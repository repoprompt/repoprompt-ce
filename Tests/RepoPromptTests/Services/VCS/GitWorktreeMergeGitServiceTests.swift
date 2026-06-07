@testable import RepoPrompt
import XCTest

final class GitWorktreeMergeGitServiceTests: XCTestCase {
    func testMergeBaseAncestorAndCleanNoCommitMergeThenCommit() async throws {
        let fixture = try GitMergeFixture()
        defer { fixture.cleanup() }
        try fixture.commitFile("Source.txt", contents: "source\n", message: "Source change", cwd: fixture.source)

        let git = GitService()
        let source = try await fixture.endpoint(for: fixture.source, using: git)
        let target = try await fixture.endpoint(for: fixture.repo, using: git)

        let base = try await git.getMergeBase(sourceHead: source.head, targetHead: target.head, at: fixture.repo)
        let baseIsSourceAncestor = try await git.isAncestor(base, of: source.head, at: fixture.repo)
        let baseIsTargetAncestor = try await git.isAncestor(base, of: target.head, at: fixture.repo)
        XCTAssertTrue(baseIsSourceAncestor)
        XCTAssertTrue(baseIsTargetAncestor)

        let inspection = try await git.inspectWorktreeMerge(.init(source: source, target: target))
        XCTAssertTrue(inspection.blockers.isEmpty, inspection.blockers.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(inspection.summary.commits, 1)
        XCTAssertTrue([.clean, .unavailable].contains(inspection.conflictPrediction.status))

        let state = try await git.applyNoCommitWorktreeMerge(sourceHead: source.head, at: fixture.repo)
        XCTAssertTrue(state.inProgress)
        XCTAssertEqual(state.mergeHead, source.head)
        XCTAssertEqual(state.conflictFiles, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent("Source.txt").path))

        let commit = try await git.commitWorktreeMerge(message: "Merge source", at: fixture.repo)
        let parents = try fixture.gitOutput(["rev-list", "--parents", "-n", "1", commit], cwd: fixture.repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
        XCTAssertEqual(parents.count, 3)
    }

    func testConflictLeavesMergeHeadAndAbortRestoresTarget() async throws {
        let fixture = try GitMergeFixture()
        defer { fixture.cleanup() }
        try fixture.commitFile("Common.txt", contents: "target\n", message: "Target edit", cwd: fixture.repo)
        try fixture.commitFile("Common.txt", contents: "source\n", message: "Source edit", cwd: fixture.source)

        let git = GitService()
        let source = try await fixture.endpoint(for: fixture.source, using: git)
        let state = try await git.applyNoCommitWorktreeMerge(sourceHead: source.head, at: fixture.repo)

        XCTAssertTrue(state.inProgress)
        XCTAssertEqual(state.mergeHead, source.head)
        XCTAssertEqual(state.conflictFiles, ["Common.txt"])
        XCTAssertTrue(try String(contentsOf: fixture.repo.appendingPathComponent(".git/MERGE_HEAD"), encoding: .utf8).contains(source.head))

        let aborted = try await git.abortWorktreeMerge(at: fixture.repo)
        XCTAssertTrue(aborted)
        let after = try await git.inspectMergeState(at: fixture.repo)
        XCTAssertFalse(after.inProgress)
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent("Common.txt"), encoding: .utf8), "target\n")
    }

    func testConflictResolutionContinueCreatesTwoParentMergeCommit() async throws {
        let fixture = try GitMergeFixture()
        defer { fixture.cleanup() }
        try fixture.commitFile("Common.txt", contents: "target\n", message: "Target edit", cwd: fixture.repo)
        try fixture.commitFile("Common.txt", contents: "source\n", message: "Source edit", cwd: fixture.source)

        let git = GitService()
        let source = try await fixture.endpoint(for: fixture.source, using: git)
        let target = try await fixture.endpoint(for: fixture.repo, using: git)
        _ = try await git.applyNoCommitWorktreeMerge(sourceHead: source.head, at: fixture.repo)
        let unresolved = try await VCSService().continueGitWorktreeMerge(.init(
            source: source,
            target: target,
            sourceHead: source.head,
            targetHeadBefore: target.head
        ))
        XCTAssertEqual(unresolved.status, .failed)
        XCTAssertEqual(unresolved.conflictFiles, ["Common.txt"])

        try "resolved\n".write(to: fixture.repo.appendingPathComponent("Common.txt"), atomically: true, encoding: .utf8)
        try fixture.runGit(["add", "Common.txt"], cwd: fixture.repo)

        let commit = try await git.continueWorktreeMerge(message: "Resolve merge", at: fixture.repo)
        let parents = try fixture.gitOutput(["rev-list", "--parents", "-n", "1", commit], cwd: fixture.repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
        XCTAssertEqual(parents.count, 3)
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent("Common.txt"), encoding: .utf8), "resolved\n")
    }

    func testVCSPreviewApplyCompletesCleanMerge() async throws {
        let fixture = try GitMergeFixture()
        defer { fixture.cleanup() }
        try fixture.commitFile("Source.txt", contents: "source\n", message: "Source change", cwd: fixture.source)

        let preview = try await fixture.preview(publishArtifacts: true)
        let artifacts = try XCTUnwrap(preview.artifacts)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.mapPath), artifacts.mapPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.sidecarPath), artifacts.sidecarPath)
        let result = try await VCSService().applyGitWorktreeMerge(.init(preview: preview))

        XCTAssertEqual(result.status, .completed)
        XCTAssertNotNil(result.mergeCommit)
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent("Source.txt"), encoding: .utf8), "source\n")
        let parents = try fixture.gitOutput(["rev-list", "--parents", "-n", "1", "HEAD"], cwd: fixture.repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
        XCTAssertEqual(parents.count, 3)

        let dirty = try GitMergeFixture()
        defer { dirty.cleanup() }
        try "dirty\n".write(to: dirty.source.appendingPathComponent("Dirty.txt"), atomically: true, encoding: .utf8)
        let dirtyPreview = try await dirty.preview(publishArtifacts: false)
        XCTAssertTrue(dirtyPreview.inspection.isBlocked)
        XCTAssertTrue(dirtyPreview.inspection.blockers.contains { $0.code == .sourceDirty })
    }

    func testPreviewRejectsEndpointHeadChangedBeforeInspection() async throws {
        let fixture = try GitMergeFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let staleSource = try await fixture.endpoint(for: fixture.source, using: git)
        let target = try await fixture.endpoint(for: fixture.repo, using: git)
        try fixture.commitFile("Source.txt", contents: "source\n", message: "Source change", cwd: fixture.source)

        do {
            _ = try await VCSService().previewGitWorktreeMerge(.init(
                source: staleSource,
                target: target,
                workspaceDirectory: fixture.sandbox.appendingPathComponent("workspace", isDirectory: true),
                publishArtifacts: false
            ))
            XCTFail("Expected stale endpoint head to be rejected before preview")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Source worktree HEAD changed"), error.localizedDescription)
        }
    }

    func testDivergentTargetDoesNotAppearAsDeletionInMergeSummary() async throws {
        let fixture = try GitMergeFixture()
        defer { fixture.cleanup() }
        try fixture.commitFile("Target.txt", contents: "target\n", message: "Target change", cwd: fixture.repo)
        try fixture.commitFile("Source.txt", contents: "source\n", message: "Source change", cwd: fixture.source)
        let git = GitService()
        let source = try await fixture.endpoint(for: fixture.source, using: git)
        let target = try await fixture.endpoint(for: fixture.repo, using: git)

        let inspection = try await git.inspectWorktreeMerge(.init(source: source, target: target))

        XCTAssertEqual(inspection.summary.commits, 1)
        XCTAssertEqual(inspection.summary.files, 1)
        XCTAssertEqual(inspection.summary.insertions, 1)
        XCTAssertEqual(inspection.summary.deletions, 0)
    }

    func testVCSApplyRejectsStaleSourceAndTargetHeads() async throws {
        let sourceStale = try GitMergeFixture()
        defer { sourceStale.cleanup() }
        try sourceStale.commitFile("Source.txt", contents: "source\n", message: "Source change", cwd: sourceStale.source)
        let sourceStalePreview = try await sourceStale.preview(publishArtifacts: false)
        try sourceStale.commitFile("Source2.txt", contents: "source 2\n", message: "Source second change", cwd: sourceStale.source)
        let sourceResult = try await VCSService().applyGitWorktreeMerge(.init(preview: sourceStalePreview))
        XCTAssertEqual(sourceResult.status, .stale)
        XCTAssertEqual(sourceResult.staleReason, "Source worktree changed since preview.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceStale.repo.appendingPathComponent("Source.txt").path))

        let targetStale = try GitMergeFixture()
        defer { targetStale.cleanup() }
        try targetStale.commitFile("Source.txt", contents: "source\n", message: "Source change", cwd: targetStale.source)
        let targetStalePreview = try await targetStale.preview(publishArtifacts: false)
        try targetStale.commitFile("Target.txt", contents: "target\n", message: "Target change", cwd: targetStale.repo)
        let targetHeadAfterIntentionalChange = try targetStale.gitOutput(["rev-parse", "HEAD"], cwd: targetStale.repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let targetTreeAfterIntentionalChange = try targetStale.gitOutput(["rev-parse", "HEAD^{tree}"], cwd: targetStale.repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let statusAfterIntentionalChange = try targetStale.gitOutput(["status", "--porcelain"], cwd: targetStale.repo)
        let targetResult = try await VCSService().applyGitWorktreeMerge(.init(preview: targetStalePreview))
        XCTAssertEqual(targetResult.status, .stale)
        XCTAssertEqual(targetResult.staleReason, "Target worktree changed since preview.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetStale.repo.appendingPathComponent("Source.txt").path))
        XCTAssertEqual(
            try targetStale.gitOutput(["rev-parse", "HEAD"], cwd: targetStale.repo)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            targetHeadAfterIntentionalChange
        )
        XCTAssertEqual(
            try targetStale.gitOutput(["rev-parse", "HEAD^{tree}"], cwd: targetStale.repo)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            targetTreeAfterIntentionalChange
        )
        XCTAssertEqual(try targetStale.gitOutput(["status", "--porcelain"], cwd: targetStale.repo), statusAfterIntentionalChange)
    }

    func testConflictPredictionUnavailableIsAdvisoryFallback() async throws {
        let fixture = try GitMergeFixture()
        defer { fixture.cleanup() }
        let git = GitService()

        let prediction = try await git.predictWorktreeMergeConflicts(
            sourceHead: "source",
            targetHead: "target",
            at: fixture.sandbox
        )

        XCTAssertEqual(prediction.status, .unavailable)
        XCTAssertNotNil(prediction.message)
    }

    func testFilesystemAdvisoryLockSerializesLinkedWorktreesAndReleases() async throws {
        let fixture = try GitMergeFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let gate = AsyncGate()
        let order = LockOrder()

        let first = Task {
            try await git.withWorktreeMergeAdvisoryLock(at: fixture.source) {
                await order.append("first-enter")
                await gate.open()
                try await Task.sleep(nanoseconds: 250_000_000)
                await order.append("first-exit")
            }
        }
        await gate.wait()
        let second = Task {
            try await git.withWorktreeMergeAdvisoryLock(at: fixture.repo) {
                await order.append("second-enter")
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let beforeRelease = await order.snapshot()
        XCTAssertEqual(beforeRelease, ["first-enter"])
        try await first.value
        try await second.value
        let afterRelease = await order.snapshot()
        XCTAssertEqual(afterRelease, ["first-enter", "first-exit", "second-enter"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent(".git/repoprompt-mutex/worktree.lock").path))
    }

    func testFilesystemAdvisoryLockSerializesAcrossProcesses() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("/usr/bin/python3 is unavailable for cross-process flock smoke")
        }

        let fixture = try GitMergeFixture()
        defer { fixture.cleanup() }
        let mutexDir = fixture.repo.appendingPathComponent(".git/repoprompt-mutex", isDirectory: true)
        try FileManager.default.createDirectory(at: mutexDir, withIntermediateDirectories: true)
        let lockPath = mutexDir.appendingPathComponent("worktree.lock").path
        let readyPath = fixture.sandbox.appendingPathComponent("cross-process-lock-ready").path
        let script = """
        import fcntl, os, sys, time
        fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        with open(sys.argv[2], "w", encoding="utf-8") as ready:
            ready.write("ready")
        time.sleep(0.6)
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
        """
        let holder = Process()
        holder.executableURL = python
        holder.arguments = ["-c", script, lockPath, readyPath]
        let output = Pipe()
        holder.standardOutput = output
        holder.standardError = output
        try holder.run()
        defer {
            if holder.isRunning {
                holder.terminate()
                holder.waitUntilExit()
            }
        }

        let readyDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: readyPath), Date() < readyDeadline {
            if !holder.isRunning {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self)
                throw XCTSkip("Unable to start cross-process flock holder: \(text)")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard FileManager.default.fileExists(atPath: readyPath) else {
            XCTFail("Timed out waiting for cross-process flock holder")
            return
        }

        let git = GitService()
        let order = LockOrder()
        let waiter = Task {
            try await git.withWorktreeMergeAdvisoryLock(at: fixture.source) {
                await order.append("swift-enter")
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let beforeRelease = await order.snapshot()
        XCTAssertEqual(beforeRelease, [], "Swift lock entered while another process held the common Git dir lock")

        let exitDeadline = Date().addingTimeInterval(2)
        while holder.isRunning, Date() < exitDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !holder.isRunning else {
            holder.terminate()
            holder.waitUntilExit()
            _ = try? await waiter.value
            XCTFail("Timed out waiting for cross-process flock holder to release the lock")
            return
        }
        XCTAssertEqual(holder.terminationStatus, 0)
        try await waiter.value
        let afterRelease = await order.snapshot()
        XCTAssertEqual(afterRelease, ["swift-enter"])
    }
}

private actor LockOrder {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private struct GitMergeFixture {
    let sandbox: URL
    let repo: URL
    let source: URL

    init() throws {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitWorktreeMergeGitServiceTests-\(suffix)", isDirectory: true)
        repo = sandbox.appendingPathComponent("repo", isDirectory: true).standardizedFileURL
        source = sandbox.appendingPathComponent("source", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init"], cwd: repo)
        try runGit(["config", "user.name", "RepoPrompt Test"], cwd: repo)
        try runGit(["config", "user.email", "repoprompt@example.test"], cwd: repo)
        try runGit(["config", "commit.gpgSign", "false"], cwd: repo)
        try runGit(["checkout", "-b", "main"], cwd: repo)
        try "base\n".write(to: repo.appendingPathComponent("Common.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "Common.txt"], cwd: repo)
        try runGit(["commit", "-m", "Initial commit"], cwd: repo)
        try runGit(["worktree", "add", "-b", "feature/source", source.path, "HEAD"], cwd: repo)
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

    func preview(publishArtifacts: Bool) async throws -> GitWorktreeMergePreview {
        let git = GitService()
        let sourceEndpoint = try await endpoint(for: source, using: git)
        let targetEndpoint = try await endpoint(for: repo, using: git)
        return try await VCSService().previewGitWorktreeMerge(.init(
            source: sourceEndpoint,
            target: targetEndpoint,
            workspaceDirectory: sandbox.appendingPathComponent("workspace", isDirectory: true),
            publishArtifacts: publishArtifacts
        ))
    }

    func commitFile(_ relativePath: String, contents: String, message: String, cwd: URL) throws {
        let url = cwd.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try runGit(["add", relativePath], cwd: cwd)
        try runGit(["commit", "-m", message], cwd: cwd)
    }

    func gitOutput(_ arguments: [String], cwd: URL) throws -> String {
        try Self.gitOutput(arguments, cwd: cwd)
    }

    func runGit(_ arguments: [String], cwd: URL) throws {
        try Self.runGit(arguments, cwd: cwd)
    }

    private static func runGit(_ arguments: [String], cwd: URL) throws {
        _ = try gitOutput(arguments, cwd: cwd)
    }

    private static func gitOutput(_ arguments: [String], cwd: URL) throws -> String {
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
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitWorktreeMergeGitServiceTests.git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(text)"]
            )
        }
        return text
    }
}
