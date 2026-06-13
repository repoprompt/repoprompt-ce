import Dispatch
import Foundation
import Logging
import MCP
import RepoPromptShared
import ServiceLifecycle
import SystemPackage

// MARK: - Version Constants

/// Update this when releasing new versions
let CLI_VERSION = "1.0.15"

/// CLI verbose mode - controls debug output (enabled by --verbose flag)
var cliVerboseMode = false

let log: Logger = {
    var logger = Logger(label: "com.repoprompt.ce.mcp.cli") {
        StreamLogHandler.standardError(label: $0)
    }
    // Default to warning level - --verbose will enable more output
    logger.logLevel = .warning
    return logger
}()

/// File-based debug logging for socket proxy debugging
/// Enable via: defaults write com.repoprompt.ce.mcp enableSocketDebugLog -bool true
private let enableSocketDebugLog: Bool = ProcessInfo.processInfo.environment["MCP_SOCKET_DEBUG"] == "1" ||
    UserDefaults.standard.bool(forKey: "enableSocketDebugLog")

private let debugLogURL: URL = {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/RepoPrompt CE/socket-proxy-debug.log")
    guard enableSocketDebugLog else { return url }
    // Create directory if needed
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    // Clear old log on startup
    try? "".write(to: url, atomically: true, encoding: .utf8)
    return url
}()

func debugLog(_ message: @autoclosure () -> String) {
    guard enableSocketDebugLog else { return }
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message())\n"
    if let data = line.data(using: .utf8),
       let handle = try? FileHandle(forWritingTo: debugLogURL)
    {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        // First write or file doesn't exist
        try? line.write(to: debugLogURL, atomically: false, encoding: .utf8)
    }
}

enum MCPCLIExitCode: Int32 {
    case ok = 0
    case connectionFailed = 73
    case approvalDenied = 74
    case terminatedByServer = 76 // Server explicitly terminated this connection
    case unknownError = 1
}

enum CLIRuntimeError: Swift.Error {
    case connectionFailed(underlying: Swift.Error)
    case approvalDenied
    case terminatedByServer(reason: String?)
    case hostDisconnected // Stdin closed or stdout broken pipe
}

// ────────────────────────────────────────────────────────────
// CLI Event Logger - writes error events to Application Support
// for the app to surface when network connections fail
// ────────────────────────────────────────────────────────────

enum CLIEventLogger {
    /// Events directory - uses shared constant for consistent gating by build flavor and version
    private static let eventsDir: URL = MCPFilesystemConstants.eventsDirectoryURL()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Returns the parent process executable name for initial connection identification.
    /// The MCP protocol handshake name is authoritative for final client identity.
    static func detectClientName() -> String? {
        let parentPID = getppid()
        debugLog("detectClientName: parentPID=\(parentPID)")
        var name = [CChar](repeating: 0, count: 1024)
        var size = name.count

        var mib = [CTL_KERN, KERN_PROCARGS2, parentPID]
        guard sysctl(&mib, 3, &name, &size, nil, 0) == 0 else {
            debugLog("detectClientName: sysctl failed for parentPID=\(parentPID), errno=\(errno)")
            return nil
        }

        let pathStart = name.dropFirst(4).firstIndex(where: { $0 != 0 }) ?? 4
        let execPath = name.withUnsafeBufferPointer { buffer in
            String(cString: buffer.baseAddress!.advanced(by: pathStart))
        }
        guard !execPath.isEmpty else {
            debugLog("detectClientName: execPath empty for parentPID=\(parentPID)")
            return nil
        }

        // Return raw executable name - let MCP protocol name be authoritative
        let result = URL(fileURLWithPath: execPath).lastPathComponent
        debugLog("detectClientName: execPath='\(execPath)' result='\(result)'")
        return result
    }

    /// Determines if an error should be persisted as an event file.
    /// Expected terminations (host disconnect, server termination) should not surface as errors.
    static func shouldPersistEvent(for err: CLIRuntimeError) -> Bool {
        switch err {
        case .hostDisconnected, .terminatedByServer:
            // These are expected/clean terminations, not actionable errors
            false
        case .connectionFailed, .approvalDenied:
            true
        }
    }

    /// Logs a runtime error event to disk
    static func logRuntimeError(_ err: CLIRuntimeError) {
        guard shouldPersistEvent(for: err) else { return }
        let (code, message, details) = mapRuntimeError(err)
        let detectedClient = detectClientName()
        log.debug("Writing runtime error event for client: \(detectedClient ?? "unknown")")
        let event = MCPExternalClientEvent(
            id: UUID(),
            timestamp: Date(),
            source: .repopromptCLI,
            kind: .runtimeError,
            code: code,
            humanMessage: message,
            clientName: detectedClient,
            details: details
        )
        writeEvent(event)
    }

    private static func mapRuntimeError(_ err: CLIRuntimeError) -> (MCPExternalClientEvent.Code, String, [String: String]?) {
        switch err {
        case let .connectionFailed(underlying):
            var details: [String: String] = ["underlying": String(describing: underlying)]
            if let socketError = underlying as? SocketProxyError {
                switch socketError {
                case let .connectFailed(errno),
                     let .socketCreationFailed(errno),
                     let .descriptorConfigurationFailed(errno),
                     let .bindFailed(errno),
                     let .listenFailed(errno),
                     let .acceptFailed(errno),
                     let .writeFailed(errno),
                     let .readFailed(errno),
                     let .pollFailed(errno):
                    details["errno"] = String(errno)
                case .connectionRefused:
                    details["errno"] = String(ECONNREFUSED)
                case let .stdoutWriteTimeout(bytesWritten, totalBytes, stallTimeout):
                    details["layer"] = "stdout_bridge"
                    details["provenance"] = "local_timeout"
                    details["bytes_written"] = String(bytesWritten)
                    details["total_bytes"] = String(totalBytes)
                    details["stall_timeout_seconds"] = String(stallTimeout)
                case let .stdoutBrokenPipe(bytesWritten, totalBytes):
                    details["layer"] = "stdout_bridge"
                    details["provenance"] = "broken_pipe"
                    details["bytes_written"] = String(bytesWritten)
                    details["total_bytes"] = String(totalBytes)
                default:
                    break
                }
            }
            return (.connectionFailed, "Connection failed", details)
        case .approvalDenied:
            return (.approvalDenied, "Connection approval denied", nil)
        case let .terminatedByServer(reason):
            // Server explicitly terminated - this is expected behavior, not an error to surface
            return (.approvalDenied, reason ?? "Connection terminated by server", nil)
        case .hostDisconnected:
            return (.connectionFailed, "Host disconnected (stdin closed or stdout broken)", nil)
        }
    }

    private static func writeEvent(_ event: MCPExternalClientEvent) {
        do {
            // Ensure directory exists
            try FileManager.default.createDirectory(
                at: eventsDir,
                withIntermediateDirectories: true
            )

            // Generate filename with timestamp and UUID
            let timestamp = isoFormatter.string(from: event.timestamp)
                .replacingOccurrences(of: ":", with: "-")
            let filename = "cli-\(timestamp)-\(event.id.uuidString).json"
            let fileURL = eventsDir.appendingPathComponent(filename)

            // Encode and write atomically
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(event)
            try data.write(to: fileURL, options: .atomic)

            log.debug("Wrote error event to \(fileURL.path)")
        } catch {
            // Best-effort logging - don't fail the CLI if event logging fails
            log.warning("Failed to write error event: \(error)")
        }
    }
}

// ────────────────────────────────────────────────────────────
// Kill Signal Detection - monitors filesystem side-channel for
// server-initiated termination requests
// ────────────────────────────────────────────────────────────

enum CLIKillSignal {
    typealias SignalContent = MCPKillSignal.SignalContent
    typealias Reason = TerminationReason

    /// Directory where kill signal files are written by the app
    static var signalsDirectory: URL {
        MCPFilesystemConstants.identity.killSignalsDirectoryURL()
    }

    /// Kill signal file for a specific session token
    static func signalFileURL(forSessionToken token: String) -> URL {
        MCPKillSignal.signalFileURL(forSessionToken: token, directory: signalsDirectory)
    }

    /// Reads a kill signal if it exists for this session.
    static func readKillSignal(forSessionToken token: String) -> SignalContent? {
        MCPKillSignal.readKillSignal(forSessionToken: token, directory: signalsDirectory)
    }

    /// Removes a kill signal file after acknowledging it.
    static func removeKillSignal(forSessionToken token: String) {
        MCPKillSignal.removeKillSignal(forSessionToken: token, directory: signalsDirectory)
    }

    /// Returns a human-readable message for a termination reason.
    static func messageForReason(_ reason: Reason) -> String {
        switch reason {
        case .userBootFromDashboard:
            "Connection terminated by user from MCP dashboard"
        case .runCompleted:
            "Agent run completed successfully"
        case .runCancelled:
            "Agent run was cancelled"
        case .serverShutdown:
            "Server is shutting down"
        case .idleTimeout:
            "Connection closed due to idle timeout"
        case .approvalDenied:
            "Connection approval was denied"
        case .connectionReplaced:
            "Connection replaced by a newer connection"
        }
    }
}

// Note: TCP/Bonjour transport has been removed. CLI now uses bootstrap socket only.

// ────────────────────────────────────────────────────────────
// Protocol Version - must match app's MCPConstants.bootstrapProtocolVersion
// ────────────────────────────────────────────────────────────

/// Bootstrap socket protocol version.
/// Uses shared constant from MCPBootstrapMessages.swift for consistency with app.
let kBootstrapProtocolVersion = MCPBootstrapProtocol.currentVersion

// ────────────────────────────────────────────────────────────
// Client Identity Cache - stores MCP clientInfo.name across reconnects
// ────────────────────────────────────────────────────────────

/// Caches the MCP client identity (from the first `initialize` request) for use
/// in bootstrap handshakes on reconnect. This ensures the app sees the correct
/// client name (e.g., "Claude Code") even after transport reconnection.
actor ClientIdentityCache {
    private(set) var mcpClientName: String?

    /// Sets the cached name if not already set. Called when parsing MCP initialize.
    func setIfEmpty(_ name: String) {
        guard mcpClientName == nil else { return }
        mcpClientName = name
        debugLog("ClientIdentityCache: cached MCP client name: \(name)")
    }

    /// Returns the cached MCP client name, or nil if not yet captured.
    func currentName() -> String? {
        mcpClientName
    }
}

/// Socket proxy errors
enum SocketProxyError: Swift.Error, LocalizedError {
    case socketCreationFailed(errno: Int32)
    case descriptorConfigurationFailed(errno: Int32)
    case pathTooLong
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case acceptFailed(errno: Int32)
    case connectFailed(errno: Int32)
    case notListening
    case notConnected
    case connectionTimeout
    case bootstrapResponseTimeout
    case connectionReset
    case connectionRefused // App busy or not accepting connections
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case pollFailed(errno: Int32)
    case stdoutWriteTimeout(bytesWritten: Int, totalBytes: Int, stallTimeout: TimeInterval)
    case stdoutBrokenPipe(bytesWritten: Int, totalBytes: Int)
    case cancelled
    case serverClosed
    case approvalDenied
    case terminatedByServer(reason: String?)
    case handshakeFailed(reason: String)
    case handshakeRejected(errorCode: String?, reason: String?)
    case protocolVersionMismatch
    case hostDisconnected // Host process closed stdin or stdout pipe broken

    var errorDescription: String? {
        switch self {
        case let .socketCreationFailed(errno):
            return "Failed to create socket: \(errno)"
        case let .descriptorConfigurationFailed(errno):
            return "Failed to configure socket descriptor: \(errno)"
        case .pathTooLong:
            return "Socket path too long"
        case let .bindFailed(errno):
            return "Failed to bind socket: \(errno)"
        case let .listenFailed(errno):
            return "Failed to listen on socket: \(errno)"
        case let .acceptFailed(errno):
            return "Failed to accept connection: \(errno)"
        case let .connectFailed(errno):
            if errno == EPERM || errno == EACCES {
                return "Permission denied (errno \(errno)). If running in a sandboxed environment (e.g., Codex), disable sandbox or grant Unix socket access."
            } else if errno == ENOENT {
                return "Socket not found. Is RepoPrompt running with MCP enabled?"
            } else if errno == ECONNREFUSED {
                return "Connection refused. RepoPrompt may need to be restarted."
            }
            return "Failed to connect: \(errno)"
        case .notListening:
            return "Socket not listening"
        case .notConnected:
            return "Not connected"
        case .connectionTimeout:
            return "Connection timeout"
        case .bootstrapResponseTimeout:
            return "Timed out waiting for RepoPrompt bootstrap response"
        case .connectionReset:
            return "Connection reset"
        case .connectionRefused:
            return "Connection refused. RepoPrompt may be busy or restarting; try again."
        case let .writeFailed(errno):
            return "Write failed: \(errno)"
        case let .readFailed(errno):
            return "Read failed: \(errno)"
        case let .pollFailed(errno):
            return "Poll failed: \(errno)"
        case let .stdoutWriteTimeout(bytesWritten, totalBytes, stallTimeout):
            return "Stdout write timed out locally after no progress for \(stallTimeout)s (\(bytesWritten)/\(totalBytes) bytes written)"
        case let .stdoutBrokenPipe(bytesWritten, totalBytes):
            return "Stdout broken pipe (\(bytesWritten)/\(totalBytes) bytes written)"
        case .cancelled:
            return "Operation cancelled"
        case .serverClosed:
            return "Server closed connection"
        case .approvalDenied:
            return "Connection approval denied by user"
        case let .terminatedByServer(reason):
            return "Terminated by server: \(reason ?? "unknown reason")"
        case let .handshakeFailed(reason):
            return "Handshake failed: \(reason)"
        case let .handshakeRejected(errorCode, reason):
            let code = errorCode ?? "unknown"
            let message = reason ?? "Rejected by server"
            return "Handshake rejected (\(code)): \(message)"
        case .protocolVersionMismatch:
            return "Protocol version mismatch. Update the CLI or RepoPrompt app."
        case .hostDisconnected:
            return "Host disconnected"
        }
    }
}

