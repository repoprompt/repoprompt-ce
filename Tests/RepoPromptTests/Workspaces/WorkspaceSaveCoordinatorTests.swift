import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class WorkspaceSaveCoordinatorTests: XCTestCase {
    override func tearDown() async throws {
        await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
        try await super.tearDown()
    }

    func testFailedThenSuccessfulPayloadsReceiveTheirOwnOutcomes() async throws {
        let storageRoot = try makeTestDirectory(named: "FailedThenSuccessful")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let url = storageRoot.appendingPathComponent("payload.json")
        let writer = WorkspaceManagerViewModel.WorkspaceDiskWriter.shared
        let gate = WorkspaceSavePreparationGate()
        await writer.setAtomicWriteGateForTesting {
            await gate.pauseFirstPreparation()
        }
        await writer.setFailAtomicWriteForTesting(url: url, afterAdditionalAttempts: 1)

        let failedTask = Task { await writer.enqueueAndWait(data: Data("failed".utf8), url: url) }
        await gate.waitUntilPaused()
        let successfulTask = Task { await writer.enqueueAndWait(data: Data("successful".utf8), url: url) }
        let flushTask = Task { await writer.flush(url: url) }
        await drainMainActorTasks()
        await gate.release()

        let failedOutcome = await failedTask.value
        let successfulOutcome = await successfulTask.value
        let flushOutcome = await flushTask.value
        XCTAssertEqual(failedOutcome, .failed)
        XCTAssertEqual(successfulOutcome, .committed)
        XCTAssertEqual(flushOutcome, .failed)
        XCTAssertEqual(try Data(contentsOf: url), Data("successful".utf8))
    }

    func testSupersededPayloadReportsReplacementFailure() async throws {
        let storageRoot = try makeTestDirectory(named: "SupersededReplacementFailure")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let url = storageRoot.appendingPathComponent("payload.json")
        let writer = WorkspaceManagerViewModel.WorkspaceDiskWriter.shared
        let gate = WorkspaceSavePreparationGate()
        await writer.setAtomicWriteGateForTesting {
            await gate.pauseFirstPreparation()
        }
        await writer.setFailAtomicWriteForTesting(true)

        let workspaceID = UUID()
        let olderWorkspace = WorkspaceModel(
            id: workspaceID,
            dateModified: Date(timeIntervalSince1970: 1000),
            name: "Workspace",
            repoPaths: []
        )
        let newerWorkspace = WorkspaceModel(
            id: workspaceID,
            dateModified: Date(timeIntervalSince1970: 2000),
            name: "Workspace",
            repoPaths: []
        )
        let olderData = try JSONEncoder().encode(olderWorkspace)
        let newerData = try JSONEncoder().encode(newerWorkspace)
        let firstData = Data("first".utf8)

        let firstTask = Task { await writer.enqueueAndWait(data: firstData, url: url) }
        await gate.waitUntilPaused()
        let newerTask = Task { await writer.enqueueAndWait(data: newerData, url: url) }
        let olderTask = Task { await writer.enqueueAndWait(data: olderData, url: url) }
        let flushTask = Task { await writer.flush(url: url) }
        await drainMainActorTasks()
        await gate.release()

        let firstOutcome = await firstTask.value
        let newerOutcome = await newerTask.value
        let olderOutcome = await olderTask.value
        let flushOutcome = await flushTask.value
        XCTAssertEqual(firstOutcome, .failed)
        XCTAssertEqual(newerOutcome, .failed)
        XCTAssertEqual(olderOutcome, .failed)
        XCTAssertEqual(flushOutcome, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSuccessfulThenFailedPayloadsReceiveTheirOwnOutcomes() async throws {
        let storageRoot = try makeTestDirectory(named: "SuccessfulThenFailed")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let url = storageRoot.appendingPathComponent("payload.json")
        let writer = WorkspaceManagerViewModel.WorkspaceDiskWriter.shared
        let gate = WorkspaceSavePreparationGate()
        await writer.setAtomicWriteGateForTesting {
            await gate.pauseFirstPreparation()
        }
        await writer.setFailAtomicWriteForTesting(url: url, afterAdditionalAttempts: 2)

        let successfulTask = Task { await writer.enqueueAndWait(data: Data("successful".utf8), url: url) }
        await gate.waitUntilPaused()
        let failedTask = Task { await writer.enqueueAndWait(data: Data("failed".utf8), url: url) }
        let flushTask = Task { await writer.flush(url: url) }
        await drainMainActorTasks()
        await gate.release()

        let successfulOutcome = await successfulTask.value
        let failedOutcome = await failedTask.value
        let flushOutcome = await flushTask.value
        XCTAssertEqual(successfulOutcome, .committed)
        XCTAssertEqual(failedOutcome, .failed)
        XCTAssertEqual(flushOutcome, .failed)
        XCTAssertEqual(try Data(contentsOf: url), Data("successful".utf8))
    }

    func testCloseBoundaryFlushesPendingDebouncedSave() async throws {
        let storageRoot = try makeTestDirectory(named: "CloseDuringDebounce")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let manager = makeManager(storageRoot: storageRoot)
        let workspace = representativeWorkspace(storageRoot: storageRoot)
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        manager.test_markWorkspaceDirty(workspaceID: workspace.id)

        manager.test_scheduleWorkspaceSave(source: "test.close.deferred")
        manager.prepareForWindowClose()
        let outcome = await manager.flushPendingWorkspaceSavesBeforeClose()

        let committedVersion = try unwrapCommittedVersion(outcome)
        XCTAssertEqual(manager.test_lastSavedVersion(workspaceID: workspace.id), committedVersion)
        let fileURL = try XCTUnwrap(workspace.customStoragePath?.appendingPathComponent("workspace.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let decoded = try WorkspaceManagerViewModel.loadWorkspaceFromFile(at: fileURL)
        XCTAssertEqual(decoded.id, workspace.id)
    }

    func testCloseBoundaryRetriesDirtyVersionAfterEarlierFailure() async throws {
        let storageRoot = try makeTestDirectory(named: "CloseRetryAfterFailure")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let manager = makeManager(storageRoot: storageRoot)
        defer { manager.prepareForWindowClose() }
        let workspace = representativeWorkspace(storageRoot: storageRoot)
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        manager.test_markWorkspaceDirty(workspaceID: workspace.id)
        let writer = WorkspaceManagerViewModel.WorkspaceDiskWriter.shared
        await writer.setFailAtomicWriteForTesting(true)

        manager.test_scheduleWorkspaceSave(source: "test.preCloseFailure")
        let failed = await manager.test_flushWorkspaceSave(
            workspaceID: workspace.id,
            source: "test.observePreCloseFailure"
        )
        XCTAssertEqual(failed, .failed)
        XCTAssertNil(manager.test_lastSavedVersion(workspaceID: workspace.id))

        await writer.setFailAtomicWriteForTesting(false)
        let closeOutcome = await manager.flushPendingWorkspaceSavesBeforeClose()
        _ = try unwrapCommittedVersion(closeOutcome)
        XCTAssertNotNil(manager.test_lastSavedVersion(workspaceID: workspace.id))
        let fileURL = try XCTUnwrap(workspace.customStoragePath?.appendingPathComponent("workspace.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testRapidRequestsCoalesceBeforeRepresentativeWorkspacePreparation() async throws {
        let storageRoot = try makeTestDirectory(named: "RapidRequests")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let manager = makeManager(storageRoot: storageRoot)
        defer { manager.prepareForWindowClose() }
        let workspace = representativeWorkspace(storageRoot: storageRoot)
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        manager.test_markWorkspaceDirty(workspaceID: workspace.id)

        for _ in 0 ..< 100 {
            manager.test_scheduleWorkspaceSave(source: "test.rapid")
        }
        await drainMainActorTasks()
        let outcome = await manager.test_flushWorkspaceSave(workspaceID: workspace.id, source: "test.rapid.flush")

        let committedVersion = try unwrapCommittedVersion(outcome)
        XCTAssertEqual(manager.test_lastSavedVersion(workspaceID: workspace.id), committedVersion)
        XCTAssertEqual(manager.test_workspaceSavePreparationCount(workspaceID: workspace.id), 1)
        let summary = try XCTUnwrap(manager.test_workspaceSavePerformanceSummary(workspaceID: workspace.id))
        XCTAssertEqual(summary.composeTabCount, 25)
        XCTAssertGreaterThanOrEqual(summary.payloadByteCount, 100_000)
        XCTAssertEqual(summary.selectedPathCount, 180)
        XCTAssertEqual(summary.sliceFileCount, 130)
        XCTAssertEqual(summary.sliceRangeCount, 260)
        XCTAssertGreaterThanOrEqual(summary.coalescedRequestCount, 100)
        XCTAssertEqual(summary.atomicWriteCount, 1)
    }

    func testMutationDuringPreparationProducesOneFollowUpAndFlushCommitsNewestState() async throws {
        let storageRoot = try makeTestDirectory(named: "MutationDuringPreparation")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let manager = makeManager(storageRoot: storageRoot)
        defer { manager.prepareForWindowClose() }
        var workspace = representativeWorkspace(storageRoot: storageRoot)
        workspace.currentPromptText = "before"
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        manager.test_markWorkspaceDirty(workspaceID: workspace.id)
        let gate = WorkspaceSavePreparationGate()
        manager.test_setWorkspaceSavePreparationGate { _, _ in
            await gate.pauseFirstPreparation()
        }

        manager.test_scheduleWorkspaceSave(source: "test.blockedPreparation")
        await gate.waitUntilPaused()
        manager.workspaces[0].currentPromptText = "after"
        manager.workspaces[0].dateModified = Date()
        manager.test_markWorkspaceDirty(workspaceID: workspace.id)
        for _ in 0 ..< 20 {
            manager.test_scheduleWorkspaceSave(source: "test.newerWhileBlocked")
        }
        await drainMainActorTasks()
        await gate.release()
        let outcome = await manager.test_flushWorkspaceSave(workspaceID: workspace.id, source: "test.boundaryFlush")
        manager.test_setWorkspaceSavePreparationGate(nil)

        let committedVersion = try unwrapCommittedVersion(outcome)
        XCTAssertEqual(manager.test_workspaceSavePreparationCount(workspaceID: workspace.id), 2)
        let fileURL = try XCTUnwrap(workspace.customStoragePath?.appendingPathComponent("workspace.json"))
        let decoded = try WorkspaceManagerViewModel.loadWorkspaceFromFile(at: fileURL)
        XCTAssertEqual(decoded.currentPromptText, "after")
        XCTAssertEqual(manager.test_lastSavedVersion(workspaceID: workspace.id), committedVersion)
    }

    func testMutationDuringAtomicWriteFlushesNewestStateBeforeCompleting() async throws {
        let storageRoot = try makeTestDirectory(named: "MutationDuringAtomicWrite")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let manager = makeManager(storageRoot: storageRoot)
        defer { manager.prepareForWindowClose() }
        var workspace = representativeWorkspace(storageRoot: storageRoot)
        workspace.currentPromptText = "before"
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        manager.test_markWorkspaceDirty(workspaceID: workspace.id)
        let gate = WorkspaceSavePreparationGate()
        await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.setAtomicWriteGateForTesting {
            await gate.pauseFirstPreparation()
        }

        manager.test_scheduleWorkspaceSave(source: "test.blockedAtomicWrite")
        let flushTask = Task {
            await manager.test_flushWorkspaceSave(workspaceID: workspace.id, source: "test.boundaryFlush")
        }
        await gate.waitUntilPaused()
        manager.workspaces[0].currentPromptText = "after"
        manager.workspaces[0].dateModified = Date()
        manager.test_markWorkspaceDirty(workspaceID: workspace.id)
        await gate.release()

        let committedVersion = try await unwrapCommittedVersion(flushTask.value)
        let fileURL = try XCTUnwrap(workspace.customStoragePath?.appendingPathComponent("workspace.json"))
        let decoded = try WorkspaceManagerViewModel.loadWorkspaceFromFile(at: fileURL)
        XCTAssertEqual(decoded.currentPromptText, "after")
        XCTAssertEqual(manager.test_lastSavedVersion(workspaceID: workspace.id), committedVersion)
        XCTAssertEqual(manager.test_workspaceSavePreparationCount(workspaceID: workspace.id), 2)
    }

    func testFailedAtomicWriteIsObservableAndDoesNotAdvanceSavedVersion() async throws {
        let storageRoot = try makeTestDirectory(named: "FailedWrite")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let manager = makeManager(storageRoot: storageRoot)
        defer { manager.prepareForWindowClose() }
        var workspace = representativeWorkspace(storageRoot: storageRoot)
        workspace.currentPromptText = "state to retry"
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        manager.test_markWorkspaceDirty(workspaceID: workspace.id)
        let writer = WorkspaceManagerViewModel.WorkspaceDiskWriter.shared
        let fileURL = try XCTUnwrap(workspace.customStoragePath?.appendingPathComponent("workspace.json"))
        await writer.setFailAtomicWriteForTesting(true)

        manager.test_scheduleWorkspaceSave(source: "test.failingSnapshot")
        let failed = await manager.test_flushWorkspaceSave(workspaceID: workspace.id, source: "test.injectedFailure")

        XCTAssertEqual(failed, .failed)
        XCTAssertNil(manager.test_lastSavedVersion(workspaceID: workspace.id))

        await writer.setFailAtomicWriteForTesting(false)
        let retried = await manager.test_flushWorkspaceSave(workspaceID: workspace.id, source: "test.retryAfterFailure")
        let committedVersion = try unwrapCommittedVersion(retried)
        XCTAssertEqual(manager.test_lastSavedVersion(workspaceID: workspace.id), committedVersion)
        let decoded = try WorkspaceManagerViewModel.loadWorkspaceFromFile(at: fileURL)
        XCTAssertEqual(decoded.currentPromptText, "state to retry")
    }

    private func unwrapCommittedVersion(_ outcome: WorkspaceSaveCompletion) throws -> Int {
        guard case let .committed(version) = outcome else {
            XCTFail("Expected committed workspace save, received \(outcome)")
            throw UnexpectedWorkspaceSaveOutcome()
        }
        return version
    }

    private func makeManager(storageRoot: URL) -> WorkspaceManagerViewModel {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        let defaults = UserDefaults.standard
        let previousStoragePath = defaults.string(forKey: "GlobalCustomStorageURL")
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defaults.set(storageRoot.path, forKey: "GlobalCustomStorageURL")
        defer {
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            if let previousStoragePath {
                defaults.set(previousStoragePath, forKey: "GlobalCustomStorageURL")
            } else {
                defaults.removeObject(forKey: "GlobalCustomStorageURL")
            }
        }
        return WindowStateCompositionFactory.make(
            windowID: -940 - Int.random(in: 1 ... 40),
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        ).workspaceManager
    }

    private func representativeWorkspace(storageRoot: URL) -> WorkspaceModel {
        let selectedPaths = (0 ..< 180).map { "/synthetic/root/File\($0).swift" }
        let slices = Dictionary(uniqueKeysWithValues: (0 ..< 130).map { index in
            (
                "/synthetic/root/Slice\(index).swift",
                [
                    LineRange(start: 1, end: 5),
                    LineRange(start: 20, end: 30)
                ]
            )
        })
        let selection = StoredSelection(
            selectedPaths: selectedPaths,
            slices: slices,
            codemapAutoEnabled: false
        )
        let tabs = (0 ..< 25).map { index in
            ComposeTabState(
                name: "T\(index + 1)",
                selection: index == 0 ? selection : .init(),
                promptText: String(repeating: "p", count: 4000)
            )
        }
        return WorkspaceModel(
            name: "Synthetic Save Fixture",
            repoPaths: ["/synthetic/root"],
            customStoragePath: storageRoot.appendingPathComponent("workspace", isDirectory: true),
            composeTabs: tabs,
            activeComposeTabID: tabs[0].id
        )
    }

    private func makeTestDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSaveCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func drainMainActorTasks() async {
        for _ in 0 ..< 5 {
            await Task.yield()
        }
    }
}

private struct UnexpectedWorkspaceSaveOutcome: Error {}

private actor WorkspaceSavePreparationGate {
    private var didPause = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pauseFirstPreparation() async {
        guard !didPause else { return }
        didPause = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilPaused() async {
        if didPause {
            return
        }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
