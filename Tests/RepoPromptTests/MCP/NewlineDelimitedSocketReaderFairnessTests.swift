import Darwin
import Dispatch
import Foundation
import Logging
@testable import RepoPrompt
import RepoPromptShared
import XCTest

final class NewlineDelimitedSocketReaderFairnessTests: XCTestCase {
    func testContinuouslyReadableInputYieldsThenResumesProgress() {
        let queue = DispatchQueue(label: "NewlineDelimitedSocketReaderFairnessTests.continuous")
        let script = ContinuousFrameReadOperation(frameCount: 6)
        let state = ReaderCallbackState()
        let queueYielded = expectation(description: "serial queue yielded")

        let reader = makeReader(
            queue: queue,
            maxReadCallsPerEvent: 3,
            readOperation: script.read,
            state: state
        )

        queue.suspend()
        queue.async {
            reader.processReadableEvent()
        }
        queue.async {
            state.readAttemptsObservedAtYield = script.readAttemptCount
            state.framesObservedAtYield = state.frames
            queueYielded.fulfill()
        }
        queue.resume()

        wait(for: [queueYielded], timeout: 1)
        XCTAssertEqual(state.readAttemptsObservedAtYield, 3)
        XCTAssertEqual(state.framesObservedAtYield, ["frame-0", "frame-1", "frame-2"])
        queue.sync {}
        reader.stop()

        XCTAssertEqual(state.frames, [
            "frame-0", "frame-1", "frame-2",
            "frame-3", "frame-4", "frame-5"
        ])
        XCTAssertEqual(state.bytesReadNotifications, 2)
        XCTAssertTrue(state.errors.isEmpty)
        XCTAssertEqual(state.eofResiduals, [])
    }

    func testSplitAndMultipleFramesPreserveOrderAcrossReadableEvents() {
        let script = ScriptedReadOperation(outcomes: [
            .data(Data("fir".utf8)),
            .data(Data("st\nsecond\nthi".utf8)),
            .wouldBlock,
            .data(Data("rd\nfourth\n".utf8)),
            .wouldBlock
        ])
        let state = ReaderCallbackState()
        let reader = makeReader(readOperation: script.read, state: state)

        reader.processReadableEvent()
        XCTAssertEqual(state.frames, ["first", "second"])
        XCTAssertEqual(state.bytesReadNotifications, 1)

        reader.processReadableEvent()
        XCTAssertEqual(state.frames, ["first", "second", "third", "fourth"])
        XCTAssertEqual(state.bytesReadNotifications, 2)
        XCTAssertEqual(script.readAttemptCount, 5)
        XCTAssertTrue(state.errors.isEmpty)
        XCTAssertEqual(state.eofResiduals, [])
    }

    func testEOFThroughDispatchSourceDrainsCompleteFramesBeforeTerminal() throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer {
            if sockets[0] >= 0 {
                close(sockets[0])
            }
            if sockets[1] >= 0 {
                close(sockets[1])
            }
        }

        let flags = fcntl(sockets[0], F_GETFL)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertEqual(fcntl(sockets[0], F_SETFL, flags | O_NONBLOCK), 0)

        let queue = DispatchQueue(label: "NewlineDelimitedSocketReaderFairnessTests.eof")
        let state = ReaderCallbackState()
        let eofDelivered = expectation(description: "EOF delivered")
        let reader = NewlineDelimitedSocketReader(
            fd: sockets[0],
            queue: queue,
            logger: Logger(label: "NewlineDelimitedSocketReaderFairnessTests.eof"),
            onFrame: { frame in
                let text = String(decoding: frame, as: UTF8.self)
                state.frames.append(text)
                state.callbackOrder.append("frame:\(text)")
            },
            onEOF: { hasResidualData in
                state.eofResiduals.append(hasResidualData)
                state.callbackOrder.append("eof:\(hasResidualData)")
                eofDelivered.fulfill()
            },
            onError: { state.errors.append($0) },
            onBytesRead: { state.bytesReadNotifications += 1 }
        )
        try reader.start()

