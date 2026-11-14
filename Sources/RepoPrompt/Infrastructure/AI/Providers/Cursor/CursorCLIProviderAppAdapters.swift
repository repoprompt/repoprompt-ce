import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts

extension CursorCLIProvider {
    convenience init(
        headlessProviderFactory: @escaping HeadlessProviderFactory = { config, workspacePath in
            CursorACPHeadlessAgentProvider(config: config, workspacePath: workspacePath)
        }
    ) {
        self.init(
            configurationFactory: { model in
                Self.makeHeadlessConfig(modelName: Self.cursorModelName(for: model))
            },
            headlessProviderFactory: headlessProviderFactory
        )
    }

    private static func makeHeadlessConfig(modelName: String?) -> CursorAgentConfig {
        CursorAgentConfig(
            enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
            modelString: modelName,
            includeRepoPromptMCPServer: false,
            cleanupProjectMCPApproval: true,
            sessionModeID: CursorAgentConfig.promptOnlySessionModeID
        )
    }

    private static func cursorModelName(for model: AIModel) -> String? {
        guard model.providerType == .cursor else { return nil }
        let trimmed = model.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    #if DEBUG
        static func test_makeHeadlessConfig(modelName: String?) -> CursorAgentConfig {
            makeHeadlessConfig(modelName: modelName)
        }

        static func test_makeAgentMessage(from aiMessage: AIMessage) -> AgentMessage {
            CursorCLIProvider().makeAgentMessage(from: aiMessage)
        }
    #endif
}
