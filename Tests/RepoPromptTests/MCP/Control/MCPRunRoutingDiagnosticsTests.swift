import Foundation
import MCP
@testable import RepoPrompt
import XCTest

final class MCPRunRoutingDiagnosticsTests: XCTestCase {
    private let manager = ServerNetworkManager.shared

    func testRunRoutingHistoryFiltersByRunAndRedactsSensitiveFields() async throws {
        #if DEBUG
            let firstRunID = UUID()
            let secondRunID = UUID()
            let connectionID = UUID()
            await manager.debugClearRunRoutingHistoryForTesting()

            await manager.debugRecordRunRoutingEvent(
                runID: firstRunID,
                event: "policy_installed",
                connectionID: connectionID,
                fields: [
                    "client_name": "opencode",
                    "session_token": "must-not-leak",
                    "auth_header": "Bearer must-not-leak",
                    "prompt_payload": "private prompt",
                    "error": "token=must-not-leak",
                    "safe_args": "OPENAI_API_KEY=<redacted> --header <redacted>",
                    "unsafe_args": "OPENAI_API_KEY=must-not-leak",
                    "pending_policy_key": "opencode",
                    "bounded": String(repeating: "x", count: 900)
                ]
            )
            await manager.debugRecordRunRoutingEvent(
                runID: secondRunID,
                event: "other_run_event",
                fields: ["client_name": "opencode"]
            )
            await manager.debugRecordRunRoutingEvent(
                runID: firstRunID,
                event: "policy_applied",
                connectionID: connectionID,
                fields: ["expected_pids": "123,456"]
            )

            let payload = await manager.debugRunRoutingHistoryPayload(runID: firstRunID, limit: 20)
            let events = try XCTUnwrap(payload["events"] as? [[String: Any]])
            XCTAssertEqual(events.map { $0["event"] as? String }, ["policy_installed", "policy_applied"])
            XCTAssertTrue(events.allSatisfy { $0["run_id"] as? String == firstRunID.uuidString })
            XCTAssertFalse(events.contains { $0["event"] as? String == "other_run_event" })

            let fields = try XCTUnwrap(events.first?["fields"] as? [String: String])
            XCTAssertEqual(fields["session_token"], "<redacted>")
            XCTAssertEqual(fields["auth_header"], "<redacted>")
            XCTAssertEqual(fields["prompt_payload"], "<redacted>")
            XCTAssertEqual(fields["error"], "<redacted>")
            XCTAssertEqual(fields["safe_args"], "OPENAI_API_KEY=<redacted> --header <redacted>")
            XCTAssertEqual(fields["unsafe_args"], "<redacted>")
            XCTAssertEqual(fields["client_name"], "opencode")
            XCTAssertEqual(fields["pending_policy_key"], "opencode")
            XCTAssertEqual(fields["bounded"]?.count, 512)
            XCTAssertFalse(String(describing: payload).contains("must-not-leak"))
            XCTAssertFalse(String(describing: payload).contains("private prompt"))
        #else
            throw XCTSkip("Run routing history is DEBUG-only.")
        #endif
    }

    func testRunRoutingHistoryBoundsFieldCountAndValueLength() async throws {
        #if DEBUG
            let runID = UUID()
            await manager.debugClearRunRoutingHistoryForTesting()
            let fields = Dictionary(uniqueKeysWithValues: (0 ..< 40).map { index in
                (String(format: "field_%02d", index), String(repeating: "v", count: 900))
            })

            await manager.debugRecordRunRoutingEvent(
                runID: runID,
                event: String(repeating: "e", count: 200),
                fields: fields
            )

            let payload = await manager.debugRunRoutingHistoryPayload(runID: runID, limit: 1)
            let events = try XCTUnwrap(payload["events"] as? [[String: Any]])
            let event = try XCTUnwrap(events.first)
            let boundedFields = try XCTUnwrap(event["fields"] as? [String: String])
            XCTAssertEqual((event["event"] as? String)?.count, 96)
            XCTAssertEqual(boundedFields.count, 32)
            XCTAssertTrue(boundedFields.values.allSatisfy { $0.count == 512 })
            XCTAssertNotNil(boundedFields["field_00"])
            XCTAssertNil(boundedFields["field_39"])
        #else
            throw XCTSkip("Run routing history is DEBUG-only.")
        #endif
    }

    func testRunRoutingHistoryIsBoundedAndReportsDroppedEvents() async throws {
        #if DEBUG
            let runID = UUID()
            await manager.debugClearRunRoutingHistoryForTesting()

            for index in 0 ..< 1005 {
                await manager.debugRecordRunRoutingEvent(
                    runID: runID,
                    event: "event_\(index)"
                )
            }

            let payload = await manager.debugRunRoutingHistoryPayload(runID: runID, limit: 500)
            let events = try XCTUnwrap(payload["events"] as? [[String: Any]])
            XCTAssertEqual(payload["history_capacity"] as? Int, 1000)
            XCTAssertEqual(payload["dropped_event_count"] as? Int, 5)
            XCTAssertEqual(events.count, 500)
            XCTAssertEqual(events.first?["event"] as? String, "event_505")
            XCTAssertEqual(events.last?["event"] as? String, "event_1004")
        #else
            throw XCTSkip("Run routing history is DEBUG-only.")
        #endif
    }

