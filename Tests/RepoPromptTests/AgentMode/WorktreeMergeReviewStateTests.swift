@testable import RepoPromptApp
import XCTest

final class WorktreeMergeReviewStateTests: XCTestCase {
    func testSourceBindingResolutionRequiresRepoRootWhenMultipleBindingsExist() throws {
        let first = makeBinding(logicalRootName: "App", logicalRootPath: "/repo/app", worktreeID: "wt_app")
        let second = makeBinding(logicalRootName: "Lib", logicalRootPath: "/repo/lib", worktreeID: "wt_lib")

        XCTAssertThrowsError(try WorktreeMergeSourceBindingResolver.resolve(bindings: [first, second], repoRoot: nil)) { error in
            XCTAssertTrue(String(describing: error).contains("ambiguous") || (error as? LocalizedError)?.errorDescription?.contains("Multiple") == true)
        }

        let resolvedByName = try WorktreeMergeSourceBindingResolver.resolve(bindings: [first, second], repoRoot: "Lib")
        XCTAssertEqual(resolvedByName.worktreeID, "wt_lib")

        let resolvedByPath = try WorktreeMergeSourceBindingResolver.resolve(bindings: [first, second], repoRoot: "/repo/app")
        XCTAssertEqual(resolvedByPath.worktreeID, "wt_app")
    }

    func testSourceBindingResolutionBuildsEndpointFromSessionBinding() throws {
        let binding = makeBinding(
            logicalRootName: "App",
            logicalRootPath: "/repo/app",
            worktreeID: "wt_app",
            branch: "feature/merge",
            head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )

        let endpoint = try WorktreeMergeSourceBindingResolver.endpoint(from: binding)

        XCTAssertEqual(endpoint.worktreeID, "wt_app")
        XCTAssertEqual(endpoint.repositoryID, binding.repositoryID)
        XCTAssertEqual(endpoint.repoKey, binding.repoKey)
        XCTAssertEqual(endpoint.path, binding.worktreeRootPath)
        XCTAssertEqual(endpoint.branch, "feature/merge")
        XCTAssertEqual(endpoint.head, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    }

    func testPreviewOperationUpsertAndApprovalStateAreReflectedInRunSnapshot() {
        var operations: [AgentSessionWorktreeMergeOperation] = []
        let preview = makePreview(operationID: "merge_state")
        let operation = AgentWorktreeMergeCoordinator.makeOperation(preview: preview, status: .awaitingApproval, now: stateNow)
        AgentWorktreeMergeCoordinator.upsert(operation, in: &operations)

        XCTAssertEqual(operations.map(\.id), ["merge_state"])
        XCTAssertEqual(operations[0].status, .awaitingApproval)
        XCTAssertEqual(operations.activeWorktreeMergeSummaries.first?.status, .awaitingApproval)

        let review = PendingWorktreeMergeReview(
            id: reviewID,
            scope: WorktreeMergeReviewScope(windowID: 7, tabID: tabID),
            preview: preview,
            createdAt: stateNow
        )
        let snapshot = AgentRunInteractionUISnapshot(
            currentTabID: tabID,
            runState: .waitingForApproval,
            runningStatusText: nil,
            activeAgentRunStartedAt: nil,
            waitingPrompt: nil,
            pendingAskUser: nil,
            pendingUserInputRequest: nil,
            pendingApproval: nil,
            pendingPermissionsRequest: nil,
            pendingMCPElicitationRequest: nil,
            pendingApplyEditsReview: nil,
            pendingWorktreeMergeReview: review,
            activeRunID: nil,
            activeAgentSessionID: sessionID,
            activeRunAttemptID: nil,
            latestUserSequenceIndex: nil,
            canForkCurrentSession: false,
            selectedAgent: .codexExec,
            selectedModelRaw: AgentModel.defaultModel.rawValue,
            selectedReasoningEffortRaw: nil
        )

        XCTAssertEqual(snapshot.pendingWorktreeMergeReview?.operationID, "merge_state")
        XCTAssertTrue(snapshot.isWaitingForInstruction == false)
    }

    func testRejectedReviewMarksOperationCancelledWithoutApplyResult() throws {
        var operations = [AgentWorktreeMergeCoordinator.makeOperation(
            preview: makePreview(operationID: "merge_reject"),
            status: .awaitingApproval,
            now: stateNow
        )]

        try AgentWorktreeMergeCoordinator.update(operationID: "merge_reject", in: &operations, now: stateNow) { operation in
            operation.status = .cancelled
            operation.completedAt = stateNow
            operation.lastError = "Rejected by user"
        }

        XCTAssertEqual(operations[0].status, .cancelled)
        XCTAssertEqual(operations[0].completedAt, stateNow)
        XCTAssertEqual(operations[0].lastError, "Rejected by user")
        XCTAssertNil(operations[0].resultCommit)
        XCTAssertTrue(operations.activeWorktreeMergeSummaries.isEmpty)
    }

    func testAcceptedApplyResultUpdatesCompletedAndConflictedStates() {
        var completed = AgentWorktreeMergeCoordinator.makeOperation(
            preview: makePreview(operationID: "merge_apply"),
            status: .applying,
            now: stateNow
        )
        AgentWorktreeMergeCoordinator.apply(
            result: GitWorktreeMergeApplyResult(
                status: .completed,
                source: completed.source,
                target: completed.target,
                sourceHead: completed.sourceHead,
                targetHeadBefore: completed.targetHeadBefore,
                targetHeadAfter: "dddddddddddddddddddddddddddddddddddddddd",
                mergeCommit: "dddddddddddddddddddddddddddddddddddddddd"
            ),
            to: &completed,
            now: stateNow
        )

        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.resultCommit, "dddddddddddddddddddddddddddddddddddddddd")
        XCTAssertEqual(completed.completedAt, stateNow)

        var conflicted = AgentWorktreeMergeCoordinator.makeOperation(
            preview: makePreview(operationID: "merge_conflict"),
            status: .applying,
            now: stateNow
        )
        AgentWorktreeMergeCoordinator.apply(
            result: GitWorktreeMergeApplyResult(
                status: .conflicted,
                source: conflicted.source,
                target: conflicted.target,
                sourceHead: conflicted.sourceHead,
                targetHeadBefore: conflicted.targetHeadBefore,
                conflictFiles: ["b.txt", "a.txt"]
            ),
            to: &conflicted,
            now: stateNow
        )

        XCTAssertEqual(conflicted.status, .conflicted)
        XCTAssertEqual(conflicted.conflictFiles, ["a.txt", "b.txt"])
        XCTAssertNil(conflicted.completedAt)
        XCTAssertEqual(conflicted.activeSummary?.conflictFileCount, 2)
    }

