import Foundation
@testable import RepoPromptApp
import XCTest

final class JevRoutingResponseInterpreterTests: XCTestCase {
    func testValidatesConfidenceSeparatelyFromWinningProbability() throws {
        let response = makeResponse(choice: "a", probabilities: ["a": 0.6, "b": 0.4], confidence: 0.9)
        let validated = try JevRoutingResponseInterpreter().validate(response, submittedOpaqueKeys: ["a", "b"])
        XCTAssertEqual(validated.selectedOpaqueKey, "a")
        XCTAssertEqual(validated.probabilities["a"], 0.6)
        XCTAssertEqual(validated.confidence, 0.9)
    }

    func testRejectsUnknownKeysInvalidDistributionAndWrongEvaluator() {
        assertError(.unknownOrMissingCandidates, response: makeResponse(
            choice: "a", probabilities: ["a": 0.6, "unknown": 0.4], confidence: 0.9
        ))
        assertError(.invalidProbability, response: makeResponse(
            choice: "a", probabilities: ["a": 0.9, "b": 0.9], confidence: 0.9
        ))
        var wrong = makeResponse(choice: "a", probabilities: ["a": 0.6, "b": 0.4], confidence: 0.9)
        wrong = .init(model: "moving-alias", answers: wrong.answers, usage: wrong.usage)
        assertError(.wrongEvaluator, response: wrong)
    }

    func testRejectsChoiceThatIsNotUniqueProbabilityArgmax() {
        assertError(.nonUniqueWinningChoice, response: makeResponse(
            choice: "b", probabilities: ["a": 0.6, "b": 0.4], confidence: 0.9
        ))
        assertError(.nonUniqueWinningChoice, response: makeResponse(
            choice: "a", probabilities: ["a": 0.5, "b": 0.5], confidence: 0.9
        ))
    }

    private func assertError(
        _ expected: JevRoutingResponseInterpreter.ValidationError,
        response: JevRoutingWireResponse,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try JevRoutingResponseInterpreter().validate(
            response, submittedOpaqueKeys: ["a", "b"]
        ), file: file, line: line) {
            XCTAssertEqual($0 as? JevRoutingResponseInterpreter.ValidationError, expected, file: file, line: line)
        }
    }

    private func makeResponse(
        choice: String,
        probabilities: [String: Double],
        confidence: Double
    ) -> JevRoutingWireResponse {
        .init(
            model: JevRouterCredentialService.pinnedModel,
            answers: ["route": .init(type: "choice", choice: choice, probabilities: probabilities, confidence: confidence)],
            usage: .init(inputTokens: 10, outputTokens: 2)
        )
    }
}
