import Foundation

/// OpenCode CLI provider for non-agent use (chat, Oracle, AI queries) backed by ACP.
/// Runs a fresh prompt-only-style ACP session per request while preserving OpenCode's raw model IDs.
final class OpenCodeCLIProvider: AIProvider {
    private let engine = ACPCLIChatProviderEngine<OpenCodeACPHeadlessAgentProvider>(
        providerName: "OpenCode",
        providerType: .openCode,
        makeProvider: { modelName in
            OpenCodeACPHeadlessAgentProvider(
                config: OpenCodeCLIProvider.makeHeadlessConfig(modelName: modelName),
                workspacePath: nil
            )
        }
    )

    #if DEBUG
        static func test_makeHeadlessConfig(modelName: String?) -> OpenCodeAgentConfig {
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
}
