import Foundation

struct OMPAgentConfig {
    let commandName: String
    let additionalPathHints: [String]
    let enableDebugLogging: Bool
    let includeRepoPromptMCPServer: Bool

    init(
        commandName: String = "omp",
        additionalPathHints: [String] = CLIPathHints.omp,
        enableDebugLogging: Bool = false,
        includeRepoPromptMCPServer: Bool = true
    ) {
        self.commandName = commandName
        self.additionalPathHints = additionalPathHints
        self.enableDebugLogging = enableDebugLogging
        self.includeRepoPromptMCPServer = includeRepoPromptMCPServer
    }
}
