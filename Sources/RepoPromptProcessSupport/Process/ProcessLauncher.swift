import Darwin
import Foundation
import RepoPromptShared

package struct SpawnedProcess: @unchecked Sendable {
    package let pid: pid_t
    package let processGroupID: pid_t?
    package let stdin: FileHandle?
    package let stdinDescriptor: Int32?
    package let stdout: FileHandle
    package let stderr: FileHandle

    package init(
        pid: pid_t,
        processGroupID: pid_t?,
        stdin: FileHandle?,
        stdinDescriptor: Int32?,
        stdout: FileHandle,
        stderr: FileHandle
    ) {
        self.pid = pid
        self.processGroupID = processGroupID
        self.stdin = stdin
        self.stdinDescriptor = stdinDescriptor
        self.stdout = stdout
        self.stderr = stderr
    }
}

package enum ProcessLauncherError: Error {
    case pipeCreationFailed(String)
    case descriptorConfigurationFailed(label: String, fd: Int32, underlying: POSIXDescriptorConfigurationError)
    case spawnFileActionsFailed(operation: String, errno: Int32)
    case changeDirectoryFailed(path: String, errno: Int32)
    case spawnAttributesFailed(operation: String, errno: Int32)
    case spawnFailed(errno: Int32)
}

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
            if pipe[0] != -1 {
                close(pipe[0])
            }
            if pipe[1] != -1 {
                close(pipe[1])
            }
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
                    throw ProcessLauncherError.descriptorConfigurationFailed(label: label, fd: fd, underlying: error)
                }
            }
        }

        guard pipe(&stdinPipe) == 0 else {
            throw ProcessLauncherError.pipeCreationFailed("stdin")
        }
        do {
            try configureCloseOnExec(stdinPipe, label: "stdin")
        } catch {
            closePipe(&stdinPipe)
            throw error
        }

        guard pipe(&stdoutPipe) == 0 else {
            closePipe(&stdinPipe)
            throw ProcessLauncherError.pipeCreationFailed("stdout")
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
            throw ProcessLauncherError.pipeCreationFailed("stderr")
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
            throw ProcessLauncherError.spawnFileActionsFailed(operation: "init", errno: fileActionsInitResult)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        func checkFileAction(_ operation: String, result: Int32) throws {
            if result != 0 {
                closePipes()
                throw ProcessLauncherError.spawnFileActionsFailed(operation: operation, errno: result)
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
                throw ProcessLauncherError.changeDirectoryFailed(path: workingDirectory, errno: result)
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
            throw ProcessLauncherError.spawnAttributesFailed(operation: "init", errno: attributesInitResult)
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
            throw ProcessLauncherError.spawnAttributesFailed(operation: "getflags", errno: getFlagsResult)
        }

        let setSigDefaultResult = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        if setSigDefaultResult != 0 {
            closePipe(&stdinPipe)
            closePipe(&stdoutPipe)
            closePipe(&stderrPipe)
            throw ProcessLauncherError.spawnAttributesFailed(operation: "setsigdefault", errno: setSigDefaultResult)
        }

        // Place each spawned CLI/provider root in its own process group. Cancellation
        // and timeout cleanup can then signal the whole tool family, not just the
        // direct child PID, which prevents same-PGID descendants from surviving if
        // they are reparented away from the original process tree.
        let setProcessGroupResult = posix_spawnattr_setpgroup(&attributes, 0)
        if setProcessGroupResult != 0 {
            closePipe(&stdinPipe)
            closePipe(&stdoutPipe)
            closePipe(&stderrPipe)
            throw ProcessLauncherError.spawnAttributesFailed(operation: "setpgroup", errno: setProcessGroupResult)
        }

        var configuredSpawnFlags = spawnFlags | Int16(POSIX_SPAWN_SETSIGDEF) | Int16(POSIX_SPAWN_SETPGROUP)
        #if canImport(Darwin)
            configuredSpawnFlags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        let setFlagsResult = posix_spawnattr_setflags(&attributes, configuredSpawnFlags)
        if setFlagsResult != 0 {
            closePipe(&stdinPipe)
            closePipe(&stdoutPipe)
            closePipe(&stderrPipe)
            throw ProcessLauncherError.spawnAttributesFailed(operation: "setflags", errno: setFlagsResult)
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
            throw ProcessLauncherError.spawnFailed(errno: spawnResult)
        }

        close(stdinPipe[0])
        close(stdoutPipe[1])
        close(stderrPipe[1])

        let stdinHandle = FileHandle(fileDescriptor: stdinPipe[1], closeOnDealloc: true)
        let stdoutHandle = FileHandle(fileDescriptor: stdoutPipe[0], closeOnDealloc: true)
        let stderrHandle = FileHandle(fileDescriptor: stderrPipe[0], closeOnDealloc: true)

        return SpawnedProcess(
            pid: pid,
            processGroupID: pid,
            stdin: stdinHandle,
            stdinDescriptor: stdinPipe[1],
            stdout: stdoutHandle,
            stderr: stderrHandle
        )
    }
}
