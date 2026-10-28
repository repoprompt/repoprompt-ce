import Foundation
import RepoPromptDomainRuntime

/// Ordered public tool-family groups for a window-scoped MCP catalog.
enum MCPAppToolGroup: CaseIterable, Hashable {
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
            return [MCPWindowToolName.manageSelection]
        case .files:
            return [
                MCPWindowToolName.fileActions,
                MCPWindowToolName.getCodeStructure,
                MCPWindowToolName.getFileTree,
                MCPWindowToolName.readFile,
                MCPWindowToolName.search
            ]
        case .promptContext:
            return [
                MCPWindowToolName.workspaceContext,
                MCPWindowToolName.prompt
            ]
        case .applyEdits:
            return [MCPWindowToolName.applyEdits]
        case .oracle:
            return [
                MCPWindowToolName.oracleUtils,
                MCPWindowToolName.askOracle,
                MCPWindowToolName.oracleSend,
                MCPWindowToolName.oracleChatLog
            ]
        case .git:
            return [
                MCPWindowToolName.git,
                MCPWindowToolName.manageWorktree
            ]
        case .contextBuilder:
            return [MCPWindowToolName.contextBuilder]
        case .askUser:
            return [MCPWindowToolName.askUser]
        case .agentControl:
            return [
                MCPWindowToolName.agentExplore,
                MCPWindowToolName.agentRun,
                MCPWindowToolName.agentManage,
                MCPWindowToolName.agentSessionLink,
                MCPWindowToolName.sessionAdmin
            ]
        case .agentSessionControl:
            var names = [
                MCPWindowToolName.agentSelf,
                MCPWindowToolName.shareThoughts,
                MCPWindowToolName.setStatus,
                MCPWindowToolName.waitForNextInstruction
            ]
            #if DEBUG
                names.append(MCPWindowToolName.promptExperiment)
            #endif
            return names
        case .history:
            return [MCPWindowToolName.history]
        }
    }

    static var orderedToolNames: [String] {
        MCPDomainToolCatalog.windowToolNames
    }
}
