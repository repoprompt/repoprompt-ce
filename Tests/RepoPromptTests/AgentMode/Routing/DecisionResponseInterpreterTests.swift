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

final class OpenAIDecisionsRoutingResponseInterpreterTests: XCTestCase {
    func testAcceptsExactChoiceAndProjectsCompleteProbabilityMap() throws {
        let result = try OpenAIDecisionsRoutingResponseInterpreter().interpret(
            response(answer: #"{"type":"choice","name":"model","choice":"candidate-b","probabilities":[{"value":"candidate-a","probability":0.25},{"value":"candidate-b","probability":0.75}],"confidence":0.8}"#),
            expectedQuestionName: "model",
            submittedChoices: ["candidate-a", "candidate-b"]
        )
        XCTAssertEqual(result, .choice(key: "candidate-b", scores: ["candidate-a": 0.25, "candidate-b": 0.75], confidence: 0.8))
    }

    func testRejectsNonNormalizedProbabilityDistributions() {
        let distributions = [(0.0, 0.0), (0.8, 0.8), (0.5, 0.5002)]
        for (first, second) in distributions {
            let answer = """
            {"type":"choice","name":"model","choice":"a","probabilities":[{"value":"a","probability":\(first)},{"value":"b","probability":\(second)}],"confidence":0.8}
            """
            XCTAssertThrowsError(try OpenAIDecisionsRoutingResponseInterpreter().interpret(
                response(answer: answer), expectedQuestionName: "model", submittedChoices: ["a", "b"]
            )) { error in
                XCTAssertEqual(error as? OpenAIDecisionsRoutingResponseInterpreter.ValidationError, .invalidProbabilities)
            }
        }
        let rounded = """
        {"type":"choice","name":"model","choice":"a","probabilities":[{"value":"a","probability":0.5},{"value":"b","probability":0.50009}],"confidence":0.8}
        """
        XCTAssertNoThrow(try OpenAIDecisionsRoutingResponseInterpreter().interpret(
            response(answer: rounded), expectedQuestionName: "model", submittedChoices: ["a", "b"]
        ))
    }

    func testAcceptsOnlyCorrectlyNamedTypedRefusal() throws {
        let result = try OpenAIDecisionsRoutingResponseInterpreter().interpret(
            response(answer: #"{"type":"refusal","name":"model"}"#),
            expectedQuestionName: "model",
            submittedChoices: ["a", "b"]
        )
        XCTAssertEqual(result, .refusal)
    }

    func testRejectsWrongModelQuestionAndAnswerCount() {
        XCTAssertThrowsError(try OpenAIDecisionsRoutingResponseInterpreter().interpret(
            response(model: "other", answer: choiceAnswer), expectedQuestionName: "model", submittedChoices: ["a", "b"]
        ))
        XCTAssertThrowsError(try OpenAIDecisionsRoutingResponseInterpreter().interpret(
            response(answer: choiceAnswer.replacingOccurrences(of: "model", with: "renamed")), expectedQuestionName: "model", submittedChoices: ["a", "b"]
        ))
        XCTAssertThrowsError(try OpenAIDecisionsRoutingResponseInterpreter().interpret(
            response(answers: "[]"), expectedQuestionName: "model", submittedChoices: ["a", "b"]
        ))
    }

    func testRejectsUnknownDuplicateMissingAndInvalidProbabilityEntries() {
        let invalidAnswers = [
            #"{"type":"choice","name":"model","choice":"unknown","probabilities":[{"value":"a","probability":0.5},{"value":"b","probability":0.5}],"confidence":0.5}"#,
            #"{"type":"choice","name":"model","choice":"a","probabilities":[{"value":"a","probability":0.5},{"value":"a","probability":0.5}],"confidence":0.5}"#,
            #"{"type":"choice","name":"model","choice":"a","probabilities":[{"value":"a","probability":0.5}],"confidence":0.5}"#,
            #"{"type":"choice","name":"model","choice":"a","probabilities":[{"value":"a","probability":1.5},{"value":"b","probability":0.5}],"confidence":0.5}"#
        ]
        for answer in invalidAnswers {
            XCTAssertThrowsError(try OpenAIDecisionsRoutingResponseInterpreter().interpret(
                response(answer: answer), expectedQuestionName: "model", submittedChoices: ["a", "b"]
            ))
        }
    }

    func testRequiresAllUsageFieldsAndRejectsNegativeCounts() {
        let missing = response(model: "gpt-6-luna", answerJSON: choiceAnswer, answersJSON: nil).replacingOccurrences(of: #""input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0}"#, with: "")
        XCTAssertThrowsError(try JSONDecoder().decode(OpenAIDecisionsWireResponse.self, from: Data(missing.utf8)))
        let negative = response(model: "gpt-6-luna", answerJSON: choiceAnswer, answersJSON: nil).replacingOccurrences(of: #""input_tokens":10"#, with: #""input_tokens":-1"#)
        XCTAssertThrowsError(try OpenAIDecisionsRoutingResponseInterpreter().interpret(
            JSONDecoder().decode(OpenAIDecisionsWireResponse.self, from: Data(negative.utf8)),
            expectedQuestionName: "model", submittedChoices: ["a", "b"]
        ))
    }

    func testUnknownAnswerDiscriminatorFailsDecoding() {
        let json = response(
            model: "gpt-6-luna",
            answerJSON: choiceAnswer.replacingOccurrences(of: "choice", with: "score"),
            answersJSON: nil
        )
        XCTAssertThrowsError(try JSONDecoder().decode(OpenAIDecisionsWireResponse.self, from: Data(json.utf8)))
    }

    private var choiceAnswer: String {
        #"{"type":"choice","name":"model","choice":"a","probabilities":[{"value":"a","probability":0.6},{"value":"b","probability":0.4}],"confidence":0.9}"#
    }

    private func response(model: String = "gpt-6-luna", answer: String? = nil, answers: String? = nil) -> OpenAIDecisionsWireResponse {
        // The encoded fixture is decoded through the real wire DTO, preserving strict JSON typing.
        let json = response(model: model, answerJSON: answer ?? choiceAnswer, answersJSON: answers)
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(OpenAIDecisionsWireResponse.self, from: Data(json.utf8))
    }

    private func response(answer: String) -> OpenAIDecisionsWireResponse {
        response(answer: Optional(answer))
    }

    private func response(model: String, answerJSON: String, answersJSON: String?) -> String {
        let answers = answersJSON ?? "[\(answerJSON)]"
        return """
        {"model":"\(model)","answers":\(answers),"usage":{"input_tokens":10,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":0,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":10}}
        """
    }
}
