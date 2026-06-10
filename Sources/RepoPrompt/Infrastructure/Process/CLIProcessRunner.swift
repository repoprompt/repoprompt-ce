import Darwin
import Foundation

/// Separate diagnostic logger for deadlock debugging (independent of config.enableDebugLogging)
enum ProcessDiagnostics {
    static var enableLogging = false

    static func log(_ message: String) {
        guard enableLogging else { return }
        print("[ProcessDiagnostics] \(message)")
    }
}

/// Actor to coordinate gate release and prevent double-release
private actor GateReleaseCoordinator {
    private var released = false

    func markReleased() -> Bool {
        if released { return false }
        released = true
        return true
    }
}

/// Global cache: remember the absolute path to a command once we've
/// successfully launched it at least once. This avoids repeating
/// interactive-shell lookups (which are relatively expensive).
private actor ResolvedCommandCache {
    static let shared = ResolvedCommandCache()
    private var map: [String: String] = [:] // command -> absolute path
    func get(for command: String) -> String? {
        map[command]
    }

    func put(_ path: String, for command: String) {
        map[command] = path
    }

    func invalidate(_ command: String? = nil) {
        if let command { map.removeValue(forKey: command) } else { map.removeAll() }
    }
}

/// Diagnostics logger for lifecycle gate operations
enum LifecycleGateDiagnostics {
    static var enableLogging = false

    static func log(_ message: String) {
        guard enableLogging else { return }
        print("[LifecycleGate] \(message)")
    }
}

enum CLIProcessRunnerError: Error, LocalizedError {
    case commandNotFound(String)
    case spawnFailed(String)
    case inputEncodingFailed
    case inputWriteFailed(String)
    case waitFailed(String)

    var errorDescription: String? {
        switch self {
        case let .commandNotFound(command):
            "Command not found: \(command)"
        case let .spawnFailed(message):
            message
        case .inputEncodingFailed:
            "Failed to encode input for process"
        case let .inputWriteFailed(message):
            message
        case let .waitFailed(message):
            "waitpid failed: \(message)"
        }
    }
}

final class CLIProcessRunner {
    struct Result {
        let stdout: Data
        let stderr: Data
        let status: Int32
        let timedOut: Bool
    }

    enum OutputFlagMode {
        case auto(CLIOutputFormat)
        case none
        case custom([String])
    }

    enum StreamEvent {
        case stdout(Data)
        case stderr(Data)
        case terminated(status: Int32, timedOut: Bool)
    }

    let config: CLIProcessConfiguration
    private let registry = ProcessRegistry()
    private let gate: TaskSemaphore

    init(config: CLIProcessConfiguration, concurrencyLimit: Int = 1) {
        self.config = config
        gate = TaskSemaphore(max(concurrencyLimit, 1))
    }

    @inline(__always)
    private func cancelEarlyReleasingGate(phase: String) async throws {
        if Task.isCancelled {
            ProcessDiagnostics.log("🛑 [CANCEL] \(phase); releasing gate")
            await gate.release()
            throw CancellationError()
        }
    }

    private func terminateChild(_ p: SpawnedProcess, sendSigterm: Bool) {
        // Only the waitpid-driven cleanup should close stdout/stderr. Here we just stop input
        // and request termination so reader threads aren't left blocked on a closed read end.
        p.stdin?.closeFile()
        if sendSigterm {
            kill(p.pid, SIGTERM)
        }
    }

