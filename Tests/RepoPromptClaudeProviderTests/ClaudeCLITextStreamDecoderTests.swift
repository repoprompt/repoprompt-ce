import Foundation
import RepoPromptClaudeProvider
import XCTest

final class ClaudeCLITextStreamDecoderTests: XCTestCase {
    func testClaudeWholeMessageFallbackRejectsTruncatedSuccess() throws {
        var decoder = ClaudeCLITextStreamDecoder()
        let frames = """
        {"type":"assistant","message":{"stop_reason":"max_tokens","content":[{"type":"text","text":"Recoverable partial brief"}]}}
        {"type":"result","subtype":"success","is_error":false}

        """
        XCTAssertEqual(try decoder.append(Data(frames.utf8)), ["Recoverable partial brief"])
        XCTAssertThrowsError(try decoder.finish()) { error in
            XCTAssertTrue(error is ClaudeCLITextStreamFailure)
        }
    }

    func testClaudeDecoderEmitsPartialTextAndNeverDuplicatesAssistantSnapshot() throws {
        var decoder = ClaudeCLITextStreamDecoder()
        let first = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}}"# + "\n"
        XCTAssertEqual(try decoder.append(Data(first.utf8)), ["Hello"])
        let final = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}]}}"# + "\n" + #"{"type":"result","subtype":"success","is_error":false}"# + "\n"
        XCTAssertTrue(try decoder.append(Data(final.utf8)).isEmpty)
        XCTAssertTrue(try decoder.finish().isEmpty)
        var truncated = ClaudeCLITextStreamDecoder()
        _ = try truncated.append(Data(first.utf8))
        XCTAssertThrowsError(try truncated.finish())
    }
}
