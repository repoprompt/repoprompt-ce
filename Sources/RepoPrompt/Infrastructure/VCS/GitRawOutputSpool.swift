import CryptoKit
import Darwin
import Foundation

enum GitRawOutputSpoolError: Error, Equatable {
    case invalidConfiguration
    case resourceAdmission
    case closed
    case corrupt(String)
    case io(operation: String, code: Int32)
}

struct GitRawOutputSpoolResourcePolicy: Equatable {
    static let `default` = GitRawOutputSpoolResourcePolicy()

    let maximumSpoolByteCount: UInt64
    let maximumWriteChunkByteCount: Int
    let readChunkByteCount: Int
    let minimumFreeDiskBytes: UInt64
    let activityTimeout: Duration

    init(
        maximumSpoolByteCount: UInt64 = 4 * 1024 * 1024 * 1024,
        maximumWriteChunkByteCount: Int = 64 * 1024,
        readChunkByteCount: Int = 64 * 1024,
        minimumFreeDiskBytes: UInt64 = 256 * 1024 * 1024,
        activityTimeout: Duration = .seconds(30)
    ) {
        self.maximumSpoolByteCount = maximumSpoolByteCount
        self.maximumWriteChunkByteCount = maximumWriteChunkByteCount
        self.readChunkByteCount = readChunkByteCount
        self.minimumFreeDiskBytes = minimumFreeDiskBytes
        self.activityTimeout = activityTimeout
    }

    var isValid: Bool {
        maximumSpoolByteCount > 0 && maximumWriteChunkByteCount > 0 &&
            readChunkByteCount > 0 && readChunkByteCount <= 1024 * 1024 &&
            activityTimeout > .zero
    }
}

private struct GitRawOutputSpoolDescriptorIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let byteCount: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64
}

/// Secure, ephemeral storage for one Git command's stdout. Writes are synchronous
/// so the pipe callback applies disk backpressure instead of building an
/// unbounded in-memory stream. The byte ceiling is resource admission, not a
/// correctness/cardinality limit: exceeding it produces a typed resource error.
final class GitRawOutputSpool: @unchecked Sendable {
    let directoryURL: URL
    let fileURL: URL
    let resourcePolicy: GitRawOutputSpoolResourcePolicy

    private let lock = NSLock()
    private var descriptor: Int32
    private var byteCount: UInt64 = 0
    private var terminalError: GitRawOutputSpoolError?
    private var isClosed = false
    private var leaseTransferred = false

    init(
        directoryURL: URL? = nil,
        resourcePolicy: GitRawOutputSpoolResourcePolicy = .default
    ) throws {
        guard resourcePolicy.isValid else {
            throw GitRawOutputSpoolError.invalidConfiguration
        }
        self.resourcePolicy = resourcePolicy
        let chosenDirectory = directoryURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "repoprompt-git-raw-spool-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        self.directoryURL = chosenDirectory
        fileURL = chosenDirectory.appendingPathComponent("stdout.raw", isDirectory: false)
        descriptor = -1

        do {
            try Self.createSecureDirectory(chosenDirectory)
            try Self.admitDisk(at: chosenDirectory, policy: resourcePolicy)
            let opened = Darwin.open(
                fileURL.path,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            guard opened >= 0 else {
                throw GitRawOutputSpoolError.io(operation: "spool-open", code: errno)
            }
            descriptor = opened
            try Self.validateSecureRegularFile(opened)
        } catch {
            if descriptor >= 0 {
                _ = Darwin.close(descriptor)
                descriptor = -1
            }
            try? FileManager.default.removeItem(at: chosenDirectory)
            throw error
        }
    }

    deinit {
        if !leaseTransferred {
            cancel()
        }
    }

    /// Appends one bounded pipe chunk. Safe to call from Foundation readability
    /// callbacks; no Swift concurrency hop or aggregate buffering is involved.
    func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if let terminalError { throw terminalError }
        guard !isClosed, descriptor >= 0 else { throw GitRawOutputSpoolError.closed }
        guard data.count <= resourcePolicy.maximumWriteChunkByteCount else {
            try failLocked(.resourceAdmission)
        }
        guard let incoming = UInt64(exactly: data.count) else {
            try failLocked(.resourceAdmission)
        }
        let (proposed, overflowed) = byteCount.addingReportingOverflow(incoming)
        guard !overflowed, proposed <= resourcePolicy.maximumSpoolByteCount else {
            try failLocked(.resourceAdmission)
        }
        do {
            try Self.admitDisk(at: directoryURL, policy: resourcePolicy)
            try Self.writeAll(data, to: descriptor)
            byteCount = proposed
        } catch let error as GitRawOutputSpoolError {
            try failLocked(error)
        } catch {
            try failLocked(.io(operation: "spool-write", code: EIO))
        }
    }

