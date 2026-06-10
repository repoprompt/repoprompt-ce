import CoreServices
@testable import RepoPrompt
import XCTest

final class FileSystemServiceRecoveryTests: XCTestCase {
    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testTempRootCreateEditReadExistsAndModificationDate() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemServiceRecovery")
        let service = try await FileSystemService(
            path: root.path,
            respectGitignore: false,
            respectRepoIgnore: false,
            respectCursorignore: false,
            skipSymlinks: true
        )

        try await service.createFile(atRelativePath: "src/Note.txt", content: "first")
        let existsAfterCreate = await service.fileExistsOnDisk(relativePath: "src/../src/Note.txt")
        let contentAfterCreate = try await service.loadContent(ofRelativePath: "src/./Note.txt")
        XCTAssertTrue(existsAfterCreate)
        XCTAssertEqual(contentAfterCreate, "first")

        try await service.editFile(atRelativePath: "src/Note.txt", newContent: "second")
        let loaded = try await service.loadContentWithDate(ofRelativePath: "src/Note.txt")
        XCTAssertEqual(loaded.content, "second")
        XCTAssertGreaterThan(loaded.modificationDate.timeIntervalSince1970, 0)
    }

    #if DEBUG
        func testFolderScanCapSchedulesQuietFollowUpBatchesThroughAcceptedWatermark() async throws {
            let root = try temporaryRoots.makeRoot(suiteName: "FileSystemFolderScanCap")
            let folders = ["A", "B", "C"]
            for folder in folders {
                let folderURL = root.appendingPathComponent(folder, isDirectory: true)
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                try "new".write(
                    to: folderURL.appendingPathComponent("new.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }

            let service = try await FileSystemService(
                path: root.path,
                respectGitignore: false,
                respectRepoIgnore: false,
                respectCursorignore: false,
                skipSymlinks: true,
                enableHierarchicalIgnores: false,
                testVisitedPaths: Set(folders),
                testVisitedItems: Dictionary(uniqueKeysWithValues: folders.map { ($0, true) }),
                isTestMode: true,
                maxFoldersPerBatchOverride: 2
            )
            let flags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile
            )
            let watermarkValue = await service.acceptWatcherPayloadForTesting(folders.map { folder in
                (
                    absolutePath: root.appendingPathComponent("\(folder)/new.txt").path,
                    flags: flags,
                    eventId: 1
                )
            })
            let watermark = try XCTUnwrap(watermarkValue)

            _ = await service.flushPendingEventsNow(throughAcceptedWatcherWatermark: watermark)

            let processed = await service.getProcessedFolders()
            let state = await service.getCoalescingState()
            let publication = await service.publicationStateForTesting()
            XCTAssertEqual(processed, Set(folders))
            XCTAssertTrue(state.pendingScanTargets.isEmpty)
            XCTAssertEqual(
                state.lastScannedEventIdByFolder,
                Dictionary(uniqueKeysWithValues: folders.map { ($0, FSEventStreamEventId(1)) })
            )
            XCTAssertEqual(publication.lastPublishedWatcherAcceptedWatermark, watermark)
        }

        func testCarryOverFolderScansPreserveIntermediateWatermarkUnderContinuousChurn() async throws {
            let root = try temporaryRoots.makeRoot(suiteName: "FileSystemFolderScanFairness")
            let folders = ["A", "B", "C"]
            for folder in folders {
                let folderURL = root.appendingPathComponent(folder, isDirectory: true)
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                try "initial".write(
                    to: folderURL.appendingPathComponent("initial.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }

            let service = try await FileSystemService(
                path: root.path,
                respectGitignore: false,
                respectRepoIgnore: false,
                respectCursorignore: false,
                skipSymlinks: true,
                enableHierarchicalIgnores: false,
                testVisitedPaths: Set(folders),
                testVisitedItems: Dictionary(uniqueKeysWithValues: folders.map { ($0, true) }),
                isTestMode: true,
                maxFoldersPerBatchOverride: 1
            )
            let batchGate = SteppedBatchGate()
            await service.setWatcherBatchWillProcessHandlerForTesting {
                await batchGate.markStartedAndWaitForRelease()
            }
            let flags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile
            )
            let initialWatermarkValue = await service.acceptWatcherPayloadForTesting(folders.map { folder in
                (
                    absolutePath: root.appendingPathComponent("\(folder)/initial.txt").path,
                    flags: flags,
                    eventId: 1
                )
            })
            let initialWatermark = try XCTUnwrap(initialWatermarkValue)
            await batchGate.waitUntilStartCount(1)

            let intermediateFlush = Task {
                await service.flushPendingEventsNow(throughAcceptedWatcherWatermark: initialWatermark)
            }
            var latestWatermark = initialWatermark
            for eventID in 2 ... 4 {
                // Keep churn paths absent so every accepted event deterministically requires parent verification.
                let churnURL = root.appendingPathComponent("A/churn-\(eventID).txt")
                let churnWatermark = await service.acceptWatcherPayloadForTesting([
                    (absolutePath: churnURL.path, flags: flags, eventId: FSEventStreamEventId(eventID))
                ], scheduleDrain: false)
                latestWatermark = try XCTUnwrap(churnWatermark)
                await service.drainAcceptedWatcherIngressMailbox()
                await batchGate.releaseNext()
                if eventID < 4 {
                    await batchGate.waitUntilStartCount(Int(eventID))
                }
            }
            await batchGate.releaseAll()

            let intermediateSequence = await intermediateFlush.value
            let finalSequence = await service.flushPendingEventsNow(
                throughAcceptedWatcherWatermark: latestWatermark
            )
            let batches = await service.getProcessedFolderBatches()
            let state = await service.getCoalescingState()
            let publication = await service.publicationStateForTesting()

            let processedFolders = batches.flatMap(\.self)
            XCTAssertEqual(Array(processedFolders.prefix(2)), ["A", "B"])
            let firstCBatchIndex = try XCTUnwrap(batches.firstIndex(where: { $0.contains("C") }))
            XCTAssertLessThanOrEqual(firstCBatchIndex, 3)
            XCTAssertGreaterThanOrEqual(processedFolders.count(where: { $0 == "A" }), 2)
            XCTAssertGreaterThan(intermediateSequence, 0)
            XCTAssertGreaterThanOrEqual(finalSequence, intermediateSequence)
            XCTAssertTrue(state.pendingScanTargets.isEmpty)
            XCTAssertEqual(state.lastScannedEventIdByFolder["A"], 4)
            XCTAssertEqual(state.lastScannedEventIdByFolder["B"], 1)
            XCTAssertEqual(state.lastScannedEventIdByFolder["C"], 1)
            XCTAssertEqual(publication.lastPublishedWatcherAcceptedWatermark, latestWatermark)
            await service.setWatcherBatchWillProcessHandlerForTesting(nil)
        }

        private actor SteppedBatchGate {
            private var startCount = 0
            private var releasePermits = 0
            private var releasesAllBatches = false
            private var startWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

            func markStartedAndWaitForRelease() async {
                startCount += 1
                let readyWaiters = startWaiters.filter { $0.target <= startCount }
                startWaiters.removeAll { $0.target <= startCount }
                readyWaiters.forEach { $0.continuation.resume() }

                if releasesAllBatches { return }
                if releasePermits > 0 {
                    releasePermits -= 1
                    return
                }
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }

            func waitUntilStartCount(_ target: Int) async {
                guard startCount < target else { return }
                await withCheckedContinuation { continuation in
                    startWaiters.append((target, continuation))
                }
            }

            func releaseNext() {
                if releaseWaiters.isEmpty {
                    releasePermits += 1
                } else {
                    releaseWaiters.removeFirst().resume()
                }
            }

            func releaseAll() {
                releasesAllBatches = true
                let waiters = releaseWaiters
                releaseWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
    #endif
}
