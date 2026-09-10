import Foundation

final class DevinCLIProvider: AIProvider {
    private let engine = ACPCLIChatProviderEngine<DevinACPHeadlessAgentProvider>(
        providerName: "Devin",
        providerType: .devin,
        makeProvider: { modelName in
            DevinACPHeadlessAgentProvider(
                config: DevinCLIProvider.makeHeadlessConfig(modelName: modelName),
                workspacePath: nil
            )
        }
    )

    #if DEBUG
        static func test_makeHeadlessConfig(modelName: String?) -> DevinAgentConfig {
            makeHeadlessConfig(modelName: modelName)
        }
    #endif

    func streamMessage(
        _ aiMessage: AIMessage,
        model: AIModel,
        maxTokens: Int? = nil
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        try await engine.streamMessage(aiMessage, model: model, maxTokens: maxTokens)
    }

    func completeMessage(
        _ aiMessage: AIMessage,
        model: AIModel,
        maxTokens: Int? = nil
    ) async throws -> AICompletionResult {
        try await engine.completeMessage(aiMessage, model: model, maxTokens: maxTokens)
    }

    func dispose() async {
        await engine.dispose()
    }

    private static func makeHeadlessConfig(modelName: String?) -> DevinAgentConfig {
        DevinAgentConfig(
            enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
            includeRepoPromptMCPServer: false,
            modelString: modelName
        )
    }
}
