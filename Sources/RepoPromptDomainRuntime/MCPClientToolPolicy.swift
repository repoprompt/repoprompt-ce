import Foundation

package enum MCPClientTaskRole: String, CaseIterable, Sendable {
    case direct
    case explore
    case engineer
}

package enum MCPClientToolAnnotationProfile: String, CaseIterable, Sendable {
    case canonical
    case suppressReadOnlyHint = "suppress_read_only_hint"
}

package enum MCPClientToolPolicyProfile: String, CaseIterable, Sendable {
    case direct
    case discovery
    case agentModeGenericExplore = "agent_mode_generic_explore"
    case agentModeGenericEngineer = "agent_mode_generic_engineer"
    case agentModeGenericEngineerOrchestrator = "agent_mode_generic_engineer_orchestrator"
    case agentModeClaudeEngineer = "agent_mode_claude_engineer"
    case agentModeCodexEngineer = "agent_mode_codex_engineer"
    case agentModeOpenCodeEngineer = "agent_mode_open_code_engineer"
    case agentModeCursorEngineer = "agent_mode_cursor_engineer"
}

package struct MCPClientToolPolicyClassification: Sendable {
    package let profile: MCPClientToolPolicyProfile
    package let restrictedCapabilities: Set<MCPToolCapability>
    package let grantedCapabilities: Set<MCPToolCapability>
    package let role: MCPClientTaskRole
    package let allowsAgentExternalControlTools: Bool
    package let annotationProfile: MCPClientToolAnnotationProfile
}

