import Foundation
@testable import RepoPromptMCP
import XCTest

final class DirectProcessOutputCaptureTests: XCTestCase {
    func testPipeReadStartsOnlyAfterAcquiringCaptureLock() {
        let mutex = NSLock()
        let attemptedLock = DispatchSemaphore(value: 0)
        let capture = DirectProcessOutputCapture(lock: ObservedLock(mutex: mutex) {
            attemptedLock.signal()
        })
        let state = ReadState()
        let completed = DispatchGroup()

        mutex.lock()
        completed.enter()
        DispatchQueue.global().async {
            capture.consume {
                state.recordRead()
                return Data("A".utf8)
            }
            completed.leave()
        }
        XCTAssertEqual(attemptedLock.wait(timeout: .now() + 5), .success)
        // Acquisition was attempted while we still own the mutex. The pipe must be untouched.
        XCTAssertEqual(state.readCount, 0)
        mutex.unlock()
        XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(capture.finish { Data() }.data, Data("A".utf8))
    }

    func testTerminalDrainWaitsForConsumedChunkToBeAccumulated() {
        let attemptedLock = DispatchSemaphore(value: 0)
        let capture = DirectProcessOutputCapture(lock: ObservedLock(mutex: NSLock()) {
            attemptedLock.signal()
        })
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = DispatchSemaphore(value: 0)
        let completed = DispatchGroup()
        let state = ReadState()

        completed.enter()
        DispatchQueue.global().async {
            capture.consume {
                readStarted.signal()
                releaseRead.wait()
                return Data("A".utf8)
            }
            completed.leave()
        }
        XCTAssertEqual(attemptedLock.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(readStarted.wait(timeout: .now() + 5), .success)
        completed.enter()
        DispatchQueue.global().async {
            state.store(capture.finish { Data("B".utf8) })
            completed.leave()
        }
        // The finalizer has attempted the same mutex while the consumed chunk is held.
        XCTAssertEqual(attemptedLock.wait(timeout: .now() + 5), .success)
        releaseRead.signal()
        XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(state.snapshot?.data, Data("AB".utf8))
        XCTAssertEqual(state.snapshot?.truncated, false)
    }

    func testFinalizationSkipsLateReadersAndPreservesBoundedPrefix() {
        let capture = DirectProcessOutputCapture(limit: 4)
        capture.consume { Data("abc".utf8) }
        let snapshot = capture.finish { Data("def".utf8) }
        XCTAssertEqual(snapshot.data, Data("abcd".utf8))
        XCTAssertTrue(snapshot.truncated)
        capture.consume {
            XCTFail("A late callback must not consume the pipe after finalization")
            return Data("late".utf8)
        }
        XCTAssertEqual(capture.finish {
            XCTFail("Finalization must not drain the pipe twice")
            return Data()
        }, snapshot)

        let exact = DirectProcessOutputCapture(limit: 4)
        exact.consume { Data("abcd".utf8) }
        XCTAssertEqual(exact.finish { Data() }, .init(data: Data("abcd".utf8), truncated: false))
    }
}

private final class ObservedLock: NSLocking, @unchecked Sendable {
    private let mutex: NSLock
    private let onAttempt: @Sendable () -> Void

    init(mutex: NSLock, onAttempt: @escaping @Sendable () -> Void) {
        self.mutex = mutex
        self.onAttempt = onAttempt
    }

    func lock() {
        onAttempt()
        mutex.lock()
    }

    func unlock() {
        mutex.unlock()
    }
}

private final class ReadState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var storedSnapshot: DirectProcessOutputCapture.Snapshot?

    var readCount: Int {
        lock.withLock { count }
    }

    var snapshot: DirectProcessOutputCapture.Snapshot? {
        lock.withLock { storedSnapshot }
    }

    func recordRead() {
        lock.withLock { count += 1 }
    }

    func store(_ snapshot: DirectProcessOutputCapture.Snapshot) {
        lock.withLock { storedSnapshot = snapshot }
    }
}
