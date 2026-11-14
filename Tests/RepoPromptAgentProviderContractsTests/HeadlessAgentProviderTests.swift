import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import XCTest

final class HeadlessAgentProviderTests: XCTestCase {
    func testDefaultCleanupReportsUnsupportedWithoutStartingOrDisposingExecution() async {
        let provider = CleanupProbe()
        let handle = ProviderConversationCleanupHandle(provider: "fixture", conversationID: "persisted-conversation")
        for action in ProviderConversationCleanupAction.allCases {
            let outcome = await provider.cleanupConversation(handle, action: action)
            XCTAssertEqual(outcome, .unsupported(message: "Provider has no local API for \(action.rawValue) cleanup of conversations."))
        }
        XCTAssertEqual(provider.streamCount, 0)
        XCTAssertEqual(provider.disposeCount, 0)
    }

    func testUnsupportedProviderRetainsItsReasonAndCleanupSemanticsAcrossRepeatedDisposal() async {
        let reason = "Fixture provider cannot execute headless requests."
        let provider = UnsupportedHeadlessAgentProvider(reason: reason)
        for _ in 0 ..< 2 {
            await provider.dispose()
            do {
                _ = try await provider.streamAgentMessage(AgentMessage(userMessage: "Must not execute"), runID: nil)
                XCTFail("Unsupported providers must fail before returning an execution stream")
            } catch let AIProviderError.invalidConfiguration(detail) {
                XCTAssertEqual(detail, reason)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            let outcome = await provider.cleanupConversation(
                ProviderConversationCleanupHandle(provider: "fixture", conversationID: "persisted-conversation"),
                action: .delete
            )
            XCTAssertEqual(outcome, .unsupported(message: "Provider has no local API for delete cleanup of conversations."))
        }
    }
}

private final class CleanupProbe: HeadlessAgentProvider {
    var streamCount = 0
    var disposeCount = 0

    func streamAgentMessage(_ message: AgentMessage, runID: UUID?) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        streamCount += 1
        return AsyncThrowingStream { $0.finish() }
    }

    func dispose() async {
        disposeCount += 1
    }
}
