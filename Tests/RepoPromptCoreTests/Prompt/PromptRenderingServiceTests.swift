@testable import RepoPromptCore
import XCTest

final class PromptRenderingServiceTests: XCTestCase {
    func testFullFileRenderingPreservesFencesEmptyContentOmissionIndicesAndTrailingWhitespace() {
        let blocks = PromptRenderingService.renderFileBlocks([
            PromptRenderingFileValue(
                displayPath: "Sources/A.swift",
                fileName: "A.swift",
                content: "struct A {}\n"
            ),
            PromptRenderingFileValue(
                displayPath: "Sources/Missing.swift",
                fileName: "Missing.swift",
                content: nil
            ),
            PromptRenderingFileValue(
                displayPath: "README",
                fileName: "README",
                content: ""
            )
        ])

        XCTAssertEqual(blocks.map(\.inputIndex), [0, 2])
        XCTAssertEqual(blocks.map(\.kind), [.content, .content])
        XCTAssertEqual(blocks.map(\.text), [
            "File: Sources/A.swift\n```swift\nstruct A {}\n\n```",
            "File: README\n```\n\n```"
        ])
        XCTAssertEqual(PromptRenderingService.codeFenceStart(for: "A.swift"), "```swift")
        XCTAssertEqual(PromptRenderingService.codeFenceStart(for: "README"), "```")
    }

    func testSliceRenderingUsesNormalizedRangeOrderLabelsDescriptionsAndSeparators() {
        let blocks = PromptRenderingService.renderFileBlocks([
            PromptRenderingFileValue(
                displayPath: "Sources/Sliced.swift",
                fileName: "Sliced.swift",
                content: "one\ntwo\nthree\nfour\n",
                ranges: [
                    LineRange(start: 3, end: 3, description: "third"),
                    LineRange(start: 1, end: 1),
                    LineRange(start: 9, end: 12, description: "ignored")
                ]
            ),
            PromptRenderingFileValue(
                displayPath: "Sources/Merged.swift",
                fileName: "Merged.swift",
                content: "one\ntwo\nthree\n",
                ranges: [
                    LineRange(start: 2, end: 2, description: "second"),
                    LineRange(start: 1, end: 1, description: "first")
                ]
            )
        ])

        XCTAssertEqual(
            blocks[0].text,
            "File: Sources/Sliced.swift\n(lines 1)\n```swift\none\n\n```\n\n(lines 3: third)\n```swift\nthree\n\n```"
        )
        XCTAssertEqual(
            blocks[1].text,
            "File: Sources/Merged.swift\n(lines 1-2: first; second)\n```swift\none\ntwo\n\n```"
        )
    }

    func testCodemapPartitionAndMissingCodemapFallbackPreserveOrderingWithoutDuplication() {
        let values = [
            PromptRenderingFileValue(
                displayPath: "A.swift",
                fileName: "A.swift",
                content: "A\n"
            ),
            PromptRenderingFileValue(
                displayPath: "B.swift",
                fileName: "B.swift",
                content: "B full content must not render",
                codemapText: "B CODEMAP"
            ),
            PromptRenderingFileValue(
                displayPath: "Omitted.swift",
                fileName: "Omitted.swift",
                content: nil
            ),
            PromptRenderingFileValue(
                displayPath: "Fallback.swift",
                fileName: "Fallback.swift",
                content: "FALLBACK\n",
                codemapText: nil
            ),
            PromptRenderingFileValue(
                displayPath: "EmptyCodemap.swift",
                fileName: "EmptyCodemap.swift",
                content: "must not render",
                codemapText: ""
            )
        ]

        let detailed = PromptRenderingService.renderFileBlocks(values)
        XCTAssertEqual(detailed.map(\.inputIndex), [0, 1, 3, 4])
        XCTAssertEqual(detailed.map(\.kind), [.content, .codemap, .content, .codemap])

        let partitioned = PromptRenderingService.renderPartitionedFileBlocks(values)
        XCTAssertEqual(partitioned.codemapBlocks, ["B CODEMAP"])
        XCTAssertEqual(partitioned.contentBlocks, [
            "File: A.swift\n```swift\nA\n\n```",
            "File: Fallback.swift\n```swift\nFALLBACK\n\n```"
        ])
        XCTAssertFalse(partitioned.contentBlocks.joined().contains("B full content"))
        XCTAssertEqual(partitioned.contentBlocks.joined().components(separatedBy: "FALLBACK").count - 1, 1)
    }

