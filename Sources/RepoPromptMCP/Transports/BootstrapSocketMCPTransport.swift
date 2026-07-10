//
//  BootstrapSocketMCPTransport.swift
//  repoprompt-mcp
//
//  CLI-side MCP Transport implementation over an already-connected UNIX socket FD.
//  Uses DispatchSourceRead for event-driven I/O to avoid blocking the actor executor.
//

import Dispatch
import Foundation
import Logging
import MCP
import RepoPromptShared
import SystemPackage

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

#if DEBUG
    private final class BootstrapSocketMCPTransportCallbackGate: @unchecked Sendable {
        enum Kind: Hashable {
            case terminal
            case cancellation
        }

        private let lock = NSLock()
        private var heldKinds: Set<Kind> = []
        private var pendingCallbacks: [Kind: [@Sendable () -> Void]] = [:]

        func hold(_ kind: Kind) {
            lock.lock()
            heldKinds.insert(kind)
            lock.unlock()
        }

        func submit(_ kind: Kind, callback: @escaping @Sendable () -> Void) {
            lock.lock()
            guard heldKinds.contains(kind) else {
                lock.unlock()
                callback()
                return
            }
            pendingCallbacks[kind, default: []].append(callback)
            lock.unlock()
        }

        func release(_ kind: Kind) {
            lock.lock()
            heldKinds.remove(kind)
            let callbacks = pendingCallbacks.removeValue(forKey: kind) ?? []
            lock.unlock()
            callbacks.forEach { $0() }
        }
    }
#endif

struct BootstrapSocketMCPReceiveBufferOverflowError: Error, Equatable, CustomStringConvertible, LocalizedError {
    let capacity: Int

    var description: String {
        "CLI MCP receive buffer overflow (capacity=\(capacity))"
    }

    var errorDescription: String? {
        description
    }
}

private final class BootstrapSocketMCPIngressGate: @unchecked Sendable {
    enum OfferResult {
        case accepted
        case overflow
        case terminal
    }

    private let lock = NSLock()
    private let receiveBufferCapacity: Int
    private var isTerminal = false
    /// First-writer-wins terminal cause. Overflow is recorded synchronously on
    /// `.dropped` so a racing EOF/error teardown still finishes the stream with
    /// the authoritative overflow error (mirrors app UnixSocketMCPTransport).
    private var terminalError: (any Swift.Error)?

    init(receiveBufferCapacity: Int) {
        self.receiveBufferCapacity = max(1, receiveBufferCapacity)
    }

    func offer(
        _ frame: Data,
        to continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    ) -> OfferResult {
        lock.lock()
        defer { lock.unlock() }
        guard !isTerminal else { return .terminal }

        switch continuation.yield(frame) {
        case .enqueued:
            return .accepted
        case .dropped:
            isTerminal = true
            if terminalError == nil {
                terminalError = BootstrapSocketMCPReceiveBufferOverflowError(
                    capacity: receiveBufferCapacity
                )
            }
            return .overflow
        case .terminated:
            isTerminal = true
            return .terminal
        @unknown default:
            isTerminal = true
            return .terminal
        }
    }

    /// Marks the gate terminal. Optional `error` is recorded only when no
    /// stronger cause (e.g. overflow) was already stored.
    func markTerminal(error: (any Swift.Error)? = nil) {
        lock.lock()
        isTerminal = true
        if terminalError == nil, let error {
            terminalError = error
        }
        lock.unlock()
    }

    /// Authoritative terminal error for stream finish (overflow wins over nil/EOF).
    func authoritativeTerminalError() -> (any Swift.Error)? {
        lock.lock()
        defer { lock.unlock() }
        return terminalError
    }
}

