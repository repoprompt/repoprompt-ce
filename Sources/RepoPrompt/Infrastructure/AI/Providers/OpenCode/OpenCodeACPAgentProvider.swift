import Foundation

struct OpenCodeACPAgentProvider: ACPAgentProvider {
    private enum LaunchContract {
        static let configContentEnvironmentKey = "OPENCODE_CONFIG_CONTENT"
    }

    private let config: OpenCodeAgentConfig
    private let repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration
    private let launchResolver: OpenCodeACPLaunchResolver
    private let recursiveMCPConfigGuidance: @Sendable () -> String?

    #if DEBUG
        var test_config: OpenCodeAgentConfig {
            config
        }
    #endif

    init(
        config: OpenCodeAgentConfig,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration = .repoPrompt,
        launchResolver: OpenCodeACPLaunchResolver = OpenCodeACPLaunchResolver(),
        recursiveMCPConfigGuidance: @escaping @Sendable () -> String? = {
            OpenCodeGlobalMCPConfigDiagnostic.detect()?.guidanceMessage
        }
    ) {
        self.config = config
        self.repoPromptMCPConfiguration = repoPromptMCPConfiguration
        self.launchResolver = launchResolver
        self.recursiveMCPConfigGuidance = recursiveMCPConfigGuidance
    }

    var providerID: ACPProviderID {
        .openCode
    }

    func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
        try await launchResolver.probeSupport(for: config)
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        let workingDirectory = standardizedWorkingDirectory(from: request.workspacePath)
        let resolvedLaunch = try launchResolver.resolvedLaunch(for: config)
        var environment: [String: String] = [:]

        if config.includeManagedConfigOverlay {
            if config.cleanupLegacyPersistentConfig {
                OpenCodeIntegrationConfiguration.cleanupLegacyACPConfigIfNeeded(
                    preserveExplicitMCPInstall: MCPIntegrationHelper.isMCPServerInstalled
                )
            }
            if config.includeRepoPromptMCPServer {
                try repoPromptMCPConfiguration.validateACPLaunchCommand(
                    workingDirectory: workingDirectory
                )
            }
            environment[LaunchContract.configContentEnvironmentKey] = try OpenCodeIntegrationConfiguration.ephemeralACPConfigJSON(
                includeRepoPromptMCPServer: config.includeRepoPromptMCPServer,
                repoPromptMCPConfiguration: repoPromptMCPConfiguration
            )
        }

        return ACPLaunchConfiguration(
            providerID: providerID,
            command: resolvedLaunch.command,
            arguments: resolvedLaunch.arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            additionalPathHints: resolvedLaunch.additionalPathHints,
            enableDebugLogging: config.enableDebugLogging,
            expectedExecutableIdentity: resolvedLaunch.executableIdentity
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        let mode: ACPSessionConfiguration.Mode = if let resume = request.resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
                                                    !resume.isEmpty
        {
            .load(existingSessionID: resume)
        } else {
            .new
        }

        return ACPSessionConfiguration(
            mode: mode,
            workingDirectory: standardizedWorkingDirectory(from: request.workspacePath),
            mcpServers: []
        )
    }

    func buildPromptBlocks(
        for message: AgentMessage,
        request: ACPRunRequest
    ) throws -> [[String: Any]] {
        let isFollowUp = request.resumeSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let systemPrompt = message.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let userMessage = message.userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String = if isFollowUp || systemPrompt.isEmpty {
            userMessage.isEmpty ? message.userMessage : userMessage
        } else if userMessage.isEmpty {
            systemPrompt
        } else {
            "\(systemPrompt)\n\n\(userMessage)"
        }

        return try ACPPromptContentBuilder.blocks(
            text: text,
            attachments: request.attachments
        )
    }

    func normalizeSessionUpdate(
        _ payload: [String: Any],
        sessionID _: String
    ) -> [NormalizedAgentRuntimeEvent] {
        OpenCodeACPEventNormalizer.normalize(payload, toolProfile: config.toolProfile)
    }

