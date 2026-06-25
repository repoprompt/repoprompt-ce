import Foundation
@testable import RepoPrompt
import XCTest

final class CodexNativeSessionControllerEventRecoveryTests: XCTestCase {
    private static let webSearchAliases = ["search", "web_search", "web_search_request", "google_web_search", "search_web"]

    func testLegacyAssistantCompleteWithoutPriorDeltaEmitsFullText() async {
        let controller = makeControllerWithThread(turnID: "turn-1")

        await controller.test_handleNotification(
            method: "codex/event/agent_message",
            params: legacyAssistantCompleteParams(turnID: "turn-1", message: "complete response")
        )

        let deltas = await finishAndReadAssistantDeltas(from: controller)
        XCTAssertEqual(deltas, ["complete response"])
    }

    func testLegacyAssistantCompleteIdenticalToCanonicalDeltaEmitsNothingAdditional() async {
        let controller = makeControllerWithThread(turnID: "turn-1")

        await controller.test_handleNotification(
            method: "item/agentMessage/delta",
            params: assistantDeltaParams(turnID: "turn-1", delta: "complete response")
        )
        await controller.test_handleNotification(
            method: "codex/event/agent_message",
            params: legacyAssistantCompleteParams(turnID: "turn-1", message: "complete response")
        )

        let deltas = await finishAndReadAssistantDeltas(from: controller)
        XCTAssertEqual(deltas, ["complete response"])
    }

    func testLegacyAssistantCompleteTopLevelEventIDDoesNotResetCanonicalItemBoundary() async {
        let controller = makeControllerWithThread(turnID: "turn-1")

        await controller.test_handleNotification(
            method: "item/agentMessage/delta",
            params: assistantDeltaParams(
                turnID: "turn-1",
                itemID: "assistant-item-1",
                delta: "complete response"
            )
        )
        await controller.test_handleNotification(
            method: "codex/event/agent_message",
            params: legacyAssistantCompleteParams(
                turnID: "turn-1",
                eventID: "0",
                message: "complete response"
            )
        )

        let deltas = await finishAndReadAssistantDeltas(from: controller)
        XCTAssertEqual(deltas, ["complete response"])
    }

    func testLegacyAssistantCompleteStrictPrefixRecoversOnlySuffixAndIsIdempotent() async {
        let controller = makeControllerWithThread(turnID: "turn-1")

        await controller.test_handleNotification(
            method: "item/agentMessage/delta",
            params: assistantDeltaParams(turnID: "turn-1", delta: "answer")
        )
        for _ in 0 ..< 2 {
            await controller.test_handleNotification(
                method: "codex/event/agent_message",
                params: legacyAssistantCompleteParams(turnID: "turn-1", message: "answer.")
            )
        }

        let deltas = await finishAndReadAssistantDeltas(from: controller)
        XCTAssertEqual(deltas, ["answer", "."])
        XCTAssertEqual(deltas.joined(), "answer.")
    }

    func testLegacyAssistantCompleteRecoversUTF8SuffixAcrossGraphemeBoundary() async {
        let controller = makeControllerWithThread(turnID: "turn-1")
        let streamedPrefix = "👨"
        let completeMessage = "👨‍👩‍👧"

        await controller.test_handleNotification(
            method: "item/agentMessage/delta",
            params: assistantDeltaParams(turnID: "turn-1", delta: streamedPrefix)
        )
        await controller.test_handleNotification(
            method: "codex/event/agent_message",
            params: legacyAssistantCompleteParams(turnID: "turn-1", message: completeMessage)
        )

        let deltas = await finishAndReadAssistantDeltas(from: controller)
        XCTAssertEqual(deltas.joined(), completeMessage)
        XCTAssertEqual(Array(deltas.joined().utf8), Array(completeMessage.utf8))
        XCTAssertEqual(deltas.count, 2)
    }

    func testAssistantCompleteReconciliationResetsAtCanonicalItemBoundary() async {
        let controller = makeControllerWithThread(turnID: "turn-1")

        await controller.test_handleNotification(
            method: "item/agentMessage/delta",
            params: assistantDeltaParams(
                turnID: "turn-1",
                itemID: "assistant-item-1",
                delta: "Checking"
            )
        )
        await controller.test_handleNotification(
            method: "codex/event/agent_message",
            params: legacyAssistantCompleteParams(turnID: "turn-1", message: "Checking")
        )
        await controller.test_handleNotification(
            method: "item/agentMessage/delta",
            params: assistantDeltaParams(
                turnID: "turn-1",
                itemID: "assistant-item-2",
                delta: "Result"
            )
        )
        await controller.test_handleNotification(
            method: "codex/event/agent_message",
            params: legacyAssistantCompleteParams(turnID: "turn-1", message: "Result.")
        )

        let deltas = await finishAndReadAssistantDeltas(from: controller)
        XCTAssertEqual(deltas, ["Checking", "Result", "."])
    }

    func testLegacyAssistantCompleteNonPrefixMismatchDoesNotEmitUnprovenBytes() async {
        let controller = makeControllerWithThread(turnID: "turn-1")

        await controller.test_handleNotification(
            method: "item/agentMessage/delta",
            params: assistantDeltaParams(turnID: "turn-1", delta: "trusted prefix")
        )
        await controller.test_handleNotification(
            method: "codex/event/agent_message",
            params: legacyAssistantCompleteParams(turnID: "turn-1", message: "different response")
        )

        let deltas = await finishAndReadAssistantDeltas(from: controller)
        XCTAssertEqual(deltas, ["trusted prefix"])
    }

    func testAssistantCompleteReconciliationIsIsolatedAndResetsWhenTurnCompletes() async {
        let controller = makeControllerWithThread(turnID: "turn-1")

        await controller.test_handleNotification(
            method: "item/agentMessage/delta",
            params: assistantDeltaParams(turnID: "turn-1", delta: "turn one")
        )
        await controller.test_handleNotification(
            method: "codex/event/agent_message",
            params: legacyAssistantCompleteParams(turnID: "turn-2", message: "turn two")
        )
        await controller.test_handleNotification(
            method: "turn/completed",
            params: turnLifecycleParams(turnID: "turn-1", status: "completed")
        )
        await controller.test_handleNotification(
            method: "turn/started",
            params: turnLifecycleParams(turnID: "turn-1")
        )
        await controller.test_handleNotification(
            method: "codex/event/agent_message",
            params: legacyAssistantCompleteParams(turnID: "turn-1", message: "reused turn fresh text")
        )

        let deltas = await finishAndReadAssistantDeltas(from: controller)
        XCTAssertEqual(deltas, ["turn one", "turn two", "reused turn fresh text"])
    }

