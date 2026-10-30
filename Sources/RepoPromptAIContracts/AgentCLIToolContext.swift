import Foundation

/// Shared context describing how a CLI-based provider is being launched.
/// Provider-specific integration configuration uses this to choose native tool
/// exclusions and process-scoped config overlays.
package enum AgentCLIToolContext {
    case agentRun // Agent Mode runs (interactive, user-controlled permissions)
    case discoverRun // Discovery runs (headless, MCP-only exploration)
    case promptOnly // Non-agent CLI usage (prompt → response, no tool use)
    case terminal // Interactive terminal sessions
}
