import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexExecAgentProviderRuntimePreparationTests: XCTestCase {
    func testPrepareUsesRuntimeStateAuthorityAndMapsFailureBeforeMCPBootstrap() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexExecAgentProviderRuntimePreparationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        try "#!/bin/sh\necho 'codex 0.156.0'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let recorder = PreparedRuntimeRecorder()
        let provider = CodexExecAgentProvider(
            config: .init(commandName: executable.path, additionalPathHints: []),
            runtimeStatePreparer: { runtime in
                recorder.record(runtime)
                throw RuntimePreparationFailure.conflict
            }
        )

        do {
            _ = try await provider.prepare()
            XCTFail("prepare must fail when isolated Codex state preparation fails")
        } catch let AIProviderError.invalidConfiguration(detail) {
            XCTAssertTrue(detail.contains("unable to prepare its isolated Codex state"))
            XCTAssertTrue(detail.contains("projection conflict"))
        } catch {
            XCTFail("Expected invalidConfiguration, got \(error)")
        }

        XCTAssertEqual(recorder.callCount, 1)
        XCTAssertEqual(recorder.runtime?.source, .externalOverride)
        XCTAssertEqual(recorder.runtime?.executableURL, executable)
    }
}

private enum RuntimePreparationFailure: Error, LocalizedError {
    case conflict

    var errorDescription: String? {
        "projection conflict"
    }
}

private final class PreparedRuntimeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRuntime: CodexRuntimeAuthority.Runtime?
    private var recordedCallCount = 0

    func record(_ runtime: CodexRuntimeAuthority.Runtime) {
        lock.lock()
        recordedRuntime = runtime
        recordedCallCount += 1
        lock.unlock()
    }

    var runtime: CodexRuntimeAuthority.Runtime? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRuntime
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCallCount
    }
}

@MainActor
final class CodexComputerUseV1Tests: XCTestCase {
    func testGlobalPreferenceDefaultsOffAndCanBeExplicitlyEnabled() throws {
        let suite = "CodexComputerUseV1Tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(CodexAgentModeBooleanPreference.computerUse.isEnabled(defaults: defaults))
        CodexAgentModeBooleanPreference.computerUse.setEnabled(true, defaults: defaults)
        XCTAssertTrue(CodexAgentModeBooleanPreference.computerUse.isEnabled(defaults: defaults))
        CodexAgentModeBooleanPreference.computerUse.setEnabled(false, defaults: defaults)
        XCTAssertFalse(CodexAgentModeBooleanPreference.computerUse.isEnabled(defaults: defaults))
    }

    func testBlockedSessionKindsRemainIneligible() {
        XCTAssertTrue(CodexComputerUseWorkflow.isEligible(
            globalEnabled: true, isCodex: true, isMCPRelated: false, hasActiveLink: false
        ))
        XCTAssertFalse(CodexComputerUseWorkflow.isEligible(
            globalEnabled: false, isCodex: true, isMCPRelated: false, hasActiveLink: false
        ))
        XCTAssertFalse(CodexComputerUseWorkflow.isEligible(
            globalEnabled: true, isCodex: false, isMCPRelated: false, hasActiveLink: false
        ))
        XCTAssertFalse(CodexComputerUseWorkflow.isEligible(
            globalEnabled: true, isCodex: true, isMCPRelated: true, hasActiveLink: false
        ))
        XCTAssertFalse(CodexComputerUseWorkflow.isEligible(
            globalEnabled: true, isCodex: true, isMCPRelated: false, hasActiveLink: true
        ))
    }

