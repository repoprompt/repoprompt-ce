@testable import RepoPromptApp
import XCTest

final class AgentAskUserModelsTests: XCTestCase {
    func testValidationRejectsInvalidInteractions() throws {
        XCTAssertThrowsAgentAskUserError(
            try AgentAskUserInteraction(questions: []).validate(),
            .emptyQuestions
        )

        XCTAssertThrowsAgentAskUserError(
            try AgentAskUserInteraction(questions: [
                AgentAskUserQuestion(id: "   ", question: "Choose one")
            ]).validate(),
            .blankQuestionID(index: 0)
        )

        XCTAssertThrowsAgentAskUserError(
            try AgentAskUserInteraction(questions: [
                AgentAskUserQuestion(id: "choice", question: "Choose one"),
                AgentAskUserQuestion(id: "choice", question: "Choose another")
            ]).validate(),
            .duplicateQuestionID("choice")
        )

        XCTAssertThrowsAgentAskUserError(
            try AgentAskUserInteraction(questions: [
                AgentAskUserQuestion(id: "blank", question: " \n\t ")
            ]).validate(),
            .blankQuestionText(id: "blank")
        )

        XCTAssertThrowsAgentAskUserError(
            try AgentAskUserInteraction(questions: [
                AgentAskUserQuestion(
                    id: "dupe-option",
                    question: "Choose one",
                    options: [AgentAskUserOption(label: "A"), AgentAskUserOption(label: "A")],
                    allowsCustom: false
                )
            ]).validate(),
            .duplicateOptionLabel(questionID: "dupe-option", label: "A")
        )

        XCTAssertThrowsAgentAskUserError(
            try AgentAskUserInteraction(questions: [
                AgentAskUserQuestion(id: "impossible", question: "No way out", allowsCustom: false)
            ]).validate(),
            .impossibleQuestion(questionID: "impossible")
        )
    }

    func testSubmittedResponseBuildsStructuredAnswersFromDrafts() throws {
        let interaction = makeInteraction()
        var drafts = interaction.emptyDrafts()
        drafts["single"] = AgentAskUserDraft(selectedOptionLabels: ["Beta"])
        drafts["multiple"] = AgentAskUserDraft(
            selectedOptionLabels: ["Third", "First"],
            customResponse: "  Additional context  "
        )
        drafts["custom"] = AgentAskUserDraft(customResponse: "  Free-form answer  ")
        drafts["skippable"] = AgentAskUserDraft(skipped: true)

        let response = try interaction.buildSubmittedResponse(drafts: drafts, elapsedSeconds: 42)

        XCTAssertFalse(response.timedOut)
        XCTAssertFalse(response.skipped)
        XCTAssertEqual(response.elapsedSeconds, 42)

        let single = try XCTUnwrap(response.answersByQuestionID["single"])
        XCTAssertEqual(single.answers, ["Beta"])
        XCTAssertEqual(single.selectedOptions, ["Beta"])
        XCTAssertNil(single.customResponse)
        XCTAssertFalse(single.skipped)

        let multiple = try XCTUnwrap(response.answersByQuestionID["multiple"])
        XCTAssertEqual(multiple.selectedOptions, ["First", "Third"])
        XCTAssertEqual(multiple.answers, ["First", "Third", "Additional context"])
        XCTAssertEqual(multiple.customResponse, "Additional context")

        let custom = try XCTUnwrap(response.answersByQuestionID["custom"])
        XCTAssertEqual(custom.answers, ["Free-form answer"])
        XCTAssertEqual(custom.selectedOptions, [])
        XCTAssertEqual(custom.customResponse, "Free-form answer")

        let skipped = try XCTUnwrap(response.answersByQuestionID["skippable"])
        XCTAssertTrue(skipped.skipped)
        XCTAssertEqual(skipped.answers, [])
    }

    func testSubmittedResponseRequiresCompleteAnswers() throws {
        let interaction = makeInteraction()
        var drafts = interaction.emptyDrafts()
        drafts["single"] = AgentAskUserDraft(selectedOptionLabels: ["Alpha"])
        drafts["multiple"] = AgentAskUserDraft(selectedOptionLabels: ["First"])
        drafts["custom"] = AgentAskUserDraft(customResponse: "done")
        // Leave skippable unanswered.

        XCTAssertThrowsAgentAskUserError(
            try interaction.buildSubmittedResponse(drafts: drafts, elapsedSeconds: 1),
            .incompleteQuestion("skippable")
        )
    }

