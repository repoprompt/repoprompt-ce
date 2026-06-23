@testable import RepoPromptCore
import XCTest

final class FileSystemContentLoadingConcurrencyTests: XCTestCase {
    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        #if DEBUG
            EditFlowPerf.resetDebugCaptureForTesting()
        #endif
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }









    #if DEBUG


        func testContentReadSchedulerBoundsQueueCancelsWaitersAndReturnsIdle() async throws {
            let limiter = ContentReadAsyncLimiter(
                capacity: 1,
                maxQueuedWaiterCount: 1,
                retryAfterMilliseconds: 777
            )
            let gate = AsyncGate()
            let heldOwner = UUID()
            let queuedOwner = UUID()

            let held = Task {
                try await limiter.withPermit(workloadClass: .contentSearch, ownerID: heldOwner) {
                    await gate.markStartedAndWaitForRelease()
                    return 1
                }
            }
            await gate.waitUntilStarted()
            let queued = Task {
                try await limiter.withPermit(workloadClass: .contentSearch, ownerID: queuedOwner) { 2 }
            }
            let queuedSnapshot = await waitForLimiterSnapshot(limiter) { $0.queuedWaiterCount == 1 }
            XCTAssertEqual(queuedSnapshot.activePermitCount, 1)
            XCTAssertEqual(queuedSnapshot.ownerLaneCount, 2)

            do {
                _ = try await limiter.withPermit(workloadClass: .contentSearch, ownerID: UUID()) { 3 }
                XCTFail("Expected bounded scheduler backpressure")
            } catch let error as ContentReadSchedulerError {
                XCTAssertEqual(error, .queueFull(retryAfterMilliseconds: 777))
            }

            queued.cancel()
            do {
                _ = try await queued.value
                XCTFail("Expected queued scheduler cancellation")
            } catch is CancellationError {
                // Expected.
            }
            let cancelledSnapshot = await waitForLimiterSnapshot(limiter) { $0.queuedWaiterCount == 0 }
            XCTAssertEqual(cancelledSnapshot.cancellationCount, 1)
            XCTAssertEqual(cancelledSnapshot.overloadCount, 1)

            await gate.release()
            let heldValue = try await held.value
            XCTAssertEqual(heldValue, 1)
            let idle = await waitForLimiterSnapshot(limiter) { $0.isIdle }
            XCTAssertTrue(idle.isIdle)
            XCTAssertEqual(idle.activePermitCount, 0)
            XCTAssertEqual(idle.queuedWaiterCount, 0)
            XCTAssertEqual(idle.ownerLaneCount, 0)
        }

        func testContentReadSchedulerPrioritizesInteractiveWaitersOverBulk() async throws {
            let limiter = ContentReadAsyncLimiter(capacity: 1, maxQueuedWaiterCount: 4)
            let gate = AsyncGate()
            let recorder = AsyncValueRecorder()

            let held = Task {
                try await limiter.withPermit(workloadClass: .contentSearch, ownerID: UUID()) {
                    await gate.markStartedAndWaitForRelease()
                }
            }
            await gate.waitUntilStarted()
            let bulk = Task {
                try await limiter.withPermit(workloadClass: .codemap, ownerID: UUID()) {
                    await recorder.append(2)
                }
            }
            _ = await waitForLimiterSnapshot(limiter) { $0.queuedWaiterCount == 1 }
            let interactive = Task {
                try await limiter.withPermit(workloadClass: .interactiveRead, ownerID: UUID()) {
                    await recorder.append(1)
                }
            }
            _ = await waitForLimiterSnapshot(limiter) { $0.queuedWaiterCount == 2 }

            await gate.release()
            _ = try await held.value
            _ = try await interactive.value
            _ = try await bulk.value

            let values = await recorder.values()
            XCTAssertEqual(values, [1, 2])
            let idle = await waitForLimiterSnapshot(limiter) { $0.isIdle }
            XCTAssertEqual(idle.interactiveGrantCount, 1)
            XCTAssertEqual(idle.bulkGrantCount, 1)
        }

        func testContentReadSchedulerReservesPermitForLatencySensitiveReadsAcrossSupportedCapacities() async throws {
            let backgroundWorkloads: [ContentReadWorkloadClass] = [
                .codemap,
                .promptAccounting,
                .encodingDetection,
                .unspecified
            ]

            for capacity in 2 ... 4 {
                let limiter = ContentReadAsyncLimiter(capacity: capacity, maxQueuedWaiterCount: 12)
                let backgroundGate = AsyncGate()
                let backgroundStarted = AsyncCounter()
                let searchGate = AsyncGate()
                let interactiveGate = AsyncGate()
                let backgroundTasks = (0 ..< capacity).map { index in
                    Task {
                        try await limiter.withPermit(
                            workloadClass: backgroundWorkloads[index],
                            ownerID: UUID()
                        ) {
                            _ = await backgroundStarted.incrementAndValue()
                            await backgroundGate.markStartedAndWaitForRelease()
                        }
                    }
                }

                let capped = await waitForLimiterSnapshot(limiter) {
                    $0.activeBackgroundPermitCount == capacity - 1 && $0.queuedWaiterCount == 1
                }
                XCTAssertEqual(capped.backgroundPermitLimit, capacity - 1)
                XCTAssertEqual(capped.activePermitCount, capacity - 1)
                let initialBackgroundStartCount = await backgroundStarted.value()
                XCTAssertEqual(initialBackgroundStartCount, capacity - 1)

                let search = Task {
                    try await limiter.withPermit(workloadClass: .contentSearch, ownerID: UUID()) {
                        await searchGate.markStartedAndWaitForRelease()
                    }
                }
                await searchGate.waitUntilStarted()
                let searchAdmitted = await limiter.snapshotForTesting()
                XCTAssertEqual(searchAdmitted.activePermitCount, capacity)
                XCTAssertEqual(searchAdmitted.activeBackgroundPermitCount, capacity - 1)

                let interactive = Task {
                    try await limiter.withPermit(workloadClass: .interactiveRead, ownerID: UUID()) {
                        await interactiveGate.markStartedAndWaitForRelease()
                    }
                }
                _ = await waitForLimiterSnapshot(limiter) { $0.queuedWaiterCount == 2 }

                await searchGate.release()
                _ = try await search.value
                await interactiveGate.waitUntilStarted()
                let interactiveAdmitted = await limiter.snapshotForTesting()
                XCTAssertEqual(interactiveAdmitted.activePermitCount, capacity)
                XCTAssertEqual(interactiveAdmitted.activeBackgroundPermitCount, capacity - 1)
                XCTAssertEqual(interactiveAdmitted.queuedWaiterCount, 1)

                await interactiveGate.release()
                _ = try await interactive.value
                let backgroundStillCapped = await waitForLimiterSnapshot(limiter) {
                    $0.activePermitCount == capacity - 1 && $0.queuedWaiterCount == 1
                }
                XCTAssertEqual(backgroundStillCapped.activeBackgroundPermitCount, capacity - 1)

                await backgroundGate.release()
                let allBackgroundStarted = await backgroundStarted.waitUntilValue(atLeast: capacity)
                XCTAssertTrue(allBackgroundStarted)
                for task in backgroundTasks {
                    _ = try await task.value
                }
                let idle = await waitForLimiterSnapshot(limiter) { $0.isIdle }
                XCTAssertTrue(idle.isIdle)
                XCTAssertEqual(idle.activeBackgroundPermitCount, 0)
            }
        }

        func testCancelledActiveBackgroundReadRetainsPermitUntilBodyReturns() async throws {
            let limiter = ContentReadAsyncLimiter(capacity: 2, maxQueuedWaiterCount: 4)
            let firstGate = AsyncGate()
            let secondGate = AsyncGate()
            let sensitiveGate = AsyncGate()

            let first = Task {
                try await limiter.withPermit(workloadClass: .codemap, ownerID: UUID()) {
                    await firstGate.markStartedAndWaitForRelease()
                }
            }
            await firstGate.waitUntilStarted()
            first.cancel()

            let second = Task {
                try await limiter.withPermit(workloadClass: .encodingDetection, ownerID: UUID()) {
                    await secondGate.markStartedAndWaitForRelease()
                }
            }
            let backgroundQueued = await waitForLimiterSnapshot(limiter) {
                $0.activeBackgroundPermitCount == 1 && $0.queuedWaiterCount == 1
            }
            XCTAssertEqual(backgroundQueued.activePermitCount, 1)

            let sensitive = Task {
                try await limiter.withPermit(workloadClass: .interactiveRead, ownerID: UUID()) {
                    await sensitiveGate.markStartedAndWaitForRelease()
                }
            }
            await sensitiveGate.waitUntilStarted()
            let sensitiveAdmitted = await limiter.snapshotForTesting()
            XCTAssertEqual(sensitiveAdmitted.activeBackgroundPermitCount, 1)

            await sensitiveGate.release()
            _ = try await sensitive.value
            let cancelledBodyStillActive = await limiter.snapshotForTesting()
            XCTAssertEqual(cancelledBodyStillActive.queuedWaiterCount, 1)

            await firstGate.release()
            _ = try? await first.value
            await secondGate.waitUntilStarted()
            let secondAdmitted = await limiter.snapshotForTesting()
            XCTAssertEqual(secondAdmitted.activeBackgroundPermitCount, 1)
            XCTAssertEqual(secondAdmitted.activePermitCount, 1)

            await secondGate.release()
            _ = try await second.value
            let idle = await waitForLimiterSnapshot(limiter) { $0.isIdle }
            XCTAssertTrue(idle.isIdle)
            XCTAssertEqual(idle.activeBackgroundPermitCount, 0)
        }

        func testContentReadSchedulerPromotesAgedWaitersAheadOfNewInteractiveWork() async throws {
            let clock = ContentReadTestClock()
            let limiter = ContentReadAsyncLimiter(
                capacity: 1,
                maxQueuedWaiterCount: 4,
                agePromotionNanoseconds: 10_000_000,
                nowUptimeNanoseconds: { clock.now() }
            )
            let gate = AsyncGate()
            let recorder = AsyncValueRecorder()

            let held = Task {
                try await limiter.withPermit(workloadClass: .contentSearch, ownerID: UUID()) {
                    await gate.markStartedAndWaitForRelease()
                }
            }
            await gate.waitUntilStarted()
            let agedBulk = Task {
                try await limiter.withPermit(workloadClass: .codemap, ownerID: UUID()) {
                    await recorder.append(1)
                }
            }
            _ = await waitForLimiterSnapshot(limiter) { $0.queuedWaiterCount == 1 }
            clock.advance(by: 20_000_000)
            let interactive = Task {
                try await limiter.withPermit(workloadClass: .interactiveRead, ownerID: UUID()) {
                    await recorder.append(2)
                }
            }
            _ = await waitForLimiterSnapshot(limiter) { $0.queuedWaiterCount == 2 }

            await gate.release()
            _ = try await held.value
            _ = try await agedBulk.value
            _ = try await interactive.value

            let values = await recorder.values()
            XCTAssertEqual(values, [1, 2])
            let idle = await waitForLimiterSnapshot(limiter) { $0.isIdle }
            XCTAssertTrue(idle.isIdle)
        }

        func testContentReadSchedulerRoundRobinsOwnersWhilePreservingOwnerFIFO() async throws {
            let limiter = ContentReadAsyncLimiter(capacity: 1, maxQueuedWaiterCount: 8)
            let gate = AsyncGate()
            let recorder = AsyncValueRecorder()
            let ownerA = UUID()
            let ownerB = UUID()

            let held = Task {
                try await limiter.withPermit(workloadClass: .contentSearch, ownerID: UUID()) {
                    await gate.markStartedAndWaitForRelease()
                }
            }
            await gate.waitUntilStarted()
            var tasks: [Task<Void, Error>] = []
            tasks.append(Task { try await limiter.withPermit(workloadClass: .contentSearch, ownerID: ownerA) { await recorder.append(1) } })
            _ = await waitForLimiterSnapshot(limiter) { $0.queuedWaiterCount == 1 }
            tasks.append(Task { try await limiter.withPermit(workloadClass: .contentSearch, ownerID: ownerA) { await recorder.append(2) } })
            _ = await waitForLimiterSnapshot(limiter) { $0.queuedWaiterCount == 2 }
            tasks.append(Task { try await limiter.withPermit(workloadClass: .contentSearch, ownerID: ownerB) { await recorder.append(3) } })
            _ = await waitForLimiterSnapshot(limiter) { $0.queuedWaiterCount == 3 }
            tasks.append(Task { try await limiter.withPermit(workloadClass: .contentSearch, ownerID: ownerB) { await recorder.append(4) } })
            _ = await waitForLimiterSnapshot(limiter) { $0.queuedWaiterCount == 4 }

            await gate.release()
            _ = try await held.value
            for task in tasks {
                _ = try await task.value
            }

            let recordedValues = await recorder.values()
            XCTAssertEqual(recordedValues, [1, 3, 2, 4])
            let idle = await waitForLimiterSnapshot(limiter) { $0.isIdle }
            XCTAssertTrue(idle.isIdle)
            XCTAssertEqual(idle.grantCount, 5)
            XCTAssertEqual(idle.normalGrantCount, 5)
        }
    #endif


    #if DEBUG
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

        private func saturateContentReadWorkers(
            service: FileSystemService,
            root: URL,
            gate: AsyncGate
        ) async throws -> [Task<String?, Error>] {
            let limit = FileSystemService.contentReadWorkerLimitForTesting
            let enteredCount = AsyncCounter()
            for index in 0 ..< limit {
                try FileSystemTestSupport.write("held-\(index)", to: root.appendingPathComponent("Held-\(index).txt"))
            }
            await service.setContentReadChunkHandlerForTesting { path in
                guard path.hasPrefix("Held-") else { return }
                _ = await enteredCount.incrementAndValue()
                await gate.markStartedAndWaitForRelease()
            }
            let tasks = (0 ..< limit).map { index in
                Task {
                    try await service.loadContent(
                        ofRelativePath: "Held-\(index).txt",
                        workloadClass: .contentSearch
                    )
                }
            }
            let saturated = await enteredCount.waitUntilValue(atLeast: limit)
            XCTAssertTrue(saturated)
            return tasks
        }

        private func waitForLifecycleEvent(
            _ eventName: String,
            correlationID: UUID,
            timeoutNanoseconds: UInt64 = 1_000_000_000
        ) async -> Bool {
            let interval: UInt64 = 10_000_000
            var waited: UInt64 = 0
            while waited < timeoutNanoseconds {
                let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: false)
                if snapshot.lifecycleEvents.contains(where: {
                    $0.eventName == eventName && $0.correlationID == correlationID.uuidString
                }) {
                    return true
                }
                try? await Task.sleep(nanoseconds: interval)
                waited += interval
            }
            return false
        }

        private static func rootToken(in event: EditFlowPerf.DebugCaptureLifecycleEvent) -> String? {
            event.sanitizedDimensions
                .split(separator: " ")
                .first { $0.hasPrefix("rootToken=") }
                .map(String.init)
        }

        private func startedCapture(label: String, maxSamples: Int) -> EditFlowPerf.DebugCaptureSnapshot {
            switch EditFlowPerf.beginDebugCapture(label: label, maxSamples: maxSamples) {
            case let .started(snapshot):
                return snapshot
            case .busy:
                XCTFail("Capture should start.")
                fatalError("Capture should start.")
            }
        }
    #endif

    private var createdFileFlags: FileSystemWatchEventFlags {
        [.itemCreated, .itemIsFile]
    }

    private func makeService(root: URL, skipSymlinks: Bool = true) async throws -> FileSystemService {
        try await FileSystemService(
            path: root.path,
            respectGitignore: false,
            respectRepoIgnore: false,
            respectCursorignore: false,
            skipSymlinks: skipSymlinks
        )
    }

    private func waitForPublishedWatermark(
        _ service: FileSystemService,
        through target: FileSystemWatcherIngressMailbox.Watermark
    ) async -> Bool {
        for _ in 0 ..< 100 {
            let publication = await service.publicationStateForTesting()
            if publication.lastPublishedWatcherAcceptedWatermark >= target {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func createSymlinkOrSkip(at link: URL, destination: URL) throws {
        do {
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination.path)
        } catch {
            throw XCTSkip("Symlink creation unavailable in this environment: \(error)")
        }
    }

    private func assertInvalidRelativePath(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected invalidRelativePath")
        } catch FileSystemError.invalidRelativePath {
            // Expected.
        } catch {
            XCTFail("Expected invalidRelativePath, got \(error)")
        }
    }
}

