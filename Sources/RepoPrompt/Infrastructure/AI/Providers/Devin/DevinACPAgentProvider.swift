import Foundation

/// Interactive Devin CLI ACP agent (`devin acp`, protocol version 1).
///
/// Verified against devin 3000.6.14: `promptCapabilities.image = true`,
/// `mcpCapabilities` is stdio-only, and MCP servers handed to `session/new` are spawned
/// but never registered into the state Devin's `mcp_*` gateway tools read. The isolated
/// `XDG_CONFIG_HOME` overlay prepared by `DevinIntegrationConfiguration` is therefore the
/// only route by which RepoPrompt's MCP tools reach Devin's model.
struct DevinACPAgentProvider: ACPAgentProvider {
    private let modelFamilies = DevinModelFamilyCatalog()
    private let config: DevinAgentConfig
    private let repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration
    private let launchResolver: ACPCLILaunchResolver

    init(
        config: DevinAgentConfig,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration = .repoPrompt,
        launchResolver: ACPCLILaunchResolver = ACPCLILaunchResolver(spec: .devin)
    ) {
        self.config = config
        self.repoPromptMCPConfiguration = repoPromptMCPConfiguration
        self.launchResolver = launchResolver
    }

    var providerID: ACPProviderID {
        .devin
    }

    func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
        let result = try await launchResolver.probeSupport(for: config)
        if result == .supported {
            try await modelFamilies.refresh(launch: launchResolver.resolvedLaunch(for: config))
        }
        return result
    }

    func modelFamily(for rawModel: String) -> AgentModelFamily? {
        modelFamilies.family(for: rawModel)
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
            environment: integration?.environment ?? [:],
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
            // Devin connects `session/new.mcpServers` but never registers them with its
            // `mcp_*` gateway, so a session-scoped server is invisible to the model. The
            // isolated XDG configuration overlay is the only working delivery path.
            mcpServers: []
        )
    }

    func buildPromptBlocks(
        for message: AgentMessage,
        request: ACPRunRequest
    ) throws -> [[String: Any]] {
        try ACPPromptContentBuilder.blocks(
            content: ACPPromptComposition.promptContentParts(for: message, request: request),
            attachments: request.attachments
        )
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
           // MCP calls arrive through Devin's `mcp_call_tool` gateway meta-tool; that
           // generic dispatcher name says nothing about the concrete tool, so leave it
           // unresolved rather than labelling every MCP call `mcp_call_tool`.
           toolName != "mcp_call_tool"
        {
            projected["toolName"] = toolName
        }
        return ACPDefaultSessionUpdateNormalizer.normalize(projected, providerID: .devin)
    }

    func cleanupLaunchArtifacts(for configuration: ACPLaunchConfiguration) async {
        guard let artifact = configuration.cleanupArtifact else { return }
        DevinIntegrationConfiguration.cleanup(artifact: artifact)
    }

    func shouldEmitStderrLine(_ line: String) -> Bool {
        // Devin traces routine INFO lines to stderr. Diagnostics still record every line;
        // only the exact observed tracing prefix is suppressed from the transcript.
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
        if error is ACPCLILaunchResolutionError || error is ExecutableFileIdentityError {
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
