import Darwin
import Dispatch
import Foundation
import Logging
@testable import RepoPromptApp
import XCTest

final class NewlineDelimitedSocketReaderFairnessTests: XCTestCase {
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

    private func makeReader(
        queue: DispatchQueue = DispatchQueue(label: "NewlineDelimitedSocketReaderFairnessTests"),
        readOperation: @escaping NewlineDelimitedSocketReader.ReadOperation,
        state: ReaderCallbackState
    ) -> NewlineDelimitedSocketReader {
        NewlineDelimitedSocketReader(
            fd: -1,
            queue: queue,
            logger: Logger(label: "NewlineDelimitedSocketReaderFairnessTests"),
            chunkSize: 64,
            maxReadCallsPerEvent: 32,
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
