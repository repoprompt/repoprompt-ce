import Foundation

extension MCPServerViewModel {
    @MainActor
    func buildTabWorkspaceContext(
        context: TabScopedContext,
        include: Set<String>,
        display: FilePathDisplay,
        copyPresetOverride: CopyPreset? = nil,
        activeTabCompatibility: Bool = false
    ) async throws -> ToolResultDTOs.PromptContextDTO {
        let includeSelection = include.contains("selection")
        let requireSelectionData = includeSelection
            || include.contains("files")
            || include.contains("code")
            || include.contains("tokens")

        var collections: SelectionReplyAssembler.SelectionCollections? = nil
        var selectionReply: ToolResultDTOs.SelectedFilesReply? = nil
        let lookupContext = await lookupContext(for: context)
        let effectiveSelection = lookupContext.physicalizeSelection(context.selection)
        let emitsFilesystemIdentity = includeSelection
            || include.contains("files")
            || include.contains("code")
            || include.contains("tree")
        let worktreeScope = emitsFilesystemIdentity
            ? ToolResultDTOs.WorktreeScopeDTO.sessionBound(from: lookupContext.bindingProjection)
            : nil

        // Get active and effective presets + resolved config
        let activePreset = promptVM.currentCopyPreset()
        let effectivePreset = copyPresetOverride ?? activePreset
        var resolvedCfg = promptVM.resolvePromptContext(effectivePreset, custom: promptVM.workingCopyCustomizations)
        if promptVM.codeMapsGloballyDisabled {
            resolvedCfg.codeMapUsage = .none
        }
        let projectionConfig = projectionConfig(from: resolvedCfg)

        // Get effective copy usage from resolved config
        let copyUsage = effectiveMCPCodeMapUsage(resolvedCfg.codeMapUsage)

        // Include user preset state when copy mode differs from auto or a global override is active
        let userPresetState = (copyUsage != .auto || promptVM.codeMapsGloballyDisabled) ? buildUserPresetState() : nil

        if requireSelectionData {
            // Always use .auto mode for normalized view
            let source = StoredSelectionSource(
                stored: effectiveSelection,
                codeMapUsage: effectiveMCPCodeMapUsage(.auto)
            )
            let formatter = PathFormatter(format: .relative, owner: self, projection: lookupContext.bindingProjection)
            let tokens = TokenServices(owner: self)
            let gathered = await SelectionReplyAssembler.collect(from: source, owner: self, rootScope: lookupContext.rootScope)
            let evaluation = await evaluateVirtualPromptEntries(
                for: effectiveSelection,
                codeMapUsage: gathered.codeMapUsage,
                rootScope: lookupContext.rootScope
            )
            let reply = await SelectionReplyAssembler.buildSelectedFilesReply(
                collections: gathered,
                formatter: formatter,
                tokens: tokens,
                userPresetState: userPresetState,
                copyUsage: copyUsage != .auto ? copyUsage : nil,
                projection: projectionConfig,
                entryResultsByFileID: evaluation.entryResultsByFileID
            )
            collections = gathered
            selectionReply = reply
        }

        let selectionDTO = includeSelection ? selectionReply : nil

        var fileBlocks: [String]? = nil
        if include.contains("files") {
            if let coll = collections {
                fileBlocks = await SelectionReplyAssembler.generateBlocks(
                    selected: coll.selected,
                    display: display,
                    projection: lookupContext.bindingProjection
                )
            } else {
                fileBlocks = []
            }
        }

        var codeStructDTO: ToolResultDTOs.SelectedCodeStructureDTO? = nil
        if include.contains("code"), !promptVM.codeMapsGloballyDisabled, let coll = collections {
            let builder = CodeStructureBuilder(owner: self, lookupContext: lookupContext)
            let combined = coll.selected.map(\.file) + coll.codemap.map(\.file)
            codeStructDTO = try await builder.build(for: combined)
        }

        var fileTreeDTO: ToolResultDTOs.FileTreeDTO? = nil
        var fileTreeTokens = 0
        if include.contains("tree") {
            let treeSelection = activeTabCompatibility
                ? storedSelection(for: context, includeCodemapPathsWhenSelectedUsage: true)
                : effectiveSelection
            let rawTreeSnapshot = await promptVM.workspaceFileContextStore.makeFileTreeSelectionSnapshot(
                selection: treeSelection,
                request: WorkspaceFileTreeSnapshotRequest(
                    mode: .selected,
                    filePathDisplay: promptVM.filePathDisplayOption,
                    onlyIncludeRootsWithSelectedFiles: false,
                    includeLegend: true,
                    showCodeMapMarkers: !promptVM.codeMapsGloballyDisabled,
                    rootScope: lookupContext.rootScope
                ),
                profile: .uiAssisted
            )
            let treeSnapshot = lookupContext.bindingProjection?.logicalizeFileTreeSnapshot(rawTreeSnapshot) ?? rawTreeSnapshot
            if treeSnapshot.roots.isEmpty {
                let msg = activeTabCompatibility
                    ? await workspaceContextMessage(forOperation: MCPWindowToolName.getFileTree, path: nil)
                    : await tabWorkspaceContextMessage(forOperation: tabFileTreeToolName, path: nil)
                fileTreeDTO = .init(
                    rootsCount: 0,
                    usesLegend: false,
                    tree: msg,
                    note: activeTabCompatibility ? "No workspace loaded" : nil,
                    worktreeScope: worktreeScope
                )
                fileTreeTokens = TokenCalculationService.estimateTokens(for: msg)
            } else {
                let tree = await Task.detached(priority: .userInitiated) {
                    CodeMapExtractor.generateFileTree(using: treeSnapshot)
                }.value
                fileTreeDTO = .init(
                    rootsCount: treeSnapshot.roots.count,
                    usesLegend: true,
                    tree: tree,
                    note: nil,
                    worktreeScope: worktreeScope
                )
                fileTreeTokens = TokenCalculationService.estimateTokens(for: tree)
            }
        }

        var tokenStatsDTO: ToolResultDTOs.TokenStats? = nil
        var userTokenStatsDTO: ToolResultDTOs.TokenStats? = nil
        var tokenStatsNote: String? = nil
        if include.contains("tokens") {
            let fileTokens = selectionReply?.totalTokens ?? 0
            let filesContentTokens = (selectionReply?.summary?.fullTokens ?? 0) + (selectionReply?.summary?.sliceTokens ?? 0)
            let codemapsTokens = selectionReply?.summary?.codemapTokens ?? 0

            if activeTabCompatibility {
                await promptVM.tokenCountingViewModel.forceImmediateRecount()
                let breakdown = latestTokenBreakdown()
                let promptTokens = breakdown.prompt
                var treeTokens = breakdown.fileTree
                if treeTokens == 0 && fileTreeTokens > 0 {
                    treeTokens = fileTreeTokens
                }
                let metaTokens = breakdown.meta
                let gitTokens = breakdown.git
                var totalTokens = breakdown.total
                let componentSum = promptTokens + fileTokens + treeTokens + metaTokens + gitTokens
                if totalTokens == 0 || totalTokens < componentSum {
                    totalTokens = componentSum
                }
                let otherTokens = max(totalTokens - componentSum, 0)
                tokenStatsDTO = .init(
                    total: totalTokens,
                    files: fileTokens,
                    prompt: promptTokens,
                    fileTree: treeTokens,
                    meta: metaTokens,
                    git: gitTokens,
                    other: otherTokens,
                    filesContent: filesContentTokens > 0 ? filesContentTokens : nil,
                    codemaps: codemapsTokens > 0 ? codemapsTokens : nil
                )

                if let userFileTokens = selectionReply?.userCopyTokens, userFileTokens != fileTokens {
                    let userContentTokens = selectionReply?.userCopyContentTokens ?? 0
                    let userCodemapTokens = selectionReply?.userCopyCodemapTokens ?? 0
                    let userComponentSum = promptTokens + userFileTokens + treeTokens + metaTokens + gitTokens
                    let userTotalTokens = max(userComponentSum, totalTokens - fileTokens + userFileTokens)
                    let userOtherTokens = max(userTotalTokens - userComponentSum, 0)
                    userTokenStatsDTO = .init(
                        total: userTotalTokens,
                        files: userFileTokens,
                        prompt: promptTokens,
                        fileTree: treeTokens,
                        meta: metaTokens,
                        git: gitTokens,
                        other: userOtherTokens,
                        filesContent: userContentTokens > 0 ? userContentTokens : nil,
                        codemaps: userCodemapTokens > 0 ? userCodemapTokens : nil
                    )
                    let codemapDelta = fileTokens - userFileTokens
                    tokenStatsNote = "Difference: \(codemapDelta) codemap tokens (API signatures). Your preset excludes these, so exports use \(userFileTokens) file tokens, not \(fileTokens)."
                }
            } else {
                let selectedFiles = collections?.selected.map(\.file) ?? []
                let codemapFiles = collections?.codemap.map(\.file) ?? []
                let breakdown = await buildVirtualTokenBreakdown(
                    for: context,
                    resolvedContext: resolvedCfg,
                    selectedFiles: selectedFiles,
                    codemapFiles: codemapFiles,
                    lookupContext: lookupContext
                )
                tokenStatsDTO = Self.makeTokenStats(
                    filesTokens: fileTokens,
                    filesContentTokens: filesContentTokens > 0 ? filesContentTokens : nil,
                    codemapsTokens: codemapsTokens > 0 ? codemapsTokens : nil,
                    breakdown: breakdown
                )

                if let userFileTokens = selectionReply?.userCopyTokens, userFileTokens != fileTokens {
                    let userContentTokens = selectionReply?.userCopyContentTokens ?? 0
                    let userCodemapTokens = selectionReply?.userCopyCodemapTokens ?? 0
                    userTokenStatsDTO = Self.makeTokenStats(
                        filesTokens: userFileTokens,
                        filesContentTokens: userContentTokens > 0 ? userContentTokens : nil,
                        codemapsTokens: userCodemapTokens > 0 ? userCodemapTokens : nil,
                        breakdown: breakdown
                    )
                    let codemapDelta = fileTokens - userFileTokens
                    tokenStatsNote = "Difference: \(codemapDelta) codemap tokens (API signatures). Your preset excludes these, so exports use \(userFileTokens) file tokens, not \(fileTokens)."
                }
            }
        }

        let prompt = include.contains("prompt") ? context.promptText : ""

        // Build copy preset context DTO (shows active vs effective if overridden)
        let copyPresetContextDTO = buildCopyPresetContextDTO(active: activePreset, effective: effectivePreset)

        return ToolResultDTOs.PromptContextDTO(
            prompt: prompt,
            selection: selectionDTO,
            fileBlocks: fileBlocks,
            codeStructure: codeStructDTO,
            fileTree: fileTreeDTO,
            tokenStats: tokenStatsDTO,
            userTokenStats: userTokenStatsDTO,
            tokenStatsNote: tokenStatsNote,
            copyPreset: copyPresetContextDTO,
            copyPresets: nil,
            worktreeScope: worktreeScope
        )
    }