        let payload = Data("first\nsecond\npartial".utf8)
        let written = payload.withUnsafeBytes { bytes in
            Darwin.write(sockets[1], bytes.baseAddress, bytes.count)
        }
        XCTAssertEqual(written, payload.count)
        XCTAssertEqual(shutdown(sockets[1], SHUT_WR), 0)
        wait(for: [eofDelivered], timeout: 1)
        queue.sync {}

        XCTAssertEqual(state.callbackOrder, ["frame:first", "frame:second", "eof:true"])
        XCTAssertEqual(state.frames, ["first", "second"])
        XCTAssertEqual(state.eofResiduals, [true])
        XCTAssertEqual(state.bytesReadNotifications, 1)
        XCTAssertTrue(state.errors.isEmpty)
    }

    func testHardReadErrorIsTerminalAndDeliveredExactlyOnce() {
        let script = ScriptedReadOperation(outcomes: [.error(EIO)])
        let state = ReaderCallbackState()
        let reader = makeReader(readOperation: script.read, state: state)

        reader.processReadableEvent()
        reader.processReadableEvent()

        XCTAssertEqual(script.readAttemptCount, 1)
        XCTAssertEqual(state.errors.count, 1)
        XCTAssertTrue(state.frames.isEmpty)
        XCTAssertTrue(state.eofResiduals.isEmpty)
    }

    func testFrameCapDeliversPriorFramesThenFailsExactlyOnce() {
        let script = ScriptedReadOperation(outcomes: [
            .data(Data("1234\n12345\n".utf8)),
            .wouldBlock
        ])
        let state = ReaderCallbackState()
        let reader = makeReader(
            maximumFrameByteCount: 4,
            readOperation: script.read,
            state: state
        )

        reader.processReadableEvent()
        reader.processReadableEvent()

        XCTAssertEqual(state.frames, ["1234"])
        XCTAssertEqual(state.errors.count, 1)
        XCTAssertEqual(
            state.errors.first as? MCPNewlineFrameTooLargeError,
            MCPNewlineFrameTooLargeError(maximumByteCount: 4, accumulatedByteCount: 5)
        )
        XCTAssertTrue(state.eofResiduals.isEmpty)
        XCTAssertEqual(script.readAttemptCount, 1)
    }

    func testFrameMaySpanMultiplePerEventByteBudgets() {
        let queue = DispatchQueue(label: "NewlineDelimitedSocketReaderFairnessTests.largeFrame")
        let script = ScriptedReadOperation(outcomes: [
            .data(Data("larg".utf8)),
            .data(Data("e-fr".utf8)),
            .data(Data("ame\n".utf8)),
            .wouldBlock
        ])
        let state = ReaderCallbackState()
        let reader = makeReader(
            queue: queue,
            maxBytesPerEvent: 4,
            maximumFrameByteCount: 16,
            readOperation: script.read,
            state: state
        )

        reader.processReadableEvent()
        for _ in 0 ..< 4 {
            queue.sync {}
        }
        reader.stop()

        XCTAssertEqual(state.frames, ["large-frame"])
        XCTAssertTrue(state.errors.isEmpty)
        XCTAssertEqual(script.readAttemptCount, 4)
    }

    func testReentrantReadableEventDoesNotNestFrameDelivery() {
        let queue = DispatchQueue(label: "NewlineDelimitedSocketReaderFairnessTests.reentrant")
        let script = ScriptedReadOperation(outcomes: [
            .data(Data("first\n".utf8)),
            .data(Data("second\n".utf8)),
            .wouldBlock
        ])
        let delivered = expectation(description: "both frames delivered")
        var frames: [String] = []
        var callbackDepth = 0
        var maximumCallbackDepth = 0
        weak var weakReader: NewlineDelimitedSocketReader?

        let reader = NewlineDelimitedSocketReader(
            fd: -1,
            queue: queue,
            logger: Logger(label: "NewlineDelimitedSocketReaderFairnessTests.reentrant"),
            chunkSize: 64,
            maxReadCallsPerEvent: 1,
            readOperation: script.read,
            onFrame: { frame in
                callbackDepth += 1
                maximumCallbackDepth = max(maximumCallbackDepth, callbackDepth)
                frames.append(String(decoding: frame, as: UTF8.self))
                if frames.count == 1 {
                    weakReader?.processReadableEvent()
                } else {
                    weakReader?.stop()
                    delivered.fulfill()
                }
                callbackDepth -= 1
            },
            onEOF: { _ in XCTFail("Unexpected EOF") },
            onError: { XCTFail("Unexpected read error: \($0)") }
        )
        weakReader = reader

        reader.processReadableEvent()
        wait(for: [delivered], timeout: 1)

        XCTAssertEqual(frames, ["first", "second"])
        XCTAssertEqual(maximumCallbackDepth, 1)
        XCTAssertEqual(script.readAttemptCount, 2)
    }

    func testStopDuringFrameDeliveryCancelsSourceAndSuppressesBufferedFrames() throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer {
            if sockets[0] >= 0 {
                close(sockets[0])
            }
            if sockets[1] >= 0 {
                close(sockets[1])
            }
        }

        let flags = fcntl(sockets[0], F_GETFL)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertEqual(fcntl(sockets[0], F_SETFL, flags | O_NONBLOCK), 0)

        let queue = DispatchQueue(label: "NewlineDelimitedSocketReaderFairnessTests.stop")
        let cancelled = expectation(description: "read source cancelled")
        var frames: [String] = []
        var cancelCount = 0
        weak var weakReader: NewlineDelimitedSocketReader?

        let reader = NewlineDelimitedSocketReader(
            fd: sockets[0],
            queue: queue,
            logger: Logger(label: "NewlineDelimitedSocketReaderFairnessTests.stop"),
            onFrame: { frame in
                frames.append(String(decoding: frame, as: UTF8.self))
                weakReader?.stop()
            },
            onEOF: { _ in XCTFail("Unexpected EOF") },
            onError: { XCTFail("Unexpected read error: \($0)") },
            onCancel: {
                cancelCount += 1
                cancelled.fulfill()
            }
        )
        weakReader = reader
        try reader.start()

        let payload = Data("first\nsecond\n".utf8)
        let written = payload.withUnsafeBytes { bytes in
            Darwin.write(sockets[1], bytes.baseAddress, bytes.count)
        }
        XCTAssertEqual(written, payload.count)

        wait(for: [cancelled], timeout: 1)
        queue.sync {}

        XCTAssertEqual(frames, ["first"])
        XCTAssertEqual(cancelCount, 1)
    }

    func testCrossQueueStopPreventsFurtherReadsAndCallbacks() {
        let queue = DispatchQueue(label: "NewlineDelimitedSocketReaderFairnessTests.crossQueueStop")
        let script = ScriptedReadOperation(outcomes: [
            .data(Data("first\n".utf8)),
            .wouldBlock,
            .data(Data("second\n".utf8)),
            .wouldBlock
        ])
        let state = ReaderCallbackState()
        let reader = makeReader(queue: queue, readOperation: script.read, state: state)
        let stopped = expectation(description: "cross-queue stop returned")

        reader.processReadableEvent()
        DispatchQueue.global().async {
            reader.stop()
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 1)

        reader.processReadableEvent()
        queue.sync {}

        XCTAssertEqual(script.readAttemptCount, 2)
        XCTAssertEqual(state.frames, ["first"])
        XCTAssertEqual(state.bytesReadNotifications, 1)
        XCTAssertTrue(state.errors.isEmpty)
        XCTAssertTrue(state.eofResiduals.isEmpty)
    }

    func testAppAndCLISocketReaderCopiesRemainIdentical() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            root.deleteLastPathComponent()
        }

        let appCopy = try Data(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPrompt/Infrastructure/MCP/AppShared/NewlineDelimitedSocketReader.swift"
            )
        )
        let cliCopy = try Data(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPromptMCP/Shared/NewlineDelimitedSocketReader.swift"
            )
        )
        XCTAssertEqual(appCopy, cliCopy)
    }

    private func makeReader(
        queue: DispatchQueue = DispatchQueue(label: "NewlineDelimitedSocketReaderFairnessTests"),
        maxReadCallsPerEvent: Int = 32,
        maxBytesPerEvent: Int = 256 * 1024,
        maximumFrameByteCount: Int = MCPNewlineFrameAccumulator.defaultMaximumFrameByteCount,
        readOperation: @escaping NewlineDelimitedSocketReader.ReadOperation,
        state: ReaderCallbackState
    ) -> NewlineDelimitedSocketReader {
        NewlineDelimitedSocketReader(
            fd: -1,
            queue: queue,
            logger: Logger(label: "NewlineDelimitedSocketReaderFairnessTests"),
            chunkSize: 64,
            maximumFrameByteCount: maximumFrameByteCount,
            maxReadCallsPerEvent: maxReadCallsPerEvent,
            maxBytesPerEvent: maxBytesPerEvent,
            readOperation: readOperation,
            onFrame: { frame in
                let text = String(decoding: frame, as: UTF8.self)
                state.frames.append(text)
                state.callbackOrder.append("frame:\(text)")
            },
            onEOF: { hasResidualData in
                state.eofResiduals.append(hasResidualData)
                state.callbackOrder.append("eof:\(hasResidualData)")
            },
            onError: { state.errors.append($0) },
            onBytesRead: { state.bytesReadNotifications += 1 },
            onCancel: { state.cancelCount += 1 }
        )
    }
}

