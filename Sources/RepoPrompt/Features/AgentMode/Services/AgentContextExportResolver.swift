import Foundation

struct AgentContextExportSource: Equatable {
    let tabID: UUID?
    let promptText: String
    let selection: StoredSelection
    let selectedMetaPromptIDs: [UUID]
    let tabName: String?
    let activeAgentSessionID: UUID?
    let worktreeBindings: [AgentSessionWorktreeBinding]

    var hasWorktreeBindings: Bool {
        activeAgentSessionID != nil && !worktreeBindings.isEmpty
    }

    var exportContextIdentity: AgentContextExportIdentity {
        AgentContextExportIdentity(
            tabID: tabID,
            selection: selection,
            activeAgentSessionID: activeAgentSessionID,
            worktreeBindingFingerprint: Self.worktreeBindingFingerprint(worktreeBindings)
        )
    }

    static func worktreeBindingFingerprint(_ bindings: [AgentSessionWorktreeBinding]) -> String {
        AgentWorkspaceLookupContextSource.worktreeBindingFingerprint(bindings)
    }
}

struct AgentContextExportIdentity: Equatable {
    let tabID: UUID?
    let selection: StoredSelection
    let activeAgentSessionID: UUID?
    let worktreeBindingFingerprint: String
}

struct AgentContextSelectionSummary: Equatable {
    let totalExplicitFileCount: Int
    let fullFileCount: Int
    let slicedFileCount: Int
    let sliceRangeCount: Int

    var headlineText: String {
        let fileText = "\(totalExplicitFileCount) file\(totalExplicitFileCount == 1 ? "" : "s")"
        guard slicedFileCount > 0 else { return fileText }
        let rangeText = "\(sliceRangeCount) range\(sliceRangeCount == 1 ? "" : "s")"
        return "\(fileText) · \(slicedFileCount) sliced · \(rangeText)"
    }
}

struct AgentContextExportSourceBuildRequest {
    let requestedTabID: UUID?
    let activeComposeTabID: UUID?
    let activePromptText: String
    let selectionSnapshot: WorkspaceSelectionCoordinator.Snapshot?
    let composeTabs: [ComposeTabState]
    let explicitActiveAgentSessionID: UUID?
    let worktreeBindingsProvider: (UUID, UUID?) -> [AgentSessionWorktreeBinding]
}

enum AgentContextExportSourceBuilder {
    static func makeSource(_ request: AgentContextExportSourceBuildRequest) -> AgentContextExportSource {
        let resolvedTabID = request.requestedTabID
            ?? request.selectionSnapshot?.tabID
            ?? request.activeComposeTabID
        let tab = resolvedTabID.flatMap { tabID in
            request.composeTabs.first { $0.id == tabID }
        }
        let selectionSnapshotApplies = request.selectionSnapshot?.tabID == resolvedTabID
        let selection = selectionSnapshotApplies
            ? request.selectionSnapshot?.selection ?? StoredSelection()
            : tab?.selection ?? StoredSelection()
        let promptText = resolvedTabID == request.activeComposeTabID
            ? request.activePromptText
            : tab?.promptText ?? request.activePromptText
        let sessionID = request.explicitActiveAgentSessionID ?? tab?.activeAgentSessionID
        let bindings = sessionID.map { request.worktreeBindingsProvider($0, resolvedTabID) } ?? []

        return AgentContextExportSource(
            tabID: resolvedTabID,
            promptText: promptText,
            selection: selection,
            selectedMetaPromptIDs: tab?.selectedMetaPromptIDs ?? [],
            tabName: tab?.name,
            activeAgentSessionID: sessionID,
            worktreeBindings: bindings
        )
    }
}

struct AgentContextExportModel: Equatable {
    let source: AgentContextExportSource
    let lookupContext: WorkspaceLookupContext
    let rows: [AgentContextExportRow]
    let missingPaths: [String]
    let invalidPaths: [String]
    let codemapPresentation: WorkspaceCodemapOperationPresentation

    var fileCount: Int {
        rows.count
    }

    var codemapCoverage: WorkspaceCodemapOperationPresentationCoverage {
        codemapPresentation.coverage
    }

    var codemapIssues: [WorkspaceCodemapOperationIssue] {
        codemapPresentation.issues
    }
}

struct AgentContextExportRow: Identifiable, Equatable {
    enum Kind: Int, Equatable {
        case codemap = 0
        case slices = 1
        case full = 2

