import Darwin
import Darwin.POSIX.fcntl

package enum POSIXDescriptorConfigurationError: Error, Equatable {
    case invalidFileDescriptor(fd: Int32)
    case getDescriptorFlagsFailed(fd: Int32, errno: Int32)
    case setDescriptorFlagsFailed(fd: Int32, errno: Int32)

    package var errnoValue: Int32 {
        switch self {
        case .invalidFileDescriptor:
            EBADF
        case let .getDescriptorFlagsFailed(_, errno), let .setDescriptorFlagsFailed(_, errno):
            errno
        }
    }
}

package enum POSIXDescriptorSupport {
    package static func setCloseOnExec(_ fd: Int32) throws {
        guard fd >= 0 else {
            throw POSIXDescriptorConfigurationError.invalidFileDescriptor(fd: fd)
        }

        let flags = fcntl(fd, F_GETFD)
        guard flags != -1 else {
            throw POSIXDescriptorConfigurationError.getDescriptorFlagsFailed(fd: fd, errno: errno)
        }

        guard fcntl(fd, F_SETFD, flags | FD_CLOEXEC) != -1 else {
            throw POSIXDescriptorConfigurationError.setDescriptorFlagsFailed(fd: fd, errno: errno)
        }
    }

    package static func shutdownSocketReadWrite(_ fd: Int32) {
        guard fd >= 0 else { return }
        _ = shutdown(fd, SHUT_RDWR)
    }
}
