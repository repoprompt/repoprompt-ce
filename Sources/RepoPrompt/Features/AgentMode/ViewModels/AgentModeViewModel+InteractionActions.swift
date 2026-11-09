import Foundation
import RepoPromptDomainRuntime

@MainActor
extension AgentModeViewModel {
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
        guard let session = activeSession else { return true }
        return codexCoordinator.isCodexHookApprovalStrictModeEnabled(for: session)
    }

    func codexRememberedApprovalAllowed(for tabID: UUID?) -> Bool {
        guard let tabID else { return true }
        return sessions[tabID]?.codexControllerFeatureState?.computerUseEnabled != true
    }
}
