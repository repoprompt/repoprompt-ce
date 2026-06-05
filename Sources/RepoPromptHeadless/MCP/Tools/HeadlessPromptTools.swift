import Foundation

enum HeadlessPromptTools {
    static func prompt(host: HeadlessHost, arguments: HeadlessJSONObject) async throws -> HeadlessJSONObject {
        let op = HeadlessToolArguments.string(arguments, key: "op") ?? "get"
        switch op {
        case "get":
            let snapshot = try await host.snapshot(requireWorkspace: true)
            let text = snapshot.workspace?.promptText ?? ""
            return HeadlessToolResponse.success(text: "## Prompt ✅\n\n```text\n\(text)\n```", structured: ["op": op, "prompt": text])
        case "set":
            let text = try HeadlessToolArguments.requiredString(arguments, key: "text")
            let workspace = try await host.setPrompt(text)
            return HeadlessToolResponse.success(text: "## Prompt Updated ✅\n- **Length**: \(workspace.promptText.count) characters", structured: ["op": op, "prompt": workspace.promptText])
        case "append":
            let text = try HeadlessToolArguments.requiredString(arguments, key: "text")
            let workspace = try await host.appendPrompt(text)
            return HeadlessToolResponse.success(text: "## Prompt Updated ✅\n- **Length**: \(workspace.promptText.count) characters", structured: ["op": op, "prompt": workspace.promptText])
        case "clear":
            let workspace = try await host.clearPrompt()
            return HeadlessToolResponse.success(text: "## Prompt Cleared ✅", structured: ["op": op, "prompt": workspace.promptText])
        case "export":
            let snapshot = try await host.snapshot(requireWorkspace: true)
            let prompt = snapshot.workspace?.promptText ?? ""
            let url = try await host.exportURL(
                for: HeadlessToolArguments.string(arguments, key: "path"),
                defaultFileName: "prompt-export-\(timestamp()).md",
                permissions: snapshot.config.permissions
            )
            try prompt.write(to: url, atomically: true, encoding: .utf8)
            return HeadlessToolResponse.success(text: "## Prompt Export ✅\n- **Path**: `\(url.path)`", structured: ["op": op, "path": url.path])
        case "list_presets":
            let preset: HeadlessJSONObject = [
                "name": "Headless Default",
                "kind": "headless_default",
                "description": "Built-in plain prompt/context renderer for RepoPrompt Headless v1."
            ]
            return HeadlessToolResponse.success(text: "## Copy Presets ✅\n- Headless Default (built-in)", structured: ["op": op, "presets": [preset]])
        case "select_preset":
            throw HeadlessCommandError("prompt select_preset is not supported in headless v1; only the built-in Headless Default preset is available.", exitCode: 2)
        default:
            throw HeadlessCommandError("Unsupported prompt op '\(op)'. Supported ops: get, set, append, clear, export, list_presets.", exitCode: 2)
        }
    }

    static func workspaceContext(host: HeadlessHost, arguments: HeadlessJSONObject) async throws -> HeadlessJSONObject {
        let op = HeadlessToolArguments.string(arguments, key: "op") ?? "snapshot"
        switch op {
        case "snapshot":
            let rendered = try await renderWorkspaceContext(host: host, arguments: arguments)
            return HeadlessToolResponse.success(text: rendered.text, structured: rendered.structured)
        case "export":
            let snapshot = try await host.snapshot(requireWorkspace: true)
            let rendered = try await renderWorkspaceContext(host: host, arguments: arguments)
            let url = try await host.exportURL(
                for: HeadlessToolArguments.string(arguments, key: "path"),
                defaultFileName: "workspace-context-\(timestamp()).md",
                permissions: snapshot.config.permissions
            )
            try rendered.text.write(to: url, atomically: true, encoding: .utf8)
            var structured = rendered.structured
            structured["export_path"] = url.path
            return HeadlessToolResponse.success(text: "## Prompt Context Export ✅\n- **Path**: `\(url.path)`", structured: structured)
        case "list_presets":
            return HeadlessToolResponse.success(text: "## Copy Presets ✅\n- Headless Default (built-in)", structured: ["op": op, "presets": [["name": "Headless Default", "kind": "headless_default"]]])
        case "select_preset":
            throw HeadlessCommandError("workspace_context select_preset is not supported in headless v1; only the built-in Headless Default preset is available.", exitCode: 2)
        default:
            throw HeadlessCommandError("Unsupported workspace_context op '\(op)'. Supported ops: snapshot, export.", exitCode: 2)
        }
    }

