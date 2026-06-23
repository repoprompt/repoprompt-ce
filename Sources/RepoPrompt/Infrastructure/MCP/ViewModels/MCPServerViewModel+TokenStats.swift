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
        let rendered: PromptFactualRenderedSections?
    }

    @MainActor
    func prepareMCPTokenAccounting(
        context: TabScopedContext,
        effectiveSelection _: StoredSelection,
        collections: SelectionReplyAssembler.SelectionCollections,
        resolvedContext: PromptContextResolved,
        lookupContext: WorkspaceLookupContext,
        ingressPolicy: SelectionReplyIngressPolicy,
        activeTabCompatibility _: Bool
    ) async -> MCPPreparedTokenAccounting {
        var factualConfig = resolvedContext
        factualConfig.includeFiles = true
        factualConfig.codeMapUsage = collections.codeMapUsage
        let reviewGitContext = await promptVM.freezePromptGitReviewContext(
            workspaceID: context.workspaceID,
            tabID: context.tabID,
            sessionID: context.activeAgentSessionID,
            bindings: context.worktreeBindings
        )
        let coordinator = AutomaticReviewGitDiffCoordinator()
        let outcome = await PromptContextPreAssemblyService.resolve(
            PromptContextPreAssemblyRequest(
                cfg: factualConfig,
                selection: context.selection,
                store: promptVM.workspaceFileContextStore,
                lookupContext: lookupContext,
                factualProvider: promptVM.promptFactualContextProvider,
                admissionToken: ServerNetworkManager.currentAdmittedContextBinding?.admissionToken,
                filePathDisplay: promptVM.filePathDisplayOption,
                onlyIncludeRootsWithSelectedFiles: promptVM.onlyIncludeRootsWithSelectedFiles,
                showCodeMapMarkers: !promptVM.codeMapsGloballyDisabled,
                codeMapUsage: collections.codeMapUsage,
                selectedGitDiffFolderPolicy: .filesOnly,
                selectedGitDiffLookupProfile: .mcpSelection,
                factualIngressPolicy: ingressPolicy == .awaitPending ? .awaitPending : .alreadyAwaited,
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

        guard case let .ready(preAssembly) = outcome else {
            return MCPPreparedTokenAccounting(
                entryResultsByFileID: [:],
                breakdown: .init(
                    prompt: 0,
                    duplicatePrompt: 0,
                    instructions: 0,
                    fileTree: 0,
                    gitDiff: 0,
                    metadata: 0
                ),
                tokenAccounting: .init(
                    status: "unavailable",
                    source: "construction_selected_factual_provider",
                    refreshPending: false,
                    incompleteComponents: ["factual_context"]
                ),
                activePublishedSnapshot: nil,
                rendered: nil
            )
        }

        let snapshot = preAssembly.factualSnapshot
        let pairs: [(UUID, PromptEntriesEvaluation.EntryResult)] = snapshot.entries.compactMap { entry in
            guard let info = snapshot.tokenResult.fileTokenInfo[entry.fileID] else { return nil }
            let renderMode: PromptEntriesEvaluation.RenderMode = if entry.isCodemap {
                .codemap
            } else if info.count != info.fullCount {
                .slice
            } else {
                .full
            }
            return (
                entry.fileID,
                .init(
                    fileID: entry.fileID,
                    renderMode: renderMode,
                    displayTokens: info.count,
                    fullTokens: info.fullCount,
                    codemapTokens: info.codemapCount
                )
            )
        }
        let selectedInstructionsText = promptVM.metaInstructions(
            for: resolvedContext,
            selectedPromptIDsOverride: context.selectedMetaPromptIDs
        )
        .map(\.content)
        .joined(separator: "\n\n")
        return MCPPreparedTokenAccounting(
            entryResultsByFileID: Dictionary(uniqueKeysWithValues: pairs),
            breakdown: TokenCalculationService.calculateComponentBreakdown(
                promptText: resolvedContext.includeUserPrompt ? context.promptText : "",
                selectedInstructionsText: selectedInstructionsText,
                fileTreeText: snapshot.rendered.fileTreeContent ?? "",
                gitDiffText: preAssembly.gitDiff,
                metadataText: nil,
                duplicateUserInstructionsAtTop: resolvedContext.includeUserPrompt
                    && promptVM.duplicateUserInstructionsAtTop
            ),
            tokenAccounting: .init(
                status: "fresh",
                source: "construction_selected_factual_provider",
                refreshPending: false
            ),
            activePublishedSnapshot: nil,
            rendered: snapshot.rendered
        )
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
