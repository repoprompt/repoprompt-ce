import Darwin
import Foundation
import RepoPromptPOSIXSupport

package enum PlatformDescriptorConfigurationError: Error, Equatable {
    case invalidFileDescriptor(fd: Int32)
    case getDescriptorFlagsFailed(fd: Int32, errno: Int32)
    case setDescriptorFlagsFailed(fd: Int32, errno: Int32)

    package var errnoValue: Int32 {
        switch self {
        case .invalidFileDescriptor: EBADF
        case let .getDescriptorFlagsFailed(_, value), let .setDescriptorFlagsFailed(_, value): value
        }
    }
}

package enum PlatformDescriptorPolicy {
    package static func setCloseOnExec(_ fd: Int32) throws {
        do {
            try RepoPromptPOSIXSupport.POSIXDescriptorSupport.setCloseOnExec(fd)
        } catch let error as RepoPromptPOSIXSupport.POSIXDescriptorConfigurationError {
            switch error {
            case let .invalidFileDescriptor(fd):
                throw PlatformDescriptorConfigurationError.invalidFileDescriptor(fd: fd)
            case let .getDescriptorFlagsFailed(fd, errorNumber):
                throw PlatformDescriptorConfigurationError.getDescriptorFlagsFailed(fd: fd, errno: errorNumber)
            case let .setDescriptorFlagsFailed(fd, errorNumber):
                throw PlatformDescriptorConfigurationError.setDescriptorFlagsFailed(fd: fd, errno: errorNumber)
            }
        }
    }

    package static func shutdownSocketReadWrite(_ fd: Int32) {
        RepoPromptPOSIXSupport.POSIXDescriptorSupport.shutdownSocketReadWrite(fd)
    }
}

package enum PlatformFDWriteError: Error, Equatable {
    case brokenPipe(errno: Int32)
    case badDescriptor(errno: Int32)
    case system(errno: Int32)

    package var errnoValue: Int32 {
        switch self {
        case let .brokenPipe(value), let .badDescriptor(value), let .system(value): value
        }
    }
}

package enum PlatformFDWriter {
    @discardableResult
    package static func configureNoSigPipe(fd: Int32) -> Bool {
        RepoPromptPOSIXSupport.FDWriteSupport.configureNoSigPipe(fd: fd)
    }

    package static func writeAll(_ data: Data, to fd: Int32) throws {
        do {
            try RepoPromptPOSIXSupport.FDWriteSupport.writeAll(data, to: fd)
        } catch let error as RepoPromptPOSIXSupport.FDWriteError {
            switch error {
            case let .brokenPipe(errorNumber):
                throw PlatformFDWriteError.brokenPipe(errno: errorNumber)
            case let .badDescriptor(errorNumber):
                throw PlatformFDWriteError.badDescriptor(errno: errorNumber)
            case let .system(errorNumber):
                throw PlatformFDWriteError.system(errno: errorNumber)
            }
        }
    }
}
