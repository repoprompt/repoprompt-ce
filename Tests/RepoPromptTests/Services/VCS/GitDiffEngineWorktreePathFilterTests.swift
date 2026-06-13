import Foundation
@testable import RepoPrompt
import XCTest

final class GitDiffEngineWorktreePathFilterTests: XCTestCase {
    func testAbsolutePathFilterInLinkedWorktreeMatchesUnfilteredDiff() async throws {
        let fixture = try LinkedWorktreeDiffFixture()
        defer { fixture.cleanup() }
        let engine = GitDiffEngine(vcsService: VCSService(), gitService: GitService())

        let unfiltered = try await engine.buildSnapshotInputs(
            compare: .uncommitted(base: "HEAD"),
            pathspecs: nil,
            repoURL: fixture.worktree,
            contextLines: 3,
            detectRenames: false,
            generateDiffText: true
        )
        let filtered = try await engine.buildSnapshotInputs(
            compare: .uncommitted(base: "HEAD"),
            pathspecs: [fixture.changedFile.path],
            repoURL: fixture.worktree,
            contextLines: 3,
            detectRenames: false,
            generateDiffText: true
        )

        XCTAssertEqual(unfiltered.changedFiles.map(\.path), [fixture.relativePath])
        XCTAssertEqual(filtered.changedFiles, unfiltered.changedFiles)
        XCTAssertEqual(filtered.summary.files, unfiltered.summary.files)
        XCTAssertEqual(filtered.summary.insertions, unfiltered.summary.insertions)
        XCTAssertEqual(filtered.summary.deletions, unfiltered.summary.deletions)
        XCTAssertEqual(filtered.requestedPaths, [fixture.relativePath])
        XCTAssertEqual(filtered.perFile, unfiltered.perFile)
    }
}

private struct LinkedWorktreeDiffFixture {
    let sandbox: URL
    let repo: URL
    let worktree: URL
    let relativePath = "Sources/Feature.swift"

    var changedFile: URL {
        worktree.appendingPathComponent(relativePath)
    }

    init() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitDiffEngineWorktreePathFilterTests-\(UUID().uuidString)", isDirectory: true)
        repo = sandbox.appendingPathComponent("repo", isDirectory: true).standardizedFileURL
        worktree = sandbox.appendingPathComponent("linked", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init"], cwd: repo)
        try runGit(["config", "user.name", "RepoPrompt Test"], cwd: repo)
        try runGit(["config", "user.email", "repoprompt@example.test"], cwd: repo)
        try runGit(["config", "commit.gpgSign", "false"], cwd: repo)
        try runGit(["checkout", "-b", "main"], cwd: repo)

        let initialFile = repo.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: initialFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "let value = 1\n".write(to: initialFile, atomically: true, encoding: .utf8)
        try runGit(["add", relativePath], cwd: repo)
        try runGit(["commit", "-m", "Initial commit"], cwd: repo)
        try runGit(["worktree", "add", "-b", "feature/linked", worktree.path, "HEAD"], cwd: repo)
        try "let value = 2\n".write(to: changedFile, atomically: true, encoding: .utf8)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func runGit(_ arguments: [String], cwd: URL) throws {
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
        guard result.terminationStatus == 0 else {
            throw NSError(
                domain: "GitDiffEngineWorktreePathFilterTests.git",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: result.outputText]
            )
        }
    }
}
