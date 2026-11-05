import Foundation

@MainActor
extension AgentModeViewModel {
    func makeRunInteractionUISnapshot() -> AgentRunInteractionUISnapshot {
        let tabID = currentTabID
        let session = activeSession
        return AgentRunInteractionUISnapshot(
            currentTabID: tabID,
            runState: runState,
            runningStatusText: runningStatusText,
            activeAgentRunStartedAt: activeAgentRunStartedAt,
            waitingPrompt: waitingPrompt,
            pendingAskUser: pendingAskUser(for: tabID),
            pendingUserInputRequest: pendingUserInputRequest(for: tabID),
            pendingApproval: pendingApproval(for: tabID),
            pendingCodexHookReview: pendingCodexHookReview(for: tabID),
            pendingPermissionsRequest: pendingPermissionsRequest(for: tabID),
            pendingMCPElicitationRequest: pendingMCPElicitationRequest(for: tabID),
            pendingApplyEditsReview: pendingApplyEditsReview(for: tabID),
            pendingWorktreeMergeReview: pendingWorktreeMergeReview(for: tabID),
            activeWorktreeMergeConflict: activeWorktreeMergeConflictOperation(for: tabID),
            activeRunID: session?.runID,
            activeAgentSessionID: session?.activeAgentSessionID,
            activeRunAttemptID: session?.activeRunAttemptID,
            latestUserSequenceIndex: session?.items.last(where: { $0.kind == .user })?.sequenceIndex,
            canForkCurrentSession: canForkCurrentSession,
            selectedAgent: selectedAgent,
            selectedModelRaw: selectedModelRaw,
            selectedReasoningEffortRaw: selectedReasoningEffortRaw
        )
    }

    /// Whether activating `tabID` should focus a pending question or approval, not the composer.
    func hasPendingInteractionForFocus(tabID: UUID) -> Bool {
        let snapshot = makeRunInteractionUISnapshot()
        if snapshot.currentTabID == tabID, snapshot.pendingInteractionFocusKey != nil { return true }
        let sessionID = sessions[tabID]?.activeAgentSessionID
        let scopes = AgentSessionLinkRuntimeBridge.shared.delegationScopes
        if !scopes.pendingRequests(forTab: tabID, sessionID: sessionID).isEmpty { return true }
        return sessionID.map { !scopes.confirmations.pendingConfirmations(forTab: tabID, sessionID: $0).isEmpty } ?? false
    }

    func syncRunInteractionUIState() {
        #if DEBUG
            test_syncRunInteractionCallCount += 1
        #endif
        ui.runInteraction.update(makeRunInteractionUISnapshot())
    }
}
