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
        if let guidance = Self.openCodeACPStartupGuidance(for: error) {
            return AIProviderError.invalidConfiguration(detail: guidance)
        }
        if (error as NSError).domain == NSCocoaErrorDomain {
            return AIProviderError.invalidConfiguration(detail: "Unable to prepare OpenCode ACP config: \(error.localizedDescription)")
        }
        return AIProviderError.apiError(source: error)
    }

    private static func openCodeACPStartupGuidance(for error: Error) -> String? {
        guard let timeout = error as? ACPRequestTimeoutError,
              ["initialize", "authenticate", "session/new", "session/load"].contains(timeout.method)
        else {
            return nil
        }

        let message = timeout.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return "OpenCode ACP did not finish session startup. Update OpenCode with `opencode upgrade`, then verify `opencode --version` and `opencode acp --help` return promptly before retrying. Original error: \(message)"
    }

    private func standardizedWorkingDirectory(from workspacePath: String?) -> String {
        let cwd = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cwd?.isEmpty == false ? cwd : nil)
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? FileManager.default.temporaryDirectory.path
    }
}
