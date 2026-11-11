import Foundation
import MCP
import RepoPromptVCS

/// The continuation and its originating receipt are one runtime-owned wait, not UI state.
@MainActor
struct AgentWorktreeMergeReviewWait {
    let reviewID: UUID
    let operationID: String
    let originatingWriter: AgentSessionRuntimeStore.WriterIdentity
    let runID: UUID?
    let runAttemptID: UUID?
    let runStateBeforeReview: AgentSessionRunState
    let continuation: CheckedContinuation<WorktreeMergeReviewDecision, Never>
    var timeoutTask: Task<Void, Never>?
}

extension AgentSessionInteractionRuntime {
    func requestWorktreeMergeReview(
        command: AgentSessionRuntimeStore.Command,
        preview: GitWorktreeMergePreview,
        timeoutSeconds: TimeInterval
    ) async throws -> WorktreeMergeReviewDecision {
        guard command.writer.scope === scope, command.isCurrent else {
            throw MCPError.invalidParams("The worktree merge owner is no longer current. No review was shown.")
        }
        let session = command.writer.session
        let owner = command.writer.scope
        cancelPendingWorktreeMergeReview(for: session, reason: "Replaced by newer worktree merge review")
        // Settlement publishes synchronously; a subscriber may have replaced the writer.
        guard command.isCurrent else {
            throw MCPError.invalidParams("The worktree merge owner changed while replacing its review.")
        }
        let review = PendingWorktreeMergeReview(
            scope: WorktreeMergeReviewScope(windowID: 0, tabID: session.tabID),
            preview: preview
        )
        let reviewID = review.id
        let decision = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var wait = AgentWorktreeMergeReviewWait(
                    reviewID: review.id,
                    operationID: review.operationID,
                    originatingWriter: command.identity,
                    runID: session.runID,
                    runAttemptID: session.activeRunAttemptID,
                    runStateBeforeReview: session.runState,
                    continuation: continuation
                )
                if timeoutSeconds > 0 {
                    let reviewID = review.id
                    wait.timeoutTask = Task { @MainActor [weak self, weak session] in
                        do {
                            try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                        } catch {
                            return
                        }
                        guard let self, let session else { return }
                        expireWorktreeMergeReview(session: session, reviewID: reviewID)
                    }
                }
                session.worktreeMergeReviewWait = wait
                AgentWorktreeMergeCoordinator.upsert(
                    AgentWorktreeMergeCoordinator.makeOperation(preview: preview, status: .awaitingApproval),
                    in: &session.worktreeMergeOperations
                )
                session.isDirty = true
                // The exact wait must exist before observers can see the review.
                session.pendingWorktreeMergeReview = review
                if command.isCurrent, session.worktreeMergeReviewWait?.reviewID == review.id {
                    Self.reconcileInteractiveRunState(session)
                    publishWorktreeReviewChange(session: session, writer: command.identity)
                }
            }
        } onCancel: { [weak self, weak session] in
            Task { @MainActor in
                guard let self, let session else { return }
                // Settle only this wait; an old caller cannot cancel a replacement review.
                _ = self.settleWorktreeMergeReview(session: session, reviewID: reviewID, decision: .cancelled(reason: "Worktree merge request was cancelled."))
            }
        }
        // Retain the runtime scope through detached expiry even without a presentation.
        withExtendedLifetime(owner) {}
        return decision
    }

    @discardableResult
    func submitWorktreeMergeReviewDecision(
        command: AgentSessionRuntimeStore.Command,
        reviewID: UUID,
        decision: WorktreeMergeReviewDecision
    ) -> Bool {
        let session = command.writer.session
        guard command.writer.scope === scope, command.isCurrent,
              session.pendingWorktreeMergeReview?.id == reviewID,
              session.worktreeMergeReviewWait?.originatingWriter == command.identity,
              decision != .timeout else { return false }
        return settleWorktreeMergeReview(session: session, reviewID: reviewID, decision: decision)
    }

    /// Timer and run teardown own the original wait even when new command admission is gone.
    func expireWorktreeMergeReview(session: AgentTabSession, reviewID: UUID) {
        settleWorktreeMergeReview(session: session, reviewID: reviewID, decision: .timeout)
    }

    func cancelPendingWorktreeMergeReview(for session: AgentTabSession, reason: String) {
        guard let wait = session.worktreeMergeReviewWait else { return }
        settleWorktreeMergeReview(session: session, reviewID: wait.reviewID, decision: .cancelled(reason: reason))
    }

    @discardableResult
    private func settleWorktreeMergeReview(
        session: AgentTabSession,
        reviewID: UUID,
        decision: WorktreeMergeReviewDecision
    ) -> Bool {
        guard let wait = session.worktreeMergeReviewWait, wait.reviewID == reviewID else { return false }
        session.worktreeMergeReviewWait = nil
        wait.timeoutTask?.cancel()
        if session.pendingWorktreeMergeReview?.id == reviewID {
            session.pendingWorktreeMergeReview = nil
            // Recompute the original run's derived blocker state even after detachment or
            // claim reacquisition, but never rewrite a rebound binding or successor attempt.
            if session.persistentSessionBindingIdentity == wait.originatingWriter.restoration.bindingIdentity,
               session.runID == wait.runID, session.activeRunAttemptID == wait.runAttemptID
            {
                // An admin review can start while no provider run exists. Reconciliation may
                // resume an active run, but must not manufacture one from an idle/terminal state.
                if !wait.runStateBeforeReview.isActive, session.runState == .waitingForApproval,
                   session.activeRunLiveness == nil, session.agentTask == nil
                {
                    session.runState = wait.runStateBeforeReview
                }
                Self.reconcileInteractiveRunState(session)
            }
        }
        if scope?.originatingWriter(identity: wait.originatingWriter, session: session) != nil {
            let operationChanged = decision.cancelledReason.map {
                markWorktreeReviewAbandoned(session: session, operationID: wait.operationID, reason: $0)
            } ?? false
            publishWorktreeReviewChange(session: session, writer: wait.originatingWriter, operationChanged: operationChanged)
        }
        wait.continuation.resume(returning: decision)
        return true
    }

    /// An accepted waiter can lose admission before its caller resumes. This is cleanup only.
    func recordWorktreeMergeReviewAbandoned(
        command: AgentSessionRuntimeStore.Command,
        operationID: String,
        reason: String
    ) {
        let session = command.writer.session
        guard command.writer.scope === scope,
              scope?.originatingWriter(identity: command.identity, session: session) != nil else { return }
        let changed = markWorktreeReviewAbandoned(session: session, operationID: operationID, reason: reason)
        publishWorktreeReviewChange(session: session, writer: command.identity, operationChanged: changed)
    }

    private func markWorktreeReviewAbandoned(session: AgentTabSession, operationID: String, reason: String) -> Bool {
        do {
            try AgentWorktreeMergeCoordinator.update(operationID: operationID, in: &session.worktreeMergeOperations) {
                $0.status = .cancelled
                $0.completedAt = Date()
                $0.lastError = reason
            }
            session.isDirty = true
            return true
        } catch {
            // Preserve best-effort cancellation if the operation was already removed.
            return false
        }
    }

    private func publishWorktreeReviewChange(
        session: AgentTabSession,
        writer: AgentSessionRuntimeStore.WriterIdentity,
        operationChanged: Bool = true
    ) {
        guard let scope, scope.originatingWriter(identity: writer, session: session) != nil else { return }
        if operationChanged {
            scope.presentation.worktreeOperationsChanged(session)
            scope.mcp.handleObservedMCPStateChange(for: session)
            scope.presentation.bindingChanged(session)
            // Presentation callbacks are not authority and may synchronously replace a binding.
            guard scope.originatingWriter(identity: writer, session: session) != nil else { return }
            scope.persistence.scheduleSave(for: session)
        }
        scope.presentation.makeRunHooks().requestUIRefresh(session, true)
    }
}
