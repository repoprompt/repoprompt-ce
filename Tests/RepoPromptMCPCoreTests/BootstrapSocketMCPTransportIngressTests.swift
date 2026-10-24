import Darwin
import Foundation
@testable import RepoPromptMCPCore
import XCTest

final class BootstrapSocketMCPTransportIngressTests: XCTestCase {
    func testWithheldConsumerReportsOverflowInsteadOfDroppingTerminalResponse() async throws {
        let pair = try makeSocketPair()
        defer { Darwin.close(pair[1]) }
        let transport = try BootstrapSocketMCPTransport(connectedFD: pair[0])
        try await transport.connect()
        let frames = numberedFrames(count: 1025)
        try writeFrames(frames, to: pair[1])
        XCTAssertEqual(shutdown(pair[1], SHUT_WR), 0)
        try waitForPeerShutdown(pair[1])

        let stream = await transport.receive()
        var observed: [Data] = []
        var terminalError: Error?
        do {
            for try await frame in stream {
                observed.append(frame)
            }
        } catch { terminalError = error }
        XCTAssertEqual(observed, Array(frames.prefix(1024)))
        XCTAssertEqual(
            terminalError as? BootstrapSocketReceiveBufferOverflowError,
            BootstrapSocketReceiveBufferOverflowError(capacity: 1024)
        )
        await transport.disconnect()
    }

    func testAtCapacityPreservesEveryFrameBeforeCleanEOF() async throws {
        let pair = try makeSocketPair()
        defer { Darwin.close(pair[1]) }
        let transport = try BootstrapSocketMCPTransport(connectedFD: pair[0])
        try await transport.connect()
        let frames = numberedFrames(count: 1024)
        try writeFrames(frames, to: pair[1])
        XCTAssertEqual(shutdown(pair[1], SHUT_WR), 0)
        try waitForPeerShutdown(pair[1])
        var observed: [Data] = []
        for try await frame in await transport.receive() {
            observed.append(frame)
        }
        XCTAssertEqual(observed, frames)
        await transport.disconnect()
    }

    func testInjectedOverflowUsesConfiguredCapacityAndIgnoresStaleToken() async throws {
        let pair = try makeSocketPair()
        defer { Darwin.close(pair[1]) }
        let transport = try BootstrapSocketMCPTransport(connectedFD: pair[0], receiveBufferCapacity: 3)
        await transport.debugHoldReaderTerminalCallback()
        await transport.debugHoldReaderCancellationCallback()
        try await transport.connect()

        // A stale identity must leave ingress and the adopted connection live.
        await transport.debugDeliverReceiveOverflow(token: 2)
        try await transport.connect()
        let frames = numberedFrames(count: 3)
        try writeFrames(frames, to: pair[1])
        XCTAssertEqual(shutdown(pair[1], SHUT_WR), 0)
        await transport.debugWaitForHeldReaderTerminalCallback()
        let pending = await transport.debugIngressTeardownCounts()
        XCTAssertEqual(pending.finalized, 0)
        XCTAssertEqual(pending.closed, 0)

        // Exactly capacity frames means no real overflow error can mask the
        // injected callback's configured-capacity diagnostic.
        await transport.debugDeliverReceiveOverflow(token: 1)
        var observed: [Data] = []
        var terminalError: Error?
        do {
            for try await frame in await transport.receive() {
                observed.append(frame)
            }
        } catch { terminalError = error }
        XCTAssertEqual(observed, frames)
        XCTAssertEqual(
            terminalError as? BootstrapSocketReceiveBufferOverflowError,
            BootstrapSocketReceiveBufferOverflowError(capacity: 3)
        )
        await transport.debugDeliverReaderCancellation(token: 1)
        await transport.debugDeliverReceiveOverflow(token: 2)
        let settled = await transport.debugIngressTeardownCounts()
        XCTAssertEqual(settled.finalized, 1)
        XCTAssertEqual(settled.closed, 1)
        try waitForPeerShutdown(pair[1])
        await transport.debugReleaseReaderTerminalCallbacks()
        await transport.debugReleaseReaderCancellationCallbacks()
        await transport.disconnect()
    }

    func testEOFFirstKeepsOverflowAndSettlesReaderExactlyOnce() async throws {
        try await assertDelayedTeardown(overflowFirst: false)
    }

