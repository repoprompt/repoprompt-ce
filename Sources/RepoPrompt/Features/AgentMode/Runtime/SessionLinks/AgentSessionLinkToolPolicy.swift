import Foundation
import RepoPromptDomainRuntime

/// Effective outbound-oversight eligibility, derived from the canonical tool policy catalog rather
/// than assumed.
///
/// Oversee's Add button and the agent-facing `agent_session_link` role filter must agree: a session
/// whose effective role could never perform outbound observer operations must not be offered a
/// control that promises it can oversee. Live catalog visibility is decided separately from links in
/// either direction.
///
/// This file owns only the task-label → role mapping and the role-filter query. It coordinates
/// with `MCPClientToolPolicyCatalog` (the canonical policy it reads), `AgentMonitorPillModels`
/// (whose `canAddReason` it informs), and `AgentSessionLinkMCPToolService` (whose role
/// advertisement filter must agree with it). Invariant: it checks the role filter alone, never the
/// live-link grant, because the grant is what a first Add is about to create.
enum AgentSessionLinkToolPolicy {
    /// Maps an Agent Mode task label onto the canonical MCP client role.
    ///
    /// A user-driven session has no `mcpControlContext` and therefore no task label; it is `.direct`,
    /// which is exactly the role a locally started Agent Mode session presents to the tool catalog.
    static func role(for taskLabelKind: AgentModelCatalog.TaskLabelKind?) -> MCPClientTaskRole {
        switch taskLabelKind {
        case .explore:
            .explore
        case .engineer, .pair, .design:
            .engineer
        case nil:
            .direct
        }
    }

    /// Whether the canonical role policy permits outbound monitoring for this role.
    ///
    /// This deliberately checks only the role filter, not the additional-grant gate: the grant is
    /// computed live from active links, so requiring it here would make Add impossible for a session
    /// that has no links yet — the exact session the user is trying to grant one to.
    static func allowsOutboundMonitoring(taskLabelKind: AgentModelCatalog.TaskLabelKind?) -> Bool {
        MCPClientToolPolicyCatalog.shouldAdvertise(
            toolName: MCPWindowToolName.agentSessionLink,
            role: role(for: taskLabelKind),
            allowsAgentExternalControlTools: false
        )
    }
}
