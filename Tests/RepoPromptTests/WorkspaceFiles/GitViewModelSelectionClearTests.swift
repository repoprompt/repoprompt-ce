@testable import RepoPromptApp
import RepoPromptFileSystem
import RepoPromptVCS
import XCTest

@MainActor
final class GitViewModelSelectionClearTests: XCTestCase {
    func testClearSelectedChangedFilesPreservesSelectedFileThatBecameClean() async {
        let fixture = makeFixture()
        let gitViewModel = makeGitViewModel(fixture: fixture)
        fixture.fileManager.selectPath(fixture.targetA.file.fullPath, kind: nil)
        fixture.fileManager.selectPath(fixture.targetB.file.fullPath, kind: nil)
        fixture.fileManager.selectPath(fixture.unrelated.file.fullPath, kind: nil)

        await publishStatus(
            changedFiles: [fixture.targetA],
            generation: 1,
            fixture: fixture,
            gitViewModel: gitViewModel
        )
        await publishStatus(
            changedFiles: [fixture.targetB],
            generation: 2,
            fixture: fixture,
            gitViewModel: gitViewModel
        )

        await gitViewModel.clearSelectedChangedFilesFromFileManager()

        XCTAssertEqual(
            selectedPaths(in: fixture.fileManager),
            [fixture.targetA.file.fullPath, fixture.unrelated.file.fullPath]
        )
    }

    func testEmptyGitStatusClearsTrackedSelectedChangedPaths() async {
        let fixture = makeFixture()
        let gitViewModel = makeGitViewModel(fixture: fixture)
        fixture.fileManager.selectPath(fixture.targetA.file.fullPath, kind: nil)

        await publishStatus(
            changedFiles: [fixture.targetA],
            generation: 1,
            fixture: fixture,
            gitViewModel: gitViewModel
        )
        await publishStatus(
            changedFiles: [],
            generation: 2,
            fixture: fixture,
            gitViewModel: gitViewModel
        )

        XCTAssertEqual(gitViewModel.test_trackedSelectedChangedAbsolutePaths, [])
        XCTAssertFalse(gitViewModel.hasTrackedSelectedChangedFiles)
    }

    func testHiddenPopoverCanonicalSelectionEmissionReconcilesTrackedChangedPaths() async {
        let fixture = makeFixture()
        let gitViewModel = makeGitViewModel(fixture: fixture)
        XCTAssertFalse(gitViewModel.isPopoverVisible)

        fixture.fileManager.selectPath(fixture.targetB.file.fullPath, kind: nil)
        await publishStatus(
            changedFiles: [fixture.targetB],
            generation: 1,
            fixture: fixture,
            gitViewModel: gitViewModel
        )
        XCTAssertEqual(
            gitViewModel.test_trackedSelectedChangedAbsolutePaths,
            [fixture.targetB.file.fullPath]
        )
        XCTAssertTrue(gitViewModel.hasTrackedSelectedChangedFiles)

        fixture.fileManager.deselectPath(fixture.targetB.file.fullPath, kind: nil)
        XCTAssertEqual(gitViewModel.test_trackedSelectedChangedAbsolutePaths, [])
        XCTAssertFalse(gitViewModel.hasTrackedSelectedChangedFiles)

        fixture.fileManager.selectPath(fixture.targetB.file.fullPath, kind: nil)
        XCTAssertEqual(
            gitViewModel.test_trackedSelectedChangedAbsolutePaths,
            [fixture.targetB.file.fullPath]
        )
        XCTAssertTrue(gitViewModel.hasTrackedSelectedChangedFiles)
    }

    private func makeGitViewModel(
        fixture: (
            fileManager: WorkspaceFilesViewModel,
            root: FolderViewModel,
            targetA: FixtureFile,
            targetB: FixtureFile,
            unrelated: FixtureFile
        )
    ) -> GitViewModel {
        GitViewModel(
            fileManager: fixture.fileManager,
            gitContextRefreshIntervalNanoseconds: 0
        )
    }

