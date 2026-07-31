import Foundation
import MCP

/// Capability-level grouping for MCP tool policy decisions.
/// Policies should express intent in terms of capabilities and derive tool names from this map.
enum MCPToolCapability: CaseIterable, Hashable {
    case conversationSend
    case conversationHelper
    case conversationLog
    case contextMutate
    case contextRender
    case routingAdvanced
    case discovery
    case userInteraction
    case agentExternalControl
    case agentExploreControl
    case agentReasoningControl
    case agentSessionControl
    case fileContentEdit
    case fileManagement
    case structuralExplore
    case agentConversationSend
    case gitRead
    case worktreeManage
    case appSettings

    /// Stable snake_case name for MCP discovery serialization.
    var externalName: String {
        switch self {
        case .conversationSend: "conversation_send"
        case .conversationHelper: "conversation_helper"
        case .conversationLog: "conversation_log"
        case .contextMutate: "context_mutate"
        case .contextRender: "context_render"
        case .routingAdvanced: "routing_advanced"
        case .discovery: "discovery"
        case .userInteraction: "user_interaction"
        case .agentExternalControl: "agent_external_control"
        case .agentExploreControl: "agent_explore_control"
        case .agentReasoningControl: "agent_reasoning_control"
        case .agentConversationSend: "agent_conversation_send"
        case .agentSessionControl: "agent_session_control"
        case .fileContentEdit: "file_content_edit"
        case .fileManagement: "file_management"
        case .structuralExplore: "structural_explore"
        case .gitRead: "git_read"
        case .worktreeManage: "worktree_manage"
        case .appSettings: "app_settings"
        }
    }
}

enum MCPToolCapabilities {
    private static let capabilityToTools: [MCPToolCapability: Set<String>] = [
        .conversationSend: [
            "oracle_send"
        ],
        .agentConversationSend: [
            "ask_oracle"
        ],
        .conversationHelper: [
            "oracle_utils"
        ],
        .conversationLog: [
            "oracle_chat_log"
        ],
        .contextMutate: [
            "manage_selection",
            "prompt"
        ],
        .contextRender: [
            "workspace_context"
        ],
        .routingAdvanced: [
            "bind_context",
            "manage_workspaces"
        ],
        .discovery: [
            "context_builder"
        ],
        .userInteraction: [
            "ask_user"
        ],
        .agentExternalControl: [
            "agent_run",
            "agent_manage"
        ],
        .agentExploreControl: [
            "agent_explore"
        ],
        .agentReasoningControl: [
            "share_thoughts",
            "wait_for_next_user_instruction"
        ],
        .agentSessionControl: [
            "set_status"
        ],
        .fileContentEdit: [
            "apply_edits"
        ],
        .fileManagement: [
            "file_actions"
        ],
        .structuralExplore: [
            "get_file_tree",
            "get_code_structure"
        ],
        .gitRead: [
            "git"
        ],
        .worktreeManage: [
            "manage_worktree"
        ],
        .appSettings: [
            "app_settings"
        ]
    ]

    static func toolNames(for capabilities: Set<MCPToolCapability>) -> Set<String> {
        capabilities.reduce(into: Set<String>()) { partialResult, capability in
            partialResult.formUnion(capabilityToTools[capability] ?? [])
        }
    }

    static func capabilities(for toolName: String) -> Set<MCPToolCapability> {
        Set(capabilityToTools.compactMap { capability, tools in
            tools.contains(toolName) ? capability : nil
        })
    }
}

enum MCPToolActionCapability: String, Hashable {
    case worktreeManage = "worktree_manage"
    case irreversibleWorktreeRetirement = "irreversible_worktree_retirement"
}

enum MCPToolActionApprovalContract: String, Equatable {
    case ordinary
    case explicitTwoStage = "explicit_two_stage"
}

struct MCPToolActionContract: Equatable {
    let capability: MCPToolActionCapability
    let admissionClass: MCPToolAdmissionClass
    let approval: MCPToolActionApprovalContract
    let requiresActivationGate: Bool
}

enum MCPToolActionContractCatalog {
    static let irreversibleRetirementDispatchGrant = "manage_worktree.retire"

    static func contract(toolName: String, arguments: [String: Value]) -> MCPToolActionContract? {
        guard toolName == MCPWindowToolName.manageWorktree else { return nil }
        let operation = arguments["op"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if operation == "retire" {
            return MCPToolActionContract(
                capability: .irreversibleWorktreeRetirement,
                admissionClass: .exclusive,
                approval: .explicitTwoStage,
                requiresActivationGate: true
            )
        }
        return MCPToolActionContract(
            capability: .worktreeManage,
            admissionClass: .exclusive,
            approval: .ordinary,
            requiresActivationGate: false
        )
    }

    static func isAuthorized(
        toolName: String,
        arguments: [String: Value],
        grantedCapabilities: Set<MCPToolActionCapability>,
        activationEnabled: Bool
    ) -> Bool {
        guard let contract = contract(toolName: toolName, arguments: arguments),
              grantedCapabilities.contains(contract.capability)
        else { return false }
        return !contract.requiresActivationGate || activationEnabled
    }

    static func requireRuntimeAuthorization(
        toolName: String,
        arguments: [String: Value]
    ) throws {
        guard let contract = contract(toolName: toolName, arguments: arguments) else {
            throw MCPError.invalidParams("No action-level safety contract exists for this operation.")
        }
        guard contract.capability == .irreversibleWorktreeRetirement,
              contract.approval == .explicitTwoStage,
              contract.admissionClass == .exclusive
        else { return }
        try GitWorktreeRetirementActivation.requireEnabled()
    }

    static func dispatchAuthorizationError(
        toolName: String,
        arguments: [String: Value],
        additionalGrants: Set<String>
    ) -> String? {
        guard let contract = contract(toolName: toolName, arguments: arguments),
              contract.capability == .irreversibleWorktreeRetirement
        else { return nil }
        guard additionalGrants.contains(irreversibleRetirementDispatchGrant) else {
            return "Action 'manage_worktree.retire' requires the dedicated irreversible retirement grant."
        }
        return nil
    }
}
