import Foundation
import MCP

/// A cancellation never retargets after suspension, even to a successor run of the same session.
@MainActor
struct AgentRunCapturedCancellation {
    let sessionID: UUID
    let control: AgentMCPControlContext

    private let session: AgentTabSession
    private let runtime: AgentSessionMCPRuntime
    private let executor: AgentSessionLinkExecutionRuntime
    private let requireOrigin: @MainActor () throws -> Void
    private let binding: AgentPersistentSessionBindingIdentity
    private let controlGeneration: UInt64
    private let ownership: AgentRunOwnership?
    private let runID: UUID?
    private let stopFence: AgentRunStartStopFence
    private let parentSessionID: UUID?
    private let pendingStart: Bool
    private let pendingUpdatedAt: Date?
    private let scheduledProducerID: UUID?

    init?(
        sessionID: UUID, session: AgentTabSession,
        runtime: AgentSessionMCPRuntime, executor: AgentSessionLinkExecutionRuntime,
        requireOrigin: @escaping @MainActor () throws -> Void
    ) {
        guard runtime.controlledWriter(sessionID: sessionID)?.session === session,
              session.activeAgentSessionID == sessionID,
              let binding = session.persistentSessionBindingIdentity,
              let control = session.mcpControlContext,
              session.runState.isActive || session.mcpFollowUpRunPending else { return nil }
        let pendingStart = !session.runState.isActive && session.mcpFollowUpRunPending
        guard pendingStart ? session.activeRunOwnership == nil
            : (session.activeRunOwnership != nil && session.runID != nil) else { return nil }
        self.sessionID = sessionID
        self.session = session
        self.runtime = runtime
        self.executor = executor
        self.requireOrigin = requireOrigin
        self.binding = binding
        self.control = control
        self.pendingStart = pendingStart
        controlGeneration = session.mcpControlActivationGeneration
        ownership = session.activeRunOwnership
        runID = session.runID
        stopFence = AgentRunStartStopFence(session: session)
        parentSessionID = session.parentSessionID
        pendingUpdatedAt = session.mcpFollowUpRunPendingUpdatedAt
        scheduledProducerID = session.scheduledACPFollowUp?.id
    }

    /// The exact context and producer remain the final synchronous fence before cancellation.
    func requireCurrent() throws {
        try Task.checkCancellation()
        try requireOrigin()
        guard runtime.controlledWriter(sessionID: sessionID)?.session === session,
              session.activeAgentSessionID == sessionID,
              session.persistentSessionBindingIdentity == binding,
              session.mcpControlContext == control,
              session.mcpControlActivationGeneration == controlGeneration,
              session.activeRunOwnership == ownership, session.runID == runID,
              session.stopState.cancellationGeneration == stopFence.cancellationGeneration,
              session.parentSessionID == parentSessionID,
              !pendingStart || (
                  session.mcpFollowUpRunPendingUpdatedAt == pendingUpdatedAt
                      && session.scheduledACPFollowUp?.id == scheduledProducerID
              ),
              !session.terminalCommitInProgress,
              pendingStart ? (!session.runState.isActive && session.mcpFollowUpRunPending) : session.runState.isActive
        else { throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID) }
    }

    func cancel() async throws -> Value {
        try requireCurrent()
        let admission = AgentRunCancellationAdmission(
            scope: pendingStart ? .pendingStart : .activeRun,
            session: session, binding: binding,
            expectedOwnership: ownership, expectedRunID: runID,
            cancellationGeneration: stopFence.cancellationGeneration,
            pendingStartFence: pendingStart ? stopFence : nil,
            validateAndClaim: {
                do {
                    try requireCurrent()
                    return true
                } catch { return false }
            }
        )
        let admitted: Bool
        var stopped = false
        var outcomeSnapshot: AgentRunMCPSnapshot?
        if pendingStart {
            admitted = executor.withdrawPendingStartForSessionLink(session: session, admission: admission)
            if admitted { outcomeSnapshot = runtime.mcpSnapshot(for: session) }
        } else {
            guard let ownership else {
                throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID)
            }
            let recorder = AgentRunCancellationOutcomeRecorder(
                expectedOwnership: ownership, expectedRunID: runID, expectedBinding: binding,
                onAcceptedPrimaryPublication: { _ in
                    stopped = true
                    if session.mcpControlContext == control,
                       !session.runState.isActive,
                       session.runID == nil || session.runID == runID
                    {
                        outcomeSnapshot = runtime.mcpSnapshot(
                            for: session, canonicalTerminalState: .cancelled,
                            canonicalProviderRunID: runID
                        )
                    }
                }
            )
            admitted = await executor.cancelAgentRunForSessionLink(
                session: session, admission: admission, outcomeRecorder: recorder,
                completion: .terminalPublished
            )
        }
        guard admitted else { throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID) }
        // The effect is settled. Read no UUID-routed store or successor snapshot after this point.
        // Natural completion can win the terminal race; only the matching original revision may
        // describe that outcome. The receipt still distinguishes initiation from a stopped run.
        if outcomeSnapshot == nil,
           session.persistentSessionBindingIdentity == binding,
           session.mcpControlContext == control,
           !session.runState.isActive,
           session.runID == nil || session.runID == runID,
           let revision = session.lastTerminalCommitRevision,
           revision.ownership == ownership, revision.expectedRunID == runID
        {
            outcomeSnapshot = runtime.mcpSnapshot(
                for: session, canonicalTerminalState: revision.terminalState,
                canonicalProviderRunID: runID
            )
        }
        var result = (outcomeSnapshot ?? AgentRunMCPToolService.agentRunExpiredSnapshot(sessionID: sessionID)).asObject()
        result["cancellation"] = .object([
            "run_id": runID.map { .string($0.uuidString) } ?? .null,
            "initiated": .bool(!pendingStart),
            "stopped": .bool(stopped),
            "pending_start_withdrawn": .bool(pendingStart)
        ])
        return .object(result)
    }
}
