import Darwin
import Foundation
import RepoPromptShared

enum MCPBackend: String, CaseIterable {
    case app
    case headless
    case auto
}

enum MCPResolvedBackend: String, Equatable {
    case app
    case headless
}

enum MCPBackendSelection {
    static func resolve(
        requested: MCPBackend,
        appIsAvailable: () -> Bool = MCPAppSocketAvailabilityProbe.isAvailable
    ) -> MCPResolvedBackend {
        switch requested {
        case .app:
            .app
        case .headless:
            .headless
        case .auto:
            appIsAvailable() ? .app : .headless
        }
    }
}

enum MCPAppSocketAvailabilityProbe {
    private static let pollTimeoutMilliseconds: Int32 = 150

    /// Probes only the well-known app bootstrap endpoint. The probe completes before the
    /// selected backend reads stdin, sends no handshake or MCP bytes, and never inspects a
    /// private headless child endpoint.
    static func isAvailable() -> Bool {
        isAvailable(at: MCPFilesystemConstants.bootstrapSocketURL())
    }

    static func isAvailable(at socketURL: URL) -> Bool {
        let path = socketURL.path
        guard isUnixDomainSocket(at: path) else { return false }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        do {
            try POSIXDescriptorSupport.setCloseOnExec(fd)
        } catch {
            return false
        }

        let currentFlags = fcntl(fd, F_GETFL)
        guard currentFlags >= 0, fcntl(fd, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
            return false
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return false
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                _ = strcpy(
                    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self),
                    source
                )
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 {
            return true
        }
        guard errno == EINPROGRESS || errno == EAGAIN else {
            return false
        }

        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptor, 1, pollTimeoutMilliseconds) > 0 else {
            return false
        }
        let terminalEvents = Int16(POLLERR | POLLHUP | POLLNVAL)
        guard descriptor.revents & terminalEvents == 0 else {
            return false
        }

        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(
            fd,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &socketErrorLength
        ) == 0 else {
            return false
        }
        return socketError == 0
    }

    private static func isUnixDomainSocket(at path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFSOCK
    }
}