    func testTimedOutAndSkippedResponsesCarryExpectedStatus() {
        let interaction = makeInteraction()
        var drafts = interaction.emptyDrafts()
        drafts["single"] = AgentAskUserDraft(selectedOptionLabels: ["Beta"])

        let timedOut = interaction.buildTimedOutResponse(drafts: drafts, elapsedSeconds: 300)
        XCTAssertTrue(timedOut.timedOut)
        XCTAssertFalse(timedOut.skipped)
        XCTAssertEqual(timedOut.elapsedSeconds, 300)
        XCTAssertEqual(timedOut.answersByQuestionID["single"]?.answers, ["Beta"])
        XCTAssertEqual(timedOut.answersByQuestionID["multiple"]?.answers, [])

        let skipped = interaction.buildSkippedResponse(elapsedSeconds: 12)
        XCTAssertFalse(skipped.timedOut)
        XCTAssertTrue(skipped.skipped)
        XCTAssertEqual(skipped.elapsedSeconds, 12)
        XCTAssertTrue(skipped.answersByQuestionID.values.allSatisfy(\.skipped))
    }

    func testStructuredAndFlatAnswersConvertBackToDrafts() throws {
        let interaction = makeInteraction()
        let structuredDrafts = try interaction.drafts(from: [
            "single": AgentAskUserAnswer(
                answers: ["Beta"],
                selectedOptions: ["Beta"],
                customResponse: nil,
                skipped: false
            ),
            "multiple": AgentAskUserAnswer(
                answers: ["First", "Third", "Extra"],
                selectedOptions: ["First", "Third"],
                customResponse: "Extra",
                skipped: false
            ),
            "custom": AgentAskUserAnswer(
                answers: ["Manual"],
                selectedOptions: [],
                customResponse: "Manual",
                skipped: false
            ),
            "skippable": AgentAskUserAnswer(
                answers: [],
                selectedOptions: [],
                customResponse: nil,
                skipped: true
            )
        ])

        XCTAssertEqual(structuredDrafts["single"]?.selectedOptionLabels, ["Beta"])
        XCTAssertEqual(structuredDrafts["multiple"]?.selectedOptionLabels, ["First", "Third"])
        XCTAssertEqual(structuredDrafts["multiple"]?.customResponse, "Extra")
        XCTAssertEqual(structuredDrafts["custom"]?.customResponse, "Manual")
        XCTAssertEqual(structuredDrafts["skippable"]?.skipped, true)

        let flatDrafts = try interaction.drafts(fromFlatAnswers: [
            "single": ["Alpha"],
            "multiple": ["Third", "First", "Legacy note"],
            "custom": ["Legacy free form"],
            "skippable": ["Skip via text"]
        ])

        XCTAssertEqual(flatDrafts["single"]?.selectedOptionLabels, ["Alpha"])
        XCTAssertEqual(flatDrafts["multiple"]?.selectedOptionLabels, ["First", "Third"])
        XCTAssertEqual(flatDrafts["multiple"]?.customResponse, "Legacy note")
        XCTAssertEqual(flatDrafts["custom"]?.customResponse, "Legacy free form")
        XCTAssertEqual(flatDrafts["skippable"]?.customResponse, "Skip via text")
    }

    func testAnswerConversionRejectsUnknownInvalidCustomAndInvalidSingleSelectAnswers() throws {
        let interaction = makeInteraction()

        XCTAssertThrowsAgentAskUserError(
            try interaction.drafts(fromFlatAnswers: ["missing": ["value"]]),
            .unknownQuestionID(id: "missing", validIDs: ["single", "multiple", "custom", "skippable"])
        )

        XCTAssertThrowsAgentAskUserError(
            try interaction.drafts(fromFlatAnswers: ["single": ["Not an option"]]),
            .invalidCustomAnswer(questionID: "single")
        )

        XCTAssertThrowsAgentAskUserError(
            try interaction.drafts(fromFlatAnswers: ["single": ["Alpha", "Beta"]]),
            .invalidSingleSelectAnswer(questionID: "single")
        )

        XCTAssertThrowsAgentAskUserError(
            try interaction.drafts(from: [
                "multiple": AgentAskUserAnswer(
                    answers: [],
                    selectedOptions: ["Not an option"],
                    customResponse: nil,
                    skipped: false
                )
            ]),
            .invalidSelectedOption(questionID: "multiple", label: "Not an option")
        )

        XCTAssertThrowsAgentAskUserError(
            try interaction.drafts(from: [
                "skippable": AgentAskUserAnswer(
                    answers: ["answer"],
                    selectedOptions: [],
                    customResponse: nil,
                    skipped: true
                )
            ]),
            .skippedQuestionHasAnswer(questionID: "skippable")
        )

        XCTAssertThrowsAgentAskUserError(
            try interaction.drafts(from: [
                "multiple": AgentAskUserAnswer(
                    answers: ["Second"],
                    selectedOptions: ["First"],
                    customResponse: nil,
                    skipped: false
                )
            ]),
            .inconsistentStructuredAnswer(questionID: "multiple")
        )
    }

