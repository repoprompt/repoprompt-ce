import Darwin
import Foundation

public enum MCPBestEffortRawFDWriter {
    typealias RawWrite = (Int32, UnsafeRawPointer?, Int) -> Int

    private static let lock = NSLock()
    private static let maxConsecutiveInterrupts = 16

    public static func write(_ data: Data) {
        write(data, to: STDERR_FILENO)
    }

    public static func write(_ data: Data, to fd: Int32) {
        write(data, to: fd, rawWrite: Darwin.write)
    }

    static func write(
        _ data: Data,
        to fd: Int32,
        rawWrite: RawWrite
    ) {
        guard fd >= 0, !data.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        _ = fcntl(fd, F_SETNOSIGPIPE, 1)

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
}
