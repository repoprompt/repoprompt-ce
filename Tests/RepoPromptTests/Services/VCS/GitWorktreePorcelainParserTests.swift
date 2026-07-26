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

    func testStandardizedPathAliasesCollapseOnlyForEquivalentRepositoryLayouts() throws {
        let canonicalPath = "/tmp/repo"
        let aliasPath = "/tmp/repo/linked/.."
        let output = [
            "worktree \(aliasPath)",
            "HEAD 7777777777777777777777777777777777777777",
            "branch refs/heads/main",
            "",
            "worktree \(canonicalPath)",
            "HEAD 7777777777777777777777777777777777777777",
            "branch refs/heads/main",
            ""
        ].joined(separator: "\0")
        let records = try GitWorktreePorcelainParser.parse(output, format: .nulTerminated)
        let commonDirectory = URL(fileURLWithPath: "/tmp/repo/.git")

        func layout(
            root: URL,
            commonDirectory: URL,
            marksDirectories: Bool = false
        ) -> GitRepositoryLayout {
            let markedRoot = URL(fileURLWithPath: root.path, isDirectory: marksDirectories)
            let markedCommonDirectory = URL(
                fileURLWithPath: commonDirectory.path,
                isDirectory: marksDirectories
            )
            return GitRepositoryLayout(
                workTreeRoot: markedRoot,
                dotGitPath: markedRoot.appendingPathComponent(".git", isDirectory: marksDirectories),
                gitDir: markedCommonDirectory.appendingPathComponent("worktrees/repo", isDirectory: marksDirectories),
                commonDir: markedCommonDirectory,
                isWorktree: true
            )
        }

        let resolution = try GitService.collapseEquivalentWorktreeAliases(records) {
            layout(root: $0, commonDirectory: commonDirectory)
        }

        XCTAssertEqual(resolution.records.count, 1)
        XCTAssertEqual(resolution.collapsedAliasCount, 1)
        XCTAssertEqual(resolution.records[0].record.path, canonicalPath)
        XCTAssertEqual(resolution.records[0].pathURL.path, canonicalPath)
        XCTAssertEqual(resolution.records[0].layout?.workTreeRoot.path, canonicalPath)

        var directoryMarkerIndex = 0
        let directoryMarkerResolution = try GitService.collapseEquivalentWorktreeAliases(records) { root in
            defer { directoryMarkerIndex += 1 }
            return layout(
                root: root,
                commonDirectory: commonDirectory,
                marksDirectories: directoryMarkerIndex == 0
            )
        }
        XCTAssertEqual(directoryMarkerResolution.records.count, 1)
        XCTAssertEqual(directoryMarkerResolution.collapsedAliasCount, 1)
        XCTAssertEqual(directoryMarkerResolution.records[0].layout?.workTreeRoot.hasDirectoryPath, true)

        XCTAssertThrowsError(
            try GitService.collapseEquivalentWorktreeAliases(records) { _ in nil }
        ) { error in
            XCTAssertEqual(error as? GitService.WorktreeAliasConflict, .repositoryLayout)
        }

        var partialLayoutIndex = 0
        XCTAssertThrowsError(
            try GitService.collapseEquivalentWorktreeAliases(records) { root in
                defer { partialLayoutIndex += 1 }
                return partialLayoutIndex == 0
                    ? layout(root: root, commonDirectory: commonDirectory)
                    : nil
            }
        ) { error in
            XCTAssertEqual(error as? GitService.WorktreeAliasConflict, .repositoryLayout)
        }

        var layoutIndex = 0
        XCTAssertThrowsError(
            try GitService.collapseEquivalentWorktreeAliases(records) { root in
                defer { layoutIndex += 1 }
                let resolvedCommonDirectory = layoutIndex == 0
                    ? commonDirectory
                    : URL(fileURLWithPath: "/tmp/other-repo/.git")
                return layout(root: root, commonDirectory: resolvedCommonDirectory)
            }
        ) { error in
            XCTAssertEqual(error as? GitService.WorktreeAliasConflict, .repositoryLayout)
        }

        var conflictingRecords = records
        conflictingRecords[1].branch = "topic"
        XCTAssertThrowsError(
            try GitService.collapseEquivalentWorktreeAliases(conflictingRecords) {
                layout(root: $0, commonDirectory: commonDirectory)
            }
        ) { error in
            XCTAssertEqual(error as? GitService.WorktreeAliasConflict, .recordMetadata)
        }
    }

    func testWorktreeListZFallsBackOnlyForUnsupportedCapabilityFailures() {
        XCTAssertTrue(GitService.shouldFallbackFromWorktreeListZError("error: unknown option `z'"))
        XCTAssertTrue(GitService.shouldFallbackFromWorktreeListZError("usage: git worktree list [<options>]"))
        XCTAssertFalse(GitService.shouldFallbackFromWorktreeListZError("fatal: not a git repository"))
        XCTAssertFalse(GitService.shouldFallbackFromWorktreeListZError("fatal: bad object HEAD"))
    }
}
