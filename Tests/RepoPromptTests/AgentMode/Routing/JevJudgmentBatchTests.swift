import Foundation
@testable import RepoPromptApp
import XCTest

final class JevJudgmentBatchTests: XCTestCase {
    /// The shipped routing policy submits exactly one `route` choice question. This pins the encoded
    /// payload so the batch seam cannot silently change what the router sends.
    func testOneQuestionBatchEncodesTheUnchangedShippedPayload() throws {
        let request = try JevRoutingWireRequest(
            model: JevRouterCredentialService.pinnedModel,
            state: "task",
            questions: batch(questions: [
                .init(id: "route", instructions: "pick", criteria: [
                    .init(opaqueKey: "a", description: "A"),
                    .init(opaqueKey: "b", description: "B")
                ])
            ]).wireQuestions()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try XCTUnwrap(String(data: encoder.encode(request), encoding: .utf8))
        XCTAssertEqual(
            encoded,
            """
            {"model":"\(JevRouterCredentialService.pinnedModel)",\
            "questions":{"route":{"criteria":{"a":"A","b":"B"},"instructions":"pick","type":"choice"}},\
            "state":"task"}
            """
        )
    }

    func testBatchEncodesEveryQuestionIntoTheDocumentedQuestionMap() throws {
        let wire = try batch(questions: [
            .init(id: "model", instructions: "choose model", criteria: [
                .init(opaqueKey: "m1", description: "M1"),
                .init(opaqueKey: "m2", description: "M2")
            ]),
            .init(id: "effort", instructions: "choose effort", criteria: [
                .init(opaqueKey: "e1", description: "E1"),
                .init(opaqueKey: "e2", description: "E2")
            ])
        ]).wireQuestions()
        XCTAssertEqual(Set(wire.keys), ["model", "effort"])
        XCTAssertEqual(wire["model"]?.type, "choice")
        XCTAssertEqual(wire["model"]?.instructions, "choose model")
        XCTAssertEqual(wire["model"]?.criteria, ["m1": "M1", "m2": "M2"])
        XCTAssertEqual(wire["effort"]?.criteria, ["e1": "E1", "e2": "E2"])
    }

    func testSubmittedKeysAreScopedPerQuestion() throws {
        let built = try batch(questions: [
            .init(id: "model", instructions: "m", criteria: [
                .init(opaqueKey: "shared", description: "M1"),
                .init(opaqueKey: "m2", description: "M2")
            ]),
            .init(id: "effort", instructions: "e", criteria: [
                .init(opaqueKey: "shared", description: "E1"),
                .init(opaqueKey: "e2", description: "E2")
            ])
        ])
        XCTAssertEqual(built.questionIDs, ["model", "effort"])
        XCTAssertEqual(built.submittedOpaqueKeysByQuestionID["model"], ["shared", "m2"])
        XCTAssertEqual(built.submittedOpaqueKeysByQuestionID["effort"], ["shared", "e2"])
    }

    func testRejectsStructurallyInvalidBatches() {
        assertBuildError(.noQuestions, questions: [])
        assertBuildError(.emptyQuestionID, questions: [
            .init(id: "", instructions: "i", criteria: [
                .init(opaqueKey: "a", description: "A"),
                .init(opaqueKey: "b", description: "B")
            ])
        ])
        assertBuildError(.duplicateQuestionID("route"), questions: [
            .init(id: "route", instructions: "i", criteria: [
                .init(opaqueKey: "a", description: "A"),
                .init(opaqueKey: "b", description: "B")
            ]),
            .init(id: "route", instructions: "i", criteria: [
                .init(opaqueKey: "c", description: "C"),
                .init(opaqueKey: "d", description: "D")
            ])
        ])
        assertBuildError(.invalidCriteriaCount(questionID: "route"), questions: [
            .init(id: "route", instructions: "i", criteria: [.init(opaqueKey: "a", description: "A")])
        ])
        assertBuildError(.invalidCriteriaCount(questionID: "route"), questions: [
            .init(
                id: "route",
                instructions: "i",
                criteria: (0 ... JevJudgmentBatch.maximumCriteria).map {
                    .init(opaqueKey: "k\($0)", description: "K\($0)")
                }
            )
        ])
        assertBuildError(.emptyCriterionKey(questionID: "route"), questions: [
            .init(id: "route", instructions: "i", criteria: [
                .init(opaqueKey: "", description: "A"),
                .init(opaqueKey: "b", description: "B")
            ])
        ])
        assertBuildError(.duplicateCriterionKey(questionID: "route"), questions: [
            .init(id: "route", instructions: "i", criteria: [
                .init(opaqueKey: "a", description: "A"),
                .init(opaqueKey: "a", description: "B")
            ])
        ])
    }

    private func batch(questions: [JevJudgmentQuestion]) throws -> JevJudgmentBatch {
        try JevJudgmentBatch(questions: questions)
    }

    private func assertBuildError(
        _ expected: JevJudgmentBatch.BuildError,
        questions: [JevJudgmentQuestion],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try JevJudgmentBatch(questions: questions), file: file, line: line) {
            XCTAssertEqual($0 as? JevJudgmentBatch.BuildError, expected, file: file, line: line)
        }
    }
}
