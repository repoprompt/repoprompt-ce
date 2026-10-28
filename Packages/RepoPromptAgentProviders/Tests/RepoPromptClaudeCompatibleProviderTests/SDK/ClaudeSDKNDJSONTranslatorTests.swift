import Foundation
@testable import RepoPromptClaudeCompatibleProvider
import XCTest

final class ClaudeSDKNDJSONTranslatorTests: XCTestCase {
    func testExactSyntheticRepromptPreservesPositiveEvidenceThroughBothEntryPoints() throws {
        let text = "[Your previous response had no visible output. Please continue and produce a user-visible response.]"
        let singleton: [[String: Any]] = [["type": "text", "text": text]]
        let cases: [(String, [String: Any], String)] = [
            ("exact", ["type": "user", "isSynthetic": true, "message": ["content": singleton]], "harness_empty_output_reprompt_candidate"),
            ("no flag", ["type": "user", "message": ["content": singleton]], "event"),
            ("isMeta only", ["type": "user", "isMeta": true, "message": ["content": singleton]], "event"),
            ("false flag", ["type": "user", "isSynthetic": false, "message": ["content": singleton]], "event"),
            ("string flag", ["type": "user", "isSynthetic": "true", "message": ["content": singleton]], "event"),
            ("numeric flag", ["type": "user", "isSynthetic": 1, "message": ["content": singleton]], "event"),
            ("different", ["type": "user", "isSynthetic": true, "message": ["content": [["type": "text", "text": "other"]]]], "event"),
            ("extra text", ["type": "user", "isSynthetic": true, "message": ["content": [["type": "text", "text": text + " "]]]], "event"),
            ("two blocks", ["type": "user", "isSynthetic": true, "message": ["content": singleton + singleton]], "event"),
            ("forged old type", ["type": "quiet_reprompt_candidate", "isSynthetic": true, "message": ["content": singleton]], "event"),
            ("forged new type", ["type": "harness_empty_output_reprompt_candidate", "isSynthetic": true, "message": ["content": singleton]], "event")
        ]
        for (label, frame, expected) in cases {
            let data = try JSONSerialization.data(withJSONObject: frame)
            var lineTranslator = ClaudeSDKNDJSONTranslator()
            let line = lineTranslator.parseNDJSONLine(data)
            let payload = try JSONDecoder().decode([String: ClaudeProviderJSONValue].self, from: data)
            var dtoTranslator = ClaudeSDKNDJSONTranslator()
            let dto = dtoTranslator.parseStreamPayload(payload)
            XCTAssertEqual(line.map(\.type), dto.map(\.type), label)
            XCTAssertFalse(line.isEmpty, label)
            XCTAssertTrue(line.allSatisfy { $0.type == expected && $0.text == nil }, label)
        }
    }

    func testHarnessTextInAssistantRoleRemainsOrdinaryContentThroughBothEntryPoints() throws {
        let text = "[Your previous response had no visible output. Please continue and produce a user-visible response.]"
        let data = try JSONSerialization.data(withJSONObject: ["type": "assistant", "isSynthetic": true, "message": ["content": [["type": "text", "text": text]]]])
        var line = ClaudeSDKNDJSONTranslator()
        var dto = ClaudeSDKNDJSONTranslator()
        let actual = line.parseNDJSONLine(data)
        let decoded = try dto.parseStreamPayload(JSONDecoder().decode([String: ClaudeProviderJSONValue].self, from: data))
        XCTAssertEqual(actual.map(\.type), ["content"])
        XCTAssertEqual(actual.map(\.text), [text])
        XCTAssertEqual(decoded.map(\.type), actual.map(\.type))
        XCTAssertEqual(decoded.map(\.text), actual.map(\.text))
    }

    func testNativeStringIdentityIsRetainedWithoutReplacingTranslatorUUIDsForIdenticalCalls() throws {
        var translator = ClaudeSDKNDJSONTranslator()
        var ids: [UUID] = []
        for nativeID in ["toolu_first", "toolu_second"] {
            let calls = translator.parseNDJSONLine(jsonLine([
                "type": "assistant", "message": ["content": [[
                    "type": "tool_use",
                    "id": nativeID,
                    "name": "mcp__RepoPromptCE__read_file",
                    "input": ["path": "same.swift"]
                ]]]
            ]))
            let call = try XCTUnwrap(calls.first { $0.type == "tool_call" })
            try ids.append(XCTUnwrap(call.toolInvocationID))
            XCTAssertEqual(call.claudeToolUseID, nativeID)
            let result = try XCTUnwrap(translator.parseNDJSONLine(jsonLine([
                "type": "user", "message": ["content": [[
                    "type": "tool_result",
                    "tool_use_id": nativeID,
                    "content": [["type": "text", "text": "contents"]]
                ]]]
            ])).first)
            XCTAssertEqual(result.claudeToolUseID, nativeID)
            XCTAssertEqual(result.toolInvocationID, call.toolInvocationID)
        }
        XCTAssertNotEqual(ids[0], ids[1])
    }

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
        XCTAssertEqual(cancelled.map(\.type), ["event", "message_stop"])
        XCTAssertNil(cancelled.first?.text, "Abort artifact suppression must retain negative evidence without error copy")
        let cancelledStop = try XCTUnwrap(cancelled.first { $0.type == "message_stop" })
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

