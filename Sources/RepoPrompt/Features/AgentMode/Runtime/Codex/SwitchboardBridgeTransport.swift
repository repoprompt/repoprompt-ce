import Darwin
import Foundation

/// Private one-request Unix transport. It never logs paths, frames or errno text.
/// All reads, writes and connect share one monotonic deadline, including EOF.
enum SwitchboardBridgeTransport {
    struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    static func processStart(pid: Int32) throws -> SwitchboardPairingEnvelope.ProcessStart {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(),
              info.pbi_start_tvsec > 0, info.pbi_start_tvsec <= UInt64(Int64.max),
              info.pbi_start_tvusec < 1_000_000
        else { throw SwitchboardBridgeError.unauthorized }
        return .init(seconds: Int64(info.pbi_start_tvsec), microseconds: Int64(info.pbi_start_tvusec))
    }

    static func address(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path),
              !path.utf8.contains(0)
        else { throw SwitchboardBridgeError.invalidRequest }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: bytes.count) { pointer in
                for (index, byte) in bytes.enumerated() {
                    pointer[index] = byte
                }
            }
        }
        return address
    }

    static func exchange(pairing: SwitchboardPairingEnvelope, request: Data) throws -> Data {
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        guard !request.isEmpty, request.count <= SwitchboardBridgeWire.maximumFrameBytes, request.last == 0x0A
        else { throw SwitchboardBridgeError.invalidRequest }
        let identity = try validatePath(pairing.socketPath)
        var address = try address(path: pairing.socketPath)
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw SwitchboardBridgeError.unavailable }
        defer { Darwin.close(socket) }
        guard fcntl(socket, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(socket, F_SETFL, O_NONBLOCK) == 0
        else { throw SwitchboardBridgeError.unavailable }
        var noSignal: Int32 = 1
        guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { throw SwitchboardBridgeError.unavailable }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN || errno == EINTR
            else { throw SwitchboardBridgeError.unavailable }
            try ready(socket, events: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0
            else { throw SwitchboardBridgeError.unavailable }
        }

        // Authentication precedes the first byte containing the capability.
        guard try validatePath(pairing.socketPath) == identity else { throw SwitchboardBridgeError.unauthorized }
        try validatePeer(socket, pairing: pairing)
        try write(request, socket: socket, deadline: deadline)
        guard shutdown(socket, SHUT_WR) == 0 else { throw SwitchboardBridgeError.unavailable }
        let response = try read(socket: socket, deadline: deadline)
        // Darwin may discard LOCAL_PEERPID after the peer has closed. The
        // connected peer was kernel-authenticated before writing; after EOF,
        // recheck that exact process birth stamp instead of querying a dead link.
        guard try processStart(pid: pairing.peerPID) == pairing.peerStart
        else { throw SwitchboardBridgeError.unauthorized }
        return response
    }

    private static func validatePeer(_ socket: Int32, pairing: SwitchboardPairingEnvelope) throws {
        var user: uid_t = 0
        var group: gid_t = 0
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(socket, &user, &group) == 0, user == getuid(),
              getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
              size == MemoryLayout<pid_t>.size, pid > 0, pid == pairing.peerPID,
              try processStart(pid: pid) == pairing.peerStart
        else { throw SwitchboardBridgeError.unauthorized }
    }

    /// Walk directories using descriptors and O_NOFOLLOW so no path component
    /// can silently redirect validation through a symlink. The immediate parent
    /// and socket must belong to this UID and have exactly private permissions.
    static func validatePath(_ path: String) throws -> FileIdentity {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), components.count >= 3,
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.utf8.contains(0)
        else { throw SwitchboardBridgeError.unauthorized }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw SwitchboardBridgeError.unauthorized }
        defer { Darwin.close(directory) }
        for component in components.dropFirst().dropLast() {
            let next = openat(directory, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw SwitchboardBridgeError.unauthorized }
            Darwin.close(directory)
            directory = next
        }
        var parentInfo = stat()
        guard fstat(directory, &parentInfo) == 0, parentInfo.st_uid == getuid(),
              parentInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              parentInfo.st_mode & 0o7777 == 0o700
        else { throw SwitchboardBridgeError.unauthorized }
        var socketInfo = stat()
        guard let name = components.last,
              fstatat(directory, String(name), &socketInfo, AT_SYMLINK_NOFOLLOW) == 0,
              socketInfo.st_uid == getuid(),
              socketInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              socketInfo.st_mode & 0o7777 == 0o600
        else { throw SwitchboardBridgeError.unauthorized }
        return .init(device: socketInfo.st_dev, inode: socketInfo.st_ino)
    }

    private static func ready(_ socket: Int32, events: Int16, deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw SwitchboardBridgeError.unavailable }
            let milliseconds = Int32(min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max)))
            var descriptor = pollfd(fd: socket, events: events, revents: 0)
            let count = Darwin.poll(&descriptor, 1, milliseconds)
            if count < 0, errno == EINTR { continue }
            guard count > 0, descriptor.revents & Int16(POLLNVAL) == 0,
                  descriptor.revents & (events | Int16(POLLHUP) | Int16(POLLERR)) != 0
            else { throw SwitchboardBridgeError.unavailable }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw SwitchboardBridgeError.unavailable }
            return
        }
    }

    private static func write(_ request: Data, socket: Int32, deadline: UInt64) throws {
        try request.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw SwitchboardBridgeError.invalidRequest }
            var offset = 0
            while offset < bytes.count {
                try ready(socket, events: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.send(socket, base.advanced(by: offset), bytes.count - offset, 0)
                if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                guard count > 0 else { throw SwitchboardBridgeError.unavailable }
                offset += count
            }
        }
    }

    private static func read(socket: Int32, deadline: UInt64) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try ready(socket, events: Int16(POLLIN), deadline: deadline)
            let count = Darwin.recv(socket, &buffer, buffer.count, 0)
            if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            guard count >= 0 else { throw SwitchboardBridgeError.unavailable }
            if count == 0 {
                try SwitchboardBridgeWire.validateFrame(result)
                return result
            }
            guard result.count + count <= SwitchboardBridgeWire.maximumFrameBytes
            else { throw SwitchboardBridgeError.invalidRequest }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}
