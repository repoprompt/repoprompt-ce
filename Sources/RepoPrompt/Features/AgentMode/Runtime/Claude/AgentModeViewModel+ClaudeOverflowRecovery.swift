import Foundation

extension AgentModeViewModel {
    /// Prepare the next *user* message to start a new provider conversation. This action sends nothing.
    func continueFreshAfterClaudeOverflow(_ session: TabSession, expectedHoldID: UUID) async -> Bool {
        let links = linkExecutionRuntime
        guard let hold = session.activeClaudeContextAutoWakeHold, hold.id == expectedHoldID,
              let conversation = session.providerSessionID,
              session.selfCompactState.active == nil, !links.hasPendingSelfCompactEffects(for: session),
              let target = links.makeComposerSubmitTarget(tabID: session.tabID, session: session),
              let claim = links.claimComposerSubmitAttempt(.init(
                  id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: ""
              ))
        else { return false }
        defer { links.releaseComposerSubmitClaim(claim) }
        guard let command = claim.command, links.composerSubmitClaimIsCurrent(claim) else { return false }
        let readiness = AgentSessionLinkExecutionRuntime.agentSessionLinkDeliveryReadinessSnapshot(
            session: session, endpointMatchesGrant: command.isCurrent, isClosing: false,
            ignoresComposerSubmissionInFlight: true
        )
        guard AgentSessionLinkDeliveryReadiness.evaluate(snapshot: readiness) == .ready,
              !AgentSessionLinkExecutionRuntime.agentSessionLinkCompactHasQueuedProviderWork(session),
              let preparation = handoffRuntime.prepareRecovery(for: session, sourceTabName: "", transcriptXML: "")
        else { return false }

        let priorHandoff = session.pendingHandoff
        let oldCleanup = session.providerCleanupHandle
        let fence = AgentRunStartStopFence(session: session)
        guard let staged = handoffRuntime.stageRecovery(preparation, initialThreadContextBlock: nil, overflowRecovery: true)
        else { return false }
        // Commit the resumable ID and staged handoff in the same save, under the same composer
        // claim. Detached shutdown cannot restore the old ID or capture the replacement process.
        claudeCoordinator.prepareFreshConversationAfterOverflow(session)
        let row = AgentChatItem.system("Fresh Claude conversation prepared. Send a new message to continue in this session.", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(row)
        let saved = await links.flushSaveRequired(writer: command.writer)
        guard command.isCurrent, links.composerSubmitClaimIsCurrent(claim),
              !session.runState.isActive, session.providerSessionID == nil, session.pendingHandoff == staged
        else { return false }
        switch saved {
        case .success:
            session.contextUsageSnapshot = nil
            session.contextCompactedAt = nil
            session.noteLiveContextUsageReport(contextUsedTokens: nil, promptTokens: nil, modelContextWindow: 0)
            updateBindingsFromSession(session)
            return fence.permitsStart(of: session)
        case .failure:
            session.providerSessionID = conversation
            session.providerCleanupHandle = oldCleanup
            session.pendingHandoff = priorHandoff
            if let index = session.items.firstIndex(where: { $0.id == row.id }) {
                _ = session.removeItem(at: index)
            }
            _ = await links.flushSaveRequired(writer: command.writer)
            updateBindingsFromSession(session)
            return false
        }
    }
}
