#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RepoPromptServerHost

/// Desktop `BootstrapSocketProxy`: Codex stdio MCP child connects to the
/// app-owned unix socket. Linux uses `RepoPromptServer mcp-stdio` for the
/// same hop onto `HeadlessMCPSocketServer`.
public enum HeadlessMCPStdioBridge {
    public enum BridgeError: Error {
        case missingSessionID
        case untrustedEndpoint
        case socket(errno: Int32)
        case pathTooLong
        case connect(errno: Int32)
        case read(errno: Int32)
        case write(errno: Int32)
        case writeTimeout
    }

    private enum PumpDirection {
        case upstream
        case downstream
    }

    public static func run(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        guard let rawSession = environment["REPOPROMPT_MCP_SESSION_ID"],
              let sessionID = UUID(uuidString: rawSession)
        else {
            throw BridgeError.missingSessionID
        }
        let socketPath = CodexRepoPromptMCPConfig.socketPath(environment: environment)
        try validateEndpoint(path: socketPath)
        let fd = try connect(path: socketPath)
        defer { PortablePOSIX.closeDescriptor(fd) }
        var handshake = try JSONEncoder().encode(
            HeadlessMCPSocketServer.Handshake(
                sessionID: sessionID,
                runID: environment["REPOPROMPT_MCP_RUN_ID"].flatMap(UUID.init(uuidString:))
            )
        )
        handshake.append(0x0A)
        try writeAll(handshake, to: fd)

        try await withThrowingTaskGroup(of: PumpDirection.self) { group in
            group.addTask {
                try pump(from: STDIN_FILENO, to: fd)
                return .upstream
            }
            group.addTask {
                try pump(from: fd, to: STDOUT_FILENO)
                return .downstream
            }
            while let completed = try await group.next() {
                switch completed {
                case .upstream:
                    PortablePOSIX.shutdownWrite(fd)
                case .downstream:
                    PortablePOSIX.shutdownReadWrite(fd)
                    group.cancelAll()
                    return
                }
            }
        }
    }

    private static func validateEndpoint(path: String) throws {
        var socketInfo = stat()
        guard lstat(path, &socketInfo) == 0,
              socketInfo.st_uid == geteuid(),
              (socketInfo.st_mode & S_IFMT) == S_IFSOCK,
              (socketInfo.st_mode & 0o077) == 0
        else {
            throw BridgeError.untrustedEndpoint
        }
        var parentInfo = stat()
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard lstat(parent, &parentInfo) == 0,
              parentInfo.st_uid == geteuid(),
              (parentInfo.st_mode & S_IFMT) == S_IFDIR,
              (parentInfo.st_mode & 0o077) == 0
        else {
            throw BridgeError.untrustedEndpoint
        }
    }

    private static func connect(path: String) throws -> Int32 {
        let fd = PortablePOSIX.unixStreamSocket()
        guard fd >= 0 else { throw BridgeError.socket(errno: errno) }
        PortablePOSIX.enableNoSIGPIPE(on: fd)
        var address = sockaddr_un()
        guard PortablePOSIX.fillUnixAddress(&address, path: path) else {
            PortablePOSIX.closeDescriptor(fd)
            throw BridgeError.pathTooLong
        }
        let result = PortablePOSIX.connectUnix(fd, &address)
        guard result == 0 else {
            let code = errno
            PortablePOSIX.closeDescriptor(fd)
            throw BridgeError.connect(errno: code)
        }
        return fd
    }

    private static func pump(from source: Int32, to destination: Int32) throws {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while !Task.isCancelled {
            var descriptor = pollfd(fd: source, events: Int16(POLLIN | POLLERR | POLLHUP), revents: 0)
            let polled = PortablePOSIX.poll(&descriptor, timeout: 100)
            if polled == 0 { continue }
            if polled < 0 {
                if errno == EINTR { continue }
                throw BridgeError.read(errno: errno)
            }
            let count = PortablePOSIX.read(source, &buffer, buffer.count)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw BridgeError.read(errno: errno)
            }
            try buffer.withUnsafeBytes { raw in
                try writeAll(Data(raw.prefix(count)), to: destination)
            }
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return PortablePOSIX.write(fd, base.advanced(by: written), data.count - written)
            }
            if count > 0 {
                written += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno != EAGAIN, errno != EWOULDBLOCK {
                throw BridgeError.write(errno: errno)
            }
            guard ContinuousClock().now < deadline else { throw BridgeError.writeTimeout }
            usleep(10_000)
        }
    }
}