    @MainActor
    private func resolvedContextForExportSelectedFiles(
        _ resolvedContext: ResolvedTabContextSnapshot?
    ) async throws -> ResolvedTabContextSnapshot? {
        if let resolvedContext { return resolvedContext }
        let metadata = await captureRequestMetadata()
        return try resolveTabContextSnapshot(
            from: metadata,
            toolName: "export_selected_files",
            policy: .allowLegacyImplicitRouting
        )
    }

    @MainActor
    func buildExportSelectedFileInfos(
        resolvedContext: ResolvedTabContextSnapshot? = nil,
        cfg: PromptContextResolved,
        selectionOverride: StoredSelection? = nil,
        display: FilePathDisplay
    ) async throws -> [ToolResultDTOs.SelectedFileInfo] {
        guard cfg.includeFiles else { return [] }
        let tokens = TokenServices(owner: self)
        let effectiveCodeMapUsage = effectiveMCPCodeMapUsage(cfg.codeMapUsage)
        let resolved = try await resolvedContextForExportSelectedFiles(resolvedContext)

        let lookupContext = if let snapshot = resolved?.snapshot {
            await lookupContext(for: snapshot)
        } else {
            WorkspaceLookupContext.visibleWorkspace
        }
        let formatter = PathFormatter(format: display, owner: self, projection: lookupContext.bindingProjection)
        let selectionForCollections = selectionOverride ?? resolved?.snapshot.selection
        let collections: SelectionReplyAssembler.SelectionCollections
        if let selectionForCollections {
            let source = StoredSelectionSource(
                stored: lookupContext.physicalizeSelection(selectionForCollections),
                codeMapUsage: effectiveCodeMapUsage
            )
            collections = await SelectionReplyAssembler.collect(from: source, owner: self, rootScope: lookupContext.rootScope)
        } else {
            collections = SelectionReplyAssembler.SelectionCollections.empty(codeMapUsage: effectiveCodeMapUsage)
        }

        let evaluationSelection: StoredSelection? = if let selectionOverride {
            lookupContext.physicalizeSelection(selectionOverride)
        } else if let resolved, !resolved.usesActiveTabCompatibility {
            lookupContext.physicalizeSelection(resolved.snapshot.selection)
        } else {
            nil
        }
        let entryResultsByFileID: [UUID: PromptEntriesEvaluation.EntryResult]? = if let evaluationSelection {
            await evaluateVirtualPromptEntries(
                for: evaluationSelection,
                codeMapUsage: collections.codeMapUsage,
                rootScope: lookupContext.rootScope
            ).entryResultsByFileID
        } else {
            nil
        }
        let reply = await SelectionReplyAssembler.buildSelectedFilesReply(
            collections: collections,
            formatter: formatter,
            tokens: tokens,
            entryResultsByFileID: entryResultsByFileID
        )
        return reply.files
    }

