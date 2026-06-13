import Darwin
import Darwin.POSIX.fcntl
import Foundation

/// Best-effort raw file-descriptor writer for diagnostic output on MCP stdio
/// transports.
///
/// Foundation's `FileHandle.write(_:)` raises an Objective-C
/// `NSFileHandleOperationException` when the descriptor is closed or the pipe
/// is broken, and Swift `do/catch` cannot intercept that exception, so a
/// failed diagnostic write aborts the whole process. Transport diagnostics
/// must never be able to crash the MCP helper, so this writer uses
/// `Darwin.write` directly and silently drops the payload when the destination
/// is unavailable (`EPIPE`, `EBADF`, `EINVAL`, or any other write failure).
public enum BestEffortStderrWriter {
    private static let writeLock = NSLock()

    /// Writes `data` to `descriptor`, returning `true` only when every byte
    /// was delivered. Never throws and never raises: any failure other than
    /// an interrupted write drops the remaining payload.
    ///
    /// This legacy variant can block when the destination is a full pipe. Use
    /// `writeNonBlocking(_:to:)` from terminal or deadline-enforcement paths.
    @discardableResult
    public static func write(_ data: Data, to descriptor: Int32 = STDERR_FILENO) -> Bool {
        guard descriptor >= 0 else { return false }
        guard !data.isEmpty else { return true }
        writeLock.lock()
        defer { writeLock.unlock() }
        suppressSIGPIPE(on: descriptor)
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(descriptor, baseAddress + offset, rawBuffer.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    /// Attempts one nonblocking write and drops any unwritten bytes.
    ///
    /// File-status flags belong to the shared open-file description, so even
    /// a duplicated descriptor cannot isolate `O_NONBLOCK`. Serialize our
    /// writers from this helper, keep the mutation window to one write syscall,
    /// and restore the original status flags before returning. If another helper
    /// writer owns the window, drop this payload rather than waiting. Writers
    /// outside this helper can still observe the brief nonblocking window; no
    /// POSIX primitive can make this transition private for pipes. Locking the C
    /// `stderr` stream on its exact descriptor also avoids racing stdio writers
    /// when that lock is immediately available.
    @discardableResult
    public static func writeNonBlocking(_ data: Data, to descriptor: Int32 = STDERR_FILENO) -> Bool {
        guard descriptor >= 0 else { return false }
        guard !data.isEmpty else { return true }
        guard writeLock.try() else { return false }
        defer { writeLock.unlock() }

        let lockedStandardError = descriptor == STDERR_FILENO
        if lockedStandardError, ftrylockfile(stderr) != 0 {
            return false
        }
        defer {
            if lockedStandardError { funlockfile(stderr) }
        }

        let originalFlags = fcntl(descriptor, F_GETFL)
        guard originalFlags >= 0 else { return false }
        let rawNoSIGPIPE = fcntl(descriptor, F_GETNOSIGPIPE)
        let originalNoSIGPIPE = rawNoSIGPIPE >= 0 ? rawNoSIGPIPE : nil
        let needsNoSIGPIPE = originalNoSIGPIPE == 0
        if needsNoSIGPIPE,
           fcntl(descriptor, F_SETNOSIGPIPE, 1) < 0
        {
            return false
        }

        let needsNonBlocking = originalFlags & O_NONBLOCK == 0
        if needsNonBlocking,
           fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) < 0
        {
            _ = restoreDiagnosticState(
                descriptor: descriptor,
                originalFlags: originalFlags,
                restoreNonBlocking: false,
                noSIGPIPE: needsNoSIGPIPE ? originalNoSIGPIPE : nil
            )
            return false
        }

        let writeSucceeded = data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            let written = Darwin.write(descriptor, baseAddress, rawBuffer.count)
            return written == rawBuffer.count
        }

        // Restore every state bit we changed while holding our writer lock. Darwin may
        // expose kernel-maintained bits through F_GETFL after a write. Read the
        // latest flags and replace only O_NONBLOCK so unrelated concurrent flag
        // changes are not clobbered. Restore the independently queried SIGPIPE
        // setting too. Code that mutates O_NONBLOCK or F_SETNOSIGPIPE without
        // this lock remains inherently racy at the POSIX open-description level.
        let restoredState = restoreDiagnosticState(
            descriptor: descriptor,
            originalFlags: originalFlags,
            restoreNonBlocking: needsNonBlocking,
            noSIGPIPE: needsNoSIGPIPE ? originalNoSIGPIPE : nil
        )
        return writeSucceeded && restoredState
    }

    private static func restoreDiagnosticState(
        descriptor: Int32,
        originalFlags: Int32,
        restoreNonBlocking: Bool,
        noSIGPIPE: Int32?
    ) -> Bool {
        let restoredFlags: Bool
        if restoreNonBlocking {
            let latestFlags = fcntl(descriptor, F_GETFL)
            if latestFlags >= 0 {
                let flags = (latestFlags & ~O_NONBLOCK) | (originalFlags & O_NONBLOCK)
                restoredFlags = fcntl(descriptor, F_SETFL, flags) >= 0
            } else {
                restoredFlags = false
            }
        } else {
            restoredFlags = true
        }

        guard let noSIGPIPE else { return restoredFlags }
        let restoredSIGPIPE = fcntl(descriptor, F_SETNOSIGPIPE, noSIGPIPE) >= 0
        return restoredFlags && restoredSIGPIPE
    }

    private static func suppressSIGPIPE(on descriptor: Int32) {
        // Failure is acceptable: callers also ignore SIGPIPE process-wide, and
        // the write still fails softly when descriptor configuration is unavailable.
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
    }
}
