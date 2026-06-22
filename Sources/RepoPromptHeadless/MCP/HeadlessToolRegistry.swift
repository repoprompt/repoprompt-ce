import Foundation

final class HeadlessToolRegistry {
    enum Capability: String, Equatable {
        case safeProfile
        case writeFiles
        case vcsWrite
        case launchAgents
        case appOnly

        func isEnabled(by permissions: HeadlessPermissions) -> Bool {
            switch self {
            case .safeProfile: true
            case .writeFiles: permissions.writeFiles
            case .vcsWrite: permissions.vcsWrite
            case .launchAgents: permissions.launchAgents
            case .appOnly: false
            }
        }
    }

    struct Registration {
        let name: String
        let capability: Capability
    }

    static let registrations: [Registration] = [
        Registration(name: "bind_context", capability: .safeProfile),
        Registration(name: "manage_workspaces", capability: .safeProfile),
        Registration(name: "manage_selection", capability: .safeProfile),
        Registration(name: "workspace_context", capability: .safeProfile),
        Registration(name: "get_file_tree", capability: .safeProfile),
        Registration(name: "get_code_structure", capability: .safeProfile),
        Registration(name: "read_file", capability: .safeProfile),
        Registration(name: "file_search", capability: .safeProfile),
        Registration(name: "prompt", capability: .safeProfile)
    ]

    static let blockedCapabilities: [String: Capability] = [
        "file_actions": .writeFiles,
        "apply_edits": .writeFiles,
        "git": .vcsWrite,
        "manage_worktree": .vcsWrite,
        "agent_run": .launchAgents,
        "agent_explore": .launchAgents,
        "agent_manage": .launchAgents,
        "ask_oracle": .appOnly,
        "oracle_send": .appOnly,
        "oracle_chat_log": .appOnly,
        "context_builder": .appOnly,
        "ask_user": .appOnly,
        "share_thoughts": .appOnly,
        "set_status": .appOnly,
        "wait_for_next_user_instruction": .appOnly,
        "app_settings": .appOnly
    ]

    private let host: HeadlessHost
    private let configurationStore: HeadlessConfigurationStore

    init(host: HeadlessHost, configurationStore: HeadlessConfigurationStore) {
        self.host = host
        self.configurationStore = configurationStore
    }

    func listDescriptors() -> [HeadlessJSONObject] {
        guard let permissions = try? configurationStore.loadOrCreate().permissions else { return [] }
        return Self.registrations
            .filter { $0.capability.isEnabled(by: permissions) }
            .map { descriptor(for: $0.name).json }
    }

    func call(name: String, arguments: HeadlessJSONObject) async throws -> HeadlessJSONObject {
        do {
            guard let registration = Self.registrations.first(where: { $0.name == name }) else {
                if let capability = Self.blockedCapabilities[name] {
                    return HeadlessToolResponse.error(blockedToolMessage(name: name, capability: capability))
                }
                return HeadlessToolResponse.error("Unsupported headless tool: \(name). Use tools/list to see the enabled safe profile.")
            }
            let permissions = try configurationStore.loadOrCreate().permissions
            guard registration.capability.isEnabled(by: permissions) else {
                return HeadlessToolResponse.error(blockedToolMessage(name: name, capability: registration.capability))
            }

            switch name {
            case "bind_context":
                return try await HeadlessWorkspaceTools.bindContext(host: host, arguments: arguments)
            case "manage_workspaces":
                return try await HeadlessWorkspaceTools.manageWorkspaces(host: host, arguments: arguments)
            case "manage_selection":
                return try await HeadlessSelectionTools.manageSelection(host: host, arguments: arguments)
            case "workspace_context":
                return try await HeadlessPromptTools.workspaceContext(host: host, arguments: arguments)
            case "prompt":
                return try await HeadlessPromptTools.prompt(host: host, arguments: arguments)
            case "get_file_tree":
                return try await HeadlessFileTools.getFileTree(host: host, arguments: arguments)
            case "get_code_structure":
                return try await HeadlessFileTools.getCodeStructure(host: host, arguments: arguments)
            case "read_file":
                return try await HeadlessFileTools.readFile(host: host, arguments: arguments)
            case "file_search":
                return try await HeadlessFileTools.fileSearch(host: host, arguments: arguments)
            default:
                return HeadlessToolResponse.error("Headless tool '\(name)' has capability metadata but no dispatch implementation.")
            }
        } catch let error as HeadlessCommandError {
            return HeadlessToolResponse.error(error.message)
        }
    }

    private func blockedToolMessage(name: String, capability: Capability) -> String {
        "Tool '\(name)' is not available in RepoPrompt Headless v1. Required capability: \(capability.rawValue). The standalone profile fails closed until both permission wiring and a registered implementation exist."
    }

