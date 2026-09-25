import Foundation
@testable import RepoPromptApp
import XCTest

/// Pins how often the jj backend snapshots the working copy.
///
/// Every jj command snapshots by default, scanning all tracked files and rewriting
/// `.jj/working_copy` state. Most tests drive the backend through a scripted executor, so
/// they need no jj installation and assert the exact commands jj would have received. One
/// test runs the real jj CLI and is skipped where jj is not installed.
final class JujutsuSnapshotPolicyTests: XCTestCase {
    private static let ignoreWorkingCopy = "--ignore-working-copy"

    /// A path that never exists, so no stray `.git` there can make it look colocated.
    private let probeRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("jj-policy-probe-\(UUID().uuidString)", isDirectory: true)

    // MARK: - Runner

    func testRecordedPolicyPlacesFlagBeforeSubcommandSoTrailingPathsCannotSwallowIt() async throws {
        let log = JJInvocationLog()
        let runner = makeRunner(log: log)
        let repo = probeRoot

        _ = try await runner.run(["diff", "--stat", "--", "a.swift"], at: repo, workingCopy: .recorded)
        _ = try await runner.run(["diff", "--stat", "--", "a.swift"], at: repo, workingCopy: .snapshot)

        let invocations = await log.invocations
        XCTAssertEqual(invocations.first, [Self.ignoreWorkingCopy, "diff", "--stat", "--", "a.swift"])
        XCTAssertEqual(invocations.last, ["diff", "--stat", "--", "a.swift"])
    }

    // MARK: - Current bookmark

    func testCurrentBranchIsResolvedInOneProcessRegardlessOfBookmarkCount() async throws {
        let log = JJInvocationLog()
        let manyBookmarks = (0 ..< 120).map { "feature-\($0): abcdefgh 12345678 work \($0)" }
        let backend = JujutsuBackend(runner: makeRunner(
            log: log,
            allBookmarks: manyBookmarks.joined(separator: "\n") + "\n",
            bookmarksAtWorkingCopy: "zeta\nalpha"
        ))

        let branch = try await backend.getCurrentBranch(at: probeRoot)

        XCTAssertEqual(branch, "alpha", "The first local bookmark at @ in sorted order.")
        let invocations = await log.invocations
        XCTAssertEqual(invocations.count, 2, "One bookmark list plus one current read: \(invocations)")
        XCTAssertTrue(invocations.allSatisfy { $0.first == Self.ignoreWorkingCopy })
        XCTAssertTrue(perBookmarkLookups(in: invocations).isEmpty)
    }

    func testCurrentBranchIsUnknownWithoutAFallbackLoopWhenTheCurrentReadFails() async throws {
        let log = JJInvocationLog()
        let backend = JujutsuBackend(runner: makeRunner(log: log, currentReadExitCode: 1))

        let branch = try await backend.getCurrentBranch(at: probeRoot)

        XCTAssertNil(branch)
        let invocations = await log.invocations
        XCTAssertEqual(invocations.count, 2, "A failed read must not fall back to per-bookmark lookups.")
        XCTAssertTrue(perBookmarkLookups(in: invocations).isEmpty)
    }

    func testCurrentReadIsSkippedWhenTheRepositoryHasNoBookmarks() async throws {
        let log = JJInvocationLog()
        let backend = JujutsuBackend(runner: makeRunner(log: log, allBookmarks: ""))

        let branch = try await backend.getCurrentBranch(at: probeRoot)

        XCTAssertNil(branch)
        let invocations = await log.invocations
        XCTAssertEqual(invocations.count, 1, "Only the bookmark list runs: \(invocations)")
    }

    // MARK: - Status refresh