private final class ContentReadTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func now() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by nanoseconds: UInt64) {
        lock.lock()
        value &+= nanoseconds
        lock.unlock()
    }
}

private actor AsyncGate {
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

private actor AsyncCounter {
    private var count = 0

    func incrementAndValue() -> Int {
        count += 1
        return count
    }

    func value() -> Int {
        count
    }

    func waitUntilValue(atLeast target: Int, timeoutNanoseconds: UInt64 = 1_000_000_000) async -> Bool {
        let interval: UInt64 = 10_000_000
        var waited: UInt64 = 0
        while count < target, waited < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: interval)
            waited += interval
        }
        return count >= target
    }
}

private actor AsyncValueRecorder {
    private var recordedValues: [Int] = []

    func append(_ value: Int) {
        recordedValues.append(value)
    }

    func values() -> [Int] {
        recordedValues
    }
}

private actor AsyncSignal {
    private var marked = false

    func mark() {
        marked = true
    }

    func isMarked() -> Bool {
        marked
    }

    func waitUntilMarked(timeoutNanoseconds: UInt64 = 1_000_000_000) async -> Bool {
        let interval: UInt64 = 10_000_000
        var waited: UInt64 = 0
        while !marked, waited < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: interval)
            waited += interval
        }
        return marked
    }
}
