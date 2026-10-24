import Foundation
@testable import RepoPromptApp
import RepoPromptSecureStorage
import XCTest

final class AutoEffortPolicyTests: XCTestCase {
    func testMCPAdmissionAllowsFirstStartsAndSettledFollowUpsButPreservesRoutedInitialEffort() {
        XCTAssertTrue(AutoEffortModelPolicy.shouldJudgeMCPUserTurn(
            isEnabled: true,
            startsNewRun: true,
            hasPriorUserTurn: true,
            isNativePreparedTurn: false
        ))
        XCTAssertTrue(AutoEffortModelPolicy.shouldJudgeMCPUserTurn(
            isEnabled: true,
            startsNewRun: true,
            hasPriorUserTurn: false,
            isNativePreparedTurn: false
        ))
        XCTAssertFalse(AutoEffortModelPolicy.shouldJudgeMCPUserTurn(
            isEnabled: true,
            startsNewRun: true,
            hasPriorUserTurn: false,
            isNativePreparedTurn: false,
            preserveRoutedInitialEffort: true
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
            effortRaw: "high",
            backendID: .jev,
            autoEffortRevision: 0
        )
        let first = AutoEffortTurnFeedback(selection: high, previous: nil)
        XCTAssertEqual(first.direction, .up)
        XCTAssertEqual(first.effortRaw, "high")
        XCTAssertEqual(high.manualEffortRaw, "low")

        let ultra = AutoEffortTurnSelection(
            provider: .codexExec,
            selectedModelRaw: "gpt-6-sol-low",
            manualEffortRaw: "low",
            effortRaw: "ultra",
            backendID: .jev,
            autoEffortRevision: 0
        )
        let ultraFeedback = AutoEffortTurnFeedback(selection: ultra, previous: first)
        XCTAssertEqual(ultraFeedback.effortRaw, "ultra")
        XCTAssertEqual(ultraFeedback.direction, .up)
        XCTAssertEqual(AutoEffortTurnFeedback(selection: high, previous: ultraFeedback).direction, .down)

        let low = AutoEffortTurnSelection(
            provider: .codexExec,
            selectedModelRaw: "gpt-6-sol-low",
            manualEffortRaw: "low",
            effortRaw: "low",
            backendID: .jev,
            autoEffortRevision: 0
        )
        XCTAssertEqual(AutoEffortTurnFeedback(selection: low, previous: first).direction, .down)
        XCTAssertEqual(AutoEffortTurnFeedback(selection: low, previous: nil).direction, .unchanged)
        XCTAssertEqual(AutoEffortTurnFeedback(selection: high, previous: .init(
            selection: .init(provider: .codexExec, selectedModelRaw: "gpt-6-sol-low", manualEffortRaw: "minimal", effortRaw: "minimal", backendID: .jev, autoEffortRevision: 0),
            previous: nil
        )).direction, .unknown)
        XCTAssertEqual(AutoEffortTurnFeedback(selection: low, previous: .init(
            selection: .init(provider: .claudeCode, selectedModelRaw: "claude-opus-5-5", manualEffortRaw: "high", effortRaw: "high", backendID: .jev, autoEffortRevision: 0),
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
            effortRaw: "low",
            backendID: .jev,
            autoEffortRevision: 0
        )
        XCTAssertTrue(selection.isCurrent(
            provider: .codexExec,
            selectedModelRaw: "gpt-6-sol",
            manualEffortRaw: "medium",
            configuration: .init(enabled: true, selectedBackendRawValue: nil, revision: 0)
        ))
        XCTAssertFalse(selection.isCurrent(
            provider: .codexExec,
            selectedModelRaw: "gpt-6-sol",
            manualEffortRaw: "high",
            configuration: .init(enabled: true, selectedBackendRawValue: nil, revision: 0)
        ))
        XCTAssertFalse(selection.isCurrent(
            provider: .claudeCode,
            selectedModelRaw: "gpt-6-sol",
            manualEffortRaw: "medium",
            configuration: .init(enabled: true, selectedBackendRawValue: nil, revision: 0)
        ))
        XCTAssertFalse(selection.isCurrent(
            provider: .codexExec,
            selectedModelRaw: "gpt-6-sol",
            manualEffortRaw: "medium",
            configuration: .init(enabled: false, selectedBackendRawValue: nil, revision: 0)
        ))
        XCTAssertFalse(selection.isCurrent(
            provider: .codexExec,
            selectedModelRaw: "gpt-6-sol",
            manualEffortRaw: "medium",
            configuration: .init(enabled: true, selectedBackendRawValue: "openai-decisions", revision: 0)
        ))
        XCTAssertFalse(selection.isCurrent(
            provider: .codexExec,
            selectedModelRaw: "gpt-6-sol",
            manualEffortRaw: "medium",
            configuration: .init(enabled: true, selectedBackendRawValue: nil, revision: 1)
        ))
    }

    func testGenericPolicyHasOnlyEffortQuestionAndRejectsInvalidChoices() throws {
        let capabilities = JevDecisionService(credentialService: JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )).capabilities
        let policy = AutoEffortDecisionPolicy()
        let prepared = try policy.build(
            requestID: UUID(), maskedTaskExcerpt: "Review the change", selectedModelID: "gpt-6-sol",
            builtInWorkflow: nil, efforts: ["low", "medium", "high"], capabilities: capabilities
        )
        XCTAssertEqual(prepared.request.consumerID, .autoEffort)
        XCTAssertEqual(prepared.request.question.name, "effort")
        XCTAssertEqual(prepared.request.question.choices.map(\.opaqueKey), ["effort-0", "effort-1", "effort-2"])
        XCTAssertEqual(prepared.effort(for: .selected(opaqueKey: "effort-1", evidence: nil)), "medium")
        XCTAssertNil(prepared.effort(for: .selected(opaqueKey: "medium", evidence: nil)))
        XCTAssertThrowsError(try policy.build(
            requestID: UUID(), maskedTaskExcerpt: "Review", selectedModelID: "gpt-6-sol",
            builtInWorkflow: nil, efforts: ["low"], capabilities: capabilities
        ))
        XCTAssertThrowsError(try policy.build(
            requestID: UUID(), maskedTaskExcerpt: "Review", selectedModelID: "gpt-6-sol",
            builtInWorkflow: nil, efforts: ["low", "low"], capabilities: capabilities
        ))
    }

    func testGenericPolicyKeepsPrivacyEnvelopeAndManualFallbackLocal() throws {
        let service = JevDecisionService(credentialService: JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend())
        ))
        let masked = try XCTUnwrap(AutoEffortTaskSummary.make(from: "Review login password=private123 /Users/alice/work"))
        let prepared = try AutoEffortDecisionPolicy().build(
            requestID: UUID(), maskedTaskExcerpt: masked, selectedModelID: "gpt-6-sol",
            builtInWorkflow: .review, efforts: ["low", "future-effort"], capabilities: service.capabilities
        )
        let context = prepared.request.textContext
        XCTAssertTrue(context.contains("SELECTED_MODEL_ID:\ngpt-6-sol"))
        XCTAssertTrue(context.contains("BUILT_IN_WORKFLOW_CATEGORY:\nreview"))
        XCTAssertTrue(context.contains("MASKED_CURRENT_USER_TURN_EXCERPT:"))
        XCTAssertFalse(context.contains("private123"))
        XCTAssertFalse(context.contains("/Users/alice/work"))
        XCTAssertFalse(context.contains("workflow template"))
        XCTAssertEqual(prepared.request.question.choices.map(\.opaqueKey), ["effort-0", "effort-1"])
        XCTAssertTrue(prepared.request.question.choices[1].description.contains("not yet profiled"))
        XCTAssertNil(prepared.effort(for: .selected(opaqueKey: "future-effort", evidence: nil)))
        XCTAssertNil(prepared.effort(for: .abstained(reasonCode: "no-choice", evidence: nil)))
        XCTAssertNil(prepared.effort(for: .failed(category: .transport, retryable: true, evidence: nil)))
        XCTAssertNil(prepared.effort(for: .cancelled))
    }

