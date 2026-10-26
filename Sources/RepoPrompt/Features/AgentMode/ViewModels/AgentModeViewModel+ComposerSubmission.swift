import Foundation

@MainActor
extension AgentModeViewModel {
    /// Local UI handoff, distinct from eventual provider dispatch. The existing claim remains
    /// the only admission authority; the pending row is merely its visible projection.
    func claimComposerSubmitForImmediatePresentation(_ attempt: AgentComposerSubmitAttempt) -> AgentComposerSubmitClaimResult {
        if let pending = ui.composer.pendingSubmissions.values.first(where: {
            $0.sourceTabID == attempt.sourceTabID || $0.destinationTabID == attempt.sourceTabID
        }) {
            return .rejected(.activeAttemptExists(activeAttemptID: pending.id))
        }
        let result = claimComposerSubmitAttempt(attempt)
        guard case let .claimed(claim) = result else { return result }
        let submittedRepromptDraft = repromptUIStore.submittedDraftSnapshot(tabID: attempt.sourceTabID)
        ui.composer.pendingSubmissions[attempt.id] = .init(
            id: attempt.id,
            sourceTabID: attempt.sourceTabID,
            destinationTabID: attempt.sourceTabID,
            text: attempt.rawDraftSnapshot,
            repromptDraft: submittedRepromptDraft,
            originalDraft: repromptDispatchOriginals[attempt.id]
        )
        // Move recovery ownership into the pending send, rather than discarding it.
        repromptUIStore.clearSubmittedDraft(submittedRepromptDraft)
        // claim captured the exact original before this clear. Any later typing is a new draft.
        if composerSubmitClaimIsCurrent(claim) {
            storeDraftText(for: attempt.sourceTabID, "")
        }
        return result
    }

    func movePendingComposerSubmission(_ claim: AgentComposerSubmitClaim, to tabID: UUID) {
        guard var pending = ui.composer.pendingSubmissions[claim.attempt.id], pending.destinationTabID != tabID else { return }
        pending.destinationTabID = tabID
        ui.composer.pendingSubmissions[pending.id] = pending
    }

    func cancelPresentedComposerSubmission(id: UUID) async {
        guard let pending = ui.composer.pendingSubmissions[id],
              let session = sessions[pending.sourceTabID],
              let attempt = session.activeComposerSubmitAttempt, attempt.id == id else { return }
        let claim = AgentComposerSubmitClaim(attempt: attempt, sourceSession: session, draftMutationGeneration: session.draftMutationGeneration)
        // Fence dispatch and restore immediately; backend cancellation may itself suspend.
        finishPresentedComposerSubmitAttempt(claim, result: .blocked(message: "Send cancelled. Your draft was restored."))
        await cancelFreshTaskRouting(tabID: pending.sourceTabID)
    }

    /// Always finish a UI handoff even if the asynchronous execution rejects a stale claim.
    /// The restoration ledger composes rejected text above newer typing, including on inactive tabs.
    func executePresentedComposerSubmitAttempt(text: String, claim: AgentComposerSubmitClaim) async -> UserTurnSubmissionResult {
        let result = await executeComposerSubmitAttempt(text: text, claim: claim)
        finishPresentedComposerSubmitAttempt(claim, result: result)
        return result
    }

    /// Idempotent cleanup also covers cancellation before the asynchronous executor starts.
    func clearRepromptSubmissionState(claimID: UUID) {
        cancelRepromptSpeculation(claimID: claimID)
        repromptAudits[claimID] = nil
        repromptDispatchTexts[claimID] = nil
        repromptDispatchOriginals[claimID] = nil
    }

    func finishPresentedComposerSubmitAttempt(_ claim: AgentComposerSubmitClaim, result: UserTurnSubmissionResult) {
        guard let pending = ui.composer.pendingSubmissions.removeValue(forKey: claim.attempt.id) else { return }
        if case let .blocked(message) = result,
           sessions[claim.attempt.sourceTabID] === claim.sourceSession
        {
            restoreComposerDraft(
                tabID: claim.attempt.sourceTabID,
                text: claim.attempt.rawDraftSnapshot,
                message: message,
                strategy: .prependAlways
            )
            repromptUIStore.restoreCancelledDraft(
                pending.repromptDraft.cancelledDraft,
                tabID: pending.sourceTabID,
                currentDraft: retrieveDraftText(for: pending.sourceTabID)
            )
            if repromptUIStore.recoveries[pending.sourceTabID] == nil {
                if let original = pending.originalDraft, pending.text != original {
                    // Bind only after restoration has composed against newer typing. Never let a
                    // late executor re-stamp this authority or overwrite a newer preparation.
                    repromptUIStore.recover(
                        tabID: pending.sourceTabID, text: pending.text, originalDraft: original,
                        reason: message, currentDraft: retrieveDraftText(for: pending.sourceTabID), requiresDecision: true
                    )
                } else {
                    // An unrelated older recovery retains its original exact-draft boundary.
                    repromptUIStore.recoveries[pending.sourceTabID] = pending.repromptDraft.recovery
                }
            }
        }
        if case .blocked = result { clearRepromptSubmissionState(claimID: claim.attempt.id) }
        // executeComposerSubmitAttempt normally releases this. Also cover its early stale guard.
        if composerSubmitClaimIsCurrent(claim) { releaseComposerSubmitClaim(claim) }
    }
}
