import Combine
@testable import RepoPrompt
import XCTest

@MainActor
final class WorkspaceRootSyncTests: XCTestCase {
    func testReorderRootFoldersNoOpDoesNotEmitRootChange() {
        let viewModel = WorkspaceFilesViewModel()
        let rootA = makeRoot(name: "A", path: "/tmp/A")
        let rootB = makeRoot(name: "B", path: "/tmp/B")
        viewModel.addRootFolder(rootA)
        viewModel.addRootFolder(rootB)

        var changeCount = 0
        viewModel.onRootFoldersChanged = { changeCount += 1 }

        let didReorder = viewModel.reorderRootFolders(to: ["/tmp/A", "/tmp/B"])

        XCTAssertFalse(didReorder)
        XCTAssertEqual(changeCount, 0)
        XCTAssertEqual(viewModel.rootFolders.map(\.id), [rootA.id, rootB.id])
    }

    func testReorderRootFoldersEmitsOnceAndPinsSystemRootsAfterUsers() {
        let viewModel = WorkspaceFilesViewModel()
        let rootA = makeRoot(name: "A", path: "/tmp/A")
        let rootB = makeRoot(name: "B", path: "/tmp/B")
        let rootC = makeRoot(name: "C", path: "/tmp/C")
        let systemScratch = makeRoot(name: "scratch", path: "/tmp/scratch", isSystemRoot: true)
        let gitData = makeRoot(name: "_git_data", path: "/tmp/_git_data", isSystemRoot: true)
        viewModel.addRootFolder(rootA)
        viewModel.addRootFolder(rootB)
        viewModel.addRootFolder(rootC)
        viewModel.addRootFolder(gitData)
        viewModel.addRootFolder(systemScratch)

        var changeCount = 0
        viewModel.onRootFoldersChanged = { changeCount += 1 }

        let didReorder = viewModel.reorderRootFolders(to: ["/tmp/B", "/tmp/A"])

        XCTAssertTrue(didReorder)
        XCTAssertEqual(changeCount, 1)
        XCTAssertEqual(viewModel.rootFolders.map(\.id), [
            rootB.id,
            rootA.id,
            rootC.id, // user roots missing from desired order keep original relative order after desired roots
            systemScratch.id, // system roots stay after user roots
            gitData.id // _git_data pinned last among system roots
        ])
    }

    func testMovedRepoPathsMovesAdjacentRootAndDeduplicatesStandardizedPaths() {
        let moved = WorkspaceRootActions.movedRepoPaths(
            repoPaths: ["/tmp/A/../A", "/tmp/B", "/tmp/a"],
            movingRootPath: "/tmp/A",
            direction: .down
        )

        XCTAssertEqual(moved, ["/tmp/B", "/tmp/A"])
    }

    func testMovedRepoPathsUsesVisibleRootAdjacencyWhenPersistedRootsAreUnloaded() {
        let moved = WorkspaceRootActions.movedRepoPaths(
            repoPaths: ["/tmp/A", "/tmp/missing", "/tmp/B"],
            movingRootPath: "/tmp/B",
            direction: .up,
            visibleRootPaths: ["/tmp/A", "/tmp/B"]
        )

        XCTAssertEqual(moved, ["/tmp/B", "/tmp/missing", "/tmp/A"])
    }

    func testMovedRepoPathsNoOpsForMissingAndEdgeRoots() {
        let repoPaths = ["/tmp/A", "/tmp/B"]

        XCTAssertEqual(
            WorkspaceRootActions.movedRepoPaths(
                repoPaths: repoPaths,
                movingRootPath: "/tmp/missing",
                direction: .down
            ),
            repoPaths
        )
        XCTAssertEqual(
            WorkspaceRootActions.movedRepoPaths(
                repoPaths: repoPaths,
                movingRootPath: "/tmp/A",
                direction: .up
            ),
            repoPaths
        )
        XCTAssertEqual(
            WorkspaceRootActions.movedRepoPaths(
                repoPaths: repoPaths,
                movingRootPath: "/tmp/B",
                direction: .down
            ),
            repoPaths
        )
    }

