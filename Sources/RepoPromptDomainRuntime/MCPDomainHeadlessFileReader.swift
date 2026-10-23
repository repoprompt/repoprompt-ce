import Darwin
import Foundation

/// Bounded physical reads for standalone hosts. Permits stay owned by the worker until it
/// settles; cancellation never frees capacity while a filesystem call is still running.
package enum MCPDomainHeadlessFileReader {
    package static let maximumBytes = 10_000_000
    private static let workers = MCPDomainToolResourceAdmissionController(
        limit: MCPDomainToolAdmissionLimits.fileReadPerWindow
    )

    package enum ReadError: Error, Equatable, CustomStringConvertible {
        case tooLarge
        case notRegularFile
        case invalidText
        case changedDuringRead
        case unsafeAdmissionDirectory

        package var description: String {
            switch self {
            case .tooLarge: "File exceeds the headless read_file limit of 10,000,000 bytes"
            case .notRegularFile: "read_file requires a regular file"
            case .invalidText: "File is binary or is not valid UTF-8 text"
            case .changedDuringRead: "File changed during read; retry against the current file"
            case .unsafeAdmissionDirectory: "Unable to safely acquire shared headless file-read admission"
            }
        }
    }

    package static func read(
        at url: URL,
        startLine: Int?,
        limit: Int?,
        chunkSize: Int = 65536,
        slotDirectory: URL? = nil,
        slotCount: Int = MCPDomainToolAdmissionLimits.fileReadPerWindow,
        didReadChunk: @escaping @Sendable (Int) -> Void = { _ in },
        didWaitForSlot: @escaping @Sendable () -> Void = {}
    ) async throws -> String {
        let path = try physicalPath(url)
        let lease = try await workers.acquire(.appWide)
        defer { lease.release() }
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            let result: String = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try cancellation.check()
                        let slot = try acquireSlot(
                            in: slotDirectory ?? defaultSlotDirectory(), count: slotCount, cancellation: cancellation,
                            didWait: didWaitForSlot
                        )
                        defer { close(slot) }
                        return try readBlocking(
                            path: path, startLine: startLine, limit: limit, chunkSize: chunkSize,
                            cancellation: cancellation, didReadChunk: didReadChunk
                        )
                    })
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func defaultSlotDirectory() throws -> URL {
        // Unlike TMPDIR, confstr is not a caller-controlled namespace. The OS owns this
        // private per-user parent, so another UID cannot squat on the shared directory.
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 1 else { throw ReadError.unsafeAdmissionDirectory }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) == length else {
            throw ReadError.unsafeAdmissionDirectory
        }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
            .resolvingSymlinksInPath().appendingPathComponent("repoprompt-ce-headless-file-reads", isDirectory: true)
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.withLock { cancelled = true }
        }

        func check() throws {
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }
    }

    /// Lock files are never unlinked: unlinking permits a second inode to become a parallel
    /// authority. CLOEXEC and kernel close-on-exit release slots on teardown/crash as well.
    private static func acquireSlot(
        in directory: URL, count: Int, cancellation: Cancellation, didWait: @Sendable () -> Void
    ) throws -> Int32 {
        precondition(count > 0)
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw ReadError.unsafeAdmissionDirectory }
        defer { close(directoryFD) }
        var metadata = stat()
        guard fstat(directoryFD, &metadata) == 0,
              metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0
        else { throw ReadError.unsafeAdmissionDirectory }
        while true {
            try cancellation.check()
            for index in 0 ..< count {
                let fd = openat(directoryFD, "slot-\(index)", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
                guard fd >= 0 else { throw ReadError.unsafeAdmissionDirectory }
                var slotMetadata = stat()
                guard fstat(fd, &slotMetadata) == 0,
                      slotMetadata.st_mode & S_IFMT == S_IFREG,
                      slotMetadata.st_uid == getuid(), slotMetadata.st_mode & 0o077 == 0,
                      slotMetadata.st_nlink == 1
                else {
                    close(fd)
                    throw ReadError.unsafeAdmissionDirectory
                }
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
                let lockError = errno
                close(fd)
                guard lockError == EWOULDBLOCK || lockError == EAGAIN else {
                    throw POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO)
                }
            }
            didWait()
            // Only bounded worker threads wait here, not the Swift cooperative pool.
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private static func readBlocking(
        path: String, startLine: Int?, limit: Int?, chunkSize: Int,
        cancellation: Cancellation, didReadChunk: @Sendable (Int) -> Void
    ) throws -> String {
        precondition(chunkSize > 0)
        let fd = try openWithoutSymlinks(path)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw ReadError.changedDuringRead }
        guard before.st_mode & S_IFMT == S_IFREG else { throw ReadError.notRegularFile }
        guard before.st_size <= maximumBytes else { throw ReadError.tooLarge }
        var selection = Lines(startLine: startLine, limit: limit)
        var line = Data()
        var bytesRead = 0
        var finished = selection.isComplete
        while !finished {
            try cancellation.check()
            let chunk = try handle.read(upToCount: min(chunkSize, maximumBytes - bytesRead + 1)) ?? Data()
            bytesRead += chunk.count
            guard bytesRead <= maximumBytes else { throw ReadError.tooLarge }
            didReadChunk(bytesRead)
            try cancellation.check()
            if chunk.isEmpty {
                try selection.append(line, hasDelimiter: false)
                break
            }
            for byte in chunk {
                guard byte != 0 else { throw ReadError.invalidText }
                line.append(byte)
                let delimiterBytes: Int
                if byte == 10 || byte == 11 || byte == 12 || byte == 13 {
                    delimiterBytes = 1
                } else if byte == 0x85, line.suffix(2).elementsEqual([0xC2, 0x85]) {
                    delimiterBytes = 2
                } else if byte == 0xA8 || byte == 0xA9,
                          line.suffix(3).elementsEqual([0xE2, 0x80, 0xA8])
                          || line.suffix(3).elementsEqual([0xE2, 0x80, 0xA9])
                {
                    delimiterBytes = 3
                } else {
                    continue
                }
                line.removeLast(delimiterBytes)
                try selection.append(line, hasDelimiter: true)
                line.removeAll(keepingCapacity: true)
                if selection.isComplete { finished = true
                    break
                }
            }
        }
        try cancellation.check()
        var after = stat()
        var pathMetadata = stat()
        guard fstat(fd, &after) == 0, stat(path, &pathMetadata) == 0,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              before.st_ino == pathMetadata.st_ino, before.st_dev == pathMetadata.st_dev
        else { throw ReadError.changedDuringRead }
        return selection.result
    }

    /// Foundation can spell canonical /private/var and /private/tmp URLs using their
    /// root-owned aliases. Resolve only that trusted top-level alias before admission;
    /// never resolve user-controlled parent components after the authorization boundary.
    private static func physicalPath(_ url: URL) throws -> String {
        let path = url.path
        guard let first = path.split(separator: "/").first else { return path }
        let anchor = "/" + first
        var metadata = stat()
        guard lstat(anchor, &metadata) == 0 else { throw POSIXError(.ENOENT) }
        guard metadata.st_mode & S_IFMT == S_IFLNK, metadata.st_uid == 0 else { return path }
        guard let resolved = realpath(anchor, nil) else { throw POSIXError(.EIO) }
        defer { free(resolved) }
        return String(cString: resolved) + path.dropFirst(anchor.count)
    }

    /// The resolver returns a canonical authorized path. Walk it from a trusted descriptor
    /// without following any new symlink, including parent components replaced during admission.
    private static func openWithoutSymlinks(_ path: String) throws -> Int32 {
        let parts = path.split(separator: "/").map(String.init)
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw POSIXError(.EIO) }
        defer { close(directory) }
        for (index, part) in parts.enumerated() {
            let isLeaf = index == parts.count - 1
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (isLeaf ? 0 : O_DIRECTORY)
            let next = openat(directory, part, flags)
            guard next >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO, userInfo: [NSFilePathErrorKey: path, "component": part])
            }
            if isLeaf { return next }
            close(directory)
            directory = next
        }
        throw ReadError.notRegularFile
    }

    /// Normalize into bytes, not one String per line (newline-heavy inputs would amplify
    /// memory). Tails scan the bounded normalized buffer backward with constant extra storage.
    private struct Lines {
        let firstIndex: Int
        let count: Int?
        let tailCount: Int?
        var index = 0
        var retained = Data()
        var selectedLineCount = 0

        init(startLine: Int?, limit: Int?) {
            if let startLine, startLine < 0 {
                firstIndex = 0
                count = nil
                tailCount = Int(min(startLine.magnitude, UInt(maximumBytes + 1)))
            } else {
                firstIndex = startLine.map { max(0, $0 - 1) } ?? 0
                count = startLine == nil ? nil : limit.map { max(0, $0) }
                tailCount = nil
            }
        }

        var isComplete: Bool {
            count.map { selectedLineCount >= $0 } ?? false
        }

        mutating func append(_ data: Data, hasDelimiter: Bool) throws {
            guard String(data: data, encoding: .utf8) != nil else { throw ReadError.invalidText }
            defer { index += 1 }
            guard index >= firstIndex else { return }
            // Foundation's whole-file UTF-8 decoder consumes a BOM only at file offset zero.
            // Keep interior U+FEFF even when line slicing makes it the first output scalar.
            if index == 0, data.starts(with: [0xEF, 0xBB, 0xBF]) {
                retained.append(contentsOf: data.dropFirst(3))
            } else {
                retained.append(data)
            }
            selectedLineCount += 1
            if hasDelimiter, !isComplete { retained.append(10) }
        }

        var result: String {
            var start = retained.startIndex
            if let tailCount {
                var remaining = tailCount
                for index in retained.indices.reversed() where retained[index] == 10 {
                    remaining -= 1
                    if remaining == 0 {
                        start = retained.index(after: index)
                        break
                    }
                }
            }
            return String(decoding: retained[start...], as: UTF8.self)
        }
    }
}
