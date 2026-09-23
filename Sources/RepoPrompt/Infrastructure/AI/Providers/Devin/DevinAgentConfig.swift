import Foundation

/// Immutable runtime configuration for the Devin ACP provider (`devin acp`).
///
struct DevinAgentConfig {
    let commandName: String
    let additionalPathHints: [String]
    let enableDebugLogging: Bool
    let includeRepoPromptMCPServer: Bool
    let modelString: String?
    let useAutoPermissionModeAtLaunch: Bool
    let modelParameterSelections: [ACPModelParameterSelection]

    init(
        commandName: String = "devin",
        additionalPathHints: [String] = CLIPathHints.devin,
        enableDebugLogging: Bool = false,
        includeRepoPromptMCPServer: Bool = true,
        modelString: String? = nil,
        useAutoPermissionModeAtLaunch: Bool = false,
        modelParameterSelections: [ACPModelParameterSelection] = []
    ) {
        self.commandName = commandName
        self.additionalPathHints = additionalPathHints
        self.enableDebugLogging = enableDebugLogging
        self.includeRepoPromptMCPServer = includeRepoPromptMCPServer
        self.modelString = modelString
        self.useAutoPermissionModeAtLaunch = useAutoPermissionModeAtLaunch
        self.modelParameterSelections = modelParameterSelections
    }
}
