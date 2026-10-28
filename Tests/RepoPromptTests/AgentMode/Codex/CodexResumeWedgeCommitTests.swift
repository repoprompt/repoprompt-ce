import Foundation
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class CodexResumeWedgeCommitTests: XCTestCase {
    private static let oldThreadID = "old-committed-thread"
    private static let oldRolloutPath = "/tmp/old-committed-rollout.jsonl"
    private static let missingRolloutMessage =
        "failed to resolve rollout path /tmp/old-committed-rollout.jsonl: file does not exist"

    @MainActor
    private struct Fixture {
        let viewModel: AgentModeViewModel
        let workspaceManager: WorkspaceManagerViewModel
        let session: AgentTabSession
        let factory: WedgeControllerFactory

        var coordinator: CodexAgentModeCoordinator {
            viewModel.test_codexCoordinator
        }
    }

    private func makeFixture(
        _ plans: [[WedgeFakeCodexController.Response]],
        mcpServerEnabler: @escaping @MainActor @Sendable () async -> Bool = { true },
        routeOwnerValidator: @escaping CodexAgentModeCoordinator.CodexRouteOwnerValidator = { _, _, _, _ in true },
        runtimeUnavailableMessage: @escaping () -> String? = { nil },
        runtimePreflight: (() async -> String?)? = nil,
        companionReady: @escaping () -> Bool = { true },
        freshSession: Bool = false,
        shouldManageCodexTooling: Bool = true,
        authRecovery: (any CodexManagedAuthRecovering)? = nil
    ) -> Fixture {
        let factory = WedgeControllerFactory(plans: plans)
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.temporaryDirectory.path,
            shouldManageCodexTooling: shouldManageCodexTooling,
            codexControllerFactory: { runID, _, _, _, _, _ in factory.make(runID: runID) },
            codexControllerFactoryWithComputerUse: { runID, _, _, _, _, _, enabled, _ in
                factory.make(runID: runID, computerUseEnabled: enabled)
            },
            mcpServerEnabler: mcpServerEnabler,
            testCodexManagedAuthRecovery: authRecovery,
            testCodexComputerUseRuntimeUnavailableMessage: runtimeUnavailableMessage,
            testCodexComputerUseRuntimePreflight: runtimePreflight,
            testCodexComputerUseCompanionReady: companionReady,
            testCodexComputerUseReservedEntryExists: { false },
            testCodexLeaseRoutingTimeoutMs: 5000,
            testCodexRouteOwnerValidator: routeOwnerValidator
        )
        let workspaceManager = AgentSessionLinkEndpointTestSupport.installWorkspace(
            on: viewModel,
            tabID: tabID,
            name: "Codex resume wedge test"
        )
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .codexExec
        session.hasLoadedPersistedState = true
        if freshSession {
            session.runState = .idle
        } else {
            session.codexConversationID = Self.oldThreadID
            session.codexRolloutPath = Self.oldRolloutPath
            session.providerCleanupHandle = ProviderConversationCleanupHandle(
                provider: AgentProviderKind.codexExec.rawValue,
                conversationID: Self.oldThreadID,
                rolloutPath: Self.oldRolloutPath
            )
            session.codexNeedsReconnect = true
            session.runState = .running
            session.beginRunAttempt(source: "codex-resume-wedge-test")
        }
        return Fixture(
            viewModel: viewModel,
            workspaceManager: workspaceManager,
            session: session,
            factory: factory
        )
    }

    func testComposerRechecksEligibilityAfterSuspendedRuntimePreflight() async throws {
        CodexComputerUseWorkflow.setEnabledForTesting(false)
        defer { CodexComputerUseWorkflow.setEnabledForTesting(nil) }
        var release: CheckedContinuation<String?, Never>?
        let fixture = makeFixture([], runtimePreflight: {
            await withCheckedContinuation { continuation in
                release = continuation
            }
        }, freshSession: true)
        var prompted = false
        let arming = Task {
            await fixture.viewModel.armComputerUseForLocalUser(session: fixture.session, confirmOptIn: {
                prompted = true
                return true
            })
        }
        try await AsyncTestWait.waitUntil("composer runtime preflight reaches suspension", timeout: 3) { release != nil }
        XCTAssertNotNil(fixture.session.codexComputerUseArmingRequestID)
        fixture.session.parentSessionID = UUID()
        release?.resume(returning: nil)
        let message = await arming.value
        XCTAssertEqual(message, CodexComputerUseWorkflow.ineligibleMessage)
        XCTAssertFalse(prompted)
        XCTAssertNil(fixture.session.codexComputerUseArmingRequestID)
        XCTAssertNil(fixture.session.pendingCodexComputerUseActivation)
        XCTAssertTrue(fixture.factory.controllers.isEmpty)
    }

    func testRuntimeRejectionPrecedesComposerOptInAndSessionCreation() async {
        CodexComputerUseWorkflow.setEnabledForTesting(false)
        defer { CodexComputerUseWorkflow.setEnabledForTesting(nil) }
        let fixture = makeFixture([], runtimeUnavailableMessage: { CodexComputerUseWorkflow.runtimeRequirementMessage }, freshSession: true)
        let session = fixture.session
        let bindingBefore = session.persistentSessionBindingIdentity
        var prompted = false
        let result = await fixture.viewModel.armComputerUseForLocalUser(session: session, confirmOptIn: {
            prompted = true
            return true
        })
        XCTAssertEqual(result, CodexComputerUseWorkflow.runtimeRequirementMessage)
        XCTAssertFalse(prompted)
        XCTAssertFalse(CodexComputerUseWorkflow.isEnabled)
        XCTAssertEqual(session.persistentSessionBindingIdentity, bindingBefore)
        XCTAssertNil(session.codexComputerUseArmingRequestID)
        XCTAssertNil(session.pendingCodexComputerUseActivation)
        XCTAssertTrue(fixture.factory.controllers.isEmpty)
    }

    func testRequiredRepoPromptDiscoveryFailureIsVisibleAndTerminatesBeforeDispatch() async throws {
        for resuming in [false, true] {
            let fixture = makeFixture([[.discoveryFailure]])
            if !resuming {
                fixture.session.codexConversationID = nil
                fixture.session.codexRolloutPath = nil
                fixture.session.providerCleanupHandle = nil
            }
            var sendFinished = false
            let send = Task {
                let result = await fixture.coordinator.sendCodexNativeMessage(
                    session: fixture.session,
                    text: "continue",
                    attachments: []
                )
                sendFinished = true
                return result
            }
            defer { send.cancel() }
            try await AsyncTestWait.waitUntil("discovery failure terminates", timeout: 4) {
                sendFinished
            }
            guard case .failed = await send.value else {
                return XCTFail("Discovery failure must reject the send")
            }
            let errors = fixture.session.items.filter { $0.kind == .error }
            XCTAssertEqual(errors.count, 1)
            let message = try XCTUnwrap(errors.first).text
            XCTAssertTrue(message.contains("RepoPromptCE"))
            XCTAssertTrue(message.contains("required MCP servers failed to initialize"))
            XCTAssertTrue(message.contains("Tool catalog not ready. Please retry."))
            XCTAssertFalse(fixture.coordinator.test_hasPendingCodexStart(for: fixture.session))
            XCTAssertEqual(fixture.factory.controllers.count, 1)
            XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
        }
    }

    func testColdCompactionAfterRouteRevocationInstallsPolicyBeforeDiscovery() async throws {
        let fixture = makeFixture([
            [.success(Self.oldThreadID)],
            [.policyRequiredResume],
            [.policyRequiredResume]
        ])
        addTeardownBlock { @MainActor in
            let runID = fixture.session.runID
            await fixture.coordinator.shutdownCodexSession(fixture.session)
            if let runID,
               let clientName = AgentProviderKind.codexExec.mcpClientNameHint
            {
                await ServerNetworkManager.shared.revokeClientConnectionPolicy(
                    for: clientName,
                    windowID: 1,
                    runID: runID
                )
            }
        }
        let failedStart = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        addTeardownBlock {
            failedStart.cancel()
            await failedStart.value
        }
        try await waitForPendingStart(fixture)
        let revokedRunID = try XCTUnwrap(fixture.session.runID)
        await MCPRoutingWaiter.shared.notifyFailed(runID: revokedRunID)
        await failedStart.value
        let oldPolicyRemains = await hasPendingPolicy(for: revokedRunID)
        XCTAssertFalse(oldPolicyRemains)
        XCTAssertNil(fixture.session.codexController)
        assertOldTuple(fixture.session)

        fixture.session.runState = .idle
        let compact = Task {
            await fixture.coordinator.startOversightCompaction(
                session: fixture.session,
                expectedThreadID: Self.oldThreadID,
                isStillAdmissible: { true }
            )
        }
        addTeardownBlock {
            compact.cancel()
            _ = await compact.value
        }
        try await waitForPendingStart(fixture)
        let controller = try XCTUnwrap(fixture.factory.controllers.last)
        XCTAssertEqual(fixture.factory.controllers.count, 2)
        XCTAssertEqual(controller.receivedExistingIDs, [Self.oldThreadID])
        XCTAssertEqual(controller.startedTurnCount, 0)
        XCTAssertEqual(controller.compactCount, 0, "Compaction must wait for owned routing")
        XCTAssertEqual(fixture.session.runState, .idle, "Resume must not manufacture an active model turn")
        let compactRunID = try XCTUnwrap(fixture.session.runID)
        XCTAssertNotEqual(compactRunID, revokedRunID)
        await MCPRoutingWaiter.shared.notifyRouted(runID: compactRunID)
        let outcome = await compact.value
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(controller.compactCount, 1)
        XCTAssertEqual(controller.startedTurnCount, 0)
        assertOldTuple(fixture.session)
        XCTAssertFalse(fixture.coordinator.test_hasPendingCodexStart(for: fixture.session))
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })

        if let ownership = fixture.session.activeRunOwnership {
            _ = fixture.session.endRunAttempt(ifCurrent: ownership, source: "fake-compact-completed")
        }
        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "send-after-cold-compact")
        let send = Task {
            await fixture.coordinator.sendCodexNativeMessage(
                session: fixture.session, text: "continue", attachments: []
            )
        }
        addTeardownBlock {
            send.cancel()
            _ = await send.value
        }
        // Synthetic routing left no live app connection, so the ordinary send must rebind.
        try await waitForPendingStart(fixture)
        XCTAssertEqual(fixture.factory.controllers.count, 3)
        let sendController = try XCTUnwrap(fixture.factory.controllers.last)
        XCTAssertEqual(sendController.receivedExistingIDs, [Self.oldThreadID])
        XCTAssertEqual(sendController.startedTurnCount, 0)
        try await MCPRoutingWaiter.shared.notifyRouted(runID: XCTUnwrap(fixture.session.runID))
        let sendOutcome = await send.value
        XCTAssertTrue(sendOutcome.didSend)
        XCTAssertEqual(sendController.startedTurnCount, 1)
        XCTAssertEqual(sendController.compactCount, 0)
        assertOldTuple(fixture.session)
    }

    /// Routing is synthetic; assert pending-policy cleanup rather than live socket admission.
    func testColdResumeFailureAfterRoutedCleansOnlyItsOwnedStartup() async throws {
        for superseded in [false, true] {
            let gate = TestReleaseFence(name: "routed compact resume failure")
            let fixture = makeFixture([[.routedThenResumeFailure(gate)]])
            fixture.session.runState = .idle
            addTeardownBlock { @MainActor in
                let runID = fixture.session.runID
                await fixture.coordinator.shutdownCodexSession(fixture.session)
                if let runID, let clientName = AgentProviderKind.codexExec.mcpClientNameHint {
                    await ServerNetworkManager.shared.revokeClientConnectionPolicy(
                        for: clientName, windowID: 1, runID: runID
                    )
                    await MCPRoutingWaiter.shared.cleanup(runID: runID)
                }
            }
            let compact = Task {
                await fixture.coordinator.startOversightCompaction(
                    session: fixture.session,
                    expectedThreadID: Self.oldThreadID,
                    isStillAdmissible: { true }
                )
            }
            addTeardownBlock {
                compact.cancel()
                gate.release()
                _ = await compact.value
            }
            let entered = await gate.waitUntilEntered(timeout: 4)
            XCTAssertTrue(entered)
            let controller = try XCTUnwrap(fixture.factory.controllers.first)
            let runID = try XCTUnwrap(fixture.session.runID)
            let successor = WedgeFakeCodexController(runID: runID, responses: [])
            if superseded {
                fixture.session.beginRunAttempt(source: "compact-successor")
                fixture.session.codexController = successor
                try await ServerNetworkManager.shared.installClientConnectionPolicy(
                    for: XCTUnwrap(AgentProviderKind.codexExec.mcpClientNameHint),
                    windowID: 1, restrictedTools: [], tabID: fixture.session.tabID,
                    runID: runID, purpose: .agentModeRun, requiresExpectedAgentPID: true
                )
            }
            let attemptBeforeFailure = fixture.session.activeRunAttemptID
            let itemsBeforeFailure = fixture.session.items.count
            gate.release()
            let outcome = await compact.value
            try await AsyncTestWait.waitUntil("failed compact controller retired", timeout: 4) {
                controller.shutdownCount == 1
            }
            let pendingPolicyRemains = await hasPendingPolicy(for: runID)
            XCTAssertEqual(pendingPolicyRemains, superseded)
            if superseded {
                XCTAssertEqual(fixture.session.codexController.map(ObjectIdentifier.init), ObjectIdentifier(successor))
                XCTAssertEqual(successor.shutdownCount, 0)
                XCTAssertEqual(fixture.session.items.count, itemsBeforeFailure)
            } else {
                XCTAssertNil(fixture.session.codexController)
            }
            XCTAssertEqual(fixture.factory.controllers.count, 1)
            XCTAssertEqual(controller.receivedExistingIDs, [Self.oldThreadID])
            XCTAssertEqual(outcome, .notStarted)
            XCTAssertFalse(fixture.coordinator.test_hasPendingCodexStart(for: fixture.session))
            XCTAssertEqual(controller.startedTurnCount, 0)
            XCTAssertEqual(controller.compactCount, 0)
            XCTAssertEqual(fixture.session.runState, .idle)
            XCTAssertEqual(fixture.session.activeRunAttemptID, attemptBeforeFailure)
            assertOldTuple(fixture.session)
        }
    }

    func testAcquisitionFailureRetiresPreparedColdCompactController() async throws {
        let fixture = makeFixture([[]], mcpServerEnabler: { false })
        fixture.session.runState = .idle
        addTeardownBlock { @MainActor in
            await fixture.coordinator.shutdownCodexSession(fixture.session)
        }
        let outcome = await fixture.coordinator.startOversightCompaction(
            session: fixture.session, expectedThreadID: Self.oldThreadID, isStillAdmissible: { true }
        )
        let controller = try XCTUnwrap(fixture.factory.controllers.first)
        XCTAssertEqual(outcome, .notStarted)
        XCTAssertNil(fixture.session.codexController, "Failed provisioning must not strand the prepared idle controller")
        XCTAssertEqual(controller.shutdownCount, 1)
        XCTAssertEqual(controller.startedTurnCount, 0)
        XCTAssertEqual(controller.compactCount, 0)
        XCTAssertTrue(controller.receivedExistingIDs.isEmpty)
        XCTAssertFalse(fixture.coordinator.test_hasPendingCodexStart(for: fixture.session))
        assertOldTuple(fixture.session)
    }

    func testRoutingQualificationSupersessionPreservesSameRunPolicy() async throws {
        let gate = TestReleaseFence(name: "cold compact route-owner validation")
        let fixture = makeFixture([[.policyRequiredResume]], routeOwnerValidator: { _, _, _, _ in
            await gate.enterAndWait()
            return true
        })
        fixture.session.runState = .idle
        let compact = Task {
            await fixture.coordinator.startOversightCompaction(
                session: fixture.session, expectedThreadID: Self.oldThreadID, isStillAdmissible: { true }
            )
        }
        addTeardownBlock { @MainActor in
            compact.cancel()
            gate.release()
            _ = await compact.value
            let runID = fixture.session.runID
            await fixture.coordinator.shutdownCodexSession(fixture.session)
            if let runID, let clientName = AgentProviderKind.codexExec.mcpClientNameHint {
                await ServerNetworkManager.shared.revokeClientConnectionPolicy(for: clientName, windowID: 1, runID: runID)
                await MCPRoutingWaiter.shared.cleanup(runID: runID)
            }
        }
        try await waitForPendingStart(fixture)
        let runID = try XCTUnwrap(fixture.session.runID)
        await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
        let entered = await gate.waitUntilEntered(timeout: 4)
        XCTAssertTrue(entered)
        let original = try XCTUnwrap(fixture.factory.controllers.first)
        let successor = WedgeFakeCodexController(runID: runID, responses: [])
        fixture.session.beginRunAttempt(source: "cold compact route successor")
        fixture.session.codexController = successor
        try await ServerNetworkManager.shared.installClientConnectionPolicy(
            for: XCTUnwrap(AgentProviderKind.codexExec.mcpClientNameHint), windowID: 1,
            restrictedTools: [], tabID: fixture.session.tabID, runID: runID,
            purpose: .agentModeRun, requiresExpectedAgentPID: true
        )
        await MCPRoutingWaiter.shared.cleanup(runID: runID)
        await MCPRoutingWaiter.register(runID: runID)
        await MCPRoutingWaiter.notifyRouted(runID: runID)
        let successorAttempt = fixture.session.activeRunAttemptID
        let successorItems = fixture.session.items.count
        gate.release()
        let outcome = await compact.value
        let policyRemains = await hasPendingPolicy(for: runID)
        XCTAssertEqual(outcome, .notStarted)
        XCTAssertTrue(policyRemains, "A stale compact routing callback must not revoke the successor's policy")
        XCTAssertEqual(fixture.session.codexController.map(ObjectIdentifier.init), ObjectIdentifier(successor))
        XCTAssertEqual(successor.shutdownCount, 0)
        let routingOutcome = await MCPRoutingWaiter.currentTerminalOutcome(runID: runID)
        XCTAssertEqual(routingOutcome, .routed)
        XCTAssertEqual(fixture.session.activeRunAttemptID, successorAttempt)
        XCTAssertEqual(fixture.session.items.count, successorItems)
        try await AsyncTestWait.waitUntil("superseded controller retired", timeout: 4) { original.shutdownCount == 1 }
        XCTAssertEqual(original.compactCount, 0)
        XCTAssertEqual(original.startedTurnCount, 0)
        assertOldTuple(fixture.session)
    }

    func testComputerUseLegacyApprovalSurfacesAndRejectsRememberedAnswers() async throws {
        CodexComputerUseWorkflow.setEnabledForTesting(false)
        defer { CodexComputerUseWorkflow.setEnabledForTesting(nil) }
        let fixture = makeFixture([])
        let session = fixture.session
        let controller = WedgeFakeCodexController(runID: UUID(), responses: [])
        session.codexController = controller
        session.codexControllerFeatureState = .init(computerUseEnabled: true, goalSupportEnabled: false, reasoningSummariesEnabled: false, memoriesEnabled: false, capabilities: .disabled)
        let request = makeLegacyApprovalRequest()
        let questionID = try XCTUnwrap(request.questions.first?.id)
        await fixture.coordinator.test_handleCodexNativeEvent(.requestUserInput(request), session: session, sourceController: controller)
        XCTAssertEqual(session.pendingUserInputRequest?.id, request.id, "Frozen armed scope must surface approval even with the global setting OFF")
        XCTAssertEqual(session.pendingUserInputRequest?.questions.first?.options.map(\.label), ["Allow", "Deny"], "Remembered and unknown approval options must not be offered")
        // Continue probing submission even on the known-bad autoanswer path.
        if session.pendingUserInputRequest == nil { session.pendingUserInputRequest = request }
        for remembered in ["Allow for this session", "AlwaysAllow", "Allow forever", "user_note: Allow for this session"] {
            fixture.viewModel.submitUserInputResponse(tabID: session.tabID, requestID: request.requestID, response: .init(answersByQuestionID: [questionID: [remembered]]))
            XCTAssertEqual(session.pendingUserInputRequest?.id, request.id, "Rejected answers must preserve the pending review: \(remembered)")
            if session.pendingUserInputRequest == nil { session.pendingUserInputRequest = request }
        }
        fixture.viewModel.submitUserInputResponse(tabID: session.tabID, requestID: .int(999), response: .init(answersByQuestionID: [questionID: ["Allow"]]))
        XCTAssertEqual(session.pendingUserInputRequest?.id, request.id, "A stale request ID must not consume the prompt")
        fixture.viewModel.submitUserInputResponse(tabID: session.tabID, requestID: request.requestID, response: .init(answersByQuestionID: [questionID: ["Allow"]]))
        try await AsyncTestWait.waitUntil("explicit one-shot legacy answer", timeout: 4) { controller.qaUserInputAnswers[questionID] == ["Allow"] }
        XCTAssertEqual(controller.qaResponseCount, 1, "Only the explicit one-shot response may reach the controller")
        XCTAssertNil(session.pendingUserInputRequest)
        await fixture.coordinator.shutdownCodexSession(session)
    }

    func testOrdinaryLegacyApprovalRetainsAutomaticSessionAnswer() async throws {
        for optedIn in [false, true] {
            CodexComputerUseWorkflow.setEnabledForTesting(optedIn)
            let fixture = makeFixture([])
            let session = fixture.session
            let controller = WedgeFakeCodexController(runID: UUID(), responses: [])
            session.codexController = controller
            session.codexControllerFeatureState = .init(computerUseEnabled: false, goalSupportEnabled: false, reasoningSummariesEnabled: false, memoriesEnabled: false, capabilities: .disabled)
            let request = makeLegacyApprovalRequest()
            let questionID = try XCTUnwrap(request.questions.first?.id)
            await fixture.coordinator.test_handleCodexNativeEvent(.requestUserInput(request), session: session, sourceController: controller)
            try await AsyncTestWait.waitUntil("ordinary automatic legacy answer", timeout: 4) { controller.qaResponseCount == 1 }
            XCTAssertNil(session.pendingUserInputRequest)
            XCTAssertEqual(controller.qaUserInputAnswers[questionID], ["Allow for this session"])
            await fixture.coordinator.shutdownCodexSession(session)
        }
        CodexComputerUseWorkflow.setEnabledForTesting(nil)
    }

    func testArmedLegacyApprovalsRequireRepoPromptProvenanceAndRemainOneShot() async throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        defer { CodexComputerUseWorkflow.setEnabledForTesting(nil) }
        let cases: [(String?, String, Bool, Bool)] = [
            ("RepoPromptCE", "apply_edits", true, true),
            ("computer-use", "apply_edits", true, true),
            ("computer-use", "apply_edits", false, false),
            ("NotRepoPromptCE", "mcp__RepoPromptCE__apply_edits", false, true),
            (nil, "apply_edits", false, true),
            ("RepoPromptCE", "mcp__OtherServer__apply_edits", false, true)
        ]
        for (server, tool, autoApproved, fullAccess) in cases {
            let fixture = makeFixture([])
            fixture.session.permissionProfile = .providerOverride(.codex(fullAccess ? .fullAccess : .autoReview))
            let controller = WedgeFakeCodexController(runID: UUID(), responses: [])
            fixture.session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
            fixture.session.codexController = controller
            fixture.session.codexControllerFeatureState = .init(computerUseEnabled: true, goalSupportEnabled: false, reasoningSummariesEnabled: false, memoriesEnabled: false, capabilities: .disabled)
            var params: [String: Any] = [
                "threadId": Self.oldThreadID, "turnId": "legacy-turn", "itemId": "legacy-approval", "toolName": tool,
                "questions": [["id": "mcp_tool_call_approval_apply_edits", "header": "MCP approval", "question": "Allow this tool?", "options": [
                    ["label": "Allow for this session", "description": "Remember"],
                    ["label": "Allow", "description": "One call"],
                    ["label": "Cancel", "description": "Refuse"]
                ]]]
            ]
            if let server { params["serverName"] = server }
            let request = try XCTUnwrap(CodexNativeSessionController.parseRequestUserInputRequest(requestID: .int(91), method: "item/tool/requestUserInput", params: params, activeThreadID: Self.oldThreadID, currentTurnID: "legacy-turn"))
            await fixture.coordinator.test_handleCodexNativeEvent(.requestUserInput(request), session: fixture.session, sourceController: controller)
            if autoApproved {
                XCTAssertNil(fixture.session.pendingUserInputRequest, "Verified RepoPrompt tools must retain their normal approval policy")
                try await AsyncTestWait.waitUntil("verified RepoPrompt one-shot answer", timeout: 2) { controller.qaResponseCount == 1 }
                XCTAssertEqual(controller.qaUserInputAnswers, ["mcp_tool_call_approval_apply_edits": ["Allow"]], "Arming must not add remembered permission")
            } else {
                XCTAssertEqual(fixture.session.pendingUserInputRequest?.id, request.id)
                XCTAssertEqual(controller.qaResponseCount, 0)
            }
            await fixture.coordinator.shutdownCodexSession(fixture.session)
        }
    }

    func testArmedRequestUserInputCardSubmitRequiresOneShotSelection() {
        let request = makeLegacyApprovalRequest()
        let questionID = "mcp_tool_call_approval_read_file"
        let empty = [questionID: AgentRequestUserInputQuestionDraft()]
        let allowOnce = [questionID: AgentRequestUserInputQuestionDraft(selectedOptionIndex: 0)]
        let remembered = [questionID: AgentRequestUserInputQuestionDraft(selectedOptionIndex: 1)]

        XCTAssertFalse(AgentRequestUserInputCard.canSubmit(request: request, drafts: empty, allowsRememberedDecision: false))
        XCTAssertTrue(AgentRequestUserInputCard.canSubmit(request: request, drafts: allowOnce, allowsRememberedDecision: false))
        XCTAssertFalse(AgentRequestUserInputCard.canSubmit(request: request, drafts: remembered, allowsRememberedDecision: false))
        XCTAssertTrue(AgentRequestUserInputCard.canSubmit(request: request, drafts: empty, allowsRememberedDecision: true))
    }

    private func makeLegacyApprovalRequest() -> AgentRequestUserInputRequest {
        .init(requestID: .int(91), method: "item/tool/requestUserInput", threadID: Self.oldThreadID, turnID: "legacy-turn", itemID: "legacy-approval", questions: [
            .init(id: "mcp_tool_call_approval_read_file", header: "MCP approval", question: "Allow this tool?", isOther: true, isSecret: false, options: [
                .init(label: "Allow", description: "One call"),
                .init(label: "Allow for this session", description: "Remember"),
                .init(label: "AlwaysAllow", description: "Remember"),
                .init(label: "Allow forever", description: "Unknown persistent choice"),
                .init(label: "Deny", description: "Refuse")
            ])
        ])
    }

    func testComputerUseIconProjectionIsPureAndHidesIneligibleChats() throws {
        var discoveries = 0
        let fixture = makeFixture([], companionReady: { discoveries += 1
            return true
        })
        let vm = fixture.viewModel
        let session = fixture.session
        session.runState = .idle
        XCTAssertTrue(vm.computerUseComposerProps(session: session).isVisible)
        XCTAssertFalse(vm.computerUseComposerProps(session: session).isOn)
        session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        XCTAssertTrue(vm.computerUseComposerProps(session: session).isOn)
        for provider in [AgentProviderKind.claudeCode, .cursor] {
            session.selectedAgent = provider
            XCTAssertEqual(vm.computerUseComposerProps(session: session), .hidden)
        }
        session.selectedAgent = .codexExec
        session.parentSessionID = UUID()
        XCTAssertEqual(vm.computerUseComposerProps(session: session), .hidden)
        session.parentSessionID = nil
        session.mcpControlActivationGeneration = 1
        XCTAssertTrue(vm.computerUseComposerProps(session: session).isVisible)
        session.mcpControlActivationGeneration = 0
        session.createdByOverseerSessionID = UUID()
        XCTAssertTrue(vm.computerUseComposerProps(session: session).isVisible)
        session.createdByOverseerSessionID = nil
        _ = try XCTUnwrap(vm.test_ensureSessionBoundToTab(session))
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(vm, tabID: session.tabID)
        vm.monitorPillPropsByEndpoint[endpoint] = .init(
            sessionID: session.activeAgentSessionID, endpoint: endpoint, outbound: [],
            inbound: [.init(
                linkID: UUID(),
                generation: 1,
                observerSessionID: UUID(),
                observerEndpoint: endpoint,
                displayName: "Observer",
                providerDisplayName: nil
            )], recentNotices: [], canAddReason: nil
        )
        XCTAssertTrue(vm.computerUseComposerProps(session: session).isVisible)
        XCTAssertEqual(discoveries, 0, "Painting must never discover or provision the companion")
    }

    func testComputerUseMCPTopLevelCanArmButChildAndDeliveredCommandsCannot() async {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        defer { CodexComputerUseWorkflow.setEnabledForTesting(nil) }
        let fixture = makeFixture([])
        let vm = fixture.viewModel
        let session = fixture.session
        session.runState = .idle
        session.isMCPOriginated = true
        session.createdByOverseerSessionID = UUID()
        session.mcpControlActivationGeneration = 1
        for local in [false, true] {
            let result = vm.submitUserTurn(text: "/computer-use inspect the screen", tabID: session.tabID, isLocalComposerInput: local)
            guard case .blocked = result else { return XCTFail("Only an admitted composer claim may arm") }
            XCTAssertFalse(session.isCodexComputerUseArmed)
        }
        await vm.toggleComputerUse(tabID: session.tabID, expectedSessionIdentity: ObjectIdentifier(session))
        XCTAssertTrue(session.isCodexComputerUseArmed)
        let activation = session.pendingCodexComputerUseActivation?.id
        let delivered = vm.submitUserTurn(text: "/computer-use inspect the screen", tabID: session.tabID, isLocalComposerInput: false)
        guard case .blocked = delivered else { return XCTFail("Delivered /computer-use cannot acquire local consent") }
        XCTAssertEqual(session.pendingCodexComputerUseActivation?.id, activation)
        let admitted = await fixture.coordinator.test_computerUseForNextTurn(session: session)
        XCTAssertTrue(admitted)
        await vm.toggleComputerUse(tabID: session.tabID, expectedSessionIdentity: ObjectIdentifier(session))
        session.parentSessionID = UUID()
        await vm.toggleComputerUse(tabID: session.tabID, expectedSessionIdentity: ObjectIdentifier(session))
        XCTAssertFalse(session.isCodexComputerUseArmed)
        let childMessage = await vm.armComputerUseForLocalUser(session: session)
        XCTAssertEqual(childMessage, CodexComputerUseWorkflow.ineligibleMessage)
        let detached = AgentTabSession(tabID: UUID())
        detached.selectedAgent = .codexExec
        let detachedMessage = await vm.armComputerUseForLocalUser(session: detached)
        XCTAssertEqual(detachedMessage, CodexComputerUseWorkflow.ineligibleMessage)
        XCTAssertEqual(CodexComputerUseWorkflow.ineligibleMessage, "Computer Use requires a top-level native Codex session with its own tab, the feature enabled, and an available companion. Enable it locally in that tab.")
    }

    func testLocalComputerUseComposerFirstSendArmsOnlyFreshDestinationAndStartsProvider() async throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        defer { CodexComputerUseWorkflow.setEnabledForTesting(nil) }
        let preflight = CodexComputerUseWorkflow.RuntimeAdmissionPreflight(load: { nil })
        XCTAssertEqual(preflight.cachedMessage, CodexComputerUseWorkflow.checkingRuntimeMessage)
        let fixture = try makeSubmissionFixture(runtimeUnavailableMessage: { preflight.cachedMessage }, runtimePreflight: { await preflight.check() })
        let vm = fixture.viewModel
        let source = fixture.session
        let destinationTabID = UUID()
        let text = "/computer-use inspect the screen"
        let claim = try claimLocalComposerTurn(text, session: source, viewModel: vm)
        XCTAssertEqual(claim.attempt.target.route, .createAgentSessionFromSourceTab)

        let result = await vm.executeComposerSubmitAttempt(
            text: text,
            claim: claim,
            createAndActivateSessionTab: {
                var workspace = fixture.workspaceManager.workspaces[0]
                workspace.composeTabs.append(ComposeTabState(id: destinationTabID, name: "Computer Use destination"))
                workspace.activeComposeTabID = destinationTabID
                fixture.workspaceManager.workspaces = [workspace]
                fixture.workspaceManager.activeWorkspace = workspace
                _ = vm.session(for: destinationTabID)
                vm.test_setCurrentTabIDOverride(destinationTabID)
                return destinationTabID
            }
        )
        XCTAssertEqual(result, .submitted)
        let destination = try XCTUnwrap(vm.sessions[destinationTabID])
        XCTAssertTrue(destination.isCodexComputerUseArmed)
        XCTAssertFalse(source.isCodexComputerUseArmed)
        XCTAssertTrue(source.items.isEmpty, "The source must not receive the destination's turn")
        try await assertComputerUseProviderStart(fixture, session: destination)
    }

    func testLocalComputerUseComposerExistingSessionArmsAndStartsProvider() async throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        defer { CodexComputerUseWorkflow.setEnabledForTesting(nil) }
        let fixture = try makeSubmissionFixture()
        let vm = fixture.viewModel
        let session = fixture.session
        _ = try installRestoredBinding(fixture)
        let text = "/computer-use inspect the screen"
        let claim = try claimLocalComposerTurn(text, session: session, viewModel: vm)
        XCTAssertNotEqual(claim.attempt.target.route, .createAgentSessionFromSourceTab)
        let result = await vm.executeComposerSubmitAttempt(
            text: text,
            claim: claim,
            createAndActivateSessionTab: {
                XCTFail("An existing session must not create a destination")
                return nil
            }
        )
        XCTAssertEqual(result, .submitted)
        XCTAssertTrue(session.isCodexComputerUseArmed)
        try await assertComputerUseProviderStart(fixture, session: session)
    }

    func testLocallyArmedChatRunsRemoteSessionLinkSendWithComputerUse() async throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        defer { CodexComputerUseWorkflow.setEnabledForTesting(nil) }
        let fixture = try makeSubmissionFixture()
        let vm = fixture.viewModel
        let session = fixture.session
        let sessionID = try installRestoredBinding(fixture)
        let candidate = try XCTUnwrap(vm.agentSessionLinkCandidate(
            tabID: session.tabID, sessionID: sessionID, tabName: "Target", isWindowClosing: false
        ))
        vm.test_setAgentSessionSaver { _, _, _ in
            FileManager.default.temporaryDirectory.appendingPathComponent("linked-send-test.json")
        }
        await vm.toggleComputerUse(tabID: session.tabID, expectedSessionIdentity: ObjectIdentifier(session))
        let request = computerUseRemoteRequest("inspect the screen")
        let outcome = await vm.agentSessionLinkPerformSend(
            to: candidate, request: request,
            liveness: { .init(observerEndpointIsLive: true, targetEndpointIsLive: true, targetWindowIsClosing: false) },
            commitAuthorization: { .committed }
        )
        guard case let .delivered(delivery) = outcome else { return XCTFail("Expected delivery: \(outcome)") }
        XCTAssertEqual(delivery.deliveryState, .runStarted)
        try await assertComputerUseProviderStart(fixture, session: session)
        let envelope = AgentSessionLinkMessageEnvelope.render(
            sourceSessionID: request.observerSessionID, sourceName: request.observerDisplayName,
            linkID: request.linkID, linkGeneration: request.linkGeneration,
            message: request.message, framing: request.framing
        )
        let expected = CodexComputerUseWorkflow.renderProviderPrompt(userInstructions: envelope)
        XCTAssertEqual(fixture.factory.controllers.first?.startedTexts, [expected])
        XCTAssertEqual(session.items.first(where: { $0.kind == .user })?.dispatchedProviderText, expected)
    }

    func testManagedSteerStoresExactProviderPayloadInArmedAndUnarmedChats() async throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        defer { CodexComputerUseWorkflow.setEnabledForTesting(nil) }
        for armed in [true, false] {
            let fixture = try makeSubmissionFixture()
            let vm = fixture.viewModel
            let session = fixture.session
            let sessionID = try installRestoredBinding(fixture)
            let candidate = try XCTUnwrap(vm.agentSessionLinkCandidate(
                tabID: session.tabID, sessionID: sessionID, tabName: "Target", isWindowClosing: false
            ))
            if armed {
                await vm.toggleComputerUse(tabID: session.tabID, expectedSessionIdentity: ObjectIdentifier(session))
            }
            XCTAssertEqual(vm.submitUserTurn(text: "inspect the screen", tabID: session.tabID), .submitted)
            try await AsyncTestWait.waitUntil("initial turn reaches fake provider", timeout: 4) {
                fixture.factory.controllers.first?.startedTurnCount == 1
            }
            let controller = try XCTUnwrap(fixture.factory.controllers.first)
            await fixture.coordinator.test_handleCodexNativeEvent(
                .turnStarted(turnID: "armed-turn"), session: session, sourceController: controller
            )
            let request = computerUseRemoteRequest("continue remotely")
            let envelope = AgentSessionLinkMessageEnvelope.render(
                sourceSessionID: request.observerSessionID, sourceName: request.observerDisplayName,
                linkID: request.linkID, linkGeneration: request.linkGeneration,
                message: request.message, framing: .management
            )
            let sink = AgentSessionLinkManagedSteerSink()
            XCTAssertTrue(vm.submitAgentSessionLinkManagedSteer(
                tabID: session.tabID, session: session, displayText: request.message,
                turn: .init(candidate: candidate, providerText: envelope, attribution: request.attribution, sink: sink),
                route: .codex
            ))
            let outcome = await sink.awaitOutcome(timeoutSeconds: 4)
            XCTAssertEqual(outcome, .delivered(.steered))
            let expected = armed ? CodexComputerUseWorkflow.renderProviderPrompt(userInstructions: envelope) : envelope
            XCTAssertEqual(controller.steeredTexts, [expected])
            let row = try XCTUnwrap(session.items.last(where: { $0.kind == .user }))
            XCTAssertEqual(row.dispatchedProviderText, controller.steeredTexts.last, "Stored managed payload must equal transport payload (armed: \(armed))")
            XCTAssertEqual(row.dispatchedProviderText, expected)
            XCTAssertEqual(fixture.factory.computerUseEnabledFlags, [armed])
            XCTAssertEqual(session.isCodexComputerUseArmed, armed)
            XCTAssertEqual(controller.startedTurnCount, 1)
        }
    }

    private func computerUseRemoteRequest(_ text: String) -> AgentSessionLinkSendRequest {
        .init(
            linkID: UUID(), linkGeneration: 1,
            observerEndpoint: DomainAgentSessionLinkEndpointIdentity(
                windowID: 2, workspaceID: UUID(), tabID: UUID(), sessionID: UUID(),
                persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1
            ),
            observerDisplayName: "Observer", message: text, workflow: nil
        )
    }

    func testRemoteMCPGoalInLocallyArmedChatStartsComputerUseController() async throws {
        try await assertRemoteMCPGoalStart(locallyArmed: true)
    }

    func testRemoteMCPGoalInUnarmedChatStartsOrdinaryControllerWithoutArming() async throws {
        try await assertRemoteMCPGoalStart(locallyArmed: false)
    }

    func testDeliveredComputerUseCannotArmOrStartControllerInUnarmedChat() async throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        defer { CodexComputerUseWorkflow.setEnabledForTesting(nil) }
        let fixture = try makeSubmissionFixture()
        let vm = fixture.viewModel
        let session = fixture.session
        let sessionID = try installRestoredBinding(fixture)
        _ = try await vm.mcpActivateControlContext(
            forTabID: session.tabID, sessionID: sessionID, originatingConnectionID: nil
        )
        do {
            _ = try await vm.mcpDispatchInstruction(
                sessionID: sessionID, text: "/computer-use inspect the screen", allowStartingRun: true
            )
            XCTFail("Delivered /computer-use must not acquire local consent")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Enable Computer Use in this tab before submitting /computer-use."))
        }
        XCTAssertFalse(session.isCodexComputerUseArmed)
        XCTAssertNil(session.codexController)
        XCTAssertNil(session.codexControllerFeatureState)
        XCTAssertTrue(fixture.factory.controllers.isEmpty)
        XCTAssertEqual(fixture.factory.computerUseEnabledFlags, [])
        XCTAssertTrue(session.items.isEmpty)
    }

    /// These control and delivery tests start with an existing restored app session, even when
    /// its provider conversation is new. Fresh composer creation is exercised separately.
    private func installRestoredBinding(_ fixture: Fixture) throws -> UUID {
        let sessionID = UUID()
        _ = try XCTUnwrap(fixture.viewModel.test_installPersistentSessionBinding(
            sessionID: sessionID, on: fixture.session, updateWorkspaceMetadata: true
        ))
        XCTAssertFalse(fixture.session.permitsBoundOperationAndSave)
        XCTAssertNotNil(fixture.session.operationAdmissionFailureMessage)
        fixture.session.recordRestorationAuthoritative(.persistedPayloadApplied)
        XCTAssertTrue(fixture.session.permitsBoundOperationAndSave)
        XCTAssertNil(fixture.session.operationAdmissionFailureMessage)
        return sessionID
    }

    private func makeSubmissionFixture(
        runtimeUnavailableMessage: @escaping () -> String? = { nil },
        runtimePreflight: (() async -> String?)? = nil
    ) throws -> Fixture {
        let fixture = makeFixture([[.success("submission-thread")]], runtimeUnavailableMessage: runtimeUnavailableMessage, runtimePreflight: runtimePreflight, freshSession: true, shouldManageCodexTooling: false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "CodexResumeWedge.composer.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        store.setModelRouterEnabled(false)
        store.setUsageBalancingEnabled(false)
        store.setAutoEffortEnabled(false)
        fixture.viewModel.modelRouterSettingsStore = store
        addTeardownBlock { @MainActor in
            for session in Array(fixture.viewModel.sessions.values) {
                if let context = session.mcpControlContext {
                    await fixture.viewModel.mcpDeactivateControlContext(sessionID: context.sessionID, cleanupSessionStore: true)
                }
                await fixture.coordinator.shutdownCodexSession(session)
            }
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        return fixture
    }

    private func claimLocalComposerTurn(
        _ text: String,
        session: AgentTabSession,
        viewModel: AgentModeViewModel
    ) throws -> AgentModeViewModel.AgentComposerSubmitClaim {
        let target = try XCTUnwrap(viewModel.makeComposerSubmitTarget(tabID: session.tabID, session: session))
        let attempt = AgentComposerSubmitAttempt(
            id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: text
        )
        guard case let .claimed(claim) = viewModel.claimComposerSubmitAttempt(attempt, requireActiveTabOwnership: true) else {
            throw NSError(domain: "CodexResumeWedge.composerClaim", code: 1)
        }
        return claim
    }

    private func assertComputerUseProviderStart(_ fixture: Fixture, session: AgentTabSession) async throws {
        try await AsyncTestWait.waitUntil("claimed Computer Use turn reaches fake provider", timeout: 4) {
            fixture.factory.controllers.first?.startedTurnCount == 1
        }
        let controller = try XCTUnwrap(fixture.factory.controllers.first)
        XCTAssertEqual(fixture.factory.controllers.count, 1)
        XCTAssertEqual(fixture.factory.computerUseEnabledFlags, [true])
        XCTAssertTrue(session.codexController === controller)
        XCTAssertEqual(session.codexControllerFeatureState?.computerUseEnabled, true)
        XCTAssertEqual(controller.receivedExistingIDs.count, 1)
        XCTAssertEqual(controller.receivedExistingIDs, [nil])
        XCTAssertEqual(controller.startedTurnCount, 1)
        let providerText = try XCTUnwrap(controller.startedTexts.first)
        XCTAssertTrue(providerText.contains("inspect the screen"))
        XCTAssertFalse(session.items.contains { $0.kind == .error })
    }

    private func assertRemoteMCPGoalStart(locallyArmed: Bool) async throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        CodexGoalSupport.setEnabledForTesting(true)
        defer {
            CodexComputerUseWorkflow.setEnabledForTesting(nil)
            CodexGoalSupport.setEnabledForTesting(nil)
        }
        let fixture = try makeSubmissionFixture()
        let vm = fixture.viewModel
        let session = fixture.session
        let sessionID = try installRestoredBinding(fixture)
        if locallyArmed {
            await vm.toggleComputerUse(tabID: session.tabID, expectedSessionIdentity: ObjectIdentifier(session))
            XCTAssertTrue(session.isCodexComputerUseArmed)
        }
        let activationID = session.pendingCodexComputerUseActivation?.id
        _ = try await vm.mcpActivateControlContext(
            forTabID: session.tabID, sessionID: sessionID, originatingConnectionID: nil
        )
        let delivery = try await vm.mcpDispatchInstruction(
            sessionID: sessionID, text: "/goal inspect the screen", allowStartingRun: true
        )
        XCTAssertEqual(delivery, .startedRun)
        try await AsyncTestWait.waitUntil("remote goal reaches fake native controller", timeout: 4) {
            fixture.factory.controllers.first?.goalObjectives == ["inspect the screen"]
                && session.items.contains { $0.text == "Set Codex goal: inspect the screen" }
        }
        let controller = try XCTUnwrap(fixture.factory.controllers.first)
        XCTAssertEqual(fixture.factory.controllers.count, 1)
        XCTAssertEqual(fixture.factory.computerUseEnabledFlags, [locallyArmed])
        XCTAssertEqual(session.codexControllerFeatureState?.computerUseEnabled, locallyArmed)
        XCTAssertTrue(session.codexController === controller)
        XCTAssertEqual(controller.receivedExistingIDs.count, 1)
        XCTAssertEqual(controller.receivedExistingIDs, [nil])
        XCTAssertEqual(controller.goalObjectives, ["inspect the screen"])
        XCTAssertEqual(controller.startedTurnCount, 0, "/goal uses native control, not an ordinary model turn")
        XCTAssertEqual(session.isCodexComputerUseArmed, locallyArmed)
        XCTAssertEqual(session.pendingCodexComputerUseActivation?.id, activationID)
        XCTAssertFalse(session.items.contains { $0.kind == .error })
    }

    func testComputerUseIconOptInCancelArmAndDisarm() async {
        CodexComputerUseWorkflow.setEnabledForTesting(nil)
        let settings = GlobalSettingsStore.shared
        let wasEnabled = settings.codexComputerUseEnabled()
        settings.setCodexComputerUseEnabled(false, commit: false)
        defer { settings.setCodexComputerUseEnabled(wasEnabled, commit: false) }
        var discoveries = 0
        let fixture = makeFixture([], companionReady: { discoveries += 1
            return true
        })
        let session = fixture.session
        let vm = fixture.viewModel
        XCTAssertEqual(vm.currentTabID, session.tabID)
        session.runState = .idle
        let cancelled = await vm.armComputerUseForLocalUser(session: session, confirmOptIn: { false })
        XCTAssertEqual(cancelled, "")
        XCTAssertFalse(settings.codexComputerUseEnabled())
        XCTAssertNil(session.pendingCodexComputerUseActivation)
        XCTAssertEqual(discoveries, 0)
        let accepted = await vm.armComputerUseForLocalUser(session: session, confirmOptIn: { true })
        XCTAssertNil(accepted)
        XCTAssertTrue(settings.codexComputerUseEnabled())
        XCTAssertTrue(vm.computerUseComposerProps(session: session).isOn)
        XCTAssertGreaterThan(discoveries, 0)
        await vm.toggleComputerUse(tabID: session.tabID, expectedSessionIdentity: ObjectIdentifier(session))
        XCTAssertNil(session.pendingCodexComputerUseActivation)
        XCTAssertFalse(vm.computerUseComposerProps(session: session).isOn)
        XCTAssertTrue(settings.codexComputerUseEnabled(), "Per-chat off must not change the global preference")
    }

    func testComputerUsePersistsAcrossCompletedLocalUserTurns() async throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        defer { CodexComputerUseWorkflow.setEnabledForTesting(nil) }
        let fixture = makeFixture([])
        var flags: [Bool] = []
        var controllers: [WedgeFakeCodexController] = []
        let coordinator = makeComputerUseCoordinator(fixture: fixture) { runID, enabled in
            flags.append(enabled)
            let controller = WedgeFakeCodexController(runID: runID, responses: [.success("computer-use-thread")])
            controllers.append(controller)
            return controller
        }
        let session = fixture.session
        var publications = 0
        let barrier = AgentRunTerminalCommitBarrier()
        coordinator.installTerminalCommitBarrier(barrier, terminalSessionBinder: { owned in
            AgentRunTerminalSessionBinding(
                tabID: owned.tabID, lifecycle: owned.runLifecycle,
                hooks: .init(
                    flushPendingAssistantDelta: {},
                    finalizeStreamingItems: {},
                    finalizePendingToolCalls: { _ in },
                    finalizeNonCodexTurnUsage: {},
                    cancelPendingInteractions: { _ in },
                    finalizeAttachments: { _, _ in },
                    setAgentRunInactive: {},
                    prepareTerminalPublication: {},
                    makeTerminalPublicationEnvelope: { _, _, _, _ in nil },
                    updateBindings: {},
                    notifyAgentTurnComplete: {},
                    scheduleSave: {},
                    publishTerminalCommit: { _, _ in publications += 1
                        return .accepted(successorEpoch: nil)
                    },
                    startFollowUpRun: { _ in }
                ),
                validatesOwnership: { owned.isCurrentRunAttemptForCurrentBinding($0, expectedRunID: $1) },
                providerDrainGeneration: { owned.providerTerminalDrainGeneration },
                terminalTurnID: { nil }, queuedFollowUp: { nil }, setFollowUpPending: { _ in },
                removeFirstQueuedFollowUp: { nil }, appendError: { _ in },
                finishActiveState: { ownership, state, source in
                    owned.runState = state
                    _ = owned.endRunAttempt(ifCurrent: ownership, source: source)
                }, retainProcessRunIdentity: { _, _ in }, sourceItemsRevision: { owned.items.count },
                assistantDeltaFlushGeneration: { 0 }, latestFailureText: { nil }
            )
        })
        session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        await coordinator.ensureCodexNativeSession(session: session)
        let controller = try XCTUnwrap(controllers.first)
        session.runState = .idle
        func context(_ local: Bool, origin: AgentTabSession.CodexFallbackOrigin = .manual) -> AgentTabSession.CodexFallbackSubmissionContext {
            .init(queueID: UUID(), providerText: "continue locally", attachments: [], taggedFileAttachments: [], draftText: "continue locally", optimisticUserItemID: nil, origin: origin, dispatchTicket: nil, isLocalUserInput: local)
        }
        let first = await coordinator.sendCodexNativeMessage(session: session, text: "perform the operation", attachments: [], fallbackContext: context(true))
        XCTAssertTrue(first.didSend)
        await coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "computer-use-turn"), session: session, sourceController: controller)
        let permission = AgentApprovalRequest(
            requestID: .codex(.int(90)),
            method: "item/commandExecution/requestApproval",
            kind: .commandExecution,
            threadID: "computer-use-thread",
            turnID: "computer-use-turn",
            itemID: "qa-permission"
        )
        await coordinator.test_handleCodexNativeEvent(.approvalRequest(permission), session: session, sourceController: controller)
        XCTAssertEqual(session.pendingApproval?.id, permission.id)
        XCTAssertEqual(controller.qaResponseCount, 0)
        coordinator.submitApprovalDecision(session: session, decision: .acceptForSession)
        XCTAssertEqual(session.pendingApproval?.id, permission.id, "Remembered permission must remain rejected")
        coordinator.submitApprovalDecision(session: session, decision: .accept)
        try await AsyncTestWait.waitUntil("one explicit permission response", timeout: 4) { controller.qaResponseCount == 1 }
        XCTAssertNil(session.pendingApproval)
        let followUp = await coordinator.sendCodexNativeMessage(session: session, text: "continue locally", attachments: [], fallbackContext: context(true))
        XCTAssertTrue(followUp.didSend, "Plain local input must steer an active Computer Use operation")
        XCTAssertEqual(controller.startedTurnCount, 1)
        XCTAssertEqual(controller.steeredTexts, ["continue locally"])
        for nonLocal in [nil, context(false), context(true, origin: .mcp(attemptID: UUID()))] {
            let result = await coordinator.sendCodexNativeMessage(session: session, text: "untrusted input", attachments: [], fallbackContext: nonLocal)
            XCTAssertTrue(result.didSend, "Local consent authorizes remote turns in the armed chat")
        }
        XCTAssertEqual(controller.steeredTexts, ["continue locally", "untrusted input", "untrusted input", "untrusted input"])
        XCTAssertEqual(controller.startedTurnCount, 1)
        XCTAssertEqual(session.codexControllerFeatureState?.computerUseEnabled, true)

        await coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: "computer-use-turn", status: .completed), session: session, sourceController: controller)
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(session.runState, .completed)
        let activationID = try XCTUnwrap(session.pendingCodexComputerUseActivation?.id)
        XCTAssertTrue(session.codexController === controller)
        XCTAssertEqual(session.codexControllerFeatureState?.computerUseEnabled, true)
        XCTAssertEqual(controller.shutdownCount, 0)
        session.beginRunAttempt(source: "computer-use.next-local-send")
        let next = await coordinator.sendCodexNativeMessage(session: session, text: "ordinary local follow-up", attachments: [], fallbackContext: context(true))
        XCTAssertTrue(next.didSend)
        XCTAssertEqual(flags, [true], "Later local turns must reuse the armed controller without reconnecting")
        XCTAssertEqual(controller.startedTurnCount, 2)
        XCTAssertEqual(session.pendingCodexComputerUseActivation?.id, activationID)
        let nonLocal = await coordinator.sendCodexNativeMessage(session: session, text: "non-local second-turn steer", attachments: [], fallbackContext: context(false))
        XCTAssertTrue(nonLocal.didSend, "Arming authorizes remote input on later turns")
        XCTAssertEqual(controller.startedTurnCount, 2)
        await coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "second-local-turn"), session: session, sourceController: controller)
        await coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: "second-local-turn", status: .completed), session: session, sourceController: controller)
        XCTAssertEqual(session.runState, .completed)
        await coordinator.revokeCodexComputerUse(session: session, reason: "user-off")
        XCTAssertEqual(session.runState, .completed, "Disarming an idle chat must not overwrite successful completion")
        XCTAssertNil(session.pendingCodexComputerUseActivation)
        session.beginRunAttempt(source: "computer-use.disarmed-local-send")
        let ordinary = await coordinator.sendCodexNativeMessage(session: session, text: "ordinary after off", attachments: [], fallbackContext: context(true))
        XCTAssertTrue(ordinary.didSend)
        XCTAssertEqual(flags, [true, false], "An ordinary turn after disarming must have no companion")
        await coordinator.shutdownCodexSession(session)
    }

    func testComputerUseOffAndSettingsOffRevokeBeforeRetirementCompletes() async throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        defer { CodexComputerUseWorkflow.setEnabledForTesting(nil) }
        for trigger in ["command", "setting"] {
            CodexComputerUseWorkflow.setEnabledForTesting(true)
            let fixture = makeFixture([])
            let session = fixture.session
            let otherChat = fixture.viewModel.session(for: UUID())
            otherChat.selectedAgent = .codexExec
            otherChat.runState = .idle
            otherChat.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
            let controller = WedgeFakeCodexController(runID: AgentModeProcessRunIdentity.startFreshProcessRun(for: session), responses: [])
            let gate = TestReleaseFence(name: "session-scoped Computer Use off retirement")
            controller.shutdownGate = gate
            session.codexController = controller
            session.codexControllerFeatureState = .init(computerUseEnabled: true, goalSupportEnabled: false, reasoningSummariesEnabled: false, memoriesEnabled: false, capabilities: .disabled)
            session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
            await fixture.coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "armed-turn"), session: session, sourceController: controller)
            if trigger == "command" {
                let rejected = fixture.viewModel.submitUserTurn(text: "/computer-use off", tabID: session.tabID, isLocalComposerInput: false)
                guard case .blocked = rejected else { return XCTFail("Non-local input cannot toggle Computer Use") }
                XCTAssertTrue(session.isCodexComputerUseArmed)
                XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "/computer-use off", tabID: session.tabID), .submitted)
            } else {
                CodexComputerUseWorkflow.setEnabledForTesting(false)
                CodexComputerUseWorkflow.postDidChangeIfNeeded(previousValue: true, currentValue: false)
                // Re-enabling globally must not undo this chat's revocation or admission fence.
                CodexComputerUseWorkflow.setEnabledForTesting(true)
            }
            XCTAssertFalse(session.codexComputerUseOwnershipTransitionHolds.isEmpty)
            let entered = await gate.waitUntilEntered(timeout: 4)
            XCTAssertTrue(entered)
            XCTAssertFalse(session.isCodexComputerUseArmed)
            XCTAssertNil(session.codexController)
            XCTAssertNil(session.codexControllerFeatureState)
            XCTAssertEqual(controller.interruptedTurnIDs, ["armed-turn"])
            XCTAssertEqual(controller.startedTurnCount, 0, "Off must not dispatch a model turn")
            XCTAssertTrue(fixture.factory.controllers.isEmpty, "Off must not start or reconnect Codex")
            if trigger == "setting" {
                try await AsyncTestWait.waitUntil("Global off disarms every chat", timeout: 4) {
                    !otherChat.isCodexComputerUseArmed
                }
            } else {
                XCTAssertTrue(otherChat.isCodexComputerUseArmed, "Local off affects only this chat")
            }
            gate.release()
            try await AsyncTestWait.waitUntil("Computer Use off retirement releases admission", timeout: 4) {
                controller.shutdownCount == 1 && session.codexComputerUseOwnershipTransitionHolds.isEmpty
            }
            await fixture.coordinator.shutdownCodexSession(session)
        }
    }

    func testComputerUseProviderSwitchRevokesApprovalBeforeAsyncRetirement() async {
        let fixture = makeFixture([])
        let session = fixture.session
        let controller = WedgeFakeCodexController(runID: AgentModeProcessRunIdentity.startFreshProcessRun(for: session), responses: [])
        session.codexController = controller
        session.codexControllerFeatureState = .init(computerUseEnabled: true, goalSupportEnabled: false, reasoningSummariesEnabled: false, memoriesEnabled: false, capabilities: .disabled)
        session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        fixture.coordinator.handleProviderSwitch(from: .codexExec, to: .claudeCode, session: session)
        XCTAssertTrue(controller.computerUseAutoApprovalRevoked, "Provider change must revoke before the retirement task can run")
        XCTAssertFalse(session.isCodexComputerUseArmed)
        await fixture.coordinator.shutdownCodexSession(session)
    }

    func testComputerUseSessionShutdownAndPersistedRestoreDoNotRearm() async throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        defer { CodexComputerUseWorkflow.setEnabledForTesting(nil) }
        let fixture = makeFixture([])
        fixture.session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        var saved = AgentSession(id: UUID(), name: "Computer Use persistence test")
        fixture.coordinator.applyCodexPersistence(from: fixture.session, to: &saved)
        let encoded = try JSONEncoder().encode(saved)
        await fixture.coordinator.shutdownCodexSession(fixture.session)
        XCTAssertFalse(fixture.session.isCodexComputerUseArmed)
        let restored = makeFixture([])
        try restored.coordinator.restoreCodexMetadata(from: JSONDecoder().decode(AgentSession.self, from: encoded), session: restored.session)
        var flags: [Bool] = []
        let coordinator = makeComputerUseCoordinator(fixture: restored) { runID, enabled in
            flags.append(enabled)
            return WedgeFakeCodexController(runID: runID, responses: [.success("restored-thread")])
        }
        await coordinator.ensureCodexNativeSession(session: restored.session)
        XCTAssertFalse(restored.session.isCodexComputerUseArmed)
        XCTAssertEqual(flags, [false], "Restoring the same Codex conversation with the setting on must not restore Computer Use authority")
        await coordinator.shutdownCodexSession(restored.session)
    }

    func testComputerUseMidTurnDisarmInterruptsAndRetiresController() async throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        defer { CodexComputerUseWorkflow.setEnabledForTesting(nil) }
        for reason in ["user-off", "setting-off"] {
            let fixture = makeFixture([])
            _ = try installRestoredBinding(fixture)
            let coordinator = makeComputerUseCoordinator(fixture: fixture) { runID, _ in
                WedgeFakeCodexController(runID: runID, responses: [.success("computer-use-thread")])
            }
            let session = fixture.session
            session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
            await coordinator.ensureCodexNativeSession(session: session)
            let controller = try XCTUnwrap(session.codexController as? WedgeFakeCodexController)
            await coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "computer-use-turn"), session: session, sourceController: controller)
            await coordinator.revokeCodexComputerUse(session: session, reason: reason)
            XCTAssertNil(session.pendingCodexComputerUseActivation)
            XCTAssertNil(session.codexController)
            XCTAssertNil(session.codexControllerFeatureState)
            XCTAssertEqual(session.runState, .failed)
            XCTAssertEqual(controller.interruptedTurnIDs, ["computer-use-turn"])
            XCTAssertEqual(controller.shutdownCount, 1)
            XCTAssertFalse(controller.hasActiveThread)
            XCTAssertEqual(controller.startedTurnCount, 0)
            await coordinator.shutdownCodexSession(session)
        }
    }

    private func makeComputerUseCoordinator(
        fixture: Fixture,
        factory: @escaping (UUID, Bool) -> WedgeFakeCodexController
    ) -> CodexAgentModeCoordinator {
        let coordinator = CodexAgentModeCoordinator(
            windowID: 1, runtimeWorkspacePathsProvider: { _ in .uniform(nil) },
            codexControllerFactory: { runID, _, _, _, _, _, enabled, _ in factory(runID, enabled) },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            shouldManageCodexTooling: false, computerUseRuntimeUnavailableMessage: { nil }, computerUseCompanionReady: { true },
            computerUseReservedEntryExists: { false },
            codexHookApprovalSettings: GlobalSettingsStore.shared
        )
        coordinator.attach(viewModel: fixture.viewModel)
        return coordinator
    }

    func testComputerUseRouteOwnershipLossDuringScopeValidationCannotPublish() async throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        defer { CodexComputerUseWorkflow.setEnabledForTesting(nil) }
        let fixture = makeFixture([])
        let gate = TestReleaseFence(name: "Computer Use final scope validation")
        var routeOwned = true
        var routeChecks = 0
        let coordinator = CodexAgentModeCoordinator(
            windowID: 1, runtimeWorkspacePathsProvider: { _ in .uniform(nil) },
            codexControllerFactory: { runID, _, _, _, _, _, _, _ in
                WedgeFakeCodexController(runID: runID, responses: [.success("uncommitted-computer-use")])
            },
            connectionPolicyInstaller: { clientName, windowID, tools, oneShot, reason, ttl, tabID, runID, additional, purpose, label, externalControl, requiresPID in
                await ServerNetworkManager.shared.installClientConnectionPolicy(
                    for: clientName, windowID: windowID, restrictedTools: tools,
                    oneShot: oneShot, reason: reason, ttl: ttl, tabID: tabID,
                    runID: runID, additionalTools: additional, purpose: purpose,
                    taskLabelKind: label, allowsAgentExternalControlTools: externalControl,
                    requiresExpectedAgentPID: requiresPID
                )
            },
            routeOwnerValidator: { _, _, _, _ in
                routeChecks += 1
                if routeChecks == 2 { await gate.enterAndWait() }
                return routeOwned
            },
            shouldManageCodexTooling: true, computerUseRuntimeUnavailableMessage: { nil }, computerUseCompanionReady: { true },
            computerUseReservedEntryExists: { false }, codexHookApprovalSettings: GlobalSettingsStore.shared
        )
        coordinator.attach(viewModel: fixture.viewModel)
        let session = fixture.session
        session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        let startup = Task { await coordinator.ensureCodexNativeSession(session: session) }
        addTeardownBlock { @MainActor in
            gate.release()
            startup.cancel()
            await startup.value
            await coordinator.shutdownCodexSession(session)
        }
        try await AsyncTestWait.waitUntil("Computer Use pending start", timeout: 4) { coordinator.test_hasPendingCodexStart(for: session) }
        try await MCPRoutingWaiter.shared.notifyRouted(runID: XCTUnwrap(session.runID))
        let entered = await gate.waitUntilEntered(timeout: 4)
        XCTAssertTrue(entered, "Probe must suspend after the lease's original routing ownership check")
        let controller = try XCTUnwrap(session.codexController as? WedgeFakeCodexController)
        routeOwned = false
        gate.release()
        await startup.value
        XCTAssertEqual(session.codexConversationID, Self.oldThreadID)
        XCTAssertFalse(coordinator.test_hasPendingCodexStart(for: session))
        XCTAssertNil(session.codexController)
        XCTAssertEqual(controller.startedTurnCount, 0)
        await coordinator.shutdownCodexSession(session)
    }

    func testComputerUseStaleStartupCannotRetryAgainstSuccessorAttempt() async throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        defer { CodexComputerUseWorkflow.setEnabledForTesting(nil) }
        for replaceRunID in [false, true] {
            let fixture = makeFixture([])
            let gate = TestReleaseFence(name: "Computer Use resume failure")
            let coordinator = makeComputerUseCoordinator(fixture: fixture) { runID, _ in
                WedgeFakeCodexController(runID: runID, responses: [.suspendedMissingRollout(gate), .success("stale-retry")])
            }
            let session = fixture.session
            let activation = AgentModeViewModel.CodexComputerUseActivation(id: UUID(), createdAt: Date())
            session.pendingCodexComputerUseActivation = activation
            let startup = Task { await coordinator.ensureCodexNativeSession(session: session) }
            let entered = await gate.waitUntilEntered(timeout: 4)
            XCTAssertTrue(entered)
            let controller = try XCTUnwrap(session.codexController as? WedgeFakeCodexController)
            session.beginRunAttempt(source: "successor-during-computer-use-startup")
            if replaceRunID { _ = AgentModeProcessRunIdentity.startFreshProcessRun(for: session) }
            let successorRunID = session.runID
            let successorAttemptID = session.activeRunAttemptID
            gate.release()
            await startup.value
            XCTAssertEqual(controller.receivedExistingIDs.count, 1, "A stale caller must not physically retry using its successor's identities")
            XCTAssertEqual(session.runID, successorRunID)
            XCTAssertEqual(session.activeRunAttemptID, successorAttemptID)
            XCTAssertEqual(session.pendingCodexComputerUseActivation?.id, activation.id)
            XCTAssertTrue(session.codexController.map(ObjectIdentifier.init) == ObjectIdentifier(controller))
            XCTAssertEqual(session.codexConversationID, Self.oldThreadID)
            await coordinator.shutdownCodexSession(session)
        }
    }

    func testComputerUseOrdinaryStopBlocksMCPControlUntilRetirementCompletes() async throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        defer { CodexComputerUseWorkflow.setEnabledForTesting(nil) }
        let fixture = makeFixture([])
        let session = fixture.session
        let sessionID = try installRestoredBinding(fixture)
        let controller = WedgeFakeCodexController(
            runID: AgentModeProcessRunIdentity.startFreshProcessRun(for: session), responses: []
        )
        let gate = TestReleaseFence(name: "ordinary Stop companion retirement before MCP control")
        controller.shutdownGate = gate
        session.codexController = controller
        session.codexControllerFeatureState = .init(computerUseEnabled: true, goalSupportEnabled: false, reasoningSummariesEnabled: false, memoriesEnabled: false, capabilities: .disabled)
        session.codexConversationID = "armed-thread"
        session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        let activation = session.pendingCodexComputerUseActivation?.id
        session.beginRunAttempt(source: "armed-stop-test")
        await fixture.coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "armed-turn"), session: session, sourceController: controller)
        addTeardownBlock { @MainActor in
            gate.release()
            await fixture.viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
            await fixture.coordinator.shutdownCodexSession(session)
        }
        await fixture.viewModel.cancelAgentRun(tabID: session.tabID)
        let entered = await gate.waitUntilEntered(timeout: 4)
        XCTAssertTrue(entered)
        XCTAssertNil(session.codexController)
        XCTAssertNil(session.codexControllerFeatureState)
        XCTAssertNotNil(session.pendingCodexComputerUseActivation, "Per-chat arming survives ordinary Stop")
        let generation = session.mcpControlActivationGeneration
        var acquisitionBegan = false
        var acquisitionCompleted = false
        let acquisition = Task {
            acquisitionBegan = true
            let context = try await fixture.viewModel.mcpActivateControlContext(
                forTabID: session.tabID, sessionID: sessionID, originatingConnectionID: nil
            )
            acquisitionCompleted = true
            return context
        }
        addTeardownBlock { @MainActor in
            gate.release()
            _ = try? await acquisition.value
        }
        try await AsyncTestWait.waitUntil("MCP acquisition enters revocation", timeout: 4) { acquisitionBegan }
        XCTAssertFalse(acquisitionCompleted)
        XCTAssertEqual(session.mcpControlActivationGeneration, generation, "Control must not publish before the armed controller stops")
        XCTAssertNil(session.mcpControlContext)
        gate.release()
        _ = try await acquisition.value
        XCTAssertTrue(acquisitionCompleted)
        XCTAssertNotNil(session.mcpControlContext)
        XCTAssertEqual(session.pendingCodexComputerUseActivation?.id, activation)
        XCTAssertEqual(controller.shutdownCount, 1)
        XCTAssertEqual(controller.interruptedTurnIDs, ["armed-turn"])
    }

    func testComputerUseDisarmJoinsAlreadyDetachedCompanionRetirement() async throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        defer { CodexComputerUseWorkflow.setEnabledForTesting(nil) }
        let fixture = makeFixture([])
        let gate = TestReleaseFence(name: "detached companion retirement")
        let coordinator = makeComputerUseCoordinator(fixture: fixture) { runID, _ in
            WedgeFakeCodexController(runID: runID, responses: [.success("computer-use-thread")])
        }
        let session = fixture.session
        session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        await coordinator.ensureCodexNativeSession(session: session)
        let controller = try XCTUnwrap(session.codexController as? WedgeFakeCodexController)
        controller.shutdownGate = gate
        coordinator.clearCodexSessionState(session)
        let entered = await gate.waitUntilEntered(timeout: 4)
        XCTAssertTrue(entered)
        session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        let rearmed = await coordinator.test_computerUseForNextTurn(session: session)
        XCTAssertFalse(rearmed)
        var claimBegan = false
        var claimCompleted = false
        let claim = Task {
            claimBegan = true
            await coordinator.revokeCodexComputerUse(session: session, reason: "setting-off")
            claimCompleted = true
        }
        try await AsyncTestWait.waitUntil("ownership claim begins", timeout: 4) { claimBegan }
        XCTAssertFalse(claimCompleted, "A detached companion must finish retiring before control can publish")
        gate.release()
        await claim.value
        XCTAssertEqual(controller.shutdownCount, 1)
        await coordinator.shutdownCodexSession(session)
    }

    func testComputerUseConcurrentRevocationWaitsForRetirementAndBlocksRearming() async throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        defer { CodexComputerUseWorkflow.setEnabledForTesting(nil) }
        let fixture = makeFixture([])
        let gate = TestReleaseFence(name: "companion shutdown")
        let coordinator = makeComputerUseCoordinator(fixture: fixture) { runID, _ in
            WedgeFakeCodexController(runID: runID, responses: [.success("computer-use-thread")])
        }
        let session = fixture.session
        session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        await coordinator.ensureCodexNativeSession(session: session)
        let controller = try XCTUnwrap(session.codexController as? WedgeFakeCodexController)
        controller.shutdownGate = gate
        let first = Task { await coordinator.revokeCodexComputerUse(session: session, reason: "user-off") }
        let entered = await gate.waitUntilEntered(timeout: 4)
        XCTAssertTrue(entered)
        session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        let rearmed = await coordinator.test_computerUseForNextTurn(session: session)
        XCTAssertFalse(rearmed, "Retirement must block a fresh activation even after the old controller was detached")
        var secondBegan = false
        var secondCompleted = false
        let second = Task {
            secondBegan = true
            await coordinator.revokeCodexComputerUse(session: session, reason: "setting-off")
            secondCompleted = true
        }
        try await AsyncTestWait.waitUntil("second revocation begins", timeout: 4) { secondBegan }
        XCTAssertFalse(secondCompleted, "Already disarmed is not proof that physical retirement has completed")
        gate.release()
        await first.value
        await second.value
        XCTAssertEqual(controller.shutdownCount, 1)
        XCTAssertTrue(session.codexComputerUseOwnershipTransitionHolds.isEmpty)
        XCTAssertEqual(session.codexComputerUseRevocationDepth, 0)
        await coordinator.shutdownCodexSession(session)
    }

    private func waitForPendingStart(_ fixture: Fixture) async throws {
        try await AsyncTestWait.waitUntil("Codex start staged", timeout: 4) {
            fixture.coordinator.test_hasPendingCodexStart(for: fixture.session)
        }
    }

    private func assertOldTuple(_ session: AgentTabSession, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(session.codexConversationID, Self.oldThreadID, file: file, line: line)
        XCTAssertEqual(session.codexRolloutPath, Self.oldRolloutPath, file: file, line: line)
        XCTAssertEqual(session.providerCleanupHandle?.conversationID, Self.oldThreadID, file: file, line: line)
        XCTAssertEqual(session.providerCleanupHandle?.rolloutPath, Self.oldRolloutPath, file: file, line: line)
    }

    func testResumeTimeoutRejectsSendWithOneActionableFailureAndPreservesThread() async throws {
        let fixture = makeFixture([[.timeout], [.timeout], [.discoveryFailure]], authRecovery: MonitorStubCodexAuthRecovery())
        var notifications: [String?] = []
        var reasons: [DomainAgentRunSnapshot.FailureReason?] = []
        fixture.session.appendItem(.user("continue the task"))
        let barrier = AgentRunTerminalCommitBarrier()
        let makeBinding: (AgentTabSession) -> AgentRunTerminalSessionBinding = { owned in
            AgentRunTerminalSessionBinding(
                tabID: owned.tabID, lifecycle: owned.runLifecycle,
                hooks: .init(
                    flushPendingAssistantDelta: {}, finalizeStreamingItems: {}, finalizePendingToolCalls: { _ in },
                    finalizeNonCodexTurnUsage: {}, cancelPendingInteractions: { _ in }, finalizeAttachments: { _, _ in },
                    setAgentRunInactive: {}, prepareTerminalPublication: {},
                    makeTerminalPublicationEnvelope: { _, _, _, _ in nil }, updateBindings: {},
                    notifyAgentTurnComplete: {}, notifyAgentTurnFailed: { notifications.append($0) }, scheduleSave: {},
                    publishTerminalCommit: { revision, _ in
                        reasons.append(revision.failureReason)
                        return .accepted(successorEpoch: nil)
                    }, startFollowUpRun: { _ in }
                ),
                validatesOwnership: { owned.isCurrentRunAttemptForCurrentBinding($0, expectedRunID: $1) },
                providerDrainGeneration: { owned.providerTerminalDrainGeneration },
                terminalTurnID: { owned.items.last(where: { $0.kind == .user })?.id },
                queuedFollowUp: { nil }, setFollowUpPending: { _ in }, removeFirstQueuedFollowUp: { nil },
                appendError: { owned.appendItem(.error($0, sequenceIndex: owned.nextSequenceIndex)) },
                finishActiveState: { ownership, state, source in
                    owned.runState = state
                    _ = owned.endRunAttempt(ifCurrent: ownership, source: source)
                }, retainProcessRunIdentity: { _, _ in }, sourceItemsRevision: { owned.sourceItemsRevision },
                assistantDeltaFlushGeneration: { owned.assistantDeltaFlushGeneration },
                latestFailureText: { AgentTranscriptIO.latestErrorText(from: owned.transcript, latestTurnOnly: true) }
            )
        }
        fixture.coordinator.installTerminalCommitBarrier(barrier, terminalSessionBinder: makeBinding)
        guard case let .failed(message) = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session, text: "continue the task", attachments: []
        ) else { return XCTFail("A timed-out resume must reject the send") }
        assertOldTuple(fixture.session)
        XCTAssertTrue(message.contains("No new thread was started"))
        XCTAssertTrue(message.contains("Retry"))
        XCTAssertTrue(message.contains("Handoff to New Chat"))
        XCTAssertTrue(message.contains("thread/resume: Request timed out after 120.0s"))
        XCTAssertTrue(message.contains("agent_run start with a handoff summary"))
        XCTAssertNil(fixture.session.codexNativeStartupDisposition, "terminal settlement consumes the failure")
        XCTAssertEqual(fixture.session.items.filter { $0.kind == .error }.map(\.text), [message])
        XCTAssertEqual(notifications, [message])
        XCTAssertEqual(reasons.map { $0?.rawValue }, ["resume_timed_out"])
        XCTAssertEqual(fixture.factory.controllers.count, 1)
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
        XCTAssertTrue(fixture.session.codexNeedsReconnect)
        XCTAssertFalse(fixture.coordinator.test_hasPendingCodexStart(for: fixture.session))

        let notice = try XCTUnwrap(fixture.session.items.first { $0.kind == .error })
        XCTAssertEqual(notice.recoveryDiagnostic?.reason, AgentTranscriptRecoveryDiagnostic.resumeTimedOutReason)
        XCTAssertEqual(notice.recoveryDiagnostic?.outcome, AgentTranscriptRecoveryDiagnostic.resumeStoppedOutcome)
        XCTAssertEqual(notice.recoveryDiagnostic?.previousConversationID, Self.oldThreadID)
        XCTAssertNil(notice.recoveryDiagnostic?.replacementConversationID)
        var transcript = AgentTranscriptIO.importLegacyItems([.user("continue the task"), notice], terminalState: .failed)
        transcript.turns[0].retentionTier = .summary
        let compacted = AgentTranscriptCompactor.compact(transcript)
        let restored = try JSONDecoder().decode(AgentTranscript.self, from: JSONEncoder().encode(compacted))
        let projection = AgentTranscriptProjectionBuilder.build(from: restored)
        let retained = (projection.workingRows + projection.archivedRows).filter { $0.id == notice.id }
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.kind, .error)
        XCTAssertEqual(retained.first?.text, notice.text)
        XCTAssertEqual(retained.first?.recoveryDiagnostic?.reason, AgentTranscriptRecoveryDiagnostic.resumeTimedOutReason)
        XCTAssertEqual(retained.first?.recoveryDiagnostic?.outcome, AgentTranscriptRecoveryDiagnostic.resumeStoppedOutcome)
        XCTAssertEqual(AgentTranscriptIO.latestErrorText(from: restored, latestTurnOnly: true), notice.text)
        XCTAssertEqual(DomainAgentRunSnapshot.FailureReason.classify(status: .failed, statusText: notice.text), .resumeTimedOut)
        XCTAssertEqual(DomainAgentRunSnapshot.FailureReason.classify(status: .failed, statusText: "Request timed out after 120.0s"), .timeout)

        // A successful auth refresh followed by a resume timeout must not add login guidance.
        fixture.session.runState = .running
        fixture.session.beginRunAttempt(source: "auth-recovery-timeout")
        _ = AgentModeProcessRunIdentity.startFreshProcessRun(for: fixture.session)
        fixture.session.appendItem(.user("recover auth", sequenceIndex: fixture.session.nextSequenceIndex))
        fixture.session.codexPendingAuthRetryTurn = .init(
            text: "recover auth", attachments: [], model: nil, reasoningEffort: nil, serviceTier: nil,
            attachmentReservationID: nil, expectedTurnID: nil, auditTurnID: nil
        )
        await fixture.coordinator.test_handleCodexNativeEvent(.error("account/chatgptAuthTokens/refresh"), session: fixture.session)
        let authErrors = fixture.session.transcript.turns.last?.allActivities.filter { $0.itemKind == .error } ?? []
        XCTAssertEqual(authErrors.count, 1)
        let authMessage = authErrors.first?.text
        XCTAssertTrue(authMessage?.contains("Prefer Handoff") == true)
        XCTAssertFalse(authMessage?.contains(CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage) == true)
        XCTAssertEqual(notifications, [message, authMessage])
        XCTAssertEqual(reasons, [.resumeTimedOut, .resumeTimedOut])
        XCTAssertNil(fixture.session.codexNativeStartupDisposition)

        // A later, different startup failure must not inherit the timeout classification.
        fixture.session.runState = .running
        fixture.session.beginRunAttempt(source: "retry-after-timeout")
        fixture.session.appendItem(.user("retry the task", sequenceIndex: fixture.session.nextSequenceIndex))
        guard case let .failed(retryMessage) = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session, text: "retry the task", attachments: []
        ) else { return XCTFail("Discovery failure must reject the retry") }
        XCTAssertTrue(retryMessage.contains("Tool catalog not ready"))
        XCTAssertEqual(notifications, [message, authMessage, retryMessage])
        XCTAssertEqual(reasons, [.resumeTimedOut, .resumeTimedOut, .agentError])
        XCTAssertEqual(fixture.session.transcript.turns.last?.allActivities.filter { $0.itemKind == .error }.map(\.text), [retryMessage])
        assertOldTuple(fixture.session)

        // The shared barrier must not use an earlier turn's error for another provider.
        fixture.session.selectedAgent = .claudeCode
        fixture.session.runState = .running
        fixture.session.codexNativeStartupDisposition = .resumeTimedOut
        let ownership = fixture.session.beginRunAttempt(source: "unrelated-provider-failure")
        XCTAssertNil(fixture.session.codexNativeStartupDisposition, "new attempts clear even unconsumed startup failures")
        fixture.session.appendItem(.user("unrelated task", sequenceIndex: fixture.session.nextSequenceIndex))
        _ = await barrier.commit(.init(
            binding: makeBinding(fixture.session), ownership: ownership, expectedRunID: fixture.session.runID,
            terminalState: .failed, source: "test.unrelated-provider",
            attachmentDisposition: .restoreToPending, finalizeNonCodexUsage: false, supportsFollowUp: false,
            notifyTurnComplete: false, providerDrainGeneration: fixture.session.providerTerminalDrainGeneration,
            providerBuffersAreDrained: { true }
        ))
        XCTAssertEqual(notifications, [message, authMessage, retryMessage, nil])
        XCTAssertEqual(reasons, [.resumeTimedOut, .resumeTimedOut, .agentError, .agentError])
    }

    func testRepeatedResumeTimeoutsPreservePersistedTupleAndExplicitRetryResumesSameThread() async throws {
        let fixture = makeFixture([
            [.initializationTimeout], [.timeout], [.timeout], [.success(Self.oldThreadID)]
        ], shouldManageCodexTooling: false)
        for count in 1 ... 3 {
            await fixture.coordinator.ensureCodexNativeSession(session: fixture.session)
            assertOldTuple(fixture.session)
            XCTAssertEqual(fixture.factory.controllers.count, count, "one resume attempt per explicit retry")
            XCTAssertEqual(fixture.factory.controllers.last?.receivedExistingIDs, [Self.oldThreadID])
            XCTAssertEqual(fixture.factory.controllers.last?.startedTurnCount, 0)
            XCTAssertTrue(fixture.session.codexNeedsReconnect)
            XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, count)
            XCTAssertEqual(fixture.session.codexNativeStartupDisposition, .resumeTimedOut)
            let notice = try XCTUnwrap(fixture.session.items.last)
            XCTAssertLessThanOrEqual(notice.text.count, AgentTranscriptRecoveryDiagnostic.maximumTextLength)
            XCTAssertEqual(notice.recoveryDiagnostic?.text, notice.text)
            if count == 1 {
                XCTAssertTrue(notice.text.contains("initialize: Request timed out after"))
                XCTAssertFalse(notice.text.contains("timed out while loading"))
            } else {
                XCTAssertTrue(notice.text.contains("Prefer Handoff"))
                XCTAssertTrue(notice.text.contains("Retry only if conditions improve"))
            }
            XCTAssertFalse(fixture.coordinator.test_hasPendingCodexStart(for: fixture.session))
        }
        try await AsyncTestWait.waitUntil("timed-out controllers retired", timeout: 4) {
            fixture.factory.controllers.allSatisfy { $0.shutdownCount == 1 }
        }
        var saved: AgentSession?
        fixture.viewModel.test_setAgentSessionSaver { agentSession, _, _ in
            saved = agentSession
            return FileManager.default.temporaryDirectory.appendingPathComponent("codex-wedge-\(UUID().uuidString).json")
        }
        await fixture.viewModel.flushSave(for: fixture.session.tabID)
        XCTAssertEqual(saved?.codexConversationID, Self.oldThreadID)
        XCTAssertEqual(saved?.codexRolloutPath, Self.oldRolloutPath)
        XCTAssertEqual(saved?.providerCleanupHandle?.conversationID, Self.oldThreadID)

        await fixture.coordinator.ensureCodexNativeSession(session: fixture.session)
        XCTAssertEqual(fixture.factory.controllers.count, 4)
        XCTAssertEqual(fixture.factory.controllers[3].receivedExistingIDs, [Self.oldThreadID])
        XCTAssertEqual(fixture.session.codexConversationID, Self.oldThreadID)
        XCTAssertEqual(fixture.session.codexNativeStartupDisposition, .resumed)
        XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 0)
        XCTAssertFalse(fixture.session.codexNeedsReconnect)
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })
    }

    func testExplicitRetryAfterTimeoutRenewsAdmissionAndDiscardsOldRoutingSignal() async throws {
        let responseGate = TestReleaseFence(name: "retry response")
        let fixture = makeFixture([
            [.routedTimeout],
            [.suspendedSuccess(Self.oldThreadID, responseGate)]
        ])
        await fixture.coordinator.ensureCodexNativeSession(session: fixture.session)
        assertOldTuple(fixture.session)
        XCTAssertEqual(fixture.factory.controllers.count, 1, "timeout must stop instead of replacing the thread")
        let startup = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer {
            responseGate.release()
            startup.cancel()
        }
        let entered = await responseGate.waitUntilEntered(timeout: 4)
        XCTAssertTrue(entered)
        let runID = try XCTUnwrap(fixture.session.runID)
        let clientName = try XCTUnwrap(AgentProviderKind.codexExec.mcpClientNameHint)
        let staleOutcome = await MCPRoutingWaiter.shared.currentTerminalOutcome(runID: runID)
        XCTAssertNil(staleOutcome, "the retired process's routed signal must not satisfy the retry wait")
        let pendingPolicies = await ServerNetworkManager.shared.debugPendingPolicySnapshot(for: clientName)
        XCTAssertTrue(pendingPolicies.contains { $0.runID == runID }, "retry needs fresh admission")
        assertOldTuple(fixture.session)
        XCTAssertEqual(fixture.factory.controllers[0].shutdownCount, 1)
        XCTAssertEqual(fixture.factory.controllers[1].receivedExistingIDs, [Self.oldThreadID])

        responseGate.release()
        try await waitForPendingStart(fixture)
        assertOldTuple(fixture.session)
        await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
        await startup.value
        XCTAssertEqual(fixture.session.codexConversationID, Self.oldThreadID)
        XCTAssertEqual(fixture.session.providerCleanupHandle?.conversationID, Self.oldThreadID)
        XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 0)
        XCTAssertEqual(fixture.session.codexNativeStartupDisposition, .resumed)
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })
        let retainedPolicies = await ServerNetworkManager.shared.debugPendingPolicySnapshot(for: clientName)
        XCTAssertTrue(retainedPolicies.contains { $0.runID == runID }, "old lease cleanup must not revoke successor admission")
        await ServerNetworkManager.shared.revokeClientConnectionPolicy(for: clientName, windowID: 1, runID: runID)
        await MCPRoutingWaiter.shared.cleanup(runID: runID)
    }

    func testTimeoutAndOversizedResumePoliciesRemainDistinctForSameReference() async {
        let fixture = makeFixture([
            [.timeout], [.oversizedResume], [.success(Self.oldThreadID)]
        ], shouldManageCodexTooling: false)
        await fixture.coordinator.ensureCodexNativeSession(session: fixture.session)
        assertOldTuple(fixture.session)
        XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 1)
        XCTAssertEqual(fixture.session.codexNativeStartupDisposition, .resumeTimedOut)
        XCTAssertNil(fixture.session.codexOversizedResumeTarget)

        await fixture.coordinator.ensureCodexNativeSession(session: fixture.session)
        assertOldTuple(fixture.session)
        XCTAssertEqual(fixture.factory.controllers.count, 2)
        XCTAssertEqual(fixture.factory.controllers.map(\.receivedExistingIDs), [[Self.oldThreadID], [Self.oldThreadID]])
        XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 0)
        XCTAssertNil(fixture.session.codexNativeStartupDisposition, "overflow must not inherit the timeout outcome")
        XCTAssertNotNil(fixture.session.codexOversizedResumeTarget)
        XCTAssertEqual(fixture.session.items.filter { $0.kind == .error }.compactMap { $0.recoveryDiagnostic?.reason }, [
            AgentTranscriptRecoveryDiagnostic.resumeTimedOutReason,
            AgentTranscriptRecoveryDiagnostic.resumeFrameTooLargeReason
        ])
        await fixture.coordinator.ensureCodexNativeSession(session: fixture.session)
        XCTAssertEqual(fixture.factory.controllers.count, 2, "the same oversized target remains blocked")
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })

        fixture.session.codexRolloutPath = "/tmp/changed-reference-after-overflow.jsonl"
        await fixture.coordinator.ensureCodexNativeSession(session: fixture.session)
        XCTAssertEqual(fixture.factory.controllers.count, 3, "a changed target may resume")
        XCTAssertEqual(fixture.factory.controllers[2].receivedExistingIDs, [Self.oldThreadID])
        XCTAssertEqual(fixture.session.codexNativeStartupDisposition, .resumed)
        XCTAssertNil(fixture.session.codexOversizedResumeTarget)
        XCTAssertEqual(fixture.session.codexConversationID, Self.oldThreadID)
    }

    func testOversizedResumeStopsWithoutReplacingTheConversation() async throws {
        let fixture = makeFixture([
            [.oversizedResume],
            [.success("unexpected-replacement")]
        ])
        var reasons: [DomainAgentRunSnapshot.FailureReason?] = []
        var notifications: [String?] = []
        fixture.session.appendItem(.user("continue the current task"))
        fixture.coordinator.installTerminalCommitBarrier(AgentRunTerminalCommitBarrier(), terminalSessionBinder: { owned in
            AgentRunTerminalSessionBinding(
                tabID: owned.tabID, lifecycle: owned.runLifecycle,
                hooks: .init(
                    flushPendingAssistantDelta: {}, finalizeStreamingItems: {}, finalizePendingToolCalls: { _ in },
                    finalizeNonCodexTurnUsage: {}, cancelPendingInteractions: { _ in }, finalizeAttachments: { _, _ in },
                    setAgentRunInactive: {}, prepareTerminalPublication: {},
                    makeTerminalPublicationEnvelope: { _, _, _, _ in nil }, updateBindings: {},
                    notifyAgentTurnComplete: {}, notifyAgentTurnFailed: { notifications.append($0) }, scheduleSave: {},
                    publishTerminalCommit: { revision, _ in
                        reasons.append(revision.failureReason)
                        return .accepted(successorEpoch: nil)
                    }, startFollowUpRun: { _ in }
                ),
                validatesOwnership: { owned.isCurrentRunAttemptForCurrentBinding($0, expectedRunID: $1) },
                providerDrainGeneration: { owned.providerTerminalDrainGeneration },
                terminalTurnID: { owned.items.last(where: { $0.kind == .user })?.id },
                queuedFollowUp: { nil }, setFollowUpPending: { _ in }, removeFirstQueuedFollowUp: { nil },
                appendError: { owned.appendItem(.error($0, sequenceIndex: owned.nextSequenceIndex)) },
                finishActiveState: { ownership, state, source in
                    owned.runState = state
                    _ = owned.endRunAttempt(ifCurrent: ownership, source: source)
                }, retainProcessRunIdentity: { _, _ in }, sourceItemsRevision: { owned.sourceItemsRevision },
                assistantDeltaFlushGeneration: { owned.assistantDeltaFlushGeneration },
                latestFailureText: { AgentTranscriptIO.latestErrorText(from: owned.transcript, latestTurnOnly: true) }
            )
        })
        let send = Task {
            await fixture.coordinator.sendCodexNativeMessage(
                session: fixture.session,
                text: "continue the current task",
                attachments: []
            )
        }
        defer { send.cancel() }
        guard case let .failed(failureText) = await send.value else {
            return XCTFail("An oversized resume must reject the send without dispatch")
        }

        assertOldTuple(fixture.session)
        XCTAssertEqual(fixture.factory.controllers.count, 1, "overflow must not create a taskless replacement")
        XCTAssertEqual(fixture.factory.controllers[0].receivedExistingIDs, [Self.oldThreadID])
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
        try await AsyncTestWait.waitUntil("oversized-resume controller retired", timeout: 4) {
            fixture.factory.controllers[0].shutdownCount == 1
        }
        XCTAssertTrue(fixture.session.codexNeedsReconnect)
        XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 0)
        XCTAssertFalse(fixture.coordinator.test_hasPendingCodexStart(for: fixture.session))
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })
        let notice = try XCTUnwrap(fixture.session.items.first { $0.text.contains("No new thread was started") })
        XCTAssertEqual(failureText, notice.text)
        XCTAssertEqual(fixture.session.items.count(where: { $0.kind == .error }), 1)
        XCTAssertEqual(notifications, [notice.text])
        XCTAssertEqual(reasons, [.resumeHistoryTooLarge])
        XCTAssertTrue(notice.text.contains("Handoff to New Chat"))
        XCTAssertFalse(notice.text.contains("Retry"))
        XCTAssertEqual(notice.recoveryDiagnostic?.reason, AgentTranscriptRecoveryDiagnostic.resumeFrameTooLargeReason)
        XCTAssertEqual(notice.recoveryDiagnostic?.outcome, AgentTranscriptRecoveryDiagnostic.resumeStoppedOutcome)
        XCTAssertEqual(notice.recoveryDiagnostic?.previousConversationID, Self.oldThreadID)
        XCTAssertNil(notice.recoveryDiagnostic?.replacementConversationID)

        var transcript = AgentTranscriptIO.importLegacyItems(
            [.user("continue the current task"), notice],
            terminalState: .completed
        )
        transcript.turns[0].retentionTier = .summary
        let compacted = AgentTranscriptCompactor.compact(transcript)
        let restored = try JSONDecoder().decode(AgentTranscript.self, from: JSONEncoder().encode(compacted))
        let projection = AgentTranscriptProjectionBuilder.build(from: restored)
        let retainedNotices = (projection.workingRows + projection.archivedRows).filter { $0.id == notice.id }
        XCTAssertEqual(retainedNotices.count, 1)
        XCTAssertEqual(retainedNotices.first?.text, notice.text)
        XCTAssertEqual(retainedNotices.first?.kind, .error)
        XCTAssertEqual(retainedNotices.first?.recoveryDiagnostic?.outcome, AgentTranscriptRecoveryDiagnostic.resumeStoppedOutcome)
        XCTAssertEqual(AgentTranscriptIO.latestErrorText(from: restored, latestTurnOnly: true), notice.text)

        fixture.session.runState = .running
        fixture.session.beginRunAttempt(source: "repeat-oversized-send")
        fixture.session.appendItem(.user("continue again", sequenceIndex: fixture.session.nextSequenceIndex))
        guard case let .failed(repeatedText) = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session, text: "continue again", attachments: []
        ) else { return XCTFail("The blocked pair must reject repeat sends") }
        XCTAssertEqual(repeatedText, notice.text)
        XCTAssertEqual(fixture.factory.controllers.count, 1, "a known oversized pair must not launch another app-server")
        XCTAssertEqual(fixture.session.items.count(where: { $0.kind == .error }), 2)
        XCTAssertEqual(fixture.session.transcript.turns.last?.allActivities.count(where: { $0.itemKind == .error }), 1)
        XCTAssertEqual(AgentTranscriptIO.latestErrorText(from: fixture.session.transcript, latestTurnOnly: true), notice.text)
        XCTAssertEqual(notifications, [notice.text, notice.text])
        XCTAssertEqual(reasons, [.resumeHistoryTooLarge, .resumeHistoryTooLarge])
    }

    func testOversizedResumeCompactAndRecoveryStopWithoutAutomaticFallback() async {
        for recovering in [false, true] {
            let fixture = makeFixture([[.oversizedResume], [.success(Self.oldThreadID)]], shouldManageCodexTooling: false)
            if recovering {
                _ = AgentModeProcessRunIdentity.startFreshProcessRun(for: fixture.session)
                let failed = await fixture.coordinator.test_attemptCodexStreamRecovery(session: fixture.session)
                XCTAssertTrue(failed)
            } else {
                fixture.session.runState = .idle
                let result = await fixture.coordinator.executeNativeSlashCommand(.compact, argumentsText: "", session: fixture.session)
                guard case let .failed(message) = result else { return XCTFail("Oversized /compact must fail") }
                XCTAssertTrue(message.contains("Handoff to New Chat"))
            }
            assertOldTuple(fixture.session)
            XCTAssertEqual(fixture.factory.controllers.count, 1)
            XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
            XCTAssertEqual(fixture.factory.controllers[0].compactCount, 0)
            let errors = fixture.session.items.filter { $0.kind == .error }
            XCTAssertEqual(errors.count, 1)
            XCTAssertEqual(errors.first?.recoveryDiagnostic?.outcome, AgentTranscriptRecoveryDiagnostic.resumeStoppedOutcome)
            if recovering {
                let failed = await fixture.coordinator.test_attemptCodexStreamRecovery(session: fixture.session)
                XCTAssertTrue(failed)
            } else {
                _ = await fixture.coordinator.executeNativeSlashCommand(.compact, argumentsText: "", session: fixture.session)
            }
            XCTAssertEqual(fixture.factory.controllers.count, 1, "repeat control/recovery must skip the blocked pair")
            XCTAssertEqual(fixture.session.items.count(where: { $0.kind == .error }), 1)

            fixture.session.codexRolloutPath = "/tmp/changed-rollout.jsonl"
            await fixture.coordinator.ensureCodexNativeSession(session: fixture.session)
            XCTAssertEqual(fixture.factory.controllers.count, 2, "a changed rollout must not inherit the old pair's block")
            XCTAssertEqual(fixture.factory.controllers[1].receivedExistingIDs, [Self.oldThreadID])
            XCTAssertNil(fixture.session.codexOversizedResumeTarget)
        }
    }

    func testSettledOldLeaseCannotRevokeSameRunSuccessor() async {
        let runID = UUID()
        let tabID = UUID()
        let clearGate = TestReleaseFence(name: "old permit revocation")
        let oldLease = MCPBootstrapLease(
            spec: .agentMode(tabID: tabID, runID: runID, gateID: UUID(), windowID: 1, agent: .codexExec),
            policyClearer: { spec in
                await clearGate.enterAndWait()
                await ServerNetworkManager.shared.revokeClientConnectionPolicy(
                    for: AgentProviderKind.codexMCPClientID,
                    windowID: spec.windowID,
                    runID: spec.runID
                )
            }
        )
        let acquired = await oldLease.acquire()
        XCTAssertTrue(acquired)
        let firstCleanup = Task { await oldLease.cancelAndCleanup() }
        defer { clearGate.release() }
        let entered = await clearGate.waitUntilEntered(timeout: 4)
        XCTAssertTrue(entered)
        let secondCleanup = Task { await oldLease.cancelAndCleanup() }
        _ = await oldLease.debugWaitForPolicyClearJoiner()
        clearGate.release()
        await firstCleanup.value
        await secondCleanup.value

        let successor = MCPBootstrapLease(
            spec: .agentMode(tabID: tabID, runID: runID, gateID: UUID(), windowID: 1, agent: .codexExec)
        )
        let successorAcquired = await successor.acquire()
        XCTAssertTrue(successorAcquired)
        await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
        await oldLease.cancelAndCleanup()
        let pending = await hasPendingPolicy(for: runID)
        XCTAssertTrue(pending, "settled predecessor must not clear the successor permit")
        let outcome = await MCPRoutingWaiter.shared.currentTerminalOutcome(runID: runID)
        XCTAssertEqual(outcome, .routed, "settled predecessor must not fail or remove the successor waiter")
        await successor.cancelAndCleanup()
    }

    func testMissingRolloutFreshStartTimeoutPreservesTupleWithoutStoppedResumeClaim() async {
        let fixture = makeFixture([[.missingRollout, .startTimeout]], shouldManageCodexTooling: false)
        var notifications: [String?] = []
        var reasons: [DomainAgentRunSnapshot.FailureReason?] = []
        fixture.session.appendItem(.user("continue the task"))
        let barrier = AgentRunTerminalCommitBarrier()
        let makeBinding: (AgentTabSession) -> AgentRunTerminalSessionBinding = { owned in
            AgentRunTerminalSessionBinding(
                tabID: owned.tabID, lifecycle: owned.runLifecycle,
                hooks: .init(
                    flushPendingAssistantDelta: {}, finalizeStreamingItems: {}, finalizePendingToolCalls: { _ in },
                    finalizeNonCodexTurnUsage: {}, cancelPendingInteractions: { _ in }, finalizeAttachments: { _, _ in },
                    setAgentRunInactive: {}, prepareTerminalPublication: {},
                    makeTerminalPublicationEnvelope: { _, _, _, _ in nil }, updateBindings: {},
                    notifyAgentTurnComplete: {}, notifyAgentTurnFailed: { notifications.append($0) }, scheduleSave: {},
                    publishTerminalCommit: { revision, _ in
                        reasons.append(revision.failureReason)
                        return .accepted(successorEpoch: nil)
                    }, startFollowUpRun: { _ in }
                ),
                validatesOwnership: { owned.isCurrentRunAttemptForCurrentBinding($0, expectedRunID: $1) },
                providerDrainGeneration: { owned.providerTerminalDrainGeneration },
                terminalTurnID: { owned.items.last(where: { $0.kind == .user })?.id },
                queuedFollowUp: { nil }, setFollowUpPending: { _ in }, removeFirstQueuedFollowUp: { nil },
                appendError: { owned.appendItem(.error($0, sequenceIndex: owned.nextSequenceIndex)) },
                finishActiveState: { ownership, state, source in
                    owned.runState = state
                    _ = owned.endRunAttempt(ifCurrent: ownership, source: source)
                }, retainProcessRunIdentity: { _, _ in }, sourceItemsRevision: { owned.sourceItemsRevision },
                assistantDeltaFlushGeneration: { owned.assistantDeltaFlushGeneration },
                latestFailureText: { AgentTranscriptIO.latestErrorText(from: owned.transcript, latestTurnOnly: true) }
            )
        }
        fixture.coordinator.installTerminalCommitBarrier(barrier, terminalSessionBinder: makeBinding)
        guard case let .failed(message) = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session, text: "continue the task", attachments: []
        ) else { return XCTFail("An unconfirmed fresh start must reject the send") }
        assertOldTuple(fixture.session)
        XCTAssertTrue(message.contains("thread/start: Request timed out after 120.0s"))
        XCTAssertTrue(message.contains("a new thread may have been created"))
        XCTAssertTrue(message.contains("original conversation was retained and no user turn was sent"))
        XCTAssertFalse(message.contains("No new thread was started"))
        XCTAssertFalse(message.contains("Codex native resume failed"))
        XCTAssertEqual(fixture.session.items.filter { $0.kind == .error }.map(\.text), [message])
        XCTAssertEqual(notifications, [message])
        XCTAssertEqual(reasons.count, 1)
        XCTAssertFalse(reasons.contains { $0 == .resumeTimedOut })
        XCTAssertNil(fixture.session.items.last?.recoveryDiagnostic)
        XCTAssertNil(fixture.session.codexNativeStartupDisposition)
        XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 0)
        XCTAssertEqual(fixture.factory.controllers.count, 1)
        XCTAssertEqual(fixture.factory.controllers[0].receivedExistingIDs, [Self.oldThreadID, nil])
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
        XCTAssertTrue(fixture.session.codexNeedsReconnect)
        XCTAssertFalse(fixture.coordinator.test_hasPendingCodexStart(for: fixture.session))
    }

    func testRoutingSuccessCommitsFreshFallbackExactlyOnce() async throws {
        let fixture = makeFixture([[.missingRollout, .success("ready-fresh-thread")]])
        let startup = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer { startup.cancel() }
        try await waitForPendingStart(fixture)
        assertOldTuple(fixture.session)
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })
        try await MCPRoutingWaiter.shared.notifyRouted(runID: XCTUnwrap(fixture.session.runID))
        await startup.value

        XCTAssertEqual(fixture.session.codexConversationID, "ready-fresh-thread")
        XCTAssertNil(fixture.session.codexRolloutPath, "a pre-turn fresh thread may not have a rollout yet")
        XCTAssertEqual(fixture.session.providerCleanupHandle?.conversationID, "ready-fresh-thread")
        XCTAssertFalse(fixture.session.codexNeedsReconnect)
        XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 0)
        XCTAssertEqual(fixture.session.items.count(where: { $0.text.contains("Started a fresh thread") }), 1)
        XCTAssertFalse(fixture.coordinator.test_hasPendingCodexStart(for: fixture.session))

        fixture.session.runState = .idle
        await fixture.coordinator.ensureCodexNativeSession(session: fixture.session)
        XCTAssertEqual(fixture.factory.controllers.count, 1)
        XCTAssertEqual(fixture.factory.controllers[0].receivedExistingIDs, [Self.oldThreadID, nil])
        XCTAssertEqual(fixture.session.items.count(where: { $0.text.contains("Started a fresh thread") }), 1)
    }

    func testSecondCallerCannotBypassUnpublishedStartup() async throws {
        let gate = TestReleaseFence(name: "first Codex start response")
        let fixture = makeFixture([[.suspendedSuccess("claimed-thread", gate)]])
        let startup = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer {
            gate.release()
            startup.cancel()
        }
        let entered = await gate.waitUntilEntered(timeout: 4)
        XCTAssertTrue(entered)
        await fixture.coordinator.ensureCodexNativeSession(session: fixture.session)
        let secondSend = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "duplicate",
            attachments: []
        )
        if case .preDispatchRejected = secondSend {} else {
            XCTFail("a second send must be rejected before turn dispatch")
        }
        XCTAssertEqual(fixture.factory.controllers.count, 1)
        XCTAssertEqual(fixture.factory.controllers[0].receivedExistingIDs, [Self.oldThreadID])
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
        assertOldTuple(fixture.session)

        gate.release()
        try await waitForPendingStart(fixture)
        try await MCPRoutingWaiter.shared.notifyRouted(runID: XCTUnwrap(fixture.session.runID))
        await startup.value
        XCTAssertEqual(fixture.session.codexConversationID, "claimed-thread")
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
    }

    func testCancellationAndSuccessorCannotPublishStagedThread() async throws {
        let cancelled = makeFixture([[.success("cancelled-fresh")]])
        let cancelledTask = Task { await cancelled.coordinator.ensureCodexNativeSession(session: cancelled.session) }
        try await waitForPendingStart(cancelled)
        cancelledTask.cancel()
        await cancelledTask.value
        assertOldTuple(cancelled.session)
        XCTAssertFalse(cancelled.coordinator.test_hasPendingCodexStart(for: cancelled.session))
        XCTAssertFalse(cancelled.session.items.contains { $0.text.contains("Started a fresh thread") })

        let successor = makeFixture([[.success("stale-fresh")]])
        let staleTask = Task { await successor.coordinator.ensureCodexNativeSession(session: successor.session) }
        defer { staleTask.cancel() }
        try await waitForPendingStart(successor)
        let staleRunID = try XCTUnwrap(successor.session.runID)
        successor.session.installRunID(UUID())
        await MCPRoutingWaiter.shared.notifyRouted(runID: staleRunID)
        await staleTask.value
        assertOldTuple(successor.session)
        XCTAssertFalse(successor.coordinator.test_hasPendingCodexStart(for: successor.session))
        XCTAssertFalse(successor.session.items.contains { $0.text.contains("Started a fresh thread") })
        XCTAssertEqual(successor.factory.controllers[0].startedTurnCount, 0)
    }

    func testInheritedRoutedOutcomeCannotCommitWithoutCurrentControllerRoute() async throws {
        let fixture = makeFixture(
            [[.success("unrouted-fresh-thread")]],
            routeOwnerValidator: { _, _, _, _ in false }
        )
        fixture.session.codexNativeStartupDisposition = .resumed
        let startup = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer { startup.cancel() }
        try await waitForPendingStart(fixture)
        let runID = try XCTUnwrap(fixture.session.runID)
        let policyWasInstalled = await hasPendingPolicy(for: runID)
        XCTAssertTrue(policyWasInstalled)
        await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
        await startup.value

        assertOldTuple(fixture.session)
        let policyWasCleared = await hasPendingPolicy(for: runID)
        XCTAssertFalse(policyWasCleared)
        XCTAssertNil(fixture.session.codexNativeStartupDisposition)
        XCTAssertNil(fixture.session.codexController)
        XCTAssertFalse(fixture.session.codexNeedsReconnect)
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })
    }

    func testCancellationDuringRouteOwnerCheckCleansPolicyAndUncommittedController() async throws {
        let gate = TestReleaseFence(name: "Codex route owner check")
        let fixture = makeFixture(
            [[.success("cancelled-owner-thread")]],
            routeOwnerValidator: { _, _, _, _ in
                await gate.enterAndWait()
                return true
            }
        )
        let startup = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer {
            gate.release()
            startup.cancel()
        }
        try await waitForPendingStart(fixture)
        let runID = try XCTUnwrap(fixture.session.runID)
        await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
        let ownerCheckEntered = await gate.waitUntilEntered(timeout: 4)
        XCTAssertTrue(ownerCheckEntered)
        startup.cancel()
        gate.release()
        await startup.value

        assertOldTuple(fixture.session)
        let policyWasCleared = await hasPendingPolicy(for: runID)
        XCTAssertFalse(policyWasCleared)
        XCTAssertNil(fixture.session.codexController)
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
    }

    private func hasPendingPolicy(for runID: UUID) async -> Bool {
        guard let clientName = AgentProviderKind.codexExec.mcpClientNameHint else { return false }
        let policies = await ServerNetworkManager.shared.debugPendingPolicySnapshot(for: clientName)
        return policies.contains { $0.runID == runID }
    }

    func testAlreadyInstalledPolicyRecoveryStillStagesUntilRouting() async throws {
        let fixture = makeFixture([[.success("event-recovery-thread")]])
        let startup = Task {
            await fixture.coordinator.ensureCodexNativeSession(
                session: fixture.session,
                policyAlreadyInstalled: true,
                preserveExistingRunID: true
            )
        }
        defer { startup.cancel() }
        try await waitForPendingStart(fixture)
        assertOldTuple(fixture.session)
        try await MCPRoutingWaiter.shared.notifyFailed(runID: XCTUnwrap(fixture.session.runID))
        await startup.value
        assertOldTuple(fixture.session)
        XCTAssertNil(fixture.session.codexController)
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
    }

    func testSameRunAttemptDriftRetiresOnlyUncommittedControllerBeforeLaterSend() async throws {
        let fixture = makeFixture([
            [.success("drifted-fresh-thread")],
            [.success("later-fresh-thread")]
        ])
        fixture.session.appendItem(.system("Earlier Codex history", sequenceIndex: fixture.session.nextSequenceIndex))
        let startup = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer { startup.cancel() }
        try await waitForPendingStart(fixture)
        let runID = try XCTUnwrap(fixture.session.runID)
        fixture.session.beginRunAttempt(source: "same-run-successor")
        XCTAssertEqual(fixture.session.runID, runID)
        await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
        await startup.value

        assertOldTuple(fixture.session)
        XCTAssertNil(fixture.session.codexController)
        XCTAssertFalse(fixture.coordinator.test_hasPendingCodexStart(for: fixture.session))
        try await AsyncTestWait.waitUntil("uncommitted Codex controller retired", timeout: 4) {
            fixture.factory.controllers[0].shutdownCount == 1
        }
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)

        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "later-send")
        let later = Task {
            await fixture.coordinator.sendCodexNativeMessage(
                session: fixture.session,
                text: "continue",
                attachments: []
            )
        }
        defer { later.cancel() }
        try await waitForPendingStart(fixture)
        XCTAssertEqual(fixture.factory.controllers[1].receivedExistingIDs, [Self.oldThreadID])
        try await MCPRoutingWaiter.shared.notifyFailed(runID: XCTUnwrap(fixture.session.runID))
        _ = await later.value
        assertOldTuple(fixture.session)
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
        XCTAssertEqual(fixture.factory.controllers[1].startedTurnCount, 0)
    }

    func testAttemptDriftDoesNotRetireSuccessorController() async throws {
        let fixture = makeFixture([[.success("stale-fresh-thread")]])
        let startup = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer { startup.cancel() }
        try await waitForPendingStart(fixture)
        let runID = try XCTUnwrap(fixture.session.runID)
        fixture.session.beginRunAttempt(source: "successor-controller")
        let successor = WedgeFakeCodexController(runID: runID, responses: [])
        fixture.session.codexController = successor
        await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
        await startup.value

        assertOldTuple(fixture.session)
        XCTAssertEqual(fixture.session.codexController.map(ObjectIdentifier.init), ObjectIdentifier(successor))
        XCTAssertEqual(successor.shutdownCount, 0)
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
    }

    func testResolveRolloutPathClassifierIsNarrow() {
        let ref = CodexNativeSessionController.SessionRef(
            conversationID: Self.oldThreadID,
            rolloutPath: Self.oldRolloutPath,
            model: nil,
            reasoningEffort: nil
        )
        let classifier: (CodexNativeSessionController.SessionRef?, String) -> Bool = { reference, message in
            CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
                existingRef: reference,
                errorDescription: message
            )
        }
        XCTAssertTrue(classifier(ref, Self.missingRolloutMessage))
        XCTAssertTrue(classifier(ref, "  FAILED TO RESOLVE ROLLOUT PATH /tmp/old-committed-rollout.jsonl: FILE DOES NOT EXIST.  "))
        XCTAssertFalse(classifier(ref, "failed to resolve rollout path /tmp/other-rollout.jsonl: file does not exist"))
        let mixedCaseRef = CodexNativeSessionController.SessionRef(
            conversationID: Self.oldThreadID,
            rolloutPath: "/tmp/CaseSensitive.jsonl",
            model: nil,
            reasoningEffort: nil
        )
        XCTAssertTrue(classifier(mixedCaseRef, "failed to resolve rollout path /tmp/CaseSensitive.jsonl: file does not exist"))
        XCTAssertFalse(classifier(mixedCaseRef, "failed to resolve rollout path /tmp/casesensitive.jsonl: file does not exist"))
        XCTAssertTrue(classifier(
            .init(conversationID: Self.oldThreadID, rolloutPath: nil, model: nil, reasoningEffort: nil),
            "failed to resolve rollout path /tmp/other-rollout.jsonl: file does not exist"
        ))
        XCTAssertTrue(classifier(ref, "no rollout found for thread id old-committed-thread"))
        XCTAssertFalse(classifier(nil, Self.missingRolloutMessage))
        XCTAssertFalse(classifier(ref, "failed to resolve workspace path /tmp/x: file does not exist"))
        XCTAssertFalse(classifier(ref, "failed to resolve rollout path /tmp/x: permission denied"))
        XCTAssertFalse(classifier(ref, "warning: failed to resolve rollout path /tmp/x: file does not exist"))
        XCTAssertFalse(classifier(ref, "failed to resolve rollout path /tmp/x: file does not exist; check permissions"))
        XCTAssertTrue(CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
            existingRef: ref,
            method: "thread/resume",
            code: -32600,
            message: Self.missingRolloutMessage
        ))
        XCTAssertFalse(CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
            existingRef: ref,
            method: "thread/resume",
            code: -32600,
            message: "failed to resolve rollout path /tmp/other-rollout.jsonl: file does not exist"
        ))
        XCTAssertFalse(CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
            existingRef: mixedCaseRef,
            method: "thread/resume",
            code: -32600,
            message: "failed to resolve rollout path /tmp/casesensitive.jsonl: file does not exist"
        ))
        XCTAssertFalse(CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
            existingRef: mixedCaseRef,
            method: "config/read",
            code: -32600,
            message: "failed to resolve rollout path /tmp/CaseSensitive.jsonl: file does not exist"
        ))
        XCTAssertFalse(CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
            existingRef: mixedCaseRef,
            method: "config/read",
            code: -32600,
            message: "failed to resolve rollout path /tmp/casesensitive.jsonl: file does not exist"
        ))
        XCTAssertFalse(CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
            existingRef: ref,
            method: "config/read",
            code: -32600,
            message: Self.missingRolloutMessage
        ))
        XCTAssertFalse(CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
            existingRef: ref,
            method: "thread/resume",
            code: -32602,
            message: Self.missingRolloutMessage
        ))
    }
}

