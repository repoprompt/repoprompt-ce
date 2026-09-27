import Foundation

@MainActor
extension AgentModeViewModel {
    /// Id-checked approval submission: applies `decision` only while `requestID` is still the pending
    /// approval for `tabID`. Returns whether that approval was consumed.
    @discardableResult
    func submitApprovalDecision(tabID: UUID, requestID: UUID, decision: AgentApprovalDecision) -> Bool {
        guard let session = sessions[tabID], session.pendingApproval?.id == requestID else {
            return false
        }
        submitApprovalDecision(tabID: tabID, decision: decision)
        return session.pendingApproval?.id != requestID
    }

    /// Unchecked variant resolving whatever approval is currently pending. Prefer the id-checked
    /// overload for any caller that captured the request earlier (cards, notifications).
    func submitApprovalDecision(tabID: UUID, decision: AgentApprovalDecision) {
        guard let session = sessions[tabID],
              let request = session.pendingApproval
        else {
            return
        }
        switch request.requestID {
        case .codex:
            codexCoordinator.submitApprovalDecision(session: session, decision: decision)
        case .claudeControl:
            claudeCoordinator.submitApprovalDecision(session: session, decision: decision)
        case let .acp(requestID):
            session.pendingApproval = nil
            if session.runState == .waitingForApproval {
                session.runState = .running
            }
            requestUIRefresh(tabID: tabID, urgent: true)
            Task { [controller = session.acpController] in
                await controller?.respondToPermissionRequest(id: requestID, decision: decision)
            }
        }
    }

    func submitCodexHookReviewDecision(
        tabID: UUID,
        requestID: UUID,
        decision: AgentCodexHookReviewDecision
    ) async throws {
        guard let session = sessions[tabID],
              let currentRequest = session.pendingCodexHookReview
        else {
            throw AgentCodexHookReviewResolutionError.noPendingReview
        }
        guard currentRequest.id == requestID else {
            throw AgentCodexHookReviewResolutionError.staleRequest(currentID: currentRequest.id)
        }
        try await codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: requestID,
            decision: decision
        )
    }

    func isCodexHookApprovalStrictModeEnabled() -> Bool {
        codexCoordinator.isCodexHookApprovalStrictModeEnabled()
    }

    func submitMCPElicitationResponse(
        tabID: UUID,
        requestID: UUID,
        response: AgentMCPElicitationResponse
    ) {
        guard let session = sessions[tabID],
              let request = session.pendingMCPElicitationRequest,
              request.id == requestID
        else {
            return
        }
        codexCoordinator.submitMCPElicitationResponse(session: session, request: request, response: response)
    }

    func submitApplyEditsReviewDecision(
        tabID: UUID,
        reviewID: UUID,
        decision: ApplyEditsReviewDecision
    ) {
        let scope = applyEditsScope(for: tabID)
        Task { [applyEditsApprovalStore] in
            await applyEditsApprovalStore.resolveReview(
                scope: scope,
                reviewID: reviewID,
                decision: decision
            )
        }
    }
}