    func finish() throws -> GitRawOutputSpoolLease {
        lock.lock()
        defer { lock.unlock() }
        if let terminalError { throw terminalError }
        guard !isClosed, descriptor >= 0 else { throw GitRawOutputSpoolError.closed }
        guard fsync(descriptor) == 0 else {
            try failLocked(.io(operation: "spool-fsync", code: errno))
        }
        let identity = try Self.descriptorIdentity(descriptor)
        guard identity.byteCount == byteCount else {
            try failLocked(.corrupt("spool byte count mismatch"))
        }
        let ownedDescriptor = descriptor
        descriptor = -1
        isClosed = true
        leaseTransferred = true
        return GitRawOutputSpoolLease(
            directoryURL: directoryURL,
            fileURL: fileURL,
            descriptor: ownedDescriptor,
            identity: identity,
            byteCount: byteCount,
            readChunkByteCount: resourcePolicy.readChunkByteCount
        )
    }

    func cancel() {
        lock.lock()
        guard !leaseTransferred else {
            lock.unlock()
            return
        }
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
            descriptor = -1
        }
        isClosed = true
        lock.unlock()
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func failLocked(_ error: GitRawOutputSpoolError) throws -> Never {
        terminalError = error
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
            descriptor = -1
        }
        isClosed = true
        try? FileManager.default.removeItem(at: directoryURL)
        throw error
    }

    fileprivate static func validateSecureRegularFile(_ descriptor: Int32) throws {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            throw GitRawOutputSpoolError.io(operation: "spool-fstat", code: errno)
        }
        guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              value.st_uid == getuid(),
              value.st_mode & 0o077 == 0
        else {
            throw GitRawOutputSpoolError.corrupt("insecure spool file")
        }
    }

    fileprivate static func descriptorIdentity(
        _ descriptor: Int32
    ) throws -> GitRawOutputSpoolDescriptorIdentity {
        try validateSecureRegularFile(descriptor)
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            throw GitRawOutputSpoolError.io(operation: "spool-identity", code: errno)
        }
        guard value.st_size >= 0 else {
            throw GitRawOutputSpoolError.corrupt("negative spool size")
        }
        return GitRawOutputSpoolDescriptorIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            byteCount: UInt64(value.st_size),
            modificationSeconds: Int64(value.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(value.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(value.st_ctimespec.tv_nsec)
        )
    }

    fileprivate static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return -1 }
                return Darwin.write(descriptor, baseAddress.advanced(by: offset), data.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                throw GitRawOutputSpoolError.io(operation: "spool-write", code: errno)
            }
        }
    }

    private static func createSecureDirectory(_ url: URL) throws {
        guard mkdir(url.path, S_IRWXU) == 0 else {
            throw GitRawOutputSpoolError.io(operation: "spool-mkdir", code: errno)
        }
        var value = stat()
        guard lstat(url.path, &value) == 0,
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              value.st_uid == getuid(),
              value.st_mode & 0o077 == 0
        else {
            throw GitRawOutputSpoolError.corrupt("insecure spool directory")
        }
    }

    private static func admitDisk(
        at directoryURL: URL,
        policy: GitRawOutputSpoolResourcePolicy
    ) throws {
        var value = statfs()
        guard statfs(directoryURL.path, &value) == 0 else {
            throw GitRawOutputSpoolError.io(operation: "spool-statfs", code: errno)
        }
        guard value.f_bsize > 0, value.f_bavail >= 0 else {
            throw GitRawOutputSpoolError.resourceAdmission
        }
        let blockSize = UInt64(value.f_bsize)
        let availableBlocks = UInt64(value.f_bavail)
        let (availableBytes, overflowed) = blockSize.multipliedReportingOverflow(by: availableBlocks)
        guard !overflowed, availableBytes >= policy.minimumFreeDiskBytes else {
            throw GitRawOutputSpoolError.resourceAdmission
        }
    }
}

