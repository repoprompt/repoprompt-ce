import Foundation
@testable import RepoPromptApp
import XCTest

final class JevRoutingResponseInterpreterTests: XCTestCase {
    // MARK: - Single-question behavior (the shipped routing policy)

    func testValidatesConfidenceSeparatelyFromWinningProbability() throws {
        let response = makeResponse(answers: [
            "route": answer(choice: "a", probabilities: ["a": 0.6, "b": 0.4], confidence: 0.9)
        ])
        let validated = try JevRoutingResponseInterpreter().validate(response, batch: routeBatch())
        let route = try XCTUnwrap(validated.answer(forQuestionID: "route"))
        XCTAssertEqual(route.selectedOpaqueKey, "a")
        XCTAssertEqual(route.probabilities["a"], 0.6)
        XCTAssertEqual(route.confidence, 0.9)
        XCTAssertEqual(validated.inputTokens, 10)
        XCTAssertEqual(validated.outputTokens, 2)
    }

    func testRejectsUnknownKeysInvalidDistributionAndWrongEvaluator() {
        assertRouteError(.unknownOrMissingCandidates, answer: answer(
            choice: "a", probabilities: ["a": 0.6, "unknown": 0.4], confidence: 0.9
        ))
        assertRouteError(.invalidProbability, answer: answer(
            choice: "a", probabilities: ["a": 0.9, "b": 0.9], confidence: 0.9
        ))
        var wrong = makeResponse(answers: [
            "route": answer(choice: "a", probabilities: ["a": 0.6, "b": 0.4], confidence: 0.9)
        ])
        wrong = .init(model: "moving-alias", answers: wrong.answers, usage: wrong.usage)
        assertError(.wrongEvaluator, response: wrong, batch: routeBatch())
    }

    func testRejectsChoiceThatIsNotUniqueProbabilityArgmax() {
        assertRouteError(.nonUniqueWinningChoice, answer: answer(
            choice: "b", probabilities: ["a": 0.6, "b": 0.4], confidence: 0.9
        ))
        assertRouteError(.nonUniqueWinningChoice, answer: answer(
            choice: "a", probabilities: ["a": 0.5, "b": 0.5], confidence: 0.9
        ))
    }

    func testRejectsInvalidConfidenceAndNegativeUsage() {
        assertRouteError(.invalidConfidence, answer: answer(
            choice: "a", probabilities: ["a": 0.6, "b": 0.4], confidence: 1.5
        ))
        let negativeUsage = JevRoutingWireResponse(
            model: JevRouterCredentialService.pinnedModel,
            answers: ["route": answer(choice: "a", probabilities: ["a": 0.6, "b": 0.4], confidence: 0.9)],
            usage: .init(inputTokens: -1, outputTokens: 2)
        )
        assertError(.invalidUsage, response: negativeUsage, batch: routeBatch())
    }

    /// Exact-coverage enforcement applies to the shipped one-question policy too, not only batches.
    func testRejectsMissingOrUnexpectedAnswersForTheShippedRouteQuestion() {
        assertError(
            .missingAnswer(questionID: "route"),
            response: makeResponse(answers: [:]),
            batch: routeBatch()
        )
        assertError(
            .unexpectedAnswer(questionID: "effort"),
            response: makeResponse(answers: [
                "route": answer(choice: "a", probabilities: ["a": 0.6, "b": 0.4], confidence: 0.9),
                "effort": answer(choice: "a", probabilities: ["a": 0.6, "b": 0.4], confidence: 0.9)
            ]),
            batch: routeBatch()
        )
        // A renamed answer key is an unexpected answer, never a silently accepted substitute.
        assertError(
            .unexpectedAnswer(questionID: "rout"),
            response: makeResponse(answers: [
                "rout": answer(choice: "a", probabilities: ["a": 0.6, "b": 0.4], confidence: 0.9)
            ]),
            batch: routeBatch()
        )
    }

    // MARK: - Batch validation

    func testValidatesEverySubmittedQuestionIndependently() throws {
        let response = makeResponse(answers: [
            "model": answer(choice: "m2", probabilities: ["m1": 0.3, "m2": 0.7], confidence: 0.8),
            "effort": answer(choice: "e1", probabilities: ["e1": 0.9, "e2": 0.1], confidence: 0.6)
        ])
        let validated = try JevRoutingResponseInterpreter().validate(response, batch: twoQuestionBatch())
        XCTAssertEqual(validated.answersByQuestionID.count, 2)
        let model = try XCTUnwrap(validated.answer(forQuestionID: "model"))
        let effort = try XCTUnwrap(validated.answer(forQuestionID: "effort"))
        XCTAssertEqual(model.selectedOpaqueKey, "m2")
        XCTAssertEqual(model.confidence, 0.8)
        XCTAssertEqual(effort.selectedOpaqueKey, "e1")
        XCTAssertEqual(effort.probabilities, ["e1": 0.9, "e2": 0.1])
        XCTAssertNil(validated.answer(forQuestionID: "route"))
    }

