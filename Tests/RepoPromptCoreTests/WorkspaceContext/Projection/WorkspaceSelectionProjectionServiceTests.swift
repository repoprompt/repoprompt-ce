import Foundation
@testable import RepoPromptCore
import XCTest

final class WorkspaceSelectionProjectionServiceTests: XCTestCase {
    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testBaseProjectionAndSelectedAlternateMatchFrozenTokenSemantics() {
        let ranges = [LineRange(start: 2, end: 2, description: "middle")]
        let entries = [
            makeEntry(path: "Sources/Full.swift", mode: .full, displayTokens: 100, fullTokens: 100, codemapTokens: 10),
            makeEntry(
                path: "Sources/Sliced.swift",
                mode: .slice,
                ranges: ranges,
                displayTokens: 20,
                fullTokens: 200,
                codemapTokens: 11
            ),
            makeEntry(path: "Sources/Auto.swift", mode: .codemap, displayTokens: 12, fullTokens: 300, codemapTokens: 12)
        ]

        let projection = project(entries, alternateUsage: .selected)

        XCTAssertEqual(projection.files.map(\.file.standardizedRelativePath), [
            "Sources/Full.swift",
            "Sources/Sliced.swift",
            "Sources/Auto.swift"
        ])
        XCTAssertEqual(projection.files.map(\.mode), [.full, .slice, .codemap])
        XCTAssertEqual(projection.files.map(\.tokens), [100, 20, 12])
        XCTAssertEqual(projection.files.map(\.isAuto), [false, false, true])
        XCTAssertEqual(projection.totalTokens, 132)
        XCTAssertEqual(projection.summary, .init(
            fullCount: 1,
            sliceCount: 1,
            codemapCount: 1,
            fullTokens: 100,
            sliceTokens: 20,
            codemapTokens: 12
        ))
        XCTAssertEqual(projection.slices.map(\.file.standardizedRelativePath), ["Sources/Sliced.swift"])
        XCTAssertEqual(projection.slices.map(\.ranges), [ranges])
        XCTAssertEqual(projection.files.map(\.alternate?.mode), [.codemap, .codemap, nil])
        XCTAssertEqual(projection.files.map(\.alternate?.tokens), [10, 11, nil])
        XCTAssertEqual(projection.files.map(\.alternate?.codemapOrigin), [.selectedMode, .selectedMode, nil])
        XCTAssertEqual(projection.alternate?.contentTokens, 0)
        XCTAssertEqual(projection.alternate?.codemapTokens, 33)
        XCTAssertEqual(projection.alternate?.totalTokens, 33)
        XCTAssertEqual(projection.alternate?.includedTotalTokens, 33)
        XCTAssertEqual(projection.alternate?.includedFiles.map(\.file.standardizedRelativePath), [
            "Sources/Full.swift",
            "Sources/Sliced.swift",
            "Sources/Auto.swift"
        ])
        XCTAssertEqual(projection.alternate?.includedFiles.map(\.mode), [.codemap, .codemap, .codemap])
    }

    func testCompleteNoneAndAutoAlternatesPreserveBaseAndAggregateSemantics() {
        let entries = [
            makeEntry(path: "Full.swift", mode: .full, displayTokens: 100, fullTokens: 100, codemapTokens: 10),
            makeEntry(path: "Sliced.swift", mode: .slice, displayTokens: 20, fullTokens: 200, codemapTokens: 11),
            makeEntry(path: "Auto.swift", mode: .codemap, displayTokens: 12, fullTokens: 300, codemapTokens: 12)
        ]

        let complete = project(entries, alternateUsage: .complete)
        XCTAssertEqual(complete.files.map(\.alternate?.tokens), [10, 11, nil])
        XCTAssertEqual(complete.files.map(\.alternate?.codemapOrigin), [.completeMode, .completeMode, nil])
        XCTAssertEqual(complete.alternate?.contentTokens, 0)
        XCTAssertEqual(complete.alternate?.codemapTokens, 33)
        XCTAssertEqual(complete.alternate?.totalTokens, 33)
        XCTAssertEqual(complete.alternate?.includedTotalTokens, 33)

        let none = project(entries, alternateUsage: .none)
        XCTAssertEqual(none.files.map(\.alternate?.mode), [nil, nil, .hidden])
        XCTAssertEqual(none.files.map(\.tokens), [100, 20, 12])
        XCTAssertEqual(none.summary.codemapTokens, 12)
        XCTAssertEqual(none.alternate?.contentTokens, 120)
        XCTAssertEqual(none.alternate?.codemapTokens, 0)
        XCTAssertEqual(none.alternate?.totalTokens, 120)
        XCTAssertEqual(none.alternate?.includedTotalTokens, 120)

        let auto = project(entries, alternateUsage: .auto)
        XCTAssertTrue(auto.files.allSatisfy { $0.alternate == nil })
        XCTAssertEqual(auto.alternate?.contentTokens, 120)
        XCTAssertEqual(auto.alternate?.codemapTokens, 12)
        XCTAssertEqual(auto.alternate?.totalTokens, 132)
        XCTAssertEqual(auto.alternate?.includedTotalTokens, 132)
    }

