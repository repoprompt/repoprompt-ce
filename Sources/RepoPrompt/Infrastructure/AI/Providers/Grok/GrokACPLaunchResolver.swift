import Foundation

struct GrokACPResolvedLaunch: Equatable {
    let command: String
    let arguments: [String]
    let additionalPathHints: [String]
    let executableIdentity: ExecutableFileIdentity
}

enum GrokACPLaunchResolutionError: Error, Equatable, LocalizedError {
    case missingConfiguredCommand
    case exactPathNotFound(String)
    case environmentDiscoveryRequired(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguredCommand:
            "Grok ACP launch requires a `grok` command or executable path."
        case let .exactPathNotFound(command):
            "Grok CLI was not found as a valid executable regular file for `\(command)`. Install Grok Build CLI and ensure `grok` is available on PATH."
        case let .environmentDiscoveryRequired(command):
            "Grok CLI path discovery has not completed for `\(command)`. Run the Grok ACP support preflight or configure an absolute executable path."
        }
    }
}

final class GrokACPLaunchResolver: @unchecked Sendable {
    typealias EnvironmentProvider = @Sendable (_ enableDebugLogging: Bool) async -> [String: String]

    private static let launchArguments = ["agent", "--always-approve", "stdio"]
    private static let helpArguments = ["agent", "--help"]

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
            let result = try await CLIProcessRunner(config: processConfig).run(
                args: Self.helpArguments,
                stdin: nil,
                outputMode: .none,
                timeout: 10,
                cancelChildOnTaskCancellation: true
            )
            guard result.status == 0 else {
                return .unsupported(
                    reason: "Grok ACP preflight failed: `grok agent --help` exited with status \(result.status)."
                )
            }

            let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            let combined = "\(stdout)\n\(stderr)"
            guard combined.localizedCaseInsensitiveContains("stdio")
                || combined.localizedCaseInsensitiveContains("agent client protocol")
                || combined.localizedCaseInsensitiveContains("acp")
            else {
                return .unsupported(reason: "Installed Grok CLI does not advertise ACP stdio support.")
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

    private func resolveLaunchForProbe(for config: GrokAgentConfig) async throws -> GrokACPResolvedLaunch {
        let configuredCommand = try validatedConfiguredCommand(config)
        let environment = await environmentProvider(config.enableDebugLogging)
        try Task.checkCancellation()
        if configuredCommand.contains("/") {
            return try resolveExplicitLaunch(for: config, environment: environment)
        }

        let effectiveHints = CLIPathHints.nativeDefaultsSupplemented(with: config.additionalPathHints)
        let resolved = CommandPathResolver.resolve(
            CLILaunchProfiles.grok.commandName,
            environment: environment,
            additionalPaths: effectiveHints,
            preferredBasenames: CLILaunchProfiles.grok.preferredBasenames
        )
        return try validatedLaunch(
            entryPath: resolved,
            configuredCommand: configuredCommand,
            additionalPathHints: effectiveHints
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
        let effectiveHints = CLIPathHints.nativeDefaultsSupplemented(with: config.additionalPathHints)
        let expanded = CommandPathResolver.expandPath(configuredCommand, environment: environment)
        return try validatedLaunch(
            entryPath: expanded,
            configuredCommand: configuredCommand,
            additionalPathHints: effectiveHints
        )
    }

    private func validatedConfiguredCommand(_ config: GrokAgentConfig) throws -> String {
        let configuredCommand = config.commandName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredCommand.isEmpty else {
            throw GrokACPLaunchResolutionError.missingConfiguredCommand
        }
        let expectedCommand = CLILaunchProfiles.grok.commandName
        if configuredCommand.contains("/") {
            guard URL(fileURLWithPath: configuredCommand).lastPathComponent.caseInsensitiveCompare(expectedCommand) == .orderedSame else {
                throw GrokACPLaunchResolutionError.exactPathNotFound(configuredCommand)
            }
        } else if configuredCommand.caseInsensitiveCompare(expectedCommand) != .orderedSame {
            throw GrokACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }
        return configuredCommand
    }

    private func validatedLaunch(
        entryPath: String,
        configuredCommand: String,
        additionalPathHints: [String]
    ) throws -> GrokACPResolvedLaunch {
        guard entryPath.hasPrefix("/"),
              URL(fileURLWithPath: entryPath).lastPathComponent.caseInsensitiveCompare(CLILaunchProfiles.grok.commandName) == .orderedSame
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
            arguments: Self.launchArguments,
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
        ([config.commandName] + config.additionalPathHints).joined(separator: "\u{1F}")
    }
}