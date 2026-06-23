import Foundation
@testable import RepoPrompt
import RepoPromptCore
import XCTest

final class AutomaticReviewGitDiffCoordinatorTests: XCTestCase {
    func testSingleCheckoutIncludesStagedUnstagedAndUntrackedChanges() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        defer { fixture.cleanup() }
        let repo = try fixture.makeRepository(named: "repo")
        try fixture.write("let value = 2\n", to: "Sources/Feature.swift", at: repo)
        try fixture.stage("Sources/Feature.swift", at: repo)
        try fixture.write("let value = 3\n", to: "Sources/Feature.swift", at: repo)
        try fixture.write("let extra = true\n", to: "Sources/Untracked.swift", at: repo)

        let result = await AutomaticReviewGitDiffCoordinator().resolve(request(
            paths: [
                repo.appendingPathComponent("Sources/Untracked.swift").path,
                repo.appendingPathComponent("Sources/Feature.swift").path
            ],
            displayRoots: [displayRoot(name: "Project", physicalRoot: repo)]
        ))

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.outcomes.count, 1)
        guard case let .diff(checkout, text) = result.outcomes.first else {
            return XCTFail("Expected one checkout diff")
        }
        XCTAssertEqual(checkout.checkoutRootPath, repo.path)
        XCTAssertEqual(checkout.displayLabel, "Project")
        XCTAssertEqual(
            checkout.selectedPaths,
            [
                repo.appendingPathComponent("Sources/Feature.swift").path,
                repo.appendingPathComponent("Sources/Untracked.swift").path
            ]
        )
        XCTAssertTrue(text.contains("Sources/Feature.swift"))
        XCTAssertTrue(text.contains("Sources/Untracked.swift"))
        XCTAssertEqual(result.text, text, "A complete single-checkout diff must remain byte-compatible")
        XCTAssertFalse(text.contains("REPOPROMPT CHECKOUT DIFF"))
    }

    func testNestedRepositoryUsesNearestOwnerAndSortsCheckoutsDeterministically() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        defer { fixture.cleanup() }
        let outer = try fixture.makeRepository(
            named: "outer",
            files: ["Sources/Outer.swift": "let outer = 1\n"]
        )
        let nested = try fixture.makeRepository(
            named: "outer/Dependencies/Nested",
            files: ["Sources/Inner.swift": "let inner = 1\n"]
        )
        try fixture.write("let outer = 2\n", to: "Sources/Outer.swift", at: outer)
        try fixture.write("let inner = 2\n", to: "Sources/Inner.swift", at: nested)

        let result = await AutomaticReviewGitDiffCoordinator().resolve(request(
            paths: [
                nested.appendingPathComponent("Sources/Inner.swift").path,
                outer.appendingPathComponent("Sources/Outer.swift").path
            ],
            displayRoots: [displayRoot(name: "Project", physicalRoot: outer)]
        ))

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.outcomes.map(\.checkout.checkoutRootPath), [outer.path, nested.path])
        XCTAssertEqual(result.outcomes.map(\.checkout.displayLabel), ["Project", "Project/Dependencies/Nested"])
        let text = try XCTUnwrap(result.text)
        let outerHeader = try XCTUnwrap(text.range(
            of: "BEGIN REPOPROMPT CHECKOUT DIFF: Project ====="
        ))
        let nestedHeader = try XCTUnwrap(text.range(
            of: "BEGIN REPOPROMPT CHECKOUT DIFF: Project/Dependencies/Nested ====="
        ))
        XCTAssertLessThan(outerHeader.lowerBound, nestedHeader.lowerBound)
        XCTAssertTrue(text.contains("Sources/Outer.swift"))
        XCTAssertTrue(text.contains("Sources/Inner.swift"))
    }

    func testLinkedWorktreesSharingCommonDirectoryRemainSeparate() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        defer { fixture.cleanup() }
        let main = try fixture.makeRepository(named: "main")
        let alpha = try fixture.makeLinkedWorktree(
            from: main,
            named: "linked-alpha",
            branch: "feature/alpha"
        )
        let beta = try fixture.makeLinkedWorktree(
            from: main,
            named: "linked-beta",
            branch: "feature/beta"
        )
        try fixture.write("let value = 10\n", to: "Sources/Feature.swift", at: alpha)
        try fixture.stage("Sources/Feature.swift", at: alpha)
        try fixture.write("let value = 20\n", to: "Sources/Feature.swift", at: beta)

        let alphaLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: alpha))
        let betaLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: beta))
        XCTAssertEqual(alphaLayout.commonDir, betaLayout.commonDir)

        let result = await AutomaticReviewGitDiffCoordinator().resolve(request(
            paths: [
                beta.appendingPathComponent("Sources/Feature.swift").path,
                alpha.appendingPathComponent("Sources/Feature.swift").path
            ],
            displayRoots: [
                displayRoot(name: "Alpha", physicalRoot: alpha),
                displayRoot(name: "Beta", physicalRoot: beta)
            ]
        ))

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.outcomes.map(\.checkout.checkoutRootPath), [alpha.path, beta.path])
        XCTAssertEqual(result.outcomes.map(\.checkout.displayLabel), ["Alpha", "Beta"])
        let text = try XCTUnwrap(result.text)
        XCTAssertTrue(text.contains("BEGIN REPOPROMPT CHECKOUT DIFF: Alpha"))
        XCTAssertTrue(text.contains("BEGIN REPOPROMPT CHECKOUT DIFF: Beta"))
    }

    func testMergeBaseIDsAndPathOrderingAreFrozenBeforeDiffExecution() async {
        let root = URL(fileURLWithPath: "/tmp/review-freeze/repo", isDirectory: true)
        let first = root.appendingPathComponent("Sources/A.swift").path
        let second = root.appendingPathComponent("Sources/B.swift").path
        let recorder = ReviewGitCoordinatorRecorder()
        let layout = testLayout(root: root)
        let dependencies = AutomaticReviewGitDiffCoordinator.Dependencies(
            resolveRepo: { _ in VCSResolvedRepo(rootURL: root, backendKind: .git) },
            resolveLayout: { _ in layout },
            resolveHead: { _ in
                await recorder.record("head")
                return "head-frozen"
            },
            resolveRef: { ref, _ in
                await recorder.record("ref:\(ref)")
                return "base-frozen"
            },
            mergeBase: { headID, baseID, _ in
                await recorder.record("merge:\(headID):\(baseID)")
                return "merge-frozen"
            },
            buildDiff: { compare, paths, _ in
                await recorder.recordDiff(compare: compare, paths: paths)
                return "frozen diff"
            }
        )

        let result = await AutomaticReviewGitDiffCoordinator(dependencies: dependencies).resolve(
            request(
                paths: [second, first, second],
                compareIntent: .uncommittedMergeBase(symbolicBase: "origin/main"),
                displayRoots: [displayRoot(name: "Project", physicalRoot: root)]
            )
        )

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.text, "frozen diff")
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(
            snapshot.events,
            ["head", "ref:origin/main", "merge:head-frozen:base-frozen", "diff"]
        )
        XCTAssertEqual(snapshot.compare, .uncommitted(base: "merge-frozen"))
        XCTAssertEqual(snapshot.paths, [first, second])
    }

    func testAllCheckoutBoundariesFreezeBeforeFirstDiffExecution() async {
        let rootA = URL(fileURLWithPath: "/tmp/review-freeze/alpha", isDirectory: true)
        let rootB = URL(fileURLWithPath: "/tmp/review-freeze/beta", isDirectory: true)
        let layoutA = testLayout(root: rootA)
        let layoutB = testLayout(root: rootB)
        let recorder = ReviewGitCoordinatorRecorder()
        let dependencies = AutomaticReviewGitDiffCoordinator.Dependencies(
            resolveRepo: { url in
                VCSResolvedRepo(
                    rootURL: url.path.hasPrefix(rootA.path) ? rootA : rootB,
                    backendKind: .git
                )
            },
            resolveLayout: { root in root.path == rootA.path ? layoutA : layoutB },
            resolveHead: { root in
                await recorder.record("head:\(root.lastPathComponent)")
                return "head-\(root.lastPathComponent)"
            },
            resolveRef: { _, root in
                await recorder.record("ref:\(root.lastPathComponent)")
                return "base-\(root.lastPathComponent)"
            },
            mergeBase: { _, _, root in
                await recorder.record("merge:\(root.lastPathComponent)")
                return "merge-\(root.lastPathComponent)"
            },
            buildDiff: { _, _, root in
                await recorder.record("diff:\(root.lastPathComponent)")
                return "diff \(root.lastPathComponent)"
            }
        )

        let result = await AutomaticReviewGitDiffCoordinator(dependencies: dependencies).resolve(request(
            paths: [
                rootB.appendingPathComponent("B.swift").path,
                rootA.appendingPathComponent("A.swift").path
            ],
            compareIntent: .uncommittedMergeBase(symbolicBase: "main"),
            displayRoots: [
                displayRoot(name: "Alpha", physicalRoot: rootA),
                displayRoot(name: "Beta", physicalRoot: rootB)
            ]
        ))

        XCTAssertEqual(result.completeness, .complete)
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(
            snapshot.events,
            [
                "head:alpha", "ref:alpha", "merge:alpha",
                "head:beta", "ref:beta", "merge:beta",
                "diff:alpha", "diff:beta"
            ]
        )
    }

    func testOneCheckoutFailureProducesExplicitPartialResultWithoutPhysicalPaths() async throws {
        let rootA = URL(fileURLWithPath: "/private/tmp/review-partial/alpha", isDirectory: true)
        let rootB = URL(fileURLWithPath: "/private/tmp/review-partial/beta", isDirectory: true)
        let fileA = rootA.appendingPathComponent("A.swift").path
        let fileB = rootB.appendingPathComponent("B.swift").path
        let layoutA = testLayout(root: rootA)
        let layoutB = testLayout(root: rootB)
        let dependencies = AutomaticReviewGitDiffCoordinator.Dependencies(
            resolveRepo: { url in
                if url.path.hasPrefix(rootA.path) {
                    return VCSResolvedRepo(rootURL: rootA, backendKind: .git)
                }
                return VCSResolvedRepo(rootURL: rootB, backendKind: .git)
            },
            resolveLayout: { url in url.path == rootA.path ? layoutA : layoutB },
            resolveHead: { _ in "head-frozen" },
            resolveRef: { _, _ in "base-frozen" },
            mergeBase: { _, _, _ in "merge-frozen" },
            buildDiff: { _, _, root in
                if root.path == rootB.path {
                    throw ReviewGitCoordinatorTestError(message: "failed at \(root.path)")
                }
                return "diff --git a/A.swift b/A.swift"
            }
        )

        let result = await AutomaticReviewGitDiffCoordinator(dependencies: dependencies).resolve(request(
            paths: [fileB, fileA],
            displayRoots: [
                displayRoot(name: "Alpha", physicalRoot: rootA),
                displayRoot(name: "Beta", physicalRoot: rootB)
            ]
        ))

        XCTAssertEqual(result.completeness, .partial)
        XCTAssertEqual(result.outcomes.count, 2)
        guard case .diff = result.outcomes[0],
              case let .commandFailed(checkout, summary) = result.outcomes[1]
        else {
            return XCTFail("Expected deterministic success then failure outcomes")
        }
        XCTAssertEqual(checkout.displayLabel, "Beta")
        XCTAssertFalse(summary.contains(rootB.path))
        let text = try XCTUnwrap(result.text)
        XCTAssertTrue(text.contains("REPOPROMPT REVIEW DIFF INCOMPLETE"))
        XCTAssertTrue(text.contains("Git diff command failed for checkout: Beta"))
        XCTAssertFalse(text.contains(rootA.path))
        XCTAssertFalse(text.contains(rootB.path))
    }

    func testUnresolvedNoRepositoryAndUnsupportedBackendAreStructuredFailures() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/review-path-issues", isDirectory: true)
        let noRepo = root.appendingPathComponent("NoRepo.swift").path
        let jjFile = root.appendingPathComponent("JJ/File.swift").path
        let dependencies = AutomaticReviewGitDiffCoordinator.Dependencies(
            resolveRepo: { url in
                guard url.path == jjFile else { return nil }
                return VCSResolvedRepo(
                    rootURL: root.appendingPathComponent("JJ", isDirectory: true),
                    backendKind: .jujutsu
                )
            },
            resolveLayout: { _ in nil },
            resolveHead: { _ in "unused" },
            resolveRef: { _, _ in "unused" },
            mergeBase: { _, _, _ in "unused" },
            buildDiff: { _, _, _ in XCTFail("Diff execution must not run")
                return nil
            }
        )
        let resolution = WorkspaceSelectedGitPathResolution(
            paths: [noRepo, jjFile],
            unresolvedCandidates: [root.appendingPathComponent("Missing.swift").path]
        )

        let result = await AutomaticReviewGitDiffCoordinator(dependencies: dependencies).resolve(
            AutomaticReviewGitDiffRequest(
                pathResolution: resolution,
                compareIntent: .uncommittedHEAD,
                displayContext: ReviewGitDisplayContext(roots: [
                    displayRoot(name: "Project", physicalRoot: root)
                ])
            )
        )

        XCTAssertEqual(result.completeness, .failed)
        XCTAssertEqual(
            result.pathIssues,
            [
                .unresolvedSelection(displayPath: "Project/Missing.swift"),
                .noRepository(displayPath: "Project/NoRepo.swift"),
                .unsupportedBackend(displayPath: "Project/JJ/File.swift", backendKind: .jujutsu)
            ]
        )
        XCTAssertTrue(result.outcomes.isEmpty)
        let text = try XCTUnwrap(result.text)
        XCTAssertTrue(text.contains("REPOPROMPT REVIEW DIFF INCOMPLETE"))
        XCTAssertFalse(text.contains(root.path))
    }

    func testCancellationAfterNonCooperativeDiffSuppressesPartialPayload() async {
        let root = URL(fileURLWithPath: "/tmp/review-cancel/repo", isDirectory: true)
        let layout = testLayout(root: root)
        let gate = ReviewGitNonCooperativeGate()
        let dependencies = AutomaticReviewGitDiffCoordinator.Dependencies(
            resolveRepo: { _ in VCSResolvedRepo(rootURL: root, backendKind: .git) },
            resolveLayout: { _ in layout },
            resolveHead: { _ in "head-frozen" },
            resolveRef: { _, _ in "base-frozen" },
            mergeBase: { _, _, _ in "merge-frozen" },
            buildDiff: { _, _, _ in
                await gate.suspend()
                return "late diff"
            }
        )
        let coordinator = AutomaticReviewGitDiffCoordinator(dependencies: dependencies)
        let request = request(
            paths: [root.appendingPathComponent("Feature.swift").path],
            displayRoots: [displayRoot(name: "Project", physicalRoot: root)]
        )

        let task = Task { await coordinator.resolve(request) }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.release()
        let result = await task.value

        XCTAssertEqual(result.completeness, .cancelled)
        XCTAssertNil(result.text)
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertTrue(result.pathIssues.isEmpty)
    }

    func testMissingBaseRefFailsBeforeDiffAndAllNoChangeReturnsNil() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        defer { fixture.cleanup() }
        let repo = try fixture.makeRepository(named: "repo")
        let file = repo.appendingPathComponent("Sources/Feature.swift").path

        let missingBase = await AutomaticReviewGitDiffCoordinator().resolve(request(
            paths: [file],
            compareIntent: .uncommittedMergeBase(symbolicBase: "refs/heads/does-not-exist"),
            displayRoots: [displayRoot(name: "Project", physicalRoot: repo)]
        ))
        XCTAssertEqual(missingBase.completeness, .failed)
        guard case .baseResolutionFailed = missingBase.outcomes.first else {
            return XCTFail("Expected a structured base resolution failure")
        }
        XCTAssertTrue(try XCTUnwrap(missingBase.text).contains("Comparison base could not be resolved"))

        let root = URL(fileURLWithPath: "/tmp/review-clean/repo", isDirectory: true)
        let layout = testLayout(root: root)
        let cleanDependencies = AutomaticReviewGitDiffCoordinator.Dependencies(
            resolveRepo: { _ in VCSResolvedRepo(rootURL: root, backendKind: .git) },
            resolveLayout: { _ in layout },
            resolveHead: { _ in "head-frozen" },
            resolveRef: { _, _ in "base-frozen" },
            mergeBase: { _, _, _ in "merge-frozen" },
            buildDiff: { _, _, _ in nil }
        )
        let clean = await AutomaticReviewGitDiffCoordinator(dependencies: cleanDependencies).resolve(request(
            paths: [root.appendingPathComponent("Clean.swift").path],
            displayRoots: [displayRoot(name: "Clean", physicalRoot: root)]
        ))
        XCTAssertEqual(clean.completeness, .complete)
        XCTAssertNil(clean.text)
        guard case .noChanges = clean.outcomes.first else {
            return XCTFail("Expected a structured no-change checkout outcome")
        }
    }

    func testFinalizedAuthorityBypassesOwnershipRediscoveryAndKeepsSameRelativePathsSeparate() async throws {
        let rootA = URL(fileURLWithPath: "/tmp/review-finalized/alpha", isDirectory: true)
        let rootB = URL(fileURLWithPath: "/tmp/review-finalized/beta", isDirectory: true)
        let pathA = rootA.appendingPathComponent("Sources/App.swift").path
        let pathB = rootB.appendingPathComponent("Sources/App.swift").path
        let authorization = finalizedAuthorization(
            rootsAndPaths: [(rootA, [pathA]), (rootB, [pathB])]
        )
        let recorder = ReviewGitCoordinatorRecorder()
        let dependencies = AutomaticReviewGitDiffCoordinator.Dependencies(
            resolveRepo: { _ in
                XCTFail("Finalized requests must not rediscover selected-path ownership")
                return nil
            },
            resolveLayout: { _ in
                XCTFail("Finalized requests must not rediscover checkout layout through ownership")
                return nil
            },
            resolveHead: { root in "head-\(root.lastPathComponent)" },
            resolveRef: { _, _ in "unused" },
            mergeBase: { _, _, _ in "unused" },
            buildDiff: { _, paths, root in
                await recorder.record("diff:\(root.lastPathComponent):\(paths.joined(separator: ","))")
                return "diff \(root.lastPathComponent)"
            },
            revalidateFinalAuthorization: { _ in nil }
        )

        let result = try await AutomaticReviewGitDiffCoordinator(dependencies: dependencies)
            .resolveStrict(finalizedRequest(authorization))

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.outcomes.map(\.checkout.selectedPaths), [[pathA], [pathB]])
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(
            snapshot.events,
            ["diff:alpha:\(pathA)", "diff:beta:\(pathB)"]
        )
    }

    func testFinalizedAuthorityInvalidatedAfterBaseResolutionNeverRunsDiff() async {
        let root = URL(fileURLWithPath: "/tmp/review-finalized/base-race", isDirectory: true)
        let path = root.appendingPathComponent("Feature.swift").path
        let authorization = finalizedAuthorization(rootsAndPaths: [(root, [path])])
        let validity = FinalAuthorizationValidity()
        let dependencies = AutomaticReviewGitDiffCoordinator.Dependencies(
            resolveRepo: { _ in XCTFail("Ownership rediscovery is forbidden")
                return nil
            },
            resolveLayout: { _ in XCTFail("Ownership rediscovery is forbidden")
                return nil
            },
            resolveHead: { _ in
                await validity.invalidate()
                return "head"
            },
            resolveRef: { _, _ in "unused" },
            mergeBase: { _, _, _ in "unused" },
            buildDiff: { _, _, _ in XCTFail("Diff must not run after authority expires")
                return "forbidden"
            },
            revalidateFinalAuthorization: { _ in
                await validity.failure()
            }
        )

        do {
            _ = try await AutomaticReviewGitDiffCoordinator(dependencies: dependencies)
                .resolveStrict(finalizedRequest(authorization))
            XCTFail("Expected stale finalized authority")
        } catch let reason as ContextBuilderReviewTargetUnavailableReason {
            XCTAssertEqual(reason, .staleWorkspaceRoot)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFinalizedAuthorityInvalidatedDuringDiffDiscardsReturnedPayload() async {
        let root = URL(fileURLWithPath: "/tmp/review-finalized/diff-race", isDirectory: true)
        let path = root.appendingPathComponent("Feature.swift").path
        let authorization = finalizedAuthorization(rootsAndPaths: [(root, [path])])
        let validity = FinalAuthorizationValidity()
        let dependencies = AutomaticReviewGitDiffCoordinator.Dependencies(
            resolveRepo: { _ in XCTFail("Ownership rediscovery is forbidden")
                return nil
            },
            resolveLayout: { _ in XCTFail("Ownership rediscovery is forbidden")
                return nil
            },
            resolveHead: { _ in "head" },
            resolveRef: { _, _ in "unused" },
            mergeBase: { _, _, _ in "unused" },
            buildDiff: { _, _, _ in
                await validity.invalidate()
                return "late unauthorized payload"
            },
            revalidateFinalAuthorization: { _ in
                await validity.failure()
            }
        )

        do {
            _ = try await AutomaticReviewGitDiffCoordinator(dependencies: dependencies)
                .resolveStrict(finalizedRequest(authorization))
            XCTFail("Expected stale finalized authority")
        } catch let reason as ContextBuilderReviewTargetUnavailableReason {
            XCTAssertEqual(reason, .staleWorkspaceRoot)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func request(
        paths: [String],
        unresolved: [String] = [],
        compareIntent: ReviewGitCompareIntent = .uncommittedHEAD,
        displayRoots: [ReviewGitDisplayRoot]
    ) -> AutomaticReviewGitDiffRequest {
        AutomaticReviewGitDiffRequest(
            pathResolution: WorkspaceSelectedGitPathResolution(
                paths: paths,
                unresolvedCandidates: unresolved
            ),
            compareIntent: compareIntent,
            displayContext: ReviewGitDisplayContext(roots: displayRoots)
        )
    }

    private func displayRoot(name: String, physicalRoot: URL) -> ReviewGitDisplayRoot {
        ReviewGitDisplayRoot(
            logicalRootPath: "/logical/\(name)",
            logicalRootName: name,
            physicalRootPath: physicalRoot.path
        )
    }

    private func finalizedRequest(
        _ authorization: ContextBuilderFinalReviewAuthorization
    ) -> AutomaticReviewGitDiffRequest {
        AutomaticReviewGitDiffRequest(
            finalReviewAuthorization: authorization,
            compareIntent: .uncommittedHEAD,
            displayContext: authorization.target.displayContext
        )
    }

    private func finalizedAuthorization(
        rootsAndPaths: [(URL, [String])]
    ) -> ContextBuilderFinalReviewAuthorization {
        let workspaceID = UUID()
        let tabID = UUID()
        let revision: UInt64 = 7
        let displayRoots = rootsAndPaths.enumerated().map { index, item in
            displayRoot(name: "Checkout \(index + 1)", physicalRoot: item.0)
        }
        let checkouts = rootsAndPaths.enumerated().map { index, item in
            ContextBuilderReviewCheckoutTarget(
                logicalWorkspaceRoot: WorkspaceRootRef(
                    id: UUID(),
                    name: "Checkout \(index + 1)",
                    fullPath: "/logical/checkout-\(index + 1)"
                ),
                physicalWorkspaceRoot: WorkspaceRootRef(
                    id: UUID(),
                    name: item.0.lastPathComponent,
                    fullPath: item.0.path
                ),
                physicalWorkspaceRootKind: .primaryWorkspace,
                checkoutRootPath: item.0.path,
                repoKey: "repo-\(index)",
                repositoryID: "repository-\(index)",
                worktreeID: "worktree-\(index)",
                kind: .canonical,
                sessionRootAuthorization: nil
            )
        }
        let target = ContextBuilderReviewTarget(
            workspaceID: workspaceID,
            tabID: tabID,
            sourceSelectionRevision: revision,
            initialOrdinarySelectionIdentities: rootsAndPaths.flatMap(\.1),
            initialSelectedArtifactIdentities: [],
            checkouts: checkouts,
            primaryCheckout: checkouts[0],
            artifactCapability: nil,
            displayContext: ReviewGitDisplayContext(roots: displayRoots)
        )
        return ContextBuilderFinalReviewAuthorization(
            electionOrigin: .initiallyAvailable,
            workspaceID: workspaceID,
            tabID: tabID,
            committedSelectionRevision: revision,
            committedSelection: StoredSelection(
                selectedPaths: rootsAndPaths.flatMap(\.1),
                codemapAutoEnabled: false
            ),
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
            reviewGitContext: .automaticOnly(),
            target: target,
            checkoutAuthorizations: zip(checkouts, rootsAndPaths).map { checkout, item in
                ContextBuilderFinalReviewCheckoutAuthorization(
                    checkout: checkout,
                    ordinaryPhysicalPaths: item.1
                )
            },
            selectedArtifactAuthorizations: []
        )
    }
}

private actor ReviewGitCoordinatorRecorder {
    private var events: [String] = []
    private var compare: GitDiffCompareSpec?
    private var paths: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func recordDiff(compare: GitDiffCompareSpec, paths: [String]) {
        events.append("diff")
        self.compare = compare
        self.paths = paths
    }

    func snapshot() -> (events: [String], compare: GitDiffCompareSpec?, paths: [String]) {
        (events, compare, paths)
    }
}

private actor ReviewGitNonCooperativeGate {
    private var started = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor FinalAuthorizationValidity {
    private var isValid = true

    func invalidate() {
        isValid = false
    }

    func failure() -> ContextBuilderReviewTargetUnavailableReason? {
        isValid ? nil : .staleWorkspaceRoot
    }
}

private struct ReviewGitCoordinatorTestError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private func testLayout(root: URL) -> GitRepositoryLayout {
    let dotGit = root.appendingPathComponent(".git", isDirectory: true)
    return GitRepositoryLayout(
        workTreeRoot: root,
        dotGitPath: dotGit,
        gitDir: dotGit,
        commonDir: dotGit,
        isWorktree: false
    )
}
