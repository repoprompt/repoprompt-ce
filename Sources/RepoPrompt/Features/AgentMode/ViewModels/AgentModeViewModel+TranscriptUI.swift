import Foundation

struct AgentQuietTranscriptDisplayCache {
    struct Key: Equatable {
        let session: ObjectIdentifier
        let binding: AgentSessionRestorationBindingToken?
        let tabID: UUID?
        let presentationRevision: Int
        let maskRevision: UInt64
    }

    struct Archive {
        let key: Key
        let region: AgentTranscriptProjectionBuilder.DisplayMaskRegion

        func matches(_ candidate: Key) -> Bool {
            key.session == candidate.session && key.binding == candidate.binding
                && key.tabID == candidate.tabID && key.maskRevision == candidate.maskRevision
        }
    }

    let key: Key
    let result: AgentTranscriptProjectionBuilder.DisplayMaskResult
}

@MainActor
extension AgentModeViewModel {
    private func quietDisplayKey(_ session: AgentTabSession, base: AgentTranscriptPresentationSnapshot) -> AgentQuietTranscriptDisplayCache.Key {
        .init(
            session: ObjectIdentifier(session),
            binding: session.currentRestorationBindingToken,
            tabID: base.tabID,
            presentationRevision: base.revision,
            maskRevision: session.quietLedger.displayMaskRevision
        )
    }

    /// Owning UI sync only. Snapshot getters never populate/invalidate this cache.
    @discardableResult
    func prepareQuietTranscriptDisplay() -> Bool {
        guard let session = activeSession else { return true }
        let base = scopedActiveTranscriptPresentation(for: currentTabID)
        let key = quietDisplayKey(session, base: base)
        guard session.quietTranscriptDisplayCache?.key != key else { return true }
        // Inline run-state publication can reenter UI sync while the terminal barrier owns the
        // actor. Its existing phase-end callback requests the scoped refresh after that phase.
        if session.terminalCommitInProgress, session.quietDisplayCandidate != nil || !session.quietLedger.hiddenSourceIDs.isEmpty {
            session.quietTranscriptDisplayCache = nil
            return false
        }
        let hidden = session.quietLedger.hiddenSourceIDs
        let reusable = session.quietTranscriptArchiveDisplayCache.flatMap { $0.matches(key) ? $0.region : nil }
        // Archive replacement/reset and mask/binding retirement clear this part in AgentTabSession.
        // Base assignment clears only the presentation part, including same-revision hydration (A3).
        let archive = hidden.isEmpty ? nil : reusable ?? AgentTranscriptProjectionBuilder.maskArchiveForLocalDisplay(
            session.archivedTranscriptSnapshot, hiddenSourceIDs: hidden
        )
        session.quietTranscriptArchiveDisplayCache = archive.map { .init(key: key, region: $0) }
        var result = AgentTranscriptProjectionBuilder.maskForLocalDisplay(
            base, archivedBlocks: session.archivedTranscriptSnapshot.blocks, hiddenSourceIDs: hidden, reusableArchive: archive
        )
        if reusable == nil, let archive {
            // Charge the initial archive traversal to this owner sync, not just the helper call.
            result = .init(
                presentation: result.presentation, archivedBlocks: result.archivedBlocks,
                blockVisits: result.blockVisits + archive.blockVisits, rowVisits: result.rowVisits + archive.rowVisits,
                anchorVisits: result.anchorVisits, archiveBlockVisits: archive.blockVisits, archiveRowVisits: archive.rowVisits
            )
        }
        session.quietTranscriptDisplayCache = .init(key: key, result: result)
        #if DEBUG
            perfRecorder.increment("quiet.display.cache.build", tabID: session.tabID)
            perfRecorder.event("quiet.display.work", tabID: session.tabID, fields: [
                "blocks": String(result.blockVisits), "rows": String(result.rowVisits), "anchors": String(result.anchorVisits),
                "archiveBlocks": String(result.archiveBlockVisits), "archiveRows": String(result.archiveRowVisits)
            ])
        #endif
        return true
    }

    func makeTranscriptUISnapshot() -> AgentTranscriptUISnapshot {
        let tabID = currentTabID
        let session = activeSession
        let paneInput = transcriptPaneInput(tabID: tabID, session: session)
        let scopedBase = scopedActiveTranscriptPresentation(for: tabID)
        let cached = session.flatMap { session in
            session.quietTranscriptDisplayCache.flatMap { $0.key == quietDisplayKey(session, base: scopedBase) ? $0.result : nil }
        }
        let scopedPresentation = cached?.presentation ?? scopedBase
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
            displayMaskRevision: session?.quietLedger.displayMaskRevision ?? 0,
            followBindingState: activeTranscriptFollowBindingState,
            activeSessionLoadInProgressTabID: activeSessionLoadInProgressTabID,
            activeBashLiveExecutionByItemID: activeBashLiveExecutionByItemID,
            runtimeFooterByItemID: agentMessageRuntimeFooters(for: tabID),
            fallbackFollowArmingState: session?.transcriptAutoFollowArmingState ?? .armed,
            archivedBlocks: canPresentExistingTranscript ? cached?.archivedBlocks ?? session?.archivedTranscriptSnapshot.blocks ?? [] : [],
            panePresentation: AgentTranscriptPanePresentation.resolve(paneInput)
                // Nil rejects stale candidate evidence; it never authorizes welcome (§4.5).
                ?? .restoring,
            paneTarget: paneInput.target
        )
    }
}
