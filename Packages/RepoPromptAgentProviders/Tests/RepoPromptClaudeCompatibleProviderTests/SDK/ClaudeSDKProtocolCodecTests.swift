import Foundation
@testable import RepoPromptClaudeCompatibleProvider
import XCTest

final class ClaudeSDKProtocolCodecTests: XCTestCase {
    func testActualControlDecoderPreservesNumericLimitsAndBooleanTypes() throws {
        let cases: [(literal: String, expected: ClaudeProviderJSONValue)] = [
            ("0", .integer(0)), ("1", .integer(1)), ("2", .integer(2)),
            ("5", .integer(5)), ("50", .integer(50)), ("500", .integer(500)),
            ("501", .integer(501)), ("-1", .integer(-1)), ("1.5", .double(1.5)),
            ("9007199254740993", .integer(9_007_199_254_740_993)),
            ("true", .bool(true)), ("false", .bool(false)), ("\"1\"", .string("1"))
        ]
        for (literal, expected) in cases {
            // Enter through the production JSONSerialization -> init(any:) codec seam,
            // not Codable decoding or a manually constructed provider value.
            let line = Data("{\"type\":\"control_request\",\"request_id\":\"numeric-input\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"mcp__RepoPrompt__session_admin\",\"input\":{\"op\":\"request_scope\",\"guardrails\":{\"max_live_sessions\":\(literal)}}}}".utf8)
            guard case let .controlRequest(request)? = try ClaudeSDKProtocolCodec.decodeLine(line) else {
                return XCTFail("Expected actual control request for \(literal)")
            }
            XCTAssertEqual(request.request["input"]?.objectValue?["guardrails"]?.objectValue?["max_live_sessions"], expected, "literal=\(literal)")
        }
    }

    func testActualAssistantToolInputDecoderKeepsNestedNumbersDistinctFromBooleans() throws {
        let line = Data(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-1","name":"session_admin","input":{"op":"inventory","limit":1,"values":[0,1,2,1.5,true,false,9007199254740993]}}]}}"#.utf8)
        guard case let .streamPayload(payload)? = try ClaudeSDKProtocolCodec.decodeLine(line) else {
            return XCTFail("Expected actual assistant stream payload")
        }
        let content = try XCTUnwrap(payload["message"]?.objectValue?["content"]?.arrayValue?.first?.objectValue)
        let input = try XCTUnwrap(content["input"]?.objectValue)
        XCTAssertEqual(input["limit"], .integer(1))
        XCTAssertEqual(input["values"], .array([
            .integer(0), .integer(1), .integer(2), .double(1.5),
            .bool(true), .bool(false), .integer(9_007_199_254_740_993)
        ]))
        // The Any bridge must retain its existing rejection of non-JSON numeric values.
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(try ClaudeProviderJSONValue(any: value))
        }
    }

    func testProtocolCodecSmokeDecodesControlRepairsControlCharactersAndEncodesUserMessage() throws {
        let controlLine = Data(#"{"type":"control_request","request_id":"req-1","request":{"subtype":"permission","tool_name":"read_file","input":{"path":"Sources/App.swift"}}}"#.utf8)

        let controlMessage = try ClaudeSDKProtocolCodec.decodeLine(controlLine)

        guard case let .controlRequest(request) = controlMessage else {
            XCTFail("Expected control request")
            return
        }
        XCTAssertEqual(request.requestID, "req-1")
        XCTAssertEqual(request.subtype, "permission")
        XCTAssertEqual(request.request["tool_name"], .string("read_file"))
        XCTAssertEqual(request.request["input"]?.objectValue?["path"], .string("Sources/App.swift"))

        let rawControlCharacterLine = Data("{\"type\":\"assistant\",\"message\":{\"content\":\"hello\nworld\"}}".utf8)
        let streamMessage = try ClaudeSDKProtocolCodec.decodeLine(rawControlCharacterLine)
        guard case let .streamPayload(payload) = streamMessage else {
            XCTFail("Expected stream payload")
            return
        }
        XCTAssertEqual(payload["type"], .string("assistant"))
        XCTAssertEqual(payload["message"]?.objectValue?["content"], .string("hello\nworld"))

        let userData = try ClaudeSDKProtocolCodec.encodeUserMessage(text: "Continue", sessionID: "session-1")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: userData) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "user")
        XCTAssertEqual(object["session_id"] as? String, "session-1")
        XCTAssertTrue(object["parent_tool_use_id"] is NSNull)
        let message = try XCTUnwrap(object["message"] as? [String: Any])
        XCTAssertEqual(message["role"] as? String, "user")
    }
}
