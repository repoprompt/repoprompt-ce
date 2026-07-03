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

    /// Canonical `TokenAccountingDTO.incompleteComponents` values, in stable display order.
    ///
    /// - `published_snapshot`: the active tab's published token snapshot is stale/incomplete.
    /// - `files`: selected file content or per-file token inputs are missing.
    /// - `codemap_presentation`: requested codemap presentation is pending or retryable.
    /// - `file_tree`: file-tree tokens require asynchronous virtual-context rendering.
    /// - `git`: git-review tokens require asynchronous virtual-context rendering.
    private static let tokenAccountingComponentOrder = [
        "published_snapshot",
        "files",
        "codemap_presentation",
        "file_tree",
        "git"
    ]

    @MainActor
    func prepareMCPTokenAccounting(
        context: TabScopedContext,
        effectiveSelection: StoredSelection,
        collections: SelectionReplyAssembler.SelectionCollections,
        resolvedContext: PromptContextResolved,
        lookupContext: WorkspaceLookupContext,
        activeTabCompatibility: Bool,
        allowActivePublishedSnapshotRefresh: Bool = true,
        allowVirtualTokenRefresh: Bool = true
    ) async -> MCPPreparedTokenAccounting {
        if activeTabCompatibility {
            let publishedOverlay = publishedEntryResultsOverlay(
                collections: collections,
                base: [:]
            )
            let published = promptVM.tokenCountingViewModel.latestPublishedTokenSnapshot(
                for: effectiveSelection,
                scheduleRefreshIfNeeded: allowActivePublishedSnapshotRefresh
            )

            var incompleteComponents = Self.virtualSnapshotIncompleteComponents(
                collections: collections,
                reliableFileIDs: publishedOverlay.reliableFileIDs
            )
            if !published.isComplete {
                incompleteComponents.insert("published_snapshot")
            }

            let orderedIncomplete = Self.orderedIncompleteComponents(incompleteComponents)
            if allowActivePublishedSnapshotRefresh, !incompleteComponents.isEmpty {
                if incompleteComponents.contains("files") {
                    promptVM.tokenCountingViewModel.markDirty(.selection)
                }
                if incompleteComponents.contains("codemap_presentation") {
                    promptVM.tokenCountingViewModel.markDirty(.codeMap)
                }
                if incompleteComponents.contains("published_snapshot") {
                    promptVM.tokenCountingViewModel.markDirty()
                }
            }
            let refreshPending = published.refreshPending
                || (allowActivePublishedSnapshotRefresh && !incompleteComponents.isEmpty)
            let status = if !incompleteComponents.isEmpty {
                "incomplete"
            } else if published.isStale {
                "stale"
            } else {
                "fresh"
            }

            return MCPPreparedTokenAccounting(
                entryResultsByFileID: publishedOverlay.entryResultsByFileID,
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
                    refreshPending: refreshPending,
                    incompleteComponents: orderedIncomplete
                ),
                activePublishedSnapshot: published
            )
        }

        let cachedEvaluation = await cachedPromptEntriesEvaluation(collections: collections)
        let publishedOverlay = publishedEntryResultsOverlay(
            collections: collections,
            base: cachedEvaluation.entryResultsByFileID
        )
        let signature = virtualTokenSignature(
            context: context,
            selection: effectiveSelection,
            resolvedContext: resolvedContext,
            lookupContext: lookupContext,
            codeMapUsage: collections.codeMapUsage
        )
        if allowVirtualTokenRefresh,
           let cachedSnapshot = mcpVirtualTokenSnapshotsByTabID[context.tabID]?[signature]
        {
            var incompleteComponents = Self.virtualSnapshotIncompleteComponents(
                collections: collections,
                reliableFileIDs: Set(cachedSnapshot.entryResultsByFileID.keys)
            )
            incompleteComponents.formUnion(cachedSnapshot.incompleteComponents ?? [])
            let orderedIncomplete = Self.orderedIncompleteComponents(incompleteComponents)
            // The virtual-token signature intentionally captures logical selection and prompt
            // shape, but not file-content, search-catalog, or codemap-authority generations.
            // Treat every cache hit as a stale lower-bound and refresh in the background so
            // bound agent tabs cannot permanently report obsolete token totals as fresh.
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
                    refreshPending: true,
                    incompleteComponents: orderedIncomplete
                ),
                activePublishedSnapshot: nil
            )
        }

        var incompleteComponents = Self.virtualSnapshotIncompleteComponents(
            collections: collections,
            reliableFileIDs: publishedOverlay.reliableFileIDs
        )
        if resolvedContext.rendersFileTree {
            incompleteComponents.insert("file_tree")
        }
        if resolvedContext.gitInclusion != .none {
            incompleteComponents.insert("git")
        }
        let orderedIncomplete = Self.orderedIncompleteComponents(incompleteComponents)
        if allowVirtualTokenRefresh, !incompleteComponents.isEmpty {
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
            entryResultsByFileID: publishedOverlay.entryResultsByFileID,
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
                refreshPending: allowVirtualTokenRefresh && !incompleteComponents.isEmpty,
                incompleteComponents: orderedIncomplete
            ),
            activePublishedSnapshot: nil
        )
    }

    @MainActor
    private func publishedEntryResultsOverlay(
        collections: SelectionReplyAssembler.SelectionCollections,
        base: [UUID: PromptEntriesEvaluation.EntryResult]
    ) -> (
        entryResultsByFileID: [UUID: PromptEntriesEvaluation.EntryResult],
        reliableFileIDs: Set<UUID>
    ) {
        var entryResults = base
        var reliableFileIDs = Set<UUID>()
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
            reliableFileIDs.insert(entry.file.id)
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
            reliableFileIDs.insert(entry.file.id)
        }
        return (entryResults, reliableFileIDs)
    }

    private static func orderedIncompleteComponents(
        _ components: Set<String>
    ) -> [String]? {
        let ordered = tokenAccountingComponentOrder.filter(components.contains)
        return ordered.isEmpty ? nil : ordered
    }

    private static func hasMissingFileTokenInputs(
        collections: SelectionReplyAssembler.SelectionCollections,
        reliableFileIDs: Set<UUID>
    ) -> Bool {
        collections.selected.contains { entry in
            entry.entry.loadedContent == nil && !reliableFileIDs.contains(entry.file.id)
        }
    }

    private static func hasPendingCodemapPresentationGaps(
        collections: SelectionReplyAssembler.SelectionCollections
    ) -> Bool {
        SelectionReplyAssembler.hasPendingCodemapPresentationGaps(
            for: SelectionReplyAssembler.codemapDiagnosticFiles(for: collections),
            presentation: collections.codemapPresentation,
            codeMapUsage: collections.codeMapUsage
        )
    }

    @MainActor
    private func cachedPromptEntriesEvaluation(
        collections: SelectionReplyAssembler.SelectionCollections
    ) async -> PromptEntriesEvaluation {
        let entries = collections.selected.map(\.entry) + collections.codemap.map(\.entry)
        let snapshots = await PromptContextAccountingService().makePromptFileEntrySnapshots(
            from: entries,
            codemapPresentation: collections.codemapPresentation,
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
                lookupContext: lookupContext,
                codemapPresentation: collections.codemapPresentation
            )
            guard !Task.isCancelled,
                  mcpVirtualTokenRefreshGenerationByTabID[context.tabID]?[signature] == generation
            else { return }
            mcpVirtualTokenSnapshotsByTabID[context.tabID, default: [:]][signature] = MCPVirtualTokenSnapshot(
                signature: signature,
                entryResultsByFileID: evaluation.entryResultsByFileID,
                breakdown: breakdown,
                incompleteComponents: Self.orderedIncompleteComponents(
                    Self.virtualSnapshotIncompleteComponents(
                        collections: collections,
                        reliableFileIDs: Set(evaluation.entryResultsByFileID.keys)
                    )
                )
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

    private static func virtualSnapshotIncompleteComponents(
        collections: SelectionReplyAssembler.SelectionCollections,
        reliableFileIDs: Set<UUID>
    ) -> Set<String> {
        var incompleteComponents = Set<String>()
        if hasMissingFileTokenInputs(
            collections: collections,
            reliableFileIDs: reliableFileIDs
        ) {
            incompleteComponents.insert("files")
        }
        if hasPendingCodemapPresentationGaps(collections: collections) {
            incompleteComponents.insert("codemap_presentation")
        }
        return incompleteComponents
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
