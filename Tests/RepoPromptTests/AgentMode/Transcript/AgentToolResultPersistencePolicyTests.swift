@testable import RepoPrompt
import XCTest

final class AgentToolResultPersistencePolicyTests: XCTestCase {
    func testConfirmedOracleSendToolNamesPersistBoundedStructuredSummaries() throws {
        let rows: [(toolName: String, receivesOracleMetadata: Bool)] = [
            ("ask_oracle", true),
            ("oracle_send", true),
            ("chat_send", false)
        ]

        for row in rows {
            let rawResponse = String(repeating: "oracle raw response ", count: 40)
            let rawError = String(repeating: "raw oracle error ", count: 20)
            let rawDiff = "diff --git a/File.swift b/File.swift\n@@ -1 +1 @@\n-old\n+new"
            let raw = jsonString([
                "status": "success",
                "chat_id": "chat-123",
                "mode": "review",
                "response": rawResponse,
                "diffs": [["path": "File.swift", "diff": rawDiff]],
                "errors": [rawError]
            ])

            let summary = try XCTUnwrap(persistedSummary(toolName: row.toolName, rawResultJSON: raw))
            let object = try decodedObject(summary.resultJSON)

            XCTAssertEqual(object["status"] as? String, "success", row.toolName)
            XCTAssertTrue(summary.summaryOnly, row.toolName)
            XCTAssertEqual(object["summary_only"] as? Bool, true, row.toolName)
            if row.receivesOracleMetadata {
                XCTAssertEqual(object["chat_id"] as? String, "chat-123", row.toolName)
                XCTAssertEqual(object["mode"] as? String, "review", row.toolName)
                XCTAssertEqual(object["has_response"] as? Bool, true, row.toolName)
                XCTAssertEqual(object["diff_count"] as? Int, 1, row.toolName)
                XCTAssertEqual(object["error_count"] as? Int, 1, row.toolName)
                XCTAssertEqual(object["summary_text"] as? String, "review • 1 diff", row.toolName)
            } else {
                XCTAssertNil(object["chat_id"], row.toolName)
                XCTAssertNil(object["mode"], row.toolName)
                XCTAssertNil(object["has_response"], row.toolName)
                XCTAssertNil(object["diff_count"], row.toolName)
                XCTAssertNil(object["error_count"], row.toolName)
                XCTAssertEqual(object["summary_text"] as? String, "chat_send • success", row.toolName)
            }
            XCTAssertNil(object["response"], row.toolName)
            XCTAssertNil(object["diffs"], row.toolName)
            XCTAssertNil(object["errors"], row.toolName)
            XCTAssertFalse(summary.resultJSON.contains(rawResponse), row.toolName)
            XCTAssertFalse(summary.resultJSON.contains(rawDiff), row.toolName)
            XCTAssertFalse(summary.resultJSON.contains(rawError), row.toolName)
            XCTAssertLessThanOrEqual(summary.resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes, row.toolName)
        }
    }