        var iconName: String {
            switch self {
            case .codemap: "square.grid.2x2"
            case .slices: "scissors"
            case .full: "doc.text"
            }
        }

        var badgeText: String? {
            switch self {
            case .codemap: "Codemap"
            case .slices: "Slices"
            case .full: nil
            }
        }
    }

    let id: ResolvedPromptFileEntryID
    let kind: Kind
    let rootID: UUID
    let relativePath: String
    let displayPath: String
    let displayName: String
    let directoryDisplay: String?
    let lineRanges: [LineRange]?
    let canRemove: Bool
    let removesAutomaticSourceIntent: Bool

    init(
        id: ResolvedPromptFileEntryID,
        kind: Kind,
        rootID: UUID,
        relativePath: String,
        displayPath: String,
        displayName: String,
        directoryDisplay: String?,
        lineRanges: [LineRange]?,
        canRemove: Bool,
        removesAutomaticSourceIntent: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.rootID = rootID
        self.relativePath = relativePath
        self.displayPath = displayPath
        self.displayName = displayName
        self.directoryDisplay = directoryDisplay
        self.lineRanges = lineRanges
        self.canRemove = canRemove
        self.removesAutomaticSourceIntent = removesAutomaticSourceIntent
    }
}

extension AgentContextExportRow {
    enum ContentPurpose {
        case preview
        case copy
    }
}

enum AgentContextPreviewContentPolicy {
    static let maximumBytes = 256_000
    static let maximumCharacters = 200_000

    static func boundedPreviewText(_ text: String, wasTruncated: Bool = false) -> String {
        let exceedsCharacterLimit = text.count > maximumCharacters
        guard wasTruncated || exceedsCharacterLimit else { return text }
        let preview = exceedsCharacterLimit ? String(text.prefix(maximumCharacters)) : text
        return """
        \(preview)

        … Preview truncated to avoid retaining large file content. Copy the file content for the full text.
        """
    }
}

struct AgentContextClipboardRequest {
    let cfg: PromptContextResolved
    let source: AgentContextExportSource
    let store: WorkspaceFileContextStore
    let lookupContext: WorkspaceLookupContext
    let filePathDisplay: FilePathDisplay
    let onlyIncludeRootsWithSelectedFiles: Bool
    let showCodeMapMarkers: Bool
    let metaInstructions: [MetaInstruction]
    let includeDatetimeInUserInstructions: Bool
    let promptSectionsOrder: [PromptSection]
    let disabledPromptSections: Set<PromptSection>
    let duplicateUserInstructionsAtTop: Bool
    let reviewGitContext: FrozenPromptGitReviewContext
    let completeGitDiffProvider: () async -> String
}

typealias AgentCodemapPresentationPlan = WorkspaceCodemapOperationPresentationPlan

enum AgentContextExportResolver {
    private struct RowResolutionEntry {
        let entry: ResolvedPromptFileEntry
        let canRemove: Bool
        let removesAutomaticSourceIntent: Bool
    }

    private struct RowResolution {
        let rows: [RowResolutionEntry]
        let selectedFileIDs: Set<UUID>
        let missingPaths: [String]
        let invalidPaths: [String]
    }

    static func selectionSummary(for selection: StoredSelection) -> AgentContextSelectionSummary {
        var explicitFileKeys = Set(selection.selectedPaths.map(normalizedSelectionKey))
        var slicedFileKeys = Set<String>()
        var sliceRangeCount = 0

        for (path, ranges) in selection.slices where !ranges.isEmpty {
            let key = normalizedSelectionKey(path)
            explicitFileKeys.insert(key)
            slicedFileKeys.insert(key)
            sliceRangeCount += ranges.count
        }

        return AgentContextSelectionSummary(
            totalExplicitFileCount: explicitFileKeys.count,
            fullFileCount: explicitFileKeys.count - slicedFileKeys.count,
            slicedFileCount: slicedFileKeys.count,
            sliceRangeCount: sliceRangeCount
        )
    }

    static func explicitSelectionFileCount(_ selection: StoredSelection) -> Int {
        selectionSummary(for: selection).totalExplicitFileCount
    }

    static func displayFileCount(
        resolvedModel _: AgentContextExportModel?,
        sourceSelection: StoredSelection
    ) -> Int {
        selectionSummary(for: sourceSelection).totalExplicitFileCount
    }