// MARK: - Bootstrap Socket Proxy (CLI connects to App)

/// Bootstrap socket proxy - connects to app's single socket server.
/// Replaces the old filesystem-based discovery approach.
actor BootstrapSocketProxy {
    private let socketURL: URL
    private let sessionToken: String
    private let clientName: String?
    private let identityCache: ClientIdentityCache
    private let bridgeLedger: JSONRPCBridgeLedger
    private let faultRule: JSONRPCBridgeFaultRule?
    private var socketFD: Int32 = -1

    init(
        sessionToken: String,
        clientName: String?,
        identityCache: ClientIdentityCache,
        bridgeLedger: JSONRPCBridgeLedger,
        faultRule: JSONRPCBridgeFaultRule?
    ) {
        socketURL = MCPFilesystemConstants.bootstrapSocketURL()
        self.sessionToken = sessionToken
        self.clientName = clientName
        self.identityCache = identityCache
        self.bridgeLedger = bridgeLedger
        self.faultRule = faultRule
    }

    func start() async throws {
        // Connect to app's bootstrap socket
        try connectToSocket()

        defer {
            closeSocket()
        }

        // Send handshake request
        log.debug("BootstrapSocketProxy: Connected, sending handshake...")
        debugLog("Connected to bootstrap socket, sending handshake")
        try sendHandshakeRequest()

        // Wait for response
        let response = try await readHandshakeResponse(
            timeout: MCPBootstrapTiming.initialResponseTimeout
        )

        switch response.type {
        case "accepted":
            log.debug("BootstrapSocketProxy: Handshake accepted, starting bridge")
            debugLog("Handshake accepted, starting stdin/stdout bridge")

        case "rejected":
            log.warning("BootstrapSocketProxy: Handshake rejected: \(response.reason ?? "unknown")")
            if response.errorCode == MCPBootstrapErrorCode.approvalDenied.rawValue {
                throw SocketProxyError.approvalDenied
            }
            if response.errorCode == MCPBootstrapErrorCode.protocolVersionMismatch.rawValue {
                throw SocketProxyError.protocolVersionMismatch
            }
            throw SocketProxyError.handshakeRejected(errorCode: response.errorCode, reason: response.reason)

        default:
            throw SocketProxyError.handshakeFailed(reason: "Unknown response type: \(response.type)")
        }

        // Run the bidirectional bridge
        // IMPORTANT: Use static (non-actor) methods to avoid actor starvation.
        // The poll() in socket→stdout has no await points and would block the actor,
        // preventing stdin→socket from ever running again.
        let fd = socketFD
        let cache = identityCache
        let ledger = bridgeLedger
        let faultRule = faultRule
        try await Self.runBridge(
            socketFD: fd,
            identityCache: cache,
            bridgeLedger: ledger,
            faultRule: faultRule
        )
    }

    func stop() async {
        closeSocket()
    }

    // MARK: - Socket Connection

    private func connectToSocket() throws {
        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketProxyError.socketCreationFailed(errno: errno)
        }

        do {
            try POSIXDescriptorSupport.setCloseOnExec(fd)
        } catch let error as POSIXDescriptorConfigurationError {
            Darwin.close(fd)
            throw SocketProxyError.descriptorConfigurationFailed(errno: error.errnoValue)
        }

        // Disable SIGPIPE
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Set up socket address
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw SocketProxyError.pathTooLong
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }

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
            if err == ECONNREFUSED {
                let socketPath = socketURL.path
                if FileManager.default.fileExists(atPath: socketPath),
                   isUnixDomainSocket(atPath: socketPath)
                {
                    throw SocketProxyError.connectionRefused
                }
            }
            throw SocketProxyError.connectFailed(errno: err)
        }

        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        socketFD = fd
        log.debug("BootstrapSocketProxy: Connected to \(socketURL.path)")
    }

    private func closeSocket() {
        if socketFD >= 0 {
            POSIXDescriptorSupport.shutdownSocketReadWrite(socketFD)
            Darwin.close(socketFD)
            socketFD = -1
        }
    }

    private func isUnixDomainSocket(atPath path: String) -> Bool {
        var info = stat()
        if lstat(path, &info) != 0 {
            return false
        }
        return (info.st_mode & S_IFMT) == S_IFSOCK
    }

    /// Instance wrapper for static writeToSocket (used during handshake)
    private func writeToSocket(_ data: Data) throws {
        try Self.writeToSocket(data, socketFD: socketFD)
    }

    // MARK: - Handshake

    private func sendHandshakeRequest() throws {
        let request = MCPBootstrapRequest(
            sessionToken: sessionToken,
            clientPid: Int(getpid()),
            clientName: clientName ?? ProcessInfo.processInfo.processName,
            protocolVersion: kBootstrapProtocolVersion
        )

        guard let jsonData = try? JSONEncoder().encode(request) else {
            throw SocketProxyError.handshakeFailed(reason: "Failed to encode request")
        }

        var payload = jsonData
        payload.append(UInt8(ascii: "\n"))

        try writeToSocket(payload)
    }

    private func readHandshakeResponse(
        timeout: TimeInterval
    ) async throws -> MCPBootstrapResponse {
        var buffer = Data()
        let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { readBuffer.deallocate() }

        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            // Check for cancellation at the top of the loop for faster responsiveness
            if Task.isCancelled {
                throw SocketProxyError.cancelled
            }

            var pfd = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            // Poll timeout of 100ms balances cancellation responsiveness with CPU efficiency
            let remaining = Int32(deadline.timeIntervalSinceNow * 1000)
            let pollResult = poll(&pfd, 1, min(100, max(1, remaining)))

            if pollResult < 0 {
                if errno == EINTR { continue }
                throw SocketProxyError.pollFailed(errno: errno)
            }

            if pollResult == 0 {
                continue // Timeout, keep waiting
            }

            if pfd.revents & Int16(POLLHUP | POLLERR) != 0 {
                throw SocketProxyError.connectionReset
            }

            let bytesRead = Darwin.read(socketFD, readBuffer, 4096)
            if bytesRead <= 0 {
                if bytesRead < 0, errno == EAGAIN || errno == EINTR {
                    continue
                }
                throw SocketProxyError.serverClosed
            }

            buffer.append(readBuffer, count: bytesRead)

            // Check for complete message
            if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let jsonData = buffer[..<newlineIndex]
                guard let response = try? JSONDecoder().decode(MCPBootstrapResponse.self, from: Data(jsonData)) else {
                    throw SocketProxyError.handshakeFailed(reason: "Invalid response JSON")
                }
                return response
            }
        }

        throw SocketProxyError.bootstrapResponseTimeout
    }
}

// MARK: - Static Pump Methods (non-actor isolated to avoid starvation)

private enum BridgeTaskExit {
    case stdinClosed
    case socketClosed
}

enum BridgeSocketPollResult {
    case timedOut
    case events(Int16)
}

typealias BridgeSocketPoller = @Sendable (Int32) async throws -> BridgeSocketPollResult

private actor BridgeDrainState {
    typealias Clock = @Sendable () -> TimeInterval

    private let clock: Clock
    private var stdinClosedAt: TimeInterval?
    private var lastVisibilityLogAt: TimeInterval?

    init(clock: @escaping Clock) {
        self.clock = clock
    }

    func markStdinClosed() {
        if stdinClosedAt == nil {
            stdinClosedAt = clock()
        }
    }

    func elapsedSinceStdinClosed() -> TimeInterval? {
        guard let stdinClosedAt else { return nil }
        return max(0, clock() - stdinClosedAt)
    }

    func claimVisibilityLog(interval: TimeInterval) -> TimeInterval? {
        guard let stdinClosedAt else { return nil }
        let now = clock()
        if let lastVisibilityLogAt,
           now - lastVisibilityLogAt < max(0.001, interval)
        {
            return nil
        }
        lastVisibilityLogAt = now
        return max(0, now - stdinClosedAt)
    }
}

extension BootstrapSocketProxy {
    static func runBridge(
        socketFD: Int32,
        stdinFD: Int32 = STDIN_FILENO,
        stdoutFD: Int32 = STDOUT_FILENO,
        identityCache: ClientIdentityCache,
        bridgeLedger: JSONRPCBridgeLedger,
        faultRule: JSONRPCBridgeFaultRule?,
        socketPoller: BridgeSocketPoller? = nil,
        drainClock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        drainDeadline: TimeInterval = TimeInterval(MCPTimeoutPolicy.postStdinHalfCloseBridgeDrainDeadlineSeconds),
        drainVisibilityInterval: TimeInterval = 30,
        drainLogDescriptor: Int32 = STDERR_FILENO,
        onStdinClosed: @escaping @Sendable () async -> Void = {}
    ) async throws {
        let drainState = BridgeDrainState(clock: drainClock)
        try await withThrowingTaskGroup(of: BridgeTaskExit.self) { group in
            group.addTask {
                try await Self.pumpStdinToSocket(
                    socketFD: socketFD,
                    stdinFD: stdinFD,
                    identityCache: identityCache,
                    bridgeLedger: bridgeLedger,
                    faultRule: faultRule
                )
                await drainState.markStdinClosed()
                await onStdinClosed()
                return .stdinClosed
            }
            group.addTask {
                try await Self.pumpSocketToStdout(
                    socketFD: socketFD,
                    stdoutFD: stdoutFD,
                    drainState: drainState,
                    bridgeLedger: bridgeLedger,
                    faultRule: faultRule,
                    socketPoller: socketPoller,
                    drainDeadline: drainDeadline,
                    drainVisibilityInterval: drainVisibilityInterval,
                    drainLogDescriptor: drainLogDescriptor
                )
                return .socketClosed
            }

            var stdinClosed = false
            do {
                while let exit = try await group.next() {
                    switch exit {
                    case .stdinClosed:
                        stdinClosed = true
                    case .socketClosed:
                        group.cancelAll()
                        if stdinClosed {
                            return
                        }
                        throw SocketProxyError.serverClosed
                    }
                }
            } catch {
                let message = "[MCPBridge] task_failed error=\(error)\n"
                BestEffortStderrWriter.writeNonBlocking(
                    Data(message.utf8),
                    to: drainLogDescriptor
                )
                debugLog("BootstrapSocketProxy: Bridge task failed: \(error)")
                group.cancelAll()
                throw error
            }
        }
    }

