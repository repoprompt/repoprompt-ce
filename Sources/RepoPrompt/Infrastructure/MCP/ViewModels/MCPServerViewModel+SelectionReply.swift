import Foundation

extension MCPServerViewModel {
    @MainActor
    func stabilizedVirtualSelection(for context: TabScopedContext) async -> StoredSelection {
        // For any tab-bound virtual context (including runs), prefer latest stored tab selection.
        // This prevents resurrecting stale slices from the run snapshot after the user clears them.
        if let manager = workspaceManager,
           let liveTab = manager.composeTab(with: context.tabID)
        {
            return liveTab.selection
        }

        return context.selection
    }

    struct TabSelectionData {
        struct SelectedEntry {
            let file: WorkspaceFileRecord
            let ranges: [LineRange]?
        }

        var selected: [SelectedEntry] = []
        var codemap: [WorkspaceFileRecord] = []
        var invalidInputs: [String] = []
    }

    /// Builds the UserPresetState for virtual contexts, capturing the user's actual preset settings.
    /// This allows the builder to know what the user sees (different codemap mode) while working with normalized auto view.
    @MainActor
    func buildUserPresetState() -> SelectionReplyAssembler.UserPresetState {
        // Use the current copy/chat codemap usage settings from PromptViewModel
        let copyUsage = promptVM.codeMapUsage
        let chatUsage = promptVM.codeMapUsageForChat
        return SelectionReplyAssembler.UserPresetState(
            copyCodeMapUsage: copyUsage.rawValue,
            chatCodeMapUsage: chatUsage.rawValue,
            copyTokens: nil, // Can be computed lazily if needed
            chatTokens: nil, // Can be computed lazily if needed
            normalizedCodeMapUsage: effectiveMCPCodeMapUsage(.auto).rawValue
        )
    }

    @MainActor
    func tabSelectionCollections(
        from selection: StoredSelection,
        codeMapUsageOverride: CodeMapUsage? = nil
    ) async -> SelectionReplyAssembler.SelectionCollections {
        let requestedUsage = codeMapUsageOverride ?? promptVM.codeMapUsage
        let source = StoredSelectionSource(
            stored: selection,
            codeMapUsage: effectiveMCPCodeMapUsage(requestedUsage)
        )
        return await SelectionReplyAssembler.collect(from: source, owner: self)
    }

    @MainActor
    private func makeTabSelectionData(
        from collections: SelectionReplyAssembler.SelectionCollections
    ) -> TabSelectionData {
        var data = TabSelectionData()
        data.selected = collections.selected.map { .init(file: $0.file, ranges: $0.ranges) }
        data.codemap = collections.codemap.map(\.file)
        data.invalidInputs = collections.invalid
        return data
    }

    @MainActor
    func evaluateVirtualPromptEntries(
        for selection: StoredSelection,
        codeMapUsage: CodeMapUsage,
        rootScope: WorkspaceLookupRootScope = .allLoaded
    ) async -> PromptEntriesEvaluation {
        let store = promptVM.workspaceFileContextStore
        let accountingService = PromptContextAccountingService()
        let request = PromptContextAccountingRequest(
            selection: selection,
            codeMapUsage: codeMapUsage,
            filePathDisplay: promptVM.filePathDisplayOption,
            rootScope: rootScope,
            pathLocateProfile: .uiAssisted
        )
        let accounting = await accountingService.calculatePromptStats(request: request, store: store)
        let service = TokenCalculationService()
        return await service.evaluatePromptEntries(accounting.promptFileEntrySnapshots)
    }

    @MainActor
    private func virtualSelectionFileTreeText(
        selection: StoredSelection,
        resolvedContext: PromptContextResolved
    ) async -> String {
        guard resolvedContext.rendersFileTree else { return "" }
        let store = promptVM.workspaceFileContextStore
        let snapshot = await store.makeFileTreeSelectionSnapshot(
            selection: selection,
            request: WorkspaceFileTreeSnapshotRequest(
                mode: WorkspaceFileTreeSnapshotMode(fileTreeOption: resolvedContext.effectiveFileTreeMode),
                filePathDisplay: promptVM.filePathDisplayOption,
                onlyIncludeRootsWithSelectedFiles: promptVM.onlyIncludeRootsWithSelectedFiles,
                includeLegend: true,
                showCodeMapMarkers: !promptVM.codeMapsGloballyDisabled,
                rootScope: .allLoaded
            ),
            profile: .uiAssisted
        )
        return await Task.detached(priority: .userInitiated) {
            CodeMapExtractor.generateFileTree(using: snapshot)
        }.value
    }

