@testable import RepoPrompt
import XCTest

#if DEBUG
    final class GitCommandWorkCountDiagnosticsTests: XCTestCase {
        func testWarmStatusUsesOnePorcelainV2GitProcess() async throws {
            let fixture = try GitWorkCountFixture()
            defer { fixture.cleanup() }
            let git = GitService()

            let snapshot = try await capture(operation: "status") {
                _ = try await git.getRepositoryStatus(at: fixture.repo)
            }

            XCTAssertEqual(snapshot.commandCount, 1, snapshot.commands.joined(separator: "\n"))
            XCTAssertEqual(snapshot.commands, ["status --porcelain=v2 -z --branch"])
            XCTAssertEqual(snapshot.repositories, [fixture.repo.path])
            XCTAssertGreaterThan(snapshot.outputBytes, 0)
            XCTAssertGreaterThanOrEqual(snapshot.spawnMicroseconds, 0)
            XCTAssertGreaterThanOrEqual(snapshot.parseMicroseconds, 0)
        }

        func testUncommittedSummaryUsesFiveGitProcesses() async throws {
            let fixture = try GitWorkCountFixture()
            defer { fixture.cleanup() }
            let vcs = VCSService()
            let engine = GitDiffEngine(vcsService: vcs, gitService: GitService())

            let snapshot = try await capture(operation: "diff_summary") {
                _ = try await engine.buildSnapshotInputs(
                    compare: .uncommitted(base: "HEAD"),
                    scope: .all,
                    selectedAbsolutePaths: [],
                    repoURL: fixture.repo,
                    contextLines: 3,
                    detectRenames: false,
                    generateDiffText: false
                )
            }

            XCTAssertEqual(snapshot.commandCount, 5, snapshot.commands.joined(separator: "\n"))
            XCTAssertEqual(snapshot.commandCountsByRepository, [fixture.repo.path: 5])
        }

        func testArtifactModesShowWI9CommandCountReductions() async throws {
            let fixture = try GitWorkCountFixture()
            defer { fixture.cleanup() }
            let vcs = VCSService()
            let engine = GitDiffEngine(vcsService: vcs, gitService: GitService())
            let publisher = GitDiffSnapshotPublisher(
                engine: engine,
                store: GitDiffSnapshotStore(),
                vcsService: vcs
            )
            let repo = GitRepoDescriptor(rootURL: fixture.repo)

            for (mode, wi3Baseline, wi9Expected) in [
                (GitDiffPublishMode.quick, 7, 6),
                (.standard, 15, 8),
                (.deep, 15, 8)
            ] {
                let snapshot = try await capture(operation: "artifact_\(mode.rawValue)") {
                    _ = try await publisher.publish(
                        workspaceDirectory: fixture.workspace,
                        repo: repo,
                        mode: mode,
                        compareSpec: .uncommitted(base: "HEAD"),
                        compareDisplay: "uncommitted:HEAD",
                        compareInput: nil,
                        scope: .all,
                        selectedAbsolutePaths: [],
                        contextLines: 3,
                        detectRenames: false,
                        snapshotIDOverride: "wi3-\(mode.rawValue)-\(UUID().uuidString)",
                        tabID: nil
                    )
                }
                XCTAssertEqual(
                    snapshot.commandCount,
                    wi9Expected,
                    "\(mode.rawValue) WI-3 baseline=\(wi3Baseline), WI-9 expected=\(wi9Expected):\n\(snapshot.commands.joined(separator: "\n"))"
                )
                if mode != .quick {
                    XCTAssertLessThan(snapshot.commandCount, wi3Baseline)
                }
            }
        }

        func testBatchedUntrackedDiffPreservesRepositoryRelativePatchPaths() async throws {
            let fixture = try GitWorkCountFixture()
            defer { fixture.cleanup() }
            try fixture.writeUntracked("Nested/Second File.txt", contents: "second\n")

            let diff = try await GitService().getUntrackedDiff(
                for: ["Untracked.txt", "Nested/Second File.txt"],
                contextLines: 3,
                at: fixture.repo
            )

            XCTAssertTrue(diff.contains("diff --git a/Untracked.txt b/Untracked.txt"), diff)
            XCTAssertTrue(diff.contains("Nested/Second File.txt"), diff)
            XCTAssertFalse(diff.contains("a/./"), diff)
            XCTAssertFalse(diff.contains("b/./"), diff)
        }

        func testFullDiffBatchesMultipleUntrackedFilesIntoOneGitProcess() async throws {
            let fixture = try GitWorkCountFixture()
            defer { fixture.cleanup() }
            try fixture.writeUntracked("Nested/Second.txt", contents: "second\n")
            try fixture.writeUntracked("Third.txt", contents: "third\n")
            let engine = GitDiffEngine(vcsService: VCSService(), gitService: GitService())

            let snapshot = try await capture(operation: "diff_full") {
                _ = try await engine.buildSnapshotInputs(
                    compare: .uncommitted(base: "HEAD"),
                    scope: .all,
                    selectedAbsolutePaths: [],
                    repoURL: fixture.repo,
                    contextLines: 3,
                    detectRenames: false,
                    generateDiffText: true
                )
            }

            XCTAssertEqual(snapshot.commandCount, 7, snapshot.commands.joined(separator: "\n"))
            XCTAssertEqual(snapshot.commandCountsByRepository, [fixture.repo.path: 7])
            XCTAssertEqual(snapshot.commands.count(where: { $0.hasPrefix("diff --no-index") }), 1)
        }

        private func capture(
            operation: String,
            body: () async throws -> Void
        ) async throws -> MCPToolWorkCountDiagnostics.GitInvocationSnapshot {
            MCPToolWorkCountDiagnostics.resetForTesting()
            try await MCPToolWorkCountDiagnostics.withGitInvocation(operation: operation, body)
            return try XCTUnwrap(MCPToolWorkCountDiagnostics.debugSnapshots().git.last)
        }
    }

    private struct GitWorkCountFixture {
        let sandbox: URL
        let repo: URL
        let workspace: URL

        init() throws {
            sandbox = FileManager.default.temporaryDirectory
                .appendingPathComponent("GitCommandWorkCountDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
            repo = sandbox.appendingPathComponent("repo", isDirectory: true).standardizedFileURL
            workspace = sandbox.appendingPathComponent("workspace", isDirectory: true).standardizedFileURL
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try runGit(["init"], cwd: repo)
            try runGit(["config", "user.name", "RepoPrompt Test"], cwd: repo)
            try runGit(["config", "user.email", "repoprompt@example.test"], cwd: repo)
            try runGit(["config", "commit.gpgSign", "false"], cwd: repo)
            try runGit(["checkout", "-b", "main"], cwd: repo)
            try "base\n".write(to: repo.appendingPathComponent("Tracked.txt"), atomically: true, encoding: .utf8)
            try runGit(["add", "Tracked.txt"], cwd: repo)
            try runGit(["commit", "-m", "Initial commit"], cwd: repo)
            try "changed\n".write(to: repo.appendingPathComponent("Tracked.txt"), atomically: true, encoding: .utf8)
            try "untracked\n".write(to: repo.appendingPathComponent("Untracked.txt"), atomically: true, encoding: .utf8)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: sandbox)
        }

        func writeUntracked(_ relativePath: String, contents: String) throws {
            let url = repo.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
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
                    domain: "GitCommandWorkCountDiagnosticsTests.git",
                    code: Int(result.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: result.outputText]
                )
            }
        }
    }
#endif