    func testCompleteAlternateEntriesAffectOnlyAlternateTotals() {
        let selected = makeEntry(
            path: "Selected.swift",
            mode: .full,
            displayTokens: 100,
            fullTokens: 100,
            codemapTokens: 10
        )
        let auto = makeEntry(
            path: "Auto.swift",
            mode: .codemap,
            displayTokens: 12,
            fullTokens: 300,
            codemapTokens: 12
        )
        let completeOnly = makeEntry(
            path: "CompleteOnly.swift",
            mode: .codemap,
            displayTokens: 14,
            fullTokens: 0,
            codemapTokens: 14
        )

        let projection = WorkspaceSelectionProjectionService.project(.init(
            entries: [selected, auto],
            completeAlternateEntries: [completeOnly],
            codeMapUsage: .auto,
            codemapAutoEnabled: true,
            alternatePolicy: .init(includeFiles: true, codeMapUsage: .complete)
        ))

        XCTAssertEqual(projection.files.map(\.file.standardizedRelativePath), ["Selected.swift", "Auto.swift"])
        XCTAssertEqual(projection.summary, .init(
            fullCount: 1,
            sliceCount: 0,
            codemapCount: 1,
            fullTokens: 100,
            sliceTokens: 0,
            codemapTokens: 12
        ))
        XCTAssertEqual(projection.files.map(\.alternate?.tokens), [10, nil])
        XCTAssertEqual(projection.alternate?.contentTokens, 0)
        XCTAssertEqual(projection.alternate?.codemapTokens, 36)
        XCTAssertEqual(projection.alternate?.totalTokens, 36)
        XCTAssertEqual(projection.alternate?.includedTotalTokens, 36)
        XCTAssertEqual(projection.alternate?.includedFiles.map(\.file.standardizedRelativePath), [
            "Selected.swift",
            "Auto.swift",
            "CompleteOnly.swift"
        ])
    }

    func testAlternateIncludeFilesFalseUsesFrozenBaseCodemapTotalRule() {
        let entries = [
            makeEntry(path: "Full.swift", mode: .full, displayTokens: 100, fullTokens: 100, codemapTokens: 10),
            makeEntry(path: "Auto.swift", mode: .codemap, displayTokens: 12, fullTokens: 300, codemapTokens: 12)
        ]

        let selected = project(entries, alternateUsage: .selected, includeFiles: false)
        XCTAssertEqual(selected.alternate?.totalTokens, 22)
        XCTAssertEqual(selected.alternate?.includedTotalTokens, 12)
        XCTAssertEqual(selected.alternate?.includedFiles.map(\.file.standardizedRelativePath), ["Auto.swift"])

        let complete = project(entries, alternateUsage: .complete, includeFiles: false)
        XCTAssertEqual(complete.alternate?.totalTokens, 22)
        XCTAssertEqual(complete.alternate?.includedTotalTokens, 12)

        let auto = project(entries, alternateUsage: .auto, includeFiles: false)
        XCTAssertEqual(auto.alternate?.totalTokens, 112)
        XCTAssertEqual(auto.alternate?.includedTotalTokens, 12)

        let none = project(entries, alternateUsage: .none, includeFiles: false)
        XCTAssertEqual(none.alternate?.totalTokens, 100)
        XCTAssertEqual(none.alternate?.includedTotalTokens, 0)
    }

    func testBaseCodemapOriginsPreserveNormalizedAutoAndConfiguredUsage() throws {
        let entry = makeEntry(path: "Only.swift", mode: .codemap, displayTokens: 7, fullTokens: 70, codemapTokens: 7)
        let cases: [(CodeMapUsage, Bool, WorkspaceSelectionProjection.CodemapOrigin, Bool)] = [
            (.auto, true, .auto, true),
            (.auto, false, .manual, false),
            (.selected, false, .selectedMode, false),
            (.complete, false, .auto, true),
            (.none, false, .manual, false)
        ]

        for (usage, autoEnabled, expectedOrigin, expectedIsAuto) in cases {
            let projection = WorkspaceSelectionProjectionService.project(.init(
                entries: [entry],
                codeMapUsage: usage,
                codemapAutoEnabled: autoEnabled
            ))
            let file = try XCTUnwrap(projection.files.first)
            XCTAssertEqual(file.codemapOrigin, expectedOrigin)
            XCTAssertEqual(file.isAuto, expectedIsAuto)
        }
    }

