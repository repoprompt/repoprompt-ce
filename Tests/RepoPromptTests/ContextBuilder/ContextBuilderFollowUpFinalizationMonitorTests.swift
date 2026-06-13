import Foundation
@testable import RepoPrompt
import XCTest

final class ContextBuilderFollowUpFinalizationMonitorTests: XCTestCase {
    func testInjectedClockResetsInactivityOnlyForMeaningfulActivity() async {
        let configuration = ContextBuilderFollowUpFinalizationConfiguration(
            overallTimeout: 100,
            inactivityTimeout: 10,
            checkInterval: 1
        )
        let state = ContextBuilderFollowUpFinalizationState(startedAt: 0)

        let initialTimeout = await state.timeoutSnapshot(at: 9, configuration: configuration)
        XCTAssertNil(initialTimeout)

        let watchdogUpdate = await state.record(
            OracleMessageLifecycleActivityEvent(kind: .finalizationWatchdogFired),
            at: 9
        )
        XCTAssertEqual(watchdogUpdate.phase, .streaming)
        let timeoutBeforeDeadline = await state.timeoutSnapshot(at: 9.5, configuration: configuration)
        XCTAssertNil(timeoutBeforeDeadline)

        let timeoutWithoutMeaningfulActivity = await state.timeoutSnapshot(
            at: 10,
            configuration: configuration
        )
        XCTAssertEqual(timeoutWithoutMeaningfulActivity?.kind, .inactivity)
        XCTAssertEqual(timeoutWithoutMeaningfulActivity?.lastEvent, "Oracle finalization watchdog fired")

        let finalizationUpdate = await state.record(
            OracleMessageLifecycleActivityEvent(kind: .providerStopObserved),
            at: 10
        )
        XCTAssertTrue(finalizationUpdate.shouldTransitionToFinalization)
        XCTAssertEqual(finalizationUpdate.phase, .messageFinalization)
        let timeoutBeforeFinalizationDeadline = await state.timeoutSnapshot(
            at: 19.9,
            configuration: configuration
        )
        XCTAssertNil(timeoutBeforeFinalizationDeadline)

        let timeoutAfterFinalizationStalls = await state.timeoutSnapshot(
            at: 20,
            configuration: configuration
        )
        XCTAssertEqual(timeoutAfterFinalizationStalls?.kind, .inactivity)
        XCTAssertEqual(
            timeoutAfterFinalizationStalls?.lastKnownSubphase,
            ContextBuilderMCPProgressPhase.messageFinalization.displayName
        )
    }

    func testStalledFakeQueryTimesOutWithAttributedSubphaseAndCancelsStream() async {
        let clock = ContextBuilderFinalizationTestClock()
        let cancellationRecorder = ContextBuilderFinalizationCancellationRecorder()
        let (events, continuation) = AsyncStream<OracleMessageLifecycleActivityEvent>.makeStream()
        defer { continuation.finish() }

        do {
            try await ContextBuilderFollowUpFinalizationMonitor.wait(
                activityEvents: events,
                configuration: ContextBuilderFollowUpFinalizationConfiguration(
                    overallTimeout: 100,
                    inactivityTimeout: 10,
                    checkInterval: 5
                ),
                clock: { clock.now() },
                sleep: { seconds in
                    clock.advance(by: seconds)
                    await Task.yield()
                },
                waitForFinalization: {
                    try await Task.sleep(for: .seconds(60))
                },
                cancelStreaming: {
                    await cancellationRecorder.recordCancellation()
                }
            )
            XCTFail("Expected an inactivity timeout")
        } catch is CancellationError {
            XCTFail("Expected an attributed timeout, not cancellation")
        } catch {
            let description = error.localizedDescription
            XCTAssertTrue(description.contains("no streaming/finalization activity"), description)
            XCTAssertTrue(description.contains("Oracle response streaming"), description)
        }

        let cancellationCount = await cancellationRecorder.count()
        XCTAssertEqual(cancellationCount, 1)
    }

