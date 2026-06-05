import Foundation

package enum MCPSessionToolName {
    package static let bindContext = "bind_context"
    package static let manageWorkspaces = "manage_workspaces"
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

    package static let shareThoughts = "share_thoughts"
    package static let setStatus = "set_status"
    package static let waitForNextInstruction = "wait_for_next_user_instruction"
    package static let appSettings = "app_settings"
}

package enum MCPSessionToolGroup: CaseIterable, Hashable {
    case routing
    case selection
    case files
    case promptContext
    case applyEdits
    case oracle
    case git
    case contextBuilder
    case askUser
    case agentControl
    case agentSessionControl
    case settings

    package var orderedToolNames: [String] {
        switch self {
        case .routing:
            [MCPSessionToolName.bindContext, MCPSessionToolName.manageWorkspaces]
        case .selection:
            [MCPSessionToolName.manageSelection]
        case .files:
            [
                MCPSessionToolName.fileActions,
                MCPSessionToolName.getCodeStructure,
                MCPSessionToolName.getFileTree,
                MCPSessionToolName.readFile,
                MCPSessionToolName.search
            ]
        case .promptContext:
            [MCPSessionToolName.workspaceContext, MCPSessionToolName.prompt]
        case .applyEdits:
            [MCPSessionToolName.applyEdits]
        case .oracle:
            [
                MCPSessionToolName.oracleUtils,
                MCPSessionToolName.askOracle,
                MCPSessionToolName.oracleSend,
                MCPSessionToolName.oracleChatLog
            ]
        case .git:
            [MCPSessionToolName.git, MCPSessionToolName.manageWorktree]
        case .contextBuilder:
            [MCPSessionToolName.contextBuilder]
        case .askUser:
            [MCPSessionToolName.askUser]
        case .agentControl:
            [MCPSessionToolName.agentExplore, MCPSessionToolName.agentRun, MCPSessionToolName.agentManage]
        case .agentSessionControl:
            [
                MCPSessionToolName.shareThoughts,
                MCPSessionToolName.setStatus,
                MCPSessionToolName.waitForNextInstruction
            ]
        case .settings:
            [MCPSessionToolName.appSettings]
        }
    }

    package static var orderedToolNames: [String] {
        allCases.flatMap(\.orderedToolNames)
    }
}
