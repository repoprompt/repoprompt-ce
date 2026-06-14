import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class GitProcessPipeDrainTests: XCTestCase {
    func testFinishWaitsForInFlightReadBeforeClosingStream() async {
        let (stream, drain) = GitProcessPipeDrain.makeStream()
        let collected = Task { await Self.collect(stream) }
        let readStarted = TestSemaphore()
        let releaseRead = TestSemaphore()
        let consumeCompleted = TestSemaphore()
        let finishWillLock = TestSemaphore()
        let finishCompleted = TestSemaphore()
        let callbackData = Data("callback".utf8)
        let tailData = Data("-tail".utf8)

        DispatchQueue.global().async {
            drain.consume {
                readStarted.signal()
                _ = releaseRead.wait(timeout: .now() + 5)
                return callbackData
            }
            consumeCompleted.signal()
        }

        XCTAssertEqual(readStarted.wait(timeout: .now() + 5), .success)

        DispatchQueue.global().async {
            drain.finish(
                readRemaining: { tailData },
                onWillLock: { finishWillLock.signal() }
            )
            finishCompleted.signal()
        }

        XCTAssertEqual(finishWillLock.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(finishCompleted.wait(timeout: .now() + 0.1), .timedOut)
        releaseRead.signal()
        XCTAssertEqual(consumeCompleted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(finishCompleted.wait(timeout: .now() + 5), .success)

        let output = await collected.value
        XCTAssertEqual(output, callbackData + tailData)
    }

    func testOwnedDescriptorSurvivesOriginalFileHandleCloseBeforeQueuedRead() async throws {
        let pipe = Pipe()
        let originalReadHandle = pipe.fileHandleForReading
        let (stream, drain) = try GitProcessPipeDrain.makeStream(readingFrom: originalReadHandle)
        let collected = Task { await Self.collect(stream) }
        let expected = Data("queued callback".utf8)

        pipe.fileHandleForWriting.write(expected)
        originalReadHandle.closeFile()

        XCTAssertFalse(drain.consumeAvailableData())
        pipe.fileHandleForWriting.closeFile()
        XCTAssertTrue(drain.consumeAvailableData())

        let output = await collected.value
        XCTAssertEqual(output, expected)
    }

    func testConsumeReturnsPromptlyWhenWriterRemainsOpenWithoutAvailableBytes() throws {
        let pipe = Pipe()
        let originalReadHandle = pipe.fileHandleForReading
        let originalStatusFlags = fcntl(originalReadHandle.fileDescriptor, F_GETFL)
        XCTAssertGreaterThanOrEqual(originalStatusFlags, 0)

        let (_, drain) = try GitProcessPipeDrain.makeStream(readingFrom: originalReadHandle)
        let configuredStatusFlags = fcntl(originalReadHandle.fileDescriptor, F_GETFL)
        XCTAssertGreaterThanOrEqual(configuredStatusFlags, 0)
        XCTAssertEqual(
            configuredStatusFlags & ~O_NONBLOCK,
            originalStatusFlags & ~O_NONBLOCK
        )
        XCTAssertNotEqual(configuredStatusFlags & O_NONBLOCK, 0)

        let consumeResult = TestLockedBool()
        let consumeCompleted = TestSemaphore()
        DispatchQueue.global().async {
            consumeResult.set(drain.consumeAvailableData())
            consumeCompleted.signal()
        }

        let waitResult = consumeCompleted.wait(timeout: .now() + 1)
        if waitResult == .timedOut {
            pipe.fileHandleForWriting.closeFile()
            _ = consumeCompleted.wait(timeout: .now() + 5)
        }

        XCTAssertEqual(waitResult, .success)
        XCTAssertEqual(consumeResult.value, false)
        drain.cancel()
        if waitResult == .success {
            pipe.fileHandleForWriting.closeFile()
        }
    }

    func testReadabilityCallbackAfterFinishCannotConsumeOrAppendData() async {
        let (stream, drain) = GitProcessPipeDrain.makeStream()
        let tailData = Data("tail".utf8)
        var didReadAfterFinish = false

        drain.finish { tailData }
        drain.consume {
            didReadAfterFinish = true
            return Data("late".utf8)
        }

        XCTAssertFalse(didReadAfterFinish)
        let output = await Self.collect(stream)
        XCTAssertEqual(output, tailData)
    }

    private static func collect(_ stream: AsyncStream<Data>) async -> Data {
        var result = Data()
        for await chunk in stream {
            result.append(chunk)
        }
        return result
    }
}

private final class TestLockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool?

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: Bool) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

private final class TestSemaphore: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() {
        semaphore.signal()
    }

    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        semaphore.wait(timeout: timeout)
    }
}
