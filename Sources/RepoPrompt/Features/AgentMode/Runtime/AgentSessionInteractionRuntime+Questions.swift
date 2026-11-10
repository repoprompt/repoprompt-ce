import Foundation
import MCP

@MainActor
extension AgentSessionInteractionRuntime {
    /// Admission/loading belongs to the caller's existing lifecycle authority. Once admitted,
    /// the exact scope and request remain alive until response, timeout or cancellation settles.
    /// Presentation is optional; a delayed cancellation never looks up a successor by tab UUID.
    func askUser(command: AgentSessionRuntimeStore.Command, interaction: AgentAskUserInteraction) async throws -> AgentAskUserResponse {
        guard command.writer.scope === scope, command.isCurrent else {
            throw MCPError.invalidParams("The Agent session is unavailable for its question.")
        }
        let owner = command.writer.scope
        let session = command.writer.session
        if let message = session.operationAdmissionFailureMessage { throw MCPError.invalidParams(message) }
        try Task.checkCancellation()
        try interaction.validate()
        try rejectAskUserIfBlockingInteractionExists(in: session)

        let identity = ObjectIdentifier(session)
        let waitID = UUID()
        questionWaits[identity] = QuestionWait(id: waitID, writer: command.identity, runID: session.runID, runAttemptID: session.activeRunAttemptID)
        defer {
            if questionWaits[identity]?.id == waitID { questionWaits.removeValue(forKey: identity) }
            withExtendedLifetime(owner) {}
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // Install the cancellation/response capability before publishing waiting state.
                session.askUserContinuation = continuation
                session.pendingAskUser = AgentAskUserPendingState(interaction: interaction, timeoutStartedAt: interaction.askedAt)
                Self.reconcileInteractiveRunState(session)
                guard questionWaits[identity]?.id == waitID, session.askUserContinuation != nil,
                      session.pendingAskUser?.interaction.id == interaction.id else { return }
                schedulePendingAskUserTimeout(
                    for: session, interactionID: interaction.id, waitID: waitID,
                    timeoutSeconds: interaction.timeoutSeconds, startedAt: interaction.askedAt
                )
                publishQuestionChange(session: session, wait: questionWaits[identity])
            }
        } onCancel: {
            Task { @MainActor [self, session] in
                cancelAskUserInteraction(session: session, interactionID: interaction.id, waitID: waitID)
            }
        }
    }

    func ownsQuestion(command: AgentSessionRuntimeStore.Command, interactionID: UUID) -> Bool {
        let session = command.writer.session
        return command.writer.scope === scope && command.isCurrent
            && questionWaits[ObjectIdentifier(session)]?.writer == command.identity
            && session.pendingAskUser?.interaction.id == interactionID && session.askUserContinuation != nil
    }

    func finishQuestionState(session: AgentTabSession, wait: QuestionWait) {
        // Release the original run's blocker after detachment, but never reconcile a rebound
        // binding or a later run attempt on the same payload.
        if session.persistentSessionBindingIdentity == wait.writer.restoration.bindingIdentity,
           session.runID == wait.runID, session.activeRunAttemptID == wait.runAttemptID
        {
            Self.reconcileInteractiveRunState(session)
        }
        if scope?.originatingWriter(identity: wait.writer, session: session) != nil {
            publishQuestionChange(session: session, wait: wait)
        } else if let scope, scope.sessions[session.tabID] === session {
            // Repaint only the current payload's interaction projection. This is not writer
            // publication, persistence, or permission to reconcile a rebound run's state.
            scope.presentation.interactionChanged(session)
        }
    }

    private func publishQuestionChange(session: AgentTabSession, wait: QuestionWait?) {
        guard let wait, let scope, scope.originatingWriter(identity: wait.writer, session: session) != nil else { return }
        scope.presentation.bindingChanged(session)
    }

    private func rejectAskUserIfBlockingInteractionExists(in session: AgentTabSession) throws {
        if session.pendingAskUser != nil {
            throw MCPError.invalidParams("ask_user is already waiting for a response in this session.")
        }
        if session.pendingApproval != nil || session.hasPendingCodexHookReviewWait || session.pendingPermissionsRequest != nil || session.pendingApplyEditsReview != nil || session.pendingWorktreeMergeReview != nil {
            throw MCPError.invalidParams("ask_user cannot be shown while an approval is pending.")
        }
        if session.pendingMCPElicitationRequest != nil || !session.queuedMCPElicitationRequests.isEmpty {
            throw MCPError.invalidParams("ask_user cannot be shown while an MCP elicitation is pending.")
        }
        if session.pendingUserInputRequest != nil || !session.queuedUserInputRequests.isEmpty {
            throw MCPError.invalidParams("ask_user cannot be shown while native user input is pending.")
        }
    }

    @discardableResult
    func updateAskUserDraft(command: AgentSessionRuntimeStore.Command, interactionID: UUID, questionID: String, draft: AgentAskUserDraft) -> Bool {
        let session = command.writer.session
        guard ownsQuestion(command: command, interactionID: interactionID),
              var pending = session.pendingAskUser,
              pending.interaction.id == interactionID,
              pending.interaction.questions.contains(where: { $0.id == questionID }),
              pending.draftsByQuestionID[questionID] != draft else { return false }
        pending.draftsByQuestionID[questionID] = draft
        session.pendingAskUser = pending
        scope?.presentation.bindingChanged(session)
        return true
    }

    @discardableResult
    func updateAskUserQuestionIndex(command: AgentSessionRuntimeStore.Command, interactionID: UUID, index: Int) -> Bool {
        let session = command.writer.session
        guard ownsQuestion(command: command, interactionID: interactionID),
              var pending = session.pendingAskUser,
              pending.interaction.id == interactionID,
              pending.interaction.questions.indices.contains(index), pending.currentQuestionIndex != index else { return false }
        pending.currentQuestionIndex = index
        session.pendingAskUser = pending
        scope?.presentation.bindingChanged(session)
        return true
    }

    @discardableResult
    func noteAskUserCardActivity(command: AgentSessionRuntimeStore.Command, interactionID: UUID) -> Bool {
        let session = command.writer.session
        guard ownsQuestion(command: command, interactionID: interactionID), let pending = session.pendingAskUser,
              let wait = questionWaits[ObjectIdentifier(session)],
              pending.interaction.id == interactionID, session.askUserContinuation != nil else { return false }
        schedulePendingAskUserTimeout(
            for: session, interactionID: interactionID, waitID: wait.id,
            timeoutSeconds: pending.interaction.timeoutSeconds, startedAt: Date()
        )
        scope?.presentation.interactionChanged(session)
        return true
    }

    private func schedulePendingAskUserTimeout(
        for session: AgentTabSession, interactionID: UUID, waitID: UUID, timeoutSeconds: TimeInterval, startedAt: Date
    ) {
        session.askUserTimeoutTask?.cancel()
        session.pendingAskUserTimeoutGeneration &+= 1
        let generation = session.pendingAskUserTimeoutGeneration
        if var pending = session.pendingAskUser, pending.interaction.id == interactionID {
            pending.timeoutStartedAt = startedAt
            session.pendingAskUser = pending
        }
        let sleepNanoseconds = UInt64(max(0, timeoutSeconds) * 1_000_000_000)
        session.askUserTimeoutTask = Task { @MainActor [weak self, weak session] in
            do { try await Task.sleep(nanoseconds: sleepNanoseconds) } catch { return }
            guard let self, let session else { return }
            expireAskUserTimeout(for: session, interactionID: interactionID, waitID: waitID, generation: generation)
        }
    }

    /// A timeout settles only its original request. It must still release that caller when its
    /// session has detached; optional publication is independently exact-object fenced.
    func expireAskUserTimeout(for session: AgentTabSession, interactionID: UUID, waitID: UUID, generation: UInt64) {
        guard let wait = questionWaits[ObjectIdentifier(session)], wait.id == waitID,
              session.pendingAskUserTimeoutGeneration == generation,
              let pending = session.pendingAskUser, pending.interaction.id == interactionID,
              let continuation = session.askUserContinuation else { return }
        Self.invalidatePendingAskUserTimeout(for: session)
        session.pendingAskUser = nil
        session.askUserContinuation = nil
        questionWaits.removeValue(forKey: ObjectIdentifier(session))
        finishQuestionState(session: session, wait: wait)
        let elapsedSeconds = max(0, Int(Date().timeIntervalSince(pending.interaction.askedAt)))
        continuation.resume(returning: pending.interaction.buildTimedOutResponse(
            drafts: pending.draftsByQuestionID, elapsedSeconds: elapsedSeconds
        ))
    }

    @discardableResult
    func cancelAskUserInteraction(session: AgentTabSession, interactionID: UUID, waitID: UUID) -> Bool {
        guard let wait = questionWaits[ObjectIdentifier(session)], wait.id == waitID,
              session.pendingAskUser?.interaction.id == interactionID,
              let continuation = session.askUserContinuation else { return false }
        Self.invalidatePendingAskUserTimeout(for: session)
        session.pendingAskUser = nil
        session.askUserContinuation = nil
        questionWaits.removeValue(forKey: ObjectIdentifier(session))
        finishQuestionState(session: session, wait: wait)
        continuation.resume(throwing: CancellationError())
        return true
    }
}
