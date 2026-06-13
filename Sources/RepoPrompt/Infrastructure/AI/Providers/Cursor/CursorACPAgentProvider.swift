import Foundation

struct CursorACPAgentProvider: ACPAgentProvider {
    private let config: CursorAgentConfig
    private let repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration
    private let launchResolver: CursorACPLaunchResolver

    #if DEBUG
        var test_config: CursorAgentConfig {
            config
        }
    #endif

    init(
        config: CursorAgentConfig,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration = .repoPrompt,
        launchResolver: CursorACPLaunchResolver = CursorACPLaunchResolver()
    ) {
        self.config = config
        self.repoPromptMCPConfiguration = repoPromptMCPConfiguration
        self.launchResolver = launchResolver
    }

    var providerID: ACPProviderID {
        .cursor
    }

    func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
        try await launchResolver.probeSupport(for: config)
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        let workingDirectory = try standardizedWorkingDirectory(from: request.workspacePath)
        let resolvedLaunch = try launchResolver.resolvedLaunch(for: config)
        var environment: [String: String] = [:]
        var cleanupArtifact: ACPLaunchCleanupArtifact?
        if config.includeRepoPromptMCPServer {
            let cursorDataDirectory = CursorIntegrationConfiguration.cursorDataDirectoryURL(
                workingDirectory: workingDirectory,
                environment: resolvedLaunch.environment
            )
            environment["CURSOR_DATA_DIR"] = cursorDataDirectory.path
            cleanupArtifact = try CursorIntegrationConfiguration.prepareProjectMCPApproval(
                workingDirectory: workingDirectory,
                cursorDataDirectory: cursorDataDirectory,
                repoPromptMCPConfiguration: repoPromptMCPConfiguration,
                cleanupAfterRun: config.cleanupProjectMCPApproval
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
            cleanupArtifact: cleanupArtifact,
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

        return try ACPSessionConfiguration(
            mode: mode,
            workingDirectory: standardizedWorkingDirectory(from: request.workspacePath),
            mcpServers: config.includeRepoPromptMCPServer ? [repoPromptMCPConfiguration] : []
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
        CursorACPEventNormalizer.normalize(payload)
    }

    func preferredAuthMethodID(context: ACPAuthenticationContext) -> String? {
        let envTokenKeys = ["CURSOR_API_KEY", "CURSOR_AUTH_TOKEN"]
        let hasEnvironmentToken = envTokenKeys.contains { key in
            context.environment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
        }
        guard !hasEnvironmentToken else { return nil }
        return context.authMethodIDs.first {
            $0.caseInsensitiveCompare("cursor_login") == .orderedSame
        }
    }

    func cleanupLaunchArtifacts(for configuration: ACPLaunchConfiguration) async {
        guard let artifact = configuration.cleanupArtifact,
              artifact.providerID == providerID,
              artifact.kind == CursorIntegrationConfiguration.cleanupArtifactKind
        else {
            return
        }
        CursorIntegrationConfiguration.cleanupProjectMCPApproval(leaseID: artifact.id)
    }

    func normalizeError(_ error: Error) -> Error {
        if error is AIProviderError {
            return error
        }
        if let runnerError = error as? CLIProcessRunnerError,
           case .commandNotFound = runnerError
        {
            return AIProviderError.invalidConfiguration(detail: "Cursor Agent CLI ACP server not found. Install Cursor Agent CLI and ensure `cursor-agent acp` is available.")
        }
        if error is CursorACPLaunchResolutionError || error is ExecutableFileIdentityError {
            return AIProviderError.invalidConfiguration(detail: error.localizedDescription)
        }
        if (error as NSError).domain == NSCocoaErrorDomain {
            return AIProviderError.invalidConfiguration(detail: "Unable to prepare Cursor MCP approval: \(error.localizedDescription)")
        }
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = description.lowercased()
        if lower.contains("session mode")
            || lower.contains("session/set_config_option")
            || lower.contains("mode config option")
        {
            return AIProviderError.invalidConfiguration(detail: description)
        }
        return AIProviderError.apiError(source: error)
    }

    private func standardizedWorkingDirectory(from workspacePath: String?) throws -> String {
        if let cwd = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            return URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL.path
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptCursorACPPreflight", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url.standardizedFileURL.path
    }
}
