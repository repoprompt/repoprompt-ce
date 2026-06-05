import Combine
@testable import RepoPrompt
import XCTest

final class FileSystemAcceptedIngressBarrierTests: XCTestCase {
    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testAcceptedBeforeAndAfterCaptureCutsPublishIndependentWatermarks() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemAcceptedIngressBarrier")
        let service = try await makeService(root: root)
        let publications = LockedPublications()
        let publisher = await service.publisherForChanges()
        let cancellable = publisher.sink { publications.append($0) }

        let acceptedBefore = await service.acceptWatcherPayloadForTesting([
            (absolutePath: "/outside/before.swift", flags: createdFileFlags, eventId: 1)
        ], scheduleDrain: false)
        let before = try XCTUnwrap(acceptedBefore)
        let captured = service.captureAcceptedWatcherWatermark()
        let acceptedAfter = await service.acceptWatcherPayloadForTesting([
            (absolutePath: "/outside/after.swift", flags: createdFileFlags, eventId: 2)
        ], scheduleDrain: false)
        let after = try XCTUnwrap(acceptedAfter)

        XCTAssertEqual(captured, before)
        XCTAssertGreaterThan(after, captured)
        _ = await service.flushPendingEventsNow(throughAcceptedWatcherWatermark: captured)

        var snapshot = publications.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot[0].source, .watcherBarrierNoop)
        XCTAssertEqual(snapshot[0].watcherAcceptedWatermark, before)
        XCTAssertTrue(snapshot[0].deltas.isEmpty)
        let queuedAfterFirstCut = await service.watcherIngressMailboxSnapshotForTesting()
        XCTAssertEqual(queuedAfterFirstCut.queuedRawEntryCount, 1)

        _ = await service.flushPendingEventsNow(throughAcceptedWatcherWatermark: after)
        snapshot = publications.snapshot()
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot[1].source, .watcherBarrierNoop)
        XCTAssertEqual(snapshot[1].watcherAcceptedWatermark, after)
        XCTAssertTrue(snapshot[1].deltas.isEmpty)
        let queuedAfterSecondCut = await service.watcherIngressMailboxSnapshotForTesting()
        XCTAssertEqual(queuedAfterSecondCut.queuedRawEntryCount, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testNoDeltaAcceptedPayloadAdvancesPublishedWatcherWatermark() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemAcceptedIngressNoop")
        let service = try await makeService(root: root)
        let publications = LockedPublications()
        let publisher = await service.publisherForChanges()
        let cancellable = publisher.sink { publications.append($0) }

        let acceptedPayload = await service.acceptWatcherPayloadForTesting([
            (absolutePath: "/outside/no-delta.swift", flags: createdFileFlags, eventId: 10)
        ], scheduleDrain: false)
        let accepted = try XCTUnwrap(acceptedPayload)
        let sequence = await service.flushPendingEventsNow(throughAcceptedWatcherWatermark: accepted)
        let publication = try XCTUnwrap(publications.snapshot().last)
        let serviceState = await service.publicationStateForTesting()

        XCTAssertGreaterThan(sequence, 0)
        XCTAssertEqual(publication.source, .watcherBarrierNoop)
        XCTAssertEqual(publication.watcherAcceptedWatermark, accepted)
        XCTAssertTrue(publication.deltas.isEmpty)
        XCTAssertEqual(serviceState.lastPublishedWatcherAcceptedWatermark, accepted)
        withExtendedLifetime(cancellable) {}
    }

    func testMailboxOverflowRootRescanPreservesHighestAcceptedWatermark() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemAcceptedIngressOverflow")
        let service = try await makeService(root: root, maxPendingWatcherIngressEntries: 2)
        let publications = LockedPublications()
        let publisher = await service.publisherForChanges()
        let cancellable = publisher.sink { publications.append($0) }

        var highest = FileSystemWatcherIngressMailbox.Watermark.zero
        for eventID in 1 ... 3 {
            let acceptedPayload = await service.acceptWatcherPayloadForTesting([
                (absolutePath: "/outside/overflow-\(eventID).swift", flags: createdFileFlags, eventId: FileSystemWatchEventID(eventID))
            ], scheduleDrain: false)
            highest = try XCTUnwrap(acceptedPayload)
        }
        let mailbox = await service.watcherIngressMailboxSnapshotForTesting()
        XCTAssertTrue(mailbox.hasOverflowRootRescan)
        XCTAssertEqual(mailbox.queuedPayloadCount, 1)
        XCTAssertEqual(mailbox.queuedRawEntryCount, 1)
        XCTAssertEqual(mailbox.acceptedHighWatermark, highest)

        _ = await service.flushPendingEventsNow(throughAcceptedWatcherWatermark: highest)
        let publication = try XCTUnwrap(publications.snapshot().last)
        XCTAssertEqual(publication.source, .overflowRootRescan)
        XCTAssertEqual(publication.watcherAcceptedWatermark, highest)
        let serviceState = await service.publicationStateForTesting()
        XCTAssertEqual(serviceState.lastPublishedWatcherAcceptedWatermark, highest)
        withExtendedLifetime(cancellable) {}
    }

    func testFlushWaitsForInFlightWatcherBatchBeforePublishingAcceptedCut() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemAcceptedIngressInFlight")
        let service = try await makeService(root: root)
        let publications = LockedPublications()
        let publisher = await service.publisherForChanges()
        let cancellable = publisher.sink { publications.append($0) }
        let processingGate = AsyncGate()
        let flushCompleted = AsyncSignal()

        await service.setWatcherBatchWillProcessHandlerForTesting {
            await processingGate.markStartedAndWaitForRelease()
        }
        let acceptedPayload = await service.acceptWatcherPayloadForTesting([
            (absolutePath: "/outside/in-flight.swift", flags: createdFileFlags, eventId: 20)
        ])
        let accepted = try XCTUnwrap(acceptedPayload)
        await processingGate.waitUntilStarted()

        let flushTask = Task {
            let sequence = await service.flushPendingEventsNow(throughAcceptedWatcherWatermark: accepted)
            await flushCompleted.mark()
            return sequence
        }
        await Task.yield()
        let completedBeforeRelease = await flushCompleted.isMarked()
        XCTAssertFalse(completedBeforeRelease)
        XCTAssertTrue(publications.snapshot().isEmpty)

        await processingGate.release()
        let sequence = await flushTask.value
        let publication = try XCTUnwrap(publications.snapshot().last)
        XCTAssertGreaterThan(sequence, 0)
        XCTAssertEqual(publication.watcherAcceptedWatermark, accepted)
        await service.setWatcherBatchWillProcessHandlerForTesting(nil)
        withExtendedLifetime(cancellable) {}
    }

    func testMailboxOverflowPreservesIgnoreChangeAlreadyBufferedOnActor() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemAcceptedIngressOverflowIgnore")
        let ignoreURL = root.appendingPathComponent(".gitignore")
        try "*.generated\n".write(to: ignoreURL, atomically: true, encoding: .utf8)
        let service = try await makeService(root: root, maxPendingWatcherIngressEntries: 2)

        await service.enqueuePendingRawEventsForTesting([
            (absolutePath: ignoreURL.path, flags: modifiedFileFlags, eventId: 30)
        ])
        var highest = FileSystemWatcherIngressMailbox.Watermark.zero
        for eventID in 31 ... 33 {
            let acceptedPayload = await service.acceptWatcherPayloadForTesting([
                (absolutePath: "/outside/overflow-ignore-\(eventID).swift", flags: createdFileFlags, eventId: FileSystemWatchEventID(eventID))
            ], scheduleDrain: false)
            highest = try XCTUnwrap(acceptedPayload)
        }

        _ = await service.flushPendingEventsNow(throughAcceptedWatcherWatermark: highest)
        let pendingIgnoreChangeDirs = await service.getPendingIgnoreChangeDirs()
        XCTAssertTrue(pendingIgnoreChangeDirs.contains(""))
    }

    func testMailboxStaleDrainCompletionDoesNotClearRestartDrain() async {
        let mailbox = FileSystemWatcherIngressMailbox(maxQueuedRawEntries: 10)
        let oldDrainGate = AsyncGate()
        let newDrainGate = AsyncGate()
        let oldDrainCount = AsyncCounter()
        let newDrainCount = AsyncCounter()
        let firstPayload = callbackPayload(path: "/outside/old.swift", eventID: 40)
        let secondPayload = callbackPayload(path: "/outside/new.swift", eventID: 41)

        let oldAcceptanceGeneration = mailbox.startAccepting()
        _ = mailbox.accept(firstPayload, acceptanceGeneration: oldAcceptanceGeneration, lifecycleCorrelation: nil) {
            let invocation = await oldDrainCount.incrementAndValue()
            if invocation == 1 {
                await oldDrainGate.markStartedAndWaitForRelease()
            } else {
                while mailbox.takeNextAcceptedPayload() != nil {}
            }
        }
        await oldDrainGate.waitUntilStarted()
        mailbox.stopAcceptingAndDiscardPending()
        let newAcceptanceGeneration = mailbox.startAccepting()

        _ = mailbox.accept(secondPayload, acceptanceGeneration: newAcceptanceGeneration, lifecycleCorrelation: nil) {
            _ = await newDrainCount.incrementAndValue()
            await newDrainGate.markStartedAndWaitForRelease()
            while mailbox.takeNextAcceptedPayload() != nil {}
        }
        await newDrainGate.waitUntilStarted()
        await oldDrainGate.release()
        await Task.yield()
        await Task.yield()

        let observedOldDrainCount = await oldDrainCount.value()
        let observedNewDrainCount = await newDrainCount.value()
        XCTAssertEqual(observedOldDrainCount, 1)
        XCTAssertEqual(observedNewDrainCount, 1)
        await newDrainGate.release()
    }

    func testMailboxRejectsOldAcceptanceGenerationAfterRestart() {
        let mailbox = FileSystemWatcherIngressMailbox(maxQueuedRawEntries: 10)
        let oldAcceptanceGeneration = mailbox.startAccepting()
        let oldPayload = callbackPayload(path: "/outside/old.swift", eventID: 42)
        let newPayload = callbackPayload(path: "/outside/new.swift", eventID: 43)

        XCTAssertNotNil(mailbox.accept(
            oldPayload,
            acceptanceGeneration: oldAcceptanceGeneration,
            lifecycleCorrelation: nil,
            scheduleDrain: nil
        ))
        mailbox.stopAcceptingAndDiscardPending()
        let newAcceptanceGeneration = mailbox.startAccepting()

        XCTAssertNil(mailbox.accept(
            oldPayload,
            acceptanceGeneration: oldAcceptanceGeneration,
            lifecycleCorrelation: nil,
            scheduleDrain: nil
        ))
        XCTAssertNotNil(mailbox.accept(
            newPayload,
            acceptanceGeneration: newAcceptanceGeneration,
            lifecycleCorrelation: nil,
            scheduleDrain: nil
        ))
    }

    func testSyntheticPublicationDoesNotAdvanceWatcherAcceptedWatermark() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemAcceptedIngressSynthetic")
        let service = try await makeService(root: root)
        let publications = LockedPublications()
        let publisher = await service.publisherForChanges()
        let cancellable = publisher.sink { publications.append($0) }

        let before = service.captureAcceptedWatcherWatermark()
        let sequence = await service.publishFileSystemDeltas([.fileAdded("Synthetic.swift")], source: .syntheticMutation)
        let after = service.captureAcceptedWatcherWatermark()
        let publication = try XCTUnwrap(publications.snapshot().last)

        XCTAssertGreaterThan(sequence, 0)
        XCTAssertEqual(before, .zero)
        XCTAssertEqual(after, before)
        XCTAssertEqual(publication.source, .syntheticMutation)
        XCTAssertNil(publication.watcherAcceptedWatermark)
        XCTAssertEqual(publication.servicePublicationSequence, sequence)
        withExtendedLifetime(cancellable) {}
    }

    private var createdFileFlags: FileSystemWatchEventFlags {
        [.itemCreated, .itemIsFile]
    }

    private var modifiedFileFlags: FileSystemWatchEventFlags {
        [.contentChanged, .itemIsFile]
    }

    private func callbackPayload(path: String, eventID: FileSystemWatchEventID) -> FileSystemWatchEventPayload {
        FileSystemWatchEventPayload(entries: [
            FileSystemWatchEvent(path: path, flags: createdFileFlags, id: eventID)
        ])
    }

    private func makeService(
        root: URL,
        maxPendingWatcherIngressEntries: Int? = nil
    ) async throws -> FileSystemService {
        try await FileSystemService(
            path: root.path,
            respectGitignore: false,
            respectRepoIgnore: false,
            respectCursorignore: false,
            skipSymlinks: true,
            isTestMode: true,
            maxPendingWatcherIngressEntriesOverride: maxPendingWatcherIngressEntries
        )
    }

    private final class LockedPublications: @unchecked Sendable {
        private let lock = NSLock()
        private var publications: [FileSystemDeltaPublication] = []

        func append(_ publication: FileSystemDeltaPublication) {
            lock.lock()
            publications.append(publication)
            lock.unlock()
        }

        func snapshot() -> [FileSystemDeltaPublication] {
            lock.lock()
            defer { lock.unlock() }
            return publications
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

private actor AsyncSignal {
    private var marked = false

    func mark() {
        marked = true
    }

    func isMarked() -> Bool {
        marked
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
}