private final class WedgeControllerFactory {
    private var plans: [[WedgeFakeCodexController.Response]]
    private(set) var controllers: [WedgeFakeCodexController] = []
    private(set) var computerUseEnabledFlags: [Bool] = []

    init(plans: [[WedgeFakeCodexController.Response]]) {
        self.plans = plans
    }

    func make(runID: UUID, computerUseEnabled: Bool = false) -> WedgeFakeCodexController {
        computerUseEnabledFlags.append(computerUseEnabled)
        let controller = WedgeFakeCodexController(
            runID: runID,
            responses: plans.isEmpty ? [] : plans.removeFirst()
        )
        controllers.append(controller)
        return controller
    }
}

final class WedgeFakeCodexController: CodexSessionControllerPassiveStubDefaults, @unchecked Sendable {
    enum Response {
        case timeout
        case initializationTimeout
        case startTimeout
        case discoveryFailure
        case policyRequiredResume
        case routedThenResumeFailure(TestReleaseFence)
        case routedTimeout
        case missingRollout
        case oversizedResume
        case suspendedSuccess(String, TestReleaseFence)
        case suspendedMissingRollout(TestReleaseFence)
        case success(String)
    }

    let runID: UUID
    private let lock = NSLock()
    private var responses: [Response]
    private var existingIDs: [String?] = []
    private var active = false
    private var turnCount = 0
    private var compactions = 0
    private var turnTexts: [String] = []
    private var goals: [String] = []
    private var steers: [String] = []
    private var interrupts: [String] = []
    private var shutdowns = 0
    private var qaResponses = 0
    private var recoverySnapshot: CodexNativeSessionController.ThreadSnapshot?
    private var recoverySnapshotGate: TestReleaseFence?