    @inline(__always)
    private static func isRunnableExecutable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        return access(path, X_OK) == 0
    }

    func run(
        args: [String],
        stdin: String?,
        outputMode: OutputFlagMode = .auto(.json),
        timeout: TimeInterval?,
        additionalEnvironment: [String: String] = [:],
        additionalRemovedKeys: Set<String> = [],
        cancelChildOnTaskCancellation: Bool = false
    ) async throws -> Result {
        try await gate.withPermit { [self] in
            let environment = await resolvedEnvironment(
                additionalEnvironment: additionalEnvironment,
                additionalRemovedKeys: additionalRemovedKeys
            )
            // Prefer a previously successful absolute path for this command.
            let resolvedCommand: String = await {
                if let cached = await ResolvedCommandCache.shared.get(for: config.command),
                   Self.isRunnableExecutable(cached)
                {
                    log("Using cached command path for \(config.command): \(cached)")
                    return cached
                }
                log("Resolving command: \(config.command)")
                return CommandPathResolver.resolve(
                    config.command,
                    environment: environment,
                    additionalPaths: config.additionalPaths,
                    logger: { [weak self] message in
                        self?.log(message)
                    },
                    preferredBasenames: (config.resolveCandidates?.isEmpty == false ? config.resolveCandidates : [config.command])
                )
            }()
            let workingDirectory = CommandPathResolver.expandPath(config.workingDirectory, environment: environment)
            log("Using working directory: \(workingDirectory)")
            var arguments = config.commandSuffix + args
            switch outputMode {
            case let .auto(format):
                if let existing = arguments.firstIndex(of: "--output-format") {
                    let valueIndex = arguments.index(after: existing)
                    if valueIndex < arguments.count {
                        arguments[valueIndex] = format.rawValue
                    } else {
                        arguments.append(format.rawValue)
                    }
                } else {
                    arguments.append(contentsOf: format.tokens)
                }
            case .none:
                break
            case let .custom(tokens):
                arguments.append(contentsOf: tokens)
            }
            var resolvedIsDirectory: ObjCBool = false
            if resolvedCommand.contains("/"),
               FileManager.default.fileExists(atPath: resolvedCommand, isDirectory: &resolvedIsDirectory),
               resolvedIsDirectory.boolValue
            {
                log("Resolved command is a directory; refusing to execute: \(resolvedCommand)")
                throw CLIProcessRunnerError.commandNotFound(resolvedCommand)
            }
            if config.enableDebugLogging {
                let sensitiveFlags: Set = [
                    "--append-system-prompt",
                    "--system-prompt",
                    "--prompt"
                ]
                let sanitizedArgs = arguments.enumerated().map { index, arg -> String in
                    if index > 0, sensitiveFlags.contains(arguments[index - 1]) {
                        return "<redacted>"
                    }
                    if arg.contains("<file_map>")
                        || arg.contains("<user_instructions>")
                        || arg.contains("<discover_instructions>")
                        || arg.contains("<metadata>")
                        || arg.contains("\n")
                        || arg.count > 120
                    {
                        return "<redacted>"
                    }
                    return arg
                }
                log("Launching \(resolvedCommand) with arguments: \(sanitizedArgs)")
            } else {
                log("Launching \(resolvedCommand)")
            }
            let spawned: SpawnedProcess
            do {
                spawned = try ProcessLauncher.spawn(
                    command: resolvedCommand,
                    arguments: arguments,
                    environment: environment,
                    workingDirectory: workingDirectory
                )
            } catch let launcherError as ProcessLauncherError {
                log("Failed to spawn \(resolvedCommand): \(launcherError)")
                throw mapLauncherError(launcherError, command: resolvedCommand, workingDirectory: workingDirectory)
            } catch {
                log("Failed to launch \(resolvedCommand): \(error)")
                throw error
            }
            // Use AsyncScope.withCleanup to ensure cleanup completes before gate is released
            return try await AsyncScope.withCleanup {
                await registry.add(spawned)
            } cleanup: {
                await cleanupProcess(pid: spawned.pid)
            } operation: {
                // 1) Immediately start draining child output (prevents cross‑pipe back‑pressure)
                let group = DispatchGroup()
                var stdoutData = Data()
                var stderrData = Data()

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { group.leave() }
                    let chunkSize = 64 * 1024
                    while true {
                        guard let chunk = try? spawned.stdout.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                        stdoutData.append(chunk)
                    }
                }

                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { group.leave() }
                    let chunkSize = 64 * 1024
                    while true {
                        guard let chunk = try? spawned.stderr.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                        stderrData.append(chunk)
                    }
                }

                // 2) Feed stdin concurrently, in chunks; close when done
                if let stdin, !stdin.isEmpty,
                   let stdinHandle = spawned.stdin,
                   let data = stdin.data(using: .utf8)
                {
                    if config.logStdinSampleBytes > 0, let collector = config.logCollector,
                       let (sample, truncated) = makeUTF8Sample(from: data, limit: config.logStdinSampleBytes)
                    {
                        let suffix = truncated ? "…" : ""
                        collector.appendSection(title: "STDIN (sample)", content: sample + suffix)
                    }
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        defer { group.leave()
                            stdinHandle.closeFile()
                        }
                        let chunkSize = 64 * 1024
                        var offset = 0
                        while offset < data.count {
                            let end = min(offset + chunkSize, data.count)
                            let chunk = data.subdata(in: offset ..< end)
                            do { try stdinHandle.write(contentsOf: chunk) }
                            catch { break } // EPIPE or early exit; stop writing
                            offset = end
                        }
                    }
                } else {
                    spawned.stdin?.closeFile()
                }

                // 3) Wait asynchronously for termination
                let waitTask = Task.detached { () throws -> (Int32, Bool) in
                    // Use async, cooperative waiting to avoid blocking the pool
                    try await Self.waitForTerminationAsync(pid: spawned.pid, timeout: timeout) { [weak self] warning in
                        self?.log(warning)
                    }
                }

                let status: Int32
                let timedOut: Bool
                do {
                    let termination: (Int32, Bool) = if cancelChildOnTaskCancellation {
                        try await withTaskCancellationHandler {
                            let result = try await waitTask.value
                            try Task.checkCancellation()
                            return result
                        } onCancel: {
                            spawned.stdin?.closeFile()
                            kill(spawned.pid, SIGTERM)
                            waitTask.cancel()
                        }
                    } else {
                        try await waitTask.value
                    }
                    (status, timedOut) = termination
                } catch {
                    spawned.stdout.closeFile()
                    spawned.stderr.closeFile()
                    await Self.waitForGroup(group)
                    throw error
                }

                // Proactively close FDs and wait for readers to finish
                spawned.stdout.closeFile()
                spawned.stderr.closeFile()
                await Self.waitForGroup(group)
                if !stdoutData.isEmpty {
                    config.logCollector?.appendDataSection(title: "STDOUT", data: stdoutData)
                }
                if !stderrData.isEmpty {
                    config.logCollector?.appendDataSection(title: "STDERR", data: stderrData)
                }
                log("Process \(spawned.pid) exited with status \(status) (timed out: \(timedOut))")
                // On success, memorize the absolute path for next time.
                if status == 0, !timedOut, resolvedCommand.contains("/"),
                   Self.isRunnableExecutable(resolvedCommand)
                {
                    await ResolvedCommandCache.shared.put(resolvedCommand, for: config.command)
                }
                return Result(stdout: stdoutData, stderr: stderrData, status: status, timedOut: timedOut)
            }
        }
    }

    func runStreaming(
        args: [String],
        stdin: String?,
        outputMode: OutputFlagMode = .auto(.streamJson),
        timeout: TimeInterval?,
        additionalEnvironment: [String: String] = [:],
        additionalRemovedKeys: Set<String> = [],
        onProcessStarted: (@Sendable (pid_t) async -> Void)? = nil,
        onProcessTerminated: (@Sendable (pid_t) async -> Void)? = nil
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        // Hold the permit for the entire lifetime of the child process
        ProcessDiagnostics.log("🔵 [GATE] Acquiring gate...")
        await gate.acquire()
        ProcessDiagnostics.log("🟢 [GATE] Acquired")

        // If the caller cancelled before we even start heavy work, bail out now.
        try await cancelEarlyReleasingGate(phase: "after acquiring gate")

        let environment = await resolvedEnvironment(
            additionalEnvironment: additionalEnvironment,
            additionalRemovedKeys: additionalRemovedKeys
        )

        // Cancellation can happen while we were building environment; check again.
        try await cancelEarlyReleasingGate(phase: "after env/compose")
        let resolvedCommand: String = await {
            if let cached = await ResolvedCommandCache.shared.get(for: config.command),
               Self.isRunnableExecutable(cached)
            {
                log("Using cached command path for \(config.command): \(cached)")
                return cached
            }
            log("Resolving command: \(config.command)")
            return CommandPathResolver.resolve(
                config.command,
                environment: environment,
                additionalPaths: config.additionalPaths,
                logger: { [weak self] message in
                    self?.log(message)
                },
                preferredBasenames: (config.resolveCandidates?.isEmpty == false ? config.resolveCandidates : [config.command])
            )
        }()

        // Command resolution (which can spawn an interactive shell) finished; check again.
        try await cancelEarlyReleasingGate(phase: "after command resolve")

        let workingDirectory = CommandPathResolver.expandPath(config.workingDirectory, environment: environment)
        log("Using working directory: \(workingDirectory)")
        var arguments = config.commandSuffix + args
        switch outputMode {
        case let .auto(format):
            if let existing = arguments.firstIndex(of: "--output-format") {
                let valueIndex = arguments.index(after: existing)
                if valueIndex < arguments.count {
                    arguments[valueIndex] = format.rawValue
                } else {
                    arguments.append(format.rawValue)
                }
            } else {
                arguments.append(contentsOf: format.tokens)
            }
        case .none:
            break
        case let .custom(tokens):
            arguments.append(contentsOf: tokens)
        }
        var resolvedIsDirectory: ObjCBool = false
        if resolvedCommand.contains("/"),
           FileManager.default.fileExists(atPath: resolvedCommand, isDirectory: &resolvedIsDirectory),
           resolvedIsDirectory.boolValue
        {
            log("Resolved command is a directory; refusing to execute: \(resolvedCommand)")
            await gate.release()
            throw CLIProcessRunnerError.commandNotFound(resolvedCommand)
        }
        if config.enableDebugLogging {
            let sensitiveFlags: Set = [
                "--append-system-prompt",
                "--system-prompt",
                "--prompt"
            ]
            let sanitizedArgs = arguments.enumerated().map { index, arg -> String in
                if index > 0, sensitiveFlags.contains(arguments[index - 1]) {
                    return "<redacted>"
                }
                if arg.contains("<file_map>")
                    || arg.contains("<user_instructions>")
                    || arg.contains("<discover_instructions>")
                    || arg.contains("<metadata>")
                    || arg.contains("\n")
                    || arg.count > 120
                {
                    return "<redacted>"
                }
                return arg
            }
            log("Launching \(resolvedCommand) with arguments: \(sanitizedArgs)")
        } else {
            log("Launching \(resolvedCommand)")
        }
        // Absolutely last chance before we actually spawn the child process.
        try await cancelEarlyReleasingGate(phase: "pre-spawn")

        let spawned: SpawnedProcess
        do {
            spawned = try ProcessLauncher.spawn(
                command: resolvedCommand,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory
            )
        } catch let launcherError as ProcessLauncherError {
            log("Failed to spawn \(resolvedCommand): \(launcherError)")
            ProcessDiagnostics.log("🔴 [GATE] Releasing after spawn failure")
            await gate.release()
            throw mapLauncherError(launcherError, command: resolvedCommand, workingDirectory: workingDirectory)
        } catch {
            log("Failed to launch \(resolvedCommand): \(error)")
            ProcessDiagnostics.log("🔴 [GATE] Releasing after launch failure")
            await gate.release()
            throw error
        }

        await registry.add(spawned)
        await onProcessStarted?(spawned.pid)

        let collector = config.logCollector

        return AsyncThrowingStream { continuation in
            ProcessDiagnostics.log("🎬 [STREAM] Stream started for pid=\(spawned.pid)")

            // (A) Start draining output immediately (prevents cross‑pipe back‑pressure)
            let group = DispatchGroup()
            let stdoutTailLimit = config.captureStdoutTailBytes
            let stderrTailLimit = config.captureStderrTailBytes
            var stdoutTail = Data()
            var stderrTail = Data()

            let gateCoordinator = GateReleaseCoordinator()

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                let chunkSize = 64 * 1024
                while true {
                    guard let chunk = try? spawned.stdout.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                    appendTail(&stdoutTail, chunk: chunk, limit: stdoutTailLimit)
                    if case .terminated = continuation.yield(.stdout(chunk)) {
                        break
                    }
                }
            }

            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                let chunkSize = 64 * 1024
                while true {
                    guard let chunk = try? spawned.stderr.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                    appendTail(&stderrTail, chunk: chunk, limit: stderrTailLimit)
                    if case .terminated = continuation.yield(.stderr(chunk)) {
                        break
                    }
                }
            }

            // (B) Feed stdin concurrently, in chunks; close when done
            if let stdin, !stdin.isEmpty,
               let stdinHandle = spawned.stdin,
               let data = stdin.data(using: .utf8)
            {
                if config.logStdinSampleBytes > 0, let collector = config.logCollector,
                   let (sample, truncated) = makeUTF8Sample(from: data, limit: config.logStdinSampleBytes)
                {
                    let suffix = truncated ? "…" : ""
                    collector.appendSection(title: "STDIN (sample)", content: sample + suffix)
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer {
                        stdinHandle.closeFile()
                        group.leave()
                    }
                    let chunkSize = 64 * 1024
                    var offset = 0
                    while offset < data.count {
                        let end = min(offset + chunkSize, data.count)
                        let chunk = data.subdata(in: offset ..< end)
                        do { try stdinHandle.write(contentsOf: chunk) }
                        catch { break } // EPIPE or early exit
                        offset = end
                    }
                }
            } else {
                spawned.stdin?.closeFile()
            }

            let waitTask = Task.detached { () throws -> (Int32, Bool) in
                // Use async, cooperative waiting to avoid blocking the pool
                try await Self.waitForTerminationAsync(pid: spawned.pid, timeout: timeout) { warning in
                    ProcessDiagnostics.log(warning)
                }
            }

            // Detached so its lifetime outlives this closure and it always releases the permit
            let _ = Task.detached { [self, gateCoordinator] in
                do {
                    let (status, timedOut) = try await waitTask.value

                    // IMPORTANT: The child has terminated. Close FDs to unblock reads
                    // and wait for readers to finish.
                    ProcessDiagnostics.log("🔒 [FD] Closing FDs for pid=\(spawned.pid)")
                    spawned.stdout.closeFile()
                    spawned.stderr.closeFile()

                    let groupFinished = await Self.waitForGroup(group, timeout: 5.0, pid: spawned.pid) { msg in
                        ProcessDiagnostics.log(msg)
                    }
                    if !groupFinished {
                        ProcessDiagnostics.log("⚠️ [GROUP] Reader threads timed out for pid=\(spawned.pid)")
                    }

                    // Collect whatever has been read so far.
                    if !stdoutTail.isEmpty {
                        collector?.appendDataSection(title: "STDOUT", data: stdoutTail)
                    }
                    if !stderrTail.isEmpty {
                        collector?.appendDataSection(title: "STDERR", data: stderrTail)
                    }
                    // On success, memorize the absolute path for next time.
                    if status == 0, !timedOut, resolvedCommand.contains("/"),
                       Self.isRunnableExecutable(resolvedCommand)
                    {
                        await ResolvedCommandCache.shared.put(resolvedCommand, for: config.command)
                    }
                    continuation.yield(.terminated(status: status, timedOut: timedOut))
                    continuation.finish()
                    ProcessDiagnostics.log("✅ [STREAM] Finished normally for pid=\(spawned.pid)")
                } catch {
                    ProcessDiagnostics.log("❌ [ERROR] Wait failed for pid=\(spawned.pid): \(error)")
                    spawned.stdout.closeFile()
                    spawned.stderr.closeFile()

                    let groupFinished = await Self.waitForGroup(group, timeout: 5.0, pid: spawned.pid) { msg in
                        ProcessDiagnostics.log(msg)
                    }
                    if !groupFinished {
                        ProcessDiagnostics.log("⚠️ [GROUP] Reader timeout (error path) pid=\(spawned.pid)")
                    }

                    if !stdoutTail.isEmpty {
                        collector?.appendDataSection(title: "STDOUT", data: stdoutTail)
                    }
                    if !stderrTail.isEmpty {
                        collector?.appendDataSection(title: "STDERR", data: stderrTail)
                    }
                    continuation.finish(throwing: error)
                }
                ProcessDiagnostics.log("🧹 [CLEANUP] Cleaning up pid=\(spawned.pid)")
                if await cleanupProcess(pid: spawned.pid) {
                    await onProcessTerminated?(spawned.pid)
                }
                ProcessDiagnostics.log("🔴 [GATE] Releasing gate for pid=\(spawned.pid)")
                if await gateCoordinator.markReleased() {
                    await gate.release()
                    ProcessDiagnostics.log("🎉 [GATE] Released for pid=\(spawned.pid)")
                } else {
                    ProcessDiagnostics.log("⚠️ [GATE] Double-release prevented for pid=\(spawned.pid)")
                }
            }

            continuation.onTermination = { [self, gateCoordinator, spawned, group] reason in
                if case .cancelled = reason {
                    ProcessDiagnostics.log("🛑 [CANCEL] Cancelled pid=\(spawned.pid)")
                    // Ask child to exit and proactively complete cleanup ourselves.
                    terminateChild(spawned, sendSigterm: true)

                    // Fast-path cleanup: wait up to ~3s, escalate to SIGKILL if needed,
                    // then close FDs, drain readers briefly, and release the gate.
                    Task.detached { [self, gateCoordinator] in
                        let timeout = ProcessTermination.cooperativeCancellationWaitTimeout()
                        _ = try? await Self.waitForTerminationAsync(pid: spawned.pid, timeout: timeout) { msg in
                            ProcessDiagnostics.log(msg)
                        }
                        // Ensure reader threads unblock even if the monitor path stalls.
                        ProcessDiagnostics.log("🔒 [FD] Closing FDs (onTermination) for pid=\(spawned.pid)")
                        spawned.stdout.closeFile()
                        spawned.stderr.closeFile()

                        let _ = await Self.waitForGroup(group, timeout: 2.0, pid: spawned.pid) { msg in
                            ProcessDiagnostics.log(msg)
                        }
                        if await cleanupProcess(pid: spawned.pid) {
                            await onProcessTerminated?(spawned.pid)
                        }

                        if await gateCoordinator.markReleased() {
                            ProcessDiagnostics.log("🟠 [CANCEL] Releasing gate (onTermination) pid=\(spawned.pid)")
                            await gate.release()
                        } else {
                            ProcessDiagnostics.log("⚠️ [GATE] Double-release prevented (onTermination) pid=\(spawned.pid)")
                        }
                    }
                } else {
                    // Normal finish: let the waitpid-driven cleanup close streams and release the gate.
                }

                // Safety net: if gate hasn't been released within 15 seconds, force release.
                Task { [self, gateCoordinator] in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    if await gateCoordinator.markReleased() {
                        ProcessDiagnostics.log("🚨 [WATCHDOG] DEADLOCK! Force releasing gate for pid=\(spawned.pid)")
                        await gate.release()
                    }
                }
            }
        }
    }

    func cancelAll() async {
        // Do not steal cleanup ownership from runStreaming; just request termination.
        let processes = await registry.current()
        let timeout = ProcessTermination.cooperativeCancellationWaitTimeout()
        for process in processes {
            // Stop further input and ask the child to exit. The waitpid cleanup will close stdout/stderr.
            process.stdin?.closeFile()
            kill(process.pid, SIGTERM)
        }
        for process in processes {
            // Give every child a chance to begin exiting before we await individual reaping.
            do {
                let (status, _) = try await Self.waitForTerminationAsync(pid: process.pid, timeout: timeout) { [weak self] message in
                    self?.log(message)
                }
                log("Cancelled process \(process.pid) with status \(status)")
            } catch {
                log("Failed to wait for process \(process.pid): \(error)")
            }
        }
    }

    private func resolvedEnvironment(
        additionalEnvironment: [String: String] = [:],
        additionalRemovedKeys: Set<String> = []
    ) async -> [String: String] {
        var overrides = config.environment
        // Runtime environment variables take highest priority.
        for (key, value) in additionalEnvironment {
            overrides[key] = value
        }
        let result = await ProcessEnvironmentBuilder.build(
            ProcessEnvironmentRequest(
                purpose: .cliRunner,
                overrides: overrides,
                additionalRemovedKeys: additionalRemovedKeys,
                enableDebugLogging: config.enableDebugLogging
            )
        )
        return result.environment
    }

    private func log(_ message: String) {
        config.logCollector?.append(message)
        if config.enableDebugLogging {
            print("[CLIProcessRunner] \(message)")
        }
    }

    @discardableResult
    private func cleanupProcess(pid: pid_t) async -> Bool {
        guard let process = await registry.remove(pid: pid) else { return false }
        process.stdin?.closeFile()
        process.stdout.closeFile()
        process.stderr.closeFile()
        return true
    }

    private func mapLauncherError(
        _ error: ProcessLauncherError,
        command: String,
        workingDirectory: String?
    ) -> CLIProcessRunnerError {
        switch error {
        case let .pipeCreationFailed(pipe):
            return .spawnFailed("Failed to create \(pipe) pipe for process startup")
        case let .descriptorConfigurationFailed(label, fd, underlying):
            let message = String(cString: strerror(underlying.errnoValue))
            return .spawnFailed("Failed to configure \(label) pipe descriptor \(fd) for process startup: \(message)")
        case let .spawnFileActionsFailed(operation, errnoValue):
            let message = String(cString: strerror(errnoValue))
            return .spawnFailed("Failed to configure spawn file actions (\(operation)) for \(command): \(message)")
        case let .changeDirectoryFailed(path, errnoValue):
            let message = String(cString: strerror(errnoValue))
            return .spawnFailed("Unable to set working directory to \(path): \(message)")
        case let .spawnAttributesFailed(operation, errnoValue):
            let message = String(cString: strerror(errnoValue))
            if let workingDirectory {
                return .spawnFailed("Failed to configure spawn attributes (\(operation)) for \(command) in \(workingDirectory): \(message)")
            }
            return .spawnFailed("Failed to configure spawn attributes (\(operation)) for \(command): \(message)")
        case let .spawnFailed(errnoValue):
            if errnoValue == ENOENT {
                return .commandNotFound(command)
            }
            let message = String(cString: strerror(errnoValue))
            if let workingDirectory {
                return .spawnFailed("Failed to launch \(command) in \(workingDirectory): \(message)")
            }
            return .spawnFailed("Failed to launch \(command): \(message)")
        }
    }

    // MARK: - Async helpers

    /// Async wrapper around DispatchGroup.wait() to avoid blocking in async contexts
    private static func waitForGroup(_ group: DispatchGroup) async {
        await withCheckedContinuation { continuation in
            group.notify(queue: .global()) {
                continuation.resume()
            }
        }
    }

    /// Wait for group with timeout to prevent deadlocks
    private static func waitForGroup(_ group: DispatchGroup, timeout: TimeInterval, pid: pid_t, logger: @escaping (String) -> Void) async -> Bool {
        let timeoutNs = UInt64(timeout * 1_000_000_000)

        return await withTaskGroup(of: Bool.self) { taskGroup in
            // Task 1: Wait for group to complete
            taskGroup.addTask {
                await withCheckedContinuation { continuation in
                    group.notify(queue: .global()) {
                        continuation.resume()
                    }
                }
                return true
            }

            // Task 2: Timeout
            taskGroup.addTask {
                try? await Task.sleep(nanoseconds: timeoutNs)
                return false
            }

            // Return result of whichever finishes first
            let result = await taskGroup.next() ?? false
            taskGroup.cancelAll()

            if !result {
                logger("⏰ [GROUP] Timeout waiting for reader threads for pid=\(pid)")
            }

            return result
        }
    }

    // MARK: - Cooperative process termination (no blocking sleeps)

    private static func waitForTerminationAsync(
        pid: pid_t,
        timeout: TimeInterval?,
        logger: (String) -> Void
    ) async throws -> (Int32, Bool) {
        do {
            let (exitCode, timedOut) = try await ProcessTermination.waitForTermination(
                pid: pid,
                timeout: timeout,
                logger: logger
            )
            return (exitCode, timedOut)
        } catch let terminationError as ProcessTerminationError {
            switch terminationError {
            case let .waitFailed(message):
                throw CLIProcessRunnerError.waitFailed(message)
            }
        }
    }
}
