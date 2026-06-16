import Foundation

extension MCPServerViewModel {
    nonisolated static let codeMapsGloballyDisabledMCPMessage = "Code Maps are globally disabled in Advanced Settings; codemap-only selection modes and get_code_structure are unavailable."

    @MainActor
    var codeMapsGloballyDisabledForMCP: Bool {
        promptVM.codeMapsGloballyDisabled
    }

    @MainActor
    func effectiveMCPCodeMapUsage(_ usage: CodeMapUsage) -> CodeMapUsage {
        promptVM.codeMapsGloballyDisabled ? .none : usage
    }

    /// Describes why a file is rendered as a codemap
    enum CodemapOrigin: String {
        /// Auto-added as a dependency of selected files
        case auto
        /// Explicitly added via mode: "codemap_only"
        case manual
        /// Was selected as full but converted due to codeMapUsage == .selected
        case selectedMode = "selected_mode"
    }

    /// A codemap entry with its origin/reason.
    struct CodemapEntry {
        let entry: ResolvedPromptFileEntry
        let origin: CodemapOrigin
        var file: WorkspaceFileRecord {
            entry.file
        }
    }

    @MainActor
    protocol SelectionSource {
        func resolvedSelection() async -> StoredSelection
        func currentCodeMapUsage() -> CodeMapUsage
    }

    @MainActor
    struct StoredSelectionSource: SelectionSource {
        let stored: StoredSelection
        let codeMapUsage: CodeMapUsage

        func resolvedSelection() async -> StoredSelection {
            stored
        }

        func currentCodeMapUsage() -> CodeMapUsage {
            codeMapUsage
        }
    }

    /// Returns selection-aware workspace records for the resolved tab context snapshot.
    @MainActor
    func selectedRecordsForCurrentTabContext() async throws -> [WorkspaceFileRecord] {
        let collections = try await selectionCollectionsForCurrentTabContext()
        return collections.selected.map(\.entry.file)
    }

    /// Returns the identifiers of files selected in the resolved tab context snapshot.
    @MainActor
    func selectedRecordIDsForCurrentTabContext() async throws -> Set<UUID> {
        let collections = try await selectionCollectionsForCurrentTabContext()
        var ids = Set(collections.selected.map(\.entry.file.id))
        if effectiveMCPCodeMapUsage(promptVM.codeMapUsage) == .selected {
            ids.formUnion(collections.codemap.map(\.entry.file.id))
        }
        return ids
    }

    @MainActor
    func selectionCollections(for context: TabContextSnapshot, codeMapUsageOverride: CodeMapUsage? = nil) async -> SelectionReplyAssembler.SelectionCollections {
        let requestedUsage = codeMapUsageOverride ?? promptVM.codeMapUsage
        let lookupContext = await lookupContext(for: context)
        let source = StoredSelectionSource(
            stored: lookupContext.physicalizeSelection(context.selection),
            codeMapUsage: effectiveMCPCodeMapUsage(requestedUsage)
        )
        return await SelectionReplyAssembler.collect(from: source, owner: self, rootScope: lookupContext.rootScope)
    }

    @MainActor
    func lookupContext(for context: TabContextSnapshot) async -> WorkspaceLookupContext {
        if let frozenLookupContext = context.frozenLookupContext {
            return frozenLookupContext
        }
        return await AgentWorkspaceLookupContextResolver.authoritativeLookupContextOrFailClosed(
            source: AgentWorkspaceLookupContextSource(
                activeAgentSessionID: context.activeAgentSessionID,
                worktreeBindingState: context.worktreeBindingState
            ),
            store: promptVM.workspaceFileContextStore
        )
    }

    @MainActor
    func selectionCollectionsForCurrentTabContext() async throws -> SelectionReplyAssembler.SelectionCollections {
        let metadata = await captureRequestMetadata()
        let resolved = try resolveTabContextSnapshot(
            from: metadata,
            toolName: "selection",
            policy: .allowLegacyImplicitRouting
        )
        return await selectionCollections(for: resolved.snapshot)
    }

    struct PathFormatter {
        let format: FilePathDisplay
        unowned let owner: MCPServerViewModel
        let projection: WorkspaceRootBindingProjection?

