import Foundation
import JSONSchema
import MCP
import Ontology
import RepoPromptDomainRuntime

@MainActor
final class MCPFileToolProvider: MCPAppToolProviding {
    let group: MCPAppToolGroup = .files

    private let runtime: MCPAppToolBinder
    private typealias Dependencies = (
        context: MCPAppPhysicalCapabilityAdapters.Context,
        selection: MCPAppPhysicalCapabilityAdapters.Selection,
        files: MCPAppPhysicalCapabilityAdapters.Files
    )

    private let dependencies: Dependencies

    init(runtime: MCPAppToolBinder, context: MCPAppPhysicalCapabilityAdapters.Context, selection: MCPAppPhysicalCapabilityAdapters.Selection, files: MCPAppPhysicalCapabilityAdapters.Files) {
        self.runtime = runtime
        dependencies = (context: context, selection: selection, files: files)
    }

    func buildTools() -> [Tool] {
        [fileActionsTool()]
    }

    func executeDomainRead(
        toolName: String,
        context _: DomainReadInvocationContext,
        appContext: MCPServerViewModel.DomainReadAppExecutionContext?,
        args: [String: Value],
        sideEffects: MCPDomainReadSideEffectEmitter
    ) async throws -> Value {
        switch toolName {
        case MCPWindowToolName.getCodeStructure:
            try await executeGetCodeStructure(args: args, appContext: appContext)
        case MCPWindowToolName.getFileTree:
            try await executeGetFileTree(args: args, appContext: appContext)
        case MCPWindowToolName.readFile:
            try await executeReadFile(args: args, appContext: appContext, sideEffects: sideEffects)
        case MCPWindowToolName.search:
            try await executeFileSearchToolValue(args: args, appContext: appContext, sideEffects: sideEffects)
        default:
            throw MCPError.invalidParams("Unsupported file read tool: \(toolName)")
        }
    }

    private func readAuthority(
        _ appContext: MCPServerViewModel.DomainReadAppExecutionContext?
    ) async -> (
        metadata: MCPServerViewModel.RequestMetadata,
        lookupContext: WorkspaceLookupContext
    ) {
        if let appContext {
            return (appContext.metadata, appContext.lookupContext)
        }
        let metadata = await dependencies.context.captureRequestMetadata()
        return await (metadata, dependencies.selection.resolveFileToolLookupContext(metadata))
    }

    private func withActiveWorktreeStartupBenchmarkTag<T>(
        appContext: MCPServerViewModel.DomainReadAppExecutionContext?,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        #if DEBUG
            let authority = await readAuthority(appContext)
            let lookupContext = authority.lookupContext
            let tag = lookupContext.bindingProjection.map(\.sessionID).flatMap {
                WorktreeStartupBenchmarkDiagnostics.shared.activeBenchmarkMetricTag(
                    agentSessionID: $0
                )
            }
            return try await WorktreeStartupInstrumentation.$currentBenchmarkMetricTag
                .withValue(tag, operation: operation)
        #else
            return try await operation()
        #endif
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
                    "operation_id": .string(description: "Optional caller-stable correlation ID echoed in the mutation acknowledgement; not a deduplication or status lookup key"),
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
            let suppliedOperationID = args["operation_id"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let operationID = suppliedOperationID.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
            await MCPToolExecutionHandlerPhaseContext.report(.fileActionsPreMutationChecks, transition: .completed)
            try Task.checkCancellation()

            let reply: ToolResultDTOs.FileActionReply
            do {
                let acknowledgement = try await dependencies.files.performFileAction(action, path, content, newPath, ifExists, operationID)
                reply = ToolResultDTOs.FileActionReply(
                    status: "ok",
                    action: action,
                    path: path,
                    newPath: newPath,
                    warning: acknowledgement.warning,
                    operationID: acknowledgement.operationID,
                    mutationState: acknowledgement.mutationState,
                    freshness: acknowledgement.freshness
                )
            } catch let failure as MCPMutationRetryableFailure {
                reply = ToolResultDTOs.FileActionReply.retryableFailure(
                    action: action,
                    path: path,
                    newPath: newPath,
                    failure: failure
                )
            }
            await MCPToolExecutionHandlerPhaseContext.report(.fileActionsReplyConstruction)
            let value = try Value(reply)
            await MCPToolExecutionHandlerPhaseContext.report(.fileActionsReplyConstruction, transition: .completed)
            return value
        }
    }