    func testOverflowFirstIgnoresDelayedEOFAndSettlesReaderExactlyOnce() async throws {
        try await assertDelayedTeardown(overflowFirst: true)
    }

    private func assertDelayedTeardown(overflowFirst: Bool) async throws {
        let pair = try makeSocketPair()
        defer { Darwin.close(pair[1]) }
        let transport = try BootstrapSocketMCPTransport(connectedFD: pair[0], receiveBufferCapacity: 2)
        await transport.debugHoldReaderTerminalCallback()
        await transport.debugHoldReceiveOverflowCallback()
        await transport.debugHoldReaderCancellationCallback()
        try await transport.connect()

        // Wrong generation must not close a live socket, even with the same fd.
        await transport.debugDeliverReceiveOverflow(token: 2)
        await transport.debugDeliverReaderEOF(token: 2)
        let frames = numberedFrames(count: 5)
        try writeFrames(frames, to: pair[1])
        XCTAssertEqual(shutdown(pair[1], SHUT_WR), 0)
        // This observes the real EOF callback after all five numbered reader
        // callbacks. Overflow and actor teardown remain held independently.
        await transport.debugWaitForHeldReaderTerminalCallback()
        if overflowFirst {
            await transport.debugDeliverReceiveOverflow(token: 1)
        } else {
            await transport.debugDeliverReaderEOF(token: 1)
        }
        var observed: [Data] = []
        var terminalError: Error?
        do {
            for try await frame in await transport.receive() {
                observed.append(frame)
            }
        } catch { terminalError = error }
        XCTAssertEqual(observed, Array(frames.prefix(2)), "No frame after the gap may enter the stream")
        XCTAssertEqual(
            terminalError as? BootstrapSocketReceiveBufferOverflowError,
            BootstrapSocketReceiveBufferOverflowError(capacity: 2)
        )
        do {
            try await transport.send(Data("after overflow".utf8))
            XCTFail("A failed transport must reject later sends")
        } catch {}
        do {
            try await transport.connect()
            XCTFail("An adopted socket cannot be reconnected after overflow")
        } catch {}

        let pending = await transport.debugIngressTeardownCounts()
        XCTAssertEqual(pending.finalized, 0)
        XCTAssertEqual(pending.closed, 0, "Only the matching cancellation finalizer closes the descriptor")
        await transport.debugDeliverReaderCancellation(token: 2)
        await transport.debugDeliverReaderCancellation(token: 1)
        await transport.debugDeliverReaderCancellation(token: 1)
        await transport.debugDeliverReaderEOF(token: 1)
        await transport.debugDeliverReceiveOverflow(token: 1)
        await transport.disconnect()
        let settled = await transport.debugIngressTeardownCounts()
        XCTAssertEqual(settled.finalized, 1)
        XCTAssertEqual(settled.closed, 1)
        // Cancellation owns the physical close. Peer EOF is observable only
        // after that held, matching-identity finalizer has closed the descriptor.
        try waitForPeerShutdown(pair[1])
        XCTAssertEqual(settled.staleTerminal, 2)
        XCTAssertEqual(settled.staleCancellation, 2)
        await transport.debugReleaseReaderTerminalCallbacks()
        await transport.debugReleaseReceiveOverflowCallbacks()
        await transport.debugReleaseReaderCancellationCallbacks()
    }

    private func numberedFrames(count: Int) -> [Data] {
        (1 ... count).map { Data("{\"jsonrpc\":\"2.0\",\"id\":\($0),\"result\":\($0)}".utf8) }
    }

    private func makeSocketPair() throws -> [Int32] {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return descriptors
    }

    private func writeFrames(_ frames: [Data], to descriptor: Int32) throws {
        var data = Data()
        for frame in frames {
            data.append(frame)
            data.append(0x0A)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard result > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                offset += result
            }
        }
    }

    /// EOF on the peer proves the transport has read and settled ingress before
    /// the consumer starts. The bounded poll is a failure deadline, not a sleep.
    private func waitForPeerShutdown(_ descriptor: Int32) throws {
        var descriptorPoll = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptorPoll, 1, 5000) > 0 else {
            XCTFail("Transport did not shut down after inbound EOF")
            throw POSIXError(.ETIMEDOUT)
        }
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(descriptor, &byte, 1), 0)
    }
}
