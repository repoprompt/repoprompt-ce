import Darwin
import Foundation
import Logging
import MCP
import RepoPromptDomainRuntime

actor DirectHeadlessChildEndpoint {
    struct Handshake: Codable {
        let launchToken: String
        let clientPrincipal: String
        let providerIdentifier: String
        let runID: UUID
    }

    enum EndpointError: Error, Equatable {
        case pathTooLong
        case socket(errno: Int32)
        case bind(errno: Int32)
        case listen(errno: Int32)
        case handshakeTimeout
        case handshakeTooLarge
        case handshakeRead(errno: Int32)
        case invalidHandshake
    }

    typealias ClientHandler = @Sendable (
        _ fd: Int32,
        _ observedPeerPID: Int32?,
        _ handshake: Handshake
    ) async -> Void

    private struct ClientTask {
        let fd: Int32
        let task: Task<Void, Never>
    }

    private struct SocketIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    nonisolated let socketURL: URL
    private let directoryURL: URL
    private let logger: Logger
    private var listenFD: Int32 = -1
    private var socketIdentity: SocketIdentity?
    private var directoryIdentity: SocketIdentity?
    private var acceptTask: Task<Void, Never>?
    private var clientTasks: [UUID: ClientTask] = [:]

    init(directory: URL, logger: Logger) {
        directoryURL = directory
        socketURL = directory.appendingPathComponent("c-\(UUID().uuidString.prefix(12)).sock", isDirectory: false)
        self.logger = logger
    }

    func start(handler: @escaping ClientHandler) throws {
        guard listenFD < 0 else { return }
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        directoryIdentity = Self.identity(at: directory.path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EndpointError.socket(errno: errno) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = socketURL.path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw EndpointError.pathTooLong
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
                for (index, byte) in bytes.enumerated() {
                    destination[index] = byte
                }
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(fd)
            throw EndpointError.bind(errno: code)
        }
        guard chmod(socketURL.path, 0o600) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(socketURL.path)
            throw EndpointError.bind(errno: code)
        }
        guard Darwin.listen(fd, 8) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(socketURL.path)
            throw EndpointError.listen(errno: code)
        }
        listenFD = fd
        socketIdentity = Self.identity(at: socketURL.path)
        acceptTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await Self.acceptLoop(endpoint: self, fd: fd, handler: handler)
        }
    }

    func stop() async {
        let listener = listenFD
        listenFD = -1
        if listener >= 0 {
            Darwin.shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
        }
        acceptTask?.cancel()
        let accept = acceptTask
        acceptTask = nil
        let clients = Array(clientTasks.values)
        clientTasks.removeAll()
        for client in clients {
            Darwin.shutdown(client.fd, SHUT_RDWR)
            client.task.cancel()
        }
        await accept?.value
        for client in clients {
            await client.task.value
        }
        if socketIdentity == Self.identity(at: socketURL.path) {
            unlink(socketURL.path)
        }
        socketIdentity = nil
        if directoryIdentity == Self.identity(at: directoryURL.path),
           (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path).isEmpty) == true
        {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        directoryIdentity = nil
    }

    private nonisolated static func acceptLoop(
        endpoint: DirectHeadlessChildEndpoint,
        fd: Int32,
        handler: @escaping ClientHandler
    ) async {
        while !Task.isCancelled {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLERR | POLLHUP), revents: 0)
            let polled = Darwin.poll(&descriptor, 1, 100)
            if polled == 0 { continue }
            if polled < 0 {
                if errno == EINTR { continue }
                return
            }
            var address = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(fd, $0, &length)
                }
            }
            if clientFD < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return
            }
            var noSigPipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            await endpoint.acceptClient(fd: clientFD, handler: handler)
        }
    }

    private func acceptClient(fd: Int32, handler: @escaping ClientHandler) {
        let id = UUID()
        let logger = logger
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            defer { Darwin.close(fd) }
            do {
                let handshake = try Self.readHandshake(fd: fd)
                let peerPID = Self.peerPID(fd: fd)
                await handler(fd, peerPID, handshake)
            } catch {
                logger.warning("Rejected private child endpoint connection", metadata: ["error": "\(error)"])
            }
            await self?.clientFinished(id)
        }
        clientTasks[id] = ClientTask(fd: fd, task: task)
    }

    private func clientFinished(_ id: UUID) {
        clientTasks.removeValue(forKey: id)
    }

    private nonisolated static func readHandshake(fd: Int32) throws -> Handshake {
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while ContinuousClock().now < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLERR | POLLHUP), revents: 0)
            let polled = Darwin.poll(&descriptor, 1, 100)
            if polled == 0 { continue }
            if polled < 0 {
                if errno == EINTR { continue }
                throw EndpointError.handshakeRead(errno: errno)
            }
            let count = Darwin.read(fd, &byte, 1)
            if count == 0 { throw EndpointError.invalidHandshake }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw EndpointError.handshakeRead(errno: errno)
            }
            if byte == 0x0A {
                guard let handshake = try? JSONDecoder().decode(Handshake.self, from: Data(bytes)) else {
                    throw EndpointError.invalidHandshake
                }
                return handshake
            }
            bytes.append(byte)
            if bytes.count > 16 * 1024 { throw EndpointError.handshakeTooLarge }
        }
        throw EndpointError.handshakeTimeout
    }

    private nonisolated static func peerPID(fd: Int32) -> Int32? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        return pid
    }

    private nonisolated static func identity(at path: String) -> SocketIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return SocketIdentity(device: info.st_dev, inode: info.st_ino)
    }
}

actor DirectHeadlessChildLaunchCoordinator {
    enum CoordinatorError: Error {
        case unavailable
        case missingRoutingContext
    }

    private var runtime: MCPDomainRuntime?
    private var harness: DomainPrivateChildLaunchHarness?

    func configure(runtime: MCPDomainRuntime, endpointDescriptor: String) {
        self.runtime = runtime
        harness = DomainPrivateChildLaunchHarness(
            endpointDescriptor: endpointDescriptor,
            credentialStore: runtime.credentialEnvelopeStore,
            issueLaunchToken: { request in
                try await runtime.routingCoordinator.issueLaunchToken(request)
            }
        )
    }

    func prepare(
        toolName: String,
        arguments: [String: MCP.Value],
        securityContext: DomainToolInvocationSecurityContext
    ) async throws -> DomainChildLaunchCarrier? {
        guard let runtime, let harness else { throw CoordinatorError.unavailable }
        let registration = try await runtime.routingCoordinator.currentRegistration(
            connectionID: securityContext.connectionID
        )
        let handle = try await runtime.routingCoordinator.resolveReadContext(connection: registration)
        let provider = arguments["provider"]?.stringValue
            ?? arguments["model_id"]?.stringValue
            ?? "headless"
        let runID = arguments["run_id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? UUID()
        let request = DomainRunLaunchReservationRequest(
            runID: runID,
            context: handle.context,
            expectedContextRevision: handle.contextRevision,
            windowID: nil,
            clientPrincipal: securityContext.principal.stableKey ?? securityContext.principal.displayName,
            providerIdentifier: provider,
            runPurpose: toolName,
            additionalTools: Set(arguments["additional_tools"]?.arrayValue?.compactMap(\.stringValue) ?? []),
            expectedProcessID: nil,
            lifetime: .seconds(60)
        )
        return try await harness.prepare(request: request)
    }
}
