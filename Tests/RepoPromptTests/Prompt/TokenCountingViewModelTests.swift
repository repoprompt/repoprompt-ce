@testable import RepoPromptApp
import XCTest

@MainActor
final class TokenCountingViewModelTests: XCTestCase {
    func testExpectedSelectionForPublishedSnapshotMatchesCompletedSnapshotAcrossSelectionModes() async {
        let activeSelection = StoredSelection(selectedPaths: ["/tmp/RepoPromptTests/Active.swift"])

        await assertPublishedSnapshotReady(
            includeFiles: false,
            providedSelection: activeSelection,
            expectedSelection: StoredSelection(),
            fileManager: WorkspaceFilesViewModel()
        )

        await assertPublishedSnapshotReady(
            includeFiles: true,
            providedSelection: activeSelection,
            expectedSelection: activeSelection,
            fileManager: WorkspaceFilesViewModel()
        )

        let fallbackFileManager = makeFallbackFileManager()
        let fallbackSelection = fallbackFileManager.snapshotSelection()
        XCTAssertFalse(fallbackSelection.selectedPaths.isEmpty)
        await assertPublishedSnapshotReady(
            includeFiles: true,
            providedSelection: nil,
            expectedSelection: fallbackSelection,
            fileManager: fallbackFileManager
        )
    }

    func testExpectedSelectionRetargetsChangedSelectionBeforeRecountCompletes() async {
        let oldSelection = StoredSelection(selectedPaths: ["/tmp/RepoPromptTests/Old.swift"])
        let newSelection = StoredSelection(selectedPaths: ["/tmp/RepoPromptTests/New.swift"])
        let fileManager = WorkspaceFilesViewModel()
        var currentSelection = oldSelection
        let tokenCounter = makeTokenCounter(
            includeFiles: true,
            fileManager: fileManager,
            getStoredSelection: { currentSelection }
        )

        let oldBlankingSelection = tokenCounter.currentExpectedSelectionForPublishedSnapshot()
        XCTAssertEqual(oldBlankingSelection, oldSelection)
        await tokenCounter.forceImmediateRecount()

        currentSelection = newSelection
        let retargetedBlankingSelection = tokenCounter.currentExpectedSelectionForPublishedSnapshot()
        XCTAssertEqual(retargetedBlankingSelection, newSelection)
        let pendingNewSnapshot = tokenCounter.latestPublishedTokenSnapshot(
            for: retargetedBlankingSelection,
            scheduleRefreshIfNeeded: false
        )
        XCTAssertTrue(pendingNewSnapshot.isStale)
        XCTAssertTrue(pendingNewSnapshot.refreshPending)

        await tokenCounter.forceImmediateRecount()

        let newSnapshot = tokenCounter.latestPublishedTokenSnapshot(
            for: retargetedBlankingSelection,
            scheduleRefreshIfNeeded: false
        )
        XCTAssertTrue(newSnapshot.isComplete)
        XCTAssertFalse(newSnapshot.isStale)
        XCTAssertFalse(newSnapshot.refreshPending)
        let oldSnapshot = tokenCounter.latestPublishedTokenSnapshot(
            for: oldBlankingSelection,
            scheduleRefreshIfNeeded: false
        )
        XCTAssertTrue(oldSnapshot.isStale)
        await tokenCounter.stopTokenCountUpdateTimer()
    }

    private func assertPublishedSnapshotReady(
        includeFiles: Bool,
        providedSelection: StoredSelection?,
        expectedSelection: StoredSelection,
        fileManager: WorkspaceFilesViewModel
    ) async {
        let tokenCounter = makeTokenCounter(
            includeFiles: includeFiles,
            providedSelection: providedSelection,
            fileManager: fileManager
        )
        let blankingSelection = tokenCounter.currentExpectedSelectionForPublishedSnapshot()
        XCTAssertEqual(blankingSelection, expectedSelection)

        await tokenCounter.forceImmediateRecount()

        let snapshot = tokenCounter.latestPublishedTokenSnapshot(
            for: blankingSelection,
            scheduleRefreshIfNeeded: false
        )
        XCTAssertTrue(snapshot.isComplete)
        XCTAssertFalse(snapshot.isStale)
        XCTAssertFalse(snapshot.refreshPending)
        await tokenCounter.stopTokenCountUpdateTimer()
    }

    private func makeTokenCounter(
        includeFiles: Bool,
        providedSelection: StoredSelection?,
        fileManager: WorkspaceFilesViewModel
    ) -> TokenCountingViewModel {
        makeTokenCounter(
            includeFiles: includeFiles,
            fileManager: fileManager,
            getStoredSelection: { providedSelection }
        )
    }

    private func makeTokenCounter(
        includeFiles: Bool,
        fileManager: WorkspaceFilesViewModel,
        getStoredSelection: @escaping @MainActor () -> StoredSelection?
    ) -> TokenCountingViewModel {
        let tokenCounter = TokenCountingViewModel()
        let gitViewModel = GitViewModel(
            fileManager: fileManager,
            gitContextRefreshIntervalNanoseconds: 0
        )
        tokenCounter.configure(
            fileManager: fileManager,
            gitViewModel: gitViewModel,
            getPromptText: { "" },
            getSelectedInstructionsText: { "" },
            getSettings: {
                TokenCountingViewModel.TokenCalculationSettings(
                    fileTreeOption: .none,
                    codeMapUsage: .none,
                    filePathDisplayOption: .relative,
                    includeFilesInClipboard: includeFiles,
                    duplicateUserInstructionsAtTop: false,
                    onlyIncludeRootsWithSelectedFiles: false,
                    codeMapsGloballyDisabled: false
                )
            },
            getCopyContext: {
                TokenCountingViewModel.CopyContextSnapshot(
                    includeFiles: includeFiles,
                    includeUserPrompt: false,
                    includeMetaPrompts: false,
                    includeFileTree: false,
                    fileTreeMode: .none,
                    codeMapUsage: .none,
                    gitInclusion: .none,
                    duplicateUserInstructionsAtTop: false
                )
            },
            getStoredSelection: getStoredSelection
        )
        tokenCounter.suspendAutomaticRecounts()
        return tokenCounter
    }

    private func makeFallbackFileManager() -> WorkspaceFilesViewModel {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TokenCountingViewModelTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = FolderViewModel(
            folder: Folder(name: "FixtureRoot", path: rootURL.path, modificationDate: Date(timeIntervalSince1970: 1000)),
            rootPath: rootURL.path,
            isExpanded: true
        )
        let file = FileViewModel(
            file: File(
                name: "Fallback.swift",
                path: rootURL.appendingPathComponent("Fallback.swift").path,
                modificationDate: Date(timeIntervalSince1970: 1000)
            ),
            rootPath: rootURL.path,
            hierarchyLevel: 1,
            rootIdentifier: root.id,
            rootFolderPath: rootURL.path,
            fileSystemService: nil,
            parentFolder: root
        )
        root.addChildrenBatch([.file(file)])

        let fileManager = WorkspaceFilesViewModel()
        fileManager.registerRootFolderForTesting(root)
        fileManager.selectFileForTesting(file)
        return fileManager
    }
}
