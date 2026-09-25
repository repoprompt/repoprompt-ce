import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    final class WorkspaceRootCatalogSnapshotTests: XCTestCase {
        @MainActor
        func testPostActivationWindowTimesOutInsteadOfReturningEmptyConfiguredSnapshot() async throws {
            let rootURL = try makeTemporaryRoot(name: "CatalogHeld")
            let source = WorkspaceModel(name: "Source", repoPaths: [])
            let target = WorkspaceModel(name: "Target", repoPaths: [rootURL.path])
            let manager = makeManager(workspaces: [source, target], active: source)
            let gate = RootHydrationSuspensionGate()
            manager.setWorkspaceRootHydrationWillSpawnHandlerForTesting { workspaceID in
                guard workspaceID == target.id else { return }
                await gate.hold()
            }

            let switchTask = Task { @MainActor in
                await manager.switchWorkspace(to: target, saveState: false, reason: "catalog-test")
            }
            await gate.waitUntilHeld()
            XCTAssertEqual(manager.activeWorkspaceID, target.id)

            do {
                _ = try await manager.awaitWorkspaceRootCatalogSnapshot(
                    workspaceID: target.id,
                    timeout: .milliseconds(20)
                )
                XCTFail("Configured workspace must not publish an empty snapshot while hydration is held")
            } catch let error as WorkspaceRootCatalogSnapshotError {
                XCTAssertEqual(error, .readinessTimedOut)
            }

            await gate.release()
            let switchResult = await switchTask.value
            XCTAssertTrue(switchResult.didSwitch)
            let snapshot = try await manager.awaitWorkspaceRootCatalogSnapshot(
                workspaceID: target.id,
                timeout: .seconds(1)
            )
            let storeRoots = await manager.fileManager.workspaceFileContextStore.roots()
                .filter { $0.kind == .primaryWorkspace }

            XCTAssertEqual(snapshot.configuredRootPaths, [rootURL.standardizedFileURL.path])
            XCTAssertEqual(snapshot.primaryRoots.map(\.id), storeRoots.map(\.id))
            XCTAssertEqual(snapshot.primaryRoots.map(\.standardizedFullPath), [rootURL.standardizedFileURL.path])
        }

        @MainActor
        func testCancelledCatalogWaitRemovesOnlyItsWaiter() async throws {
            let rootURL = try makeTemporaryRoot(name: "CatalogCancelled")
            let source = WorkspaceModel(name: "Source", repoPaths: [])
            let target = WorkspaceModel(name: "Target", repoPaths: [rootURL.path])
            let manager = makeManager(workspaces: [source, target], active: source)
            let gate = RootHydrationSuspensionGate()
            manager.setWorkspaceRootHydrationWillSpawnHandlerForTesting { workspaceID in
                guard workspaceID == target.id else { return }
                await gate.hold()
            }
            let switchTask = Task { @MainActor in
                await manager.switchWorkspace(to: target, saveState: false, reason: "catalog-cancel-test")
            }
            await gate.waitUntilHeld()
            let cancelledWait = Task { @MainActor in
                try await manager.awaitWorkspaceRootCatalogSnapshot(
                    workspaceID: target.id,
                    timeout: .seconds(30)
                )
            }
            let survivingWait = Task { @MainActor in
                try await manager.awaitWorkspaceRootCatalogSnapshot(
                    workspaceID: target.id,
                    timeout: .seconds(30)
                )
            }
            await Task.yield()
            await Task.yield()

            cancelledWait.cancel()
            do {
                _ = try await cancelledWait.value
                XCTFail("Cancelled waiter must throw")
            } catch is CancellationError {
                // Expected.
            }
            await gate.release()
            _ = await switchTask.value
            let survivingSnapshot = try await survivingWait.value
            XCTAssertEqual(survivingSnapshot.workspaceID, target.id)
            XCTAssertEqual(manager.workspaceSearchReadinessWaiterCountForTesting, 0)
        }

        @MainActor
        func testAdditionalLoadedPrimaryRootIsRejectedAsInconsistent() async throws {
            let configuredRoot = try makeTemporaryRoot(name: "CatalogConfigured")
            let extraRoot = try makeTemporaryRoot(name: "CatalogExtra")
            let source = WorkspaceModel(name: "Source", repoPaths: [])
            let target = WorkspaceModel(name: "Target", repoPaths: [configuredRoot.path])
            let manager = makeManager(workspaces: [source, target], active: source)

            let result = await manager.switchWorkspace(to: target, saveState: false, reason: "catalog-mismatch-test")
            XCTAssertTrue(result.didSwitch)
            _ = try await manager.fileManager.workspaceFileContextStore.loadRoot(path: extraRoot.path)

            do {
                _ = try await manager.awaitWorkspaceRootCatalogSnapshot(
                    workspaceID: target.id,
                    timeout: .seconds(1)
                )
                XCTFail("An additional primary root must invalidate exact catalog authority")
            } catch let error as WorkspaceRootCatalogSnapshotError {
                XCTAssertEqual(error, .inconsistentRootProjection)
            }
        }

        @MainActor
        func testGenerationInvalidationSupersedesPendingCatalogWait() async throws {
            let rootURL = try makeTemporaryRoot(name: "CatalogSuperseded")
            let source = WorkspaceModel(name: "Source", repoPaths: [])
            let target = WorkspaceModel(name: "Target", repoPaths: [rootURL.path])
            let manager = makeManager(workspaces: [source, target], active: source)
            let gate = RootHydrationSuspensionGate()
            manager.setWorkspaceRootHydrationWillSpawnHandlerForTesting { workspaceID in
                guard workspaceID == target.id else { return }
                await gate.hold()
            }
            let switchTask = Task { @MainActor in
                await manager.switchWorkspace(to: target, saveState: false, reason: "catalog-supersede-test")
            }
            await gate.waitUntilHeld()
            let waitTask = Task { @MainActor in
                try await manager.awaitWorkspaceRootCatalogSnapshot(
                    workspaceID: target.id,
                    timeout: .seconds(30)
                )
            }
            await Task.yield()
            await Task.yield()

            await manager.cancelCurrentWorkspaceSwitchAndReturnToSystem()
            do {
                _ = try await waitTask.value
                XCTFail("Invalidating the hydration generation must supersede the pending snapshot")
            } catch let error as WorkspaceRootCatalogSnapshotError {
                XCTAssertEqual(error, .readinessSuperseded)
            }
            XCTAssertEqual(manager.workspaceSearchReadinessWaiterCountForTesting, 0)

            await gate.release()
            _ = await switchTask.value
        }

        @MainActor
        func testGenerationInvalidationAfterRootCaptureUsesCatalogErrorTaxonomy() async throws {
            let rootURL = try makeTemporaryRoot(name: "CatalogPostWaitSuperseded")
            let source = WorkspaceModel(name: "Source", repoPaths: [])
            let target = WorkspaceModel(name: "Target", repoPaths: [rootURL.path])
            let manager = makeManager(workspaces: [source, target], active: source)
            let result = await manager.switchWorkspace(
                to: target,
                saveState: false,
                reason: "catalog-post-wait-supersede-test"
            )
            XCTAssertTrue(result.didSwitch)
            manager.setWorkspaceRootCatalogDidCaptureRootsHandlerForTesting {
                manager.republishReadyRootCatalogWithNextGenerationForTesting()
            }
            addTeardownBlock { @MainActor in
                manager.setWorkspaceRootCatalogDidCaptureRootsHandlerForTesting(nil)
            }

            do {
                _ = try await manager.awaitWorkspaceRootCatalogSnapshot(
                    workspaceID: target.id,
                    timeout: .seconds(1)
                )
                XCTFail("Post-wait readiness invalidation must supersede the catalog snapshot")
            } catch let error as WorkspaceRootCatalogSnapshotError {
                XCTAssertEqual(error, .readinessSuperseded)
            } catch {
                XCTFail("Catalog snapshot must not leak an unrelated readiness error: \(error)")
            }
        }

        @MainActor
        func testCancellationAfterRootCaptureDoesNotPublishCatalogSnapshot() async throws {
            let rootURL = try makeTemporaryRoot(name: "CatalogPostCaptureCancellation")
            let source = WorkspaceModel(name: "Source", repoPaths: [])
            let target = WorkspaceModel(name: "Target", repoPaths: [rootURL.path])
            let manager = makeManager(workspaces: [source, target], active: source)
            let result = await manager.switchWorkspace(
                to: target,
                saveState: false,
                reason: "catalog-post-capture-cancellation-test"
            )
            XCTAssertTrue(result.didSwitch)
            let gate = RootHydrationSuspensionGate()
            manager.setWorkspaceRootCatalogDidCaptureRootsHandlerForTesting {
                await gate.hold()
            }
            addTeardownBlock { @MainActor in
                manager.setWorkspaceRootCatalogDidCaptureRootsHandlerForTesting(nil)
                await gate.release()
            }

            let snapshotTask = Task { @MainActor in
                try await manager.awaitWorkspaceRootCatalogSnapshot(
                    workspaceID: target.id,
                    timeout: .seconds(1)
                )
            }
            await gate.waitUntilHeld()
            snapshotTask.cancel()
            await gate.release()

            do {
                _ = try await snapshotTask.value
                XCTFail("Cancellation after root capture must not publish a catalog snapshot")
            } catch is CancellationError {
                // Expected.
            }
        }

        @MainActor
        func testGenuinelyRootlessWorkspaceProducesSuccessfulEmptySnapshot() async throws {
            let source = WorkspaceModel(name: "Source", repoPaths: [])
            let target = WorkspaceModel(name: "Rootless", repoPaths: [])
            let manager = makeManager(workspaces: [source, target], active: source)

            let result = await manager.switchWorkspace(to: target, saveState: false, reason: "rootless-test")
            XCTAssertTrue(result.didSwitch)
            let snapshot = try await manager.awaitWorkspaceRootCatalogSnapshot(
                workspaceID: target.id,
                timeout: .seconds(1)
            )

            XCTAssertTrue(snapshot.isGenuinelyRootless)
            XCTAssertEqual(snapshot.configuredRootPaths, [])
            XCTAssertEqual(snapshot.primaryRoots, [])
        }

        @MainActor
        private func makeManager(
            workspaces: [WorkspaceModel],
            active: WorkspaceModel
        ) -> WorkspaceManagerViewModel {
            let files = WorkspaceFilesViewModel()
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
            manager.workspaces = workspaces
            manager.activeWorkspace = active
            return manager
        }

        private func makeTemporaryRoot(name: String) throws -> URL {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            return root
        }
    }

    private actor RootHydrationSuspensionGate {
        private var held = false
        private var released = false
        private var heldWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func hold() async {
            held = true
            let waiters = heldWaiters
            heldWaiters.removeAll()
            waiters.forEach { $0.resume() }
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilHeld() async {
            guard !held else { return }
            await withCheckedContinuation { heldWaiters.append($0) }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
#endif
