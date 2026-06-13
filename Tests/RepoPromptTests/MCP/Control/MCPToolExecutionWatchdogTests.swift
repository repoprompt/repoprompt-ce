import Foundation
@testable import RepoPrompt
import RepoPromptShared
import XCTest

final class MCPToolExecutionWatchdogTests: XCTestCase {
    func testCompletionBeforeDeadlineReturnsValueWithoutTimeoutEvents() async throws {
        let clock = ExecutionWatchdogManualClock()
        let events = ExecutionWatchdogEventRecorder()

        let value = try await MCPToolExecutionWatchdog.execute(
            deadline: MCPTimeoutPolicy.boundedToolExecutionDeadline,
            cancellationGrace: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace,
            environment: clock.environment,
            onEvent: { await events.append($0) }
        ) {
            42
        }

        XCTAssertEqual(value, 42)
        let recordedEvents = await events.snapshot()
        XCTAssertEqual(recordedEvents, [])
    }

    func testDeadlineCancelsCooperativeOperationAndReturnsSingleTimeout() async throws {
        let clock = ExecutionWatchdogManualClock()
        let events = ExecutionWatchdogEventRecorder()
        let task = Task<Int, Error> {
            try await MCPToolExecutionWatchdog.execute(
                deadline: MCPTimeoutPolicy.boundedToolExecutionDeadline,
                cancellationGrace: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace,
                environment: clock.environment,
                onEvent: { await events.append($0) }
            ) {
                try await Task.sleep(for: .seconds(3600))
                return 1
            }
        }

        try await clock.waitForSleeperCount(1)
        try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)

        do {
            _ = try await task.value
            XCTFail("Expected execution timeout")
        } catch let error as MCPToolExecutionWatchdogError {
            XCTAssertEqual(error, .executionTimedOut(settlement: .cancellation))
        }
        let recordedEvents = await events.snapshot()
        XCTAssertEqual(recordedEvents, [
            .deadlineExpired,
            .cancellationRequested,
            .settledDuringGrace(.cancellation)
        ])
    }

    func testDeadlineStartsCancellationGraceBeforeAwaitingDiagnostics() async throws {
        let clock = ExecutionWatchdogManualClock()
        let events = ExecutionWatchdogEventRecorder()
        let callbackGate = ExecutionWatchdogCallbackGate()
        let task = Task<Int, Error> {
            try await MCPToolExecutionWatchdog.execute(
                deadline: MCPTimeoutPolicy.boundedToolExecutionDeadline,
                cancellationGrace: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace,
                environment: clock.environment,
                onEvent: { event in
                    await events.append(event)
                    if event == .deadlineExpired {
                        await callbackGate.pause()
                    }
                }
            ) {
                try await Task.sleep(for: .seconds(3600))
                return 1
            }
        }

        try await clock.waitForSleeperCount(1)
        try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
        await callbackGate.waitUntilPaused()
        try await clock.waitForSleeperCount(1)
        await callbackGate.open()

        do {
            _ = try await task.value
            XCTFail("Expected execution timeout")
        } catch let error as MCPToolExecutionWatchdogError {
            XCTAssertEqual(error, .executionTimedOut(settlement: .cancellation))
        }
        let recordedEvents = await events.snapshot()
        XCTAssertEqual(recordedEvents, [
            .deadlineExpired,
            .cancellationRequested,
            .settledDuringGrace(.cancellation)
        ])
    }

    func testUncooperativeOperationEscalatesAfterCleanupGraceWithoutJoiningIt() async throws {
        let clock = ExecutionWatchdogManualClock()
        let events = ExecutionWatchdogEventRecorder()
        let gate = ExecutionWatchdogUncooperativeGate()
        let task = Task<Int, Error> {
            try await MCPToolExecutionWatchdog.execute(
                deadline: MCPTimeoutPolicy.boundedToolExecutionDeadline,
                cancellationGrace: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace,
                environment: clock.environment,
                onEvent: { await events.append($0) }
            ) {
                await gate.wait()
                return 1
            }
        }

        try await clock.waitForSleeperCount(1)
        try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
        try await clock.waitForSleeperCount(1)
        try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace)

        do {
            _ = try await task.value
            XCTFail("Expected cleanup escalation")
        } catch let error as MCPToolExecutionWatchdogError {
            XCTAssertEqual(error, .cleanupUnresponsive)
        }
        let recordedEvents = await events.snapshot()
        XCTAssertEqual(recordedEvents, [
            .deadlineExpired,
            .cancellationRequested,
            .cleanupGraceExpired
        ])

        await gate.release()
    }

    func testManualClockAdvancesElapsedTimeWithoutRegisteredSleepers() async throws {
        let clock = ExecutionWatchdogManualClock()
        try await clock.advanceWithoutSleepers(by: .seconds(31))
        let elapsed = await clock.currentTime()
        let sleeperCount = await clock.sleeperCount()
        XCTAssertEqual(elapsed, .seconds(31))
        XCTAssertEqual(sleeperCount, 0)
    }

    func testManualClockRejectsElapsedAdvanceWhileSleeperIsRegistered() async throws {
        let clock = ExecutionWatchdogManualClock()
        let sleeper = Task {
            try await clock.sleep(for: .seconds(1))
        }
        try await clock.waitForSleeperCount(1)
        do {
            try await clock.advanceWithoutSleepers(by: .seconds(31))
            XCTFail("Expected registered sleeper guard")
        } catch {
            // Expected.
        }
        sleeper.cancel()
        _ = try? await sleeper.value
    }

    func testHandlerPhaseRecorderUsesWatchdogClockAndFormatsEscalationContext() async throws {
        let clock = ExecutionWatchdogManualClock()
        let origin = await clock.currentTime()
        let recorder = MCPToolExecutionHandlerPhaseRecorder(
            origin: origin,
            now: { await clock.environment.now() }
        )

        await recorder.report(.manageSelectionAutoSelectionDrain, transition: .started)
        try await clock.advanceWithoutSleepers(by: .seconds(2))
        let phase = try XCTUnwrap(recorder.snapshot())
        let invocationID = UUID()
        let event = MCPToolExecutionTraceEvent(
            toolName: MCPWindowToolName.manageSelection,
            connectionID: UUID(),
            invocationID: invocationID,
            runID: nil,
            contractKind: .bounded,
            executionDeadlineSeconds: 30,
            cleanupGraceSeconds: 5,
            phase: .deadlineExpired,
            elapsedMilliseconds: 2000,
            cancellationRequested: nil,
            cancellationOutcome: nil,
            graceOutcome: nil,
            escalationReason: nil,
            handlerPhase: phase,
            handlerPhaseAgeMilliseconds: 2000
        )

        XCTAssertEqual(phase.phase, .manageSelectionAutoSelectionDrain)
        XCTAssertEqual(phase.transition, .started)
        XCTAssertEqual(phase.elapsedMilliseconds, 0)
        XCTAssertTrue(event.description.contains("invocation_id=\(invocationID.uuidString)"))
        XCTAssertTrue(event.description.contains("handler_phase=manage_selection.auto_selection_drain"))
        XCTAssertTrue(event.description.contains("handler_phase_transition=started"))
        XCTAssertTrue(event.description.contains("handler_phase_age_ms=2000.000"))
    }

    func testExternalCancellationCancelsOwnedTasksAndPropagatesCancellation() async throws {
        let clock = ExecutionWatchdogManualClock()
        let gate = ExecutionWatchdogUncooperativeGate()
        let task = Task<Int, Error> {
            try await MCPToolExecutionWatchdog.execute(
                deadline: MCPTimeoutPolicy.boundedToolExecutionDeadline,
                cancellationGrace: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace,
                environment: clock.environment
            ) {
                await gate.wait()
                try Task.checkCancellation()
                return 1
            }
        }

        try await clock.waitForSleeperCount(1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        await gate.release()
    }
}

