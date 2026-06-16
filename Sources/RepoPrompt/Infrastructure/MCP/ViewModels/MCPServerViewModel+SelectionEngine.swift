import Foundation
import MCP

struct WorkspaceGitDiffArtifactSelectionService {
    let store: WorkspaceFileContextStore

    func addPrimaryArtifacts(
        existing: StoredSelection,
        paths: [String],
        rootScope: WorkspaceLookupRootScope = .visibleWorkspacePlusGitData
    ) async -> (selection: StoredSelection, autoSelectedPaths: [String]) {
        let orderedPaths = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, item in
                if !result.contains(item) { result.append(item) }
            }
        guard !orderedPaths.isEmpty else { return (existing, []) }

        let previouslySelected = Set(existing.selectedPaths)
        let mutation = await WorkspaceSelectionMutationService(store: store).addPaths(
            existing: existing,
            paths: orderedPaths,
            rawPaths: orderedPaths,
            mode: "full",
            rootScope: rootScope
        )
        let resolvedFiles = await store.lookupFiles(atPaths: orderedPaths, rootScope: rootScope)
        let autoSelectedPaths = orderedPaths.filter { rawPath in
            guard let file = resolvedFiles[rawPath] else { return false }
            let fullPath = file.standardizedFullPath
            return !previouslySelected.contains(fullPath)
                && mutation.selection.selectedPaths.contains(fullPath)
        }
        return (mutation.selection, autoSelectedPaths)
    }
}

extension MCPServerViewModel {
    /// Result of building a stored selection
    struct BuildStoredSelectionResult {
        let selection: StoredSelection
        let invalidPaths: [String]
        let codemapUnavailable: [String]
    }

    @MainActor
    private func mcpSelectionMutationService() -> WorkspaceSelectionMutationService {
        WorkspaceSelectionMutationService(
            store: promptVM.workspaceFileContextStore,
            codemapsGloballyDisabled: codeMapsGloballyDisabledForMCP,
            codemapsGloballyDisabledMessage: Self.codeMapsGloballyDisabledMCPMessage
        )
    }

