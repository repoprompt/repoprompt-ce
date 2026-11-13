import Foundation

/// Compatibility ingress only. The scope owns admission, submission and provider settlement.
/// The host cutover calls the runtime directly with its epoch-qualified resource environment.
extension AgentModeViewModel {
    static var agentSessionLinkManagedSteerOutcomeTimeoutSeconds: TimeInterval {
        AgentSessionLinkExecutionRuntime.agentSessionLinkManagedSteerOutcomeTimeoutSeconds
    }

    func agentSessionLinkSteerAdmission(
        for session: TabSession, liveness: AgentSessionLinkSendLiveness
    ) -> AgentSessionLinkSteerAdmission {
        linkExecutionRuntime.agentSessionLinkSteerAdmission(for: session, liveness: liveness)
    }

    func agentSessionLinkPerformSteer(
        to candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkSendRequest,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkSendTransactionOutcome {
        await linkExecutionRuntime.agentSessionLinkPerformSteer(
            to: candidate, request: request, liveness: liveness,
            commitAuthorization: commitAuthorization, environment: managedInputEnvironment()
        )
    }
}
