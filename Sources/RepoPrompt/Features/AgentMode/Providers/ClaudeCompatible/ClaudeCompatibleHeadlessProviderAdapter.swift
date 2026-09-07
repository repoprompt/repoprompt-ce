import Foundation

/// Headless seam for the Claude-compatible plugin path.
///
/// Wraps the current core headless implementation while carrying the plugin
/// runtime DTO that future slices can hand directly to the package-owned
/// headless implementation.
final class ClaudeCompatibleHeadlessProviderAdapter: HeadlessAgentProvider {
    let runtimeConfig: ClaudeCompatiblePluginRuntimeConfig
    let mcpCatalogScope: MCPServerCatalogAuthority.Scope
    private let wrappedProvider: any HeadlessAgentProvider

    init(
        runtimeConfig: ClaudeCompatiblePluginRuntimeConfig,
        mcpCatalogScope: MCPServerCatalogAuthority.Scope,
        wrappedProvider: any HeadlessAgentProvider
    ) {
        self.runtimeConfig = runtimeConfig
        self.mcpCatalogScope = mcpCatalogScope
        self.wrappedProvider = wrappedProvider
    }

    func streamAgentMessage(_ message: AgentMessage, runID: UUID?) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        try await wrappedProvider.streamAgentMessage(message, runID: runID)
    }

    func dispose() async {
        await wrappedProvider.dispose()
    }
}
