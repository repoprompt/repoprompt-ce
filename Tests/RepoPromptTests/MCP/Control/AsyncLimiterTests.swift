import Foundation
@testable import RepoPrompt
import XCTest

#if DEBUG
    final class AsyncLimiterTests: XCTestCase {
        func testCancelledMiddleWaiterDetachesPromptlyAndLiveWaitersRemainFIFO() async throws {
            let limiter = AsyncLimiter(limit: 1)
            let holderGate = LimiterTestGate()
            let recorder = LimiterOrderRecorder()
            let snapshots = LimiterSnapshotSignal()
            await limiter.setDebugStateObserver { snapshot in
                Task { await snapshots.record(snapshot) }
            }

            let holder = Task {
                try await limiter.withPermit {
                    await holderGate.markStartedAndWaitForRelease()
                }
            }
            await holderGate.waitUntilStarted()

            let first = Task {
                try await limiter.withPermit {
                    await recorder.append(1)
                }
            }
            _ = await snapshots.waitUntil { $0.waiterCount == 1 }

            let cancelled = Task {
                try await limiter.withPermit {
                    await recorder.append(2)
                }
            }
            _ = await snapshots.waitUntil { $0.waiterCount == 2 }

            let third = Task {
                try await limiter.withPermit {
                    await recorder.append(3)
                }
            }
            _ = await snapshots.waitUntil { $0.waiterCount == 3 }

            cancelled.cancel()
            let afterCancellation = await snapshots.waitUntil {
                $0.waiterCount == 2 && $0.inFlight == 3 && $0.cancelledWaiterCount == 1
            }
            XCTAssertEqual(afterCancellation.activePermitCount, 1)
            await assertCancellation(cancelled)

            await holderGate.release()
            try await holder.value
            try await first.value
            try await third.value

            let values = await recorder.values()
            XCTAssertEqual(values, [1, 3])
            let settled = await snapshots.waitUntil { $0.isIdle }
            assertIdle(settled, cancelledWaiterCount: 1, isClosed: false)
        }

        func testCloseDuringQueuedPermitHandoffRejectsResumedBodyAndRestoresPermit() async throws {
            let limiter = AsyncLimiter(limit: 1)
            let holderGate = LimiterTestGate()
            let handoffGate = LimiterTestGate()
            let waiterBodyRan = LimiterTestFlag()
            await limiter.setDebugQueuedPermitHandoffHandler {
                await handoffGate.markStartedAndWaitForRelease()
            }

            let holder = Task {
                try await limiter.withPermit {
                    await holderGate.markStartedAndWaitForRelease()
                }
            }
            await holderGate.waitUntilStarted()

            let waiter = Task {
                try await limiter.withPermit {
                    await waiterBodyRan.mark()
                }
            }
            let snapshots = LimiterSnapshotSignal()
            await limiter.setDebugStateObserver { snapshot in
                Task { await snapshots.record(snapshot) }
            }
            _ = await snapshots.waitUntil { $0.waiterCount == 1 }

            await holderGate.release()
            try await holder.value
            await handoffGate.waitUntilStarted()

            let close = Task {
                await limiter.cancelAll()
                return await limiter.waitUntilIdle()
            }
            _ = await snapshots.waitUntil { $0.isClosed && $0.activePermitCount == 1 }
            await handoffGate.release()

            await assertCancellation(waiter)
            let closeDrained = await close.value
            XCTAssertTrue(closeDrained)
            let didRunWaiterBody = await waiterBodyRan.isMarked()
            XCTAssertFalse(didRunWaiterBody)
            let settled = await limiter.debugSnapshot()
            assertIdle(settled, cancelledWaiterCount: 0, isClosed: true)
            await limiter.setDebugQueuedPermitHandoffHandler(nil)
        }

        func testConnectionRemovalBoundsCancellationInsensitiveOwnerAndDropsLimiter() async throws {
            let manager = ServerNetworkManager.shared
            let connectionID = UUID()
            let cleanupDeadlineGate = LimiterTestGate()
            let limiter = await manager.debugInstallConnectionLimiterForTesting(
                connectionID: connectionID,
                idleWaitSleep: { _ in
                    await cleanupDeadlineGate.markStartedAndWaitForRelease()
                }
            )
            let holderGate = LimiterTestGate()
            let queuedBodyRan = LimiterTestFlag()
            let removalCompleted = LimiterTestFlag()
            let snapshots = LimiterSnapshotSignal()
            await limiter.setDebugStateObserver { snapshot in
                Task { await snapshots.record(snapshot) }
            }

            let holder = Task {
                try await limiter.withPermit {
                    await holderGate.markStartedAndWaitForRelease()
                }
            }
            await holderGate.waitUntilStarted()

            let queued = Task {
                try await limiter.withPermit {
                    await queuedBodyRan.mark()
                }
            }
            _ = await snapshots.waitUntil { $0.waiterCount == 1 }

            let removal = Task {
                await manager.debugRemoveConnection(connectionID)
                await removalCompleted.mark()
            }

            let closed = await snapshots.waitUntil {
                $0.isClosed && $0.waiterCount == 0 && $0.cancelledWaiterCount == 1
            }
            XCTAssertEqual(closed.activePermitCount, 1)
            await assertCancellation(queued)
            let didRunQueuedBody = await queuedBodyRan.isMarked()
            XCTAssertFalse(didRunQueuedBody)
            await cleanupDeadlineGate.waitUntilStarted()
            let didFinishRemovalBeforeDeadline = await removalCompleted.isMarked()
            XCTAssertFalse(didFinishRemovalBeforeDeadline)
            let registeredSnapshot = await manager.connectionLimiterSnapshotForTesting(connectionID: connectionID)
            XCTAssertNil(registeredSnapshot)

            await cleanupDeadlineGate.release()
            await removal.value
            let didFinishRemoval = await removalCompleted.isMarked()
            XCTAssertTrue(didFinishRemoval)
            let detached = await limiter.debugSnapshot()
            XCTAssertTrue(detached.isClosed)
            XCTAssertEqual(detached.activePermitCount, 1)
            XCTAssertEqual(detached.inFlight, 1)
            XCTAssertFalse(detached.isIdle)

            await holderGate.release()
            try await holder.value
            let eventuallyDrained = await limiter.waitUntilIdle()
            XCTAssertTrue(eventuallyDrained)
            let settled = await limiter.debugSnapshot()
            assertIdle(settled, cancelledWaiterCount: 1, isClosed: true)
        }

        private func assertCancellation(_ task: Task<Void, Error>, file: StaticString = #filePath, line: UInt = #line) async {
            do {
                try await task.value
                XCTFail("Expected CancellationError", file: file, line: line)
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("Expected CancellationError, got \(error)", file: file, line: line)
            }
        }

        private func assertIdle(
            _ snapshot: AsyncLimiter.DebugSnapshot,
            cancelledWaiterCount: Int,
            isClosed: Bool,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertEqual(snapshot.permits, 1, file: file, line: line)
            XCTAssertEqual(snapshot.activePermitCount, 0, file: file, line: line)
            XCTAssertEqual(snapshot.waiterCount, 0, file: file, line: line)
            XCTAssertEqual(snapshot.inFlight, 0, file: file, line: line)
            XCTAssertEqual(snapshot.cancelledWaiterCount, cancelledWaiterCount, file: file, line: line)
            XCTAssertEqual(snapshot.isClosed, isClosed, file: file, line: line)
            XCTAssertTrue(snapshot.isIdle, file: file, line: line)
        }
    }

    private actor LimiterTestGate {
        private var started = false
        private var released = false
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markStartedAndWaitForRelease() async {
            started = true
            let startedWaiters = startedWaiters
            self.startedWaiters.removeAll()
            for waiter in startedWaiters {
                waiter.resume()
            }
            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                startedWaiters.append(continuation)
            }
        }

        func release() {
            guard !released else { return }
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    private actor LimiterOrderRecorder {
        private var recordedValues: [Int] = []

        func append(_ value: Int) {
            recordedValues.append(value)
        }

        func values() -> [Int] {
            recordedValues
        }
    }

    private actor LimiterTestFlag {
        private var marked = false

        func mark() {
            marked = true
        }

        func isMarked() -> Bool {
            marked
        }
    }

    private actor LimiterSnapshotSignal {
        typealias Snapshot = AsyncLimiter.DebugSnapshot

        private var latest: Snapshot?
        private var waiter: (
            predicate: @Sendable (Snapshot) -> Bool,
            continuation: CheckedContinuation<Snapshot, Never>
        )?

        func record(_ snapshot: Snapshot) {
            latest = snapshot
            guard let waiter, waiter.predicate(snapshot) else { return }
            self.waiter = nil
            waiter.continuation.resume(returning: snapshot)
        }

        func waitUntil(
            _ predicate: @escaping @Sendable (Snapshot) -> Bool
        ) async -> Snapshot {
            if let latest, predicate(latest) {
                return latest
            }
            return await withCheckedContinuation { continuation in
                waiter = (predicate, continuation)
            }
        }
    }
#endif
