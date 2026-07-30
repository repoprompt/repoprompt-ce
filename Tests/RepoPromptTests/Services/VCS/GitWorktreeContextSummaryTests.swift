import Foundation
@testable import RepoPromptApp
import XCTest

final class GitWorktreeContextResolverTests: XCTestCase {
    private var tempRoot: URL?

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    func testResolverReturnsNilForNonGitRoot() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let context = await VCSService().gitWorktreeContext(for: root)

        XCTAssertNil(context)
    }

    func testResolverMatchesVisibleSubdirectoryInsideWorktree() async throws {
        let repo = try makeGitFixture()
        let nested = repo.appendingPathComponent("apps/web", isDirectory: true)

        let resolvedContext = await VCSService().gitWorktreeContext(for: nested)
        let context = try XCTUnwrap(resolvedContext)

        XCTAssertEqual(context.repositoryDisplayName, "repo")
        XCTAssertEqual(context.worktreeName, "repo")
        XCTAssertEqual(context.branchDisplayText, "main")
        XCTAssertEqual(context.breadcrumbText, "repo / repo / main")
        XCTAssertTrue(context.isMain)
        XCTAssertEqual(context.checkoutDisplayText, "main repository checkout")
        XCTAssertEqual(URL(fileURLWithPath: context.worktreePath).standardizedFileURL.path, repo.standardizedFileURL.path)
    }

    func testFallbackContextMarksMainRepositoryCheckout() async throws {
        let repo = try makeGitFixture()
        let service = VCSService()
        let resolved = VCSResolvedRepo(rootURL: repo, backendKind: .git)

        let resolvedContext = await service.gitWorktreeContext(for: repo, resolved: resolved, worktrees: nil)
        let context = try XCTUnwrap(resolvedContext)

        XCTAssertTrue(context.isMain)
        XCTAssertEqual(context.checkoutDisplayText, "main repository checkout")
        XCTAssertTrue(context.tooltipText.contains("Checkout: main repository checkout"))

        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: repo))
        XCTAssertFalse(layout.isWorktree)
        XCTAssertFalse(layout.isLinkedWorktree)
    }

    func testSeparateGitDirPrimaryCheckoutIsNotTreatedAsLinkedWorktree() async throws {
        let fixture = try makeSeparateGitDirFixture()
        let service = VCSService()
        let resolved = VCSResolvedRepo(rootURL: fixture.repo, backendKind: .git)

        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.repo))
        XCTAssertTrue(layout.isWorktree)
        XCTAssertFalse(layout.isLinkedWorktree)
        XCTAssertEqual(layout.gitDir.standardizedFileURL, fixture.gitDir.standardizedFileURL)
        XCTAssertEqual(layout.commonDir.standardizedFileURL, fixture.gitDir.standardizedFileURL)
        XCTAssertEqual(layout.knownMainWorktreeRoot, fixture.repo.standardizedFileURL)

        let metadata = GitDiffSnapshotStore().worktreeMetadata(for: fixture.repo.path)
        XCTAssertNil(metadata.isWorktree)
        XCTAssertNil(metadata.mainWorktreeRoot)

        let resolvedFallbackContext = await service.gitWorktreeContext(
            for: fixture.repo,
            resolved: resolved,
            worktrees: nil
        )
        let fallbackContext = try XCTUnwrap(resolvedFallbackContext)
        XCTAssertTrue(fallbackContext.isMain)
        XCTAssertEqual(fallbackContext.repositoryDisplayName, fixture.repo.lastPathComponent)
        XCTAssertEqual(fallbackContext.checkoutDisplayText, "main repository checkout")

        let descriptors = try await service.listGitWorktrees(at: fixture.repo)
        let descriptor = try XCTUnwrap(descriptors.first)
        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(URL(fileURLWithPath: descriptor.path).standardizedFileURL, fixture.repo.standardizedFileURL)
        XCTAssertEqual(descriptor.gitDir.map { URL(fileURLWithPath: $0).standardizedFileURL }, fixture.gitDir.standardizedFileURL)
        XCTAssertTrue(descriptor.isMain)
        XCTAssertTrue(descriptor.isCurrent)
        XCTAssertEqual(descriptor.repository.mainWorktreeRoot, fixture.repo.standardizedFileURL.path)
        XCTAssertEqual(descriptor.repository.displayName, fixture.repo.lastPathComponent)

        let resolvedListedContext = await service.gitWorktreeContext(for: fixture.repo)
        let listedContext = try XCTUnwrap(resolvedListedContext)
        XCTAssertTrue(listedContext.isMain)
        XCTAssertEqual(listedContext.worktreePath, fixture.repo.standardizedFileURL.path)
        XCTAssertEqual(listedContext.repositoryDisplayName, fixture.repo.lastPathComponent)
    }

    func testExternalCommonDirLinkedWorktreeOmitsUnresolvablePrimaryRecord() async throws {
        let fixture = try makeSeparateGitDirFixture()
        let linkedWorktree = fixture.repo.deletingLastPathComponent()
            .appendingPathComponent("repo-linked", isDirectory: true)
        try runGit(["worktree", "add", "-b", "feature/linked", linkedWorktree.path], cwd: fixture.repo)
        let service = VCSService()

        let descriptors = try await service.listGitWorktrees(at: linkedWorktree)
        XCTAssertFalse(descriptors.contains { URL(fileURLWithPath: $0.path).standardizedFileURL == fixture.gitDir.standardizedFileURL })
        XCTAssertFalse(descriptors.contains(where: \.isMain))
        let linkedDescriptor = try XCTUnwrap(descriptors.first { $0.isCurrent })
        XCTAssertEqual(URL(fileURLWithPath: linkedDescriptor.path).standardizedFileURL, linkedWorktree.standardizedFileURL)
        XCTAssertFalse(linkedDescriptor.isMain)
        XCTAssertNil(linkedDescriptor.repository.mainWorktreeRoot)

        let resolved = VCSResolvedRepo(rootURL: linkedWorktree, backendKind: .git)
        let resolvedFallback = await service.gitWorktreeContext(
            for: linkedWorktree,
            resolved: resolved,
            worktrees: nil
        )
        let fallback = try XCTUnwrap(resolvedFallback)
        XCTAssertFalse(fallback.isMain)
        XCTAssertEqual(fallback.checkoutDisplayText, "linked worktree")

        let metadata = GitDiffSnapshotStore().worktreeMetadata(for: linkedWorktree.path)
        XCTAssertEqual(metadata.isWorktree, true)
        XCTAssertEqual(metadata.worktreeRoot, linkedWorktree.standardizedFileURL.path)
        XCTAssertNil(metadata.mainWorktreeRoot)
    }

    func testExternalCommonDirLinkedWorktreeUsesConfiguredCoreWorktree() async throws {
        let fixture = try makeSeparateGitDirFixture()
        let linkedWorktree = fixture.repo.deletingLastPathComponent()
            .appendingPathComponent("repo-linked", isDirectory: true)
        try runGit(["worktree", "add", "-b", "feature/linked", linkedWorktree.path], cwd: fixture.repo)
        try runGit(["config", "core.worktree", fixture.repo.path], cwd: fixture.repo)

        let descriptors = try await VCSService().listGitWorktrees(at: linkedWorktree)
        let main = try XCTUnwrap(descriptors.first(where: \.isMain))
        XCTAssertEqual(URL(fileURLWithPath: main.path).standardizedFileURL, fixture.repo.standardizedFileURL)
        XCTAssertEqual(main.repository.mainWorktreeRoot, fixture.repo.standardizedFileURL.path)
        XCTAssertTrue(descriptors.contains { $0.isCurrent && URL(fileURLWithPath: $0.path).standardizedFileURL == linkedWorktree.standardizedFileURL })
    }

    func testExternalCommonDirLinkedWorktreeUsesWorktreeConfigCoreWorktree() async throws {
        let fixture = try makeSeparateGitDirFixture()
        let linkedWorktree = fixture.repo.deletingLastPathComponent()
            .appendingPathComponent("repo-linked", isDirectory: true)
        try runGit(["worktree", "add", "-b", "feature/linked", linkedWorktree.path], cwd: fixture.repo)
        try runGit(["config", "extensions.worktreeConfig", "true"], cwd: fixture.repo)
        try runGit(["config", "--worktree", "core.worktree", fixture.repo.path], cwd: fixture.repo)

        let normalQuery = try runGitResult(
            ["config", "--path", "--get", "core.worktree"],
            cwd: linkedWorktree,
            requireSuccess: false
        )
        XCTAssertTrue(normalQuery.outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let descriptors = try await VCSService().listGitWorktrees(at: linkedWorktree)
        let main = try XCTUnwrap(descriptors.first(where: \.isMain))
        XCTAssertEqual(URL(fileURLWithPath: main.path).standardizedFileURL, fixture.repo.standardizedFileURL)
        XCTAssertEqual(main.repository.mainWorktreeRoot, fixture.repo.standardizedFileURL.path)
        XCTAssertTrue(descriptors.contains { $0.isCurrent && URL(fileURLWithPath: $0.path).standardizedFileURL == linkedWorktree.standardizedFileURL })
    }

    func testFallbackContextMarksLinkedWorktree() async throws {
        let root = try makeTemporaryDirectory()
        let repo = try makeGitFixture(in: root)
        let linkedWorktree = root.appendingPathComponent("repo-linked", isDirectory: true)
        try runGit(["worktree", "add", "-b", "feature/linked", linkedWorktree.path], cwd: repo)
        let service = VCSService()
        let resolved = VCSResolvedRepo(rootURL: linkedWorktree, backendKind: .git)

        let resolvedContext = await service.gitWorktreeContext(for: linkedWorktree, resolved: resolved, worktrees: nil)
        let context = try XCTUnwrap(resolvedContext)

        XCTAssertFalse(context.isMain)
        XCTAssertEqual(context.checkoutDisplayText, "linked worktree")
        XCTAssertEqual(context.branchDisplayText, "feature/linked")
        XCTAssertTrue(context.tooltipText.contains("Checkout: linked worktree"))

        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: linkedWorktree))
        XCTAssertTrue(layout.isWorktree)
        XCTAssertTrue(layout.isLinkedWorktree)
        XCTAssertNotEqual(layout.gitDir.standardizedFileURL, layout.commonDir.standardizedFileURL)
        XCTAssertEqual(layout.knownMainWorktreeRoot, repo.standardizedFileURL)

        let metadata = GitDiffSnapshotStore().worktreeMetadata(for: linkedWorktree.path)
        XCTAssertEqual(metadata.isWorktree, true)
        XCTAssertEqual(metadata.mainWorktreeRoot, repo.standardizedFileURL.path)
    }

    func testGitStatusActorRefreshesCachedContextForUnchangedRootList() async throws {
        let repo = try makeGitFixture()
        let actor = GitStatusActor(vcsService: VCSService())

        let initial = await actor.updateRoots([repo.path])
        XCTAssertEqual(initial.first?.gitWorktreeContext?.branchDisplayText, "main")

        try runGit(["checkout", "-b", "feature/context-refresh"], cwd: repo)

        let refreshed = await actor.updateRoots([repo.path])
        XCTAssertEqual(refreshed.first?.gitWorktreeContext?.branchDisplayText, "feature/context-refresh")
    }

    func testGitStatusActorSwitchBranchRefreshesSelectedNestedRootInSameCheckout() async throws {
        let root = try makeTemporaryDirectory()
        let targetRepo = try makeGitFixture(name: "target", in: root)
        let selectedNestedRoot = targetRepo.appendingPathComponent("apps/web", isDirectory: true)
        try runGit(["switch", "-c", "feature/non-selected"], cwd: targetRepo)
        try runGit(["switch", "main"], cwd: targetRepo)

        let actor = GitStatusActor(vcsService: VCSService())
        _ = await actor.updateRoots([selectedNestedRoot.path, targetRepo.path])
        await actor.setSelectedRoot(selectedNestedRoot.path)
        let initialSnapshot = await actor.getLatestSnapshot()
        XCTAssertEqual(initialSnapshot?.gitWorktreeContext?.branchDisplayText, "main")

        let preflight = try await actor.preflightGitBranchSwitch(
            branchName: "feature/non-selected",
            forRootPath: targetRepo.path
        )
        let (_, context) = try await actor.switchGitBranch(
            GitBranchSwitchRequest(
                branchName: "feature/non-selected",
                expectedCurrentBranch: preflight.currentBranch,
                expectedCurrentHead: preflight.currentHead
            ),
            forRootPath: targetRepo.path
        )

        XCTAssertEqual(context?.branchDisplayText, "feature/non-selected")
        let refreshedSnapshot = await actor.getLatestSnapshot()
        XCTAssertEqual(refreshedSnapshot?.rootPath, selectedNestedRoot.path)
        XCTAssertEqual(refreshedSnapshot?.gitWorktreeContext?.branchDisplayText, "feature/non-selected")
    }

    private func makeGitFixture(name: String = "repo", in existingRoot: URL? = nil) throws -> URL {
        let root = if let existingRoot {
            existingRoot
        } else {
            try makeTemporaryDirectory()
        }
        let repo = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], cwd: repo)
        try runGit(["config", "user.email", "test@example.com"], cwd: repo)
        try runGit(["config", "user.name", "Test User"], cwd: repo)
        let nested = repo.appendingPathComponent("apps/web", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "hello\n".write(to: nested.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: repo)
        try runGit(["commit", "-m", "Initial commit"], cwd: repo)
        return repo
    }

    private func makeSeparateGitDirFixture() throws -> (repo: URL, gitDir: URL) {
        let root = try makeTemporaryDirectory()
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let gitDir = root.appendingPathComponent("repo-git", isDirectory: true)
        try runGit([
            "init",
            "-b", "main",
            "--separate-git-dir", gitDir.path,
            repo.path
        ], cwd: root)
        try runGit(["config", "user.email", "test@example.com"], cwd: repo)
        try runGit(["config", "user.name", "Test User"], cwd: repo)
        try "hello\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: repo)
        try runGit(["commit", "-m", "Initial commit"], cwd: repo)
        return (repo, gitDir)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitWorktreeContextResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoot = root
        return root
    }

    private func runGit(_ arguments: [String], cwd: URL) throws {
        _ = try runGitResult(arguments, cwd: cwd)
    }

    private func runGitResult(
        _ arguments: [String],
        cwd: URL,
        requireSuccess: Bool = true
    ) throws -> TestProcessResult {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let result = try TestProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectoryURL: cwd,
            environment: environment
        )
        guard !requireSuccess || result.terminationStatus == 0 else {
            throw NSError(
                domain: "GitWorktreeContextResolverTests",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(result.outputText)"]
            )
        }
        return result
    }
}

