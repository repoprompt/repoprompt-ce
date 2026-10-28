//
//  ServerController.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-06-20.
//

import AppKit
import Darwin
import Foundation
import Logging
import OSLog
import RepoPromptSettingsCore
import RepoPromptShared
import SwiftUI

#if DEBUG
    private var serverControllerDebugLoggingEnabled = false
    private func serverControllerDebugLog(_ message: @autoclosure () -> String) {
        guard serverControllerDebugLoggingEnabled else { return }
        print("[ServerController] \(message())")
    }
#else
    private func serverControllerDebugLog(_ message: @autoclosure () -> String) {}
#endif

private let log = Logger(label: "com.repoprompt.mcp.servercontroller")

/// ---------------------------------------------------------------------
///  SwiftUI facing controller – own instance lives at the app level
/// ---------------------------------------------------------------------
/// Controller visible from SwiftUI
final actor ServerController: ObservableObject {
    /// ──────────  Singleton  ──────────
    static let shared = ServerController()

    // –––––  Internal state (no longer @Published since we're not on @MainActor)  –––––
    private var serverStatus: String = "Starting…"
    private var pendingConnectionID: String?
    weak var mcpService: MCPService?

    /// Default ("Always allow") mode deliberately trusts self-reported names, as before #1346.
    /// Strict mode ignores both this persisted list and the built-in set.
    private static let alwaysAllowedKey = "mcp.alwaysAllowedClients"
    private static let defaultAlwaysAllowedClients: Set<String> = [
        "claude-code", "codex-mcp-client", "gemini-cli-mcp-client",
        "opencode", "cursor", "cursor-mcp-client", "claude-ai"
    ]
    private var alwaysAllowedClients: Set<String>
    private let approvalDefaults: UserDefaults
    private let strictConnectionApprovalEnabled: @Sendable () async -> Bool

    /// –––––  Private implementation helpers  –––––
    private enum DesiredTransportState: Equatable {
        case running
        case disabled
        case stopped
    }

    private struct StartAttempt {
        let generation: UInt64
        let task: Task<Void, Error>
    }

    enum LifecycleError: Error {
        case startSuperseded
        case controllerReleased
    }

    private let networkManager: ServerNetworkManager
    private let globalRegistrationOperation: @Sendable () async throws -> Void
    private let beforeTransportActivationOperation: @Sendable () async throws -> Void
    private var lifecycleGeneration: UInt64 = 0
    private var desiredTransportState: DesiredTransportState = .stopped
    private var activeStartAttempt: StartAttempt?
    private var activeApprovalDialogs: Set<String> = []
    private struct ApprovalRequest {
        let clientID: String
        let principal: MCPApprovalProcessIdentity?
        let validate: @Sendable () async -> Bool
        let isConnectionLive: @Sendable () async -> Bool
        let approve: () -> Void
        let deny: () -> Void
    }

    private struct SessionDecision {
        let allowed: Bool
        let deniedUntil: TimeInterval
        let order: UInt64
    }

    private var pendingApprovals: [ApprovalRequest] = []
    private var currentApproval: ApprovalRequest?
    /// Reserves the FIFO head across asynchronous liveness/session checks.
    private var preparingApproval = false
    private var sessionDecisions: [MCPApprovalProcessIdentity: SessionDecision] = [:]
    private var decisionOrder: UInt64 = 0
    private let monotonicNow: @Sendable () -> TimeInterval
    private let processIsCurrent: @Sendable (MCPApprovalProcessIdentity) -> Bool
    private let denialCooldown: TimeInterval = 60

    // –––––  Injected callbacks for approval flow  –––––
    nonisolated(unsafe) var onApprovalRequest: ((String, UInt64, String?) async -> Void)?
    nonisolated(unsafe) var onApprovalResolved: ((Bool) -> Void)?

    /// Activity token used to disable App Nap while the server runs.
    private var powerActivity: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    /// Set the approval callback
    func setApprovalCallback(_ callback: @escaping (String, UInt64, String?) async -> Void) {
        onApprovalRequest = callback
    }

    func setMCPService(_ service: MCPService?) {
        mcpService = service
    }

    /// –––––  Init: wire approval-flow & kick off the listener  –––––
    init(
        networkManager: ServerNetworkManager = .shared,
        globalRegistrationOperation: @escaping @Sendable () async throws -> Void = {
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
        },
        beforeTransportActivationOperation: @escaping @Sendable () async throws -> Void = {},
        installNetworkCallbacks: Bool = true,
        approvalDefaults: UserDefaults = .standard,
        strictConnectionApprovalEnabled: @escaping @Sendable () async -> Bool = {
            await MainActor.run { GlobalSettingsStore.shared.mcpStrictConnectionApproval() }
        },
        monotonicNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        processIsCurrent: @escaping @Sendable (MCPApprovalProcessIdentity) -> Bool = {
            MCPApprovalProcessIdentity.read(pid: $0.pid) == $0
        }
    ) {
        self.networkManager = networkManager
        self.approvalDefaults = approvalDefaults
        alwaysAllowedClients = Self.loadLegacyClientNames(defaults: approvalDefaults)
            .filter { !Self.isRepoPromptCLIClientName($0) }
        self.strictConnectionApprovalEnabled = strictConnectionApprovalEnabled
        self.monotonicNow = monotonicNow
        self.processIsCurrent = processIsCurrent
        self.globalRegistrationOperation = globalRegistrationOperation
        self.beforeTransportActivationOperation = beforeTransportActivationOperation
        if installNetworkCallbacks {
            Task { [weak self] in
                await self?.bootstrapCallbacks()
            }
        }
    }

    private func bootstrapCallbacks() async {
        // Wire up dashboard update callback to notify MCPService
        await networkManager.setOnDashboardUpdate { [weak self] in
            guard let self else { return }
            Task {
                guard let service = await self.mcpService else { return }
                await service.notifyDashboardUpdate()
            }
        }

        // Wire up identity escalation callback
        await networkManager.setOnIdentityEscalation { [weak self] reason in
            guard let self else { return }
            Task {
                guard let service = await self.mcpService else { return }
                let diag = MCPDiagnostics(
                    issue: .identityRecoveryDegraded(message: reason),
                    lastEventAt: Date(),
                    listenerStateDescription: "Bootstrap socket connection issue"
                )
                await service.updateDiagnostics(diag)
            }
        }

        // Set up approval handler
        await networkManager.setConnectionApprovalHandler { [weak self] connectionID, client in
            guard let self else { return false }
            return await authorizeConnection(connectionID: connectionID, clientName: client.name)
        }
        await installWakeObserverIfNeeded()
    }

    /// Shared by live socket initialization and isolated transport regression tests.
    private func authorizeConnection(connectionID: UUID, clientName: String) async -> Bool {
        serverControllerDebugLog("Approval handler called for client: '\(clientName)' connectionID: \(connectionID)")

        // Reserve a slot BEFORE any UI to avoid stampedes
        guard await networkManager.tryReserveConnectionSlot(
            connectionID: connectionID, clientID: clientName
        ) else {
            log.warning("Failed to reserve connection slot for '\(clientName)'")
            return false
        }

        // The explicit global bypass applies in both approval modes; strict mode
        // only disables name-based grants (built-in and saved client names).
        if autoApproveAllClients {
            serverControllerDebugLog("Auto-approving '\(clientName)' (global auto-approve enabled)")
            if let service = mcpService {
                await service.clientConnectedSuccessfully(name: clientName)
            }
            return true
        }

        // Built-in auto-approve for RepoPrompt's own CLI clients requires
        // executable verification. Do not consult the generic allow-list for these
        // spoofable client names.
        let isRepoCLI = Self.isRepoPromptCLIClientName(clientName)
        let verifiedHelperPID = await bundledRepoPromptHelperPID(connectionID: connectionID)
        let verifiedBundledCLI = verifiedHelperPID != nil
        let appManagedAgent = if let verifiedHelperPID {
            await networkManager.authorizeAutomaticAppManagedAgentAdmission(
                connectionID: connectionID,
                clientName: clientName,
                verifiedBundledHelperPID: verifiedHelperPID
            )
        } else {
            false
        }
        if Self.canAutomaticallyApprove(clientName: clientName, bundledCLI: verifiedBundledCLI) || appManagedAgent {
            serverControllerDebugLog("Auto-approving '\(clientName)' (bundled helper verified; appManagedAgent=\(appManagedAgent))")
            if let service = mcpService {
                await service.clientConnectedSuccessfully(name: clientName)
            }
            return true
        } else if isRepoCLI {
            log.warning("RepoPrompt CLI name matched but executable path verification failed for connectionID=\(connectionID)")
        }

        if await !strictConnectionApprovalEnabled(), isClientAlwaysAllowed(clientName) {
            serverControllerDebugLog("Auto-approving '\(clientName)' (always-allowed client name)")
            await mcpService?.clientConnectedSuccessfully(name: clientName)
            return true
        }

        // Reconnect consent belongs to an OS-observed process lifetime, never
        // to initialize metadata. Bundled transports use their immediate launcher.
        let principal = await approvalPrincipal(
            connectionID: connectionID, bundledHelper: verifiedBundledCLI
        )

        let peerIdentity = await approvalPeerIdentity(connectionID: connectionID)

        // Otherwise request approval through the callback
        let approved = await withCheckedContinuation { c in
            Task {
                await self.requestApproval(
                    clientID: clientName,
                    principal: principal,
                    validate: {
                        guard await self.networkManager.isConnectionLiveForApproval(connectionID) else { return false }
                        guard let principal else { return true }
                        guard let peerIdentity,
                              await self.approvalPeerIdentity(connectionID: connectionID) == peerIdentity
                        else { return false }
                        return await self.approvalPrincipal(
                            connectionID: connectionID, bundledHelper: verifiedBundledCLI
                        ) == principal
                    },
                    isConnectionLive: { await self.networkManager.isConnectionLiveForApproval(connectionID) },
                    approve: { c.resume(returning: true) },
                    deny: { c.resume(returning: false) }
                )
            }
        }
        if !approved {
            await networkManager.terminateConnection(
                connectionID,
                reason: .approvalDenied,
                message: "Denied by user"
            )
        } else {
            // Client manually approved - clear any previous errors for this client
            if let service = mcpService {
                await service.clientConnectedSuccessfully(name: clientName)
            }
        }
        return approved
    }

    private func installWakeObserverIfNeeded() async {
        // Register wake observer if not already registered
        guard wakeObserver == nil else { return }
        let networkMgr = networkManager
        let observer = await MainActor.run {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { _ in
                Task {
                    await networkMgr.ensureBootstrapHealthy(force: true)
                }
            }
        }
        wakeObserver = observer
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    // MARK: – Allow-list helpers –

    static func isBuiltInAlwaysAllowedClient(_ clientID: String) -> Bool {
        !isRepoPromptCLIClientName(clientID)
            && defaultAlwaysAllowedClients.contains { MCPClientIdentity.matches($0, clientID) }
    }

    private func isClientAlwaysAllowed(_ clientID: String) -> Bool {
        // RepoPrompt CLI names must still pass bundled executable verification.
        guard !Self.isRepoPromptCLIClientName(clientID) else { return false }
        if Self.isBuiltInAlwaysAllowedClient(clientID) { return true }
        return alwaysAllowedClients.contains { MCPClientIdentity.matches($0, clientID) }
    }

    /// RepoPrompt CLI names are reserved for verified bundled helpers and are never saved.
    static func canSaveAlwaysAllowed(clientName: String) -> Bool {
        !isRepoPromptCLIClientName(clientName)
    }

    private func addAlwaysAllowed(clientID: String) {
        guard Self.canSaveAlwaysAllowed(clientName: clientID), !isClientAlwaysAllowed(clientID) else { return }
        alwaysAllowedClients.insert(clientID)
        approvalDefaults.set(Array(alwaysAllowedClients).sorted(), forKey: Self.alwaysAllowedKey)
    }

    static func loadLegacyClientNames(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: alwaysAllowedKey) ?? [])
    }

    /// Verified bundled-helper admission is independent of the selected approval mode.
    static func canAutomaticallyApprove(clientName: String, bundledCLI verified: Bool) -> Bool {
        isRepoPromptCLIClientName(clientName) && verified
    }

    private static func isRepoPromptCLIClientName(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("RepoPrompt CLI")
    }

    #if DEBUG
        func test_authorizeConnection(connectionID: UUID, clientName: String) async -> Bool {
            await authorizeConnection(connectionID: connectionID, clientName: clientName)
        }

        func test_timeoutApproval(generation: UInt64) async {
            guard let clientID = pendingConnectionID else { return }
            await handleApprovalTimeout(clientID: clientID, expectedGeneration: generation)
        }

        func test_requestApproval(
            clientID: String,
            principal: MCPApprovalProcessIdentity? = nil,
            validate: @escaping @Sendable () async -> Bool = { true },
            isConnectionLive: @escaping @Sendable () async -> Bool = { true },
            approve: @escaping () -> Void,
            deny: @escaping () -> Void
        ) async {
            await requestApproval(
                clientID: clientID, principal: principal, validate: validate,
                isConnectionLive: isConnectionLive, approve: approve, deny: deny
            )
        }
    #endif

    /// Only a kernel-observed peer matching the bundled helper can enter either automatic path.
    private func bundledRepoPromptHelperPID(connectionID: UUID) async -> Int? {
        guard let expectedURL = Bundle.main.url(forAuxiliaryExecutable: "repoprompt-mcp"),
              let peerPID = await networkManager.peerPID(for: connectionID),
              peerPID > 1,
              let actualPath = Self.executablePath(forPID: peerPID)
        else { return nil }
        let expected = expectedURL.resolvingSymlinksInPath().standardizedFileURL.path
        let actual = URL(fileURLWithPath: actualPath).resolvingSymlinksInPath().standardizedFileURL.path
        return actual == expected ? peerPID : nil
    }

    private func approvalPeerIdentity(connectionID: UUID) async -> MCPApprovalProcessIdentity? {
        guard let pid = await networkManager.peerPID(for: connectionID), pid > 1, pid <= Int(Int32.max) else { return nil }
        return MCPApprovalProcessIdentity.read(pid: Int32(pid))
    }

    private func approvalPrincipal(connectionID: UUID, bundledHelper: Bool) async -> MCPApprovalProcessIdentity? {
        guard let pid = await networkManager.peerPID(for: connectionID), pid > 1, pid <= Int(Int32.max) else { return nil }
        return MCPApprovalProcessIdentity.resolve(peerPID: Int32(pid), bundledHelper: bundledHelper)
    }

    private nonisolated static func executablePath(forPID pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Dashboard & Auto-Approve Management

    /// Returns the list of always-allowed client IDs
    func alwaysAllowedClientIDs() -> [String] {
        var seen = Set<String>()
        var values: [String] = []
        for clientID in alwaysAllowedClients.union(Self.defaultAlwaysAllowedClients).sorted() {
            let dedupeKey = MCPClientIdentity.storageKey(clientID) ?? clientID
            guard seen.insert(dedupeKey).inserted else { continue }
            values.append(clientID)
        }
        return values
    }

    /// Add or remove a client from the persistent allow-list
    func setAlwaysAllowed(clientID: String, allowed: Bool) async {
        if allowed {
            guard await !strictConnectionApprovalEnabled() else { return }
            addAlwaysAllowed(clientID: clientID)
        } else {
            guard !Self.isBuiltInAlwaysAllowedClient(clientID) else { return }
            alwaysAllowedClients = alwaysAllowedClients.filter { !MCPClientIdentity.matches($0, clientID) }
            approvalDefaults.set(
                Array(alwaysAllowedClients),
                forKey: Self.alwaysAllowedKey
            )
        }
        // Notify dashboard to refresh the UI
        await mcpService?.notifyDashboardUpdate()
    }

    /// Key for auto-approve all clients setting
    private static let autoApproveAllClientsKey = "mcpAutoApproveAllClients"

    /// Whether to auto-approve all new clients without user confirmation
    private var autoApproveAllClients: Bool {
        get { approvalDefaults.bool(forKey: Self.autoApproveAllClientsKey) }
        set { approvalDefaults.set(newValue, forKey: Self.autoApproveAllClientsKey) }
    }

    func getAutoApproveAllClients() -> Bool {
        autoApproveAllClients
    }

    func setAutoApproveAllClients(_ enabled: Bool) async {
        autoApproveAllClients = enabled
        // Notify dashboard to refresh the UI
        await mcpService?.notifyDashboardUpdate()
    }

    /// Forcefully disconnect a specific connection (legacy - use terminateConnection instead)
    func bootConnection(id: UUID) async {
        await terminateConnection(id: id, reason: .userBootFromDashboard)
    }

    /// Terminates a connection with explicit kill semantics.
    /// CLI will exit without retrying.
    func terminateConnection(id: UUID, reason: TerminationReason, message: String? = nil) async {
        await networkManager.terminateConnection(id, reason: reason, message: message)
    }

    /// Snapshot of the server state for dashboard display
    struct ServerDashboardSnapshot {
        let serverStatus: String
        let diagnostics: MCPDiagnostics
        let connections: NetworkDashboardSnapshot
        let alwaysAllowedClients: [String]
        let autoApproveAllClients: Bool
    }

    /// Returns a complete dashboard snapshot
    func dashboardSnapshot(currentDiagnostics: MCPDiagnostics) async -> ServerDashboardSnapshot {
        let connSnapshot = await networkManager.dashboardSnapshot()
        return ServerDashboardSnapshot(
            serverStatus: serverStatus,
            diagnostics: currentDiagnostics,
            connections: connSnapshot,
            alwaysAllowedClients: alwaysAllowedClientIDs(),
            autoApproveAllClients: autoApproveAllClients
        )
    }

    // MARK: – public API –

    /// Request to start (or re-enable) the MCP listener.
    /// Application-scoped domain tools must exist before the listener can advertise
    /// or accept any window-scoped catalog.
    func startServer() async throws {
        if let activeStartAttempt,
           activeStartAttempt.generation == lifecycleGeneration,
           desiredTransportState == .running
        {
            try await activeStartAttempt.task.value
            return
        }

        lifecycleGeneration &+= 1
        desiredTransportState = .running
        let generation = lifecycleGeneration
        let task = Task { [weak self] in
            guard let self else { throw LifecycleError.controllerReleased }
            try await performStart(generation: generation)
        }
        activeStartAttempt = StartAttempt(generation: generation, task: task)

        do {
            try await task.value
        } catch {
            if activeStartAttempt?.generation == generation {
                activeStartAttempt = nil
            }
            throw error
        }
        if activeStartAttempt?.generation == generation {
            activeStartAttempt = nil
        }
    }

    private func performStart(generation: UInt64) async throws {
        do {
            try await globalRegistrationOperation()
            try requireCurrentStart(generation)
            try await beforeTransportActivationOperation()
            try requireCurrentStart(generation)

            let startOutcome: ServerNetworkManager.StartOutcome
            if await networkManager.isRunning() {
                try requireCurrentStart(generation)
                await networkManager.setEnabled(true) // expose tools only
                try requireCurrentStart(generation)
                startOutcome = await networkManager.start()
                try requireCurrentStart(generation)
                await networkManager.ensureBootstrapHealthy(force: true)
            } else {
                try requireCurrentStart(generation)
                await networkManager.setEnabled(true)
                try requireCurrentStart(generation)
                startOutcome = await networkManager.start() // cold start once
                try requireCurrentStart(generation)
                await networkManager.ensureBootstrapHealthy(force: true)
            }
            try requireCurrentStart(generation)
            guard let runningStatus = Self.runningStatus(for: startOutcome) else {
                throw LifecycleError.startSuperseded
            }
            beginPowerActivity()
            updateServerStatus(runningStatus)
        } catch LifecycleError.startSuperseded {
            await reconcileSupersededStart()
            throw LifecycleError.startSuperseded
        }
    }

    private func requireCurrentStart(_ generation: UInt64) throws {
        guard generation == lifecycleGeneration, desiredTransportState == .running else {
            throw LifecycleError.startSuperseded
        }
    }

    private func reconcileSupersededStart() async {
        switch desiredTransportState {
        case .running:
            break
        case .disabled:
            await networkManager.setEnabled(false)
        case .stopped:
            await networkManager.stop()
        }
    }

    /// Disable the listener.
    func stopServer() async {
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        desiredTransportState = .disabled
        await networkManager.setEnabled(false)
        guard generation == lifecycleGeneration, desiredTransportState == .disabled else { return }
        endPowerActivity()
        updateServerStatus("Disabled")
    }

    /// Completely shut down the listener.
    func fullShutdown() async {
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        desiredTransportState = .stopped
        await networkManager.stop()
        guard generation == lifecycleGeneration, desiredTransportState == .stopped else { return }
        endPowerActivity()
        updateServerStatus("Stopped")
    }

    /// This method will be used to enable/disable all tools at once.
    /// Enabling joins the same single-flight start authority as window startup so
    /// registration and pre-activation checks always precede transport exposure.
    func setEnabled(_ enabled: Bool) async throws {
        if enabled {
            try await startServer()
        } else {
            await stopServer()
        }
    }

    // This is no longer needed as there are no individual service toggles.
    // func updateServiceBindings(_ b: [String: Binding<Bool>]) async {
    //     await networkManager.updateServiceBindings(b)
    // }

    // MARK: – helpers ––––––––––––––––––––––––––––––––––––––––––––––––––

    nonisolated static func runningStatus(for outcome: ServerNetworkManager.StartOutcome) -> String? {
        switch outcome {
        case .ready:
            "Running"
        case let .degraded(reason):
            "Running (Degraded: \(reason.statusDescription))"
        case .superseded:
            nil
        }
    }

    /// Timeout for approval dialogs (auto-deny after this duration)
    private let approvalTimeout: TimeInterval = 300
    /// Monotonic generation for the active approval request.
    /// Prevents stale timeout tasks from auto-denying a newer request.
    private var approvalGeneration: UInt64 = 0
    /// Timeout watchdog for the currently active approval request.
    /// Cancelled when approval resolves or is superseded.
    private var approvalTimeoutTask: Task<Void, Never>?

    private func updateServerStatus(_ s: String) {
        serverControllerDebugLog("Server status ➜ \(s)")
        serverStatus = s
    }

    private func beginPowerActivity() {
        guard powerActivity == nil else { return }
        powerActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
            reason: "Maintain realtime MCP server connection"
        )
    }

    private func endPowerActivity() {
        guard let activity = powerActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        powerActivity = nil
    }

    /// Request approval through the callback system instead of showing NSAlert directly.
    /// Approval requests are handled in strict FIFO order: exactly one active request at a time.
    private func requestApproval(
        clientID: String,
        principal: MCPApprovalProcessIdentity? = nil,
        validate: @escaping @Sendable () async -> Bool = { true },
        isConnectionLive: @escaping @Sendable () async -> Bool = { true },
        approve: @escaping () -> Void,
        deny: @escaping () -> Void
    ) async {
        let request = ApprovalRequest(
            clientID: clientID, principal: principal, validate: validate,
            isConnectionLive: isConnectionLive, approve: approve, deny: deny
        )
        await enqueueApproval(request)
    }

    private func enqueueApproval(_ request: ApprovalRequest) async {
        // Register arrival and reserve capacity before any actor suspension.
        // Include the head being validated, which has already left the array.
        guard pendingApprovals.count + (currentApproval != nil || preparingApproval ? 1 : 0) < 32 else {
            request.deny()
            return
        }
        pendingApprovals.append(request)
        await activateNextQueuedApprovalIfNeeded()
    }

    /// Returns true if the request was resolved without presenting UI.
    private func resolveSessionDecision(_ request: ApprovalRequest) async -> Bool {
        guard let principal = request.principal else { return false }
        guard processIsCurrent(principal) else {
            sessionDecisions.removeValue(forKey: principal)
            request.deny()
            return true
        }
        guard let decision = sessionDecisions[principal] else { return false }
        if !decision.allowed, monotonicNow() >= decision.deniedUntil {
            sessionDecisions.removeValue(forKey: principal)
            return false
        }
        if decision.allowed {
            if await request.validate(), processIsCurrent(principal) { request.approve() } else { request.deny() }
        } else {
            request.deny()
        }
        return true
    }

    private func rememberDecision(for request: ApprovalRequest, allow: Bool) {
        guard let principal = request.principal, processIsCurrent(principal) else { return }
        let now = monotonicNow()
        // Dead process entries are harmless: each lookup checks the full process
        // lifetime. Prune expiry here and bound storage without scanning 256 PIDs.
        sessionDecisions = sessionDecisions.filter { $0.value.allowed || $0.value.deniedUntil > now }
        if sessionDecisions[principal] == nil, sessionDecisions.count >= 256 {
            // Only at capacity, retire dead lifetimes before evicting a long-lived
            // launcher's consent. Routine decisions never scan every process.
            sessionDecisions = sessionDecisions.filter { processIsCurrent($0.key) }
            if sessionDecisions.count >= 256,
               let oldest = sessionDecisions.min(by: { $0.value.order < $1.value.order })?.key
            {
                sessionDecisions.removeValue(forKey: oldest)
            }
        }
        decisionOrder &+= 1
        sessionDecisions[principal] = SessionDecision(
            allowed: allow, deniedUntil: now + denialCooldown, order: decisionOrder
        )
    }

    /// Starts a single active approval request and schedules its timeout watchdog.
    private func beginApprovalRequest(_ request: ApprovalRequest) async {
        let clientID = request.clientID
        approvalTimeoutTask?.cancel()
        approvalTimeoutTask = nil
        pendingConnectionID = clientID
        activeApprovalDialogs.insert(clientID)
        currentApproval = request
        approvalGeneration &+= 1

        let expectedClientID = clientID
        let expectedGeneration = approvalGeneration
        let timeout = approvalTimeout
        approvalTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            guard let self else { return }
            await handleApprovalTimeout(
                clientID: expectedClientID,
                expectedGeneration: expectedGeneration
            )
        }

        await onApprovalRequest?(clientID, expectedGeneration, request.principal?.executablePath)
    }

    /// Starts the next queued approval request, if any.
    private func activateNextQueuedApprovalIfNeeded() async {
        guard !preparingApproval, currentApproval == nil, pendingConnectionID == nil else { return }
        preparingApproval = true
        defer { preparingApproval = false }
        while currentApproval == nil, !pendingApprovals.isEmpty {
            let request = pendingApprovals.removeFirst()
            guard await request.isConnectionLive() else {
                request.deny()
                continue
            }
            if await !strictConnectionApprovalEnabled(), isClientAlwaysAllowed(request.clientID) {
                if await request.validate() { request.approve() } else { request.deny() }
                continue
            }
            if await resolveSessionDecision(request) { continue }
            await beginApprovalRequest(request)
        }
    }

    /// Timeout creates the same process-scoped cooldown as explicit denial.
    private func handleApprovalTimeout(clientID: String, expectedGeneration: UInt64) async {
        guard let request = currentApproval,
              pendingConnectionID == clientID,
              approvalGeneration == expectedGeneration else { return }

        approvalTimeoutTask?.cancel()
        approvalTimeoutTask = nil
        currentApproval = nil
        pendingConnectionID = nil
        activeApprovalDialogs.remove(clientID)
        rememberDecision(for: request, allow: false)
        request.deny()
        // With no process identity, preserve the old denial-only duplicate drain.
        // This never grants trust to a name and avoids a backlog of timeout dialogs.
        if request.principal == nil {
            while let index = pendingApprovals.firstIndex(where: { $0.principal == nil && $0.clientID == clientID }) {
                pendingApprovals.remove(at: index).deny()
            }
        }
        await mcpService?.clearPendingApproval(generation: expectedGeneration)
        onApprovalResolved?(false)

        if let service = mcpService {
            let diag = MCPDiagnostics(
                issue: .lastClientApprovalTimedOut(clientID: clientID),
                lastEventAt: Date(),
                listenerStateDescription: "Last client was auto-denied after approval timeout"
            )
            Task { await service.updateDiagnostics(diag) }
        }

        await activateNextQueuedApprovalIfNeeded()
    }

    /// Called by MCPService when the UI has made a decision.
    func resolvePendingApproval(allow: Bool, generation: UInt64, alwaysAllow: Bool = false) async {
        guard generation == approvalGeneration,
              let request = currentApproval else { return }
        // Validate this connection independently of consent for its displayed
        // launching process. A host can replace the helper while the dialog is
        // open; that must not discard a decision for a still-running launcher.
        // Awaiting process observation may race timeout or another window's response.
        let valid = await request.validate()
        let strictApproval = await strictConnectionApprovalEnabled()
        guard generation == approvalGeneration, currentApproval != nil else { return }
        let resolvedClientID = pendingConnectionID
        approvalTimeoutTask?.cancel()
        approvalTimeoutTask = nil

        if !allow, let clientID = resolvedClientID, let service = mcpService {
            let diag = MCPDiagnostics(
                issue: .lastClientApprovalDenied(clientID: clientID),
                lastEventAt: Date(),
                listenerStateDescription: "Last client was denied"
            )
            Task { await service.updateDiagnostics(diag) }
        }

        rememberDecision(for: request, allow: allow)
        let principalIsCurrent = request.principal.map(processIsCurrent)
        if allow, alwaysAllow, !strictApproval, principalIsCurrent ?? valid {
            addAlwaysAllowed(clientID: request.clientID)
        }
        if allow, valid, principalIsCurrent ?? true {
            request.approve()
        } else {
            request.deny()
        }

        // Queue entries recheck the current mode's saved-name and process-session policy.
        if let clientID = resolvedClientID {
            activeApprovalDialogs.remove(clientID)
        }

        currentApproval = nil
        pendingConnectionID = nil

        // Notify resolution callback if needed
        onApprovalResolved?(allow)
        await activateNextQueuedApprovalIfNeeded()
    }
}