    @MainActor
    func buildTabClipboardContent(
        cfg: PromptContextResolved,
        context: TabScopedContext
    ) async -> String {
        // Use the resolved tab-scoped context directly.
        // Run-bound sessions and explicitly bound tabs should export from their bound tab
        // state, not from whichever compose tab happens to be active in the UI.
        let lookupContext = await lookupContext(for: context)
        let effectivePromptText = context.promptText
        let store = promptVM.workspaceFileContextStore
        var effectiveCfg = cfg
        effectiveCfg.codeMapUsage = effectiveMCPCodeMapUsage(cfg.codeMapUsage)
        let preAssembly = await PromptContextPreAssemblyService.resolve(
            PromptContextPreAssemblyRequest(
                cfg: effectiveCfg,
                selection: context.selection,
                store: store,
                lookupContext: lookupContext,
                filePathDisplay: promptVM.filePathDisplayOption,
                onlyIncludeRootsWithSelectedFiles: promptVM.onlyIncludeRootsWithSelectedFiles,
                showCodeMapMarkers: !promptVM.codeMapsGloballyDisabled,
                selectedGitDiffFolderPolicy: .filesOnly,
                selectedGitDiffLookupProfile: .mcpSelection,
                selectedGitDiffArtifactPolicy: .respectGitInclusion,
                selectedGitDiffProvider: { [gitViewModel = promptVM.gitViewModel] paths in
                    await gitViewModel.getDiffForAbsolutePaths(paths, forceRefreshStatus: true)
                },
                completeGitDiffProvider: { [gitViewModel = promptVM.gitViewModel] in
                    await gitViewModel.getDiffUsing(inclusionMode: .all, forceRefreshStatus: true)
                }
            )
        )

        let combinedMeta = promptVM.metaInstructions(
            for: cfg,
            selectedPromptIDsOverride: context.selectedMetaPromptIDs
        )
        let includeMetaBlock = !combinedMeta.isEmpty

        return await PromptPackagingService.generateClipboardContent(
            metaInstructions: combinedMeta,
            userInstructions: cfg.includeUserPrompt ? effectivePromptText : "",
            files: preAssembly.entries,
            fileTreeContent: preAssembly.fileTreeContent,
            gitDiff: preAssembly.gitDiff,
            includeSavedPrompts: includeMetaBlock,
            includeFiles: cfg.includeFiles,
            includeUserPrompt: cfg.includeUserPrompt,
            filePathDisplay: promptVM.filePathDisplayOption,
            codemapSnapshots: preAssembly.codemapSnapshots,
            includeDatetimeInUserInstructions: promptVM.includeDatetimeInUserInstructions,
            promptSectionsOrder: promptVM.promptSectionsOrder,
            disabledPromptSections: promptVM.disabledPromptSections,
            duplicateUserInstructionsAtTop: promptVM.duplicateUserInstructionsAtTop,
            displayPathResolver: { entry in
                preAssembly.displayPath(for: entry)
            }
        )
    }
}

extension MCPServerViewModel {
    @MainActor
    func latestTokenBreakdown() -> TokenCountingViewModel.TokenBreakdown {
        promptVM.tokenCountingViewModel.latestTokenBreakdown()
    }
}
