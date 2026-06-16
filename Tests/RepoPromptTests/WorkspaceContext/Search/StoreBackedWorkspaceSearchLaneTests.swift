@testable import RepoPrompt
import XCTest

#if DEBUG
    final class StoreBackedWorkspaceSearchLaneTests: XCTestCase {
        func testProductionPolicyAdmitsBoundedBurstWithBoundedWait() {
            let configuration = StoreBackedWorkspaceSearchLane.Configuration.production
            XCTAssertEqual(configuration.maxActiveLeases, 4)
            XCTAssertEqual(configuration.maxQueuedWaiters, 4)
            XCTAssertEqual(configuration.maxQueueWaitMilliseconds, 1500)
            XCTAssertEqual(configuration.retryAfterMilliseconds, 1000)
        }

        func testProductionBurstAdmitsActiveBatchQueuesOverflowAndRejectsBeyondQueue() async throws {
            let lane = StoreBackedWorkspaceSearchLane()
            let configuration = StoreBackedWorkspaceSearchLane.Configuration.production
            let gate = AsyncGate()
            await lane.setPermitAcquiredHandlerForTesting {
                await gate.markStartedAndWaitForRelease()
            }

            var activeBatch: [Task<Int, Error>] = []
            for value in 1 ... configuration.maxActiveLeases {
                activeBatch.append(permitTask(lane: lane, value: value))
            }
            await assertTrue(gate.waitUntilStartedCount(configuration.maxActiveLeases))

            var queuedBatch: [Task<Int, Error>] = []
            for value in 1 ... configuration.maxQueuedWaiters {
                queuedBatch.append(permitTask(lane: lane, value: 100 + value))
            }
            await assertTrue(waitForSnapshot(lane) { $0.waiterCount == configuration.maxQueuedWaiters })

            let overflow = permitTask(lane: lane, value: 999)
            await assertQueueFull(overflow)

            let held = await lane.snapshotForTesting()
            XCTAssertEqual(held.activePermitCount, configuration.maxActiveLeases)
            XCTAssertEqual(held.waiterCount, configuration.maxQueuedWaiters)
            XCTAssertEqual(held.overloadCount, 1)
            XCTAssertEqual(held.maximumActivePermitCount, configuration.maxActiveLeases)
            XCTAssertEqual(held.maximumWaiterCount, configuration.maxQueuedWaiters)

            await gate.release()
            for (index, task) in activeBatch.enumerated() {
                let value = try await task.value
                XCTAssertEqual(value, index + 1)
            }
            for (index, task) in queuedBatch.enumerated() {
                let value = try await task.value
                XCTAssertEqual(value, 101 + index)
            }
            let settled = await lane.snapshotForTesting()
            XCTAssertTrue(settled.isIdle)
            XCTAssertEqual(settled.grantCount, configuration.maxActiveLeases + configuration.maxQueuedWaiters)
        }

        func testOneActiveOneQueuedAndThirdRejectedThenLaneReturnsIdle() async throws {
            let lane = StoreBackedWorkspaceSearchLane(
                configuration: .init(maxQueueWait: .milliseconds(1500))
            )
            let gate = AsyncGate()
            await lane.setPermitAcquiredHandlerForTesting {
                await gate.markStartedAndWaitForRelease()
            }

            let first = permitTask(lane: lane, value: 1)
            await assertTrue(gate.waitUntilStartedCount(1))
            let second = permitTask(lane: lane, value: 2)
            await assertTrue(waitForSnapshot(lane) { $0.waiterCount == 1 })
            let third = permitTask(lane: lane, value: 3)
            await assertQueueFull(third)

            let held = await lane.snapshotForTesting()
            XCTAssertEqual(held.activePermitCount, 1)
            XCTAssertEqual(held.waiterCount, 1)
            XCTAssertEqual(held.overloadCount, 1)
            XCTAssertEqual(held.maximumActivePermitCount, 1)
            XCTAssertEqual(held.maximumWaiterCount, 1)

            await gate.release()
            let firstValue = try await first.value
            let secondValue = try await second.value
            XCTAssertEqual(firstValue, 1)
            XCTAssertEqual(secondValue, 2)
            let settled = await lane.snapshotForTesting()
            XCTAssertTrue(settled.isIdle)
            XCTAssertEqual(settled.grantCount, 2)
        }

        func testQueuedCancellationRemovesWaiterWithoutLeakingLane() async throws {
            let lane = StoreBackedWorkspaceSearchLane(
                configuration: .init(maxQueueWait: .milliseconds(1500))
            )
            let gate = AsyncGate()
            await lane.setPermitAcquiredHandlerForTesting {
                await gate.markStartedAndWaitForRelease()
            }

            let active = permitTask(lane: lane, value: 1)
            await assertTrue(gate.waitUntilStartedCount(1))
            let queued = permitTask(lane: lane, value: 2)
            await assertTrue(waitForSnapshot(lane) { $0.waiterCount == 1 })
            queued.cancel()
            do {
                _ = try await queued.value
                XCTFail("Expected queued cancellation")
            } catch is CancellationError {
                // Expected.
            }
            await assertTrue(waitForSnapshot(lane) { $0.waiterCount == 0 })

            await gate.release()
            let activeValue = try await active.value
            XCTAssertEqual(activeValue, 1)
            let settled = await lane.snapshotForTesting()
            XCTAssertTrue(settled.isIdle)
            XCTAssertEqual(settled.queuedCancellationCount, 1)
        }

        func testQueuedWaitExpiresAndLaneReturnsIdle() async throws {
            let lane = StoreBackedWorkspaceSearchLane(
                configuration: .init(maxQueueWait: .milliseconds(25), retryAfterMilliseconds: 321)
            )
            let gate = AsyncGate()
            await lane.setPermitAcquiredHandlerForTesting {
                await gate.markStartedAndWaitForRelease()
            }

            let active = permitTask(lane: lane, value: 1)
            await assertTrue(gate.waitUntilStartedCount(1))
            let queued = permitTask(lane: lane, value: 2)
            do {
                _ = try await queued.value
                XCTFail("Expected queue expiry")
            } catch let error as StoreBackedWorkspaceSearchAdmissionError {
                XCTAssertEqual(error, .waitExpired(retryAfterMilliseconds: 321))
            }

            await gate.release()
            let activeValue = try await active.value
            XCTAssertEqual(activeValue, 1)
            let settled = await lane.snapshotForTesting()
            XCTAssertTrue(settled.isIdle)
            XCTAssertEqual(settled.waitExpiryCount, 1)
        }

        func testCancellationAfterPermitAcquisitionReleasesActiveLease() async throws {
            let lane = StoreBackedWorkspaceSearchLane()
            let gate = AsyncGate()
            await lane.setPermitAcquiredHandlerForTesting {
                await gate.markStartedAndWaitForRelease()
            }

            let active = permitTask(lane: lane, value: 1)
            await assertTrue(gate.waitUntilStartedCount(1))
            active.cancel()
            await gate.release()
            do {
                _ = try await active.value
                XCTFail("Expected active cancellation")
            } catch is CancellationError {
                // Expected.
            }
            let settled = await lane.snapshotForTesting()
            XCTAssertTrue(settled.isIdle)
        }

        func testBypassAccessDoesNotWaitForHeldBroadPermit() async throws {
            let lane = StoreBackedWorkspaceSearchLane()
            let gate = AsyncGate()
            await lane.setPermitAcquiredHandlerForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            let active = permitTask(lane: lane, value: 1)
            await assertTrue(gate.waitUntilStartedCount(1))

            let bypass = try await lane.withSearchAccess(searchMode: .path, admissionClass: nil) { _ in 7 }
            XCTAssertEqual(bypass, 7)
            let held = await lane.snapshotForTesting()
            XCTAssertEqual(held.activePermitCount, 1)
            XCTAssertEqual(held.waiterCount, 0)

            await gate.release()
            let activeValue = try await active.value
            XCTAssertEqual(activeValue, 1)
            let settled = await lane.snapshotForTesting()
            XCTAssertTrue(settled.isIdle)
        }

        func testThrownOperationReleasesLease() async {
            enum Expected: Error { case failure }
            let lane = StoreBackedWorkspaceSearchLane()
            do {
                let _: Int = try await lane.withSearchAccess(
                    searchMode: .content,
                    admissionClass: .unscopedContent
                ) { _ in
                    throw Expected.failure
                }
                XCTFail("Expected operation failure")
            } catch Expected.failure {
                // Expected.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            let settled = await lane.snapshotForTesting()
            XCTAssertTrue(settled.isIdle)
        }

        func testDebugConfigurationIsIdleOnly() async throws {
            let lane = StoreBackedWorkspaceSearchLane()
            let gate = AsyncGate()
            await lane.setPermitAcquiredHandlerForTesting {
                await gate.markStartedAndWaitForRelease()
            }
            let active = permitTask(lane: lane, value: 1)
            await assertTrue(gate.waitUntilStartedCount(1))

            let replacement = StoreBackedWorkspaceSearchLane.Configuration(
                maxQueueWait: .milliseconds(750),
                retryAfterMilliseconds: 222
            )
            guard case let .busy(snapshot) = await lane.configureForTesting(replacement) else {
                await gate.release()
                _ = try? await active.value
                return XCTFail("Busy lane must reject DEBUG configuration")
            }
            XCTAssertEqual(snapshot.configuration, .production)

            await gate.release()
            _ = try await active.value
            guard case let .applied(applied) = await lane.configureForTesting(replacement) else {
                return XCTFail("Idle lane should accept DEBUG configuration")
            }
            XCTAssertEqual(applied.configuration, replacement)
            XCTAssertTrue(applied.isIdle)
        }

        private func permitTask(
            lane: StoreBackedWorkspaceSearchLane,
            value: Int
        ) -> Task<Int, Error> {
            Task {
                try await lane.withSearchAccess(
                    searchMode: .content,
                    admissionClass: .unscopedContent
                ) { _ in
                    value
                }
            }
        }

        private func assertQueueFull(
            _ task: Task<Int, Error>,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                _ = try await task.value
                XCTFail("Expected queue-full error", file: file, line: line)
            } catch let error as StoreBackedWorkspaceSearchAdmissionError {
                XCTAssertEqual(
                    error,
                    .queueFull(scope: .perStore, retryAfterMilliseconds: 1000),
                    file: file,
                    line: line
                )
            } catch {
                XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        }

        private func assertTrue(
            _ value: Bool,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertTrue(value, file: file, line: line)
        }

        private func waitForSnapshot(
            _ lane: StoreBackedWorkspaceSearchLane,
            timeoutNanoseconds: UInt64 = 1_000_000_000,
            predicate: (StoreBackedWorkspaceSearchLane.Snapshot) -> Bool
        ) async -> Bool {
            let interval: UInt64 = 5_000_000
            var waited: UInt64 = 0
            while waited < timeoutNanoseconds {
                if await predicate(lane.snapshotForTesting()) { return true }
                try? await Task.sleep(nanoseconds: interval)
                waited += interval
            }
            return await predicate(lane.snapshotForTesting())
        }
    }

    private actor AsyncGate {
        private var startedCount = 0
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markStartedAndWaitForRelease() async {
            startedCount += 1
            if released { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilStartedCount(
            _ expectedCount: Int,
            timeoutNanoseconds: UInt64 = 1_000_000_000
        ) async -> Bool {
            let interval: UInt64 = 5_000_000
            var waited: UInt64 = 0
            while startedCount < expectedCount, waited < timeoutNanoseconds {
                try? await Task.sleep(nanoseconds: interval)
                waited += interval
            }
            return startedCount >= expectedCount
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
#endif