    static func lookupContext(
        source: AgentContextExportSource,
        store: WorkspaceFileContextStore
    ) async -> WorkspaceLookupContext {
        await AgentWorkspaceLookupContextResolver.lookupContext(
            source: AgentWorkspaceLookupContextSource(
                activeAgentSessionID: source.activeAgentSessionID,
                worktreeBindings: source.worktreeBindings
            ),
            store: store
        )
    }

    static func resolveModel(
        source: AgentContextExportSource,
        store: WorkspaceFileContextStore,
        filePathDisplay: FilePathDisplay,
        codeMapUsage: CodeMapUsage,
        presentationCoordinator: WorkspaceCodemapPresentationCoordinator? = nil
    ) async -> AgentContextExportModel {
        let lookupContext = await lookupContext(source: source, store: store)
        let physicalSelection = lookupContext.physicalizeSelection(source.selection)
        let resolution = await resolveRows(
            selection: physicalSelection,
            store: store,
            rootScope: lookupContext.rootScope,
            profile: .uiAssisted
        )
        let roots = await store.rootRefs(scope: lookupContext.rootScope)
        var filesByID: [UUID: WorkspaceFileRecord] = [:]
        for root in roots {
            for file in await store.files(inRoot: root.id) {
                filesByID[file.id] = file
            }
        }
        let presentationPlan = await WorkspaceCodemapPresentationIntentResolver.plan(
            codeMapUsage: codeMapUsage,
            selection: physicalSelection,
            store: store,
            rootScope: lookupContext.rootScope,
            profile: .uiAssisted
        )
        let logicalRootDisplayNames = await lookupContext.logicalRootDisplayNamesByRootID(store: store)
        let coordinator = presentationCoordinator ?? WorkspaceCodemapPresentationCoordinator(store: store)
        do {
            return try await coordinator.withPresentation(
                for: presentationPlan.intent,
                rootScope: lookupContext.rootScope,
                logicalRootDisplayNamesByRootID: logicalRootDisplayNames
            ) { presentation in
                let presentation = merging(
                    presentation,
                    preflightIssues: presentationPlan.preflightIssues
                )
                return makeModel(
                    source: source,
                    lookupContext: lookupContext,
                    resolution: resolution,
                    roots: roots,
                    filesByID: filesByID,
                    filePathDisplay: filePathDisplay,
                    codeMapUsage: codeMapUsage,
                    codemapPresentation: presentation,
                    logicalRootDisplayNamesByRootID: logicalRootDisplayNames
                )
            }
        } catch {
            let issue: WorkspaceCodemapOperationIssue = if Task.isCancelled || error is CancellationError {
                .cancelled
            } else {
                .coordinationUnavailable
            }
            let presentation = merging(
                unavailablePresentation(issue),
                preflightIssues: presentationPlan.preflightIssues
            )
            return makeModel(
                source: source,
                lookupContext: lookupContext,
                resolution: resolution,
                roots: roots,
                filesByID: filesByID,
                filePathDisplay: filePathDisplay,
                codeMapUsage: codeMapUsage,
                codemapPresentation: presentation,
                logicalRootDisplayNamesByRootID: logicalRootDisplayNames
            )
        }
    }

