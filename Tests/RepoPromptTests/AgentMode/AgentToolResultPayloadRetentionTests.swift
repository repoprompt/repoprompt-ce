@testable import RepoPromptApp
import XCTest

final class AgentToolResultPayloadRetentionTests: XCTestCase {
    private let rich = #"{"review":{"chat_id":"c","oracle_results":[]},"status":"success"}"#

    func testEmptyLaterUpdateKeepsEarlierResult() {
        for thin in [nil, "", "  \n", "{}", "[]", "null", "\"\""] {
            XCTAssertTrue(
                AgentToolResultPayloadRetention.shouldKeepExisting(existing: rich, incoming: thin, incomingIsError: false),
                String(describing: thin)
            )
        }
    }

    func testRealUpdatesAndErrorsStillReplace() {
        XCTAssertFalse(AgentToolResultPayloadRetention.shouldKeepExisting(existing: rich, incoming: #"{"status":"x"}"#, incomingIsError: false))
        XCTAssertFalse(AgentToolResultPayloadRetention.shouldKeepExisting(existing: rich, incoming: "", incomingIsError: true))
        XCTAssertFalse(AgentToolResultPayloadRetention.shouldKeepExisting(existing: "", incoming: "", incomingIsError: false))
        XCTAssertFalse(AgentToolResultPayloadRetention.shouldKeepExisting(existing: rich, incoming: "plain text", incomingIsError: false))
    }

    func testProgressUpdatesNeverReplaceARealResult() {
        let running = #"{"title":"Called manage_selection from RepoPromptCE","status":"running"}"#
        let finalContent = #"[{"type":"content","content":{"type":"text","text":"Selection set"}}]"#
        // Devin sends a progress update after RepoPrompt's own result arrived.
        XCTAssertTrue(AgentToolResultPayloadRetention.shouldKeepExisting(
            existing: rich, incoming: running, incomingIsError: false, requireObjectReplacement: true
        ))
        // A real result always replaces a progress placeholder, even a text echo.
        XCTAssertFalse(AgentToolResultPayloadRetention.shouldKeepExisting(
            existing: running, incoming: finalContent, incomingIsError: false, requireObjectReplacement: true
        ))
        XCTAssertFalse(AgentToolResultPayloadRetention.shouldKeepExisting(
            existing: running, incoming: rich, incomingIsError: false, requireObjectReplacement: true
        ))
        // A result that merely has a running status plus real fields is not progress.
        XCTAssertFalse(AgentToolResultPayloadRetention.isProgress(#"{"status":"running","context_id":"x"}"#))
    }

    func testBareTerminalMarkerCompletesStreamedProgressAndKeepsRealResults() throws {
        let streamed = #"{"content":[{"type":"content"}],"status":"running"}"#
        let completed = #"{"status":"completed"}"#
        let merged = try XCTUnwrap(AgentToolResultPayloadRetention.resolvedPayload(
            existing: streamed, incoming: completed, incomingIsError: false
        ))
        XCTAssertTrue(merged.contains(#""status":"completed""#), merged)
        XCTAssertTrue(merged.contains(#""content""#), merged)
        // A terminal marker never erases RepoPrompt's own structured result.
        XCTAssertNil(AgentToolResultPayloadRetention.resolvedPayload(
            existing: rich, incoming: completed, incomingIsError: false, requireObjectReplacement: true
        ))
        // With nothing earlier, the marker is stored as-is.
        XCTAssertEqual(
            AgentToolResultPayloadRetention.resolvedPayload(existing: nil, incoming: completed, incomingIsError: false),
            completed
        )
    }

    func testPrettyPrintedDevinSkillLifecycleCompletes() {
        let running = "{\n  \"status\" : \"running\"\n}"
        let completed = "{\n  \"status\" : \"completed\"\n}"
        XCTAssertEqual(
            AgentToolResultPayloadRetention.resolvedPayload(existing: running, incoming: completed, incomingIsError: false),
            #"{"status":"completed"}"#
        )
    }

    func testTerminalMarkerFinishesSanitizedPresentationSummary() throws {
        let summary = #"{"render_summary":{"detail_text":"running","op":"skill","status":"running","title":"Skill","tool_name":"skill"},"status":"running","summary_only":true,"summary_text":"running"}"#
        let merged = try XCTUnwrap(AgentToolResultPayloadRetention.resolvedPayload(
            existing: summary, incoming: "{\n  \"status\" : \"completed\"\n}", incomingIsError: false
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any])
        let render = try XCTUnwrap(object["render_summary"] as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "completed")
        XCTAssertEqual(render["status"] as? String, "success")
        XCTAssertNil(render["detail_text"])
        XCTAssertNil(object["summary_text"])
        XCTAssertEqual(render["title"] as? String, "Skill")
    }

    func testObjectReplacementModeKeepsObjectOverText() {
        XCTAssertTrue(AgentToolResultPayloadRetention.shouldKeepExisting(
            existing: rich, incoming: "Context built.", incomingIsError: false, requireObjectReplacement: true
        ))
        XCTAssertFalse(AgentToolResultPayloadRetention.shouldKeepExisting(
            existing: rich, incoming: #"{"status":"success"}"#, incomingIsError: false, requireObjectReplacement: true
        ))
        XCTAssertFalse(AgentToolResultPayloadRetention.shouldKeepExisting(
            existing: "text", incoming: "other text", incomingIsError: false, requireObjectReplacement: true
        ))
    }
}
