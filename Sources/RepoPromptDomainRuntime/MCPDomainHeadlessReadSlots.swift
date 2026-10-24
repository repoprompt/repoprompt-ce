import Darwin
import Foundation
import OSLog

/// Cross-process FIFO admission. A locked claim is a live waiter; unlocked claims are
/// crash leftovers. Registration/pruning use one short turnstile lock, never held for I/O.
package enum MCPDomainHeadlessReadSlots {
    private static let logger = Logger(subsystem: "com.repoprompt.ce", category: "HeadlessReadAdmission")
    private static let warnings = WarningState()

    package static func deadline(timeout: Duration = .seconds(15)) -> MCPDomainAdmissionDeadline {
        let clock = ContinuousClock()
        let start = clock.now
        return MCPDomainAdmissionDeadline(instant: timeout, now: { start.duration(to: clock.now) }, sleep: {
            try await Task.sleep(for: $0)
        })
    }

    package static func acquire(
        directory: URL?, count: Int, deadline: MCPDomainAdmissionDeadline,
        checkCancellation: () throws -> Void, didWait: () -> Void,
        warning: (@Sendable (Int32) -> Void)?
    ) throws -> Int32? {
        precondition(count > 0)
        do {
            if directory == nil, ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
                warn(EPERM, warning: warning)
                return nil
            }
            let sharedDirectory = try directory ?? defaultDirectory()
            if directory == nil, sharedDirectory.path.contains("/Library/Containers/") {
                warn(EPERM, warning: warning)
                return nil
            }
            return try acquireShared(
                directory: sharedDirectory, count: count, deadline: deadline,
                checkCancellation: checkCancellation, didWait: didWait
            )
        } catch let error as POSIXError where [EACCES, EPERM, EROFS].contains(error.code.rawValue) {
            // Availability failures may degrade coordination, never owner/mode/link failures.
            warn(error.code.rawValue, warning: warning)
            return nil
        }
    }

    private static func warn(_ code: Int32, warning: (@Sendable (Int32) -> Void)?) {
        if let warning { warning(code)
            return
        }
        if warnings.shouldLog() {
            logger.warning("Shared headless file-read slots unavailable (POSIX \(code)); using the in-process bound only")
        }
    }

    private final class WarningState: @unchecked Sendable {
        private let lock = NSLock()
        private var emitted = false
        func shouldLog() -> Bool {
            lock.withLock { defer { emitted = true }
                return !emitted
            }
        }
    }

    private static func defaultDirectory() throws -> URL {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 1 else { throw POSIXError(.EPERM) }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) == length else { throw POSIXError(.EPERM) }
        return URL(fileURLWithPath: String(decoding: buffer.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self), isDirectory: true)
            .appendingPathComponent("repoprompt-ce-headless-file-reads", isDirectory: true)
    }

    private static func failure() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func checkedFile(_ name: String, directory: Int32, exclusive: Bool = false, create: Bool = true) throws -> Int32 {
        var existing = stat()
        let exists = fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) == 0
        if exists {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_uid == getuid(),
                  existing.st_mode & 0o077 == 0, existing.st_nlink == 1
            else { throw MCPDomainHeadlessFileReader.ReadError.unsafeAdmissionDirectory }
        } else if errno != ENOENT { throw failure() }
        let baseFlags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        let creating = create && (!exists || exclusive)
        let flags = baseFlags | (creating ? O_CREAT | O_EXCL : 0)
        var fd = openat(directory, name, flags, 0o600)
        // Another process may win first creation between metadata validation and open.
        // Open the winner without creation flags; it still receives full post-open checks.
        if fd < 0, errno == EEXIST, !exclusive {
            fd = openat(directory, name, baseFlags)
        }
        guard fd >= 0 else {
            let code = errno
            if code == ELOOP { throw MCPDomainHeadlessFileReader.ReadError.unsafeAdmissionDirectory }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO, userInfo: ["entry": name])
        }
        do {
            var metadata = stat()
            guard fstat(fd, &metadata) == 0 else { throw failure() }
            guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(),
                  metadata.st_mode & 0o077 == 0, metadata.st_nlink == 1
            else { throw MCPDomainHeadlessFileReader.ReadError.unsafeAdmissionDirectory }
            return fd
        } catch { close(fd)
            throw error
        }
    }

    private static func tryLock(_ fd: Int32) throws -> Bool {
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
        guard errno == EWOULDBLOCK || errno == EAGAIN else { throw failure() }
        return false
    }

    private struct Backoff {
        var delay = 0.01
        mutating func wait(
            deadline: MCPDomainAdmissionDeadline, checkCancellation: () throws -> Void, didWait: () -> Void
        ) throws {
            try checkCancellation()
            try deadline.check()
            didWait()
            let remaining = deadline.remaining().components
            let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            Thread.sleep(forTimeInterval: min(seconds, delay * Double.random(in: 0.8 ... 1.2)))
            delay = min(0.25, delay * 2)
            try checkCancellation()
            try deadline.check()
        }
    }

    private static func lock(
        _ fd: Int32, deadline: MCPDomainAdmissionDeadline, checkCancellation: () throws -> Void, didWait: () -> Void
    ) throws {
        var backoff = Backoff()
        while true {
            try checkCancellation()
            try deadline.check()
            if try tryLock(fd) { return }
            try backoff.wait(deadline: deadline, checkCancellation: checkCancellation, didWait: didWait)
        }
    }

    private static func acquireShared(
        directory: URL, count: Int, deadline: MCPDomainAdmissionDeadline,
        checkCancellation: () throws -> Void, didWait: () -> Void
    ) throws -> Int32 {
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw failure() }
        var expectedDirectory = stat()
        guard lstat(directory.path, &expectedDirectory) == 0 else { throw failure() }
        guard expectedDirectory.st_mode & S_IFMT == S_IFDIR, expectedDirectory.st_uid == getuid(),
              expectedDirectory.st_mode & 0o077 == 0
        else { throw MCPDomainHeadlessFileReader.ReadError.unsafeAdmissionDirectory }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else {
            if errno == ELOOP || errno == ENOTDIR { throw MCPDomainHeadlessFileReader.ReadError.unsafeAdmissionDirectory }
            throw failure()
        }
        defer { close(directoryFD) }
        var metadata = stat()
        guard fstat(directoryFD, &metadata) == 0 else { throw failure() }
        guard metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0,
              metadata.st_ino == expectedDirectory.st_ino, metadata.st_dev == expectedDirectory.st_dev
        else {
            throw MCPDomainHeadlessFileReader.ReadError.unsafeAdmissionDirectory
        }
        let turnstile = try checkedFile("turnstile", directory: directoryFD)
        defer { close(turnstile) }
        try lock(turnstile, deadline: deadline, checkCancellation: checkCancellation, didWait: didWait)
        let claim: (name: String, fd: Int32)
        do {
            var turnstileMetadata = stat()
            guard fstat(turnstile, &turnstileMetadata) == 0 else { throw failure() }
            guard turnstileMetadata.st_size == 0 || turnstileMetadata.st_size == MemoryLayout<UInt64>.size else {
                throw MCPDomainHeadlessFileReader.ReadError.unsafeAdmissionDirectory
            }
            var ticket: UInt64 = 0
            let size = pread(turnstile, &ticket, MemoryLayout<UInt64>.size, 0)
            guard size == 0 || size == MemoryLayout<UInt64>.size, ticket < UInt64.max else {
                throw MCPDomainHeadlessFileReader.ReadError.unsafeAdmissionDirectory
            }
            ticket += 1
            guard pwrite(turnstile, &ticket, MemoryLayout<UInt64>.size, 0) == MemoryLayout<UInt64>.size else { throw failure() }
            let name = String(format: "wait-%020llu-", ticket) + UUID().uuidString
            let fd = try checkedFile(name, directory: directoryFD, exclusive: true)
            do {
                guard try tryLock(fd) else { throw POSIXError(.EIO) }
                claim = (name, fd)
            } catch {
                unlinkat(directoryFD, name, 0)
                close(fd)
                throw error
            }
        } catch {
            flock(turnstile, LOCK_UN)
            throw error
        }
        flock(turnstile, LOCK_UN)
        defer {
            // Do not race a directory scan or block cancellation on cleanup. If the
            // turnstile is occupied, closing leaves an unlocked claim for its next holder.
            if (try? tryLock(turnstile)) == true {
                unlinkat(directoryFD, claim.name, 0)
                flock(turnstile, LOCK_UN)
            }
            close(claim.fd)
        }
        var backoff = Backoff()
        // FIFO once registered. Only the queue head opens slot descriptors, once each;
        // later arrivals cannot repeatedly race the head for newly released capacity.
        while true {
            try lock(turnstile, deadline: deadline, checkCancellation: checkCancellation, didWait: didWait)
            let isHead: Bool
            do {
                isHead = try firstLiveClaim(directory: directoryFD, ownName: claim.name) == claim.name
                flock(turnstile, LOCK_UN)
            } catch {
                flock(turnstile, LOCK_UN)
                throw error
            }
            if isHead { break }
            try backoff.wait(deadline: deadline, checkCancellation: checkCancellation, didWait: didWait)
        }
        var slots: [Int32] = []
        defer { for fd in slots {
            close(fd)
        } }
        while true {
            try checkCancellation()
            try deadline.check()
            for index in 0 ..< count {
                if index == slots.count { try slots.append(checkedFile("slot-\(index)", directory: directoryFD)) }
                if try tryLock(slots[index]) { return slots.remove(at: index) }
            }
            try backoff.wait(deadline: deadline, checkCancellation: checkCancellation, didWait: didWait)
        }
    }

    /// Inspect claim locks under the turnstile, deleting only unlocked crash leftovers.
    private static func firstLiveClaim(directory: Int32, ownName: String) throws -> String? {
        let scanFD = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard scanFD >= 0 else { throw failure() }
        guard let scan = fdopendir(scanFD) else { close(scanFD)
            throw failure()
        }
        defer { closedir(scan) }
        var names: [String] = []
        while let entry = readdir(scan) {
            let capacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name.hasPrefix("wait-") { names.append(name) }
        }
        for name in names.sorted() {
            if name == ownName { return name }
            let fd: Int32
            do {
                fd = try checkedFile(name, directory: directory, create: false)
            } catch let error as POSIXError where error.code == .ENOENT {
                continue
            }
            defer { close(fd) }
            if try tryLock(fd) {
                unlinkat(directory, name, 0)
            } else {
                return name
            }
        }
        return nil
    }
}
