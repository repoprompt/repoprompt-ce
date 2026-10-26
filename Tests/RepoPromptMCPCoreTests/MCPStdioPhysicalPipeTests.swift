import Darwin
import Foundation
@testable import RepoPromptMCPCore
import XCTest

final class MCPStdioPhysicalPipeTests: XCTestCase {
    func testPhysicalEAGAINPreservesFrameOwnershipUntilPipeIsWritable() async throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        defer { descriptors.forEach { _ = close($0) } }
        let physical = MCPStdioFileDescriptorOutputSink(descriptor: descriptors[1], pollIntervalMilliseconds: 1)
        try physical.prepare()
        let filler = Data(repeating: 0x58, count: 4096)
        var filled = 0
        var encounteredEAGAIN = false
        // A finite resource ceiling, not a retry/deadline around the race.
        while filled < 1024 * 1024 {
            let result = filler.withUnsafeBytes { physical.write($0) }
            switch result {
            case let .wrote(count): filled += count
            case .wouldBlock: encounteredEAGAIN = true
            default: throw POSIXError(.EIO)
            }
            if encounteredEAGAIN { break }
        }
        XCTAssertTrue(encounteredEAGAIN, "The real nonblocking descriptor must reach EAGAIN")
        guard encounteredEAGAIN, filled >= 8 else { throw POSIXError(.ENOBUFS) }
        XCTAssertEqual(try readExactly(8, from: descriptors[0]), Data(repeating: 0x58, count: 8))

        let barrier = PhysicalStdioBarrier()
        let sink = PhysicalPrefixStdioSink(physical: physical, barrier: barrier)
        let transport = MCPStdioServerTransport(outputSink: sink, writeGateObserver: { event in
            if case .enqueued = event { Task { await barrier.recordQueued() } }
        })
        let first = Data(#"{"jsonrpc":"2.0","id":7,"result":{}}"#.utf8)
        let second = Data(#"{"jsonrpc":"2.0","id":"7","result":{}}"#.utf8)
        let sendA = Task { try await transport.send(first) }
        await barrier.waitUntilBlocked()
        let sendB = Task { try await transport.send(second) }
        await barrier.waitUntilQueued()

        // The pipe is physically full again: all remaining filler and exactly A's prefix.
        let parkedBytes = try readExactly(filled, from: descriptors[0])
        XCTAssertEqual(parkedBytes.prefix(filled - 8), Data(repeating: 0x58, count: filled - 8))
        XCTAssertEqual(parkedBytes.suffix(8), first.prefix(8))
        await barrier.release()
        try await sendA.value
        try await sendB.value
        let remainder = try readExactly(first.count + second.count + 2 - 8, from: descriptors[0])
        let wire = Data(parkedBytes.suffix(8)) + remainder
        XCTAssertEqual(wire, first + Data([10]) + second + Data([10]))
        let lines = wire.split(separator: 10)
        XCTAssertEqual(lines.count, 2)
        let decoded = try lines.map { try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        XCTAssertEqual(decoded[0]?["id"] as? Int, 7)
        XCTAssertEqual(decoded[1]?["id"] as? String, "7")
        await transport.disconnect()
    }

    private func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        try bytes.withUnsafeMutableBytes { buffer in
            while offset < count {
                let result = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
                guard result > 0 else { throw POSIXError(.EIO) }
                offset += result
            }
        }
        return Data(bytes)
    }
}

/// Every write goes to the real descriptor. Only the first syscall's size and
/// the readiness suspension are controlled; no synthetic EAGAIN is returned.
private final class PhysicalPrefixStdioSink: MCPStdioOutputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var isFirstWrite = true
    private let physical: MCPStdioFileDescriptorOutputSink
    private let barrier: PhysicalStdioBarrier

    init(physical: MCPStdioFileDescriptorOutputSink, barrier: PhysicalStdioBarrier) {
        self.physical = physical
        self.barrier = barrier
    }

    func prepare() throws {
        try physical.prepare()
    }

    func write(_ bytes: UnsafeRawBufferPointer) -> MCPStdioWriteResult {
        lock.lock()
        let first = isFirstWrite
        isFirstWrite = false
        lock.unlock()
        return physical.write(first ? UnsafeRawBufferPointer(rebasing: bytes.prefix(8)) : bytes)
    }

    func awaitWritable() async -> MCPStdioWritableResult {
        await barrier.park()
        return await physical.awaitWritable()
    }
}

private actor PhysicalStdioBarrier {
    private var blocked = false
    private var queued = false
    private var released = false
    private var parkWaiter: CheckedContinuation<Void, Never>?
    private var blockedWaiter: CheckedContinuation<Void, Never>?
    private var queuedWaiter: CheckedContinuation<Void, Never>?

    func park() async {
        blocked = true
        blockedWaiter?.resume()
        blockedWaiter = nil
        if released { return }
        await withCheckedContinuation { parkWaiter = $0 }
    }

    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { blockedWaiter = $0 }
    }

    func recordQueued() {
        queued = true
        queuedWaiter?.resume()
        queuedWaiter = nil
    }

    func waitUntilQueued() async {
        if queued { return }
        await withCheckedContinuation { queuedWaiter = $0 }
    }

    func release() {
        released = true
        parkWaiter?.resume()
        parkWaiter = nil
    }
}