    func setRecoverySnapshot(_ snapshot: CodexNativeSessionController.ThreadSnapshot, gate: TestReleaseFence? = nil) {
        lock.withLock {
            recoverySnapshot = snapshot
            recoverySnapshotGate = gate
            active = true
        }
    }

    func readThreadSnapshot(includeTurns _: Bool, timeout _: TimeInterval?) async throws -> CodexNativeSessionController.ThreadSnapshot {
        let (snapshot, gate) = lock.withLock { (recoverySnapshot, recoverySnapshotGate) }
        if let gate { await gate.enterAndWait() }
        return snapshot ?? .init(
            conversationID: "fake", rolloutPath: nil, model: nil, reasoningEffort: nil,
            runtimeStatus: .idle, currentTurnID: nil, activeTurnIDs: [], latestTurnStatus: nil
        )
    }

    var qaResponseCount: Int {
        lock.withLock { qaResponses }
    }

    private var qaAnswers: [String: [String]] = [:]
    var qaUserInputAnswers: [String: [String]] {
        lock.withLock { qaAnswers }
    }

    func respondToServerRequest(id _: CodexAppServerRequestID, result: [String: Any]) async {
        lock.withLock {
            qaResponses += 1
            if let answers = result["answers"] as? [String: [String: Any]] {
                qaAnswers = answers.compactMapValues { $0["answers"] as? [String] }
            }
        }
    }

