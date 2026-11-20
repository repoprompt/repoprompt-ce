import Foundation
import RepoPromptFileSystem
import XCTest

final class FileSystemDeltaCoalescerTests: XCTestCase {
    func testStrictAncestorsPruneDescendantsWithoutRemovingSiblingsOrSamePathKindChanges() {
        let input: [FileSystemDelta] = [
            .fileAdded("src/child/file"),
            .folderRemoved("src/child"),
            .folderRemoved("src"),
            .fileRemoved("src2/file"),
            .fileAdded("src"),
            .folderRemoved("src-2"),
            .fileAdded("src-2x/keep"),
            .folderRemoved("café"),
            .fileAdded("cafe\u{301}/child")
        ]
        XCTAssertEqual(FileSystemDeltaCoalescer.coalesce(input), [
            .folderRemoved("src"),
            .fileRemoved("src2/file"),
            .fileAdded("src"),
            .folderRemoved("src-2"),
            .fileAdded("src-2x/keep"),
            .folderRemoved("café")
        ])
    }

    func testLatestFolderEventControlsPruningAndOriginalEventOrderIsRetained() {
        let input: [FileSystemDelta] = [
            .folderRemoved("restored"),
            .folderAdded("restored"),
            .fileAdded("restored/child"),
            .folderAdded("removed"),
            .fileAdded("removed/child"),
            .folderRemoved("removed")
        ]
        XCTAssertEqual(FileSystemDeltaCoalescer.coalesce(input), [
            .folderAdded("restored"),
            .fileAdded("restored/child"),
            .folderRemoved("removed")
        ])
    }

    func testCanonicalPathsAndRootContainmentRetainExistingSemantics() {
        XCTAssertEqual(FileSystemDeltaCoalescer.coalesce([
            .folderRemoved("./src/../src"),
            .fileAdded("src/./child"),
            .fileAdded("../escape"),
            .fileAdded("/absolute"),
            .fileAdded("src2/keep")
        ], inRoot: "/fixture"), [
            .folderRemoved("./src/../src"),
            .fileAdded("src2/keep")
        ])
        // A canonical empty relative folder did not suppress relative children in the
        // previous containment predicate; this optimization does not change that policy.
        XCTAssertEqual(FileSystemDeltaCoalescer.coalesce([
            .folderRemoved("."), .fileAdded("keep/file")
        ]), [.folderRemoved("."), .fileAdded("keep/file")])
        XCTAssertEqual(FileSystemDeltaCoalescer.coalesce([
            .folderRemoved(".."), .fileAdded("../outside"), .fileAdded("sibling")
        ]), [.folderRemoved(".."), .fileAdded("sibling")])
    }

    func testLargeDeletionBatchKeepsOrderedIndependentEvents() {
        var input: [FileSystemDelta] = []
        var expected: [FileSystemDelta] = []
        for index in 0 ..< 8192 {
            let removal = FileSystemDelta.folderRemoved("removed/\(index)")
            let survivor = FileSystemDelta.fileAdded("removed/\(index)-keep/value")
            input.append(contentsOf: [removal, .fileRemoved("removed/\(index)/child"), survivor])
            expected.append(contentsOf: [removal, survivor])
        }
        let started = Date()
        let actual = FileSystemDeltaCoalescer.coalesce(input)
        print("LATENCY_COALESCER events=\(input.count) seconds=\(Date().timeIntervalSince(started))")
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertTrue(actual == expected, "Large batches must retain exact surviving events and order")
    }
}