    func testCanonicalAssistantCompletionWithoutDeltaEmitsAuthoritativeSnapshot() async {
        let controller = makeControllerWithThread(turnID: "turn-1")

        await controller.test_handleNotification(
            method: "item/completed",
            params: canonicalCompletedItemParams(
                turnID: "turn-1",
                itemID: "assistant-item-1",
                type: "agentMessage",
                fields: ["text": .string("complete response")]
            )
        )

        let events = await finishAndReadEvents(from: controller)
        let completions = events.compactMap { event -> CodexNativeSessionController.AssistantCompletionPayload? in
            guard case let .assistantCompleted(payload) = event else { return nil }
            return payload
        }
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.text, "complete response")
        XCTAssertEqual(completions.first?.scope, .init(turnID: "turn-1", itemID: "assistant-item-1"))
    }

    func testCanonicalAssistantCompletionIsDeduplicatedSuppressesLegacyMirrorAndRejectsLateDelta() async {
        let controller = makeControllerWithThread(turnID: "turn-1")
        let completion = canonicalCompletedItemParams(
            turnID: "turn-1",
            itemID: "assistant-item-1",
            type: "agentMessage",
            fields: ["text": .string("authoritative response")]
        )

        await controller.test_handleNotification(
            method: "item/agentMessage/delta",
            params: assistantDeltaParams(
                turnID: "turn-1",
                itemID: "assistant-item-1",
                delta: "draft"
            )
        )
        await controller.test_handleNotification(method: "item/completed", params: completion)
        await controller.test_handleNotification(method: "item/completed", params: completion)
        await controller.test_handleNotification(
            method: "codex/event/agent_message",
            params: legacyAssistantCompleteParams(turnID: "turn-1", message: "authoritative response")
        )
        await controller.test_handleNotification(
            method: "item/agentMessage/delta",
            params: assistantDeltaParams(
                turnID: "turn-1",
                itemID: "assistant-item-1",
                delta: " late"
            )
        )

        let events = await finishAndReadEvents(from: controller)
        XCTAssertEqual(events.count(where: {
            if case .canonicalAssistantDelta = $0 { return true }
            return false
        }), 1)
        XCTAssertEqual(events.count(where: {
            if case .assistantCompleted = $0 { return true }
            return false
        }), 1)
        XCTAssertFalse(events.contains {
            if case .assistantDelta = $0 { return true }
            return false
        })
    }

    func testCanonicalAssistantCompletionSuppressesOnlyMatchingScopedLegacyMirror() async {
        let controller = makeControllerWithThread(turnID: "turn-1")
        await controller.test_handleNotification(
            method: "item/completed",
            params: canonicalCompletedItemParams(
                turnID: "turn-1",
                itemID: "assistant-item-1",
                type: "agentMessage",
                fields: ["text": .string("canonical first")]
            )
        )
        await controller.test_handleNotification(
            method: "codex/event/agent_message",
            params: legacyAssistantCompleteParams(
                turnID: "turn-1",
                itemID: "assistant-item-1",
                message: "canonical first"
            )
        )
        await controller.test_handleNotification(
            method: "codex/event/agent_message",
            params: legacyAssistantCompleteParams(
                turnID: "turn-1",
                itemID: "assistant-item-2",
                message: "legacy second"
            )
        )

        let events = await finishAndReadEvents(from: controller)
        XCTAssertEqual(events.count(where: {
            if case .assistantCompleted = $0 { return true }
            return false
        }), 1)
        let scopedLegacyDeltas = events.compactMap { event -> (String, CodexNativeSessionController.ItemScope)? in
            guard case let .canonicalAssistantDelta(text, scope) = event else { return nil }
            return (text, scope)
        }
        XCTAssertEqual(scopedLegacyDeltas.map(\.0), ["legacy second"])
        XCTAssertEqual(
            scopedLegacyDeltas.map(\.1),
            [.init(turnID: "turn-1", itemID: "assistant-item-2")]
        )
    }

    func testScopedLegacyAssistantBeforeCanonicalCompletionUsesSameItemScope() async {
        let controller = makeControllerWithThread(turnID: "turn-1")
        await controller.test_handleNotification(
            method: "codex/event/agent_message",
            params: legacyAssistantCompleteParams(
                turnID: "turn-1",
                itemID: "assistant-item-1",
                message: "draft"
            )
        )
        await controller.test_handleNotification(
            method: "item/completed",
            params: canonicalCompletedItemParams(
                turnID: "turn-1",
                itemID: "assistant-item-1",
                type: "agentMessage",
                fields: ["text": .string("final")]
            )
        )

        let events = await finishAndReadEvents(from: controller)
        let scopes = events.compactMap { event -> CodexNativeSessionController.ItemScope? in
            switch event {
            case let .canonicalAssistantDelta(_, scope):
                scope
            case let .assistantCompleted(payload):
                payload.scope
            default:
                nil
            }
        }
        XCTAssertEqual(
            scopes,
            [
                .init(turnID: "turn-1", itemID: "assistant-item-1"),
                .init(turnID: "turn-1", itemID: "assistant-item-1")
            ]
        )
        XCTAssertFalse(events.contains {
            if case .assistantDelta = $0 { return true }
            return false
        })
    }

    func testCanonicalReasoningCompletionIsAuthoritativeAndRejectsLateDelta() async {
        let controller = makeControllerWithThread(turnID: "turn-1")

        await controller.test_handleNotification(
            method: "item/reasoning/summaryTextDelta",
            params: [
                "threadId": .string("thread-active"),
                "turnId": .string("turn-1"),
                "itemId": .string("reasoning-item-1"),
                "summaryIndex": .number(0),
                "delta": .string("Draft")
            ]
        )
        await controller.test_handleNotification(
            method: "item/completed",
            params: canonicalCompletedItemParams(
                turnID: "turn-1",
                itemID: "reasoning-item-1",
                type: "reasoning",
                fields: [
                    "summary": .array([.string("Final summary")]),
                    "content": .array([.string("Final body")])
                ]
            )
        )
        await controller.test_handleNotification(
            method: "item/reasoning/textDelta",
            params: [
                "threadId": .string("thread-active"),
                "turnId": .string("turn-1"),
                "itemId": .string("reasoning-item-1"),
                "contentIndex": .number(0),
                "delta": .string(" late")
            ]
        )

        let events = await finishAndReadEvents(from: controller)
        XCTAssertEqual(events.count(where: {
            if case .reasoningDelta = $0 { return true }
            return false
        }), 1)
        let completions = events.compactMap { event -> CodexNativeSessionController.ReasoningCompletionPayload? in
            guard case let .reasoningCompleted(payload) = event else { return nil }
            return payload
        }
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.summary, ["Final summary"])
        XCTAssertEqual(completions.first?.content, ["Final body"])
    }

    func testCanonicalMCPToolLifecycleCoversSuccessFailureAndResultOnly() async throws {
        let controller = makeControllerWithThread(turnID: "turn-1")

        await controller.test_handleNotification(
            method: "item/started",
            params: canonicalMCPItemParams(
                turnID: "turn-1",
                itemID: "mcp-success",
                status: "inProgress",
                arguments: ["query": .string("docs")]
            )
        )
        await controller.test_handleNotification(
            method: "item/completed",
            params: canonicalMCPItemParams(
                turnID: "turn-1",
                itemID: "mcp-success",
                status: "completed",
                arguments: ["query": .string("docs")],
                result: .object(["content": .string("found")])
            )
        )
        await controller.test_handleNotification(
            method: "item/completed",
            params: canonicalMCPItemParams(
                turnID: "turn-1",
                itemID: "mcp-failure",
                status: "failed",
                arguments: [:],
                error: .object(["message": .string("boom")])
            )
        )
        await controller.test_handleNotification(
            method: "item/completed",
            params: canonicalMCPItemParams(
                turnID: "turn-1",
                itemID: "mcp-result-only",
                status: "completed",
                arguments: ["path": .string("README.md")],
                result: .object(["ok": .bool(true)])
            )
        )

        let events = await finishAndReadEvents(from: controller)
        let calls = events.compactMap { event -> (String, UUID?)? in
            guard case let .toolCall(name, invocationID, _) = event else { return nil }
            return (name, invocationID)
        }
        let results = events.compactMap { event -> (String, UUID?, String, Bool?)? in
            guard case let .toolResult(name, invocationID, _, resultJSON, isError) = event else { return nil }
            return (name, invocationID, resultJSON, isError)
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(calls.first?.0, "lookup")
        XCTAssertEqual(results[0].0, "lookup")
        XCTAssertEqual(results[0].1, calls.first?.1)
        XCTAssertEqual(results[0].3, false)
        XCTAssertEqual(try XCTUnwrap(jsonObject(from: results[0].2))["content"] as? String, "found")
        XCTAssertEqual(results[1].3, true)
        XCTAssertEqual(
            try XCTUnwrap(jsonObject(from: results[1].2))["message"] as? String,
            "boom"
        )
        XCTAssertEqual(results[2].3, false)
        XCTAssertEqual(try XCTUnwrap(jsonObject(from: results[2].2))["ok"] as? Bool, true)
        XCTAssertFalse(events.contains(where: { event in
            switch event {
            case .approvalRequest, .permissionsRequest, .requestUserInput, .mcpElicitationRequest:
                true
            default:
                false
            }
        }))
    }

    func testCanonicalAndDeprecatedContextCompactionDeduplicate() async {
        let controller = makeControllerWithThread(turnID: "turn-1")

        await controller.test_handleNotification(
            method: "item/completed",
            params: canonicalCompletedItemParams(
                turnID: "turn-1",
                itemID: "compaction-item-1",
                type: "contextCompaction"
            )
        )
        await controller.test_handleNotification(
            method: "thread/compacted",
            params: [
                "threadId": .string("thread-active"),
                "turnId": .string("turn-1")
            ]
        )
        await controller.test_handleNotification(
            method: "item/completed",
            params: canonicalCompletedItemParams(
                turnID: "turn-1",
                itemID: "compaction-item-1b",
                type: "contextCompaction"
            )
        )

        let events = await finishAndReadEvents(from: controller)
        XCTAssertEqual(events.count(where: {
            if case .contextCompacted = $0 { return true }
            return false
        }), 2)

        let reverseController = makeControllerWithThread(turnID: "turn-2")
        await reverseController.test_handleNotification(
            method: "thread/compacted",
            params: [
                "threadId": .string("thread-active"),
                "turnId": .string("turn-2")
            ]
        )
        await reverseController.test_handleNotification(
            method: "item/completed",
            params: canonicalCompletedItemParams(
                turnID: "turn-2",
                itemID: "compaction-item-2",
                type: "contextCompaction"
            )
        )
        await reverseController.test_handleNotification(
            method: "item/completed",
            params: canonicalCompletedItemParams(
                turnID: "turn-2",
                itemID: "compaction-item-2b",
                type: "contextCompaction"
            )
        )
        let reverseEvents = await finishAndReadEvents(from: reverseController)
        XCTAssertEqual(reverseEvents.count(where: {
            if case .contextCompacted = $0 { return true }
            return false
        }), 2)
    }

    func testExactLegacyMCPPathsRemainWhileSyntheticLifecycleAliasesAreIgnored() async {
        let controller = makeControllerWithThread(turnID: "turn-1")
        let legacyParams: [String: CodexJSONValue] = [
            "threadId": .string("thread-active"),
            "turnId": .string("turn-1"),
            "msg": .object([
                "call_id": .string("legacy-mcp-1"),
                "invocation": .object([
                    "server": .string("third-party"),
                    "tool": .string("lookup"),
                    "arguments": .object(["query": .string("docs")])
                ])
            ])
        ]
        await controller.test_handleNotification(
            method: "codex/event/mcp_tool_call_begin",
            params: legacyParams
        )
        var legacyCompletionParams = legacyParams
        legacyCompletionParams["msg"] = .object([
            "call_id": .string("legacy-mcp-1"),
            "invocation": .object([
                "server": .string("third-party"),
                "tool": .string("lookup"),
                "arguments": .object(["query": .string("docs")])
            ]),
            "result": .object(["ok": .bool(true)])
        ])
        await controller.test_handleNotification(
            method: "codex/event/mcp_tool_call_end",
            params: legacyCompletionParams
        )
        await controller.test_handleNotification(
            method: "item/agentMessage/delta",
            params: [
                "thread_id": .string("thread-active"),
                "turn_id": .string("turn-1"),
                "item_id": .string("snake-payload-item"),
                "delta": .string("payload aliases retained")
            ]
        )
        await controller.test_handleNotification(
            method: "codex/event/item_commandExecution_started",
            params: canonicalCompletedItemParams(
                turnID: "stale-turn",
                itemID: "synthetic-command",
                type: "commandExecution",
                fields: ["command": .string("echo ignored")]
            )
        )
        await controller.test_handleNotification(
            method: "item/command_execution/output_delta",
            params: [
                "threadId": .string("thread-active"),
                "turnId": .string("turn-1"),
                "itemId": .string("synthetic-command"),
                "delta": .string("ignored")
            ]
        )
        await controller.test_handleNotification(
            method: "thread/token_usage/updated",
            params: [
                "threadId": .string("thread-active"),
                "turnId": .string("turn-1")
            ]
        )
        for method in [
            "item/mcp_tool_call/progress",
            "command/exec/output_delta",
            "process/output_delta",
            "deprecation_notice",
            "server_request/resolved"
        ] {
            await controller.test_handleNotification(
                method: method,
                params: [
                    "threadId": .string("thread-active"),
                    "turnId": .string("stale-turn"),
                    "itemId": .string("synthetic-progress")
                ]
            )
        }
        XCTAssertEqual(controller.test_routingCurrentTurnID, "turn-1")

        let events = await finishAndReadEvents(from: controller)
        XCTAssertEqual(events.count(where: {
            if case .toolCall = $0 { return true }
            return false
        }), 1)
        XCTAssertEqual(events.count(where: {
            if case .toolResult = $0 { return true }
            return false
        }), 1)
        XCTAssertEqual(events.count(where: {
            if case .canonicalAssistantDelta = $0 { return true }
            return false
        }), 1)
        XCTAssertFalse(events.contains {
            if case .commandExecutionRunning = $0 { return true }
            return false
        })
        XCTAssertFalse(events.contains {
            if case .tokenUsage = $0 { return true }
            return false
        })
        XCTAssertFalse(events.contains {
            if case .livenessActivity = $0 { return true }
            return false
        })
        XCTAssertTrue(CodexNativeSessionController.test_isItemLifecycleNotificationMethod("item/started"))
        XCTAssertTrue(CodexNativeSessionController.test_isItemLifecycleNotificationMethod("item/completed"))
        XCTAssertFalse(CodexNativeSessionController.test_isItemLifecycleNotificationMethod("codex/event/item_commandExecution_started"))
        XCTAssertFalse(CodexNativeSessionController.test_isItemLifecycleNotificationMethod("item_command_execution_completed"))
    }

    func testStructuredErrorNotificationRetainsRetryMetadataAndScope() throws {
        let retrying = try XCTUnwrap(CodexNativeSessionController.test_parseErrorNotification(from: [
            "threadId": "thread-1",
            "turnId": "turn-1",
            "error": [
                "message": "reconnecting",
                "willRetry": true
            ]
        ]))
        XCTAssertEqual(retrying.message, "reconnecting")
        XCTAssertEqual(retrying.willRetry, true)
        XCTAssertEqual(retrying.threadID, "thread-1")
        XCTAssertEqual(retrying.turnID, "turn-1")

        let nestedRetry = try XCTUnwrap(CodexNativeSessionController.test_parseErrorNotification(from: [
            "error": [
                "message": "nested retry",
                "details": [
                    "will_retry": true,
                    "thread_id": "thread-2",
                    "turn_id": "turn-2",
                    "item_id": "item-2"
                ]
            ]
        ]))
        XCTAssertEqual(nestedRetry.willRetry, true)
        XCTAssertEqual(nestedRetry.threadID, "thread-2")
        XCTAssertEqual(nestedRetry.turnID, "turn-2")
        XCTAssertEqual(nestedRetry.itemID, "item-2")

        let terminal = try XCTUnwrap(CodexNativeSessionController.test_parseErrorNotification(from: [
            "message": "fatal",
            "will_retry": false
        ]))
        XCTAssertEqual(terminal.willRetry, false)

        let missingMetadata = try XCTUnwrap(CodexNativeSessionController.test_parseErrorNotification(from: [
            "message": "retrying from legacy text"
        ]))
        XCTAssertNil(missingMetadata.willRetry)
    }

    func testStructuredFailedCompletionPrefersTurnErrorOverCachedNotification() async throws {
        let controller = makeControllerWithThread(turnID: "turn-1")
        await controller.test_handleNotification(
            method: "error",
            params: [
                "threadId": .string("thread-active"),
                "turnId": .string("turn-1"),
                "error": .object([
                    "message": .string("cached async error"),
                    "willRetry": .bool(false)
                ])
            ]
        )
        await controller.test_handleNotification(
            method: "turn/completed",
            params: [
                "threadId": .string("thread-active"),
                "turn": .object([
                    "id": .string("turn-1"),
                    "status": .string("failed"),
                    "error": .object([
                        "message": .string("authoritative turn error"),
                        "codexErrorInfo": .string("quotaExceeded"),
                        "additionalDetails": .object([
                            "requestId": .string("request-1")
                        ])
                    ])
                ])
            ]
        )

        let events = await finishAndReadEvents(from: controller)
        XCTAssertFalse(events.contains {
            if case .errorNotification = $0 { return true }
            return false
        })
        let completions: [(
            String?,
            CodexNativeSessionController.TurnStatus,
            CodexNativeSessionController.TurnFailure?
        )] = events.compactMap { event in
            guard case let .turnCompleted(turnID, status, failure) = event else { return nil }
            return (turnID, status, failure)
        }
        let completion = try XCTUnwrap(completions.first)
        XCTAssertEqual(completion.0, "turn-1")
        XCTAssertEqual(completion.1, .failed)
        XCTAssertEqual(completion.2?.message, "authoritative turn error")
        XCTAssertEqual(completion.2?.codexErrorInfo, "quotaExceeded")
        XCTAssertEqual(completion.2?.additionalDetails, #"{"requestId":"request-1"}"#)
    }

    func testStructuredFailedCompletionUsesCachedThenGenericFallback() async throws {
        let cachedController = makeControllerWithThread(turnID: "turn-1")
        await cachedController.test_handleNotification(
            method: "error",
            params: [
                "threadId": .string("thread-active"),
                "turnId": .string("turn-1"),
                "message": .string("cached terminal error"),
                "willRetry": .bool(false)
            ]
        )
        await cachedController.test_handleNotification(
            method: "turn/completed",
            params: turnLifecycleParams(turnID: "turn-1", status: "failed")
        )
        let cachedEvents = await finishAndReadEvents(from: cachedController)
        let cachedFailure = try XCTUnwrap(cachedEvents.compactMap { event -> CodexNativeSessionController.TurnFailure? in
            guard case let .turnCompleted(_, .failed, failure) = event else { return nil }
            return failure
        }.first)
        XCTAssertEqual(cachedFailure.message, "cached terminal error")

        let genericController = makeControllerWithThread(turnID: "turn-2")
        await genericController.test_handleNotification(
            method: "turn/completed",
            params: turnLifecycleParams(turnID: "turn-2", status: "failed")
        )
        let genericEvents = await finishAndReadEvents(from: genericController)
        let genericFailure = try XCTUnwrap(genericEvents.compactMap { event -> CodexNativeSessionController.TurnFailure? in
            guard case let .turnCompleted(_, .failed, failure) = event else { return nil }
            return failure
        }.first)
        XCTAssertEqual(genericFailure.message, "Codex turn failed.")
    }

    func testRetryingMissingMetadataStaleAndContradictoryErrorsPreserveCurrentBehavior() async {
        let controller = makeControllerWithThread(turnID: "turn-1")
        await controller.test_handleNotification(
            method: "error",
            params: [
                "threadId": .string("thread-active"),
                "turnId": .string("turn-1"),
                "message": .string("retrying"),
                "willRetry": .bool(true)
            ]
        )
        await controller.test_handleNotification(
            method: "error",
            params: [
                "message": .string("legacy immediate")
            ]
        )
        await controller.test_handleNotification(
            method: "error",
            params: [
                "threadId": .string("thread-active"),
                "turnId": .string("stale-turn"),
                "message": .string("stale terminal"),
                "willRetry": .bool(false)
            ]
        )
        await controller.test_handleNotification(
            method: "error",
            params: [
                "threadId": .string("thread-active"),
                "turnId": .string("turn-1"),
                "message": .string("contradictory terminal"),
                "willRetry": .bool(false)
            ]
        )
        await controller.test_handleNotification(
            method: "turn/completed",
            params: turnLifecycleParams(turnID: "turn-1", status: "completed")
        )

        let events = await finishAndReadEvents(from: controller)
        let notifications = events.compactMap { event -> CodexNativeSessionController.ErrorNotification? in
            guard case let .errorNotification(notification) = event else { return nil }
            return notification
        }
        XCTAssertEqual(notifications.map(\.message), ["retrying", "legacy immediate"])
        XCTAssertEqual(notifications.first?.willRetry, true)
        XCTAssertNil(notifications.last?.willRetry)
        XCTAssertTrue(events.contains {
            guard case let .turnCompleted(_, status, failure) = $0 else { return false }
            return status == .completed && failure == nil
        })
    }

    func testTransportLossFlushesCachedActiveTurnErrorBeforeGenericClosure() async throws {
        let controller = makeControllerWithThread(turnID: "turn-1")
        await controller.test_handleNotification(
            method: "error",
            params: [
                "threadId": .string("thread-active"),
                "turnId": .string("turn-1"),
                "message": .string("explicit terminal error"),
                "willRetry": .bool(false)
            ]
        )
        await controller.test_simulateTransportStreamEnded(source: "test")

        let events = await finishAndReadEvents(from: controller)
        let failedCompletionIndex = try XCTUnwrap(events.firstIndex {
            guard case let .turnCompleted("turn-1", .failed, failure) = $0 else {
                return false
            }
            return failure?.message == "explicit terminal error"
        })
        let transportIndex = try XCTUnwrap(events.firstIndex {
            guard case let .error(message) = $0 else { return false }
            return message.localizedCaseInsensitiveContains("transport closed")
        })
        XCTAssertLessThan(failedCompletionIndex, transportIndex)
        XCTAssertEqual(events.count(where: {
            if case .turnCompleted(_, .failed, _) = $0 { return true }
            return false
        }), 1)
    }

    func testRoutingOnlyTransportLossFlushesAcceptedCachedError() async throws {
        let controller = makeControllerWithThread(turnID: "initial-turn")
        controller.test_installThreadState(
            threadID: "thread-active",
            authoritativeTurnID: nil,
            routingTurnID: "routing-turn"
        )
        await controller.test_handleNotification(
            method: "error",
            params: [
                "threadId": .string("thread-active"),
                "turnId": .string("routing-turn"),
                "message": .string("routing-only explicit error"),
                "willRetry": .bool(false)
            ]
        )
        await controller.test_simulateTransportStreamEnded(source: "test-routing")

        let events = await finishAndReadEvents(from: controller)
        let failure = try XCTUnwrap(events.compactMap { event -> CodexNativeSessionController.TurnFailure? in
            guard case let .turnCompleted("routing-turn", .failed, failure) = event else {
                return nil
            }
            return failure
        }.first)
        XCTAssertEqual(failure.message, "routing-only explicit error")
    }

    func testPendingFailurePeekIsNonDestructiveForDelayedCompletion() async throws {
        let controller = makeControllerWithThread(turnID: "turn-1")
        await controller.test_handleNotification(
            method: "error",
            params: [
                "threadId": .string("thread-active"),
                "turnId": .string("turn-1"),
                "message": .string("preserved explicit error"),
                "willRetry": .bool(false)
            ]
        )

        let peekedFailure = await controller.pendingTurnFailure(turnID: nil)
        XCTAssertEqual(peekedFailure?.message, "preserved explicit error")

        await controller.test_handleNotification(
            method: "turn/completed",
            params: turnLifecycleParams(turnID: "turn-1", status: "failed")
        )
        let events = await finishAndReadEvents(from: controller)
        let completedFailure = try XCTUnwrap(events.compactMap { event -> CodexNativeSessionController.TurnFailure? in
            guard case let .turnCompleted("turn-1", .failed, failure) = event else {
                return nil
            }
            return failure
        }.first)
        XCTAssertEqual(completedFailure.message, "preserved explicit error")
    }

    func testProgressOnlyNotificationsRetainLivenessCategoryScopeAndActiveFlags() throws {
        let rows: [(String, CodexNativeSessionController.LivenessActivity.Kind)] = [
            ("thread/status/changed", .threadStatusChanged),
            ("turn/plan/updated", .turnPlanUpdated),
            ("turn/diff/updated", .turnDiffUpdated),
            ("item/plan/delta", .itemPlanDelta),
            ("item/mcpToolCall/progress", .mcpToolProgress),
            ("command/exec/outputDelta", .commandOrProcessOutput),
            ("process/exited", .processExited),
            ("hook/started", .hookLifecycle),
            ("warning", .warning),
            ("deprecationNotice", .deprecationNotice),
            ("serverRequest/resolved", .serverRequestResolved)
        ]

        for (method, expectedKind) in rows {
            let activity = try XCTUnwrap(CodexNativeSessionController.test_parseLivenessActivity(
                method: method,
                params: [
                    "threadId": "thread-1",
                    "turnId": "turn-1",
                    "itemId": "item-1",
                    "status": [
                        "type": "active",
                        "activeFlags": ["waiting_for_user_input"]
                    ],
                    "message": "progress"
                ]
            ), method)
            XCTAssertEqual(activity.kind, expectedKind, method)
            XCTAssertEqual(activity.threadID, "thread-1", method)
            XCTAssertEqual(activity.turnID, "turn-1", method)
            XCTAssertEqual(activity.itemID, "item-1", method)
            XCTAssertEqual(activity.activeFlags, ["waiting_for_user_input"], method)
            XCTAssertEqual(activity.message, "progress", method)
        }
    }

    func testStaleScopedProgressNotificationIsRejectedByRouting() {
        XCTAssertTrue(CodexNativeSessionController.test_shouldDropNotificationForRouting(
            method: "turn/plan/updated",
            params: [
                "threadId": "stale-thread",
                "turnId": "stale-turn"
            ],
            activeThreadID: "active-thread",
            currentTurnID: "active-turn"
        ))
    }

    func testNormalizedCommandExecutionLifecycleParsesAsBashCallAndResult() throws {
        let controller = CodexNativeSessionController(
            client: CodexAppServerClient(),
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil
        )

        let started = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/started",
            params: [
                "threadId": "thread-active",
                "turnId": "turn-current",
                "item": [
                    "type": "commandExecution",
                    "id": "call_exec_1",
                    "command": "echo hi",
                    "cwd": "/tmp/work",
                    "processId": "47551",
                    "commandActions": [["type": "unknown", "command": "echo hi"]]
                ]
            ]
        ))

        XCTAssertEqual(started.kind, "call")
        XCTAssertEqual(started.name, "bash")
        XCTAssertNotNil(started.invocationID)
        let argsObject = try XCTUnwrap(jsonObject(from: started.argsJSON))
        XCTAssertEqual(argsObject["command"] as? String, "echo hi")
        XCTAssertEqual(argsObject["cwd"] as? String, "/tmp/work")
        XCTAssertEqual(argsObject["processId"] as? String, "47551")
        XCTAssertEqual((argsObject["commandActions"] as? [[String: Any]])?.count, 1)

        let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: [
                "threadId": "thread-active",
                "turnId": "turn-current",
                "item": [
                    "type": "commandExecution",
                    "id": "call_exec_1",
                    "command": "echo hi",
                    "processId": "47551",
                    "status": "completed",
                    "exitCode": 0,
                    "aggregatedOutput": "hi\n"
                ]
            ]
        ))

        XCTAssertEqual(completed.kind, "result")
        XCTAssertEqual(completed.name, "bash")
        XCTAssertEqual(completed.invocationID, started.invocationID)
        XCTAssertEqual(completed.isError, false)
        let resultObject = try XCTUnwrap(jsonObject(from: completed.resultJSON))
        XCTAssertEqual(resultObject["type"] as? String, "commandExecution")
        XCTAssertEqual(resultObject["status"] as? String, "completed")
        XCTAssertEqual(resultObject["processId"] as? String, "47551")
        XCTAssertEqual(resultObject["aggregatedOutput"] as? String, "hi\n")
        XCTAssertEqual(resultObject["exitCode"] as? Int, 0)
    }

    func testNativeWebSearchAliasesPairStartedAndCompletedInvocations() throws {
        for alias in Self.webSearchAliases {
            let controller = makeController()
            let itemID = "call_pair_\(alias)"
            let started = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
                method: "item/started",
                params: toolParams(item: [
                    "type": "toolCall",
                    "id": itemID,
                    "name": alias,
                    "query": "paired alias \(alias)"
                ])
            ), alias)

            let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
                method: "item/completed",
                params: toolParams(item: [
                    "type": "toolCall",
                    "id": itemID,
                    "name": alias,
                    "status": "completed",
                    "query": "paired alias \(alias)",
                    "response": [
                        "results": [["title": "Paired", "snippet": alias]]
                    ]
                ])
            ), alias)

            XCTAssertEqual(started.kind, "call", alias)
            XCTAssertEqual(completed.kind, "result", alias)
            XCTAssertEqual(completed.name, "search", alias)
            XCTAssertEqual(completed.invocationID, started.invocationID, alias)
            XCTAssertEqual(completed.isError, false, alias)
        }
    }

    func testNativeWebActionTopLevelScalarsSurviveStartedAndCompletedEvents() throws {
        let controller = makeController()
        let started = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/started",
            params: toolParams(item: [
                "type": "toolCall",
                "id": "call_search_open",
                "name": "web_search",
                "query": "docs",
                "url": "https://docs.example.com/a/b/c",
                "action": "open"
            ])
        ))
        XCTAssertEqual(started.kind, "call")
        XCTAssertEqual(started.name, "search")
        let startedArgs = try XCTUnwrap(jsonObject(from: started.argsJSON))
        XCTAssertEqual(startedArgs["query"] as? String, "docs")
        XCTAssertEqual(startedArgs["url"] as? String, "https://docs.example.com/a/b/c")
        XCTAssertEqual(startedArgs["action"] as? String, "open")

        let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "toolCall",
                "id": "call_search_open",
                "name": "web_search",
                "status": "completed",
                "url": "https://docs.example.com/a/b/c",
                "action": "open",
                "title": "Docs page",
                "content": String(repeating: "full page body ", count: 80)
            ])
        ))
        XCTAssertEqual(completed.kind, "result")
        XCTAssertEqual(completed.name, "search")
        let completedResult = try XCTUnwrap(jsonObject(from: completed.resultJSON))
        XCTAssertEqual(completedResult["url"] as? String, "https://docs.example.com/a/b/c")
        XCTAssertEqual(completedResult["action"] as? String, "open")
        XCTAssertNil(completedResult["content"])
    }

    func testActualCodexWebSearchLifecycleShapesPreserveQueriesAndIgnoreRawDuplicate() throws {
        let controller = makeController()
        let started = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/started",
            params: toolParams(item: [
                "type": "webSearch",
                "id": "ws_actual",
                "query": "",
                "action": ["type": "other"]
            ])
        ))
        XCTAssertEqual(started.kind, "call")
        XCTAssertEqual(started.name, "search")
        XCTAssertNil(started.argsJSON)

        let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "webSearch",
                "id": "ws_actual",
                "query": "first query ...",
                "action": [
                    "type": "search",
                    "query": NSNull(),
                    "queries": ["first query", "second query"]
                ]
            ])
        ))
        XCTAssertEqual(completed.kind, "result")
        XCTAssertEqual(completed.name, "search")
        XCTAssertEqual(completed.invocationID, started.invocationID)
        XCTAssertNil(completed.isError)
        let args = try XCTUnwrap(jsonObject(from: completed.argsJSON))
        let result = try XCTUnwrap(jsonObject(from: completed.resultJSON))
        XCTAssertEqual(args["action"] as? String, "search")
        XCTAssertEqual(args["query"] as? String, "first query ...")
        XCTAssertEqual(args["queries"] as? [String], ["first query", "second query"])
        XCTAssertEqual(result["action"] as? String, "search")
        XCTAssertEqual(result["query"] as? String, "first query ...")
        XCTAssertEqual(result["queries"] as? [String], ["first query", "second query"])

        XCTAssertFalse(CodexNativeSessionController.test_isItemLifecycleNotificationMethod("rawResponseItem/completed"))
        XCTAssertNil(controller.test_parseToolLifecycleEvent(
            method: "rawResponseItem/completed",
            params: toolParams(item: [
                "type": "web_search_call",
                "status": "completed",
                "action": [
                    "type": "search",
                    "queries": ["first query", "second query"]
                ]
            ])
        ))

        let recovered = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "webSearch",
                "id": "ws_recovered_begin",
                "query": "",
                "action": NSNull()
            ])
        ))
        XCTAssertEqual(recovered.name, "search")
        XCTAssertNil(recovered.argsJSON)
    }

    func testNativeWebSearchNestedTaggedActionsPreserveCompactFieldsAcrossLifecycle() throws {
        let rows: [(label: String, action: [String: Any], expectedAction: String, expectedFields: [String: String])] = [
            (
                "search",
                ["type": "search", "query": "nested Codex query"],
                "search",
                ["query": "nested Codex query"]
            ),
            (
                "camel open page",
                ["type": "openPage", "url": "https://docs.example.com/open", "refId": "turn0search0"],
                "open_page",
                ["url": "https://docs.example.com/open", "refId": "turn0search0"]
            ),
            (
                "actual targetless find in page",
                ["type": "findInPage", "url": NSNull(), "pattern": "installation"],
                "find_in_page",
                ["pattern": "installation"]
            )
        ]

        for (index, row) in rows.enumerated() {
            let controller = makeController()
            let itemID = "call_nested_web_\(index)"
            let started = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
                method: "item/started",
                params: toolParams(item: [
                    "type": "webSearch",
                    "id": itemID,
                    "action": row.action
                ])
            ), row.label)
            XCTAssertEqual(started.kind, "call", row.label)
            XCTAssertEqual(started.name, "search", row.label)
            let startedArgs = try XCTUnwrap(jsonObject(from: started.argsJSON), row.label)
            XCTAssertEqual(startedArgs["action"] as? String, row.expectedAction, row.label)
            for (key, value) in row.expectedFields {
                XCTAssertEqual(startedArgs[key] as? String, value, "\(row.label) started \(key)")
            }

            let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
                method: "item/completed",
                params: toolParams(item: [
                    "type": "webSearch",
                    "id": itemID,
                    "status": "completed",
                    "action": row.action
                ])
            ), row.label)
            XCTAssertEqual(completed.kind, "result", row.label)
            XCTAssertEqual(completed.name, "search", row.label)
            XCTAssertEqual(completed.invocationID, started.invocationID, row.label)
            let completedArgs = try XCTUnwrap(jsonObject(from: completed.argsJSON), row.label)
            let completedResult = try XCTUnwrap(jsonObject(from: completed.resultJSON), row.label)
            XCTAssertEqual(completedArgs["action"] as? String, row.expectedAction, row.label)
            XCTAssertEqual(completedResult["action"] as? String, row.expectedAction, row.label)
            for (key, value) in row.expectedFields {
                XCTAssertEqual(completedArgs[key] as? String, value, "\(row.label) completed args \(key)")
                XCTAssertEqual(completedResult[key] as? String, value, "\(row.label) completed result \(key)")
            }
        }

        let bodyMarker = "wrapped nested web body"
        let wrappedController = makeController()
        let wrapped = try XCTUnwrap(wrappedController.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "webSearch",
                "id": "call_nested_wrapped_find",
                "status": "failed",
                "action": [
                    "type": "findInPage",
                    "url": "https://docs.example.com/wrapped-find",
                    "pattern": "installation"
                ],
                "response": [
                    "title": "Wrapped find page",
                    "matches": [["text": String(repeating: bodyMarker, count: 100)]],
                    "error": ["message": "wrapped find failed"],
                    "content": String(repeating: bodyMarker, count: 100)
                ]
            ])
        ))
        let wrappedResult = try XCTUnwrap(jsonObject(from: wrapped.resultJSON))
        XCTAssertEqual(wrappedResult["action"] as? String, "find_in_page")
        XCTAssertEqual(wrappedResult["url"] as? String, "https://docs.example.com/wrapped-find")
        XCTAssertEqual(wrappedResult["pattern"] as? String, "installation")
        XCTAssertEqual(wrappedResult["title"] as? String, "Wrapped find page")
        XCTAssertEqual(wrappedResult["match_count"] as? Int, 1)
        XCTAssertEqual((wrappedResult["error"] as? [String: Any])?["message"] as? String, "wrapped find failed")
        XCTAssertFalse(wrapped.resultJSON?.contains(bodyMarker) == true)
    }

    func testNativeWebReadAndFindEventsUseCanonicalWebReadNameAndCompactResults() throws {
        let controller = makeController()
        let started = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/started",
            params: toolParams(item: [
                "type": "toolCall",
                "id": "call_webfetch",
                "name": "webfetch",
                "url": "https://docs.example.com/a/b/c",
                "needle": "install"
            ])
        ))
        XCTAssertEqual(started.kind, "call")
        XCTAssertEqual(started.name, "web_read")
        let args = try XCTUnwrap(jsonObject(from: started.argsJSON))
        XCTAssertEqual(args["url"] as? String, "https://docs.example.com/a/b/c")
        XCTAssertEqual(args["needle"] as? String, "install")

        let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "toolCall",
                "id": "call_webfetch",
                "name": "webfetch",
                "status": "completed",
                "url": "https://docs.example.com/a/b/c",
                "needle": "install",
                "matches": [["text": String(repeating: "full page body ", count: 80)]],
                "content": String(repeating: "full page body ", count: 80)
            ])
        ))
        XCTAssertEqual(completed.kind, "result")
        XCTAssertEqual(completed.name, "web_read")
        let result = try XCTUnwrap(jsonObject(from: completed.resultJSON))
        XCTAssertEqual(result["url"] as? String, "https://docs.example.com/a/b/c")
        XCTAssertEqual(result["needle"] as? String, "install")
        XCTAssertEqual(result["match_count"] as? Int, 1)
        XCTAssertNil(result["matches"])
        XCTAssertNil(result["content"])
        XCTAssertFalse(completed.resultJSON?.contains("full page body") == true)
    }

    func testNativeWebReadWrapperResultsUnwrapCompactMetadataAndErrors() throws {
        for wrapperKey in ["result", "output", "response", "content"] {
            let bodyMarker = "full wrapped page body"
            let controller = makeController()
            let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
                method: "item/completed",
                params: toolParams(item: [
                    "type": "toolCall",
                    "id": "call_web_read_\(wrapperKey)",
                    "name": "web_fetch",
                    "url": "https://docs.example.com/wrapped",
                    wrapperKey: [
                        "status": "completed",
                        "title": "Wrapped docs",
                        "description": String(repeating: "compact metadata ", count: 80),
                        "error": [
                            "message": "bounded warning",
                            "code": 42,
                            "details": String(repeating: "unbounded detail ", count: 100)
                        ],
                        "content": String(repeating: bodyMarker, count: 100)
                    ]
                ])
            ), wrapperKey)

            XCTAssertEqual(completed.name, "web_read", wrapperKey)
            let result = try XCTUnwrap(jsonObject(from: completed.resultJSON), wrapperKey)
            XCTAssertEqual(result["url"] as? String, "https://docs.example.com/wrapped", wrapperKey)
            XCTAssertEqual(result["status"] as? String, "completed", wrapperKey)
            XCTAssertEqual(result["title"] as? String, "Wrapped docs", wrapperKey)
            XCTAssertLessThanOrEqual((result["description"] as? String)?.count ?? 0, 500, wrapperKey)
            let error = try XCTUnwrap(result["error"] as? [String: Any], wrapperKey)
            XCTAssertEqual(error["message"] as? String, "bounded warning", wrapperKey)
            XCTAssertEqual(error["code"] as? Int, 42, wrapperKey)
            XCTAssertNil(error["details"], wrapperKey)
            XCTAssertNil(result[wrapperKey], wrapperKey)
            XCTAssertFalse(completed.resultJSON?.contains(bodyMarker) == true, wrapperKey)

            let bodyOnly = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
                method: "item/completed",
                params: toolParams(item: [
                    "type": "toolCall",
                    "id": "call_web_read_body_only_\(wrapperKey)",
                    "name": "web_fetch",
                    wrapperKey: ["content": String(repeating: bodyMarker, count: 100)]
                ])
            ), "\(wrapperKey) body only")
            XCTAssertEqual(try XCTUnwrap(jsonObject(from: bodyOnly.resultJSON)).count, 0, wrapperKey)
            XCTAssertFalse(bodyOnly.resultJSON?.contains(bodyMarker) == true, wrapperKey)

            let successfulScalar = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
                method: "item/completed",
                params: toolParams(item: [
                    "type": "toolCall",
                    "id": "call_web_read_scalar_success_\(wrapperKey)",
                    "name": "web_fetch",
                    "status": "completed",
                    wrapperKey: String(repeating: bodyMarker, count: 100)
                ])
            ), "\(wrapperKey) successful scalar")
            let scalarResult = try XCTUnwrap(jsonObject(from: successfulScalar.resultJSON), wrapperKey)
            XCTAssertEqual(scalarResult.count, 1, wrapperKey)
            XCTAssertEqual(scalarResult["status"] as? String, "completed", wrapperKey)
            XCTAssertFalse(successfulScalar.resultJSON?.contains(bodyMarker) == true, wrapperKey)
        }

        for wrapperKey in ["result", "output", "response"] {
            let controller = makeController()
            let failed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
                method: "item/completed",
                params: toolParams(item: [
                    "type": "toolCall",
                    "id": "call_web_read_scalar_failure_\(wrapperKey)",
                    "name": "web_fetch",
                    "status": "failed",
                    wrapperKey: "request timed out"
                ])
            ), "\(wrapperKey) failed scalar")
            let failedResult = try XCTUnwrap(jsonObject(from: failed.resultJSON), wrapperKey)
            XCTAssertEqual(failedResult["status"] as? String, "failed", wrapperKey)
            XCTAssertEqual(failedResult["errorMessage"] as? String, "request timed out", wrapperKey)
        }

        let nestedFailureController = makeController()
        let nestedFailure = try XCTUnwrap(nestedFailureController.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "toolCall",
                "id": "call_web_read_nested_failure",
                "name": "web_fetch",
                "result": [
                    "status": "failed",
                    "message": "request blocked"
                ]
            ])
        ))
        let nestedFailureResult = try XCTUnwrap(jsonObject(from: nestedFailure.resultJSON))
        XCTAssertEqual(nestedFailureResult["status"] as? String, "failed")
        XCTAssertEqual(nestedFailureResult["errorMessage"] as? String, "request blocked")

        let legacyMessageController = makeController()
        let legacyMessage = try XCTUnwrap(legacyMessageController.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "toolCall",
                "id": "call_web_read_legacy_message",
                "name": "web_fetch",
                "isError": true,
                "message": "legacy request failed"
            ])
        ))
        let legacyMessageResult = try XCTUnwrap(jsonObject(from: legacyMessage.resultJSON))
        XCTAssertEqual(legacyMessageResult["errorMessage"] as? String, "legacy request failed")
    }

    func testNativeWebSearchCompletionPayloadsPreserveCompactSearchFields() throws {
        let longQuery = String(repeating: "query", count: 140)
        let boundedController = makeController()
        let bounded = try XCTUnwrap(boundedController.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "webSearch",
                "id": "call_search_bounded_query",
                "query": longQuery,
                "action": ["type": "search", "query": longQuery]
            ])
        ))
        let boundedArgs = try XCTUnwrap(jsonObject(from: bounded.argsJSON))
        let boundedResult = try XCTUnwrap(jsonObject(from: bounded.resultJSON))
        XCTAssertEqual((boundedArgs["query"] as? String)?.count, 500)
        XCTAssertEqual((boundedResult["query"] as? String)?.count, 500)
        XCTAssertTrue((boundedResult["query"] as? String)?.hasSuffix("…") == true)

        let rawQueries = (0 ..< 12).map { index in
            index == 0 ? longQuery : "query \(index)"
        }
        let boundedList = try XCTUnwrap(makeController().test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "webSearch",
                "id": "call_search_bounded_queries",
                "action": ["type": "search", "queries": rawQueries]
            ])
        ))
        let boundedListArgs = try XCTUnwrap(jsonObject(from: boundedList.argsJSON))
        let boundedListResult = try XCTUnwrap(jsonObject(from: boundedList.resultJSON))
        let argsQueries = try XCTUnwrap(boundedListArgs["queries"] as? [String])
        let resultQueries = try XCTUnwrap(boundedListResult["queries"] as? [String])
        XCTAssertEqual(argsQueries.count, 10)
        XCTAssertEqual(resultQueries, argsQueries)
        XCTAssertEqual(argsQueries.first?.count, 500)
        XCTAssertTrue(argsQueries.first?.hasSuffix("…") == true)

        let rows: [(label: String, alias: String, item: [String: Any], expectedResults: Int?, expectedSources: Int?, expectedDetailKey: String)] = [
            (
                "root results",
                "web_search",
                [
                    "type": "toolCall",
                    "id": "call_search_root",
                    "name": "web_search",
                    "status": "completed",
                    "query": "RepoPrompt CE",
                    "results": [["title": "RepoPrompt CE", "url": "https://example.com/repo", "snippet": "Native cards"]],
                    "sources": [["title": "Docs", "url": "https://example.com/docs"]]
                ],
                1,
                1,
                "results"
            ),
            (
                "wrapped response",
                "web_search_request",
                [
                    "type": "toolCall",
                    "id": "call_search_wrapped",
                    "name": "web_search_request",
                    "query": "macOS app search",
                    "response": [
                        "summary": "Search completed",
                        "items": [["title": "Result", "snippet": "Useful result"]]
                    ],
                    "sources": [["title": "Wrapped Source"]],
                    "total_results": 3,
                    "source_count": 4,
                    "citationCount": 2
                ],
                nil,
                1,
                "items"
            ),
            (
                "array content",
                "google_web_search",
                [
                    "type": "toolCall",
                    "id": "call_search_array",
                    "name": "google_web_search",
                    "query": "Codex native web search",
                    "content": [["title": "Codex", "snippet": "Web search result"]]
                ],
                1,
                nil,
                "results"
            )
        ]

        for row in rows {
            let controller = makeController()
            let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
                method: "item/completed",
                params: toolParams(item: row.item)
            ), row.label)

            XCTAssertEqual(completed.kind, "result", row.label)
            XCTAssertEqual(completed.name, "search", row.label)
            XCTAssertNotEqual(completed.isError, true, row.label)
            let resultObject = try XCTUnwrap(jsonObject(from: completed.resultJSON), row.label)
            XCTAssertEqual(resultObject["query"] as? String, row.item["query"] as? String, row.label)
            if let expectedResults = row.expectedResults {
                XCTAssertEqual((resultObject["results"] as? [[String: Any]])?.count, expectedResults, row.label)
            }
            if let expectedSources = row.expectedSources {
                XCTAssertEqual((resultObject["sources"] as? [[String: Any]])?.count, expectedSources, row.label)
            }
            XCTAssertNotNil(resultObject[row.expectedDetailKey], row.label)
            if row.label == "wrapped response" {
                XCTAssertEqual(resultObject["total_results"] as? Int, 3)
                XCTAssertEqual(resultObject["source_count"] as? Int, 4)
                XCTAssertEqual(resultObject["citationCount"] as? Int, 2)
            }
        }
    }

    func testNativeWebSearchWrappedPayloadMergesSiblingSearchFieldsAndSuccessfulStatusWins() throws {
        let controller = makeController()
        let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "toolCall",
                "id": "call_search_completed_with_stale_error",
                "name": "web_search",
                "status": "completed",
                "query": "completed despite stale error field",
                "response": [
                    "items": [["title": "Completed", "snippet": "Usable result"]]
                ],
                "citations": [["title": "Citation"]],
                "total_results": 9,
                "errorMessage": "stale retry warning",
                "errors": [["message": "stale retry detail"]]
            ])
        ))

        XCTAssertEqual(completed.kind, "result")
        XCTAssertEqual(completed.name, "search")
        XCTAssertEqual(completed.isError, false)
        let resultObject = try XCTUnwrap(jsonObject(from: completed.resultJSON))
        XCTAssertEqual(resultObject["query"] as? String, "completed despite stale error field")
        XCTAssertEqual((resultObject["items"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((resultObject["citations"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(resultObject["total_results"] as? Int, 9)
        XCTAssertEqual(resultObject["errorMessage"] as? String, "stale retry warning")
        XCTAssertEqual((resultObject["errors"] as? [[String: Any]])?.count, 1)
    }

    func testNativeWebSearchErrorPayloadWithoutFailedStatusParsesAsFailure() throws {
        let controller = makeController()
        let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "toolCall",
                "id": "call_search_error_without_status",
                "name": "web_search",
                "query": "transient web outage",
                "errorMessage": "web search timed out"
            ])
        ))

        XCTAssertEqual(completed.kind, "result")
        XCTAssertEqual(completed.name, "search")
        XCTAssertEqual(completed.isError, true)
        let resultObject = try XCTUnwrap(jsonObject(from: completed.resultJSON))
        XCTAssertEqual(resultObject["query"] as? String, "transient web outage")
        XCTAssertEqual(resultObject["errorMessage"] as? String, "web search timed out")
    }

    private func makeController() -> CodexNativeSessionController {
        CodexNativeSessionController(
            client: CodexAppServerClient(),
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil
        )
    }

    private func makeControllerWithThread(turnID: String) -> CodexNativeSessionController {
        let controller = makeController()
        controller.test_installThreadState(
            threadID: "thread-active",
            authoritativeTurnID: turnID,
            routingTurnID: turnID
        )
        return controller
    }

    private func assistantDeltaParams(
        turnID: String,
        itemID: String? = "assistant-item-1",
        delta: String
    ) -> [String: CodexJSONValue] {
        var params: [String: CodexJSONValue] = [
            "threadId": .string("thread-active"),
            "turnId": .string(turnID),
            "delta": .string(delta)
        ]
        if let itemID {
            params["itemId"] = .string(itemID)
        }
        return params
    }

    private func legacyAssistantCompleteParams(
        turnID: String,
        eventID: String? = nil,
        itemID: String? = nil,
        message: String
    ) -> [String: CodexJSONValue] {
        var params: [String: CodexJSONValue] = [
            "threadId": .string("thread-active"),
            "turnId": .string(turnID),
            "msg": .object([
                "type": .string("agent_message"),
                "message": .string(message)
            ])
        ]
        if let eventID {
            params["id"] = .string(eventID)
        }
        if let itemID {
            params["itemId"] = .string(itemID)
        }
        return params
    }

    private func turnLifecycleParams(turnID: String, status: String? = nil) -> [String: CodexJSONValue] {
        var turn: [String: CodexJSONValue] = ["id": .string(turnID)]
        if let status {
            turn["status"] = .string(status)
        }
        return [
            "threadId": .string("thread-active"),
            "turn": .object(turn)
        ]
    }

    private func finishAndReadAssistantDeltas(
        from controller: CodexNativeSessionController
    ) async -> [String] {
        let events = await finishAndReadEvents(from: controller)
        return events.compactMap { event in
            switch event {
            case let .assistantDelta(delta):
                delta
            case let .canonicalAssistantDelta(text, _):
                text
            default:
                nil
            }
        }
    }

    private func finishAndReadEvents(
        from controller: CodexNativeSessionController
    ) async -> [CodexNativeSessionController.Event] {
        await controller.shutdown()
        var events: [CodexNativeSessionController.Event] = []
        for await event in controller.events {
            events.append(event)
        }
        return events
    }

    private func canonicalCompletedItemParams(
        turnID: String,
        itemID: String,
        type: String,
        fields: [String: CodexJSONValue] = [:]
    ) -> [String: CodexJSONValue] {
        var item: [String: CodexJSONValue] = [
            "id": .string(itemID),
            "type": .string(type)
        ]
        item.merge(fields) { _, new in new }
        return [
            "threadId": .string("thread-active"),
            "turnId": .string(turnID),
            "item": .object(item)
        ]
    }

    private func canonicalMCPItemParams(
        turnID: String,
        itemID: String,
        status: String,
        arguments: [String: CodexJSONValue],
        result: CodexJSONValue? = nil,
        error: CodexJSONValue? = nil
    ) -> [String: CodexJSONValue] {
        var fields: [String: CodexJSONValue] = [
            "server": .string("third-party"),
            "tool": .string("lookup"),
            "status": .string(status),
            "arguments": .object(arguments)
        ]
        if let result {
            fields["result"] = result
        }
        if let error {
            fields["error"] = error
        }
        return canonicalCompletedItemParams(
            turnID: turnID,
            itemID: itemID,
            type: "mcpToolCall",
            fields: fields
        )
    }

    private func toolParams(item: [String: Any]) -> [String: Any] {
        [
            "threadId": "thread-active",
            "turnId": "turn-current",
            "item": item
        ]
    }

    private func jsonObject(from raw: String?) -> [String: Any]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
