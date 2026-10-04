import Foundation

/// Immutable runtime configuration for the Grok Build ACP provider (`grok agent stdio`).
struct GrokBuildAgentConfig {
    /// Process-local MCP import isolation shared by every RPCE-launched Grok process.
    static let importIsolationEnvironment: [String: String] = [
        "GROK_CLAUDE_MCPS_ENABLED": "0",
        "GROK_CURSOR_MCPS_ENABLED": "0"
    ]

    let commandName: String
    let additionalPathHints: [String]
    let enableDebugLogging: Bool
    let modelString: String?
    let includeRepoPromptMCPServer: Bool
    /// Provider-native full-access intent; when true the provider launches
    /// `grok agent --always-approve stdio`. Interactive runs may also carry the
    /// intent via `ACPRunRequest.autoApproveAllToolPermissions`; the provider ORs both.
    let alwaysApproveTools: Bool
    /// Grok (xAI) API key resolved asynchronously at provider-construction time from
    /// the existing `.grokAPI` KeyManager account. `makeLaunchConfiguration` is
    /// synchronous while the keychain is not, so resolution happens upstream
    /// (`ACPAgentProviderFactory`). nil means "no stored key" — Grok's own credential
    /// precedence (`~/.grok/auth.json`, config.toml) still applies.
    let apiKey: String?

    init(
        commandName: String = "grok",
        additionalPathHints: [String] = CLIPathHints.grokBuild,
        enableDebugLogging: Bool = false,
        modelString: String? = nil,
        includeRepoPromptMCPServer: Bool = true,
        alwaysApproveTools: Bool = false,
        apiKey: String? = nil
    ) {
        self.commandName = commandName
        self.additionalPathHints = additionalPathHints
        self.enableDebugLogging = enableDebugLogging
        self.modelString = modelString
        self.includeRepoPromptMCPServer = includeRepoPromptMCPServer
        self.alwaysApproveTools = alwaysApproveTools
        self.apiKey = apiKey
    }
}
