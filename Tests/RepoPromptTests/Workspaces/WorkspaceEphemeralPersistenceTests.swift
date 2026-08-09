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
        let manager = makeManager()
        manager.globalCustomStorageURL = storageRoot
        manager.workspaces = []

        let workspace = manager.createEphemeralWorkspace(
            name: "Temporary Review",
            repoPaths: ["/tmp/temporary-review"]
        )
        manager.activeWorkspace = workspace

        await manager.pollAndSaveStateAsync(source: .pollAndSaveStateAsync)
        await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(
            url: manager.workspaceFileURL(for: workspace)
        )

        XCTAssertTrue(workspace.isEphemeral)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.path))
    }

    @MainActor
    func testEphemeralWorkspaceReadsAreEmptyAndWritesDoNotCreateSidecars() async throws {
        let storageRoot = temporaryStorageRoot()
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        var workspace = WorkspaceModel(
            name: "Temporary",
            repoPaths: [],
            customStoragePath: storageRoot
        )
        workspace.isEphemeral = true

        XCTAssertEqual(try await ChatDataService().listChatSessions(for: workspace), [])
        XCTAssertEqual(try await AgentSessionDataService.shared.listAgentSessions(for: workspace), [])
        XCTAssertNil(try await AgentSessionDataService.shared.loadAgentSession(id: UUID(), for: workspace))
        let manager = makeManager()
        await XCTAssertThrowsErrorAsync {
            try await manager.saveWorkspaceToFileAsync(workspace, baseRoot: storageRoot)
        }
        await XCTAssertThrowsErrorAsync {
            try await ChatDataService().saveChatSession(ChatSession(name: "Unsaved", messages: []), for: workspace)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.path))
    }

    @MainActor
    func testEphemeralWorkspaceUsesTemporaryGitArtifactRoot() {
        let storageRoot = temporaryStorageRoot()
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let manager = makeManager()
        var workspace = WorkspaceModel(
            name: "Temporary Git",
            repoPaths: [],
            customStoragePath: storageRoot
        )
        workspace.isEphemeral = true

        let artifactDirectory = manager.gitDataDirectory(for: workspace)

        XCTAssertTrue(artifactDirectory.path.contains("RepoPromptCE-EphemeralArtifacts"))
        XCTAssertFalse(artifactDirectory.path.hasPrefix(storageRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.path))
    }

    @MainActor
    func testConvertingWorkspaceToEphemeralBlocksAnInFlightLegacyWriter() async throws {
        let storageRoot = temporaryStorageRoot()
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let manager = makeManager()
        let workspace = WorkspaceModel(name: "In Flight", repoPaths: [], customStoragePath: storageRoot)
        manager.workspaces = [workspace]
        let gate = WorkspaceEphemeralPersistenceGate()
        let writer = WorkspaceManagerViewModel.WorkspaceDiskWriter.shared
        await writer.setAtomicWriteGateForTesting { await gate.arriveAndWait() }

        let fileURL = try await manager.saveWorkspaceToFileAsync(workspace, baseRoot: storageRoot)
        await gate.waitUntilArrived()
        await manager.setWorkspaceEphemeral(workspace.id, true)
        await gate.release()
        await writer.flush(url: fileURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    private func makeManager() -> WorkspaceManagerViewModel {
        let files = WorkspaceFilesViewModel(workspaceFileContextStore: WorkspaceFileContextStore())
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: files,
            apiSettingsViewModel: apiSettings,
            windowID: -485,
            settingsManager: WindowSettingsManager(windowID: -485)
        )
        return WorkspaceManagerViewModel(
            fileManager: files,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
    }

    private func temporaryStorageRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceEphemeralPersistenceTests-\(UUID().uuidString)", isDirectory: true)
    }

    @MainActor
    private func XCTAssertThrowsErrorAsync(
        _ expression: () async throws -> some Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected expression to throw", file: file, line: line)
        } catch {}
    }
}

private actor WorkspaceEphemeralPersistenceGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrived = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilArrived() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