final class GitWorktreeContextSummaryTests: XCTestCase {
    func testNormalBranchUsesBranchInBreadcrumbTooltipAndAccessibility() {
        let summary = makeSummary(branch: "main", head: "1234567890abcdef", isDetached: false)

        XCTAssertEqual(summary.branchDisplayText, "main")
        XCTAssertEqual(summary.breadcrumbText, "Repo / repo / main")
        XCTAssertEqual(summary.checkoutDisplayText, "main repository checkout")
        XCTAssertEqual(summary.tooltipText, """
        Repository: Repo
        Checkout: main repository checkout
        Worktree: repo
        Branch: main
        Path: /tmp/repo
        """)
        XCTAssertFalse(summary.tooltipText.contains("HEAD:"))
        XCTAssertFalse(summary.tooltipText.contains("1234567890abcdef"))
        XCTAssertFalse(summary.tooltipText.contains("Click to switch local branches"))
        XCTAssertTrue(summary.accessibilityText.contains("main repository checkout repo"))
        XCTAssertTrue(summary.accessibilityText.contains("branch main"))
    }

    func testDetachedHeadUsesShortShaDisplay() {
        let summary = makeSummary(branch: nil, head: "abcdef1234567890", isDetached: true)

        XCTAssertEqual(summary.branchDisplayText, "detached @ abcdef1")
        XCTAssertEqual(summary.breadcrumbText, "Repo / repo / detached @ abcdef1")
        XCTAssertTrue(summary.tooltipText.contains("Branch: detached @ abcdef1"))
        XCTAssertFalse(summary.tooltipText.contains("HEAD:"))
        XCTAssertFalse(summary.tooltipText.contains("abcdef1234567890"))
    }

