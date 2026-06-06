//
//  UnixSocketMCPTransport.swift
//  RepoPrompt
//
//  UNIX domain socket transport for local MCP connections.
//  Uses DispatchSourceRead for event-driven I/O (no polling).
//

import Foundation
import Logging
import MCP
import RepoPromptShared

#if DEBUG
    private var unixSocketMCPTransportDebugLoggingEnabled = ProcessInfo.processInfo.environment["REPOPROMPT_MCP_DEBUG"] == "1"
    private func unixSocketMCPTransportDebugLog(_ message: @autoclosure () -> String) {
        guard unixSocketMCPTransportDebugLoggingEnabled else { return }
        print("[UnixSocketMCPTransport] \(message())")
    }
#else
    private func unixSocketMCPTransportDebugLog(_ message: @autoclosure () -> String) {}
#endif

private final class MCPTransportIngressGate: @unchecked Sendable {
    enum OfferResult {
        case accepted
        case overflow(MCPReceiveBufferOverflowError)
        case terminal
    }

    private let lock = NSLock()
    private let capacity: Int
    private var acceptedFrameCount = 0
    private var droppedFrameCount = 0
    private var highWaterMark = 0
    private var isTerminal = false
    private var terminalCause: MCPTransportTerminalCause?

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func offer(
        _ frame: Data,
        to continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    ) -> OfferResult {
        lock.lock()
        defer { lock.unlock() }

        guard !isTerminal else {
            return .terminal
        }

        switch continuation.yield(frame) {
        case let .enqueued(remainingCapacity):
            acceptedFrameCount += 1
            highWaterMark = max(highWaterMark, capacity - remainingCapacity)
            return .accepted
        case .dropped:
            droppedFrameCount += 1
            highWaterMark = capacity
            isTerminal = true
            terminalCause = .receiveBufferOverflow
            return .overflow(MCPReceiveBufferOverflowError(
                capacity: capacity,
                highWaterMark: highWaterMark
            ))
        case .terminated:
            isTerminal = true
            return .terminal
        @unknown default:
            isTerminal = true
            return .terminal
        }
    }

    func closeAndSnapshot() -> MCPTransportIngressSnapshot {
        lock.lock()
        isTerminal = true
        let snapshot = makeSnapshot()
        lock.unlock()
        return snapshot
    }

    func snapshot() -> MCPTransportIngressSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return makeSnapshot()
    }

    private func makeSnapshot() -> MCPTransportIngressSnapshot {
        MCPTransportIngressSnapshot(
            receiveBufferCapacity: capacity,
            acceptedFrameCount: acceptedFrameCount,
            droppedFrameCount: droppedFrameCount,
            receiveBufferHighWaterMark: highWaterMark,
            isTerminal: isTerminal,
            terminalCause: terminalCause
        )
    }
}

