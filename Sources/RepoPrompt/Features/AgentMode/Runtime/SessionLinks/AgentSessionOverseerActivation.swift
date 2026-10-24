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

/// Why `become_overseer` cannot activate this session right now.
///
/// `isPermanent` separates sessions that can never oversee (lanes, children, MCP-created or
/// MCP-controlled sessions, explore role, closing) from transient states (thread still loading,
/// binding settling). Only permanent refusals hide the bootstrap tool; a transient refusal keeps
/// it listed so the agent can call it and relay an actionable reason instead of silently lacking it.
struct AgentSessionOverseerBootstrapRefusal: Equatable {
    let reason: String
    let isPermanent: Bool

    static let notLoaded = Self(
        reason: "This session isn't routed to a loaded Agent Mode tab right now, or its binding is still settling. Retry become_overseer once after this turn; if it still fails, ask the user to start oversight from the session's own tab.",
        isPermanent: false
    )
    static let overseerLane = Self(
        reason: "This session is a lane created by an overseer, and lanes can't become overseers. Ask the user to start oversight from a top-level session they opened.",
        isPermanent: true
    )
    static let terminating = Self(reason: "The app is quitting, so oversight can't start.", isPermanent: true)

    static func classify(
        candidate: AgentSessionLinkEndpointCandidate?,
        isOverseerLane: Bool
    ) -> Self {
        if isOverseerLane { return .overseerLane }
        guard let candidate else { return .notLoaded }
        let input = candidate.eligibilityInput
        if input.isChildSession || input.isMCPControlled || input.isMCPOriginated
            || !candidate.roleAllowsOutboundMonitoring
        {
            return Self(
                reason: "This session can't oversee others: it is a child, MCP-created, MCP-controlled or explore-role session. Ask the user to start oversight from a top-level session they opened.",
                isPermanent: true
            )
        }
        if input.isClosing || input.isDeletionInProgress {
            return Self(reason: "This session is closing or being deleted, so it can't become an overseer.", isPermanent: true)
        }
        if !input.hasDurableBinding, !input.bindingTransitionInProgress {
            return Self(
                reason: "This session hasn't finished saving its first turn yet. Retry become_overseer after this turn ends; if the user is waiting, tell them oversight starts on their next message.",
                isPermanent: false
            )
        }
        if let reason = AgentSessionLinkEndpointEligibility.addDisabledReason(
            input, roleAllowsOutboundMonitoring: candidate.roleAllowsOutboundMonitoring
        ) {
            return Self(
                reason: "\(reason) This is temporary: retry become_overseer once after this turn.",
                isPermanent: false
            )
        }
        return Self(
            reason: "This session's oversight state changed during the call. Retry become_overseer once.",
            isPermanent: false
        )
    }
}

extension AgentModeViewModel {
    /// nil when `agentSessionLinkBootstrapState(for:)` would admit this endpoint now.
    func agentSessionLinkBootstrapRefusal(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentSessionOverseerBootstrapRefusal? {
        guard agentSessionLinkBootstrapState(for: endpoint) == nil else { return nil }
        let isLane = sessions[endpoint.tabID]?.createdByOverseerSessionID != nil
        return .classify(candidate: agentSessionLinkModelCandidate(for: endpoint), isOverseerLane: isLane)
    }
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
