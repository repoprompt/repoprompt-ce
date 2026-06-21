import Darwin
import Foundation
import RepoPromptCore
import RepoPromptPOSIXSupport

package enum ProcessLauncher {
    package static func spawn(
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?
    ) throws -> SpawnedProcess {
        try spawn(
            command: command,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            initializationFailure: nil
        )
    }

    #if DEBUG
        package enum DebugInitializationFailure {
            case fileActions(errno: Int32)
            case attributes(errno: Int32)
        }

        package static func debugSpawn(
            command: String,
            arguments: [String],
            environment: [String: String],
            workingDirectory: String?,
            initializationFailure: DebugInitializationFailure
        ) throws -> SpawnedProcess {
            let failure: InitializationFailure = switch initializationFailure {
            case let .fileActions(errno): .fileActions(errno: errno)
            case let .attributes(errno): .attributes(errno: errno)
            }
            return try spawn(
                command: command,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                initializationFailure: failure
            )
        }
    #endif

    private enum InitializationFailure {
        case fileActions(errno: Int32)
        case attributes(errno: Int32)
    }

    private static func spawn(
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?,
        initializationFailure: InitializationFailure?
    ) throws -> SpawnedProcess {
        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]

        func closePipe(_ pipe: inout [Int32]) {
            if pipe[0] != -1 { close(pipe[0]) }
            if pipe[1] != -1 { close(pipe[1]) }
            pipe = [-1, -1]
        }

        func closePipes() {
            closePipe(&stdinPipe)
            closePipe(&stdoutPipe)
            closePipe(&stderrPipe)
        }

        func configureCloseOnExec(_ descriptors: [Int32], label: String) throws {
            for fd in descriptors {
                do {
                    try POSIXDescriptorSupport.setCloseOnExec(fd)
                } catch let error as POSIXDescriptorConfigurationError {
                    let stage: ProcessDescriptorConfigurationStage = switch error {
                    case .invalidFileDescriptor: .invalidDescriptor
                    case .getDescriptorFlagsFailed: .getDescriptorFlags
                    case .setDescriptorFlagsFailed: .setDescriptorFlags
                    }
                    throw ProcessLaunchError.descriptorConfigurationFailed(
                        stage: stage,
                        label: label,
                        fd: fd,
                        errno: error.errnoValue
                    )
                }
            }
        }

        guard pipe(&stdinPipe) == 0 else {
            throw ProcessLaunchError.pipeCreationFailed("stdin")
        }
        do {
            try configureCloseOnExec(stdinPipe, label: "stdin")
        } catch {
            closePipe(&stdinPipe)
            throw error
        }

        guard pipe(&stdoutPipe) == 0 else {
            closePipe(&stdinPipe)
            throw ProcessLaunchError.pipeCreationFailed("stdout")
        }
        do {
            try configureCloseOnExec(stdoutPipe, label: "stdout")
        } catch {
            closePipe(&stdinPipe)
            closePipe(&stdoutPipe)
            throw error
        }

        guard pipe(&stderrPipe) == 0 else {
            closePipe(&stdinPipe)
            closePipe(&stdoutPipe)
            throw ProcessLaunchError.pipeCreationFailed("stderr")
        }
        do {
            try configureCloseOnExec(stderrPipe, label: "stderr")
        } catch {
            closePipe(&stdinPipe)
            closePipe(&stdoutPipe)
            closePipe(&stderrPipe)
            throw error
        }

        _ = FDWriteSupport.configureNoSigPipe(fd: stdinPipe[1])

        var fileActions: posix_spawn_file_actions_t? = nil
        let fileActionsInitResult: Int32 = if case let .fileActions(errno)? = initializationFailure {
            errno
        } else {
            posix_spawn_file_actions_init(&fileActions)
        }
        if fileActionsInitResult != 0 {
            closePipes()
            throw ProcessLaunchError.spawnFileActionsFailed(operation: "init", errno: fileActionsInitResult)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        func checkFileAction(_ operation: String, result: Int32) throws {
            if result != 0 {
                closePipes()
                throw ProcessLaunchError.spawnFileActionsFailed(operation: operation, errno: result)
            }
        }

        try checkFileAction("adddup2(stdin)", result: posix_spawn_file_actions_adddup2(&fileActions, stdinPipe[0], STDIN_FILENO))
        try checkFileAction("adddup2(stdout)", result: posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO))
        try checkFileAction("adddup2(stderr)", result: posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO))
        try checkFileAction("addclose(stdin write)", result: posix_spawn_file_actions_addclose(&fileActions, stdinPipe[1]))
        try checkFileAction("addclose(stdout read)", result: posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0]))
        try checkFileAction("addclose(stderr read)", result: posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0]))

        if let workingDirectory {
            let result = workingDirectory.withCString { pointer -> Int32 in
                #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
                    return posix_spawn_file_actions_addchdir_np(&fileActions, pointer)
                #else
                    return 0
                #endif
            }
            if result != 0 {
                closePipe(&stdinPipe)
                closePipe(&stdoutPipe)
                closePipe(&stderrPipe)
                throw ProcessLaunchError.changeDirectoryFailed(path: workingDirectory, errno: result)
            }
        }

        var attributes: posix_spawnattr_t? = nil
        let attributesInitResult: Int32 = if case let .attributes(errno)? = initializationFailure {
            errno
        } else {
            posix_spawnattr_init(&attributes)
        }
        if attributesInitResult != 0 {
            closePipes()
            throw ProcessLaunchError.spawnAttributesFailed(operation: "init", errno: attributesInitResult)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        // Parent-side write paths use no-SIGPIPE hardening; restore the default SIGPIPE
        // disposition in spawned children so CLI/tool processes keep normal pipe semantics.
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGPIPE)

        var spawnFlags: Int16 = 0
        let getFlagsResult = posix_spawnattr_getflags(&attributes, &spawnFlags)
        if getFlagsResult != 0 {
            closePipe(&stdinPipe)
            closePipe(&stdoutPipe)
            closePipe(&stderrPipe)
            throw ProcessLaunchError.spawnAttributesFailed(operation: "getflags", errno: getFlagsResult)
        }

        let setSigDefaultResult = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        if setSigDefaultResult != 0 {
            closePipe(&stdinPipe)
            closePipe(&stdoutPipe)
            closePipe(&stderrPipe)
            throw ProcessLaunchError.spawnAttributesFailed(operation: "setsigdefault", errno: setSigDefaultResult)
        }

        var configuredSpawnFlags = spawnFlags | Int16(POSIX_SPAWN_SETSIGDEF)
        #if canImport(Darwin)
            configuredSpawnFlags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        let setFlagsResult = posix_spawnattr_setflags(&attributes, configuredSpawnFlags)
        if setFlagsResult != 0 {
            closePipe(&stdinPipe)
            closePipe(&stdoutPipe)
            closePipe(&stderrPipe)
            throw ProcessLaunchError.spawnAttributesFailed(operation: "setflags", errno: setFlagsResult)
        }

        var argv: [UnsafeMutablePointer<CChar>?] = []
        argv.reserveCapacity(arguments.count + 2)
        argv.append(strdup(command))
        for argument in arguments {
            argv.append(strdup(argument))
        }
        argv.append(nil)
        defer {
            for pointer in argv where pointer != nil {
                free(pointer)
            }
        }

        var envp: [UnsafeMutablePointer<CChar>?] = []
        envp.reserveCapacity(environment.count + 1)
        for (key, value) in environment {
            envp.append(strdup("\(key)=\(value)"))
        }
        envp.append(nil)
        defer {
            for pointer in envp where pointer != nil {
                free(pointer)
            }
        }

        var pid: pid_t = 0
        let spawnResult = posix_spawnp(
            &pid,
            command,
            &fileActions,
            &attributes,
            argv,
            envp
        )

        if spawnResult != 0 {
            closePipe(&stdinPipe)
            closePipe(&stdoutPipe)
            closePipe(&stderrPipe)
            throw ProcessLaunchError.spawnFailed(errno: spawnResult)
        }

        close(stdinPipe[0])
        close(stdoutPipe[1])
        close(stderrPipe[1])

        let stdinHandle = FileHandle(fileDescriptor: stdinPipe[1], closeOnDealloc: true)
        let stdoutHandle = FileHandle(fileDescriptor: stdoutPipe[0], closeOnDealloc: true)
        let stderrHandle = FileHandle(fileDescriptor: stderrPipe[0], closeOnDealloc: true)

        return SpawnedProcess(
            pid: pid,
            stdin: stdinHandle,
            stdinDescriptor: stdinPipe[1],
            stdout: stdoutHandle,
            stderr: stderrHandle
        )
    }
}

/// macOS POSIX adapter exposed through the neutral process-launching contract.
package struct POSIXProcessLauncher: ProcessLaunching {
    package init() {}

    package func spawn(
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?
    ) throws -> SpawnedProcess {
        try ProcessLauncher.spawn(
            command: command,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
    }
}