/// A Transport implementation using UNIX domain sockets for local MCP communication.
///
/// This transport connects to a UNIX socket created by the CLI within a connection folder.
/// It provides efficient, low-latency communication using event-driven I/O via
/// DispatchSourceRead, avoiding the CPU overhead of polling.
public actor UnixSocketMCPTransport: Transport {
    private let socketURL: URL?
    public let logger: Logger

    private var socketFD: Int32 = -1
    private var isConnected = false
    private var isStopping = false
    private var streamFinished = false

    /// If true, this transport was created with an existing FD (no connect needed)
    private let ownsExistingFD: Bool

    // Message stream for received data
    private nonisolated let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private var messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private let ingressGate: MCPTransportIngressGate

    // Close notification stream for cleanup signaling
    private nonisolated let closeStream: AsyncStream<Void>
    private var closeContinuation: AsyncStream<Void>.Continuation
    private var closeSignaled = false

    // Event-driven read source (replaces poll loop)
    private var reader: NewlineDelimitedSocketReader?
    private let readQueue = DispatchQueue(label: "com.repoprompt.mcp.unix.read", qos: .userInitiated)

    /// Track fd that the read source is bound to (helps avoid closing wrong fd on reuse)
    private var readSourceFD: Int32?
    private var readSourceToken: UInt64?
    private var readSourceSocketOwnershipGeneration: UInt64?
    private var nextReadSourceToken: UInt64 = 0

    /// Retains cancelled readers until their delayed cancel handlers perform final close.
    /// The transport retainer intentionally forms a temporary cycle so cleanup does not
    /// depend on an external manager keeping this actor alive after disconnect returns.
    private struct PendingReaderCancellation {
        let fd: Int32
        let socketOwnershipGeneration: UInt64
        let reader: NewlineDelimitedSocketReader
        let transportRetainer: UnixSocketMCPTransport
    }

    private var pendingReaderCancellations: [UInt64: PendingReaderCancellation] = [:]

    /// Changes whenever socketFD is replaced or synchronously closed.
    private var socketOwnershipGeneration: UInt64 = 0

    #if DEBUG
        /// Forces the adopted-FD startup path to fail after preparation but before reader ownership.
        private var failNextExistingFDConnectBeforeReaderStart = false
        /// Leaves a selected overflow pending so tests can race it with another teardown path.
        private var deferNextReceiveOverflowTeardown = false
    #endif

    /// Generation counter that increments on each connection close/open cycle.
    /// Used to detect FD reuse races in the write path.
    private var fdGeneration: UInt64 = 0

    private var lastActivityTime: Date?

    /// Connection timeout when waiting for socket to appear and accept connections
    private let connectionTimeout: TimeInterval = 30.0

    /// Maximum time a write may make no forward progress before the connection is failed closed.
    private let writeStallTimeout: TimeInterval

    /// Maximum poll interval while waiting for socket writability under backpressure.
    private let writePollIntervalMilliseconds: Int32

    /// Retry interval when waiting for socket
    private let retryInterval: UInt64 = 50_000_000 // 50ms in nanoseconds

    /// Creates a transport that will connect to the given socket URL.
    public init(
        socketURL: URL,
        logger: Logger? = nil,
        writeStallTimeout: TimeInterval = 30.0,
        writePollIntervalMilliseconds: Int32 = 250,
        receiveBufferCapacity: Int = 1024
    ) {
        let sanitizedReceiveBufferCapacity = max(1, receiveBufferCapacity)
        self.socketURL = socketURL
        ownsExistingFD = false
        self.logger = Self.createLogger(logger)
        self.writeStallTimeout = writeStallTimeout
        self.writePollIntervalMilliseconds = Self.sanitizedWritePollIntervalMilliseconds(writePollIntervalMilliseconds)
        ingressGate = MCPTransportIngressGate(capacity: sanitizedReceiveBufferCapacity)

        // Initialize streams
        var msgCont: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        messageStream = AsyncThrowingStream(
            Data.self,
            bufferingPolicy: .bufferingOldest(sanitizedReceiveBufferCapacity)
        ) { continuation in
            msgCont = continuation
        }
        messageContinuation = msgCont

        var closeCont: AsyncStream<Void>.Continuation!
        closeStream = AsyncStream(Void.self) { continuation in
            closeCont = continuation
        }
        closeContinuation = closeCont
    }

    /// Creates a transport using an already-connected file descriptor.
    /// Use this when accepting connections from BootstrapSocketServer.
    /// - Parameters:
    ///   - connectedFD: An already-connected UNIX socket file descriptor
    ///   - logger: Optional logger
    public init(
        connectedFD: Int32,
        logger: Logger? = nil,
        writeStallTimeout: TimeInterval = 30.0,
        writePollIntervalMilliseconds: Int32 = 250,
        receiveBufferCapacity: Int = 1024
    ) throws {
        let sanitizedReceiveBufferCapacity = max(1, receiveBufferCapacity)
        do {
            try POSIXDescriptorSupport.setCloseOnExec(connectedFD)
        } catch {
            POSIXDescriptorSupport.shutdownSocketReadWrite(connectedFD)
            if connectedFD >= 0 {
                Darwin.close(connectedFD)
            }
            throw error
        }

        socketURL = nil
        socketFD = connectedFD
        ownsExistingFD = true
        isConnected = false
        self.logger = Self.createLogger(logger)
        self.writeStallTimeout = writeStallTimeout
        self.writePollIntervalMilliseconds = Self.sanitizedWritePollIntervalMilliseconds(writePollIntervalMilliseconds)
        ingressGate = MCPTransportIngressGate(capacity: sanitizedReceiveBufferCapacity)

        // Initialize streams
        var msgCont: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        messageStream = AsyncThrowingStream(
            Data.self,
            bufferingPolicy: .bufferingOldest(sanitizedReceiveBufferCapacity)
        ) { continuation in
            msgCont = continuation
        }
        messageContinuation = msgCont

        var closeCont: AsyncStream<Void>.Continuation!
        closeStream = AsyncStream(Void.self) { continuation in
            closeCont = continuation
        }
        closeContinuation = closeCont
    }

    private static func createLogger(_ logger: Logger?) -> Logger {
        var l = logger ?? Logger(label: "com.repoprompt.mcp.unix.transport") {
            _ in SwiftLogNoOpLogHandler()
        }
        #if DEBUG
            l.logLevel = unixSocketMCPTransportDebugLoggingEnabled ? .debug : .notice
        #else
            l.logLevel = .notice
        #endif
        return l
    }

    private nonisolated static func sanitizedWritePollIntervalMilliseconds(_ value: Int32) -> Int32 {
        max(1, value)
    }

    // MARK: - Transport Protocol

    /// Connects to the UNIX socket, waiting for it to appear if necessary.
    /// If this transport was created with an existing FD, this just starts the read source.
    public func connect() async throws {
        if ownsExistingFD {
            try connectExistingFD()
            return
        }

        guard !isConnected else { return }

        guard let socketURL else {
            throw MCPError.internalError("No socket URL and no existing FD")
        }

        unixSocketMCPTransportDebugLog("connecting to \(socketURL.path)")

        isStopping = false
        streamFinished = false
        closeSignaled = false

        // Wait for socket file to appear and connect
        let startTime = Date()
        var lastError: Swift.Error?

        while Date().timeIntervalSince(startTime) < connectionTimeout {
            if Task.isCancelled {
                throw MCPError.connectionClosed
            }

            // Check if socket file exists
            if FileManager.default.fileExists(atPath: socketURL.path) {
                do {
                    try connectToSocket()

                    // Start event-driven read source (replaces poll loop) before marking connected.
                    try startReadSource(fd: socketFD)
                    isConnected = true
                    lastActivityTime = Date()

                    unixSocketMCPTransportDebugLog("connected successfully")
                    return
                } catch let error as POSIXError where error.code == .ECONNREFUSED || error.code == .ENOENT {
                    // Socket exists but not ready yet, or was removed - retry
                    lastError = error
                } catch {
                    // Other error - fail this connection attempt cleanly.
                    tearDownSocket(error: error)
                    throw error
                }
            }

            // Wait before retrying
            try? await Task.sleep(nanoseconds: retryInterval)
        }

        // Timeout reached
        logger.error("UnixSocketMCPTransport connection timeout after \(connectionTimeout)s")
        throw lastError ?? MCPError.internalError("Timeout connecting to UNIX socket at \(socketURL.path)")
    }

    /// Disconnects from the UNIX socket.
    /// Order: shutdown socket → cancel reader → close directly only when no reader owns cleanup.
    public func disconnect() async {
        guard isConnected || !isStopping else { return }

        mcpConnectionLog("UnixSocketMCPTransport disconnecting")
        tearDownSocket(error: MCPError.connectionClosed)
        mcpConnectionLog("UnixSocketMCPTransport disconnect requested")
    }

    /// Sends a message through the socket.
    public func send(_ message: Data) async throws {
        mcpTransportLog("UnixSocketMCPTransport send called with \(message.count) bytes")
        guard isConnected, socketFD >= 0 else {
            logger.error("UnixSocketMCPTransport send failed: not connected (isConnected=\(isConnected), socketFD=\(socketFD))")
            throw MCPError.connectionClosed
        }

        let framed = Self.frameWithNewlineIfNeeded(message)

        try await writeAll(framed)
        lastActivityTime = Date()
        mcpTransportLog("UnixSocketMCPTransport sent \(framed.count) bytes successfully")
    }

    /// Appends a newline delimiter if the message doesn't already end with one.
    /// This makes framing idempotent so callers don't need to know whether the
    /// transport adds a newline — sending pre-framed or unframed data is equally safe.
    private nonisolated static func frameWithNewlineIfNeeded(_ data: Data) -> Data {
        guard data.last != UInt8(ascii: "\n") else { return data }
        var framed = Data()
        framed.reserveCapacity(data.count + 1)
        framed.append(data)
        framed.append(UInt8(ascii: "\n"))
        return framed
    }

    /// Returns the async stream of received messages.
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messageStream
    }

    /// Returns the close notification stream.
    /// Use this to detect when the socket closes so connections can be cleaned up promptly.
    public func closed() -> AsyncStream<Void> {
        closeStream
    }

    func ingressSnapshot() -> MCPTransportIngressSnapshot {
        ingressGate.snapshot()
    }

    /// Returns seconds since last activity, or nil if never active.
    public func secondsSinceLastActivity() -> TimeInterval? {
        guard let lastActivityTime else { return nil }
        return Date().timeIntervalSince(lastActivityTime)
    }

    // MARK: - Private Implementation

    /// Connects to the UNIX socket at socketURL.
    private func connectToSocket() throws {
        guard let socketURL else {
            throw MCPError.internalError("No socket URL configured")
        }

        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }

        do {
            try POSIXDescriptorSupport.setCloseOnExec(fd)
        } catch {
            Darwin.close(fd)
            throw error
        }

        // Set up socket address
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw MCPError.internalError("Socket path too long: \(path)")
        }

        // Copy path to sun_path without raw-pointer rebinding/casts.
        var sunPath = addr.sun_path
        let sunPathSize = MemoryLayout.size(ofValue: sunPath)
        path.withCString { cstr in
            withUnsafeMutablePointer(to: &sunPath.0) { dst in
                // Safer than strcpy; always NUL-terminates.
                _ = Darwin.strlcpy(dst, cstr, sunPathSize)
            }
        }
        addr.sun_path = sunPath

        // Connect
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }

        if result < 0 {
            let err = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .ECONNREFUSED)
        }

        // Disable SIGPIPE on this socket
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Set non-blocking mode for non-blocking writes
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        socketOwnershipGeneration &+= 1
        socketFD = fd
    }

    /// Closes the socket if open. Callers that own teardown must issue shutdown first.
    private func closeSocket() {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
            socketOwnershipGeneration &+= 1
        }
    }

    /// Wakes blocked I/O and deterministically transfers final-close responsibility.
    /// If a reader exists, its cancel handler remains the sole final-close owner to
    /// avoid a stale callback closing a reused descriptor number.
    private func tearDownSocket(error proposedError: Swift.Error?) {
        guard !streamFinished else { return }
        let ingressSnapshot = ingressGate.closeAndSnapshot()
        let resolvedError: Swift.Error? = if ingressSnapshot.terminalCause == .receiveBufferOverflow {
            MCPReceiveBufferOverflowError(
                capacity: ingressSnapshot.receiveBufferCapacity,
                highWaterMark: ingressSnapshot.receiveBufferHighWaterMark
            )
        } else {
            proposedError
        }
        if ingressSnapshot.terminalCause == .receiveBufferOverflow {
            logger.error("UnixSocketMCPTransport ingress terminated: \(String(describing: resolvedError))")
        }
        isConnected = false
        isStopping = true

        if socketFD >= 0 {
            POSIXDescriptorSupport.shutdownSocketReadWrite(socketFD)
        }
        stopReadSource()
        if !pendingReaderCancellationOwnsCurrentSocket() {
            closeSocket()
        }
        transitionToClosed(error: resolvedError)
    }

    private func connectExistingFD() throws {
        if isConnected {
            guard reader != nil else {
                let error = MCPError.connectionClosed
                tearDownSocket(error: error)
                throw error
            }
            return
        }

        guard !streamFinished, !closeSignaled, socketFD >= 0 else {
            let error = MCPError.connectionClosed
            tearDownSocket(error: error)
            throw error
        }

        do {
            try ReadSourceFDPreflight.validateOpenFD(socketFD, label: "UnixSocketMCPTransport existing socket")
            try Self.ensureNonBlocking(fd: socketFD)

            // Disable SIGPIPE on this socket.
            var noSigPipe: Int32 = 1
            setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            #if DEBUG
                if failNextExistingFDConnectBeforeReaderStart {
                    failNextExistingFDConnectBeforeReaderStart = false
                    throw DebugExistingFDConnectFailure()
                }
            #endif

            try startReadSource(fd: socketFD)
            isConnected = true
            isStopping = false
            lastActivityTime = Date()
            unixSocketMCPTransportDebugLog("started with existing FD \(socketFD)")
        } catch {
            tearDownSocket(error: error)
            throw error
        }
    }

    #if DEBUG
        private struct DebugExistingFDConnectFailure: Swift.Error {}

        func debugSocketHasCloseOnExec() -> Bool? {
            guard socketFD >= 0 else { return nil }
            let flags = fcntl(socketFD, F_GETFD)
            guard flags >= 0 else { return nil }
            return flags & FD_CLOEXEC != 0
        }

        func debugFailNextExistingFDConnectBeforeReaderStart() {
            failNextExistingFDConnectBeforeReaderStart = true
        }

        func debugDeferNextReceiveOverflowTeardown() {
            deferNextReceiveOverflowTeardown = true
        }
    #endif

    private nonisolated static func ensureNonBlocking(fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else {
            throw MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EBADF))
        }
        guard flags & O_NONBLOCK == 0 else { return }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        }
    }

    /// Writes all data to the socket, handling partial writes.
    /// Uses non-blocking writes plus bounded POLLOUT waits for backpressure.
    /// The stall deadline resets whenever any bytes are successfully written.
    /// Guards against FD reuse races by checking fdGeneration after each sleep.
    private func writeAll(_ data: Data) async throws {
        // Fast-fail if we're obviously disconnected
        guard isConnected, socketFD >= 0 else {
            throw MCPError.connectionClosed
        }

        // Capture the FD and the connection generation at the time this write starts.
        // fdGeneration protects against FD reuse; if the connection closes and
        // reconnects (possibly with the same FD number), generation will differ.
        let fd = socketFD
        let gen = fdGeneration
        do {
            try Self.ensureNonBlocking(fd: fd)
        } catch {
            closeAfterSendFailure(error)
            throw error
        }
        var remaining = data
        var lastProgressAt = Date()

        while !remaining.isEmpty {
            // Re-check that we're still talking to the same connection epoch.
            guard isConnected, fdGeneration == gen else {
                throw MCPError.connectionClosed
            }
            if Date().timeIntervalSince(lastProgressAt) >= writeStallTimeout {
                let error = MCPError.transportError(UnixSocketWriteStalledError(
                    stallTimeout: writeStallTimeout,
                    bytesRemaining: remaining.count,
                    totalBytes: data.count
                ))
                closeAfterSendFailure(error)
                throw error
            }

            let written = remaining.withUnsafeBytes { buf in
                Darwin.write(fd, buf.baseAddress!, buf.count)
            }

            if written < 0 {
                let err = errno
                if err == EINTR {
                    continue // Interrupted, retry
                } else if err == EAGAIN || err == EWOULDBLOCK {
                    try waitForSocketWritable(
                        fd: fd,
                        generation: gen,
                        lastProgressAt: lastProgressAt,
                        totalBytes: data.count,
                        bytesRemaining: remaining.count
                    )
                    continue
                } else if err == EPIPE || err == ECONNRESET {
                    closeAfterSendFailure(MCPError.connectionClosed)
                    throw MCPError.connectionClosed
                } else {
                    let error = MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO))
                    closeAfterSendFailure(error)
                    throw error
                }
            } else if written == 0 {
                // On sockets, a 0-length write generally means closed / unusable
                closeAfterSendFailure(MCPError.connectionClosed)
                throw MCPError.connectionClosed
            }

            remaining = remaining.dropFirst(written)
            lastProgressAt = Date()
        }
    }

    private func waitForSocketWritable(
        fd: Int32,
        generation: UInt64,
        lastProgressAt: Date,
        totalBytes: Int,
        bytesRemaining: Int
    ) throws {
        while true {
            guard isConnected, fdGeneration == generation else {
                throw MCPError.connectionClosed
            }

            let remainingStallSeconds = writeStallTimeout - Date().timeIntervalSince(lastProgressAt)
            if remainingStallSeconds <= 0 {
                let error = MCPError.transportError(UnixSocketWriteStalledError(
                    stallTimeout: writeStallTimeout,
                    bytesRemaining: bytesRemaining,
                    totalBytes: totalBytes
                ))
                closeAfterSendFailure(error)
                throw error
            }

            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let remainingMs = max(1, Int32(remainingStallSeconds * 1000))
            let pollTimeout = min(writePollIntervalMilliseconds, remainingMs)
            let result = poll(&pfd, 1, pollTimeout)

            if result < 0 {
                if errno == EINTR { continue }
                let error = MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
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
        logger.error("UnixSocketMCPTransport send failed; closing transport: \(String(describing: error))")
        tearDownSocket(error: error)
    }

    private struct UnixSocketWriteStalledError: Swift.Error, CustomStringConvertible {
        let stallTimeout: TimeInterval
        let bytesRemaining: Int
        let totalBytes: Int

        var description: String {
            "Unix socket write made no progress for \(stallTimeout)s (remaining \(bytesRemaining)/\(totalBytes) bytes)"
        }
    }

    // MARK: - DispatchSourceRead Event-Driven Receive

    /// Starts the DispatchSourceRead to receive data without polling.
    private func startReadSource(fd: Int32) throws {
        try ReadSourceFDPreflight.validateOpenFD(fd, label: "UnixSocketMCPTransport read socket")
        stopReadSource()

        // Track which FD this source is bound to
        nextReadSourceToken &+= 1
        let token = nextReadSourceToken
        readSourceFD = fd
        readSourceToken = token
        readSourceSocketOwnershipGeneration = socketOwnershipGeneration

        let cont = messageContinuation
        let ingressGate = ingressGate
        let log = logger

        let newReader = NewlineDelimitedSocketReader(
            fd: fd,
            queue: readQueue,
            logger: log,
            onFrame: { [weak self] frame in
                guard let self else { return }
                switch ingressGate.offer(frame, to: cont) {
                case .accepted:
                    mcpTransportLog("UnixSocketMCPTransport accepted message of \(frame.count) bytes")
                case let .overflow(error):
                    mcpConnectionLog("UnixSocketMCPTransport receive buffer overflow; terminating connection")
                    Task { await self.handleReceiveBufferOverflow(error) }
                case .terminal:
                    break
                }
            },
            onEOF: { hasResidual in
                mcpConnectionLog("UnixSocketMCPTransport received EOF")
                Task { self.handleReadEOF(hasResidualData: hasResidual) }
            },
            onError: { error in
                Task { self.handleReadError(error: error) }
            },
            onBytesRead: { Task { self.noteActivity() } },
            onCancel: { [weak self] in
                mcpConnectionLog("UnixSocketMCPTransport read source cancelled for fd=\(fd) token=\(token)")
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
            readSourceSocketOwnershipGeneration = nil
            throw error
        }
        mcpConnectionLog("UnixSocketMCPTransport read source started for fd=\(fd)")
    }

    /// Stops the read source. Does NOT close the FD - that happens in cancelHandler.
    private func stopReadSource() {
        guard let reader else { return }
        guard let fd = readSourceFD,
              let token = readSourceToken,
              let socketOwnershipGeneration = readSourceSocketOwnershipGeneration
        else {
            self.reader = nil
            readSourceFD = nil
            readSourceToken = nil
            readSourceSocketOwnershipGeneration = nil
            reader.stop()
            return
        }

        pendingReaderCancellations[token] = PendingReaderCancellation(
            fd: fd,
            socketOwnershipGeneration: socketOwnershipGeneration,
            reader: reader,
            transportRetainer: self
        )
        self.reader = nil
        readSourceFD = nil
        readSourceToken = nil
        readSourceSocketOwnershipGeneration = nil
        reader.stop()
        // Note: retained reader cleanup happens in readSourceDidCancel
    }

    private func pendingReaderCancellationOwnsCurrentSocket() -> Bool {
        pendingReaderCancellations.values.contains { ownership in
            ownership.fd == socketFD &&
                ownership.socketOwnershipGeneration == socketOwnershipGeneration
        }
    }

    /// Called by the read source's cancel handler. Closes the FD safely.
    private func readSourceDidCancel(fd: Int32, token: UInt64) {
        guard let ownership = pendingReaderCancellations.removeValue(forKey: token) else { return }
        guard ownership.fd == fd else {
            logger.error("UnixSocketMCPTransport reader cancellation fd mismatch for token=\(token)")
            return
        }

        if socketFD == fd, socketOwnershipGeneration != ownership.socketOwnershipGeneration {
            logger.warning("UnixSocketMCPTransport skipping stale reader cancellation close for reused fd=\(fd)")
            return
        }

        Darwin.close(fd)
        if socketFD == fd {
            socketFD = -1
            socketOwnershipGeneration &+= 1
        }
    }

    private func handleReceiveBufferOverflow(_ error: MCPReceiveBufferOverflowError) {
        guard !streamFinished else { return }
        #if DEBUG
            if deferNextReceiveOverflowTeardown {
                deferNextReceiveOverflowTeardown = false
                return
            }
        #endif
        tearDownSocket(error: error)
    }

    /// Called when read encounters an error.
    private func handleReadError(error: Swift.Error) {
        tearDownSocket(error: error)
    }

    /// Called when read encounters EOF.
    /// - Parameter hasResidualData: If true, buffer had incomplete frame data
    private func handleReadEOF(hasResidualData: Bool) {
        if hasResidualData {
            // Treat residual incomplete frame as a protocol error
            let truncationError = MCPError.internalError("Connection closed with incomplete frame data")
            tearDownSocket(error: truncationError)
        } else {
            tearDownSocket(error: nil)
        }
    }

    /// Single entry point for transitioning to closed state.
    /// Finishes streams and signals closed, idempotently.
    private func transitionToClosed(error: Swift.Error?) {
        isConnected = false

        // Increment generation to invalidate any in-flight writers.
        // This protects against FD reuse races where an old writer might
        // otherwise write to a new connection that happens to get the same FD.
        fdGeneration &+= 1

        finishStream(error: error)
        signalClosedOnce()
    }

    /// Updates the activity timestamp (called from read handler).
    private func noteActivity() {
        lastActivityTime = Date()
    }

    /// Finishes the message stream exactly once.
    private func finishStream(error: Swift.Error? = nil) {
        guard !streamFinished else { return }
        streamFinished = true
        if let error {
            messageContinuation.finish(throwing: error)
        } else {
            messageContinuation.finish()
        }
    }

    /// Signals the close stream exactly once.
    private func signalClosedOnce() {
        guard !closeSignaled else { return }
        closeSignaled = true
        closeContinuation.yield()
        closeContinuation.finish()
    }
}
