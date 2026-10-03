import Foundation

@MainActor
extension AgentModeViewModel {
    func codexComputerUseIsArmed(tabID: UUID) -> Bool {
        sessions[tabID]?.wantsCodexComputerUseForNextTurn == true
    }

    func codexComputerUseIsEligible(_ session: TabSession) async -> Bool {
        guard sessions[session.tabID] === session,
              codexComputerUseEnabledProvider(),
              session.selectedAgent == .codexExec,
              !session.isMCPRelated
        else { return false }
        let endpoint = agentSessionLinkObserverEndpoint(tabID: session.tabID)
        let hasActiveLink = if let endpoint {
            await AgentSessionLinkRuntimeBridge.shared.hasActiveLink(endpoint: endpoint)
        } else {
            false
        }
        return sessions[session.tabID] === session && CodexComputerUseWorkflow.isEligible(
            globalEnabled: codexComputerUseEnabledProvider(),
            isCodex: session.selectedAgent == .codexExec,
            isMCPRelated: session.isMCPRelated,
            hasActiveLink: hasActiveLink
        )
    }

    /// Returns a visible refusal, or nil after the human's session-scoped arm was recorded.
    func armCodexComputerUse(tabID: UUID, expectedTarget: AgentComposerSubmitTarget? = nil) async -> String? {
        guard currentTabID == tabID,
              let session = sessions[tabID],
              codexComputerUseMatchesExpectedTarget(session, expectedTarget),
              codexComputerUseEnabledProvider(),
              session.selectedAgent == .codexExec,
              !session.isMCPRelated
        else {
            return "Computer Use is available only in a direct, unlinked Codex session with the global setting on."
        }
        guard codexComputerUseClientPathProvider() != nil else {
            return "Install OpenAI's Codex Computer Use companion before allowing Computer Use."
        }
        // Claim before the authority hop. An Add already in flight refuses this arm; a new Add
        // cannot enter while the claim is held. Candidate exclusion takes over after commit.
        let bridge = AgentSessionLinkRuntimeBridge.shared
        let claimedSessionID = agentSessionLinkObserverEndpoint(tabID: tabID)?.sessionID
        if let claimedSessionID, !bridge.beginComputerUseArming(sessionID: claimedSessionID) {
            return "Wait for the session-link change to finish before allowing Computer Use."
        }
        defer {
            if let claimedSessionID { bridge.endComputerUseArming(sessionID: claimedSessionID) }
        }
        guard await codexComputerUseIsEligible(session),
              currentTabID == tabID,
              codexComputerUseMatchesExpectedTarget(session, expectedTarget)
        else {
            return "Computer Use is available only in a direct, unlinked Codex session with the global setting on."
        }
        session.pendingCodexComputerUseActivation = CodexComputerUseActivation(
            id: UUID(),
            createdAt: Date(),
            binding: session.persistentSessionBindingIdentity,
            bindingTransitionGeneration: session.bindingTransitionGeneration
        )
        requestUIRefresh(tabID: tabID, urgent: true)
        return nil
    }

    func disarmCodexComputerUse(tabID: UUID) {
        guard let session = sessions[tabID] else { return }
        session.pendingCodexComputerUseActivation = nil
        if session.runState.isActive {
            let target = makeRunCancelTarget(tabID: tabID, session: session)
            Task { [weak self] in
                guard let self else { return }
                _ = await cancelAgentRun(target: target)
                // A terminal shortcut can return without retiring the old enabled controller.
                // Never retire a successor's active controller; its next start sees disarmed state.
                if sessions[tabID] === session {
                    codexCoordinator.disarmComputerUse(session: session)
                }
            }
        } else {
            codexCoordinator.disarmComputerUse(session: session)
        }
        requestUIRefresh(tabID: tabID, urgent: true)
    }

    /// The first send creates a bound destination tab. Transfer only while that exact incarnation
    /// is still direct and unlinked; the same MainActor fence excludes an Add during the authority hop.
    func transferCodexComputerUseActivation(from source: TabSession, to destination: TabSession) async -> Bool {
        guard sessions[source.tabID] === source,
              sessions[destination.tabID] === destination,
              let activation = source.pendingCodexComputerUseActivation,
              source.wantsCodexComputerUseForNextTurn,
              let binding = destination.persistentSessionBindingIdentity
        else { return false }
        let generation = destination.bindingTransitionGeneration
        let bridge = AgentSessionLinkRuntimeBridge.shared
        guard bridge.beginComputerUseArming(sessionID: binding.sessionID) else { return false }
        defer { bridge.endComputerUseArming(sessionID: binding.sessionID) }
        guard await codexComputerUseIsEligible(destination),
              sessions[source.tabID] === source,
              sessions[destination.tabID] === destination,
              source.pendingCodexComputerUseActivation?.id == activation.id,
              source.wantsCodexComputerUseForNextTurn,
              destination.persistentSessionBindingIdentity == binding,
              destination.bindingTransitionGeneration == generation
        else { return false }
        destination.pendingCodexComputerUseActivation = CodexComputerUseActivation(
            id: activation.id,
            createdAt: activation.createdAt,
            binding: binding,
            bindingTransitionGeneration: generation
        )
        source.pendingCodexComputerUseActivation = nil
        return true
    }

    private func codexComputerUseMatchesExpectedTarget(
        _ session: TabSession,
        _ target: AgentComposerSubmitTarget?
    ) -> Bool {
        guard let target else { return true }
        return target.tabID == session.tabID
            && target.expectedSourceTabSessionIdentity == ObjectIdentifier(session)
            && target.expectedPersistentBindingIdentity == session.persistentSessionBindingIdentity
            && target.expectedBindingTransitionGeneration == session.bindingTransitionGeneration
    }
}
