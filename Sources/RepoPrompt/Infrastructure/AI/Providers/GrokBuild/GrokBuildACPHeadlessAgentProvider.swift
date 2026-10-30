import Foundation
import RepoPromptACPProviders
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptDomainRuntime

/// Headless/discovery adapter for Grok Build's ACP runtime (`grok agent stdio`).
///
/// Agent Mode owns the long-lived ACP runner; headless discovery paths use
/// the shared one-shot ACP headless bridge configured with Grok Build's launch
/// and model-selection behavior.
package final class GrokBuildACPHeadlessAgentProvider: HeadlessAgentProvider {
    package typealias ProviderFactory = @Sendable (_ config: GrokBuildAgentConfig) async throws -> any ACPAgentProvider
    package typealias ControllerFactory = ACPHeadlessAgentProviderBridge.ControllerFactory

    private let config: GrokBuildAgentConfig
    private let bridge: ACPHeadlessAgentProviderBridge

    #if DEBUG
        package var test_config: GrokBuildAgentConfig {
            config
        }
    #endif

    package init(
        host: any GrokBuildACPHeadlessHost,
        config: GrokBuildAgentConfig,
        workspacePath: String? = nil,
        providerFactory: @escaping ProviderFactory,
        controllerFactory: @escaping ControllerFactory
    ) {
        self.config = config

        bridge = ACPHeadlessAgentProviderBridge(
            providerName: "Grok Build",
            makeProvider: {
                try await providerFactory(config)
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
                if let model = try host.selectedModel(config: config) {
                    try await controller.setSessionModel(model)
                }
            },
            approvalPolicy: .declineUnsupported
        )
    }

    package func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID? = nil
    ) async throws -> AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error> {
        try await bridge.streamAgentMessage(message, runID: runID)
    }

    package func dispose() async {
        await bridge.dispose()
    }
}
