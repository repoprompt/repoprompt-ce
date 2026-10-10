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
        routeOwnerValidator: @escaping CodexAgentModeCoordinator.CodexRouteOwnerValidator = { _, _, _, _ in true },
        companionReady: @escaping () -> Bool = { true },
        freshSession: Bool = false,
        shouldManageCodexTooling: Bool = true
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
            mcpServerEnabler: { true },
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
        let fixture = try makeSubmissionFixture()
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
        _ = try XCTUnwrap(vm.test_ensureSessionBoundToTab(session))
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
        let sessionID = try XCTUnwrap(vm.test_ensureSessionBoundToTab(session))
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
            let sessionID = try XCTUnwrap(vm.test_ensureSessionBoundToTab(session))
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
        let sessionID = try XCTUnwrap(vm.test_ensureSessionBoundToTab(session))
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

    private func makeSubmissionFixture() throws -> Fixture {
        let fixture = makeFixture([[.success("submission-thread")]], freshSession: true, shouldManageCodexTooling: false)
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
        let sessionID = try XCTUnwrap(vm.test_ensureSessionBoundToTab(session))
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
            .init(queueID: UUID(), providerText: "continue locally", images: [], taggedFileAttachments: [], draftText: "continue locally", optimisticUserItemID: nil, origin: origin, dispatchTicket: nil, isLocalUserInput: local)
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
            _ = try XCTUnwrap(fixture.viewModel.test_ensureSessionBoundToTab(fixture.session))
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
            shouldManageCodexTooling: false, computerUseCompanionReady: { true },
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
            shouldManageCodexTooling: true, computerUseCompanionReady: { true },
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
        let sessionID = try XCTUnwrap(fixture.viewModel.test_ensureSessionBoundToTab(session))
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

    func testTwoResumeTimeoutsThenFreshRoutingFailureRetainsPersistedTupleAndLaterSend() async throws {
        let fixture = makeFixture([
            [.timeout],
            [.timeout],
            [.success("failed-fresh-thread")],
            [.success("later-fresh-thread")]
        ])
        await fixture.coordinator.ensureCodexNativeSession(session: fixture.session)
        XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 1)
        assertOldTuple(fixture.session)

        let second = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer { second.cancel() }
        try await waitForPendingStart(fixture)
        XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 2)
        assertOldTuple(fixture.session)
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })
        let failedRunID = try XCTUnwrap(fixture.session.runID)
        await MCPRoutingWaiter.shared.notifyFailed(runID: failedRunID)
        await second.value

        assertOldTuple(fixture.session)
        XCTAssertFalse(fixture.coordinator.test_hasPendingCodexStart(for: fixture.session))
        XCTAssertFalse(fixture.session.codexNeedsReconnect)
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })
        XCTAssertEqual(fixture.factory.controllers[2].startedTurnCount, 0)

        var saved: AgentSession?
        fixture.viewModel.test_setAgentSessionSaver { agentSession, _, _ in
            saved = agentSession
            return FileManager.default.temporaryDirectory.appendingPathComponent("codex-wedge-\(UUID().uuidString).json")
        }
        await fixture.viewModel.flushSave(for: fixture.session.tabID)
        XCTAssertEqual(saved?.codexConversationID, Self.oldThreadID)
        XCTAssertEqual(saved?.codexRolloutPath, Self.oldRolloutPath)
        XCTAssertEqual(saved?.providerCleanupHandle?.conversationID, Self.oldThreadID)

        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "codex-resume-wedge-later-send")
        let later = Task {
            await fixture.coordinator.sendCodexNativeMessage(
                session: fixture.session,
                text: "continue",
                attachments: []
            )
        }
        defer { later.cancel() }
        try await waitForPendingStart(fixture)
        XCTAssertEqual(fixture.factory.controllers[3].receivedExistingIDs, [nil])
        assertOldTuple(fixture.session)
        try await MCPRoutingWaiter.shared.notifyFailed(runID: XCTUnwrap(fixture.session.runID))
        _ = await later.value
        assertOldTuple(fixture.session)
        XCTAssertFalse(fixture.session.codexNeedsReconnect)
        XCTAssertEqual(fixture.factory.controllers[2].startedTurnCount, 0)
        XCTAssertEqual(fixture.factory.controllers[3].startedTurnCount, 0)
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })
    }

    func testRepeatedTimeoutReplacementRenewsAdmissionAndDiscardsOldRoutingSignal() async throws {
        let responseGate = TestReleaseFence(name: "replacement response")
        let fixture = makeFixture([
            [.timeout],
            [.routedTimeout],
            [.suspendedSuccess("replacement-thread", responseGate)]
        ])
        await fixture.coordinator.ensureCodexNativeSession(session: fixture.session)
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
        XCTAssertNil(staleOutcome, "the retired process's routed signal must not satisfy the replacement wait")
        let pendingPolicies = await ServerNetworkManager.shared.debugPendingPolicySnapshot(for: clientName)
        XCTAssertTrue(pendingPolicies.contains { $0.runID == runID }, "replacement needs fresh admission after the old permit expired")
        assertOldTuple(fixture.session)
        XCTAssertEqual(fixture.factory.controllers[1].shutdownCount, 1)
        XCTAssertEqual(fixture.factory.controllers[2].runID, runID)

        responseGate.release()
        try await waitForPendingStart(fixture)
        assertOldTuple(fixture.session)
        XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 2)
        XCTAssertEqual(fixture.factory.controllers[2].startedTurnCount, 0)
        await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
        await startup.value
        XCTAssertEqual(fixture.session.codexConversationID, "replacement-thread")
        XCTAssertEqual(fixture.session.providerCleanupHandle?.conversationID, "replacement-thread")
        XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 0)
        XCTAssertEqual(fixture.session.items.count(where: { $0.text.contains("Started a fresh thread") }), 1)
        let retainedPolicies = await ServerNetworkManager.shared.debugPendingPolicySnapshot(for: clientName)
        XCTAssertTrue(retainedPolicies.contains { $0.runID == runID }, "old lease cleanup must not revoke successor admission")
        await ServerNetworkManager.shared.revokeClientConnectionPolicy(for: clientName, windowID: 1, runID: runID)
        await MCPRoutingWaiter.shared.cleanup(runID: runID)
    }

    func testOversizedResumeResponseFallsBackToFreshThreadOnFirstFailure() async throws {
        let fixture = makeFixture([
            [.oversizedResume],
            [.success("fresh-after-oversized-resume")]
        ])
        let startup = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer { startup.cancel() }
        try await waitForPendingStart(fixture)

        XCTAssertEqual(fixture.factory.controllers.count, 2, "an oversized resume must retire the poisoned controller")
        XCTAssertEqual(fixture.factory.controllers[0].receivedExistingIDs, [Self.oldThreadID])
        XCTAssertEqual(fixture.factory.controllers[0].shutdownCount, 1)
        XCTAssertEqual(fixture.factory.controllers[1].receivedExistingIDs, [nil])
        XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 0, "a frame overflow is not a timeout")
        assertOldTuple(fixture.session)
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })

        try await MCPRoutingWaiter.shared.notifyRouted(runID: XCTUnwrap(fixture.session.runID))
        await startup.value

        XCTAssertEqual(fixture.session.codexConversationID, "fresh-after-oversized-resume")
        XCTAssertEqual(fixture.session.providerCleanupHandle?.conversationID, "fresh-after-oversized-resume")
        XCTAssertEqual(fixture.session.codexNativeStartupDisposition, .resumeFellBackToFresh)
        XCTAssertFalse(fixture.session.codexNeedsReconnect)
        XCTAssertEqual(
            fixture.session.items.count(where: { $0.text.contains("history was too large to load. Started a fresh thread") }),
            1
        )
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("after repeated timeout") })
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("frame budget") }, "the overflow must not surface as a send failure")
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
    private var turnTexts: [String] = []
    private var goals: [String] = []
    private var steers: [String] = []
    private var interrupts: [String] = []
    private var shutdowns = 0
    private var qaResponses = 0
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
        case .timeout:
            throw CodexAppServerClient.ClientError.requestFailed(.init(
                method: "thread/resume",
                code: nil,
                message: "Request timed out after 120.0s",
                data: nil
            ))
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
        images _: [AgentImageAttachment],
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

    func steerUserTurn(text: String, images _: [AgentImageAttachment], expectedTurnID: String) async throws -> CodexTurnSteerReceipt {
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