    /// The status poll runs this refresh every few seconds per window, so the number of
    /// working-copy snapshots it takes is the cost that matters.
    func testStatusRefreshSnapshotsTheWorkingCopyExactlyOnce() async throws {
        let (invocations, snapshot) = try await coldRefresh(colocated: false)

        let snapshotting = invocations.filter { $0.first != Self.ignoreWorkingCopy }
        XCTAssertEqual(snapshotting.count, 1, "Exactly one command may snapshot: \(snapshotting)")
        XCTAssertEqual(Array(snapshotting.first?.prefix(2) ?? []), ["diff", "--summary"])

        let summaryIndex = try XCTUnwrap(invocations.firstIndex { $0.prefix(2) == ["diff", "--summary"] })
        let statIndex = try XCTUnwrap(invocations.firstIndex { $0.dropFirst().prefix(2) == ["diff", "--stat"] })
        XCTAssertLessThan(summaryIndex, statIndex, "The stat read reuses the summary's snapshot.")
        XCTAssertTrue(perBookmarkLookups(in: invocations).isEmpty)
        XCTAssertTrue(indices(of: ["git", "import"], in: invocations).isEmpty, "Only colocated workspaces import.")
        XCTAssertEqual(invocations.count, 5, "summary, stat, two bookmark lists, current read: \(invocations)")

        XCTAssertEqual(snapshot.currentBranch, "main")
        XCTAssertEqual(snapshot.unstagedFiles.map(\.path), ["Sources/App.swift"])
        XCTAssertEqual(snapshot.totalAdditions, 2)
        XCTAssertEqual(snapshot.totalDeletions, 1)
    }

    /// In a colocated workspace jj imports changes made with plain `git` only while snapshotting,
    /// so there the bookmark lists keep snapshotting, as before, and nothing else is added.
    func testColocatedRefreshSnapshotsTheBookmarkListsSoGitSideChangesAreImported() async throws {
        let (invocations, snapshot) = try await coldRefresh(colocated: true)

        let snapshotting = invocations.filter { $0.first != Self.ignoreWorkingCopy }
        XCTAssertEqual(
            Set(snapshotting.map { Array($0.prefix(3)) }),
            [["diff", "--summary", "--color=never"], ["bookmark", "list", "--color=never"]],
            "Only the summary and the two bookmark lists snapshot: \(snapshotting)"
        )
        XCTAssertEqual(snapshotting.count, 3)
        XCTAssertEqual(indices(of: ["bookmark", "list"], in: snapshotting).count, 2)
        XCTAssertTrue(indices(of: ["git", "import"], in: invocations).isEmpty, "Never import under --ignore-working-copy.")

        let allList = try XCTUnwrap(invocations.firstIndex { $0.prefix(2) == ["bookmark", "list"] && $0.contains("--all") })
        let currentRead = try XCTUnwrap(invocations.firstIndex { command(of: $0).prefix(3) == ["log", "-r", "@"] })
        XCTAssertEqual(invocations[currentRead].first, Self.ignoreWorkingCopy, "The current read reuses the list's snapshot.")
        XCTAssertLessThan(allList, currentRead)
        XCTAssertEqual(invocations.count, 5, "summary, stat, two bookmark lists, current read: \(invocations)")
        XCTAssertEqual(snapshot.currentBranch, "main")
    }

    // MARK: - Reads that stay snapshotting

    func testLiveReadsAndFetchStillSnapshot() async throws {
        let log = JJInvocationLog()
        let backend = JujutsuBackend(runner: makeRunner(log: log))
        let repo = probeRoot

        _ = try await backend.getDiffText(
            compare: .uncommitted(base: "HEAD"),
            paths: nil,
            contextLines: 3,
            detectRenames: false,
            at: repo
        )
        _ = try await backend.getWorkingStatus(at: repo)
        _ = try await backend.getStatusFingerprint(at: repo, baseRef: "HEAD")
        try await backend.fetch(at: repo)

        let invocations = await log.invocations
        XCTAssertEqual(invocations.count, 5, "diff text, working status, fingerprint head + summary, fetch: \(invocations)")
        XCTAssertTrue(
            invocations.allSatisfy { $0.first != Self.ignoreWorkingCopy },
            "Live reads and the one write command (fetch) must not skip the snapshot: \(invocations)"
        )
    }

    func testDiffGitFallbackReusesTheSummarySnapshot() async throws {
        let log = JJInvocationLog()
        let backend = JujutsuBackend(runner: makeRunner(log: log, statOutput: "stat output jj did not recognise\n"))

        _ = try await backend.getChangedFilesStats(
            compare: .uncommitted(base: "HEAD"),
            includeUntrackedWhenApplicable: true,
            detectRenames: false,
            paths: nil,
            at: probeRoot
        )

        let invocations = await log.invocations
        XCTAssertEqual(
            invocations.map { Array(command(of: $0).prefix(2)) },
            [["diff", "--summary"], ["diff", "--stat"], ["diff", "--git"]]
        )
        XCTAssertEqual(invocations.count(where: { $0.first != Self.ignoreWorkingCopy }), 1, "Only the summary snapshots.")
    }

