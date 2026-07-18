import Foundation
import RepoPromptProcessSupport

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
            case notFound
            case missingResolvedPath
            case resolvedToDirectory
            case notExecutable
        }

        let commandName: String
        let resolvedCommand: String
        let status: Status
        let pathValue: String?
        let additionalPathHints: [String]
        let userMessage: String
        let debugMessage: String
    }

    static func resolveCodexExecutable(
        commandName: String = CLILaunchProfiles.codex.commandName,
        environment: [String: String],
        additionalPathHints: [String] = CLILaunchProfiles.codex.supplementalSearchPaths,
        logger: ((String) -> Void)? = nil
    ) -> CodexExecutableResolution {
        let environment = normalizedPreflightEnvironment(environment)
        let expandedHints = normalizedPathHints(additionalPathHints, environment: environment)
        let preferredBasename = preferredBasename(for: commandName)
        var resolvedCommand = CommandPathResolver.resolve(
            commandName,
            environment: environment,
            additionalPaths: expandedHints,
            logger: logger,
            preferredBasenames: [preferredBasename],
            shellLookupMode: .fallbackOnly
        )
        var launchability = CommandPathResolver.launchability(of: resolvedCommand)

        if launchability == .bareCommandFallback,
           let existingCandidate = firstExistingSearchPathCandidate(
               for: commandName,
               environment: environment,
               additionalPathHints: expandedHints
           )
        {
            resolvedCommand = existingCandidate
            launchability = CommandPathResolver.launchability(of: existingCandidate)
        }

        let status = codexStatus(for: launchability)
        let userMessage = codexExecutableUserMessage(
            status: status,
            resolvedCommand: resolvedCommand
        )
        let debugMessage = codexExecutableDebugMessage(
            commandName: commandName,
            resolvedCommand: resolvedCommand,
            status: status,
            pathValue: environment["PATH"],
            additionalPathHints: expandedHints
        )
        logger?(debugMessage)

        return CodexExecutableResolution(
            commandName: commandName,
            resolvedCommand: resolvedCommand,
            status: status,
            pathValue: environment["PATH"],
            additionalPathHints: expandedHints,
            userMessage: userMessage,
            debugMessage: debugMessage
        )
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
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("Codex CLI executable was not found.") {
            return true
        }
        guard trimmed.hasPrefix("Codex CLI resolved to `") else {
            return false
        }
        return trimmed.contains("`, but that file does not exist.") ||
            trimmed.contains("`, but that path is a directory.") ||
            trimmed.contains("`, but it is not executable.")
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

    private static func codexStatus(for launchability: CLIExecutableLaunchability) -> CodexExecutableResolution.Status {
        switch launchability {
        case .launchable:
            .available
        case .bareCommandFallback:
            .notFound
        case .missingPath:
            .missingResolvedPath
        case .directory:
            .resolvedToDirectory
        case .notExecutable:
            .notExecutable
        }
    }

    private static func codexExecutableUserMessage(
        status: CodexExecutableResolution.Status,
        resolvedCommand: String
    ) -> String {
        switch status {
        case .available:
            ""
        case .notFound:
            "Codex CLI executable was not found. Install Codex CLI and ensure `codex` is available in your login shell PATH. RepoPrompt searched your login-shell PATH plus common Homebrew, npm/pnpm/yarn/Volta, Bun, Cargo, version-manager shim, and Codex.app locations."
        case .missingResolvedPath:
            "Codex CLI resolved to `\(resolvedCommand)`, but that file does not exist. Reinstall Codex CLI or fix your shell PATH."
        case .resolvedToDirectory:
            "Codex CLI resolved to `\(resolvedCommand)`, but that path is a directory. Fix your shell PATH so `codex` points to the executable."
        case .notExecutable:
            "Codex CLI resolved to `\(resolvedCommand)`, but it is not executable. Check file permissions or reinstall Codex CLI."
        }
    }

    private static func codexExecutableDebugMessage(
        commandName: String,
        resolvedCommand: String,
        status: CodexExecutableResolution.Status,
        pathValue: String?,
        additionalPathHints: [String]
    ) -> String {
        let pathDisplay = pathValue?.isEmpty == false ? pathValue! : "(empty)"
        let hintsDisplay = additionalPathHints.isEmpty ? "(none)" : additionalPathHints.joined(separator: ":")
        return "Codex executable preflight: command=\(commandName), resolved=\(resolvedCommand), status=\(status), PATH=\(pathDisplay), additionalHints=\(hintsDisplay)"
    }

    private static func normalizedPreflightEnvironment(_ environment: [String: String]) -> [String: String] {
        var normalized = environment
        if normalized["HOME"].map({ !$0.isEmpty }) != true {
            normalized["HOME"] = NSHomeDirectory()
        }
        return normalized
    }

    private static func normalizedPathHints(_ hints: [String], environment: [String: String]) -> [String] {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
        var normalized: [String] = []
        for hint in hints {
            for component in hint.split(separator: ":") {
                normalized.append(expandTilde(String(component), home: home))
            }
        }
        return orderedUnique(normalized)
    }

    private static func firstExistingSearchPathCandidate(
        for commandName: String,
        environment: [String: String],
        additionalPathHints: [String]
    ) -> String? {
        let expandedCommand = CommandPathResolver.expandPath(commandName, environment: environment)
        guard !expandedCommand.contains("/") else { return nil }
        let paths = CommandPathResolver.mergedPathComponents(
            environment: environment,
            additionalPaths: additionalPathHints
        )
        for path in paths {
            let candidate = (path as NSString).appendingPathComponent(expandedCommand)
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func preferredBasename(for commandName: String) -> String {
        let expanded = (commandName as NSString).expandingTildeInPath
        let basename = (expanded as NSString).lastPathComponent
        return basename.isEmpty ? commandName : basename
    }

    private static func expandTilde(_ path: String, home: String?) -> String {
        guard path.hasPrefix("~") else { return path }
        if let home, path == "~" {
            return home
        }
        if let home, path.hasPrefix("~/") {
            return home + String(path.dropFirst())
        }
        return (path as NSString).expandingTildeInPath
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        for value in values where !value.isEmpty && seen.insert(value).inserted {
            ordered.append(value)
        }
        return ordered
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
