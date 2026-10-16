@testable import RepoPromptApp
import XCTest

final class DiffChunkTextApplierTests: XCTestCase {
    func testAdjustsLaterStartLineForCumulativeOffsets() throws {
        let scenarios: [(name: String, chunks: [DiffChunk], expected: String)] = [
            (
                "insertion shifts later replacement forward",
                [
                    DiffChunk(
                        lines: [DiffLine(content: "+inserted")],
                        startLine: 2
                    ),
                    DiffChunk(
                        lines: [
                            DiffLine(content: "-d"),
                            DiffLine(content: "+D")
                        ],
                        startLine: 3
                    )
                ],
                "a\nb\ninserted\nc\nD"
            ),
            (
                "deletion shifts later replacement backward",
                [
                    DiffChunk(
                        lines: [DiffLine(content: "-b")],
                        startLine: 1
                    ),
                    DiffChunk(
                        lines: [
                            DiffLine(content: "-d"),
                            DiffLine(content: "+D")
                        ],
                        startLine: 3
                    )
                ],
                "a\nc\nD"
            )
        ]

        for scenario in scenarios {
            try XCTContext.runActivity(named: scenario.name) { _ in
                let result = try DiffChunkTextApplier.apply(chunks: scenario.chunks, to: "a\nb\nc\nd")
                XCTAssertEqual(result, scenario.expected)
            }
        }
    }

    func testPreservesTextShapeAndReturnsOriginalTextForEmptyChunks() throws {
        let replacementChunk = DiffChunk(
            lines: [
                DiffLine(content: "-two"),
                DiffLine(content: "+TWO")
            ],
            startLine: 1
        )
        let scenarios: [(name: String, original: String, chunks: [DiffChunk], expected: String, forbiddenFragment: String?)] = [
            ("CRLF remains CRLF", "one\r\ntwo\r\nthree", [replacementChunk], "one\r\nTWO\r\nthree", "one\nTWO"),
            ("existing trailing LF remains present", "one\ntwo\n", [replacementChunk], "one\nTWO\n", nil),
            ("empty chunk input returns byte-equivalent original text", "one\r\ntwo\r\n", [], "one\r\ntwo\r\n", nil)
        ]

        for scenario in scenarios {
            try XCTContext.runActivity(named: scenario.name) { _ in
                let result = try DiffChunkTextApplier.apply(chunks: scenario.chunks, to: scenario.original)
                XCTAssertEqual(result, scenario.expected)
                if let forbiddenFragment = scenario.forbiddenFragment {
                    XCTAssertFalse(result.contains(forbiddenFragment))
                }
            }
        }
    }

    func testAppliesChunksInInputOrder() throws {
        let original = "a\nb"
        let chunks = [
            DiffChunk(
                lines: [DiffLine(content: "+first")],
                startLine: 1
            ),
            DiffChunk(
                lines: [DiffLine(content: "+second")],
                startLine: 1
            )
        ]

        let result = try DiffChunkTextApplier.apply(chunks: chunks, to: original)

        XCTAssertEqual(result, "a\nsecond\nfirst\nb")
    }

    func testAppliesDecodedIndentation() throws {
        let original = "func f() {\n}"
        let chunks = [
            DiffChunk(
                lines: [DiffLine(content: "+<s4>let value = 1")],
                startLine: 1
            )
        ]

        let result = try DiffChunkTextApplier.apply(chunks: chunks, to: original)

        XCTAssertEqual(result, "func f() {\n    let value = 1\n}")
    }
}
