import Foundation
import MCP
import RepoPromptDomainRuntime
import XCTest

final class AgentRunStartEnvelopeTests: XCTestCase {
    func testReturningStartReplacesSetupDeadlineAndDetachesWithoutAwaitingOperation() async throws {
        let clock = MCPExportWatchdogManualClock()
        let scope = MCPAgentRunStartExecutionScope(connectionID: UUID(), environment: clock.environment)
        let gate = StartEnvelopeGate()
        let operation = Task {
            try await MCPToolExecutionWatchdog.execute(
                deadline: .seconds(150), cancellationGrace: .seconds(5),
                cleanupDisposition: .detachAndSettle, startScope: scope, environment: clock.environment
            ) {
                try scope.enterReturn()
                await gate.wait()
                return 1
            }
        }
        defer { Task { await gate.release() } }
        try await clock.waitForSleeper(expected: .seconds(25))
        try await clock.advanceSleeper(expected: .seconds(25))
        try await clock.waitForSleeper(expected: .seconds(5))
        try await clock.advanceSleeper(expected: .seconds(5))
        do { _ = try await operation.value
            XCTFail("Expected detached start request")
        } catch { XCTAssertEqual(error as? MCPToolExecutionWatchdogError, .executionDetached) }
        XCTAssertEqual(scope.recoveryMetadata()["settlement"], .string("pending"))
        XCTAssertThrowsError(try scope.checkAdmission())
        await gate.release()
    }

    func testReturnCompletionTimestampWinsOnlyStrictlyBeforeDeadline() async throws {
        for instant in [Duration.seconds(24), .seconds(25), .seconds(27)] {
            let clock = MCPExportWatchdogManualClock()
            let scope = MCPAgentRunStartExecutionScope(connectionID: UUID(), environment: clock.environment)
            let gate = StartEnvelopeGate()
            let task = Task {
                try await MCPToolExecutionWatchdog.execute(
                    deadline: .seconds(150), cancellationGrace: .seconds(5),
                    cleanupDisposition: .detachAndSettle, startScope: scope, environment: clock.environment
                ) {
                    try scope.enterReturn()
                    await gate.wait()
                    return 7
                }
            }
            defer { Task { await gate.release() } }
            try await clock.waitForSleeper(expected: .seconds(25))
            try await clock.advanceWithoutWakingSleepers(by: instant)
            await gate.release()
            do {
                let value = try await task.value
                XCTAssertEqual(instant, .seconds(24))
                XCTAssertEqual(value, 7)
            } catch {
                XCTAssertNotEqual(instant, .seconds(24))
                XCTAssertEqual(error as? MCPToolExecutionWatchdogError, .executionTimedOut(settlement: .success))
            }
            XCTAssertEqual(scope.recoveryMetadata()["settlement"], .string("settled"))
        }
    }

    func testDelayedDeadlineConsumptionCapsGraceAtAbsoluteReturnDeadlinePlusFive() async throws {
        let clock = MCPExportWatchdogManualClock()
        let deadlineConsumed = StartEnvelopeGate()
        let releaseConsumption = StartEnvelopeGate()
        let operationGate = StartEnvelopeGate()
        let environment = clock.environment(beforeEventConsumption: { point in
            if point == .deadlineExpired {
                await deadlineConsumed.release()
                await releaseConsumption.wait()
            }
        })
        let scope = MCPAgentRunStartExecutionScope(connectionID: UUID(), environment: environment)
        let task = Task {
            try await MCPToolExecutionWatchdog.execute(
                deadline: .seconds(150), cancellationGrace: .seconds(5),
                cleanupDisposition: .detachAndSettle, startScope: scope, environment: environment
            ) {
                try scope.enterReturn()
                await operationGate.wait()
                return 1
            }
        }
        defer { Task { await releaseConsumption.release()
            await operationGate.release()
        } }
        try await clock.waitForSleeper(expected: .seconds(25))
        try await clock.advanceSleeper(expected: .seconds(25))
        await deadlineConsumed.wait()
        try await clock.advanceWithoutSleepers(by: .seconds(4))
        await releaseConsumption.release()
        try await clock.waitForSleeper(expected: .seconds(1))
        try await clock.advanceSleeper(expected: .seconds(1))
        do {
            _ = try await task.value
            XCTFail("Expected detached return")
        } catch {
            XCTAssertEqual(error as? MCPToolExecutionWatchdogError, .executionDetached)
        }
        XCTAssertEqual(clock.currentTime(), .seconds(30))
        await operationGate.release()
    }

