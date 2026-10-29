import Foundation
import RepoPromptACPProviders

/// Immutable runtime configuration for the Devin ACP provider (`devin acp`).
///
/// The per-run permission mode is intentionally NOT held here: it arrives with each
/// `ACPRunRequest` so `.mcpSafeDefaults` / `.providerOverride` profiles stay authoritative
/// and `ACPAgentSessionController.isCompatibleWith` can detect a changed launch flag.
package struct DevinAgentConfig {
    package let commandName: String
    package let additionalPathHints: [String]
    package let enableDebugLogging: Bool
    package let includeRepoPromptMCPServer: Bool
    package let modelString: String?

    package init(
        commandName: String = "devin",
        additionalPathHints: [String],
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
