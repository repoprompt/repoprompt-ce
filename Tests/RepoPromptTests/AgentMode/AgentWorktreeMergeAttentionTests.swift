@testable import RepoPromptApp
import XCTest

/// Unit tests for the Item 8 worktree merge attention surfaces shared by the
/// Agent Mode blocker stack, session row badges, and workspace-root capsules.
final class AgentWorktreeMergeAttentionTests: XCTestCase {
    // MARK: - Blocker selector

    func testActiveConflictOperationPicksMostRecentNonTerminalConflictOrAwaitingCommit() {
        let stale = makeOperation(id: "old", status: .conflicted, updatedAt: epoch(0))
        let recentAwaitingCommit = makeOperation(id: "awaiting", status: .awaitingCommit, updatedAt: epoch(50))
        let recentConflict = makeOperation(id: "newConflict", status: .conflicted, updatedAt: epoch(120))
        let completed = makeOperation(id: "completed", status: .completed, updatedAt: epoch(200))

        let result = AgentWorktreeMergeBlockerSelector.activeConflictOperation(in: [
            stale, recentAwaitingCommit, recentConflict, completed
        ])

        XCTAssertEqual(result?.id, "newConflict")
    }

    func testActiveConflictOperationReturnsNilWhenOnlyTerminalOrReviewStatesArePresent() {
        let preview = makeOperation(id: "preview", status: .previewed, updatedAt: epoch(80))
        let awaitingApproval = makeOperation(id: "await", status: .awaitingApproval, updatedAt: epoch(90))
        let cancelled = makeOperation(id: "cancel", status: .cancelled, updatedAt: epoch(100))

        let result = AgentWorktreeMergeBlockerSelector.activeConflictOperation(
            in: [preview, awaitingApproval, cancelled]
        )

        XCTAssertNil(result)
    }

    func testSidebarAttentionPrefersMostRecentActiveOperationAndMapsKind() {
        let approval = makeOperation(id: "approval", status: .awaitingApproval, updatedAt: epoch(10))
        let awaitingCommit = makeOperation(id: "awaitingCommit", status: .awaitingCommit, updatedAt: epoch(50))
        let conflict = makeOperation(
            id: "conflict",
            status: .conflicted,
            updatedAt: epoch(100),
            conflictFiles: ["a.txt", "b.txt"]
        )

        let attention = AgentWorktreeMergeBlockerSelector.sidebarAttention(
            in: [approval, awaitingCommit, conflict]
        )

        XCTAssertEqual(attention?.operationID, "conflict")
        XCTAssertEqual(attention?.kind, .conflicted)
        XCTAssertEqual(attention?.conflictFileCount, 2)
        XCTAssertTrue(attention?.tooltipText.contains("2 conflict") == true)
        XCTAssertEqual(attention?.capsuleText, "MERGE → main")
    }

    func testSidebarAttentionReturnsNilWhenNoActiveOperationsExist() {
        let completed = makeOperation(id: "done", status: .completed, updatedAt: epoch(5))
        let aborted = makeOperation(id: "abort", status: .aborted, updatedAt: epoch(7))
        let cancelled = makeOperation(id: "cancel", status: .cancelled, updatedAt: epoch(9))

        XCTAssertNil(AgentWorktreeMergeBlockerSelector.sidebarAttention(
            in: [completed, aborted, cancelled]
        ))
    }

    func testSidebarAttentionMapsAwaitingApprovalAndAwaitingCommitKinds() {
        let approvalOnly = makeOperation(id: "approval", status: .awaitingApproval, updatedAt: epoch(1))
        XCTAssertEqual(
            AgentWorktreeMergeBlockerSelector.sidebarAttention(in: [approvalOnly])?.kind,
            .awaitingApproval
        )
        let awaitingCommitOnly = makeOperation(id: "commit", status: .awaitingCommit, updatedAt: epoch(1))
        XCTAssertEqual(
            AgentWorktreeMergeBlockerSelector.sidebarAttention(in: [awaitingCommitOnly])?.kind,
            .awaitingCommit
        )
    }

    // MARK: - Attention summary view-model

    func testAttentionFromSessionSummaryUsesPersistedFieldsAndKind() {
        let summary = AgentSessionWorktreeMergeSummary(
            id: "summary_op",
            status: .conflicted,
            sourceWorktreeID: "wt_source",
            sourceLabel: "feature-x",
            sourceBranch: "feature/x",
            sourcePath: "/tmp/source",
            targetWorktreeID: "wt_target",
            targetLabel: "main",
            targetBranch: "main",
            targetPath: "/tmp/target",
            repositoryID: "gitrepo",
            repoKey: "repo",
            conflictFileCount: 3,
            updatedAt: epoch(7)
        )

        let attention = AgentWorktreeMergeAttention(summary: summary)

        XCTAssertEqual(attention.operationID, "summary_op")
        XCTAssertEqual(attention.kind, .conflicted)
        XCTAssertEqual(attention.sourceLabel, "feature-x")
        XCTAssertEqual(attention.targetLabel, "main")
        XCTAssertEqual(attention.targetPath, "/tmp/target")
        XCTAssertEqual(attention.conflictFileCount, 3)
        XCTAssertEqual(attention.capsuleText, "MERGE → main")
        XCTAssertTrue(attention.tooltipText.contains("3 conflicts"))
    }