    /// Pumps stdin to socket. Static to run outside actor isolation.
    /// Also parses MCP initialize requests to cache the client name for reconnects.
    private static func pumpStdinToSocket(
        socketFD: Int32,
        stdinFD: Int32 = STDIN_FILENO,
        identityCache: ClientIdentityCache,
        bridgeLedger: JSONRPCBridgeLedger,
        faultRule: JSONRPCBridgeFaultRule?
    ) async throws {
        let flags = fcntl(stdinFD, F_GETFL)
        if flags >= 0 {
            _ = fcntl(stdinFD, F_SETFL, flags | O_NONBLOCK)
        }
        debugLog("BootstrapSocketProxy: pumpStdinToSocket started")

        var buffer = [UInt8](repeating: 0, count: 8192)
        var pending = Data()
        var hasCachedIdentity = false // Stop parsing after first capture

        while !Task.isCancelled {
            var pfd = pollfd(fd: stdinFD, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&pfd, 1, 1000)

            if pollResult < 0 {
                if errno == EINTR { continue }
                throw SocketProxyError.pollFailed(errno: errno)
            }
            if pollResult == 0 { continue }

            let revents = Int32(pfd.revents)
            if revents & (POLLERR | POLLNVAL) != 0 {
                debugLog("BootstrapSocketProxy: stdin error - host disconnected")
                throw SocketProxyError.hostDisconnected
            }
            let sawHangup = revents & POLLHUP != 0
            if revents & POLLIN == 0 {
                if sawHangup {
                    debugLog("BootstrapSocketProxy: stdin hangup after draining input")
                    try await requireCleanBridgeStop(
                        ledger: bridgeLedger,
                        direction: .clientToServer,
                        pendingByteCount: pending.count,
                        reason: "stdin_hangup"
                    )
                    return
                }
                continue
            }

            let bytesRead = buffer.withUnsafeMutableBufferPointer { ptr in
                Darwin.read(stdinFD, ptr.baseAddress!, ptr.count)
            }

            if bytesRead < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw SocketProxyError.readFailed(errno: errno)
            }
            if bytesRead == 0 {
                debugLog("BootstrapSocketProxy: stdin EOF after draining input")
                try await requireCleanBridgeStop(
                    ledger: bridgeLedger,
                    direction: .clientToServer,
                    pendingByteCount: pending.count,
                    reason: "stdin_eof"
                )
                return
            }

            pending.append(contentsOf: buffer[0 ..< bytesRead])
            debugLog("BootstrapSocketProxy: read \(bytesRead) bytes from stdin, pending=\(pending.count)")

            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let message = pending[..<newline]
                pending = Data(pending[(newline + 1)...])

                // Parse MCP initialize to extract clientInfo.name (best-effort, once only)
                if !hasCachedIdentity, let name = extractMCPClientName(from: Data(message)) {
                    hasCachedIdentity = true
                    await identityCache.setIfEmpty(name)
                }

                var payload = Data(message)
                payload.append(UInt8(ascii: "\n"))
                debugLog("BootstrapSocketProxy: → socket bytes=\(payload.count) sha256=\(MCPResponseDeliveryTracer.sha256Hex(payload))")
                let prepared = try await JSONRPCBridgeDelivery.forward(
                    frame: payload,
                    direction: .clientToServer,
                    ledger: bridgeLedger,
                    faultRule: faultRule
                ) { framed in
                    try writeToSocket(framed, socketFD: socketFD)
                }
                if prepared.deliveryFrame != nil {
                    MCPResponseDeliveryTracer.emitPreparedFrame(
                        layer: "proxy_app_uds",
                        phase: "socket_write_completed",
                        prepared: prepared
                    )
                }
            }

            if sawHangup {
                debugLog("BootstrapSocketProxy: stdin hangup after forwarding complete frames")
                try await requireCleanBridgeStop(
                    ledger: bridgeLedger,
                    direction: .clientToServer,
                    pendingByteCount: pending.count,
                    reason: "stdin_hangup"
                )
                return
            }
        }
    }

    /// Extracts the client name from an MCP initialize request.
    /// Returns nil if not an initialize request or if parsing fails.
    private static func extractMCPClientName(from data: Data) -> String? {
        // Quick check for "initialize" string before full JSON parse
        guard let str = String(data: data, encoding: .utf8),
              str.contains("\"initialize\"")
        else {
            return nil
        }

        // Parse as JSON-RPC request
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String,
              method == "initialize",
              let params = json["params"] as? [String: Any],
              let clientInfo = params["clientInfo"] as? [String: Any],
              let name = clientInfo["name"] as? String
        else {
            return nil
        }

        debugLog("Extracted MCP client name from initialize: \(name)")
        return name
    }

    /// Extracts a human-readable message from a progress notification.
    /// Returns nil if not a progress notification.
    private static func extractProgressMessage(from jsonLine: Data) -> String? {
        // Fast check: look for progress method marker
        guard let str = String(data: jsonLine, encoding: .utf8),
              str.contains("repoprompt/control/progress")
        else {
            return nil
        }

        // Parse JSON to extract message
        guard let json = try? JSONSerialization.jsonObject(with: jsonLine) as? [String: Any],
              json["id"] == nil, // Must be a notification (no id)
              let method = json["method"] as? String,
              method == "repoprompt/control/progress",
              let params = json["params"] as? [String: Any]
        else {
            return nil
        }

        // Build human-readable message: "tool: message" or just "message"
        let tool = params["tool"] as? String ?? "unknown"
        let message = params["message"] as? String ?? "working..."
        return "\(tool): \(message)"
    }

    #if DEBUG
        private static let stdoutWriteStallTimeout: TimeInterval = {
            guard let raw = ProcessInfo.processInfo.environment["RP_STDOUT_STALL_TIMEOUT"],
                  let value = TimeInterval(raw),
                  value.isFinite,
                  (0.05 ... 30.0).contains(value)
            else {
                return 30.0
            }
            return value
        }()

        private static let stdoutWritePollIntervalMilliseconds: Int32 = {
            guard let raw = ProcessInfo.processInfo.environment["RP_STDOUT_POLL_INTERVAL_MS"],
                  let value = Int32(raw),
                  (1 ... 1000).contains(value)
            else {
                return 250
            }
            return value
        }()
    #else
        private static let stdoutWriteStallTimeout: TimeInterval = 30.0
        private static let stdoutWritePollIntervalMilliseconds: Int32 = 250
    #endif

    /// Pumps socket to stdout. Static to run outside actor isolation.
    private static func pumpSocketToStdout(
        socketFD: Int32,
        stdoutFD: Int32 = STDOUT_FILENO,
        drainState: BridgeDrainState,
        bridgeLedger: JSONRPCBridgeLedger,
        faultRule: JSONRPCBridgeFaultRule?,
        socketPoller: BridgeSocketPoller? = nil,
        drainDeadline: TimeInterval,
        drainVisibilityInterval: TimeInterval,
        drainLogDescriptor: Int32
    ) async throws {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var pending = Data()
        debugLog("BootstrapSocketProxy: pumpSocketToStdout started")
        let originalStdoutFlags: Int32
        do {
            originalStdoutFlags = try NonBlockingFDWriter.setNonBlocking(fd: stdoutFD)
        } catch let writeError as NonBlockingFDWriteError {
            throw mapStdoutWriteError(writeError)
        }
        defer {
            do {
                try NonBlockingFDWriter.restoreFlags(fd: stdoutFD, flags: originalStdoutFlags)
            } catch {
                debugLog("BootstrapSocketProxy: failed to restore stdout flags: \(error)")
            }
        }

        while !Task.isCancelled {
            let readiness: BridgeSocketPollResult
            if let socketPoller {
                readiness = try await socketPoller(socketFD)
            } else {
                var pfd = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
                let pollResult = poll(&pfd, 1, 1000)

                if pollResult < 0 {
                    if errno == EINTR { continue }
                    throw SocketProxyError.pollFailed(errno: errno)
                }
                readiness = pollResult == 0 ? .timedOut : .events(pfd.revents)
            }

            guard case let .events(rawEvents) = readiness else {
                if try await shouldFinishSocketDrain(
                    drainState: drainState,
                    ledger: bridgeLedger,
                    pendingByteCount: pending.count,
                    deadline: drainDeadline,
                    visibilityInterval: drainVisibilityInterval,
                    logDescriptor: drainLogDescriptor
                ) {
                    debugLog("BootstrapSocketProxy: socket→stdout drained after stdin close")
                    return
                }
                continue
            }

            let revents = Int32(rawEvents)
            if revents & (POLLERR | POLLNVAL) != 0 {
                throw SocketProxyError.connectionReset
            }
            let sawHangup = revents & POLLHUP != 0
            if revents & POLLIN == 0 {
                if sawHangup {
                    try await requireCleanBridgeStop(
                        ledger: bridgeLedger,
                        direction: .serverToClient,
                        pendingByteCount: pending.count,
                        reason: "socket_hangup"
                    )
                    return
                }
                continue
            }

            let bytesRead = buffer.withUnsafeMutableBufferPointer { ptr in
                Darwin.read(socketFD, ptr.baseAddress!, ptr.count)
            }

            if bytesRead < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw SocketProxyError.readFailed(errno: errno)
            }
            if bytesRead == 0 {
                try await requireCleanBridgeStop(
                    ledger: bridgeLedger,
                    direction: .serverToClient,
                    pendingByteCount: pending.count,
                    reason: "socket_eof"
                )
                return
            }

            pending.append(contentsOf: buffer[0 ..< bytesRead])
            debugLog("BootstrapSocketProxy: read \(bytesRead) bytes from socket, pending=\(pending.count)")

            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let data = Data(pending[...newline])
                pending = Data(pending[(newline + 1)...])
                debugLog("BootstrapSocketProxy: ← stdout bytes=\(data.count) sha256=\(MCPResponseDeliveryTracer.sha256Hex(data))")

                let prepared = try await JSONRPCBridgeDelivery.forward(
                    frame: data,
                    direction: .serverToClient,
                    ledger: bridgeLedger,
                    faultRule: faultRule
                ) { framed in
                    // Progress notifications are an intentional stderr-only control surface.
                    // Delivery is best-effort: if the host closed stderr, drop the progress
                    // line and keep the stdout transport alive rather than raising an ObjC
                    // exception that would abort the helper mid-ledger-transaction.
                    if let progressMessage = Self.extractProgressMessage(from: framed) {
                        let delivered = BestEffortStderrWriter.writeNonBlocking(
                            Data("[progress] \(progressMessage)\n".utf8)
                        )
                        if !delivered {
                            debugLog("BootstrapSocketProxy: dropped progress output, stderr unavailable")
                        }
                        return
                    }
                    do {
                        try NonBlockingFDWriter.writeAll(
                            framed,
                            to: stdoutFD,
                            stallTimeout: stdoutWriteStallTimeout,
                            pollIntervalMilliseconds: stdoutWritePollIntervalMilliseconds,
                            setNonBlocking: false
                        )
                    } catch let writeError as NonBlockingFDWriteError {
                        debugLog("BootstrapSocketProxy: stdout bridge write failed provenance=\(writeError.provenance)")
                        throw mapStdoutWriteError(writeError)
                    }
                }
                if let delivered = prepared.deliveryFrame,
                   Self.extractProgressMessage(from: delivered) == nil
                {
                    MCPResponseDeliveryTracer.emitPreparedFrame(
                        layer: "proxy_stdout",
                        phase: "stdout_write_completed",
                        prepared: prepared,
                        publicationPending: false,
                        terminalBarrier: false
                    )
                }
            }

            if sawHangup {
                try await requireCleanBridgeStop(
                    ledger: bridgeLedger,
                    direction: .serverToClient,
                    pendingByteCount: pending.count,
                    reason: "socket_hangup"
                )
                return
            }
            if try await shouldFinishSocketDrain(
                drainState: drainState,
                ledger: bridgeLedger,
                pendingByteCount: pending.count,
                deadline: drainDeadline,
                visibilityInterval: drainVisibilityInterval,
                logDescriptor: drainLogDescriptor
            ) {
                debugLog("BootstrapSocketProxy: socket→stdout drained after stdin close")
                return
            }
        }
    }

    private static func shouldFinishSocketDrain(
        drainState: BridgeDrainState,
        ledger: JSONRPCBridgeLedger,
        pendingByteCount: Int,
        deadline: TimeInterval,
        visibilityInterval: TimeInterval,
        logDescriptor: Int32
    ) async throws -> Bool {
        guard let elapsed = await drainState.elapsedSinceStdinClosed() else { return false }
        let snapshot = await ledger.snapshot()
        if snapshot.canFinishSocketDrain(partialByteCount: pendingByteCount) {
            return true
        }

        let effectiveDeadline = max(0.001, deadline)
        if elapsed >= effectiveDeadline {
            let terminalReason = await ledger.terminalizePostStdinHalfCloseDrainDeadline()
            let elapsedText = String(format: "%.3fs", elapsed)
            let deadlineText = String(format: "%.3fs", effectiveDeadline)
            let blockers = snapshot.socketDrainBlockerDescription(partialByteCount: pendingByteCount)
            let message = "[MCPBridgeDrain] deadline_exceeded elapsed=\(elapsedText) deadline=\(deadlineText) \(blockers) terminalized_reason=\(terminalReason)\n"
            BestEffortStderrWriter.writeNonBlocking(Data(message.utf8), to: logDescriptor)
            throw JSONRPCBridgeLedgerError.terminal(terminalReason)
        }

        if let visibleElapsed = await drainState.claimVisibilityLog(interval: visibilityInterval) {
            let elapsedText = String(format: "%.3fs", visibleElapsed)
            let message = "[MCPBridgeDrain] waiting elapsed=\(elapsedText) \(snapshot.socketDrainBlockerDescription(partialByteCount: pendingByteCount))\n"
            BestEffortStderrWriter.writeNonBlocking(Data(message.utf8), to: logDescriptor)
        }
        return false
    }

    private static func requireCleanBridgeStop(
        ledger: JSONRPCBridgeLedger,
        direction: JSONRPCBridgeDirection,
        pendingByteCount: Int,
        reason: String
    ) async throws {
        switch await ledger.noteEOF(
            direction: direction,
            pendingByteCount: pendingByteCount,
            reason: reason
        ) {
        case .clean:
            return
        case let .terminal(terminalReason):
            throw JSONRPCBridgeLedgerError.terminal(terminalReason)
        }
    }

    private static func mapStdoutWriteError(_ error: NonBlockingFDWriteError) -> SocketProxyError {
        switch error {
        case let .brokenPipe(bytesWritten, totalBytes):
            .stdoutBrokenPipe(bytesWritten: bytesWritten, totalBytes: totalBytes)
        case let .localTimeout(stallTimeout, bytesWritten, totalBytes):
            .stdoutWriteTimeout(
                bytesWritten: bytesWritten,
                totalBytes: totalBytes,
                stallTimeout: stallTimeout
            )
        case let .pollFailed(errno), let .fcntlFailed(errno):
            .pollFailed(errno: errno)
        case let .writeFailed(errno, _, _):
            .writeFailed(errno: errno)
        case .cancelled:
            .cancelled
        }
    }

    /// Writes data to socket. Static helper.
    /// Uses poll with a 10 second deadline to avoid blocking forever if server stops reading.
    private static func writeToSocket(_ data: Data, socketFD: Int32) throws {
        var totalWritten = 0
        let deadline = Date().addingTimeInterval(10.0)

        while totalWritten < data.count {
            if Task.isCancelled {
                throw SocketProxyError.cancelled
            }
            if Date() > deadline {
                shutdown(socketFD, SHUT_RDWR)
                throw SocketProxyError.connectionTimeout
            }

            let written = data.withUnsafeBytes { buf in
                let ptr = buf.baseAddress!.advanced(by: totalWritten)
                return Darwin.write(socketFD, ptr, data.count - totalWritten)
            }

            if written > 0 {
                totalWritten += written
                continue
            }

            if written < 0 {
                let err = errno
                if err == EINTR { continue }
                if err == EAGAIN || err == EWOULDBLOCK {
                    let remainingMs = Int32(deadline.timeIntervalSinceNow * 1000)
                    if remainingMs <= 0 {
                        shutdown(socketFD, SHUT_RDWR)
                        throw SocketProxyError.connectionTimeout
                    }
                    var pfd = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
                    let result = poll(&pfd, 1, min(remainingMs, 250))
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw SocketProxyError.pollFailed(errno: errno)
                    }
                    if pfd.revents & Int16(POLLHUP | POLLERR) != 0 {
                        throw SocketProxyError.connectionReset
                    }
                    continue
                }
                throw SocketProxyError.writeFailed(errno: err)
            }

            // written == 0 on stream socket is unusual, treat as connection closed
            throw SocketProxyError.connectionReset
        }
    }

    /// Sets file descriptor to non-blocking mode. Static helper.
    static func setNonBlocking(fileDescriptor: FileDescriptor) throws {
        let flags = fcntl(fileDescriptor.rawValue, F_GETFL)
        guard flags >= 0 else {
            throw MCPError.transportError(Errno.badFileDescriptor)
        }
        let result = fcntl(fileDescriptor.rawValue, F_SETFL, flags | O_NONBLOCK)
        guard result >= 0 else {
            throw MCPError.transportError(Errno.badFileDescriptor)
        }
    }
}

