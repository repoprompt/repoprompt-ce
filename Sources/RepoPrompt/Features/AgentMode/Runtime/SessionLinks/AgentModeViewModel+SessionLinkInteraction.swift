import Foundation
import RepoPromptDomainRuntime

@MainActor
extension AgentModeViewModel {
    func agentSessionLinkPendingInteraction(for candidate: AgentSessionLinkEndpointCandidate) -> AgentSessionLinkPendingInteractionInspection {
        guard let session = linkExecutionRuntime.agentSessionLinkLiveSession(matching: candidate) else { return .none }
        return interactionRuntime.pendingInteraction(for: session)
    }

    func agentSessionLinkRespondToPendingInteraction(
        for candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkInteractionResponseRequest,
        authorize: @escaping @MainActor @Sendable () async -> Bool
    ) async -> AgentSessionLinkInteractionResponseOutcome {
        guard let session = linkExecutionRuntime.agentSessionLinkLiveSession(matching: candidate) else { return .unavailable }
        return await interactionRuntime.respondToPendingInteraction(
            session: session,
            isCurrent: { [weak self, weak session] in
                guard let self, let session else { return false }
                return linkExecutionRuntime.agentSessionLinkLiveSession(matching: candidate) === session
            },
            request: request, authorize: authorize
        )
    }
}
