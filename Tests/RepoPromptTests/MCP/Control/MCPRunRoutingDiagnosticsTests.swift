import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

final class MCPRunRoutingDiagnosticsTests: XCTestCase {
    private let manager = ServerNetworkManager.shared

    func testRunRoutingHistoryFiltersByRunAndRedactsSensitiveFields() async throws {
        #if DEBUG
            let firstRunID = UUID()
            let secondRunID = UUID()
            let connectionID = UUID()
            let secondConnectionID = UUID()
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
                connectionID: secondConnectionID,
                fields: [
                    "client_name": "opencode",
                    "prompt_payload": "another private prompt"
                ]
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

            let recentPayload = await manager.debugRunRoutingHistoryPayload(runID: nil, limit: 2)
            let recentEvents = try XCTUnwrap(recentPayload["events"] as? [[String: Any]])
            XCTAssertTrue(recentPayload["run_id"] is NSNull)
            XCTAssertEqual(recentPayload["history_capacity"] as? Int, 1000)
            XCTAssertEqual(recentPayload["dropped_event_count"] as? Int, 0)
            XCTAssertEqual(recentEvents.map { $0["event"] as? String }, ["other_run_event", "policy_applied"])
            XCTAssertEqual(
                recentEvents.map { $0["run_id"] as? String },
                [secondRunID.uuidString, firstRunID.uuidString]
            )
            XCTAssertEqual(
                recentEvents.map { $0["connection_id"] as? String },
                [secondConnectionID.uuidString, connectionID.uuidString]
            )
            XCTAssertEqual(
                (recentEvents.first?["fields"] as? [String: String])?["prompt_payload"],
                "<redacted>"
            )
            let recentSequences = recentEvents.compactMap { $0["seq"] as? Int }
            XCTAssertEqual(recentSequences, recentSequences.sorted())
            XCTAssertFalse(String(describing: recentPayload).contains("another private prompt"))
        #else
            throw XCTSkip("Run routing history is DEBUG-only.")
        #endif
    }

    func testRunRoutingHistoryBoundsFieldsValuesCapacityAndLimitOrdering() async throws {
        #if DEBUG
            do {
                let caseLabel = "testRunRoutingHistoryBoundsFieldCountAndValueLength"
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
                let events = try XCTUnwrap(payload["events"] as? [[String: Any]], caseLabel)
                let event = try XCTUnwrap(events.first, caseLabel)
                let boundedFields = try XCTUnwrap(event["fields"] as? [String: String], caseLabel)
                XCTAssertEqual((event["event"] as? String)?.count, 96, caseLabel)
                XCTAssertEqual(boundedFields.count, 32, caseLabel)
                XCTAssertTrue(boundedFields.values.allSatisfy { $0.count == 512 }, caseLabel)
                XCTAssertNotNil(boundedFields["field_00"], caseLabel)
                XCTAssertNil(boundedFields["field_39"], caseLabel)
            }

            do {
                let caseLabel = "testRunRoutingHistoryIsBoundedAndReportsDroppedEvents"
                let runID = UUID()
                await manager.debugClearRunRoutingHistoryForTesting()

                for index in 0 ..< 1005 {
                    await manager.debugRecordRunRoutingEvent(
                        runID: runID,
                        event: "event_\(index)"
                    )
                }

                let payload = await manager.debugRunRoutingHistoryPayload(runID: runID, limit: 500)
                let events = try XCTUnwrap(payload["events"] as? [[String: Any]], caseLabel)
                XCTAssertEqual(payload["history_capacity"] as? Int, 1000, caseLabel)
                XCTAssertEqual(payload["dropped_event_count"] as? Int, 5, caseLabel)
                XCTAssertEqual(events.count, 500, caseLabel)
                XCTAssertEqual(events.first?["event"] as? String, "event_505", caseLabel)
                XCTAssertEqual(events.last?["event"] as? String, "event_1004", caseLabel)
            }

            do {
                let caseLabel = "testRunRoutingHistoryLimitReturnsNewestMatchingEventsInSequenceOrder"
                let runID = UUID()
                await manager.debugClearRunRoutingHistoryForTesting()

                for event in ["routing_waiter_registered", "policy_installed", "pid_gate_wait_started", "expected_pid_registered", "policy_applied"] {
                    await manager.debugRecordRunRoutingEvent(runID: runID, event: event)
                }

                let payload = await manager.debugRunRoutingHistoryPayload(runID: runID, limit: 3)
                let events = try XCTUnwrap(payload["events"] as? [[String: Any]], caseLabel)
                XCTAssertEqual(
                    events.map { $0["event"] as? String },
                    ["pid_gate_wait_started", "expected_pid_registered", "policy_applied"],
                    caseLabel
                )
                let sequences = events.compactMap { $0["seq"] as? Int }
                XCTAssertEqual(sequences, sequences.sorted(), caseLabel)
            }
        #else
            throw XCTSkip("Run routing history is DEBUG-only: testRunRoutingHistoryBoundsFieldCountAndValueLength, testRunRoutingHistoryIsBoundedAndReportsDroppedEvents, testRunRoutingHistoryLimitReturnsNewestMatchingEventsInSequenceOrder")
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
                if continuationCount == 2 {
                    break
                }
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
                if continuationCount == 2 {
                    break
                }
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

    func testRunRoutingHistoryToolAllowsOmittedRunIDAndBoundsLimit() async throws {
        #if DEBUG
            let firstRunID = UUID()
            let secondRunID = UUID()
            await manager.debugClearRunRoutingHistoryForTesting()
            await manager.debugRecordRunRoutingEvent(runID: firstRunID, event: "first")
            await manager.debugRecordRunRoutingEvent(runID: secondRunID, event: "second")

            let recentRun = await manager.debugRunRoutingHistoryToolPayload(
                op: "run_routing_history",
                arguments: ["limit": .int(1)]
            )
            let recentPayload = try diagnosticsPayload(recentRun)
            let recentEvents = try XCTUnwrap(recentPayload["events"] as? [[String: Any]])
            XCTAssertEqual(recentPayload["ok"] as? Bool, true)
            XCTAssertTrue(recentPayload["run_id"] is NSNull)
            XCTAssertEqual(recentEvents.count, 1)
            XCTAssertEqual(recentEvents.first?["run_id"] as? String, secondRunID.uuidString)

            let filteredRun = await manager.debugRunRoutingHistoryToolPayload(
                op: "run_routing_history",
                arguments: ["run_id": .string(firstRunID.uuidString)]
            )
            let filteredPayload = try diagnosticsPayload(filteredRun)
            let filteredEvents = try XCTUnwrap(filteredPayload["events"] as? [[String: Any]])
            XCTAssertEqual(filteredPayload["run_id"] as? String, firstRunID.uuidString)
            XCTAssertEqual(filteredEvents.map { $0["event"] as? String }, ["first"])

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

    #if DEBUG
        private func diagnosticsPayload(_ result: CallTool.Result) throws -> [String: Any] {
            let text = result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content {
                    return text
                }
                return nil
            }.joined()
            let data = try XCTUnwrap(text.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    #endif
}
