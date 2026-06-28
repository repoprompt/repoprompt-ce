import Foundation

struct GrokACPResolvedLaunch: Equatable {
    let command: String
    let arguments: [String]
    let additionalPathHints: [String]
    let executableIdentity: ExecutableFileIdentity
}

enum GrokACPLaunchResolutionError: Error, Equatable, LocalizedError {
    case missingConfiguredCommand
    case unsafeConfiguredCommand(String)
    case exactPathNotFound(String)
    case environmentDiscoveryRequired(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguredCommand:
            "Grok Build CLI launch requires an exact `grok` command or absolute path."
        case let .unsafeConfiguredCommand(command):
            "Refusing unsafe Grok ACP command `\(command)`. Configure the official `grok` executable."
        case let .exactPathNotFound(command):
            "Grok Build CLI was not found as a valid executable regular file for `\(command)`. Install Grok Build or configure its absolute path."
        case let .environmentDiscoveryRequired(command):
            "Grok Build CLI path discovery has not completed for `\(command)`. Run the Grok ACP support preflight or configure an absolute `grok` path."
        }
    }
}

final class GrokACPLaunchResolver: @unchecked Sendable {
    typealias EnvironmentProvider = @Sendable (_ enableDebugLogging: Bool) async -> [String: String]

    /// Builds `grok agent [-m <modelId>] stdio`. The `-m` flag lives on the `agent`
    /// parent and must precede the `stdio` subcommand (verified against grok 0.2.67).
    private static func launchArguments(for config: GrokAgentConfig) -> [String] {
        var arguments = ["agent"]
        if config.alwaysApprove {
            arguments.append("--always-approve")
        }
        if let model = config.modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty,
           model.caseInsensitiveCompare("default") != .orderedSame,
           model.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        {
            arguments.append(contentsOf: ["-m", model])
        }
        arguments.append("stdio")
        return arguments
    }

    private static let stdioHelpArguments = ["agent", "stdio", "--help"]
    private static let agentHelpArguments = ["agent", "--help"]

    private let environmentProvider: EnvironmentProvider
    private let probeMutex = AsyncMutex()
    private let lock = NSLock()
    private var cachedLaunchByKey: [String: GrokACPResolvedLaunch] = [:]

    init(
        environmentProvider: @escaping EnvironmentProvider = { enableDebugLogging in
            let result = await ProcessEnvironmentBuilder.build(
                ProcessEnvironmentRequest(
                    purpose: .acpAgent(providerID: ACPProviderID.grok.rawValue),
                    enableDebugLogging: enableDebugLogging
                )
            )
            return result.environment
        }
    ) {
        self.environmentProvider = environmentProvider
    }

