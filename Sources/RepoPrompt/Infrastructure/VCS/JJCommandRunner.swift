import CryptoKit
import Foundation

// MARK: - JJ Command Runner

/// Actor for executing Jujutsu (jj) commands safely.
/// Uses the same async stream pipe pattern as GitService.runGit for reliable output handling.
public actor JJCommandRunner {
    // MARK: - Types

    public struct JJError: LocalizedError {
        public let message: String
        public var errorDescription: String? {
            message
        }

        public init(_ message: String) {
            self.message = message
        }
    }

    // MARK: - Properties

    /// Resolved path to the jj executable (cached after first resolution).
    private var resolvedExecutablePath: String?

    /// Cached environment for command execution.
    private var cachedEnvironment: [String: String]?

    // MARK: - Initialization

    public init() {}

    // MARK: - Public API

    /// Check if jj is available on this system.
    /// - Returns: True if jj executable is found.
    public func isAvailable() async -> Bool {
        do {
            _ = try await resolveExecutable()
            return true
        } catch {
            return false
        }
    }

    /// Get the resolved path to the jj executable.
    /// - Returns: The path to jj, or nil if not found.
    public func getExecutablePath() async -> String? {
        try? await resolveExecutable()
    }

    /// Run a jj command and return the output.
    /// - Parameters:
    ///   - args: The arguments to pass to jj (not including the jj command itself).
    ///   - at: The working directory for the command.
    ///   - stdin: Optional stdin data to send to the process.
    /// - Returns: Tuple of (stdout, stderr, exitCode).
    public func run(
        _ args: [String],
        at repoURL: URL,
        stdin: Data? = nil
    ) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let executable = try await resolveExecutable()
        let environment = try await getEnvironment()

        return try await runProcess(
            executable: executable,
            args: args,
            at: repoURL,
            environment: environment,
            stdin: stdin
        )
    }

    /// Run a jj command and return stdout, throwing on non-zero exit.
    /// - Parameters:
    ///   - args: The arguments to pass to jj.
    ///   - at: The working directory for the command.
    /// - Returns: The stdout output.
    public func runOrThrow(
        _ args: [String],
        at repoURL: URL
    ) async throws -> String {
        let (stdout, stderr, exitCode) = try await run(args, at: repoURL)
        guard exitCode == 0 else {
            let command = "jj " + args.joined(separator: " ")
            throw JJError("Command '\(command)' failed with exit code \(exitCode): \(stderr)")
        }
        return stdout
    }

    /// Compute SHA256 hash of data.
    public func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Private Implementation

    /// Resolve the jj executable path using CommandPathResolver.
    private func resolveExecutable() async throws -> String {
        if let cached = resolvedExecutablePath {
            return cached
        }

        // Try to resolve using the command path resolver infrastructure
        let environment = try await getEnvironment()

        // Check common locations in order of preference
        let searchPaths = [
            "/opt/homebrew/bin", // Apple Silicon Homebrew
            "/usr/local/bin", // Intel Homebrew / manual installs
            "/usr/bin", // System
            "~/.cargo/bin" // Cargo install
        ].map { ($0 as NSString).expandingTildeInPath }

        // First, check if it's in PATH
        if let pathEnv = environment["PATH"] {
            let pathDirs = pathEnv.split(separator: ":").map(String.init)
            for dir in pathDirs {
                let candidate = (dir as NSString).appendingPathComponent("jj")
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    resolvedExecutablePath = candidate
                    return candidate
                }
            }
        }

        // Then check common locations
        for dir in searchPaths {
            let candidate = (dir as NSString).appendingPathComponent("jj")
            if FileManager.default.isExecutableFile(atPath: candidate) {
                resolvedExecutablePath = candidate
                return candidate
            }
        }

        throw VCSError.executableNotFound(name: "jj")
    }

    /// Get the environment for command execution.
    private func getEnvironment() async throws -> [String: String] {
        if let cached = cachedEnvironment {
            return cached
        }

        // Start with current environment
        var env = ProcessInfo.processInfo.environment

        // Get login shell environment for proper PATH using the public API
        let shellEnv = await CLIEnvironmentCache.shared.environment(enableLogging: false)
        env.merge(shellEnv) { _, new in new }

        // Ensure no interactive prompts
        env["JJ_TERMINAL_PROMPT"] = "0"

        cachedEnvironment = env
        return env
    }

    /// Run a process with async stream pipe handling.
    /// This mirrors the pattern in GitService.runGit for reliable output collection.
    private func runProcess(
        executable: String,
        args: [String],
        at repoURL: URL,
        environment: [String: String],
        stdin: Data?
    ) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = repoURL
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var inPipe: Pipe?
        if stdin != nil {
            let p = Pipe()
            process.standardInput = p
            inPipe = p
            // Suppress SIGPIPE
            let fd = p.fileHandleForWriting.fileDescriptor
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        } else {
            // Set stdin to null device to prevent blocked subprocess
            process.standardInput = FileHandle.nullDevice
        }

        // Build async streams for stdout/stderr
        final class SendableContinuation: @unchecked Sendable {
            private let _cont: AsyncStream<Data>.Continuation
            init(_ c: AsyncStream<Data>.Continuation) {
                _cont = c
            }

            func yield(_ d: Data) {
                _cont.yield(d)
            }

            func finish() {
                _cont.finish()
            }
        }

        var outBox: SendableContinuation!
        let outStream = AsyncStream<Data>(bufferingPolicy: .unbounded) { cont in
            outBox = SendableContinuation(cont)
        }
        var errBox: SendableContinuation!
        let errStream = AsyncStream<Data>(bufferingPolicy: .unbounded) { cont in
            errBox = SendableContinuation(cont)
        }

        let outC = outBox!
        let errC = errBox!

        let outCollector = Task(priority: .userInitiated) { () -> Data in
            var buf = Data()
            for await chunk in outStream {
                if !chunk.isEmpty { buf.append(chunk) }
            }
            return buf
        }
        let errCollector = Task(priority: .userInitiated) { () -> Data in
            var buf = Data()
            for await chunk in errStream {
                if !chunk.isEmpty { buf.append(chunk) }
            }
            return buf
        }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                // Drain stdout
                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if !chunk.isEmpty { outC.yield(chunk) }
                }
                // Drain stderr
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if !chunk.isEmpty { errC.yield(chunk) }
                }

                process.terminationHandler = { proc in
                    // Stop handlers
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil

                    // Read any remaining bytes
                    let outTail = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errTail = errPipe.fileHandleForReading.readDataToEndOfFile()

                    if !outTail.isEmpty { outC.yield(outTail) }
                    if !errTail.isEmpty { errC.yield(errTail) }
                    outC.finish()
                    errC.finish()

                    Task {
                        let stdoutData = await outCollector.value
                        let stderrData = await errCollector.value

                        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                        continuation.resume(returning: (stdout, stderr, proc.terminationStatus))
                    }
                }

                do {
                    try process.run()

                    // Write stdin if provided.
                    // Use raw FD writes via FDWriteSupport instead of FileHandle.write()
                    // because FileHandle.write() throws ObjC NSFileHandleOperationException
                    // on broken pipe, which Swift do/catch cannot intercept.
                    if let stdin, let inPipe {
                        let fd = inPipe.fileHandleForWriting.fileDescriptor
                        do {
                            try FDWriteSupport.writeAll(stdin, to: fd)
                        } catch {
                            // Broken pipe / bad fd — child exited or was terminated.
                            // Swallow; termination handler collects output.
                        }
                        inPipe.fileHandleForWriting.closeFile()
                    }
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            outC.finish()
            errC.finish()
            if process.isRunning {
                process.terminate()
            }
        })
    }
}
