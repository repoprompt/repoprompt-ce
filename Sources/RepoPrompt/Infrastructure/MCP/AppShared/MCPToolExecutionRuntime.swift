import Foundation
import RepoPromptInstrumentation
import RepoPromptShared

/// Execution bookkeeping shared by providers and MCP tool dispatch, independent of presentation.
/// Cancellation unregisters tracking immediately, as before; idle is not a durable side-effect drain.
@MainActor
final class MCPToolExecutionRuntime {
    var didChange: (() -> Void)?

    #if DEBUG
        var beforeAgentRunWaiterWakeForTesting: (@MainActor @Sendable (UUID, UUID) async -> Void)?
    #endif

    private static let enableSteeringDebugLogging = false

    private func steeringDebugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
            guard Self.enableSteeringDebugLogging else { return }
            print(message())
        #endif
    }

    var activeExecutionCount: Int {
        activeToolExecutionsByID.count
    }

    func containsExecution(_ id: UUID) -> Bool {
        activeToolExecutionsByID[id] != nil
    }

    func executionIDs(connectionID: UUID) -> Set<UUID> {
        activeToolExecutionIDsByConnectionID[connectionID] ?? []
    }

    #if DEBUG
        func waitScopeCount(parentRunID: UUID) -> Int {
            purgeStaleAgentRunWaitScopes(source: "test-count")
            return agentRunWaitScopesByToken.values.count { $0.parentRunID == parentRunID }
        }
    #endif

    /// Token-primary active tool execution tracking. Run ID is a secondary index;
    /// executions remain connection-owned and cancellable even when no run resolves.
    @MainActor
    private struct ActiveToolExecution {
        let executionID: UUID
        let runID: UUID?
        let connectionID: UUID?
        let toolName: String
        let lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
        let startedAt: Date
        let cancel: () -> Void
    }

    @MainActor
    private var activeToolExecutionsByID: [UUID: ActiveToolExecution] = [:]
    @MainActor
    private var activeToolExecutionIDsByRunID: [UUID: Set<UUID>] = [:]
    @MainActor
    private var activeToolExecutionIDsByConnectionID: [UUID: Set<UUID>] = [:]

    @MainActor
    private struct AgentRunWaitScope {
        let token: UUID
        let parentRunID: UUID
        let childSessionIDs: Set<UUID>
        let startedAt: Date
        let timeoutSeconds: TimeInterval
        let metadata: MCPRequestMetadata
    }

    @MainActor
    private var agentRunWaitScopesByToken: [UUID: AgentRunWaitScope] = [:]
    @MainActor
    private var childAgentRunWaitCountsByParentRunID: [UUID: [UUID: Int]] = [:]
    private let agentRunWaitScopeStaleGraceSeconds: TimeInterval = 60

    /// Cumulative count of tool executions that have ended (success/error/cancel) per run.
    /// Used by the Claude steering interrupt safety gate to verify that the provider stream
    /// has acknowledged all locally-completed tool results before sending an interrupt.
    @MainActor
    private var toolEndedCountByRunID: [UUID: Int] = [:]

    /// Continuations parked by `awaitNoActiveToolExecutions` waiting for a runID to have zero
    /// in-flight tool executions. Keyed by runID → waiterID → continuation.
    @MainActor
    private var toolIdleWaitersByRunID: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]

    @MainActor
    private func debugActiveTools(for runID: UUID) -> String {
        let executionIDs = activeToolExecutionIDsByRunID[runID] ?? []
        guard !executionIDs.isEmpty else { return "none" }
        return executionIDs.compactMap { activeToolExecutionsByID[$0] }
            .map { "\($0.toolName)#\(String($0.executionID.uuidString.prefix(8)))" }
            .sorted()
            .joined(separator: ",")
    }

    @MainActor
    @discardableResult
    func cancelActiveToolsForRun(runID: UUID, reason: String? = nil) -> Int {
        let executionIDs = activeToolExecutionIDsByRunID[runID] ?? []
        guard !executionIDs.isEmpty else {
            resumeAllToolIdleWaiters(forRunID: runID)
            toolEndedCountByRunID.removeValue(forKey: runID)
            return 0
        }

        var cancelledCount = 0
        for executionID in executionIDs {
            if cancelToolExecution(executionID: executionID, reason: reason) {
                cancelledCount += 1
            }
        }
        toolEndedCountByRunID.removeValue(forKey: runID)
        return cancelledCount
    }

    @MainActor
    func registerToolExecution(
        executionID: UUID,
        runID: UUID?,
        connectionID: UUID?,
        toolName: String,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation? = nil,
        cancel: @escaping () -> Void
    ) {
        let execution = ActiveToolExecution(
            executionID: executionID,
            runID: runID,
            connectionID: connectionID,
            toolName: toolName,
            lifecycleCorrelation: lifecycleCorrelation,
            startedAt: Date(),
            cancel: cancel
        )
        activeToolExecutionsByID[executionID] = execution
        if let runID {
            activeToolExecutionIDsByRunID[runID, default: []].insert(executionID)
            steeringDebugLog("[AgentRunSteeringWake] MCP tool register runID=\(runID) executionID=\(executionID) tool=\(toolName) active=\(debugActiveTools(for: runID))")
        }
        if let connectionID {
            activeToolExecutionIDsByConnectionID[connectionID, default: []].insert(executionID)
        }
        didChange?()
    }

    @MainActor
    func unregisterToolExecution(
        executionID: UUID,
        countAsEnded: Bool = true
    ) {
        guard let execution = activeToolExecutionsByID.removeValue(forKey: executionID) else {
            steeringDebugLog("[AgentRunSteeringWake] MCP tool unregister ignored missing executionID=\(executionID)")
            return
        }

        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.MCPRunTool.unregister,
            correlation: execution.lifecycleCorrelation,
            EditFlowPerf.Dimensions(toolName: execution.toolName)
        )

        if let connectionID = execution.connectionID {
            activeToolExecutionIDsByConnectionID[connectionID]?.remove(executionID)
            if activeToolExecutionIDsByConnectionID[connectionID]?.isEmpty == true {
                activeToolExecutionIDsByConnectionID.removeValue(forKey: connectionID)
            }
        }

        if let runID = execution.runID {
            activeToolExecutionIDsByRunID[runID]?.remove(executionID)
            if countAsEnded {
                toolEndedCountByRunID[runID, default: 0] += 1
            }
            if activeToolExecutionIDsByRunID[runID]?.isEmpty == true {
                activeToolExecutionIDsByRunID.removeValue(forKey: runID)
                steeringDebugLog("[AgentRunSteeringWake] MCP tool unregister drained runID=\(runID) executionID=\(executionID) tool=\(execution.toolName) endedCount=\(toolEndedCountByRunID[runID] ?? 0)")
                resumeAllToolIdleWaiters(forRunID: runID, lifecycleCorrelation: execution.lifecycleCorrelation)
            } else {
                steeringDebugLog("[AgentRunSteeringWake] MCP tool unregister runID=\(runID) executionID=\(executionID) tool=\(execution.toolName) remaining=\(debugActiveTools(for: runID)) endedCount=\(toolEndedCountByRunID[runID] ?? 0)")
            }
        }

        didChange?()
    }

    @MainActor
    func toolEndedCount(runID: UUID) -> Int {
        toolEndedCountByRunID[runID] ?? 0
    }

    @MainActor
    func hasActiveToolExecutions(runID: UUID) -> Bool {
        !(activeToolExecutionIDsByRunID[runID]?.isEmpty ?? true)
    }

    @MainActor
    func hasActiveChildAgentRunWaits(runID: UUID) -> Bool {
        purgeStaleAgentRunWaitScopes(source: "liveness-query")
        let active = !(childAgentRunWaitCountsByParentRunID[runID]?.isEmpty ?? true)
        if active {
            let scopes = agentRunWaitScopesByToken.values.filter { $0.parentRunID == runID }
            let oldestAge = scopes.map { Date().timeIntervalSince($0.startedAt) }.max() ?? 0
            steeringDebugLog("[AgentRunSteeringWake] agent_run wait scope liveness parentRunID=\(runID) scopes=\(scopes.count) oldestAge=\(oldestAge) counts=\(debugChildAgentRunWaits(for: runID))")
        }
        return active
    }

    @MainActor
    func awaitNoActiveToolExecutions(runID: UUID) async throws {
        try Task.checkCancellation()
        // Fast path: already idle
        let executions = activeToolExecutionIDsByRunID[runID]
        if executions == nil || executions!.isEmpty {
            steeringDebugLog("[AgentRunSteeringWake] MCP idle wait fast-idle runID=\(runID)")
            return
        }
        steeringDebugLog("[AgentRunSteeringWake] MCP idle wait blocking runID=\(runID) active=\(debugActiveTools(for: runID))")

        let waiterID = UUID()

        // Use withTaskCancellationHandler so that Task.cancel() from the
        // outside (e.g., user cancels the run) will promptly resume us.
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Double-check under the same MainActor turn — tools may have
                // drained between the fast-path check and here.
                let stillActive = activeToolExecutionIDsByRunID[runID]
                if Task.isCancelled || stillActive == nil || stillActive!.isEmpty {
                    steeringDebugLog("[AgentRunSteeringWake] MCP idle wait drained before parking runID=\(runID) waiterID=\(waiterID)")
                    continuation.resume()
                    return
                }
                toolIdleWaitersByRunID[runID, default: [:]][waiterID] = continuation
                steeringDebugLog("[AgentRunSteeringWake] MCP idle wait parked runID=\(runID) waiterID=\(waiterID) active=\(debugActiveTools(for: runID)) waiters=\(toolIdleWaitersByRunID[runID]?.count ?? 0)")
            }
        } onCancel: {
            // Must hop to MainActor to safely remove the waiter.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let continuation = toolIdleWaitersByRunID[runID]?
                    .removeValue(forKey: waiterID)
                {
                    continuation.resume() // unblock so CancellationError propagates
                }
                if toolIdleWaitersByRunID[runID]?.isEmpty == true {
                    toolIdleWaitersByRunID.removeValue(forKey: runID)
                }
            }
        }

        // After resuming, respect cooperative cancellation
        try Task.checkCancellation()
        steeringDebugLog("[AgentRunSteeringWake] MCP idle wait completed runID=\(runID) waiterID=\(waiterID)")
    }

    @MainActor
    private func resumeAllToolIdleWaiters(
        forRunID runID: UUID,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation? = nil
    ) {
        let waiters = toolIdleWaitersByRunID.removeValue(forKey: runID)
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.MCPRunTool.idleWaitersResumed,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(waiterCount: waiters?.count ?? 0)
        )
        guard let waiters else {
            steeringDebugLog("[AgentRunSteeringWake] MCP idle wait resume skipped no waiters runID=\(runID)")
            return
        }
        steeringDebugLog("[AgentRunSteeringWake] MCP idle wait resuming runID=\(runID) waiters=\(waiters.count)")
        for (_, continuation) in waiters {
            continuation.resume()
        }
    }

    @MainActor
    @discardableResult
    func cancelToolExecution(executionID: UUID, reason: String?) -> Bool {
        guard let execution = activeToolExecutionsByID[executionID] else {
            return false
        }
        execution.cancel()
        unregisterToolExecution(executionID: executionID)
        return true
    }

    @MainActor
    func endAgentRunWaitScope(_ token: UUID, completion: AgentRunWaitScopeCompletion) {
        guard let scope = agentRunWaitScopesByToken.removeValue(forKey: token) else {
            steeringDebugLog("[AgentRunSteeringWake] agent_run wait scope end ignored missing token=\(token) reason=\(completion.reason.rawValue)")
            return
        }
        decrementAgentRunWaitScope(scope)
        let elapsed = Date().timeIntervalSince(scope.startedAt)
        steeringDebugLog("[AgentRunSteeringWake] agent_run wait scope end parentRunID=\(scope.parentRunID) token=\(token) elapsed=\(elapsed) reason=\(completion.reason.rawValue) result=\(completion.result ?? "none") winner=\(completion.winnerSessionID?.uuidString ?? "none") pending=\(completion.pendingSessionIDs.map(\.uuidString).sorted().joined(separator: ",")) childSessions=\(scope.childSessionIDs.map(\.uuidString).sorted().joined(separator: ",")) remaining=\(debugChildAgentRunWaits(for: scope.parentRunID))")
    }

    @MainActor
    private func decrementAgentRunWaitScope(_ scope: AgentRunWaitScope) {
        for sessionID in scope.childSessionIDs {
            let existing = childAgentRunWaitCountsByParentRunID[scope.parentRunID]?[sessionID] ?? 0
            if existing <= 1 {
                childAgentRunWaitCountsByParentRunID[scope.parentRunID]?.removeValue(forKey: sessionID)
            } else {
                childAgentRunWaitCountsByParentRunID[scope.parentRunID]?[sessionID] = existing - 1
            }
        }
        if childAgentRunWaitCountsByParentRunID[scope.parentRunID]?.isEmpty == true {
            childAgentRunWaitCountsByParentRunID.removeValue(forKey: scope.parentRunID)
        }
    }

    @MainActor
    func purgeStaleAgentRunWaitScopes(now: Date = Date(), source: String) {
        let staleTokens = agentRunWaitScopesByToken.compactMap { token, scope -> UUID? in
            let maxAge = scope.timeoutSeconds + agentRunWaitScopeStaleGraceSeconds
            return now.timeIntervalSince(scope.startedAt) > maxAge ? token : nil
        }
        for token in staleTokens {
            guard let scope = agentRunWaitScopesByToken.removeValue(forKey: token) else { continue }
            decrementAgentRunWaitScope(scope)
            let elapsed = now.timeIntervalSince(scope.startedAt)
            steeringDebugLog("[AgentRunSteeringWake] agent_run wait scope stale purge source=\(source) parentRunID=\(scope.parentRunID) token=\(token) elapsed=\(elapsed) timeout=\(scope.timeoutSeconds) childSessions=\(scope.childSessionIDs.map(\.uuidString).sorted().joined(separator: ","))")
        }
    }

    @MainActor
    private func debugChildAgentRunWaits(for parentRunID: UUID) -> String {
        let counts = childAgentRunWaitCountsByParentRunID[parentRunID] ?? [:]
        guard !counts.isEmpty else { return "none" }
        return counts
            .map { "\($0.key.uuidString.prefix(8)):\($0.value)" }
            .sorted()
            .joined(separator: ",")
    }

    @MainActor
    func wakeAgentRunWaitersOwnedByActiveRun(
        runID: UUID,
        source: String,
        steeringMessage: String? = nil,
        steeringOriginRunID: () -> UUID? = { nil },
        publicationForSessionID: (UUID) -> (snapshot: AgentRunMCPSnapshot, cursor: AgentRunSessionStore.WaitCursor)?
    ) async {
        let sessionIDs = Set(childAgentRunWaitCountsByParentRunID[runID]?.keys.map(\.self) ?? [])
        guard !sessionIDs.isEmpty else {
            steeringDebugLog("[AgentRunSteeringWake] parent wake found no child agent_run waiters source=\(source) parentRunID=\(runID) active=\(debugActiveTools(for: runID))")
            return
        }
        steeringDebugLog("[AgentRunSteeringWake] parent wake child agent_run waiters source=\(source) parentRunID=\(runID) childSessions=\(sessionIDs.map(\.uuidString).sorted().joined(separator: ",")) active=\(debugActiveTools(for: runID))")
        for sessionID in sessionIDs {
            guard let publication = publicationForSessionID(sessionID) else {
                steeringDebugLog("[AgentRunSteeringWake] parent wake skipped missing child snapshot source=\(source) parentRunID=\(runID) childSessionID=\(sessionID)")
                continue
            }
            #if DEBUG
                if let beforeAgentRunWaiterWakeForTesting {
                    await beforeAgentRunWaiterWakeForTesting(runID, sessionID)
                }
            #endif
            let validatedSteeringOriginRunID = steeringOriginRunID()
            await AgentRunSessionStore.wakeCurrentWaiters(
                publication.snapshot,
                cursor: publication.cursor,
                reason: .steeringRequested,
                steeringMessage: steeringMessage,
                steeringOriginRunID: validatedSteeringOriginRunID
            )
        }
        await Task.yield()
        steeringDebugLog("[AgentRunSteeringWake] parent wake yielded source=\(source) parentRunID=\(runID)")
    }

    @MainActor
    func wakeAndDrainAgentRunWaitersOwnedByActiveRun(
        runID: UUID,
        source: String,
        steeringMessage: String? = nil,
        timeoutSeconds: TimeInterval,
        steeringOriginRunID: () -> UUID? = { nil },
        publicationForSessionID: (UUID) -> (snapshot: AgentRunMCPSnapshot, cursor: AgentRunSessionStore.WaitCursor)?
    ) async -> Bool {
        guard hasActiveChildAgentRunWaits(runID: runID) else {
            steeringDebugLog("[AgentRunSteeringWake] parent drain fast-idle source=\(source) parentRunID=\(runID)")
            return true
        }

        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        while true {
            await wakeAgentRunWaitersOwnedByActiveRun(
                runID: runID,
                source: source,
                steeringMessage: steeringMessage,
                steeringOriginRunID: steeringOriginRunID,
                publicationForSessionID: publicationForSessionID
            )

            guard hasActiveChildAgentRunWaits(runID: runID) else {
                steeringDebugLog("[AgentRunSteeringWake] parent drain completed source=\(source) parentRunID=\(runID)")
                return true
            }
            guard timeoutSeconds > 0, Date() < deadline else {
                steeringDebugLog("[AgentRunSteeringWake] parent drain timed out source=\(source) parentRunID=\(runID) timeout=\(timeoutSeconds) remaining=\(debugChildAgentRunWaits(for: runID))")
                return false
            }

            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                steeringDebugLog("[AgentRunSteeringWake] parent drain cancelled source=\(source) parentRunID=\(runID)")
                return false
            }
        }
    }

    func beginAgentRunWaitScope(
        parentRunID: UUID,
        metadata: MCPRequestMetadata,
        sessionIDs: Set<UUID>,
        timeoutSeconds: TimeInterval
    ) -> AgentRunWaitScopeRegistration {
        let token = UUID()
        // The caller already froze its resolved wait; stale-scope purging must age against that
        // same value rather than a preference that can change mid-wait.
        let scope = AgentRunWaitScope(
            token: token,
            parentRunID: parentRunID,
            childSessionIDs: sessionIDs,
            startedAt: Date(),
            timeoutSeconds: timeoutSeconds,
            metadata: metadata
        )
        agentRunWaitScopesByToken[token] = scope
        for sessionID in sessionIDs {
            childAgentRunWaitCountsByParentRunID[parentRunID, default: [:]][sessionID, default: 0] += 1
        }
        steeringDebugLog("[AgentRunSteeringWake] agent_run wait scope begin parentRunID=\(parentRunID) token=\(token) timeout=\(timeoutSeconds) childSessions=\(sessionIDs.map(\.uuidString).sorted().joined(separator: ",")) counts=\(debugChildAgentRunWaits(for: parentRunID))")
        return AgentRunWaitScopeRegistration(token: token, parentRunID: parentRunID)
    }

    /// The existing exactly-once cleanup claim and execution owner survive presentation loss.
    /// Completion still removes steering bookkeeping, not a durable side-effect barrier.
    func makeCompletionHandler(
        executionID: UUID,
        toolName: String,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation? = nil,
        didFinish: (@MainActor @Sendable () -> Void)? = nil
    ) -> @Sendable (String) async -> Void {
        let cleanupClaim = MCPRunToolCleanupClaim()
        return { [self] outcome in
            guard cleanupClaim.claim() else { return }
            let cleanupState = EditFlowPerf.begin(
                EditFlowPerf.Stage.MCPToolCall.runToolCompletionCleanup,
                EditFlowPerf.Dimensions(toolName: toolName)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPRunTool.cleanupScheduled,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(toolName: toolName, outcome: outcome)
            )
            await MainActor.run {
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.MCPRunTool.cleanupMainActorEntered,
                    correlation: lifecycleCorrelation,
                    EditFlowPerf.Dimensions(toolName: toolName, outcome: outcome)
                )
                self.unregisterToolExecution(executionID: executionID)
                didFinish?()
            }
            EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.runToolCompletionCleanup, cleanupState)
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPRunTool.cleanupEnded,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(toolName: toolName, outcome: outcome)
            )
        }
    }
}

private final class MCPRunToolCleanupClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
