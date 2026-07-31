@testable import RepoPromptApp
import XCTest

final class OracleTransportActivityPropagationTests: XCTestCase {
    func testOpenAIClassifiesOnlyEmptyNonFinalDecodedChunksAsTransportActivity() {
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
