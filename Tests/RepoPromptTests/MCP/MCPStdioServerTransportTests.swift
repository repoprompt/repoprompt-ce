import Darwin
import Foundation
@testable import RepoPromptMCP
import XCTest

final class MCPStdioServerTransportTests: XCTestCase {
    func testCompleteFramesAreDeliveredExactlyOnceInOrderBeforeCleanEOF() async throws {
        var inputDescriptors = try makePipe()
        defer {
            closeDescriptor(&inputDescriptors[0])
            closeDescriptor(&inputDescriptors[1])
        }
        var outputDescriptors = try makePipe()
        defer {
            closeDescriptor(&outputDescriptors[0])
            closeDescriptor(&outputDescriptors[1])
        }

        let transport = MCPStdioServerTransport(
            stdinFD: inputDescriptors[0],
            stdoutFD: outputDescriptors[1],
            parentPIDProvider: { 42 }
        )
        try await transport.connect()
        let stream = await transport.receive()
        async let terminal = transport.waitUntilTerminal()

        let expectedFrames = [
            Data(#"{"jsonrpc":"2.0","id":1}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":2}"#.utf8)
        ]
        var wireBytes = Data()
        for frame in expectedFrames {
            wireBytes.append(frame)
            wireBytes.append(0x0A)
        }
        writeExactly(wireBytes, to: inputDescriptors[1])
        closeDescriptor(&inputDescriptors[1])

        var receivedFrames: [Data] = []
        for try await frame in stream {
            receivedFrames.append(frame)
        }

        let observedTerminal = await terminal
        XCTAssertEqual(receivedFrames, expectedFrames)
        XCTAssertEqual(observedTerminal, .stdinEOF)
        await transport.disconnect()
    }

    func testEOFWithIncompleteFrameReportsExactTruncatedByteCount() async throws {
        var inputDescriptors = try makePipe()
        defer {
            closeDescriptor(&inputDescriptors[0])
            closeDescriptor(&inputDescriptors[1])
        }
        var outputDescriptors = try makePipe()
        defer {
            closeDescriptor(&outputDescriptors[0])
            closeDescriptor(&outputDescriptors[1])
        }

        let transport = MCPStdioServerTransport(
            stdinFD: inputDescriptors[0],
            stdoutFD: outputDescriptors[1],
            parentPIDProvider: { 42 }
        )
        try await transport.connect()
        let stream = await transport.receive()
        async let terminal = transport.waitUntilTerminal()

        let incompleteFrame = Data(#"{"jsonrpc":"2.0""#.utf8)
        writeExactly(incompleteFrame, to: inputDescriptors[1])
        closeDescriptor(&inputDescriptors[1])

        var receivedFrames: [Data] = []
        var streamError: Error?
        do {
            for try await frame in stream {
                receivedFrames.append(frame)
            }
        } catch {
            streamError = error
        }

        let expectedTerminal = MCPStdioServerTransport.TerminalError.stdinTruncatedFrame(
            bytes: incompleteFrame.count
        )
        let observedTerminal = await terminal
        XCTAssertTrue(receivedFrames.isEmpty)
        XCTAssertEqual(streamError as? MCPStdioServerTransport.TerminalError, expectedTerminal)
        XCTAssertEqual(observedTerminal, expectedTerminal)
        await transport.disconnect()
    }

    private func makePipe() throws -> [Int32] {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return descriptors
    }

    private func writeExactly(
        _ data: Data,
        to descriptor: Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let written = data.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        XCTAssertEqual(written, data.count, file: file, line: line)
    }

    private func closeDescriptor(
        _ descriptor: inout Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard descriptor >= 0 else { return }
        XCTAssertEqual(Darwin.close(descriptor), 0, file: file, line: line)
        descriptor = -1
    }
}