    @MainActor
    private func virtualSelectionGitDiffText(
        for selection: StoredSelection,
        resolvedContext: PromptContextResolved
    ) async -> String? {
        switch resolvedContext.gitInclusion {
        case .none:
            return nil
        case .selected:
            let selectedPaths = await WorkspaceGitDiffSelectionResolver.selectedGitDiffPaths(
                for: selection,
                store: promptVM.workspaceFileContextStore,
                rootScope: .allLoaded,
                folderPolicy: .filesOnly,
                profile: .mcpSelection,
                allowFilesystemFallback: WorkspaceLookupRootScope.allLoaded.allowsSelectedGitDiffFilesystemFallback
            )
            return await promptVM.gitViewModel.getDiffForAbsolutePaths(selectedPaths, forceRefreshStatus: true)
        case .complete:
            return await promptVM.gitViewModel.getDiffUsing(inclusionMode: .all, forceRefreshStatus: true)
        }
    }

    @MainActor
    func buildVirtualTokenBreakdown(
        for context: TabScopedContext,
        resolvedContext: PromptContextResolved,
        selectedFiles: [WorkspaceFileRecord],
        codemapFiles: [WorkspaceFileRecord]
    ) async -> TokenComponentBreakdown {
        let selectedInstructionsText = promptVM.metaInstructions(
            for: resolvedContext,
            selectedPromptIDsOverride: context.selectedMetaPromptIDs
        )
        .map(\.content)
        .joined(separator: "\n\n")
        let isActiveWorkspaceBound = context.workspaceID == nil || context.workspaceID == workspaceManager?.activeWorkspace?.id
        let fileTreeText = isActiveWorkspaceBound
            ? await virtualSelectionFileTreeText(selection: context.selection, resolvedContext: resolvedContext)
            : ""
        let gitDiffText = isActiveWorkspaceBound
            ? await virtualSelectionGitDiffText(for: context.selection, resolvedContext: resolvedContext)
            : nil
        let promptText = resolvedContext.includeUserPrompt ? context.promptText : ""
        let duplicateUserPrompt = resolvedContext.includeUserPrompt ? promptVM.duplicateUserInstructionsAtTop : false
        return TokenCalculationService.calculateComponentBreakdown(
            promptText: promptText,
            selectedInstructionsText: selectedInstructionsText,
            fileTreeText: fileTreeText,
            gitDiffText: gitDiffText,
            metadataText: nil,
            duplicateUserInstructionsAtTop: duplicateUserPrompt
        )
    }

    @MainActor
    func buildVirtualSelectionTokenStats(
        for context: TabScopedContext,
        filesReply: ToolResultDTOs.SelectedFilesReply,
        resolvedContext: PromptContextResolved,
        selectedFiles: [WorkspaceFileRecord],
        codemapFiles: [WorkspaceFileRecord]
    ) async -> ToolResultDTOs.TokenStats {
        let filesContentTokens = (filesReply.summary?.fullTokens ?? 0) + (filesReply.summary?.sliceTokens ?? 0)
        let codemapsTokens = filesReply.summary?.codemapTokens ?? 0
        let breakdown = await buildVirtualTokenBreakdown(
            for: context,
            resolvedContext: resolvedContext,
            selectedFiles: selectedFiles,
            codemapFiles: codemapFiles
        )
        return Self.makeTokenStats(
            filesTokens: filesReply.totalTokens,
            filesContentTokens: filesContentTokens > 0 ? filesContentTokens : nil,
            codemapsTokens: codemapsTokens > 0 ? codemapsTokens : nil,
            breakdown: breakdown
        )
    }

    @MainActor
    func buildTabSelectedFilesReply(
        from selection: StoredSelection,
        codeMapUsageOverride: CodeMapUsage? = nil,
        display: FilePathDisplay = .relative
    ) async -> (ToolResultDTOs.SelectedFilesReply, TabSelectionData) {
        let collections = await tabSelectionCollections(from: selection, codeMapUsageOverride: codeMapUsageOverride)
        let evaluation = await evaluateVirtualPromptEntries(
            for: selection,
            codeMapUsage: collections.codeMapUsage
        )
        let formatter = PathFormatter(format: display, owner: self)
        let tokens = TokenServices(owner: self)
        // Include user preset state when using codemap override (normalized view)
        let userPresetState = codeMapUsageOverride != nil ? buildUserPresetState() : nil
        let reply = await SelectionReplyAssembler.buildSelectedFilesReply(
            collections: collections,
            formatter: formatter,
            tokens: tokens,
            userPresetState: userPresetState,
            entryResultsByFileID: evaluation.entryResultsByFileID
        )
        let data = makeTabSelectionData(from: collections)
        return (reply, data)
    }

