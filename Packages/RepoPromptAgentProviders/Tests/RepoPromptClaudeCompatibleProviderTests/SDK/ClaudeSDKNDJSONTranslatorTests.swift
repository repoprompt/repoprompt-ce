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

    // MARK: Context window and sub-agent usage (review follow-up on #1077)

    private func resultWindow(
        initModel: String?,
        modelUsage: [String: Any]
    ) -> Int? {
        var translator = ClaudeSDKNDJSONTranslator()
        var initMessage: [String: Any] = ["type": "system", "subtype": "init", "session_id": "s"]
        if let initModel { initMessage["model"] = initModel }
        _ = translator.parseNDJSONLine(jsonLine(initMessage))
        let results = translator.parseNDJSONLine(jsonLine([
            "type": "result",
            "subtype": "success",
            "usage": ["input_tokens": 1, "output_tokens": 1],
            "modelUsage": modelUsage
        ]))
        return results.first { $0.type == "message_stop" }?.modelContextWindow
    }

    func testTheWindowIsTheSessionModelsOwnEntryNotAnAuxiliaryModels() {
        // Several orderings of the same dictionary content, so a first-entry pick cannot pass by luck.
        for _ in 0 ..< 5 {
            XCTAssertEqual(
                resultWindow(initModel: "claude-opus-4-5[1m]", modelUsage: [
                    "claude-haiku-4-5": ["contextWindow": 200_000],
                    "claude-opus-4-5[1m]": ["contextWindow": 1_000_000],
                    "claude-sonnet-4-5": ["contextWindow": 200_000]
                ]),
                1_000_000
            )
        }
    }

    func testAVariantSuffixStillMatchesTheSessionModelWhenUnique() {
        XCTAssertEqual(
            resultWindow(initModel: "claude-opus-4-5", modelUsage: [
                "claude-haiku-4-5": ["contextWindow": 200_000],
                "claude-opus-4-5[1m]": ["contextWindow": 1_000_000]
            ]),
            1_000_000
        )
    }

    func testWithoutTheSessionModelsEntryTheWindowIsUnknown() {
        XCTAssertNil(
            resultWindow(initModel: "claude-opus-4-5", modelUsage: [
                "claude-haiku-4-5": ["contextWindow": 200_000],
                "claude-sonnet-4-5": ["contextWindow": 200_000]
            ]),
            "Other models' windows say nothing about the session model's, even when they agree"
        )
    }

    func testWithoutAnAnnouncedModelOnlyAUnanimousWindowStands() {
        XCTAssertEqual(
            resultWindow(initModel: nil, modelUsage: [
                "a": ["contextWindow": 200_000],
                "b": ["contextWindow": 200_000]
            ]),
            200_000
        )
        XCTAssertNil(resultWindow(initModel: nil, modelUsage: [
            "a": ["contextWindow": 200_000],
            "b": ["contextWindow": 1_000_000]
        ]))
    }

    func testALoneEntryIsTheSessionModelsWhateverItIsCalled() {
        XCTAssertEqual(
            resultWindow(initModel: "opus", modelUsage: ["glm-4.6": ["contextWindow": 200_000]]),
            200_000,
            "Compatible backends may report the model under their own name"
        )
    }

    func testALoneEntryConflictingWithAResponseNamedModelIsNotTaken() {
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "message": ["model": "claude-opus-4-5[1m]", "content": []]
        ]))
        let results = translator.parseNDJSONLine(jsonLine([
            "type": "result",
            "subtype": "success",
            "modelUsage": ["claude-haiku-4-5": ["contextWindow": 200_000]]
        ]))
        XCTAssertNil(
            results.first { $0.type == "message_stop" }?.modelContextWindow,
            "Once a response named the session model, an auxiliary-only result says nothing about it"
        )
    }

    func testAResponseNamedModelUsedInTwoVariantsHasNoKnownWindow() {
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-sonnet-4-5"]))
        // Responses name the model without its variant suffix, so after a live switch between the
        // plain and `[1m]` variants the entries cannot say which one is current.
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "message": ["model": "claude-sonnet-4-5", "content": []]
        ]))
        // Neither a made-up message nor a later init displaces the response-named model.
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "message": ["model": "<synthetic>", "content": [["type": "text", "text": "API Error"]]]
        ]))
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-haiku-4-5"]))
        let ambiguous = translator.parseNDJSONLine(jsonLine([
            "type": "result",
            "subtype": "success",
            "modelUsage": [
                "claude-sonnet-4-5": ["contextWindow": 200_000],
                "claude-sonnet-4-5[1m]": ["contextWindow": 1_000_000]
            ]
        ]))
        XCTAssertNil(ambiguous.first { $0.type == "message_stop" }?.modelContextWindow)

        let identified = translator.parseNDJSONLine(jsonLine([
            "type": "result",
            "subtype": "success",
            "modelUsage": [
                "claude-sonnet-4-5[1m]": ["contextWindow": 1_000_000],
                "claude-haiku-4-5": ["contextWindow": 200_000]
            ]
        ]))
        XCTAssertEqual(identified.first { $0.type == "message_stop" }?.modelContextWindow, 1_000_000)

        // A response that names the explicit variant identifies its entry even alongside the plain one.
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "message": ["model": "claude-sonnet-4-5[1m]", "content": []]
        ]))
        let explicit = translator.parseNDJSONLine(jsonLine([
            "type": "result",
            "subtype": "success",
            "modelUsage": [
                "claude-sonnet-4-5": ["contextWindow": 200_000],
                "claude-sonnet-4-5[1m]": ["contextWindow": 1_000_000]
            ]
        ]))
        XCTAssertEqual(explicit.first { $0.type == "message_stop" }?.modelContextWindow, 1_000_000)
    }

    func testALiveModelSwitchFollowsTheMainThreadsResponses() {
        var translator = ClaudeSDKNDJSONTranslator()
        _ = translator.parseNDJSONLine(jsonLine(["type": "system", "subtype": "init", "model": "claude-sonnet-4-5"]))
        // A live switch announces no new init; the main thread's responses name the model.
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "stream_event",
            "event": ["type": "message_start", "message": ["model": "claude-opus-4-5[1m]", "usage": ["input_tokens": 1]]]
        ]))
        // A sub-agent's init or response never becomes the session model.
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "system", "subtype": "init", "model": "claude-haiku-4-5", "parent_tool_use_id": "toolu_1"
        ]))
        _ = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "parent_tool_use_id": "toolu_1",
            "message": ["model": "claude-haiku-4-5", "content": []]
        ]))
        let results = translator.parseNDJSONLine(jsonLine([
            "type": "result",
            "subtype": "success",
            "modelUsage": [
                "claude-sonnet-4-5": ["contextWindow": 200_000],
                "claude-opus-4-5[1m]": ["contextWindow": 1_000_000],
                "claude-haiku-4-5": ["contextWindow": 200_000]
            ]
        ]))
        XCTAssertEqual(results.first { $0.type == "message_stop" }?.modelContextWindow, 1_000_000)
    }

    func testSubagentUsageIsNotReportedAsThisSessionsContext() {
        var translator = ClaudeSDKNDJSONTranslator()
        let subagentAssistant = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "parent_tool_use_id": "toolu_task_1",
            "message": [
                "usage": ["input_tokens": 90000, "output_tokens": 10],
                "content": [["type": "text", "text": "sub-agent says hi"]]
            ]
        ]))
        XCTAssertEqual(subagentAssistant.map(\.type), ["content"], "Its content still flows; its usage does not")

        let subagentStart = translator.parseNDJSONLine(jsonLine([
            "type": "stream_event",
            "parent_tool_use_id": "toolu_task_1",
            "event": ["type": "message_start", "message": ["usage": ["input_tokens": 90000]]]
        ]))
        XCTAssertTrue(subagentStart.isEmpty)

        let subagentDelta = translator.parseNDJSONLine(jsonLine([
            "type": "stream_event",
            "parent_tool_use_id": "toolu_task_1",
            "event": [
                "type": "message_delta",
                "delta": ["stop_reason": "end_turn"],
                "usage": ["input_tokens": 90000, "output_tokens": 5]
            ]
        ]))
        XCTAssertTrue(subagentDelta.isEmpty, "Neither the sub-agent's usage nor its stop is this session's")

        let subagentStop = translator.parseNDJSONLine(jsonLine([
            "type": "stream_event",
            "parent_tool_use_id": "toolu_task_1",
            "event": ["type": "message_stop"]
        ]))
        XCTAssertTrue(subagentStop.isEmpty)

        let mainStop = translator.parseNDJSONLine(jsonLine([
            "type": "stream_event",
            "parent_tool_use_id": NSNull(),
            "event": ["type": "message_delta", "delta": ["stop_reason": "tool_use"]]
        ]))
        XCTAssertEqual(mainStop.map(\.type), ["message_stop"], "The main thread's stops still end its responses")

        let mainThread = translator.parseNDJSONLine(jsonLine([
            "type": "assistant",
            "parent_tool_use_id": NSNull(),
            "message": ["usage": ["input_tokens": 1000, "output_tokens": 10], "content": []]
        ]))
        XCTAssertEqual(mainThread.first?.type, "usage", "A null parent is the main thread")
        XCTAssertEqual(mainThread.first?.contextUsedTokens, 1000)
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
