import Combine
import CoreServices
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

    func testIgnoredEventsBeyondMailboxCapAreFilteredBeforeOverflow() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemAcceptedIngressEarlyIgnore")
        try ".build/\n".write(
            to: root.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        let service = try await makeService(
            root: root,
            maxPendingWatcherIngressEntries: 2,
            respectGitignore: true
        )

        for eventID in 1 ... 10 {
            let accepted = await service.acceptWatcherPayloadForTesting([
                (
                    absolutePath: root.appendingPathComponent(".build/churn-\(eventID).o").path,
                    flags: createdFileFlags,
                    eventId: FSEventStreamEventId(eventID)
                )
            ], scheduleDrain: false)
            XCTAssertNil(accepted)
        }

        let mailbox = await service.watcherIngressMailboxSnapshotForTesting()
        XCTAssertFalse(mailbox.hasOverflowRootRescan)
        XCTAssertEqual(mailbox.queuedPayloadCount, 0)
        XCTAssertEqual(mailbox.queuedRawEntryCount, 0)
        XCTAssertEqual(mailbox.acceptedHighWatermark, .zero)
        let filter = await service.watcherEarlyFilterSnapshotForTesting()
        XCTAssertTrue(filter.isValid)
        XCTAssertEqual(filter.filteredEntryCount, 10)
    }

    func testMixedIgnoredAndVisibleEventsPreserveVisibleOrderingAndWatermarks() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemAcceptedIngressEarlyMixed")
        try ".build/\n".write(
            to: root.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        let service = try await makeService(root: root, respectGitignore: true)
        let firstVisiblePath = root.appendingPathComponent("Sources/First.swift").path
        let secondVisiblePath = root.appendingPathComponent("Sources/Second.swift").path

        let firstAccepted = await service.acceptWatcherPayloadForTesting([
            (absolutePath: root.appendingPathComponent(".build/first.o").path, flags: createdFileFlags, eventId: 1),
            (absolutePath: firstVisiblePath, flags: createdFileFlags, eventId: 2)
        ], scheduleDrain: false)
        let firstWatermark = try XCTUnwrap(firstAccepted)
        let secondAccepted = await service.acceptWatcherPayloadForTesting([
            (absolutePath: root.appendingPathComponent(".build/second.o").path, flags: createdFileFlags, eventId: 3),
            (absolutePath: secondVisiblePath, flags: createdFileFlags, eventId: 4)
        ], scheduleDrain: false)
        let secondWatermark = try XCTUnwrap(secondAccepted)

        XCTAssertLessThan(firstWatermark, secondWatermark)
        let firstPayload = try XCTUnwrap(service.watcherIngressMailbox.takeNextAcceptedPayload())
        let secondPayload = try XCTUnwrap(service.watcherIngressMailbox.takeNextAcceptedPayload())
        guard case let .entries(firstEntries) = firstPayload.contents,
              case let .entries(secondEntries) = secondPayload.contents
        else {
            return XCTFail("Expected visible entries to remain as ordered mailbox payloads")
        }
        XCTAssertEqual(firstEntries.map(\.path), [firstVisiblePath])
        XCTAssertEqual(secondEntries.map(\.path), [secondVisiblePath])
        XCTAssertEqual(firstPayload.acceptedHighWatermark, firstWatermark)
        XCTAssertEqual(secondPayload.acceptedHighWatermark, secondWatermark)
    }

    func testIgnoreControlEventsInvalidateFilterAndEnterIngressUnchanged() async throws {
        let root = try temporaryRoots.makeRoot(suiteName: "FileSystemAcceptedIngressEarlyIgnoreChange")
        let ignoreURL = root.appendingPathComponent(".gitignore")
        try ".build/\n".write(to: ignoreURL, atomically: true, encoding: .utf8)
        let service = try await makeService(root: root, respectGitignore: true)
        let ignoredPath = root.appendingPathComponent(".build/generated.o").path

        let initiallyIgnored = await service.acceptWatcherPayloadForTesting([
            (absolutePath: ignoredPath, flags: createdFileFlags, eventId: 1)
        ], scheduleDrain: false)
        XCTAssertNil(initiallyIgnored)

        let changeAccepted = await service.acceptWatcherPayloadForTesting([
            (absolutePath: ignoreURL.path, flags: modifiedFileFlags, eventId: 2),
            (absolutePath: ignoredPath, flags: createdFileFlags, eventId: 3)
        ], scheduleDrain: false)
        let changeWatermark = try XCTUnwrap(changeAccepted)
        let followingAccepted = await service.acceptWatcherPayloadForTesting([
            (absolutePath: root.appendingPathComponent(".build/following.o").path, flags: createdFileFlags, eventId: 4)
        ], scheduleDrain: false)
        let followingWatermark = try XCTUnwrap(followingAccepted)

        XCTAssertLessThan(changeWatermark, followingWatermark)
        let mailbox = await service.watcherIngressMailboxSnapshotForTesting()
        XCTAssertEqual(mailbox.queuedPayloadCount, 2)
        XCTAssertEqual(mailbox.queuedRawEntryCount, 3)
        XCTAssertFalse(mailbox.hasOverflowRootRescan)
        let filter = await service.watcherEarlyFilterSnapshotForTesting()
        XCTAssertFalse(filter.isValid)
        XCTAssertEqual(filter.filteredEntryCount, 1)
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
                (absolutePath: "/outside/overflow-\(eventID).swift", flags: createdFileFlags, eventId: FSEventStreamEventId(eventID))
            ], scheduleDrain: false)
            highest = try XCTUnwrap(acceptedPayload)
        }
        let mailbox = await service.watcherIngressMailboxSnapshotForTesting()
        XCTAssertTrue(mailbox.hasOverflowRootRescan)
        XCTAssertEqual(mailbox.queuedPayloadCount, 1)
        XCTAssertEqual(mailbox.queuedRawEntryCount, 1)
        XCTAssertEqual(mailbox.acceptedHighWatermark, highest)
        let filter = await service.watcherEarlyFilterSnapshotForTesting()
        XCTAssertEqual(filter.filteredEntryCount, 0)

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
                (absolutePath: "/outside/overflow-ignore-\(eventID).swift", flags: createdFileFlags, eventId: FSEventStreamEventId(eventID))
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

        _ = mailbox.accept(firstPayload, lifecycleCorrelation: nil) {
            let invocation = await oldDrainCount.incrementAndValue()
            if invocation == 1 {
                await oldDrainGate.markStartedAndWaitForRelease()
            } else {
                while mailbox.takeNextAcceptedPayload() != nil {}
            }
        }
        await oldDrainGate.waitUntilStarted()
        mailbox.stopAcceptingAndDiscardPending()
        mailbox.startAccepting()

        _ = mailbox.accept(secondPayload, lifecycleCorrelation: nil) {
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

    private var createdFileFlags: FSEventStreamEventFlags {
        FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
    }

    private var modifiedFileFlags: FSEventStreamEventFlags {
        FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
    }

    private func callbackPayload(path: String, eventID: FSEventStreamEventId) -> FSEventCallbackPayload {
        FSEventCallbackPayload(entries: [
            FSEventCallbackEntry(path: path, flags: createdFileFlags, id: eventID)
        ])
    }

    private func makeService(
        root: URL,
        maxPendingWatcherIngressEntries: Int? = nil,
        respectGitignore: Bool = false
    ) async throws -> FileSystemService {
        try await FileSystemService(
            path: root.path,
            respectGitignore: respectGitignore,
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