    private func publishStatus(
        changedFiles: [FixtureFile],
        generation: Int,
        fixture: (
            fileManager: WorkspaceFilesViewModel,
            root: FolderViewModel,
            targetA: FixtureFile,
            targetB: FixtureFile,
            unrelated: FixtureFile
        ),
        gitViewModel: GitViewModel
    ) async {
        let snapshot = GitStatusActor.GitStatusSnapshot(
            rootPath: "",
            gitRootPath: (fixture.targetA.file.fullPath as NSString).deletingLastPathComponent,
            isGitRepo: true,
            backendKind: nil,
            unstagedFiles: changedFiles.map {
                VCSUncommittedFile(path: $0.relativePath, status: "M")
            },
            currentBranch: "main",
            availableBranches: [],
            availableRemoteBranches: [],
            availableTags: [],
            gitWorktreeContext: nil,
            totalAdditions: 0,
            totalDeletions: 0,
            commitDelta: nil,
            errorMessage: nil,
            trigger: .explicitRefresh,
            generation: generation
        )
        await gitViewModel.test_applyStatusSnapshot(snapshot)
    }

    private func selectedPaths(in fileManager: WorkspaceFilesViewModel) -> Set<String> {
        Set(fileManager.selectedFiles.map(\.fullPath))
    }

    private func makeFixture() -> (
        fileManager: WorkspaceFilesViewModel,
        root: FolderViewModel,
        targetA: FixtureFile,
        targetB: FixtureFile,
        unrelated: FixtureFile
    ) {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GitViewModelSelectionClearTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let date = Date(timeIntervalSince1970: 1000)
        let root = FolderViewModel(
            folder: Folder(name: "FixtureRoot", path: rootURL.path, modificationDate: date),
            rootPath: rootURL.path,
            isExpanded: true
        )

        let targetA = makeFile(name: "TargetA.swift", rootURL: rootURL, root: root, date: date)
        let targetB = makeFile(name: "TargetB.swift", rootURL: rootURL, root: root, date: date)
        let unrelated = makeFile(name: "Notes.md", rootURL: rootURL, root: root, date: date)
        root.addChildrenBatch([.file(targetA.file), .file(targetB.file), .file(unrelated.file)])

        let fileManager = WorkspaceFilesViewModel()
        fileManager.registerRootFolderForTesting(root)
        for file in [targetA.file, targetB.file, unrelated.file] {
            fileManager.selectFileForTesting(file)
            fileManager.deselectPath(file.fullPath, kind: nil)
        }
        return (fileManager, root, targetA, targetB, unrelated)
    }

    private func makeFile(
        name: String,
        rootURL: URL,
        root: FolderViewModel,
        date: Date
    ) -> FixtureFile {
        let file = FileViewModel(
            file: File(name: name, path: rootURL.appendingPathComponent(name).path, modificationDate: date),
            rootPath: rootURL.path,
            hierarchyLevel: 1,
            rootIdentifier: root.id,
            rootFolderPath: rootURL.path,
            fileSystemService: nil,
            parentFolder: root
        )
        return FixtureFile(file: file, relativePath: name)
    }

    private struct FixtureFile {
        let file: FileViewModel
        let relativePath: String
    }
}

@MainActor
final class GitViewModelPollingBackoffTests: XCTestCase {
    private let base: UInt64 = 2_500_000_000

    func testUnchangedResultsBackOffToBoundAndChangeRestoresBase() async throws {
        let model = GitViewModel()
        let root = makeRoot("one")
        model.updateRootFolders([root])
        let detection = GitStatusActor.RepoDetection(
            rootPath: root.fullPath, isGitRepo: false, backendKind: nil, gitWorktreeContext: nil
        )
        for expected in [base, 5_000_000_000, 10_000_000_000, 20_000_000_000, 30_000_000_000, 30_000_000_000] {
            let finish = try XCTUnwrap(model.test_beginPeriodicGitContextRefresh())
            finish([detection], true)
            XCTAssertEqual(model.test_gitContextRefreshDelayNanoseconds, expected)
        }
        let finish = try XCTUnwrap(model.test_beginPeriodicGitContextRefresh())
        finish([.init(rootPath: root.fullPath, isGitRepo: true, backendKind: nil, gitWorktreeContext: nil)], true)
        XCTAssertEqual(model.test_gitContextRefreshDelayNanoseconds, base)
        await model.shutdownForWindowClose()
    }