    var computerUseAutoApprovalRevoked = false
    var shutdownGate: TestReleaseFence?
    private let continuation: AsyncStream<CodexNativeSessionController.Event>.Continuation
    let events: AsyncStream<CodexNativeSessionController.Event>

    init(runID: UUID, responses: [Response]) {
        self.runID = runID
        self.responses = responses
        var storedContinuation: AsyncStream<CodexNativeSessionController.Event>.Continuation!
        events = AsyncStream { storedContinuation = $0 }
        continuation = storedContinuation
    }

    var hasActiveThread: Bool {
        lock.withLock { active }
    }

    var receivedExistingIDs: [String?] {
        lock.withLock { existingIDs }
    }

    var startedTurnCount: Int {
        lock.withLock { turnCount }
    }

    var compactCount: Int {
        lock.withLock { compactions }
    }

    var startedTexts: [String] {
        lock.withLock { turnTexts }
    }

    var goalObjectives: [String] {
        lock.withLock { goals }
    }

    func setThreadGoalObjective(_ objective: String) async throws -> CodexNativeSessionController.ThreadGoal {
        lock.withLock { goals.append(objective) }
        return .init(
            threadID: "submission-thread", objective: objective, status: .active,
            tokenBudget: nil, tokensUsed: 0, timeUsedSeconds: 0, createdAt: 0, updatedAt: 0
        )
    }

