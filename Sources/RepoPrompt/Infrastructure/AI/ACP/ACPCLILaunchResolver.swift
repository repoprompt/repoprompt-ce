import Foundation

/// Launch configuration an ACP provider hands to `ACPCLILaunchResolver`. `Sendable` because
/// the serialized preflight captures it in a `@Sendable` closure.
protocol ACPCLILaunchConfiguring: Sendable {
    /// Either the profile's bare command name or an absolute path to it.
    var commandName: String { get }
    var additionalPathHints: [String] { get }
    var enableDebugLogging: Bool { get }
}

/// The provider-specific facts of a `<cli> acp`-style stdio launch. Candidate ordering,
/// executable-identity capture, caching, and the `--help` preflight are shared.
struct ACPCLILaunchSpec {
    let providerID: ACPProviderID
    let providerKind: AgentProviderKind
    /// Product name used verbatim in every user-facing diagnostic ("Devin", "Oh My Pi").
    let displayName: String
    let profile: CLILaunchProfile
    let launchArguments: [String]
    let helpArguments: [String]
    /// Case-insensitive substrings the preflight output must ALL contain before the
    /// installed CLI counts as ACP-capable.
    let requiredHelpAdvertisements: [String]

    var commandName: String {
        profile.commandName
    }

    fileprivate var helpInvocation: String {
        ([commandName] + helpArguments).joined(separator: " ")
    }
}

struct ACPCLIResolvedLaunch: Equatable {
    let command: String
    let arguments: [String]
    let additionalPathHints: [String]
    /// The effective child environment this resolution was performed against. Providers
    /// that overlay isolated configuration (Devin's `XDG_CONFIG_HOME`) read the native
    /// `HOME`/`XDG_CONFIG_HOME` from here instead of re-deriving them.
    let environment: [String: String]
    let executableIdentity: ExecutableFileIdentity
}

enum ACPCLILaunchResolutionError: Error, Equatable, LocalizedError {
    case missingConfiguredCommand(agent: String, expected: String)
    case unsafeConfiguredCommand(agent: String, command: String)
    case exactPathNotFound(agent: String, command: String)
    case noValidLaunchCandidate(agent: String, command: String, failures: [String], source: ShellEnvironmentSource?)
    case environmentDiscoveryRequired(agent: String, command: String)
    case unsafeApplicationPath(agent: String, path: String)

    var errorDescription: String? {
        switch self {
        case let .missingConfiguredCommand(agent, expected):
            "\(agent) CLI launch requires an exact `\(expected)` command or absolute path."
        case let .unsafeConfiguredCommand(agent, command):
            "Refusing unsafe \(agent) ACP command `\(command)`. Configure the installed executable."
        case let .exactPathNotFound(agent, command):
            "\(agent) CLI was not found as a valid executable regular file for `\(command)`. Install \(agent) or configure its absolute path."
        case let .noValidLaunchCandidate(agent, command, failures, source):
            AgentCLILaunchDiagnostics.appendFallbackEnvironmentHint(
                to: "\(agent) CLI was not found as a valid executable regular file for `\(command)`. Tried: \(failures.joined(separator: "; "))",
                source: source
            )
        case let .environmentDiscoveryRequired(agent, command):
            "\(agent) CLI path discovery has not completed for `\(command)`. Run the \(agent) ACP support preflight or configure an absolute path."
        case let .unsafeApplicationPath(agent, path):
            "Refusing \(agent) ACP executable inside an application bundle: \(path)"
        }
    }
}

/// Shared resolver for ACP providers whose runtime is a locally installed CLI invoked as
/// `<command> acp` over stdio. Behavior matches the per-provider resolvers it generalizes:
/// only the profile's exact basename is accepted, executables inside `.app` bundles are
/// refused, and the resolution cache exists only to bridge a successful `probeSupport`
/// to the launch configuration that immediately follows it.
final class ACPCLILaunchResolver: @unchecked Sendable {
    typealias EnvironmentProvider = @Sendable (_ enableDebugLogging: Bool) async -> ACPLaunchEnvironment

    let spec: ACPCLILaunchSpec

    private let environmentProvider: EnvironmentProvider
    private let probeMutex = AsyncMutex()
    private let lock = NSLock()
    private var cachedLaunchByKey: [String: ACPCLIResolvedLaunch] = [:]

