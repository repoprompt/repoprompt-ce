@testable import RepoPromptApp
import XCTest

@MainActor
final class CodexSwitchboardSessionAdmissionTests: XCTestCase {
    func testManagedRepairNeverRetiresLiveOrUnknownControllerForReconciliation() async {
        for scenario in ["healthy", "reconnect", "features", "workspace", "profile", "workspaceFailure", "recheckedWorkspace", "recheckedFailure"] {
            let controller = Controller()
            var launches = 0
            var resolutions = 0
            let coordinator = makeCoordinator(
                recovery: Recovery(), activeTools: { _ in false }, launched: { launches += 1 },
                replacement: Controller(), workspace: { _ in
                    resolutions += 1
                    if scenario == "workspaceFailure" || (scenario == "recheckedFailure" && resolutions > 1) {
                        throw CodexAccountAdoptionReason.runtimeUnavailable
                    }
                    return .uniform(scenario == "recheckedWorkspace" && resolutions > 1 ? "/synthetic/changed" : "/synthetic/workspace")
                }
            )
            let session = AgentTabSession(tabID: UUID())
            session.selectedAgent = .codexExec
            session.installRunID(UUID())
            session.codexConversationID = "retained-history"
            session.requiresSwitchboardPairing = true
            session.codexController = controller
            session.switchboardAccountControl = CodexSwitchboardSessionControl()
            session.codexControllerWorkspacePaths = .uniform("/synthetic/workspace")
            session.codexControllerPermissionProfile = session.permissionProfile
            session.codexControllerFeatureState = .init(
                computerUseEnabled: false, goalSupportEnabled: false,
                reasoningSummariesEnabled: CodexReasoningSummaries.isEnabled, memoriesEnabled: CodexMemories.isEnabled
            )
            switch scenario {
            case "reconnect": session.codexNeedsReconnect = true
            case "features": session.codexControllerFeatureState?.goalSupportEnabled = true
            case "workspace": session.codexControllerWorkspacePaths = .uniform("/synthetic/previous")
            case "profile": session.codexControllerPermissionProfile = nil
            default: break
            }
            let generation = session.codexControllerGeneration
            await coordinator.ensureCodexNativeSession(session: session, allowMissingRolloutFallback: false, allowResumeTimeoutFallback: false)
            XCTAssertTrue(session.codexController === controller, scenario)
            XCTAssertEqual(session.codexControllerGeneration, generation, scenario)
            XCTAssertEqual(session.codexConversationID, "retained-history", scenario)
            XCTAssertEqual(controller.shutdowns, 0, scenario)
            XCTAssertEqual(controller.starts, 0, scenario)
            XCTAssertEqual(launches, 0, scenario)
            XCTAssertEqual(session.switchboardAccountControl?.state, scenario == "healthy" ? .waitingIdle(.runtimeUnavailable) : .failedUnknown(.runtimeUnavailable), scenario)
            await session.switchboardAccountControl?.revokeAndWait()
            session.codexEventTask?.cancel()
        }
    }

    func testOrdinaryControllerReconciliationStillReplacesItsOwnBackend() async {
        let controller = Controller()
        controller.usesManagedHTTPAccountAdoption = false
        let replacement = Controller()
        replacement.usesManagedHTTPAccountAdoption = false
        var launches = 0
        let coordinator = makeCoordinator(recovery: Recovery(), activeTools: { _ in false }, launched: { launches += 1 }, replacement: replacement)
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        session.installRunID(UUID())
        session.codexConversationID = "retained-history"
        session.codexController = controller
        // Missing feature metadata uses the ordinary replacement path.
        await coordinator.ensureCodexNativeSession(session: session)
        XCTAssertTrue(session.codexController === replacement)
        XCTAssertEqual(controller.shutdowns, 1)
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(session.codexConversationID, "retained-history")
        session.codexEventTask?.cancel()
    }

    func testCoordinatorRefusesManagedHistoryBeforeAnyBackendOrGlobalLoginWork() async {
        let recovery = Recovery()
        var launches = 0
        let coordinator = makeCoordinator(recovery: recovery, activeTools: { _ in false }, launched: { launches += 1 })
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        session.requiresSwitchboardPairing = true
        session.codexConversationID = "retained-history"
        await coordinator.ensureCodexNativeSession(session: session)
        let outcome = await coordinator.sendCodexNativeMessage(session: session, text: "synthetic input", attachments: [])
        if case .preDispatchRejected = outcome {} else { XCTFail("Unpaired managed history must reject provider dispatch") }
        XCTAssertEqual(launches, 0)
        let calls = await recovery.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(session.codexConversationID, "retained-history")
        XCTAssertNil(session.codexController)
    }

    func testCoordinatorUsesLiveToolAndQueueAdmissionSignals() {
        var hasTools = false
        let coordinator = makeCoordinator(recovery: Recovery(), activeTools: { _ in hasTools }, launched: {})
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        session.installRunID(UUID())
        XCTAssertNil(coordinator.switchboardSetupRejection(for: session))
        hasTools = true
        XCTAssertEqual(coordinator.switchboardSetupRejection(for: session), .activeTools)
        hasTools = false
        session.pendingInstructions = ["accepted work"]
        XCTAssertEqual(coordinator.switchboardSetupRejection(for: session), .queuedDispatch)
        session.pendingInstructions = []
        session.runState = .running
        XCTAssertEqual(coordinator.switchboardSetupRejection(for: session), .busy)
        session.runState = .idle
        session.parentSessionID = UUID()
        XCTAssertEqual(coordinator.switchboardSetupRejection(for: session), .identityChanged)
    }