/// Create MCPService class to manage lifecycle
actor MCPService: Service {
    /// Stable session token for this CLI process instance.
    /// Used by the app to identify this CLI across bootstrap-socket reconnections.
    private let sessionToken: String

    /// Cache for MCP client identity (extracted from initialize request).
    /// Persists across startup-only reconnects so the app sees the correct client name.
    private let identityCache = ClientIdentityCache()

    /// Process-lifetime correlation ledger. It deliberately survives startup reconnect attempts
    /// so a protocol-active bridge can never be silently replaced.
    private let bridgeLedger: JSONRPCBridgeLedger

    // Kill signal watcher state
    private var killSignalFD: Int32 = -1
    private var killSignalSource: DispatchSourceFileSystemObject?
    private var killSignalContinuation: CheckedContinuation<CLIKillSignal.SignalContent?, Never>?

    init() {
        let sessionToken = UUID().uuidString
        self.sessionToken = sessionToken
        bridgeLedger = JSONRPCBridgeLedger(connectionID: sessionToken, traceSink: { event in
            MCPResponseDeliveryTracer.emit(event)
        })
        // No TCP/Bonjour transport – bootstrap socket only
    }

    // MARK: - Kill Signal Watcher

    /// Sets up a DispatchSource watcher on the kill signals directory.
    /// When the app writes a kill signal file for this session, the watcher triggers.
    private func setupKillSignalWatcher() {
        let signalsDir = CLIKillSignal.signalsDirectory
        let fm = FileManager.default

        // Ensure directory exists
        try? fm.createDirectory(at: signalsDir, withIntermediateDirectories: true)

        let fd = open(signalsDir.path, O_EVTONLY)
        guard fd >= 0 else {
            log.warning("Failed to open kill signals directory for watching")
            return
        }
        do {
            try POSIXDescriptorSupport.setCloseOnExec(fd)
        } catch {
            close(fd)
            log.warning("Failed to configure kill signals directory watcher descriptor: \(error)")
            return
        }
        killSignalFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self, sessionToken] in
            // Check if our kill signal file exists
            if let signal = CLIKillSignal.readKillSignal(forSessionToken: sessionToken) {
                Task { [weak self] in
                    await self?.handleKillSignal(signal)
                }
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        killSignalSource = source
        source.resume()
        log.debug("Kill signal watcher set up for session \(sessionToken.prefix(8))...")
    }

    /// Called when a kill signal is detected.
    private func handleKillSignal(_ signal: CLIKillSignal.SignalContent) {
        log.notice("Kill signal received: \(signal.reason.rawValue)")

        // Clean up the signal file
        CLIKillSignal.removeKillSignal(forSessionToken: sessionToken)

        // Resume the continuation if waiting
        if let cont = killSignalContinuation {
            killSignalContinuation = nil
            cont.resume(returning: signal)
        }
    }

    /// Waits for a kill signal. Returns immediately if one is already pending.
    /// Returns nil if the task is cancelled before a signal arrives.
    private func waitForKillSignal() async -> CLIKillSignal.SignalContent? {
        // Check if already signaled
        if let signal = CLIKillSignal.readKillSignal(forSessionToken: sessionToken) {
            CLIKillSignal.removeKillSignal(forSessionToken: sessionToken)
            return signal
        }

        // Check if already cancelled before waiting
        if Task.isCancelled { return nil }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                killSignalContinuation = cont
            }
        } onCancel: {
            // Resume with nil on cancellation - must be done from actor context
            Task { [weak self] in
                await self?.cancelKillSignalWait()
            }
        }
    }

    /// Resumes the kill signal continuation with nil when cancelled.
    private func cancelKillSignalWait() {
        if let cont = killSignalContinuation {
            killSignalContinuation = nil
            cont.resume(returning: nil)
        }
    }

    private func teardownKillSignalWatcher() {
        let source = killSignalSource
        killSignalSource = nil
        killSignalFD = -1
        source?.cancel()
        killSignalContinuation = nil
    }

    func run() async throws {
        // Set up kill signal watcher before starting transport
        setupKillSignalWatcher()
        defer { teardownKillSignalWatcher() }

        // Capture initial parent PID for orphan detection
        let initialPPID = getppid()

        // Race between transport loop, kill signal, and PPID watchdog
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Kill signal monitor task
            group.addTask {
                guard let signal = await self.waitForKillSignal() else {
                    // Task was cancelled - just return without throwing
                    return
                }
                throw CLIRuntimeError.terminatedByServer(
                    reason: CLIKillSignal.messageForReason(signal.reason)
                )
            }

            // PPID watchdog - detect orphaned CLI when parent dies
            group.addTask {
                try await self.runPPIDWatchdog(initialPPID: initialPPID)
            }

            // Main transport task
            group.addTask {
                try await self.runTransport()
            }

            // Wait for first to complete (either kill signal, orphan detection, or transport exit)
            do {
                while let _ = try await group.next() {}
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    /// Monitors the parent process ID. If it changes (reparented to init/launchd),
    /// the host process died and we should exit cleanly.
    private func runPPIDWatchdog(initialPPID: pid_t) async throws {
        // Check every 5 seconds - balance between responsiveness and CPU usage
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(5))

            let currentPPID = getppid()
            if currentPPID != initialPPID {
                // Parent changed - we've been orphaned (typically reparented to PID 1)
                log.notice("CLI: Parent process died (PPID changed from \(initialPPID) to \(currentPPID)), exiting")
                throw CLIRuntimeError.hostDisconnected
            }
        }
    }

    // MARK: - Reconnection Logic

    /// Determines whether a runtime error is transient and should trigger a retry.
    /// Terminal errors (approval denied, explicit termination, host disconnect) return false.
    private func shouldRetry(after error: CLIRuntimeError) -> Bool {
        switch error {
        case .approvalDenied,
             .hostDisconnected,
             .terminatedByServer:
            return false

        case let .connectionFailed(underlying):
            guard let socketError = underlying as? SocketProxyError else {
                // Unknown underlying error - be conservative, allow a few retries
                return true
            }
            switch socketError {
            // Terminal socket errors - don't retry
            case .approvalDenied,
                 .handshakeFailed,
                 .protocolVersionMismatch,
                 .socketCreationFailed,
                 .descriptorConfigurationFailed,
                 .pathTooLong,
                 .bindFailed,
                 .listenFailed,
                 .acceptFailed,
                 .stdoutWriteTimeout,
                 .stdoutBrokenPipe,
                 .hostDisconnected:
                return false

            case let .handshakeRejected(errorCode, _):
                return isTransientBootstrapRejection(errorCode)

            // Transient socket errors - retry with backoff
            case .connectionRefused,
                 .connectionTimeout,
                 .bootstrapResponseTimeout,
                 .connectionReset,
                 .serverClosed,
                 .readFailed,
                 .writeFailed,
                 .pollFailed,
                 .notConnected,
                 .notListening,
                 .cancelled,
                 .connectFailed,
                 .terminatedByServer:
                return true
            }
        }
    }

    private func transportFailureReason(for error: CLIRuntimeError) -> String {
        switch error {
        case .approvalDenied:
            return "approval_denied"
        case .hostDisconnected:
            return "host_disconnected"
        case .terminatedByServer:
            return "terminated_by_server"
        case let .connectionFailed(underlying):
            if underlying is JSONRPCBridgeLedgerError {
                return "jsonrpc_bridge_terminal"
            }
            if let socketError = underlying as? SocketProxyError {
                switch socketError {
                case .stdoutWriteTimeout: return "stdout_write_timeout"
                case .stdoutBrokenPipe: return "stdout_broken_pipe"
                case .serverClosed: return "app_socket_closed"
                case .connectionReset: return "app_socket_reset"
                case .connectionTimeout: return "app_socket_write_timeout"
                default: return "bootstrap_transport_failure"
                }
            }
            return "transport_failure"
        }
    }

    private static func responseDeliveryFaultRuleFromEnvironment() -> JSONRPCBridgeFaultRule? {
        #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            guard environment["RP_MCP_FAULT_ACTION"] == JSONRPCBridgeFaultRule.Action.failDestinationWrite.rawValue,
                  let rawDirection = environment["RP_MCP_FAULT_DIRECTION"],
                  let direction = JSONRPCBridgeDirection(rawValue: rawDirection)
            else {
                return nil
            }

            let id = environment["RP_MCP_FAULT_ID"].flatMap(JSONRPCBridgeID.parseFaultSelector)
            let allowOrdinal = environment["RP_MCP_FAULT_ALLOW_ORDINAL"] == "1"
            let ordinal = allowOrdinal
                ? environment["RP_MCP_FAULT_ORDINAL"].flatMap(UInt64.init)
                : nil
            guard id != nil || ordinal != nil else { return nil }

            let rule = JSONRPCBridgeFaultRule(
                direction: direction,
                id: id,
                method: environment["RP_MCP_FAULT_METHOD"],
                tool: environment["RP_MCP_FAULT_TOOL"],
                requestOrdinal: ordinal
            )
            debugLog(
                "Configured response fault direction=\(direction.rawValue) id=\(id?.description ?? "none") " +
                    "method=\(rule.method ?? "none") tool=\(rule.tool ?? "none") ordinal=\(ordinal.map(String.init) ?? "none")"
            )
            return rule
        #else
            return nil
        #endif
    }

    private func isTransientBootstrapRejection(_ code: String?) -> Bool {
        guard let code else { return false }
        switch code {
        case MCPBootstrapErrorCode.serverNotReady.rawValue,
             MCPBootstrapErrorCode.serverUnavailable.rawValue,
             MCPBootstrapErrorCode.connectionLimitReached.rawValue,
             MCPBootstrapErrorCode.capacityExceeded.rawValue,
             MCPBootstrapErrorCode.clientCooldown.rawValue:
            return true
        default:
            return false
        }
    }

    /// Runs the MCP transport with reconnection on transient failures.
    /// Exits on approvalDenied, terminatedByServer, hostDisconnected, or fatal transport errors.
    ///
    /// Retry strategy:
    /// - First 60 seconds: aggressive retries every 0.5s (app might just be restarting)
    /// - After 60 seconds: exponential backoff from 1s up to 30s
    private func runTransport() async throws {
        var attempt = 0
        var firstFailureTime: Date?

        // Phase 1: Aggressive retries (first 60 seconds)
        let aggressiveDelay = 0.5
        let aggressivePhaseDuration = 60.0

        // Phase 2: Exponential backoff
        let backoffBase = 1.0
        let maxDelay = 30.0

        while !Task.isCancelled {
            do {
                try await runSocketLoop()
                // If runSocketLoop() returns without throwing, treat as clean exit
                return
            } catch let err as CLIRuntimeError {
                // Reconnection is legal only while the process is still in startup state.
                // Once any complete protocol frame has committed—or delivery is uncertain—
                // preserve JSON-RPC correlation by failing the stdio session closed.
                let protocolActiveFailure = await bridgeLedger.recordConnectionFailure(
                    transportFailureReason(for: err)
                )
                guard !protocolActiveFailure, shouldRetry(after: err) else {
                    throw err
                }

                attempt += 1
                let now = Date()
                if firstFailureTime == nil {
                    firstFailureTime = now
                }

                let elapsedSinceFirstFailure = now.timeIntervalSince(firstFailureTime!)
                let delay: Double

                if elapsedSinceFirstFailure < aggressivePhaseDuration {
                    // Phase 1: Frequent retries - app might just be restarting
                    let jitter = Double.random(in: 0 ... 0.1)
                    delay = aggressiveDelay + jitter
                } else {
                    // Phase 2: Exponential backoff with jitter
                    let backoffAttempt = attempt - Int(aggressivePhaseDuration / aggressiveDelay)
                    let expDelay = min(maxDelay, backoffBase * pow(2.0, Double(max(0, backoffAttempt - 1))))
                    let jitter = Double.random(in: 0 ... (0.2 * expDelay))
                    delay = min(maxDelay, expDelay + jitter)
                }

                log.warning("Bootstrap connection lost (\(err)). Retrying in \(String(format: "%.1f", delay))s (attempt \(attempt), elapsed \(String(format: "%.0f", elapsedSinceFirstFailure))s)")

                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch is CancellationError {
                    // Cancelled by kill signal or PPID watchdog
                    throw CLIRuntimeError.hostDisconnected
                }
            } catch {
                // Unknown error type - treat as fatal connection failure
                throw CLIRuntimeError.connectionFailed(underlying: error)
            }
        }

        // If loop exits due to Task cancellation
        throw CLIRuntimeError.hostDisconnected
    }

    /// Single connection attempt to the bootstrap socket.
    private func runSocketLoop() async throws {
        _ = try await bridgeLedger.beginConnection()

        // Build the best available client name for the handshake:
        // 1. Cached MCP clientInfo.name (from previous initialize)
        // 2. Parent process executable name
        // 3. Our own process name (fallback)
        let cachedName = await identityCache.currentName()
        let displayName = cachedName
            ?? CLIEventLogger.detectClientName()
            ?? ProcessInfo.processInfo.processName

        // Use bootstrap socket proxy (CLI connects to app's socket server)
        let proxy = BootstrapSocketProxy(
            sessionToken: sessionToken,
            clientName: displayName,
            identityCache: identityCache,
            bridgeLedger: bridgeLedger,
            faultRule: Self.responseDeliveryFaultRuleFromEnvironment()
        )

        do {
            try await proxy.start()
            log.debug("Bootstrap socket proxy stopped cleanly")
            throw CLIRuntimeError.hostDisconnected
        } catch let err as SocketProxyError {
            await proxy.stop()
            switch err {
            case .approvalDenied:
                throw CLIRuntimeError.approvalDenied
            case .hostDisconnected:
                // Host process closed stdin - clean exit
                throw CLIRuntimeError.hostDisconnected
            case let .stdoutBrokenPipe(bytesWritten, totalBytes):
                debugLog("BootstrapSocketProxy: stdout bridge broken_pipe bytes_written=\(bytesWritten) total_bytes=\(totalBytes)")
                throw CLIRuntimeError.hostDisconnected
            case .stdoutWriteTimeout:
                throw CLIRuntimeError.connectionFailed(underlying: err)
            case .serverClosed, .connectionReset, .connectionTimeout:
                throw CLIRuntimeError.connectionFailed(underlying: err)
            case .connectionRefused:
                // App not running or not accepting connections
                throw CLIRuntimeError.connectionFailed(underlying: err)
            case let .terminatedByServer(reason):
                // Server explicitly killed this connection - exit without retry
                throw CLIRuntimeError.terminatedByServer(reason: reason)
            case let .handshakeFailed(reason):
                log.error("Bootstrap handshake failed: \(reason)")
                throw CLIRuntimeError.connectionFailed(underlying: err)
            default:
                throw CLIRuntimeError.connectionFailed(underlying: err)
            }
        } catch let err as CLIRuntimeError {
            await proxy.stop()
            throw err
        } catch {
            await proxy.stop()
            throw CLIRuntimeError.connectionFailed(underlying: error)
        }
    }

    func shutdown() async throws {
        // Required by Service protocol - no cleanup needed
    }
}

