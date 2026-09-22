import Foundation

/// Headless/discovery adapter for Grok Build's ACP runtime (`grok agent stdio`).
///
/// Agent Mode owns the long-lived ACP runner; headless discovery paths use
/// the shared one-shot ACP headless bridge configured with Grok Build's launch
/// and model-selection behavior.
final class GrokBuildACPHeadlessAgentProvider: HeadlessAgentProvider {
    typealias ProviderFactory = @Sendable (_ config: GrokBuildAgentConfig) async throws -> any ACPAgentProvider
    typealias ControllerFactory = ACPHeadlessAgentProviderBridge.ControllerFactory

    private let config: GrokBuildAgentConfig
    private let bridge: ACPHeadlessAgentProviderBridge

    #if DEBUG
        var test_config: GrokBuildAgentConfig {
            config
        }
    #endif

    init(
        config: GrokBuildAgentConfig,
        workspacePath: String? = nil,
        providerFactory: ProviderFactory? = nil,
        controllerFactory: @escaping ControllerFactory = { provider, request, diagnosticSink in
            try ACPAgentSessionController(
                provider: provider,
                runRequest: request,
                diagnosticSink: diagnosticSink
            )
        }
    ) {
        self.config = config
        let resolvedProviderFactory = providerFactory ?? { config in
            // Resolve the stored Grok key here (async) — `AgentRuntimeProviderService.makeProvider`
            // is synchronous and cannot read the keychain, so headless configs arrive without it.
            try await GrokBuildACPAgentProvider(
                config: GrokBuildAgentConfig(
                    commandName: config.commandName,
                    additionalPathHints: config.additionalPathHints,
                    enableDebugLogging: config.enableDebugLogging,
                    modelString: config.modelString,
                    includeRepoPromptMCPServer: config.includeRepoPromptMCPServer,
                    alwaysApproveTools: config.alwaysApproveTools,
                    apiKey: KeyManager().getAPIKey(for: .grok)
                )
            )
        }
        bridge = ACPHeadlessAgentProviderBridge(
            providerName: "Grok Build",
            makeProvider: {
                try await resolvedProviderFactory(config)
            },
            makeRequest: { message, _ in
                ACPRunRequest(
                    agentKind: .grokBuild,
                    modelString: config.modelString,
                    workspacePath: workspacePath,
                    resumeSessionID: message.resumeSessionID,
                    attachments: [],
                    taskLabelKind: nil,
                    sessionModeID: nil,
                    autoApproveAllToolPermissions: config.alwaysApproveTools
                )
            },
            makeController: controllerFactory,
            beforePrompt: { controller, _ in
                try await Self.applySelectedModelIfNeeded(config: config, controller: controller)
            },
            approvalPolicy: .declineUnsupported
        )
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID? = nil
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        try await bridge.streamAgentMessage(message, runID: runID)
    }

    func dispose() async {
        await bridge.dispose()
    }

    private static func applySelectedModelIfNeeded(
        config: GrokBuildAgentConfig,
        controller: ACPAgentSessionController
    ) async throws {
        guard let model = config.modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty,
              model.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else {
            return
        }
        // No silent substitution: a concrete model must exist in the current Grok registry
        // snapshot; anything else fails before the prompt instead of running a stale model.
        guard AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)?.contains(rawModel: model) == true else {
            throw AIProviderError.invalidConfiguration(
                detail: "Grok Build model `\(model)` is not in the discovered model set. Refresh Grok Build models and retry."
            )
        }
        try await controller.setSessionModel(model)
    }
}