    private func executeGetCodeStructure(
        args: [String: Value],
        appContext: MCPServerViewModel.DomainReadAppExecutionContext?
    ) async throws -> Value {
        try await withActiveWorktreeStartupBenchmarkTag(appContext: appContext) {
            try await MCPToolWorkCountDiagnostics.withGitInvocation(
                operation: MCPWindowToolName.getCodeStructure
            ) {
                try Task.checkCancellation()
                let allowedKeys: Set = ["paths", "expand", "depth", "signatures", "size"]
                guard Set(args.keys).isSubset(of: allowedKeys) else {
                    throw MCPError.invalidParams("unknown get_code_structure parameter")
                }

                let direction: WorkspaceCodemapStructureTraversalDirection?
                if let value = args["expand"] {
                    guard let raw = value.stringValue else {
                        throw MCPError.invalidParams("expand must be 'uses', 'used_by', or 'both'")
                    }
                    direction = switch raw {
                    case "uses": .referencedDefinitions
                    case "used_by": .referrers
                    case "both": .both
                    default: throw MCPError.invalidParams("expand must be 'uses', 'used_by', or 'both'")
                    }
                } else {
                    direction = nil
                }

                let suppliedDepth: Int
                if let value = args["depth"] {
                    guard let depth = value.intValue else {
                        throw MCPError.invalidParams("depth must be an integer")
                    }
                    suppliedDepth = depth
                } else {
                    suppliedDepth = 1
                }
                guard (1 ... 4).contains(suppliedDepth) else {
                    throw MCPError.invalidParams("depth must be between 1 and 4")
                }

                let includesSignatures: Bool
                if let value = args["signatures"] {
                    guard let signatures = value.boolValue else {
                        throw MCPError.invalidParams("signatures must be a boolean")
                    }
                    includesSignatures = signatures
                } else {
                    includesSignatures = true
                }

                let size: WorkspaceCodemapGraphOutputSize
                if let value = args["size"] {
                    guard let rawSize = value.stringValue,
                          let parsedSize = WorkspaceCodemapGraphOutputSize(rawValue: rawSize)
                    else {
                        throw MCPError.invalidParams("size must be 'small', 'medium', or 'large'")
                    }
                    size = parsedSize
                } else {
                    size = .medium
                }
                let budget = WorkspaceCodemapGraphPolicy.initial.queryBudget(
                    size: size,
                    includesSignatures: includesSignatures
                )
                let request = MCPServerViewModel.CodeStructureRequest(
                    direction: direction,
                    maximumDepth: direction == nil ? 0 : suppliedDepth,
                    includesSignatures: includesSignatures,
                    size: size,
                    budget: budget
                )

                await MCPToolExecutionHandlerPhaseContext.report(.getCodeStructureSeedResolution)
                let authority = await readAuthority(appContext)
                let metadata = authority.metadata
                try Task.checkCancellation()
                let lookupContext = authority.lookupContext
                try Task.checkCancellation()
                _ = await dependencies.context.promptVM.workspaceFileContextStore.awaitAppliedIngress(
                    rootScope: lookupContext.rootScope
                )
                try Task.checkCancellation()

                let files: [WorkspaceFileRecord]
                var requestedPaths: [String] = []
                if let pathsValue = args["paths"] {
                    guard let rawPaths = pathsValue.arrayValue,
                          !rawPaths.isEmpty,
                          rawPaths.count <= 256,
                          rawPaths.allSatisfy({ $0.stringValue != nil })
                    else {
                        throw MCPError.invalidParams("paths must contain one to 256 strings")
                    }
                    let translated = lookupContext.translateInputPaths(rawPaths.compactMap(\.stringValue))
                    requestedPaths = translated
                    for path in translated {
                        try Task.checkCancellation()
                        if let issue = await dependencies.context.promptVM.workspaceFileContextStore
                            .exactPathResolutionIssue(
                                for: path,
                                kind: .either,
                                rootScope: lookupContext.rootScope
                            )
                        {
                            throw MCPError.invalidParams(PathResolutionIssueRenderer.message(for: issue))
                        }
                    }
                    files = try await dependencies.files.resolveFilesForCodeStructure(
                        translated,
                        lookupContext.rootScope,
                        MCPServerViewModel.codeStructureSeedLimit(for: request)
                    )
                } else {
                    guard try await dependencies.files.drainReadFileAutoSelection(
                        metadata,
                        .canonicalSelection
                    ) == .completed else {
                        throw CancellationError()
                    }
                    files = try await dependencies.context.resolveSelectedFilesForCodeStructure(
                        metadata,
                        lookupContext,
                        MCPServerViewModel.codeStructureSeedLimit(for: request)
                    )
                }
                try Task.checkCancellation()
                let reply = try await dependencies.files.buildCodeStructureDTO(
                    files,
                    request,
                    true,
                    requestedPaths,
                    lookupContext
                )
                try Task.checkCancellation()
                return try Value(reply)
            }
        }
    }