        init(format: FilePathDisplay, owner: MCPServerViewModel, projection: WorkspaceRootBindingProjection? = nil) {
            self.format = format
            self.owner = owner
            self.projection = projection
        }

        func displayPath(for file: WorkspaceFileRecord) async -> String {
            if let projection,
               let projected = projection.projectedLogicalDisplayPath(forPhysicalPath: file.standardizedFullPath, display: format)
            {
                return projected
            }
            switch format {
            case .full:
                return file.fullPath
            case .relative:
                let roots = await owner.promptVM.workspaceFileContextStore.rootRefs(scope: .allLoaded)
                guard let root = roots.first(where: { $0.id == file.rootID }) else { return file.relativePath }
                return ClientPathFormatter.displayPath(root: root, relativePath: file.standardizedRelativePath, visibleRoots: roots)
            }
        }
    }

    struct TokenServices {
        unowned let owner: MCPServerViewModel

        func fullTokens(for entry: ResolvedPromptFileEntry) -> Int {
            if let content = entry.loadedContent {
                return TokenCalculationService.estimateTokens(for: content)
            }
            return 0
        }

        func sliceTokens(for entry: ResolvedPromptFileEntry, ranges: [LineRange]) async -> Int {
            guard let content = entry.loadedContent else { return 0 }
            let lines = content.components(separatedBy: .newlines)
            let selected = ranges.flatMap { range -> [String] in
                let start = max(1, range.start) - 1
                let end = min(lines.count, range.end) - 1
                guard start <= end, lines.indices.contains(start) else { return [] }
                return Array(lines[start ... end])
            }.joined(separator: "\n")
            return TokenCalculationService.estimateTokens(for: selected)
        }

        func codemapTokens(for file: WorkspaceFileRecord, displayPath: String) async -> Int {
            let snapshots = await owner.promptVM.workspaceFileContextStore.codemapSnapshotDictionary()
            guard let api = snapshots[file.id]?.fileAPI else { return 0 }
            return api.estimatedFullAPIDescriptionTokens(displayPath: displayPath)
        }
    }

    enum SelectionReplyAssembler {
        struct SelectedEntry {
            let entry: ResolvedPromptFileEntry
            var ranges: [LineRange]? {
                entry.lineRanges
            }

            var file: WorkspaceFileRecord {
                entry.file
            }
        }

        struct SelectionCollections {
            let selected: [SelectedEntry]
            let codemap: [CodemapEntry]
            let codemapAutoEnabled: Bool
            let codeMapUsage: CodeMapUsage
            let invalid: [String]
            let codemapSnapshots: [UUID: WorkspaceCodemapSnapshot]

            static func empty(codeMapUsage: CodeMapUsage) -> SelectionCollections {
                SelectionCollections(selected: [], codemap: [], codemapAutoEnabled: false, codeMapUsage: codeMapUsage, invalid: [], codemapSnapshots: [:])
            }
        }

        /// Metadata for user's actual preset settings (for virtual context state indicators)
        struct UserPresetState {
            let copyCodeMapUsage: String
            let chatCodeMapUsage: String
            /// Token count under user's copy preset settings (optional - computed lazily)
            var copyTokens: Int?
            /// Token count under user's chat preset settings (optional - computed lazily)
            var chatTokens: Int?
            /// What this reply uses (e.g. "auto" for virtual contexts)
            let normalizedCodeMapUsage: String
        }

        static func collect(
            from source: SelectionSource,
            owner: MCPServerViewModel,
            rootScope: WorkspaceLookupRootScope = .allLoaded,
            contentPolicy: PromptContextAccountingContentPolicy = .loadContent
        ) async -> SelectionCollections {
            let selection = await source.resolvedSelection()
            let usage = await source.currentCodeMapUsage()
            let store = await MainActor.run { owner.promptVM.workspaceFileContextStore }
            let codemapSnapshots = await store.codemapSnapshotDictionary()
            let accounting = PromptContextAccountingService()
            let resolution = await accounting.resolveEntries(
                selection: selection,
                store: store,
                rootScope: rootScope,
                profile: .uiAssisted,
                codeMapUsage: usage,
                contentPolicy: contentPolicy
            )

            let selected = resolution.entries.compactMap { entry -> SelectedEntry? in
                entry.isCodemap ? nil : SelectedEntry(entry: entry)
            }
            let codemap = resolution.entries.compactMap { entry -> CodemapEntry? in
                guard entry.isCodemap else { return nil }
                let origin: CodemapOrigin = switch usage {
                case .selected: .selectedMode
                case .complete: .auto
                case .auto: selection.codemapAutoEnabled ? .auto : .manual
                case .none: .manual
                }
                return CodemapEntry(entry: entry, origin: origin)
            }
            return SelectionCollections(
                selected: selected,
                codemap: codemap,
                codemapAutoEnabled: selection.codemapAutoEnabled,
                codeMapUsage: usage,
                invalid: resolution.missingPaths + resolution.invalidPaths,
                codemapSnapshots: codemapSnapshots
            )
        }

