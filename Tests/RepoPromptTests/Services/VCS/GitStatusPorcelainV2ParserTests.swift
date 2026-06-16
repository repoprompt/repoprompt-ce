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
    }

    func testRejectsMalformedTrackedRecord() {
        XCTAssertThrowsError(try GitStatusPorcelainV2Parser.parse("1 M. incomplete\0"))
    }
}
