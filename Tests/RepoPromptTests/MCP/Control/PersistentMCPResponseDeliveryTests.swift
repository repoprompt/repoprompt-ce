import Darwin
import Foundation
@testable import RepoPromptMCP
import RepoPromptShared
import XCTest

final class PersistentMCPResponseDeliveryTests: XCTestCase {
    func testProxyHalfCloseDrainsResponseAfterFormerGraceCheckpoint() async throws {
        var sockets = [Int32](repeating: -1, count: 2)
        var stdinPipe = [Int32](repeating: -1, count: 2)
        var stdoutPipe = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        XCTAssertEqual(Darwin.pipe(&stdinPipe), 0)
        XCTAssertEqual(Darwin.pipe(&stdoutPipe), 0)
        defer {
            (sockets + stdinPipe + stdoutPipe).forEach(Self.closeIfOpen)
        }

        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        let poller = ManualBridgeSocketPoller()
        let drainClock = ManualBridgeDrainClock()
        let bridgeTask = Task {
            do {
                try await BootstrapSocketProxy.runBridge(
                    socketFD: sockets[0],
                    stdinFD: stdinPipe[0],
                    stdoutFD: stdoutPipe[1],
                    identityCache: ClientIdentityCache(),
                    bridgeLedger: ledger,
                    faultRule: nil,
                    socketPoller: { _ in try await poller.next() },
                    drainClock: { drainClock.now() },
                    onStdinClosed: {
                        drainClock.advance(by: 2)
                        await poller.markStdinClosed()
                    }
                )
                await poller.markBridgeCompleted()
            } catch {
                await poller.markBridgeCompleted()
                throw error
            }
        }

        let requestFrame = request(id: 401)
        try Self.writeAll(requestFrame, to: stdinPipe[1])
        Self.closeIfOpen(stdinPipe[1])
        stdinPipe[1] = -1
        let forwardedRequest = try await Task.detached {
            try Self.readLine(from: sockets[1])
        }.value
        XCTAssertEqual(forwardedRequest, requestFrame)
        let observedStdinClose = await poller.waitUntilStdinClosed()
        XCTAssertTrue(observedStdinClose)
        XCTAssertGreaterThan(drainClock.now(), 1)

        let reachedInitialWait = await poller.waitUntilWaiting(count: 1)
        XCTAssertTrue(reachedInitialWait)
        await poller.resumeNext(.timedOut)
        let reachedBeyondFormerGraceWait = await poller.waitUntilWaiting(count: 2)
        XCTAssertTrue(
            reachedBeyondFormerGraceWait,
            "The bridge exited after the former one-second drain grace instead of waiting for the active response"
        )

        let responseFrame = response(id: 401)
        try Self.writeAll(responseFrame, to: sockets[1])
        await poller.resumeNext(.events(Int16(POLLIN)))
        try await bridgeTask.value

        let deliveredResponse = try Self.readLine(from: stdoutPipe[0])
        XCTAssertEqual(deliveredResponse, responseFrame)
        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 0)
        XCTAssertNil(snapshot.terminalReason)
    }

    func testFiveIndependentCallsDeliverExactlyFiveMatchingResponses() async throws {
        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        let writes = WriteRecorder()

        for id in 101 ... 105 {
            try await deliver(request(id: id), direction: .clientToServer, ledger: ledger, writes: writes)
        }
        for id in [105, 103, 101, 104, 102] {
            try await deliver(response(id: id), direction: .serverToClient, ledger: ledger, writes: writes)
        }

        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 0)
        XCTAssertEqual(snapshot.recentCompletionCount, 5)
        let writtenFrameCount = await writes.frames.count
        let deliveredResponseIDs = await writes.responseIDs
        XCTAssertEqual(writtenFrameCount, 10)
        XCTAssertEqual(Set(deliveredResponseIDs), Set(101 ... 105))
    }

    func testExactIDStdoutFaultTerminatesConnectionWithoutSelectiveDropContinuation() async throws {
        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        let writes = WriteRecorder()

        for id in 101 ... 105 {
            try await deliver(request(id: id), direction: .clientToServer, ledger: ledger, writes: writes)
        }

        try await deliver(response(id: 101), direction: .serverToClient, ledger: ledger, writes: writes)
        let fault = JSONRPCBridgeFaultRule(direction: .serverToClient, id: .number(102))
        do {
            _ = try await JSONRPCBridgeDelivery.forward(
                frame: response(id: 102),
                direction: .serverToClient,
                ledger: ledger,
                faultRule: fault
            ) { frame in
                await writes.record(frame)
            }
            XCTFail("Expected exact-ID injected write failure")
        } catch let error as JSONRPCBridgeLedgerError {
            XCTAssertEqual(error, .injectedFault(.serverToClient, .number(102)))
        }

        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.terminalReason, "fault_injected_fail_destination_write")
        XCTAssertFalse(snapshot.canReconnect)
        let deliveredResponseIDs = await writes.responseIDs
        XCTAssertEqual(deliveredResponseIDs, [101])

        do {
            try await deliver(response(id: 103), direction: .serverToClient, ledger: ledger, writes: writes)
            XCTFail("A terminal session must reject later sibling responses")
        } catch let error as JSONRPCBridgeLedgerError {
            XCTAssertEqual(error, .terminal("fault_injected_fail_destination_write"))
        }
    }

    func testFaultRuleCanConstrainMethodAndToolWithoutPayloadMatching() async throws {
        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        let writes = WriteRecorder()

        try await deliver(request(id: 201, tool: "read_file"), direction: .clientToServer, ledger: ledger, writes: writes)
        let matching = JSONRPCBridgeFaultRule(
            direction: .serverToClient,
            id: .number(201),
            method: "tools/call",
            tool: "read_file"
        )
        do {
            _ = try await JSONRPCBridgeDelivery.forward(
                frame: response(id: 201),
                direction: .serverToClient,
                ledger: ledger,
                faultRule: matching
            ) { frame in
                await writes.record(frame)
            }
            XCTFail("Expected constrained fault to match correlated request metadata")
        } catch let error as JSONRPCBridgeLedgerError {
            XCTAssertEqual(error, .injectedFault(.serverToClient, .number(201)))
        }
    }

    func testIDReuseAfterResponseBytesWriteBeforeLedgerCommitIsAccepted() async throws {
        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        let responseWriteGate = AsyncGate()
        let writes = WriteRecorder()

        try await deliver(request(id: 250), direction: .clientToServer, ledger: ledger, writes: writes)
        let responseTask = Task {
            try await JSONRPCBridgeDelivery.forward(
                frame: response(id: 250),
                direction: .serverToClient,
                ledger: ledger
            ) { frame in
                await writes.record(frame)
                await responseWriteGate.markEnteredAndWait()
            }
        }

        await responseWriteGate.waitUntilEntered()
        try await deliver(request(id: 250, tool: "search"), direction: .clientToServer, ledger: ledger, writes: writes)
        await responseWriteGate.release()
        _ = try await responseTask.value

        var snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 1)
        try await deliver(response(id: 250), direction: .serverToClient, ledger: ledger, writes: writes)
        snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 0)
    }

    func testImmediateResponseWhileRequestWriterIsHeldDoesNotBecomeUnknown() async throws {
        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        let gate = AsyncGate()
        let writes = WriteRecorder()

        let requestTask = Task {
            try await JSONRPCBridgeDelivery.forward(
                frame: request(id: 301),
                direction: .clientToServer,
                ledger: ledger
            ) { frame in
                await gate.markEnteredAndWait()
                await writes.record(frame)
            }
        }

        await gate.waitUntilEntered()
        try await deliver(response(id: 301), direction: .serverToClient, ledger: ledger, writes: writes)
        await gate.release()
        _ = try await requestTask.value

        let activeRequestCount = await ledger.snapshot().activeRequestCount
        XCTAssertEqual(activeRequestCount, 0)
    }
}

