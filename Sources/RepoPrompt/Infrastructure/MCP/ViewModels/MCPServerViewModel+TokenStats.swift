import Foundation

extension MCPServerViewModel {
    nonisolated static func makeTokenStats(
        filesTokens: Int,
        filesContentTokens: Int? = nil,
        codemapsTokens: Int? = nil,
        breakdown: TokenComponentBreakdown
    ) -> ToolResultDTOs.TokenStats {
        let promptTokens = breakdown.promptDisplay
        let metaTokens = breakdown.instructions
        let treeTokens = breakdown.fileTree
        let gitTokens = breakdown.gitDiff
        let otherTokens = breakdown.other
        return .init(
            total: filesTokens + breakdown.totalNonFile,
            files: filesTokens,
            prompt: promptTokens > 0 ? promptTokens : nil,
            fileTree: treeTokens > 0 ? treeTokens : nil,
            meta: metaTokens > 0 ? metaTokens : nil,
            git: gitTokens > 0 ? gitTokens : nil,
            other: otherTokens > 0 ? otherTokens : nil,
            filesContent: filesContentTokens,
            codemaps: codemapsTokens
        )
    }

    /// Computes workspace token stats (total breakdown including prompt, file tree, meta, git, etc.)
    /// This is the shared helper used by both `workspace_context` and `manage_selection`
    /// to ensure consistent token reporting.
    ///
    /// For virtual contexts (bound tabs), we compute totals from components since
    /// TokenCalcService reflects the active tab, not necessarily the bound tab.
    ///
    /// - Parameters:
    ///   - filesTokens: Token count from the current selection (tab-scoped, combined full+slices+codemaps)
    ///   - filesContentTokens: Token count from full files and slices only (excludes codemaps)
    ///   - codemapsTokens: Token count from codemaps only
    ///   - promptTokensOverride: Override for prompt tokens (for virtual contexts)
    ///   - fileTreeTokensOverride: Override for file tree tokens when freshly computed
    ///   - metaTokensOverride: Override for stored prompts tokens (for virtual contexts)
    ///   - gitTokensOverride: Override for git tokens (for virtual contexts)
    ///   - otherTokensOverride: Override for other tokens (XML formatting + MCP metadata)
    /// - Returns: Complete workspace token breakdown
    @MainActor
    func computeWorkspaceTokenStats(
        filesTokens: Int,
        filesContentTokens: Int? = nil,
        codemapsTokens: Int? = nil,
        promptTokensOverride: Int? = nil,
        fileTreeTokensOverride: Int? = nil,
        metaTokensOverride: Int? = nil,
        gitTokensOverride: Int? = nil,
        otherTokensOverride: Int? = nil
    ) -> ToolResultDTOs.TokenStats {
        // Get baseline from TokenCalcService (reflects active tab)
        let breakdown = promptVM.tokenCountingViewModel.latestTokenBreakdown()

        // Use overrides if provided (for virtual contexts), otherwise use breakdown
        let promptTokens = promptTokensOverride ?? breakdown.prompt
        let treeTokens = fileTreeTokensOverride ?? breakdown.fileTree
        let metaTokens = metaTokensOverride ?? breakdown.meta
        let gitTokens = gitTokensOverride ?? breakdown.git
        // Note: Don't default to breakdown.other as it includes codemaps which are already in filesTokens
        let otherTokens = otherTokensOverride ?? 0

        return Self.makeTokenStats(
            filesTokens: filesTokens,
            filesContentTokens: filesContentTokens,
            codemapsTokens: codemapsTokens,
            breakdown: .init(
                prompt: promptTokens,
                duplicatePrompt: 0,
                instructions: metaTokens,
                fileTree: treeTokens,
                gitDiff: gitTokens,
                metadata: otherTokens
            )
        )
    }
}

extension MCPServerViewModel {
    struct MCPPreparedTokenAccounting {
        let entryResultsByFileID: [UUID: PromptEntriesEvaluation.EntryResult]
        let breakdown: TokenComponentBreakdown
        let tokenAccounting: ToolResultDTOs.TokenAccountingDTO
        let activePublishedSnapshot: TokenCountingViewModel.PublishedTokenSnapshot?
    }

