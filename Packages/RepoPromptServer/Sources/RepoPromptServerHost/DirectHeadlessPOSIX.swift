#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Cross-platform POSIX calls used by the private direct-headless transports.
/// Platform-specific socket options remain contained here so the Server Host
/// target can compile independently on both macOS and Linux.
enum DirectHeadlessPOSIX {
    #if canImport(Glibc)
        private struct LinuxSocketCredentials {
            var pid: pid_t = 0
            var uid: uid_t = 0
            var gid: gid_t = 0
        }
    #endif

    static func ignoreSIGPIPE() {
        signal(SIGPIPE, SIG_IGN)
    }

    static func enableNoSIGPIPE(on fd: Int32) {
        #if canImport(Darwin)
            var noSigPipe: Int32 = 1
            _ = setsockopt(
                fd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout<Int32>.size)
            )
        #endif
    }

    static func closeDescriptor(_ fd: Int32) {
        #if canImport(Darwin)
            _ = Darwin.close(fd)
        #else
            _ = Glibc.close(fd)
        #endif
    }

    private static func shutdownDescriptor(_ fd: Int32, how: Int32) {
        #if canImport(Darwin)
            _ = Darwin.shutdown(fd, how)
        #else
            _ = Glibc.shutdown(fd, how)
        #endif
    }

    static func shutdownReadWrite(_ fd: Int32) {
        shutdownDescriptor(fd, how: shutdownHowReadWrite)
    }

    static func shutdownWrite(_ fd: Int32) {
        shutdownDescriptor(fd, how: shutdownHowWrite)
    }

    static func unixStreamSocket() -> Int32 {
        #if canImport(Darwin)
            Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #else
            Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
    }

    static func bindUnix(_ fd: Int32, _ address: inout sockaddr_un) -> Int32 {
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #else
                    Glibc.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
    }

    static func connectUnix(_ fd: Int32, _ address: inout sockaddr_un) -> Int32 {
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #else
                    Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
    }

    static func listen(_ fd: Int32, backlog: Int32) -> Int32 {
        #if canImport(Darwin)
            Darwin.listen(fd, backlog)
        #else
            Glibc.listen(fd, backlog)
        #endif
    }

    static func accept(_ fd: Int32) -> Int32 {
        var address = sockaddr()
        var length = socklen_t(MemoryLayout<sockaddr>.size)
        #if canImport(Darwin)
            return Darwin.accept(fd, &address, &length)
        #else
            return Glibc.accept(fd, &address, &length)
        #endif
    }

    static func fillUnixAddress(_ address: inout sockaddr_un, path: String) -> Bool {
        address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            guard let base = destination.baseAddress else { return }
            bytes.withUnsafeBufferPointer { source in
                guard let sourceBase = source.baseAddress else { return }
                memcpy(base, sourceBase, source.count)
            }
        }
        return true
    }

    static func poll(_ descriptor: inout pollfd, timeout: Int32) -> Int32 {
        #if canImport(Darwin)
            Darwin.poll(&descriptor, 1, timeout)
        #else
            Glibc.poll(&descriptor, 1, timeout)
        #endif
    }

    static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
            Darwin.read(fd, buffer, count)
        #else
            Glibc.read(fd, buffer, count)
        #endif
    }

    static func write(_ fd: Int32, _ base: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
            Darwin.write(fd, base, count)
        #else
            Glibc.write(fd, base, count)
        #endif
    }

    static func peerPID(_ fd: Int32) -> Int32? {
        #if canImport(Darwin)
            var pid: pid_t = 0
            var size = socklen_t(MemoryLayout<pid_t>.size)
            guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
            return pid
        #else
            var credentials = LinuxSocketCredentials()
            var size = socklen_t(MemoryLayout<LinuxSocketCredentials>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &size) == 0,
                  credentials.pid > 0
            else { return nil }
            return credentials.pid
        #endif
    }

    private static var shutdownHowReadWrite: Int32 {
        #if canImport(Darwin)
            SHUT_RDWR
        #else
            Int32(SHUT_RDWR)
        #endif
    }

    private static var shutdownHowWrite: Int32 {
        #if canImport(Darwin)
            SHUT_WR
        #else
            Int32(SHUT_WR)
        #endif
    }
}
