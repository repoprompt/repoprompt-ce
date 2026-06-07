import Foundation
@testable import RepoPrompt
import XCTest

final class CodexAppServerDiagnosticsTests: XCTestCase {
    func testTimeoutFailureMessageIncludesMethodAndRequestID() {
        let message = CodexAppServerClient.timeoutFailureMessage(
            method: "thread/start",
            requestID: "42",
            timeout: 120
        )

        XCTAssertTrue(message.contains("120s"), message)
        XCTAssertTrue(message.contains("method: thread/start"), message)
        XCTAssertTrue(message.contains("request id: 42"), message)
        XCTAssertTrue(CodexAppServerClient.isTimeoutError(CodexAppServerClient.ClientError.requestFailed(message)))

        let whitespaceMessage = CodexAppServerClient.timeoutFailureMessage(
            method: "  thread/resume\n",
            requestID: "43",
            timeout: 120
        )
        XCTAssertTrue(whitespaceMessage.contains("method: thread/resume"), whitespaceMessage)
        XCTAssertFalse(whitespaceMessage.contains("method:   thread/resume"), whitespaceMessage)
    }

    func testTimeoutFailureMessageHandlesUnknownMethod() {
        let message = CodexAppServerClient.timeoutFailureMessage(
            method: nil,
            requestID: "abc",
            timeout: 1.5
        )

        XCTAssertTrue(message.contains("1.5s"), message)
        XCTAssertTrue(message.contains("method: <unknown>"), message)
        XCTAssertTrue(message.contains("request id: abc"), message)
    }

    func testJSONRPCPayloadSummaryDoesNotCapturePromptContent() throws {
        let summary = CodexAppServerDiagnostics.jsonRPCPayloadSummary([
            "id": 1,
            "method": "thread/start",
            "params": [
                "baseInstructions": "private instructions",
                "input": [["text": "secret prompt"]]
            ]
        ])

        XCTAssertEqual(summary["method"] as? String, "thread/start")
        let paramsSummary = try XCTUnwrap(summary["params"] as? [String: Any])
        XCTAssertEqual(paramsSummary["type"] as? String, "object")
        XCTAssertEqual(paramsSummary["keyCount"] as? Int, 2)
        XCTAssertFalse(String(describing: summary).contains("private instructions"))
        XCTAssertFalse(String(describing: summary).contains("secret prompt"))
    }

    func testDiagnosticsSanitizerRedactsSensitiveKeysAndKeepsShape() throws {
        let sanitized = try XCTUnwrap(CodexAppServerDiagnostics.sanitizedJSONObject([
            "method": "thread/start",
            "accessToken": "secret-token",
            "nested": [
                "api_key": "secret-key",
                "cwd": "/tmp/workspace"
            ]
        ]) as? [String: Any])

        XCTAssertEqual(sanitized["method"] as? String, "thread/start")
        XCTAssertEqual(sanitized["accessToken"] as? String, "<redacted>")
        let nested = try XCTUnwrap(sanitized["nested"] as? [String: Any])
        XCTAssertEqual(nested["api_key"] as? String, "<redacted>")
        XCTAssertEqual(nested["cwd"] as? String, "/tmp/workspace")
    }
}