    func testArmIsSessionScopedAndDisarmClearsIt() async {
        let viewModel = AgentModeViewModel(
            testWindowID: 81,
            testWorkspacePath: FileManager.default.temporaryDirectory.path,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        viewModel.codexComputerUseEnabledProvider = { true }
        viewModel.codexComputerUseClientPathProvider = { "/fake/OpenAI/Codex Computer Use client" }
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .codexExec

        XCTAssertFalse(viewModel.codexComputerUseIsArmed(tabID: tabID))
        let armResult = await viewModel.armCodexComputerUse(tabID: tabID)
        XCTAssertNil(armResult)
        XCTAssertTrue(viewModel.codexComputerUseIsArmed(tabID: tabID))
        viewModel.disarmCodexComputerUse(tabID: tabID)
        XCTAssertFalse(viewModel.codexComputerUseIsArmed(tabID: tabID))

        let secondArmResult = await viewModel.armCodexComputerUse(tabID: tabID)
        XCTAssertNil(secondArmResult)
        _ = viewModel.test_codexCoordinator.prepareCodexCancellationTeardown(
            session, expectedRunID: nil, capturedTarget: nil
        )
        XCTAssertTrue(viewModel.codexComputerUseIsArmed(tabID: tabID), "Stop preserves session consent")
        viewModel.disarmCodexComputerUse(tabID: tabID)

        viewModel.test_setCurrentTabIDOverride(UUID())
        let staleTabResult = await viewModel.armCodexComputerUse(tabID: tabID)
        XCTAssertNotNil(staleTabResult)
        viewModel.test_setCurrentTabIDOverride(tabID)

        session.isMCPOriginated = true
        let mcpArmResult = await viewModel.armCodexComputerUse(tabID: tabID)
        XCTAssertNotNil(mcpArmResult)
        session.isMCPOriginated = false
        session.parentSessionID = UUID()
        let childArmResult = await viewModel.armCodexComputerUse(tabID: tabID)
        XCTAssertNotNil(childArmResult)
        session.parentSessionID = nil
        viewModel.codexComputerUseEnabledProvider = { false }
        let disabledArmResult = await viewModel.armCodexComputerUse(tabID: tabID)
        XCTAssertNotNil(disabledArmResult)
    }

    func testRebindingRevokesConsentAndRejectsTheOldComposerTarget() async {
        let viewModel = AgentModeViewModel(
            testWindowID: 82,
            testWorkspacePath: FileManager.default.temporaryDirectory.path,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        viewModel.codexComputerUseEnabledProvider = { true }
        viewModel.codexComputerUseClientPathProvider = { "/fake/OpenAI/Codex Computer Use client" }
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .codexExec
        let oldTarget = AgentComposerSubmitTarget(
            tabID: tabID,
            route: .createAgentSessionFromSourceTab,
            expectedSourceTabSessionIdentity: ObjectIdentifier(session),
            expectedSourceAgentSessionID: nil,
            expectedPersistentBindingIdentity: nil,
            expectedBindingTransitionGeneration: session.bindingTransitionGeneration,
            expectedRunState: .idle,
            expectedRunID: nil,
            expectedRunAttemptID: nil,
            expectedSubmissionToken: session.composerSubmissionToken,
            expectedInitialStartLocation: .local
        )
        let armResult = await viewModel.armCodexComputerUse(tabID: tabID, expectedTarget: oldTarget)
        XCTAssertNil(armResult)
        XCTAssertTrue(viewModel.codexComputerUseIsArmed(tabID: tabID))

        session.testInstallPersistentSessionBinding(sessionID: UUID())
        XCTAssertFalse(viewModel.codexComputerUseIsArmed(tabID: tabID))
        XCTAssertNil(session.pendingCodexComputerUseActivation)
        let staleResult = await viewModel.armCodexComputerUse(tabID: tabID, expectedTarget: oldTarget)
        XCTAssertNotNil(staleResult)
    }

    func testFirstSendTransferUsesBoundDestinationAndRefusesPendingLinkAdd() async {
        let viewModel = AgentModeViewModel(
            testWindowID: 83,
            testWorkspacePath: FileManager.default.temporaryDirectory.path,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        viewModel.codexComputerUseEnabledProvider = { true }
        viewModel.codexComputerUseClientPathProvider = { "/fake/OpenAI/Codex Computer Use client" }
        let source = viewModel.session(for: UUID())
        source.selectedAgent = .codexExec
        source.pendingCodexComputerUseActivation = AgentModeViewModel.CodexComputerUseActivation(
            id: UUID(),
            createdAt: Date(),
            binding: nil,
            bindingTransitionGeneration: source.bindingTransitionGeneration
        )
        let destination = viewModel.session(for: UUID())
        destination.selectedAgent = .codexExec
        let destinationSessionID = UUID()
        destination.testInstallPersistentSessionBinding(sessionID: destinationSessionID)
        let bridge = AgentSessionLinkRuntimeBridge.shared

        XCTAssertTrue(bridge.beginComputerUseArming(sessionID: destinationSessionID))
        let refused = await viewModel.transferCodexComputerUseActivation(from: source, to: destination)
        XCTAssertFalse(refused)
        XCTAssertNil(destination.pendingCodexComputerUseActivation)
        XCTAssertTrue(source.wantsCodexComputerUseForNextTurn)
        bridge.endComputerUseArming(sessionID: destinationSessionID)

        let transferred = await viewModel.transferCodexComputerUseActivation(from: source, to: destination)
        XCTAssertTrue(transferred)
        XCTAssertTrue(destination.wantsCodexComputerUseForNextTurn)
        XCTAssertEqual(destination.pendingCodexComputerUseActivation?.binding, destination.persistentSessionBindingIdentity)
        XCTAssertNil(source.pendingCodexComputerUseActivation)
    }

    func testOnlyArmedConfigurationExposesCompanionMCP() {
        let client = "/fake/OpenAI/SkyComputerUseClient"
        let armed = CodexNativeSessionController.defaultAppServerConfigOverrides(
            computerUseEnabled: true, computerUseClientPath: client
        )
        XCTAssertEqual(armed["features.computer_use"] as? Bool, true)
        XCTAssertEqual(armed["mcp_servers.computer-use.command"] as? String, client)
        XCTAssertEqual(armed["mcp_servers.computer-use.args"] as? [String], ["mcp"])
        XCTAssertEqual(armed["mcp_servers.computer-use.enabled"] as? Bool, true)

        for overrides in [
            CodexNativeSessionController.defaultAppServerConfigOverrides(
                computerUseEnabled: false, computerUseClientPath: client
            ),
            CodexNativeSessionController.defaultAppServerConfigOverrides(
                computerUseEnabled: true, computerUseClientPath: nil
            )
        ] {
            XCTAssertEqual(overrides["features.computer_use"] as? Bool, false)
            XCTAssertNil(overrides["mcp_servers.computer-use.command"])
        }
    }

    func testSavedComputerUseServerPreferenceCannotOverrideDisarmedSession() {
        let entry = MCPIntegrationHelper.CodexServerEntry(
            rawName: "computer-use",
            normalizedName: "computer-use",
            cliPathComponent: "computer-use"
        )
        let overrides = CodexNativeSessionController.appServerMCPServerOverrides(
            serverEntries: [entry],
            enabledMCPServerNames: ["computer-use"],
            suppressThirdPartyMCPServers: false,
            computerUseEnabled: false
        )
        XCTAssertEqual(overrides["mcp_servers.computer-use.enabled"] as? Bool, false)
    }

    func testComputerUseElicitationNeverTakesAutomaticAcceptancePath() {
        let params: [String: Any] = [
            "server": "computer-use", "tool": "screenshot", "prompt": "Allow screen access?"
        ]
        XCTAssertNil(CodexNativeSessionController.automaticMCPElicitationResult(params: params))
        XCTAssertNotNil(CodexNativeSessionController.parseMCPElicitationRequest(
            requestID: .int(1),
            method: "mcpServer/elicitation/request",
            params: params,
            activeThreadID: "thread",
            currentTurnID: "turn"
        ))
    }

    func testExplicitSlashRequestParsingDoesNotMatchLookalikes() {
        XCTAssertEqual(CodexComputerUseWorkflow.explicitRequestArguments(in: " /computer-use list apps "), "list apps")
        XCTAssertEqual(CodexComputerUseWorkflow.explicitRequestArguments(in: "/computer-use"), "")
        XCTAssertNil(CodexComputerUseWorkflow.explicitRequestArguments(in: "/computer-useful list apps"))
        XCTAssertNil(CodexComputerUseWorkflow.explicitRequestArguments(in: "Use /computer-use please"))
    }
}
