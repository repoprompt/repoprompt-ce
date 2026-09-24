@testable import RepoPromptApp
import XCTest

final class AutoEffortPolicyTests: XCTestCase {
    func testMCPAdmissionAllowsSettledFollowUpsButPreservesFirstStartAndActiveSteering() {
        XCTAssertTrue(AutoEffortModelPolicy.shouldJudgeMCPUserTurn(
            isEnabled: true,
            startsNewRun: true,
            hasPriorUserTurn: true,
            isNativePreparedTurn: false
        ))
        XCTAssertFalse(AutoEffortModelPolicy.shouldJudgeMCPUserTurn(
            isEnabled: true,
            startsNewRun: true,
            hasPriorUserTurn: false,
            isNativePreparedTurn: false
        ))
        XCTAssertFalse(AutoEffortModelPolicy.shouldJudgeMCPUserTurn(
            isEnabled: true,
            startsNewRun: true,
            hasPriorUserTurn: false,
            isNativePreparedTurn: false
        ))
        XCTAssertFalse(AutoEffortModelPolicy.shouldJudgeMCPUserTurn(
            isEnabled: true,
            startsNewRun: false,
            hasPriorUserTurn: true,
            isNativePreparedTurn: false
        ))
        XCTAssertFalse(AutoEffortModelPolicy.shouldJudgeMCPUserTurn(
            isEnabled: true,
            startsNewRun: true,
            hasPriorUserTurn: true,
            isNativePreparedTurn: true
        ))
        XCTAssertFalse(AutoEffortModelPolicy.shouldJudgeMCPUserTurn(
            isEnabled: false,
            startsNewRun: true,
            hasPriorUserTurn: true,
            isNativePreparedTurn: false
        ))
    }

    func testTurnFeedbackTracksBothEffortDirectionsWithoutChangingManualSelection() {
        let high = AutoEffortTurnSelection(
            provider: .codexExec,
            selectedModelRaw: "gpt-6-sol-low",
            manualEffortRaw: "low",
            effortRaw: "high"
        )
        let first = AutoEffortTurnFeedback(selection: high, previous: nil)
        XCTAssertEqual(first.direction, .up)
        XCTAssertEqual(first.effortRaw, "high")
        XCTAssertEqual(high.manualEffortRaw, "low")

        let low = AutoEffortTurnSelection(
            provider: .codexExec,
            selectedModelRaw: "gpt-6-sol-low",
            manualEffortRaw: "low",
            effortRaw: "low"
        )
        XCTAssertEqual(AutoEffortTurnFeedback(selection: low, previous: first).direction, .down)
        XCTAssertEqual(AutoEffortTurnFeedback(selection: low, previous: nil).direction, .unchanged)
        XCTAssertEqual(AutoEffortTurnFeedback(selection: high, previous: .init(
            selection: .init(provider: .codexExec, selectedModelRaw: "gpt-6-sol-low", manualEffortRaw: "minimal", effortRaw: "minimal"),
            previous: nil
        )).direction, .unknown)
        XCTAssertEqual(AutoEffortTurnFeedback(selection: low, previous: .init(
            selection: .init(provider: .claudeCode, selectedModelRaw: "claude-opus-5-5", manualEffortRaw: "high", effortRaw: "high"),
            previous: nil
        )).direction, .unchanged)
    }

    func testCodexAdmissionRequiresExactFamilyAndAdvertisedEfforts() {
        XCTAssertEqual(
            AutoEffortModelPolicy.codexEfforts(
                modelRaw: "gpt-6-astra-high",
                advertised: [.none, .low, .medium, .high, .ultra]
            ),
            ["low", "medium", "high"]
        )
        XCTAssertTrue(AutoEffortModelPolicy.codexEfforts(
            modelRaw: "gpt-5.6-sol",
            advertised: [.low, .medium, .high]
        ).isEmpty)
        XCTAssertTrue(AutoEffortModelPolicy.codexEfforts(
            modelRaw: "default",
            advertised: [.low, .medium]
        ).isEmpty)
    }

    func testClaudeAdmissionRejectsAliasAndOlderModel() {
        XCTAssertEqual(
            AutoEffortModelPolicy.claudeEfforts(
                modelRaw: "claude-opus-5-5:high",
                advertised: [.max, .high, .low]
            ),
            ["low", "high", "max"]
        )
        XCTAssertTrue(AutoEffortModelPolicy.claudeEfforts(
            modelRaw: "opus",
            advertised: [.low, .medium, .high]
        ).isEmpty)
        XCTAssertTrue(AutoEffortModelPolicy.claudeEfforts(
            modelRaw: "claude-opus-4-7",
            advertised: [.low, .medium, .high]
        ).isEmpty)
    }

    func testWorkflowAdmissionKeepsCustomTemplateLocal() {
        XCTAssertTrue(AutoEffortModelPolicy.shouldJudgeWorkflow(nil))
        XCTAssertTrue(AutoEffortModelPolicy.shouldJudgeWorkflow(.init(builtIn: .review)))
        XCTAssertFalse(AutoEffortModelPolicy.shouldJudgeWorkflow(.init(
            customID: UUID(),
            displayName: "Private review",
            template: "Inspect internal customer data"
        )))
    }