    // MARK: - Real jj

    // The bookmark template and jj's handling of changes made with plain `git` are jj-facing
    // behaviour a scripted executor cannot check, so these run the real jj CLI when installed.

    func testRealJJReportsTheCurrentBookmarkAndSeesBranchesCreatedWithPlainGit() async throws {
        let repo = try await makeColocatedScratchRepository()
        defer { repo.remove() }
        try repo.jj(["bookmark", "create", "probe", "-r", "@"])

        let current = try await JujutsuBackend(runner: repo.runner).getCurrentBranch(at: repo.root)
        XCTAssertEqual(current, "probe")

        try repo.git(["branch", "plain-git", "main"])
        let branches = try await JujutsuBackend(runner: repo.runner).getLocalBranches(at: repo.root, limit: 50)
        XCTAssertTrue(branches.contains { $0.name == "plain-git" }, "Got \(branches.map(\.name))")
    }

    func testRealJJNeverReportsAConflictedBookmarkAsCurrent() async throws {
        let repo = try await makeColocatedScratchRepository()
        defer { repo.remove() }
        try repo.jj(["bookmark", "create", "probe", "-r", "@"])
        // `cf` becomes conflicted between @ and root(). It sorts before `probe`, so reporting it
        // as current would make it the first name.
        try repo.jj(["bookmark", "create", "cf", "-r", "@-"])
        let operation = try repo.jj(["op", "log", "--no-graph", "--limit", "1", "-T", #"id.short() ++ "\n""#])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try repo.jj(["bookmark", "set", "cf", "-r", "@"])
        try repo.jj(["--at-op", operation, "--ignore-working-copy", "bookmark", "set", "cf", "-r", "root()", "--allow-backwards"])
        guard try repo.jj(["bookmark", "list", "--color=never"]).contains("cf (conflicted)") else {
            throw XCTSkip("This jj version did not produce a conflicted bookmark from concurrent operations.")
        }

        let current = try await JujutsuBackend(runner: repo.runner).getCurrentBranch(at: repo.root)
        XCTAssertEqual(current, "probe")
    }

    /// A status poll must never undo a commit made with plain git: jj should move @ onto the new
    /// git HEAD, and git HEAD must stay where the user put it.
    func testRealJJBookmarkReadsFollowAPlainGitCommitWithoutMovingGitHead() async throws {
        let repo = try await makeColocatedScratchRepository()
        defer { repo.remove() }
        try repo.git(["commit", "-q", "--allow-empty", "-m", "made with git"])
        let gitHead = try repo.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

        let backend = JujutsuBackend(runner: repo.runner)
        _ = try await backend.getCurrentBranch(at: repo.root)
        _ = try await backend.getLocalBranches(at: repo.root, limit: 50)
        _ = await backend.hasRemoteTrackingRef(named: "main@origin", at: repo.root)

        XCTAssertEqual(try repo.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines), gitHead)
        XCTAssertEqual(try repo.git(["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines), "main")
        let parentOfWorkingCopy = try repo.jj(["--ignore-working-copy", "log", "-r", "@-", "--no-graph", "-T", "commit_id"])
        XCTAssertEqual(parentOfWorkingCopy, gitHead, "jj must follow the new git HEAD, as a snapshot does.")
    }

    // MARK: - Helpers

    /// Runs one refresh with cold caches against a scratch jj root and returns every jj
    /// invocation it made together with the resulting snapshot.
    private func coldRefresh(colocated: Bool) async throws -> ([[String]], GitStatusActor.GitStatusSnapshot) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jj-snapshot-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".jj", isDirectory: true),
            withIntermediateDirectories: true
        )
        if colocated {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(".git", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let log = JJInvocationLog()
        let service = VCSService(jjRunner: makeRunner(log: log))
        let status = GitStatusActor(vcsService: service, diffEngine: GitDiffEngine(vcsService: service))
        let detections = await status.updateRoots([root.path])
        XCTAssertEqual(detections.first?.backendKind, .jujutsu, "jj is preferred when .jj and .git coexist.")

        // Selecting the root runs one refresh with cold caches.
        await status.setSelectedRoot(root.path)
        // The stream replays the latest snapshot to a new subscriber.
        var snapshots = status.statusStream.makeAsyncIterator()
        let latest = await snapshots.next()
        return try await (log.invocations, XCTUnwrap(latest))
    }

    /// The jj subcommand and its arguments, without the runner's global working-copy flag.
    private func command(of invocation: [String]) -> [String] {
        invocation.first == Self.ignoreWorkingCopy ? Array(invocation.dropFirst()) : invocation
    }

    private func indices(of prefix: [String], in invocations: [[String]]) -> [Int] {
        invocations.indices.filter { command(of: invocations[$0]).prefix(prefix.count) == prefix[...] }
    }

    /// `jj log -r <bookmark>` calls: the per-bookmark resolution this backend must not do.
    private func perBookmarkLookups(in invocations: [[String]]) -> [[String]] {
        invocations.filter { invocation in
            let command = command(of: invocation)
            return command.prefix(2) == ["log", "-r"] && command.dropFirst(2).first != "@"
        }
    }

    /// A scratch git repository with a colocated jj workspace, driven by the real jj CLI.
    private struct ScratchRepository {
        let root: URL
        let runner: JJCommandRunner
        let jjPath: String

        @discardableResult
        func jj(_ arguments: [String]) throws -> String {
            try run(jjPath, arguments)
        }

        @discardableResult
        func git(_ arguments: [String]) throws -> String {
            try run("/usr/bin/git", arguments)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private func run(_ executable: String, _ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = root
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in [
                "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
                "JJ_USER": "t", "JJ_EMAIL": "t@t"
            ] {
                environment[key] = value
            }
            process.environment = environment
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let stdout = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: stderr, encoding: .utf8) ?? ""
                throw ScratchRepositoryError("\(executable) \(arguments.joined(separator: " ")) failed: \(message)")
            }
            return String(data: stdout, encoding: .utf8) ?? ""
        }
    }

    private struct ScratchRepositoryError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }

    /// Skips when jj is not installed; once it is, any setup failure fails the test.
    private func makeColocatedScratchRepository() async throws -> ScratchRepository {
        let runner = JJCommandRunner()
        guard await runner.isAvailable(), let jjPath = await runner.getExecutablePath() else {
            throw XCTSkip("jj is not installed")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jj-real-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = ScratchRepository(root: root, runner: runner, jjPath: jjPath)
        do {
            try repo.git(["init", "-q", "-b", "main"])
            try repo.git(["commit", "-q", "--allow-empty", "-m", "init"])
            try repo.jj(["git", "init", "--colocate"])
        } catch {
            repo.remove()
            throw error
        }
        return repo
    }

    private func makeRunner(
        log: JJInvocationLog,
        allBookmarks: String = """
        core: vwzyxozr 38f2602e docs: scope claims
          @git: vwzyxozr 38f2602e docs: scope claims
          @origin: vwzyxozr 38f2602e docs: scope claims
        main: qpvuntsm 230dd059 initial

        """,
        bookmarksAtWorkingCopy: String = "main",
        currentReadExitCode: Int32 = 0,
        statOutput: String = "Sources/App.swift | 3 ++-\n1 file changed, 2 insertions(+), 1 deletion(-)\n"
    ) -> JJCommandRunner {
        JJCommandRunner { arguments, _, _ in
            await log.record(arguments)
            let command = arguments.first == Self.ignoreWorkingCopy ? Array(arguments.dropFirst()) : arguments
            switch (command.first, command.dropFirst().first) {
            case ("diff"?, "--summary"?):
                return ("M Sources/App.swift\n", "", 0)
            case ("diff"?, "--stat"?):
                return (statOutput, "", 0)
            case ("diff"?, _):
                return ("", "", 0)
            case ("git"?, "fetch"?):
                return ("", "", 0)
            case ("bookmark"?, "list"?):
                return command.contains("--all") ? (allBookmarks, "", 0) : ("core: vwzyxozr 38f2602e docs\n", "", 0)
            case ("log"?, "-r"?) where command.dropFirst(2).first == "@":
                return currentReadExitCode == 0
                    ? (bookmarksAtWorkingCopy, "", 0)
                    : ("", "unsupported template", currentReadExitCode)
            default:
                return ("", "unexpected jj invocation", 1)
            }
        }
    }
}

private actor JJInvocationLog {
    private(set) var invocations: [[String]] = []

    func record(_ arguments: [String]) {
        invocations.append(arguments)
    }
}
