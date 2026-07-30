@testable import RepoPromptApp
import XCTest

@MainActor
final class ContextBuilderAskUserStateTests: XCTestCase {
    func testTabSessionInitializesWithNoPendingAskUserInteraction() {
        let session = ContextBuilderAgentViewModel.TabSession(tabID: UUID())

        XCTAssertNil(session.pendingAskUser)
        XCTAssertNil(session.askUserContinuation)
        XCTAssertNil(session.pendingAskUserRunID)
        XCTAssertNil(session.askUserTimeoutTask)
        XCTAssertEqual(session.pendingAskUserTimeoutGeneration, 0)
    }

    func testTabSessionStoresStructuredPendingAskUserState() throws {
        let tabID = UUID()
        let interactionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000128"))
        let session = ContextBuilderAgentViewModel.TabSession(tabID: tabID)
        let interaction = AgentAskUserInteraction(
            id: interactionID,
            title: "Clarify selection",
            context: "Context Builder needs one more detail.",
            timeoutSeconds: 30,
            questions: [
                AgentAskUserQuestion(
                    id: "scope",
                    header: "Scope",
                    question: "Which files should be included?",
                    options: [
                        AgentAskUserOption(label: "Changed only"),
                        AgentAskUserOption(label: "All relevant")
                    ],
                    allowsMultiple: false,
                    allowsCustom: false
                ),
                AgentAskUserQuestion(
                    id: "notes",
                    question: "Any extra constraints?",
                    allowsCustom: true
                )
            ]
        )
        try interaction.validate()

        var drafts = interaction.emptyDrafts()
        drafts["scope"] = AgentAskUserDraft(selectedOptionLabels: ["All relevant"])
        let pending = AgentAskUserPendingState(
            interaction: interaction,
            draftsByQuestionID: drafts,
            currentQuestionIndex: 1
        )

        let runID = UUID()
        session.pendingAskUser = pending
        session.pendingAskUserRunID = runID

        let stored = try XCTUnwrap(session.pendingAskUser)
        XCTAssertEqual(session.pendingAskUserRunID, runID)
        XCTAssertEqual(stored.id, interactionID)
        XCTAssertEqual(stored.currentQuestion?.id, "notes")
        XCTAssertEqual(stored.draftsByQuestionID["scope"]?.selectedOptionLabels, ["All relevant"])
        XCTAssertEqual(stored.legacyDiscoveryQuestion?.id, interactionID)
        XCTAssertEqual(stored.legacyDiscoveryQuestion?.question, "Which files should be included?")
    }
}
