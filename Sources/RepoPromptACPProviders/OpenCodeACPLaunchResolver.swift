import Foundation
import RepoPromptAIContracts
import RepoPromptFoundation
import RepoPromptProcess

package struct OpenCodeACPResolvedLaunch: Equatable {
    package let command: String
    package let arguments: [String]
    package let additionalPathHints: [String]
    package let executableIdentity: ExecutableFileIdentity
}

package enum OpenCodeACPLaunchResolutionError: Error, Equatable, LocalizedError {
    case missingConfiguredCommand
    case exactPathNotFound(String)
    case noValidLaunchCandidate(String, [String], ShellEnvironmentSource?)
    case environmentDiscoveryRequired(String)

    package var errorDescription: String? {
        switch self {
        case .missingConfiguredCommand:
            "OpenCode ACP launch requires an `opencode` command or executable path."
        case let .exactPathNotFound(command):
            "OpenCode CLI was not found as a valid executable regular file for `\(command)`. Install OpenCode or configure its absolute path."
        case let .noValidLaunchCandidate(command, failures, source):
            AgentCLILaunchDiagnostics.appendFallbackEnvironmentHint(
                to: "OpenCode CLI was not found as a valid executable regular file for `\(command)`. Tried: \(failures.joined(separator: "; "))",
                source: source
            )
        case let .environmentDiscoveryRequired(command):
            "OpenCode CLI path discovery has not completed for `\(command)`. Run the OpenCode ACP support preflight or configure an absolute executable path."
        }
    }
}

