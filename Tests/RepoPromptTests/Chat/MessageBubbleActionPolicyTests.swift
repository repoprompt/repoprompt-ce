@testable import RepoPromptApp
import XCTest

final class MessageBubbleActionPolicyTests: XCTestCase {
    func testMutatingActionAvailabilityMatchesTranscriptPolicy() {
        XCTAssertTrue(ChatTranscriptActionPolicy.standard.allowsMutatingActions)
        XCTAssertFalse(ChatTranscriptActionPolicy.nonMutating.allowsMutatingActions)
    }
}
