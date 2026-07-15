@testable import RepoPromptApp
import XCTest

#if DEBUG
    @MainActor
    final class WorkspaceSavePreparationTests: XCTestCase {
        private var originalMCPAutoStart = false

        override func setUp() async throws {
            try await super.setUp()
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
        }

        override func tearDown() async throws {
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
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { workspaceID, fileURL, _ in
                await gate.arriveAndWait(workspaceID: workspaceID, fileURL: fileURL)
            }
            let saveTask = Task { @MainActor in
                await manager.pollAndSaveStateAsync()
            }
            let arrival = await gate.waitUntilArrived()
            XCTAssertEqual(arrival.workspaceID, workspaceA.id)
            XCTAssertEqual(arrival.fileURL, manager.workspaceFileURL(for: workspaceA))
            try manager.workspaces.swapAt(
                XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspaceA.id }),
                XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspaceB.id })
            )
            await gate.release()
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
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { workspaceID, fileURL, _ in
                await gate.arriveAndWait(workspaceID: workspaceID, fileURL: fileURL)
            }
            let saveTask = Task { @MainActor in
                await manager.pollAndSaveStateAsync()
            }
            _ = await gate.waitUntilArrived()
            manager.workspaces.removeAll { $0.id == workspace.id }
            await gate.release()
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

    private actor WorkspaceSavePreparationGate {
        struct Arrival {
            let workspaceID: UUID
            let fileURL: URL
        }

        private var arrival: Arrival?
        private var arrivalWaiters: [CheckedContinuation<Arrival, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func arriveAndWait(workspaceID: UUID, fileURL: URL) async {
            let value = Arrival(workspaceID: workspaceID, fileURL: fileURL)
            arrival = value
            arrivalWaiters.forEach { $0.resume(returning: value) }
            arrivalWaiters.removeAll()
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        func waitUntilArrived() async -> Arrival {
            if let arrival { return arrival }
            return await withCheckedContinuation { continuation in
                arrivalWaiters.append(continuation)
            }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

#endif
