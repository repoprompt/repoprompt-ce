import Foundation
@testable import RepoPromptApp
import XCTest

final class GrokBuildACPEventNormalizerTests: XCTestCase {
    func testAgentMessageChunkProducesContentStream() {
        let events = GrokBuildACPEventNormalizer.normalize([
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": "hello from grok"]
        ])
        guard case let .stream(result) = events.first else {
            return XCTFail("expected stream event, got \(events)")
        }
        XCTAssertEqual(result.type, "content")
        XCTAssertEqual(result.text, "hello from grok")
    }

    func testAgentThoughtChunkProducesReasoningStream() {
        let events = GrokBuildACPEventNormalizer.normalize([
            "sessionUpdate": "agent_thought_chunk",
            "content": ["type": "text", "text": "thinking"]
        ])
        guard case let .stream(result) = events.first else {
            return XCTFail("expected stream event, got \(events)")
        }
        XCTAssertEqual(result.type, "reasoning")
    }

    func testTerminalToolUpdateProducesCanonicalACPStatusPayload() {
        let events = GrokBuildACPEventNormalizer.normalize([
            "sessionUpdate": "tool_call_update",
            "toolCallId": "call-1",
            "status": "completed",
            "rawOutput": ["exitCode": 0, "stdout": "ok"]
        ])
        guard case let .stream(result) = events.first else {
            return XCTFail("expected stream event, got \(events)")
        }
        XCTAssertEqual(result.type, "tool_result")
        let json = result.toolResultJSON ?? ""
        XCTAssertTrue(json.contains("acp_status"), "missing acp_status in \(json)")
        XCTAssertTrue(json.contains("completed"), "missing acp status value in \(json)")
        XCTAssertTrue(json.contains("success"), "missing normalized status in \(json)")
    }

    func testFailedToolUpdateMarksToolError() {
        let events = GrokBuildACPEventNormalizer.normalize([
            "sessionUpdate": "tool_call_update",
            "toolCallId": "call-2",
            "status": "failed",
            "rawOutput": ["exitCode": 3]
        ])
        guard case let .stream(result) = events.first else {
            return XCTFail("expected stream event, got \(events)")
        }
        XCTAssertTrue(result.toolIsError == true)
        let json = result.toolResultJSON ?? ""
        XCTAssertTrue(json.contains("failed"), "missing failed status in \(json)")
    }

    func testNativeEditClassificationIsExact() throws {
        let repoPromptTool = "mcp__\(RepoPromptMCPServerConfiguration.defaultServerName)__apply_edits"
        let cases: [(label: String, identity: [String: Any], expected: String)] = [
            ("1.0.62 search_replace", ["title": "search_replace"], "edit"),
            ("1.0.62 write", ["title": "write"], "edit"),
            ("legacy search_replace", ["title": "search_replace", "kind": "other", "status": "pending"], "edit"),
            ("legacy write", ["title": "write", "kind": "other", "status": "pending"], "edit"),
            ("explicit native identity", ["toolName": "write", "title": "Write a file"], "edit"),
            ("explicit identity wins title", ["toolName": "read_file", "title": "write"], "read_file"),
            ("RepoPrompt MCP identity", ["toolName": repoPromptTool, "title": "write"], repoPromptTool),
            ("external MCP identity", ["toolName": "mcp__external__write", "title": "write"], "mcp__external__write"),
            ("namespaced identity", ["title": "functions.search_replace"], "functions.search_replace"),
            ("unrelated native", ["title": "grep"], "grep"),
            ("kind is not native identity", ["title": "grep", "kind": "edit"], "grep"),
            ("nested metadata is not identity", ["title": "grep", "_meta": ["x.ai/tool": ["name": "write"]]], "grep"),
            ("hashline excluded", ["title": "hashline_edit"], "hashline_edit"),
            ("apply_patch excluded", ["title": "apply_patch"], "apply_patch"),
            ("no prefix matching", ["title": "write_file"], "write_file"),
            ("case is exact", ["title": "Search_Replace"], "Search_Replace")
        ]
        let args: [String: Any] = ["file_path": "/fixtures/classification.txt", "content": "unchanged\n"]
        for fixture in cases {
            let callID = "classification-\(fixture.label)"
            var payload = fixture.identity
            payload["sessionUpdate"] = "tool_call"
            payload["toolCallId"] = callID
            payload["rawInput"] = args
            let events = GrokBuildACPEventNormalizer.normalize(payload)
            XCTAssertEqual(events.count, 1, fixture.label)
            guard case let .stream(result) = events.first else {
                XCTFail("\(fixture.label): expected one stream event")
                continue
            }
            XCTAssertEqual(result.toolName, fixture.expected, "\(fixture.label): classify only the exact native identity")
            XCTAssertEqual(result.type, "tool_call", fixture.label)
            XCTAssertEqual(result.toolInvocationID, ACPRuntimeEventParsing.stableInvocationUUID(rawValue: callID), fixture.label)
            let actualArgs = try XCTUnwrap(ToolJSON.rawObject(from: result.toolArgsJSON), fixture.label)
            XCTAssertEqual(actualArgs as NSDictionary, args as NSDictionary, "\(fixture.label): preserve native arguments")
        }
    }