    func testDelayedGraceTaskStartupDoesNotRestartCapturedRemainingGrace() async throws {
        let clock = MCPExportWatchdogManualClock()
        let delayedClock = StartEnvelopeGraceSchedule()
        let gate = StartEnvelopeGate()
        let environment = MCPToolExecutionWatchdogEnvironment(
            now: { delayedClock.now(fallback: clock.currentTime()) },
            sleep: { try await clock.sleep(for: $0) },
            beforeCleanupGraceTaskRegistration: { delayedClock.delayGraceTask() }
        )
        let scope = MCPAgentRunStartExecutionScope(connectionID: UUID(), environment: environment)
        let task = Task {
            try await MCPToolExecutionWatchdog.execute(
                deadline: .seconds(150), cancellationGrace: .seconds(5),
                cleanupDisposition: .detachAndSettle, startScope: scope, environment: environment
            ) {
                try scope.enterReturn()
                await gate.wait()
                return 1
            }
        }
        defer { task.cancel()
            Task { await gate.release() }
        }
        try await clock.waitForSleeper(expected: .seconds(25))
        try await clock.advanceSleeper(expected: .seconds(25))
        // Grace calculation observes 29; its task first runs at 31, beyond the cap of 30.
        // The timer must sleep zero, not restart the captured one-second remainder.
        try await clock.waitForSleeper(expected: .zero)
        try await clock.advanceSleeper(expected: .zero)
        do {
            _ = try await task.value
            XCTFail("Expected detached return")
        } catch {
            XCTAssertEqual(error as? MCPToolExecutionWatchdogError, .executionDetached)
        }
        await gate.release()
    }

    func testSemanticBudgetStartsAfterSetupAndLateTransitionsCannotExtendIt() async throws {
        let clock = MCPExportWatchdogManualClock()
        let scope = MCPAgentRunStartExecutionScope(connectionID: UUID(), environment: clock.environment)
        try await clock.advanceWithoutSleepers(by: .seconds(149))
        XCTAssertEqual(try scope.enterSemanticWait(seconds: 300), .seconds(449))
        XCTAssertEqual(scope.deadline.instant, .seconds(474))
        try await clock.advanceWithoutSleepers(by: .seconds(325))
        XCTAssertThrowsError(try scope.enterReturn())
        XCTAssertThrowsError(try scope.beginDispatch())
    }

    func testSetupCannotBorrowAttachedSemanticTimeoutAndRetainsReservedIdentity() async throws {
        let clock = MCPExportWatchdogManualClock()
        let scope = MCPAgentRunStartExecutionScope(connectionID: UUID(), environment: clock.environment)
        let sessionID = UUID(), tabID = UUID()
        try scope.recordTarget(sessionID: sessionID, tabID: tabID)
        let gate = StartEnvelopeGate()
        let task = Task {
            try await MCPToolExecutionWatchdog.execute(
                deadline: .seconds(150), cancellationGrace: .seconds(5),
                cleanupDisposition: .detachAndSettle, startScope: scope, environment: clock.environment
            ) {
                await gate.wait()
                // A long caller wait is not admitted after setup expires.
                _ = try scope.enterSemanticWait(seconds: 3600)
                XCTFail("Late start entered semantic wait")
                return 1
            }
        }
        defer { Task { await gate.release() } }
        try await clock.waitForSleeper(expected: .seconds(150))
        try await clock.advanceSleeper(expected: .seconds(150))
        try await clock.waitForSleeper(expected: .seconds(5))
        try await clock.advanceSleeper(expected: .seconds(5))
        do { _ = try await task.value
            XCTFail("Expected detached setup")
        } catch { XCTAssertEqual(error as? MCPToolExecutionWatchdogError, .executionDetached) }
        let recovery = scope.recoveryMetadata()
        XCTAssertEqual(recovery["session_id"], .string(sessionID.uuidString))
        XCTAssertEqual(recovery["phase"], .string("setup"))
        XCTAssertEqual(recovery["dispatch_state"], .string("not_attempted"))
        XCTAssertEqual(recovery["settlement"], .string("pending"))
        await gate.release()
    }

    func testStaleTimerRevisionCannotCancelTimelySemanticPhase() async throws {
        let clock = MCPExportWatchdogManualClock()
        let scope = MCPAgentRunStartExecutionScope(connectionID: UUID(), environment: clock.environment)
        let setupRevision = scope.deadline.revision
        try await clock.advanceWithoutSleepers(by: .seconds(149))
        _ = try scope.enterSemanticWait(seconds: 300)
        try await clock.advanceWithoutSleepers(by: .seconds(1))
        XCTAssertFalse(scope.expire(revision: setupRevision))
        XCTAssertNoThrow(try scope.checkAdmission())
        XCTAssertEqual(scope.phase, .semanticWait)
    }

    func testReturnCannotExtendFixedSemanticEnvelopeOrRearmItself() async throws {
        let clock = MCPExportWatchdogManualClock()
        let scope = MCPAgentRunStartExecutionScope(connectionID: UUID(), environment: clock.environment)
        _ = try scope.enterSemanticWait(seconds: 10)
        try await clock.advanceWithoutSleepers(by: .seconds(15))
        try scope.enterReturn()
        XCTAssertEqual(scope.deadline.instant, .seconds(35))
        let firstReturn = scope.deadline
        try await clock.advanceWithoutSleepers(by: .seconds(1))
        try scope.enterReturn()
        XCTAssertEqual(scope.deadline, firstReturn)
        XCTAssertThrowsError(try scope.enterSemanticWait(seconds: 600))
    }

