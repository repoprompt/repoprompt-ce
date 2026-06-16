import Foundation

/// Headless/discovery adapter for Grok Build's ACP runtime.
final class GrokACPHeadlessAgentProvider: HeadlessAgentProvider {
    typealias ProviderFactory = @Sendable (_ config: GrokAgentConfig) -> any ACPAgentProvider
    typealias ControllerFactory = ACPHeadlessAgentProviderBridge.ControllerFactory

    private let config: GrokAgentConfig
    private let bridge: ACPHeadlessAgentProviderBridge

    #if DEBUG
        var test_config: GrokAgentConfig {
            config
        }
    #endif

    init(
        config: GrokAgentConfig,
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
            GrokACPAgentProvider(config: config)
        }
        bridge = ACPHeadlessAgentProviderBridge(
            providerName: "Grok",
            makeProvider: {
                resolvedProviderFactory(config)
            },
            makeRequest: { message, _ in
                ACPRunRequest(
                    agentKind: .grok,
                    modelString: config.modelString,
                    workspacePath: workspacePath,
                    resumeSessionID: message.resumeSessionID,
                    attachments: [],
                    taskLabelKind: nil,
                    sessionModeID: nil,
                    autoApproveAllToolPermissions: config.alwaysApproveToolPermissions
                )
            },
            makeController: controllerFactory,
            beforePrompt: { controller, _ in
                if let model = Self.selectedModelToApply(config: config) {
                    try await controller.setSessionModel(model)
                }
            }
        )
    }

    func run(message: AgentMessage) async throws -> AIStreamResult {
        try await bridge.run(message: message)
    }

    private static func selectedModelToApply(config: GrokAgentConfig) -> String? {
        let trimmed = config.modelString?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        if trimmed.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) == .orderedSame {
            return nil
        }
        return trimmed
    }
}