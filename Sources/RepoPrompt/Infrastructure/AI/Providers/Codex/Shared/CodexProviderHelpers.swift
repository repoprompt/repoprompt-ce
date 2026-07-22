import Foundation

/// Singleton actor that manages the cache of broken Codex MCP servers.
/// Shared across all Codex provider instances (CLI and Exec Agent).
/// Broken servers are those that have malformed configurations (e.g., missing command field)
/// and cause "invalid transport" errors when we try to disable them.
actor CodexBrokenServersCache {
    static let shared = CodexBrokenServersCache()

    private var brokenServers: Set<String> = []

    private init() {}

    func add(_ serverName: String) {
        brokenServers.insert(serverName)
    }

    func getAll() -> Set<String> {
        brokenServers
    }
}

/// Helper utilities for Codex providers
enum CodexProviderHelpers {
    /// Returns a fresh app-server client for non-agent Codex flows.
    /// These flows should not share transport/process state across chat, health checks,
    /// and model polling because failures become sticky across otherwise unrelated work.
    static func makeOwnedNonAgentAppServerClient() -> CodexAppServerClient {
        let _ = MCPIntegrationHelper.ensureCodexServerForDiscovery()
        return CodexAppServerClient()
    }

    struct CodexExecutableResolution: Equatable {
        enum Status: Equatable {
            case available
            case bundledRuntimeUnavailable
            case externalOverrideInvalid
            case externalOverrideIncompatible
            case unsupportedArchitecture
        }

        let commandName: String
        let resolvedCommand: String
        let status: Status
        let runtime: CodexRuntimeAuthority.Runtime?
        let userMessage: String
        let debugMessage: String

        var environmentOverrides: [String: String] {
            runtime?.statePaths.environment ?? [:]
        }

        var displayDescription: String? {
            guard let runtime else { return nil }
            return switch runtime.source {
            case let .bundled(target):
                "Bundled Codex \(runtime.version) (\(target))"
            case .externalOverride:
                "External Codex override \(runtime.version) (\(runtime.executableURL.lastPathComponent))"
            }
        }
    }

    static func resolveCodexExecutable(
        commandName: String = CLILaunchProfiles.codex.commandName,
        environment: [String: String],
        additionalPathHints: [String] = CLILaunchProfiles.codex.supplementalSearchPaths,
        logger: ((String) -> Void)? = nil
    ) -> CodexExecutableResolution {
        _ = additionalPathHints // Kept for source compatibility; PATH fallback is intentionally disabled.
        let injectedOverride = commandName == CLILaunchProfiles.codex.commandName ? nil : commandName
        switch CodexRuntimeAuthority.resolve(
            environment: environment,
            explicitExecutableOverride: injectedOverride
        ) {
        case let .success(runtime):
            let debugMessage = runtime.redactedDiagnosticSummary
            logger?(debugMessage)
            return CodexExecutableResolution(
                commandName: commandName,
                resolvedCommand: runtime.executableURL.path,
                status: .available,
                runtime: runtime,
                userMessage: "",
                debugMessage: debugMessage
            )
        case let .failure(failure):
            let status: CodexExecutableResolution.Status = switch failure {
            case .unsupportedArchitecture:
                .unsupportedArchitecture
            case .externalOverrideTooOld:
                .externalOverrideIncompatible
            case .externalOverrideMustBeAbsolute,
                 .externalOverrideMissing,
                 .externalOverrideNotExecutable,
                 .externalOverrideVersionUnreadable:
                .externalOverrideInvalid
            default:
                .bundledRuntimeUnavailable
            }
            let debugMessage = "Codex runtime authority: status=\(status), failure=\(failureDiagnosticCode(failure))"
            logger?(debugMessage)
            return CodexExecutableResolution(
                commandName: commandName,
                resolvedCommand: "",
                status: status,
                runtime: nil,
                userMessage: failure.localizedDescription,
                debugMessage: debugMessage
            )
        }
    }

    static func preflightCodexExecutable(
        commandName: String = CLILaunchProfiles.codex.commandName,
        additionalPathHints: [String] = CLILaunchProfiles.codex.supplementalSearchPaths,
        enableDebugLogging: Bool = false,
        logCollector: CLIProcessLogCollector? = nil
    ) async -> CodexExecutableResolution {
        let environmentResult = await ProcessEnvironmentBuilder.build(
            ProcessEnvironmentRequest(
                purpose: .codexPreflight,
                enableDebugLogging: enableDebugLogging
            )
        )
        let logger: ((String) -> Void)? = { message in
            logCollector?.append(message)
            if enableDebugLogging {
                print("[CodexPreflight] \(message)")
            }
        }
        return resolveCodexExecutable(
            commandName: commandName,
            environment: environmentResult.environment,
            additionalPathHints: additionalPathHints,
            logger: logger
        )
    }