    func resolvedLaunch(for config: GrokAgentConfig) throws -> GrokACPResolvedLaunch {
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

    func probeSupport(for config: GrokAgentConfig) async throws -> ACPSupportResult {
        try await probeMutex.withLock { [self] in
            try await probeSupportSerially(for: config)
        }
    }

    private func probeSupportSerially(for config: GrokAgentConfig) async throws -> ACPSupportResult {
        let key = cacheKey(for: config)
        invalidate(key: key)
        do {
            let launch = try await resolveLaunchForProbe(for: config)
            let processConfig = CLIProcessConfiguration(
                command: launch.command,
                additionalPaths: [],
                enableDebugLogging: config.enableDebugLogging
            )
            let probe = try await runSupportProbe(processConfig: processConfig)
            guard probe.supported else {
                return .unsupported(reason: probe.reason)
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

    private struct ProbeOutcome {
        let supported: Bool
        let reason: String
    }

    private func runSupportProbe(processConfig: CLIProcessConfiguration) async throws -> ProbeOutcome {
        let stdioResult = try? await runHelpProbe(args: Self.stdioHelpArguments, processConfig: processConfig)
        if let stdioResult, stdioResult.status == 0, Self.probeOutputAdvertisesACP(stdioResult) {
            return ProbeOutcome(supported: true, reason: "")
        }

        let agentResult = try await runHelpProbe(args: Self.agentHelpArguments, processConfig: processConfig)
        if agentResult.status == 0, Self.probeOutputAdvertisesACP(agentResult) {
            return ProbeOutcome(supported: true, reason: "")
        }

        if let stdioResult, stdioResult.status != 0, agentResult.status != 0 {
            return ProbeOutcome(
                supported: false,
                reason: "Grok Build CLI ACP preflight failed: `grok agent stdio --help` exited with status \(stdioResult.status), and `grok agent --help` exited with status \(agentResult.status)."
            )
        }
        return ProbeOutcome(
            supported: false,
            reason: "Grok Build CLI ACP preflight failed: help output did not advertise stdio ACP support."
        )
    }

    private func runHelpProbe(
        args: [String],
        processConfig: CLIProcessConfiguration
    ) async throws -> CLIProcessRunner.Result {
        try await CLIProcessRunner(config: processConfig).run(
            args: args,
            stdin: nil,
            outputMode: .none,
            timeout: 10,
            cancelChildOnTaskCancellation: true
        )
    }

    private static func probeOutputAdvertisesACP(_ result: CLIProcessRunner.Result) -> Bool {
        let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        let combined = "\(stdout)\n\(stderr)"
        return combined.localizedCaseInsensitiveContains("stdio")
            || combined.localizedCaseInsensitiveContains("agent client protocol")
            || combined.localizedCaseInsensitiveContains("json-rpc")
    }

    private func resolveLaunchForProbe(for config: GrokAgentConfig) async throws -> GrokACPResolvedLaunch {
        let configuredCommand = try validatedConfiguredCommand(config)
        let environment = await environmentProvider(config.enableDebugLogging)
        try Task.checkCancellation()
        if configuredCommand.contains("/") {
            return try resolveExplicitLaunch(for: config, environment: environment)
        }

        let effectiveHints = CLILaunchProfiles.providerSpecificPathsSupplementedWithNativeDefaults(config.additionalPathHints)
        let resolved = CommandPathResolver.resolve(
            configuredCommand,
            environment: environment,
            additionalPaths: effectiveHints,
            preferredBasenames: CLILaunchProfiles.grok.preferredBasenames
        )
        return try validatedLaunch(
            entryPath: resolved,
            configuredCommand: configuredCommand,
            additionalPathHints: effectiveHints,
            arguments: Self.launchArguments(for: config)
        )
    }

    private func resolveExplicitLaunch(
        for config: GrokAgentConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> GrokACPResolvedLaunch {
        let configuredCommand = try validatedConfiguredCommand(config)
        guard configuredCommand.contains("/") else {
            throw GrokACPLaunchResolutionError.environmentDiscoveryRequired(configuredCommand)
        }
        let effectiveHints = CLILaunchProfiles.providerSpecificPathsSupplementedWithNativeDefaults(config.additionalPathHints)
        return try validatedLaunch(
            entryPath: CommandPathResolver.expandPath(configuredCommand, environment: environment),
            configuredCommand: configuredCommand,
            additionalPathHints: effectiveHints,
            arguments: Self.launchArguments(for: config)
        )
    }

    private func validatedConfiguredCommand(_ config: GrokAgentConfig) throws -> String {
        let configuredCommand = config.commandName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredCommand.isEmpty else {
            throw GrokACPLaunchResolutionError.missingConfiguredCommand
        }
        let expectedCommand = CLILaunchProfiles.grok.commandName
        if configuredCommand.contains("/") {
            guard (configuredCommand as NSString).lastPathComponent.caseInsensitiveCompare(expectedCommand) == .orderedSame else {
                throw GrokACPLaunchResolutionError.unsafeConfiguredCommand(configuredCommand)
            }
        } else if configuredCommand.caseInsensitiveCompare(expectedCommand) != .orderedSame {
            throw GrokACPLaunchResolutionError.unsafeConfiguredCommand(configuredCommand)
        }
        return configuredCommand
    }

    private func validatedLaunch(
        entryPath: String,
        configuredCommand: String,
        additionalPathHints: [String],
        arguments: [String]
    ) throws -> GrokACPResolvedLaunch {
        guard entryPath.hasPrefix("/"),
              (entryPath as NSString).lastPathComponent.caseInsensitiveCompare(CLILaunchProfiles.grok.commandName) == .orderedSame
        else {
            throw GrokACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }

        let identity: ExecutableFileIdentity
        do {
            identity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: entryPath)
        } catch {
            throw GrokACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }

        return GrokACPResolvedLaunch(
            command: identity.canonicalPath,
            arguments: arguments,
            additionalPathHints: additionalPathHints,
            executableIdentity: identity
        )
    }

    private func cachedLaunch(forKey key: String) -> GrokACPResolvedLaunch? {
        lock.lock()
        defer { lock.unlock() }
        return cachedLaunchByKey[key]
    }

    private func cache(_ launch: GrokACPResolvedLaunch, key: String) {
        lock.lock()
        cachedLaunchByKey[key] = launch
        lock.unlock()
    }

    private func invalidate(key: String) {
        lock.lock()
        cachedLaunchByKey.removeValue(forKey: key)
        lock.unlock()
    }

    private func cacheKey(for config: GrokAgentConfig) -> String {
        ([config.commandName, config.modelString ?? "", config.alwaysApprove ? "always-approve" : ""] + config.additionalPathHints).joined(separator: "\u{1F}")
    }
}
