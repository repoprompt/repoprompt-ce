import Foundation

/// Configuration for the official xAI Grok Build ACP agent provider.
///
/// MVP auth is intentionally delegated to the CLI's login/environment handling; RepoPrompt
/// does not persist a Grok CLI API key for Agent Mode.
struct GrokAgentConfig {
    let commandName: String
    let additionalPathHints: [String]
    let enableDebugLogging: Bool
    let modelString: String?
    /// Whether to inject the RepoPrompt MCP server through ACP `session/new` `mcpServers`.
    /// Defaults to true so both interactive and headless Grok runs get RepoPrompt tools
    /// (verified: `grok agent stdio` accepts ACP-standard stdio `mcpServers` and connects).
    let includeRepoPromptMCPServer: Bool
    /// Whether to launch `grok agent` with `--always-approve`. Headless/discovery runs set this
    /// so autonomous tool use never stalls on `session/request_permission`; interactive runs leave
    /// it false and rely on RepoPrompt's ACP permission handling.
    let alwaysApprove: Bool

    init(
        commandName: String = "grok",
        additionalPathHints: [String] = CLIPathHints.grok,
        enableDebugLogging: Bool = false,
        modelString: String? = nil,
        includeRepoPromptMCPServer: Bool = true,
        alwaysApprove: Bool = false
    ) {
        self.commandName = commandName
        self.additionalPathHints = additionalPathHints
        self.enableDebugLogging = enableDebugLogging
        self.modelString = modelString
        self.includeRepoPromptMCPServer = includeRepoPromptMCPServer
        self.alwaysApprove = alwaysApprove
    }
}
