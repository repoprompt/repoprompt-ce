import Foundation

/// Immutable runtime configuration for the Devin ACP provider (`devin acp`).
///
/// The per-run permission mode is intentionally NOT held here: it arrives with each
/// `ACPRunRequest` so `.mcpSafeDefaults` / `.providerOverride` profiles stay authoritative
/// and `ACPAgentSessionController.isCompatibleWith` can detect a changed launch flag.
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
