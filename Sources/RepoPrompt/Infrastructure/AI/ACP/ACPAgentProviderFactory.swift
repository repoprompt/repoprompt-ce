import Foundation

enum ACPAgentProviderFactory {
    /// Injectable so tests can supply keys without touching the keychain. Defaults to the
    /// existing `.grokAPI` account via a fresh KeyManager (same pattern as
    /// `ClaudeCodeLaunchEnvironmentResolver`).
    typealias GrokAPIKeyProvider = @Sendable () async throws -> String?

    /// - Parameter grokAPIKeyProvider: resolves the optional stored Grok (xAI) API key for
    ///   `.grokBuild` providers. A thrown error is a configuration failure, not "no key" —
    ///   a missing key is a valid outcome (Grok's own auth.json/config.toml precedence
    ///   still applies).
    static func makeProvider(
        for agentKind: AgentProviderKind,
        modelString: String?,
        grokAPIKeyProvider: GrokAPIKeyProvider = {
            try await KeyManager().getAPIKey(for: .grok)
        }
    ) async throws -> (any ACPAgentProvider)? {
        switch agentKind {
        case .openCode:
            OpenCodeACPAgentProvider(
                config: OpenCodeAgentConfig(
                    modelString: modelString,
                    enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
                    toolProfile: .agentMode
                )
            )
        case .cursor:
            CursorACPAgentProvider(
                config: CursorAgentConfig(
                    enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
                    modelString: modelString
                )
            )
        case .grokBuild:
            try await GrokBuildACPAgentProvider(
                config: GrokBuildAgentConfig(
                    enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
                    modelString: modelString,
                    // The per-run permission binding is authoritative for interactive runs:
                    // `ACPRunRequest.autoApproveAllToolPermissions` already reflects the
                    // effective profile (including .mcpSafeDefaults overrides), so this
                    // config must not OR the global preference back in.
                    alwaysApproveTools: false,
                    apiKey: grokAPIKeyProvider()
                )
            )
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible, .codexExec:
            nil
        }
    }
}