    func testContextBuilderPersistsOnlySelectedBoundedFollowUpRoutingMetadata() throws {
        let rows: [(responseType: String, selectedKey: String, chatID: String, mode: String)] = [
            ("plan", "plan", "plan-chat", "plan"),
            ("review", "review", "review-chat", "review")
        ]

        for row in rows {
            let bulkyResponse = String(repeating: "generated response ", count: 200)
            let bulkyDiff = String(repeating: "diff --git a/File.swift b/File.swift\n", count: 100)
            let raw = jsonString([
                "status": "success",
                "context_id": "11111111-2222-3333-4444-555555555555",
                "response_type": row.responseType,
                "plan": [
                    "chat_id": "plan-chat",
                    "mode": "plan",
                    "response": bulkyResponse,
                    "diffs": [["path": "File.swift", "patch": bulkyDiff]],
                    "errors": ["plan error"]
                ],
                "review": [
                    "chat_id": "review-chat",
                    "mode": "review",
                    "response": bulkyResponse,
                    "diffs": [["path": "File.swift", "patch": bulkyDiff]],
                    "errors": ["review error"]
                ]
            ])

            let summary = try XCTUnwrap(persistedSummary(toolName: "context_builder", rawResultJSON: raw))
            let object = try decodedObject(summary.resultJSON)
            let selectedReply = try XCTUnwrap(object[row.selectedKey] as? [String: Any])
            let unselectedKey = row.selectedKey == "plan" ? "review" : "plan"
            let dto = try XCTUnwrap(ToolJSON.decode(
                ToolResultDTOs.ContextBuilderDTO.self,
                from: summary.resultJSON
            ))
            let selectedDTO = row.selectedKey == "plan" ? dto.plan : dto.review

            XCTAssertTrue(summary.summaryOnly, row.responseType)
            XCTAssertEqual(object["status"] as? String, "success", row.responseType)
            XCTAssertEqual(object["summary_only"] as? Bool, true, row.responseType)
            XCTAssertEqual(object["context_id"] as? String, "11111111-2222-3333-4444-555555555555", row.responseType)
            XCTAssertEqual(object["response_type"] as? String, row.responseType, row.responseType)
            XCTAssertEqual(selectedReply["chat_id"] as? String, row.chatID, row.responseType)
            XCTAssertEqual(selectedReply["mode"] as? String, row.mode, row.responseType)
            XCTAssertNil(selectedReply["response"], row.responseType)
            XCTAssertNil(selectedReply["diffs"], row.responseType)
            XCTAssertNil(selectedReply["errors"], row.responseType)
            XCTAssertNil(object[unselectedKey], row.responseType)
            XCTAssertEqual(dto.tabID, "11111111-2222-3333-4444-555555555555", row.responseType)
            XCTAssertEqual(dto.responseType, row.responseType, row.responseType)
            XCTAssertEqual(selectedDTO?.chatID, row.chatID, row.responseType)
            XCTAssertEqual(selectedDTO?.mode, row.mode, row.responseType)
            XCTAssertFalse(summary.resultJSON.contains(bulkyResponse), row.responseType)
            XCTAssertFalse(summary.resultJSON.contains(bulkyDiff), row.responseType)
            XCTAssertLessThanOrEqual(
                summary.resultJSON.utf8.count,
                AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes,
                row.responseType
            )
        }
    }