final class GitRawOutputSpoolLease: @unchecked Sendable {
    let fileURL: URL
    let byteCount: UInt64

    private let directoryURL: URL
    private let descriptor: Int32
    private let identity: GitRawOutputSpoolDescriptorIdentity
    private let readChunkByteCount: Int

    fileprivate init(
        directoryURL: URL,
        fileURL: URL,
        descriptor: Int32,
        identity: GitRawOutputSpoolDescriptorIdentity,
        byteCount: UInt64,
        readChunkByteCount: Int
    ) {
        self.directoryURL = directoryURL
        self.fileURL = fileURL
        self.descriptor = descriptor
        self.identity = identity
        self.byteCount = byteCount
        self.readChunkByteCount = readChunkByteCount
    }

    deinit {
        _ = Darwin.close(descriptor)
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func makeReader() throws -> GitRawOutputSpoolReader {
        try validateIdentity()
        let readerDescriptor = Darwin.open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard readerDescriptor >= 0 else {
            throw GitRawOutputSpoolError.io(operation: "spool-reader-open", code: errno)
        }
        do {
            guard try GitRawOutputSpool.descriptorIdentity(readerDescriptor) == identity else {
                throw GitRawOutputSpoolError.corrupt("spool reader identity mismatch")
            }
        } catch {
            _ = Darwin.close(readerDescriptor)
            throw error
        }
        return GitRawOutputSpoolReader(
            descriptor: readerDescriptor,
            lease: self,
            expectedByteCount: byteCount,
            readChunkByteCount: readChunkByteCount
        )
    }

    /// Hashes the exact descriptor-bound raw stream without materializing it.
    /// A separate reader may subsequently parse the same leased artifact.
    func sha256Digest() throws -> Data {
        let reader = try makeReader()
        var digest = SHA256()
        while let chunk = try reader.nextChunk() {
            digest.update(data: chunk)
        }
        return Data(digest.finalize())
    }

    fileprivate func validateIdentity() throws {
        let current = try GitRawOutputSpool.descriptorIdentity(descriptor)
        guard current == identity else {
            throw GitRawOutputSpoolError.corrupt("spool descriptor identity changed")
        }
        var pathValue = stat()
        guard lstat(fileURL.path, &pathValue) == 0,
              UInt64(pathValue.st_dev) == identity.device,
              UInt64(pathValue.st_ino) == identity.inode,
              pathValue.st_size >= 0,
              UInt64(pathValue.st_size) == identity.byteCount
        else {
            throw GitRawOutputSpoolError.corrupt("spool path identity changed")
        }
    }
}

final class GitRawOutputSpoolReader: @unchecked Sendable {
    private let descriptor: Int32
    private let lease: GitRawOutputSpoolLease
    private let expectedByteCount: UInt64
    private let readChunkByteCount: Int
    private var consumedByteCount: UInt64 = 0
    private var reachedEnd = false

    fileprivate init(
        descriptor: Int32,
        lease: GitRawOutputSpoolLease,
        expectedByteCount: UInt64,
        readChunkByteCount: Int
    ) {
        self.descriptor = descriptor
        self.lease = lease
        self.expectedByteCount = expectedByteCount
        self.readChunkByteCount = readChunkByteCount
    }

    deinit {
        _ = Darwin.close(descriptor)
    }

    func nextChunk() throws -> Data? {
        guard !reachedEnd else { return nil }
        try Task.checkCancellation()
        try lease.validateIdentity()
        var buffer = Data(count: readChunkByteCount)
        let amount = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if amount > 0 {
            buffer.removeSubrange(amount ..< buffer.count)
            guard let increment = UInt64(exactly: amount) else {
                throw GitRawOutputSpoolError.corrupt("spool read count overflow")
            }
            let (total, overflowed) = consumedByteCount.addingReportingOverflow(increment)
            guard !overflowed, total <= expectedByteCount else {
                throw GitRawOutputSpoolError.corrupt("spool read exceeds published size")
            }
            consumedByteCount = total
            return buffer
        }
        if amount < 0, errno == EINTR {
            return try nextChunk()
        }
        guard amount == 0, consumedByteCount == expectedByteCount else {
            throw GitRawOutputSpoolError.corrupt("truncated raw spool")
        }
        try lease.validateIdentity()
        reachedEnd = true
        return nil
    }
}

/// Serializes pipe callbacks and writes each bounded read directly to a raw
/// spool. It deliberately has no AsyncStream: an unbounded continuation would
/// merely move aggregate stdout into memory while the disk writer catches up.
final class GitProcessPipeSpoolDrain: @unchecked Sendable {
    private enum ReadResult {
        case data(Data)
        case unavailable
        case terminal
        case failed(GitRawOutputSpoolError)
    }

