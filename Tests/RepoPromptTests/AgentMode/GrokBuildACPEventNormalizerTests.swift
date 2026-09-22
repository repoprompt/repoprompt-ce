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
