import Foundation
import RepoPromptDomainRuntime

extension AgentSessionInteractionRuntime {
    /// Cancellation operates on the originating object, including after presentation removal.
    /// Namespace-addressed provider work and inbound withdrawal may not target a recycled tab.
    @discardableResult
    func prepareRunCancellation(
        session: AgentTabSession,
        intent: DomainAgentRunCancellationIntent,
        origin: AgentModeRunService.CancellationOrigin,
        links: AgentSessionLinkExecutionRuntime
    ) -> (@MainActor () async -> Void)? {
        Self.cancelPendingInstruction(for: session)
        let current = scope?.sessions[session.tabID]
        let providerTeardown = current == nil || current === session
            ? claudeCommands?.cancelPendingProviderAdoption(for: session) : nil
        // Internal lifecycle cancellation fences deferred starts, but is not a user Stop.
        session.stopState.invalidateScheduledStarts()
        guard intent == .userStop, origin == .explicitStop else { return providerTeardown }
        closeOracleBackground(for: session)
        session.stopState.invalidateQueuedDeliveries()
        session.mcpFollowUpRunPending = false
        links.agentSessionLinkRetractAutoWakeForUserStop(session)
        if scope?.sessions[session.tabID] === session,
           let endpoint = links.agentSessionLinkObserverEndpoint(tabID: session.tabID),
           scope?.sessions[session.tabID] === session
        {
            AgentSessionLinkRuntimeBridge.shared.withdrawCancellableInboundPendingSends(
                to: endpoint,
                requiringNoCommittedDrain: false
            )
        }
        return providerTeardown
    }

    @discardableResult
    func closeOracleBackground(for session: AgentTabSession) -> Task<Void, Never>? {
        guard let owner = session.oracleBackgroundOwner else { return nil }
        let drain = OracleBackgroundInvocationRegistry.shared.close(owner)
        session.oracleBackgroundDrain = drain
        session.oracleBackgroundAwareness.resetContext()
        return drain
    }

    @discardableResult
    func awaitOracleBackgroundDrain(for session: AgentTabSession, timeout: TimeInterval = 30) async -> Bool {
        guard let owner = session.oracleBackgroundOwner else { return true }
        let scope = scope
        defer { withExtendedLifetime(scope) {} }
        let registry = OracleBackgroundInvocationRegistry.shared
        guard let drain = closeOracleBackground(for: session) else { return true }
        if registry.isDrained(owner) { return true }
        let settled = await OracleBackgroundInvocationRegistry.awaitDrain(drain, timeout: timeout)
        return settled && scope?.sessions[session.tabID] === session && session.persistentSessionBindingIdentity == owner.binding
    }

    func closeOracleBackgroundAdmission() {
        guard let scope else { return }
        for session in scope.sessions.values {
            closeOracleBackground(for: session)
        }
    }

    func joinOracleBackgroundDrain() async {
        guard let scope else { return }
        defer { withExtendedLifetime(scope) {} }
        let drains = scope.sessions.values.compactMap { closeOracleBackground(for: $0) }
        guard !OracleBackgroundInvocationRegistry.shared.isShuttingDown else { return }
        for drain in drains {
            await drain.value
        }
    }
}
