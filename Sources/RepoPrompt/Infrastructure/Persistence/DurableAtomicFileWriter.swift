import Darwin
import Foundation

/// Crash-safe replacement of a small state file: write a sibling temp file, flush it to stable
/// storage (`F_FULLFSYNC`, falling back to `fsync`), atomically `rename` it over the destination, then
/// flush the directory entry. A process kill or power loss leaves either the old or the new bytes,
/// never a torn file, and a write that returned has reached the disk.
enum DurableAtomicFileWriter {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o644))
        guard descriptor >= 0 else { throw posixError() }
        var renamed = false
        defer { if !renamed { _ = Darwin.unlink(temporary.path) } }
        do {
            try writeAll(data, to: descriptor)
            try flush(descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else { throw posixError() }
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw posixError() }
        renamed = true
        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        if directoryDescriptor >= 0 {
            _ = Darwin.fsync(directoryDescriptor)
            Darwin.close(directoryDescriptor)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                offset += written
            }
        }
    }

    private static func flush(_ descriptor: Int32) throws {
        if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
