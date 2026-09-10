import Foundation

/// Oh My Pi provider for non-agent use (chat, Oracle, AI queries) backed by ACP.
/// Runs a fresh ACP session per request while preserving OMP's advertised model IDs.
final class OMPCLIProvider: AIProvider {
    private let engine = ACPCLIChatProviderEngine<OMPACPHeadlessAgentProvider>(
        providerName: "Oh My Pi",
        providerType: .omp,
        makeProvider: { modelName in
            OMPACPHeadlessAgentProvider(
                config: OMPCLIProvider.makeHeadlessConfig(modelName: modelName),
                workspacePath: nil
            )
        }
    )

    #if DEBUG
        static func test_makeHeadlessConfig(modelName: String?) -> OMPAgentConfig {
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

    /// A chat/Oracle turn is prompt-only: OMP keeps its own tools, but RepoPrompt's MCP
    /// server is never injected into a non-agent session.
    private static func makeHeadlessConfig(modelName: String?) -> OMPAgentConfig {
        OMPAgentConfig(
            enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
            modelString: modelName,
            includeRepoPromptMCPServer: false
        )
    }
}
