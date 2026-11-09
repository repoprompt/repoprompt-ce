import Foundation
import MCP

@MainActor
extension AgentSessionInteractionRuntime {
    /// Admission/loading belongs to the caller's existing lifecycle authority. Once admitted,
    /// the exact scope and request remain alive until response, timeout or cancellation settles.
    /// Presentation is optional; a delayed cancellation never looks up a successor by tab UUID.
    func askUser(session: AgentTabSession, interaction: AgentAskUserInteraction) async throws -> AgentAskUserResponse {
        guard let owner = scope, owns(session), !owner.isRetiring else {
            throw MCPError.invalidParams("The Agent session is unavailable for its question.")
        }
        if let message = session.operationAdmissionFailureMessage { throw MCPError.invalidParams(message) }
        try Task.checkCancellation()
        try interaction.validate()
        try rejectAskUserIfBlockingInteractionExists(in: session)

        let identity = ObjectIdentifier(session)
        let waitID = UUID()
        questionWaitIDs[identity] = waitID
        defer {
            if questionWaitIDs[identity] == waitID { questionWaitIDs.removeValue(forKey: identity) }
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
                guard session.askUserContinuation != nil, session.pendingAskUser?.interaction.id == interaction.id else { return }
                schedulePendingAskUserTimeout(
                    for: session, interactionID: interaction.id,
                    timeoutSeconds: interaction.timeoutSeconds, startedAt: interaction.askedAt
                )
                owner.presentation.bindingChanged(session)
            }
        } onCancel: {
            Task { @MainActor [self, session] in
                guard questionWaitIDs[identity] == waitID else { return }
                cancelAskUserInteraction(session: session, interactionID: interaction.id)
            }
        }
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
        guard command.writer.scope === scope, command.isCurrent, session.askUserContinuation != nil,
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
        guard command.writer.scope === scope, command.isCurrent, session.askUserContinuation != nil,
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
        guard command.writer.scope === scope, command.isCurrent, let pending = session.pendingAskUser,
              pending.interaction.id == interactionID, session.askUserContinuation != nil else { return false }
        schedulePendingAskUserTimeout(
            for: session, interactionID: interactionID,
            timeoutSeconds: pending.interaction.timeoutSeconds, startedAt: Date()
        )
        scope?.presentation.interactionChanged(session)
        return true
    }

    private func schedulePendingAskUserTimeout(
        for session: AgentTabSession, interactionID: UUID, timeoutSeconds: TimeInterval, startedAt: Date
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
            expireAskUserTimeout(for: session, interactionID: interactionID, generation: generation)
        }
    }

    /// A timeout settles only its original request. It must still release that caller when its
    /// session has detached; optional publication is independently exact-object fenced.
    func expireAskUserTimeout(for session: AgentTabSession, interactionID: UUID, generation: UInt64) {
        guard session.pendingAskUserTimeoutGeneration == generation,
              let pending = session.pendingAskUser, pending.interaction.id == interactionID,
              let continuation = session.askUserContinuation else { return }
        Self.invalidatePendingAskUserTimeout(for: session)
        session.pendingAskUser = nil
        session.askUserContinuation = nil
        Self.reconcileInteractiveRunState(session)
        scope?.presentation.bindingChanged(session)
        let elapsedSeconds = max(0, Int(Date().timeIntervalSince(pending.interaction.askedAt)))
        continuation.resume(returning: pending.interaction.buildTimedOutResponse(
            drafts: pending.draftsByQuestionID, elapsedSeconds: elapsedSeconds
        ))
    }

    @discardableResult
    func cancelAskUserInteraction(session: AgentTabSession, interactionID: UUID) -> Bool {
        guard session.pendingAskUser?.interaction.id == interactionID,
              let continuation = session.askUserContinuation else { return false }
        Self.invalidatePendingAskUserTimeout(for: session)
        session.pendingAskUser = nil
        session.askUserContinuation = nil
        Self.reconcileInteractiveRunState(session)
        scope?.presentation.bindingChanged(session)
        continuation.resume(throwing: CancellationError())
        return true
    }
}
