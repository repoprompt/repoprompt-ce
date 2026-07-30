@testable import RepoPromptApp
import XCTest

final class BranchSwitchBranchListPresentationTests: XCTestCase {
    func testNameSortGroupsCurrentThenCheckedOutElsewhereThenAvailable() {
        let branches = [
            VCSBranch(name: "aaa-available", isCurrent: false),
            VCSBranch(name: "mmm-current", isCurrent: true),
            VCSBranch(name: "zzz-available", isCurrent: false),
            occupiedBranch(name: "bbb-occupied"),
            occupiedBranch(name: "ccc-occupied")
        ]

        let presentation = BranchSwitchBranchListPresentation(branches: branches, sortOrder: .name)

        XCTAssertEqual(presentation.sections.map(\.kind), [.currentCheckout, .checkedOutElsewhere, .available])
        XCTAssertEqual(presentation.branches.map(\.name), [
            "mmm-current",
            "bbb-occupied",
            "ccc-occupied",
            "aaa-available",
            "zzz-available"
        ])
    }

    func testNameSortAlphabetizesWithinCheckedOutAndAvailableGroups() {
        let branches = [
            occupiedBranch(name: "Zoo/occupied"),
            VCSBranch(name: "beta-available", isCurrent: false),
            occupiedBranch(name: "alpha/occupied"),
            VCSBranch(name: "Alpha-available", isCurrent: false)
        ]

        let presentation = BranchSwitchBranchListPresentation(branches: branches, sortOrder: .name)

        XCTAssertEqual(branchNames(in: .checkedOutElsewhere, presentation), ["alpha/occupied", "Zoo/occupied"])
        XCTAssertEqual(branchNames(in: .available, presentation), ["Alpha-available", "beta-available"])
    }

    func testRecentSortKeepsSafetyGroupsThenUsesRecentOrderingWithinGroups() {
        let oldest = Date(timeIntervalSince1970: 100)
        let middle = Date(timeIntervalSince1970: 200)
        let newest = Date(timeIntervalSince1970: 300)
        let branches = [
            VCSBranch(name: "available-old", isCurrent: false, lastCommitDate: oldest),
            occupiedBranch(name: "occupied-middle", lastCommitDate: middle),
            VCSBranch(name: "current", isCurrent: true, lastCommitDate: oldest),
            occupiedBranch(name: "occupied-new", lastCommitDate: newest),
            VCSBranch(name: "available-new", isCurrent: false, lastCommitDate: newest)
        ]

        let presentation = BranchSwitchBranchListPresentation(branches: branches, sortOrder: .recent)

        XCTAssertEqual(presentation.sections.map(\.kind), [.currentCheckout, .checkedOutElsewhere, .available])
        XCTAssertEqual(presentation.branches.map(\.name), [
            "current",
            "occupied-new",
            "occupied-middle",
            "available-new",
            "available-old"
        ])
    }

    func testOccupiedBranchMetadataIsPreservedThroughPresentation() throws {
        let occupancy = VCSBranchWorktreeOccupancy(
            worktreePath: "/repo/.worktrees/feature-one",
            worktreeName: "feature-one",
            worktreeID: "wt-feature-one"
        )
        let branches = [
            VCSBranch(name: "feature/one", isCurrent: false, checkedOutWorktree: occupancy),
            VCSBranch(name: "main", isCurrent: true)
        ]

        let presentation = BranchSwitchBranchListPresentation(branches: branches, sortOrder: .name)
        let occupied = try XCTUnwrap(presentation.branches.first { $0.name == "feature/one" })

        XCTAssertEqual(occupied.checkedOutWorktree, occupancy)
        XCTAssertTrue(occupied.isCheckedOutInAnotherWorktree)
        XCTAssertEqual(occupied.checkedOutWorktreeLabel, "feature-one")
    }

    private func branchNames(
        in kind: BranchSwitchBranchListPresentation.Section.Kind,
        _ presentation: BranchSwitchBranchListPresentation
    ) -> [String] {
        presentation.sections.first { $0.kind == kind }?.branches.map(\.name) ?? []
    }

    private func occupiedBranch(name: String, lastCommitDate: Date? = nil) -> VCSBranch {
        VCSBranch(
            name: name,
            isCurrent: false,
            lastCommitDate: lastCommitDate,
            checkedOutWorktree: VCSBranchWorktreeOccupancy(
                worktreePath: "/repo/.worktrees/\(name)",
                worktreeName: name,
                worktreeID: "wt-\(name)"
            )
        )
    }
}
