@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class WorkspaceEphemeralPersistenceTests: XCTestCase {
        private var originalMCPAutoStart = false
        private var originalStoragePath: String?
        private var storageRoot: URL!
        private var managers: [WorkspaceManagerViewModel] = []

        override func setUp() async throws {
            try await super.setUp()
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            originalStoragePath = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorkspaceEphemeralPersistenceTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            UserDefaults.standard.set(storageRoot.path, forKey: "GlobalCustomStorageURL")
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
        }

        override func tearDown() async throws {
            managers.forEach { $0.prepareForWindowClose() }
            managers.removeAll()
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
            try? FileManager.default.removeItem(at: storageRoot)
            if let originalStoragePath {
                UserDefaults.standard.set(originalStoragePath, forKey: "GlobalCustomStorageURL")
            } else {
                UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
            }
            GlobalSettingsStore.shared.setMCPAutoStart(originalMCPAutoStart, commit: false)
            try await super.tearDown()
        }

        func testDirtyEphemeralWorkspaceSkipsEverySaveSideEffect() async {
            let manager = makeManager(windowID: -761)
            await manager.awaitInitialized()
            let workspace = manager.createEphemeralWorkspace(name: "Temporary", repoPaths: [])
            XCTAssertTrue(workspace.isEphemeral)
            XCTAssertTrue(manager.workspace(withID: workspace.id)?.isEphemeral == true)

            let switched = await manager.switchWorkspace(to: workspace, saveState: false)
            XCTAssertTrue(switched.didSwitch)
            manager.markWorkspaceDirty()

            let outcome = await manager.pollAndSaveStateWithOutcomeAsync(workspaceID: workspace.id)
            XCTAssertEqual(outcome, .notRequired(workspaceID: workspace.id))

            let workspaceFile = manager.workspaceFileURL(for: workspace)
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceFile.path))
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: storageRoot.appendingPathComponent("workspacesIndex.json").path
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: workspaceFile.deletingLastPathComponent().path),
                "Skipping persistence must not create an empty workspace directory."
            )
        }

        func testIndexedPersistedEphemeralWorkspaceIsExcludedWithoutDeletingLegacyFiles() async throws {
            let workspace = WorkspaceModel(
                name: "Legacy Temporary",
                repoPaths: ["/tmp/legacy-ephemeral"],
                ephemeralFlag: true
            )
            let directory = storageRoot.appendingPathComponent(
                DomainWorkspaceStoragePath.directoryName(name: workspace.name, id: workspace.id),
                isDirectory: true
            )
            let workspaceFile = directory.appendingPathComponent("workspace.json")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(workspace).write(to: workspaceFile, options: .atomic)
            let indexURL = storageRoot.appendingPathComponent("workspacesIndex.json")
            try JSONEncoder().encode([
                WorkspaceIndexEntry(
                    id: workspace.id,
                    name: workspace.name,
                    customStoragePath: nil,
                    isSystemWorkspace: false,
                    isHiddenInMenus: false
                )
            ]).write(to: indexURL, options: .atomic)

            let manager = makeManager(windowID: -762)
            await manager.awaitInitialized()

            XCTAssertFalse(manager.workspaces.contains { $0.id == workspace.id })
            let legacySnapshot = await manager.loadWorkspaceSnapshotFromDisk()
            XCTAssertFalse(legacySnapshot.contains { $0.id == workspace.id })
            XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceFile.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))
        }

        func testRuntimeCatalogCleanupFindsLegacyInventoryOmissionsAndAppliesIdempotently() async throws {
            let normal = WorkspaceModel(name: "User Workspace", repoPaths: ["/Users/example/project"])
            let removableLeak = leakedFixtureWorkspace()
            let protectedLeak = leakedFixtureWorkspace()
            let unrelatedEphemeral = WorkspaceModel(
                name: "Temporary User Session",
                repoPaths: ["/tmp/user-session"],
                ephemeralFlag: true
            )
            let allWorkspaces = [normal, removableLeak, protectedLeak, unrelatedEphemeral]
            for workspace in allWorkspaces {
                try writeWorkspace(workspace)
            }
            try writeLegacyIndex(allWorkspaces)

            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "workspace-leak-cleanup-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            defer { Task { _ = await runtime.shutdown() } }
            let authoritativeBefore = await runtime.workspaceStore.snapshot()
            XCTAssertEqual(
                Set(authoritativeBefore.workspaces.map(\.document.workspaceID)),
                Set(allWorkspaces.map(\.id))
            )

            // Reproduce the production split: the runtime catalog retains the fixtures while the
            // legacy inventory consulted by manage_workspaces lists only the ordinary workspace.
            try writeLegacyIndex([normal])
            let composition = WindowStateCompositionFactory.make(
                windowID: -763,
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService(),
                domainRuntime: runtime,
                workspaceFileContextStore: WorkspaceFileContextStore()
            )
            let manager = composition.workspaceManager
            managers.append(manager)
            await manager.awaitInitialized()
            let bridge = try XCTUnwrap(composition.domainWorkspacePresentationBridge)
            let projected = await bridge.waitUntilProjected(through: authoritativeBefore.publicationSequence)
            XCTAssertTrue(projected)

            let legacyInventory = await manager.loadWorkspaceSnapshotFromDisk()
            XCTAssertEqual(legacyInventory.map(\.id), [normal.id])
            XCTAssertFalse(manager.workspaces.contains { $0.id == removableLeak.id })
            XCTAssertTrue(manager.workspaces.contains { $0.id == normal.id })

            let protectedIDs: Set<UUID> = [normal.id, protectedLeak.id]
            let preview = await manager.previewLeakedTestWorkspaces(protectedWorkspaceIDs: protectedIDs)
            XCTAssertEqual(Set(preview.records.map(\.id)), [removableLeak.id, protectedLeak.id])
            XCTAssertTrue(preview.records.first(where: { $0.id == removableLeak.id })?.isDeletable == true)
            XCTAssertEqual(
                preview.records.first(where: { $0.id == protectedLeak.id })?.deletionBlockReason,
                "Workspace is active in an open window."
            )
            XCTAssertFalse(preview.records.contains { $0.id == unrelatedEphemeral.id })

            let firstApply = await manager.deleteWorkspacesAsync(
                workspaceIDs: [removableLeak.id, protectedLeak.id, normal.id],
                protectedWorkspaceIDs: protectedIDs,
                leakedTestFixtureWorkspaceIDs: [removableLeak.id, protectedLeak.id]
            )
            XCTAssertEqual(firstApply.deletedWorkspaceIDs, [removableLeak.id])
            XCTAssertEqual(Set(firstApply.skippedReasonsByWorkspaceID.keys), protectedIDs)
            XCTAssertTrue(firstApply.failedReasonsByWorkspaceID.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceFileURL(for: removableLeak).path))

            let authoritativeAfter = await runtime.workspaceStore.snapshot()
            let survivingIDs = Set(authoritativeAfter.workspaces.map(\.document.workspaceID))
            XCTAssertFalse(survivingIDs.contains(removableLeak.id))
            XCTAssertTrue(survivingIDs.isSuperset(of: [normal.id, protectedLeak.id, unrelatedEphemeral.id]))

            let repeatedApply = await manager.deleteWorkspacesAsync(
                workspaceIDs: [removableLeak.id],
                protectedWorkspaceIDs: protectedIDs,
                leakedTestFixtureWorkspaceIDs: [removableLeak.id]
            )
            XCTAssertEqual(repeatedApply.alreadyAbsentWorkspaceIDs, [removableLeak.id])
            XCTAssertTrue(repeatedApply.deletedWorkspaceIDs.isEmpty)
            XCTAssertTrue(repeatedApply.failedReasonsByWorkspaceID.isEmpty)
        }

        private func leakedFixtureWorkspace() -> WorkspaceModel {
            let suffix = UUID()
            return WorkspaceModel(
                name: "Agent Mode Chat Switch \(suffix.uuidString)",
                repoPaths: [
                    "/private/var/folders/fixture/AgentModeChatSwitchActivationTests-\(UUID().uuidString)/repo"
                ],
                ephemeralFlag: true
            )
        }

        private func writeWorkspace(_ workspace: WorkspaceModel) throws {
            let fileURL = workspaceFileURL(for: workspace)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(workspace).write(to: fileURL, options: .atomic)
        }

        private func workspaceFileURL(for workspace: WorkspaceModel) -> URL {
            storageRoot
                .appendingPathComponent(
                    DomainWorkspaceStoragePath.directoryName(name: workspace.name, id: workspace.id),
                    isDirectory: true
                )
                .appendingPathComponent("workspace.json")
        }

        private func writeLegacyIndex(_ workspaces: [WorkspaceModel]) throws {
            let entries = workspaces.map {
                WorkspaceIndexEntry(
                    id: $0.id,
                    name: $0.name,
                    customStoragePath: $0.customStoragePath,
                    isSystemWorkspace: $0.isSystemWorkspace,
                    isHiddenInMenus: $0.isHiddenInMenus
                )
            }
            try JSONEncoder().encode(entries).write(
                to: storageRoot.appendingPathComponent("workspacesIndex.json"),
                options: .atomic
            )
        }

        private func makeManager(windowID: Int) -> WorkspaceManagerViewModel {
            let keyManager = KeyManager(
                secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
            )
            let aiQueriesService = AIQueriesService(keyManager: keyManager)
            let fileManager = WorkspaceFilesViewModel()
            let apiSettings = APISettingsViewModel(
                aiQueriesService: aiQueriesService,
                keyManager: keyManager,
                loadStoredDataOnInit: false
            )
            let prompt = PromptViewModel(
                fileManager: fileManager,
                apiSettingsViewModel: apiSettings,
                windowID: windowID,
                settingsManager: WindowSettingsManager(windowID: windowID)
            )
            let manager = WorkspaceManagerViewModel(
                fileManager: fileManager,
                promptViewModel: prompt,
                performInitialWorkspaceActivation: false
            )
            managers.append(manager)
            return manager
        }
    }
#endif
