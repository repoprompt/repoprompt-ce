import Foundation

enum OMPACPLaunchCandidate: Equatable {
    case ompACP

    var command: String {
        CLILaunchProfiles.omp.commandName
    }

    var launchArguments: [String] {
        ["acp"]
    }

    var helpArguments: [String] {
        ["acp", "--help"]
    }
}

struct OMPACPResolvedLaunch: Equatable {
    let command: String
    let arguments: [String]
    let additionalPathHints: [String]
    let executableIdentity: ExecutableFileIdentity
}

enum OMPACPLaunchResolutionError: Error, Equatable, LocalizedError {
    case missingConfiguredCommand
    case unsafeConfiguredCommand(String)
    case exactPathNotFound(String)
    case noValidLaunchCandidate(String, [String], ShellEnvironmentSource?)
    case environmentDiscoveryRequired(String)
    case unsafeApplicationPath(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguredCommand:
            "Oh My Pi CLI launch requires an exact `omp` command or absolute path."
        case let .unsafeConfiguredCommand(command):
            "Refusing unsafe OMP ACP command `\(command)`. Configure the installed `omp` executable."
        case let .exactPathNotFound(command):
            "Oh My Pi CLI was not found as a valid executable regular file for `\(command)`. Install OMP or configure its absolute `omp` path."
        case let .noValidLaunchCandidate(command, failures, source):
            AgentCLILaunchDiagnostics.appendFallbackEnvironmentHint(
                to: "Oh My Pi CLI was not found as a valid executable regular file for `\(command)`. Tried: \(failures.joined(separator: "; "))",
                source: source
            )
        case let .environmentDiscoveryRequired(command):
            "Oh My Pi CLI path discovery has not completed for `\(command)`. Run the OMP ACP support preflight or configure an absolute `omp` path."
        case let .unsafeApplicationPath(path):
            "Refusing OMP ACP executable inside an application bundle: \(path)"
        }
    }
}

final class OMPACPLaunchResolver: @unchecked Sendable {
    typealias EnvironmentProvider = @Sendable (_ enableDebugLogging: Bool) async -> ACPLaunchEnvironment

    private let environmentProvider: EnvironmentProvider
    private let probeMutex = AsyncMutex()
    private let lock = NSLock()
    private var cachedLaunchByKey: [String: OMPACPResolvedLaunch] = [:]

    convenience init(
        environmentProvider: @escaping @Sendable (_ enableDebugLogging: Bool) async -> [String: String]
    ) {
        self.init(launchEnvironmentProvider: { enableDebugLogging in
            await ACPLaunchEnvironment(environment: environmentProvider(enableDebugLogging))
        })
    }

    init(
        launchEnvironmentProvider: @escaping EnvironmentProvider = { enableDebugLogging in
            let result = await ProcessEnvironmentBuilder.build(
                ProcessEnvironmentRequest(
                    purpose: .acpAgent(providerID: ACPProviderID.omp.rawValue),
                    enableDebugLogging: enableDebugLogging
                )
            )
            return ACPLaunchEnvironment(
                environment: result.environment,
                shellEnvironmentSource: result.shellEnvironmentSource
            )
        }
    ) {
        environmentProvider = launchEnvironmentProvider
    }

