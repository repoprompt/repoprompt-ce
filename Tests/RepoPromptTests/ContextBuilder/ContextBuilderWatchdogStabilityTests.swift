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

    func releaseForTestCleanup() {
        let pending = continuation
        continuation = nil
        // Even a successful response caused by teardown must not overwrite the
        // already-selected timeout outcome.
        pending?.resume(returning: "late response")
    }
}
