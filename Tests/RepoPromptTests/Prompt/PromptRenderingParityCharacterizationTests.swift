import Foundation
@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

final class PromptRenderingParityCharacterizationTests: XCTestCase {
    private let rootID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let rootPath = "/workspace/Alpha"
    private let modificationDate = Date(timeIntervalSince1970: 1000)

    func testPromptSectionIdentityAndDefaultOrderRemainFrozen() {
        XCTAssertEqual(PromptSection.allCases.map(\.rawValue), [
            "fileMap",
            "fileContents",
            "metaPrompts",
            "userInstructions",
            "gitDiff"
        ])
        XCTAssertEqual(PromptAssemblyBuilder.defaultSectionOrder, [
            .fileMap,
            .fileContents,
            .gitDiff,
            .metaPrompts,
            .userInstructions
        ])
    }

    func testPromptAssemblyFreezesDisabledSectionsSeparatorsTrailingNewlinesAndDuplicateUserPromptBehavior() {
        let order: [PromptSection] = [.metaPrompts, .fileContents, .userInstructions, .fileMap, .gitDiff]
        let snippets: [PromptSection: String] = [
            .fileMap: "MAP",
            .fileContents: "FILES\n\n",
            .metaPrompts: "META\n",
            .userInstructions: "USER\n\n",
            .gitDiff: ""
        ]

        XCTAssertEqual(
            PromptAssemblyBuilder.build(
                order: order,
                disabled: [.fileContents, .userInstructions],
                duplicateUserInstructionsAtTop: false,
                snippets: snippets
            ),
            "META\nMAP\n"
        )
        XCTAssertEqual(
            PromptAssemblyBuilder.build(
                order: order,
                disabled: [.fileContents, .userInstructions],
                duplicateUserInstructionsAtTop: true,
                snippets: snippets
            ),
            "USER\n\nMETA\nMAP\n"
        )
        XCTAssertEqual(
            PromptAssemblyBuilder.build(
                order: order,
                disabled: [.fileContents],
                duplicateUserInstructionsAtTop: true,
                snippets: snippets
            ),
            "USER\n\nMETA\nUSER\n\nMAP\n"
        )
    }

    func testResolvedEntryRenderingFreezesFullSliceCodemapAndMissingCodemapFallbackOrdering() {
        let full = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            relativePath: "Sources/Full.swift",
            content: "struct Full {}\n"
        )
        let sliced = makeEntry(
            id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            relativePath: "Sources/Sliced.swift",
            content: "one\ntwo\nthree\nfour\n",
            isCodemap: false,
            ranges: [
                LineRange(start: 3, end: 3, description: "third"),
                LineRange(start: 1, end: 1)
            ]
        )
        let codemap = makeEntry(
            id: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            relativePath: "Sources/Structure.swift",
            content: nil,
            isCodemap: true
        )
        let missingCodemap = makeEntry(
            id: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",
            relativePath: "Sources/MissingCodemap.swift",
            content: "struct MissingCodemapFallback {}\n",
            isCodemap: true
        )
        let codemapSnapshot = makeCodemapSnapshot(for: codemap)

        let records = PromptPackagingService.generateFileBlocksDetailed(
            files: [full, codemap, sliced, missingCodemap],
            filePathDisplay: .full,
            codemapSnapshots: [codemap.file.id: codemapSnapshot]
        )

        let expectedFull = "File: /workspace/Alpha/Sources/Full.swift\n```swift\nstruct Full {}\n\n```"
        let expectedCodemap = "File: /workspace/Alpha/Sources/Structure.swift\nImports:\n---\n\nFunctions:\n  - L7: func codemapOnlySymbol()\n---\n"
        let expectedSlice = "File: /workspace/Alpha/Sources/Sliced.swift\n(lines 1)\n```swift\none\n\n```\n\n(lines 3: third)\n```swift\nthree\n\n```"
        let expectedMissingCodemap = "File: /workspace/Alpha/Sources/MissingCodemap.swift\n```swift\nstruct MissingCodemapFallback {}\n\n```"

