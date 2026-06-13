import Foundation

enum MCPToolAdmissionClass: String, CaseIterable {
    /// Mutating, lifecycle, approval, and interactive tools. The connection lane remains
    /// named `ordinary` for diagnostics compatibility, but this class is deliberately exclusive.
    case exclusive
    case control
    case smallRead = "small_read"
    case gitRead = "git_read"
    case fileSearch = "file_search"

    var connectionLane: MCPConnectionCallLane {
        switch self {
        case .exclusive:
            .ordinary
        case .control:
            .control
        case .smallRead:
            .smallRead
        case .gitRead:
            .gitRead
        case .fileSearch:
            .fileSearch
        }
    }
}

enum MCPToolAdmissionPolicy {
    /// Gate B selected the conservative lower bounds from the WI-3 baseline:
    /// two small reads per connection and per window/store, two Git requests per connection
    /// with a separate one-per-repository request gate, and the unchanged PR #155 four-search burst.
    static let exclusiveConnectionLimit = 1
    static let controlConnectionLimit = 8
    static let smallReadConnectionLimit = 2
    static let smallReadPerWindowLimit = 2
    static let gitReadConnectionLimit = 2
    static let fileSearchConnectionLimit = 4
    static let gitReadPerRepositoryLimit = 1

    /// Exhaustive canonical-tool table. Do not add a default: every advertised tool must be
    /// reviewed and classified explicitly before it can enter a concurrent lane.
    static let classifications: [String: MCPToolAdmissionClass] = [
        MCPGlobalToolName.appSettings: .exclusive,
        MCPGlobalToolName.bindContext: .exclusive,
        MCPGlobalToolName.manageWorkspaces: .exclusive,

        MCPWindowToolName.manageSelection: .exclusive,
        MCPWindowToolName.fileActions: .exclusive,
        MCPWindowToolName.getCodeStructure: .smallRead,
        MCPWindowToolName.getFileTree: .smallRead,
        MCPWindowToolName.readFile: .smallRead,
        MCPWindowToolName.search: .fileSearch,
        // workspace_context includes export and select_preset, so the canonical tool stays exclusive.
        MCPWindowToolName.workspaceContext: .exclusive,
        MCPWindowToolName.prompt: .exclusive,
        MCPWindowToolName.applyEdits: .exclusive,
        MCPWindowToolName.oracleUtils: .control,
        MCPWindowToolName.askOracle: .control,
        MCPWindowToolName.oracleSend: .control,
        MCPWindowToolName.oracleChatLog: .smallRead,
        MCPWindowToolName.git: .gitRead,
        MCPWindowToolName.manageWorktree: .exclusive,
        MCPWindowToolName.contextBuilder: .control,
        MCPWindowToolName.askUser: .control,
        MCPWindowToolName.agentExplore: .control,
        MCPWindowToolName.agentRun: .control,
        MCPWindowToolName.agentManage: .control,
        MCPWindowToolName.shareThoughts: .control,
        MCPWindowToolName.setStatus: .control,
        MCPWindowToolName.waitForNextInstruction: .control
    ]

    static func classification(forCanonicalToolName toolName: String) -> MCPToolAdmissionClass? {
        classifications[toolName]
    }
}