    func testGenericPolicyRejectsIncompatibleCapabilityBeforeDispatch() {
        let narrow = DecisionServiceCapabilities(
            contextKinds: [.text],
            finiteChoice: .init(
                minimumChoices: 2, maximumChoices: 12, maximumContextBytes: 100,
                maximumInstructionsBytes: 16 * 1024, maximumChoiceDescriptionBytes: 8 * 1024,
                maximumAggregateBytes: 128 * 1024
            ),
            evidence: .init(confidence: false, probabilityDistribution: false, usage: false)
        )
        XCTAssertFalse(AutoEffortDecisionPolicy.supports(narrow))
        XCTAssertThrowsError(try AutoEffortDecisionPolicy().build(
            requestID: UUID(), maskedTaskExcerpt: "Review change", selectedModelID: "gpt-6-sol",
            builtInWorkflow: nil, efforts: ["low", "medium"], capabilities: narrow
        ))
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
        let service = JevDecisionService(credentialService: credentials)
        let prepared = try AutoEffortDecisionPolicy().build(
            requestID: UUID(), maskedTaskExcerpt: masked, selectedModelID: "gpt-6-sol",
            builtInWorkflow: nil, efforts: ["low", "medium"], capabilities: service.capabilities
        )
        let outcome = await service.decide(prepared.request)
        let chosen = prepared.effort(for: outcome)
        XCTAssertEqual(chosen, "medium")
        let request = await client.lastRequest
        XCTAssertEqual(request?.model, JevRouterCredentialService.pinnedModel)
        XCTAssertEqual(
            request?.state,
            "SELECTED_MODEL_ID:\ngpt-6-sol\n\nMASKED_CURRENT_USER_TURN_EXCERPT:\n\(masked)"
        )
        XCTAssertFalse(request?.state.contains("private123") == true)
        XCTAssertEqual(request.map { Set($0.questions.keys) }, Set([JevDecisionService.routeQuestionID]))
        XCTAssertEqual(request?.questions[JevDecisionService.routeQuestionID]?.criteria.keys.sorted(), ["effort-0", "effort-1"])
    }

