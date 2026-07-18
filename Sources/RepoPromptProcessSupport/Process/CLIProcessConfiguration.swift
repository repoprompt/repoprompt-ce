import Foundation

package struct CLIProcessConfiguration {
    package var command: String
    /// Working directory for the CLI process. Defaults to temp directory to avoid macOS security popups.
    package var workingDirectory: String
    package var environment: [String: String]
    package var additionalPaths: [String]
    package var commandSuffix: [String]
    package var enableDebugLogging: Bool
    package var logCollector: CLIProcessLogCollector?
    /// Optional: explicit basenames we prefer to resolve to (e.g., ["claude", "codex"]).
    /// If omitted, the resolver will prefer `command` and otherwise behave as before.
    package var resolveCandidates: [String]?
    /// Controls whether command resolution queries the user's shell before or after PATH search.
    package var shellLookupMode: CommandPathResolver.ShellLookupMode
    /// Limit how many bytes from child stdout/stderr we retain (per stream).
    package var captureStdoutTailBytes: Int
    package var captureStderrTailBytes: Int
    /// Limit how many bytes of stdin we sample for logs (0 disables sampling).
    package var logStdinSampleBytes: Int

    package init(
        command: String = "claude",
        workingDirectory: String? = nil, // nil → temp directory to avoid macOS security popups
        environment: [String: String] = [:],
        additionalPaths: [String] = CLINativePathDefaults.defaultAdditionalPaths,
        commandSuffix: [String] = [],
        enableDebugLogging: Bool = false,
        logCollector: CLIProcessLogCollector? = nil,
        resolveCandidates: [String]? = nil,
        shellLookupMode: CommandPathResolver.ShellLookupMode = .preferShell,
        captureStdoutTailBytes: Int = 0,
        captureStderrTailBytes: Int = 256 * 1024,
        logStdinSampleBytes: Int = 0
    ) {
        self.command = command
        self.workingDirectory = workingDirectory ?? FileManager.default.temporaryDirectory.path
        self.environment = environment
        self.additionalPaths = additionalPaths
        self.commandSuffix = commandSuffix
        self.enableDebugLogging = enableDebugLogging
        self.logCollector = logCollector
        self.resolveCandidates = resolveCandidates
        self.shellLookupMode = shellLookupMode
        self.captureStdoutTailBytes = captureStdoutTailBytes
        self.captureStderrTailBytes = captureStderrTailBytes
        self.logStdinSampleBytes = logStdinSampleBytes
    }
}