    static func isCodexExecutableUnavailableMessage(_ message: String) -> Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("RepoPrompt could not start Codex:")
    }

    /// Extracts the name of a broken MCP server from Codex CLI stderr output.
    /// Parses error messages like:
    /// - "Error: invalid transport\nin `mcp_servers.ServerName`"
    /// - "Error: invalid transport in `mcp_servers.ServerName`"
    ///
    /// - Parameter stderr: The stderr string from Codex CLI
    /// - Returns: The server name (e.g., "datadog") if found, nil otherwise
    static func extractBrokenServerName(from stderr: String) -> String? {
        let nsString = stderr as NSString
        let range = NSRange(location: 0, length: nsString.length)

        // First try to match MCP client startup failures (e.g., timeout, connection errors)
        // - "MCP client for `ServerName` failed to start: request timed out"
        // - "MCP client for `ServerName` failed to start"
        let mcpFailurePattern = #"MCP client for [`'"]?([^`'"]+)[`'"]? failed to start"#
        if let mcpFailureRegex = try? NSRegularExpression(pattern: mcpFailurePattern, options: [.caseInsensitive]),
           let match = mcpFailureRegex.firstMatch(in: stderr, range: range),
           match.numberOfRanges >= 2
        {
            let serverNameRange = match.range(at: 1)
            if serverNameRange.location != NSNotFound {
                return nsString.substring(with: serverNameRange)
            }
        }

        // Fall back to invalid transport pattern:
        // - "Error: invalid transport\nin `mcp_servers.ServerName`"
        // - "Error: invalid transport in 'mcp_servers.ServerName'"
        // - "Error: invalid transport in \"mcp_servers.Server Name\""
        // - "Error: invalid transport in mcp_servers.ServerName"
        let transportPattern = #"invalid transport(?:\s+in)?[\s\S]*?['"`]?mcp_servers\.([^'"`\r\n]+)"#
        guard let transportRegex = try? NSRegularExpression(pattern: transportPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }

        guard let match = transportRegex.firstMatch(in: stderr, range: range), match.numberOfRanges >= 2 else {
            return nil
        }

        let serverNameRange = match.range(at: 1)
        guard serverNameRange.location != NSNotFound else { return nil }

        return nsString.substring(with: serverNameRange)
    }

    /// Returns a fallback model when Codex reports that a GPT-5.3 Codex model is unavailable.
    /// Maps reasoning tiers from gpt-5.3-codex-* to gpt-5.2-codex-* for a single retry.
    static func codexFallbackModelIfNeeded(attemptedModel: String?, errorDetail: String) -> String? {
        guard let attemptedModel, attemptedModel != "default" else { return nil }
        guard attemptedModel.hasPrefix("gpt-5.3-codex") else { return nil }

        let lowerDetail = errorDetail.lowercased()
        let indicatesMissingModel = lowerDetail.contains("model_not_found") ||
            (lowerDetail.contains("requested model") && lowerDetail.contains("does not exist")) ||
            (lowerDetail.contains("404") && lowerDetail.contains("model"))
        guard indicatesMissingModel else { return nil }

        // Ensure this is the expected gpt-5.3-codex mismatch and not an unrelated model error.
        guard lowerDetail.contains("gpt-5.3-codex") || attemptedModel.contains("gpt-5.3-codex") else {
            return nil
        }

        if attemptedModel.hasSuffix("-xhigh") {
            return "gpt-5.2-codex-xhigh"
        }
        if attemptedModel.hasSuffix("-high") {
            return "gpt-5.2-codex-high"
        }
        if attemptedModel.hasSuffix("-medium") {
            return "gpt-5.2-codex-medium"
        }
        if attemptedModel.hasSuffix("-low") {
            return "gpt-5.2-codex-low"
        }

        return "gpt-5.2-codex"
    }

    private static func failureDiagnosticCode(_ failure: CodexRuntimeAuthority.Failure) -> String {
        switch failure {
        case .unsupportedArchitecture: "unsupported-architecture"
        case .bundledResourcesUnavailable: "bundled-resources-unavailable"
        case .bundledPackageMissing: "bundled-package-missing"
        case .bundledMetadataUnreadable: "bundled-metadata-unreadable"
        case .bundledMetadataMismatch: "bundled-metadata-mismatch"
        case .bundledLayoutIncomplete: "bundled-layout-incomplete"
        case .externalOverrideMustBeAbsolute: "override-not-absolute"
        case .externalOverrideMissing: "override-missing"
        case .externalOverrideNotExecutable: "override-not-executable"
        case .externalOverrideVersionUnreadable: "override-version-unreadable"
        case .externalOverrideTooOld: "override-version-too-old"
        }
    }

    static func normalizedAssistantDeltaForAppend(existingText: String, delta: String) -> String {
        guard shouldInsertAssistantSentenceBreak(existingText: existingText, delta: delta) else {
            return delta
        }
        return "\n" + delta
    }

    private static func shouldInsertAssistantSentenceBreak(existingText: String, delta: String) -> Bool {
        guard !existingText.isEmpty, !delta.isEmpty else { return false }
        guard !isInsideFencedCodeBlock(existingText) else { return false }
        guard !isInsideInlineCodeSpan(existingText) else { return false }
        guard let lastCharacter = existingText.last, lastCharacter == "." else { return false }
        guard let previousCharacter = existingText.dropLast().last, previousCharacter.isLowercase else { return false }
        return startsWithSentenceLikeWord(delta)
    }

    private static func startsWithSentenceLikeWord(_ text: String) -> Bool {
        guard let firstCharacter = text.first, !firstCharacter.isWhitespace, firstCharacter.isUppercase else {
            return false
        }
        var sawLowercase = false
        var sawLetter = false
        for character in text {
            if character.isLetter {
                sawLetter = true
                if character.isLowercase {
                    sawLowercase = true
                }
                continue
            }
            if character == "'" || character == "’" {
                continue
            }
            if character.isWhitespace {
                return sawLetter && sawLowercase
            }
            return false
        }
        return sawLetter && sawLowercase
    }

    private static func isInsideFencedCodeBlock(_ text: String) -> Bool {
        let fenceCount = text.components(separatedBy: "```").count - 1
        return fenceCount.isMultiple(of: 2) == false
    }

    private static func isInsideInlineCodeSpan(_ text: String) -> Bool {
        let backtickCount = text.replacingOccurrences(of: "```", with: "").count(where: { $0 == "`" })
        return backtickCount.isMultiple(of: 2) == false
    }
}