package enum MCPClientToolPolicyCatalog {
    package static let discoveryRestrictedCapabilities: Set<MCPToolCapability> = [
        .conversationSend,
        .agentConversationSend,
        .conversationHelper,
        .fileContentEdit,
        .fileManagement,
        .workspaceMutate,
        .discovery,
        .appSettings,
        .worktreeManage,
        .agentExternalControl,
        .agentExploreControl,
        .agentReasoningControl,
        .statusPublication,
    ]

    package static let discoveryGrantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
    ]

    package static let agentModeRestrictedCapabilities: Set<MCPToolCapability> = [
        .workspaceMutate,
        .conversationHelper,
        .conversationSend,
    ]

    package static let agentModeGenericGrantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .agentReasoningControl,
        .statusPublication,
        .agentConversationSend,
        .conversationLog,
    ]

    package static let agentModeNativeGrantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .statusPublication,
        .agentConversationSend,
        .conversationLog,
    ]

    package static let policyGatedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .agentReasoningControl,
        .statusPublication,
        .agentConversationSend,
        .conversationLog,
    ]

    package static let classifications: [MCPClientToolPolicyProfile: MCPClientToolPolicyClassification] = [
        .direct: .init(
            profile: .direct,
            restrictedCapabilities: [],
            grantedCapabilities: [],
            role: .direct,
            allowsAgentExternalControlTools: false,
            annotationProfile: .canonical
        ),
        .discovery: .init(
            profile: .discovery,
            restrictedCapabilities: discoveryRestrictedCapabilities,
            grantedCapabilities: discoveryGrantedCapabilities,
            role: .direct,
            allowsAgentExternalControlTools: false,
            annotationProfile: .canonical
        ),
        .agentModeGenericExplore: .init(
            profile: .agentModeGenericExplore,
            restrictedCapabilities: agentModeRestrictedCapabilities,
            grantedCapabilities: agentModeGenericGrantedCapabilities,
            role: .explore,
            allowsAgentExternalControlTools: false,
            annotationProfile: .canonical
        ),
        .agentModeGenericEngineer: .init(
            profile: .agentModeGenericEngineer,
            restrictedCapabilities: agentModeRestrictedCapabilities,
            grantedCapabilities: agentModeGenericGrantedCapabilities,
            role: .engineer,
            allowsAgentExternalControlTools: false,
            annotationProfile: .canonical
        ),
        .agentModeGenericEngineerOrchestrator: .init(
            profile: .agentModeGenericEngineerOrchestrator,
            restrictedCapabilities: agentModeRestrictedCapabilities,
            grantedCapabilities: agentModeGenericGrantedCapabilities,
            role: .engineer,
            allowsAgentExternalControlTools: true,
            annotationProfile: .canonical
        ),
        .agentModeClaudeEngineer: .init(
            profile: .agentModeClaudeEngineer,
            restrictedCapabilities: agentModeRestrictedCapabilities,
            grantedCapabilities: agentModeNativeGrantedCapabilities,
            role: .engineer,
            allowsAgentExternalControlTools: false,
            annotationProfile: .canonical
        ),
        .agentModeCodexEngineer: .init(
            profile: .agentModeCodexEngineer,
            restrictedCapabilities: agentModeRestrictedCapabilities,
            grantedCapabilities: agentModeNativeGrantedCapabilities,
            role: .engineer,
            allowsAgentExternalControlTools: false,
            annotationProfile: .suppressReadOnlyHint
        ),
        .agentModeOpenCodeEngineer: .init(
            profile: .agentModeOpenCodeEngineer,
            restrictedCapabilities: agentModeRestrictedCapabilities,
            grantedCapabilities: agentModeNativeGrantedCapabilities,
            role: .engineer,
            allowsAgentExternalControlTools: false,
            annotationProfile: .canonical
        ),
        .agentModeCursorEngineer: .init(
            profile: .agentModeCursorEngineer,
            restrictedCapabilities: agentModeRestrictedCapabilities,
            grantedCapabilities: agentModeNativeGrantedCapabilities,
            role: .engineer,
            allowsAgentExternalControlTools: false,
            annotationProfile: .canonical
        ),
    ]

    package static let policyGatedToolNames = MCPDomainToolCatalog.toolNames(for: policyGatedCapabilities)

    private static let agentExternalControlToolNames = MCPDomainToolCatalog.toolNames(for: [.agentExternalControl])
    private static let hiddenToolNamesByRole: [MCPClientTaskRole: Set<String>] = {
        let exploreControlTools = MCPDomainToolCatalog.toolNames(for: [.agentExploreControl])
        var exploreCapabilities = discoveryRestrictedCapabilities
        exploreCapabilities.remove(.agentReasoningControl)
        exploreCapabilities.remove(.statusPublication)
        exploreCapabilities.remove(.appSettings)
        exploreCapabilities.insert(.conversationLog)
        exploreCapabilities.insert(.selectionMutate)
        exploreCapabilities.insert(.promptMutate)
        exploreCapabilities.insert(.workspaceRead)

        return [
            .direct: exploreControlTools,
            .explore: MCPDomainToolCatalog.toolNames(for: exploreCapabilities).union(exploreControlTools),
            .engineer: agentExternalControlToolNames,
        ]
    }()

    package static func classification(
        for profile: MCPClientToolPolicyProfile
    ) -> MCPClientToolPolicyClassification {
        guard let classification = classifications[profile] else {
            preconditionFailure("Missing MCP client policy classification: \(profile.rawValue)")
        }
        return classification
    }

    package static func hiddenToolNames(for role: MCPClientTaskRole) -> Set<String> {
        guard let names = hiddenToolNamesByRole[role] else {
            preconditionFailure("Missing MCP hidden-tool policy for role: \(role.rawValue)")
        }
        return names
    }

    package static func shouldAdvertise(
        toolName: String,
        role: MCPClientTaskRole,
        allowsAgentExternalControlTools: Bool
    ) -> Bool {
        if role != .explore,
           allowsAgentExternalControlTools,
           agentExternalControlToolNames.contains(toolName)
        {
            return true
        }
        return !hiddenToolNames(for: role).contains(toolName)
    }

    package static func resolvedToolNames(
        for profile: MCPClientToolPolicyProfile
    ) -> [String] {
        let policy = classification(for: profile)
        let restricted = MCPDomainToolCatalog.toolNames(for: policy.restrictedCapabilities)
        let additional = MCPDomainToolCatalog.toolNames(for: policy.grantedCapabilities)
        return MCPDomainToolCatalog.orderedToolNames.filter { toolName in
            !restricted.contains(toolName)
                && (!policyGatedToolNames.contains(toolName) || additional.contains(toolName))
                && shouldAdvertise(
                    toolName: toolName,
                    role: policy.role,
                    allowsAgentExternalControlTools: policy.allowsAgentExternalControlTools
                )
        }
    }
}
