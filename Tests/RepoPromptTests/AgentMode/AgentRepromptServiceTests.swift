import Foundation
@testable import RepoPromptApp
import RepoPromptSettingsCore
import XCTest

final class AgentRepromptServiceTests: XCTestCase {
    static let valid = #"{"version":1,"brief":{"goal":"Keep my voice","constraints":[],"acceptanceCriteria":[],"knownContext":[],"assumptions":[]},"openQuestions":[],"contextRequests":[]}"#

    func testMessageIncludesOnlyDeclaredInputsAndRefinesFromOriginal() throws {
        var request = AgentRepromptRequest(originalText: "original <untrusted>", manifest: "Root: sample\nfile.swift", guidance: "My guidance")
        request.answers = [.init(question: "Which?", customText: "My custom answer")]
        request.consultResults = [.init(kind: .oracle, status: "success", text: "Known context")]
        let message = try AgentRepromptService.message(for: request)
        XCTAssertTrue(message.systemPrompt.contains("prompt rewriter, not a coding agent"))
        XCTAssertTrue(message.systemPrompt.contains("My guidance"))
        XCTAssertEqual(message.conversationMessages.count, 1)
        XCTAssertTrue(message.transientImages.isEmpty)
        XCTAssertTrue(message.fileBlocks.isEmpty)
        XCTAssertTrue(message.metaPrompts.isEmpty)
        XCTAssertTrue(message.fileTree.isEmpty)
        XCTAssertNil(message.gitDiff)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.conversationMessages[0].content.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["originalText", "manifest", "answers", "consultResults"])
        XCTAssertEqual(object["originalText"] as? String, request.originalText)
        XCTAssertFalse(message.conversationMessages[0].content.contains("Keep my voice"))
    }

    func testMinimalResultAndSingleFenceAcceptedButProseAndInvalidContractsRejected() throws {
        let result = try AgentRepromptResult.decode(Self.valid, refinement: false, contextPolicy: .automatic)
        XCTAssertEqual(result.renderedBrief, "## Goal\nKeep my voice")
        XCTAssertEqual(try AgentRepromptResult.decode("```json\n\(Self.valid)\n```", refinement: true, contextPolicy: .never), result)
        for invalid in ["Here is JSON: " + Self.valid, Self.valid.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"), Self.valid.replacingOccurrences(of: "Keep my voice", with: " "), String(repeating: "x", count: 65537)] {
            XCTAssertThrowsError(try AgentRepromptResult.decode(invalid, refinement: false, contextPolicy: .automatic))
        }
    }

    func testContextRequestsRejectedOnRefinementOrNeverAndDuplicatesRejected() throws {
        let consult = #"{"kind":"oracle","question":"Which pattern?"}"#
        let first = Self.valid.replacingOccurrences(of: "\"contextRequests\":[]", with: "\"contextRequests\":[\(consult)]")
        XCTAssertEqual(try AgentRepromptResult.decode(first, refinement: false, contextPolicy: .automatic).contextRequests.count, 1)
        XCTAssertThrowsError(try AgentRepromptResult.decode(first, refinement: true, contextPolicy: .automatic))
        XCTAssertThrowsError(try AgentRepromptResult.decode(first, refinement: false, contextPolicy: .never))
        XCTAssertThrowsError(try AgentRepromptResult.decode(first.replacingOccurrences(of: "[\(consult)]", with: "[\(consult),\(consult)]"), refinement: false, contextPolicy: .automatic))
    }

    func testNeverOmitsManifestAndBoundsRejectRatherThanTruncate() throws {
        var request = AgentRepromptRequest(originalText: "Hello", manifest: "sensitive path", contextPolicy: .never)
        let message = try AgentRepromptService.message(for: request)
        XCTAssertFalse(message.conversationMessages[0].content.contains("sensitive path"))
        request = .init(originalText: String(repeating: "é", count: 16385))
        XCTAssertThrowsError(try AgentRepromptService.message(for: request))
        XCTAssertEqual(AgentRepromptService.timeout(for: .openAI), 60)
        for provider in [AIProviderType.claudeCode, .codex, .cursor, .openCode, .devin] {
            XCTAssertEqual(AgentRepromptService.timeout(for: provider), 120)
        }
    }

    func testTimeoutReturnsEvenWhenTransportIgnoresCancellation() async throws {
        let model = AIModel.gpt61Sol
        let service = AgentRepromptService(transport: { _, _ in
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { continuation.resume() }
            }
            return Self.valid
        }, timeoutOverride: 0.01)
        do {
            _ = try await service.generate(request: .init(originalText: "Hello"), model: model)
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? AgentRepromptError, .timeout) }
    }

    func testCancellationAndLateTransportCannotSucceed() async throws {
        let model = AIModel.gpt61Sol
        let service = AgentRepromptService(transport: { _, _ in
            try? await Task.sleep(for: .seconds(1))
            return Self.valid
        })
        let task = Task { try await service.generate(request: .init(originalText: "Hello"), model: model) }
        task.cancel()
        do { _ = try await task.value
            XCTFail("Cancelled request succeeded")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
