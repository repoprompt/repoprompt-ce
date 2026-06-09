import Foundation

enum CursorACPLaunchCandidate: Equatable {
    case cursorAgentACP

    var command: String {
        CLILaunchProfiles.cursor.commandName
    }

    var launchArguments: [String] {
        ["--approve-mcps", "acp"]
    }

    var helpArguments: [String] {
        ["acp", "--help"]
    }
}

struct CursorACPResolvedLaunch: Equatable {
    let command: String
    let arguments: [String]
    let additionalPathHints: [String]
    let environment: [String: String]
    let executableIdentity: ExecutableFileIdentity
}

enum CursorACPLaunchResolutionError: Error, Equatable, LocalizedError {
    case missingConfiguredCommand
    case unsafeConfiguredCommand(String)
    case exactPathNotFound(String)
    case environmentDiscoveryRequired(String)
    case unsafeApplicationPath(String)
    case unsafeCanonicalBasename(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguredCommand:
            "Cursor Agent CLI launch requires an exact `cursor-agent` command or absolute path."
        case let .unsafeConfiguredCommand(command):
            "Refusing unsafe Cursor ACP command `\(command)`. Configure the CLI-only `cursor-agent` executable."
        case let .exactPathNotFound(command):
            "Cursor Agent CLI was not found as a valid executable regular file for `\(command)`. Install `cursor-agent` or configure its absolute path."
        case let .environmentDiscoveryRequired(command):
            "Cursor Agent CLI path discovery has not completed for `\(command)`. Run the Cursor ACP support preflight or configure an absolute `cursor-agent` path."
        case let .unsafeApplicationPath(path):
            "Refusing Cursor ACP executable inside an application bundle: \(path)"
        case let .unsafeCanonicalBasename(path):
            "Refusing Cursor ACP executable whose canonical basename is `cursor`: \(path)"
        }
    }
}

final class CursorACPLaunchResolver: @unchecked Sendable {
    typealias EnvironmentProvider = @Sendable (_ enableDebugLogging: Bool) async -> [String: String]

    private let environmentProvider: EnvironmentProvider
    private let probeMutex = AsyncMutex()
    private let lock = NSLock()
    private var cachedLaunchByKey: [String: CursorACPResolvedLaunch] = [:]

    init(
        environmentProvider: @escaping EnvironmentProvider = { enableDebugLogging in
            let result = await ProcessEnvironmentBuilder.build(
                ProcessEnvironmentRequest(
                    purpose: .acpAgent(providerID: ACPProviderID.cursor.rawValue),
                    enableDebugLogging: enableDebugLogging
                )
            )
            return result.environment
        }
    ) {
        self.environmentProvider = environmentProvider
    }

