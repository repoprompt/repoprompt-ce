import Foundation
@testable import RepoPromptApp
import XCTest

final class DevinACPAgentProviderToolMetadataTests: XCTestCase {
    private let provider = DevinACPAgentProvider(config: DevinAgentConfig(includeRepoPromptMCPServer: false))
    private let canonicalName = "mcp__RepoPromptCE__read_file"
    private let callID = "synthetic-devin-read"

    /// Minimal metadata/title/status shapes from installed Devin 3000.6.14 captures.
    /// IDs, arguments and content below are synthetic; no private session/prompt data.
    func testCapturedInitialToolMetadataPreservesCanonicalNameAndArguments() throws {
        let payload: [String: Any] = [
            "sessionUpdate": "tool_call", "toolCallId": callID,
            "title": "Calling read_file from RepoPromptCE",
            "rawInput": ["path": "fixture.txt"],
            "_meta": [
                "cognition.ai/eventType": "mcp_tool_call",
                "cognition.ai/toolName": canonicalName,
                "cognition.ai/inferenceToolName": canonicalName
            ]
        ]
        let result = try normalize(payload)
        XCTAssertEqual(result.type, "tool_call")
        XCTAssertEqual(result.toolName, canonicalName)
        XCTAssertEqual(result.toolInvocationID, ACPRuntimeEventParsing.stableInvocationUUID(rawValue: callID))
        XCTAssertEqual(try jsonObject(result.toolArgsJSON), ["path": "fixture.txt"] as NSDictionary)
        XCTAssertEqual(result.toolArgs, result.toolArgsJSON)
        XCTAssertNil(result.toolResultJSON)
    }

    func testCapturedTitlelessUpdatesKeepCanonicalNameStatusErrorsAndContent() throws {
        for status in ["in_progress", "completed", "failed"] {
            let payload: [String: Any] = [
                "sessionUpdate": "tool_call_update", "toolCallId": callID, "status": status,
                "rawInput": ["path": "fixture.txt"],
                "content": [["type": "content", "content": ["type": "text", "text": "synthetic result"]]],
                "_meta": ["cognition.ai/inferenceToolName": canonicalName]
            ]
            let result = try normalize(payload)
            let baseline = try stream(ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: .devin))
            XCTAssertEqual(result.toolName, canonicalName, status)
            XCTAssertEqual(result.type, "tool_result")
            XCTAssertEqual(result.toolInvocationID, ACPRuntimeEventParsing.stableInvocationUUID(rawValue: callID))
            XCTAssertEqual(result.toolIsError, status == "failed")
            XCTAssertEqual(try jsonObject(result.toolArgsJSON), try jsonObject(baseline.toolArgsJSON))
            XCTAssertEqual(try jsonObject(result.toolResultJSON), try jsonObject(baseline.toolResultJSON))
            XCTAssertEqual(result.toolOutput, result.toolResultJSON)
            if status == "in_progress" {
                XCTAssertEqual(try (jsonObject(result.toolResultJSON) as? NSDictionary)?["status"] as? String, "running")
            }
        }
    }

    func testLoadedCanonicalToolNameWinsButGenericOnlyReplayDoesNotInventIdentity() throws {
        let initial: [String: Any] = [
            "sessionUpdate": "tool_call", "toolCallId": callID,
            "title": "Calling read_file from RepoPromptCE",
            "_meta": ["cognition.ai/toolName": canonicalName, "cognition.ai/inferenceToolName": "mcp_call_tool"]
        ]
        let loaded = try normalize(initial)
        XCTAssertEqual(loaded.toolName, canonicalName)
        // Recorded replay updates carry only the generic dispatcher. Stateless projection
        // must not pretend it can reconstruct the omitted canonical name from that field.
        for status in ["completed", "failed"] {
            let partial: [String: Any] = [
                "sessionUpdate": "tool_call_update", "toolCallId": callID, "status": status,
                "_meta": ["cognition.ai/inferenceToolName": "mcp_call_tool"]
            ]
            let result = try normalize(partial)
            XCTAssertEqual(result.toolName, "tool")
            XCTAssertEqual(result.toolInvocationID, loaded.toolInvocationID)
            XCTAssertEqual(result.toolIsError, status == "failed")
        }
    }

    func testMetadataFreeAndMalformedMetadataRetainExistingFallback() throws {
        let metadata: [Any] = [
            NSNull(), "not-an-object", [:] as [String: Any],
            ["cognition.ai/toolName": " ", "cognition.ai/inferenceToolName": 42],
            ["cognition.ai/toolName": "not a machine name", "cognition.ai/inferenceToolName": "mcp_call_tool"]
        ]
        for meta in metadata {
            for title in [nil, "Calling read_file from RepoPromptCE"] as [String?] {
                var payload: [String: Any] = ["sessionUpdate": "tool_call_update", "toolCallId": callID, "status": "failed"]
                payload["title"] = title
                let expected = try normalize(payload)
                payload["_meta"] = meta
                let result = try normalize(payload)
                XCTAssertEqual(result.toolName, title ?? "tool")
                XCTAssertEqual(result.toolName, expected.toolName)
                XCTAssertEqual(result.toolInvocationID, expected.toolInvocationID)
                XCTAssertEqual(result.toolIsError, expected.toolIsError)
            }
        }
    }

    func testCapturedNativeInferenceNamesUseExistingMachineIdentifierParsing() throws {
        for name in ["read", "mcp_list_tools"] {
            let result = try normalize([
                "sessionUpdate": "tool_call_update", "toolCallId": callID, "status": "in_progress",
                "_meta": ["cognition.ai/inferenceToolName": "  \(name)  "]
            ])
            XCTAssertEqual(result.toolName, name)
        }
    }

    func testNonToolUpdatesAndOMPDoNotAdoptDevinMetadata() throws {
        let message: [String: Any] = [
            "sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "synthetic greeting"],
            "_meta": ["cognition.ai/toolName": canonicalName]
        ]
        let result = try normalize(message)
        XCTAssertEqual(result.type, "content")
        XCTAssertEqual(result.text, "synthetic greeting")
        XCTAssertNil(result.toolName)
        let omp = OMPACPAgentProvider(config: OMPAgentConfig())
        let events = omp.normalizeSessionUpdate([
            "sessionUpdate": "tool_call", "toolCallId": callID, "title": "Calling read_file from RepoPromptCE",
            "_meta": ["cognition.ai/toolName": canonicalName]
        ], sessionID: "synthetic-session")
        XCTAssertEqual(try stream(events).toolName, "Calling read_file from RepoPromptCE")
    }

    private func normalize(_ payload: [String: Any]) throws -> AIStreamResult {
        try stream(provider.normalizeSessionUpdate(payload, sessionID: "synthetic-session"))
    }

    private func stream(_ events: [NormalizedAgentRuntimeEvent]) throws -> AIStreamResult {
        XCTAssertEqual(events.count, 1)
        guard case let .stream(result) = try XCTUnwrap(events.first) else {
            throw NSError(domain: "ExpectedStreamEvent", code: 1)
        }
        return result
    }

    private func jsonObject(_ text: String?) throws -> NSObject {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(text).utf8)) as? NSObject)
    }
}