        private static func pathMetadata(
            for file: WorkspaceFileRecord,
            entry: ResolvedPromptFileEntry? = nil,
            projection: WorkspaceRootBindingProjection? = nil
        ) -> (rootPath: String, pathWithinRoot: String) {
            if let projected = projection?.projectedLogicalRootMetadata(forPhysicalPath: file.standardizedFullPath) {
                return projected
            }
            let rootPath = entry?.rootFolderPath.map { StandardizedPath.absolute($0) }
                ?? (file.standardizedFullPath as NSString).deletingLastPathComponent
            return (rootPath, file.standardizedRelativePath)
        }

        /// Computes how a file would render under a given codemap usage mode
        static func computeCopyPresetProjection(
            autoRenderMode: String,
            autoTokens: Int,
            hasCodemap: Bool,
            copyUsage: CodeMapUsage,
            codemapTokens: Int
        ) -> ToolResultDTOs.SelectedFileInfo.CopyPresetProjection? {
            // Determine what renderMode would be under copy preset
            let copyRenderMode: String
            let copyTokens: Int
            let copyOrigin: String?

            switch copyUsage {
            case .auto:
                // Same as auto view - no projection needed
                return nil

            case .selected:
                // Full/slice files with codemaps become codemaps
                if autoRenderMode == "full" || autoRenderMode == "slice", hasCodemap {
                    copyRenderMode = "codemap"
                    copyTokens = codemapTokens
                    copyOrigin = "selected_mode"
                } else if autoRenderMode == "codemap" {
                    // Already codemap, no change
                    return nil
                } else {
                    // No codemap available, stays as is
                    return nil
                }

            case .complete:
                // Everything with a codemap becomes codemap
                if hasCodemap, autoRenderMode != "codemap" {
                    copyRenderMode = "codemap"
                    copyTokens = codemapTokens
                    copyOrigin = "complete_mode"
                } else {
                    return nil
                }

            case .none:
                // Under 'none' mode, codemaps are disabled
                if autoRenderMode == "codemap" {
                    // Codemap-only files wouldn't appear - mark as hidden
                    return ToolResultDTOs.SelectedFileInfo.CopyPresetProjection(
                        tokens: 0,
                        renderMode: "hidden",
                        ranges: nil,
                        codemapOrigin: nil
                    )
                } else {
                    // Full/slice stays the same
                    return nil
                }
            }

            // Only return projection if it differs from auto view
            if copyRenderMode == autoRenderMode, copyTokens == autoTokens {
                return nil
            }

            return ToolResultDTOs.SelectedFileInfo.CopyPresetProjection(
                tokens: copyTokens,
                renderMode: copyRenderMode,
                ranges: nil,
                codemapOrigin: copyOrigin
            )
        }

