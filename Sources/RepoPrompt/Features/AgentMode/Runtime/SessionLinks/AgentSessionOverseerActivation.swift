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
    /// Retirement is observed once at the session's mutation owner, including catalog-free sessions.
    /// Queue the reread past the enclosing setter so binding/provenance writes have settled. Binding
    /// transitions also send a presentation-only settlement hint, without replaying discovery.
    func agentSessionLinkOverseerActivationChanged(
        session: AgentTabSession,
        retired: AgentSessionOverseerActivation?
    ) {
        Task { @MainActor [weak self, weak session] in
            // Never overlay the captured retired endpoint onto a replacement. Recompute only the
            // live current owner, with its current generation, eligibility and activation.
            if let self, let session, sessions[session.tabID] === session, currentTabID == session.tabID {
                syncStatusPillsUIStateIfMonitorStale()
            }
            // Retirement belongs to the outgoing endpoint even if its object left the owner map.
            // Discovery reevaluates live routing; notifying it neither repaints nor grants a successor.
            if let retired {
                AgentSessionLinkInvalidationSink.overseerActivationRetired?(retired.endpoint)
            }
        }
    }

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
        syncStatusPillsUIStateIfMonitorStale()
        return true
    }
}
