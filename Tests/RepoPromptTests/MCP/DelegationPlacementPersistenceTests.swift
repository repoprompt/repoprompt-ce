import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptSecureStorage
import XCTest

@MainActor
final class DelegationPlacementPersistenceTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let dataService: AgentSessionDataService
        let manager: WorkspaceManagerViewModel
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let sessionID: UUID
        let workspace: WorkspaceModel
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DelegationPlacement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dataService = AgentSessionDataService()
        await dataService.test_setWorkspaceRootOverride(root)
        let tabID = UUID()
        let files = WorkspaceFilesViewModel()
        let keys = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let api = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keys), keyManager: keys, loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: files, apiSettingsViewModel: api, windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: files, promptViewModel: prompt, performInitialWorkspaceActivation: false
        )
        let workspace = WorkspaceModel(
            name: "Placement target", repoPaths: [], ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID)], activeComposeTabID: tabID
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        let viewModel = AgentModeViewModel(
            testWindowID: 1, testWorkspacePath: root.path,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Placement tests must not start a provider")
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        viewModel.workspaceManager = manager
        viewModel.test_setCurrentTabIDOverride(tabID)
        viewModel.test_setAgentSessionSaver { session, workspace, count in
            try await dataService.saveAgentSession(
                session, for: workspace, preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: count
            )
        }
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        let sessionID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(session))
        addTeardownBlock { @MainActor in
            session.saveDebounceTask?.cancel()
            viewModel.test_setCurrentTabIDOverride(nil)
            _ = manager
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(
            root: root, dataService: dataService, manager: manager, viewModel: viewModel,
            session: session, sessionID: sessionID, workspace: workspace
        )
    }

    /// A fresh owner reads the actual JSON after the production commit acknowledgement. No test
    /// flush participates: the commit itself must drive and await the ordinary durable save.
    private func reopen(_ fixture: Fixture) async throws -> AgentSession? {
        let reopened = AgentSessionDataService()
        await reopened.test_setWorkspaceRootOverride(fixture.root)
        return try await reopened.loadAgentSession(id: fixture.sessionID, for: fixture.workspace)
    }

    func testLivePlacementAcknowledgementSurvivesReopen() async throws {
        let fixture = try await makeFixture()
        let parent = UUID(), scope = UUID(), spawnParent = UUID()
        fixture.session.parentSessionID = spawnParent
        let commit = try XCTUnwrap(fixture.viewModel.commitDelegationPlacement(
            sessionID: fixture.sessionID, organizationalParentID: parent, delegationScopeID: scope
        ))
        try await commit.persisted()
        XCTAssertFalse(fixture.session.isDirty)
        let restored = try await reopen(fixture)
        XCTAssertEqual(restored?.organizationalParentID, parent)
        XCTAssertEqual(restored?.delegationScopeID, scope)
        XCTAssertEqual(restored?.parentSessionID, spawnParent, "Placement must preserve spawn provenance")
        XCTAssertEqual(restored?.id, fixture.sessionID)
    }

    func testLivePlacementSaveFailureKeepsMemoryChangeAndRejectsDurableAcknowledgement() async throws {
        struct SaveFailure: Error {}
        let fixture = try await makeFixture()
        let priorParent = UUID(), nextParent = UUID()
        var original = AgentSession(id: fixture.sessionID, name: "Original")
        original.organizationalParentID = priorParent
        _ = try await fixture.dataService.saveAgentSession(original, for: fixture.workspace)
        fixture.viewModel.test_setAgentSessionSaver { _, _, _ in throw SaveFailure() }
        let commit = try XCTUnwrap(fixture.viewModel.commitDelegationPlacement(
            sessionID: fixture.sessionID, organizationalParentID: nextParent, delegationScopeID: UUID()
        ))
        do {
            try await commit.persisted()
            XCTFail("A failed save cannot acknowledge durable placement")
        } catch DelegationPlacementPersistenceError.saveFailed {
            // Expected: the caller can return applied-in-memory with persistence failure.
        }
        XCTAssertEqual(fixture.session.organizationalParentID, nextParent)
        XCTAssertTrue(fixture.session.isDirty, "The failed owner remains dirty for recovery")
        let restored = try await reopen(fixture)
        XCTAssertEqual(restored?.organizationalParentID, priorParent)
    }

    func testNewerPlacementCannotAcknowledgeOlderQueuedPlacement() async throws {
        let fixture = try await makeFixture()
        let firstParent = UUID(), secondParent = UUID(), scope = UUID()
        // Both commits apply synchronously before either queued persistence task can start.
        let first = try XCTUnwrap(fixture.viewModel.commitDelegationPlacement(
            sessionID: fixture.sessionID, organizationalParentID: firstParent, delegationScopeID: scope
        ))
        let second = try XCTUnwrap(fixture.viewModel.commitDelegationPlacement(
            sessionID: fixture.sessionID, organizationalParentID: secondParent, delegationScopeID: scope
        ))
        do {
            try await first.persisted()
            XCTFail("Saving a successor must not acknowledge the superseded placement")
        } catch DelegationPlacementPersistenceError.superseded {}
        try await second.persisted()
        let restored = try await reopen(fixture)
        XCTAssertEqual(restored?.organizationalParentID, secondParent)
        XCTAssertEqual(restored?.delegationScopeID, scope)
    }

    func testUnloadedPlacementReportsMissingFileAndPersistsExistingProvenance() async throws {
        let fixture = try await makeFixture()
        let parent = UUID(), scope = UUID(), creator = UUID()
        do {
            try await fixture.dataService.updateDelegationPlacement(
                id: fixture.sessionID, organizationalParentID: parent, delegationScopeID: scope,
                for: fixture.workspace
            )
            XCTFail("A missing file is a failed commit, not a successful no-op")
        } catch DelegationPlacementPersistenceError.sessionFileMissing {}
        var original = AgentSession(id: fixture.sessionID, name: "Unloaded")
        original.createdByOverseerSessionID = creator
        _ = try await fixture.dataService.saveAgentSession(original, for: fixture.workspace)
        try await fixture.dataService.updateDelegationPlacement(
            id: fixture.sessionID, organizationalParentID: parent, delegationScopeID: scope,
            for: fixture.workspace
        )
        let restored = try await reopen(fixture)
        XCTAssertEqual(restored?.organizationalParentID, parent)
        XCTAssertEqual(restored?.delegationScopeID, scope)
        XCTAssertEqual(restored?.createdByOverseerSessionID, creator)
    }
}