    func resolvedLaunch(for config: CursorAgentConfig) throws -> CursorACPResolvedLaunch {
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

    func probeSupport(for config: CursorAgentConfig) async throws -> ACPSupportResult {
        try await probeMutex.withLock { [self] in
            try await probeSupportSerially(for: config)
        }
    }

    private func probeSupportSerially(for config: CursorAgentConfig) async throws -> ACPSupportResult {
        let key = cacheKey(for: config)
        invalidate(key: key)
        do {
            // Resolve from the current effective environment on every support check. The cache only
            // bridges this successful probe to the immediately following launch configuration.
            let launch = try await resolveLaunchForProbe(for: config)
            let processConfig = CLIProcessConfiguration(
                command: launch.command,
                additionalPaths: [],
                enableDebugLogging: config.enableDebugLogging
            )
            let result = try await CLIProcessRunner(config: processConfig).run(
                args: CursorACPLaunchCandidate.cursorAgentACP.helpArguments,
                stdin: nil,
                outputMode: .none,
                timeout: 10,
                cancelChildOnTaskCancellation: true
            )
            guard result.status == 0 else {
                return .unsupported(
                    reason: "Cursor Agent CLI ACP preflight failed: `cursor-agent acp --help` exited with status \(result.status)."
                )
            }

            let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            let combined = "\(stdout)\n\(stderr)"
            guard combined.localizedCaseInsensitiveContains("acp")
                || combined.localizedCaseInsensitiveContains("agent client protocol")
            else {
                return .unsupported(
                    reason: "Cursor Agent CLI ACP preflight failed: `cursor-agent acp --help` did not advertise ACP support."
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

    private func resolveLaunchForProbe(for config: CursorAgentConfig) async throws -> CursorACPResolvedLaunch {
        let configuredCommand = try validatedConfiguredCommand(config)
        let environment = await environmentProvider(config.enableDebugLogging)
        try Task.checkCancellation()
        if configuredCommand.contains("/") {
            return try resolveExplicitLaunch(for: config, environment: environment)
        }

        let effectiveHints = CLIPathHints.nativeDefaultsSupplemented(with: config.additionalPathHints)
        let resolved = CommandPathResolver.resolve(
            CursorACPLaunchCandidate.cursorAgentACP.command,
            environment: environment,
            additionalPaths: effectiveHints,
            preferredBasenames: CLILaunchProfiles.cursor.preferredBasenames
        )
        return try validatedLaunch(
            entryPath: resolved,
            configuredCommand: configuredCommand,
            additionalPathHints: effectiveHints,
            environment: environment
        )
    }

    private func resolveExplicitLaunch(
        for config: CursorAgentConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> CursorACPResolvedLaunch {
        let configuredCommand = try validatedConfiguredCommand(config)
        guard configuredCommand.contains("/") else {
            throw CursorACPLaunchResolutionError.environmentDiscoveryRequired(configuredCommand)
        }
        let effectiveHints = CLIPathHints.nativeDefaultsSupplemented(with: config.additionalPathHints)
        let expanded = CommandPathResolver.expandPath(configuredCommand, environment: environment)
        return try validatedLaunch(
            entryPath: expanded,
            configuredCommand: configuredCommand,
            additionalPathHints: effectiveHints,
            environment: environment
        )
    }

    private func validatedConfiguredCommand(_ config: CursorAgentConfig) throws -> String {
        let configuredCommand = config.commandName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredCommand.isEmpty else {
            throw CursorACPLaunchResolutionError.missingConfiguredCommand
        }
        let expectedCommand = CursorACPLaunchCandidate.cursorAgentACP.command
        if configuredCommand.contains("/") {
            guard URL(fileURLWithPath: configuredCommand).lastPathComponent.caseInsensitiveCompare(expectedCommand) == .orderedSame else {
                throw CursorACPLaunchResolutionError.unsafeConfiguredCommand(configuredCommand)
            }
        } else if configuredCommand.caseInsensitiveCompare(expectedCommand) != .orderedSame {
            throw CursorACPLaunchResolutionError.unsafeConfiguredCommand(configuredCommand)
        }
        return configuredCommand
    }

    private func validatedLaunch(
        entryPath: String,
        configuredCommand: String,
        additionalPathHints: [String],
        environment: [String: String]
    ) throws -> CursorACPResolvedLaunch {
        guard entryPath.hasPrefix("/"),
              URL(fileURLWithPath: entryPath).lastPathComponent.caseInsensitiveCompare(CursorACPLaunchCandidate.cursorAgentACP.command) == .orderedSame
        else {
            throw CursorACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }

        let identity: ExecutableFileIdentity
        do {
            identity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: entryPath)
        } catch {
            throw CursorACPLaunchResolutionError.exactPathNotFound(configuredCommand)
        }

        let canonicalURL = URL(fileURLWithPath: identity.canonicalPath)
        if canonicalURL.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) {
            throw CursorACPLaunchResolutionError.unsafeApplicationPath(identity.canonicalPath)
        }
        if canonicalURL.lastPathComponent.caseInsensitiveCompare("cursor") == .orderedSame {
            throw CursorACPLaunchResolutionError.unsafeCanonicalBasename(identity.canonicalPath)
        }

        return CursorACPResolvedLaunch(
            command: identity.canonicalPath,
            arguments: CursorACPLaunchCandidate.cursorAgentACP.launchArguments,
            additionalPathHints: additionalPathHints,
            environment: environment,
            executableIdentity: identity
        )
    }

    private func cachedLaunch(forKey key: String) -> CursorACPResolvedLaunch? {
        lock.lock()
        defer { lock.unlock() }
        return cachedLaunchByKey[key]
    }

    private func cache(_ launch: CursorACPResolvedLaunch, key: String) {
        lock.lock()
        cachedLaunchByKey[key] = launch
        lock.unlock()
    }

    private func invalidate(key: String) {
        lock.lock()
        cachedLaunchByKey.removeValue(forKey: key)
        lock.unlock()
    }

    private func cacheKey(for config: CursorAgentConfig) -> String {
        ([config.commandName] + config.additionalPathHints).joined(separator: "\u{1F}")
    }
}
