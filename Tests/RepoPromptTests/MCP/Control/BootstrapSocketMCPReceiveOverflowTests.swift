import Darwin
import Foundation
@testable import RepoPromptMCP
import RepoPromptShared
import XCTest

final class BootstrapSocketMCPReceiveOverflowTests: XCTestCase {
    func testDroppedYieldFailsClosedAfterDeliveringBufferedFrame() async throws {
        let descriptors = try Self.makeSocketPair()
        defer { Self.closeIfOpen(descriptors[1]) }

        let transport = try BootstrapSocketMCPTransport(
            connectedFD: descriptors[0],
            receiveBufferCapacity: 1
        )
        try await transport.connect()
        let stream = await transport.receive()

        try Self.writeAll(Data("first\nsecond\nthird\n".utf8), to: descriptors[1])
        let finished = await Self.waitUntil {
            await transport.debugIsStreamFinished()
        }
        XCTAssertTrue(finished)

        var iterator = stream.makeAsyncIterator()
        let firstFrame = try await iterator.next()
        XCTAssertEqual(firstFrame, Data("first".utf8))
        do {
            _ = try await iterator.next()
            XCTFail("Expected receive overflow to terminate the stream")
        } catch {
            XCTAssertEqual(
                error as? BootstrapSocketMCPReceiveBufferOverflowError,
                BootstrapSocketMCPReceiveBufferOverflowError(capacity: 1)
            )
        }
    }

    func testOverflowThenImmediatePeerCloseStillFailsWithOverflow() async throws {
        // If peer EOF teardown races the unstructured overflow Task and wins,
        // the stream must still terminate with the overflow error (cause recorded
        // synchronously at yield-drop), not a clean finish.
        var descriptors = try Self.makeSocketPair()
        defer { Self.closeIfOpen(descriptors[1]) }

        let transport = try BootstrapSocketMCPTransport(
            connectedFD: descriptors[0],
            receiveBufferCapacity: 1
        )
        try await transport.connect()
        let stream = await transport.receive()

        try Self.writeAll(Data("first\nsecond\nthird\n".utf8), to: descriptors[1])
        // Close the peer immediately so EOF/error teardown races the overflow path.
        Self.closeIfOpen(descriptors[1])
        descriptors[1] = -1

        let finished = await Self.waitUntil {
            await transport.debugIsStreamFinished()
        }
        XCTAssertTrue(finished)

        var iterator = stream.makeAsyncIterator()
        let firstFrame = try await iterator.next()
        XCTAssertEqual(firstFrame, Data("first".utf8))
        do {
            _ = try await iterator.next()
            XCTFail("Expected overflow to remain the terminal cause after peer close")
        } catch {
            XCTAssertEqual(
                error as? BootstrapSocketMCPReceiveBufferOverflowError,
                BootstrapSocketMCPReceiveBufferOverflowError(capacity: 1)
            )
        }
    }

    func testOversizedFrameFailsClosedWithoutYieldingFrame() async throws {
        let descriptors = try Self.makeSocketPair()
        defer { Self.closeIfOpen(descriptors[1]) }

        let transport = try BootstrapSocketMCPTransport(
            connectedFD: descriptors[0],
            maximumFrameByteCount: 4
        )
        try await transport.connect()
        let stream = await transport.receive()

        try Self.writeAll(Data("12345\n".utf8), to: descriptors[1])
        let finished = await Self.waitUntil {
            await transport.debugIsStreamFinished()
        }
        XCTAssertTrue(finished)

        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Expected oversized frame to terminate the stream")
        } catch {
            XCTAssertEqual(
                error as? MCPNewlineFrameTooLargeError,
                MCPNewlineFrameTooLargeError(maximumByteCount: 4, accumulatedByteCount: 5)
            )
        }
    }

    private static func makeSocketPair() throws -> [Int32] {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return descriptors
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
    }

    private static func closeIfOpen(_ fd: Int32) {
        guard fd >= 0 else { return }
        Darwin.close(fd)
    }

    private static func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}
