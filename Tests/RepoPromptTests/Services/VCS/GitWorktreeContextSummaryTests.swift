import Foundation
@testable import RepoPrompt
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
        XCTAssertEqual(URL(fileURLWithPath: context.worktreePath).standardizedFileURL.path, repo.standardizedFileURL.path)
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

    private func makeGitFixture() throws -> URL {
        let root = try makeTemporaryDirectory()
        let repo = root.appendingPathComponent("repo", isDirectory: true)
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

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitWorktreeContextResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoot = root
        return root
    }

    private func runGit(_ arguments: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "GitWorktreeContextResolverTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(text)"]
            )
        }
    }
}

final class GitWorktreeContextSummaryTests: XCTestCase {
    func testNormalBranchUsesBranchInBreadcrumbTooltipAndAccessibility() {
        let summary = makeSummary(branch: "main", head: "1234567890abcdef", isDetached: false)

        XCTAssertEqual(summary.branchDisplayText, "main")
        XCTAssertEqual(summary.breadcrumbText, "Repo / repo / main")
        XCTAssertTrue(summary.tooltipText.contains("Branch: main"))
        XCTAssertTrue(summary.accessibilityText.contains("branch main"))
    }

    func testDetachedHeadUsesShortShaDisplay() {
        let summary = makeSummary(branch: nil, head: "abcdef1234567890", isDetached: true)

        XCTAssertEqual(summary.branchDisplayText, "detached @ abcdef1")
        XCTAssertEqual(summary.breadcrumbText, "Repo / repo / detached @ abcdef1")
        XCTAssertTrue(summary.tooltipText.contains("Branch: detached @ abcdef1"))
    }

    func testMissingBranchWithKnownHeadUsesHeadFallback() {
        let summary = makeSummary(branch: nil, head: "fedcba9876543210", isDetached: false)

        XCTAssertEqual(summary.branchDisplayText, "HEAD @ fedcba9")
        XCTAssertEqual(summary.breadcrumbText, "Repo / repo / HEAD @ fedcba9")
        XCTAssertTrue(summary.tooltipText.contains("Branch: HEAD @ fedcba9"))
    }

    func testUnknownBranchIsOnlySurfacedInTooltipAndAccessibility() {
        let summary = makeSummary(branch: nil, head: nil, isDetached: false)

        XCTAssertNil(summary.branchDisplayText)
        XCTAssertEqual(summary.breadcrumbText, "Repo / repo")
        XCTAssertTrue(summary.tooltipText.contains("Branch: unknown branch"))
        XCTAssertTrue(summary.accessibilityText.contains("branch unknown branch"))
    }

    private func makeSummary(
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
            branch: branch,
            head: head,
            isDetached: isDetached
        )
    }
}
