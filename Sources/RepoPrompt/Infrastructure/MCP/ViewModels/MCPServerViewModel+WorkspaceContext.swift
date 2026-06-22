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
        var preparedTokenAccounting: MCPPreparedTokenAccounting? = nil
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

        let needsFactualContext = include.contains("files")
            || include.contains("tree")
            || include.contains("tokens")
        var factualContext: PromptContextPreAssemblyResult?
        if needsFactualContext {
            var factualCfg = resolvedCfg
            factualCfg.includeFiles = include.contains("files") || include.contains("tokens")
            factualCfg.codeMapUsage = effectiveMCPCodeMapUsage(.auto)
            if include.contains("tree") {
                factualCfg.includeFileTree = true
                factualCfg.fileTreeMode = .selected
            }
            let reviewGitContext = await promptVM.freezePromptGitReviewContext(
                workspaceID: context.workspaceID,
                tabID: context.tabID,
                sessionID: context.activeAgentSessionID,
                bindings: context.worktreeBindings
            )
            let coordinator = AutomaticReviewGitDiffCoordinator()
            let outcome = await PromptContextPreAssemblyService.resolve(
                PromptContextPreAssemblyRequest(
                    cfg: factualCfg,
                    selection: context.selection,
                    store: promptVM.workspaceFileContextStore,
                    lookupContext: lookupContext,
                    factualProvider: promptVM.promptFactualContextProvider,
                    admissionToken: ServerNetworkManager.currentAdmittedContextBinding?.admissionToken,
                    filePathDisplay: display,
                    onlyIncludeRootsWithSelectedFiles: false,
                    showCodeMapMarkers: !promptVM.codeMapsGloballyDisabled,
                    codeMapUsage: factualCfg.codeMapUsage,
                    selectedGitDiffFolderPolicy: .filesOnly,
                    selectedGitDiffLookupProfile: .mcpSelection,
                    selectedGitDiffArtifactPolicy: .respectGitInclusion,
                    reviewGitContext: reviewGitContext,
                    selectedGitDiffProvider: { request in
                        await coordinator.resolve(request)
                    },
                    completeGitDiffProvider: { [gitViewModel = promptVM.gitViewModel] in
                        await gitViewModel.getDiffUsing(inclusionMode: .all, forceRefreshStatus: false)
                    }
                )
            )
            switch outcome {
            case let .ready(result):
                factualContext = result
            case let .unavailable(failure):
                throw PromptFactualPackagingError.unavailable(failure)
            case .cancelled:
                throw PromptFactualPackagingError.cancelled
            }
        }

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
            let gathered = await SelectionReplyAssembler.collect(
                from: source,
                owner: self,
                rootScope: lookupContext.rootScope,
                contentPolicy: .cachedOnly
            )
            let factualSnapshot = factualContext?.factualSnapshot
            let entryPairs: [(UUID, PromptEntriesEvaluation.EntryResult)] = (factualSnapshot?.entries ?? []).compactMap { entry in
                guard let info = factualSnapshot?.tokenResult.fileTokenInfo[entry.fileID] else { return nil }
                let renderMode: PromptEntriesEvaluation.RenderMode = if entry.isCodemap {
                    .codemap
                } else if info.count != info.fullCount {
                    .slice
                } else {
                    .full
                }
                return (
                    entry.fileID,
                    PromptEntriesEvaluation.EntryResult(
                        fileID: entry.fileID,
                        renderMode: renderMode,
                        displayTokens: info.count,
                        fullTokens: info.fullCount,
                        codemapTokens: info.codemapCount
                    )
                )
            }
            let entryResults = Dictionary(uniqueKeysWithValues: entryPairs)
            let selectedInstructionsText = promptVM.metaInstructions(
                for: resolvedCfg,
                selectedPromptIDsOverride: context.selectedMetaPromptIDs
            )
            .map(\.content)
            .joined(separator: "\n\n")
            let preparedAccounting = MCPPreparedTokenAccounting(
                entryResultsByFileID: entryResults,
                breakdown: TokenCalculationService.calculateComponentBreakdown(
                    promptText: resolvedCfg.includeUserPrompt ? context.promptText : "",
                    selectedInstructionsText: selectedInstructionsText,
                    fileTreeText: factualContext?.fileTreeContent ?? "",
                    gitDiffText: factualContext?.gitDiff,
                    metadataText: nil,
                    duplicateUserInstructionsAtTop: resolvedCfg.includeUserPrompt
                        && promptVM.duplicateUserInstructionsAtTop
                ),
                tokenAccounting: .init(
                    status: factualSnapshot == nil ? "incomplete" : "fresh",
                    source: "construction_selected_factual_provider",
                    refreshPending: factualSnapshot == nil,
                    incompleteComponents: factualSnapshot == nil ? ["factual_context"] : nil
                ),
                activePublishedSnapshot: nil,
                rendered: factualSnapshot?.rendered
            )
            let reply = await SelectionReplyAssembler.buildSelectedFilesReply(
                collections: gathered,
                formatter: formatter,
                tokens: tokens,
                userPresetState: userPresetState,
                copyUsage: nil,
                projection: projectionConfig,
                entryResultsByFileID: preparedAccounting.entryResultsByFileID
            )
            collections = gathered
            selectionReply = reply
            preparedTokenAccounting = preparedAccounting
        }

        let selectionDTO = includeSelection ? selectionReply : nil

        var fileBlocks: [String]? = nil
        if include.contains("files") {
            fileBlocks = factualContext?.rendered.contentBlocks ?? []
        }

        var codeStructDTO: ToolResultDTOs.SelectedCodeStructureDTO? = nil
        if include.contains("code"), !promptVM.codeMapsGloballyDisabled, let coll = collections {
            let builder = CodeStructureBuilder(owner: self, lookupContext: lookupContext)
            let combined = coll.selected.map(\.file) + coll.codemap.map(\.file)
            codeStructDTO = try await builder.build(for: combined)
        }

        var fileTreeDTO: ToolResultDTOs.FileTreeDTO? = nil
        if include.contains("tree") {
            let snapshot = factualContext?.factualSnapshot
            if snapshot?.fileTreeRootCount == 0 {
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
            } else {
                let tree = snapshot?.rendered.fileTreeContent ?? ""
                fileTreeDTO = .init(
                    rootsCount: snapshot?.fileTreeRootCount ?? 0,
                    usesLegend: true,
                    tree: tree,
                    note: nil,
                    worktreeScope: worktreeScope
                )
            }
        }

        var tokenStatsDTO: ToolResultDTOs.TokenStats? = nil
        let userTokenStatsDTO: ToolResultDTOs.TokenStats? = nil
        let tokenStatsNote: String? = nil
        if include.contains("tokens") {
            let factualTokens = factualContext?.factualSnapshot.tokenResult
            let fileTokens = factualTokens?.totalTokenCountFilesOnly ?? 0
            let codemapsTokens = factualTokens?.codeMapTokenCount ?? 0
            let filesContentTokens = max(0, fileTokens - codemapsTokens)

            if let prepared = preparedTokenAccounting {
                if let published = prepared.activePublishedSnapshot {
                    tokenStatsDTO = Self.publishedTokenStats(published)
                } else {
                    tokenStatsDTO = Self.makeTokenStats(
                        filesTokens: fileTokens,
                        filesContentTokens: filesContentTokens > 0 ? filesContentTokens : nil,
                        codemapsTokens: codemapsTokens > 0 ? codemapsTokens : nil,
                        breakdown: prepared.breakdown
                    )
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
            tokenAccounting: preparedTokenAccounting?.tokenAccounting,
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
    ) async throws -> String {
        // Use the resolved tab-scoped context directly.
        // Run-bound sessions and explicitly bound tabs should export from their bound tab
        // state, not from whichever compose tab happens to be active in the UI.
        let lookupContext = await lookupContext(for: context)
        let effectivePromptText = context.promptText
        let store = promptVM.workspaceFileContextStore
        let reviewGitContext = await promptVM.freezePromptGitReviewContext(
            workspaceID: context.workspaceID,
            tabID: context.tabID,
            sessionID: context.activeAgentSessionID,
            bindings: context.worktreeBindings
        )
        let coordinator = AutomaticReviewGitDiffCoordinator()
        var effectiveCfg = cfg
        effectiveCfg.codeMapUsage = effectiveMCPCodeMapUsage(cfg.codeMapUsage)
        let preAssembly = await PromptContextPreAssemblyService.resolve(
            PromptContextPreAssemblyRequest(
                cfg: effectiveCfg,
                selection: context.selection,
                store: store,
                lookupContext: lookupContext,
                factualProvider: promptVM.promptFactualContextProvider,
                admissionToken: ServerNetworkManager.currentAdmittedContextBinding?.admissionToken,
                filePathDisplay: promptVM.filePathDisplayOption,
                onlyIncludeRootsWithSelectedFiles: promptVM.onlyIncludeRootsWithSelectedFiles,
                showCodeMapMarkers: !promptVM.codeMapsGloballyDisabled,
                selectedGitDiffFolderPolicy: .filesOnly,
                selectedGitDiffLookupProfile: .mcpSelection,
                selectedGitDiffArtifactPolicy: .respectGitInclusion,
                reviewGitContext: reviewGitContext,
                selectedGitDiffProvider: { request in
                    await coordinator.resolve(request)
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

        let resolved: PromptContextPreAssemblyResult = switch preAssembly {
        case let .ready(result): result
        case let .unavailable(failure): throw PromptFactualPackagingError.unavailable(failure)
        case .cancelled: throw PromptFactualPackagingError.cancelled
        }
        return PromptPackagingService.generateClipboardContent(
            metaInstructions: combinedMeta,
            userInstructions: cfg.includeUserPrompt ? effectivePromptText : "",
            factualSections: resolved.rendered,
            gitDiff: resolved.gitDiff,
            includeSavedPrompts: includeMetaBlock,
            includeFiles: cfg.includeFiles,
            includeUserPrompt: cfg.includeUserPrompt,
            includeDatetimeInUserInstructions: promptVM.includeDatetimeInUserInstructions,
            promptSectionsOrder: promptVM.promptSectionsOrder,
            disabledPromptSections: promptVM.disabledPromptSections,
            duplicateUserInstructionsAtTop: promptVM.duplicateUserInstructionsAtTop
        )
    }
}

extension MCPServerViewModel {
    @MainActor
    func latestTokenBreakdown() -> TokenCountingViewModel.TokenBreakdown {
        promptVM.tokenCountingViewModel.latestTokenBreakdown()
    }
}