    func testJevWireRequestIncludesOnlyFixedBuiltInWorkflowCategory() async throws {
        let client = CapturingAutoEffortJevClient()
        let credentials = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend(values: [.jevRouterAPIKey: "stored"])),
            client: client
        )
        guard case .saved = await credentials.validateStoredKey(operationID: UUID()) else {
            return XCTFail("Stored Jev key did not validate")
        }
        let service = JevDecisionService(credentialService: credentials)
        let prepared = try AutoEffortDecisionPolicy().build(
            requestID: UUID(), maskedTaskExcerpt: "Check the change", selectedModelID: "gpt-6-sol",
            builtInWorkflow: .review, efforts: ["low", "medium"], capabilities: service.capabilities
        )
        let outcome = await service.decide(prepared.request)
        XCTAssertEqual(prepared.effort(for: outcome), "medium")
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
                "route": .init(
                    type: "choice",
                    choice: "effort-1",
                    probabilities: ["effort-0": 0.2, "effort-1": 0.8],
                    confidence: 0.8
                )
            ],
            usage: .init(inputTokens: 12, outputTokens: 4)
        )
    }
}

@MainActor
final class ModelRouterDecisionPolicyTests: XCTestCase {
    func testVersionedSingleQuestionPreservesDirectiveIdentityAndExactKeys() throws {
        let choices = [candidate("opaque-a", model: "alpha"), candidate("opaque-b", model: "beta")]
        let request = try ModelRouterDecisionPolicy().build(
            requestID: UUID(), task: "  Investigate a regression  ", scope: .subagent,
            stage: .model, directive: "  Prefer reliable review.  ", candidates: choices,
            capabilities: capabilities()
        )
        XCTAssertEqual(request.consumerID, .modelRouter)
        XCTAssertEqual(request.contractVersion, FiniteChoiceDecisionRequest.currentContractVersion)
        XCTAssertEqual(request.policy, ModelRouterDecisionPolicy.identity)
        XCTAssertEqual(request.question.name, "model_route")
        XCTAssertEqual(request.question.choices.map(\.opaqueKey), ["opaque-a", "opaque-b"])
        XCTAssertEqual(request.textContext, "HIGHEST-PRIORITY USER ROUTING DIRECTIVE:\nPrefer reliable review.\n\nTASK:\nInvestigate a regression")
        XCTAssertTrue(request.question.instructions.contains("delegated subagent session"))
        XCTAssertTrue(request.question.instructions.contains("Choose the model first"))
        XCTAssertTrue(request.question.choices[0].description.contains("Provider: codexExec; model: alpha; effort: provider-default"))
        XCTAssertTrue(request.question.choices[0].description.contains("Missing evidence is unknown"))
        XCTAssertFalse(request.textContext.contains("opaque-a"))
        XCTAssertTrue(request.question.instructions.hasPrefix("HIGHEST-PRIORITY USER ROUTING DIRECTIVE: Prefer reliable review."))
    }

