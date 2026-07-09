import Foundation
@testable import RepoPromptApp
import XCTest

final class GitBranchSwitchServiceTests: XCTestCase {
    private var tempRoot: URL?

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    func testSwitchesToExistingLocalBranchInPlace() async throws {
        let repo = try makeGitFixture()
        let service = VCSService()

        let preflight = try await service.preflightGitBranchSwitch(branchName: "feature/local", at: repo)
        let result = try await service.switchGitBranch(
            GitBranchSwitchRequest(
                branchName: "feature/local",
                expectedCurrentBranch: preflight.currentBranch,
                expectedCurrentHead: preflight.currentHead
            ),
            at: repo
        )

        XCTAssertTrue(result.didSwitch)
        XCTAssertEqual(result.previousBranch, "main")
        XCTAssertEqual(result.newBranch, "feature/local")
        XCTAssertEqual(try currentBranch(cwd: repo), "feature/local")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("branch.txt")), "feature\n")
    }

    func testCurrentBranchIsNoOp() async throws {
        let repo = try makeGitFixture()
        let service = VCSService()

        let result = try await service.switchGitBranch(
            GitBranchSwitchRequest(branchName: "main"),
            at: repo
        )

        XCTAssertFalse(result.didSwitch)
        XCTAssertEqual(result.previousBranch, "main")
        XCTAssertEqual(result.newBranch, "main")
        XCTAssertEqual(try currentBranch(cwd: repo), "main")
    }

    func testMissingLocalBranchFailsWithoutCreatingBranch() async throws {
        let repo = try makeGitFixture()
        let service = VCSService()

        do {
            _ = try await service.switchGitBranch(GitBranchSwitchRequest(branchName: "origin/not-local"), at: repo)
            XCTFail("Expected missing local branch to fail")
        } catch let error as GitBranchSwitchError {
            XCTAssertEqual(error, .branchNotLocal("origin/not-local"))
        }

        XCTAssertEqual(try currentBranch(cwd: repo), "main")
        XCTAssertFalse(try localBranches(cwd: repo).contains("origin/not-local"))
    }

    func testStaleExpectedCheckoutFailsBeforeSwitching() async throws {
        let repo = try makeGitFixture()
        let service = VCSService()
        let preflight = try await service.preflightGitBranchSwitch(branchName: "feature/local", at: repo)
        try runGit(["switch", "other"], cwd: repo)

        do {
            _ = try await service.switchGitBranch(
                GitBranchSwitchRequest(
                    branchName: "feature/local",
                    expectedCurrentBranch: preflight.currentBranch,
                    expectedCurrentHead: preflight.currentHead
                ),
                at: repo
            )
            XCTFail("Expected stale checkout to fail")
        } catch let error as GitBranchSwitchError {
            if case .staleCheckout = error {
                // expected
            } else {
                XCTFail("Expected stale checkout, got \(error)")
            }
        }

        XCTAssertEqual(try currentBranch(cwd: repo), "other")
    }

    func testSameBranchAdvancedHeadIsStaleBeforeSwitching() async throws {
        let repo = try makeGitFixture()
        let service = VCSService()
        let preflight = try await service.preflightGitBranchSwitch(branchName: "feature/local", at: repo)
        try "advanced\n".write(to: repo.appendingPathComponent("advanced.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: repo)
        try runGit(["commit", "-m", "Advance main"], cwd: repo)

        do {
            _ = try await service.switchGitBranch(
                GitBranchSwitchRequest(
                    branchName: "feature/local",
                    expectedCurrentBranch: preflight.currentBranch,
                    expectedCurrentHead: preflight.currentHead
                ),
                at: repo
            )
            XCTFail("Expected same-branch HEAD staleness to fail")
        } catch let error as GitBranchSwitchError {
            if case .staleCheckout = error {
                // expected
            } else {
                XCTFail("Expected stale checkout, got \(error)")
            }
        }

        XCTAssertEqual(try currentBranch(cwd: repo), "main")
    }

    func testDirtyConflictingWorktreeIsLeftUnstashedAndUnswitched() async throws {
        let repo = try makeGitFixture()
        let service = VCSService()
        try "dirty main edit\n".write(to: repo.appendingPathComponent("branch.txt"), atomically: true, encoding: .utf8)

        let preflight = try await service.preflightGitBranchSwitch(branchName: "feature/local", at: repo)
        XCTAssertTrue(preflight.warnings.contains(.uncommittedChanges))

        do {
            _ = try await service.switchGitBranch(
                GitBranchSwitchRequest(
                    branchName: "feature/local",
                    expectedCurrentBranch: preflight.currentBranch,
                    expectedCurrentHead: preflight.currentHead
                ),
                at: repo
            )
            XCTFail("Expected dirty conflicting checkout to fail")
        } catch {
            // Git is the authority for dirty-worktree conflicts. We only assert
            // the concrete safety outcome: no switch and no auto-stash.
        }

        XCTAssertEqual(try currentBranch(cwd: repo), "main")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("branch.txt")), "dirty main edit\n")
        XCTAssertTrue(try runGitCapture(["stash", "list"], cwd: repo).isEmpty)
    }

    func testOptionsAnnotateBranchCheckedOutInAnotherWorktree() async throws {
        let repo = try makeGitFixture()
        let occupiedWorktree = try addLinkedWorktree(for: "feature/local", repo: repo)
        let service = VCSService()

        let options = try await service.gitBranchSwitchOptions(at: repo)
        let branch = try XCTUnwrap(options.branches.first { $0.name == "feature/local" })

        XCTAssertFalse(branch.isCurrent)
        XCTAssertTrue(branch.isCheckedOutInAnotherWorktree)
        XCTAssertEqual(branch.checkedOutWorktree?.worktreePath, occupiedWorktree.standardizedFileURL.path)
        XCTAssertEqual(branch.checkedOutWorktree?.worktreeName, "feature-local")
        XCTAssertEqual(branch.checkedOutWorktreeLabel, "feature-local")
        XCTAssertNotNil(branch.checkedOutWorktree?.worktreeID)
    }

    func testPreflightRejectsBranchCheckedOutInAnotherWorktree() async throws {
        let repo = try makeGitFixture()
        let occupiedWorktree = try addLinkedWorktree(for: "feature/local", repo: repo)
        let service = VCSService()

        do {
            _ = try await service.preflightGitBranchSwitch(branchName: "feature/local", at: repo)
            XCTFail("Expected occupied branch preflight to fail")
        } catch let error as GitBranchSwitchError {
            XCTAssertEqual(
                error,
                .branchCheckedOutInWorktree(
                    branch: "feature/local",
                    worktreePath: occupiedWorktree.standardizedFileURL.path,
                    worktreeName: "feature-local"
                )
            )
        }

        XCTAssertEqual(try currentBranch(cwd: repo), "main")
    }

    func testSwitchRejectsBranchCheckedOutInAnotherWorktreeAndLeavesCheckoutUnchanged() async throws {
        let repo = try makeGitFixture()
        let occupiedWorktree = try addLinkedWorktree(for: "feature/local", repo: repo)
        let service = VCSService()

        do {
            _ = try await service.switchGitBranch(GitBranchSwitchRequest(branchName: "feature/local"), at: repo)
            XCTFail("Expected occupied branch switch to fail")
        } catch let error as GitBranchSwitchError {
            XCTAssertEqual(
                error,
                .branchCheckedOutInWorktree(
                    branch: "feature/local",
                    worktreePath: occupiedWorktree.standardizedFileURL.path,
                    worktreeName: "feature-local"
                )
            )
        }

        XCTAssertEqual(try currentBranch(cwd: repo), "main")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("branch.txt")), "main\n")
    }

    private func makeGitFixture() throws -> URL {
        let root = try makeTemporaryDirectory()
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], cwd: repo)
        try runGit(["config", "user.email", "test@example.com"], cwd: repo)
        try runGit(["config", "user.name", "Test User"], cwd: repo)
        try "main\n".write(to: repo.appendingPathComponent("branch.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: repo)
        try runGit(["commit", "-m", "Initial commit"], cwd: repo)

        try runGit(["switch", "-c", "feature/local"], cwd: repo)
        try "feature\n".write(to: repo.appendingPathComponent("branch.txt"), atomically: true, encoding: .utf8)
        try runGit(["commit", "-am", "Feature commit"], cwd: repo)

        try runGit(["switch", "main"], cwd: repo)
        try runGit(["switch", "-c", "other"], cwd: repo)
        try "other\n".write(to: repo.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: repo)
        try runGit(["commit", "-m", "Other commit"], cwd: repo)
        try runGit(["switch", "main"], cwd: repo)
        return repo
    }

    private func addLinkedWorktree(for branch: String, repo: URL) throws -> URL {
        let worktreesRoot = repo.deletingLastPathComponent().appendingPathComponent(".worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: worktreesRoot, withIntermediateDirectories: true)
        let worktree = worktreesRoot.appendingPathComponent(safeWorktreeDirectoryName(for: branch), isDirectory: true)
        try runGit(["worktree", "add", worktree.path, branch], cwd: repo)
        return worktree.standardizedFileURL
    }

    private func safeWorktreeDirectoryName(for branch: String) -> String {
        let safeName = branch.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }.joined()
        let trimmed = safeName.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "worktree" : trimmed
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitBranchSwitchServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoot = root
        return root
    }

    private func currentBranch(cwd: URL) throws -> String {
        try runGitCapture(["branch", "--show-current"], cwd: cwd)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func localBranches(cwd: URL) throws -> [String] {
        try runGitCapture(["for-each-ref", "--format=%(refname:short)", "refs/heads"], cwd: cwd)
            .split(separator: "\n")
            .map(String.init)
    }

    private func runGit(_ arguments: [String], cwd: URL) throws {
        _ = try runGitCapture(arguments, cwd: cwd)
    }

    private func runGitCapture(_ arguments: [String], cwd: URL) throws -> String {
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
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitBranchSwitchServiceTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(text)"]
            )
        }
        return text
    }
}
