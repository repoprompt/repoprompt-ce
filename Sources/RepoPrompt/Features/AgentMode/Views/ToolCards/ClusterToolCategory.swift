import Foundation

/// Groups tool names into display categories for compact cluster summaries.
/// Called from the service layer when building `AgentTranscriptClusterSummary` so
/// the view receives pre-computed `[ClusterToolGroup]` — no grouping logic in the UI.
///
/// Related:
/// - Model: AgentTranscriptModels.swift (ClusterToolGroup, AgentTranscriptClusterSummary)
/// - Service: AgentTranscriptServices.swift (clusterSummary builder)
/// - Icons: ToolCardContainer.swift (toolIcon, toolDisplayName)
enum ClusterToolCategory {
    private struct ToolEntry {
        let rawName: String
        let normalizedName: String
        let count: Int
    }

    enum ToolFamily: Equatable {
        case navigation
        case edit
        case execution
        case communication
        case agentControl
        case config
        case other
    }

    enum SummaryTitleSignal {
        case navigation
        case edit
        case execution
        case agentControl
        case none
    }

    struct ToolClassification {
        let family: ToolFamily
        let summaryTitleSignal: SummaryTitleSignal
    }

    enum SummaryTitleSemantic {
        case running
        case exploredAndEdited
        case madeChanges
        case ranCommands
        case agentActivity
        case exploredCodebase
        case toolActivity
        case none
    }

    /// Build pre-computed groups from raw tool names and per-tool counts.
    /// Order: Navigation → Edits → Execution → Communication → Agent → Config → Other (single chip).
    static func buildGroups(toolNames: [String], counts: [String: Int]) -> [ClusterToolGroup] {
        var groups: [ClusterToolGroup] = []
        let entries = toolNames.map {
            ToolEntry(
                rawName: $0,
                normalizedName: $0.lowercased(),
                count: counts[$0] ?? counts[$0.lowercased()] ?? 1
            )
        }
        var nav: [ToolEntry] = []
        var edit: [ToolEntry] = []
        var exec: [ToolEntry] = []
        var comm: [ToolEntry] = []
        var agent: [ToolEntry] = []
        var config: [ToolEntry] = []
        var other: [ToolEntry] = []

        for entry in entries {
            switch classification(forNormalizedToolName: entry.normalizedName).family {
            case .navigation:
                nav.append(entry)
            case .edit:
                edit.append(entry)
            case .execution:
                exec.append(entry)
            case .communication:
                comm.append(entry)
            case .agentControl:
                agent.append(entry)
            case .config:
                config.append(entry)
            case .other:
                other.append(entry)
            }
        }

        if !nav.isEmpty {
            groups.append(ClusterToolGroup(
                icon: "magnifyingglass",
                label: categoryLabel("Navigate", entries: nav)
            ))
        }
        if !edit.isEmpty {
            groups.append(ClusterToolGroup(
                icon: "pencil",
                label: categoryLabel("Edit", entries: edit)
            ))
        }
        if !exec.isEmpty {
            groups.append(ClusterToolGroup(
                icon: "terminal",
                label: categoryLabel("Bash", entries: exec)
            ))
        }
        if !comm.isEmpty {
            groups.append(ClusterToolGroup(
                icon: "bubble.left",
                label: categoryLabel("Chat", entries: comm)
            ))
        }
        if !agent.isEmpty {
            groups.append(ClusterToolGroup(
                icon: "person.2",
                label: categoryLabel("Agent", entries: agent)
            ))
        }
        if !config.isEmpty {
            groups.append(ClusterToolGroup(
                icon: "gearshape",
                label: categoryLabel("Config", entries: config)
            ))
        }

        // External MCP tools and anything else — group into a single "Other" chip
        if !other.isEmpty {
            let otherTotal = other.reduce(0) { $0 + $1.count }
            if other.count == 1 {
                // Single unknown tool — show its display name instead of "Other"
                let name = toolDisplayName(for: other[0].rawName)
                groups.append(ClusterToolGroup(
                    icon: toolIcon(for: other[0].rawName),
                    label: otherTotal > 1 ? "\(name) ×\(otherTotal)" : name
                ))
            } else {
                groups.append(ClusterToolGroup(
                    icon: "ellipsis.circle",
                    label: otherTotal > 1 ? "Other ×\(otherTotal)" : "Other"
                ))
            }
        }

        return groups
    }

