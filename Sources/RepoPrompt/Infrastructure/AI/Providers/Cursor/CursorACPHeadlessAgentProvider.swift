import Foundation
import RepoPromptACPProviders
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptDomainRuntime

/// Headless/discovery adapter for Cursor's ACP runtime.
///
/// Agent Mode owns the long-lived ACP runner; headless discovery paths use
/// the shared one-shot ACP headless bridge configured with Cursor's launch,
/// session-mode, and model-selection behavior.
package final class CursorACPHeadlessAgentProvider: HeadlessAgentProvider {
    package typealias ProviderFactory = @Sendable (_ config: CursorAgentConfig) -> any ACPAgentProvider
    package typealias ControllerFactory = ACPHeadlessAgentProviderBridge.ControllerFactory

    package typealias ModelSelection = (_ controller: ACPAgentSessionController, _ config: CursorAgentConfig) async throws -> Void

    private let config: CursorAgentConfig
    private let bridge: ACPHeadlessAgentProviderBridge

    #if DEBUG
        package var test_config: CursorAgentConfig {
            config
        }
    #endif

    package init(
        config: CursorAgentConfig,
        workspacePath: String? = nil,
        baseModel: String?,
        providerFactory: @escaping ProviderFactory,
        controllerFactory: @escaping ControllerFactory,
        applySelectedModel: @escaping ModelSelection
    ) {
        self.config = config
        let launchConfig = CursorAgentConfig(
            commandName: config.commandSelection == .automatic ? nil : config.commandName,
            additionalPathHints: config.additionalPathHints,
            enableDebugLogging: config.enableDebugLogging, modelString: baseModel,
            includeRepoPromptMCPServer: config.includeRepoPromptMCPServer,
            cleanupProjectMCPApproval: config.cleanupProjectMCPApproval,
            sessionModeID: config.sessionModeID
        )
        bridge = ACPHeadlessAgentProviderBridge(
            providerName: "Cursor",
            makeProvider: {
                providerFactory(launchConfig)
            },
            makeRequest: { message, _ in
                ACPRunRequest(
                    agentKind: .cursor,
                    modelString: baseModel,
                    workspacePath: workspacePath,
                    resumeSessionID: message.resumeSessionID,
                    attachments: [],
                    taskLabelKind: nil,
                    sessionModeID: config.sessionModeID
                )
            },
            makeController: controllerFactory,
            beforePrompt: { controller, _ in
                try await applySelectedModel(controller, config)
                if let sessionMode = Self.sessionModeToApply(config: config) {
                    try await controller.setSessionMode(sessionMode)
                }
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

    private static func sessionModeToApply(config: CursorAgentConfig) -> String? {
        guard let mode = config.sessionModeID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !mode.isEmpty
        else {
            return nil
        }
        return mode
    }
}
