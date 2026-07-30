@testable import RepoPromptApp
import XCTest

final class WorkspaceGitDataRootLoadingTests: XCTestCase {
    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    @MainActor
    func testReturnsAndReusesExactWorkspaceGitDataRoot() async throws {
        let storage = try temporaryRoots.makeRoot(suiteName: "GitDataRootLoading")
        let workspace = WorkspaceModel(
            name: "GitDataRootLoading",
            repoPaths: [],
            customStoragePath: storage
        )
        let fixture = makeFixture(workspace: workspace)

        let first = try await fixture.files.ensureGitDataRootLoaded(
            workspace: workspace,
            workspaceManager: fixture.manager
        )
        let second = try await fixture.files.ensureGitDataRootLoaded(
            workspace: workspace,
            workspaceManager: fixture.manager
        )
        let expectedPath = storage.appendingPathComponent("_git_data", isDirectory: true).path
        let exact = await fixture.store.exactRootRef(
            path: expectedPath,
            kind: .workspaceGitData
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first, exact)
        XCTAssertEqual(first.standardizedFullPath, expectedPath)
        await fixture.files.unloadAllRootFolders()
    }

    @MainActor
    func testSystemWorkspaceAndWrongLoadedKindFailExplicitly() async throws {
        let systemStorage = try temporaryRoots.makeRoot(suiteName: "GitDataRootSystemWorkspace")
        let systemWorkspace = WorkspaceModel(
            name: "System",
            repoPaths: [],
            isSystemWorkspace: true,
            customStoragePath: systemStorage
        )
        let systemFixture = makeFixture(workspace: systemWorkspace)

        do {
            _ = try await systemFixture.files.ensureGitDataRootLoaded(
                workspace: systemWorkspace,
                workspaceManager: systemFixture.manager
            )
            XCTFail("Expected system workspace Git-data loading to fail")
        } catch let error as WorkspaceFilesViewModel.GitDataRootLoadError {
            XCTAssertEqual(error, .systemWorkspace(workspaceID: systemWorkspace.id))
        }

        let wrongKindStorage = try temporaryRoots.makeRoot(suiteName: "GitDataRootWrongKind")
        let wrongKindWorkspace = WorkspaceModel(
            name: "WrongKind",
            repoPaths: [],
            customStoragePath: wrongKindStorage
        )
        let wrongKindFixture = makeFixture(workspace: wrongKindWorkspace)
        let gitDataRoot = wrongKindStorage.appendingPathComponent("_git_data", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDataRoot, withIntermediateDirectories: true)
        let wrongKindRoot = try await wrongKindFixture.store.loadRoot(
            path: gitDataRoot.path,
            kind: .primaryWorkspace
        )

        do {
            _ = try await wrongKindFixture.files.ensureGitDataRootLoaded(
                workspace: wrongKindWorkspace,
                workspaceManager: wrongKindFixture.manager
            )
            XCTFail("Expected a root loaded with the wrong kind to fail")
        } catch {
            let exactGitDataRoot = await wrongKindFixture.store.exactRootRef(
                path: gitDataRoot.path,
                kind: .workspaceGitData
            )
            XCTAssertNil(exactGitDataRoot)
        }
        await wrongKindFixture.store.unloadRoot(id: wrongKindRoot.id)
    }

    @MainActor
    private func makeFixture(
        workspace: WorkspaceModel
    ) -> (
        store: WorkspaceFileContextStore,
        files: WorkspaceFilesViewModel,
        manager: WorkspaceManagerViewModel
    ) {
        let store = WorkspaceFileContextStore()
        let files = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: files,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: files,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        manager.workspaces = [workspace]
        return (store, files, manager)
    }
}
