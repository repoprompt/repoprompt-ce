#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Logging
import MCP
import RepoPromptDomainRuntime
import RepoPromptHeadlessRuntime
import RepoPromptMCPAdapter
import RepoPromptServiceProtocol

private final class HeadlessMCPClientConnection: @unchecked Sendable {
    let descriptor: Int32

    private let lock = NSLock()
    private var closed = false
    private var shutdownRequested = false
    private var completed = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func shutdown() {
        lock.lock()
        guard !closed, !shutdownRequested else {
            lock.unlock()
            return
        }
        shutdownRequested = true
        PortablePOSIX.shutdownReadWrite(descriptor)
        lock.unlock()
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        PortablePOSIX.closeDescriptor(descriptor)
        lock.unlock()
    }

    func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }
}

/// In-process analogue of Desktop `BootstrapSocketServer`: Codex spawns
/// `RepoPromptServer mcp-stdio`, which connects here so `agent_run` hits the
/// the same host-issued authority capabilities as the parent Codex run.
public actor HeadlessMCPSocketServer {
    public struct ShutdownReport: Sendable, Equatable {
        public let clientCount: Int
        public let forceClosedClientCount: Int
        public let unreapedClientCount: Int

        public var clean: Bool { forceClosedClientCount == 0 && unreapedClientCount == 0 }
    }

    private struct ClientTask {
        let connection: HeadlessMCPClientConnection
        let task: Task<Void, Never>
    }

    public struct Handshake: Codable, Sendable {
        public let sessionID: UUID
        public let runID: UUID?

        public init(sessionID: UUID, runID: UUID? = nil) {
            self.sessionID = sessionID
            self.runID = runID
        }
    }

    public enum ServerError: Error, Equatable {
        case pathTooLong
        case socket(errno: Int32)
        case bind(errno: Int32)
        case listen(errno: Int32)
        case handshakeTimeout
        case invalidHandshake
    }

    public let socketURL: URL
    private let adapter: RepoPromptMCPAdapter
    private let logger: Logger
    private let clientHandlerOverride: (@Sendable (Int32) async -> Void)?
    private var listenFD: Int32 = -1
    private var listenerGeneration: UInt64 = 0
    private var acceptingClients = false
    private var acceptTask: Task<Void, Never>?
    private var clientTasks: [UUID: ClientTask] = [:]
    private var lastShutdownReport: ShutdownReport?

    public init(
        socketURL: URL,
        adapter: RepoPromptMCPAdapter,
        clientHandlerOverride: (@Sendable (Int32) async -> Void)? = nil,
        logger: Logger = Logger(label: "com.repoprompt.ce.mcp.headless-socket")
    ) {
        self.socketURL = socketURL
        self.adapter = adapter
        self.clientHandlerOverride = clientHandlerOverride
        self.logger = logger
    }

    public func start() throws {
        guard listenFD < 0 else { return }
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        PortablePOSIX.unlinkPath(socketURL.path)
        let fd = PortablePOSIX.unixStreamSocket()
        guard fd >= 0 else { throw ServerError.socket(errno: errno) }
        PortablePOSIX.enableNoSIGPIPE(on: fd)
        var address = sockaddr_un()
        guard PortablePOSIX.fillUnixAddress(&address, path: socketURL.path) else {
            PortablePOSIX.closeDescriptor(fd)
            throw ServerError.pathTooLong
        }
        let bindResult = PortablePOSIX.bindUnix(fd, &address)
        guard bindResult == 0 else {
            let code = errno
            PortablePOSIX.closeDescriptor(fd)
            throw ServerError.bind(errno: code)
        }
        guard PortablePOSIX.chmodPath(socketURL.path, mode: 0o600) == 0 else {
            let code = errno
            PortablePOSIX.closeDescriptor(fd)
            PortablePOSIX.unlinkPath(socketURL.path)
            throw ServerError.bind(errno: code)
        }
        guard PortablePOSIX.listen(fd, backlog: 16) == 0 else {
            let code = errno
            PortablePOSIX.closeDescriptor(fd)
            PortablePOSIX.unlinkPath(socketURL.path)
            throw ServerError.listen(errno: code)
        }
        listenerGeneration &+= 1
        let generation = listenerGeneration
        acceptingClients = true
        lastShutdownReport = nil
        listenFD = fd
        acceptTask = Task.detached { [weak self] in
            guard let self else { return }
            await Self.acceptLoop(server: self, fd: fd, generation: generation)
        }
    }

    @discardableResult
    public func stop(
        clientDrainTimeout: Duration = .seconds(5),
        forceCloseReapTimeout: Duration = .seconds(1)
    ) async -> ShutdownReport {
        if listenFD < 0, !acceptingClients, acceptTask == nil, let lastShutdownReport {
            return lastShutdownReport
        }
        acceptingClients = false
        listenerGeneration &+= 1
        let listener = listenFD
        listenFD = -1
        if listener >= 0 {
            PortablePOSIX.shutdownReadWrite(listener)
            PortablePOSIX.closeDescriptor(listener)
        }
        PortablePOSIX.unlinkPath(socketURL.path)
        let accept = acceptTask
        acceptTask = nil
        accept?.cancel()
        await accept?.value

        let clients = clientTasks
        clientTasks.removeAll()
        for client in clients.values {
            client.connection.shutdown()
            client.task.cancel()
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: max(.zero, clientDrainTimeout))
        while clients.values.contains(where: { !$0.connection.isCompleted }), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let remaining = clients.values.filter { !$0.connection.isCompleted }
        for client in remaining {
            client.connection.close()
            client.task.cancel()
        }
        let requestedReapDeadline = clock.now.advanced(by: max(.zero, forceCloseReapTimeout))
        let reapDeadline = min(deadline, requestedReapDeadline)
        while remaining.contains(where: { !$0.connection.isCompleted }), clock.now < reapDeadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let unreaped = remaining.filter { !$0.connection.isCompleted }
        let report = ShutdownReport(
            clientCount: clients.count,
            forceClosedClientCount: remaining.count,
            unreapedClientCount: unreaped.count
        )
        lastShutdownReport = report
        return report
    }

    func activeClientCount() -> Int { clientTasks.count }

    private static func acceptLoop(
        server: HeadlessMCPSocketServer,
        fd: Int32,
        generation: UInt64
    ) async {
        while !Task.isCancelled {
            let client = PortablePOSIX.accept(fd)
            if client < 0 {
                if errno == EINTR { continue }
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            PortablePOSIX.enableNoSIGPIPE(on: client)
            await server.acceptClient(descriptor: client, generation: generation)
        }
    }

    private func acceptClient(descriptor: Int32, generation: UInt64) {
        guard acceptingClients, generation == listenerGeneration else {
            PortablePOSIX.closeDescriptor(descriptor)
            return
        }
        let connectionID = UUID()
        let connection = HeadlessMCPClientConnection(descriptor: descriptor)
        let clientHandlerOverride = clientHandlerOverride
        let task = Task.detached { [weak self] in
            guard let self else {
                connection.close()
                connection.markCompleted()
                return
            }
            do {
                if let clientHandlerOverride {
                    await clientHandlerOverride(descriptor)
                    await self.completeOverride(
                        connectionID: connectionID,
                        connection: connection
                    )
                    return
                }
                let handshake = try Self.readHandshake(from: descriptor)
                await self.serve(
                    connectionID: connectionID,
                    connection: connection,
                    handshake: handshake
                )
            } catch {
                await self.reject(
                    connectionID: connectionID,
                    connection: connection,
                    diagnostic: String(describing: error)
                )
            }
        }
        clientTasks[connectionID] = ClientTask(connection: connection, task: task)
    }

    private func completeOverride(
        connectionID: UUID,
        connection: HeadlessMCPClientConnection
    ) {
        connection.close()
        connection.markCompleted()
        clientTasks[connectionID] = nil
    }

    private func reject(
        connectionID: UUID,
        connection: HeadlessMCPClientConnection,
        diagnostic: String
    ) {
        logger.warning("Rejected MCP handshake", metadata: ["error": "\(diagnostic)"])
        connection.close()
        connection.markCompleted()
        clientTasks[connectionID] = nil
    }

    private func serve(
        connectionID: UUID,
        connection: HeadlessMCPClientConnection,
        handshake: Handshake
    ) async {
        let clientFD = connection.descriptor
        defer {
            connection.close()
            connection.markCompleted()
            clientTasks[connectionID] = nil
        }
        let snapshot: SessionSnapshot
        do {
            snapshot = try await adapter.sessionSnapshot(id: handshake.sessionID)
        } catch {
            logger.warning("MCP session not found", metadata: ["session": "\(handshake.sessionID)"])
            return
        }
        let binding = RepoPromptMCPBinding(
            sessionID: snapshot.sessionID,
            actor: snapshot.creator,
            mcpClientID: RepoPromptMCPBinding.untrustedClientID
        )
        let isRootSession = snapshot.parentSessionID == nil
        let classification = MCPClientToolPolicyCatalog.classification(for: .agentModeCodexEngineer)
        let server = Server(
            name: "RepoPrompt CE",
            version: "1",
            title: "RepoPrompt CE",
            instructions: "Canonical RepoPrompt MCP tools bound to the calling Agent Mode session.",
            capabilities: .init(tools: .init(listChanged: false)),
            configuration: .init(strict: true, responseSendTimeout: .seconds(5))
        )
        let adapter = adapter
        await server.withMethodHandler(ListTools.self) { _ in
            let visibleNames = try await adapter.advertisedToolNames(isRootSession: isRootSession)
            let tools = MCPDomainCanonicalToolDefinitions.definitions.compactMap { definition -> MCP.Tool? in
                guard visibleNames.contains(definition.name) else { return nil }
                let projected = definition.annotations.projected(for: classification.annotationProfile)
                return MCP.Tool(
                    name: definition.name,
                    description: definition.description,
                    inputSchema: definition.inputSchema,
                    annotations: .init(
                        title: projected.title,
                        readOnlyHint: projected.readOnlyHint,
                        destructiveHint: projected.destructiveHint,
                        idempotentHint: projected.idempotentHint,
                        openWorldHint: projected.openWorldHint
                    )
                )
            }
            return ListTools.Result(tools: tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                let visibleNames = try await adapter.advertisedToolNames(isRootSession: isRootSession)
                guard visibleNames.contains(params.name) else {
                    return Self.errorResult("Tool is unavailable for this client policy: \(params.name)")
                }
                let arguments = params.arguments ?? [:]
                let data = try await adapter.invoke(
                    toolName: params.name,
                    argumentsJSON: JSONEncoder().encode(arguments),
                    binding: binding
                )
                let value = try JSONDecoder().decode(Value.self, from: data)
                return Self.successResult(value)
            } catch {
                return Self.errorResult(String(describing: error))
            }
        }
        let transport = PortableMCPByteTransport(
            stdinFD: clientFD,
            stdoutFD: clientFD,
            logger: logger
        )
        do {
            try await server.start(transport: transport)
            _ = await transport.waitUntilTerminal()
            await server.stop()
            await server.waitUntilCompleted()
        } catch {
            logger.warning("MCP connection failed", metadata: ["error": "\(error)"])
            await server.stop()
        }
    }

    private nonisolated static func readHandshake(from fd: Int32) throws -> Handshake {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while ContinuousClock().now < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let polled = PortablePOSIX.poll(&descriptor, timeout: 100)
            if polled == 0 { continue }
            if polled < 0 {
                if errno == EINTR { continue }
                throw ServerError.invalidHandshake
            }
            let count = PortablePOSIX.read(fd, &buffer, buffer.count)
            if count == 0 { throw ServerError.invalidHandshake }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw ServerError.invalidHandshake
            }
            pending.append(buffer, count: count)
            if let newline = pending.firstIndex(of: 0x0A) {
                let payload = pending.prefix(upTo: newline)
                guard let handshake = try? JSONDecoder().decode(Handshake.self, from: Data(payload)) else {
                    throw ServerError.invalidHandshake
                }
                return handshake
            }
            if pending.count > 4096 { throw ServerError.invalidHandshake }
        }
        throw ServerError.handshakeTimeout
    }

    private static func successResult(_ value: Value) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
            ?? String(describing: value)
        return CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            isError: false
        )
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }
}
