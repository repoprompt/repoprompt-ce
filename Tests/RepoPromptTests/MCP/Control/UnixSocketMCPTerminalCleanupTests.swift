import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class UnixSocketMCPTerminalCleanupTests: XCTestCase {
    func testCleanPeerEOFPreservesFirstCloseCause() async throws {
        let descriptors = try Self.makeSocketPair()
        defer { Self.closeIfOpen(descriptors[1]) }

        let transport = try UnixSocketMCPTransport(connectedFD: descriptors[0])
        try await transport.connect()
        let closeStream = await transport.closed()

        XCTAssertEqual(Darwin.shutdown(descriptors[1], SHUT_WR), 0)

        var iterator = closeStream.makeAsyncIterator()
        let closeValue = await iterator.next()
        let close = try XCTUnwrap(closeValue)
        XCTAssertEqual(close.cause, .peerEOF)
        XCTAssertEqual(close.initiator, .peer)
        XCTAssertNil(close.errno)
        XCTAssertNil(close.errorDescription)
        let storedClose = await transport.closeSnapshot()
        XCTAssertEqual(storedClose, close)
    }

    func testIncompletePeerEOFPreservesProtocolCause() async throws {
        let descriptors = try Self.makeSocketPair()
        defer { Self.closeIfOpen(descriptors[1]) }

        let transport = try UnixSocketMCPTransport(connectedFD: descriptors[0])
        try await transport.connect()
        let closeStream = await transport.closed()

        try Self.writeAll(Data(#"{"jsonrpc":"2.0""#.utf8), to: descriptors[1])
        XCTAssertEqual(Darwin.shutdown(descriptors[1], SHUT_WR), 0)

        var iterator = closeStream.makeAsyncIterator()
        let closeValue = await iterator.next()
        let close = try XCTUnwrap(closeValue)
        XCTAssertEqual(close.cause, .incompleteEOF)
        XCTAssertEqual(close.initiator, .peer)
        XCTAssertTrue(close.errorDescription?.contains("incomplete frame data") == true)
        let storedClose = await transport.closeSnapshot()
        XCTAssertEqual(storedClose, close)
    }

    func testPeerCloseDuringWritePublishesPeerWriteHangup() async throws {
        #if DEBUG
            let descriptors = try Self.makeSocketPair()
            var peerFD = descriptors[1]
            defer { Self.closeIfOpen(peerFD) }

            let transport = try UnixSocketMCPTransport(connectedFD: descriptors[0])
            await transport.debugHoldReaderTerminalCallback()
            try await transport.connect()
            let closeStream = await transport.closed()

            Self.closeIfOpen(peerFD)
            peerFD = -1

            do {
                try await transport.send(Data("peer-close-write".utf8))
                XCTFail("Expected write to fail after the peer closed")
            } catch {
                // Expected: the close snapshot is the behavior under test.
            }

            var iterator = closeStream.makeAsyncIterator()
            let closeValue = await iterator.next()
            let close = try XCTUnwrap(closeValue)
            XCTAssertEqual(close.cause, .writeHangup)
            XCTAssertEqual(close.initiator, .peer)
            XCTAssertTrue(close.errno == EPIPE || close.errno == ECONNRESET)
            let storedClose = await transport.closeSnapshot()
            XCTAssertEqual(storedClose, close)

            await transport.debugReleaseReaderTerminalCallbacks()
        #else
            throw XCTSkip("Deterministic transport callback gates require a DEBUG build")
        #endif
    }

    func testCancellationCallbackBeforeTerminalTaskFinalizesExactlyOnce() async throws {
        #if DEBUG
            let descriptors = try Self.makeSocketPair()
            defer { Self.closeIfOpen(descriptors[1]) }

            let transport: UnixSocketMCPTransport? = try UnixSocketMCPTransport(connectedFD: descriptors[0])
            let connectedTransport = try XCTUnwrap(transport)
            await connectedTransport.debugHoldReaderTerminalCallback()
            try await connectedTransport.connect()
            let stream = await connectedTransport.receive()

            XCTAssertEqual(Darwin.shutdown(descriptors[1], SHUT_WR), 0)

            let cancellationArrivedFirst = await Self.waitUntil {
                let snapshot = await connectedTransport.debugCleanupSnapshot()
                return snapshot.cancellationCallbackCount == 1
                    && snapshot.earlyReaderCancellationCount == 1
                    && snapshot.hasActiveReader
                    && snapshot.terminalCallbackCount == 0
            }
            XCTAssertTrue(cancellationArrivedFirst)
            var snapshot = await connectedTransport.debugCleanupSnapshot()
            XCTAssertEqual(snapshot.descriptorCloseCount, 0)
            XCTAssertEqual(snapshot.finalizationCount, 0)
            XCTAssertTrue(snapshot.readerIsRetained)
            XCTAssertTrue(snapshot.socketIsOwned)
            XCTAssertFalse(Self.peerObservedEOF(on: descriptors[1]))

            await connectedTransport.debugReleaseReaderTerminalCallbacks()
            var iterator = stream.makeAsyncIterator()
            let terminalFrame = try await iterator.next()
            XCTAssertNil(terminalFrame)

            let cleanupCompleted = await Self.waitUntil {
                let snapshot = await connectedTransport.debugCleanupSnapshot()
                return !snapshot.hasActiveReader
                    && snapshot.pendingReaderCancellationCount == 0
                    && snapshot.earlyReaderCancellationCount == 0
                    && !snapshot.readerIsRetained
                    && snapshot.terminalCallbackCount == 1
                    && snapshot.finalizationCount == 1
                    && snapshot.descriptorCloseCount == 1
                    && !snapshot.socketIsOwned
            }
            XCTAssertTrue(cleanupCompleted)
            XCTAssertTrue(Self.peerObservedEOF(on: descriptors[1]))

            await connectedTransport.disconnect()
            await connectedTransport.disconnect()
            snapshot = await connectedTransport.debugCleanupSnapshot()
            XCTAssertEqual(snapshot.terminalCallbackCount, 1)
            XCTAssertEqual(snapshot.cancellationCallbackCount, 1)
            XCTAssertEqual(snapshot.finalizationCount, 1)
            XCTAssertEqual(snapshot.descriptorCloseCount, 1)
            XCTAssertEqual(snapshot.staleCancellationCount, 0)

        #else
            throw XCTSkip("Deterministic transport callback gates require a DEBUG build")
        #endif
    }

    func testTerminalTaskBeforeCancellationCallbackRetainsThenReleasesOwnership() async throws {
        #if DEBUG
            let descriptors = try Self.makeSocketPair()
            defer { Self.closeIfOpen(descriptors[1]) }

            let transport: UnixSocketMCPTransport? = try UnixSocketMCPTransport(connectedFD: descriptors[0])
            let connectedTransport = try XCTUnwrap(transport)
            await connectedTransport.debugHoldReaderCancellationCallback()
            try await connectedTransport.connect()
            let stream = await connectedTransport.receive()

            XCTAssertEqual(Darwin.shutdown(descriptors[1], SHUT_WR), 0)

            let terminalArrivedFirst = await Self.waitUntil {
                let snapshot = await connectedTransport.debugCleanupSnapshot()
                return snapshot.terminalCallbackCount == 1
                    && snapshot.pendingReaderCancellationCount == 1
                    && snapshot.cancellationCallbackCount == 0
                    && !snapshot.hasActiveReader
            }
            XCTAssertTrue(terminalArrivedFirst)
            var snapshot = await connectedTransport.debugCleanupSnapshot()
            XCTAssertEqual(snapshot.earlyReaderCancellationCount, 0)
            XCTAssertEqual(snapshot.finalizationCount, 0)
            XCTAssertEqual(snapshot.descriptorCloseCount, 0)
            XCTAssertTrue(snapshot.readerIsRetained)
            XCTAssertTrue(snapshot.socketIsOwned)

            var iterator = stream.makeAsyncIterator()
            let terminalFrame = try await iterator.next()
            XCTAssertNil(terminalFrame)

            await connectedTransport.debugReleaseReaderCancellationCallbacks()
            let cleanupCompleted = await Self.waitUntil {
                let snapshot = await connectedTransport.debugCleanupSnapshot()
                return snapshot.pendingReaderCancellationCount == 0
                    && snapshot.earlyReaderCancellationCount == 0
                    && !snapshot.readerIsRetained
                    && snapshot.cancellationCallbackCount == 1
                    && snapshot.finalizationCount == 1
                    && snapshot.descriptorCloseCount == 1
                    && !snapshot.socketIsOwned
            }
            XCTAssertTrue(cleanupCompleted)
            XCTAssertTrue(Self.peerObservedEOF(on: descriptors[1]))

            await connectedTransport.disconnect()
            snapshot = await connectedTransport.debugCleanupSnapshot()
            XCTAssertEqual(snapshot.terminalCallbackCount, 1)
            XCTAssertEqual(snapshot.cancellationCallbackCount, 1)
            XCTAssertEqual(snapshot.finalizationCount, 1)
            XCTAssertEqual(snapshot.descriptorCloseCount, 1)
            XCTAssertEqual(snapshot.staleCancellationCount, 0)

        #else
            throw XCTSkip("Deterministic transport callback gates require a DEBUG build")
        #endif
    }

    func testTerminalCleanupReleasesTransportRetainer() async throws {
        #if DEBUG
            let descriptors = try Self.makeSocketPair()
            defer { Self.closeIfOpen(descriptors[1]) }
            weak var weakTransport: UnixSocketMCPTransport?

            do {
                let transport = try UnixSocketMCPTransport(connectedFD: descriptors[0])
                weakTransport = transport
                await transport.debugHoldReaderCancellationCallback()
                try await transport.connect()
                XCTAssertEqual(Darwin.shutdown(descriptors[1], SHUT_WR), 0)

                let pending = await Self.waitUntil {
                    let snapshot = await transport.debugCleanupSnapshot()
                    return snapshot.pendingReaderCancellationCount == 1
                        && snapshot.readerIsRetained
                        && snapshot.terminalCallbackCount == 1
                }
                XCTAssertTrue(pending)
                await transport.debugReleaseReaderCancellationCallbacks()
                let cleaned = await Self.waitUntil {
                    let snapshot = await transport.debugCleanupSnapshot()
                    return snapshot.pendingReaderCancellationCount == 0
                        && !snapshot.readerIsRetained
                        && snapshot.finalizationCount == 1
                }
                XCTAssertTrue(cleaned)
            }

            let transportReleased = await Self.waitUntil { weakTransport == nil }
            XCTAssertTrue(transportReleased)
        #else
            throw XCTSkip("Deterministic transport callback gates require a DEBUG build")
        #endif
    }

    func testExplicitStopFencesHeldTerminalCallback() async throws {
        #if DEBUG
            let descriptors = try Self.makeSocketPair()
            defer { Self.closeIfOpen(descriptors[1]) }

            let transport = try UnixSocketMCPTransport(connectedFD: descriptors[0])
            await transport.debugHoldReaderTerminalCallback()
            try await transport.connect()
            XCTAssertEqual(Darwin.shutdown(descriptors[1], SHUT_WR), 0)

            let cancellationArrived = await Self.waitUntil {
                let snapshot = await transport.debugCleanupSnapshot()
                return snapshot.earlyReaderCancellationCount == 1
                    && snapshot.terminalCallbackCount == 0
            }
            XCTAssertTrue(cancellationArrived)

            await transport.disconnect()
            let stopped = await Self.waitUntil {
                let snapshot = await transport.debugCleanupSnapshot()
                return snapshot.finalizationCount == 1
                    && snapshot.descriptorCloseCount == 1
                    && !snapshot.readerIsRetained
            }
            XCTAssertTrue(stopped)

            await transport.debugReleaseReaderTerminalCallbacks()
            let staleTerminalWasFenced = await Self.waitUntil {
                let snapshot = await transport.debugCleanupSnapshot()
                return snapshot.terminalCallbackCount == 1
                    && snapshot.staleTerminalCount == 1
            }
            XCTAssertTrue(staleTerminalWasFenced)
            let snapshot = await transport.debugCleanupSnapshot()
            XCTAssertEqual(snapshot.cancellationCallbackCount, 1)
            XCTAssertEqual(snapshot.finalizationCount, 1)
            XCTAssertEqual(snapshot.descriptorCloseCount, 1)
            XCTAssertFalse(snapshot.socketIsOwned)
        #else
            throw XCTSkip("Deterministic transport callback gates require a DEBUG build")
        #endif
    }

    func testHeldOldTerminalCallbackCannotCloseReplacementConnection() async throws {
        #if DEBUG
            let suffix = UUID().uuidString.prefix(8)
            let directoryURL = URL(fileURLWithPath: "/tmp/rpce-t-\(getpid())-\(suffix)", isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directoryURL) }
            let socketURL = directoryURL.appendingPathComponent("transport.sock")
            let listenerFD = try Self.makeUnixListener(at: socketURL)
            defer { Self.closeIfOpen(listenerFD) }

            let transport = UnixSocketMCPTransport(socketURL: socketURL)
            await transport.debugHoldReaderTerminalCallback()
            try await transport.connect()
            let firstPeerFD = Darwin.accept(listenerFD, nil, nil)
            XCTAssertGreaterThanOrEqual(firstPeerFD, 0)
            defer { Self.closeIfOpen(firstPeerFD) }

            XCTAssertEqual(Darwin.shutdown(firstPeerFD, SHUT_WR), 0)
            let oldCancellationArrived = await Self.waitUntil {
                let snapshot = await transport.debugCleanupSnapshot()
                return snapshot.earlyReaderCancellationCount == 1
                    && snapshot.terminalCallbackCount == 0
            }
            XCTAssertTrue(oldCancellationArrived)

            await transport.disconnect()
            try await transport.connect()
            let replacementPeerFD = Darwin.accept(listenerFD, nil, nil)
            XCTAssertGreaterThanOrEqual(replacementPeerFD, 0)
            defer { Self.closeIfOpen(replacementPeerFD) }
            let replacementStream = await transport.receive()
            var replacementIterator = replacementStream.makeAsyncIterator()
            var snapshot = await transport.debugCleanupSnapshot()
            XCTAssertTrue(snapshot.hasActiveReader)
            XCTAssertTrue(snapshot.socketIsOwned)
            XCTAssertEqual(snapshot.descriptorCloseCount, 1)
            var replacementIngress = await transport.ingressSnapshot()
            XCTAssertFalse(replacementIngress.isTerminal)
            XCTAssertEqual(replacementIngress.acceptedFrameCount, 0)

            await transport.debugReleaseReaderTerminalCallbacks()
            let staleTerminalWasFenced = await Self.waitUntil {
                let snapshot = await transport.debugCleanupSnapshot()
                return snapshot.terminalCallbackCount == 1
                    && snapshot.staleTerminalCount == 1
            }
            XCTAssertTrue(staleTerminalWasFenced)
            snapshot = await transport.debugCleanupSnapshot()
            XCTAssertTrue(snapshot.hasActiveReader)
            XCTAssertTrue(snapshot.socketIsOwned)
            XCTAssertEqual(snapshot.descriptorCloseCount, 1)
            replacementIngress = await transport.ingressSnapshot()
            XCTAssertFalse(replacementIngress.isTerminal)

            try await transport.send(Data("replacement-probe".utf8))
            let replacementFrame = try Self.readLine(from: replacementPeerFD)
            XCTAssertEqual(replacementFrame, Data("replacement-probe".utf8))

            try Self.writeAll(Data("replacement-inbound\n".utf8), to: replacementPeerFD)
            let replacementInboundFrame = try await replacementIterator.next()
            XCTAssertEqual(replacementInboundFrame, Data("replacement-inbound".utf8))
            replacementIngress = await transport.ingressSnapshot()
            XCTAssertEqual(replacementIngress.acceptedFrameCount, 1)
            XCTAssertFalse(replacementIngress.isTerminal)

            await transport.disconnect()
            let replacementCleaned = await Self.waitUntil {
                let snapshot = await transport.debugCleanupSnapshot()
                return snapshot.finalizationCount == 2
                    && snapshot.descriptorCloseCount == 2
                    && !snapshot.readerIsRetained
            }
            XCTAssertTrue(replacementCleaned)
        #else
            throw XCTSkip("Deterministic transport callback gates require a DEBUG build")
        #endif
    }

    func testExplicitStopAndHardErrorUseSameSingleFinalizer() async throws {
        #if DEBUG
            try await Self.assertControlledCleanup { transport, _ in
                await transport.debugHoldReaderCancellationCallback()
                await transport.disconnect()
                let pending = await Self.waitUntil {
                    let snapshot = await transport.debugCleanupSnapshot()
                    return snapshot.pendingReaderCancellationCount == 1
                        && snapshot.descriptorCloseCount == 0
                }
                XCTAssertTrue(pending)
                await transport.debugReleaseReaderCancellationCallbacks()
            }

            try await Self.assertControlledCleanup { transport, stream in
                await transport.debugHoldReaderCancellationCallback()
                await transport.debugTriggerReadErrorForCleanupTest()
                var iterator = stream.makeAsyncIterator()
                do {
                    _ = try await iterator.next()
                    XCTFail("Expected the forced read error to terminate the stream")
                } catch is POSIXError {
                } catch {
                    XCTFail("Unexpected forced read terminal error: \(error)")
                }
                let pending = await Self.waitUntil {
                    let snapshot = await transport.debugCleanupSnapshot()
                    return snapshot.pendingReaderCancellationCount == 1
                        && snapshot.terminalCallbackCount == 1 + snapshot.staleTerminalCount
                        && snapshot.descriptorCloseCount == 0
                }
                XCTAssertTrue(pending)
                await transport.debugReleaseReaderCancellationCallbacks()
            }
        #else
            throw XCTSkip("Deterministic transport callback gates require a DEBUG build")
        #endif
    }

    func testTerminalCleanupIsConnectionLocalWhilePeerContinues() async throws {
        #if DEBUG
            let firstDescriptors = try Self.makeSocketPair()
            let secondDescriptors = try Self.makeSocketPair()
            defer {
                Self.closeIfOpen(firstDescriptors[1])
                Self.closeIfOpen(secondDescriptors[1])
            }

            let firstTransport = try UnixSocketMCPTransport(connectedFD: firstDescriptors[0])
            let secondTransport = try UnixSocketMCPTransport(connectedFD: secondDescriptors[0])
            await firstTransport.debugHoldReaderTerminalCallback()
            try await firstTransport.connect()
            try await secondTransport.connect()
            let secondStream = await secondTransport.receive()

            XCTAssertEqual(Darwin.shutdown(firstDescriptors[1], SHUT_WR), 0)
            let firstCancellationArrived = await Self.waitUntil {
                let snapshot = await firstTransport.debugCleanupSnapshot()
                return snapshot.earlyReaderCancellationCount == 1
                    && snapshot.terminalCallbackCount == 0
            }
            XCTAssertTrue(firstCancellationArrived)

            try Self.writeAll(Data("peer-frame\n".utf8), to: secondDescriptors[1])
            var secondIterator = secondStream.makeAsyncIterator()
            let firstPeerFrame = try await secondIterator.next()
            XCTAssertEqual(firstPeerFrame, Data("peer-frame".utf8))
            let secondBeforeCleanup = await secondTransport.debugCleanupSnapshot()
            XCTAssertTrue(secondBeforeCleanup.hasActiveReader)
            XCTAssertEqual(secondBeforeCleanup.descriptorCloseCount, 0)
            XCTAssertFalse(Self.peerObservedEOF(on: secondDescriptors[1]))

            await firstTransport.debugReleaseReaderTerminalCallbacks()
            let firstCleaned = await Self.waitUntil {
                let snapshot = await firstTransport.debugCleanupSnapshot()
                return snapshot.finalizationCount == 1
                    && snapshot.descriptorCloseCount == 1
                    && !snapshot.readerIsRetained
            }
            XCTAssertTrue(firstCleaned)
            XCTAssertTrue(Self.peerObservedEOF(on: firstDescriptors[1]))
            XCTAssertFalse(Self.peerObservedEOF(on: secondDescriptors[1]))

            try Self.writeAll(Data("peer-frame-2\n".utf8), to: secondDescriptors[1])
            let secondPeerFrame = try await secondIterator.next()
            XCTAssertEqual(secondPeerFrame, Data("peer-frame-2".utf8))

            await firstTransport.disconnect()
            await secondTransport.disconnect()
            let secondCleaned = await Self.waitUntil {
                let snapshot = await secondTransport.debugCleanupSnapshot()
                return snapshot.finalizationCount == 1
                    && snapshot.descriptorCloseCount == 1
                    && !snapshot.readerIsRetained
            }
            XCTAssertTrue(secondCleaned)
        #else
            throw XCTSkip("Deterministic transport callback gates require a DEBUG build")
        #endif
    }

    #if DEBUG
        private static func assertControlledCleanup(
            trigger: (UnixSocketMCPTransport, AsyncThrowingStream<Data, Swift.Error>) async throws -> Void
        ) async throws {
            let descriptors = try makeSocketPair()
            defer { closeIfOpen(descriptors[1]) }

            let transport = try UnixSocketMCPTransport(connectedFD: descriptors[0])
            try await transport.connect()
            let stream = await transport.receive()
            try await trigger(transport, stream)

            let cleanupCompleted = await waitUntil {
                let snapshot = await transport.debugCleanupSnapshot()
                return !snapshot.hasActiveReader
                    && snapshot.pendingReaderCancellationCount == 0
                    && snapshot.earlyReaderCancellationCount == 0
                    && !snapshot.readerIsRetained
                    && snapshot.cancellationCallbackCount == 1
                    && snapshot.finalizationCount == 1
                    && snapshot.descriptorCloseCount == 1
                    && !snapshot.socketIsOwned
            }
            XCTAssertTrue(cleanupCompleted)
            XCTAssertTrue(peerObservedEOF(on: descriptors[1]))

            await transport.disconnect()
            let snapshot = await transport.debugCleanupSnapshot()
            XCTAssertEqual(snapshot.cancellationCallbackCount, 1)
            XCTAssertEqual(snapshot.finalizationCount, 1)
            XCTAssertEqual(snapshot.descriptorCloseCount, 1)
            XCTAssertEqual(snapshot.staleCancellationCount, 0)
        }
    #endif

    private static func makeSocketPair() throws -> [Int32] {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return descriptors
    }

    private static func makeUnixListener(at socketURL: URL) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            var address = try unixSocketAddress(for: socketURL)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0, Darwin.listen(fd, 4) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return fd
        } catch {
            closeIfOpen(fd)
            throw error
        }
    }

    private static func unixSocketAddress(for socketURL: URL) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketURL.path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = byte
                }
            }
        }
        return address
    }

    private static func readLine(from fd: Int32, timeout: TimeInterval = 2) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let pollResult = Darwin.poll(&descriptor, 1, 50)
            if pollResult < 0, errno == EINTR { continue }
            guard pollResult > 0 else { continue }

            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw POSIXError(.EIO) }
            if byte == UInt8(ascii: "\n") {
                return data
            }
            data.append(byte)
        }
        throw POSIXError(.ETIMEDOUT)
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
            guard written > 0 else { throw POSIXError(.EIO) }
            remaining = remaining.dropFirst(written)
        }
    }

    private static func peerObservedEOF(on fd: Int32) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
        guard poll(&descriptor, 1, 0) > 0 else { return false }
        var byte: UInt8 = 0
        return Darwin.read(fd, &byte, 1) == 0
    }

    private static func isClosed(_ fd: Int32) -> Bool {
        // Only use while the test still owns the descriptor; closed descriptor numbers can be reused.
        errno = 0
        return fcntl(fd, F_GETFD) == -1 && errno == EBADF
    }

    private static func closeIfOpen(_ fd: Int32) {
        guard fd >= 0, !isClosed(fd) else { return }
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