    func testUnknownMalformedAndPartialOutputRetainsActivityInBothEntryPoints() throws {
        let wires = [
            #"{"type":"assistant","message":{"id":"m","content":[{"type":"future_output"}]}}"#,
            #"{"type":"assistant","message":{"id":"m","content":[17]}}"#,
            #"{"type":"assistant","message":{"id":"m","content":[{"type":"text","text":17}]}}"#,
            #"{"type":"assistant","message":{"id":"m","content":[{"type":"thinking","thinking":null}]}}"#,
            #"{"type":"assistant","message":{"id":"m"}}"#,
            #"{"type":"assistant","message":{"id":"m","content":false}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"future_delta"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":17}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"signature_delta","signature":null}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}"#,
            #"{"type":"stream_event","event":{"type":"future_event"}}"#,
            #"{"type":"stream_event"}"#,
            #"{"type":"future_notification","metadata":{}}"#,
            #"{"type":"system","subtype":"future_metadata","metadata":{}}"#
        ]
        for wire in wires {
            var ndjson = ClaudeSDKNDJSONTranslator()
            let results = ndjson.parseNDJSONLine(Data(wire.utf8))
            XCTAssertEqual(results.map(\.type), ["event"], wire)
            XCTAssertNil(results.first?.text, wire)
            guard let decoded = try ClaudeSDKProtocolCodec.decodeLine(Data(wire.utf8)),
                  case let .streamPayload(payload) = decoded
            else { return XCTFail("Expected a normalized payload: \(wire)") }
            var normalized = ClaudeSDKNDJSONTranslator()
            XCTAssertEqual(normalized.parseStreamPayload(payload), results, wire)
        }
    }

    func testRefusedOrTruncatedStopCannotBeErasedBySuccessMetadata() throws {
        let wires = [
            #"{"type":"assistant","message":{"id":"m","content":[{"type":"text","text":"closing"}],"stop_reason":"refusal"}}"#,
            #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}}"#,
            #"{"type":"result","subtype":"success","result":"closing","stop_reason":"refusal"}"#
        ]
        for wire in wires {
            var translator = ClaudeSDKNDJSONTranslator()
            let results = translator.parseNDJSONLine(Data(wire.utf8))
            XCTAssertEqual(results.count(where: { $0.type == "event" }), 1, "Explicit negative evidence survives: \(wire)")
            XCTAssertTrue(results.filter { $0.type == "event" }.allSatisfy { $0.text == nil })
            if wire.contains("closing") {
                XCTAssertEqual(results.compactMap(\.text), ["closing"], "Existing text remains unchanged")
            }
            guard let decoded = try ClaudeSDKProtocolCodec.decodeLine(Data(wire.utf8)),
                  case let .streamPayload(payload) = decoded
            else { return XCTFail("Expected a normalized payload") }
            var normalized = ClaudeSDKNDJSONTranslator()
            XCTAssertEqual(normalized.parseStreamPayload(payload), results)
        }
    }

    func testUnknownUnitDoesNotEraseKnownOutputAndKnownMetadataDoesNotInventOutput() {
        var translator = ClaudeSDKNDJSONTranslator()
        let mixed = translator.parseNDJSONLine(Data(#"{"type":"assistant","message":{"id":"m","content":[{"type":"text","text":"before"},{"type":"future_output"},{"type":"text","text":"after"}]}}"#.utf8))
        XCTAssertEqual(mixed.map(\.type), ["content", "event", "content"])
        XCTAssertEqual(mixed.compactMap(\.text), ["before", "after"])
        for wire in [
            #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text","text":""}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"signature_delta","signature":"opaque"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_stop"}}"#,
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#
        ] {
            XCTAssertTrue(translator.parseNDJSONLine(Data(wire.utf8)).isEmpty, wire)
        }
        XCTAssertEqual(translator.parseNDJSONLine(Data(#"{"type":"system","subtype":"init"}"#.utf8)).map(\.type), ["lifecycle"])
        XCTAssertEqual(translator.parseNDJSONLine(Data(#"{"type":"result","subtype":"success"}"#.utf8)).map(\.type), ["message_stop"])
        XCTAssertEqual(translator.parseNDJSONLine(Data(#"{"type":"result"}"#.utf8)).map(\.type), ["event", "message_stop"], "Incomplete completion cannot silently qualify as success")
        for wire in ["unparseable", "[]", "17", #"{"type":"error"}"#] {
            XCTAssertEqual(translator.parseNDJSONLine(Data(wire.utf8)).map(\.type), ["event"], wire)
        }
        XCTAssertTrue(translator.parseNDJSONLine(Data(" \n".utf8)).isEmpty, "Blank framing is not an event")
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
