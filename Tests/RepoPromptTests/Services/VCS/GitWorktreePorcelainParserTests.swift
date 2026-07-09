@testable import RepoPromptApp
import XCTest

final class GitWorktreePorcelainParserTests: XCTestCase {
    func testParseNULTerminatedNormalMainAndLinkedWorktree() throws {
        let output = [
            "worktree /tmp/repo",
            "HEAD 1111111111111111111111111111111111111111",
            "branch refs/heads/main",
            "",
            "worktree /tmp/repo-feature",
            "HEAD 2222222222222222222222222222222222222222",
            "branch refs/heads/feature/test",
            ""
        ].joined(separator: "\0")

        let records = try GitWorktreePorcelainParser.parse(output, format: .nulTerminated)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].path, "/tmp/repo")
        XCTAssertEqual(records[0].head, "1111111111111111111111111111111111111111")
        XCTAssertEqual(records[0].branch, "main")
        XCTAssertFalse(records[0].isDetached)
        XCTAssertFalse(records[0].isLocked)
        XCTAssertFalse(records[0].isPrunable)
        XCTAssertEqual(records[1].path, "/tmp/repo-feature")
        XCTAssertEqual(records[1].branch, "feature/test")
    }

    func testParseNULTerminatedDetachedLockedPrunableRecordsWithNewlinesInReasons() throws {
        let output = [
            "worktree /tmp/repo-detached",
            "HEAD 3333333333333333333333333333333333333333",
            "detached",
            "locked keep this\nreason intact",
            "prunable stale admin\nreason intact",
            ""
        ].joined(separator: "\0")

        let records = try GitWorktreePorcelainParser.parse(output, format: .nulTerminated)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].path, "/tmp/repo-detached")
        XCTAssertNil(records[0].branch)
        XCTAssertTrue(records[0].isDetached)
        XCTAssertTrue(records[0].isLocked)
        XCTAssertEqual(records[0].lockReason, "keep this\nreason intact")
        XCTAssertTrue(records[0].isPrunable)
        XCTAssertEqual(records[0].prunableReason, "stale admin\nreason intact")
    }

    func testParseNULTerminatedPreservesExactPathsWithTrailingWhitespaceAndNewlines() throws {
        let exactPath = "/tmp/repo with suffix \n"
        let output = [
            "worktree \(exactPath)",
            "HEAD 4444444444444444444444444444444444444444",
            "branch refs/heads/main",
            ""
        ].joined(separator: "\0")

        let records = try GitWorktreePorcelainParser.parse(output, format: .nulTerminated)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].path, exactPath)
    }

    func testParseNewlineTerminatedFallback() throws {
        let output = """
        worktree /tmp/repo
        HEAD 4444444444444444444444444444444444444444
        branch refs/heads/main

        worktree /tmp/repo-linked
        HEAD 5555555555555555555555555555555555555555
        detached
        """

        let records = try GitWorktreePorcelainParser.parse(output, format: .newlineTerminated)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].path, "/tmp/repo")
        XCTAssertEqual(records[0].branch, "main")
        XCTAssertEqual(records[1].path, "/tmp/repo-linked")
        XCTAssertTrue(records[1].isDetached)
    }

    func testParseLockedAndPrunableWithoutReasons() throws {
        let output = [
            "worktree /tmp/repo-linked",
            "HEAD 6666666666666666666666666666666666666666",
            "branch refs/heads/topic",
            "locked",
            "prunable",
            ""
        ].joined(separator: "\0")

        let records = try GitWorktreePorcelainParser.parse(output, format: .nulTerminated)

        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].isLocked)
        XCTAssertNil(records[0].lockReason)
        XCTAssertTrue(records[0].isPrunable)
        XCTAssertNil(records[0].prunableReason)
    }

    func testParseMalformedRecordsThrowBranchSpecificErrors() {
        let scenarios = [
            ("attribute before worktree", "HEAD abc\0", "before worktree path"),
            ("empty worktree path", "worktree \0HEAD abc\0", "missing a path")
        ]

        for scenario in scenarios {
            XCTAssertThrowsError(try GitWorktreePorcelainParser.parse(scenario.1, format: .nulTerminated), scenario.0) { error in
                guard case let VCSError.parseError(message) = error else {
                    XCTFail("Expected parseError, got \(error)", file: #filePath, line: #line)
                    return
                }
                XCTAssertTrue(message.contains(scenario.2), scenario.0)
            }
        }
    }

    func testWorktreeListZFallsBackOnlyForUnsupportedCapabilityFailures() {
        XCTAssertTrue(GitService.shouldFallbackFromWorktreeListZError("error: unknown option `z'"))
        XCTAssertTrue(GitService.shouldFallbackFromWorktreeListZError("usage: git worktree list [<options>]"))
        XCTAssertFalse(GitService.shouldFallbackFromWorktreeListZError("fatal: not a git repository"))
        XCTAssertFalse(GitService.shouldFallbackFromWorktreeListZError("fatal: bad object HEAD"))
    }
}