    func testRootShellProjectionsMirrorRootOrderAndHideSystemRootsForVisibleProjection() {
        let viewModel = WorkspaceFilesViewModel()
        let rootA = makeRoot(name: "A", path: "/tmp/A")
        let rootB = makeRoot(name: "B", path: "/tmp/B")
        let gitData = makeRoot(name: "_git_data", path: "/tmp/_git_data", isSystemRoot: true)
        viewModel.addRootFolder(rootA)
        viewModel.addRootFolder(gitData)
        viewModel.addRootFolder(rootB)

        XCTAssertEqual(viewModel.rootShellProjections.map(\.id), [rootA.id, gitData.id, rootB.id])
        XCTAssertEqual(viewModel.visibleRootShellProjections.map(\.id), [rootA.id, rootB.id])
        XCTAssertEqual(
            viewModel.rootShellProjections[0],
            WorkspaceRootShellProjection(
                id: rootA.id,
                name: rootA.name,
                fullPath: rootA.fullPath,
                standardizedFullPath: rootA.standardizedFullPath,
                isSystemRoot: false
            )
        )
        XCTAssertTrue(viewModel.rootShellProjections[1].isSystemRoot)
    }

    func testRootShellProjectionPublisherIgnoresUnrelatedPublishedChanges() {
        let viewModel = WorkspaceFilesViewModel()
        var changeCount = 0
        var cancellables = Set<AnyCancellable>()
        viewModel.rootShellProjectionsChangedPublisher
            .sink { changeCount += 1 }
            .store(in: &cancellables)

        viewModel.currentSortMethod = .dateNewest
        viewModel.codemapAutoEnabled = false

        XCTAssertEqual(changeCount, 0)
    }

    func testRootShellProjectionBatchPublishesOneFinalNotification() {
        let viewModel = WorkspaceFilesViewModel()
        var changeCount = 0
        var snapshots: [[UUID]] = []
        var cancellables = Set<AnyCancellable>()
        viewModel.rootShellProjectionsChangedPublisher
            .sink {
                changeCount += 1
                snapshots.append(viewModel.visibleRootShellProjections.map(\.id))
            }
            .store(in: &cancellables)
        let rootA = makeRoot(name: "A", path: "/tmp/A")
        let rootB = makeRoot(name: "B", path: "/tmp/B")

        viewModel.beginRootShellProjectionChangeBatch()
        viewModel.addRootFolder(rootA)
        viewModel.addRootFolder(rootB)
        XCTAssertEqual(changeCount, 0)
        _ = viewModel.reorderRootFolders(to: ["/tmp/B", "/tmp/A"])

        viewModel.endRootShellProjectionChangeBatch()

        XCTAssertEqual(changeCount, 1)
        XCTAssertEqual(snapshots, [[rootB.id, rootA.id]])
    }

    func testDefaultWorkspaceAndWindowRootsUseCESupportRoot() {
        let workspaceRoot = WorkspaceStoragePaths.defaultRoot.path
        XCTAssertTrue(workspaceRoot.contains("/Application Support/RepoPrompt CE/Workspaces"), workspaceRoot)
        XCTAssertFalse(workspaceRoot.contains("/Application Support/RepoPrompt/Workspaces"), workspaceRoot)

        let windowPath = WindowSessionStore.sessionFileURL().path
        XCTAssertTrue(windowPath.contains("/Application Support/RepoPrompt CE/windowSessions.json"), windowPath)
        XCTAssertFalse(windowPath.contains("/Application Support/RepoPrompt/windowSessions.json"), windowPath)
    }

    func testWorkspaceDecodeCreatesDefaultComposeTabAndIgnoresRemovedLegacyFields() throws {
        let workspaceID = UUID()
        let payload = """
        {
          "id": "\(workspaceID.uuidString)",
          "schemaVersion": 1,
          "dateModified": 0,
          "name": "Legacy Fields",
          "repoPaths": ["/tmp/root"],
          "presets": [],
          "lastUsed": 0,
          "selectedMetaPromptIDs": [],
          "workingFilePaths": ["/tmp/root/legacy.swift"],
          "workingExpandedFolders": ["/tmp/root"],
          "contextBuilderState": { "useOverridePrompt": true, "overridePromptText": "legacy override" },
          "discoveryInstructions": "legacy instructions",
          "discoveryAgentRaw": "codexExec",
          "composeTabs": [],
          "stashedTabs": []
        }
        """

        let decoded = try JSONDecoder().decode(WorkspaceModel.self, from: Data(payload.utf8))

        XCTAssertEqual(decoded.composeTabs.count, 1)
        XCTAssertEqual(decoded.activeComposeTabID, decoded.composeTabs[0].id)
        XCTAssertEqual(decoded.composeTabs[0].selection, StoredSelection())
        XCTAssertEqual(decoded.composeTabs[0].expandedFolders, [])
        XCTAssertEqual(decoded.composeTabs[0].contextOverrides, ContextBuilderOverrides())
        XCTAssertEqual(decoded.composeTabs[0].contextBuilder.instructions, "")
        XCTAssertTrue(decoded.normalizationRequiresSave)

        let encoded = try String(data: JSONEncoder().encode(decoded), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("workingFilePaths"), encoded)
        XCTAssertFalse(encoded.contains("contextBuilderState"), encoded)
        XCTAssertFalse(encoded.contains("discoveryInstructions"), encoded)
    }