private final class ReaderCallbackState {
    var frames: [String] = []
    var eofResiduals: [Bool] = []
    var errors: [Error] = []
    var callbackOrder: [String] = []
    var bytesReadNotifications = 0
    var cancelCount = 0
    var readAttemptsObservedAtYield = 0
    var framesObservedAtYield: [String] = []
}

private final class ContinuousFrameReadOperation {
    private let frameCount: Int
    private(set) var readAttemptCount = 0

    init(frameCount: Int) {
        self.frameCount = frameCount
    }

    func read(
        _ fd: Int32,
        _ buffer: UnsafeMutableRawPointer?,
        _ count: Int
    ) -> Int {
        _ = fd
        guard readAttemptCount < frameCount else {
            errno = EAGAIN
            readAttemptCount += 1
            return -1
        }
        let frame = Data("frame-\(readAttemptCount)\n".utf8)
        readAttemptCount += 1
        precondition(frame.count <= count)
        frame.copyBytes(to: buffer!.assumingMemoryBound(to: UInt8.self), count: frame.count)
        return frame.count
    }
}

private final class ScriptedReadOperation {
    enum Outcome {
        case data(Data)
        case wouldBlock
        case eof
        case error(Int32)
    }

    private var outcomes: [Outcome]
    private(set) var readAttemptCount = 0

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func read(
        _ fd: Int32,
        _ buffer: UnsafeMutableRawPointer?,
        _ count: Int
    ) -> Int {
        _ = fd
        readAttemptCount += 1
        guard !outcomes.isEmpty else {
            errno = EAGAIN
            return -1
        }

        switch outcomes.removeFirst() {
        case let .data(chunk):
            precondition(chunk.count <= count)
            chunk.copyBytes(to: buffer!.assumingMemoryBound(to: UInt8.self), count: chunk.count)
            return chunk.count
        case .wouldBlock:
            errno = EAGAIN
            return -1
        case .eof:
            return 0
        case let .error(errorCode):
            errno = errorCode
            return -1
        }
    }
}
