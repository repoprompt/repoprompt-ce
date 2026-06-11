import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Best-effort raw file-descriptor writer for small MCP diagnostic messages.
///
/// This is intentionally for stderr-style diagnostics only, not protocol payload
/// delivery. It serializes writes so diagnostic lines do not interleave, retries a
/// bounded number of `EINTR` failures, and drops the remaining data on any other
/// write failure or closed descriptor.
public enum MCPBestEffortRawFDWriter {
    typealias RawWrite = (Int32, UnsafeRawPointer?, Int) -> Int

    // Keep the lock around the whole small diagnostic write to preserve line
    // ordering. Callers should use protocol-specific writers for large payloads.
    private static let lock = NSLock()
    private static let maxConsecutiveInterrupts = 16

    /// Writes diagnostic data to stderr on a best-effort basis.
    ///
    /// The call never throws. If stderr is unavailable or a write fails, remaining
    /// bytes are dropped after bounded `EINTR` retries.
    public static func write(_ data: Data) {
        write(data, to: STDERR_FILENO)
    }

    /// Writes diagnostic data to the supplied file descriptor on a best-effort basis.
    ///
    /// This is intended for small diagnostic stderr-style output. Partial writes are
    /// completed when possible; closed or failing descriptors drop remaining bytes.
    public static func write(_ data: Data, to fd: Int32) {
        write(data, to: fd, rawWrite: platformWrite)
    }

    static func write(
        _ data: Data,
        to fd: Int32,
        rawWrite: RawWrite
    ) {
        guard fd >= 0, !data.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        configureNoSigPipeIfAvailable(fd)

        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }

            var offset = 0
            var consecutiveInterrupts = 0

            while offset < data.count {
                let written = rawWrite(
                    fd,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )

                if written > 0 {
                    offset += written
                    consecutiveInterrupts = 0
                    continue
                }

                if written == 0 {
                    return
                }

                let err = errno
                if err == EINTR, consecutiveInterrupts < maxConsecutiveInterrupts {
                    consecutiveInterrupts += 1
                    continue
                }

                return
            }
        }
    }

    private static func platformWrite(_ fd: Int32, _ pointer: UnsafeRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
            Darwin.write(fd, pointer, count)
        #elseif canImport(Glibc)
            Glibc.write(fd, pointer, count)
        #else
            -1
        #endif
    }

    private static func configureNoSigPipeIfAvailable(_ fd: Int32) {
        #if canImport(Darwin)
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        #else
            _ = fd
        #endif
    }
}