    func testLoadFolderPublishesRootShellProjectionWhenReorderIsNoOp() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptRootSyncTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try "hello".write(to: tempRoot.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let viewModel = WorkspaceFilesViewModel()
        let workspace = WorkspaceModel(name: "Load Folder", repoPaths: [tempRoot.path])
        var changeCount = 0
        var snapshots: [[UUID]] = []
        var cancellables = Set<AnyCancellable>()
        viewModel.rootShellProjectionsChangedPublisher
            .sink {
                changeCount += 1
                snapshots.append(viewModel.visibleRootShellProjections.map(\.id))
            }
            .store(in: &cancellables)

        try await viewModel.loadFolder(at: tempRoot, for: workspace)

        XCTAssertEqual(changeCount, 1)
        XCTAssertEqual(snapshots, [viewModel.visibleRootShellProjections.map(\.id)])
        XCTAssertEqual(viewModel.visibleRootShellProjections.map(\.fullPath), [tempRoot.path])
    }

    func testWorkspaceFolderLoadConcurrencyLimitIsBounded() {
        XCTAssertEqual(WorkspaceManagerViewModel.boundedWorkspaceRootLoadLimit(forRootCount: 0), 0)
        XCTAssertEqual(WorkspaceManagerViewModel.boundedWorkspaceRootLoadLimit(forRootCount: 1), 1)
        XCTAssertEqual(WorkspaceManagerViewModel.boundedWorkspaceRootLoadLimit(forRootCount: 2), 2)
        XCTAssertEqual(WorkspaceManagerViewModel.boundedWorkspaceRootLoadLimit(forRootCount: 4), 3)
        XCTAssertEqual(WorkspaceManagerViewModel.boundedWorkspaceRootLoadLimit(forRootCount: 12), 3)
    }

    func testWorkspaceSaveMergePreservesDiskRepoPathsWhenNoLocalRootEdit() {
        var current = WorkspaceModel(name: "Workspace", repoPaths: ["/tmp/A", "/tmp/B"])
        current.dateModified = Date(timeIntervalSince1970: 10)
        var disk = current
        disk.repoPaths = ["/tmp/B", "/tmp/A", "/tmp/C"]
        disk.dateModified = Date(timeIntervalSince1970: 20)

        let result = WorkspaceManagerViewModel.workspaceForSavePreservingDiskRepoPaths(
            current: current,
            diskWorkspace: disk,
            lastSyncedRepoPaths: ["/tmp/A", "/tmp/B"],
            modificationDate: Date(timeIntervalSince1970: 30)
        )

        XCTAssertTrue(result.preservedDiskRepoPaths)
        XCTAssertEqual(result.workspace.repoPaths, disk.repoPaths)
        XCTAssertEqual(result.workspace.dateModified, Date(timeIntervalSince1970: 30))
    }

    func testWorkspaceSaveMergeKeepsLocalRepoPathsAfterLocalRootEdit() {
        var current = WorkspaceModel(name: "Workspace", repoPaths: ["/tmp/A", "/tmp/C"])
        current.dateModified = Date(timeIntervalSince1970: 10)
        var disk = current
        disk.repoPaths = ["/tmp/A", "/tmp/B"]

        let result = WorkspaceManagerViewModel.workspaceForSavePreservingDiskRepoPaths(
            current: current,
            diskWorkspace: disk,
            lastSyncedRepoPaths: ["/tmp/A"],
            modificationDate: Date(timeIntervalSince1970: 30)
        )

        XCTAssertFalse(result.preservedDiskRepoPaths)
        XCTAssertEqual(result.workspace.repoPaths, current.repoPaths)
    }

    private func makeRoot(name: String, path: String, isSystemRoot: Bool = false) -> FolderViewModel {
        FolderViewModel(
            folder: Folder(name: name, path: path, modificationDate: Date(timeIntervalSince1970: 1)),
            rootPath: path,
            isExpanded: true,
            isSystemRoot: isSystemRoot
        )
    }
}
