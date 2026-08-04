import Darwin
import Foundation
import RepoPromptDomainRuntime
@testable import RepoPromptMCP
import XCTest

final class DirectHeadlessStdioTransportTests: XCTestCase {
    func testCleanEOFAndTruncatedEOFHaveDistinctTerminalProvenance() async throws {
        var input = try PipeDescriptors.make()
        var output = try PipeDescriptors.make()
        let eofTransport = MCPStdioServerTransport(
            stdinFD: input.read,
            stdoutFD: output.write,
            pollIntervalMilliseconds: 5,
            writeStallTimeout: .milliseconds(100)
        )
        try await eofTransport.connect()
        input.closeWrite()
        let eofTerminal = await eofTransport.waitUntilTerminal()
        XCTAssertEqual(eofTerminal, .stdinEOF)
        await eofTransport.disconnect()
        input.closeRead()
        output.closeAll()

        input = try PipeDescriptors.make()
        output = try PipeDescriptors.make()
        let truncatedTransport = MCPStdioServerTransport(
            stdinFD: input.read,
            stdoutFD: output.write,
            pollIntervalMilliseconds: 5,
            writeStallTimeout: .milliseconds(100)
        )
        try await truncatedTransport.connect()
        let truncatedFrame = Data("{}".utf8)
        let writeCount = truncatedFrame.withUnsafeBytes {
            Darwin.write(input.write, $0.baseAddress, $0.count)
        }
        XCTAssertEqual(writeCount, 2)
        input.closeWrite()
        let truncatedTerminal = await truncatedTransport.waitUntilTerminal()
        XCTAssertEqual(truncatedTerminal, .stdinTruncatedFrame(bytes: 2))
        await truncatedTransport.disconnect()
        input.closeRead()
        output.closeAll()
    }

    func testParentProcessChangeAndReadFailureHaveExplicitProvenance() async throws {
        var input = try PipeDescriptors.make()
        var output = try PipeDescriptors.make()
        let parentPID = LockedPIDBox(100)
        let parentTransport = MCPStdioServerTransport(
            stdinFD: input.read,
            stdoutFD: output.write,
            pollIntervalMilliseconds: 5,
            writeStallTimeout: .milliseconds(100),
            parentPIDProvider: { parentPID.value }
        )
        try await parentTransport.connect()
        parentPID.value = 101
        let parentTerminal = await parentTransport.waitUntilTerminal()
        XCTAssertEqual(parentTerminal, .parentProcessChanged(initial: 100, current: 101))
        await parentTransport.disconnect()
        input.closeAll()
        output.closeAll()

        var failingInput = try PipeDescriptors.make()
        output = try PipeDescriptors.make()
        let readFailureTransport = MCPStdioServerTransport(
            stdinFD: failingInput.read,
            stdoutFD: output.write,
            pollIntervalMilliseconds: 5,
            writeStallTimeout: .milliseconds(100)
        )
        try await readFailureTransport.connect()
        failingInput.closeRead()
        let readFailureTerminal = await readFailureTransport.waitUntilTerminal()
        XCTAssertEqual(readFailureTerminal, .stdinRead(errno: EBADF))
        await readFailureTransport.disconnect()
        failingInput.closeWrite()
        output.closeAll()
    }

    func testOversizedInboundFrameTerminatesAtConfiguredBound() async throws {
        var input = try PipeDescriptors.make()
        var output = try PipeDescriptors.make()
        let transport = MCPStdioServerTransport(
            stdinFD: input.read,
            stdoutFD: output.write,
            pollIntervalMilliseconds: 5,
            writeStallTimeout: .milliseconds(100),
            maximumInboundFrameBytes: 8
        )
        try await transport.connect()
        let payload = Data(repeating: 0x61, count: 9)
        XCTAssertEqual(payload.withUnsafeBytes { Darwin.write(input.write, $0.baseAddress, $0.count) }, 9)
        let terminal = await transport.waitUntilTerminal()
        XCTAssertEqual(terminal, .stdinFrameTooLarge(bytes: 9, maximum: 8))
        await transport.disconnect()
        input.closeAll()
        output.closeAll()
    }

    func testInboundFrameQueueBackpressuresWithoutDroppingRequests() async throws {
        var input = try PipeDescriptors.make()
        var output = try PipeDescriptors.make()
        let tracker = MCPDomainResponseDeliveryTracker()
        let transport = MCPStdioServerTransport(
            stdinFD: input.read,
            stdoutFD: output.write,
            pollIntervalMilliseconds: 5,
            writeStallTimeout: .milliseconds(100),
            maximumInboundFrameBytes: 1024,
            maximumBufferedFrames: 2,
            deliveryTracker: tracker
        )
        try await transport.connect()
        let frames = (1 ... 3).map {
            Data("{\"jsonrpc\":\"2.0\",\"id\":\($0),\"method\":\"tools/list\"}\n".utf8)
        }
        for frame in frames {
            XCTAssertEqual(frame.withUnsafeBytes { Darwin.write(input.write, $0.baseAddress, $0.count) }, frame.count)
        }
        for _ in 0 ..< 100 where tracker.snapshot().pendingRequestCount < 2 {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 2)

        let stream = await transport.receive()
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        for _ in 0 ..< 100 where tracker.snapshot().pendingRequestCount < 3 {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 3)

        await transport.disconnect()
        input.closeAll()
        output.closeAll()
    }

