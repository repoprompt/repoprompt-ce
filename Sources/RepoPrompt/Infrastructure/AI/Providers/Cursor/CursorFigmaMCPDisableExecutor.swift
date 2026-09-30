import Foundation

enum CursorFigmaMCPDisableOutcome: Equatable {
    case disabled
    case failed
    case timedOut
    case cancelled
}

protocol CursorFigmaMCPDisableExecuting: Sendable {
    func disable(
        retainedLaunch launch: FigmaMCPProviderResolvedLoginLaunch
    ) async -> CursorFigmaMCPDisableOutcome
}

/// Fixed-purpose executor for `cursor-agent mcp disable figma`. It deliberately accepts only the
/// exact nonsecret launch retained by the reviewed login flow, and never resolves an executable,
/// environment, configuration, or credential state on its own.
struct CursorFigmaMCPDisableExecutor: CursorFigmaMCPDisableExecuting {
    struct ProcessInvocation: @unchecked Sendable {
        let configuration: CLIProcessConfiguration
        let arguments: [String]
        let timeout: TimeInterval
        let cancelChildOnTaskCancellation: Bool
    }

    struct ProcessResult: Equatable {
        let status: Int32
        let timedOut: Bool
    }

    typealias ProcessRunner = @Sendable (ProcessInvocation) async throws -> ProcessResult

    private static let disableArguments = ["mcp", "disable", "figma"]
    private static let disableTimeout: TimeInterval = 30

    private let processRunner: ProcessRunner

    init(
        processRunner: @escaping ProcessRunner = { invocation in
            let result = try await CLIProcessRunner(config: invocation.configuration).run(
                args: invocation.arguments,
                stdin: nil,
                outputMode: .none,
                timeout: invocation.timeout,
                cancelChildOnTaskCancellation: invocation.cancelChildOnTaskCancellation
            )
            return .init(status: result.status, timedOut: result.timedOut)
        }
    ) {
        self.processRunner = processRunner
    }

    func disable(
        retainedLaunch launch: FigmaMCPProviderResolvedLoginLaunch
    ) async -> CursorFigmaMCPDisableOutcome {
        guard !Task.isCancelled,
              launch.executableVersion == CursorFigmaMCPToolSurfaceDescriptor.acceptedExecutableBuild
        else { return Task.isCancelled ? .cancelled : .failed }

        do {
            // Revalidate immediately before the pathname-based spawn. The already-sanitized login
            // environment is reused unchanged, and the restricted configuration disables lookup
            // and output capture.
            try launch.executableIdentity.validateForTrustedPathLaunch(
                atPath: launch.executableIdentity.canonicalPath
            )
            var configuration = try CLIProcessConfiguration.validatedFigmaProviderLogin(
                executablePath: launch.executableIdentity.canonicalPath
            )
            configuration.environment = launch.environment
            guard !Task.isCancelled else { return .cancelled }

            let result = try await processRunner(.init(
                configuration: configuration,
                arguments: Self.disableArguments,
                timeout: Self.disableTimeout,
                cancelChildOnTaskCancellation: true
            ))
            guard !Task.isCancelled else { return .cancelled }
            if result.timedOut { return .timedOut }
            return result.status == 0 ? .disabled : .failed
        } catch is CancellationError {
            return .cancelled
        } catch {
            return Task.isCancelled ? .cancelled : .failed
        }
    }
}