    func normalizeError(_ error: Error) -> Error {
        if error is AIProviderError {
            return error
        }
        if let runnerError = error as? CLIProcessRunnerError,
           case .commandNotFound = runnerError
        {
            return AIProviderError.invalidConfiguration(detail: "OpenCode CLI not found. Install it and ensure `opencode` is available on PATH.")
        }
        if error is OpenCodeACPLaunchResolutionError || error is ExecutableFileIdentityError {
            return AIProviderError.invalidConfiguration(detail: error.localizedDescription)
        }
        if let guidance = Self.openCodeACPStartupGuidance(
            for: error,
            recursiveMCPConfigGuidance: recursiveMCPConfigGuidance()
        ) {
            return AIProviderError.invalidConfiguration(detail: guidance)
        }
        if (error as NSError).domain == NSCocoaErrorDomain {
            return AIProviderError.invalidConfiguration(detail: "Unable to prepare OpenCode ACP config: \(error.localizedDescription)")
        }
        return AIProviderError.apiError(source: error)
    }

    private static func openCodeACPStartupGuidance(
        for error: Error,
        recursiveMCPConfigGuidance: String?
    ) -> String? {
        guard let timeout = error as? ACPRequestTimeoutError,
              ["initialize", "authenticate", "session/new", "session/load"].contains(timeout.method)
        else {
            return nil
        }

        let message = timeout.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let recursiveGuidance = recursiveMCPConfigGuidance?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let recovery = if let recursiveGuidance, !recursiveGuidance.isEmpty {
            " \(recursiveGuidance)"
        } else {
            " Update OpenCode with `opencode upgrade`, then verify `opencode --version` and `opencode acp --help` return promptly before retrying."
        }
        return "OpenCode ACP did not finish session startup.\(recovery) Original error: \(message)"
    }

    private func standardizedWorkingDirectory(from workspacePath: String?) -> String {
        let cwd = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cwd?.isEmpty == false ? cwd : nil)
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? FileManager.default.temporaryDirectory.path
    }
}

struct OpenCodeGlobalMCPConfigDiagnostic: Equatable {
    private static let maximumConfigBytes: UInt64 = 2 * 1024 * 1024

    let path: String
    let suspiciousKeys: [String]

    var guidanceMessage: String {
        let keys = suspiciousKeys.map { "`\($0)`" }.joined(separator: ", ")
        return "OpenCode may be loading RepoPrompt MCP server entries from its global config at `\(path)` (\(keys)). OpenCode loads global MCP servers during `opencode acp` startup; a RepoPrompt/RepoPrompt CE MCP entry can recursively launch RepoPrompt CE and block `session/new`. Back up the config, then remove or disable those OpenCode MCP entries (or temporarily set `\"mcp\": {}`) and retry."
    }

    static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> OpenCodeGlobalMCPConfigDiagnostic? {
        for path in candidateConfigPaths(environment: environment) {
            guard isRegularConfigFileWithinLimit(path, fileManager: fileManager),
                  let data = fileManager.contents(atPath: path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let diagnostic = diagnostic(in: object, path: path)
            else {
                continue
            }
            return diagnostic
        }
        return nil
    }

    static func diagnostic(in config: [String: Any], path: String) -> OpenCodeGlobalMCPConfigDiagnostic? {
        guard let mcp = config["mcp"] as? [String: Any], !mcp.isEmpty else { return nil }
        let keys = mcp.compactMap { key, value -> String? in
            if isRepoPromptReference(key) || containsRepoPromptReference(value) {
                return key
            }
            return nil
        }
        guard !keys.isEmpty else { return nil }
        return OpenCodeGlobalMCPConfigDiagnostic(path: path, suspiciousKeys: keys.sorted())
    }

    private static func isRegularConfigFileWithinLimit(_ path: String, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular
        else {
            return false
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value
            ?? attributes[.size] as? UInt64
        guard let size else { return false }
        return size <= maximumConfigBytes
    }

    private static func candidateConfigPaths(environment: [String: String]) -> [String] {
        var paths: [String] = []
        if let xdgConfigHome = environment["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !xdgConfigHome.isEmpty
        {
            paths.append(URL(fileURLWithPath: xdgConfigHome).appendingPathComponent("opencode/opencode.json").path)
        }
        let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty {
            paths.append(URL(fileURLWithPath: home).appendingPathComponent(".config/opencode/opencode.json").path)
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func containsRepoPromptReference(_ value: Any) -> Bool {
        if let string = value as? String {
            return isRepoPromptReference(string)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsRepoPromptReference)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.contains { key, value in
                isRepoPromptReference(key) || containsRepoPromptReference(value)
            }
        }
        return false
    }

    private static func isRepoPromptReference(_ string: String) -> Bool {
        let normalized = string.lowercased()
        return normalized.contains("repoprompt")
            || normalized.contains("repopromptce")
            || normalized.contains("repoprompt_ce_cli")
            || normalized.contains("repoprompt-mcp")
    }
}