    func testEphemeralChoiceRejectsToggleModelAndManualEffortChanges() {
        let selection = AutoEffortTurnSelection(
            provider: .codexExec,
            selectedModelRaw: "gpt-6-sol",
            manualEffortRaw: "medium",
            effortRaw: "low"
        )
        XCTAssertTrue(selection.isCurrent(
            provider: .codexExec,
            selectedModelRaw: "gpt-6-sol",
            manualEffortRaw: "medium",
            enabled: true
        ))
        XCTAssertFalse(selection.isCurrent(
            provider: .codexExec,
            selectedModelRaw: "gpt-6-sol",
            manualEffortRaw: "high",
            enabled: true
        ))
        XCTAssertFalse(selection.isCurrent(
            provider: .claudeCode,
            selectedModelRaw: "gpt-6-sol",
            manualEffortRaw: "medium",
            enabled: true
        ))
        XCTAssertFalse(selection.isCurrent(
            provider: .codexExec,
            selectedModelRaw: "gpt-6-sol",
            manualEffortRaw: "medium",
            enabled: false
        ))
    }

    func testJevPolicyHasOnlyEffortQuestionAndRejectsInvalidChoices() {
        let batch = JevAutoEffortJudge.batch(efforts: ["low", "medium", "high"])
        XCTAssertEqual(batch?.questionIDs, ["effort"])
        XCTAssertEqual(batch?.wireQuestions()["effort"]?.criteria.keys.sorted(), ["high", "low", "medium"])
        XCTAssertNil(JevAutoEffortJudge.batch(efforts: ["low"]))
        XCTAssertNil(JevAutoEffortJudge.batch(efforts: ["low", "low"]))
        XCTAssertNil(JevAutoEffortJudge.batch(efforts: ["low", "ultra"]))
    }

    func testJevWireRequestUsesOnlyMaskedCurrentTurnAndFixedModel() async throws {
        let client = CapturingAutoEffortJevClient()
        let credentials = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend(values: [.jevRouterAPIKey: "stored"])),
            client: client
        )
        guard case .saved = await credentials.validateStoredKey(operationID: UUID()) else {
            return XCTFail("Stored Jev key did not validate")
        }
        let masked = try XCTUnwrap(AutoEffortTaskSummary.make(from: "Review login password=private123"))
        let chosen = await JevAutoEffortJudge(credentials: credentials).chooseEffort(
            maskedTaskExcerpt: masked,
            selectedModelID: "gpt-6-sol",
            builtInWorkflow: nil,
            efforts: ["low", "medium"]
        )
        XCTAssertEqual(chosen, "medium")
        let request = await client.lastRequest
        XCTAssertEqual(request?.model, JevRouterCredentialService.pinnedModel)
        XCTAssertEqual(
            request?.state,
            "SELECTED_MODEL_ID:\ngpt-6-sol\n\nMASKED_CURRENT_USER_TURN_EXCERPT:\n\(masked)"
        )
        XCTAssertFalse(request?.state.contains("private123") == true)
        XCTAssertEqual(request.map { Set($0.questions.keys) }, Set(["effort"]))
    }

    func testJevWireRequestIncludesOnlyFixedBuiltInWorkflowCategory() async {
        let client = CapturingAutoEffortJevClient()
        let credentials = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend(values: [.jevRouterAPIKey: "stored"])),
            client: client
        )
        guard case .saved = await credentials.validateStoredKey(operationID: UUID()) else {
            return XCTFail("Stored Jev key did not validate")
        }
        let chosen = await JevAutoEffortJudge(credentials: credentials).chooseEffort(
            maskedTaskExcerpt: "Check the change",
            selectedModelID: "gpt-6-sol",
            builtInWorkflow: .review,
            efforts: ["low", "medium"]
        )
        XCTAssertEqual(chosen, "medium")
        let request = await client.lastRequest
        XCTAssertEqual(
            request?.state,
            "SELECTED_MODEL_ID:\ngpt-6-sol\n\nBUILT_IN_WORKFLOW_CATEGORY:\nreview\n\nMASKED_CURRENT_USER_TURN_EXCERPT:\nCheck the change"
        )
    }
}

private actor CapturingAutoEffortJevClient: JevRoutingClientProtocol {
    private(set) var lastRequest: JevRoutingWireRequest?

    func listModels(apiKey: String, timeout: Duration) -> JevModelList {
        .init(models: [.init(name: "jev-latest")])
    }

    func judge(
        request: JevRoutingWireRequest,
        apiKey: String,
        timeout: Duration
    ) -> JevRoutingWireResponse {
        lastRequest = request
        return .init(
            model: JevRouterCredentialService.pinnedModel,
            answers: [
                "effort": .init(
                    type: "choice",
                    choice: "medium",
                    probabilities: ["low": 0.2, "medium": 0.8],
                    confidence: 0.8
                )
            ],
            usage: .init(inputTokens: 12, outputTokens: 4)
        )
    }
}
