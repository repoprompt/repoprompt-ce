import CoreFoundation
import CoreServices
import Dispatch
import Foundation
@testable import RepoPromptCoreMacOS
import XCTest

final class MacOSFSEventsWatcherTests: XCTestCase {
    func testOrderedSemanticEventsAreDeepCopiedBeforeDelivery() throws {
        let backend = FakeFSEventStreamBackend()
        let watcher = MacOSFSEventsWatcher(path: "/tmp/root", streamBackend: backend)
        let recorder = WatchEventRecorder()

        try watcher.start(from: 41) { payload in
            recorder.record(
                paths: payload.entries.map(\.path),
                ids: payload.entries.map(\.id),
                firstWasCreated: payload.entries.first?.flags.contains(.itemCreated) == true
            )
        }

        backend.emit(
            paths: ["/tmp/root/a", "/tmp/root/b"],
            flags: [
                FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile),
                FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsDir)
            ],
            ids: [42, 43]
        )

        XCTAssertEqual(backend.createdFromEventID, 41)
        XCTAssertEqual(recorder.paths, ["/tmp/root/a", "/tmp/root/b"])
        XCTAssertEqual(recorder.ids, [42, 43])
        XCTAssertTrue(recorder.firstWasCreated)
    }

    func testLateCallbackAfterStopIsIgnoredAndStopDisposesExactlyOnce() throws {
        let backend = FakeFSEventStreamBackend()
        let watcher = MacOSFSEventsWatcher(path: "/tmp/root", streamBackend: backend)
        let recorder = WatchEventRecorder()
        try watcher.start(from: 1) { _ in
            recorder.record(paths: [], ids: [], firstWasCreated: false)
        }

        backend.onDispose = {
            backend.emit(
                paths: ["/tmp/root/late"],
                flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)],
                ids: [2]
            )
        }
        watcher.stop()
        watcher.stop()

        XCTAssertEqual(recorder.deliveryCount, 0)
        XCTAssertEqual(backend.disposeCount, 1)
        XCTAssertFalse(watcher.isWatching)
    }

    func testExternalStopWaitsForAnAcceptedDeliveryToFinish() throws {
        let backend = FakeFSEventStreamBackend()
        let watcher = MacOSFSEventsWatcher(path: "/tmp/root", streamBackend: backend)
        let handlerEntered = DispatchSemaphore(value: 0)
        let allowHandlerReturn = DispatchSemaphore(value: 0)
        let stopReturned = DispatchSemaphore(value: 0)
        try watcher.start(from: 1) { _ in
            handlerEntered.signal()
            _ = allowHandlerReturn.wait(timeout: .now() + 2)
        }

        DispatchQueue.global().async {
            backend.emit(
                paths: ["/tmp/root/in-flight"],
                flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)],
                ids: [2]
            )
        }
        XCTAssertEqual(handlerEntered.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            watcher.stop()
            stopReturned.signal()
        }
        XCTAssertEqual(stopReturned.wait(timeout: .now() + 0.05), .timedOut)
        allowHandlerReturn.signal()
        XCTAssertEqual(stopReturned.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(backend.disposeCount, 1)
    }

    func testStartFailureReleasesCreatedStreamExactlyOnce() {
        let backend = FakeFSEventStreamBackend()
        backend.startResult = false
        let watcher = MacOSFSEventsWatcher(path: "/tmp/root", streamBackend: backend)

        XCTAssertThrowsError(try watcher.start(from: 7) { _ in }) { error in
            XCTAssertTrue(String(describing: error).contains("streamStartFailed"))
        }
        XCTAssertEqual(backend.disposeCount, 1)
        XCTAssertFalse(watcher.isWatching)
    }
}

private final class WatchEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPaths: [String] = []
    private var storedIDs: [UInt64] = []
    private var storedFirstWasCreated = false
    private var storedDeliveryCount = 0

    var paths: [String] { lock.withLock { storedPaths } }
    var ids: [UInt64] { lock.withLock { storedIDs } }
    var firstWasCreated: Bool { lock.withLock { storedFirstWasCreated } }
    var deliveryCount: Int { lock.withLock { storedDeliveryCount } }

    func record(paths: [String], ids: [UInt64], firstWasCreated: Bool) {
        lock.withLock {
            storedPaths = paths
            storedIDs = ids
            storedFirstWasCreated = firstWasCreated
            storedDeliveryCount += 1
        }
    }
}

private final class FakeFSEventStreamBackend: MacOSFSEventStreamBackend, @unchecked Sendable {
    private final class Token: MacOSFSEventStreamToken, @unchecked Sendable {}

    var startResult = true
    var disposeCount = 0
    var onDispose: (() -> Void)?
    var createdFromEventID: UInt64?
    var latestID: UInt64 = 0

    private var callback: FSEventStreamCallback?
    private var contextInfo: UnsafeMutableRawPointer?

    func createStream(
        path: String,
        from eventID: UInt64,
        callback: @escaping FSEventStreamCallback,
        contextInfo: UnsafeMutableRawPointer,
        callbackQueue: DispatchQueue
    ) -> (any MacOSFSEventStreamToken)? {
        createdFromEventID = eventID
        self.callback = callback
        self.contextInfo = contextInfo
        return Token()
    }

    func startStream(_ stream: any MacOSFSEventStreamToken) -> Bool {
        startResult
    }

    func flushStream(_ stream: any MacOSFSEventStreamToken) {}

    func latestEventID(_ stream: any MacOSFSEventStreamToken) -> UInt64 {
        latestID
    }

    func disposeStream(_ stream: any MacOSFSEventStreamToken, wasStarted: Bool) {
        disposeCount += 1
        onDispose?()
    }

    func emit(
        paths: [String],
        flags: [FSEventStreamEventFlags],
        ids: [FSEventStreamEventId]
    ) {
        guard let callback, let contextInfo else { return }
        let array = paths as CFArray
        let eventPaths = UnsafeMutableRawPointer(Unmanaged.passUnretained(array).toOpaque())
        flags.withUnsafeBufferPointer { flagBuffer in
            ids.withUnsafeBufferPointer { idBuffer in
                guard let flagBase = flagBuffer.baseAddress,
                      let idBase = idBuffer.baseAddress
                else { return }
                callback(
                    OpaquePointer(bitPattern: 1)!,
                    contextInfo,
                    paths.count,
                    eventPaths,
                    flagBase,
                    idBase
                )
            }
        }
    }
}