    func testInboundFrameQueueBackpressureTerminatesAtConfiguredStallBound() async throws {
        var input = try PipeDescriptors.make()
        var output = try PipeDescriptors.make()
        let tracker = MCPDomainResponseDeliveryTracker()
        let transport = MCPStdioServerTransport(
            stdinFD: input.read,
            stdoutFD: output.write,
            pollIntervalMilliseconds: 5,
            readBackpressureStallTimeout: .milliseconds(25),
            writeStallTimeout: .milliseconds(100),
            maximumInboundFrameBytes: 1024,
            maximumBufferedFrames: 1,
            deliveryTracker: tracker
        )
        try await transport.connect()
        let frames = (1 ... 2).map {
            Data("{\"jsonrpc\":\"2.0\",\"id\":\($0),\"method\":\"tools/list\"}\n".utf8)
        }
        for frame in frames {
            XCTAssertEqual(frame.withUnsafeBytes { Darwin.write(input.write, $0.baseAddress, $0.count) }, frame.count)
        }

        let terminal = await transport.waitUntilTerminal()
        XCTAssertEqual(
            terminal,
            .stdinBackpressureStall(
                frameBytes: frames[1].count - 1,
                maximumBufferedFrames: 1
            )
        )
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 1)
        await transport.disconnect()
        input.closeAll()
        output.closeAll()
    }

    func testDisconnectAwaitsOwnedReaderAndRecordsCancellation() async throws {
        var input = try PipeDescriptors.make()
        var output = try PipeDescriptors.make()
        let transport = MCPStdioServerTransport(
            stdinFD: input.read,
            stdoutFD: output.write,
            pollIntervalMilliseconds: 5,
            writeStallTimeout: .milliseconds(100)
        )
        try await transport.connect()
        await transport.disconnect()
        let cancellationTerminal = await transport.waitUntilTerminal()
        XCTAssertEqual(cancellationTerminal, .cancelled)
        input.closeAll()
        output.closeAll()
    }

    func testBrokenPipeIsBoundedAndDeliveryIsRecordedOnlyAfterPhysicalWrite() async throws {
        let input = try PipeDescriptors.make()
        var output = try PipeDescriptors.make()
        let tracker = MCPDomainResponseDeliveryTracker()
        let transport = MCPStdioServerTransport(
            stdinFD: input.read,
            stdoutFD: output.write,
            pollIntervalMilliseconds: 5,
            writeStallTimeout: .milliseconds(100),
            deliveryTracker: tracker
        )
        try await transport.connect()

        let request = Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#.utf8)
        tracker.recordAcceptedClientFrame(request)
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 1)
        let response = Data(#"{"jsonrpc":"2.0","id":7,"result":{}}"#.utf8)
        try await transport.send(response)
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 0)
        var bytes = [UInt8](repeating: 0, count: response.count + 1)
        XCTAssertGreaterThan(Darwin.read(output.read, &bytes, bytes.count), 0)

        let undeliverableRequest = Data(#"{"jsonrpc":"2.0","id":8,"method":"tools/list"}"#.utf8)
        let undeliverableResponse = Data(#"{"jsonrpc":"2.0","id":8,"result":{}}"#.utf8)
        tracker.recordAcceptedClientFrame(undeliverableRequest)
        output.closeRead()
        do {
            try await transport.send(undeliverableResponse)
            XCTFail("Expected broken pipe")
        } catch let error as MCPStdioServerTransport.TerminalError {
            guard case .stdoutBrokenPipe = error else {
                return XCTFail("Unexpected terminal error: \(error)")
            }
        }
        let terminal = await transport.waitUntilTerminal()
        guard case .stdoutBrokenPipe = terminal else {
            return XCTFail("Expected broken-pipe terminal provenance")
        }
        XCTAssertEqual(tracker.snapshot().pendingRequestCount, 1)
        let drainStart = ContinuousClock().now
        let deliveryDrained = await transport.waitForDeliveryDrain(timeout: .milliseconds(50))
        XCTAssertFalse(deliveryDrained)
        XCTAssertLessThan(drainStart.duration(to: .now), .milliseconds(500))
        await transport.disconnect()
        XCTAssertTrue(tracker.snapshot().isTerminal)
        var mutableInput = input
        mutableInput.closeAll()
        output.closeWrite()
    }
}

private final class LockedPIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Int32

    init(_ value: Int32) {
        storedValue = value
    }

    var value: Int32 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private struct PipeDescriptors {
    var read: Int32
    var write: Int32

    static func make() throws -> Self {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Self(read: descriptors[0], write: descriptors[1])
    }

    mutating func closeRead() {
        guard read >= 0 else { return }
        Darwin.close(read)
        read = -1
    }

    mutating func closeWrite() {
        guard write >= 0 else { return }
        Darwin.close(write)
        write = -1
    }

    mutating func closeAll() {
        closeRead()
        closeWrite()
    }
}
