@testable import RepoPrompt
import XCTest

final class WorkspaceEphemeralPersistenceTests: XCTestCase {
    override func tearDown() async throws {
        await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
        try await super.tearDown()
    }

    @MainActor
    func testEphemeralFactoryAndAutosaveNeverCreateWorkspaceStorage() async throws {
        let storageRoot = temporaryStorageRoot()
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        let defaults = UserDefaults.standard
        let previousStoragePath = defaults.string(forKey: "GlobalCustomStorageURL")
        defer {
            if let previousStoragePath {
                defaults.set(previousStoragePath, forKey: "GlobalCustomStorageURL")
            } else {
                defaults.removeObject(forKey: "GlobalCustomStorageURL")
            }
        }

        let manager = makeFixture().manager
        manager.globalCustomStorageURL = storageRoot
        manager.workspaces = []

        let workspace = manager.createEphemeralWorkspace(
            name: "Temporary Review",
            repoPaths: ["/tmp/temporary-review"]
        )
        manager.activeWorkspace = workspace

        await manager.pollAndSaveStateAsync(source: .pollAndSaveStateAsync)
        let workspaceURL = manager.workspaceFileURL(for: workspace)
        await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: workspaceURL)

        XCTAssertTrue(workspace.isEphemeral)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: manager.workspaceDirectory(for: workspace).path),
            "Ephemeral factory/autosave must not create a workspace directory"
        )
    }

    @MainActor
    func testDirectEphemeralSavesFailBeforeAnyFilesystemMutation() async throws {
        let storageRoot = temporaryStorageRoot()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let manager = makeFixture().manager
        var workspace = WorkspaceModel(
            name: "Direct Temporary",
            repoPaths: ["/tmp/direct-temporary"],
            customStoragePath: storageRoot.appendingPathComponent("workspace", isDirectory: true)
        )
        workspace.isEphemeral = true

        await XCTAssertThrowsErrorAsync(
            try manager.saveWorkspaceToFileAsync(workspace, baseRoot: storageRoot)
        ) { error in
            XCTAssertEqual(error as? WorkspacePersistenceError, .ephemeralWorkspace)
        }
        XCTAssertThrowsError(try manager.saveWorkspaceToFile(workspace)) { error in
            XCTAssertEqual(error as? WorkspacePersistenceError, .ephemeralWorkspace)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.path))
    }

    @MainActor
    func testEphemeralChatSaveFailsBeforeCreatingSidecars() async throws {
        let storageRoot = temporaryStorageRoot()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        var workspace = WorkspaceModel(
            name: "Temporary Chat",
            repoPaths: ["/tmp/temporary-chat"],
            customStoragePath: storageRoot
        )
        workspace.isEphemeral = true
        let session = ChatSession(name: "Unsaved", messages: [])

        await XCTAssertThrowsErrorAsync(
            try ChatDataService().saveChatSession(session, for: workspace)
        ) { error in
            XCTAssertEqual(error as? WorkspacePersistenceError, .ephemeralWorkspace)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.path))
    }

    @MainActor
    func testEphemeralAgentSessionLookupFailsBeforeCreatingSidecars() async throws {
        let storageRoot = temporaryStorageRoot()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        var workspace = WorkspaceModel(
            name: "Temporary Agent",
            repoPaths: ["/tmp/temporary-agent"],
            customStoragePath: storageRoot
        )
        workspace.isEphemeral = true

        await XCTAssertThrowsErrorAsync(
            try AgentSessionDataService.shared.listAgentSessions(for: workspace)
        ) { error in
            XCTAssertEqual(error as? WorkspacePersistenceError, .ephemeralWorkspace)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.path))
    }

    @MainActor
    func testEphemeralGitDataLoadFailsBeforeCreatingSidecars() async throws {
        let storageRoot = temporaryStorageRoot()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let fixture = makeFixture()
        var workspace = WorkspaceModel(
            name: "Temporary Git",
            repoPaths: ["/tmp/temporary-git"],
            customStoragePath: storageRoot
        )
        workspace.isEphemeral = true
        fixture.manager.workspaces = [workspace]
        fixture.manager.activeWorkspace = workspace

        await XCTAssertThrowsErrorAsync(
            try fixture.files.ensureGitDataRootLoaded(
                workspace: workspace,
                workspaceManager: fixture.manager
            )
        ) { error in
            XCTAssertEqual(error as? WorkspacePersistenceError, .ephemeralWorkspace)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.path))
    }

    func testEphemeralWorkspaceCannotAuthorizeAttachmentStorage() throws {
        let storageRoot = temporaryStorageRoot()
        var workspace = WorkspaceModel(name: "Temporary Attachment", repoPaths: [])
        workspace.isEphemeral = true

        XCTAssertThrowsError(
            try WorkspacePersistentStorage(workspace: workspace, workspaceDirectory: storageRoot)
        ) { error in
            XCTAssertEqual(error as? WorkspacePersistenceError, .ephemeralWorkspace)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.path))
    }

    @MainActor
    func testPersistentWorkspaceStillWritesAndReloads() throws {
        let storageRoot = temporaryStorageRoot()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let manager = makeFixture().manager
        let workspace = WorkspaceModel(
            name: "Persistent",
            repoPaths: ["/tmp/persistent"],
            customStoragePath: storageRoot
        )

        let fileURL = try manager.saveWorkspaceToFile(workspace)
        let reloaded = try WorkspaceManagerViewModel.loadWorkspaceFromFile(at: fileURL)

        XCTAssertEqual(reloaded.id, workspace.id)
        XCTAssertEqual(reloaded.repoPaths, workspace.repoPaths)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    private func makeFixture() -> (
        manager: WorkspaceManagerViewModel,
        files: WorkspaceFilesViewModel
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
            windowID: -468,
            settingsManager: WindowSettingsManager(windowID: -468)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: files,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        return (manager, files)
    }

    private func temporaryStorageRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceEphemeralPersistenceTests-\(UUID().uuidString)", isDirectory: true)
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
