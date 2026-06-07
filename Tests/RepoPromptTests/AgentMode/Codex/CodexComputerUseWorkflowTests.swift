import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class CodexComputerUseWorkflowTests: XCTestCase {
    override func tearDown() {
        CodexComputerUseWorkflow.setEnabledForTesting(nil)
        CodexComputerUseWorkflow.setPrerequisiteSnapshotForTesting(nil)
        super.tearDown()
    }

    func testAvailabilityRequiresOptInPluginAndMacPermissions() {
        let ready = CodexComputerUseAvailability(
            featureOptIn: true,
            prerequisites: .ready
        )
        XCTAssertTrue(ready.isReady)
        XCTAssertEqual(ready.missingPrerequisites, [])

        let disabled = CodexComputerUseAvailability(
            featureOptIn: false,
            prerequisites: .ready
        )
        XCTAssertFalse(disabled.isReady)
        XCTAssertEqual(disabled.missingPrerequisites, [.featureOptIn])
        XCTAssertTrue(disabled.primaryUnavailableMessage.contains("Enable Computer Use"))

        let missingPlugin = CodexComputerUseAvailability(
            featureOptIn: true,
            prerequisites: .init(
                pluginInstalled: false,
                screenRecordingGranted: true,
                accessibilityGranted: true
            )
        )
        XCTAssertFalse(missingPlugin.isReady)
        XCTAssertEqual(missingPlugin.missingPrerequisites, [.plugin])
        XCTAssertTrue(missingPlugin.primaryUnavailableMessage.contains("MCP server"))

        let missingPermissions = CodexComputerUseAvailability(
            featureOptIn: true,
            prerequisites: .init(
                pluginInstalled: true,
                screenRecordingGranted: false,
                accessibilityGranted: false
            )
        )
        XCTAssertFalse(missingPermissions.isReady)
        XCTAssertEqual(missingPermissions.missingPrerequisites, [.screenRecording, .accessibility])
        XCTAssertTrue(missingPermissions.primaryUnavailableMessage.contains("Screen Recording"))
        XCTAssertTrue(missingPermissions.primaryUnavailableMessage.contains("Accessibility"))
    }

    func testSlashCommandHiddenAndActionableWhenPrerequisitesMissing() {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        CodexComputerUseWorkflow.setPrerequisiteSnapshotForTesting(.init(
            pluginInstalled: false,
            screenRecordingGranted: true,
            accessibilityGranted: true
        ))
        let viewModel = makeViewModel()
        let session = preparedCodexSession(in: viewModel)

        let message = viewModel.test_codexCoordinator.nativeSlashCommandAvailabilityMessage(
            .computerUse,
            argumentsText: "",
            session: session
        )
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("MCP server") == true)
        XCTAssertTrue(message?.contains("Settings → Agent Mode → Computer Use") == true)

        let suggestions = viewModel.test_codexCoordinator.nativeSlashCommandSuggestions(
            for: session,
            query: "computer",
            limit: 10
        )
        XCTAssertFalse(suggestions.contains { $0.displayName == "/computer-use" })
    }

    func testSlashCommandAvailableWhenPrerequisitesSatisfied() {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        CodexComputerUseWorkflow.setPrerequisiteSnapshotForTesting(.ready)
        let viewModel = makeViewModel()
        let session = preparedCodexSession(in: viewModel)

        XCTAssertNil(viewModel.test_codexCoordinator.nativeSlashCommandAvailabilityMessage(
            .computerUse,
            argumentsText: "",
            session: session
        ))

        let suggestions = viewModel.test_codexCoordinator.nativeSlashCommandSuggestions(
            for: session,
            query: "computer",
            limit: 10
        )
        XCTAssertTrue(suggestions.contains { $0.displayName == "/computer-use" })
    }

    func testPendingComputerUseActivationReconnectsControllerWithEnabledFlag() async {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        CodexComputerUseWorkflow.setPrerequisiteSnapshotForTesting(.ready)
        let existingController = ComputerUseFakeCodexController()
        var requestedComputerUseFlags: [Bool] = []
        let replacementController = ComputerUseFakeCodexController()
        let viewModel = makeViewModel { _, _, _, _, _, _, computerUseEnabled in
            requestedComputerUseFlags.append(computerUseEnabled)
            return replacementController
        }
        let session = preparedCodexSession(in: viewModel, controller: existingController)
        session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        session.codexControllerComputerUseEnabled = false

        await viewModel.test_codexCoordinator.ensureCodexNativeSession(
            session: session,
            policyAlreadyInstalled: true,
            allowMissingRolloutFallback: false,
            allowResumeTimeoutFallback: false
        )

        XCTAssertEqual(requestedComputerUseFlags, [true])
        XCTAssertTrue(session.codexControllerComputerUseEnabled)
        XCTAssertTrue(replacementController.startOrResumeCallCount > 0)
    }

    func testComputerUseActivationSettlesAfterOneTurnAndReconnectsDisabled() async {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        CodexComputerUseWorkflow.setPrerequisiteSnapshotForTesting(.ready)
        let existingController = ComputerUseFakeCodexController()
        var requestedComputerUseFlags: [Bool] = []
        let replacementController = ComputerUseFakeCodexController()
        let viewModel = makeViewModel { _, _, _, _, _, _, computerUseEnabled in
            requestedComputerUseFlags.append(computerUseEnabled)
            return replacementController
        }
        let session = preparedCodexSession(in: viewModel, controller: existingController)
        session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        session.codexControllerComputerUseEnabled = true

        viewModel.test_codexCoordinator.test_settleCodexComputerUseActivationAfterTurn(session)

        XCTAssertNil(session.pendingCodexComputerUseActivation)
        XCTAssertNil(session.codexController)
        XCTAssertFalse(session.codexControllerComputerUseEnabled)

        await viewModel.test_codexCoordinator.ensureCodexNativeSession(
            session: session,
            policyAlreadyInstalled: true,
            allowMissingRolloutFallback: false,
            allowResumeTimeoutFallback: false
        )

        XCTAssertEqual(requestedComputerUseFlags, [false])
        XCTAssertFalse(session.codexControllerComputerUseEnabled)
        XCTAssertTrue(replacementController.startOrResumeCallCount > 0)
    }

    func testComputerUseMCPElicitationAutoAcceptIsNarrowlyScoped() async throws {
        let acceptingController = makeControllerForElicitation(
            computerUseEnabled: true,
            approvalPolicy: .never,
            sandboxMode: .dangerFullAccess
        )
        let result = await acceptingController.test_computerUseMCPElicitationAutoAcceptResult(params: [
            "mcpServer": "computer-use",
            "prompt": "Computer Use wants to continue"
        ])
        let accepted = try XCTUnwrap(result)
        XCTAssertEqual(accepted["action"] as? String, "accept")
        let meta = try XCTUnwrap(accepted["_meta"] as? [String: Any])
        XCTAssertEqual(meta["repoPromptAutoAccepted"] as? Bool, true)
        XCTAssertEqual(meta["reason"] as? String, "explicit_computer_use_full_access")

        let disabledController = makeControllerForElicitation(
            computerUseEnabled: false,
            approvalPolicy: .never,
            sandboxMode: .dangerFullAccess
        )
        let disabledResult = await disabledController.test_computerUseMCPElicitationAutoAcceptResult(params: [
            "mcpServer": "computer-use"
        ])
        XCTAssertNil(disabledResult)

        let sandboxedController = makeControllerForElicitation(
            computerUseEnabled: true,
            approvalPolicy: .never,
            sandboxMode: .workspaceWrite
        )
        let sandboxedResult = await sandboxedController.test_computerUseMCPElicitationAutoAcceptResult(params: [
            "mcpServer": "computer-use"
        ])
        XCTAssertNil(sandboxedResult)

        XCTAssertTrue(CodexNativeSessionController.test_isComputerUseMCPElicitationRequest(params: [
            "mcp_server_name": "computer-use"
        ]))
        XCTAssertFalse(CodexNativeSessionController.test_isComputerUseMCPElicitationRequest(params: [
            "mcpServer": MCPIntegrationHelper.repoPromptMCPServerName
        ]))
    }

    private func makeViewModel(
        factory: CodexAgentModeCoordinator.CodexControllerFactory? = nil
    ) -> AgentModeViewModel {
        AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in ComputerUseFakeCodexController() },
            codexControllerFactoryWithComputerUse: factory,
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in }
        )
    }

    private func preparedCodexSession(
        in viewModel: AgentModeViewModel,
        controller: ComputerUseFakeCodexController? = nil
    ) -> AgentModeViewModel.TabSession {
        let session = viewModel.session(for: UUID())
        session.selectedAgent = .codexExec
        session.runID = UUID()
        session.runState = .idle
        session.codexController = controller
        session.codexControllerGoalSupportEnabled = CodexGoalSupport.isEnabled
        return session
    }

    private func makeControllerForElicitation(
        computerUseEnabled: Bool,
        approvalPolicy: CodexAgentToolPreferences.ApprovalPolicy,
        sandboxMode: CodexAgentToolPreferences.SandboxMode
    ) -> CodexNativeSessionController {
        CodexNativeSessionController(
            client: CodexAppServerClient(),
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            options: .agentModeDefault(
                forceExperimentalSteering: true,
                approvalPolicyProvider: { approvalPolicy },
                sandboxModeProvider: { sandboxMode },
                computerUseEnabledProvider: { computerUseEnabled }
            )
        )
    }
}

private final class ComputerUseFakeCodexController: CodexSessionControlling {
    private(set) var startOrResumeCallCount = 0

    var hasActiveThread: Bool {
        true
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in continuation.finish() }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String) async throws -> CodexNativeSessionController.SessionRef {
        startOrResumeCallCount += 1
        return CodexNativeSessionController.SessionRef(conversationID: "computer-use-test", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?) async throws -> CodexNativeSessionController.SessionRef {
        startOrResumeCallCount += 1
        return CodexNativeSessionController.SessionRef(conversationID: "computer-use-test", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexNativeSessionController.SessionRef {
        startOrResumeCallCount += 1
        return CodexNativeSessionController.SessionRef(conversationID: "computer-use-test", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(includeTurns: Bool, timeout: TimeInterval?) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "computer-use-test",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func setThreadName(_ name: String, threadID: String?) async throws {}
    func sendUserMessage(_ text: String) async throws {}
    func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {}
    func sendUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?) async throws {}
    func sendUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?, serviceTier: String?) async throws {}
    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_ objective: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_ status: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}
