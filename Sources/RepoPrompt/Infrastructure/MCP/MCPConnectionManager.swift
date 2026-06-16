// MARK: - Connection Management Components

import Darwin
import Dispatch
import Foundation
import JSONSchema
import Logging
import MCP
import Ontology
import OSLog
import RepoPromptShared
import SwiftUI

#if DEBUG
    private var mcpConnectionManagerDebugLoggingEnabled = ProcessInfo.processInfo.environment["REPOPROMPT_MCP_DEBUG"] == "1"
    private var mcpRoutingDebugLoggingEnabled = false
    private var mcpPolicyDebugLoggingEnabled = false

    private func connectionLog(_ message: @autoclosure () -> String) {
        guard mcpConnectionManagerDebugLoggingEnabled else { return }
        print("[MCPConnectionManager] \(message())")
    }

    private func mcpACPLog(_ message: @autoclosure () -> String) {
        guard AgentRuntimeProviderService.enableDebugLogging else { return }
        print(message())
    }

    private func mcpRoutingLog(_ message: @autoclosure () -> String) {
        guard mcpRoutingDebugLoggingEnabled else { return }
        print("[MCPRouting] \(message())")
    }

    private func mcpRoutingInternalDebugLog(_ message: @autoclosure () -> String) {
        mcpRoutingLog(message())
    }

    private func mcpPolicyLog(_ message: @autoclosure () -> String) {
        guard mcpPolicyDebugLoggingEnabled else { return }
        print("[MCPPolicy] \(message())")
    }

    private func mcpToolTrackingDiagnostic(_ message: @autoclosure () -> String) {
        print("[ClaudeToolTracking] \(message())")
    }
#else
    private func connectionLog(_ message: @autoclosure () -> String) {}
    private func mcpACPLog(_ message: @autoclosure () -> String) {}
    private func mcpRoutingLog(_ message: @autoclosure () -> String) {}
    private func mcpRoutingInternalDebugLog(_ message: @autoclosure () -> String) {}
    private func mcpPolicyLog(_ message: @autoclosure () -> String) {}
    private func mcpToolTrackingDiagnostic(_ message: @autoclosure () -> String) {}
#endif

// MARK: - Bundle helpers for safe metadata access

private extension Bundle {
    var name: String {
        object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Unknown"
    }

    var shortVersionString: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
    }
}

// MARK: - MCP Run Purpose

/// Purpose of an MCP connection's run, used to route UI (e.g., ask_user) to the correct surface.
public enum MCPRunPurpose: String, Sendable, Codable {
    case discoverRun // Context Builder agent exploring codebase
    case agentModeRun // Agent mode interactive session
    case unknown // No policy or unspecified
}

/// ---------------------------------------------------------------------
/// Shared constants & logger for the connection-layer (ported from iMCP)
/// ---------------------------------------------------------------------
private let log: Logging.Logger = {
    var logger = Logger(label: "com.repoprompt.mcp.connection")
    #if DEBUG
        logger.logLevel = .debug
    #else
        logger.logLevel = .notice
    #endif
    return logger
}()

enum ConnectionStateSnapshot: Equatable {
    case connecting
    case ready
    case failed(Swift.Error?)
    case cancelled

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.connecting, .connecting),
             (.ready, .ready),
             (.cancelled, .cancelled):
            true
        case (.failed, .failed):
            // Treat all failures as equivalent for pruning/retention decisions
            true
        default:
            false
        }
    }
}

private enum MCPConnectionStopRaceOutcome {
    case stopped
    case deadlineElapsed
}

private actor MCPConnectionStopRace {
    private var outcome: MCPConnectionStopRaceOutcome?
    private var waiters: [CheckedContinuation<MCPConnectionStopRaceOutcome, Never>] = []

    func resolve(_ outcome: MCPConnectionStopRaceOutcome) {
        guard case nil = self.outcome else { return }
        self.outcome = outcome
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: outcome)
        }
    }

    func wait() async -> MCPConnectionStopRaceOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

protocol MCPServerConnection: Actor {
    func start(approvalHandler: @escaping (MCP.Client.Info) async -> Bool) async throws
    func stop() async
    /// Immediately severs transport delivery for a tool execution that ignored cancellation.
    /// This must not await handler/server shutdown.
    func abortForExecutionWatchdog() async
    func notifyToolListChanged() async
    func connectionState() -> ConnectionStateSnapshot
    func isViableForRetention() -> Bool
    func secondsSinceLastActivity() async -> TimeInterval
    func transportIngressSnapshot() async -> MCPTransportIngressSnapshot?
    func waitUntilResponseDeliveryDrained() async -> Bool
    /// Whether this is a legacy filesystem-backed connection (deprecated)
    nonisolated var isFilesystemBacked: Bool { get }
    /// Legacy: connection folder URL for filesystem connections
    nonisolated var connectionFolderURL: URL? { get }
    /// Optional capability token / session key for routing persistence.
    /// Used to correlate CLI sessions across reconnections.
    nonisolated var capabilityToken: String? { get }
    /// Terminates this connection with a reason.
    /// Writes a kill signal file (filesystem side-channel) so CLI exits without retry, then stops.
    /// - Parameter reason: Why the connection is being terminated
    /// - Parameter message: Optional human-readable message
    func terminate(reason: TerminationReason, message: String?) async

    /// Sends a progress notification to the CLI during long-running operations.
    /// - Parameters:
    ///   - tool: Tool name (e.g., "context_builder", "oracle_send")
    ///   - kind: Progress kind (.stage for transitions, .heartbeat for keep-alive)
    ///   - stage: Current stage name
    ///   - message: Human-readable message
    func sendProgress(tool: String, kind: RepoPromptProgressKind, stage: String, message: String) async
}

extension MCPServerConnection {
    func waitUntilResponseDeliveryDrained() async -> Bool {
        true
    }
}

// MARK: - Dashboard Models

/// Transport type for MCP connections
enum ConnectionTransport: String, Codable {
    case network
    case filesystem
}

/// Summary state for dashboard display
enum ConnectionStateSummary: String, Codable {
    case setup
    case waiting
    case ready
    case failed
    case cancelled
    case unknown
}

struct ConnectionDashboardActiveToolScope: Codable, Equatable {
    let windowID: Int
    let toolName: String
    let sequence: UInt64
}

/// Dashboard entry for a single connection
struct ConnectionDashboardEntry: Identifiable, Codable {
    let id: UUID
    let clientName: String
    let windowID: Int?
    let transport: ConnectionTransport
    let state: ConnectionStateSummary
    let createdAt: Date
    let lastToolCallAt: Date?
    let totalToolCalls: Int
    let idleSeconds: TimeInterval?
    let hasInFlightCalls: Bool
    let activeToolScope: ConnectionDashboardActiveToolScope?
    let activeToolScopes: [ConnectionDashboardActiveToolScope]
    var activeToolScopeCount: Int {
        activeToolScopes.count
    }

    var activeToolName: String? {
        activeToolScope?.toolName
    }

    var activeToolWindowID: Int? {
        activeToolScope?.windowID
    }

    /// Session key (capabilityToken) for disambiguating multiple client instances
    let sessionKey: String?
}

/// Complete dashboard snapshot from ServerNetworkManager
struct NetworkDashboardSnapshot {
    let isRunning: Bool
    let connections: [ConnectionDashboardEntry]
    let recentToolCalls: [ServerNetworkManager.ToolCallHistoryEntry]
}

/// Debug snapshot of identity context for a connection
struct IdentityContextSnapshot {
    /// How identity was derived
    enum Source: String {
        case unknown
        case filesystemMeta
        case handshake
    }

    let connectionID: UUID
    let clientName: String?
    let capabilityToken: String?
    let source: Source
    let hasHandshake: Bool
    let lastUpdated: Date
}

// The NWConnection-based MCPConnectionManager and Bonjour-based NetworkDiscoveryManager
// previously lived here. They have been fully removed so that the only remaining
// MCPServerConnection implementation is BootstrapSocketConnectionManager (in a separate file).
// No replacement code is needed; we now go directly to ServerNetworkManager.

/// Lock-protected ownership ledger for accepted bootstrap descriptors after handshake
/// ownership transfer but before actor-processed deferred registration. Full shutdown
/// invalidates one lifecycle and drains its descriptors synchronously.
private final class BootstrapTransferredSocketLedger: @unchecked Sendable {
    private struct Entry {
        let lifecycleGeneration: UInt64
        let fd: Int32
    }

    private let lock = NSLock()
    private var activeLifecycleGeneration: UInt64?
    private var entriesByConnectionID: [UUID: Entry] = [:]

    func activate(lifecycleGeneration: UInt64) {
        lock.lock()
        activeLifecycleGeneration = lifecycleGeneration
        lock.unlock()
    }

    func publish(connectionID: UUID, lifecycleGeneration: UInt64, fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeLifecycleGeneration == lifecycleGeneration,
              entriesByConnectionID[connectionID] == nil
        else { return false }
        entriesByConnectionID[connectionID] = Entry(lifecycleGeneration: lifecycleGeneration, fd: fd)
        return true
    }

    func contains(connectionID: UUID, lifecycleGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeLifecycleGeneration == lifecycleGeneration,
              let entry = entriesByConnectionID[connectionID]
        else { return false }
        return entry.lifecycleGeneration == lifecycleGeneration
    }

    func claim(connectionID: UUID, lifecycleGeneration: UInt64) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard activeLifecycleGeneration == lifecycleGeneration,
              let entry = entriesByConnectionID[connectionID],
              entry.lifecycleGeneration == lifecycleGeneration
        else { return nil }
        entriesByConnectionID.removeValue(forKey: connectionID)
        return entry.fd
    }

    func remove(connectionID: UUID, lifecycleGeneration: UInt64) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entriesByConnectionID[connectionID],
              entry.lifecycleGeneration == lifecycleGeneration
        else { return nil }
        entriesByConnectionID.removeValue(forKey: connectionID)
        return entry.fd
    }

    func invalidateAndDrain(lifecycleGeneration: UInt64) -> [Int32] {
        lock.lock()
        defer { lock.unlock() }
        guard activeLifecycleGeneration == lifecycleGeneration else { return [] }
        activeLifecycleGeneration = nil
        let matchingEntries = entriesByConnectionID.filter { $0.value.lifecycleGeneration == lifecycleGeneration }
        for connectionID in matchingEntries.keys {
            entriesByConnectionID.removeValue(forKey: connectionID)
        }
        return matchingEntries.values.map(\.fd)
    }

    var isEmptyAndInactive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeLifecycleGeneration == nil && entriesByConnectionID.isEmpty
    }

    #if DEBUG
        var debugEntryCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return entriesByConnectionID.count
        }
    #endif
}

enum MCPConnectionCallLane: String, CaseIterable {
    /// Legacy diagnostics name for the explicit exclusive class.
    case ordinary
    case control
    case smallRead = "small_read"
    case gitRead = "git_read"
    case fileSearch = "file_search"
}

/// Manages all MCP connections using the bootstrap UNIX-domain socket.
/// TCP/Bonjour transport has been removed.
actor ServerNetworkManager {
    /// 🚀 Single, app-wide instance that owns the MCP listener and all
    /// active client connections.  Use this when you need to reference the
    /// MCP listener from anywhere in the app.
    static let shared = ServerNetworkManager()
    private static let repoCLIPrefix = "RepoPrompt CLI"
    private static let toolNameAliases: [String: String] = [
        "discover_manage_selection": "manage_selection",
        "discover_prompt": "prompt",
        "discover_workspace_context": "workspace_context"
    ]
    nonisolated static func canonicalToolName(for name: String) -> String {
        toolNameAliases[name] ?? name
    }

    nonisolated static func admissionClass(forCanonicalToolName toolName: String) -> MCPToolAdmissionClass? {
        MCPToolAdmissionPolicy.classification(forCanonicalToolName: toolName)
    }

    nonisolated static func callLane(forCanonicalToolName toolName: String) -> MCPConnectionCallLane? {
        admissionClass(forCanonicalToolName: toolName)?.connectionLane
    }

    nonisolated static let smallReadCallLaneLimit = MCPToolAdmissionPolicy.smallReadConnectionLimit
    nonisolated static let controlCallLaneLimit = MCPToolAdmissionPolicy.controlConnectionLimit
    nonisolated static let gitReadCallLaneLimit = MCPToolAdmissionPolicy.gitReadConnectionLimit

    /// Bounded concurrent `file_search` permits per connection. This remains aligned with
    /// PR #155's per-workspace broad-search active capacity.
    nonisolated static let fileSearchCallLaneLimit = MCPToolAdmissionPolicy.fileSearchConnectionLimit

    private static func validatedLiveRunID(
        candidateRunID: UUID,
        connectionID: UUID,
        connectionIDByRunID: [UUID: UUID],
        connectionIDToRunID: [UUID: UUID]
    ) -> UUID? {
        guard connectionIDToRunID[connectionID] == candidateRunID,
              connectionIDByRunID[candidateRunID] == connectionID
        else {
            return nil
        }
        return candidateRunID
    }

    #if DEBUG
        nonisolated static func test_validatedLiveRunID(
            candidateRunID: UUID,
            connectionID: UUID,
            connectionIDByRunID: [UUID: UUID],
            connectionIDToRunID: [UUID: UUID]
        ) -> UUID? {
            validatedLiveRunID(
                candidateRunID: candidateRunID,
                connectionID: connectionID,
                connectionIDByRunID: connectionIDByRunID,
                connectionIDToRunID: connectionIDToRunID
            )
        }
    #endif

    /// Resolve the window currently associated with a run ID.
    /// Fast path prefers actor-local caches (run routing/policy state) and only falls
    /// back to scanning live windows when no cached mapping exists.
    private func windowIDForRunID(_ runID: UUID) async -> Int? {
        if let cachedWindowID = windowIDByRunID[runID] {
            return cachedWindowID
        }
        if let policyWindowID = runPolicyStateByRunID[runID]?.windowID {
            windowIDByRunID[runID] = policyWindowID
            return policyWindowID
        }
        let resolvedWindowID = await MainActor.run {
            WindowStatesManager.shared.allWindows.first { $0.mcpServer.hasLiveRunID(runID) }?.windowID
        }
        if let resolvedWindowID {
            windowIDByRunID[runID] = resolvedWindowID
        }
        return resolvedWindowID
    }

    static func sanitizedRoutingRestrictedTools(_ names: Set<String>) -> Set<String> {
        guard !names.isEmpty else { return [] }
        return names
    }

    nonisolated static func shouldAdvertiseCanonicalBindingParams(for toolName: String) -> Bool {
        toolName == "bind_context"
    }

    /// Tools that declare context_id in their own schema and need it rehydrated after dispatch extraction.
    nonisolated static func shouldRehydrateContextID(for toolName: String) -> Bool {
        toolName == "bind_context" || toolName == "oracle_utils" || toolName == "context_builder"
    }

    nonisolated static func shouldRehydrateLegacyTabID(for toolName: String) -> Bool {
        toolName == "context_builder"
    }

    /// Tools that declare public window_id semantics and need an explicit hidden
    /// _windowID compatibility selector restored after dispatch extraction.
    nonisolated static func shouldRehydrateExplicitWindowID(for toolName: String) -> Bool {
        toolName == "bind_context"
    }

    /// Migrated tools resolve tab-context snapshots from request metadata, including
    /// the one-shot TaskLocal hint populated from dispatch-level context_id/_tabID.
    nonisolated static func shouldUseGenericTabBindingCompatibility(for toolName: String) -> Bool {
        guard !shouldSkipGenericTabBinding(for: toolName) else { return false }
        let migrated: Set = [
            "manage_selection",
            "workspace_context",
            "get_file_tree",
            "get_code_structure",
            "read_file",
            "file_search",
            "file_actions",
            "apply_edits",
            "prompt",
            "agent_run",
            "agent_explore",
            "agent_manage",
            "ask_oracle",
            "oracle_send",
            "oracle_utils",
            "oracle_chat_log",
            "git",
            "manage_worktree"
        ]
        return !migrated.contains(toolName)
    }

    nonisolated static func shouldInjectLegacyTabIDForCompatibility(for toolName: String) -> Bool {
        shouldRehydrateLegacyTabID(for: toolName) || shouldUseGenericTabBindingCompatibility(for: toolName)
    }

    /// bind_context manages its own window_id semantics — the dispatch layer must not
    /// auto-inject a routing window_id into its public args, because that would silently
    /// scope `op=list` to a single window instead of returning all windows.
    nonisolated static func isAppWideTool(_ toolName: String) -> Bool {
        toolName == AppSettingsMCPService.toolName
    }

    nonisolated static func shouldAutoInjectPublicWindowID(for toolName: String) -> Bool {
        toolName != "bind_context" && !isAppWideTool(toolName)
    }

    nonisolated static func shouldBypassLogicalContextPreResolution(for toolName: String) -> Bool {
        toolName == "bind_context" || isAppWideTool(toolName)
    }

    nonisolated static func shouldSkipGenericTabBinding(for toolName: String) -> Bool {
        toolName == "manage_workspaces" || toolName == "bind_context" || toolName == "context_builder" || isAppWideTool(toolName)
    }

    nonisolated static func shouldSkipPerCallRunScopedTabRebindFallback(
        toolName: String,
        purpose: MCPRunPurpose
    ) -> Bool {
        guard purpose == .agentModeRun else { return false }
        return toolName == "read_file" || toolName == "file_search"
    }

    nonisolated static func shouldBypassWindowRouting(for toolName: String) -> Bool {
        isAppWideTool(toolName)
    }

    nonisolated static func shouldPersistResolvedLogicalContextWindowMapping(for toolName: String) -> Bool {
        !shouldBypassWindowRouting(for: toolName)
    }

    nonisolated static func isWindowSelectionExempt(toolName: String, args: [String: Value]) -> Bool {
        if toolName == "bind_context" || isAppWideTool(toolName) {
            return true
        }
        guard toolName == "manage_workspaces" else { return false }
        let action = args["action"]?.stringValue?.lowercased()
        if action == "list" {
            return true
        }
        if action == "switch" || action == "create",
           args["open_in_new_window"]?.boolValue ?? false
        {
            return true
        }
        return false
    }

    nonisolated static func multiWindowSelectionGuidance() -> String {
        "Multiple RepoPrompt windows detected. Bind your connection to a tab context to route tool calls:\n\n" +
            "**Recommended: Bind by exact workspace root paths (auto-resolves to the matching workspace/window tab context)**\n" +
            "Call `bind_context` with `{\"op\":\"bind\",\"working_dirs\":[\"/absolute/path/to/root1\",\"/absolute/path/to/root2\"]}` using the full workspace directory set.\n\n" +
            "**Alternatives:**\n" +
            "- `bind_context` with `{\"op\":\"list\"}` to see windows and context_id values\n" +
            "- `bind_context` with `{\"op\":\"bind\",\"context_id\":\"<id>\"}` to bind a specific tab context\n" +
            "- `bind_context` with `{\"op\":\"bind\",\"window_id\":<id>}` to set window affinity only\n" +
            "- Pass `_windowID` as a hidden parameter on any tool call for one-shot routing"
    }

    nonisolated static func multiWindowSelectionGuidance(
        purpose: MCPRunPurpose,
        restrictedTools: Set<String>
    ) -> String {
        if purpose == .agentModeRun {
            return agentModeRoutingFailureGuidance()
        }
        if restrictedTools.contains("bind_context") {
            return restrictedConnectionRoutingFailureGuidance()
        }
        return multiWindowSelectionGuidance()
    }

    nonisolated static func invalidWindowSelectionGuidance(
        windowID: Int,
        purpose: MCPRunPurpose,
        restrictedTools: Set<String>
    ) -> String {
        if purpose == .agentModeRun {
            return "Window \(windowID) is not available for this Agent Mode run.\n" + agentModeRoutingFailureGuidance()
        }
        if restrictedTools.contains("bind_context") {
            return "Window \(windowID) is not available for this restricted MCP connection.\n" + restrictedConnectionRoutingFailureGuidance()
        }
        return "Window \(windowID) not found or MCP tools not enabled.\n" +
            "Call `bind_context` with `{\"op\":\"list\"}` to see available windows."
    }

    nonisolated static func tabBindingTroubleshooting(
        purpose: MCPRunPurpose,
        restrictedTools: Set<String>,
        windowID: Int? = nil
    ) -> [String] {
        if purpose == .agentModeRun {
            return [
                "RepoPrompt could not route this Agent Mode MCP call to the active run.",
                "Retry the tool call once. If it fails again, tell the user the RepoPrompt connection failed and ask them to restart this Agent Mode run."
            ]
        }
        if restrictedTools.contains("bind_context") {
            return [
                "RepoPrompt could not route this restricted MCP connection.",
                "Retry once. If it fails again, tell the user the RepoPrompt connection failed and ask them to restart the MCP client or Agent Mode run."
            ]
        }
        if let windowID {
            return [
                "Call `bind_context` with `{\"op\":\"list\",\"window_id\":\(windowID)}` to see available context_id values in this window.",
                "The tab may exist in a different window - verify `_windowID` is correct.",
                "Use `bind_context` with `op=bind` for explicit tab binding with validation."
            ]
        }
        return [
            "Include `_windowID` alongside `_tabID` to specify the target window.",
            "Or call `bind_context` with `{\"op\":\"bind\",\"window_id\":<window_id>}` first.",
            "Or use `bind_context` with `op=bind` and a `context_id` for sticky tab binding."
        ]
    }

    private nonisolated static func agentModeRoutingFailureGuidance() -> String {
        "RepoPrompt could not route this Agent Mode MCP call to the active run. " +
            "Retry the tool call once. If it fails again, tell the user the RepoPrompt connection failed and ask them to restart this Agent Mode run."
    }

    private nonisolated static func restrictedConnectionRoutingFailureGuidance() -> String {
        "RepoPrompt could not route this restricted MCP connection. " +
            "Retry once. If it fails again, tell the user the RepoPrompt connection failed and ask them to restart the MCP client or Agent Mode run."
    }

    private static func describeToolList(_ names: Set<String>) -> String {
        guard !names.isEmpty else { return "-" }
        return names.sorted().joined(separator: ",")
    }

    private static func describeGrantedTools(restricted: Set<String>) -> String {
        if restricted.isEmpty {
            return "all tools"
        }
        return "all except \(describeToolList(restricted))"
    }

    private var isRunningState: Bool = false
    private var lifecycleGeneration: UInt64 = 0
    private var isEnabledState: Bool = true

    // Bootstrap socket server
    private var bootstrapSocketServer: BootstrapSocketServer?
    private var bootstrapSocketServerLifecycleGeneration: UInt64?
    private var bootstrapSocketTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var bootstrapStartInProgress: Bool = false
    private var bootstrapStartLifecycleGeneration: UInt64?
    private var bootstrapRestartInProgress: Bool = false
    private var bootstrapRestartToken: UUID?
    private var bootstrapRestartLifecycleGeneration: UInt64?
    private var lastBootstrapRestartAt: Date = .distantPast
    private let bootstrapRestartMinInterval: TimeInterval = 2.0
    private var bootstrapStartFailures: Int = 0
    private var lastBootstrapHealthCheckAt: Date = .distantPast
    private let bootstrapHealthCheckInterval: TimeInterval = 5.0

    private func resolvedBootstrapSocketURL() -> URL {
        #if DEBUG
            if let testBootstrapSocketURLOverride {
                return testBootstrapSocketURLOverride
            }
        #endif
        return MCPFilesystemConstants.bootstrapSocketURL()
    }

    #if DEBUG
        enum DebugBootstrapSocketURLOverrideError: Error, Equatable {
            case managerNotFullyStopped
            case overrideAlreadyInstalled
            case overrideNotInstalled
            case overrideMismatch
            case productionSocketURLRejected
        }

        enum DebugLifecycleFenceCheckpoint: Hashable {
            case listenerPublishedBeforeStartInvocation
            case listenerStopReturnedBeforeConditionalClear
            case restartTaskBeforePerform
        }

        private var testBootstrapSocketURLOverride: URL?
        private var debugLifecycleFenceCheckpointsToSuspend: Set<DebugLifecycleFenceCheckpoint> = []
        private var debugSuspendedLifecycleFenceCheckpoints: Set<DebugLifecycleFenceCheckpoint> = []
        private var debugLifecycleFenceCheckpointResumeWaiters: [DebugLifecycleFenceCheckpoint: [CheckedContinuation<Void, Never>]] = [:]
        private var debugBootstrapRestartTaskCompletionCount = 0

        func debugInstallBootstrapSocketURLOverride(_ socketURL: URL) throws {
            try debugRequireFullyStoppedForBootstrapSocketURLOverride()
            let standardizedSocketURL = socketURL.standardizedFileURL
            guard standardizedSocketURL != MCPFilesystemConstants.bootstrapSocketURL().standardizedFileURL else {
                throw DebugBootstrapSocketURLOverrideError.productionSocketURLRejected
            }
            guard testBootstrapSocketURLOverride == nil else {
                throw DebugBootstrapSocketURLOverrideError.overrideAlreadyInstalled
            }
            testBootstrapSocketURLOverride = standardizedSocketURL
        }

        func debugRestoreBootstrapSocketURLOverride(expected socketURL: URL) throws {
            try debugRequireFullyStoppedForBootstrapSocketURLOverride()
            guard let testBootstrapSocketURLOverride else {
                throw DebugBootstrapSocketURLOverrideError.overrideNotInstalled
            }
            guard testBootstrapSocketURLOverride == socketURL.standardizedFileURL else {
                throw DebugBootstrapSocketURLOverrideError.overrideMismatch
            }
            self.testBootstrapSocketURLOverride = nil
        }

        func debugResolvedBootstrapSocketURL() -> URL {
            resolvedBootstrapSocketURL()
        }

        func debugIsEnabledForBootstrapSocketURLOverride() -> Bool {
            isEnabledState
        }

        func debugSuspendNextLifecycleFenceCheckpoint(_ checkpoint: DebugLifecycleFenceCheckpoint) {
            debugLifecycleFenceCheckpointsToSuspend.insert(checkpoint)
        }

        func debugIsLifecycleFenceCheckpointSuspended(_ checkpoint: DebugLifecycleFenceCheckpoint) -> Bool {
            debugSuspendedLifecycleFenceCheckpoints.contains(checkpoint)
        }

        func debugResumeLifecycleFenceCheckpoint(_ checkpoint: DebugLifecycleFenceCheckpoint) {
            debugLifecycleFenceCheckpointsToSuspend.remove(checkpoint)
            debugSuspendedLifecycleFenceCheckpoints.remove(checkpoint)
            let waiters = debugLifecycleFenceCheckpointResumeWaiters.removeValue(forKey: checkpoint) ?? []
            waiters.forEach { $0.resume() }
        }

        func debugResumeAllLifecycleFenceCheckpoints() {
            let checkpoints = debugLifecycleFenceCheckpointsToSuspend
                .union(debugSuspendedLifecycleFenceCheckpoints)
                .union(debugLifecycleFenceCheckpointResumeWaiters.keys)
            checkpoints.forEach { debugResumeLifecycleFenceCheckpoint($0) }
        }

        func debugLifecycleGenerationForLifecycleFenceTest() -> UInt64 {
            lifecycleGeneration
        }

        func debugBootstrapListenerLifecycleGenerationForLifecycleFenceTest() -> UInt64? {
            bootstrapSocketServerLifecycleGeneration
        }

        func debugBootstrapListenerIdentityForLifecycleFenceTest() -> ObjectIdentifier? {
            bootstrapSocketServer.map(ObjectIdentifier.init)
        }

        func debugBootstrapRestartTaskCompletionCountForLifecycleFenceTest() -> Int {
            debugBootstrapRestartTaskCompletionCount
        }

        func debugConnectionWaiterCountForLifecycleFenceTest() -> Int {
            connectionWaiters.count
        }

        func debugHasCurrentBootstrapListenerForLifecycleFenceTest() -> Bool {
            guard let bootstrapSocketServer else { return false }
            return isCurrentBootstrapListener(bootstrapSocketServer, lifecycleGeneration: lifecycleGeneration)
        }

        func debugScheduleDelayedBootstrapRestartForLifecycleFenceTest(delay: TimeInterval) -> Bool {
            lastBootstrapRestartAt = .distantPast
            let tokenBeforeRestart = bootstrapRestartToken
            restartBootstrapSocketServer(
                reason: "DEBUG lifecycle fence test",
                delay: delay,
                lifecycleGeneration: lifecycleGeneration
            )
            return bootstrapRestartToken != tokenBeforeRestart
                && bootstrapRestartLifecycleGeneration == lifecycleGeneration
        }

        private func debugSuspendLifecycleFenceCheckpointIfNeeded(_ checkpoint: DebugLifecycleFenceCheckpoint) async {
            guard debugLifecycleFenceCheckpointsToSuspend.remove(checkpoint) != nil else { return }
            debugSuspendedLifecycleFenceCheckpoints.insert(checkpoint)
            await withCheckedContinuation { continuation in
                debugLifecycleFenceCheckpointResumeWaiters[checkpoint, default: []].append(continuation)
            }
            debugSuspendedLifecycleFenceCheckpoints.remove(checkpoint)
        }

        private func debugRecordBootstrapRestartTaskCompletion() {
            debugBootstrapRestartTaskCompletionCount += 1
        }

        private func debugRequireFullyStoppedForBootstrapSocketURLOverride() throws {
            guard !isRunningState,
                  bootstrapSocketServer == nil,
                  bootstrapSocketServerLifecycleGeneration == nil,
                  bootstrapSocketTask == nil,
                  maintenanceTask == nil,
                  !bootstrapStartInProgress,
                  bootstrapStartLifecycleGeneration == nil,
                  !bootstrapRestartInProgress,
                  bootstrapRestartToken == nil,
                  bootstrapRestartLifecycleGeneration == nil,
                  debugLifecycleFenceCheckpointsToSuspend.isEmpty,
                  debugSuspendedLifecycleFenceCheckpoints.isEmpty,
                  debugLifecycleFenceCheckpointResumeWaiters.isEmpty,
                  connections.isEmpty,
                  connectionLifecycleGenerationByID.isEmpty,
                  connectionTasks.isEmpty,
                  pendingConnections.isEmpty,
                  bootstrapReservations.isEmpty,
                  bootstrapAdmissionClaimsBySessionToken.isEmpty,
                  transferredBootstrapSockets.isEmptyAndInactive,
                  connectionWaiters.isEmpty
            else {
                throw DebugBootstrapSocketURLOverrideError.managerNotFullyStopped
            }
        }

        private struct DebugConnectionEvent {
            let seq: UInt64
            let timestamp: Date
            let event: String
            let restartID: UUID?
            let connectionID: UUID?
            let clientName: String?
            let normalizedClientID: String?
            let sessionFingerprint: String?
            let windowID: Int?
            let state: String?
            let reason: String?
            let transportIngress: MCPTransportIngressSnapshot?
        }

        private struct DebugRunRoutingEvent {
            let seq: UInt64
            let timestamp: Date
            let runID: UUID
            let event: String
            let connectionID: UUID?
            let fields: [String: String]
        }

        private struct DebugRetainedTransportIngress {
            let snapshot: MCPTransportIngressSnapshot
            let clientName: String?
            let sessionToken: String?
        }

        private struct DebugRestartStatus {
            let restartID: UUID
            var state: String
            var lastError: String?
            var updatedAt: Date
        }

        private var debugConnectionHistory: [DebugConnectionEvent] = []
        private var debugConnectionHistorySeq: UInt64 = 0
        private var debugRunRoutingHistory: [DebugRunRoutingEvent] = []
        private var debugRunRoutingHistorySeq: UInt64 = 0
        private var debugRunRoutingHistoryDroppedCount = 0
        private var debugRestartStatesByID: [UUID: DebugRestartStatus] = [:]
        private var debugRetainedTransportIngressByConnectionID: [UUID: DebugRetainedTransportIngress] = [:]
        private var debugRetainedTransportIngressOrder: [UUID] = []
        private var debugRecordedTransportTerminalConnectionIDs: Set<UUID> = []
        private let debugConnectionHistoryLimit = 1000
        private let debugRunRoutingHistoryLimit = 1000
        private let debugRetainedTransportIngressLimit = 100
        private let debugRestartStatusLimit = 50
        private var debugResolvedToolOperationOverrides: [String: @Sendable () async throws -> Value] = [:]
        private var debugExecutionWatchdogAbortTargets: [UUID: any MCPServerConnection] = [:]
    #endif

    private var connections: [UUID: any MCPServerConnection] = [:]
    private var connectionsBeingRemoved: Set<UUID> = []
    private var executionWatchdogTerminalConnections: Set<UUID> = []
    private var toolExecutionWatchdogEnvironment = MCPToolExecutionWatchdogEnvironment.continuous()
    private var connectionLifecycleGenerationByID: [UUID: UInt64] = [:]
    private var bootstrapPeerPIDByConnectionID: [UUID: Int] = [:]
    private var terminalRecordClaimsByConnectionID: [UUID: MCPFirstTerminalRecordClaim] = [:]
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingConnections: [UUID: String] = [:]

    /// Callback for dashboard updates (connection changes, tool calls, etc.)
    private var onDashboardUpdate: (@Sendable () -> Void)?

    /// Sets the dashboard update callback. Called when connections are added/removed or tool calls complete.
    func setOnDashboardUpdate(_ handler: @escaping @Sendable () -> Void) {
        onDashboardUpdate = handler
    }

    /// Emits a dashboard update notification
    private func emitDashboardUpdate() {
        connectionLog("Emitting dashboard update notification")
        onDashboardUpdate?()
    }

    static func toolErrorResult(rawJSON: Bool, message: String) -> CallTool.Result {
        guard rawJSON else { return CallTool.Result.err(message) }
        let value: Value = .object([
            "is_error": .bool(true),
            "error": .string(message)
        ])
        return CallTool.Result(content: [.text(text: ToolOutputFormatter.rawJSONString(value), annotations: nil, _meta: nil)], isError: true)
    }

    static func executionContractToolErrorResult(rawJSON: Bool, code: String, message: String) -> CallTool.Result {
        guard rawJSON else { return CallTool.Result.err("\(code): \(message)") }
        let value: Value = .object([
            "is_error": .bool(true),
            "code": .string(code),
            "error": .string(message)
        ])
        return CallTool.Result(content: [.text(text: ToolOutputFormatter.rawJSONString(value), annotations: nil, _meta: nil)], isError: true)
    }

    fileprivate final class ToolEventObserverDeliveryBarrier: @unchecked Sendable {
        private let lock = NSLock()
        private var activeDeliveryCount = 0
        private var idleContinuations: [CheckedContinuation<Void, Never>] = []

        func beginDeliveries(_ count: Int = 1) {
            guard count > 0 else { return }
            lock.lock()
            activeDeliveryCount += count
            lock.unlock()
        }

        func endDelivery() {
            lock.lock()
            precondition(activeDeliveryCount > 0)
            activeDeliveryCount -= 1
            guard activeDeliveryCount == 0 else {
                lock.unlock()
                return
            }
            let continuations = idleContinuations
            idleContinuations.removeAll(keepingCapacity: true)
            lock.unlock()
            continuations.forEach { $0.resume() }
        }

        func waitUntilIdle() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard activeDeliveryCount > 0 else {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                idleContinuations.append(continuation)
                lock.unlock()
            }
        }
    }

    private struct ToolObserverUnregistrationState {
        let id: UUID
        let task: Task<Void, Never>
    }

    /// Enhanced tool observer that receives args on call and result on completion.
    /// The manager acquires delivery leases for the captured batch before its first
    /// suspension so unregistration can await callbacks that have not entered yet.
    struct ToolEventObserver: @unchecked Sendable {
        let onCalled: @Sendable (_ invocationID: UUID, _ toolName: String, _ args: [String: Value]?) async -> Void
        let onCompleted: (@Sendable (_ invocationID: UUID, _ toolName: String, _ args: [String: Value]?, _ resultJSON: String, _ isError: Bool) async -> Void)?
        fileprivate let deliveryBarrier = ToolEventObserverDeliveryBarrier()
    }

    private var toolEventObservers: [UUID: [UUID: ToolEventObserver]] = [:]
    private var toolObserverUnregistrationsByRunID: [UUID: ToolObserverUnregistrationState] = [:]
    #if DEBUG
        private var debugBeforeToolEventObserverDeliveryForTesting: (@Sendable () async -> Void)?
    #endif

    // Per-connection restriction + routing state
    private var restrictedToolsByConnection: [UUID: Set<String>] = [:]
    private var additionalToolsByConnection: [UUID: Set<String>] = [:]
    private var runPurposeByConnection: [UUID: MCPRunPurpose] = [:]
    private var windowAssignmentByConnection: [UUID: Int] = [:]
    private var preassignedConnections: Set<UUID> = []

    /// Tracks the window count at the time each connection was established.
    /// Connections established during single-window mode are auto-bound to that window
    /// and stay bound even when multi-window mode becomes active.
    private var windowCountAtConnectionTime: [UUID: Int] = [:]

    /// Snapshot describing a temporary routing/restriction rule for an incoming client connection.
    /// Policies are queued via `installClientConnectionPolicy`, enforced on the next admitted connection
    /// for the matching client/window combination, and cleared automatically after either a one-shot run
    /// or an explicit `clearClientConnectionPolicy` call. `windowID` preserves routing for multi-window
    /// scenarios, while `restrictedTools` and `ttl` gate which tool APIs the connection may invoke before
    /// the policy expires. This keeps Context Builder sandboxes from leaking into shared MCP sessions yet
    /// still allows intentional overrides when necessary.
    private struct ClientConnectionPolicy {
        let id: UUID
        let windowID: Int
        let restrictedTools: Set<String>
        let oneShot: Bool
        let reason: String?
        let createdAt: Date
        let ttl: TimeInterval
        // Tab context for Context Builder agents
        let tabID: UUID?
        let runID: UUID?
        /// Additional tools to expose for this connection (policy-gated tools like ask_user)
        let additionalTools: Set<String>?
        /// Purpose of this run (for UI routing)
        let purpose: MCPRunPurpose
        /// Task label kind for role-aware tool advertisement filtering
        let taskLabelKind: AgentModelCatalog.TaskLabelKind?
        /// Whether role-aware advertisement should allow agent_run/agent_manage for this run
        let allowsAgentExternalControlTools: Bool
        /// When true, only an MCP peer whose verified PID descends from a registered
        /// expected agent PID may consume this queued policy.
        var requiresExpectedAgentPID: Bool
        /// One-shot policies stay queued but unavailable while route installation awaits.
        var reservationConnectionID: UUID?
    }

    /// Run-scoped policy state captured when the first connection for a run is admitted.
    /// Used to rehydrate later handover/reconnect connections from server-maintained run mapping.
    private struct RunConnectionPolicyState {
        let windowID: Int
        let workspaceID: UUID?
        let tabID: UUID?
        let restrictedTools: Set<String>
        let additionalTools: Set<String>?
        let purpose: MCPRunPurpose
        let taskLabelKind: AgentModelCatalog.TaskLabelKind?
        let allowsAgentExternalControlTools: Bool
        let updatedAt: Date
    }

    /// Same-process live reconnect affinity keyed by MCP client name + capability token.
    /// The capability token identifies one `repoprompt-mcp` helper process lease. While the
    /// matching run policy remains live, that token is pinned to the run and may only reconnect
    /// to the same run. A different run must use a fresh helper/token.
    private struct LiveRunAffinity {
        let windowID: Int
        let runID: UUID
        let purpose: MCPRunPurpose
        let lastSeenAt: Date
    }

    private enum AgentPolicyAdmissionReadiness: Equatable {
        case notRequired
        case ready
        case timedOut
    }

    private enum PendingPolicyApplicationOutcome: Equatable {
        case applied(runID: UUID?)
        case fallback
        case rejected(runID: UUID?, reason: String)
    }

    private struct PendingPolicyRestorePoint {
        let restrictedTools: Set<String>?
        let additionalTools: Set<String>?
        let runPurpose: MCPRunPurpose?
        let windowID: Int?
        let windowAssignment: Int?
        let runID: UUID?
        let wasPreassigned: Bool
        let wasRunAdmitted: Bool
        let runPolicyState: RunConnectionPolicyState?
        let runWindowID: Int?
    }

    private var pendingPoliciesByClient: [String: [ClientConnectionPolicy]] = [:]
    #if DEBUG
        private var debugShouldSuspendNextPendingPolicyRouteInstallation = false
        private var debugPendingPolicyRouteInstallationIsSuspended = false
        private var debugPendingPolicyRouteInstallationResumeWaiters: [CheckedContinuation<Void, Never>] = []
        private var debugShouldSuspendNextPendingPolicyCommit = false
        private var debugPendingPolicyCommitIsSuspended = false
        private var debugPendingPolicyCommitResumeWaiters: [CheckedContinuation<Void, Never>] = []
        private var debugPendingPolicyReplacementSchedules: [(existing: UUID, replacement: UUID, runID: UUID)] = []
    #endif
    private var expectedAgentPIDsByClient: [String: Set<pid_t>] = [:]
    private var expectedAgentPIDsByRunID: [UUID: Set<pid_t>] = [:]
    private var runPolicyStateByRunID: [UUID: RunConnectionPolicyState] = [:]
    private var admittedPolicyRunIDs: Set<UUID> = []
    private var windowIDByRunID: [UUID: Int] = [:]
    private var pendingPolicyApplicationIDByConnectionID: [UUID: UUID] = [:]
    private var pendingPolicyApplicationIDByRunID: [UUID: UUID] = [:]

    // 🆕 Per-connection → windowID routing map
    private var connectionWindowMap: [UUID: Int] = [:]
    private var runIDByConnectionID: [UUID: UUID] = [:]

    private struct MCPConnectionCallLimiterWatchdogDiagnostics {
        let admittedCallCount: Int
    }

    private actor MCPConnectionCallLimiters {
        struct AdmissionRejected: Error {}

        private enum AdmissionCloseState {
            case open
            case tentative
            case restored(MCPConnectionCallLimiters)
            case committed
        }

        private let ordinary: AsyncLimiter
        private let control: AsyncLimiter
        private let smallRead: AsyncLimiter
        private let gitRead: AsyncLimiter
        private let fileSearch: AsyncLimiter
        private var admittedCallCount = 0
        private var admissionCloseState: AdmissionCloseState = .open
        private var admissionRetryWaiters: [UUID: CheckedContinuation<MCPConnectionCallLimiters?, Never>] = [:]

        #if DEBUG
            init(
                limit: Int,
                controlLimit: Int,
                smallReadLimit: Int,
                gitReadLimit: Int,
                fileSearchLimit: Int,
                idleWaitSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
                    try await Task.sleep(for: duration)
                }
            ) {
                ordinary = AsyncLimiter(limit: limit, idleWaitSleep: idleWaitSleep)
                control = AsyncLimiter(limit: controlLimit, idleWaitSleep: idleWaitSleep)
                smallRead = AsyncLimiter(limit: smallReadLimit, idleWaitSleep: idleWaitSleep)
                gitRead = AsyncLimiter(limit: gitReadLimit, idleWaitSleep: idleWaitSleep)
                fileSearch = AsyncLimiter(limit: fileSearchLimit, idleWaitSleep: idleWaitSleep)
            }
        #else
            init(limit: Int, controlLimit: Int, smallReadLimit: Int, gitReadLimit: Int, fileSearchLimit: Int) {
                ordinary = AsyncLimiter(limit: limit)
                control = AsyncLimiter(limit: controlLimit)
                smallRead = AsyncLimiter(limit: smallReadLimit)
                gitRead = AsyncLimiter(limit: gitReadLimit)
                fileSearch = AsyncLimiter(limit: fileSearchLimit)
            }
        #endif

        func withPermit<T>(
            lane: MCPConnectionCallLane,
            cancellationResult: @Sendable () -> T,
            _ operation: @Sendable () async -> T
        ) async -> T {
            guard case .open = admissionCloseState else { return cancellationResult() }
            admittedCallCount += 1
            defer { admittedCallCount -= 1 }
            return await limiter(for: lane).withPermit(
                cancellationResult: cancellationResult,
                operation
            )
        }

        func withPermit<T>(
            lane: MCPConnectionCallLane,
            toolName: String? = nil,
            lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation? = nil,
            ownerResource: String? = nil,
            ownerWindowID: Int? = nil,
            ownerRunID: String? = nil,
            _ operation: @Sendable () async throws -> T
        ) async throws -> T {
            guard case .open = admissionCloseState else { throw AdmissionRejected() }
            admittedCallCount += 1
            defer { admittedCallCount -= 1 }

            let laneLimiter = limiter(for: lane)
            #if DEBUG
                let queuedSnapshot = await laneLimiter.debugSnapshot()
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.MCPToolCall.permitQueued,
                    correlation: lifecycleCorrelation,
                    EditFlowPerf.Dimensions(
                        toolName: toolName,
                        outcome: "queued",
                        activeCount: queuedSnapshot.activePermitCount,
                        admissionClass: lane.rawValue,
                        queueDepth: queuedSnapshot.waiterCount + (queuedSnapshot.permits == 0 ? 1 : 0),
                        windowID: ownerWindowID,
                        runID: ownerRunID,
                        ownerResource: ownerResource,
                        permitActive: false,
                        publicationPending: false,
                        terminalBarrier: false
                    )
                )
            #endif

            do {
                let result = try await laneLimiter.withPermit {
                    #if DEBUG
                        let acquiredSnapshot = await laneLimiter.debugSnapshot()
                        EditFlowPerf.lifecycleEvent(
                            EditFlowPerf.Lifecycle.MCPToolCall.permitAcquired,
                            correlation: lifecycleCorrelation,
                            EditFlowPerf.Dimensions(
                                toolName: toolName,
                                outcome: "acquired",
                                activeCount: acquiredSnapshot.activePermitCount,
                                admissionClass: lane.rawValue,
                                queueDepth: acquiredSnapshot.waiterCount,
                                windowID: ownerWindowID,
                                runID: ownerRunID,
                                ownerResource: ownerResource,
                                permitActive: true,
                                publicationPending: false,
                                terminalBarrier: false
                            )
                        )
                    #endif
                    return try await operation()
                }
                #if DEBUG
                    await recordPermitReleased(
                        laneLimiter: laneLimiter,
                        lane: lane,
                        toolName: toolName,
                        lifecycleCorrelation: lifecycleCorrelation,
                        ownerResource: ownerResource,
                        ownerWindowID: ownerWindowID,
                        ownerRunID: ownerRunID,
                        outcome: "completed"
                    )
                #endif
                return result
            } catch {
                #if DEBUG
                    await recordPermitReleased(
                        laneLimiter: laneLimiter,
                        lane: lane,
                        toolName: toolName,
                        lifecycleCorrelation: lifecycleCorrelation,
                        ownerResource: ownerResource,
                        ownerWindowID: ownerWindowID,
                        ownerRunID: ownerRunID,
                        outcome: error is CancellationError ? "cancelled" : "failed"
                    )
                #endif
                throw error
            }
        }

        #if DEBUG
            private func recordPermitReleased(
                laneLimiter: AsyncLimiter,
                lane: MCPConnectionCallLane,
                toolName: String?,
                lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?,
                ownerResource: String?,
                ownerWindowID: Int?,
                ownerRunID: String?,
                outcome: String
            ) async {
                let releasedSnapshot = await laneLimiter.debugSnapshot()
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.MCPToolCall.permitReleased,
                    correlation: lifecycleCorrelation,
                    EditFlowPerf.Dimensions(
                        toolName: toolName,
                        outcome: outcome,
                        activeCount: releasedSnapshot.activePermitCount,
                        admissionClass: lane.rawValue,
                        queueDepth: releasedSnapshot.waiterCount,
                        windowID: ownerWindowID,
                        runID: ownerRunID,
                        ownerResource: ownerResource,
                        permitActive: false,
                        publicationPending: true,
                        terminalBarrier: false
                    )
                )
            }
        #endif

        func hasInFlightCalls() -> Bool {
            admittedCallCount > 0
        }

        func executionWatchdogDiagnostics() -> MCPConnectionCallLimiterWatchdogDiagnostics {
            MCPConnectionCallLimiterWatchdogDiagnostics(admittedCallCount: admittedCallCount)
        }

        func admissionRetryReplacement() async -> MCPConnectionCallLimiters? {
            guard !Task.isCancelled else { return nil }
            switch admissionCloseState {
            case .open, .committed:
                return nil
            case let .restored(replacement):
                return replacement
            case .tentative:
                return await waitForAdmissionCloseOutcome()
            }
        }

        func markTentativeCloseRestored(by replacement: MCPConnectionCallLimiters) {
            guard case .tentative = admissionCloseState else { return }
            admissionCloseState = .restored(replacement)
            resumeAdmissionRetryWaiters(with: replacement)
        }

        func markTentativeCloseCommitted() {
            guard case .tentative = admissionCloseState else { return }
            admissionCloseState = .committed
            resumeAdmissionRetryWaiters(with: nil)
        }

        func cancelAll() async {
            switch admissionCloseState {
            case .open, .tentative:
                admissionCloseState = .committed
                resumeAdmissionRetryWaiters(with: nil)
            case .restored, .committed:
                break
            }
            await closeLanes()
        }

        #if DEBUG
            func closeIfIdle(
                afterClosingBegan: (@Sendable () async -> Void)? = nil
            ) async -> Bool {
                guard case .open = admissionCloseState, admittedCallCount == 0 else { return false }
                admissionCloseState = .tentative
                if let afterClosingBegan {
                    await afterClosingBegan()
                }
                await closeLanes()
                return true
            }
        #else
            func closeIfIdle() async -> Bool {
                guard case .open = admissionCloseState, admittedCallCount == 0 else { return false }
                admissionCloseState = .tentative
                await closeLanes()
                return true
            }
        #endif

        func waitUntilIdle(timeout: Duration) async -> [(MCPConnectionCallLane, Bool)] {
            await withTaskGroup(of: (MCPConnectionCallLane, Bool).self) { group in
                for (lane, limiter) in lanes {
                    group.addTask {
                        await (lane, limiter.waitUntilIdle(timeout: timeout))
                    }
                }
                var results: [(MCPConnectionCallLane, Bool)] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
        }

        #if DEBUG
            func limiterForTesting(_ lane: MCPConnectionCallLane) -> AsyncLimiter {
                limiter(for: lane)
            }

            func diagnosticsSnapshot() async -> MCPConnectionCallLimiterDebugSnapshot {
                async let ordinarySnapshot = ordinary.debugSnapshot()
                async let controlSnapshot = control.debugSnapshot()
                async let smallReadSnapshot = smallRead.debugSnapshot()
                async let gitReadSnapshot = gitRead.debugSnapshot()
                async let fileSearchSnapshot = fileSearch.debugSnapshot()
                return await MCPConnectionCallLimiterDebugSnapshot(
                    ordinary: ordinarySnapshot,
                    control: controlSnapshot,
                    smallRead: smallReadSnapshot,
                    gitRead: gitReadSnapshot,
                    fileSearch: fileSearchSnapshot
                )
            }

            func diagnosticsSnapshot(for lane: MCPConnectionCallLane) async -> AsyncLimiter.DebugSnapshot {
                await limiter(for: lane).debugSnapshot()
            }

            func admissionRetryWaiterCountForTesting() -> Int {
                admissionRetryWaiters.count
            }
        #endif

        private func waitForAdmissionCloseOutcome() async -> MCPConnectionCallLimiters? {
            let waiterID = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }
                    switch admissionCloseState {
                    case .open, .committed:
                        continuation.resume(returning: nil)
                    case let .restored(replacement):
                        continuation.resume(returning: replacement)
                    case .tentative:
                        admissionRetryWaiters[waiterID] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelAdmissionRetryWaiter(waiterID) }
            }
        }

        private func cancelAdmissionRetryWaiter(_ waiterID: UUID) {
            admissionRetryWaiters.removeValue(forKey: waiterID)?.resume(returning: nil)
        }

        private func resumeAdmissionRetryWaiters(with replacement: MCPConnectionCallLimiters?) {
            let waiters = Array(admissionRetryWaiters.values)
            admissionRetryWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(returning: replacement)
            }
        }

        private func closeLanes() async {
            async let cancelOrdinary: Void = ordinary.cancelAll()
            async let cancelControl: Void = control.cancelAll()
            async let cancelSmallRead: Void = smallRead.cancelAll()
            async let cancelGitRead: Void = gitRead.cancelAll()
            async let cancelFileSearch: Void = fileSearch.cancelAll()
            _ = await (cancelOrdinary, cancelControl, cancelSmallRead, cancelGitRead, cancelFileSearch)
        }

        private func limiter(for lane: MCPConnectionCallLane) -> AsyncLimiter {
            switch lane {
            case .ordinary:
                ordinary
            case .control:
                control
            case .smallRead:
                smallRead
            case .gitRead:
                gitRead
            case .fileSearch:
                fileSearch
            }
        }

        private var lanes: [(MCPConnectionCallLane, AsyncLimiter)] {
            [
                (.ordinary, ordinary),
                (.control, control),
                (.smallRead, smallRead),
                (.gitRead, gitRead),
                (.fileSearch, fileSearch)
            ]
        }
    }

    // 🆕 Admission control
    private var activeConnectionsByClient: [String: Set<UUID>] = [:]
    private var clientIDByConnection: [UUID: String] = [:]
    private var callLimiters: [UUID: MCPConnectionCallLimiters] = [:]

    private nonisolated let mutationAdmissionController = MCPToolResourceAdmissionController(
        limit: MCPToolAdmissionPolicy.exclusiveConnectionLimit
    )
    private nonisolated let smallReadAdmissionController = MCPToolResourceAdmissionController(
        limit: MCPToolAdmissionPolicy.smallReadPerWindowLimit
    )
    private nonisolated let toolCardOwnershipLedger = MCPToolCardOwnershipLedger()
    #if DEBUG
        private var debugAfterDirectAdmissionPendingPublishedForTesting: (@Sendable (UUID) async -> Void)?
        private var debugAfterBootstrapPolicyReadinessForTesting: (@Sendable (String) async -> Void)?
        private var debugAfterConnectionCallLimiterResolutionForTesting: (@Sendable (UUID) async -> Void)?
        private var debugAfterConnectionCallPermitAcquiredForTesting: (@Sendable (UUID) async -> Void)?
        private var debugAfterConnectionCallLimiterRejectionForTesting: (@Sendable (UUID) async -> Void)?
        private var debugBeforeToolResultFormattingForTesting: (@Sendable (UUID, String) async -> Void)?
        private var debugBeforeToolCompletionObserversForTesting: (@Sendable (UUID, String) async -> Void)?
        private var debugBeforeAdmissionEvictionCloseForTesting: (@Sendable (UUID) async -> Void)?
        private var debugBeforeActiveToolCancellationScanForTesting: (@Sendable (UUID, [UUID]) async -> Void)?
        private var debugAllocatedActiveToolScopeIDsForTesting: Set<UUID> = []
        private var debugDuringAdmissionEvictionCloseForTesting: (@Sendable (UUID) async -> Void)?
        private var debugAfterAdmissionEvictionRemovalCommittedForTesting: (@Sendable (UUID) async -> Void)?
        private var debugBootstrapPredecessorStopGraceSleepForTesting: (@Sendable (Duration) async throws -> Void)?
        private var debugMaxGlobalConnectionsForTesting: Int?
        private var debugMaxConnectionsPerClientForTesting: Int?
        private var debugPreserveOnePerClientForTesting: Bool?
        private var debugPressureEvictIdleSecondsForTesting: Int?
    #endif

    /// 🆕 Routing persistence: per-connection metadata
    /// Session key (capabilityToken) for disambiguating multiple client instances
    private var capabilityTokenByConnection: [UUID: String] = [:]
    /// Reverse lookup for session token → connection ID (bootstrap socket)
    private var connectionIDBySessionToken: [String: UUID] = [:]
    /// Monotonic token-binding generation used to prevent replacement credit from transferring
    /// or resurrecting after a durable session token is rebound.
    private var sessionTokenBindingGeneration: [String: UInt64] = [:]
    /// Persisted routing state (survives app restarts)
    private var routingState: MCPRoutingState = MCPRoutingStateStore.load()
    /// In-memory last window selection per (clientID, sessionKey) for quick access
    /// Outer key is clientID, inner key is sessionKey -> windowID
    private var lastWindowByClientSession: [String: [String: Int]] = [:]
    /// Same-process live run reconnect affinity keyed by (clientID, sessionKey).
    private var liveRunAffinityByClientSession: [String: [String: LiveRunAffinity]] = [:]
    #if DEBUG
        private var debugExactRoutingSessionRestorePoints: [UUID: DebugExactRoutingSessionFixtureRestorePoint] = [:]
    #endif
    /// TTL for routing records (24 hours)
    private let routingRecordTTL: TimeInterval = 24 * 60 * 60

    // MARK: - Killed Session Tracking

    /// Session tokens (capabilityTokens) that were explicitly killed from the dashboard.
    /// These sessions should not be allowed to reconnect - the CLI should exit instead of retrying.
    private var killedSessionTokens: Set<String> = []

    /// Expiration time for killed session entries (1 hour - long enough for CLI to exit, not permanent)
    private let killedSessionTTL: TimeInterval = 3600

    /// Tracks when each session was killed for TTL-based cleanup
    private var killedSessionTimestamps: [String: Date] = [:]

    /// ClientIDs (e.g., "claude-ai") that were recently killed by user action from the dashboard.
    /// Brief cooldown to prevent immediate auto-reconnection by the host (e.g., Claude Code).
    private var userKilledClientIDs: [String: Date] = [:]

    /// Cooldown period for user-killed clientIDs (5 seconds - just enough to prevent auto-reconnect race)
    private let userKilledClientCooldown: TimeInterval = 5.0

    // MARK: - Identity Context & Failure Escalation

    /// Tracks how identity was derived for each connection
    private struct ConnectionIdentityContext {
        enum Source {
            case unknown // nothing yet
            case filesystemMeta // from meta.json
            case handshake // from MCP initialize
        }

        var clientName: String?
        var capabilityToken: String?
        var source: Source
        var hasHandshake: Bool
        var lastUpdated: Date
    }

    /// Identity context per connection
    private var identityContextByConnection: [UUID: ConnectionIdentityContext] = [:]

    /// Identity failure escalation tracking
    private var identityFailureWindowStart: Date?
    private var identityFailureCount: Int = 0
    private let identityFailureWindow: TimeInterval = 300 // 5 min
    private let identityFailureThreshold: Int = 3 // 3 failures in 5 min triggers escalation

    /// Callback to notify higher layers (ServerController) of identity escalation
    typealias IdentityEscalationHandler = @Sendable (_ reason: String) -> Void
    private var identityEscalationHandler: IdentityEscalationHandler?

    /// Sets the identity escalation callback
    func setOnIdentityEscalation(_ handler: @escaping IdentityEscalationHandler) {
        identityEscalationHandler = handler
    }

    /// Sets a hook for dashboard updates (tool ownership, connection changes, etc.)
    func setDashboardDidChangeHook(_ hook: @escaping @Sendable () -> Void) {
        dashboardDidChangeHook = hook
    }

    /// 🆕 Connection waiter continuations (replaces polling in waitForNewConnection)
    private struct ConnectionWaiter {
        let lifecycleGeneration: UInt64
        let clientName: String?
        let excludeExisting: Set<UUID>
        let continuation: CheckedContinuation<UUID?, Never>
        var timeoutTask: Task<Void, Never>?
    }

    private var connectionWaiters: [UUID: ConnectionWaiter] = [:]

    /// Exact active-tool scopes per window. Every scope has an identity so overlapping
    /// connections, cancellation cleanup, and deferred completions cannot clear each other.
    private struct ActiveToolScopeRecord {
        let connectionID: UUID
        let toolName: String
        let sequence: UInt64
    }

    private struct ActiveToolScopeHandle {
        let windowID: Int
        let scopeID: UUID
    }

    struct WindowToolDispatchIdentity: @unchecked Sendable {
        let windowID: Int
        let windowStateIdentity: ObjectIdentifier
        let serverViewModelIdentity: ObjectIdentifier
        let catalogServiceIdentity: ObjectIdentifier
    }

    struct ToolDispatchAuthorization: @unchecked Sendable {
        let connectionID: UUID
        let connectionIdentity: ObjectIdentifier
        let lifecycleGeneration: UInt64
        let windowIdentity: WindowToolDispatchIdentity?
    }

    enum ToolDispatchAdmissionError: Error {
        case connectionTerminal
        case windowTerminal
    }

    private var activeToolScopesByWindow: [Int: [UUID: ActiveToolScopeRecord]] = [:]
    private var activeToolScopeSequence: UInt64 = 0
    private var dashboardDidChangeHook: (@Sendable () -> Void)?

    /// ─────────────  Connection value/stats (for admission fairness)  ─────────────
    private struct ConnectionStats {
        let createdAt: Date
        var totalToolCalls: Int
        var lastToolCallAt: Date?
    }

    private var connectionStats: [UUID: ConnectionStats] = [:]

    /// ─────────────  Tool call history (for dashboard display)  ─────────────
    struct ToolCallHistoryEntry {
        let timestamp: Date
        let toolName: String
        let clientName: String
        let connectionID: UUID
    }

    private var recentToolCallHistory: [ToolCallHistoryEntry] = []
    private let maxToolCallHistoryCount = 5
    private struct ToolSchemaCacheKey: Hashable {
        let name: String
        let purpose: MCPRunPurpose
    }

    private var toolSchemaCache: [ToolSchemaCacheKey: Value] = [:]
    /// Tracks bootstrap connections that have been accepted but not yet committed (registered).
    /// This prevents burst scenarios where multiple concurrent accepts could exceed maxGlobalConnections.
    private struct BootstrapAdmissionClaim {
        let connectionID: UUID
        let lifecycleGeneration: UInt64
        var replacementCredit: BootstrapReplacementCredit?
    }

    private struct BootstrapReplacementCredit {
        let sessionToken: String
        let predecessorConnectionID: UUID
        let predecessorConnectionIdentity: ObjectIdentifier
        let predecessorLifecycleGeneration: UInt64
        let tokenBindingGeneration: UInt64
    }

    private struct BootstrapReservation {
        let connectionID: UUID
        let lifecycleGeneration: UInt64
        let sessionToken: String
        var createdAt: Date
        var replacementCredit: BootstrapReplacementCredit?
        var committingConnection: BootstrapSocketConnectionManager?

        var isCommitting: Bool {
            committingConnection != nil
        }
    }

    private struct GlobalAdmissionLoadSnapshot {
        let registeredConnectionCount: Int
        let reservationCount: Int
        let creditedPredecessorConnectionIDs: Set<UUID>

        var replacementCreditCount: Int {
            creditedPredecessorConnectionIDs.count
        }

        var effectiveLoad: Int {
            registeredConnectionCount + reservationCount - replacementCreditCount
        }
    }

    private var bootstrapAdmissionClaimsBySessionToken: [String: BootstrapAdmissionClaim] = [:]
    private var bootstrapReservations: [UUID: BootstrapReservation] = [:]
    /// Synchronously visible ownership for transferred bootstrap sockets that are
    /// awaiting deferred actor registration.
    private let transferredBootstrapSockets = BootstrapTransferredSocketLedger()
    /// Safety-net TTL for reservations (should be released via commit/rollback, but this catches edge cases).
    /// Use a generous value to avoid expiring legitimate reservations under load.
    private let bootstrapReservationTTL: TimeInterval = 60.0

    private func captureBootstrapReplacementCredit(
        sessionToken: String
    ) -> BootstrapReplacementCredit? {
        guard let predecessorConnectionID = currentBootstrapReplacementConnectionID(
            forSessionToken: sessionToken
        ),
            let predecessor = connections[predecessorConnectionID],
            !predecessor.isFilesystemBacked,
            let predecessorLifecycleGeneration = connectionLifecycleGenerationByID[predecessorConnectionID],
            isCurrentLifecycle(predecessorLifecycleGeneration),
            capabilityTokenByConnection[predecessorConnectionID] == sessionToken
        else { return nil }
        return BootstrapReplacementCredit(
            sessionToken: sessionToken,
            predecessorConnectionID: predecessorConnectionID,
            predecessorConnectionIdentity: ObjectIdentifier(predecessor as AnyObject),
            predecessorLifecycleGeneration: predecessorLifecycleGeneration,
            tokenBindingGeneration: sessionTokenBindingGeneration[sessionToken, default: 0]
        )
    }

    private func isCurrentBootstrapAdmissionClaim(
        sessionToken: String,
        connectionID: UUID,
        lifecycleGeneration: UInt64
    ) -> Bool {
        guard let claim = bootstrapAdmissionClaimsBySessionToken[sessionToken] else { return false }
        return claim.connectionID == connectionID
            && claim.lifecycleGeneration == lifecycleGeneration
    }

    private func isValidBootstrapReplacementCredit(
        _ credit: BootstrapReplacementCredit,
        reservationConnectionID: UUID,
        reservationLifecycleGeneration: UInt64
    ) -> Bool {
        guard credit.sessionToken.isEmpty == false,
              isCurrentLifecycle(reservationLifecycleGeneration),
              isCurrentBootstrapAdmissionClaim(
                  sessionToken: credit.sessionToken,
                  connectionID: reservationConnectionID,
                  lifecycleGeneration: reservationLifecycleGeneration
              ),
              sessionTokenBindingGeneration[credit.sessionToken, default: 0] == credit.tokenBindingGeneration,
              connectionIDBySessionToken[credit.sessionToken] == credit.predecessorConnectionID,
              capabilityTokenByConnection[credit.predecessorConnectionID] == credit.sessionToken,
              !connectionsBeingRemoved.contains(credit.predecessorConnectionID),
              connectionLifecycleGenerationByID[credit.predecessorConnectionID] == credit.predecessorLifecycleGeneration,
              let predecessor = connections[credit.predecessorConnectionID],
              !predecessor.isFilesystemBacked
        else { return false }
        return ObjectIdentifier(predecessor as AnyObject) == credit.predecessorConnectionIdentity
    }

    private func isLiveBootstrapReservation(_ reservation: BootstrapReservation) -> Bool {
        // Expired reservations continue consuming capacity until cleanup atomically removes
        // the reservation, releases its claim, and closes any transferred descriptor.
        reservation.lifecycleGeneration == lifecycleGeneration
    }

    /// Global admission load shared by direct and bootstrap admission.
    /// Registered predecessors and their valid replacement reservations count once.
    /// A prospective bootstrap credit is included only for the pre-reservation capacity check;
    /// the prospective reservation itself is represented by the caller's `< cap` requirement.
    private func globalAdmissionLoadSnapshot(
        prospectiveReplacementCredit: BootstrapReplacementCredit? = nil
    ) -> GlobalAdmissionLoadSnapshot {
        let now = Date()
        let liveReservations = bootstrapReservations.values.filter {
            isLiveBootstrapReservation($0)
        }
        var creditedPredecessorsByIdentity: [ObjectIdentifier: UUID] = [:]
        for reservation in liveReservations {
            guard reservation.isCommitting || now.timeIntervalSince(reservation.createdAt) < bootstrapReservationTTL,
                  let credit = reservation.replacementCredit,
                  isValidBootstrapReplacementCredit(
                      credit,
                      reservationConnectionID: reservation.connectionID,
                      reservationLifecycleGeneration: reservation.lifecycleGeneration
                  )
            else { continue }
            creditedPredecessorsByIdentity[credit.predecessorConnectionIdentity] = credit.predecessorConnectionID
        }
        if let prospectiveReplacementCredit,
           let claim = bootstrapAdmissionClaimsBySessionToken[prospectiveReplacementCredit.sessionToken],
           isValidBootstrapReplacementCredit(
               prospectiveReplacementCredit,
               reservationConnectionID: claim.connectionID,
               reservationLifecycleGeneration: claim.lifecycleGeneration
           )
        {
            creditedPredecessorsByIdentity[
                prospectiveReplacementCredit.predecessorConnectionIdentity
            ] = prospectiveReplacementCredit.predecessorConnectionID
        }
        return GlobalAdmissionLoadSnapshot(
            registeredConnectionCount: effectiveRegisteredConnectionCount,
            reservationCount: liveReservations.count,
            creditedPredecessorConnectionIDs: Set(creditedPredecessorsByIdentity.values)
        )
    }

    private func effectiveGlobalAdmissionLoad(
        prospectiveReplacementCredit: BootstrapReplacementCredit? = nil
    ) -> Int {
        globalAdmissionLoadSnapshot(
            prospectiveReplacementCredit: prospectiveReplacementCredit
        ).effectiveLoad
    }

    private func creditedBootstrapPredecessorConnectionIDs(
        prospectiveReplacementCredit: BootstrapReplacementCredit? = nil
    ) -> Set<UUID> {
        var protectedConnectionIDs = globalAdmissionLoadSnapshot(
            prospectiveReplacementCredit: prospectiveReplacementCredit
        ).creditedPredecessorConnectionIDs
        for claim in bootstrapAdmissionClaimsBySessionToken.values {
            guard let credit = claim.replacementCredit,
                  isValidBootstrapReplacementCredit(
                      credit,
                      reservationConnectionID: claim.connectionID,
                      reservationLifecycleGeneration: claim.lifecycleGeneration
                  )
            else { continue }
            protectedConnectionIDs.insert(credit.predecessorConnectionID)
        }
        return protectedConnectionIDs
    }

    private func invalidateBootstrapReplacementCredits(
        sessionToken: String? = nil,
        predecessorConnectionID: UUID? = nil
    ) {
        for claimSessionToken in Array(bootstrapAdmissionClaimsBySessionToken.keys) {
            guard var claim = bootstrapAdmissionClaimsBySessionToken[claimSessionToken],
                  let credit = claim.replacementCredit,
                  sessionToken == nil || credit.sessionToken == sessionToken,
                  predecessorConnectionID == nil || credit.predecessorConnectionID == predecessorConnectionID
            else { continue }
            claim.replacementCredit = nil
            bootstrapAdmissionClaimsBySessionToken[claimSessionToken] = claim
        }
        for reservationID in Array(bootstrapReservations.keys) {
            guard var reservation = bootstrapReservations[reservationID],
                  let credit = reservation.replacementCredit,
                  sessionToken == nil || credit.sessionToken == sessionToken,
                  predecessorConnectionID == nil || credit.predecessorConnectionID == predecessorConnectionID
            else { continue }
            reservation.replacementCredit = nil
            bootstrapReservations[reservationID] = reservation
        }
    }

    private func claimBootstrapAdmission(
        sessionToken: String,
        connectionID: UUID,
        lifecycleGeneration: UInt64
    ) -> Bool {
        guard bootstrapAdmissionClaimsBySessionToken[sessionToken] == nil else { return false }
        let replacementCredit = captureBootstrapReplacementCredit(sessionToken: sessionToken)
        bootstrapAdmissionClaimsBySessionToken[sessionToken] = BootstrapAdmissionClaim(
            connectionID: connectionID,
            lifecycleGeneration: lifecycleGeneration,
            replacementCredit: replacementCredit
        )
        return true
    }

    private func releaseBootstrapAdmissionClaim(
        sessionToken: String,
        connectionID: UUID,
        lifecycleGeneration: UInt64
    ) {
        guard isCurrentBootstrapAdmissionClaim(
            sessionToken: sessionToken,
            connectionID: connectionID,
            lifecycleGeneration: lifecycleGeneration
        ) else { return }
        invalidateBootstrapReplacementCredits(sessionToken: sessionToken)
        bootstrapAdmissionClaimsBySessionToken.removeValue(forKey: sessionToken)
    }

    /// Reserve a slot for an incoming bootstrap connection (called before returning .accept).
    /// The durable-token claim must already belong to this exact admission.
    private func reserveBootstrapSlot(
        connectionID: UUID,
        lifecycleGeneration: UInt64,
        sessionToken: String
    ) -> Bool {
        guard let claim = bootstrapAdmissionClaimsBySessionToken[sessionToken],
              claim.connectionID == connectionID,
              claim.lifecycleGeneration == lifecycleGeneration
        else { return false }
        let validReplacementCredit = claim.replacementCredit.flatMap { credit in
            isValidBootstrapReplacementCredit(
                credit,
                reservationConnectionID: connectionID,
                reservationLifecycleGeneration: lifecycleGeneration
            ) ? credit : nil
        }
        bootstrapReservations[connectionID] = BootstrapReservation(
            connectionID: connectionID,
            lifecycleGeneration: lifecycleGeneration,
            sessionToken: sessionToken,
            createdAt: Date(),
            replacementCredit: validReplacementCredit,
            committingConnection: nil
        )
        return true
    }

    @discardableResult
    private func takeBootstrapReservation(
        connectionID: UUID,
        lifecycleGeneration: UInt64
    ) -> BootstrapReservation? {
        guard let reservation = bootstrapReservations[connectionID],
              reservation.lifecycleGeneration == lifecycleGeneration
        else { return nil }
        bootstrapReservations.removeValue(forKey: connectionID)
        releaseBootstrapAdmissionClaim(
            sessionToken: reservation.sessionToken,
            connectionID: connectionID,
            lifecycleGeneration: lifecycleGeneration
        )
        return reservation
    }

    /// Release a bootstrap reservation when an accepted handshake aborts before commit.
    private func rollbackBootstrapReservation(connectionID: UUID, lifecycleGeneration: UInt64, reason: String) async {
        let reservation = takeBootstrapReservation(
            connectionID: connectionID,
            lifecycleGeneration: lifecycleGeneration
        )
        if reservation != nil {
            connectionLog("Bootstrap connection \(connectionID) rolled back (\(reason))")
        } else if isRunningState {
            log.warning("rollbackBootstrapReservation: no matching reservation found for \(connectionID) while running (reason=\(reason))")
        } else {
            connectionLog("Bootstrap connection \(connectionID) rollback found no matching reservation after shutdown (\(reason))")
        }
        closeTransferredBootstrapSocket(
            connectionID: connectionID,
            lifecycleGeneration: lifecycleGeneration
        )
        await reservation?.committingConnection?.stop()
    }

    private func closeTransferredBootstrapSocket(connectionID: UUID, lifecycleGeneration: UInt64) {
        guard let fd = transferredBootstrapSockets.remove(
            connectionID: connectionID,
            lifecycleGeneration: lifecycleGeneration
        ) else { return }
        closeUnregisteredBootstrapFD(fd)
    }

    private func closeUnregisteredBootstrapFD(_ fd: Int32) {
        POSIXDescriptorSupport.shutdownSocketReadWrite(fd)
        Darwin.close(fd)
    }

    /// Clean up expired reservations (safety net for edge cases)
    private func cleanupExpiredBootstrapReservations() {
        let now = Date()
        let expired = bootstrapReservations.filter {
            !$0.value.isCommitting
                && now.timeIntervalSince($0.value.createdAt) >= bootstrapReservationTTL
        }
        if !expired.isEmpty {
            let expiredIDs = expired.map(\.key.uuidString).joined(separator: ", ")
            log.warning("Cleaning up \(expired.count) expired bootstrap reservations (indicates a bug or crash): \(expiredIDs)")
            for id in expired.keys {
                guard let reservation = bootstrapReservations.removeValue(forKey: id) else { continue }
                releaseBootstrapAdmissionClaim(
                    sessionToken: reservation.sessionToken,
                    connectionID: id,
                    lifecycleGeneration: reservation.lifecycleGeneration
                )
                closeTransferredBootstrapSocket(
                    connectionID: id,
                    lifecycleGeneration: reservation.lifecycleGeneration
                )
            }
        }
    }

    private func defaultsInt(_ key: String, _ def: Int) -> Int {
        let v = UserDefaults.standard.integer(forKey: key)
        return v > 0 ? v : def
    }

    private var maxGlobalConnections: Int {
        #if DEBUG
            if let debugMaxGlobalConnectionsForTesting {
                return debugMaxGlobalConnectionsForTesting
            }
        #endif
        return defaultsInt("mcp.maxGlobalConnections", 128)
    }

    private var maxConnectionsPerClient: Int {
        #if DEBUG
            if let debugMaxConnectionsPerClientForTesting {
                return debugMaxConnectionsPerClientForTesting
            }
        #endif
        return defaultsInt("mcp.maxConnectionsPerClient", 64)
    }

    private var maxCallsPerConnection: Int {
        defaultsInt("mcp.maxCallsPerConnection", 8)
    }

    private var pressureEvictIdleSeconds: Int {
        #if DEBUG
            if let debugPressureEvictIdleSecondsForTesting {
                return debugPressureEvictIdleSecondsForTesting
            }
        #endif
        return defaultsInt("mcp.pressureEvictIdleSeconds", 7200)
    } // 2h
    private var connectingTimeoutSeconds: Int {
        defaultsInt("mcp.connectingTimeoutSeconds", 60)
    }

    private var preserveOnePerClient: Bool {
        #if DEBUG
            if let debugPreserveOnePerClientForTesting {
                return debugPreserveOnePerClientForTesting
            }
        #endif
        return (UserDefaults.standard.object(forKey: "mcp.preserveOnePerClient") as? Bool) ?? true
    }

    /// 🆕 Task-local keys to expose current routing hints inside tool calls
    @TaskLocal
    static var currentConnectionID: UUID?
    @TaskLocal
    static var currentTabContextHint: MCPServerViewModel.TabContextHint?
    @TaskLocal
    static var currentToolDispatchAuthorization: ToolDispatchAuthorization?

    // ------------------------------------------------------------------
    // MARK: Tool ownership tracking helpers

    /// ------------------------------------------------------------------
    private func beginActiveToolScope(
        windowID: Int,
        connectionID: UUID,
        toolName: String,
        scopeID requestedScopeID: UUID? = nil
    ) -> ActiveToolScopeHandle? {
        guard !connectionsBeingRemoved.contains(connectionID) else { return nil }

        let scopeID: UUID
        if let requestedScopeID {
            #if DEBUG
                guard debugAllocatedActiveToolScopeIDsForTesting.insert(requestedScopeID).inserted else { return nil }
            #else
                guard !containsActiveToolScope(scopeID: requestedScopeID) else { return nil }
            #endif
            scopeID = requestedScopeID
        } else {
            var generatedScopeID = UUID()
            while containsActiveToolScope(scopeID: generatedScopeID) {
                generatedScopeID = UUID()
            }
            scopeID = generatedScopeID
        }

        precondition(activeToolScopeSequence < UInt64.max, "Active-tool scope sequence exhausted")
        activeToolScopeSequence += 1
        activeToolScopesByWindow[windowID, default: [:]][scopeID] = ActiveToolScopeRecord(
            connectionID: connectionID,
            toolName: toolName,
            sequence: activeToolScopeSequence
        )
        connectionLog(
            "Tool '\(toolName)' scope \(scopeID) marked for connection \(connectionID) on window \(windowID) (sequence=\(activeToolScopeSequence))"
        )
        dashboardDidChangeHook?()
        return ActiveToolScopeHandle(windowID: windowID, scopeID: scopeID)
    }

    private func containsActiveToolScope(scopeID: UUID) -> Bool {
        activeToolScopesByWindow.values.contains { $0[scopeID] != nil }
    }

    @discardableResult
    private func endActiveToolScope(_ handle: ActiveToolScopeHandle) -> Bool {
        guard var scopes = activeToolScopesByWindow[handle.windowID],
              let removed = scopes.removeValue(forKey: handle.scopeID)
        else { return false }

        if scopes.isEmpty {
            activeToolScopesByWindow.removeValue(forKey: handle.windowID)
        } else {
            activeToolScopesByWindow[handle.windowID] = scopes
        }
        connectionLog(
            "Tool '\(removed.toolName)' scope \(handle.scopeID) cleared for connection \(removed.connectionID) on window \(handle.windowID)"
        )
        dashboardDidChangeHook?()
        return true
    }

    @discardableResult
    private func removeActiveToolScopes(_ scopeIDsByWindow: [Int: Set<UUID>]) -> Int {
        var removedCount = 0
        for (windowID, scopeIDs) in scopeIDsByWindow {
            guard var scopes = activeToolScopesByWindow[windowID] else { continue }
            for scopeID in scopeIDs where scopes.removeValue(forKey: scopeID) != nil {
                removedCount += 1
            }
            if scopes.isEmpty {
                activeToolScopesByWindow.removeValue(forKey: windowID)
            } else {
                activeToolScopesByWindow[windowID] = scopes
            }
        }
        if removedCount > 0 {
            dashboardDidChangeHook?()
        }
        return removedCount
    }

    @discardableResult
    private func removeActiveToolScopesForWindow(_ windowID: Int) -> Int {
        guard let removed = activeToolScopesByWindow.removeValue(forKey: windowID) else { return 0 }
        dashboardDidChangeHook?()
        return removed.count
    }

    private func activeToolScopeIDs(ownedBy connectionID: UUID) -> [Int: Set<UUID>] {
        var result: [Int: Set<UUID>] = [:]
        for (windowID, scopes) in activeToolScopesByWindow {
            for (scopeID, scope) in scopes where scope.connectionID == connectionID {
                result[windowID, default: []].insert(scopeID)
            }
        }
        return result
    }

    private func hasActiveToolScopes(ownedBy connectionID: UUID) -> Bool {
        activeToolScopesByWindow.values.contains { scopes in
            scopes.values.contains { $0.connectionID == connectionID }
        }
    }

    private func preferredActiveToolScope(
        connectionID: UUID,
        assignedWindowID: Int?,
        scopesByWindow: [Int: [UUID: ActiveToolScopeRecord]]
    ) -> ConnectionDashboardActiveToolScope? {
        if let assignedWindowID,
           let assignedScope = scopesByWindow[assignedWindowID]?.values
           .filter({ $0.connectionID == connectionID })
           .max(by: { $0.sequence < $1.sequence })
        {
            return ConnectionDashboardActiveToolScope(
                windowID: assignedWindowID,
                toolName: assignedScope.toolName,
                sequence: assignedScope.sequence
            )
        }

        var newestScope: ConnectionDashboardActiveToolScope?
        for (windowID, scopes) in scopesByWindow {
            for scope in scopes.values where scope.connectionID == connectionID {
                if newestScope == nil || scope.sequence > newestScope!.sequence {
                    newestScope = ConnectionDashboardActiveToolScope(
                        windowID: windowID,
                        toolName: scope.toolName,
                        sequence: scope.sequence
                    )
                }
            }
        }
        return newestScope
    }

    private func cancelActiveToolsOwnedByConnection(
        _ connectionID: UUID,
        reason: String
    ) async -> Int {
        // Capture exact scope identities before the MainActor hop. Actor reentrancy may admit
        // newer same-connection scopes while the identity-bound VM cancellation scan runs.
        let capturedScopeIDsByWindow = activeToolScopeIDs(ownedBy: connectionID)
        #if DEBUG
            if let debugBeforeActiveToolCancellationScanForTesting {
                let capturedScopeIDs = capturedScopeIDsByWindow.values
                    .flatMap(\.self)
                    .sorted { $0.uuidString < $1.uuidString }
                await debugBeforeActiveToolCancellationScanForTesting(connectionID, capturedScopeIDs)
            }
        #endif

        let cancelledCount = await MainActor.run { () -> Int in
            // The VM API is identity-bound, so it is safe to scan all windows. This avoids
            // missing tools routed via a per-call _windowID override that differs from the
            // connection's sticky/default assigned window.
            WindowStatesManager.shared.allWindows.reduce(into: 0) { partialResult, window in
                partialResult += window.mcpServer.cancelActiveToolsForConnection(
                    connectionID: connectionID,
                    reason: reason
                )
            }
        }

        _ = removeActiveToolScopes(capturedScopeIDsByWindow)
        return cancelledCount
    }

    private func captureWindowToolDispatchIdentity(
        windowID: Int,
        catalogServiceIdentity: ObjectIdentifier
    ) async -> WindowToolDispatchIdentity? {
        await MainActor.run {
            guard let window = WindowStatesManager.shared.window(withID: windowID),
                  !window.isClosing,
                  ServiceRegistry.services.contains(where: {
                      ObjectIdentifier($0 as AnyObject) == catalogServiceIdentity
                  })
            else { return nil }
            return WindowToolDispatchIdentity(
                windowID: windowID,
                windowStateIdentity: ObjectIdentifier(window),
                serverViewModelIdentity: ObjectIdentifier(window.mcpServer),
                catalogServiceIdentity: catalogServiceIdentity
            )
        }
    }

    private func isCurrentWindowToolDispatchIdentity(
        _ identity: WindowToolDispatchIdentity,
        expectedServerViewModelIdentity: ObjectIdentifier? = nil
    ) async -> Bool {
        await MainActor.run {
            guard identity.windowID > 0,
                  let window = WindowStatesManager.shared.window(withID: identity.windowID),
                  !window.isClosing,
                  ObjectIdentifier(window) == identity.windowStateIdentity,
                  ObjectIdentifier(window.mcpServer) == identity.serverViewModelIdentity,
                  ServiceRegistry.services.contains(where: {
                      ObjectIdentifier($0 as AnyObject) == identity.catalogServiceIdentity
                  })
            else { return false }
            if let expectedServerViewModelIdentity {
                return ObjectIdentifier(window.mcpServer) == expectedServerViewModelIdentity
            }
            return true
        }
    }

    func validateToolDispatchAuthorization(
        _ authorization: ToolDispatchAuthorization,
        expectedWindowID: Int,
        expectedServerViewModelIdentity: ObjectIdentifier
    ) async -> Bool {
        guard authorization.connectionID == Self.currentConnectionID,
              isCurrentToolDispatchAuthorization(authorization),
              let windowIdentity = authorization.windowIdentity,
              windowIdentity.windowID == expectedWindowID
        else { return false }
        return await isCurrentWindowToolDispatchIdentity(
            windowIdentity,
            expectedServerViewModelIdentity: expectedServerViewModelIdentity
        )
    }

    private func isCurrentToolDispatchAuthorization(
        _ authorization: ToolDispatchAuthorization
    ) -> Bool {
        guard !connectionsBeingRemoved.contains(authorization.connectionID),
              !executionWatchdogTerminalConnections.contains(authorization.connectionID),
              isCurrentLifecycle(authorization.lifecycleGeneration),
              connectionLifecycleGenerationByID[authorization.connectionID] == authorization.lifecycleGeneration,
              let connection = connections[authorization.connectionID]
        else { return false }
        return ObjectIdentifier(connection as AnyObject) == authorization.connectionIdentity
    }

    /// Run `op` while recording this exact active-tool scope for `windowID`.
    /// The exact scope ID is always removed, even if `op` throws or broader cleanup ran first.
    func withWindowToolOwnership<T>(
        windowID: Int,
        connectionID: UUID,
        toolName: String,
        connectionAuthorization: ToolDispatchAuthorization? = nil,
        windowIdentity: WindowToolDispatchIdentity? = nil,
        recordScope: Bool = true,
        _ op: @Sendable () async throws -> T
    ) async throws -> T {
        guard !connectionsBeingRemoved.contains(connectionID),
              connectionAuthorization.map(isCurrentToolDispatchAuthorization) ?? true
        else {
            throw ToolDispatchAdmissionError.connectionTerminal
        }
        if let windowIdentity {
            guard windowIdentity.windowID == windowID,
                  await isCurrentWindowToolDispatchIdentity(windowIdentity)
            else {
                throw ToolDispatchAdmissionError.windowTerminal
            }
        }
        if !recordScope {
            guard !connectionsBeingRemoved.contains(connectionID),
                  connectionAuthorization.map(isCurrentToolDispatchAuthorization) ?? true
            else {
                throw ToolDispatchAdmissionError.connectionTerminal
            }
            return try await op()
        }
        guard !connectionsBeingRemoved.contains(connectionID),
              connectionAuthorization.map(isCurrentToolDispatchAuthorization) ?? true,
              let scope = beginActiveToolScope(
                  windowID: windowID,
                  connectionID: connectionID,
                  toolName: toolName
              )
        else {
            throw ToolDispatchAdmissionError.connectionTerminal
        }
        defer {
            endActiveToolScope(scope)
        }
        return try await op()
    }

    // ------------------------------------------------------------------
    // MARK: Window-selection helpers (called from WindowRoutingService)

    /// ------------------------------------------------------------------
    func setActiveWindowForCurrentConnection(_ windowID: Int) async throws {
        guard let connID = Self.currentConnectionID else {
            throw MCPError.internalError("No active connection context")
        }
        setConnectionWindowMapping(connID, windowID: windowID)
    }

    func clearActiveWindowForCurrentConnection() async throws {
        guard let connID = Self.currentConnectionID else {
            throw MCPError.internalError("No active connection context")
        }
        clearConnectionWindowMapping(connID)
        clearPersistedWindowAffinity(for: connID)
    }

    func selectedWindow(for connectionID: UUID) -> Int? {
        connectionWindowMap[connectionID]
    }

    private func setConnectionWindowMapping(_ connectionID: UUID, windowID: Int) {
        connectionWindowMap[connectionID] = windowID
        windowAssignmentByConnection[connectionID] = windowID

        // Update per-client memory and persist routing (token-backed only)
        guard let clientID = clientIdentifier(forConnection: connectionID) else { return }

        // Resolve sessionKey - only update in-memory map for token-backed clients
        let sessionKey = connections[connectionID]?.capabilityToken ?? capabilityTokenByConnection[connectionID]
        if let sessionKey {
            let storageKey = bestStorageKey(for: clientID, in: Array(lastWindowByClientSession.keys))
            lastWindowByClientSession[storageKey, default: [:]][sessionKey] = windowID
        }

        Task { [weak self] in
            await self?.updateRoutingRecordForConnection(connectionID, clientID: clientID)
        }
    }

    private func clearConnectionWindowMapping(_ connectionID: UUID) {
        connectionWindowMap.removeValue(forKey: connectionID)
        windowAssignmentByConnection.removeValue(forKey: connectionID)
    }

    private func clearPersistedWindowAffinity(for connectionID: UUID) {
        guard let clientID = clientIdentifier(forConnection: connectionID) else { return }
        guard let sessionKey = connections[connectionID]?.capabilityToken ?? capabilityTokenByConnection[connectionID] else {
            return
        }

        for key in matchingClientKeys(for: clientID, in: Array(lastWindowByClientSession.keys)) {
            if var sessionMap = lastWindowByClientSession[key] {
                sessionMap.removeValue(forKey: sessionKey)
                if sessionMap.isEmpty {
                    lastWindowByClientSession.removeValue(forKey: key)
                } else {
                    lastWindowByClientSession[key] = sessionMap
                }
            }
        }

        var stateChanged = false
        for key in matchingClientKeys(for: clientID, in: Array(routingState.records.keys)) {
            guard var records = routingState.records[key] else { continue }
            var changed = false
            for index in records.indices {
                guard records[index].sessionKey == sessionKey, records[index].lastWindowID != nil else { continue }
                records[index].lastWindowID = nil
                changed = true
            }
            guard changed else { continue }
            routingState.records[key] = records
            stateChanged = true
        }
        guard stateChanged else { return }
        saveRoutingState()
    }

    private func effectivePolicyState(for connectionID: UUID) -> (restricted: Set<String>, additional: Set<String>, preassigned: Bool, purpose: MCPRunPurpose, taskLabelKind: AgentModelCatalog.TaskLabelKind?, allowsAgentExternalControlTools: Bool) {
        let restricted = restrictedToolsByConnection[connectionID] ?? []
        let additional = additionalToolsByConnection[connectionID] ?? []
        let preassigned = preassignedConnections.contains(connectionID)
        let purpose = runPurposeByConnection[connectionID] ?? .unknown
        let runState: RunConnectionPolicyState? = {
            guard let runID = runIDByConnectionID[connectionID] else { return nil }
            return runPolicyStateByRunID[runID]
        }()
        let taskLabelKind = runState?.taskLabelKind
        let allowsAgentExternalControlTools = runState?.allowsAgentExternalControlTools ?? false
        return (restricted, additional, preassigned, purpose, taskLabelKind, allowsAgentExternalControlTools)
    }

    #if DEBUG
        private func debugPolicyDiagnosticFields(
            connectionID: UUID,
            policy: (restricted: Set<String>, additional: Set<String>, preassigned: Bool, purpose: MCPRunPurpose, taskLabelKind: AgentModelCatalog.TaskLabelKind?, allowsAgentExternalControlTools: Bool)? = nil,
            extra: [String: String] = [:]
        ) -> [String: String] {
            let effective = policy ?? effectivePolicyState(for: connectionID)
            let runID = runIDByConnectionID[connectionID]
            let runState = runID.flatMap { runPolicyStateByRunID[$0] }
            var fields = extra
            fields["connectionID"] = connectionID.uuidString
            fields["runID"] = runID?.uuidString ?? "nil"
            fields["tabID"] = runState?.tabID?.uuidString ?? "nil"
            fields["windowID"] = connectionWindowMap[connectionID].map(String.init) ?? runState.map { String($0.windowID) } ?? "nil"
            fields["purpose"] = effective.purpose.rawValue
            fields["taskLabel"] = effective.taskLabelKind?.rawValue ?? "nil"
            fields["additionalTools"] = Self.debugDescribeToolSet(effective.additional)
            fields["restrictedTools"] = Self.debugDescribeToolSet(effective.restricted)
            fields["preassigned"] = String(effective.preassigned)
            fields["allowsAgentExternalControlTools"] = String(effective.allowsAgentExternalControlTools)
            fields["hasRunPolicy"] = String(runState != nil)
            return fields
        }

        private static func debugDescribeToolSet(_ tools: Set<String>) -> String {
            guard !tools.isEmpty else { return "[]" }
            return "[" + tools.sorted().joined(separator: ",") + "]"
        }

        private func debugPolicyDiagnostic(_ name: String, connectionID: UUID, policy: (restricted: Set<String>, additional: Set<String>, preassigned: Bool, purpose: MCPRunPurpose, taskLabelKind: AgentModelCatalog.TaskLabelKind?, allowsAgentExternalControlTools: Bool)? = nil, extra: [String: String] = [:]) {
            AgentModePerfDiagnostics.event(
                "mcp.policy.\(name)",
                fields: debugPolicyDiagnosticFields(connectionID: connectionID, policy: policy, extra: extra)
            )
        }
    #endif

    func clearWindowSelectionIfClosed(_ windowID: Int) {
        let toClear = connectionWindowMap.filter { $0.value == windowID }.map(\.key)
        for cid in toClear {
            connectionWindowMap[cid] = nil
            windowAssignmentByConnection[cid] = nil // Keep both maps consistent
            runIDByConnectionID[cid] = nil
        }

        // Window close authoritatively removes this bucket; deferred exact-ID completions are no-ops.
        removeActiveToolScopesForWindow(windowID)

        // Remove stale run→window cache entries for the closed window.
        let staleRunIDs = windowIDByRunID.compactMap { runID, mappedWindowID in
            mappedWindowID == windowID ? runID : nil
        }
        for runID in staleRunIDs {
            windowIDByRunID.removeValue(forKey: runID)
        }
        if !staleRunIDs.isEmpty {
            let staleRunIDSet = Set(staleRunIDs)
            let staleConnections = runIDByConnectionID.compactMap { connectionID, runID in
                staleRunIDSet.contains(runID) ? connectionID : nil
            }
            for connectionID in staleConnections {
                runIDByConnectionID.removeValue(forKey: connectionID)
            }
        }
        dashboardDidChangeHook?()

        // Remove in-memory mapping to this window (nested structure: clientID -> sessionKey -> windowID)
        let clientIDs = Array(lastWindowByClientSession.keys)
        for clientID in clientIDs {
            guard var sessionMap = lastWindowByClientSession[clientID] else { continue }
            let sessionsToClear = sessionMap.filter { $0.value == windowID }.map(\.key)
            for sessionKey in sessionsToClear {
                sessionMap.removeValue(forKey: sessionKey)
            }
            if sessionMap.isEmpty {
                lastWindowByClientSession.removeValue(forKey: clientID)
            } else {
                lastWindowByClientSession[clientID] = sessionMap
            }
        }

        // Update routingState.records to null out invalid lastWindowID
        var stateChanged = false
        let recordKeys = Array(routingState.records.keys)
        for clientID in recordKeys {
            guard let records = routingState.records[clientID] else { continue }
            var changed = false
            let updated = records.map { record -> MCPRoutingState.ClientRecord in
                var r = record
                if r.lastWindowID == windowID {
                    r.lastWindowID = nil
                    changed = true
                }
                return r
            }
            if changed {
                routingState.records[clientID] = updated
                stateChanged = true
            }
        }
        if stateChanged {
            saveRoutingState()
        }
    }

    /// Ensures a connection has a window binding when the choice is unambiguous.
    /// This provides a single-window fallback for early protocol calls (tools/list, handshake)
    /// that occur before explicit window selection.
    ///
    /// Returns the effective window ID if binding is unambiguous, nil if multi-window ambiguity exists.
    ///
    /// Binding logic:
    /// 1. If connection already has a mapping → use it
    /// 2. If exactly one MCP-enabled window exists → bind to it
    /// 3. If connection was established during single-window mode → bind to first MCP-enabled window
    /// 4. If multi-window mode is not effectively active → bind to first MCP-enabled window
    /// 5. Otherwise → nil (multi-window ambiguous, caller should fail closed or prompt selection)
    private func ensureWindowBindingIfUnambiguous(connectionID: UUID, reason: String) async -> Int? {
        // Check existing mapping first
        if let existing = connectionWindowMap[connectionID] {
            return existing
        }

        // Get window state on MainActor
        let (mcpEnabledWindows, multiWindowEffective) = await MainActor.run {
            let windows = WindowStatesManager.shared.allWindows.filter(\.mcpServer.windowToolsEnabled)
            let effective = WindowStatesManager.shared.isMultiWindowModeEffectivelyActive
            return (windows, effective)
        }

        // Single MCP-enabled window → unambiguous binding
        if mcpEnabledWindows.count == 1, let window = mcpEnabledWindows.first {
            let windowID = window.windowID
            setConnectionWindowMapping(connectionID, windowID: windowID)
            connectionLog("\(reason): auto-bound connection \(connectionID) to single MCP-enabled window \(windowID)")
            return windowID
        }

        // Connection established during single-window mode stays bound.
        // If capture is missing, treat as unknown and only infer single-window when
        // current mode is also effectively single-window.
        let connectedDuringSingleWindow: Bool
        if let recordedWindowCount = windowCountAtConnectionTime[connectionID] {
            connectedDuringSingleWindow = recordedWindowCount == 1
        } else {
            connectedDuringSingleWindow = !multiWindowEffective && mcpEnabledWindows.count <= 1
            if multiWindowEffective {
                connectionLog("\(reason): missing connection-time window count for \(connectionID); treating as multi-window")
            }
        }
        if connectedDuringSingleWindow || !multiWindowEffective {
            if let firstWindow = await WindowStatesManager.shared.firstMCPEnabledWindow() {
                let windowID = firstWindow.windowID
                setConnectionWindowMapping(connectionID, windowID: windowID)
                let bindReason = connectedDuringSingleWindow ? "single-window-at-connect" : "single-window-mode"
                connectionLog("\(reason): auto-bound connection \(connectionID) to window \(windowID) (\(bindReason))")
                return windowID
            }
        }

        // Multi-window ambiguous - caller must handle
        connectionLog("\(reason): connection \(connectionID) has no unambiguous window binding (multi-window active)")
        return nil
    }

    // ------------------------------------------------------------------

    func currentClientIdentifier() -> String? {
        guard let connectionID = Self.currentConnectionID else { return nil }
        if let admitted = clientIDByConnection[connectionID] {
            return admitted
        }
        if let pending = pendingConnections[connectionID] {
            return pending
        }
        return nil
    }

    func currentConnectionWindowID() -> Int? {
        guard let connectionID = Self.currentConnectionID else { return nil }
        return connectionWindowMap[connectionID]
    }

    func currentConnectionUUID() -> UUID? {
        Self.currentConnectionID
    }

    private func requestTimelineConnectionGeneration(for connectionID: UUID) -> UInt64? {
        connectionLifecycleGenerationByID[connectionID]
    }

    /// Runs the given async operation with the TaskLocal connectionID and lifecycle correlation set.
    /// Use this to propagate the connection context across Task boundaries.
    nonisolated static func withConnectionID<T>(
        _ connectionID: UUID?,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation? = nil,
        operation: () async throws -> T
    ) async rethrows -> T {
        #if DEBUG || EDIT_FLOW_PERF
            let effectiveLifecycleCorrelation = lifecycleCorrelation ?? EditFlowPerf.currentLifecycleCorrelation
            guard let effectiveLifecycleCorrelation else {
                return try await $currentConnectionID.withValue(connectionID, operation: operation)
            }
            return try await EditFlowPerf.$currentLifecycleCorrelation.withValue(effectiveLifecycleCorrelation) {
                try await $currentConnectionID.withValue(connectionID, operation: operation)
            }
        #else
            return try await $currentConnectionID.withValue(connectionID, operation: operation)
        #endif
    }

    func clientIdentifier(forConnection id: UUID) -> String? {
        if let admitted = clientIDByConnection[id] {
            return admitted
        }
        if let pending = pendingConnections[id] {
            return pending
        }
        return nil
    }

    /// Returns the run purpose for a connection, used for UI routing (e.g., ask_user).
    func runPurpose(for connectionID: UUID) -> MCPRunPurpose {
        runPurposeByConnection[connectionID] ?? .unknown
    }

    func setRunPurpose(_ purpose: MCPRunPurpose, for connectionID: UUID) {
        runPurposeByConnection[connectionID] = purpose
    }

    func hasCachedRunPolicyState(for runID: UUID) -> Bool {
        runPolicyStateByRunID[runID] != nil
    }

    func cachedRunPolicyWindowID(for runID: UUID) -> Int? {
        runPolicyStateByRunID[runID]?.windowID
    }

    private func reusableWindowForClient(newConnectionID: UUID, clientName: String) async -> Int? {
        for (existingID, windowID) in connectionWindowMap where existingID != newConnectionID {
            guard MCPClientIdentity.matches(clientIDByConnection[existingID], clientName) else { continue }
            if let existingManager = connections[existingID] {
                let existingViable = await existingManager.isViableForRetention()
                if existingViable {
                    // Existing connection is healthy; do not auto-route the newcomer.
                    return nil
                } else {
                    return windowID
                }
            } else {
                return windowID
            }
        }
        return nil
    }

    /// Get the runID associated with a connection (if any)
    /// Fast path uses actor-local cache; fallback scans all windows for resilient recovery.
    func runIDForConnection(_ connectionID: UUID) async -> UUID? {
        if let cachedRunID = runIDByConnectionID[connectionID] {
            return cachedRunID
        }

        let resolved = await MainActor.run { () -> (runID: UUID, windowID: Int)? in
            for window in WindowStatesManager.shared.allWindows {
                guard let candidateRunID = window.mcpServer.connectionIDToRunID[connectionID],
                      let runID = Self.validatedLiveRunID(
                          candidateRunID: candidateRunID,
                          connectionID: connectionID,
                          connectionIDByRunID: window.mcpServer.connectionIDByRunID,
                          connectionIDToRunID: window.mcpServer.connectionIDToRunID
                      )
                else {
                    continue
                }
                return (runID, window.windowID)
            }
            return nil
        }
        guard let resolved else {
            connectionLog("runIDForConnection: no run mapping found for connection \(connectionID)")
            return nil
        }

        runIDByConnectionID[connectionID] = resolved.runID
        windowIDByRunID[resolved.runID] = resolved.windowID
        return resolved.runID
    }

    func toolTrackingRunIDForCompletion(
        callTimeRunID: UUID?,
        connectionID: UUID,
        toolName: String,
        invocationID: UUID,
        context: String
    ) async -> UUID? {
        if let callTimeRunID {
            if MCPIntegrationHelper.isRepoPromptToolNameAfterNormalization(toolName),
               let completionTimeRunID = await runIDForConnection(connectionID),
               completionTimeRunID != callTimeRunID
            {
                mcpToolTrackingDiagnostic(
                    "MCP observer completion runID changed context=\(context) conn=\(connectionID.uuidString) " +
                        "tool=\(toolName) invocation=\(invocationID.uuidString) " +
                        "callRunID=\(callTimeRunID.uuidString) completionRunID=\(completionTimeRunID.uuidString) " +
                        "usingCallTimeRunID=true"
                )
            }
            return callTimeRunID
        }

        let completionTimeRunID = await runIDForConnection(connectionID)
        if let completionTimeRunID {
            if MCPIntegrationHelper.isRepoPromptToolNameAfterNormalization(toolName) {
                mcpToolTrackingDiagnostic(
                    "MCP observer completion re-resolved runID context=\(context) conn=\(connectionID.uuidString) " +
                        "tool=\(toolName) invocation=\(invocationID.uuidString) " +
                        "runID=\(completionTimeRunID.uuidString)"
                )
            }
            return completionTimeRunID
        }

        if MCPIntegrationHelper.isRepoPromptToolNameAfterNormalization(toolName) {
            mcpToolTrackingDiagnostic(
                "MCP observer completion skipped no runID context=\(context) conn=\(connectionID.uuidString) " +
                    "tool=\(toolName) invocation=\(invocationID.uuidString)"
            )
        }
        return nil
    }

    /// Map a connection to a runID for server-managed reconnect/handover scenarios.
    /// This creates the connectionID → runID mapping that enables tool tracking across connections.
    @discardableResult
    func mapConnectionToRunID(
        _ connectionID: UUID,
        runID: UUID,
        windowID explicitWindowID: Int? = nil,
        persistWindowBinding: Bool = true,
        signalRouting: Bool = true
    ) async -> Bool {
        let resolvedWindowID: Int? = if let explicitWindowID {
            explicitWindowID
        } else if let mappedWindowID = connectionWindowMap[connectionID] {
            mappedWindowID
        } else {
            await windowIDForRunID(runID)
        }
        guard let windowID = resolvedWindowID else {
            log.warning("mapConnectionToRunID: cannot map connection \(connectionID) to run \(runID) - no window assignment")
            return false
        }

        // Fast path: if this connection is already mapped to this run in this window,
        // avoid re-registering and re-binding on every tool call.
        let alreadyMapped = await MainActor.run { () -> Bool in
            guard let window = WindowStatesManager.shared.window(withID: windowID) else {
                return false
            }
            let mappedRun = window.mcpServer.connectionIDToRunID[connectionID]
            let mappedConnection = window.mcpServer.connectionID(forRunID: runID)
            return mappedRun == runID && mappedConnection == connectionID
        }
        if alreadyMapped {
            if signalRouting {
                await MCPRoutingWaiter.notifyRouted(runID: runID)
            }
            if persistWindowBinding, connectionWindowMap[connectionID] != windowID {
                setConnectionWindowMapping(connectionID, windowID: windowID)
            }
            if persistWindowBinding {
                runIDByConnectionID[connectionID] = runID
            }
            windowIDByRunID[runID] = windowID
            return true
        }

        let registrationSucceeded = await MainActor.run { () -> Bool in
            guard let window = WindowStatesManager.shared.window(withID: windowID) else {
                log.warning("mapConnectionToRunID: window \(windowID) not found for connection \(connectionID)")
                return false
            }

            // Update bidirectional mappings in MCPServerViewModel
            let didRegister = window.mcpServer.registerRunIDMapping(
                connectionID: connectionID,
                runID: runID,
                windowID: windowID,
                signalRouting: signalRouting
            )
            if didRegister {
                connectionLog("mapConnectionToRunID: mapped connection \(connectionID) to runID \(runID) in window \(windowID)")
            }
            return didRegister
        }
        guard registrationSucceeded else {
            log.warning("mapConnectionToRunID: registerRunIDMapping refused connection \(connectionID) run \(runID) window \(windowID)")
            return false
        }

        if persistWindowBinding, connectionWindowMap[connectionID] != windowID {
            setConnectionWindowMapping(connectionID, windowID: windowID)
        }
        if persistWindowBinding {
            runIDByConnectionID[connectionID] = runID
        }
        windowIDByRunID[runID] = windowID
        updateLiveRunAffinity(
            clientName: clientIdentifier(forConnection: connectionID) ?? "",
            sessionKey: connections[connectionID]?.capabilityToken ?? capabilityTokenByConnection[connectionID],
            runID: runID,
            windowID: windowID,
            purpose: runPurposeByConnection[connectionID] ?? runPolicyStateByRunID[runID]?.purpose
        )

        // Rehydrate run-scoped policy grants/restrictions on reconnect handovers.
        await applyRunPolicyStateIfAvailable(
            runID: runID,
            connectionID: connectionID,
            persistWindowBinding: persistWindowBinding
        )
        return true
    }

    private func mapConnectionToRunIDForPendingPolicy(
        _ connectionID: UUID,
        runID: UUID,
        windowID: Int
    ) async -> MCPServerViewModel.PendingPolicyRunIDMappingToken? {
        let token = await MainActor.run { () -> MCPServerViewModel.PendingPolicyRunIDMappingToken? in
            guard let window = WindowStatesManager.shared.window(withID: windowID) else {
                log.warning("mapConnectionToRunIDForPendingPolicy: window \(windowID) not found for connection \(connectionID)")
                return nil
            }
            return window.mcpServer.registerPendingPolicyRunIDMapping(
                connectionID: connectionID,
                runID: runID,
                windowID: windowID
            )
        }
        guard let token else {
            log.warning("mapConnectionToRunIDForPendingPolicy: registration refused connection \(connectionID) run \(runID) window \(windowID)")
            return nil
        }

        if connectionWindowMap[connectionID] != windowID {
            setConnectionWindowMapping(connectionID, windowID: windowID)
        }
        runIDByConnectionID[connectionID] = runID
        windowIDByRunID[runID] = windowID
        updateLiveRunAffinity(
            clientName: clientIdentifier(forConnection: connectionID) ?? "",
            sessionKey: connections[connectionID]?.capabilityToken ?? capabilityTokenByConnection[connectionID],
            runID: runID,
            windowID: windowID,
            purpose: runPurposeByConnection[connectionID] ?? runPolicyStateByRunID[runID]?.purpose
        )
        await applyRunPolicyStateIfAvailable(
            runID: runID,
            connectionID: connectionID,
            persistWindowBinding: true
        )
        return token
    }

    private func seedRunPolicyState(
        runID: UUID,
        windowID: Int,
        workspaceID: UUID?,
        tabID: UUID?,
        restrictedTools: Set<String>,
        additionalTools: Set<String>?,
        purpose: MCPRunPurpose,
        taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil,
        allowsAgentExternalControlTools: Bool = false,
        updatedAt: Date
    ) {
        if let existing = runPolicyStateByRunID[runID], existing.updatedAt >= updatedAt {
            return
        }
        runPolicyStateByRunID[runID] = RunConnectionPolicyState(
            windowID: windowID,
            workspaceID: workspaceID,
            tabID: tabID,
            restrictedTools: restrictedTools,
            additionalTools: additionalTools,
            purpose: purpose,
            taskLabelKind: taskLabelKind,
            allowsAgentExternalControlTools: allowsAgentExternalControlTools,
            updatedAt: updatedAt
        )
        windowIDByRunID[runID] = windowID
    }

    private func cacheRunPolicyStateIfNeeded(_ policy: ClientConnectionPolicy) {
        guard let runID = policy.runID else { return }
        seedRunPolicyState(
            runID: runID,
            windowID: policy.windowID,
            workspaceID: nil,
            tabID: policy.tabID,
            restrictedTools: policy.restrictedTools,
            additionalTools: policy.additionalTools,
            purpose: policy.purpose,
            taskLabelKind: policy.taskLabelKind,
            allowsAgentExternalControlTools: policy.allowsAgentExternalControlTools,
            updatedAt: policy.createdAt
        )
    }

    private nonisolated static func normalizedClientName(_ clientName: String) -> String {
        MCPClientIdentity.normalized(clientName) ?? ""
    }

    private nonisolated static func clientStorageKey(_ clientName: String) -> String {
        MCPClientIdentity.storageKey(clientName) ?? normalizedClientName(clientName)
    }

    private func matchingClientKeys(for clientName: String, in availableKeys: [String]) -> [String] {
        guard !Self.normalizedClientName(clientName).isEmpty else { return [] }
        let canonicalKey = Self.clientStorageKey(clientName)
        var seen = Set<String>()
        var matches: [String] = []

        if availableKeys.contains(clientName), seen.insert(clientName).inserted {
            matches.append(clientName)
        }
        if availableKeys.contains(canonicalKey), seen.insert(canonicalKey).inserted {
            matches.append(canonicalKey)
        }

        for key in availableKeys.sorted() where MCPClientIdentity.matches(key, clientName) {
            guard seen.insert(key).inserted else { continue }
            matches.append(key)
        }

        return matches
    }

    private func bestStorageKey(for clientName: String, in availableKeys: [String]) -> String {
        matchingClientKeys(for: clientName, in: availableKeys).first ?? Self.clientStorageKey(clientName)
    }

    private nonisolated static func isKnownAgentClientName(_ clientName: String) -> Bool {
        guard !normalizedClientName(clientName).isEmpty else { return false }
        for agent in AgentProviderKind.allCases {
            guard let hint = agent.mcpClientNameHint else { continue }
            if MCPClientIdentity.matches(clientName, hint) {
                return true
            }
        }
        return false
    }

    private func shouldAllowPersistedAgentModeRestore(clientName: String, purpose: MCPRunPurpose) -> Bool {
        purpose != .agentModeRun || Self.isKnownAgentClientName(clientName)
    }

    private func updateLiveRunAffinity(
        clientName: String,
        sessionKey: String?,
        runID: UUID?,
        windowID: Int?,
        purpose: MCPRunPurpose?
    ) {
        guard !clientName.isEmpty, let sessionKey, let runID, let windowID else { return }
        let resolvedPurpose = purpose ?? runPolicyStateByRunID[runID]?.purpose ?? .unknown
        guard shouldAllowPersistedAgentModeRestore(clientName: clientName, purpose: resolvedPurpose) else {
            return
        }
        let storageKey = bestStorageKey(
            for: clientName,
            in: Array(liveRunAffinityByClientSession.keys)
        )
        liveRunAffinityByClientSession[storageKey, default: [:]][sessionKey] = LiveRunAffinity(
            windowID: windowID,
            runID: runID,
            purpose: resolvedPurpose,
            lastSeenAt: Date()
        )
    }

    private func preferredLiveRunAffinity(
        for clientName: String,
        sessionKey: String?
    ) -> LiveRunAffinity? {
        guard let sessionKey else {
            return nil
        }
        let matchingKeys = matchingClientKeys(
            for: clientName,
            in: Array(liveRunAffinityByClientSession.keys)
        )
        guard let matchedKey = matchingKeys.first,
              let affinity = liveRunAffinityByClientSession[matchedKey]?[sessionKey]
        else {
            return nil
        }
        guard let cached = runPolicyStateByRunID[affinity.runID] else {
            liveRunAffinityByClientSession[matchedKey]?[sessionKey] = nil
            if liveRunAffinityByClientSession[matchedKey]?.isEmpty == true {
                liveRunAffinityByClientSession.removeValue(forKey: matchedKey)
            }
            return nil
        }
        let refreshed = LiveRunAffinity(
            windowID: cached.windowID,
            runID: affinity.runID,
            purpose: cached.purpose,
            lastSeenAt: affinity.lastSeenAt
        )
        liveRunAffinityByClientSession[matchedKey, default: [:]][sessionKey] = refreshed
        return refreshed
    }

    private func preferredExpectedPIDRunAffinity(
        for clientName: String,
        clientPid: Int?
    ) -> LiveRunAffinity? {
        guard let clientPid else { return nil }
        let clientExpectedPIDs = expectedAgentPIDs(for: clientName)
        guard !clientExpectedPIDs.isEmpty else { return nil }

        return expectedAgentPIDsByRunID.compactMap { runID, runExpectedPIDs -> (affinity: LiveRunAffinity, updatedAt: Date)? in
            let expectedPIDs = runExpectedPIDs.intersection(clientExpectedPIDs)
            guard admittedPolicyRunIDs.contains(runID),
                  !expectedPIDs.isEmpty,
                  isAncestor(expectedPIDs: expectedPIDs, ofPid: pid_t(clientPid)),
                  let cached = runPolicyStateByRunID[runID],
                  shouldAllowPersistedAgentModeRestore(clientName: clientName, purpose: cached.purpose)
            else {
                return nil
            }
            return (
                affinity: LiveRunAffinity(
                    windowID: cached.windowID,
                    runID: runID,
                    purpose: cached.purpose,
                    lastSeenAt: cached.updatedAt
                ),
                updatedAt: cached.updatedAt
            )
        }
        .max { lhs, rhs in lhs.updatedAt < rhs.updatedAt }?
        .affinity
    }

    private func oldestPendingPolicyEntry(for clientName: String) -> (key: String, policy: ClientConnectionPolicy)? {
        guard let entry = oldestPendingPolicyEntry(for: clientName, where: { _ in true }) else { return nil }
        return (key: entry.key, policy: entry.policy)
    }

    private func oldestPendingPolicyEntry(
        for clientName: String,
        where predicate: (ClientConnectionPolicy) -> Bool
    ) -> (key: String, index: Int, policy: ClientConnectionPolicy)? {
        pruneExpiredPolicies(for: clientName)
        let matchingKeys = matchingClientKeys(for: clientName, in: Array(pendingPoliciesByClient.keys))
        return matchingKeys
            .flatMap { key -> [(key: String, index: Int, policy: ClientConnectionPolicy)] in
                let queue = pendingPoliciesByClient[key] ?? []
                return queue.indices.compactMap { index in
                    let policy = queue[index]
                    guard predicate(policy) else { return nil }
                    return (key: key, index: index, policy: policy)
                }
            }
            .min { lhs, rhs in
                if lhs.policy.createdAt == rhs.policy.createdAt {
                    if lhs.key == rhs.key {
                        return lhs.index < rhs.index
                    }
                    return lhs.key < rhs.key
                }
                return lhs.policy.createdAt < rhs.policy.createdAt
            }
    }

    private func hasAgentPolicyAdmissionTarget(
        clientName: String,
        sessionKey: String?,
        clientPid: Int? = nil
    ) -> Bool {
        if oldestPendingPolicyEntry(for: clientName) != nil {
            return true
        }
        if preferredLiveRunAffinity(for: clientName, sessionKey: sessionKey) != nil {
            return true
        }
        return preferredExpectedPIDRunAffinity(for: clientName, clientPid: clientPid) != nil
    }

    private func hasPendingAgentBootstrapIntent(
        clientName: String,
        sessionKey: String?,
        clientPid: Int? = nil
    ) -> Bool {
        oldestPendingPolicyEntry(for: clientName) != nil
            || !expectedAgentPIDs(for: clientName).isEmpty
            || preferredLiveRunAffinity(for: clientName, sessionKey: sessionKey) != nil
            || preferredExpectedPIDRunAffinity(for: clientName, clientPid: clientPid) != nil
    }

    private func clearLiveRunAffinity(for runID: UUID) {
        let clientNames = Array(liveRunAffinityByClientSession.keys)
        for clientName in clientNames {
            guard var sessionMap = liveRunAffinityByClientSession[clientName] else { continue }
            sessionMap = sessionMap.filter { $0.value.runID != runID }
            if sessionMap.isEmpty {
                liveRunAffinityByClientSession.removeValue(forKey: clientName)
            } else {
                liveRunAffinityByClientSession[clientName] = sessionMap
            }
        }
    }

    private func applyRunPolicyStateIfAvailable(
        runID: UUID,
        connectionID: UUID,
        persistWindowBinding: Bool = true
    ) async {
        guard let cached = runPolicyStateByRunID[runID] else { return }

        restrictedToolsByConnection[connectionID] = cached.restrictedTools
        if let additional = cached.additionalTools {
            additionalToolsByConnection[connectionID] = additional
        } else {
            additionalToolsByConnection.removeValue(forKey: connectionID)
        }
        runPurposeByConnection[connectionID] = cached.purpose
        preassignedConnections.insert(connectionID)
        if persistWindowBinding {
            runIDByConnectionID[connectionID] = runID
        }

        if persistWindowBinding, connectionWindowMap[connectionID] != cached.windowID {
            setConnectionWindowMapping(connectionID, windowID: cached.windowID)
        }
        updateLiveRunAffinity(
            clientName: clientIdentifier(forConnection: connectionID) ?? "",
            sessionKey: connections[connectionID]?.capabilityToken ?? capabilityTokenByConnection[connectionID],
            runID: runID,
            windowID: cached.windowID,
            purpose: cached.purpose
        )

        _ = await ensureTabBoundForRunIfPossible(
            connectionID: connectionID,
            clientName: clientIdentifier(forConnection: connectionID),
            runID: runID,
            windowID: cached.windowID
        )

        if connections[connectionID] != nil {
            await notifyToolListChanged(connectionID: connectionID)
        }
    }

    func connectionID(for clientName: String, windowID: Int) -> UUID? {
        // Use canonical connectionWindowMap for consistency
        if let active = activeConnectionsByClient[clientName] {
            for id in active {
                if connectionWindowMap[id] == windowID {
                    return id
                }
            }
        }
        for (id, pendingName) in pendingConnections where pendingName == clientName {
            if connectionWindowMap[id] == windowID {
                return id
            }
        }
        return nil
    }

    func runPolicyPurpose(for runID: UUID) -> MCPRunPurpose? {
        runPolicyStateByRunID[runID]?.purpose
    }

    @discardableResult
    func rehydrateRunTabContextForConnectionIfPossible(_ connectionID: UUID) async -> Bool {
        guard let runID = await runIDForConnection(connectionID),
              let cached = runPolicyStateByRunID[runID],
              cached.purpose == .agentModeRun,
              cached.tabID != nil
        else {
            return false
        }
        await applyRunPolicyStateIfAvailable(runID: runID, connectionID: connectionID)
        return await ensureTabBoundForRunIfPossible(
            connectionID: connectionID,
            clientName: clientIdentifier(forConnection: connectionID),
            runID: runID,
            windowID: cached.windowID
        )
    }

    typealias ConnectionApprovalHandler = @Sendable (UUID, MCP.Client.Info) async -> Bool
    private var connectionApprovalHandler: ConnectionApprovalHandler?

    private var serviceBindings: [String: Binding<Bool>] = [:]

    func isRunning() -> Bool {
        isRunningState
    }

    func setConnectionApprovalHandler(_ handler: @escaping ConnectionApprovalHandler) {
        connectionLog("Setting connection approval handler")
        connectionApprovalHandler = handler
    }

    /// Unregister all enhanced tool event observers for a specific run.
    /// This only removes observers and does not mutate run routing state.
    func unregisterToolObservers(for runID: UUID) async {
        if let unregistration = toolObserverUnregistrationsByRunID[runID] {
            await unregistration.task.value
            return
        }

        let removedObservers = toolEventObservers.removeValue(forKey: runID).map { Array($0.values) } ?? []
        let unregistrationID = UUID()
        let task = Task {
            for observer in removedObservers {
                await observer.deliveryBarrier.waitUntilIdle()
            }
        }
        toolObserverUnregistrationsByRunID[runID] = ToolObserverUnregistrationState(
            id: unregistrationID,
            task: task
        )
        await task.value
        if toolObserverUnregistrationsByRunID[runID]?.id == unregistrationID {
            toolObserverUnregistrationsByRunID.removeValue(forKey: runID)
        }
        connectionLog("Unregistered tool observers for runID: \(runID)")
    }

    /// Explicitly clears run-scoped routing/policy state.
    /// Use this at true end-of-scope boundaries (session deletion, tab/window close),
    /// not for normal observer lifecycle teardown.
    func cleanupRunRoutingState(for runID: UUID, windowID: Int? = nil) async {
        runPolicyStateByRunID.removeValue(forKey: runID)
        admittedPolicyRunIDs.remove(runID)
        windowIDByRunID.removeValue(forKey: runID)
        pendingPolicyApplicationIDByRunID.removeValue(forKey: runID)
        clearLiveRunAffinity(for: runID)
        let connectionIDsForRun = runIDByConnectionID.compactMap { connectionID, mappedRunID in
            mappedRunID == runID ? connectionID : nil
        }
        for connectionID in connectionIDsForRun {
            runIDByConnectionID.removeValue(forKey: connectionID)
        }

        await MainActor.run {
            let windows = WindowStatesManager.shared.allWindows.filter { window in
                guard let windowID else { return true }
                return window.windowID == windowID
            }
            for window in windows {
                if let connectionID = window.mcpServer.connectionID(forRunID: runID) {
                    window.mcpServer.cleanupRunIDMapping(runID: runID, connectionID: connectionID)
                    connectionLog("Cleaned up runID mapping for runID \(runID) in window \(window.windowID)")
                }
            }
        }
    }

    /// Explicitly clears cached run routing/policy state for any runs associated with a closed tab.
    /// Preserves window affinity while dropping tab-scoped run state.
    func cleanupRunRoutingState(forTabID tabID: UUID, windowID: Int? = nil) async {
        let targetRunIDs = runPolicyStateByRunID.compactMap { runID, state -> UUID? in
            guard state.tabID == tabID else { return nil }
            if let windowID, state.windowID != windowID {
                return nil
            }
            return runID
        }

        guard !targetRunIDs.isEmpty else { return }
        for runID in targetRunIDs {
            await cleanupRunRoutingState(for: runID, windowID: windowID)
        }
    }

    // MARK: - Enhanced Tool Event Observers (with args and results)

    /// Register an enhanced tool event observer that receives args on call and result on completion
    @discardableResult
    func registerToolEventObserver(for runID: UUID, observer: ToolEventObserver) -> UUID {
        let token = UUID()
        toolEventObservers[runID, default: [:]][token] = observer
        connectionLog("Registered tool event observer for runID: \(runID) token: \(token)")
        return token
    }

    /// Unregister all tool event observers for a specific run
    func unregisterToolEventObservers(for runID: UUID) async {
        await unregisterToolObservers(for: runID)
    }

    func toolEventObserverCount(for runID: UUID? = nil) -> Int {
        if let runID {
            return toolEventObservers[runID]?.count ?? 0
        }
        return toolEventObservers.values.reduce(into: 0) { partialResult, observers in
            partialResult += observers.count
        }
    }

    /// Notify observers when a tool is called (with args).
    /// Deliver synchronously to preserve ordering with completion callbacks in the same turn.
    @discardableResult
    func fireToolCalledObservers(runID: UUID, invocationID: UUID, toolName: String, args: [String: Value]?) async -> Int {
        guard let observers = toolEventObservers[runID], !observers.isEmpty else {
            if MCPIntegrationHelper.isRepoPromptToolNameAfterNormalization(toolName) {
                mcpToolTrackingDiagnostic(
                    "MCP observer call skipped no event observers runID=\(runID.uuidString) " +
                        "tool=\(toolName) invocation=\(invocationID.uuidString)"
                )
            }
            return 0
        }
        let observerEntries = Array(observers)
        observerEntries.forEach { $0.value.deliveryBarrier.beginDeliveries() }
        defer { observerEntries.forEach { $0.value.deliveryBarrier.endDelivery() } }
        #if DEBUG
            let batchStart = DispatchTime.now().uptimeNanoseconds
            await debugBeforeToolEventObserverDeliveryForTesting?()
        #endif
        for (position, entry) in observerEntries.enumerated() {
            let (token, observer) = entry
            #if DEBUG
                let scheduledAt = DispatchTime.now().uptimeNanoseconds
                let dimensions = EditFlowPerf.Dimensions(
                    toolName: toolName,
                    observerToken: token.uuidString,
                    observerType: "event_call",
                    serialPosition: position,
                    queueDelayMicroseconds: Self.debugElapsedMicroseconds(from: batchStart, to: scheduledAt),
                    correlationPath: "invocation_id",
                    scannedItemCount: 0,
                    runID: runID.uuidString
                )
                EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.MCPToolCall.observerScheduled, dimensions)
                EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.MCPToolCall.observerEntered, dimensions)
            #endif
            #if DEBUG
                let recorder = MCPToolObserverAttributionRecorder()
                await MCPToolObserverAttributionContext.$recorder.withValue(recorder) {
                    await observer.onCalled(invocationID, toolName, args)
                }
                let attribution = recorder.snapshot()
                let finishedAt = DispatchTime.now().uptimeNanoseconds
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.MCPToolCall.observerExited,
                    EditFlowPerf.Dimensions(
                        toolName: toolName,
                        observerToken: token.uuidString,
                        observerType: "event_call",
                        serialPosition: position,
                        queueDelayMicroseconds: Self.debugElapsedMicroseconds(from: batchStart, to: scheduledAt),
                        durationMicroseconds: Self.debugElapsedMicroseconds(from: scheduledAt, to: finishedAt),
                        correlationPath: attribution?.correlationPath ?? "unreported",
                        scannedItemCount: attribution?.scannedItemCount ?? 0,
                        runID: runID.uuidString
                    )
                )
            #else
                await observer.onCalled(invocationID, toolName, args)
            #endif
        }
        connectionLog("Tool called observers fired for runID \(runID) tool \(toolName) count \(observers.count)")
        return observers.count
    }

    /// Notify observers when a tool completes (with result).
    /// Deliver synchronously so tool cards can finalize before run-end fallback logic executes.
    @discardableResult
    func fireToolCompletedObservers(runID: UUID, invocationID: UUID, toolName: String, args: [String: Value]?, resultJSON: String, isError: Bool) async -> Int {
        guard let observers = toolEventObservers[runID], !observers.isEmpty else {
            if MCPIntegrationHelper.isRepoPromptToolNameAfterNormalization(toolName) {
                mcpToolTrackingDiagnostic(
                    "MCP observer completion skipped no event observers runID=\(runID.uuidString) " +
                        "tool=\(toolName) invocation=\(invocationID.uuidString) isError=\(isError) resultChars=\(resultJSON.count)"
                )
            }
            return 0
        }
        let observerEntries = Array(observers)
        observerEntries.forEach { $0.value.deliveryBarrier.beginDeliveries() }
        defer { observerEntries.forEach { $0.value.deliveryBarrier.endDelivery() } }
        #if DEBUG
            let batchStart = DispatchTime.now().uptimeNanoseconds
            await debugBeforeToolEventObserverDeliveryForTesting?()
        #endif
        var firedCount = 0
        for (position, entry) in observerEntries.enumerated() {
            let (token, observer) = entry
            guard let onCompleted = observer.onCompleted else { continue }
            firedCount += 1
            #if DEBUG
                let scheduledAt = DispatchTime.now().uptimeNanoseconds
                let recorder = MCPToolObserverAttributionRecorder()
                let dimensions = EditFlowPerf.Dimensions(
                    toolName: toolName,
                    observerToken: token.uuidString,
                    observerType: "event_completion",
                    serialPosition: position,
                    queueDelayMicroseconds: Self.debugElapsedMicroseconds(from: batchStart, to: scheduledAt),
                    resultBytes: resultJSON.utf8.count,
                    runID: runID.uuidString
                )
                EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.MCPToolCall.observerScheduled, dimensions)
                EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.MCPToolCall.observerEntered, dimensions)
                await MCPToolObserverAttributionContext.$recorder.withValue(recorder) {
                    await onCompleted(invocationID, toolName, args, resultJSON, isError)
                }
                let attribution = recorder.snapshot()
                let finishedAt = DispatchTime.now().uptimeNanoseconds
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.MCPToolCall.observerExited,
                    EditFlowPerf.Dimensions(
                        toolName: toolName,
                        observerToken: token.uuidString,
                        observerType: "event_completion",
                        serialPosition: position,
                        queueDelayMicroseconds: Self.debugElapsedMicroseconds(from: batchStart, to: scheduledAt),
                        durationMicroseconds: Self.debugElapsedMicroseconds(from: scheduledAt, to: finishedAt),
                        correlationPath: attribution?.correlationPath ?? "unreported",
                        scannedItemCount: attribution?.scannedItemCount ?? 0,
                        resultBytes: resultJSON.utf8.count,
                        runID: runID.uuidString
                    )
                )
            #else
                await onCompleted(invocationID, toolName, args, resultJSON, isError)
            #endif
        }
        connectionLog("Tool completed observers fired for runID \(runID) tool \(toolName) count \(firedCount)")
        return firedCount
    }

    #if DEBUG
        private nonisolated static func debugElapsedMicroseconds(from start: UInt64, to end: UInt64) -> Int {
            guard end >= start else { return 0 }
            return Int(min((end - start) / 1000, UInt64(Int.max)))
        }
    #endif

    // MARK: - Connection Waiter Helpers (event-driven, replaces 100ms polling)

    /// Find a matching connection among current connections, excluding those in the exclude set.
    /// Checks both admitted (clientIDByConnection) and pending (pendingConnections) names.
    private func findMatchingConnection(
        excluding: Set<UUID>,
        clientName: String?,
        lifecycleGeneration expectedLifecycleGeneration: UInt64
    ) -> UUID? {
        guard isCurrentLifecycle(expectedLifecycleGeneration) else { return nil }
        for (id, _) in connections {
            guard !connectionsBeingRemoved.contains(id),
                  connectionLifecycleGenerationByID[id] == expectedLifecycleGeneration
            else { continue }
            guard !excluding.contains(id) else { continue }

            if let nameFilter = clientName {
                // Prefer authoritative admission mapping
                if MCPClientIdentity.matches(clientIDByConnection[id], nameFilter) {
                    return id
                }
                // Also accept pre-admission handshake name
                if MCPClientIdentity.matches(pendingConnections[id], nameFilter) {
                    return id
                }
                // No name yet or mismatched
                continue
            } else {
                // No filter - return first new connection
                return id
            }
        }
        return nil
    }

    /// Resume a waiter with a result (connection ID or nil for timeout/cancel).
    /// Ensures single-shot resumption by removing waiter before resuming.
    private func resumeWaiter(_ waiterID: UUID, lifecycleGeneration expectedLifecycleGeneration: UInt64? = nil, with connectionID: UUID?) {
        guard let waiter = connectionWaiters[waiterID] else { return }
        if let expectedLifecycleGeneration {
            guard waiter.lifecycleGeneration == expectedLifecycleGeneration else { return }
        }
        connectionWaiters.removeValue(forKey: waiterID)
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(returning: connectionID)
    }

    /// Cancel a waiter (called from task cancellation handler).
    /// Note: Intentionally no logging here to avoid actor hop complexity during cancellation
    /// which can cause resource starvation/deadlock.
    private func cancelWaiter(_ waiterID: UUID, lifecycleGeneration expectedLifecycleGeneration: UInt64) {
        resumeWaiter(waiterID, lifecycleGeneration: expectedLifecycleGeneration, with: nil)
    }

    /// Notify waiters when a new connection arrives. Resumes the first matching waiter (FIFO).
    /// Called from handleBootstrapConnection after adding to connections.
    private func notifyConnectionWaiters(connectionID: UUID, clientName: String?, lifecycleGeneration expectedLifecycleGeneration: UInt64) {
        guard isCurrentConnection(connectionID, lifecycleGeneration: expectedLifecycleGeneration) else { return }
        let actualName = clientName ?? "unknown"
        var matchedWaiterID: UUID?

        for (waiterID, waiter) in connectionWaiters {
            guard waiter.lifecycleGeneration == expectedLifecycleGeneration else { continue }
            guard !waiter.excludeExisting.contains(connectionID) else {
                mcpACPLog("[MCP-ACP] waiter=\(waiterID) connection=\(connectionID) skipped existing expected=\(waiter.clientName ?? "<any>") actual=\(actualName)")
                continue
            }
            let isMatch = waiter.clientName == nil || MCPClientIdentity.matches(waiter.clientName, clientName)
            mcpACPLog("[MCP-ACP] waiter=\(waiterID) connection=\(connectionID) expected=\(waiter.clientName ?? "<any>") actual=\(actualName) match=\(isMatch)")
            if isMatch {
                matchedWaiterID = waiterID
                break
            }
        }

        guard let matchID = matchedWaiterID else {
            mcpACPLog("[MCP-ACP] no waiter matched connection=\(connectionID) actual=\(actualName)")
            return
        }

        let waiter = connectionWaiters[matchID]
        connectionLog("Found new connection \(connectionID) for waiting client: \(waiter?.clientName ?? "any") (actual: \(actualName))")
        resumeWaiter(matchID, lifecycleGeneration: expectedLifecycleGeneration, with: connectionID)
    }

    /// Wait for a new connection from a specific client (for Context Builder).
    /// Uses event-driven continuations instead of polling for efficiency.
    /// Returns the connection ID once established, or nil if timeout/cancelled.
    ///
    /// For name-filtered waits, we only exclude connections that already have the target
    /// client name. This allows bootstrap connections (which exist before MCP initialize)
    /// to satisfy waiters once their MCP client name is established.
    func waitForNewConnection(clientName: String?, timeout: TimeInterval = 10.0) async -> UUID? {
        let waiterLifecycleGeneration = lifecycleGeneration
        guard isCurrentLifecycle(waiterLifecycleGeneration) else { return nil }

        // Compute exclusion set based on whether we're filtering by name
        let existing: Set<UUID>
        if let targetName = clientName {
            // Only exclude connections that already match this client name.
            // This allows bootstrap connections to satisfy waiters once MCP initialize arrives.
            let alreadyMatching = connections.keys.filter { id in
                guard connectionLifecycleGenerationByID[id] == waiterLifecycleGeneration else { return false }
                let admitted = clientIDByConnection[id]
                let pending = pendingConnections[id]
                return admitted == targetName || pending == targetName
            }
            existing = Set(alreadyMatching)
        } else {
            // Unfiltered waiter: exclude all existing connections from this lifecycle.
            existing = Set(connections.keys.filter { connectionLifecycleGenerationByID[$0] == waiterLifecycleGeneration })
        }

        // Fast path: check if a matching connection already exists
        if let match = findMatchingConnection(
            excluding: existing,
            clientName: clientName,
            lifecycleGeneration: waiterLifecycleGeneration
        ) {
            let label = clientIDByConnection[match] ?? pendingConnections[match] ?? "unknown"
            connectionLog("Found existing connection \(match) for client: \(label)")
            return match
        }

        // Generate waiter ID before entering continuation so cancellation handler can capture it
        let waiterID = UUID()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UUID?, Never>) in
                guard isCurrentLifecycle(waiterLifecycleGeneration) else {
                    continuation.resume(returning: nil)
                    return
                }

                // Schedule timeout task
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    await self?.handleWaiterTimeout(
                        waiterID,
                        lifecycleGeneration: waiterLifecycleGeneration,
                        clientName: clientName
                    )
                }

                // Register the waiter
                let waiter = ConnectionWaiter(
                    lifecycleGeneration: waiterLifecycleGeneration,
                    clientName: clientName,
                    excludeExisting: existing,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                connectionWaiters[waiterID] = waiter

                // Recheck after registration to close race window:
                // A connection may have arrived between fast-path check and registration
                if let match = findMatchingConnection(
                    excluding: existing,
                    clientName: clientName,
                    lifecycleGeneration: waiterLifecycleGeneration
                ) {
                    let label = clientIDByConnection[match] ?? pendingConnections[match] ?? "unknown"
                    connectionLog("Found connection \(match) for client: \(label) (post-registration recheck)")
                    resumeWaiter(
                        waiterID,
                        lifecycleGeneration: waiterLifecycleGeneration,
                        with: match
                    )
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelWaiter(
                    waiterID,
                    lifecycleGeneration: waiterLifecycleGeneration
                )
            }
        }
    }

    /// Handle waiter timeout - resume with nil if waiter still exists.
    private func handleWaiterTimeout(_ waiterID: UUID, lifecycleGeneration expectedLifecycleGeneration: UInt64, clientName: String?) {
        guard connectionWaiters[waiterID]?.lifecycleGeneration == expectedLifecycleGeneration else { return }
        if let clientName {
            connectionLog("Timed out waiting for connection from client: \(clientName)")
        } else {
            connectionLog("Timed out waiting for connection without client hint")
        }
        resumeWaiter(waiterID, lifecycleGeneration: expectedLifecycleGeneration, with: nil)
    }

    /// Backwards-compatible overload that preserves previous call sites.
    func waitForNewConnection(clientName: String, timeout: TimeInterval = 10.0) async -> UUID? {
        await waitForNewConnection(clientName: Optional(clientName), timeout: timeout)
    }

    func start() async {
        #if DEBUG
            print("[MCPStartup] ServerNetworkManager.start entered")
        #endif
        connectionLog("Starting network manager")
        if !isRunningState {
            lifecycleGeneration &+= 1
        }
        isRunningState = true
        let startLifecycleGeneration = lifecycleGeneration
        transferredBootstrapSockets.activate(lifecycleGeneration: startLifecycleGeneration)

        // Start bootstrap socket server for UNIX socket connections before maintenance
        // health checks can observe and restart a not-yet-created socket.
        bootstrapSocketTask?.cancel()
        await startBootstrapSocketServer(lifecycleGeneration: startLifecycleGeneration)

        // A full shutdown may have run while listener startup awaited another actor.
        guard isCurrentLifecycle(startLifecycleGeneration) else { return }

        // Start periodic maintenance loop for cleanup tasks
        startMaintenanceLoop(lifecycleGeneration: startLifecycleGeneration)
    }

    /// Starts the periodic maintenance loop for cleanup tasks.
    private func startMaintenanceLoop(lifecycleGeneration: UInt64) {
        guard isCurrentLifecycle(lifecycleGeneration) else { return }
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard await isCurrentLifecycle(lifecycleGeneration) else { return }
                await maintenanceTick(lifecycleGeneration: lifecycleGeneration)
                guard await isCurrentLifecycle(lifecycleGeneration) else { return }
                do { try await Task.sleep(for: .seconds(5)) }
                catch { break }
            }
        }
    }

    // Throttle kill signal cleanup (filesystem operations) to reduce overhead
    private var lastKillSignalCleanupAt: Date = .distantPast
    private let killSignalCleanupInterval: TimeInterval = 60.0

    /// Performs periodic maintenance: cleans up expired reservations, cooldowns, policies, and stale kill signals.
    private func maintenanceTick(lifecycleGeneration expectedLifecycleGeneration: UInt64) async {
        guard isCurrentLifecycle(expectedLifecycleGeneration) else { return }
        // Safety-net cleanup for edge cases / crashy mid-flight states.
        cleanupExpiredBootstrapReservations()
        cleanupExpiredKilledSessions()
        cleanupExpiredUserKilledClients()
        cleanupExpiredClientConnectionPolicies()
        await pruneNonViableConnections(lifecycleGeneration: expectedLifecycleGeneration)
        guard isCurrentLifecycle(expectedLifecycleGeneration) else { return }
        await pressureEvictIdleConnectionsIfNeeded(lifecycleGeneration: expectedLifecycleGeneration)
        guard isCurrentLifecycle(expectedLifecycleGeneration) else { return }
        await ensureBootstrapHealthy(lifecycleGeneration: expectedLifecycleGeneration)
        guard isCurrentLifecycle(expectedLifecycleGeneration) else { return }

        // Throttle kill signal cleanup (involves filesystem operations)
        let now = Date()
        if now.timeIntervalSince(lastKillSignalCleanupAt) >= killSignalCleanupInterval {
            lastKillSignalCleanupAt = now
            MCPKillSignal.cleanupStaleSignals(in: MCPFilesystemConstants.identity.killSignalsDirectoryURL())
        }
    }

    /// Removes expired queued ClientConnectionPolicy entries so they don't accumulate.
    /// Policies have TTL but were never pruned, causing unbounded growth over long runs.
    private func cleanupExpiredClientConnectionPolicies() {
        let now = Date()
        var removedCount = 0
        for (clientID, policies) in pendingPoliciesByClient {
            let filtered = policies.filter { now.timeIntervalSince($0.createdAt) < $0.ttl }
            if filtered.isEmpty {
                pendingPoliciesByClient.removeValue(forKey: clientID)
                removedCount += policies.count
            } else if filtered.count != policies.count {
                removedCount += policies.count - filtered.count
                pendingPoliciesByClient[clientID] = filtered
            }
        }
        if removedCount > 0 {
            connectionLog("Cleaned up \(removedCount) expired client connection policies")
        }
    }

    /// Prune connections that are no longer viable or have been stuck connecting too long.
    private func pruneNonViableConnections(lifecycleGeneration expectedLifecycleGeneration: UInt64? = nil) async {
        if let expectedLifecycleGeneration {
            guard isCurrentLifecycle(expectedLifecycleGeneration) else { return }
        }
        guard !connections.isEmpty else { return }
        let now = Date()
        let connectingTimeout = TimeInterval(connectingTimeoutSeconds)
        var toRemove: [(UUID, MCPConnectionCloseContext)] = []

        for (id, mgr) in connections {
            if let expectedLifecycleGeneration {
                guard isCurrentLifecycle(expectedLifecycleGeneration) else { return }
            }
            let state = await mgr.connectionState()
            if let expectedLifecycleGeneration {
                guard isCurrentLifecycle(expectedLifecycleGeneration) else { return }
            }
            if case .failed = state {
                toRemove.append((
                    id,
                    MCPConnectionCloseContext(reason: "maintenance_prune_failed", initiator: .app)
                ))
                continue
            }
            if case .cancelled = state {
                toRemove.append((
                    id,
                    MCPConnectionCloseContext(reason: "maintenance_prune_cancelled", initiator: .app)
                ))
                continue
            }
            let viable = await mgr.isViableForRetention()
            if let expectedLifecycleGeneration {
                guard isCurrentLifecycle(expectedLifecycleGeneration) else { return }
            }
            if !viable {
                toRemove.append((
                    id,
                    MCPConnectionCloseContext(reason: "maintenance_prune_nonviable", initiator: .app)
                ))
                continue
            }
            if connectingTimeout > 0, state == .connecting {
                if let createdAt = connectionStats[id]?.createdAt,
                   now.timeIntervalSince(createdAt) > connectingTimeout
                {
                    log.warning("Pruning connection \(id) stuck in connecting for \(Int(now.timeIntervalSince(createdAt)))s")
                    toRemove.append((
                        id,
                        MCPConnectionCloseContext(reason: "maintenance_prune_connect_timeout", initiator: .app)
                    ))
                }
            }
        }

        for (id, context) in toRemove {
            if let expectedLifecycleGeneration {
                guard isCurrentLifecycle(expectedLifecycleGeneration) else { return }
            }
            await removeConnection(id, context: context)
        }
    }

    /// Under pressure, evict idle connections that exceed pressureEvictIdleSeconds.
    private func pressureEvictIdleConnectionsIfNeeded(lifecycleGeneration expectedLifecycleGeneration: UInt64? = nil) async {
        if let expectedLifecycleGeneration {
            guard isCurrentLifecycle(expectedLifecycleGeneration) else { return }
        }
        guard pressureEvictIdleSeconds > 0 else { return }
        guard effectiveGlobalAdmissionLoad() >= maxGlobalConnections else { return }
        guard let victim = await oldestPressureEvictionCandidate() else { return }
        if let expectedLifecycleGeneration {
            guard isCurrentLifecycle(expectedLifecycleGeneration) else { return }
        }
        guard isCurrentEvictionCandidate(victim),
              !isCreditedBootstrapPredecessor(victim),
              let closedLimiters = callLimiters[victim.id]
        else { return }
        guard await closeConnectionCallLanesIfIdleForEviction(
            victim.id,
            expectedConnectionIdentity: victim.connectionIdentity,
            expectedLimiters: closedLimiters
        ) else { return }
        guard isCurrentEvictionCandidate(victim),
              callLimiters[victim.id] === closedLimiters
        else {
            await closedLimiters.markTentativeCloseCommitted()
            return
        }

        if isCreditedBootstrapPredecessor(victim)
            || effectiveGlobalAdmissionLoad() < maxGlobalConnections
        {
            _ = await restoreConnectionCallLanesAfterAbortedIdleEviction(
                victim.id,
                clientID: victim.clientID,
                connectionIdentity: victim.connectionIdentity,
                replacing: closedLimiters,
                requiresClientMembership: false
            )
            return
        }

        guard !isCreditedBootstrapPredecessor(victim),
              let committedRemoval = commitConnectionRemoval(
                  connectionID: victim.id,
                  expectedIdentity: victim.connectionIdentity,
                  expectedLifecycleGeneration: victim.lifecycleGeneration
              )
        else {
            await closedLimiters.markTentativeCloseCommitted()
            return
        }
        await closedLimiters.markTentativeCloseCommitted()
        log.warning("Pressure eviction: evicting idle connection \(victim.id)")
        _ = await removeConnection(
            victim.id,
            committedRemoval: committedRemoval,
            connectionAlreadyStopped: false,
            context: MCPConnectionCloseContext(
                reason: "pressure_eviction",
                initiator: .app
            )
        )
    }

    // MARK: - Bootstrap Socket Server

    /// Ensures the bootstrap socket listener is present and healthy.
    /// Intended as a periodic self-heal for stale sockets or failed startups.
    func ensureBootstrapHealthy(force: Bool = false) async {
        await ensureBootstrapHealthy(force: force, lifecycleGeneration: lifecycleGeneration)
    }

    private func ensureBootstrapHealthy(force: Bool = false, lifecycleGeneration healthCheckLifecycleGeneration: UInt64) async {
        guard isCurrentLifecycle(healthCheckLifecycleGeneration) else { return }
        // Listener retention and recovery are lifecycle concerns, not tool-exposure concerns.
        // Ordinary setEnabled(false) keeps sockets alive and must still self-heal the listener.
        guard !bootstrapStartInProgress else { return }
        guard !bootstrapRestartInProgress else { return }

        let now = Date()
        if !force, now.timeIntervalSince(lastBootstrapHealthCheckAt) < bootstrapHealthCheckInterval {
            return
        }
        lastBootstrapHealthCheckAt = now

        let socketPath = resolvedBootstrapSocketURL().path
        guard let server = bootstrapSocketServer,
              bootstrapSocketServerLifecycleGeneration == healthCheckLifecycleGeneration
        else {
            connectionLog("BootstrapSocketServer nil or stale while running. Restarting.")
            restartBootstrapSocketServer(reason: "server_nil_or_stale", lifecycleGeneration: healthCheckLifecycleGeneration)
            return
        }

        await server.ensureAccepting()
        guard isCurrentBootstrapListener(server, lifecycleGeneration: healthCheckLifecycleGeneration) else { return }

        let diagnostics = await server.diagnostics()
        guard isCurrentBootstrapListener(server, lifecycleGeneration: healthCheckLifecycleGeneration) else { return }
        if !diagnostics.ownsSocketPath {
            log.warning("Bootstrap listener no longer owns socket path \(socketPath) (status=\(String(describing: diagnostics.socketPathStatus))); stopping orphan and restarting with backoff.")
            restartBootstrapSocketServer(reason: "socket_path_ownership_lost", lifecycleGeneration: healthCheckLifecycleGeneration)
            return
        }

        if !diagnostics.listenFDValid {
            log.warning("Bootstrap listen FD invalid; restarting.")
            restartBootstrapSocketServer(reason: "listen_fd_invalid", lifecycleGeneration: healthCheckLifecycleGeneration)
            return
        }

        if !diagnostics.acceptSourceExists {
            log.warning("Bootstrap accept source missing; restarting.")
            restartBootstrapSocketServer(reason: "accept_source_missing", lifecycleGeneration: healthCheckLifecycleGeneration)
            return
        }

        let listening = await server.isListening()
        guard isCurrentBootstrapListener(server, lifecycleGeneration: healthCheckLifecycleGeneration) else { return }
        if !listening {
            log.warning("BootstrapSocketServer not listening (but should be). Restarting.")
            restartBootstrapSocketServer(reason: "not_listening", lifecycleGeneration: healthCheckLifecycleGeneration)
        }
    }

    private func bootstrapBackoffDelay(for failures: Int) -> TimeInterval {
        let capped = min(failures, 4)
        return min(10.0, pow(2.0, Double(capped)))
    }

    private func restartBootstrapSocketServer(
        reason: String,
        delay: TimeInterval = 0,
        lifecycleGeneration expectedLifecycleGeneration: UInt64
    ) {
        guard isCurrentLifecycle(expectedLifecycleGeneration) else { return }
        guard !bootstrapRestartInProgress else { return }

        let now = Date()
        guard now.timeIntervalSince(lastBootstrapRestartAt) >= bootstrapRestartMinInterval else { return }

        bootstrapRestartInProgress = true
        lastBootstrapRestartAt = now
        let token = UUID()
        bootstrapRestartToken = token
        bootstrapRestartLifecycleGeneration = expectedLifecycleGeneration

        Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            #if DEBUG
                await self?.debugSuspendLifecycleFenceCheckpointIfNeeded(.restartTaskBeforePerform)
            #endif
            await self?.performBootstrapRestart(
                reason: reason,
                token: token,
                lifecycleGeneration: expectedLifecycleGeneration
            )
            #if DEBUG
                await self?.debugRecordBootstrapRestartTaskCompletion()
            #endif
        }
    }

    private func performBootstrapRestart(reason: String, token: UUID, lifecycleGeneration expectedLifecycleGeneration: UInt64) async {
        defer { clearBootstrapRestartIfMatching(token: token, lifecycleGeneration: expectedLifecycleGeneration) }

        guard bootstrapRestartToken == token,
              bootstrapRestartLifecycleGeneration == expectedLifecycleGeneration
        else {
            connectionLog("Skipping bootstrap restart (reason=\(reason)) - superseded")
            return
        }
        guard isCurrentLifecycle(expectedLifecycleGeneration) else {
            connectionLog("Skipping bootstrap restart (reason=\(reason)) - stale lifecycle")
            return
        }

        let socketPath = resolvedBootstrapSocketURL().path
        connectionLog("Restarting bootstrap socket server (reason=\(reason), socket=\(socketPath), failures=\(bootstrapStartFailures))")
        let server = bootstrapSocketServer
        let serverLifecycleGeneration = bootstrapSocketServerLifecycleGeneration
        if let serverLifecycleGeneration {
            await stopBootstrapSocketServer(server: server, lifecycleGeneration: serverLifecycleGeneration)
        }
        guard bootstrapRestartToken == token,
              bootstrapRestartLifecycleGeneration == expectedLifecycleGeneration,
              isCurrentLifecycle(expectedLifecycleGeneration)
        else {
            connectionLog("Skipping bootstrap listener replacement (reason=\(reason)) - stale lifecycle")
            return
        }
        await startBootstrapSocketServer(lifecycleGeneration: expectedLifecycleGeneration)
    }

    private func clearBootstrapRestartIfMatching(token: UUID, lifecycleGeneration expectedLifecycleGeneration: UInt64) {
        guard bootstrapRestartToken == token,
              bootstrapRestartLifecycleGeneration == expectedLifecycleGeneration
        else { return }
        bootstrapRestartToken = nil
        bootstrapRestartLifecycleGeneration = nil
        bootstrapRestartInProgress = false
    }

    private func invalidateBootstrapRestartState() {
        bootstrapRestartToken = nil
        bootstrapRestartLifecycleGeneration = nil
        bootstrapRestartInProgress = false
    }

    private func clearBootstrapStartIfMatching(lifecycleGeneration expectedLifecycleGeneration: UInt64) {
        guard bootstrapStartLifecycleGeneration == expectedLifecycleGeneration else { return }
        bootstrapStartLifecycleGeneration = nil
        bootstrapStartInProgress = false
    }

    private func isCurrentBootstrapListener(_ server: BootstrapSocketServer, lifecycleGeneration expectedLifecycleGeneration: UInt64) -> Bool {
        isCurrentLifecycle(expectedLifecycleGeneration)
            && bootstrapSocketServer === server
            && bootstrapSocketServerLifecycleGeneration == expectedLifecycleGeneration
    }

    /// Starts the bootstrap socket server for UNIX socket connections.
    private func startBootstrapSocketServer(lifecycleGeneration expectedLifecycleGeneration: UInt64) async {
        #if DEBUG
            print("[MCPStartup] startBootstrapSocketServer entered running=\(isRunningState) enabled=\(isEnabledState) inProgress=\(bootstrapStartInProgress) generation=\(expectedLifecycleGeneration)")
        #endif
        guard isCurrentLifecycle(expectedLifecycleGeneration) else { return }
        guard !bootstrapStartInProgress else { return }
        // Never overwrite a listener that another lifecycle is still tearing down.
        // A new lifecycle maintenance tick will retry once identity-fenced teardown clears it.
        guard bootstrapSocketServer == nil else { return }
        bootstrapStartInProgress = true
        bootstrapStartLifecycleGeneration = expectedLifecycleGeneration
        defer { clearBootstrapStartIfMatching(lifecycleGeneration: expectedLifecycleGeneration) }

        connectionLog("Starting bootstrap socket server for lifecycle \(expectedLifecycleGeneration)...")

        let socketURL = resolvedBootstrapSocketURL()
        let server = BootstrapSocketServer(socketURL: socketURL, logger: log)
        bootstrapSocketServer = server
        bootstrapSocketServerLifecycleGeneration = expectedLifecycleGeneration
        #if DEBUG
            await debugSuspendLifecycleFenceCheckpointIfNeeded(.listenerPublishedBeforeStartInvocation)
        #endif

        do {
            #if DEBUG
                print("[MCPStartup] calling BootstrapSocketServer.start socket=\(socketURL.path) generation=\(expectedLifecycleGeneration)")
            #endif
            try await server.start { [weak self, weak server] clientFD, sessionToken, clientPid, clientName async -> BootstrapSocketServer.Admission in
                guard let self, let server else {
                    return .reject(.rejected(reason: "Server unavailable", errorCode: "server_unavailable"))
                }
                return await handleBootstrapConnection(
                    sourceListener: server,
                    lifecycleGeneration: expectedLifecycleGeneration,
                    clientFD: clientFD,
                    sessionToken: sessionToken,
                    clientPid: clientPid,
                    clientName: clientName
                )
            }
            guard isCurrentBootstrapListener(server, lifecycleGeneration: expectedLifecycleGeneration) else {
                await server.stop()
                return
            }
            #if DEBUG
                print("[MCPStartup] BootstrapSocketServer.start succeeded socket=\(socketURL.path) generation=\(expectedLifecycleGeneration)")
            #endif
            bootstrapStartFailures = 0
            invalidateBootstrapRestartState()
        } catch {
            #if DEBUG
                print("[MCPStartup] BootstrapSocketServer.start failed: \(error)")
            #endif
            if bootstrapSocketServer === server,
               bootstrapSocketServerLifecycleGeneration == expectedLifecycleGeneration
            {
                bootstrapSocketServer = nil
                bootstrapSocketServerLifecycleGeneration = nil
                scheduleBootstrapSocketServerStartForCurrentLifecycleIfNeeded(excluding: expectedLifecycleGeneration)
            }
            guard isCurrentLifecycle(expectedLifecycleGeneration) else { return }
            bootstrapStartFailures += 1
            log.error("Failed to start bootstrap socket server: \(error) (failures=\(bootstrapStartFailures))")
            let delay = bootstrapBackoffDelay(for: bootstrapStartFailures)
            restartBootstrapSocketServer(
                reason: "start_failed",
                delay: delay,
                lifecycleGeneration: expectedLifecycleGeneration
            )
        }
    }

    /// Handles a new connection from the bootstrap socket.
    /// Returns an Admission with postAccept closure for MCP server startup.
    ///
    /// IMPORTANT: Connection registration is deferred to postAccept to avoid "ghost" connections
    /// if the "accepted" response fails to send. Capacity is reserved here and released on
    /// commit (postAccept) or rollback (onAcceptAborted).
    private func handleBootstrapConnection(
        sourceListener: BootstrapSocketServer,
        lifecycleGeneration admissionLifecycleGeneration: UInt64,
        clientFD: Int32,
        sessionToken: String,
        clientPid: Int,
        clientName: String?
    ) async -> BootstrapSocketServer.Admission {
        let connectionID = UUID()
        connectionLog("Bootstrap socket connection: \(connectionID) from '\(clientName ?? "unknown")' (pid=\(clientPid), session=\(sessionToken.prefix(8))...)")
        mcpACPLog("[MCP-ACP] bootstrap connection connection=\(connectionID) bootstrapClientName=\(clientName ?? "unknown") pid=\(clientPid)")

        guard isCurrentBootstrapListener(sourceListener, lifecycleGeneration: admissionLifecycleGeneration) else {
            return rejectBootstrapAdmissionBecauseStopped(connectionID: connectionID)
        }

        // Clean up any expired reservations (safety net)
        cleanupExpiredBootstrapReservations()

        // Early rejection if session is blocked (avoids pointless reservation)
        if isSessionBlocked(sessionToken) {
            let reason = "Session blocked"
            log.warning("Rejecting bootstrap connection \(connectionID) - session in cooldown")
            return .reject(.rejected(reason: reason, errorCode: MCPBootstrapErrorCode.sessionBlocked.rawValue))
        }

        // Brief cooldown for user-killed clientIDs (prevents auto-reconnect race)
        if let clientName, isClientInUserKillCooldown(clientName) {
            let remaining = remainingUserKillCooldown(clientName).map { Int($0) } ?? 0
            let reason = "Client temporarily blocked (retry in ~\(remaining)s)"
            log.warning("Rejecting bootstrap connection \(connectionID) - client '\(clientName)' in cooldown")
            return .reject(.rejected(reason: reason, errorCode: MCPBootstrapErrorCode.clientCooldown.rawValue))
        }

        // This pre-await snapshot is only a policy-readiness hint. Capacity must resolve the
        // current replacement from the durable session token after every suspension.
        let replacementBeforePolicyReadiness = currentBootstrapReplacementConnectionID(
            forSessionToken: sessionToken
        )

        let policyReadiness = await awaitAgentBootstrapPolicyBeforeAcceptIfNeeded(
            bootstrapClientName: clientName,
            connectionID: connectionID,
            sessionKey: sessionToken,
            clientPid: clientPid,
            isReplacementForSession: replacementBeforePolicyReadiness != nil
        )
        if policyReadiness == .timedOut {
            return .reject(.rejected(
                reason: "Agent policy admission timed out.",
                errorCode: MCPBootstrapErrorCode.serverNotReady.rawValue
            ))
        }
        guard isCurrentBootstrapListener(sourceListener, lifecycleGeneration: admissionLifecycleGeneration) else {
            return rejectBootstrapAdmissionBecauseStopped(connectionID: connectionID)
        }
        #if DEBUG
            await debugAfterBootstrapPolicyReadinessForTesting?(sessionToken)
            guard isCurrentBootstrapListener(sourceListener, lifecycleGeneration: admissionLifecycleGeneration) else {
                return rejectBootstrapAdmissionBecauseStopped(connectionID: connectionID)
            }
        #endif

        guard claimBootstrapAdmission(
            sessionToken: sessionToken,
            connectionID: connectionID,
            lifecycleGeneration: admissionLifecycleGeneration
        ) else {
            log.notice("Rejecting concurrent bootstrap admission \(connectionID) for an already-pending durable session token")
            return .reject(.rejected(
                reason: "Session connection already pending",
                errorCode: MCPBootstrapErrorCode.capacityExceeded.rawValue
            ))
        }

        let replacementCredit = bootstrapAdmissionClaimsBySessionToken[sessionToken]?.replacementCredit
        let capacityResult = await ensureGlobalCapacityForBootstrapAdmission(
            sourceListener: sourceListener,
            lifecycleGeneration: admissionLifecycleGeneration,
            prospectiveReplacementCredit: replacementCredit
        )
        switch capacityResult {
        case .available:
            break
        case .capacityExceeded:
            releaseBootstrapAdmissionClaim(
                sessionToken: sessionToken,
                connectionID: connectionID,
                lifecycleGeneration: admissionLifecycleGeneration
            )
            log.warning("At global capacity and no evictable candidate; rejecting bootstrap connection \(connectionID)")
            return .reject(.rejected(reason: "Server at capacity", errorCode: MCPBootstrapErrorCode.capacityExceeded.rawValue))
        case .admissionContextInvalidated:
            releaseBootstrapAdmissionClaim(
                sessionToken: sessionToken,
                connectionID: connectionID,
                lifecycleGeneration: admissionLifecycleGeneration
            )
            return rejectBootstrapAdmissionBecauseStopped(connectionID: connectionID)
        }

        guard isCurrentBootstrapListener(sourceListener, lifecycleGeneration: admissionLifecycleGeneration) else {
            releaseBootstrapAdmissionClaim(
                sessionToken: sessionToken,
                connectionID: connectionID,
                lifecycleGeneration: admissionLifecycleGeneration
            )
            return rejectBootstrapAdmissionBecauseStopped(connectionID: connectionID)
        }
        return makeAcceptedBootstrapAdmission(
            connectionID: connectionID,
            lifecycleGeneration: admissionLifecycleGeneration,
            sessionToken: sessionToken,
            clientPid: clientPid,
            clientName: clientName
        )
    }

    private enum BootstrapAdmissionCapacityResult: Equatable {
        case available
        case capacityExceeded
        case admissionContextInvalidated
    }

    private func ensureGlobalCapacityForBootstrapAdmission(
        sourceListener: BootstrapSocketServer?,
        lifecycleGeneration admissionLifecycleGeneration: UInt64?,
        prospectiveReplacementCredit: BootstrapReplacementCredit?
    ) async -> BootstrapAdmissionCapacityResult {
        guard isCurrentBootstrapAdmissionContext(
            sourceListener: sourceListener,
            lifecycleGeneration: admissionLifecycleGeneration
        ) else { return .admissionContextInvalidated }

        while true {
            if effectiveGlobalAdmissionLoad(
                prospectiveReplacementCredit: prospectiveReplacementCredit
            ) < maxGlobalConnections {
                return .available
            }

            let evictionResult = await evictLeastValuableGlobalForAdmission(
                preserveOnePerClient: preserveOnePerClient,
                sourceListener: sourceListener,
                lifecycleGeneration: admissionLifecycleGeneration,
                capacityPredicate: .bootstrap(
                    prospectiveReplacementCredit: prospectiveReplacementCredit
                )
            )
            guard isCurrentBootstrapAdmissionContext(
                sourceListener: sourceListener,
                lifecycleGeneration: admissionLifecycleGeneration
            ) else { return .admissionContextInvalidated }

            if effectiveGlobalAdmissionLoad(
                prospectiveReplacementCredit: prospectiveReplacementCredit
            ) < maxGlobalConnections {
                return .available
            }

            switch evictionResult {
            case .evicted, .capacityChanged:
                continue
            case .noProgress:
                return .capacityExceeded
            case .admissionContextInvalidated:
                return .admissionContextInvalidated
            }
        }
    }

    private func isCurrentLifecycle(_ generation: UInt64) -> Bool {
        isRunningState && lifecycleGeneration == generation
    }

    private func rejectBootstrapAdmissionBecauseStopped(connectionID: UUID) -> BootstrapSocketServer.Admission {
        connectionLog("Rejecting bootstrap connection \(connectionID) - manager stopped")
        return .reject(.rejected(reason: "Server unavailable", errorCode: "server_unavailable"))
    }

    private func makeAcceptedBootstrapAdmission(
        connectionID: UUID,
        lifecycleGeneration admissionLifecycleGeneration: UInt64,
        sessionToken: String,
        clientPid: Int,
        clientName: String?
    ) -> BootstrapSocketServer.Admission {
        guard reserveBootstrapSlot(
            connectionID: connectionID,
            lifecycleGeneration: admissionLifecycleGeneration,
            sessionToken: sessionToken
        ) else {
            releaseBootstrapAdmissionClaim(
                sessionToken: sessionToken,
                connectionID: connectionID,
                lifecycleGeneration: admissionLifecycleGeneration
            )
            log.error("Bootstrap admission \(connectionID) lost its durable-token claim before reservation")
            return .reject(.rejected(reason: "Server unavailable", errorCode: MCPBootstrapErrorCode.serverUnavailable.rawValue))
        }
        connectionLog("handleBootstrapConnection: returning Admission.accept for \(connectionID)")

        // NOTE: Using strong capture [self] to ensure reservation cleanup always reaches
        // the owning manager. These closures are short-lived and not stored long-term.
        return .accept(
            publishTransferredFD: { [transferredBootstrapSockets] clientFD in
                transferredBootstrapSockets.publish(
                    connectionID: connectionID,
                    lifecycleGeneration: admissionLifecycleGeneration,
                    fd: clientFD
                )
            },
            postAccept: { [self] in
                await commitAcceptedBootstrapConnection(
                    connectionID: connectionID,
                    lifecycleGeneration: admissionLifecycleGeneration,
                    sessionToken: sessionToken,
                    clientPid: clientPid,
                    clientName: clientName
                )
            },
            onAcceptAborted: { [self] in
                await rollbackBootstrapReservation(
                    connectionID: connectionID,
                    lifecycleGeneration: admissionLifecycleGeneration,
                    reason: "accept aborted"
                )
            }
        )
    }

    private func commitAcceptedBootstrapConnection(
        connectionID: UUID,
        lifecycleGeneration admissionLifecycleGeneration: UInt64,
        sessionToken: String,
        clientPid: Int,
        clientName: String?
    ) async {
        guard let reservation = bootstrapReservations[connectionID],
              reservation.lifecycleGeneration == admissionLifecycleGeneration,
              !reservation.isCommitting,
              isCurrentLifecycle(admissionLifecycleGeneration)
        else {
            closeTransferredBootstrapSocket(
                connectionID: connectionID,
                lifecycleGeneration: admissionLifecycleGeneration
            )
            if isRunningState {
                log.warning("commitAcceptedBootstrapConnection: no current reservation found for \(connectionID) while running")
            }
            return
        }
        guard Date().timeIntervalSince(reservation.createdAt) < bootstrapReservationTTL,
              isCurrentBootstrapCommit(
                  connectionID: connectionID,
                  lifecycleGeneration: admissionLifecycleGeneration
              )
        else {
            await abandonPendingBootstrapCommit(
                connectionID: connectionID,
                lifecycleGeneration: admissionLifecycleGeneration,
                reason: "reservation expired or invalid before commit"
            )
            return
        }

        guard let committedFD = transferredBootstrapSockets.claim(
            connectionID: connectionID,
            lifecycleGeneration: admissionLifecycleGeneration
        ) else {
            await abandonPendingBootstrapCommit(
                connectionID: connectionID,
                lifecycleGeneration: admissionLifecycleGeneration,
                reason: "transferred fd missing before preparation"
            )
            return
        }

        let preparedConnection: BootstrapSocketConnectionManager
        do {
            preparedConnection = try prepareBootstrapConnection(
                connectionID: connectionID,
                sessionToken: sessionToken,
                clientPid: clientPid,
                clientName: clientName,
                clientFD: committedFD
            )
        } catch {
            log.error("Failed to prepare bootstrap connection manager \(connectionID): \(String(describing: error))")
            await abandonPendingBootstrapCommit(
                connectionID: connectionID,
                lifecycleGeneration: admissionLifecycleGeneration,
                reason: "connection preparation failed"
            )
            return
        }

        guard var committingReservation = bootstrapReservations[connectionID],
              committingReservation.lifecycleGeneration == admissionLifecycleGeneration,
              !committingReservation.isCommitting,
              isCurrentLifecycle(admissionLifecycleGeneration),
              isCurrentBootstrapAdmissionClaim(
                  sessionToken: sessionToken,
                  connectionID: connectionID,
                  lifecycleGeneration: admissionLifecycleGeneration
              )
        else {
            await preparedConnection.stop()
            await abandonPendingBootstrapCommit(
                connectionID: connectionID,
                lifecycleGeneration: admissionLifecycleGeneration,
                reason: "reservation invalidated during preparation"
            )
            return
        }
        committingReservation.committingConnection = preparedConnection
        bootstrapReservations[connectionID] = committingReservation

        guard isCurrentBootstrapCommit(
            connectionID: connectionID,
            lifecycleGeneration: admissionLifecycleGeneration,
            preparedConnection: preparedConnection
        ) else {
            await abandonPendingBootstrapCommit(
                connectionID: connectionID,
                lifecycleGeneration: admissionLifecycleGeneration,
                reason: "commit invalidated before publication"
            )
            return
        }

        let committedPredecessorRemoval: CommittedConnectionRemoval?
        if let replacementCredit = committingReservation.replacementCredit {
            guard isValidBootstrapReplacementCredit(
                replacementCredit,
                reservationConnectionID: connectionID,
                reservationLifecycleGeneration: admissionLifecycleGeneration
            ),
                let committedRemoval = commitConnectionRemoval(
                    connectionID: replacementCredit.predecessorConnectionID,
                    expectedIdentity: replacementCredit.predecessorConnectionIdentity,
                    expectedLifecycleGeneration: replacementCredit.predecessorLifecycleGeneration
                )
            else {
                await abandonPendingBootstrapCommit(
                    connectionID: connectionID,
                    lifecycleGeneration: admissionLifecycleGeneration,
                    reason: "replacement predecessor fence invalidated"
                )
                return
            }
            committedPredecessorRemoval = committedRemoval
        } else {
            guard existingConnectionID(forSessionToken: sessionToken) == nil else {
                await abandonPendingBootstrapCommit(
                    connectionID: connectionID,
                    lifecycleGeneration: admissionLifecycleGeneration,
                    reason: "session rebound without exact replacement credit"
                )
                return
            }
            committedPredecessorRemoval = nil
        }

        // From exact predecessor-removal commitment through successor publication and
        // reservation consumption there is no suspension. A hung predecessor stop can no
        // longer retain the successor FD inside a non-expiring committing reservation.
        guard registerAndStartBootstrapConnection(
            connectionID: connectionID,
            lifecycleGeneration: admissionLifecycleGeneration,
            sessionToken: sessionToken,
            clientPid: clientPid,
            clientName: clientName,
            manager: preparedConnection
        ) else {
            if let committedPredecessorRemoval {
                _ = rollbackCommittedConnectionRemoval(committedPredecessorRemoval)
            }
            await abandonPendingBootstrapCommit(
                connectionID: connectionID,
                lifecycleGeneration: admissionLifecycleGeneration,
                reason: "registration context invalidated"
            )
            return
        }
        let consumedReservation = takeBootstrapReservation(
            connectionID: connectionID,
            lifecycleGeneration: admissionLifecycleGeneration
        )
        if consumedReservation == nil {
            log.critical("Published bootstrap connection \(connectionID) without its exact committing reservation")
            releaseBootstrapAdmissionClaim(
                sessionToken: sessionToken,
                connectionID: connectionID,
                lifecycleGeneration: admissionLifecycleGeneration
            )
        }
        if let committedPredecessorRemoval {
            scheduleBootstrapPredecessorCleanup(committedPredecessorRemoval)
        }
    }

    private func isCurrentBootstrapCommit(
        connectionID: UUID,
        lifecycleGeneration: UInt64,
        preparedConnection: BootstrapSocketConnectionManager? = nil
    ) -> Bool {
        guard isCurrentLifecycle(lifecycleGeneration),
              let reservation = bootstrapReservations[connectionID],
              reservation.lifecycleGeneration == lifecycleGeneration,
              isCurrentBootstrapAdmissionClaim(
                  sessionToken: reservation.sessionToken,
                  connectionID: connectionID,
                  lifecycleGeneration: lifecycleGeneration
              )
        else { return false }
        if let preparedConnection {
            return reservation.committingConnection === preparedConnection
        }
        guard !reservation.isCommitting,
              Date().timeIntervalSince(reservation.createdAt) < bootstrapReservationTTL
        else { return false }
        return transferredBootstrapSockets.contains(
            connectionID: connectionID,
            lifecycleGeneration: lifecycleGeneration
        )
    }

    private func rollbackCommittedConnectionRemoval(
        _ committedRemoval: CommittedConnectionRemoval
    ) -> Bool {
        guard connectionsBeingRemoved.contains(committedRemoval.connectionID),
              connectionLifecycleGenerationByID[committedRemoval.connectionID] == committedRemoval.lifecycleGeneration,
              let connection = connections[committedRemoval.connectionID],
              ObjectIdentifier(connection as AnyObject) == committedRemoval.connectionIdentity
        else { return false }
        connectionsBeingRemoved.remove(committedRemoval.connectionID)
        return true
    }

    private func scheduleBootstrapPredecessorCleanup(
        _ committedRemoval: CommittedConnectionRemoval
    ) {
        #if DEBUG
            let graceSleep = debugBootstrapPredecessorStopGraceSleepForTesting ?? { duration in
                try await Task.sleep(for: duration)
            }
        #else
            let graceSleep: @Sendable (Duration) async throws -> Void = { duration in
                try await Task.sleep(for: duration)
            }
        #endif
        Task { [weak self] in
            guard let self else { return }
            let closeContext = MCPConnectionCloseContext(
                reason: TerminationReason.connectionReplaced.rawValue,
                initiator: .app
            )
            await persistAcceptedSocketTerminalRecord(
                connectionID: committedRemoval.connectionID,
                context: closeContext
            )
            let race = MCPConnectionStopRace()
            Task {
                await committedRemoval.connection.stop()
                await race.resolve(.stopped)
            }
            Task {
                do {
                    try await graceSleep(MCPTimeoutPolicy.bootstrapReplacementPredecessorStopGrace)
                } catch {
                    return
                }
                await race.resolve(.deadlineElapsed)
            }

            let outcome = await race.wait()
            if case .deadlineElapsed = outcome {
                log.warning(
                    "Bootstrap predecessor stop grace elapsed; detaching exact committed removal \(committedRemoval.connectionID) while its stop task continues."
                )
            }
            _ = await removeConnection(
                committedRemoval.connectionID,
                committedRemoval: committedRemoval,
                connectionAlreadyStopped: true,
                context: closeContext
            )
        }
    }

    private func abandonPendingBootstrapCommit(
        connectionID: UUID,
        lifecycleGeneration: UInt64,
        reason: String
    ) async {
        let reservation = takeBootstrapReservation(
            connectionID: connectionID,
            lifecycleGeneration: lifecycleGeneration
        )
        closeTransferredBootstrapSocket(
            connectionID: connectionID,
            lifecycleGeneration: lifecycleGeneration
        )
        await reservation?.committingConnection?.stop()
        connectionLog("Abandoned pending bootstrap commit \(connectionID) (\(reason))")
    }

    #if DEBUG
        func debugMakeReservedBootstrapAdmissionForShutdownTest(
            connectionID: UUID,
            sessionToken: String,
            clientPid: Int,
            clientName: String?,
            clientFD: Int32
        ) async -> BootstrapSocketServer.Admission? {
            guard isRunningState,
                  claimBootstrapAdmission(
                      sessionToken: sessionToken,
                      connectionID: connectionID,
                      lifecycleGeneration: lifecycleGeneration
                  )
            else { return nil }
            let admission = makeAcceptedBootstrapAdmission(
                connectionID: connectionID,
                lifecycleGeneration: lifecycleGeneration,
                sessionToken: sessionToken,
                clientPid: clientPid,
                clientName: clientName
            )
            guard admission.publishTransferredFD?(clientFD) == true else {
                await rollbackBootstrapReservation(
                    connectionID: connectionID,
                    lifecycleGeneration: lifecycleGeneration,
                    reason: "DEBUG test publication failed"
                )
                return nil
            }
            return admission
        }

        func debugContainsConnection(_ id: UUID) -> Bool {
            connections[id] != nil
        }

        func debugBootstrapReservationCount() -> Int {
            bootstrapReservations.count
        }

        func debugTransferredBootstrapSocketCountForShutdownTest() -> Int {
            transferredBootstrapSockets.debugEntryCount
        }
    #endif

    private func prepareBootstrapConnection(
        connectionID: UUID,
        sessionToken: String,
        clientPid: Int,
        clientName: String?,
        clientFD: Int32
    ) throws -> BootstrapSocketConnectionManager {
        let purpose = purposeForNewBootstrapConnection(
            clientName: clientName,
            sessionToken: sessionToken
        )

        // Do not block first-frame MCP startup on MainActor/global settings during bootstrap.
        // The instructions resource path reads the live Code Maps setting later; defaulting
        // the initial server instructions to enabled keeps CLI initialize responsive.
        let codeMapsDisabled = false
        return try BootstrapSocketConnectionManager(
            connectionID: connectionID,
            sessionToken: sessionToken,
            clientPid: clientPid,
            clientName: clientName,
            purpose: purpose,
            codeMapsDisabled: codeMapsDisabled,
            connectedFD: clientFD,
            parentManager: self
        )
    }

    /// Registers a prepared bootstrap connection and starts its MCP server.
    /// Called from postAccept AFTER the "accepted" response has been successfully sent.
    @discardableResult
    private func registerAndStartBootstrapConnection(
        connectionID: UUID,
        lifecycleGeneration: UInt64,
        sessionToken: String,
        clientPid: Int,
        clientName: String?,
        manager: BootstrapSocketConnectionManager
    ) -> Bool {
        guard isRunningState, self.lifecycleGeneration == lifecycleGeneration else {
            return false
        }

        // Initialize identity context only after manager construction succeeds.
        let identityContext = ConnectionIdentityContext(
            clientName: clientName,
            capabilityToken: sessionToken,
            source: .handshake,
            hasHandshake: false,
            lastUpdated: Date()
        )
        identityContextByConnection[connectionID] = identityContext

        if let name = clientName, !name.isEmpty {
            pendingConnections[connectionID] = name
        }
        mcpACPLog("[MCP-ACP] registered bootstrap connection connection=\(connectionID) pendingClientName=\(clientName ?? "unknown")")

        connections[connectionID] = manager
        bootstrapPeerPIDByConnectionID[connectionID] = clientPid
        callLimiters[connectionID] = MCPConnectionCallLimiters(
            limit: limiterLimit(for: connectionID),
            controlLimit: controlLimiterLimit(for: connectionID),
            smallReadLimit: smallReadLimiterLimit(for: connectionID),
            gitReadLimit: gitReadLimiterLimit(for: connectionID),
            fileSearchLimit: fileSearchLimiterLimit(for: connectionID)
        )
        connectionLifecycleGenerationByID[connectionID] = lifecycleGeneration
        bindSessionToken(sessionToken, to: connectionID)
        if connectionStats[connectionID] == nil {
            connectionStats[connectionID] = ConnectionStats(
                createdAt: Date(),
                totalToolCalls: 0,
                lastToolCallAt: nil
            )
        }
        #if DEBUG
            debugRecordConnectionEvent(
                "registered",
                connectionID: connectionID,
                reason: "bootstrap",
                clientName: clientName,
                sessionToken: sessionToken
            )
        #endif

        // Notify dashboard
        emitDashboardUpdate()

        // Start MCP server FIRST to minimize time-to-first-MCP-frame
        // (CLI may send MCP frames immediately after receiving "accepted")
        startMCPServerForConnection(
            connectionID: connectionID,
            lifecycleGeneration: lifecycleGeneration,
            sessionToken: sessionToken,
            clientPid: clientPid,
            manager: manager
        )

        // Capture window count concurrently (don't block MCP server startup on MainActor).
        // Note: There's a brief window where windowCountAtConnectionTime[id] is nil.
        // Routing logic treats nil as unknown and falls back to current window topology.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let count = WindowStatesManager.shared.allWindows.count
            await setWindowCountAtConnectionTime(
                connectionID: connectionID,
                lifecycleGeneration: lifecycleGeneration,
                count: count
            )
        }
        return true
    }

    /// Sets the window count at connection time (called from MainActor task)
    private func setWindowCountAtConnectionTime(connectionID: UUID, lifecycleGeneration expectedLifecycleGeneration: UInt64, count: Int) {
        guard isCurrentConnection(connectionID, lifecycleGeneration: expectedLifecycleGeneration) else { return }
        windowCountAtConnectionTime[connectionID] = count
    }

    private func purposeForNewBootstrapConnection(
        clientName: String?,
        sessionToken: String
    ) -> MCPRunPurpose {
        if let existingConnectionID = existingConnectionID(forSessionToken: sessionToken),
           let existingPurpose = runPurposeByConnection[existingConnectionID],
           existingPurpose != .unknown
        {
            return existingPurpose
        }

        guard let clientName,
              !clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .unknown
        }

        pruneExpiredPolicies(for: clientName)
        let matchingKeys = matchingClientKeys(for: clientName, in: Array(pendingPoliciesByClient.keys))
        let pendingPurpose = matchingKeys
            .compactMap { key -> (key: String, createdAt: Date, purpose: MCPRunPurpose)? in
                guard let policy = pendingPoliciesByClient[key]?.first else { return nil }
                return (key: key, createdAt: policy.createdAt, purpose: policy.purpose)
            }
            .min { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.key < rhs.key
                }
                return lhs.createdAt < rhs.createdAt
            }?
            .purpose
        if let pendingPurpose {
            return pendingPurpose
        }

        if let livePurpose = preferredLiveRunAffinity(for: clientName, sessionKey: sessionToken)?.purpose {
            return livePurpose
        }

        return .unknown
    }

    private func isCurrentConnection(_ connectionID: UUID, lifecycleGeneration expectedLifecycleGeneration: UInt64) -> Bool {
        isCurrentLifecycle(expectedLifecycleGeneration)
            && !connectionsBeingRemoved.contains(connectionID)
            && connectionLifecycleGenerationByID[connectionID] == expectedLifecycleGeneration
            && connections[connectionID] != nil
    }

    /// Starts the MCP server for a bootstrap connection.
    /// Called from postAccept after the "accepted" response has been sent to the CLI.
    private func startMCPServerForConnection(
        connectionID: UUID,
        lifecycleGeneration expectedLifecycleGeneration: UInt64,
        sessionToken: String,
        clientPid: Int,
        manager: BootstrapSocketConnectionManager
    ) {
        // Spawn the MCP server task - this runs after CLI has received "accepted"
        let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        connectionTasks[connectionID] = Task {
            let startupState = EditFlowPerf.begin(EditFlowPerf.Stage.Bootstrap.postAcceptStartup)
            var startupOutcome = "cancelled"
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.Bootstrap.postAcceptStartupBegan,
                correlation: lifecycleCorrelation
            )
            defer {
                self.connectionTasks.removeValue(forKey: connectionID)
                EditFlowPerf.end(
                    EditFlowPerf.Stage.Bootstrap.postAcceptStartup,
                    startupState,
                    EditFlowPerf.Dimensions(outcome: startupOutcome)
                )
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.Bootstrap.postAcceptStartupEnded,
                    correlation: lifecycleCorrelation,
                    EditFlowPerf.Dimensions(outcome: startupOutcome)
                )
            }
            guard self.isCurrentConnection(connectionID, lifecycleGeneration: expectedLifecycleGeneration) else {
                startupOutcome = "stale"
                return
            }
            do {
                guard let approvalHandler = self.connectionApprovalHandler else {
                    log.error("No connection approval handler set, rejecting bootstrap connection")
                    await removeConnection(
                        connectionID,
                        context: MCPConnectionCloseContext(
                            reason: "connection_approval_handler_unavailable",
                            initiator: .app
                        )
                    )
                    return
                }

                connectionLog("Starting MCP server for bootstrap connection \(connectionID)")
                mcpACPLog("[MCP-ACP] starting MCP server connection=\(connectionID)")
                try await manager.start { clientInfo in
                    guard self.isCurrentConnection(connectionID, lifecycleGeneration: expectedLifecycleGeneration) else { return false }
                    connectionLog("MCP handshake callback for \(connectionID): clientName='\(clientInfo.name)'")
                    mcpACPLog("[MCP-ACP] handshake connection=\(connectionID) clientName=\(clientInfo.name)")

                    // Update identity context
                    if var ctx = self.identityContextByConnection[connectionID] {
                        ctx.clientName = clientInfo.name
                        ctx.hasHandshake = true
                        ctx.source = .handshake
                        ctx.lastUpdated = Date()
                        self.identityContextByConnection[connectionID] = ctx
                    }

                    let bootstrapClientName = self.pendingConnections[connectionID]
                    self.pendingConnections[connectionID] = clientInfo.name
                    self.emitDashboardUpdate()

                    // Validate client name
                    let trimmedName = clientInfo.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedName.isEmpty {
                        await self.recordIdentityFailure(for: connectionID, source: .filesystem, reason: "Bootstrap handshake provided empty client name")
                        return false
                    }

                    // Check cooldown
                    if self.isSessionBlocked(sessionToken) {
                        log.warning("Rejecting bootstrap connection \(connectionID) - session in cooldown")
                        return false
                    }

                    connectionLog("Calling approval handler for \(connectionID) client='\(clientInfo.name)'")
                    let approved = await approvalHandler(connectionID, clientInfo)
                    guard self.isCurrentConnection(connectionID, lifecycleGeneration: expectedLifecycleGeneration) else { return false }
                    connectionLog("Approval handler returned \(approved) for \(connectionID)")
                    if approved {
                        #if DEBUG
                            let diagnosticPolicy = self.oldestPendingPolicyEntry(for: clientInfo.name) { policy in
                                self.canConsumePendingPolicy(
                                    policy,
                                    clientName: clientInfo.name,
                                    clientPid: clientPid
                                )
                            }
                            if let diagnosticPolicy, let runID = diagnosticPolicy.policy.runID {
                                let expectedPIDs = self.expectedAgentPIDs(for: clientInfo.name, runID: runID)
                                    .map(String.init)
                                    .sorted()
                                    .joined(separator: ",")
                                self.debugRecordRunRoutingEvent(
                                    runID: runID,
                                    event: "client_identity_observed",
                                    connectionID: connectionID,
                                    fields: [
                                        "bootstrap_client_name": bootstrapClientName ?? "nil",
                                        "authoritative_client_name": clientInfo.name,
                                        "helper_peer_pid": String(clientPid),
                                        "ancestor_chain": self.pidAncestorChainDescription(from: pid_t(clientPid)),
                                        "expected_pids": expectedPIDs,
                                        "pending_policy_key": diagnosticPolicy.key,
                                        "policy_consumable": String(self.canConsumePendingPolicy(
                                            diagnosticPolicy.policy,
                                            clientName: clientInfo.name,
                                            clientPid: clientPid
                                        ))
                                    ]
                                )
                            }
                        #endif
                        let readiness = await self.awaitAgentPolicyAdmissionIfNeeded(
                            clientName: clientInfo.name,
                            bootstrapClientName: bootstrapClientName,
                            connectionID: connectionID,
                            sessionKey: sessionToken,
                            clientPid: clientPid
                        )
                        guard self.isCurrentConnection(connectionID, lifecycleGeneration: expectedLifecycleGeneration) else { return false }
                        if readiness == .timedOut {
                            self.pendingConnections.removeValue(forKey: connectionID)
                            return false
                        }

                        let policyOutcome = await self.applyPendingPolicyIfAvailable(
                            clientName: clientInfo.name,
                            connectionID: connectionID,
                            clientPid: clientPid,
                            bootstrapClientName: bootstrapClientName,
                            expectedLifecycleGeneration: expectedLifecycleGeneration
                        )
                        guard self.isCurrentConnection(connectionID, lifecycleGeneration: expectedLifecycleGeneration) else { return false }
                        if case let .rejected(runID, reason) = policyOutcome {
                            mcpPolicyLog(
                                "rejected MCP initialize after pid-gated policy wait client=\(clientInfo.name) connection=\(connectionID) runID=\(runID?.uuidString ?? "nil") reason=\(reason)"
                            )
                            self.pendingConnections.removeValue(forKey: connectionID)
                            return false
                        }
                        self.notifyConnectionWaiters(
                            connectionID: connectionID,
                            clientName: clientInfo.name,
                            lifecycleGeneration: expectedLifecycleGeneration
                        )

                        // Do not block MCP initialize on window binding/readiness/cache warming.
                        // Policy admission and waiter notification are complete; finish catalog prep opportunistically.
                        Task {
                            guard self.isCurrentConnection(connectionID, lifecycleGeneration: expectedLifecycleGeneration) else { return }
                            let windowID = await self.ensureWindowBindingIfUnambiguous(connectionID: connectionID, reason: "handshake")
                            guard self.isCurrentConnection(connectionID, lifecycleGeneration: expectedLifecycleGeneration) else { return }
                            let ready = await MCPToolCatalogReadiness.shared.awaitReady(
                                windowID: windowID,
                                timeout: MCPToolCatalogReadiness.defaultTimeout
                            )
                            guard self.isCurrentConnection(connectionID, lifecycleGeneration: expectedLifecycleGeneration) else { return }
                            if !ready {
                                log.warning("Tool catalog not ready for connection \(connectionID) window=\(windowID.map(String.init) ?? "nil") - proceeding anyway")
                            }

                            if let windowID {
                                await MCPToolCatalogReadiness.shared.warmToolCache(windowID: windowID)
                            }
                        }
                    } else {
                        self.pendingConnections.removeValue(forKey: connectionID)
                    }
                    return approved
                }

                guard self.isCurrentConnection(connectionID, lifecycleGeneration: expectedLifecycleGeneration) else { return }

                // Update identity after successful start
                if var ctx = self.identityContextByConnection[connectionID] {
                    ctx.hasHandshake = true
                    self.identityContextByConnection[connectionID] = ctx
                }
                self.emitDashboardUpdate()
                startupOutcome = "started"

            } catch {
                startupOutcome = error is CancellationError ? "cancelled" : "error"
                log.error("Bootstrap connection \(connectionID) start failed: \(error)")
                let transportSnapshot = await manager.startupFailureTransportCloseSnapshot()
                guard self.isCurrentConnection(connectionID, lifecycleGeneration: expectedLifecycleGeneration) else { return }
                await removeConnection(
                    connectionID,
                    context: MCPConnectionCloseContext.startupFailure(
                        error: error,
                        transportSnapshot: transportSnapshot
                    )
                )
            }
        }
    }

    /// Stops one published bootstrap listener. Actor reentrancy means a replacement
    /// listener may be published while the cross-actor stop awaits; only clear the
    /// listener slot when the identity and lifecycle generation still match.
    private func stopBootstrapSocketServer(server: BootstrapSocketServer?, lifecycleGeneration expectedLifecycleGeneration: UInt64) async {
        guard let server,
              bootstrapSocketServer === server,
              bootstrapSocketServerLifecycleGeneration == expectedLifecycleGeneration
        else { return }

        await server.stop()
        #if DEBUG
            await debugSuspendLifecycleFenceCheckpointIfNeeded(.listenerStopReturnedBeforeConditionalClear)
        #endif

        guard bootstrapSocketServer === server,
              bootstrapSocketServerLifecycleGeneration == expectedLifecycleGeneration
        else { return }
        bootstrapSocketServer = nil
        bootstrapSocketServerLifecycleGeneration = nil

        scheduleBootstrapSocketServerStartForCurrentLifecycleIfNeeded(excluding: expectedLifecycleGeneration)
    }

    /// If stale listener teardown or startup failure cleared an older publication after a
    /// cold start began, restore the current lifecycle promptly. Maintenance is the fallback.
    private func scheduleBootstrapSocketServerStartForCurrentLifecycleIfNeeded(excluding staleLifecycleGeneration: UInt64) {
        let replacementLifecycleGeneration = lifecycleGeneration
        guard replacementLifecycleGeneration != staleLifecycleGeneration,
              isCurrentLifecycle(replacementLifecycleGeneration),
              bootstrapSocketServer == nil
        else { return }

        Task { [weak self] in
            await self?.startBootstrapSocketServer(lifecycleGeneration: replacementLifecycleGeneration)
        }
    }

    func stop() async {
        connectionLog("Stopping network manager")
        let stoppedLifecycleGeneration = lifecycleGeneration
        let listenerToStop = bootstrapSocketServerLifecycleGeneration == stoppedLifecycleGeneration
            ? bootstrapSocketServer
            : nil
        let connectionsToStop = connections.compactMap { connectionID, connectionManager -> (UUID, any MCPServerConnection)? in
            guard connectionLifecycleGenerationByID[connectionID] == stoppedLifecycleGeneration else { return nil }
            return (connectionID, connectionManager)
        }
        let shutdownContext = MCPConnectionCloseContext(
            reason: "server_shutdown",
            initiator: .app
        )
        for (connectionID, _) in connectionsToStop {
            persistAcceptedSocketTerminalRecord(
                connectionID: connectionID,
                context: shutdownContext
            )
        }
        let limitersToStop = Array(callLimiters)
        let committingBootstrapConnectionsToStop = bootstrapReservations.values.compactMap { reservation in
            reservation.lifecycleGeneration == stoppedLifecycleGeneration
                ? reservation.committingConnection
                : nil
        }

        // This synchronous invalidation boundary executes before the first await. New starts
        // receive a new generation and stale listener/restart/connection resumptions can no
        // longer publish into that lifecycle.
        isRunningState = false
        lifecycleGeneration &+= 1
        invalidateBootstrapRestartState()
        if bootstrapStartLifecycleGeneration == stoppedLifecycleGeneration {
            bootstrapStartLifecycleGeneration = nil
            bootstrapStartInProgress = false
        }
        bootstrapSocketTask?.cancel()
        bootstrapSocketTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil

        // Invalidate synchronous transfer publication and close transferred-but-unregistered
        // sockets before awaiting listener teardown. This prevents old-lifecycle commits
        // from surviving a full stop followed by restart.
        let transferredBootstrapFDs = transferredBootstrapSockets.invalidateAndDrain(
            lifecycleGeneration: stoppedLifecycleGeneration
        )
        for fd in transferredBootstrapFDs {
            closeUnregisteredBootstrapFD(fd)
        }
        bootstrapReservations.removeAll()
        bootstrapAdmissionClaimsBySessionToken.removeAll()
        let waiterIDsToResume = connectionWaiters.compactMap { waiterID, waiter in
            waiter.lifecycleGeneration == stoppedLifecycleGeneration ? waiterID : nil
        }
        for waiterID in waiterIDsToResume {
            resumeWaiter(
                waiterID,
                lifecycleGeneration: stoppedLifecycleGeneration,
                with: nil
            )
        }

        // Detach only captured old-generation connection registries before yielding. Their
        // managers are stopped below, but a slow cross-actor stop must not leave stale sessions
        // visible to a replacement lifecycle or clear replacement registries when it resumes.
        for (id, _) in connectionsToStop {
            connectionTasks[id]?.cancel()
            connections.removeValue(forKey: id)
            connectionLifecycleGenerationByID.removeValue(forKey: id)
            bootstrapPeerPIDByConnectionID.removeValue(forKey: id)
            connectionTasks.removeValue(forKey: id)
            pendingConnections.removeValue(forKey: id)
            identityContextByConnection.removeValue(forKey: id)
            capabilityTokenByConnection.removeValue(forKey: id)
            connectionStats.removeValue(forKey: id)
        }
        callLimiters.removeAll()

        // Clear shared in-memory routing caches before yielding. A replacement lifecycle
        // may repopulate them while this shutdown awaits, so stale teardown must never
        // perform broad removeAll() operations after the first suspension point.
        pendingConnections.removeAll()
        identityContextByConnection.removeAll()
        capabilityTokenByConnection.removeAll()
        connectionIDBySessionToken.removeAll()
        sessionTokenBindingGeneration.removeAll()
        resetInMemoryRoutingCachesForRestart()
        for (connectionID, _) in connectionsToStop {
            terminalRecordClaimsByConnectionID.removeValue(forKey: connectionID)
        }

        for (_, limiters) in limitersToStop {
            await limiters.cancelAll()
        }
        for (connectionID, _) in limitersToStop {
            let cancelledToolCount = await cancelActiveToolsOwnedByConnection(
                connectionID,
                reason: shutdownContext.reason
            )
            if cancelledToolCount > 0 {
                connectionLog(
                    "Cancelled \(cancelledToolCount) active tool execution(s) owned by connection \(connectionID) during server shutdown"
                )
            }
        }

        await stopBootstrapSocketServer(server: listenerToStop, lifecycleGeneration: stoppedLifecycleGeneration)

        // The registry detach above was synchronous; stale resumptions below only stop the
        // captured manager objects and never mutate a replacement lifecycle's registries.
        for connectionManager in committingBootstrapConnectionsToStop {
            await connectionManager.stop()
        }
        for (id, connectionManager) in connectionsToStop {
            connectionLog("Stopping connection: \(id)")
            #if DEBUG
                debugRecordConnectionEvent("removed", connectionID: id, reason: shutdownContext.reason)
            #endif
            await connectionManager.stop()
        }
        await withTaskGroup(of: (UUID, [(MCPConnectionCallLane, Bool)]).self) { group in
            for (connectionID, limiters) in limitersToStop {
                group.addTask {
                    let results = await limiters.waitUntilIdle(
                        timeout: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace
                    )
                    return (connectionID, results)
                }
            }
            for await (connectionID, results) in group {
                for (lane, drained) in results where !drained {
                    connectionLog(
                        "Connection limiter cleanup grace expired during server shutdown: \(connectionID) lane=\(lane.rawValue)"
                    )
                }
            }
        }
        emitDashboardUpdate()
    }

    private func resetInMemoryRoutingCachesForRestart() {
        connectionWindowMap.removeAll()
        runIDByConnectionID.removeAll()
        windowAssignmentByConnection.removeAll()
        restrictedToolsByConnection.removeAll()
        additionalToolsByConnection.removeAll()
        runPurposeByConnection.removeAll()
        windowCountAtConnectionTime.removeAll()
        preassignedConnections.removeAll()
        pendingPoliciesByClient.removeAll()
        expectedAgentPIDsByClient.removeAll()
        expectedAgentPIDsByRunID.removeAll()
        runPolicyStateByRunID.removeAll()
        admittedPolicyRunIDs.removeAll()
        windowIDByRunID.removeAll()
        pendingPolicyApplicationIDByConnectionID.removeAll()
        pendingPolicyApplicationIDByRunID.removeAll()
        activeConnectionsByClient.removeAll()
        clientIDByConnection.removeAll()
        capabilityTokenByConnection.removeAll()
        connectionIDBySessionToken.removeAll()
        lastWindowByClientSession.removeAll()
        liveRunAffinityByClientSession.removeAll()
        activeToolScopesByWindow.removeAll()
        connectionStats.removeAll()
    }

    // MARK: - Termination & Kill Semantics

    /// Controls which termination side-effects are applied.
    /// Used to differentiate between hard kills (user boot) and soft disconnects (reconnection churn).
    private struct TerminationSemantics {
        var writeKillSignal: Bool
        var markSessionKilled: Bool
        var markClientUserKilled: Bool

        static let hardKill = TerminationSemantics(
            writeKillSignal: true,
            markSessionKilled: true,
            markClientUserKilled: true
        )

        static let softDisconnect = TerminationSemantics(
            writeKillSignal: false,
            markSessionKilled: false,
            markClientUserKilled: false
        )
    }

    /// Returns the default termination semantics for a given reason.
    private func defaultSemantics(for reason: TerminationReason) -> TerminationSemantics {
        switch reason {
        case .userBootFromDashboard:
            // User explicitly killed - full blocking
            TerminationSemantics(
                writeKillSignal: true,
                markSessionKilled: true,
                markClientUserKilled: true
            )
        case .runCompleted, .runCancelled, .serverShutdown, .approvalDenied:
            // Expected terminations - kill signal but no client cooldown
            TerminationSemantics(
                writeKillSignal: true,
                markSessionKilled: true,
                markClientUserKilled: false
            )
        case .idleTimeout:
            // Hygiene cleanup - allow clean reconnects.
            .softDisconnect
        case .connectionReplaced:
            // Default to hard behavior; caller can override for same-session replacement
            TerminationSemantics(
                writeKillSignal: true,
                markSessionKilled: true,
                markClientUserKilled: false
            )
        }
    }

    /// Checks if a session token is in termination cooldown (recently killed).
    /// Sessions in cooldown should be rejected on reconnect attempt.
    private func isSessionInTerminationCooldown(_ sessionToken: String?) -> Bool {
        guard let token = sessionToken,
              let killedAt = killedSessionTimestamps[token]
        else { return false }

        let elapsed = Date().timeIntervalSince(killedAt)
        if elapsed >= killedSessionTTL {
            // Expired - clean up
            killedSessionTokens.remove(token)
            killedSessionTimestamps.removeValue(forKey: token)
            return false
        }
        return true
    }

    /// Marks a session as killed (for cooldown deny on reconnect).
    private func markSessionAsKilled(_ sessionToken: String) {
        killedSessionTokens.insert(sessionToken)
        killedSessionTimestamps[sessionToken] = Date()
    }

    /// Cleans up expired killed session entries.
    private func cleanupExpiredKilledSessions() {
        let now = Date()
        for (token, killedAt) in killedSessionTimestamps {
            if now.timeIntervalSince(killedAt) >= killedSessionTTL {
                killedSessionTokens.remove(token)
                killedSessionTimestamps.removeValue(forKey: token)
            }
        }
    }

    /// Checks if a session token is blocked (killed and in cooldown).
    /// Called during admission to reject reconnection attempts from killed sessions.
    func isSessionBlocked(_ sessionToken: String?) -> Bool {
        isSessionInTerminationCooldown(sessionToken)
    }

    /// Checks if a clientID is in user-initiated kill cooldown.
    /// Returns true if the client was killed by user action within the cooldown period.
    private func isClientInUserKillCooldown(_ clientID: String) -> Bool {
        guard let killedAt = userKilledClientIDs[clientID] else { return false }

        let elapsed = Date().timeIntervalSince(killedAt)
        if elapsed >= userKilledClientCooldown {
            // Expired - clean up
            userKilledClientIDs.removeValue(forKey: clientID)
            return false
        }
        return true
    }

    /// Returns remaining TTL for a killed session, or nil if not blocked.
    private func remainingKilledSessionTTL(_ token: String) -> TimeInterval? {
        guard let killedAt = killedSessionTimestamps[token] else { return nil }
        let elapsed = Date().timeIntervalSince(killedAt)
        let remaining = killedSessionTTL - elapsed
        return remaining > 0 ? remaining : nil
    }

    /// Returns remaining TTL for a user-killed client, or nil if not in cooldown.
    private func remainingUserKillCooldown(_ clientID: String) -> TimeInterval? {
        guard let killedAt = userKilledClientIDs[clientID] else { return nil }
        let elapsed = Date().timeIntervalSince(killedAt)
        let remaining = userKilledClientCooldown - elapsed
        return remaining > 0 ? remaining : nil
    }

    /// Marks a clientID as killed by user action (for brief reconnection cooldown).
    private func markClientAsUserKilled(_ clientID: String) {
        userKilledClientIDs[clientID] = Date()
        connectionLog("Marked clientID '\(clientID)' for \(Int(userKilledClientCooldown))s reconnection cooldown")
    }

    /// Cleans up expired user-killed client entries.
    private func cleanupExpiredUserKilledClients() {
        let now = Date()
        for (clientID, killedAt) in userKilledClientIDs {
            if now.timeIntervalSince(killedAt) >= userKilledClientCooldown {
                userKilledClientIDs.removeValue(forKey: clientID)
            }
        }
    }

    /// Terminates a connection with explicit kill semantics.
    /// - Writes a kill signal file (filesystem side-channel) so CLI exits without retry
    /// - Marks the session for cooldown deny to block immediate reconnection
    /// - Terminates and removes the connection
    /// - Parameters:
    ///   - id: The connection UUID to terminate
    ///   - reason: Why the connection is being terminated
    ///   - message: Optional human-readable message
    func terminateConnection(_ id: UUID, reason: TerminationReason, message: String? = nil) async {
        await terminateConnection(id, reason: reason, message: message, semanticsOverride: nil)
    }

    /// Internal termination with configurable semantics.
    private func terminateConnection(
        _ id: UUID,
        reason: TerminationReason,
        message: String?,
        semanticsOverride: TerminationSemantics?
    ) async {
        guard let connection = connections[id] else {
            log.warning("terminateConnection: connection \(id) not found in connections dictionary")
            return
        }

        let sem = semanticsOverride ?? defaultSemantics(for: reason)
        let sessionToken = capabilityTokenByConnection[id] ?? connection.capabilityToken
        connectionLog("Terminating connection \(id) with reason: \(reason.rawValue), session: \(sessionToken?.prefix(8) ?? "nil")..., semantics: killSignal=\(sem.writeKillSignal), markSession=\(sem.markSessionKilled), markClient=\(sem.markClientUserKilled)")
        #if DEBUG
            debugRecordConnectionEvent("terminated", connectionID: id, reason: reason.rawValue, sessionToken: sessionToken)
        #endif
        let closeContext = MCPConnectionCloseContext(
            reason: reason.rawValue,
            initiator: .app,
            errorDescription: message
        )
        persistAcceptedSocketTerminalRecord(connectionID: id, context: closeContext)

        // 1. Write kill signal file (works for both transport types)
        if sem.writeKillSignal, let token = sessionToken {
            do {
                try MCPKillSignal.writeKillSignal(
                    sessionToken: token,
                    reason: reason,
                    message: message,
                    directory: MCPFilesystemConstants.identity.killSignalsDirectoryURL()
                )
                connectionLog("Wrote kill signal for session \(token.prefix(8))...")
            } catch {
                log.warning("Failed to write kill signal: \(error)")
            }
        }

        // 2. Mark session for cooldown deny (only if semantics require it)
        if sem.markSessionKilled, let token = sessionToken {
            markSessionAsKilled(token)
        }

        // 2b. Mark clientID for brief cooldown (only if semantics require it)
        if sem.markClientUserKilled, let clientID = clientIDByConnection[id] {
            markClientAsUserKilled(clientID)
        }

        // 3. Terminate the connection (writes "killed" to meta.json for filesystem)
        await connection.terminate(reason: reason, message: message)

        // 4. Clean up connection state
        await removeConnection(id, context: closeContext)

        connectionLog("Successfully terminated and removed connection \(id)")

        // Periodic cleanup of expired entries
        cleanupExpiredKilledSessions()
        cleanupExpiredUserKilledClients()
        MCPKillSignal.cleanupStaleSignals(in: MCPFilesystemConstants.identity.killSignalsDirectoryURL())
    }

    /// Soft-disconnects a connection without kill signals or cooldowns.
    /// Used for internal connection churn (e.g., same-session reconnection).
    private func softDisconnectConnection(_ id: UUID, reason: TerminationReason, message: String?) async {
        guard let connection = connections[id] else {
            connectionLog("softDisconnectConnection: connection \(id) not found")
            return
        }
        connectionLog("Soft-disconnecting connection \(id) reason=\(reason.rawValue)")
        #if DEBUG
            debugRecordConnectionEvent("soft_disconnected", connectionID: id, reason: reason.rawValue)
        #endif
        let closeContext = MCPConnectionCloseContext(
            reason: reason.rawValue,
            initiator: .app,
            errorDescription: message
        )
        persistAcceptedSocketTerminalRecord(connectionID: id, context: closeContext)
        await connection.stop()
        await removeConnection(id, context: closeContext)
    }

    private func currentBootstrapReplacementConnectionID(forSessionToken token: String) -> UUID? {
        guard let connectionID = connectionIDBySessionToken[token] else { return nil }
        guard connections[connectionID] != nil else {
            if connectionIDBySessionToken[token] == connectionID {
                invalidateBootstrapReplacementCredits(
                    sessionToken: token,
                    predecessorConnectionID: connectionID
                )
                sessionTokenBindingGeneration[token, default: 0] &+= 1
                connectionIDBySessionToken.removeValue(forKey: token)
            }
            return nil
        }
        guard !connectionsBeingRemoved.contains(connectionID) else { return nil }
        return connectionID
    }

    /// Returns the existing connection ID for a given session token, if any.
    private func existingConnectionID(forSessionToken token: String) -> UUID? {
        if let id = connectionIDBySessionToken[token],
           !connectionsBeingRemoved.contains(id),
           let mgr = connections[id],
           !mgr.isFilesystemBacked
        {
            return id
        }
        // Fallback scan in case mapping got out of sync.
        for (id, mgr) in connections {
            if mgr.isFilesystemBacked || connectionsBeingRemoved.contains(id) { continue }
            let stored = capabilityTokenByConnection[id] ?? mgr.capabilityToken
            if stored == token {
                bindSessionToken(token, to: id)
                return id
            }
        }
        if let staleConnectionID = connectionIDBySessionToken[token] {
            invalidateBootstrapReplacementCredits(
                sessionToken: token,
                predecessorConnectionID: staleConnectionID
            )
            sessionTokenBindingGeneration[token, default: 0] &+= 1
            connectionIDBySessionToken.removeValue(forKey: token)
        }
        return nil
    }

    /// Binds a session token to a connection for fast lookup and routing persistence.
    private func bindSessionToken(_ token: String, to connectionID: UUID) {
        if connectionIDBySessionToken[token] != connectionID {
            invalidateBootstrapReplacementCredits(sessionToken: token)
            sessionTokenBindingGeneration[token, default: 0] &+= 1
        }
        connectionIDBySessionToken[token] = connectionID
        capabilityTokenByConnection[connectionID] = token
    }

    /// Removes session-token mappings for a connection.
    private func unbindSessionToken(_ token: String?, forConnectionID id: UUID) {
        guard let token else {
            capabilityTokenByConnection.removeValue(forKey: id)
            return
        }
        if connectionIDBySessionToken[token] == id {
            invalidateBootstrapReplacementCredits(
                sessionToken: token,
                predecessorConnectionID: id
            )
            sessionTokenBindingGeneration[token, default: 0] &+= 1
            connectionIDBySessionToken.removeValue(forKey: token)
        }
        capabilityTokenByConnection.removeValue(forKey: id)
    }

    /// Returns the session token for a connection (from capability token cache or connection itself).
    func sessionToken(for connectionID: UUID) -> String? {
        capabilityTokenByConnection[connectionID] ?? connections[connectionID]?.capabilityToken
    }

    private func persistAcceptedSocketTerminalRecord(
        connectionID: UUID,
        context: MCPConnectionCloseContext
    ) {
        guard let peerPID = bootstrapPeerPIDByConnectionID[connectionID] else { return }

        let candidate = MCPTerminalRecord(
            layer: .appAcceptedSocket,
            initiator: context.initiator,
            reason: context.reason,
            sessionToken: sessionToken(for: connectionID),
            localPID: Int(getpid()),
            peerPID: peerPID,
            appConnectionID: connectionID,
            connectionGeneration: connectionLifecycleGenerationByID[connectionID],
            errno: context.errno,
            errorDescription: context.errorDescription
        )
        var claim = terminalRecordClaimsByConnectionID[connectionID] ?? MCPFirstTerminalRecordClaim()
        guard let record = claim.claim(candidate) else { return }
        terminalRecordClaimsByConnectionID[connectionID] = claim

        if MCPTerminalRecordStore.writeBestEffort(
            record,
            to: MCPFilesystemConstants.eventsDirectoryURL()
        ) != nil {
            claim.markPersisted()
            terminalRecordClaimsByConnectionID[connectionID] = claim
        }
    }

    /// Handles connection replacement when a new connection registers with the same runID.
    /// Uses soft-disconnect for same-session replacements to avoid blocking legitimate reconnects.
    func handleConnectionReplaced(
        existing oldID: UUID,
        by newID: UUID,
        runID: UUID,
        message: String? = nil
    ) async {
        let oldToken = sessionToken(for: oldID)
        let newToken = sessionToken(for: newID)

        // If both tokens exist and are equal, this is a reconnect churn from the same CLI.
        // Soft-disconnect the old connection without kill signals or session blocking.
        if let oldToken, let newToken, oldToken == newToken {
            connectionLog("RunID \(runID) collision: same session (\(oldToken.prefix(8))…) - soft-disconnect old=\(oldID) for new=\(newID)")
            await softDisconnectConnection(oldID, reason: .connectionReplaced, message: message)
            return
        }

        // Different session or unknown: treat as true replacement (kill old session)
        connectionLog("RunID \(runID) collision: different session - hard-terminate old=\(oldID) (token=\(oldToken?.prefix(8) ?? "nil")) for new=\(newID) (token=\(newToken?.prefix(8) ?? "nil"))")
        let hardSemantics = TerminationSemantics(
            writeKillSignal: true,
            markSessionKilled: true,
            markClientUserKilled: false
        )
        await terminateConnection(oldID, reason: .connectionReplaced, message: message, semanticsOverride: hardSemantics)
    }

    private func schedulePendingPolicyConnectionReplacement(
        _ token: MCPServerViewModel.PendingPolicyRunIDMappingToken,
        windowID: Int
    ) {
        guard let displacedConnectionID = token.displacedConnectionID else { return }
        #if DEBUG
            debugPendingPolicyReplacementSchedules.append((
                existing: displacedConnectionID,
                replacement: token.connectionID,
                runID: token.runID
            ))
        #endif
        Task {
            await ServerNetworkManager.shared.handlePendingPolicyConnectionReplacement(
                token,
                windowID: windowID
            )
        }
    }

    private func handlePendingPolicyConnectionReplacement(
        _ token: MCPServerViewModel.PendingPolicyRunIDMappingToken,
        windowID: Int
    ) async {
        guard let displacedConnectionID = token.displacedConnectionID else { return }
        let replacementStillOwnsRun = await MainActor.run {
            guard let window = WindowStatesManager.shared.window(withID: windowID) else { return false }
            return window.mcpServer.isCurrentPendingPolicyRunIDMapping(token)
                && window.mcpServer.connectionIDToRunID[displacedConnectionID] == nil
        }
        guard replacementStillOwnsRun else {
            connectionLog("Skipping stale pending-policy replacement old=\(displacedConnectionID) new=\(token.connectionID) runID=\(token.runID)")
            return
        }
        await handleConnectionReplaced(
            existing: displacedConnectionID,
            by: token.connectionID,
            runID: token.runID,
            message: "Connection replaced by new connection for same runID"
        )
    }

    func recordTransportIngressTerminal(
        connectionID: UUID,
        clientName: String?,
        sessionToken: String?,
        snapshot: MCPTransportIngressSnapshot,
        closeSnapshot: MCPTransportCloseSnapshot
    ) {
        persistAcceptedSocketTerminalRecord(
            connectionID: connectionID,
            context: MCPConnectionCloseContext(transport: closeSnapshot)
        )
        if snapshot.terminalCause == .receiveBufferOverflow {
            log.error(
                "MCP connection \(connectionID) ingress terminated: cause=\(closeSnapshot.cause.rawValue) capacity=\(snapshot.receiveBufferCapacity) highWaterMark=\(snapshot.receiveBufferHighWaterMark)"
            )
        } else {
            connectionLog(
                "MCP connection \(connectionID) transport terminated: cause=\(closeSnapshot.cause.rawValue)"
            )
        }
        #if DEBUG
            let retained = DebugRetainedTransportIngress(
                snapshot: snapshot,
                clientName: clientName,
                sessionToken: sessionToken
            )
            debugRetainedTransportIngressByConnectionID[connectionID] = retained
            debugRetainedTransportIngressOrder.removeAll { $0 == connectionID }
            debugRetainedTransportIngressOrder.append(connectionID)
            while debugRetainedTransportIngressOrder.count > debugRetainedTransportIngressLimit {
                let expiredID = debugRetainedTransportIngressOrder.removeFirst()
                debugRetainedTransportIngressByConnectionID.removeValue(forKey: expiredID)
                debugRecordedTransportTerminalConnectionIDs.remove(expiredID)
            }
            if debugRecordedTransportTerminalConnectionIDs.insert(connectionID).inserted {
                debugRecordConnectionEvent(
                    "transport_terminal",
                    connectionID: connectionID,
                    reason: closeSnapshot.cause.rawValue,
                    clientName: clientName,
                    sessionToken: sessionToken,
                    transportIngress: snapshot
                )
            }
        #endif
    }

    private func abortConnectionForExecutionWatchdog(
        _ id: UUID,
        toolName: String,
        invocationID: UUID,
        elapsedMilliseconds: Double,
        handlerPhase: MCPToolExecutionHandlerPhaseSnapshot?,
        handlerPhaseAgeMilliseconds: Double?
    ) async {
        guard executionWatchdogTerminalConnections.insert(id).inserted else { return }
        let activeToolExecutionScopeCount = activeToolScopeIDs(ownedBy: id).values.reduce(0) { $0 + $1.count }
        let limiterDiagnostics = await callLimiters[id]?.executionWatchdogDiagnostics()
        let phaseDescription = handlerPhase.map {
            "\($0.phase.rawValue):\($0.transition.rawValue) entered_ms=\(String(format: "%.3f", $0.elapsedMilliseconds)) age_ms=\(String(format: "%.3f", handlerPhaseAgeMilliseconds ?? 0))"
        } ?? "unreported"
        log.error(
            "MCP execution watchdog abort connection_id=\(id) tool=\(toolName) invocation_id=\(invocationID) elapsed_ms=\(String(format: "%.3f", elapsedMilliseconds)) handler_phase=\(phaseDescription) connection_in_flight_request_count=\(limiterDiagnostics?.admittedCallCount ?? 0) active_tool_execution_scope_count=\(activeToolExecutionScopeCount)"
        )
        connectionLog("Execution watchdog marked connection terminal: \(id)")
        #if DEBUG
            debugRecordConnectionEvent(
                "tool_execution_watchdog_abort",
                connectionID: id,
                reason: "tool_execution_watchdog"
            )
        #endif
        let closeContext = MCPConnectionCloseContext(
            reason: "tool_execution_watchdog",
            initiator: .app,
            errorDescription: "Unresponsive tool execution exceeded the watchdog deadline"
        )
        persistAcceptedSocketTerminalRecord(connectionID: id, context: closeContext)

        let connection: (any MCPServerConnection)? = if let registeredConnection = connections[id] {
            registeredConnection
        } else {
            #if DEBUG
                debugExecutionWatchdogAbortTargets[id]
            #else
                nil
            #endif
        }
        guard let connection else { return }
        await connection.abortForExecutionWatchdog()
        Task { [weak self] in
            await self?.removeConnection(id, context: closeContext)
        }
    }

    private struct CommittedConnectionRemoval {
        let connectionID: UUID
        let connectionIdentity: ObjectIdentifier
        let lifecycleGeneration: UInt64
        let connection: any MCPServerConnection
    }

    private func commitConnectionRemoval(
        connectionID: UUID,
        expectedIdentity: ObjectIdentifier,
        expectedLifecycleGeneration: UInt64
    ) -> CommittedConnectionRemoval? {
        guard !connectionsBeingRemoved.contains(connectionID),
              connectionLifecycleGenerationByID[connectionID] == expectedLifecycleGeneration,
              let connection = connections[connectionID],
              ObjectIdentifier(connection as AnyObject) == expectedIdentity
        else { return nil }
        connectionsBeingRemoved.insert(connectionID)
        invalidateBootstrapReplacementCredits(predecessorConnectionID: connectionID)
        return CommittedConnectionRemoval(
            connectionID: connectionID,
            connectionIdentity: expectedIdentity,
            lifecycleGeneration: expectedLifecycleGeneration,
            connection: connection
        )
    }

    @MainActor
    private static func finishReadFileAutoSelectionAndRemoveTabContext(
        connectionID: UUID,
        clientName: String?,
        assignedWindowID: Int?
    ) async {
        let windows = WindowStatesManager.shared.allWindows
        let targets: [WindowState]
        let cleanupWindowID: Int?
        if let assignedWindowID,
           let assignedWindow = windows.first(where: { $0.windowID == assignedWindowID })
        {
            targets = [assignedWindow]
            cleanupWindowID = assignedWindowID
        } else {
            targets = windows
            cleanupWindowID = nil
        }

        for state in targets {
            await state.mcpServer.finishReadFileAutoSelectionForConnectionTeardown(
                connectionID: connectionID
            )
        }
        for state in targets {
            state.mcpServer.removeTabContext(
                forConnectionID: connectionID,
                clientName: clientName,
                windowID: cleanupWindowID,
                runID: nil
            )
        }
    }

    func removeConnection(
        _ id: UUID,
        context: MCPConnectionCloseContext = .cleanupUnspecified
    ) async {
        _ = await removeConnection(
            id,
            committedRemoval: nil,
            connectionAlreadyStopped: false,
            context: context
        )
    }

    @discardableResult
    private func removeConnection(
        _ id: UUID,
        committedRemoval: CommittedConnectionRemoval?,
        connectionAlreadyStopped: Bool,
        context: MCPConnectionCloseContext
    ) async -> Bool {
        if let committedRemoval {
            guard committedRemoval.connectionID == id,
                  connectionsBeingRemoved.contains(id),
                  connectionLifecycleGenerationByID[id] == committedRemoval.lifecycleGeneration,
                  let connection = connections[id],
                  ObjectIdentifier(connection as AnyObject) == committedRemoval.connectionIdentity
            else {
                return false
            }
        } else {
            guard !connectionsBeingRemoved.contains(id) else {
                connectionLog("removeConnection: \(id) cleanup already in progress; ignoring duplicate call")
                return false
            }
        }

        // Idempotent guard – if already gone, do nothing (and do not log)
        guard connections[id] != nil
            || connectionTasks[id] != nil
            || pendingConnections[id] != nil
            || callLimiters[id] != nil
        else {
            connectionLog("removeConnection: \(id) already removed; ignoring duplicate call")
            connectionsBeingRemoved.remove(id)
            return false
        }

        if committedRemoval == nil {
            connectionsBeingRemoved.insert(id)
            invalidateBootstrapReplacementCredits(predecessorConnectionID: id)
        }
        defer { connectionsBeingRemoved.remove(id) }

        // Claim and persist the first terminal cause before any suspension.
        // Later termination/watchdog cleanup must not overwrite the event that
        // actually initiated removal.
        persistAcceptedSocketTerminalRecord(connectionID: id, context: context)

        // Always drop any lingering bootstrap reservation (commit/rollback should handle it,
        // but this is a leak safety-net for edge cases)
        if let reservation = bootstrapReservations.removeValue(forKey: id) {
            releaseBootstrapAdmissionClaim(
                sessionToken: reservation.sessionToken,
                connectionID: id,
                lifecycleGeneration: reservation.lifecycleGeneration
            )
            closeTransferredBootstrapSocket(
                connectionID: id,
                lifecycleGeneration: reservation.lifecycleGeneration
            )
            await reservation.committingConnection?.stop()
        }

        connectionLog("Removing connection: \(id)")

        let limiters = callLimiters.removeValue(forKey: id)
        await limiters?.cancelAll()

        let assignedWindowID = connectionWindowMap[id]
        let cleanupClientID = clientIDByConnection[id]
        let cleanupClientName = pendingConnections[id] ?? cleanupClientID
        let sessionToken = capabilityTokenByConnection[id] ?? connections[id]?.capabilityToken
        #if DEBUG
            debugRecordConnectionEvent(
                "removed",
                connectionID: id,
                reason: context.reason,
                clientName: cleanupClientName,
                sessionToken: sessionToken,
                windowID: assignedWindowID
            )
        #endif

        restrictedToolsByConnection.removeValue(forKey: id)
        additionalToolsByConnection.removeValue(forKey: id)
        runPurposeByConnection.removeValue(forKey: id)
        runIDByConnectionID.removeValue(forKey: id)
        pendingPolicyApplicationIDByConnectionID.removeValue(forKey: id)
        windowAssignmentByConnection.removeValue(forKey: id)
        preassignedConnections.remove(id)
        windowCountAtConnectionTime.removeValue(forKey: id)
        identityContextByConnection.removeValue(forKey: id)

        let cancelledToolCount = await cancelActiveToolsOwnedByConnection(
            id,
            reason: context.reason
        )
        if cancelledToolCount > 0 {
            connectionLog("Cancelled \(cancelledToolCount) active tool execution(s) owned by disconnected connection \(id)")
        }

        await Self.finishReadFileAutoSelectionAndRemoveTabContext(
            connectionID: id,
            clientName: cleanupClientName,
            assignedWindowID: assignedWindowID
        )
        connectionWindowMap[id] = nil

        // Stop the connection manager unless the exact committed owner was already stopped
        // before entering cleanup (bootstrap predecessor handoff).
        if !connectionAlreadyStopped, let connectionManager = connections[id] {
            await connectionManager.stop()
        }

        // Cancel any associated tasks
        if let task = connectionTasks[id] {
            task.cancel()
        }

        // Remove from all collections
        connections.removeValue(forKey: id)
        connectionLifecycleGenerationByID.removeValue(forKey: id)
        bootstrapPeerPIDByConnectionID.removeValue(forKey: id)
        connectionTasks.removeValue(forKey: id)
        pendingConnections.removeValue(forKey: id)
        connectionStats.removeValue(forKey: id)
        // Note: run-scoped tool event observers are cleaned up when the discovery run completes,
        // not when an individual connection is removed.
        // Note: connectionIDToRunID mapping is managed by MCPServerViewModel, not here

        // Release admission slot & limiter
        if let clientID = clientIDByConnection[id] {
            var set = activeConnectionsByClient[clientID] ?? []
            set.remove(id)
            if set.isEmpty { activeConnectionsByClient.removeValue(forKey: clientID) }
            else { activeConnectionsByClient[clientID] = set }
            clientIDByConnection.removeValue(forKey: id)
        }
        // Clean up routing metadata before any bounded drain wait so the disconnected
        // connection cannot remain discoverable while an active owner ignores cancellation.
        unbindSessionToken(sessionToken, forConnectionID: id)
        terminalRecordClaimsByConnectionID.removeValue(forKey: id)

        if let limiters {
            let results = await limiters.waitUntilIdle(
                timeout: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace
            )
            for (lane, drained) in results where !drained {
                connectionLog(
                    "Connection limiter cleanup grace expired; detached active owner may settle later: \(id) lane=\(lane.rawValue)"
                )
            }
        }

        // Removal is terminal for this connection ID. Sweep any scope that raced the initial
        // cancellation snapshot; exact deferred completions remain harmless no-ops.
        _ = removeActiveToolScopes(activeToolScopeIDs(ownedBy: id))

        // Notify dashboard of connection removal
        emitDashboardUpdate()
        return true
    }

    /// Reads the cached TCP client name from all CLI instance cache files.
    /// (Legacy TCP transport has been removed; this helper now returns nil.)
    /// - Parameter remotePort: The remote port from the incoming connection for precise matching
    /// - Returns: Always nil now that TCP transport and cache files are deprecated
    // MARK: - Identity Failure Recording & Escalation

    /// Transport type for identity failure tracking
    private enum IdentityFailureSource {
        /// Identity failures observed on filesystem/bootstrap-socket connections
        case filesystem
    }

    /// Records an identity recovery failure and potentially escalates diagnostics.
    /// With TCP transport removed, this is only used for filesystem/bootstrap-socket failures.
    /// - Parameters:
    ///   - connectionID: The connection that failed identity recovery
    ///   - source: Where the failure was observed (currently always `.filesystem`)
    ///   - reason: Human-readable description of the failure
    private func recordIdentityFailure(for connectionID: UUID, source: IdentityFailureSource, reason: String) async {
        log.error("Identity recovery failed for connection \(connectionID): \(reason)")

        let now = Date()
        if let start = identityFailureWindowStart,
           now.timeIntervalSince(start) <= identityFailureWindow
        {
            identityFailureCount += 1
        } else {
            identityFailureWindowStart = now
            identityFailureCount = 1
        }

        // Escalate after threshold
        if identityFailureCount >= identityFailureThreshold {
            await escalateIdentityFailures(reason: reason)
        }
    }

    /// Escalates repeated identity failures - placeholder for future handling.
    private func escalateIdentityFailures(reason: String) async {
        // Log the escalation for diagnostics
        log.error("Identity failure escalation (count=\(identityFailureCount)): \(reason)")
    }

    /// Maximum entries in toolSchemaCache to prevent unbounded growth
    private let maxToolSchemaCacheEntries = 256

    private var bindingResolver: MCPBindingResolver {
        MCPBindingResolver(
            collectMatchesForContextID: { contextID in
                await MainActor.run {
                    WindowStatesManager.shared.allWindows.compactMap { windowState in
                        guard let candidate = windowState.workspaceManager.bindingCandidate(forContextID: contextID) else {
                            return nil
                        }
                        return MCPContextBindingMatch(
                            windowID: windowState.windowID,
                            tabID: candidate.tabID,
                            workspaceID: candidate.workspaceID,
                            workspaceName: candidate.workspaceName,
                            repoPaths: candidate.repoPaths
                        )
                    }
                }
            },
            collectMatchesForWorkingDirs: { workingDirs in
                await MainActor.run {
                    WindowStatesManager.shared.allWindows.flatMap { windowState in
                        windowState.workspaceManager.bindingCandidates(matchingWorkingDirs: workingDirs, includeHidden: false).map { candidate in
                            MCPContextBindingMatch(
                                windowID: windowState.windowID,
                                tabID: candidate.tabID,
                                workspaceID: candidate.workspaceID,
                                workspaceName: candidate.workspaceName,
                                repoPaths: candidate.repoPaths
                            )
                        }
                    }
                }
            },
            existingWindowIDForConnection: { [self] connectionID in
                connectionWindowMap[connectionID]
            },
            clientIdentifier: { [self] connectionID in
                clientIdentifier(forConnection: connectionID)
            },
            reusableWindowForClient: { [self] connectionID, clientName in
                await reusableWindowForClient(newConnectionID: connectionID, clientName: clientName)
            },
            sessionKeyForConnection: { [self] connectionID in
                connections[connectionID]?.capabilityToken ?? capabilityTokenByConnection[connectionID]
            },
            preferredLiveRunWindowID: { [self] clientName, sessionKey in
                preferredLiveRunAffinity(for: clientName, sessionKey: sessionKey)?.windowID
            },
            preferredWindowID: { [self] clientName, sessionKey in
                await preferredWindowID(for: clientName, sessionKey: sessionKey)
            }
        )
    }

    private func cachedSchema(for name: String, schema: JSONSchema, purpose: MCPRunPurpose) async throws -> Value {
        let cacheKey = ToolSchemaCacheKey(name: name, purpose: purpose)
        if let cached = toolSchemaCache[cacheKey] {
            return cached
        }

        var schemaValue = try Value(schema)

        if case var .object(dict) = schemaValue,
           dict["type"]?.stringValue == "object",
           dict["properties"] == nil
        {
            dict["properties"] = Value.object([:])
            schemaValue = .object(dict)
        }

        schemaValue = Self.augmentSchemaWithCanonicalBindingParams(schemaValue, toolName: name, purpose: purpose)

        // Prevent unbounded cache growth (safety net for buggy/malicious clients)
        if toolSchemaCache.count >= maxToolSchemaCacheEntries {
            connectionLog("toolSchemaCache flushed (exceeded cap=\(maxToolSchemaCacheEntries))")
            toolSchemaCache.removeAll(keepingCapacity: true)
        }

        toolSchemaCache[cacheKey] = schemaValue
        return schemaValue
    }

    private func invalidateToolSchemaCache() {
        toolSchemaCache.removeAll(keepingCapacity: false)
    }

    nonisolated static func augmentSchemaWithCanonicalBindingParams(
        _ schemaValue: Value,
        toolName: String,
        purpose: MCPRunPurpose
    ) -> Value {
        guard case var .object(dict) = schemaValue,
              dict["type"]?.stringValue == "object"
        else {
            return schemaValue
        }

        var properties = dict["properties"]?.objectValue ?? [:]

        let shouldAdvertiseCanonicalBindingParams = shouldAdvertiseCanonicalBindingParams(for: toolName)
        let shouldKeepContextID = shouldRehydrateContextID(for: toolName)
        if !shouldAdvertiseCanonicalBindingParams {
            if !shouldKeepContextID {
                properties.removeValue(forKey: "context_id")
            }
            properties.removeValue(forKey: "working_dirs")
        }

        dict["properties"] = .object(properties)

        if var required = dict["required"]?.arrayValue {
            if !shouldAdvertiseCanonicalBindingParams {
                required.removeAll { value in
                    guard let stringValue = value.stringValue else { return false }
                    if stringValue == "context_id" { return !shouldKeepContextID }
                    return stringValue == "working_dirs"
                }
            }
            dict["required"] = .array(required)
        }

        return .object(dict)
    }

    private nonisolated func advertisedToolDescription(
        for name: String,
        baseDescription: String,
        purpose: MCPRunPurpose
    ) -> String {
        baseDescription
    }

    /// Checks if a tool's schema declares a `window_id` parameter.
    /// Pure function - doesn't access actor state.
    private nonisolated func schemaDeclaresWindowID(schema: JSONSchema) -> Bool {
        // Convert schema to Value and check for window_id in properties
        guard let schemaValue = try? Value(schema),
              case let .object(dict) = schemaValue,
              let props = dict["properties"]?.objectValue
        else {
            return false
        }
        return props.keys.contains("window_id")
    }

    /// Injects `window_id` into tool arguments if:
    /// 1. The tool schema declares a `window_id` parameter
    /// 2. The caller provided `_windowID` for routing
    /// 3. The caller didn't explicitly provide `window_id`
    /// Pure function - doesn't access actor state.
    private nonisolated func injectWindowIDIfNeeded(
        schemaDeclaresWindowID: Bool,
        routingWindowID: Int?,
        args: [String: Value]
    ) -> [String: Value] {
        // Priority 1: explicit window_id in args -> keep unchanged
        if args["window_id"] != nil { return args }

        // Priority 2: _windowID routing + schema has window_id -> inject
        guard let windowID = routingWindowID,
              schemaDeclaresWindowID
        else {
            return args
        }

        var mutableArgs = args
        mutableArgs["window_id"] = .int(windowID)
        return mutableArgs
    }

    func registerExpectedAgentPID(_ pid: pid_t, for clientName: String, runID: UUID? = nil) {
        let storageKey = Self.clientStorageKey(clientName)
        var pids = expectedAgentPIDsByClient[storageKey] ?? []
        pids.insert(pid)
        expectedAgentPIDsByClient[storageKey] = pids
        if let runID {
            var runPIDs = expectedAgentPIDsByRunID[runID] ?? []
            runPIDs.insert(pid)
            expectedAgentPIDsByRunID[runID] = runPIDs
        }
        mcpPolicyLog(
            "registered expected agent pid client=\(clientName) storageKey=\(storageKey) pid=\(pid) runID=\(runID?.uuidString ?? "nil") count=\(pids.count)"
        )
        #if DEBUG
            if let runID {
                debugRecordRunRoutingEvent(
                    runID: runID,
                    event: "expected_pid_registered",
                    fields: [
                        "client_name": clientName,
                        "expected_pid": String(pid),
                        "expected_pid_count": String((expectedAgentPIDsByRunID[runID] ?? []).count)
                    ]
                )
            }
        #endif
    }

    func clearExpectedAgentPID(_ pid: pid_t, for clientName: String, runID: UUID? = nil) {
        let keys = matchingClientKeys(for: clientName, in: Array(expectedAgentPIDsByClient.keys))
        guard !keys.isEmpty || runID != nil else { return }
        var removedCount = 0
        for key in keys {
            guard var pids = expectedAgentPIDsByClient[key] else { continue }
            if pids.remove(pid) != nil {
                removedCount += 1
            }
            if pids.isEmpty {
                expectedAgentPIDsByClient.removeValue(forKey: key)
            } else {
                expectedAgentPIDsByClient[key] = pids
            }
        }
        if let runID {
            removeExpectedAgentPID(pid, forRunID: runID)
        } else {
            for candidateRunID in Array(expectedAgentPIDsByRunID.keys) {
                removeExpectedAgentPID(pid, forRunID: candidateRunID)
            }
        }
        guard removedCount > 0 else { return }
        mcpPolicyLog(
            "cleared expected agent pid client=\(clientName) pid=\(pid) runID=\(runID?.uuidString ?? "nil") removed=\(removedCount)"
        )
        #if DEBUG
            if let runID {
                debugRecordRunRoutingEvent(
                    runID: runID,
                    event: "expected_pid_cleared",
                    fields: [
                        "client_name": clientName,
                        "expected_pid": String(pid),
                        "removed_count": String(removedCount)
                    ]
                )
            }
        #endif
    }

    private func removeExpectedAgentPID(_ pid: pid_t, forRunID runID: UUID) {
        guard var pids = expectedAgentPIDsByRunID[runID] else { return }
        pids.remove(pid)
        if pids.isEmpty {
            expectedAgentPIDsByRunID.removeValue(forKey: runID)
        } else {
            expectedAgentPIDsByRunID[runID] = pids
        }
    }

    private func expectedAgentPIDs(for clientName: String, runID: UUID? = nil) -> Set<pid_t> {
        if let runID {
            return expectedAgentPIDsByRunID[runID] ?? []
        }
        let keys = matchingClientKeys(for: clientName, in: Array(expectedAgentPIDsByClient.keys))
        return keys.reduce(into: Set<pid_t>()) { partialResult, key in
            partialResult.formUnion(expectedAgentPIDsByClient[key] ?? [])
        }
    }

    private func hasPIDGatedPendingPolicy(for clientName: String) -> Bool {
        oldestPendingPolicyEntry(for: clientName) { $0.requiresExpectedAgentPID } != nil
    }

    private func oldestPIDGatedPendingPolicyEntry(
        for clientName: String,
        matching clientPid: Int
    ) -> (key: String, index: Int, policy: ClientConnectionPolicy)? {
        oldestPendingPolicyEntry(for: clientName) { policy in
            policy.reservationConnectionID == nil
                && policy.requiresExpectedAgentPID
                && canConsumePendingPolicy(policy, clientName: clientName, clientPid: clientPid)
        }
    }

    private func directAgentBootstrapAdmissionStatus(
        clientName: String,
        sessionKey: String?,
        clientPid: Int,
        isReplacementForSession: Bool
    ) -> AgentPolicyAdmissionReadiness? {
        if oldestPIDGatedPendingPolicyEntry(for: clientName, matching: clientPid) != nil {
            return .ready
        }

        let descendantStatus = isExpectedAgentDescendant(clientName: clientName, clientPid: clientPid)
        if isReplacementForSession,
           preferredLiveRunAffinity(for: clientName, sessionKey: sessionKey) != nil,
           descendantStatus != false
        {
            return .ready
        }

        let hasReservedPIDGatedPolicy = hasPIDGatedPendingPolicy(for: clientName)
        switch descendantStatus {
        case true:
            return hasReservedPIDGatedPolicy ? nil : .ready
        case false:
            return hasReservedPIDGatedPolicy ? nil : .notRequired
        case nil:
            return nil
        }
    }

    private func awaitAgentBootstrapPolicyBeforeAcceptIfNeeded(
        bootstrapClientName: String?,
        connectionID: UUID,
        sessionKey: String?,
        clientPid: Int,
        isReplacementForSession: Bool,
        timeout: TimeInterval = 2.0
    ) async -> AgentPolicyAdmissionReadiness {
        guard let bootstrapClientName,
              Self.isKnownAgentClientName(bootstrapClientName)
        else {
            return .notRequired
        }
        // Do not spend the ownership wait twice. A PID-gated policy is checked and
        // consumed atomically after the authoritative MCP initialize identity arrives.
        if hasPIDGatedPendingPolicy(for: bootstrapClientName) {
            return .ready
        }
        if let readiness = directAgentBootstrapAdmissionStatus(
            clientName: bootstrapClientName,
            sessionKey: sessionKey,
            clientPid: clientPid,
            isReplacementForSession: isReplacementForSession
        ) {
            return readiness
        }
        guard hasPIDGatedPendingPolicy(for: bootstrapClientName)
            || preferredLiveRunAffinity(for: bootstrapClientName, sessionKey: sessionKey) != nil
        else {
            return .notRequired
        }

        let expectedDescription = expectedAgentPIDs(for: bootstrapClientName).map(String.init).sorted().joined(separator: ",")
        let ancestorDescription = pidAncestorChainDescription(from: pid_t(clientPid))
        mcpPolicyLog(
            "holding direct agent bootstrap client=\(bootstrapClientName) connection=\(connectionID) clientPid=\(clientPid) ancestorChain=[\(ancestorDescription)] expectedAgentPIDs=[\(expectedDescription)] timeout=\(timeout)s"
        )

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled {
                return .timedOut
            }
            try? await Task.sleep(for: .milliseconds(50))
            if let readiness = directAgentBootstrapAdmissionStatus(
                clientName: bootstrapClientName,
                sessionKey: sessionKey,
                clientPid: clientPid,
                isReplacementForSession: isReplacementForSession
            ) {
                return readiness
            }
        }

        log.warning(
            "Rejecting direct agent bootstrap \(connectionID) for known client '\(bootstrapClientName)' - expected policy or live run affinity did not become consumable within \(timeout)s"
        )
        mcpPolicyLog(
            "rejected direct agent bootstrap client=\(bootstrapClientName) connection=\(connectionID) reason=policy_admission_timeout clientPid=\(clientPid) ancestorChain=[\(ancestorDescription)] timeout=\(timeout)s"
        )
        return .timedOut
    }

    private func awaitAgentPolicyAdmissionIfNeeded(
        clientName: String,
        bootstrapClientName: String?,
        connectionID: UUID,
        sessionKey: String?,
        clientPid: Int,
        timeout: TimeInterval = 2.0
    ) async -> AgentPolicyAdmissionReadiness {
        guard Self.isKnownAgentClientName(clientName) else {
            return .notRequired
        }

        // PID-gated ownership is resolved atomically at policy consumption. This covers
        // helper bootstrap identities (for example repoprompt_ce_cli_debug) that transition
        // to an authoritative provider identity before the ACP parent PID is registered.
        if hasPIDGatedPendingPolicy(for: clientName) {
            return .ready
        }

        if hasAgentPolicyAdmissionTarget(clientName: clientName, sessionKey: sessionKey, clientPid: clientPid) {
            return .ready
        }

        switch isExpectedAgentDescendant(clientName: clientName, clientPid: clientPid) {
        case true:
            break
        case false, nil:
            return .notRequired
        }
        return await waitForAgentPolicyAdmission(
            clientName: clientName,
            connectionID: connectionID,
            sessionKey: sessionKey,
            clientPid: clientPid,
            timeout: timeout,
            holdReason: "mcp_initialize"
        )
    }

    private func waitForAgentPolicyAdmission(
        clientName: String,
        connectionID: UUID,
        sessionKey: String?,
        clientPid: Int,
        timeout: TimeInterval,
        holdReason: String
    ) async -> AgentPolicyAdmissionReadiness {
        let expectedPIDs = expectedAgentPIDs(for: clientName)
        let expectedDescription = expectedPIDs.map(String.init).sorted().joined(separator: ",")
        let ancestorDescription = pidAncestorChainDescription(from: pid_t(clientPid))
        mcpPolicyLog(
            "holding bootstrap for agent policy client=\(clientName) connection=\(connectionID) reason=\(holdReason) clientPid=\(clientPid) ancestorChain=[\(ancestorDescription)] expectedAgentPIDs=[\(expectedDescription)] timeout=\(timeout)s"
        )

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled {
                return .timedOut
            }
            try? await Task.sleep(for: .milliseconds(50))
            if hasAgentPolicyAdmissionTarget(clientName: clientName, sessionKey: sessionKey, clientPid: clientPid) {
                mcpPolicyLog(
                    "agent policy admission ready client=\(clientName) connection=\(connectionID) reason=\(holdReason)"
                )
                return .ready
            }
        }

        log.warning(
            "Rejecting bootstrap connection \(connectionID) for known agent client '\(clientName)' - no pending policy or live run affinity appeared within \(timeout)s (\(holdReason))"
        )
        mcpPolicyLog(
            "rejected bootstrap client=\(clientName) connection=\(connectionID) reason=policy_admission_timeout holdReason=\(holdReason) clientPid=\(clientPid) ancestorChain=[\(ancestorDescription)] expectedAgentPIDs=[\(expectedDescription)]"
        )
        return .timedOut
    }

    /// Returns nil when no expected PID is registered yet; otherwise checks whether
    /// the trusted peer pid belongs to one of the currently expected agent processes.
    private func isExpectedAgentDescendant(clientName: String, clientPid: Int, runID: UUID? = nil) -> Bool? {
        let expectedAgentPIDs = expectedAgentPIDs(for: clientName, runID: runID)
        guard !expectedAgentPIDs.isEmpty else { return nil }
        return isAncestor(expectedPIDs: expectedAgentPIDs, ofPid: pid_t(clientPid))
    }

    /// Walks the process ancestor chain from `pid` upward, checking if any ancestor
    /// matches one of the expected PIDs. Stops at PID 1 (launchd) or after a
    /// reasonable depth limit to avoid infinite loops on broken process tables.
    private nonisolated func isAncestor(expectedPIDs: Set<pid_t>, ofPid startPid: pid_t) -> Bool {
        var current = startPid
        for _ in 0 ..< 16 {
            if expectedPIDs.contains(current) {
                return true
            }
            guard let parent = parentPID(of: current), parent > 1, parent != current else {
                return false
            }
            current = parent
        }
        return false
    }

    private nonisolated func pidAncestorChainDescription(from startPid: pid_t) -> String {
        var chain = [String(startPid)]
        var current = startPid
        for _ in 0 ..< 16 {
            guard let parent = parentPID(of: current), parent > 1, parent != current else {
                break
            }
            chain.append(String(parent))
            current = parent
        }
        return chain.joined(separator: "<-")
    }

    private nonisolated func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout.stride(ofValue: info)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        return info.kp_eproc.e_ppid
    }

    func installClientConnectionPolicy(
        for clientName: String,
        windowID: Int,
        restrictedTools: Set<String>,
        oneShot: Bool = true,
        reason: String? = nil,
        ttl: TimeInterval = 15,
        tabID: UUID? = nil,
        runID: UUID? = nil,
        additionalTools: Set<String>? = nil,
        purpose: MCPRunPurpose = .unknown,
        taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil,
        allowsAgentExternalControlTools: Bool = false,
        requiresExpectedAgentPID: Bool = false
    ) async {
        let storageKey = Self.clientStorageKey(clientName)
        pruneExpiredPolicies(for: clientName)
        let sanitizedRestricted = Self.sanitizedRoutingRestrictedTools(restrictedTools)
        let policy = ClientConnectionPolicy(
            id: UUID(),
            windowID: windowID,
            restrictedTools: sanitizedRestricted,
            oneShot: oneShot,
            reason: reason,
            createdAt: Date(),
            ttl: ttl,
            tabID: tabID,
            runID: runID,
            additionalTools: additionalTools,
            purpose: purpose,
            taskLabelKind: taskLabelKind,
            allowsAgentExternalControlTools: allowsAgentExternalControlTools,
            requiresExpectedAgentPID: requiresExpectedAgentPID,
            reservationConnectionID: nil
        )
        let grantDescription = Self.describeGrantedTools(restricted: sanitizedRestricted)
        let restrictedDescription = Self.describeToolList(sanitizedRestricted)
        connectionLog(
            "Installing connection policy for client \(clientName) window=\(windowID) grants=\(grantDescription) restricted=\(restrictedDescription) oneShot=\(oneShot) ttl=\(ttl) reason=\(reason ?? "-") role=\(taskLabelKind?.rawValue ?? "-")"
        )
        if let runID {
            seedRunPolicyState(
                runID: runID,
                windowID: windowID,
                workspaceID: nil,
                tabID: tabID,
                restrictedTools: sanitizedRestricted,
                additionalTools: additionalTools,
                purpose: purpose,
                taskLabelKind: taskLabelKind,
                allowsAgentExternalControlTools: allowsAgentExternalControlTools,
                updatedAt: policy.createdAt
            )
        }
        var queue = pendingPoliciesByClient[storageKey] ?? []
        // Agent-mode runs can enqueue policies frequently (e.g. warmup/send/reconnect loops).
        // Keep only the newest pending one-shot agent-mode policy for the same tab/run.
        // Do NOT collapse policies across different tabs in the same window; staggered tab starts
        // must retain independent pending policies until each connection is admitted.
        if oneShot, purpose == .agentModeRun {
            let beforeCount = queue.count
            queue.removeAll {
                guard
                    $0.reservationConnectionID == nil,
                    $0.oneShot,
                    $0.purpose == .agentModeRun,
                    $0.windowID == windowID
                else {
                    return false
                }

                if let newRunID = policy.runID,
                   let existingRunID = $0.runID,
                   existingRunID == newRunID
                {
                    return true
                }
                if let newTabID = policy.tabID,
                   let existingTabID = $0.tabID,
                   existingTabID == newTabID
                {
                    return true
                }

                // Legacy fallback when tab/run context is unavailable: only collapse other
                // legacy policies lacking tab/run context.
                if policy.runID == nil,
                   policy.tabID == nil,
                   $0.runID == nil,
                   $0.tabID == nil
                {
                    return true
                }

                return false
            }
            let removedCount = beforeCount - queue.count
            if removedCount > 0 {
                connectionLog(
                    "Collapsed \(removedCount) stale pending agent-mode policy entries for client \(clientName) storageKey=\(storageKey) window=\(windowID) tabID=\(policy.tabID?.uuidString ?? "nil") runID=\(policy.runID?.uuidString ?? "nil")"
                )
                mcpPolicyLog(
                    "collapsed stale pending policies client=\(clientName) storageKey=\(storageKey) window=\(windowID) tabID=\(policy.tabID?.uuidString ?? "nil") runID=\(policy.runID?.uuidString ?? "nil") removed=\(removedCount)"
                )
            }
        }
        queue.append(policy)
        pendingPoliciesByClient[storageKey] = queue
        mcpPolicyLog(
            "installed policy client=\(clientName) storageKey=\(storageKey) window=\(windowID) purpose=\(purpose.rawValue) oneShot=\(oneShot) ttl=\(ttl)s runID=\(runID?.uuidString ?? "nil") tabID=\(tabID?.uuidString ?? "nil") requiresExpectedPID=\(requiresExpectedAgentPID) queueCount=\(queue.count)"
        )
        #if DEBUG
            if let runID {
                debugRecordRunRoutingEvent(
                    runID: runID,
                    event: "policy_installed",
                    fields: [
                        "client_name": clientName,
                        "pending_policy_key": storageKey,
                        "window_id": String(windowID),
                        "tab_id": tabID?.uuidString ?? "nil",
                        "purpose": purpose.rawValue,
                        "one_shot": String(oneShot),
                        "requires_expected_pid": String(requiresExpectedAgentPID),
                        "queue_count": String(queue.count)
                    ]
                )
            }
        #endif
    }

    func requireExpectedAgentPIDForPendingPolicy(
        for clientName: String,
        runID: UUID,
        windowID: Int? = nil
    ) {
        pruneExpiredPolicies(for: clientName)
        let keys = matchingClientKeys(for: clientName, in: Array(pendingPoliciesByClient.keys))
        var updatedCount = 0
        for key in keys {
            guard var queue = pendingPoliciesByClient[key] else { continue }
            for index in queue.indices {
                guard queue[index].runID == runID else { continue }
                if let windowID, queue[index].windowID != windowID { continue }
                if !queue[index].requiresExpectedAgentPID {
                    queue[index].requiresExpectedAgentPID = true
                    updatedCount += 1
                }
            }
            pendingPoliciesByClient[key] = queue
        }
        mcpPolicyLog(
            "marked policy requires expected pid client=\(clientName) runID=\(runID.uuidString) window=\(windowID.map(String.init) ?? "any") updated=\(updatedCount)"
        )
    }

    #if DEBUG
        func debugSuspendNextPendingPolicyRouteInstallation() {
            debugShouldSuspendNextPendingPolicyRouteInstallation = true
        }

        func debugIsPendingPolicyRouteInstallationSuspended() -> Bool {
            debugPendingPolicyRouteInstallationIsSuspended
        }

        func debugResumePendingPolicyRouteInstallation() {
            debugShouldSuspendNextPendingPolicyRouteInstallation = false
            debugPendingPolicyRouteInstallationIsSuspended = false
            let waiters = debugPendingPolicyRouteInstallationResumeWaiters
            debugPendingPolicyRouteInstallationResumeWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func debugInvalidatePendingPolicyApplication(connectionID: UUID) {
            pendingConnections.removeValue(forKey: connectionID)
        }

        func debugSupersedePendingPolicyApplicationOwnership(connectionID: UUID, runID: UUID) {
            let applicationID = UUID()
            pendingPolicyApplicationIDByConnectionID[connectionID] = applicationID
            pendingPolicyApplicationIDByRunID[runID] = applicationID
        }

        func debugSuspendNextPendingPolicyCommit() {
            debugShouldSuspendNextPendingPolicyCommit = true
        }

        func debugIsPendingPolicyCommitSuspended() -> Bool {
            debugPendingPolicyCommitIsSuspended
        }

        func debugResumePendingPolicyCommit() {
            debugShouldSuspendNextPendingPolicyCommit = false
            debugPendingPolicyCommitIsSuspended = false
            let waiters = debugPendingPolicyCommitResumeWaiters
            debugPendingPolicyCommitResumeWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        private func debugSuspendPendingPolicyRouteInstallationIfNeeded() async {
            guard debugShouldSuspendNextPendingPolicyRouteInstallation else { return }
            debugShouldSuspendNextPendingPolicyRouteInstallation = false
            debugPendingPolicyRouteInstallationIsSuspended = true
            await withCheckedContinuation { continuation in
                debugPendingPolicyRouteInstallationResumeWaiters.append(continuation)
            }
            debugPendingPolicyRouteInstallationIsSuspended = false
        }

        private func debugSuspendPendingPolicyCommitIfNeeded() async {
            guard debugShouldSuspendNextPendingPolicyCommit else { return }
            debugShouldSuspendNextPendingPolicyCommit = false
            debugPendingPolicyCommitIsSuspended = true
            await withCheckedContinuation { continuation in
                debugPendingPolicyCommitResumeWaiters.append(continuation)
            }
            debugPendingPolicyCommitIsSuspended = false
        }

        func debugPendingPolicyReplacementScheduleCount(
            existing: UUID,
            replacement: UUID,
            runID: UUID
        ) -> Int {
            debugPendingPolicyReplacementSchedules.count {
                $0.existing == existing && $0.replacement == replacement && $0.runID == runID
            }
        }

        func debugClearPendingPolicyReplacementSchedules() {
            debugPendingPolicyReplacementSchedules.removeAll()
        }

        func debugPendingPolicySnapshot(for clientName: String) -> [(windowID: Int, tabID: UUID?, runID: UUID?, oneShot: Bool, purpose: MCPRunPurpose)] {
            pruneExpiredPolicies(for: clientName)
            let keys = matchingClientKeys(for: clientName, in: Array(pendingPoliciesByClient.keys))
            let queue = keys.flatMap { pendingPoliciesByClient[$0] ?? [] }.sorted { $0.createdAt < $1.createdAt }
            return queue.map {
                (
                    windowID: $0.windowID,
                    tabID: $0.tabID,
                    runID: $0.runID,
                    oneShot: $0.oneShot,
                    purpose: $0.purpose
                )
            }
        }

        func debugApplyPendingPolicy(
            clientName: String,
            connectionID: UUID,
            clientPid: Int? = nil,
            bootstrapClientName: String? = nil,
            sessionKey: String? = nil,
            pidGateTimeout: TimeInterval = 0.25,
            requireRunRouting: Bool = true,
            expectedLifecycleGeneration: UInt64? = nil
        ) async -> (restrictedTools: Set<String>, additionalTools: Set<String>, purpose: MCPRunPurpose, windowID: Int?, outcome: String, runID: UUID?) {
            pendingConnections[connectionID] = clientName
            if let sessionKey {
                capabilityTokenByConnection[connectionID] = sessionKey
            }
            let outcome = await applyPendingPolicyIfAvailable(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: clientPid,
                bootstrapClientName: bootstrapClientName,
                pidGateTimeout: pidGateTimeout,
                requireRunRouting: requireRunRouting,
                expectedLifecycleGeneration: expectedLifecycleGeneration
            )
            let state = debugConnectionPolicyState(for: connectionID)
            let outcomeDescription: String
            let outcomeRunID: UUID?
            switch outcome {
            case let .applied(runID):
                outcomeDescription = "applied"
                outcomeRunID = runID
            case .fallback:
                outcomeDescription = "fallback"
                outcomeRunID = nil
            case let .rejected(runID, reason):
                outcomeDescription = "rejected:\(reason)"
                outcomeRunID = runID
            }
            return (
                restrictedTools: state.restrictedTools,
                additionalTools: state.additionalTools,
                purpose: state.purpose,
                windowID: state.windowID,
                outcome: outcomeDescription,
                runID: outcomeRunID
            )
        }

        func debugBootstrapPolicyAdmissionStatus(
            bootstrapClientName: String?,
            connectionID: UUID,
            sessionKey: String? = nil,
            clientPid: Int,
            isReplacementForSession: Bool = false,
            timeout: TimeInterval = 0.05
        ) async -> String {
            let readiness = await awaitAgentBootstrapPolicyBeforeAcceptIfNeeded(
                bootstrapClientName: bootstrapClientName,
                connectionID: connectionID,
                sessionKey: sessionKey,
                clientPid: clientPid,
                isReplacementForSession: isReplacementForSession,
                timeout: timeout
            )
            switch readiness {
            case .notRequired:
                return "notRequired"
            case .ready:
                return "ready"
            case .timedOut:
                return "timedOut"
            }
        }

        func debugAgentPolicyAdmissionStatus(
            clientName: String,
            bootstrapClientName: String? = nil,
            connectionID: UUID,
            sessionKey: String? = nil,
            clientPid: Int,
            timeout: TimeInterval = 0.05
        ) async -> String {
            let readiness = await awaitAgentPolicyAdmissionIfNeeded(
                clientName: clientName,
                bootstrapClientName: bootstrapClientName,
                connectionID: connectionID,
                sessionKey: sessionKey,
                clientPid: clientPid,
                timeout: timeout
            )
            switch readiness {
            case .notRequired:
                return "notRequired"
            case .ready:
                return "ready"
            case .timedOut:
                return "timedOut"
            }
        }

        func debugRunPolicyState(for runID: UUID) -> (windowID: Int, workspaceID: UUID?, restrictedTools: Set<String>, additionalTools: Set<String>?, purpose: MCPRunPurpose)? {
            guard let cached = runPolicyStateByRunID[runID] else { return nil }
            return (
                windowID: cached.windowID,
                workspaceID: cached.workspaceID,
                restrictedTools: cached.restrictedTools,
                additionalTools: cached.additionalTools,
                purpose: cached.purpose
            )
        }

        func debugSeedRunPolicyState(
            runID: UUID,
            windowID: Int = 1,
            workspaceID: UUID? = nil,
            tabID: UUID? = nil,
            restrictedTools: Set<String>,
            additionalTools: Set<String>?,
            purpose: MCPRunPurpose,
            updatedAt: Date = Date()
        ) {
            seedRunPolicyState(
                runID: runID,
                windowID: windowID,
                workspaceID: workspaceID,
                tabID: tabID,
                restrictedTools: restrictedTools,
                additionalTools: additionalTools,
                purpose: purpose,
                updatedAt: updatedAt
            )
        }

        func debugConnectionPolicyState(for connectionID: UUID) -> (restrictedTools: Set<String>, additionalTools: Set<String>, purpose: MCPRunPurpose, windowID: Int?) {
            (
                restrictedTools: restrictedToolsByConnection[connectionID] ?? [],
                additionalTools: additionalToolsByConnection[connectionID] ?? [],
                purpose: runPurposeByConnection[connectionID] ?? .unknown,
                windowID: connectionWindowMap[connectionID]
            )
        }

        func debugCachedRunID(for connectionID: UUID) -> UUID? {
            runIDByConnectionID[connectionID]
        }

        func debugSeedConnectionRunRouting(
            connectionID: UUID,
            runID: UUID,
            purpose: MCPRunPurpose = .unknown,
            windowID: Int? = nil
        ) {
            runIDByConnectionID[connectionID] = runID
            if purpose != .unknown || runPurposeByConnection[connectionID] == nil {
                runPurposeByConnection[connectionID] = purpose
            }
            if let windowID {
                connectionWindowMap[connectionID] = windowID
                windowIDByRunID[runID] = windowID
            }
        }

        func debugRestorePersistedAgentModePolicy(
            clientName: String,
            connectionID: UUID,
            windowID: Int,
            runID: UUID?,
            runPurpose _: MCPRunPurpose?
        ) async -> (didRestore: Bool, restrictedTools: Set<String>, additionalTools: Set<String>, purpose: MCPRunPurpose, cachedPolicyPurpose: MCPRunPurpose?) {
            setConnectionWindowMapping(connectionID, windowID: windowID)
            let cachedPurpose = runID.flatMap { runPolicyStateByRunID[$0]?.purpose }
            let didRestore: Bool
            if let runID,
               runPolicyStateByRunID[runID] != nil,
               shouldAllowPersistedAgentModeRestore(clientName: clientName, purpose: cachedPurpose ?? .unknown)
            {
                updateLiveRunAffinity(
                    clientName: clientName,
                    sessionKey: capabilityTokenByConnection[connectionID],
                    runID: runID,
                    windowID: windowID,
                    purpose: cachedPurpose
                )
                didRestore = await mapConnectionToRunID(connectionID, runID: runID, windowID: windowID)
            } else {
                didRestore = false
            }
            let state = debugConnectionPolicyState(for: connectionID)
            return (
                didRestore: didRestore,
                restrictedTools: state.restrictedTools,
                additionalTools: state.additionalTools,
                purpose: state.purpose,
                cachedPolicyPurpose: cachedPurpose
            )
        }

        func debugEffectivePolicyState(for connectionID: UUID) -> (restrictedTools: Set<String>, additionalTools: Set<String>, purpose: MCPRunPurpose, taskLabelKind: AgentModelCatalog.TaskLabelKind?) {
            let policy = effectivePolicyState(for: connectionID)
            return (
                restrictedTools: policy.restricted,
                additionalTools: policy.additional,
                purpose: policy.purpose,
                taskLabelKind: policy.taskLabelKind
            )
        }

        func debugCanRestoreLiveRunAffinity(hasCachedPolicy: Bool) -> Bool {
            let runID = UUID()
            if hasCachedPolicy {
                seedRunPolicyState(
                    runID: runID,
                    windowID: 1,
                    workspaceID: nil,
                    tabID: nil,
                    restrictedTools: [],
                    additionalTools: nil,
                    purpose: .agentModeRun,
                    updatedAt: Date()
                )
            }
            let canRestore = runPolicyStateByRunID[runID] != nil
            runPolicyStateByRunID.removeValue(forKey: runID)
            return canRestore
        }

        #if DEBUG
            private nonisolated func debugDateMilliseconds(_ date: Date) -> Int {
                Int((date.timeIntervalSince1970 * 1000).rounded())
            }

            private nonisolated func debugConnectionStateString(_ state: ConnectionStateSnapshot) -> String {
                switch state {
                case .connecting: "connecting"
                case .ready: "ready"
                case .failed: "failed"
                case .cancelled: "cancelled"
                }
            }

            private nonisolated func debugBindingKindString(_ kind: MCPServerViewModel.ConnectionBindingSnapshot.BindingKind) -> String {
                switch kind {
                case .tabContext: "tab_context"
                case .windowOnly: "window_only"
                case .unbound: "unbound"
                }
            }

            func debugSessionFingerprint(forToken token: String?) -> String? {
                MCPTerminalFingerprint.session(token)?.description
            }

            func debugSessionFingerprint(forConnection connectionID: UUID) -> String? {
                debugSessionFingerprint(forToken: sessionToken(for: connectionID))
            }

            func debugNormalizedClientID(for clientName: String?) -> String? {
                guard let clientName, !clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return Self.clientStorageKey(clientName)
            }

            private nonisolated static func debugSanitizedRunRoutingFields(_ fields: [String: String]) -> [String: String] {
                let sensitiveKeyFragments = [
                    "auth", "bearer", "credential", "environment", "password", "prompt", "secret",
                    "sessiontoken", "session_token", "token", "transcript"
                ]
                let sensitiveValueFragments = [
                    "authorization:", "proxy-authorization:", "bearer ", "api-key", "api_key",
                    "apikey", "credential", "password", "private_key", "secret", "session_token",
                    "sessiontoken", "token="
                ]
                return fields.sorted { $0.key < $1.key }.prefix(32).reduce(into: [:]) { result, entry in
                    let normalizedKey = entry.key.lowercased().replacingOccurrences(of: "-", with: "_")
                    let normalizedValue = entry.value.lowercased()
                    let isSensitiveKey = sensitiveKeyFragments.contains { normalizedKey.contains($0) }
                        || normalizedKey == "api_key"
                        || normalizedKey.hasSuffix("_api_key")
                        || normalizedKey == "private_key"
                        || normalizedKey.hasSuffix("_private_key")
                    let valueComponents = normalizedValue.split { $0.isWhitespace || $0 == "|" }
                    let containsSensitiveValue = sensitiveValueFragments.contains { fragment in
                        if fragment.contains(" ") {
                            return normalizedValue.contains(fragment)
                        }
                        return valueComponents.contains { component in
                            component.contains(fragment) && !component.contains("<redacted>")
                        }
                    }
                    let value = isSensitiveKey || containsSensitiveValue
                        ? "<redacted>"
                        : String(entry.value.prefix(512))
                    result[String(entry.key.prefix(64))] = value
                }
            }

            func debugRecordRunRoutingEvent(
                runID: UUID,
                event: String,
                connectionID: UUID? = nil,
                fields: [String: String] = [:]
            ) {
                debugRunRoutingHistorySeq &+= 1
                debugRunRoutingHistory.append(DebugRunRoutingEvent(
                    seq: debugRunRoutingHistorySeq,
                    timestamp: Date(),
                    runID: runID,
                    event: String(event.prefix(96)),
                    connectionID: connectionID,
                    fields: Self.debugSanitizedRunRoutingFields(fields)
                ))
                if debugRunRoutingHistory.count > debugRunRoutingHistoryLimit {
                    let overflow = debugRunRoutingHistory.count - debugRunRoutingHistoryLimit
                    debugRunRoutingHistory.removeFirst(overflow)
                    debugRunRoutingHistoryDroppedCount += overflow
                }
            }

            private func debugRunRoutingHistoryObject(_ event: DebugRunRoutingEvent) -> [String: Any] {
                [
                    "seq": Int(event.seq),
                    "timestamp_ms": debugDateMilliseconds(event.timestamp),
                    "run_id": event.runID.uuidString,
                    "event": event.event,
                    "connection_id": event.connectionID?.uuidString ?? NSNull(),
                    "fields": event.fields
                ]
            }

            func debugRunRoutingHistoryPayload(runID: UUID, limit: Int) -> [String: Any] {
                let matching = debugRunRoutingHistory.filter { $0.runID == runID }
                let events = Array(matching.suffix(limit))
                return [
                    "ok": true,
                    "op": "run_routing_history",
                    "run_id": runID.uuidString,
                    "events": events.map(debugRunRoutingHistoryObject),
                    "oldest_available_seq": debugRunRoutingHistory.first.map { Int($0.seq) } ?? NSNull(),
                    "latest_seq": debugRunRoutingHistory.last.map { Int($0.seq) } ?? NSNull(),
                    "dropped_event_count": debugRunRoutingHistoryDroppedCount,
                    "history_capacity": debugRunRoutingHistoryLimit
                ]
            }

            func debugClearRunRoutingHistoryForTesting() {
                debugRunRoutingHistory.removeAll()
                debugRunRoutingHistorySeq = 0
                debugRunRoutingHistoryDroppedCount = 0
            }

            private func debugRecordConnectionEvent(
                _ event: String,
                connectionID: UUID? = nil,
                restartID: UUID? = nil,
                reason: String? = nil,
                state: String? = nil,
                clientName overrideClientName: String? = nil,
                sessionToken overrideSessionToken: String? = nil,
                windowID overrideWindowID: Int? = nil,
                transportIngress: MCPTransportIngressSnapshot? = nil
            ) {
                debugConnectionHistorySeq &+= 1
                let resolvedClientName = overrideClientName ?? connectionID.flatMap { clientIdentifier(forConnection: $0) }
                let resolvedSessionToken = overrideSessionToken ?? connectionID.flatMap { sessionToken(for: $0) }
                let resolvedState: String? = state
                let entry = DebugConnectionEvent(
                    seq: debugConnectionHistorySeq,
                    timestamp: Date(),
                    event: event,
                    restartID: restartID,
                    connectionID: connectionID,
                    clientName: resolvedClientName,
                    normalizedClientID: debugNormalizedClientID(for: resolvedClientName),
                    sessionFingerprint: debugSessionFingerprint(forToken: resolvedSessionToken),
                    windowID: overrideWindowID ?? connectionID.flatMap { connectionWindowMap[$0] },
                    state: resolvedState,
                    reason: reason,
                    transportIngress: transportIngress
                )
                debugConnectionHistory.append(entry)
                if debugConnectionHistory.count > debugConnectionHistoryLimit {
                    debugConnectionHistory.removeFirst(debugConnectionHistory.count - debugConnectionHistoryLimit)
                }
            }

            private nonisolated func debugTransportIngressObject(
                _ snapshot: MCPTransportIngressSnapshot
            ) -> [String: Any] {
                [
                    "receive_capacity": snapshot.receiveBufferCapacity,
                    "accepted_frames": snapshot.acceptedFrameCount,
                    "dropped_frames": snapshot.droppedFrameCount,
                    "receive_high_water_mark": snapshot.receiveBufferHighWaterMark,
                    "terminal": snapshot.isTerminal,
                    "terminal_cause": snapshot.terminalCause?.rawValue ?? NSNull()
                ]
            }

            private func debugHistoryObject(_ event: DebugConnectionEvent) -> [String: Any] {
                [
                    "seq": Int(event.seq),
                    "timestamp_ms": debugDateMilliseconds(event.timestamp),
                    "event": event.event,
                    "restart_id": event.restartID?.uuidString ?? NSNull(),
                    "connection_id": event.connectionID?.uuidString ?? NSNull(),
                    "client_name": event.clientName ?? NSNull(),
                    "normalized_client_id": event.normalizedClientID ?? NSNull(),
                    "session_key_present": event.sessionFingerprint != nil,
                    "session_fingerprint": event.sessionFingerprint ?? NSNull(),
                    "window_id": event.windowID ?? NSNull(),
                    "state": event.state ?? NSNull(),
                    "reason": event.reason ?? NSNull(),
                    "transport_ingress": event.transportIngress.map(debugTransportIngressObject) ?? NSNull()
                ]
            }

            private func debugConnectionObject(for entry: ConnectionDashboardEntry) -> [String: Any] {
                let identity = identityContext(for: entry.id)
                let clientName = identity?.clientName ?? clientIdentifier(forConnection: entry.id) ?? (entry.clientName.isEmpty ? nil : entry.clientName)
                let fingerprint = debugSessionFingerprint(forToken: entry.sessionKey)
                return [
                    "id": entry.id.uuidString,
                    "client_name": clientName ?? NSNull(),
                    "normalized_client_id": debugNormalizedClientID(for: clientName) ?? NSNull(),
                    "session_key_present": entry.sessionKey != nil,
                    "session_fingerprint": fingerprint ?? NSNull(),
                    "window_id": entry.windowID ?? NSNull(),
                    "state": entry.state.rawValue,
                    "transport": entry.transport.rawValue,
                    "created_at_ms": debugDateMilliseconds(entry.createdAt),
                    "last_tool_call_at_ms": entry.lastToolCallAt.map(debugDateMilliseconds) ?? NSNull(),
                    "total_tool_calls": entry.totalToolCalls,
                    "idle_seconds": entry.idleSeconds ?? NSNull(),
                    "has_in_flight_calls": entry.hasInFlightCalls,
                    "active_tool_name": entry.activeToolName ?? NSNull(),
                    "identity": [
                        "client_name": identity?.clientName ?? NSNull(),
                        "source": identity?.source.rawValue ?? "unknown",
                        "has_handshake": identity?.hasHandshake ?? false,
                        "session_key_present": identity?.capabilityToken != nil,
                        "session_fingerprint": debugSessionFingerprint(forToken: identity?.capabilityToken) ?? NSNull()
                    ] as [String: Any]
                ]
            }

            private func debugBindingSnapshot(for connectionID: UUID, selectedWindowID: Int?) async -> MCPServerViewModel.ConnectionBindingSnapshot {
                await MainActor.run {
                    let windows = WindowStatesManager.shared.allWindows
                    let snapshots = windows.map { $0.mcpServer.connectionBindingSnapshot(forConnection: connectionID) }
                    if let explicit = snapshots.first(where: { $0.bindingKind == .tabContext && $0.explicitlyBound && $0.runID == nil }) {
                        return explicit
                    }
                    if let runScoped = snapshots.first(where: { $0.bindingKind == .tabContext && $0.runID != nil }) {
                        return runScoped
                    }
                    if let context = snapshots.first(where: { $0.bindingKind == .tabContext }) {
                        return context
                    }
                    if let selectedWindowID,
                       let selectedWindow = windows.first(where: { $0.windowID == selectedWindowID })
                    {
                        let workspace = selectedWindow.workspaceManager.activeWorkspace
                        return MCPServerViewModel.ConnectionBindingSnapshot(
                            windowID: selectedWindowID,
                            tabID: nil,
                            workspaceID: workspace?.id,
                            workspaceName: workspace?.isSystemWorkspace == true ? "Default (no workspace loaded)" : workspace?.name,
                            tabName: nil,
                            repoPaths: workspace.map { WorkspaceManagerViewModel.loadableRepoPaths(for: $0) } ?? [],
                            explicitlyBound: false,
                            runID: nil
                        )
                    }
                    return MCPServerViewModel.ConnectionBindingSnapshot(
                        windowID: nil,
                        tabID: nil,
                        workspaceID: nil,
                        workspaceName: nil,
                        tabName: nil,
                        repoPaths: [],
                        explicitlyBound: false,
                        runID: nil
                    )
                }
            }

            private func debugBindingObject(_ snapshot: MCPServerViewModel.ConnectionBindingSnapshot) -> [String: Any] {
                [
                    "binding_kind": debugBindingKindString(snapshot.bindingKind),
                    "window_id": snapshot.windowID ?? NSNull(),
                    "context_id": snapshot.tabID?.uuidString ?? NSNull(),
                    "workspace_id": snapshot.workspaceID?.uuidString ?? NSNull(),
                    "workspace_name": snapshot.workspaceName ?? NSNull(),
                    "tab_name": snapshot.tabName ?? NSNull(),
                    "repo_paths": snapshot.repoPaths,
                    "explicit": snapshot.explicitlyBound,
                    "run_scoped": snapshot.runID != nil,
                    "run_id": snapshot.runID?.uuidString ?? NSNull()
                ]
            }

            private func debugWindowObjects() async -> [[String: Any]] {
                await MainActor.run {
                    WindowStatesManager.shared.allWindows.map { window in
                        let workspace = window.workspaceManager.activeWorkspace
                        let activeTabID = window.promptManager.activeComposeTabID
                        let workspaceID: Any = workspace?.id.uuidString ?? NSNull()
                        let workspaceName: Any = if workspace?.isSystemWorkspace == true {
                            "Default (no workspace loaded)"
                        } else {
                            workspace?.name ?? NSNull()
                        }
                        let workspaceInstanceNumber: Any = window.workspaceInstanceNumber ?? NSNull()
                        let activeContextID: Any = activeTabID?.uuidString ?? NSNull()
                        let activeContextName: Any = activeTabID.flatMap { window.workspaceManager.composeTabName(with: $0) } ?? NSNull()
                        let repoPaths: [String] = workspace.map { WorkspaceManagerViewModel.loadableRepoPaths(for: $0) } ?? []
                        return [
                            "window_id": window.windowID,
                            "workspace_id": workspaceID,
                            "workspace_name": workspaceName,
                            "workspace_instance_number": workspaceInstanceNumber,
                            "active_context_id": activeContextID,
                            "active_context_name": activeContextName,
                            "repo_paths": repoPaths
                        ] as [String: Any]
                    }
                }
            }

            private func debugPersistedRecordObjects(clientNameFilter: String?, sessionFingerprint: String?) -> [[String: Any]] {
                let keys: [String] = if let clientNameFilter, !clientNameFilter.isEmpty {
                    matchingClientKeys(for: clientNameFilter, in: Array(routingState.records.keys))
                } else {
                    Array(routingState.records.keys).sorted()
                }
                return keys.flatMap { key in
                    (routingState.records[key] ?? []).compactMap { record -> [String: Any]? in
                        let fingerprint = debugSessionFingerprint(forToken: record.sessionKey)
                        if let sessionFingerprint, fingerprint != sessionFingerprint {
                            return nil
                        }
                        return [
                            "client_id": key,
                            "last_transport": record.lastTransport.rawValue,
                            "session_key_present": record.sessionKey != nil,
                            "session_fingerprint": fingerprint ?? NSNull(),
                            "last_window_id": record.lastWindowID ?? NSNull(),
                            "last_workspace_id": record.lastWorkspaceID?.uuidString ?? NSNull(),
                            "last_workspace_instance_number": record.lastWorkspaceInstanceNumber ?? NSNull(),
                            "last_connection_uuid": record.lastConnectionUUID?.uuidString ?? NSNull(),
                            "last_seen_at_ms": debugDateMilliseconds(record.lastSeenAt)
                        ]
                    }
                }
            }

            func debugBindingKind(for connectionID: UUID) async -> String {
                let snapshot = await debugBindingSnapshot(for: connectionID, selectedWindowID: connectionWindowMap[connectionID])
                return debugBindingKindString(snapshot.bindingKind)
            }

            private func debugLiveAffinityObject(clientName: String?, sessionKey: String?) -> [String: Any] {
                guard let clientName, let sessionKey else {
                    return ["present": false, "window_id": NSNull(), "run_id": NSNull(), "purpose": NSNull()]
                }
                let keys = matchingClientKeys(for: clientName, in: Array(liveRunAffinityByClientSession.keys))
                guard let key = keys.first,
                      let affinity = liveRunAffinityByClientSession[key]?[sessionKey]
                else {
                    return ["present": false, "window_id": NSNull(), "run_id": NSNull(), "purpose": NSNull()]
                }
                return [
                    "present": true,
                    "window_id": affinity.windowID,
                    "run_id": affinity.runID.uuidString,
                    "purpose": affinity.purpose.rawValue,
                    "last_seen_at_ms": debugDateMilliseconds(affinity.lastSeenAt)
                ]
            }

            func debugTransportIngressSnapshotPayload(
                currentConnectionID: UUID,
                requestedConnectionID: UUID?
            ) async -> [String: Any] {
                let targetID = requestedConnectionID ?? currentConnectionID
                if let connection = connections[targetID],
                   let snapshot = await connection.transportIngressSnapshot()
                {
                    return [
                        "ok": true,
                        "op": "transport_snapshot",
                        "current_connection_id": currentConnectionID.uuidString,
                        "requested_connection_id": targetID.uuidString,
                        "present": true,
                        "active": true,
                        "ingress": debugTransportIngressObject(snapshot)
                    ]
                }
                if let retained = debugRetainedTransportIngressByConnectionID[targetID] {
                    return [
                        "ok": true,
                        "op": "transport_snapshot",
                        "current_connection_id": currentConnectionID.uuidString,
                        "requested_connection_id": targetID.uuidString,
                        "present": true,
                        "active": false,
                        "client_name": retained.clientName ?? NSNull(),
                        "session_fingerprint": debugSessionFingerprint(forToken: retained.sessionToken) ?? NSNull(),
                        "ingress": debugTransportIngressObject(retained.snapshot)
                    ]
                }
                return [
                    "ok": true,
                    "op": "transport_snapshot",
                    "current_connection_id": currentConnectionID.uuidString,
                    "requested_connection_id": targetID.uuidString,
                    "present": false,
                    "active": false,
                    "ingress": NSNull()
                ]
            }

            func debugConnectionSnapshotPayload(
                currentConnectionID: UUID,
                requestedConnectionID: UUID?,
                includeHistory: Bool,
                historyLimit: Int
            ) async -> [String: Any] {
                let targetID = requestedConnectionID ?? currentConnectionID
                let snapshot = await dashboardSnapshot()
                let entry = snapshot.connections.first { $0.id == targetID }
                var payload: [String: Any] = [
                    "ok": true,
                    "op": "connection_snapshot",
                    "current_connection_id": currentConnectionID.uuidString,
                    "requested_connection_id": targetID.uuidString,
                    "connection": entry.map(debugConnectionObject) ?? NSNull(),
                    "missing": entry == nil
                ]
                if includeHistory {
                    payload["history"] = debugConnectionHistoryPayload(limit: historyLimit, clientName: nil, sessionFingerprint: nil, connectionID: targetID)["events"] ?? []
                }
                return payload
            }

            func debugRoutingSnapshotPayload(
                currentConnectionID: UUID,
                requestedConnectionID: UUID?,
                clientNameFilter: String?,
                includeRecords: Bool,
                includeWindows: Bool
            ) async -> [String: Any] {
                let targetID = requestedConnectionID ?? currentConnectionID
                let snapshot = await dashboardSnapshot()
                let entry = snapshot.connections.first { $0.id == targetID }
                let clientName = clientNameFilter ?? entry?.clientName ?? clientIdentifier(forConnection: targetID)
                let sessionKey = entry?.sessionKey ?? sessionToken(for: targetID)
                let fingerprint = debugSessionFingerprint(forToken: sessionKey)
                let selectedWindowID = entry?.windowID ?? connectionWindowMap[targetID]
                let binding = await debugBindingSnapshot(for: targetID, selectedWindowID: selectedWindowID)
                let liveAffinity = debugLiveAffinityObject(clientName: clientName, sessionKey: sessionKey)
                var payload: [String: Any] = [
                    "ok": true,
                    "op": "routing_snapshot",
                    "current_connection_id": currentConnectionID.uuidString,
                    "connection": entry.map(debugConnectionObject) ?? [
                        "id": targetID.uuidString,
                        "client_name": clientName ?? NSNull(),
                        "normalized_client_id": debugNormalizedClientID(for: clientName) ?? NSNull(),
                        "session_key_present": fingerprint != nil,
                        "session_fingerprint": fingerprint ?? NSNull(),
                        "selected_window_id": selectedWindowID ?? NSNull(),
                        "run_id": runIDByConnectionID[targetID]?.uuidString ?? NSNull(),
                        "purpose": runPurposeByConnection[targetID]?.rawValue ?? "unknown"
                    ] as [String: Any],
                    "binding": debugBindingObject(binding),
                    "live_affinity": liveAffinity
                ]
                if includeRecords {
                    payload["persisted_records"] = debugPersistedRecordObjects(clientNameFilter: clientName, sessionFingerprint: fingerprint)
                }
                if includeWindows {
                    payload["windows"] = await debugWindowObjects()
                }
                return payload
            }

            func debugConnectionHistoryPayload(limit: Int, clientName: String?, sessionFingerprint: String?, connectionID: UUID?) -> [String: Any] {
                var events = debugConnectionHistory
                if let connectionID {
                    events = events.filter { $0.connectionID == connectionID }
                }
                if let clientName, !clientName.isEmpty {
                    events = events.filter { event in
                        guard let eventClientName = event.clientName else { return false }
                        return MCPClientIdentity.matches(eventClientName, clientName)
                    }
                }
                if let sessionFingerprint, !sessionFingerprint.isEmpty {
                    events = events.filter { $0.sessionFingerprint == sessionFingerprint }
                }
                events = Array(events.suffix(limit))
                return [
                    "ok": true,
                    "op": "connection_history",
                    "events": events.map(debugHistoryObject)
                ]
            }

            func debugClearConnectionHistoryPayload() -> [String: Any] {
                let removed = debugConnectionHistory.count
                debugConnectionHistory.removeAll()
                debugRetainedTransportIngressByConnectionID.removeAll()
                debugRetainedTransportIngressOrder.removeAll()
                debugRecordedTransportTerminalConnectionIDs.removeAll()
                return [
                    "ok": true,
                    "op": "clear_connection_history",
                    "cleared": true,
                    "removed_count": removed
                ]
            }

            func debugWaitForReconnectPayload(
                currentConnectionID: UUID,
                clientName requestedClientName: String?,
                sessionFingerprint requestedFingerprint: String?,
                excludeConnectionIDs: Set<UUID>,
                timeoutMS: Int,
                pollMS: Int,
                requireReady: Bool
            ) async -> [String: Any] {
                let start = Date()
                let fallbackClientName = clientIdentifier(forConnection: currentConnectionID) ?? identityContext(for: currentConnectionID)?.clientName
                let clientName = requestedClientName ?? fallbackClientName
                let fingerprint = requestedFingerprint ?? debugSessionFingerprint(forConnection: currentConnectionID)
                guard let clientName, let fingerprint else {
                    return [
                        "ok": false,
                        "op": "wait_for_reconnect",
                        "code": "invalid_params",
                        "error": "client_name and session_fingerprint must be provided or resolvable from the current connection."
                    ]
                }

                let deadline = start.addingTimeInterval(Double(timeoutMS) / 1000.0)
                var found: ConnectionDashboardEntry?
                repeat {
                    let snapshot = await dashboardSnapshot()
                    found = snapshot.connections.first { entry in
                        guard !excludeConnectionIDs.contains(entry.id) else { return false }
                        guard MCPClientIdentity.matches(entry.clientName, clientName) else { return false }
                        guard debugSessionFingerprint(forToken: entry.sessionKey) == fingerprint else { return false }
                        if requireReady, entry.state != .ready { return false }
                        return true
                    }
                    if found != nil { break }
                    try? await Task.sleep(for: .milliseconds(pollMS))
                } while Date() < deadline

                let elapsed = debugDateMilliseconds(Date()) - debugDateMilliseconds(start)
                return [
                    "ok": true,
                    "op": "wait_for_reconnect",
                    "found": found != nil,
                    "elapsed_ms": elapsed,
                    "connection": found.map(debugConnectionObject) ?? NSNull()
                ]
            }

            func debugClearRoutingStatePayload(currentConnectionID: UUID, clientName: String?, allClients: Bool) -> [String: Any] {
                let resolvedClientName = clientName ?? clientIdentifier(forConnection: currentConnectionID) ?? identityContext(for: currentConnectionID)?.clientName
                let removedCount: Int
                if allClients {
                    removedCount = routingState.records.values.reduce(0) { $0 + $1.count }
                    routingState.records.removeAll()
                    lastWindowByClientSession.removeAll()
                    liveRunAffinityByClientSession.removeAll()
                } else if let resolvedClientName {
                    let keys = matchingClientKeys(for: resolvedClientName, in: Array(routingState.records.keys))
                    removedCount = keys.reduce(0) { $0 + (routingState.records[$1]?.count ?? 0) }
                    for key in keys {
                        routingState.records.removeValue(forKey: key)
                    }
                    for key in matchingClientKeys(for: resolvedClientName, in: Array(lastWindowByClientSession.keys)) {
                        lastWindowByClientSession.removeValue(forKey: key)
                    }
                    for key in matchingClientKeys(for: resolvedClientName, in: Array(liveRunAffinityByClientSession.keys)) {
                        liveRunAffinityByClientSession.removeValue(forKey: key)
                    }
                } else {
                    return [
                        "ok": false,
                        "op": "clear_routing_state",
                        "code": "invalid_params",
                        "error": "client_name must be provided or resolvable unless all_clients=true."
                    ]
                }
                saveRoutingState()
                return [
                    "ok": true,
                    "op": "clear_routing_state",
                    "cleared": true,
                    "client_name": resolvedClientName ?? NSNull(),
                    "all_clients": allClients,
                    "removed_record_count": removedCount
                ]
            }

            struct DebugExactRoutingSessionFixtureSession {
                let sessionFingerprint: String
                let expectedLastConnectionID: UUID
                let rawSessionToken: String
            }

            struct DebugExactRoutingSessionFixture {
                let restoreID: UUID
                let sessionA: DebugExactRoutingSessionFixtureSession
                let sessionB: DebugExactRoutingSessionFixtureSession
                let reboundConnectionID: UUID
            }

            struct DebugExactRoutingSessionFixtureState: Equatable {
                let persistedRecordCountByFingerprint: [String: Int]
                let lastWindowEntryCountByFingerprint: [String: Int]
                let liveRunAffinityEntryCountByFingerprint: [String: Int]
            }

            private struct DebugExactRoutingSessionFixtureRestorePoint {
                let routingState: MCPRoutingState
                let lastWindowByClientSession: [String: [String: Int]]
                let liveRunAffinityByClientSession: [String: [String: LiveRunAffinity]]
                let pendingConnections: [UUID: String]
                let activeConnectionsByClient: [String: Set<UUID>]
                let clientIDByConnection: [UUID: String]
                let capabilityTokenByConnection: [UUID: String]
                let connectionIDBySessionToken: [String: UUID]
            }

            func debugClearPersistedRoutingSessionPayload(
                sessionFingerprint: String,
                expectedLastConnectionID: UUID
            ) -> [String: Any] {
                guard !debugHasActiveOrPendingRuntimeResidue(for: expectedLastConnectionID) else {
                    return debugExactRoutingSessionCleanupError(
                        sessionFingerprint: sessionFingerprint,
                        expectedLastConnectionID: expectedLastConnectionID,
                        code: "target_connection_active_or_pending",
                        message: "expected_last_connection_id remains active or pending."
                    )
                }

                var matchingRawSessionKeys = Set<String>()
                for records in routingState.records.values {
                    for record in records {
                        guard let sessionKey = record.sessionKey, !sessionKey.isEmpty else { continue }
                        if debugSessionFingerprint(forToken: sessionKey) == sessionFingerprint {
                            matchingRawSessionKeys.insert(sessionKey)
                        }
                    }
                }
                for sessionMap in lastWindowByClientSession.values {
                    for sessionKey in sessionMap.keys where !sessionKey.isEmpty {
                        if debugSessionFingerprint(forToken: sessionKey) == sessionFingerprint {
                            matchingRawSessionKeys.insert(sessionKey)
                        }
                    }
                }
                for sessionMap in liveRunAffinityByClientSession.values {
                    for sessionKey in sessionMap.keys where !sessionKey.isEmpty {
                        if debugSessionFingerprint(forToken: sessionKey) == sessionFingerprint {
                            matchingRawSessionKeys.insert(sessionKey)
                        }
                    }
                }

                guard !matchingRawSessionKeys.isEmpty else {
                    return debugExactRoutingSessionCleanupSuccess(
                        sessionFingerprint: sessionFingerprint,
                        expectedLastConnectionID: expectedLastConnectionID,
                        alreadyAbsent: true,
                        removedPersistedRecordCount: 0,
                        removedLastWindowEntryCount: 0,
                        removedLiveRunAffinityEntryCount: 0
                    )
                }
                guard matchingRawSessionKeys.count == 1, let rawSessionKey = matchingRawSessionKeys.first else {
                    return debugExactRoutingSessionCleanupError(
                        sessionFingerprint: sessionFingerprint,
                        expectedLastConnectionID: expectedLastConnectionID,
                        code: "ambiguous_session_fingerprint",
                        message: "session_fingerprint resolves to multiple persisted routing sessions."
                    )
                }

                let matchedRecords = routingState.records.flatMap { clientID, records in
                    records.compactMap { record -> (clientID: String, record: MCPRoutingState.ClientRecord)? in
                        record.sessionKey == rawSessionKey ? (clientID, record) : nil
                    }
                }
                guard !matchedRecords.isEmpty else {
                    return debugExactRoutingSessionCleanupError(
                        sessionFingerprint: sessionFingerprint,
                        expectedLastConnectionID: expectedLastConnectionID,
                        code: "unexpected_routing_state_shape",
                        message: "session_fingerprint resolved only to map residue without a persisted record."
                    )
                }
                for matchedRecord in matchedRecords {
                    guard matchedRecord.record.sessionKey == rawSessionKey,
                          !rawSessionKey.isEmpty,
                          matchedRecord.record.clientID == matchedRecord.clientID
                    else {
                        return debugExactRoutingSessionCleanupError(
                            sessionFingerprint: sessionFingerprint,
                            expectedLastConnectionID: expectedLastConnectionID,
                            code: "unexpected_routing_state_shape",
                            message: "Persisted routing record shape is inconsistent."
                        )
                    }
                    guard let lastConnectionUUID = matchedRecord.record.lastConnectionUUID else {
                        return debugExactRoutingSessionCleanupError(
                            sessionFingerprint: sessionFingerprint,
                            expectedLastConnectionID: expectedLastConnectionID,
                            code: "unexpected_routing_state_shape",
                            message: "Persisted routing record is missing last_connection_id corroboration."
                        )
                    }
                    guard lastConnectionUUID == expectedLastConnectionID else {
                        return debugExactRoutingSessionCleanupError(
                            sessionFingerprint: sessionFingerprint,
                            expectedLastConnectionID: expectedLastConnectionID,
                            code: "last_connection_id_mismatch",
                            message: "Persisted routing record does not match expected_last_connection_id."
                        )
                    }
                }

                let reverseConnectionID = connectionIDBySessionToken[rawSessionKey]
                let forwardConnectionIDs = Set(capabilityTokenByConnection.compactMap { connectionID, sessionKey in
                    sessionKey == rawSessionKey ? connectionID : nil
                })
                let activeConnectionTokenIDs = Set(connections.compactMap { connectionID, connection in
                    connection.capabilityToken == rawSessionKey ? connectionID : nil
                })
                if reverseConnectionID != nil || !forwardConnectionIDs.isEmpty || !activeConnectionTokenIDs.isEmpty {
                    guard let reverseConnectionID,
                          forwardConnectionIDs == Set([reverseConnectionID]),
                          activeConnectionTokenIDs.isEmpty || activeConnectionTokenIDs == Set([reverseConnectionID])
                    else {
                        return debugExactRoutingSessionCleanupError(
                            sessionFingerprint: sessionFingerprint,
                            expectedLastConnectionID: expectedLastConnectionID,
                            code: "unexpected_routing_state_shape",
                            message: "Session token caches are stale or inconsistent."
                        )
                    }
                    guard debugHasActiveOrPendingRuntimeResidue(for: reverseConnectionID) else {
                        return debugExactRoutingSessionCleanupError(
                            sessionFingerprint: sessionFingerprint,
                            expectedLastConnectionID: expectedLastConnectionID,
                            code: "unexpected_routing_state_shape",
                            message: "Session token caches reference a non-live connection."
                        )
                    }
                    return debugExactRoutingSessionCleanupError(
                        sessionFingerprint: sessionFingerprint,
                        expectedLastConnectionID: expectedLastConnectionID,
                        code: "session_rebound_active",
                        message: "Persisted routing session is rebound to a live connection."
                    )
                }

                var nextRecords = routingState.records
                var removedPersistedRecordCount = 0
                for clientID in Array(nextRecords.keys) {
                    guard let records = nextRecords[clientID] else { continue }
                    let retainedRecords = records.filter { $0.sessionKey != rawSessionKey }
                    removedPersistedRecordCount += records.count - retainedRecords.count
                    if retainedRecords.isEmpty {
                        nextRecords.removeValue(forKey: clientID)
                    } else {
                        nextRecords[clientID] = retainedRecords
                    }
                }

                var nextLastWindowByClientSession = lastWindowByClientSession
                var removedLastWindowEntryCount = 0
                for clientID in Array(nextLastWindowByClientSession.keys) {
                    guard var sessionMap = nextLastWindowByClientSession[clientID] else { continue }
                    if sessionMap.removeValue(forKey: rawSessionKey) != nil {
                        removedLastWindowEntryCount += 1
                    }
                    if sessionMap.isEmpty {
                        nextLastWindowByClientSession.removeValue(forKey: clientID)
                    } else {
                        nextLastWindowByClientSession[clientID] = sessionMap
                    }
                }

                var nextLiveRunAffinityByClientSession = liveRunAffinityByClientSession
                var removedLiveRunAffinityEntryCount = 0
                for clientID in Array(nextLiveRunAffinityByClientSession.keys) {
                    guard var sessionMap = nextLiveRunAffinityByClientSession[clientID] else { continue }
                    if sessionMap.removeValue(forKey: rawSessionKey) != nil {
                        removedLiveRunAffinityEntryCount += 1
                    }
                    if sessionMap.isEmpty {
                        nextLiveRunAffinityByClientSession.removeValue(forKey: clientID)
                    } else {
                        nextLiveRunAffinityByClientSession[clientID] = sessionMap
                    }
                }

                routingState.records = nextRecords
                lastWindowByClientSession = nextLastWindowByClientSession
                liveRunAffinityByClientSession = nextLiveRunAffinityByClientSession
                if removedPersistedRecordCount > 0 {
                    saveRoutingState()
                }
                return debugExactRoutingSessionCleanupSuccess(
                    sessionFingerprint: sessionFingerprint,
                    expectedLastConnectionID: expectedLastConnectionID,
                    alreadyAbsent: false,
                    removedPersistedRecordCount: removedPersistedRecordCount,
                    removedLastWindowEntryCount: removedLastWindowEntryCount,
                    removedLiveRunAffinityEntryCount: removedLiveRunAffinityEntryCount
                )
            }

            private func debugHasActiveOrPendingRuntimeResidue(for connectionID: UUID) -> Bool {
                connections[connectionID] != nil
                    || connectionTasks[connectionID] != nil
                    || pendingConnections[connectionID] != nil
                    || bootstrapReservations[connectionID] != nil
                    || clientIDByConnection[connectionID] != nil
                    || activeConnectionsByClient.values.contains { $0.contains(connectionID) }
                    || callLimiters[connectionID] != nil
            }

            private func debugExactRoutingSessionCleanupSuccess(
                sessionFingerprint: String,
                expectedLastConnectionID: UUID,
                alreadyAbsent: Bool,
                removedPersistedRecordCount: Int,
                removedLastWindowEntryCount: Int,
                removedLiveRunAffinityEntryCount: Int
            ) -> [String: Any] {
                let removedTotalCount = removedPersistedRecordCount
                    + removedLastWindowEntryCount
                    + removedLiveRunAffinityEntryCount
                return [
                    "ok": true,
                    "op": "clear_persisted_routing_session",
                    "session_fingerprint": sessionFingerprint,
                    "expected_last_connection_id": expectedLastConnectionID.uuidString,
                    "already_absent": alreadyAbsent,
                    "changed": removedTotalCount > 0,
                    "removed_persisted_record_count": removedPersistedRecordCount,
                    "removed_last_window_entry_count": removedLastWindowEntryCount,
                    "removed_live_run_affinity_entry_count": removedLiveRunAffinityEntryCount,
                    "removed_total_count": removedTotalCount
                ]
            }

            private func debugExactRoutingSessionCleanupError(
                sessionFingerprint: String,
                expectedLastConnectionID: UUID,
                code: String,
                message: String
            ) -> [String: Any] {
                [
                    "ok": false,
                    "op": "clear_persisted_routing_session",
                    "session_fingerprint": sessionFingerprint,
                    "expected_last_connection_id": expectedLastConnectionID.uuidString,
                    "code": code,
                    "error": message
                ]
            }

            func debugSeedExactRoutingSessionFixture() -> DebugExactRoutingSessionFixture {
                let clientID = AgentProviderKind.codexMCPClientID
                let sessionAToken = "debug-exact-routing-session-a"
                let sessionBToken = "debug-exact-routing-session-b"
                let sessionAConnectionID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
                let sessionBConnectionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
                let reboundConnectionID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
                let restoreID = UUID()
                debugExactRoutingSessionRestorePoints[restoreID] = DebugExactRoutingSessionFixtureRestorePoint(
                    routingState: routingState,
                    lastWindowByClientSession: lastWindowByClientSession,
                    liveRunAffinityByClientSession: liveRunAffinityByClientSession,
                    pendingConnections: pendingConnections,
                    activeConnectionsByClient: activeConnectionsByClient,
                    clientIDByConnection: clientIDByConnection,
                    capabilityTokenByConnection: capabilityTokenByConnection,
                    connectionIDBySessionToken: connectionIDBySessionToken
                )

                debugRemoveExactRoutingSessionFixtureToken(sessionAToken)
                debugRemoveExactRoutingSessionFixtureToken(sessionBToken)
                debugRemoveExactRoutingSessionFixtureRuntimeResidue(for: sessionAConnectionID)
                debugRemoveExactRoutingSessionFixtureRuntimeResidue(for: sessionBConnectionID)
                debugRemoveExactRoutingSessionFixtureRuntimeResidue(for: reboundConnectionID)

                routingState.records[clientID, default: []].append(contentsOf: [
                    MCPRoutingState.ClientRecord(
                        clientID: clientID,
                        lastTransport: .network,
                        sessionKey: sessionAToken,
                        lastWindowID: 9101,
                        lastWorkspaceID: nil,
                        lastWorkspaceInstanceNumber: nil,
                        lastConnectionUUID: sessionAConnectionID,
                        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_001)
                    ),
                    MCPRoutingState.ClientRecord(
                        clientID: clientID,
                        lastTransport: .network,
                        sessionKey: sessionBToken,
                        lastWindowID: 9102,
                        lastWorkspaceID: nil,
                        lastWorkspaceInstanceNumber: nil,
                        lastConnectionUUID: sessionBConnectionID,
                        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_002)
                    )
                ])
                lastWindowByClientSession[clientID, default: [:]][sessionAToken] = 9101
                lastWindowByClientSession[clientID, default: [:]][sessionBToken] = 9102
                liveRunAffinityByClientSession[clientID, default: [:]][sessionAToken] = LiveRunAffinity(
                    windowID: 9101,
                    runID: UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!,
                    purpose: .agentModeRun,
                    lastSeenAt: Date(timeIntervalSince1970: 1_700_000_001)
                )
                liveRunAffinityByClientSession[clientID, default: [:]][sessionBToken] = LiveRunAffinity(
                    windowID: 9102,
                    runID: UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!,
                    purpose: .agentModeRun,
                    lastSeenAt: Date(timeIntervalSince1970: 1_700_000_002)
                )
                saveRoutingState()

                return DebugExactRoutingSessionFixture(
                    restoreID: restoreID,
                    sessionA: DebugExactRoutingSessionFixtureSession(
                        sessionFingerprint: debugSessionFingerprint(forToken: sessionAToken)!,
                        expectedLastConnectionID: sessionAConnectionID,
                        rawSessionToken: sessionAToken
                    ),
                    sessionB: DebugExactRoutingSessionFixtureSession(
                        sessionFingerprint: debugSessionFingerprint(forToken: sessionBToken)!,
                        expectedLastConnectionID: sessionBConnectionID,
                        rawSessionToken: sessionBToken
                    ),
                    reboundConnectionID: reboundConnectionID
                )
            }

            func debugSetExactRoutingSessionFixtureTargetActive(
                _ session: DebugExactRoutingSessionFixtureSession,
                active: Bool
            ) {
                let clientID = AgentProviderKind.codexMCPClientID
                if active {
                    clientIDByConnection[session.expectedLastConnectionID] = clientID
                    activeConnectionsByClient[clientID, default: []].insert(session.expectedLastConnectionID)
                } else {
                    debugRemoveExactRoutingSessionFixtureRuntimeResidue(for: session.expectedLastConnectionID)
                }
            }

            func debugSetExactRoutingSessionFixtureTargetPending(
                _ session: DebugExactRoutingSessionFixtureSession,
                pending: Bool
            ) {
                if pending {
                    pendingConnections[session.expectedLastConnectionID] = AgentProviderKind.codexMCPClientID
                } else {
                    pendingConnections.removeValue(forKey: session.expectedLastConnectionID)
                }
            }

            func debugSetExactRoutingSessionFixtureReboundActive(
                _ fixture: DebugExactRoutingSessionFixture,
                active: Bool
            ) {
                let clientID = AgentProviderKind.codexMCPClientID
                let reboundConnectionID = fixture.reboundConnectionID
                if active {
                    debugRemoveExactRoutingSessionFixtureRuntimeResidue(for: reboundConnectionID)
                    debugRemoveExactRoutingSessionFixtureTokenBindings(fixture.sessionA.rawSessionToken)
                    clientIDByConnection[reboundConnectionID] = clientID
                    activeConnectionsByClient[clientID, default: []].insert(reboundConnectionID)
                    capabilityTokenByConnection[reboundConnectionID] = fixture.sessionA.rawSessionToken
                    connectionIDBySessionToken[fixture.sessionA.rawSessionToken] = reboundConnectionID
                } else {
                    debugRemoveExactRoutingSessionFixtureRuntimeResidue(for: reboundConnectionID)
                    debugRemoveExactRoutingSessionFixtureTokenBindings(fixture.sessionA.rawSessionToken)
                }
            }

            func debugExactRoutingSessionFixtureState() -> DebugExactRoutingSessionFixtureState {
                var persistedRecordCountByFingerprint: [String: Int] = [:]
                var lastWindowEntryCountByFingerprint: [String: Int] = [:]
                var liveRunAffinityEntryCountByFingerprint: [String: Int] = [:]
                func increment(_ sessionToken: String?, counts: inout [String: Int]) {
                    guard let sessionToken,
                          !sessionToken.isEmpty,
                          let fingerprint = debugSessionFingerprint(forToken: sessionToken)
                    else { return }
                    counts[fingerprint, default: 0] += 1
                }
                for records in routingState.records.values {
                    for record in records {
                        increment(record.sessionKey, counts: &persistedRecordCountByFingerprint)
                    }
                }
                for sessionMap in lastWindowByClientSession.values {
                    for sessionToken in sessionMap.keys {
                        increment(sessionToken, counts: &lastWindowEntryCountByFingerprint)
                    }
                }
                for sessionMap in liveRunAffinityByClientSession.values {
                    for sessionToken in sessionMap.keys {
                        increment(sessionToken, counts: &liveRunAffinityEntryCountByFingerprint)
                    }
                }
                return DebugExactRoutingSessionFixtureState(
                    persistedRecordCountByFingerprint: persistedRecordCountByFingerprint,
                    lastWindowEntryCountByFingerprint: lastWindowEntryCountByFingerprint,
                    liveRunAffinityEntryCountByFingerprint: liveRunAffinityEntryCountByFingerprint
                )
            }

            func debugRestoreExactRoutingSessionFixture(_ fixture: DebugExactRoutingSessionFixture) -> Bool {
                guard let restorePoint = debugExactRoutingSessionRestorePoints.removeValue(forKey: fixture.restoreID) else {
                    return false
                }
                routingState = restorePoint.routingState
                lastWindowByClientSession = restorePoint.lastWindowByClientSession
                liveRunAffinityByClientSession = restorePoint.liveRunAffinityByClientSession
                pendingConnections = restorePoint.pendingConnections
                activeConnectionsByClient = restorePoint.activeConnectionsByClient
                clientIDByConnection = restorePoint.clientIDByConnection
                capabilityTokenByConnection = restorePoint.capabilityTokenByConnection
                connectionIDBySessionToken = restorePoint.connectionIDBySessionToken
                saveRoutingState()
                return debugEncodedRoutingState(routingState) == debugEncodedRoutingState(restorePoint.routingState)
                    && lastWindowByClientSession == restorePoint.lastWindowByClientSession
                    && debugLiveRunAffinitiesEqual(liveRunAffinityByClientSession, restorePoint.liveRunAffinityByClientSession)
                    && pendingConnections == restorePoint.pendingConnections
                    && activeConnectionsByClient == restorePoint.activeConnectionsByClient
                    && clientIDByConnection == restorePoint.clientIDByConnection
                    && capabilityTokenByConnection == restorePoint.capabilityTokenByConnection
                    && connectionIDBySessionToken == restorePoint.connectionIDBySessionToken
            }

            private func debugRemoveExactRoutingSessionFixtureToken(_ sessionToken: String) {
                for clientID in Array(routingState.records.keys) {
                    guard let records = routingState.records[clientID] else { continue }
                    let retainedRecords = records.filter { $0.sessionKey != sessionToken }
                    if retainedRecords.isEmpty {
                        routingState.records.removeValue(forKey: clientID)
                    } else {
                        routingState.records[clientID] = retainedRecords
                    }
                }
                for clientID in Array(lastWindowByClientSession.keys) {
                    lastWindowByClientSession[clientID]?.removeValue(forKey: sessionToken)
                    if lastWindowByClientSession[clientID]?.isEmpty == true {
                        lastWindowByClientSession.removeValue(forKey: clientID)
                    }
                }
                for clientID in Array(liveRunAffinityByClientSession.keys) {
                    liveRunAffinityByClientSession[clientID]?.removeValue(forKey: sessionToken)
                    if liveRunAffinityByClientSession[clientID]?.isEmpty == true {
                        liveRunAffinityByClientSession.removeValue(forKey: clientID)
                    }
                }
                debugRemoveExactRoutingSessionFixtureTokenBindings(sessionToken)
            }

            private func debugRemoveExactRoutingSessionFixtureTokenBindings(_ sessionToken: String) {
                connectionIDBySessionToken.removeValue(forKey: sessionToken)
                for connectionID in capabilityTokenByConnection.compactMap({ connectionID, token in
                    token == sessionToken ? connectionID : nil
                }) {
                    capabilityTokenByConnection.removeValue(forKey: connectionID)
                }
            }

            private func debugRemoveExactRoutingSessionFixtureRuntimeResidue(for connectionID: UUID) {
                pendingConnections.removeValue(forKey: connectionID)
                clientIDByConnection.removeValue(forKey: connectionID)
                capabilityTokenByConnection.removeValue(forKey: connectionID)
                for sessionToken in connectionIDBySessionToken.compactMap({ sessionToken, mappedConnectionID in
                    mappedConnectionID == connectionID ? sessionToken : nil
                }) {
                    connectionIDBySessionToken.removeValue(forKey: sessionToken)
                }
                for clientID in Array(activeConnectionsByClient.keys) {
                    activeConnectionsByClient[clientID]?.remove(connectionID)
                    if activeConnectionsByClient[clientID]?.isEmpty == true {
                        activeConnectionsByClient.removeValue(forKey: clientID)
                    }
                }
            }

            private func debugEncodedRoutingState(_ state: MCPRoutingState) -> Data? {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                return try? encoder.encode(state)
            }

            private func debugLiveRunAffinitiesEqual(
                _ lhs: [String: [String: LiveRunAffinity]],
                _ rhs: [String: [String: LiveRunAffinity]]
            ) -> Bool {
                guard Set(lhs.keys) == Set(rhs.keys) else { return false }
                for clientID in lhs.keys {
                    guard let leftSessions = lhs[clientID], let rightSessions = rhs[clientID] else { return false }
                    guard Set(leftSessions.keys) == Set(rightSessions.keys) else { return false }
                    for sessionToken in leftSessions.keys {
                        guard let left = leftSessions[sessionToken], let right = rightSessions[sessionToken] else { return false }
                        guard left.windowID == right.windowID,
                              left.runID == right.runID,
                              left.purpose == right.purpose,
                              left.lastSeenAt == right.lastSeenAt
                        else { return false }
                    }
                }
                return true
            }

            func debugSeedRoutingAffinityPayload(connectionID: UUID, windowID: Int) async -> [String: Any] {
                let exists = await MainActor.run { WindowStatesManager.shared.hasWindow(id: windowID) }
                guard exists else {
                    return ["ok": false, "op": "seed_routing_affinity", "code": "invalid_params", "error": "No window found for window_id \(windowID)."]
                }
                guard connections[connectionID] != nil else {
                    return ["ok": false, "op": "seed_routing_affinity", "code": "invalid_params", "error": "connection_id is not an active connection."]
                }
                setConnectionWindowMapping(connectionID, windowID: windowID)
                let clientID = clientIdentifier(forConnection: connectionID)
                let sessionPresent = sessionToken(for: connectionID) != nil
                let didPersist = clientID != nil && sessionPresent
                if let clientID {
                    await updateRoutingRecordForConnection(connectionID, clientID: clientID)
                }
                return [
                    "ok": true,
                    "op": "seed_routing_affinity",
                    "connection_id": connectionID.uuidString,
                    "window_id": windowID,
                    "session_fingerprint": debugSessionFingerprint(forConnection: connectionID) ?? NSNull(),
                    "client_name": clientID ?? NSNull(),
                    "persisted": didPersist,
                    "persist_reason": didPersist ? "updated" : (sessionPresent ? "missing_client_id" : "missing_session_key")
                ]
            }

            private func debugSetRestartStatus(_ restartID: UUID, state: String, error: String? = nil) {
                debugRestartStatesByID[restartID] = DebugRestartStatus(
                    restartID: restartID,
                    state: state,
                    lastError: error,
                    updatedAt: Date()
                )
                if debugRestartStatesByID.count > debugRestartStatusLimit {
                    let oldest = debugRestartStatesByID.values.sorted { $0.updatedAt < $1.updatedAt }.prefix(debugRestartStatesByID.count - debugRestartStatusLimit).map(\.restartID)
                    for id in oldest {
                        debugRestartStatesByID.removeValue(forKey: id)
                    }
                }
            }

            func debugScheduleShutdownAndRestartPayload(restartID: UUID, delayMS: Int, downMS: Int, mode: String) -> [String: Any] {
                debugSetRestartStatus(restartID, state: "scheduled")
                debugRecordConnectionEvent("restart_scheduled", restartID: restartID, reason: mode)
                Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: .milliseconds(delayMS))
                    await debugSetRestartStatus(restartID, state: "stopping")
                    await debugRecordConnectionEvent("restart_stop_begin", restartID: restartID, reason: mode)
                    await stop()
                    await debugSetRestartStatus(restartID, state: "down")
                    await debugRecordConnectionEvent("restart_stop_end", restartID: restartID, reason: mode)
                    if downMS > 0 {
                        try? await Task.sleep(for: .milliseconds(downMS))
                    }
                    await debugSetRestartStatus(restartID, state: "starting")
                    await debugRecordConnectionEvent("restart_start_begin", restartID: restartID, reason: mode)
                    await start()
                    try? await Task.sleep(for: .milliseconds(100))
                    await ensureBootstrapHealthy(force: true)
                    await debugSetRestartStatus(restartID, state: "completed")
                    await debugRecordConnectionEvent("restart_start_end", restartID: restartID, reason: mode)
                }
                return [
                    "ok": true,
                    "op": "shutdown_and_restart",
                    "scheduled": true,
                    "restart_id": restartID.uuidString,
                    "mode": mode,
                    "delay_ms": delayMS,
                    "down_ms": downMS,
                    "socket_path": resolvedBootstrapSocketURL().path,
                    "scheduled_at_ms": debugDateMilliseconds(Date())
                ]
            }

            func debugRestartStatusPayload(restartID: UUID?) -> [String: Any] {
                let status: DebugRestartStatus? = if let restartID {
                    debugRestartStatesByID[restartID]
                } else {
                    debugRestartStatesByID.values.sorted { $0.updatedAt > $1.updatedAt }.first
                }
                return [
                    "ok": true,
                    "op": "restart_status",
                    "restart_id": status?.restartID.uuidString ?? restartID?.uuidString ?? NSNull(),
                    "state": status?.state ?? "none",
                    "last_error": status?.lastError ?? NSNull(),
                    "updated_at_ms": status.map { debugDateMilliseconds($0.updatedAt) } ?? NSNull()
                ]
            }
        #endif

        func debugClearPersistedRoutingState() {
            routingState.records.removeAll()
            lastWindowByClientSession.removeAll()
            saveRoutingState()
        }

        func debugClearPersistedRoutingState(for clientName: String) {
            for key in matchingClientKeys(for: clientName, in: Array(routingState.records.keys)) {
                routingState.records.removeValue(forKey: key)
            }
            for key in matchingClientKeys(for: clientName, in: Array(lastWindowByClientSession.keys)) {
                lastWindowByClientSession.removeValue(forKey: key)
            }
            for key in matchingClientKeys(for: clientName, in: Array(liveRunAffinityByClientSession.keys)) {
                liveRunAffinityByClientSession.removeValue(forKey: key)
            }
            saveRoutingState()
        }

        func debugRemoveConnection(_ id: UUID) async {
            #if DEBUG
                debugExecutionWatchdogAbortTargets.removeValue(forKey: id)
            #endif
            await removeConnection(
                id,
                context: MCPConnectionCloseContext(
                    reason: "debug_remove_connection",
                    initiator: .app
                )
            )
        }

        #if DEBUG
            func debugInstallConnectionLimiterForTesting(
                connectionID: UUID,
                idleWaitSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
                    try await Task.sleep(for: duration)
                }
            ) async -> AsyncLimiter {
                let limiters = MCPConnectionCallLimiters(
                    limit: limiterLimit(for: connectionID),
                    controlLimit: controlLimiterLimit(for: connectionID),
                    smallReadLimit: smallReadLimiterLimit(for: connectionID),
                    gitReadLimit: gitReadLimiterLimit(for: connectionID),
                    fileSearchLimit: fileSearchLimiterLimit(for: connectionID),
                    idleWaitSleep: idleWaitSleep
                )
                callLimiters[connectionID] = limiters
                return await limiters.limiterForTesting(.ordinary)
            }

            struct DebugDirectAdmissionState: Equatable {
                let pendingClientID: String?
                let indexedClientID: String?
                let activeClientIDs: [String]
                let hasStats: Bool
                let lifecycleGeneration: UInt64
                let connectionLifecycleGeneration: UInt64?
            }

            func debugInstallAdmissionEvictionCandidateForTesting(
                connectionID: UUID,
                connection: any MCPServerConnection,
                clientID: String,
                totalToolCalls: Int,
                createdAt: Date
            ) {
                if !isRunningState {
                    lifecycleGeneration &+= 1
                    isRunningState = true
                }
                connections[connectionID] = connection
                connectionLifecycleGenerationByID[connectionID] = lifecycleGeneration
                activeConnectionsByClient[clientID, default: []].insert(connectionID)
                clientIDByConnection[connectionID] = clientID
                callLimiters[connectionID] = MCPConnectionCallLimiters(
                    limit: limiterLimit(for: connectionID),
                    controlLimit: controlLimiterLimit(for: connectionID),
                    smallReadLimit: smallReadLimiterLimit(for: connectionID),
                    gitReadLimit: gitReadLimiterLimit(for: connectionID),
                    fileSearchLimit: fileSearchLimiterLimit(for: connectionID)
                )
                connectionStats[connectionID] = ConnectionStats(
                    createdAt: createdAt,
                    totalToolCalls: totalToolCalls,
                    lastToolCallAt: nil
                )
            }

            func debugInstallDirectAdmissionConnectionForTesting(
                connectionID: UUID,
                connection: any MCPServerConnection,
                pendingClientID: String? = nil,
                advanceLifecycleGeneration: Bool = false
            ) {
                if !isRunningState || advanceLifecycleGeneration {
                    lifecycleGeneration &+= 1
                }
                isRunningState = true
                connections[connectionID] = connection
                connectionLifecycleGenerationByID[connectionID] = lifecycleGeneration
                if let pendingClientID {
                    pendingConnections[connectionID] = pendingClientID
                } else {
                    pendingConnections.removeValue(forKey: connectionID)
                }
                if let indexedClientID = clientIDByConnection.removeValue(forKey: connectionID) {
                    var indexedConnections = activeConnectionsByClient[indexedClientID] ?? []
                    indexedConnections.remove(connectionID)
                    if indexedConnections.isEmpty {
                        activeConnectionsByClient.removeValue(forKey: indexedClientID)
                    } else {
                        activeConnectionsByClient[indexedClientID] = indexedConnections
                    }
                }
                connectionStats.removeValue(forKey: connectionID)
            }

            func debugDirectAdmissionStateForTesting(connectionID: UUID) -> DebugDirectAdmissionState {
                DebugDirectAdmissionState(
                    pendingClientID: pendingConnections[connectionID],
                    indexedClientID: clientIDByConnection[connectionID],
                    activeClientIDs: activeConnectionsByClient.compactMap { clientID, connectionIDs in
                        connectionIDs.contains(connectionID) ? clientID : nil
                    }.sorted(),
                    hasStats: connectionStats[connectionID] != nil,
                    lifecycleGeneration: lifecycleGeneration,
                    connectionLifecycleGeneration: connectionLifecycleGenerationByID[connectionID]
                )
            }

            func debugBindSessionTokenForAdmissionTesting(_ sessionToken: String, to connectionID: UUID) {
                bindSessionToken(sessionToken, to: connectionID)
            }

            func debugUnbindSessionTokenForAdmissionTesting(_ sessionToken: String, from connectionID: UUID) {
                unbindSessionToken(sessionToken, forConnectionID: connectionID)
            }

            func debugConnectionIDForSessionTokenForTesting(_ sessionToken: String) -> UUID? {
                connectionIDBySessionToken[sessionToken]
            }

            func debugSetAfterDirectAdmissionPendingPublishedForTesting(
                _ handler: (@Sendable (UUID) async -> Void)?
            ) {
                debugAfterDirectAdmissionPendingPublishedForTesting = handler
            }

            func debugSetAfterBootstrapPolicyReadinessForTesting(
                _ handler: (@Sendable (String) async -> Void)?
            ) {
                debugAfterBootstrapPolicyReadinessForTesting = handler
            }

            func debugSetAfterConnectionCallLimiterResolutionForTesting(
                _ handler: (@Sendable (UUID) async -> Void)?
            ) {
                debugAfterConnectionCallLimiterResolutionForTesting = handler
            }

            func debugSetAfterConnectionCallPermitAcquiredForTesting(
                _ handler: (@Sendable (UUID) async -> Void)?
            ) {
                debugAfterConnectionCallPermitAcquiredForTesting = handler
            }

            func debugSetAfterConnectionCallLimiterRejectionForTesting(
                _ handler: (@Sendable (UUID) async -> Void)?
            ) {
                debugAfterConnectionCallLimiterRejectionForTesting = handler
            }

            func debugSetBeforeAdmissionEvictionCloseForTesting(
                _ handler: (@Sendable (UUID) async -> Void)?
            ) {
                debugBeforeAdmissionEvictionCloseForTesting = handler
            }

            func debugSetDuringAdmissionEvictionCloseForTesting(
                _ handler: (@Sendable (UUID) async -> Void)?
            ) {
                debugDuringAdmissionEvictionCloseForTesting = handler
            }

            func debugSetAfterAdmissionEvictionRemovalCommittedForTesting(
                _ handler: (@Sendable (UUID) async -> Void)?
            ) {
                debugAfterAdmissionEvictionRemovalCommittedForTesting = handler
            }

            func debugSetBootstrapPredecessorStopGraceSleepForTesting(
                _ sleep: (@Sendable (Duration) async throws -> Void)?
            ) {
                debugBootstrapPredecessorStopGraceSleepForTesting = sleep
            }

            func debugEvictLeastValuableForTesting(clientID: String) async -> Bool {
                await evictLeastValuable(for: clientID) == .evicted
            }

            func debugEvictLeastValuableGlobalForAdmissionForTesting(
                preserveOnePerClient: Bool
            ) async -> Bool {
                await evictLeastValuableGlobalForAdmission(
                    preserveOnePerClient: preserveOnePerClient
                ) == .evicted
            }

            func debugConfigureGlobalAdmissionForTesting(
                maxGlobalConnections: Int?,
                preserveOnePerClient: Bool?
            ) {
                debugMaxGlobalConnectionsForTesting = maxGlobalConnections
                debugPreserveOnePerClientForTesting = preserveOnePerClient
            }

            func debugConfigurePerClientAdmissionForTesting(maxConnectionsPerClient: Int?) {
                debugMaxConnectionsPerClientForTesting = maxConnectionsPerClient
            }

            func debugConfigurePressureEvictionForTesting(idleSeconds: Int?) {
                debugPressureEvictIdleSecondsForTesting = idleSeconds
            }

            func debugPressureEvictIdleConnectionsForTesting() async {
                await pressureEvictIdleConnectionsIfNeeded()
            }

            func debugBootstrapAdmissionHasCapacityForTesting() async -> Bool {
                await ensureGlobalCapacityForBootstrapAdmission(
                    sourceListener: nil,
                    lifecycleGeneration: nil,
                    prospectiveReplacementCredit: nil
                ) == .available
            }

            func debugBootstrapAdmissionHasCapacityForTesting(sessionToken: String) async -> Bool {
                await debugAfterBootstrapPolicyReadinessForTesting?(sessionToken)
                if !isRunningState {
                    lifecycleGeneration &+= 1
                    isRunningState = true
                }
                let connectionID = UUID()
                guard claimBootstrapAdmission(
                    sessionToken: sessionToken,
                    connectionID: connectionID,
                    lifecycleGeneration: lifecycleGeneration
                ) else { return false }
                let replacementCredit = bootstrapAdmissionClaimsBySessionToken[sessionToken]?.replacementCredit
                let result = await ensureGlobalCapacityForBootstrapAdmission(
                    sourceListener: nil,
                    lifecycleGeneration: nil,
                    prospectiveReplacementCredit: replacementCredit
                ) == .available
                releaseBootstrapAdmissionClaim(
                    sessionToken: sessionToken,
                    connectionID: connectionID,
                    lifecycleGeneration: lifecycleGeneration
                )
                return result
            }

            func debugEffectiveRegisteredConnectionCountForTesting() -> Int {
                effectiveRegisteredConnectionCount
            }

            func debugEffectiveGlobalAdmissionLoadForTesting() -> Int {
                effectiveGlobalAdmissionLoad()
            }

            func debugGlobalAdmissionLoadComponentsForTesting() -> (
                registeredConnections: Int,
                reservations: Int,
                replacementCredits: Int,
                effectiveLoad: Int
            ) {
                let snapshot = globalAdmissionLoadSnapshot()
                return (
                    registeredConnections: snapshot.registeredConnectionCount,
                    reservations: snapshot.reservationCount,
                    replacementCredits: snapshot.replacementCreditCount,
                    effectiveLoad: snapshot.effectiveLoad
                )
            }

            func debugClaimBootstrapAdmissionForTesting(
                connectionID: UUID,
                sessionToken: String
            ) -> Bool {
                if !isRunningState {
                    lifecycleGeneration &+= 1
                    isRunningState = true
                }
                return claimBootstrapAdmission(
                    sessionToken: sessionToken,
                    connectionID: connectionID,
                    lifecycleGeneration: lifecycleGeneration
                )
            }

            func debugProtectedBootstrapPredecessorConnectionIDsForTesting() -> Set<UUID> {
                creditedBootstrapPredecessorConnectionIDs()
            }

            func debugReserveBootstrapSlotForTesting(
                connectionID: UUID,
                sessionToken: String
            ) -> Bool {
                if !isRunningState {
                    lifecycleGeneration &+= 1
                    isRunningState = true
                }
                guard claimBootstrapAdmission(
                    sessionToken: sessionToken,
                    connectionID: connectionID,
                    lifecycleGeneration: lifecycleGeneration
                ) else { return false }
                guard reserveBootstrapSlot(
                    connectionID: connectionID,
                    lifecycleGeneration: lifecycleGeneration,
                    sessionToken: sessionToken
                ) else {
                    releaseBootstrapAdmissionClaim(
                        sessionToken: sessionToken,
                        connectionID: connectionID,
                        lifecycleGeneration: lifecycleGeneration
                    )
                    return false
                }
                return true
            }

            func debugReleaseBootstrapAdmissionClaimForTesting(
                connectionID: UUID,
                sessionToken: String
            ) {
                releaseBootstrapAdmissionClaim(
                    sessionToken: sessionToken,
                    connectionID: connectionID,
                    lifecycleGeneration: lifecycleGeneration
                )
            }

            func debugRollbackBootstrapReservationForTesting(connectionID: UUID) async {
                await rollbackBootstrapReservation(
                    connectionID: connectionID,
                    lifecycleGeneration: lifecycleGeneration,
                    reason: "DEBUG test rollback"
                )
            }

            func debugCommitBootstrapReservationAccountingForTesting(connectionID: UUID) async -> Bool {
                guard let reservation = bootstrapReservations[connectionID],
                      Date().timeIntervalSince(reservation.createdAt) < bootstrapReservationTTL
                else {
                    await abandonPendingBootstrapCommit(
                        connectionID: connectionID,
                        lifecycleGeneration: lifecycleGeneration,
                        reason: "DEBUG expired commit"
                    )
                    return false
                }
                return takeBootstrapReservation(
                    connectionID: connectionID,
                    lifecycleGeneration: lifecycleGeneration
                ) != nil
            }

            func debugAgeBootstrapReservationPastExpiryForTesting(connectionID: UUID) {
                guard var reservation = bootstrapReservations[connectionID] else { return }
                reservation.createdAt = Date(
                    timeIntervalSinceNow: -(bootstrapReservationTTL + 1)
                )
                bootstrapReservations[connectionID] = reservation
            }

            func debugExpireBootstrapReservationForTesting(connectionID: UUID) {
                debugAgeBootstrapReservationPastExpiryForTesting(connectionID: connectionID)
                cleanupExpiredBootstrapReservations()
            }

            func debugRegisterConnectionForSocketFixture(
                connectionID: UUID,
                connection: any MCPServerConnection,
                clientName: String,
                sessionToken: String
            ) {
                if !isRunningState {
                    lifecycleGeneration &+= 1
                    isRunningState = true
                }
                debugExecutionWatchdogAbortTargets[connectionID] = connection
                connections[connectionID] = connection
                connectionLifecycleGenerationByID[connectionID] = lifecycleGeneration
                pendingConnections[connectionID] = clientName
                bindSessionToken(sessionToken, to: connectionID)
                if callLimiters[connectionID] == nil {
                    callLimiters[connectionID] = MCPConnectionCallLimiters(
                        limit: limiterLimit(for: connectionID),
                        controlLimit: controlLimiterLimit(for: connectionID),
                        smallReadLimit: smallReadLimiterLimit(for: connectionID),
                        gitReadLimit: gitReadLimiterLimit(for: connectionID),
                        fileSearchLimit: fileSearchLimiterLimit(for: connectionID)
                    )
                }
            }

            func debugSetToolExecutionWatchdogEnvironment(_ environment: MCPToolExecutionWatchdogEnvironment) {
                toolExecutionWatchdogEnvironment = environment
            }

            func debugResetToolExecutionWatchdogEnvironment() {
                toolExecutionWatchdogEnvironment = .continuous()
            }

            func debugSetResolvedToolOperationOverride(
                toolName: String,
                operation: (@Sendable () async throws -> Value)?
            ) {
                if let operation {
                    debugResolvedToolOperationOverrides[toolName] = operation
                } else {
                    debugResolvedToolOperationOverrides.removeValue(forKey: toolName)
                }
            }

            func debugSetBeforeToolResultFormattingForTesting(
                _ handler: (@Sendable (UUID, String) async -> Void)?
            ) {
                debugBeforeToolResultFormattingForTesting = handler
            }

            func debugSetBeforeToolCompletionObserversForTesting(
                _ handler: (@Sendable (UUID, String) async -> Void)?
            ) {
                debugBeforeToolCompletionObserversForTesting = handler
            }

            func debugIsExecutionWatchdogTerminal(connectionID: UUID) -> Bool {
                executionWatchdogTerminalConnections.contains(connectionID)
            }
        #endif

        struct DebugActiveToolScopeSnapshot: Equatable {
            let scopeID: UUID
            let windowID: Int
            let connectionID: UUID
            let toolName: String
            let sequence: UInt64
        }

        func debugBeginActiveToolScopeForTesting(
            windowID: Int,
            connectionID: UUID,
            toolName: String,
            scopeID: UUID
        ) -> UUID? {
            beginActiveToolScope(
                windowID: windowID,
                connectionID: connectionID,
                toolName: toolName,
                scopeID: scopeID
            )?.scopeID
        }

        func debugEndActiveToolScopeForTesting(windowID: Int, scopeID: UUID) -> Bool {
            endActiveToolScope(ActiveToolScopeHandle(windowID: windowID, scopeID: scopeID))
        }

        func debugActiveToolScopesForTesting() -> [DebugActiveToolScopeSnapshot] {
            activeToolScopesByWindow.flatMap { windowID, scopes in
                scopes.map { scopeID, scope in
                    DebugActiveToolScopeSnapshot(
                        scopeID: scopeID,
                        windowID: windowID,
                        connectionID: scope.connectionID,
                        toolName: scope.toolName,
                        sequence: scope.sequence
                    )
                }
            }
            .sorted { lhs, rhs in
                if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
                return lhs.scopeID.uuidString < rhs.scopeID.uuidString
            }
        }

        func debugSetBeforeActiveToolCancellationScanForTesting(
            _ handler: (@Sendable (UUID, [UUID]) async -> Void)?
        ) {
            debugBeforeActiveToolCancellationScanForTesting = handler
        }

        func debugSetConnectionWindowForTesting(connectionID: UUID, windowID: Int?) {
            if let windowID {
                connectionWindowMap[connectionID] = windowID
                windowAssignmentByConnection[connectionID] = windowID
            } else {
                connectionWindowMap.removeValue(forKey: connectionID)
                windowAssignmentByConnection.removeValue(forKey: connectionID)
            }
        }

        func debugCancelActiveToolsOwnedByConnection(
            _ connectionID: UUID,
            assignedWindowID: Int? = nil,
            reason: String = "test"
        ) async -> Int {
            _ = assignedWindowID
            return await cancelActiveToolsOwnedByConnection(
                connectionID,
                reason: reason
            )
        }

        func debugSetAdditionalTools(for connectionID: UUID, additionalTools: Set<String>?) async {
            if let additionalTools {
                additionalToolsByConnection[connectionID] = additionalTools
            } else {
                additionalToolsByConnection.removeValue(forKey: connectionID)
            }
            if connections[connectionID] != nil {
                await notifyToolListChanged(connectionID: connectionID)
            }
        }

        func debugListToolNames(
            for connectionID: UUID,
            hydratePersistedPolicy: Bool = true
        ) async throws -> [String] {
            let windowID = await ensureWindowBindingIfUnambiguous(connectionID: connectionID, reason: "debug/tools/list")
            let isReady = await MCPToolCatalogReadiness.shared.awaitReady(
                windowID: windowID,
                timeout: 5.0
            )
            if !isReady, windowID != nil {
                throw MCPError.internalError("Tool catalog not ready. Please retry.")
            }
            if let windowID {
                await MCPToolCatalogReadiness.shared.warmToolCache(windowID: windowID)
            }

            if hydratePersistedPolicy {
                _ = await hydratePersistedAgentModePolicyForConnectionIfNeeded(
                    connectionID: connectionID,
                    reason: "debug/tools/list"
                )
            }

            let (disabled, registeredServices) = await MainActor.run {
                (
                    ToolAvailabilityStore.shared.effectiveDisabledTools,
                    ServiceRegistry.services
                )
            }
            let policy = effectivePolicyState(for: connectionID)
            let restricted = policy.restricted
            let additionalTools = policy.additional
            var seenNames = Set<String>()
            var names: [String] = []

            if isEnabledState {
                for service in registeredServices {
                    for tool in await service.tools {
                        guard !disabled.contains(tool.name) else { continue }
                        guard !restricted.contains(tool.name) else { continue }

                        if MCPPolicyGatedTools.names.contains(tool.name),
                           !additionalTools.contains(tool.name)
                        {
                            continue
                        }

                        if !AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                            toolName: tool.name,
                            taskLabelKind: policy.taskLabelKind,
                            allowsAgentExternalControlTools: policy.allowsAgentExternalControlTools
                        ) { continue }

                        guard seenNames.insert(tool.name).inserted else { continue }
                        names.append(tool.name)
                    }
                }
            }

            return names.sorted()
        }

        func debugSetBeforeToolEventObserverDeliveryForTesting(
            _ handler: (@Sendable () async -> Void)?
        ) {
            debugBeforeToolEventObserverDeliveryForTesting = handler
        }

        @discardableResult
        func debugFireToolCalledObservers(
            runID: UUID,
            invocationID: UUID,
            toolName: String,
            args: [String: Value]? = nil
        ) async -> Int {
            await fireToolCalledObservers(
                runID: runID,
                invocationID: invocationID,
                toolName: toolName,
                args: args
            )
        }

        @discardableResult
        func debugFireToolCompletedObservers(
            runID: UUID,
            invocationID: UUID,
            toolName: String,
            args: [String: Value]? = nil,
            resultJSON: String,
            isError: Bool
        ) async -> Int {
            await fireToolCompletedObservers(
                runID: runID,
                invocationID: invocationID,
                toolName: toolName,
                args: args,
                resultJSON: resultJSON,
                isError: isError
            )
        }

        func debugClearActiveToolOwner(windowID: Int) {
            removeActiveToolScopesForWindow(windowID)
        }
    #endif

    func clearClientConnectionPolicy(
        for clientName: String,
        windowID: Int? = nil,
        runID: UUID? = nil
    ) async {
        pruneExpiredPolicies(for: clientName)
        let keys = matchingClientKeys(for: clientName, in: Array(pendingPoliciesByClient.keys))
        guard !keys.isEmpty else {
            #if DEBUG
                if let runID {
                    debugRecordRunRoutingEvent(
                        runID: runID,
                        event: "policy_cleared",
                        fields: [
                            "client_name": clientName,
                            "removed_count": "0",
                            "remaining_count": "0",
                            "reason": "no_matching_policy"
                        ]
                    )
                }
            #endif
            return
        }
        var removedCount = 0
        var remainingCount = 0
        for key in keys {
            guard var queue = pendingPoliciesByClient[key] else { continue }
            let beforeCount = queue.count
            if let targetRunID = runID, let targetWindow = windowID {
                queue.removeAll { $0.windowID == targetWindow && $0.runID == targetRunID }
            } else if let targetRunID = runID {
                queue.removeAll { $0.runID == targetRunID }
            } else if let targetWindow = windowID {
                queue.removeAll { $0.windowID == targetWindow }
            } else {
                queue.removeAll()
            }
            removedCount += beforeCount - queue.count
            remainingCount += queue.count
            if queue.isEmpty {
                pendingPoliciesByClient.removeValue(forKey: key)
            } else {
                pendingPoliciesByClient[key] = queue
            }
        }
        mcpPolicyLog(
            "cleared policy client=\(clientName) window=\(windowID.map(String.init) ?? "all") runID=\(runID?.uuidString ?? "all") removed=\(removedCount) remaining=\(remainingCount)"
        )
        #if DEBUG
            if let runID {
                debugRecordRunRoutingEvent(
                    runID: runID,
                    event: "policy_cleared",
                    fields: [
                        "client_name": clientName,
                        "window_id": windowID.map(String.init) ?? "all",
                        "removed_count": String(removedCount),
                        "remaining_count": String(remainingCount)
                    ]
                )
            }
        #endif
    }

    func setRestrictedTools(for connectionID: UUID, tools: Set<String>) async {
        let sanitized = Self.sanitizedRoutingRestrictedTools(tools)
        restrictedToolsByConnection[connectionID] = sanitized
        if connections[connectionID] != nil {
            await notifyToolListChanged(connectionID: connectionID)
        }
    }

    func addRestrictedTools(for connectionID: UUID, names: [String]) async {
        let sanitized = Self.sanitizedRoutingRestrictedTools(Set(names))
        guard !sanitized.isEmpty else { return }
        var existing = restrictedToolsByConnection[connectionID] ?? []
        existing.formUnion(sanitized)
        restrictedToolsByConnection[connectionID] = existing
        if connections[connectionID] != nil {
            await notifyToolListChanged(connectionID: connectionID)
        }
    }

    func clearRestrictedTools(for connectionID: UUID) async {
        if restrictedToolsByConnection.removeValue(forKey: connectionID) != nil,
           connections[connectionID] != nil
        {
            await notifyToolListChanged(connectionID: connectionID)
        }
    }

    func notifyToolListChanged(connectionID: UUID) async {
        if let mgr = connections[connectionID] {
            await mgr.notifyToolListChanged()
        }
    }

    /// Sends a progress notification to a specific connection.
    /// Used during long-running tool calls to prevent agent timeouts.
    func sendProgress(
        for connectionID: UUID,
        tool: String,
        kind: RepoPromptProgressKind,
        stage: String,
        message: String
    ) async {
        guard supportsControlNotifications(connectionID: connectionID) else { return }
        #if DEBUG
            let clientName = clientIdentifier(forConnection: connectionID) ?? "unknown"
            connectionLog("progress client=\(clientName) connection=\(connectionID) tool=\(tool) kind=\(kind.rawValue) stage=\(stage) message=\(message)")
        #endif
        if let mgr = connections[connectionID] {
            await mgr.sendProgress(tool: tool, kind: kind, stage: stage, message: message)
        }
    }

    /// RepoPrompt control notifications are only supported by the bundled CLI.
    func supportsControlNotifications(connectionID: UUID) -> Bool {
        guard let clientName = clientIdentifier(forConnection: connectionID) else { return false }
        return clientName.hasPrefix(Self.repoCLIPrefix)
    }

    private func pruneExpiredPolicies(for clientName: String) {
        let keys = matchingClientKeys(for: clientName, in: Array(pendingPoliciesByClient.keys))
        let now = Date()
        for key in keys {
            guard var queue = pendingPoliciesByClient[key], !queue.isEmpty else { continue }
            queue.removeAll { now.timeIntervalSince($0.createdAt) > $0.ttl }
            if queue.isEmpty {
                pendingPoliciesByClient.removeValue(forKey: key)
            } else {
                pendingPoliciesByClient[key] = queue
            }
        }
    }

    @discardableResult
    private func hydratePersistedAgentModePolicyForConnectionIfNeeded(
        connectionID: UUID,
        reason: String
    ) async -> Bool {
        let existingRestricted = restrictedToolsByConnection[connectionID] ?? []
        let existingAdditional = additionalToolsByConnection[connectionID] ?? []
        let existingPurpose = runPurposeByConnection[connectionID] ?? .unknown
        if !existingRestricted.isEmpty || !existingAdditional.isEmpty || existingPurpose != .unknown {
            return false
        }

        guard let clientName = clientIdentifier(forConnection: connectionID) else { return false }
        let sessionKey = connections[connectionID]?.capabilityToken ?? capabilityTokenByConnection[connectionID]
        if let liveAffinity = preferredLiveRunAffinity(for: clientName, sessionKey: sessionKey) {
            guard shouldAllowPersistedAgentModeRestore(clientName: clientName, purpose: liveAffinity.purpose) else {
                return false
            }
            setConnectionWindowMapping(connectionID, windowID: liveAffinity.windowID)
            let restored = await mapConnectionToRunID(
                connectionID,
                runID: liveAffinity.runID,
                windowID: liveAffinity.windowID
            )
            if restored {
                await updateRoutingRecordForConnection(connectionID, clientID: clientName)
                await notifyToolListChanged(connectionID: connectionID)
                mcpPolicyLog(
                    "hydrated live run affinity reason=\(reason) client=\(clientName) connection=\(connectionID) window=\(liveAffinity.windowID) runID=\(liveAffinity.runID.uuidString)"
                )
            }
            return restored
        }

        if let preferredWindowID = await preferredWindowID(for: clientName, sessionKey: sessionKey) {
            setConnectionWindowMapping(connectionID, windowID: preferredWindowID)
            await updateRoutingRecordForConnection(connectionID, clientID: clientName)
        }
        return false
    }

    private func applyLiveRunAffinity(
        _ liveAffinity: LiveRunAffinity,
        clientName: String,
        connectionID: UUID,
        reason: String
    ) async {
        connectionLog("Applying live run affinity (\(reason)): client \(clientName) → window \(liveAffinity.windowID) runID=\(liveAffinity.runID)")
        setConnectionWindowMapping(connectionID, windowID: liveAffinity.windowID)
        let mapped = await mapConnectionToRunID(
            connectionID,
            runID: liveAffinity.runID,
            windowID: liveAffinity.windowID
        )
        if !mapped {
            await applyRunPolicyStateIfAvailable(runID: liveAffinity.runID, connectionID: connectionID)
        }
        await updateRoutingRecordForConnection(connectionID, clientID: clientName)
        await notifyToolListChanged(connectionID: connectionID)
    }

    private func applyRoutingFallback(
        clientName: String,
        connectionID: UUID,
        clientPid: Int? = nil,
        pendingPolicyWasReserved: Bool = false
    ) async {
        if pendingPolicyWasReserved {
            mcpPolicyLog("pending policy reserved for different pid client=\(clientName) connection=\(connectionID)")
        } else {
            mcpRoutingLog("No pending policy for client=\(clientName) connectionID=\(connectionID)")
            mcpPolicyLog("no pending policy client=\(clientName) connection=\(connectionID)")
        }

        let sessionKey = connections[connectionID]?.capabilityToken ?? capabilityTokenByConnection[connectionID]
        if let liveAffinity = preferredLiveRunAffinity(for: clientName, sessionKey: sessionKey) {
            await applyLiveRunAffinity(liveAffinity, clientName: clientName, connectionID: connectionID, reason: "session-token")
            return
        }

        if let liveAffinity = preferredExpectedPIDRunAffinity(for: clientName, clientPid: clientPid) {
            await applyLiveRunAffinity(liveAffinity, clientName: clientName, connectionID: connectionID, reason: "expected-pid")
            return
        }

        if let preferredWindowID = await preferredWindowID(for: clientName, sessionKey: sessionKey) {
            connectionLog("Applying persisted routing affinity: client \(clientName) → window \(preferredWindowID)")
            setConnectionWindowMapping(connectionID, windowID: preferredWindowID)
            await updateRoutingRecordForConnection(connectionID, clientID: clientName)
            await notifyToolListChanged(connectionID: connectionID)
        }
    }

    private func canConsumePendingPolicy(
        _ policy: ClientConnectionPolicy,
        clientName: String,
        clientPid: Int?
    ) -> Bool {
        guard policy.requiresExpectedAgentPID else { return true }
        guard let clientPid else { return false }
        return isExpectedAgentDescendant(clientName: clientName, clientPid: clientPid, runID: policy.runID) == true
    }

    private func oldestReservedPendingPolicyEntry(
        for clientName: String
    ) -> (key: String, index: Int, policy: ClientConnectionPolicy)? {
        oldestPendingPolicyEntry(for: clientName) { $0.reservationConnectionID != nil }
    }

    private func reserveOneShotPendingPolicy(
        _ matchedQueueEntry: (key: String, index: Int, policy: ClientConnectionPolicy),
        for connectionID: UUID
    ) -> ClientConnectionPolicy? {
        guard matchedQueueEntry.policy.oneShot,
              var queue = pendingPoliciesByClient[matchedQueueEntry.key],
              queue.indices.contains(matchedQueueEntry.index),
              queue[matchedQueueEntry.index].id == matchedQueueEntry.policy.id,
              queue[matchedQueueEntry.index].reservationConnectionID == nil
        else {
            return nil
        }
        queue[matchedQueueEntry.index].reservationConnectionID = connectionID
        let policy = queue[matchedQueueEntry.index]
        pendingPoliciesByClient[matchedQueueEntry.key] = queue
        return policy
    }

    private func consumeOneShotPendingPolicy(
        id: UUID,
        key: String,
        connectionID: UUID
    ) -> Bool {
        guard var queue = pendingPoliciesByClient[key],
              let index = queue.firstIndex(where: {
                  $0.id == id && $0.reservationConnectionID == connectionID
              })
        else {
            return false
        }
        queue.remove(at: index)
        if queue.isEmpty {
            pendingPoliciesByClient.removeValue(forKey: key)
        } else {
            pendingPoliciesByClient[key] = queue
        }
        return true
    }

    private func rollbackOneShotPendingPolicyReservation(
        id: UUID,
        key: String,
        connectionID: UUID
    ) -> Bool {
        guard var queue = pendingPoliciesByClient[key],
              let index = queue.firstIndex(where: {
                  $0.id == id && $0.reservationConnectionID == connectionID
              })
        else {
            return false
        }
        queue[index].reservationConnectionID = nil
        pendingPoliciesByClient[key] = queue
        return true
    }

    private func logReservedPendingPolicy(
        _ policy: ClientConnectionPolicy,
        clientName: String,
        connectionID: UUID,
        clientPid: Int?,
        bootstrapClientName: String?
    ) {
        mcpPolicyLog(
            "reserved pid-gated policy client=\(clientName) bootstrapClient=\(bootstrapClientName ?? "nil") connection=\(connectionID) clientPid=\(clientPid.map(String.init) ?? "nil") runID=\(policy.runID?.uuidString ?? "nil")"
        )
    }

    private func applyPendingPolicyIfAvailable(
        clientName: String,
        connectionID: UUID,
        clientPid: Int? = nil,
        bootstrapClientName: String? = nil,
        pidGateTimeout: TimeInterval = 2.0,
        requireRunRouting: Bool = true,
        expectedLifecycleGeneration: UInt64? = nil
    ) async -> PendingPolicyApplicationOutcome {
        if let reservedEntry = oldestReservedPendingPolicyEntry(for: clientName),
           canConsumePendingPolicy(reservedEntry.policy, clientName: clientName, clientPid: clientPid)
        {
            mcpPolicyLog(
                "pending policy route installation already reserved client=\(clientName) connection=\(connectionID) reservedConnection=\(reservedEntry.policy.reservationConnectionID?.uuidString ?? "nil") runID=\(reservedEntry.policy.runID?.uuidString ?? "nil")"
            )
            return .rejected(runID: reservedEntry.policy.runID, reason: "policy_reserved")
        }

        if let reservedEntry = oldestPendingPolicyEntry(for: clientName, where: {
            $0.reservationConnectionID == nil && $0.requiresExpectedAgentPID
        }),
            oldestPIDGatedPendingPolicyEntry(for: clientName, matching: clientPid ?? -1) == nil
        {
            let runID = reservedEntry.policy.runID
            let ancestorDescription = clientPid.map { pidAncestorChainDescription(from: pid_t($0)) } ?? "nil"
            let expectedDescription = expectedAgentPIDs(for: clientName, runID: runID)
                .map(String.init)
                .sorted()
                .joined(separator: ",")
            mcpPolicyLog(
                "holding pid-gated policy consumption client=\(clientName) bootstrapClient=\(bootstrapClientName ?? "nil") connection=\(connectionID) clientPid=\(clientPid.map(String.init) ?? "nil") ancestorChain=[\(ancestorDescription)] expectedAgentPIDs=[\(expectedDescription)] runID=\(runID?.uuidString ?? "nil") timeout=\(pidGateTimeout)s"
            )
            #if DEBUG
                if let runID {
                    debugRecordRunRoutingEvent(
                        runID: runID,
                        event: "pid_gate_wait_started",
                        connectionID: connectionID,
                        fields: [
                            "client_name": clientName,
                            "bootstrap_client_name": bootstrapClientName ?? "nil",
                            "helper_peer_pid": clientPid.map(String.init) ?? "nil",
                            "ancestor_chain": ancestorDescription,
                            "expected_pids": expectedDescription,
                            "pending_policy_key": reservedEntry.key,
                            "timeout_ms": String(Int((pidGateTimeout * 1000).rounded()))
                        ]
                    )
                }
            #endif

            let deadline = Date().addingTimeInterval(pidGateTimeout)
            while oldestPIDGatedPendingPolicyEntry(for: clientName, matching: clientPid ?? -1) == nil {
                if Task.isCancelled {
                    #if DEBUG
                        if let runID {
                            debugRecordRunRoutingEvent(
                                runID: runID,
                                event: "pid_gate_wait_rejected",
                                connectionID: connectionID,
                                fields: ["reason": "cancelled"]
                            )
                        }
                    #endif
                    return .rejected(runID: runID, reason: "cancelled")
                }
                guard hasPIDGatedPendingPolicy(for: clientName) else {
                    #if DEBUG
                        if let runID {
                            debugRecordRunRoutingEvent(
                                runID: runID,
                                event: "pid_gate_wait_rejected",
                                connectionID: connectionID,
                                fields: ["reason": "policy_removed"]
                            )
                        }
                    #endif
                    return .rejected(runID: runID, reason: "policy_removed")
                }
                guard Date() < deadline else {
                    logReservedPendingPolicy(
                        reservedEntry.policy,
                        clientName: clientName,
                        connectionID: connectionID,
                        clientPid: clientPid,
                        bootstrapClientName: bootstrapClientName
                    )
                    #if DEBUG
                        if let runID {
                            debugRecordRunRoutingEvent(
                                runID: runID,
                                event: "pid_gate_wait_rejected",
                                connectionID: connectionID,
                                fields: [
                                    "reason": "ownership_timeout",
                                    "helper_peer_pid": clientPid.map(String.init) ?? "nil",
                                    "ancestor_chain": ancestorDescription,
                                    "expected_pids": expectedAgentPIDs(for: clientName, runID: runID)
                                        .map(String.init)
                                        .sorted()
                                        .joined(separator: ",")
                                ]
                            )
                        }
                    #endif
                    return .rejected(runID: runID, reason: "ownership_timeout")
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            #if DEBUG
                if let matchedEntry = oldestPIDGatedPendingPolicyEntry(for: clientName, matching: clientPid ?? -1),
                   let matchedRunID = matchedEntry.policy.runID
                {
                    debugRecordRunRoutingEvent(
                        runID: matchedRunID,
                        event: "pid_gate_wait_completed",
                        connectionID: connectionID,
                        fields: [
                            "helper_peer_pid": clientPid.map(String.init) ?? "nil",
                            "expected_pids": expectedAgentPIDs(for: clientName, runID: matchedRunID)
                                .map(String.init)
                                .sorted()
                                .joined(separator: ","),
                            "pending_policy_key": matchedEntry.key
                        ]
                    )
                }
            #endif
        }

        let hasPIDGatedPolicy = hasPIDGatedPendingPolicy(for: clientName)
        let matchedQueueEntry = if hasPIDGatedPolicy {
            oldestPIDGatedPendingPolicyEntry(for: clientName, matching: clientPid ?? -1)
        } else {
            oldestPendingPolicyEntry(for: clientName) { policy in
                policy.reservationConnectionID == nil
                    && canConsumePendingPolicy(policy, clientName: clientName, clientPid: clientPid)
            }
        }
        guard let matchedQueueEntry else {
            #if DEBUG
                debugPolicyDiagnostic("pendingPolicyMiss", connectionID: connectionID, extra: [
                    "clientName": clientName,
                    "clientPid": clientPid.map(String.init) ?? "nil",
                    "bootstrapClientName": bootstrapClientName ?? "nil",
                    "reason": oldestPendingPolicyEntry(for: clientName) == nil ? "no_pending_policy" : "pending_policy_not_consumable"
                ])
            #endif
            if let reservedEntry = oldestReservedPendingPolicyEntry(for: clientName) {
                return .rejected(runID: reservedEntry.policy.runID, reason: "policy_reserved")
            }
            if let reservedEntry = oldestPendingPolicyEntry(for: clientName) {
                logReservedPendingPolicy(
                    reservedEntry.policy,
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: clientPid,
                    bootstrapClientName: bootstrapClientName
                )
                return .rejected(runID: reservedEntry.policy.runID, reason: "not_consumable")
            }
            await applyRoutingFallback(clientName: clientName, connectionID: connectionID, clientPid: clientPid)
            return .fallback
        }
        let sessionKey = connections[connectionID]?.capabilityToken ?? capabilityTokenByConnection[connectionID]
        let liveAffinity = preferredLiveRunAffinity(for: clientName, sessionKey: sessionKey)
        var queue = pendingPoliciesByClient[matchedQueueEntry.key] ?? []
        mcpRoutingLog("Applying FIFO policy client=\(clientName) matchedKey=\(matchedQueueEntry.key) connectionID=\(connectionID) queueLength=\(queue.count) policyWindow=\(matchedQueueEntry.policy.windowID)")
        let policy: ClientConnectionPolicy
        let remainingAfterPop: Int
        let remainingAfterRequeue: Int
        if matchedQueueEntry.policy.oneShot {
            guard let reservedPolicy = reserveOneShotPendingPolicy(matchedQueueEntry, for: connectionID) else {
                return .rejected(runID: matchedQueueEntry.policy.runID, reason: "policy_reservation_failed")
            }
            policy = reservedPolicy
            remainingAfterPop = max(0, queue.count - 1)
            remainingAfterRequeue = remainingAfterPop
        } else {
            policy = queue.remove(at: matchedQueueEntry.index)
            remainingAfterPop = queue.count
            queue.append(policy)
            remainingAfterRequeue = queue.count
            pendingPoliciesByClient[matchedQueueEntry.key] = queue
        }

        if let policyRunID = policy.runID,
           let boundRunID = await runIDForConnection(connectionID),
           boundRunID != policyRunID
        {
            if policy.oneShot {
                _ = rollbackOneShotPendingPolicyReservation(
                    id: policy.id,
                    key: matchedQueueEntry.key,
                    connectionID: connectionID
                )
            }
            #if DEBUG
                debugRecordRunRoutingEvent(
                    runID: policyRunID,
                    event: "policy_rejected",
                    connectionID: connectionID,
                    fields: [
                        "client_name": clientName,
                        "reason": "connection_bound_to_other_run",
                        "bound_run_id": boundRunID.uuidString
                    ]
                )
            #endif
            return .rejected(runID: policyRunID, reason: "connection_bound_to_other_run")
        }

        if let policyRunID = policy.runID,
           let liveAffinity,
           liveAffinity.runID != policyRunID
        {
            if policy.oneShot {
                _ = rollbackOneShotPendingPolicyReservation(
                    id: policy.id,
                    key: matchedQueueEntry.key,
                    connectionID: connectionID
                )
            }
            #if DEBUG
                debugRecordRunRoutingEvent(
                    runID: policyRunID,
                    event: "policy_rejected",
                    connectionID: connectionID,
                    fields: [
                        "client_name": clientName,
                        "reason": "session_token_bound_to_other_run",
                        "bound_run_id": liveAffinity.runID.uuidString
                    ]
                )
            #endif
            return .rejected(runID: policyRunID, reason: "session_token_bound_to_other_run")
        }

        let restorePoint = PendingPolicyRestorePoint(
            restrictedTools: restrictedToolsByConnection[connectionID],
            additionalTools: additionalToolsByConnection[connectionID],
            runPurpose: runPurposeByConnection[connectionID],
            windowID: connectionWindowMap[connectionID],
            windowAssignment: windowAssignmentByConnection[connectionID],
            runID: runIDByConnectionID[connectionID],
            wasPreassigned: preassignedConnections.contains(connectionID),
            wasRunAdmitted: policy.runID.map { admittedPolicyRunIDs.contains($0) } ?? false,
            runPolicyState: policy.runID.flatMap { runPolicyStateByRunID[$0] },
            runWindowID: policy.runID.flatMap { windowIDByRunID[$0] }
        )
        let pendingPolicyApplicationID = UUID()
        pendingPolicyApplicationIDByConnectionID[connectionID] = pendingPolicyApplicationID
        if let runID = policy.runID {
            pendingPolicyApplicationIDByRunID[runID] = pendingPolicyApplicationID
        }

        // Stage the complete policy before registering the run mapping. The mapping
        // signals MCPRoutingWaiter, so restrictions and run identity must already be
        // visible before the bootstrap gate can be released.
        restrictedToolsByConnection[connectionID] = policy.restrictedTools
        preassignedConnections.insert(connectionID)
        runPurposeByConnection[connectionID] = policy.purpose
        cacheRunPolicyStateIfNeeded(policy)
        if let runID = policy.runID {
            admittedPolicyRunIDs.insert(runID)
            runIDByConnectionID[connectionID] = runID
        }
        if let additional = policy.additionalTools {
            additionalToolsByConnection[connectionID] = additional
        } else {
            additionalToolsByConnection.removeValue(forKey: connectionID)
        }
        connectionWindowMap[connectionID] = policy.windowID
        windowAssignmentByConnection[connectionID] = policy.windowID

        #if DEBUG
            await debugSuspendPendingPolicyRouteInstallationIfNeeded()
        #endif

        guard isPendingPolicyApplicationOwner(
            pendingPolicyApplicationID,
            connectionID: connectionID,
            runID: policy.runID
        ),
            isPendingPolicyApplicationCurrent(
                connectionID: connectionID,
                clientName: clientName,
                expectedLifecycleGeneration: expectedLifecycleGeneration
            )
        else {
            if policy.oneShot {
                _ = rollbackOneShotPendingPolicyReservation(
                    id: policy.id,
                    key: matchedQueueEntry.key,
                    connectionID: connectionID
                )
            }
            await rollbackPendingPolicyApplication(
                policy,
                clientName: clientName,
                connectionID: connectionID,
                restorePoint: restorePoint,
                applicationID: pendingPolicyApplicationID,
                signalRoutingFailure: false
            )
            return .rejected(runID: policy.runID, reason: "stale_connection")
        }

        var pendingPolicyRunIDMappingToken: MCPServerViewModel.PendingPolicyRunIDMappingToken?
        if requireRunRouting, let runID = policy.runID {
            let routed: Bool
            if let tabID = policy.tabID {
                mcpRoutingLog("Policy includes tab context - installing for tab=\(tabID) run=\(runID)")
                let installation = await installTabContextFromPolicy(
                    clientID: connectionID.uuidString,
                    clientName: clientName,
                    windowID: policy.windowID,
                    tabID: tabID,
                    runID: runID,
                    signalRouting: false
                )
                routed = installation.routed
                pendingPolicyRunIDMappingToken = installation.replacementToken
            } else {
                pendingPolicyRunIDMappingToken = await mapConnectionToRunIDForPendingPolicy(
                    connectionID,
                    runID: runID,
                    windowID: policy.windowID
                )
                routed = pendingPolicyRunIDMappingToken != nil
            }
            #if DEBUG
                debugRecordRunRoutingEvent(
                    runID: runID,
                    event: routed ? "run_route_mapped" : "run_route_mapping_failed",
                    connectionID: connectionID,
                    fields: [
                        "client_name": clientName,
                        "window_id": String(policy.windowID),
                        "tab_id": policy.tabID?.uuidString ?? "nil"
                    ]
                )
            #endif
            guard routed else {
                let reservationRolledBack = !policy.oneShot || rollbackOneShotPendingPolicyReservation(
                    id: policy.id,
                    key: matchedQueueEntry.key,
                    connectionID: connectionID
                )
                await rollbackPendingPolicyApplication(
                    policy,
                    clientName: clientName,
                    connectionID: connectionID,
                    restorePoint: restorePoint,
                    applicationID: pendingPolicyApplicationID,
                    pendingPolicyRunIDMappingToken: pendingPolicyRunIDMappingToken
                )
                return .rejected(
                    runID: runID,
                    reason: reservationRolledBack ? "route_mapping_failed" : "policy_removed"
                )
            }

            #if DEBUG
                await debugSuspendPendingPolicyCommitIfNeeded()
            #endif

            let routeMappingToken = pendingPolicyRunIDMappingToken
            let routeMappingIsCurrent = await MainActor.run {
                routeMappingToken.map { token in
                    guard let window = WindowStatesManager.shared.window(withID: policy.windowID) else {
                        return false
                    }
                    return window.mcpServer.isCurrentPendingPolicyRunIDMapping(token)
                } ?? true
            }
            guard routeMappingIsCurrent,
                  isPendingPolicyApplicationOwner(
                      pendingPolicyApplicationID,
                      connectionID: connectionID,
                      runID: policy.runID
                  ),
                  isPendingPolicyApplicationCurrent(
                      connectionID: connectionID,
                      clientName: clientName,
                      expectedLifecycleGeneration: expectedLifecycleGeneration
                  )
            else {
                if policy.oneShot {
                    _ = rollbackOneShotPendingPolicyReservation(
                        id: policy.id,
                        key: matchedQueueEntry.key,
                        connectionID: connectionID
                    )
                }
                await rollbackPendingPolicyApplication(
                    policy,
                    clientName: clientName,
                    connectionID: connectionID,
                    restorePoint: restorePoint,
                    applicationID: pendingPolicyApplicationID,
                    pendingPolicyRunIDMappingToken: pendingPolicyRunIDMappingToken,
                    signalRoutingFailure: false
                )
                return .rejected(runID: runID, reason: "stale_connection")
            }
        }

        if policy.oneShot,
           !consumeOneShotPendingPolicy(
               id: policy.id,
               key: matchedQueueEntry.key,
               connectionID: connectionID
           )
        {
            await rollbackPendingPolicyApplication(
                policy,
                clientName: clientName,
                connectionID: connectionID,
                restorePoint: restorePoint,
                applicationID: pendingPolicyApplicationID,
                pendingPolicyRunIDMappingToken: pendingPolicyRunIDMappingToken
            )
            return .rejected(runID: policy.runID, reason: "policy_removed")
        }

        finishPendingPolicyApplication(
            pendingPolicyApplicationID,
            connectionID: connectionID,
            runID: policy.runID
        )
        if let pendingPolicyRunIDMappingToken {
            schedulePendingPolicyConnectionReplacement(
                pendingPolicyRunIDMappingToken,
                windowID: policy.windowID
            )
        }
        if requireRunRouting, let runID = policy.runID {
            await MCPRoutingWaiter.notifyRouted(runID: runID)
        }

        let grantDescription = Self.describeGrantedTools(restricted: policy.restrictedTools)
        let restrictedDescription = Self.describeToolList(policy.restrictedTools)
        connectionLog(
            "Applying connection policy to \(connectionID) client=\(clientName) window=\(policy.windowID) grants=\(grantDescription) restricted=\(restrictedDescription) reason=\(policy.reason ?? "-") tabID=\(policy.tabID?.uuidString ?? "nil") runID=\(policy.runID?.uuidString ?? "nil")"
        )
        mcpPolicyLog(
            "applied policy client=\(clientName) matchedKey=\(matchedQueueEntry.key) connection=\(connectionID) window=\(policy.windowID) purpose=\(policy.purpose.rawValue) oneShot=\(policy.oneShot) runID=\(policy.runID?.uuidString ?? "nil") tabID=\(policy.tabID?.uuidString ?? "nil") queueAfterPop=\(remainingAfterPop) queueAfterStore=\(remainingAfterRequeue)"
        )
        #if DEBUG
            if let runID = policy.runID {
                debugRecordRunRoutingEvent(
                    runID: runID,
                    event: "policy_applied",
                    connectionID: connectionID,
                    fields: [
                        "client_name": clientName,
                        "bootstrap_client_name": bootstrapClientName ?? "nil",
                        "helper_peer_pid": clientPid.map(String.init) ?? "nil",
                        "pending_policy_key": matchedQueueEntry.key,
                        "window_id": String(policy.windowID),
                        "tab_id": policy.tabID?.uuidString ?? "nil",
                        "purpose": policy.purpose.rawValue,
                        "queue_after_store": String(remainingAfterRequeue)
                    ]
                )
            }
            AgentModePerfDiagnostics.event("mcp.policy.pendingPolicyApplied", fields: [
                "connectionID": connectionID.uuidString,
                "clientName": clientName,
                "clientPid": clientPid.map(String.init) ?? "nil",
                "bootstrapClientName": bootstrapClientName ?? "nil",
                "matchedKey": matchedQueueEntry.key,
                "windowID": String(policy.windowID),
                "tabID": policy.tabID?.uuidString ?? "nil",
                "runID": policy.runID?.uuidString ?? "nil",
                "purpose": policy.purpose.rawValue,
                "taskLabel": policy.taskLabelKind?.rawValue ?? "nil",
                "additionalTools": Self.debugDescribeToolSet(policy.additionalTools ?? []),
                "restrictedTools": Self.debugDescribeToolSet(policy.restrictedTools),
                "allowsAgentExternalControlTools": String(policy.allowsAgentExternalControlTools),
                "requiresExpectedAgentPID": String(policy.requiresExpectedAgentPID),
                "queueAfterPop": String(remainingAfterPop),
                "queueAfterStore": String(remainingAfterRequeue)
            ])
        #endif
        if let runID = policy.runID {
            updateLiveRunAffinity(
                clientName: clientName,
                sessionKey: connections[connectionID]?.capabilityToken ?? capabilityTokenByConnection[connectionID],
                runID: runID,
                windowID: policy.windowID,
                purpose: policy.purpose
            )
        }

        setConnectionWindowMapping(connectionID, windowID: policy.windowID)
        mcpRoutingLog("Set window mapping connectionID=\(connectionID) → window=\(policy.windowID)")

        await updateRoutingRecordForConnection(connectionID, clientID: clientName)
        await notifyToolListChanged(connectionID: connectionID)
        return .applied(runID: policy.runID)
    }

    private func isPendingPolicyApplicationOwner(
        _ applicationID: UUID,
        connectionID: UUID,
        runID: UUID?
    ) -> Bool {
        guard pendingPolicyApplicationIDByConnectionID[connectionID] == applicationID else { return false }
        return runID.map { pendingPolicyApplicationIDByRunID[$0] == applicationID } ?? true
    }

    private func isPendingPolicyApplicationCurrent(
        connectionID: UUID,
        clientName: String,
        expectedLifecycleGeneration: UInt64?
    ) -> Bool {
        if let expectedLifecycleGeneration {
            return isCurrentConnection(connectionID, lifecycleGeneration: expectedLifecycleGeneration)
        }
        return pendingConnections[connectionID] == clientName
    }

    private func rollbackPendingPolicyApplication(
        _ policy: ClientConnectionPolicy,
        clientName: String,
        connectionID: UUID,
        restorePoint: PendingPolicyRestorePoint,
        applicationID: UUID,
        pendingPolicyRunIDMappingToken: MCPServerViewModel.PendingPolicyRunIDMappingToken? = nil,
        signalRoutingFailure: Bool = true
    ) async {
        var mappingRollbackResult: MCPServerViewModel.PendingPolicyRunIDMappingRollbackResult?
        if let runID = policy.runID {
            mappingRollbackResult = await MainActor.run {
                guard let window = WindowStatesManager.shared.window(withID: policy.windowID) else { return nil }
                if let pendingPolicyRunIDMappingToken {
                    return window.mcpServer.rollbackPendingPolicyRunIDMapping(
                        pendingPolicyRunIDMappingToken,
                        clientName: clientName,
                        windowID: policy.windowID,
                        signalRoutingFailure: signalRoutingFailure
                    )
                }
                window.mcpServer.removeTabContext(
                    forConnectionID: connectionID,
                    clientName: clientName,
                    windowID: policy.windowID,
                    runID: runID
                )
                window.mcpServer.cleanupRunIDMapping(
                    runID: runID,
                    connectionID: connectionID,
                    signalRoutingFailure: signalRoutingFailure
                )
                return .restored
            }
        }

        var ownsConnectionState = pendingPolicyApplicationIDByConnectionID[connectionID] == applicationID
        var ownsRunState = policy.runID.map { pendingPolicyApplicationIDByRunID[$0] == applicationID } ?? false
        switch mappingRollbackResult {
        case .supersededBySameConnection:
            ownsConnectionState = false
            ownsRunState = false
        case .supersededByOtherConnection:
            ownsRunState = false
        case .restored, nil:
            break
        }
        restorePendingPolicyState(
            restorePoint,
            connectionID: connectionID,
            policyRunID: policy.runID,
            restoreConnectionScopedState: ownsConnectionState,
            restoreRunScopedState: ownsRunState
        )
        finishPendingPolicyApplication(
            applicationID,
            connectionID: connectionID,
            runID: policy.runID
        )
    }

    private func finishPendingPolicyApplication(
        _ applicationID: UUID,
        connectionID: UUID,
        runID: UUID?
    ) {
        if pendingPolicyApplicationIDByConnectionID[connectionID] == applicationID {
            pendingPolicyApplicationIDByConnectionID.removeValue(forKey: connectionID)
        }
        if let runID, pendingPolicyApplicationIDByRunID[runID] == applicationID {
            pendingPolicyApplicationIDByRunID.removeValue(forKey: runID)
        }
    }

    private func restorePendingPolicyState(
        _ restorePoint: PendingPolicyRestorePoint,
        connectionID: UUID,
        policyRunID: UUID?,
        restoreConnectionScopedState: Bool,
        restoreRunScopedState: Bool
    ) {
        if restoreConnectionScopedState {
            if let restrictedTools = restorePoint.restrictedTools {
                restrictedToolsByConnection[connectionID] = restrictedTools
            } else {
                restrictedToolsByConnection.removeValue(forKey: connectionID)
            }
            if let additionalTools = restorePoint.additionalTools {
                additionalToolsByConnection[connectionID] = additionalTools
            } else {
                additionalToolsByConnection.removeValue(forKey: connectionID)
            }
            if let runPurpose = restorePoint.runPurpose {
                runPurposeByConnection[connectionID] = runPurpose
            } else {
                runPurposeByConnection.removeValue(forKey: connectionID)
            }
            if let windowID = restorePoint.windowID {
                connectionWindowMap[connectionID] = windowID
            } else {
                connectionWindowMap.removeValue(forKey: connectionID)
            }
            if let windowAssignment = restorePoint.windowAssignment {
                windowAssignmentByConnection[connectionID] = windowAssignment
            } else {
                windowAssignmentByConnection.removeValue(forKey: connectionID)
            }
            if let runID = restorePoint.runID {
                runIDByConnectionID[connectionID] = runID
            } else {
                runIDByConnectionID.removeValue(forKey: connectionID)
            }
            if restorePoint.wasPreassigned {
                preassignedConnections.insert(connectionID)
            } else {
                preassignedConnections.remove(connectionID)
            }
        }

        guard restoreRunScopedState, let policyRunID else { return }
        if restorePoint.wasRunAdmitted {
            admittedPolicyRunIDs.insert(policyRunID)
        } else {
            admittedPolicyRunIDs.remove(policyRunID)
        }
        if let runPolicyState = restorePoint.runPolicyState {
            runPolicyStateByRunID[policyRunID] = runPolicyState
        } else {
            runPolicyStateByRunID.removeValue(forKey: policyRunID)
        }
        if let runWindowID = restorePoint.runWindowID {
            windowIDByRunID[policyRunID] = runWindowID
        } else {
            windowIDByRunID.removeValue(forKey: policyRunID)
        }
    }

    /// Install tab context from a connection policy (for Context Builder agents)
    private func installTabContextFromPolicy(
        clientID: String,
        clientName: String,
        windowID: Int,
        tabID: UUID,
        runID: UUID,
        signalRouting: Bool = true
    ) async -> (routed: Bool, replacementToken: MCPServerViewModel.PendingPolicyRunIDMappingToken?) {
        let resolved = await MainActor.run {
            () -> (
                workspaceID: UUID,
                snapshot: ComposeTabState,
                routed: Bool,
                replacementToken: MCPServerViewModel.PendingPolicyRunIDMappingToken?
            )? in
            guard let windowState = WindowStatesManager.shared.window(withID: windowID) else {
                return nil
            }
            guard let resolved = windowState.workspaceManager.resolveComposeTabRoutingSnapshot(
                for: tabID,
                captureActiveUIState: false
            ) else {
                return nil
            }
            let replacementToken = windowState.mcpServer.installTabContext(
                clientID: clientID,
                clientName: clientName,
                windowID: windowID,
                workspaceID: resolved.workspaceID,
                snapshot: resolved.snapshot,
                runID: runID,
                signalRouting: signalRouting,
                deferRunIDReplacementForPendingPolicy: true
            )
            let routed = replacementToken != nil
            return (resolved.workspaceID, resolved.snapshot, routed, replacementToken)
        }

        guard let resolved else {
            log.warning("installTabContextFromPolicy: tab \(tabID) could not resolve routing snapshot in window \(windowID)")
            return (false, nil)
        }

        if resolved.routed, let cached = runPolicyStateByRunID[runID] {
            seedRunPolicyState(
                runID: runID,
                windowID: windowID,
                workspaceID: resolved.workspaceID,
                tabID: resolved.snapshot.id,
                restrictedTools: cached.restrictedTools,
                additionalTools: cached.additionalTools,
                purpose: cached.purpose,
                taskLabelKind: cached.taskLabelKind,
                allowsAgentExternalControlTools: cached.allowsAgentExternalControlTools,
                updatedAt: Date()
            )
        }
        connectionLog("Installed tab context from policy: tab=\(tabID) run=\(runID) window=\(windowID) workspace=\(resolved.workspaceID) client=\(clientName)")
        return (resolved.routed, resolved.replacementToken)
    }

    @discardableResult
    private func ensureTabBoundForRunIfPossible(
        connectionID: UUID,
        clientName: String?,
        runID: UUID,
        windowID: Int
    ) async -> Bool {
        guard
            let cached = runPolicyStateByRunID[runID],
            let tabID = cached.tabID
        else {
            return false
        }
        let resolvedClientName = clientName ?? clientIdentifier(forConnection: connectionID)
        do {
            let bindingResult = try await MainActor.run { () throws -> (didBind: Bool, workspaceID: UUID?) in
                guard let windowState = WindowStatesManager.shared.window(withID: windowID) else {
                    throw MCPError.invalidParams("Window \(windowID) not found")
                }
                // Fast path: already bound to this exact tab+run in this window.
                let alreadyBoundTab = windowState.mcpServer.boundTabID(forConnection: connectionID) == tabID
                let alreadyBoundRun = windowState.mcpServer.connectionIDToRunID[connectionID] == runID
                if alreadyBoundTab, alreadyBoundRun {
                    return (false, cached.workspaceID)
                }
                let resolvedWorkspaceID = cached.workspaceID ?? windowState.workspaceManager.resolveComposeTabRoutingSnapshot(for: tabID)?.workspaceID
                guard let workspaceID = resolvedWorkspaceID else {
                    throw MCPError.invalidParams("Tab \(tabID) not found in any workspace for window \(windowID)")
                }
                try windowState.mcpServer.bindTabForConnection(
                    connectionID: connectionID,
                    clientName: resolvedClientName,
                    tabID: tabID,
                    workspaceID: workspaceID,
                    windowID: windowID,
                    runID: runID,
                    explicitlyBound: false
                )
                return (true, workspaceID)
            }
            if let workspaceID = bindingResult.workspaceID, workspaceID != cached.workspaceID {
                seedRunPolicyState(
                    runID: runID,
                    windowID: cached.windowID,
                    workspaceID: workspaceID,
                    tabID: cached.tabID,
                    restrictedTools: cached.restrictedTools,
                    additionalTools: cached.additionalTools,
                    purpose: cached.purpose,
                    taskLabelKind: cached.taskLabelKind,
                    allowsAgentExternalControlTools: cached.allowsAgentExternalControlTools,
                    updatedAt: Date()
                )
            }
            if bindingResult.didBind {
                connectionLog("Tab binding: rebound connection \(connectionID) to cached run tab \(tabID) for run \(runID) in window \(windowID)")
            }
            return true
        } catch {
            log.warning("ensureTabBoundForRunIfPossible: failed run=\(runID) tab=\(tabID) window=\(windowID) connection=\(connectionID) error=\(error.localizedDescription)")
            return false
        }
    }

    func registerHandlers(for server: MCP.Server, connectionID: UUID) async {
        // ------------------------------------------------------------------
        //  prompts/list
        // ------------------------------------------------------------------
        await server.withMethodHandler(ListPrompts.self) { _ in
            connectionLog("Handling ListPrompts request for \(connectionID)")
            return ListPrompts.Result(prompts: MCPPromptRegistry.listPrompts())
        }

        // ------------------------------------------------------------------
        //  prompts/get
        // ------------------------------------------------------------------
        await server.withMethodHandler(GetPrompt.self) { params in
            connectionLog("Handling GetPrompt request name=\(params.name) for \(connectionID)")
            let promptArguments = params.arguments?.mapValues { Value.string($0) }
            return try MCPPromptRegistry.getPrompt(named: params.name, arguments: promptArguments)
        }

        // ------------------------------------------------------------------
        //  resources/list
        // ------------------------------------------------------------------
        await server.withMethodHandler(ListResources.self) { _ in
            connectionLog("Handling ListResources request for \(connectionID)")
            return ListResources.Result(
                resources: [
                    Resource(
                        name: "RepoPrompt Instructions",
                        uri: "repoprompt://instructions",
                        description: "Usage instructions for RepoPrompt MCP tools - read this to understand how to effectively use the available tools",
                        mimeType: "text/plain"
                    )
                ],
                nextCursor: nil
            )
        }

        // ------------------------------------------------------------------
        //  resources/templates/list
        // ------------------------------------------------------------------
        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            connectionLog("Handling ListResourceTemplates request for \(connectionID)")
            return ListResourceTemplates.Result(templates: [], nextCursor: nil)
        }

        // ------------------------------------------------------------------
        //  resources/read
        // ------------------------------------------------------------------
        await server.withMethodHandler(ReadResource.self) { [weak self] params in
            guard let self else { throw MCPError.internalError("Server unavailable") }
            connectionLog("Handling ReadResource request for \(connectionID), uri=\(params.uri)")

            switch params.uri {
            case "repoprompt://instructions":
                let hydratedPolicy = await hydratePersistedAgentModePolicyForConnectionIfNeeded(
                    connectionID: connectionID,
                    reason: "resources/read-instructions"
                )
                let purpose = await effectivePolicyState(for: connectionID).purpose
                if hydratedPolicy {
                    mcpPolicyLog("hydrated policy before resources/read instructions connection=\(connectionID) purpose=\(purpose.rawValue)")
                }
                let codeMapsDisabled = await MainActor.run { GlobalSettingsStore.shared.globalCodeMapsDisabled() }
                return ReadResource.Result(
                    contents: [
                        .text(RepoPromptMCPInstructions.text(for: purpose, codeMapsDisabled: codeMapsDisabled), uri: params.uri, mimeType: "text/plain")
                    ]
                )
            default:
                throw MCPError.invalidParams("Unknown resource URI: \(params.uri)")
            }
        }

        // ------------------------------------------------------------------
        //  tools/list  (UPDATED)
        // ------------------------------------------------------------------
        await server.withMethodHandler(ListTools.self) { [weak self] _ in
            guard let self else { return ListTools.Result(tools: []) }

            connectionLog("Handling ListTools request for \(connectionID)")
            let clientIdentifier = await clientIdentifier(forConnection: connectionID)

            // Safety net: ensure tool catalog is ready before returning list.
            // The primary readiness wait happens during handshake, but this catches edge cases.
            // Use ensureWindowBindingIfUnambiguous to treat nil as single-window fallback,
            // preventing failures for clients that call tools/list before explicit window selection.
            let windowID = await ensureWindowBindingIfUnambiguous(connectionID: connectionID, reason: "tools/list")
            let isReady = await MCPToolCatalogReadiness.shared.awaitReady(
                windowID: windowID,
                timeout: 2.0 // Shorter timeout here since handshake should have waited
            )
            if !isReady {
                // Only fail closed if we had a specific window to wait for.
                // If windowID is nil (true multi-window ambiguity), log warning but proceed
                // with whatever tools are available - the client will need to select a window.
                if windowID != nil {
                    log.warning("Tool catalog not ready for tools/list - failing closed for connection \(connectionID) window \(windowID!)")
                    throw MCPError.internalError("Tool catalog not ready. Please retry.")
                } else {
                    connectionLog("Tool catalog readiness skipped for multi-window ambiguous connection \(connectionID)")
                }
            }

            // Warm tool cache if we have a bound window
            if let windowID {
                await MCPToolCatalogReadiness.shared.warmToolCache(windowID: windowID)
            }

            // Opportunistic persisted hydration for resumed agent-mode sessions.
            // Persisted routing metadata may restore window/run mapping, and cached
            // run policy (if available) can restore gated tool visibility.
            _ = await hydratePersistedAgentModePolicyForConnectionIfNeeded(
                connectionID: connectionID,
                reason: "tools/list"
            )

            // Get all MainActor-isolated data in one hop
            let (disabled, registeredServices) = await MainActor.run {
                (
                    ToolAvailabilityStore.shared.effectiveDisabledTools,
                    ServiceRegistry.services
                )
            }
            let policy = await effectivePolicyState(for: connectionID)
            let restricted = policy.restricted
            let additionalTools = policy.additional
            #if DEBUG
                var hiddenToolReasons: [String: Int] = [:]
                var hiddenToolSamples: [String] = []
                func recordHiddenTool(_ toolName: String, reason: String) {
                    hiddenToolReasons[reason, default: 0] += 1
                    guard hiddenToolSamples.count < 20 else { return }
                    hiddenToolSamples.append("\(toolName):\(reason)")
                }
            #endif

            var seenNames = Set<String>() // ✱ 2. Deduplication helper
            var tools: [MCP.Tool] = []

            // Only proceed when the global MCP switch is ON
            if await isEnabledState {
                // Enumerate every registered Service
                for service in registeredServices {
                    // Walk through the service's declared tools
                    for tool in await service.tools {
                        if disabled.contains(tool.name) {
                            #if DEBUG
                                recordHiddenTool(tool.name, reason: "disabled")
                            #endif
                            continue
                        }
                        if restricted.contains(tool.name) {
                            #if DEBUG
                                recordHiddenTool(tool.name, reason: "restricted")
                            #endif
                            continue
                        }

                        // • hide policy-gated tools unless explicitly granted via additionalTools
                        if MCPPolicyGatedTools.names.contains(tool.name),
                           !additionalTools.contains(tool.name)
                        {
                            #if DEBUG
                                recordHiddenTool(tool.name, reason: "missing_additional_tool_grant")
                            #endif
                            continue
                        }

                        // • role-based advertisement filtering (advertisement-only, not execution-time)
                        if !AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                            toolName: tool.name,
                            taskLabelKind: policy.taskLabelKind,
                            allowsAgentExternalControlTools: policy.allowsAgentExternalControlTools
                        ) {
                            #if DEBUG
                                recordHiddenTool(tool.name, reason: "role_advertisement_policy")
                            #endif
                            continue
                        }

                        // • skip duplicates coming from other windows
                        guard seenNames.insert(tool.name).inserted else { continue }

                        // OK – advertise the tool
                        let schemaValue = try await cachedSchema(
                            for: tool.name,
                            schema: tool.inputSchema,
                            purpose: policy.purpose
                        )
                        let description = advertisedToolDescription(
                            for: tool.name,
                            baseDescription: tool.description,
                            purpose: policy.purpose
                        )

                        tools.append(
                            .init(
                                name: tool.name,
                                description: description,
                                inputSchema: schemaValue,
                                annotations: CodexMCPToolAnnotationProjection.project(
                                    tool.annotations,
                                    clientIdentifier: clientIdentifier
                                )
                            )
                        )
                    }
                }
            }

            #if DEBUG
                await debugPolicyDiagnostic("toolsList", connectionID: connectionID, policy: policy, extra: [
                    "advertisedToolCount": String(tools.count),
                    "hiddenReasons": hiddenToolReasons.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ","),
                    "hiddenSamples": hiddenToolSamples.joined(separator: ",")
                ])
            #endif
            connectionLog("Returning \(tools.count) available tools for \(connectionID)")
            return ListTools.Result(tools: tools)
        }

        // ------------------------------------------------------------------
        //  tools/call  (UPDATED)
        // ------------------------------------------------------------------
        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else {
                return CallTool.Result(
                    content: [MCP.Tool.Content.text(text: "Server unavailable", annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            let originalName = params.name
            let toolName = Self.canonicalToolName(for: originalName)
            connectionLog("tools/call received original=\(originalName) canonical=\(toolName) connection=\(connectionID)")
            #if DEBUG
                await debugPolicyDiagnostic("toolsCallReceived", connectionID: connectionID, extra: [
                    "toolName": toolName,
                    "originalName": originalName
                ])
                if Self.isDebugDiagnosticsToolName(toolName) {
                    guard let limiterResolution = await connectionCallLimiterResolution(
                        for: connectionID
                    ) else {
                        return Self.executionContractToolErrorResult(
                            rawJSON: false,
                            code: "tool_execution_connection_terminal",
                            message: "The MCP connection is closing."
                        )
                    }
                    return await withConnectionCallPermit(
                        connectionID: connectionID,
                        lane: .ordinary,
                        resolution: limiterResolution,
                        cancellationResult: {
                            Self.executionContractToolErrorResult(
                                rawJSON: false,
                                code: "tool_execution_connection_terminal",
                                message: "The MCP connection is closing."
                            )
                        }
                    ) {
                        await self.handleDebugDiagnosticsTool(
                            connectionID: connectionID,
                            arguments: params.arguments ?? [:]
                        )
                    }
                }
            #endif
            #if DEBUG
                let transportRequestIdentity = MCPRequestTimelineRegistry.shared.claimToolRequest(
                    connectionID: connectionID.uuidString,
                    originalToolName: originalName
                )
                let inheritedRequestIdentity = transportRequestIdentity?.fillingMissingFields(
                    from: MCPRequestTimelineContext.current
                ) ?? MCPRequestTimelineContext.current
                let fallbackConnectionGeneration = await requestTimelineConnectionGeneration(for: connectionID)
                let requestIdentity = MCPRequestTimelineIdentity(
                    jsonRPCRequestID: inheritedRequestIdentity?.jsonRPCRequestID,
                    connectionID: inheritedRequestIdentity?.connectionID ?? connectionID.uuidString,
                    connectionGeneration: inheritedRequestIdentity?.connectionGeneration ?? fallbackConnectionGeneration,
                    appInvocationID: inheritedRequestIdentity?.appInvocationID,
                    requestOrdinal: inheritedRequestIdentity?.requestOrdinal
                )
                let invocationID = requestIdentity.appInvocationID.flatMap { UUID(uuidString: $0) } ?? UUID()
                let resolvedRequestIdentity: MCPRequestTimelineIdentity? = MCPRequestTimelineIdentity(
                    jsonRPCRequestID: requestIdentity.jsonRPCRequestID,
                    connectionID: requestIdentity.connectionID,
                    connectionGeneration: requestIdentity.connectionGeneration,
                    appInvocationID: invocationID.uuidString,
                    requestOrdinal: requestIdentity.requestOrdinal
                )
                let lifecycleCorrelation = EditFlowPerf.makeLifecycleCorrelationIfActive(
                    requestIdentity: resolvedRequestIdentity
                )
                if let resolvedRequestIdentity {
                    MCPResponseDeliveryTracer.emit(MCPResponseDeliveryTraceEvent(
                        layer: "app_sdk",
                        phase: "sdk_decode_completed",
                        connectionID: resolvedRequestIdentity.connectionID,
                        connectionGeneration: resolvedRequestIdentity.connectionGeneration,
                        direction: .clientToServer,
                        id: resolvedRequestIdentity.jsonRPCRequestID,
                        method: "tools/call",
                        tool: toolName,
                        invocationID: invocationID.uuidString,
                        requestOrdinal: resolvedRequestIdentity.requestOrdinal,
                        requestIdentity: resolvedRequestIdentity
                    ))
                }
            #else
                let invocationID = UUID()
                let resolvedRequestIdentity: MCPRequestTimelineIdentity? = nil
                let lifecycleCorrelation = EditFlowPerf.makeLifecycleCorrelationIfActive()
            #endif
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.received,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(toolName: toolName)
            )
            // CE exposes all MCP tools that are registered for the current connection.
            // Avoid calling the MainActor-backed ToolAvailabilityStore from this hot path;
            // it can block tool responses while settings/UI work is in flight.
            connectionLog("tools/call \(toolName): tool availability gate skipped for CE")
            let totalState = EditFlowPerf.begin(
                EditFlowPerf.Stage.MCPToolCall.total,
                EditFlowPerf.Dimensions(toolName: toolName)
            )
            defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.total, totalState) }
            let preLimiterEnvelopeState = EditFlowPerf.begin(
                EditFlowPerf.Stage.MCPToolCall.preLimiterEnvelope,
                EditFlowPerf.Dimensions(toolName: toolName)
            )
            var didEndPreLimiterEnvelope = false
            func endPreLimiterEnvelopeIfNeeded() {
                guard !didEndPreLimiterEnvelope else { return }
                didEndPreLimiterEnvelope = true
                EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.preLimiterEnvelope, preLimiterEnvelopeState)
            }
            defer { endPreLimiterEnvelopeIfNeeded() }

            // Normalize arguments using shared module
            connectionLog("tools/call \(toolName): normalizing args")
            let normalized = EditFlowPerf.measure(
                EditFlowPerf.Stage.MCPToolCall.normalizeArgs,
                EditFlowPerf.Dimensions(toolName: toolName)
            ) {
                MCPToolArgsNormalizer.normalize(
                    params: params.arguments,
                    originalToolName: originalName,
                    canonicalToolName: toolName
                )
            }

            // Log any warnings from normalization
            for warning in normalized.warnings {
                connectionLog("Argument normalization: \(warning)")
            }

            let extractedTabID = normalized.tabID
            let extractedWindowID = normalized.windowID
            let extractedContextID = normalized.contextID
            let extractedWorkingDirs = normalized.workingDirs
            let extractedRawJSON = normalized.rawJSON
            let cleanedArguments = normalized.payload
            let capturedRawJSON = extractedRawJSON
            connectionLog("tools/call \(toolName): args normalized keys=\(cleanedArguments.keys.sorted().joined(separator: ","))")

            // tools/list already performs any needed persisted routing hydration.
            // Do not repeat it on each tools/call; it can re-enter routing notifications
            // while the call is waiting for a response.

            var dispatchTabContextHint: MCPServerViewModel.TabContextHint? = nil
            var preResolvedWindowID: Int? = nil
            do {
                let logicalContextState = EditFlowPerf.begin(
                    EditFlowPerf.Stage.MCPToolCall.logicalContextResolution,
                    EditFlowPerf.Dimensions(toolName: toolName)
                )
                defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.logicalContextResolution, logicalContextState) }
                if !Self.shouldBypassLogicalContextPreResolution(for: toolName) {
                    do {
                        if let logicalBinding = try await bindingResolver.resolveLogicalContextBinding(
                            connectionID: connectionID,
                            explicitContextID: extractedContextID,
                            legacyTabID: extractedTabID,
                            workingDirs: [],
                            requestedWindowID: extractedWindowID
                        ) {
                            dispatchTabContextHint = MCPServerViewModel.TabContextHint(
                                tabID: logicalBinding.logicalContext.tabID,
                                workspaceID: logicalBinding.logicalContext.workspaceID,
                                windowID: logicalBinding.windowID
                            )
                            preResolvedWindowID = logicalBinding.windowID
                            if Self.shouldPersistResolvedLogicalContextWindowMapping(for: toolName) {
                                await setConnectionWindowMapping(connectionID, windowID: logicalBinding.windowID)
                            }
                            connectionLog(
                                "Tool call: resolved logical context_id=\(logicalBinding.logicalContext.tabID) workspace=\(logicalBinding.logicalContext.workspaceName) window=\(logicalBinding.windowID)"
                            )
                        }
                    } catch {
                        let routePolicy = await effectivePolicyState(for: connectionID)
                        if routePolicy.purpose == .agentModeRun || routePolicy.restricted.contains("bind_context") {
                            return Self.toolErrorResult(
                                rawJSON: capturedRawJSON,
                                message: "Unable to resolve the requested RepoPrompt context for this restricted connection. " +
                                    Self.multiWindowSelectionGuidance(
                                        purpose: routePolicy.purpose,
                                        restrictedTools: routePolicy.restricted
                                    )
                            )
                        }
                        return Self.toolErrorResult(rawJSON: capturedRawJSON, message: error.localizedDescription)
                    }
                }
            }

            do {
                let policyState = EditFlowPerf.begin(
                    EditFlowPerf.Stage.MCPToolCall.policyGating,
                    EditFlowPerf.Dimensions(toolName: toolName)
                )
                defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.policyGating, policyState) }

                // tools/list already performs any needed persisted routing hydration.
                // Avoid repeating that work while a tool call is in-flight.

                // Block policy-gated tools unless explicitly granted via additionalTools
                if MCPPolicyGatedTools.names.contains(toolName) {
                    let effectivePolicy = await effectivePolicyState(for: connectionID)
                    if !effectivePolicy.additional.contains(toolName) {
                        #if DEBUG
                            await debugPolicyDiagnostic("toolsCallRejected", connectionID: connectionID, policy: effectivePolicy, extra: [
                                "toolName": toolName,
                                "reason": "missing_additional_tool_grant"
                            ])
                        #endif
                        return CallTool.Result.err("Tool '\(toolName)' is only available during discovery or agent mode runs.")
                    }
                }
            }

            // Rehydrate canonical binding fields only when the tool explicitly accepts
            // them. For migrated tools, context_id/_tabID has already become a one-shot
            // tab-context hint instead of hidden sticky binding args.
            var dispatchArguments = cleanedArguments
            if let contextID = extractedContextID, Self.shouldRehydrateContextID(for: toolName) {
                dispatchArguments["context_id"] = .string(contextID.uuidString)
            }
            if let legacyTabID = extractedTabID, Self.shouldRehydrateLegacyTabID(for: toolName) {
                dispatchArguments["_tabID"] = .string(legacyTabID.uuidString)
            }
            if let windowID = extractedWindowID, Self.shouldRehydrateExplicitWindowID(for: toolName) {
                dispatchArguments["window_id"] = .int(windowID)
            }
            if toolName == "bind_context", !extractedWorkingDirs.isEmpty {
                dispatchArguments["working_dirs"] = .array(extractedWorkingDirs.map { .string($0) })
            }

            // Prepare args for formatter. Hidden _tabID is injected only for explicit
            // compatibility paths that still inspect legacy args directly.
            var argsForFormatter = dispatchArguments
            if Self.shouldInjectLegacyTabIDForCompatibility(for: toolName),
               let tabID = dispatchTabContextHint?.tabID ?? extractedTabID
            {
                argsForFormatter["_tabID"] = .string(tabID.uuidString)
            }
            if !Self.shouldBypassWindowRouting(for: toolName),
               let windowID = extractedWindowID ?? preResolvedWindowID
            {
                argsForFormatter["_windowID"] = .int(windowID)
            }
            if extractedRawJSON {
                argsForFormatter["_rawJSON"] = .bool(true)
            }

            connectionLog("tools/call \(toolName): computing effective policy")
            let policy = await EditFlowPerf.measure(
                EditFlowPerf.Stage.MCPToolCall.effectivePolicySnapshot,
                EditFlowPerf.Dimensions(toolName: toolName)
            ) {
                await self.effectivePolicyState(for: connectionID)
            }
            connectionLog("tools/call \(toolName): policy ready")
            do {
                let policyState = EditFlowPerf.begin(
                    EditFlowPerf.Stage.MCPToolCall.policyGating,
                    EditFlowPerf.Dimensions(toolName: toolName)
                )
                defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.policyGating, policyState) }
                if policy.restricted.contains(toolName) {
                    log.notice("Connection \(connectionID) attempted to call restricted tool \(toolName)")
                    return Self.toolErrorResult(rawJSON: capturedRawJSON, message: "Tool '\(toolName)' is disabled for this connection.")
                }
                if MCPToolCapabilities.capabilities(for: toolName).contains(.agentExploreControl),
                   !AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                       toolName: toolName,
                       taskLabelKind: policy.taskLabelKind,
                       allowsAgentExternalControlTools: policy.allowsAgentExternalControlTools
                   )
                {
                    return Self.toolErrorResult(
                        rawJSON: capturedRawJSON,
                        message: "Tool 'agent_explore' is only available to MCP-started non-explore Agent Mode runs."
                    )
                }
            }

            // Create immutable copies for Swift 6 concurrency safety
            let capturedTabContextHint = dispatchTabContextHint
            let capturedTabID = Self.shouldUseGenericTabBindingCompatibility(for: toolName)
                ? (dispatchTabContextHint?.tabID ?? extractedTabID)
                : nil
            let capturedWindowID = extractedWindowID
            let capturedPreResolvedWindowID = preResolvedWindowID
            let capturedArguments = dispatchArguments
            let capturedArgsForFormatter = argsForFormatter

            // Snapshot routing state before entering the per-connection limiter.
            // Keep the snapshot local to this call so app-wide tools do not share
            // mutable cross-connection service state.
            let bypassWindowRoutingForSnapshot = Self.shouldBypassWindowRouting(for: toolName)
            connectionLog("tools/call \(toolName): reading MainActor routing state")
            let routingSnapshot: (Int, [any Service], Bool) = await EditFlowPerf.measure(
                EditFlowPerf.Stage.MCPToolCall.routingSnapshot,
                EditFlowPerf.Dimensions(toolName: toolName)
            ) {
                await MainActor.run {
                    let services = ServiceRegistry.services
                    guard !bypassWindowRoutingForSnapshot else {
                        return (0, services, false)
                    }
                    let windows = WindowStatesManager.shared.allWindows
                    let effectiveMode = WindowStatesManager.shared.isMultiWindowModeEffectivelyActive
                    return (windows.count, services, effectiveMode)
                }
            }
            connectionLog("tools/call \(toolName): routing state windowCount=\(routingSnapshot.0) services=\(routingSnapshot.1.count) multi=\(routingSnapshot.2)")
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.routingSnapshotCompleted,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(toolName: toolName)
            )

            // Connection lanes provide bounded FIFO admission only. Shared-state correctness is
            // enforced below by explicit window/app/repository resource ownership.
            guard let admissionClass = Self.admissionClass(forCanonicalToolName: toolName) else {
                return Self.executionContractToolErrorResult(
                    rawJSON: capturedRawJSON,
                    code: "tool_execution_admission_unclassified",
                    message: "No static admission classification exists for tool '\(toolName)'."
                )
            }
            let callLane = admissionClass.connectionLane
            connectionLog("tools/call \(toolName): acquiring limiter lane=\(callLane.rawValue)")
            let limiterResolution = await EditFlowPerf.measure(
                EditFlowPerf.Stage.MCPToolCall.limiterResolution,
                EditFlowPerf.Dimensions(toolName: toolName)
            ) {
                await self.connectionCallLimiterResolution(for: connectionID)
            }
            endPreLimiterEnvelopeIfNeeded()
            guard let limiterResolution else {
                connectionLog("tools/call \(toolName): rejected because connection limiter is unavailable")
                return Self.executionContractToolErrorResult(
                    rawJSON: capturedRawJSON,
                    code: "tool_execution_connection_terminal",
                    message: "The MCP connection is closing."
                )
            }
            connectionLog("tools/call \(toolName): entering limiter lane=\(callLane.rawValue)")
            return await EditFlowPerf.measure(
                EditFlowPerf.Stage.MCPToolCall.limiterEnvelope,
                EditFlowPerf.Dimensions(toolName: toolName)
            ) {
                let limiterWaitState = EditFlowPerf.begin(
                    EditFlowPerf.Stage.MCPToolCall.limiterWait,
                    EditFlowPerf.Dimensions(toolName: toolName)
                )
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.MCPToolCall.limiterWaitBegan,
                    correlation: lifecycleCorrelation,
                    EditFlowPerf.Dimensions(toolName: toolName)
                )
                defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.limiterWait, limiterWaitState) }
                return await self.withConnectionCallPermit(
                    connectionID: connectionID,
                    lane: callLane,
                    resolution: limiterResolution,
                    toolName: toolName,
                    lifecycleCorrelation: lifecycleCorrelation,
                    cancellationResult: {
                        Self.executionContractToolErrorResult(
                            rawJSON: capturedRawJSON,
                            code: "tool_execution_connection_terminal",
                            message: "The MCP connection is closing."
                        )
                    }
                ) {
                    guard !Task.isCancelled,
                          await !(self.executionWatchdogTerminalConnections.contains(connectionID))
                    else {
                        connectionLog("tools/call \(toolName): rejected after limiter because connection is terminal or cancelled")
                        return Self.executionContractToolErrorResult(
                            rawJSON: capturedRawJSON,
                            code: "tool_execution_connection_terminal",
                            message: "The MCP connection was closed after an earlier tool failed to stop."
                        )
                    }
                    EditFlowPerf.lifecycleEvent(
                        EditFlowPerf.Lifecycle.MCPToolCall.limiterAcquired,
                        correlation: lifecycleCorrelation,
                        EditFlowPerf.Dimensions(toolName: toolName)
                    )
                    return await EditFlowPerf.measure(
                        EditFlowPerf.Stage.MCPToolCall.permitBodyEnvelope,
                        EditFlowPerf.Dimensions(toolName: toolName)
                    ) {
                        // Wrap entire call so inner services can query current routing hints.
                        await Self.withConnectionID(connectionID, lifecycleCorrelation: lifecycleCorrelation) {
                            await Self.$currentTabContextHint.withValue(capturedTabContextHint) {
                                let permitPreDispatchEnvelopeState = EditFlowPerf.begin(
                                    EditFlowPerf.Stage.MCPToolCall.permitPreDispatchEnvelope,
                                    EditFlowPerf.Dimensions(toolName: toolName)
                                )
                                var didEndPermitPreDispatchEnvelope = false
                                func endPermitPreDispatchEnvelopeIfNeeded() {
                                    guard !didEndPermitPreDispatchEnvelope else { return }
                                    didEndPermitPreDispatchEnvelope = true
                                    EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.permitPreDispatchEnvelope, permitPreDispatchEnvelopeState)
                                }
                                defer { endPermitPreDispatchEnvelopeIfNeeded() }

                                // Global enable flag
                                let isEnabled = await EditFlowPerf.measure(
                                    EditFlowPerf.Stage.MCPToolCall.enabledStateSnapshot,
                                    EditFlowPerf.Dimensions(toolName: toolName)
                                ) {
                                    await self.isEnabledState
                                }
                                guard isEnabled else {
                                    log.notice("Tool call rejected: RepoPrompt MCP is disabled")
                                    return Self.toolErrorResult(rawJSON: capturedRawJSON, message: "RepoPrompt MCP is currently disabled.")
                                }

                                // ────────────────────────────────────────────────────────
                                // Window-selection with explicit override support
                                // ────────────────────────────────────────────────────────
                                // Hidden params like `_windowID` can explicitly redirect a call even
                                // when the connection already has a preferred window binding.

                                let (windowCount, allServices, multiWindowModeEffective) = routingSnapshot
                                var chosenID: Int?
                                let windowStr: String
                                let observerRunIDForCallbacksFinal: UUID?
                                do {
                                    let windowRunResolutionState = EditFlowPerf.begin(
                                        EditFlowPerf.Stage.MCPToolCall.windowRunResolution,
                                        EditFlowPerf.Dimensions(toolName: toolName)
                                    )
                                    defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.windowRunResolution, windowRunResolutionState) }

                                    let bypassWindowRouting = Self.shouldBypassWindowRouting(for: toolName)
                                    let existingMapping = bypassWindowRouting ? nil : await self.connectionWindowMap[connectionID]
                                    chosenID = bypassWindowRouting ? nil : capturedPreResolvedWindowID
                                    let preassigned = await self.preassignedConnections.contains(connectionID)
                                    if let cid = existingMapping {
                                        mcpRoutingLog("Tool=\(toolName) conn=\(connectionID) has existingWindow=\(cid) preassigned=\(preassigned)")
                                    }

                                    // ═══════════════════════════════════════════════════════════════
                                    // PRIORITY 0: _windowID is a strong per-call override
                                    // ═══════════════════════════════════════════════════════════════
                                    // When provided, _windowID always takes precedence, even over
                                    // existing connection mappings. This enables explicit window targeting.
                                    if !bypassWindowRouting, let requestedWindowID = capturedWindowID {
                                        let windowValid = await WindowStatesManager.shared.hasWindowWithMCPEnabled(requestedWindowID)
                                        guard windowValid else {
                                            return Self.toolErrorResult(
                                                rawJSON: capturedRawJSON,
                                                message: Self.invalidWindowSelectionGuidance(
                                                    windowID: requestedWindowID,
                                                    purpose: policy.purpose,
                                                    restrictedTools: policy.restricted
                                                )
                                            )
                                        }

                                        chosenID = requestedWindowID
                                        if existingMapping == nil {
                                            await self.setConnectionWindowMapping(connectionID, windowID: requestedWindowID)
                                            connectionLog("Tool call: bound unassigned connection \(connectionID) to window \(requestedWindowID) via _windowID")
                                        } else if let prev = existingMapping, prev != requestedWindowID {
                                            connectionLog("Tool call: applying per-call _windowID override \(prev) → \(requestedWindowID) for connection \(connectionID) (default binding unchanged)")
                                        } else {
                                            connectionLog("Tool call: routed connection \(connectionID) to window \(requestedWindowID) via _windowID")
                                        }
                                    }

                                    // ═══════════════════════════════════════════════════════════════
                                    // PRIORITY 1: Use existing connection mapping (no override requested)
                                    // ═══════════════════════════════════════════════════════════════
                                    if !bypassWindowRouting, chosenID == nil, let mapped = existingMapping {
                                        chosenID = mapped
                                        mcpRoutingLog("Tool=\(toolName) using existing mapping conn=\(connectionID) window=\(mapped)")
                                    }

                                    // PRIORITY 2: Use clientName to find existing window assignment (for same client, new connection)
                                    if !bypassWindowRouting,
                                       chosenID == nil,
                                       let clientName = await self.clientIdentifier(forConnection: connectionID),
                                       let windowID = await self.reusableWindowForClient(newConnectionID: connectionID, clientName: clientName)
                                    {
                                        chosenID = windowID
                                        await self.setConnectionWindowMapping(connectionID, windowID: windowID)
                                        connectionLog("Tool call: auto-routed connection \(connectionID) to window \(windowID) via clientName '\(clientName)' reuse")
                                    }

                                    // PRIORITY 2b: Same-process live run affinity, then persisted window affinity.
                                    if !bypassWindowRouting,
                                       chosenID == nil,
                                       let clientName = await self.clientIdentifier(forConnection: connectionID)
                                    {
                                        let managerToken = await self.connections[connectionID]?.capabilityToken
                                        let cachedToken = await self.capabilityTokenByConnection[connectionID]
                                        let sessionKey = managerToken ?? cachedToken
                                        mcpRoutingInternalDebugLog("[PRIORITY 2b] client='\(clientName)' managerToken=\(managerToken?.prefix(8) ?? "nil") cachedToken=\(cachedToken?.prefix(8) ?? "nil") sessionKey=\(sessionKey?.prefix(8) ?? "nil")")
                                        if let liveAffinity = await self.preferredLiveRunAffinity(for: clientName, sessionKey: sessionKey) {
                                            chosenID = liveAffinity.windowID
                                            await self.setConnectionWindowMapping(connectionID, windowID: liveAffinity.windowID)
                                            _ = await self.mapConnectionToRunID(
                                                connectionID,
                                                runID: liveAffinity.runID,
                                                windowID: liveAffinity.windowID
                                            )
                                            connectionLog("Tool call: restored live run affinity for connection \(connectionID) → runID \(liveAffinity.runID)")
                                        } else if let preferredWindowID = await self.preferredWindowID(for: clientName, sessionKey: sessionKey) {
                                            chosenID = preferredWindowID
                                            await self.setConnectionWindowMapping(connectionID, windowID: preferredWindowID)
                                            connectionLog("Tool call: auto-routed connection \(connectionID) to window \(preferredWindowID) via persisted routing affinity for client '\(clientName)'")
                                        }
                                    }

                                    // PRIORITY 3: Auto-route to active window when:
                                    // - Currently in single-window mode, OR
                                    // - Connection was established during single-window mode (stays bound even when more windows open)
                                    let connectedDuringSingleWindow: Bool
                                    if let recordedWindowCount = await self.windowCountAtConnectionTime[connectionID] {
                                        connectedDuringSingleWindow = recordedWindowCount == 1
                                    } else if multiWindowModeEffective {
                                        mcpRoutingLog("Auto-routing conn=\(connectionID): connect-time window count unavailable; treating as multi-window")
                                        connectedDuringSingleWindow = false
                                    } else {
                                        connectedDuringSingleWindow = windowCount == 1
                                    }
                                    if !bypassWindowRouting && chosenID == nil && (!multiWindowModeEffective || connectedDuringSingleWindow) {
                                        // Find the window with active MCP tools
                                        let activeWindowID = await WindowStatesManager.shared.firstMCPEnabledWindow()?.windowID
                                        if let activeID = activeWindowID {
                                            let reason = connectedDuringSingleWindow && multiWindowModeEffective
                                                ? "single-window-at-connect"
                                                : "no policy"
                                            mcpRoutingLog("Auto-routing conn=\(connectionID) to active window=\(activeID) (\(reason))")
                                            chosenID = activeID
                                            // Store the mapping for this connection
                                            await self.setConnectionWindowMapping(connectionID, windowID: activeID)
                                        }
                                    }

                                    // Only require explicit window selection when multi-window mode is effectively active.
                                    // bind_context is exempt because it is the public routing/binding entry point.
                                    if !bypassWindowRouting,
                                       multiWindowModeEffective,
                                       chosenID == nil,
                                       !Self.isWindowSelectionExempt(toolName: toolName, args: capturedArguments)
                                    {
                                        return Self.toolErrorResult(
                                            rawJSON: capturedRawJSON,
                                            message: Self.multiWindowSelectionGuidance(
                                                purpose: policy.purpose,
                                                restrictedTools: policy.restricted
                                            )
                                        )
                                    }

                                    // Log the call - one notice for the call, debug for the end
                                    windowStr = chosenID.map(String.init) ?? "-"
                                    let logName = (originalName == toolName) ? toolName : "\(originalName)→\(toolName)"
                                    connectionLog("Tool call: \(logName) [conn=\(connectionID) window=\(windowStr)]")

                                    // Notify enhanced tool event observers using the connection's resolved run mapping.
                                    // Coordination/app-wide routing tools run before a stable window/run context may
                                    // exist, so avoid re-entering MainActor run lookup on that hot path.
                                    observerRunIDForCallbacksFinal = Self.shouldBypassWindowRouting(for: toolName)
                                        ? nil
                                        : await self.runIDForConnection(connectionID)
                                }
                                let mutationAdmissionLease: MCPToolResourceAdmissionController.Lease?
                                if admissionClass == .exclusive {
                                    let mutationResource: MCPToolResourceAdmissionController.Resource
                                    if MCPGlobalToolName.orderedToolNames.contains(toolName) {
                                        mutationResource = .appWide
                                    } else if let chosenID {
                                        mutationResource = .window(chosenID)
                                    } else {
                                        return Self.executionContractToolErrorResult(
                                            rawJSON: capturedRawJSON,
                                            code: "tool_execution_mutation_resource_unresolved",
                                            message: "The exclusive tool '\(toolName)' has no resolved window resource."
                                        )
                                    }
                                    do {
                                        mutationAdmissionLease = try await self.mutationAdmissionController.acquire(mutationResource)
                                    } catch {
                                        return Self.executionContractToolErrorResult(
                                            rawJSON: capturedRawJSON,
                                            code: "tool_execution_connection_terminal",
                                            message: "The MCP connection closed while waiting for exclusive resource admission."
                                        )
                                    }
                                } else {
                                    mutationAdmissionLease = nil
                                }
                                defer { mutationAdmissionLease?.release() }

                                let smallReadAdmissionLease: MCPToolResourceAdmissionController.Lease?
                                if admissionClass == .smallRead {
                                    guard let chosenID else {
                                        return Self.executionContractToolErrorResult(
                                            rawJSON: capturedRawJSON,
                                            code: "tool_execution_read_resource_unresolved",
                                            message: "The small-read tool '\(toolName)' has no resolved window/store resource."
                                        )
                                    }
                                    do {
                                        smallReadAdmissionLease = try await self.smallReadAdmissionController.acquire(.window(chosenID))
                                    } catch {
                                        return Self.executionContractToolErrorResult(
                                            rawJSON: capturedRawJSON,
                                            code: "tool_execution_connection_terminal",
                                            message: "The MCP connection closed while waiting for window/store read admission."
                                        )
                                    }
                                } else {
                                    smallReadAdmissionLease = nil
                                }
                                defer { smallReadAdmissionLease?.release() }

                                let resourceAdmissionWindowID = chosenID
                                let resourceAdmissionOwner = MCPGlobalToolName.orderedToolNames.contains(toolName)
                                    ? "app_wide"
                                    : resourceAdmissionWindowID.map { "window:\($0)" }
                                @Sendable func releaseResourceAdmissionLeases(outcome: String) {
                                    let releasedMutation = mutationAdmissionLease?.release() ?? false
                                    let releasedSmallRead = smallReadAdmissionLease?.release() ?? false
                                    guard releasedMutation || releasedSmallRead else { return }
                                    EditFlowPerf.lifecycleEvent(
                                        EditFlowPerf.Lifecycle.MCPToolCall.resourceAdmissionReleased,
                                        correlation: lifecycleCorrelation,
                                        EditFlowPerf.Dimensions(
                                            toolName: toolName,
                                            outcome: outcome,
                                            windowID: resourceAdmissionWindowID,
                                            ownerResource: resourceAdmissionOwner,
                                            permitActive: true,
                                            publicationPending: true,
                                            terminalBarrier: false
                                        )
                                    )
                                }

                                @Sendable func releaseResourceAdmissionLeasesAfterProviderError(_ error: Error) {
                                    if case MCPToolExecutionWatchdogError.cleanupUnresponsive = error {
                                        return
                                    }
                                    releaseResourceAdmissionLeases(outcome: "provider_error")
                                }

                                let toolCardOwnershipLease: MCPToolCardOwnershipLedger.Lease?
                                if let runID = observerRunIDForCallbacksFinal, let chosenID {
                                    guard let lease = self.toolCardOwnershipLedger.begin(
                                        windowID: chosenID,
                                        runID: runID,
                                        invocationID: invocationID,
                                        connectionID: connectionID,
                                        toolName: toolName
                                    ) else {
                                        return Self.executionContractToolErrorResult(
                                            rawJSON: capturedRawJSON,
                                            code: "tool_card_ownership_conflict",
                                            message: "Duplicate tool-card ownership was rejected for invocation \(invocationID.uuidString)."
                                        )
                                    }
                                    toolCardOwnershipLease = lease
                                } else {
                                    toolCardOwnershipLease = nil
                                }
                                defer { toolCardOwnershipLease?.release() }

                                if let runID = observerRunIDForCallbacksFinal {
                                    let observerState = EditFlowPerf.begin(
                                        EditFlowPerf.Stage.MCPToolCall.observerCallbacks,
                                        EditFlowPerf.Dimensions(toolName: toolName)
                                    )
                                    let eventObserverCount = await self.fireToolCalledObservers(runID: runID, invocationID: invocationID, toolName: toolName, args: capturedArguments)
                                    EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.observerCallbacks, observerState)
                                    #if DEBUG
                                        if toolName == "agent_run" {
                                            print("[ACPAgentRunToolTracking] MCP observer call tool=\(toolName) conn=\(connectionID.uuidString) runID=\(runID.uuidString) invocation=\(invocationID.uuidString) eventObservers=\(eventObserverCount)")
                                        }
                                    #endif
                                } else {
                                    if MCPIntegrationHelper.isRepoPromptToolNameAfterNormalization(toolName) {
                                        mcpToolTrackingDiagnostic(
                                            "MCP observer call skipped no runID conn=\(connectionID.uuidString) " +
                                                "tool=\(toolName) invocation=\(invocationID.uuidString)"
                                        )
                                    }
                                    #if DEBUG
                                        if toolName == "agent_run" {
                                            print("[ACPAgentRunToolTracking] MCP observer call skipped no-run tool=\(toolName) conn=\(connectionID.uuidString)")
                                        }
                                    #endif
                                }

                                let shouldTrackToolOwnership = await EditFlowPerf.measure(
                                    EditFlowPerf.Stage.MCPToolCall.ownershipPurposeResolution,
                                    EditFlowPerf.Dimensions(toolName: toolName)
                                ) {
                                    await self.runPurpose(for: connectionID) != .agentModeRun
                                }

                                // Record value signal for admission fairness and history
                                await EditFlowPerf.measure(
                                    EditFlowPerf.Stage.MCPToolCall.toolCallRecording,
                                    EditFlowPerf.Dimensions(toolName: toolName)
                                ) {
                                    await self.recordToolCall(for: connectionID, toolName: toolName)
                                }
                                defer { connectionLog("CALL end   conn=\(connectionID) tool=\(toolName) window=\(windowStr)") }

                                // ────────────────────────────────────────────────────────
                                // Run-scoped tab rebind fallback on reconnect handovers
                                // ────────────────────────────────────────────────────────
                                let shouldAttemptRunScopedTabRebindFallback = capturedTabID == nil
                                    && observerRunIDForCallbacksFinal != nil
                                    && chosenID != nil
                                    && !Self.shouldSkipPerCallRunScopedTabRebindFallback(
                                        toolName: toolName,
                                        purpose: policy.purpose
                                    )
                                do {
                                    let runScopedTabRebindFallbackState = EditFlowPerf.begin(
                                        EditFlowPerf.Stage.MCPToolCall.runScopedTabRebindFallback,
                                        EditFlowPerf.Dimensions(
                                            toolName: toolName,
                                            outcome: shouldAttemptRunScopedTabRebindFallback ? "attempted" : "skipped"
                                        )
                                    )
                                    defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.runScopedTabRebindFallback, runScopedTabRebindFallbackState) }
                                    if shouldAttemptRunScopedTabRebindFallback,
                                       let runID = observerRunIDForCallbacksFinal,
                                       let windowID = chosenID
                                    {
                                        let clientName = await self.clientIdentifier(forConnection: connectionID)
                                        _ = await self.ensureTabBoundForRunIfPossible(
                                            connectionID: connectionID,
                                            clientName: clientName,
                                            runID: runID,
                                            windowID: windowID
                                        )
                                    }
                                }

                                // ────────────────────────────────────────────────────────
                                // Legacy compatibility: sticky tab binding via hidden _tabID for unmigrated tools only
                                // ────────────────────────────────────────────────────────
                                let shouldAttemptLegacyTabBindingCompatibility = capturedTabID != nil
                                    && !Self.shouldSkipGenericTabBinding(for: toolName)
                                do {
                                    let legacyTabBindingCompatibilityState = EditFlowPerf.begin(
                                        EditFlowPerf.Stage.MCPToolCall.legacyTabBindingCompatibility,
                                        EditFlowPerf.Dimensions(
                                            toolName: toolName,
                                            outcome: shouldAttemptLegacyTabBindingCompatibility ? "attempted" : "skipped"
                                        )
                                    )
                                    defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.legacyTabBindingCompatibility, legacyTabBindingCompatibilityState) }
                                    if shouldAttemptLegacyTabBindingCompatibility, let tabID = capturedTabID {
                                        // Guard: _tabID requires a resolved window
                                        guard let windowID = chosenID else {
                                            let msg = ToolOutputFormatter.operationFailed(
                                                title: "Tab Binding Failed",
                                                issue: "Cannot bind to tab \(tabID.uuidString.prefix(8))... - no window is selected.",
                                                troubleshooting: Self.tabBindingTroubleshooting(
                                                    purpose: policy.purpose,
                                                    restrictedTools: policy.restricted
                                                )
                                            )
                                            return CallTool.Result(content: [.text(text: msg, annotations: nil, _meta: nil)], isError: true)
                                        }

                                        let clientName = await self.clientIdentifier(forConnection: connectionID)

                                        do {
                                            try await MainActor.run {
                                                guard let windowState = WindowStatesManager.shared.window(withID: windowID) else {
                                                    throw MCPError.invalidParams("Window \(windowID) not found")
                                                }
                                                let resolvedWorkspaceID = capturedTabContextHint?.workspaceID
                                                    ?? windowState.workspaceManager.resolveComposeTabRoutingSnapshot(for: tabID)?.workspaceID
                                                    ?? windowState.workspaceManager.activeWorkspace?.id
                                                guard let workspaceID = resolvedWorkspaceID else {
                                                    throw MCPError.invalidParams("No workspace containing tab \(tabID) is available in window \(windowID). Use bind_context op='list' to verify context_id/window routing.")
                                                }
                                                try windowState.mcpServer.bindTabForConnection(
                                                    connectionID: connectionID,
                                                    clientName: clientName,
                                                    tabID: tabID,
                                                    workspaceID: workspaceID,
                                                    windowID: windowID
                                                )
                                            }
                                            await self.setConnectionWindowMapping(connectionID, windowID: windowID)
                                            connectionLog("Tab binding: bound connection \(connectionID) to tab \(tabID) in window \(windowID)")
                                        } catch {
                                            // Tab binding failed - provide detailed error with window context
                                            let shortTabID = tabID.uuidString.prefix(8)
                                            let issue = "Tab \(shortTabID)... not found in window \(windowID)."
                                            let msg = ToolOutputFormatter.operationFailed(
                                                title: "Tab Binding Failed",
                                                issue: issue,
                                                troubleshooting: Self.tabBindingTroubleshooting(
                                                    purpose: policy.purpose,
                                                    restrictedTools: policy.restricted,
                                                    windowID: windowID
                                                )
                                            )
                                            return CallTool.Result(content: [.text(text: msg, annotations: nil, _meta: nil)], isError: true)
                                        }
                                    }
                                }

                                let selectedExecutionContract = MCPToolExecutionContractCatalog.contract(
                                    for: toolName,
                                    arguments: capturedArguments
                                )
                                let executionWatchdogEnvironment = await self.toolExecutionWatchdogEnvironment
                                let executionTraceOrigin = await executionWatchdogEnvironment.now()
                                let handlerPhaseRecorder = MCPToolExecutionHandlerPhaseRecorder(
                                    origin: executionTraceOrigin,
                                    now: { await executionWatchdogEnvironment.now() }
                                )

                                @Sendable func dispatchResolvedProvider(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
                                    guard await self.isCurrentConnectionCallLimiterResolution(
                                        limiterResolution,
                                        connectionID: connectionID
                                    ) else {
                                        throw ToolDispatchAdmissionError.connectionTerminal
                                    }
                                    if let authorization = Self.currentToolDispatchAuthorization {
                                        guard await self.isCurrentToolDispatchAuthorization(authorization) else {
                                            throw ToolDispatchAdmissionError.connectionTerminal
                                        }
                                        if let windowIdentity = authorization.windowIdentity,
                                           await !(self.isCurrentWindowToolDispatchIdentity(windowIdentity))
                                        {
                                            throw ToolDispatchAdmissionError.windowTerminal
                                        }
                                    }
                                    guard let contract = selectedExecutionContract else {
                                        throw MCPToolExecutionDispatchError.missingContract(toolName: toolName)
                                    }

                                    @Sendable func emitExecutionTrace(
                                        _ phase: MCPToolExecutionTraceEvent.Phase,
                                        cancellationRequested: Bool? = nil,
                                        cancellationOutcome: String? = nil,
                                        graceOutcome: String? = nil,
                                        escalationReason: String? = nil
                                    ) async {
                                        let now = await executionWatchdogEnvironment.now()
                                        let handlerPhase = handlerPhaseRecorder.snapshot()
                                        let handlerPhaseAgeMilliseconds = handlerPhase.map {
                                            max(0, now.mcpMilliseconds - executionTraceOrigin.mcpMilliseconds - $0.elapsedMilliseconds)
                                        }
                                        MCPToolExecutionTracer.emit(MCPToolExecutionTraceEvent(
                                            toolName: toolName,
                                            connectionID: connectionID,
                                            invocationID: invocationID,
                                            runID: observerRunIDForCallbacksFinal,
                                            contractKind: contract.kind,
                                            executionDeadlineSeconds: contract.deadline?.mcpSeconds,
                                            cleanupGraceSeconds: contract.cancellationGrace?.mcpSeconds,
                                            phase: phase,
                                            elapsedMilliseconds: max(0, now.mcpMilliseconds - executionTraceOrigin.mcpMilliseconds),
                                            cancellationRequested: cancellationRequested,
                                            cancellationOutcome: cancellationOutcome,
                                            graceOutcome: graceOutcome,
                                            escalationReason: escalationReason,
                                            handlerPhase: handlerPhase,
                                            handlerPhaseAgeMilliseconds: handlerPhaseAgeMilliseconds
                                        ))
                                    }

                                    await emitExecutionTrace(.contractSelected)
                                    await emitExecutionTrace(.started)
                                    EditFlowPerf.lifecycleEvent(
                                        EditFlowPerf.Lifecycle.MCPToolCall.resolvedProviderBegan,
                                        correlation: lifecycleCorrelation,
                                        EditFlowPerf.Dimensions(toolName: toolName)
                                    )
                                    EditFlowPerf.lifecycleEvent(
                                        EditFlowPerf.Lifecycle.MCPToolCall.publicationOwnershipState,
                                        correlation: lifecycleCorrelation,
                                        EditFlowPerf.Dimensions(
                                            toolName: toolName,
                                            windowID: Self.currentToolDispatchAuthorization?.windowIdentity?.windowID,
                                            runID: observerRunIDForCallbacksFinal?.uuidString,
                                            providerActive: true,
                                            networkScopeActive: Self.currentToolDispatchAuthorization?.windowIdentity != nil,
                                            permitActive: true,
                                            publicationPending: false,
                                            terminalBarrier: false
                                        )
                                    )

                                    let tracedOperation: @Sendable () async throws -> Value = {
                                        do {
                                            guard await self.isCurrentConnectionCallLimiterResolution(
                                                limiterResolution,
                                                connectionID: connectionID
                                            ) else {
                                                throw ToolDispatchAdmissionError.connectionTerminal
                                            }
                                            if let authorization = Self.currentToolDispatchAuthorization {
                                                guard await self.isCurrentToolDispatchAuthorization(authorization) else {
                                                    throw ToolDispatchAdmissionError.connectionTerminal
                                                }
                                                if let windowIdentity = authorization.windowIdentity,
                                                   await !(self.isCurrentWindowToolDispatchIdentity(windowIdentity))
                                                {
                                                    throw ToolDispatchAdmissionError.windowTerminal
                                                }
                                            }
                                            let value = try await MCPToolExecutionHandlerPhaseContext.$recorder.withValue(handlerPhaseRecorder) {
                                                try await EditFlowPerf.measure(
                                                    EditFlowPerf.Stage.MCPToolCall.resolvedProviderDispatch,
                                                    EditFlowPerf.Dimensions(toolName: toolName),
                                                    operation: operation
                                                )
                                            }
                                            await emitExecutionTrace(.handlerCompleted, cancellationOutcome: "success")
                                            EditFlowPerf.lifecycleEvent(
                                                EditFlowPerf.Lifecycle.MCPToolCall.resolvedProviderEnded,
                                                correlation: lifecycleCorrelation,
                                                EditFlowPerf.Dimensions(toolName: toolName, outcome: "success")
                                            )
                                            EditFlowPerf.lifecycleEvent(
                                                EditFlowPerf.Lifecycle.MCPToolCall.publicationOwnershipState,
                                                correlation: lifecycleCorrelation,
                                                EditFlowPerf.Dimensions(
                                                    toolName: toolName,
                                                    outcome: "provider_completed",
                                                    windowID: Self.currentToolDispatchAuthorization?.windowIdentity?.windowID,
                                                    runID: observerRunIDForCallbacksFinal?.uuidString,
                                                    providerActive: false,
                                                    networkScopeActive: Self.currentToolDispatchAuthorization?.windowIdentity != nil,
                                                    permitActive: true,
                                                    publicationPending: true,
                                                    terminalBarrier: false
                                                )
                                            )
                                            return value
                                        } catch {
                                            let outcome = MCPToolExecutionCancelledError.matches(error) ? "cancelled" : "error"
                                            await emitExecutionTrace(.handlerCompleted, cancellationOutcome: outcome)
                                            EditFlowPerf.lifecycleEvent(
                                                EditFlowPerf.Lifecycle.MCPToolCall.resolvedProviderEnded,
                                                correlation: lifecycleCorrelation,
                                                EditFlowPerf.Dimensions(toolName: toolName, outcome: outcome)
                                            )
                                            EditFlowPerf.lifecycleEvent(
                                                EditFlowPerf.Lifecycle.MCPToolCall.publicationOwnershipState,
                                                correlation: lifecycleCorrelation,
                                                EditFlowPerf.Dimensions(
                                                    toolName: toolName,
                                                    outcome: outcome,
                                                    windowID: Self.currentToolDispatchAuthorization?.windowIdentity?.windowID,
                                                    runID: observerRunIDForCallbacksFinal?.uuidString,
                                                    providerActive: false,
                                                    networkScopeActive: Self.currentToolDispatchAuthorization?.windowIdentity != nil,
                                                    permitActive: true,
                                                    publicationPending: true,
                                                    terminalBarrier: false
                                                )
                                            )
                                            throw error
                                        }
                                    }

                                    switch contract {
                                    case let .bounded(deadline, cancellationGrace):
                                        do {
                                            return try await MCPToolExecutionWatchdog.execute(
                                                deadline: deadline,
                                                cancellationGrace: cancellationGrace,
                                                environment: executionWatchdogEnvironment,
                                                onEvent: { event in
                                                    switch event {
                                                    case .deadlineExpired:
                                                        await emitExecutionTrace(.deadlineExpired)
                                                    case .cancellationRequested:
                                                        await emitExecutionTrace(.cancellationRequested, cancellationRequested: true)
                                                    case let .settledDuringGrace(settlement):
                                                        await emitExecutionTrace(
                                                            .settledDuringGrace,
                                                            cancellationRequested: true,
                                                            cancellationOutcome: settlement.rawValue,
                                                            graceOutcome: "settled"
                                                        )
                                                    case .cleanupGraceExpired:
                                                        await emitExecutionTrace(
                                                            .cleanupGraceExpired,
                                                            cancellationRequested: true,
                                                            graceOutcome: "expired",
                                                            escalationReason: "handler_ignored_cancellation"
                                                        )
                                                    }
                                                },
                                                operation: tracedOperation
                                            )
                                        } catch MCPToolExecutionWatchdogError.cleanupUnresponsive {
                                            await emitExecutionTrace(
                                                .connectionForceDisconnectRequested,
                                                cancellationRequested: true,
                                                graceOutcome: "expired",
                                                escalationReason: "handler_ignored_cancellation"
                                            )
                                            throw MCPToolExecutionWatchdogError.cleanupUnresponsive
                                        }
                                    case .longSynchronousCancellable,
                                         .lifecycleManagedCancellable,
                                         .interactiveCancellable,
                                         .workspaceLifecycleCancellable:
                                        return try await tracedOperation()
                                    }
                                }

                                @Sendable func handlerResult(_ result: CallTool.Result, outcome: String) -> CallTool.Result {
                                    EditFlowPerf.lifecycleEvent(
                                        EditFlowPerf.Lifecycle.MCPToolCall.handlerResultReady,
                                        correlation: lifecycleCorrelation,
                                        EditFlowPerf.Dimensions(toolName: toolName, outcome: outcome)
                                    )
                                    MCPResponseDeliveryTracer.emit(MCPResponseDeliveryTraceEvent(
                                        layer: "app_tool_handler",
                                        phase: "handler_result_ready",
                                        connectionID: resolvedRequestIdentity?.connectionID ?? connectionID.uuidString,
                                        connectionGeneration: resolvedRequestIdentity?.connectionGeneration,
                                        method: "tools/call",
                                        tool: toolName,
                                        invocationID: invocationID.uuidString,
                                        lifecycleState: outcome,
                                        requestOrdinal: resolvedRequestIdentity?.requestOrdinal,
                                        requestIdentity: resolvedRequestIdentity,
                                        providerActive: false,
                                        networkScopeActive: Self.currentToolDispatchAuthorization?.windowIdentity != nil,
                                        permitActive: true,
                                        publicationPending: true,
                                        terminalBarrier: false
                                    ))
                                    return EditFlowPerf.measure(
                                        EditFlowPerf.Stage.MCPToolCall.handlerResultHandoff,
                                        EditFlowPerf.Dimensions(toolName: toolName, outcome: outcome)
                                    ) {
                                        result
                                    }
                                }

                                @Sendable func executionContractFailureResult(
                                    for error: Error,
                                    context: String
                                ) async -> CallTool.Result? {
                                    let code: String
                                    let message: String
                                    let outcome: String
                                    let shouldForceDisconnect: Bool
                                    let selectedDeadlineDescription: String = {
                                        guard let seconds = selectedExecutionContract?.deadline?.mcpSeconds else {
                                            return "declared"
                                        }
                                        if seconds.rounded() == seconds {
                                            return String(Int(seconds))
                                        }
                                        return seconds.formatted()
                                    }()

                                    switch error {
                                    case ToolDispatchAdmissionError.connectionTerminal:
                                        code = "tool_execution_connection_terminal"
                                        message = "The MCP connection is closing."
                                        outcome = "connectionTerminal"
                                        shouldForceDisconnect = false
                                    case ToolDispatchAdmissionError.windowTerminal:
                                        code = "tool_execution_window_terminal"
                                        message = "The selected window is closing or no longer owns this tool catalog."
                                        outcome = "windowTerminal"
                                        shouldForceDisconnect = false
                                    case let MCPToolExecutionDispatchError.missingContract(missingToolName):
                                        code = "tool_execution_contract_missing"
                                        message = "No declared execution contract exists for MCP tool '\(missingToolName)'."
                                        outcome = "executionContractMissing"
                                        shouldForceDisconnect = false
                                    case let MCPToolExecutionWatchdogError.executionTimedOut(settlement):
                                        code = "tool_execution_timeout"
                                        message = "Tool '\(toolName)' exceeded its \(selectedDeadlineDescription)-second execution contract and settled as \(settlement.rawValue) during cancellation grace."
                                        outcome = "executionTimeout"
                                        shouldForceDisconnect = false
                                    case MCPToolExecutionWatchdogError.cleanupUnresponsive:
                                        code = "tool_execution_cleanup_unresponsive"
                                        message = "Tool '\(toolName)' exceeded its \(selectedDeadlineDescription)-second execution contract and did not stop during cancellation grace. The MCP connection was force-disconnected."
                                        outcome = "executionCleanupUnresponsive"
                                        shouldForceDisconnect = true
                                    default:
                                        return nil
                                    }

                                    log.error("MCP execution contract failure tool=\(toolName) context=\(context) code=\(code)")
                                    let errorJSON = ToolOutputFormatter.rawJSONString(.object([
                                        "code": .string(code),
                                        "error": .string(message),
                                        "tool": .string(toolName)
                                    ]))
                                    if let runID = await self.toolTrackingRunIDForCompletion(
                                        callTimeRunID: observerRunIDForCallbacksFinal,
                                        connectionID: connectionID,
                                        toolName: toolName,
                                        invocationID: invocationID,
                                        context: "\(context) execution contract failure"
                                    ) {
                                        _ = await self.fireToolCompletedObservers(
                                            runID: runID,
                                            invocationID: invocationID,
                                            toolName: toolName,
                                            args: nil,
                                            resultJSON: errorJSON,
                                            isError: true
                                        )
                                    }

                                    let result = Self.executionContractToolErrorResult(
                                        rawJSON: capturedRawJSON,
                                        code: code,
                                        message: message
                                    )
                                    if shouldForceDisconnect {
                                        let abortNow = await executionWatchdogEnvironment.now()
                                        let handlerPhase = handlerPhaseRecorder.snapshot()
                                        let handlerPhaseAgeMilliseconds = handlerPhase.map {
                                            max(0, abortNow.mcpMilliseconds - executionTraceOrigin.mcpMilliseconds - $0.elapsedMilliseconds)
                                        }
                                        await self.abortConnectionForExecutionWatchdog(
                                            connectionID,
                                            toolName: toolName,
                                            invocationID: invocationID,
                                            elapsedMilliseconds: max(0, abortNow.mcpMilliseconds - executionTraceOrigin.mcpMilliseconds),
                                            handlerPhase: handlerPhase,
                                            handlerPhaseAgeMilliseconds: handlerPhaseAgeMilliseconds
                                        )
                                        // The transport is already severed. Deliberately skip handlerResult so
                                        // execution-completion tracing cannot be mistaken for response delivery.
                                        return result
                                    }
                                    return handlerResult(result, outcome: outcome)
                                }

                                let serviceToolLookupState = EditFlowPerf.begin(
                                    EditFlowPerf.Stage.MCPToolCall.serviceToolLookup,
                                    EditFlowPerf.Dimensions(toolName: toolName)
                                )
                                for service in allServices {
                                    // App-wide coordination tools have a single owning service. Avoid probing
                                    // unrelated window-scoped services for their tool lists during startup,
                                    // because some of those lists hop through UI/window state.
                                    if toolName == "bind_context", !(service is WindowRoutingService) { continue }
                                    if toolName == AppSettingsMCPService.toolName, !(service is AppSettingsMCPService) { continue }

                                    let wsSvc = service as? WindowScopedService

                                    // Skip window-scoped services that don't match this connection
                                    if let wsSvc, windowCount > 1 {
                                        guard let wID = chosenID, wID == wsSvc.windowID else { continue }
                                    }

                                    // Get the tool definition (need schema for window_id injection)
                                    connectionLog("tools/call \(toolName): inspecting service \(String(describing: type(of: service)))")
                                    #if DEBUG || EDIT_FLOW_PERF
                                        let serviceToolsAwaitState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupServiceToolsAwait)
                                    #endif
                                    let serviceTools = await service.tools
                                    #if DEBUG || EDIT_FLOW_PERF
                                        EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupServiceToolsAwait, serviceToolsAwaitState)
                                    #endif
                                    connectionLog("tools/call \(toolName): service \(String(describing: type(of: service))) exposes \(serviceTools.count) tools")
                                    #if DEBUG || EDIT_FLOW_PERF
                                        let toolDefinitionScanState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupToolDefinitionScan)
                                    #endif
                                    guard let toolDef = serviceTools.first(where: { $0.name == toolName }) else {
                                        #if DEBUG || EDIT_FLOW_PERF
                                            EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupToolDefinitionScan, toolDefinitionScanState)
                                        #endif
                                        continue
                                    }
                                    #if DEBUG || EDIT_FLOW_PERF
                                        EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupToolDefinitionScan, toolDefinitionScanState)
                                    #endif
                                    connectionLog("tools/call \(toolName): dispatching via service \(String(describing: type(of: service))) windowScoped=\(wsSvc != nil)")

                                    // Inject window_id from routing if tool schema declares it and caller didn't provide it.
                                    // bind_context manages its own window_id semantics and must not be auto-injected.
                                    let effectiveArgs: [String: Value]
                                    let effectiveArgsForFormatter: [String: Value]
                                    if Self.shouldAutoInjectPublicWindowID(for: toolName) {
                                        #if DEBUG || EDIT_FLOW_PERF
                                            let publicWindowIDInjectionState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupPublicWindowIDInjection)
                                        #endif
                                        let routingWindowID: Int? = {
                                            if let wsSvc {
                                                return capturedWindowID ?? chosenID ?? wsSvc.windowID
                                            }
                                            return capturedWindowID ?? chosenID
                                        }()
                                        let selectedSchemaDeclaresWindowID = routingWindowID != nil
                                            && (
                                                capturedArguments["window_id"] == nil
                                                    || capturedArgsForFormatter["window_id"] == nil
                                            )
                                            && self.schemaDeclaresWindowID(schema: toolDef.inputSchema)
                                        effectiveArgs = self.injectWindowIDIfNeeded(
                                            schemaDeclaresWindowID: selectedSchemaDeclaresWindowID,
                                            routingWindowID: routingWindowID,
                                            args: capturedArguments
                                        )
                                        effectiveArgsForFormatter = self.injectWindowIDIfNeeded(
                                            schemaDeclaresWindowID: selectedSchemaDeclaresWindowID,
                                            routingWindowID: routingWindowID,
                                            args: capturedArgsForFormatter
                                        )
                                        #if DEBUG || EDIT_FLOW_PERF
                                            EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupPublicWindowIDInjection, publicWindowIDInjectionState)
                                        #endif
                                    } else {
                                        effectiveArgs = capturedArguments
                                        effectiveArgsForFormatter = capturedArgsForFormatter
                                    }
                                    EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookup, serviceToolLookupState)
                                    endPermitPreDispatchEnvelopeIfNeeded()

                                    let resolvedOperation: @Sendable () async throws -> Value = {
                                        #if DEBUG
                                            if let operation = await self.debugResolvedToolOperationOverrides[toolName] {
                                                return try await operation()
                                            }
                                        #endif
                                        return try await toolDef.callAsFunction(effectiveArgs)
                                    }

                                    // Now dispatch. If window-scoped, wrap in ownership scope (fallback to service window).
                                    if let wsSvc {
                                        let ownershipWindowID = chosenID ?? wsSvc.windowID
                                        let catalogServiceIdentity = ObjectIdentifier(wsSvc as AnyObject)
                                        guard let windowDispatchIdentity = await self.captureWindowToolDispatchIdentity(
                                            windowID: ownershipWindowID,
                                            catalogServiceIdentity: catalogServiceIdentity
                                        ) else {
                                            return Self.executionContractToolErrorResult(
                                                rawJSON: capturedRawJSON,
                                                code: "tool_execution_window_terminal",
                                                message: "The selected window is closing or no longer owns this tool catalog."
                                            )
                                        }
                                        let dispatchAuthorization = await self.toolDispatchAuthorization(
                                            connectionID: connectionID,
                                            resolution: limiterResolution,
                                            windowIdentity: windowDispatchIdentity
                                        )
                                        do {
                                            return try await self.withWindowToolOwnership(
                                                windowID: ownershipWindowID,
                                                connectionID: connectionID,
                                                toolName: toolName,
                                                connectionAuthorization: dispatchAuthorization,
                                                windowIdentity: windowDispatchIdentity,
                                                recordScope: shouldTrackToolOwnership
                                            ) {
                                                try await Self.$currentToolDispatchAuthorization.withValue(dispatchAuthorization) {
                                                    let value = try await EditFlowPerf.measure(
                                                        EditFlowPerf.Stage.MCPToolCall.dispatch,
                                                        EditFlowPerf.Dimensions(toolName: toolName)
                                                    ) {
                                                        try await dispatchResolvedProvider(resolvedOperation)
                                                    }
                                                    releaseResourceAdmissionLeases(outcome: "provider_success")
                                                    let permitPostDispatchEnvelopeState = EditFlowPerf.begin(
                                                        EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope,
                                                        EditFlowPerf.Dimensions(toolName: toolName, outcome: "success")
                                                    )
                                                    defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope, permitPostDispatchEnvelopeState) }

                                                    #if DEBUG
                                                        await self.debugBeforeToolResultFormattingForTesting?(connectionID, toolName)
                                                    #endif
                                                    // Build well‑structured, human‑readable content blocks for the result
                                                    let contentBlocks = EditFlowPerf.measure(
                                                        EditFlowPerf.Stage.MCPToolCall.formatResult,
                                                        EditFlowPerf.Dimensions(toolName: toolName)
                                                    ) {
                                                        Self.formatToolResult(
                                                            toolName: toolName,
                                                            args: effectiveArgsForFormatter,
                                                            value: value
                                                        )
                                                    }
                                                    EditFlowPerf.lifecycleEvent(
                                                        EditFlowPerf.Lifecycle.MCPToolCall.formatResultReturned,
                                                        EditFlowPerf.Dimensions(toolName: toolName)
                                                    )

                                                    // Fire completion observer with result for detailed UI rendering
                                                    #if DEBUG
                                                        await self.debugBeforeToolCompletionObserversForTesting?(connectionID, toolName)
                                                    #endif
                                                    await EditFlowPerf.measure(
                                                        EditFlowPerf.Stage.MCPToolCall.completionObservers,
                                                        EditFlowPerf.Dimensions(toolName: toolName)
                                                    ) {
                                                        if let runID = await self.toolTrackingRunIDForCompletion(callTimeRunID: observerRunIDForCallbacksFinal, connectionID: connectionID, toolName: toolName, invocationID: invocationID, context: "window-scoped success") {
                                                            let resultJSON = EditFlowPerf.measure(
                                                                EditFlowPerf.Stage.MCPToolCall.completionObserverResultEncoding,
                                                                EditFlowPerf.Dimensions(toolName: toolName)
                                                            ) {
                                                                ToolOutputFormatter.rawJSONString(value)
                                                            }
                                                            let eventObserverCount = await EditFlowPerf.measure(
                                                                EditFlowPerf.Stage.MCPToolCall.completionObserverCallbacks,
                                                                EditFlowPerf.Dimensions(toolName: toolName)
                                                            ) {
                                                                await self.fireToolCompletedObservers(runID: runID, invocationID: invocationID, toolName: toolName, args: capturedArguments, resultJSON: resultJSON, isError: false)
                                                            }
                                                            #if DEBUG
                                                                if toolName == "agent_run" {
                                                                    print("[ACPAgentRunToolTracking] MCP observer completion tool=\(toolName) conn=\(connectionID.uuidString) runID=\(runID.uuidString) invocation=\(invocationID.uuidString) eventObservers=\(eventObserverCount) isError=false resultChars=\(resultJSON.count)")
                                                                }
                                                            #endif
                                                        }
                                                    }
                                                    EditFlowPerf.lifecycleEvent(
                                                        EditFlowPerf.Lifecycle.MCPToolCall.completionObserverReturned,
                                                        EditFlowPerf.Dimensions(toolName: toolName, status: "success")
                                                    )

                                                    // Note: context_builder caller termination is NOT done here.
                                                    // The spawned agent connection is terminated by ContextBuilderAgentViewModel
                                                    // when the run completes. This prevents killing the host MCP client
                                                    // (e.g., Claude Desktop) that invoked context_builder.

                                                    return handlerResult(
                                                        CallTool.Result(content: contentBlocks, isError: false),
                                                        outcome: "success"
                                                    )
                                                }
                                            }
                                        } catch {
                                            releaseResourceAdmissionLeasesAfterProviderError(error)
                                            if let failure = await executionContractFailureResult(
                                                for: error,
                                                context: "window-scoped"
                                            ) {
                                                return failure
                                            }
                                            let permitPostDispatchEnvelopeState = EditFlowPerf.begin(
                                                EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope,
                                                EditFlowPerf.Dimensions(toolName: toolName, outcome: "dispatchError")
                                            )
                                            defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope, permitPostDispatchEnvelopeState) }
                                            log.error("Error executing tool \(toolName): \(error.localizedDescription)")
                                            await EditFlowPerf.measure(
                                                EditFlowPerf.Stage.MCPToolCall.completionObservers,
                                                EditFlowPerf.Dimensions(toolName: toolName)
                                            ) {
                                                if let runID = await self.toolTrackingRunIDForCompletion(callTimeRunID: observerRunIDForCallbacksFinal, connectionID: connectionID, toolName: toolName, invocationID: invocationID, context: "window-scoped error") {
                                                    let errorJSON = EditFlowPerf.measure(
                                                        EditFlowPerf.Stage.MCPToolCall.completionObserverResultEncoding,
                                                        EditFlowPerf.Dimensions(toolName: toolName)
                                                    ) {
                                                        ToolOutputFormatter.rawJSONString(.object(["error": .string(error.localizedDescription), "tool": .string(toolName)]))
                                                    }
                                                    let eventObserverCount = await EditFlowPerf.measure(
                                                        EditFlowPerf.Stage.MCPToolCall.completionObserverCallbacks,
                                                        EditFlowPerf.Dimensions(toolName: toolName)
                                                    ) {
                                                        await self.fireToolCompletedObservers(runID: runID, invocationID: invocationID, toolName: toolName, args: capturedArguments, resultJSON: errorJSON, isError: true)
                                                    }
                                                    #if DEBUG
                                                        if toolName == "agent_run" {
                                                            print("[ACPAgentRunToolTracking] MCP observer completion tool=\(toolName) conn=\(connectionID.uuidString) runID=\(runID.uuidString) invocation=\(invocationID.uuidString) eventObservers=\(eventObserverCount) isError=true resultChars=\(errorJSON.count)")
                                                        }
                                                    #endif
                                                }
                                            }
                                            EditFlowPerf.lifecycleEvent(
                                                EditFlowPerf.Lifecycle.MCPToolCall.completionObserverReturned,
                                                EditFlowPerf.Dimensions(toolName: toolName, status: "dispatchError")
                                            )
                                            return handlerResult(
                                                Self.toolErrorResult(rawJSON: capturedRawJSON, message: "Error: \(error)"),
                                                outcome: "dispatchError"
                                            )
                                        }
                                    } else {
                                        // Not window-scoped → no ownership tracking needed
                                        do {
                                            let value = try await EditFlowPerf.measure(
                                                EditFlowPerf.Stage.MCPToolCall.dispatch,
                                                EditFlowPerf.Dimensions(toolName: toolName)
                                            ) {
                                                try await dispatchResolvedProvider(resolvedOperation)
                                            }
                                            releaseResourceAdmissionLeases(outcome: "provider_success")
                                            let permitPostDispatchEnvelopeState = EditFlowPerf.begin(
                                                EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope,
                                                EditFlowPerf.Dimensions(toolName: toolName, outcome: "success")
                                            )
                                            defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope, permitPostDispatchEnvelopeState) }

                                            #if DEBUG
                                                await self.debugBeforeToolResultFormattingForTesting?(connectionID, toolName)
                                            #endif
                                            // Build well‑structured, human‑readable content blocks for the result
                                            let contentBlocks = EditFlowPerf.measure(
                                                EditFlowPerf.Stage.MCPToolCall.formatResult,
                                                EditFlowPerf.Dimensions(toolName: toolName)
                                            ) {
                                                Self.formatToolResult(
                                                    toolName: toolName,
                                                    args: effectiveArgsForFormatter,
                                                    value: value
                                                )
                                            }
                                            EditFlowPerf.lifecycleEvent(
                                                EditFlowPerf.Lifecycle.MCPToolCall.formatResultReturned,
                                                EditFlowPerf.Dimensions(toolName: toolName)
                                            )

                                            // Fire completion observer with result for detailed UI rendering
                                            #if DEBUG
                                                await self.debugBeforeToolCompletionObserversForTesting?(connectionID, toolName)
                                            #endif
                                            await EditFlowPerf.measure(
                                                EditFlowPerf.Stage.MCPToolCall.completionObservers,
                                                EditFlowPerf.Dimensions(toolName: toolName)
                                            ) {
                                                if let runID = await self.toolTrackingRunIDForCompletion(callTimeRunID: observerRunIDForCallbacksFinal, connectionID: connectionID, toolName: toolName, invocationID: invocationID, context: "global success") {
                                                    let resultJSON = EditFlowPerf.measure(
                                                        EditFlowPerf.Stage.MCPToolCall.completionObserverResultEncoding,
                                                        EditFlowPerf.Dimensions(toolName: toolName)
                                                    ) {
                                                        ToolOutputFormatter.rawJSONString(value)
                                                    }
                                                    let eventObserverCount = await EditFlowPerf.measure(
                                                        EditFlowPerf.Stage.MCPToolCall.completionObserverCallbacks,
                                                        EditFlowPerf.Dimensions(toolName: toolName)
                                                    ) {
                                                        await self.fireToolCompletedObservers(runID: runID, invocationID: invocationID, toolName: toolName, args: capturedArguments, resultJSON: resultJSON, isError: false)
                                                    }
                                                    #if DEBUG
                                                        if toolName == "agent_run" {
                                                            print("[ACPAgentRunToolTracking] MCP observer completion tool=\(toolName) conn=\(connectionID.uuidString) runID=\(runID.uuidString) invocation=\(invocationID.uuidString) eventObservers=\(eventObserverCount) isError=false resultChars=\(resultJSON.count)")
                                                        }
                                                    #endif
                                                }
                                            }
                                            EditFlowPerf.lifecycleEvent(
                                                EditFlowPerf.Lifecycle.MCPToolCall.completionObserverReturned,
                                                EditFlowPerf.Dimensions(toolName: toolName, status: "success")
                                            )

                                            // Note: context_builder caller termination is NOT done here.
                                            // See comment in window-scoped branch above.

                                            return handlerResult(
                                                CallTool.Result(content: contentBlocks, isError: false),
                                                outcome: "success"
                                            )
                                        } catch {
                                            releaseResourceAdmissionLeasesAfterProviderError(error)
                                            if let failure = await executionContractFailureResult(
                                                for: error,
                                                context: "global"
                                            ) {
                                                return failure
                                            }
                                            let permitPostDispatchEnvelopeState = EditFlowPerf.begin(
                                                EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope,
                                                EditFlowPerf.Dimensions(toolName: toolName, outcome: "dispatchError")
                                            )
                                            defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope, permitPostDispatchEnvelopeState) }
                                            log.error("Error executing tool \(toolName): \(error.localizedDescription)")
                                            await EditFlowPerf.measure(
                                                EditFlowPerf.Stage.MCPToolCall.completionObservers,
                                                EditFlowPerf.Dimensions(toolName: toolName)
                                            ) {
                                                if let runID = await self.toolTrackingRunIDForCompletion(callTimeRunID: observerRunIDForCallbacksFinal, connectionID: connectionID, toolName: toolName, invocationID: invocationID, context: "global error") {
                                                    let errorJSON = EditFlowPerf.measure(
                                                        EditFlowPerf.Stage.MCPToolCall.completionObserverResultEncoding,
                                                        EditFlowPerf.Dimensions(toolName: toolName)
                                                    ) {
                                                        ToolOutputFormatter.rawJSONString(.object(["error": .string(error.localizedDescription), "tool": .string(toolName)]))
                                                    }
                                                    let eventObserverCount = await EditFlowPerf.measure(
                                                        EditFlowPerf.Stage.MCPToolCall.completionObserverCallbacks,
                                                        EditFlowPerf.Dimensions(toolName: toolName)
                                                    ) {
                                                        await self.fireToolCompletedObservers(runID: runID, invocationID: invocationID, toolName: toolName, args: capturedArguments, resultJSON: errorJSON, isError: true)
                                                    }
                                                    #if DEBUG
                                                        if toolName == "agent_run" {
                                                            print("[ACPAgentRunToolTracking] MCP observer completion tool=\(toolName) conn=\(connectionID.uuidString) runID=\(runID.uuidString) invocation=\(invocationID.uuidString) eventObservers=\(eventObserverCount) isError=true resultChars=\(errorJSON.count)")
                                                        }
                                                    #endif
                                                }
                                            }
                                            EditFlowPerf.lifecycleEvent(
                                                EditFlowPerf.Lifecycle.MCPToolCall.completionObserverReturned,
                                                EditFlowPerf.Dimensions(toolName: toolName, status: "dispatchError")
                                            )
                                            return handlerResult(
                                                Self.toolErrorResult(rawJSON: capturedRawJSON, message: "Error: \(error)"),
                                                outcome: "dispatchError"
                                            )
                                        }
                                    }
                                }

                                EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookup, serviceToolLookupState)
                                endPermitPreDispatchEnvelopeIfNeeded()
                                releaseResourceAdmissionLeases(outcome: "tool_not_found")
                                let permitPostDispatchEnvelopeState = EditFlowPerf.begin(
                                    EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope,
                                    EditFlowPerf.Dimensions(toolName: toolName, outcome: "toolNotFound")
                                )
                                defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope, permitPostDispatchEnvelopeState) }
                                await EditFlowPerf.measure(
                                    EditFlowPerf.Stage.MCPToolCall.completionObservers,
                                    EditFlowPerf.Dimensions(toolName: toolName)
                                ) {
                                    let finalToolNotFoundErrorJSON = EditFlowPerf.measure(
                                        EditFlowPerf.Stage.MCPToolCall.completionObserverResultEncoding,
                                        EditFlowPerf.Dimensions(toolName: toolName)
                                    ) {
                                        ToolOutputFormatter.rawJSONString(.object(["error": .string("Tool not found: \(toolName)"), "tool": .string(toolName)]))
                                    }
                                    if let runID = await self.toolTrackingRunIDForCompletion(callTimeRunID: observerRunIDForCallbacksFinal, connectionID: connectionID, toolName: toolName, invocationID: invocationID, context: "final tool-not-found fallthrough") {
                                        let eventObserverCount = await EditFlowPerf.measure(
                                            EditFlowPerf.Stage.MCPToolCall.completionObserverCallbacks,
                                            EditFlowPerf.Dimensions(toolName: toolName)
                                        ) {
                                            await self.fireToolCompletedObservers(
                                                runID: runID,
                                                invocationID: invocationID,
                                                toolName: toolName,
                                                args: capturedArguments,
                                                resultJSON: finalToolNotFoundErrorJSON,
                                                isError: true
                                            )
                                        }
                                        mcpToolTrackingDiagnostic(
                                            "MCP observer completion final tool-not-found fallthrough conn=\(connectionID.uuidString) " +
                                                "runID=\(runID.uuidString) tool=\(toolName) invocation=\(invocationID.uuidString) " +
                                                "eventObservers=\(eventObserverCount)"
                                        )
                                    }
                                }
                                EditFlowPerf.lifecycleEvent(
                                    EditFlowPerf.Lifecycle.MCPToolCall.completionObserverReturned,
                                    EditFlowPerf.Dimensions(toolName: toolName, status: "toolNotFound")
                                )
                                log.error("Tool not found: \(toolName)")
                                return handlerResult(
                                    Self.toolErrorResult(rawJSON: capturedRawJSON, message: "Tool not found: \(toolName)"),
                                    outcome: "toolNotFound"
                                )
                            } // TabContextHint TaskLocal wrapper
                        } // ConnectionID + LifecycleCorrelation TaskLocal wrapper
                    } // PermitBodyEnvelope wrapper
                } // withPermit wrapper
            } // LimiterEnvelope wrapper
        }
    }

    /// Update the enabled state and notify clients
    func setEnabled(_ enabled: Bool) async {
        // Only do something if the state actually changes
        guard isEnabledState != enabled else { return }

        isEnabledState = enabled
        log.notice("RepoPrompt MCP enabled state changed to: \(enabled)")

        // Notify all connected clients that the tool list has changed
        for (_, connectionManager) in connections {
            Task {
                await connectionManager.notifyToolListChanged()
            }
        }
    }

    /// Notify every connected client that the advertised tool catalogue
    /// has changed (e.g. user enabled/disabled a tool in Settings).
    func broadcastToolListChanged() async {
        connectionLog("Broadcasting ToolListChanged notification to all clients")
        invalidateToolSchemaCache()
        for (connectionID, connectionManager) in connections where !connectionsBeingRemoved.contains(connectionID) {
            Task {
                await connectionManager.notifyToolListChanged()
            }
        }
    }

    // MARK: - Dashboard Snapshot

    /// Creates a snapshot of the current network state for the dashboard UI.
    /// This provides a comprehensive view of all connections and their status.
    /// Connections without identity (haven't completed MCP handshake) are excluded.
    func dashboardSnapshot() async -> NetworkDashboardSnapshot {
        var entries: [ConnectionDashboardEntry] = []
        // Capture ownership and assignment together before this method suspends on connection actors.
        let activeToolScopesSnapshot = activeToolScopesByWindow
        let assignedWindowSnapshot = connectionWindowMap

        for (id, manager) in connections {
            guard !connectionsBeingRemoved.contains(id) else { continue }
            // Use known client name or placeholder for connections still completing handshake
            let admittedName = clientIDByConnection[id]
            let pendingName = pendingConnections[id]
            let clientName = admittedName ?? pendingName ?? "Connecting..."

            if admittedName == nil && pendingName == nil {
                log.warning("Dashboard: Connection \(id) has no client name (admitted=nil, pending=nil)")
            }

            let windowID = assignedWindowSnapshot[id]
            let stats = connectionStats[id]

            // Get connection state
            let rawState = await manager.connectionState()
            let stateSummary: ConnectionStateSummary = switch rawState {
            case .ready: .ready
            case .connecting: .setup
            case .failed: .failed
            case .cancelled: .cancelled
            }

            // Get idle time
            let idle = await manager.secondsSinceLastActivity()
            let hasInFlight = await hasInFlightCalls(for: id)

            // Prefer the newest active scope in the assigned window, then the newest scope anywhere.
            // Preserve the selected scope's actual window so callers never project B onto assigned A.
            let activeToolScope = preferredActiveToolScope(
                connectionID: id,
                assignedWindowID: windowID,
                scopesByWindow: activeToolScopesSnapshot
            )
            let activeToolScopes = activeToolScopesSnapshot.flatMap { windowID, scopes in
                scopes.values.compactMap { scope -> ConnectionDashboardActiveToolScope? in
                    guard scope.connectionID == id else { return nil }
                    return ConnectionDashboardActiveToolScope(
                        windowID: windowID,
                        toolName: scope.toolName,
                        sequence: scope.sequence
                    )
                }
            }.sorted { lhs, rhs in
                if lhs.sequence != rhs.sequence { return lhs.sequence > rhs.sequence }
                if lhs.windowID != rhs.windowID { return lhs.windowID < rhs.windowID }
                return lhs.toolName < rhs.toolName
            }

            // Determine transport type
            let transport: ConnectionTransport = manager.isFilesystemBacked ? .filesystem : .network

            // Get routing metadata (no longer track per-connection remote TCP port)
            let sessionKey = manager.capabilityToken ?? capabilityTokenByConnection[id]

            entries.append(
                ConnectionDashboardEntry(
                    id: id,
                    clientName: clientName,
                    windowID: windowID,
                    transport: transport,
                    state: stateSummary,
                    createdAt: stats?.createdAt ?? Date.distantPast,
                    lastToolCallAt: stats?.lastToolCallAt,
                    totalToolCalls: stats?.totalToolCalls ?? 0,
                    idleSeconds: idle > 0 ? idle : nil,
                    hasInFlightCalls: hasInFlight,
                    activeToolScope: activeToolScope,
                    activeToolScopes: activeToolScopes,
                    sessionKey: sessionKey
                )
            )
        }

        return NetworkDashboardSnapshot(
            isRunning: isRunningState,
            connections: entries.sorted { $0.createdAt < $1.createdAt },
            recentToolCalls: recentToolCallHistory
        )
    }

    // MARK: - Identity Context Debug Inspection

    /// Returns debug snapshots of identity context for all active connections.
    /// Useful for dashboard debugging to understand how identity was derived.
    func identityContextSnapshots() -> [IdentityContextSnapshot] {
        identityContextByConnection.map { connectionID, ctx in
            let source: IdentityContextSnapshot.Source = switch ctx.source {
            case .unknown: .unknown
            case .filesystemMeta: .filesystemMeta
            case .handshake: .handshake
            }

            return IdentityContextSnapshot(
                connectionID: connectionID,
                clientName: ctx.clientName,
                capabilityToken: ctx.capabilityToken,
                source: source,
                hasHandshake: ctx.hasHandshake,
                lastUpdated: ctx.lastUpdated
            )
        }.sorted { $0.lastUpdated < $1.lastUpdated }
    }

    /// Returns identity context for a specific connection, if available.
    func identityContext(for connectionID: UUID) -> IdentityContextSnapshot? {
        guard let ctx = identityContextByConnection[connectionID] else { return nil }

        let source: IdentityContextSnapshot.Source = switch ctx.source {
        case .unknown: .unknown
        case .filesystemMeta: .filesystemMeta
        case .handshake: .handshake
        }

        return IdentityContextSnapshot(
            connectionID: connectionID,
            clientName: ctx.clientName,
            capabilityToken: ctx.capabilityToken,
            source: source,
            hasHandshake: ctx.hasHandshake,
            lastUpdated: ctx.lastUpdated
        )
    }

    /// Returns the verified peer PID for a bootstrap socket connection, if available.
    func peerPID(for connectionID: UUID) async -> Int? {
        guard let connection = connections[connectionID] else { return nil }
        guard let bootstrap = connection as? BootstrapSocketConnectionManager else { return nil }
        return await bootstrap.peerPID()
    }

    /// Update service bindings - no longer needed but kept for compatibility
    func updateServiceBindings(_ newBindings: [String: Binding<Bool>]) async {
        // No-op since we don't use individual service bindings anymore
        // All services are controlled by the master enabled state
    }

    // MARK: - Admission helpers

    private static var emitResourceContent: Bool {
        UserDefaults.standard.bool(forKey: "mcp.emitResourceContent")
    }

    private static func formatToolResult(
        toolName: String,
        args: [String: Value],
        value: Value
    ) -> [MCP.Tool.Content] {
        let emit = Self.emitResourceContent
        return ToolOutputFormatter.buildContentBlocks(
            toolName: toolName,
            args: args,
            result: value,
            emitResources: emit
        )
    }

    /// Extract text content from tool result content blocks for observer callbacks
    static func extractTextFromContentBlocks(_ blocks: [MCP.Tool.Content]) -> String {
        blocks.compactMap { block -> String? in
            switch block {
            case .text(text: let text, annotations: _, _meta: _):
                return text
            default:
                return nil
            }
        }.joined(separator: "\n")
    }

    private static func languageTag(forPath path: String) -> String {
        // Deprecated: use ToolOutputFormatter.languageTag(forPath:) instead
        ToolOutputFormatter.languageTag(forPath: path)
    }

    private static func prettyJSON(_ value: Value) -> String {
        do {
            let encoder = JSONEncoder()
            encoder.userInfo[Ontology.DateTime.timeZoneOverrideKey] = TimeZone.current
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
            let data = try encoder.encode(value)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{}"
        }
    }

    // MARK: - Admission helpers

    private struct DirectAdmissionFence {
        let connectionIdentity: ObjectIdentifier
        let lifecycleGeneration: UInt64
    }

    private func captureDirectAdmissionFence(connectionID: UUID) -> DirectAdmissionFence? {
        guard !connectionsBeingRemoved.contains(connectionID),
              let connection = connections[connectionID],
              let connectionLifecycleGeneration = connectionLifecycleGenerationByID[connectionID],
              isCurrentLifecycle(connectionLifecycleGeneration)
        else { return nil }
        return DirectAdmissionFence(
            connectionIdentity: ObjectIdentifier(connection as AnyObject),
            lifecycleGeneration: connectionLifecycleGeneration
        )
    }

    private func isCurrentDirectAdmission(
        connectionID: UUID,
        fence: DirectAdmissionFence
    ) -> Bool {
        guard !connectionsBeingRemoved.contains(connectionID),
              isCurrentLifecycle(fence.lifecycleGeneration),
              connectionLifecycleGenerationByID[connectionID] == fence.lifecycleGeneration,
              let connection = connections[connectionID]
        else { return false }
        return ObjectIdentifier(connection as AnyObject) == fence.connectionIdentity
    }

    private func removePendingDirectAdmissionIfOwned(
        connectionID: UUID,
        clientID: String,
        fence: DirectAdmissionFence
    ) {
        guard isCurrentDirectAdmission(connectionID: connectionID, fence: fence),
              pendingConnections[connectionID] == clientID
        else { return }
        pendingConnections.removeValue(forKey: connectionID)
    }

    func tryReserveConnectionSlot(connectionID: UUID, clientID: String) async -> Bool {
        guard let admissionFence = captureDirectAdmissionFence(connectionID: connectionID) else {
            return false
        }

        // 0a) Check if this clientID is in user-kill cooldown (prevents auto-reconnect race)
        if isClientInUserKillCooldown(clientID) {
            let remainingTTL = remainingUserKillCooldown(clientID) ?? 0
            log.notice("Rejecting connection \(connectionID) from '\(clientID)' - in user-kill cooldown (remaining: \(String(format: "%.1f", remainingTTL))s of \(Int(userKilledClientCooldown))s)")
            return false
        }

        // 0b) Prune dead slots for this client (defensive cleanup)
        pruneDeadSlots(for: clientID)
        // Ensure the handshake name is visible even if admission blocks briefly.
        pendingConnections[connectionID] = clientID
        #if DEBUG
            await debugAfterDirectAdmissionPendingPublishedForTesting?(connectionID)
            guard isCurrentDirectAdmission(connectionID: connectionID, fence: admissionFence) else {
                return false
            }
        #endif

        // Global and per-client admission may suspend independently. Stabilize both predicates
        // before committing the direct admission so a bootstrap reservation created during a
        // per-client await cannot be missed.
        cleanupExpiredBootstrapReservations()
        while true {
            // Ensure global headroom using the same replacement-aware load as bootstrap admission.
            if effectiveGlobalAdmissionLoad() >= maxGlobalConnections {
                await pruneNonViableConnections()
                guard isCurrentDirectAdmission(connectionID: connectionID, fence: admissionFence) else {
                    return false
                }
            }
            while effectiveGlobalAdmissionLoad() >= maxGlobalConnections {
                let evictionResult = await evictLeastValuableGlobalForAdmission(
                    preserveOnePerClient: preserveOnePerClient,
                    capacityPredicate: .direct
                )
                guard isCurrentDirectAdmission(connectionID: connectionID, fence: admissionFence) else {
                    return false
                }
                if effectiveGlobalAdmissionLoad() < maxGlobalConnections {
                    break
                }
                switch evictionResult {
                case .evicted, .capacityChanged:
                    continue
                case .noProgress, .admissionContextInvalidated:
                    removePendingDirectAdmissionIfOwned(
                        connectionID: connectionID,
                        clientID: clientID,
                        fence: admissionFence
                    )
                    log.notice("Rejecting connection \(connectionID) from '\(clientID)' - global capacity full (effective=\(effectiveGlobalAdmissionLoad()), cap=\(maxGlobalConnections))")
                    return false
                }
            }

            // Enforce per-client cap with hygiene + eviction using effective membership.
            var effectiveSet = effectiveActiveConnectionIDs(for: clientID)
            while effectiveSet.count >= maxConnectionsPerClient {
                await pruneNonViableConnections()
                guard isCurrentDirectAdmission(connectionID: connectionID, fence: admissionFence) else {
                    return false
                }
                pruneDeadSlots(for: clientID)
                effectiveSet = effectiveActiveConnectionIDs(for: clientID)
                if effectiveSet.count < maxConnectionsPerClient { break }

                let evictionResult = await evictLeastValuable(
                    for: clientID,
                    capacityLimit: maxConnectionsPerClient
                )
                guard isCurrentDirectAdmission(connectionID: connectionID, fence: admissionFence) else {
                    return false
                }
                effectiveSet = effectiveActiveConnectionIDs(for: clientID)
                if effectiveSet.count < maxConnectionsPerClient { break }

                switch evictionResult {
                case .evicted, .capacityChanged:
                    continue
                case .noProgress:
                    removePendingDirectAdmissionIfOwned(
                        connectionID: connectionID,
                        clientID: clientID,
                        fence: admissionFence
                    )
                    log.notice("Rejecting connection \(connectionID) from '\(clientID)' - per-client capacity full (active=\(effectiveSet.count), cap=\(maxConnectionsPerClient))")
                    return false
                }
            }

            guard isCurrentDirectAdmission(connectionID: connectionID, fence: admissionFence) else {
                return false
            }
            if effectiveGlobalAdmissionLoad() < maxGlobalConnections {
                break
            }
        }

        // Reserve & index without discarding any removing member that still owns cleanup identity.
        var set = activeConnectionsByClient[clientID, default: []]
        set.insert(connectionID)
        activeConnectionsByClient[clientID] = set
        clientIDByConnection[connectionID] = clientID
        connectionLog("Admitted connection \(connectionID) with clientID='\(clientID)'")
        // Once admitted, the authoritative map is set — drop only the pending label this admission owns.
        if pendingConnections[connectionID] == clientID {
            pendingConnections.removeValue(forKey: connectionID)
        }

        // 4) Initialize stats if not already present
        if connectionStats[connectionID] == nil {
            connectionStats[connectionID] = ConnectionStats(
                createdAt: Date(),
                totalToolCalls: 0,
                lastToolCallAt: nil
            )
        }
        return true
    }

    func releaseConnectionSlot(connectionID: UUID) async {
        if let clientID = clientIDByConnection[connectionID] {
            var set = activeConnectionsByClient[clientID] ?? []
            set.remove(connectionID)
            if set.isEmpty { activeConnectionsByClient.removeValue(forKey: clientID) }
            else { activeConnectionsByClient[clientID] = set }
            clientIDByConnection.removeValue(forKey: connectionID)
        }
    }

    // MARK: - Routing Persistence Helpers

    /// Removes routing records older than routingRecordTTL, purges token-less records,
    /// and cleans up stale in-memory session map entries.
    private func pruneRoutingRecords() async {
        let now = Date()
        let keys = Array(routingState.records.keys)

        // Get live windows to also prune records pointing to closed windows
        let liveWindows: Set<Int> = await MainActor.run {
            Set(WindowStatesManager.shared.allWindows.map(\.windowID))
        }

        for clientID in keys {
            guard let records = routingState.records[clientID] else { continue }
            // Keep only fresh, token-backed records; drop expired, nil-sessionKey, and invalid window entries
            let filtered = records.filter {
                $0.sessionKey != nil &&
                    now.timeIntervalSince($0.lastSeenAt) < routingRecordTTL &&
                    ($0.lastWindowID == nil || liveWindows.contains($0.lastWindowID!))
            }
            if filtered.isEmpty {
                routingState.records.removeValue(forKey: clientID)
                lastWindowByClientSession.removeValue(forKey: clientID)
            } else {
                routingState.records[clientID] = filtered
                // Keep in-memory fast path aligned to surviving sessionKeys
                let validSessionKeys = Set(filtered.compactMap(\.sessionKey))
                if var sessionMap = lastWindowByClientSession[clientID] {
                    sessionMap = sessionMap.filter { validSessionKeys.contains($0.key) }
                    if sessionMap.isEmpty {
                        lastWindowByClientSession.removeValue(forKey: clientID)
                    } else {
                        lastWindowByClientSession[clientID] = sessionMap
                    }
                }
            }
        }
    }

    /// Persists routing state to disk synchronously to avoid race conditions.
    /// Called on the actor so state is always consistent.
    private func saveRoutingState() {
        MCPRoutingStateStore.save(routingState)
    }

    /// Updates the routing record for a connection after window assignment.
    /// Only persists routing/window affinity for token-backed clients; token-less clients are skipped
    /// to avoid incorrectly merging distinct client instances.
    private func updateRoutingRecordForConnection(_ connectionID: UUID, clientID: String) async {
        guard let manager = connections[connectionID] else { return }

        let capability = manager.capabilityToken ?? capabilityTokenByConnection[connectionID]
        guard let sessionKey = capability else {
            connectionLog("Skipping routing persistence for token-less client: \(clientID)")
            return
        }

        let transport: MCPRoutingState.ClientRecord.Transport = manager.isFilesystemBacked ? .filesystem : .network
        let windowID = connectionWindowMap[connectionID]
        let runID = if let mappedRunID = runIDByConnectionID[connectionID] {
            mappedRunID
        } else {
            await runIDForConnection(connectionID)
        }
        let runPurpose = runID.flatMap { runPolicyStateByRunID[$0]?.purpose } ?? runPurposeByConnection[connectionID]
        updateLiveRunAffinity(
            clientName: clientID,
            sessionKey: sessionKey,
            runID: runID,
            windowID: windowID,
            purpose: runPurpose
        )

        let (workspaceID, instanceNumber): (UUID?, Int?) = await MainActor.run {
            guard
                let windowID,
                let win = WindowStatesManager.shared.window(withID: windowID)
            else { return (nil, nil) }
            return (win.workspaceManager.activeWorkspace?.id, win.workspaceInstanceNumber)
        }

        await pruneRoutingRecords()

        let storageKey = bestStorageKey(
            for: clientID,
            in: Array(Set(routingState.records.keys).union(lastWindowByClientSession.keys))
        )
        var records = routingState.records[storageKey] ?? []
        let now = Date()
        let matchedIdx = records.firstIndex(where: {
            $0.lastTransport == transport && $0.sessionKey == sessionKey
        })

        if let idx = matchedIdx {
            records[idx].lastWindowID = windowID
            records[idx].lastWorkspaceID = workspaceID
            records[idx].lastWorkspaceInstanceNumber = instanceNumber
            records[idx].lastConnectionUUID = connectionID
            records[idx].lastSeenAt = now
        } else {
            let record = MCPRoutingState.ClientRecord(
                clientID: storageKey,
                lastTransport: transport,
                sessionKey: sessionKey,
                lastWindowID: windowID,
                lastWorkspaceID: workspaceID,
                lastWorkspaceInstanceNumber: instanceNumber,
                lastConnectionUUID: connectionID,
                lastSeenAt: now
            )
            records.append(record)
        }

        routingState.records[storageKey] = records
        if let windowID {
            lastWindowByClientSession[storageKey, default: [:]][sessionKey] = windowID
        }
        saveRoutingState()
    }

    /// Returns the preferred window ID for a token-backed client session.
    /// Persisted routing is an affinity hint only; live run ownership is resolved separately
    /// from in-memory `liveRunAffinityByClientSession`.
    private func preferredWindowID(for clientName: String, sessionKey: String?) async -> Int? {
        guard sessionKey != nil else {
            mcpRoutingInternalDebugLog("[preferredWindowID] no sessionKey for client '\(clientName)' - returning nil")
            return nil
        }

        mcpRoutingInternalDebugLog("[preferredWindowID] looking up client '\(clientName)' sessionKey '\(sessionKey!.prefix(8))...'")

        await pruneRoutingRecords()

        for key in matchingClientKeys(for: clientName, in: Array(lastWindowByClientSession.keys)) {
            if let sessionKey, let win = lastWindowByClientSession[key]?[sessionKey] {
                let exists = await WindowStatesManager.shared.hasWindow(id: win)
                if exists {
                    mcpRoutingInternalDebugLog("[preferredWindowID] fast path hit: client '\(clientName)' matchedKey '\(key)' window \(win)")
                    return win
                }
            }
        }

        let matchedRecordKeys = matchingClientKeys(for: clientName, in: Array(routingState.records.keys))
        let records = matchedRecordKeys.flatMap { routingState.records[$0] ?? [] }
        guard !records.isEmpty else {
            mcpRoutingInternalDebugLog("[preferredWindowID] no records for client '\(clientName)' - returning nil")
            return nil
        }

        let now = Date()
        let freshRecords = records.filter { record in
            guard record.sessionKey != nil, now.timeIntervalSince(record.lastSeenAt) < routingRecordTTL else {
                return false
            }
            if let sk = sessionKey {
                return record.sessionKey == sk
            }
            return true
        }

        guard !freshRecords.isEmpty else {
            mcpRoutingInternalDebugLog("[preferredWindowID] no fresh records matching sessionKey - returning nil")
            return nil
        }

        let sortedRecords = freshRecords.sorted { $0.lastSeenAt > $1.lastSeenAt }
        let windowSnapshot: [(workspaceID: UUID?, instanceNumber: Int?, windowID: Int)] = await MainActor.run {
            WindowStatesManager.shared.allWindows.map {
                ($0.workspaceManager.activeWorkspace?.id, $0.workspaceInstanceNumber, $0.windowID)
            }
        }

        for record in sortedRecords {
            guard let ws = record.lastWorkspaceID, let inst = record.lastWorkspaceInstanceNumber else { continue }
            if let match = windowSnapshot.first(where: { $0.workspaceID == ws && $0.instanceNumber == inst }) {
                return match.windowID
            }
        }

        for record in sortedRecords {
            guard let ws = record.lastWorkspaceID else { continue }
            let candidates = windowSnapshot.filter { $0.workspaceID == ws }
            if candidates.count == 1 {
                return candidates[0].windowID
            }
        }

        for record in sortedRecords {
            guard let wid = record.lastWindowID else { continue }
            if windowSnapshot.contains(where: { $0.windowID == wid }) {
                return wid
            }
        }

        for record in sortedRecords {
            guard let inst = record.lastWorkspaceInstanceNumber else { continue }
            let candidates = windowSnapshot.filter { $0.instanceNumber == inst }
            if candidates.count == 1 {
                return candidates[0].windowID
            }
        }

        return nil
    }

    /// Record a tool call occurrence for value scoring and history
    func recordToolCall(for connectionID: UUID, toolName: String) {
        // Hidden coordination calls should not appear in dashboards/histories.
        let canonicalToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(toolName) ?? toolName
        if canonicalToolName == "set_status" || canonicalToolName == "bind_context" { return }

        // If this connection dropped out of the active sets (e.g., after transport toggles),
        // re-associate it now that we have a live tool call.
        if let clientID = clientIdentifier(forConnection: connectionID),
           connections[connectionID] != nil
        {
            var set = activeConnectionsByClient[clientID] ?? []
            if !set.contains(connectionID) {
                set.insert(connectionID)
                activeConnectionsByClient[clientID] = set
                log.notice("Re-associated connection \(connectionID) for client \(clientID) after successful tool call")
            }
        }

        if var s = connectionStats[connectionID] {
            s.totalToolCalls += 1
            s.lastToolCallAt = Date()
            connectionStats[connectionID] = s
        } else {
            connectionStats[connectionID] = ConnectionStats(
                createdAt: Date(),
                totalToolCalls: 1,
                lastToolCallAt: Date()
            )
        }

        // Record in history for dashboard display
        let clientName = clientIdentifier(forConnection: connectionID) ?? "Unknown"
        let entry = ToolCallHistoryEntry(
            timestamp: Date(),
            toolName: toolName,
            clientName: clientName,
            connectionID: connectionID
        )
        recentToolCallHistory.insert(entry, at: 0)
        if recentToolCallHistory.count > maxToolCallHistoryCount {
            recentToolCallHistory.removeLast()
        }

        // Notify dashboard of tool call update
        emitDashboardUpdate()
    }

    /// Returns recent tool call history for dashboard display
    func getRecentToolCallHistory() -> [ToolCallHistoryEntry] {
        recentToolCallHistory
    }

    private func limiterLimit(for connectionID: UUID) -> Int {
        // The legacy `ordinary` lane is now the explicit exclusive class only.
        _ = connectionID
        return MCPToolAdmissionPolicy.exclusiveConnectionLimit
    }

    private func controlLimiterLimit(for connectionID: UUID) -> Int {
        _ = connectionID
        return Self.controlCallLaneLimit
    }

    private func smallReadLimiterLimit(for connectionID: UUID) -> Int {
        _ = connectionID
        return Self.smallReadCallLaneLimit
    }

    private func gitReadLimiterLimit(for connectionID: UUID) -> Int {
        _ = connectionID
        return Self.gitReadCallLaneLimit
    }

    private func fileSearchLimiterLimit(for connectionID: UUID) -> Int {
        // Admit a bounded burst of concurrent file_search calls per connection. Agents batch
        // read-only searches; running the burst concurrently lets every member share one
        // workspace ingress freshness flight instead of reconstructing it serially per call.
        // Per-workspace broad admission still bounds unscoped content searches downstream.
        _ = connectionID
        return Self.fileSearchCallLaneLimit
    }

    private struct ConnectionCallLimiterResolution {
        let limiters: MCPConnectionCallLimiters
        let connectionIdentity: ObjectIdentifier
        let lifecycleGeneration: UInt64
    }

    private func connectionCallLimiterResolution(
        for connectionID: UUID
    ) -> ConnectionCallLimiterResolution? {
        guard !connectionsBeingRemoved.contains(connectionID),
              let connection = connections[connectionID],
              let connectionLifecycleGeneration = connectionLifecycleGenerationByID[connectionID],
              isCurrentLifecycle(connectionLifecycleGeneration),
              let limiters = callLimiters[connectionID]
        else { return nil }
        return ConnectionCallLimiterResolution(
            limiters: limiters,
            connectionIdentity: ObjectIdentifier(connection as AnyObject),
            lifecycleGeneration: connectionLifecycleGeneration
        )
    }

    private func isCurrentConnectionCallLimiterResolution(
        _ resolution: ConnectionCallLimiterResolution,
        connectionID: UUID
    ) -> Bool {
        guard !connectionsBeingRemoved.contains(connectionID),
              !executionWatchdogTerminalConnections.contains(connectionID),
              isCurrentLifecycle(resolution.lifecycleGeneration),
              connectionLifecycleGenerationByID[connectionID] == resolution.lifecycleGeneration,
              let connection = connections[connectionID]
        else { return false }
        return ObjectIdentifier(connection as AnyObject) == resolution.connectionIdentity
    }

    private func toolDispatchAuthorization(
        connectionID: UUID,
        resolution: ConnectionCallLimiterResolution,
        windowIdentity: WindowToolDispatchIdentity? = nil
    ) -> ToolDispatchAuthorization {
        ToolDispatchAuthorization(
            connectionID: connectionID,
            connectionIdentity: resolution.connectionIdentity,
            lifecycleGeneration: resolution.lifecycleGeneration,
            windowIdentity: windowIdentity
        )
    }

    private func withConnectionCallPermit<T>(
        connectionID: UUID,
        lane: MCPConnectionCallLane,
        resolution: ConnectionCallLimiterResolution,
        toolName: String? = nil,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation? = nil,
        _ operation: @Sendable () async -> T
    ) async throws -> T {
        #if DEBUG
            await debugAfterConnectionCallLimiterResolutionForTesting?(connectionID)
        #endif
        var attemptedLimiters = resolution.limiters
        var visitedLimiterIdentities: Set<ObjectIdentifier> = []

        while true {
            try Task.checkCancellation()
            guard isCurrentConnectionCallLimiterResolution(
                resolution,
                connectionID: connectionID
            ) else { throw CancellationError() }

            let attemptedIdentity = ObjectIdentifier(attemptedLimiters)
            guard visitedLimiterIdentities.insert(attemptedIdentity).inserted else {
                throw CancellationError()
            }

            do {
                #if DEBUG
                    let afterPermitAcquired = debugAfterConnectionCallPermitAcquiredForTesting
                #endif
                #if DEBUG
                    let ownerResource = "connection:\(connectionID.uuidString)"
                    let ownerWindowID = connectionWindowMap[connectionID]
                    let ownerRunID = runIDByConnectionID[connectionID]?.uuidString
                #else
                    let ownerResource: String? = nil
                    let ownerWindowID: Int? = nil
                    let ownerRunID: String? = nil
                #endif
                return try await attemptedLimiters.withPermit(
                    lane: lane,
                    toolName: toolName,
                    lifecycleCorrelation: lifecycleCorrelation,
                    ownerResource: ownerResource,
                    ownerWindowID: ownerWindowID,
                    ownerRunID: ownerRunID
                ) {
                    #if DEBUG
                        await afterPermitAcquired?(connectionID)
                    #endif
                    guard await self.isCurrentConnectionCallLimiterResolution(
                        resolution,
                        connectionID: connectionID
                    ) else {
                        throw CancellationError()
                    }
                    return await operation()
                }
            } catch is MCPConnectionCallLimiters.AdmissionRejected {
                #if DEBUG
                    await debugAfterConnectionCallLimiterRejectionForTesting?(connectionID)
                #endif
                try Task.checkCancellation()
                guard isCurrentConnectionCallLimiterResolution(
                    resolution,
                    connectionID: connectionID
                ),
                    let replacementLimiters = await attemptedLimiters.admissionRetryReplacement(),
                    replacementLimiters !== attemptedLimiters,
                    !Task.isCancelled,
                    isCurrentConnectionCallLimiterResolution(
                        resolution,
                        connectionID: connectionID
                    )
                else { throw CancellationError() }
                attemptedLimiters = replacementLimiters
            }
        }
    }

    private func withConnectionCallPermit<T>(
        connectionID: UUID,
        lane: MCPConnectionCallLane,
        resolution: ConnectionCallLimiterResolution,
        toolName: String? = nil,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation? = nil,
        cancellationResult: @Sendable () -> T,
        _ operation: @Sendable () async -> T
    ) async -> T {
        do {
            return try await withConnectionCallPermit(
                connectionID: connectionID,
                lane: lane,
                resolution: resolution,
                toolName: toolName,
                lifecycleCorrelation: lifecycleCorrelation,
                operation
            )
        } catch {
            return cancellationResult()
        }
    }

    func hasInFlightCalls(for connectionID: UUID) async -> Bool {
        guard let limiters = callLimiters[connectionID] else { return false }
        return await limiters.hasInFlightCalls()
    }

    func waitUntilResponseDeliveryDrained(for connectionID: UUID) async -> Bool {
        guard let connection = connections[connectionID] else { return false }
        return await connection.waitUntilResponseDeliveryDrained()
    }

    #if DEBUG
        func limiter(
            for connectionID: UUID,
            lane: MCPConnectionCallLane = .ordinary
        ) async -> AsyncLimiter? {
            guard let limiters = callLimiters[connectionID] else { return nil }
            return await limiters.limiterForTesting(lane)
        }

        func connectionLimiterDiagnosticsSnapshot(
            connectionID: UUID
        ) async -> MCPConnectionCallLimiterDebugSnapshot? {
            guard let limiters = callLimiters[connectionID] else { return nil }
            return await limiters.diagnosticsSnapshot()
        }

        func connectionLimiterSnapshotForTesting(
            connectionID: UUID,
            lane: MCPConnectionCallLane = .ordinary
        ) async -> AsyncLimiter.DebugSnapshot? {
            guard let limiter = await limiter(for: connectionID, lane: lane) else { return nil }
            return await limiter.debugSnapshot()
        }

        func setConnectionLimiterStateObserverForTesting(
            connectionID: UUID,
            lane: MCPConnectionCallLane = .ordinary,
            observer: ((AsyncLimiter.DebugSnapshot) -> Void)?
        ) async -> Bool {
            guard let limiter = await limiter(for: connectionID, lane: lane) else { return false }
            await limiter.setDebugStateObserver(observer)
            return true
        }

        func withConnectionCallPermitForTesting<T>(
            connectionID: UUID,
            lane: MCPConnectionCallLane,
            toolName: String? = nil,
            lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation? = nil,
            _ operation: @Sendable () async -> T
        ) async throws -> T {
            if let resolution = connectionCallLimiterResolution(for: connectionID) {
                return try await withConnectionCallPermit(
                    connectionID: connectionID,
                    lane: lane,
                    resolution: resolution,
                    toolName: toolName,
                    lifecycleCorrelation: lifecycleCorrelation,
                    operation
                )
            }
            guard let limiters = callLimiters[connectionID] else { throw CancellationError() }
            await debugAfterConnectionCallLimiterResolutionForTesting?(connectionID)
            return try await limiters.withPermit(
                lane: lane,
                toolName: toolName,
                lifecycleCorrelation: lifecycleCorrelation,
                ownerResource: "connection:\(connectionID.uuidString)",
                ownerWindowID: connectionWindowMap[connectionID],
                ownerRunID: runIDByConnectionID[connectionID]?.uuidString,
                operation
            )
        }

        func connectionIsEvictableForTesting(_ connectionID: UUID) async -> Bool {
            await isEvictable(connectionID)
        }

        func closeConnectionCallLanesIfIdleForEvictionForTesting(_ connectionID: UUID) async -> Bool {
            guard let limiters = callLimiters[connectionID],
                  await closeConnectionCallLanesIfIdleForEviction(connectionID)
            else { return false }
            await limiters.markTentativeCloseCommitted()
            return true
        }

        func beginTentativeConnectionCallLaneCloseForTesting(_ connectionID: UUID) async -> Bool {
            await closeConnectionCallLanesIfIdleForEviction(connectionID)
        }

        func connectionCallAdmissionRetryWaiterCountForTesting(_ connectionID: UUID) async -> Int? {
            guard let limiters = callLimiters[connectionID] else { return nil }
            return await limiters.admissionRetryWaiterCountForTesting()
        }

        func closeAndRestoreConnectionCallLanesForTesting(_ connectionID: UUID) async -> Bool {
            guard let connection = connections[connectionID],
                  let clientID = clientIDByConnection[connectionID],
                  let limiters = callLimiters[connectionID]
            else { return false }
            let connectionIdentity = ObjectIdentifier(connection as AnyObject)
            guard await closeConnectionCallLanesIfIdleForEviction(
                connectionID,
                expectedConnectionIdentity: connectionIdentity,
                expectedLimiters: limiters
            ) else { return false }
            return await restoreConnectionCallLanesAfterAbortedIdleEviction(
                connectionID,
                clientID: clientID,
                connectionIdentity: connectionIdentity,
                replacing: limiters
            )
        }
    #endif

    private func oldestPressureEvictionCandidate() async -> EvictionCandidate? {
        let threshold = pressureEvictIdleSeconds
        guard threshold > 0 else { return nil }
        var best: EvictionCandidate?
        for id in connections.keys {
            guard !creditedBootstrapPredecessorConnectionIDs().contains(id),
                  await isEvictable(id),
                  let candidate = await makeCandidate(for: id),
                  candidate.idleSeconds >= TimeInterval(threshold),
                  !isCreditedBootstrapPredecessor(candidate)
            else { continue }
            if best == nil || candidate.idleSeconds > best!.idleSeconds {
                best = candidate
            }
        }
        return best
    }

    /// ─────────────  Admission fairness helpers  ─────────────
    private var effectiveRegisteredConnectionCount: Int {
        connections.keys.reduce(into: 0) { count, connectionID in
            if !connectionsBeingRemoved.contains(connectionID) {
                count += 1
            }
        }
    }

    private func effectiveActiveConnectionIDs(for clientID: String) -> Set<UUID> {
        guard let indexedConnections = activeConnectionsByClient[clientID] else { return [] }
        return indexedConnections.filter { connectionID in
            connections[connectionID] != nil && !connectionsBeingRemoved.contains(connectionID)
        }
    }

    /// Remove client slots that are no longer backed by a live connection entry.
    private func pruneDeadSlots(for clientID: String) {
        guard var set = activeConnectionsByClient[clientID] else { return }
        let live = Set(connections.keys)
        set = set.filter { live.contains($0) }
        if set.isEmpty { activeConnectionsByClient.removeValue(forKey: clientID) }
        else { activeConnectionsByClient[clientID] = set }
    }

    /// Connection is evictable if it has no in-flight calls and does not own an active tool.
    private func isEvictable(_ id: UUID) async -> Bool {
        if connectionsBeingRemoved.contains(id) { return false }
        if let limiters = callLimiters[id], await limiters.hasInFlightCalls() { return false }
        if hasActiveToolScopes(ownedBy: id) { return false }
        return true
    }

    private func isCurrentConnectionIdentity(
        _ connectionID: UUID,
        expectedIdentity: ObjectIdentifier
    ) -> Bool {
        guard let connection = connections[connectionID] else { return false }
        return ObjectIdentifier(connection as AnyObject) == expectedIdentity
    }

    private func isCurrentEvictionCandidate(_ candidate: EvictionCandidate) -> Bool {
        connectionLifecycleGenerationByID[candidate.id] == candidate.lifecycleGeneration
            && isCurrentLifecycle(candidate.lifecycleGeneration)
            && isCurrentConnectionIdentity(
                candidate.id,
                expectedIdentity: candidate.connectionIdentity
            )
    }

    private func isCreditedBootstrapPredecessor(_ candidate: EvictionCandidate) -> Bool {
        isCurrentEvictionCandidate(candidate)
            && creditedBootstrapPredecessorConnectionIDs().contains(candidate.id)
    }

    private func closeConnectionCallLanesIfIdleForEviction(
        _ id: UUID,
        expectedConnectionIdentity: ObjectIdentifier? = nil,
        expectedLimiters: MCPConnectionCallLimiters? = nil
    ) async -> Bool {
        if let expectedConnectionIdentity,
           !isCurrentConnectionIdentity(id, expectedIdentity: expectedConnectionIdentity)
        {
            return false
        }
        guard !hasActiveToolScopes(ownedBy: id),
              let limiters = expectedLimiters ?? callLimiters[id],
              callLimiters[id] === limiters
        else { return false }
        #if DEBUG
            let didClose = await limiters.closeIfIdle { [debugDuringAdmissionEvictionCloseForTesting] in
                await debugDuringAdmissionEvictionCloseForTesting?(id)
            }
        #else
            let didClose = await limiters.closeIfIdle()
        #endif
        return didClose
    }

    private func restoreConnectionCallLanesAfterAbortedIdleEviction(
        _ id: UUID,
        clientID: String,
        connectionIdentity: ObjectIdentifier,
        replacing closedLimiters: MCPConnectionCallLimiters,
        requiresClientMembership: Bool = true
    ) async -> Bool {
        guard !connectionsBeingRemoved.contains(id),
              isCurrentConnectionIdentity(id, expectedIdentity: connectionIdentity),
              callLimiters[id] === closedLimiters
        else {
            await closedLimiters.markTentativeCloseCommitted()
            return false
        }
        if requiresClientMembership {
            guard clientIDByConnection[id] == clientID,
                  activeConnectionsByClient[clientID]?.contains(id) == true
            else {
                await closedLimiters.markTentativeCloseCommitted()
                return false
            }
        }

        // closeIfIdle() admitted no owners before closing both lanes. Replacing that exact,
        // still-registered bundle is therefore a safe rollback: stale references can only
        // observe cancellation, while all subsequent calls resolve these fresh open lanes.
        let replacement = MCPConnectionCallLimiters(
            limit: limiterLimit(for: id),
            controlLimit: controlLimiterLimit(for: id),
            smallReadLimit: smallReadLimiterLimit(for: id),
            gitReadLimit: gitReadLimiterLimit(for: id),
            fileSearchLimit: fileSearchLimiterLimit(for: id)
        )
        callLimiters[id] = replacement
        await closedLimiters.markTentativeCloseRestored(by: replacement)
        return true
    }

    private enum PerClientAdmissionEvictionResult: Equatable {
        /// This invocation committed and completed removal of its selected victim.
        case evicted
        /// Another removal reduced this client's effective membership while this invocation awaited.
        case capacityChanged
        /// No victim was removed and effective membership did not change.
        case noProgress
    }

    private enum GlobalAdmissionCapacityPredicate {
        case none
        case direct
        case bootstrap(prospectiveReplacementCredit: BootstrapReplacementCredit?)
    }

    private enum GlobalAdmissionEvictionResult: Equatable {
        /// This invocation committed and completed removal of its selected victim.
        case evicted
        /// Another removal made effective capacity progress while this invocation preserved its victim.
        case capacityChanged
        /// No victim was removed and effective live capacity did not change.
        case noProgress
        /// The bootstrap listener or lifecycle generation became stale.
        case admissionContextInvalidated
    }

    private struct EvictionCandidate {
        let id: UUID
        let connectionIdentity: ObjectIdentifier
        let lifecycleGeneration: UInt64
        let clientID: String
        let everCalled: Bool
        let totalCalls: Int
        let idleSeconds: TimeInterval
        let createdAt: Date
    }

    private func makeCandidate(for id: UUID) async -> EvictionCandidate? {
        guard let clientID = clientIDByConnection[id],
              let mgr = connections[id],
              let candidateLifecycleGeneration = connectionLifecycleGenerationByID[id],
              isCurrentLifecycle(candidateLifecycleGeneration)
        else { return nil }
        let connectionIdentity = ObjectIdentifier(mgr as AnyObject)
        let stats = connectionStats[id]

        // If not viable, force to the front by giving infinite idle.
        let viable = await mgr.isViableForRetention()
        guard isCurrentConnectionIdentity(id, expectedIdentity: connectionIdentity),
              clientIDByConnection[id] == clientID
        else { return nil }
        if !viable {
            return EvictionCandidate(
                id: id,
                connectionIdentity: connectionIdentity,
                lifecycleGeneration: candidateLifecycleGeneration,
                clientID: clientID,
                everCalled: (stats?.totalToolCalls ?? 0) > 0,
                totalCalls: stats?.totalToolCalls ?? 0,
                idleSeconds: .infinity,
                createdAt: stats?.createdAt ?? Date.distantPast
            )
        }

        let idle = await mgr.secondsSinceLastActivity()
        guard isCurrentConnectionIdentity(id, expectedIdentity: connectionIdentity),
              clientIDByConnection[id] == clientID
        else { return nil }
        return EvictionCandidate(
            id: id,
            connectionIdentity: connectionIdentity,
            lifecycleGeneration: candidateLifecycleGeneration,
            clientID: clientID,
            everCalled: (stats?.totalToolCalls ?? 0) > 0,
            totalCalls: stats?.totalToolCalls ?? 0,
            idleSeconds: idle,
            createdAt: stats?.createdAt ?? Date.distantPast
        )
    }

    /// Sort ascending by value (least valuable first)
    private func isLessValuable(_ a: EvictionCandidate, than b: EvictionCandidate) -> Bool {
        if a.everCalled != b.everCalled { return a.everCalled == false }
        if a.idleSeconds != b.idleSeconds { return a.idleSeconds > b.idleSeconds }
        if a.totalCalls != b.totalCalls { return a.totalCalls < b.totalCalls }
        return a.createdAt < b.createdAt
    }

    /// Evict least valuable eligible connection for this client.
    private func evictLeastValuable(
        for clientID: String,
        capacityLimit: Int? = nil
    ) async -> PerClientAdmissionEvictionResult {
        let initialEffectiveConnections = effectiveActiveConnectionIDs(for: clientID)
        guard !initialEffectiveConnections.isEmpty else { return .noProgress }
        func noEvictionResult() -> PerClientAdmissionEvictionResult {
            effectiveActiveConnectionIDs(for: clientID).count < initialEffectiveConnections.count
                ? .capacityChanged
                : .noProgress
        }

        var candidates: [EvictionCandidate] = []
        for id in initialEffectiveConnections {
            guard !creditedBootstrapPredecessorConnectionIDs().contains(id) else { continue }
            guard await isEvictable(id) else {
                if effectiveActiveConnectionIDs(for: clientID).count < initialEffectiveConnections.count {
                    return .capacityChanged
                }
                continue
            }
            if effectiveActiveConnectionIDs(for: clientID).count < initialEffectiveConnections.count {
                return .capacityChanged
            }
            if let candidate = await makeCandidate(for: id),
               !isCreditedBootstrapPredecessor(candidate)
            {
                if effectiveActiveConnectionIDs(for: clientID).count < initialEffectiveConnections.count {
                    return .capacityChanged
                }
                candidates.append(candidate)
            }
        }

        for victim in candidates.sorted(by: isLessValuable) {
            #if DEBUG
                if let debugBeforeAdmissionEvictionCloseForTesting {
                    await debugBeforeAdmissionEvictionCloseForTesting(victim.id)
                }
            #endif
            if effectiveActiveConnectionIDs(for: clientID).count < initialEffectiveConnections.count {
                return .capacityChanged
            }
            guard isCurrentEvictionCandidate(victim),
                  !isCreditedBootstrapPredecessor(victim),
                  clientIDByConnection[victim.id] == clientID,
                  effectiveActiveConnectionIDs(for: clientID).contains(victim.id),
                  let closedLimiters = callLimiters[victim.id]
            else { continue }

            let didClose = await closeConnectionCallLanesIfIdleForEviction(
                victim.id,
                expectedConnectionIdentity: victim.connectionIdentity,
                expectedLimiters: closedLimiters
            )
            guard didClose else {
                if effectiveActiveConnectionIDs(for: clientID).count < initialEffectiveConnections.count {
                    return .capacityChanged
                }
                continue
            }
            guard isCurrentEvictionCandidate(victim),
                  callLimiters[victim.id] === closedLimiters
            else {
                await closedLimiters.markTentativeCloseCommitted()
                return noEvictionResult()
            }

            if isCreditedBootstrapPredecessor(victim) {
                let restored = await restoreConnectionCallLanesAfterAbortedIdleEviction(
                    victim.id,
                    clientID: clientID,
                    connectionIdentity: victim.connectionIdentity,
                    replacing: closedLimiters,
                    requiresClientMembership: false
                )
                if restored {
                    log.notice(
                        "Per-client eviction aborted because \(victim.id) became a credited bootstrap predecessor; restored idle call lanes."
                    )
                }
                continue
            }

            if let capacityLimit,
               effectiveActiveConnectionIDs(for: clientID).count < capacityLimit
            {
                let restored = await restoreConnectionCallLanesAfterAbortedIdleEviction(
                    victim.id,
                    clientID: clientID,
                    connectionIdentity: victim.connectionIdentity,
                    replacing: closedLimiters
                )
                if restored {
                    log.notice(
                        "Per-client eviction aborted after capacity changed during lane closure for \(victim.id); restored idle call lanes."
                    )
                    return .capacityChanged
                }
                guard isCurrentEvictionCandidate(victim),
                      callLimiters[victim.id] === closedLimiters
                else { return .capacityChanged }
            }

            guard !isCreditedBootstrapPredecessor(victim),
                  let committedRemoval = commitConnectionRemoval(
                      connectionID: victim.id,
                      expectedIdentity: victim.connectionIdentity,
                      expectedLifecycleGeneration: victim.lifecycleGeneration
                  )
            else {
                await closedLimiters.markTentativeCloseCommitted()
                return noEvictionResult()
            }
            #if DEBUG
                await debugAfterAdmissionEvictionRemovalCommittedForTesting?(victim.id)
            #endif
            await closedLimiters.markTentativeCloseCommitted()

            log.warning("Per-client eviction: evicting \(victim.id) for client \(clientID) to admit a new connection.")
            _ = await removeConnection(
                victim.id,
                committedRemoval: committedRemoval,
                connectionAlreadyStopped: false,
                context: MCPConnectionCloseContext(
                    reason: "per_client_admission_eviction",
                    initiator: .app
                )
            )
            return .evicted
        }
        return noEvictionResult()
    }

    /// Evict least valuable eligible connection across all clients.
    private func evictLeastValuableGlobalForAdmission(
        preserveOnePerClient: Bool,
        sourceListener: BootstrapSocketServer? = nil,
        lifecycleGeneration: UInt64? = nil,
        capacityPredicate: GlobalAdmissionCapacityPredicate = .none
    ) async -> GlobalAdmissionEvictionResult {
        guard isCurrentBootstrapAdmissionContext(
            sourceListener: sourceListener,
            lifecycleGeneration: lifecycleGeneration
        ) else { return .admissionContextInvalidated }

        let initialEffectiveLoad = globalAdmissionLoad(for: capacityPredicate)
        func noEvictionResult() -> GlobalAdmissionEvictionResult {
            globalAdmissionLoad(for: capacityPredicate) < initialEffectiveLoad ? .capacityChanged : .noProgress
        }
        func isCreditedPredecessor(_ connectionID: UUID) -> Bool {
            let prospectiveReplacementCredit: BootstrapReplacementCredit? = switch capacityPredicate {
            case .none, .direct:
                nil
            case let .bootstrap(prospectiveReplacementCredit):
                prospectiveReplacementCredit
            }
            return creditedBootstrapPredecessorConnectionIDs(
                prospectiveReplacementCredit: prospectiveReplacementCredit
            ).contains(connectionID)
        }

        var countsByClient: [String: Int] = [:]
        for clientID in activeConnectionsByClient.keys {
            countsByClient[clientID] = effectiveActiveConnectionIDs(for: clientID).count
        }

        var candidates: [EvictionCandidate] = []
        for id in connections.keys {
            guard isCurrentBootstrapAdmissionContext(
                sourceListener: sourceListener,
                lifecycleGeneration: lifecycleGeneration
            ) else { return .admissionContextInvalidated }
            guard !isCreditedPredecessor(id) else { continue }
            guard await isEvictable(id) else { continue }
            guard isCurrentBootstrapAdmissionContext(
                sourceListener: sourceListener,
                lifecycleGeneration: lifecycleGeneration
            ) else { return .admissionContextInvalidated }
            guard !isCreditedPredecessor(id) else { continue }
            if preserveOnePerClient, let cid = clientIDByConnection[id], (countsByClient[cid] ?? 0) <= 1 {
                continue
            }
            if let candidate = await makeCandidate(for: id) {
                guard isCurrentBootstrapAdmissionContext(
                    sourceListener: sourceListener,
                    lifecycleGeneration: lifecycleGeneration
                ) else { return .admissionContextInvalidated }
                guard !isCreditedPredecessor(id) else { continue }
                candidates.append(candidate)
            }
        }

        if candidates.isEmpty, preserveOnePerClient {
            var anyHasMoreThanOne = false
            for count in countsByClient.values where count > 1 {
                anyHasMoreThanOne = true
                break
            }
            if !anyHasMoreThanOne {
                return await evictLeastValuableGlobalForAdmission(
                    preserveOnePerClient: false,
                    sourceListener: sourceListener,
                    lifecycleGeneration: lifecycleGeneration,
                    capacityPredicate: capacityPredicate
                )
            }
        }

        guard isCurrentBootstrapAdmissionContext(
            sourceListener: sourceListener,
            lifecycleGeneration: lifecycleGeneration
        ) else { return .admissionContextInvalidated }
        for victim in candidates.sorted(by: isLessValuable) {
            guard isCurrentBootstrapAdmissionContext(
                sourceListener: sourceListener,
                lifecycleGeneration: lifecycleGeneration
            ) else { return .admissionContextInvalidated }
            guard !isCreditedPredecessor(victim.id) else { continue }
            #if DEBUG
                if let debugBeforeAdmissionEvictionCloseForTesting {
                    await debugBeforeAdmissionEvictionCloseForTesting(victim.id)
                    guard isCurrentBootstrapAdmissionContext(
                        sourceListener: sourceListener,
                        lifecycleGeneration: lifecycleGeneration
                    ) else { return .admissionContextInvalidated }
                    guard !isCreditedPredecessor(victim.id) else { continue }
                }
            #endif

            guard isCurrentConnectionIdentity(victim.id, expectedIdentity: victim.connectionIdentity),
                  clientIDByConnection[victim.id] == victim.clientID
            else { continue }

            if preserveOnePerClient {
                let currentClientConnections = effectiveActiveConnectionIDs(for: victim.clientID)
                guard currentClientConnections.contains(victim.id),
                      currentClientConnections.count > 1
                else { continue }
            }

            if globalAdmissionHasCapacity(for: capacityPredicate) {
                return .capacityChanged
            }

            guard let closedLimiters = callLimiters[victim.id] else { continue }
            let didClose = await closeConnectionCallLanesIfIdleForEviction(
                victim.id,
                expectedConnectionIdentity: victim.connectionIdentity,
                expectedLimiters: closedLimiters
            )
            let lifecycleStillCurrentAfterClose = isCurrentBootstrapAdmissionContext(
                sourceListener: sourceListener,
                lifecycleGeneration: lifecycleGeneration
            )
            guard didClose else {
                guard lifecycleStillCurrentAfterClose else { return .admissionContextInvalidated }
                continue
            }
            guard isCurrentConnectionIdentity(victim.id, expectedIdentity: victim.connectionIdentity),
                  callLimiters[victim.id] === closedLimiters
            else {
                await closedLimiters.markTentativeCloseCommitted()
                guard lifecycleStillCurrentAfterClose else { return .admissionContextInvalidated }
                continue
            }

            // Once the exact victim's lanes close, a stale lifecycle cannot leave it registered.
            guard lifecycleStillCurrentAfterClose else {
                guard let committedRemoval = commitConnectionRemoval(
                    connectionID: victim.id,
                    expectedIdentity: victim.connectionIdentity,
                    expectedLifecycleGeneration: victim.lifecycleGeneration
                ) else {
                    await closedLimiters.markTentativeCloseCommitted()
                    return .admissionContextInvalidated
                }
                await closedLimiters.markTentativeCloseCommitted()
                log.warning("Global eviction: removing closed victim \(victim.id) after admission lifecycle invalidation.")
                _ = await removeConnection(
                    victim.id,
                    committedRemoval: committedRemoval,
                    connectionAlreadyStopped: false,
                    context: MCPConnectionCloseContext(
                        reason: "global_admission_eviction_lifecycle_invalidated",
                        initiator: .app
                    )
                )
                return .admissionContextInvalidated
            }

            let currentClientConnections = effectiveActiveConnectionIDs(for: victim.clientID)
            let becameCreditedPredecessor = isCreditedPredecessor(victim.id)
            let becameSoleProtectedConnection = preserveOnePerClient
                && currentClientConnections.contains(victim.id)
                && currentClientConnections.count == 1
            if becameCreditedPredecessor || becameSoleProtectedConnection {
                let restored = await restoreConnectionCallLanesAfterAbortedIdleEviction(
                    victim.id,
                    clientID: victim.clientID,
                    connectionIdentity: victim.connectionIdentity,
                    replacing: closedLimiters,
                    requiresClientMembership: !becameCreditedPredecessor
                )
                if restored {
                    let reason = becameCreditedPredecessor
                        ? "became a credited bootstrap predecessor"
                        : "became the sole connection for client \(victim.clientID)"
                    log.notice(
                        "Global eviction aborted after \(victim.id) \(reason); restored idle call lanes."
                    )
                    continue
                }

                // Restoration failure means the exact identity or lifecycle changed; never
                // remove a newly protected/current replacement through the stale victim ID.
                continue
            }

            if globalAdmissionHasCapacity(for: capacityPredicate) {
                let restored = await restoreConnectionCallLanesAfterAbortedIdleEviction(
                    victim.id,
                    clientID: victim.clientID,
                    connectionIdentity: victim.connectionIdentity,
                    replacing: closedLimiters
                )
                if restored {
                    log.notice(
                        "Global eviction aborted after capacity changed during lane closure for \(victim.id); restored idle call lanes."
                    )
                    return .capacityChanged
                }

                guard !isCreditedPredecessor(victim.id),
                      let committedRemoval = commitConnectionRemoval(
                          connectionID: victim.id,
                          expectedIdentity: victim.connectionIdentity,
                          expectedLifecycleGeneration: victim.lifecycleGeneration
                      )
                else {
                    await closedLimiters.markTentativeCloseCommitted()
                    return .capacityChanged
                }
                log.warning("Global eviction could not restore closed victim \(victim.id); removing it.")
                _ = await removeConnection(
                    victim.id,
                    committedRemoval: committedRemoval,
                    connectionAlreadyStopped: false,
                    context: MCPConnectionCloseContext(
                        reason: "global_admission_eviction_restore_failed",
                        initiator: .app
                    )
                )
                guard isCurrentBootstrapAdmissionContext(
                    sourceListener: sourceListener,
                    lifecycleGeneration: lifecycleGeneration
                ) else { return .admissionContextInvalidated }
                return .evicted
            }

            // Atomic lane closure commits this exact victim to eviction. Claim exact removal
            // ownership before the cross-actor limiter notification so credit cannot appear in between.
            guard !isCreditedPredecessor(victim.id),
                  let committedRemoval = commitConnectionRemoval(
                      connectionID: victim.id,
                      expectedIdentity: victim.connectionIdentity,
                      expectedLifecycleGeneration: victim.lifecycleGeneration
                  )
            else {
                await closedLimiters.markTentativeCloseCommitted()
                continue
            }
            await closedLimiters.markTentativeCloseCommitted()
            log.warning("Global eviction: evicting \(victim.id) (client \(victim.clientID)) to admit a new connection.")
            _ = await removeConnection(
                victim.id,
                committedRemoval: committedRemoval,
                connectionAlreadyStopped: false,
                context: MCPConnectionCloseContext(
                    reason: "global_admission_eviction",
                    initiator: .app
                )
            )
            guard isCurrentBootstrapAdmissionContext(
                sourceListener: sourceListener,
                lifecycleGeneration: lifecycleGeneration
            ) else { return .admissionContextInvalidated }
            return .evicted
        }
        return noEvictionResult()
    }

    private func globalAdmissionLoad(
        for predicate: GlobalAdmissionCapacityPredicate
    ) -> Int {
        switch predicate {
        case .none, .direct:
            effectiveGlobalAdmissionLoad()
        case let .bootstrap(prospectiveReplacementCredit):
            effectiveGlobalAdmissionLoad(
                prospectiveReplacementCredit: prospectiveReplacementCredit
            )
        }
    }

    private func globalAdmissionHasCapacity(
        for predicate: GlobalAdmissionCapacityPredicate
    ) -> Bool {
        switch predicate {
        case .none:
            false
        case .direct, .bootstrap:
            globalAdmissionLoad(for: predicate) < maxGlobalConnections
        }
    }

    private func isCurrentBootstrapAdmissionContext(
        sourceListener: BootstrapSocketServer?,
        lifecycleGeneration: UInt64?
    ) -> Bool {
        switch (sourceListener, lifecycleGeneration) {
        case (nil, nil):
            true
        case let (sourceListener?, lifecycleGeneration?):
            isCurrentBootstrapListener(sourceListener, lifecycleGeneration: lifecycleGeneration)
        default:
            false
        }
    }
}

#if DEBUG
    struct MCPConnectionCallLimiterDebugSnapshot: Equatable {
        let ordinary: AsyncLimiter.DebugSnapshot
        let control: AsyncLimiter.DebugSnapshot
        let smallRead: AsyncLimiter.DebugSnapshot
        let gitRead: AsyncLimiter.DebugSnapshot
        let fileSearch: AsyncLimiter.DebugSnapshot

        var laneCount: Int {
            MCPConnectionCallLane.allCases.count
        }

        var limit: Int {
            ordinary.limit + control.limit + smallRead.limit + gitRead.limit + fileSearch.limit
        }

        var permits: Int {
            ordinary.permits + control.permits + smallRead.permits + gitRead.permits + fileSearch.permits
        }

        var activePermitCount: Int {
            ordinary.activePermitCount + control.activePermitCount + smallRead.activePermitCount + gitRead.activePermitCount + fileSearch.activePermitCount
        }

        var waiterCount: Int {
            ordinary.waiterCount + control.waiterCount + smallRead.waiterCount + gitRead.waiterCount + fileSearch.waiterCount
        }

        var inFlight: Int {
            ordinary.inFlight + control.inFlight + smallRead.inFlight + gitRead.inFlight + fileSearch.inFlight
        }

        var oldestWaiterAgeMilliseconds: UInt64? {
            [
                ordinary.oldestWaiterAgeMilliseconds,
                control.oldestWaiterAgeMilliseconds,
                smallRead.oldestWaiterAgeMilliseconds,
                gitRead.oldestWaiterAgeMilliseconds,
                fileSearch.oldestWaiterAgeMilliseconds
            ]
            .compactMap(\.self)
            .max()
        }

        var cancelledWaiterCount: Int {
            ordinary.cancelledWaiterCount + control.cancelledWaiterCount + smallRead.cancelledWaiterCount + gitRead.cancelledWaiterCount + fileSearch.cancelledWaiterCount
        }

        var isClosed: Bool {
            ordinary.isClosed && control.isClosed && smallRead.isClosed && gitRead.isClosed && fileSearch.isClosed
        }

        var isIdle: Bool {
            ordinary.isIdle && control.isIdle && smallRead.isIdle && gitRead.isIdle && fileSearch.isIdle
        }
    }
#endif

/// Cancellation-aware async semaphore used to serialize calls per connection.
actor AsyncLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
        let enqueuedAtNanoseconds: UInt64
        var previousID: UUID?
        var nextID: UUID?
    }

    private let limit: Int
    private var permits: Int
    private var activePermitCount = 0
    private var inFlight = 0
    private var isClosed = false
    private var waiterByID: [UUID: Waiter] = [:]
    private var firstWaiterID: UUID?
    private var lastWaiterID: UUID?
    private var idleWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var cancelledWaiterCount = 0
    private let idleWaitSleep: @Sendable (Duration) async throws -> Void

    #if DEBUG
        struct DebugSnapshot: Equatable {
            let limit: Int
            let permits: Int
            let activePermitCount: Int
            let waiterCount: Int
            let inFlight: Int
            let oldestWaiterAgeMilliseconds: UInt64?
            let cancelledWaiterCount: Int
            let isClosed: Bool
            let isIdle: Bool
        }

        private let debugNowNanoseconds: @Sendable () -> UInt64
        private var debugStateObserver: ((DebugSnapshot) -> Void)?
        private var debugQueuedPermitHandoffHandler: (@Sendable () async -> Void)?
    #endif

    #if DEBUG
        init(
            limit: Int,
            debugNowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
            idleWaitSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
                try await Task.sleep(for: duration)
            }
        ) {
            self.limit = max(1, limit)
            permits = max(1, limit)
            self.debugNowNanoseconds = debugNowNanoseconds
            self.idleWaitSleep = idleWaitSleep
        }
    #else
        init(limit: Int) {
            self.limit = max(1, limit)
            permits = max(1, limit)
            idleWaitSleep = { duration in
                try await Task.sleep(for: duration)
            }
        }
    #endif

    private func acquirePermit() async throws {
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }

        if permits > 0 {
            permits -= 1
            activePermitCount += 1
            notifyDebugStateChanged()
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !isClosed else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                appendWaiter(Waiter(
                    id: waiterID,
                    continuation: continuation,
                    enqueuedAtNanoseconds: currentDebugNanoseconds(),
                    previousID: lastWaiterID,
                    nextID: nil
                ))
                notifyDebugStateChanged()
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }

        #if DEBUG
            if let debugQueuedPermitHandoffHandler {
                await debugQueuedPermitHandoffHandler()
            }
        #endif
        guard !isClosed else {
            releasePermit()
            throw CancellationError()
        }
    }

    private func appendWaiter(_ waiter: Waiter) {
        if let lastWaiterID, var lastWaiter = waiterByID[lastWaiterID] {
            lastWaiter.nextID = waiter.id
            waiterByID[lastWaiterID] = lastWaiter
        } else {
            firstWaiterID = waiter.id
        }
        waiterByID[waiter.id] = waiter
        lastWaiterID = waiter.id
    }

    @discardableResult
    private func removeWaiter(_ waiterID: UUID) -> Waiter? {
        guard let waiter = waiterByID.removeValue(forKey: waiterID) else { return nil }
        if let previousID = waiter.previousID, var previous = waiterByID[previousID] {
            previous.nextID = waiter.nextID
            waiterByID[previousID] = previous
        } else {
            firstWaiterID = waiter.nextID
        }
        if let nextID = waiter.nextID, var next = waiterByID[nextID] {
            next.previousID = waiter.previousID
            waiterByID[nextID] = next
        } else {
            lastWaiterID = waiter.previousID
        }
        return waiter
    }

    private func popFirstWaiter() -> Waiter? {
        guard let firstWaiterID else { return nil }
        return removeWaiter(firstWaiterID)
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let waiter = removeWaiter(waiterID) else { return }
        cancelledWaiterCount += 1
        waiter.continuation.resume(throwing: CancellationError())
        notifyDebugStateChanged()
    }

    private func releasePermit() {
        if let waiter = popFirstWaiter() {
            waiter.continuation.resume()
        } else {
            activePermitCount = max(0, activePermitCount - 1)
            permits = min(permits + 1, limit)
        }
        notifyDebugStateChanged()
    }

    /// Rejects new acquisitions and promptly cancels every queued waiter.
    func cancelAll() {
        isClosed = true
        while let waiter = popFirstWaiter() {
            cancelledWaiterCount += 1
            waiter.continuation.resume(throwing: CancellationError())
        }
        notifyDebugStateChanged()
        resumeIdleWaitersIfNeeded()
    }

    /// Waits until active owners and cancelled queued callers have left `withPermit`.
    /// Returns `false` when the caller cancels its join; active owners are never force-released.
    func waitUntilIdle() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard !isIdle else { return true }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                guard !isIdle else {
                    continuation.resume(returning: true)
                    return
                }
                idleWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancelIdleWaiter(waiterID) }
        }
    }

    /// Gives active owners a bounded cooperative cleanup grace. A timed-out owner remains
    /// attached only to this closed limiter and may settle later without blocking teardown.
    func waitUntilIdle(timeout: Duration) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard !isIdle else { return true }
        let sleep = idleWaitSleep
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return true }
                return await waitUntilIdle()
            }
            group.addTask {
                do {
                    try await sleep(timeout)
                    return false
                } catch {
                    return nil
                }
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first ?? false
        }
    }

    /// Number of active and queued operations (0 means idle).
    func activeCount() -> Int {
        inFlight
    }

    private var isIdle: Bool {
        inFlight == 0 && activePermitCount == 0 && waiterByID.isEmpty
    }

    private func cancelIdleWaiter(_ waiterID: UUID) {
        idleWaiters.removeValue(forKey: waiterID)?.resume(returning: false)
    }

    private func resumeIdleWaitersIfNeeded() {
        guard isIdle, !idleWaiters.isEmpty else { return }
        let continuations = Array(idleWaiters.values)
        idleWaiters.removeAll()
        for continuation in continuations {
            continuation.resume(returning: true)
        }
    }

    #if DEBUG
        func debugSnapshot() -> DebugSnapshot {
            makeDebugSnapshot()
        }

        func setDebugStateObserver(
            _ observer: ((DebugSnapshot) -> Void)?
        ) {
            debugStateObserver = observer
            observer?(makeDebugSnapshot())
        }

        func setDebugQueuedPermitHandoffHandler(
            _ handler: (@Sendable () async -> Void)?
        ) {
            debugQueuedPermitHandoffHandler = handler
        }

        private func makeDebugSnapshot() -> DebugSnapshot {
            let now = debugNowNanoseconds()
            let oldestWaiterAgeMilliseconds = firstWaiterID
                .flatMap { waiterByID[$0] }
                .map { Self.elapsedMilliseconds(since: $0.enqueuedAtNanoseconds, now: now) }
            return DebugSnapshot(
                limit: limit,
                permits: permits,
                activePermitCount: activePermitCount,
                waiterCount: waiterByID.count,
                inFlight: inFlight,
                oldestWaiterAgeMilliseconds: oldestWaiterAgeMilliseconds,
                cancelledWaiterCount: cancelledWaiterCount,
                isClosed: isClosed,
                isIdle: isIdle
            )
        }

        private static func elapsedMilliseconds(since start: UInt64, now: UInt64) -> UInt64 {
            guard now >= start else { return 0 }
            return (now - start) / 1_000_000
        }

        private func currentDebugNanoseconds() -> UInt64 {
            debugNowNanoseconds()
        }

        private func notifyDebugStateChanged() {
            debugStateObserver?(makeDebugSnapshot())
        }
    #else
        private func currentDebugNanoseconds() -> UInt64 {
            0
        }

        private func notifyDebugStateChanged() {}
    #endif

    /// Executes an operation with a permit, limiting concurrency.
    func withPermit<T>(
        _ op: @Sendable () async throws -> T
    ) async throws -> T {
        inFlight += 1
        notifyDebugStateChanged()
        defer {
            inFlight -= 1
            notifyDebugStateChanged()
            resumeIdleWaitersIfNeeded()
        }

        try await acquirePermit()
        defer { releasePermit() }
        try Task.checkCancellation()
        return try await op()
    }

    func withPermit<T>(
        cancellationResult: @Sendable () -> T,
        _ op: @Sendable () async -> T
    ) async -> T {
        do {
            return try await withPermit {
                await op()
            }
        } catch {
            return cancellationResult()
        }
    }
}
