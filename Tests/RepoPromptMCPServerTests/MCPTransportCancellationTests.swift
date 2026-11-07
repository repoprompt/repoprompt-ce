import Darwin
import Foundation
import Logging
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCPServer
import RepoPromptShared
import XCTest

final class UnixSocketMCPTransportCancellationTests: XCTestCase {
    func testPinnedSDKNormalReturnAfterCancellationDoesNotReachWire() async throws {
        try await assertPinnedSDKCancellation(customError: false)
    }

    func testPinnedSDKCustomCancellationErrorDoesNotReachWire() async throws {
        try await assertPinnedSDKCancellation(customError: true)
    }

    private func assertPinnedSDKCancellation(customError: Bool) async throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENFILE)
        }
        let peer = descriptors[1]
        defer { Darwin.close(peer) }
        let transport = try UnixSocketMCPTransport(connectedFD: descriptors[0])
        let entered = expectation(description: "cancelled handler entered")
        let unrelatedEntered = expectation(description: "unrelated string ID remains active")
        let cancelled = expectation(description: "SDK cancelled the numeric ID handler")
        let completedSend = expectation(description: "SDK numeric response delivery attempt completed")
        let unrelatedSend = expectation(description: "unrelated string response delivery completed")
        let held = CancellationSettlementGate()
        let unrelated = CancellationSettlementGate()
        let observed = CancellationObservedTransport(transport: transport, completedSend: completedSend, unrelatedSend: unrelatedSend)
        let server = Server(name: "cancellation-contract", version: "1", capabilities: .init(tools: .init()))
        await server.withMethodHandler(CallTool.self) { params in
            if params.name == "unrelated" {
                unrelatedEntered.fulfill()
                await unrelated.wait()
                return .init(content: [.text("unrelated-result")])
            }
            return try await withTaskCancellationHandler {
                entered.fulfill()
                await held.wait()
                if customError {
                    throw CancelledByClient()
                }
                return .init(content: [.text("late-cancelled-result")])
            } onCancel: {
                cancelled.fulfill()
            }
        }
        try await server.start(transport: observed)
        do {
            let ledger = JSONRPCBridgeLedger()
            _ = try await ledger.beginConnection()
            let numeric = frame(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"held"}}"#)
            let string = frame(#"{"jsonrpc":"2.0","id":"7","method":"tools/call","params":{"name":"unrelated"}}"#)
            let cancellation = frame(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#)
            for request in [numeric, string] {
                let prepared = try await ledger.prepare(frame: request, direction: .clientToServer, now: 0)
                try await ledger.commit(prepared, now: 0)
                try write(request, to: peer)
            }
            await fulfillment(of: [entered, unrelatedEntered], timeout: 5)
            let initialDelivery = await transport.responseDeliverySnapshot()
            XCTAssertEqual(initialDelivery.pendingRequestCount, 2)
            let preparedCancel = try await ledger.prepare(frame: cancellation, direction: .clientToServer, now: 1)
            try await ledger.commit(preparedCancel, now: 1)
            try write(cancellation, to: peer)
            await fulfillment(of: [cancelled], timeout: 5)
            let cancellationDelivery = await transport.responseDeliverySnapshot()
            XCTAssertEqual(cancellationDelivery.pendingRequestCount, 1, "Client cancellation retires only numeric7's delivery obligation")
            await held.release()
            await fulfillment(of: [completedSend], timeout: 5)
            let stillActive = await ledger.snapshot(now: 32)
            XCTAssertEqual(stillActive.activeRequestCount, 1)
            XCTAssertNil(stillActive.terminalReason)
            await unrelated.release()
            await fulfillment(of: [unrelatedSend], timeout: 5)
            let sentinel = frame(#"{"jsonrpc":"2.0","id":99,"method":"ping"}"#)
            let preparedSentinel = try await ledger.prepare(frame: sentinel, direction: .clientToServer, now: 32)
            try await ledger.commit(preparedSentinel, now: 32)
            try write(sentinel, to: peer)
            let replies = try await Task.detached { try Self.readThroughSentinel(from: peer) }.value
            XCTAssertFalse(replies.contains { reply in
                JSONRPCBridgeFrameInspector.inspectPermissively(reply, direction: .serverToClient)
                    .contains { $0.id == .number(7) }
            }, "A client-cancelled response must never reach the bridge, even after cleanup returns")
            XCTAssertTrue(replies.contains { reply in
                JSONRPCBridgeFrameInspector.inspectPermissively(reply, direction: .serverToClient)
                    .contains { $0.id == .string("7") }
            })
            for reply in replies {
                let prepared = try await ledger.prepare(frame: reply, direction: .serverToClient, now: 32)
                try await ledger.commit(prepared, now: 32)
            }
            let final = await ledger.snapshot(now: 32)
            XCTAssertNil(final.terminalReason)
            XCTAssertEqual(final.activeRequestCount, 0)
            let delivery = await transport.responseDeliverySnapshot()
            XCTAssertEqual(delivery.pendingRequestCount, 0)
            await server.stop()
        } catch {
            await held.release()
            await unrelated.release()
            await server.stop()
            throw error
        }
    }

    private func frame(_ string: String) -> Data {
        Data((string + "\n").utf8)
    }

    private func write(_ data: Data, to fd: Int32) throws {
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard count == data.count else { throw POSIXError(.EIO) }
    }

    private static func readThroughSentinel(from fd: Int32) throws -> [Data] {
        var buffer = Data()
        var frames: [Data] = []
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, 5000) > 0 else { throw POSIXError(.ETIMEDOUT) }
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count > 0 else { throw POSIXError(.EIO) }
            buffer.append(contentsOf: bytes.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let frame = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                frames.append(frame)
                let ids = JSONRPCBridgeFrameInspector.inspectPermissively(frame, direction: .serverToClient).compactMap(\.id)
                if ids.contains(.number(99)) {
                    return frames
                }
            }
        }
    }
}