private final class ManualBridgeDrainClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value += interval
        lock.unlock()
    }
}

private actor ManualBridgeSocketPoller {
    private var waitingCount = 0
    private var queuedResults: [BridgeSocketPollResult] = []
    private var resultContinuation: CheckedContinuation<BridgeSocketPollResult, Error>?
    private var pendingPollCancelled = false
    private var stdinClosed = false
    private var bridgeCompleted = false
    private var stdinClosedWaiters: [CheckedContinuation<Bool, Never>] = []
    private var waitingCountWaiters: [(count: Int, continuation: CheckedContinuation<Bool, Never>)] = []

    func next() async throws -> BridgeSocketPollResult {
        waitingCount += 1
        resumeWaitingCountWaiters()
        if !queuedResults.isEmpty {
            return queuedResults.removeFirst()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if pendingPollCancelled {
                    pendingPollCancelled = false
                    continuation.resume(throwing: CancellationError())
                } else {
                    resultContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelPendingPoll() }
        }
    }

    func resumeNext(_ result: BridgeSocketPollResult) {
        if let resultContinuation {
            self.resultContinuation = nil
            resultContinuation.resume(returning: result)
        } else {
            queuedResults.append(result)
        }
    }

    func markStdinClosed() {
        stdinClosed = true
        let waiters = stdinClosedWaiters
        stdinClosedWaiters.removeAll()
        waiters.forEach { $0.resume(returning: true) }
    }

    func waitUntilStdinClosed() async -> Bool {
        if stdinClosed { return true }
        if bridgeCompleted { return false }
        return await withCheckedContinuation { stdinClosedWaiters.append($0) }
    }

    func waitUntilWaiting(count: Int) async -> Bool {
        if waitingCount >= count { return true }
        if bridgeCompleted { return false }
        return await withCheckedContinuation { continuation in
            waitingCountWaiters.append((count, continuation))
        }
    }

    func markBridgeCompleted() {
        bridgeCompleted = true
        cancelPendingPoll()
        let closeWaiters = stdinClosedWaiters
        stdinClosedWaiters.removeAll()
        closeWaiters.forEach { $0.resume(returning: false) }
        resumeWaitingCountWaiters()
    }

    private func cancelPendingPoll() {
        guard let resultContinuation else {
            pendingPollCancelled = true
            return
        }
        self.resultContinuation = nil
        resultContinuation.resume(throwing: CancellationError())
    }

    private func resumeWaitingCountWaiters() {
        var pending: [(count: Int, continuation: CheckedContinuation<Bool, Never>)] = []
        for waiter in waitingCountWaiters {
            if waitingCount >= waiter.count {
                waiter.continuation.resume(returning: true)
            } else if bridgeCompleted {
                waiter.continuation.resume(returning: false)
            } else {
                pending.append(waiter)
            }
        }
        waitingCountWaiters = pending
    }
}

