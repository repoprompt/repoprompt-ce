import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

/// Regression tests for the tool-card presentation projection fence.
///
/// Tool-card presentation derivations (DTO decoding, structured-object
/// parsing, status classification) are deterministic functions of immutable
/// transcript JSON. These tests demonstrate that repeated evaluation — the
/// shape of repeated SwiftUI `body` recomputation — performs each derivation
/// once per unique input revision via `ToolCardProjectionCache`, stays
/// deterministic, and remains memory-bounded.
final class ToolCardProjectionFenceTests: XCTestCase {
    private struct ProbeArgs: Decodable, Equatable {
        let path: String?
        let maxDepth: Int?
    }

    private struct ProbeResult: Decodable, Equatable {
        let status: String

        private enum CodingKeys: String, CodingKey {
            case status
        }
    }

    // MARK: - Cache core semantics

    func testProjectionComputesOncePerUniqueInput() {
        let cache = ToolCardProjectionCache()
        var computeCount = 0

        for _ in 0 ..< 5 {
            let value = cache.projection(String.self, variant: "probe", primary: "{\"a\":1}") {
                computeCount += 1
                return "derived"
            }
            XCTAssertEqual(value, "derived")
        }

        XCTAssertEqual(computeCount, 1)
        let metrics = cache.metricsSnapshot()
        XCTAssertEqual(metrics.missCount, 1)
        XCTAssertEqual(metrics.hitCount, 4)
    }

    func testProjectionMemoizesFailedDerivationsWithoutRetry() {
        let cache = ToolCardProjectionCache()
        var computeCount = 0

        for _ in 0 ..< 3 {
            let value = cache.projection(String.self, variant: "probe", primary: "not json") { () -> String? in
                computeCount += 1
                return nil
            }
            XCTAssertNil(value)
        }

        XCTAssertEqual(computeCount, 1)
    }

    func testProjectionDoesNotCacheEmptyPayloads() {
        let cache = ToolCardProjectionCache()
        var computeCount = 0

        for _ in 0 ..< 2 {
            _ = cache.projection(String.self, variant: "probe", primary: nil) {
                computeCount += 1
                return "x"
            }
            _ = cache.projection(String.self, variant: "probe", primary: "") {
                computeCount += 1
                return "x"
            }
        }

        XCTAssertEqual(computeCount, 4)
        XCTAssertEqual(cache.entryCount, 0)
    }

    func testProjectionIsolatesKindVariantAndSecondaryKeys() {
        let cache = ToolCardProjectionCache()
        let raw = "{\"a\":1}"

        let stringValue = cache.projection(String.self, variant: "v1", primary: raw) { "s" }
        let intValue = cache.projection(Int.self, variant: "v1", primary: raw) { 7 }
        let otherVariant = cache.projection(String.self, variant: "v2", primary: raw) { "t" }
        let withSecondary = cache.projection(String.self, variant: "v1", primary: raw, secondary: "args") { "u" }

        XCTAssertEqual(stringValue, "s")
        XCTAssertEqual(intValue, 7)
        XCTAssertEqual(otherVariant, "t")
        XCTAssertEqual(withSecondary, "u")
        XCTAssertEqual(cache.metricsSnapshot().missCount, 4)
        XCTAssertEqual(cache.entryCount, 4)

        // Repeats hit their own entries without recomputation.
        XCTAssertEqual(cache.projection(String.self, variant: "v1", primary: raw) { "unused" }, "s")
        XCTAssertEqual(cache.projection(Int.self, variant: "v1", primary: raw) { -1 }, 7)
        XCTAssertEqual(cache.metricsSnapshot().missCount, 4)
    }

    func testProjectionStorageStaysBoundedAndRecoversAfterEviction() {
        let cache = ToolCardProjectionCache()

        for index in 0 ..< (ToolCardProjectionCache.maxEntryCount + 8) {
            _ = cache.projection(Int.self, variant: "probe", primary: "payload-\(index)") { index }
        }

        let metrics = cache.metricsSnapshot()
        XCTAssertGreaterThanOrEqual(metrics.evictionCount, 1)
        XCTAssertLessThanOrEqual(cache.entryCount, ToolCardProjectionCache.maxEntryCount)

        // Evicted entries recompute correctly on demand.
        let recomputed = cache.projection(Int.self, variant: "probe", primary: "payload-0") { 0 }
        XCTAssertEqual(recomputed, 0)
    }

