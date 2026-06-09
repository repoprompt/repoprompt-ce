import Foundation

enum AgentProviderContextBuilder {
    typealias AccountingOperation = (PromptContextAccountingRequest, WorkspaceFileContextStore) async throws -> PromptContextAccountingResult

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
        accountingOperation: AccountingOperation? = nil,
        overTokenCapSummaryProvider: ((StoredSelection, WorkspaceLookupContext) async -> String?)? = nil
    ) async -> String {
        let physicalSelection = lookupContext.physicalizeSelection(logicalSelection)
        let request = PromptContextAccountingRequest(
            selection: physicalSelection,
            codeMapUsage: .auto,
            filePathDisplay: .relative,
            rootScope: lookupContext.rootScope,
            pathLocateProfile: .uiAssisted
        )
        let accounting: PromptContextAccountingResult
        do {
            if let accountingOperation {
                accounting = try await accountingOperation(request, store)
            } else {
                let accountingService = PromptContextAccountingService()
                accounting = try await accountingService.calculatePromptStats(request: request, store: store)
            }
        } catch {
            return ""
        }

        let entries = accounting.resolvedEntries
        let selectionTokens = accounting.tokenResult.totalTokenCountFilesOnly
        let codemapSnapshots = await store.codemapSnapshotDictionary()

        if selectionTokens > tokenCap {
            if let summary = await overTokenCapSummaryProvider?(logicalSelection, lookupContext),
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return summary
            }
            return "<selection_summary>\(entries.count) files, ~\(selectionTokens) tokens (contents omitted, exceeds \(tokenCap) token cap)</selection_summary>"
        }

        let blocks = PromptPackagingService.generateFileContents(
            entries,
            filePathDisplay: .relative,
            codemapSnapshots: codemapSnapshots,
            displayPathResolver: { entry in
                lookupContext.bindingProjection?.projectedLogicalDisplayPath(
                    forPhysicalPath: entry.file.standardizedFullPath,
                    display: .relative
                )
            }
        )
        guard !blocks.isEmpty else { return "" }
        return """
        <file_contents>
        \(blocks.joined(separator: "\n\n"))
        </file_contents>
        """
    }
}
