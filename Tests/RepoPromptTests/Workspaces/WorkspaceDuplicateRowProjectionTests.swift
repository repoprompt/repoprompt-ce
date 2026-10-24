import Foundation
@testable import RepoPromptApp
import XCTest

final class WorkspaceDuplicateRowProjectionTests: XCTestCase {
    func testDuplicateWorkspaceRowsUseOccurrenceIdentityForRepeatedIDsAndShrinkingSnapshots() {
        let duplicateWorkspaceID = UUID()
        let fullSummary = makeSummary(
            duplicateWorkspaceIDs: [duplicateWorkspaceID, duplicateWorkspaceID],
            duplicateWorkspaceNames: ["Recovered first", "Recovered second"],
            windowIDsByWorkspaceID: [duplicateWorkspaceID: [11]]
        )

        let fullRows = fullSummary.duplicateWorkspaceRows
        XCTAssertEqual(fullRows.map(\.id), [0, 1])
        XCTAssertEqual(fullRows.map(\.workspaceID), [duplicateWorkspaceID, duplicateWorkspaceID])
        XCTAssertEqual(fullRows.map(\.name), ["Recovered first", "Recovered second"])
        XCTAssertEqual(fullRows.map(\.windowIDs), [[11], [11]])
        XCTAssertEqual(Set(fullRows.map(\.id)).count, fullRows.count)

        let shrunkSummary = makeSummary(
            duplicateWorkspaceIDs: [duplicateWorkspaceID],
            duplicateWorkspaceNames: ["Recovered first"],
            windowIDsByWorkspaceID: [duplicateWorkspaceID: [11]]
        )

        let shrunkRows = shrunkSummary.duplicateWorkspaceRows
        XCTAssertEqual(shrunkRows, Array(fullRows.prefix(1)))
        XCTAssertEqual(Set(shrunkRows.map(\.id)).count, shrunkRows.count)
    }

    private func makeSummary(
        duplicateWorkspaceIDs: [UUID],
        duplicateWorkspaceNames: [String],
        windowIDsByWorkspaceID: [UUID: [Int]]
    ) -> WorkspaceDuplicateGroupSummary {
        WorkspaceDuplicateGroupSummary(
            id: "shared-workspace",
            normalizedRepoPaths: ["/tmp/shared-workspace"],
            canonicalWorkspaceID: UUID(),
            canonicalWorkspaceName: "Canonical",
            duplicateWorkspaceIDs: duplicateWorkspaceIDs,
            duplicateWorkspaceNames: duplicateWorkspaceNames,
            windowIDsByWorkspaceID: windowIDsByWorkspaceID
        )
    }
}
