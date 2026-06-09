import Foundation
@testable import RepoPromptCore
import XCTest

final class WorkspaceRepositoryTests: XCTestCase {
    func testSnapshotPreservesIndexOrderAndSkipsMissingEntries() async throws {
        let root = try makeTemporaryDirectory()
        let graph = Slice1TestWorkspaceGraph(root: root)
        let first = makeSlice1Workspace(name: "First", repoPaths: ["/tmp/first"])
        let missing = makeSlice1Workspace(name: "Missing", repoPaths: ["/tmp/missing"])
        let second = makeSlice1Workspace(name: "Second", repoPaths: ["/tmp/second"])
        try writeWorkspace(first, under: root)
        try writeWorkspace(second, under: root)
        try writeIndex([entry(first), entry(missing), entry(second)], under: root)

        let inventory = await graph.repository.loadInventory()

        XCTAssertEqual(inventory.entries.map(\.id), [first.id, missing.id, second.id])
        XCTAssertEqual(inventory.workspaces.map(\.id), [first.id, second.id])
    }

    func testSnapshotLoadsCustomStoragePath() async throws {
        let root = try makeTemporaryDirectory()
        let customRoot = try makeTemporaryDirectory()
        let graph = Slice1TestWorkspaceGraph(root: root)
        let workspace = WorkspaceModel(
            name: "Custom",
            repoPaths: ["/tmp/custom"],
            customStoragePath: customRoot
        )
        try EmbeddedWorkspaceCodecV1().encode(workspace).data.write(
            to: customRoot.appendingPathComponent("workspace.json"),
            options: .atomic
        )
        try writeIndex([entry(workspace)], under: root)

        let snapshot = await graph.repository.loadWorkspaceSnapshotFromDisk()

        XCTAssertEqual(snapshot.map(\.id), [workspace.id])
        XCTAssertEqual(snapshot.first?.repoPaths, ["/tmp/custom"])
    }

    func testNormalizationRequiringLoadDoesNotRewriteDocumentOrIndex() async throws {
        let root = try makeTemporaryDirectory()
        let graph = Slice1TestWorkspaceGraph(root: root)
        let workspaceID = UUID()
        let workspaceDirectory = root.appendingPathComponent(
            "Workspace-Normalization-\(workspaceID.uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        let workspaceURL = workspaceDirectory.appendingPathComponent("workspace.json")
        let payload = """
        {
          "id": "\(workspaceID.uuidString)",
          "schemaVersion": 1,
          "dateModified": 0,
          "name": "Normalization",
          "repoPaths": ["/tmp/root"],
          "composeTabs": [],
          "stashedTabs": []
        }
        """
        try Data(payload.utf8).write(to: workspaceURL)
        try writeIndex([
            WorkspaceIndexEntry(
                id: workspaceID,
                name: "Normalization",
                customStoragePath: nil,
                isSystemWorkspace: false,
                isHiddenInMenus: false
            )
        ], under: root)
        let indexURL = root.appendingPathComponent("workspacesIndex.json")
        let beforeWorkspace = try Data(contentsOf: workspaceURL)
        let beforeIndex = try Data(contentsOf: indexURL)
        let beforeModified = try workspaceURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        let inventory = await graph.repository.loadInventory()

        let workspace = try XCTUnwrap(inventory.workspaces.first)
        XCTAssertEqual(workspace.composeTabs.count, 1)
        XCTAssertTrue(try XCTUnwrap(inventory.decodeResults[workspaceID]).requiresRewrite)
        XCTAssertEqual(try Data(contentsOf: workspaceURL), beforeWorkspace)
        XCTAssertEqual(try Data(contentsOf: indexURL), beforeIndex)
        XCTAssertEqual(
            try workspaceURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            beforeModified
        )
    }

    func testConcurrentMergingIndexSavesPreserveEveryEntry() async throws {
        let root = try makeTemporaryDirectory()
        let graph = Slice1TestWorkspaceGraph(root: root)
        let gate = RepositoryIndexWriteGate()
        await graph.writer.setAtomicWriteGateForTesting { await gate.waitIfFirstWrite() }
        let first = makeSlice1Workspace(name: "First")
        let second = makeSlice1Workspace(name: "Second")

        let firstReceipt = try await graph.repository.saveIndex([entry(first)], mergingExisting: true)
        await gate.waitUntilFirstWriteStarted()
        let secondReceipt = try await graph.repository.saveIndex([entry(second)], mergingExisting: true)
        let completionTask = Task { await graph.repository.flush(secondReceipt) }
        await gate.releaseFirstWrite()
        let completion = await completionTask.value
        await graph.writer.setAtomicWriteGateForTesting(nil)

        XCTAssertTrue(completion.succeeded)
        XCTAssertLessThan(firstReceipt.sequence, secondReceipt.sequence)
        let layout = FixedWorkspaceRepositoryLayout(repositoryRoot: root)
        let entries = try JSONDecoder().decode([WorkspaceIndexEntry].self, from: Data(contentsOf: layout.indexURL))
        XCTAssertEqual(Set(entries.map(\.id)), Set([first.id, second.id]))
    }

    func testExplicitSaveWritesDocumentAndIndexThroughSharedWriter() async throws {
        let root = try makeTemporaryDirectory()
        let graph = Slice1TestWorkspaceGraph(root: root)
        let workspace = makeSlice1Workspace(name: "Explicit", promptText: "saved")

        try await graph.repository.save(workspace)

        let layout = FixedWorkspaceRepositoryLayout(repositoryRoot: root)
        let data = try Data(contentsOf: layout.workspaceDocumentURL(id: workspace.id, name: workspace.name))
        let decoded = try EmbeddedWorkspaceCodecV1().decode(data).document
        XCTAssertEqual(decoded, workspace)
        let entries = try JSONDecoder().decode([WorkspaceIndexEntry].self, from: Data(contentsOf: layout.indexURL))
        XCTAssertEqual(entries.map(\.id), [workspace.id])
    }

    private func entry(_ workspace: WorkspaceModel) -> WorkspaceIndexEntry {
        WorkspaceIndexEntry(workspace: workspace)
    }

    private func writeWorkspace(_ workspace: WorkspaceModel, under root: URL) throws {
        let directory = root.appendingPathComponent("Workspace-\(workspace.name)-\(workspace.id.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try EmbeddedWorkspaceCodecV1().encode(workspace).data.write(
            to: directory.appendingPathComponent("workspace.json"),
            options: .atomic
        )
    }

    private func writeIndex(_ entries: [WorkspaceIndexEntry], under root: URL) throws {
        try JSONEncoder().encode(entries).write(
            to: root.appendingPathComponent("workspacesIndex.json"),
            options: .atomic
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceRepositoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

private actor RepositoryIndexWriteGate {
    private var firstStarted = false
    private var firstReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitIfFirstWrite() async {
        guard !firstStarted else { return }
        firstStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        guard !firstReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilFirstWriteStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstWrite() {
        firstReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