// MARK: - Error Handlers

func mcpCLIExitCode(for error: CLIRuntimeError) -> MCPCLIExitCode {
    switch error {
    case .connectionFailed:
        .connectionFailed
    case .approvalDenied:
        .approvalDenied
    case .terminatedByServer:
        .terminatedByServer
    case .hostDisconnected:
        .ok
    }
}

func handleRuntimeError(_ err: CLIRuntimeError) -> Never {
    let exitCode = mcpCLIExitCode(for: err)
    // Log error event to disk for app to surface (respects shouldPersistEvent policy)
    CLIEventLogger.logRuntimeError(err)

    switch err {
    case let .connectionFailed(underlying):
        log.error("Connection failed: \(underlying)")
        fputs("RepoPrompt MCP: connection failed – \(underlying)\n", stderr)
        exit(exitCode.rawValue)
    case .approvalDenied:
        fputs("RepoPrompt MCP: connection closed immediately. Approval was likely denied or the server is disabled. Check the RepoPrompt approval dialog or MCP settings.\n", stderr)
        exit(exitCode.rawValue)
    case let .terminatedByServer(reason):
        // Clean exit - server explicitly terminated this connection
        let message = reason ?? "Connection terminated by server"
        log.notice("CLI exiting: \(message)")
        fputs("RepoPrompt MCP: \(message)\n", stderr)
        exit(exitCode.rawValue)
    case .hostDisconnected:
        // Host process died - exit cleanly without retry
        log.notice("CLI exiting: host disconnected")
        exit(exitCode.rawValue)
    }
}

// MARK: - CLI Mode Selection

/// CLI operating mode
enum CLIMode {
    case proxy
    case interactive(InteractiveOptions)
    case exec(ExecOptions)
}

private func parseToolTimeoutSeconds(_ raw: String) -> Double? {
    guard let seconds = Double(raw), seconds.isFinite, seconds >= 0 else {
        return nil
    }
    return seconds
}

/// Parses command line arguments to determine CLI mode
func parseCLIMode() -> CLIMode {
    let args = CommandLine.arguments.dropFirst() // Skip executable name
    let hasUserArgs = !args.isEmpty
    var interactiveOptions = InteractiveOptions()
    var execOptions = ExecOptions()
    var isInteractive = false
    var isExec = false

    var i = args.startIndex
    while i < args.endIndex {
        let arg = args[i]

        switch arg {
        case "--raw-json":
            interactiveOptions.rawJSON = true
            execOptions.rawJSON = true

        case "--tool-timeout":
            i = args.index(after: i)
            guard i < args.endIndex, let seconds = parseToolTimeoutSeconds(args[i]) else {
                fputs("Error: --tool-timeout requires a non-negative finite number of seconds (0 disables the CLI-side timeout).\n", stderr)
                exit(2)
            }
            interactiveOptions.toolCallTimeoutSeconds = seconds
            execOptions.toolCallTimeoutSeconds = seconds

        case let s where s.hasPrefix("--tool-timeout="):
            let raw = String(s.dropFirst("--tool-timeout=".count))
            guard let seconds = parseToolTimeoutSeconds(raw) else {
                fputs("Error: --tool-timeout requires a non-negative finite number of seconds (0 disables the CLI-side timeout).\n", stderr)
                exit(2)
            }
            interactiveOptions.toolCallTimeoutSeconds = seconds
            execOptions.toolCallTimeoutSeconds = seconds

        // Interactive mode flags
        case "--interactive", "-i":
            isInteractive = true

        case "--list-tools", "-l":
            isInteractive = true
            interactiveOptions.listToolsOnly = true
            interactiveOptions.listToolsMode = .all

        case let s where s.hasPrefix("--list-tools="):
            isInteractive = true
            interactiveOptions.listToolsOnly = true
            let spec = String(s.dropFirst("--list-tools=".count))
            if spec == "--groups" || spec.lowercased() == "groups" {
                interactiveOptions.listToolsMode = .groupNames
            } else {
                do {
                    let groups = try ToolGroupCatalog.parseGroups(spec: spec)
                    interactiveOptions.listToolsMode = .groups(groups)
                } catch {
                    fputs("Error: \(error)\n", stderr)
                    exit(2)
                }
            }

        case "--describe", "-d":
            isInteractive = true
            i = args.index(after: i)
            if i < args.endIndex {
                interactiveOptions.describeTool = args[i]
            }

        case "--call", "-c":
            isInteractive = true
            i = args.index(after: i)
            if i < args.endIndex {
                interactiveOptions.callTool = args[i]
            }

        case "--json", "-j":
            i = args.index(after: i)
            if i < args.endIndex {
                interactiveOptions.callArgs = args[i]
                execOptions.jsonArgs = args[i]
            }

        case "--tools-schema":
            isInteractive = true
            interactiveOptions.toolsSchemaOnly = true
            interactiveOptions.toolsSchemaMode = .all

        case let s where s.hasPrefix("--tools-schema="):
            isInteractive = true
            interactiveOptions.toolsSchemaOnly = true
            let spec = String(s.dropFirst("--tools-schema=".count))
            if spec.isEmpty {
                interactiveOptions.toolsSchemaMode = .all
            } else {
                do {
                    let groups = try ToolGroupCatalog.parseGroups(spec: spec)
                    interactiveOptions.toolsSchemaMode = .groups(groups)
                } catch {
                    fputs("Error: \(error)\n", stderr)
                    exit(2)
                }
            }

        case "--snapshot-tools", "-s":
            isInteractive = true
            i = args.index(after: i)
            if i < args.endIndex {
                interactiveOptions.snapshotPath = args[i]
            }

        // Exec mode flags
        case "--exec", "-e":
            isExec = true
            i = args.index(after: i)
            if i < args.endIndex {
                execOptions.commands.append(args[i])
            }

        case "--exec-file":
            isExec = true
            i = args.index(after: i)
            if i < args.endIndex {
                execOptions.scriptPath = args[i]
            }

        case "--exec-stdin":
            isExec = true
            execOptions.readStdin = true

        case "--cwd":
            i = args.index(after: i)
            if i < args.endIndex {
                execOptions.cwd = args[i]
            }

        case "--wait-for-server", "--connect-wait":
            i = args.index(after: i)
            if i < args.endIndex, let seconds = Double(args[i]) {
                execOptions.connectWaitSeconds = seconds
            }

        case "--fail-fast":
            execOptions.failFast = true

        case "--quiet", "-q":
            execOptions.quiet = true

        case "--verbose":
            execOptions.verbose = true
            interactiveOptions.verbose = true
            interactiveOptions.prettyJSON = true

        // Workflow sugar flags (compile to exec commands)
        case "--workspace":
            isExec = true
            i = args.index(after: i)
            if i < args.endIndex {
                execOptions.commands.append("workspace switch \"\(args[i])\"")
            }

        case "--select-add":
            isExec = true
            i = args.index(after: i)
            if i < args.endIndex {
                execOptions.commands.append("select add \(args[i])")
            }

        case "--select-set":
            isExec = true
            i = args.index(after: i)
            if i < args.endIndex {
                execOptions.commands.append("select set \(args[i])")
            }

        case "--export-context":
            isExec = true
            i = args.index(after: i)
            if i < args.endIndex {
                execOptions.commands.append("context --all > \"\(args[i])\"")
            }

        case "--export-prompt":
            isExec = true
            i = args.index(after: i)
            if i < args.endIndex {
                execOptions.commands.append("prompt export \"\(args[i])\"")
            }

        case "--chat":
            isExec = true
            i = args.index(after: i)
            if i < args.endIndex {
                execOptions.commands.append("chat \(args[i])")
            }

        case "--builder":
            isExec = true
            i = args.index(after: i)
            if i < args.endIndex {
                execOptions.commands.append("builder \(args[i])")
            }

        // Shared flags
        case "--window", "-w":
            i = args.index(after: i)
            if i < args.endIndex, let windowID = Int(args[i]) {
                interactiveOptions.initialWindowID = windowID
                execOptions.windowID = windowID
            }

        case "--tab", "-t":
            i = args.index(after: i)
            if i < args.endIndex {
                execOptions.tabID = args[i]
            }

        case "--context-id":
            i = args.index(after: i)
            if i < args.endIndex {
                execOptions.contextID = args[i]
            }

        case "--working-dir":
            i = args.index(after: i)
            if i < args.endIndex {
                execOptions.workingDirs.append(args[i])
            }

        case "--compact":
            interactiveOptions.prettyJSON = false
            execOptions.prettyJSON = false

        case "--pretty":
            execOptions.prettyJSON = true

        case "--help", "-h":
            printUsage()
            exit(0)

        case "--help-interactive":
            printInteractiveUsage()
            exit(0)

        case "--help-scripting":
            printScriptingUsage()
            exit(0)

        case "--help-advanced":
            printAdvancedUsage()
            exit(0)

        #if DEBUG
            case "--test-parse":
                // Debug mode: parse command and print result without executing
                i = args.index(after: i)
                if i < args.endIndex {
                    let command = args[i]
                    testParseCommand(command)
                } else {
                    fputs("Error: --test-parse requires a command string\n", stderr)
                    exit(1)
                }
                exit(0)
        #endif

        case "--version", "-v":
            printVersion()
            exit(0)

        case "--launch-app":
            launchRepoPromptApp()
            exit(0)

        default:
            // Check if this looks like a command (tool name or alias) without -e flag
            // This allows: rpce-cli tree, rpce-cli search "pattern", etc.
            if !isExec, !isInteractive, !arg.hasPrefix("-") {
                // Check if it's a known command/tool alias
                let resolved = MCPCommandParser.resolveToolAlias(arg)
                let isKnownCommand = MCPCommandParser.allCommands.contains(arg.lowercased()) ||
                    resolved != arg // resolveToolAlias returns different value for known aliases

                if isKnownCommand {
                    // Treat remaining args as an implicit exec command
                    isExec = true
                    let remaining = args[i...].joined(separator: " ")
                    execOptions.commands.append(remaining)
                    break // Consumed all remaining args
                }
            }
        }

        i = args.index(after: i)
    }

    // Exec mode takes precedence if any exec flags were used
    if isExec {
        return .exec(execOptions)
    }
    if isInteractive {
        return .interactive(interactiveOptions)
    }

    // Proxy mode is reserved for MCP hosts launching the binary with no CLI args.
    // Any explicit args that don't select exec/interactive are invalid user input.
    if hasUserArgs {
        fputs("Error: no command or mode specified.\n", stderr)
        fputs("Use -e/--exec for commands, -i for REPL, or --help for usage.\n\n", stderr)
        printUsage()
        exit(2)
    }

    return .proxy
}

