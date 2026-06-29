import Foundation

/// Headless/discovery adapter for Droid's ACP runtime.
///
/// Agent Mode owns the long-lived ACP runner; headless discovery paths use
/// the shared one-shot ACP headless bridge configured with Droid's managed
/// headless session mode and optional selected model.
final class DroidACPHeadlessAgentProvider: HeadlessAgentProvider {
    typealias ProviderFactory = @Sendable (_ config: DroidAgentConfig) -> any ACPAgentProvider
    typealias ControllerFactory = ACPHeadlessAgentProviderBridge.ControllerFactory

    private let config: DroidAgentConfig
    private let bridge: ACPHeadlessAgentProviderBridge

    #if DEBUG
        var test_config: DroidAgentConfig {
            config
        }
    #endif

    init(
        config: DroidAgentConfig,
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
            DroidACPAgentProvider(config: config)
        }
        bridge = ACPHeadlessAgentProviderBridge(
            providerName: "Droid",
            makeProvider: {
                resolvedProviderFactory(config)
            },
            makeRequest: { message, _ in
                ACPRunRequest(
                    agentKind: .droid,
                    modelString: config.modelString,
                    workspacePath: workspacePath,
                    resumeSessionID: message.resumeSessionID,
                    attachments: [],
                    taskLabelKind: nil,
                    sessionModeID: config.sessionModeID
                )
            },
            makeController: controllerFactory,
            beforePrompt: { controller, _ in
                if let model = Self.selectedModelToApply(config: config) {
                    try await controller.setSessionModel(model)
                }
                try await controller.setSessionMode(config.sessionModeID)
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

    private static func selectedModelToApply(config: DroidAgentConfig) -> String? {
        guard let model = config.modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty,
              model.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else {
            return nil
        }
        return model
    }
}