        static func buildSelectedFilesReply(
            collections: SelectionCollections,
            formatter: PathFormatter,
            tokens: TokenServices,
            userPresetState: UserPresetState? = nil,
            copyUsage: CodeMapUsage? = nil,
            projection: MCPServerViewModel.CopyPresetProjectionConfig? = nil,
            entryResultsByFileID: [UUID: PromptEntriesEvaluation.EntryResult]? = nil
        ) async -> ToolResultDTOs.SelectedFilesReply {
            var files: [ToolResultDTOs.SelectedFileInfo] = []
            var totalTokens = 0
            var fileSlices: [ToolResultDTOs.FileSliceDTO] = []
            var copyTotalTokens = 0
            // Track user copy breakdown by content type
            var copyContentTokens = 0
            var copyCodemapTokens = 0

            var fullCount = 0
            var sliceCount = 0
            var codemapCount = 0
            var fullTokens = 0
            var sliceTokens = 0
            var codemapTokens = 0

            for entry in collections.selected {
                let file = entry.file
                let displayPath = await formatter.displayPath(for: file)
                let metadata = pathMetadata(for: file, entry: entry.entry, projection: formatter.projection)
                let ranges = entry.ranges ?? []
                let hasSlices = !ranges.isEmpty
                let entryResult = entryResultsByFileID?[file.id]
                let tokenCount = if let entryResult {
                    entryResult.displayTokens
                } else if hasSlices {
                    await tokens.sliceTokens(for: entry.entry, ranges: ranges)
                } else {
                    tokens.fullTokens(for: entry.entry)
                }

                totalTokens += tokenCount
                if hasSlices {
                    sliceCount += 1
                    sliceTokens += tokenCount
                    let dtoRanges = ranges.map { ToolResultDTOs.LineRangeDTO(range: $0) }
                    fileSlices.append(.init(
                        path: displayPath,
                        ranges: dtoRanges,
                        rootPath: metadata.rootPath,
                        pathWithinRoot: metadata.pathWithinRoot
                    ))
                } else {
                    fullCount += 1
                    fullTokens += tokenCount
                }

                let rangesDTOs = hasSlices ? ranges.map { ToolResultDTOs.LineRangeDTO(range: $0) } : nil
                let autoRenderMode = hasSlices ? "slice" : "full"

                // Compute copy preset projection if copy usage differs from auto
                var copyPreset: ToolResultDTOs.SelectedFileInfo.CopyPresetProjection? = nil
                if let copyUsage, copyUsage != .auto {
                    let hasCodemap = collections.codemapSnapshots[file.id]?.fileAPI != nil
                    let codemapTokenCount = if let entryResult {
                        entryResult.codemapTokens
                    } else if hasCodemap {
                        await tokens.codemapTokens(for: file, displayPath: displayPath)
                    } else {
                        0
                    }
                    copyPreset = computeCopyPresetProjection(
                        autoRenderMode: autoRenderMode,
                        autoTokens: tokenCount,
                        hasCodemap: hasCodemap,
                        copyUsage: copyUsage,
                        codemapTokens: codemapTokenCount
                    )
                }

                // Track copy total tokens and breakdown
                if let cp = copyPreset {
                    copyTotalTokens += cp.tokens
                    // Track breakdown based on user preset render mode
                    switch cp.renderMode {
                    case "codemap":
                        copyCodemapTokens += cp.tokens
                    case "hidden":
                        break // 0 tokens, nothing to add
                    default: // "full", "slice"
                        copyContentTokens += cp.tokens
                    }
                } else {
                    copyTotalTokens += tokenCount
                    copyContentTokens += tokenCount // Original mode is content (full/slice)
                }

                files.append(
                    ToolResultDTOs.SelectedFileInfo(
                        path: displayPath,
                        tokens: tokenCount,
                        renderMode: autoRenderMode,
                        ranges: rangesDTOs,
                        isAuto: false,
                        codemapOrigin: nil,
                        copyPreset: copyPreset,
                        rootPath: metadata.rootPath,
                        pathWithinRoot: metadata.pathWithinRoot
                    )
                )
            }

            for entry in collections.codemap {
                let file = entry.file
                let displayPath = await formatter.displayPath(for: file)
                let metadata = pathMetadata(for: file, entry: entry.entry, projection: formatter.projection)
                let entryResult = entryResultsByFileID?[file.id]
                let tokenCount: Int
                if let entryResult {
                    tokenCount = entryResult.displayTokens
                } else {
                    let rawCodemapTokens = await tokens.codemapTokens(for: file, displayPath: displayPath)
                    if rawCodemapTokens == 0, collections.codeMapUsage == .selected {
                        tokenCount = tokens.fullTokens(for: entry.entry)
                    } else {
                        tokenCount = rawCodemapTokens
                    }
                }
                codemapCount += 1
                codemapTokens += tokenCount
                totalTokens += tokenCount

                // For codemap files, compute copy preset projection
                var copyPreset: ToolResultDTOs.SelectedFileInfo.CopyPresetProjection? = nil
                if let copyUsage, copyUsage != .auto {
                    // Under 'none' or 'selected' mode, codemap-only files wouldn't appear
                    // Under 'complete' mode, same as auto for codemaps
                    if copyUsage == .none || copyUsage == .selected {
                        // Codemap-only files wouldn't be included under 'none' or 'selected' mode
                        // Mark as hidden (0 tokens, "hidden" mode)
                        copyPreset = ToolResultDTOs.SelectedFileInfo.CopyPresetProjection(
                            tokens: 0,
                            renderMode: "hidden",
                            ranges: nil,
                            codemapOrigin: nil
                        )
                    }
                    // For 'complete' mode, codemap stays as codemap (no projection needed)
                }

                // Track copy total tokens and breakdown (codemap-only files under 'none' or 'selected' would be 0)
                if let copyUsage {
                    if copyUsage == .none || copyUsage == .selected {
                        // File wouldn't appear under copy preset
                        // Don't add to copyTotalTokens or breakdown
                    } else {
                        copyTotalTokens += tokenCount
                        copyCodemapTokens += tokenCount
                    }
                } else {
                    copyTotalTokens += tokenCount
                    copyCodemapTokens += tokenCount
                }

                files.append(
                    ToolResultDTOs.SelectedFileInfo(
                        path: displayPath,
                        tokens: tokenCount,
                        renderMode: "codemap",
                        ranges: nil,
                        isAuto: entry.origin == .auto,
                        codemapOrigin: entry.origin.rawValue,
                        copyPreset: copyPreset,
                        rootPath: metadata.rootPath,
                        pathWithinRoot: metadata.pathWithinRoot
                    )
                )
            }

            let summary = ToolResultDTOs.SelectionSummary(
                fullCount: fullCount,
                sliceCount: sliceCount,
                codemapCount: codemapCount,
                fullTokens: fullTokens,
                sliceTokens: sliceTokens,
                codemapTokens: codemapTokens
            )

            var reply = ToolResultDTOs.SelectedFilesReply(
                files: files,
                totalTokens: totalTokens,
                fileSlices: fileSlices.isEmpty ? nil : fileSlices,
                summary: summary,
                codeMapUsage: collections.codeMapUsage.rawValue
            )

            // Populate user preset state indicators if provided
            if let state = userPresetState {
                reply.userCopyCodeMapUsage = state.copyCodeMapUsage
                reply.userChatCodeMapUsage = state.chatCodeMapUsage
                // Use computed copy tokens if we have copy usage, otherwise use provided state
                reply.userCopyTokens = copyUsage != nil ? copyTotalTokens : state.copyTokens
                reply.userChatTokens = state.chatTokens
                reply.normalizedCodeMapUsage = state.normalizedCodeMapUsage
                // Include user copy breakdown if we computed projections
                if copyUsage != nil {
                    reply.userCopyContentTokens = copyContentTokens
                    reply.userCopyCodemapTokens = copyCodemapTokens
                }
            } else if copyUsage != nil, copyUsage != .auto {
                // Even without full state, include copy tokens if we computed projections
                reply.userCopyCodeMapUsage = copyUsage?.rawValue
                reply.userCopyTokens = copyTotalTokens
                reply.userCopyContentTokens = copyContentTokens
                reply.userCopyCodemapTokens = copyCodemapTokens
            }

            // Build copy preset projection summary if projection config is provided
            if let projection {
                // Compute projected tokens based on includeFiles flag
                let projectedTokens: Int = if !projection.includeFiles {
                    // Files not included - only codemaps if mode supports them
                    projection.codeMapUsage == .none ? 0 : codemapTokens
                } else {
                    // Use the computed copy total tokens
                    copyTotalTokens
                }
                reply.copyPresetProjection = ToolResultDTOs.CopyPresetProjectionSummaryDTO(
                    codeMapUsage: projection.codeMapUsage.rawValue,
                    includesFiles: projection.includeFiles,
                    totalTokens: projectedTokens
                )
            }

            return reply
        }

