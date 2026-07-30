import CryptoKit
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

struct AgentContextExportIdentity: Equatable, Hashable {
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

    static func filesOnly(_ count: Int) -> AgentContextSelectionSummary {
        AgentContextSelectionSummary(
            totalExplicitFileCount: count,
            fullFileCount: count,
            slicedFileCount: 0,
            sliceRangeCount: 0
        )
    }

    var compactText: String {
        fileCountText
    }

    var headlineText: String {
        guard let sliceCountText else { return fileCountText }
        return "\(fileCountText) · \(sliceCountText)"
    }

    private var fileCountText: String {
        "\(totalExplicitFileCount) file\(totalExplicitFileCount == 1 ? "" : "s")"
    }

    private var sliceCountText: String? {
        guard sliceRangeCount > 0 else { return nil }
        return "\(sliceRangeCount) slice\(sliceRangeCount == 1 ? "" : "s")"
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
    let directContentPath: String?
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
        directContentPath: String? = nil,
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
        self.directContentPath = directContentPath
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

    private struct PresentationAuthoritySnapshot {
        let lookupContext: WorkspaceLookupContext
        let physicalSelection: StoredSelection
        let rootScope: WorkspaceLookupRootScope
        let roots: [WorkspaceRootRef]
        let logicalRootDisplayNamesByRootID: [UUID: String]
        let presentationPlan: AgentCodemapPresentationPlan
    }

    private struct ModelPresentationAttempt {
        let authority: PresentationAuthoritySnapshot
        let resolution: RowResolution
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

    private static func selectionNeedsResolution(_ selection: StoredSelection, codeMapUsage: CodeMapUsage) -> Bool {
        if !selection.selectedPaths.isEmpty { return true }
        if selection.slices.contains(where: { !$0.value.isEmpty }) { return true }
        switch codeMapUsage {
        case .auto:
            return !selection.manualCodemapPaths.isEmpty
        case .complete:
            return true
        case .none, .selected:
            return false
        }
    }

    static func lookupContext(
        source: AgentContextExportSource,
        store: WorkspaceFileContextStore
    ) async -> WorkspaceLookupContext {
        let startMS = AgentSelectedFilesDiagnostics.timestampMSIfEnabled()
        AgentSelectedFilesDiagnostics.event("resolver.lookupContext.start", fields: AgentSelectedFilesDiagnostics.sourceFields(source))
        let context = await AgentWorkspaceLookupContextResolver.lookupContext(
            source: AgentWorkspaceLookupContextSource(
                activeAgentSessionID: source.activeAgentSessionID,
                worktreeBindings: source.worktreeBindings
            ),
            store: store
        )
        var fields = AgentSelectedFilesDiagnostics.sourceFields(source)
        fields["rootScope"] = String(describing: context.rootScope)
        fields["hasProjection"] = String(context.bindingProjection != nil)
        AgentSelectedFilesDiagnostics.durationEvent("resolver.lookupContext", startMS: startMS, fields: fields)
        return context
    }

    static func resolveModel(
        source: AgentContextExportSource,
        store: WorkspaceFileContextStore,
        filePathDisplay: FilePathDisplay,
        codeMapUsage: CodeMapUsage,
        presentationCoordinator: WorkspaceCodemapPresentationCoordinator? = nil
    ) async -> AgentContextExportModel {
        let totalStartMS = AgentSelectedFilesDiagnostics.timestampMSIfEnabled()
        var startFields = AgentSelectedFilesDiagnostics.sourceFields(source)
        startFields["filePathDisplay"] = String(describing: filePathDisplay)
        startFields["codeMapUsage"] = String(describing: codeMapUsage)
        AgentSelectedFilesDiagnostics.event("resolver.resolveModel.start", fields: startFields)
        guard selectionNeedsResolution(source.selection, codeMapUsage: codeMapUsage) else {
            AgentSelectedFilesDiagnostics.durationEvent(
                "resolver.resolveModel.fastEmpty",
                startMS: totalStartMS,
                fields: startFields
            )
            return AgentContextExportModel(
                source: source,
                lookupContext: .visibleWorkspace,
                rows: [],
                missingPaths: [],
                invalidPaths: [],
                codemapPresentation: .empty
            )
        }

        if let displayModel = resolveMetadataOnlyWorktreeModel(
            source: source,
            filePathDisplay: filePathDisplay,
            codeMapUsage: codeMapUsage,
            totalStartMS: totalStartMS,
            fields: startFields
        ) {
            return displayModel
        }

        let coordinator = presentationCoordinator ?? WorkspaceCodemapPresentationCoordinator(store: store)
        do {
            return try await coordinator.withPresentation(
                prepareAttempt: {
                    let attempt = await modelPresentationAttempt(
                        source: source,
                        store: store,
                        codeMapUsage: codeMapUsage
                    )
                    return WorkspaceCodemapPresentationAttempt(
                        context: attempt,
                        intent: attempt.authority.presentationPlan.intent,
                        rootScope: attempt.authority.rootScope,
                        logicalRootDisplayNamesByRootID: attempt.authority.logicalRootDisplayNamesByRootID,
                        requestedCodemapCount: requestedCodemapCount(
                            for: attempt.authority.presentationPlan.intent,
                            codeMapUsage: codeMapUsage
                        )
                    )
                }
            ) { attempt, presentation in
                let presentation = merging(
                    presentation,
                    preflightIssues: attempt.authority.presentationPlan.preflightIssues
                )
                let resolution = await validatedSelectedFallbackResolution(
                    attempt.resolution,
                    presentation: presentation,
                    store: store,
                    codeMapUsage: codeMapUsage
                )
                let codemapFilesByID = await codemapFileRecordsByID(
                    for: presentation,
                    resolution: resolution,
                    roots: attempt.authority.roots,
                    store: store,
                    codeMapUsage: codeMapUsage
                )
                return makeModel(
                    source: source,
                    lookupContext: attempt.authority.lookupContext,
                    resolution: resolution,
                    roots: attempt.authority.roots,
                    codemapFilesByID: codemapFilesByID,
                    filePathDisplay: filePathDisplay,
                    codeMapUsage: codeMapUsage,
                    codemapPresentation: presentation,
                    logicalRootDisplayNamesByRootID: attempt.authority.logicalRootDisplayNamesByRootID
                )
            }
        } catch {
            let issue: WorkspaceCodemapOperationIssue = if Task.isCancelled || error is CancellationError {
                .cancelled
            } else {
                .coordinationUnavailable
            }
            let attempt = await modelPresentationAttempt(
                source: source,
                store: store,
                codeMapUsage: codeMapUsage
            )
            let presentation = merging(
                unavailablePresentation(issue),
                preflightIssues: attempt.authority.presentationPlan.preflightIssues
            )
            let resolution = await validatedSelectedFallbackResolution(
                attempt.resolution,
                presentation: presentation,
                store: store,
                codeMapUsage: codeMapUsage
            )
            let codemapFilesByID = await codemapFileRecordsByID(
                for: presentation,
                resolution: resolution,
                roots: attempt.authority.roots,
                store: store,
                codeMapUsage: codeMapUsage
            )
            return makeModel(
                source: source,
                lookupContext: attempt.authority.lookupContext,
                resolution: resolution,
                roots: attempt.authority.roots,
                codemapFilesByID: codemapFilesByID,
                filePathDisplay: filePathDisplay,
                codeMapUsage: codeMapUsage,
                codemapPresentation: presentation,
                logicalRootDisplayNamesByRootID: attempt.authority.logicalRootDisplayNamesByRootID
            )
        }
    }

    static func buildClipboardContent(
        _ request: AgentContextClipboardRequest,
        presentationCoordinator: WorkspaceCodemapPresentationCoordinator? = nil
    ) async -> String {
        let coordinator = presentationCoordinator ?? WorkspaceCodemapPresentationCoordinator(store: request.store)
        do {
            return try await coordinator.withPresentation(
                prepareAttempt: {
                    let authority = await presentationAuthoritySnapshot(
                        source: request.source,
                        store: request.store,
                        codeMapUsage: request.cfg.codeMapUsage,
                        fallbackLookupContext: request.lookupContext,
                        excludingWorkspaceGitData: true
                    )
                    return WorkspaceCodemapPresentationAttempt(
                        context: authority,
                        intent: authority.presentationPlan.intent,
                        rootScope: authority.rootScope,
                        logicalRootDisplayNamesByRootID: authority.logicalRootDisplayNamesByRootID,
                        requestedCodemapCount: requestedCodemapCount(
                            for: authority.presentationPlan.intent,
                            codeMapUsage: request.cfg.codeMapUsage
                        )
                    )
                }
            ) { authority, presentation in
                await assembleClipboardContent(
                    clipboardRequest(request, lookupContext: authority.lookupContext),
                    codemapPresentation: merging(
                        presentation,
                        preflightIssues: authority.presentationPlan.preflightIssues
                    )
                )
            }
        } catch {
            let issue: WorkspaceCodemapOperationIssue = if Task.isCancelled || error is CancellationError {
                .cancelled
            } else {
                .coordinationUnavailable
            }
            let authority = await presentationAuthoritySnapshot(
                source: request.source,
                store: request.store,
                codeMapUsage: request.cfg.codeMapUsage,
                fallbackLookupContext: request.lookupContext,
                excludingWorkspaceGitData: true
            )
            return await assembleClipboardContent(
                clipboardRequest(request, lookupContext: authority.lookupContext),
                codemapPresentation: merging(
                    unavailablePresentation(issue),
                    preflightIssues: authority.presentationPlan.preflightIssues
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
            if let directContentPath = row.directContentPath {
                return await loadDirectFileContent(
                    path: directContentPath,
                    lineRanges: nil,
                    purpose: purpose
                )
            }
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
            if let directContentPath = row.directContentPath {
                return await loadDirectFileContent(
                    path: directContentPath,
                    lineRanges: row.lineRanges,
                    purpose: purpose
                )
            }
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
        let targetDirectPath = row.directContentPath.map(StandardizedPath.absolute)
        let removedKeys = Set(originalKeys.filter { original in
            guard let physical = physicalKeysByOriginal[original] else { return false }
            if let targetDirectPath, StandardizedPath.absolute(physical) == targetDirectPath {
                return true
            }
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

    private static func authoritativeLookupContext(
        source: AgentContextExportSource,
        store: WorkspaceFileContextStore,
        fallback: WorkspaceLookupContext
    ) async -> WorkspaceLookupContext {
        guard source.hasWorktreeBindings else { return fallback }
        return await AgentWorkspaceLookupContextResolver.authoritativeLookupContextOrFailClosed(
            source: AgentWorkspaceLookupContextSource(
                activeAgentSessionID: source.activeAgentSessionID,
                worktreeBindings: source.worktreeBindings
            ),
            store: store
        )
    }

    private static func presentationAuthoritySnapshot(
        source: AgentContextExportSource,
        store: WorkspaceFileContextStore,
        codeMapUsage: CodeMapUsage,
        fallbackLookupContext: WorkspaceLookupContext,
        excludingWorkspaceGitData: Bool
    ) async -> PresentationAuthoritySnapshot {
        let lookupContext = await authoritativeLookupContext(
            source: source,
            store: store,
            fallback: fallbackLookupContext
        )
        let physicalSelection = lookupContext.physicalizeSelection(source.selection)
        let rootScope = excludingWorkspaceGitData
            ? lookupContext.rootScope.excludingWorkspaceGitData
            : lookupContext.rootScope
        let roots = await store.rootRefs(scope: rootScope)
        let presentationPlan = await codemapPresentationPlan(
            codeMapUsage: codeMapUsage,
            selection: physicalSelection,
            store: store,
            rootScope: rootScope,
            profile: .uiAssisted
        )
        let logicalRootDisplayNamesByRootID = await lookupContext.logicalRootDisplayNamesByRootID(
            store: store
        )
        return PresentationAuthoritySnapshot(
            lookupContext: lookupContext,
            physicalSelection: physicalSelection,
            rootScope: rootScope,
            roots: roots,
            logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID,
            presentationPlan: presentationPlan
        )
    }

    private static func modelPresentationAttempt(
        source: AgentContextExportSource,
        store: WorkspaceFileContextStore,
        codeMapUsage: CodeMapUsage
    ) async -> ModelPresentationAttempt {
        let authority = await presentationAuthoritySnapshot(
            source: source,
            store: store,
            codeMapUsage: codeMapUsage,
            fallbackLookupContext: .visibleWorkspace,
            excludingWorkspaceGitData: false
        )
        let resolution = await resolveRows(
            selection: authority.physicalSelection,
            store: store,
            rootScope: authority.rootScope,
            profile: .uiAssisted
        )
        return ModelPresentationAttempt(authority: authority, resolution: resolution)
    }

    private static func requestedCodemapCount(
        for intent: WorkspaceCodemapOperationPresentationIntent,
        codeMapUsage: CodeMapUsage
    ) -> Int? {
        guard codeMapUsage == .selected else { return nil }
        guard case let .exact(fileIDs, _) = intent else { return 0 }
        return Set(fileIDs).count
    }

    private static func clipboardRequest(
        _ request: AgentContextClipboardRequest,
        lookupContext: WorkspaceLookupContext
    ) -> AgentContextClipboardRequest {
        AgentContextClipboardRequest(
            cfg: request.cfg,
            source: request.source,
            store: request.store,
            lookupContext: lookupContext,
            filePathDisplay: request.filePathDisplay,
            onlyIncludeRootsWithSelectedFiles: request.onlyIncludeRootsWithSelectedFiles,
            showCodeMapMarkers: request.showCodeMapMarkers,
            metaInstructions: request.metaInstructions,
            includeDatetimeInUserInstructions: request.includeDatetimeInUserInstructions,
            promptSectionsOrder: request.promptSectionsOrder,
            disabledPromptSections: request.disabledPromptSections,
            duplicateUserInstructionsAtTop: request.duplicateUserInstructionsAtTop,
            reviewGitContext: request.reviewGitContext,
            completeGitDiffProvider: request.completeGitDiffProvider
        )
    }

    private static func validatedSelectedFallbackResolution(
        _ resolution: RowResolution,
        presentation: WorkspaceCodemapOperationPresentation,
        store: WorkspaceFileContextStore,
        codeMapUsage: CodeMapUsage
    ) async -> RowResolution {
        guard codeMapUsage == .selected else { return resolution }
        guard !Task.isCancelled else {
            return cancelledSelectedFallbackResolution(resolution)
        }
        var rows: [RowResolutionEntry] = []
        rows.reserveCapacity(resolution.rows.count)
        var missingPaths = resolution.missingPaths
        for row in resolution.rows {
            let file = row.entry.file
            if let rendered = presentation.renderedEntriesByFileID[file.id],
               rendered.rootEpoch.rootID == file.rootID
            {
                rows.append(row)
                continue
            }
            do {
                guard try await store.readContent(
                    rootID: file.rootID,
                    relativePath: file.standardizedRelativePath,
                    workloadClass: .promptAccounting
                ) != nil else {
                    missingPaths.append(file.standardizedRelativePath)
                    continue
                }
                rows.append(row)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    return cancelledSelectedFallbackResolution(resolution)
                }
                missingPaths.append(file.standardizedRelativePath)
            }
        }
        return RowResolution(
            rows: rows,
            selectedFileIDs: resolution.selectedFileIDs,
            missingPaths: Array(Set(missingPaths)).sorted(),
            invalidPaths: resolution.invalidPaths
        )
    }

    private static func cancelledSelectedFallbackResolution(
        _ resolution: RowResolution
    ) -> RowResolution {
        RowResolution(
            rows: [],
            selectedFileIDs: resolution.selectedFileIDs,
            missingPaths: resolution.missingPaths,
            invalidPaths: resolution.invalidPaths
        )
    }

    private static func loadDirectFileContent(
        path rawPath: String,
        lineRanges: [LineRange]?,
        purpose: AgentContextExportRow.ContentPurpose
    ) async -> String? {
        let path = StandardizedPath.absolute((rawPath as NSString).expandingTildeInPath)
        return await Task.detached(priority: .userInitiated) {
            switch purpose {
            case .preview where lineRanges?.isEmpty != false:
                guard let file = FileHandle(forReadingAtPath: path) else { return nil }
                defer { try? file.close() }
                let data: Data
                do {
                    data = try file.read(upToCount: AgentContextPreviewContentPolicy.maximumBytes + 1) ?? Data()
                } catch {
                    return nil
                }
                let truncated = data.count > AgentContextPreviewContentPolicy.maximumBytes
                let boundedData = truncated ? data.prefix(AgentContextPreviewContentPolicy.maximumBytes) : data[...]
                let text = Self.decodeText(Data(boundedData))
                return AgentContextPreviewContentPolicy.boundedPreviewText(text, wasTruncated: truncated)
            case .preview, .copy:
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                    return nil
                }
                let content = Self.decodeText(data)
                let renderedContent: String = if let lineRanges, !lineRanges.isEmpty {
                    SliceAssemblyBuilder.build(from: content, ranges: lineRanges).combinedText
                } else {
                    content
                }
                return purpose == .preview
                    ? AgentContextPreviewContentPolicy.boundedPreviewText(renderedContent)
                    : renderedContent
            }
        }.value
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

    private static func resolveMetadataOnlyWorktreeModel(
        source: AgentContextExportSource,
        filePathDisplay: FilePathDisplay,
        codeMapUsage: CodeMapUsage,
        totalStartMS: Double?,
        fields startFields: [String: String]
    ) -> AgentContextExportModel? {
        let startMS = AgentSelectedFilesDiagnostics.timestampMSIfEnabled()
        guard source.hasWorktreeBindings,
              source.worktreeBindings.count >= 1,
              metadataOnlyBindingsAreSafe(source.worktreeBindings),
              codeMapUsage == .none,
              let sessionID = source.activeAgentSessionID
        else { return nil }

        guard let projection = lightweightProjection(
            sessionID: sessionID,
            bindings: source.worktreeBindings
        ) else { return nil }

        let lookupContext = WorkspaceLookupContext(
            rootScope: projection.lookupRootScope,
            bindingProjection: projection
        )
        var rows: [AgentContextExportRow] = []
        var missingPaths: [String] = []
        var invalidPaths: [String] = []
        var seenPhysicalPaths = Set<String>()

        let selectedPaths = source.selection.selectedPaths
        for path in selectedPaths {
            let translatedPath = lookupContext.translateInputPath(path)
            var requiresStoreFallback = false
            guard let row = metadataOnlyRow(
                originalPath: path,
                translatedPath: translatedPath,
                lineRanges: sliceRanges(forOriginalPath: path, translatedPath: translatedPath, selection: source.selection),
                projection: projection,
                filePathDisplay: filePathDisplay,
                missingPaths: &missingPaths,
                invalidPaths: &invalidPaths,
                requiresStoreFallback: &requiresStoreFallback
            ) else {
                if requiresStoreFallback || metadataOnlyPathRequiresStoreFallback(translatedPath, projection: projection) {
                    return nil
                }
                continue
            }
            guard let physicalPath = row.directContentPath,
                  seenPhysicalPaths.insert(physicalPath).inserted
            else { continue }
            rows.append(row)
        }

        for (path, ranges) in source.selection.slices where !ranges.isEmpty && !selectedPaths.contains(where: { normalizedSelectionKey($0) == normalizedSelectionKey(path) }) {
            let translatedPath = lookupContext.translateInputPath(path)
            var requiresStoreFallback = false
            guard let row = metadataOnlyRow(
                originalPath: path,
                translatedPath: translatedPath,
                lineRanges: ranges,
                projection: projection,
                filePathDisplay: filePathDisplay,
                missingPaths: &missingPaths,
                invalidPaths: &invalidPaths,
                requiresStoreFallback: &requiresStoreFallback
            ) else {
                if requiresStoreFallback || metadataOnlyPathRequiresStoreFallback(translatedPath, projection: projection) {
                    return nil
                }
                continue
            }
            guard let physicalPath = row.directContentPath,
                  seenPhysicalPaths.insert(physicalPath).inserted
            else { continue }
            rows.append(row)
        }

        rows.sort(by: rowSort)
        AgentSelectedFilesDiagnostics.durationEvent(
            "resolver.metadataOnlyWorktreeModel",
            startMS: startMS,
            fields: [
                "rowCount": String(rows.count),
                "missingPaths": String(missingPaths.count),
                "invalidPaths": String(invalidPaths.count),
                "bindingCount": String(source.worktreeBindings.count)
            ]
        )
        var completeFields = startFields
        completeFields["rowCount"] = String(rows.count)
        completeFields["missingPaths"] = String(missingPaths.count)
        completeFields["invalidPaths"] = String(invalidPaths.count)
        completeFields["hasProjection"] = "true"
        completeFields["metadataOnly"] = "true"
        AgentSelectedFilesDiagnostics.durationEvent(
            "resolver.resolveModel.complete",
            startMS: totalStartMS,
            fields: completeFields
        )
        return AgentContextExportModel(
            source: source,
            lookupContext: lookupContext,
            rows: rows,
            missingPaths: Array(Set(missingPaths)).sorted(),
            invalidPaths: Array(Set(invalidPaths)).sorted(),
            codemapPresentation: .empty
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
        codemapFilesByID: [UUID: WorkspaceFileRecord],
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
            let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
            for rendered in codemapPresentation.orderedEntries {
                guard !resolution.selectedFileIDs.contains(rendered.fileID),
                      let file = codemapFilesByID[rendered.fileID],
                      file.rootID == rendered.rootEpoch.rootID
                else { continue }
                let rootPath = rootsByID[file.rootID]?.standardizedFullPath
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

    private static func codemapFileRecordsByID(
        for presentation: WorkspaceCodemapOperationPresentation,
        resolution: RowResolution,
        roots: [WorkspaceRootRef],
        store: WorkspaceFileContextStore,
        codeMapUsage: CodeMapUsage
    ) async -> [UUID: WorkspaceFileRecord] {
        guard codeMapUsage == .auto || codeMapUsage == .complete else { return [:] }

        var wantedIDsByRootID: [UUID: Set<UUID>] = [:]
        for rendered in presentation.orderedEntries where !resolution.selectedFileIDs.contains(rendered.fileID) {
            wantedIDsByRootID[rendered.rootEpoch.rootID, default: []].insert(rendered.fileID)
        }
        guard !wantedIDsByRootID.isEmpty else { return [:] }

        let allowedRootIDs = Set(roots.map(\.id))
        let wantedFileCount = wantedIDsByRootID.values.reduce(0) { $0 + $1.count }
        var filesByID: [UUID: WorkspaceFileRecord] = [:]
        var skippedOutOfScopeCount = 0
        for (rootID, wantedIDs) in wantedIDsByRootID {
            guard allowedRootIDs.contains(rootID) else {
                skippedOutOfScopeCount += wantedIDs.count
                continue
            }
            for fileID in wantedIDs {
                guard let file = await store.file(id: fileID), file.rootID == rootID else { continue }
                filesByID[fileID] = file
            }
        }
        AgentSelectedFilesDiagnostics.event(
            "resolver.codemapFileRecords",
            fields: [
                "wantedFiles": String(wantedFileCount),
                "resolvedFiles": String(filesByID.count),
                "skippedOutOfScope": String(skippedOutOfScopeCount)
            ]
        )
        return filesByID
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

    private static func metadataOnlyBindingsAreSafe(_ bindings: [AgentSessionWorktreeBinding]) -> Bool {
        do {
            try AgentWorktreeRuntimeWorkspaceResolver.validateBindingsAvailable(bindings)
        } catch {
            return false
        }
        return bindings.allSatisfy { binding in
            guard let logicalPath = AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath(binding.logicalRootPath),
                  let worktreePath = AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath(binding.worktreeRootPath)
            else { return false }
            return logicalPath != worktreePath
        }
    }

    private static func lightweightProjection(
        sessionID: UUID,
        bindings: [AgentSessionWorktreeBinding]
    ) -> WorkspaceRootBindingProjection? {
        guard !bindings.isEmpty else { return nil }
        let boundRoots = bindings.map { binding in
            let logicalPath = StandardizedPath.absolute((binding.logicalRootPath as NSString).expandingTildeInPath)
            let physicalPath = StandardizedPath.absolute((binding.worktreeRootPath as NSString).expandingTildeInPath)
            let logicalRoot = WorkspaceRootRef(
                id: stableUUID(namespace: "agent-selected-files-logical-root", rawValue: logicalPath),
                name: binding.logicalRootName ?? URL(fileURLWithPath: logicalPath).lastPathComponent,
                fullPath: logicalPath
            )
            let physicalRoot = WorkspaceRootRef(
                id: stableUUID(namespace: "agent-selected-files-physical-root", rawValue: physicalPath),
                name: logicalRoot.name,
                fullPath: physicalPath
            )
            return WorkspaceRootBindingProjection.BoundRoot(
                logicalRoot: logicalRoot,
                physicalRoot: physicalRoot,
                binding: binding,
                sessionRootAuthorization: nil
            )
        }
        return WorkspaceRootBindingProjection(
            sessionID: sessionID,
            boundRoots: boundRoots,
            visibleLogicalRoots: boundRoots.map(\.logicalRoot),
            lookupPhysicalRootPaths: []
        )
    }

    private static func metadataOnlyRow(
        originalPath: String,
        translatedPath: String,
        lineRanges: [LineRange]?,
        projection: WorkspaceRootBindingProjection,
        filePathDisplay: FilePathDisplay,
        missingPaths: inout [String],
        invalidPaths: inout [String],
        requiresStoreFallback: inout Bool
    ) -> AgentContextExportRow? {
        let trimmed = translatedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            invalidPaths.append(originalPath)
            return nil
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let physicalPath = StandardizedPath.absolute(expanded)
        guard let boundRoot = projection.boundRoot(containingPhysicalAbsolutePath: physicalPath) else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: physicalPath, isDirectory: &isDirectory) else {
            missingPaths.append(physicalPath)
            return nil
        }
        guard !isDirectory.boolValue else { return nil }
        guard safeDirectContentPath(physicalPath, boundRoot: boundRoot) != nil else {
            requiresStoreFallback = true
            return nil
        }

        let relativePath = StandardizedPath.relative(
            String(physicalPath.dropFirst(boundRoot.physicalRoot.standardizedFullPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
        let displayPath = projection.projectedLogicalDisplayPath(
            forPhysicalPath: physicalPath,
            display: filePathDisplay
        ) ?? originalPath
        let displayName = URL(fileURLWithPath: displayPath).lastPathComponent
        let mode: PromptFileEntryMode = lineRanges?.isEmpty == false ? .sliced : .fullFile
        return AgentContextExportRow(
            id: ResolvedPromptFileEntryID(
                fileID: stableUUID(namespace: "agent-selected-files-row", rawValue: physicalPath),
                mode: mode,
                lineRanges: lineRanges
            ),
            kind: mode == .sliced ? .slices : .full,
            rootID: boundRoot.physicalRoot.id,
            relativePath: relativePath,
            displayPath: displayPath,
            displayName: displayName.isEmpty ? URL(fileURLWithPath: physicalPath).lastPathComponent : displayName,
            directoryDisplay: directoryDisplay(for: displayPath, fallbackRootName: boundRoot.logicalRoot.name),
            lineRanges: lineRanges,
            canRemove: true,
            directContentPath: physicalPath
        )
    }

    private static func safeDirectContentPath(
        _ physicalPath: String,
        boundRoot: WorkspaceRootBindingProjection.BoundRoot
    ) -> String? {
        let rootPath = boundRoot.physicalRoot.standardizedFullPath
        let resolvedRoot = StandardizedPath.absolute((rootPath as NSString).resolvingSymlinksInPath)
        let resolvedPath = StandardizedPath.absolute((physicalPath as NSString).resolvingSymlinksInPath)
        guard resolvedPath == resolvedRoot || resolvedPath.hasPrefix("\(resolvedRoot)/") else {
            return nil
        }
        return physicalPath
    }

    private static func metadataOnlyPathRequiresStoreFallback(
        _ translatedPath: String,
        projection: WorkspaceRootBindingProjection
    ) -> Bool {
        let trimmed = translatedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return true }
        let physicalPath = StandardizedPath.absolute(expanded)
        guard projection.boundRoot(containingPhysicalAbsolutePath: physicalPath) != nil else { return true }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: physicalPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func sliceRanges(
        forOriginalPath originalPath: String,
        translatedPath: String,
        selection: StoredSelection
    ) -> [LineRange]? {
        let candidateKeys = [
            originalPath,
            normalizedSelectionKey(originalPath),
            translatedPath,
            normalizedSelectionKey(translatedPath)
        ]
        for key in candidateKeys {
            if let ranges = selection.slices[key], !ranges.isEmpty {
                return ranges
            }
        }
        return nil
    }

    private static func stableUUID(namespace: String, rawValue: String) -> UUID {
        var digest = Array(SHA256.hash(data: Data("\(namespace)|\(rawValue)".utf8)))
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        let bytes: uuid_t = (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        )
        return UUID(uuid: bytes)
    }

    private static func decodeText(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let unicode = String(data: data, encoding: .unicode) {
            return unicode
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func resolveRows(
        selection: StoredSelection,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        profile: PathLocateProfile
    ) async -> RowResolution {
        let totalStartMS = AgentSelectedFilesDiagnostics.timestampMSIfEnabled()
        AgentSelectedFilesDiagnostics.event(
            "resolver.resolveRows.start",
            fields: [
                "selectedPaths": String(selection.selectedPaths.count),
                "sliceFiles": String(selection.slices.count(where: { !$0.value.isEmpty })),
                "manualCodemapPaths": String(selection.manualCodemapPaths.count),
                "rootScope": String(describing: rootScope)
            ]
        )
        var rows: [RowResolutionEntry] = []
        var missingPaths: [String] = []
        var invalidPaths: [String] = []
        var seenIDs = Set<ResolvedPromptFileEntryID>()
        var selectedFileIDs = Set<UUID>()

        let selectedRequests = selection.selectedPaths.map {
            WorkspacePathLookupRequest(userPath: $0, profile: profile, rootScope: rootScope)
        }
        let selectedLookupStartMS = AgentSelectedFilesDiagnostics.timestampMSIfEnabled()
        let selectedLookupResults = await store.lookupSelectionPaths(selectedRequests)
        AgentSelectedFilesDiagnostics.durationEvent(
            "resolver.lookupSelectedPaths",
            startMS: selectedLookupStartMS,
            fields: [
                "requestCount": String(selectedRequests.count),
                "resultCount": String(selectedLookupResults.count)
            ]
        )

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
        let sliceLookupStartMS = AgentSelectedFilesDiagnostics.timestampMSIfEnabled()
        let sliceLookupResults: [String: WorkspacePathLookupResult] = if sliceLookupRequests.isEmpty {
            [:]
        } else {
            await store.lookupSelectionPaths(sliceLookupRequests)
        }
        AgentSelectedFilesDiagnostics.durationEvent(
            "resolver.lookupSlicePaths",
            startMS: sliceLookupStartMS,
            fields: [
                "requestCount": String(sliceLookupRequests.count),
                "resultCount": String(sliceLookupResults.count)
            ]
        )
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

        AgentSelectedFilesDiagnostics.durationEvent(
            "resolver.resolveRows.complete",
            startMS: totalStartMS,
            fields: [
                "rowEntries": String(rows.count),
                "selectedFileIDs": String(selectedFileIDs.count),
                "missingPaths": String(Set(missingPaths).count),
                "invalidPaths": String(Set(invalidPaths).count)
            ]
        )
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