    private func descriptor(for name: String) -> HeadlessToolDescriptor {
        switch name {
        case "bind_context":
            HeadlessToolDescriptor(
                name: name,
                description: "List, inspect, or bind the single headless session to a configured workspace.",
                inputSchema: HeadlessToolSchemas.object(properties: [
                    "op": HeadlessToolSchemas.string(enum: ["list", "get", "status", "bind"]),
                    "workspace": HeadlessToolSchemas.string(description: "Workspace id or name for bind.")
                ])
            )
        case "manage_workspaces":
            HeadlessToolDescriptor(
                name: name,
                description: "Manage headless workspaces without adding arbitrary filesystem roots.",
                inputSchema: HeadlessToolSchemas.object(properties: [
                    "op": HeadlessToolSchemas.string(enum: ["list", "get", "create", "select", "switch", "rename"]),
                    "action": HeadlessToolSchemas.string(description: "Alias for op."),
                    "workspace": HeadlessToolSchemas.string(description: "Workspace id or name."),
                    "name": HeadlessToolSchemas.string(description: "Workspace name."),
                    "new_name": HeadlessToolSchemas.string(description: "New workspace name for rename."),
                    "roots": HeadlessToolSchemas.stringArray(description: "Configured root ids/names/paths to include.")
                ])
            )
        case "manage_selection":
            HeadlessToolDescriptor(
                name: name,
                description: "Read or mutate the active workspace selection using allowed root-contained paths only.",
                inputSchema: HeadlessToolSchemas.object(properties: [
                    "op": HeadlessToolSchemas.string(enum: ["get", "preview", "add", "remove", "set", "clear"]),
                    "paths": HeadlessToolSchemas.stringArray(),
                    "path": HeadlessToolSchemas.string(description: "Single-path alias."),
                    "mode": HeadlessToolSchemas.string(enum: ["full", "slices", "codemap_only"]),
                    "slices": ["type": "array"],
                    "view": HeadlessToolSchemas.string(enum: ["summary", "files", "content", "codemaps"])
                ])
            )
        case "workspace_context":
            HeadlessToolDescriptor(
                name: name,
                description: "Render or export the active workspace prompt/selection/code/files/tree context.",
                inputSchema: HeadlessToolSchemas.object(properties: [
                    "op": HeadlessToolSchemas.string(enum: ["snapshot", "export"]),
                    "include": HeadlessToolSchemas.stringArray(description: "prompt, selection, code, tokens, files, tree"),
                    "path": HeadlessToolSchemas.string(description: "Export path; relative paths stay under state Exports/."),
                    "path_display": HeadlessToolSchemas.string(enum: ["relative", "full"])
                ])
            )
        case "prompt":
            HeadlessToolDescriptor(
                name: name,
                description: "Get, set, append, clear, export, or list the built-in headless prompt preset.",
                inputSchema: HeadlessToolSchemas.object(properties: [
                    "op": HeadlessToolSchemas.string(enum: ["get", "set", "append", "clear", "export", "list_presets"]),
                    "text": HeadlessToolSchemas.string(),
                    "path": HeadlessToolSchemas.string(description: "Export path; relative paths stay under state Exports/.")
                ])
            )
        case "get_file_tree":
            HeadlessToolDescriptor(
                name: name,
                description: "Return an ASCII tree for configured roots, a subpath, or selected files.",
                inputSchema: HeadlessToolSchemas.object(properties: [
                    "type": HeadlessToolSchemas.string(enum: ["files", "roots"]),
                    "mode": HeadlessToolSchemas.string(enum: ["auto", "full", "folders", "selected"]),
                    "path": HeadlessToolSchemas.string(),
                    "max_depth": HeadlessToolSchemas.integer()
                ]),
                readOnlyHint: true
            )
        case "get_code_structure":
            HeadlessToolDescriptor(
                name: name,
                description: "Return lightweight headless code signatures for paths or selected files.",
                inputSchema: HeadlessToolSchemas.object(properties: [
                    "scope": HeadlessToolSchemas.string(enum: ["paths", "selected"]),
                    "paths": HeadlessToolSchemas.stringArray(),
                    "max_results": HeadlessToolSchemas.integer()
                ]),
                readOnlyHint: true
            )
        case "read_file":
            HeadlessToolDescriptor(
                name: name,
                description: "Read a UTF-8 file under configured roots with optional line slicing.",
                inputSchema: HeadlessToolSchemas.object(properties: [
                    "path": HeadlessToolSchemas.string(),
                    "start_line": HeadlessToolSchemas.integer(),
                    "limit": HeadlessToolSchemas.integer()
                ], required: ["path"]),
                readOnlyHint: true
            )
        case "file_search":
            HeadlessToolDescriptor(
                name: name,
                description: "Search paths and/or UTF-8 file contents under configured roots.",
                inputSchema: HeadlessToolSchemas.object(properties: [
                    "pattern": HeadlessToolSchemas.string(),
                    "mode": HeadlessToolSchemas.string(enum: ["auto", "path", "content", "both"]),
                    "regex": HeadlessToolSchemas.boolean(),
                    "filter": ["type": "object"],
                    "path": HeadlessToolSchemas.string(),
                    "max_results": HeadlessToolSchemas.integer(),
                    "count_only": HeadlessToolSchemas.boolean(),
                    "context_lines": HeadlessToolSchemas.integer(),
                    "whole_word": HeadlessToolSchemas.boolean()
                ], required: ["pattern"]),
                readOnlyHint: true
            )
        default:
            HeadlessToolDescriptor(name: name, description: "RepoPrompt Headless tool", inputSchema: HeadlessToolSchemas.object())
        }
    }
}