    func testOrdinaryAndChildSessionsNeverInheritPairing() {
        let root = AgentTabSession(tabID: UUID())
        root.selectedAgent = .codexExec
        XCTAssertFalse(root.requiresSwitchboardPairing)
        XCTAssertNil(root.switchboardDispatchBlockReason)
        XCTAssertFalse(root.allowsSwitchboardBootstrap)
        let child = AgentTabSession(tabID: UUID())
        child.selectedAgent = .codexExec
        child.parentSessionID = UUID()
        XCTAssertFalse(child.requiresSwitchboardPairing)
        child.requiresSwitchboardPairing = true
        child.switchboardAccountControl = CodexSwitchboardSessionControl()
        XCTAssertFalse(child.allowsSwitchboardBootstrap)
        XCTAssertNotNil(child.switchboardDispatchBlockReason)
    }

    func testSavedManagedHistoryIsBlockedUntilExplicitRootPairing() {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        session.codexConversationID = "retained-history"
        session.requiresSwitchboardPairing = true
        XCTAssertNotNil(session.switchboardDispatchBlockReason)
        XCTAssertFalse(session.allowsSwitchboardBootstrap)
        session.switchboardAccountControl = CodexSwitchboardSessionControl()
        // This is credential-free preparation, not an ordinary global-login gate.
        XCTAssertTrue(session.allowsSwitchboardBootstrap)
        XCTAssertNotNil(session.switchboardDispatchBlockReason)
        session.switchboardAccountControl?.revoke()
        XCTAssertFalse(session.allowsSwitchboardBootstrap)
        XCTAssertNotNil(session.switchboardDispatchBlockReason)
        XCTAssertEqual(session.codexConversationID, "retained-history")
    }

    func testLateDispatchLeaseReleaseCannotUndoConsentRevocation() throws {
        var gate = CodexManagedHTTPPolicy.RequestGate()
        try gate.claimStartup()
        try gate.bindThread("retained")
        let lease = try gate.reserve()
        let authorization = CodexAccountAdoptionAuthorization()
        try gate.bindAuthorization(authorization)
        authorization.invalidate()
        gate.finish(lease, allowTurns: true)
        XCTAssertThrowsError(try gate.authorize(method: "turn/start"))
        XCTAssertThrowsError(try gate.authorize(method: "turn/steer"))
        XCTAssertThrowsError(try gate.authorize(method: "review/start"))
    }

    private func makeCoordinator(
        recovery: Recovery, activeTools: @escaping (UUID) -> Bool, launched: @escaping () -> Void,
        replacement: Controller? = nil,
        workspace: @escaping (AgentTabSession) throws -> CodexRuntimeWorkspacePaths = { _ in .uniform("/synthetic/workspace") }
    ) -> CodexAgentModeCoordinator {
        CodexAgentModeCoordinator(
            windowID: 1, runtimeWorkspacePathsProvider: workspace,
            codexControllerFactory: { _, _, _, _, _, _, _, _, _ in
                launched()
                if let replacement { return replacement }
                fatalError("This refusal test must never create a native backend")
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            shouldManageCodexTooling: false, authRecovery: recovery,
            codexHookApprovalSettings: HookSettings(), activeToolQuery: activeTools,
            preferenceDefaults: UserDefaults(suiteName: "SwitchboardAdmissionTests.\(UUID().uuidString)")!
        )
    }

    private final class Controller: CodexSessionControlling {
        var shutdowns = 0
        var starts = 0
        var hasActiveThread = true
        var usesManagedHTTPAccountAdoption = true
        let currentSessionReference: CodexNativeSessionController.SessionRef? = .init(conversationID: "retained-history")
        let events = AsyncStream<CodexNativeSessionController.Event> { _ in }
        func ensureEventsStreamReady() {}
        func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String) async throws -> CodexNativeSessionController.SessionRef {
            starts += 1
            throw CodexAccountAdoptionReason.runtimeUnavailable
        }

        func startUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexTurnStartReceipt {
            throw CodexAccountAdoptionReason.runtimeUnavailable
        }

        func steerUserTurn(text: String, images: [AgentImageAttachment], expectedTurnID: String) async throws -> CodexTurnSteerReceipt {
            throw CodexAccountAdoptionReason.runtimeUnavailable
        }

        func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
            throw CodexAccountAdoptionReason.runtimeUnavailable
        }

        func cancelCurrentTurn() async {}
        func shutdown() async {
            shutdowns += 1
        }

        func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
    }

    private struct HookSettings: CodexHookApprovalSettingsProviding {
        func codexHookApprovalStrictModeEnabled(workspaceID: UUID?) -> Bool {
            false
        }
    }

    private actor Recovery: CodexManagedAuthRecovering {
        var calls = 0
        func refreshManagedAccount() -> CodexManagedAuthRefreshResult {
            calls += 1
            return .requiresUserLogin(message: "synthetic unavailable")
        }

        func managedAccountSnapshot() -> CodexManagedAccount? {
            calls += 1
            return nil
        }

        func startManagedChatgptLogin(openURL: @MainActor @escaping @Sendable (URL) -> Void) -> CodexManagedChatgptLoginResult {
            calls += 1
            return .failed(message: "synthetic unavailable")
        }

        func startManagedChatgptDeviceCodeLogin(presentDeviceCode: @MainActor @escaping @Sendable (CodexManagedChatgptDeviceCode, Bool) -> Void) -> CodexManagedChatgptLoginResult {
            calls += 1
            return .failed(message: "synthetic unavailable")
        }

        func logoutManagedAccount() -> CodexManagedAuthLogoutResult {
            calls += 1
            return .failed(message: "synthetic unavailable")
        }
    }
}
