import Foundation

enum GrokBuildACPLaunchCandidate: Equatable {
    case grokAgentStdio

    var command: String {
        CLILaunchProfiles.grokBuild.commandName
    }

    /// Approval/model flags belong to the parent `grok agent` command (confirmed against
    /// grok 1.0.3: `grok agent stdio` accepts only `--debug`/`--debug-file`/`--leader-socket`),
    /// so full-access launches become `["agent", "--no-leader", "--always-approve", "stdio"]`.
    /// `--no-leader` is mandatory: in leader mode (grok 1.0.4 default) the shared leader
    /// process spawns MCP servers, which breaks the ACP expected-PID ancestry check that
    /// admits the injected RepoPrompt MCP connection — the server must be a direct child
    /// of the ACP session process. The resolver deliberately caches only the executable,
    /// never per-request arguments.
    var launchArguments: [String] {
        ["agent", "--no-leader", "stdio"]
    }

    var helpArguments: [String] {
        ["agent", "--help"]
    }
}

struct GrokBuildACPResolvedLaunch: Equatable {
    let command: String
    let arguments: [String]
    let additionalPathHints: [String]
    let environment: [String: String]
    let executableIdentity: ExecutableFileIdentity
}

enum GrokBuildACPLaunchResolutionError: Error, Equatable, LocalizedError {
    case missingConfiguredCommand
    case unsafeConfiguredCommand(String)
    case exactPathNotFound(String)
    case noValidLaunchCandidate(String, [String], ShellEnvironmentSource?)
    case environmentDiscoveryRequired(String)
    case unsafeApplicationPath(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguredCommand:
            "Grok Build CLI launch requires an exact `grok` command or absolute path."
        case let .unsafeConfiguredCommand(command):
            "Refusing unsafe Grok Build ACP command `\(command)`. Configure the `grok` executable."
        case let .exactPathNotFound(command):
            "Grok Build CLI was not found as a valid executable regular file for `\(command)`. Install Grok Build (`npm i -g @xai-official/grok` or https://x.ai/cli/install.sh) or configure its absolute path."
        case let .noValidLaunchCandidate(command, failures, source):
            AgentCLILaunchDiagnostics.appendFallbackEnvironmentHint(
                to: "Grok Build CLI was not found as a valid executable regular file for `\(command)`. Tried: \(failures.joined(separator: "; "))",
                source: source
            )
        case let .environmentDiscoveryRequired(command):
            "Grok Build CLI path discovery has not completed for `\(command)`. Run the Grok Build ACP support preflight or configure an absolute `grok` path."
        case let .unsafeApplicationPath(path):
            "Refusing Grok Build ACP executable inside an application bundle: \(path)"
        }
    }
}

final class GrokBuildACPLaunchResolver: @unchecked Sendable {
    typealias EnvironmentProvider = @Sendable (_ enableDebugLogging: Bool) async -> ACPLaunchEnvironment

    private let environmentProvider: EnvironmentProvider
    private let probeMutex = AsyncMutex()
    private let lock = NSLock()
    private var cachedLaunchByKey: [String: GrokBuildACPResolvedLaunch] = [:]

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
                    purpose: .acpAgent(providerID: ACPProviderID.grokBuild.rawValue),
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