    func resolvedLaunch(for config: OMPAgentConfig) throws -> OMPACPResolvedLaunch {
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

    func probeSupport(for config: OMPAgentConfig) async throws -> ACPSupportResult {
        try await probeMutex.withLock { [self] in
            try await probeSupportSerially(for: config)
        }
    }

    private func probeSupportSerially(for config: OMPAgentConfig) async throws -> ACPSupportResult {
        let key = cacheKey(for: config)
        invalidate(key: key)
        do {
            // Resolve from the current effective environment on every support check. The cache only
            // bridges this successful probe to the immediately following launch configuration.
            let launch = try await resolveLaunchForProbe(for: config)
            let processConfig = CLIProcessConfiguration(
                command: launch.command,
                additionalPaths: [],
                enableDebugLogging: config.enableDebugLogging,
                shellLookupMode: .fallbackOnly
            )
            let result = try await CLIProcessRunner(config: processConfig).run(
                args: OMPACPLaunchCandidate.ompACP.helpArguments,
                stdin: nil,
                outputMode: .none,
                timeout: 10,
                cancelChildOnTaskCancellation: true
            )
            guard result.status == 0 else {
                return .unsupported(
                    reason: "Oh My Pi CLI ACP preflight failed: `omp acp --help` exited with status \(result.status)."
                )
            }

            let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            let combined = "\(stdout)\n\(stderr)"
            guard combined.localizedCaseInsensitiveContains("run oh my pi as an acp"),
                  combined.localizedCaseInsensitiveContains("server over stdio")
            else {
                return .unsupported(
                    reason: "Oh My Pi CLI ACP preflight failed: `omp acp --help` did not advertise ACP support."
                )
            }

            try launch.executableIdentity.validateForTrustedPathLaunch(atPath: launch.command)
            cache(launch, key: key)
            return .supported
        } catch is CancellationError {
            invalidate(key: key)
            throw CancellationError()
        } catch {
            invalidate(key: key)
            return .unsupported(reason: error.localizedDescription)
        }
    }

    private func resolveLaunchForProbe(for config: OMPAgentConfig) async throws -> OMPACPResolvedLaunch {
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

        let effectiveHints = CLILaunchProfiles.providerSpecificPathsSupplementedWithNativeDefaults(config.additionalPathHints)
        return try firstValidLaunch(
            candidates: launchCandidates(
                additionalPathHints: effectiveHints,
                environment: environment
            ),
            configuredCommand: configuredCommand,
            additionalPathHints: effectiveHints,
            shellEnvironmentSource: launchEnvironment.shellEnvironmentSource
        )
    }

    private func resolveExplicitLaunch(
        for config: OMPAgentConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shellEnvironmentSource: ShellEnvironmentSource? = nil
    ) throws -> OMPACPResolvedLaunch {
        let configuredCommand = try validatedConfiguredCommand(config)
        guard configuredCommand.contains("/") else {
            throw OMPACPLaunchResolutionError.environmentDiscoveryRequired(configuredCommand)
        }
        let effectiveHints = CLILaunchProfiles.providerSpecificPathsSupplementedWithNativeDefaults(config.additionalPathHints)
        do {
            return try validatedLaunch(
                entryPath: CommandPathResolver.expandPath(configuredCommand, environment: environment),
                configuredCommand: configuredCommand,
                additionalPathHints: effectiveHints
            )
        } catch {
            // Explicit-path failures intentionally keep their specific errors
            // (exactPathNotFound / unsafeApplicationPath) and omit the
            // fallback-PATH hint: an exact configured path does not depend on PATH discovery.
            // Record the same resolution-failure telemetry as other ACP launchers.
            AgentCLILaunchDiagnostics.recordPathResolutionFailure(
                providerKind: .omp,
                shellEnvironmentSource: shellEnvironmentSource,
                candidateCount: 1
            )
            throw error
        }
    }

    private func validatedConfiguredCommand(_ config: OMPAgentConfig) throws -> String {
        let configuredCommand = config.commandName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredCommand.isEmpty else {
            throw OMPACPLaunchResolutionError.missingConfiguredCommand
        }
        let expectedCommand = OMPACPLaunchCandidate.ompACP.command
        if configuredCommand.contains("/") {
            guard (configuredCommand as NSString).lastPathComponent.caseInsensitiveCompare(expectedCommand) == .orderedSame else {
                throw OMPACPLaunchResolutionError.unsafeConfiguredCommand(configuredCommand)
            }
        } else if configuredCommand.caseInsensitiveCompare(expectedCommand) != .orderedSame {
            throw OMPACPLaunchResolutionError.unsafeConfiguredCommand(configuredCommand)
        }
        return configuredCommand
    }

    private func validatedLaunch(
        entryPath: String,
        configuredCommand: String,
        additionalPathHints: [String],
        preserveValidationError: Bool = false
    ) throws -> OMPACPResolvedLaunch {
        guard entryPath.hasPrefix("/"),
              (entryPath as NSString).lastPathComponent.caseInsensitiveCompare(OMPACPLaunchCandidate.ompACP.command) == .orderedSame
        else {
            throw OMPACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }

        let identity: ExecutableFileIdentity
        do {
            identity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: entryPath)
        } catch {
            if preserveValidationError { throw error }
            throw OMPACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }

        if identity.canonicalPath.split(separator: "/").contains(where: { $0.lowercased().hasSuffix(".app") }) {
            throw OMPACPLaunchResolutionError.unsafeApplicationPath(identity.canonicalPath)
        }
        return OMPACPResolvedLaunch(
            command: identity.canonicalPath,
            arguments: OMPACPLaunchCandidate.ompACP.launchArguments,
            additionalPathHints: additionalPathHints,
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
                OMPACPLaunchCandidate.ompACP.command,
                environment: environment,
                additionalPaths: additionalPathHints,
                preferredBasenames: CLILaunchProfiles.omp.preferredBasenames,
                shellLookupMode: .fallbackOnly
            )
        )
        for directory in CommandPathResolver.mergedPathComponents(
            environment: environment,
            additionalPaths: additionalPathHints
        ) {
            append((directory as NSString).appendingPathComponent(OMPACPLaunchCandidate.ompACP.command))
        }
        return candidates
    }

    private func firstValidLaunch(
        candidates: [String],
        configuredCommand: String,
        additionalPathHints: [String],
        shellEnvironmentSource: ShellEnvironmentSource?
    ) throws -> OMPACPResolvedLaunch {
        var failures: [String] = []
        for candidate in candidates {
            do {
                return try validatedLaunch(
                    entryPath: candidate,
                    configuredCommand: configuredCommand,
                    additionalPathHints: additionalPathHints,
                    preserveValidationError: true
                )
            } catch {
                failures.append("\(candidate): \(error.localizedDescription)")
            }
        }
        if failures.isEmpty {
            throw OMPACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }
        AgentCLILaunchDiagnostics.recordPathResolutionFailure(
            providerKind: .omp,
            shellEnvironmentSource: shellEnvironmentSource,
            candidateCount: candidates.count
        )
        throw OMPACPLaunchResolutionError.noValidLaunchCandidate(configuredCommand, failures, shellEnvironmentSource)
    }

    private func cachedLaunch(forKey key: String) -> OMPACPResolvedLaunch? {
        lock.lock()
        defer { lock.unlock() }
        return cachedLaunchByKey[key]
    }

    private func cache(_ launch: OMPACPResolvedLaunch, key: String) {
        lock.lock()
        cachedLaunchByKey[key] = launch
        lock.unlock()
    }

    private func invalidate(key: String) {
        lock.lock()
        cachedLaunchByKey.removeValue(forKey: key)
        lock.unlock()
    }

    private func cacheKey(for config: OMPAgentConfig) -> String {
        ([config.commandName] + config.additionalPathHints).joined(separator: "\u{1F}")
    }
}
