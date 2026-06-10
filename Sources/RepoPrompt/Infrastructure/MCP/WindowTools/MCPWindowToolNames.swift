import Foundation

/// Stable internal namespace for window-scoped MCP tool names.
enum MCPWindowToolName {
    static let manageSelection = "manage_selection"

    static let fileActions = "file_actions"
    static let getCodeStructure = "get_code_structure"
    static let getFileTree = "get_file_tree"
    static let readFile = "read_file"
    static let search = "file_search"

    static let workspaceContext = "workspace_context"
    static let prompt = "prompt"

    static let applyEdits = "apply_edits"

    static let oracleUtils = "oracle_utils"
    static let askOracle = "ask_oracle"
    static let oracleSend = "oracle_send"
    static let oracleChatLog = "oracle_chat_log"

    static let git = "git"
    static let manageWorktree = "manage_worktree"
    static let contextBuilder = "context_builder"
    static let askUser = "ask_user"

    static let agentExplore = "agent_explore"
    static let agentRun = "agent_run"
    static let agentManage = "agent_manage"

    static let history = "history"

    static let shareThoughts = "share_thoughts"
    static let setStatus = "set_status"
    static let waitForNextInstruction = "wait_for_next_user_instruction"
}
