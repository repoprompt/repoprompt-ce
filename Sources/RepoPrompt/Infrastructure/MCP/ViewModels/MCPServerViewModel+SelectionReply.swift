import Foundation

extension MCPServerViewModel {
    enum SelectionReplyIngressPolicy: Equatable {
        case awaitPending
        case alreadyAwaited
    }

    struct CanonicalSelectionReadSnapshot: Equatable {
        let selection: StoredSelection
        let selectionRevision: UInt64
    }

    enum StabilizedSelectionReadSnapshotError: LocalizedError, Equatable {
        case canonicalTabUnavailable(workspaceID: UUID?, tabID: UUID)

        var errorDescription: String? {
            switch self {
            case let .canonicalTabUnavailable(workspaceID, tabID):
                let workspace = workspaceID?.uuidString ?? "unknown"
                return "Canonical selection is unavailable for workspace \(workspace), tab \(tabID.uuidString). Rebind the tab context and retry."
            }
        }
    }

    @MainActor
    private func canonicalSelectionReadSnapshot(
        for context: TabScopedContext
    ) -> CanonicalSelectionReadSnapshot? {
        guard let manager = workspaceManager else { return nil }

        let identity: WorkspaceSelectionIdentity
        if let workspaceID = context.workspaceID {
            identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: context.tabID)
        } else {
            guard let workspace = manager.workspaces.first(where: { workspace in
                workspace.composeTabs.contains(where: { $0.id == context.tabID })
            }) else { return nil }
            identity = WorkspaceSelectionIdentity(workspaceID: workspace.id, tabID: context.tabID)
        }