    var steeredTexts: [String] {
        lock.withLock { steers }
    }

    var interruptedTurnIDs: [String] {
        lock.withLock { interrupts }
    }

    var shutdownCount: Int {
        lock.withLock { shutdowns }
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        let response = lock.withLock { () -> Response? in
            existingIDs.append(existing?.conversationID)
            return responses.isEmpty ? nil : responses.removeFirst()
        }
        switch response {
        case .routedTimeout:
            // Model a permit pruned during the slow resume, with readiness already cached
            // from the retired process. Neither may authorize the replacement process.
            await ServerNetworkManager.shared.revokeClientConnectionPolicy(
                for: AgentProviderKind.codexMCPClientID,
                windowID: 1,
                runID: runID
            )
            await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
            throw CodexAppServerClient.ClientError.requestFailed(.init(
                method: "thread/resume",
                code: nil,
                message: "Request timed out after 120.0s",
                data: nil
            ))
        case .initializationTimeout:
            throw CodexAppServerClient.ClientError.requestFailed(.init(
                method: "initialize", code: nil, message: "Request timed out after 30.0s", data: nil
            ))
        case .startTimeout:
            // Model the actual fresh binding request, not a resume failure with a nil input.
            throw CodexAppServerClient.ClientError.requestFailed(.init(
                method: "thread/start", code: nil, message: "Request timed out after 120.0s", data: nil
            ))
        case .timeout:
            throw CodexAppServerClient.ClientError.requestFailed(.init(
                method: "thread/resume",
                code: nil,
                message: "Request timed out after 120.0s",
                data: nil
            ))
        case .discoveryFailure:
            throw CodexAppServerClient.ClientError.requestFailed(.init(
                method: existing == nil ? "thread/start" : "thread/resume",
                code: -32603,
                message: "Failed to initialize session: required MCP servers failed to initialize: RepoPromptCE: Tool catalog not ready. Please retry.",
                data: nil
            ))
        case let .routedThenResumeFailure(gate):
            await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
            await gate.enterAndWait()
            throw CodexAppServerClient.ClientError.requestFailed(.init(
                method: "thread/resume",
                code: -32603,
                message: "Non-timeout resume failure after routing",
                data: nil
            ))
        case .policyRequiredResume:
            guard let clientName = AgentProviderKind.codexExec.mcpClientNameHint else {
                throw CodexAppServerClient.ClientError.invalidResponse
            }
            let policies = await ServerNetworkManager.shared.debugPendingPolicySnapshot(for: clientName)
            guard policies.contains(where: { $0.runID == runID && $0.purpose == .agentModeRun }),
                  let existing
            else { throw CodexAppServerClient.ClientError.invalidResponse }
            lock.withLock { active = true }
            return existing
        case .oversizedResume:
            throw CodexAppServerClient.ClientError.stdoutFrameBudgetExceeded(limitBytes: 64 * 1024 * 1024)
        case let .suspendedMissingRollout(gate):
            await gate.enterAndWait()
            throw CodexAppServerClient.ClientError.requestFailed(.init(
                method: "thread/resume", code: -32600,
                message: "failed to resolve rollout path /tmp/old-committed-rollout.jsonl: file does not exist", data: nil
            ))
        case .missingRollout:
            throw CodexAppServerClient.ClientError.requestFailed(.init(
                method: "thread/resume",
                code: -32600,
                message: "failed to resolve rollout path /tmp/old-committed-rollout.jsonl: file does not exist",
                data: nil
            ))
        case let .suspendedSuccess(threadID, gate):
            await gate.enterAndWait()
            lock.withLock { active = true }
            return CodexNativeSessionController.SessionRef(
                conversationID: threadID,
                rolloutPath: nil,
                model: model,
                reasoningEffort: reasoningEffort
            )
        case let .success(threadID):
            lock.withLock { active = true }
            return CodexNativeSessionController.SessionRef(
                conversationID: threadID,
                rolloutPath: nil,
                model: model,
                reasoningEffort: reasoningEffort
            )
        case nil:
            throw CodexAppServerClient.ClientError.invalidResponse
        }
    }