/// Returns true when stdin is suitable for MCP host stdio transport.
/// MCP hosts should provide a pipe/socket; other descriptor types (e.g. /dev/null)
/// are treated as non-host invocations.
private func stdinLooksLikeMCPTransport() -> Bool {
    var st = stat()
    guard fstat(STDIN_FILENO, &st) == 0 else { return false }
    let type = st.st_mode & S_IFMT
    return type == S_IFIFO || type == S_IFSOCK
}

/// Returns true when stdin already reports hangup/invalid before proxy start.
/// This indicates no live host is attached.
private func stdinHasImmediateDisconnect() -> Bool {
    var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    let result = poll(&pfd, 1, 0)
    guard result > 0 else { return false }
    let revents = Int32(pfd.revents)
    return (revents & POLLHUP) != 0 || (revents & POLLNVAL) != 0 || (revents & POLLERR) != 0
}

func cliDisplayCommand() -> String {
    let invokedName = URL(fileURLWithPath: CommandLine.arguments.first ?? "").lastPathComponent
    if invokedName == "repoprompt-mcp" || invokedName.isEmpty {
        #if DEBUG
            return "rpce-cli-debug"
        #else
            return "rpce-cli"
        #endif
    }
    return invokedName
}

func printUsage() {
    let usage = """
    RepoPrompt MCP CLI - Execute commands against RepoPrompt workspaces

    USAGE:
        __RPCE_CLI__ -e '<command>'           Run a command
        __RPCE_CLI__ -e '<cmd1> && <cmd2>'    Chain commands
        __RPCE_CLI__ -w <id> -e '<command>'   Target specific window
        __RPCE_CLI__ -w <id> -t <tab> -e ...  Target window and tab

    EXAMPLES:
        __RPCE_CLI__ -e 'tree'                          Show file tree
        __RPCE_CLI__ -e 'workspace list'                List workspaces
        __RPCE_CLI__ -e 'select set src/ && context'    Select files, get context
        __RPCE_CLI__ -e 'search "TODO" --extensions .swift'
        __RPCE_CLI__ -e 'chat How does auth work?'      Send to AI chat

    QUICK START:
        __RPCE_CLI__ --launch-app                       Launch RepoPrompt app
        __RPCE_CLI__ -e 'windows'                       List open windows (get ID)
        __RPCE_CLI__ -w 1 -e 'select set src/'          Select files for context
        __RPCE_CLI__ -w 1 -e 'chat "Explain this code" --new'   Start new chat

    CORE CONCEPTS:
        The tab's file selection is part of the current context. Use `manage_selection`
        to mutate it and `workspace_context` to inspect or export it.

        Manual:   manage_selection op=set paths=["src/"] && ask_oracle message="..."
        Auto:     context_builder task="..." response_type=question  → chat
                  context_builder task="..." response_type=plan      → plan
                  builder "..." --response-type plan --export       → plan file

    PARAMETER SYNTAX:
        Equivalent forms:  key=value  |  --key value  |  --key=value
        JSON values:       paths=["src/","lib/"]  filter={"paths":["src/"]}
        Dotted keys:       filter.paths=src/  (expands to nested object)
        Boolean flags:     --verbose  (alone means true)
        Dash → underscore: --max-results  becomes  max_results
        Spaces:            --pattern "hello world"
        Slice notation:    path:start-end  (e.g., file.swift:10-50)

        Positional args (tool-specific shorthands):
          read <path> [start] [limit]       read src/main.swift 100 50
          search <pattern> [--flags]        search "TODO" --extensions .swift

    MCP TOOLS WITH EXAMPLES (use -d <tool> for full parameter docs):

        manage_selection (select) - Curate file selection
          select set src/                              Replace selection with src/
          select add lib/utils.ts                      Add file to selection
          select add file.swift:10-50                  Add lines 10-50 only (slice)
          manage_selection op=set paths=["src/"] mode=codemap_only

        context_builder (builder) - Auto-build selection, optionally generate response
          builder "find authentication code"           Build context only (sets selection)
          builder "add logout feature" --response-type plan   Build context + generate plan
          builder "add logout feature" --response-type plan --export
                                                       Generate plan and return oracle_export_path
          builder "how does auth work?" --response-type question
          After builder, use chat to continue: chat "explain more" --chat-id <returned-id>

        ask_oracle (chat, plan, review) - Send/continue an oracle conversation
          Aliases: chat "msg" continues current chat (--new to start fresh)
                   plan "msg"   → new_chat=true mode=plan
                   review "msg" → new_chat=true mode=review (includes git diff)
          chat "How does this work?"                   Continue current chat
          chat "Explain auth" --new                    Start new chat
          plan "Design user system"                    New chat in plan mode
          review "What changed?"                       Review git diff of selected files
          ask_oracle message="Review plan" mode=plan new_chat=true

        read_file (read, cat) - Read file contents
          read src/main.swift                          Read entire file
          read src/main.swift 100 50                   Lines 100-149
          read_file path=src/main.swift start_line=-20 Read last 20 lines

        file_search (search, grep) - Search by pattern
          search "TODO"                                Search all files
          search "func.*async" --extensions .swift     Regex in Swift files
          search "error" --context-lines 3             Show context around matches
          file_search pattern="TODO" filter={"paths":["src/"]}

        get_file_tree (tree) - Show directory structure
          tree                                         Auto-trimmed tree
          tree --folders                               Folders only
          tree src/                                    Tree from specific path
          get_file_tree type=files mode=selected       Show only selected files

        get_code_structure (structure, map) - Get function/type signatures
          structure src/auth/                          Codemaps for directory (default considers up to 10 files)
          structure --scope selected                   Codemaps for selection (~6k token cap still applies)
          get_code_structure paths=["src/"] max_results=50   Opt in to consider more files (response still capped)

        workspace_context (context) - Get workspace snapshot
          context                                      Default snapshot
          context --all                                Include everything
          workspace_context include=["prompt","selection","code","tree"]

        prompt - CLI shorthand for canonical context tools
          prompt get                                   Show current prompt text
          prompt set "Review for security issues"      Set prompt text
          prompt export ~/context.md                   Export full LLM context
          prompt presets                               List copy presets

        app_settings - Read/update allowlisted app-wide RepoPrompt preferences
          app_settings op=list [group=<g>]             Catalog with current values
          app_settings op=get key=<k>|group=<g>        Read one key or a whole group
          app_settings op=set key=<k> value=<v>        Write; use JSON for fractions/null
          app_settings op=options key=<k> [agent=<a>]  Candidate values for keys that advertise options_available
          Operations: list, get, set, options
          Groups: ui, prompt_packaging, editing, models, context_builder, mcp, code_maps

        apply_edits - Find/replace in files (JSON args required)
          __RPCE_CLI__ -c apply_edits -j '{"path":"f.ts","search":"old","replace":"new"}'
          __RPCE_CLI__ -c apply_edits -j '{"path":"f.ts","search":"line1\\nline2","replace":"new"}'
          __RPCE_CLI__ -c apply_edits -j '{"path":"f.ts","edits":[{"search":"a","replace":"b"}]}'
          __RPCE_CLI__ -c apply_edits -j '{"path":"f.ts","rewrite":"new content"}'
          __RPCE_CLI__ -c apply_edits -j @edits.json         (from file with @ prefix)
          __RPCE_CLI__ -c apply_edits -j edits.json           (auto-detected .json file)
          echo '...' | __RPCE_CLI__ -c apply_edits -j @-      (from stdin)
          Note: Raw newlines/tabs in JSON strings are auto-repaired.

        file_actions - Create/delete/move files (JSON args required)
          __RPCE_CLI__ -c file_actions -j '{"action":"create","path":"src/new.ts"}'
          __RPCE_CLI__ -c file_actions -j '{"action":"create","path":"f.ts","content":"line1\\nline2"}'
          __RPCE_CLI__ -c file_actions -j '{"action":"delete","path":"/absolute/path/file.ts"}'
          __RPCE_CLI__ -c file_actions -j '{"action":"move","path":"old.ts","new_path":"new.ts"}'
          __RPCE_CLI__ -c file_actions -j @create-file.json    (from file with @ prefix)
          __RPCE_CLI__ -c file_actions -j create-file.json      (auto-detected .json file)
          echo '...' | __RPCE_CLI__ -c file_actions -j @-       (from stdin)
          Note: Raw newlines/tabs in JSON strings are auto-repaired.

        oracle_utils (oracle, models, chats) - Oracle helpers
          models                                       Show available oracle models
          chats                                        Compatibility alias for session listing
          oracle sessions --limit 10                   List recent sessions
          oracle_utils op=sessions limit=10

        bind_context (windows, use) - Discover/bind routing context
          windows                                      List windows, tabs, and context_id values
          bind_context op=status                       Show current binding
          bind_context op=bind context_id=<uuid>       Bind a specific compose context
          bind_context op=bind window_id=<id>          Bind a window without pinning a tab

        manage_workspaces (workspace, ws) - Manage workspaces/tab lifecycle
          workspace list                               List visible workspaces
          workspace list --include-hidden              Include recoverable hidden workspaces
          workspace hide MyProject                     Hide from default lists (non-destructive)
          workspace unhide MyProject                   Restore to default lists
          workspace switch MyProject                   Switch workspace
          workspace switch MyProject --include-hidden  Switch hidden workspace by name
          workspace switch MyProject --new-window      Open in NEW window (returns window_id)
          workspace create "New Project" --new-window  Create in NEW window (returns window_id)
          workspace create "New Project" --switch      Create and switch to it
          workspace delete MyProject --include-hidden  Delete hidden workspace by name
          tabs list                                    List tabs via bind_context
          tabs create "Feature Work"                   Create a new compose tab
          manage_workspaces action=create name="New Project"
          manage_workspaces action=create name="New Project" open_in_new_window=true
          manage_workspaces action=switch workspace=X open_in_new_window=true
          manage_workspaces action=list include_hidden=true
          manage_workspaces action=hide workspace=X
          manage_workspaces action=unhide workspace=X

        agent_run - Session-based agent run control (advanced, policy-gated)
          agent_run op=start message="Find auth bugs" Start run → session_id
          agent_run op=start message="Read the plan at prompt-exports/oracle-plan.md with read_file first. Implement item 1."
          agent_run op=wait session_id="<uuid>"        Block until input/terminal
          agent_run op=wait session_id="<uuid>" timeout=5  Bounded wait (seconds)
          agent_run op=wait session_ids=["<uuid1>","<uuid2>"] timeout=60
                                                        Wait for first of multiple sessions
          agent_run op=poll session_id="<uuid>"        Poll current snapshot
          agent_run op=poll session_ids=["<uuid1>","<uuid2>","<uuid3>"]
                                                        Poll multiple snapshots
          agent_run op=steer session_id="<uuid>" message="Also check logout"
          agent_run op=respond session_id="<uuid>" interaction_id="<id>" response="accept"
          agent_run op=cancel session_id="<uuid>"      Cancel run
          Operations: start, poll, wait, cancel, steer, respond
          wait accepts optional timeout (seconds, fractional OK). Defaults
          to 300s (5 min). timeout=0 returns current snapshot immediately.
          session_ids is accepted only for wait/poll and is mutually exclusive
          with session_id. Multi-wait returns the winning snapshot plus wait
          metadata (mode, result, winner_session_id, pending_session_ids).
          Multi-poll returns poll metadata plus a snapshots array.
          session_id is the control-plane identifier. Use agent_manage for durable session data.

        agent_manage - Session and workflow management (advanced, policy-gated)
          agent_manage op=list_agents                   List available agent providers
          agent_manage op=list_sessions limit=10        List sessions
          agent_manage op=get_log session_id="<id>"     Get transcript
          agent_manage handoff <id> --output handoff.xml  Export <forked_session> XML
          agent_manage op=extract_handoff session_id="<id>" output_path="/tmp/handoff.xml"
          agent_manage op=handoff session_id="<id>" inline=true  Alias for extract_handoff
          agent_manage op=create_session session_name="Auth work"
          agent_manage op=resume_session session_id="<id>"
          agent_manage op=stop_session session_id="<id>"   Stop a live session
          agent_manage op=list_workflows                List workflows
          Operations: list_agents, list_sessions, get_log, extract_handoff/handoff,
                      create_session, resume_session, stop_session, list_workflows

        Raw tool calls with JSON (for tools without shorthand syntax):
          __RPCE_CLI__ -c <tool> -j '{"param":"value"}'
          __RPCE_CLI__ -c manage_worktree -j '{"op":"list","include_graph":true,"graph_limit":8}'

        Direct raw tool calls with key=value args:
          __RPCE_CLI__ manage_worktree op=list include_graph=true graph_limit=8
          __RPCE_CLI__ -e 'manage_worktree op=preview session_id="<uuid>" target="@main"'

    OPTIONS:
        -e, --exec <cmd>       Execute command(s)
        -w, --window <id>      Target window ID
        -t, --tab <name>       Resolve/bind a tab by name or UUID at startup
        --context-id <uuid>    Bind directly to a canonical context
        --working-dir <path>   Explicit bind_context working_dirs selector (repeatable)
        -c, --call <tool>      Call tool directly (use with -j for JSON args)
        -j, --json <arg>       JSON for --call: inline, @file, @-, or path.json
        -d, --describe <tool>  Show full parameter docs (types, required, enums)
        -l, --list-tools       List all MCP tools
        --tools-schema         Print all tools as MCP tools/list-style JSON
        --tools-schema=git       Print git and manage_worktree schemas only
        --tools-schema=settings  Print app_settings schema only
        -q, --quiet            Suppress non-essential output
        --launch-app           Launch RepoPrompt app
        --raw-json             Raw JSON output (for scripting)
        --verbose              Show debug/timing info
        --fail-fast            Stop on first error in chain

    MULTI-WINDOW ROUTING:
        With one window: -w is optional. With multiple: bind or disambiguate explicitly.

        __RPCE_CLI__ -e 'windows'                          List windows, tabs, and context_id values
        __RPCE_CLI__ -w <id> -e 'context'                  Bind a window for this invocation
        __RPCE_CLI__ --context-id <uuid> -e 'context'      Bind a compose context directly
        __RPCE_CLI__ -w <id> -t <tab-or-uuid> -e 'context' Resolve/bind a tab in one step

        Prefer --context-id for compose-context targeting.
        Use -w only when you want window scope without a tab pin.

    MORE HELP:
        --help-interactive     REPL mode for exploration
        --help-scripting       Script files and workflow flags
        --help-advanced        Tab targeting, routing parameters

    TOOL SCHEMAS - Use -d <tool> to see complete parameter documentation:
        __RPCE_CLI__ -d manage_selection    Show selection params
        __RPCE_CLI__ -d file_search         See filter options and valid values
        __RPCE_CLI__ -d ask_oracle          See mode options and chat workflow
        __RPCE_CLI__ -d app_settings        App-wide preferences operations
        __RPCE_CLI__ -d manage_worktree     Worktree management and merge operations
        __RPCE_CLI__ -d agent_run           Agent run control operations
        __RPCE_CLI__ -d agent_manage        Session/workflow management operations

        Output includes: parameter names, types (string, array, object),
        required vs optional, allowed values (enums), and descriptions.
        Add --verbose to also see the raw JSON schema.

    MACHINE-READABLE SCHEMAS:
        __RPCE_CLI__ --tools-schema                 All tools as JSON (MCP tools/list format)
        __RPCE_CLI__ --tools-schema=explore         Only tools in the "explore" group
        __RPCE_CLI__ --tools-schema=git             Only git and manage_worktree
        __RPCE_CLI__ --tools-schema=settings        Only app_settings
        __RPCE_CLI__ -e 'tools --schema'            Same via exec mode
        __RPCE_CLI__ -e 'tools explore --schema'    Filter by group via exec mode
        __RPCE_CLI__ -e 'tools git --schema'        git/manage_worktree schemas via exec mode
        __RPCE_CLI__ -e 'tools settings --schema'   app_settings schema via exec mode
    """.replacingOccurrences(of: "__RPCE_CLI__", with: cliDisplayCommand())
    print(usage)
}

