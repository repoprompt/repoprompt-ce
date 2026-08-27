import Foundation
@testable import RepoPromptApp
import SwiftOpenAI
import XCTest

final class ProviderStreamCompletionTests: XCTestCase {
    private let officialEndpoint = URL(string: "https://api.openai.com")!
    private let officialSubdomainEndpoint = URL(string: "https://gateway.openai.com")!
    private let customEndpoint = URL(string: "http://localhost:11434")!

    func testOpenAIEndpointOwnershipClassification() throws {
        XCTAssertTrue(OpenAIURLHelper.isOpenAIOwnedEndpoint(nil))
        XCTAssertTrue(OpenAIURLHelper.isOpenAIOwnedEndpoint(officialEndpoint))
        XCTAssertTrue(OpenAIURLHelper.isOpenAIOwnedEndpoint(officialSubdomainEndpoint))
        XCTAssertFalse(OpenAIURLHelper.isOpenAIOwnedEndpoint(customEndpoint))
        XCTAssertFalse(try OpenAIURLHelper.isOpenAIOwnedEndpoint(XCTUnwrap(URL(string: "https://evilopenai.com"))))
    }

    func testOpenAIStopReasonReportsSuccessfulCompletion() {
        XCTAssertEqual(
            openAIChatCompletionOutcome(.string("stop"), endpointBaseURL: nil),
            .completed
        )
        XCTAssertEqual(
            openAIChatCompletionOutcome(.string("stop"), endpointBaseURL: customEndpoint),
            .completed
        )
        XCTAssertNil(openAIChatCompletionOutcome(nil, endpointBaseURL: customEndpoint))
    }

    func testCustomEndpointEndTurnReportsSuccessfulCompletion() {
        XCTAssertEqual(
            openAIChatCompletionOutcome(.string("end_turn"), endpointBaseURL: customEndpoint),
            .completed
        )
    }

    func testOfficialEndpointEndTurnRemainsIncomplete() {
        XCTAssertEqual(
            openAIChatCompletionOutcome(.string("end_turn"), endpointBaseURL: nil),
            .incomplete(reason: "end_turn")
        )
        XCTAssertEqual(
            openAIChatCompletionOutcome(.string("end_turn"), endpointBaseURL: officialEndpoint),
            .incomplete(reason: "end_turn")
        )
    }

    func testOpenAIIncompleteStopReasonIsPreserved() {
        XCTAssertEqual(
            openAIChatCompletionOutcome(.string("length"), endpointBaseURL: nil),
            .incomplete(reason: "length")
        )
        XCTAssertEqual(
            openAIChatCompletionOutcome(.string("length"), endpointBaseURL: customEndpoint),
            .incomplete(reason: "length")
        )
    }

    func testStreamedChatCompletionTerminalResultUsesEndpointAwareOutcome() throws {
        let customTerminal = try XCTUnwrap(
            openAIChatCompletionTerminalResult(
                finishReason: .string("end_turn"),
                endpointBaseURL: customEndpoint,
                promptTokens: 7,
                completionTokens: 11
            )
        )
        XCTAssertEqual(customTerminal.type, "message_stop")
        XCTAssertEqual(customTerminal.promptTokens, 7)
        XCTAssertEqual(customTerminal.completionTokens, 11)
        XCTAssertNil(customTerminal.stopReason)

        let officialTerminal = try XCTUnwrap(
            openAIChatCompletionTerminalResult(
                finishReason: .string("end_turn"),
                endpointBaseURL: nil,
                promptTokens: 13,
                completionTokens: 17
            )
        )
        XCTAssertEqual(officialTerminal.type, AIStreamResult.incompleteType)
        XCTAssertEqual(officialTerminal.stopReason, "end_turn")
        XCTAssertEqual(officialTerminal.promptTokens, 13)
        XCTAssertEqual(officialTerminal.completionTokens, 17)

        XCTAssertNil(
            openAIChatCompletionTerminalResult(
                finishReason: nil,
                endpointBaseURL: customEndpoint,
                promptTokens: nil,
                completionTokens: nil
            )
        )
    }

    func testNonStreamedChatCompletionResultUsesEndpointAwareOutcome() {
        let customResult = openAIChatCompletionResult(
            text: "done",
            promptTokens: 3,
            completionTokens: 5,
            finishReason: .string("end_turn"),
            endpointBaseURL: customEndpoint
        )
        XCTAssertEqual(customResult.text, "done")
        XCTAssertEqual(customResult.promptTokens, 3)
        XCTAssertEqual(customResult.completionTokens, 5)
        XCTAssertEqual(customResult.completionOutcome, .completed)

        let officialResult = openAIChatCompletionResult(
            text: "done",
            promptTokens: nil,
            completionTokens: nil,
            finishReason: .string("end_turn"),
            endpointBaseURL: officialEndpoint
        )
        XCTAssertEqual(officialResult.completionOutcome, .incomplete(reason: "end_turn"))

        let lengthResult = openAIChatCompletionResult(
            text: "partial",
            promptTokens: nil,
            completionTokens: nil,
            finishReason: .string("length"),
            endpointBaseURL: customEndpoint
        )
        XCTAssertEqual(lengthResult.completionOutcome, .incomplete(reason: "length"))

        let missingFinishReasonResult = openAIChatCompletionResult(
            text: "unknown",
            promptTokens: nil,
            completionTokens: nil,
            finishReason: nil,
            endpointBaseURL: customEndpoint
        )
        XCTAssertEqual(missingFinishReasonResult.completionOutcome, .incomplete(reason: "missing_finish_reason"))
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