    private static func renderWorkspaceContext(host: HeadlessHost, arguments: HeadlessJSONObject) async throws -> (text: String, structured: HeadlessJSONObject) {
        let snapshot = try await host.snapshot(requireWorkspace: true)
        guard let workspace = snapshot.workspace else {
            throw HeadlessCommandError("No active workspace is available.", exitCode: 2)
        }
        let includes = Set(HeadlessToolArguments.stringArray(arguments, key: "include") ?? ["prompt", "selection", "code", "tokens"])
        let resolver = HeadlessPathResolver(roots: snapshot.roots)
        var sections: [String] = ["## Prompt Context ✅", "- **Workspace**: \(workspace.name)", "- **Copy preset**: Headless Default"]
        var structured: HeadlessJSONObject = try [
            "workspace": HeadlessJSONValue.value(workspace),
            "roots": HeadlessJSONValue.value(snapshot.roots),
            "include": Array(includes).sorted()
        ]

        if includes.contains("tokens") {
            let promptTokens = approximateTokens(workspace.promptText)
            let selectionTokens = workspace.selection.count * 8
            sections.append("\n### Tokens\n- prompt: \(promptTokens)\n- selection: \(selectionTokens)\n- total_estimate: \(promptTokens + selectionTokens)")
            structured["token_stats"] = ["prompt": promptTokens, "selection": selectionTokens, "total_estimate": promptTokens + selectionTokens]
        }
        if includes.contains("prompt") {
            sections.append("\n### Prompt\n```text\n\(workspace.promptText)\n```")
            structured["prompt"] = workspace.promptText
        }
        if includes.contains("selection") {
            let selectionLines = workspace.selection.isEmpty ? "(no selected files)" : workspace.selection.map { "- \(HeadlessSelectionTools.displayPath(for: $0, roots: snapshot.roots)) (\($0.mode.rawValue))" }.joined(separator: "\n")
            sections.append("\n### Selection\n\(selectionLines)")
            structured["selection"] = try HeadlessJSONValue.value(workspace.selection)
        }
        if includes.contains("tree") {
            let tree = try HeadlessFileCatalog().tree(roots: snapshot.roots, basePath: nil, mode: "auto", maxDepth: 4).tree
            sections.append("\n### File Tree\n```text\n\(tree)\n```")
            structured["file_tree"] = tree
        }
        if includes.contains("code"), !workspace.selection.isEmpty {
            let selectedPaths = try workspace.selection.compactMap { entry -> HeadlessResolvedPath? in
                guard let root = snapshot.roots.first(where: { $0.id == entry.rootID }) else { return nil }
                return try resolver.resolve(entry.relativePath.isEmpty ? root.name : "\(root.name)/\(entry.relativePath)")
            }
            let code = try HeadlessCodeStructureService().structure(paths: selectedPaths, maxResults: 50)
            sections.append("\n### Code Structure\n\(code.text)")
            structured["code_structure"] = code.structured
        }
        if includes.contains("files"), !workspace.selection.isEmpty {
            let files = try HeadlessFileTools.readSelectedContent(selection: workspace.selection, roots: snapshot.roots, resolver: resolver)
            var fileBlocks: [HeadlessJSONObject] = []
            var fileText: [String] = []
            for file in files {
                fileBlocks.append(["path": file.path, "content": file.content])
                fileText.append("#### \(file.path)\n```text\n\(file.content)\n```")
            }
            sections.append("\n### Files\n\(fileText.joined(separator: "\n\n"))")
            structured["file_blocks"] = fileBlocks
        }
        return (sections.joined(separator: "\n"), structured)
    }

    private static func approximateTokens(_ text: String) -> Int {
        max(0, (text.count + 3) / 4)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}
