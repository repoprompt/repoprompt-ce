import Combine
import Foundation
import RepoPromptDomainRuntime

/// Independent scheduling; the existing Auto-wake slot owns provider execution.
@MainActor
extension AgentModeViewModel {
    static var periodicWakeMessage: String {
        AgentSessionLinkExecutionRuntime.periodicWakeMessage
    }

    static func agentSessionLinkPeriodicWakeSessionIsIdle(_ session: TabSession) -> Bool {
        AgentSessionLinkExecutionRuntime.agentSessionLinkPeriodicWakeSessionIsIdle(session)
    }

    func agentSessionLinkPeriodicWakeIsEligible(
        _ session: TabSession, endpoint: DomainAgentSessionLinkEndpointIdentity, requiresReadyCatalog: Bool = true
    ) -> Bool {
        linkExecutionRuntime.agentSessionLinkPeriodicWakeIsEligible(session, endpoint: endpoint, requiresReadyCatalog: requiresReadyCatalog)
    }

    func agentSessionLinkPeriodicPreparationIsUnblocked(_ session: TabSession) -> Bool {
        linkExecutionRuntime.agentSessionLinkPeriodicPreparationIsUnblocked(session)
    }

    func agentSessionLinkReconcilePeriodicWake(for endpoint: DomainAgentSessionLinkEndpointIdentity) {
        linkExecutionRuntime.agentSessionLinkReconcilePeriodicWake(for: endpoint)
    }

    func agentSessionLinkPeriodicWakeDeadline(
        endpoint: DomainAgentSessionLinkEndpointIdentity, token: UUID, deadline: ContinuousClock.Instant
    ) {
        linkExecutionRuntime.agentSessionLinkPeriodicWakeDeadline(endpoint: endpoint, token: token, deadline: deadline)
    }

    func agentSessionLinkPeriodicProducerHasSettled(_ session: TabSession) -> Bool {
        linkExecutionRuntime.agentSessionLinkPeriodicProducerHasSettled(session)
    }

    func agentSessionLinkRunPeriodicAttempt(_ attempt: AgentSessionLinkAutoWakeAttempt, session: TabSession) async {
        await linkExecutionRuntime.agentSessionLinkRunPeriodicAttempt(attempt, session: session)
    }
}