    func testOversizedStructuredSummaryFallsBackToMinimalResultJSON() throws {
        let oversizedReviewStatus = String(repeating: "approved-with-a-very-long-note-", count: 120)
        let raw = jsonString([
            "status": "success",
            "edits_requested": 1,
            "edits_applied": 1,
            "review_status": oversizedReviewStatus
        ])

        let summary = try XCTUnwrap(persistedSummary(toolName: "apply_edits", rawResultJSON: raw))
        let object = try decodedObject(summary.resultJSON)

        XCTAssertEqual(object["status"] as? String, "success")
        XCTAssertEqual(object["summary_only"] as? Bool, true)
        XCTAssertNil(object["review_status"])
        XCTAssertFalse(summary.resultJSON.contains(oversizedReviewStatus))
        XCTAssertLessThanOrEqual(summary.resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
    }

    func testAgentManagePersistsSmallDeleteAndSkipCounts() throws {
        let raw = jsonString([
            "status": "success",
            "deleted_sessions": ["a", "b", "c"],
            "skipped_sessions": ["d", "e"],
            "agent": ["id": "agent-1", "name": "Pair Programmer"],
            "sessions": [["name": "raw-session", "state": "closed"]]
        ])

        let summary = try XCTUnwrap(persistedSummary(toolName: "agent_manage", rawResultJSON: raw))
        let object = try decodedObject(summary.resultJSON)

        XCTAssertEqual(object["status"] as? String, "success")
        XCTAssertEqual(object["summary_only"] as? Bool, true)
        XCTAssertEqual(object["deleted_count"] as? Int, 3)
        XCTAssertEqual(object["skipped_count"] as? Int, 2)
        XCTAssertEqual(object["summary_text"] as? String, "3 deleted, 2 skipped")
        XCTAssertNil(object["deleted_sessions"])
        XCTAssertNil(object["skipped_sessions"])
        XCTAssertNil(object["agent"])
        XCTAssertNil(object["sessions"])
        XCTAssertLessThanOrEqual(summary.resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
    }

    func testCursorACPStructuredSummaryKeepsChatIDForAllowedOracleTools() throws {
        for toolName in ["ask_oracle", "oracle_send"] {
            let events = CursorACPEventNormalizer.normalize([
                "sessionUpdate": "tool_call_update",
                "status": "completed",
                "toolCallId": "oracle-routing-\(toolName)",
                "toolName": toolName,
                "kind": "message",
                "title": "Tool result",
                "rawOutput": [
                    "chat_id": "chat-789",
                    "mode": "review",
                    "response": "raw oracle response"
                ],
                "content": [[
                    "type": "text",
                    "text": "cursor acp text payload"
                ]]
            ])
            guard case let .stream(result) = try XCTUnwrap(events.first) else {
                return XCTFail("Expected normalized Cursor ACP stream event for \(toolName)")
            }
            let raw = try XCTUnwrap(result.toolResultJSON)
            let summary = try XCTUnwrap(persistedSummary(toolName: toolName, rawResultJSON: raw))
            let object = try decodedObject(summary.resultJSON)
            let content = try XCTUnwrap(object["content"] as? [[String: Any]])
            let firstContent = try XCTUnwrap(content.first)

            XCTAssertEqual(object["acp_status"] as? String, "completed", toolName)
            XCTAssertEqual(object["kind"] as? String, "message", toolName)
            XCTAssertEqual(object["chat_id"] as? String, "chat-789", toolName)
            XCTAssertEqual(firstContent["text_bytes"] as? Int, "cursor acp text payload".utf8.count, toolName)
            XCTAssertNil(object["mode"], toolName)
            XCTAssertNil(object["has_response"], toolName)
            XCTAssertNil(object["response"], toolName)
            XCTAssertFalse(summary.resultJSON.contains("raw oracle response"), toolName)
            XCTAssertLessThanOrEqual(
                summary.resultJSON.utf8.count,
                AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes,
                toolName
            )
        }
    }

    func testCompletionOnlyToolResultFactoryPreservesArgsForPersistenceClassification() throws {
        let args = jsonString([
            "action": "find_in_page",
            "url": "https://example.com/docs",
            "pattern": "install"
        ])
        let invocationID = UUID()
        let raw = jsonString(["status": "completed", "match_count": 2])
        let item = AgentChatItem.toolResult(
            name: "search",
            invocationID: invocationID,
            argsJSON: args,
            resultJSON: raw,
            isError: false,
            sequenceIndex: 42
        )

        XCTAssertEqual(item.toolInvocationID, invocationID)
        XCTAssertEqual(item.toolArgsJSON, args)
        XCTAssertEqual(item.toolResultJSON, raw)
        XCTAssertEqual(item.toolIsError, false)
        XCTAssertEqual(item.sequenceIndex, 42)
        let persisted = AgentChatItemPersist(from: item)
        let object = try decodedObject(XCTUnwrap(persisted.toolResultJSON))
        let renderSummary = try XCTUnwrap(object["render_summary"] as? [String: Any])
        XCTAssertEqual(renderSummary["title"] as? String, "Find In Page")
        XCTAssertEqual(renderSummary["op"] as? String, "find_in_page")
    }

    func testWebSearchPersistsBoundedSummaryOnlySuccessPresentation() throws {
        let bulkySnippet = String(repeating: "full page body ", count: 80)
        let raw = jsonString([
            "status": "completed",
            "query": "native web search cards",
            "results": [[
                "title": "Native Web Search Cards",
                "url": "https://example.com/search-cards",
                "snippet": bulkySnippet
            ]],
            "sources": [["title": "Plan", "url": "https://example.com/plan"]]
        ])
        let args = jsonString(["query": "native web search cards"])

        let summary = try XCTUnwrap(persistedSummary(toolName: "search", rawResultJSON: raw, argsJSON: args))
        let object = try decodedObject(summary.resultJSON)
        let renderSummary = try XCTUnwrap(object["render_summary"] as? [String: Any])
        let restored = try XCTUnwrap(StoredToolCardPresentation.fromSummaryOnly(raw: summary.resultJSON))

        XCTAssertTrue(summary.summaryOnly)
        XCTAssertEqual(object["summary_only"] as? Bool, true)
        XCTAssertEqual(renderSummary["tool_name"] as? String, "search")
        XCTAssertEqual(renderSummary["title"] as? String, "Web Search")
        XCTAssertEqual(renderSummary["status"] as? String, "success")
        XCTAssertTrue((renderSummary["subtitle"] as? String)?.contains("native web search cards") == true)
        XCTAssertTrue((renderSummary["subtitle"] as? String)?.contains("1 result") == true)
        XCTAssertTrue((renderSummary["subtitle"] as? String)?.contains("1 source") == true)
        XCTAssertEqual(restored.title, "Web Search")
        XCTAssertEqual(restored.status, .success)
        XCTAssertFalse(summary.resultJSON.contains(bulkySnippet))
        XCTAssertNil(object["results"])
        XCTAssertLessThanOrEqual(summary.resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
    }

    func testWebReadAndFindPersistActionAwareSummaryOnlyPresentations() throws {
        let readRaw = jsonString([
            "status": "completed",
            "title": "RepoPrompt docs",
            "content": String(repeating: "full page body ", count: 80)
        ])
        let readArgs = jsonString(["url": "https://docs.example.com/a/b/c"])
        let readSummary = try XCTUnwrap(persistedSummary(toolName: "webfetch", rawResultJSON: readRaw, argsJSON: readArgs))
        let readObject = try decodedObject(readSummary.resultJSON)
        let readRenderSummary = try XCTUnwrap(readObject["render_summary"] as? [String: Any])
        XCTAssertEqual(readRenderSummary["tool_name"] as? String, "web_read")
        XCTAssertEqual(readRenderSummary["title"] as? String, "Read Web Page")
        XCTAssertEqual(readRenderSummary["subtitle"] as? String, "docs.example.com/…/c")
        XCTAssertEqual(readRenderSummary["detail_text"] as? String, "RepoPrompt docs")
        XCTAssertFalse(readSummary.resultJSON.contains("full page body"))

        let bodySummaryRaw = jsonString([
            "status": "completed",
            "summary": String(repeating: "page body ", count: 80)
        ])
        let bodySummary = try XCTUnwrap(persistedSummary(toolName: "webfetch", rawResultJSON: bodySummaryRaw, argsJSON: readArgs))
        XCTAssertFalse(bodySummary.resultJSON.contains("page body"))

        let findRaw = jsonString(["status": "completed", "match_count": 3])
        let findArgs = jsonString(["url": "https://example.com/docs", "pattern": "needle"])
        let findSummary = try XCTUnwrap(persistedSummary(toolName: "search", rawResultJSON: findRaw, argsJSON: findArgs))
        let findObject = try decodedObject(findSummary.resultJSON)
        let findRenderSummary = try XCTUnwrap(findObject["render_summary"] as? [String: Any])
        XCTAssertEqual(findRenderSummary["tool_name"] as? String, "search")
        XCTAssertEqual(findRenderSummary["title"] as? String, "Find In Page")
        XCTAssertEqual(findRenderSummary["op"] as? String, "find_in_page")
        XCTAssertEqual(findRenderSummary["detail_text"] as? String, "3 matches")
        let restored = try XCTUnwrap(StoredToolCardPresentation.fromSummaryOnly(raw: findSummary.resultJSON))
        XCTAssertEqual(restored.title, "Find In Page")
    }

    func testWebSearchPersistsBoundedSummaryOnlyErrorPresentation() throws {
        let raw = jsonString([
            "status": "failed",
            "query": "native web search cards",
            "error": ["message": "web search unavailable"]
        ])
        let args = jsonString(["query": "native web search cards"])

        let summary = try XCTUnwrap(persistedSummary(toolName: "web_search", rawResultJSON: raw, argsJSON: args))
        let object = try decodedObject(summary.resultJSON)
        let renderSummary = try XCTUnwrap(object["render_summary"] as? [String: Any])
        let restored = try XCTUnwrap(StoredToolCardPresentation.fromSummaryOnly(raw: summary.resultJSON))

        XCTAssertTrue(summary.summaryOnly)
        XCTAssertEqual(renderSummary["tool_name"] as? String, "search")
        XCTAssertEqual(renderSummary["title"] as? String, "Web Search")
        XCTAssertEqual(renderSummary["status"] as? String, "failure")
        XCTAssertTrue((renderSummary["detail_text"] as? String)?.contains("web search unavailable") == true)
        XCTAssertEqual(restored.title, "Web Search")
        XCTAssertEqual(restored.status, .failure)
        XCTAssertLessThanOrEqual(summary.resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
    }

    func testSummaryOnlyFalseOnlyForPromptExportStructuredMetadata() throws {
        let promptRaw = jsonString([
            "op": "export",
            "export": [
                "path": "/tmp/context.txt",
                "tokens": 42,
                "bytes": 2048
            ]
        ])
        let promptSummary = try XCTUnwrap(persistedSummary(toolName: "prompt", rawResultJSON: promptRaw))
        let promptObject = try decodedObject(promptSummary.resultJSON)
        let export = try XCTUnwrap(promptObject["export"] as? [String: Any])

        XCTAssertFalse(promptSummary.summaryOnly)
        XCTAssertEqual(promptObject["op"] as? String, "export")
        XCTAssertEqual(export["path"] as? String, "/tmp/context.txt")
        XCTAssertEqual(export["tokens"] as? Int, 42)
        XCTAssertEqual(export["bytes"] as? Int, 2048)
        XCTAssertNil(promptObject["summary_only"])
    }

    func testTrustedIncrementalFinalTurnSanitizationMatchesFullSanitization() {
        let turnID = UUID()
        let spanID = UUID()
        let startedAt = Date()
        let activities = (0 ..< 100).map { sequenceIndex in
            makeReadFileActivity(
                id: UUID(),
                sequenceIndex: sequenceIndex,
                marker: "before-\(sequenceIndex)"
            )
        }
        let previousRaw = AgentTranscript(
            turns: [
                AgentTranscriptTurn(
                    id: turnID,
                    responseSpans: [
                        AgentTranscriptProviderResponseSpan(
                            id: spanID,
                            lifecycle: .open,
                            startedAt: startedAt,
                            activities: activities
                        )
                    ],
                    startedAt: startedAt
                )
            ],
            nextSequenceIndex: 100
        )
        let previousSanitized = AgentToolResultPersistencePolicy
            .sanitizeTranscriptWithMetrics(previousRaw)
            .transcript

        var updatedActivities = activities
        updatedActivities[99] = makeReadFileActivity(
            id: activities[99].id,
            sequenceIndex: 99,
            marker: "after"
        )
        let updatedRaw = AgentTranscript(
            turns: [
                AgentTranscriptTurn(
                    id: turnID,
                    responseSpans: [
                        AgentTranscriptProviderResponseSpan(
                            id: spanID,
                            lifecycle: .open,
                            startedAt: startedAt,
                            activities: updatedActivities
                        )
                    ],
                    startedAt: startedAt
                )
            ],
            nextSequenceIndex: 100
        )

        let incremental = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            updatedRaw,
            previousSanitizedTranscript: previousSanitized,
            trustedReusablePrefixTurnCount: 0,
            trustedIncrementalFinalTurnStartSequenceIndex: 99
        )
        let fullySanitized = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(updatedRaw)

        XCTAssertEqual(incremental.transcript, fullySanitized.transcript)
        XCTAssertLessThanOrEqual(incremental.sanitizedActivityCount, 1)
        XCTAssertGreaterThan(fullySanitized.sanitizedActivityCount, incremental.sanitizedActivityCount)
    }

    func testIncrementalSanitizerFallbackDoesNotReuseChangedCompactionPrefix() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 1)
        let prefixActivity = makeReadFileActivity(
            id: UUID(),
            sequenceIndex: 0,
            marker: "prefix"
        )
        let previousFinalActivity = makeReadFileActivity(
            id: UUID(),
            sequenceIndex: 100,
            marker: "previous-final"
        )
        let previousRaw = AgentTranscript(
            turns: [
                AgentTranscriptTurn(
                    id: UUID(),
                    responseSpans: [
                        AgentTranscriptProviderResponseSpan(
                            lifecycle: .completed,
                            startedAt: startedAt,
                            activities: [prefixActivity]
                        )
                    ],
                    retentionTier: .archived,
                    startedAt: startedAt,
                    completedAt: startedAt
                ),
                AgentTranscriptTurn(
                    id: UUID(),
                    responseSpans: [
                        AgentTranscriptProviderResponseSpan(
                            lifecycle: .open,
                            startedAt: startedAt,
                            activities: [previousFinalActivity]
                        )
                    ],
                    startedAt: startedAt
                )
            ],
            nextSequenceIndex: 101
        )
        let previousSanitized = AgentToolResultPersistencePolicy
            .sanitizeTranscriptWithMetrics(previousRaw)
            .transcript

        var changedPrefix = previousSanitized.turns[0]
        changedPrefix.retentionTier = .summary
        let changedFinalActivity = makeReadFileActivity(
            id: previousFinalActivity.id,
            sequenceIndex: 100,
            marker: "changed-final"
        )
        let appendedFinalActivity = makeReadFileActivity(
            id: UUID(),
            sequenceIndex: 101,
            marker: "appended-final"
        )
        var updatedRaw = previousRaw
        updatedRaw.turns[0] = changedPrefix
        updatedRaw.turns[1].responseSpans = [
            AgentTranscriptProviderResponseSpan(
                lifecycle: .completed,
                startedAt: startedAt,
                activities: [changedFinalActivity]
            ),
            AgentTranscriptProviderResponseSpan(
                lifecycle: .open,
                startedAt: startedAt,
                activities: [appendedFinalActivity]
            )
        ]
        updatedRaw.nextSequenceIndex = 102

        let incrementalFallback = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            updatedRaw,
            previousSanitizedTranscript: previousSanitized,
            trustedReusablePrefixTurnCount: 1,
            trustedIncrementalFinalTurnStartSequenceIndex: 100
        )
        let fullySanitized = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(updatedRaw)

        XCTAssertEqual(incrementalFallback.transcript, fullySanitized.transcript)
        XCTAssertEqual(incrementalFallback.transcript.turns[0].retentionTier, .summary)
        XCTAssertEqual(incrementalFallback.reusedTurnCount, 0)
    }