    func testSelectedDiffRenderingPreservesSliceJoiningOrderOmissionAndTwoNewlinePartitioning() {
        let values = [
            PromptRenderingDiffValue(
                content: "a\nb\nc\n",
                ranges: [LineRange(start: 1, end: 1), LineRange(start: 3, end: 3)]
            ),
            PromptRenderingDiffValue(content: nil),
            PromptRenderingDiffValue(content: ""),
            PromptRenderingDiffValue(content: "PATCH")
        ]

        XCTAssertEqual(PromptRenderingService.renderDiffParts(values), ["a\n\nc\n", "PATCH"])
        XCTAssertEqual(PromptRenderingService.renderSelectedDiffText(values), "a\n\nc\n\n\nPATCH")
        XCTAssertNil(PromptRenderingService.renderSelectedDiffText([
            PromptRenderingDiffValue(content: nil),
            PromptRenderingDiffValue(content: "")
        ]))
    }

    func testFactualSnippetRenderingPreservesWrappersOrderingOmissionAndTrailingNewlines() {
        let snippets = PromptRenderingService.renderFactualSnippets(
            fileTreeContent: "TREE",
            codemapBlocks: ["MAP-ONE", "MAP-TWO"],
            contentBlocks: ["FILE-ONE", "FILE-TWO"],
            gitDiff: "DIFF"
        )

        XCTAssertEqual(PromptFactualEnvelopePolicy.canonical.fileMapTag, "file_map")
        XCTAssertEqual(PromptFactualEnvelopePolicy.canonical.fileContentsTag, "file_contents")
        XCTAssertEqual(PromptFactualEnvelopePolicy.canonical.gitDiffTag, "git_diff")
        XCTAssertEqual(snippets.fileMap, "<file_map>\nTREE\n\nMAP-ONE\n\nMAP-TWO\n</file_map>\n")
        XCTAssertEqual(snippets.fileContents, "<file_contents>\nFILE-ONE\n\nFILE-TWO\n</file_contents>\n")
        XCTAssertEqual(snippets.gitDiff, "<git_diff>\nDIFF\n</git_diff>\n")

        XCTAssertEqual(
            PromptRenderingService.renderFactualSnippets(
                fileTreeContent: "",
                codemapBlocks: [],
                contentBlocks: [],
                gitDiff: ""
            ),
            PromptRenderedFactualSnippets(fileMap: nil, fileContents: nil, gitDiff: nil)
        )
        XCTAssertEqual(
            PromptRenderingService.renderFactualSnippets(
                fileTreeContent: nil,
                codemapBlocks: [],
                contentBlocks: [""],
                gitDiff: nil
            ).fileContents,
            "<file_contents>\n\n</file_contents>\n"
        )
    }

    func testFactualSnippetRenderingSupportsChatStyleTreeEnvelopePolicy() {
        let snippets = PromptRenderingService.renderFactualSnippets(
            fileTreeContent: "TREE",
            codemapBlocks: [],
            contentBlocks: ["FILE"],
            gitDiff: "DIFF",
            envelopePolicy: .chatStyleTree
        )

        XCTAssertEqual(PromptFactualEnvelopePolicy.chatStyleTree.fileMapTag, "file_tree")
        XCTAssertEqual(snippets.fileMap, "<file_tree>\nTREE\n</file_tree>")
        XCTAssertEqual(snippets.fileContents, "<file_contents>\nFILE\n\n</file_contents>")
        XCTAssertEqual(snippets.gitDiff, "<git_diff>\nDIFF\n</git_diff>")
    }

    func testFactualSnippetRenderingKeepsCoreOwnedCloseSpacingAndOmissionRules() {
        let treeOnly = PromptRenderingService.renderFactualSnippets(
            fileTreeContent: "TREE\n",
            codemapBlocks: [],
            contentBlocks: [],
            gitDiff: nil
        )
        XCTAssertEqual(treeOnly.fileMap, "<file_map>\nTREE\n\n</file_map>\n")
        XCTAssertNil(treeOnly.fileContents)
        XCTAssertNil(treeOnly.gitDiff)

        let codemapOnly = PromptRenderingService.renderFactualSnippets(
            fileTreeContent: nil,
            codemapBlocks: ["CODEMAP"],
            contentBlocks: [],
            gitDiff: nil,
            envelopePolicy: .chatStyleTree
        )
        XCTAssertEqual(codemapOnly.fileMap, "<file_tree>\nCODEMAP\n</file_tree>")
        XCTAssertNil(codemapOnly.fileContents)
        XCTAssertNil(codemapOnly.gitDiff)
    }
}
