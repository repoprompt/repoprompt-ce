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

/// Saved transcripts drop tool args and reduce tool results to summaries. These tests pin that an
/// `ask_user` card replayed from storage still shows the questions and answers, instead of the
/// placeholder "Question / No response" a bare status summary produced.
final class AgentAskUserTranscriptPersistenceTests: XCTestCase {
    private let structuredArgs = """
    {"title":"Phase 3 decisions","context":"Pricing and rollout depend on these.","questions":[\
    {"id":"pricing","header":"Pricing","question":"Publish our own prices?","options":[{"label":"Yes","description":"Show them"},"No"]},\
    {"id":"regions","question":"Which regions launch first?","allows_multiple":true},\
    {"id":"later","question":"Anything else?"}]}
    """

    private let structuredResult = """
    {"answers":{\
    "pricing":{"answers":["Yes"],"selected_options":["Yes"],"custom_response":null,"skipped":false},\
    "regions":{"answers":[],"selected_options":["JP","US"],"custom_response":"EU later","skipped":false},\
    "later":{"answers":[],"selected_options":[],"custom_response":null,"skipped":true}},\
    "timed_out":false,"skipped":false,"elapsed_seconds":42}
    """

    private func persistedResultJSON(args: String?, result: String) throws -> String {
        let item = AgentChatItem.toolResult(name: "ask_user", argsJSON: args, resultJSON: result, isError: false, sequenceIndex: 1)
        return try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: item)).resultJSON
    }

    func testPersistedSummaryKeepsQuestionsAndAnswersForTheSavedCard() throws {
        let persisted = try persistedResultJSON(args: structuredArgs, result: structuredResult)
        XCTAssertLessThanOrEqual(persisted.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)

        // Saved transcripts carry no args, so the card must render from the persisted result alone.
        let card = parseAskUserQuestionSummaryRobust(args: nil, result: persisted)
        XCTAssertFalse(card.detailsUnavailable)
        XCTAssertEqual(card.displayTitle, "Phase 3 decisions (3 questions)")
        XCTAssertEqual(card.questions.map(\.header), ["Pricing", nil, nil])
        XCTAssertEqual(
            card.questions.map(\.question),
            ["Publish our own prices?", "Which regions launch first?", "Anything else?"]
        )
        XCTAssertEqual(card.questions.map(\.answer), ["Yes", "JP, US, EU later", "Skipped"])
        XCTAssertNil(card.statusText)
    }

    func testPersistedRecordIsAFixedPointUnderResanitization() throws {
        let first = try persistedResultJSON(args: structuredArgs, result: structuredResult)
        let second = try persistedResultJSON(args: nil, result: first)
        XCTAssertEqual(second, first)
    }

    func testProviderFormattedAndEnvelopedResultsPersistTheSameRecord() throws {
        let raw = try persistedResultJSON(args: structuredArgs, result: structuredResult)
        let fenced = "```json\n\(structuredResult)\n```"
        let response = try JSONDecoder().decode(Value.self, from: Data(structuredResult.utf8))
        let content = ToolOutputFormatter.buildContentBlocks(
            toolName: "ask_user", args: [:], result: response, emitResources: false
        )
        let envelope = try String(
            decoding: JSONEncoder().encode(["Ok": CallTool.Result(content: content, isError: false)]),
            as: UTF8.self
        )

        XCTAssertEqual(try persistedResultJSON(args: structuredArgs, result: fenced), raw)
        XCTAssertEqual(try persistedResultJSON(args: structuredArgs, result: envelope), raw)
    }

    func testOversizedExchangeIsClippedWithinTheBudget() throws {
        let longText = String(repeating: "long question text ", count: 60)
        let questions = (1 ... 10).map { #"{"id":"q\#($0)","header":"\#(longText)","question":"\#(longText)"}"# }
        let answers = (1 ... 10).map { #""q\#($0)":{"answers":["\#(longText)"],"skipped":false}"# }
        let args = #"{"title":"\#(longText)","questions":[\#(questions.joined(separator: ","))]}"#
        let result = #"{"answers":{\#(answers.joined(separator: ","))},"timed_out":false,"skipped":false}"#

        let persisted = try persistedResultJSON(args: args, result: result)
        XCTAssertLessThanOrEqual(persisted.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
        let card = parseAskUserQuestionSummaryRobust(args: nil, result: persisted)
        XCTAssertEqual(card.questions.count, 10)
        for question in card.questions {
            XCTAssertTrue(question.question.hasSuffix("…"))
            XCTAssertTrue(question.answer?.hasSuffix("…") == true)
        }
        XCTAssertEqual(try persistedResultJSON(args: nil, result: persisted), persisted)
    }

    func testLongIDsSharingAPrefixKeepTheirOwnAnswers() throws {
        let prefix = String(repeating: "x", count: 63) + " "
        let args = #"{"questions":[{"id":"\#(prefix)a","question":"First?"},{"id":"\#(prefix)b","question":"Second?"}]}"#
        let result = #"{"answers":{"\#(prefix)a":{"answers":["one"]},"\#(prefix)b":{"answers":["two"]}},"timed_out":false,"skipped":false}"#

        let persisted = try persistedResultJSON(args: args, result: result)
        let card = parseAskUserQuestionSummaryRobust(args: nil, result: persisted)
        XCTAssertEqual(card.questions.map(\.answer), ["one", "two"])
        XCTAssertEqual(try persistedResultJSON(args: nil, result: persisted), persisted)
    }

    func testMultibyteHeavyExchangeKeepsEveryRowAcrossPasses() throws {
        let emoji = String(repeating: "🧪", count: 48)
        let questions = (1 ... 10).map { #"{"id":"q\#($0)","question":"\#(emoji)"}"# }
        let answers = (1 ... 10).map { #""q\#($0)":{"answers":["\#(emoji)"]}"# }
        let args = #"{"questions":[\#(questions.joined(separator: ","))]}"#
        let result = #"{"answers":{\#(answers.joined(separator: ","))},"timed_out":false,"skipped":false}"#

        let persisted = try persistedResultJSON(args: args, result: result)
        XCTAssertLessThanOrEqual(persisted.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
        let card = parseAskUserQuestionSummaryRobust(args: nil, result: persisted)
        XCTAssertEqual(card.questions.count, 10)
        XCTAssertTrue(card.questions.allSatisfy { $0.answer?.hasPrefix("🧪") == true })
        XCTAssertEqual(try persistedResultJSON(args: nil, result: persisted), persisted)
    }

    func testEnvelopePrefersStructuredContentOverConflictingText() throws {
        let decoy = #"{"answers":{"pricing":{"answers":["decoy"]}},"timed_out":false,"skipped":false}"#
        let canonical = #"{"answers":{"pricing":{"answers":["canonical"]}},"timed_out":false,"skipped":false}"#
        let decoyText = try String(decoding: JSONEncoder().encode(decoy), as: UTF8.self)
        let envelope = """
        {"Ok":{"content":[{"type":"text","text":\(decoyText)}],\
        "isError":false,"structuredContent":\(canonical)}}
        """

        let card = try parseAskUserQuestionSummaryRobust(args: nil, result: persistedResultJSON(args: structuredArgs, result: envelope))
        XCTAssertEqual(card.questions.first?.answer, "canonical")
    }

    func testLegacyScalarExchangePersistsItsQuestionAndResponse() throws {
        let args = #"{"question":"Which database?","options":["Postgres","SQLite"]}"#
        let result = """
        {"answers":{"response":{"answers":["Postgres"],"selected_options":["Postgres"],"custom_response":null,"skipped":false}},\
        "response":"Postgres","timed_out":false,"skipped":false,"elapsed_seconds":3}
        """

        let card = try parseAskUserQuestionSummaryRobust(args: nil, result: persistedResultJSON(args: args, result: result))
        XCTAssertEqual(card.questions.map(\.question), ["Which database?"])
        XCTAssertEqual(card.questions.map(\.answer), ["Postgres"])
    }

    func testTimedOutExchangeKeepsItsStatus() throws {
        let result = #"{"answers":{"pricing":{"answers":["No"],"skipped":false}},"timed_out":true,"skipped":false}"#
        let card = try parseAskUserQuestionSummaryRobust(args: nil, result: persistedResultJSON(args: structuredArgs, result: result))
        XCTAssertEqual(card.questions.map(\.answer), ["No", "No response (timed out)", "No response (timed out)"])
        XCTAssertEqual(card.statusText, "Timed out")
    }

    func testSkippedInteractionKeepsItsStatus() throws {
        let result = #"{"answers":{},"timed_out":false,"skipped":true}"#
        let card = try parseAskUserQuestionSummaryRobust(args: nil, result: persistedResultJSON(args: structuredArgs, result: result))
        XCTAssertEqual(card.questions.map(\.answer), ["Skipped", "Skipped", "Skipped"])
        XCTAssertEqual(card.statusText, "Skipped")
    }

    func testLegacyStatusOnlyRecordRendersAnUnavailableStateInsteadOfAPlaceholderAnswer() {
        let legacy = #"{"status":"success","summary_only":true,"summary_text":"ask_user • success"}"#
        let card = parseAskUserQuestionSummaryRobust(args: nil, result: legacy)
        XCTAssertTrue(card.detailsUnavailable)
        XCTAssertTrue(card.questions.isEmpty)
        XCTAssertEqual(card.displayTitle, "Question")
    }

    func testTranscriptPersistenceDropsArgsButKeepsTheExchange() throws {
        let startedAt = Date(timeIntervalSince1970: 0)
        let execution = AgentTranscriptToolExecution(
            stableExecutionID: "exec-ask-user",
            toolName: "mcp__RepoPrompt__ask_user",
            invocationID: UUID(),
            argsJSON: structuredArgs,
            resultJSON: structuredResult,
            toolIsError: false,
            status: .success
        )
        let activity = AgentTranscriptActivity(
            id: UUID(),
            timestamp: startedAt,
            sequenceIndex: 1,
            role: .toolExecution,
            itemKind: .toolResult,
            text: structuredResult,
            toolExecution: execution
        )
        let transcript = AgentTranscript(
            turns: [
                AgentTranscriptTurn(
                    id: UUID(),
                    request: AgentTranscriptRequestAnchor(from: AgentChatItem.user("request", sequenceIndex: 0)),
                    responseSpans: [
                        AgentTranscriptProviderResponseSpan(
                            lifecycle: .completed,
                            startedAt: startedAt,
                            lastActivityAt: startedAt,
                            completedAt: startedAt,
                            activities: [activity]
                        )
                    ],
                    retentionTier: .full,
                    terminalState: .completed,
                    startedAt: startedAt,
                    lastActivityAt: startedAt,
                    completedAt: startedAt
                )
            ],
            nextSequenceIndex: 2
        )

        let persisted = AgentToolResultPersistencePolicy.sanitizeTranscriptForPersistence(transcript)
        let persistedActivity = try XCTUnwrap(persisted.turns.first?.responseSpans.first?.activities.first)
        let persistedExecution = try XCTUnwrap(persistedActivity.toolExecution)
        XCTAssertNil(persistedExecution.argsJSON)

        let row = persistedActivity.toItem()
        let card = parseAskUserQuestionSummaryRobust(args: row.toolArgsJSON, result: row.toolResultJSON)
        XCTAssertEqual(card.questions.map(\.answer), ["Yes", "JP, US, EU later", "Skipped"])
        XCTAssertEqual(AgentToolResultPersistencePolicy.sanitizeTranscriptForPersistence(persisted), persisted)
    }
}
