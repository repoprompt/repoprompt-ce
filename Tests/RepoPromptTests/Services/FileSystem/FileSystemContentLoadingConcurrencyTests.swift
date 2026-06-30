import CoreServices
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

    func testValidatedRawContentReadsExactBytesWithoutProbeOrReread() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "ValidatedRawContentExactBytes")
        let service = try await makeService(root: root)
        let relativePath = "Source.swift"
        let data = Data(repeating: 0x61, count: 12000)
        try data.write(to: root.appendingPathComponent(relativePath))
        let expectedFingerprint = try await service.contentFingerprint(ofRelativePath: relativePath)

        let snapshot = try await service.loadValidatedRawContent(
            ofRelativePath: relativePath,
            expectedFingerprint: expectedFingerprint
        )

        XCTAssertEqual(snapshot.data, data)
        XCTAssertEqual(snapshot.fingerprint, expectedFingerprint)
        XCTAssertEqual(snapshot.modificationDate, expectedFingerprint.modificationDate)

        try FileSystemTestSupport.write("other", to: root.appendingPathComponent("Other.swift"))
        let otherFingerprint = try await service.contentFingerprint(ofRelativePath: "Other.swift")
        do {
            _ = try await service.loadValidatedRawContent(
                ofRelativePath: relativePath,
                expectedFingerprint: otherFingerprint
            )
            XCTFail("Expected the caller fingerprint mismatch to fail closed.")
        } catch FileContentValidationError.fingerprintChanged {
            // Expected.
        }
    }

    func testValidatedRawContentRejectsUnsafeMissingAndOversizedInputs() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "ValidatedRawContentSafety")
        let outside = try temporaryRoots.makeRoot(suiteName: "ValidatedRawContentOutside")
        let insideURL = root.appendingPathComponent("Inside.swift")
        let outsideURL = outside.appendingPathComponent("Outside.swift")
        let insideLinkURL = root.appendingPathComponent("InsideLink.swift")
        let outsideLinkURL = root.appendingPathComponent("OutsideLink.swift")
        try FileSystemTestSupport.write("inside", to: insideURL)
        try FileSystemTestSupport.write("outside", to: outsideURL)
        try createSymlinkOrSkip(at: insideLinkURL, destination: insideURL)
        try createSymlinkOrSkip(at: outsideLinkURL, destination: outsideURL)

        let service = try await makeService(root: root, skipSymlinks: false)
        await assertInvalidRelativePath {
            _ = try await service.loadValidatedRawContent(
                ofRelativePath: "../\(outside.lastPathComponent)/Outside.swift"
            )
        }
        await assertInvalidRelativePath {
            _ = try await service.loadValidatedRawContent(ofRelativePath: "InsideLink.swift")
        }
        await assertInvalidRelativePath {
            _ = try await service.loadValidatedRawContent(ofRelativePath: "OutsideLink.swift")
        }

        do {
            _ = try await service.loadValidatedRawContent(ofRelativePath: "Missing.swift")
            XCTFail("Expected a missing raw source to fail closed.")
        } catch FileSystemError.fileNotFound {
            // Expected.
        }

        do {
            _ = try await service.loadValidatedRawContent(
                ofRelativePath: "Inside.swift",
                maximumBytes: 2
            )
            XCTFail("Expected an oversized raw source to fail closed.")
        } catch FileSystemError.fileTooLarge {
            // Expected.
        }
    }

    func testValidatedRawContentRejectsCancellationBeforeBufferedRead() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "ValidatedRawContentCancellation")
        let service = try await makeService(root: root)
        let relativePath = "Slow.swift"
        try Data(repeating: 0x61, count: 1_500_000)
            .write(to: root.appendingPathComponent(relativePath))
        let gate = AsyncGate()

        await service.setContentReadChunkHandlerForTesting { path in
            guard path == relativePath else { return }
            await gate.markStartedAndWaitForRelease()
        }
        let readTask = Task {
            try await service.loadValidatedRawContent(
                ofRelativePath: relativePath,
                maximumBytes: 2_000_000
            )
        }
        await gate.waitUntilStarted()
        readTask.cancel()
        await gate.release()

        do {
            _ = try await readTask.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        }
        await service.setContentReadChunkHandlerForTesting(nil)
    }

    func testValidatedRawContentRejectsMidReadMutation() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "ValidatedRawContentMutation")
        let service = try await makeService(root: root)
        let relativePath = "Changing.swift"
        let sourceURL = root.appendingPathComponent(relativePath)
        try Data(repeating: 0x61, count: 1_500_000).write(to: sourceURL)
        let secondChunkGate = AsyncGate()
        let chunkCounter = AsyncCounter()

        await service.setContentReadChunkHandlerForTesting { path in
            guard path == relativePath else { return }
            if await chunkCounter.incrementAndValue() == 2 {
                await secondChunkGate.markStartedAndWaitForRelease()
            }
        }
        let readTask = Task {
            try await service.loadValidatedRawContent(
                ofRelativePath: relativePath,
                maximumBytes: 2_000_000
            )
        }
        await secondChunkGate.waitUntilStarted()
        try Data("replacement".utf8).write(to: sourceURL, options: .atomic)
        await secondChunkGate.release()

        do {
            _ = try await readTask.value
            XCTFail("Expected a mid-read replacement to fail closed.")
        } catch FileContentValidationError.fingerprintChanged {
            // Expected.
        }
        await service.setContentReadChunkHandlerForTesting(nil)
    }

    func testValidatedRawContentRejectsSymlinkRetargetDuringRead() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "ValidatedRawContentRetarget")
        let outside = try temporaryRoots.makeRoot(suiteName: "ValidatedRawContentRetargetOutside")
        let service = try await makeService(root: root, skipSymlinks: false)
        let relativePath = "Retargeted.swift"
        let sourceURL = root.appendingPathComponent(relativePath)
        let movedURL = root.appendingPathComponent("Original.swift")
        let targetURL = root.appendingPathComponent("Target.swift")
        try Data(repeating: 0x61, count: 1_500_000).write(to: sourceURL)
        try FileSystemTestSupport.write("target", to: targetURL)
        let secondChunkGate = AsyncGate()
        let chunkCounter = AsyncCounter()

        await service.setContentReadChunkHandlerForTesting { path in
            guard path == relativePath else { return }
            if await chunkCounter.incrementAndValue() == 2 {
                await secondChunkGate.markStartedAndWaitForRelease()
            }
        }
        let readTask = Task {
            try await service.loadValidatedRawContent(
                ofRelativePath: relativePath,
                maximumBytes: 2_000_000
            )
        }
        await secondChunkGate.waitUntilStarted()
        try FileManager.default.moveItem(at: sourceURL, to: movedURL)
        try createSymlinkOrSkip(at: sourceURL, destination: targetURL)
        await secondChunkGate.release()

        do {
            _ = try await readTask.value
            XCTFail("Expected a symlink retarget to fail closed.")
        } catch FileContentValidationError.fingerprintChanged {
            // Descriptor identity changed when the original path moved.
        } catch FileSystemError.invalidRelativePath {
            // Pathname validation observed the symlink replacement.
        }
        await service.setContentReadChunkHandlerForTesting(nil)

        let nestedRelativePath = "Nested/Intermediate.swift"
        let nestedDirectoryURL = root.appendingPathComponent("Nested")
        let movedDirectoryURL = outside.appendingPathComponent("MovedNested")
        try FileManager.default.createDirectory(
            at: nestedDirectoryURL,
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x62, count: 1_500_000)
            .write(to: root.appendingPathComponent(nestedRelativePath))
        let intermediateGate = AsyncGate()
        let intermediateCounter = AsyncCounter()
        await service.setContentReadChunkHandlerForTesting { path in
            guard path == nestedRelativePath else { return }
            if await intermediateCounter.incrementAndValue() == 2 {
                await intermediateGate.markStartedAndWaitForRelease()
            }
        }
        let intermediateTask = Task {
            try await service.loadValidatedRawContent(
                ofRelativePath: nestedRelativePath,
                maximumBytes: 2_000_000
            )
        }
        await intermediateGate.waitUntilStarted()
        try FileManager.default.moveItem(at: nestedDirectoryURL, to: movedDirectoryURL)
        try createSymlinkOrSkip(at: nestedDirectoryURL, destination: movedDirectoryURL)
        await intermediateGate.release()

        do {
            _ = try await intermediateTask.value
            XCTFail("Expected an intermediate-directory retarget outside the root to fail closed.")
        } catch FileContentValidationError.fingerprintChanged {
            // Descriptor identity changed when the original directory moved.
        } catch FileSystemError.invalidRelativePath {
            // Canonical containment observed the outside-root directory symlink.
        }
        await service.setContentReadChunkHandlerForTesting(nil)
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

    #if DEBUG
    #endif

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
                try await service.loadContent(ofRelativePath: "File-\(index).txt", workloadClass: .contentSearch)
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
            XCTAssertEqual(limiterSnapshot.activePermitCount, 0)
            XCTAssertEqual(limiterSnapshot.queuedWaiterCount, 0)
            XCTAssertEqual(limiterSnapshot.ownerLaneCount, 0)
            XCTAssertTrue(limiterSnapshot.isIdle)
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

            let reserveLimiter = ContentReadAsyncLimiter(
                capacity: 1,
                maxQueuedWaiterCount: 2,
                retryAfterMilliseconds: 777
            )
            let reserveGate = AsyncGate()
            let reserveRecorder = AsyncValueRecorder()
            let reserveHeld = Task {
                try await reserveLimiter.withPermit(workloadClass: .contentSearch, ownerID: UUID()) {
                    await reserveGate.markStartedAndWaitForRelease()
                }
            }
            await reserveGate.waitUntilStarted()
            let foregroundToken = await reserveLimiter.beginForegroundActivity(kind: .storeBackedSearch)
            let reservedCodemap = Task {
                try await reserveLimiter.withPermit(workloadClass: .codemap, ownerID: UUID()) {
                    await reserveRecorder.append(2)
                }
            }
            _ = await waitForLimiterSnapshot(reserveLimiter) { $0.queuedCodemapWaiterCount == 1 }
            do {
                _ = try await reserveLimiter.withPermit(workloadClass: .codemap, ownerID: UUID()) { 0 }
                XCTFail("Expected the codemap queue reserve to reject another background waiter")
            } catch let error as ContentReadSchedulerError {
                XCTAssertEqual(error, .queueFull(retryAfterMilliseconds: 777))
            }
            let reservedForeground = Task {
                try await reserveLimiter.withPermit(workloadClass: .contentSearch, ownerID: UUID()) {
                    await reserveRecorder.append(1)
                }
            }
            let fullButForegroundAdmitted = await waitForLimiterSnapshot(reserveLimiter) {
                $0.queuedWaiterCount == 2
            }
            XCTAssertEqual(fullButForegroundAdmitted.queuedCodemapWaiterCount, 1)

            await reserveLimiter.endForegroundActivity(foregroundToken)
            await reserveGate.release()
            _ = try await reserveHeld.value
            _ = try await reservedForeground.value
            _ = try await reservedCodemap.value
            let reservedValues = await reserveRecorder.values()
            XCTAssertEqual(reservedValues, [1, 2])
            let reserveIdle = await waitForLimiterSnapshot(reserveLimiter) { $0.isIdle }
            XCTAssertTrue(reserveIdle.isIdle)
            XCTAssertEqual(reserveIdle.overloadCount, 1)
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

        func testContentReadSchedulerNeverPromotesAgedCodemapAheadOfForegroundWaiters() async throws {
            for foregroundWorkload in [ContentReadWorkloadClass.interactiveRead, .contentSearch] {
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
                let agedCodemap = Task {
                    try await limiter.withPermit(workloadClass: .codemap, ownerID: UUID()) {
                        await recorder.append(2)
                    }
                }
                _ = await waitForLimiterSnapshot(limiter) { $0.queuedWaiterCount == 1 }
                clock.advance(by: 20_000_000)
                let foreground = Task {
                    try await limiter.withPermit(workloadClass: foregroundWorkload, ownerID: UUID()) {
                        await recorder.append(1)
                    }
                }
                _ = await waitForLimiterSnapshot(limiter) { $0.queuedWaiterCount == 2 }

                await gate.release()
                _ = try await held.value
                _ = try await foreground.value
                _ = try await agedCodemap.value

                let values = await recorder.values()
                XCTAssertEqual(values, [1, 2], foregroundWorkload.rawValue)
                let idle = await waitForLimiterSnapshot(limiter) { $0.isIdle }
                XCTAssertTrue(idle.isIdle, foregroundWorkload.rawValue)
            }
        }

        func testContentReadSchedulerForegroundTokensBlockCodemapReplacementUntilFinalEnd() async throws {
            let limiter = ContentReadAsyncLimiter(capacity: 1, maxQueuedWaiterCount: 8)
            let activeGate = AsyncGate()
            let recorder = AsyncValueRecorder()
            let active = Task {
                try await limiter.withPermit(workloadClass: .codemap, ownerID: UUID()) {
                    await activeGate.markStartedAndWaitForRelease()
                }
            }
            await activeGate.waitUntilStarted()

            let materialization = await limiter.beginForegroundActivity(kind: .materialization)
            let search = await limiter.beginForegroundActivity(kind: .storeBackedSearch)
            let ownerA = UUID()
            let ownerB = UUID()
            var queued: [Task<Void, Error>] = []
            queued.append(Task { try await limiter.withPermit(workloadClass: .codemap, ownerID: ownerA) { await recorder.append(1) } })
            _ = await waitForLimiterSnapshot(limiter) { $0.queuedCodemapWaiterCount == 1 }
            queued.append(Task { try await limiter.withPermit(workloadClass: .codemap, ownerID: ownerA) { await recorder.append(2) } })
            _ = await waitForLimiterSnapshot(limiter) { $0.queuedCodemapWaiterCount == 2 }
            queued.append(Task { try await limiter.withPermit(workloadClass: .codemap, ownerID: ownerB) { await recorder.append(3) } })
            _ = await waitForLimiterSnapshot(limiter) { $0.queuedCodemapWaiterCount == 3 }
            queued.append(Task { try await limiter.withPermit(workloadClass: .codemap, ownerID: ownerB) { await recorder.append(4) } })
            let blocked = await waitForLimiterSnapshot(limiter) { $0.queuedCodemapWaiterCount == 4 }
            XCTAssertEqual(blocked.foregroundActivityCount, 2)
            XCTAssertEqual(blocked.foregroundActivityCountsByKind, [.materialization: 1, .storeBackedSearch: 1])
            XCTAssertEqual(blocked.activeCodemapPermitCount, 1)

            await activeGate.release()
            _ = try await active.value
            let noReplacement = await waitForLimiterSnapshot(limiter) {
                $0.activeCodemapPermitCount == 0 && $0.queuedCodemapWaiterCount == 4
            }
            XCTAssertEqual(noReplacement.bulkGrantCount, 1)
            XCTAssertEqual(noReplacement.codemapGrantWhileForegroundCount, 0)

            await limiter.endForegroundActivity(materialization)
            let oneToken = await limiter.snapshotForTesting()
            XCTAssertEqual(oneToken.foregroundActivityCount, 1)
            XCTAssertEqual(oneToken.activeCodemapPermitCount, 0)
            XCTAssertEqual(oneToken.queuedCodemapWaiterCount, 4)

            await limiter.endForegroundActivity(search)
            for task in queued {
                _ = try await task.value
            }
            let recordedValues = await recorder.values()
            XCTAssertEqual(recordedValues, [1, 3, 2, 4])
            let idle = await waitForLimiterSnapshot(limiter) { $0.isIdle }
            XCTAssertTrue(idle.isIdle)
            XCTAssertEqual(idle.foregroundActivityCount, 0)
            XCTAssertEqual(idle.activeCodemapPermitCount, 0)
            XCTAssertEqual(idle.queuedCodemapWaiterCount, 0)
            XCTAssertEqual(idle.codemapGrantWhileForegroundCount, 0)
        }

        func testForegroundActivityTokensCleanUpOnSuccessErrorAndCancellation() async throws {
            let limiter = ContentReadAsyncLimiter(capacity: 1, maxQueuedWaiterCount: 2)

            let value = await limiter.withForegroundActivity(kind: .rootLoad) {
                let active = await limiter.snapshotForTesting()
                XCTAssertEqual(active.foregroundActivityCountsByKind, [.rootLoad: 1])
                return 42
            }
            XCTAssertEqual(value, 42)
            let afterSuccess = await limiter.snapshotForTesting()
            XCTAssertEqual(afterSuccess.foregroundActivityCount, 0)

            do {
                _ = try await limiter.withForegroundActivity(kind: .readResolution) {
                    throw ForegroundActivityTestError.expected
                }
                XCTFail("Expected foreground body error")
            } catch ForegroundActivityTestError.expected {
                // Expected.
            }
            let afterError = await limiter.snapshotForTesting()
            XCTAssertEqual(afterError.foregroundActivityCount, 0)

            let started = AsyncSignal()
            let cancelled = Task {
                try await limiter.withForegroundActivity(kind: .interactiveRead) {
                    await started.mark()
                    try await Task.sleep(for: .seconds(60))
                }
            }
            let didStart = await started.waitUntilMarked()
            XCTAssertTrue(didStart)
            cancelled.cancel()
            do {
                try await cancelled.value
                XCTFail("Expected foreground body cancellation")
            } catch is CancellationError {
                // Expected.
            }

            let idle = await waitForLimiterSnapshot(limiter) { $0.isIdle }
            XCTAssertTrue(idle.isIdle)
            XCTAssertEqual(idle.foregroundActivityCount, 0)
            XCTAssertTrue(idle.foregroundActivityCountsByKind.isEmpty)
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

    func testTestModeKeepsContentReadOnSerialFallbackWithoutInvokingWorkerHook() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemContentLoadingTestMode")
        try FileSystemTestSupport.write("serial", to: root.appendingPathComponent("Serial.txt"))
        let service = try await FileSystemService(
            path: root.path,
            respectRepoIgnore: false,
            respectCursorignore: false,
            skipSymlinks: true,
            testIgnoreRules: IgnoreRules(policy: .nonGitRoot),
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

    private var createdFileFlags: FSEventStreamEventFlags {
        FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
    }

    private func makeService(root: URL, skipSymlinks: Bool = true) async throws -> FileSystemService {
        try await FileSystemService(
            path: root.path,
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

private enum ForegroundActivityTestError: Error {
    case expected
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
