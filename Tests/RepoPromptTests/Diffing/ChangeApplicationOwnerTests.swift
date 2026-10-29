import Foundation
import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class ChangeApplicationOwnerTests: XCTestCase {
    func testFileChangeLegacyCodingAndStableContentKey() throws {
        let json = #"{"start_line":1,"description":"  Update  ","chunk":["-old","+new"]}"#
        var change = try JSONDecoder().decode(FileChange.self, from: Data(json.utf8))
        let decodedAgain = try JSONDecoder().decode(FileChange.self, from: Data(json.utf8))
        XCTAssertNotEqual(change.id, decodedAgain.id)
        XCTAssertEqual(change.diffChunk.lines.map(\.rawContent), ["-old", "+new"])
        let key = change.contentKey
        change.startLine = 9
        XCTAssertEqual(change.contentKey, key)
        XCTAssertEqual(key, "Update|1|-old\n+new")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as? [String: Any])
        XCTAssertEqual(Set(encoded.keys), ["start_line", "description", "chunk"])
        XCTAssertEqual(encoded["start_line"] as? Int, 9)
        XCTAssertEqual(encoded["chunk"] as? [String], ["-old", "+new"])
    }

    func testApplyRevertGroupingAndTrailingNewline() {
        let first = FileChange(startLine: 0, description: "first", diffChunk: DiffChunk(lines: [DiffLine(content: "-one"), DiffLine(content: "+ONE")], startLine: 0))
        let second = FileChange(startLine: 2, description: "second", diffChunk: DiffChunk(lines: [DiffLine(content: "-three"), DiffLine(content: "+THREE")], startLine: 2))
        let manager = ChangeManager(fileContent: ["one", "two", "three"], changes: [second, first], lineEnding: "\r\n", fileAction: .modify, hadTrailingNewline: true)
        XCTAssertEqual(manager.changeGroups(threshold: 3).count, 1)
        XCTAssertEqual(manager.changeGroups(threshold: -1).count, 2)
        let applied = manager.applyChange(first)
        XCTAssertNil(applied.error)
        XCTAssertEqual(applied.updatedContent, ["ONE", "two", "three"])
        XCTAssertEqual(applied.appliedChangeIds, [first.id])
        let reverted = manager.revertChange(first)
        XCTAssertNil(reverted.error)
        XCTAssertEqual(reverted.updatedContent, ["one", "two", "three"])
        XCTAssertEqual(manager.updatedContent(), "one\r\ntwo\r\nthree\r\n")
    }

    func testBatchedApplicationKeepsSuccessfulChangesWhenAnotherFails() async {
        let valid = FileChange(startLine: 0, description: "valid", diffChunk: DiffChunk(lines: [DiffLine(content: "-one"), DiffLine(content: "+ONE")], startLine: 0))
        let missing = FileChange(startLine: 1, description: "missing", diffChunk: DiffChunk(lines: [DiffLine(content: "+unused")], startLine: 1))
        let manager = ChangeManager(fileContent: ["one"], changes: [valid], lineEnding: "\n", fileAction: .modify)
        let applier = ChangeApplier(manager: manager)
        let result = await applier.apply([valid, missing])
        XCTAssertEqual(result.updated, ["ONE"])
        XCTAssertEqual(result.newlyApplied, [valid.id])
        XCTAssertEqual(result.failedIDs, [missing.id])
    }
}