    // MARK: - ToolJSON fence wiring

    func testDecodeArgsIsFencedAndDeterministic() {
        let cache = ToolCardProjectionCache()
        let json = "{\"path\": \"a/b/c.swift\", \"max_depth\": 3}"

        let first = ToolJSON.decodeArgs(ProbeArgs.self, from: json, cache: cache)
        let second = ToolJSON.decodeArgs(ProbeArgs.self, from: json, cache: cache)

        XCTAssertEqual(first, ProbeArgs(path: "a/b/c.swift", maxDepth: 3))
        XCTAssertEqual(first, second)
        let metrics = cache.metricsSnapshot()
        XCTAssertEqual(metrics.missCount, 1)
        XCTAssertEqual(metrics.hitCount, 1)
    }

    func testDecodeResultIsFencedIncludingEnvelopeUnwrapping() {
        let cache = ToolCardProjectionCache()
        let json = "{\"ok\": {\"status\": \"done\"}}"

        let first = ToolJSON.decodeResult(ProbeResult.self, from: json, cache: cache)
        XCTAssertEqual(first, ProbeResult(status: "done"))

        let missesAfterFirst = cache.metricsSnapshot().missCount
        let second = ToolJSON.decodeResult(ProbeResult.self, from: json, cache: cache)
        XCTAssertEqual(second, first)
        XCTAssertEqual(cache.metricsSnapshot().missCount, missesAfterFirst, "repeat decode must not derive again")
    }

    func testRawObjectAndStructuredResultObjectAreFenced() {
        let cache = ToolCardProjectionCache()
        let json = "{\"status\": \"completed\", \"count\": 2}"

        let rawFirst = ToolJSON.rawObject(from: json, cache: cache)
        XCTAssertEqual(rawFirst?["status"] as? String, "completed")
        let structuredFirst = ToolJSON.structuredResultObject(from: json, cache: cache)
        XCTAssertEqual(structuredFirst?["count"] as? Int, 2)

        let missesAfterFirst = cache.metricsSnapshot().missCount
        _ = ToolJSON.rawObject(from: json, cache: cache)
        _ = ToolJSON.structuredResultObject(from: json, cache: cache)
        XCTAssertEqual(cache.metricsSnapshot().missCount, missesAfterFirst)
    }

    func testDistinctPayloadRevisionsDeriveFreshProjections() {
        let cache = ToolCardProjectionCache()
        let first = ToolJSON.decodeArgs(ProbeArgs.self, from: "{\"path\": \"one\"}", cache: cache)
        let second = ToolJSON.decodeArgs(ProbeArgs.self, from: "{\"path\": \"two\"}", cache: cache)

        XCTAssertEqual(first?.path, "one")
        XCTAssertEqual(second?.path, "two")
        XCTAssertEqual(cache.metricsSnapshot().missCount, 2)
    }

    func testAskUserCardDecodesRawAndProviderFormattedAnswers() throws {
        let args = #"{"questions":[{"id":"scope","question":"Which files?"},{"id":"tests","question":"Run tests?"}]}"#
        let response: Value = .object([
            "answers": .object([
                "scope": .object(["answers": .array([.string("Sources only")]), "skipped": .bool(false)])
            ]),
            "timed_out": .bool(true),
            "skipped": .bool(false)
        ])
        let content = ToolOutputFormatter.buildContentBlocks(
            toolName: "ask_user", args: [:], result: response, emitResources: false
        )
        guard case let .text(formattedText, _, _) = try XCTUnwrap(content.first) else {
            return XCTFail("ask_user should be formatted as text")
        }
        let wireResult = CallTool.Result(content: content, isError: false)
        let codexEnvelope = try JSONEncoder().encode(["Ok": wireResult])
        let payloads = [
            ToolOutputFormatter.rawJSONString(response),
            formattedText,
            String(decoding: codexEnvelope, as: UTF8.self)
        ]

        for payload in payloads {
            let summary = parseAskUserQuestionSummaryRobust(args: args, result: payload)
            XCTAssertEqual(summary.questions.map(\.question), ["Which files?", "Run tests?"])
            XCTAssertEqual(summary.questions.map(\.answer), ["Sources only", "No response (timed out)"])
            XCTAssertEqual(summary.statusText, "Timed out")
        }
    }

