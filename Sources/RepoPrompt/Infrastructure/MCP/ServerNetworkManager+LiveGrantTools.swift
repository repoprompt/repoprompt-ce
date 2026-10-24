import Foundation
import RepoPromptDomainRuntime

extension ServerNetworkManager {
    /// Tools whose catalog grant is live authority state rather than installed run policy.
    ///
    /// Only these pay for the live-grant lookup on `tools/call`, and both are recomputed on every
    /// `tools/list` and `tools/call` so a stale `list_changed` can never decide execution:
    /// - `agent_session_link`: the exact endpoint holds at least one active link.
    /// - `session_admin`: the exact Agent session holds a live delegation scope, or is an
    ///   orchestrator/overseer run that may `request_scope`. Never granted to administrative
    ///   principals, which have no run-scoped route and therefore no live snapshot at all.
    static func isLiveGrantTool(_ toolName: String) -> Bool {
        toolName == MCPWindowToolName.agentSessionLink || toolName == MCPWindowToolName.sessionAdmin
    }
}