    func testMissingBranchWithKnownHeadUsesHeadFallback() {
        let summary = makeSummary(branch: nil, head: "fedcba9876543210", isDetached: false)

        XCTAssertEqual(summary.branchDisplayText, "HEAD @ fedcba9")
        XCTAssertEqual(summary.breadcrumbText, "Repo / repo / HEAD @ fedcba9")
        XCTAssertTrue(summary.tooltipText.contains("Branch: HEAD @ fedcba9"))
        XCTAssertFalse(summary.tooltipText.contains("HEAD:"))
        XCTAssertFalse(summary.tooltipText.contains("fedcba9876543210"))
    }

    func testUnknownBranchIsOnlySurfacedInTooltipAndAccessibility() {
        let summary = makeSummary(branch: nil, head: nil, isDetached: false)

        XCTAssertNil(summary.branchDisplayText)
        XCTAssertEqual(summary.breadcrumbText, "Repo / repo")
        XCTAssertTrue(summary.tooltipText.contains("Checkout: main repository checkout"))
        XCTAssertTrue(summary.tooltipText.contains("Branch: unknown branch"))
        XCTAssertTrue(summary.accessibilityText.contains("branch unknown branch"))
    }

    func testLinkedWorktreeCheckoutTextIsSurfacedInTooltipAndAccessibility() {
        let summary = makeSummary(isMain: false, branch: "feature/x", head: "1234567890abcdef", isDetached: false)

        XCTAssertFalse(summary.isMain)
        XCTAssertEqual(summary.checkoutDisplayText, "linked worktree")
        XCTAssertTrue(summary.tooltipText.contains("Checkout: linked worktree"))
        XCTAssertTrue(summary.accessibilityText.contains("linked worktree repo"))
    }