    func testEffortQuestionKeepsSelectedBaseModelAndDoesNotRevisitIt() throws {
        let request = try ModelRouterDecisionPolicy().build(
            requestID: UUID(), task: "Implement parser and tests", scope: .primarySession,
            stage: .effort, directive: "", candidates: [
                candidate("low", model: "sol", effort: "low"), candidate("high", model: "sol", effort: "high")
            ], capabilities: capabilities()
        )
        XCTAssertEqual(request.question.name, "effort_route")
        XCTAssertTrue(request.question.instructions.contains("Do not revisit or substitute the base-model choice"))
        XCTAssertEqual(request.question.choices.map(\.opaqueKey), ["low", "high"])
        XCTAssertTrue(request.question.choices[0].description.contains("effort: low"))
        XCTAssertTrue(request.question.choices[1].description.contains("effort: high"))
    }

    func testBudgetDropsOptionalProfileBeforeRequiredFieldsAndKeepsBothTaskEnds() throws {
        let task = "Investigate opening behavior. " + String(repeating: "middle context ", count: 500)
            + " Verify the ending cancellation behavior."
        let limited = capabilities(context: 700, description: 160, aggregate: 2500)
        let request = try ModelRouterDecisionPolicy().build(
            requestID: UUID(), task: task, scope: .primarySession, stage: .model,
            directive: "Prefer correctness over cost.",
            candidates: [candidate("a", model: "alpha"), candidate("b", model: "beta")],
            capabilities: limited
        )
        XCTAssertLessThanOrEqual(request.textContext.utf8.count, 700)
        XCTAssertLessThanOrEqual(request.aggregateUTF8Bytes, 2500)
        XCTAssertTrue(request.textContext.contains("Investigate opening behavior"))
        XCTAssertTrue(request.textContext.contains("ending cancellation behavior"))
        XCTAssertTrue(request.textContext.contains("task middle omitted"))
        XCTAssertTrue(request.textContext.contains("Prefer correctness over cost"))
        XCTAssertTrue(request.question.choices.allSatisfy { $0.description.contains("Missing evidence is unknown") })
        XCTAssertTrue(request.question.choices.allSatisfy { !$0.description.contains("Rubric v1:") })
    }

