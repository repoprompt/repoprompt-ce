#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation

@inline(__always)
func rpMakeUnixStreamSocket() -> Int32 {
#if canImport(Darwin)
    socket(AF_UNIX, SOCK_STREAM, 0)
#else
    socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
#endif
}

@inline(__always)
func rpConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
#if canImport(Darwin)
    Darwin.connect(fd, address, length)
#else
    Glibc.connect(fd, address, length)
#endif
}

@discardableResult
@inline(__always)
func rpConfigureNoSIGPIPE(_ fd: Int32) -> Int32 {
#if canImport(Darwin)
    var enabled: Int32 = 1
    return setsockopt(
        fd,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &enabled,
        socklen_t(MemoryLayout<Int32>.size)
    )
#else
    // Linux has no SO_NOSIGPIPE. The executable ignores SIGPIPE before any
    // transport starts, so writes fail with EPIPE and retain bounded handling.
    _ = fd
    return 0
#endif
}

@inline(__always)
func rpShutdownReadWrite(_ fd: Int32) {
    _ = shutdown(fd, Int32(SHUT_RDWR))
}

@inline(__always)
func rpShutdownWrite(_ fd: Int32) {
    _ = shutdown(fd, Int32(SHUT_WR))
}

func rpPeerProcessID(_ fd: Int32) -> Int32? {
#if canImport(Darwin)
    var pid: pid_t = 0
    var size = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
    return pid
#else
    struct LinuxPeerCredentials {
        var pid: pid_t = 0
        var uid: uid_t = 0
        var gid: gid_t = 0
    }
    var credentials = LinuxPeerCredentials()
    var size = socklen_t(MemoryLayout<LinuxPeerCredentials>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &size) == 0,
          credentials.pid > 0
    else { return nil }
    return credentials.pid
#endif
}

func rpExecutablePath(processID: Int32) -> String? {
#if canImport(Darwin)
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(processID, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
#else
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let count = readlink("/proc/\(processID)/exe", &buffer, buffer.count)
    guard count > 0 else { return nil }
    let bytes = buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
#endif
}
