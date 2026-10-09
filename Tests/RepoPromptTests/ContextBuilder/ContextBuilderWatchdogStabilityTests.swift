import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class ContextBuilderWatchdogStabilityTests: XCTestCase {
    private func requireFulfillment(
        of expectations: [XCTestExpectation],
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let result = await XCTWaiter.fulfillment(of: expectations, timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected asynchronous work to settle", file: file, line: line)
    }

    func testTimeoutCancelsBeforeJoiningAndCannotBecomeLateSuccess() async {
        let clock = FollowUpWatchdogClock()
        let tick = FollowUpWatchdogGate()
        let completion = FollowUpCancellationDrivenCompletion()
        let waiting = expectation(description: "completion waiter installed")
        let finished = expectation(description: "timeout settled without external rescue")
        let (events, continuation) = AsyncStream<OracleMessageLifecycleActivityEvent>.makeStream()
        defer { continuation.finish() }
        let task = Task {
            defer { finished.fulfill() }
            do {
                _ = try await ContextBuilderFollowUpFinalizationMonitor.wait(
                    activityEvents: events,
                    configuration: .init(overallTimeout: 100, inactivityTimeout: 10, checkInterval: 1),
                    clock: { clock.now },
                    sleep: { _ in
                        await tick.wait()
                        try Task.checkCancellation()
                    },
                    waitForFinalization: {
                        try await completion.wait(onRegistered: { waiting.fulfill() })
                    },
                    cancelStreaming: { await completion.cancelStream() }
                )
                return "unexpected success"
            } catch let error as ChatToolError {
                return error.message
            } catch {
                return "unexpected error: \(error)"
            }
        }
        defer { task.cancel() }
        await requireFulfillment(of: [waiting], timeout: 3)
        clock.advance(to: 11)
        await tick.open()
        await requireFulfillment(of: [finished], timeout: 3)
        let cancellationCount = await completion.cancellationCount
        XCTAssertEqual(cancellationCount, 1)

        // Bound the regression itself on the broken baseline: release the child
        // only AFTER asserting that the monitor should have settled on its own.
        await completion.releaseForTestCleanup()
        let outcome = await task.value
        XCTAssertTrue(outcome.contains("Follow-up response stalled"), outcome)
        let finalCancellationCount = await completion.cancellationCount
        XCTAssertEqual(finalCancellationCount, 1)
    }

    func testEndedActivityObserverDoesNotDiscardSuccessfulResponse() async throws {
        let (events, continuation) = AsyncStream<OracleMessageLifecycleActivityEvent>.makeStream()
        continuation.finish()
        let completion = FollowUpCancellationDrivenCompletion()
        let response = try await ContextBuilderFollowUpFinalizationMonitor.wait(
            activityEvents: events,
            clock: { 0 },
            waitForFinalization: { "complete response" },
            cancelStreaming: { await completion.cancelStream() }
        )
        XCTAssertEqual(response, "complete response")
        let cancellations = await completion.cancellationCount
        XCTAssertEqual(cancellations, 0)
    }

    func testProviderFailureKeepsExactTypedOutcome() async {
        let (events, continuation) = AsyncStream<OracleMessageLifecycleActivityEvent>.makeStream()
        defer { continuation.finish() }
        let completion = FollowUpCancellationDrivenCompletion()
        let expected = OracleContextBuilderCompletionError.providerStreamFailed(message: "provider rejected request")
        do {
            _ = try await ContextBuilderFollowUpFinalizationMonitor.wait(
                activityEvents: events,
                clock: { 0 },
                waitForFinalization: { throw expected },
                cancelStreaming: { await completion.cancelStream() }
            )
            XCTFail("Expected provider failure")
        } catch let error as OracleContextBuilderCompletionError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Provider error changed: \(error)")
        }
        let cancellations = await completion.cancellationCount
        XCTAssertEqual(cancellations, 0)
    }

    func testCancellationIsNotReportedAsTimeoutOrSuccess() async {
        let (events, continuation) = AsyncStream<OracleMessageLifecycleActivityEvent>.makeStream()
        defer { continuation.finish() }
        let completion = FollowUpCancellationDrivenCompletion()
        do {
            _ = try await ContextBuilderFollowUpFinalizationMonitor.wait(
                activityEvents: events,
                clock: { 0 },
                waitForFinalization: { throw CancellationError() },
                cancelStreaming: { await completion.cancelStream() }
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Existing caller-owned cancellation semantics are unchanged.
        } catch {
            XCTFail("Cancellation was reclassified: \(error)")
        }
        let cancellations = await completion.cancellationCount
        XCTAssertEqual(cancellations, 0)
    }

    /// #803: a silent-but-alive lane renews the budget through transport liveness and
    /// outlives several inactivity budgets without content.
    func testLivenessRenewedLaneOutlivesSeveralInactivityBudgets() async throws {
        let lane = LivenessLaneHarness()
        let waiting = expectation(description: "completion waiter installed")
        let task = lane.start(onRegistered: { waiting.fulfill() })
        defer { task.cancel() }
        await requireFulfillment(of: [waiting], timeout: 3)
        let parked = await eventually { lane.stepper.parkCount == 1 }
        XCTAssertTrue(parked)

        // Liveness every 8s; every check lands 7s after the latest renewal. Total
        // elapsed time reaches 47s against a 10s inactivity budget.
        for beat in 1 ... 5 {
            let renewal = TimeInterval(beat) * 8
            await lane.renew(at: renewal, expectedRecorded: beat)
            let survived = await lane.check(at: renewal + 7, expectedParkCount: beat + 1)
            XCTAssertTrue(survived, "Liveness-renewed lane timed out at beat \(beat)")
        }

        await lane.completion.finish(returning: "final answer")
        lane.stepper.release()
        let response = try await task.value
        XCTAssertEqual(response, "final answer")
        let cancellations = await lane.completion.cancellationCount
        XCTAssertEqual(cancellations, 0)
    }

    /// #803: liveness renews the budget only while it keeps arriving; a lane whose
    /// process or socket dies after being alive still times out and is cancelled.
    func testLaneThatStopsSignallingLivenessStillTimesOut() async throws {
        let lane = LivenessLaneHarness()
        let waiting = expectation(description: "completion waiter installed")
        let task = lane.start(onRegistered: { waiting.fulfill() })
        defer { task.cancel() }
        await requireFulfillment(of: [waiting], timeout: 3)
        let parked = await eventually { lane.stepper.parkCount == 1 }
        XCTAssertTrue(parked)

        await lane.renew(at: 8, expectedRecorded: 1)
        await lane.renew(at: 16, expectedRecorded: 2)
        let survivedJustUnderBudget = await lane.check(at: 25.9, expectedParkCount: 2)
        XCTAssertTrue(survivedJustUnderBudget)

        lane.clock.advance(to: 26)
        lane.stepper.step()
        do {
            _ = try await task.value
            XCTFail("A lane without liveness must time out")
        } catch let error as ChatToolError {
            XCTAssertTrue(error.message.contains("Follow-up response stalled for 10.0s"), error.message)
            XCTAssertTrue(error.message.contains("Last event: Oracle stream activity observed"), error.message)
        }
        let cancellations = await lane.completion.cancellationCount
        XCTAssertEqual(cancellations, 1)
    }

    private func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

/// Drives the follow-up monitor with a manual clock, step-released inactivity
/// checks, and explicitly delivered liveness events.
@MainActor
private final class LivenessLaneHarness {
    let clock = FollowUpWatchdogClock()
    let stepper = FollowUpWatchdogStepper()
    let recorded = FollowUpWatchdogCounter()
    let completion = FollowUpCancellationDrivenCompletion()
    private let events: AsyncStream<OracleMessageLifecycleActivityEvent>
    private let continuation: AsyncStream<OracleMessageLifecycleActivityEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream<OracleMessageLifecycleActivityEvent>.makeStream()
    }

    deinit {
        continuation.finish()
    }

    func start(onRegistered: @escaping @Sendable () -> Void) -> Task<String, Error> {
        let events = events
        let clock = clock
        let stepper = stepper
        let recorded = recorded
        let completion = completion
        return Task {
            try await ContextBuilderFollowUpFinalizationMonitor.wait(
                activityEvents: events,
                configuration: .init(overallTimeout: 1000, inactivityTimeout: 10, checkInterval: 1),
                clock: { clock.now },
                sleep: { _ in try await stepper.sleep() },
                waitForFinalization: { try await completion.wait(onRegistered: onRegistered) },
                cancelStreaming: { await completion.cancelStream() },
                reportActivity: { _, _ in recorded.increment() }
            )
        }
    }

    /// Delivers one transport-liveness event and waits until the monitor records it.
    func renew(at time: TimeInterval, expectedRecorded: Int) async {
        clock.advance(to: time)
        continuation.yield(OracleMessageLifecycleActivityEvent(kind: .streamActivity))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while recorded.count < expectedRecorded, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(recorded.count, expectedRecorded)
    }

    /// Releases one inactivity check at `time`; true when the monitor re-parked (no timeout).
    func check(at time: TimeInterval, expectedParkCount: Int) async -> Bool {
        clock.advance(to: time)
        stepper.step()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while stepper.parkCount < expectedParkCount, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return stepper.parkCount == expectedParkCount
    }
}

/// Each `sleep` parks until one `step()`; cancellation or `release()` wakes it.
private final class FollowUpWatchdogStepper: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: CheckedContinuation<Void, Never>?
    private var parks = 0
    private var released = false

    var parkCount: Int {
        lock.withLock { parks }
    }

    func sleep() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    parks += 1
                    if released || Task.isCancelled { return true }
                    parked = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            self.wake()
        }
        try Task.checkCancellation()
    }

    func step() {
        wake()
    }

    func release() {
        lock.withLock { released = true }
        wake()
    }

    private func wake() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { parked = nil }
            return parked
        }
        continuation?.resume()
    }
}

private final class FollowUpWatchdogCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func increment() {
        lock.withLock { value += 1 }
    }
}

private final class FollowUpWatchdogClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    var now: TimeInterval {
        lock.withLock { value }
    }

    func advance(to time: TimeInterval) {
        lock.withLock { value = time }
    }
}

private actor FollowUpWatchdogGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor FollowUpCancellationDrivenCompletion {
    private var continuation: CheckedContinuation<String, any Error>?
    private(set) var cancellationCount = 0

    func wait(onRegistered: @Sendable () -> Void) async throws -> String {
        try await withCheckedThrowingContinuation {
            continuation = $0
            onRegistered()
        }
    }

    func cancelStream() {
        cancellationCount += 1
        releaseForTestCleanup()
    }

    func finish(returning response: String) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: response)
    }

    func releaseForTestCleanup() {
        let pending = continuation
        continuation = nil
        // Even a successful response caused by teardown must not overwrite the
        // already-selected timeout outcome.
        pending?.resume(returning: "late response")
    }
}