    private let lock = NSLock()
    private let spool: GitRawOutputSpool
    private let activityHandler: @Sendable () -> Void
    private var ownedDescriptor: Int32?
    private var isFinished = false
    private var storedError: GitRawOutputSpoolError?

    private init(
        descriptor: Int32,
        spool: GitRawOutputSpool,
        activityHandler: @escaping @Sendable () -> Void
    ) {
        ownedDescriptor = descriptor
        self.spool = spool
        self.activityHandler = activityHandler
    }

    deinit {
        if let ownedDescriptor {
            _ = Darwin.close(ownedDescriptor)
        }
    }

    static func make(
        readingFrom handle: FileHandle,
        spool: GitRawOutputSpool,
        activityHandler: @escaping @Sendable () -> Void
    ) throws -> GitProcessPipeSpoolDrain {
        let descriptor = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else {
            throw GitRawOutputSpoolError.io(operation: "spool-pipe-dup", code: errno)
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            let failure = errno
            _ = Darwin.close(descriptor)
            throw GitRawOutputSpoolError.io(operation: "spool-pipe-nonblock", code: failure)
        }
        return GitProcessPipeSpoolDrain(
            descriptor: descriptor,
            spool: spool,
            activityHandler: activityHandler
        )
    }

    var terminalError: GitRawOutputSpoolError? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    /// Returns true when Foundation should stop monitoring readability.
    @discardableResult
    func consumeAvailableData() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished, let descriptor = ownedDescriptor else { return true }
        switch readChunk(from: descriptor) {
        case let .data(data):
            if storedError != nil {
                // Keep draining after a spool failure until the subprocess exits;
                // otherwise a child flushing while handling SIGTERM can fill the
                // pipe and prevent its own termination.
                return false
            }
            do {
                try spool.append(data)
                activityHandler()
                return false
            } catch let error as GitRawOutputSpoolError {
                failLocked(error)
                return false
            } catch {
                failLocked(.io(operation: "spool-pipe-append", code: EIO))
                return false
            }
        case .unavailable:
            return false
        case .terminal:
            finishLocked()
            return true
        case let .failed(error):
            failLocked(error)
            return true
        }
    }

    func finishReading() {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished, let descriptor = ownedDescriptor else { return }
        while true {
            switch readChunk(from: descriptor) {
            case let .data(data):
                if storedError != nil {
                    continue
                }
                do {
                    try spool.append(data)
                    activityHandler()
                } catch let error as GitRawOutputSpoolError {
                    failLocked(error)
                    return
                } catch {
                    failLocked(.io(operation: "spool-pipe-append", code: EIO))
                    return
                }
            case .unavailable, .terminal:
                finishLocked()
                return
            case let .failed(error):
                failLocked(error)
                return
            }
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        finishLocked()
    }

    private func readChunk(from descriptor: Int32) -> ReadResult {
        var bytes = [UInt8](repeating: 0, count: spool.resourcePolicy.maximumWriteChunkByteCount)
        while true {
            let amount = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            }
            if amount > 0 { return .data(Data(bytes.prefix(amount))) }
            if amount == 0 { return .terminal }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return .unavailable }
            return .failed(.io(operation: "spool-pipe-read", code: errno))
        }
    }

    private func failLocked(_ error: GitRawOutputSpoolError) {
        if storedError == nil {
            storedError = error
        }
        spool.cancel()
    }

    private func finishLocked() {
        guard !isFinished else { return }
        isFinished = true
        if let ownedDescriptor {
            self.ownedDescriptor = nil
            _ = Darwin.close(ownedDescriptor)
        }
    }
}