        static func buildSelectionReply(
            collections: SelectionCollections,
            includeBlocks: Bool,
            display: FilePathDisplay,
            formatter: PathFormatter,
            tokens: TokenServices,
            status: String,
            extraInvalid: [String],
            userPresetState: UserPresetState? = nil,
            copyUsage: CodeMapUsage? = nil,
            projection: MCPServerViewModel.CopyPresetProjectionConfig? = nil,
            tokenStatsOverride: ToolResultDTOs.TokenStats? = nil
        ) async -> ToolResultDTOs.SelectionReply {
            let filesReply = await buildSelectedFilesReply(
                collections: collections,
                formatter: formatter,
                tokens: tokens,
                userPresetState: userPresetState,
                copyUsage: copyUsage,
                projection: projection
            )

            return await makeSelectionReply(
                filesReply: filesReply,
                collections: collections,
                includeBlocks: includeBlocks,
                display: display,
                status: status,
                extraInvalid: extraInvalid,
                userPresetState: userPresetState,
                tokens: tokens,
                tokenStatsOverride: tokenStatsOverride,
                pathProjection: formatter.projection
            )
        }

        static func makeSelectionReply(
            filesReply: ToolResultDTOs.SelectedFilesReply,
            collections: SelectionCollections,
            includeBlocks: Bool,
            display: FilePathDisplay,
            status: String,
            extraInvalid: [String],
            userPresetState: UserPresetState? = nil,
            tokens: TokenServices? = nil,
            tokenStatsOverride: ToolResultDTOs.TokenStats? = nil,
            tokenAccountingOverride: ToolResultDTOs.TokenAccountingDTO? = nil,
            pathProjection: WorkspaceRootBindingProjection? = nil
        ) async -> ToolResultDTOs.SelectionReply {
            var blocks: [String]? = nil
            if includeBlocks {
                let generated = await generateBlocks(selected: collections.selected, display: display, projection: pathProjection)
                blocks = generated
            }

            var invalid = collections.invalid
            for candidate in extraInvalid where !invalid.contains(candidate) {
                invalid.append(candidate)
            }

            // MCP replies never await an immediate recount. Use the latest published
            // active-tab snapshot when no tab-scoped override was prepared.
            let fallbackPublished = await MainActor.run {
                tokens?.owner.promptVM.tokenCountingViewModel.latestPublishedTokenSnapshot(for: nil)
            }
            let tokenStats: ToolResultDTOs.TokenStats? = tokenStatsOverride
                ?? fallbackPublished.map(MCPServerViewModel.publishedTokenStats)
            let tokenAccounting = tokenAccountingOverride ?? fallbackPublished.map { snapshot in
                ToolResultDTOs.TokenAccountingDTO(
                    status: !snapshot.isComplete ? "incomplete" : (snapshot.isStale ? "stale" : "fresh"),
                    source: "active_tab_published",
                    refreshPending: snapshot.refreshPending,
                    incompleteComponents: snapshot.isComplete ? nil : ["published_snapshot"]
                )
            }

            return ToolResultDTOs.SelectionReply(
                files: filesReply.files,
                totalTokens: filesReply.totalTokens,
                status: status,
                invalidPaths: invalid.isEmpty ? nil : invalid,
                blocks: blocks,
                codeStructure: nil,
                fileSlices: filesReply.fileSlices,
                codemapAutoEnabled: collections.codemapAutoEnabled,
                summary: filesReply.summary,
                codeMapUsage: collections.codeMapUsage.rawValue,
                // User preset state indicators - use filesReply values (computed) where available
                userCopyCodeMapUsage: filesReply.userCopyCodeMapUsage ?? userPresetState?.copyCodeMapUsage,
                userChatCodeMapUsage: filesReply.userChatCodeMapUsage ?? userPresetState?.chatCodeMapUsage,
                userCopyTokens: filesReply.userCopyTokens ?? userPresetState?.copyTokens,
                userChatTokens: filesReply.userChatTokens ?? userPresetState?.chatTokens,
                normalizedCodeMapUsage: filesReply.normalizedCodeMapUsage ?? userPresetState?.normalizedCodeMapUsage,
                tokenStats: tokenStats,
                tokenAccounting: tokenAccounting,
                copyPresetProjection: filesReply.copyPresetProjection
            )
        }

