import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptProcess

package struct DevinACPAgentProvider: ACPAgentProvider {
    package enum MCPServersPolicy {
        case mergeRepoPrompt(RepoPromptMCPServerConfiguration)
        case disableAll
    }

    package struct PreparedIntegration {
        package let environment: [String: String]
        package let cleanupArtifact: ACPLaunchCleanupArtifact

        package init(environment: [String: String], cleanupArtifact: ACPLaunchCleanupArtifact) {
            self.environment = environment
            self.cleanupArtifact = cleanupArtifact
        }
    }

    package typealias PermissionArguments = @Sendable (_ launchPermissionMode: String?) throws -> [String]
    package typealias IntegrationPreparer = @Sendable (
        _ workingDirectory: String,
        _ mcpServers: MCPServersPolicy,
        _ sourceEnvironment: [String: String],
        _ isolateForeignMCPImports: Bool
    ) throws -> PreparedIntegration
    package typealias IntegrationCleanup = @Sendable (_ artifact: ACPLaunchCleanupArtifact) -> Void

    private let config: DevinAgentConfig
    private let repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration
    private let launchResolver: DevinACPLaunchResolver
    private let isolateForeignMCPImports: Bool
    private let toolNames: ACPToolNameResolution
    private let permissionArguments: PermissionArguments
    private let prepareIntegration: IntegrationPreparer
    private let cleanupIntegration: IntegrationCleanup

    package init(
        config: DevinAgentConfig,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration,
        launchResolver: DevinACPLaunchResolver,
        isolateForeignMCPImports: Bool,
        toolNames: ACPToolNameResolution,
        permissionArguments: @escaping PermissionArguments,
        prepareIntegration: @escaping IntegrationPreparer,
        cleanupIntegration: @escaping IntegrationCleanup
    ) {
        self.config = config
        self.repoPromptMCPConfiguration = repoPromptMCPConfiguration
        self.launchResolver = launchResolver
        self.isolateForeignMCPImports = isolateForeignMCPImports
        self.toolNames = toolNames
        self.permissionArguments = permissionArguments
        self.prepareIntegration = prepareIntegration
        self.cleanupIntegration = cleanupIntegration
    }

    package var providerID: ACPProviderID {
        .devin
    }

    package var supportsParameterizedModelPicker: Bool {
        true
    }

    package func modelParameterKind(for input: ACPModelParameterClassificationInput) -> ACPModelParameterKind? {
        input.category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "thought_level"
            ? .thinking : nil
    }

    package func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
        try await launchResolver.probeSupport(for: config)
    }

    /// `--permission-mode` is a TOP-LEVEL `devin` option (3000.10.21); `devin acp --help`
    /// does not advertise it, so the flag must precede the `acp` subcommand. Unknown
    /// non-empty carrier values are rejected rather than silently degrading to no flag.
    package func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        let workingDirectory = try standardizedWorkingDirectory(from: request.workspacePath)
        let resolvedLaunch = try launchResolver.resolvedLaunch(for: config)
        let permissionArguments = try permissionArguments(request.launchPermissionMode)
        let integration = try prepareIntegration(
            workingDirectory,
            config.includeRepoPromptMCPServer
                ? .mergeRepoPrompt(repoPromptMCPConfiguration)
                : .disableAll,
            resolvedLaunch.environment,
            isolateForeignMCPImports
        )
        return ACPLaunchConfiguration(
            providerID: providerID,
            command: resolvedLaunch.command,
            arguments: permissionArguments + resolvedLaunch.arguments,
            environment: resolvedLaunch.environment.merging(integration.environment) { _, overlay in overlay },
            workingDirectory: workingDirectory,
            additionalPathHints: resolvedLaunch.additionalPathHints,
            enableDebugLogging: config.enableDebugLogging,
            cleanupArtifact: integration.cleanupArtifact,
            expectedExecutableIdentity: resolvedLaunch.executableIdentity,
            explicitEnvironmentKeys: Set(integration.environment.keys)
        )
    }

    package func makeSessionConfiguration(
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

    package func buildPromptBlocks(
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
            attachments: request.attachments,
            oracleAttachments: message.attachments
        )
    }

    package func normalizeSessionUpdate(
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
        return ACPDefaultSessionUpdateNormalizer.normalize(projected, providerID: .devin, toolNames: toolNames)
    }

    package func cleanupLaunchArtifacts(for configuration: ACPLaunchConfiguration) async {
        guard let artifact = configuration.cleanupArtifact else { return }
        cleanupIntegration(artifact)
    }

    package func shouldEmitStderrLine(_ line: String) -> Bool {
        let suppressedPattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\s+(?:INFO\s+|WARN\s+(?:message_forest:\s+MessageChain tree duplication:|windsurf_api_client::remote_config:\s+remote config revalidation failed,\s+keeping last-good value:))"#
        return line.range(of: suppressedPattern, options: .regularExpression) == nil
    }

    package static let emptyResponseUserMessage =
        "Devin ended this turn without a response. The session is still open; send a message to continue."

    /// Devin's `EmptyResponse` agent error (`-32021`, `cognition.ai/errorKind = empty_response`,
    /// `cognition.ai/retryable = true`) ends only the turn; its ACP process and session stay usable.
    /// Other Devin error kinds keep the ordinary failure until their session state is verified.
    package func sessionPreservingPromptFailure(forResponseError error: [String: Any]) -> ACPSessionPreservingPromptFailure? {
        guard error["code"] as? Int == -32021,
              let data = error["data"] as? [String: Any],
              data["cognition.ai/errorKind"] as? String == "empty_response",
              // A JSON boolean only: Foundation also bridges the number `1` to `true`.
              let retryable = data["cognition.ai/retryable"] as? NSNumber,
              CFGetTypeID(retryable) == CFBooleanGetTypeID(),
              retryable.boolValue
        else { return nil }
        return ACPSessionPreservingPromptFailure(userMessage: Self.emptyResponseUserMessage)
    }

    package func normalizeError(_ error: Error) -> Error {
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
