import Foundation
import JSONSchema
import MCP
import Ontology

@MainActor
final class MCPSelectionToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .selection

    private let runtime: MCPWindowToolRuntime
    private let dependencies: MCPWindowToolDependencies

    private struct ArtifactCommitConflict: Error {
        let reason: String
    }

    init(runtime: MCPWindowToolRuntime, dependencies: MCPWindowToolDependencies) {
        self.runtime = runtime
        self.dependencies = dependencies
    }

    func buildTools() -> [Tool] {
        [manageSelectionTool()]
    }

    private func manageSelectionTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.manageSelection,
            freshnessPolicy: .providerManaged,
            description: """
            Manage the file selection used by all tools.

            **Operations**: get | add | remove | set | clear | preview | promote | demote

            **Modes** (how files appear in context):
            - `full` (default): Complete file content
            - `slices`: Specific line ranges only
            - `codemap_only`: API signatures only (function/type definitions)

            **Key behaviors**:
            - Incremental context changes use `op=add` / `op=remove`
            - `op=set` with `mode=full`: Complete selection replacement
            - `op=set` with `mode=codemap_only`: Complete codemap-only replacement
            - `op=set` with `mode=slices`: File-scoped slice replacement (requires `#L` ranges or `slices` entries; preserves unrelated full files and slices)
            - Mixed full-file + slice additions use `op=add` with both `paths` and `slices`
            - Auto-codemap: When adding files with `mode=full/slices`, related files get auto-added as codemaps
            - Manual mode: Using `mode=codemap_only`, `promote`, or `demote` disables auto-management

            **Path handling**:
            - Accepts files or directories (directories expand recursively)
            - Relative or absolute paths accepted
            - Multi-root: prefix with root name (e.g., "ProjectA/src/main.swift")
            - Single-root: prefix optional
            - Fuzzy matching enabled by default
            - Exact `_git_data/...` aliases advertised by the Git tool may be added, removed, set, or previewed as full files
            - Git artifact aliases do not support fuzzy matching, folder expansion, codemaps, or slices

            **Options**:
            - `view`: "summary" | "files" | "content" | "codemaps" (default: "summary")
            - `path_display`: "relative" | "full" (default: "relative")
            - `strict`: When true, errors if no paths resolve (default: false)

            **Examples**:
            - Get selection: `{"op":"get","view":"files"}`
            - Add files: `{"op":"add","paths":["src/main.swift"]}`
            - Add slices: `{"op":"add","slices":[{"path":"file.swift","ranges":[{"start_line":45,"end_line":120}]}]}`
            - Set codemap-only: `{"op":"set","paths":["utils/"],"mode":"codemap_only"}`
            - Promote codemap→full: `{"op":"promote","paths":["helper.swift"]}`

            Related: get_file_tree, file_search, workspace_context, prompt, apply_edits
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                properties: [
                    "op": .string(description: "Operation", enum: ["get", "add", "remove", "set", "clear", "preview", "promote", "demote"]),
                    "paths": .array(description: "File or folder paths (required for add/remove/set)", items: .string(description: "Relative or absolute file or folder path")),
                    "mode": .string(description: "How to represent files in selection: 'full' (complete content), 'slices' (line ranges), or 'codemap_only' (signatures only). With op=set, mode changes semantics (see 'op=set semantics' above).", enum: ["full", "slices", "codemap_only"]),
                    "slices": .array(
                        description: "Selection slices to apply (path + line ranges)",
                        items: .object(
                            properties: [
                                "path": .string(description: "Relative or absolute file path"),
                                "ranges": .array(
                                    description: "Explicit line ranges (inclusive)",
                                    items: .object(
                                        properties: [
                                            "start_line": .integer(description: "1-based start line"),
                                            "end_line": .integer(description: "1-based end line"),
                                            "description": .string(description: "Optional slice description (aliases: desc, label)")
                                        ],
                                        required: ["start_line"]
                                    )
                                ),
                                "lines": .string(description: "Comma-separated shorthand like '10-20,40'")
                            ],
                            required: ["path"]
                        )
                    ),
                    "view": .string(description: "Amount of detail to return", enum: ["summary", "files", "content", "codemaps"]),
                    "path_display": .string(description: "Path display for blocks", enum: ["full", "relative"]),
                    "strict": .boolean(description: "Throw when no paths resolve (mutations)")
                ],
                required: []
            )
        ) { [self] _, args in
            try await Value(executeManageSelection(args: args))
        }
    }

    private func executeManageSelection(args: [String: Value]) async throws -> ToolResultDTOs.SelectionReply {
        #if DEBUG
            let metadata = await dependencies.captureRequestMetadata()
            let lookupContext = await dependencies.resolveFileToolLookupContext(metadata)
            let tag = lookupContext.bindingProjection.map(\.sessionID).flatMap {
                WorktreeStartupBenchmarkDiagnostics.shared.activeBenchmarkMetricTag(
                    agentSessionID: $0
                )
            }
            return try await WorktreeStartupInstrumentation.$currentBenchmarkMetricTag.withValue(tag) {
                try await executeManageSelectionWithRetry(args: args)
            }
        #else
            return try await executeManageSelectionWithRetry(args: args)
        #endif
    }

    private func executeManageSelectionWithRetry(
        args: [String: Value]
    ) async throws -> ToolResultDTOs.SelectionReply {
        do {
            return try await executeManageSelectionAttempt(args: args)
        } catch is ArtifactCommitConflict {
            do {
                return try await executeManageSelectionAttempt(args: args)
            } catch let retryConflict as ArtifactCommitConflict {
                throw MCPError.internalError(
                    "Canonical selection changed concurrently (\(retryConflict.reason)). Retry manage_selection."
                )
            }
        }
    }

    private func executeManageSelectionAttempt(args: [String: Value]) async throws -> ToolResultDTOs.SelectionReply {
        try Task.checkCancellation()
        let op = (args["op"]?.stringValue ?? "get").lowercased()
        let rawPaths = args["paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let parsedInputs = dependencies.parseManageSelectionInputs(rawPaths, args["slices"])
        let selectionPaths = parsedInputs.paths
        let sliceInputs = parsedInputs.sliceInputs
        let sliceParseErrors = parsedInputs.sliceErrors
        let mode = args["mode"]?.stringValue?.lowercased() ?? "full"
        if await dependencies.promptVM.codeMapsGloballyDisabled, mode == "codemap_only" || op == "demote" {
            throw MCPError.invalidParams(MCPServerViewModel.codeMapsGloballyDisabledMCPMessage)
        }
        try Task.checkCancellation()
        let view = (args["view"]?.stringValue ?? "summary").lowercased()
        let strict = args["strict"]?.boolValue ?? false
        let display: FilePathDisplay = ((args["path_display"]?.stringValue ?? "relative").lowercased() == "full") ? .full : .relative
        let includeBlocks = view == "content"
        let metadata = await dependencies.captureRequestMetadata()
        try Task.checkCancellation()
        await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionAutoSelectionDrain)
        let drainRequirement: MCPReadFileAutoSelectionCoordinator.DrainRequirement = op == "get"
            ? .canonicalSelection
            : .mirroredSelectionAndMetrics
        guard await dependencies.drainReadFileAutoSelection(metadata, drainRequirement) == .completed else {
            throw CancellationError()
        }
        await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionAutoSelectionDrain, transition: .completed)
        try Task.checkCancellation()
        var resolvedContext = try dependencies.resolveTabContextSnapshot(metadata, MCPWindowToolName.manageSelection, .allowLegacyImplicitRouting)
        let lookupContext = await dependencies.resolveFileToolLookupContext(metadata)
        try Task.checkCancellation()
        let lookupRootScope = lookupContext.rootScope
        if op != "get" {
            await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionIngressWait)
            _ = await dependencies.promptVM.workspaceFileContextStore.awaitAppliedIngress(rootScope: lookupRootScope)
            await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionIngressWait, transition: .completed)
        }
        try Task.checkCancellation()
        await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionConstruction)
        if !resolvedContext.usesActiveTabCompatibility {
            resolvedContext.snapshot.selection = await dependencies.stabilizedVirtualSelection(resolvedContext.snapshot)
            try Task.checkCancellation()
        }
        resolvedContext.snapshot.selection = lookupContext.physicalizeSelection(resolvedContext.snapshot.selection)
        let frozenReviewContext: FrozenPromptGitReviewContext?
        let artifactResolution: MCPManageSelectionArtifactResolution
        if ["add", "remove", "set", "preview"].contains(op) {
            let frozen = await dependencies.freezePromptGitReviewContext(resolvedContext.snapshot)
            frozenReviewContext = frozen
            let identity = resolvedContext.snapshot.workspaceID.map {
                WorkspaceSelectionIdentity(
                    workspaceID: $0,
                    tabID: resolvedContext.snapshot.tabID
                )
            }
            artifactResolution = await dependencies.resolveManageSelectionArtifactInputs(
                MCPManageSelectionArtifactResolutionRequest(
                    paths: parsedInputs.paths,
                    sliceInputs: parsedInputs.sliceInputs,
                    use: op == "remove" ? .remove : .insert,
                    mode: mode,
                    physicalSelection: resolvedContext.snapshot.selection,
                    identity: identity,
                    capability: frozen.artifactCapability
                )
            )
        } else {
            frozenReviewContext = nil
            let artifactInputs = parsedInputs.paths.filter {
                let path = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return path == "_git_data" || path.hasPrefix("_git_data/")
            }
            if !artifactInputs.isEmpty, op == "promote" || op == "demote" {
                throw MCPError.invalidParams(
                    "Git artifact aliases support add, remove, set, and preview in mode 'full' only."
                )
            }
            artifactResolution = MCPManageSelectionArtifactResolution(
                ordinaryPaths: parsedInputs.paths,
                ordinarySliceInputs: parsedInputs.sliceInputs,
                artifacts: [],
                invalidDiagnostics: [],
                fence: nil
            )
        }
        let physicalParsedInputs = MCPServerViewModel.ManageSelectionInputs(
            paths: lookupContext.translateInputPaths(artifactResolution.ordinaryPaths),
            sliceInputs: lookupContext.translateSliceInputs(artifactResolution.ordinarySliceInputs),
            sliceErrors: parsedInputs.sliceErrors,
            hadExplicitSliceSpec: parsedInputs.hadExplicitSliceSpec
        )
        let physicalSelectionPaths = physicalParsedInputs.paths
        let physicalSliceInputs = physicalParsedInputs.sliceInputs
        let extraInvalid = sliceParseErrors + artifactResolution.invalidDiagnostics

        switch op {
        case "get":
            let ctx = resolvedContext.snapshot
            selectionLog("[Virtual] manage_selection op=get tab=\(ctx.tabID) selected=\(ctx.selection.selectedPaths.count) manualCodemaps=\(ctx.selection.manualCodemapPaths.count) slices=\(ctx.selection.slices.count)")
            await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionConstruction, transition: .completed)
            try Task.checkCancellation()
            await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionReplyConstruction)
            let reply = try await dependencies.buildCurrentSelectionReply(includeBlocks, display, extraInvalid, view, resolvedContext, lookupContext)
            await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionReplyConstruction, transition: .completed)
            try Task.checkCancellation()
            return reply
        case "preview":
            let context = resolvedContext.snapshot
            if mode == "codemap_only", !physicalSliceInputs.isEmpty {
                throw MCPError.invalidParams("mode 'codemap_only' cannot be used with slices")
            }
            let buildResult = await dependencies.buildManageSelectionSetSelection(
                physicalParsedInputs,
                mode,
                context.selection,
                !artifactResolution.artifacts.isEmpty,
                lookupRootScope
            )
            try Task.checkCancellation()
            let selectionWithArtifacts = dependencies.mutatePreResolvedFullFilePaths(
                buildResult.selection,
                artifactResolution.absolutePaths,
                .add
            )
            let previewSelectionFinal = mode == "codemap_only"
                ? buildResult.selection
                : selectionWithArtifacts
            var combinedInvalid = buildResult.invalidPaths
            for msg in buildResult.codemapUnavailable where !combinedInvalid.contains(msg) {
                combinedInvalid.append(msg)
            }
            for error in extraInvalid where !combinedInvalid.contains(error) {
                combinedInvalid.append(error)
            }
            let previewCodeMapOverride: CodeMapUsage? = (!resolvedContext.usesActiveTabCompatibility && context.runID != nil) ? .auto : nil
            await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionConstruction, transition: .completed)
            try Task.checkCancellation()
            await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionReplyConstruction)
            let previewReply = try await dependencies.buildSelectionPreviewReply(
                previewSelectionFinal,
                includeBlocks,
                display,
                combinedInvalid,
                view,
                previewCodeMapOverride,
                lookupContext,
                resolvedContext.usesActiveTabCompatibility ? nil : context,
                frozenReviewContext
            )
            if let fence = artifactResolution.fence {
                let fenceIsCurrent = await dependencies.validateManageSelectionArtifactFence(fence)
                if !fenceIsCurrent {
                    throw ArtifactCommitConflict(reason: "Git artifact advertisement changed during preview")
                }
            }
            await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionReplyConstruction, transition: .completed)
            try Task.checkCancellation()
            if strict {
                let resolvedPreviewArtifactCount = artifactResolution.artifacts.count { artifact in
                    previewReply.files?.contains { $0.path == artifact.alias } == true
                }
                let resolvedAny = resolvedPreviewArtifactCount > 0
                    || (previewReply.files?.isEmpty == false)
                    || (previewReply.fileSlices?.isEmpty == false)
                if !resolvedAny {
                    if !artifactResolution.invalidDiagnostics.isEmpty {
                        throw MCPError.invalidParams(
                            artifactResolution.invalidDiagnostics.joined(separator: "; ")
                        )
                    }
                    var hintInputs = rawPaths
                    let slicePaths = physicalSliceInputs.map(\.path)
                    if hintInputs.isEmpty {
                        hintInputs = slicePaths
                    } else {
                        for candidate in slicePaths where !hintInputs.contains(candidate) {
                            hintInputs.append(candidate)
                        }
                    }
                    let hint = await dependencies.makeSelectionHintError(hintInputs, "preview", lookupContext)
                    throw MCPError.invalidParams(hint)
                }
            }
            return previewReply
        case "set":
            let context = resolvedContext.snapshot
            selectionLog("[Virtual] manage_selection op=set tab=\(context.tabID)")
            if mode == "codemap_only", !physicalSliceInputs.isEmpty {
                throw MCPError.invalidParams("mode 'codemap_only' cannot be used with slices")
            }
            let setBuildResult = await dependencies.buildManageSelectionSetSelection(
                physicalParsedInputs,
                mode,
                context.selection,
                !artifactResolution.artifacts.isEmpty,
                lookupRootScope
            )
            try Task.checkCancellation()
            let currentSelection = dependencies.mutatePreResolvedFullFilePaths(
                setBuildResult.selection,
                artifactResolution.absolutePaths,
                .add
            )
            var combinedInvalid = setBuildResult.invalidPaths
            for error in extraInvalid where !combinedInvalid.contains(error) {
                combinedInvalid.append(error)
            }
            if !combinedInvalid.isEmpty {
                throw MCPError.invalidParams("Invalid selection inputs: \(combinedInvalid.joined(separator: ", "))")
            }
            for msg in setBuildResult.codemapUnavailable where !combinedInvalid.contains(msg) {
                combinedInvalid.append(msg)
            }
            return try await persistAndReply(
                resolvedContext: &resolvedContext,
                metadata: metadata,
                lookupContext: lookupContext,
                baseContext: context,
                selection: currentSelection,
                includeBlocks: includeBlocks,
                display: display,
                extraInvalid: combinedInvalid,
                view: view,
                artifactFence: artifactResolution.fence,
                reviewGitContext: frozenReviewContext
            )
        case "add":
            if parsedInputs.paths.isEmpty, parsedInputs.sliceInputs.isEmpty { throw MCPError.invalidParams("paths or slices required for add") }
            let context = resolvedContext.snapshot
            selectionLog("[Virtual] manage_selection op=add mode=\(mode) paths=\(selectionPaths.count) slices=\(sliceInputs.count) tab=\(context.tabID)")
            var invalid: [String] = []
            var resolvedMap: [String: String] = [:]
            var pathMutated = false
            var currentSelection = context.selection
            var codemapUnavailableMsgs: [String] = []

            if mode == "codemap_only", !physicalSliceInputs.isEmpty {
                throw MCPError.invalidParams("mode 'codemap_only' cannot be used with slices")
            }
            if !physicalSelectionPaths.isEmpty {
                let addResult = await dependencies.addStoredSelectionPaths(currentSelection, physicalSelectionPaths, rawPaths, mode, lookupRootScope)
                try Task.checkCancellation()
                currentSelection = addResult.selection
                invalid.append(contentsOf: addResult.invalidPaths)
                codemapUnavailableMsgs.append(contentsOf: addResult.codemapUnavailable)
                for (key, value) in addResult.resolvedMap where resolvedMap[key] == nil {
                    resolvedMap[key] = value
                }
                pathMutated = addResult.mutated
            }
            if mode != "codemap_only" {
                var sliceResolved = false
                var sliceMutated = false
                var sliceInvalid = false
                if !physicalSliceInputs.isEmpty {
                    let sliceResult = await dependencies.computeSelectionSlicesVirtual(currentSelection, physicalSliceInputs, .add, lookupRootScope)
                    try Task.checkCancellation()
                    currentSelection = sliceResult.selection
                    invalid.append(contentsOf: sliceResult.result.invalidPaths)
                    sliceResolved = !sliceResult.result.resolvedMap.isEmpty
                    sliceMutated = sliceResult.mutated
                    sliceInvalid = !sliceResult.result.invalidPaths.isEmpty
                } else if parsedInputs.hadExplicitSliceSpec && strict {
                    let detail = sliceParseErrors.isEmpty ? "No valid slices parsed from provided specification" : sliceParseErrors.joined(separator: "; ")
                    throw MCPError.invalidParams(detail)
                }
                let resolvedAnything = pathMutated || !resolvedMap.isEmpty || sliceResolved || sliceMutated
                    || artifactResolution.resolvedCount > 0
                if strict, !resolvedAnything {
                    if !artifactResolution.invalidDiagnostics.isEmpty {
                        throw MCPError.invalidParams(
                            artifactResolution.invalidDiagnostics.joined(separator: "; ")
                        )
                    }
                    if !selectionPaths.isEmpty {
                        let hint = await dependencies.makeSelectionHintError(rawPaths, "add", lookupContext)
                        throw MCPError.invalidParams(hint)
                    } else if !sliceInvalid {
                        throw MCPError.invalidParams("Provided slices did not match any files")
                    }
                }
            } else if strict, !pathMutated, resolvedMap.isEmpty,
                      artifactResolution.resolvedCount == 0
            {
                if !artifactResolution.invalidDiagnostics.isEmpty {
                    throw MCPError.invalidParams(
                        artifactResolution.invalidDiagnostics.joined(separator: "; ")
                    )
                }
                let hint = await dependencies.makeSelectionHintError(rawPaths, "add", lookupContext)
                throw MCPError.invalidParams(hint)
            }
            currentSelection = dependencies.mutatePreResolvedFullFilePaths(
                currentSelection,
                artifactResolution.absolutePaths,
                .add
            )
            var combinedInvalid = invalid
            for error in extraInvalid where !combinedInvalid.contains(error) {
                combinedInvalid.append(error)
            }
            for error in sliceParseErrors where !combinedInvalid.contains(error) {
                combinedInvalid.append(error)
            }
            for msg in codemapUnavailableMsgs where !combinedInvalid.contains(msg) {
                combinedInvalid.append(msg)
            }
            return try await persistAndReply(
                resolvedContext: &resolvedContext,
                metadata: metadata,
                lookupContext: lookupContext,
                baseContext: context,
                selection: currentSelection,
                includeBlocks: includeBlocks,
                display: display,
                extraInvalid: combinedInvalid,
                view: view,
                artifactFence: artifactResolution.fence,
                reviewGitContext: frozenReviewContext
            )
        case "remove":
            if parsedInputs.paths.isEmpty, parsedInputs.sliceInputs.isEmpty { throw MCPError.invalidParams("paths or slices required for remove") }
            if mode == "codemap_only", !physicalSliceInputs.isEmpty { throw MCPError.invalidParams("mode 'codemap_only' cannot be used with slices") }
            let context = resolvedContext.snapshot
            selectionLog("[Virtual] manage_selection op=remove mode=\(mode) paths=\(selectionPaths.count) slices=\(sliceInputs.count) tab=\(context.tabID)")
            var invalid: [String] = []
            var resolvedMap: [String: String] = [:]
            var pathMutated = false
            var currentSelection = context.selection
            if !physicalSelectionPaths.isEmpty {
                let result = await dependencies.removeStoredSelectionPaths(currentSelection, physicalSelectionPaths, rawPaths, mode, lookupRootScope)
                try Task.checkCancellation()
                currentSelection = result.0
                invalid.append(contentsOf: result.1)
                for (key, value) in result.2 where resolvedMap[key] == nil {
                    resolvedMap[key] = value
                }
                pathMutated = result.3
            }
            var sliceResolved = false
            var sliceMutated = false
            var sliceInvalid = false
            if !physicalSliceInputs.isEmpty {
                let sliceResult = await dependencies.computeSelectionSlicesVirtual(currentSelection, physicalSliceInputs, .remove, lookupRootScope)
                try Task.checkCancellation()
                currentSelection = sliceResult.selection
                invalid.append(contentsOf: sliceResult.result.invalidPaths)
                sliceResolved = !sliceResult.result.resolvedMap.isEmpty
                sliceMutated = sliceResult.mutated
                sliceInvalid = !sliceResult.result.invalidPaths.isEmpty
                if strict, !(pathMutated || !resolvedMap.isEmpty || sliceResolved || sliceMutated), !sliceInvalid {
                    throw MCPError.invalidParams("Provided slices did not match any files")
                }
            } else if parsedInputs.hadExplicitSliceSpec, strict {
                let detail = sliceParseErrors.isEmpty ? "No valid slices parsed from provided specification" : sliceParseErrors.joined(separator: "; ")
                throw MCPError.invalidParams(detail)
            }
            if strict, !(pathMutated || !resolvedMap.isEmpty || sliceResolved || sliceMutated), !selectionPaths.isEmpty {
                if artifactResolution.resolvedCount > 0 {
                    // Exact artifact resolution is successful even when the structural result is a no-op.
                } else if !artifactResolution.invalidDiagnostics.isEmpty {
                    throw MCPError.invalidParams(
                        artifactResolution.invalidDiagnostics.joined(separator: "; ")
                    )
                } else {
                    let hint = await dependencies.makeSelectionHintError(rawPaths, "remove", lookupContext)
                    throw MCPError.invalidParams(hint)
                }
            }
            currentSelection = dependencies.mutatePreResolvedFullFilePaths(
                currentSelection,
                artifactResolution.absolutePaths,
                .remove
            )
            var combinedInvalid = invalid
            for error in extraInvalid where !combinedInvalid.contains(error) {
                combinedInvalid.append(error)
            }
            for error in sliceParseErrors where !combinedInvalid.contains(error) {
                combinedInvalid.append(error)
            }
            return try await persistAndReply(
                resolvedContext: &resolvedContext,
                metadata: metadata,
                lookupContext: lookupContext,
                baseContext: context,
                selection: currentSelection,
                includeBlocks: includeBlocks,
                display: display,
                extraInvalid: combinedInvalid,
                view: view,
                artifactFence: artifactResolution.fence,
                reviewGitContext: frozenReviewContext
            )
        case "promote":
            let context = resolvedContext.snapshot
            selectionLog("[Virtual] manage_selection op=promote paths=\(selectionPaths.count) tab=\(context.tabID)")
            if physicalSelectionPaths.isEmpty { throw MCPError.invalidParams("paths required for promote") }
            if !physicalSliceInputs.isEmpty { throw MCPError.invalidParams("promote does not support slices") }
            let (newSelection, invalid, mutated) = await dependencies.promoteStoredSelectionPaths(context.selection, physicalSelectionPaths, rawPaths, strict, lookupRootScope)
            try Task.checkCancellation()
            var combinedInvalid = invalid
            for error in extraInvalid where !combinedInvalid.contains(error) {
                combinedInvalid.append(error)
            }
            if strict, !mutated {
                let hint = await dependencies.makeSelectionHintError(rawPaths, "promote", lookupContext)
                throw MCPError.invalidParams(hint)
            }
            return try await persistAndReply(resolvedContext: &resolvedContext, metadata: metadata, lookupContext: lookupContext, baseContext: context, selection: newSelection, includeBlocks: includeBlocks, display: display, extraInvalid: combinedInvalid, view: view)
        case "demote":
            let context = resolvedContext.snapshot
            selectionLog("[Virtual] manage_selection op=demote paths=\(selectionPaths.count) tab=\(context.tabID)")
            if physicalSelectionPaths.isEmpty { throw MCPError.invalidParams("paths required for demote") }
            if !physicalSliceInputs.isEmpty { throw MCPError.invalidParams("demote does not support slices") }
            let demoteResult = await dependencies.demoteStoredSelectionPaths(context.selection, physicalSelectionPaths, rawPaths, strict, lookupRootScope)
            try Task.checkCancellation()
            var combinedInvalid = demoteResult.invalidPaths
            for error in extraInvalid where !combinedInvalid.contains(error) {
                combinedInvalid.append(error)
            }
            for msg in demoteResult.codemapUnavailable where !combinedInvalid.contains(msg) {
                combinedInvalid.append(msg)
            }
            if strict, !demoteResult.mutated {
                let hint = await dependencies.makeSelectionHintError(rawPaths, "demote", lookupContext)
                throw MCPError.invalidParams(hint)
            }
            return try await persistAndReply(resolvedContext: &resolvedContext, metadata: metadata, lookupContext: lookupContext, baseContext: context, selection: demoteResult.selection, includeBlocks: includeBlocks, display: display, extraInvalid: combinedInvalid, view: view)
        case "clear":
            let baseContext = resolvedContext.snapshot
            selectionLog("[Virtual] manage_selection op=clear mode=\(mode) tab=\(baseContext.tabID)")
            let clearedSelection = mode == "codemap_only"
                ? StoredSelection(
                    selectedPaths: baseContext.selection.selectedPaths,
                    slices: baseContext.selection.slices,
                    codemapAutoEnabled: false
                )
                : StoredSelection()
            return try await persistAndReply(resolvedContext: &resolvedContext, metadata: metadata, lookupContext: lookupContext, baseContext: baseContext, selection: clearedSelection, includeBlocks: includeBlocks, display: display, extraInvalid: extraInvalid, view: view)
        default:
            throw MCPError.invalidParams("Unsupported op '\(op)' for manage_selection when tab context is active")
        }
    }

    private func persistAndReply(
        resolvedContext: inout MCPServerViewModel.ResolvedTabContextSnapshot,
        metadata: MCPServerViewModel.RequestMetadata,
        lookupContext: WorkspaceLookupContext,
        baseContext: MCPServerViewModel.TabScopedContext,
        selection: StoredSelection,
        includeBlocks: Bool,
        display: FilePathDisplay,
        extraInvalid: [String],
        view: String,
        artifactFence: MCPManageSelectionArtifactAuthorizationFence? = nil,
        reviewGitContext: FrozenPromptGitReviewContext? = nil
    ) async throws -> ToolResultDTOs.SelectionReply {
        resolvedContext.snapshot.selection = selection
        await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionConstruction, transition: .completed)
        try Task.checkCancellation()
        await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionPersistence)
        let canonicalSelection: StoredSelection
        if let artifactFence {
            let result = await dependencies.commitManageSelectionArtifactMutation(
                resolvedContext,
                metadata,
                baseContext.selection,
                selection,
                lookupContext,
                artifactFence
            )
            switch result {
            case let .committed(selection, _):
                canonicalSelection = selection
            case let .conflict(reason):
                throw ArtifactCommitConflict(reason: reason)
            case let .unavailable(reason):
                throw MCPError.internalError(
                    "Selection persistence handoff failed for manage_selection: \(reason)."
                )
            }
        } else {
            let verification = await dependencies.persistResolvedTabContextSnapshot(
                resolvedContext,
                metadata,
                true
            )
            canonicalSelection = try Self.requireCanonicalSelection(
                verification,
                requested: selection,
                tabID: resolvedContext.snapshot.tabID,
                operation: "manage_selection",
                recovery: "Retry manage_selection for the same context_id or rebind the tab context before continuing."
            )
        }
        await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionPersistence, transition: .completed)
        try Task.checkCancellation()
        let codeMapOverride: CodeMapUsage? = (!resolvedContext.usesActiveTabCompatibility && baseContext.runID != nil) ? .auto : nil
        var replyContext = baseContext
        replyContext.selection = canonicalSelection
        await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionReplyConstruction)
        let reply = try await dependencies.buildSelectionMutationReply(
            canonicalSelection,
            includeBlocks,
            display,
            extraInvalid,
            view,
            codeMapOverride,
            resolvedContext.usesActiveTabCompatibility ? nil : replyContext,
            lookupContext,
            reviewGitContext
        )
        await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionReplyConstruction, transition: .completed)
        try Task.checkCancellation()
        return reply
    }

    static func requireCanonicalSelection(
        _ verification: MCPServerViewModel.MCPSelectionPersistenceVerification?,
        requested: StoredSelection,
        tabID: UUID,
        operation: String,
        recovery: String
    ) throws -> StoredSelection {
        guard let verification,
              let canonicalSelection = verification.canonicalSelection,
              verification.isVerified
        else {
            throw MCPError.internalError(selectionPersistenceMismatchMessage(
                expected: verification?.expectedSelection ?? requested,
                canonical: verification?.canonicalSelection,
                tabID: tabID,
                operation: operation,
                recovery: recovery
            ))
        }
        return canonicalSelection
    }

    private static func selectionPersistenceMismatchMessage(
        expected: StoredSelection,
        canonical: StoredSelection?,
        tabID: UUID,
        operation: String,
        recovery: String
    ) -> String {
        let canonicalSummary = canonical.map(selectionSummary) ?? "unavailable"
        return "Selection persistence handoff failed for \(operation) on tab \(tabID.uuidString): canonical selection did not match the requested mutation (expected \(selectionSummary(expected)); canonical \(canonicalSummary)). \(recovery)"
    }

    private static func selectionSummary(_ selection: StoredSelection) -> String {
        "selected=\(selection.selectedPaths.count), manualCodemaps=\(selection.manualCodemapPaths.count), slices=\(selection.slices.count), auto=\(selection.codemapAutoEnabled)"
    }
}
