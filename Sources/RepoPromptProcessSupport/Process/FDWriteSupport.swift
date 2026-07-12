import Darwin
import Darwin.POSIX.fcntl
import Foundation

package enum FDWriteError: Error, Equatable {
    case brokenPipe(errno: Int32)
    case badDescriptor(errno: Int32)
    case system(errno: Int32)

    package var errnoValue: Int32 {
        switch self {
        case let .brokenPipe(errno), let .badDescriptor(errno), let .system(errno):
            errno
        }
    }
}

package enum FDWriteSupport {
    @discardableResult
    package static func configureNoSigPipe(fd: Int32) -> Bool {
        guard fd >= 0 else { return false }
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
            return fcntl(fd, F_SETNOSIGPIPE, 1) != -1
        #else
            return true
        #endif
    }

    package static func writeAll(_ data: Data, to fd: Int32) throws {
        guard fd >= 0 else {
            throw FDWriteError.badDescriptor(errno: EBADF)
        }
        guard !data.isEmpty else { return }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }

            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written == 0 {
                    throw FDWriteError.brokenPipe(errno: EPIPE)
                }

                let currentErrno = errno
                switch currentErrno {
                case EINTR:
                    continue
                case EPIPE:
                    throw FDWriteError.brokenPipe(errno: currentErrno)
                case EBADF:
                    throw FDWriteError.badDescriptor(errno: currentErrno)
                default:
                    throw FDWriteError.system(errno: currentErrno)
                }
            }
        }
    }
}