    func testRootChangeAndExplicitActivityResetWithoutOldCompletionUndoingIt() async throws {
        let model = GitViewModel()
        let first = makeRoot("one")
        let second = makeRoot("two")
        model.updateRootFolders([first])
        for _ in 0 ..< 5 {
            let finish = try XCTUnwrap(model.test_beginPeriodicGitContextRefresh())
            finish([], true)
        }
        XCTAssertEqual(model.test_gitContextRefreshDelayNanoseconds, 30_000_000_000)
        let oldFinish = try XCTUnwrap(model.test_beginPeriodicGitContextRefresh())
        model.updateRootFolders([second])
        XCTAssertEqual(model.test_gitContextRefreshDelayNanoseconds, base)
        oldFinish([], true)
        XCTAssertEqual(model.test_gitContextRefreshDelayNanoseconds, base)

        let pending = try XCTUnwrap(model.test_beginPeriodicGitContextRefresh())
        model.isPopoverVisible = true
        pending([], true)
        XCTAssertEqual(model.test_gitContextRefreshDelayNanoseconds, base)
        model.isPopoverVisible = false
        let unchanged = try XCTUnwrap(model.test_beginPeriodicGitContextRefresh())
        unchanged([], true)
        XCTAssertEqual(model.test_gitContextRefreshDelayNanoseconds, base * 2)
        // This resets even with no selected repository; no Git operation is required.
        await model.fetchUnstagedFiles(trigger: .explicitRefresh)
        XCTAssertEqual(model.test_gitContextRefreshDelayNanoseconds, base)
        await model.shutdownForWindowClose()
    }

    func testExplicitRefreshFencesOldUnchangedCompletionWithSameRoots() async throws {
        let model = GitViewModel()
        model.updateRootFolders([makeRoot("one")])
        let first = try XCTUnwrap(model.test_beginPeriodicGitContextRefresh())
        first([], true)
        XCTAssertEqual(model.test_gitContextRefreshDelayNanoseconds, base * 2)
        let pending = try XCTUnwrap(model.test_beginPeriodicGitContextRefresh())
        await model.fetchUnstagedFiles(trigger: .explicitRefresh)
        XCTAssertFalse(model.isPopoverVisible)
        pending([], true)
        XCTAssertEqual(model.test_gitContextRefreshDelayNanoseconds, base)
        await model.shutdownForWindowClose()
    }

    func testUnchangedRefreshWhilePopoverIsVisibleKeepsBaseInterval() async throws {
        let model = GitViewModel()
        model.updateRootFolders([makeRoot("one")])
        model.isPopoverVisible = true
        let finish = try XCTUnwrap(model.test_beginPeriodicGitContextRefresh())
        finish([], true)
        XCTAssertEqual(model.test_gitContextRefreshDelayNanoseconds, base)
        await model.shutdownForWindowClose()
    }

    func testCancelledRefreshDoesNotAdvanceDelayAndWindowCloseJoinsLoop() async throws {
        let model = GitViewModel()
        model.updateRootFolders([makeRoot("one")])
        let finish = try XCTUnwrap(model.test_beginPeriodicGitContextRefresh())
        XCTAssertNil(model.test_beginPeriodicGitContextRefresh(), "Refreshes must not overlap")
        finish([], false)
        XCTAssertEqual(model.test_gitContextRefreshDelayNanoseconds, base)
        XCTAssertTrue(model.test_hasGitContextRefreshTask)
        await model.shutdownForWindowClose()
        XCTAssertFalse(model.test_hasGitContextRefreshTask)
        XCTAssertEqual(model.test_pendingWindowCloseTaskCount, 0)
    }

    private func makeRoot(_ name: String) -> FolderViewModel {
        // Model-only roots: no scratch directories or Git repositories are created.
        let path = "/nonexistent/item4-polling/" + name
        return FolderViewModel(
            folder: Folder(name: name, path: path, modificationDate: .distantPast),
            rootPath: path,
            isExpanded: true
        )
    }
}
