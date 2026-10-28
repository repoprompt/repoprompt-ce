//
//  ToolGroups.swift
//  repoprompt-mcp
//
//  Tool category groupings for CLI filtering
//

import Foundation
import MCP

/// Available tool groups for categorization
public enum ToolGroup: String, CaseIterable, Sendable {
    case binding // Window/workspace routing and binding tools
    case context // Selection, context, and prompt management
    case explore // File tree, code structure, reading, searching
    case git // Git status/diff and worktree management
    case edit // File editing and actions
    case conversation // Oracle conversation and discovery helpers
    case settings // App-wide RepoPrompt preferences/settings
}

/// Mode for tool listing operations
public enum ToolListMode: Sendable, Equatable {
    case all // List all tools with full schemas (default)
    case groups([ToolGroup]) // List tools from specific groups (union)
    case groupNames // List available group names only
}

/// Error when parsing tool group specifications
public enum ToolGroupParseError: Swift.Error, Sendable, CustomStringConvertible {
    case unknownGroup(String)
    case emptySpec

    public var description: String {
        switch self {
        case let .unknownGroup(name):
            "Unknown tool group '\(name)'. Run 'tools --groups' to see available groups."
        case .emptySpec:
            "Empty group specification. Run 'tools --groups' to see available groups."
        }
    }
}

/// Catalog mapping tool groups to tool names
public struct ToolGroupCatalog: Sendable {
    /// Mapping of groups to their tool names
    public static let mapping: [ToolGroup: Set<String>] = [
        .binding: [
            "bind_context",
            "manage_workspaces"
        ],
        .context: [
            "manage_selection",
            "prompt",
            "workspace_context"
        ],
        .explore: [
            "get_file_tree",
            "get_code_structure",
            "read_file",
            "file_search",
            "git"
        ],
        .git: [
            "git",
            "manage_worktree"
        ],
        .edit: [
            "apply_edits",
            "file_actions"
        ],
        .conversation: [
            "ask_oracle",
            "oracle_send",
            "oracle_utils",
            "context_builder",
            "ask_user", // Discovery-only, but included in conversation group
            "agent_run",
            "agent_manage"
        ],
        .settings: [
            "app_settings"
        ]
    ]

    /// All group names in alphabetical order
    public static var groupNames: [String] {
        ToolGroup.allCases.map(\.rawValue).sorted()
    }

    /// Brief descriptions for each group
    public static let groupDescriptions: [ToolGroup: String] = [
        .binding: "Binding and routing (bind_context, manage_workspaces)",
        .context: "Selection and context management (manage_selection, prompt, workspace_context)",
        .explore: "File exploration and search (get_file_tree, get_code_structure, read_file, file_search, git)",
        .git: "Git and worktree management (git, manage_worktree)",
        .edit: "File editing and actions (apply_edits, file_actions)",
        .conversation: "Oracle conversation, discovery helpers, and agent control (ask_oracle, oracle_utils, context_builder, agent_run, agent_manage)",
        .settings: "App-wide RepoPrompt preferences (app_settings)"
    ]

    /// Parse a comma-separated group specification string into an array of groups.
    /// - Parameter spec: Comma-separated group names (e.g., "routing,explore" or "routing, explore")
    /// - Returns: Array of parsed ToolGroups in canonical order
    /// - Throws: ToolGroupParseError if any group name is invalid or spec is empty
    public static func parseGroups(spec: String) throws -> [ToolGroup] {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolGroupParseError.emptySpec
        }

        // Split on commas, trim whitespace, lowercase
        let parts = trimmed
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else {
            throw ToolGroupParseError.emptySpec
        }

        // Parse each part and collect unique groups
        var seen = Set<ToolGroup>()
        var result: [ToolGroup] = []

        let aliases: [String: ToolGroup] = [
            "routing": .binding,
            "workspace": .context,
            "chat": .conversation
        ]

        for part in parts {
            guard let group = ToolGroup(rawValue: part) ?? aliases[part] else {
                throw ToolGroupParseError.unknownGroup(part)
            }
            if seen.insert(group).inserted {
                result.append(group)
            }
        }

        // Return in canonical order (allCases order) for consistency
        return ToolGroup.allCases.filter { result.contains($0) }
    }

    /// Filter a list of tools to include only those in the specified groups.
    /// - Parameters:
    ///   - tools: The full list of MCP tools
    ///   - groups: The groups to filter by
    /// - Returns: Filtered list of tools (order preserved from input)
    public static func filter(tools: [MCP.Tool], groups: [ToolGroup]) -> [MCP.Tool] {
        // Build union of all tool names from requested groups
        var allowedNames = Set<String>()
        for group in groups {
            if let names = mapping[group] {
                allowedNames.formUnion(names)
            }
        }

        // Filter tools by name
        return tools.filter { allowedNames.contains($0.name) }
    }

    /// Get the group(s) a tool belongs to.
    /// - Parameter toolName: The name of the tool
    /// - Returns: Array of groups containing this tool (may be empty if tool is ungrouped)
    public static func groups(forTool toolName: String) -> [ToolGroup] {
        ToolGroup.allCases.filter { group in
            mapping[group]?.contains(toolName) ?? false
        }
    }

    /// Check if a tool belongs to any of the specified groups.
    /// - Parameters:
    ///   - toolName: The name of the tool
    ///   - groups: The groups to check
    /// - Returns: True if the tool is in any of the specified groups
    public static func isInGroups(_ toolName: String, groups: [ToolGroup]) -> Bool {
        for group in groups {
            if mapping[group]?.contains(toolName) == true {
                return true
            }
        }
        return false
    }
}
