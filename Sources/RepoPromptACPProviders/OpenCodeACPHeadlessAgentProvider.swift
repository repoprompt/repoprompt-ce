import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptDomainRuntime

/// Headless/discovery adapter for OpenCode's ACP runtime.
///
/// Agent Mode owns the long-lived ACP runner; headless discovery paths use
/// the shared one-shot ACP headless bridge configured with OpenCode's managed
/// headless session mode and optional selected model.
package final class OpenCodeACPHeadlessAgentProvider: HeadlessAgentProvider {
    package typealias ProviderFactory = @Sendable (_ config: OpenCodeAgentConfig) -> any ACPAgentProvider
    package typealias ControllerFactory = ACPHeadlessAgentProviderBridge.ControllerFactory

    package typealias SelectedModel = (_ config: OpenCodeAgentConfig) -> String?

    private let config: OpenCodeAgentConfig
    private let bridge: ACPHeadlessAgentProviderBridge

    #if DEBUG
        package var test_config: OpenCodeAgentConfig {
            config
        }
    #endif

    package init(
        config: OpenCodeAgentConfig,
        workspacePath: String? = nil,
        providerFactory: @escaping ProviderFactory,
        controllerFactory: @escaping ControllerFactory,
        selectedModel: @escaping SelectedModel
    ) {
        self.config = config
        bridge = ACPHeadlessAgentProviderBridge(
            providerName: "OpenCode",
            makeProvider: {
                providerFactory(config)
            },
            makeRequest: { message, _ in
                ACPRunRequest(
                    agentKind: .openCode,
                    modelString: config.modelString,
                    workspacePath: workspacePath,
                    resumeSessionID: message.resumeSessionID,
                    attachments: [],
                    taskLabelKind: nil,
                    sessionModeID: config.sessionModeID,
                    modelParameterSelections: config.modelParameterSelections
                )
            },
            makeController: controllerFactory,
            beforePrompt: { controller, request in
                // Order matters: OpenCode advertises `effort` only after the model is set, so
                // set model → apply selections → validate → set mode. A pin that cannot be
                // honoured fails here, before `session/prompt`, rather than silently running at
                // another level.
                let modelToApply = selectedModel(config)
                let selections = request.modelParameterSelections
                if let modelToApply {
                    // Force the model-selector RPC when a pin is pending: OpenCode advertises
                    // `effort` only after an actual model set, so the ordinary no-op skip would
                    // leave the pin unadvertised and therefore skipped.
                    try await controller.setSessionModel(modelToApply, forceRPC: !selections.isEmpty)
                }
                let parameterReport = try await controller.applySessionModelParameterSelections(selections)
                try parameterReport.validateNoSkippedSelections()
                try await controller.setSessionMode(config.sessionModeID)
            },
            approvalPolicy: .declineUnsupported
        )
    }

    package func streamAgentMessage(
        _ message: RepoPromptDomainRuntime.AgentMessage,
        runID: UUID? = nil
    ) async throws -> AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error> {
        try await bridge.streamAgentMessage(message, runID: runID)
    }

    package func dispose() async {
        await bridge.dispose()
    }
}
