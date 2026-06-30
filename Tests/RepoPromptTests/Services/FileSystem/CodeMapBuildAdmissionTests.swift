import Foundation
@testable import RepoPrompt
import XCTest

final class CodeMapBuildAdmissionTests: XCTestCase {
    #if DEBUG
        func testProcessWideCodemapBuildAdmissionWaitsForForegroundActivityAndUsesRequestedPriority() async throws {
            let foregroundGate = CodeMapAdmissionGate()
            let operationStarted = CodeMapAdmissionSignal()
            let foreground = Task {
                await FileSystemService.withContentReadForegroundActivity(kind: .rootLoad) {
                    await foregroundGate.markStartedAndWaitForRelease()
                }
            }
            await foregroundGate.waitUntilStarted()

            let before = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
            XCTAssertEqual(before.foregroundActivityCountsByKind[.rootLoad], 1)

            let build = Task.detached(priority: .background) {
                try await FileSystemService.withCodeMapArtifactBuildPermit(
                    ownerID: UUID(),
                    priority: .userInitiated
                ) {
                    await operationStarted.mark()
                    return Task.currentPriority
                }
            }
            let blocked = await waitForProcessWideLimiterSnapshot {
                $0.queuedCodemapWaiterCount == before.queuedCodemapWaiterCount + 1
            }
            XCTAssertEqual(blocked.activeCodemapPermitCount, before.activeCodemapPermitCount)
            XCTAssertEqual(blocked.codemapGrantWhileForegroundCount, before.codemapGrantWhileForegroundCount)
            let didStartWhileBlocked = await operationStarted.isMarked()
            XCTAssertFalse(didStartWhileBlocked)

            await foregroundGate.release()
            await foreground.value
            let observedPriority = try await build.value
            XCTAssertGreaterThanOrEqual(observedPriority.rawValue, TaskPriority.userInitiated.rawValue)

            let completed = await waitForProcessWideLimiterSnapshot {
                $0.queuedCodemapWaiterCount == before.queuedCodemapWaiterCount
                    && $0.activeCodemapPermitCount == before.activeCodemapPermitCount
                    && $0.foregroundActivityCount == before.foregroundActivityCount - 1
            }
            XCTAssertEqual(completed.grantCount, before.grantCount + 1)
            XCTAssertEqual(completed.bulkGrantCount, before.bulkGrantCount + 1)
            XCTAssertEqual(completed.codemapGrantWhileForegroundCount, before.codemapGrantWhileForegroundCount)
        }

        func testCancellingQueuedCodemapBuildAdmissionRemovesWaiterWithoutPermitLeak() async throws {
            let limiter = ContentReadAsyncLimiter(capacity: 1, maxQueuedWaiterCount: 2)
            let foregroundToken = await limiter.beginForegroundActivity(kind: .storeBackedSearch)
            let operationStarted = CodeMapAdmissionSignal()
            let build = Task {
                try await limiter.withCodeMapArtifactBuildPermit(
                    ownerID: UUID(),
                    priority: .utility
                ) {
                    await operationStarted.mark()
                }
            }

            let queued = await waitForLimiterSnapshot(limiter) {
                $0.queuedCodemapWaiterCount == 1
            }
            XCTAssertEqual(queued.activePermitCount, 0)
            XCTAssertEqual(queued.ownerLaneCount, 1)

            build.cancel()
            do {
                try await build.value
                XCTFail("Expected queued codemap build admission cancellation.")
            } catch is CancellationError {
                // Expected.
            }

            let cancelled = await waitForLimiterSnapshot(limiter) {
                $0.queuedWaiterCount == 0 && $0.ownerLaneCount == 0
            }
            XCTAssertEqual(cancelled.cancellationCount, 1)
            XCTAssertEqual(cancelled.grantCount, 0)
            XCTAssertEqual(cancelled.activePermitCount, 0)
            XCTAssertEqual(cancelled.activeCodemapPermitCount, 0)
            let didStartAfterCancellation = await operationStarted.isMarked()
            XCTAssertFalse(didStartAfterCancellation)

            await limiter.endForegroundActivity(foregroundToken)
            let idle = await waitForLimiterSnapshot(limiter) { $0.isIdle }
            XCTAssertTrue(idle.isIdle)
        }

