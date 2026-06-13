import Foundation

struct CursorAgentConfig {
    static let promptOnlySessionModeID = "ask"

    let commandName: String
    let additionalPathHints: [String]
    let enableDebugLogging: Bool
    let modelString: String?
    let includeRepoPromptMCPServer: Bool
    let cleanupProjectMCPApproval: Bool
    let sessionModeID: String?

    init(
        commandName: String = "cursor-agent",
        additionalPathHints: [String] = CLIPathHints.cursor,
        enableDebugLogging: Bool = false,
        modelString: String? = nil,
        includeRepoPromptMCPServer: Bool = true,
        cleanupProjectMCPApproval: Bool = true,
        sessionModeID: String? = nil
    ) {
        self.commandName = commandName
        self.additionalPathHints = additionalPathHints
        self.enableDebugLogging = enableDebugLogging
        self.modelString = modelString
        self.includeRepoPromptMCPServer = includeRepoPromptMCPServer
        self.cleanupProjectMCPApproval = cleanupProjectMCPApproval
        self.sessionModeID = sessionModeID
    }
}
