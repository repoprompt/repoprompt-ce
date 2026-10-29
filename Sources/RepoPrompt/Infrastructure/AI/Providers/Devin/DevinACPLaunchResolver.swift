import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptFoundation
import RepoPromptProcess

package enum DevinACPLaunchCandidate: Equatable {
    case devinACP

    package var command: String {
        CLILaunchProfiles.devin.commandName
    }

    package var launchArguments: [String] {
        ["acp"]
    }

    package var helpArguments: [String] {
        ["acp", "--help"]
    }
}

package struct DevinACPResolvedLaunch: Equatable {
    package let command: String
    package let arguments: [String]
    package let additionalPathHints: [String]
    package let environment: [String: String]
    package let executableIdentity: ExecutableFileIdentity
}

package enum DevinACPLaunchResolutionError: Error, Equatable, LocalizedError {
    case missingConfiguredCommand
    case unsafeConfiguredCommand(String)
    case exactPathNotFound(String)
    case noValidLaunchCandidate(String, [String], ShellEnvironmentSource?)
    case environmentDiscoveryRequired(String)
    case unsafeApplicationPath(String)

    package var errorDescription: String? {
        switch self {
        case .missingConfiguredCommand:
            "Devin CLI launch requires an exact `devin` command or absolute path."
        case let .unsafeConfiguredCommand(command):
            "Refusing unsafe Devin ACP command `\(command)`. Configure the installed `devin` executable."
        case let .exactPathNotFound(command):
            "Devin CLI was not found as a valid executable regular file for `\(command)`. Install Devin or configure its absolute `devin` path."
        case let .noValidLaunchCandidate(command, failures, source):
            AgentCLILaunchDiagnostics.appendFallbackEnvironmentHint(
                to: "Devin CLI was not found as a valid executable regular file for `\(command)`. Tried: \(failures.joined(separator: "; "))",
                source: source
            )
        case let .environmentDiscoveryRequired(command):
            "Devin CLI path discovery has not completed for `\(command)`. Run the Devin ACP support preflight or configure an absolute `devin` path."
        case let .unsafeApplicationPath(path):
            "Refusing Devin ACP executable inside an application bundle: \(path)"
        }
    }
}

