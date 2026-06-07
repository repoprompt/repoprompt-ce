import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class UnixSocketMCPReceiveOverflowTests: XCTestCase {
    func testOverflowPreservesAcceptedOrderTerminatesStreamAndPublishesStableDiagnostics() async throws {
        #if DEBUG
            let descriptors = try Self.makeSocketPair()
            defer { Self.closeIfOpen(descriptors[1]) }

            let transport = try UnixSocketMCPTransport(
                connectedFD: descriptors[0],
                receiveBufferCapacity: 2
            )
            let manager = ServerNetworkManager()
            let connectionID = UUID()
            try await transport.connect()
            let stream = await transport.receive()

            try Self.writeAll(
                Data("frame-1\nframe-2\nframe-3\nframe-4\nframe-5\n".utf8),
                to: descriptors[1]
            )

            let didOverflow = await Self.waitUntil {
                let snapshot = await transport.ingressSnapshot()
                return snapshot.terminalCause == .receiveBufferOverflow
            }
            XCTAssertTrue(didOverflow)

            var iterator = stream.makeAsyncIterator()
            let firstFrame = try await iterator.next()
            let secondFrame = try await iterator.next()
            XCTAssertEqual(firstFrame, Data("frame-1".utf8))
            XCTAssertEqual(secondFrame, Data("frame-2".utf8))
            do {
                _ = try await iterator.next()
                XCTFail("Expected the receive stream to terminate with an overflow error")
            } catch let error as MCPReceiveBufferOverflowError {
                XCTAssertEqual(error.capacity, 2)
                XCTAssertEqual(error.highWaterMark, 2)
            } catch {
                XCTFail("Unexpected receive termination error: \(error)")
            }

            let snapshot = await transport.ingressSnapshot()
            XCTAssertEqual(snapshot.receiveBufferCapacity, 2)
            XCTAssertEqual(snapshot.acceptedFrameCount, 2)
            XCTAssertEqual(snapshot.droppedFrameCount, 1)
            XCTAssertEqual(snapshot.receiveBufferHighWaterMark, 2)
            XCTAssertTrue(snapshot.isTerminal)
            XCTAssertEqual(snapshot.terminalCause, .receiveBufferOverflow)

            await manager.recordTransportIngressTerminal(
                connectionID: connectionID,
                clientName: "overflow-test-client",
                sessionToken: "overflow-test-session",
                snapshot: snapshot
            )
            let payload = await manager.debugTransportIngressSnapshotPayload(
                currentConnectionID: connectionID,
                requestedConnectionID: connectionID
            )
            XCTAssertEqual(payload["present"] as? Bool, true)
            XCTAssertEqual(payload["active"] as? Bool, false)
            let ingress = try XCTUnwrap(payload["ingress"] as? [String: Any])
            XCTAssertEqual(ingress["terminal_cause"] as? String, MCPTransportTerminalCause.receiveBufferOverflow.rawValue)
            XCTAssertEqual(ingress["accepted_frames"] as? Int, 2)
            XCTAssertEqual(ingress["dropped_frames"] as? Int, 1)

            let history = await manager.debugConnectionHistoryPayload(
                limit: 10,
                clientName: nil,
                sessionFingerprint: nil,
                connectionID: connectionID
            )
            let events = try XCTUnwrap(history["events"] as? [[String: Any]])
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events[0]["event"] as? String, "transport_terminal")
            XCTAssertEqual(events[0]["reason"] as? String, MCPTransportTerminalCause.receiveBufferOverflow.rawValue)

            let peerSawEOF = await Self.waitUntil { Self.peerObservedEOF(on: descriptors[1]) }
            XCTAssertTrue(peerSawEOF)
            let cleanupCompleted = await Self.waitUntil {
                let cleanup = await transport.debugCleanupSnapshot()
                return !cleanup.hasActiveReader
                    && cleanup.pendingReaderCancellationCount == 0
                    && cleanup.earlyReaderCancellationCount == 0
                    && !cleanup.readerIsRetained
                    && cleanup.cancellationCallbackCount == 1
                    && cleanup.finalizationCount == 1
                    && cleanup.descriptorCloseCount == 1
                    && !cleanup.socketIsOwned
            }
            XCTAssertTrue(cleanupCompleted)
            let settledCleanup = await transport.debugCleanupSnapshot()
            XCTAssertEqual(settledCleanup.cancellationCallbackCount, 1)
            XCTAssertEqual(settledCleanup.finalizationCount, 1)
            XCTAssertEqual(settledCleanup.descriptorCloseCount, 1)
            XCTAssertFalse(settledCleanup.socketIsOwned)

            await transport.disconnect()
            await transport.disconnect()
        #else
            throw XCTSkip("Transport ingress diagnostics require a DEBUG build")
        #endif
    }

    func testOverflowCauseWinsWhenLocalDisconnectRacesDeferredOverflowTeardown() async throws {
        #if DEBUG
            let descriptors = try Self.makeSocketPair()
            defer { Self.closeIfOpen(descriptors[1]) }

            let transport = try UnixSocketMCPTransport(
                connectedFD: descriptors[0],
                receiveBufferCapacity: 1
            )
            await transport.debugDeferNextReceiveOverflowTeardown()
            try await transport.connect()
            let stream = await transport.receive()

            try Self.writeAll(Data("accepted\noverflow\n".utf8), to: descriptors[1])
            let overflowWasSelected = await Self.waitUntil {
                let snapshot = await transport.ingressSnapshot()
                return snapshot.terminalCause == .receiveBufferOverflow
            }
            XCTAssertTrue(overflowWasSelected)

            await transport.disconnect()

            var iterator = stream.makeAsyncIterator()
            let acceptedFrame = try await iterator.next()
            XCTAssertEqual(acceptedFrame, Data("accepted".utf8))
            do {
                _ = try await iterator.next()
                XCTFail("Expected the selected overflow cause to win the teardown race")
            } catch let error as MCPReceiveBufferOverflowError {
                XCTAssertEqual(error.capacity, 1)
                XCTAssertEqual(error.highWaterMark, 1)
            } catch {
                XCTFail("Unexpected terminal error: \(error)")
            }

            let peerSawEOF = await Self.waitUntil { Self.peerObservedEOF(on: descriptors[1]) }
            XCTAssertTrue(peerSawEOF)
            let cleanupCompleted = await Self.waitUntil {
                let cleanup = await transport.debugCleanupSnapshot()
                return cleanup.pendingReaderCancellationCount == 0
                    && cleanup.earlyReaderCancellationCount == 0
                    && !cleanup.readerIsRetained
                    && cleanup.finalizationCount == 1
                    && cleanup.descriptorCloseCount == 1
            }
            XCTAssertTrue(cleanupCompleted)
        #else
            throw XCTSkip("Overflow teardown race seam requires a DEBUG build")
        #endif
    }

    func testOverflowIsConnectionLocalAndPeerContinuesNormally() async throws {
        let firstDescriptors = try Self.makeSocketPair()
        let secondDescriptors = try Self.makeSocketPair()
        defer {
            Self.closeIfOpen(firstDescriptors[1])
            Self.closeIfOpen(secondDescriptors[1])
        }

        let firstTransport = try UnixSocketMCPTransport(
            connectedFD: firstDescriptors[0],
            receiveBufferCapacity: 1
        )
        let secondTransport = try UnixSocketMCPTransport(
            connectedFD: secondDescriptors[0],
            receiveBufferCapacity: 1
        )
        try await firstTransport.connect()
        try await secondTransport.connect()
        let firstStream = await firstTransport.receive()
        let secondStream = await secondTransport.receive()

        try Self.writeAll(Data("a-1\na-2\na-3\n".utf8), to: firstDescriptors[1])
        let firstDidOverflow = await Self.waitUntil {
            let snapshot = await firstTransport.ingressSnapshot()
            return snapshot.terminalCause == .receiveBufferOverflow
        }
        XCTAssertTrue(firstDidOverflow)

        try Self.writeAll(Data("b-1\n".utf8), to: secondDescriptors[1])
        var secondIterator = secondStream.makeAsyncIterator()
        let peerFrame = try await secondIterator.next()
        XCTAssertEqual(peerFrame, Data("b-1".utf8))
        let secondSnapshot = await secondTransport.ingressSnapshot()
        XCTAssertEqual(secondSnapshot.acceptedFrameCount, 1)
        XCTAssertFalse(secondSnapshot.isTerminal)
        XCTAssertNil(secondSnapshot.terminalCause)

        var firstIterator = firstStream.makeAsyncIterator()
        let acceptedFirstFrame = try await firstIterator.next()
        XCTAssertEqual(acceptedFirstFrame, Data("a-1".utf8))
        do {
            _ = try await firstIterator.next()
            XCTFail("Expected the saturated connection to terminate")
        } catch is MCPReceiveBufferOverflowError {
        } catch {
            XCTFail("Unexpected saturated connection error: \(error)")
        }

        let firstPeerSawEOF = await Self.waitUntil { Self.peerObservedEOF(on: firstDescriptors[1]) }
        XCTAssertTrue(firstPeerSawEOF)
        #if DEBUG
            let firstCleanupCompleted = await Self.waitUntil {
                let cleanup = await firstTransport.debugCleanupSnapshot()
                return cleanup.pendingReaderCancellationCount == 0
                    && cleanup.earlyReaderCancellationCount == 0
                    && !cleanup.readerIsRetained
                    && cleanup.finalizationCount == 1
                    && cleanup.descriptorCloseCount == 1
            }
            XCTAssertTrue(firstCleanupCompleted)
            let secondCleanupBeforeDisconnect = await secondTransport.debugCleanupSnapshot()
            XCTAssertTrue(secondCleanupBeforeDisconnect.hasActiveReader)
            XCTAssertEqual(secondCleanupBeforeDisconnect.descriptorCloseCount, 0)
        #endif
        XCTAssertFalse(Self.peerObservedEOF(on: secondDescriptors[1]))
        await firstTransport.disconnect()
        await secondTransport.disconnect()
        let secondPeerSawEOF = await Self.waitUntil { Self.peerObservedEOF(on: secondDescriptors[1]) }
        XCTAssertTrue(secondPeerSawEOF)
    }

    private static func makeSocketPair() throws -> [Int32] {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return descriptors
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress, buffer.count)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard written > 0 else {
                throw POSIXError(.EIO)
            }
            remaining = remaining.dropFirst(written)
        }
    }

    private static func peerObservedEOF(on fd: Int32) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
        guard poll(&descriptor, 1, 0) > 0 else { return false }
        var byte: UInt8 = 0
        let result = Darwin.read(fd, &byte, 1)
        return result == 0
    }

    private static func closeIfOpen(_ fd: Int32) {
        guard fd >= 0 else { return }
        Darwin.close(fd)
    }

    private static func waitUntil(
        timeout: TimeInterval = 2,
        pollIntervalNanoseconds: UInt64 = 5_000_000,
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return await condition()
    }
}