    func testDescriptorConversionPreservesMainAndLinkedWorktreeStatus() {
        let mainSummary = GitWorktreeContextSummary(descriptor: makeDescriptor(isMain: true, name: "repo", branch: "main"))
        let linkedSummary = GitWorktreeContextSummary(descriptor: makeDescriptor(isMain: false, name: "repo-feature", branch: "feature/x"))

        XCTAssertTrue(mainSummary.isMain)
        XCTAssertEqual(mainSummary.checkoutDisplayText, "main repository checkout")
        XCTAssertTrue(mainSummary.tooltipText.contains("Checkout: main repository checkout"))
        XCTAssertFalse(linkedSummary.isMain)
        XCTAssertEqual(linkedSummary.checkoutDisplayText, "linked worktree")
        XCTAssertTrue(linkedSummary.tooltipText.contains("Checkout: linked worktree"))
    }

    private func makeSummary(
        isMain: Bool = true,
        branch: String?,
        head: String?,
        isDetached: Bool
    ) -> GitWorktreeContextSummary {
        GitWorktreeContextSummary(
            repositoryID: "gitrepo-test",
            repoKey: "repo-test",
            repositoryDisplayName: "Repo",
            worktreeID: "wt-test",
            worktreePath: "/tmp/repo",
            worktreeName: "repo",
            isMain: isMain,
            branch: branch,
            head: head,
            isDetached: isDetached
        )
    }

    private func makeDescriptor(
        isMain: Bool,
        name: String,
        branch: String?
    ) -> GitWorktreeDescriptor {
        let repository = GitWorktreeRepositoryIdentity(
            repositoryID: "gitrepo-test",
            repoKey: "repo-test",
            displayName: "Repo",
            commonGitDir: "/tmp/repo/.git",
            mainWorktreeRoot: "/tmp/repo"
        )
        return GitWorktreeDescriptor(
            worktreeID: isMain ? "wt-main" : "wt-linked",
            repository: repository,
            path: isMain ? "/tmp/repo" : "/tmp/repo-feature",
            gitDir: isMain ? "/tmp/repo/.git" : "/tmp/repo/.git/worktrees/repo-feature",
            name: name,
            branch: branch,
            head: "1234567890abcdef",
            isMain: isMain,
            isCurrent: true,
            isDetached: false,
            isLocked: false,
            lockReason: nil,
            isPrunable: false,
            prunableReason: nil
        )
    }
}
