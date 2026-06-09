//
//  MCPService.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-06-26.
//

import Foundation
import RepoPromptShared
import SwiftUI

#if DEBUG
    private var mcpServiceDebugLoggingEnabled = false
    private func mcpServiceLog(_ message: @autoclosure () -> String) {
        guard mcpServiceDebugLoggingEnabled else { return }
        print("[MCPService] \(message())")
    }
#else
    private func mcpServiceLog(_ message: @autoclosure () -> String) {}
#endif

/// Background actor that manages the single MCP server instance and handles all networking/file I/O operations.
/// This actor ensures that no long-running network or file-system work ever executes on @MainActor.
actor MCPService: Sendable {
    struct ListenerOperations: @unchecked Sendable {
        let start: @Sendable () async throws -> Void
        let stop: @Sendable () async -> Void
        let fullShutdown: @Sendable () async -> Void

        static let live = ListenerOperations(
            start: { await ServerController.shared.startServer() },
            stop: { await ServerController.shared.stopServer() },
            fullShutdown: { await ServerController.shared.fullShutdown() }
        )
    }

    // ──────────────────────────────────────────────
    // MARK: - Public state that the UI may query

    /// ──────────────────────────────────────────────
    struct Snapshot: Equatable {
        var isRunning: Bool
        var pendingClientID: String?
        var diagnostics: MCPDiagnostics
    }

    private var state = Snapshot(
        isRunning: false,
        pendingClientID: nil,
        diagnostics: MCPDiagnostics()
    )

    /// Async publisher for incremental updates
    private let updates = AsyncStream.makeStream(of: Snapshot.self)

    nonisolated var stateStream: AsyncStream<Snapshot> {
        updates.stream
    }

    /// Subscribers for dashboard updates (multicast to all windows)
    private var dashboardSubscribers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Creates a new dashboard update stream for a subscriber.
    /// Each subscriber gets their own stream to avoid event stealing between windows.
    func subscribeToDashboardUpdates() -> (id: UUID, stream: AsyncStream<Void>) {
        let id = UUID()
        var continuation: AsyncStream<Void>.Continuation!
        let stream = AsyncStream<Void> { cont in
            continuation = cont
        }
        dashboardSubscribers[id] = continuation
        return (id, stream)
    }

    /// Unsubscribes from dashboard updates
    func unsubscribeFromDashboardUpdates(id: UUID) {
        if let cont = dashboardSubscribers.removeValue(forKey: id) {
            cont.finish()
        }
    }

    /// Returns the latest server snapshot synchronously (callers must `await`).
    func currentState() -> Snapshot {
        state
    }

    // ──────────────────────────────────────────────
    // MARK: - Private implementation objects

    /// ──────────────────────────────────────────────
    private let controller = ServerController.shared
    private let listenerOperations: ListenerOperations
    private let participationEligibility: @Sendable (Int) async -> Bool
    nonisolated let networkManager: ServerNetworkManager

    nonisolated var runtimeSessionRegistry: MCPRuntimeSessionRegistry {
        networkManager.runtimeSessionRegistry
    }

    nonisolated var serviceRegistry: MCPServiceRegistry {
        networkManager.serviceRegistry
    }

    /// Desired participation is authoritative; actual listener state is reconciled serially.
    private var desiredParticipatingWindows = Set<Int>()
    private var participationRequestGeneration: UInt64 = 0
    private var latestParticipationRequestByWindow: [Int: UInt64] = [:]
    private var listenerReconciliation: (id: UUID, task: Task<Void, Error>)?
    private var terminalShutdown = false

    // ──────────────────────────────────────────────
    // MARK: - Initialization

    /// ──────────────────────────────────────────────
    init(
        networkManager: ServerNetworkManager = .shared,
        listenerOperations: ListenerOperations = .live,
        participationEligibility: (@Sendable (Int) async -> Bool)? = nil,
        configureControllerCallbacks: Bool = true
    ) {
        self.networkManager = networkManager
        self.listenerOperations = listenerOperations
        let runtimeSessionRegistry = networkManager.runtimeSessionRegistry
        self.participationEligibility = participationEligibility ?? { windowID in
            await MainActor.run {
                runtimeSessionRegistry.hasMCPEnabledWindow(id: windowID)
            }
        }
        guard configureControllerCallbacks else { return }
        // Set up the approval request callback
        Task {
            await controller.setMCPService(self)
            await controller.setApprovalCallback { [weak self] clientID in
                await self?.setPendingApproval(clientID)
            }
            await networkManager.setDashboardDidChangeHook { [weak self] in
                Task { await self?.notifyDashboardUpdate() }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Commands called from the UI layer

    /// ──────────────────────────────────────────────
    func start() async throws {
        guard !terminalShutdown, !state.isRunning else { return }
        // One-time Codex migration: no-op when the RepoPrompt entry or config file is missing.
        _ = MCPIntegrationHelper.ensureCodexToolTimeout()
        mcpServiceLog("Starting MCP listener")
        try await listenerOperations.start()
        state.isRunning = true
        updates.continuation.yield(state)
    }

    func stop() async {
        guard state.isRunning else { return }
        mcpServiceLog("Stopping MCP listener")
        await listenerOperations.stop()
        state.isRunning = false
        updates.continuation.yield(state)
    }

    func join(windowID: Int) async throws {
        try await reconcileParticipation(windowID: windowID, propagatesStartFailure: true)
    }

    func leave(windowID: Int) async {
        do {
            try await reconcileParticipation(windowID: windowID, propagatesStartFailure: false)
        } catch {
            mcpServiceLog("Failed to reconcile MCP leave for window \(windowID): \(error)")
        }
    }

    private func reconcileParticipation(windowID: Int, propagatesStartFailure: Bool) async throws {
        participationRequestGeneration &+= 1
        let requestGeneration = participationRequestGeneration
        latestParticipationRequestByWindow[windowID] = requestGeneration

        let isEligible = await participationEligibility(windowID)
        guard !terminalShutdown,
              latestParticipationRequestByWindow[windowID] == requestGeneration
        else {
            mcpServiceLog("Ignoring stale MCP participation request for window \(windowID)")
            updates.continuation.yield(state)
            return
        }

        if isEligible {
            desiredParticipatingWindows.insert(windowID)
        } else {
            desiredParticipatingWindows.remove(windowID)
        }
        mcpServiceLog(
            "Window \(windowID) participation reconciled (eligible: \(isEligible), desired total: \(desiredParticipatingWindows.count))"
        )

        do {
            try await settleListenerState()
        } catch {
            updates.continuation.yield(state)
            if propagatesStartFailure { throw error }
        }

        // Always re-broadcast so callers receive an up-to-date snapshot even for idempotent work.
        updates.continuation.yield(state)
    }

    private func settleListenerState() async throws {
        while true {
            let reconciliation: (id: UUID, task: Task<Void, Error>)
            if let existing = listenerReconciliation {
                reconciliation = existing
            } else {
                guard state.isRunning != (!desiredParticipatingWindows.isEmpty && !terminalShutdown) else {
                    return
                }
                let id = UUID()
                let task = Task { [weak self] in
                    guard let self else { return }
                    try await performNextListenerTransition()
                }
                reconciliation = (id, task)
                listenerReconciliation = reconciliation
            }

            do {
                try await reconciliation.task.value
            } catch {
                if listenerReconciliation?.id == reconciliation.id {
                    listenerReconciliation = nil
                }
                if desiredParticipatingWindows.isEmpty || terminalShutdown {
                    continue
                }
                throw error
            }
            if listenerReconciliation?.id == reconciliation.id {
                listenerReconciliation = nil
            }
        }
    }

    private func performNextListenerTransition() async throws {
        let shouldRun = !desiredParticipatingWindows.isEmpty && !terminalShutdown
        if shouldRun, !state.isRunning {
            do {
                try await start()
            } catch {
                guard !desiredParticipatingWindows.isEmpty, !terminalShutdown else { return }
                throw error
            }
        } else if !shouldRun, state.isRunning {
            await stop()
        }
    }

    /// Force a state refresh (useful when UI needs immediate update)
    func refreshState() async {
        updates.continuation.yield(state)
    }

    func updateDiagnostics(_ diag: MCPDiagnostics) {
        state.diagnostics = diag
        updates.continuation.yield(state)
    }

    /// Called when a client successfully connects/approves.
    /// Clears any previous error events for this client from the UI.
    func clientConnectedSuccessfully(name: String) async {
        mcpServiceLog("Client connected successfully: \(name)")
        await MainActor.run {
            MCPExternalEventsMonitor.shared.clearEventForClient(name)
        }
        // Trigger state update so the UI refreshes the dashboard
        updates.continuation.yield(state)
    }

    /// Expose enable/disable for Settings
    func setEnabled(_ flag: Bool) async {
        mcpServiceLog("Setting MCP server enabled: \(flag)")
        await controller.setEnabled(flag)
        // No state change for UI, so no yield necessary
    }

    func fullShutdown() async {
        mcpServiceLog("Performing full MCP server shutdown")
        terminalShutdown = true
        desiredParticipatingWindows.removeAll()
        participationRequestGeneration &+= 1
        latestParticipationRequestByWindow.removeAll()
        try? await settleListenerState()
        await listenerOperations.fullShutdown()
        state.isRunning = false
        terminalShutdown = false
        updates.continuation.yield(state)
    }

    func currentRequestConnectionID() async -> UUID? {
        await ServerNetworkManager.shared.currentConnectionUUID()
    }

    func currentRequestClientName() async -> String? {
        await ServerNetworkManager.shared.currentClientIdentifier()
    }

    func currentRequestClientID() async -> String? {
        await currentRequestClientName()
    }

    func currentRequestWindowID() async -> Int? {
        await ServerNetworkManager.shared.currentConnectionWindowID()
    }

    // ──────────────────────────────────────────────
    // MARK: - Connection approval bridge

    /// ──────────────────────────────────────────────
    /// Called by the MainActor after the alert sheet closes
    /// Runs on the actor executor – no extra Task hop required.
    func continuePendingApproval(allow: Bool, alwaysAllow: Bool = false) async {
        await controller.resolvePendingApproval(
            allow: allow,
            alwaysAllow: alwaysAllow
        )
        // Clear the pending client ID and notify observers.
        state.pendingClientID = nil
        updates.continuation.yield(state)
    }

    /// Controller → Service callback - called when a new client requests approval
    private func setPendingApproval(_ clientID: String?) {
        mcpServiceLog("Setting pending approval for client: \(clientID ?? "nil")")
        state.pendingClientID = clientID
        updates.continuation.yield(state)
    }

    // ──────────────────────────────────────────────
    // MARK: - Dashboard API

    // ──────────────────────────────────────────────

    /// Dashboard connection entry mirroring ServerNetworkManager's model
    struct DashboardConnection: Identifiable {
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
        let activeToolName: String?
        /// Session key (capabilityToken) for disambiguating multiple client instances
        let sessionKey: String?
    }

    /// Tool call history entry for dashboard display
    struct ToolCallHistoryEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let toolName: String
        let clientName: String
    }

    /// Complete dashboard snapshot exposed to UI
    struct DashboardSnapshot {
        let isRunning: Bool
        let diagnostics: MCPDiagnostics
        let connections: [DashboardConnection]
        let recentToolCalls: [ToolCallHistoryEntry]
        let alwaysAllowedClients: [String]
        let autoApproveAllClients: Bool
    }

    /// Returns a complete dashboard snapshot for the UI
    func dashboardSnapshot() async -> DashboardSnapshot {
        let raw = await controller.dashboardSnapshot(currentDiagnostics: state.diagnostics)

        let connections = raw.connections.connections.map {
            DashboardConnection(
                id: $0.id,
                clientName: $0.clientName,
                windowID: $0.windowID,
                transport: $0.transport,
                state: $0.state,
                createdAt: $0.createdAt,
                lastToolCallAt: $0.lastToolCallAt,
                totalToolCalls: $0.totalToolCalls,
                idleSeconds: $0.idleSeconds,
                hasInFlightCalls: $0.hasInFlightCalls,
                activeToolName: $0.activeToolName,
                sessionKey: $0.sessionKey
            )
        }

        let recentToolCalls = raw.connections.recentToolCalls.map {
            ToolCallHistoryEntry(
                timestamp: $0.timestamp,
                toolName: $0.toolName,
                clientName: $0.clientName
            )
        }

        return DashboardSnapshot(
            isRunning: state.isRunning,
            diagnostics: state.diagnostics,
            connections: connections,
            recentToolCalls: recentToolCalls,
            alwaysAllowedClients: raw.alwaysAllowedClients,
            autoApproveAllClients: raw.autoApproveAllClients
        )
    }

    /// Forcefully disconnect a specific connection (legacy - use terminateConnection)
    func bootConnection(id: UUID) async {
        await controller.bootConnection(id: id)
    }

    /// Terminates a connection with explicit kill semantics.
    /// CLI will exit without retrying.
    func terminateConnection(id: UUID, reason: TerminationReason, message: String? = nil) async {
        await controller.terminateConnection(id: id, reason: reason, message: message)
    }

    /// Add or remove a client from the persistent allow-list
    func setAlwaysAllowed(clientID: String, allowed: Bool) async {
        await controller.setAlwaysAllowed(clientID: clientID, allowed: allowed)
    }

    /// Set the global auto-approve flag
    func setAutoApproveAllClients(_ enabled: Bool) async {
        await controller.setAutoApproveAllClients(enabled)
    }

    // ──────────────────────────────────────────────
    // MARK: - Dashboard Update Notifications

    // ──────────────────────────────────────────────

    /// Notify that dashboard data has changed (connection added/removed, tool call, etc.)
    /// Called by ServerNetworkManager when connection state changes.
    /// Broadcasts to all subscribed windows.
    func notifyDashboardUpdate() {
        mcpServiceLog("Broadcasting dashboard update to \(dashboardSubscribers.count) subscriber(s)")
        for (_, continuation) in dashboardSubscribers {
            continuation.yield(())
        }
    }
}