    func testAskUserCardKeepsLegacyScalarRepliesLiteral() {
        let args = #"{"question":"Which files?"}"#
        let scalar = "```json\n{\"answer\":\"Sources only\"}\n```"
        let summary = parseAskUserQuestionSummaryRobust(args: args, result: scalar)

        XCTAssertEqual(summary.questions.first?.question, "Which files?")
        XCTAssertEqual(summary.questions.first?.answer, scalar)
    }

    // MARK: - Status classification fence

    func testStatusResolutionIsFencedAcrossRepeatedEvaluation() {
        let cache = ToolCardProjectionCache()
        let raw = "{\"is_error\": false, \"status\": \"completed\"}"

        let first = ToolResultStatusResolver.resolve(toolIsError: nil, raw: raw, fallback: .neutral, cache: cache)
        XCTAssertEqual(first, .success)

        let missesAfterFirst = cache.metricsSnapshot().missCount
        for _ in 0 ..< 3 {
            let repeated = ToolResultStatusResolver.resolve(toolIsError: nil, raw: raw, fallback: .neutral, cache: cache)
            XCTAssertEqual(repeated, .success)
        }
        XCTAssertEqual(cache.metricsSnapshot().missCount, missesAfterFirst, "repeat resolution must not classify again")
    }

    func testStatusResolutionKeepsInputVariantsIsolated() {
        let cache = ToolCardProjectionCache()
        let raw = "{\"note\": \"no status keys\"}"

        let asFailure = ToolResultStatusResolver.resolve(toolIsError: true, raw: raw, fallback: .neutral, cache: cache)
        let asFallback = ToolResultStatusResolver.resolve(toolIsError: nil, raw: raw, fallback: .neutral, cache: cache)
        let asRunningFallback = ToolResultStatusResolver.resolve(toolIsError: nil, raw: raw, fallback: .running, cache: cache)

        XCTAssertEqual(asFailure, .failure)
        XCTAssertEqual(asFallback, .neutral)
        XCTAssertEqual(asRunningFallback, .running)
    }

    func testStatusResolutionMatchesUnfencedBehaviorAcrossRepresentativePayloads() {
        let payloads: [(raw: String?, toolIsError: Bool?, expected: ToolCardStatus)] = [
            (nil, true, .failure),
            (nil, false, .success),
            (nil, nil, .neutral),
            ("{\"is_error\": true}", nil, .failure),
            ("{\"exit_code\": 0, \"type\": \"command_execution\"}", nil, .success),
            ("{\"errors\": [\"boom\"]}", nil, .failure),
            ("{\"warning\": \"partial\"}", nil, .warning),
            ("{\"ok\": true}", nil, .success)
        ]

        for payload in payloads {
            // Two independent caches must agree: the projection is a pure
            // function of the payload, never cross-contaminated state.
            let one = ToolResultStatusResolver.resolve(
                toolIsError: payload.toolIsError,
                raw: payload.raw,
                fallback: .neutral,
                cache: ToolCardProjectionCache()
            )
            let two = ToolResultStatusResolver.resolve(
                toolIsError: payload.toolIsError,
                raw: payload.raw,
                fallback: .neutral,
                cache: ToolCardProjectionCache()
            )
            XCTAssertEqual(one, payload.expected, "payload: \(payload.raw ?? "nil")")
            XCTAssertEqual(one, two, "payload: \(payload.raw ?? "nil")")
        }
    }
}

