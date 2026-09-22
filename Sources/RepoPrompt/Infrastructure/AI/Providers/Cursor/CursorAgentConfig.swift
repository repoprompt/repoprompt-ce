import Foundation

enum CursorAgentCommandSelection: Equatable {
    case automatic
    case exact(String)
}

struct CursorAgentConfig {
    static let promptOnlySessionModeID = "ask"

    let commandSelection: CursorAgentCommandSelection
    let additionalPathHints: [String]
    let enableDebugLogging: Bool
    let modelString: String?
    let includeRepoPromptMCPServer: Bool
    let cleanupProjectMCPApproval: Bool
    let sessionModeID: String?

    var commandName: String {
        switch commandSelection {
        case .automatic:
            CLILaunchProfiles.cursor.commandName
        case let .exact(commandName):
            commandName
        }
    }

    init(
        commandName: String? = nil,
        additionalPathHints: [String] = CLIPathHints.cursor,
        enableDebugLogging: Bool = false,
        modelString: String? = nil,
        includeRepoPromptMCPServer: Bool = true,
        cleanupProjectMCPApproval: Bool = true,
        sessionModeID: String? = nil
    ) {
        commandSelection = commandName.map(CursorAgentCommandSelection.exact) ?? .automatic
        self.additionalPathHints = additionalPathHints
        self.enableDebugLogging = enableDebugLogging
        self.modelString = modelString
        self.includeRepoPromptMCPServer = includeRepoPromptMCPServer
        self.cleanupProjectMCPApproval = cleanupProjectMCPApproval
        self.sessionModeID = sessionModeID
    }
}