        static func generateBlocks(
            selected: [SelectedEntry],
            display: FilePathDisplay,
            projection: WorkspaceRootBindingProjection? = nil
        ) async -> [String] {
            guard !selected.isEmpty else { return [] }
            return await PromptPackagingService.generateFileContents(
                selected.map(\.entry),
                filePathDisplay: display,
                displayPathResolver: { entry in
                    projection?.projectedLogicalDisplayPath(forPhysicalPath: entry.file.standardizedFullPath, display: display)
                }
            )
        }

        /// Builds lightweight FileSliceDTO array from collections without token calculations.
        /// Only produces entries for files with at least one slice.
        static func buildFileSlices(
            collections: SelectionCollections,
            formatter: PathFormatter
        ) async -> [ToolResultDTOs.FileSliceDTO] {
            var slices: [ToolResultDTOs.FileSliceDTO] = []
            slices.reserveCapacity(collections.selected.count)

            for entry in collections.selected {
                let file = entry.file
                let ranges = entry.ranges ?? []
                guard !ranges.isEmpty else { continue }

                let displayPath = await formatter.displayPath(for: file)
                let metadata = pathMetadata(for: file, entry: entry.entry, projection: formatter.projection)
                let dtoRanges = ranges.map { ToolResultDTOs.LineRangeDTO(range: $0) }
                slices.append(.init(
                    path: displayPath,
                    ranges: dtoRanges,
                    rootPath: metadata.rootPath,
                    pathWithinRoot: metadata.pathWithinRoot
                ))
            }

            return slices
        }

