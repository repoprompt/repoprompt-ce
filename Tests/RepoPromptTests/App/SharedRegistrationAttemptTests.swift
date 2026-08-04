@testable import RepoPromptApp
import XCTest

@MainActor
final class SharedRegistrationAttemptTests: XCTestCase {
    private enum TestFailure: Error {
        case expected
    }

    private actor SuspensionGate {
        private var entered = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func wait() async {
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { continuation in
                entryWaiters.append(continuation)
            }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    func testCancelledWaiterStillObservesSharedTaskResult() async {
        let coordinator = SharedRegistrationAttempt<Int>()
        let gate = SuspensionGate()
        let attempt = coordinator.start {
            await gate.wait()
            return 7
        }
        let waiter = Task { @MainActor in
            await coordinator.complete(attempt)
        }

        await gate.waitUntilEntered()
        waiter.cancel()
        await gate.release()

        let completion = await waiter.value
        XCTAssertTrue(completion.wasCurrent)
        switch completion.result {
        case let .success(value):
            XCTAssertEqual(value, 7)
        case let .failure(error):
            XCTFail("Expected shared success after waiter cancellation, got \(error)")
        }
        XCTAssertNil(coordinator.current)
    }

    func testStaleFailureCompletionCannotClearNewAttempt() async {
        let coordinator = SharedRegistrationAttempt<Int>()
        let failedAttempt = coordinator.start {
            throw TestFailure.expected
        }

        let firstCompletion = await coordinator.complete(failedAttempt)
        XCTAssertTrue(firstCompletion.wasCurrent)
        guard case let .failure(error) = firstCompletion.result,
              error is TestFailure
        else {
            return XCTFail("Expected the first attempt to fail")
        }

        let gate = SuspensionGate()
        let currentAttempt = coordinator.start {
            await gate.wait()
            return 11
        }
        await gate.waitUntilEntered()

        let staleCompletion = await coordinator.complete(failedAttempt)
        XCTAssertFalse(staleCompletion.wasCurrent)
        XCTAssertEqual(coordinator.current?.id, currentAttempt.id)

        await gate.release()
        let currentCompletion = await coordinator.complete(currentAttempt)
        XCTAssertTrue(currentCompletion.wasCurrent)
        guard case let .success(value) = currentCompletion.result else {
            return XCTFail("Expected the current attempt to succeed")
        }
        XCTAssertEqual(value, 11)
        XCTAssertNil(coordinator.current)
    }
}
