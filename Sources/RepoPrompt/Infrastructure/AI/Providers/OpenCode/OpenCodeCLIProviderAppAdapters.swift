import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts

extension OpenCodeCLIProvider {
    convenience init() {
        self.init(
            configurationFactory: { model in
                Self.makeHeadlessConfig(modelName: Self.openCodeModelName(for: model))
            },
            headlessProviderFactory: { config, workspacePath in
                OpenCodeACPHeadlessAgentProvider(config: config, workspacePath: workspacePath)
            }
        )
    }

    private static func makeHeadlessConfig(modelName: String?) -> OpenCodeAgentConfig {
        OpenCodeAgentConfig(
            modelString: modelName,
            enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
            includeRepoPromptMCPServer: false,
            includeManagedConfigOverlay: true,
            cleanupLegacyPersistentConfig: true,
            toolProfile: .noTools
        )
    }

    private static func openCodeModelName(for model: AIModel) -> String? {
        guard model.providerType == .openCode else { return nil }
        let trimmed = model.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    #if DEBUG
        static func test_makeHeadlessConfig(modelName: String?) -> OpenCodeAgentConfig {
            makeHeadlessConfig(modelName: modelName)
        }

        static func test_makeAgentMessage(from aiMessage: AIMessage) -> AgentMessage {
            OpenCodeCLIProvider().makeAgentMessage(from: aiMessage)
        }
    #endif
}