        /// Post-filter a SelectionReply for "codemaps" view.
        static func applyViewFilter(_ reply: ToolResultDTOs.SelectionReply, view: String) -> ToolResultDTOs.SelectionReply {
            guard view == "codemaps", let files = reply.files else { return reply }

            let filteredFiles = files.filter { $0.renderMode == "codemap" }
            let filteredPaths = Set(filteredFiles.map(\.path))
            let filteredSlices = reply.fileSlices?.filter { filteredPaths.contains($0.path) }
            let totalTokens = filteredFiles.reduce(0) { $0 + $1.tokens }

            // Recompute a minimal summary for the filtered view to avoid confusing totals
            let summary = ToolResultDTOs.SelectionSummary(
                fullCount: 0,
                sliceCount: 0,
                codemapCount: filteredFiles.count,
                fullTokens: 0,
                sliceTokens: 0,
                codemapTokens: totalTokens
            )

            return ToolResultDTOs.SelectionReply(
                files: filteredFiles,
                totalTokens: totalTokens,
                status: reply.status,
                invalidPaths: reply.invalidPaths,
                // No content blocks for codemaps view
                blocks: nil,
                codeStructure: reply.codeStructure,
                fileSlices: filteredSlices,
                codemapAutoEnabled: reply.codemapAutoEnabled,
                summary: summary,
                codeMapUsage: reply.codeMapUsage,
                // Preserve user preset state indicators
                userCopyCodeMapUsage: reply.userCopyCodeMapUsage,
                userChatCodeMapUsage: reply.userChatCodeMapUsage,
                userCopyTokens: reply.userCopyTokens,
                userChatTokens: reply.userChatTokens,
                normalizedCodeMapUsage: reply.normalizedCodeMapUsage,
                // Preserve workspace token stats (total breakdown stays the same even for filtered view)
                tokenStats: reply.tokenStats,
                tokenAccounting: reply.tokenAccounting
            )
        }
    }

    struct CodeStructureBuilder {
        unowned let owner: MCPServerViewModel
        let lookupContext: WorkspaceLookupContext

        func build(for files: [WorkspaceFileRecord]) async throws -> ToolResultDTOs.SelectedCodeStructureDTO? {
            guard !files.isEmpty else { return nil }
            let disabled = await MainActor.run { owner.promptVM.codeMapsGloballyDisabled }
            guard !disabled else { return nil }

            return try await owner.buildCodeStructureDTO(
                fromRecords: files,
                maxResults: 25,
                includeUnmappedPaths: true,
                lookupContext: lookupContext
            )
        }
    }
}