    func testRoutingWaiterRecordsOnlyAcceptedTerminalSignal() async throws {
        #if DEBUG
            let runID = UUID()
            await manager.debugClearRunRoutingHistoryForTesting()
            await MCPRoutingWaiter.cleanup(runID: runID)
            await MCPRoutingWaiter.register(runID: runID)
            let waitTask = Task {
                await MCPRoutingWaiter.waitUntilRouted(runID: runID, timeoutSeconds: 1)
            }

            await MCPRoutingWaiter.notifyRouted(runID: runID)
            await MCPRoutingWaiter.notifyRouted(runID: runID)
            await MCPRoutingWaiter.notifyFailed(runID: runID)

            let routed = await waitTask.value
            XCTAssertTrue(routed)
            let payload = await manager.debugRunRoutingHistoryPayload(runID: runID, limit: 20)
            let events = try XCTUnwrap(payload["events"] as? [[String: Any]])
            let signals = events.filter { $0["event"] as? String == "routing_waiter_signalled" }
            XCTAssertEqual(signals.count, 1)
            let fields = try XCTUnwrap(signals.first?["fields"] as? [String: String])
            XCTAssertEqual(fields["outcome"], "routed")
            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Run routing history is DEBUG-only.")
        #endif
    }

    func testRoutingWaiterTimeoutIsPerWaiterAndDoesNotResolveRun() async throws {
        #if DEBUG
            let runID = UUID()
            await MCPRoutingWaiter.cleanup(runID: runID)
            await MCPRoutingWaiter.register(runID: runID)

            let shortWaiter = Task {
                await MCPRoutingWaiter.waitUntilRouted(runID: runID, timeoutSeconds: 0.01)
            }
            let longWaiter = Task {
                await MCPRoutingWaiter.waitUntilRouted(runID: runID, timeoutSeconds: 5)
            }
            var continuationCount = 0
            for _ in 0 ..< 100 {
                continuationCount = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
                if continuationCount == 2 { break }
                await Task.yield()
            }
            XCTAssertEqual(continuationCount, 2)

            let shortResult = await shortWaiter.value
            let remainingWaiterCount = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            XCTAssertFalse(shortResult)
            XCTAssertEqual(remainingWaiterCount, 1)

            await MCPRoutingWaiter.notifyRouted(runID: runID)
            let longResult = await longWaiter.value
            XCTAssertTrue(longResult)
            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Routing waiter continuation inspection is DEBUG-only.")
        #endif
    }

    func testRoutingWaiterCleanupResumesUnresolvedWaitersAsFailure() async throws {
        #if DEBUG
            let runID = UUID()
            await MCPRoutingWaiter.cleanup(runID: runID)
            await MCPRoutingWaiter.register(runID: runID)
            let firstWaiter = Task {
                await MCPRoutingWaiter.waitUntilRouted(runID: runID, timeoutSeconds: 5)
            }
            let secondWaiter = Task {
                await MCPRoutingWaiter.waitUntilRouted(runID: runID, timeoutSeconds: 5)
            }
            var continuationCount = 0
            for _ in 0 ..< 100 {
                continuationCount = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
                if continuationCount == 2 { break }
                await Task.yield()
            }
            XCTAssertEqual(continuationCount, 2)

            await MCPRoutingWaiter.cleanup(runID: runID)

            let firstResult = await firstWaiter.value
            let secondResult = await secondWaiter.value
            XCTAssertFalse(firstResult)
            XCTAssertFalse(secondResult)
        #else
            throw XCTSkip("Routing waiter continuation inspection is DEBUG-only.")
        #endif
    }

    func testRunRoutingHistoryToolRequiresRunIDAndBoundsLimit() async throws {
        #if DEBUG
            let missingRun = await manager.debugRunRoutingHistoryToolPayload(
                op: "run_routing_history",
                arguments: [:]
            )
            let missingPayload = try diagnosticsPayload(missingRun)
            XCTAssertEqual(missingPayload["ok"] as? Bool, false)
            XCTAssertEqual(missingPayload["code"] as? String, "invalid_params")

            let invalidLimit = await manager.debugRunRoutingHistoryToolPayload(
                op: "run_routing_history",
                arguments: [
                    "run_id": .string(UUID().uuidString),
                    "limit": .int(501)
                ]
            )
            let limitPayload = try diagnosticsPayload(invalidLimit)
            XCTAssertEqual(limitPayload["ok"] as? Bool, false)
            XCTAssertEqual(limitPayload["code"] as? String, "invalid_params")
        #else
            throw XCTSkip("Run routing history is DEBUG-only.")
        #endif
    }

    func testRunRoutingHistoryLimitReturnsNewestMatchingEventsInSequenceOrder() async throws {
        #if DEBUG
            let runID = UUID()
            await manager.debugClearRunRoutingHistoryForTesting()

            for event in ["routing_waiter_registered", "policy_installed", "pid_gate_wait_started", "expected_pid_registered", "policy_applied"] {
                await manager.debugRecordRunRoutingEvent(runID: runID, event: event)
            }

            let payload = await manager.debugRunRoutingHistoryPayload(runID: runID, limit: 3)
            let events = try XCTUnwrap(payload["events"] as? [[String: Any]])
            XCTAssertEqual(
                events.map { $0["event"] as? String },
                ["pid_gate_wait_started", "expected_pid_registered", "policy_applied"]
            )
            let sequences = events.compactMap { $0["seq"] as? Int }
            XCTAssertEqual(sequences, sequences.sorted())
        #else
            throw XCTSkip("Run routing history is DEBUG-only.")
        #endif
    }

    #if DEBUG
        private func diagnosticsPayload(_ result: CallTool.Result) throws -> [String: Any] {
            let text = result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content { return text }
                return nil
            }.joined()
            let data = try XCTUnwrap(text.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    #endif
}
