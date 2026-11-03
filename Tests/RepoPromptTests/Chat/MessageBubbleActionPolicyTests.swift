@testable import RepoPromptApp
import XCTest

final class MessageBubbleActionPolicyTests: XCTestCase {
    func testMutatingActionAvailabilityMatchesTranscriptPolicy() {
        XCTAssertTrue(ChatTranscriptActionPolicy.standard.allowsMutatingActions)
        XCTAssertFalse(ChatTranscriptActionPolicy.nonMutating.allowsMutatingActions)
    }

    func testUsageAvailabilityMatchesTranscriptPolicy() {
        XCTAssertTrue(ChatTranscriptActionPolicy.standard.showsTokenUsage)
        XCTAssertFalse(ChatTranscriptActionPolicy.nonMutating.showsTokenUsage)
    }

    func testTokenUsagePreservesCompletePartialAndUnavailableCounters() {
        let cases: [(Int?, Int?, String)] = [
            (12345, 1940, "Tokens: 12.35k in | 1.94k out"),
            (12345, nil, "Tokens: 12.35k in | unavailable out"),
            (nil, 1940, "Tokens: unavailable in | 1.94k out"),
            (nil, nil, "Usage unavailable"),
            (0, nil, "Tokens: 0 in | unavailable out"),
            (nil, 0, "Tokens: unavailable in | 0 out")
        ]
        for (input, output, expected) in cases {
            XCTAssertEqual(TokenUsagePresentation.text(inputTokens: input, outputTokens: output), expected)
        }
    }

    func testTokenUsageDistinguishesZeroAndSmallPositiveCounts() {
        let cases: [(Int, String)] = [
            (0, "0"), (1, "1"), (3, "3"), (4, "4"), (5, "5"),
            (999, "999"), (1000, "1.00k")
        ]
        for (tokens, expected) in cases {
            XCTAssertEqual(
                TokenUsagePresentation.text(inputTokens: tokens, outputTokens: tokens),
                "Tokens: \(expected) in | \(expected) out"
            )
        }
    }
}
