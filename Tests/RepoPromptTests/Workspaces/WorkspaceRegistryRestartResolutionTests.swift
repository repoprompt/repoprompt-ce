@testable import RepoPromptApp
@testable import RepoPromptDomainRuntime
import RepoPromptSecureStorage
import RepoPromptSettingsCore
import XCTest

#if DEBUG
    /// Regression coverage for #829: a workspace created through the domain authority after the
    /// legacy `workspacesIndex.json` froze must remain resolvable after an app restart.
    @MainActor
    final class WorkspaceRegistryRestartResolutionTests: XCTestCase {
        private var originalMCPAutoStart = false
        private var originalStoragePath: String?
        private var storageRoot: URL!
        private var repoRoot: URL!
        private var managers: [WorkspaceManagerViewModel] = []

        override func setUp() async throws {
            try await super.setUp()
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            originalStoragePath = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
            let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            storageRoot = temporaryRoot
                .appendingPathComponent("WorkspaceRegistryRestartResolutionTests-\(UUID().uuidString)", isDirectory: true)
            repoRoot = temporaryRoot
                .appendingPathComponent("WorkspaceRegistryRestartResolutionRepos-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
            UserDefaults.standard.set(storageRoot.path, forKey: "GlobalCustomStorageURL")
            await WorkspaceDiskWriterComposition.processWriter.removeAllForTesting()
        }

        override func tearDown() async throws {
            managers.forEach { $0.prepareForWindowClose() }
            managers.removeAll()
            await WorkspaceDiskWriterComposition.processWriter.removeAllForTesting()
            try? FileManager.default.removeItem(at: storageRoot)
            try? FileManager.default.removeItem(at: repoRoot)
            if let originalStoragePath {
                UserDefaults.standard.set(originalStoragePath, forKey: "GlobalCustomStorageURL")
            } else {
                UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
            }
            GlobalSettingsStore.shared.setMCPAutoStart(originalMCPAutoStart, commit: false)
            try await super.tearDown()
        }

        func testCatalogOnlyWorkspaceCreatedAfterLegacyIndexFreezeResolvesAfterRestart() async throws {
            // Pre-existing store: N workspaces registered only in the legacy index.
            let legacyWorkspaces = try (0 ..< 8).map { index in
                let root = try makeRepoDirectory("legacy-\(index)")
                return WorkspaceModel(
                    id: UUID(),
                    dateModified: Date(timeIntervalSince1970: TimeInterval(100 + index)),
                    name: "Legacy \(index)",
                    repoPaths: [root],
                    lastUsed: Date(timeIntervalSince1970: TimeInterval(100 + index))
                )
            }
            for workspace in legacyWorkspaces {
                try writeWorkspace(workspace)
            }
            try writeLegacyIndex(legacyWorkspaces)
            let legacyIDs = Set(legacyWorkspaces.map(\.id))

            let configuration = DomainRuntimeConfiguration(
                mode: .app,
                profileIdentifier: "workspace-registry-restart-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            )

            // First app run: the authority owns the registry, so a workspace created in-session
            // lands in the runtime catalog while the legacy index stays frozen.
            let extraRoot = try makeRepoDirectory("created-after-freeze")
            let firstRuntime = MCPDomainRuntime(configuration: configuration, runtimeID: UUID())
            try await firstRuntime.start()
            let firstClient = DomainWorkspaceAuthorityClient(store: firstRuntime.workspaceStore, windowID: -829)
            let firstManager = makeManager(windowID: -829, domainWorkspaceAuthorityClient: firstClient)
            await firstManager.awaitInitialized()
            let creation = try firstManager.createPersistentWorkspace(
                name: "Created After Freeze",
                repoPaths: [extraRoot]
            )
            let createOutcome = try await creation.join()
            XCTAssertTrue(
                createOutcome.disposition == .applied || createOutcome.disposition == .deduplicated,
                "Creation must commit through the authority."
            )
            let extraID = creation.workspaceID
            XCTAssertFalse(legacyIDs.contains(extraID))

            let firstSnapshot = await firstRuntime.workspaceStore.snapshot()
            XCTAssertTrue(firstSnapshot.workspaces.contains { $0.document.workspaceID == extraID })
            XCTAssertEqual(
                try Set(legacyIndexEntries().map(\.id)),
                legacyIDs,
                "Precondition: authority-owned managers never rewrite the legacy index."
            )
            XCTAssertTrue(
                try catalogFileContents().contains(extraID.uuidString),
                "Precondition: the durable runtime catalog records the post-freeze workspace."
            )

            firstManager.prepareForWindowClose()
            _ = await firstRuntime.shutdown()

            // Fresh launch against the same store.
            let restartedRuntime = MCPDomainRuntime(configuration: configuration, runtimeID: UUID())
            try await restartedRuntime.start()
            defer { Task { _ = await restartedRuntime.shutdown() } }
            let restartedClient = DomainWorkspaceAuthorityClient(
                store: restartedRuntime.workspaceStore,
                windowID: -830
            )
            let restartedManager = makeManager(windowID: -830, domainWorkspaceAuthorityClient: restartedClient)
            XCTAssertEqual(
                Set(restartedManager.workspaces.map(\.id)),
                legacyIDs,
                "Precondition: construction-time load still reads the frozen legacy index."
            )
            await restartedManager.awaitInitialized()

            let restartedSnapshot = await restartedRuntime.workspaceStore.snapshot()
            XCTAssertTrue(restartedSnapshot.isBootstrapped)
            XCTAssertEqual(
                Set(restartedSnapshot.workspaces.map(\.document.workspaceID)),
                legacyIDs.union([extraID])
            )

            // manage_workspaces list / switch inventory (WindowRoutingService.loadWorkspaceDiskSnapshot).
            let inventory = await restartedManager.loadWorkspaceSnapshotFromDisk()
            XCTAssertEqual(Set(inventory.map(\.id)), legacyIDs.union([extraID]))
            let listed = WindowRoutingService.workspaceInventoryModels(
                inventory,
                authorityIncompleteWorkspaceIDs: restartedManager.pendingConsolidatedRestoreIDs,
                includeHidden: false
            )
            XCTAssertTrue(listed.contains { $0.id == extraID && $0.name == "Created After Freeze" })

            // bind_context working_dirs exact-path matching over the same inventory.
            let exactMatches = WindowRoutingService.test_collapsedWorkingDirsWorkspaceMatches(
                workingDirs: [extraRoot],
                diskWorkspaces: listed,
                activeWindows: []
            )
            XCTAssertEqual(exactMatches.map(\.workspace.id), [extraID])

            // Authority exact-root folder-open resolution.
            let folderSelection = try await restartedManager.persistentFolderOpenSelection(forFolderPath: extraRoot)
            guard case let .matched(matchedWorkspace) = folderSelection else {
                return XCTFail("Expected an exact-root match for the post-freeze workspace, got \(folderSelection)")
            }
            XCTAssertEqual(matchedWorkspace.id, extraID)

            // Routing catalog used by deep links / window routing.
            let routingSnapshot = await restartedManager.workspaceRoutingCatalogSnapshot()
            let routingCatalog = try XCTUnwrap(routingSnapshot)
            XCTAssertTrue(routingCatalog.contains { $0.id == extraID })

            // The in-window presentation list adopts the authority projection.
            let bridge = DomainWorkspacePresentationBridge(
                workspaceManager: restartedManager,
                client: restartedClient
            )
            bridge.start()
            let projected = await bridge.waitUntilProjected(through: restartedSnapshot.publicationSequence)
            XCTAssertTrue(projected)
            XCTAssertEqual(Set(restartedManager.workspaces.map(\.id)), legacyIDs.union([extraID]))
            XCTAssertEqual(restartedManager.workspace(withID: extraID)?.repoPaths, [extraRoot])
            await bridge.stopAndJoinForTesting()
        }

        // MARK: - Helpers

        private func makeRepoDirectory(_ name: String) throws -> String {
            let url = repoRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }

        private func writeWorkspace(_ workspace: WorkspaceModel) throws {
            let fileURL = storageRoot
                .appendingPathComponent(
                    DomainWorkspaceStoragePath.directoryName(name: workspace.name, id: workspace.id),
                    isDirectory: true
                )
                .appendingPathComponent("workspace.json")
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(workspace).write(to: fileURL, options: .atomic)
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

        private func legacyIndexEntries() throws -> [WorkspaceIndexEntry] {
            try JSONDecoder().decode(
                [WorkspaceIndexEntry].self,
                from: Data(contentsOf: storageRoot.appendingPathComponent("workspacesIndex.json"))
            )
        }

        private func catalogFileContents() throws -> String {
            let runtimeVersionRoot = storageRoot
                .appendingPathComponent("runtime-state", isDirectory: true)
                .appendingPathComponent("DomainRuntime", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
            let profileDirectories = try FileManager.default.contentsOfDirectory(
                at: runtimeVersionRoot,
                includingPropertiesForKeys: nil
            )
            let catalogURL = try XCTUnwrap(
                profileDirectories
                    .map { $0.appendingPathComponent("workspace-catalog.json") }
                    .first { FileManager.default.fileExists(atPath: $0.path) }
            )
            return try String(contentsOf: catalogURL, encoding: .utf8)
        }

        private func makeManager(
            windowID: Int,
            domainWorkspaceAuthorityClient: DomainWorkspaceAuthorityClient
        ) -> WorkspaceManagerViewModel {
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
                domainWorkspaceAuthorityClient: domainWorkspaceAuthorityClient,
                workspaceActivityCoordinator: WorkspaceActivityCoordinator(),
                performInitialWorkspaceActivation: false
            )
            managers.append(manager)
            return manager
        }
    }
#endif