    func testAttentionFromOperationRoundTripsAllFields() {
        let operation = makeOperation(
            id: "op_round",
            status: .awaitingCommit,
            updatedAt: epoch(11),
            conflictFiles: []
        )

        let attention = AgentWorktreeMergeAttention(operation: operation)

        XCTAssertEqual(attention.operationID, "op_round")
        XCTAssertEqual(attention.kind, .awaitingCommit)
        XCTAssertEqual(attention.sourceLabel, operation.source.displayName)
        XCTAssertEqual(attention.targetLabel, operation.target.displayName)
        XCTAssertEqual(attention.targetPath, operation.target.path)
        XCTAssertEqual(attention.conflictFileCount, 0)
        XCTAssertTrue(attention.tooltipText.contains("awaiting commit"))
    }

    // MARK: - Tool result card presentation

    func testToolCardRouterRecognizesManageWorktreeMergeResultWithoutArgs() throws {
        let reply = ToolResultDTOs.ManageWorktreeReplyDTO(
            op: "status",
            merge: .init(status: "awaiting_approval", operationID: "merge_123")
        )
        let data = try JSONEncoder().encode(reply)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(ToolCardRouter.isWorktreeMergeResult(json))
        XCTAssertFalse(ToolCardRouter.isWorktreeMergeOp(nil))
    }

    func testWorktreeMergeCardPresentationMarksConflictedAsWarningWithConflictDetail() {
        let dto = ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO(
            status: "conflicted",
            operationID: "op_apply",
            source: endpointDTO(label: "feature", path: "/tmp/source", branch: "feature"),
            target: endpointDTO(label: "main", path: "/tmp/target", branch: "main"),
            conflictFiles: ["a.txt", "b.txt"]
        )

        let presentation = WorktreeMergeCardPresentationBuilder.build(dto: dto, op: "apply", toolIsError: false)

        XCTAssertEqual(presentation.title, "Merge Worktree • Apply")
        XCTAssertEqual(presentation.status, ToolCardStatus.warning)
        XCTAssertTrue(presentation.subtitle.contains("feature → main"))
        XCTAssertTrue(presentation.subtitle.contains("conflicted"))
        XCTAssertEqual(presentation.detailText, "2 conflicted files")
    }

    func testWorktreeMergeCardPresentationNilDTOFallbackMatrix() {
        let rows: [(label: String, toolIsError: Bool, status: ToolCardStatus, subtitle: String)] = [
            ("neutral fallback", false, .neutral, "manage_worktree"),
            ("tool error", true, .failure, "failed")
        ]

        for row in rows {
            let presentation = WorktreeMergeCardPresentationBuilder.build(dto: nil, toolIsError: row.toolIsError)
            XCTAssertEqual(presentation.title, "Merge Worktree", row.label)
            XCTAssertEqual(presentation.status, row.status, row.label)
            XCTAssertEqual(presentation.subtitle, row.subtitle, row.label)
        }
    }

    func testWorktreeMergeCardPresentationCompletedStatusIsSuccess() {
        let dto = ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO(
            status: "completed",
            source: endpointDTO(label: "feature", path: "/tmp/source", branch: "feature"),
            target: endpointDTO(label: "main", path: "/tmp/target", branch: "main"),
            summary: .init(commits: 3, files: 5, insertions: 80, deletions: 12),
            nextActions: ["Validate from target cwd"]
        )

        let presentation = WorktreeMergeCardPresentationBuilder.build(dto: dto, op: "apply", toolIsError: false)

        XCTAssertEqual(presentation.status, ToolCardStatus.success)
        XCTAssertTrue(presentation.subtitle.contains("3c · 5f · +80 -12"))
        XCTAssertEqual(presentation.detailText, "Validate from target cwd")
    }

    func testWorktreeMergeCardPresentationPreviewWithBlockedPreflightWarns() {
        let dto = ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO(
            status: "preview",
            source: endpointDTO(label: "feature", path: "/tmp/source", branch: "feature"),
            target: endpointDTO(label: "main", path: "/tmp/target", branch: "main"),
            preflight: .init(
                blocked: true,
                blockers: [.init(code: "source_dirty", message: "source is dirty", paths: [])],
                conflictPrediction: nil
            )
        )

        let presentation = WorktreeMergeCardPresentationBuilder.build(dto: dto, toolIsError: false)

        XCTAssertEqual(presentation.status, ToolCardStatus.warning)
        XCTAssertEqual(presentation.detailText, "source is dirty")
    }

    // MARK: - Helpers

    private func epoch(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    private func makeOperation(
        id: String,
        status: AgentSessionWorktreeMergeOperation.Status,
        updatedAt: Date,
        conflictFiles: [String] = []
    ) -> AgentSessionWorktreeMergeOperation {
        let source = GitWorktreeMergeEndpoint(
            worktreeID: "wt_source_\(id)",
            repositoryID: "gitrepo",
            repoKey: "repo",
            path: "/tmp/source_\(id)",
            name: "feature",
            branch: "feature",
            head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            isMain: false
        )
        let target = GitWorktreeMergeEndpoint(
            worktreeID: "wt_target_\(id)",
            repositoryID: "gitrepo",
            repoKey: "repo",
            path: "/tmp/target_\(id)",
            name: "main",
            branch: "main",
            head: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            isMain: true
        )
        return AgentSessionWorktreeMergeOperation(
            id: id,
            source: source,
            target: target,
            mergeBase: "cccccccccccccccccccccccccccccccccccccccc",
            sourceHead: source.head,
            targetHeadBefore: target.head,
            status: status,
            conflictFiles: conflictFiles,
            createdAt: epoch(0),
            updatedAt: updatedAt
        )
    }

    private func endpointDTO(
        label: String,
        path: String,
        branch: String?
    ) -> ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO.EndpointDTO {
        ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO.EndpointDTO(
            worktreeID: "wt_\(label)",
            repoKey: "repo",
            path: path,
            name: label,
            branch: branch,
            head: "0000000000000000000000000000000000000000",
            shortHead: "0000000",
            isMain: label == "main",
            label: label
        )
    }
}
