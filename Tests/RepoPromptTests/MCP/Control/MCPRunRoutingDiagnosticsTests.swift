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

    func testAdaptiveRoutingDistinguishesBothDeadlinePhasesAndDoesNotRefreshGrace() async {
        let beforeClock = MCPRoutingWaitManualClock()
        let beforeWaiter = MCPRoutingWaiter(clock: beforeClock.routingClock)
        let beforeRunID = UUID()
        await beforeWaiter.register(runID: beforeRunID)
        let beforeTask = Task {
            await beforeWaiter.waitForRoutingOutcome(
                runID: beforeRunID,
                policy: MCPRoutingWaitPolicy(
                    noConnectionTimeout: .milliseconds(100),
                    observedConnectionGrace: .milliseconds(200)
                )
            )
        }
        await beforeClock.waitUntilSleeping(deadline: .milliseconds(100))
        beforeClock.advance(by: .milliseconds(100))
        let beforeOutcome = await beforeTask.value
        XCTAssertEqual(beforeOutcome, .timedOutBeforeConnection)
        await beforeWaiter.cleanup(runID: beforeRunID)

        let afterClock = MCPRoutingWaitManualClock()
        let afterWaiter = MCPRoutingWaiter(clock: afterClock.routingClock)
        let afterRunID = UUID()
        await afterWaiter.register(runID: afterRunID)
        let afterTask = Task {
            await afterWaiter.waitForRoutingOutcome(
                runID: afterRunID,
                policy: MCPRoutingWaitPolicy(
                    noConnectionTimeout: .milliseconds(100),
                    observedConnectionGrace: .milliseconds(200)
                )
            )
        }
        await afterClock.waitUntilSleeping(deadline: .milliseconds(100))
        afterClock.advance(by: .milliseconds(10))
        let observedConnection = await afterWaiter.notifyConnectionObserved(runID: afterRunID)
        XCTAssertTrue(observedConnection)
        await afterClock.waitUntilSleeping(deadline: .milliseconds(210))
        let graceDeadlines = afterClock.activeDeadlines()
        let observedConnectionAgain = await afterWaiter.notifyConnectionObserved(runID: afterRunID)
        XCTAssertFalse(observedConnectionAgain)
        XCTAssertEqual(afterClock.activeDeadlines(), graceDeadlines)

        afterClock.advance(by: .milliseconds(200))
        let afterOutcome = await afterTask.value
        XCTAssertEqual(afterOutcome, .timedOutAfterConnection)
        await afterWaiter.cleanup(runID: afterRunID)
    }

    func testAdaptiveRoutingCanCommitDuringObservedGrace() async {
        let clock = MCPRoutingWaitManualClock()
        let enrollmentGate = MCPRoutingWaitEnrollmentGate()
        let waiter = MCPRoutingWaiter(
            clock: clock.routingClock,
            beforeWaiterEnrollment: {
                await enrollmentGate.block()
            }
        )
        let runID = UUID()
        await waiter.register(runID: runID)
        let waitTask = Task {
            await waiter.waitForRoutingOutcome(
                runID: runID,
                policy: MCPRoutingWaitPolicy(
                    noConnectionTimeout: .milliseconds(100),
                    observedConnectionGrace: .milliseconds(200)
                )
            )
        }

        await enrollmentGate.waitUntilBlocked()
        clock.advance(by: .milliseconds(40))
        let observedConnection = await waiter.notifyConnectionObserved(runID: runID)
        XCTAssertTrue(observedConnection)
        await enrollmentGate.release()
        await clock.waitUntilSleeping(deadline: .milliseconds(240))
        await waiter.notifyRouted(runID: runID)

        let outcome = await waitTask.value
        XCTAssertEqual(outcome, .routed)
        await waiter.cleanup(runID: runID)
    }

    func testLegacyAbsoluteWaitIgnoresObservationAndClassifiesStickyObservation() async {
        let clock = MCPRoutingWaitManualClock()
        let waiter = MCPRoutingWaiter(clock: clock.routingClock)
        let runID = UUID()
        await waiter.register(runID: runID)
        let waitTask = Task {
            await waiter.waitForRoutingOutcome(runID: runID, timeoutSeconds: 0.1)
        }
        await clock.waitUntilSleeping(deadline: .milliseconds(100))
        clock.advance(by: .milliseconds(20))
        let observedConnection = await waiter.notifyConnectionObserved(runID: runID)
        XCTAssertTrue(observedConnection)
        XCTAssertEqual(clock.activeDeadlines(), [.milliseconds(100)])

        clock.advance(by: .milliseconds(80))
        let outcome = await waitTask.value
        XCTAssertEqual(outcome, .timedOutAfterConnection)
        await waiter.cleanup(runID: runID)
    }

    func testLegacyNonpositiveTimeoutWaitsIndefinitelyUntilCancellationOrRouting() async throws {
        #if DEBUG
            let clock = MCPRoutingWaitManualClock()
            let waiter = MCPRoutingWaiter(clock: clock.routingClock)

            let preCancelledRunID = UUID()
            await waiter.register(runID: preCancelledRunID)
            let preCancelledWaiter = Task {
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
                return await waiter.waitForRoutingOutcome(
                    runID: preCancelledRunID,
                    timeoutSeconds: 0
                )
            }
            let preCancelledOutcome = await preCancelledWaiter.value
            XCTAssertEqual(preCancelledOutcome, .cancelled)
            let preCancelledContinuationCount = await waiter.debugContinuationCount(runID: preCancelledRunID)
            XCTAssertEqual(preCancelledContinuationCount, 0)
            XCTAssertTrue(clock.activeDeadlines().isEmpty)
            await waiter.cleanup(runID: preCancelledRunID)

            let runID = UUID()
            await waiter.register(runID: runID)
            let cancelledWaiter = Task {
                await waiter.waitForRoutingOutcome(runID: runID, timeoutSeconds: 0)
            }
            let routedWaiter = Task {
                await waiter.waitUntilRouted(runID: runID, timeoutSeconds: -1)
            }

            var continuationCount = 0
            for _ in 0 ..< 100 {
                continuationCount = await waiter.debugContinuationCount(runID: runID)
                if continuationCount == 2 { break }
                await Task.yield()
            }
            XCTAssertEqual(continuationCount, 2, "nonpositive legacy timeouts must not resolve immediately")
            XCTAssertTrue(clock.activeDeadlines().isEmpty)

            clock.advance(by: .seconds(60))
            let continuationCountAfterMinute = await waiter.debugContinuationCount(runID: runID)
            XCTAssertEqual(continuationCountAfterMinute, 2)
            XCTAssertTrue(clock.activeDeadlines().isEmpty)

            cancelledWaiter.cancel()
            let cancelledOutcome = await cancelledWaiter.value
            XCTAssertEqual(cancelledOutcome, .cancelled)
            let remainingContinuationCount = await waiter.debugContinuationCount(runID: runID)
            XCTAssertEqual(remainingContinuationCount, 1)

            await waiter.notifyRouted(runID: runID)
            let didRoute = await routedWaiter.value
            XCTAssertTrue(didRoute)
            await waiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Routing waiter continuation inspection is DEBUG-only.")
        #endif
    }

    func testTypedCancellationAndCleanupRemainDistinct() async {
        #if DEBUG
            let clock = MCPRoutingWaitManualClock()
            let waiter = MCPRoutingWaiter(clock: clock.routingClock)
            let runID = UUID()
            await waiter.register(runID: runID)
            let cancelledWaiter = Task {
                await waiter.waitForRoutingOutcome(
                    runID: runID,
                    policy: MCPRoutingWaitPolicy(
                        noConnectionTimeout: .seconds(5),
                        observedConnectionGrace: .seconds(5)
                    )
                )
            }
            let cleanupWaiter = Task {
                await waiter.waitForRoutingOutcome(
                    runID: runID,
                    policy: MCPRoutingWaitPolicy(
                        noConnectionTimeout: .seconds(5),
                        observedConnectionGrace: .seconds(5)
                    )
                )
            }
            var continuationCount = 0
            for _ in 0 ..< 100 {
                continuationCount = await waiter.debugContinuationCount(runID: runID)
                if continuationCount == 2 { break }
                await Task.yield()
            }
            XCTAssertEqual(continuationCount, 2)

            cancelledWaiter.cancel()
            let cancelledOutcome = await cancelledWaiter.value
            XCTAssertEqual(cancelledOutcome, .cancelled)
            await waiter.cleanup(runID: runID)
            let cleanupOutcome = await cleanupWaiter.value
            XCTAssertEqual(cleanupOutcome, .failed(.cleanedUp))
        #else
            XCTFail("Routing waiter continuation inspection is DEBUG-only.")
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

private final class MCPRoutingWaitManualClock: @unchecked Sendable {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct DeadlineWaiter {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var nowValue: Duration = .zero
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledSleeperIDs: Set<UUID> = []
    private var deadlineWaiters: [DeadlineWaiter] = []

    var routingClock: MCPRoutingWaitClock {
        MCPRoutingWaitClock(
            now: { [weak self] in
                self?.now() ?? .zero
            },
            sleep: { [weak self] duration in
                guard let self else { return }
                try await sleep(for: duration)
            }
        )
    }

    func activeDeadlines() -> [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.values.map(\.deadline).sorted()
    }

    func advance(by duration: Duration) {
        lock.lock()
        nowValue += duration
        let readyIDs = sleepers.compactMap { id, sleeper in
            sleeper.deadline <= nowValue ? id : nil
        }
        let ready = readyIDs.compactMap { sleepers.removeValue(forKey: $0)?.continuation }
        lock.unlock()
        for continuation in ready {
            continuation.resume()
        }
    }

    func waitUntilSleeping(deadline: Duration) async {
        lock.lock()
        if sleepers.values.contains(where: { $0.deadline == deadline }) {
            lock.unlock()
            return
        }
        lock.unlock()

        await withCheckedContinuation { continuation in
            lock.lock()
            if sleepers.values.contains(where: { $0.deadline == deadline }) {
                lock.unlock()
                continuation.resume()
                return
            }
            deadlineWaiters.append(DeadlineWaiter(deadline: deadline, continuation: continuation))
            lock.unlock()
        }
    }

    private func now() -> Duration {
        lock.lock()
        defer { lock.unlock() }
        return nowValue
    }

    private func sleep(for duration: Duration) async throws {
        let sleeperID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if Task.isCancelled || cancelledSleeperIDs.remove(sleeperID) != nil {
                    lock.unlock()
                    continuation.resume()
                    return
                }

                let deadline = nowValue + max(.zero, duration)
                if deadline <= nowValue {
                    lock.unlock()
                    continuation.resume()
                    return
                }

                sleepers[sleeperID] = Sleeper(deadline: deadline, continuation: continuation)
                let readyWaiters = deadlineWaiters.filter { $0.deadline == deadline }
                deadlineWaiters.removeAll { $0.deadline == deadline }
                lock.unlock()
                for waiter in readyWaiters {
                    waiter.continuation.resume()
                }
            }
        } onCancel: {
            cancel(sleeperID: sleeperID)
        }
        try Task.checkCancellation()
    }

    private func cancel(sleeperID: UUID) {
        lock.lock()
        let continuation = sleepers.removeValue(forKey: sleeperID)?.continuation
        if continuation == nil {
            cancelledSleeperIDs.insert(sleeperID)
        }
        lock.unlock()
        continuation?.resume()
    }
}

private actor MCPRoutingWaitEnrollmentGate {
    private var blocked = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        blocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
