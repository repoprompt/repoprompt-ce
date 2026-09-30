import Foundation

struct CLIProcessConfiguration {
    static func resolvedWorkingDirectory(_ workingDirectory: String?) -> String {
        workingDirectory ?? FileManager.default.temporaryDirectory.path
    }

    /// Creates the restricted launch profile used by provider-owned Figma login commands.
    static func validatedFigmaProviderLogin(executablePath: String) throws -> Self {
        guard executablePath.hasPrefix("/"),
              !executablePath.contains("/../"),
              FileManager.default.isExecutableFile(atPath: executablePath)
        else {
            throw ValidationError.invalidAbsoluteExecutable(executablePath)
        }
        return Self(
            command: executablePath,
            additionalPaths: [],
            launchPurpose: .figmaProviderLogin,
            requiresAbsoluteExecutable: true,
            enableDebugLogging: false,
            logCollector: nil,
            shellLookupMode: .disabled,
            captureStdoutTailBytes: 0,
            captureStderrTailBytes: 0,
            logStdinSampleBytes: 0,
            discardOutput: true
        )
    }

    enum ValidationError: Error, Equatable {
        case invalidAbsoluteExecutable(String)
    }

    var command: String
    /// Working directory for the CLI process. Defaults to temp directory to avoid macOS security popups.
    var workingDirectory: String
    var environment: [String: String]
    var additionalPaths: [String]
    var commandSuffix: [String]
    /// Selects the environment policy used by the child launch.
    var launchPurpose: ProcessLaunchPurpose
    /// When enabled, `command` must already be an absolute executable path; no lookup occurs.
    var requiresAbsoluteExecutable: Bool
    var enableDebugLogging: Bool
    var logCollector: CLIProcessLogCollector?
    /// Optional: explicit basenames we prefer to resolve to (e.g., ["claude", "codex"]).
    /// If omitted, the resolver will prefer `command` and otherwise behave as before.
    var resolveCandidates: [String]?
    /// Controls whether command resolution queries the user's shell before or after PATH search.
    var shellLookupMode: CommandPathResolver.ShellLookupMode
    /// Limit how many bytes from child stdout/stderr we retain (per stream).
    var captureStdoutTailBytes: Int
    var captureStderrTailBytes: Int
    /// Limit how many bytes of stdin we sample for logs (0 disables sampling).
    var logStdinSampleBytes: Int
    /// Discard child stdout and stderr instead of returning or retaining them.
    var discardOutput: Bool

    init(
        command: String = "claude",
        workingDirectory: String? = nil, // nil → temp directory to avoid macOS security popups
        environment: [String: String] = [:],
        additionalPaths: [String] = CLINativePathDefaults.defaultAdditionalPaths,
        commandSuffix: [String] = [],
        launchPurpose: ProcessLaunchPurpose = .cliRunner,
        requiresAbsoluteExecutable: Bool = false,
        enableDebugLogging: Bool = false,
        logCollector: CLIProcessLogCollector? = nil,
        resolveCandidates: [String]? = nil,
        shellLookupMode: CommandPathResolver.ShellLookupMode = .preferShell,
        captureStdoutTailBytes: Int = 0,
        captureStderrTailBytes: Int = 256 * 1024,
        logStdinSampleBytes: Int = 0,
        discardOutput: Bool = false
    ) {
        self.command = command
        self.workingDirectory = Self.resolvedWorkingDirectory(workingDirectory)
        self.environment = environment
        self.additionalPaths = additionalPaths
        self.commandSuffix = commandSuffix
        self.launchPurpose = launchPurpose
        self.requiresAbsoluteExecutable = requiresAbsoluteExecutable
        self.enableDebugLogging = enableDebugLogging
        self.logCollector = logCollector
        self.resolveCandidates = resolveCandidates
        self.shellLookupMode = shellLookupMode
        self.captureStdoutTailBytes = captureStdoutTailBytes
        self.captureStderrTailBytes = captureStderrTailBytes
        self.logStdinSampleBytes = logStdinSampleBytes
        self.discardOutput = discardOutput
    }
}
