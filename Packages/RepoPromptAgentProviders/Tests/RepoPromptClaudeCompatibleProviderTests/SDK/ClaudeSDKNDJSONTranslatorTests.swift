import Foundation
@testable import RepoPromptClaudeCompatibleProvider
import XCTest

final class ClaudeSDKNDJSONTranslatorTests: XCTestCase {
    func testAssistantToolAndResultSmokePreservesUsageArgsAndStableInvocationID() throws {
        var translator = ClaudeSDKNDJSONTranslator(
            treatsToolResultErrorsAsHostOwned: { $0 == "mcp__RepoPromptCE__read_file" }
        )
        let line = jsonLine([
            "type": "assistant",
            "message": [
                "usage": [
                    "input_tokens": 7,
                    "output_tokens": 3,
                    "cache_read_input_tokens": 5,
                    "cache_creation_input_tokens": 2
                ],
                "content": [
                    ["type": "text", "text": "Hello"],
                    [
                        "type": "tool_use",
                        "id": "toolu_1",
                        "name": "mcp__RepoPromptCE__read_file",
                        "input": ["path": "Sources/App.swift"]
                    ]
                ]
            ]
        ])

        let results = translator.parseNDJSONLine(line)

        XCTAssertEqual(results.map(\.type), ["usage", "content", "tool_call"])
        guard results.count == 3 else { return }
        XCTAssertEqual(results[0].promptTokens, 7)
        XCTAssertEqual(results[0].completionTokens, 3)
        XCTAssertEqual(results[0].contextUsedTokens, 14)
        XCTAssertEqual(results[1].text, "Hello")
        XCTAssertEqual(results[2].toolName, "mcp__RepoPromptCE__read_file")
        let invocationID = try XCTUnwrap(results[2].toolInvocationID)
        XCTAssertEqual(try jsonObject(from: results[2].toolArgsJSON), ["path": "Sources/App.swift"])

        let resultLine = jsonLine([
            "type": "user",
            "message": [
                "content": [[
                    "type": "tool_result",
                    "tool_use_id": "toolu_1",
                    "content": [["type": "text", "text": "contents"]]
                ]]
            ]
        ])
        let toolResult = try XCTUnwrap(translator.parseNDJSONLine(resultLine).first)
        XCTAssertEqual(toolResult.type, "tool_result")
        XCTAssertEqual(toolResult.toolName, "mcp__RepoPromptCE__read_file")
        XCTAssertEqual(toolResult.toolOutput, "contents")
        XCTAssertEqual(toolResult.toolInvocationID, invocationID)
        XCTAssertNil(toolResult.toolIsError, "Host-owned tool result errors are tracked by the host completion handler, not inferred here.")
    }

    func testLifecycleAndStreamSmokeCoversSessionCancellationDeltaStopAndContextUsage() throws {
        var translator = ClaudeSDKNDJSONTranslator()

        let initResults = translator.parseNDJSONLine(jsonLine([
            "type": "system",
            "subtype": "init",
            "session_id": "claude-session-1"
        ]))
        XCTAssertEqual(initResults.map(\.type), [ClaudeProviderStreamResult.lifecycleType])
        XCTAssertEqual(translator.cliSessionID, "claude-session-1")

        let usage = translator.parseNDJSONLine(jsonLine([
            "type": "stream_event",
            "event": [
                "type": "message_start",
                "message": [
                    "usage": [
                        "inputTokens": 4,
                        "outputTokens": 0,
                        "cacheReadInputTokens": 6
                    ]
                ]
            ]
        ]))
        XCTAssertEqual(usage.first?.type, "usage")
        XCTAssertEqual(usage.first?.contextUsedTokens, 10)

        let delta = translator.parseNDJSONLine(jsonLine([
            "type": "stream_event",
            "event": [
                "type": "content_block_delta",
                "delta": ["type": "text_delta", "text": "partial"]
            ]
        ]))
        XCTAssertEqual(delta.first?.type, "content")
        XCTAssertEqual(delta.first?.text, "partial")

        let stop = translator.parseNDJSONLine(jsonLine([
            "type": "stream_event",
            "event": [
                "type": "message_delta",
                "delta": ["stop_reason": "end_turn"],
                "usage": ["input_tokens": 4, "output_tokens": 9]
            ]
        ]))
        XCTAssertEqual(stop.map(\.type), ["usage", "message_stop"])
        XCTAssertEqual(stop.last?.stopReason, "end_turn")

        let cancelled = translator.parseNDJSONLine(jsonLine([
            "type": "result",
            "subtype": "error_during_execution",
            "session_id": "claude-session-2",
            "is_error": true,
            "errors": ["Request was aborted by user"],
            "stop_reason": "cancelled",
            "usage": ["input_tokens": 11, "output_tokens": 0],
            "total_cost_usd": 0.12
        ]))
        XCTAssertEqual(cancelled.map(\.type), ["message_stop"])
        let cancelledStop = try XCTUnwrap(cancelled.first)
        XCTAssertEqual(cancelledStop.providerSessionID, "claude-session-2")
        XCTAssertEqual(cancelledStop.promptTokens, 11)
        XCTAssertEqual(cancelledStop.completionTokens, 0)
        XCTAssertEqual(cancelledStop.cost, 0.12)
        XCTAssertEqual(cancelledStop.stopReason, "cancelled")
        XCTAssertEqual(translator.cliSessionID, "claude-session-2")
    }

