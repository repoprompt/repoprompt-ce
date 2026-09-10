import Foundation

struct DevinAgentConfig: ACPCLILaunchConfiguring {
    let commandName: String
    let additionalPathHints: [String]
    let enableDebugLogging: Bool
    let includeRepoPromptMCPServer: Bool
    let modelString: String?

    init(
        commandName: String = CLILaunchProfiles.devin.commandName,
        additionalPathHints: [String] = CLIPathHints.devin,
        enableDebugLogging: Bool = false,
        includeRepoPromptMCPServer: Bool = true,
        modelString: String? = nil
    ) {
        self.commandName = commandName
        self.additionalPathHints = additionalPathHints
        self.enableDebugLogging = enableDebugLogging
        self.includeRepoPromptMCPServer = includeRepoPromptMCPServer
        self.modelString = modelString
    }
}
