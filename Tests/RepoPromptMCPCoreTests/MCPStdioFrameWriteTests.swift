import Darwin
import Foundation
@testable import MCP
@testable import RepoPromptMCPCore
import XCTest

final class MCPStdioFrameWriteTests: XCTestCase {
    func testScriptedSinkReportsSyscallFailureWithoutNegativeWriteCounts() throws {
        let frame = Data(#"{"id":7}"#.utf8)
        for failInitialPrefix in [true, false] {
            let sink = try ScriptedStdioSink(prefixBytes: 2)
            if !failInitialPrefix {
                let prefixResult = frame.withUnsafeBytes { sink.write($0) }
                guard case .wrote(2) = prefixResult else {
                    XCTFail("Expected a successful two-byte prefix")
                    continue
                }
                sink.open()
            }
            sink.failNextWriteWithBadDescriptor()
            let bytes = failInitialPrefix ? frame : Data(frame.dropFirst(2))
            let result = bytes.withUnsafeBytes { sink.write($0) }
            if case let .failed(code) = result {
                XCTAssertEqual(code, EBADF)
            } else {
                XCTFail("Expected EBADF instead of a negative write count: \(result)")
            }
            XCTAssertEqual(try sink.readWire(), failInitialPrefix ? Data() : Data(frame.prefix(2)))
        }
    }

    func testConcurrentSendCannotAppendInsideBlockedFrame() async throws {
        let sink = try ScriptedStdioSink(prefixBytes: 8)
        let transport = MCPStdioServerTransport(
            outputSink: sink,
            writeGateObserver: {
                event in if case .enqueued = event {
                    sink.recordQueued()
                }
            }
        )
        let first = Data(#"{"jsonrpc":"2.0","id":7,"result":{}}"#.utf8)
        let second = Data(#"{"jsonrpc":"2.0","id":"7","result":{}}"#.utf8)
        let sendA = Task { try await transport.send(first) }
        await sink.waitUntilBlocked()
        // Queue admission is the boundary proving B attempted to send while A still owns a prefix.
        let sendB = Task { try await transport.send(second) }
        await sink.waitUntilSecondWriteOrQueued(transport: transport)
        sink.open()
        try await sendA.value
        try await sendB.value
        let wire = try sink.readWire()
        XCTAssertEqual(wire, first + Data([10]) + second + Data([10]))
        let lines = wire.split(separator: 10)
        XCTAssertEqual(lines.count, 2)
        let decoded = try lines.map { try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        XCTAssertEqual(decoded[0]?["id"] as? Int, 7)
        XCTAssertEqual(decoded[1]?["id"] as? String, "7")
    }

    func testCancellationAfterPrefixSealsOutputAndSettlesEveryQueuedSend() async throws {
        let sink = try ScriptedStdioSink(prefixBytes: 8)
        let fixture = try StdioInputFixture()
        let transport = MCPStdioServerTransport(
            stdinFD: fixture.readDescriptor, outputSink: sink,
            writeGateObserver: {
                event in if case .enqueued = event {
                    sink.recordQueued()
                }
            }
        )
        try await transport.connect()
        let stream = await transport.receive()
        let frame = Data(#"{"jsonrpc":"2.0","id":7,"result":{}}"#.utf8)
        let sendA = Task { try await transport.send(frame) }
        await sink.waitUntilBlocked()
        let sendB = Task { try await transport.send(Data(#"{"id":"7"}"#.utf8)) }
        let sendC = Task { try await transport.send(Data(#"{"id":8}"#.utf8)) }
        await sink.waitUntilQueued(2)
        sendA.cancel()
        let terminal = MCPStdioServerTransport.TerminalError.stdoutPartialFrame(
            bytesWritten: 8, totalBytes: frame.count + 1
        )
        await assertFailure(sendA, terminal)
        await assertFailure(sendB, terminal)
        await assertFailure(sendC, terminal)
        let observed = await transport.waitUntilTerminal()
        XCTAssertEqual(observed, terminal)
        do {
            for try await _ in stream {
                XCTFail("No input frame was written")
            }
            XCTFail("Sealed receive stream must fail")
        } catch { XCTAssertEqual(error as? MCPStdioServerTransport.TerminalError, terminal) }
        sink.open()
        await assertFailure(Task { try await transport.send(Data(#"{"id":"late"}"#.utf8)) }, terminal)
        XCTAssertEqual(try sink.readWire(), Data(frame.prefix(8)))
        await transport.disconnect()
    }

    func testFirstWriteFailureSurvivesDisconnectAndCleanReadTermination() async throws {
        for disconnectWhileTeardownIsSuspended in [true, false] {
            let sink = try ScriptedStdioSink(prefixBytes: 8)
            let fixture = try StdioInputFixture()
            let publication = StdioSealTeardownGate()
            let readEOF = StdioReadEOFSignal()
            let transport = MCPStdioServerTransport(
                stdinFD: fixture.readDescriptor, outputSink: sink,
                writeGateObserver: { event in
                    if case .enqueued = event { sink.recordQueued() }
                },
                beforeSealReaderTeardownForTesting: { await publication.suspend() },
                readEOFObserverForTesting: { Task { await readEOF.signal() } }
            )
            try await transport.connect()
            let stream = await transport.receive()
            let frame = Data(#"{"id":7,"result":{}}"#.utf8)
            let expected = MCPStdioServerTransport.TerminalError.stdoutWrite(
                errno: ETIMEDOUT, bytesWritten: 8, totalBytes: frame.count + 1
            )
            let owner = Task { try await transport.send(frame) }
            await sink.waitUntilBlocked()
            let queued = Task { try await transport.send(Data(#"{"id":"7"}"#.utf8)) }
            await sink.waitUntilQueued(1)
            sink.failWait(errno: ETIMEDOUT)
            await publication.waitUntilSuspended()
            await assertFailure(queued, expected)
            if disconnectWhileTeardownIsSuspended {
                await transport.disconnect()
            } else {
                try fixture.closeWriter()
                // Receive is already finished by stdout; wait for the reader's actual EOF attempt.
                await readEOF.wait()
            }
            var streamError: Error?
            do {
                for try await _ in stream {
                    XCTFail("No input frames were written")
                }
            } catch { streamError = error }
            XCTAssertEqual(streamError as? MCPStdioServerTransport.TerminalError, expected)
            let recorded = await transport.terminalError()
            let waited = await transport.waitUntilTerminal()
            XCTAssertEqual(recorded, expected)
            XCTAssertEqual(waited, expected)
            await publication.release()
            await assertFailure(owner, expected)
            let afterPublication = await transport.terminalError()
            XCTAssertEqual(afterPublication, expected)
            sink.open()
            await assertFailure(Task { try await transport.send(Data(#"{"id":"late"}"#.utf8)) }, expected)
            XCTAssertEqual(try sink.readWire(), Data(frame.prefix(8)))
            await transport.disconnect()
        }
    }

    func testReadErrorBeforeWriteFailureRemainsFirstTerminalControl() async throws {
        let sink = try ScriptedStdioSink(prefixBytes: 8)
        let fixture = try StdioInputFixture()
        let transport = MCPStdioServerTransport(stdinFD: fixture.readDescriptor, outputSink: sink)
        try await transport.connect()
        let stream = await transport.receive()
        let incomplete = Data(#"{"id":7"#.utf8)
        try fixture.write(incomplete)
        try fixture.closeWriter()
        let expected = MCPStdioServerTransport.TerminalError.stdinTruncatedFrame(bytes: incomplete.count)
        do {
            for try await _ in stream {
                XCTFail("Incomplete input cannot be delivered")
            }
            XCTFail("Read error must fail receive")
        } catch { XCTAssertEqual(error as? MCPStdioServerTransport.TerminalError, expected) }
        let before = await transport.waitUntilTerminal()
        XCTAssertEqual(before, expected)
        let frame = Data(#"{"id":8,"result":{}}"#.utf8)
        let owner = Task { try await transport.send(frame) }
        await sink.waitUntilBlocked()
        sink.failWait(errno: ETIMEDOUT)
        await assertFailure(owner, .stdoutWrite(errno: ETIMEDOUT, bytesWritten: 8, totalBytes: frame.count + 1))
        await transport.disconnect()
        let recorded = await transport.terminalError()
        let waited = await transport.waitUntilTerminal()
        XCTAssertEqual(recorded, expected)
        XCTAssertEqual(waited, expected)
        XCTAssertEqual(try sink.readWire(), Data(frame.prefix(8)))
    }

    func testCleanEOFBeforeWriteFailureRemainsFirstTerminalControl() async throws {
        let sink = try ScriptedStdioSink(prefixBytes: 8)
        let fixture = try StdioInputFixture()
        let transport = MCPStdioServerTransport(stdinFD: fixture.readDescriptor, outputSink: sink)
        try await transport.connect()
        let stream = await transport.receive()
        try fixture.closeWriter()
        for try await _ in stream {
            XCTFail("No input frames were written")
        }
        let before = await transport.waitUntilTerminal()
        XCTAssertEqual(before, .stdinEOF)
        let frame = Data(#"{"id":8,"result":{}}"#.utf8)
        let owner = Task { try await transport.send(frame) }
        await sink.waitUntilBlocked()
        sink.failWait(errno: ETIMEDOUT)
        let writeError = MCPStdioServerTransport.TerminalError.stdoutWrite(
            errno: ETIMEDOUT, bytesWritten: 8, totalBytes: frame.count + 1
        )
        await assertFailure(owner, writeError)
        await assertFailure(Task { try await transport.send(Data(#"{"id":"late"}"#.utf8)) }, writeError)
        await transport.disconnect()
        let recorded = await transport.terminalError()
        let waited = await transport.waitUntilTerminal()
        XCTAssertEqual(recorded, .stdinEOF)
        XCTAssertEqual(waited, .stdinEOF)
        XCTAssertEqual(try sink.readWire(), Data(frame.prefix(8)))
    }

    func testZeroByteCancellationHandsOffWithoutSealing() async throws {
        let sink = try ScriptedStdioSink(prefixBytes: 0)
        let transport = MCPStdioServerTransport(
            outputSink: sink,
            writeGateObserver: {
                event in if case .enqueued = event {
                    sink.recordQueued()
                }
            }
        )
        let sendA = Task { try await transport.send(Data(#"{"id":7}"#.utf8)) }
        await sink.waitUntilBlocked()
        let frameB = Data(#"{"id":"7"}"#.utf8)
        let sendB = Task { try await transport.send(frameB) }
        await sink.waitUntilQueued(1)
        sendA.cancel()
        do { try await sendA.value
            XCTFail("Cancelled unsent frame must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
        try await sendB.value
        let terminal = await transport.terminalError()
        XCTAssertNil(terminal)
        XCTAssertEqual(try sink.readWire(), frameB + Data([10]))
        await transport.disconnect()
    }

    func testQueuedCancellationNeverWritesAndPreservesStream() async throws {
        let sink = try ScriptedStdioSink(prefixBytes: 8)
        let transport = MCPStdioServerTransport(
            outputSink: sink,
            writeGateObserver: {
                event in if case .enqueued = event {
                    sink.recordQueued()
                }
            }
        )
        let frameA = Data(#"{"id":7,"result":{}}"#.utf8)
        let sendA = Task { try await transport.send(frameA) }
        await sink.waitUntilBlocked()
        let sendB = Task { try await transport.send(Data(#"{"id":"7"}"#.utf8)) }
        await sink.waitUntilQueued(1)
        sendB.cancel()
        do { try await sendB.value
            XCTFail("Cancelled queued frame must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
        sink.open()
        try await sendA.value
        let frameC = Data(#"{"id":8}"#.utf8)
        try await transport.send(frameC)
        XCTAssertEqual(try sink.readWire(), frameA + Data([10]) + frameC + Data([10]))
        let terminal = await transport.terminalError()
        XCTAssertNil(terminal)
        await transport.disconnect()
    }

    func testDisconnectSettlesOwnerAndQueuedSendersWithoutLateAppend() async throws {
        for prefixBytes in [0, 8] {
            let sink = try ScriptedStdioSink(prefixBytes: prefixBytes)
            let transport = MCPStdioServerTransport(
                outputSink: sink,
                writeGateObserver: {
                    event in if case .enqueued = event {
                        sink.recordQueued()
                    }
                }
            )
            let frame = Data(#"{"id":7,"result":{}}"#.utf8)
            let sendA = Task { try await transport.send(frame) }
            await sink.waitUntilBlocked()
            let sendB = Task { try await transport.send(Data(#"{"id":"7"}"#.utf8)) }
            let sendC = Task { try await transport.send(Data(#"{"id":8}"#.utf8)) }
            await sink.waitUntilQueued(2)
            await transport.disconnect()
            await assertFailure(sendA, .cancelled)
            await assertFailure(sendB, .cancelled)
            await assertFailure(sendC, .cancelled)
            sink.open()
            await assertFailure(Task { try await transport.send(Data(#"{"id":"late"}"#.utf8)) }, .cancelled)
            XCTAssertEqual(try sink.readWire(), Data(frame.prefix(prefixBytes)))
        }
    }

    func testBoundedWriteAdmissionRejectsOnlyNewestUnsentFrame() async throws {
        let sink = try ScriptedStdioSink(prefixBytes: 8)
        let transport = MCPStdioServerTransport(
            outputSink: sink, maximumQueuedWrites: 1,
            writeGateObserver: {
                event in if case .enqueued = event {
                    sink.recordQueued()
                }
            }
        )
        let frameA = Data(#"{"id":7,"result":{}}"#.utf8)
        let frameB = Data(#"{"id":"7"}"#.utf8)
        let sendA = Task { try await transport.send(frameA) }
        await sink.waitUntilBlocked()
        let sendB = Task { try await transport.send(frameB) }
        await sink.waitUntilQueued(1)
        await assertFailure(Task { try await transport.send(Data(#"{"id":8}"#.utf8)) }, .stdoutWriteQueueFull(maximum: 1))
        sink.open()
        try await sendA.value
        try await sendB.value
        XCTAssertEqual(try sink.readWire(), frameA + Data([10]) + frameB + Data([10]))
        let terminal = await transport.terminalError()
        XCTAssertNil(terminal)
        await transport.disconnect()
    }

    func testPinnedSDKDeadlineAfterPrefixCannotAppendReplacementOrLateResponse() async throws {
        let sink = try ScriptedStdioSink(prefixBytes: 8)
        let fixture = try StdioInputFixture()
        let transport = MCPStdioServerTransport(
            stdinFD: fixture.readDescriptor, outputSink: sink,
            writeGateObserver: {
                event in if case .enqueued = event {
                    sink.recordQueued()
                }
            }
        )
        let server = Server(
            name: "stdio-writer-regression",
            version: "1",
            configuration: .init(responseSendTimeout: .seconds(5))
        )
        let deadline = StdioManualDeadline()
        await server.setResponseSendDeadlineSleepForTesting { _ in try await deadline.sleep() }
        try await server.start(transport: transport)
        try fixture.write(Data(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#.utf8) + Data([10]))
        await sink.waitUntilBlocked()
        await deadline.waitUntilArmed()
        try fixture.write(Data(#"{"jsonrpc":"2.0","id":"7","method":"ping"}"#.utf8) + Data([10]))
        await sink.waitUntilQueued(1)
        await deadline.expire()
        await server.waitUntilCompleted()
        let terminal = await transport.waitUntilTerminal()
        sink.open()
        await assertFailure(Task { try await transport.send(Data(#"{"id":"late"}"#.utf8)) }, terminal)
        let wire = try sink.readWire()
        XCTAssertEqual(wire, sink.acceptedPrefix)
        XCTAssertEqual(wire.count, 8)
        await server.stop()
    }

    func testWriteTimeoutAfterPrefixSealsOwnerQueueAndFutureSends() async throws {
        let sink = try ScriptedStdioSink(prefixBytes: 8)
        let transport = MCPStdioServerTransport(
            outputSink: sink,
            writeGateObserver: {
                event in if case .enqueued = event {
                    sink.recordQueued()
                }
            }
        )
        let frame = Data(#"{"id":7,"result":{}}"#.utf8)
        let sendA = Task { try await transport.send(frame) }
        await sink.waitUntilBlocked()
        let sendB = Task { try await transport.send(Data(#"{"id":"7"}"#.utf8)) }
        await sink.waitUntilQueued(1)
        sink.failWait(errno: ETIMEDOUT)
        let terminal = MCPStdioServerTransport.TerminalError.stdoutWrite(
            errno: ETIMEDOUT, bytesWritten: 8, totalBytes: frame.count + 1
        )
        await assertFailure(sendA, terminal)
        await assertFailure(sendB, terminal)
        sink.open()
        await assertFailure(Task { try await transport.send(Data(#"{"id":"late"}"#.utf8)) }, terminal)
        XCTAssertEqual(try sink.readWire(), Data(frame.prefix(8)))
        let observed = await transport.waitUntilTerminal()
        XCTAssertEqual(observed, terminal)
        await transport.disconnect()
    }

    private func assertFailure(
        _ task: Task<Void, Error>, _ expected: MCPStdioServerTransport.TerminalError,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do { try await task.value
            XCTFail("Expected terminal send failure", file: file, line: line)
        } catch { XCTAssertEqual(error as? MCPStdioServerTransport.TerminalError, expected, file: file, line: line) }
    }
}

private final class ScriptedStdioSink: MCPStdioOutputSink, @unchecked Sendable {
    private let lock = NSLock()
    private let descriptors: [Int32]
    private let prefixBytes: Int
    private var firstPrefix = Data()
    private var wrotePrefix = false
    private var opened = false
    private var written = 0
    private var failNextWrite = false
    private var blocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var writableWaiter: CheckedContinuation<MCPStdioWritableResult, Never>?
    private var secondWriteWaiter: CheckedContinuation<Void, Never>?
    private var secondWrote = false
    private var waitCancelled = false
    private var queuedCount = 0
    private var queuedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(prefixBytes: Int) throws {
        self.prefixBytes = prefixBytes
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        self.descriptors = descriptors
    }

    deinit { descriptors.forEach { _ = close($0) } }
    func prepare() throws {}

    func write(_ bytes: UnsafeRawBufferPointer) -> MCPStdioWriteResult {
        lock.lock()
        defer { lock.unlock() }
        if !wrotePrefix {
            wrotePrefix = true
            firstPrefix = Data(bytes.prefix(prefixBytes))
            let count = writePipe(bytes, count: prefixBytes)
            guard count >= 0 else { return .failed(errno) }
            written += count
            return prefixBytes == 0 ? .wouldBlock : .wrote(count)
        }
        if !opened, bytes.first != UInt8(ascii: "{") {
            return .wouldBlock
        }
        let count = writePipe(bytes, count: bytes.count)
        guard count >= 0 else { return .failed(errno) }
        written += count
        if !opened {
            secondWrote = true
            secondWriteWaiter?.resume()
            secondWriteWaiter = nil
        }
        return .wrote(count)
    }

    /// Called under the sink lock; -1 deterministically yields EBADF without touching owned descriptors.
    private func writePipe(_ bytes: UnsafeRawBufferPointer, count: Int) -> Int {
        let descriptor = failNextWrite ? -1 : descriptors[1]
        failNextWrite = false
        return Darwin.write(descriptor, bytes.baseAddress, count)
    }

    func failNextWriteWithBadDescriptor() {
        lock.withLock { failNextWrite = true }
    }

    func awaitWritable() async -> MCPStdioWritableResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                blocked = true
                blockedWaiters.forEach { $0.resume() }
                blockedWaiters.removeAll()
                if opened || waitCancelled {
                    continuation.resume(returning: .ready)
                } else {
                    writableWaiter = continuation
                }
                lock.unlock()
            }
        } onCancel: {
            self.cancelWait()
        }
    }

    private func cancelWait() {
        lock.lock()
        waitCancelled = true
        writableWaiter?.resume(returning: .ready)
        writableWaiter = nil
        lock.unlock()
    }

    func recordQueued() {
        lock.lock()
        queuedCount += 1
        secondWriteWaiter?.resume()
        secondWriteWaiter = nil
        let ready = queuedWaiters.filter { $0.0 <= queuedCount }
        queuedWaiters.removeAll { $0.0 <= queuedCount }
        ready.forEach { $0.1.resume() }
        lock.unlock()
    }

    func waitUntilQueued(_ count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if queuedCount >= count {
                continuation.resume()
            } else {
                queuedWaiters.append((count, continuation))
            }
            lock.unlock()
        }
    }

    func waitUntilBlocked() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if blocked {
                continuation.resume()
            } else {
                blockedWaiters.append(continuation)
            }
            lock.unlock()
        }
    }

    func waitUntilSecondWriteOrQueued(transport: MCPStdioServerTransport) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if secondWrote || queuedCount > 0 {
                continuation.resume()
            } else {
                secondWriteWaiter = continuation
            }
            lock.unlock()
        }
    }

    func failWait(errno: Int32) {
        lock.lock()
        writableWaiter?.resume(returning: .failed(errno))
        writableWaiter = nil
        lock.unlock()
    }

    func open() {
        lock.lock()
        opened = true
        writableWaiter?.resume(returning: .ready)
        writableWaiter = nil
        lock.unlock()
    }

    var acceptedPrefix: Data {
        lock.lock()
        defer { lock.unlock() }
        return firstPrefix
    }

    func readWire() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: written)
        guard Darwin.read(descriptors[0], &bytes, bytes.count) == written else {
            throw NSError(domain: "ScriptedStdioSink", code: 1)
        }
        return Data(bytes)
    }
}

private final class StdioInputFixture {
    private var descriptors: [Int32]
    var readDescriptor: Int32 {
        descriptors[0]
    }

    init() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        self.descriptors = descriptors
    }

    func write(_ data: Data) throws {
        let count = data.withUnsafeBytes { Darwin.write(descriptors[1], $0.baseAddress, $0.count) }
        guard count == data.count else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    func closeWriter() throws {
        guard descriptors[1] >= 0 else { return }
        guard Darwin.close(descriptors[1]) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        descriptors[1] = -1
    }

    deinit { descriptors.filter { $0 >= 0 }.forEach { _ = close($0) } }
}

/// Exercises the pinned SDK's existing deadline hook without waiting on wall time.
private actor StdioManualDeadline {
    private var sleepers: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var armedWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep() async throws {
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers[token] = continuation
                    armedWaiters.forEach { $0.resume() }
                    armedWaiters.removeAll()
                }
            }
        } onCancel: { Task { await self.cancel(token) } }
    }

    func waitUntilArmed() async {
        if !sleepers.isEmpty {
            return
        }
        await withCheckedContinuation { armedWaiters.append($0) }
    }

    func expire() {
        let pending = sleepers
        sleepers.removeAll()
        pending.values.forEach { $0.resume() }
    }

    private func cancel(_ token: UUID) {
        sleepers.removeValue(forKey: token)?.resume(throwing: CancellationError())
    }
}

/// Parks outbound teardown after terminal ownership; no timer or scheduler-order assumption.
private actor StdioSealTeardownGate {
    private var suspended = false
    private var released = false
    private var owner: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        suspended = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        guard !released else { return }
        await withCheckedContinuation { owner = $0 }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        released = true
        owner?.resume()
        owner = nil
    }
}

/// Signals the detached reader's EOF record attempt, independently of receive completion.
private actor StdioReadEOFSignal {
    private var observed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        observed = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !observed else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
