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
