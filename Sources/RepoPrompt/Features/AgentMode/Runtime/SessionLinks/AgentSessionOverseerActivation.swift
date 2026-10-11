import Foundation
import RepoPromptDomainRuntime

/// Explicit opt-in belongs to one session object and exact binding, never to a run/controller or UUID.
struct AgentSessionOverseerActivation: Hashable {
    let endpoint: DomainAgentSessionLinkEndpointIdentity
    let token: UUID
}

/// An eligible, memory-only incarnation read. The object identity fences activation across awaits.
struct AgentSessionOverseerBootstrapState: Equatable {
    let sessionIdentity: ObjectIdentifier
    let provider: AgentProviderKind
    let activation: AgentSessionOverseerActivation?
}

extension AgentModeViewModel {
    func agentSessionLinkBootstrapState(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentSessionOverseerBootstrapState? {
        guard let candidate = agentSessionLinkModelCandidate(for: endpoint),
              let session = sessions[endpoint.tabID],
              session.createdByOverseerSessionID == nil,
              AgentSessionLinkEndpointEligibility.addDisabledReason(
                  candidate.eligibilityInput,
                  roleAllowsOutboundMonitoring: candidate.roleAllowsOutboundMonitoring
              ) == nil
        else { return nil }
        let activation = session.oversight.overseerActivation
        if let activation, activation.endpoint != endpoint {
            return nil // Reads fail closed; binding/provenance write owners retire stale activation.
        }
        return AgentSessionOverseerBootstrapState(
            sessionIdentity: ObjectIdentifier(session), provider: session.selectedAgent,
            activation: activation
        )
    }

    /// Synchronous final commit; no authority, persistence, prompt inventory or wake state changes.
    func agentSessionLinkActivateOverseer(
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        expected: AgentSessionOverseerBootstrapState
    ) -> Bool {
        guard expected.activation == nil,
              agentSessionLinkBootstrapState(for: endpoint) == expected,
              let session = sessions[endpoint.tabID]
        else { return false }
        session.oversight.overseerActivation = AgentSessionOverseerActivation(endpoint: endpoint, token: UUID())
        return true
    }
}
