@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentContextExportRenderSnapshotTests: XCTestCase {
    func testRenderSnapshotReusesOneBindingResolutionAcrossIdentityAndReadinessDerivations() {
        let promptManager = makePromptManager()
        let viewModel = makeAgentModeViewModel()
        let sessionID = UUID()
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        viewModel.test_installLiveSession(session)
        XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session))
        viewModel.test_resetPersistentBindingResolutionSnapshotBuildCount()
        var bindingResolutionCount = 0
        let context = AgentContextExportViewContext(
            promptManager: promptManager,
            selectionCoordinator: nil,
            currentTabID: tabID,
            activeAgentSessionID: sessionID,
            worktreeBindingsProvider: { requestedSessionID, requestedTabID in
                bindingResolutionCount += 1
                XCTAssertEqual(requestedSessionID, sessionID)
                XCTAssertEqual(requestedTabID, tabID)
                return viewModel.worktreeBindings(
                    forAgentSessionID: requestedSessionID,
                    tabID: requestedTabID
                )
            }
        )

        let snapshot = context.makeRenderSnapshot()
        let coordinator = AgentSelectedFilesModelCoordinator()

        for _ in 0 ..< 10 {
            _ = snapshot.modelRequestIdentity
            _ = coordinator.loadedFileCodemapCountSummary(for: snapshot.modelRequestIdentity)
            _ = AgentSelectedFilesModelCoordinator.unresolvedFileCodemapCountReadiness(
                for: snapshot.modelRequestIdentity,
                summary: AgentContextFileCodemapCountSummary.intent(from: snapshot.selectionSummary)
            )
        }

        XCTAssertEqual(bindingResolutionCount, 1)
        XCTAssertEqual(viewModel.test_persistentBindingResolutionBuildCount, 1)
    }

    func testSameTurnBindingConflictIsVisibleToNextAuthoritativeResolution() {
        let viewModel = makeAgentModeViewModel()
        let sessionID = UUID()
        let firstTabID = UUID()
        let secondTabID = UUID()
        let firstSession = AgentModeViewModel.TabSession(tabID: firstTabID)
        let secondSession = AgentModeViewModel.TabSession(tabID: secondTabID)

        viewModel.test_installLiveSession(firstSession)
        XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: firstSession))
        viewModel.test_resetPersistentBindingResolutionSnapshotBuildCount()
        XCTAssertEqual(viewModel.test_bindingResolution(sessionID: sessionID), .unique(tabID: firstTabID))

        viewModel.test_installLiveSession(secondSession)
        XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: secondSession))

        let expectedConflicts = [firstTabID, secondTabID].sorted { $0.uuidString < $1.uuidString }
        XCTAssertEqual(
            viewModel.test_bindingResolution(sessionID: sessionID),
            .ambiguous(tabIDs: expectedConflicts)
        )
        XCTAssertEqual(viewModel.test_persistentBindingResolutionBuildCount, 2)
    }

    private func makePromptManager() -> PromptViewModel {
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        return PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -990,
            settingsManager: WindowSettingsManager(windowID: -990)
        )
    }

    private func makeAgentModeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: -990,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Binding-resolution tests must not start a Codex session")
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
    }
}