    private func persistedSummary(toolName: String, rawResultJSON: String, argsJSON: String? = nil) -> AgentPersistedToolResultSummary? {
        let invocationID = UUID()
        let item = AgentChatItem(
            kind: .toolResult,
            text: rawResultJSON,
            toolName: toolName,
            toolInvocationID: invocationID,
            toolArgsJSON: argsJSON,
            toolResultJSON: rawResultJSON
        )
        let execution = AgentTranscriptToolExecution(
            stableExecutionID: invocationID.uuidString,
            toolName: toolName,
            invocationID: invocationID,
            argsJSON: argsJSON,
            resultJSON: rawResultJSON,
            toolIsError: nil,
            status: .unknown
        )
        return AgentToolResultPersistencePolicy.persistedToolResultSummary(
            for: item,
            toolExecution: execution,
            rawResultTextFallback: rawResultJSON
        )
    }

    private func makeReadFileActivity(
        id: UUID,
        sequenceIndex: Int,
        marker: String
    ) -> AgentTranscriptActivity {
        let invocationID = UUID()
        let argsJSON = jsonString(["path": "/tmp/\(marker).txt"])
        let resultJSON = jsonString([
            "path": "/tmp/\(marker).txt",
            "content": String(repeating: "\(marker) payload ", count: 80)
        ])
        let execution = AgentTranscriptToolExecution(
            stableExecutionID: invocationID.uuidString,
            toolName: "read_file",
            invocationID: invocationID,
            argsJSON: argsJSON,
            resultJSON: resultJSON,
            toolIsError: false,
            status: .success
        )
        return AgentTranscriptActivity(
            id: id,
            timestamp: Date(timeIntervalSinceReferenceDate: TimeInterval(sequenceIndex)),
            sequenceIndex: sequenceIndex,
            role: .toolExecution,
            itemKind: .toolResult,
            text: resultJSON,
            toolExecution: execution
        )
    }

    private func jsonString(_ object: [String: Any], file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(object), file: file, line: line)
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func decodedObject(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8), file: file, line: line)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], file: file, line: line)
    }
}
