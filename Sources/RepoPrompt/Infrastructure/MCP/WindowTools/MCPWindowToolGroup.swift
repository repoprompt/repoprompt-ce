import Foundation

/// Ordered public tool-family groups for a window-scoped MCP catalog.
enum MCPWindowToolGroup: CaseIterable, Hashable {
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
    case history

    var orderedToolNames: [String] {
        switch self {
        case .selection:
            [MCPWindowToolName.manageSelection]
        case .files:
            [
                MCPWindowToolName.fileActions,
                MCPWindowToolName.getCodeStructure,
                MCPWindowToolName.getFileTree,
                MCPWindowToolName.readFile,
                MCPWindowToolName.search
            ]
        case .promptContext:
            [
                MCPWindowToolName.workspaceContext,
                MCPWindowToolName.prompt
            ]
        case .applyEdits:
            [MCPWindowToolName.applyEdits]
        case .oracle:
            [
                MCPWindowToolName.oracleUtils,
                MCPWindowToolName.askOracle,
                MCPWindowToolName.oracleSend,
                MCPWindowToolName.oracleChatLog
            ]
        case .git:
            [
                MCPWindowToolName.git,
                MCPWindowToolName.manageWorktree
            ]
        case .contextBuilder:
            [MCPWindowToolName.contextBuilder]
        case .askUser:
            [MCPWindowToolName.askUser]
        case .agentControl:
            [
                MCPWindowToolName.agentExplore,
                MCPWindowToolName.agentRun,
                MCPWindowToolName.agentManage
            ]
        case .agentSessionControl:
            [
                MCPWindowToolName.shareThoughts,
                MCPWindowToolName.setStatus,
                MCPWindowToolName.waitForNextInstruction
            ]
        case .history:
            [MCPWindowToolName.history]
        }
    }

    static var orderedToolNames: [String] {
        allCases.flatMap(\.orderedToolNames)
    }
}
