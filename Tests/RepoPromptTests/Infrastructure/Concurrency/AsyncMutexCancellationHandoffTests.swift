import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AsyncMutexCancellationHandoffTests: XCTestCase {
    private func requireFulfillment(
        of expectations: [XCTestExpectation],
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let result = await XCTWaiter.fulfillment(of: expectations, timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected asynchronous work to settle", file: file, line: line)
    }

    func testCancellationAfterDequeueSkipsBodyAndReleasesGrantToLiveWaiters() async {
        let mutex = AsyncMutex()
        let gate = MutexHandoffGate()
        let log = MutexHandoffLog()
        let ownerEntered = expectation(description: "owner entered")
        let ownerDone = expectation(description: "owner finished")
        let owner = Task {
            defer { ownerDone.fulfill() }
            try? await mutex.withLock {
                ownerEntered.fulfill()
                await gate.wait()
            }
        }
        defer { owner.cancel() }
        await requireFulfillment(of: [ownerEntered], timeout: 3)

        let cancelledDone = expectation(description: "cancelled waiter finished")
        let cancelled = Task {
            defer { cancelledDone.fulfill() }
            do {
                try await mutex.withLock { await log.enter("cancelled") }
            } catch is CancellationError {
                await log.recordCancellation()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        defer { cancelled.cancel() }
        await requireQueued(1, in: mutex)

        let firstDone = expectation(description: "first live waiter finished")
        let first = Task {
            defer { firstDone.fulfill() }
            do {
                try await mutex.withLock { await log.enter("first") }
            } catch {
                XCTFail("Live waiter failed: \(error)")
            }
        }
        defer { first.cancel() }
        await requireQueued(2, in: mutex)

        let secondDone = expectation(description: "second live waiter finished")
        let second = Task {
            defer { secondDone.fulfill() }
            do {
                try await mutex.withLock { await log.enter("second") }
            } catch {
                XCTFail("Live waiter failed: \(error)")
            }
        }
        defer { second.cancel() }
        await requireQueued(3, in: mutex)

        // unlock has removed the waiter, but has not yet resumed its continuation.
        // The cancellation-removal task cannot win: unlock still owns the actor.
        await mutex.setWillResumeNextWaiterForTesting { cancelled.cancel() }
        await gate.open()
        await requireFulfillment(of: [ownerDone, cancelledDone, firstDone, secondDone], timeout: 3)

        let bodies = await log.bodies
        let cancellations = await log.cancellations
        let remaining = await mutex.queuedWaiterCountForTesting
        XCTAssertEqual(bodies, ["first", "second"])
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(remaining, 0)
    }

    func testQueuedCancellationSettlesWithoutWaitingForOwner() async {
        let mutex = AsyncMutex()
        let gate = MutexHandoffGate()
        let log = MutexHandoffLog()
        let ownerEntered = expectation(description: "owner entered")
        let ownerDone = expectation(description: "owner finished")
        let owner = Task {
            defer { ownerDone.fulfill() }
            try? await mutex.withLock {
                ownerEntered.fulfill()
                await gate.wait()
            }
        }
        defer { owner.cancel() }
        await requireFulfillment(of: [ownerEntered], timeout: 3)

        let waiterDone = expectation(description: "cancelled waiter finished while owner holds lock")
        let waiter = Task {
            defer { waiterDone.fulfill() }
            do {
                try await mutex.withLock { await log.enter("cancelled") }
            } catch is CancellationError {
                await log.recordCancellation()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        defer { waiter.cancel() }
        await requireQueued(1, in: mutex)
        waiter.cancel()
        await requireFulfillment(of: [waiterDone], timeout: 3)
        let bodies = await log.bodies
        let cancellations = await log.cancellations
        XCTAssertTrue(bodies.isEmpty)
        XCTAssertEqual(cancellations, 1)

        await gate.open()
        await requireFulfillment(of: [ownerDone], timeout: 3)
    }

    func testAlreadyCancelledAcquisitionDoesNotEnterBody() async {
        let mutex = AsyncMutex()
        let log = MutexHandoffLog()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await mutex.withLock { await log.enter("cancelled") }
            } catch is CancellationError {
                await log.recordCancellation()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        await task.value
        let bodies = await log.bodies
        let cancellations = await log.cancellations
        XCTAssertTrue(bodies.isEmpty)
        XCTAssertEqual(cancellations, 1)
        do {
            try await mutex.withLock { await log.enter("next") }
        } catch {
            XCTFail("Mutex did not remain usable: \(error)")
        }
    }

    func testCancelledCleanupStillWaitsForAndAcquiresOwnedMutex() async {
        let mutex = AsyncMutex()
        let gate = MutexHandoffGate()
        let log = MutexHandoffLog()
        let ownerEntered = expectation(description: "owner entered")
        let ownerDone = expectation(description: "owner finished")
        let owner = Task {
            defer { ownerDone.fulfill() }
            try? await mutex.withLock {
                ownerEntered.fulfill()
                await gate.wait()
            }
        }
        defer { owner.cancel() }
        await requireFulfillment(of: [ownerEntered], timeout: 3)

        let cleanupDone = expectation(description: "required cleanup finished")
        let cleanup = Task {
            defer { cleanupDone.fulfill() }
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await mutex.withLockIgnoringCancellation { await log.enter("cleanup") }
            } catch {
                XCTFail("Required cleanup failed: \(error)")
            }
        }
        defer { cleanup.cancel() }
        await requireQueued(1, in: mutex)
        let beforeRelease = await log.bodies
        XCTAssertTrue(beforeRelease.isEmpty)
        await gate.open()
        await requireFulfillment(of: [ownerDone, cleanupDone], timeout: 3)
        let bodies = await log.bodies
        XCTAssertEqual(bodies, ["cleanup"])
    }

    func testThrowingBodyReleasesOwnership() async {
        let mutex = AsyncMutex()
        do {
            try await mutex.withLock { throw MutexHandoffFailure.expected }
            XCTFail("Expected body failure")
        } catch MutexHandoffFailure.expected {
            // The error must not retain the mutex grant.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        do {
            let result = try await mutex.withLock { "reused" }
            XCTAssertEqual(result, "reused")
        } catch {
            XCTFail("Mutex did not release ownership: \(error)")
        }
    }

    private func requireQueued(
        _ count: Int,
        in mutex: AsyncMutex,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await mutex.queuedWaiterCountForTesting == count { return }
            await Task.yield()
        }
        XCTFail("Expected \(count) queued mutex waiters", file: file, line: line)
    }
}

private actor MutexHandoffGate {
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

private actor MutexHandoffLog {
    private(set) var bodies: [String] = []
    private(set) var cancellations = 0

    func enter(_ label: String) {
        bodies.append(label)
    }

    func recordCancellation() {
        cancellations += 1
    }
}

private enum MutexHandoffFailure: Error {
    case expected
}