    @MainActor
    func buildStoredSelection(
        from inputs: ManageSelectionInputs,
        mode: String,
        existing: StoredSelection,
        lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> BuildStoredSelectionResult {
        let service = mcpSelectionMutationService()
        let result = await service.buildSelection(
            paths: inputs.paths,
            slices: inputs.sliceInputs.map(\.self),
            sliceErrors: inputs.sliceErrors,
            mode: mode,
            existing: existing,
            rootScope: lookupRootScope
        )
        return BuildStoredSelectionResult(
            selection: result.selection,
            invalidPaths: result.invalidPaths,
            codemapUnavailable: result.codemapUnavailable
        )
    }

    @MainActor
    func buildManageSelectionSetSelection(
        from inputs: ManageSelectionInputs,
        mode: String,
        existing: StoredSelection,
        lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> BuildStoredSelectionResult {
        let result = await mcpSelectionMutationService().buildManageSelectionSet(
            paths: inputs.paths,
            slices: inputs.sliceInputs.map(\.self),
            sliceErrors: inputs.sliceErrors,
            mode: mode,
            existing: existing,
            rootScope: lookupRootScope
        )
        return BuildStoredSelectionResult(
            selection: result.selection,
            invalidPaths: result.invalidPaths,
            codemapUnavailable: result.codemapUnavailable
        )
    }

    @MainActor
    func mutateStoredSelectionSlices(
        base: StoredSelection,
        entries: [WorkspaceSelectionSliceInput],
        mode: SliceMutationMode,
        lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> (selection: StoredSelection, result: MCPSelectionSlicesMutationResult, mutated: Bool) {
        let mutation = await mcpSelectionMutationService().mutateSlices(
            base: base,
            entries: entries,
            mode: mode,
            rootScope: lookupRootScope
        )
        var snapshot: [UUID: [LineRange]] = [:]
        for (full, ranges) in mutation.selection.slices where !ranges.isEmpty {
            if let file = await promptVM.workspaceFileContextStore.lookupFiles(atPaths: [full], rootScope: lookupRootScope)[full] {
                snapshot[file.id] = ranges
            }
        }
        return (
            mutation.selection,
            MCPSelectionSlicesMutationResult(invalidPaths: mutation.invalidPaths, resolvedMap: mutation.resolvedMap, snapshot: snapshot),
            mutation.mutated
        )
    }

    @MainActor
    func buildPreviewSelectionReply(
        paths: [String],
        sliceInputs: [WorkspaceSelectionSliceInput],
        includeBlocks: Bool,
        display: FilePathDisplay,
        mode: String,
        lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> ToolResultDTOs.SelectionReply {
        var invalidPaths: [String] = []
        let selection: StoredSelection

        if mode == "codemap_only", codeMapsGloballyDisabledForMCP {
            invalidPaths.append(Self.codeMapsGloballyDisabledMCPMessage)
            selection = StoredSelection()
        } else if mode == "codemap_only" {
            let buildResult = await buildStoredSelection(
                from: ManageSelectionInputs(
                    paths: paths,
                    sliceInputs: [],
                    sliceErrors: [],
                    hadExplicitSliceSpec: false
                ),
                mode: mode,
                existing: StoredSelection(),
                lookupRootScope: lookupRootScope
            )
            invalidPaths.append(contentsOf: buildResult.invalidPaths)
            // Include codemapUnavailable messages in invalidPaths for preview display
            invalidPaths.append(contentsOf: buildResult.codemapUnavailable)
            selection = buildResult.selection
        } else {
            let inputs = ManageSelectionInputs(
                paths: paths,
                sliceInputs: sliceInputs,
                sliceErrors: [],
                hadExplicitSliceSpec: !sliceInputs.isEmpty
            )
            let buildResult = await buildStoredSelection(
                from: inputs,
                mode: mode,
                existing: StoredSelection(),
                lookupRootScope: lookupRootScope
            )
            selection = buildResult.selection
            invalidPaths.append(contentsOf: buildResult.invalidPaths)
        }

        let source = StoredSelectionSource(
            stored: selection,
            codeMapUsage: effectiveMCPCodeMapUsage(promptVM.codeMapUsage)
        )
        let collections = await SelectionReplyAssembler.collect(
            from: source,
            owner: self,
            contentPolicy: includeBlocks ? .loadContent : .cachedOnly
        )
        let formatter = PathFormatter(format: display, owner: self)
        let tokens = TokenServices(owner: self)
        var out = await SelectionReplyAssembler.buildSelectionReply(
            collections: collections,
            includeBlocks: includeBlocks,
            display: display,
            formatter: formatter,
            tokens: tokens,
            status: "preview",
            extraInvalid: invalidPaths
        )

        // Inject minimal codeStructure.unmappedPaths to report pending codemaps
        if out.codeStructure == nil {
            if let minimal = await buildUnmappedOnlyCodeStructure(collections: collections, display: display) {
                out = ToolResultDTOs.SelectionReply(
                    files: out.files,
                    totalTokens: out.totalTokens,
                    status: out.status,
                    invalidPaths: out.invalidPaths,
                    blocks: out.blocks,
                    codeStructure: minimal,
                    fileSlices: out.fileSlices,
                    codemapAutoEnabled: out.codemapAutoEnabled,
                    summary: out.summary,
                    codeMapUsage: out.codeMapUsage,
                    // Preserve user preset state indicators
                    userCopyCodeMapUsage: out.userCopyCodeMapUsage,
                    userChatCodeMapUsage: out.userChatCodeMapUsage,
                    userCopyTokens: out.userCopyTokens,
                    userChatTokens: out.userChatTokens,
                    normalizedCodeMapUsage: out.normalizedCodeMapUsage,
                    tokenStats: out.tokenStats,
                    tokenAccounting: out.tokenAccounting
                )
            }
        }

        return out
    }

    /// Result of adding paths to stored selection
    struct AddStoredSelectionResult {
        let selection: StoredSelection
        let invalidPaths: [String]
        let resolvedMap: [String: String]
        let mutated: Bool
        let codemapUnavailable: [String]
    }

    @MainActor
    func addPrimaryGitDiffArtifactsToSelection(
        existing: StoredSelection,
        paths: [String],
        lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspacePlusGitData
    ) async -> (selection: StoredSelection, autoSelectedPaths: [String]) {
        await WorkspaceGitDiffArtifactSelectionService(
            store: promptVM.workspaceFileContextStore
        ).addPrimaryArtifacts(
            existing: existing,
            paths: paths,
            rootScope: lookupRootScope
        )
    }

    @MainActor
    func addStoredSelectionPaths(
        existing: StoredSelection,
        paths: [String],
        rawPaths: [String],
        mode: String,
        lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> AddStoredSelectionResult {
        let result = await mcpSelectionMutationService().addPaths(
            existing: existing,
            paths: paths,
            rawPaths: rawPaths,
            mode: mode,
            rootScope: lookupRootScope
        )
        return AddStoredSelectionResult(
            selection: result.selection,
            invalidPaths: result.invalidPaths,
            resolvedMap: result.resolvedMap,
            mutated: result.mutated,
            codemapUnavailable: result.codemapUnavailable
        )
    }

    @MainActor
    func removeStoredSelectionPaths(
        existing: StoredSelection,
        paths: [String],
        rawPaths: [String],
        mode: String = "full",
        lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> (StoredSelection, [String], [String: String], Bool) {
        let result = await mcpSelectionMutationService().removePaths(
            existing: existing,
            paths: paths,
            rawPaths: rawPaths,
            mode: mode,
            rootScope: lookupRootScope
        )
        return (result.selection, result.invalidPaths, result.resolvedMap, result.mutated)
    }

    @MainActor
    func promoteStoredSelectionPaths(
        existing: StoredSelection,
        paths: [String],
        rawPaths: [String],
        strict _: Bool,
        lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> (StoredSelection, [String], Bool) {
        let result = await mcpSelectionMutationService().promotePaths(
            existing: existing,
            paths: paths,
            rawPaths: rawPaths,
            rootScope: lookupRootScope
        )
        return (result.selection, result.invalidPaths, result.mutated)
    }

    /// Result of demoting paths to codemap mode
    struct DemoteStoredSelectionResult {
        let selection: StoredSelection
        let invalidPaths: [String]
        let codemapUnavailable: [String]
        let mutated: Bool
    }

    @MainActor
    func demoteStoredSelectionPaths(
        existing: StoredSelection,
        paths: [String],
        rawPaths: [String],
        strict _: Bool,
        lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> DemoteStoredSelectionResult {
        let result = await mcpSelectionMutationService().demotePaths(
            existing: existing,
            paths: paths,
            rawPaths: rawPaths,
            rootScope: lookupRootScope
        )
        return DemoteStoredSelectionResult(
            selection: result.selection,
            invalidPaths: result.invalidPaths,
            codemapUnavailable: result.codemapUnavailable,
            mutated: result.mutated
        )
    }
}
