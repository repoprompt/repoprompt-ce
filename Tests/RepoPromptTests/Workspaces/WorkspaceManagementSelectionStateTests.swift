@testable import RepoPromptApp
import XCTest

final class WorkspaceManagementSelectionStateTests: XCTestCase {
    func testSelectAllResultsScopesToCurrentFilteredEligibleSet() {
        var state = WorkspaceManagementSelectionState()
        let first = UUID()
        let second = UUID()
        let outsideFilter = UUID()

        state.begin()
        state.selectAllResults([first, second])

        XCTAssertEqual(state.selectedWorkspaceIDs, [first, second])
        XCTAssertFalse(state.selectedWorkspaceIDs.contains(outsideFilter))
        XCTAssertEqual(state.selectedCount(in: [first, second, outsideFilter]), 2)
    }

    func testFilterChangePreservesSelectionAndNextSelectAllAddsNewResults() {
        var state = WorkspaceManagementSelectionState()
        let firstFilter = UUID()
        let secondFilter = UUID()

        state.begin()
        state.selectAllResults([firstFilter])
        XCTAssertEqual(state.selectedCount(in: [secondFilter]), 0)

        state.selectAllResults([secondFilter])
        XCTAssertEqual(state.selectedWorkspaceIDs, [firstFilter, secondFilter])
        XCTAssertEqual(state.selectedCount(in: [secondFilter]), 1)
    }

    func testProtectedWorkspaceCannotBeSelected() {
        var state = WorkspaceManagementSelectionState()
        let protected = UUID()

        state.begin()
        state.toggle(protected, isDeletable: false)

        XCTAssertTrue(state.selectedWorkspaceIDs.isEmpty)
    }

    func testClearAndCancelHaveDistinctSelectionModeSemantics() {
        var state = WorkspaceManagementSelectionState()
        let workspaceID = UUID()

        state.begin()
        state.toggle(workspaceID, isDeletable: true)
        state.clear()
        XCTAssertTrue(state.isSelecting)
        XCTAssertTrue(state.selectedWorkspaceIDs.isEmpty)

        state.toggle(workspaceID, isDeletable: true)
        state.cancel()
        XCTAssertFalse(state.isSelecting)
        XCTAssertTrue(state.selectedWorkspaceIDs.isEmpty)
    }

    func testUnavailableRecordsAreRemovedBeforeOneApprovedBatchIsBuilt() {
        var state = WorkspaceManagementSelectionState()
        let retained = UUID()
        let disappeared = UUID()

        state.begin()
        state.selectAllResults([retained, disappeared])
        state.removeUnavailableWorkspaceIDs([retained])

        XCTAssertEqual(state.selectedWorkspaceIDs, [retained])
    }

    func testSelectAllRejectsOversizedResultWithoutPartialSelection() {
        var state = WorkspaceManagementSelectionState()
        let workspaceIDs = (0 ... WorkspaceBulkDeletePolicy.maximumWorkspaceCount).map { _ in UUID() }

        state.begin()
        let result = state.selectAllResults(workspaceIDs)

        XCTAssertEqual(
            result,
            .limitExceeded(
                maximum: WorkspaceBulkDeletePolicy.maximumWorkspaceCount,
                attemptedCount: WorkspaceBulkDeletePolicy.maximumWorkspaceCount + 1
            )
        )
        XCTAssertTrue(state.selectedWorkspaceIDs.isEmpty)
    }
}