    func testAggregateLimitShortensOnlyTaskAfterReservingRequiredContent() throws {
        let task = "Opening task goal. " + String(repeating: "background detail ", count: 400)
            + " Ending validation goal."
        let limits = capabilities(context: 2000, aggregate: 2500)
        let request = try ModelRouterDecisionPolicy().build(
            requestID: UUID(), task: task, scope: .primarySession, stage: .model,
            directive: "Prefer reliability.",
            candidates: [candidate("a", model: "alpha"), candidate("b", model: "beta")],
            capabilities: limits
        )
        XCTAssertLessThan(request.textContext.utf8.count, 2000)
        XCTAssertLessThanOrEqual(request.aggregateUTF8Bytes, 2500)
        XCTAssertTrue(request.textContext.contains("Opening task goal"))
        XCTAssertTrue(request.textContext.contains("Ending validation goal"))
        XCTAssertTrue(request.question.choices.allSatisfy { $0.description.contains("Missing evidence is unknown") })
    }

    func testLongTaskMaskingAndInsufficientBudgetFailClosed() throws {
        let task = "Investigate parser. password=openingSecret "
            + String(repeating: "ordinary details ", count: 500)
            + " Add tests. token=endingSecret"
        let request = try ModelRouterDecisionPolicy().build(
            requestID: UUID(), task: task, scope: .primarySession, stage: .model,
            directive: "", candidates: [candidate("a", model: "alpha"), candidate("b", model: "beta")],
            capabilities: capabilities()
        )
        XCTAssertFalse(request.textContext.contains("openingSecret"))
        XCTAssertFalse(request.textContext.contains("endingSecret"))
        XCTAssertTrue(request.textContext.contains("Investigate parser"))
        XCTAssertTrue(request.textContext.contains("Add tests"))
        XCTAssertThrowsError(try ModelRouterDecisionPolicy().build(
            requestID: UUID(), task: "task", scope: .primarySession, stage: .model,
            directive: "", candidates: [candidate("a", model: "alpha"), candidate("b", model: "beta")],
            capabilities: capabilities(context: 4)
        )) { XCTAssertEqual($0 as? ModelRouterDecisionPolicy.BuildError, .insufficientCapability) }
    }

    func testDuplicateOpaqueKeysAndOversizedDirectiveFailClosed() {
        let policy = ModelRouterDecisionPolicy()
        let duplicates = [candidate("same", model: "alpha"), candidate("same", model: "beta")]
        XCTAssertThrowsError(try policy.build(
            requestID: UUID(), task: "task", scope: .primarySession, stage: .model,
            directive: "", candidates: duplicates, capabilities: capabilities()
        )) { XCTAssertEqual($0 as? ModelRouterDecisionPolicy.BuildError, .invalidRequest) }
        XCTAssertThrowsError(try policy.build(
            requestID: UUID(), task: "task", scope: .primarySession, stage: .model,
            directive: String(repeating: "x", count: 1001), candidates: duplicates, capabilities: capabilities()
        )) { XCTAssertEqual($0 as? ModelRouterDecisionPolicy.BuildError, .oversizedDirective) }
    }

    private func candidate(_ key: String, model: String, effort: String? = nil) -> AgentTaskRoutingCandidateBuilder.Candidate {
        .init(
            opaqueKey: key, utilityTier: model,
            target: .init(agentRaw: "codexExec", modelRaw: model, reasoningEffortRaw: effort, modelParameters: []),
            descriptor: .init(
                opaqueKey: key, roleLabels: ["engineer"], targetDescription: "Audited profile for \(model)",
                rubricVersion: "v1", rubric: String(repeating: "optional evidence ", count: 20)
            )
        )
    }

    private func capabilities(
        context: Int = 24 * 1024, description: Int = 8 * 1024, aggregate: Int = 128 * 1024
    ) -> DecisionServiceCapabilities {
        .init(
            contextKinds: [.text],
            finiteChoice: .init(
                minimumChoices: 2, maximumChoices: 12, maximumContextBytes: context,
                maximumInstructionsBytes: 16 * 1024, maximumChoiceDescriptionBytes: description,
                maximumAggregateBytes: aggregate
            ),
            evidence: .init(confidence: true, probabilityDistribution: true, usage: true)
        )
    }
}