private actor WriteRecorder {
    private(set) var frames: [Data] = []

    var responseIDs: [Int] {
        frames.compactMap { frame in
            guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
                  object["result"] != nil,
                  let number = object["id"] as? NSNumber
            else {
                return nil
            }
            return number.intValue
        }
    }

    func record(_ frame: Data) {
        frames.append(frame)
    }
}

private actor AsyncGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markEnteredAndWait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private extension PersistentMCPResponseDeliveryTests {
    static func closeIfOpen(_ fd: Int32) {
        if fd >= 0 {
            _ = Darwin.close(fd)
        }
    }

    static func writeAll(_ data: Data, to fd: Int32) throws {
        var written = 0
        while written < data.count {
            let result = data.withUnsafeBytes { bytes in
                Darwin.write(fd, bytes.baseAddress!.advanced(by: written), data.count - written)
            }
            if result > 0 {
                written += result
            } else if result < 0, errno == EINTR {
                continue
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    static func readLine(from fd: Int32) throws -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let result = Darwin.read(fd, &byte, 1)
            if result == 1 {
                data.append(byte)
                if byte == UInt8(ascii: "\n") { return data }
            } else if result < 0, errno == EINTR {
                continue
            } else if result == 0 {
                throw POSIXError(.ECONNRESET)
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    func deliver(
        _ frame: Data,
        direction: JSONRPCBridgeDirection,
        ledger: JSONRPCBridgeLedger,
        writes: WriteRecorder
    ) async throws {
        _ = try await JSONRPCBridgeDelivery.forward(
            frame: frame,
            direction: direction,
            ledger: ledger
        ) { frame in
            await writes.record(frame)
        }
    }

    func request(id: Int, tool: String = "read_file") -> Data {
        line("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"tools/call\",\"params\":{\"name\":\"\(tool)\",\"path\":\"/tmp/fixture\"}}")
    }

    func response(id: Int) -> Data {
        line("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{\"content\":[]}}")
    }

    func line(_ string: String) -> Data {
        Data((string + "\n").utf8)
    }
}
