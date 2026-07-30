import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentExecutionWorktreeSelectionTests: XCTestCase {
    func testDedupePrefersNonPrunableForDuplicateWorktreeID() {
        let prunable = makeSelection(worktreeID: "wt-1", path: "/repo/wt-prunable", isPrunable: true)
        let available = makeSelection(worktreeID: "wt-1", path: "/repo/wt-available", isPrunable: false)

        let deduped = AgentModeViewModel.dedupedExecutionWorktreeSelections([prunable, available])

        XCTAssertEqual(deduped, [available])
    }

    func testDedupeUsesNormalizedPathAsSecondGuard() {
        let first = makeSelection(worktreeID: "wt-a", path: "/repo/../repo/worktree", name: nil, branch: nil, head: nil)
        let second = makeSelection(worktreeID: "wt-b", path: "/repo/worktree", branch: "feature/path")

        let deduped = AgentModeViewModel.dedupedExecutionWorktreeSelections([first, second])

        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.first?.branch, "feature/path")
    }

    func testVisuallySimilarDifferentWorktreesRemainDistinct() {
        let first = makeSelection(worktreeID: "wt-login", path: "/tmp/a/repoprompt-ce", name: "repoprompt-ce", branch: "feature/login")
        let second = makeSelection(worktreeID: "wt-billing", path: "/tmp/b/repoprompt-ce", name: "repoprompt-ce", branch: "feature/billing")

        let deduped = AgentModeViewModel.dedupedExecutionWorktreeSelections([first, second])

        XCTAssertEqual(Set(deduped.map(\.worktreeID)), Set(["wt-login", "wt-billing"]))
        XCTAssertEqual(Set(deduped.map(\.presentationID)).count, 2)
    }

    private func makeSelection(
        repositoryID: String = "repo-id",
        repoKey: String = "repo-key",
        worktreeID: String,
        path: String,
        name: String? = "repo",
        branch: String? = "main",
        head: String? = "1234567890abcdef",
        isDetached: Bool = false,
        label: String = "repo",
        colorHex: String? = nil,
        isLocked: Bool = false,
        lockReason: String? = nil,
        isPrunable: Bool = false,
        prunableReason: String? = nil
    ) -> AgentModeViewModel.AgentExecutionWorktreeSelection {
        AgentModeViewModel.AgentExecutionWorktreeSelection(
            repositoryID: repositoryID,
            repoKey: repoKey,
            worktreeID: worktreeID,
            path: path,
            name: name,
            branch: branch,
            head: head,
            isDetached: isDetached,
            label: label,
            colorHex: colorHex,
            isLocked: isLocked,
            lockReason: lockReason,
            isPrunable: isPrunable,
            prunableReason: prunableReason
        )
    }
}
