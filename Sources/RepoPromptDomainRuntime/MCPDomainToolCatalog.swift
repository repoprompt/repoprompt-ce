import Foundation

package enum MCPGlobalToolName {
    package static let appSettings = "app_settings"
    package static let bindContext = "bind_context"
    package static let manageWorkspaces = "manage_workspaces"

    package static var orderedToolNames: [String] {
        MCPDomainToolCatalog.globalToolNames
    }
}

package enum MCPWindowToolName {
    package static let manageSelection = "manage_selection"
    package static let fileActions = "file_actions"
    package static let getCodeStructure = "get_code_structure"
    package static let getFileTree = "get_file_tree"
    package static let readFile = "read_file"
    package static let search = "file_search"
    package static let workspaceContext = "workspace_context"
    package static let prompt = "prompt"
    package static let applyEdits = "apply_edits"
    package static let oracleUtils = "oracle_utils"
    package static let askOracle = "ask_oracle"
    package static let oracleSend = "oracle_send"
    package static let oracleChatLog = "oracle_chat_log"
    package static let git = "git"
    package static let manageWorktree = "manage_worktree"
    package static let contextBuilder = "context_builder"
    package static let askUser = "ask_user"
    package static let agentExplore = "agent_explore"
    package static let agentRun = "agent_run"
    package static let agentManage = "agent_manage"
    package static let history = "history"
    package static let shareThoughts = "share_thoughts"
    package static let setStatus = "set_status"
    package static let waitForNextInstruction = "wait_for_next_user_instruction"

    package static var orderedToolNames: [String] {
        MCPDomainToolCatalog.windowToolNames
    }
}

package enum MCPDomainToolScopeKind: String, CaseIterable, Sendable {
    case application
    case window
    case standalone
}

package enum MCPToolCapability: String, CaseIterable, Hashable, Sendable {
    case conversationSend = "conversation_send"
    case conversationHelper = "conversation_helper"
    case conversationLog = "conversation_log"
    case workspaceRead = "workspace_read"
    case workspaceMutate = "workspace_mutate"
    case fileRead = "file_read"
    case fileSearch = "file_search"
    case selectionMutate = "selection_mutate"
    case promptMutate = "prompt_mutate"
    case historyRead = "history_read"
    // Preserve the legacy agent_manage list_agents wire capability while using the
    // more precise M1 intent name internally.
    case statusPublication = "agent_session_control"
    case discovery
    case userInteraction = "user_interaction"
    case agentExternalControl = "agent_external_control"
    case agentExploreControl = "agent_explore_control"
    case agentReasoningControl = "agent_reasoning_control"
    case fileContentEdit = "file_content_edit"
    case fileManagement = "file_management"
    case structuralExplore = "structural_explore"
    case agentConversationSend = "agent_conversation_send"
    case gitRead = "git_read"
    case worktreeManage = "worktree_manage"
    case appSettings = "app_settings"

    package var externalName: String { rawValue }
}

package enum MCPToolAdmissionClass: String, CaseIterable, Sendable {
    case exclusive
    case control
    case smallRead = "small_read"
    case gitRead = "git_read"
    case fileSearch = "file_search"
}

package struct MCPDomainToolCatalogEntry: Hashable, Sendable {
    package let name: String
    package let scope: MCPDomainToolScopeKind
    package let capability: MCPToolCapability
    package let admissionClass: MCPToolAdmissionClass

    package func supports(registrationScope: MCPDomainToolRegistrationScope) -> Bool {
        switch (scope, registrationScope) {
        case (.application, .application), (.window, .window), (.window, .standalone):
            true
        default:
            false
        }
    }
}

