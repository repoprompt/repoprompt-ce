@testable import RepoPromptApp
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

        await XCTAssertThrowsErrorAsync {
            try await manager.saveWorkspaceToFileAsync(workspace, baseRoot: storageRoot)
        } errorHandler: { error in
            XCTAssertEqual(error as? WorkspacePersistenceError, .ephemeralWorkspace)
        }
        XCTAssertThrowsError(try manager.saveWorkspaceToFile(workspace)) { error in
            XCTAssertEqual(error as? WorkspacePersistenceError, .ephemeralWorkspace)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.path))
    }

    @MainActor
    func testEphemeralChatSaveFailsBeforeCreatingSidecars() async {
        let storageRoot = temporaryStorageRoot()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        var workspace = WorkspaceModel(
            name: "Temporary Chat",
            repoPaths: ["/tmp/temporary-chat"],
            customStoragePath: storageRoot
        )
        workspace.isEphemeral = true
        let session = ChatSession(name: "Unsaved", messages: [])

        let existingSessions = try? await ChatDataService().listChatSessions(for: workspace)
        XCTAssertEqual(existingSessions, [])
        await XCTAssertThrowsErrorAsync {
            try await ChatDataService().saveChatSession(session, for: workspace)
        } errorHandler: { error in
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

        let sessions = try await AgentSessionDataService.shared.listAgentSessions(for: workspace)
        XCTAssertEqual(sessions, [])
        let loaded = try await AgentSessionDataService.shared.loadAgentSession(id: UUID(), for: workspace)
        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.path))
    }

    @MainActor
    func testEphemeralGitDataLoadFailsBeforeCreatingSidecars() async {
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

        await XCTAssertThrowsErrorAsync {
            try await fixture.files.ensureGitDataRootLoaded(
                workspace: workspace,
                workspaceManager: fixture.manager
            )
        } errorHandler: { error in
            XCTAssertEqual(error as? WorkspacePersistenceError, .ephemeralWorkspace)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.path))
    }

    @MainActor
    func testEphemeralWorkspaceCannotAuthorizeAttachmentStorage() throws {
        let storageRoot = temporaryStorageRoot()
        let manager = makeFixture().manager
        var workspace = WorkspaceModel(name: "Temporary Attachment", repoPaths: [])
        workspace.isEphemeral = true

        XCTAssertThrowsError(
            try manager.persistentStorage(for: workspace, baseRoot: storageRoot)
        ) { error in
            XCTAssertEqual(error as? WorkspacePersistenceError, .ephemeralWorkspace)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.path))
    }

    @MainActor
    func testExistingPersistentWorkspaceKeepsEphemeralDispositionAcrossDiskHydration() async throws {
        let storageRoot = temporaryStorageRoot()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let manager = makeFixture().manager
        let source = WorkspaceModel(
            name: "Source",
            repoPaths: [],
            isSystemWorkspace: true
        )
        let target = WorkspaceModel(
            name: "Persisted Target",
            repoPaths: [],
            customStoragePath: storageRoot
        )
        _ = try manager.saveWorkspaceToFile(target)
        manager.workspaces = [source, target]
        manager.activeWorkspace = source

        await manager.setWorkspaceEphemeral(target.id, true)
        let result = await manager.requestWorkspaceSwitch(
            to: target,
            saveState: false,
            reason: "ephemeralPersistenceTest"
        )

        XCTAssertTrue(result.didSwitch)
        XCTAssertEqual(manager.activeWorkspace?.id, target.id)
        XCTAssertTrue(manager.activeWorkspace?.isEphemeral == true)
        XCTAssertTrue(manager.workspaces.first(where: { $0.id == target.id })?.isEphemeral == true)
    }

    @MainActor
    func testConvertingWorkspaceToEphemeralBlocksInFlightWriter() async throws {
        let storageRoot = temporaryStorageRoot()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let fixture = makeFixture()
        let manager = fixture.manager
        let workspace = WorkspaceModel(
            name: "In Flight",
            repoPaths: [],
            customStoragePath: storageRoot
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace

        let gate = WorkspaceEphemeralPersistenceGate()
        let writer = WorkspaceManagerViewModel.WorkspaceDiskWriter.shared
        await writer.setAtomicWriteGateForTesting {
            await gate.arriveAndWait()
        }

        let finalURL = try await manager.saveWorkspaceToFileAsync(
            workspace,
            baseRoot: storageRoot
        )
        await gate.waitUntilArrived()
        await manager.setWorkspaceEphemeral(workspace.id, true)
        await gate.release()
        await writer.flush(url: finalURL)
        await writer.setAtomicWriteGateForTesting(nil)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: finalURL.path),
            "A writer already admitted before conversion must be cancelled at the final write boundary"
        )
        XCTAssertThrowsError(try manager.saveWorkspaceToFile(workspace)) { error in
            XCTAssertEqual(error as? WorkspacePersistenceError, .ephemeralWorkspace)
        }
    }

    @MainActor
    func testPersistentAttachmentStorageUsesAuthorizedWorkspaceDirectory() throws {
        let storageRoot = temporaryStorageRoot()
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        let workspaceDirectory = storageRoot.appendingPathComponent("workspace", isDirectory: true)
        let sourceURL = storageRoot.appendingPathComponent("source.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: sourceURL)

        let manager = makeFixture().manager
        let workspace = WorkspaceModel(
            name: "Attachment Workspace",
            repoPaths: [],
            customStoragePath: workspaceDirectory
        )
        let storage = try manager.persistentStorage(for: workspace)
        let result = try AgentAttachmentStore().importImageFile(
            sourceURL: sourceURL,
            storage: storage
        )

        XCTAssertEqual(
            result.fileURL.deletingLastPathComponent(),
            workspaceDirectory.appendingPathComponent("agent_attachments", isDirectory: true)
                .standardizedFileURL
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.fileURL.path))
    }

    @MainActor
    func testEphemeralPromptGitPublicationFailsAtStorageAuthorization() async {
        let fixture = makeFixture()
        var workspace = WorkspaceModel(name: "Prompt Temporary", repoPaths: [])
        workspace.isEphemeral = true
        fixture.manager.workspaces = [workspace]
        fixture.manager.activeWorkspace = workspace

        await XCTAssertThrowsErrorAsync {
            try await fixture.prompt.publishGitDiffArtifacts(inclusionMode: .all)
        } errorHandler: { error in
            XCTAssertEqual(error as? WorkspacePersistenceError, .ephemeralWorkspace)
        }
    }

    @MainActor
    func testEphemeralMCPGitPublicationCannotResolveArtifactDirectory() throws {
        let fixture = makeFixture()
        var workspace = WorkspaceModel(name: "MCP Temporary", repoPaths: [])
        workspace.isEphemeral = true

        XCTAssertThrowsError(
            try MCPGitToolProvider.test_persistentArtifactDirectory(
                workspaceManager: fixture.manager,
                workspace: workspace
            )
        ) { error in
            XCTAssertEqual(error as? WorkspacePersistenceError, .ephemeralWorkspace)
        }
    }

    @MainActor
    func testWorktreeArtifactPublicationUsesAuthorizedWorkspaceDirectory() throws {
        let storageRoot = temporaryStorageRoot()
        let fixture = makeFixture()
        let workspace = WorkspaceModel(
            name: "Worktree Persistent",
            repoPaths: [],
            customStoragePath: storageRoot
        )
        fixture.manager.workspaces = [workspace]
        fixture.manager.activeWorkspace = workspace

        XCTAssertEqual(
            try AgentModeViewModel.test_worktreePreviewDirectory(
                publishArtifacts: true,
                workspaceManager: fixture.manager
            ),
            storageRoot.standardizedFileURL
        )

        var ephemeral = workspace
        ephemeral.isEphemeral = true
        fixture.manager.workspaces = [ephemeral]
        fixture.manager.activeWorkspace = ephemeral
        XCTAssertThrowsError(
            try AgentModeViewModel.test_worktreePreviewDirectory(
                publishArtifacts: true,
                workspaceManager: fixture.manager
            )
        ) { error in
            XCTAssertEqual(error as? WorkspacePersistenceError, .ephemeralWorkspace)
        }
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
        files: WorkspaceFilesViewModel,
        prompt: PromptViewModel
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
        return (manager, files, prompt)
    }

    private func temporaryStorageRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceEphemeralPersistenceTests-\(UUID().uuidString)", isDirectory: true)
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> some Any,
    errorHandler: (Error) -> Void = { _ in },
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

private actor WorkspaceEphemeralPersistenceGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilArrived() async {
        guard !arrived else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
