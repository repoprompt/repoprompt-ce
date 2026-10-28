import Foundation
import RepoPromptProcess

package enum CursorAgentCommandSelection: Equatable {
    case automatic
    case exact(String)
}

package struct CursorAgentConfig {
    package static let promptOnlySessionModeID = "ask"

    package let commandSelection: CursorAgentCommandSelection
    package let additionalPathHints: [String]
    package let enableDebugLogging: Bool
    package let modelString: String?
    package let includeRepoPromptMCPServer: Bool
    package let cleanupProjectMCPApproval: Bool
    package let sessionModeID: String?
    package let modelOverrides: [CursorModelOverride]

    package var commandName: String {
        switch commandSelection {
        case .automatic:
            CLILaunchProfiles.cursor.commandName
        case let .exact(commandName):
            commandName
        }
    }

    package init(
        commandName: String? = nil,
        additionalPathHints: [String] = CLILaunchProfiles.cursorProviderSpecificPaths,
        enableDebugLogging: Bool = false,
        modelString: String? = nil,
        includeRepoPromptMCPServer: Bool = true,
        cleanupProjectMCPApproval: Bool = true,
        sessionModeID: String? = nil,
        modelOverrides: [CursorModelOverride] = []
    ) {
        commandSelection = commandName.map(CursorAgentCommandSelection.exact) ?? .automatic
        self.additionalPathHints = additionalPathHints
        self.enableDebugLogging = enableDebugLogging
        self.modelString = modelString
        self.includeRepoPromptMCPServer = includeRepoPromptMCPServer
        self.cleanupProjectMCPApproval = cleanupProjectMCPApproval
        self.sessionModeID = sessionModeID
        self.modelOverrides = modelOverrides
    }
}