    func startUserTurn(
        text: String,
        attachments _: [AgentFileAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        let count = lock.withLock { () -> Int in
            turnTexts.append(text)
            turnCount += 1
            return turnCount
        }
        return CodexTurnStartReceipt(provisionalSubmissionID: "fake-turn-\(count)")
    }

    func compactThread() async throws {
        lock.withLock { compactions += 1 }
    }

    func steerUserTurn(text: String, attachments _: [AgentFileAttachment], expectedTurnID: String) async throws -> CodexTurnSteerReceipt {
        lock.withLock { steers.append(text) }
        return CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        lock.withLock { interrupts.append(expectedTurnID) }
        return CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
    }

    func revokeComputerUseAutoApproval() {
        computerUseAutoApprovalRevoked = true
    }

    func shutdown() async {
        if let shutdownGate { await shutdownGate.enterAndWait() }
        lock.withLock {
            active = false
            shutdowns += 1
        }
        continuation.finish()
    }
}

extension CodexResumeWedgeCommitTests {
    func testAdmittedActiveReattachCannotQuietNormallyCompletedSilenceOrAckIncludingBufferedStartup() async throws {
        for buffered in [false, true] {
            for ack in [false, true] {
                let startup = TestReleaseFence(name: "quiet recovery startup")
                let f = makeFixture([[.suspendedSuccess(Self.oldThreadID, startup)]], freshSession: true, shouldManageCodexTooling: false)
                _ = try installRestoredBinding(f)
                f.viewModel.test_initializeRunService()
                let runID = UUID()
                f.session.installRunID(runID)
                f.session.codexConversationID = Self.oldThreadID
                f.session.codexRolloutPath = Self.oldRolloutPath
                let old = WedgeFakeCodexController(runID: runID, responses: [])
                let snapshot = CodexNativeSessionController.ThreadSnapshot(
                    conversationID: Self.oldThreadID, rolloutPath: Self.oldRolloutPath, model: nil, reasoningEffort: nil,
                    runtimeStatus: .active(activeFlags: []), currentTurnID: "quiet-recovery", activeTurnIDs: ["quiet-recovery"], latestTurnStatus: nil
                )
                old.setRecoverySnapshot(snapshot)
                f.session.codexController = old
                f.session.runState = .running
                f.session.beginRunAttempt(source: "quiet-active-recovery")
                await f.coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "quiet-recovery"), session: f.session, sourceController: old)
                let owner = try XCTUnwrap(f.session.activeRunOwnership)
                f.session.quietLedger.recordPhysicalDispatch(owner: owner, wakeID: UUID(), routineQuietCheckIn: true, alreadyAcquired: false)
                if ack { await f.coordinator.test_handleCodexNativeEvent(.assistantDelta("[ack]"), session: f.session, sourceController: old) }
                XCTAssertNotNil(f.session.quietLedger.candidateStartKey(owner: owner))
                // First unchanged active probe is benign. Only the second admits reattachment.
                let firstFailed = await f.coordinator.test_attemptCodexStallRecovery(session: f.session)
                XCTAssertFalse(firstFailed)
                XCTAssertTrue(f.factory.controllers.isEmpty)
                XCTAssertNotNil(f.session.quietLedger.candidateStartKey(owner: owner), "a skipped probe is not recovery")
                let recovery = Task { await f.coordinator.test_attemptCodexStallRecovery(session: f.session) }
                addTeardownBlock { @MainActor in
                    startup.release()
                    recovery.cancel()
                    _ = await recovery.value
                    await f.coordinator.shutdownCodexSession(f.session)
                    f.session.saveDebounceTask?.cancel()
                }
                guard await startup.waitUntilEntered(timeout: 4) else { continue }
                let replacement = try XCTUnwrap(f.factory.controllers.last)
                replacement.setRecoverySnapshot(snapshot)
                XCTAssertEqual(f.factory.controllers.count, 1)
                XCTAssertEqual(old.shutdownCount, 1)
                XCTAssertEqual(f.session.activeRunOwnership, owner)
                XCTAssertEqual(f.session.runID, runID)
                XCTAssertTrue(f.coordinator.test_codexReattachReconciliationIsPending(session: f.session))
                if buffered {
                    await f.coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: "quiet-recovery", status: .completed), session: f.session, sourceController: replacement)
                    XCTAssertTrue(f.session.runState.isActive, "startup completion is buffered, not a fabricated terminal state")
                    XCTAssertEqual(f.session.quietLedger.facts, .zero)
                }
                startup.release()
                let failed = await recovery.value
                XCTAssertFalse(failed)
                if !buffered {
                    XCTAssertEqual(f.session.activeRunOwnership, owner)
                    XCTAssertEqual(f.session.runState, .running)
                    await f.coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: "quiet-recovery", status: .completed), session: f.session, sourceController: replacement)
                }
                XCTAssertEqual(f.session.runState, .completed)
                XCTAssertEqual(f.session.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: 1), "buffered=\(buffered) ack=\(ack): admitted recovery is ordinary even at normal completion")
                XCTAssertTrue(f.session.quietLedger.hiddenSourceIDs.isEmpty, "buffered=\(buffered) ack=\(ack): recovery cannot hide rows or its routine marker")
                XCTAssertFalse(f.coordinator.test_codexReattachReconciliationIsPending(session: f.session))
                await f.coordinator.shutdownCodexSession(f.session)
                f.session.saveDebounceTask?.cancel()
            }
        }
    }

    func testSkippedQuietRecoveryProbesDoNotLatchRetryOrTouchSuccessorOwnerBindingOrController() async throws {
        for variant in ["first", "changed", "waiting", "owner", "binding", "controller", "cancelled"] {
            let f = makeFixture([], freshSession: true, shouldManageCodexTooling: false)
            _ = try installRestoredBinding(f)
            f.viewModel.test_initializeRunService()
            let runID = UUID()
            f.session.installRunID(runID)
            f.session.codexConversationID = Self.oldThreadID
            let old = WedgeFakeCodexController(runID: runID, responses: [])
            func snapshot(_ turn: String = "quiet-negative", flags: [String] = []) -> CodexNativeSessionController.ThreadSnapshot {
                .init(
                    conversationID: Self.oldThreadID,
                    rolloutPath: nil,
                    model: nil,
                    reasoningEffort: nil,
                    runtimeStatus: .active(activeFlags: flags),
                    currentTurnID: turn,
                    activeTurnIDs: [turn],
                    latestTurnStatus: nil
                )
            }
            old.setRecoverySnapshot(snapshot())
            f.session.codexController = old
            f.session.runState = .running
            let owner = f.session.beginRunAttempt(source: "quiet-negative-recovery")
            await f.coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "quiet-negative"), session: f.session, sourceController: old)
            f.session.quietLedger.recordPhysicalDispatch(owner: owner, wakeID: UUID(), routineQuietCheckIn: true, alreadyAcquired: false)
            addTeardownBlock { @MainActor in
                await f.coordinator.shutdownCodexSession(f.session)
                f.session.saveDebounceTask?.cancel()
            }
            let first = await f.coordinator.test_attemptCodexStallRecovery(session: f.session)
            XCTAssertFalse(first)
            XCTAssertNotNil(f.session.quietLedger.candidateStartKey(owner: owner))
            if variant == "first" {
                XCTAssertTrue(f.factory.controllers.isEmpty)
                XCTAssertEqual(f.session.runLifecycle.liveness?.retryIntent, AgentRunRetryIntent.none)
                continue
            }
            let gate = TestReleaseFence(name: "quiet recovery probe \(variant)")
            let probe = variant == "changed" ? snapshot("progressed-turn")
                : variant == "waiting" ? snapshot(flags: ["waiting_on_approval"]) : snapshot()
            old.setRecoverySnapshot(probe, gate: gate)
            let recovery = Task { await f.coordinator.test_attemptCodexStallRecovery(session: f.session) }
            addTeardownBlock { @MainActor in gate.release()
                recovery.cancel()
                _ = await recovery.value
            }
            guard await gate.waitUntilEntered(timeout: 4) else { continue }
            var currentOwner = owner
            var currentController = old
            if variant == "owner" {
                currentOwner = f.session.beginRunAttempt(source: "quiet-recovery-successor")
                f.session.quietLedger.recordPhysicalDispatch(owner: currentOwner, wakeID: UUID(), routineQuietCheckIn: true, alreadyAcquired: false)
            } else if variant == "binding" {
                f.session.beginPersistentBindingTransition()
            } else if variant == "controller" {
                currentController = WedgeFakeCodexController(runID: runID, responses: [])
                currentController.setRecoverySnapshot(snapshot())
                f.session.codexController = currentController
            } else if variant == "cancelled" {
                recovery.cancel()
            }
            let factsBeforeRelease = f.session.quietLedger.facts
            gate.release()
            let failed = await recovery.value
            XCTAssertFalse(failed, variant)
            XCTAssertTrue(f.factory.controllers.isEmpty, "\(variant): no recovery startup admitted")
            XCTAssertEqual(old.shutdownCount, 0, "\(variant): skipped probe cannot retire a controller")
            XCTAssertTrue(f.session.codexController === currentController)
            XCTAssertEqual(f.session.activeRunOwnership, currentOwner)
            XCTAssertEqual(f.session.quietLedger.facts, factsBeforeRelease)
            XCTAssertEqual(f.session.runLifecycle.liveness?.retryIntent, AgentRunRetryIntent.none)
            if variant != "binding" {
                XCTAssertNotNil(f.session.quietLedger.candidateStartKey(owner: currentOwner), "\(variant): no retry occurrence may contaminate the surviving quiet owner")
            }
        }
    }

    func testQuietNormalNativeCompletionVersusMissedCompletionWatchdogAndHiddenTool() async throws {
        for variant in 0 ..< 5 {
            let f = makeFixture([])
            f.viewModel.test_initializeRunService()
            let runID = UUID()
            f.session.runLifecycle.installRunID(runID)
            let controller = WedgeFakeCodexController(runID: runID, responses: [])
            f.session.codexController = controller
            f.session.codexConversationID = Self.oldThreadID
            await f.coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "quiet-normal"), session: f.session, sourceController: controller)
            let owner = try XCTUnwrap(f.session.activeRunOwnership)
            f.session.quietLedger.markRoutineWake(owner: owner, wakeID: UUID())
            if let activity = CodexNativeSessionController.test_parseLivenessActivity(
                method: "thread/status/changed", params: ["threadId": Self.oldThreadID, "status": ["type": "active"]]
            ) {
                await f.coordinator.test_handleCodexNativeEvent(.livenessActivity(activity), session: f.session, sourceController: controller)
            } else { XCTFail("Expected real neutral Codex lifecycle translation") }
            if variant == 3 {
                await f.coordinator.test_handleCodexNativeEvent(.assistantDelta("[ack]"), session: f.session, sourceController: controller)
            }
            if variant == 4, let activity = CodexNativeSessionController.test_parseLivenessActivity(method: "turn/plan/updated", params: ["threadId": Self.oldThreadID]) {
                await f.coordinator.test_handleCodexNativeEvent(.livenessActivity(activity), session: f.session, sourceController: controller)
            }
            if variant == 2 {
                await f.coordinator.test_handleCodexNativeEvent(.toolCall(name: "get_file_tree", invocationID: UUID(), argsJSON: "{}"), session: f.session, sourceController: controller)
                XCTAssertNil(f.session.quietLedger.candidateStartKey(owner: owner), "Accepted native tools latch before transcript hiding")
            }
            if variant == 1 {
                await f.coordinator.test_settleQuietIdleRecovery(session: f.session, snapshot: .init(
                    conversationID: Self.oldThreadID, rolloutPath: nil, model: nil, reasoningEffort: nil,
                    runtimeStatus: .idle, currentTurnID: nil, activeTurnIDs: [], latestTurnStatus: .completed
                ))
                XCTAssertTrue(f.session.items.contains { $0.kind == .system && $0.text == "Repo Prompt reconnected after a quiet period and confirmed that Codex completed the turn." })
            } else {
                await f.coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: "quiet-normal", status: .completed), session: f.session, sourceController: controller)
            }
            XCTAssertEqual(f.session.quietLedger.facts, AgentRunQuietFacts(settledThrough: 1, ordinaryThrough: variant == 0 || variant == 3 ? 0 : 1))
            XCTAssertEqual(f.session.runState, .completed)
            let target = DomainAgentSessionLinkEndpointIdentity(
                windowID: 2, workspaceID: UUID(), tabID: f.session.tabID, sessionID: UUID(),
                persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1
            )
            let reference = DomainAgentSessionLinkReference(linkID: UUID(), generation: 1)
            var notices = AgentSessionLinkPassiveStatusNotices(observerEndpoint: target)
            func sample(_ facts: AgentRunQuietFacts?) -> AgentSessionLinkPassiveStatusNotices.Sample {
                .init(
                    reference: reference,
                    targetEndpoint: target,
                    targetSessionID: target.sessionID,
                    displayName: "Codex target",
                    status: .idle,
                    runFacts: facts
                )
            }
            notices.enable(samples: [sample(.zero)], linkSetRevision: 1)
            notices.reconcile(samples: [sample(f.session.quietLedger.facts)], linkSetRevision: 1, deliverable: true)
            XCTAssertEqual(
                notices.snapshot.entries.first?.isRoutineWakeEligible ?? false,
                variant != 0 && variant != 3,
                "F4: actual watchdog completion remains ordinary and downstream eligible even with every intermediate sample dropped"
            )
            await f.coordinator.shutdownCodexSession(f.session)
            f.session.saveDebounceTask?.cancel()
        }
    }
}

extension CodexResumeWedgeCommitTests {
    func testQuietRawNativeIngressCurrentForeignUnknownAndFinishedAck() async throws {
        for variant in 0 ..< 18 {
            let f = makeFixture([])
            f.viewModel.test_initializeRunService()
            let runID = UUID()
            f.session.installRunID(runID)
            let controller = CodexNativeSessionController(
                client: CodexAppServerClient(), runID: runID, tabID: f.session.tabID,
                windowID: -1, workspacePaths: .uniform(nil)
            )
            f.session.codexController = controller
            f.session.codexConversationID = Self.oldThreadID
            let owner = try XCTUnwrap(f.session.activeRunOwnership)
            f.session.quietLedger.markRoutineWake(owner: owner, wakeID: UUID())
            await controller.test_installThreadState(threadID: Self.oldThreadID, authoritativeTurnID: "raw-turn", routingTurnID: "raw-turn")
            let stream = controller.events
            let thread = variant == 2 ? "foreign-thread" : Self.oldThreadID
            if [1, 2, 3, 4, 6].contains(variant) {
                let method = variant == 3 ? "item/started" : variant == 4 ? "turn/plan/updated" : "future/activity"
                await controller.test_handleNotification(method: method, params: ["threadId": .string(thread), "turnId": .string(variant == 6 ? "foreign-turn" : "raw-turn")])
            }
            if variant == 0 {
                await controller.test_handleNotification(method: "item/agentMessage/delta", params: [
                    "threadId": .string(Self.oldThreadID), "turnId": .string("raw-turn"),
                    "itemId": .string("answer"), "delta": .string("discarded streaming prose")
                ])
            }
            if variant == 8 {
                await controller.test_handleNotification(method: "item/completed", params: [
                    "threadId": .string(Self.oldThreadID), "turnId": .string("raw-turn"),
                    "item": .object(["id": .string("earlier"), "type": .string("agentMessage"), "text": .string("separate completed prose")])
                ])
            }
            if variant >= 9 {
                var item: [String: CodexJSONValue] = [
                    "type": .string("agentMessage"), "text": .string("unrepresented completed prose")
                ]
                switch (variant - 9) % 3 {
                case 1: item["id"] = .string("")
                case 2: item["id"] = .string(" \t\n")
                default: break // Missing identity, not a separate valid completed message.
                }
                await controller.test_handleNotification(method: "item/completed", params: [
                    "threadId": .string((12 ... 14).contains(variant) ? "foreign-thread" : Self.oldThreadID),
                    "turnId": .string(variant >= 15 ? "foreign-turn" : "raw-turn"), "item": .object(item)
                ])
            }
            if variant != 7 { // Actual raw native silence has no assistant row at all.
                await controller.test_handleNotification(method: "item/completed", params: [
                    "threadId": .string(Self.oldThreadID), "turnId": .string("raw-turn"),
                    "item": .object(["id": .string("answer"), "type": .string("agentMessage"), "text": .string("[ack]")])
                ])
            }
            await controller.test_handleNotification(method: "turn/completed", params: [
                "threadId": .string(Self.oldThreadID), "turn": .object(variant == 5 ? ["id": .string("raw-turn")] : ["id": .string("raw-turn"), "status": .string("completed")])
            ])
            await controller.shutdown()
            // Route the actual translated stream through the production current-controller gate.
            // Start is coordinator-owned separately so the routine mark precedes all tested ingress.
            await f.coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "raw-turn"), session: f.session, sourceController: controller)
            var ingressOrder: [String] = []
            for await event in stream {
                switch event {
                case let .livenessActivity(activity) where activity.method == "item/completed":
                    XCTAssertEqual(activity.turnID, variant >= 15 ? "foreign-turn" : "raw-turn")
                    if activity.turnID == "raw-turn" { ingressOrder.append("uncertainty") }
                case let .assistantCompleted(completion) where completion.scope.itemID == "answer":
                    ingressOrder.append("ack")
                default: break
                }
                await f.coordinator.test_handleCodexNativeEvent(event, session: f.session, sourceController: controller)
            }
            let expectsQuiet = [0, 2, 6, 7].contains(variant) || variant >= 12
            XCTAssertEqual(f.session.quietLedger.facts?.ordinaryThrough, expectsQuiet ? 0 : 1, "variant \(variant)")
            XCTAssertEqual(f.session.quietLedger.facts?.settledThrough, 1)
            if (9 ... 11).contains(variant) {
                XCTAssertEqual(ingressOrder, ["uncertainty", "ack"], "variant \(variant): uncertainty must precede the valid completion")
                XCTAssertTrue(f.session.quietLedger.hiddenSourceIDs.isEmpty, "variant \(variant): missing identity cannot hide the ACK")
            } else if variant >= 12 || variant == 0 {
                XCTAssertEqual(ingressOrder, ["ack"], "variant \(variant): foreign activity and valid same-item replacement remain quiet")
                XCTAssertFalse(f.session.quietLedger.hiddenSourceIDs.isEmpty, "variant \(variant): valid ACK remains quiet-masked")
            }
            f.session.saveDebounceTask?.cancel()
        }
    }
}

private actor QuietAutoapprovalResponseRecorder {
    private var frames: [Data] = []
    func record(_ frame: Data) {
        frames.append(frame)
    }

    func recorded() -> [Data] {
        frames
    }
}

