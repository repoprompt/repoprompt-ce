import Foundation

enum AgentProviderContextBuilder {
    static func initialFileTree(
        selection logicalSelection: StoredSelection,
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext,
        filePathDisplay: FilePathDisplay = .relative,
        onlyIncludeRootsWithSelectedFiles: Bool = false,
        showCodeMapMarkers: Bool = true
    ) async -> String {
        let physicalSelection = lookupContext.physicalizeSelection(logicalSelection)
        let presentationPlan = await AgentContextExportResolver.codemapPresentationPlan(
            codeMapUsage: .auto,
            selection: physicalSelection,
            store: store,
            rootScope: lookupContext.rootScope,
            profile: .uiAssisted
        )
        do {
            return try await WorkspaceCodemapPresentationCoordinator(store: store).withPresentation(
                for: presentationPlan.intent,
                rootScope: lookupContext.rootScope,
                logicalRootDisplayNamesByRootID: lookupContext.logicalRootDisplayNamesByRootID(
                    store: store
                )
            ) { presentation in
                await makeInitialFileTree(
                    physicalSelection: physicalSelection,
                    store: store,
                    lookupContext: lookupContext,
                    filePathDisplay: filePathDisplay,
                    onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
                    showCodeMapMarkers: showCodeMapMarkers,
                    codemapPresentation: AgentContextExportResolver.merging(
                        presentation,
                        preflightIssues: presentationPlan.preflightIssues
                    )
                )
            }
        } catch {
            let issue: WorkspaceCodemapOperationIssue = if Task.isCancelled || error is CancellationError {
                .cancelled
            } else {
                .coordinationUnavailable
            }
            return await makeInitialFileTree(
                physicalSelection: physicalSelection,
                store: store,
                lookupContext: lookupContext,
                filePathDisplay: filePathDisplay,
                onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
                showCodeMapMarkers: showCodeMapMarkers,
                codemapPresentation: AgentContextExportResolver.merging(
                    AgentContextExportResolver.unavailablePresentation(issue),
                    preflightIssues: presentationPlan.preflightIssues
                )
            )
        }
    }

    private static func makeInitialFileTree(
        physicalSelection: StoredSelection,
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext,
        filePathDisplay: FilePathDisplay,
        onlyIncludeRootsWithSelectedFiles: Bool,
        showCodeMapMarkers: Bool,
        codemapPresentation: WorkspaceCodemapOperationPresentation
    ) async -> String {
        let fileTree = await store.makeFileTreePresentation(
            selection: physicalSelection,
            request: WorkspaceFileTreePresentationRequest(
                mode: .auto,
                filePathDisplay: filePathDisplay,
                onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
                includeLegend: true,
                showCodeMapMarkers: showCodeMapMarkers,
                rootScope: lookupContext.rootScope
            ),
            lookupContext: lookupContext,
            codemapPresentation: codemapPresentation,
            profile: .uiAssisted
        )
        return fileTree.content
    }

    static func forkFileContentsBlock(
        selection logicalSelection: StoredSelection,
        tokenCap: Int,
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext,
        codemapPresentation: WorkspaceCodemapOperationPresentation? = nil,
        overTokenCapSummaryProvider: ((StoredSelection, WorkspaceLookupContext, WorkspaceCodemapOperationPresentation) async -> String?)? = nil,
        overTokenCapSummaryWillBegin: (() async -> Void)? = nil
    ) async -> String {
        let physicalSelection = lookupContext.physicalizeSelection(logicalSelection)
        if let codemapPresentation {
            return await makeForkFileContentsBlock(
                logicalSelection: logicalSelection,
                physicalSelection: physicalSelection,
                tokenCap: tokenCap,
                store: store,
                lookupContext: lookupContext,
                codemapPresentation: codemapPresentation,
                overTokenCapSummaryProvider: overTokenCapSummaryProvider,
                overTokenCapSummaryWillBegin: overTokenCapSummaryWillBegin
            )
        }
        let presentationPlan = await AgentContextExportResolver.codemapPresentationPlan(
            codeMapUsage: .auto,
            selection: physicalSelection,
            store: store,
            rootScope: lookupContext.rootScope,
            profile: .uiAssisted
        )
        do {
            return try await WorkspaceCodemapPresentationCoordinator(store: store).withPresentation(
                for: presentationPlan.intent,
                rootScope: lookupContext.rootScope,
                logicalRootDisplayNamesByRootID: lookupContext.logicalRootDisplayNamesByRootID(
                    store: store
                )
            ) { presentation in
                let presentation = AgentContextExportResolver.merging(
                    presentation,
                    preflightIssues: presentationPlan.preflightIssues
                )
                return await makeForkFileContentsBlock(
                    logicalSelection: logicalSelection,
                    physicalSelection: physicalSelection,
                    tokenCap: tokenCap,
                    store: store,
                    lookupContext: lookupContext,
                    codemapPresentation: presentation,
                    overTokenCapSummaryProvider: overTokenCapSummaryProvider,
                    overTokenCapSummaryWillBegin: overTokenCapSummaryWillBegin
                )
            }
        } catch {
            let issue: WorkspaceCodemapOperationIssue = if Task.isCancelled || error is CancellationError {
                .cancelled
            } else {
                .coordinationUnavailable
            }
            return await makeForkFileContentsBlock(
                logicalSelection: logicalSelection,
                physicalSelection: physicalSelection,
                tokenCap: tokenCap,
                store: store,
                lookupContext: lookupContext,
                codemapPresentation: AgentContextExportResolver.merging(
                    AgentContextExportResolver.unavailablePresentation(issue),
                    preflightIssues: presentationPlan.preflightIssues
                ),
                overTokenCapSummaryProvider: overTokenCapSummaryProvider,
                overTokenCapSummaryWillBegin: overTokenCapSummaryWillBegin
            )
        }
    }

