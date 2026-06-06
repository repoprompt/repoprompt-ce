@testable import RepoPrompt
import XCTest

final class GitWorktreeMergePreviewPublisherTests: XCTestCase {
    func testPreviewPublishesDiffSnapshotAndMergeSidecar() async throws {
        let fixture = try GitMergePreviewFixture()
        defer { fixture.cleanup() }
        try fixture.commitFile("Source.txt", contents: "source\n", message: "Source change", cwd: fixture.source)

        let git = GitService()
        let source = try await fixture.endpoint(for: fixture.source, using: git)
        let target = try await fixture.endpoint(for: fixture.repo, using: git)
        let preview = try await VCSService().previewGitWorktreeMerge(.init(
            source: source,
            target: target,
            workspaceDirectory: fixture.workspace,
            contextLines: 2,
            publishArtifacts: true
        ))

        XCTAssertFalse(preview.operationID.isEmpty)
        let artifacts = try XCTUnwrap(preview.artifacts)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.manifestPath), artifacts.manifestPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.mapPath), artifacts.mapPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.sidecarPath), artifacts.sidecarPath)
        let allPatch = try XCTUnwrap(artifacts.allPatchPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: allPatch), allPatch)

        let sidecarData = try Data(contentsOf: URL(fileURLWithPath: artifacts.sidecarPath))
        let sidecarObject = try XCTUnwrap(JSONSerialization.jsonObject(with: sidecarData) as? [String: Any])
        XCTAssertEqual(sidecarObject["operationID"] as? String, preview.operationID)
        XCTAssertEqual(sidecarObject["sourceHead"] as? String, source.head)
        XCTAssertEqual(sidecarObject["targetHead"] as? String, target.head)
        XCTAssertEqual((sidecarObject["summary"] as? [String: Any])?["files"] as? Int, 1)
        XCTAssertTrue((sidecarObject["visualization"] as? String)?.contains("merge preview") ?? false)
    }
}

private struct GitMergePreviewFixture {
    let sandbox: URL
    let repo: URL
    let source: URL
    let workspace: URL

    init() throws {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitWorktreeMergePreviewPublisherTests-\(suffix)", isDirectory: true)
        repo = sandbox.appendingPathComponent("repo", isDirectory: true).standardizedFileURL
        source = sandbox.appendingPathComponent("source", isDirectory: true).standardizedFileURL
        workspace = sandbox.appendingPathComponent("workspace", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Self.runGit(["init"], cwd: repo)
        try Self.runGit(["config", "user.name", "RepoPrompt Test"], cwd: repo)
        try Self.runGit(["config", "user.email", "repoprompt@example.test"], cwd: repo)
        try Self.runGit(["config", "commit.gpgSign", "false"], cwd: repo)
        try Self.runGit(["checkout", "-b", "main"], cwd: repo)
        try "base\n".write(to: repo.appendingPathComponent("Common.txt"), atomically: true, encoding: .utf8)
        try Self.runGit(["add", "Common.txt"], cwd: repo)
        try Self.runGit(["commit", "-m", "Initial commit"], cwd: repo)
        try Self.runGit(["worktree", "add", "-b", "feature/source", source.path, "HEAD"], cwd: repo)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func endpoint(for path: URL, using git: GitService) async throws -> GitWorktreeMergeEndpoint {
        let worktrees = try await git.listWorktrees(at: repo)
        let standardized = path.standardizedFileURL.path
        let descriptor = try XCTUnwrap(worktrees.first { $0.path == standardized })
        return try GitWorktreeMergeEndpoint(descriptor: descriptor)
    }

    func commitFile(_ relativePath: String, contents: String, message: String, cwd: URL) throws {
        let url = cwd.appendingPathComponent(relativePath)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try Self.runGit(["add", relativePath], cwd: cwd)
        try Self.runGit(["commit", "-m", message], cwd: cwd)
    }

    private static func runGit(_ arguments: [String], cwd: URL) throws {
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
                domain: "GitWorktreeMergePreviewPublisherTests.git",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(result.outputText)"]
            )
        }
    }
}
