import Foundation

package struct SpawnedProcess: @unchecked Sendable {
    package let pid: Int32
    package let stdin: FileHandle?
    package let stdinDescriptor: Int32?
    package let stdout: FileHandle
    package let stderr: FileHandle

    package init(
        pid: Int32,
        stdin: FileHandle?,
        stdinDescriptor: Int32?,
        stdout: FileHandle,
        stderr: FileHandle
    ) {
        self.pid = pid
        self.stdin = stdin
        self.stdinDescriptor = stdinDescriptor
        self.stdout = stdout
        self.stderr = stderr
    }
}

package enum ProcessDescriptorConfigurationStage: Equatable {
    case invalidDescriptor
    case getDescriptorFlags
    case setDescriptorFlags
}

package enum ProcessLaunchError: Error, Equatable {
    case pipeCreationFailed(String)
    case descriptorConfigurationFailed(
        stage: ProcessDescriptorConfigurationStage,
        label: String,
        fd: Int32,
        errno: Int32
    )
    case spawnFileActionsFailed(operation: String, errno: Int32)
    case changeDirectoryFailed(path: String, errno: Int32)
    case spawnAttributesFailed(operation: String, errno: Int32)
    case spawnFailed(errno: Int32)
}

package protocol ProcessLaunching: Sendable {
    func spawn(
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?
    ) throws -> SpawnedProcess
}
