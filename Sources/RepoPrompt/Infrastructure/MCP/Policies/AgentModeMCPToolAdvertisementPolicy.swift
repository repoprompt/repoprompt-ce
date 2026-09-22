import Foundation
import RepoPromptDomainRuntime

/// App role adapter over the canonical domain-runtime advertisement policy.
enum AgentModeMCPToolAdvertisementPolicy {
    static func hiddenToolNames(
        for taskLabelKind: AgentModelCatalog.TaskLabelKind?
    ) -> Set<String> {
        MCPClientToolPolicyCatalog.hiddenToolNames(for: domainRole(taskLabelKind))
    }

    static func shouldAdvertise(
        toolName: String,
        taskLabelKind: AgentModelCatalog.TaskLabelKind?
    ) -> Bool {
        shouldAdvertise(
            toolName: toolName,
            taskLabelKind: taskLabelKind,
            allowsAgentExternalControlTools: false
        )
    }

    static func shouldAdvertise(
        toolName: String,
        taskLabelKind: AgentModelCatalog.TaskLabelKind?,
        allowsAgentExternalControlTools: Bool
    ) -> Bool {
        MCPClientToolPolicyCatalog.shouldAdvertise(
            toolName: toolName,
            role: domainRole(taskLabelKind),
            allowsAgentExternalControlTools: allowsAgentExternalControlTools
        )
    }

    private static func domainRole(
        _ taskLabelKind: AgentModelCatalog.TaskLabelKind?
    ) -> MCPClientTaskRole {
        guard let taskLabelKind else { return .direct }
        switch taskLabelKind {
        case .explore:
            return .explore
        case .engineer, .pair, .design:
            return .engineer
        }
    }
}