    func testTimeoutOutcomeWinsWhenCancellationAlsoCompletesFinalization() async {
        let clock = ContextBuilderFinalizationTestClock()
        let finalizationGate = ContextBuilderCancellableFinalizationGate()
        let cancellationDelay = ContextBuilderFinalizationTestGate()
        let cancellationStarted = expectation(description: "stream cancellation started")
        let (events, continuation) = AsyncStream<OracleMessageLifecycleActivityEvent>.makeStream()
        defer { continuation.finish() }

        let monitor = Task { () -> Result<Void, Error> in
            do {
                try await ContextBuilderFollowUpFinalizationMonitor.wait(
                    activityEvents: events,
                    configuration: ContextBuilderFollowUpFinalizationConfiguration(
                        overallTimeout: 100,
                        inactivityTimeout: 10,
                        checkInterval: 10
                    ),
                    clock: { clock.now() },
                    sleep: { seconds in
                        clock.advance(by: seconds)
                        await Task.yield()
                    },
                    waitForFinalization: {
                        try await finalizationGate.wait()
                    },
                    cancelStreaming: {
                        await finalizationGate.complete()
                        cancellationStarted.fulfill()
                        await cancellationDelay.arriveAndWait()
                    }
                )
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        await fulfillment(of: [cancellationStarted], timeout: 1)
        await cancellationDelay.release()

        switch await monitor.value {
        case .success:
            XCTFail("Timeout must remain authoritative after cancellation completes finalization")
        case let .failure(error):
            let description = error.localizedDescription
            XCTAssertTrue(description.contains("no streaming/finalization activity"), description)
        }
    }

    func testFastFinalizationStillReportsMessageFinalizationPhase() async throws {
        let recorder = ContextBuilderFinalizationProgressRecorder()
        let (events, continuation) = AsyncStream<OracleMessageLifecycleActivityEvent>.makeStream()
        defer { continuation.finish() }

        try await ContextBuilderFollowUpFinalizationMonitor.wait(
            activityEvents: events,
            configuration: ContextBuilderFollowUpFinalizationConfiguration(
                overallTimeout: 100,
                inactivityTimeout: 10,
                checkInterval: 60
            ),
            waitForFinalization: {},
            cancelStreaming: {},
            reportPhase: { phase in
                await recorder.recordPhase(phase)
            }
        )

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.phases, [.messageFinalization])
    }

    func testOracleWatchdogAndFinalizationEventsReachProgressCallbacks() async throws {
        let activityExpectation = expectation(description: "Oracle activity events reported")
        activityExpectation.expectedFulfillmentCount = 2
        let finalizationPhaseExpectation = expectation(description: "Finalization phase reported")
        let recorder = ContextBuilderFinalizationProgressRecorder()
        let finalizationGate = ContextBuilderFinalizationTestGate()
        let (events, continuation) = AsyncStream<OracleMessageLifecycleActivityEvent>.makeStream()
        continuation.yield(OracleMessageLifecycleActivityEvent(kind: .finalizationWatchdogArmed))
        continuation.yield(OracleMessageLifecycleActivityEvent(kind: .providerStopObserved))

        let monitor = Task {
            try await ContextBuilderFollowUpFinalizationMonitor.wait(
                activityEvents: events,
                configuration: ContextBuilderFollowUpFinalizationConfiguration(
                    overallTimeout: 100,
                    inactivityTimeout: 10,
                    checkInterval: 60
                ),
                waitForFinalization: {
                    await finalizationGate.arriveAndWait()
                },
                cancelStreaming: {},
                reportPhase: { phase in
                    await recorder.recordPhase(phase)
                    finalizationPhaseExpectation.fulfill()
                },
                reportActivity: { phase, message in
                    await recorder.recordActivity(phase: phase, message: message)
                    activityExpectation.fulfill()
                }
            )
        }

        await fulfillment(of: [activityExpectation, finalizationPhaseExpectation], timeout: 1)
        await finalizationGate.release()
        continuation.finish()
        try await monitor.value

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.phases, [.messageFinalization])
        XCTAssertEqual(snapshot.activities.map(\.phase), [.streaming, .messageFinalization])
        XCTAssertEqual(snapshot.activities.map(\.message), [
            "Oracle finalization watchdog armed",
            "Oracle provider stop observed"
        ])
    }
}

private final class ContextBuilderFinalizationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value += interval
        lock.unlock()
    }
}

private actor ContextBuilderFinalizationCancellationRecorder {
    private var cancellationCount = 0

    func recordCancellation() {
        cancellationCount += 1
    }

    func count() -> Int {
        cancellationCount
    }
}

private actor ContextBuilderFinalizationProgressRecorder {
    struct Activity: Equatable {
        let phase: ContextBuilderMCPProgressPhase
        let message: String
    }

    private var phases: [ContextBuilderMCPProgressPhase] = []
    private var activities: [Activity] = []

    func recordPhase(_ phase: ContextBuilderMCPProgressPhase) {
        phases.append(phase)
    }

    func recordActivity(phase: ContextBuilderMCPProgressPhase, message: String) {
        activities.append(Activity(phase: phase, message: message))
    }

    func snapshot() -> (phases: [ContextBuilderMCPProgressPhase], activities: [Activity]) {
        (phases, activities)
    }
}

private actor ContextBuilderCancellableFinalizationGate {
    private var completed = false
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task { await self.register(continuation) }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
        try Task.checkCancellation()
    }

    func complete() {
        completed = true
        continuation?.resume()
        continuation = nil
    }

    private func register(_ continuation: CheckedContinuation<Void, Never>) {
        if completed || cancelled {
            continuation.resume()
        } else {
            self.continuation = continuation
        }
    }

    private func cancel() {
        cancelled = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ContextBuilderFinalizationTestGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume()
        }
    }
}
