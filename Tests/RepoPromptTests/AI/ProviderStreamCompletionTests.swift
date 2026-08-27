import Foundation
@testable import RepoPromptApp
import SwiftOpenAI
import XCTest

final class ProviderStreamCompletionTests: XCTestCase {
    private let officialEndpoint = URL(string: "https://api.openai.com")!
    private let customEndpoint = URL(string: "http://localhost:8787")!

    func testOpenAIStopReasonReportsSuccessfulCompletion() {
        XCTAssertEqual(openAIChatCompletionOutcome(.string("stop")), .completed)
        XCTAssertNil(openAIChatCompletionOutcome(nil))
    }

    func testCustomOpenAIEndpointEndTurnReportsSuccessfulCompletion() {
        XCTAssertEqual(
            openAIChatCompletionOutcome(.string("end_turn"), endpointBaseURL: customEndpoint),
            .completed
        )
    }

    func testOfficialOpenAIEndpointEndTurnRemainsIncomplete() {
        XCTAssertEqual(
            openAIChatCompletionOutcome(.string("end_turn")),
            .incomplete(reason: "end_turn")
        )
        XCTAssertEqual(
            openAIChatCompletionOutcome(.string("end_turn"), endpointBaseURL: officialEndpoint),
            .incomplete(reason: "end_turn")
        )
    }

    func testOpenAIIncompleteStopReasonIsPreserved() {
        XCTAssertEqual(
            openAIChatCompletionOutcome(.string("length"), endpointBaseURL: customEndpoint),
            .incomplete(reason: "length")
        )
    }

    func testOpenAIBackedCustomProviderEndTurnReportsSuccessfulCompletion() {
        let customProviderModel = AIModel.customProvider(
            name: "fable",
            provider: "custom",
            model: "fable"
        )
        let endpoint = openAICompletionEndpointBaseURL(
            customEndpoint,
            providerType: customProviderModel.providerType
        )

        XCTAssertEqual(endpoint, customEndpoint)
        XCTAssertEqual(
            openAIChatCompletionOutcome(.string("end_turn"), endpointBaseURL: endpoint),
            .completed
        )
    }

    func testNonOpenAIProviderDoesNotUseOpenAICompletionEndpointPolicy() {
        XCTAssertNil(
            openAICompletionEndpointBaseURL(
                customEndpoint,
                providerType: AIModel.geminiCustom(name: "gemini").providerType
            )
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