    func testRejectsMissingAnswerForASubmittedQuestion() {
        let response = makeResponse(answers: [
            "model": answer(choice: "m2", probabilities: ["m1": 0.3, "m2": 0.7], confidence: 0.8)
        ])
        assertError(.missingAnswer(questionID: "effort"), response: response, batch: twoQuestionBatch())
    }

    func testRejectsAnswerForAQuestionThatWasNotSubmitted() {
        let response = makeResponse(answers: [
            "model": answer(choice: "m2", probabilities: ["m1": 0.3, "m2": 0.7], confidence: 0.8),
            "effort": answer(choice: "e1", probabilities: ["e1": 0.9, "e2": 0.1], confidence: 0.6),
            "smuggled": answer(choice: "e1", probabilities: ["e1": 0.9, "e2": 0.1], confidence: 0.6)
        ])
        assertError(.unexpectedAnswer(questionID: "smuggled"), response: response, batch: twoQuestionBatch())
    }

    /// A sibling question's opaque key is rejected exactly like an unknown key, so batching cannot
    /// let one decision be answered with another decision's candidates.
    func testRejectsCrossQuestionOpaqueKeyBleed() {
        let bledProbabilities = makeResponse(answers: [
            "model": answer(choice: "m2", probabilities: ["m1": 0.3, "m2": 0.7], confidence: 0.8),
            "effort": answer(choice: "e1", probabilities: ["e1": 0.9, "m1": 0.1], confidence: 0.6)
        ])
        assertError(.unknownOrMissingCandidates, response: bledProbabilities, batch: twoQuestionBatch())

        let bledChoice = makeResponse(answers: [
            "model": answer(choice: "m2", probabilities: ["m1": 0.3, "m2": 0.7], confidence: 0.8),
            "effort": answer(choice: "m1", probabilities: ["e1": 0.9, "e2": 0.1], confidence: 0.6)
        ])
        assertError(.wrongAnswerShape, response: bledChoice, batch: twoQuestionBatch())
    }

    /// Opaque keys are scoped per question, so the same key in two questions is legitimate.
    func testAcceptsRepeatedOpaqueKeysAcrossDistinctQuestions() throws {
        let batch = try JevJudgmentBatch(questions: [
            .init(id: "first", instructions: "first", criteria: [
                .init(opaqueKey: "shared", description: "a"),
                .init(opaqueKey: "other", description: "b")
            ]),
            .init(id: "second", instructions: "second", criteria: [
                .init(opaqueKey: "shared", description: "c"),
                .init(opaqueKey: "different", description: "d")
            ])
        ])
        let response = makeResponse(answers: [
            "first": answer(choice: "shared", probabilities: ["shared": 0.7, "other": 0.3], confidence: 0.5),
            "second": answer(choice: "different", probabilities: ["shared": 0.2, "different": 0.8], confidence: 0.5)
        ])
        let validated = try JevRoutingResponseInterpreter().validate(response, batch: batch)
        XCTAssertEqual(validated.answer(forQuestionID: "first")?.selectedOpaqueKey, "shared")
        XCTAssertEqual(validated.answer(forQuestionID: "second")?.selectedOpaqueKey, "different")
    }

    // MARK: - Helpers

    private func routeBatch() -> JevJudgmentBatch {
        // swiftlint:disable:next force_try
        try! JevJudgmentBatch(questions: [
            .init(id: "route", instructions: "route", criteria: [
                .init(opaqueKey: "a", description: "a"),
                .init(opaqueKey: "b", description: "b")
            ])
        ])
    }

    private func twoQuestionBatch() -> JevJudgmentBatch {
        // swiftlint:disable:next force_try
        try! JevJudgmentBatch(questions: [
            .init(id: "model", instructions: "model", criteria: [
                .init(opaqueKey: "m1", description: "m1"),
                .init(opaqueKey: "m2", description: "m2")
            ]),
            .init(id: "effort", instructions: "effort", criteria: [
                .init(opaqueKey: "e1", description: "e1"),
                .init(opaqueKey: "e2", description: "e2")
            ])
        ])
    }

    private func assertRouteError(
        _ expected: JevRoutingResponseInterpreter.ValidationError,
        answer: JevRoutingWireResponse.Answer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertError(
            expected,
            response: makeResponse(answers: ["route": answer]),
            batch: routeBatch(),
            file: file,
            line: line
        )
    }

    private func assertError(
        _ expected: JevRoutingResponseInterpreter.ValidationError,
        response: JevRoutingWireResponse,
        batch: JevJudgmentBatch,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try JevRoutingResponseInterpreter().validate(response, batch: batch),
            file: file,
            line: line
        ) {
            XCTAssertEqual($0 as? JevRoutingResponseInterpreter.ValidationError, expected, file: file, line: line)
        }
    }

    private func answer(
        choice: String,
        probabilities: [String: Double],
        confidence: Double
    ) -> JevRoutingWireResponse.Answer {
        .init(type: "choice", choice: choice, probabilities: probabilities, confidence: confidence)
    }

    private func makeResponse(
        answers: [String: JevRoutingWireResponse.Answer]
    ) -> JevRoutingWireResponse {
        .init(
            model: JevRouterCredentialService.pinnedModel,
            answers: answers,
            usage: .init(inputTokens: 10, outputTokens: 2)
        )
    }
}