        guard let selection = manager.composeTab(for: identity)?.selection else { return nil }
        return CanonicalSelectionReadSnapshot(
            selection: selection,
            selectionRevision: manager.selectionRevisionForMCP(
                workspaceID: identity.workspaceID,
                tabID: identity.tabID
            )
        )
    }

    @MainActor
    func stabilizedVirtualSelection(for context: TabScopedContext) async -> StoredSelection {
        await stabilizedVirtualContext(for: context).selection
    }

    @MainActor
    func stabilizedVirtualContext(for context: TabScopedContext) async -> TabScopedContext {
        // For any tab-bound virtual context (including runs), prefer latest stored tab selection.
        // This prevents resurrecting stale slices from the run snapshot after the user clears them.
        guard let canonical = canonicalSelectionReadSnapshot(for: context) else { return context }
        var stabilized = context
        stabilized.selection = canonical.selection
        stabilized.selectionRevision = canonical.selectionRevision
        return stabilized
    }

    @MainActor
    func stabilizedSelectionReadSnapshot(
        _ resolved: ResolvedTabContextSnapshot
    ) throws -> ResolvedTabContextSnapshot {
        guard !resolved.usesActiveTabCompatibility else { return resolved }
        guard let canonical = canonicalSelectionReadSnapshot(for: resolved.snapshot) else {
            throw StabilizedSelectionReadSnapshotError.canonicalTabUnavailable(
                workspaceID: resolved.snapshot.workspaceID,
                tabID: resolved.snapshot.tabID
            )
        }

        var stabilized = resolved
        stabilized.snapshot.selection = canonical.selection
        stabilized.snapshot.selectionRevision = canonical.selectionRevision
        return stabilized
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
        let service = TokenCalculationService()
        do {
            return try await accountingService.withPromptStats(
                request: request,
                store: store,
                lookupContext: WorkspaceLookupContext(
                    rootScope: rootScope,
                    bindingProjection: nil
                )
            ) { accounting in
                await service.evaluatePromptEntries(accounting.promptFileEntrySnapshots)
            }
        } catch {
            return await service.evaluatePromptEntries([])
        }
    }

    @MainActor
    private func virtualSelectionFileTreeText(
        selection: StoredSelection,
        resolvedContext: PromptContextResolved,
        lookupContext: WorkspaceLookupContext,
        codemapPresentation: WorkspaceCodemapOperationPresentation
    ) async -> String {
        guard resolvedContext.rendersFileTree else { return "" }
        let store = promptVM.workspaceFileContextStore
        let presentation = await store.makeFileTreePresentation(
            selection: lookupContext.physicalizeSelection(selection),
            request: WorkspaceFileTreePresentationRequest(
                mode: WorkspaceFileTreePresentationMode(fileTreeOption: resolvedContext.effectiveFileTreeMode),
                filePathDisplay: promptVM.filePathDisplayOption,
                onlyIncludeRootsWithSelectedFiles: promptVM.onlyIncludeRootsWithSelectedFiles,
                includeLegend: true,
                showCodeMapMarkers: !promptVM.codeMapsGloballyDisabled,
                rootScope: lookupContext.rootScope
            ),
            lookupContext: lookupContext,
            codemapPresentation: codemapPresentation,
            profile: .uiAssisted
        )
        return presentation.content
    }

    @MainActor
    private func virtualSelectionGitDiffText(
        for selection: StoredSelection,
        resolvedContext: PromptContextResolved,
        lookupContext: WorkspaceLookupContext,
        context: TabScopedContext
    ) async -> String? {
        switch resolvedContext.gitInclusion {
        case .none:
            return nil
        case .selected:
            let pathResolution = await WorkspaceGitDiffSelectionResolver.resolveSelectedGitDiffPaths(
                for: lookupContext.physicalizeSelection(selection),
                store: promptVM.workspaceFileContextStore,
                rootScope: lookupContext.rootScope,
                folderPolicy: .filesOnly,
                profile: .mcpSelection,
                allowFilesystemFallback: lookupContext.rootScope.allowsSelectedGitDiffFilesystemFallback,
                excluding: []
            )
            let reviewGitContext = await promptVM.freezePromptGitReviewContext(
                workspaceID: context.workspaceID,
                tabID: context.tabID,
                sessionID: context.activeAgentSessionID,
                bindings: context.worktreeBindings
            )
            return await AutomaticReviewGitDiffCoordinator().resolve(
                AutomaticReviewGitDiffRequest(
                    pathResolution: pathResolution,
                    compareIntent: reviewGitContext.compareIntent,
                    displayContext: reviewGitContext.displayContext
                )
            ).text
        case .complete:
            guard lookupContext.bindingProjection == nil else {
                return PromptContextGitDiffPolicy.deferredCompleteWorktreeGitDiffMessage
            }
            return await promptVM.gitViewModel.getDiffUsing(inclusionMode: .all, forceRefreshStatus: true)
        }
    }

    @MainActor
    func buildVirtualTokenBreakdown(
        for context: TabScopedContext,
        resolvedContext: PromptContextResolved,
        selectedFiles: [WorkspaceFileRecord],
        codemapFiles: [WorkspaceFileRecord],
        lookupContext: WorkspaceLookupContext,
        codemapPresentation: WorkspaceCodemapOperationPresentation
    ) async -> TokenComponentBreakdown {
        let selectedInstructionsText = promptVM.metaInstructions(
            for: resolvedContext,
            selectedPromptIDsOverride: context.selectedMetaPromptIDs
        )
        .map(\.content)
        .joined(separator: "\n\n")
        let isActiveWorkspaceBound = context.workspaceID == nil || context.workspaceID == workspaceManager?.activeWorkspace?.id
        let fileTreeText = isActiveWorkspaceBound
            ? await virtualSelectionFileTreeText(
                selection: context.selection,
                resolvedContext: resolvedContext,
                lookupContext: lookupContext,
                codemapPresentation: codemapPresentation
            )
            : ""
        let gitDiffText = isActiveWorkspaceBound
            ? await virtualSelectionGitDiffText(
                for: context.selection,
                resolvedContext: resolvedContext,
                lookupContext: lookupContext,
                context: context
            )
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
        codemapFiles: [WorkspaceFileRecord],
        lookupContext: WorkspaceLookupContext,
        codemapPresentation: WorkspaceCodemapOperationPresentation
    ) async -> ToolResultDTOs.TokenStats {
        let filesContentTokens = (filesReply.summary?.fullTokens ?? 0) + (filesReply.summary?.sliceTokens ?? 0)
        let codemapsTokens = filesReply.summary?.codemapTokens ?? 0
        let breakdown = await buildVirtualTokenBreakdown(
            for: context,
            resolvedContext: resolvedContext,
            selectedFiles: selectedFiles,
            codemapFiles: codemapFiles,
            lookupContext: lookupContext,
            codemapPresentation: codemapPresentation
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
        lookupContext: WorkspaceLookupContext = .visibleWorkspace,
        virtualContext: TabScopedContext? = nil,
        reviewGitContext: FrozenPromptGitReviewContext? = nil
    ) async -> ToolResultDTOs.SelectionReply {
        await buildTabSelectionReply(
            from: selection,
            includeBlocks: includeBlocks,
            display: display,
            extraInvalid: extraInvalid,
            viewMode: viewMode,
            codeMapUsageOverride: codeMapUsageOverride,
            virtualContext: virtualContext,
            lookupContextOverride: lookupContext,
            ingressPolicy: .alreadyAwaited,
            reviewGitContextOverride: reviewGitContext,
            statusOverride: "preview"
        )
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
        lookupContextOverride: WorkspaceLookupContext? = nil,
        ingressPolicy: SelectionReplyIngressPolicy = .awaitPending,
        reviewGitContextOverride: FrozenPromptGitReviewContext? = nil,
        statusOverride: String = "ok"
    ) async -> ToolResultDTOs.SelectionReply {
        await buildTabSelectionReplyCore(
            from: selection,
            includeBlocks: includeBlocks,
            display: display,
            extraInvalid: extraInvalid,
            viewMode: viewMode,
            codeMapUsageOverride: codeMapUsageOverride,
            virtualContext: virtualContext,
            lookupContextOverride: lookupContextOverride,
            ingressPolicy: ingressPolicy,
            reviewGitContextOverride: reviewGitContextOverride,
            codemapPresentationOverride: nil,
            statusOverride: statusOverride
        )
    }

    @MainActor
    func buildBorrowedTabSelectionReply(
        codemapPresentation: WorkspaceCodemapOperationPresentation,
        from selection: StoredSelection,
        includeBlocks: Bool,
        display: FilePathDisplay,
        lookupContext: WorkspaceLookupContext
    ) async -> ToolResultDTOs.SelectionReply {
        await buildTabSelectionReplyCore(
            from: selection,
            includeBlocks: includeBlocks,
            display: display,
            lookupContextOverride: lookupContext,
            ingressPolicy: .alreadyAwaited,
            codemapPresentationOverride: codemapPresentation
        )
    }

    @MainActor
    private func buildTabSelectionReplyCore(
        from selection: StoredSelection,
        includeBlocks: Bool,
        display: FilePathDisplay,
        extraInvalid: [String] = [],
        viewMode: String? = nil,
        codeMapUsageOverride: CodeMapUsage? = nil,
        virtualContext: TabScopedContext? = nil,
        lookupContextOverride: WorkspaceLookupContext? = nil,
        ingressPolicy: SelectionReplyIngressPolicy = .awaitPending,
        reviewGitContextOverride: FrozenPromptGitReviewContext? = nil,
        codemapPresentationOverride: WorkspaceCodemapOperationPresentation? = nil,
        statusOverride: String = "ok"
    ) async -> ToolResultDTOs.SelectionReply {
        // Always use .auto mode for manage_selection (normalized view)
        let effectiveOverride = effectiveMCPCodeMapUsage(codeMapUsageOverride ?? .auto)
        let lookupContext = if let lookupContextOverride {
            lookupContextOverride
        } else if let virtualContext {
            await lookupContext(for: virtualContext)
        } else {
            WorkspaceLookupContext.visibleWorkspace
        }
        if ingressPolicy == .awaitPending {
            _ = await promptVM.workspaceFileContextStore.awaitAppliedIngress(rootScope: lookupContext.rootScope)
        }
        let effectiveSelection = lookupContext.physicalizeSelection(selection)
        let reviewGitContext = if let reviewGitContextOverride {
            reviewGitContextOverride
        } else {
            await promptVM.freezePromptGitReviewContext(
                workspaceID: virtualContext?.workspaceID,
                tabID: virtualContext?.tabID,
                sessionID: virtualContext?.activeAgentSessionID,
                bindings: virtualContext?.worktreeBindings ?? [],
                base: "HEAD"
            )
        }
        let artifactAuthorization = await authorizeSelectedGitArtifacts(
            selection: effectiveSelection,
            reviewGitContext: reviewGitContext
        )
        let ordinarySelection = selectionExcludingArtifacts(
            effectiveSelection,
            excluding: artifactAuthorization.consumedSelectionPaths
        )
        let source = StoredSelectionSource(stored: ordinarySelection, codeMapUsage: effectiveOverride)
        let ordinaryCollections = await SelectionReplyAssembler.collect(
            from: source,
            owner: self,
            rootScope: lookupContext.rootScope.excludingWorkspaceGitData,
            contentPolicy: includeBlocks ? .loadContent : .cachedOnly,
            lookupContext: WorkspaceLookupContext(
                rootScope: lookupContext.rootScope.excludingWorkspaceGitData,
                bindingProjection: lookupContext.bindingProjection
            ),
            codemapPresentation: codemapPresentationOverride,
            issuePathDisplay: display
        )
        let collections = overlaySelectedGitArtifacts(
            artifactAuthorization,
            onto: ordinaryCollections
        )
        let resolvedPromptContext = promptVM.resolvePromptContext()
        let accountingContext = virtualContext ?? TabContextSnapshot(
            tabID: promptVM.activeComposeTabID ?? UUID(),
            windowID: windowID,
            workspaceID: workspaceManager?.activeWorkspace?.id,
            promptText: promptVM.promptText,
            selection: effectiveSelection,
            selectedMetaPromptIDs: [],
            tabName: "Active",
            runID: nil,
            explicitlyBound: false
        )
        let useActivePublishedSnapshot = virtualContext == nil && codemapPresentationOverride == nil
        let preparedAccounting = await prepareMCPTokenAccounting(
            context: accountingContext,
            effectiveSelection: effectiveSelection,
            collections: collections,
            resolvedContext: resolvedPromptContext,
            lookupContext: lookupContext,
            activeTabCompatibility: useActivePublishedSnapshot,
            allowActivePublishedSnapshotRefresh: codemapPresentationOverride == nil,
            allowVirtualTokenRefresh: codemapPresentationOverride == nil
        )
        let artifactRootMetadata: [String: PathFormatter.RootMetadata] = Dictionary(
            uniqueKeysWithValues: artifactAuthorization.displayAliasesByAbsolutePath.compactMap { path, alias in
                guard artifactAuthorization.entries.contains(where: {
                    $0.file.standardizedFullPath == path
                }) else { return nil }
                let pathWithinRoot = alias.hasPrefix("_git_data/")
                    ? String(alias.dropFirst("_git_data/".count))
                    : alias
                return (
                    path,
                    PathFormatter.RootMetadata(
                        rootPath: "_git_data",
                        pathWithinRoot: pathWithinRoot
                    )
                )
            }
        )
        let formatter = PathFormatter(
            format: display,
            owner: self,
            projection: lookupContext.bindingProjection,
            rootScope: lookupContext.rootScope,
            displayPathOverrides: artifactAuthorization.displayAliasesByAbsolutePath,
            rootMetadataOverrides: artifactRootMetadata
        )
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
            entryResultsByFileID: preparedAccounting.entryResultsByFileID
        )

        let tokenStatsOverride: ToolResultDTOs.TokenStats = if let published = preparedAccounting.activePublishedSnapshot {
            Self.publishedTokenStats(published)
        } else {
            Self.makeTokenStats(
                filesTokens: filesReply.totalTokens,
                filesContentTokens: (filesReply.summary?.fullTokens ?? 0) + (filesReply.summary?.sliceTokens ?? 0),
                codemapsTokens: filesReply.summary?.codemapTokens,
                breakdown: preparedAccounting.breakdown
            )
        }

        var reply = await SelectionReplyAssembler.makeSelectionReply(
            filesReply: filesReply,
            collections: collections,
            includeBlocks: includeBlocks,
            display: display,
            status: statusOverride,
            extraInvalid: extraInvalid + artifactAuthorization.rejectedDisplayDiagnostics,
            userPresetState: userPresetState,
            tokens: tokens,
            tokenStatsOverride: tokenStatsOverride,
            tokenAccountingOverride: preparedAccounting.tokenAccounting,
            pathProjection: lookupContext.bindingProjection,
            displayPathOverrides: artifactAuthorization.displayAliasesByAbsolutePath
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
                    tokenStats: reply.tokenStats,
                    tokenAccounting: reply.tokenAccounting
                )
            }
        }

        if let v = viewMode, v == "codemaps" {
            reply = SelectionReplyAssembler.applyViewFilter(reply, view: v)
        }
        return reply
    }

    private func authorizeSelectedGitArtifacts(
        selection: StoredSelection,
        reviewGitContext: FrozenPromptGitReviewContext
    ) async -> SelectedGitArtifactAuthorizationResult {
        guard let capability = reviewGitContext.artifactCapability else {
            return SelectedGitArtifactAuthorizationResult(
                entries: [],
                consumedSelectionPaths: [],
                dispositions: []
            )
        }
        return await SelectedGitDiffArtifactAuthorizationService().authorize(
            SelectedGitArtifactAuthorizationRequest(
                physicalSelection: selection,
                capability: capability,
                store: promptVM.workspaceFileContextStore
            )
        )
    }

    private func selectionExcludingArtifacts(
        _ selection: StoredSelection,
        excluding consumedPaths: Set<String>
    ) -> StoredSelection {
        guard !consumedPaths.isEmpty else { return selection }
        let normalizedConsumed = Set(
            consumedPaths.compactMap(StoredSelectionPathNormalization.standardizedPath)
        )
        func isConsumed(_ path: String) -> Bool {
            consumedPaths.contains(path)
                || StoredSelectionPathNormalization.standardizedPath(path)
                .map(normalizedConsumed.contains) == true
        }
        return StoredSelection(
            selectedPaths: selection.selectedPaths.filter { !isConsumed($0) },
            manualCodemapPaths: selection.manualCodemapPaths,
            slices: selection.slices.filter { !isConsumed($0.key) },
            codemapAutoEnabled: selection.codemapAutoEnabled
        )
    }

    private func overlaySelectedGitArtifacts(
        _ authorization: SelectedGitArtifactAuthorizationResult,
        onto collections: SelectionReplyAssembler.SelectionCollections
    ) -> SelectionReplyAssembler.SelectionCollections {
        let artifactEntries = authorization.entries.map {
            SelectionReplyAssembler.SelectedEntry(entry: $0)
        }
        guard !artifactEntries.isEmpty else { return collections }
        return SelectionReplyAssembler.SelectionCollections(
            selected: artifactEntries + collections.selected,
            codemap: collections.codemap,
            codemapAutoEnabled: collections.codemapAutoEnabled,
            codeMapUsage: collections.codeMapUsage,
            invalid: collections.invalid,
            codemapPresentation: collections.codemapPresentation
        )
    }

    // MARK: - Unified Selection Reply Builder

    /// Unified entry point to build a selection reply from a resolved tab-context snapshot.
    @MainActor
    func buildCurrentSelectionReply(
        includeBlocks: Bool,
        display: FilePathDisplay,
        extraInvalid: [String] = [],
        viewMode: String? = nil,
        resolvedContext: ResolvedTabContextSnapshot,
        lookupContext: WorkspaceLookupContext
    ) async -> ToolResultDTOs.SelectionReply {
        var context = resolvedContext.snapshot
        if !resolvedContext.usesActiveTabCompatibility {
            context = await stabilizedVirtualContext(for: context)
        }
        return await buildTabSelectionReply(
            from: context.selection,
            includeBlocks: includeBlocks,
            display: display,
            extraInvalid: extraInvalid,
            viewMode: viewMode,
            codeMapUsageOverride: .auto,
            virtualContext: resolvedContext.usesActiveTabCompatibility ? nil : context,
            lookupContextOverride: lookupContext,
            ingressPolicy: .alreadyAwaited
        )
    }

    @MainActor
    func buildSelectionMutationReply(
        from selection: StoredSelection,
        includeBlocks: Bool,
        display: FilePathDisplay,
        extraInvalid: [String] = [],
        viewMode: String? = nil,
        codeMapUsageOverride: CodeMapUsage? = nil,
        virtualContext: TabScopedContext?,
        lookupContext: WorkspaceLookupContext,
        reviewGitContext: FrozenPromptGitReviewContext? = nil
    ) async -> ToolResultDTOs.SelectionReply {
        var effectiveSelection = selection
        var effectiveVirtualContext = virtualContext
        if var context = virtualContext {
            context = await stabilizedVirtualContext(for: context)
            effectiveSelection = context.selection
            effectiveVirtualContext = context
        }
        return await buildTabSelectionReply(
            from: effectiveSelection,
            includeBlocks: includeBlocks,
            display: display,
            extraInvalid: extraInvalid,
            viewMode: viewMode,
            codeMapUsageOverride: codeMapUsageOverride,
            virtualContext: effectiveVirtualContext,
            lookupContextOverride: lookupContext,
            ingressPolicy: .alreadyAwaited,
            reviewGitContextOverride: reviewGitContext
        )
    }

    func selectedFilesWithStats(resolvedContext: ResolvedTabContextSnapshot) async -> ToolResultDTOs.SelectedFilesReply {
        // Get user's effective copy preset mode for projection
        let copyUsage = await MainActor.run { promptVM.effectiveCopyCodeMapUsage() }
        let userPresetState = await MainActor.run { (copyUsage != .auto || promptVM.codeMapsGloballyDisabled) ? buildUserPresetState() : nil }

        let collections = await selectionCollections(for: resolvedContext.snapshot, codeMapUsageOverride: .auto)
        let lookupContext = await lookupContext(for: resolvedContext.snapshot)
        let formatter = PathFormatter(
            format: .relative,
            owner: self,
            projection: lookupContext.bindingProjection,
            rootScope: lookupContext.rootScope
        )
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
        for file in files where collections.codemapPresentation.renderedEntriesByFileID[file.id] == nil {
            let p = await PathFormatter(
                format: display,
                owner: self,
                projection: projection
            ).displayPath(for: file)
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
