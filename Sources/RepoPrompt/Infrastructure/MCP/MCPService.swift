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
    private let hostBootstrapOperation: @Sendable () async -> Void
    private let controllerStartOperation: @Sendable () async throws -> Void
    private let controllerFullShutdownOperation: @Sendable () async -> Void

    private struct StartAttempt {
        let id: UUID
        let generation: UInt64
        let task: Task<Void, Error>
    }

    private struct TeardownAttempt {
        let id: UUID
        let task: Task<Void, Never>
    }

    private enum LifecycleError: Error {
        case startSuperseded
    }

    private var lifecycleGeneration: UInt64 = 0
    private var activeStartAttempt: StartAttempt?
    private var activeTeardownAttempt: TeardownAttempt?
    private var joinedWindowIDs = Set<Int>()
    #if DEBUG
        private var teardownRequestCount = 0
    #endif

    // ──────────────────────────────────────────────
    // MARK: - Initialization

    /// ──────────────────────────────────────────────
    init(
        hostBootstrapOperation: @escaping @Sendable () async -> Void = {
            // One-time Codex migration: no-op when the RepoPrompt entry or config file is missing.
            _ = MCPIntegrationHelper.ensureCodexToolTimeout()
        },
        controllerStartOperation: @escaping @Sendable () async throws -> Void = {
            try await ServerController.shared.startServer()
        },
        controllerFullShutdownOperation: @escaping @Sendable () async -> Void = {
            await ServerController.shared.fullShutdown()
        }
    ) {
        self.hostBootstrapOperation = hostBootstrapOperation
        self.controllerStartOperation = controllerStartOperation
        self.controllerFullShutdownOperation = controllerFullShutdownOperation
        // Set up the approval request callback
        Task {
            await controller.setMCPService(self)
            await controller.setApprovalCallback { [weak self] clientID in
                await self?.setPendingApproval(clientID)
            }
            await ServerNetworkManager.shared.setDashboardDidChangeHook { [weak self] in
                Task { await self?.notifyDashboardUpdate() }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Commands called from the UI layer

    /// ──────────────────────────────────────────────
    func start() async throws {
        try await ensureTransportRunning()
    }

    private func ensureTransportRunning() async throws {
        while let teardown = activeTeardownAttempt {
            await teardown.task.value
            if activeTeardownAttempt?.id == teardown.id {
                activeTeardownAttempt = nil
            }
        }
        try Task.checkCancellation()
        guard !state.isRunning else { return }

        let attempt: StartAttempt
        if let activeStartAttempt, activeStartAttempt.generation == lifecycleGeneration {
            attempt = activeStartAttempt
        } else {
            lifecycleGeneration &+= 1
            let generation = lifecycleGeneration
            let bootstrap = hostBootstrapOperation
            let operation = controllerStartOperation
            let task = Task {
                await bootstrap()
                mcpServiceLog("Starting MCP listener")
                try await operation()
            }
            attempt = StartAttempt(id: UUID(), generation: generation, task: task)
            activeStartAttempt = attempt
        }

        do {
            try await attempt.task.value
        } catch {
            if activeStartAttempt?.id == attempt.id,
               activeStartAttempt?.generation == attempt.generation,
               lifecycleGeneration == attempt.generation
            {
                activeStartAttempt = nil
                state.isRunning = false
                updates.continuation.yield(state)
            }
            throw error
        }

        guard activeStartAttempt?.id == attempt.id,
              activeStartAttempt?.generation == attempt.generation,
              lifecycleGeneration == attempt.generation
        else {
            if state.isRunning { return }
            throw LifecycleError.startSuperseded
        }

        activeStartAttempt = nil
        state.isRunning = true
        updates.continuation.yield(state)
    }

    private func performTeardown(
        operation: @escaping @Sendable () async -> Void
    ) async {
        #if DEBUG
            teardownRequestCount += 1
        #endif
        lifecycleGeneration &+= 1
        let supersededStartAttempt = activeStartAttempt
        activeStartAttempt = nil
        supersededStartAttempt?.task.cancel()
        state.isRunning = false
        updates.continuation.yield(state)

        let predecessor = activeTeardownAttempt?.task
        let task = Task {
            await predecessor?.value
            await operation()
        }
        let teardown = TeardownAttempt(id: UUID(), task: task)
        activeTeardownAttempt = teardown
        await task.value
        if activeTeardownAttempt?.id == teardown.id {
            activeTeardownAttempt = nil
        }
    }

    /// Attach presentation state only. Process transport ownership belongs to app startup
    /// and explicit lifecycle actions; opening a window must never resurrect a stopped server.
    func join(windowID: Int) async {
        joinedWindowIDs.insert(windowID)
        mcpServiceLog("Window \(windowID) attached to process-owned MCP presentation")
        updates.continuation.yield(state)
    }

    func leave(windowID: Int) async {
        joinedWindowIDs.remove(windowID)
        mcpServiceLog("Window \(windowID) detached from process-owned MCP presentation")
        updates.continuation.yield(state)
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
    func setEnabled(_ flag: Bool) async throws {
        mcpServiceLog("Setting MCP server enabled: \(flag)")
        try await controller.setEnabled(flag)
        // No state change for UI, so no yield necessary
    }

    func fullShutdown() async {
        mcpServiceLog("Performing full MCP server shutdown")
        await performTeardown(operation: controllerFullShutdownOperation)
    }

    #if DEBUG
        func teardownRequestCountForTesting() -> Int {
            teardownRequestCount
        }

        func joinedWindowIDsForTesting() -> Set<Int> {
            joinedWindowIDs
        }
    #endif

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

    func currentRequestExplicitWindowRoutingHint() -> MCPExplicitWindowRoutingHint? {
        ServerNetworkManager.currentExplicitWindowRoutingHint
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
                activeToolScope: $0.activeToolScope,
                activeToolScopes: $0.activeToolScopes,
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
