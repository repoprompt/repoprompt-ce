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

    func testWorktreeMergeEndpointPostCheckRejectsPathOrIdentityChanges() throws {
        let repository = GitWorktreeRepositoryIdentity(
            repositoryID: "gitrepo_merge",
            repoKey: "merge",
            displayName: "merge",
            commonGitDir: "/tmp/merge/.git",
            mainWorktreeRoot: "/tmp/merge"
        )

        func descriptor(
            worktreeID: String = "wt_source",
            path: String = "/tmp/merge-source/../merge-source",
            head: String = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        ) -> GitWorktreeDescriptor {
            GitWorktreeDescriptor(
                worktreeID: worktreeID,
                repository: repository,
                path: path,
                gitDir: "/tmp/merge/.git/worktrees/source",
                name: "source",
                branch: "feature",
                head: head,
                isMain: false,
                isCurrent: false,
                isDetached: false,
                isLocked: false,
                lockReason: nil,
                isPrunable: false,
                prunableReason: nil
            )
        }

        let endpoint = try GitWorktreeMergeEndpoint(descriptor: descriptor())
        XCTAssertEqual(endpoint.path, "/tmp/merge-source")
        XCTAssertTrue(WorktreeMergeEndpointValidation.matches(endpoint, descriptor: descriptor()))
        XCTAssertFalse(WorktreeMergeEndpointValidation.matches(endpoint, descriptor: descriptor(path: "/tmp/merge-other")))
        XCTAssertFalse(WorktreeMergeEndpointValidation.matches(endpoint, descriptor: descriptor(worktreeID: "wt-replaced")))
        XCTAssertFalse(WorktreeMergeEndpointValidation.matches(endpoint, descriptor: descriptor(head: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")))
    }

    func testEndpointAuthorizationAcceptsMainAdvertisedByAuthorizedLinkedWorktree() async throws {
        let fixture = try makeEndpointAuthorizationFixture()

        let authorized = try await WorktreeMergeEndpointValidation.resolveAuthorizedDescriptor(
            for: fixture.endpoint,
            roots: [fixture.linkedRoot],
            resolver: fixture.resolver
        )

        XCTAssertEqual(authorized, fixture.resolvedMain)
    }

    func testEndpointAuthorizationRejectsExternalWorktreeNotAdvertisedByAuthorizedRoot() async throws {
        let fixture = try makeEndpointAuthorizationFixture()
        let unrelatedRoot = WorkspaceRootRef(
            id: UUID(),
            name: "unrelated",
            fullPath: "/tmp/unrelated-workspace"
        )

        do {
            _ = try await WorktreeMergeEndpointValidation.resolveAuthorizedDescriptor(
                for: fixture.endpoint,
                roots: [unrelatedRoot],
                resolver: fixture.resolver
            )
            XCTFail("Expected an external worktree with no authorized repository checkout to be rejected.")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("inside a loaded root or advertised by a loaded repository"),
                String(describing: error)
            )
        }
    }

    func testEndpointAuthorizationRejectsResolvedHeadIdentityDrift() async throws {
        let fixture = try makeEndpointAuthorizationFixture(
            resolvedHead: "cccccccccccccccccccccccccccccccccccccccc"
        )

        do {
            _ = try await WorktreeMergeEndpointValidation.resolveAuthorizedDescriptor(
                for: fixture.endpoint,
                roots: [fixture.linkedRoot],
                resolver: fixture.resolver
            )
            XCTFail("Expected an endpoint whose resolved HEAD changed to be rejected.")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("Worktree endpoint identity changed before authorization"),
                String(describing: error)
            )
        }
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

    private func makeEndpointAuthorizationFixture(
        resolvedHead: String = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ) throws -> (
        endpoint: GitWorktreeMergeEndpoint,
        resolvedMain: GitWorktreeDescriptor,
        linkedRoot: WorkspaceRootRef,
        resolver: GitRepoTargetResolver
    ) {
        let mainPath = "/tmp/merge-main"
        let linkedPath = "/tmp/merge-linked"
        let endpointHead = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let repository = GitWorktreeRepositoryIdentity(
            repositoryID: "gitrepo_merge",
            repoKey: "merge",
            displayName: "merge",
            commonGitDir: "\(mainPath)/.git",
            mainWorktreeRoot: mainPath
        )

        func mainDescriptor(head: String) -> GitWorktreeDescriptor {
            GitWorktreeDescriptor(
                worktreeID: "wt_main",
                repository: repository,
                path: mainPath,
                gitDir: "\(mainPath)/.git",
                name: "merge-main",
                branch: "main",
                head: head,
                isMain: true,
                isCurrent: false,
                isDetached: false,
                isLocked: false,
                lockReason: nil,
                isPrunable: false,
                prunableReason: nil
            )
        }

        let linked = GitWorktreeDescriptor(
            worktreeID: "wt_linked",
            repository: repository,
            path: linkedPath,
            gitDir: "\(mainPath)/.git/worktrees/merge-linked",
            name: "merge-linked",
            branch: "feature/merge",
            head: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            isMain: false,
            isCurrent: true,
            isDetached: false,
            isLocked: false,
            lockReason: nil,
            isPrunable: false,
            prunableReason: nil
        )
        let endpoint = try GitWorktreeMergeEndpoint(descriptor: mainDescriptor(head: endpointHead))
        let resolvedMain = mainDescriptor(head: resolvedHead)
        let resolvedMainDescriptor = GitRepoDescriptor(
            rootURL: URL(fileURLWithPath: mainPath),
            rootPath: mainPath,
            repoKey: resolvedMain.repository.repoKey,
            displayName: resolvedMain.repository.displayName,
            worktreeIdentity: GitWorktreeIdentitySnapshot(
                repository: resolvedMain.repository,
                worktreeID: resolvedMain.worktreeID,
                worktreeRootPath: mainPath,
                isMain: resolvedMain.isMain
            )
        )
        let resolver = GitRepoTargetResolver(dependencies: .init(
            resolveRepo: { url in
                url.standardizedFileURL.path == mainPath
                    ? resolvedMainDescriptor
                    : nil
            },
            listWorktrees: { _ in [resolvedMain, linked] }
        ))
        let linkedRoot = WorkspaceRootRef(id: UUID(), name: "merge-linked", fullPath: linkedPath)
        return (endpoint, resolvedMain, linkedRoot, resolver)
    }

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
