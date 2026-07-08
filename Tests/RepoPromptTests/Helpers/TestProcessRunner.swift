import Foundation
import XCTest
#if os(macOS)
    import Darwin
#elseif os(Linux)
    import Glibc
#endif

struct TestProcessResult {
    let terminationStatus: Int32
    let output: Data

    var outputText: String {
        String(decoding: output, as: UTF8.self)
    }
}

struct TestProcessTimeoutError: Error, LocalizedError, CustomStringConvertible {
    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL?
    let timeout: TimeInterval
    let output: Data

    var outputText: String {
        String(decoding: output, as: UTF8.self)
    }

    var errorDescription: String? {
        description
    }

    var description: String {
        var parts = [
            "Process timed out after \(String(format: "%.3f", timeout))s:",
            ([executableURL.path] + arguments).joined(separator: " ")
        ]
        if let currentDirectoryURL {
            parts.append("cwd: \(currentDirectoryURL.path)")
        }
        if !output.isEmpty {
            parts.append("captured output:\n\(outputText)")
        }
        return parts.joined(separator: "\n")
    }
}

/// Raised when the child exits within the deadline but stdout/stderr drain does not complete.
struct TestProcessOutputDrainTimeoutError: Error, LocalizedError, CustomStringConvertible {
    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL?
    let drainTimeout: TimeInterval
    let terminationStatus: Int32
    let output: Data

    var outputText: String {
        String(decoding: output, as: UTF8.self)
    }

    var errorDescription: String? {
        description
    }

    var description: String {
        var parts = [
            "Process exited (status \(terminationStatus)) but output drain timed out after \(String(format: "%.3f", drainTimeout))s:",
            ([executableURL.path] + arguments).joined(separator: " ")
        ]
        if let currentDirectoryURL {
            parts.append("cwd: \(currentDirectoryURL.path)")
        }
        if !output.isEmpty {
            parts.append("captured output:\n\(outputText)")
        }
        return parts.joined(separator: "\n")
    }
}

enum TestProcessRunner {
    /// Default wall-clock budget for `run`. Keep this modest so a wedged child cannot
    /// stall the suite; known heavy call sites (cold git fixtures, large clones) should
    /// pass an explicit larger `timeout:` rather than raising the global default.
    static let defaultTimeout: TimeInterval = 30
    private static let terminationGraceInterval: TimeInterval = 1
    private static let outputDrainGraceInterval: TimeInterval = 1
    /// Tight budget for assistive pgrep child discovery (primary kill is process-group).
    private static let childPIDQueryTimeout: TimeInterval = 0.2
    /// Cap emergency pgrep tree walks so hang recovery cannot spend unbounded time.
    /// Process-group `kill(-pgid)` remains primary for the posix_spawn path; this walk is
    /// assistive only for Foundation `Process` trees.
    private static let maxProcessTreeWalkDepth = 3
    private static let maxProcessTreeWalkNodes = 16
    /// After kill grace, unreaped pids are tracked for best-effort `WNOHANG` reaping.
    /// Residual zombies (D-state / unkillable) live only for the suite process lifetime.
    private static let maxAbandonedPIDsBeforeFail = 16

    static func run(
        executableURL: URL,
        arguments: [String] = [],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = defaultTimeout
    ) throws -> TestProcessResult {
        #if os(macOS) || os(Linux)
            reapAbandonedChildren()
            return try runWithSpawnedProcessGroup(
                executableURL: executableURL,
                arguments: arguments,
                currentDirectoryURL: currentDirectoryURL,
                environment: environment,
                timeout: timeout
            )
        #else
            try runWithFoundationProcess(
                executableURL: executableURL,
                arguments: arguments,
                currentDirectoryURL: currentDirectoryURL,
                environment: environment,
                timeout: timeout
            )
        #endif
    }

