import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
func waitForPendingCodexHookReview(
    in session: AgentModeViewModel.TabSession,
    timeout: TimeInterval = 2,
    diagnostic: @autoclosure () -> String
) async throws -> AgentCodexHookReviewRequest {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let request = session.pendingCodexHookReview,
           session.codexHookReviewContinuation != nil
        {
            return request
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail(diagnostic())
    throw CancellationError()
}
