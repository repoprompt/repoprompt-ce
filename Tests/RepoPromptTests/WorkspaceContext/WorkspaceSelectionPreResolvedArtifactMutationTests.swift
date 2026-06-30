@testable import RepoPrompt
import XCTest

final class WorkspaceSelectionPreResolvedArtifactMutationTests: XCTestCase {
    func testAddPromotesExactIdentityAndPreservesOrdinaryState() {
        let artifact = "/workspace/_git_data/repos/repo/snapshot/MAP.txt"
        let source = "/workspace/Sources/App.swift"
        let service = WorkspaceSelectionMutationService(store: WorkspaceFileContextStore())
        let base = StoredSelection(
            selectedPaths: [source],

            slices: [
                source: [LineRange(start: 1, end: 2)],
                artifact: [LineRange(start: 1, end: 1)]
            ],
            codemapAutoEnabled: false
        )

        let result = service.mutatePreResolvedFullFilePaths(
            base: base,
            absolutePaths: [artifact, artifact],
            mode: .add
        )

        XCTAssertEqual(result.selectedPaths, [source, artifact])
        XCTAssertEqual(result.slices, [source: [LineRange(start: 1, end: 2)]])
        XCTAssertFalse(result.codemapAutoEnabled)
    }

    func testRemoveDeletesExactIdentityFromEverySelectionShape() {
        let artifact = "/workspace/_git_data/repos/repo/snapshot/diff/all.patch"
        let source = "/workspace/Sources/App.swift"
        let service = WorkspaceSelectionMutationService(store: WorkspaceFileContextStore())
        let base = StoredSelection(
            selectedPaths: [source, artifact],

            slices: [
                source: [LineRange(start: 1, end: 2)],
                artifact: [LineRange(start: 1, end: 1)]
            ],
            codemapAutoEnabled: true
        )

        let result = service.mutatePreResolvedFullFilePaths(
            base: base,
            absolutePaths: [artifact],
            mode: .remove
        )

        XCTAssertEqual(result.selectedPaths, [source])
        XCTAssertEqual(result.slices, [source: [LineRange(start: 1, end: 2)]])
        XCTAssertTrue(result.codemapAutoEnabled)
    }

    func testArtifactSignalMakesMixedFullFileAndSliceSetDestructive() async {
        let service = WorkspaceSelectionMutationService(store: WorkspaceFileContextStore())
        let existing = StoredSelection(
            selectedPaths: ["/workspace/existing.swift"],
            codemapAutoEnabled: false
        )

        let result = await service.buildManageSelectionSet(
            paths: [],
            slices: [],
            mode: "full",
            existing: existing,
            hasFullFileArtifactInputs: true
        )

        XCTAssertTrue(result.selection.selectedPaths.isEmpty)
        XCTAssertFalse(result.selection.codemapAutoEnabled)
    }
}