    private let tabID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
    private let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
    private let reviewID = UUID(uuidString: "00000000-0000-0000-0000-000000000303")!
    private let stateNow = Date(timeIntervalSinceReferenceDate: 303)

    private func makeBinding(
        logicalRootName: String,
        logicalRootPath: String,
        worktreeID: String,
        branch: String = "feature",
        head: String = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding_\(worktreeID)",
            repositoryID: "gitrepo_abc123",
            repoKey: "repo",
            logicalRootPath: logicalRootPath,
            logicalRootName: logicalRootName,
            worktreeID: worktreeID,
            worktreeRootPath: "/tmp/\(worktreeID)",
            worktreeName: worktreeID,
            branch: branch,
            head: head,
            visualLabel: logicalRootName,
            visualColorHex: "#6699CC",
            boundAt: stateNow,
            source: "test"
        )
    }

    private func makePreview(operationID: String) -> GitWorktreeMergePreview {
        let source = GitWorktreeMergeEndpoint(
            worktreeID: "wt_source",
            repositoryID: "gitrepo_abc123",
            repoKey: "repo",
            path: "/tmp/source",
            name: "source",
            branch: "feature",
            head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            isMain: false
        )
        let target = GitWorktreeMergeEndpoint(
            worktreeID: "wt_target",
            repositoryID: "gitrepo_abc123",
            repoKey: "repo",
            path: "/tmp/target",
            name: "target",
            branch: "main",
            head: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            isMain: true
        )
        let inspection = GitWorktreeMergeInspection(
            source: source,
            target: target,
            mergeBase: "cccccccccccccccccccccccccccccccccccccccc",
            sourceHead: source.head,
            targetHead: target.head,
            sourceFingerprint: GitDiffFingerprint(headSHA: source.head, baseRef: "HEAD", statusHash: "source-clean", generatedAt: stateNow),
            targetFingerprint: GitDiffFingerprint(headSHA: target.head, baseRef: "HEAD", statusHash: "target-clean", generatedAt: stateNow),
            blockers: [],
            conflictPrediction: GitWorktreeMergeConflictPrediction(status: .clean),
            summary: GitWorktreeMergeSummary(commits: 2, files: 4, insertions: 20, deletions: 5),
            visualization: "target main <- source feature"
        )
        return GitWorktreeMergePreview(operationID: operationID, inspection: inspection, artifacts: GitWorktreeMergePreviewArtifacts(
            snapshotID: "snapshot_\(operationID)",
            snapshotDirectory: "/tmp/snapshot_\(operationID)",
            manifestPath: "/tmp/snapshot_\(operationID)/manifest.json",
            mapPath: "/tmp/snapshot_\(operationID)/MAP.txt",
            allPatchPath: "/tmp/snapshot_\(operationID)/diff/all.patch",
            sidecarPath: "/tmp/snapshot_\(operationID)/merge_preview.json"
        ))
    }
}
