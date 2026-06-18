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
        let rawFileTreeSnapshot = await store.makeFileTreeSelectionSnapshot(
            selection: physicalSelection,
            request: WorkspaceFileTreeSnapshotRequest(
                mode: .auto,
                filePathDisplay: filePathDisplay,
                onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
                includeLegend: true,
                showCodeMapMarkers: showCodeMapMarkers,
                rootScope: lookupContext.rootScope
            ),
            profile: .uiAssisted
        )
        let fileTreeSnapshot = lookupContext.bindingProjection?.logicalizeFileTreeSnapshot(rawFileTreeSnapshot) ?? rawFileTreeSnapshot
        return CodeMapExtractor.generateFileTree(using: fileTreeSnapshot)
    }

    static func forkFileContentsBlock(
        selection logicalSelection: StoredSelection,
        tokenCap: Int,
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext,
        overTokenCapSummaryProvider: ((StoredSelection, WorkspaceLookupContext, WorkspaceCodemapSnapshotBundle) async -> String?)? = nil
    ) async -> String {
        let physicalSelection = lookupContext.physicalizeSelection(logicalSelection)
        let accountingService = PromptContextAccountingService()
        let request = PromptContextAccountingRequest(
            selection: physicalSelection,
            codeMapUsage: .auto,
            filePathDisplay: .relative,
            rootScope: lookupContext.rootScope,
            pathLocateProfile: .uiAssisted
        )
        let displayPathResolver: (ResolvedPromptFileEntry) -> String? = { entry in
            lookupContext.bindingProjection?.projectedLogicalDisplayPath(
                forPhysicalPath: entry.file.standardizedFullPath,
                display: .relative
            )
        }
        let accounting = await accountingService.calculatePromptStats(
            request: request,
            store: store,
            codemapDisplayPathResolver: displayPathResolver
        )
        let entries = accounting.resolvedEntries
        let selectionTokens = accounting.tokenResult.totalTokenCountFilesOnly
            + accounting.tokenResult.codeMapTokenCount
        let codemapSnapshotBundle = accounting.codemapSnapshotBundle

        if selectionTokens > tokenCap {
            if let summary = await overTokenCapSummaryProvider?(
                logicalSelection,
                lookupContext,
                codemapSnapshotBundle
            ),
                !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return summary
            }
            return "<selection_summary>\(entries.count) files, ~\(selectionTokens) tokens (contents omitted, exceeds \(tokenCap) token cap)</selection_summary>"
        }

        let renderableEntries = entries.filter { entry in
            !entry.isCodemap || codemapSnapshotBundle.hasRenderableCodemap(for: entry.file)
        }
        let (codemapBlocks, contentBlocks) = PromptPackagingService.generatePartitionedFileBlocks(
            renderableEntries,
            filePathDisplay: .relative,
            codemapSnapshotBundle: codemapSnapshotBundle,
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
