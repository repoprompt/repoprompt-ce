@testable import RepoPromptCore
import XCTest

final class SelectionSlicePersistenceAndRebaseTests: XCTestCase {
    func testPartitionStoreColdReloadPreservesSlicesAndIsolatesScopes() async throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelectionSlicePersistenceAndRebaseTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let rootPath = "/tmp/SelectionSlicePersistenceAndRebaseTests/root"
        let relativePath = "Sources/A.swift"
        let workspaceID = UUID()
        let tabID = UUID()
        let scope = PartitionScope(workspaceID: workspaceID, tabID: tabID)
        let normalizedRanges = [
            LineRange(start: 2, end: 4, description: "header"),
            LineRange(start: 8, end: 10, description: "body")
        ]
        let anchors = [
            SliceAnchor(range: normalizedRanges[0], startSignature: ["header-start"], endSignature: ["header-end"]),
            SliceAnchor(range: normalizedRanges[1], startSignature: ["body-start"], endSignature: ["body-end"])
        ]
        let modificationTime = 1_717_171_717.25

        let writer = PartitionStore(baseURL: baseURL)
        _ = try await writer.apply(
            forRoot: rootPath,
            scope: scope,
            updates: [
                relativePath: PartitionStore.SliceUpdate(
                    ranges: Array(normalizedRanges.reversed()),
                    fileModificationTime: modificationTime,
                    anchors: anchors
                )
            ],
            mode: .set
        )

        let reader = PartitionStore(baseURL: baseURL)
        let reloaded = await reader.load(forRoot: rootPath, scope: scope)
        XCTAssertEqual(
            reloaded.files,
            [relativePath: PartitionStore.StoredSlices(
                ranges: normalizedRanges,
                fileModificationTime: modificationTime,
                anchors: anchors
            )]
        )

        let anotherTab = await reader.load(
            forRoot: rootPath,
            scope: PartitionScope(workspaceID: workspaceID, tabID: UUID())
        )
        XCTAssertTrue(anotherTab.files.isEmpty)

        let anotherWorkspace = await reader.load(
            forRoot: rootPath,
            scope: PartitionScope(workspaceID: UUID(), tabID: tabID)
        )
        XCTAssertTrue(anotherWorkspace.files.isEmpty)
    }

    func testSliceRebaseDropsRangesForEmptyAndUnmappableContent() {
        let originalRange = LineRange(start: 2, end: 2, description: "selected")
        let oldText = "before\nselected\nafter\n"
        let anchors = SliceRebaseEngine.buildAnchors(content: oldText, ranges: [originalRange])
        let cases: [(name: String, result: SliceRebaseEngine.Result)] = [
            (
                name: "empty content",
                result: SliceRebaseEngine.rebase(
                    oldText: oldText,
                    newText: "",
                    oldRanges: [originalRange],
                    anchors: anchors
                )
            ),
            (
                name: "unmappable selected signature",
                result: SliceRebaseEngine.rebase(
                    oldText: oldText,
                    newText: "before\nreplacement\nafter\n",
                    oldRanges: [originalRange],
                    anchors: anchors
                )
            )
        ]

        for testCase in cases {
            XCTAssertEqual(testCase.result.rebased, [], testCase.name)
            XCTAssertEqual(testCase.result.dropped, [originalRange], testCase.name)
            XCTAssertTrue(testCase.result.didChange, testCase.name)
        }
    }

    func testSliceRebaseEqualCacheUsesSavedAnchorFallback() {
        let staleRange = LineRange(start: 2, end: 2, description: "selected")
        let preEditText = "before\nselected\nafter\n"
        let savedAnchors = SliceRebaseEngine.buildAnchors(content: preEditText, ranges: [staleRange])
        let currentText = "inserted\nbefore\nselected\nafter\n"

        let result = SliceRebaseEngine.rebase(
            oldText: currentText,
            newText: currentText,
            oldRanges: [staleRange],
            anchors: savedAnchors
        )

        XCTAssertEqual(result.rebased, [LineRange(start: 3, end: 3, description: "selected")])
        XCTAssertTrue(result.dropped.isEmpty)
        XCTAssertTrue(result.didChange)
    }
}