package final class OpenCodeACPLaunchResolver: @unchecked Sendable {
    package typealias EnvironmentProvider = @Sendable (_ enableDebugLogging: Bool) async -> ACPLaunchEnvironment
    package typealias ProbeRunner = @Sendable (_ launch: OpenCodeACPResolvedLaunch, _ config: OpenCodeAgentConfig) async throws -> CLIProcessRunner.Result
    package typealias FailureRecorder = @Sendable (_ source: ShellEnvironmentSource?, _ candidateCount: Int) -> Void

    private static let launchArguments = ["acp"]

    private let environmentProvider: EnvironmentProvider
    private let probeRunner: ProbeRunner
    private let recordFailure: FailureRecorder
    private let probeMutex = AsyncMutex()
    private let lock = NSLock()
    private var cachedLaunchByKey: [String: OpenCodeACPResolvedLaunch] = [:]

    package init(
        launchEnvironmentProvider: @escaping EnvironmentProvider,
        probeRunner: @escaping ProbeRunner,
        recordFailure: @escaping FailureRecorder
    ) {
        environmentProvider = launchEnvironmentProvider
        self.probeRunner = probeRunner
        self.recordFailure = recordFailure
    }

    package func resolvedLaunch(for config: OpenCodeAgentConfig) throws -> OpenCodeACPResolvedLaunch {
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

    package func probeSupport(for config: OpenCodeAgentConfig) async throws -> ACPSupportResult {
        try await probeMutex.withLock { [self] in
            try await probeSupportSerially(for: config)
        }
    }

    private func probeSupportSerially(for config: OpenCodeAgentConfig) async throws -> ACPSupportResult {
        let key = cacheKey(for: config)
        invalidate(key: key)
        do {
            // Resolve from the current effective environment on every support check. The cache only
            // bridges this successful probe to the immediately following launch configuration.
            let launch = try await resolveLaunchForProbe(for: config)
            let result = try await probeRunner(launch, config)
            guard result.status == 0 else {
                return .unsupported(
                    reason: "OpenCode ACP preflight failed: `opencode acp --help` exited with status \(result.status)."
                )
            }

            let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            guard "\(stdout)\n\(stderr)".localizedCaseInsensitiveContains("acp") else {
                return .unsupported(reason: "Installed OpenCode CLI does not advertise ACP support.")
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

    private func resolveLaunchForProbe(for config: OpenCodeAgentConfig) async throws -> OpenCodeACPResolvedLaunch {
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

        let effectiveHints = Self.effectiveSearchPaths(providerSpecificPaths: config.additionalPathHints)
        return try firstValidLaunch(
            candidates: launchCandidates(
                configuredCommand: configuredCommand,
                additionalPathHints: effectiveHints,
                environment: environment
            ),
            configuredCommand: configuredCommand,
            additionalPathHints: effectiveHints,
            shellEnvironmentSource: launchEnvironment.shellEnvironmentSource
        )
    }

    private func resolveExplicitLaunch(
        for config: OpenCodeAgentConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shellEnvironmentSource: ShellEnvironmentSource? = nil
    ) throws -> OpenCodeACPResolvedLaunch {
        let configuredCommand = try validatedConfiguredCommand(config)
        guard configuredCommand.contains("/") else {
            throw OpenCodeACPLaunchResolutionError.environmentDiscoveryRequired(configuredCommand)
        }
        let effectiveHints = Self.effectiveSearchPaths(providerSpecificPaths: config.additionalPathHints)
        return try firstValidLaunch(
            candidates: [CommandPathResolver.expandPath(configuredCommand, environment: environment)],
            configuredCommand: configuredCommand,
            additionalPathHints: effectiveHints,
            shellEnvironmentSource: shellEnvironmentSource
        )
    }

    private func validatedConfiguredCommand(_ config: OpenCodeAgentConfig) throws -> String {
        let command = config.commandName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw OpenCodeACPLaunchResolutionError.missingConfiguredCommand
        }
        return command
    }

    private func validatedLaunch(
        entryPath: String,
        configuredCommand: String,
        additionalPathHints: [String]
    ) throws -> OpenCodeACPResolvedLaunch {
        guard entryPath.hasPrefix("/") else {
            throw OpenCodeACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }
        let identity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: entryPath)

        return OpenCodeACPResolvedLaunch(
            command: identity.canonicalPath,
            arguments: Self.launchArguments,
            additionalPathHints: additionalPathHints,
            executableIdentity: identity
        )
    }

    private func launchCandidates(
        configuredCommand: String,
        additionalPathHints: [String],
        environment: [String: String]
    ) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        func append(_ candidate: String) {
            let expanded = CommandPathResolver.expandPath(candidate, environment: environment)
            guard !expanded.isEmpty,
                  seen.insert(expanded).inserted
            else { return }
            candidates.append(expanded)
        }

        append(
            CommandPathResolver.resolve(
                configuredCommand,
                environment: environment,
                additionalPaths: additionalPathHints,
                preferredBasenames: [configuredCommand],
                shellLookupMode: .fallbackOnly
            )
        )
        for directory in CommandPathResolver.mergedPathComponents(
            environment: environment,
            additionalPaths: additionalPathHints
        ) {
            append((directory as NSString).appendingPathComponent(configuredCommand))
        }
        return candidates
    }

    private func firstValidLaunch(
        candidates: [String],
        configuredCommand: String,
        additionalPathHints: [String],
        shellEnvironmentSource: ShellEnvironmentSource?
    ) throws -> OpenCodeACPResolvedLaunch {
        var failures: [String] = []
        for candidate in candidates {
            do {
                return try validatedLaunch(
                    entryPath: candidate,
                    configuredCommand: configuredCommand,
                    additionalPathHints: additionalPathHints
                )
            } catch {
                failures.append("\(candidate): \(candidateDiagnostic(candidate, validationError: error))")
            }
        }
        if failures.isEmpty {
            throw OpenCodeACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }
        recordFailure(shellEnvironmentSource, candidates.count)
        throw OpenCodeACPLaunchResolutionError.noValidLaunchCandidate(configuredCommand, failures, shellEnvironmentSource)
    }

    private func candidateDiagnostic(_ candidate: String, validationError: Error) -> String {
        guard candidate.hasPrefix("/") else { return "not an absolute path" }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory) else {
            return "missing"
        }
        if isDirectory.boolValue { return "directory" }
        guard FileManager.default.isExecutableFile(atPath: candidate) else {
            return "not executable"
        }
        return validationError.localizedDescription
    }

    private func cachedLaunch(forKey key: String) -> OpenCodeACPResolvedLaunch? {
        lock.lock()
        defer { lock.unlock() }
        return cachedLaunchByKey[key]
    }

    private func cache(_ launch: OpenCodeACPResolvedLaunch, key: String) {
        lock.lock()
        cachedLaunchByKey[key] = launch
        lock.unlock()
    }

    private func invalidate(key: String) {
        lock.lock()
        cachedLaunchByKey.removeValue(forKey: key)
        lock.unlock()
    }

    private func cacheKey(for config: OpenCodeAgentConfig) -> String {
        ([config.commandName] + config.additionalPathHints).joined(separator: "\u{1F}")
    }

    private static func effectiveSearchPaths(providerSpecificPaths: [String]) -> [String] {
        CLILaunchProfiles.providerSpecificPathsSupplementedWithNativeDefaults(providerSpecificPaths)
    }
}
