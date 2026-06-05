import Foundation
import RepoPromptShared

/// Platform-neutral description of a spawned child process.
struct SpawnedProcess: @unchecked Sendable {
    let pid: Int32
    let stdin: FileHandle?
    let stdinDescriptor: Int32?
    let stdout: FileHandle
    let stderr: FileHandle
}

enum ProcessLauncherError: Error {
    case pipeCreationFailed(String)
    case descriptorConfigurationFailed(label: String, fd: Int32, underlying: POSIXDescriptorConfigurationError)
    case spawnFileActionsFailed(operation: String, errno: Int32)
    case changeDirectoryFailed(path: String, errno: Int32)
    case spawnAttributesFailed(operation: String, errno: Int32)
    case spawnFailed(errno: Int32)
}

/// Injected child-process boundary for reusable runtime owners.
protocol ProcessLaunching: Sendable {
    func spawn(
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?
    ) throws -> SpawnedProcess
}
