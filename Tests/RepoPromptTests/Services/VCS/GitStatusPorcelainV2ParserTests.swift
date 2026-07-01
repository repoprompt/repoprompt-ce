@testable import RepoPrompt
import XCTest

final class GitStatusPorcelainV2ParserTests: XCTestCase {
    func testParsesBranchTrackingOrdinaryRenameSubmoduleAndUntrackedRecords() throws {
        let output = [
            "# branch.oid 0123456789012345678901234567890123456789",
            "# branch.head feature/status-v2",
            "# branch.upstream origin/feature/status-v2",
            "# branch.ab +3 -2",
            "1 M. N... 100644 100644 100644 aaaaaaa bbbbbbb Staged.txt",
            "1 .M S.M. 160000 160000 160000 ccccccc ddddddd Submodule",
            "2 R. N... 100644 100644 100644 eeeeeee fffffff R100 New Name.txt",
            "Old Name.txt",
            "? Untracked File.txt"
        ].joined(separator: "\0") + "\0"

        let snapshot = try GitStatusPorcelainV2Parser.parse(output)

        XCTAssertEqual(snapshot.branch, "feature/status-v2")
        XCTAssertEqual(snapshot.headID, "0123456789012345678901234567890123456789")
        XCTAssertEqual(snapshot.upstream, "origin/feature/status-v2")
        XCTAssertEqual(snapshot.ahead, 3)
        XCTAssertEqual(snapshot.behind, 2)
        XCTAssertEqual(snapshot.staged, ["New Name.txt", "Staged.txt"])
        XCTAssertEqual(snapshot.modified, ["Submodule"])
        XCTAssertEqual(snapshot.untracked, ["Untracked File.txt"])
        XCTAssertEqual(snapshot.pathRecords.count, 4)
        XCTAssertEqual(snapshot.pathRecords[0].indexStatus, "M")
        XCTAssertEqual(snapshot.pathRecords[0].workTreeStatus, ".")
        XCTAssertEqual(snapshot.pathRecords[0].headMode, "100644")
        XCTAssertEqual(snapshot.pathRecords[0].indexMode, "100644")
        XCTAssertEqual(snapshot.pathRecords[0].workTreeMode, "100644")
        XCTAssertEqual(snapshot.pathRecords[0].headOID, "aaaaaaa")
        XCTAssertEqual(snapshot.pathRecords[0].indexOID, "bbbbbbb")
        XCTAssertEqual(snapshot.pathRecords[1].submoduleState, "S.M.")
        XCTAssertEqual(
            snapshot.pathRecords[2].kind,
            .renamedOrCopied(originalPath: "Old Name.txt", score: "R100")
        )
        XCTAssertEqual(snapshot.pathRecords[3].kind, .untracked)
    }

    func testParsesUnstagedRenameAndCopyType2Records() throws {
        let output = [
            "2 .R N... 100644 100644 100644 aaaaaaa bbbbbbb R100 Renamed.txt",
            "Original.txt",
            "2 .C N... 100644 100644 100644 ccccccc ddddddd C100 Copied.txt",
            "Source.txt",
            "2 C. N... 100644 100644 100644 eeeeeee fffffff C87 Staged Copy.txt",
            "Staged Source.txt"
        ].joined(separator: "\0") + "\0"

        let snapshot = try GitStatusPorcelainV2Parser.parse(output)

        XCTAssertEqual(snapshot.staged, ["Staged Copy.txt"])
        XCTAssertEqual(snapshot.modified, ["Copied.txt", "Renamed.txt"])
        XCTAssertEqual(snapshot.pathRecords.map(\.indexStatus), [".", ".", "C"])
        XCTAssertEqual(snapshot.pathRecords.map(\.workTreeStatus), ["R", "C", "."])
        XCTAssertEqual(snapshot.pathRecords.map(\.path), ["Renamed.txt", "Copied.txt", "Staged Copy.txt"])
        XCTAssertEqual(
            snapshot.pathRecords.map(\.kind),
            [
                .renamedOrCopied(originalPath: "Original.txt", score: "R100"),
                .renamedOrCopied(originalPath: "Source.txt", score: "C100"),
                .renamedOrCopied(originalPath: "Staged Source.txt", score: "C87")
            ]
        )
    }

    func testParsesDetachedAndUnmergedStatus() throws {
        let output = [
            "# branch.oid fedcba9876543210fedcba9876543210fedcba98",
            "# branch.head (detached)",
            "u UU N... 100644 100644 100644 100644 aaaaaaa bbbbbbb ccccccc Conflict.txt"
        ].joined(separator: "\0") + "\0"

        let snapshot = try GitStatusPorcelainV2Parser.parse(output)

        XCTAssertNil(snapshot.branch)
        XCTAssertNil(snapshot.upstream)
        XCTAssertNil(snapshot.ahead)
        XCTAssertNil(snapshot.behind)
        XCTAssertEqual(snapshot.staged, ["Conflict.txt"])
        XCTAssertEqual(snapshot.modified, ["Conflict.txt"])
        XCTAssertTrue(snapshot.untracked.isEmpty)
        XCTAssertEqual(snapshot.pathRecords.first?.kind, .unmerged)
        XCTAssertEqual(snapshot.pathRecords.first?.conflictStage1OID, "aaaaaaa")
        XCTAssertEqual(snapshot.pathRecords.first?.conflictStage2OID, "bbbbbbb")
        XCTAssertEqual(snapshot.pathRecords.first?.conflictStage3OID, "ccccccc")
    }

    func testRejectsMalformedTrackedRecord() {
        XCTAssertThrowsError(try GitStatusPorcelainV2Parser.parse("1 M. incomplete\0"))
    }

    func testRejectsMalformedOrdinaryRenameAndUnmergedXYValues() {
        let ordinary = "1 MX N... 100644 100644 100644 aaaaaaa bbbbbbb File.txt\0"
        let overlong = "1 M.. N... 100644 100644 100644 aaaaaaa bbbbbbb File.txt\0"
        let rename = "2 Z. N... 100644 100644 100644 aaaaaaa bbbbbbb R100 New.txt\0Old.txt\0"
        let modifiedIndex = "2 M. N... 100644 100644 100644 aaaaaaa bbbbbbb R100 New.txt\0Old.txt\0"
        let modifiedWorktree = "2 .M N... 100644 100644 100644 aaaaaaa bbbbbbb C100 New.txt\0Old.txt\0"
        let invalidScorePrefix = "2 R. N... 100644 100644 100644 aaaaaaa bbbbbbb M100 New.txt\0Old.txt\0"
        let mismatchedScorePrefix = "2 C. N... 100644 100644 100644 aaaaaaa bbbbbbb R100 New.txt\0Old.txt\0"
        let unmerged = "u M. N... 100644 100644 100644 100644 aaaaaaa bbbbbbb ccccccc Conflict.txt\0"

        for output in [
            ordinary,
            overlong,
            rename,
            modifiedIndex,
            modifiedWorktree,
            invalidScorePrefix,
            mismatchedScorePrefix,
            unmerged
        ] {
            XCTAssertThrowsError(try GitStatusPorcelainV2Parser.parse(output), output)
        }
    }
}