    private static func makeForkFileContentsBlock(
        logicalSelection: StoredSelection,
        physicalSelection: StoredSelection,
        tokenCap: Int,
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext,
        codemapPresentation: WorkspaceCodemapOperationPresentation,
        overTokenCapSummaryProvider: ((StoredSelection, WorkspaceLookupContext, WorkspaceCodemapOperationPresentation) async -> String?)?,
        overTokenCapSummaryWillBegin: (() async -> Void)?
    ) async -> String {
        let accountingService = PromptContextAccountingService()
        let request = PromptContextAccountingRequest(
            selection: physicalSelection,
            codeMapUsage: .auto,
            filePathDisplay: .relative,
            rootScope: lookupContext.rootScope,
            pathLocateProfile: .uiAssisted
        )
        let roots = await store.rootRefs(scope: lookupContext.rootScope)
        let rootDisplayNames = await lookupContext.logicalRootDisplayNamesByRootID(store: store)
        let displayPathResolver: (ResolvedPromptFileEntry) -> String? = { entry in
            lookupContext.logicalDisplayPath(
                for: entry.file,
                roots: roots,
                rootDisplayNamesByRootID: rootDisplayNames,
                display: .relative
            )
        }
        let accounting = await accountingService.calculatePromptStats(
            request: request,
            store: store,
            codemapPresentation: codemapPresentation,
            codemapDisplayPathResolver: displayPathResolver
        )
        let entries = accounting.resolvedEntries
        let selectionTokens = accounting.tokenResult.totalTokenCountFilesOnly
            + accounting.tokenResult.codeMapTokenCount
        let resolvedPresentation = accounting.codemapPresentation

        if selectionTokens > tokenCap {
            await overTokenCapSummaryWillBegin?()
            if let summary = await overTokenCapSummaryProvider?(
                logicalSelection,
                lookupContext,
                resolvedPresentation
            ),
                !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return summary
            }
            return "<selection_summary>\(entries.count) files, ~\(selectionTokens) tokens (contents omitted, exceeds \(tokenCap) token cap)</selection_summary>"
        }

        let renderableEntries = entries.filter { entry in
            !entry.isCodemap || resolvedPresentation.renderedEntriesByFileID[entry.file.id] != nil
        }
        let (codemapBlocks, contentBlocks) = PromptPackagingService.generatePartitionedFileBlocks(
            renderableEntries,
            filePathDisplay: .relative,
            codemapPresentation: resolvedPresentation,
            displayPathResolver: displayPathResolver
        )
        var sections: [String] = []
        if let fileMap = PromptPackagingService.combinedFileMapContent(
            fileTreeContent: nil,
            codemapBlocks: codemapBlocks
        ) {
            sections.append("""
            <file_map>
            \(fileMap)
            </file_map>
            """)
        }
        if !contentBlocks.isEmpty {
            sections.append("""
            <file_contents>
            \(contentBlocks.joined(separator: "\n\n"))
            </file_contents>
            """)
        }
        return sections.joined(separator: "\n\n")
    }
}
