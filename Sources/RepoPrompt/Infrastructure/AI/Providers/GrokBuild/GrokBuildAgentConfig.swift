import Foundation

/// Immutable runtime configuration for the Grok Build ACP provider (`grok agent stdio`).
struct GrokBuildAgentConfig {
    /// Process-local MCP import isolation shared by Grok's ACP and one-shot launch adapters.
    static let importIsolationEnvironment: [String: String] = [
        "GROK_CLAUDE_MCPS_ENABLED": "0",
        "GROK_CURSOR_MCPS_ENABLED": "0"
    ]

    /// Disable Grok-owned background features for host-managed Agent Mode and model polling.
    static let managedBackgroundFeatureEnvironment: [String: String] = [
        "GROK_MEMORY": "0",
        "GROK_SUBAGENTS": "0",
        "GROK_WORKFLOWS": "0",
        "GROK_AUTO_WAKE": "0"
    ]

    let commandName: String
    let additionalPathHints: [String]
    let enableDebugLogging: Bool
    let modelString: String?
    let includeRepoPromptMCPServer: Bool
    /// Provider-native full-access intent; when true the provider launches
    /// `grok agent --always-approve --no-leader stdio`. Interactive runs may also carry the
    /// intent via `ACPRunRequest.autoApproveAllToolPermissions`; the provider ORs both.
    let alwaysApproveTools: Bool
    /// Grok (xAI) API key resolved asynchronously at provider-construction time from
    /// the existing `.grokAPI` KeyManager account. `makeLaunchConfiguration` is
    /// synchronous while the keychain is not, so resolution happens upstream
    /// (`ACPAgentProviderFactory`). nil means "no stored key" — Grok's own credential
    /// precedence (`~/.grok/auth.json`, config.toml) still applies.
    let apiKey: String?
    /// Process-local background-feature policy. Empty preserves Grok's native defaults
    /// for Context Builder and one-shot callers; managed callers opt in explicitly.
    let backgroundFeatureEnvironment: [String: String]

    init(
        commandName: String = "grok",
        additionalPathHints: [String] = CLIPathHints.grokBuild,
        enableDebugLogging: Bool = false,
        modelString: String? = nil,
        includeRepoPromptMCPServer: Bool = true,
        alwaysApproveTools: Bool = false,
        apiKey: String? = nil,
        backgroundFeatureEnvironment: [String: String] = [:]
    ) {
        self.commandName = commandName
        self.additionalPathHints = additionalPathHints
        self.enableDebugLogging = enableDebugLogging
        self.modelString = modelString
        self.includeRepoPromptMCPServer = includeRepoPromptMCPServer
        self.alwaysApproveTools = alwaysApproveTools
        self.apiKey = apiKey
        self.backgroundFeatureEnvironment = backgroundFeatureEnvironment
    }
}
