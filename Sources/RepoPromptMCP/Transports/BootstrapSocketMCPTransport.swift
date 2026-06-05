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
import RepoPromptPOSIXSupport
import RepoPromptShared
import SystemPackage

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// MCP Transport implementation for CLI that wraps an already-connected UNIX socket FD.
/// This is used after the bootstrap handshake completes to run MCP.Client over the socket.
public actor BootstrapSocketMCPTransport: Transport {
    private let socketFD: Int32
    public nonisolated let logger: Logger

    private var isConnected = false
    private var streamFinished = false
    private var socketClosed = false
    private var connectionAttempted = false

    private nonisolated let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private var messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    private var reader: NewlineDelimitedSocketReader?
    private let readQueue = DispatchQueue(label: "com.repoprompt.ce.mcp.cli.socket.read", qos: .userInitiated)
    private var readSourceFD: Int32?
    private var readSourceToken: UInt64?
    private var nextReadSourceToken: UInt64 = 0

    /// Retains cancelled readers until their delayed cancel handlers perform final close.
    /// The transport retainer intentionally forms a temporary cycle so cleanup does not
    /// depend on an external owner keeping this actor alive after disconnect returns.
    private struct PendingReaderCancellation {
        let fd: Int32
        let reader: NewlineDelimitedSocketReader
        let transportRetainer: BootstrapSocketMCPTransport
    }

    private var pendingReaderCancellations: [UInt64: PendingReaderCancellation] = [:]

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
        writeStallTimeout: TimeInterval = 30.0,
        writePollIntervalMilliseconds: Int32 = 250
    ) throws {
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

        // Create message stream (buffered to avoid unbounded growth if consumer is slow)
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        messageStream = AsyncThrowingStream(
            Data.self,
            bufferingPolicy: .bufferingOldest(1024)
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

        // Log what we're sending (debug only)
        if let jsonStr = String(data: message, encoding: .utf8) {
            logger.trace("send: \(String(jsonStr.prefix(200)))")
        }

        let framed = Self.frameWithNewlineIfNeeded(message)

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
                if err == EINTR { continue }
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
                if errno == EINTR { continue }
                let error = MCPError.transportError(Errno(rawValue: errno))
                closeAfterSendFailure(error)
                throw error
            }

            if result == 0 { continue }

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

    // MARK: - Private

    /// Starts the DispatchSourceRead to receive data without blocking the actor executor.
    private func startReadSource(fd: Int32) throws {
        try ReadSourceFDPreflight.validateOpenFD(fd, label: "BootstrapSocketMCPTransport read socket")
        stopReadSource()

        nextReadSourceToken &+= 1
        let token = nextReadSourceToken
        readSourceFD = fd
        readSourceToken = token

        let cont = messageContinuation
        let log = logger

        let newReader = NewlineDelimitedSocketReader(
            fd: fd,
            queue: readQueue,
            logger: log,
            onFrame: { frame in
                cont.yield(frame)
            },
            onEOF: { [weak self] hasResidual in
                Task { await self?.handleReadEOF(hasResidualData: hasResidual) }
            },
            onError: { [weak self] error in
                Task { await self?.handleReadError(error: error) }
            },
            onCancel: { [weak self] in
                Task { await self?.readSourceDidCancel(fd: fd, token: token) }
            }
        )

        reader = newReader
        do {
            try newReader.start()
        } catch {
            reader = nil
            readSourceFD = nil
            readSourceToken = nil
            throw error
        }
    }

    /// Stops the read source. FD is closed in cancel handler to avoid races.
    private func stopReadSource() {
        guard let reader else { return }
        guard let fd = readSourceFD, let token = readSourceToken else {
            self.reader = nil
            readSourceFD = nil
            readSourceToken = nil
            reader.stop()
            return
        }

        pendingReaderCancellations[token] = PendingReaderCancellation(
            fd: fd,
            reader: reader,
            transportRetainer: self
        )
        self.reader = nil
        readSourceFD = nil
        readSourceToken = nil
        reader.stop()
        // Note: retained reader cleanup happens in readSourceDidCancel.
    }

    private func pendingReaderCancellationOwnsCurrentSocket() -> Bool {
        pendingReaderCancellations.values.contains { $0.fd == socketFD }
    }

    private func readSourceDidCancel(fd: Int32, token: UInt64) {
        guard let ownership = pendingReaderCancellations.removeValue(forKey: token) else { return }
        guard ownership.fd == fd else {
            logger.error("BootstrapSocketMCPTransport reader cancellation fd mismatch for token=\(token)")
            return
        }
        closeSocketIfNeeded()
    }

    private func handleReadError(error: Swift.Error) {
        tearDownSocket(error: error)
    }

    private func handleReadEOF(hasResidualData: Bool) {
        if hasResidualData {
            let truncationError = MCPError.internalError("Connection closed with incomplete frame data")
            tearDownSocket(error: truncationError)
        } else {
            tearDownSocket()
        }
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

        if let error {
            messageContinuation.finish(throwing: error)
        } else {
            messageContinuation.finish()
        }
    }

    private func closeSocketIfNeeded() {
        guard !socketClosed else { return }
        socketClosed = true
        POSIXDescriptorSupport.shutdownSocketReadWrite(socketFD)
        Darwin.close(socketFD)
    }
}