    func testExplicitCodemapAvailabilityDoesNotDependOnTokenCount() throws {
        let zeroTokenAvailable = makeEntry(
            path: "Zero.swift",
            mode: .full,
            displayTokens: 50,
            fullTokens: 50,
            codemapTokens: 0,
            codemapAvailable: true
        )
        let nonzeroUnavailable = makeEntry(
            path: "Unavailable.swift",
            mode: .slice,
            displayTokens: 25,
            fullTokens: 75,
            codemapTokens: 99,
            codemapAvailable: false
        )

        let selected = project([zeroTokenAvailable, nonzeroUnavailable], alternateUsage: .selected)
        let zero = try XCTUnwrap(selected.files.first)
        XCTAssertEqual(zero.alternate, .init(mode: .codemap, tokens: 0, codemapOrigin: .selectedMode))
        XCTAssertNil(selected.files.last?.alternate)
        XCTAssertEqual(selected.alternate?.codemapTokens, 0)
        XCTAssertEqual(selected.alternate?.contentTokens, 25)

        let complete = project([zeroTokenAvailable, nonzeroUnavailable], alternateUsage: .complete)
        XCTAssertEqual(complete.files.first?.alternate, .init(mode: .codemap, tokens: 0, codemapOrigin: .completeMode))
        XCTAssertNil(complete.files.last?.alternate)
        XCTAssertEqual(complete.alternate?.codemapTokens, 0)
        XCTAssertEqual(complete.alternate?.contentTokens, 25)
    }