    @MainActor
    func prepareMCPTokenAccounting(
        context: TabScopedContext,
        effectiveSelection: StoredSelection,
        collections: SelectionReplyAssembler.SelectionCollections,
        resolvedContext: PromptContextResolved,
        lookupContext: WorkspaceLookupContext,
        activeTabCompatibility: Bool
    ) async -> MCPPreparedTokenAccounting {
        let cachedEvaluation = await cachedPromptEntriesEvaluation(collections: collections)
        if activeTabCompatibility {
            let published = promptVM.tokenCountingViewModel.latestPublishedTokenSnapshot(
                for: effectiveSelection
            )
            var entryResults = cachedEvaluation.entryResultsByFileID
            for entry in collections.selected {
                guard let info = promptVM.tokenCountingViewModel.latestPublishedTokenInfo(
                    forFullPath: entry.file.standardizedFullPath
                ) else { continue }
                let renderMode: PromptEntriesEvaluation.RenderMode = entry.ranges?.isEmpty == false ? .slice : .full
                let displayTokens = renderMode == .slice ? info.count : info.fullCount
                entryResults[entry.file.id] = .init(
                    fileID: entry.file.id,
                    renderMode: renderMode,
                    displayTokens: displayTokens,
                    fullTokens: info.fullCount,
                    codemapTokens: info.codemapCount
                )
            }
            for entry in collections.codemap {
                guard let info = promptVM.tokenCountingViewModel.latestPublishedTokenInfo(
                    forFullPath: entry.file.standardizedFullPath
                ) else { continue }
                entryResults[entry.file.id] = .init(
                    fileID: entry.file.id,
                    renderMode: .codemap,
                    displayTokens: info.codemapCount,
                    fullTokens: info.fullCount,
                    codemapTokens: info.codemapCount
                )
            }
            let status = !published.isComplete ? "incomplete" : (published.isStale ? "stale" : "fresh")
            return MCPPreparedTokenAccounting(
                entryResultsByFileID: entryResults,
                breakdown: .init(
                    prompt: published.breakdown.prompt,
                    duplicatePrompt: 0,
                    instructions: published.breakdown.meta,
                    fileTree: published.breakdown.fileTree,
                    gitDiff: published.breakdown.git,
                    metadata: max(published.breakdown.other - published.codeMapTokens, 0)
                ),
                tokenAccounting: .init(
                    status: status,
                    source: "active_tab_published",
                    refreshPending: published.refreshPending,
                    incompleteComponents: published.isComplete ? nil : ["published_snapshot"]
                ),
                activePublishedSnapshot: published
            )
        }

        let signature = virtualTokenSignature(
            context: context,
            selection: effectiveSelection,
            resolvedContext: resolvedContext,
            lookupContext: lookupContext,
            codeMapUsage: collections.codeMapUsage
        )
        let cachedSnapshot = mcpVirtualTokenSnapshotsByTabID[context.tabID]?[signature]
        if let cachedSnapshot {
            enqueueVirtualTokenRefresh(
                signature: signature,
                context: context,
                effectiveSelection: effectiveSelection,
                resolvedContext: resolvedContext,
                collections: collections,
                lookupContext: lookupContext
            )
            return MCPPreparedTokenAccounting(
                entryResultsByFileID: cachedSnapshot.entryResultsByFileID,
                breakdown: cachedSnapshot.breakdown,
                tokenAccounting: .init(
                    status: "stale",
                    source: "bound_tab_cache",
                    refreshPending: true
                ),
                activePublishedSnapshot: nil
            )
        }

        var incompleteComponents: [String] = []
        if collections.selected.contains(where: { $0.entry.loadedContent == nil }) {
            incompleteComponents.append("files")
        }
        if resolvedContext.rendersFileTree {
            incompleteComponents.append("file_tree")
        }
        if resolvedContext.gitInclusion != .none {
            incompleteComponents.append("git")
        }
        if !incompleteComponents.isEmpty {
            enqueueVirtualTokenRefresh(
                signature: signature,
                context: context,
                effectiveSelection: effectiveSelection,
                resolvedContext: resolvedContext,
                collections: collections,
                lookupContext: lookupContext
            )
        }
        let selectedInstructionsText = promptVM.metaInstructions(
            for: resolvedContext,
            selectedPromptIDsOverride: context.selectedMetaPromptIDs
        )
        .map(\.content)
        .joined(separator: "\n\n")
        let promptText = resolvedContext.includeUserPrompt ? context.promptText : ""
        let duplicatePrompt = resolvedContext.includeUserPrompt
            ? promptVM.duplicateUserInstructionsAtTop
            : false
        return MCPPreparedTokenAccounting(
            entryResultsByFileID: cachedEvaluation.entryResultsByFileID,
            breakdown: TokenCalculationService.calculateComponentBreakdown(
                promptText: promptText,
                selectedInstructionsText: selectedInstructionsText,
                fileTreeText: "",
                gitDiffText: nil,
                metadataText: nil,
                duplicateUserInstructionsAtTop: duplicatePrompt
            ),
            tokenAccounting: .init(
                status: incompleteComponents.isEmpty ? "fresh" : "incomplete",
                source: "bound_tab_cached_state",
                refreshPending: !incompleteComponents.isEmpty,
                incompleteComponents: incompleteComponents.isEmpty ? nil : incompleteComponents
            ),
            activePublishedSnapshot: nil
        )
    }