func printInteractiveUsage() {
    let usage = """
    RepoPrompt MCP CLI - Interactive Mode

    USAGE:
        __RPCE_CLI__ -i                  Start REPL
        __RPCE_CLI__ -i -w <id>          Start with window pre-selected

    Interactive mode provides a shell-like REPL for exploring the RepoPrompt
    workspace and calling tools. Commands use natural syntax instead of JSON.

    IMPORTANT: When multiple windows are open, you must select a window:
        __RPCE_CLI__ -i -w <id>          Pre-select window at startup
        windows                    List available windows (inside REPL)
        use <id>                   Select window for session (inside REPL)

    REPL COMMANDS:
        read ~/code/main.swift              Read a file
        search "pattern" ~/src              Search for pattern
        tree --folders                      Show folder structure
        select add file1.swift file2.swift  Add files to selection
        context --all                       Get full workspace context
        workspace list --include-hidden     Include recoverable hidden workspaces
        agent_manage handoff <uuid> --output handoff.xml  Export <forked_session> XML
        chat How does auth work?            Quick chat message
        edit main.swift old new --all       Find and replace
        builder "Find auth code"            Run context builder
        builder "Add logout" --response-type plan --export
                                            Generate an exported plan file
        app_settings op=get key=ui.appearance_mode
                                            Read an app-wide preference

        Type 'help' inside the REPL for the full command list.

    ONE-SHOT FLAGS (run and exit):
        -l, --list-tools           List all tools with full schemas
        --list-tools=<groups>      List tools in specific groups (e.g., explore,git,edit,settings)
        --list-tools=groups        List available tool group names
        --tools-schema             Print all tools as MCP tools/list JSON (machine-readable)
        --tools-schema=<groups>    Print tools in specific groups as JSON (e.g., git,settings)
        -d, --describe <tool>      Describe a specific tool's parameters
        -c, --call <tool>          Call a tool directly
        -j, --json <arg>           JSON for --call (see JSON ARGUMENTS below)
        -s, --snapshot-tools <path>  Save tool list to JSON file

    JSON ARGUMENTS (-j / --json):
        Inline JSON:     -j '{"path":"file.txt"}'
        From file:       -j @/path/to/args.json    or   -j /path/to/args.json
        From stdin:      echo '{"path":"..."}' | __RPCE_CLI__ -c tool -j @-
        Auto-repair:     Multiline strings with raw newlines are auto-escaped

    EXAMPLES:
        # Explore available tools
        __RPCE_CLI__ -l
        __RPCE_CLI__ --list-tools=explore
        __RPCE_CLI__ --tools-schema > tools.json
        __RPCE_CLI__ --tools-schema=settings
        __RPCE_CLI__ --tools-schema=git
        __RPCE_CLI__ -d file_search
        __RPCE_CLI__ -d manage_worktree              # Worktree management/merge schemas
        __RPCE_CLI__ -d agent_run                    # Agent run control schemas
        __RPCE_CLI__ -d agent_manage                 # Session/workflow schemas

        # Call a tool directly
        __RPCE_CLI__ -c read_file -j '{"path":"/tmp/test.txt"}'
        __RPCE_CLI__ -c manage_worktree -j '{"op":"list","include_graph":true,"graph_limit":8}'
        __RPCE_CLI__ -e 'manage_worktree op=list include_graph=true graph_limit=8'
        __RPCE_CLI__ -c read_file -j args.json
        __RPCE_CLI__ -c read_file -j @args.json

        # Save tool snapshot for documentation
        __RPCE_CLI__ -s ~/tools.json

    OUTPUT OPTIONS:
        --raw-json                 Raw JSON output (for scripting)
        --verbose                  Show debug/timing info

    """.replacingOccurrences(of: "__RPCE_CLI__", with: cliDisplayCommand())
    print(usage)
}

func printScriptingUsage() {
    let usage = """
    RepoPrompt MCP CLI - Scripting & Workflow Flags

    SCRIPT FILES (.rp):
        __RPCE_CLI__ --exec-file ~/scripts/export.rp

        Script files contain one command per line. Lines starting with # are comments.
        Commands can use output redirection (> file.txt).

        Example script (export.rp):
            # Export context from MyProject
            workspace switch MyProject
            select set src/
            context --all > output.md

    LAUNCHING THE APP:
        __RPCE_CLI__ --launch-app                       Launch RepoPrompt app

    READING FROM STDIN:
        echo 'tree' | __RPCE_CLI__ --exec-stdin
        cat commands.txt | __RPCE_CLI__ --exec-stdin

    MULTIPLE EXEC FLAGS:
        Multiple -e flags run in order (each is a separate command):

        __RPCE_CLI__ -e 'workspace MyProject' \\
                       -e 'select set src/' \\
                       -e 'context > out.md'

    WORKFLOW SHORTHAND FLAGS:
        These flags compile to exec commands for common workflows:

        --workspace <name>       → workspace switch "<name>"
        --select-add <paths>     → select add <paths>
        --select-set <paths>     → select set <paths>
        --export-context <file>  → context --all > "<file>" (JSON workspace snapshot)
        --export-prompt <file>   → prompt export "<file>" (full LLM-ready context)
        --chat <message>         → chat <message>
        --builder <instructions> → builder <instructions>

        Example:
        __RPCE_CLI__ --workspace MyProject --select-set src/ --export-context ~/out.md

        Is equivalent to:
        __RPCE_CLI__ -e 'workspace switch "MyProject" && select set src/ && context --all > "~/out.md"'

    EXEC OPTIONS:
        -w, --window <id>        Bind a window at startup (disambiguate when needed)
        -t, --tab <name>         Resolve/bind a tab by name or UUID at startup
        --json, -j <arg>         JSON args: inline, @file, @-, or path.json
        --wait-for-server <s>    Wait up to N seconds for server
        --tool-timeout <s>       Tool call timeout seconds (default 300, 0 disables)
        --fail-fast              Stop on first command failure
        -q, --quiet              Suppress non-essential output
        --verbose                Show debug/timing info
        --raw-json               Raw JSON output (for scripting)
        --launch-app             Launch RepoPrompt app

    MULTI-WINDOW NOTE:
        Scripts should bind explicitly with -w and/or --context-id for deterministic behavior.

        Example:
        __RPCE_CLI__ -w 1 -t MyTab -e 'select set src/ && context > out.md'

    EXIT CODES:
        0    Success
        1    Command execution failed
        73   Connection failed
        74   Approval denied
        75   Script file not found
        78   Parse error

    """.replacingOccurrences(of: "__RPCE_CLI__", with: cliDisplayCommand())
    print(usage)
}

