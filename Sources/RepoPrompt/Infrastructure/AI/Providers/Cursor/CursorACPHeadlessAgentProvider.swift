import Foundation

/// Headless/discovery adapter for Cursor's ACP runtime.
///
/// Agent Mode owns the long-lived ACP runner; headless discovery paths use
/// the shared one-shot ACP headless bridge configured with Cursor's launch,
/// session-mode, and model-selection behavior.
final class CursorACPHeadlessAgentProvider: HeadlessAgentProvider {
    typealias ProviderFactory = @Sendable (_ config: CursorAgentConfig) -> any ACPAgentProvider
    typealias ControllerFactory = ACPHeadlessAgentProviderBridge.ControllerFactory

    private let config: CursorAgentConfig
    private let bridge: ACPHeadlessAgentProviderBridge

    #if DEBUG
        var test_config: CursorAgentConfig {
            config
        }
    #endif

    init(
        config: CursorAgentConfig,
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
            CursorACPAgentProvider(config: config)
        }
        bridge = ACPHeadlessAgentProviderBridge(
            providerName: "Cursor",
            makeProvider: {
                resolvedProviderFactory(config)
            },
            makeRequest: { message, _ in
                ACPRunRequest(
                    agentKind: .cursor,
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
                if let sessionMode = Self.sessionModeToApply(config: config) {
                    try await controller.setSessionMode(sessionMode)
                }
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

    private static func sessionModeToApply(config: CursorAgentConfig) -> String? {
        guard let mode = config.sessionModeID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !mode.isEmpty
        else {
            return nil
        }
        return mode
    }

    private static func selectedModelToApply(config: CursorAgentConfig) -> String? {
        guard let model = config.modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty,
              model.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else {
            return nil
        }
        if model.caseInsensitiveCompare(AgentModel.cursorAuto.rawValue) == .orderedSame {
            return model
        }
        guard AgentACPModelRegistry.shared.resolvedSnapshot(for: .cursor)?.contains(rawModel: model) == true else {
            return nil
        }
        return model
    }
}