        func testCodemapBuildAdmissionPreservesForegroundPriorityAndOwnerRoundRobin() async throws {
            let limiter = ContentReadAsyncLimiter(capacity: 1, maxQueuedWaiterCount: 8)
            let heldGate = CodeMapAdmissionGate()
            let recorder = CodeMapAdmissionRecorder()
            let ownerA = UUID()
            let ownerB = UUID()

            let held = Task {
                try await limiter.withPermit(workloadClass: .contentSearch, ownerID: UUID()) {
                    await heldGate.markStartedAndWaitForRelease()
                }
            }
            await heldGate.waitUntilStarted()

            let requests: [(value: Int, ownerID: UUID, priority: TaskPriority)] = [
                (1, ownerA, .userInitiated),
                (2, ownerA, .utility),
                (3, ownerB, .userInitiated),
                (4, ownerB, .utility)
            ]
            var builds: [Task<Void, Error>] = []
            for request in requests {
                builds.append(Task.detached(priority: .background) {
                    try await limiter.withCodeMapArtifactBuildPermit(
                        ownerID: request.ownerID,
                        priority: request.priority
                    ) {
                        await recorder.append(
                            value: request.value,
                            priority: Task.currentPriority
                        )
                    }
                })
                _ = await waitForLimiterSnapshot(limiter) {
                    $0.queuedCodemapWaiterCount == builds.count
                }
            }

            let foreground = Task {
                try await limiter.withPermit(workloadClass: .contentSearch, ownerID: UUID()) {
                    await recorder.append(value: 0, priority: Task.currentPriority)
                }
            }
            _ = await waitForLimiterSnapshot(limiter) { $0.queuedWaiterCount == 5 }

            await heldGate.release()
            try await held.value
            try await foreground.value
            for build in builds {
                try await build.value
            }

            let entries = await recorder.entries()
            XCTAssertEqual(entries.map(\.value), [0, 1, 3, 2, 4])
            let requestedPriorities = Dictionary(
                uniqueKeysWithValues: requests.map { ($0.value, $0.priority) }
            )
            for entry in entries where entry.value != 0 {
                let requestedPriority = try XCTUnwrap(requestedPriorities[entry.value])
                XCTAssertGreaterThanOrEqual(
                    entry.priority.rawValue,
                    requestedPriority.rawValue,
                    "Priority context was not applied for request \(entry.value)."
                )
            }

            let idle = await waitForLimiterSnapshot(limiter) { $0.isIdle }
            XCTAssertTrue(idle.isIdle)
            XCTAssertEqual(idle.normalGrantCount, 2)
            XCTAssertEqual(idle.bulkGrantCount, 4)
            XCTAssertEqual(idle.activeBackgroundPermitCount, 0)
            XCTAssertEqual(idle.activeCodemapPermitCount, 0)
        }

        private func waitForProcessWideLimiterSnapshot(
            timeoutNanoseconds: UInt64 = 1_000_000_000,
            predicate: (ContentReadAsyncLimiter.Snapshot) -> Bool
        ) async -> ContentReadAsyncLimiter.Snapshot {
            let interval: UInt64 = 10_000_000
            var waited: UInt64 = 0
            while waited < timeoutNanoseconds {
                let snapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
                if predicate(snapshot) { return snapshot }
                try? await Task.sleep(nanoseconds: interval)
                waited += interval
            }
            return await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
        }

        private func waitForLimiterSnapshot(
            _ limiter: ContentReadAsyncLimiter,
            timeoutNanoseconds: UInt64 = 1_000_000_000,
            predicate: (ContentReadAsyncLimiter.Snapshot) -> Bool
        ) async -> ContentReadAsyncLimiter.Snapshot {
            let interval: UInt64 = 10_000_000
            var waited: UInt64 = 0
            while waited < timeoutNanoseconds {
                let snapshot = await limiter.snapshotForTesting()
                if predicate(snapshot) { return snapshot }
                try? await Task.sleep(nanoseconds: interval)
                waited += interval
            }
            return await limiter.snapshotForTesting()
        }
    #endif
}

private actor CodeMapAdmissionGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStartedAndWaitForRelease() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor CodeMapAdmissionSignal {
    private var marked = false

    func mark() {
        marked = true
    }

    func isMarked() -> Bool {
        marked
    }
}

private actor CodeMapAdmissionRecorder {
    struct Entry {
        let value: Int
        let priority: TaskPriority
    }

    private var recordedEntries: [Entry] = []

    func append(value: Int, priority: TaskPriority) {
        recordedEntries.append(Entry(value: value, priority: priority))
    }

    func entries() -> [Entry] {
        recordedEntries
    }
}
