#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Logging
import MCP
import RepoPromptDomainRuntime

/// Newline-framed MCP transport over an arbitrary pair of file descriptors.
/// Desktop `MCPStdioServerTransport` is Darwin-only; this is the portable copy
/// used by the Linux server socket and `RepoPromptServer mcp-stdio` bridge peer.
actor PortableMCPByteTransport: Transport {
    enum TerminalError: Error, Equatable {
        case stdinEOF
        case stdinRead(errno: Int32)
        case stdinTruncatedFrame(bytes: Int)
        case stdinFrameTooLarge(bytes: Int, maximum: Int)
        case stdinPoll(errno: Int32)
        case stdinBackpressureStall(frameBytes: Int, maximumBufferedFrames: Int)
        case parentProcessChanged(initial: Int32, current: Int32)
        case stdoutBrokenPipe(bytesWritten: Int, totalBytes: Int)
        case stdoutWrite(errno: Int32, bytesWritten: Int, totalBytes: Int)
        case cancelled
    }

    nonisolated let logger: Logger
    private let stdinFD: Int32
    private let stdoutFD: Int32
    private let pollIntervalMilliseconds: Int32
    private let readBackpressureStallTimeout: Duration
    private let writeStallTimeout: Duration
    private let maximumInboundFrameBytes: Int
    private let maximumBufferedFrames: Int
    private let initialParentPID: Int32
    private let parentPIDProvider: @Sendable () -> Int32
    private let deliveryTracker: MCPDomainResponseDeliveryTracker
    private let terminalState = PortableMCPTerminalState()
    private var readTask: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var stream: AsyncThrowingStream<Data, Error>?

    init(
        stdinFD: Int32,
        stdoutFD: Int32,
        pollIntervalMilliseconds: Int32 = 100,
        readBackpressureStallTimeout: Duration = .seconds(5),
        writeStallTimeout: Duration = .seconds(5),
        maximumInboundFrameBytes: Int = 16 * 1024 * 1024,
        maximumBufferedFrames: Int = 64,
        parentPIDProvider: @escaping @Sendable () -> Int32 = { 1 },
        deliveryTracker: MCPDomainResponseDeliveryTracker = MCPDomainResponseDeliveryTracker(),
        logger: Logger = Logger(label: "com.repoprompt.ce.mcp.headless-byte")
    ) {
        self.stdinFD = stdinFD
        self.stdoutFD = stdoutFD
        self.pollIntervalMilliseconds = pollIntervalMilliseconds
        self.readBackpressureStallTimeout = readBackpressureStallTimeout
        self.writeStallTimeout = writeStallTimeout
        self.maximumInboundFrameBytes = max(1, maximumInboundFrameBytes)
        self.maximumBufferedFrames = max(1, maximumBufferedFrames)
        self.parentPIDProvider = parentPIDProvider
        initialParentPID = parentPIDProvider()
        self.deliveryTracker = deliveryTracker
        self.logger = logger
    }

    func connect() throws {
        guard readTask == nil else { return }
        PortablePOSIX.ignoreSIGPIPE()
        PortablePOSIX.enableNoSIGPIPE(on: stdoutFD)
        let flags = PortablePOSIX.fcntlGetFlags(stdoutFD)
        guard flags >= 0, PortablePOSIX.fcntlSetFlags(stdoutFD, flags | O_NONBLOCK) == 0 else {
            throw TerminalError.stdoutWrite(errno: errno, bytesWritten: 0, totalBytes: 0)
        }
        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        let created = AsyncThrowingStream<Data, Error>(
            bufferingPolicy: .bufferingOldest(maximumBufferedFrames)
        ) { captured = $0 }
        guard let captured else { throw TerminalError.cancelled }
        continuation = captured
        stream = created
        let stdinFD = stdinFD
        let pollIntervalMilliseconds = pollIntervalMilliseconds
        let initialParentPID = initialParentPID
        let parentPIDProvider = parentPIDProvider
        let deliveryTracker = deliveryTracker
        let terminalState = terminalState
        let maximumInboundFrameBytes = maximumInboundFrameBytes
        let maximumBufferedFrames = maximumBufferedFrames
        let readBackpressureStallTimeout = readBackpressureStallTimeout
        readTask = Task.detached(priority: .userInitiated) { [captured] in
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while !Task.isCancelled {
                let currentParentPID = parentPIDProvider()
                guard currentParentPID == initialParentPID else {
                    let terminal = TerminalError.parentProcessChanged(
                        initial: initialParentPID,
                        current: currentParentPID
                    )
                    await terminalState.record(terminal)
                    captured.finish(throwing: terminal)
                    return
                }
                var descriptor = pollfd(fd: stdinFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
                let pollResult = PortablePOSIX.poll(&descriptor, timeout: pollIntervalMilliseconds)
                if pollResult == 0 { continue }
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    let terminal = TerminalError.stdinPoll(errno: errno)
                    await terminalState.record(terminal)
                    captured.finish(throwing: terminal)
                    return
                }
                let count = PortablePOSIX.read(stdinFD, &buffer, buffer.count)
                if count == 0 {
                    if pending.isEmpty {
                        await terminalState.record(.stdinEOF)
                        captured.finish()
                    } else {
                        let terminal = TerminalError.stdinTruncatedFrame(bytes: pending.count)
                        await terminalState.record(terminal)
                        captured.finish(throwing: terminal)
                    }
                    return
                }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    let terminal = TerminalError.stdinRead(errno: errno)
                    await terminalState.record(terminal)
                    captured.finish(throwing: terminal)
                    return
                }
                pending.append(buffer, count: count)
                guard pending.count <= maximumInboundFrameBytes || pending.firstIndex(of: 0x0A) != nil else {
                    let terminal = TerminalError.stdinFrameTooLarge(
                        bytes: pending.count,
                        maximum: maximumInboundFrameBytes
                    )
                    await terminalState.record(terminal)
                    captured.finish(throwing: terminal)
                    return
                }
                while let newline = pending.firstIndex(of: 0x0A) {
                    let frame = pending.prefix(upTo: newline)
                    pending.removeSubrange(...newline)
                    guard frame.count <= maximumInboundFrameBytes else {
                        let terminal = TerminalError.stdinFrameTooLarge(
                            bytes: frame.count,
                            maximum: maximumInboundFrameBytes
                        )
                        await terminalState.record(terminal)
                        captured.finish(throwing: terminal)
                        return
                    }
                    if !frame.isEmpty {
                        let data = Data(frame)
                        var enqueued = false
                        var backpressureDeadline: ContinuousClock.Instant?
                        let clock = ContinuousClock()
                        while !enqueued, !Task.isCancelled {
                            switch captured.yield(data) {
                            case .enqueued:
                                deliveryTracker.recordAcceptedClientFrame(data)
                                enqueued = true
                            case .dropped:
                                if let backpressureDeadline {
                                    guard clock.now < backpressureDeadline else {
                                        let terminal = TerminalError.stdinBackpressureStall(
                                            frameBytes: data.count,
                                            maximumBufferedFrames: maximumBufferedFrames
                                        )
                                        await terminalState.record(terminal)
                                        captured.finish(throwing: terminal)
                                        return
                                    }
                                } else {
                                    backpressureDeadline = clock.now.advanced(by: readBackpressureStallTimeout)
                                }
                                try? await Task.sleep(for: .milliseconds(1))
                            case .terminated:
                                return
                            @unknown default:
                                return
                            }
                        }
                        if Task.isCancelled { break }
                    }
                }
            }
            await terminalState.record(.cancelled)
            captured.finish(throwing: TerminalError.cancelled)
        }
    }

    func disconnect() async {
        let ownedReadTask = readTask
        readTask = nil
        ownedReadTask?.cancel()
        if let ownedReadTask {
            await ownedReadTask.value
        }
        await terminalState.record(.cancelled)
        continuation?.finish()
        continuation = nil
        stream = nil
        deliveryTracker.close()
    }

    func send(_ data: Data) async throws {
        var bytes = data
        if bytes.last != 0x0A { bytes.append(0x0A) }
        let deadline = ContinuousClock().now.advanced(by: writeStallTimeout)
        var written = 0
        while written < bytes.count {
            try Task.checkCancellation()
            let result = bytes.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return 0 }
                return PortablePOSIX.write(stdoutFD, base.advanced(by: written), bytes.count - written)
            }
            if result > 0 {
                written += result
                continue
            }
            if result < 0, errno == EINTR { continue }
            if result < 0, errno == EPIPE {
                let terminal = TerminalError.stdoutBrokenPipe(bytesWritten: written, totalBytes: bytes.count)
                await terminalState.record(terminal)
                throw terminal
            }
            if result < 0, errno != EAGAIN, errno != EWOULDBLOCK {
                let terminal = TerminalError.stdoutWrite(errno: errno, bytesWritten: written, totalBytes: bytes.count)
                await terminalState.record(terminal)
                throw terminal
            }
            guard ContinuousClock().now < deadline else {
                let terminal = TerminalError.stdoutWrite(errno: ETIMEDOUT, bytesWritten: written, totalBytes: bytes.count)
                await terminalState.record(terminal)
                throw terminal
            }
            var descriptor = pollfd(fd: stdoutFD, events: Int16(POLLOUT | POLLHUP | POLLERR), revents: 0)
            let pollResult = PortablePOSIX.poll(&descriptor, timeout: min(pollIntervalMilliseconds, 50))
            if pollResult < 0, errno != EINTR {
                let terminal = TerminalError.stdoutWrite(errno: errno, bytesWritten: written, totalBytes: bytes.count)
                await terminalState.record(terminal)
                throw terminal
            }
            await Task.yield()
        }
        deliveryTracker.recordDeliveredServerFrame(bytes)
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        stream ?? AsyncThrowingStream { $0.finish(throwing: TerminalError.cancelled) }
    }

    func waitUntilTerminal() async -> TerminalError {
        await terminalState.wait()
    }
}

private actor PortableMCPTerminalState {
    private var terminal: PortableMCPByteTransport.TerminalError?
    private var waiters: [CheckedContinuation<PortableMCPByteTransport.TerminalError, Never>] = []

    func record(_ value: PortableMCPByteTransport.TerminalError) {
        guard terminal == nil else { return }
        terminal = value
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: value) }
    }

    func wait() async -> PortableMCPByteTransport.TerminalError {
        if let terminal { return terminal }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
