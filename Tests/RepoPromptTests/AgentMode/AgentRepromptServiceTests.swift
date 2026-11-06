import Foundation
@testable import RepoPromptApp
import RepoPromptSettingsCore
import XCTest

final class AgentRepromptServiceTests: XCTestCase {
    static let valid = "Keep my voice. Fix only the parser behavior I described."
    static let questions = #"[{"id":"scope","question":"Which scope?","options":[{"label":"Small"},{"label":"Large"}]}]"#

    func testMessageContainsOnlyDeclaredInputsAndFixedHistoryFraming() throws {
        let request = AgentRepromptRequest(originalText: "That's wrong. Start over with a different approach.", guidance: "My guidance", answers: [.init(question: "Which?", customText: "My answer")])
        let message = try AgentRepromptService.message(for: request)
        XCTAssertTrue(message.systemPrompt.contains("prompt rewriter, not a coding agent"))
        XCTAssertTrue(message.systemPrompt.contains(AgentRepromptHistory.framing))
        XCTAssertTrue(message.systemPrompt.contains("do NOT carry forward the prior"))
        XCTAssertTrue(message.systemPrompt.contains("My guidance"))
        XCTAssertEqual(message.conversationMessages.count, 1)
        XCTAssertTrue(message.attachments.isEmpty && message.fileBlocks.isEmpty && message.metaPrompts.isEmpty && message.fileTree.isEmpty)
        XCTAssertNil(message.gitDiff)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.conversationMessages[0].content.utf8)) as? [String: Any])
        XCTAssertEqual(object["originalText"] as? String, request.originalText)
        XCTAssertNil(object["contextRequests"])
        XCTAssertNil(object["consultResults"])
        XCTAssertNil(object["guidance"])
        XCTAssertNil(object["manifest"])
        XCTAssertNil(object["attachments"], "An absent attachment list must not suggest files to the model")
        XCTAssertNil(object["sessionTitle"])
    }

    func testContractDescribesAttachmentsAndForbidsSpeculation() throws {
        let contract = try AgentRepromptService.message(for: .init(originalText: "Hello")).systemPrompt
        for required in ["attachments", "recentChat", "sessionTitle", "cannot see their contents", "candidate intents", "hedged guesses", "remarks about the draft", "near-identical", "exactly one thing", "do not guess"] {
            XCTAssertTrue(contract.contains(required), required)
        }
        for removed in ["anifest", "vocabulary", "Leave incidental gaps", "unspecified"] {
            XCTAssertFalse(contract.contains(removed), removed)
        }
    }

    func testOnlyAnExplicitRequestAbandonsPriorWork() {
        let framing = AgentRepromptHistory.framing
        XCTAssertTrue(framing.contains("changes only what it"))
        XCTAssertTrue(framing.contains("explicitly asks to abandon or redo"))
        XCTAssertFalse(framing.contains("signals frustration"), "Frustration alone must not read as a scope change")
        XCTAssertFalse(framing.contains("if useful"), "Abandonment language must not be optional colour on a correction")
    }

    func testAttachmentAndTitleInputsAreEncodedAndBounded() throws {
        let request = AgentRepromptRequest(originalText: "See this", attachments: [.init(name: "shot.png", kind: "image")], sessionTitle: "CI gating")
        let message = try AgentRepromptService.message(for: request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.conversationMessages[0].content.utf8)) as? [String: Any])
        XCTAssertEqual(object["attachments"] as? [[String: String]], [["name": "shot.png", "kind": "image"]])
        XCTAssertEqual(object["sessionTitle"] as? String, "CI gating")
        XCTAssertTrue(message.attachments.isEmpty, "Names only: no attachment payload reaches the rewriter")
        XCTAssertThrowsError(try AgentRepromptService.message(for: .init(originalText: "x", sessionTitle: String(repeating: "x", count: 1025))))
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
