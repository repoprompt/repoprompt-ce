import MCP
@testable import RepoPromptApp
import XCTest

final class ApplyEditsCoreRecoveryTests: XCTestCase {
    private let engine = ApplyEditsEngine.default
    private let builder = ApplyEditsRequestBuilder()

    func testRewriteUpdatesTextAndVerboseDiff() async throws {
        let request = ApplyEditsRequest(
            path: "file.swift",
            mode: .rewrite(newText: "new\n", onMissing: .error),
            verbose: true
        )

        let result = try await engine.apply(request: request, to: "old\n")

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.updatedText, "new\n")
        XCTAssertEqual(result.editsRequested, 1)
        XCTAssertEqual(result.editsApplied, 1)
        XCTAssertNotNil(result.stats)
        let diff = try XCTUnwrap(result.unifiedDiff)
        XCTAssertTrue(diff.contains("--- a/file.swift"))
        XCTAssertTrue(diff.contains("+++ b/file.swift"))
        XCTAssertTrue(diff.contains("-old"))
        XCTAssertTrue(diff.contains("+new"))
    }

    func testSingleReplaceSupportsEscapedSearchFallback() async throws {
        let request = ApplyEditsRequest(
            path: "file.swift",
            mode: .single(
                search: #"let value = \"old\"\n"#,
                replace: #"let value = \"new\"\n"#,
                replaceAll: false
            ),
            verbose: false
        )

        let result = try await engine.apply(request: request, to: "let value = \"old\"\n")

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.updatedText, "let value = \"new\"\n")
        XCTAssertEqual(result.editsRequested, 1)
        XCTAssertEqual(result.editsApplied, 1)
    }

    func testUnmatchedSearchBlockReportsSingleAndBatchContracts() async throws {
        let originalText = "present\n"
        let singleRequest = ApplyEditsRequest(
            path: "file.swift",
            mode: .single(search: "missing", replace: "replacement", replaceAll: false),
            verbose: false
        )

        do {
            _ = try await engine.apply(request: singleRequest, to: originalText)
            XCTFail("Expected unmatched single edit to fail")
        } catch let error as ApplyEditsError {
            XCTAssertEqual(error, .invalidParams("search block not found in file"))
        }

        let batchRequest = ApplyEditsRequest(
            path: "file.swift",
            mode: .batch([
                ApplyEditsOperation(search: "missing", replace: "replacement", replaceAll: false)
            ]),
            verbose: false
        )

        let result = try await engine.apply(request: batchRequest, to: originalText)

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.updatedText, originalText)
        XCTAssertEqual(result.editsRequested, 1)
        XCTAssertEqual(result.editsApplied, 0)
        XCTAssertEqual(result.outcomes, [
            EditOutcome(
                index: 0,
                status: "failed",
                error: "search block not found in file (matches are exact, including whitespace/indentation)"
            )
        ])
    }

    func testBatchLiteralFastPathReturnsNoteAndVerboseOutcomes() async throws {
        let request = ApplyEditsRequest(
            path: "file.swift",
            mode: .batch([
                ApplyEditsOperation(search: "old", replace: "new", replaceAll: false)
            ]),
            verbose: true
        )

        let result = try await engine.apply(request: request, to: "let value = old\n")

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.updatedText, "let value = new\n")
        XCTAssertEqual(result.note, "Applied via exact literal replacement")
        XCTAssertEqual(result.editsRequested, 1)
        XCTAssertEqual(result.editsApplied, 1)
        XCTAssertEqual(result.outcomes, [EditOutcome(index: 0, status: "success", error: nil)])
    }

    func testBatchDiffFallbackReportsSuccessOutcomes() async throws {
        let request = ApplyEditsRequest(
            path: "file.swift",
            mode: .batch([
                ApplyEditsOperation(search: "same", replace: "first", replaceAll: false),
                ApplyEditsOperation(search: "same", replace: "second", replaceAll: false)
            ]),
            verbose: true
        )

        let result = try await engine.apply(request: request, to: "same\nsame\n")

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.updatedText, "first\nsecond\n")
        XCTAssertNil(result.note)
        XCTAssertEqual(result.editsRequested, 2)
        XCTAssertEqual(result.editsApplied, 2)
        XCTAssertEqual(result.outcomes, [
            EditOutcome(index: 0, status: "success", error: nil),
            EditOutcome(index: 1, status: "success", error: nil)
        ])
    }

    func testBatchDiffFallbackReportsPartialOutcomes() async throws {
        let request = ApplyEditsRequest(
            path: "file.swift",
            mode: .batch([
                ApplyEditsOperation(search: "same", replace: "replacement", replaceAll: false),
                ApplyEditsOperation(search: "tail", replace: "done", replaceAll: false)
            ]),
            verbose: true
        )

        let result = try await engine.apply(request: request, to: "same\nsame\ntail\n")

        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.updatedText, "same\nsame\ndone\n")
        XCTAssertNil(result.note)
        XCTAssertEqual(result.editsRequested, 2)
        XCTAssertEqual(result.editsApplied, 1)
        let outcomes = try XCTUnwrap(result.outcomes)
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(outcomes[0].index, 0)
        XCTAssertEqual(outcomes[0].status, "failed")
        XCTAssertEqual(
            outcomes[0].error,
            "Search block matches multiple locations (lines 1, 2). Please make the block more specific or use the replace_all parameter to replace all occurrences."
        )
        XCTAssertEqual(outcomes[1], EditOutcome(index: 1, status: "success", error: nil))
    }

    func testEmptyGeneratedChunksFailThroughApplyEditsInternalError() async throws {
        let engine = ApplyEditsEngine(
            diffEngine: EmptyDiffChunkGenerator(),
            patchApplier: DefaultDiffChunkApplier(),
            unifiedDiffRenderer: DefaultUnifiedDiffRenderer()
        )
        let request = ApplyEditsRequest(
            path: "file.swift",
            mode: .single(search: "old", replace: "new", replaceAll: false),
            verbose: false
        )

        do {
            _ = try await engine.apply(request: request, to: "old\n")
            XCTFail("Expected empty generated chunks to fail")
        } catch let error as ApplyEditsError {
            XCTAssertEqual(error, .internalError("diff generation produced no changes."))
        }
    }

    func testRequestBuilderAcceptsBatchPayloadShapes() throws {
        struct Case {
            let name: String
            let args: [String: Value]
            let expectedReplaceAll: Bool
        }

        let cases: [Case] = [
            Case(
                name: "edits array",
                args: [
                    "path": .string("file.swift"),
                    "edits": .array([
                        .object([
                            "search": .string("old"),
                            "replace": .string("new")
                        ])
                    ])
                ],
                expectedReplaceAll: false
            ),
            Case(
                name: "single edits object",
                args: [
                    "path": .string("file.swift"),
                    "edits": .object([
                        "search": .string("old"),
                        "with": .string("new"),
                        "all": .bool(true)
                    ])
                ],
                expectedReplaceAll: true
            ),
            Case(
                name: "JSON edits array string",
                args: [
                    "path": .string("file.swift"),
                    "edits": .string("[{\"search\":\"old\",\"replace\":\"new\"}]")
                ],
                expectedReplaceAll: false
            ),
            Case(
                name: "args tool wrapper",
                args: [
                    "args": .string("{\"apply_edits\":{\"path\":\"file.swift\",\"edits\":{\"search\":\"old\",\"content\":\"new\"}}}")
                ],
                expectedReplaceAll: false
            )
        ]

        for testCase in cases {
            let request = try builder.build(from: testCase.args)
            XCTAssertEqual(request.path, "file.swift", testCase.name)
            switch request.mode {
            case let .batch(edits):
                XCTAssertEqual(edits.count, 1, testCase.name)
                XCTAssertEqual(edits[0].search, "old", testCase.name)
                XCTAssertEqual(edits[0].replace, "new", testCase.name)
                XCTAssertEqual(edits[0].replaceAll, testCase.expectedReplaceAll, testCase.name)
            default:
                XCTFail("Expected batch mode for \(testCase.name)")
            }
        }
    }
}

private struct EmptyDiffChunkGenerator: DiffChunkGenerator {
    func makeDiffChunks(
        filePath _: String,
        originalText _: String,
        search _: String?,
        replace _: String,
        replaceAll _: Bool,
        treatAsRewrite _: Bool
    ) async throws -> [DiffChunk] {
        []
    }
}
