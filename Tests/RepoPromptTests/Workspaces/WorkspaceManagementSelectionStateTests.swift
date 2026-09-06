@testable import RepoPromptApp
import XCTest

final class WorkspaceManagementSelectionStateTests: XCTestCase {
    func testSelectAllIncludesEntireInventoryOutsideCurrentFilter() {
        var state = WorkspaceManagementSelectionState()
        let first = UUID()
        let second = UUID()
        let outsideFilter = UUID()

        state.begin()
        state.selectAllResults([first, second, outsideFilter])

        XCTAssertEqual(state.selectedWorkspaceIDs, [first, second, outsideFilter])
        XCTAssertTrue(state.selectedWorkspaceIDs.contains(outsideFilter))
        XCTAssertEqual(state.selectedCount(in: [first]), 1)
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

    func testAnyWorkspaceCanBeSelected() {
        var state = WorkspaceManagementSelectionState()
        let protected = UUID()

        state.begin()
        state.toggle(protected)

        XCTAssertEqual(state.selectedWorkspaceIDs, [protected])
    }

    func testClearAndCancelHaveDistinctSelectionModeSemantics() {
        var state = WorkspaceManagementSelectionState()
        let workspaceID = UUID()

        state.begin()
        state.toggle(workspaceID)
        state.clear()
        XCTAssertTrue(state.isSelecting)
        XCTAssertTrue(state.selectedWorkspaceIDs.isEmpty)

        state.toggle(workspaceID)
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

    func testSelectAllHasNoArbitraryCatalogSizeLimit() {
        var state = WorkspaceManagementSelectionState()
        let workspaceIDs = (0 ..< 1200).map { _ in UUID() }
        state.begin()
        XCTAssertEqual(state.selectAllResults(workspaceIDs), .changed)
        XCTAssertEqual(state.selectedWorkspaceIDs, Set(workspaceIDs))
    }
}