    func testClosedScopeRetainsUnknownAndLateAcceptedDispatchWithoutUnsafeCleanup() throws {
        let clock = MCPExportWatchdogManualClock()
        let scope = MCPAgentRunStartExecutionScope(connectionID: UUID(), environment: clock.environment)
        try scope.recordTarget(sessionID: UUID(), tabID: UUID(), created: true)
        try scope.beginDispatch()
        scope.close()
        XCTAssertFalse(scope.allowsFailureCleanup)
        XCTAssertEqual(scope.recoveryMetadata()["dispatch_state"], .string("unknown"))
        XCTAssertThrowsError(try scope.recordActivation(UUID()))
        XCTAssertThrowsError(try scope.recordWorktreeIntent("must not be recorded"))
        XCTAssertThrowsError(try scope.beginDispatch())
        scope.recordDispatch(accepted: true)
        scope.recordDispatch(accepted: false)
        XCTAssertFalse(scope.allowsFailureCleanup)
        XCTAssertEqual(scope.recoveryMetadata()["dispatch_state"], .string("accepted"))
        scope.settle()
        XCTAssertEqual(scope.recoveryMetadata()["settlement"], .string("settled"))
    }

    func testRefusedSubmissionAllowsExactOwnerCleanupAndNoSnapshotIsFabricated() throws {
        let clock = MCPExportWatchdogManualClock()
        let scope = MCPAgentRunStartExecutionScope(connectionID: UUID(), environment: clock.environment)
        try scope.beginDispatch()
        scope.recordDispatch(accepted: false)
        scope.close()
        XCTAssertTrue(scope.allowsFailureCleanup)
        let result = scope.timeoutValue(code: "timeout", message: "bounded request").objectValue
        XCTAssertNil(result?["status"])
        XCTAssertNil(result?["session_id"])
        XCTAssertEqual(result?["_meta"]?.objectValue?["start"]?.objectValue?["dispatch_state"], .string("refused"))
    }

    func testCachedRealResponseSurvivesMemoryOnlyTimeoutRendering() throws {
        let clock = MCPExportWatchdogManualClock()
        let scope = MCPAgentRunStartExecutionScope(connectionID: UUID(), environment: clock.environment)
        let sessionID = UUID()
        try scope.recordTarget(sessionID: sessionID, tabID: UUID())
        scope.recordDispatch(accepted: true)
        scope.cacheResponse(.object([
            "session_id": .string(sessionID.uuidString), "status": .string("running"),
            "_meta": .object(["existing": .bool(true)])
        ]))
        scope.close()
        let value = scope.timeoutValue(code: "timeout", message: "bounded request").objectValue
        XCTAssertEqual(value?["status"], .string("running"))
        XCTAssertEqual(value?["is_error"], .bool(true))
        XCTAssertEqual(value?["_meta"]?.objectValue?["existing"], .bool(true))
        XCTAssertEqual(value?["_meta"]?.objectValue?["start"]?.objectValue?["session_id"], .string(sessionID.uuidString))
    }

    func testClientCancellationClosesAdmissionBeforeNoncooperativeOperationResumes() async throws {
        let clock = MCPExportWatchdogManualClock()
        let scope = MCPAgentRunStartExecutionScope(connectionID: UUID(), environment: clock.environment)
        let gate = StartEnvelopeGate()
        let task = Task {
            try await MCPToolExecutionWatchdog.execute(
                deadline: .seconds(150), cancellationGrace: .seconds(5),
                cleanupDisposition: .detachAndSettle, startScope: scope, environment: clock.environment
            ) {
                await gate.wait()
                try scope.beginDispatch()
                XCTFail("Cancelled operation dispatched")
                return 1
            }
        }
        defer { Task { await gate.release() } }
        try await clock.waitForSleeper(expected: .seconds(150))
        task.cancel()
        do { _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertThrowsError(try scope.checkAdmission())
        await gate.release()
    }

    func testAlreadyCancelledWatchdogNeverLaunchesStartOperation() async throws {
        let clock = MCPExportWatchdogManualClock()
        let scope = MCPAgentRunStartExecutionScope(connectionID: UUID(), environment: clock.environment)
        let gate = StartEnvelopeGate()
        let task = Task {
            await gate.wait()
            return try await MCPToolExecutionWatchdog.execute(
                deadline: .seconds(150), cancellationGrace: .seconds(5),
                cleanupDisposition: .detachAndSettle, startScope: scope, environment: clock.environment
            ) {
                XCTFail("Pre-cancelled start launched work")
                return 1
            }
        }
        task.cancel()
        await gate.release()
        do { _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertThrowsError(try scope.checkAdmission())
    }
}

private actor StartEnvelopeGate {
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        released = true
        let captured = waiting
        waiting.removeAll()
        captured.forEach { $0.resume() }
    }
}

/// Advances only the scheduling reads: both readings share the same monotonic origin.
private final class StartEnvelopeGraceSchedule: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [Duration] = []
    private var last: Duration?
    func delayGraceTask() {
        lock.withLock { remaining = [.seconds(29), .seconds(31)] }
    }

    func now(fallback: Duration) -> Duration {
        lock.withLock {
            if !remaining.isEmpty { last = remaining.removeFirst() }
            return last ?? fallback
        }
    }
}