private struct CancelledByClient: Error {}

private actor CancellationSettlementGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if released {
            return
        }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private actor CancellationObservedTransport: Transport {
    let logger = Logger(label: "cancellation-contract")
    private let transport: UnixSocketMCPTransport
    private let completedSend: XCTestExpectation
    private let unrelatedSend: XCTestExpectation
    private var stream = AsyncThrowingStream<Data, Error> { $0.finish() }
    init(transport: UnixSocketMCPTransport, completedSend: XCTestExpectation, unrelatedSend: XCTestExpectation) {
        self.transport = transport
        self.completedSend = completedSend
        self.unrelatedSend = unrelatedSend
    }

    func connect() async throws {
        try await transport.connect()
        stream = await transport.receive()
    }

    func disconnect() async {
        await transport.disconnect()
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    func send(_ frame: Data) async throws {
        try await transport.send(frame)
        if JSONRPCBridgeFrameInspector.inspectPermissively(frame, direction: .serverToClient).contains(where: { $0.id == .number(7) }) {
            completedSend.fulfill()
        }
        if JSONRPCBridgeFrameInspector.inspectPermissively(frame, direction: .serverToClient).contains(where: { $0.id == .string("7") }) {
            unrelatedSend.fulfill()
        }
    }
}

final class MCPClientCancellationOwnershipTests: XCTestCase {
    func testMixedBatchPreservesExactStringIDNullErrorAndNotification() throws {
        let ledger = MCPExecutionWatchdogResponseLedger()
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(frame(#"{"id":7,"method":"tools/list"}"#)))
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(frame(#"{"id":"7","method":"tools/list"}"#)))
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(frame(#"{"method":"notifications/cancelled","params":{"requestId":7}}"#)))
        let batch = frame(#"[{"id":7,"result":{}},{"id":"7","result":{}},{"id":null,"error":{"code":-32600,"message":"Invalid Request"}},{"method":"notifications/progress","params":{"progress":1}}]"#)
        guard case let .frame(prepared) = ledger.prepareServerFrameForDelivery(batch) else {
            return XCTFail("Only the cancelled numeric response may be removed")
        }
        let metadata = JSONRPCBridgeFrameInspector.inspectPermissively(prepared.data, direction: .serverToClient)
        XCTAssertEqual(metadata.filter { $0.kind == .response }.compactMap(\.id), [.string("7"), .null])
        XCTAssertEqual(metadata.filter { $0.kind == .notification }.map(\.method), ["notifications/progress"])
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(frame(#"{"method":"notifications/cancelled","params":{"requestId":99}}"#)))
        guard case .frame = ledger.prepareServerFrameForDelivery(frame(#"{"id":99,"result":{}}"#)) else {
            return XCTFail("Unknown cancellation cannot authorize blanket response suppression")
        }
    }

    func testRetentionCapacityFailsClosedWithoutEviction() throws {
        let ledger = MCPExecutionWatchdogResponseLedger(maximumCancelledRequestIDs: 1)
        for id in [7, 8] {
            XCTAssertTrue(try ledger.recordAcceptedClientFrame(frame("{\"id\":\(id),\"method\":\"tools/list\"}")))
        }
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(frame(#"{"method":"notifications/cancelled","params":{"requestId":7}}"#)))
        XCTAssertThrowsError(try ledger.recordAcceptedClientFrame(frame(#"{"method":"notifications/cancelled","params":{"requestId":8}}"#))) {
            XCTAssertEqual($0 as? MCPClientCancellationOwnershipError, .retentionCapacityExceeded(1))
        }
        XCTAssertThrowsError(try ledger.recordAcceptedClientFrame(frame(#"{"id":9,"method":"tools/list"}"#))) {
            XCTAssertEqual($0 as? MCPClientCancellationOwnershipError, .retentionCapacityExceeded(1))
        }
        guard case let .suppressed(phase, _) = ledger.prepareServerFrameForDelivery(frame(#"{"id":7,"result":{}}"#)) else {
            return XCTFail("Capacity failure cannot let a previous cancelled response escape")
        }
        XCTAssertEqual(phase, "client_cancellation_ownership_failure")
    }

    func testSameGenerationReuseIsRefusedButResetFencesOldIngress() throws {
        let ledger = MCPExecutionWatchdogResponseLedger(maximumCancelledRequestIDs: 1)
        let oldGeneration = ledger.currentGeneration
        let request = frame(#"{"id":7,"method":"tools/list"}"#)
        let cancellation = frame(#"{"method":"notifications/cancelled","params":{"requestId":7}}"#)
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(request, expectedGeneration: oldGeneration))
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(cancellation, expectedGeneration: oldGeneration))
        XCTAssertThrowsError(try ledger.recordAcceptedClientFrame(request, expectedGeneration: oldGeneration)) {
            XCTAssertEqual($0 as? MCPClientCancellationOwnershipError, .cancelledIDReuse(.number(7)))
        }
        ledger.reset()
        let generation = ledger.currentGeneration
        XCTAssertNotEqual(generation, oldGeneration)
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(request, expectedGeneration: generation))
        XCTAssertFalse(try ledger.recordAcceptedClientFrame(cancellation, expectedGeneration: oldGeneration))
        guard case .frame = ledger.prepareServerFrameForDelivery(frame(#"{"id":7,"result":{}}"#)) else {
            return XCTFail("Old ingress cannot cancel the fresh generation's reused ID")
        }
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(cancellation, expectedGeneration: generation))
        guard case .suppressed = ledger.prepareServerFrameForDelivery(frame(#"{"id":7,"result":{}}"#)) else {
            return XCTFail("Reset must restore bounded capacity, not disable cancellation ownership")
        }
    }

    func testCancellationBeforeWatchdogSealRetiresOnlyItsExactID() throws {
        let ledger = MCPExecutionWatchdogResponseLedger()
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(frame(#"[{"id":7,"method":"tools/list"},{"id":"7","method":"tools/list"}]"#)))
        XCTAssertTrue(try ledger.recordAcceptedClientFrame(frame(#"{"method":"notifications/cancelled","params":{"requestId":7}}"#)))
        ledger.seal()
        XCTAssertEqual(ledger.takeOutstandingRequestIDsAfterSeal(), [.string("7")])
        guard case let .suppressed(phase, _) = ledger.prepareServerFrameForDelivery(frame(#"{"id":7,"result":{}}"#)) else {
            return XCTFail("A cancelled response remains suppressed after terminal sealing")
        }
        XCTAssertEqual(phase, "watchdog_late_response_suppressed")
    }

    func testDeliveryTrackerCancellationPreservesStringIDAndRejectsStaleIngress() async {
        let tracker = MCPDomainResponseDeliveryTracker()
        let oldGeneration = tracker.currentGeneration
        let request = frame(#"{"id":7,"method":"tools/list"}"#)
        let cancellation = frame(#"{"method":"notifications/cancelled","params":{"requestId":7}}"#)
        tracker.recordAcceptedClientFrame(request)
        tracker.recordAcceptedClientFrame(frame(#"{"id":"7","method":"tools/list"}"#))
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 2)
        tracker.recordAcceptedClientFrame(cancellation)
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 1)
        tracker.recordAcceptedClientFrame(frame(#"{"method":"notifications/cancelled","params":{"requestId":99}}"#))
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 1)
        tracker.recordDeliveredServerFrame(frame(#"{"id":"7","result":{}}"#))
        let drained = await tracker.waitUntilDrained()
        XCTAssertTrue(drained)
        tracker.reset()
        tracker.recordAcceptedClientFrame(request, expectedGeneration: tracker.currentGeneration)
        tracker.recordAcceptedClientFrame(cancellation, expectedGeneration: oldGeneration)
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 1)
        tracker.recordAcceptedClientFrame(cancellation, expectedGeneration: tracker.currentGeneration)
        let cancelledDrain = await tracker.waitUntilDrained()
        XCTAssertTrue(cancelledDrain)
    }

    private func frame(_ json: String) -> Data {
        Data((json + "\n").utf8)
    }
}
