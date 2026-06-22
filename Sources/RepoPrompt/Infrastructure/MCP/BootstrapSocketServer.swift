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
import RepoPromptShared

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

/// Lock-protected ownership wrapper for accepted sockets that are still in the
/// bootstrap handshake. Blocking handshake reads run outside actor isolation,
/// while stop() must be able to invalidate and close these sockets immediately.
private final class BootstrapHandshakeSocket: @unchecked Sendable {
    private enum Ownership: Equatable {
        case serverOwnedOpen
        case serverOwnedClosing
        case transferred
        case closed
    }

    let fd: Int32

    private let lock = NSLock()
    private var ownership: Ownership = .serverOwnedOpen
    private var activeIOLeases = 0
    private var shutdownInProgress = false
    #if DEBUG
        private let debugBeforeInitiatingShutdown: (() -> Void)?
    #endif

    init(fd: Int32) {
        self.fd = fd
        #if DEBUG
            debugBeforeInitiatingShutdown = nil
        #endif
    }

    #if DEBUG
        init(fd: Int32, debugBeforeInitiatingShutdown: @escaping () -> Void) {
            self.fd = fd
            self.debugBeforeInitiatingShutdown = debugBeforeInitiatingShutdown
        }
    #endif

    func isServerOwnedOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .serverOwnedOpen = ownership else { return false }
        return true
    }

    /// Runs one blocking syscall while preventing the numeric FD from being closed
    /// and reused underneath it. stop() still calls shutdown immediately to wake I/O;
    /// final close occurs when the last lease exits.
    func withServerOwnedIOLease<T>(_ body: (Int32) -> T) -> T? {
        lock.lock()
        guard case .serverOwnedOpen = ownership else {
            lock.unlock()
            return nil
        }
        activeIOLeases += 1
        lock.unlock()

        let result = body(fd)
        releaseIOLease()
        return result
    }

    func shutdownAndCloseIfServerOwned() {
        lock.lock()
        guard case .serverOwnedOpen = ownership else {
            lock.unlock()
            return
        }
        ownership = .serverOwnedClosing
        // A lease release must not close and recycle the numeric FD before this
        // initiating shutdown call has used it.
        shutdownInProgress = true
        lock.unlock()

        #if DEBUG
            debugBeforeInitiatingShutdown?()
        #endif
        POSIXDescriptorSupport.shutdownSocketReadWrite(fd)

        lock.lock()
        shutdownInProgress = false
        let shouldClose = activeIOLeases == 0 && ownership == .serverOwnedClosing
        if shouldClose {
            ownership = .closed
        }
        lock.unlock()

        if shouldClose {
            Darwin.close(fd)
        }
    }

    /// Atomically leaves handshake ownership and publishes the transferred descriptor
    /// into the manager's synchronous full-shutdown ledger. If the receiving lifecycle
    /// is already invalid, this method closes the descriptor itself.
    func transferOwnershipIfOpen(
        publishTransferredFD: (Int32) -> Bool
    ) -> Bool {
        lock.lock()
        guard case .serverOwnedOpen = ownership, activeIOLeases == 0 else {
            lock.unlock()
            return false
        }
        ownership = .transferred
        let wasPublished = publishTransferredFD(fd)
        lock.unlock()

        if !wasPublished {
            POSIXDescriptorSupport.shutdownSocketReadWrite(fd)
            Darwin.close(fd)
        }
        return wasPublished
    }

    private func releaseIOLease() {
        lock.lock()
        activeIOLeases -= 1
        let shouldClose = activeIOLeases == 0
            && ownership == .serverOwnedClosing
            && !shutdownInProgress
        if shouldClose {
            ownership = .closed
        }
        lock.unlock()

        if shouldClose {
            Darwin.close(fd)
        }
    }
}

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
    private var socketOwnership: BootstrapSocketOwnership?
    private var isRunning = false
    /// One-way tombstone for this listener actor. A stop queued ahead of start must
    /// prevent that later start intent from binding after full shutdown returns.
    private var stopRequested = false
    private var acceptSource: DispatchSourceRead?

    /// Backpressure: cap the number of accepted sockets that are mid-handshake.
    /// Prevents FD exhaustion during connection storms.
    private let maxInFlightHandshakes: Int = 32
    private var listenerGeneration: UInt64 = 0
    private var inFlightHandshakeSockets: [UUID: BootstrapHandshakeSocket] = [:]
    private var acceptSuspendedForBackpressure: Bool = false
    private var drainInProgress: Bool = false
    private var drainRequestedWhileBusy: Bool = false

    /// Result of connection admission decision
    struct Admission {
        let accepted: Bool
        /// Called synchronously while handshake ownership is transferred. The receiver
        /// must publish the descriptor into storage visible to full shutdown.
        let publishTransferredFD: (@Sendable (Int32) -> Bool)?
        /// Called after the bootstrap server successfully sends the accepted response
        /// and synchronously publishes transferred descriptor ownership.
        /// This is where MCP server startup should be scheduled.
        let postAccept: (@Sendable () async -> Void)?
        /// Called if a reserved acceptance is abandoned before deferred startup commits.
        /// Used to release the reserved slot and clean up any pre-commit state.
        let onAcceptAborted: (@Sendable () async -> Void)?
        /// Optional override rejection response
        let rejection: MCPBootstrapResponse?

        static func accept(
            publishTransferredFD: @escaping @Sendable (Int32) -> Bool,
            postAccept: @escaping @Sendable () async -> Void,
            onAcceptAborted: (@Sendable () async -> Void)? = nil
        ) -> Self {
            .init(
                accepted: true,
                publishTransferredFD: publishTransferredFD,
                postAccept: postAccept,
                onAcceptAborted: onAcceptAborted,
                rejection: nil
            )
        }

        static func reject(_ response: MCPBootstrapResponse? = nil) -> Self {
            .init(accepted: false, publishTransferredFD: nil, postAccept: nil, onAcceptAborted: nil, rejection: response)
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
        guard !stopRequested else { throw BootstrapSocketError.startCancelled }
        guard !isRunning else { return }

        self.onNewConnection = onNewConnection

        // Ensure socket directory exists with secure permissions
        MCPFilesystemConstants.ensureSocketDirectoryExists()
        #if DEBUG
            print("[MCPStartup] ensured socket dir=\(socketURL.deletingLastPathComponent().path) exists=\(FileManager.default.fileExists(atPath: socketURL.deletingLastPathComponent().path))")
        #endif

        let ownership = try BootstrapSocketOwnership.acquire(socketURL: socketURL)
        socketOwnership = ownership
        do {
            try ownership.preparePathForBinding()
        } catch {
            socketOwnership = nil
            ownership.release()
            throw error
        }

        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            socketOwnership = nil
            ownership.release()
            throw BootstrapSocketError.socketCreationFailed(errno: errno)
        }

        do {
            try POSIXDescriptorSupport.setCloseOnExec(fd)
        } catch {
            Darwin.close(fd)
            socketOwnership = nil
            ownership.release()
            let descriptorError = error as? POSIXDescriptorConfigurationError
                ?? .setDescriptorFlagsFailed(fd: fd, errno: errno)
            throw BootstrapSocketError.descriptorConfigurationFailed(role: "listener", error: descriptorError)
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
            socketOwnership = nil
            ownership.release()
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
            socketOwnership = nil
            ownership.release()
            throw BootstrapSocketError.bindFailed(errno: bindErrno)
        }

        do {
            try ownership.captureBoundSocketIdentity()
        } catch {
            Darwin.close(fd)
            _ = ownership.removeOwnedSocketIfCurrent()
            socketOwnership = nil
            ownership.release()
            throw error
        }

        // Listen with generous backlog for connection bursts
        guard listen(fd, 128) == 0 else {
            let listenErrno = errno
            Darwin.close(fd)
            _ = ownership.removeOwnedSocketIfCurrent()
            socketOwnership = nil
            ownership.release()
            throw BootstrapSocketError.listenFailed(errno: listenErrno)
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

    #if DEBUG
        struct DebugHandshakeIOLeaseShutdownRaceResult {
            let remainedOpenUntilInitiatingShutdown: Bool
            let closedAfterShutdownFinished: Bool
            let peerObservedEOF: Bool
        }

        enum DebugHandshakeIOLeaseShutdownRaceError: Error {
            case socketPairCreationFailed(errno: Int32)
            case timedOut(phase: String)
        }

        func debugListenerHasCloseOnExec() -> Bool? {
            guard isRunning, listenFD >= 0 else { return nil }
            let flags = fcntl(listenFD, F_GETFD)
            guard flags >= 0 else { return false }
            return (flags & FD_CLOEXEC) != 0
        }

        nonisolated static func debugExerciseHandshakeIOLeaseReleaseRacingShutdown() throws -> DebugHandshakeIOLeaseShutdownRaceResult {
            var descriptors = [Int32](repeating: -1, count: 2)
            guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw DebugHandshakeIOLeaseShutdownRaceError.socketPairCreationFailed(errno: errno)
            }
            let workerGroup = DispatchGroup()
            let leaseStarted = DispatchSemaphore(value: 0)
            let releaseLease = DispatchSemaphore(value: 0)
            let leaseFinished = DispatchSemaphore(value: 0)
            let initiatingShutdown = DispatchSemaphore(value: 0)
            let continueShutdown = DispatchSemaphore(value: 0)
            let shutdownFinished = DispatchSemaphore(value: 0)
            defer {
                releaseLease.signal()
                continueShutdown.signal()
                if workerGroup.wait(timeout: .now() + 2) == .success {
                    if fcntl(descriptors[0], F_GETFD) >= 0 { Darwin.close(descriptors[0]) }
                    if fcntl(descriptors[1], F_GETFD) >= 0 { Darwin.close(descriptors[1]) }
                }
            }

            let handshakeSocket = BootstrapHandshakeSocket(
                fd: descriptors[0],
                debugBeforeInitiatingShutdown: {
                    initiatingShutdown.signal()
                    continueShutdown.wait()
                }
            )
            workerGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { workerGroup.leave() }
                _ = handshakeSocket.withServerOwnedIOLease { _ in
                    leaseStarted.signal()
                    releaseLease.wait()
                }
                leaseFinished.signal()
            }
            try debugWait(leaseStarted, phase: "lease start")

            workerGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { workerGroup.leave() }
                handshakeSocket.shutdownAndCloseIfServerOwned()
                shutdownFinished.signal()
            }
            try debugWait(initiatingShutdown, phase: "shutdown initiation")

            releaseLease.signal()
            try debugWait(leaseFinished, phase: "lease release")
            let remainedOpenUntilInitiatingShutdown = fcntl(descriptors[0], F_GETFD) >= 0

            continueShutdown.signal()
            try debugWait(shutdownFinished, phase: "shutdown finish")
            errno = 0
            let closedAfterShutdownFinished = fcntl(descriptors[0], F_GETFD) == -1 && errno == EBADF
            let peerObservedEOF = debugPeerObservedEOF(on: descriptors[1])
            return .init(
                remainedOpenUntilInitiatingShutdown: remainedOpenUntilInitiatingShutdown,
                closedAfterShutdownFinished: closedAfterShutdownFinished,
                peerObservedEOF: peerObservedEOF
            )
        }

        private nonisolated static func debugWait(_ semaphore: DispatchSemaphore, phase: String) throws {
            guard semaphore.wait(timeout: .now() + 2) == .success else {
                throw DebugHandshakeIOLeaseShutdownRaceError.timedOut(phase: phase)
            }
        }

        private nonisolated static func debugPeerObservedEOF(on fd: Int32) -> Bool {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            guard Darwin.poll(&descriptor, 1, 2000) > 0 else { return false }
            var byte: UInt8 = 0
            return Darwin.recv(fd, &byte, 1, Int32(MSG_PEEK | MSG_DONTWAIT)) == 0
        }
    #endif

    /// Stops the bootstrap socket server.
    func stop() {
        // Record intent even if start() has not run yet. Actor message ordering can
        // otherwise allow a queued start to bind after its parent's full stop returns.
        stopRequested = true
        onNewConnection = nil
        guard isRunning else { return }
        isRunning = false
        listenerGeneration &+= 1

        // IMPORTANT: If a DispatchSource is suspended, you must resume it before cancel/deinit
        // to avoid crashes from unbalanced suspend/resume.
        if acceptSuspendedForBackpressure {
            acceptSource?.resume()
            acceptSuspendedForBackpressure = false
        }

        acceptSource?.cancel()
        acceptSource = nil
        drainRequestedWhileBusy = false

        if listenFD >= 0 {
            POSIXDescriptorSupport.shutdownSocketReadWrite(listenFD)
            Darwin.close(listenFD)
            listenFD = -1
        }

        for socket in inFlightHandshakeSockets.values {
            socket.shutdownAndCloseIfServerOwned()
        }
        inFlightHandshakeSockets.removeAll()

        // Remove only the pathname that still identifies this listener.
        socketOwnership?.removeOwnedSocketIfCurrent()
        socketOwnership?.release()
        socketOwnership = nil

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
        let sourceGeneration = listenerGeneration
        source.setCancelHandler { [weak self] in
            Task { await self?.acceptSourceDidCancel(generation: sourceGeneration) }
        }

        acceptSource = source
        source.resume()
    }

    private func acceptSourceDidCancel(generation: UInt64) {
        guard listenerGeneration == generation else { return }
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
        guard inFlightHandshakeSockets.count < maxInFlightHandshakes else {
            suspendAcceptSourceForBackpressureIfNeeded()
            return
        }

        while isRunning, listenFD >= 0, inFlightHandshakeSockets.count < maxInFlightHandshakes {
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

            do {
                try POSIXDescriptorSupport.setCloseOnExec(clientFD)
            } catch {
                POSIXDescriptorSupport.shutdownSocketReadWrite(clientFD)
                Darwin.close(clientFD)
                logger.error("BootstrapSocketServer: failed to configure accepted fd \(clientFD): \(String(describing: error))")
                continue
            }

            let handshakeID = UUID()
            let handshakeSocket = BootstrapHandshakeSocket(fd: clientFD)
            let generation = listenerGeneration
            inFlightHandshakeSockets[handshakeID] = handshakeSocket
            let lifecycleCorrelation = EditFlowPerf.makeLifecycleCorrelationIfActive()
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.Bootstrap.socketAccepted,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(activeCount: inFlightHandshakeSockets.count)
            )
            Task {
                await self.handleNewConnectionWithBackpressure(
                    handshakeID: handshakeID,
                    handshakeSocket: handshakeSocket,
                    generation: generation,
                    lifecycleCorrelation: lifecycleCorrelation
                )
            }
        }

        // If we hit the limit, suspend to avoid repeated readability callbacks.
        if inFlightHandshakeSockets.count >= maxInFlightHandshakes {
            suspendAcceptSourceForBackpressureIfNeeded()
        }
    }

    private func suspendAcceptSourceForBackpressureIfNeeded() {
        guard !acceptSuspendedForBackpressure else { return }
        acceptSource?.suspend()
        acceptSuspendedForBackpressure = true
        bootstrapSocketServerLog("BootstrapSocketServer: accept source suspended (inFlightHandshakes=\(inFlightHandshakeSockets.count))")
    }

    private func resumeAcceptSourceIfNeeded() {
        guard acceptSuspendedForBackpressure else { return }
        acceptSource?.resume()
        acceptSuspendedForBackpressure = false
        bootstrapSocketServerLog("BootstrapSocketServer: accept source resumed (inFlightHandshakes=\(inFlightHandshakeSockets.count))")

        // Proactively drain again (don't rely on a fresh readability edge).
        drainAcceptQueue()
    }

    // MARK: - Health Diagnostics

    struct ListenerDiagnostics {
        let isRunning: Bool
        let listenFDValid: Bool
        let ownsSocketPath: Bool
        let socketPathStatus: BootstrapSocketOwnership.PathStatus?
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

        let pathStatus = socketOwnership?.pathStatus()
        return ListenerDiagnostics(
            isRunning: isRunning,
            listenFDValid: fdValid,
            ownsSocketPath: pathStatus == .owned,
            socketPathStatus: pathStatus,
            acceptSourceExists: acceptSource != nil,
            acceptSuspendedForBackpressure: acceptSuspendedForBackpressure,
            inFlightHandshakes: inFlightHandshakeSockets.count,
            maxInFlightHandshakes: maxInFlightHandshakes
        )
    }

    func ensureAccepting() {
        guard isRunning, listenFD >= 0, socketOwnership?.pathStatus() == .owned else { return }
        if acceptSource == nil {
            do {
                try startAcceptSource()
            } catch {
                logger.error("BootstrapSocketServer: failed to ensure accept source: \(String(describing: error))")
            }
        }
        if acceptSuspendedForBackpressure, inFlightHandshakeSockets.count < maxInFlightHandshakes {
            resumeAcceptSourceIfNeeded()
        }
    }

    private func handleNewConnectionWithBackpressure(
        handshakeID: UUID,
        handshakeSocket: BootstrapHandshakeSocket,
        generation: UInt64,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
    ) async {
        defer {
            handshakeSocket.shutdownAndCloseIfServerOwned()
            inFlightHandshakeSockets.removeValue(forKey: handshakeID)
            // If we were paused and now have room, resume accepting.
            if inFlightHandshakeSockets.count < maxInFlightHandshakes {
                resumeAcceptSourceIfNeeded()
            }
        }
        if let lifecycleCorrelation {
            await EditFlowPerf.$currentLifecycleCorrelation.withValue(lifecycleCorrelation) {
                await handleNewConnection(
                    handshakeID: handshakeID,
                    handshakeSocket: handshakeSocket,
                    generation: generation,
                    lifecycleCorrelation: lifecycleCorrelation
                )
            }
        } else {
            await handleNewConnection(
                handshakeID: handshakeID,
                handshakeSocket: handshakeSocket,
                generation: generation,
                lifecycleCorrelation: nil
            )
        }
    }

    private func isActiveHandshake(_ handshakeSocket: BootstrapHandshakeSocket, generation: UInt64) -> Bool {
        isRunning && listenerGeneration == generation && handshakeSocket.isServerOwnedOpen()
    }

    private func abortAcceptedAdmissionIfNeeded(_ admission: Admission) async {
        guard admission.accepted, let rollback = admission.onAcceptAborted else { return }
        await rollback()
    }

    /// Handles a new client connection: read handshake, validate, callback.
    private func handleNewConnection(
        handshakeID: UUID,
        handshakeSocket: BootstrapHandshakeSocket,
        generation: UInt64,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
    ) async {
        let clientFD = handshakeSocket.fd
        bootstrapSocketServerLog("BootstrapSocketServer: new connection on fd \(clientFD)")
        guard isActiveHandshake(handshakeSocket, generation: generation) else { return }

        // Set blocking mode for simpler handshake I/O
        let flags = fcntl(clientFD, F_GETFL)
        _ = fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK)

        // Disable SIGPIPE on client socket
        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Read handshake request (with timeout)
        guard let request = await readHandshakeRequestAsync(
            from: handshakeSocket,
            lifecycleCorrelation: lifecycleCorrelation
        ) else {
            if isActiveHandshake(handshakeSocket, generation: generation) {
                logger.warning("BootstrapSocketServer: failed to read handshake from fd \(clientFD)")
            }
            return
        }

        guard isActiveHandshake(handshakeSocket, generation: generation) else { return }

        let peerPid = Self.peerPID(for: clientFD)
        let effectivePid = peerPid ?? request.clientPid
        if let peerPid, peerPid != request.clientPid {
            bootstrapSocketServerLog("BootstrapSocketServer: clientPid mismatch (request=\(request.clientPid), peer=\(peerPid)); using peer pid")
        }

        bootstrapSocketServerLog("BootstrapSocketServer: handshake from '\(request.clientName ?? "unknown")' session=\(request.sessionToken.prefix(8))...")

        // Validate protocol version
        guard request.protocolVersion == MCPBootstrapProtocol.currentVersion else {
            logger.warning("BootstrapSocketServer: protocol version mismatch (got \(request.protocolVersion), expected \(MCPBootstrapProtocol.currentVersion))")
            _ = await sendResponseAsync(.rejected(reason: "Protocol version mismatch", errorCode: "protocol_version_mismatch"), to: handshakeSocket)
            return
        }

        // Invoke callback to let ServerNetworkManager decide
        guard let handler = onNewConnection else {
            logger.error("BootstrapSocketServer: no connection handler registered")
            _ = await sendResponseAsync(.rejected(reason: "Server not ready", errorCode: "server_not_ready"), to: handshakeSocket)
            return
        }

        bootstrapSocketServerLog("BootstrapSocketServer: invoking handler for '\(request.clientName ?? "unknown")'...")
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Bootstrap.admissionBegan,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(activeCount: inFlightHandshakeSockets.count)
        )
        let admissionState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Bootstrap.admission,
            EditFlowPerf.Dimensions(activeCount: inFlightHandshakeSockets.count)
        )
        let admission = await handler(clientFD, request.sessionToken, effectivePid, request.clientName)
        EditFlowPerf.end(
            EditFlowPerf.Stage.Bootstrap.admission,
            admissionState,
            EditFlowPerf.Dimensions(
                outcome: admission.accepted ? "accepted" : "rejected",
                activeCount: inFlightHandshakeSockets.count
            )
        )
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Bootstrap.admissionEnded,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(
                outcome: admission.accepted ? "accepted" : "rejected",
                activeCount: inFlightHandshakeSockets.count
            )
        )
        bootstrapSocketServerLog("BootstrapSocketServer: handler returned accepted=\(admission.accepted) for '\(request.clientName ?? "unknown")'")

        guard isActiveHandshake(handshakeSocket, generation: generation) else {
            await abortAcceptedAdmissionIfNeeded(admission)
            return
        }

        if admission.accepted {
            guard let publishTransferredFD = admission.publishTransferredFD,
                  let postAccept = admission.postAccept
            else {
                logger.error("BootstrapSocketServer: accepted admission missing ownership-transfer hooks for fd \(clientFD)")
                await abortAcceptedAdmissionIfNeeded(admission)
                return
            }

            // CRITICAL: Send accepted response BEFORE starting MCP server
            // This ensures CLI receives "accepted" before we start reading MCP messages
            let writeOk = await sendResponseAsync(.accepted(), to: handshakeSocket)
            guard writeOk, isActiveHandshake(handshakeSocket, generation: generation) else {
                logger.error("BootstrapSocketServer: failed or aborted accepted response for fd \(clientFD)")
                await abortAcceptedAdmissionIfNeeded(admission)
                return
            }
            bootstrapSocketServerLog("BootstrapSocketServer: accepted connection from '\(request.clientName ?? "unknown")'")
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.Bootstrap.acceptedResponseSent,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(activeCount: inFlightHandshakeSockets.count)
            )

            // NOW it's safe to transfer ownership and start the MCP server. The CLI
            // has received "accepted". Handshake ownership and full-shutdown-visible
            // manager publication move together under the handshake socket lock.
            guard handshakeSocket.transferOwnershipIfOpen(
                publishTransferredFD: publishTransferredFD
            ) else {
                await abortAcceptedAdmissionIfNeeded(admission)
                return
            }
            inFlightHandshakeSockets.removeValue(forKey: handshakeID)
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.Bootstrap.ownershipTransferred,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(activeCount: inFlightHandshakeSockets.count)
            )
            if inFlightHandshakeSockets.count < maxInFlightHandshakes {
                resumeAcceptSourceIfNeeded()
            }
            await postAccept()
        } else {
            let response = admission.rejection ?? .rejected(reason: "Connection rejected", errorCode: "approval_denied")
            _ = await sendResponseAsync(response, to: handshakeSocket)
            bootstrapSocketServerLog("BootstrapSocketServer: rejected connection from '\(request.clientName ?? "unknown")'")
        }
    }

    // MARK: - Handshake I/O

    /// Reads the handshake request from the client socket.
    /// Format: newline-delimited JSON (same as MCP protocol)
    private func readHandshakeRequestAsync(
        from handshakeSocket: BootstrapHandshakeSocket,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
    ) async -> MCPBootstrapRequest? {
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Bootstrap.handshakeIOQueued,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(activeCount: inFlightHandshakeSockets.count)
        )
        let queueEnvelopeState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Bootstrap.handshakeIOQueueEnvelope,
            EditFlowPerf.Dimensions(activeCount: inFlightHandshakeSockets.count)
        )
        let request = await withCheckedContinuation { continuation in
            handshakeIOQueue.async {
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.Bootstrap.handshakeIOBegan,
                    correlation: lifecycleCorrelation
                )
                let blockingReadState = EditFlowPerf.begin(EditFlowPerf.Stage.Bootstrap.handshakeIOBlockingRead)
                let request = Self.readHandshakeRequestBlocking(from: handshakeSocket)
                EditFlowPerf.end(
                    EditFlowPerf.Stage.Bootstrap.handshakeIOBlockingRead,
                    blockingReadState,
                    EditFlowPerf.Dimensions(outcome: request == nil ? "failed" : "completed")
                )
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.Bootstrap.handshakeIOEnded,
                    correlation: lifecycleCorrelation,
                    EditFlowPerf.Dimensions(outcome: request == nil ? "failed" : "completed")
                )
                continuation.resume(returning: request)
            }
        }
        EditFlowPerf.end(
            EditFlowPerf.Stage.Bootstrap.handshakeIOQueueEnvelope,
            queueEnvelopeState,
            EditFlowPerf.Dimensions(outcome: request == nil ? "failed" : "completed")
        )
        return request
    }

    private nonisolated static func readHandshakeRequestBlocking(from handshakeSocket: BootstrapHandshakeSocket) -> MCPBootstrapRequest? {
        var buffer = Data()
        var byte: UInt8 = 0

        // Read exactly through the bootstrap newline. Do not bulk-read here: any
        // bytes after the newline belong to the MCP transport on the same socket.
        let deadline = Date().addingTimeInterval(MCPBootstrapTiming.initialResponseTimeout)

        while Date() < deadline {
            let remaining = Int32(deadline.timeIntervalSinceNow * 1000)
            guard let pollResult = handshakeSocket.withServerOwnedIOLease({ leasedFD in
                var pfd = pollfd(fd: leasedFD, events: Int16(POLLIN), revents: 0)
                return poll(&pfd, 1, max(0, remaining))
            }) else {
                return nil
            }

            if pollResult <= 0 {
                if pollResult < 0, errno != EINTR {
                    return nil
                }
                continue
            }

            guard let bytesRead = handshakeSocket.withServerOwnedIOLease({ leasedFD in
                Darwin.read(leasedFD, &byte, 1)
            }) else {
                return nil
            }
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
    private func sendResponseAsync(_ response: MCPBootstrapResponse, to handshakeSocket: BootstrapHandshakeSocket) async -> Bool {
        let fd = handshakeSocket.fd
        guard handshakeSocket.isServerOwnedOpen() else { return false }
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
            if Task.isCancelled || !handshakeSocket.isServerOwnedOpen() {
                POSIXDescriptorSupport.shutdownSocketReadWrite(fd)
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
            POSIXDescriptorSupport.shutdownSocketReadWrite(fd)
            return false
        }

        return true
    }
}

// MARK: - Errors

enum BootstrapSocketError: Error {
    case startCancelled
    case socketCreationFailed(errno: Int32)
    case descriptorConfigurationFailed(role: String, error: POSIXDescriptorConfigurationError)
    case pathTooLong
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case readSourceCreationFailed(reason: String)
}
