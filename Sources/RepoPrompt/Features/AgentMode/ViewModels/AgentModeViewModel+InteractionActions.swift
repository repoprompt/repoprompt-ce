import Foundation

@MainActor
extension AgentModeViewModel {
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
