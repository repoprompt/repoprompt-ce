import Foundation
import RepoPromptDomainRuntime

/// Desktop Agent Mode advertises `agent_run` only on the root session
/// (`allowsAgentExternalControlTools` when `parentSessionID == nil`). Nested
/// Codex children see `agent_explore` instead.
public enum HeadlessCodexMCPToolPolicy {
    public static func advertisedToolNames(isRootSession: Bool) -> Set<String> {
        let classification = MCPClientToolPolicyCatalog.classification(for: .agentModeCodexEngineer)
        let restrictedNames = MCPDomainToolCatalog.toolNames(for: classification.restrictedCapabilities)
        let additionalNames = MCPDomainToolCatalog.toolNames(for: classification.grantedCapabilities)
        return Set(MCPDomainToolCatalog.orderedToolNames.filter { toolName in
            !restrictedNames.contains(toolName)
                && (
                    !MCPClientToolPolicyCatalog.policyGatedToolNames.contains(toolName)
                        || additionalNames.contains(toolName)
                )
                && MCPClientToolPolicyCatalog.shouldAdvertise(
                    toolName: toolName,
                    role: classification.role,
                    allowsAgentExternalControlTools: isRootSession
                )
        })
    }
}