    // MARK: - Main-model attribution for modelUsage context windows

    func testModelUsageMainModelAttributionSelectsInitTrackedWindowOverBackgroundHaiku() {
        // Init anchors the exact modelUsage key; the background Haiku entry is
        // unreachable by strategy regardless of dictionary iteration order.
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "system", "subtype": "init",
            "session_id": "s1", "model": "claude-opus-4-8[1m]"
        ]))
        let window = modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000],
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000]
        ])
        XCTAssertEqual(window, 1_000_000)
    }

    func testAssistantFallbackNormalizedMatchResolvesMainWindow() {
        // With tracking unset, a top-level assistant base id anchors
        // tracking and resolves via the normalized-equality (bracket-stripped) tier.
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "message": ["model": "claude-opus-4-8", "content": [["type": "text", "text": "hi"]]]
        ]))
        let window = modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000],
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000]
        ])
        XCTAssertEqual(window, 1_000_000)
    }

    func testInitTrackedExactIDIsNotOverwrittenByLaterAssistantModel() {
        // Assistant sets tracking only when unset, so an init-tracked exact
        // id wins over a later assistant model. If the assistant had retargeted tracking to the
        // sonnet id, the sonnet 200K entry would have been selected instead.
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-opus-4-8[1m]"]))
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "message": ["model": "claude-sonnet-4-5", "content": [["type": "text", "text": "hi"]]]
        ]))
        let window = modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000],
            "claude-sonnet-4-5": ["contextWindow": 200_000]
        ])
        XCTAssertEqual(window, 1_000_000, "init-tracked exact id must win; assistant model must not retarget tracking")
    }

    func testStickyMainWindowSurvivesBackgroundOnlyEvent() {
        // A matched main window stays sticky through a later Haiku-only event.
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-opus-4-8[1m]"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000],
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000]
        ]), 1_000_000)
        let sticky = modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000]
        ])
        XCTAssertEqual(sticky, 1_000_000, "background-only event must not downgrade the sticky main window")
    }

    func testNoPriorMatchFallsBackToDeterministicMaxAcrossEntries() {
        // With no tracking anchor and no prior match, selection is the
        // deterministic MAX across entries, never a blind first-positive.
        var translator = ClaudeSDKNDJSONTranslator()
        let window = modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000],
            "claude-unknown-background": ["contextWindow": 300_000]
        ])
        XCTAssertEqual(window, 300_000)
    }

    func testHaikuAsMainModelResolvesTwoHundredKViaExactMatch() {
        // Haiku-as-main resolves via the general exact-match path, no special case.
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-haiku-4-5-20251001"]))
        let window = modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000]
        ])
        XCTAssertEqual(window, 200_000)
    }

    func testSidechainAssistantEventDoesNotRetargetMainModelTracking() {
        // A sidechain/subagent assistant event (non-null parent_tool_use_id) must not
        // anchor tracking; the following top-level assistant anchors the real main model.
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "parent_tool_use_id": "toolu_subagent_1",
            "message": ["model": "claude-haiku-4-5-20251001", "content": [["type": "text", "text": "sub"]]]
        ]))
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "message": ["model": "claude-opus-4-8", "content": [["type": "text", "text": "main"]]]
        ]))
        let window = modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000],
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000]
        ])
        XCTAssertEqual(window, 1_000_000, "sidechain assistant must not retarget tracking to the subagent model")
    }

    func testFreshStreamInitReanchorsFromCleanStateAndReinitOverwritesTracking() {
        // A fresh translator whose init model is Haiku resolves 200K even when a larger
        // background window is present (no prior-stream leak); a subsequent new init re-anchors.
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-haiku-4-5-20251001"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000],
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000]
        ]), 200_000, "init Haiku must anchor 200K even when a larger background window is present")
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-opus-4-8[1m]"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000],
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000]
        ]), 1_000_000, "a new init must re-anchor tracking to the new main model")
    }

    func testResetMainModelTrackingReanchorsAfterLiveModelSwitchAndPreservesSessionAndToolMaps() throws {
        var translator = ClaudeSDKNDJSONTranslator(
            treatsToolResultErrorsAsHostOwned: { $0 == "mcp__RepoPromptCE__read_file" }
        )
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "system", "subtype": "init", "session_id": "s-live", "model": "claude-opus-4-8[1m]"
        ]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000],
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000]
        ]), 1_000_000)
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "message": [
                "content": [[
                    "type": "tool_use",
                    "id": "toolu_reset_survives",
                    "name": "mcp__RepoPromptCE__read_file",
                    "input": ["path": "README.md"]
                ]]
            ]
        ]))

        let sessionIDBeforeReset = translator.cliSessionID
        translator.resetMainModelTracking()
        XCTAssertEqual(translator.cliSessionID, sessionIDBeforeReset)
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "message": ["model": "claude-sonnet-4-6", "content": [["type": "text", "text": "main"]]]
        ]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000],
            "claude-sonnet-4-6": ["contextWindow": 200_000],
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000]
        ]), 200_000)

        let toolResult = try XCTUnwrap(translator.parseNDJSONLine(jsonLine([
            "type": "user",
            "message": [
                "content": [[
                    "type": "tool_result",
                    "tool_use_id": "toolu_reset_survives",
                    "content": [["type": "text", "text": "contents"]]
                ]]
            ]
        ])).first)
        XCTAssertEqual(toolResult.toolName, "mcp__RepoPromptCE__read_file")
    }

    func testPostResetSidechainAssistantDoesNotAnchorBeforeNextTopLevelAssistant() {
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-opus-4-8[1m]"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000]
        ]), 1_000_000)

        translator.resetMainModelTracking()
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "parent_tool_use_id": "toolu_subagent_2",
            "message": ["model": "claude-haiku-4-5-20251001", "content": [["type": "text", "text": "sub"]]]
        ]))
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "message": ["model": "claude-sonnet-4-6", "content": [["type": "text", "text": "main"]]]
        ]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-sonnet-4-6": ["contextWindow": 200_000],
            "claude-haiku-4-5-20251001": ["contextWindow": 300_000]
        ]), 200_000)
    }

    func testPostResetResultBeforeAnchorUsesDeterministicMaxNotStaleStickyWindow() {
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-opus-4-8[1m]"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000]
        ]), 1_000_000)

        translator.resetMainModelTracking()
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-sonnet-4-6": ["contextWindow": 200_000],
            "claude-haiku-4-5-20251001": ["contextWindow": 300_000]
        ]), 300_000)
    }

    func testPrefixBoundaryRejectsAdjacentNumericPrefixFalseMatch() {
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-opus-4-1"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-10": ["contextWindow": 200_000],
            "claude-haiku-4-5-20251001": ["contextWindow": 300_000]
        ]), 300_000)
    }

    func testPrefixBoundaryAcceptsDatedKeyWithDashDelimiter() {
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-haiku-4-5"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000],
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000]
        ]), 200_000)
    }

    func testPrefixBoundaryAcceptsTrackedDatedModelAgainstBaseKey() {
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-haiku-4-5-20251001"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5": ["contextWindow": 200_000],
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000]
        ]), 200_000)
    }

    func testPrefixBoundaryCandidateTierUsesDeterministicMaxWithoutGlobalFallthrough() {
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-haiku-4-5"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000],
            "claude-haiku-4-5-20260101": ["contextWindow": 300_000],
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000]
        ]), 300_000)
    }

    func testAgreeingPrefixCandidatesBeatUnrelatedLargerGlobalEntry() {
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-haiku-4-5"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000],
            "claude-haiku-4-5-20260101": ["contextWindow": 200_000],
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000]
        ]), 200_000)
    }

    func testNormalizedEqualityTierPrecedesLargerBoundaryPrefixCandidate() {
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-opus-4-8[tracked]"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-8[200k]": ["contextWindow": 200_000],
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000],
            "claude-opus-4-8-20260101": ["contextWindow": 2_000_000]
        ]), 1_000_000)
    }

    func testAmbiguousCandidateTierResolutionUpdatesStickyForBackgroundFollowUp() {
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-haiku-4-5"]))
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-haiku-4-5-20251001": ["contextWindow": 200_000],
            "claude-haiku-4-5-20260101": ["contextWindow": 200_000]
        ]), 200_000)
        XCTAssertEqual(modelContextWindow(from: &translator, modelUsage: [
            "claude-opus-4-8[1m]": ["contextWindow": 1_000_000]
        ]), 200_000)
    }

    private func modelContextWindow(
        from translator: inout ClaudeSDKNDJSONTranslator,
        modelUsage: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int? {
        let results = translator.parseNDJSONLine(jsonLine([
            "type": "result",
            "subtype": "success",
            "session_id": "s-result",
            "modelUsage": modelUsage
        ], file: file, line: line))
        return results.first(where: { $0.type == "message_stop" })?.modelContextWindow
    }

    private func jsonObject(from jsonString: String?, file: StaticString = #filePath, line: UInt = #line) throws -> [String: String] {
        let value = try XCTUnwrap(jsonString, file: file, line: line)
        let data = Data(value.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String], file: file, line: line)
    }

    private func jsonLine(_ object: [String: Any], file: StaticString = #filePath, line: UInt = #line) -> Data {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [])
        else {
            XCTFail("Invalid JSON fixture", file: file, line: line)
            return Data()
        }
        return data
    }
}