    static func buildClipboardContent(_ request: AgentContextClipboardRequest) async -> String {
        let physicalSelection = request.lookupContext.physicalizeSelection(request.source.selection)
        let rootScope = request.lookupContext.rootScope.excludingWorkspaceGitData
        let presentationPlan = await codemapPresentationPlan(
            codeMapUsage: request.cfg.codeMapUsage,
            selection: physicalSelection,
            store: request.store,
            rootScope: rootScope,
            profile: .uiAssisted
        )
        do {
            return try await WorkspaceCodemapPresentationCoordinator(store: request.store).withPresentation(
                for: presentationPlan.intent,
                rootScope: rootScope,
                logicalRootDisplayNamesByRootID: request.lookupContext.logicalRootDisplayNamesByRootID(
                    store: request.store
                )
            ) { presentation in
                await assembleClipboardContent(
                    request,
                    codemapPresentation: merging(
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
            return await assembleClipboardContent(
                request,
                codemapPresentation: merging(
                    unavailablePresentation(issue),
                    preflightIssues: presentationPlan.preflightIssues
                )
            )
        }
    }

    static func loadRowContent(
        for row: AgentContextExportRow,
        model: AgentContextExportModel,
        store: WorkspaceFileContextStore,
        purpose: AgentContextExportRow.ContentPurpose
    ) async -> String? {
        switch row.kind {
        case .codemap:
            guard let entry = model.codemapPresentation.renderedEntriesByFileID[row.id.fileID],
                  entry.rootEpoch.rootID == row.rootID,
                  !entry.text.isEmpty
            else { return nil }
            let text = entry.text
            return purpose == .preview ? AgentContextPreviewContentPolicy.boundedPreviewText(text) : text
        case .full:
            if purpose == .preview {
                guard let prefix = try? await store.readContentPrefix(
                    rootID: row.rootID,
                    relativePath: row.relativePath,
                    maximumBytes: AgentContextPreviewContentPolicy.maximumBytes
                ) else {
                    return nil
                }
                return AgentContextPreviewContentPolicy.boundedPreviewText(
                    prefix.content,
                    wasTruncated: prefix.truncated
                )
            }
            return try? await store.readContent(rootID: row.rootID, relativePath: row.relativePath)
        case .slices:
            guard let content = try? await store.readContent(rootID: row.rootID, relativePath: row.relativePath) else {
                return nil
            }
            let renderedContent: String = if let ranges = row.lineRanges, !ranges.isEmpty {
                SliceAssemblyBuilder.build(from: content, ranges: ranges).combinedText
            } else {
                content
            }
            return purpose == .preview ? AgentContextPreviewContentPolicy.boundedPreviewText(renderedContent) : renderedContent
        }
    }

    static func removeRow(
        _ row: AgentContextExportRow,
        from selection: StoredSelection,
        lookupContext: WorkspaceLookupContext,
        store: WorkspaceFileContextStore
    ) async -> StoredSelection {
        let originalKeys = Array(Set(
            selection.selectedPaths + selection.manualCodemapPaths + selection.slices.keys
        ))
        let physicalKeysByOriginal = Dictionary(uniqueKeysWithValues: originalKeys.map {
            ($0, physicalizedKey($0, lookupContext: lookupContext))
        })
        let requests = Set(physicalKeysByOriginal.values).map { physical in
            WorkspacePathLookupRequest(
                userPath: physical,
                profile: .uiAssisted,
                rootScope: lookupContext.rootScope
            )
        }
        let results = await store.lookupPaths(requests)
        let removedKeys = Set(originalKeys.filter { original in
            guard let physical = physicalKeysByOriginal[original] else { return false }
            return results[physical]?.file?.id == row.id.fileID
        })
        let selectedPaths = selection.selectedPaths.filter { !removedKeys.contains($0) }
        let manualCodemapPaths = selection.manualCodemapPaths.filter { !removedKeys.contains($0) }
        let slices = selection.slices.filter { path, ranges in
            !ranges.isEmpty && !removedKeys.contains(path)
        }
        return StoredSelection(
            selectedPaths: selectedPaths,
            manualCodemapPaths: manualCodemapPaths,
            slices: slices,
            codemapAutoEnabled: row.removesAutomaticSourceIntent && removedKeys.isEmpty
                ? false
                : selection.codemapAutoEnabled
        )
    }

    static func removeSelectionSnapshot(_ snapshot: StoredSelection, from selection: StoredSelection) -> StoredSelection {
        let selectedSnapshotKeys = Set(snapshot.selectedPaths.map(normalizedSelectionKey))
        let manualSnapshotKeys = Set(snapshot.manualCodemapPaths.map(normalizedSelectionKey))
        let sliceSnapshotKeys = Set(snapshot.slices.keys.map(normalizedSelectionKey))
        let selectedPaths = selection.selectedPaths.filter { !selectedSnapshotKeys.contains(normalizedSelectionKey($0)) }
        let manualCodemapPaths = selection.manualCodemapPaths.filter {
            !manualSnapshotKeys.contains(normalizedSelectionKey($0))
        }
        let slices = selection.slices.filter { path, ranges in
            !ranges.isEmpty && !sliceSnapshotKeys.contains(normalizedSelectionKey(path))
        }
        return StoredSelection(
            selectedPaths: selectedPaths,
            manualCodemapPaths: manualCodemapPaths,
            slices: slices,
            codemapAutoEnabled: selection.codemapAutoEnabled
        )
    }

    static func codemapPresentationPlan(
        codeMapUsage: CodeMapUsage,
        selection: StoredSelection,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        profile: PathLocateProfile
    ) async -> AgentCodemapPresentationPlan {
        await WorkspaceCodemapPresentationIntentResolver.plan(
            codeMapUsage: codeMapUsage,
            selection: selection,
            store: store,
            rootScope: rootScope,
            profile: profile
        )
    }

    static func merging(
        _ presentation: WorkspaceCodemapOperationPresentation,
        preflightIssues: [WorkspaceCodemapOperationIssue]
    ) -> WorkspaceCodemapOperationPresentation {
        WorkspaceCodemapPresentationIntentResolver.merging(
            presentation,
            preflightIssues: preflightIssues
        )
    }

    private static func makeModel(
        source: AgentContextExportSource,
        lookupContext: WorkspaceLookupContext,
        resolution: RowResolution,
        roots: [WorkspaceRootRef],
        filesByID: [UUID: WorkspaceFileRecord],
        filePathDisplay: FilePathDisplay,
        codeMapUsage: CodeMapUsage,
        codemapPresentation: WorkspaceCodemapOperationPresentation,
        logicalRootDisplayNamesByRootID: [UUID: String]
    ) -> AgentContextExportModel {
        var rowEntries = resolution.rows
        if codeMapUsage == .selected {
            rowEntries = rowEntries.map { rowEntry in
                guard let rendered = codemapPresentation.renderedEntriesByFileID[rowEntry.entry.file.id],
                      rendered.rootEpoch.rootID == rowEntry.entry.file.rootID
                else { return rowEntry }
                return RowResolutionEntry(
                    entry: ResolvedPromptFileEntry(
                        file: rowEntry.entry.file,
                        isCodemap: true,
                        mode: .codemap,
                        loadedContent: nil,
                        rootFolderPath: rowEntry.entry.rootFolderPath
                    ),
                    canRemove: rowEntry.canRemove,
                    removesAutomaticSourceIntent: rowEntry.removesAutomaticSourceIntent
                )
            }
        } else if codeMapUsage == .auto || codeMapUsage == .complete {
            var seenIDs = Set(rowEntries.map(\.entry.id))
            for rendered in codemapPresentation.orderedEntries {
                guard !resolution.selectedFileIDs.contains(rendered.fileID),
                      let file = filesByID[rendered.fileID],
                      file.rootID == rendered.rootEpoch.rootID
                else { continue }
                let rootPath = roots.first(where: { $0.id == file.rootID })?.standardizedFullPath
                append(
                    ResolvedPromptFileEntry(
                        file: file,
                        isCodemap: true,
                        mode: .codemap,
                        loadedContent: nil,
                        rootFolderPath: rootPath
                    ),
                    canRemove: codeMapUsage == .auto,
                    removesAutomaticSourceIntent: codeMapUsage == .auto,
                    to: &rowEntries,
                    seenIDs: &seenIDs
                )
            }
        }
        let rows = rowEntries.map { rowEntry in
            row(
                from: rowEntry.entry,
                roots: roots,
                lookupContext: lookupContext,
                logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID,
                filePathDisplay: filePathDisplay,
                canRemove: rowEntry.canRemove,
                removesAutomaticSourceIntent: rowEntry.removesAutomaticSourceIntent
            )
        }
        .sorted(by: rowSort)
        return AgentContextExportModel(
            source: source,
            lookupContext: lookupContext,
            rows: rows,
            missingPaths: logicalizedIssuePaths(
                resolution.missingPaths,
                roots: roots,
                lookupContext: lookupContext,
                logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
            ),
            invalidPaths: logicalizedIssuePaths(
                resolution.invalidPaths,
                roots: roots,
                lookupContext: lookupContext,
                logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
            ),
            codemapPresentation: codemapPresentation
        )
    }

    static func unavailablePresentation(
        _ issue: WorkspaceCodemapOperationIssue
    ) -> WorkspaceCodemapOperationPresentation {
        WorkspaceCodemapOperationPresentation(
            orderedEntries: [],
            coverage: .unavailable([issue]),
            issues: [issue],
            publicationReceipt: nil
        )
    }

    private static func assembleClipboardContent(
        _ request: AgentContextClipboardRequest,
        codemapPresentation: WorkspaceCodemapOperationPresentation
    ) async -> String {
        let cfg = request.cfg
        let coordinator = AutomaticReviewGitDiffCoordinator()
        let preAssembly = await PromptContextPreAssemblyService.resolve(
            PromptContextPreAssemblyRequest(
                cfg: cfg,
                selection: request.source.selection,
                store: request.store,
                lookupContext: request.lookupContext,
                filePathDisplay: request.filePathDisplay,
                onlyIncludeRootsWithSelectedFiles: request.onlyIncludeRootsWithSelectedFiles,
                showCodeMapMarkers: request.showCodeMapMarkers,
                selectedGitDiffFolderPolicy: .filesOnly,
                selectedGitDiffLookupProfile: .mcpSelection,
                selectedGitDiffArtifactPolicy: .respectGitInclusion,
                reviewGitContext: request.reviewGitContext,
                selectedGitDiffProvider: { automaticRequest in
                    await coordinator.resolve(automaticRequest)
                },
                completeGitDiffProvider: {
                    await request.completeGitDiffProvider()
                }
            ),
            codemapPresentation: codemapPresentation
        )

        return await PromptPackagingService.generateClipboardContent(
            metaInstructions: request.metaInstructions,
            userInstructions: cfg.includeUserPrompt ? request.source.promptText : "",
            files: preAssembly.entries,
            fileTreeContent: preAssembly.fileTreeContent,
            gitDiff: preAssembly.gitDiff,
            includeSavedPrompts: !request.metaInstructions.isEmpty,
            includeFiles: cfg.includeFiles,
            includeUserPrompt: cfg.includeUserPrompt,
            filePathDisplay: request.filePathDisplay,
            codemapPresentation: preAssembly.codemapPresentation,
            includeDatetimeInUserInstructions: request.includeDatetimeInUserInstructions,
            promptSectionsOrder: request.promptSectionsOrder,
            disabledPromptSections: request.disabledPromptSections,
            duplicateUserInstructionsAtTop: request.duplicateUserInstructionsAtTop,
            displayPathResolver: { entry in
                preAssembly.displayPath(for: entry)
            }
        )
    }

    private static func resolveRows(
        selection: StoredSelection,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        profile: PathLocateProfile
    ) async -> RowResolution {
        var rows: [RowResolutionEntry] = []
        var missingPaths: [String] = []
        var invalidPaths: [String] = []
        var seenIDs = Set<ResolvedPromptFileEntryID>()
        var selectedFileIDs = Set<UUID>()

        let selectedRequests = selection.selectedPaths.map {
            WorkspacePathLookupRequest(userPath: $0, profile: profile, rootScope: rootScope)
        }
        let selectedLookupResults = await store.lookupPaths(selectedRequests)

        for path in selection.selectedPaths {
            let result = await selectedLookupResult(
                for: path,
                batchedResults: selectedLookupResults,
                store: store,
                profile: profile,
                rootScope: rootScope
            )
            guard let result else {
                if await appendDirectoryRows(
                    for: path,
                    store: store,
                    rootScope: rootScope,
                    selectedFileIDs: &selectedFileIDs,
                    rows: &rows,
                    seenIDs: &seenIDs
                ) {
                    continue
                }
                missingPaths.append(path)
                continue
            }

            if let file = result.file {
                selectedFileIDs.insert(file.id)
                let ranges = sliceRanges(for: path, file: file, location: result.location, in: selection.slices)
                let entry = ResolvedPromptFileEntry(
                    file: file,
                    lineRanges: ranges,
                    mode: (ranges?.isEmpty == false) ? .sliced : .fullFile,
                    loadedContent: nil,
                    rootFolderPath: result.location.rootPath
                )
                append(entry, canRemove: true, to: &rows, seenIDs: &seenIDs)
            } else if let folder = result.folder {
                let files = await store.files(inRoot: folder.rootID)
                let prefix = folder.standardizedRelativePath
                for file in files where prefix.isEmpty || file.standardizedRelativePath == prefix || file.standardizedRelativePath.hasPrefix(prefix + "/") {
                    selectedFileIDs.insert(file.id)
                    let entry = ResolvedPromptFileEntry(
                        file: file,
                        mode: .fullFile,
                        loadedContent: nil,
                        rootFolderPath: result.location.rootPath
                    )
                    append(entry, canRemove: false, to: &rows, seenIDs: &seenIDs)
                }
            } else {
                invalidPaths.append(path)
            }
        }

        let orderedSlicePaths = selection.slices.keys.sorted(by: utf8Precedes)
        let slicePaths = orderedSlicePaths.filter { path in
            selection.slices[path]?.isEmpty == false && selectedLookupResults[path] == nil
        }
        let sliceLookupRequests = slicePaths.map {
            WorkspacePathLookupRequest(userPath: $0, profile: profile, rootScope: rootScope)
        }
        let sliceLookupResults: [String: WorkspacePathLookupResult] = if sliceLookupRequests.isEmpty {
            [:]
        } else {
            await store.lookupPaths(sliceLookupRequests)
        }
        for path in orderedSlicePaths {
            guard let ranges = selection.slices[path], !ranges.isEmpty else { continue }
            guard let result = selectedLookupResults[path] ?? sliceLookupResults[path] else {
                missingPaths.append(path)
                continue
            }
            guard let file = result.file else {
                invalidPaths.append(path)
                continue
            }
            guard !selectedFileIDs.contains(file.id) else { continue }
            selectedFileIDs.insert(file.id)
            let entry = ResolvedPromptFileEntry(
                file: file,
                lineRanges: ranges,
                mode: .sliced,
                loadedContent: nil,
                rootFolderPath: result.location.rootPath
            )
            append(entry, canRemove: true, to: &rows, seenIDs: &seenIDs)
        }

        return RowResolution(
            rows: rows,
            selectedFileIDs: selectedFileIDs,
            missingPaths: Array(Set(missingPaths)).sorted(),
            invalidPaths: Array(Set(invalidPaths)).sorted()
        )
    }

    private static func row(
        from entry: ResolvedPromptFileEntry,
        roots: [WorkspaceRootRef],
        lookupContext: WorkspaceLookupContext,
        logicalRootDisplayNamesByRootID: [UUID: String],
        filePathDisplay: FilePathDisplay,
        canRemove: Bool,
        removesAutomaticSourceIntent: Bool
    ) -> AgentContextExportRow {
        let displayPath = displayPath(
            for: entry,
            roots: roots,
            lookupContext: lookupContext,
            logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID,
            filePathDisplay: filePathDisplay
        )
        let kind: AgentContextExportRow.Kind = if entry.isCodemap {
            .codemap
        } else if entry.lineRanges?.isEmpty == false {
            .slices
        } else {
            .full
        }
        let displayName = URL(fileURLWithPath: displayPath).lastPathComponent
        let fallbackRootName = logicalRootDisplayNamesByRootID[entry.file.rootID]
        let directory = directoryDisplay(for: displayPath, fallbackRootName: fallbackRootName)
        return AgentContextExportRow(
            id: entry.id,
            kind: kind,
            rootID: entry.file.rootID,
            relativePath: entry.file.standardizedRelativePath,
            displayPath: displayPath,
            displayName: displayName.isEmpty ? entry.file.name : displayName,
            directoryDisplay: directory,
            lineRanges: entry.lineRanges,
            canRemove: canRemove,
            removesAutomaticSourceIntent: removesAutomaticSourceIntent
        )
    }

    private static func displayPath(
        for entry: ResolvedPromptFileEntry,
        roots: [WorkspaceRootRef],
        lookupContext: WorkspaceLookupContext,
        logicalRootDisplayNamesByRootID: [UUID: String],
        filePathDisplay: FilePathDisplay
    ) -> String {
        lookupContext.logicalDisplayPath(
            for: entry.file,
            roots: roots,
            rootDisplayNamesByRootID: logicalRootDisplayNamesByRootID,
            display: filePathDisplay
        ) ?? entry.file.standardizedRelativePath
    }

    private static func directoryDisplay(for displayPath: String, fallbackRootName: String?) -> String? {
        let directory = (displayPath as NSString).deletingLastPathComponent
        if directory != ".", !directory.isEmpty {
            return directory
        }
        guard let fallbackRootName, !fallbackRootName.isEmpty else { return nil }
        return fallbackRootName
    }

    private static func logicalizedIssuePaths(
        _ paths: [String],
        roots: [WorkspaceRootRef],
        lookupContext: WorkspaceLookupContext,
        logicalRootDisplayNamesByRootID: [UUID: String]
    ) -> [String] {
        Array(Set(paths.map { path in
            if let projected = lookupContext.bindingProjection?.projectedLogicalDisplayPath(
                forPhysicalPath: path,
                display: .relative
            ) {
                return projected
            }
            let absolute = StandardizedPath.absolute(path)
            if path.hasPrefix("/"), let root = roots.first(where: {
                absolute == $0.standardizedFullPath || absolute.hasPrefix($0.standardizedFullPath + "/")
            }), let label = logicalRootDisplayNamesByRootID[root.id] {
                let relative = String(absolute.dropFirst(root.standardizedFullPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return relative.isEmpty ? label : "\(label)/\(relative)"
            }
            return path.hasPrefix("/") ? "unmapped:\(URL(fileURLWithPath: path).lastPathComponent)" : path
        })).sorted()
    }

    private static func rowSort(_ lhs: AgentContextExportRow, _ rhs: AgentContextExportRow) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.displayName != rhs.displayName {
            return lhs.displayName.utf8.lexicographicallyPrecedes(rhs.displayName.utf8)
        }
        if lhs.displayPath != rhs.displayPath {
            return lhs.displayPath.utf8.lexicographicallyPrecedes(rhs.displayPath.utf8)
        }
        if lhs.rootID != rhs.rootID { return lhs.rootID.uuidString < rhs.rootID.uuidString }
        return lhs.id.fileID.uuidString < rhs.id.fileID.uuidString
    }

    private static func appendDirectoryRows(
        for path: String,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        selectedFileIDs: inout Set<UUID>,
        rows: inout [RowResolutionEntry],
        seenIDs: inout Set<ResolvedPromptFileEntryID>
    ) async -> Bool {
        let roots = await store.rootRefs(scope: rootScope)
        var handled = false
        for root in roots {
            guard let relativePrefix = directoryRelativePrefix(path, in: root) else { continue }
            let absoluteDirectory = ((root.standardizedFullPath as NSString).appendingPathComponent(relativePrefix) as NSString).standardizingPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: absoluteDirectory, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            handled = true
            let files = await store.files(inRoot: root.id)
            for file in files where relativePrefix.isEmpty || file.standardizedRelativePath.hasPrefix(relativePrefix + "/") {
                selectedFileIDs.insert(file.id)
                let entry = ResolvedPromptFileEntry(
                    file: file,
                    mode: .fullFile,
                    loadedContent: nil,
                    rootFolderPath: root.standardizedFullPath
                )
                append(entry, canRemove: false, to: &rows, seenIDs: &seenIDs)
            }
        }
        return handled
    }

    private static func directoryRelativePrefix(_ path: String, in root: WorkspaceRootRef) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            let standardized = StandardizedPath.absolute(expanded)
            guard standardized == root.standardizedFullPath || StandardizedPath.isDescendant(standardized, of: root.standardizedFullPath) else { return nil }
            if standardized == root.standardizedFullPath { return "" }
            return StandardizedPath.relative(String(standardized.dropFirst(root.standardizedFullPath.count + 1)))
        }
        return StandardizedPath.relative(expanded)
    }

    private static func selectedLookupResult(
        for path: String,
        batchedResults: [String: WorkspacePathLookupResult],
        store: WorkspaceFileContextStore,
        profile: PathLocateProfile,
        rootScope: WorkspaceLookupRootScope
    ) async -> WorkspacePathLookupResult? {
        if let result = batchedResults[path] { return result }
        return await store.lookupPath(path, profile: profile, rootScope: rootScope)
    }

    private static func sliceRanges(
        for path: String,
        file: WorkspaceFileRecord,
        location: WorkspacePathLocation,
        in slices: [String: [LineRange]]
    ) -> [LineRange]? {
        let candidateKeys = [
            path,
            StandardizedPath.absolute(path),
            file.relativePath,
            file.standardizedRelativePath,
            file.fullPath,
            file.standardizedFullPath,
            location.absolutePath
        ]
        for key in candidateKeys {
            if let ranges = slices[key] { return ranges }
        }
        return nil
    }

    private static func append(
        _ entry: ResolvedPromptFileEntry,
        canRemove: Bool,
        removesAutomaticSourceIntent: Bool = false,
        to rows: inout [RowResolutionEntry],
        seenIDs: inout Set<ResolvedPromptFileEntryID>
    ) {
        guard seenIDs.insert(entry.id).inserted else { return }
        rows.append(RowResolutionEntry(
            entry: entry,
            canRemove: canRemove,
            removesAutomaticSourceIntent: removesAutomaticSourceIntent
        ))
    }

    private static func physicalizedKey(_ path: String, lookupContext: WorkspaceLookupContext) -> String {
        let translated = lookupContext.translateInputPath(path)
        if translated.hasPrefix("/") {
            return StandardizedPath.absolute(translated)
        }
        return StandardizedPath.relative(translated)
    }

    private static func normalizedSelectionKey(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? StandardizedPath.absolute(expanded) : StandardizedPath.relative(expanded)
    }

    private static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