final class ToolResultMarkdownRendererTests: XCTestCase {
    func testRepoPromptTransportRendersMarkdownInsteadOfEnvelope() {
        let payload = ###"{"Ok":{"content":[{"type":"text","text":"## File Read\n\n```swift\nlet value = 1\n```"}]}}"###
        let output = ToolResultMarkdownRenderer.render(toolName: "read_file", argsJSON: nil, resultPayload: payload)
        XCTAssertEqual(output?.text, "## File Read\n\n```swift\nlet value = 1\n```")
        XCTAssertEqual(output?.isMarkdown, true)
        XCTAssertEqual(ToolResultMarkdownRenderer.readableResult(payload), output?.text)
    }

    func testStructuredPayloadShowsReadableFieldsWithoutLosingNestedValues() {
        let payload = #"{"items":[{"ok":true,"value":1},null],"text":"line one\nline two"}"#
        XCTAssertEqual(
            ToolResultMarkdownRenderer.readableResult(payload),
            "items:\n  1:\n    ok: true\n    value: 1\n  2: null\ntext:\n  line one\n  line two"
        )
    }

    func testMixedTransportPreservesEveryNonemptyTextBlock() {
        let payload = #"""
        {"content":[
          {"type":"text","text":"  "},
          {"type":"text","text":"## First"},
          {"type":"image","data":"dGVzdA==","mimeType":"image/png"},
          {"type":"audio","data":"dGVzdA==","mimeType":"audio/wav"},
          {"type":"resource","resource":{"uri":"file:///fixture","text":"embedded body"}},
          {"type":"resource_link","uri":"file:///fixture","name":"fixture"},
          {"type":"text","text":"**Last**"}
        ]}
        """#
        let output = ToolResultMarkdownRenderer.render(toolName: "read_file", argsJSON: nil, resultPayload: payload)
        XCTAssertEqual(output?.text, "## First\n\n**Last**")
        XCTAssertEqual(output?.isMarkdown, true)
        XCTAssertEqual(ToolResultMarkdownRenderer.readableResult(payload), output?.text)
    }

    func testBlankFirstBusinessContentPreservesFieldsShownInV110() {
        let payload = #"{"total":2,"content":[{"text":" "},{"text":"first","documentID":"a"}],"next":"b"}"#
        assertFieldProjection(payload, "content:\n  1:\n    text:  \n  2:\n    documentID: a\n    text: first\nnext: b\ntotal: 2", toolName: "custom_lookup")
    }

    func testBusinessContentImprovesOnV110FirstTextFallback() {
        let payload = #"{"total":2,"content":[{"text":"first","documentID":"a"}],"next":"b"}"#
        assertFieldProjection(payload, "content:\n  1:\n    documentID: a\n    text: first\nnext: b\ntotal: 2", toolName: "custom_lookup")
    }

    func testRejectedEnvelopePreservesTheWholeObject() {
        let typedBusinessRecord = #"{"content":[{"type":"text","text":"first","documentID":"a"}]}"#
        assertFieldProjection(typedBusinessRecord, "content:\n  1:\n    documentID: a\n    text: first\n    type: text")

        let invalidMixedBlocks = #"{"content":[{"type":"text","text":"first"},{"type":"image","data":"invalid without MIME"}]}"#
        assertFieldProjection(invalidMixedBlocks, "content:\n  1:\n    text: first\n    type: text\n  2:\n    data: invalid without MIME\n    type: image")

        let wrapperWithSibling = #"{"Ok":{"content":[{"type":"text","text":"first"}]},"next":"b"}"#
        assertFieldProjection(wrapperWithSibling, "Ok:\n  content:\n    1:\n      text: first\n      type: text\nnext: b")

        let numericErrorFlag = #"{"content":[{"type":"text","text":"first"}],"isError":1}"#
        assertFieldProjection(numericErrorFlag, "content:\n  1:\n    text: first\n    type: text\nisError: 1")
    }

    func testCanonicalStructuredContentWinsOverTextInBareAndWrappedResults() {
        let bare = ###"{"content":[{"type":"text","text":"## Preview"}],"structuredContent":{"items":["canonical"],"total":1},"isError":false,"_meta":{"transport":"private"}}"###
        let expected = "items:\n  1: canonical\ntotal: 1"
        assertFieldProjection(bare, expected)
        assertFieldProjection("{\"Ok\":\(bare)}", expected)
    }

    func testErrorResultUsesItsTextAndDoesNotBecomeAnEmptySuccess() {
        let bare = #"{"content":[{"type":"text","text":"Failed to read"}],"isError":true}"#
        XCTAssertEqual(ToolResultMarkdownRenderer.readableResult(bare), "Failed to read")
        XCTAssertEqual(render("{\"Err\":\(bare)}")?.text, "Failed to read")
        assertFieldProjection(#"{"content":[],"isError":true}"#, "Tool reported an error without text.")
        assertFieldProjection(#"{"Err":{"content":[]}}"#, "Tool reported an error without text.")
    }

    func testEmptySuccessHasNoExpandedResultAndDoesNotShowEnvelopeInCopy() {
        let empty = #"{"content":[],"isError":false}"#
        XCTAssertNil(render(empty))
        XCTAssertEqual(ToolResultMarkdownRenderer.readableResult(empty), "No result")
    }

    func testMarkdownViewCutoffUsesUTF8Bytes() throws {
        let atLimit = String(repeating: "é", count: 8192)
        let overLimit = atLimit + "x"
        for (text, expected) in [(atLimit, true), (overLimit, false)] {
            let payload = #"{"content":[{"type":"text","text":"\#(text)"}]}"#
            let output = try XCTUnwrap(render(payload))
            XCTAssertEqual(output.text, text)
            XCTAssertEqual(output.usesMarkdownView, expected)
        }
    }

    @MainActor
    func testRetainedInputIsStructuredAndSourceIsUnmodified() {
        // This input is byte-for-byte a valid envelope shape. Role, not shape, governs input.
        let input = #"{"content":[{"type":"text","text":"first"}]}"#
        let inputFields = "Input\ncontent:\n  1:\n    text: first\n    type: text"
        let toolCall = AgentChatItem(kind: .toolCall, text: "", toolName: "custom_lookup", toolArgsJSON: input)
        let call = AgentTranscriptRow.RetainedContent(item: toolCall, hydratedResult: nil)
        XCTAssertEqual(call.readableText, inputFields)
        XCTAssertEqual(call.source, input)

        let output = " \n" + input + " \n"
        let stored = AgentChatItem(kind: .toolResult, text: "", toolName: "custom_lookup", toolArgsJSON: input, toolResultJSON: output)
        let storedResult = AgentTranscriptRow.RetainedContent(item: stored, hydratedResult: nil)
        XCTAssertEqual(storedResult.readableText, inputFields + "\n\nOutput\nfirst")
        XCTAssertEqual(storedResult.source, output)

        var summary = stored
        summary.toolResultJSON = #"{"summary_only":true,"status":"ok"}"#
        let retained = AgentTranscriptRow.RetainedContent(item: summary, hydratedResult: nil)
        XCTAssertNil(retained.source)
        XCTAssertEqual(retained.readableText, inputFields + "\n\nFull output was not retained or is unavailable.")

        let hydrated = AgentTranscriptRow.RetainedContent(item: summary, hydratedResult: output)
        XCTAssertEqual(hydrated.readableText, storedResult.readableText)
        XCTAssertEqual(hydrated.source, output)
    }

    private func render(_ payload: String) -> ToolResultMarkdownRenderer.Output? {
        ToolResultMarkdownRenderer.render(toolName: "read_file", argsJSON: nil, resultPayload: payload)
    }

    private func assertFieldProjection(
        _ payload: String, _ expected: String, toolName: String = "read_file", file: StaticString = #filePath, line: UInt = #line
    ) {
        let output = ToolResultMarkdownRenderer.render(toolName: toolName, argsJSON: nil, resultPayload: payload)
        XCTAssertEqual(output, .init(text: expected, isMarkdown: false), file: file, line: line)
        XCTAssertEqual(ToolResultMarkdownRenderer.readableResult(payload), expected, file: file, line: line)
    }

    func testPlainPayloadKeptLiteralInRetainedContent() {
        let payload = "  <tag>\n[not a link]  \n"
        XCTAssertEqual(ToolResultMarkdownRenderer.readableResult(payload), payload)
    }
}