/// MCP Transport implementation for CLI that wraps an already-connected UNIX socket FD.
/// This is used after the bootstrap handshake completes to run MCP.Client over the socket.
public actor BootstrapSocketMCPTransport: Transport {
    private let socketFD: Int32
    public nonisolated let logger: Logger

    private var isConnected = false
    private var streamFinished = false
    private var socketClosed = false
    private var connectionAttempted = false
    private let receiveBufferCapacity: Int
    private let maximumFrameByteCount: Int

    private nonisolated let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private nonisolated let ingressGate: BootstrapSocketMCPIngressGate
    private var messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    private let readQueue = DispatchQueue(label: "com.repoprompt.ce.mcp.cli.socket.read", qos: .userInitiated)
    private var nextReadSourceToken: UInt64 = 0

    private struct ReaderIdentity: Hashable {
        let fd: Int32
        let token: UInt64
    }

    private struct ActiveReaderOwnership {
        let identity: ReaderIdentity
        let reader: NewlineDelimitedSocketReader
    }

    /// Retains cancelled readers until their delayed cancel handlers perform final close.
    /// The transport retainer intentionally forms a temporary cycle so cleanup does not
    /// depend on an external owner keeping this actor alive after disconnect returns.
    private struct PendingReaderCancellation {
        let identity: ReaderIdentity
        let reader: NewlineDelimitedSocketReader
        let transportRetainer: BootstrapSocketMCPTransport
    }

    private var activeReaderOwnership: ActiveReaderOwnership?
    private var pendingReaderCancellations: [UInt64: PendingReaderCancellation] = [:]
    private var earlyReaderCancellations: Set<ReaderIdentity> = []

    #if DEBUG
        private nonisolated let callbackGate = BootstrapSocketMCPTransportCallbackGate()
        private weak var debugLastReader: NewlineDelimitedSocketReader?
        private var debugTerminalCallbackCount = 0
        private var debugCancellationCallbackCount = 0
        private var debugReaderFinalizationCount = 0
        private var debugDescriptorCloseCount = 0
        private var debugStaleCancellationCount = 0
        private var debugStaleTerminalCount = 0
    #endif

    /// Maximum time a write may make no forward progress before the connection is failed closed.
    private let writeStallTimeout: TimeInterval

    /// Maximum poll interval while waiting for socket writability under backpressure.
    private let writePollIntervalMilliseconds: Int32

    /// Creates a transport wrapping an already-connected socket file descriptor.
    /// - Parameters:
    ///   - connectedFD: An already-connected UNIX socket file descriptor from bootstrap handshake
    ///   - logger: Optional logger for transport events
    public init(
        connectedFD: Int32,
        logger: Logger? = nil,
        writeStallTimeout: TimeInterval = MCPTimeoutPolicy.transportWriteStallTimeoutSeconds,
        writePollIntervalMilliseconds: Int32 = 250,
        receiveBufferCapacity: Int = 1024,
        maximumFrameByteCount: Int = MCPNewlineFrameAccumulator.defaultMaximumFrameByteCount
    ) throws {
        let sanitizedReceiveBufferCapacity = max(1, receiveBufferCapacity)
        do {
            try POSIXDescriptorSupport.setCloseOnExec(connectedFD)
        } catch {
            POSIXDescriptorSupport.shutdownSocketReadWrite(connectedFD)
            Darwin.close(connectedFD)
            throw error
        }

        socketFD = connectedFD
        self.logger = logger ?? Logger(label: "mcp.transport.socket") { _ in
            SwiftLogNoOpLogHandler()
        }
        self.writeStallTimeout = writeStallTimeout
        self.writePollIntervalMilliseconds = Self.sanitizedWritePollIntervalMilliseconds(writePollIntervalMilliseconds)
        self.receiveBufferCapacity = sanitizedReceiveBufferCapacity
        self.maximumFrameByteCount = max(1, maximumFrameByteCount)
        ingressGate = BootstrapSocketMCPIngressGate(
            receiveBufferCapacity: sanitizedReceiveBufferCapacity
        )

        // Create message stream (buffered to avoid unbounded growth if consumer is slow)
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        messageStream = AsyncThrowingStream(
            Data.self,
            bufferingPolicy: .bufferingOldest(sanitizedReceiveBufferCapacity)
        ) { continuation = $0 }
        messageContinuation = continuation
    }

    /// Establishes the transport connection.
    /// Since the FD is already connected from bootstrap, this just starts the read source.
    public func connect() async throws {
        guard !isConnected else { return }
        guard !connectionAttempted, !socketClosed, !streamFinished else {
            logger.warning("BootstrapSocketMCPTransport.connect called after adopted socket teardown")
            throw MCPError.connectionClosed
        }
        connectionAttempted = true

        logger.debug("BootstrapSocketMCPTransport connecting on FD \(socketFD)")
        logger.debug("BootstrapSocketMCPTransport connected, starting read source")

        do {
            // Set non-blocking mode on the socket
            try Self.ensureNonBlocking(fd: socketFD)

            // Disable SIGPIPE on this socket
            var noSigPipe: Int32 = 1
            setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            try startReadSource(fd: socketFD)
            isConnected = true
        } catch {
            tearDownSocket(error: error)
            throw error
        }
    }

    /// Disconnects the transport and closes the socket.
    public func disconnect() async {
        guard !socketClosed else { return }
        tearDownSocket(error: MCPError.connectionClosed)

        logger.debug("BootstrapSocketMCPTransport disconnected")
    }

    /// Sends data over the socket with newline delimiter.
    /// Appends a newline only if the message doesn't already end with one,
    /// making framing idempotent for callers that may or may not pre-frame.
    public func send(_ message: Data) async throws {
        guard isConnected, !socketClosed else {
            logger.warning("BootstrapSocketMCPTransport.send called but not connected")
            throw MCPError.transportError(Errno(rawValue: ENOTCONN))
        }

        let framed = Self.frameWithNewlineIfNeeded(message)
        logger.trace(
            "send bytes=\(framed.count) sha256=\(MCPResponseDeliveryTracer.sha256Hex(framed))"
        )

        try writeAll(framed)

        logger.debug("Sent \(message.count) bytes")
    }

    /// Returns the async stream of received messages.
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        logger.trace("BootstrapSocketMCPTransport.receive() called")
        return messageStream
    }

    /// Appends a newline delimiter if the message doesn't already end with one.
    private nonisolated static func frameWithNewlineIfNeeded(_ data: Data) -> Data {
        guard data.last != UInt8(ascii: "\n") else { return data }
        var framed = Data()
        framed.reserveCapacity(data.count + 1)
        framed.append(data)
        framed.append(UInt8(ascii: "\n"))
        return framed
    }

    private nonisolated static func sanitizedWritePollIntervalMilliseconds(_ value: Int32) -> Int32 {
        max(1, value)
    }

    private nonisolated static func ensureNonBlocking(fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else {
            throw MCPError.transportError(Errno(rawValue: errno))
        }
        guard flags & O_NONBLOCK == 0 else { return }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw MCPError.transportError(Errno(rawValue: errno))
        }
    }

    private func writeAll(_ data: Data) throws {
        do {
            try Self.ensureNonBlocking(fd: socketFD)
        } catch {
            closeAfterSendFailure(error)
            throw error
        }
        var remaining = data
        var lastProgressAt = Date()

        while !remaining.isEmpty {
            guard isConnected, !socketClosed else {
                throw MCPError.connectionClosed
            }
            if Date().timeIntervalSince(lastProgressAt) >= writeStallTimeout {
                let error = MCPError.transportError(BootstrapSocketWriteStalledError(
                    stallTimeout: writeStallTimeout,
                    bytesRemaining: remaining.count,
                    totalBytes: data.count
                ))
                closeAfterSendFailure(error)
                throw error
            }

            let written = remaining.withUnsafeBytes { buffer in
                Darwin.write(socketFD, buffer.baseAddress!, buffer.count)
            }

            if written < 0 {
                let err = errno
                if err == EINTR {
                    continue
                }
                if err == EAGAIN || err == EWOULDBLOCK {
                    try waitForSocketWritable(
                        lastProgressAt: lastProgressAt,
                        totalBytes: data.count,
                        bytesRemaining: remaining.count
                    )
                    continue
                }
                if err == EPIPE || err == ECONNRESET {
                    closeAfterSendFailure(MCPError.connectionClosed)
                    throw MCPError.connectionClosed
                }
                let error = MCPError.transportError(Errno(rawValue: err))
                closeAfterSendFailure(error)
                throw error
            }

            if written == 0 {
                closeAfterSendFailure(MCPError.connectionClosed)
                throw MCPError.connectionClosed
            }

            remaining = remaining.dropFirst(written)
            lastProgressAt = Date()
        }
    }

    private func waitForSocketWritable(
        lastProgressAt: Date,
        totalBytes: Int,
        bytesRemaining: Int
    ) throws {
        while true {
            guard isConnected, !socketClosed else {
                throw MCPError.connectionClosed
            }

            let remainingStallSeconds = writeStallTimeout - Date().timeIntervalSince(lastProgressAt)
            if remainingStallSeconds <= 0 {
                let error = MCPError.transportError(BootstrapSocketWriteStalledError(
                    stallTimeout: writeStallTimeout,
                    bytesRemaining: bytesRemaining,
                    totalBytes: totalBytes
                ))
                closeAfterSendFailure(error)
                throw error
            }

            var pfd = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
            let remainingMs = max(1, Int32(remainingStallSeconds * 1000))
            let pollTimeout = min(writePollIntervalMilliseconds, remainingMs)
            let result = poll(&pfd, 1, pollTimeout)

            if result < 0 {
                if errno == EINTR {
                    continue
                }
                let error = MCPError.transportError(Errno(rawValue: errno))
                closeAfterSendFailure(error)
                throw error
            }

            if result == 0 {
                continue
            }

            if pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                closeAfterSendFailure(MCPError.connectionClosed)
                throw MCPError.connectionClosed
            }

            if pfd.revents & Int16(POLLOUT) != 0 {
                return
            }
        }
    }

    private func closeAfterSendFailure(_ error: Swift.Error) {
        logger.error("BootstrapSocketMCPTransport send failed; closing transport: \(String(describing: error))")
        tearDownSocket(error: error)
    }

    private struct BootstrapSocketWriteStalledError: Swift.Error, CustomStringConvertible {
        let stallTimeout: TimeInterval
        let bytesRemaining: Int
        let totalBytes: Int

        var description: String {
            "Bootstrap socket write made no progress for \(stallTimeout)s (remaining \(bytesRemaining)/\(totalBytes) bytes)"
        }
    }

    #if DEBUG
        func debugHoldReaderTerminalCallback() {
            callbackGate.hold(.terminal)
        }

        func debugReleaseReaderTerminalCallbacks() {
            callbackGate.release(.terminal)
        }

        func debugHoldReaderCancellationCallback() {
            callbackGate.hold(.cancellation)
        }

        func debugReleaseReaderCancellationCallbacks() {
            callbackGate.release(.cancellation)
        }

        func debugIsStreamFinished() -> Bool {
            streamFinished
        }
    #endif

    private nonisolated func scheduleReaderTerminalCallback(_ callback: @escaping @Sendable () -> Void) {
        #if DEBUG
            callbackGate.submit(.terminal, callback: callback)
        #else
            callback()
        #endif
    }

    private nonisolated func scheduleReaderCancellationCallback(_ callback: @escaping @Sendable () -> Void) {
        #if DEBUG
            callbackGate.submit(.cancellation, callback: callback)
        #else
            callback()
        #endif
    }

    // MARK: - Private

    /// Starts the DispatchSourceRead to receive data without blocking the actor executor.
    private func startReadSource(fd: Int32) throws {
        try ReadSourceFDPreflight.validateOpenFD(fd, label: "BootstrapSocketMCPTransport read socket")
        stopReadSource()

        nextReadSourceToken &+= 1
        let identity = ReaderIdentity(fd: fd, token: nextReadSourceToken)

        let cont = messageContinuation
        let log = logger
        let receiveBufferCapacity = receiveBufferCapacity

        let newReader = NewlineDelimitedSocketReader(
            fd: fd,
            queue: readQueue,
            logger: log,
            maximumFrameByteCount: maximumFrameByteCount,
            onFrame: { [weak self] frame in
                guard let self else { return }
                switch ingressGate.offer(frame, to: cont) {
                case .accepted:
                    break
                case .overflow:
                    // Cause is already recorded synchronously on the gate; the
                    // async task only drives teardown. finishStreamIfNeeded always
                    // resolves the gate's authoritative overflow error.
                    let error = BootstrapSocketMCPReceiveBufferOverflowError(
                        capacity: receiveBufferCapacity
                    )
                    Task { await self.handleReceiveBufferOverflow(error, from: identity) }
                case .terminal:
                    break
                }
            },
            onTerminal: { [weak self] terminal in
                guard let transport = self else { return }
                transport.scheduleReaderTerminalCallback {
                    Task { await transport.handleReaderTerminal(terminal, from: identity) }
                }
            },
            onCancel: { [weak self] in
                guard let transport = self else { return }
                transport.scheduleReaderCancellationCallback {
                    Task { await transport.readSourceDidCancel(identity) }
                }
            }
        )

        activeReaderOwnership = ActiveReaderOwnership(identity: identity, reader: newReader)
        #if DEBUG
            debugLastReader = newReader
        #endif
        do {
            try newReader.start()
        } catch {
            if activeReaderOwnership?.identity == identity {
                activeReaderOwnership = nil
            }
            throw error
        }
    }

    /// Moves active reader ownership to the cancellation finalizer before requesting cancellation.
    private func stopReadSource() {
        guard let activeOwnership = activeReaderOwnership else { return }
        activeReaderOwnership = nil

        let identity = activeOwnership.identity
        pendingReaderCancellations[identity.token] = PendingReaderCancellation(
            identity: identity,
            reader: activeOwnership.reader,
            transportRetainer: self
        )
        activeOwnership.reader.stop()

        if earlyReaderCancellations.contains(identity) {
            finalizeReaderCancellation(identity)
        }
    }

    private func pendingReaderCancellationOwnsCurrentSocket() -> Bool {
        pendingReaderCancellations.values.contains { $0.identity.fd == socketFD }
    }

    private func readSourceDidCancel(_ identity: ReaderIdentity) {
        #if DEBUG
            debugCancellationCallbackCount += 1
        #endif

        if pendingReaderCancellations[identity.token]?.identity == identity {
            finalizeReaderCancellation(identity)
            return
        }

        if activeReaderOwnership?.identity == identity {
            earlyReaderCancellations.insert(identity)
            return
        }

        #if DEBUG
            debugStaleCancellationCount += 1
        #endif
    }

    private func finalizeReaderCancellation(_ identity: ReaderIdentity) {
        guard pendingReaderCancellations[identity.token]?.identity == identity,
              let ownership = pendingReaderCancellations.removeValue(forKey: identity.token)
        else {
            return
        }
        earlyReaderCancellations.remove(identity)
        withExtendedLifetime(ownership) {
            #if DEBUG
                debugReaderFinalizationCount += 1
            #endif
            closeSocketIfNeeded()
        }
    }

    private func handleReaderTerminal(
        _ terminal: NewlineDelimitedSocketReaderTerminal,
        from identity: ReaderIdentity
    ) {
        #if DEBUG
            debugTerminalCallbackCount += 1
        #endif

        guard activeReaderOwnership?.identity == identity else {
            #if DEBUG
                debugStaleTerminalCount += 1
            #endif
            return
        }

        switch terminal {
        case let .error(error):
            tearDownSocket(error: error)
        case let .eof(hasResidualData):
            guard hasResidualData else {
                tearDownSocket()
                return
            }
            let truncationError = MCPError.internalError("Connection closed with incomplete frame data")
            tearDownSocket(error: truncationError)
        }
    }

    private func handleReceiveBufferOverflow(
        _ error: BootstrapSocketMCPReceiveBufferOverflowError,
        from identity: ReaderIdentity
    ) {
        // Identity may already be cleared if a racing EOF teardown won the stop race.
        // The gate still holds the overflow cause recorded synchronously at yield-drop.
        let isCurrentReader = activeReaderOwnership?.identity == identity
        if !isCurrentReader, activeReaderOwnership != nil {
            // A newer reader owns the socket; do not tear it down for a stale overflow.
            return
        }
        if !streamFinished {
            logger.error("BootstrapSocketMCPTransport receive buffer overflow; terminating connection")
        }
        tearDownSocket(error: error)
    }

    private func tearDownSocket(error: Swift.Error? = nil) {
        isConnected = false
        if !socketClosed {
            POSIXDescriptorSupport.shutdownSocketReadWrite(socketFD)
        }

        stopReadSource()
        finishStreamIfNeeded(throwing: error)
        if !pendingReaderCancellationOwnsCurrentSocket() {
            closeSocketIfNeeded()
        }
    }

    private func finishStreamIfNeeded(throwing error: Swift.Error? = nil) {
        guard !streamFinished else { return }
        streamFinished = true
        // Prefer a synchronously recorded overflow cause over a racing EOF/nil teardown.
        let resolvedError = ingressGate.authoritativeTerminalError() ?? error
        ingressGate.markTerminal(error: resolvedError)

        if let resolvedError {
            messageContinuation.finish(throwing: resolvedError)
        } else {
            messageContinuation.finish()
        }
    }

    private func closeSocketIfNeeded() {
        guard !socketClosed else { return }
        socketClosed = true
        POSIXDescriptorSupport.shutdownSocketReadWrite(socketFD)
        Darwin.close(socketFD)
        #if DEBUG
            debugDescriptorCloseCount += 1
        #endif
    }
}
