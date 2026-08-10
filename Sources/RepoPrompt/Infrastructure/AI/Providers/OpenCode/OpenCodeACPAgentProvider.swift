import Foundation

struct OpenCodeACPAgentProvider: ACPAgentProvider {
    private enum LaunchContract {
        static let configContentEnvironmentKey = "OPENCODE_CONFIG_CONTENT"
    }

    private let config: OpenCodeAgentConfig
    private let repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration
    private let launchResolver: OpenCodeACPLaunchResolver

    #if DEBUG
        var test_config: OpenCodeAgentConfig {
            config
        }
    #endif

    init(
        config: OpenCodeAgentConfig,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration = .repoPrompt,
        launchResolver: OpenCodeACPLaunchResolver = OpenCodeACPLaunchResolver()
    ) {
        self.config = config
        self.repoPromptMCPConfiguration = repoPromptMCPConfiguration
        self.launchResolver = launchResolver
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
                repoPromptMCPConfiguration: repoPromptMCPConfiguration,
                workingDirectory: workingDirectory
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
        if let guidance = Self.openCodeACPStartupTimeoutGuidance(for: error) {
            return AIProviderError.invalidConfiguration(detail: guidance)
        }
        if (error as NSError).domain == NSCocoaErrorDomain {
            return AIProviderError.invalidConfiguration(detail: "Unable to prepare OpenCode ACP config: \(error.localizedDescription)")
        }
        return AIProviderError.apiError(source: error)
    }

    private static func openCodeACPStartupTimeoutGuidance(for error: Error) -> String? {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = message.lowercased()
        let isStartupTimeout = lower.contains("acp request")
            && lower.contains("timed out")
            && (lower.contains("session/new")
                || lower.contains("session/load")
                || lower.contains("initialize")
                || lower.contains("authenticate"))
        guard isStartupTimeout else { return nil }
        return """
        OpenCode ACP did not finish session startup. OpenCode merges global/project MCP servers into ACP `session/new` and waits for them to connect; a slow or hanging MCP entry (including a recursive RepoPrompt CE CLI) can exceed the bootstrap timeout. RepoPrompt disables discovered inherited MCP names in its process-ephemeral overlay—update OpenCode (`opencode upgrade`) and remove or disable hanging entries under `mcp` in `~/.config/opencode/opencode.json` if this persists. Original error: \(message)
        """
    }

    private func standardizedWorkingDirectory(from workspacePath: String?) -> String {
        let cwd = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cwd?.isEmpty == false ? cwd : nil)
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? FileManager.default.temporaryDirectory.path
    }
}