    private static func runWithFoundationProcess(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?,
        environment: [String: String]?,
        timeout: TimeInterval
    ) throws -> TestProcessResult {
        precondition(timeout > 0, "TestProcessRunner timeout must be positive")

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        let capturedOutput = LockedOutput()
        let readerGroup = DispatchGroup()
        let outputReader = output.fileHandleForReading
        readerGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { readerGroup.leave() }
            while true {
                guard let chunk = try? outputReader.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                    break
                }
                capturedOutput.append(chunk)
            }
        }

        let terminationGroup = DispatchGroup()
        terminationGroup.enter()
        process.terminationHandler = { _ in
            terminationGroup.leave()
        }

        do {
            try process.run()
        } catch {
            close(output.fileHandleForReading)
            close(output.fileHandleForWriting)
            readerGroup.wait()
            throw error
        }

        close(output.fileHandleForWriting)

        if terminationGroup.wait(timeout: .now() + timeout) == .timedOut {
            terminate(process)
            if terminationGroup.wait(timeout: .now() + terminationGraceInterval) == .timedOut {
                forceTerminate(process)
                _ = terminationGroup.wait(timeout: .now() + terminationGraceInterval)
            }

            finishReadingAfterTimeout(output.fileHandleForReading, readerGroup: readerGroup)
            throw TestProcessTimeoutError(
                executableURL: executableURL,
                arguments: arguments,
                currentDirectoryURL: currentDirectoryURL,
                timeout: timeout,
                output: capturedOutput.data()
            )
        }

        if finishReadingAfterProcessExit(output.fileHandleForReading, readerGroup: readerGroup) == false {
            // Best-effort cleanup for any orphaned descendants still holding the pipe.
            terminate(process)
            forceTerminate(process)
            throw TestProcessOutputDrainTimeoutError(
                executableURL: executableURL,
                arguments: arguments,
                currentDirectoryURL: currentDirectoryURL,
                drainTimeout: outputDrainGraceInterval,
                terminationStatus: process.terminationStatus,
                output: capturedOutput.data()
            )
        }

        return TestProcessResult(
            terminationStatus: process.terminationStatus,
            output: capturedOutput.data()
        )
    }

    #if os(macOS) || os(Linux)
        private static func runWithSpawnedProcessGroup(
            executableURL: URL,
            arguments: [String],
            currentDirectoryURL: URL?,
            environment: [String: String]?,
            timeout: TimeInterval
        ) throws -> TestProcessResult {
            precondition(timeout > 0, "TestProcessRunner timeout must be positive")

            var outputPipe: [Int32] = [-1, -1]
            guard pipe(&outputPipe) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            func closePipe() {
                if outputPipe[0] >= 0 {
                    systemClose(outputPipe[0])
                    outputPipe[0] = -1
                }
                if outputPipe[1] >= 0 {
                    systemClose(outputPipe[1])
                    outputPipe[1] = -1
                }
            }

            do {
                try setCloseOnExec(outputPipe[0])
                try setCloseOnExec(outputPipe[1])
            } catch {
                closePipe()
                throw error
            }

            #if os(macOS)
                var fileActions: posix_spawn_file_actions_t? = nil
            #else
                var fileActions = posix_spawn_file_actions_t()
            #endif
            var result = posix_spawn_file_actions_init(&fileActions)
            guard result == 0 else {
                closePipe()
                throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
            }
            defer { posix_spawn_file_actions_destroy(&fileActions) }

            func checkFileAction(_ result: Int32) throws {
                guard result == 0 else {
                    closePipe()
                    throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
                }
            }

            // Under POSIX_SPAWN_CLOEXEC_DEFAULT (Darwin), fds not explicitly installed are closed.
            // Open stdin to /dev/null so children match Foundation.Process (valid fd 0, EOF on read)
            // rather than a closed stdin that some tools probe differently.
            try checkFileAction(
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDIN_FILENO,
                    "/dev/null",
                    O_RDONLY,
                    0
                )
            )
            try checkFileAction(posix_spawn_file_actions_adddup2(&fileActions, outputPipe[1], STDOUT_FILENO))
            try checkFileAction(posix_spawn_file_actions_adddup2(&fileActions, outputPipe[1], STDERR_FILENO))
            try checkFileAction(posix_spawn_file_actions_addclose(&fileActions, outputPipe[0]))
            try checkFileAction(posix_spawn_file_actions_addclose(&fileActions, outputPipe[1]))

            if let currentDirectoryURL {
                result = currentDirectoryURL.path.withCString { path in
                    posix_spawn_file_actions_addchdir_np(&fileActions, path)
                }
                try checkFileAction(result)
            }

            #if os(macOS)
                var attributes: posix_spawnattr_t? = nil
            #else
                var attributes = posix_spawnattr_t()
            #endif
            result = posix_spawnattr_init(&attributes)
            guard result == 0 else {
                closePipe()
                throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
            }
            defer { posix_spawnattr_destroy(&attributes) }

            var spawnFlags = Int16(POSIX_SPAWN_SETPGROUP)
            #if canImport(Darwin)
                spawnFlags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
            #endif
            result = posix_spawnattr_setpgroup(&attributes, 0)
            guard result == 0 else {
                closePipe()
                throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
            }
            result = posix_spawnattr_setflags(&attributes, spawnFlags)
            guard result == 0 else {
                closePipe()
                throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
            }

            var argv: [UnsafeMutablePointer<CChar>?] = []
            argv.reserveCapacity(arguments.count + 2)
            argv.append(strdup(executableURL.path))
            for argument in arguments {
                argv.append(strdup(argument))
            }
            argv.append(nil)
            defer {
                for pointer in argv where pointer != nil {
                    free(pointer)
                }
            }

            let processEnvironment = environment ?? ProcessInfo.processInfo.environment
            var envp: [UnsafeMutablePointer<CChar>?] = []
            envp.reserveCapacity(processEnvironment.count + 1)
            for (key, value) in processEnvironment {
                envp.append(strdup("\(key)=\(value)"))
            }
            envp.append(nil)
            defer {
                for pointer in envp where pointer != nil {
                    free(pointer)
                }
            }

            var pid: pid_t = 0
            result = posix_spawn(
                &pid,
                executableURL.path,
                &fileActions,
                &attributes,
                argv,
                envp
            )
            guard result == 0 else {
                closePipe()
                throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
            }

            systemClose(outputPipe[1])
            outputPipe[1] = -1

            let capturedOutput = LockedOutput()
            let readerGroup = DispatchGroup()
            let outputReader = FileHandle(fileDescriptor: outputPipe[0], closeOnDealloc: true)
            outputPipe[0] = -1
            readerGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { readerGroup.leave() }
                while true {
                    guard let chunk = try? outputReader.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                        break
                    }
                    capturedOutput.append(chunk)
                }
            }

            let terminationGroup = DispatchGroup()
            let waitStatusBox = LockedWaitStatus()
            let spawnedPID = pid
            terminationGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var status: Int32 = 0
                var waitResult: pid_t = 0
                repeat {
                    waitResult = waitpid(spawnedPID, &status, 0)
                } while waitResult < 0 && errno == EINTR

                if waitResult == spawnedPID {
                    waitStatusBox.set(.exited(status))
                    noteReaped(spawnedPID)
                } else {
                    let errorNumber = errno
                    waitStatusBox.set(.failed(errorNumber))
                    if errorNumber == ECHILD {
                        noteReaped(spawnedPID)
                    }
                }
                terminationGroup.leave()
            }

            if terminationGroup.wait(timeout: .now() + timeout) == .timedOut {
                signalProcessGroup(rootPID: pid, SIGTERM)
                if terminationGroup.wait(timeout: .now() + terminationGraceInterval) == .timedOut {
                    signalProcessGroup(rootPID: pid, SIGKILL)
                    if terminationGroup.wait(timeout: .now() + terminationGraceInterval) == .timedOut {
                        // waitpid still blocked (D-state / unkillable). Track for best-effort reaping;
                        // residual zombies last only for the suite process lifetime.
                        noteAbandoned(spawnedPID)
                    }
                }
                finishReadingAfterTimeout(outputReader, readerGroup: readerGroup)
                throw TestProcessTimeoutError(
                    executableURL: executableURL,
                    arguments: arguments,
                    currentDirectoryURL: currentDirectoryURL,
                    timeout: timeout,
                    output: capturedOutput.data()
                )
            }

            let status: Int32
            switch waitStatusBox.value {
            case let .exited(waitStatus):
                status = terminationStatus(fromWaitStatus: waitStatus)
            case let .failed(errorNumber):
                throw POSIXError(POSIXErrorCode(rawValue: errorNumber) ?? .ECHILD)
            case nil:
                throw POSIXError(.ECHILD)
            }
            if finishReadingAfterProcessExit(outputReader, readerGroup: readerGroup) == false {
                signalProcessGroup(rootPID: pid, SIGTERM)
                signalProcessGroup(rootPID: pid, SIGKILL)
                throw TestProcessOutputDrainTimeoutError(
                    executableURL: executableURL,
                    arguments: arguments,
                    currentDirectoryURL: currentDirectoryURL,
                    drainTimeout: outputDrainGraceInterval,
                    terminationStatus: status,
                    output: capturedOutput.data()
                )
            }

            return TestProcessResult(
                terminationStatus: status,
                output: capturedOutput.data()
            )
        }
    #endif

    private static func terminate(_ process: Process) {
        #if os(macOS)
            signal(process, SIGTERM)
        #elseif os(Linux)
            signal(process, SIGTERM)
        #endif
        if process.isRunning {
            process.terminate()
        }
    }

    private static func forceTerminate(_ process: Process) {
        #if os(macOS)
            signal(process, SIGKILL)
        #elseif os(Linux)
            signal(process, SIGKILL)
        #endif
    }

    private static func close(_ handle: FileHandle) {
        do {
            try handle.close()
        } catch {
            handle.closeFile()
        }
    }

    private static func finishReadingAfterProcessExit(_ handle: FileHandle, readerGroup: DispatchGroup) -> Bool {
        if readerGroup.wait(timeout: .now() + outputDrainGraceInterval) == .timedOut {
            close(handle)
            _ = readerGroup.wait(timeout: .now() + outputDrainGraceInterval)
            return false
        }
        close(handle)
        return true
    }

    private static func finishReadingAfterTimeout(_ handle: FileHandle, readerGroup: DispatchGroup) {
        if readerGroup.wait(timeout: .now() + outputDrainGraceInterval) == .timedOut {
            close(handle)
            _ = readerGroup.wait(timeout: .now() + outputDrainGraceInterval)
        } else {
            close(handle)
        }
    }

    #if os(macOS) || os(Linux)
        private static func systemClose(_ fd: Int32) {
            #if os(macOS)
                Darwin.close(fd)
            #else
                Glibc.close(fd)
            #endif
        }

        private static func systemKill(_ pid: pid_t, _ signal: Int32) {
            #if os(macOS)
                _ = Darwin.kill(pid, signal)
            #else
                _ = Glibc.kill(pid, signal)
            #endif
        }

        private static func setCloseOnExec(_ fd: Int32) throws {
            #if os(macOS)
                let flags = Darwin.fcntl(fd, F_GETFD)
                guard flags >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard Darwin.fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            #else
                let flags = Glibc.fcntl(fd, F_GETFD)
                guard flags >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard Glibc.fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            #endif
        }

        private static func signalProcessGroup(rootPID: pid_t, _ signal: Int32) {
            guard rootPID > 0 else { return }
            // Primary: process-group signal (posix_spawn SETPGROUP). Skip assistive pgrep tree walk
            // here — `kill(-pgid)` already covers the spawn group; nested pgrep only adds teardown latency.
            systemKill(-rootPID, signal)
        }

        // MARK: Abandoned-child reaper

        private static let abandonedLock = NSLock()
        private static var abandonedPIDs: [pid_t] = []

        private static func noteAbandoned(_ pid: pid_t) {
            guard pid > 0 else { return }
            abandonedLock.lock()
            if !abandonedPIDs.contains(pid) {
                abandonedPIDs.append(pid)
            }
            let count = abandonedPIDs.count
            abandonedLock.unlock()
            if count > maxAbandonedPIDsBeforeFail {
                XCTFail(
                    "TestProcessRunner has \(count) abandoned unreaped child pids "
                        + "(threshold \(maxAbandonedPIDsBeforeFail)). "
                        + "Residual zombies last only for the suite process lifetime; "
                        + "investigate unkillable/D-state children or raise kill coverage."
                )
            }
        }

        private static func noteReaped(_ pid: pid_t) {
            guard pid > 0 else { return }
            abandonedLock.lock()
            abandonedPIDs.removeAll { $0 == pid }
            abandonedLock.unlock()
        }

        /// Best-effort `waitpid(..., WNOHANG)` over previously abandoned pids.
        /// Safe when a background waitpid already reaped the child (ECHILD) or is still waiting (0).
        private static func reapAbandonedChildren() {
            abandonedLock.lock()
            let candidates = abandonedPIDs
            abandonedLock.unlock()
            guard !candidates.isEmpty else { return }

            var stillAbandoned: [pid_t] = []
            for pid in candidates {
                var status: Int32 = 0
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid || (result < 0 && errno == ECHILD) {
                    continue
                }
                stillAbandoned.append(pid)
            }

            abandonedLock.lock()
            // Merge: keep any newly abandoned during reap, drop successfully reaped.
            let newlyAbandoned = abandonedPIDs.filter { !candidates.contains($0) }
            abandonedPIDs = stillAbandoned + newlyAbandoned
            abandonedLock.unlock()
        }

        #if os(macOS)
            private static func signal(_ process: Process, _ signal: Int32) {
                let pid = process.processIdentifier
                guard pid > 0 else { return }
                var remainingNodes = maxProcessTreeWalkNodes
                signalProcessTree(rootPID: pid, signal, depth: 0, remainingNodes: &remainingNodes)
            }

            /// Kill a single Process without walking its tree. Used for nested query helpers
            /// (e.g. pgrep) so hang recovery cannot re-enter signalProcessTree.
            private static func killProcessDirectly(_ process: Process, _ signal: Int32) {
                let pid = process.processIdentifier
                if pid > 0 {
                    systemKill(pid, signal)
                }
                if signal != SIGKILL, process.isRunning {
                    process.terminate()
                }
            }

            /// Best-effort recursive kill assist for Foundation `Process` trees.
            /// Primary kill for the posix_spawn path is `kill(-pgid)`; this walk is assistive only.
            /// Depth/node caps bound teardown latency; after the final grace wait the runner abandons
            /// any still-unreaped waitpid threads (D-state / unkillable edge cases).
            private static func signalProcessTree(
                rootPID: pid_t,
                _ signal: Int32,
                depth: Int,
                remainingNodes: inout Int
            ) {
                remainingNodes -= 1
                if depth < maxProcessTreeWalkDepth, remainingNodes > 0 {
                    for childPID in childPIDs(of: rootPID) {
                        guard remainingNodes > 0 else { break }
                        signalProcessTree(
                            rootPID: childPID,
                            signal,
                            depth: depth + 1,
                            remainingNodes: &remainingNodes
                        )
                    }
                }
                _ = Darwin.kill(rootPID, signal)
            }

            private static func childPIDs(of parentPID: pid_t) -> [pid_t] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                process.arguments = ["-P", "\(parentPID)"]

                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice

                let readerGroup = DispatchGroup()
                let captured = LockedOutput()
                let outputReader = output.fileHandleForReading
                readerGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { readerGroup.leave() }
                    while true {
                        guard let chunk = try? outputReader.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                            break
                        }
                        captured.append(chunk)
                    }
                }

                let terminationGroup = DispatchGroup()
                terminationGroup.enter()
                process.terminationHandler = { _ in
                    terminationGroup.leave()
                }

                do {
                    try process.run()
                } catch {
                    close(output.fileHandleForReading)
                    close(output.fileHandleForWriting)
                    readerGroup.wait()
                    return []
                }
                close(output.fileHandleForWriting)

                if terminationGroup.wait(timeout: .now() + childPIDQueryTimeout) == .timedOut {
                    // Direct kill only — do not call terminate/forceTerminate (those re-enter
                    // signalProcessTree via signal(_:_:) and can amplify hangs with nested pgrep).
                    killProcessDirectly(process, SIGTERM)
                    if terminationGroup.wait(timeout: .now() + terminationGraceInterval) == .timedOut {
                        killProcessDirectly(process, SIGKILL)
                        _ = terminationGroup.wait(timeout: .now() + terminationGraceInterval)
                    }
                    finishReadingAfterTimeout(output.fileHandleForReading, readerGroup: readerGroup)
                    return []
                }

                _ = finishReadingAfterProcessExit(output.fileHandleForReading, readerGroup: readerGroup)
                guard process.terminationStatus == 0 else {
                    return []
                }
                return String(decoding: captured.data(), as: UTF8.self)
                    .split(whereSeparator: \.isNewline)
                    .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }

        #elseif os(Linux)
            private static func signal(_ process: Process, _ signal: Int32) {
                let pid = process.processIdentifier
                guard pid > 0 else { return }
                systemKill(pid, signal)
            }
        #endif

        private static func terminationStatus(fromWaitStatus status: Int32) -> Int32 {
            let signal = status & 0x7F
            if signal == 0 {
                return (status >> 8) & 0xFF
            }
            return 128 + signal
        }
    #endif
}

private final class LockedOutput {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class LockedWaitStatus {
    enum Value {
        case exited(Int32)
        case failed(Int32)
    }

    private let lock = NSLock()
    private var storage: Value?

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ status: Value) {
        lock.lock()
        storage = status
        lock.unlock()
    }
}
