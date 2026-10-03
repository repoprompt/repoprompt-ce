import Foundation

@MainActor
extension AgentModeViewModel {
    func makeTranscriptUISnapshot() -> AgentTranscriptUISnapshot {
        let tabID = currentTabID
        let session = activeSession
        let paneInput = transcriptPaneInput(tabID: tabID, session: session)
        let scopedPresentation = scopedActiveTranscriptPresentation(for: tabID)
        // Committed content of another scope never survives a target replacement (§4.5).
        let presentation = activeTranscriptContentScopeMismatches(paneInput.target)
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
            archivedBlocks: session?.archivedTranscriptSnapshot.blocks ?? [],
            panePresentation: AgentTranscriptPanePresentation.resolve(paneInput)
                // Nil rejects stale candidate evidence; it never authorizes welcome (§4.5).
                ?? .restoring,
            paneTarget: paneInput.target
        )
    }

    func syncTranscriptUIState() {
        ui.transcript.update(makeTranscriptUISnapshot())
        // The same publication point reports the initial selected restoration to the sidebar join and
        // propagates owner-pending transitions to the sidebar projection (§5.3/§5.5).
        synchronizeSidebarRestoreSelectedSide()
        let isOwnerPending = isSidebarOwnerPending
        if isOwnerPending != lastPublishedSidebarOwnerPending {
            lastPublishedSidebarOwnerPending = isOwnerPending
            syncSidebarUIState(refresh: true, reason: .restoreProjection)
        }
    }
}
