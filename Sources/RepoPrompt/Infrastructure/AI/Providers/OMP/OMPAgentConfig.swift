import Foundation

struct OMPAgentConfig: ACPCLILaunchConfiguring {
    let commandName: String
    let additionalPathHints: [String]
    let enableDebugLogging: Bool
    let modelString: String?
    /// Prompt-only sessions (non-agent chat, connect-time model discovery) must not spawn a
    /// tool server, so RepoPrompt's MCP server is opt-out per session.
    let includeRepoPromptMCPServer: Bool

    init(
        commandName: String = CLILaunchProfiles.omp.commandName,
        additionalPathHints: [String] = CLIPathHints.omp,
        enableDebugLogging: Bool = false,
        modelString: String? = nil,
        includeRepoPromptMCPServer: Bool = true
    ) {
        self.commandName = commandName
        self.additionalPathHints = additionalPathHints
        self.enableDebugLogging = enableDebugLogging
        self.modelString = modelString
        self.includeRepoPromptMCPServer = includeRepoPromptMCPServer
    }
}
