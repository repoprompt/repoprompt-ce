import Foundation
@testable import RepoPromptApp
import RepoPromptSettingsCore
import XCTest

final class AgentRepromptServiceTests: XCTestCase {
    static let valid = "Keep my voice. Fix only the parser behavior I described."
    static let questions = #"[{"id":"scope","question":"Which scope?","options":[{"label":"Small"},{"label":"Large"}]}]"#

    func testMessageContainsOnlyDeclaredInputsAndFixedHistoryFraming() throws {
        let request = AgentRepromptRequest(originalText: "That's wrong. Start over with a different approach.", manifest: "Root: sample\nfile.swift", guidance: "My guidance", answers: [.init(question: "Which?", customText: "My answer")])
        let message = try AgentRepromptService.message(for: request)
        XCTAssertTrue(message.systemPrompt.contains("prompt rewriter, not a coding agent"))
        XCTAssertTrue(message.systemPrompt.contains(AgentRepromptHistory.framing))
        XCTAssertTrue(message.systemPrompt.contains("do NOT carry forward the prior"))
        XCTAssertTrue(message.systemPrompt.contains("My guidance"))
        XCTAssertEqual(message.conversationMessages.count, 1)
        XCTAssertTrue(message.transientImages.isEmpty && message.fileBlocks.isEmpty && message.metaPrompts.isEmpty && message.fileTree.isEmpty)
        XCTAssertNil(message.gitDiff)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.conversationMessages[0].content.utf8)) as? [String: Any])
        XCTAssertEqual(object["originalText"] as? String, request.originalText)
        XCTAssertNil(object["contextRequests"])
        XCTAssertNil(object["consultResults"])
        XCTAssertNil(object["guidance"])
    }

    func testPlainMarkdownAndDelimiterPrefixesAcrossEveryBoundary() throws {
        for split in 0 ... AgentRepromptStreamParser.delimiter.count {
            var parser = AgentRepromptStreamParser()
            try parser.append(Self.valid)
            let prefix = String(AgentRepromptStreamParser.delimiter.prefix(split))
            try parser.append(prefix)
            XCTAssertEqual(parser.body, Self.valid)
            try parser.append(String(AgentRepromptStreamParser.delimiter.dropFirst(split)))
            for character in Self.questions + AgentRepromptStreamParser.endDelimiter {
                try parser.append(String(character))
            }
            XCTAssertEqual(parser.body, Self.valid, "Question metadata must never enter the composer")
            let result = try parser.finish(refinement: false)
            XCTAssertEqual(result.body, Self.valid)
            XCTAssertEqual(result.openQuestions.count, 1)
            XCTAssertThrowsError(try parser.finish(refinement: true))
        }
        var plain = AgentRepromptStreamParser()
        try plain.append("Hello\n")
        XCTAssertEqual(try plain.finish(refinement: false).body, "Hello")
    }

    func testClarificationLimitsMatchTheSingleQuestionThreeShortcutContract() throws {
        let trailers = [
            #"[{"id":"a","question":"First?","options":[]},{"id":"b","question":"Second?","options":[]}]"#,
            #"[{"id":"a","question":"Choose?","options":[{"label":"1"},{"label":"2"},{"label":"3"},{"label":"4"}]}]"#
        ]
        for trailer in trailers {
            var parser = AgentRepromptStreamParser()
            try parser.append(Self.valid + AgentRepromptStreamParser.delimiter + trailer + AgentRepromptStreamParser.endDelimiter)
            XCTAssertEqual(parser.body, Self.valid)
            XCTAssertThrowsError(try parser.finish(refinement: false)) { error in
                XCTAssertEqual(error as? AgentRepromptError, .invalidResponse)
            }
        }
    }

    func testIncompleteOrInvalidQuestionsKeepRecoverableBodyButCannotComplete() throws {
        for trailer in ["[", Self.questions, "[] trailing prose", #"[{"id":"x","question":"?","options":[]},{"id":"x","question":"?","options":[]}]"# + AgentRepromptStreamParser.endDelimiter] {
            var parser = AgentRepromptStreamParser()
            try parser.append(Self.valid + AgentRepromptStreamParser.delimiter + trailer)
            XCTAssertEqual(parser.body, Self.valid)
            XCTAssertThrowsError(try parser.finish(refinement: false))
        }
    }

    func testUTF8BoundsAndSafetyCeilings() throws {
        XCTAssertThrowsError(try AgentRepromptService.message(for: .init(originalText: String(repeating: "é", count: 16385))))
        var parser = AgentRepromptStreamParser()
        XCTAssertThrowsError(try parser.append(String(repeating: "x", count: 65537)))
        XCTAssertEqual(AgentRepromptService.timeout(for: .openAI), 60)
        XCTAssertEqual(AgentRepromptService.timeout(for: .claudeCode), 120)
        XCTAssertEqual(AgentRepromptService.timeout(for: .codex), 120)
    }

    func testTransportPublishesBeforeCompletion() async throws {
        let probe = AgentRepromptStreamProbe()
        let service = AgentRepromptService(transport: { _, _, publish in
            try await publish("Keep ")
            let seen = await probe.values
            XCTAssertEqual(seen, ["Keep "])
            try await publish("my voice.")
        })
        let result = try await service.generate(request: .init(originalText: "Hello"), model: .gpt61SolLow) { await probe.append($0) }
        XCTAssertEqual(result.body, "Keep my voice.")
    }

    func testTimeoutReturnsEvenWhenTransportIgnoresCancellation() async throws {
        let service = AgentRepromptService(transport: { _, _, publish in
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { continuation.resume() }
            }
            try await publish(Self.valid)
        }, timeoutOverride: 0.01)
        do {
            _ = try await service.generate(request: .init(originalText: "Hello"), model: .gpt61SolLow) { _ in }
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? AgentRepromptError, .timeout) }
    }

    func testCancellationCannotSucceed() async throws {
        let service = AgentRepromptService(transport: { _, _, publish in
            try? await Task.sleep(for: .seconds(1))
            try await publish(Self.valid)
        })
        let task = Task { try await service.generate(request: .init(originalText: "Hello"), model: .gpt61SolLow) { _ in } }
        task.cancel()
        do { _ = try await task.value
            XCTFail("Cancelled request succeeded")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

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

actor AgentRepromptStreamProbe {
    private(set) var values: [String] = []
    func append(_ text: String) {
        values.append(text)
    }
}
