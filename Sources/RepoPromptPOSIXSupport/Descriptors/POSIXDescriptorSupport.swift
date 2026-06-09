import Darwin
import Darwin.POSIX.fcntl
import RepoPromptC

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

package enum POSIXDescriptorPathError: Error, Equatable {
    case invalidFileDescriptor(fd: Int32)
    case getPathFailed(fd: Int32, errno: Int32)

    package var errnoValue: Int32 {
        switch self {
        case .invalidFileDescriptor:
            EBADF
        case let .getPathFailed(_, errno):
            errno
        }
    }
}

package enum POSIXDescriptorSupport {
    package static func path(for fd: Int32) throws -> String {
        guard fd >= 0 else {
            throw POSIXDescriptorPathError.invalidFileDescriptor(fd: fd)
        }

        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let baseAddress = pointer.baseAddress else {
                errno = EINVAL
                return -1
            }
            return RepoPromptC.repo_prompt_descriptor_get_path(fd, baseAddress)
        }
        guard result == 0 else {
            throw POSIXDescriptorPathError.getPathFailed(fd: fd, errno: errno)
        }
        return String(cString: buffer)
    }

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
