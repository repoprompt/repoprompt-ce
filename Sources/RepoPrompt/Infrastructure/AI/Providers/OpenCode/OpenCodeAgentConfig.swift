import Foundation
import RepoPromptAIContracts
import RepoPromptProcess

/// Configuration for the OpenCode ACP agent provider.
///
/// RepoPrompt's automatic OpenCode ACP setup is process-ephemeral via
/// `OPENCODE_CONFIG_CONTENT`. Persistent OpenCode config is modified only by explicit
/// user install flows through `MCPIntegrationHelper.installInOpenCode()`.
package struct OpenCodeAgentConfig {
    package enum ToolProfile: Equatable {
        case agentMode
        case headless
        case noTools

        package var sessionModeID: String {
            switch self {
            case .agentMode:
                OpenCodeAgentConfig.managedSessionModeID
            case .headless:
                OpenCodeAgentConfig.managedHeadlessSessionModeID
            case .noTools:
                OpenCodeAgentConfig.managedNoToolsSessionModeID
            }
        }
    }

    /// RepoPrompt-managed OpenCode mode for interactive Agent Mode. Keeps bash available.
    package static let managedSessionModeID = "repoprompt_acp"
    /// RepoPrompt-managed OpenCode mode that disables approval prompts for the managed tool surface.
    package static let managedFullAccessSessionModeID = "repoprompt_acp_full_access"
    /// RepoPrompt-managed OpenCode mode for discovery/delegate headless paths. Denies native tools while preserving injected RepoPrompt MCP.
    package static let managedHeadlessSessionModeID = "repoprompt_headless"
    /// RepoPrompt-managed OpenCode mode for chat/Oracle prompt-only paths. Exposes no tools.
    package static let managedNoToolsSessionModeID = "repoprompt_no_tools"

    package let commandName: String
    package let additionalPathHints: [String]
    package let modelString: String?
    package let enableDebugLogging: Bool
    /// Controls whether the RepoPrompt MCP entry in the ephemeral OpenCode overlay is active.
    /// When false, the overlay includes a disabled same-name MCP override to neutralize stale
    /// global/project RepoPrompt MCP config inherited by prompt-only/model-discovery launches.
    package let includeRepoPromptMCPServer: Bool
    /// Controls whether `OPENCODE_CONFIG_CONTENT` is injected for RepoPrompt-launched OpenCode.
    package let includeManagedConfigOverlay: Bool
    /// Controls best-effort cleanup of legacy persistent RepoPrompt-managed OpenCode entries.
    package let cleanupLegacyPersistentConfig: Bool
    package let toolProfile: ToolProfile
    /// Model-parameter selections (e.g. OpenCode thinking level) captured at run admission
    /// and applied by the headless provider before prompting.
    package let modelParameterSelections: [ACPModelParameterSelection]

    package var sessionModeID: String {
        toolProfile.sessionModeID
    }

    package init(
        commandName: String = "opencode",
        additionalPathHints: [String] = CLILaunchProfiles.openCodeProviderSpecificPaths,
        modelString: String? = nil,
        enableDebugLogging: Bool = false,
        includeRepoPromptMCPServer: Bool = true,
        includeManagedConfigOverlay: Bool = true,
        cleanupLegacyPersistentConfig: Bool = true,
        toolProfile: ToolProfile = .headless,
        modelParameterSelections: [ACPModelParameterSelection] = []
    ) {
        self.commandName = commandName
        self.additionalPathHints = additionalPathHints
        self.modelString = modelString
        self.enableDebugLogging = enableDebugLogging
        self.includeRepoPromptMCPServer = includeRepoPromptMCPServer
        self.includeManagedConfigOverlay = includeManagedConfigOverlay
        self.cleanupLegacyPersistentConfig = cleanupLegacyPersistentConfig
        self.toolProfile = toolProfile
        self.modelParameterSelections = modelParameterSelections
    }
}