    func resolvedLaunch(for config: GrokBuildAgentConfig) throws -> GrokBuildACPResolvedLaunch {
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

    func probeSupport(for config: GrokBuildAgentConfig) async throws -> ACPSupportResult {
        try await probeMutex.withLock { [self] in
            try await probeSupportSerially(for: config)
        }
    }

    private func probeSupportSerially(for config: GrokBuildAgentConfig) async throws -> ACPSupportResult {
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
                args: GrokBuildACPLaunchCandidate.grokAgentStdio.helpArguments,
                stdin: nil,
                outputMode: .none,
                timeout: 10,
                cancelChildOnTaskCancellation: true
            )
            guard result.status == 0 else {
                return .unsupported(
                    reason: "Grok Build CLI ACP preflight failed: `grok agent --help` exited with status \(result.status)."
                )
            }

            // grok 1.0.3 prints the help (including the `stdio` subcommand) on both streams;
            // matching the concatenation keeps the probe robust to either.
            let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            let combined = "\(stdout)\n\(stderr)"
            guard combined.localizedCaseInsensitiveContains("stdio") else {
                return .unsupported(
                    reason: "Grok Build CLI ACP preflight failed: `grok agent --help` did not advertise the `stdio` ACP subcommand."
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

    private func resolveLaunchForProbe(for config: GrokBuildAgentConfig) async throws -> GrokBuildACPResolvedLaunch {
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
            environment: environment,
            shellEnvironmentSource: launchEnvironment.shellEnvironmentSource
        )
    }

    private func resolveExplicitLaunch(
        for config: GrokBuildAgentConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shellEnvironmentSource: ShellEnvironmentSource? = nil
    ) throws -> GrokBuildACPResolvedLaunch {
        let configuredCommand = try validatedConfiguredCommand(config)
        guard configuredCommand.contains("/") else {
            throw GrokBuildACPLaunchResolutionError.environmentDiscoveryRequired(configuredCommand)
        }
        let effectiveHints = CLILaunchProfiles.providerSpecificPathsSupplementedWithNativeDefaults(config.additionalPathHints)
        do {
            return try validatedLaunch(
                entryPath: CommandPathResolver.expandPath(configuredCommand, environment: environment),
                configuredCommand: configuredCommand,
                additionalPathHints: effectiveHints,
                environment: environment
            )
        } catch {
            // Explicit-path failures intentionally keep their specific errors and omit the
            // fallback-PATH hint: an exact configured path does not depend on PATH discovery.
            AgentCLILaunchDiagnostics.recordPathResolutionFailure(
                providerKind: .grokBuild,
                shellEnvironmentSource: shellEnvironmentSource,
                candidateCount: 1
            )
            throw error
        }
    }

    private func validatedConfiguredCommand(_ config: GrokBuildAgentConfig) throws -> String {
        let configuredCommand = config.commandName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredCommand.isEmpty else {
            throw GrokBuildACPLaunchResolutionError.missingConfiguredCommand
        }
        let expectedCommand = GrokBuildACPLaunchCandidate.grokAgentStdio.command
        if configuredCommand.contains("/") {
            guard (configuredCommand as NSString).lastPathComponent.caseInsensitiveCompare(expectedCommand) == .orderedSame else {
                throw GrokBuildACPLaunchResolutionError.unsafeConfiguredCommand(configuredCommand)
            }
        } else if configuredCommand.caseInsensitiveCompare(expectedCommand) != .orderedSame {
            throw GrokBuildACPLaunchResolutionError.unsafeConfiguredCommand(configuredCommand)
        }
        return configuredCommand
    }

    private func validatedLaunch(
        entryPath: String,
        configuredCommand: String,
        additionalPathHints: [String],
        environment: [String: String],
        preserveValidationError: Bool = false
    ) throws -> GrokBuildACPResolvedLaunch {
        guard entryPath.hasPrefix("/"),
              (entryPath as NSString).lastPathComponent.caseInsensitiveCompare(GrokBuildACPLaunchCandidate.grokAgentStdio.command) == .orderedSame
        else {
            throw GrokBuildACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }

        let identity: ExecutableFileIdentity
        do {
            identity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: entryPath)
        } catch {
            if preserveValidationError { throw error }
            throw GrokBuildACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }

        if identity.canonicalPath.split(separator: "/").contains(where: { $0.lowercased().hasSuffix(".app") }) {
            throw GrokBuildACPLaunchResolutionError.unsafeApplicationPath(identity.canonicalPath)
        }
        // Unlike Cursor there is no canonical-basename rejection here: the official installer
        // lands `~/.grok/bin/grok` as a symlink into `~/.grok/downloads/`, so the canonical
        // target legitimately has a different basename. The trusted entry path plus the
        // captured executable identity are the validation boundary.

        return GrokBuildACPResolvedLaunch(
            command: identity.canonicalPath,
            arguments: GrokBuildACPLaunchCandidate.grokAgentStdio.launchArguments,
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
                GrokBuildACPLaunchCandidate.grokAgentStdio.command,
                environment: environment,
                additionalPaths: additionalPathHints,
                preferredBasenames: CLILaunchProfiles.grokBuild.preferredBasenames,
                shellLookupMode: .fallbackOnly
            )
        )
        for directory in CommandPathResolver.mergedPathComponents(
            environment: environment,
            additionalPaths: additionalPathHints
        ) {
            append((directory as NSString).appendingPathComponent(GrokBuildACPLaunchCandidate.grokAgentStdio.command))
        }
        return candidates
    }

    private func firstValidLaunch(
        candidates: [String],
        configuredCommand: String,
        additionalPathHints: [String],
        environment: [String: String],
        shellEnvironmentSource: ShellEnvironmentSource?
    ) throws -> GrokBuildACPResolvedLaunch {
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
            throw GrokBuildACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }
        AgentCLILaunchDiagnostics.recordPathResolutionFailure(
            providerKind: .grokBuild,
            shellEnvironmentSource: shellEnvironmentSource,
            candidateCount: candidates.count
        )
        throw GrokBuildACPLaunchResolutionError.noValidLaunchCandidate(configuredCommand, failures, shellEnvironmentSource)
    }

    private func cachedLaunch(forKey key: String) -> GrokBuildACPResolvedLaunch? {
        lock.lock()
        defer { lock.unlock() }
        return cachedLaunchByKey[key]
    }

    private func cache(_ launch: GrokBuildACPResolvedLaunch, key: String) {
        lock.lock()
        cachedLaunchByKey[key] = launch
        lock.unlock()
    }

    private func invalidate(key: String) {
        lock.lock()
        cachedLaunchByKey.removeValue(forKey: key)
        lock.unlock()
    }

    private func cacheKey(for config: GrokBuildAgentConfig) -> String {
        ([config.commandName] + config.additionalPathHints).joined(separator: "\u{1F}")
    }
}
