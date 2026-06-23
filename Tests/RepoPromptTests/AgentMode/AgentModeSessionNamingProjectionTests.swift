import Foundation
@_spi(TestSupport) @testable import RepoPrompt
import XCTest

@MainActor
final class AgentModeSessionNamingProjectionTests: XCTestCase {
    func testRenameProjectsCanonicalTitleToIndexedAndIndexlessSidebarsWithoutChangingSelection() async {
        let indexedTabID = UUID()
        let indexlessTabID = UUID()
        let indexedSessionID = UUID()
        let indexlessSessionID = UUID()
        let workspace = WorkspaceModel(
            name: "Session naming projections",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [
                ComposeTabState(
                    id: indexedTabID,
                    name: "Indexed",
                    activeAgentSessionID: indexedSessionID
                ),
                ComposeTabState(
                    id: indexlessTabID,
                    name: "Indexless",
                    activeAgentSessionID: indexlessSessionID
                )
            ],
            activeComposeTabID: indexedTabID
        )
        let fixture = makeWorkspaceFixture(workspace: workspace)
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in SessionNamingFakeCodexController() }
        )
        viewModel.promptManager = fixture.prompt
        viewModel.workspaceManager = fixture.manager

        let owner = viewModel.test_receiveWorkspaceSwitchNotification(workspace)
        let indexedEntry = makeIndexEntry(
            id: indexedSessionID,
            tabID: indexedTabID,
            name: "Indexed"
        )
        viewModel.test_installSessionIndexSnapshot(
            [indexedSessionID: indexedEntry],
            owner: owner,
            latestOwner: owner,
            activeWorkspace: workspace
        )
        let indexedSession = await viewModel.ensureSessionReady(tabID: indexedTabID)
        let indexlessSession = await viewModel.ensureSessionReady(tabID: indexlessTabID)
        viewModel.syncSidebarUIState(
            refresh: true,
            reason: AgentModeViewModel.SidebarRefreshReason.explicit,
            sidebarTabs: fixture.prompt.currentComposeTabs
        )
        let selectedTabID = fixture.prompt.activeComposeTabID
        let initialRevision = viewModel.ui.sessionSidebar.snapshot.revision

        let indexedCanonicalName = await viewModel.renameSession(
            tabID: indexedTabID,
            to: "  Indexed   Canonical  "
        )
        let revisionAfterIndexedRename = viewModel.ui.sessionSidebar.snapshot.revision
        let indexlessCanonicalName = await viewModel.renameSession(
            tabID: indexlessTabID,
            to: "Indexless Canonical"
        )
        let finalRevision = viewModel.ui.sessionSidebar.snapshot.revision

        XCTAssertEqual(indexedCanonicalName, "Indexed Canonical")
        XCTAssertEqual(indexlessCanonicalName, "Indexless Canonical")
        XCTAssertEqual(fixture.prompt.activeComposeTabID, selectedTabID)
        XCTAssertEqual(
            viewModel.test_ownerValidatedSessionIndex[indexedSessionID]?.name,
            "Indexed Canonical"
        )
        XCTAssertNil(viewModel.test_ownerValidatedSessionIndex[indexlessSessionID])
        XCTAssertTrue(indexedSession.isDirty)
        XCTAssertTrue(indexlessSession.isDirty)
        XCTAssertGreaterThan(revisionAfterIndexedRename, initialRevision)
        XCTAssertGreaterThan(finalRevision, revisionAfterIndexedRename)

        let rows = viewModel.sidebarSessions(for: fixture.prompt.currentComposeTabs)
        XCTAssertEqual(rows.first(where: { $0.tabID == indexedTabID })?.title, "Indexed Canonical")
        XCTAssertEqual(rows.first(where: { $0.tabID == indexlessTabID })?.title, "Indexless Canonical")
        XCTAssertEqual(fixture.manager.composeTabName(with: indexedTabID), "Indexed Canonical")
        XCTAssertEqual(fixture.manager.composeTabName(with: indexlessTabID), "Indexless Canonical")
    }

    private func makeIndexEntry(id: UUID, tabID: UUID, name: String) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: id,
            tabID: tabID,
            name: name,
            lastUserMessageAt: Date(),
            savedAt: Date(),
            lastRunStateRaw: AgentSessionRunState.idle.rawValue,
            itemCount: 1,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false,
            parentSessionID: nil,
            hasUnknownConversationContent: false,
            isMCPOriginated: false,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )
    }

    private func makeWorkspaceFixture(
        workspace: WorkspaceModel
    ) -> (manager: WorkspaceManagerViewModel, prompt: PromptViewModel) {
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        manager.setWorkspacesForTesting([workspace])
        manager.activeWorkspace = workspace
        prompt.loadComposeTabsFromWorkspace(workspace)
        return (manager, prompt)
    }
}

private final class SessionNamingFakeCodexController: CodexSessionControllerTurnDispatchTestDefaults {
    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in continuation.finish() }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(
            conversationID: "fake",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil
        )
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(
            conversationID: "fake",
            rolloutPath: nil,
            model: model,
            reasoningEffort: reasoningEffort
        )
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(
            conversationID: "fake",
            rolloutPath: nil,
            model: model,
            reasoningEffort: reasoningEffort
        )
    }

    func readThreadSnapshot(
        includeTurns: Bool,
        timeout: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "fake",
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
    func compactThread() async throws {}

    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(
        _ objective: String
    ) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(
        _ status: CodexNativeSessionController.ThreadGoalStatus
    ) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}