extension CodexResumeWedgeCommitTests {
    func testQuietAutoapprovedNativeServerRequestsRemainOrdinaryAndScoped() async throws {
        for method in ["mcpServer/elicitation/request", "item/permissions/requestApproval"] {
            for ack in [false, true] {
                for scope in ["current", "absent-turn", "null-turn", "foreign-thread", "foreign-thread-no-turn", "foreign-turn", "stale-controller", "stale-controller-no-turn", "no-request"] {
                    let label = "\(method) ack=\(ack) scope=\(scope)"
                    let f = makeFixture([])
                    f.viewModel.test_initializeRunService()
                    let runID = UUID()
                    f.session.installRunID(runID)
                    let responses = QuietAutoapprovalResponseRecorder()
                    var warningMethods: [String] = []
                    func verifyRequestEvent(_ event: CodexNativeSessionController.Event) {
                        switch event {
                        case let .livenessActivity(activity):
                            XCTAssertNotEqual(activity.kind, .serverRequestResolved, label)
                            if activity.method == method {
                                XCTAssertEqual(activity.kind, .warning, label)
                                XCTAssertEqual(activity.threadID, scope.hasPrefix("foreign-thread") ? "other-thread" : Self.oldThreadID, label)
                                let lacksTurn = scope == "absent-turn" || scope == "null-turn" || scope.hasSuffix("no-turn")
                                XCTAssertEqual(activity.turnID, lacksTurn ? nil : (scope == "foreign-turn" ? "other-turn" : "request-turn"), label)
                                warningMethods.append(activity.method)
                            }
                        case .error, .serverRequestIssue, .approvalRequest, .permissionsRequest, .mcpElicitationRequest, .toolCall, .toolResult:
                            XCTFail("No error, surfaced interaction or later tool may supply the missing evidence: \(label)")
                        default: break
                        }
                    }
                    func controller() -> CodexNativeSessionController {
                        CodexNativeSessionController(
                            client: CodexAppServerClient(), runID: runID, tabID: f.session.tabID,
                            windowID: -1, workspacePaths: .uniform(nil),
                            serverRequestResponseExecutor: { id, result in
                                let frame = try JSONSerialization.data(withJSONObject: ["id": id.jsonValue, "result": result])
                                await responses.record(frame)
                            }
                        )
                    }
                    let current = controller()
                    let source = scope.hasPrefix("stale-controller") ? controller() : current
                    f.session.codexController = current
                    f.session.codexConversationID = Self.oldThreadID
                    let owner = try XCTUnwrap(f.session.activeRunOwnership)
                    f.session.quietLedger.markRoutineWake(owner: owner, wakeID: UUID())
                    await current.test_installThreadState(threadID: Self.oldThreadID, authoritativeTurnID: "request-turn", routingTurnID: "request-turn")
                    await source.test_installThreadState(threadID: Self.oldThreadID, authoritativeTurnID: "request-turn", routingTurnID: "request-turn")
                    await f.coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "request-turn"), session: f.session, sourceController: current)
                    if scope != "no-request" {
                        var params: [String: CodexJSONValue] = [
                            "serverName": .string("RepoPromptCE"), "toolName": .string("apply_edits"),
                            "threadId": .string(scope.hasPrefix("foreign-thread") ? "other-thread" : Self.oldThreadID),
                            "turnId": .string(scope == "foreign-turn" ? "other-turn" : "request-turn"),
                            "itemId": .string("permission-item"), "cwd": .string("/tmp"),
                            "message": .string("Approve app tool call?"),
                            "permissions": .object(["network": .object(["enabled": .bool(true)])]),
                            "requestedSchema": .object(["type": .string("object"), "properties": .object([:])])
                        ]
                        if scope == "absent-turn" || scope == "null-turn" || scope.hasSuffix("no-turn") {
                            params["turnId"] = nil
                            // Actual optional snake-case wire field, absent or explicitly null.
                            params["turn_id"] = scope == "null-turn" ? .null : nil
                        }
                        await source.test_handleServerRequest(method: method, params: params)
                    }
                    if source !== current {
                        await source.shutdown()
                        for await event in source.events {
                            verifyRequestEvent(event)
                            await f.coordinator.test_handleCodexNativeEvent(event, session: f.session, sourceController: source)
                        }
                    }
                    if ack {
                        await current.test_handleNotification(method: "item/completed", params: [
                            "threadId": .string(Self.oldThreadID), "turnId": .string("request-turn"),
                            "item": .object(["id": .string("answer"), "type": .string("agentMessage"), "text": .string("[ack]")])
                        ])
                    }
                    await current.test_handleNotification(method: "turn/completed", params: [
                        "threadId": .string(Self.oldThreadID), "turn": .object(["id": .string("request-turn"), "status": .string("completed")])
                    ])
                    await current.shutdown()
                    for await event in current.events {
                        verifyRequestEvent(event)
                        await f.coordinator.test_handleCodexNativeEvent(event, session: f.session, sourceController: current)
                    }
                    XCTAssertEqual(warningMethods, scope == "no-request" ? [] : [method], label)
                    let frames = await responses.recorded()
                    XCTAssertEqual(frames.count, scope == "no-request" ? 0 : 1, label)
                    for frame in frames {
                        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any])
                        XCTAssertEqual(response["id"] as? Int, 42, label)
                        XCTAssertEqual((response["result"] as? [String: Any])?["action"] as? String, "accept", label)
                    }
                    let ordinary = ["current", "absent-turn", "null-turn"].contains(scope)
                    XCTAssertEqual(f.session.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: ordinary ? 1 : 0), label)
                    XCTAssertEqual(f.session.runState, .completed, label)
                    if ordinary {
                        XCTAssertTrue(f.session.quietLedger.hiddenSourceIDs.isEmpty, label)
                    } else if ack {
                        XCTAssertFalse(f.session.quietLedger.hiddenSourceIDs.isEmpty, label)
                    }
                    let target = DomainAgentSessionLinkEndpointIdentity(
                        windowID: 2, workspaceID: UUID(), tabID: f.session.tabID, sessionID: UUID(),
                        persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1
                    )
                    let reference = DomainAgentSessionLinkReference(linkID: UUID(), generation: 1)
                    var notices = AgentSessionLinkPassiveStatusNotices(observerEndpoint: target)
                    func sample(_ facts: AgentRunQuietFacts?) -> AgentSessionLinkPassiveStatusNotices.Sample {
                        .init(
                            reference: reference,
                            targetEndpoint: target,
                            targetSessionID: target.sessionID,
                            displayName: "Codex target",
                            status: .idle,
                            runFacts: facts
                        )
                    }
                    notices.enable(samples: [sample(.zero)], linkSetRevision: 1)
                    notices.reconcile(samples: [sample(f.session.quietLedger.facts)], linkSetRevision: 1, deliverable: true)
                    XCTAssertEqual(notices.snapshot.entries.first?.isRoutineWakeEligible ?? false, ordinary, label)
                    f.session.saveDebounceTask?.cancel()
                }
            }
        }
    }
}

/// Source-derived v0.160.1 wire shapes; this is static replay, not a live emission capture.
private func quietPlainCodexNotifications(reasoning: Bool, ack: Bool, replacement: Bool) -> [(String, [String: CodexJSONValue])] {
    let thread = CodexJSONValue.string("old-committed-thread")
    let turn = CodexJSONValue.string("plain-turn")
    func scoped(_ payload: [String: CodexJSONValue]) -> [String: CodexJSONValue] {
        payload.merging(["threadId": thread, "turnId": turn]) { _, scope in scope }
    }
    func lifecycle(_ method: String, _ item: [String: CodexJSONValue]) -> (String, [String: CodexJSONValue]) {
        (method, scoped(["item": .object(item)]))
    }
    let user: [String: CodexJSONValue] = [
        "id": .string("canonical-user-uuid"),
        "type": .string("userMessage"),
        "clientId": .null,
        "content": .array([.object(["type": .string("text"), "text": .string("Same text")])])
    ]
    var events: [(String, [String: CodexJSONValue])] = [
        ("turn/started", scoped(["turn": .object(["id": turn, "status": .string("inProgress"), "items": .array([])])])),
        ("thread/status/changed", ["threadId": thread, "status": .object(["type": .string("active"), "activeFlags": .array([])])]),
        ("rawResponseItem/completed", scoped(["item": .object([
            "id": .string("msg_raw_prompt"), "type": .string("message"), "role": .string("user"),
            "content": .array([.object(["type": .string("input_text"), "text": .string("Same text")])]),
            "internal_chat_message_metadata_passthrough": .object(["turn_id": turn, "content_item_kinds": .array([.string("user.text")])])
        ])])),
        lifecycle("item/started", user), lifecycle("item/completed", user)
    ]
    if reasoning {
        events += [
            lifecycle("item/started", ["id": .string("thought"), "type": .string("reasoning"), "summary": .array([]), "content": .array([])]),
            ("item/reasoning/summaryPartAdded", scoped(["itemId": .string("thought"), "summaryIndex": .number(0)])),
            ("item/reasoning/summaryTextDelta", scoped(["itemId": .string("thought"), "summaryIndex": .number(0), "delta": .string("Thinking")])),
            ("item/reasoning/textDelta", scoped(["itemId": .string("thought"), "contentIndex": .number(0), "delta": .string("Thinking")])),
            lifecycle("item/completed", ["id": .string("thought"), "type": .string("reasoning"), "summary": .array([.string("Thinking")]), "content": .array([.string("Thinking")])]),
            lifecycle("rawResponseItem/completed", [
                "id": .string("thought"),
                "type": .string("reasoning"),
                "summary": .array([.object(["type": .string("summary_text"), "text": .string("Thinking")])]),
                "content": .array([.object(["type": .string("reasoning_text"), "text": .string("Thinking")])]),
                "encrypted_content": .null
            ])
        ]
    }
    if ack {
        events += [
            lifecycle("item/started", ["id": .string("answer"), "type": .string("agentMessage"), "text": .string("")]),
            ("item/agentMessage/delta", scoped(["itemId": .string("answer"), "delta": .string(replacement ? "discarded streaming prose" : "[ack]")])),
            lifecycle("item/completed", ["id": .string("answer"), "type": .string("agentMessage"), "text": .string("[ack]")]),
            lifecycle("rawResponseItem/completed", [
                "id": .string("answer"),
                "type": .string("message"),
                "role": .string("assistant"),
                "content": .array([.object(["type": .string("output_text"), "text": .string("[ack]")])]),
                "phase": .string("final_answer")
            ])
        ]
    }
    let usage = CodexJSONValue.object([
        "totalTokens": .number(3),
        "inputTokens": .number(1),
        "cachedInputTokens": .number(0),
        "cacheWriteInputTokens": .number(0),
        "outputTokens": .number(2),
        "reasoningOutputTokens": .number(1)
    ])
    events += [
        ("rawResponse/completed", scoped(["responseId": .string("response-1"), "usage": usage, "usageMetadata": .null])),
        ("thread/tokenUsage/updated", scoped(["tokenUsage": .object(["total": usage, "last": usage, "modelContextWindow": .number(1000)])])),
        ("account/rateLimits/updated", ["rateLimits": .object([
            "limitId": .null,
            "limitName": .null,
            "normalModelSlug": .null,
            "primary": .null,
            "secondary": .null,
            "credits": .null,
            "individualLimit": .null,
            "spendControlReached": .null,
            "planType": .null,
            "rateLimitReachedType": .null
        ])]),
        ("account/updated", ["authMode": .null, "planType": .null]),
        ("turn/completed", scoped(["turn": .object(["id": turn, "status": .string("completed"), "items": .array([])])])),
        ("thread/status/changed", ["threadId": thread, "status": .object(["type": .string("idle")])])
    ]
    return events
}

extension CodexResumeWedgeCommitTests {
    func testQuietCodex01601PlainStreamsAndBoundedRawAnnotations() async throws {
        let scenarios = [
            "plain",
            "replacement",
            "image",
            "audio",
            "command",
            "raw-tool",
            "unknown",
            "malformed-raw",
            "context",
            "goal",
            "hook",
            "missing",
            "empty",
            "unknown-kind",
            "count-mismatch",
            "mixed-context",
            "mixed-plain",
            "unpinned-case",
            "echo-then-context",
            "unrepresented-assistant",
            "unrepresented-reasoning",
            "bad-raw-response",
            "missing-usage-metadata",
            "missing-usage-metadata-context",
            "missing-usage-metadata-goal",
            "missing-usage-metadata-hook",
            "missing-usage-metadata-mixed",
            "missing-usage-metadata-misaligned",
            "malformed-usage-metadata",
            "missing-user-id",
            "null-user-id",
            "missing-assistant-id",
            "missing-reasoning-id",
            "bad-summary-part",
            "foreign-thread",
            "foreign-turn",
            "stale-controller",
            "legacy-neutral",
            "legacy-abort",
            "legacy-no-id"
        ]
        for reasoning in [false, true] {
            for ack in [false, true] {
                for scenario in scenarios {
                    let label = "\(scenario) reasoning=\(reasoning) ack=\(ack)"
                    let f = makeFixture([])
                    f.viewModel.test_initializeRunService()
                    let runID = UUID()
                    f.session.installRunID(runID)
                    let current = CodexNativeSessionController(client: CodexAppServerClient(), runID: runID, tabID: f.session.tabID, windowID: -1, workspacePaths: .uniform(nil))
                    f.session.codexController = current
                    f.session.codexConversationID = Self.oldThreadID
                    let owner = try XCTUnwrap(f.session.activeRunOwnership)
                    let wakeID = UUID()
                    f.session.quietLedger.markRoutineWake(owner: owner, wakeID: wakeID)
                    await current.test_installThreadState(threadID: Self.oldThreadID, authoritativeTurnID: "plain-turn", routingTurnID: "plain-turn")
                    var events = quietPlainCodexNotifications(reasoning: reasoning, ack: ack, replacement: scenario == "replacement")
                    guard case let .object(originalRaw)? = events[2].1["item"] else { return XCTFail("Missing raw input fixture") }
                    var raw = originalRaw
                    func annotate(_ kinds: [String]?) {
                        raw["internal_chat_message_metadata_passthrough"] = .object(kinds.map {
                            ["turn_id": .string("plain-turn"), "content_item_kinds": .array($0.map(CodexJSONValue.string))]
                        } ?? ["turn_id": .string("plain-turn")])
                    }
                    var extra: (String, [String: CodexJSONValue])?
                    switch scenario {
                    case "missing-user-id": raw["id"] = nil
                    case "null-user-id": raw["id"] = .null
                    case "missing-usage-metadata-context": annotate(["agents_md.instructions"])
                    case "missing-usage-metadata-goal": annotate(["user.goal"])
                    case "missing-usage-metadata-hook": annotate(["hooks.additional_context"])
                    case "missing-usage-metadata-mixed":
                        annotate(["user.text", "agents_md.instructions"])
                        raw["content"] = .array([
                            .object(["type": .string("input_text"), "text": .string("Same text")]),
                            .object(["type": .string("input_text"), "text": .string("Same text")])
                        ])
                    case "missing-usage-metadata-misaligned": annotate(["user.text", "user.text"])
                    case "missing-assistant-id", "missing-reasoning-id":
                        extra = ("rawResponseItem/completed", ["item": .object(scenario == "missing-assistant-id" ? [
                            "type": .string("message"), "role": .string("assistant"),
                            "content": .array([.object(["type": .string("output_text"), "text": .string("[ack]")])])
                        ] : ["type": .string("reasoning"), "summary": .array([]), "encrypted_content": .null])])
                    case "image":
                        annotate(["user.image"])
                        raw["content"] = .array([.object(["type": .string("input_image"), "image_url": .string("data:image/png;base64,AA==")])])
                    case "audio":
                        annotate(["user.audio"])
                        raw["content"] = .array([.object(["type": .string("input_audio"), "audio_url": .string("data:audio/wav;base64,AA==")])])
                    case "context": annotate(["agents_md.instructions"])
                    case "goal": annotate(["user.goal"])
                    case "hook": annotate(["hooks.additional_context"])
                    case "missing": annotate(nil)
                    case "empty": annotate([])
                    case "unknown-kind": annotate(["user.future"])
                    case "count-mismatch": annotate(["user.text", "user.text"])
                    case "mixed-context", "mixed-plain":
                        annotate(["user.text", scenario == "mixed-context" ? "agents_md.instructions" : "user.image"])
                        raw["content"] = .array([
                            .object(["type": .string("input_text"), "text": .string("Same text")]),
                            .object(["type": .string("input_text"), "text": .string("Same text")])
                        ])
                    case "unpinned-case": annotate(["User.Text"])
                    case "malformed-raw": raw["content"] = .string("Same text")
                    case "echo-then-context":
                        var context = raw
                        context["id"] = .string("msg_context")
                        context["internal_chat_message_metadata_passthrough"] = .object(["turn_id": .string("plain-turn"), "content_item_kinds": .array([.string("agents_md.instructions")])])
                        extra = ("rawResponseItem/completed", ["item": .object(context)])
                    case "command": extra = ("item/started", ["item": .object(["id": .string("command"), "type": .string("commandExecution"), "command": .string("echo test"), "cwd": .string("/tmp"), "processId": .string("1"), "status": .string("inProgress"), "commandActions": .array([]), "aggregatedOutput": .null, "exitCode": .null, "durationMs": .null])])
                    case "raw-tool": extra = ("rawResponseItem/completed", ["item": .object(["id": .string("fc_tool"), "type": .string("function_call"), "name": .string("shell"), "arguments": .string("{}"), "call_id": .string("call-1")])])
                    case "unrepresented-assistant": extra = ("rawResponseItem/completed", ["item": .object(["id": .string("unrepresented"), "type": .string("message"), "role": .string("assistant"), "content": .array([.object(["type": .string("output_text"), "text": .string("Same text")])])])])
                    case "unrepresented-reasoning": extra = ("rawResponseItem/completed", ["item": .object(["id": .string("unrepresented"), "type": .string("reasoning"), "summary": .array([]), "encrypted_content": .null])])
                    case "bad-raw-response": extra = ("rawResponse/completed", ["responseId": .string("response-bad"), "usage": .string("invalid"), "usageMetadata": .null])
                    case "bad-summary-part": extra = ("item/reasoning/summaryPartAdded", ["summaryIndex": .number(0)])
                    case "legacy-neutral": extra = ("codex/event/task_complete", [:])
                    case "legacy-abort": extra = ("codex/event/turn_aborted", [:])
                    case "legacy-no-id": extra = ("codex/event/agent_message", ["msg": .object(["type": .string("agent_message"), "message": .string("[ack]")])])
                    case "unknown", "foreign-thread", "foreign-turn", "stale-controller": extra = ("future/activity", [:])
                    default: break
                    }
                    events[2].1["item"] = .object(raw)
                    if scenario.hasPrefix("missing-usage-metadata") || scenario == "malformed-usage-metadata" {
                        let responseIndex = try XCTUnwrap(events.firstIndex { $0.0 == "rawResponse/completed" })
                        events[responseIndex].1["usageMetadata"] = scenario == "malformed-usage-metadata" ? .string("invalid") : nil
                    }
                    if var extra {
                        extra.1["threadId"] = .string(scenario == "foreign-thread" ? "other-thread" : Self.oldThreadID)
                        extra.1["turnId"] = .string(scenario == "foreign-turn" ? "other-turn" : "plain-turn")
                        if scenario == "stale-controller" {
                            let stale = CodexNativeSessionController(client: CodexAppServerClient(), runID: runID, tabID: f.session.tabID, windowID: -1, workspacePaths: .uniform(nil))
                            await stale.test_installThreadState(threadID: Self.oldThreadID, authoritativeTurnID: "plain-turn", routingTurnID: "plain-turn")
                            await stale.test_handleNotification(method: extra.0, params: extra.1)
                            await stale.shutdown()
                            for await event in stale.events {
                                await f.coordinator.test_handleCodexNativeEvent(event, session: f.session, sourceController: stale)
                            }
                        } else { events.insert(extra, at: events.count - 2) }
                    }
                    for (method, params) in events {
                        await current.test_handleNotification(method: method, params: params)
                    }
                    await current.shutdown()
                    var warnings: [String] = []
                    for await event in current.events {
                        if case let .livenessActivity(activity) = event, activity.kind == .warning { warnings.append(activity.method) }
                        await f.coordinator.test_handleCodexNativeEvent(event, session: f.session, sourceController: current)
                    }
                    let quiet = ["plain", "replacement", "image", "audio", "missing-usage-metadata", "foreign-thread", "foreign-turn", "stale-controller", "legacy-neutral"].contains(scenario)
                    XCTAssertEqual(f.session.runState, .completed, label)
                    XCTAssertEqual(f.session.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: quiet ? 0 : 1), label)
                    XCTAssertEqual(f.session.quietLedger.hiddenSourceIDs.contains(wakeID), quiet, "\(label): silence must retain the exact wake mask too")
                    if !quiet { XCTAssertTrue(f.session.quietLedger.hiddenSourceIDs.isEmpty, label) }
                    if scenario == "plain" || scenario == "replacement" { XCTAssertTrue(warnings.isEmpty, "\(label): \(warnings)") }
                    f.session.saveDebounceTask?.cancel()
                }
            }
        }
    }
}

