import Foundation
@testable import RepoPromptApp
import XCTest

final class VCSBranchSortOrderTests: XCTestCase {
    func testRecentSortPinsCurrentBranchThenUsesMostRecentCommitDate() {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let branches = [
            VCSBranch(name: "zeta", isCurrent: false, lastCommitDate: newer),
            VCSBranch(name: "current", isCurrent: true, lastCommitDate: older),
            VCSBranch(name: "alpha", isCurrent: false, lastCommitDate: older),
            VCSBranch(name: "undated", isCurrent: false, lastCommitDate: nil)
        ]

        XCTAssertEqual(
            branches.sortedForDisplay(by: .recent).map(\.name),
            ["current", "zeta", "alpha", "undated"]
        )
    }

    func testRecentSortFallsBackToCaseInsensitiveNameForEqualOrMissingDates() {
        let date = Date(timeIntervalSince1970: 100)
        let branches = [
            VCSBranch(name: "beta", isCurrent: false, lastCommitDate: date),
            VCSBranch(name: "Alpha", isCurrent: false, lastCommitDate: date),
            VCSBranch(name: "delta", isCurrent: false, lastCommitDate: nil),
            VCSBranch(name: "Charlie", isCurrent: false, lastCommitDate: nil)
        ]

        XCTAssertEqual(
            branches.sortedForDisplay(by: .recent).map(\.name),
            ["Alpha", "beta", "Charlie", "delta"]
        )
    }

    func testNameSortUsesCaseInsensitiveBranchNameWithoutPinningCurrentBranch() {
        let branches = [
            VCSBranch(name: "zeta", isCurrent: false),
            VCSBranch(name: "current", isCurrent: true),
            VCSBranch(name: "Alpha", isCurrent: false)
        ]

        XCTAssertEqual(
            branches.sortedForDisplay(by: .name).map(\.name),
            ["Alpha", "current", "zeta"]
        )
    }
}
