import Foundation

struct DevinACPAgentProvider: ACPAgentProvider {
    private let config: DevinAgentConfig
    private let repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration
    private let launchResolver: DevinACPLaunchResolver

    init(
        config: DevinAgentConfig,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration = .repoPrompt,
        launchResolver: DevinACPLaunchResolver = DevinACPLaunchResolver()
    ) {
        self.config = config
        self.repoPromptMCPConfiguration = repoPromptMCPConfiguration
        self.launchResolver = launchResolver
    }

    var providerID: ACPProviderID {
        .devin
    }

    func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
        try await launchResolver.probeSupport(for: config)
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        let workingDirectory = try standardizedWorkingDirectory(from: request.workspacePath)
        let resolvedLaunch = try launchResolver.resolvedLaunch(for: config)
        let integration: DevinIntegrationConfiguration.PreparedConfiguration? = if config.includeRepoPromptMCPServer {
            try DevinIntegrationConfiguration.prepare(
                workingDirectory: workingDirectory,
                repoPromptMCPConfiguration: repoPromptMCPConfiguration,
                sourceEnvironment: resolvedLaunch.environment
            )
        } else {
            nil
        }
        return ACPLaunchConfiguration(
            providerID: providerID,
            command: resolvedLaunch.command,
            arguments: resolvedLaunch.arguments,
            environment: resolvedLaunch.environment.merging(integration?.environment ?? [:]) { _, overlay in overlay },
            workingDirectory: workingDirectory,
            additionalPathHints: resolvedLaunch.additionalPathHints,
            enableDebugLogging: config.enableDebugLogging,
            cleanupArtifact: integration?.cleanupArtifact,
            expectedExecutableIdentity: resolvedLaunch.executableIdentity
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        let mode: ACPSessionConfiguration.Mode = if let resume = request.resumeSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines), !resume.isEmpty
        {
            .load(existingSessionID: resume)
        } else {
            .new
        }
        return try ACPSessionConfiguration(
            mode: mode,
            workingDirectory: standardizedWorkingDirectory(from: request.workspacePath),
            // Use only the isolated XDG configuration for RepoPrompt MCP injection.
            // Native ACP injection needs new/load/tool proof before replacing this route.
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
        return try ACPPromptContentBuilder.blocks(text: text, attachments: request.attachments)
    }

    func normalizeSessionUpdate(
        _ payload: [String: Any],
        sessionID _: String
    ) -> [NormalizedAgentRuntimeEvent] {
        var projected = payload
        if let update = (payload["sessionUpdate"] as? String)?.lowercased(),
           update == "tool_call" || update == "tool_call_update",
           let metadata = payload["_meta"] as? [String: Any],
           let toolName = ACPRuntimeEventParsing.firstMachineIdentifier(
               in: metadata,
               keys: ["cognition.ai/toolName", "cognition.ai/inferenceToolName"]
           ),
           toolName != "mcp_call_tool"
        {
            // Replay can replace inferenceToolName with a generic dispatcher; prefer
            // toolName when present, and leave generic-only partial records unresolved.
            projected["toolName"] = toolName
        }
        return ACPDefaultSessionUpdateNormalizer.normalize(projected, providerID: .devin)
    }

    func cleanupLaunchArtifacts(for configuration: ACPLaunchConfiguration) async {
        guard let artifact = configuration.cleanupArtifact else { return }
        DevinIntegrationConfiguration.cleanup(artifact: artifact)
    }

    func shouldEmitStderrLine(_ line: String) -> Bool {
        // The controller records diagnostics and strips ANSI before this presentation gate.
        // Only the observed tracing INFO prefix is noise; retain unknown formats and failures.
        line.range(
            of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\s+INFO\s+"#,
            options: .regularExpression
        ) == nil
    }

    func normalizeError(_ error: Error) -> Error {
        if error is AIProviderError { return error }
        if let runnerError = error as? CLIProcessRunnerError,
           case .commandNotFound = runnerError
        {
            return AIProviderError.invalidConfiguration(
                detail: "Devin ACP server not found. Install Devin and ensure `devin acp` is available."
            )
        }
        if error is DevinACPLaunchResolutionError || error is ExecutableFileIdentityError {
            return AIProviderError.invalidConfiguration(detail: error.localizedDescription)
        }
        return AIProviderError.apiError(source: error)
    }

    private func standardizedWorkingDirectory(from workspacePath: String?) throws -> String {
        if let cwd = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            return URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL.path
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptDevinACPPreflight", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL.path
    }
}
