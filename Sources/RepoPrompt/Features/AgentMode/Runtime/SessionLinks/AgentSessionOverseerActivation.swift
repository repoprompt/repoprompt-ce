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
    /// Discovery is notified now for the outgoing session UUID; only the pill reread is queued past
    /// the enclosing setter so binding/provenance writes have settled.
    func agentSessionLinkOverseerActivationRetired(
        session: AgentTabSession,
        retired: AgentSessionOverseerActivation
    ) {
        // Discovery reevaluates live routing; notifying it neither repaints nor grants a successor.
        AgentSessionLinkInvalidationSink.overseerActivationRetired?(retired.endpoint.sessionID)
        Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            agentSessionLinkRepaintCurrentPillIfOwned(session)
        }
    }

    /// Every binding-transition settlement rereads the current tab's pill, so a failed routed
    /// hydration never leaves a stale endpoint on screen. Presentation only; never notifies discovery.
    func agentSessionLinkBindingTransitionSettled(session: AgentTabSession) {
        Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            agentSessionLinkRepaintCurrentPillIfOwned(session)
        }
    }

    /// Never overlays a captured endpoint onto a replacement: recomputes only the live current
    /// owner, with its current generation, eligibility and activation.
    private func agentSessionLinkRepaintCurrentPillIfOwned(_ session: AgentTabSession) {
        guard sessions[session.tabID] === session, currentTabID == session.tabID else { return }
        syncStatusPillsUIStateIfMonitorStale()
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
