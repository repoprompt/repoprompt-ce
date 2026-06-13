//
//  BootstrapSocketConnectionManager.swift
//  RepoPrompt
//
//  Manages a single MCP connection received via the bootstrap socket.
//  Uses an already-connected file descriptor passed from BootstrapSocketServer.
//

import Foundation
import Logging
import MCP
import RepoPromptShared

// MARK: - Bundle helpers

private extension Bundle {
    var appName: String {
        object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Unknown"
    }

    var appVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
    }
}

// MARK: - Logger

private let bootstrapLog: Logger = {
    var logger = Logger(label: "com.repoprompt.mcp.bootstrap.connection")
    #if DEBUG
        logger.logLevel = .debug
    #else
        logger.logLevel = .notice
    #endif
    return logger
}()

// MARK: - Connection Manager

/// Connection manager for bootstrap socket connections.
/// Unlike FileSystemMCPConnectionManager, this doesn't use filesystem folders or meta.json.
actor BootstrapSocketConnectionManager: MCPServerConnection {
    private let connectionID: UUID
    private let sessionToken: String
    private let clientPid: Int
    private let _clientName: String?
    private let purpose: MCPRunPurpose
    private let server: MCP.Server
    private let transport: UnixSocketMCPTransport
    private let parentManager: ServerNetworkManager

    /// Not a filesystem-backed connection
    nonisolated var isFilesystemBacked: Bool {
        false
    }

    /// No connection folder
    nonisolated var connectionFolderURL: URL? {
        nil
    }

    /// Capability token is the session token
    nonisolated var capabilityToken: String? {
        sessionToken
    }

    /// Verified peer PID for this connection (from the bootstrap socket).
    func peerPID() -> Int {
        clientPid
    }

    private var healthMonitoringTask: Task<Void, Never>?
    private var closeWatchTask: Task<Void, Never>?
    private var state: ConnectionStateSnapshot = .connecting
    private var isClosing = false
    private var handshakeComplete = false

    init(
        connectionID: UUID,
        sessionToken: String,
        clientPid: Int,
        clientName: String?,
        purpose: MCPRunPurpose,
        codeMapsDisabled: Bool,
        connectedFD: Int32,
        parentManager: ServerNetworkManager,
        receiveBufferCapacity: Int = 1024
    ) throws {
        self.connectionID = connectionID
        self.sessionToken = sessionToken
        self.clientPid = clientPid
        _clientName = clientName
        self.purpose = purpose
        self.parentManager = parentManager

        // Create transport with existing connected FD
        transport = try UnixSocketMCPTransport(
            connectedFD: connectedFD,
            connectionID: connectionID,
            correlationConnectionID: sessionToken,
            logger: bootstrapLog,
            receiveBufferCapacity: receiveBufferCapacity
        )

        server = MCP.Server(
            name: Bundle.main.appName,
            version: Bundle.main.appVersion,
            instructions: RepoPromptMCPInstructions.text(for: purpose, codeMapsDisabled: codeMapsDisabled),
            capabilities: MCP.Server.Capabilities(
                prompts: .init(listChanged: false),
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: true)
            ),
            configuration: MCP.Server.Configuration(
                responseSendTimeout: MCPTimeoutPolicy.responseSendDeadline
            )
        )
    }

    func start(approvalHandler: @escaping (MCP.Client.Info) async -> Bool) async throws {
        // Start close-watch task to clean up when socket closes
        closeWatchTask = Task { [weak self] in
            guard let self else { return }
            for await _ in await transport.closed() {
                let id = connectionID
                let ingressSnapshot = await transport.ingressSnapshot()
                mcpConnectionLog("BootstrapSocketConnectionManager: transport closed for \(id)")
                await parentManager.recordTransportIngressTerminal(
                    connectionID: id,
                    clientName: _clientName,
                    sessionToken: sessionToken,
                    snapshot: ingressSnapshot
                )
                await parentManager.removeConnection(id)
                break
            }
        }

        do {
            // Register handlers BEFORE starting the server to prevent race condition.
            // The server spawns a message loop Task, and without pre-registration,
            // a fast client could call tools/list before handlers are ready.
            mcpConnectionLog("BootstrapSocketConnectionManager: registering handlers...")
            await registerHandlers()

            mcpConnectionLog("BootstrapSocketConnectionManager: starting MCP server...")
            try await server.start(transport: transport) { [weak self] clientInfo, _ in
                mcpConnectionLog("BootstrapSocketConnectionManager: received client info: \(clientInfo.name)")
                guard let self else { throw MCPError.connectionClosed }

                let approved = await approvalHandler(clientInfo)
                if !approved {
                    throw MCPError.connectionClosed
                }
                await markHandshakeComplete()
            }

            mcpConnectionLog("BootstrapSocketConnectionManager: MCP server started successfully")
            await startHealthMonitoring()
            updateState(.ready)
        } catch {
            bootstrapLog.error("BootstrapSocketConnectionManager: start failed: \(error)")
            updateState(.failed(error))
            await transport.disconnect()
            throw error
        }
    }

    private func registerHandlers() async {
        await parentManager.registerHandlers(for: server, connectionID: connectionID)
    }

    private func startHealthMonitoring() async {
        healthMonitoringTask?.cancel()
        healthMonitoringTask = Task { [self] in
            let hardIdleSec = UserDefaults.standard.integer(forKey: "mcp.idleConnectionSeconds")
            let keepaliveSec = UserDefaults.standard.integer(forKey: "mcp.keepaliveSeconds")
            var lastKeepaliveAt: Date? = nil
            while !Task.isCancelled {
                guard await parentManager.isRunning() else { break }
                let idle = await transport.secondsSinceLastActivity()
                if hardIdleSec > 0,
                   let idle,
                   idle > TimeInterval(hardIdleSec)
                {
                    let hasInFlight = await parentManager.hasInFlightCalls(for: connectionID)
                    if !hasInFlight {
                        mcpConnectionLog("Bootstrap connection \(connectionID) idle \(Int(idle))s (> \(hardIdleSec)s). Terminating.")
                        await parentManager.terminateConnection(connectionID, reason: .idleTimeout, message: "Connection idle for \(Int(idle))s")
                        break
                    }
                }
                if keepaliveSec > 0,
                   let idle,
                   idle > TimeInterval(keepaliveSec)
                {
                    let now = Date()
                    let shouldSend = lastKeepaliveAt.map { now.timeIntervalSince($0) >= TimeInterval(keepaliveSec) } ?? true
                    if shouldSend {
                        await sendProgress(tool: "mcp", kind: .heartbeat, stage: "keepalive", message: "keepalive")
                        lastKeepaliveAt = now
                    }
                }
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    break
                }
            }
        }
    }

    func notifyToolListChanged() async {
        if !handshakeComplete {
            mcpConnectionLog("Skipping tool list notification - handshake not complete")
            return
        }
        do {
            try await server.notify(ToolListChangedNotification.message())
        } catch {
            if isClosing { return }
            bootstrapLog.error("Failed to notify bootstrap client of tool list change: \(error)")
            await parentManager.removeConnection(connectionID)
        }
    }

    private func markHandshakeComplete() {
        handshakeComplete = true
    }

    func stop() async {
        guard !isClosing else { return }
        isClosing = true
        healthMonitoringTask?.cancel()
        healthMonitoringTask = nil
        closeWatchTask?.cancel()
        closeWatchTask = nil
        await server.stop()
        await transport.disconnect()
        updateState(.cancelled)
    }

    func terminate(reason: TerminationReason, message: String?) async {
        guard !isClosing else { return }
        mcpConnectionLog("Terminating bootstrap connection \(connectionID) with reason: \(reason.rawValue)")
        isClosing = true
        healthMonitoringTask?.cancel()
        healthMonitoringTask = nil
        closeWatchTask?.cancel()
        closeWatchTask = nil
        await server.stop()
        await transport.disconnect()
        updateState(.cancelled)
    }

    func abortForExecutionWatchdog() async {
        if !isClosing {
            mcpConnectionLog("Force-disconnecting bootstrap connection \(connectionID) after unresponsive tool cancellation")
            isClosing = true
            healthMonitoringTask?.cancel()
            healthMonitoringTask = nil
            closeWatchTask?.cancel()
            closeWatchTask = nil
        }

        // Delivery must stop immediately even if ordinary shutdown has already
        // started and is blocked on the uncooperative handler.
        await transport.disconnect()
        updateState(.cancelled)
        Task { await server.stop() }
    }

    func connectionState() -> ConnectionStateSnapshot {
        state
    }

    func isViableForRetention() -> Bool {
        !isClosing && (state == .ready || state == .connecting)
    }

    func secondsSinceLastActivity() async -> TimeInterval {
        await transport.secondsSinceLastActivity() ?? 0
    }

    func transportIngressSnapshot() async -> MCPTransportIngressSnapshot? {
        await transport.ingressSnapshot()
    }

    private func updateState(_ newState: ConnectionStateSnapshot) {
        state = newState
    }

    /// Sends a progress notification to the CLI.
    /// Used during long-running operations to prevent agent timeouts.
    func sendProgress(tool: String, kind: RepoPromptProgressKind, stage: String, message: String) async {
        guard !isClosing, handshakeComplete else { return }

        let notification: RepoPromptControlNotification<RepoPromptProgressParams> = switch kind {
        case .stage:
            .stage(tool: tool, stage: stage, message: message)
        case .heartbeat:
            .heartbeat(tool: tool, stage: stage, message: message)
        }

        guard let data = notification.encodedJSONLine() else {
            bootstrapLog.warning("Failed to encode progress notification")
            return
        }

        do {
            try await transport.send(data)
        } catch {
            // Non-fatal - just log and continue
            bootstrapLog.debug("Failed to send progress notification: \(error)")
        }
    }
}
