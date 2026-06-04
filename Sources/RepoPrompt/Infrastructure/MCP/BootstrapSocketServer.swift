//
//	BootstrapSocketServer.swift
//	RepoPrompt
//
//	Single app-owned UNIX socket server for MCP connections.
//	Replaces filesystem-based discovery with direct socket connection.
//

import Darwin
import Dispatch
import Foundation
import Logging

#if DEBUG
    private var bootstrapSocketServerDebugLoggingEnabled = ProcessInfo.processInfo.environment["REPOPROMPT_MCP_DEBUG"] == "1"
    private func bootstrapSocketServerLog(_ message: @autoclosure () -> String) {
        guard bootstrapSocketServerDebugLoggingEnabled else { return }
        print("[BootstrapSocketServer] \(message())")
    }
#else
    private func bootstrapSocketServerLog(_ message: @autoclosure () -> String) {}
#endif

// Note: MCPBootstrapRequest and MCPBootstrapResponse are defined in
// RepoPrompt/Shared/MCPBootstrapMessages.swift for sharing with the CLI.

// MARK: - Bootstrap Socket Server

/// Actor that manages the single bootstrap UNIX socket.
/// Accepts CLI connections and hands them off to ServerNetworkManager.
actor BootstrapSocketServer {
    private let socketURL: URL
    private let logger: Logger
    private let handshakeIOQueue = DispatchQueue(
        label: "com.repoprompt.mcp.bootstrap.handshake-io",
        qos: .userInitiated
    )

    private var listenFD: Int32 = -1
    private var isRunning = false
    private var acceptSource: DispatchSourceRead?

    /// Backpressure: cap the number of accepted sockets that are mid-handshake.
    /// Prevents FD exhaustion during connection storms.
    private let maxInFlightHandshakes: Int = 32
    private var inFlightHandshakes: Int = 0
    private var acceptSuspendedForBackpressure: Bool = false
    private var drainInProgress: Bool = false
    private var drainRequestedWhileBusy: Bool = false

    /// Result of connection admission decision
    struct Admission {
        let accepted: Bool
        /// Called after the bootstrap server successfully sends the accepted response.
        /// This is where MCP server startup should be scheduled.
        let postAccept: (@Sendable () async -> Void)?
        /// Called if we accepted (reserved capacity) but fail to send the "accepted" response.
        /// Used to release the reserved slot and clean up any pre-commit state.
        let onAcceptWriteFailed: (@Sendable () async -> Void)?
        /// Optional override rejection response
        let rejection: MCPBootstrapResponse?

        static func accept(
            postAccept: @escaping @Sendable () async -> Void,
            onAcceptWriteFailed: (@Sendable () async -> Void)? = nil
        ) -> Self {
            .init(accepted: true, postAccept: postAccept, onAcceptWriteFailed: onAcceptWriteFailed, rejection: nil)
        }

        static func reject(_ response: MCPBootstrapResponse? = nil) -> Self {
            .init(accepted: false, postAccept: nil, onAcceptWriteFailed: nil, rejection: response)
        }
    }

    /// Callback when a new CLI connects and completes handshake
    /// Parameters: (clientFD, sessionToken, clientPid, clientName)
    /// Returns: Admission decision with optional postAccept hook for MCP startup
    private var onNewConnection: ((Int32, String, Int, String?) async -> Admission)?

    init(socketURL: URL = MCPFilesystemConstants.bootstrapSocketURL(), logger: Logger? = nil) {
        self.socketURL = socketURL
        self.logger = {
            var l = logger ?? Logger(label: "com.repoprompt.mcp.bootstrap") {
                _ in SwiftLogNoOpLogHandler()
            }
            #if DEBUG
                l.logLevel = .debug
            #else
                l.logLevel = .notice
            #endif
            return l
        }()
    }

    /// Starts listening on the bootstrap socket.
    /// - Parameter onNewConnection: Callback invoked for each new CLI connection.
    ///   Return an Admission with postAccept closure for MCP startup.
    func start(onNewConnection: @escaping (Int32, String, Int, String?) async -> Admission) throws {
        #if DEBUG
            print("[MCPStartup] BootstrapSocketServer.start entered socket=\(socketURL.path)")
        #endif
        guard !isRunning else { return }

        self.onNewConnection = onNewConnection

        // Ensure socket directory exists with secure permissions
        MCPFilesystemConstants.ensureSocketDirectoryExists()
        #if DEBUG
            print("[MCPStartup] ensured socket dir=\(socketURL.deletingLastPathComponent().path) exists=\(FileManager.default.fileExists(atPath: socketURL.deletingLastPathComponent().path))")
        #endif

        // Remove stale socket if exists
        unlink(socketURL.path)

        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw BootstrapSocketError.socketCreationFailed(errno: errno)
        }

        // Disable SIGPIPE
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Bind to socket path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketURL.path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw BootstrapSocketError.pathTooLong
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            let bindErrno = errno
            #if DEBUG
                print("[MCPStartup] bind failed errno=\(bindErrno) socket=\(socketURL.path)")
            #endif
            Darwin.close(fd)
            throw BootstrapSocketError.bindFailed(errno: bindErrno)
        }

        // Listen with generous backlog for connection bursts
        guard listen(fd, 128) == 0 else {
            Darwin.close(fd)
            throw BootstrapSocketError.listenFailed(errno: errno)
        }

        // Set non-blocking for async accept
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        listenFD = fd
        isRunning = true

        #if DEBUG
            print("[MCPStartup] BootstrapSocketServer listening on \(socketURL.path)")
        #endif
        bootstrapSocketServerLog("BootstrapSocketServer listening on \(socketURL.path)")

        do {
            try startAcceptSource()
        } catch {
            stop()
            throw BootstrapSocketError.readSourceCreationFailed(reason: String(describing: error))
        }
    }

    /// Returns true when the server has an active listen socket.
    func isListening() -> Bool {
        isRunning && listenFD >= 0
    }

    /// Stops the bootstrap socket server.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        // IMPORTANT: If a DispatchSource is suspended, you must resume it before cancel/deinit
        // to avoid crashes from unbalanced suspend/resume.
        if acceptSuspendedForBackpressure {
            acceptSource?.resume()
            acceptSuspendedForBackpressure = false
        }

        acceptSource?.cancel()
        acceptSource = nil

        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }

        // Clean up socket file
        try? FileManager.default.removeItem(at: socketURL)

        bootstrapSocketServerLog("BootstrapSocketServer stopped")
    }

    // MARK: - Accept Loop

    private func startAcceptSource() throws {
        guard listenFD >= 0 else { return }
        guard acceptSource == nil else { return }

        let source = try ReadSourceFDPreflight.makeReadSource(
            fileDescriptor: listenFD,
            queue: DispatchQueue.global(qos: .userInitiated),
            label: "bootstrap listen socket"
        )

        // Keep the DispatchSource handler tiny; do the draining/backpressure in actor context.
        source.setEventHandler { [weak self] in
            Task { await self?.drainAcceptQueue() }
        }
        source.setCancelHandler { [weak self] in
            Task { await self?.acceptSourceDidCancel() }
        }

        acceptSource = source
        source.resume()
    }

    private func acceptSourceDidCancel() {
        bootstrapSocketServerLog("BootstrapSocketServer: accept source cancelled (isRunning=\(isRunning))")
        acceptSource = nil
        acceptSuspendedForBackpressure = false
        drainRequestedWhileBusy = false

        if isRunning, listenFD >= 0 {
            do {
                try startAcceptSource()
            } catch {
                logger.error("BootstrapSocketServer: failed to restart accept source: \(String(describing: error))")
            }
        }
    }

    /// Drain pending accepts with backpressure. Runs on the actor executor.
    private func drainAcceptQueue() {
        guard isRunning, listenFD >= 0 else { return }
        guard !drainInProgress else {
            drainRequestedWhileBusy = true
            return
        }
        drainInProgress = true
        defer {
            drainInProgress = false
            if drainRequestedWhileBusy {
                drainRequestedWhileBusy = false
                drainAcceptQueue()
            }
        }

        // If we're at capacity, suspend the accept source to avoid hot-spinning.
        guard inFlightHandshakes < maxInFlightHandshakes else {
            suspendAcceptSourceForBackpressureIfNeeded()
            return
        }

        while isRunning, listenFD >= 0, inFlightHandshakes < maxInFlightHandshakes {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let fd = listenFD
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(fd, sockaddrPtr, &clientAddrLen)
                }
            }

            if clientFD < 0 {
                let err = errno
                if err == EINTR { continue }
                if err == EAGAIN || err == EWOULDBLOCK { break }
                logger.error("BootstrapSocketServer: accept failed with errno \(err)")
                break
            }

            inFlightHandshakes += 1
            Task {
                await self.handleNewConnectionWithBackpressure(clientFD: clientFD)
            }
        }

        // If we hit the limit, suspend to avoid repeated readability callbacks.
        if inFlightHandshakes >= maxInFlightHandshakes {
            suspendAcceptSourceForBackpressureIfNeeded()
        }
    }

    private func suspendAcceptSourceForBackpressureIfNeeded() {
        guard !acceptSuspendedForBackpressure else { return }
        acceptSource?.suspend()
        acceptSuspendedForBackpressure = true
        bootstrapSocketServerLog("BootstrapSocketServer: accept source suspended (inFlightHandshakes=\(inFlightHandshakes))")
    }

    private func resumeAcceptSourceIfNeeded() {
        guard acceptSuspendedForBackpressure else { return }
        acceptSource?.resume()
        acceptSuspendedForBackpressure = false
        bootstrapSocketServerLog("BootstrapSocketServer: accept source resumed (inFlightHandshakes=\(inFlightHandshakes))")

        // Proactively drain again (don't rely on a fresh readability edge).
        drainAcceptQueue()
    }

    // MARK: - Health Diagnostics

    struct ListenerDiagnostics {
        let isRunning: Bool
        let listenFDValid: Bool
        let acceptSourceExists: Bool
        let acceptSuspendedForBackpressure: Bool
        let inFlightHandshakes: Int
        let maxInFlightHandshakes: Int
    }

    func diagnostics() -> ListenerDiagnostics {
        let fdValid: Bool = {
            guard listenFD >= 0 else { return false }
            if fcntl(listenFD, F_GETFL) >= 0 {
                return true
            }
            return errno != EBADF
        }()

        return ListenerDiagnostics(
            isRunning: isRunning,
            listenFDValid: fdValid,
            acceptSourceExists: acceptSource != nil,
            acceptSuspendedForBackpressure: acceptSuspendedForBackpressure,
            inFlightHandshakes: inFlightHandshakes,
            maxInFlightHandshakes: maxInFlightHandshakes
        )
    }

    func ensureAccepting() {
        guard isRunning, listenFD >= 0 else { return }
        if acceptSource == nil {
            do {
                try startAcceptSource()
            } catch {
                logger.error("BootstrapSocketServer: failed to ensure accept source: \(String(describing: error))")
            }
        }
        if acceptSuspendedForBackpressure, inFlightHandshakes < maxInFlightHandshakes {
            resumeAcceptSourceIfNeeded()
        }
    }

    private func handleNewConnectionWithBackpressure(clientFD: Int32) async {
        defer {
            if inFlightHandshakes > 0 { inFlightHandshakes -= 1 }
            // If we were paused and now have room, resume accepting.
            if inFlightHandshakes < maxInFlightHandshakes {
                resumeAcceptSourceIfNeeded()
            }
        }
        await handleNewConnection(clientFD: clientFD)
    }

    /// Handles a new client connection: read handshake, validate, callback.
    private func handleNewConnection(clientFD: Int32) async {
        bootstrapSocketServerLog("BootstrapSocketServer: new connection on fd \(clientFD)")
        guard isRunning else {
            Darwin.close(clientFD)
            return
        }

        // Set blocking mode for simpler handshake I/O
        let flags = fcntl(clientFD, F_GETFL)
        _ = fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK)

        // Disable SIGPIPE on client socket
        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Read handshake request (with timeout)
        guard let request = await readHandshakeRequestAsync(from: clientFD) else {
            logger.warning("BootstrapSocketServer: failed to read handshake from fd \(clientFD)")
            Darwin.close(clientFD)
            return
        }

        guard isRunning else {
            Darwin.close(clientFD)
            return
        }

        let peerPid = Self.peerPID(for: clientFD)
        let effectivePid = peerPid ?? request.clientPid
        if let peerPid, peerPid != request.clientPid {
            bootstrapSocketServerLog("BootstrapSocketServer: clientPid mismatch (request=\(request.clientPid), peer=\(peerPid)); using peer pid")
        }

        bootstrapSocketServerLog("BootstrapSocketServer: handshake from '\(request.clientName ?? "unknown")' session=\(request.sessionToken.prefix(8))...")

        // Validate protocol version
        guard request.protocolVersion == MCPBootstrapProtocol.currentVersion else {
            logger.warning("BootstrapSocketServer: protocol version mismatch (got \(request.protocolVersion), expected \(MCPBootstrapProtocol.currentVersion))")
            await sendResponseAsync(.rejected(reason: "Protocol version mismatch", errorCode: "protocol_version_mismatch"), to: clientFD)
            Darwin.close(clientFD)
            return
        }

        // Invoke callback to let ServerNetworkManager decide
        guard let handler = onNewConnection else {
            logger.error("BootstrapSocketServer: no connection handler registered")
            await sendResponseAsync(.rejected(reason: "Server not ready", errorCode: "server_not_ready"), to: clientFD)
            Darwin.close(clientFD)
            return
        }

        bootstrapSocketServerLog("BootstrapSocketServer: invoking handler for '\(request.clientName ?? "unknown")'...")
        let admission = await handler(clientFD, request.sessionToken, effectivePid, request.clientName)
        bootstrapSocketServerLog("BootstrapSocketServer: handler returned accepted=\(admission.accepted) for '\(request.clientName ?? "unknown")'")

        if admission.accepted {
            // CRITICAL: Send accepted response BEFORE starting MCP server
            // This ensures CLI receives "accepted" before we start reading MCP messages
            let writeOk = await sendResponseAsync(.accepted(), to: clientFD)
            guard writeOk else {
                logger.error("BootstrapSocketServer: failed to send accepted response, closing fd \(clientFD)")
                // Rollback: release reserved slot since we couldn't commit the connection
                if let rollback = admission.onAcceptWriteFailed {
                    await rollback()
                }
                Darwin.close(clientFD)
                return
            }
            bootstrapSocketServerLog("BootstrapSocketServer: accepted connection from '\(request.clientName ?? "unknown")'")

            // NOW it's safe to start MCP server - the CLI has received "accepted"
            if let postAccept = admission.postAccept {
                await postAccept()
            }
            // FD ownership transfers to whatever postAccept started
        } else {
            let response = admission.rejection ?? .rejected(reason: "Connection rejected", errorCode: "approval_denied")
            await sendResponseAsync(response, to: clientFD)
            Darwin.close(clientFD)
            bootstrapSocketServerLog("BootstrapSocketServer: rejected connection from '\(request.clientName ?? "unknown")'")
        }
    }

    // MARK: - Handshake I/O

    /// Reads the handshake request from the client socket.
    /// Format: newline-delimited JSON (same as MCP protocol)
    private func readHandshakeRequestAsync(from fd: Int32) async -> MCPBootstrapRequest? {
        await withCheckedContinuation { continuation in
            handshakeIOQueue.async {
                continuation.resume(returning: Self.readHandshakeRequestBlocking(from: fd))
            }
        }
    }

    private nonisolated static func readHandshakeRequestBlocking(from fd: Int32) -> MCPBootstrapRequest? {
        var buffer = Data()
        var byte: UInt8 = 0

        // Read exactly through the bootstrap newline. Do not bulk-read here: any
        // bytes after the newline belong to the MCP transport on the same socket.
        let deadline = Date().addingTimeInterval(MCPBootstrapTiming.initialResponseTimeout)

        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(deadline.timeIntervalSinceNow * 1000)
            let pollResult = poll(&pfd, 1, max(0, remaining))

            if pollResult <= 0 {
                if pollResult < 0, errno != EINTR {
                    return nil
                }
                continue
            }

            let bytesRead = Darwin.read(fd, &byte, 1)
            if bytesRead <= 0 {
                return nil
            }

            if byte == UInt8(ascii: "\n") {
                return try? JSONDecoder().decode(MCPBootstrapRequest.self, from: buffer)
            }

            buffer.append(byte)

            // Sanity check - handshake shouldn't be huge
            if buffer.count > 8192 {
                return nil
            }
        }

        return nil
    }

    /// Returns the peer PID for a connected unix domain socket, if available.
    private static func peerPID(for fd: Int32) -> Int? {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len)
        guard result == 0, pid > 0 else { return nil }
        return Int(pid)
    }

    /// Sends a handshake response to the client socket.
    /// Returns true if the full response was written successfully.
    /// Uses SO_SNDTIMEO for bounded writes - if the client isn't reading, we fail fast.
    @discardableResult
    private func sendResponseAsync(_ response: MCPBootstrapResponse, to fd: Int32) async -> Bool {
        guard let jsonData = try? JSONEncoder().encode(response) else {
            logger.error("BootstrapSocketServer: failed to encode response")
            return false
        }

        var payload = jsonData
        payload.append(UInt8(ascii: "\n"))

        // Set 5 second send timeout (socket is already in blocking mode)
        // This ensures we don't block forever if client stops reading
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let bytes = [UInt8](payload)
        var totalWritten = 0

        while totalWritten < bytes.count {
            if Task.isCancelled {
                shutdown(fd, SHUT_RDWR)
                return false
            }

            let written = bytes.withUnsafeBytes { buf in
                let ptr = buf.baseAddress!.advanced(by: totalWritten)
                return Darwin.write(fd, ptr, bytes.count - totalWritten)
            }

            if written > 0 {
                totalWritten += written
                continue
            }

            let err = errno
            if err == EINTR { continue }

            // Timeout (EAGAIN with SO_SNDTIMEO) or error
            // shutdown() wakes any blocked I/O and signals the other end
            logger.error("BootstrapSocketServer: write failed (errno=\(err))")
            shutdown(fd, SHUT_RDWR)
            return false
        }

        return true
    }
}

// MARK: - Errors

enum BootstrapSocketError: Error {
    case socketCreationFailed(errno: Int32)
    case pathTooLong
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case readSourceCreationFailed(reason: String)
}
