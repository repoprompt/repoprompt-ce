import Foundation
import RepoPromptDomainRuntime

// Observer-side delivery of one mid-session capability notice into a running turn.
//
// The bridge claims the notice from the authority and asks this window whether its exact overseer
// can take it now. Only a steerable Codex user turn can: Codex `turn/steer` adds input to the turn
// already in flight without interrupting it. Claude-native steering interrupts the turn and ACP has
// no non-interrupting input path, so both defer to the next oversight result or turn, and the
// dashboard says so. Invariant: nothing here starts a turn, queues a follow-up, answers a prompt,
// or reads or writes composer state; a notice the provider did not accept is handed back.

extension AgentModeViewModel {
    /// The exact live session this window holds for one observer endpoint incarnation, or `nil`.
    func agentSessionLinkLiveObserverSession(
        matching endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> TabSession? {
        guard endpoint.windowID == windowID,
              let session = sessions[endpoint.tabID],
              session.activeAgentSessionID == endpoint.sessionID,
              agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint
        else { return nil }
        return session
    }

    /// Pure classification of whether this exact overseer can take a notice mid-turn right now.
    func agentSessionLinkCapabilityNoticeRoute(
        for observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentSessionLinkCapabilityNoticeRoute {
        guard let session = agentSessionLinkLiveObserverSession(matching: observerEndpoint) else {
            return .unavailable(.observerUnavailable)
        }
        guard session.runState.isActive else { return .unavailable(.observerIdle) }
        guard session.runState == .running else { return .unavailable(.observerBusy) }
        guard session.selectedAgent == .codexExec else {
            return .unavailable(.providerCannotTakeMidTurnNotice)
        }
        // Only an observer that may be told about its links at all may be told this. A child,
        // MCP-controlled, or ineligible-role session never receives oversight context, and a run
        // whose exact catalog route is not ready is not told anything either.
        guard let context = agentSessionLinkPromptContext(for: session),
              context.epoch.allowsSupplement
        else {
            return .unavailable(.observerUnavailable)
        }
        guard session.pendingApproval == nil,
              session.pendingAskUser == nil,
              session.pendingUserInputRequest == nil,
              session.pendingPermissionsRequest == nil,
              session.pendingApplyEditsReview == nil,
              mcpPendingInteraction(for: session) == nil,
              !session.isMCPInstructionDispatchInProgress,
              codexCoordinator.canSteerOversightNotice(session: session)
        else {
            return .unavailable(.observerBusy)
        }
        return .codexRunningTurn
    }

    /// Steers one RepoPrompt-authored notice into this exact overseer's running Codex turn.
    ///
    /// Ordering is the contract: classify, take the Codex dispatch gate (so a notice never
    /// interleaves with a user send in flight), re-prove the exact session, run, and route, await
    /// `isCurrent` as the last suspension, re-prove once more, then make one `turn/steer`. A
    /// provider acceptance appends a `.system` provenance row — RepoPrompt's, never the user's —
    /// that names no session.
    func agentSessionLinkDeliverCapabilityNotice(
        to observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        providerText: String,
        notices: [DomainAgentSessionLinkCapabilityNotice],
        isCurrent: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        guard !notices.isEmpty,
              let session = agentSessionLinkLiveObserverSession(matching: observerEndpoint),
              agentSessionLinkCapabilityNoticeRoute(for: observerEndpoint) == .codexRunningTurn
        else { return false }
        let runID = session.runID
        let runAttemptID = session.activeRunAttemptID
        let ticket = session.codexDispatchSerialGate.issueTicket()
        guard await session.codexDispatchSerialGate.awaitTurn(ticket) else { return false }
        defer { session.codexDispatchSerialGate.finish(ticket) }

        func stillDeliverable() -> Bool {
            agentSessionLinkLiveObserverSession(matching: observerEndpoint) === session
                && session.runID == runID
                && session.activeRunAttemptID == runAttemptID
                && agentSessionLinkCapabilityNoticeRoute(for: observerEndpoint) == .codexRunningTurn
        }
        guard stillDeliverable(), await isCurrent(), stillDeliverable() else { return false }
        guard await codexCoordinator.steerOversightNotice(session: session, text: providerText) else {
            return false
        }
        if sessions[session.tabID] === session {
            session.appendItem(AgentChatItem.system(
                Self.agentSessionLinkCapabilityNoticeRowText(notices),
                sequenceIndex: session.nextSequenceIndex
            ))
            requestUIRefresh(tabID: session.tabID, urgent: true)
            scheduleSave(for: session.tabID)
        }
        return true
    }

    /// Local provenance for a steered notice. Counts only: target identities are agent-facing
    /// payload and stay out of the transcript text that replay and projections serialize.
    static func agentSessionLinkCapabilityNoticeRowText(
        _ notices: [DomainAgentSessionLinkCapabilityNotice]
    ) -> String {
        let granted = notices.count(where: \.managed)
        let withdrawn = notices.count - granted
        var parts: [String] = []
        if granted > 0 {
            parts.append("management granted for \(granted) linked session\(granted == 1 ? "" : "s")")
        }
        if withdrawn > 0 {
            parts.append("management withdrawn for \(withdrawn) linked session\(withdrawn == 1 ? "" : "s")")
        }
        return "RepoPrompt told this running turn that your oversight capabilities changed: "
            + parts.joined(separator: "; ") + "."
    }

    /// Settles capability notices an accepted inventory block already stated.
    ///
    /// Called at physical acceptance of a claim. Revision-scoped, so a claim rendered before a change
    /// never settles that change's notice; fire-and-forget, because a late settlement costs at most
    /// one redundant `capability_notice` on a later oversight result.
    func agentSessionLinkAcknowledgeCapabilityNotices(for claim: AgentSessionLinkOutboundPromptClaim) {
        guard let membership = claim.membership,
              membership.kind == .inventory,
              let endpoint = claim.observerEndpoint
        else { return }
        let revision = membership.linkSetRevision
        Task { @MainActor in
            await AgentSessionLinkRuntimeBridge.shared.acknowledgeCapabilityNotices(
                forObserverEndpoint: endpoint,
                throughObserverLinkSetRevision: revision
            )
        }
    }
}
