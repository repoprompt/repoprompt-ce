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

    func testOracleElapsedFooterRequiresCompletedExactFinalizedAssistant() {
        let replyID = UUID()
        let result = OracleMemberPresentation(status: .completed, elapsedSeconds: 0.25, assistantReplyID: replyID)
        let exact = AIChatMessage(id: replyID, content: "answer", isUser: false, isFinalized: true)
        XCTAssertEqual(result.completedElapsedSeconds(for: exact), 0.25)
        for message in [
            AIChatMessage(content: "answer", isUser: false, isFinalized: true),
            AIChatMessage(id: replyID, content: "answer", isUser: true, isFinalized: true),
            AIChatMessage(id: replyID, content: "answer", isUser: false, isFinalized: false)
        ] {
            XCTAssertNil(result.completedElapsedSeconds(for: message))
        }
        for status in [OracleMemberPresentation.Status.streaming, .settled, .failed, .cancelled, .unknown] {
            XCTAssertNil(
                OracleMemberPresentation(status: status, elapsedSeconds: 5, assistantReplyID: replyID)
                    .completedElapsedSeconds(for: exact)
            )
        }
        XCTAssertNil(OracleMemberPresentation(status: .completed, elapsedSeconds: 5).completedElapsedSeconds(for: exact))
        XCTAssertNil(OracleMemberPresentation(status: .completed, assistantReplyID: replyID).completedElapsedSeconds(for: exact))
    }

    func testOracleElapsedFooterFormatsOnlyKnownDurationsWithSpokenUnits() throws {
        let cases: [(Double, String, String)] = [
            (0.25, "0s", "0 seconds"), (1.9, "1s", "1 second"), (2, "2s", "2 seconds"),
            (60, "1m 00s", "1 minute, 0 seconds"), (61.8, "1m 01s", "1 minute, 1 second"),
            (62, "1m 02s", "1 minute, 2 seconds"), (121, "2m 01s", "2 minutes, 1 second")
        ]
        for (seconds, visible, spoken) in cases {
            let label = try XCTUnwrap(TokenUsagePresentation.elapsedText(seconds: seconds))
            XCTAssertEqual(label.visible, "Elapsed: \(visible)")
            XCTAssertEqual(label.spoken, "Elapsed \(spoken)")
        }
        let invalid: [Double?] = [nil, -1, .infinity, .nan, Double.greatestFiniteMagnitude]
        for value in invalid {
            XCTAssertNil(TokenUsagePresentation.elapsedText(seconds: value))
        }
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
