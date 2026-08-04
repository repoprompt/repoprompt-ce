@testable import RepoPromptApp
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

    func testSelectionChangeSupersedesInFlightStatusProjection() async {
        let fixture = makeFixture()
        let gitViewModel = makeGitViewModel(fixture: fixture)
        fixture.fileManager.selectPath(fixture.targetA.file.fullPath, kind: nil)

        await publishStatus(
            changedFiles: [fixture.targetA],
            generation: 1,
            fixture: fixture,
            gitViewModel: gitViewModel
        )
        let staleRebuildGeneration = gitViewModel.test_resolvedStateGeneration

        fixture.fileManager.deselectPath(fixture.targetA.file.fullPath, kind: nil)
        XCTAssertGreaterThan(gitViewModel.test_resolvedStateGeneration, staleRebuildGeneration)
        XCTAssertEqual(gitViewModel.test_trackedSelectedChangedAbsolutePaths, [])

        gitViewModel.test_publishSelectedChangedProjection(
            changedAbsolutePaths: [fixture.targetA.file.fullPath],
            selectedAbsolutePaths: [fixture.targetA.file.fullPath],
            rebuildGeneration: staleRebuildGeneration
        )

        XCTAssertEqual(gitViewModel.test_trackedSelectedChangedAbsolutePaths, [])
        XCTAssertEqual(selectedPaths(in: fixture.fileManager), [])
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
