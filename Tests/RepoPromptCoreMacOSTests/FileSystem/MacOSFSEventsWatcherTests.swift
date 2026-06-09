import CoreFoundation
import CoreServices
import Dispatch
import Foundation
@testable import RepoPromptCore
@testable import RepoPromptCoreMacOS
import XCTest

final class MacOSFSEventsWatcherTests: XCTestCase {
    func testSemanticFlagsMapsNativeMutationAndTypeBits() {
        let rawFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated
                | kFSEventStreamEventFlagItemModified
                | kFSEventStreamEventFlagItemIsFile
        )

        XCTAssertEqual(
            MacOSFSEventsWatcher.semanticFlags(for: rawFlags),
            [.itemCreated, .contentChanged, .itemIsFile]
        )
    }

    func testSemanticFlagsCollapsesNativeReliabilityBits() {
        let rawFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagRootChanged
        )

        XCTAssertEqual(
            MacOSFSEventsWatcher.semanticFlags(for: rawFlags),
            [.mustScanSubdirectories, .droppedEvents, .rootChanged]
        )
    }

    func testBuildOwnedPayloadDeepCopiesMutablePathStorage() throws {
        let mutablePath = NSMutableString(string: "/tmp/original.swift")
        let payload = try XCTUnwrap(ownedPayload(
            paths: [mutablePath] as CFArray,
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)],
            eventIDs: [7]
        ))

        mutablePath.setString("/tmp/mutated.swift")

        XCTAssertEqual(payload.entries, [
            FileSystemWatchEvent(path: "/tmp/original.swift", flags: [.contentChanged], id: 7)
        ])
    }

    func testBuildOwnedPayloadRetainsTemporaryPathAfterCallbackStorageLifetime() throws {
        let payload = try XCTUnwrap(autoreleasepool { () -> FileSystemWatchEventPayload? in
            let temporaryPath = NSMutableString(string: "/tmp/temporary.swift")
            return ownedPayload(
                paths: [temporaryPath] as CFArray,
                flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)],
                eventIDs: [8]
            )
        })

        XCTAssertEqual(payload.entries, [
            FileSystemWatchEvent(path: "/tmp/temporary.swift", flags: [.itemCreated], id: 8)
        ])
    }

    func testSemanticFlagsCollapsesNativeMetadataBits() {
        let rawFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemInodeMetaMod
                | kFSEventStreamEventFlagItemFinderInfoMod
                | kFSEventStreamEventFlagItemChangeOwner
        )

        XCTAssertEqual(MacOSFSEventsWatcher.semanticFlags(for: rawFlags), [.metadataChanged])
    }

    func testStopDuringStartInProgressCancelsAttemptAndRejectsStaleCallback() throws {
        let backend = FakeFSEventStreamBackend()
        let startGate = SemaphoreGate()
        backend.enqueueStartBehavior(.wait(startGate, result: true))
        let watcher = MacOSFSEventsWatcher(path: "/tmp/watcher-start-cancel", streamBackend: backend)
        let payloads = PayloadRecorder()
        let startResult = LockedValue<Bool?>(nil)
        let startFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .utility).async {
            let result = watcher.start { payloads.append($0) }
            startResult.set(result)
            startFinished.signal()
        }

        XCTAssertTrue(startGate.waitUntilEntered(), "Timed out waiting for fake startStream to block")
        let oldStream = try XCTUnwrap(backend.stream(at: 0))

        watcher.stop()

        XCTAssertFalse(watcher.isWatching)
        backend.emit(from: oldStream, path: "/tmp/canceled.swift", eventID: 100)
        XCTAssertEqual(payloads.snapshot(), [])

        startGate.release()
        XCTAssertEqual(startFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(startResult.value(), false)
        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(backend.disposeCount(for: oldStream), 1)
        XCTAssertEqual(backend.disposeRecords(for: oldStream).map(\.wasStarted), [true])
    }

    func testConcurrentStartWaitsForInProgressStartAndKeepsFirstHandler() throws {
        let backend = FakeFSEventStreamBackend()
        let startGate = SemaphoreGate()
        backend.enqueueStartBehavior(.wait(startGate, result: true))
        let watcher = MacOSFSEventsWatcher(path: "/tmp/watcher-concurrent-start", streamBackend: backend)
        let firstPayloads = PayloadRecorder()
        let secondPayloads = PayloadRecorder()
        let firstStartResult = LockedValue<Bool?>(nil)
        let secondStartResult = LockedValue<Bool?>(nil)
        let firstStartFinished = DispatchSemaphore(value: 0)
        let secondStartFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .utility).async {
            let result = watcher.start { firstPayloads.append($0) }
            firstStartResult.set(result)
            firstStartFinished.signal()
        }
        XCTAssertTrue(startGate.waitUntilEntered(), "Timed out waiting for first start to block")

        DispatchQueue.global(qos: .utility).async {
            let result = watcher.start { secondPayloads.append($0) }
            secondStartResult.set(result)
            secondStartFinished.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertNil(secondStartResult.value())

        startGate.release()
        XCTAssertEqual(firstStartFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondStartFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(firstStartResult.value(), true)
        XCTAssertEqual(secondStartResult.value(), true)
        XCTAssertEqual(backend.createdStreamCount, 1)

        let stream = try XCTUnwrap(backend.stream(at: 0))
        backend.emit(from: stream, path: "/tmp/first-handler.swift", eventID: 101)
        XCTAssertEqual(firstPayloads.paths(), ["/tmp/first-handler.swift"])
        XCTAssertEqual(secondPayloads.snapshot(), [])

        watcher.stop()
    }

    func testOldStreamCallbackCannotReachNewHandlerAfterRestart() throws {
        let backend = FakeFSEventStreamBackend()
        let watcher = MacOSFSEventsWatcher(path: "/tmp/watcher-restart", streamBackend: backend)
        let oldPayloads = PayloadRecorder()
        let newPayloads = PayloadRecorder()

        XCTAssertTrue(watcher.start { oldPayloads.append($0) })
        let oldStream = try XCTUnwrap(backend.stream(at: 0))

        let disposeGate = SemaphoreGate()
        backend.enqueueDisposeBehavior(.wait(disposeGate))
        let stopFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            watcher.stop()
            stopFinished.signal()
        }
        XCTAssertTrue(disposeGate.waitUntilEntered(), "Timed out waiting for old stream disposal to block")
        XCTAssertFalse(watcher.isWatching)

        XCTAssertTrue(watcher.start { newPayloads.append($0) })
        let newStream = try XCTUnwrap(backend.stream(at: 1))

        backend.emit(from: oldStream, path: "/tmp/old-stream.swift", eventID: 102)
        XCTAssertEqual(oldPayloads.snapshot(), [])
        XCTAssertEqual(newPayloads.snapshot(), [])

        backend.emit(from: newStream, path: "/tmp/new-stream.swift", eventID: 103)
        XCTAssertEqual(newPayloads.paths(), ["/tmp/new-stream.swift"])

        disposeGate.release()
        XCTAssertEqual(stopFinished.wait(timeout: .now() + 2), .success)
        watcher.stop()
    }

    func testRepeatedStopIsIdempotent() throws {
        let backend = FakeFSEventStreamBackend()
        let watcher = MacOSFSEventsWatcher(path: "/tmp/watcher-stop-idempotent", streamBackend: backend)

        XCTAssertTrue(watcher.start { _ in })
        let stream = try XCTUnwrap(backend.stream(at: 0))

        watcher.stop()
        watcher.stop()
        watcher.stop()

        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(backend.disposeCount(for: stream), 1)
        XCTAssertEqual(backend.totalDisposeCount, 1)
    }

    func testCreateFailureLeavesWatcherStoppedAndAllowsRetry() {
        let backend = FakeFSEventStreamBackend()
        backend.enqueueCreateBehavior(.fail)
        let watcher = MacOSFSEventsWatcher(path: "/tmp/watcher-create-failure", streamBackend: backend)

        XCTAssertFalse(watcher.start { _ in })
        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(backend.createdStreamCount, 0)
        XCTAssertEqual(backend.totalDisposeCount, 0)

        XCTAssertTrue(watcher.start { _ in })
        XCTAssertTrue(watcher.isWatching)
        XCTAssertEqual(backend.createdStreamCount, 1)

        watcher.stop()
    }

    func testStopDuringCreateDisposesUnstartedStreamWithoutCallingStart() throws {
        let backend = FakeFSEventStreamBackend()
        let createGate = SemaphoreGate()
        backend.enqueueCreateBehavior(.wait(createGate, result: true))
        let watcher = MacOSFSEventsWatcher(path: "/tmp/watcher-create-cancel", streamBackend: backend)
        let startResult = LockedValue<Bool?>(nil)
        let startFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .utility).async {
            let result = watcher.start { _ in }
            startResult.set(result)
            startFinished.signal()
        }

        XCTAssertTrue(createGate.waitUntilEntered(), "Timed out waiting for fake createStream to block")
        watcher.stop()
        XCTAssertFalse(watcher.isWatching)

        createGate.release()
        XCTAssertEqual(startFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(startResult.value(), false)
        let canceledStream = try XCTUnwrap(backend.stream(at: 0))
        XCTAssertEqual(backend.startCount(for: canceledStream), 0)
        XCTAssertEqual(backend.disposeRecords(for: canceledStream).map(\.wasStarted), [false])
        XCTAssertFalse(watcher.isWatching)
    }

    func testStartFailureDisposesUnstartedStreamAndAllowsRetry() throws {
        let backend = FakeFSEventStreamBackend()
        backend.enqueueStartBehavior(.fail)
        let watcher = MacOSFSEventsWatcher(path: "/tmp/watcher-start-failure", streamBackend: backend)

        XCTAssertFalse(watcher.start { _ in })
        XCTAssertFalse(watcher.isWatching)
        let failedStream = try XCTUnwrap(backend.stream(at: 0))
        XCTAssertEqual(backend.disposeRecords(for: failedStream).map(\.wasStarted), [false])

        XCTAssertTrue(watcher.start { _ in })
        XCTAssertTrue(watcher.isWatching)
        XCTAssertEqual(backend.createdStreamCount, 2)

        watcher.stop()
    }

    func testStopFromCallbackQueueMarksStoppedAndDefersNativeDisposal() throws {
        let backend = FakeFSEventStreamBackend()
        let disposeGate = SemaphoreGate()
        backend.enqueueDisposeBehavior(.wait(disposeGate))
        let watcher = MacOSFSEventsWatcher(path: "/tmp/watcher-reentrant-stop", streamBackend: backend)
        let payloads = PayloadRecorder()
        let isWatchingAfterStop = LockedValue<Bool?>(nil)

        XCTAssertTrue(watcher.start { payload in
            payloads.append(payload)
            watcher.stop()
            isWatchingAfterStop.set(watcher.isWatching)
        })
        let stream = try XCTUnwrap(backend.stream(at: 0))

        backend.emit(from: stream, path: "/tmp/reentrant-stop.swift", eventID: 104, onCallbackQueue: true)
        XCTAssertEqual(payloads.paths(), ["/tmp/reentrant-stop.swift"])
        XCTAssertEqual(isWatchingAfterStop.value(), false)
        XCTAssertFalse(watcher.isWatching)
        XCTAssertTrue(disposeGate.waitUntilEntered(), "Timed out waiting for deferred disposal")

        backend.emit(from: stream, path: "/tmp/stale-reentrant.swift", eventID: 105)
        XCTAssertEqual(payloads.paths(), ["/tmp/reentrant-stop.swift"])

        disposeGate.release()
        XCTAssertTrue(backend.waitForTotalDisposeCount(1))
    }

    func testActiveWatcherDoesNotSelfRetainAndStopsOnDeinit() throws {
        let backend = FakeFSEventStreamBackend()
        weak var weakWatcher: MacOSFSEventsWatcher?
        var activeStream: FakeFSEventStreamToken?

        autoreleasepool {
            var watcher: MacOSFSEventsWatcher? = MacOSFSEventsWatcher(
                path: "/tmp/watcher-no-self-retain",
                streamBackend: backend
            )
            weakWatcher = watcher
            XCTAssertTrue(watcher?.start { _ in } == true)
            activeStream = backend.stream(at: 0)
            watcher = nil
        }

        XCTAssertNil(weakWatcher)
        let stream = try XCTUnwrap(activeStream)
        XCTAssertEqual(backend.disposeRecords(for: stream).map(\.wasStarted), [true])
    }

    private func ownedPayload(
        paths: CFArray,
        flags: [FSEventStreamEventFlags],
        eventIDs: [FSEventStreamEventId]
    ) -> FileSystemWatchEventPayload? {
        flags.withUnsafeBufferPointer { flagsBuffer in
            eventIDs.withUnsafeBufferPointer { eventIDsBuffer in
                guard let flagsBaseAddress = flagsBuffer.baseAddress,
                      let eventIDsBaseAddress = eventIDsBuffer.baseAddress
                else { return nil }
                return MacOSFSEventsWatcher.buildOwnedPayload(
                    numEvents: flags.count,
                    eventPaths: Unmanaged.passUnretained(paths).toOpaque(),
                    eventFlags: flagsBaseAddress,
                    eventIDs: eventIDsBaseAddress
                )
            }
        }
    }
}