    static func classification(forNormalizedToolName name: String) -> ToolClassification {
        switch name.lowercased() {
        case let name where navigationTools.contains(name):
            ToolClassification(
                family: .navigation,
                summaryTitleSignal: summaryTitleNavigationTools.contains(name) ? .navigation : .none
            )
        case let name where editTools.contains(name):
            ToolClassification(family: .edit, summaryTitleSignal: .edit)
        case let name where execTools.contains(name):
            ToolClassification(family: .execution, summaryTitleSignal: .execution)
        case let name where commTools.contains(name):
            ToolClassification(family: .communication, summaryTitleSignal: .none)
        case let name where agentControlTools.contains(name):
            ToolClassification(family: .agentControl, summaryTitleSignal: .agentControl)
        case let name where configTools.contains(name):
            ToolClassification(family: .config, summaryTitleSignal: .none)
        default:
            ToolClassification(family: .other, summaryTitleSignal: .none)
        }
    }

    static func summaryTitleSemantic(
        toolNames: [String],
        toolNameCounts: [String: Int],
        containsRunningWork: Bool
    ) -> SummaryTitleSemantic {
        if containsRunningWork {
            return .running
        }
        let sourceNames = toolNameCounts.isEmpty ? toolNames : Array(toolNameCounts.keys)
        var hasNavigation = false
        var hasEdit = false
        var hasExecution = false
        var hasAgentControl = false
        for toolName in sourceNames {
            switch classification(forNormalizedToolName: toolName).summaryTitleSignal {
            case .navigation:
                hasNavigation = true
            case .edit:
                hasEdit = true
            case .execution:
                hasExecution = true
            case .agentControl:
                hasAgentControl = true
            case .none:
                break
            }
        }
        if hasEdit, hasNavigation {
            return .exploredAndEdited
        }
        if hasEdit {
            return .madeChanges
        }
        if hasExecution {
            return .ranCommands
        }
        if hasAgentControl {
            return .agentActivity
        }
        if hasNavigation {
            return .exploredCodebase
        }
        if !sourceNames.isEmpty {
            return .toolActivity
        }
        return .none
    }

    // MARK: - Tool categories

    private static let navigationTools: Set<String> = [
        "get_file_tree", "read_file", "read", "file_search", "search", "get_code_structure"
    ]
    private static let summaryTitleNavigationTools: Set<String> = [
        "get_file_tree", "read_file", "read", "file_search", "search", "get_code_structure"
    ]
    private static let editTools: Set<String> = [
        "apply_edits", "apply_patch", "edit", "file_actions"
    ]
    private static let execTools: Set<String> = [
        "bash", "shell", "local_shell", "unified_exec", "exec_command", "run_shell_command"
    ]
    private static let commTools: Set<String> = [
        "ask_oracle", "oracle_send", "oracle_utils", "oracle_chat_log", "chat_send", "ask_user", "ask_user_question", "chats"
    ]
    private static let agentControlTools: Set<String> = [
        "agent_explore", "agent_run", "agent_manage"
    ]
    private static let configTools: Set<String> = [
        "manage_selection", "workspace_context", "prompt", "git", "manage_worktree",
        "bind_context", "manage_workspaces", "list_models", "context_builder",
        "app_settings"
    ]

    // MARK: - Label builder

    /// Single tool type → show display name; multiple → show category name. Always append ×N for N > 1.
    private static func categoryLabel(_ categoryName: String, entries: [ToolEntry]) -> String {
        let total = entries.reduce(0) { $0 + $1.count }
        if entries.count == 1 {
            let name = toolDisplayName(for: entries[0].rawName)
            return total > 1 ? "\(name) ×\(total)" : name
        }
        return total > 1 ? "\(categoryName) ×\(total)" : categoryName
    }
}