    @MainActor
    func buildSelectionPreviewReply(
        selection: StoredSelection,
        includeBlocks: Bool,
        display: FilePathDisplay,
        extraInvalid: [String],
        viewMode: String?,
        codeMapUsageOverride: CodeMapUsage?,
        lookupContext: WorkspaceLookupContext = .visibleWorkspace
    ) async -> ToolResultDTOs.SelectionReply {
        let source = StoredSelectionSource(
            stored: lookupContext.physicalizeSelection(selection),
            codeMapUsage: effectiveMCPCodeMapUsage(codeMapUsageOverride ?? promptVM.codeMapUsage)
        )
        let collections = await SelectionReplyAssembler.collect(from: source, owner: self, rootScope: lookupContext.rootScope)
        let formatter = PathFormatter(format: display, owner: self, projection: lookupContext.bindingProjection)
        let tokens = TokenServices(owner: self)
        var reply = await SelectionReplyAssembler.buildSelectionReply(
            collections: collections,
            includeBlocks: includeBlocks,
            display: display,
            formatter: formatter,
            tokens: tokens,
            status: "preview",
            extraInvalid: extraInvalid
        )
        if let viewMode, viewMode == "codemaps" {
            reply = SelectionReplyAssembler.applyViewFilter(reply, view: viewMode)
        }
        return reply
    }

    @MainActor
    func buildTabSelectionReply(
        from selection: StoredSelection,
        includeBlocks: Bool,
        display: FilePathDisplay,
        extraInvalid: [String] = [],
        viewMode: String? = nil,
        codeMapUsageOverride: CodeMapUsage? = nil,
        virtualContext: TabScopedContext? = nil,
        lookupContextOverride: WorkspaceLookupContext? = nil
    ) async -> ToolResultDTOs.SelectionReply {
        // Always use .auto mode for manage_selection (normalized view)
        let effectiveOverride = effectiveMCPCodeMapUsage(codeMapUsageOverride ?? .auto)
        let lookupContext = if let virtualContext {
            await lookupContext(for: virtualContext)
        } else if let lookupContextOverride {
            lookupContextOverride
        } else {
            WorkspaceLookupContext.visibleWorkspace
        }
        let effectiveSelection = lookupContext.physicalizeSelection(selection)
        let source = StoredSelectionSource(stored: effectiveSelection, codeMapUsage: effectiveOverride)
        let collections = await SelectionReplyAssembler.collect(from: source, owner: self, rootScope: lookupContext.rootScope)
        let evaluation = await evaluateVirtualPromptEntries(
            for: effectiveSelection,
            codeMapUsage: collections.codeMapUsage,
            rootScope: lookupContext.rootScope
        )
        let formatter = PathFormatter(format: display, owner: self, projection: lookupContext.bindingProjection)
        let tokens = TokenServices(owner: self)

        // Get user's effective copy preset mode
        let copyUsage = promptVM.effectiveCopyCodeMapUsage()

        // Include user preset state when copy mode differs from auto or a global override is active
        let userPresetState = (copyUsage != .auto || promptVM.codeMapsGloballyDisabled) ? buildUserPresetState() : nil

        let filesReply = await SelectionReplyAssembler.buildSelectedFilesReply(
            collections: collections,
            formatter: formatter,
            tokens: tokens,
            userPresetState: userPresetState,
            copyUsage: copyUsage != .auto ? copyUsage : nil,
            entryResultsByFileID: evaluation.entryResultsByFileID
        )

        let tokenStatsOverride: ToolResultDTOs.TokenStats?
        if let virtualContext {
            let selectedFiles = collections.selected.map(\.file)
            let codemapFiles = collections.codemap.map(\.file)
            tokenStatsOverride = await buildVirtualSelectionTokenStats(
                for: virtualContext,
                filesReply: filesReply,
                resolvedContext: promptVM.resolvePromptContext(),
                selectedFiles: selectedFiles,
                codemapFiles: codemapFiles
            )
        } else {
            tokenStatsOverride = nil
        }

        var reply = await SelectionReplyAssembler.makeSelectionReply(
            filesReply: filesReply,
            collections: collections,
            includeBlocks: includeBlocks,
            display: display,
            status: "ok",
            extraInvalid: extraInvalid,
            userPresetState: userPresetState,
            tokens: tokens,
            tokenStatsOverride: tokenStatsOverride
        )

        // Inject minimal codeStructure.unmappedPaths to report pending codemaps
        if reply.codeStructure == nil {
            if let minimal = await buildUnmappedOnlyCodeStructure(collections: collections, display: display, projection: lookupContext.bindingProjection) {
                reply = ToolResultDTOs.SelectionReply(
                    files: reply.files,
                    totalTokens: reply.totalTokens,
                    status: reply.status,
                    invalidPaths: reply.invalidPaths,
                    blocks: reply.blocks,
                    codeStructure: minimal,
                    fileSlices: reply.fileSlices,
                    codemapAutoEnabled: reply.codemapAutoEnabled,
                    summary: reply.summary,
                    codeMapUsage: reply.codeMapUsage,
                    // Preserve user preset state indicators
                    userCopyCodeMapUsage: reply.userCopyCodeMapUsage,
                    userChatCodeMapUsage: reply.userChatCodeMapUsage,
                    userCopyTokens: reply.userCopyTokens,
                    userChatTokens: reply.userChatTokens,
                    normalizedCodeMapUsage: reply.normalizedCodeMapUsage,
                    tokenStats: reply.tokenStats
                )
            }
        }

        if let v = viewMode, v == "codemaps" {
            reply = SelectionReplyAssembler.applyViewFilter(reply, view: v)
        }
        return reply
    }

