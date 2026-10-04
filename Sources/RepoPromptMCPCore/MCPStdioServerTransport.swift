import Darwin
import Foundation
import Logging
import MCP
import RepoPromptDomainRuntime

actor MCPStdioServerTransport: Transport {
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
        case stdoutPartialFrame(bytesWritten: Int, totalBytes: Int)
        case stdoutWriteQueueFull(maximum: Int)
        case cancelled
    }

    enum WriteGateEvent { case enqueued, handedOff, sealed }

    nonisolated let logger: Logger
    private let stdinFD: Int32
    private let outputSink: any MCPStdioOutputSink
    private let pollIntervalMilliseconds: Int32
    private let readBackpressureStallTimeout: Duration
    private let writeStallTimeout: Duration
    private let maximumInboundFrameBytes: Int
    private let maximumBufferedFrames: Int
    private let initialParentPID: Int32
    private let parentPIDProvider: @Sendable () -> Int32
    private let deliveryTracker: MCPDomainResponseDeliveryTracker
    private let terminalState = MCPStdioTerminalState()
    private let maximumQueuedWrites: Int
    private let writeGateObserver: (@Sendable (WriteGateEvent) -> Void)?
    private let beforeSealReaderTeardownForTesting: (@Sendable () async -> Void)?
    private let readEOFObserverForTesting: (@Sendable () -> Void)?
    #if DEBUG
        private var afterClientFramePublicationForTesting: (@Sendable () async -> Void)?

        func debugSetAfterClientFramePublicationForTesting(
            _ callback: (@Sendable () async -> Void)?
        ) {
            afterClientFramePublicationForTesting = callback
        }
    #endif
    private var writeOwnerActive = false
    private var writeWaiters: [(token: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var writeSealed: TerminalError?
    private var writableTask: Task<MCPStdioWritableResult, Never>?
    private var readTask: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var stream: AsyncThrowingStream<Data, Error>?

    init(
        stdinFD: Int32 = STDIN_FILENO,
        stdoutFD: Int32 = STDOUT_FILENO,
        outputSink: (any MCPStdioOutputSink)? = nil,
        maximumQueuedWrites: Int = 64,
        writeGateObserver: (@Sendable (WriteGateEvent) -> Void)? = nil,
        beforeSealReaderTeardownForTesting: (@Sendable () async -> Void)? = nil,
        readEOFObserverForTesting: (@Sendable () -> Void)? = nil,
        pollIntervalMilliseconds: Int32 = 100,
        readBackpressureStallTimeout: Duration = .seconds(5),
        writeStallTimeout: Duration = .seconds(5),
        maximumInboundFrameBytes: Int = 16 * 1024 * 1024,
        maximumBufferedFrames: Int = 64,
        parentPIDProvider: @escaping @Sendable () -> Int32 = { getppid() },
        deliveryTracker: MCPDomainResponseDeliveryTracker = MCPDomainResponseDeliveryTracker(),
        logger: Logger = Logger(label: "com.repoprompt.ce.mcp.headless-stdio")
    ) {
        self.maximumQueuedWrites = max(1, maximumQueuedWrites)
        self.writeGateObserver = writeGateObserver
        self.beforeSealReaderTeardownForTesting = beforeSealReaderTeardownForTesting
        self.readEOFObserverForTesting = readEOFObserverForTesting
        self.stdinFD = stdinFD
        self.outputSink = outputSink ?? MCPStdioFileDescriptorOutputSink(
            descriptor: stdoutFD, pollIntervalMilliseconds: pollIntervalMilliseconds
        )
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
        if let writeSealed {
            throw writeSealed
        }
        guard readTask == nil else { return }
        try outputSink.prepare()
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
        let deliveryGeneration = deliveryTracker.currentGeneration
        let terminalState = terminalState
        let readEOFObserverForTesting = readEOFObserverForTesting
        let maximumInboundFrameBytes = maximumInboundFrameBytes
        let maximumBufferedFrames = maximumBufferedFrames
        let readBackpressureStallTimeout = readBackpressureStallTimeout
        #if DEBUG
            let afterClientFramePublicationForTesting = afterClientFramePublicationForTesting
        #endif
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
                    terminalState.record(terminal, finishing: captured)
                    return
                }
                var descriptor = pollfd(fd: stdinFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
                let pollResult = poll(&descriptor, 1, pollIntervalMilliseconds)
                if pollResult == 0 {
                    continue
                }
                if pollResult < 0 {
                    if errno == EINTR {
                        continue
                    }
                    let terminal = TerminalError.stdinPoll(errno: errno)
                    terminalState.record(terminal, finishing: captured)
                    return
                }
                let count = read(stdinFD, &buffer, buffer.count)
                if count == 0 {
                    if pending.isEmpty {
                        terminalState.record(.stdinEOF, finishing: captured)
                    } else {
                        let terminal = TerminalError.stdinTruncatedFrame(bytes: pending.count)
                        terminalState.record(terminal, finishing: captured)
                    }
                    readEOFObserverForTesting?()
                    return
                }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN {
                        continue
                    }
                    let terminal = TerminalError.stdinRead(errno: errno)
                    terminalState.record(terminal, finishing: captured)
                    return
                }
                pending.append(buffer, count: count)
                guard pending.count <= maximumInboundFrameBytes || pending.firstIndex(of: 0x0A) != nil else {
                    let terminal = TerminalError.stdinFrameTooLarge(
                        bytes: pending.count,
                        maximum: maximumInboundFrameBytes
                    )
                    terminalState.record(terminal, finishing: captured)
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
                        terminalState.record(terminal, finishing: captured)
                        return
                    }
                    if !frame.isEmpty {
                        let data = Data(frame)
                        var enqueued = false
                        var backpressureDeadline: ContinuousClock.Instant?
                        let clock = ContinuousClock()
                        while !enqueued, !Task.isCancelled {
                            var yieldResult: AsyncThrowingStream<Data, Error>.Continuation.YieldResult?
                            _ = deliveryTracker.publishClientFrame(data, expectedGeneration: deliveryGeneration) {
                                let result = captured.yield(data)
                                yieldResult = result
                                if case .enqueued = result {
                                    return true
                                }
                                return false
                            }
                            guard let yieldResult else {
                                terminalState.record(.cancelled, finishing: captured)
                                return
                            }
                            switch yieldResult {
                            case .enqueued:
                                #if DEBUG
                                    await afterClientFramePublicationForTesting?()
                                #endif
                                enqueued = true
                            case .dropped:
                                // Buffering-oldest drops only the incoming element. Retain it here and
                                // stop reading until the server consumes capacity, preserving request order.
                                if let backpressureDeadline {
                                    guard clock.now < backpressureDeadline else {
                                        let terminal = TerminalError.stdinBackpressureStall(
                                            frameBytes: data.count,
                                            maximumBufferedFrames: maximumBufferedFrames
                                        )
                                        terminalState.record(terminal, finishing: captured)
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
                        if Task.isCancelled {
                            break
                        }
                    }
                }
            }
            terminalState.record(.cancelled, finishing: captured)
        }
    }

    func disconnect() async {
        await sealWrites(.cancelled)
        let ownedReadTask = readTask
        readTask = nil
        ownedReadTask?.cancel()
        if let ownedReadTask {
            await ownedReadTask.value
        }
        terminalState.record(.cancelled, finishing: continuation)
        continuation = nil
        stream = nil
        deliveryTracker.close()
    }

    func send(_ data: Data) async throws {
        try await acquireWriteOwnership()
        var bytes = data
        if bytes.last != 0x0A {
            bytes.append(0x0A)
        }
        let deadline = ContinuousClock().now.advanced(by: writeStallTimeout)
        var written = 0
        do {
            while written < bytes.count {
                if let writeSealed {
                    throw writeSealed
                }
                try Task.checkCancellation()
                let result = bytes.withUnsafeBytes { rawBuffer in
                    outputSink.write(UnsafeRawBufferPointer(rebasing: rawBuffer[written...]))
                }
                switch result {
                case let .wrote(count):
                    written += count
                    continue
                case .interrupted:
                    continue
                case .brokenPipe:
                    throw TerminalError.stdoutBrokenPipe(bytesWritten: written, totalBytes: bytes.count)
                case let .failed(error):
                    throw TerminalError.stdoutWrite(errno: error, bytesWritten: written, totalBytes: bytes.count)
                case .wouldBlock:
                    break
                }
                guard ContinuousClock().now < deadline else {
                    throw TerminalError.stdoutWrite(errno: ETIMEDOUT, bytesWritten: written, totalBytes: bytes.count)
                }
                let sink = outputSink
                let wait = Task { await sink.awaitWritable() }
                writableTask = wait
                let readiness = await withTaskCancellationHandler {
                    await wait.value
                } onCancel: {
                    wait.cancel()
                }
                writableTask = nil
                if let writeSealed {
                    throw writeSealed
                }
                try Task.checkCancellation()
                if case let .failed(error) = readiness {
                    throw TerminalError.stdoutWrite(errno: error, bytesWritten: written, totalBytes: bytes.count)
                }
            }
            deliveryTracker.recordDeliveredServerFrame(bytes)
            releaseWriteOwnership()
        } catch is CancellationError {
            if written == 0, writeSealed == nil {
                releaseWriteOwnership()
                throw CancellationError()
            }
            let terminal = writeSealed ?? .stdoutPartialFrame(bytesWritten: written, totalBytes: bytes.count)
            await sealWrites(terminal)
            throw terminal
        } catch {
            // A fatal write, even at zero bytes, invalidates this physical output stream.
            let terminal = writeSealed ?? (error as? TerminalError)
                ?? .stdoutWrite(errno: EIO, bytesWritten: written, totalBytes: bytes.count)
            await sealWrites(terminal)
            throw terminal
        }
    }

    private func acquireWriteOwnership() async throws {
        try Task.checkCancellation()
        if let writeSealed {
            throw writeSealed
        }
        guard writeOwnerActive else {
            writeOwnerActive = true
            return
        }
        guard writeWaiters.count < maximumQueuedWrites else {
            throw TerminalError.stdoutWriteQueueFull(maximum: maximumQueuedWrites)
        }
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                writeWaiters.append((token, continuation))
                writeGateObserver?(.enqueued)
            }
        } onCancel: {
            Task { await self.cancelQueuedWrite(token) }
        }
    }

    private func cancelQueuedWrite(_ token: UUID) {
        guard let index = writeWaiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = writeWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseWriteOwnership() {
        guard writeSealed == nil else { return }
        if writeWaiters.isEmpty {
            writeOwnerActive = false
        } else {
            let waiter = writeWaiters.removeFirst()
            writeGateObserver?(.handedOff)
            waiter.continuation.resume()
        }
    }

    private func sealWrites(_ terminal: TerminalError) async {
        guard writeSealed == nil else { return }
        // Seal before any actor suspension; neither a queued nor a resumed owner can append bytes.
        writeSealed = terminal
        // Claim and finish before effects can wake other tasks or observe the sealed writer.
        // Read EOF/cancellation races on the detached reader through this same authority.
        terminalState.record(terminal, finishing: continuation)
        writableTask?.cancel()
        let waiters = writeWaiters
        writeWaiters.removeAll()
        waiters.forEach { $0.continuation.resume(throwing: terminal) }
        writeGateObserver?(.sealed)
        deliveryTracker.close()
        // Nil in production: holds the boundary after terminal ownership, before reader teardown.
        await beforeSealReaderTeardownForTesting?()
        readTask?.cancel()
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        stream ?? AsyncThrowingStream { $0.finish(throwing: TerminalError.cancelled) }
    }

    func terminalError() async -> TerminalError? {
        terminalState.value()
    }

    func waitForDeliveryDrain(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while ContinuousClock().now < deadline {
            if deliveryTracker.snapshot().acceptedRequestsFullyResponded {
                return true
            }
            if Task.isCancelled {
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
        }
        return deliveryTracker.snapshot().acceptedRequestsFullyResponded
    }

    func waitUntilTerminal() async -> TerminalError {
        await terminalState.wait()
    }
}

/// The detached reader and actor-owned writer share one synchronous terminal authority.
/// All mutable state is protected by `lock`; claiming and finishing are one critical section.
private final class MCPStdioTerminalState: @unchecked Sendable {
    private let lock = NSLock()
    private var terminal: MCPStdioServerTransport.TerminalError?
    private var waiters: [CheckedContinuation<MCPStdioServerTransport.TerminalError, Never>] = []

    func record(
        _ value: MCPStdioServerTransport.TerminalError,
        finishing continuation: AsyncThrowingStream<Data, Error>.Continuation?
    ) {
        let pending: [CheckedContinuation<MCPStdioServerTransport.TerminalError, Never>] = lock.withLock {
            guard terminal == nil else { return [] }
            terminal = value
            if value == .stdinEOF {
                continuation?.finish()
            } else {
                continuation?.finish(throwing: value)
            }
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume(returning: value) }
    }

    func value() -> MCPStdioServerTransport.TerminalError? {
        lock.withLock { terminal }
    }

    func wait() async -> MCPStdioServerTransport.TerminalError {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if let terminal {
                    continuation.resume(returning: terminal)
                } else {
                    waiters.append(continuation)
                }
            }
        }
    }
}
