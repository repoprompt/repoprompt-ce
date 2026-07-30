@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentGitBranchSwitchRelevanceTests: XCTestCase {
    func testProviderNoteIsOmittedWhenBoundSessionSwitchesLogicalBaseRootOnly() {
        let binding = makeBinding(
            logicalRootPath: "/repo/base",
            worktreeRootPath: "/repo/.worktrees/feature"
        )

        let relevant = AgentModeViewModel.branchSwitchIsProviderContextRelevant(
            worktreeBindings: [binding],
            switchedCheckoutCandidatePaths: ["/repo/base"],
            isPrimaryRoot: true,
            didUpdateMatchingWorktreeBinding: false
        )

        XCTAssertFalse(relevant)
    }

    func testProviderNoteIsAppendedWhenBoundSessionSwitchesExecutionWorktree() {
        let binding = makeBinding(
            logicalRootPath: "/repo/base",
            worktreeRootPath: "/repo/.worktrees/feature"
        )

        let relevant = AgentModeViewModel.branchSwitchIsProviderContextRelevant(
            worktreeBindings: [binding],
            switchedCheckoutCandidatePaths: ["/repo/.worktrees/feature"],
            isPrimaryRoot: false,
            didUpdateMatchingWorktreeBinding: true
        )

        XCTAssertTrue(relevant)
    }

    func testUnboundSessionOnlyTreatsPrimaryVisibleRootAsRelevant() {
        XCTAssertTrue(AgentModeViewModel.branchSwitchIsProviderContextRelevant(
            worktreeBindings: [],
            switchedCheckoutCandidatePaths: ["/repo/base"],
            isPrimaryRoot: true,
            didUpdateMatchingWorktreeBinding: false
        ))
        XCTAssertFalse(AgentModeViewModel.branchSwitchIsProviderContextRelevant(
            worktreeBindings: [],
            switchedCheckoutCandidatePaths: ["/repo/.worktrees/other"],
            isPrimaryRoot: false,
            didUpdateMatchingWorktreeBinding: false
        ))
    }

    func testBoundSessionTreatsUnboundPrimaryRootAsRelevantContext() {
        let binding = makeBinding(
            logicalRootPath: "/repo/base",
            worktreeRootPath: "/repo/.worktrees/feature"
        )

        let relevant = AgentModeViewModel.branchSwitchIsProviderContextRelevant(
            worktreeBindings: [binding],
            switchedCheckoutCandidatePaths: ["/other-visible-root"],
            isPrimaryRoot: true,
            didUpdateMatchingWorktreeBinding: false
        )

        XCTAssertTrue(relevant)
    }

    func testInAppSwitchUpdatesMatchingWorktreeBindingMetadata() {
        let matching = makeBinding(
            logicalRootPath: "/repo/base",
            worktreeRootPath: "/repo/.worktrees/feature"
        )
        let other = makeBinding(
            logicalRootPath: "/repo/base",
            worktreeRootPath: "/repo/.worktrees/other",
            worktreeID: "other-worktree"
        )

        let update = AgentModeViewModel.updatedWorktreeBindingsAfterBranchSwitch(
            [matching, other],
            switchedCheckoutCandidatePaths: ["/repo/.worktrees/feature"],
            branch: "feature/new",
            head: "new-head"
        )

        XCTAssertTrue(update.didUpdate)
        XCTAssertEqual(update.bindings[0].branch, "feature/new")
        XCTAssertEqual(update.bindings[0].head, "new-head")
        XCTAssertEqual(update.bindings[1], other)
    }

    func testInAppSwitchDoesNotUpdateBindingWhenOnlyLogicalBaseRootMatches() {
        let binding = makeBinding(
            logicalRootPath: "/repo/base",
            worktreeRootPath: "/repo/.worktrees/feature"
        )

        let update = AgentModeViewModel.updatedWorktreeBindingsAfterBranchSwitch(
            [binding],
            switchedCheckoutCandidatePaths: ["/repo/base"],
            branch: "main",
            head: "base-head"
        )

        XCTAssertFalse(update.didUpdate)
        XCTAssertEqual(update.bindings, [binding])
    }

    private func makeBinding(
        logicalRootPath: String,
        worktreeRootPath: String,
        worktreeID: String = "worktree-id"
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding",
            repositoryID: "repo-id",
            repoKey: "repo",
            logicalRootPath: logicalRootPath,
            logicalRootName: "base",
            worktreeID: worktreeID,
            worktreeRootPath: worktreeRootPath,
            worktreeName: "feature",
            branch: "feature/old",
            head: "old-head",
            visualLabel: "feature",
            visualColorHex: nil,
            boundAt: Date(timeIntervalSinceReferenceDate: 0),
            source: "test"
        )
    }
}
