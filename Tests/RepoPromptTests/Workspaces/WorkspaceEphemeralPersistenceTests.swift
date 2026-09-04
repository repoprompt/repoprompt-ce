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

        func testExplicitSaveAPIsRejectEphemeralWorkspaceWithoutSideEffects() async throws {
            let manager = makeManager(windowID: -772)
            await manager.awaitInitialized()
            let workspace = manager.createEphemeralWorkspace(
                name: "Explicit Save Rejection",
                repoPaths: []
            )
            let workspaceFile = manager.workspaceFileURL(for: workspace)
            let alternateRoot = storageRoot.appendingPathComponent(
                "ExplicitSaveAlternateRoot",
                isDirectory: true
            )

            do {
                _ = try await manager.saveWorkspaceToFileAsync(workspace)
                XCTFail("Explicit async save must reject an ephemeral workspace")
            } catch {
                XCTAssertEqual(error.localizedDescription, "Ephemeral workspaces cannot be persisted.")
            }
            do {
                _ = try await manager.saveWorkspaceToFileAsync(
                    workspace,
                    baseRoot: alternateRoot
                )
                XCTFail("Explicit base-root save must reject an ephemeral workspace")
            } catch {
                XCTAssertEqual(error.localizedDescription, "Ephemeral workspaces cannot be persisted.")
            }
            XCTAssertThrowsError(try manager.saveWorkspaceToFile(workspace)) { error in
                XCTAssertEqual(error.localizedDescription, "Ephemeral workspaces cannot be persisted.")
            }

            XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceFile.path))
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: workspaceFile.deletingLastPathComponent().path)
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: alternateRoot.path))
        }

        func testBulkAndSingleDeleteRemoveLocalEphemeralWorkspacesMissingFromRuntimeCatalog() async throws {
            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "local-ephemeral-bulk-delete-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            defer { Task { _ = await runtime.shutdown() } }

            let manager = makeManager(
                windowID: -773,
                domainWorkspaceAuthorityClient: DomainWorkspaceAuthorityClient(
                    store: runtime.workspaceStore,
                    windowID: -773
                )
            )
            await manager.awaitInitialized()
            let bulkWorkspace = manager.createEphemeralWorkspace(
                name: "Bulk Temporary Workspace",
                repoPaths: []
            )
            let singleWorkspace = manager.createEphemeralWorkspace(
                name: "Single Temporary Workspace",
                repoPaths: []
            )

            func materializeLocalArtifacts(for workspace: WorkspaceModel) throws -> URL {
                let directory = manager.workspaceFileURL(for: workspace).deletingLastPathComponent()
                let gitData = directory.appendingPathComponent("_git_data", isDirectory: true)
                try FileManager.default.createDirectory(at: gitData, withIntermediateDirectories: true)
                try Data("artifact".utf8).write(to: gitData.appendingPathComponent("marker"))
                return directory
            }

            let bulkDirectory = try materializeLocalArtifacts(for: bulkWorkspace)
            let singleDirectory = try materializeLocalArtifacts(for: singleWorkspace)
            let before = await runtime.workspaceStore.snapshot()
            XCTAssertFalse(before.workspaces.contains {
                $0.document.workspaceID == bulkWorkspace.id
                    || $0.document.workspaceID == singleWorkspace.id
            })

            let result = await manager.deleteWorkspacesAsync(workspaceIDs: [bulkWorkspace.id])

            XCTAssertEqual(result.deletedWorkspaceIDs, [bulkWorkspace.id])
            XCTAssertTrue(result.alreadyAbsentWorkspaceIDs.isEmpty)
            XCTAssertTrue(result.skippedReasonsByWorkspaceID.isEmpty)
            XCTAssertTrue(result.failedReasonsByWorkspaceID.isEmpty)
            XCTAssertNil(manager.workspace(withID: bulkWorkspace.id))
            XCTAssertNotNil(manager.workspace(withID: singleWorkspace.id))
            XCTAssertFalse(FileManager.default.fileExists(atPath: bulkDirectory.path))

            let singleDeleted = await manager.deleteWorkspaceAsync(singleWorkspace)
            XCTAssertTrue(singleDeleted)
            XCTAssertNil(manager.workspace(withID: singleWorkspace.id))
            XCTAssertFalse(FileManager.default.fileExists(atPath: singleDirectory.path))

            let after = await runtime.workspaceStore.snapshot()
            XCTAssertFalse(after.workspaces.contains {
                $0.document.workspaceID == bulkWorkspace.id
                    || $0.document.workspaceID == singleWorkspace.id
            })
        }

        func testAuthorityProjectionPreservesActiveLocalEphemeralWorkspace() async {
            let manager = makeManager(windowID: -771)
            await manager.awaitInitialized()
            let persistedProjection = manager.workspaces.filter { !$0.isEphemeral }
            let ephemeral = manager.createEphemeralWorkspace(
                name: "Temporary Projection",
                repoPaths: []
            )
            let switchResult = await manager.switchWorkspace(to: ephemeral, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)

            manager.applyDomainWorkspaceProjection(
                persistedProjection,
                fileURLsByWorkspaceID: [:],
                revisionsByWorkspaceID: [:],
                digestsByWorkspaceID: [:],
                healthByWorkspaceID: [:],
                catalogRevision: 1,
                preferredActiveWorkspaceID: ephemeral.id,
                publicationSequence: 1
            )

            XCTAssertEqual(manager.activeWorkspaceID, ephemeral.id)
            XCTAssertEqual(manager.workspace(withID: ephemeral.id)?.name, ephemeral.name)
            XCTAssertTrue(manager.workspace(withID: ephemeral.id)?.isEphemeral == true)
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

        func testSingleDeleteRejectsCanonicalPinnedAgentClaim() async throws {
            let pinnedWorkspace = WorkspaceModel(
                name: "Pinned Agent Workspace",
                repoPaths: [storageRoot.appendingPathComponent("pinned-repo").path],
                stashedTabs: [
                    StashedTab(tab: ComposeTabState(name: "Pinned", isPinned: true))
                ]
            )
            try writeWorkspace(pinnedWorkspace)
            try writeLegacyIndex([pinnedWorkspace])

            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "workspace-single-delete-protection-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            defer { Task { _ = await runtime.shutdown() } }

            let manager = makeManager(
                windowID: -767,
                domainWorkspaceAuthorityClient: DomainWorkspaceAuthorityClient(
                    store: runtime.workspaceStore,
                    windowID: -767
                )
            )
            await manager.awaitInitialized()

            let didDelete = await manager.deleteWorkspaceAsync(pinnedWorkspace)
            XCTAssertFalse(didDelete)
            let authoritativeAfter = await runtime.workspaceStore.snapshot()
            XCTAssertTrue(authoritativeAfter.workspaces.contains {
                $0.document.workspaceID == pinnedWorkspace.id
            })
        }

        func testActivationLeaseBlocksDeletionClaimUntilSwitchCompletes() async throws {
            let workspace = leakedFixtureWorkspace()
            try writeWorkspace(workspace)
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: workspace.repoPaths[0]),
                withIntermediateDirectories: true
            )
            try writeLegacyIndex([workspace])

            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "workspace-activation-lease-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            defer { Task { _ = await runtime.shutdown() } }

            let coordinator = WorkspaceActivityCoordinator()
            let activationManager = makeManager(
                windowID: -768,
                workspaceActivityCoordinator: coordinator
            )
            let deletionManager = makeManager(
                windowID: -769,
                domainWorkspaceAuthorityClient: DomainWorkspaceAuthorityClient(
                    store: runtime.workspaceStore,
                    windowID: -769
                ),
                workspaceActivityCoordinator: coordinator
            )
            await activationManager.awaitInitialized()
            await deletionManager.awaitInitialized()

            let activationLeaseAcquired = expectation(description: "activation lease acquired")
            let gate = WorkspaceDeleteSuspensionGate()
            var didSuspend = false
            activationManager.setWorkspaceActivationLeaseDidAcquireHandlerForTesting { workspaceID in
                guard workspaceID == workspace.id, !didSuspend else { return }
                didSuspend = true
                activationLeaseAcquired.fulfill()
                await gate.wait()
            }

            let activationTask = Task {
                await activationManager.switchWorkspace(to: workspace, saveState: false)
            }
            await fulfillment(of: [activationLeaseAcquired], timeout: 2)

            let deletion = await deletionManager.deleteWorkspacesAsync(
                workspaceIDs: [workspace.id],
                leakedTestFixtureWorkspaceIDs: [workspace.id]
            )
            XCTAssertEqual(
                deletion.skippedReasonsByWorkspaceID[workspace.id],
                "Workspace is being activated in another window."
            )
            XCTAssertTrue(deletion.deletedWorkspaceIDs.isEmpty)
            let authoritativeDuringActivation = await runtime.workspaceStore.snapshot()
            XCTAssertTrue(authoritativeDuringActivation.workspaces.contains {
                $0.document.workspaceID == workspace.id
            })

            await gate.open()
            let activation = await activationTask.value
            activationManager.setWorkspaceActivationLeaseDidAcquireHandlerForTesting(nil)
            XCTAssertTrue(activation.didSwitch)
        }

        func testDeletionLeaseRejectsActivationOfLaterBatchWorkspaceWhileFirstDeleteIsSuspended() async throws {
            let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
            let laterID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
            let first = leakedFixtureWorkspace(id: firstID)
            let later = leakedFixtureWorkspace(id: laterID)
            for workspace in [first, later] {
                try writeWorkspace(workspace)
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: workspace.repoPaths[0]),
                    withIntermediateDirectories: true
                )
            }
            try writeLegacyIndex([first, later])

            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "workspace-delete-lease-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            defer { Task { _ = await runtime.shutdown() } }

            let coordinator = WorkspaceActivityCoordinator()
            let deletionManager = makeManager(
                windowID: -765,
                domainWorkspaceAuthorityClient: DomainWorkspaceAuthorityClient(
                    store: runtime.workspaceStore,
                    windowID: -765
                ),
                workspaceActivityCoordinator: coordinator
            )
            let activationManager = makeManager(
                windowID: -766,
                workspaceActivityCoordinator: coordinator
            )
            await deletionManager.awaitInitialized()
            await activationManager.awaitInitialized()

            let firstDeleteStarted = expectation(description: "first deletion suspended")
            let gate = WorkspaceDeleteSuspensionGate()
            deletionManager.setWorkspaceDeleteWillExecuteHandlerForTesting { workspaceID in
                guard workspaceID == firstID else { return }
                firstDeleteStarted.fulfill()
                await gate.wait()
            }

            let deletionTask = Task {
                await deletionManager.deleteWorkspacesAsync(
                    workspaceIDs: [firstID, laterID],
                    leakedTestFixtureWorkspaceIDs: [firstID, laterID]
                )
            }
            await fulfillment(of: [firstDeleteStarted], timeout: 2)

            let activation = await activationManager.switchWorkspace(to: later, saveState: false)
            XCTAssertFalse(activation.didSwitch)
            if case let .blocked(message) = activation {
                XCTAssertTrue(message.contains("being deleted"), message)
            } else {
                XCTFail("Expected deletion lease to reject activation, got \(activation)")
            }

            await gate.open()
            let result = await deletionTask.value
            deletionManager.setWorkspaceDeleteWillExecuteHandlerForTesting(nil)

            XCTAssertEqual(Set(result.deletedWorkspaceIDs), [firstID, laterID])
            XCTAssertTrue(result.skippedReasonsByWorkspaceID.isEmpty)
            let authoritativeAfter = await runtime.workspaceStore.snapshot()
            XCTAssertFalse(authoritativeAfter.workspaces.contains { $0.document.workspaceID == laterID })
        }

        func testBulkDeleteRefreshesWorkspaceRevisionAfterSuccessfulDeletion() async throws {
            let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
            let laterID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
            let first = WorkspaceModel(id: firstID, name: "First", repoPaths: ["/tmp/first"])
            let later = WorkspaceModel(id: laterID, name: "Later", repoPaths: ["/tmp/later"])
            for workspace in [first, later] {
                try writeWorkspace(workspace)
            }
            try writeLegacyIndex([first, later])

            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "workspace-delete-refresh-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            defer { Task { _ = await runtime.shutdown() } }

            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -770)
            let manager = makeManager(
                windowID: -770,
                domainWorkspaceAuthorityClient: client
            )
            await manager.awaitInitialized()

            let initialLaterSnapshot = await client.canonicalWorkspaceSnapshot(laterID)
            let initialLater = try XCTUnwrap(initialLaterSnapshot)
            var revisedLater = later
            revisedLater.name = "Later Revised"
            var revisionOutcome: DomainCommandOutcome?
            var revisionError: Error?
            manager.setWorkspaceDeleteWillExecuteHandlerForTesting { workspaceID in
                guard workspaceID == firstID else { return }
                do {
                    revisionOutcome = try await client.replaceWorking(
                        revisedLater,
                        fileURL: initialLater.document.fileURL,
                        expectedWorkspaceRevision: initialLater.revisions.workingRevision
                    )
                } catch {
                    revisionError = error
                }
            }

            let result = await manager.deleteWorkspacesAsync(workspaceIDs: [firstID, laterID])
            manager.setWorkspaceDeleteWillExecuteHandlerForTesting(nil)

            XCTAssertNil(revisionError)
            XCTAssertEqual(revisionOutcome?.disposition, .applied)
            XCTAssertEqual(Set(result.deletedWorkspaceIDs), [firstID, laterID])
            XCTAssertTrue(result.failedReasonsByWorkspaceID.isEmpty)
        }

        private func leakedFixtureWorkspace(id: UUID = UUID()) -> WorkspaceModel {
            WorkspaceModel(
                id: id,
                name: "Agent Mode Chat Switch \(UUID().uuidString.prefix(8))",
                repoPaths: [
                    storageRoot
                        .appendingPathComponent("AgentModeChatSwitchActivationTests-\(UUID().uuidString)", isDirectory: true)
                        .appendingPathComponent("repo", isDirectory: true)
                        .path
                ],
                ephemeralFlag: true
            )
        }

        private func persistentReadFixtureWorkspace(id: UUID = UUID()) -> WorkspaceModel {
            WorkspaceModel(
                id: id,
                name: "Persistent Agent Mode MCP Read",
                repoPaths: [
                    storageRoot
                        .appendingPathComponent("PersistentAgentModeMCPReadFileConnectionTests", isDirectory: true)
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                        .path
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

        private func makeManager(
            windowID: Int,
            domainWorkspaceAuthorityClient: DomainWorkspaceAuthorityClient? = nil,
            workspaceActivityCoordinator: WorkspaceActivityCoordinator? = nil
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
                workspaceActivityCoordinator: workspaceActivityCoordinator
                    ?? WindowStatesManager.shared.workspaceActivityCoordinator,
                performInitialWorkspaceActivation: false
            )
            managers.append(manager)
            return manager
        }
    }

    private actor WorkspaceDeleteSuspensionGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }
#endif
