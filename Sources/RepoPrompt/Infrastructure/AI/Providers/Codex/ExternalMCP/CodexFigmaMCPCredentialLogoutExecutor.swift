import Foundation

/// The only credential-destruction operation RepoPrompt may request from Codex.
/// Server identity, arguments, and Codex state locations are intentionally fixed here.
protocol CodexFigmaMCPCredentialLogoutExecuting: Sendable {
    func logoutFigmaCredential() async -> FigmaMCPCredentialLogoutOutcome
}

enum FigmaMCPCredentialLogoutOutcome: Equatable {
    /// Codex exited successfully. Codex's logout command is idempotent, so this also
    /// represents a credential which was already absent.
    case credentialAbsent
    /// Codex ran and returned a nonzero exit status, or the command could not be prepared.
    case failed
    /// The task was cancelled before a child process was launched.
    case cancelledBeforeLaunch
    /// The command may have started, but its result cannot establish credential absence.
    case indeterminate
}

/// An actor-backed, fixed-purpose executor for `codex mcp logout figma`.
actor CodexFigmaMCPCredentialLogoutExecutor: CodexFigmaMCPCredentialLogoutExecuting {
    typealias EnvironmentBuilder = @Sendable (ProcessEnvironmentRequest) async -> ProcessEnvironmentResult
    typealias RuntimeResolver = @Sendable ([String: String]) -> CodexProviderHelpers.CodexExecutableResolution
    typealias RuntimePreparer = @Sendable (CodexRuntimeAuthority.Runtime) throws -> Void
    struct ProcessInvocation {
        let configuration: CLIProcessConfiguration
        let arguments: [String]
        let timeout: TimeInterval
        let cancelChildOnTaskCancellation: Bool
        let additionalRemovedKeys: Set<String>
        let onProcessStarted: (@Sendable () -> Void)?

        init(
            configuration: CLIProcessConfiguration,
            arguments: [String],
            timeout: TimeInterval,
            cancelChildOnTaskCancellation: Bool,
            additionalRemovedKeys: Set<String> = [],
            onProcessStarted: (@Sendable () -> Void)? = nil
        ) {
            self.configuration = configuration
            self.arguments = arguments
            self.timeout = timeout
            self.cancelChildOnTaskCancellation = cancelChildOnTaskCancellation
            self.additionalRemovedKeys = additionalRemovedKeys
            self.onProcessStarted = onProcessStarted
        }
    }

    typealias ProcessRunner = @Sendable (ProcessInvocation) async throws -> ProcessInvocationResult

    struct ProcessInvocationResult: Equatable {
        let status: Int32
        let timedOut: Bool
    }

    private static let logoutArguments = ["mcp", "logout", "figma"]
    private static let logoutTimeout: TimeInterval = 30
    private static let bootstrapEnvironmentKeys: Set<String> = [
        "PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"
    ]
    private static let runtimeOwnedEnvironmentKeys: Set<String> = [
        "CODEX_HOME", "CODEX_SQLITE_HOME"
    ]

    private let inheritedEnvironment: [String: String]
    private let environmentBuilder: EnvironmentBuilder
    private let runtimeResolver: RuntimeResolver
    private let runtimePreparer: RuntimePreparer
    private let processRunner: ProcessRunner

    private final class ProcessLaunchTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var launched = false

        func markLaunched() {
            lock.withLock { launched = true }
        }

        var didLaunch: Bool {
            lock.withLock { launched }
        }
    }

    init(
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        environmentBuilder: @escaping EnvironmentBuilder = { request in
            await ProcessEnvironmentBuilder.build(request)
        },
        runtimeResolver: @escaping RuntimeResolver = { environment in
            CodexProviderHelpers.resolveCodexExecutable(environment: environment)
        },
        runtimePreparer: @escaping RuntimePreparer = { runtime in
            try runtime.prepareState()
        },
        processRunner: @escaping ProcessRunner = { invocation in
            let result = try await CLIProcessRunner(config: invocation.configuration).run(
                args: invocation.arguments,
                stdin: nil,
                outputMode: .none,
                timeout: invocation.timeout,
                additionalRemovedKeys: invocation.additionalRemovedKeys,
                cancelChildOnTaskCancellation: invocation.cancelChildOnTaskCancellation,
                onProcessStarted: invocation.onProcessStarted
            )
            return .init(status: result.status, timedOut: result.timedOut)
        }
    ) {
        self.inheritedEnvironment = inheritedEnvironment
        self.environmentBuilder = environmentBuilder
        self.runtimeResolver = runtimeResolver
        self.runtimePreparer = runtimePreparer
        self.processRunner = processRunner
    }

    func logoutFigmaCredential() async -> FigmaMCPCredentialLogoutOutcome {
        guard !Task.isCancelled else { return .cancelledBeforeLaunch }

        let environmentResult = await environmentBuilder(.init(
            purpose: .codexCredentialLogout,
            inheritedEnvironment: inheritedEnvironment,
            enableDebugLogging: false
        ))
        guard !Task.isCancelled else { return .cancelledBeforeLaunch }

        // Codex logout receives only the small bootstrap environment needed to resolve and
        // launch the verified runtime. Ambient credentials and unrelated variables are excluded.
        let bootstrapEnvironment = environmentResult.environment.filter { key, _ in
            Self.bootstrapEnvironmentKeys.contains(key)
        }
        let resolution = runtimeResolver(bootstrapEnvironment)
        guard resolution.status == .available,
              let runtime = resolution.runtime
        else { return .failed }
        let environmentOverrides = resolution.environmentOverrides
        guard environmentOverrides.keys.allSatisfy(Self.runtimeOwnedEnvironmentKeys.contains) else {
            return .failed
        }

        do {
            try runtimePreparer(runtime)
        } catch {
            return .failed
        }
        guard !Task.isCancelled else { return .cancelledBeforeLaunch }

        // Runtime-owned state paths win over shell and inherited values. The command itself is
        // also the resolved absolute executable, avoiding PATH lookup by the process runner.
        var environment = bootstrapEnvironment
        environment.merge(environmentOverrides) { _, ownedValue in ownedValue }
        let ambientEnvironmentKeys = Set(environmentResult.environment.keys).union(inheritedEnvironment.keys)
        let removedEnvironmentKeys = ambientEnvironmentKeys.subtracting(environment.keys)
        let configuration = CLIProcessConfiguration(
            command: resolution.resolvedCommand,
            workingDirectory: nil,
            environment: environment,
            additionalPaths: [],
            commandSuffix: [],
            enableDebugLogging: false,
            logCollector: nil,
            resolveCandidates: [resolution.resolvedCommand],
            shellLookupMode: .preferShell,
            captureStdoutTailBytes: 0,
            captureStderrTailBytes: 0,
            logStdinSampleBytes: 0,
            discardOutput: true
        )

        let launchTracker = ProcessLaunchTracker()
        do {
            let result = try await processRunner(.init(
                configuration: configuration,
                arguments: Self.logoutArguments,
                timeout: Self.logoutTimeout,
                cancelChildOnTaskCancellation: true,
                additionalRemovedKeys: removedEnvironmentKeys,
                onProcessStarted: { launchTracker.markLaunched() }
            ))
            guard !Task.isCancelled else { return .indeterminate }
            if result.timedOut { return .indeterminate }
            return result.status == 0 ? .credentialAbsent : .failed
        } catch is CancellationError {
            return launchTracker.didLaunch ? .indeterminate : .cancelledBeforeLaunch
        } catch {
            // A spawn failure is settled failure. Any error after the launch marker is
            // indeterminate because it cannot establish whether logout completed.
            return launchTracker.didLaunch ? .indeterminate : .failed
        }
    }
}
