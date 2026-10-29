import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptProcess
import RepoPromptSettingsCore

package struct OpenCodeACPAgentProvider: ACPAgentProvider {
    private enum LaunchContract {
        static let configContentEnvironmentKey = "OPENCODE_CONFIG_CONTENT"
    }

    private let config: OpenCodeAgentConfig
    private let repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration
    private let launchResolver: OpenCodeACPLaunchResolver
    private let toolNames: ACPToolNameResolution
    private let prepareManagedOverlay: @Sendable (OpenCodeAgentConfig, RepoPromptMCPServerConfiguration, String) throws -> String

    #if DEBUG
        package var test_config: OpenCodeAgentConfig {
            config
        }
    #endif

    package init(
        config: OpenCodeAgentConfig,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration,
        launchResolver: OpenCodeACPLaunchResolver,
        toolNames: ACPToolNameResolution,
        prepareManagedOverlay: @escaping @Sendable (OpenCodeAgentConfig, RepoPromptMCPServerConfiguration, String) throws -> String
    ) {
        self.config = config
        self.repoPromptMCPConfiguration = repoPromptMCPConfiguration
        self.launchResolver = launchResolver
        self.toolNames = toolNames
        self.prepareManagedOverlay = prepareManagedOverlay
    }

    package var providerID: ACPProviderID {
        .openCode
    }

    package var supportsParameterizedModelPicker: Bool {
        true
    }

    package func modelParameterKind(for input: ACPModelParameterClassificationInput) -> ACPModelParameterKind? {
        let category = input.category?.trimmingCharacters(in: .whitespacesAndNewlines)
        let configID = input.configID.trimmingCharacters(in: .whitespacesAndNewlines)
        if category == "thought_level" || configID == "effort" {
            return .thinking
        }
        return nil
    }

    package func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
        try await launchResolver.probeSupport(for: config)
    }

    package func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        let workingDirectory = standardizedWorkingDirectory(from: request.workspacePath)
        let resolvedLaunch = try launchResolver.resolvedLaunch(for: config)
        var environment: [String: String] = [:]

        if config.includeManagedConfigOverlay {
            environment[LaunchContract.configContentEnvironmentKey] = try prepareManagedOverlay(config, repoPromptMCPConfiguration, workingDirectory)
        }

        return ACPLaunchConfiguration(
            providerID: providerID,
            command: resolvedLaunch.command,
            arguments: resolvedLaunch.arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            additionalPathHints: resolvedLaunch.additionalPathHints,
            enableDebugLogging: config.enableDebugLogging,
            expectedExecutableIdentity: resolvedLaunch.executableIdentity,
            explicitEnvironmentKeys: Set(environment.keys)
        )
    }

    package func makeSessionConfiguration(
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
        OpenCodeACPEventNormalizer.normalize(payload, toolProfile: config.toolProfile, toolNames: toolNames)
    }

    package func normalizeError(_ error: Error) -> Error {
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
        if (error as NSError).domain == NSCocoaErrorDomain {
            return AIProviderError.invalidConfiguration(detail: "Unable to prepare OpenCode ACP config: \(error.localizedDescription)")
        }
        return AIProviderError.apiError(source: error)
    }

    private func standardizedWorkingDirectory(from workspacePath: String?) -> String {
        let cwd = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cwd?.isEmpty == false ? cwd : nil)
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? FileManager.default.temporaryDirectory.path
    }
}
