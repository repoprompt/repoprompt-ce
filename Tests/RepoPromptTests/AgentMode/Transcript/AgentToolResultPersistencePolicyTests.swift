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

    func testCursorACPStructuredSummaryKeepsPrecedenceForAllowedOracleTools() throws {
        let raw = jsonString([
            "status": "success",
            "acp_status": "completed",
            "kind": "message",
            "title": "Tool result",
            "chat_id": "chat-789",
            "mode": "review",
            "response": "raw oracle response",
            "content": [[
                "type": "text",
                "text": "cursor acp text payload"
            ]]
        ])

        let summary = try XCTUnwrap(persistedSummary(toolName: "ask_oracle", rawResultJSON: raw))
        let object = try decodedObject(summary.resultJSON)
        let content = try XCTUnwrap(object["content"] as? [[String: Any]])
        let firstContent = try XCTUnwrap(content.first)

        XCTAssertEqual(object["acp_status"] as? String, "completed")
        XCTAssertEqual(object["kind"] as? String, "message")
        XCTAssertEqual(firstContent["text_bytes"] as? Int, "cursor acp text payload".utf8.count)
        XCTAssertNil(object["chat_id"])
        XCTAssertNil(object["mode"])
        XCTAssertNil(object["has_response"])
        XCTAssertNil(object["response"])
        XCTAssertFalse(summary.resultJSON.contains("raw oracle response"))
        XCTAssertLessThanOrEqual(summary.resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
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