    init(
        spec: ACPCLILaunchSpec,
        launchEnvironmentProvider: EnvironmentProvider? = nil
    ) {
        self.spec = spec
        environmentProvider = launchEnvironmentProvider ?? { enableDebugLogging in
            let result = await ProcessEnvironmentBuilder.build(
                ProcessEnvironmentRequest(
                    purpose: .acpAgent(providerID: spec.providerID.rawValue),
                    enableDebugLogging: enableDebugLogging
                )
            )
            return ACPLaunchEnvironment(
                environment: result.environment,
                shellEnvironmentSource: result.shellEnvironmentSource
            )
        }
    }

    /// Convenience for tests: supply the child environment without a shell-capture source.
    convenience init(
        spec: ACPCLILaunchSpec,
        environmentProvider: @escaping @Sendable (_ enableDebugLogging: Bool) async -> [String: String]
    ) {
        self.init(spec: spec, launchEnvironmentProvider: { enableDebugLogging in
            await ACPLaunchEnvironment(environment: environmentProvider(enableDebugLogging))
        })
    }

    func resolvedLaunch(for config: some ACPCLILaunchConfiguring) throws -> ACPCLIResolvedLaunch {
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

    func probeSupport(for config: some ACPCLILaunchConfiguring) async throws -> ACPSupportResult {
        try await probeMutex.withLock { [self] in
            try await probeSupportSerially(for: config)
        }
    }

    private func probeSupportSerially(for config: some ACPCLILaunchConfiguring) async throws -> ACPSupportResult {
        let key = cacheKey(for: config)
        invalidate(key: key)
        do {
            // Resolve from the current effective environment on every support check.
            let launch = try await resolveLaunchForProbe(for: config)
            let result = try await CLIProcessRunner(
                config: CLIProcessConfiguration(
                    command: launch.command,
                    additionalPaths: [],
                    enableDebugLogging: config.enableDebugLogging,
                    shellLookupMode: .fallbackOnly
                )
            ).run(
                args: spec.helpArguments,
                stdin: nil,
                outputMode: .none,
                timeout: 10,
                cancelChildOnTaskCancellation: true
            )
            guard result.status == 0 else {
                return .unsupported(
                    reason: "\(spec.displayName) CLI ACP preflight failed: `\(spec.helpInvocation)` exited with status \(result.status)."
                )
            }

            let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            let combined = "\(stdout)\n\(stderr)"
            guard spec.requiredHelpAdvertisements.allSatisfy(combined.localizedCaseInsensitiveContains) else {
                return .unsupported(
                    reason: "\(spec.displayName) CLI ACP preflight failed: `\(spec.helpInvocation)` did not advertise ACP support."
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

    private func resolveLaunchForProbe(for config: some ACPCLILaunchConfiguring) async throws -> ACPCLIResolvedLaunch {
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

        let hints = effectiveHints(for: config)
        return try firstValidLaunch(
            candidates: launchCandidates(additionalPathHints: hints, environment: environment),
            configuredCommand: configuredCommand,
            additionalPathHints: hints,
            environment: environment,
            shellEnvironmentSource: launchEnvironment.shellEnvironmentSource
        )
    }

    private func resolveExplicitLaunch(
        for config: some ACPCLILaunchConfiguring,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shellEnvironmentSource: ShellEnvironmentSource? = nil
    ) throws -> ACPCLIResolvedLaunch {
        let configuredCommand = try validatedConfiguredCommand(config)
        guard configuredCommand.contains("/") else {
            throw ACPCLILaunchResolutionError.environmentDiscoveryRequired(
                agent: spec.displayName,
                command: configuredCommand
            )
        }
        do {
            return try validatedLaunch(
                entryPath: CommandPathResolver.expandPath(configuredCommand, environment: environment),
                configuredCommand: configuredCommand,
                additionalPathHints: effectiveHints(for: config),
                environment: environment
            )
        } catch {
            // Explicit-path failures keep their specific errors and omit the fallback-PATH
            // hint: an exact configured path does not depend on PATH discovery.
            AgentCLILaunchDiagnostics.recordPathResolutionFailure(
                providerKind: .init(agentKind: spec.providerKind),
                shellEnvironmentSource: shellEnvironmentSource,
                candidateCount: 1
            )
            throw error
        }
    }

    private func validatedConfiguredCommand(_ config: some ACPCLILaunchConfiguring) throws -> String {
        let configuredCommand = config.commandName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredCommand.isEmpty else {
            throw ACPCLILaunchResolutionError.missingConfiguredCommand(
                agent: spec.displayName,
                expected: spec.commandName
            )
        }
        let basename = configuredCommand.contains("/")
            ? (configuredCommand as NSString).lastPathComponent
            : configuredCommand
        guard basename.caseInsensitiveCompare(spec.commandName) == .orderedSame else {
            throw ACPCLILaunchResolutionError.unsafeConfiguredCommand(
                agent: spec.displayName,
                command: configuredCommand
            )
        }
        return configuredCommand
    }

    private func validatedLaunch(
        entryPath: String,
        configuredCommand: String,
        additionalPathHints: [String],
        environment: [String: String],
        preserveValidationError: Bool = false
    ) throws -> ACPCLIResolvedLaunch {
        guard entryPath.hasPrefix("/"),
              (entryPath as NSString).lastPathComponent.caseInsensitiveCompare(spec.commandName) == .orderedSame
        else {
            throw ACPCLILaunchResolutionError.exactPathNotFound(
                agent: spec.displayName,
                command: configuredCommand
            )
        }

        let identity: ExecutableFileIdentity
        do {
            identity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: entryPath)
        } catch {
            if preserveValidationError { throw error }
            throw ACPCLILaunchResolutionError.exactPathNotFound(
                agent: spec.displayName,
                command: configuredCommand
            )
        }

        if identity.canonicalPath.split(separator: "/").contains(where: { $0.lowercased().hasSuffix(".app") }) {
            throw ACPCLILaunchResolutionError.unsafeApplicationPath(
                agent: spec.displayName,
                path: identity.canonicalPath
            )
        }
        return ACPCLIResolvedLaunch(
            command: identity.canonicalPath,
            arguments: spec.launchArguments,
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
                spec.commandName,
                environment: environment,
                additionalPaths: additionalPathHints,
                preferredBasenames: spec.profile.preferredBasenames,
                shellLookupMode: .fallbackOnly
            )
        )
        for directory in CommandPathResolver.mergedPathComponents(
            environment: environment,
            additionalPaths: additionalPathHints
        ) {
            append((directory as NSString).appendingPathComponent(spec.commandName))
        }
        return candidates
    }

    private func firstValidLaunch(
        candidates: [String],
        configuredCommand: String,
        additionalPathHints: [String],
        environment: [String: String],
        shellEnvironmentSource: ShellEnvironmentSource?
    ) throws -> ACPCLIResolvedLaunch {
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
            throw ACPCLILaunchResolutionError.exactPathNotFound(
                agent: spec.displayName,
                command: configuredCommand
            )
        }
        AgentCLILaunchDiagnostics.recordPathResolutionFailure(
            providerKind: .init(agentKind: spec.providerKind),
            shellEnvironmentSource: shellEnvironmentSource,
            candidateCount: candidates.count
        )
        throw ACPCLILaunchResolutionError.noValidLaunchCandidate(
            agent: spec.displayName,
            command: configuredCommand,
            failures: failures,
            source: shellEnvironmentSource
        )
    }

    private func effectiveHints(for config: some ACPCLILaunchConfiguring) -> [String] {
        CLILaunchProfiles.providerSpecificPathsSupplementedWithNativeDefaults(config.additionalPathHints)
    }

    private func cachedLaunch(forKey key: String) -> ACPCLIResolvedLaunch? {
        lock.lock()
        defer { lock.unlock() }
        return cachedLaunchByKey[key]
    }

    private func cache(_ launch: ACPCLIResolvedLaunch, key: String) {
        lock.lock()
        cachedLaunchByKey[key] = launch
        lock.unlock()
    }

    private func invalidate(key: String) {
        lock.lock()
        cachedLaunchByKey.removeValue(forKey: key)
        lock.unlock()
    }

    private func cacheKey(for config: some ACPCLILaunchConfiguring) -> String {
        ([config.commandName] + config.additionalPathHints).joined(separator: "\u{1F}")
    }
}

extension ACPCLILaunchSpec {
    static let devin = ACPCLILaunchSpec(
        providerID: .devin,
        providerKind: .devin,
        displayName: "Devin",
        profile: CLILaunchProfiles.devin,
        launchArguments: ["acp"],
        helpArguments: ["acp", "--help"],
        requiredHelpAdvertisements: ["run as an acp", "server over stdio"]
    )

    static let omp = ACPCLILaunchSpec(
        providerID: .omp,
        providerKind: .omp,
        displayName: "Oh My Pi",
        profile: CLILaunchProfiles.omp,
        launchArguments: ["acp"],
        helpArguments: ["acp", "--help"],
        requiredHelpAdvertisements: ["run oh my pi as an acp", "server over stdio"]
    )
}
