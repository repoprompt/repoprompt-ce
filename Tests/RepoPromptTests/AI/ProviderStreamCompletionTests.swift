import Foundation
@testable import RepoPromptApp
import SwiftOpenAI
import XCTest

final class ProviderStreamCompletionTests: XCTestCase {
    func testACPChatStreamExcludesSystemAndStatusWithoutDroppingAssistantOrTransportResults() async throws {
        let engine = ACPCLIChatProviderEngine(
            providerName: "Devin",
            providerType: .devin,
            makeProvider: { _ in ScriptedACPChatProvider() }
        )
        let stream = try await engine.streamMessage(
            AIMessage(systemPrompt: "system", userMessage: "question"),
            model: .devinCustom(name: "claude-opus-4-6")
        )
        var results: [AIStreamResult] = []
        for try await result in stream {
            results.append(result)
        }
        await engine.dispose()

        XCTAssertEqual(results.compactMap(\.text), ["answer", "final answer"])
        XCTAssertEqual(results.compactMap(\.reasoning), ["thinking"])
        XCTAssertEqual(results.map(\.type), [
            AIStreamResult.lifecycleType,
            "content",
            AIStreamResult.transportActivityType,
            "final_content",
            "message_stop"
        ])
        XCTAssertEqual(results.last?.promptTokens, 11)
        XCTAssertEqual(results.last?.completionTokens, 7)
        XCTAssertEqual(results.last?.cost, 0.25)
        XCTAssertEqual(results.last?.providerSessionID, "session-1")
    }

    func testOpenAIStopReasonReportsSuccessfulCompletion() {
        XCTAssertEqual(openAIChatCompletionOutcome(.string("stop")), .completed)
        XCTAssertNil(openAIChatCompletionOutcome(nil))
    }

    func testOpenAIIncompleteStopReasonIsPreserved() {
        XCTAssertEqual(
            openAIChatCompletionOutcome(.string("length")),
            .incomplete(reason: "length")
        )
    }

    func testAnthropicSuccessfulCompletionReasonsAreExplicit() {
        XCTAssertTrue(AnthropicProvider.isSuccessfulCompletionStopReason("end_turn"))
        XCTAssertTrue(AnthropicProvider.isSuccessfulCompletionStopReason("stop_sequence"))
        XCTAssertFalse(AnthropicProvider.isSuccessfulCompletionStopReason("max_tokens"))
        XCTAssertFalse(AnthropicProvider.isSuccessfulCompletionStopReason("tool_use"))
    }

    func testAIQueriesNormalizesIncompleteTerminationWithoutMarkingSuccess() throws {
        let result = AIStreamResult(
            type: AIStreamResult.incompleteType,
            text: nil,
            stopReason: "max_tokens"
        )

        let outcome = try AIQueriesService.terminalOutcome(for: result)

        XCTAssertEqual(outcome, .incomplete(reason: "max_tokens"))
        XCTAssertNotEqual(outcome, .completed)
    }

    func testAIQueriesRejectsIncompleteTerminationWithoutReason() {
        let result = AIStreamResult(type: AIStreamResult.incompleteType, text: nil)

        XCTAssertThrowsError(try AIQueriesService.terminalOutcome(for: result)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The provider reported incomplete termination without a reason."
            )
        }
    }
}

private final class ScriptedACPChatProvider: HeadlessAgentProvider {
    func streamAgentMessage(_: AgentMessage, runID _: UUID?) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            for result in [
                AIStreamResult(type: "system", text: "provider warning"),
                AIStreamResult(type: "status", text: "Oracle prompt title"),
                AIStreamResult(type: AIStreamResult.lifecycleType, text: nil),
                AIStreamResult(type: "content", text: "answer", reasoning: "thinking"),
                AIStreamResult(type: AIStreamResult.transportActivityType, text: nil),
                AIStreamResult(type: "final_content", text: "final answer"),
                AIStreamResult(
                    type: "message_stop",
                    text: nil,
                    promptTokens: 11,
                    completionTokens: 7,
                    cost: 0.25,
                    providerSessionID: "session-1"
                )
            ] {
                continuation.yield(result)
            }
            continuation.finish()
        }
    }

    func dispose() async {}
}