func printAdvancedUsage() {
    let usage = """
    RepoPrompt MCP CLI - Advanced Options

    TAB TARGETING:
        Workspaces can have multiple compose tabs, each with different file selections
        and prompts. `context_id` is the canonical compose-context handle.

        # List available tabs / context_id values
        __RPCE_CLI__ -e 'windows'

        # Target a specific tab with -t flag or --context-id (recommended)
        __RPCE_CLI__ -w 1 -t MyTab -e 'context'
        __RPCE_CLI__ --context-id <uuid> -e 'chat Hello'

        # Or pass hidden routing params directly to any tool call
        __RPCE_CLI__ -e 'call get_file_tree {"_windowID":1,"context_id":"<uuid>"}'

    HIDDEN ROUTING PARAMETERS:
        These parameters can be passed to any tool call for explicit routing:

        _windowID    Target a specific window (by ID from bind_context / windows)
        context_id   Target a specific compose context (UUID from bind_context / windows)
        _tabID       Legacy low-level tab routing override (advanced/manual control)

        Example:
        __RPCE_CLI__ -e 'call read_file {"path":"src/main.swift","_windowID":2,"context_id":"<uuid>"}'

    CONNECTION BINDING VS PARAMETER PASSING:
        - Interactive mode (-i): Use 'use <id>' or bind_context to bind
          your session. The binding persists for subsequent commands in the REPL.

        - Exec mode (-e): Each invocation is a fresh connection. Startup flags
          like -w, -t, and --context-id apply an explicit bind_context bind for
          that invocation before your command chain runs.

        CRITICAL FOR AI AGENTS:
          When multiple windows exist, prefer --context-id for compose-context work.

          Example workflow:
          __RPCE_CLI__ -e 'windows'                    # Discover windows and context_id values
          __RPCE_CLI__ --context-id <uuid> -e 'context' # Get context from a specific tab

    MULTI-ROOT WORKSPACES:
        Workspaces can have multiple root folders. File paths in tool responses
        are prefixed with the root name when ambiguous:

        MyProject/src/main.swift    (from MyProject root)
        OtherRoot/src/main.swift    (from OtherRoot)

    """.replacingOccurrences(of: "__RPCE_CLI__", with: cliDisplayCommand())
    print(usage)
}

func printVersion() {
    print("\(cliDisplayCommand()) (repoprompt-mcp) \(CLI_VERSION)")
}

private let repoPromptCEReleaseBundleIdentifier = "com.pvncher.repoprompt.ce"
private let repoPromptCEDebugBundleIdentifier = "com.pvncher.repoprompt.ce.debug"
private let repoPromptCEBundleIdentifier: String = {
    #if DEBUG
        return repoPromptCEDebugBundleIdentifier
    #else
        return repoPromptCEReleaseBundleIdentifier
    #endif
}()

/// Launches the RepoPrompt app that contains this CLI, falling back to Launch Services.
func launchRepoPromptApp() {
    let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let appURL = executableURL
        .deletingLastPathComponent() // MacOS
        .deletingLastPathComponent() // Contents
        .deletingLastPathComponent() // RepoPrompt.app

    let targetPath: String = if appURL.pathExtension == "app" && FileManager.default.fileExists(atPath: appURL.path) {
        appURL.path
    } else {
        "-b \(repoPromptCEBundleIdentifier)"
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = targetPath.hasPrefix("-b ")
        ? ["-b", String(targetPath.dropFirst(3))]
        : [targetPath]
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        fputs("Error: Failed to launch RepoPrompt CE app: \(error)\n", stderr)
        exit(1)
    }
}

// MARK: - Debug Helpers

#if DEBUG
    /// Recursively unwraps UncheckedSendableValue values for JSON serialization.
    /// Converts nested wrapper types to plain Foundation types that JSONSerialization can handle.
    fileprivate func unwrapForSerialization(_ value: Any) -> Any {
        switch value {
        case let wrapped as UncheckedSendableValue:
            return unwrapForSerialization(wrapped.value)
        case let array as [UncheckedSendableValue]:
            return array.map { unwrapForSerialization($0.value) }
        case let array as [Any]:
            return array.map { unwrapForSerialization($0) }
        case let dict as [String: UncheckedSendableValue]:
            var result: [String: Any] = [:]
            for (k, v) in dict {
                result[k] = unwrapForSerialization(v.value)
            }
            return result
        case let dict as [String: Any]:
            var result: [String: Any] = [:]
            for (k, v) in dict {
                result[k] = unwrapForSerialization(v)
            }
            return result
        case is NSNull:
            return NSNull()
        default:
            return value
        }
    }

    /// Tests command parsing without executing. Used for automated parser testing.
    /// Outputs JSON with parsing results for verification by test scripts.
    func testParseCommand(_ input: String) {
        let ctx = CommandParseContext()

        do {
            let command = try MCPCommandParser.parseCommand(input, ctx: ctx)

            // Convert command to JSON-serializable format
            var result: [String: Any] = [
                "success": true,
                "input": input
            ]

            switch command {
            case .help:
                result["command"] = "help"
            case let .tools(mode):
                result["command"] = "tools"
                result["mode"] = String(describing: mode)
            case let .toolsSchema(mode):
                result["command"] = "toolsSchema"
                result["mode"] = String(describing: mode)
            case let .describe(toolName):
                result["command"] = "describe"
                result["toolName"] = toolName
            case let .call(toolName, jsonPayload):
                result["command"] = "call"
                result["toolName"] = toolName
                result["jsonPayload"] = jsonPayload as Any
            case let .aliasCall(toolName, args):
                result["command"] = "aliasCall"
                result["toolName"] = toolName
                // Convert args to serializable format (recursively unwrap UncheckedSendableValue)
                var argsDict: [String: Any] = [:]
                for (key, value) in args {
                    argsDict[key] = unwrapForSerialization(value.value)
                }
                result["args"] = argsDict
            case .windows:
                result["command"] = "windows"
            case let .useWindow(windowID):
                result["command"] = "useWindow"
                result["windowID"] = windowID
            case .clearWindow:
                result["command"] = "clearWindow"
            case let .snapshot(path):
                result["command"] = "snapshot"
                result["path"] = path
            case .refresh:
                result["command"] = "refresh"
            case .exit:
                result["command"] = "exit"
            case .history:
                result["command"] = "history"
            case .showSettings:
                result["command"] = "showSettings"
            case let .setSetting(name, value):
                result["command"] = "setSetting"
                result["name"] = name
                result["value"] = value as Any
            case .clearScreen:
                result["command"] = "clearScreen"
            case .status:
                result["command"] = "status"
            case .pwd:
                result["command"] = "pwd"
            case let .cd(path):
                result["command"] = "cd"
                result["path"] = path
            }

            if let jsonData = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
               let jsonString = String(data: jsonData, encoding: .utf8)
            {
                print(jsonString)
            }
        } catch {
            let result: [String: Any] = [
                "success": false,
                "input": input,
                "error": String(describing: error)
            ]
            if let jsonData = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
               let jsonString = String(data: jsonData, encoding: .utf8)
            {
                print(jsonString)
            }
        }
    }
#endif

// MARK: - Entry Point

// Ignore SIGPIPE to prevent crashes when stdout pipe breaks.
// We detect broken pipes via write() errors instead.
signal(SIGPIPE, SIG_IGN)

/// Parse CLI mode
let mode = parseCLIMode()

// Exec mode is a bounded one-shot command runner. Run it directly instead of
// through ServiceGroup so completion exits deterministically.
if case let .exec(options) = mode {
    let service = ExecMCPService(options: options, logger: log)
    do {
        try await service.run()
        exit(MCPCLIExitCode.ok.rawValue)
    } catch let err as CLIRuntimeError {
        handleRuntimeError(err)
    } catch let err as InteractiveSessionError {
        fputs("RepoPrompt MCP: \(err.description)\n", stderr)
        exit(MCPCLIExitCode.connectionFailed.rawValue)
    } catch let err as ExecError {
        switch err {
        case .commandFailed:
            exit(ExecExitCode.commandFailed.rawValue)
        case let .scriptNotFound(path):
            fputs("RepoPrompt MCP: Script not found: \(path)\n", stderr)
            exit(ExecExitCode.scriptNotFound.rawValue)
        case let .scriptReadError(underlying):
            fputs("RepoPrompt MCP: Failed to read script: \(underlying)\n", stderr)
            exit(ExecExitCode.scriptNotFound.rawValue)
        }
    } catch {
        fputs("Error: \(error)\n", stderr)
        exit(MCPCLIExitCode.unknownError.rawValue)
    }
}

/// Create appropriate service based on mode
let service: any Service
switch mode {
case .proxy:
    // In proxy mode, only show help when directly launched from a terminal.
    // IMPORTANT: Do not infer "user mode" from a short stdin poll timeout.
    // MCP hosts can legitimately take >200ms before sending initialize, and
    // timing-based detection causes false exits during startup races.
    let stdinIsTTY = isatty(STDIN_FILENO) != 0
    let stdoutIsTTY = isatty(STDOUT_FILENO) != 0
    let hasNoUserArgs = CommandLine.arguments.count <= 1

    if stdinIsTTY || stdoutIsTTY || (hasNoUserArgs && (!stdinLooksLikeMCPTransport() || stdinHasImmediateDisconnect())) {
        let usage = """
        RepoPrompt MCP CLI

        This command is designed to be used as an MCP server by host applications
        (Claude Desktop, Cursor, etc.) or with explicit mode flags.

        Quick start:
          __RPCE_CLI__ -l                    # List available tools
          __RPCE_CLI__ -e 'tree'             # Execute a command
          __RPCE_CLI__ -i                    # Interactive REPL
          __RPCE_CLI__ --help                # Full help

        """.replacingOccurrences(of: "__RPCE_CLI__", with: cliDisplayCommand())
        fputs(usage, stderr)
        exit(0)
    }
    service = MCPService()
case let .interactive(options):
    service = InteractiveMCPService(options: options, logger: log)
case let .exec(options):
    service = ExecMCPService(options: options, logger: log)
}

/// Use a quiet logger for ServiceLifecycle to suppress internal debug output
let lifecycleLogger: Logger = .init(label: "ServiceLifecycle") { _ in
    SwiftLogNoOpLogHandler() // Suppress all ServiceLifecycle internal logging
}

let lifecycle = ServiceGroup(
    configuration: .init(
        services: [service],
        logger: lifecycleLogger
    )
)

do {
    try await lifecycle.run()
    exit(MCPCLIExitCode.ok.rawValue)
} catch let err as CLIRuntimeError {
    handleRuntimeError(err)
} catch let err as InteractiveSessionError {
    // Handle interactive mode errors
    fputs("RepoPrompt MCP: \(err.description)\n", stderr)
    exit(MCPCLIExitCode.connectionFailed.rawValue)
} catch let err as ExecError {
    // Handle exec mode errors
    switch err {
    case .commandFailed:
        exit(ExecExitCode.commandFailed.rawValue)
    case let .scriptNotFound(path):
        fputs("RepoPrompt MCP: Script not found: \(path)\n", stderr)
        exit(ExecExitCode.scriptNotFound.rawValue)
    case let .scriptReadError(underlying):
        fputs("RepoPrompt MCP: Failed to read script: \(underlying)\n", stderr)
        exit(ExecExitCode.scriptNotFound.rawValue)
    }
} catch {
    // ServiceLifecycle throws "A service has finished unexpectedly" when a service
    // completes normally (e.g., --list-tools). Treat this as success for interactive mode.
    let errorDesc = String(describing: error)
    if errorDesc.contains("service has finished unexpectedly") ||
        errorDesc.contains("ServiceGroupError")
    {
        // Service completed normally - this is expected for single-shot commands
        exit(MCPCLIExitCode.ok.rawValue)
    }

    fputs("Error: \(error)\n", stderr)
    exit(MCPCLIExitCode.unknownError.rawValue)
}
