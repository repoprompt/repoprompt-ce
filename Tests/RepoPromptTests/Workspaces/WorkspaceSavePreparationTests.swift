@testable import RepoPromptApp
import XCTest

#if DEBUG
    @MainActor
    final class WorkspaceSavePreparationTests: XCTestCase {
        private var originalMCPAutoStart = false
        private var savePreparationGates: [WorkspaceSavePreparationGate] = []
        private var saveTasks: [Task<Void, Never>] = []
        private var managersWithSavePreparationHooks: [WorkspaceManagerViewModel] = []

        override func setUp() async throws {
            try await super.setUp()
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
        }

        override func tearDown() async throws {
            for managersWithSavePreparationHook in managersWithSavePreparationHooks {
                managersWithSavePreparationHook.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
            }
            savePreparationGates.forEach { $0.cancel() }
            saveTasks.forEach { $0.cancel() }
            for saveTask in saveTasks {
                await saveTask.value
            }
            managersWithSavePreparationHooks.removeAll()
            savePreparationGates.removeAll()
            saveTasks.removeAll()
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
            GlobalSettingsStore.shared.setMCPAutoStart(originalMCPAutoStart, commit: false)
            try await super.tearDown()
        }

        func testSaveKeepsCapturedWorkspaceIdentityAndURLAcrossReorderAfterPreparation() async throws {
            let storageRoot = try temporaryDirectory(named: "IdentityURL")
            defer { try? FileManager.default.removeItem(at: storageRoot) }
            let composition = makeComposition(windowID: -981)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let workspaceA = makeWorkspace(name: "A", storage: storageRoot.appendingPathComponent("A"))
            let workspaceB = makeWorkspace(name: "B", storage: storageRoot.appendingPathComponent("B"))
            manager.workspaces.append(contentsOf: [workspaceA, workspaceB])
            let switchResult = await manager.switchWorkspace(to: workspaceA, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            manager.markWorkspaceDirty()

            let gate = WorkspaceSavePreparationGate()
            savePreparationGates.append(gate)
            managersWithSavePreparationHooks.append(manager)
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { workspaceID, fileURL, _ in
                await gate.arriveAndWait(workspaceID: workspaceID, fileURL: fileURL)
            }
            let saveTask = Task { @MainActor in
                await manager.pollAndSaveStateAsync()
            }
            saveTasks.append(saveTask)
            let arrival = try await gate.waitUntilArrivedAndBlocked()
            XCTAssertEqual(arrival.workspaceID, workspaceA.id)
            XCTAssertEqual(arrival.fileURL, manager.workspaceFileURL(for: workspaceA))
            try manager.workspaces.swapAt(
                XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspaceA.id }),
                XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspaceB.id })
            )
            gate.release()
            await saveTask.value
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)

            let savedA = try WorkspaceManagerViewModel.loadWorkspaceFromFile(at: arrival.fileURL)
            XCTAssertEqual(savedA.id, workspaceA.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: manager.workspaceFileURL(for: workspaceB).path))
        }

        func testSaveBailsWithoutEnqueueOrAcknowledgementWhenWorkspaceRemovedAfterPreparation() async throws {
            let storageRoot = try temporaryDirectory(named: "Removal")
            defer { try? FileManager.default.removeItem(at: storageRoot) }
            let composition = makeComposition(windowID: -982)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let workspace = makeWorkspace(name: "Removed", storage: storageRoot.appendingPathComponent("Removed"))
            manager.workspaces.append(workspace)
            let switchResult = await manager.switchWorkspace(to: workspace, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            manager.markWorkspaceDirty()
            let expectedURL = manager.workspaceFileURL(for: workspace)

            let gate = WorkspaceSavePreparationGate()
            savePreparationGates.append(gate)
            managersWithSavePreparationHooks.append(manager)
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { workspaceID, fileURL, _ in
                await gate.arriveAndWait(workspaceID: workspaceID, fileURL: fileURL)
            }
            let saveTask = Task { @MainActor in
                await manager.pollAndSaveStateAsync()
            }
            saveTasks.append(saveTask)
            _ = try await gate.waitUntilArrivedAndBlocked()
            manager.workspaces.removeAll { $0.id == workspace.id }
            gate.release()
            await saveTask.value
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)

            XCTAssertFalse(FileManager.default.fileExists(atPath: expectedURL.path))
            XCTAssertNil(manager.debugLastSavedVersionForWorkspace(workspace.id))
        }

        func testSaveRetriesSameIdentityOnceWhenStateChangesAfterPreparation() async throws {
            let storageRoot = try temporaryDirectory(named: "Retry")
            defer { try? FileManager.default.removeItem(at: storageRoot) }
            let composition = makeComposition(windowID: -983)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let workspace = makeWorkspace(name: "Retry", storage: storageRoot.appendingPathComponent("Retry"))
            manager.workspaces.append(workspace)
            let switchResult = await manager.switchWorkspace(to: workspace, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            manager.markWorkspaceDirty()
            manager.resetWorkspaceSaveDiagnosticsForTesting()

            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { workspaceID, _, remainingRetryCount in
                guard remainingRetryCount == 1 else { return }
                await MainActor.run {
                    guard let index = manager.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
                    manager.workspaces[index].currentPromptText = "newer state"
                    manager.markWorkspaceDirty()
                }
            }
            await manager.pollAndSaveStateAsync()
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)

            let diagnostics = manager.workspaceSaveDiagnosticsForTesting(workspaceID: workspace.id)
            XCTAssertEqual(diagnostics.attemptCount, 2)
            let saved = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: manager.workspaceFileURL(for: workspace)
            )
            XCTAssertEqual(saved.currentPromptText, "newer state")
            XCTAssertEqual(
                manager.debugLastSavedVersionForWorkspace(workspace.id),
                manager.debugStateVersionForWorkspace(workspace.id)
            )
        }

        func testPreparationFailureDoesNotAdvanceLastSavedVersion() async throws {
            let storageRoot = try temporaryDirectory(named: "Failure")
            defer { try? FileManager.default.removeItem(at: storageRoot) }
            let blockingFile = storageRoot.appendingPathComponent("not-a-directory")
            try Data("block".utf8).write(to: blockingFile)
            let composition = makeComposition(windowID: -984)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let workspace = makeWorkspace(name: "Failure", storage: blockingFile)
            manager.workspaces.append(workspace)
            let switchResult = await manager.switchWorkspace(to: workspace, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            manager.markWorkspaceDirty()

            await manager.pollAndSaveStateAsync()

            XCTAssertGreaterThan(manager.debugStateVersionForWorkspace(workspace.id), 0)
            XCTAssertNil(manager.debugLastSavedVersionForWorkspace(workspace.id))
        }

        func testQuiescentCapturePublishesWorkspaceOnceWithoutReloadingComposeTabs() async throws {
            let storageRoot = try temporaryDirectory(named: "Publication")
            defer { try? FileManager.default.removeItem(at: storageRoot) }
            let composition = makeComposition(windowID: -985)
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            let workspace = makeWorkspace(name: "Publication", storage: storageRoot.appendingPathComponent("Publication"))
            manager.workspaces.append(workspace)
            let switchResult = await manager.switchWorkspace(to: workspace, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            manager.markWorkspaceDirty()
            manager.resetWorkspaceSaveDiagnosticsForTesting()

            await manager.pollAndSaveStateAsync()

            let diagnostics = manager.workspaceSaveDiagnosticsForTesting(workspaceID: workspace.id)
            XCTAssertEqual(diagnostics.capturePublicationCount, 1)
            XCTAssertEqual(diagnostics.composeTabReloadCount, 0)
        }

        private func makeComposition(windowID: Int) -> WindowStateComposition {
            WindowStateCompositionFactory.make(
                windowID: windowID,
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService(),
                workspaceFileContextStore: WorkspaceFileContextStore()
            )
        }

        private func makeWorkspace(name: String, storage: URL) -> WorkspaceModel {
            let tab = ComposeTabState(name: name)
            return WorkspaceModel(
                name: name,
                repoPaths: [],
                customStoragePath: storage,
                composeTabs: [tab],
                activeComposeTabID: tab.id
            )
        }

        private func temporaryDirectory(named name: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorkspaceSavePreparationTests-\(name)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    private final class WorkspaceSavePreparationGate: @unchecked Sendable {
        struct Arrival {
            let workspaceID: UUID
            let fileURL: URL
        }

        private let condition = NSCondition()
        private let releaseFence = TestReleaseFence(name: "workspace save preparation gate")
        private var arrival: Arrival?
        private var arrivalWaiters: [UUID: CheckedContinuation<Arrival?, Never>] = [:]
        private var cancelledArrivalWaiters = Set<UUID>()
        private var isCancelled = false

        func arriveAndWait(workspaceID: UUID, fileURL: URL) async {
            recordArrival(Arrival(workspaceID: workspaceID, fileURL: fileURL))
            await releaseFence.enterAndWait()
        }

        func waitUntilArrivedAndBlocked() async throws -> Arrival {
            guard let arrival = await waitUntilArrived() else {
                throw CancellationError()
            }
            guard await releaseFence.waitUntilEntered() else {
                throw CancellationError()
            }
            return arrival
        }

        func release() {
            releaseFence.release()
        }

        func cancel() {
            condition.lock()
            isCancelled = true
            let pending = Array(arrivalWaiters.values)
            arrivalWaiters.removeAll()
            cancelledArrivalWaiters.removeAll()
            condition.broadcast()
            condition.unlock()
            pending.forEach { $0.resume(returning: nil) }
            releaseFence.release()
        }

        private func waitUntilArrived() async -> Arrival? {
            let waiterID = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    registerArrivalWaiter(continuation, waiterID: waiterID)
                }
            } onCancel: {
                cancelArrivalWaiter(waiterID)
            }
        }

        private func recordArrival(_ value: Arrival) {
            condition.lock()
            guard !isCancelled else {
                condition.unlock()
                return
            }
            arrival = value
            let pending = Array(arrivalWaiters.values)
            arrivalWaiters.removeAll()
            cancelledArrivalWaiters.removeAll()
            condition.broadcast()
            condition.unlock()
            pending.forEach { $0.resume(returning: value) }
        }

        private func registerArrivalWaiter(
            _ continuation: CheckedContinuation<Arrival?, Never>,
            waiterID: UUID
        ) {
            condition.lock()
            if let arrival {
                condition.unlock()
                continuation.resume(returning: arrival)
            } else if isCancelled || Task.isCancelled || cancelledArrivalWaiters.remove(waiterID) != nil {
                condition.unlock()
                continuation.resume(returning: nil)
            } else {
                arrivalWaiters[waiterID] = continuation
                condition.unlock()
            }
        }

        private func cancelArrivalWaiter(_ waiterID: UUID) {
            condition.lock()
            let continuation = arrivalWaiters.removeValue(forKey: waiterID)
            if continuation == nil {
                cancelledArrivalWaiters.insert(waiterID)
            }
            condition.broadcast()
            condition.unlock()
            continuation?.resume(returning: nil)
        }
    }

#endif
