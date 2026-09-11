import Foundation

struct DevinAgentConfig {
    let commandName: String
    let additionalPathHints: [String]
    let enableDebugLogging: Bool
    let includeRepoPromptMCPServer: Bool

    init(
        commandName: String = "devin",
        additionalPathHints: [String] = CLIPathHints.devin,
        enableDebugLogging: Bool = false,
        includeRepoPromptMCPServer: Bool = true
    ) {
        self.commandName = commandName
        self.additionalPathHints = additionalPathHints
        self.enableDebugLogging = enableDebugLogging
        self.includeRepoPromptMCPServer = includeRepoPromptMCPServer
    }
}
