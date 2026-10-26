import Foundation

@MainActor
extension AgentModeViewModel {
    func makeTranscriptUISnapshot() -> AgentTranscriptUISnapshot {
        let tabID = currentTabID
        let session = activeSession
        let paneInput = transcriptPaneInput(tabID: tabID, session: session)
        let scopedPresentation = scopedActiveTranscriptPresentation(for: tabID)
        // Existing rows/history survive a rejected operation, not a content-identity replacement.
        let canPresentExistingTranscript = paneInput.content?.canPresentExistingTranscript(for: paneInput.target) == true
        let contentScopeMismatches = activeTranscriptContentScopeMismatches(paneInput.target)
        let presentation = contentScopeMismatches && !canPresentExistingTranscript
            ? AgentTranscriptPresentationSnapshot(revision: scopedPresentation.revision)
            : scopedPresentation
        return AgentTranscriptUISnapshot(
            currentTabID: tabID,
            presentation: presentation,
            isHydrated: isActiveTranscriptPresentationHydrated(for: tabID),
            presentationRevision: activeTranscriptPresentationRevision(for: tabID),
            followBindingState: activeTranscriptFollowBindingState,
            activeSessionLoadInProgressTabID: activeSessionLoadInProgressTabID,
            activeBashLiveExecutionByItemID: activeBashLiveExecutionByItemID,
            runtimeFooterByItemID: agentMessageRuntimeFooters(for: tabID),
            fallbackFollowArmingState: session?.transcriptAutoFollowArmingState ?? .armed,
            archivedBlocks: canPresentExistingTranscript ? session?.archivedTranscriptSnapshot.blocks ?? [] : [],
            panePresentation: AgentTranscriptPanePresentation.resolve(paneInput)
                // Nil rejects stale candidate evidence; it never authorizes welcome (§4.5).
                ?? .restoring,
            paneTarget: paneInput.target
        )
    }
}
