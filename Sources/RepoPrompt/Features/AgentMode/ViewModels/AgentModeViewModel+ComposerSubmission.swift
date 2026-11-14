import Foundation

@MainActor
extension AgentModeViewModel {
    /// Local UI handoff, distinct from eventual provider dispatch. The existing claim remains
    /// the only admission authority; the pending row is merely its visible projection.
    func claimComposerSubmitForImmediatePresentation(
        _ attempt: AgentComposerSubmitAttempt, requireActiveTabOwnership: Bool = true
    ) -> AgentComposerSubmitClaimResult {
        if let pending = ui.composer.pendingSubmissions.values.first(where: {
            $0.sourceTabID == attempt.sourceTabID || $0.destinationTabID == attempt.sourceTabID
        }) {
            return .rejected(.activeAttemptExists(activeAttemptID: pending.id))
        }
        let result = claimComposerSubmitAttempt(
            attempt, requireActiveTabOwnership: requireActiveTabOwnership, awaitsExecutor: true,
            adoptsLocalReprompt: true
        )
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
        if composerSubmitRuntime.isCurrent(claim) {
            claim.cancellation.oweDraftRestoration(attempt.rawDraftSnapshot)
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
        guard let claim = composerSubmitRuntime.cleanupClaim(attempt: attempt, session: session) else { return }
        // Withdrawal restores runtime-owned text immediately, but an entered producer retains
        // its receipt until its finalizer. Never manufacture a run to cancel an unsent input.
        guard claim.cancellation.withdraw(on: session) || claim.cancellation.cancelPresentedInput(on: session) else { return }
        finishWithdrawnComposerSubmission(session: session, attemptID: id)
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
        autoWorkflowJudgments.removeValue(forKey: claimID)?.cancel()
        repromptSpeculations.removeValue(forKey: claimID)?.cancel(runtime: modelRouterRuntime)
        repromptAudits[claimID] = nil
        repromptDispatchTexts[claimID] = nil
        repromptDispatchOriginals[claimID] = nil
    }

    func finishWithdrawnComposerSubmission(session: AgentTabSession, attemptID: UUID) {
        guard let pending = ui.composer.pendingSubmissions[attemptID],
              pending.sourceTabID == session.tabID else { return }
        ui.composer.pendingSubmissions[attemptID] = nil
        restorePendingComposerRepromptMetadata(pending, message: "Send cancelled. Your draft was restored.")
        clearRepromptSubmissionState(claimID: attemptID)
    }

    private func restorePendingComposerRepromptMetadata(_ pending: AgentComposerPendingSubmission, message: String) {
        repromptUIStore.restoreCancelledDraft(
            pending.repromptDraft.cancelledDraft, tabID: pending.sourceTabID,
            currentDraft: draftRuntime.text(for: pending.sourceTabID)
        )
        if repromptUIStore.recoveries[pending.sourceTabID] == nil {
            if let original = pending.originalDraft, pending.text != original {
                repromptUIStore.recover(
                    tabID: pending.sourceTabID, text: pending.text, originalDraft: original,
                    reason: message, currentDraft: draftRuntime.text(for: pending.sourceTabID), requiresDecision: true
                )
            } else {
                repromptUIStore.recoveries[pending.sourceTabID] = pending.repromptDraft.recovery
            }
        }
    }

    func finishPresentedComposerSubmitAttempt(_ claim: AgentComposerSubmitClaim, result: UserTurnSubmissionResult) {
        guard let pending = ui.composer.pendingSubmissions.removeValue(forKey: claim.attempt.id) else { return }
        if case let .blocked(message) = result,
           sessions[claim.attempt.sourceTabID] === claim.sourceSession
        {
            claim.cancellation.restoreOwedDraftIfNeeded(message: message)
            restorePendingComposerRepromptMetadata(pending, message: message)
        }
        if case .blocked = result { clearRepromptSubmissionState(claimID: claim.attempt.id) }
        // The executor owns release. UI cleanup is not evidence of producer completion.
    }
}
