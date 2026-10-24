import Darwin
import Foundation
import RepoPromptDomainRuntime
@testable import RepoPromptMCPCore
import XCTest

final class MCPStdioServerTransportTests: XCTestCase {
    #if DEBUG
        func testPhysicallyDeliveredResponsesCannotAcquireDebtAfterReaderPublication() async throws {
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
            let tracker = MCPDomainResponseDeliveryTracker()
            let gate = StdioAccountingPublicationGate()
            let transport = MCPStdioServerTransport(
                stdinFD: inputDescriptors[0],
                stdoutFD: outputDescriptors[1],
                parentPIDProvider: { 42 },
                deliveryTracker: tracker
            )
            await transport.debugSetAfterClientFramePublicationForTesting {
                await gate.hold()
            }
            try await transport.connect()
            do {
                let requests = Data(#"[{"jsonrpc":"2.0","id":7,"method":"ping"},{"jsonrpc":"2.0","id":"7","method":"ping"}]"#.utf8)
                writeExactly(requests + Data([10]), to: inputDescriptors[1])
                await gate.waitUntilHeld()
                var iterator = await transport.receive().makeAsyncIterator()
                let published = try await iterator.next()
                XCTAssertEqual(published, requests)
                XCTAssertEqual(tracker.snapshot().pendingRequestCount, 2, "Both exact typed debts must exist when the request batch is visible")

                let responses = Data(#"[{"jsonrpc":"2.0","id":7,"result":{}},{"jsonrpc":"2.0","id":"7","result":{}}]"#.utf8)
                try await transport.send(responses)
                let expectedWire = responses + Data([10])
                var wire = Data()
                var bytes = [UInt8](repeating: 0, count: expectedWire.count)
                while wire.count < expectedWire.count {
                    let count = Darwin.read(outputDescriptors[0], &bytes, expectedWire.count - wire.count)
                    guard count > 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    wire.append(bytes, count: count)
                }
                XCTAssertEqual(wire, expectedWire, "Both exact typed IDs must be fully delivered before reader accounting resumes")
                closeDescriptor(&inputDescriptors[1])
                await gate.release()
                let terminal = await transport.waitUntilTerminal()
                XCTAssertEqual(terminal, .stdinEOF)
                let afterEOF = tracker.snapshot()
                XCTAssertEqual(afterEOF.pendingRequestCount, 0, "Already delivered numeric7 and string7 must not acquire phantom delivery debt")
                XCTAssertFalse(afterEOF.isTerminal)
                let drained = await transport.waitForDeliveryDrain(timeout: .zero)
                XCTAssertTrue(drained, "Physical delivery followed by clean EOF must already be drained")
            } catch {
                await gate.release()
                await transport.disconnect()
                throw error
            }
            await transport.disconnect()
        }
    #endif

    func testRejectedLedgerGenerationOrTerminalFinishesReaderWithoutPublishing() async throws {
        for resetGeneration in [false, true] {
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
            let tracker = MCPDomainResponseDeliveryTracker()
            let transport = MCPStdioServerTransport(
                stdinFD: inputDescriptors[0], stdoutFD: outputDescriptors[1],
                parentPIDProvider: { 42 }, deliveryTracker: tracker
            )
            try await transport.connect()
            if resetGeneration {
                tracker.reset()
            } else {
                tracker.close()
            }
            writeExactly(Data(#"{"id":7,"method":"ping"}"#.utf8) + Data([10]), to: inputDescriptors[1])
            var iterator = await transport.receive().makeAsyncIterator()
            do {
                let frame = try await iterator.next()
                XCTFail("Rejected ledger publication must finish, not expose a frame: \(String(describing: frame))")
            } catch {
                XCTAssertEqual(error as? MCPStdioServerTransport.TerminalError, .cancelled)
            }
            let terminal = await transport.waitUntilTerminal()
            XCTAssertEqual(terminal, .cancelled)
            XCTAssertEqual(tracker.snapshot().pendingRequestCount, 0)
            await transport.disconnect()
        }
    }

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

#if DEBUG
    private actor StdioAccountingPublicationGate {
        private var isHeld = false
        private var isReleased = false
        private var heldWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func hold() async {
            isHeld = true
            heldWaiter?.resume()
            heldWaiter = nil
            guard !isReleased else { return }
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func waitUntilHeld() async {
            guard !isHeld else { return }
            await withCheckedContinuation { heldWaiter = $0 }
        }

        func release() {
            isReleased = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }
#endif