private actor ExecutionWatchdogCallbackGate {
    private var isPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        isPaused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func open() {
        let waiters = openWaiters
        openWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor ExecutionWatchdogEventRecorder {
    private var events: [MCPToolExecutionWatchdogEvent] = []

    func append(_ event: MCPToolExecutionWatchdogEvent) {
        events.append(event)
    }

    func snapshot() -> [MCPToolExecutionWatchdogEvent] {
        events
    }
}

actor ExecutionWatchdogUncooperativeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

actor ExecutionWatchdogManualClock {
    private static let synchronizationTimeout: Duration = .seconds(10)

    private struct Sleeper {
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private var elapsed: Duration = .zero
    private var sleeperOrder: [UUID] = []
    private var sleepers: [UUID: Sleeper] = [:]

    nonisolated var environment: MCPToolExecutionWatchdogEnvironment {
        MCPToolExecutionWatchdogEnvironment(
            now: { await self.currentTime() },
            sleep: { try await self.sleep(for: $0) }
        )
    }

    func currentTime() -> Duration {
        elapsed
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleeperOrder.append(id)
                sleepers[id] = Sleeper(duration: duration, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelSleeper(id) }
        }
    }

    func sleeperCount() -> Int {
        sleepers.count
    }

    func waitForSleeperCount(
        _ count: Int,
        timeout: Duration = synchronizationTimeout
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while sleepers.count < count {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw ManualClockError.sleeperDidNotRegister(expected: count, actual: sleepers.count)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func advanceWithoutSleepers(by duration: Duration) throws {
        guard duration > .zero else {
            throw ManualClockError.nonPositiveAdvance(duration)
        }
        guard sleepers.isEmpty else {
            throw ManualClockError.sleepersRegistered(sleepers.count)
        }
        elapsed += duration
    }

    func advanceNext(expected: Duration) throws {
        guard let id = sleeperOrder.first else {
            throw ManualClockError.noSleeper
        }
        sleeperOrder.removeFirst()
        guard let sleeper = sleepers.removeValue(forKey: id) else {
            throw ManualClockError.noSleeper
        }
        guard sleeper.duration == expected else {
            throw ManualClockError.unexpectedDuration(expected: expected, actual: sleeper.duration)
        }
        elapsed += sleeper.duration
        sleeper.continuation.resume()
    }

    private func cancelSleeper(_ id: UUID) {
        sleeperOrder.removeAll { $0 == id }
        sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    private enum ManualClockError: Error {
        case noSleeper
        case nonPositiveAdvance(Duration)
        case sleeperDidNotRegister(expected: Int, actual: Int)
        case sleepersRegistered(Int)
        case unexpectedDuration(expected: Duration, actual: Duration)
    }
}
