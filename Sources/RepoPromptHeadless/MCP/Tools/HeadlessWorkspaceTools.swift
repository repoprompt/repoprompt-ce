import Foundation

enum HeadlessWorkspaceTools {
    static func bindContext(host: HeadlessHost, arguments: HeadlessJSONObject) async throws -> HeadlessJSONObject {
        let op = HeadlessToolArguments.string(arguments, key: "op") ?? "get"
        switch op {
        case "list":
            let listing = try await host.listWorkspaces()
            return try workspaceListResponse(config: listing.config, workspaces: listing.workspaces, title: "## Headless Contexts ✅")
        case "get", "status":
            let snapshot = try await host.snapshot(requireWorkspace: false)
            let text = if let workspace = snapshot.workspace {
                "## Headless Context Binding ✅\n- **Active workspace**: \(workspace.name) (`\(workspace.id.uuidString)`)\n- **Roots**: \(snapshot.roots.map(\.name).joined(separator: ", "))\n- **State directory**: `\(snapshot.config.activeWorkspaceID == nil ? "unbound" : "bound")`"
            } else {
                "## Headless Context Binding ⚠️\nNo active headless workspace is bound. Configure roots and create/select a workspace first."
            }
            return try HeadlessToolResponse.success(text: text, structured: snapshotJSON(snapshot))
        case "bind":
            let token = try workspaceToken(arguments)
            let workspace = try await host.selectWorkspace(token: token)
            let snapshot = try await host.snapshot(requireWorkspace: true)
            let text = "## Headless Context Binding ✅\n- **Bound workspace**: \(workspace.name) (`\(workspace.id.uuidString)`)\n- **Roots**: \(snapshot.roots.map(\.name).joined(separator: ", "))"
            return try HeadlessToolResponse.success(text: text, structured: snapshotJSON(snapshot))
        default:
            throw HeadlessCommandError("Unsupported bind_context op '\(op)'. Supported ops: list, get, bind.", exitCode: 2)
        }
    }

    static func manageWorkspaces(host: HeadlessHost, arguments: HeadlessJSONObject) async throws -> HeadlessJSONObject {
        let op = HeadlessToolArguments.string(arguments, key: "op") ?? HeadlessToolArguments.string(arguments, key: "action") ?? "list"
        switch op {
        case "list":
            let listing = try await host.listWorkspaces()
            return try workspaceListResponse(config: listing.config, workspaces: listing.workspaces, title: "## Headless Workspaces ✅")
        case "get":
            let snapshot = try await host.snapshot(requireWorkspace: false)
            return try HeadlessToolResponse.success(text: workspaceSnapshotText(snapshot), structured: snapshotJSON(snapshot))
        case "create":
            let name = try HeadlessToolArguments.requiredString(arguments, key: "name")
            let roots = HeadlessToolArguments.stringArray(arguments, key: "roots")
                ?? HeadlessToolArguments.stringArray(arguments, key: "root_ids")
                ?? HeadlessToolArguments.stringArray(arguments, key: "root_names")
                ?? []
            let workspace = try await host.createWorkspace(name: name, rootTokens: roots)
            let text = "## Headless Workspace Created ✅\n- **Name**: \(workspace.name)\n- **ID**: `\(workspace.id.uuidString)`\n- **Root count**: \(workspace.rootIDs.count)"
            return try HeadlessToolResponse.success(text: text, structured: HeadlessJSONValue.value(workspace))
        case "select", "switch":
            let token = try workspaceToken(arguments)
            let workspace = try await host.selectWorkspace(token: token)
            let text = "## Headless Workspace Selected ✅\n- **Name**: \(workspace.name)\n- **ID**: `\(workspace.id.uuidString)`"
            return try HeadlessToolResponse.success(text: text, structured: HeadlessJSONValue.value(workspace))
        case "rename":
            let token = HeadlessToolArguments.string(arguments, key: "workspace") ?? HeadlessToolArguments.string(arguments, key: "id")
            let newName = HeadlessToolArguments.string(arguments, key: "new_name") ?? HeadlessToolArguments.string(arguments, key: "name")
            guard let newName else {
                throw HeadlessCommandError("manage_workspaces rename requires new_name or name.", exitCode: 2)
            }
            let workspace = try await host.renameWorkspace(token: token, newName: newName)
            let text = "## Headless Workspace Renamed ✅\n- **Name**: \(workspace.name)\n- **ID**: `\(workspace.id.uuidString)`"
            return try HeadlessToolResponse.success(text: text, structured: HeadlessJSONValue.value(workspace))
        case "delete", "hide", "unhide", "add_folder", "remove_folder", "create_tab", "close_tab", "select_tab", "list_tabs":
            throw HeadlessCommandError("manage_workspaces op '\(op)' is app/window or destructive and is not supported by the standalone safe profile.", exitCode: 2)
        default:
            throw HeadlessCommandError("Unsupported manage_workspaces op '\(op)'. Supported ops: list, get, create, select, rename.", exitCode: 2)
        }
    }

    private static func workspaceToken(_ arguments: HeadlessJSONObject) throws -> String {
        if let token = HeadlessToolArguments.string(arguments, key: "workspace") ?? HeadlessToolArguments.string(arguments, key: "workspace_id") ?? HeadlessToolArguments.string(arguments, key: "id") ?? HeadlessToolArguments.string(arguments, key: "name") {
            return token
        }
        throw HeadlessCommandError("Workspace id or name is required.", exitCode: 2)
    }

    private static func workspaceListResponse(config: HeadlessConfigurationDocument, workspaces: [HeadlessWorkspaceDocument], title: String) throws -> HeadlessJSONObject {
        var lines = [title, "- **Workspaces**: \(workspaces.count)"]
        if let activeID = config.activeWorkspaceID {
            lines.append("- **Active**: `\(activeID.uuidString)`")
        }
        for workspace in workspaces {
            let marker = workspace.id == config.activeWorkspaceID ? "*" : "-"
            lines.append("\(marker) \(workspace.name) (`\(workspace.id.uuidString)`) roots=\(workspace.rootIDs.count) selection=\(workspace.selection.count)")
        }
        return try HeadlessToolResponse.success(text: lines.joined(separator: "\n"), structured: [
            "active_workspace_id": config.activeWorkspaceID?.uuidString ?? NSNull(),
            "workspaces": HeadlessJSONValue.value(workspaces)
        ])
    }

    private static func workspaceSnapshotText(_ snapshot: HeadlessWorkspaceSnapshot) -> String {
        guard let workspace = snapshot.workspace else {
            return "## Headless Workspace ⚠️\nNo active workspace."
        }
        return "## Headless Workspace ✅\n- **Name**: \(workspace.name)\n- **ID**: `\(workspace.id.uuidString)`\n- **Roots**: \(snapshot.roots.map(\.name).joined(separator: ", "))\n- **Selection**: \(workspace.selection.count) entries"
    }

    private static func snapshotJSON(_ snapshot: HeadlessWorkspaceSnapshot) throws -> HeadlessJSONObject {
        var object: HeadlessJSONObject = try [
            "config": HeadlessJSONValue.value(snapshot.config),
            "roots": HeadlessJSONValue.value(snapshot.roots)
        ]
        if let workspace = snapshot.workspace {
            object["workspace"] = try HeadlessJSONValue.value(workspace)
        } else {
            object["workspace"] = NSNull()
        }
        return object
    }
}
