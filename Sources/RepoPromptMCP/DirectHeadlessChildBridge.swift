import Darwin
import Foundation
import RepoPromptDomainRuntime

enum DirectHeadlessChildBridge {
    private enum PumpDirection {
        case upstream
        case downstream
    }

    enum BridgeError: Error {
        case incompleteCarrier
        case untrustedEndpoint
        case socket(errno: Int32)
        case pathTooLong
        case connect(errno: Int32)
        case read(errno: Int32)
        case write(errno: Int32)
        case writeTimeout
    }

    static func isRequested(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[DomainChildLaunchCarrier.endpointEnvironmentKey] != nil
            || environment[DomainChildLaunchCarrier.launchTokenEnvironmentKey] != nil
    }

    static func run(environment: [String: String] = ProcessInfo.processInfo.environment) async throws {
        guard let endpoint = environment[DomainChildLaunchCarrier.endpointEnvironmentKey],
              let launchToken = environment[DomainChildLaunchCarrier.launchTokenEnvironmentKey],
              let principal = environment[DomainChildLaunchCarrier.clientPrincipalEnvironmentKey],
              let provider = environment[DomainChildLaunchCarrier.providerIdentifierEnvironmentKey],
              let rawRunID = environment[DomainChildLaunchCarrier.runIDEnvironmentKey],
              let runID = UUID(uuidString: rawRunID)
        else {
            throw BridgeError.incompleteCarrier
        }
        try validatePrivateEndpoint(path: endpoint)
        let fd = try connect(path: endpoint)
        defer { Darwin.close(fd) }
        let handshake = DirectHeadlessChildEndpoint.Handshake(
            launchToken: launchToken,
            clientPrincipal: principal,
            providerIdentifier: provider,
            runID: runID
        )
        var bytes = try JSONEncoder().encode(handshake)
        bytes.append(0x0A)
        try writeAll(bytes, to: fd)

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
                    // EOF from the nested client's stdin only closes the request half. Keep the
                    // response pump alive until the private endpoint reaches its terminal boundary.
                    Darwin.shutdown(fd, SHUT_WR)
                case .downstream:
                    Darwin.shutdown(fd, SHUT_RDWR)
                    group.cancelAll()
                    return
                }
            }
        }
    }

    private static func validatePrivateEndpoint(path: String) throws {
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
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError.socket(errno: errno) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw BridgeError.pathTooLong
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
                for (index, byte) in bytes.enumerated() {
                    destination[index] = byte
                }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw BridgeError.connect(errno: code)
        }
        return fd
    }

    private static func pump(from source: Int32, to destination: Int32) throws {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while !Task.isCancelled {
            var descriptor = pollfd(fd: source, events: Int16(POLLIN | POLLERR | POLLHUP), revents: 0)
            let polled = Darwin.poll(&descriptor, 1, 100)
            if polled == 0 { continue }
            if polled < 0 {
                if errno == EINTR { continue }
                throw BridgeError.read(errno: errno)
            }
            let count = Darwin.read(source, &buffer, buffer.count)
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
                return Darwin.write(fd, base.advanced(by: written), data.count - written)
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
            usleep(10000)
        }
    }
}