private final class FakeFSEventStreamBackend: MacOSFSEventStreamBackend, @unchecked Sendable {
    enum CreateBehavior {
        case succeed
        case fail
        case wait(SemaphoreGate, result: Bool)
    }

    enum StartBehavior {
        case succeed
        case fail
        case wait(SemaphoreGate, result: Bool)
    }

    enum DisposeBehavior {
        case immediate
        case wait(SemaphoreGate)
    }

    struct DisposeRecord: Equatable {
        let streamID: Int
        let wasStarted: Bool
    }

    private let condition = NSCondition()
    private var nextStreamID = 0
    private var createBehaviors: [CreateBehavior] = []
    private var startBehaviors: [StartBehavior] = []
    private var disposeBehaviors: [DisposeBehavior] = []
    private var streams: [FakeFSEventStreamToken] = []
    private var startRecords: [Int] = []
    private var disposeRecords: [DisposeRecord] = []

    var createdStreamCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return streams.count
    }

    var totalDisposeCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return disposeRecords.count
    }

    func enqueueCreateBehavior(_ behavior: CreateBehavior) {
        condition.lock()
        createBehaviors.append(behavior)
        condition.unlock()
    }

    func enqueueStartBehavior(_ behavior: StartBehavior) {
        condition.lock()
        startBehaviors.append(behavior)
        condition.unlock()
    }

    func enqueueDisposeBehavior(_ behavior: DisposeBehavior) {
        condition.lock()
        disposeBehaviors.append(behavior)
        condition.unlock()
    }

    func createStream(
        path _: String,
        callback: FSEventStreamCallback,
        contextInfo: UnsafeMutableRawPointer,
        callbackQueue: DispatchQueue
    ) -> (any MacOSFSEventStreamToken)? {
        condition.lock()
        let behavior = createBehaviors.isEmpty ? CreateBehavior.succeed : createBehaviors.removeFirst()
        condition.unlock()

        switch behavior {
        case .succeed:
            break
        case .fail:
            return nil
        case let .wait(gate, result):
            gate.markEntered()
            gate.waitForRelease()
            guard result else { return nil }
        }

        condition.lock()
        let stream = FakeFSEventStreamToken(
            id: nextStreamID,
            callback: callback,
            contextInfo: contextInfo,
            callbackQueue: callbackQueue
        )
        nextStreamID += 1
        streams.append(stream)
        condition.broadcast()
        condition.unlock()
        return stream
    }

    func startStream(_ stream: any MacOSFSEventStreamToken) -> Bool {
        let behavior: StartBehavior
        condition.lock()
        let fakeStream = requireFakeStream(stream)
        startRecords.append(fakeStream.id)
        behavior = startBehaviors.isEmpty ? .succeed : startBehaviors.removeFirst()
        condition.unlock()

        switch behavior {
        case .succeed:
            return true
        case .fail:
            return false
        case let .wait(gate, result):
            gate.markEntered()
            gate.waitForRelease()
            return result
        }
    }

    func disposeStream(_ stream: any MacOSFSEventStreamToken, wasStarted: Bool) {
        let behavior: DisposeBehavior
        condition.lock()
        let fakeStream = requireFakeStream(stream)
        disposeRecords.append(DisposeRecord(streamID: fakeStream.id, wasStarted: wasStarted))
        behavior = disposeBehaviors.isEmpty ? .immediate : disposeBehaviors.removeFirst()
        condition.broadcast()
        condition.unlock()

        switch behavior {
        case .immediate:
            return
        case let .wait(gate):
            gate.markEntered()
            gate.waitForRelease()
        }
    }

    func stream(at index: Int) -> FakeFSEventStreamToken? {
        condition.lock()
        defer { condition.unlock() }
        guard streams.indices.contains(index) else { return nil }
        return streams[index]
    }

    func disposeCount(for stream: FakeFSEventStreamToken) -> Int {
        disposeRecords(for: stream).count
    }

    func startCount(for stream: FakeFSEventStreamToken) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return startRecords.count(where: { $0 == stream.id })
    }

    func disposeRecords(for stream: FakeFSEventStreamToken) -> [DisposeRecord] {
        condition.lock()
        defer { condition.unlock() }
        return disposeRecords.filter { $0.streamID == stream.id }
    }

    func waitForTotalDisposeCount(_ expectedCount: Int, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while disposeRecords.count < expectedCount {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                return false
            }
            condition.wait(until: Date().addingTimeInterval(remaining))
        }
        return true
    }

    func emit(
        from stream: FakeFSEventStreamToken,
        path: String,
        flags: FSEventStreamEventFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified),
        eventID: FSEventStreamEventId,
        onCallbackQueue: Bool = false
    ) {
        let deliver = {
            let paths = [path as NSString] as CFArray
            var eventFlags = [flags]
            var eventIDs = [eventID]
            eventFlags.withUnsafeBufferPointer { flagsBuffer in
                eventIDs.withUnsafeBufferPointer { idsBuffer in
                    guard let flagsBaseAddress = flagsBuffer.baseAddress,
                          let idsBaseAddress = idsBuffer.baseAddress
                    else { return }
                    stream.callback(
                        OpaquePointer(bitPattern: stream.id + 1)!,
                        stream.contextInfo,
                        1,
                        Unmanaged.passUnretained(paths).toOpaque(),
                        flagsBaseAddress,
                        idsBaseAddress
                    )
                }
            }
            withExtendedLifetime(paths) {}
        }

        if onCallbackQueue {
            stream.callbackQueue.sync(execute: deliver)
        } else {
            deliver()
        }
    }

    private func requireFakeStream(_ stream: any MacOSFSEventStreamToken) -> FakeFSEventStreamToken {
        guard let fakeStream = stream as? FakeFSEventStreamToken else {
            XCTFail("Unexpected fake FSEvents stream token type")
            return FakeFSEventStreamToken(
                id: -1,
                callback: { _, _, _, _, _, _ in },
                contextInfo: UnsafeMutableRawPointer(bitPattern: 0x1)!,
                callbackQueue: .global(qos: .utility)
            )
        }
        return fakeStream
    }
}

