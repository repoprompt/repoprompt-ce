import Foundation
@testable import RepoPromptApp
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
        let operationGate = ExecutionWatchdogCancellationGate()
        let task = Task<Int, Error> {
            try await MCPToolExecutionWatchdog.execute(
                deadline: MCPTimeoutPolicy.boundedToolExecutionDeadline,
                cancellationGrace: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace,
                environment: clock.environment,
                onEvent: { await events.append($0) }
            ) {
                try await operationGate.waitUntilCancelled()
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
            .cancellationRequested(origin: .watchdogDeadline),
            .settledDuringGrace(.cancellation)
        ])
    }

    func testDeadlineStartsCancellationGraceBeforeAwaitingDiagnostics() async throws {
        let clock = ExecutionWatchdogManualClock()
        let events = ExecutionWatchdogEventRecorder()
        let callbackGate = ExecutionWatchdogCallbackGate()
        let operationGate = ExecutionWatchdogCancellationGate()
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
                try await operationGate.waitUntilCancelled()
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
            .cancellationRequested(origin: .watchdogDeadline),
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
            .cancellationRequested(origin: .watchdogDeadline),
            .cleanupGraceExpired
        ])

        await gate.release()
    }

    func testDetachAndSettleReturnsWithoutJoiningAndReportsLateSettlement() async throws {
        let clock = ExecutionWatchdogManualClock()
        let events = ExecutionWatchdogEventRecorder()
        let settlements = ExecutionWatchdogSettlementRecorder()
        let gate = ExecutionWatchdogUncooperativeGate()
        let task = Task<Int, Error> {
            try await MCPToolExecutionWatchdog.execute(
                deadline: MCPTimeoutPolicy.boundedToolExecutionDeadline,
                cancellationGrace: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace,
                cleanupDisposition: .detachAndSettle,
                environment: clock.environment,
                onEvent: { await events.append($0) },
                onDetachedSettlement: { await settlements.append($0) }
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
            XCTFail("Expected detached execution timeout")
        } catch let error as MCPToolExecutionWatchdogError {
            XCTAssertEqual(error, .executionDetached)
        }
        let sleeperCountAfterDetach = await clock.sleeperCount()
        let settlementsAfterDetach = await settlements.snapshot()
        let eventsAfterDetach = await events.snapshot()
        XCTAssertEqual(sleeperCountAfterDetach, 0)
        XCTAssertEqual(settlementsAfterDetach, [])
        XCTAssertEqual(eventsAfterDetach, [
            .deadlineExpired,
            .cancellationRequested(origin: .watchdogDeadline),
            .cleanupGraceExpired,
            .detachedForSettlement
        ])

        await gate.release()
        try await settlements.waitForCount(1)
        let finalSettlements = await settlements.snapshot()
        let finalSleeperCount = await clock.sleeperCount()
        XCTAssertEqual(finalSettlements, [.success])
        XCTAssertEqual(finalSleeperCount, 0)
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
            cleanupDisposition: .detachAndSettle,
            phase: .deadlineExpired,
            elapsedMilliseconds: 2000,
            cancellationRequested: nil,
            cancellationOutcome: nil,
            cancellationOrigin: nil,
            settlement: nil,
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
        XCTAssertEqual(
            [
                MCPToolExecutionHandlerPhase.getCodeStructureSeedResolution,
                .getCodeStructureSeedDemand,
                .getCodeStructureProjectionWait,
                .getCodeStructureGraphQuery,
                .getCodeStructureTargetDemand,
                .getCodeStructureGraphRequery,
                .getCodeStructureFreeze,
                .getCodeStructureRender,
                .getCodeStructureAssembly,
                .getCodeStructurePublicationRevalidation
            ].map(\.rawValue),
            [
                "get_code_structure.seed_resolution",
                "get_code_structure.seed_demand",
                "get_code_structure.projection_wait",
                "get_code_structure.graph_query",
                "get_code_structure.target_demand",
                "get_code_structure.graph_requery",
                "get_code_structure.freeze",
                "get_code_structure.render",
                "get_code_structure.assembly",
                "get_code_structure.publication_revalidation"
            ]
        )
        XCTAssertTrue(event.description.contains("cleanup_disposition=detach_and_settle"))
        XCTAssertTrue(MCPToolExecutionTraceEvent.Phase.detachedForSettlement.isAlwaysEmitted)
        XCTAssertTrue(MCPToolExecutionTraceEvent.Phase.detachedSettled.isAlwaysEmitted)
    }

    func testExternalCancellationCancelsOwnedTasksAndPropagatesCancellation() async throws {
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
        try await events.waitForCount(1)
        let recordedEvents = await events.snapshot()
        XCTAssertEqual(recordedEvents, [
            .cancellationRequested(origin: .requestCancellation)
        ])
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
    private static let synchronizationTimeout: Duration = .seconds(10)
    private var events: [MCPToolExecutionWatchdogEvent] = []

    func append(_ event: MCPToolExecutionWatchdogEvent) {
        events.append(event)
    }

    func snapshot() -> [MCPToolExecutionWatchdogEvent] {
        events
    }

    func waitForCount(
        _ expected: Int,
        timeout: Duration = synchronizationTimeout
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while events.count < expected {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw ExecutionWatchdogEventRecorderError.eventDidNotArrive(
                    expected: expected,
                    actual: events.count
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum ExecutionWatchdogEventRecorderError: Error {
    case eventDidNotArrive(expected: Int, actual: Int)
}

private actor ExecutionWatchdogSettlementRecorder {
    private static let synchronizationTimeout: Duration = .seconds(10)
    private var settlements: [MCPToolExecutionSettlement] = []

    func append(_ settlement: MCPToolExecutionSettlement) {
        settlements.append(settlement)
    }

    func snapshot() -> [MCPToolExecutionSettlement] {
        settlements
    }

    func waitForCount(
        _ expected: Int,
        timeout: Duration = synchronizationTimeout
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while settlements.count < expected {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw ExecutionWatchdogSettlementRecorderError.settlementDidNotArrive(
                    expected: expected,
                    actual: settlements.count
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum ExecutionWatchdogSettlementRecorderError: Error {
    case settlementDidNotArrive(expected: Int, actual: Int)
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

typealias ExecutionWatchdogCancellationGate = TestCancellationGate

actor ExecutionWatchdogManualClock {
    private static let synchronizationTimeout: Duration = .seconds(10)

    private var elapsed: Duration = .zero
    /// Lock-backed sleeper registry so `onCancel` can remove/resume synchronously.
    private let sleeperState = ManualClockSleeperState()

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
                self.sleeperState.register(id: id, duration: duration, continuation: continuation)
            }
        } onCancel: {
            sleeperState.cancel(id: id)
        }
    }

    func sleeperCount() -> Int {
        sleeperState.count
    }

    func waitForSleeperCount(
        _ count: Int,
        timeout: Duration = synchronizationTimeout
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while sleeperState.count < count {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw ManualClockError.sleeperDidNotRegister(expected: count, actual: sleeperState.count)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func advanceWithoutSleepers(by duration: Duration) throws {
        guard duration > .zero else {
            throw ManualClockError.nonPositiveAdvance(duration)
        }
        guard sleeperState.count == 0 else {
            throw ManualClockError.sleepersRegistered(sleeperState.count)
        }
        elapsed += duration
    }

    func advanceNext(expected: Duration) throws {
        guard let sleeper = sleeperState.popNext() else {
            throw ManualClockError.noSleeper
        }
        guard sleeper.duration == expected else {
            throw ManualClockError.unexpectedDuration(expected: expected, actual: sleeper.duration)
        }
        elapsed += sleeper.duration
        sleeper.continuation.resume()
    }

    private enum ManualClockError: Error {
        case noSleeper
        case nonPositiveAdvance(Duration)
        case sleeperDidNotRegister(expected: Int, actual: Int)
        case sleepersRegistered(Int)
        case unexpectedDuration(expected: Duration, actual: Duration)
    }
}

/// Sync-cancelable sleeper registry for the manual watchdog clock.
private final class ManualClockSleeperState: @unchecked Sendable {
    private struct Sleeper {
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var sleeperOrder: [UUID] = []
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledIDs = Set<UUID>()

    var count: Int {
        lock.withLock { sleepers.count }
    }

    func register(
        id: UUID,
        duration: Duration,
        continuation: CheckedContinuation<Void, Error>
    ) {
        lock.lock()
        if cancelledIDs.remove(id) != nil {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        sleeperOrder.append(id)
        sleepers[id] = Sleeper(duration: duration, continuation: continuation)
        lock.unlock()
    }

    func cancel(id: UUID) {
        lock.lock()
        sleeperOrder.removeAll { $0 == id }
        let sleeper = sleepers.removeValue(forKey: id)
        if sleeper == nil {
            cancelledIDs.insert(id)
        }
        lock.unlock()
        sleeper?.continuation.resume(throwing: CancellationError())
    }

    func popNext() -> (duration: Duration, continuation: CheckedContinuation<Void, Error>)? {
        lock.lock()
        defer { lock.unlock() }
        guard let id = sleeperOrder.first else { return nil }
        sleeperOrder.removeFirst()
        guard let sleeper = sleepers.removeValue(forKey: id) else { return nil }
        return (sleeper.duration, sleeper.continuation)
    }
}
