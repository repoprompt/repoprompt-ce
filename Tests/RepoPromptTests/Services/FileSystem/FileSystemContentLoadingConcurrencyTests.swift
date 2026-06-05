@testable import RepoPrompt
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

    func testContentLoadingPreservesTextBinaryEmptyFallbackLargeFileAndCacheBehavior() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemContentLoadingCorrectness")
        let service = try await makeService(root: root)
        let emptyURL = root.appendingPathComponent("Empty.txt")
        let utf8URL = root.appendingPathComponent("Utf8.txt")
        let fallbackURL = root.appendingPathComponent("Fallback.txt")
        let binaryURL = root.appendingPathComponent("Opaque.dat")
        let nestedURL = root.appendingPathComponent("nested/Cache.txt")
        let largeURL = root.appendingPathComponent("Large.txt")

        try Data().write(to: emptyURL)
        try FileSystemTestSupport.write("hello, world", to: utf8URL)
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: fallbackURL)
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: binaryURL)
        try FileSystemTestSupport.write("cache", to: nestedURL)
        try Data(repeating: 0x61, count: 10_000_001).write(to: largeURL)

        let missingBinary = try await service.loadContent(ofRelativePath: "Missing.png")
        let empty = try await service.loadContent(ofRelativePath: "Empty.txt")
        let utf8 = try await service.loadContent(ofRelativePath: "Utf8.txt")
        let fallback = try await service.loadContent(ofRelativePath: "Fallback.txt")
        let binary = try await service.loadContent(ofRelativePath: "Opaque.dat")
        let large = try await service.loadContent(ofRelativePath: "Large.txt")
        let nested = try await service.loadContent(ofRelativePath: "nested/./Cache.txt")
        let emptyEncoding = await service.cachedEncodingForTesting(relativePath: "Empty.txt")
        let utf8Encoding = await service.cachedEncodingForTesting(relativePath: "Utf8.txt")
        let fallbackEncoding = await service.cachedEncodingForTesting(relativePath: "Fallback.txt")
        let binaryEncoding = await service.cachedEncodingForTesting(relativePath: "Opaque.dat")
        let largeEncoding = await service.cachedEncodingForTesting(relativePath: "Large.txt")
        let rawNestedEncoding = await service.cachedEncodingForTesting(relativePath: "nested/./Cache.txt")
        let standardizedNestedEncoding = await service.cachedEncodingForTesting(relativePath: "nested/Cache.txt")

        XCTAssertNil(missingBinary)
        XCTAssertEqual(empty, "")
        XCTAssertEqual(utf8, "hello, world")
        XCTAssertEqual(fallback, "café")
        XCTAssertNil(binary)
        XCTAssertEqual(large, "[File too large: 10000001 bytes]")
        XCTAssertEqual(nested, "cache")
        XCTAssertEqual(emptyEncoding, .utf8)
        XCTAssertEqual(utf8Encoding, .utf8)
        XCTAssertNotNil(fallbackEncoding)
        XCTAssertNil(binaryEncoding)
        XCTAssertNil(largeEncoding)
        XCTAssertEqual(rawNestedEncoding, .utf8)
        XCTAssertNil(standardizedNestedEncoding)
    }

    func testContentLoadingRejectsTraversalAndSymlinkTargets() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemContentLoadingContainment")
        let outside = try temporaryRoots.makeRoot(suiteName: "FileSystemContentLoadingOutside")
        let insideURL = root.appendingPathComponent("Inside.txt")
        let outsideURL = outside.appendingPathComponent("Outside.txt")
        let insideLinkURL = root.appendingPathComponent("InsideLink.txt")
        let outsideLinkURL = root.appendingPathComponent("OutsideLink.txt")
        try FileSystemTestSupport.write("inside", to: insideURL)
        try FileSystemTestSupport.write("outside", to: outsideURL)
        try createSymlinkOrSkip(at: insideLinkURL, destination: insideURL)
        try createSymlinkOrSkip(at: outsideLinkURL, destination: outsideURL)

        let strictService = try await makeService(root: root, skipSymlinks: true)
        await assertInvalidRelativePath {
            _ = try await strictService.loadContent(ofRelativePath: "../\(outside.lastPathComponent)/Outside.txt")
        }
        await assertInvalidRelativePath {
            _ = try await strictService.loadContent(ofRelativePath: "InsideLink.txt")
        }

        let canonicalContainmentService = try await makeService(root: root, skipSymlinks: false)
        await assertInvalidRelativePath {
            _ = try await canonicalContainmentService.loadContent(ofRelativePath: "OutsideLink.txt")
        }
    }

    func testCancellationDuringChunkedReadDoesNotCommitEncodingCache() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemContentLoadingCancellation")
        let service = try await makeService(root: root)
        let slowURL = root.appendingPathComponent("Slow.txt")
        try Data(repeating: 0x61, count: 3_000_000).write(to: slowURL)
        let gate = AsyncGate()

        await service.setContentReadChunkHandlerForTesting { path in
            guard path == "Slow.txt" else { return }
            await gate.markStartedAndWaitForRelease()
        }
        let readTask = Task {
            try await service.loadContent(ofRelativePath: "Slow.txt")
        }
        await gate.waitUntilStarted()
        readTask.cancel()
        await gate.release()

        do {
            _ = try await readTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let cachedEncoding = await service.cachedEncodingForTesting(relativePath: "Slow.txt")
        XCTAssertNil(cachedEncoding)
        await service.setContentReadChunkHandlerForTesting(nil)
    }

    func testSlowSameRootContentReadDoesNotDelayAcceptedWatcherFlush() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemContentLoadingSameRoot")
        let service = try await makeService(root: root)
        try FileSystemTestSupport.write("slow", to: root.appendingPathComponent("Slow.txt"))
        let readGate = AsyncGate()
        let flushCompleted = AsyncSignal()

        await service.setContentReadChunkHandlerForTesting { path in
            guard path == "Slow.txt" else { return }
            await readGate.markStartedAndWaitForRelease()
        }
        let readTask = Task {
            try await service.loadContent(ofRelativePath: "Slow.txt")
        }
        await readGate.waitUntilStarted()

        let acceptedWatermark = await service.acceptWatcherPayloadForTesting([
            (absolutePath: "/outside/same-root.swift", flags: createdFileFlags, eventId: 1)
        ])
        let accepted = try XCTUnwrap(acceptedWatermark)
        let scheduledDrainCompletedBeforeReadRelease = await waitForPublishedWatermark(service, through: accepted)

        let flushTask = Task {
            let sequence = await service.flushPendingEventsNow(throughAcceptedWatcherWatermark: accepted)
            await flushCompleted.mark()
            return sequence
        }
        let completedBeforeReadRelease = await flushCompleted.waitUntilMarked()
        await readGate.release()
        let sequence = await flushTask.value
        let content = try await readTask.value
        let mailbox = await service.watcherIngressMailboxSnapshotForTesting()
        let publication = await service.publicationStateForTesting()

        XCTAssertTrue(scheduledDrainCompletedBeforeReadRelease, "Same-root scheduled watcher drain should run while content I/O remains suspended off-actor")
        XCTAssertTrue(completedBeforeReadRelease, "Same-root watcher flush should finish while content I/O remains suspended off-actor")
        XCTAssertGreaterThan(sequence, 0)
        XCTAssertEqual(content, "slow")
        XCTAssertEqual(mailbox.queuedRawEntryCount, 0)
        XCTAssertGreaterThanOrEqual(publication.lastPublishedWatcherAcceptedWatermark, accepted)
        await service.setContentReadChunkHandlerForTesting(nil)
    }

    func testSlowContentReadOnRootADoesNotDelayRootBReadAndWatcherFlush() async throws {
        let rootA = try temporaryRoots.makeRoot(suiteName: "FileSystemContentLoadingRootA")
        let rootB = try temporaryRoots.makeRoot(suiteName: "FileSystemContentLoadingRootB")
        let serviceA = try await makeService(root: rootA)
        let serviceB = try await makeService(root: rootB)
        try FileSystemTestSupport.write("slow-a", to: rootA.appendingPathComponent("SlowA.txt"))
        try FileSystemTestSupport.write("fast-b", to: rootB.appendingPathComponent("FastB.txt"))
        let rootAGate = AsyncGate()
        let rootBCompleted = AsyncSignal()

        await serviceA.setContentReadChunkHandlerForTesting { path in
            guard path == "SlowA.txt" else { return }
            await rootAGate.markStartedAndWaitForRelease()
        }
        let rootATask = Task {
            try await serviceA.loadContent(ofRelativePath: "SlowA.txt")
        }
        await rootAGate.waitUntilStarted()

        let rootBFlags = createdFileFlags
        let rootBTask = Task {
            let content = try await serviceB.loadContent(ofRelativePath: "FastB.txt")
            let watermark = await serviceB.acceptWatcherPayloadForTesting([
                (absolutePath: "/outside/root-b.swift", flags: rootBFlags, eventId: 2)
            ], scheduleDrain: false)
            let accepted = try XCTUnwrap(watermark)
            let sequence = await serviceB.flushPendingEventsNow(throughAcceptedWatcherWatermark: accepted)
            await rootBCompleted.mark()
            return (content, accepted, sequence)
        }
        let completedBeforeRootARelease = await rootBCompleted.waitUntilMarked()
        await rootAGate.release()
        let rootBResult = try await rootBTask.value
        let rootAContent = try await rootATask.value
        let publicationB = await serviceB.publicationStateForTesting()

        XCTAssertTrue(completedBeforeRootARelease, "Unrelated-root reads and watcher flushes should not wait for root A content I/O")
        XCTAssertEqual(rootBResult.0, "fast-b")
        XCTAssertGreaterThan(rootBResult.2, 0)
        XCTAssertGreaterThanOrEqual(publicationB.lastPublishedWatcherAcceptedWatermark, rootBResult.1)
        XCTAssertEqual(rootAContent, "slow-a")
        await serviceA.setContentReadChunkHandlerForTesting(nil)
    }

    func testStaleChunkedReadDoesNotOverwriteEncodingCacheAfterConcurrentEdit() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemContentLoadingStaleCache")
        let service = try await makeService(root: root)
        let url = root.appendingPathComponent("Race.txt")
        var initialData = Data([0xFF, 0xFE])
        try initialData.append(XCTUnwrap(String(repeating: "a", count: 1_100_000).data(using: .utf16LittleEndian)))
        try initialData.write(to: url)
        let secondChunkGate = AsyncGate()
        let chunkCounter = AsyncCounter()

        await service.setContentReadChunkHandlerForTesting { path in
            guard path == "Race.txt" else { return }
            let count = await chunkCounter.incrementAndValue()
            if count == 2 {
                await secondChunkGate.markStartedAndWaitForRelease()
            }
        }
        let readTask = Task {
            try await service.loadContent(ofRelativePath: "Race.txt")
        }
        await secondChunkGate.waitUntilStarted()
        try await service.editFile(atRelativePath: "Race.txt", newContent: "replacement")
        await secondChunkGate.release()
        _ = try await readTask.value
        let cachedEncoding = await service.cachedEncodingForTesting(relativePath: "Race.txt")

        XCTAssertEqual(cachedEncoding, .utf8, "A stale UTF-16 worker must not overwrite the newer edit cache entry")
        await service.setContentReadChunkHandlerForTesting(nil)
    }

    func testChunkedReadEnforcesConfiguredSizeLimitWhenFileGrows() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemContentLoadingGrowth")
        let service = try await makeService(root: root)
        let url = root.appendingPathComponent("Growing.txt")
        try Data(repeating: 0x61, count: 2_000_000).write(to: url)
        let secondChunkGate = AsyncGate()
        let chunkCounter = AsyncCounter()

        await service.setContentReadChunkHandlerForTesting { path in
            guard path == "Growing.txt" else { return }
            let count = await chunkCounter.incrementAndValue()
            if count == 2 {
                await secondChunkGate.markStartedAndWaitForRelease()
            }
        }
        let readTask = Task {
            try await service.loadContent(ofRelativePath: "Growing.txt")
        }
        await secondChunkGate.waitUntilStarted()
        let appendHandle = try FileHandle(forWritingTo: url)
        try appendHandle.seekToEnd()
        try appendHandle.write(contentsOf: Data(repeating: 0x62, count: 10_000_000))
        try appendHandle.close()
        await secondChunkGate.release()
        let content = try await readTask.value
        let cachedEncoding = await service.cachedEncodingForTesting(relativePath: "Growing.txt")

        XCTAssertTrue(content?.hasPrefix("[File too large: ") == true)
        XCTAssertNil(cachedEncoding)
        await service.setContentReadChunkHandlerForTesting(nil)
    }

    func testOffActorContentReadWorkerConcurrencyIsBounded() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemContentLoadingLimiter")
        let service = try await makeService(root: root)
        let limit = FileSystemService.contentReadWorkerLimitForTesting
        let readCount = limit + 2
        for index in 0 ..< readCount {
            try FileSystemTestSupport.write("file-\(index)", to: root.appendingPathComponent("File-\(index).txt"))
        }
        let gate = AsyncGate()
        let enteredCount = AsyncCounter()

        await service.setContentReadChunkHandlerForTesting { _ in
            _ = await enteredCount.incrementAndValue()
            await gate.markStartedAndWaitForRelease()
        }
        let tasks = (0 ..< readCount).map { index in
            Task {
                try await service.loadContent(ofRelativePath: "File-\(index).txt")
            }
        }
        let reachedLimit = await enteredCount.waitUntilValue(atLeast: limit)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let enteredBeforeRelease = await enteredCount.value()
        await gate.release()
        for task in tasks {
            _ = try await task.value
        }

        XCTAssertTrue(reachedLimit)
        XCTAssertEqual(enteredBeforeRelease, limit)
        await service.setContentReadChunkHandlerForTesting(nil)
    }

    #if DEBUG
        func testQueuedContentReadWorkerPermitWaitRecordsCorrelatedAcquireAndPrivacySafeDimensions() async throws {
            let root = try temporaryRoots.makeRoot(suiteName: "FileSystemContentLoadingPermitTelemetry")
            let service = try await makeService(root: root)
            let gate = AsyncGate()
            let saturation = try await saturateContentReadWorkers(service: service, root: root, gate: gate)
            let queuedPath = "Unsafe Folder/Telemetry|Needle.txt"
            try FileSystemTestSupport.write("queued", to: root.appendingPathComponent(queuedPath))
            _ = startedCapture(label: "content-read-worker-permit-acquire", maxSamples: 100)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive())

            let queued = Task {
                try await EditFlowPerf.$currentLifecycleCorrelation.withValue(correlation) {
                    try await service.loadContent(
                        ofRelativePath: queuedPath,
                        workloadClass: .interactiveRead
                    )
                }
            }
            let waitBegan = await waitForLifecycleEvent(
                "FileSystem.ContentReadWorkerPermitWaitBegan",
                correlationID: correlation.id
            )
            XCTAssertTrue(waitBegan)

            await gate.release()
            for task in saturation {
                _ = try await task.value
            }
            let queuedContent = try await queued.value
            XCTAssertEqual(queuedContent, "queued")
            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let events = snapshot.lifecycleEvents.filter { $0.correlationID == correlation.id.uuidString }
            XCTAssertEqual(events.map(\.eventName), [
                "FileSystem.ContentLoadEntered",
                "FileSystem.ContentReadRequestPrepared",
                "FileSystem.ContentReadOffActorScheduled",
                "FileSystem.ContentReadWorkerPermitWaitBegan",
                "FileSystem.ContentReadWorkerPermitAcquired",
                "FileSystem.ContentReadWorkerReturned",
                "FileSystem.ContentLoadReturned"
            ])
            let rootLifecycleEvents = events.filter { $0.eventName != "FileSystem.ContentReadWorkerPermitWaitBegan" && $0.eventName != "FileSystem.ContentReadWorkerPermitAcquired" }
            XCTAssertEqual(Set(rootLifecycleEvents.compactMap(Self.rootToken(in:))).count, 1)
            let aggregate = try XCTUnwrap(snapshot.stages.first {
                $0.stageName == "EditFlow.FileSystem.ContentReadWorkerPermitWait" &&
                    $0.sanitizedDimensions.contains("outcome=acquiredAfterWait") &&
                    $0.sanitizedDimensions.contains("workloadClass=interactiveRead")
            })
            XCTAssertEqual(aggregate.sampleCount, 1)
            let workerBody = try XCTUnwrap(snapshot.stages.first {
                $0.stageName == "EditFlow.FileSystem.ContentReadWorkerBody" &&
                    $0.sanitizedDimensions.contains("outcome=loaded") &&
                    $0.sanitizedDimensions.contains("workloadClass=interactiveRead") &&
                    $0.sanitizedDimensions.contains("contentSource=disk") &&
                    $0.sanitizedDimensions.contains("fileBytes=6")
            })
            XCTAssertEqual(workerBody.sampleCount, 1)
            for dimensions in events.map(\.sanitizedDimensions) + [aggregate.sanitizedDimensions, workerBody.sanitizedDimensions] {
                XCTAssertFalse(dimensions.contains("Unsafe"))
                XCTAssertFalse(dimensions.contains("/"))
                XCTAssertFalse(dimensions.contains("|"))
            }
            await service.setContentReadChunkHandlerForTesting(nil)
        }

        func testCancelledQueuedContentReadWorkerPermitWaitRecordsCancellationWithoutAcquisitionOrLeak() async throws {
            let root = try temporaryRoots.makeRoot(suiteName: "FileSystemContentLoadingPermitCancellation")
            let service = try await makeService(root: root)
            let gate = AsyncGate()
            let saturation = try await saturateContentReadWorkers(service: service, root: root, gate: gate)
            try FileSystemTestSupport.write("cancel", to: root.appendingPathComponent("Cancelled.txt"))
            try FileSystemTestSupport.write("later", to: root.appendingPathComponent("Later.txt"))
            _ = startedCapture(label: "content-read-worker-permit-cancel", maxSamples: 100)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive())

            let cancelled = Task {
                try await EditFlowPerf.$currentLifecycleCorrelation.withValue(correlation) {
                    try await service.loadContent(
                        ofRelativePath: "Cancelled.txt",
                        workloadClass: .interactiveRead
                    )
                }
            }
            let waitBegan = await waitForLifecycleEvent(
                "FileSystem.ContentReadWorkerPermitWaitBegan",
                correlationID: correlation.id
            )
            XCTAssertTrue(waitBegan)
            cancelled.cancel()
            let cancellationRecorded = await waitForLifecycleEvent(
                "FileSystem.ContentReadWorkerPermitCancelled",
                correlationID: correlation.id
            )
            XCTAssertTrue(cancellationRecorded)
            do {
                _ = try await cancelled.value
                XCTFail("Expected queued content read cancellation")
            } catch is CancellationError {
                // Expected.
            }

            await gate.release()
            for task in saturation {
                _ = try await task.value
            }
            let laterContent = try await service.loadContent(ofRelativePath: "Later.txt")
            XCTAssertEqual(laterContent, "later")
            let limiterSnapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
            XCTAssertEqual(limiterSnapshot.queueDepth, 0)
            XCTAssertEqual(limiterSnapshot.waiterCount, 0)
            XCTAssertEqual(limiterSnapshot.pendingWaiterCount, 0)
            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let events = snapshot.lifecycleEvents.filter { $0.correlationID == correlation.id.uuidString }
            XCTAssertEqual(events.map(\.eventName), [
                "FileSystem.ContentLoadEntered",
                "FileSystem.ContentReadRequestPrepared",
                "FileSystem.ContentReadOffActorScheduled",
                "FileSystem.ContentReadWorkerPermitWaitBegan",
                "FileSystem.ContentReadWorkerPermitCancelled",
                "FileSystem.ContentReadWorkerReturned",
                "FileSystem.ContentLoadReturned"
            ])
            let rootLifecycleEvents = events.filter { $0.eventName != "FileSystem.ContentReadWorkerPermitWaitBegan" && $0.eventName != "FileSystem.ContentReadWorkerPermitCancelled" }
            XCTAssertEqual(Set(rootLifecycleEvents.compactMap(Self.rootToken(in:))).count, 1)
            XCTAssertFalse(events.contains { $0.eventName == "FileSystem.ContentReadWorkerPermitAcquired" })
            XCTAssertTrue(snapshot.stages.contains {
                $0.stageName == "EditFlow.FileSystem.ContentReadWorkerPermitWait" &&
                    $0.sanitizedDimensions.contains("outcome=cancelled") &&
                    $0.sanitizedDimensions.contains("workloadClass=interactiveRead")
            })
            await service.setContentReadChunkHandlerForTesting(nil)
        }
    #endif

    func testTestModeKeepsContentReadOnSerialFallbackWithoutInvokingWorkerHook() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemContentLoadingTestMode")
        try FileSystemTestSupport.write("serial", to: root.appendingPathComponent("Serial.txt"))
        let service = try await FileSystemService(
            path: root.path,
            respectGitignore: false,
            respectRepoIgnore: false,
            respectCursorignore: false,
            skipSymlinks: true,
            testIgnoreRules: IgnoreRules(),
            isTestMode: true
        )
        let workerHookInvoked = AsyncSignal()
        await service.setContentReadChunkHandlerForTesting { _ in
            await workerHookInvoked.mark()
        }

        let content = try await service.loadContent(ofRelativePath: "Serial.txt")
        let hookInvoked = await workerHookInvoked.isMarked()
        XCTAssertEqual(content, "serial")
        XCTAssertFalse(hookInvoked)
    }

    #if DEBUG
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
