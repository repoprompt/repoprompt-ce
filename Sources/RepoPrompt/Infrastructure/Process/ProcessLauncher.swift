import Foundation
import RepoPromptCore
import RepoPromptCoreMacOS
import RepoPromptPOSIXSupport

enum ProcessLauncherError: Error {
    case pipeCreationFailed(String)
    case descriptorConfigurationFailed(
        label: String,
        fd: Int32,
        underlying: POSIXDescriptorConfigurationError
    )
    case spawnFileActionsFailed(operation: String, errno: Int32)
    case changeDirectoryFailed(path: String, errno: Int32)
    case spawnAttributesFailed(operation: String, errno: Int32)
    case spawnFailed(errno: Int32)
}

enum ProcessLauncher {
    static func spawn(
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?
    ) throws -> SpawnedProcess {
        do {
            return try POSIXProcessLauncher().spawn(
                command: command,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory
            )
        } catch let error as ProcessLaunchError {
            throw map(error)
        }
    }

    #if DEBUG
        enum DebugInitializationFailure {
            case fileActions(errno: Int32)
            case attributes(errno: Int32)
        }

        static func debugSpawn(
            command: String,
            arguments: [String],
            environment: [String: String],
            workingDirectory: String?,
            initializationFailure: DebugInitializationFailure
        ) throws -> SpawnedProcess {
            let platformFailure: RepoPromptCoreMacOS.ProcessLauncher.DebugInitializationFailure =
                switch initializationFailure {
                case let .fileActions(errno): .fileActions(errno: errno)
                case let .attributes(errno): .attributes(errno: errno)
                }
            do {
                return try RepoPromptCoreMacOS.ProcessLauncher.debugSpawn(
                    command: command,
                    arguments: arguments,
                    environment: environment,
                    workingDirectory: workingDirectory,
                    initializationFailure: platformFailure
                )
            } catch let error as ProcessLaunchError {
                throw map(error)
            }
        }
    #endif

    private static func map(_ error: ProcessLaunchError) -> ProcessLauncherError {
        switch error {
        case let .pipeCreationFailed(label):
            return .pipeCreationFailed(label)
        case let .descriptorConfigurationFailed(stage, label, fd, errorNumber):
            let underlying: POSIXDescriptorConfigurationError = switch stage {
            case .invalidDescriptor: .invalidFileDescriptor(fd: fd)
            case .getDescriptorFlags: .getDescriptorFlagsFailed(fd: fd, errno: errorNumber)
            case .setDescriptorFlags: .setDescriptorFlagsFailed(fd: fd, errno: errorNumber)
            }
            return .descriptorConfigurationFailed(
                label: label,
                fd: fd,
                underlying: underlying
            )
        case let .spawnFileActionsFailed(operation, errorNumber):
            return .spawnFileActionsFailed(operation: operation, errno: errorNumber)
        case let .changeDirectoryFailed(path, errorNumber):
            return .changeDirectoryFailed(path: path, errno: errorNumber)
        case let .spawnAttributesFailed(operation, errorNumber):
            return .spawnAttributesFailed(operation: operation, errno: errorNumber)
        case let .spawnFailed(errorNumber):
            return .spawnFailed(errno: errorNumber)
        }
    }
}
