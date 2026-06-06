import Foundation
import RepoPromptShared
import XCTest

final class MCPControlMessagesTests: XCTestCase {
    func testTerminateNotificationJSONLineRoundTrips() throws {
        let requestedAt = Date(timeIntervalSince1970: 0)
        let notification = RepoPromptControlNotification(
            method: RepoPromptControlMethod.terminate,
            params: RepoPromptTerminateParams(
                reason: .userBootFromDashboard,
                message: "Booted from dashboard",
                requestedAt: requestedAt
            )
        )

        let data = try XCTUnwrap(notification.encodedJSONLine())
        XCTAssertEqual(data.last, 10, "encodedJSONLine() must preserve the trailing newline transport delimiter")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("repoprompt/control/terminate"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("repoprompt\\/control\\/terminate"))

        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(envelope["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(envelope["method"] as? String, RepoPromptControlMethod.terminate)
        XCTAssertNil(envelope["id"], "Control messages are JSON-RPC notifications, not requests")

        let parsed = try XCTUnwrap(RepoPromptControlDetection.parseTerminateParams(from: data))
        XCTAssertEqual(parsed.reason, .userBootFromDashboard)
        XCTAssertEqual(parsed.message, "Booted from dashboard")
        XCTAssertEqual(parsed.requestedAt, requestedAt)
    }

    func testRunCompletedNotificationJSONLineRoundTrips() throws {
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

        let data = try XCTUnwrap(notification.encodedJSONLine())
        XCTAssertEqual(data.last, 10)

        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(envelope["method"] as? String, RepoPromptControlMethod.runCompleted)
        XCTAssertNil(envelope["id"])

        let parsed = try XCTUnwrap(RepoPromptControlDetection.parseRunCompletedParams(from: data))
        XCTAssertEqual(parsed.runType, "context_builder")
        XCTAssertTrue(parsed.success)
        XCTAssertEqual(parsed.summary, "Done")
        XCTAssertEqual(parsed.completedAt, completedAt)
    }

    func testProgressNotificationJSONLineRoundTripsWithStringDate() throws {
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

        let data = try XCTUnwrap(notification.encodedJSONLine())
        XCTAssertEqual(data.last, 10)

        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(envelope["method"] as? String, RepoPromptControlMethod.progress)
        XCTAssertNil(envelope["id"])
        let params = try XCTUnwrap(envelope["params"] as? [String: Any])
        XCTAssertEqual(params["emittedAt"] as? String, "1970-01-01T00:00:00Z")

        let parsed = try XCTUnwrap(RepoPromptControlDetection.parseProgressParams(from: data))
        XCTAssertEqual(parsed.tool, "context_builder")
        XCTAssertEqual(parsed.kind, .stage)
        XCTAssertEqual(parsed.stage, "planning")
        XCTAssertEqual(parsed.message, "Planning response")
        XCTAssertEqual(parsed.emittedAt, "1970-01-01T00:00:00Z")
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
