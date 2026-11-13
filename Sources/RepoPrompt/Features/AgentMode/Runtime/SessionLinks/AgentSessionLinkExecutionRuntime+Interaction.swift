import Foundation
import RepoPromptDomainRuntime

@MainActor
extension AgentSessionLinkExecutionRuntime {
    func agentSessionLinkPendingInteraction(for candidate: AgentSessionLinkEndpointCandidate) -> AgentSessionLinkPendingInteractionInspection {
        guard let session = agentSessionLinkLiveSession(matching: candidate),
              let interactions = scope?.installedInteractions else { return .none }
        return interactions.pendingInteraction(for: session)
    }

    func agentSessionLinkRespondToPendingInteraction(
        for candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkInteractionResponseRequest,
        authorize: @escaping @MainActor @Sendable () async -> Bool
    ) async -> AgentSessionLinkInteractionResponseOutcome {
        guard let command = admit(candidate),
              let interactions = scope?.installedInteractions else { return .unavailable }
        return await interactions.respondToPendingInteraction(
            session: command.writer.session,
            isCurrent: { command.isCurrent },
            request: request, authorize: authorize
        )
    }
}