package final class DevinACPLaunchResolver: @unchecked Sendable {
    package typealias EnvironmentProvider = @Sendable (_ enableDebugLogging: Bool) async -> ACPLaunchEnvironment
    package typealias SupplementalPathProvider = @Sendable (_ configuredPaths: [String]) -> [String]
    package typealias FailureRecorder = @Sendable (_ source: ShellEnvironmentSource?, _ candidateCount: Int) -> Void

    private let environmentProvider: EnvironmentProvider
    private let supplementalPathProvider: SupplementalPathProvider
    private let environmentFilter: CLIProcessConfiguration.EnvironmentFilter
    private let recordFailure: FailureRecorder
    private let probeMutex = AsyncMutex()
    private let lock = NSLock()
    private var cachedLaunchByKey: [String: DevinACPResolvedLaunch] = [:]

    package init(
        launchEnvironmentProvider: @escaping EnvironmentProvider,
        supplementalPathProvider: @escaping SupplementalPathProvider,
        environmentFilter: @escaping CLIProcessConfiguration.EnvironmentFilter,
        failureRecorder: @escaping FailureRecorder
    ) {
        environmentProvider = launchEnvironmentProvider
        self.supplementalPathProvider = supplementalPathProvider
        self.environmentFilter = environmentFilter
        recordFailure = failureRecorder
    }

    package func resolvedLaunch(for config: DevinAgentConfig) throws -> DevinACPResolvedLaunch {
        let key = cacheKey(for: config)
        if let cached = cachedLaunch(forKey: key) {
            do {
                try cached.executableIdentity.validateForTrustedPathLaunch(atPath: cached.command)
                return cached
            } catch {
                invalidate(key: key)
                throw error
            }
        }

        let launch = try resolveExplicitLaunch(for: config)
        cache(launch, key: key)
        return launch
    }

    package func probeSupport(for config: DevinAgentConfig) async throws -> ACPSupportResult {
        try await probeMutex.withLock { [self] in
            try await probeSupportSerially(for: config)
        }
    }

    private func probeSupportSerially(for config: DevinAgentConfig) async throws -> ACPSupportResult {
        let key = cacheKey(for: config)
        do {
            // Resolve from the current effective environment on every support check. The cache only
            // bridges this successful probe to the immediately following launch configuration.
            let launch = try await resolveLaunchForProbe(for: config)
            let processConfig = CLIProcessConfiguration(
                command: launch.command,
                environmentFilter: environmentFilter,
                additionalPaths: [],
                enableDebugLogging: config.enableDebugLogging,
                shellLookupMode: .fallbackOnly
            )
            let result = try await CLIProcessRunner(config: processConfig).run(
                args: DevinACPLaunchCandidate.devinACP.helpArguments,
                stdin: nil,
                outputMode: .none,
                timeout: 10,
                cancelChildOnTaskCancellation: true
            )
            guard result.status == 0 else {
                return .unsupported(
                    reason: "Devin CLI ACP preflight failed: `devin acp --help` exited with status \(result.status)."
                )
            }

            let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            let combined = "\(stdout)\n\(stderr)"
            guard combined.localizedCaseInsensitiveContains("run as an acp"),
                  combined.localizedCaseInsensitiveContains("server over stdio")
            else {
                return .unsupported(
                    reason: "Devin CLI ACP preflight failed: `devin acp --help` did not advertise ACP support."
                )
            }

            try launch.executableIdentity.validateForTrustedPathLaunch(atPath: launch.command)
            cache(launch, key: key)
            return .supported
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unsupported(reason: error.localizedDescription)
        }
    }

    private func resolveLaunchForProbe(for config: DevinAgentConfig) async throws -> DevinACPResolvedLaunch {
        let configuredCommand = try validatedConfiguredCommand(config)
        let launchEnvironment = await environmentProvider(config.enableDebugLogging)
        let environment = launchEnvironment.environment
        try Task.checkCancellation()
        if configuredCommand.contains("/") {
            return try resolveExplicitLaunch(
                for: config,
                environment: environment,
                shellEnvironmentSource: launchEnvironment.shellEnvironmentSource
            )
        }

        let effectiveHints = supplementalPathProvider(config.additionalPathHints)
        return try firstValidLaunch(
            candidates: launchCandidates(
                additionalPathHints: effectiveHints,
                environment: environment
            ),
            configuredCommand: configuredCommand,
            additionalPathHints: effectiveHints,
            environment: environment,
            shellEnvironmentSource: launchEnvironment.shellEnvironmentSource
        )
    }

    private func resolveExplicitLaunch(
        for config: DevinAgentConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shellEnvironmentSource: ShellEnvironmentSource? = nil
    ) throws -> DevinACPResolvedLaunch {
        let configuredCommand = try validatedConfiguredCommand(config)
        guard configuredCommand.contains("/") else {
            throw DevinACPLaunchResolutionError.environmentDiscoveryRequired(configuredCommand)
        }
        let effectiveHints = supplementalPathProvider(config.additionalPathHints)
        do {
            return try validatedLaunch(
                entryPath: CommandPathResolver.expandPath(configuredCommand, environment: environment),
                configuredCommand: configuredCommand,
                additionalPathHints: effectiveHints,
                environment: environment
            )
        } catch {
            // Explicit-path failures intentionally keep their specific errors
            // (exactPathNotFound / unsafeApplicationPath) and omit the
            // fallback-PATH hint: an exact configured path does not depend on PATH discovery.
            // Record the same resolution-failure telemetry as other ACP launchers.
            recordFailure(shellEnvironmentSource, 1)
            throw error
        }
    }

    private func validatedConfiguredCommand(_ config: DevinAgentConfig) throws -> String {
        let configuredCommand = config.commandName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredCommand.isEmpty else {
            throw DevinACPLaunchResolutionError.missingConfiguredCommand
        }
        let expectedCommand = DevinACPLaunchCandidate.devinACP.command
        if configuredCommand.contains("/") {
            guard (configuredCommand as NSString).lastPathComponent.caseInsensitiveCompare(expectedCommand) == .orderedSame else {
                throw DevinACPLaunchResolutionError.unsafeConfiguredCommand(configuredCommand)
            }
        } else if configuredCommand.caseInsensitiveCompare(expectedCommand) != .orderedSame {
            throw DevinACPLaunchResolutionError.unsafeConfiguredCommand(configuredCommand)
        }
        return configuredCommand
    }

    private func validatedLaunch(
        entryPath: String,
        configuredCommand: String,
        additionalPathHints: [String],
        environment: [String: String],
        preserveValidationError: Bool = false
    ) throws -> DevinACPResolvedLaunch {
        guard entryPath.hasPrefix("/"),
              (entryPath as NSString).lastPathComponent.caseInsensitiveCompare(DevinACPLaunchCandidate.devinACP.command) == .orderedSame
        else {
            throw DevinACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }

        let identity: ExecutableFileIdentity
        do {
            identity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: entryPath)
        } catch {
            if preserveValidationError { throw error }
            throw DevinACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }

        if identity.canonicalPath.split(separator: "/").contains(where: { $0.lowercased().hasSuffix(".app") }) {
            throw DevinACPLaunchResolutionError.unsafeApplicationPath(identity.canonicalPath)
        }
        return DevinACPResolvedLaunch(
            command: identity.canonicalPath,
            arguments: DevinACPLaunchCandidate.devinACP.launchArguments,
            additionalPathHints: additionalPathHints,
            environment: environment,
            executableIdentity: identity
        )
    }

    private func launchCandidates(
        additionalPathHints: [String],
        environment: [String: String]
    ) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        func append(_ candidate: String) {
            let expanded = CommandPathResolver.expandPath(candidate, environment: environment)
            guard !expanded.isEmpty,
                  expanded.hasPrefix("/"),
                  seen.insert(expanded).inserted
            else { return }
            candidates.append(expanded)
        }

        append(
            CommandPathResolver.resolve(
                DevinACPLaunchCandidate.devinACP.command,
                environment: environment,
                additionalPaths: additionalPathHints,
                preferredBasenames: CLILaunchProfiles.devin.preferredBasenames,
                shellLookupMode: .fallbackOnly
            )
        )
        for directory in CommandPathResolver.mergedPathComponents(
            environment: environment,
            additionalPaths: additionalPathHints
        ) {
            append((directory as NSString).appendingPathComponent(DevinACPLaunchCandidate.devinACP.command))
        }
        return candidates
    }

    private func firstValidLaunch(
        candidates: [String],
        configuredCommand: String,
        additionalPathHints: [String],
        environment: [String: String],
        shellEnvironmentSource: ShellEnvironmentSource?
    ) throws -> DevinACPResolvedLaunch {
        var failures: [String] = []
        for candidate in candidates {
            do {
                return try validatedLaunch(
                    entryPath: candidate,
                    configuredCommand: configuredCommand,
                    additionalPathHints: additionalPathHints,
                    environment: environment,
                    preserveValidationError: true
                )
            } catch {
                failures.append("\(candidate): \(error.localizedDescription)")
            }
        }
        if failures.isEmpty {
            throw DevinACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }
        recordFailure(shellEnvironmentSource, candidates.count)
        throw DevinACPLaunchResolutionError.noValidLaunchCandidate(configuredCommand, failures, shellEnvironmentSource)
    }

    private func cachedLaunch(forKey key: String) -> DevinACPResolvedLaunch? {
        lock.lock()
        defer { lock.unlock() }
        return cachedLaunchByKey[key]
    }

    private func cache(_ launch: DevinACPResolvedLaunch, key: String) {
        lock.lock()
        cachedLaunchByKey[key] = launch
        lock.unlock()
    }

    private func invalidate(key: String) {
        lock.lock()
        cachedLaunchByKey.removeValue(forKey: key)
        lock.unlock()
    }

    private func cacheKey(for config: DevinAgentConfig) -> String {
        ([config.commandName] + config.additionalPathHints).joined(separator: "\u{1F}")
    }
}
