import Foundation
@testable import RepoPromptApp
import SwiftOpenAI
import XCTest

final class OracleTransportActivityPropagationTests: XCTestCase {
    func testOpenAIDecodedChunkAdapterPreservesChoiceAndDeltaSemantics() throws {
        func chunk(_ object: [String: Any]) throws -> ChatCompletionChunkObject {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try JSONDecoder().decode(ChatCompletionChunkObject.self, from: data)
        }

        let heartbeatChoice: [String: Any] = ["delta": [String: Any](), "index": 0]
        let semanticChoice: [String: Any] = ["delta": ["content": "content"], "index": 1]

        XCTAssertTrue(try OpenAIProvider.isTransportActivityChunk(chunk(["choices": [heartbeatChoice]])))
        XCTAssertTrue(try OpenAIProvider.isTransportActivityChunk(chunk([
            "choices": [heartbeatChoice, semanticChoice]
        ])))
        XCTAssertFalse(try OpenAIProvider.isTransportActivityChunk(chunk(["choices": []])))
        XCTAssertFalse(try OpenAIProvider.isTransportActivityChunk(chunk([
            "choices": [["index": 0]]
        ])))

        let semanticDeltas: [[String: Any]] = [
            ["content": "content"],
            ["reasoning_content": "reasoning"],
            ["role": "assistant"],
            ["tool_calls": [[
                "index": 0,
                "id": "call-1",
                "type": "function",
                "function": ["arguments": "{}", "name": "tool"]
            ]]],
            ["function_call": ["arguments": "{}", "name": "tool"]],
            ["refusal": "refusal"]
        ]
        for delta in semanticDeltas {
            XCTAssertFalse(try OpenAIProvider.isTransportActivityChunk(chunk([
                "choices": [["delta": delta, "index": 0]]
            ])))
        }

        XCTAssertFalse(try OpenAIProvider.isTransportActivityChunk(chunk([
            "choices": [["delta": [String: Any](), "finish_reason": "stop", "index": 0]]
        ])))
        XCTAssertFalse(try OpenAIProvider.isTransportActivityChunk(chunk([
            "choices": [heartbeatChoice],
            "usage": ["prompt_tokens": 1, "completion_tokens": 2, "total_tokens": 3]
        ])))
    }

    func testOpenAITransportPredicateRejectsEachSemanticFact() {
        func classifies(
            hasChoice: Bool = true,
            hasDelta: Bool = true,
            content: String? = nil,
            reasoning: String? = nil,
            role: String? = nil,
            hasToolCalls: Bool = false,
            hasFunctionCall: Bool = false,
            refusal: String? = nil,
            hasFinishReason: Bool = false,
            hasUsage: Bool = false
        ) -> Bool {
            OpenAIProvider.isTransportActivityChunk(
                hasChoice: hasChoice,
                hasDelta: hasDelta,
                content: content,
                reasoning: reasoning,
                role: role,
                hasToolCalls: hasToolCalls,
                hasFunctionCall: hasFunctionCall,
                refusal: refusal,
                hasFinishReason: hasFinishReason,
                hasUsage: hasUsage
            )
        }

        XCTAssertTrue(classifies())
        XCTAssertFalse(classifies(hasChoice: false))
        XCTAssertFalse(classifies(hasDelta: false))
        XCTAssertFalse(classifies(content: "content"))
        XCTAssertFalse(classifies(reasoning: "reasoning"))
        XCTAssertFalse(classifies(role: "assistant"))
        XCTAssertFalse(classifies(hasToolCalls: true))
        XCTAssertFalse(classifies(hasFunctionCall: true))
        XCTAssertFalse(classifies(refusal: "refusal"))
        XCTAssertFalse(classifies(hasFinishReason: true))
        XCTAssertFalse(classifies(hasUsage: true))
    }

    func testAIQueriesServiceSanitizesTransportActivityOutput() {
        let activity = AIStreamResult(
            type: AIStreamResult.transportActivityType,
            text: "ignored",
            reasoning: "ignored",
            promptTokens: 1,
            completionTokens: 2,
            cost: 3,
            providerSessionID: "ignored",
            cleanupHandle: ProviderConversationCleanupHandle(
                provider: "ignored",
                conversationID: "ignored"
            )
        )

        let output = AIQueriesService.transportActivityOutput(for: activity)

        XCTAssertNotNil(output)
        XCTAssertEqual(output?.text, "")
        XCTAssertNil(output?.reasoning)
        XCTAssertEqual(output?.tokens, ChatTokenInfo())
        XCTAssertFalse(output?.isFinal ?? true)
        XCTAssertNil(output?.cleanupHandle)
        XCTAssertTrue(output?.isTransportActivity ?? false)
        XCTAssertNil(
            AIQueriesService.transportActivityOutput(
                for: AIStreamResult(type: "content", text: "hello")
            )
        )
    }

    @MainActor
    func testOracleMapsTransportAndSemanticOutputsToExistingStreamActivity() {
        let transportOutput = ChatStreamOutput(
            text: "",
            reasoning: nil,
            tokens: ChatTokenInfo(),
            isFinal: false,
            isTransportActivity: true
        )
        let emptyOutput = ChatStreamOutput(
            text: "",
            reasoning: nil,
            tokens: ChatTokenInfo(),
            isFinal: false
        )
        let contentOutput = ChatStreamOutput(
            text: "hello",
            reasoning: nil,
            tokens: ChatTokenInfo(),
            isFinal: false
        )
        let reasoningOutput = ChatStreamOutput(
            text: "",
            reasoning: "thinking",
            tokens: ChatTokenInfo(),
            isFinal: false
        )

        XCTAssertEqual(OracleViewModel.lifecycleActivityKind(for: transportOutput), .streamActivity)
        XCTAssertNil(OracleViewModel.lifecycleActivityKind(for: emptyOutput))
        XCTAssertEqual(OracleViewModel.lifecycleActivityKind(for: contentOutput), .streamActivity)
        XCTAssertEqual(OracleViewModel.lifecycleActivityKind(for: reasoningOutput), .streamActivity)
    }
}