    private func executeGetFileTree(
        args: [String: Value],
        appContext: MCPServerViewModel.DomainReadAppExecutionContext?
    ) async throws -> Value {
        try await withActiveWorktreeStartupBenchmarkTag(appContext: appContext) {
            let type = args["type"]?.stringValue ?? "files"
            switch type {
            case "roots":
                let filePathDisplay = await MainActor.run { dependencies.context.promptVM.filePathDisplayOption }
                let lookupContext = await readAuthority(appContext).lookupContext
                _ = await dependencies.context.promptVM.workspaceFileContextStore.awaitAppliedIngress(rootScope: lookupContext.rootScope)
                let worktreeScope = ToolResultDTOs.WorktreeScopeDTO.sessionBound(from: lookupContext.bindingProjection)
                let snapshot = await dependencies.context.promptVM.workspaceFileContextStore.makeFileTreeSelectionSnapshot(
                    selection: StoredSelection(),
                    request: WorkspaceFileTreeSnapshotRequest(mode: .full, filePathDisplay: filePathDisplay, onlyIncludeRootsWithSelectedFiles: false, includeLegend: false, showCodeMapMarkers: false, rootScope: lookupContext.rootScope),
                    profile: .mcpRead
                )
                if snapshot.roots.isEmpty {
                    let msg = await dependencies.files.workspaceContextMessage(MCPWindowToolName.getFileTree, nil)
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
                let authority = await readAuthority(appContext)
                let metadata = authority.metadata
                let lookupContext = authority.lookupContext
                _ = await dependencies.context.promptVM.workspaceFileContextStore.awaitAppliedIngress(rootScope: lookupContext.rootScope)
                if mode.lowercased() == "selected" {
                    guard try await dependencies.files.drainReadFileAutoSelection(metadata, .canonicalSelection) == .completed else {
                        throw CancellationError()
                    }
                }
                let worktreeScope = ToolResultDTOs.WorktreeScopeDTO.sessionBound(from: lookupContext.bindingProjection)
                let resultAndRootCount = try await dependencies.files.buildStoreBackedFileTreeResult(mode, maxDepth, args["path"]?.stringValue, lookupContext)
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

    private func executeReadFile(
        args: [String: Value],
        appContext: MCPServerViewModel.DomainReadAppExecutionContext?,
        sideEffects: MCPDomainReadSideEffectEmitter
    ) async throws -> Value {
        try await executeReadFileBody(args: args, appContext: appContext, sideEffects: sideEffects)
    }

    private func executeReadFileBody(
        args: [String: Value],
        appContext: MCPServerViewModel.DomainReadAppExecutionContext?,
        sideEffects: MCPDomainReadSideEffectEmitter
    ) async throws -> Value {
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
        let authority = await EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.providerRequestMetadata) {
            await readAuthority(appContext)
        }
        let metadata = authority.metadata
        try Task.checkCancellation()
        let lookupContext = EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.providerLookupContextResolution) {
            authority.lookupContext
        }
        try Task.checkCancellation()
        let (worktreeScope, resolvedPath) = EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.providerPathTranslation) {
            let worktreeScope = ToolResultDTOs.WorktreeScopeDTO.sessionBound(from: lookupContext.bindingProjection)
            let resolvedPath = lookupContext.translateInputPath(path)
            return (worktreeScope, resolvedPath)
        }
        try Task.checkCancellation()
        var readResult: (reply: ToolResultDTOs.ReadFileReply, shouldAutoSelect: Bool)
        do {
            readResult = try await EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.providerReadEnvelope) {
                if let artifact = try await dependencies.files.readSelectedAuthorizedGitArtifact(
                    path,
                    resolvedPath,
                    startLine1Based,
                    limit,
                    metadata,
                    lookupContext
                ) {
                    return artifact
                }
                return try await dependencies.files.readFile(
                    resolvedPath,
                    startLine1Based,
                    limit,
                    lookupContext.rootScope
                )
            }
        } catch WorkspaceAppliedIngressWaitError.timedOut {
            return try Value(Self.readFileFreshnessTimeoutDTO(
                path: path,
                worktreeScope: worktreeScope
            ))
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
        try await EditFlowPerf.measure(
            EditFlowPerf.Stage.ReadFile.providerAutoSelect,
            EditFlowPerf.Dimensions(outcome: readResult.shouldAutoSelect ? "attempted" : "skipped")
        ) {
            if readResult.shouldAutoSelect {
                let reply = readResult.reply
                try await sideEffects.submitAndWait(fingerprint: "read_file_auto_selection") { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await applyReadFileSideEffect(
                        reply: reply,
                        requestedPath: path,
                        resolvedPath: resolvedPath,
                        metadata: metadata
                    )
                }
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

    private static func readFileFreshnessTimeoutDTO(
        path: String,
        worktreeScope: ToolResultDTOs.WorktreeScopeDTO? = nil
    ) -> ToolResultDTOs.ReadFileReply {
        ToolResultDTOs.ReadFileReply(
            content: "",
            totalLines: 0,
            firstLine: 0,
            lastLine: 0,
            message: "Workspace freshness timed out before read_file could read '\(path)'. Retry after pending file-system ingress settles.",
            displayPath: path,
            worktreeScope: worktreeScope,
            errorMessage: "Workspace freshness timed out before pending file-system ingress was applied.",
            errorCode: "workspace_freshness_timeout",
            retryable: true,
            retryAfterMilliseconds: 1000
        )
    }

    private func executeFileSearchToolValue(
        args: [String: Value],
        appContext: MCPServerViewModel.DomainReadAppExecutionContext?,
        sideEffects: MCPDomainReadSideEffectEmitter
    ) async throws -> Value {
        EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.Search.providerEntered)
        let providerTotal = EditFlowPerf.begin(EditFlowPerf.Stage.Search.providerTotal)
        defer { EditFlowPerf.end(EditFlowPerf.Stage.Search.providerTotal, providerTotal) }
        let reply = try await executeFileSearch(
            args: args,
            appContext: appContext,
            sideEffects: sideEffects
        )

        try Task.checkCancellation()
        let value = try EditFlowPerf.measure(EditFlowPerf.Stage.Search.providerValueEncoding) {
            try Value(reply)
        }
        EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.Search.providerResultReady)
        return value
    }

    private func executeFileSearch(
        args: [String: Value],
        appContext: MCPServerViewModel.DomainReadAppExecutionContext?,
        sideEffects: MCPDomainReadSideEffectEmitter
    ) async throws -> ToolResultDTOs.SearchResultDTO {
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
        let authority = await EditFlowPerf.measure(EditFlowPerf.Stage.Search.providerRequestMetadata) {
            await readAuthority(appContext)
        }
        let metadata = authority.metadata
        try Task.checkCancellation()
        let lookupContext = EditFlowPerf.measure(
            EditFlowPerf.Stage.Search.providerLookupContextResolution,
            EditFlowPerf.Dimensions(searchMode: mode.rawValue, countOnly: countOnly)
        ) {
            authority.lookupContext
        }
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
                try await dependencies.selection.workspaceSearch(
                    pattern, mode, regex, true, maxResults, maxResults, limiters, includeExts, excludePatterns, contextLines, wholeWord, countOnly, pattern.contains(" "), lookupRootScope
                )
            }
            try Task.checkCancellation()
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.Search.providerWorkspaceSearchReturned,
                EditFlowPerf.Dimensions(outcome: "completed", searchMode: mode.rawValue, countOnly: countOnly)
            )
        } catch let error as StoreBackedWorkspaceSearchError {
            let outcome = switch error {
            case .worktreeScopeUnavailable:
                "worktreeScopeUnavailable"
            case .workspaceFreshnessTimedOut:
                "workspaceFreshnessTimedOut"
            case .workspaceReadinessUnavailable:
                "workspaceReadinessUnavailable"
            case .workspaceReadinessTimedOut:
                "workspaceReadinessTimedOut"
            case .workspaceReadinessSuperseded:
                "workspaceReadinessSuperseded"
            }
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.Search.providerWorkspaceSearchReturned,
                EditFlowPerf.Dimensions(outcome: outcome, searchMode: mode.rawValue, countOnly: countOnly)
            )
            let reply = Self.searchRetryableFailureDTO(for: error, worktreeScope: worktreeScope)
            EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.Search.providerDTOReady, EditFlowPerf.Dimensions(outcome: outcome))
            EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.Search.providerAutoSelectionReturned, EditFlowPerf.Dimensions(outcome: "skippedRetryableFailure"))
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
            await dependencies.context.promptVM.workspaceFileContextStore.displayRootRefsSnapshot()
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
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.Search.providerDTOReady,
                EditFlowPerf.Dimensions(
                    outcome: "completed",
                    matchCount: reply.totalMatches,
                    usesWorktreeProjection: usesWorktreeProjection,
                    countOnly: true
                )
            )
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
        var physicalPathsByLogicalPath: [String: Set<String>] = [:]
        for (logicalMatch, physicalMatch) in zip(
            includedContentMatches,
            (results.matches ?? []).prefix(includedContentMatches.count)
        ) {
            physicalPathsByLogicalPath[logicalMatch.filePath, default: []].insert(physicalMatch.filePath)
        }
        let autoSelectionResolvedPhysicalPaths = reply.contentMatchGroups.compactMap { group -> String? in
            guard let candidates = physicalPathsByLogicalPath[group.path], candidates.count == 1 else {
                return nil
            }
            return candidates.first
        }
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Search.providerDTOReady,
            EditFlowPerf.Dimensions(
                outcome: dtoBuildOutcome,
                matchCount: reply.totalMatches,
                usesWorktreeProjection: usesWorktreeProjection,
                searchMode: mode.rawValue,
                countOnly: false
            )
        )
        try Task.checkCancellation()
        try await EditFlowPerf.measure(
            EditFlowPerf.Stage.Search.providerAutoSelection,
            EditFlowPerf.Dimensions(searchMode: mode.rawValue, contextLines: contextLines)
        ) {
            try await sideEffects.submitAndWait(fingerprint: "file_search_auto_selection") { [weak self] in
                guard let self else { throw CancellationError() }
                try await applyFileSearchSideEffect(
                    mode: mode,
                    contextLines: contextLines,
                    reply: reply,
                    resolvedPhysicalPaths: autoSelectionResolvedPhysicalPaths,
                    metadata: metadata
                )
            }
        }
        EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.Search.providerAutoSelectionReturned)
        return reply
    }

    private func applyReadFileSideEffect(
        reply: ToolResultDTOs.ReadFileReply,
        requestedPath: String,
        resolvedPath: String,
        metadata: MCPServerViewModel.RequestMetadata
    ) async throws {
        try await dependencies.files.enqueueReadFileAutoSelection(
            reply,
            requestedPath,
            resolvedPath,
            metadata
        )
        // Historical read_file completion guaranteed queue admission, not completion of the
        // deferred presentation mirror. Legacy consumers can now drain immediately after reply.
        try Task.checkCancellation()
    }

    private func applyFileSearchSideEffect(
        mode: SearchMode,
        contextLines: Int,
        reply: ToolResultDTOs.SearchResultDTO,
        resolvedPhysicalPaths: [String],
        metadata: MCPServerViewModel.RequestMetadata
    ) async throws {
        try await dependencies.files.enqueueFileSearchAutoSelection(
            mode,
            contextLines,
            reply,
            resolvedPhysicalPaths,
            metadata
        )
        // Match read_file: publish admission before reply without serializing the response on UI
        // mirroring/metrics work.
        try Task.checkCancellation()
    }

    static func searchRetryableFailureDTO(
        for error: StoreBackedWorkspaceSearchError,
        worktreeScope: ToolResultDTOs.WorktreeScopeDTO? = nil
    ) -> ToolResultDTOs.SearchResultDTO {
        let errorCode = switch error {
        case .worktreeScopeUnavailable:
            "worktree_scope_unavailable"
        case .workspaceFreshnessTimedOut:
            "workspace_freshness_timeout"
        case .workspaceReadinessUnavailable:
            "workspace_readiness_unavailable"
        case .workspaceReadinessTimedOut:
            "workspace_readiness_timeout"
        case .workspaceReadinessSuperseded:
            "workspace_readiness_superseded"
        }
        return ToolResultDTOs.SearchResultDTO(
            totalMatches: 0,
            totalFiles: 0,
            contentMatches: 0,
            pathMatches: 0,
            limitHit: false,
            perFileCounts: [],
            pathMatchLines: [],
            contentMatchGroups: [],
            errorMessage: error.localizedDescription,
            errorCode: errorCode,
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
