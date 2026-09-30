import Foundation

struct CursorExecutableVersionProbeResult: Equatable {
    let stdout: Data
    let stderr: Data
    let status: Int32
    let timedOut: Bool
}

/// Strict provider-local probe for the reviewed Cursor Agent build. It receives the executable and
/// environment already selected by the login driver and grants no authentication or runtime proof.
struct CursorExecutableVersionProbe {
    struct Invocation: @unchecked Sendable {
        let configuration: CLIProcessConfiguration
        let arguments: [String]
        let timeout: TimeInterval
    }

    typealias ProcessRunner = @Sendable (Invocation) async throws -> CursorExecutableVersionProbeResult

    let timeout: TimeInterval
    private let processRunner: ProcessRunner

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
            return .init(
                stdout: result.stdout,
                stderr: result.stderr,
                status: result.status,
                timedOut: result.timedOut
            )
        }
    ) {
        self.timeout = timeout
        self.processRunner = processRunner
    }

    func probe(executablePath: String, environment: [String: String]) async -> String? {
        guard !Task.isCancelled, executablePath.hasPrefix("/") else { return nil }
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
            guard !Task.isCancelled,
                  result.status == 0,
                  !result.timedOut,
                  result.stderr.isEmpty,
                  CursorFigmaMCPExecutableBuildMatcher.parse(
                      stdout: result.stdout,
                      outputByteLimit: 4 * 1024
                  ) == .accepted
            else { return nil }
            return CursorFigmaMCPToolSurfaceDescriptor.acceptedExecutableBuild
        } catch {
            return nil
        }
    }
}
