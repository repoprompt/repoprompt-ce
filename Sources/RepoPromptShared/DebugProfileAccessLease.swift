import Darwin
import Foundation

/// A stable sibling lock, outside the directory that snapshot publication swaps.
/// Readers/writers hold shared admission for their entire store lifetime; bootstrap
/// holds exclusive admission from capture through publication, then downgrades.
/// This coordinates cooperating CE processes, not hostile same-user filesystem edits.
public final class DebugProfileAccessLease: @unchecked Sendable {
    public enum Failure: Error, LocalizedError {
        case busy, unsafeLock
        public var errorDescription: String? {
            switch self {
            case .busy: "The debug profile is in use by another app or headless runtime. Close that owner and retry; no profile was replaced."
            case .unsafeLock: "Debug profile admission could not be secured. No profile was replaced."
            }
        }
    }

    private let descriptor: Int32
    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    public static func acquire(locations: AppProfileLocations, exclusive: Bool) throws -> DebugProfileAccessLease {
        guard locations.identity.buildFlavor == .debug else { throw Failure.unsafeLock }
        try locations.validateWritableRoot(locations.applicationSupportRoot)
        let parent = locations.applicationSupportRoot.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = parent.appendingPathComponent(".repoprompt-ce-debug-seed.lock")
        try locations.validateMetadataFile(url)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.unsafeLock }
        do {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_nlink == 1,
                  info.st_mode & 0o077 == 0 else { throw Failure.unsafeLock }
            let mode = (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB
            while flock(fd, mode) != 0 {
                if errno == EINTR { continue }
                throw errno == EWOULDBLOCK || errno == EAGAIN ? Failure.busy : Failure.unsafeLock
            }
            return DebugProfileAccessLease(descriptor: fd)
        } catch {
            close(fd)
            throw error
        }
    }

    /// Called before app stores open; keep admission without excluding other writers.
    public func allowWriters() throws {
        while flock(descriptor, LOCK_SH | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            throw Failure.unsafeLock
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