private final class FakeFSEventStreamToken: MacOSFSEventStreamToken, @unchecked Sendable {
    let id: Int
    let callback: FSEventStreamCallback
    let contextInfo: UnsafeMutableRawPointer
    let callbackQueue: DispatchQueue

    init(
        id: Int,
        callback: FSEventStreamCallback,
        contextInfo: UnsafeMutableRawPointer,
        callbackQueue: DispatchQueue
    ) {
        self.id = id
        self.callback = callback
        self.contextInfo = contextInfo
        self.callbackQueue = callbackQueue
    }
}

private final class SemaphoreGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    func markEntered() {
        entered.signal()
    }

    func waitUntilEntered(timeout: DispatchTime = .now() + 2) -> Bool {
        entered.wait(timeout: timeout) == .success
    }

    func waitForRelease() {
        releaseSemaphore.wait()
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private final class PayloadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var payloads: [FileSystemWatchEventPayload] = []

    func append(_ payload: FileSystemWatchEventPayload) {
        lock.lock()
        payloads.append(payload)
        lock.unlock()
    }

    func snapshot() -> [FileSystemWatchEventPayload] {
        lock.lock()
        defer { lock.unlock() }
        return payloads
    }

    func paths() -> [String] {
        snapshot().flatMap { payload in
            payload.entries.map(\.path)
        }
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    func set(_ value: Value) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    func value() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}
