import Foundation
import MCP

enum MCPToolLifetimeClass: String, Equatable {
    case runtimeCapable = "runtime_capable"
    case uiRequired = "ui_required"
    case mixed

    var requiresRuntimeAdmission: Bool {
        true
    }

    var requiresUIAdapterAtStart: Bool {
        self != .runtimeCapable
    }
}

enum MCPToolLifetimeCatalog {
    static let classifiedToolNames: Set<String> = Set(MCPToolExecutionContractCatalog.orderedAdvertisedToolNames)

    static func classification(
        forCanonicalToolName toolName: String,
        arguments: [String: Value]
    ) -> MCPToolLifetimeClass? {
        switch toolName {
        case MCPGlobalToolName.appSettings:
            .uiRequired
        case MCPGlobalToolName.bindContext:
            switch normalizedOperation(arguments["op"]?.stringValue) {
            case "list", "status": .runtimeCapable
            case "bind": .mixed
            default: nil
            }
        case MCPGlobalToolName.manageWorkspaces:
            switch normalizedOperation(arguments["action"]?.stringValue) {
            case "list": .runtimeCapable
            case "switch", "create", "hide", "unhide", "delete", "add_folder", "remove_folder",
                 "list_tabs", "select_tab", "create_tab", "close_tab":
                .mixed
            default:
                nil
            }
        case MCPWindowToolName.manageSelection:
            .mixed
        case MCPWindowToolName.fileActions, MCPWindowToolName.applyEdits:
            .uiRequired
        case MCPWindowToolName.getCodeStructure:
            normalizedOperation(arguments["scope"]?.stringValue) == "selected" ? .mixed : .runtimeCapable
        case MCPWindowToolName.getFileTree:
            normalizedOperation(arguments["type"]?.stringValue) == "roots"
                ? .runtimeCapable
                : (normalizedOperation(arguments["mode"]?.stringValue) == "selected" ? .mixed : .runtimeCapable)
        case MCPWindowToolName.readFile, MCPWindowToolName.search:
            // Ordinary reads/searches freeze runtime inputs, while selected Git artifacts and
            // automatic-selection tails cross the exact app-adapter boundary.
            .mixed
        case MCPWindowToolName.workspaceContext:
            switch normalizedOperation(arguments["op"]?.stringValue) {
            case nil, "snapshot", "export": .mixed
            case "list_presets", "select_preset": .uiRequired
            default: nil
            }
        case MCPWindowToolName.prompt,
             MCPWindowToolName.oracleUtils,
             MCPWindowToolName.askOracle,
             MCPWindowToolName.oracleSend,
             MCPWindowToolName.oracleChatLog,
             MCPWindowToolName.git,
             MCPWindowToolName.manageWorktree,
             MCPWindowToolName.contextBuilder,
             MCPWindowToolName.askUser,
             MCPWindowToolName.agentExplore,
             MCPWindowToolName.agentRun,
             MCPWindowToolName.agentManage,
             MCPWindowToolName.shareThoughts,
             MCPWindowToolName.setStatus,
             MCPWindowToolName.waitForNextInstruction:
            .uiRequired
        default:
            nil
        }
    }

    private static func normalizedOperation(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
