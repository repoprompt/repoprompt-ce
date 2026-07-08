import Foundation
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
    static let defaultTimeout: TimeInterval = 30
    private static let terminationGraceInterval: TimeInterval = 1
    private static let outputDrainGraceInterval: TimeInterval = 1
    private static let childPIDQueryTimeout: TimeInterval = 1

    static func run(
        executableURL: URL,
        arguments: [String] = [],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = defaultTimeout
    ) throws -> TestProcessResult {
        #if os(macOS) || os(Linux)
            try runWithSpawnedProcessGroup(
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
        let statusBox = LockedStatus()
        let spawnedPID = pid
        terminationGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var status: Int32 = 0
            while waitpid(spawnedPID, &status, 0) < 0, errno == EINTR {}
            statusBox.set(status)
            terminationGroup.leave()
        }

        if terminationGroup.wait(timeout: .now() + timeout) == .timedOut {
            signalProcessGroup(rootPID: pid, SIGTERM)
            if terminationGroup.wait(timeout: .now() + terminationGraceInterval) == .timedOut {
                signalProcessGroup(rootPID: pid, SIGKILL)
                _ = terminationGroup.wait(timeout: .now() + terminationGraceInterval)
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

        let status = terminationStatus(fromWaitStatus: statusBox.status)
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

    private static func signalProcessGroup(rootPID: pid_t, _ signal: Int32) {
        guard rootPID > 0 else { return }
        systemKill(-rootPID, signal)
        #if os(macOS)
        signalProcessTree(rootPID: rootPID, signal)
        #endif
    }

    #if os(macOS)
    private static func signal(_ process: Process, _ signal: Int32) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        signalProcessTree(rootPID: pid, signal)
    }

    private static func signalProcessTree(rootPID: pid_t, _ signal: Int32) {
        for childPID in childPIDs(of: rootPID) {
            signalProcessTree(rootPID: childPID, signal)
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
            terminate(process)
            if terminationGroup.wait(timeout: .now() + terminationGraceInterval) == .timedOut {
                forceTerminate(process)
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

private final class LockedStatus {
    private let lock = NSLock()
    private var storage: Int32 = 0

    var status: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ status: Int32) {
        lock.lock()
        storage = status
        lock.unlock()
    }
}
