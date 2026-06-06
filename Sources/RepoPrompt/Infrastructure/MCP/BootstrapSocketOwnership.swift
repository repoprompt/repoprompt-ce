import Darwin
import Foundation

/// Retained ownership of one well-known UNIX-domain socket pathname.
/// The same-directory lock descriptor remains held for the listener lifetime.
final class BootstrapSocketOwnership: @unchecked Sendable {
    struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
        let mode: mode_t

        var fileType: mode_t {
            mode & mode_t(S_IFMT)
        }

        var isSocket: Bool {
            fileType == mode_t(S_IFSOCK)
        }

        var isRegularFile: Bool {
            fileType == mode_t(S_IFREG)
        }
    }

    enum PathStatus: Equatable {
        case owned
        case missing
        case replaced(FileIdentity)
        case lockLost
    }

    enum OwnershipError: LocalizedError, Equatable {
        case lockOpenFailed(path: String, errno: Int32)
        case lockInvalid(path: String)
        case lockUnavailable(path: String, errno: Int32)
        case pathOwnedByAnotherUser(path: String)
        case unmanagedPath(path: String)
        case liveOwner(path: String)
        case socketProbeFailed(path: String, errno: Int32)
        case staleRemovalFailed(path: String, errno: Int32)
        case boundIdentityMissing(path: String)

        var errorDescription: String? {
            switch self {
            case let .lockOpenFailed(path, code):
                "Could not open socket ownership lock at \(path) (errno \(code))"
            case let .lockInvalid(path):
                "Socket ownership lock is not an owner-controlled regular file: \(path)"
            case let .lockUnavailable(path, code):
                "Another listener owns the socket lock at \(path) (errno \(code))"
            case let .pathOwnedByAnotherUser(path):
                "Socket pathname is owned by another user: \(path)"
            case let .unmanagedPath(path):
                "Refusing to replace a non-socket entry at \(path)"
            case let .liveOwner(path):
                "A live listener already owns \(path)"
            case let .socketProbeFailed(path, code):
                "Could not prove the existing socket is stale at \(path) (errno \(code))"
            case let .staleRemovalFailed(path, code):
                "Could not remove the confirmed stale socket at \(path) (errno \(code))"
            case let .boundIdentityMissing(path):
                "Bound socket identity is unavailable at \(path)"
            }
        }
    }

    let socketURL: URL
    let lockURL: URL

    private let lockFD: Int32
    private let lockIdentity: FileIdentity
    private let stateLock = NSLock()
    private var released = false
    private var boundIdentity: FileIdentity?

    static func acquire(socketURL: URL) throws -> BootstrapSocketOwnership {
        let lockURL = socketURL.appendingPathExtension("lock")
        let flags = O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW
        let fd = Darwin.open(lockURL.path, flags, mode_t(0o600))
        guard fd >= 0 else {
            throw OwnershipError.lockOpenFailed(path: lockURL.path, errno: errno)
        }

        do {
            guard let descriptorIdentity = identity(forDescriptor: fd),
                  descriptorIdentity.isRegularFile,
                  descriptorIdentity.owner == getuid(),
                  let pathIdentity = identity(atPath: lockURL.path),
                  pathIdentity == descriptorIdentity
            else {
                throw OwnershipError.lockInvalid(path: lockURL.path)
            }
            guard fchmod(fd, mode_t(0o600)) == 0,
                  let securedDescriptorIdentity = identity(forDescriptor: fd),
                  securedDescriptorIdentity.isRegularFile,
                  securedDescriptorIdentity.owner == getuid(),
                  let securedPathIdentity = identity(atPath: lockURL.path),
                  securedPathIdentity == securedDescriptorIdentity
            else {
                throw OwnershipError.lockInvalid(path: lockURL.path)
            }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                throw OwnershipError.lockUnavailable(path: lockURL.path, errno: errno)
            }
            return BootstrapSocketOwnership(
                socketURL: socketURL,
                lockURL: lockURL,
                lockFD: fd,
                lockIdentity: securedDescriptorIdentity
            )
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private init(socketURL: URL, lockURL: URL, lockFD: Int32, lockIdentity: FileIdentity) {
        self.socketURL = socketURL
        self.lockURL = lockURL
        self.lockFD = lockFD
        self.lockIdentity = lockIdentity
    }

    deinit {
        release()
    }

    /// Removes only a socket proven stale while the exclusive ownership lock is held.
    func preparePathForBinding() throws {
        guard let existing = Self.identity(atPath: socketURL.path) else { return }
        guard existing.owner == getuid() else {
            throw OwnershipError.pathOwnedByAnotherUser(path: socketURL.path)
        }
        guard existing.isSocket else {
            throw OwnershipError.unmanagedPath(path: socketURL.path)
        }

        switch try Self.probeSocket(at: socketURL) {
        case .live:
            throw OwnershipError.liveOwner(path: socketURL.path)
        case .stale:
            guard Self.identity(atPath: socketURL.path) == existing else {
                throw OwnershipError.socketProbeFailed(path: socketURL.path, errno: ESTALE)
            }
            guard unlink(socketURL.path) == 0 || errno == ENOENT else {
                throw OwnershipError.staleRemovalFailed(path: socketURL.path, errno: errno)
            }
        }
    }

    func captureBoundSocketIdentity() throws {
        guard let identity = Self.identity(atPath: socketURL.path),
              identity.isSocket,
              identity.owner == getuid()
        else {
            throw OwnershipError.boundIdentityMissing(path: socketURL.path)
        }
        stateLock.lock()
        boundIdentity = identity
        stateLock.unlock()
    }

    func pathStatus() -> PathStatus {
        guard lockFileStillMatches() else { return .lockLost }
        stateLock.lock()
        let expected = boundIdentity
        let isReleased = released
        stateLock.unlock()
        guard !isReleased, let expected else { return .lockLost }
        guard let current = Self.identity(atPath: socketURL.path) else { return .missing }
        return current == expected ? .owned : .replaced(current)
    }

    @discardableResult
    func removeOwnedSocketIfCurrent() -> Bool {
        stateLock.lock()
        let expected = boundIdentity
        stateLock.unlock()
        guard let expected,
              Self.identity(atPath: socketURL.path) == expected
        else { return false }
        return unlink(socketURL.path) == 0 || errno == ENOENT
    }

    func release() {
        stateLock.lock()
        guard !released else {
            stateLock.unlock()
            return
        }
        released = true
        stateLock.unlock()
        _ = flock(lockFD, LOCK_UN)
        Darwin.close(lockFD)
    }

    #if DEBUG
        func debugLockHasCloseOnExec() -> Bool {
            let flags = fcntl(lockFD, F_GETFD)
            return flags >= 0 && (flags & FD_CLOEXEC) != 0
        }
    #endif

    static func identity(atPath path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino, owner: info.st_uid, mode: info.st_mode)
    }

    private static func identity(forDescriptor fd: Int32) -> FileIdentity? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino, owner: info.st_uid, mode: info.st_mode)
    }

    private func lockFileStillMatches() -> Bool {
        stateLock.lock()
        let isReleased = released
        stateLock.unlock()
        guard !isReleased,
              Self.identity(forDescriptor: lockFD) == lockIdentity,
              Self.identity(atPath: lockURL.path) == lockIdentity
        else { return false }
        return true
    }

    private enum ProbeResult {
        case live
        case stale
    }

    private static func probeSocket(at url: URL) throws -> ProbeResult {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw OwnershipError.socketProbeFailed(path: url.path, errno: errno)
        }
        defer { Darwin.close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = url.path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw OwnershipError.socketProbeFailed(path: url.path, errno: ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = byte
                }
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return .live }
        let code = errno
        if code == ECONNREFUSED || code == ENOENT { return .stale }
        throw OwnershipError.socketProbeFailed(path: url.path, errno: code)
    }
}