    func testTerminalEditDiffUsesBoundedPostEditCoordinates() throws {
        func detail(_ old: String, _ new: String, line: Int) -> [String: Any] {
            ["old_string": old, "new_string": new, "old_line": line, "new_line": line]
        }
        let first = detail("a", "b\nc", line: 3)
        let second = detail("d\ne", "f", line: 10)
        let third = detail("g", "h", line: 15)
        var cases: [(label: String, details: [[String: Any]], enriched: Bool, rawOutput: [String: Any])] = [
            ("post-edit starts after additions and removals", [first, second, third], true, [:]),
            ("completed status with failing raw output", [first], false, ["success": false])
        ]
        for (label, key, value) in [
            ("missing old", "old_line", nil),
            ("missing new", "new_line", nil),
            ("zero", "new_line", 0),
            ("negative", "old_line", -1),
            ("fractional", "new_line", 10.5),
            ("string", "old_line", "10"),
            ("boolean", "new_line", true),
            ("different starts", "old_line", 9)
        ] as [(String, String, Any?)] {
            var invalid = second
            invalid[key] = value
            cases.append((label, [first, invalid], false, [:]))
        }
        let halfBytes = ACPToolUpdateResultAdapter.generatedDiffInputBytesLimit / 2
        let longDetail = detail("x", String(repeating: "y", count: halfBytes), line: 20)
        cases.append(("aggregate byte limit", [longDetail, longDetail], false, [:]))
        let quarterLines = ACPToolUpdateResultAdapter.generatedDiffInputLineLimit / 4
        let manyLines = detail(
            String(repeating: "x\n", count: quarterLines), String(repeating: "y\n", count: quarterLines), line: 20
        )
        cases.append(("aggregate line limit", [manyLines, manyLines], false, [:]))
        let carriageReturns = String(repeating: "\r", count: 8000)
        let loneCRDetail = detail(carriageReturns + "a", carriageReturns + "b", line: Int.max - 800)
        cases.append(("lone CR split-line limit prevents offset overflow", [loneCRDetail], false, [:]))

        for fixture in cases {
            let item: [String: Any] = [
                "type": "diff", "path": "/fixtures/coordinates.txt",
                "oldText": "a", "newText": "b\nc", "_meta": ["details": fixture.details]
            ]
            let events = GrokBuildACPEventNormalizer.normalize([
                "sessionUpdate": "tool_call_update", "toolCallId": "coordinates", "status": "completed", "content": [item],
                "rawOutput": fixture.rawOutput
            ])
            guard case let .stream(result) = events.first else {
                XCTFail("\(fixture.label): expected terminal stream result")
                continue
            }
            let object = try XCTUnwrap(ToolJSON.rawObject(from: result.toolResultJSON), fixture.label)
            let content = try XCTUnwrap(object["content"] as? [[String: Any]], fixture.label)
            let actual = try XCTUnwrap(content.first, fixture.label)
            var originalFields = actual
            originalFields.removeValue(forKey: "unified_diff")
            XCTAssertEqual(originalFields as NSDictionary, item as NSDictionary, "\(fixture.label): preserve original fields")
            if fixture.enriched {
                let diff = try XCTUnwrap(actual["unified_diff"] as? String, fixture.label)
                let document = UnifiedDiffCardRendering.parse(diff)
                XCTAssertEqual(document.lines.filter { $0.kind == .deletion }.compactMap(\.oldLineNumber), [3, 9, 10, 15])
                XCTAssertEqual(document.lines.filter { $0.kind == .addition }.compactMap(\.newLineNumber), [3, 4, 10, 15])
            } else {
                XCTAssertNil(actual["unified_diff"], "\(fixture.label): skip the entire item")
            }
        }
    }

    func testUnknownXAIDiscriminantIsIgnored() {
        let events = GrokBuildACPEventNormalizer.normalize([
            "sessionUpdate": "turn_completed",
            "usage": ["totalTokens": 42]
        ])
        XCTAssertTrue(events.isEmpty)
    }

    func testAvailableCommandsAndPlanAreIgnored() {
        XCTAssertTrue(GrokBuildACPEventNormalizer.normalize([
            "sessionUpdate": "available_commands_update",
            "availableCommands": [["name": "compact"]]
        ]).isEmpty)
        XCTAssertTrue(GrokBuildACPEventNormalizer.normalize([
            "sessionUpdate": "plan",
            "entries": []
        ]).isEmpty)
    }

    func testStandardUsageUpdateStillWorksIfFutureGrokVersionEmitsIt() {
        let events = GrokBuildACPEventNormalizer.normalize([
            "sessionUpdate": "usage_update",
            "used": 1234,
            "size": 500_000
        ])
        guard case let .stream(result) = events.first else {
            return XCTFail("expected usage stream event, got \(events)")
        }
        XCTAssertEqual(result.type, "usage")
        XCTAssertEqual(result.contextUsedTokens, 1234)
    }

    func testNoTerminalEventEverEmittedFromUpdates() {
        let payloads: [[String: Any]] = [
            ["sessionUpdate": "turn_completed", "stop_reason": "end_turn"],
            ["sessionUpdate": "response_completed", "usage": ["totalTokens": 1]],
            ["sessionUpdate": "session_info_update", "title": "done"]
        ]
        for payload in payloads {
            for event in GrokBuildACPEventNormalizer.normalize(payload) {
                if case .terminal = event {
                    XCTFail("normalizer must never emit terminal events (payload: \(payload))")
                }
            }
        }
    }
}