extension CodexResumeWedgeCommitTests {
    func testMalformedNativeAssistantAndReasoningDeltasRemainOrdinary() async throws {
        let cases: [(String, [String: CodexJSONValue], Bool)] = [
            ("missing-turn", ["itemId": .string("probe"), "delta": .string("")], true),
            ("missing-delta", ["itemId": .string("probe")], true),
            ("null-delta", ["itemId": .string("probe"), "delta": .null], true),
            ("number-delta", ["itemId": .string("probe"), "delta": .number(42)], true),
            ("object-delta", ["itemId": .string("probe"), "delta": .object([:])], true),
            ("missing-item", ["delta": .string("")], true),
            ("null-item", ["itemId": .null, "delta": .string("")], true),
            ("object-item", ["itemId": .object([:]), "delta": .string("")], true),
            ("number-item", ["itemId": .number(42), "delta": .string("")], true),
            ("array-item", ["itemId": .array([.string("probe")]), "delta": .string("")], true),
            ("bool-item", ["itemId": .bool(true), "delta": .string("")], true),
            ("completed-malformed", ["itemId": .string("thought"), "delta": .number(42)], true),
            ("completed-valid", ["itemId": .string("thought"), "delta": .string("")], false),
            ("fallback-item", ["item_id": .string("probe"), "delta": .string("")], false),
            ("nested-item", ["item": .object(["id": .string("probe")]), "delta": .string("")], false),
            ("empty-delta", ["itemId": .string("probe"), "delta": .string("")], false)
        ]
        for method in ["item/agentMessage/delta", "item/reasoning/summaryTextDelta", "item/reasoning/textDelta"] {
            for ack in [false, true] {
                for (name, payload, malformed) in cases {
                    let label = "\(method) \(name) ack=\(ack)"
                    let f = makeFixture([])
                    f.viewModel.test_initializeRunService()
                    let runID = UUID()
                    f.session.installRunID(runID)
                    let controller = CodexNativeSessionController(client: CodexAppServerClient(), runID: runID, tabID: f.session.tabID, windowID: -1, workspacePaths: .uniform(nil))
                    f.session.codexController = controller
                    f.session.codexConversationID = Self.oldThreadID
                    let owner = try XCTUnwrap(f.session.activeRunOwnership)
                    let wakeID = UUID()
                    f.session.quietLedger.markRoutineWake(owner: owner, wakeID: wakeID)
                    await controller.test_installThreadState(threadID: Self.oldThreadID, authoritativeTurnID: "plain-turn", routingTurnID: "plain-turn")
                    var events = quietPlainCodexNotifications(reasoning: true, ack: ack, replacement: false)
                    var params = payload
                    params["threadId"] = .string(Self.oldThreadID)
                    params["turnId"] = name == "missing-turn" ? nil : .string("plain-turn")
                    params["summaryIndex"] = .number(0)
                    params["contentIndex"] = .number(0)
                    events.insert((method, params), at: name.hasPrefix("completed-") ? events.count - 2 : 5)
                    for (method, params) in events {
                        await controller.test_handleNotification(method: method, params: params)
                    }
                    await controller.shutdown()
                    var warnings: [String] = []
                    var deltas = 0
                    for await event in controller.events {
                        if case let .livenessActivity(activity) = event, activity.kind == .warning { warnings.append(activity.method) }
                        switch event {
                        case .canonicalAssistantDelta, .reasoningDelta: deltas += 1
                        default: break
                        }
                        await f.coordinator.test_handleCodexNativeEvent(event, session: f.session, sourceController: controller)
                    }
                    XCTAssertEqual(warnings, malformed ? [method] : [], label)
                    let expectedProbeDeltas = malformed || name == "completed-valid" ? 0 : 1
                    XCTAssertEqual(deltas, 2 + (ack ? 1 : 0) + expectedProbeDeltas, "\(label): no duplicate typed delta on uncertainty or completed-item dedup")
                    XCTAssertEqual(f.session.runState, .completed, label)
                    XCTAssertEqual(f.session.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: malformed ? 1 : 0), label)
                    XCTAssertEqual(f.session.quietLedger.hiddenSourceIDs.contains(wakeID), !malformed, label)
                    if malformed { XCTAssertTrue(f.session.quietLedger.hiddenSourceIDs.isEmpty, label) }
                    f.session.saveDebounceTask?.cancel()
                }
            }
        }
    }

    func testMalformedNativeCompletionsRemainOrdinaryBeforeDeduplication() async throws {
        let cases: [(String, [String: CodexJSONValue], Bool)] = [
            ("missing-text", [:], true),
            ("null-text", ["text": .null], true),
            ("number-text", ["text": .number(7)], true),
            ("object-text", ["text": .object([:])], true),
            ("array-text", ["text": .array([])], true),
            ("message-fallback", ["message": .string("[ack]")], true),
            ("empty-text", ["text": .string("")], false),
            ("ack-text", ["text": .string("[ack]")], false),
            ("empty-text-fallback", ["text": .string(""), "message": .string("[ack]")], false),
            ("reasoning-defaults", ["type": .string("reasoning")], false),
            ("reasoning-empty", ["type": .string("reasoning"), "summary": .array([]), "content": .array([])], false),
            ("reasoning-strings", ["type": .string("reasoning"), "summary": .array([.string("Thinking")]), "content": .array([.string("Thinking")])], false)
        ] + ["summary", "content"].flatMap { field in
            [
                ("null-\(field)", ["type": .string("reasoning"), field: .null], true),
                ("number-\(field)", ["type": .string("reasoning"), field: .number(7)], true),
                ("object-\(field)", ["type": .string("reasoning"), field: .object([:])], true),
                ("mixed-\(field)", ["type": .string("reasoning"), field: .array([.string(""), .number(7)])], true)
            ]
        }
        for (name, payload, malformed) in cases {
            for scope in ["current", "completed-item", "foreign-thread", "foreign-turn", "stale-controller"] {
                let label = "\(name) scope=\(scope)"
                let f = makeFixture([])
                f.viewModel.test_initializeRunService()
                let runID = UUID()
                f.session.installRunID(runID)
                let current = CodexNativeSessionController(client: CodexAppServerClient(), runID: runID, tabID: f.session.tabID, windowID: -1, workspacePaths: .uniform(nil))
                f.session.codexController = current
                f.session.codexConversationID = Self.oldThreadID
                let owner = try XCTUnwrap(f.session.activeRunOwnership)
                let wakeID = UUID()
                f.session.quietLedger.markRoutineWake(owner: owner, wakeID: wakeID)
                await current.test_installThreadState(threadID: Self.oldThreadID, authoritativeTurnID: "completion-turn", routingTurnID: "completion-turn")
                let controller = scope == "stale-controller"
                    ? CodexNativeSessionController(client: CodexAppServerClient(), runID: runID, tabID: f.session.tabID, windowID: -1, workspacePaths: .uniform(nil)) : current
                if scope == "stale-controller" {
                    await controller.test_installThreadState(threadID: Self.oldThreadID, authoritativeTurnID: "completion-turn", routingTurnID: "completion-turn")
                }
                var item = payload
                item["id"] = .string("answer")
                item["type"] = item["type"] ?? .string("agentMessage")
                let thread = scope == "foreign-thread" ? "foreign-thread" : Self.oldThreadID
                let turn = scope == "foreign-turn" ? "foreign-turn" : "completion-turn"
                if scope == "completed-item" {
                    var valid = item
                    valid["text"] = .string("[ack]")
                    valid["summary"] = .array([])
                    valid["content"] = .array([])
                    await controller.test_handleNotification(method: "item/completed", params: [
                        "threadId": .string(thread), "turnId": .string(turn), "item": .object(valid)
                    ])
                } else if !malformed, item["type"] == .string("agentMessage"),
                          item["text"] == .string("[ack]") || item["message"] == .string("[ack]")
                {
                    // Valid final replacement may discard prior streaming prose without uncertainty.
                    await controller.test_handleNotification(method: "item/agentMessage/delta", params: [
                        "threadId": .string(thread), "turnId": .string(turn), "itemId": .string("answer"), "delta": .string("discarded streaming prose")
                    ])
                }
                await controller.test_handleNotification(method: "item/completed", params: [
                    "threadId": .string(thread), "turnId": .string(turn), "item": .object(item)
                ])
                let terminal: [String: CodexJSONValue] = [
                    "threadId": .string(Self.oldThreadID),
                    "turn": .object(["id": .string("completion-turn"), "status": .string("completed")])
                ]
                if scope != "stale-controller" {
                    await current.test_handleNotification(method: "turn/completed", params: terminal)
                }
                await controller.shutdown()
                await f.coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "completion-turn"), session: f.session, sourceController: current)
                var warnings = 0
                var order: [String] = []
                for await event in controller.events {
                    switch event {
                    case let .livenessActivity(activity) where activity.kind == .warning:
                        warnings += 1
                        XCTAssertEqual(activity.method, "item/completed", label)
                        XCTAssertEqual(activity.threadID, thread, label)
                        XCTAssertEqual(activity.turnID, turn, label)
                        order.append("uncertainty")
                    case .assistantCompleted, .reasoningCompleted: order.append("completed")
                    default: break
                    }
                    await f.coordinator.test_handleCodexNativeEvent(event, session: f.session, sourceController: controller)
                }
                if scope == "stale-controller" {
                    await current.test_handleNotification(method: "turn/completed", params: terminal)
                    await current.shutdown()
                    for await event in current.events {
                        await f.coordinator.test_handleCodexNativeEvent(event, session: f.session, sourceController: current)
                    }
                }
                let acceptedMalformed = malformed && ["current", "completed-item"].contains(scope)
                // Foreign envelopes may be dropped by routing; stale controllers still translate but cannot latch.
                let translated = scope != "foreign-thread"
                XCTAssertEqual(warnings, malformed && translated ? 1 : 0, label)
                if translated {
                    XCTAssertEqual(
                        order,
                        scope == "completed-item"
                            ? (malformed ? ["completed", "uncertainty"] : ["completed"])
                            : (malformed ? ["uncertainty", "completed"] : ["completed"]),
                        label
                    )
                }
                XCTAssertEqual(f.session.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: acceptedMalformed ? 1 : 0), label)
                XCTAssertEqual(f.session.quietLedger.hiddenSourceIDs.contains(wakeID), !acceptedMalformed, label)
                if acceptedMalformed {
                    XCTAssertTrue(f.session.quietLedger.hiddenSourceIDs.isEmpty, label)
                }
                f.session.saveDebounceTask?.cancel()
            }
        }
    }

    private func makeQuietToolProgressFixture() async throws -> (Fixture, CodexNativeSessionController, AgentRunOwnership) {
        let f = makeFixture([])
        f.viewModel.test_initializeRunService()
        let runID = UUID()
        f.session.installRunID(runID)
        let controller = CodexNativeSessionController(client: CodexAppServerClient(), runID: runID, tabID: f.session.tabID, windowID: -1, workspacePaths: .uniform(nil))
        f.session.codexController = controller
        f.session.codexConversationID = Self.oldThreadID
        await controller.test_installThreadState(threadID: Self.oldThreadID, authoritativeTurnID: "progress-turn", routingTurnID: "progress-turn")
        await f.coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "progress-turn"), session: f.session, sourceController: controller)
        let owner = try XCTUnwrap(f.session.activeRunOwnership)
        f.session.quietLedger.markRoutineWake(owner: owner, wakeID: UUID())
        return (f, controller, owner)
    }

    func testThousandNativeCommandOutputDeltasRecordExactlyOneAcceptedProgressEach() async throws {
        let (f, controller, owner) = try await makeQuietToolProgressFixture()
        defer { f.session.saveDebounceTask?.cancel() }
        let sequenceBefore = try XCTUnwrap(f.session.runLifecycle.liveness?.lastAcceptedSequence)
        let itemID = UUID().uuidString
        let expectedOutput = (0 ..< 1000).map { "ordinary output \($0)" }
        for output in expectedOutput {
            await controller.test_handleNotification(method: "item/commandExecution/outputDelta", params: [
                "threadId": .string(Self.oldThreadID), "turnId": .string("progress-turn"),
                "itemId": .string(itemID), "delta": .string(output)
            ])
        }
        await controller.shutdown()
        var output: [String] = []
        var warnings = 0
        var eventCount = 0
        for await event in controller.events {
            eventCount += 1
            if case let .commandExecutionRunning(update) = event { output.append(update.appendedOutput ?? "") }
            if case let .livenessActivity(activity) = event, activity.kind == .warning { warnings += 1 }
            await f.coordinator.test_handleCodexNativeEvent(event, session: f.session, sourceController: controller)
        }
        XCTAssertEqual(output, expectedOutput, "Every real notification retains exactly its typed output update")
        XCTAssertEqual(eventCount, 1000, "One typed semantic event, not an extra uncertainty event per chunk")
        XCTAssertEqual(warnings, 0)
        XCTAssertEqual(f.session.runLifecycle.liveness?.lastAcceptedSequence, sequenceBefore + 1000, "Exactly 1000 accepted recordRunProgress calls through the actual coordinator")
        XCTAssertNil(f.session.quietLedger.candidateStartKey(owner: owner))
        XCTAssertTrue(f.session.quietLedger.hiddenSourceIDs.isEmpty)
    }

    func testNativeToolProgressSingleActivityPreservesMalformedUnknownAndSourceFences() async throws {
        let itemID = UUID().uuidString
        let cases: [(String, [String: CodexJSONValue], Bool)] = [
            ("item/commandExecution/outputDelta", ["itemId": .string(itemID), "delta": .string("output")], false),
            ("item/fileChange/outputDelta", ["itemId": .string("patch"), "delta": .string("+line")], false),
            ("item/mcpToolCall/progress", ["itemId": .string("mcp"), "message": .string("running")], false),
            ("item/plan/delta", ["itemId": .string("plan"), "delta": .string("step")], false),
            ("turn/diff/updated", ["diff": .string("+line")], false),
            ("item/commandExecution/outputDelta", ["delta": .number(42)], true),
            ("item/fileChange/outputDelta", ["delta": .number(42)], true),
            ("future/activity", [:], true)
        ]
        for (method, payload, uncertain) in cases {
            for scope in ["current", "foreign-thread", "foreign-turn", "stale-controller"] {
                let label = "\(method) uncertain=\(uncertain) \(scope)"
                let (f, controller, _) = try await makeQuietToolProgressFixture()
                defer { f.session.saveDebounceTask?.cancel() }
                let source: CodexNativeSessionController
                if scope == "stale-controller" {
                    source = try CodexNativeSessionController(client: CodexAppServerClient(), runID: XCTUnwrap(f.session.runID), tabID: f.session.tabID, windowID: -1, workspacePaths: .uniform(nil))
                    await source.test_installThreadState(threadID: Self.oldThreadID, authoritativeTurnID: "progress-turn", routingTurnID: "progress-turn")
                } else { source = controller }
                var params = payload
                params["threadId"] = .string(scope == "foreign-thread" ? "foreign" : Self.oldThreadID)
                params["turnId"] = .string(scope == "foreign-turn" ? "foreign" : "progress-turn")
                let sequenceBefore = try XCTUnwrap(f.session.runLifecycle.liveness?.lastAcceptedSequence)
                await source.test_handleNotification(method: method, params: params)
                await source.shutdown()
                var eventCount = 0
                var warnings = 0
                for await event in source.events {
                    eventCount += 1
                    if case let .livenessActivity(activity) = event, activity.kind == .warning { warnings += 1 }
                    await f.coordinator.test_handleCodexNativeEvent(event, session: f.session, sourceController: source)
                }
                if scope == "current" {
                    XCTAssertEqual(eventCount, 1, label)
                    XCTAssertEqual(warnings, uncertain ? 1 : 0, label)
                }
                // Existing typed output events carry no turn scope after parsing. Preserve
                // their established foreign-turn ordinary behavior; do not change routing policy.
                let accepted = scope == "current" || (
                    scope == "foreign-turn" && !uncertain
                        && ["item/commandExecution/outputDelta", "item/fileChange/outputDelta"].contains(method)
                )
                XCTAssertEqual(f.session.runLifecycle.liveness?.lastAcceptedSequence, sequenceBefore + (accepted ? 1 : 0), label)
                await f.coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: "progress-turn", status: .completed), session: f.session, sourceController: controller)
                XCTAssertEqual(f.session.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: accepted ? 1 : 0), label)
                XCTAssertEqual(f.session.quietLedger.hiddenSourceIDs.isEmpty, accepted, label)
                if scope == "stale-controller" { await controller.shutdown() }
            }
        }
    }
}

private final class QuietAuthRefreshWireRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []

    func record(_ frame: Data) {
        lock.withLock { frames.append(frame) }
    }

    func recorded() -> [Data] {
        lock.withLock { frames }
    }
}

extension CodexResumeWedgeCommitTests {
    func testSuccessfulDormantAuthRefreshIsOrdinaryOnlyForCurrentScope() async throws {
        let method = "account/chatgptAuthTokens/refresh"
        for ack in [false, true] {
            for scope in ["current", "foreign-thread", "foreign-turn", "stale-controller", "no-request"] {
                let label = "auth refresh ack=\(ack) scope=\(scope)"
                let f = makeFixture([])
                f.viewModel.test_initializeRunService()
                let runID = UUID()
                f.session.installRunID(runID)
                let responses = QuietAuthRefreshWireRecorder()
                let client = CodexAppServerClient(writeFrameHandler: { _, frame in responses.record(frame) })
                // In-memory transport only: no process launch and a successful real client write.
                await client.debugInstallTestTransport()
                var options = CodexNativeSessionController.Options.agentModeDefault()
                options.authTokensRefreshHandler = { _ in
                    .init(accessToken: "fixture-refreshed-token", chatgptAccountID: "fixture-account", chatgptPlanType: "fixture-plan")
                }
                func controller() -> CodexNativeSessionController {
                    CodexNativeSessionController(client: client, runID: runID, tabID: f.session.tabID, windowID: -1, workspacePaths: .uniform(nil), options: options)
                }
                let current = controller()
                let source = scope == "stale-controller" ? controller() : current
                f.session.codexController = current
                f.session.codexConversationID = Self.oldThreadID
                let owner = try XCTUnwrap(f.session.activeRunOwnership)
                let wakeID = UUID()
                f.session.quietLedger.markRoutineWake(owner: owner, wakeID: wakeID)
                await current.test_installThreadState(threadID: Self.oldThreadID, authoritativeTurnID: "refresh-turn", routingTurnID: "refresh-turn")
                await source.test_installThreadState(threadID: Self.oldThreadID, authoritativeTurnID: "refresh-turn", routingTurnID: "refresh-turn")
                await f.coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "refresh-turn"), session: f.session, sourceController: current)
                if scope != "no-request" {
                    await source.test_handleServerRequest(method: method, params: [
                        "reason": .string("unauthorized"), "previousAccountId": .string("fixture-account"),
                        "threadId": .string(scope == "foreign-thread" ? "other-thread" : Self.oldThreadID),
                        "turnId": .string(scope == "foreign-turn" ? "other-turn" : "refresh-turn")
                    ])
                }
                var warningCount = 0
                func consume(_ controller: CodexNativeSessionController) async {
                    for await event in controller.events {
                        switch event {
                        case let .livenessActivity(activity) where activity.method == method:
                            warningCount += 1
                            XCTAssertEqual(activity.kind, .warning, label)
                            XCTAssertEqual(activity.threadID, scope == "foreign-thread" ? "other-thread" : Self.oldThreadID, label)
                            XCTAssertEqual(activity.turnID, scope == "foreign-turn" ? "other-turn" : "refresh-turn", label)
                        case .error, .serverRequestIssue, .errorNotification, .approvalRequest, .permissionsRequest, .mcpElicitationRequest, .toolCall, .toolResult:
                            XCTFail("Refresh must succeed without substitute error or interaction evidence: \(label)")
                        default: break
                        }
                        await f.coordinator.test_handleCodexNativeEvent(event, session: f.session, sourceController: controller)
                    }
                }
                if source !== current {
                    await source.shutdown()
                    await consume(source)
                }
                if ack {
                    await current.test_handleNotification(method: "item/completed", params: [
                        "threadId": .string(Self.oldThreadID), "turnId": .string("refresh-turn"),
                        "item": .object(["id": .string("answer"), "type": .string("agentMessage"), "text": .string("[ack]")])
                    ])
                }
                await current.test_handleNotification(method: "turn/completed", params: [
                    "threadId": .string(Self.oldThreadID), "turn": .object(["id": .string("refresh-turn"), "status": .string("completed")])
                ])
                await current.shutdown()
                await consume(current)
                let frames = responses.recorded()
                XCTAssertEqual(frames.count, scope == "no-request" ? 0 : 1, label)
                for frame in frames {
                    let response = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any])
                    XCTAssertEqual(response["id"] as? Int, 42, label)
                    XCTAssertNil(response["error"], label)
                    let payload = try XCTUnwrap(response["result"] as? [String: String])
                    XCTAssertEqual(payload, ["accessToken": "fixture-refreshed-token", "chatgptAccountId": "fixture-account", "chatgptPlanType": "fixture-plan"], label)
                }
                XCTAssertEqual(warningCount, scope == "no-request" ? 0 : 1, label)
                let ordinary = scope == "current"
                XCTAssertEqual(f.session.runState, .completed, label)
                XCTAssertEqual(f.session.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: ordinary ? 1 : 0), label)
                XCTAssertEqual(f.session.quietLedger.hiddenSourceIDs.contains(wakeID), !ordinary, label)
                if ordinary { XCTAssertTrue(f.session.quietLedger.hiddenSourceIDs.isEmpty, label) }
                f.session.saveDebounceTask?.cancel()
                await client.stop()
            }
        }
    }
}

extension CodexResumeWedgeCommitTests {
    func testUnscopedUnknownNativeNotificationIsOrdinaryOnlyForCurrentController() async throws {
        for ack in [false, true] {
            for scope in ["unscoped", "foreign-thread-no-turn", "foreign-turn", "stale-unscoped"] {
                let label = "unknown notification ack=\(ack) scope=\(scope)"
                let f = makeFixture([])
                f.viewModel.test_initializeRunService()
                let runID = UUID()
                f.session.installRunID(runID)
                func controller() -> CodexNativeSessionController {
                    CodexNativeSessionController(client: CodexAppServerClient(), runID: runID, tabID: f.session.tabID, windowID: -1, workspacePaths: .uniform(nil))
                }
                let current = controller()
                let source = scope == "stale-unscoped" ? controller() : current
                f.session.codexController = current
                f.session.codexConversationID = Self.oldThreadID
                let owner = try XCTUnwrap(f.session.activeRunOwnership)
                let wakeID = UUID()
                f.session.quietLedger.markRoutineWake(owner: owner, wakeID: wakeID)
                await current.test_installThreadState(threadID: Self.oldThreadID, authoritativeTurnID: "unknown-turn", routingTurnID: "unknown-turn")
                await source.test_installThreadState(threadID: Self.oldThreadID, authoritativeTurnID: "unknown-turn", routingTurnID: "unknown-turn")
                await f.coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "unknown-turn"), session: f.session, sourceController: current)
                let params: [String: CodexJSONValue] = switch scope {
                case "foreign-thread-no-turn": ["threadId": .string("other-thread")]
                case "foreign-turn": ["threadId": .string(Self.oldThreadID), "turnId": .string("other-turn")]
                default: [:]
                }
                await source.test_handleNotification(method: "future/activity", params: params)
                var warnings = 0
                func consume(_ controller: CodexNativeSessionController) async {
                    for await event in controller.events {
                        switch event {
                        case let .livenessActivity(activity) where activity.method == "future/activity":
                            warnings += 1
                            XCTAssertEqual(activity.kind, .warning, label)
                            XCTAssertEqual(activity.threadID, scope == "foreign-turn" ? Self.oldThreadID : nil, label)
                            XCTAssertEqual(activity.turnID, scope == "foreign-turn" ? "other-turn" : nil, label)
                            XCTAssertNil(activity.itemID, label)
                        case .error, .serverRequestIssue, .errorNotification, .toolCall, .toolResult:
                            XCTFail("No substitute error/tool activity: \(label)")
                        default: break
                        }
                        await f.coordinator.test_handleCodexNativeEvent(event, session: f.session, sourceController: controller)
                    }
                }
                if source !== current {
                    await source.shutdown()
                    await consume(source)
                }
                if ack {
                    await current.test_handleNotification(method: "item/completed", params: [
                        "threadId": .string(Self.oldThreadID), "turnId": .string("unknown-turn"),
                        "item": .object(["id": .string("answer"), "type": .string("agentMessage"), "text": .string("[ack]")])
                    ])
                }
                await current.test_handleNotification(method: "turn/completed", params: [
                    "threadId": .string(Self.oldThreadID), "turn": .object(["id": .string("unknown-turn"), "status": .string("completed")])
                ])
                await current.shutdown()
                await consume(current)
                // Foreign thread is discarded by the controller; other scopes reach the coordinator.
                XCTAssertEqual(warnings, scope == "foreign-thread-no-turn" ? 0 : 1, label)
                let ordinary = scope == "unscoped"
                XCTAssertEqual(f.session.runState, .completed, label)
                XCTAssertEqual(f.session.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: ordinary ? 1 : 0), label)
                XCTAssertEqual(f.session.quietLedger.hiddenSourceIDs.contains(wakeID), !ordinary, label)
                if ordinary { XCTAssertTrue(f.session.quietLedger.hiddenSourceIDs.isEmpty, label) }
                f.session.saveDebounceTask?.cancel()
            }
        }
    }
}

extension CodexResumeWedgeCommitTests {
    func testQuietAckWithModerationMetadataBeforeCompletion() async throws {
        // v0.160.1 defines metadata as arbitrary JSON, including scalar and null values.
        for metadata: CodexJSONValue in [.object([:]), .array([]), .string("annotation"), .number(1), .bool(false), .null] {
            try await replayQuietAckModerationMetadata([
                "threadId": .string(Self.oldThreadID), "turnId": .string("plain-turn"), "metadata": metadata
            ], malformed: false)
        }
    }

    func testMalformedModerationMetadataKeepsAckOrdinary() async throws {
        // Missing required metadata is malformed; a null value itself is valid JSON.
        try await replayQuietAckModerationMetadata([
            "threadId": .string(Self.oldThreadID), "turnId": .string("plain-turn")
        ], malformed: true)
    }

    private func replayQuietAckModerationMetadata(_ payload: [String: CodexJSONValue], malformed: Bool) async throws {
        let f = makeFixture([])
        defer { f.session.saveDebounceTask?.cancel() }
        f.viewModel.test_initializeRunService()
        let runID = UUID()
        f.session.installRunID(runID)
        let controller = CodexNativeSessionController(client: CodexAppServerClient(), runID: runID, tabID: f.session.tabID, windowID: -1, workspacePaths: .uniform(nil))
        f.session.codexController = controller
        f.session.codexConversationID = Self.oldThreadID
        let owner = try XCTUnwrap(f.session.activeRunOwnership)
        let wakeID = UUID()
        f.session.quietLedger.markRoutineWake(owner: owner, wakeID: wakeID)
        await controller.test_installThreadState(threadID: Self.oldThreadID, authoritativeTurnID: "plain-turn", routingTurnID: "plain-turn")
        var events = quietPlainCodexNotifications(reasoning: false, ack: true, replacement: false)
        // Replay the live ordering: routine wake, [ack] agent message, moderation, completion.
        let completionIndex = try XCTUnwrap(events.firstIndex { $0.0 == "turn/completed" })
        events.insert(("turn/moderationMetadata", payload), at: completionIndex)
        for (method, params) in events {
            await controller.test_handleNotification(method: method, params: params)
        }
        await controller.shutdown()
        var warnings: [String] = []
        for await event in controller.events {
            if case let .livenessActivity(activity) = event, activity.kind == .warning { warnings.append(activity.method) }
            await f.coordinator.test_handleCodexNativeEvent(event, session: f.session, sourceController: controller)
        }
        XCTAssertEqual(warnings, malformed ? ["turn/moderationMetadata"] : [])
        XCTAssertEqual(f.session.runState, .completed)
        XCTAssertEqual(f.session.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: malformed ? 1 : 0))
        XCTAssertEqual(f.session.quietLedger.hiddenSourceIDs.contains(wakeID), !malformed)
        if malformed { XCTAssertTrue(f.session.quietLedger.hiddenSourceIDs.isEmpty) }
        else { XCTAssertGreaterThan(f.session.quietLedger.hiddenSourceIDs.count, 1, "The ack row is hidden with the wake") }
    }
}