    // MARK: - Unified Selection Reply Builder

    /// Unified entry point to build a selection reply from a resolved tab-context snapshot.
    @MainActor
    func buildCurrentSelectionReply(
        includeBlocks: Bool,
        display: FilePathDisplay,
        extraInvalid: [String] = [],
        viewMode: String? = nil,
        resolvedContext: ResolvedTabContextSnapshot
    ) async -> ToolResultDTOs.SelectionReply {
        var context = resolvedContext.snapshot
        if !resolvedContext.usesActiveTabCompatibility {
            context.selection = await stabilizedVirtualSelection(for: context)
        }
        return await buildTabSelectionReply(
            from: context.selection,
            includeBlocks: includeBlocks,
            display: display,
            extraInvalid: extraInvalid,
            viewMode: viewMode,
            codeMapUsageOverride: .auto,
            virtualContext: resolvedContext.usesActiveTabCompatibility ? nil : context
        )
    }

    func selectedFilesWithStats(resolvedContext: ResolvedTabContextSnapshot) async -> ToolResultDTOs.SelectedFilesReply {
        // Get user's effective copy preset mode for projection
        let copyUsage = await MainActor.run { promptVM.effectiveCopyCodeMapUsage() }
        let userPresetState = await MainActor.run { (copyUsage != .auto || promptVM.codeMapsGloballyDisabled) ? buildUserPresetState() : nil }

        let collections = await selectionCollections(for: resolvedContext.snapshot, codeMapUsageOverride: .auto)
        let lookupContext = await lookupContext(for: resolvedContext.snapshot)
        let formatter = PathFormatter(format: .relative, owner: self, projection: lookupContext.bindingProjection)
        let tokens = TokenServices(owner: self)
        return await SelectionReplyAssembler.buildSelectedFilesReply(
            collections: collections,
            formatter: formatter,
            tokens: tokens,
            userPresetState: userPresetState,
            copyUsage: copyUsage != .auto ? copyUsage : nil
        )
    }

    // MARK: - Unmapped Paths Helper

    /// Builds a minimal code structure DTO containing only unmappedPaths
    /// (files without codemaps). Used to report pending codemaps in selection replies
    /// without generating full codemap content.
    @MainActor
    func buildUnmappedOnlyCodeStructure(
        collections: SelectionReplyAssembler.SelectionCollections,
        display: FilePathDisplay,
        projection: WorkspaceRootBindingProjection? = nil
    ) async -> ToolResultDTOs.SelectedCodeStructureDTO? {
        guard !promptVM.codeMapsGloballyDisabled else { return nil }
        // Combine selected + codemap files
        let files = collections.selected.map(\.file) + collections.codemap.map(\.file)
        guard !files.isEmpty else { return nil }

        var unmapped: [String] = []
        var seen = Set<String>()
        for file in files where collections.codemapSnapshots[file.id]?.fileAPI == nil {
            let p: String = if let projection,
                               let projected = projection.projectedLogicalDisplayPath(forPhysicalPath: file.standardizedFullPath, display: display)
            {
                projected
            } else {
                switch display {
                case .full:
                    file.fullPath
                case .relative:
                    await PathFormatter(format: .relative, owner: self).displayPath(for: file)
                }
            }
            if seen.insert(p).inserted {
                unmapped.append(p)
            }
        }

        guard !unmapped.isEmpty else { return nil }

        // Minimal DTO: report unmappedPaths only; keep content empty and counts neutral
        return ToolResultDTOs.SelectedCodeStructureDTO(
            fileCount: 0,
            content: "",
            unmappedPaths: unmapped,
            omittedCount: nil,
            worktreeScope: ToolResultDTOs.WorktreeScopeDTO.sessionBound(from: projection)
        )
    }
}