    @MainActor
    private func cachedPromptEntriesEvaluation(
        collections: SelectionReplyAssembler.SelectionCollections
    ) async -> PromptEntriesEvaluation {
        let entries = collections.selected.map(\.entry) + collections.codemap.map(\.entry)
        let snapshots = await PromptContextAccountingService().makePromptFileEntrySnapshots(
            from: entries,
            codemapSnapshots: collections.codemapSnapshots,
            filePathDisplay: promptVM.filePathDisplayOption
        )
        return await TokenCalculationService().evaluatePromptEntries(snapshots)
    }

    @MainActor
    private func virtualTokenSignature(
        context: TabScopedContext,
        selection: StoredSelection,
        resolvedContext: PromptContextResolved,
        lookupContext: WorkspaceLookupContext,
        codeMapUsage: CodeMapUsage
    ) -> MCPVirtualTokenSignature {
        MCPVirtualTokenSignature(
            tabID: context.tabID,
            workspaceID: context.workspaceID,
            selection: selection,
            promptText: context.promptText,
            selectedMetaPromptIDs: context.selectedMetaPromptIDs,
            codeMapUsage: codeMapUsage.rawValue,
            includeUserPrompt: resolvedContext.includeUserPrompt,
            includeMetaPrompts: resolvedContext.includeMetaPrompts,
            rendersFileTree: resolvedContext.rendersFileTree,
            fileTreeMode: resolvedContext.effectiveFileTreeMode.rawValue,
            gitInclusion: resolvedContext.gitInclusion.rawValue,
            lookupScope: String(describing: lookupContext.rootScope)
        )
    }

    @MainActor
    private func enqueueVirtualTokenRefresh(
        signature: MCPVirtualTokenSignature,
        context: TabScopedContext,
        effectiveSelection: StoredSelection,
        resolvedContext: PromptContextResolved,
        collections: SelectionReplyAssembler.SelectionCollections,
        lookupContext: WorkspaceLookupContext
    ) {
        if mcpVirtualTokenRefreshTasksByTabID[context.tabID]?[signature] != nil {
            return
        }
        let generation = UUID()
        mcpVirtualTokenRefreshGenerationByTabID[context.tabID, default: [:]][signature] = generation
        #if DEBUG
            mcpVirtualTokenRefreshStartCount += 1
        #endif
        mcpVirtualTokenRefreshTasksByTabID[context.tabID, default: [:]][signature] = Task { @MainActor [weak self] in
            guard let self else { return }
            #if DEBUG
                await debugBeforeVirtualTokenRefreshForTesting?()
            #endif
            let evaluation = await evaluateVirtualPromptEntries(
                for: effectiveSelection,
                codeMapUsage: collections.codeMapUsage,
                rootScope: lookupContext.rootScope
            )
            guard !Task.isCancelled else { return }
            let breakdown = await buildVirtualTokenBreakdown(
                for: context,
                resolvedContext: resolvedContext,
                selectedFiles: collections.selected.map(\.file),
                codemapFiles: collections.codemap.map(\.file),
                lookupContext: lookupContext
            )
            guard !Task.isCancelled,
                  mcpVirtualTokenRefreshGenerationByTabID[context.tabID]?[signature] == generation
            else { return }
            mcpVirtualTokenSnapshotsByTabID[context.tabID, default: [:]][signature] = MCPVirtualTokenSnapshot(
                signature: signature,
                entryResultsByFileID: evaluation.entryResultsByFileID,
                breakdown: breakdown
            )
            mcpVirtualTokenRefreshTasksByTabID[context.tabID]?[signature] = nil
            mcpVirtualTokenRefreshGenerationByTabID[context.tabID]?[signature] = nil
            if mcpVirtualTokenRefreshTasksByTabID[context.tabID]?.isEmpty == true {
                mcpVirtualTokenRefreshTasksByTabID[context.tabID] = nil
            }
            if mcpVirtualTokenRefreshGenerationByTabID[context.tabID]?.isEmpty == true {
                mcpVirtualTokenRefreshGenerationByTabID[context.tabID] = nil
            }
        }
    }

    nonisolated static func publishedTokenStats(
        _ snapshot: TokenCountingViewModel.PublishedTokenSnapshot
    ) -> ToolResultDTOs.TokenStats {
        let files = snapshot.filesContentTokens + snapshot.codeMapTokens
        return .init(
            total: snapshot.breakdown.total,
            files: files,
            prompt: snapshot.breakdown.prompt > 0 ? snapshot.breakdown.prompt : nil,
            fileTree: snapshot.breakdown.fileTree > 0 ? snapshot.breakdown.fileTree : nil,
            meta: snapshot.breakdown.meta > 0 ? snapshot.breakdown.meta : nil,
            git: snapshot.breakdown.git > 0 ? snapshot.breakdown.git : nil,
            other: max(snapshot.breakdown.other - snapshot.codeMapTokens, 0),
            filesContent: snapshot.filesContentTokens > 0 ? snapshot.filesContentTokens : nil,
            codemaps: snapshot.codeMapTokens > 0 ? snapshot.codeMapTokens : nil
        )
    }
}
