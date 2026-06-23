import Foundation
import RepoPromptShared
import XCTest

final class MCPControlMessagesTests: XCTestCase {
    func testControlNotificationsRoundTripWireFormats() throws {
        do {
            let caseLabel = "testTerminateNotificationJSONLineRoundTrips"
            let requestedAt = Date(timeIntervalSince1970: 0)
            let notification = RepoPromptControlNotification(
                method: RepoPromptControlMethod.terminate,
                params: RepoPromptTerminateParams(
                    reason: .userBootFromDashboard,
                    message: "Booted from dashboard",
                    requestedAt: requestedAt
                )
            )

            let data = try XCTUnwrap(notification.encodedJSONLine(), caseLabel)
            XCTAssertEqual(data.last, 10, caseLabel + ": encodedJSONLine() must preserve the trailing newline transport delimiter")
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("repoprompt/control/terminate"), caseLabel)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("repoprompt\\/control\\/terminate"), caseLabel)

            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], caseLabel)
            XCTAssertEqual(envelope["jsonrpc"] as? String, "2.0", caseLabel)
            XCTAssertEqual(envelope["method"] as? String, RepoPromptControlMethod.terminate, caseLabel)
            XCTAssertNil(envelope["id"], caseLabel + ": Control messages are JSON-RPC notifications, not requests")

            let parsed = try XCTUnwrap(RepoPromptControlDetection.parseTerminateParams(from: data), caseLabel)
            XCTAssertEqual(parsed.reason, .userBootFromDashboard, caseLabel)
            XCTAssertEqual(parsed.message, "Booted from dashboard", caseLabel)
            XCTAssertEqual(parsed.requestedAt, requestedAt, caseLabel)
        }

        do {
            let caseLabel = "testRunCompletedNotificationJSONLineRoundTrips"
            let completedAt = Date(timeIntervalSince1970: 0)
            let notification = RepoPromptControlNotification(
                method: RepoPromptControlMethod.runCompleted,
                params: RepoPromptRunCompletedParams(
                    runType: "context_builder",
                    success: true,
                    summary: "Done",
                    completedAt: completedAt
                )
            )

            let data = try XCTUnwrap(notification.encodedJSONLine(), caseLabel)
            XCTAssertEqual(data.last, 10, caseLabel)

            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], caseLabel)
            XCTAssertEqual(envelope["jsonrpc"] as? String, "2.0", caseLabel)
            XCTAssertEqual(envelope["method"] as? String, RepoPromptControlMethod.runCompleted, caseLabel)
            XCTAssertNil(envelope["id"], caseLabel)

            let parsed = try XCTUnwrap(RepoPromptControlDetection.parseRunCompletedParams(from: data), caseLabel)
            XCTAssertEqual(parsed.runType, "context_builder", caseLabel)
            XCTAssertTrue(parsed.success, caseLabel)
            XCTAssertEqual(parsed.summary, "Done", caseLabel)
            XCTAssertEqual(parsed.completedAt, completedAt, caseLabel)
        }

        do {
            let caseLabel = "testProgressNotificationJSONLineRoundTripsWithStringDate"
            let emittedAt = Date(timeIntervalSince1970: 0)
            let notification = RepoPromptControlNotification(
                method: RepoPromptControlMethod.progress,
                params: RepoPromptProgressParams(
                    tool: "context_builder",
                    kind: .stage,
                    stage: "planning",
                    message: "Planning response",
                    emittedAt: emittedAt
                )
            )

            let data = try XCTUnwrap(notification.encodedJSONLine(), caseLabel)
            XCTAssertEqual(data.last, 10, caseLabel)

            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], caseLabel)
            XCTAssertEqual(envelope["jsonrpc"] as? String, "2.0", caseLabel)
            XCTAssertEqual(envelope["method"] as? String, RepoPromptControlMethod.progress, caseLabel)
            XCTAssertNil(envelope["id"], caseLabel)
            let params = try XCTUnwrap(envelope["params"] as? [String: Any], caseLabel)
            XCTAssertEqual(params["emittedAt"] as? String, "1970-01-01T00:00:00Z", caseLabel)

            let parsed = try XCTUnwrap(RepoPromptControlDetection.parseProgressParams(from: data), caseLabel)
            XCTAssertEqual(parsed.tool, "context_builder", caseLabel)
            XCTAssertEqual(parsed.kind, .stage, caseLabel)
            XCTAssertEqual(parsed.stage, "planning", caseLabel)
            XCTAssertEqual(parsed.message, "Planning response", caseLabel)
            XCTAssertEqual(parsed.emittedAt, "1970-01-01T00:00:00Z", caseLabel)
        }
    }

    func testKillSignalPayloadPathAndJSONRoundTrip() throws {
        let directory = URL(fileURLWithPath: "/tmp/MCPKillSignals-CE-D-7", isDirectory: true)
        let url = MCPKillSignal.signalFileURL(forSessionToken: "session-token", directory: directory)
        XCTAssertEqual(url.path, "/tmp/MCPKillSignals-CE-D-7/session-token.kill")

        let killedAt = Date(timeIntervalSince1970: 0)
        let content = MCPKillSignal.SignalContent(
            reason: .runCancelled,
            message: "Cancelled by user",
            killedAt: killedAt
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(content)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["reason"] as? String, TerminationReason.runCancelled.rawValue)
        XCTAssertEqual(object["message"] as? String, "Cancelled by user")
        XCTAssertEqual(object["killedAt"] as? String, "1970-01-01T00:00:00Z")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MCPKillSignal.SignalContent.self, from: data)
        XCTAssertEqual(decoded.reason, .runCancelled)
        XCTAssertEqual(decoded.message, "Cancelled by user")
        XCTAssertEqual(decoded.killedAt, killedAt)
    }
}
