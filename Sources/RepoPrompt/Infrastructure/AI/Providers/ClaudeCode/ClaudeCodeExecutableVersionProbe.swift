import Foundation

struct ClaudeCodeExecutableVersionProbeResult: Equatable {
    let stdout: Data
    let stderr: Data
    let status: Int32
    let timedOut: Bool
}

/// A strict, provider-owned `claude --version` probe.
///
/// The probe receives the already-resolved canonical executable path and the exact environment
/// selected by the login driver. It only reports a version; it does not establish authentication,
/// Figma connectivity, or runtime authority.
struct ClaudeCodeExecutableVersionProbe {
    struct Invocation: @unchecked Sendable {
        let configuration: CLIProcessConfiguration
        let arguments: [String]
        let timeout: TimeInterval
    }

    typealias ProcessRunner = @Sendable (Invocation) async throws -> ClaudeCodeExecutableVersionProbeResult
    typealias VersionParser = @Sendable (ClaudeCodeExecutableVersionProbeResult) -> String?

    let timeout: TimeInterval
    private let processRunner: ProcessRunner
    private let versionParser: VersionParser

    init(
        timeout: TimeInterval = 10,
        processRunner: @escaping ProcessRunner = { invocation in
            let result = try await CLIProcessRunner(config: invocation.configuration).run(
                args: invocation.arguments,
                stdin: nil,
                outputMode: .none,
                timeout: invocation.timeout,
                cancelChildOnTaskCancellation: true
            )
            return ClaudeCodeExecutableVersionProbeResult(
                stdout: result.stdout,
                stderr: result.stderr,
                status: result.status,
                timedOut: result.timedOut
            )
        },
        versionParser: @escaping VersionParser = ClaudeCodeExecutableVersionParser.parse
    ) {
        self.timeout = timeout
        self.processRunner = processRunner
        self.versionParser = versionParser
    }

    func probe(
        executablePath: String,
        environment: [String: String]
    ) async -> String? {
        guard executablePath.hasPrefix("/") else { return nil }
        let configuration = CLIProcessConfiguration(
            command: executablePath,
            workingDirectory: nil,
            environment: environment,
            additionalPaths: [],
            launchPurpose: .figmaProviderLogin,
            requiresAbsoluteExecutable: true,
            shellLookupMode: .disabled,
            captureStdoutTailBytes: 4 * 1024,
            captureStderrTailBytes: 4 * 1024,
            logStdinSampleBytes: 0,
            discardOutput: false
        )
        do {
            let result = try await processRunner(.init(
                configuration: configuration,
                arguments: ["--version"],
                timeout: timeout
            ))
            guard !Task.isCancelled else { return nil }
            return versionParser(result)
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }
    }
}

enum ClaudeCodeExecutableVersionParser {
    /// Parses only the complete, single-line Claude Code version response. The accepted forms are
    /// the current bare CLI output and its documented display-labelled equivalents; arbitrary
    /// numbers embedded in diagnostics are rejected.
    static func parse(_ result: ClaudeCodeExecutableVersionProbeResult) -> String? {
        guard result.status == 0, !result.timedOut,
              let stdout = String(data: result.stdout, encoding: .utf8)
        else { return nil }
        guard let stderr = String(data: result.stderr, encoding: .utf8),
              stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let output = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, !output.contains(where: \.isNewline) else { return nil }
        let version: String
        if let bare = strictVersion(in: output) {
            version = bare
        } else if output.hasPrefix("claude "),
                  let bare = strictVersion(in: String(output.dropFirst("claude ".count)))
        {
            version = bare
        } else if output.hasSuffix(" (Claude Code)"),
                  let bare = strictVersion(in: String(output.dropLast(" (Claude Code)".count)))
        {
            version = bare
        } else {
            return nil
        }
        return version
    }

    private static func strictVersion(in value: String) -> String? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.compactMap({ Int($0) }).count == 3
        else { return nil }
        return value
    }
}
