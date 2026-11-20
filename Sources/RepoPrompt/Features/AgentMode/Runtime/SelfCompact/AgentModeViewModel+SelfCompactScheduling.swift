import Foundation
import RepoPromptDomainRuntime

/// App-side owner of the self-only MCP admission and terminal boundary, not a second overseer transaction.
extension AgentModeViewModel {
    /// Exact self read: never hydrate a target or search by a caller-supplied session UUID.
    func agentSelfContextSnapshot(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        origin: AgentSelfMCPCallOrigin
    ) -> AgentSelfContextSnapshot? {
        guard let session = origin.matchingSession(
            endpoint: endpoint, lookup: { sessions[$0] },
            observerEndpoint: { linkExecutionRuntime.agentSessionLinkObserverEndpoint(tabID: $0) }
        )
        else { return nil }
        return AgentSelfContextSnapshot(
            context: Self.observationContextLoad(for: session),
            selfCompact: session.selfCompactState.status
        )
    }

    static func agentSelfCompactNoteReadinessSnapshot(session: TabSession, requestID: UUID) -> AgentSessionLinkDeliveryReadiness.Snapshot {
        AgentSessionLinkExecutionRuntime.agentSelfCompactNoteReadinessSnapshot(session: session, requestID: requestID)
    }

    func agentSelfCompactTerminalSettled(session: TabSession, revision: AgentRunTerminalCommitRevision, publication: AgentRunTerminalPublicationResult, teardownSettled: @escaping @MainActor () -> Bool) {
        linkExecutionRuntime.agentSelfCompactTerminalSettled(session: session, revision: revision, publication: publication, teardownSettled: teardownSettled)
    }

    func agentSelfCompactCancelForAcceptedLocalInput(_ session: TabSession) {
        linkExecutionRuntime.agentSelfCompactCancelForAcceptedLocalInput(session)
    }

    func agentSelfCompactSettleStaleParkedNote(_ session: TabSession) {
        linkExecutionRuntime.agentSelfCompactSettleStaleParkedNote(session)
    }

    func agentSelfCompactHoldsWakeAcquisition(_ session: TabSession) -> Bool {
        linkExecutionRuntime.agentSelfCompactHoldsWakeAcquisition(session)
    }

    func agentSelfCompactCanIgnoreParkedWake(_ session: TabSession) -> Bool {
        linkExecutionRuntime.agentSelfCompactCanIgnoreParkedWake(session)
    }

    func agentSelfCompactBlocksNotificationWake(_ session: TabSession) -> Bool {
        linkExecutionRuntime.agentSelfCompactBlocksNotificationWake(session)
    }
}
