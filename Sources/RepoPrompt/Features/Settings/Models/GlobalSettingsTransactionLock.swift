import Darwin
import Foundation

/// A cooperative transaction lock. The sidecar inode survives atomic JSON replacement
/// and is never removed: the kernel descriptor lock, not file existence, owns the lease.
enum GlobalSettingsTransactionLock {
    enum LockError: Error {
        case busy
        case unavailable(Int32)
    }

    static func lockURL(for settingsURL: URL) -> URL {
        settingsURL.appendingPathExtension("lock")
    }

    static func withLock<T>(for settingsURL: URL, _ operation: () throws -> T) throws -> T {
        let descriptor = Darwin.open(
            lockURL(for: settingsURL).path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw LockError.unavailable(errno) }
        defer { _ = Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            if failure == EWOULDBLOCK || failure == EAGAIN { throw LockError.busy }
            throw LockError.unavailable(failure)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