        XCTAssertEqual(records.map(\.file.relativePath), [
            "Sources/Full.swift",
            "Sources/Structure.swift",
            "Sources/Sliced.swift",
            "Sources/MissingCodemap.swift"
        ])
        XCTAssertEqual(records.map(\.isCodemap), [false, true, false, false])
        XCTAssertEqual(records.map(\.text), [
            expectedFull,
            expectedCodemap,
            expectedSlice,
            expectedMissingCodemap
        ])

        let partitioned = PromptPackagingService.generatePartitionedFileBlocks(
            [full, codemap, sliced, missingCodemap],
            filePathDisplay: .full,
            codemapSnapshots: [codemap.file.id: codemapSnapshot]
        )
        XCTAssertEqual(partitioned.codemapBlocks, [expectedCodemap])
        XCTAssertEqual(partitioned.contentBlocks, [expectedFull, expectedSlice, expectedMissingCodemap])
        XCTAssertEqual(occurrences(of: "codemapOnlySymbol", in: partitioned.codemapBlocks.joined()), 1)
        XCTAssertEqual(occurrences(of: "codemapOnlySymbol", in: partitioned.contentBlocks.joined()), 0)
        XCTAssertEqual(occurrences(of: "MissingCodemapFallback", in: partitioned.codemapBlocks.joined()), 0)
        XCTAssertEqual(occurrences(of: "MissingCodemapFallback", in: partitioned.contentBlocks.joined()), 1)
    }

    func testResolvedClipboardPackagingFreezesDiffArtifactOrderingAndNonDuplication() async {
        let full = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            relativePath: "Sources/Full.swift",
            content: "struct Full {}\n"
        )
        let diffOne = makeEntry(
            id: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
            relativePath: "_git_data/repos/demo/2026-06-05/diff/first.patch",
            content: "PATCH-ONE"
        )
        let codemap = makeEntry(
            id: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            relativePath: "Sources/Structure.swift",
            content: nil,
            isCodemap: true
        )
        let sliced = makeEntry(
            id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            relativePath: "Sources/Sliced.swift",
            content: "one\ntwo\nthree\nfour\n",
            ranges: [
                LineRange(start: 3, end: 3, description: "third"),
                LineRange(start: 1, end: 1)
            ]
        )
        let diffTwo = makeEntry(
            id: "11111111-1111-1111-1111-111111111111",
            relativePath: "_git_data/repos/demo/2026-06-05/diffs/second.DIFF",
            content: "PATCH-TWO"
        )
        let missingCodemap = makeEntry(
            id: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",
            relativePath: "Sources/MissingCodemap.swift",
            content: "struct MissingCodemapFallback {}\n",
            isCodemap: true
        )
        let entries = [full, diffOne, codemap, sliced, diffTwo, missingCodemap]
        let codemapSnapshot = makeCodemapSnapshot(for: codemap)

        let partitioned = PromptPackagingService.partitionPromptEntriesForGitDiff(entries)
        XCTAssertEqual(partitioned.diffEntries.map(\.file.relativePath), [
            "_git_data/repos/demo/2026-06-05/diff/first.patch",
            "_git_data/repos/demo/2026-06-05/diffs/second.DIFF"
        ])
        XCTAssertEqual(partitioned.codeEntries.map(\.file.relativePath), [
            "Sources/Full.swift",
            "Sources/Structure.swift",
            "Sources/Sliced.swift",
            "Sources/MissingCodemap.swift"
        ])
        XCTAssertEqual(PromptPackagingService.selectedGitDiffText(fromDiffEntries: partitioned.diffEntries), "PATCH-ONE\n\nPATCH-TWO")
        let resolvedDiff = await PromptPackagingService.resolveGitDiff(fromDiffEntries: partitioned.diffEntries) {
            "GENERATED-FALLBACK"
        }
        XCTAssertEqual(resolvedDiff, "PATCH-ONE\n\nPATCH-TWO")

        let content = await PromptPackagingService.generateClipboardContent(
            metaInstructions: [],
            userInstructions: "Ship it",
            files: entries,
            fileTreeContent: "ROOT TREE",
            gitDiff: "GENERATED-FALLBACK",
            includeSavedPrompts: true,
            includeFiles: true,
            includeUserPrompt: true,
            filePathDisplay: .full,
            codemapSnapshots: [codemap.file.id: codemapSnapshot],
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: [],
            duplicateUserInstructionsAtTop: false
        )

        let expectedFull = "File: /workspace/Alpha/Sources/Full.swift\n```swift\nstruct Full {}\n\n```"
        let expectedCodemap = "File: /workspace/Alpha/Sources/Structure.swift\nImports:\n---\n\nFunctions:\n  - L7: func codemapOnlySymbol()\n---\n"
        let expectedSlice = "File: /workspace/Alpha/Sources/Sliced.swift\n(lines 1)\n```swift\none\n\n```\n\n(lines 3: third)\n```swift\nthree\n\n```"
        let expectedMissingCodemap = "File: /workspace/Alpha/Sources/MissingCodemap.swift\n```swift\nstruct MissingCodemapFallback {}\n\n```"
        let expected = "<file_map>\nROOT TREE\n\n\(expectedCodemap)\n</file_map>\n"
            + "<file_contents>\n\(expectedFull)\n\n\(expectedSlice)\n\n\(expectedMissingCodemap)\n</file_contents>\n"
            + "<git_diff>\nPATCH-ONE\n\nPATCH-TWO\n</git_diff>\n"
            + "<user_instructions>\nShip it\n</user_instructions>\n"

        XCTAssertEqual(content, expected)
        XCTAssertEqual(occurrences(of: "codemapOnlySymbol", in: content), 1)
        XCTAssertEqual(occurrences(of: "struct Full", in: content), 1)
        XCTAssertEqual(occurrences(of: "MissingCodemapFallback", in: content), 1)
        XCTAssertEqual(occurrences(of: "PATCH-ONE", in: content), 1)
        XCTAssertEqual(occurrences(of: "PATCH-TWO", in: content), 1)
        XCTAssertEqual(occurrences(of: "GENERATED-FALLBACK", in: content), 0)
        XCTAssertEqual(occurrences(of: "_git_data/", in: content), 0)
    }

    private func makeEntry(
        id: String,
        relativePath: String,
        content: String?,
        isCodemap: Bool = false,
        ranges: [LineRange]? = nil
    ) -> ResolvedPromptFileEntry {
        let fileID = UUID(uuidString: id)!
        let file = WorkspaceFileRecord(
            id: fileID,
            rootID: rootID,
            name: (relativePath as NSString).lastPathComponent,
            relativePath: relativePath,
            fullPath: "\(rootPath)/\(relativePath)",
            parentFolderID: nil,
            modificationDate: modificationDate
        )
        return ResolvedPromptFileEntry(
            file: file,
            isCodemap: isCodemap,
            lineRanges: ranges,
            mode: ranges == nil ? (isCodemap ? .codemap : .fullFile) : .sliced,
            loadedContent: content,
            rootFolderPath: rootPath
        )
    }

    private func makeCodemapSnapshot(for entry: ResolvedPromptFileEntry) -> WorkspaceCodemapSnapshot {
        WorkspaceCodemapSnapshot(
            fileID: entry.file.id,
            rootID: entry.file.rootID,
            rootPath: rootPath,
            relativePath: entry.file.relativePath,
            fullPath: entry.file.fullPath,
            modificationDate: modificationDate,
            fileAPI: FileAPI(
                filePath: entry.file.fullPath,
                imports: [],
                classes: [],
                functions: [
                    FunctionInfo(
                        name: "codemapOnlySymbol",
                        parameters: [],
                        returnType: nil,
                        definitionLine: "func codemapOnlySymbol()",
                        lineNumber: 7
                    )
                ],
                enums: [],
                globalVars: [],
                macros: [],
                referencedTypes: []
            )
        )
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