    func testPendingStateTracksCurrentQuestionAndCompleteness() {
        let interaction = makeInteraction()
        var pending = AgentAskUserPendingState(interaction: interaction, currentQuestionIndex: 1)

        XCTAssertEqual(pending.id, interaction.id)
        XCTAssertEqual(pending.currentQuestion?.id, "multiple")
        XCTAssertFalse(pending.isComplete)

        pending.draftsByQuestionID["single"] = AgentAskUserDraft(selectedOptionLabels: ["Alpha", "Beta"])
        pending.draftsByQuestionID["multiple"] = AgentAskUserDraft(selectedOptionLabels: ["First"])
        pending.draftsByQuestionID["custom"] = AgentAskUserDraft(customResponse: "Done")
        pending.draftsByQuestionID["skippable"] = AgentAskUserDraft(skipped: true)
        XCTAssertFalse(pending.isComplete)

        pending.draftsByQuestionID["single"] = AgentAskUserDraft(selectedOptionLabels: ["Alpha"])
        pending.draftsByQuestionID["multiple"] = AgentAskUserDraft(selectedOptionLabels: ["First"])
        pending.draftsByQuestionID["custom"] = AgentAskUserDraft(customResponse: "Done")
        pending.draftsByQuestionID["skippable"] = AgentAskUserDraft(skipped: true)

        XCTAssertTrue(pending.isComplete)
    }

    func testJsonObjectUsesStructuredResponseShape() throws {
        let answer = AgentAskUserAnswer(
            answers: ["First", "Details"],
            selectedOptions: ["First"],
            customResponse: "Details",
            skipped: false
        )
        let answerJSON = answer.jsonObject
        XCTAssertEqual(answerJSON["answers"] as? [String], ["First", "Details"])
        XCTAssertEqual(answerJSON["selected_options"] as? [String], ["First"])
        XCTAssertEqual(answerJSON["custom_response"] as? String, "Details")
        XCTAssertEqual(answerJSON["skipped"] as? Bool, false)

        let response = AgentAskUserResponse(
            answersByQuestionID: ["question": answer],
            timedOut: false,
            skipped: false,
            elapsedSeconds: 5
        )
        let responseJSON = response.jsonObject
        XCTAssertEqual(responseJSON["timed_out"] as? Bool, false)
        XCTAssertEqual(responseJSON["skipped"] as? Bool, false)
        XCTAssertEqual(responseJSON["elapsed_seconds"] as? Int, 5)
        let answers = try XCTUnwrap(responseJSON["answers"] as? [String: [String: Any]])
        XCTAssertEqual(answers["question"]?["answers"] as? [String], ["First", "Details"])
    }

    private func makeInteraction() -> AgentAskUserInteraction {
        AgentAskUserInteraction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "Clarify task",
            context: "Need more input",
            timeoutSeconds: 120,
            questions: [
                AgentAskUserQuestion(
                    id: "single",
                    question: "Choose one",
                    options: [AgentAskUserOption(label: "Alpha"), AgentAskUserOption(label: "Beta")],
                    allowsCustom: false
                ),
                AgentAskUserQuestion(
                    id: "multiple",
                    question: "Choose multiple",
                    options: [
                        AgentAskUserOption(label: "First"),
                        AgentAskUserOption(label: "Second"),
                        AgentAskUserOption(label: "Third")
                    ],
                    allowsMultiple: true,
                    allowsCustom: true
                ),
                AgentAskUserQuestion(id: "custom", question: "Describe it", allowsCustom: true),
                AgentAskUserQuestion(id: "skippable", question: "Optional note", allowsCustom: true)
            ]
        )
    }

    private func XCTAssertThrowsAgentAskUserError(
        _ expression: @autoclosure () throws -> some Any,
        _ expectedError: AgentAskUserValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? AgentAskUserValidationError, expectedError, file: file, line: line)
        }
    }
}