    func testProjectionPreservesSelectedFolderAndSliceOrder() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "SelectionProjectionOrder")
        let fileA = root.appendingPathComponent("Sources/A.swift")
        let fileB = root.appendingPathComponent("Sources/B.swift")
        try FileSystemTestSupport.write("alpha", to: fileA)
        try FileSystemTestSupport.write("one\ntwo\nthree", to: fileB)
        let ranges = [
            LineRange(start: 3, end: 3, description: "third"),
            LineRange(start: 1, end: 1, description: "first")
        ]

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let resolution = try await PromptContextAccountingService().resolveEntries(
            selection: StoredSelection(
                selectedPaths: [fileB.path, root.appendingPathComponent("Sources").path],
                slices: [fileB.path: ranges],
                codemapAutoEnabled: false
            ),
            store: store,
            codeMapUsage: .none
        )
        let entries = try resolution.entries.enumerated().map { index, resolved in
            try makeEntry(
                file: resolved.file,
                displayPath: "LogicalRepo/\(resolved.file.standardizedRelativePath)",
                rootPath: XCTUnwrap(resolved.rootFolderPath),
                mode: resolved.mode == .sliced ? .slice : .full,
                ranges: resolved.lineRanges ?? [],
                displayTokens: index + 1,
                fullTokens: index + 1,
                codemapTokens: 0,
                codemapAvailable: false
            )
        }

        let projection = WorkspaceSelectionProjectionService.project(.init(
            entries: entries,
            codeMapUsage: .none,
            codemapAutoEnabled: false
        ))

        XCTAssertEqual(projection.files.map(\.file.standardizedRelativePath), [
            "Sources/B.swift",
            "Sources/A.swift",
            "Sources/B.swift"
        ])
        XCTAssertEqual(projection.files.map(\.mode), [.slice, .full, .full])
        XCTAssertEqual(projection.files.map(\.metadata.displayPath), [
            "LogicalRepo/Sources/B.swift",
            "LogicalRepo/Sources/A.swift",
            "LogicalRepo/Sources/B.swift"
        ])
        XCTAssertEqual(projection.slices.map(\.file.standardizedRelativePath), ["Sources/B.swift"])
        XCTAssertEqual(projection.slices.first?.ranges, ranges)
    }

    func testInjectedDisplayMetadataDoesNotReplacePhysicalProvenanceAndInvalidOrderIsStable() throws {
        let physicalPath = "/tmp/worktrees/session/Sources/A.swift"
        let file = WorkspaceFileRecord(
            rootID: UUID(),
            name: "A.swift",
            relativePath: "Sources/A.swift",
            fullPath: physicalPath,
            parentFolderID: nil
        )
        let entry = makeEntry(
            file: file,
            displayPath: "LogicalRepo/Sources/A.swift",
            rootPath: "/tmp/worktrees/session",
            mode: .full,
            displayTokens: 5,
            fullTokens: 5,
            codemapTokens: 0,
            codemapAvailable: false
        )

        let projection = WorkspaceSelectionProjectionService.project(.init(
            entries: [entry],
            codeMapUsage: .none,
            codemapAutoEnabled: false,
            missingPaths: ["missing-b", "missing-a"],
            invalidPaths: ["invalid-b", "invalid-a"]
        ))
        let projected = try XCTUnwrap(projection.files.first)

        XCTAssertEqual(projected.file.fullPath, physicalPath)
        XCTAssertEqual(projected.file.standardizedFullPath, physicalPath)
        XCTAssertEqual(projected.metadata.displayPath, "LogicalRepo/Sources/A.swift")
        XCTAssertEqual(projected.metadata.rootPath, "/tmp/worktrees/session")
        XCTAssertEqual(projected.metadata.pathWithinRoot, "Sources/A.swift")
        XCTAssertEqual(projection.invalidPaths, ["missing-b", "missing-a", "invalid-b", "invalid-a"])
    }

    func testEmptyProjectionHasZeroTotalsAndRetainsInvalidPaths() {
        let projection = WorkspaceSelectionProjectionService.project(.init(
            entries: [],
            codeMapUsage: .auto,
            codemapAutoEnabled: true,
            missingPaths: ["missing"],
            invalidPaths: ["invalid"],
            alternatePolicy: .init(includeFiles: true, codeMapUsage: .selected)
        ))

        XCTAssertEqual(projection.files, [])
        XCTAssertEqual(projection.slices, [])
        XCTAssertEqual(projection.summary, .empty)
        XCTAssertEqual(projection.totalTokens, 0)
        XCTAssertEqual(projection.invalidPaths, ["missing", "invalid"])
        XCTAssertEqual(projection.alternate, .init(
            codeMapUsage: .selected,
            includesFiles: true,
            contentTokens: 0,
            codemapTokens: 0,
            totalTokens: 0,
            includedTotalTokens: 0
        ))
    }

    private func project(
        _ entries: [WorkspaceSelectionProjectionRequest.Entry],
        alternateUsage: CodeMapUsage,
        includeFiles: Bool = true
    ) -> WorkspaceSelectionProjection {
        WorkspaceSelectionProjectionService.project(.init(
            entries: entries,
            codeMapUsage: .auto,
            codemapAutoEnabled: true,
            alternatePolicy: .init(includeFiles: includeFiles, codeMapUsage: alternateUsage)
        ))
    }

    private func makeEntry(
        path: String,
        mode: WorkspaceSelectionProjection.BaseMode,
        ranges: [LineRange] = [],
        displayTokens: Int,
        fullTokens: Int,
        codemapTokens: Int,
        codemapAvailable: Bool = true
    ) -> WorkspaceSelectionProjectionRequest.Entry {
        let file = WorkspaceFileRecord(
            rootID: UUID(),
            name: (path as NSString).lastPathComponent,
            relativePath: path,
            fullPath: "/physical/root/\(path)",
            parentFolderID: nil
        )
        return makeEntry(
            file: file,
            displayPath: path,
            rootPath: "/physical/root",
            mode: mode,
            ranges: ranges,
            displayTokens: displayTokens,
            fullTokens: fullTokens,
            codemapTokens: codemapTokens,
            codemapAvailable: codemapAvailable
        )
    }

    private func makeEntry(
        file: WorkspaceFileRecord,
        displayPath: String,
        rootPath: String,
        mode: WorkspaceSelectionProjection.BaseMode,
        ranges: [LineRange] = [],
        displayTokens: Int,
        fullTokens: Int,
        codemapTokens: Int,
        codemapAvailable: Bool
    ) -> WorkspaceSelectionProjectionRequest.Entry {
        WorkspaceSelectionProjectionRequest.Entry(
            file: file,
            metadata: .init(
                displayPath: displayPath,
                rootPath: rootPath,
                pathWithinRoot: file.standardizedRelativePath
            ),
            mode: mode,
            ranges: ranges,
            tokens: .init(
                displayTokens: displayTokens,
                fullTokens: fullTokens,
                codemapTokens: codemapTokens
            ),
            codemapAvailable: codemapAvailable
        )
    }
}
