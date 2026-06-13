import Foundation
import JSONSchema
import MCP
import Ontology

@MainActor
final class MCPSelectionToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .selection

    private let runtime: MCPWindowToolRuntime
    private let dependencies: MCPWindowToolDependencies

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
        guard await dependencies.drainReadFileAutoSelection(metadata, .mirroredSelectionAndMetrics) == .completed else {
            throw CancellationError()
        }
        await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionAutoSelectionDrain, transition: .completed)
        try Task.checkCancellation()
        var resolvedContext = try dependencies.resolveTabContextSnapshot(metadata, MCPWindowToolName.manageSelection, .allowLegacyImplicitRouting)
        let lookupContext = await dependencies.resolveFileToolLookupContext(metadata)
        try Task.checkCancellation()
        let lookupRootScope = lookupContext.rootScope
        await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionIngressWait)
        _ = await dependencies.promptVM.workspaceFileContextStore.awaitAppliedIngress(rootScope: lookupRootScope)
        await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionIngressWait, transition: .completed)
        try Task.checkCancellation()
        await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionConstruction)
        if !resolvedContext.usesActiveTabCompatibility {
            resolvedContext.snapshot.selection = await dependencies.stabilizedVirtualSelection(resolvedContext.snapshot)
            try Task.checkCancellation()
        }
        resolvedContext.snapshot.selection = lookupContext.physicalizeSelection(resolvedContext.snapshot.selection)
        let physicalParsedInputs = MCPServerViewModel.ManageSelectionInputs(
            paths: lookupContext.translateInputPaths(parsedInputs.paths),
            sliceInputs: lookupContext.translateSliceInputs(parsedInputs.sliceInputs),
            sliceErrors: parsedInputs.sliceErrors,
            hadExplicitSliceSpec: parsedInputs.hadExplicitSliceSpec
        )
        let physicalSelectionPaths = physicalParsedInputs.paths
        let physicalSliceInputs = physicalParsedInputs.sliceInputs
        let extraInvalid = sliceParseErrors

        switch op {
        case "get":
            let ctx = resolvedContext.snapshot
            selectionLog("[Virtual] manage_selection op=get tab=\(ctx.tabID) selected=\(ctx.selection.selectedPaths.count) codemap=\(ctx.selection.autoCodemapPaths.count) slices=\(ctx.selection.slices.count)")
            await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionConstruction, transition: .completed)
            try Task.checkCancellation()
            await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionReplyConstruction)
            let reply = try await dependencies.buildCurrentSelectionReply(includeBlocks, display, extraInvalid, view, resolvedContext)
            await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionReplyConstruction, transition: .completed)
            try Task.checkCancellation()
            return reply
        case "preview":
            let context = resolvedContext.snapshot
            if mode == "codemap_only", !physicalSliceInputs.isEmpty {
                throw MCPError.invalidParams("mode 'codemap_only' cannot be used with slices")
            }
            let buildResult = await dependencies.buildManageSelectionSetSelection(physicalParsedInputs, mode, context.selection, lookupRootScope)
            try Task.checkCancellation()
            let previewSelectionFinal: StoredSelection = if mode == "codemap_only" {
                StoredSelection(selectedPaths: buildResult.selection.selectedPaths, autoCodemapPaths: buildResult.selection.autoCodemapPaths, slices: buildResult.selection.slices, codemapAutoEnabled: false)
            } else {
                buildResult.selection
            }
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
            let previewReply = try await dependencies.buildSelectionPreviewReply(previewSelectionFinal, includeBlocks, display, combinedInvalid, view, previewCodeMapOverride, lookupContext)
            await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionReplyConstruction, transition: .completed)
            try Task.checkCancellation()
            if strict {
                let resolvedAny = (previewReply.files?.isEmpty == false) || (previewReply.fileSlices?.isEmpty == false)
                if !resolvedAny {
                    var hintInputs = rawPaths
                    let slicePaths = physicalSliceInputs.map(\.path)
                    if hintInputs.isEmpty {
                        hintInputs = slicePaths
                    } else {
                        for candidate in slicePaths where !hintInputs.contains(candidate) {
                            hintInputs.append(candidate)
                        }
                    }
                    let hint = await dependencies.makeSelectionHintError(hintInputs, "preview", lookupRootScope)
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
            let setBuildResult = await dependencies.buildManageSelectionSetSelection(physicalParsedInputs, mode, context.selection, lookupRootScope)
            try Task.checkCancellation()
            let currentSelection = setBuildResult.selection
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
                baseContext: context,
                selection: currentSelection,
                includeBlocks: includeBlocks,
                display: display,
                extraInvalid: combinedInvalid,
                view: view
            )
        case "add":
            if physicalSelectionPaths.isEmpty, physicalSliceInputs.isEmpty { throw MCPError.invalidParams("paths or slices required for add") }
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
                if strict, !resolvedAnything {
                    if !selectionPaths.isEmpty {
                        let hint = await dependencies.makeSelectionHintError(rawPaths, "add", lookupRootScope)
                        throw MCPError.invalidParams(hint)
                    } else if !sliceInvalid {
                        throw MCPError.invalidParams("Provided slices did not match any files")
                    }
                }
            } else if strict, !pathMutated, resolvedMap.isEmpty {
                let hint = await dependencies.makeSelectionHintError(rawPaths, "add", lookupRootScope)
                throw MCPError.invalidParams(hint)
            }
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
            return try await persistAndReply(resolvedContext: &resolvedContext, metadata: metadata, baseContext: context, selection: currentSelection, includeBlocks: includeBlocks, display: display, extraInvalid: combinedInvalid, view: view)
        case "remove":
            if physicalSelectionPaths.isEmpty, physicalSliceInputs.isEmpty { throw MCPError.invalidParams("paths or slices required for remove") }
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
                let hint = await dependencies.makeSelectionHintError(rawPaths, "remove", lookupRootScope)
                throw MCPError.invalidParams(hint)
            }
            var combinedInvalid = invalid
            for error in extraInvalid where !combinedInvalid.contains(error) {
                combinedInvalid.append(error)
            }
            for error in sliceParseErrors where !combinedInvalid.contains(error) {
                combinedInvalid.append(error)
            }
            return try await persistAndReply(resolvedContext: &resolvedContext, metadata: metadata, baseContext: context, selection: currentSelection, includeBlocks: includeBlocks, display: display, extraInvalid: combinedInvalid, view: view)
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
                let hint = await dependencies.makeSelectionHintError(rawPaths, "promote", lookupRootScope)
                throw MCPError.invalidParams(hint)
            }
            return try await persistAndReply(resolvedContext: &resolvedContext, metadata: metadata, baseContext: context, selection: newSelection, includeBlocks: includeBlocks, display: display, extraInvalid: combinedInvalid, view: view)
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
                let hint = await dependencies.makeSelectionHintError(rawPaths, "demote", lookupRootScope)
                throw MCPError.invalidParams(hint)
            }
            return try await persistAndReply(resolvedContext: &resolvedContext, metadata: metadata, baseContext: context, selection: demoteResult.selection, includeBlocks: includeBlocks, display: display, extraInvalid: combinedInvalid, view: view)
        case "clear":
            let baseContext = resolvedContext.snapshot
            selectionLog("[Virtual] manage_selection op=clear mode=\(mode) tab=\(baseContext.tabID)")
            let clearedSelection = if mode == "codemap_only" {
                StoredSelection(selectedPaths: baseContext.selection.selectedPaths, autoCodemapPaths: [], slices: baseContext.selection.slices, codemapAutoEnabled: false)
            } else {
                StoredSelection()
            }
            return try await persistAndReply(resolvedContext: &resolvedContext, metadata: metadata, baseContext: baseContext, selection: clearedSelection, includeBlocks: includeBlocks, display: display, extraInvalid: extraInvalid, view: view)
        default:
            throw MCPError.invalidParams("Unsupported op '\(op)' for manage_selection when tab context is active")
        }
    }

    private func persistAndReply(
        resolvedContext: inout MCPServerViewModel.ResolvedTabContextSnapshot,
        metadata: MCPServerViewModel.RequestMetadata,
        baseContext: MCPServerViewModel.TabScopedContext,
        selection: StoredSelection,
        includeBlocks: Bool,
        display: FilePathDisplay,
        extraInvalid: [String],
        view: String
    ) async throws -> ToolResultDTOs.SelectionReply {
        resolvedContext.snapshot.selection = selection
        await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionConstruction, transition: .completed)
        try Task.checkCancellation()
        await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionPersistence)
        let verification = await dependencies.persistResolvedTabContextSnapshot(resolvedContext, metadata, true)
        await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionPersistence, transition: .completed)
        try Task.checkCancellation()
        let canonicalSelection = try Self.requireCanonicalSelection(
            verification,
            requested: selection,
            tabID: resolvedContext.snapshot.tabID,
            operation: "manage_selection",
            recovery: "Retry manage_selection for the same context_id or rebind the tab context before continuing."
        )
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
            resolvedContext.usesActiveTabCompatibility ? nil : replyContext
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
        "selected=\(selection.selectedPaths.count), codemap=\(selection.autoCodemapPaths.count), slices=\(selection.slices.count), auto=\(selection.codemapAutoEnabled)"
    }
}
