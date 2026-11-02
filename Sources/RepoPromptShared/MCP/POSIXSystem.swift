import RepoPromptC
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

package enum POSIXSystem {
    package static var shutdownRead: Int32 {
        #if canImport(Darwin)
            Int32(Darwin.SHUT_RD)
        #else
            Int32(Glibc.SHUT_RD)
        #endif
    }

    package static var shutdownWrite: Int32 {
        #if canImport(Darwin)
            Int32(Darwin.SHUT_WR)
        #else
            Int32(Glibc.SHUT_WR)
        #endif
    }

    package static var shutdownReadWrite: Int32 {
        #if canImport(Darwin)
            Int32(Darwin.SHUT_RDWR)
        #else
            Int32(Glibc.SHUT_RDWR)
        #endif
    }

    package static var regularFileType: mode_t {
        #if canImport(Darwin)
            mode_t(Darwin.S_IFREG)
        #else
            mode_t(Glibc.S_IFREG)
        #endif
    }

    package static var directoryFileType: mode_t {
        #if canImport(Darwin)
            mode_t(Darwin.S_IFDIR)
        #else
            mode_t(Glibc.S_IFDIR)
        #endif
    }

    package static var symbolicLinkType: mode_t {
        #if canImport(Darwin)
            mode_t(Darwin.S_IFLNK)
        #else
            mode_t(Glibc.S_IFLNK)
        #endif
    }

    package static var fileTypeMask: mode_t {
        #if canImport(Darwin)
            mode_t(Darwin.S_IFMT)
        #else
            mode_t(Glibc.S_IFMT)
        #endif
    }

    package static var stickyBit: mode_t {
        #if canImport(Darwin)
            mode_t(Darwin.S_ISVTX)
        #else
            mode_t(Glibc.S_ISVTX)
        #endif
    }

    package static var streamSocketType: Int32 {
        #if canImport(Darwin)
            SOCK_STREAM
        #else
            Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue)
        #endif
    }

    package static func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
            Darwin.read(descriptor, buffer, count)
        #else
            Glibc.read(descriptor, buffer, count)
        #endif
    }

    package static func write(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
        repo_write_no_sigpipe(descriptor, buffer, count)
    }

    @discardableResult
    package static func close(_ descriptor: Int32) -> Int32 {
        #if canImport(Darwin)
            Darwin.close(descriptor)
        #else
            Glibc.close(descriptor)
        #endif
    }

    package static func open(_ path: String, _ flags: Int32, _ mode: mode_t = 0) -> Int32 {
        #if canImport(Darwin)
            Darwin.open(path, flags, mode)
        #else
            Glibc.open(path, flags, mode)
        #endif
    }

    package static func socket(_ domain: Int32, _ type: Int32, _ protocolNumber: Int32) -> Int32 {
        #if canImport(Darwin)
            Darwin.socket(domain, type, protocolNumber)
        #else
            Glibc.socket(domain, type, protocolNumber)
        #endif
    }

    package static func connect(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Darwin)
            Darwin.connect(descriptor, address, length)
        #else
            Glibc.connect(descriptor, address, length)
        #endif
    }

    @discardableResult
    package static func shutdown(_ descriptor: Int32, _ how: Int32) -> Int32 {
        #if canImport(Darwin)
            Darwin.shutdown(descriptor, how)
        #else
            Glibc.shutdown(descriptor, how)
        #endif
    }

    package static func poll(_ descriptors: UnsafeMutablePointer<pollfd>, _ count: Int, _ timeout: Int32) -> Int32 {
        #if canImport(Darwin)
            Darwin.poll(descriptors, nfds_t(count), timeout)
        #else
            Glibc.poll(descriptors, nfds_t(count), timeout)
        #endif
    }

    package static func bind(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Darwin)
            Darwin.bind(descriptor, address, length)
        #else
            Glibc.bind(descriptor, address, length)
        #endif
    }

    package static func listen(_ descriptor: Int32, _ backlog: Int32) -> Int32 {
        #if canImport(Darwin)
            Darwin.listen(descriptor, backlog)
        #else
            Glibc.listen(descriptor, backlog)
        #endif
    }

    package static func accept(_ descriptor: Int32, _ address: UnsafeMutablePointer<sockaddr>, _ length: UnsafeMutablePointer<socklen_t>) -> Int32 {
        repo_accept_cloexec(descriptor, address, length)
    }

    package static func waitid(_ type: idtype_t, _ identifier: id_t, _ info: UnsafeMutablePointer<siginfo_t>, _ options: Int32) -> Int32 {
        #if canImport(Darwin)
            Darwin.waitid(type, identifier, info, options)
        #else
            Glibc.waitid(type, identifier, info, options)
        #endif
    }
}