package enum MCPDomainToolCatalog {
    package static let entries: [MCPDomainToolCatalogEntry] = [
        .init(name: MCPGlobalToolName.appSettings, scope: .application, capability: .appSettings, admissionClass: .exclusive),
        .init(name: MCPGlobalToolName.bindContext, scope: .application, capability: .workspaceMutate, admissionClass: .exclusive),
        .init(name: MCPGlobalToolName.manageWorkspaces, scope: .application, capability: .workspaceMutate, admissionClass: .exclusive),
        .init(name: MCPWindowToolName.manageSelection, scope: .window, capability: .selectionMutate, admissionClass: .exclusive),
        .init(name: MCPWindowToolName.fileActions, scope: .window, capability: .fileManagement, admissionClass: .exclusive),
        .init(name: MCPWindowToolName.getCodeStructure, scope: .window, capability: .structuralExplore, admissionClass: .smallRead),
        .init(name: MCPWindowToolName.getFileTree, scope: .window, capability: .structuralExplore, admissionClass: .smallRead),
        .init(name: MCPWindowToolName.readFile, scope: .window, capability: .fileRead, admissionClass: .smallRead),
        .init(name: MCPWindowToolName.search, scope: .window, capability: .fileSearch, admissionClass: .fileSearch),
        .init(name: MCPWindowToolName.workspaceContext, scope: .window, capability: .workspaceRead, admissionClass: .exclusive),
        .init(name: MCPWindowToolName.prompt, scope: .window, capability: .promptMutate, admissionClass: .exclusive),
        .init(name: MCPWindowToolName.applyEdits, scope: .window, capability: .fileContentEdit, admissionClass: .exclusive),
        .init(name: MCPWindowToolName.oracleUtils, scope: .window, capability: .conversationHelper, admissionClass: .control),
        .init(name: MCPWindowToolName.askOracle, scope: .window, capability: .agentConversationSend, admissionClass: .control),
        .init(name: MCPWindowToolName.oracleSend, scope: .window, capability: .conversationSend, admissionClass: .control),
        .init(name: MCPWindowToolName.oracleChatLog, scope: .window, capability: .conversationLog, admissionClass: .smallRead),
        .init(name: MCPWindowToolName.git, scope: .window, capability: .gitRead, admissionClass: .gitRead),
        .init(name: MCPWindowToolName.manageWorktree, scope: .window, capability: .worktreeManage, admissionClass: .exclusive),
        .init(name: MCPWindowToolName.contextBuilder, scope: .window, capability: .discovery, admissionClass: .control),
        .init(name: MCPWindowToolName.askUser, scope: .window, capability: .userInteraction, admissionClass: .control),
        .init(name: MCPWindowToolName.agentExplore, scope: .window, capability: .agentExploreControl, admissionClass: .control),
        .init(name: MCPWindowToolName.agentRun, scope: .window, capability: .agentExternalControl, admissionClass: .control),
        .init(name: MCPWindowToolName.agentManage, scope: .window, capability: .agentExternalControl, admissionClass: .control),
        .init(name: MCPWindowToolName.shareThoughts, scope: .window, capability: .agentReasoningControl, admissionClass: .control),
        .init(name: MCPWindowToolName.setStatus, scope: .window, capability: .statusPublication, admissionClass: .control),
        .init(name: MCPWindowToolName.waitForNextInstruction, scope: .window, capability: .agentReasoningControl, admissionClass: .control),
        .init(name: MCPWindowToolName.history, scope: .window, capability: .historyRead, admissionClass: .control),
    ]

    package static let orderedToolNames = entries.map(\.name)
    package static let globalToolNames = entries.filter { $0.scope == .application }.map(\.name)
    package static let windowToolNames = entries.filter { $0.scope == .window }.map(\.name)
    package static let classifications = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.admissionClass) })

    private static let entriesByName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

    package static func entry(named toolName: String) -> MCPDomainToolCatalogEntry? {
        entriesByName[toolName]
    }

    package static func toolNames(for capabilities: Set<MCPToolCapability>) -> Set<String> {
        Set(entries.lazy.filter { capabilities.contains($0.capability) }.map(\.name))
    }

    package static func capabilities(for toolName: String) -> Set<MCPToolCapability> {
        entry(named: toolName).map { [$0.capability] } ?? []
    }

    package static func admissionClass(for toolName: String) -> MCPToolAdmissionClass? {
        entry(named: toolName)?.admissionClass
    }
}
