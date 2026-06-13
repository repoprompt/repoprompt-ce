import Foundation
import JSONSchema
import MCP
import Ontology

@MainActor
final class MCPFileToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .files

    private let runtime: MCPWindowToolRuntime
    private let dependencies: MCPWindowToolDependencies

    init(runtime: MCPWindowToolRuntime, dependencies: MCPWindowToolDependencies) {
        self.runtime = runtime
        self.dependencies = dependencies
    }

    func buildTools() -> [Tool] {
        [
            fileActionsTool(),
            getCodeStructureTool(),
            getFileTreeTool(),
            readFileTool(),
            fileSearchTool()
        ]
    }

    private func fileActionsTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.fileActions,
            freshnessPolicy: .providerManaged,
            description: """
            Create, delete, or move files.

            **Always use absolute paths** for every `path` / `new_path` argument.

            **Actions**:
            - `create`: Create file with `content`. New files are auto-selected.
              - `if_exists`: "error" (default) | "overwrite"
            - `delete`: Move file or folder to the macOS Trash. Recoverable from Finder Trash until emptied.
            - `move`: Rename/move to `new_path`. Fails if destination exists. Selection state transfers with file.

            **Path handling**:
            - Absolute paths only for `path` and `new_path`.
            - Missing parent directories are created automatically.

            **Examples**:
            - Create: `{"action":"create","path":"/Users/me/project/src/new.swift","content":"// code"}`
            - Overwrite: `{"action":"create","path":"/Users/me/project/src/file.swift","content":"// new","if_exists":"overwrite"}`
            - Delete: `{"action":"delete","path":"/Users/me/project/old.swift"}` moves the item to Trash.
            - Move: `{"action":"move","path":"/Users/me/project/old.swift","new_path":"/Users/me/project/renamed.swift"}`
            """,
            annotations: .repoPromptLocalDestructive,
            inputSchema: .object(
                properties: [
                    "action": .string(description: "Operation to perform", enum: ["create", "delete", "move"]),
                    "path": .string(description: "File path"),
                    "content": .string(description: "File content (for create)"),
                    "new_path": .string(description: "New path (for move)"),
                    "if_exists": .string(description: "Behavior if the file already exists (for create)", enum: ["error", "overwrite"])
                ],
                required: ["action", "path"]
            )
        ) { [self] _, args in
            try Task.checkCancellation()
            await MCPToolExecutionHandlerPhaseContext.report(.fileActionsPreMutationChecks)
            guard let action = args["action"]?.stringValue,
                  let path = args["path"]?.stringValue
            else { throw MCPError.invalidParams("missing required fields") }

            let content = args["content"]?.stringValue
            let newPath = args["new_path"]?.stringValue
            let ifExists = args["if_exists"]?.stringValue?.lowercased() ?? "error"
            await MCPToolExecutionHandlerPhaseContext.report(.fileActionsPreMutationChecks, transition: .completed)
            try Task.checkCancellation()

            let warning = try await dependencies.performFileAction(action, path, content, newPath, ifExists)
            try Task.checkCancellation()
            await MCPToolExecutionHandlerPhaseContext.report(.fileActionsReplyConstruction)
            let value = try Value(ToolResultDTOs.FileActionReply(
                status: "ok",
                action: action,
                path: path,
                newPath: newPath,
                warning: warning
            ))
            await MCPToolExecutionHandlerPhaseContext.report(.fileActionsReplyConstruction, transition: .completed)
            try Task.checkCancellation()
            return value
        }
    }

    private func getCodeStructureTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.getCodeStructure,
            freshnessPolicy: .providerManaged,
            description: """
            Return code structure (function/type signatures) for files.

            **Scopes**:
            - `paths` (default): Analyze specific files/directories. Requires `paths` parameter.
            - `selected`: Analyze current selection. Also reports files without codemaps.

            **Parameters**:
            - `paths`: File or directory paths (directories are recursive)
            - `max_results`: Limit considered codemaps (default: 10). Larger values opt in to broader scans.

            **Note**: Files without parseable structure are skipped. Use with get_file_tree and file_search for discovery.
            Rendered codemap output is capped near 6k tokens even when `max_results` is larger; narrow `paths` to change which files fit.
            Line numbers are included in the output and match `read_file` line numbering, so you can jump directly to where a function/type is declared within a file. Code structure is refreshed after file edits, so results stay current.

            **Examples**:
            - Specific files: `{"paths":["src/auth/"]}`
            - Current selection: `{"scope":"selected"}`
            """,
            annotations: .repoPromptLocalReadOnly,
            inputSchema: .object(
                properties: [
                    "scope": .string(description: "Scope of operation: current selection or explicit paths", enum: ["paths", "selected"]),
                    "paths": .array(description: "Array of file or directory paths (when scope='paths')", items: .string(description: "File path or directory path (absolute or relative)")),
                    "max_results": .integer(description: "Maximum number of codemaps to consider before the ~6k-token response cap is applied (default: 10)")
                ],
                required: []
            )
        ) { [self] _, args in
            try Task.checkCancellation()
            if await dependencies.promptVM.codeMapsGloballyDisabled {
                throw MCPError.invalidParams(MCPServerViewModel.codeMapsGloballyDisabledMCPMessage)
            }
            let scope = (args["scope"]?.stringValue ?? "paths").lowercased()
            let maxResults = max(0, args["max_results"]?.intValue ?? MCPWindowWorkspaceToolHelpers.defaultCodeStructureMaxResults)
            let metadata = await dependencies.captureRequestMetadata()
            try Task.checkCancellation()
            let lookupContext = await dependencies.resolveFileToolLookupContext(metadata)
            try Task.checkCancellation()
            _ = await dependencies.promptVM.workspaceFileContextStore.awaitAppliedIngress(rootScope: lookupContext.rootScope)
            try Task.checkCancellation()

            switch scope {
            case "selected":
                guard await dependencies.drainReadFileAutoSelection(metadata, .canonicalSelection) == .completed else {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                let collections = try await dependencies.selectionCollectionsForCurrentTabContext()
                try Task.checkCancellation()
                var combined: [WorkspaceFileRecord] = []
                var seenPaths = Set<String>()
                for entry in collections.selected {
                    try Task.checkCancellation()
                    let abs = entry.file.standardizedFullPath
                    if seenPaths.insert(abs).inserted { combined.append(entry.file) }
                }
                for entry in collections.codemap {
                    try Task.checkCancellation()
                    let abs = entry.file.standardizedFullPath
                    if seenPaths.insert(abs).inserted { combined.append(entry.file) }
                }
                let reply = try await dependencies.buildCodeStructureDTO(combined, maxResults, true, lookupContext.bindingProjection)
                try Task.checkCancellation()
                return try Value(reply)
            default:
                guard let rawPaths = args["paths"]?.arrayValue else {
                    throw MCPError.invalidParams("missing paths (required when scope='paths')")
                }
                let paths = rawPaths.compactMap(\.stringValue)
                guard !paths.isEmpty else {
                    throw MCPError.invalidParams("paths array cannot be empty")
                }
                let lookupRootScope = lookupContext.rootScope
                let resolvedPaths = lookupContext.translateInputPaths(paths)
                for path in resolvedPaths {
                    try Task.checkCancellation()
                    if let issue = await dependencies.promptVM.workspaceFileContextStore.exactPathResolutionIssue(for: path, kind: .either, rootScope: lookupRootScope) {
                        throw MCPError.invalidParams(PathResolutionIssueRenderer.message(for: issue))
                    }
                }
                try Task.checkCancellation()
                let resolvedFiles = try await dependencies.resolveFilesForCodeStructure(resolvedPaths, lookupRootScope)
                try Task.checkCancellation()
                let reply = try await dependencies.buildCodeStructureDTO(resolvedFiles, maxResults, false, lookupContext.bindingProjection)
                try Task.checkCancellation()
                return try Value(reply)
            }
        }
    }

    private func getFileTreeTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.getFileTree,
            freshnessPolicy: .providerManaged,
            description: """
            Generate ASCII directory tree of the project.

            **Types**:
            - `files` (default): Directory tree with files
            - `roots`: List loaded root folders only

            **Modes** (for type="files"):
            - `auto` (default): Full tree, auto-trims depth if too large (~10k token target)
            - `full`: Complete tree (can be very large)
            - `folders`: Directories only, no files
            - `selected`: Only selected files and their parent directories

            **Options**:
            - `path`: Start from specific folder (modes/max_depth apply from there)
            - `max_depth`: Limit depth (root=0, immediate children=1, etc.)

            **Markers**: `*` = selected file, `+` = has codemap

            **Worktree scope**: When an agent session is bound to a Git worktree, displayed paths may remain logical/canonical while filesystem reads use the bound worktree. Responses include `worktree_scope` when this remapping is active.

            **Examples**:
            - Auto tree: `{}`
            - Folders only: `{"mode":"folders"}`
            - Subtree: `{"path":"src/components","max_depth":2}`
            - Selected files: `{"mode":"selected"}`
            """,
            annotations: .repoPromptLocalReadOnly,
            inputSchema: .object(
                properties: [
                    "type": .string(description: "Tree type to generate (default: 'files')", enum: ["files", "roots"]),
                    "mode": .string(description: "Filter mode (for 'files' type only, default: 'auto')", enum: ["auto", "full", "folders", "selected"]),
                    "max_depth": .integer(description: "Maximum depth (root = 0)"),
                    "path": .string(description: "Optional starting folder (absolute or relative) when type='files'. When provided, the tree is generated from this folder and 'mode' and 'max_depth' apply from that subtree.")
                ],
                required: []
            )
        ) { [self] _, args in
            let type = args["type"]?.stringValue ?? "files"
            switch type {
            case "roots":
                let filePathDisplay = await MainActor.run { dependencies.promptVM.filePathDisplayOption }
                let metadata = await dependencies.captureRequestMetadata()
                let lookupContext = await dependencies.resolveFileToolLookupContext(metadata)
                _ = await dependencies.promptVM.workspaceFileContextStore.awaitAppliedIngress(rootScope: lookupContext.rootScope)
                let worktreeScope = ToolResultDTOs.WorktreeScopeDTO.sessionBound(from: lookupContext.bindingProjection)
                let snapshot = await dependencies.promptVM.workspaceFileContextStore.makeFileTreeSelectionSnapshot(
                    selection: StoredSelection(),
                    request: WorkspaceFileTreeSnapshotRequest(mode: .full, filePathDisplay: filePathDisplay, onlyIncludeRootsWithSelectedFiles: false, includeLegend: false, showCodeMapMarkers: false, rootScope: lookupContext.rootScope),
                    profile: .mcpRead
                )
                if snapshot.roots.isEmpty {
                    let msg = await dependencies.workspaceContextMessage(MCPWindowToolName.getFileTree, nil)
                    return try Value(ToolResultDTOs.FileTreeDTO(rootsCount: 0, usesLegend: false, tree: msg, note: "No workspace loaded", wasTruncated: false, worktreeScope: worktreeScope))
                }
                let rootLines = snapshot.roots.map { root in
                    lookupContext.bindingProjection?.projectedLogicalDisplayPath(forPhysicalPath: root.fullPath, display: .full) ?? root.fullPath
                }
                return try Value(ToolResultDTOs.FileTreeDTO(rootsCount: snapshot.roots.count, usesLegend: false, tree: rootLines.joined(separator: "\n"), note: nil, wasTruncated: false, worktreeScope: worktreeScope))
            case "files":
                let mode = args["mode"]?.stringValue ?? "auto"
                let maxDepth: Int?
                if let maxDepthArg = args["max_depth"] {
                    guard let intVal = maxDepthArg.intValue else { throw MCPError.invalidParams("max_depth must be an integer") }
                    maxDepth = intVal
                } else {
                    maxDepth = nil
                }
                let metadata = await dependencies.captureRequestMetadata()
                let lookupContext = await dependencies.resolveFileToolLookupContext(metadata)
                _ = await dependencies.promptVM.workspaceFileContextStore.awaitAppliedIngress(rootScope: lookupContext.rootScope)
                if mode.lowercased() == "selected" {
                    guard await dependencies.drainReadFileAutoSelection(metadata, .canonicalSelection) == .completed else {
                        throw CancellationError()
                    }
                }
                let worktreeScope = ToolResultDTOs.WorktreeScopeDTO.sessionBound(from: lookupContext.bindingProjection)
                let resultAndRootCount = try await dependencies.buildStoreBackedFileTreeResult(mode, maxDepth, args["path"]?.stringValue, lookupContext)
                return try Value(ToolResultDTOs.FileTreeDTO(
                    rootsCount: resultAndRootCount.rootCount,
                    usesLegend: resultAndRootCount.result.usesLegend,
                    tree: resultAndRootCount.result.tree,
                    note: resultAndRootCount.result.note,
                    wasTruncated: resultAndRootCount.result.wasTruncated,
                    worktreeScope: worktreeScope
                ))
            default:
                throw MCPError.invalidParams("invalid type: \(type)")
            }
        }
    }

    private func readFileTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.readFile,
            freshnessPolicy: .providerManaged,
            description: """
            Read file contents with optional line range.

            **Parameters**:
            - `path`: File path (required)
            - `start_line`: 1-based line number, or negative for tail behavior
            - `limit`: Number of lines (only with positive start_line)

            **Behaviors**:
            - No params: Entire file
            - `start_line=10`: From line 10 to end
            - `start_line=10, limit=20`: Lines 10-29
            - `start_line=-10`: Last 10 lines (like `tail -10`)

            **Worktree scope**: When an agent session is bound to a Git worktree, displayed paths may remain logical/canonical while filesystem reads use the bound worktree. Responses include `worktree_scope` when this remapping is active.

            **Examples**:
            - Full file: `{"path":"src/main.swift"}`
            - Lines 50-100: `{"path":"file.swift","start_line":50,"limit":51}`
            - Last 20 lines: `{"path":"file.swift","start_line":-20}`
            """,
            annotations: .repoPromptLocalReadOnly,
            inputSchema: .object(
                properties: [
                    "path": .string(description: "File path"),
                    "start_line": .integer(description: "Line to start from (1-based) or negative for tail behavior (-N reads last N lines)"),
                    "limit": .integer(description: "Number of lines to read")
                ],
                required: ["path"]
            )
        ) { [self] _, args in
            try await executeReadFile(args: args)
        }
    }

    private func executeReadFile(args: [String: Value]) async throws -> Value {
        try Task.checkCancellation()
        EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.ReadFile.providerEntered)
        let providerTotalState = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.providerTotal)
        defer { EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.providerTotal, providerTotalState) }

        let (path, startLine1Based, limit) = try EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.providerArgumentParsing) {
            guard let path = args["path"]?.stringValue else { throw MCPError.invalidParams("missing path") }
            let startLineFromInteger = args["start_line"]?.intValue
            let offsetFromInteger = args["offset"]?.intValue
            let startLineFromString = args["start_line"]?.stringValue.flatMap(Int.init)
            let offsetFromString = args["offset"]?.stringValue.flatMap(Int.init)
            let startLine1Based = startLineFromInteger ?? offsetFromInteger ?? startLineFromString ?? offsetFromString
            let limit = args["limit"]?.intValue ?? args["limit"]?.stringValue.flatMap(Int.init)
            return (path, startLine1Based, limit)
        }
        let metadata = await EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.providerRequestMetadata) {
            await dependencies.captureRequestMetadata()
        }
        try Task.checkCancellation()
        let lookupContext = await EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.providerLookupContextResolution) {
            await dependencies.resolveFileToolLookupContext(metadata)
        }
        try Task.checkCancellation()
        let (worktreeScope, resolvedPath) = EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.providerPathTranslation) {
            let worktreeScope = ToolResultDTOs.WorktreeScopeDTO.sessionBound(from: lookupContext.bindingProjection)
            let resolvedPath = lookupContext.translateInputPath(path)
            return (worktreeScope, resolvedPath)
        }
        try Task.checkCancellation()
        var readResult = try await EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.providerReadEnvelope) {
            try await dependencies.readFile(resolvedPath, startLine1Based, limit, lookupContext.rootScope)
        }
        try Task.checkCancellation()
        let projectedDisplayPath = readResult.reply.displayPath.map { displayPath in
            lookupContext.bindingProjection?.projectedLogicalDisplayPath(forPhysicalPath: displayPath) ?? displayPath
        }
        readResult = try await EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.providerReplyProjection) {
            let reply = try await MCPReadFileToolProjection.projectReply(
                readResult.reply,
                displayPath: projectedDisplayPath,
                worktreeScope: worktreeScope
            )
            return (reply, readResult.shouldAutoSelect)
        }
        try Task.checkCancellation()
        await EditFlowPerf.measure(
            EditFlowPerf.Stage.ReadFile.providerAutoSelect,
            EditFlowPerf.Dimensions(outcome: readResult.shouldAutoSelect ? "attempted" : "skipped")
        ) {
            if readResult.shouldAutoSelect {
                await dependencies.enqueueReadFileAutoSelection(readResult.reply, path, metadata)
            }
        }
        try Task.checkCancellation()
        let value = try await EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.providerValueEncoding) {
            try await MCPProviderProjectionWorker.encode(
                readResult.reply,
                toolName: MCPWindowToolName.readFile
            )
        }
        EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.ReadFile.providerResultReady)
        return value
    }

    private func fileSearchTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.search,
            freshnessPolicy: .providerManaged,
            description: """
            Search files by path pattern and/or content.

            **Modes**:
            - `auto` (default): Detects path vs content search from pattern
            - `path`: Match file paths only (glob-style with regex=false, full regex otherwise)
            - `content`: Search inside file contents
            - `both`: Search paths and contents

            **Matching** (regex auto-detected by default):
            - Regex mode: Full regex support (groups, lookarounds, anchors)
            - Literal mode (regex=false): Special chars matched literally, `*`/`?` wildcards for paths
            - Tip: Set `regex=false` to force literal substring matching

            **Key options**:
            - `pattern`: Search term (required)
            - `max_results`: Result limit (default: 50)
            - `context_lines`: Lines before/after matches (alias: `-C`)
            - `whole_word`: Match whole words only
            - `count_only`: Return counts only, no content
            - `filter.extensions`: Limit to extensions (e.g., [".swift"])
            - `filter.paths`: Limit to paths/folders (can also be a loaded root name like 'RepoPrompt')
            - `filter.exclude`: Skip matching patterns

            **Worktree scope**: When an agent session is bound to a Git worktree, displayed paths may remain logical/canonical while filesystem searches use the bound worktree. Responses include `worktree_scope` when this remapping is active.

            **Examples**:
            - Literal: `{"pattern":"frame(minWidth:","regex":false}`
            - Regex OR: `{"pattern":"performSearch|searchUsers"}`
            - Find files: `{"pattern":"*.swift","mode":"path","regex":false}`
            - With context: `{"pattern":"TODO","context_lines":2}`
            - Scoped: `{"pattern":"auth","filter":{"paths":["src/auth/"]}}`

            Response capped at ~50k chars; excess results omitted (count reported).
            """,
            annotations: .repoPromptLocalReadOnly,
            inputSchema: .object(
                properties: [
                    "pattern": .string(description: "Search pattern"),
                    "mode": .string(description: "Search scope: auto-detects if not specified", enum: ["auto", "path", "content", "both"]),
                    "regex": .boolean(description: "Use regex matching (default: auto based on pattern)"),
                    "filter": .object(
                        description: "File filtering options (alias: use 'path' string parameter for single-file search)",
                        properties: [
                            "extensions": .array(description: "Only search files with these extensions", items: .string(description: "File extension like '.js' or '.swift'")),
                            "exclude": .array(description: "Skip files/paths matching these patterns", items: .string(description: "Pattern like 'node_modules' or '*.log'")),
                            "paths": .array(description: "Limit search to specific file or folder paths, or a loaded root name", items: .string(description: "Absolute path, relative path, or loaded root name (e.g., 'RepoPrompt')"))
                        ]
                    ),
                    "path": .string(description: "Alias for filter.paths with a single file or folder path"),
                    "max_results": .integer(description: "Maximum total results (default: 50)"),
                    "count_only": .boolean(description: "Return only match count"),
                    "context_lines": .integer(description: "Lines of context before/after matches (alias: -C)"),
                    "whole_word": .boolean(description: "Match whole words only")
                ],
                required: ["pattern"]
            )
        ) { [self] _, args in
            EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.Search.providerEntered)
            let providerTotal = EditFlowPerf.begin(EditFlowPerf.Stage.Search.providerTotal)
            defer { EditFlowPerf.end(EditFlowPerf.Stage.Search.providerTotal, providerTotal) }
            let reply = try await executeFileSearch(args: args)
            try Task.checkCancellation()
            let value = try EditFlowPerf.measure(EditFlowPerf.Stage.Search.providerValueEncoding) {
                try Value(reply)
            }
            EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.Search.providerResultReady)
            return value
        }
    }

    private func executeFileSearch(args: [String: Value]) async throws -> ToolResultDTOs.SearchResultDTO {
        try Task.checkCancellation()
        let rawPattern = args["pattern"]?.stringValue ?? ""
        let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else {
            throw MCPError.invalidParams("pattern cannot be empty; provide a non-empty search term. If you intend to enumerate files, use get_file_tree or specify a path mode with a wildcard like '*.swift'.")
        }

        let modeRaw = args["mode"]?.stringValue ?? "auto"
        let regex = args["regex"]?.boolValue ?? FileSearchActor.containsRegexSyntax(pattern)
        let wholeWord = args["whole_word"]?.boolValue ?? false
        let contextLines = args["context_lines"]?.intValue
            ?? Int(args["context_lines"]?.stringValue ?? "")
            ?? MCPWindowWorkspaceToolHelpers.parseContextAlias(args)
            ?? 0
        let maxResults = args["max_results"]?.intValue ?? 50
        let countOnly = args["count_only"]?.boolValue ?? false
        let filter = args["filter"]?.objectValue
        let includeExts = filter?["extensions"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let excludePatterns = filter?["exclude"]?.arrayValue?.compactMap(\.stringValue) ?? []
        var limiters = filter?["paths"]?.arrayValue?.compactMap(\.stringValue)
        if limiters == nil || limiters?.isEmpty == true, let singlePath = args["path"]?.stringValue {
            limiters = [singlePath]
        }
        let hadPathFilter = limiters != nil && !(limiters?.isEmpty ?? true)
        if let current = limiters, !current.isEmpty {
            limiters = MCPWindowWorkspaceToolHelpers.sanitizeSearchScopeInputs(current)
        }

        let mode = SearchMode(rawValue: modeRaw) ?? .auto
        let metadata = await dependencies.captureRequestMetadata()
        try Task.checkCancellation()
        let lookupContext = await dependencies.resolveFileToolLookupContext(metadata)
        try Task.checkCancellation()
        let usesWorktreeProjection = lookupContext.bindingProjection != nil
        let worktreeScope = ToolResultDTOs.WorktreeScopeDTO.sessionBound(from: lookupContext.bindingProjection)
        let lookupRootScope = lookupContext.rootScope
        if let current = limiters, !current.isEmpty {
            limiters = lookupContext.translateInputPaths(current)
        }
        let results: SearchResults
        do {
            try Task.checkCancellation()
            results = try await EditFlowPerf.measure(
                EditFlowPerf.Stage.Search.providerWorkspaceSearchAwait,
                EditFlowPerf.Dimensions(searchMode: mode.rawValue, countOnly: countOnly)
            ) {
                try await dependencies.workspaceSearch(
                    pattern, mode, regex, true, maxResults, maxResults, limiters, includeExts, excludePatterns, contextLines, wholeWord, countOnly, pattern.contains(" "), lookupRootScope
                )
            }
            try Task.checkCancellation()
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.Search.providerWorkspaceSearchReturned,
                EditFlowPerf.Dimensions(outcome: "completed", searchMode: mode.rawValue, countOnly: countOnly)
            )
        } catch let error as StoreBackedWorkspaceSearchError {
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.Search.providerWorkspaceSearchReturned,
                EditFlowPerf.Dimensions(outcome: "worktreeScopeUnavailable", searchMode: mode.rawValue, countOnly: countOnly)
            )
            let reply = Self.searchWorktreeUnavailableDTO(for: error, worktreeScope: worktreeScope)
            EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.Search.providerDTOReady, EditFlowPerf.Dimensions(outcome: "worktreeScopeUnavailable"))
            EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.Search.providerAutoSelectionReturned, EditFlowPerf.Dimensions(outcome: "skippedWorktreeScopeUnavailable"))
            return reply
        } catch let error as StoreBackedWorkspaceSearchAdmissionError {
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.Search.providerWorkspaceSearchReturned,
                EditFlowPerf.Dimensions(outcome: "backpressure", searchMode: mode.rawValue, countOnly: countOnly)
            )
            let reply = Self.searchBackpressureDTO(for: error, worktreeScope: worktreeScope)
            EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.Search.providerDTOReady, EditFlowPerf.Dimensions(outcome: "backpressure"))
            EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.Search.providerAutoSelectionReturned, EditFlowPerf.Dimensions(outcome: "skippedBackpressure"))
            return reply
        } catch let error as SearchPatternError {
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.Search.providerWorkspaceSearchReturned,
                EditFlowPerf.Dimensions(outcome: "patternError", searchMode: mode.rawValue, countOnly: countOnly)
            )
            let parts = MCPWindowWorkspaceToolHelpers.friendlySearchErrorParts(for: pattern, isRegex: regex, error: error)
            let reply = ToolResultDTOs.SearchResultDTO(totalMatches: 0, totalFiles: 0, contentMatches: 0, pathMatches: 0, limitHit: false, perFileCounts: [], pathMatchLines: [], contentMatchGroups: [], errorMessage: parts.issue, suggestion: parts.suggestion, worktreeScope: worktreeScope)
            EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.Search.providerDTOReady, EditFlowPerf.Dimensions(outcome: "patternError"))
            EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.Search.providerAutoSelectionReturned, EditFlowPerf.Dimensions(outcome: "skippedPatternError"))
            return reply
        }

        func dtoBuildDimensions(
            outcome: String? = nil,
            limitHit: Bool? = nil
        ) -> EditFlowPerf.Dimensions {
            EditFlowPerf.Dimensions(
                outcome: outcome,
                matchCount: (results.totalCount ?? results.matches?.count ?? 0) + (results.paths?.count ?? 0),
                scannedFileCount: results.searchedFileCount,
                matchedFileCount: results.contentFileCount,
                contentMatchCount: results.totalCount ?? results.matches?.count,
                pathMatchCount: results.paths?.count,
                limitHit: limitHit,
                usesWorktreeProjection: usesWorktreeProjection,
                searchMode: mode.rawValue,
                countOnly: countOnly
            )
        }

        let dtoBuildState = EditFlowPerf.begin(EditFlowPerf.Stage.Search.dtoBuild, dtoBuildDimensions())
        var dtoBuildOutcome = "completed"
        var dtoBuildLimitHit = false
        var dtoBuildEnded = false
        func endDTOBuildIfNeeded() {
            guard !dtoBuildEnded else { return }
            dtoBuildEnded = true
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.dtoBuild,
                dtoBuildState,
                dtoBuildDimensions(outcome: dtoBuildOutcome, limitHit: dtoBuildLimitHit)
            )
        }
        defer { endDTOBuildIfNeeded() }

        try Task.checkCancellation()
        let displayRootRefsSnapshot = await EditFlowPerf.measure(
            EditFlowPerf.Stage.Search.dtoRootRefSnapshotLookup,
            dtoBuildDimensions()
        ) {
            await dependencies.promptVM.workspaceFileContextStore.displayRootRefsSnapshot()
        }
        try Task.checkCancellation()
        let visibleRootRefs = displayRootRefsSnapshot.visibleRoots
        let allRootRefs = displayRootRefsSnapshot.allRoots
        let (displayPath, pathFilterSuggestion): ((String) -> String, String?) = EditFlowPerf.measure(
            EditFlowPerf.Stage.Search.dtoDisplayResolverPreparation,
            dtoBuildDimensions()
        ) {
            let baseDisplayPath = MCPWindowWorkspaceToolHelpers.makeCachedMCPDisplayPathResolver(visibleRoots: visibleRootRefs, allRoots: allRootRefs)
            let displayPath: (String) -> String = { rawPath in
                lookupContext.bindingProjection?.projectedLogicalDisplayPath(forPhysicalPath: rawPath) ?? baseDisplayPath(rawPath)
            }
            let pathFilterSuggestion = MCPWindowWorkspaceToolHelpers.pathFilterSuggestion(hadPathFilter: hadPathFilter, scopedFileCount: results.scopedFileCount)
            return (displayPath, pathFilterSuggestion)
        }

        if countOnly {
            let contentMatches = results.totalCount ?? results.matches?.count ?? 0
            let (displayedContentPaths, displayedPathMatches) = EditFlowPerf.measure(
                EditFlowPerf.Stage.Search.dtoPathDisplayProjection,
                dtoBuildDimensions()
            ) {
                (
                    (results.matches ?? []).map { displayPath($0.filePath) },
                    (results.paths ?? []).map { displayPath($0) }
                )
            }
            EditFlowPerf.measure(
                EditFlowPerf.Stage.Search.dtoCapAccounting,
                dtoBuildDimensions(outcome: "skippedCountOnly", limitHit: false)
            ) {}
            let reply = EditFlowPerf.measure(
                EditFlowPerf.Stage.Search.dtoAssembly,
                dtoBuildDimensions(outcome: "completed", limitHit: false)
            ) {
                let normalizedContentPaths = Set(displayedContentPaths)
                let normalizedPathMatches = Set(displayedPathMatches)
                return ToolResultDTOs.SearchResultDTO(
                    totalMatches: contentMatches + normalizedPathMatches.count,
                    totalFiles: results.contentFileCount ?? normalizedContentPaths.count,
                    matchedFiles: normalizedContentPaths.union(normalizedPathMatches).count,
                    searchedFiles: results.searchedFileCount,
                    contentMatches: contentMatches,
                    pathMatches: normalizedPathMatches.count,
                    limitHit: false,
                    perFileCounts: [],
                    pathMatchLines: Array(normalizedPathMatches).sorted(),
                    contentMatchGroups: [],
                    suggestion: pathFilterSuggestion,
                    warning: results.warningMessage,
                    worktreeScope: worktreeScope
                )
            }
            endDTOBuildIfNeeded()
            EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.Search.providerDTOReady, EditFlowPerf.Dimensions(outcome: "completed", countOnly: true))
            EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.Search.providerAutoSelectionReturned, EditFlowPerf.Dimensions(outcome: "skippedCountOnly"))
            return reply
        }

        let (normalizedMatches, pathMatchesFull) = EditFlowPerf.measure(
            EditFlowPerf.Stage.Search.dtoPathDisplayProjection,
            dtoBuildDimensions()
        ) {
            let normalizedMatches = (results.matches ?? []).map {
                SearchMatch(filePath: displayPath($0.filePath), lineNumber: $0.lineNumber, lineText: $0.lineText, contextBefore: $0.contextBefore, contextAfter: $0.contextAfter)
            }
            let pathMatchesFull = (results.paths ?? []).map { displayPath($0) }
            return (normalizedMatches, pathMatchesFull)
        }
        let contentMatchesFull = normalizedMatches

        let dtoCapAccountingState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.dtoCapAccounting,
            dtoBuildDimensions()
        )
        let budget = max(0, 50000 - 2000)
        var usedChars = 0
        var includedContentMatches: [SearchMatch] = []
        for match in contentMatchesFull {
            try Task.checkCancellation()
            let lineStr = "\(match.filePath):\(match.lineNumber + 1): \(match.lineText)"
            let cost = lineStr.count + 3
            if usedChars + cost > budget { break }
            includedContentMatches.append(match)
            usedChars += cost
        }
        var includedPathLines: [String] = []
        for path in pathMatchesFull {
            try Task.checkCancellation()
            let cost = path.count + 3
            if usedChars + cost > budget { break }
            includedPathLines.append(path)
            usedChars += cost
        }
        let omittedContent = contentMatchesFull.count - includedContentMatches.count
        let omittedPaths = pathMatchesFull.count - includedPathLines.count
        let sizeLimitHit = omittedContent + omittedPaths > 0
        let hitMaxCountLimit = contentMatchesFull.count >= maxResults || pathMatchesFull.count >= maxResults
        dtoBuildLimitHit = sizeLimitHit || hitMaxCountLimit
        if dtoBuildLimitHit {
            dtoBuildOutcome = "capped"
        }
        EditFlowPerf.end(
            EditFlowPerf.Stage.Search.dtoCapAccounting,
            dtoCapAccountingState,
            dtoBuildDimensions(outcome: dtoBuildOutcome, limitHit: dtoBuildLimitHit)
        )

        let reply = try EditFlowPerf.measure(
            EditFlowPerf.Stage.Search.dtoAssembly,
            dtoBuildDimensions(outcome: dtoBuildOutcome, limitHit: dtoBuildLimitHit)
        ) {
            let perFileTotalsDTO = Dictionary(grouping: contentMatchesFull, by: \.filePath)
                .mapValues(\.count)
                .sorted { $0.key < $1.key }
                .map { ToolResultDTOs.PerFileCount(path: $0.key, count: $0.value) }
            var perFileCounts: [String: Int] = [:]
            for match in includedContentMatches {
                try Task.checkCancellation()
                perFileCounts[match.filePath, default: 0] += 1
            }
            let perFileCountDTOs = perFileCounts.sorted { $0.key < $1.key }.map { ToolResultDTOs.PerFileCount(path: $0.key, count: $0.value) }
            var seenPaths = Set<String>()
            var orderedPaths: [String] = []
            for match in includedContentMatches where seenPaths.insert(match.filePath).inserted {
                try Task.checkCancellation()
                orderedPaths.append(match.filePath)
            }
            let groupedMatches = Dictionary(grouping: includedContentMatches, by: { $0.filePath })
            var contentGroups: [ToolResultDTOs.SearchResultDTO.ContentMatchGroup] = []
            for path in orderedPaths {
                try Task.checkCancellation()
                guard let matches = groupedMatches[path] else { continue }
                let lines = matches.sorted { $0.lineNumber < $1.lineNumber }.map { match in
                    let baseLine = match.lineNumber + 1
                    let before = (match.contextBefore ?? []).isEmpty ? nil : (match.contextBefore ?? []).enumerated().map { offset, text in
                        ToolResultDTOs.SearchResultDTO.ContentMatchGroup.ContextLine(lineNumber: max(1, baseLine - (match.contextBefore?.count ?? 0)) + offset, lineText: text)
                    }
                    let after = (match.contextAfter ?? []).isEmpty ? nil : (match.contextAfter ?? []).enumerated().map { offset, text in
                        ToolResultDTOs.SearchResultDTO.ContentMatchGroup.ContextLine(lineNumber: baseLine + offset + 1, lineText: text)
                    }
                    return ToolResultDTOs.SearchResultDTO.ContentMatchGroup.Line(lineNumber: baseLine, lineText: match.lineText, contextBefore: before, contextAfter: after)
                }
                contentGroups.append(ToolResultDTOs.SearchResultDTO.ContentMatchGroup(path: path, lines: lines))
            }

            try Task.checkCancellation()
            return ToolResultDTOs.SearchResultDTO(
                totalMatches: includedContentMatches.count + includedPathLines.count,
                totalFiles: Set(includedContentMatches.map(\.filePath)).count,
                matchedFiles: Set(contentMatchesFull.map(\.filePath)).union(Set(pathMatchesFull)).count,
                searchedFiles: results.searchedFileCount,
                contentMatches: includedContentMatches.count,
                pathMatches: includedPathLines.count,
                limitHit: sizeLimitHit || hitMaxCountLimit,
                perFileCounts: perFileCountDTOs,
                pathMatchLines: includedPathLines,
                contentMatchGroups: contentGroups,
                sizeLimitHit: sizeLimitHit ? true : nil,
                omittedTotal: sizeLimitHit ? (omittedContent + omittedPaths) : nil,
                omittedContentMatches: omittedContent > 0 ? omittedContent : nil,
                omittedPathMatches: omittedPaths > 0 ? omittedPaths : nil,
                suggestion: pathFilterSuggestion,
                warning: results.warningMessage,
                perFileTotals: perFileTotalsDTO.isEmpty ? nil : perFileTotalsDTO,
                worktreeScope: worktreeScope
            )
        }
        endDTOBuildIfNeeded()
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Search.providerDTOReady,
            EditFlowPerf.Dimensions(outcome: dtoBuildOutcome, searchMode: mode.rawValue, countOnly: false)
        )
        try Task.checkCancellation()
        await EditFlowPerf.measure(
            EditFlowPerf.Stage.Search.providerAutoSelection,
            EditFlowPerf.Dimensions(searchMode: mode.rawValue, contextLines: contextLines)
        ) {
            await dependencies.enqueueFileSearchAutoSelection(mode, contextLines, reply, metadata)
        }
        EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.Search.providerAutoSelectionReturned)
        return reply
    }

    static func searchWorktreeUnavailableDTO(
        for error: StoreBackedWorkspaceSearchError,
        worktreeScope: ToolResultDTOs.WorktreeScopeDTO? = nil
    ) -> ToolResultDTOs.SearchResultDTO {
        ToolResultDTOs.SearchResultDTO(
            totalMatches: 0,
            totalFiles: 0,
            contentMatches: 0,
            pathMatches: 0,
            limitHit: false,
            perFileCounts: [],
            pathMatchLines: [],
            contentMatchGroups: [],
            errorMessage: error.localizedDescription,
            errorCode: "worktree_scope_unavailable",
            retryable: true,
            retryAfterMilliseconds: error.retryAfterMilliseconds,
            suggestion: error.suggestion,
            worktreeScope: worktreeScope
        )
    }

    static func searchBackpressureDTO(
        for error: StoreBackedWorkspaceSearchAdmissionError,
        worktreeScope: ToolResultDTOs.WorktreeScopeDTO? = nil
    ) -> ToolResultDTOs.SearchResultDTO {
        ToolResultDTOs.SearchResultDTO(
            totalMatches: 0,
            totalFiles: 0,
            contentMatches: 0,
            pathMatches: 0,
            limitHit: false,
            perFileCounts: [],
            pathMatchLines: [],
            contentMatchGroups: [],
            errorMessage: error.localizedDescription,
            errorCode: "search_backpressure",
            retryable: true,
            retryAfterMilliseconds: error.retryAfterMilliseconds,
            suggestion: error.suggestion,
            worktreeScope: worktreeScope
        )
    }
}
