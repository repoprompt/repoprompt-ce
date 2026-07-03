import Foundation
import MCP

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
    func selectedRecordsForCurrentTabContext(
        metadataOverride: RequestMetadata? = nil,
        lookupContextOverride: WorkspaceLookupContext? = nil
    ) async throws -> [WorkspaceFileRecord] {
        do {
            let collections = try await selectionCollectionsForCurrentTabContext(
                metadataOverride: metadataOverride,
                lookupContextOverride: lookupContextOverride
            )
            return collections.selected.map(\.entry.file)
        } catch let error as StabilizedSelectionReadSnapshotError {
            throw MCPError.invalidParams(error.localizedDescription)
        }
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
    func selectionCollections(
        for context: TabContextSnapshot,
        codeMapUsageOverride: CodeMapUsage? = nil,
        lookupContextOverride: WorkspaceLookupContext? = nil
    ) async -> SelectionReplyAssembler.SelectionCollections {
        let requestedUsage = codeMapUsageOverride ?? promptVM.codeMapUsage
        let lookupContext: WorkspaceLookupContext = if let lookupContextOverride {
            lookupContextOverride
        } else {
            await self.lookupContext(for: context)
        }
        let source = StoredSelectionSource(
            stored: lookupContext.physicalizeSelection(context.selection),
            codeMapUsage: effectiveMCPCodeMapUsage(requestedUsage)
        )
        return await SelectionReplyAssembler.collect(
            from: source,
            owner: self,
            rootScope: lookupContext.rootScope,
            lookupContext: lookupContext
        )
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
    func selectionCollectionsForCurrentTabContext(
        metadataOverride: RequestMetadata? = nil,
        lookupContextOverride: WorkspaceLookupContext? = nil
    ) async throws -> SelectionReplyAssembler.SelectionCollections {
        let metadata: RequestMetadata = if let metadataOverride {
            metadataOverride
        } else {
            await captureRequestMetadata()
        }
        let resolved = try resolveTabContextSnapshot(
            from: metadata,
            toolName: "selection",
            policy: .allowLegacyImplicitRouting,
            startMirroring: false
        )
        let stabilized = try stabilizedSelectionReadSnapshot(resolved)
        return await selectionCollections(
            for: stabilized.snapshot,
            lookupContextOverride: lookupContextOverride
        )
    }

    @MainActor
    func physicalSelectionForCurrentTabContext(
        metadataOverride: RequestMetadata? = nil,
        lookupContextOverride: WorkspaceLookupContext? = nil
    ) async throws -> StoredSelection {
        do {
            let metadata: RequestMetadata = if let metadataOverride {
                metadataOverride
            } else {
                await captureRequestMetadata()
            }
            let resolved = try resolveTabContextSnapshot(
                from: metadata,
                toolName: "selection",
                policy: .allowLegacyImplicitRouting,
                startMirroring: false
            )
            let stabilized = try stabilizedSelectionReadSnapshot(resolved)
            let lookupContext: WorkspaceLookupContext = if let lookupContextOverride {
                lookupContextOverride
            } else {
                await self.lookupContext(for: stabilized.snapshot)
            }
            return lookupContext.physicalizeSelection(stabilized.snapshot.selection)
        } catch let error as StabilizedSelectionReadSnapshotError {
            throw MCPError.invalidParams(error.localizedDescription)
        }
    }

    struct PathFormatter {
        struct RootMetadata {
            let rootPath: String
            let pathWithinRoot: String
        }

        let format: FilePathDisplay
        unowned let owner: MCPServerViewModel
        let projection: WorkspaceRootBindingProjection?
        let rootScope: WorkspaceLookupRootScope
        let displayPathOverrides: [String: String]
        let rootMetadataOverrides: [String: RootMetadata]

        init(
            format: FilePathDisplay,
            owner: MCPServerViewModel,
            projection: WorkspaceRootBindingProjection? = nil,
            rootScope: WorkspaceLookupRootScope = .allLoaded,
            displayPathOverrides: [String: String] = [:],
            rootMetadataOverrides: [String: RootMetadata] = [:]
        ) {
            self.format = format
            self.owner = owner
            self.projection = projection
            self.rootScope = rootScope
            self.displayPathOverrides = displayPathOverrides
            self.rootMetadataOverrides = rootMetadataOverrides
        }

        func displayPath(for file: WorkspaceFileRecord) async -> String {
            if let override = displayPathOverrides[file.standardizedFullPath] {
                return override
            }
            let store = await MainActor.run { owner.promptVM.workspaceFileContextStore }
            let roots = await store.rootRefs(scope: rootScope)
            let lookupContext = WorkspaceLookupContext(
                rootScope: rootScope,
                bindingProjection: projection
            )
            let labels = await lookupContext.logicalRootDisplayNamesByRootID(store: store)
            if format == .full,
               let metadata = projection?.projectedLogicalRootMetadata(forPhysicalPath: file.standardizedFullPath)
            {
                let rootName = labels[file.rootID]
                    ?? URL(fileURLWithPath: metadata.rootPath).lastPathComponent
                return metadata.pathWithinRoot.isEmpty
                    ? rootName
                    : "\(rootName)/\(metadata.pathWithinRoot)"
            }
            return lookupContext.logicalDisplayPath(
                for: file,
                roots: roots,
                rootDisplayNamesByRootID: labels,
                display: format
            ) ?? file.standardizedRelativePath
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

        func codemapTokens(
            for file: WorkspaceFileRecord,
            codemapPresentation: WorkspaceCodemapOperationPresentation
        ) -> Int {
            codemapPresentation.renderedEntriesByFileID[file.id]?.tokenCount ?? 0
        }
    }

    enum SelectionReplyAssembler {
        private static let codemapPresentationPolicy = WorkspaceCodemapPresentationRequestPolicy(
            maximumReadinessRounds: 1,
            maximumTotalWait: .zero
        )

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
            let requestedCodemapFiles: [WorkspaceFileRecord]
            let codemapAutoEnabled: Bool
            let codeMapUsage: CodeMapUsage
            let invalid: [String]
            let codemapPresentation: WorkspaceCodemapOperationPresentation

            static func empty(codeMapUsage: CodeMapUsage) -> SelectionCollections {
                SelectionCollections(
                    selected: [],
                    codemap: [],
                    requestedCodemapFiles: [],
                    codemapAutoEnabled: false,
                    codeMapUsage: codeMapUsage,
                    invalid: [],
                    codemapPresentation: .empty
                )
            }
        }

        struct CodemapPathDiagnostics: Equatable {
            let pendingPaths: [String]
            let unmappedPaths: [String]

            var isEmpty: Bool {
                pendingPaths.isEmpty && unmappedPaths.isEmpty
            }
        }

        private enum MissingCodemapDisposition {
            case pending
            case unmapped
        }

        private enum CodemapIssueDisposition {
            case pending
            case unmapped(terminal: Bool)
        }

        static func codemapDiagnosticFiles(
            for collections: SelectionCollections
        ) -> [WorkspaceFileRecord] {
            switch collections.codeMapUsage {
            case .none:
                []
            case .auto:
                collections.requestedCodemapFiles + collections.codemap.map(\.file)
            case .selected, .complete:
                collections.selected.map(\.file)
                    + collections.codemap.map(\.file)
                    + collections.requestedCodemapFiles
            }
        }

        static func missingCodemapDiagnostics(
            for files: [WorkspaceFileRecord],
            presentation: WorkspaceCodemapOperationPresentation,
            displayPath: (WorkspaceFileRecord) async -> String
        ) async -> CodemapPathDiagnostics {
            let missingFiles = codemapDiagnosticFiles(files, presentation: presentation)
            var pendingPaths: [String] = []
            var unmappedPaths: [String] = []
            var seenPending = Set<String>()
            var seenUnmapped = Set<String>()

            for file in missingFiles {
                let path = await displayPath(file)
                switch missingCodemapDisposition(for: file, presentation: presentation) {
                case .pending:
                    if seenPending.insert(path).inserted {
                        pendingPaths.append(path)
                    }
                case .unmapped:
                    if seenUnmapped.insert(path).inserted {
                        unmappedPaths.append(path)
                    }
                }
            }

            return CodemapPathDiagnostics(
                pendingPaths: pendingPaths,
                unmappedPaths: unmappedPaths
            )
        }

        static func hasPendingCodemapPresentationGaps(
            for files: [WorkspaceFileRecord],
            presentation: WorkspaceCodemapOperationPresentation,
            codeMapUsage: CodeMapUsage
        ) -> Bool {
            guard codeMapUsage != .none else { return false }
            return codemapDiagnosticFiles(files, presentation: presentation).contains { file in
                missingCodemapDisposition(for: file, presentation: presentation) == .pending
            }
        }

        private static func codemapDiagnosticFiles(
            _ files: [WorkspaceFileRecord],
            presentation: WorkspaceCodemapOperationPresentation
        ) -> [WorkspaceFileRecord] {
            var seen = Set<UUID>()
            var missing: [WorkspaceFileRecord] = []
            for file in files {
                guard seen.insert(file.id).inserted else { continue }
                guard presentation.renderedEntriesByFileID[file.id] == nil else { continue }
                missing.append(file)
            }
            return missing
        }

        private static func missingCodemapDisposition(
            for file: WorkspaceFileRecord,
            presentation: WorkspaceCodemapOperationPresentation
        ) -> MissingCodemapDisposition {
            guard supportsCodemap(file) else { return .unmapped }

            let issues = presentation.issues + coverageIssues(presentation.coverage)
            var sawPending = false
            var sawUnmapped = false
            var sawTerminalUnmapped = false
            for issue in issues {
                guard let disposition = codemapDisposition(
                    for: issue,
                    fileID: file.id
                ) else { continue }
                switch disposition {
                case .pending:
                    sawPending = true
                case let .unmapped(terminal):
                    sawUnmapped = true
                    sawTerminalUnmapped = sawTerminalUnmapped || terminal
                }
            }
            if sawTerminalUnmapped { return .unmapped }
            if sawPending { return .pending }
            if sawUnmapped { return .unmapped }

            if presentationCoverageIsIncomplete(presentation.coverage) || !issues.isEmpty {
                return .pending
            }

            // A supported file absent from an otherwise empty/complete presentation is
            // ambiguous in MCP's non-blocking path: CAS may not have produced a rendered
            // bundle yet, or the codemap may not have been requested by the stale snapshot.
            // Prefer a retryable/pending diagnostic over a final-looking unmapped result.
            return .pending
        }

        private static func supportsCodemap(_ file: WorkspaceFileRecord) -> Bool {
            let fileExtension = (file.name as NSString).pathExtension.lowercased()
            guard !fileExtension.isEmpty else { return false }
            return SyntaxManager.supportsCodeMap(fileExtension: fileExtension)
        }

        private static func coverageIssues(
            _ coverage: WorkspaceCodemapOperationPresentationCoverage
        ) -> [WorkspaceCodemapOperationIssue] {
            switch coverage {
            case .complete:
                []
            case let .partial(issues), let .pending(issues), let .unavailable(issues):
                issues
            }
        }

        private static func presentationCoverageIsIncomplete(
            _ coverage: WorkspaceCodemapOperationPresentationCoverage
        ) -> Bool {
            switch coverage {
            case .complete:
                false
            case .partial, .pending, .unavailable:
                true
            }
        }

        private static func codemapDisposition(
            for issue: WorkspaceCodemapOperationIssue,
            fileID: UUID
        ) -> CodemapIssueDisposition? {
            switch issue {
            case .coordinationUnavailable, .cancelled, .publicationStale:
                return .pending
            case let .candidate(candidateIssue):
                return candidateDisposition(candidateIssue, fileID: fileID)
            case let .pending(pendingFileID, _):
                return pendingFileID == fileID ? .pending : nil
            case let .unavailable(unavailableFileID, reason):
                guard unavailableFileID == fileID else { return nil }
                return unavailableDisposition(reason)
            case let .automatic(coverage):
                return automaticCoverageDisposition(coverage, fileID: fileID)
            case let .freezeUnavailable(_, reason):
                return freezeUnavailableDisposition(reason)
            case let .renderUnavailable(_, reason):
                return renderUnavailableDisposition(reason, fileID: fileID)
            }
        }

        private static func candidateDisposition(
            _ issue: WorkspaceCodemapOperationCandidateIssue,
            fileID: UUID
        ) -> CodemapIssueDisposition? {
            switch issue {
            case let .fileNotCataloged(candidateFileID):
                candidateFileID == fileID ? .pending : nil
            case let .fileOutsideRootScope(candidateFileID),
                 let .logicalPathUnavailable(candidateFileID):
                candidateFileID == fileID ? .unmapped(terminal: true) : nil
            case let .incompleteRootSet(missingFileIDs):
                missingFileIDs.contains(fileID) ? .pending : nil
            }
        }

        private static func unavailableDisposition(
            _ reason: WorkspaceCodemapArtifactDemandUnavailableReason
        ) -> CodemapIssueDisposition {
            switch reason {
            case .unsupportedFileType:
                .unmapped(terminal: true)
            case .gitTerminal:
                .unmapped(terminal: true)
            case let .demandUnavailable(reason):
                demandUnavailableDisposition(reason)
            case .rootNotLoaded, .fileNotCataloged, .gitTransient, .busy,
                 .rejected, .routeConflict, .registrationFailed, .runtimeFailure,
                 .staleCurrentness, .cancelled:
                .pending
            }
        }

        private static func demandUnavailableDisposition(
            _ reason: WorkspaceCodemapBindingDemandUnavailableReason
        ) -> CodemapIssueDisposition {
            switch reason {
            case .unsupportedFileType, .missing, .securityExcluded, .nonRegular,
                 .oversized, .terminalArtifact:
                .unmapped(terminal: true)
            case .transient:
                .pending
            }
        }

        private static func automaticCoverageDisposition(
            _ coverage: WorkspaceCodemapAutomaticSelectionAggregateCoverage,
            fileID: UUID
        ) -> CodemapIssueDisposition? {
            automaticCoverageDispositionByFileID(coverage)[fileID]
        }

        private static func automaticCoverageDispositionByFileID(
            _ coverage: WorkspaceCodemapAutomaticSelectionAggregateCoverage
        ) -> [UUID: CodemapIssueDisposition] {
            var dispositions: [UUID: CodemapIssueDisposition] = [:]

            func merged(
                _ existing: CodemapIssueDisposition?,
                _ next: CodemapIssueDisposition
            ) -> CodemapIssueDisposition {
                guard let existing else { return next }
                switch (existing, next) {
                case (.unmapped(terminal: true), _), (_, .unmapped(terminal: true)):
                    return .unmapped(terminal: true)
                case (.pending, _), (_, .pending):
                    return .pending
                case (.unmapped, .unmapped):
                    return .unmapped(terminal: false)
                }
            }

            func record(_ fileID: UUID, _ disposition: CodemapIssueDisposition) {
                dispositions[fileID] = merged(dispositions[fileID], disposition)
            }

            func recordPending(_ fileID: UUID) {
                record(fileID, .pending)
            }

            func recordUnavailable(
                _ fileID: UUID,
                _ reason: WorkspaceCodemapArtifactDemandUnavailableReason
            ) {
                record(fileID, unavailableDisposition(reason))
            }

            func recordSourceIssue(_ issue: WorkspaceCodemapAutomaticSelectionSourceIssue) {
                switch issue {
                case let .outsideRootScope(source):
                    record(source.fileID, .unmapped(terminal: true))
                case let .notCataloged(source), let .notDemanded(source),
                     let .staleCatalogGeneration(source, _):
                    recordPending(source.fileID)
                case let .pending(source, _):
                    recordPending(source.fileID)
                case let .unavailable(source, reason):
                    recordUnavailable(source.fileID, reason)
                }
            }

            func recordTargetIssue(_ issue: WorkspaceCodemapAutomaticSelectionTargetIssue) {
                switch issue {
                case let .notCataloged(_, fileID), let .staleGeneration(_, fileID, _):
                    recordPending(fileID)
                case let .logicalPathUnavailable(_, fileID):
                    record(fileID, .unmapped(terminal: true))
                }
            }

            func recordPartialReason(_ reason: WorkspaceCodemapAutomaticSelectionPartialReason) {
                switch reason {
                case .graph:
                    break
                case let .source(issue):
                    recordSourceIssue(issue)
                case let .sourceDemandTimedOut(source):
                    recordPending(source.fileID)
                case let .candidateUnavailable(_, fileID, reason):
                    recordUnavailable(fileID, reason)
                }
            }

            func recordPendingReason(_ reason: WorkspaceCodemapAutomaticSelectionPendingReason) {
                switch reason {
                case let .sourceDemand(source, _), let .sourceBusy(source, _):
                    recordPending(source.fileID)
                case let .candidateDemand(_, fileID, _), let .candidateBusy(_, fileID, _):
                    recordPending(fileID)
                case .manifestAdmission, .graphRebuild:
                    break
                }
            }

            func recordUnavailableReason(_ reason: WorkspaceCodemapAutomaticSelectionUnavailableReason) {
                switch reason {
                case .noReadySources, .graph:
                    break
                case let .candidate(_, fileID, reason):
                    recordUnavailable(fileID, reason)
                }
            }

            func recordStaleReason(_ reason: WorkspaceCodemapAutomaticSelectionStaleReason) {
                switch reason {
                case let .sourceStateChanged(source), let .sourceCatalogGeneration(source, _):
                    recordPending(source.fileID)
                case let .targetStateChanged(issue):
                    recordTargetIssue(issue)
                case .rootEpochNotCurrent, .rootScopeChanged, .coverageProof, .graph,
                     .publicationReceipt:
                    break
                }
            }

            switch coverage {
            case .complete:
                break
            case let .partial(_, reasons):
                reasons.forEach(recordPartialReason)
            case let .provisional(_, pending, partial):
                pending.forEach(recordPendingReason)
                partial.forEach(recordPartialReason)
            case .incomplete:
                break
            case let .pending(reasons):
                reasons.forEach(recordPendingReason)
            case let .unavailable(reason):
                recordUnavailableReason(reason)
            case let .stale(reason):
                recordStaleReason(reason)
            case .busy, .budget:
                break
            }

            return dispositions
        }

        private static func automaticCoverageFileIDs(
            _ coverage: WorkspaceCodemapAutomaticSelectionAggregateCoverage
        ) -> [UUID] {
            automaticCoverageDispositionByFileID(coverage).keys.sorted { lhs, rhs in
                lhs.uuidString < rhs.uuidString
            }
        }

        private static func freezeUnavailableDisposition(
            _ reason: WorkspaceCodemapPresentationFreezeUnavailableReason
        ) -> CodemapIssueDisposition {
            switch reason {
            case .emptyRequest, .entryLimitExceeded, .retainedBundleLimitExceeded,
                 .duplicateFileID, .mixedRootEpoch, .pending, .demandUnavailable,
                 .logicalPathMismatch, .staleCurrentness, .handleRevoked:
                .pending
            }
        }

        private static func renderUnavailableDisposition(
            _ reason: WorkspaceCodemapPresentationRenderUnavailableReason,
            fileID: UUID
        ) -> CodemapIssueDisposition? {
            switch reason {
            case .bundleNotRetained, .bundleMetadataMismatch, .staleCurrentness,
                 .handleRevoked:
                .pending
            case let .noRenderableCodemap(unavailableFileID):
                unavailableFileID == fileID ? .unmapped(terminal: true) : nil
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
            contentPolicy: PromptContextAccountingContentPolicy = .loadContent,
            lookupContext: WorkspaceLookupContext? = nil,
            codemapPresentation: WorkspaceCodemapOperationPresentation? = nil,
            issuePathDisplay: FilePathDisplay = .relative
        ) async -> SelectionCollections {
            do {
                return try await withCollections(
                    from: source,
                    owner: owner,
                    rootScope: rootScope,
                    contentPolicy: contentPolicy,
                    lookupContext: lookupContext,
                    codemapPresentation: codemapPresentation,
                    issuePathDisplay: issuePathDisplay
                ) { $0 }
            } catch {
                return await .empty(codeMapUsage: source.currentCodeMapUsage())
            }
        }

        static func withCollections<Value>(
            from source: SelectionSource,
            owner: MCPServerViewModel,
            rootScope: WorkspaceLookupRootScope = .allLoaded,
            contentPolicy: PromptContextAccountingContentPolicy = .loadContent,
            lookupContext: WorkspaceLookupContext? = nil,
            codemapPresentation: WorkspaceCodemapOperationPresentation? = nil,
            issuePathDisplay: FilePathDisplay = .relative,
            operation: (SelectionCollections) async throws -> Value
        ) async throws -> Value {
            let selection = await source.resolvedSelection()
            let usage = await source.currentCodeMapUsage()
            let store = await MainActor.run { owner.promptVM.workspaceFileContextStore }
            let effectiveLookupContext = lookupContext ?? WorkspaceLookupContext(
                rootScope: rootScope,
                bindingProjection: nil
            )
            let rootDisplayNames = await effectiveLookupContext.logicalRootDisplayNamesByRootID(
                store: store
            )
            func resolveCollections(
                presentation: WorkspaceCodemapOperationPresentation
            ) async throws -> Value {
                let accounting = PromptContextAccountingService()
                let resolution = await accounting.resolveEntries(
                    selection: selection,
                    store: store,
                    rootScope: rootScope,
                    profile: .uiAssisted,
                    codeMapUsage: usage,
                    codemapPresentation: presentation,
                    contentPolicy: contentPolicy,
                    codemapLogicalRootDisplayNamesByRootID: rootDisplayNames
                )
                let roots = await store.rootRefs(scope: rootScope)
                let invalid = (resolution.missingPaths + resolution.invalidPaths).map { path in
                    logicalIssuePath(
                        path,
                        roots: roots,
                        rootDisplayNamesByRootID: rootDisplayNames,
                        lookupContext: effectiveLookupContext,
                        display: issuePathDisplay
                    )
                }.sorted(by: utf8Precedes)
                let requestedCodemapFiles = await requestedCodemapFiles(
                    selection: selection,
                    usage: usage,
                    resolution: resolution,
                    store: store,
                    rootScope: rootScope,
                    profile: .uiAssisted
                )
                let collections = makeCollections(
                    resolution: resolution,
                    selection: selection,
                    usage: usage,
                    invalid: invalid,
                    requestedCodemapFiles: requestedCodemapFiles
                )
                try Task.checkCancellation()
                return try await operation(collections)
            }
            if let codemapPresentation {
                return try await resolveCollections(presentation: codemapPresentation)
            }
            let plan = await WorkspaceCodemapPresentationIntentResolver.plan(
                codeMapUsage: usage,
                selection: selection,
                store: store,
                rootScope: rootScope,
                profile: .uiAssisted
            )
            return try await WorkspaceCodemapPresentationCoordinator(
                store: store,
                policy: codemapPresentationPolicy
            ).withPresentation(
                for: plan.intent,
                rootScope: rootScope,
                logicalRootDisplayNamesByRootID: rootDisplayNames
            ) { presentation in
                try await resolveCollections(
                    presentation: WorkspaceCodemapPresentationIntentResolver.merging(
                        presentation,
                        preflightIssues: plan.preflightIssues
                    )
                )
            }
        }

        private static func makeCollections(
            resolution: PromptContextEntryResolution,
            selection: StoredSelection,
            usage: CodeMapUsage,
            invalid: [String],
            requestedCodemapFiles: [WorkspaceFileRecord]
        ) -> SelectionCollections {
            let selected = resolution.entries.compactMap { entry -> SelectedEntry? in
                entry.isCodemap ? nil : SelectedEntry(entry: entry)
            }
            let manualCodemapPaths = Set(
                StoredSelectionPathNormalization.standardizedPaths(selection.manualCodemapPaths)
            )
            let codemap = resolution.entries.compactMap { entry -> CodemapEntry? in
                guard entry.isCodemap else { return nil }
                let origin: CodemapOrigin = switch usage {
                case .selected:
                    manualCodemapPaths.contains(entry.file.standardizedFullPath) ? .manual : .selectedMode
                case .complete: .auto
                case .auto: selection.codemapAutoEnabled ? .auto : .manual
                case .none: .manual
                }
                return CodemapEntry(entry: entry, origin: origin)
            }
            return SelectionCollections(
                selected: selected,
                codemap: codemap,
                requestedCodemapFiles: requestedCodemapFiles,
                codemapAutoEnabled: selection.codemapAutoEnabled,
                codeMapUsage: usage,
                invalid: invalid,
                codemapPresentation: resolution.codemapPresentation
            )
        }

        private static func requestedCodemapFiles(
            selection: StoredSelection,
            usage: CodeMapUsage,
            resolution: PromptContextEntryResolution,
            store: WorkspaceFileContextStore,
            rootScope: WorkspaceLookupRootScope,
            profile: PathLocateProfile
        ) async -> [WorkspaceFileRecord] {
            var files: [WorkspaceFileRecord] = []
            var seen = Set<UUID>()
            func append(_ file: WorkspaceFileRecord?) {
                guard let file, seen.insert(file.id).inserted else { return }
                files.append(file)
            }

            switch usage {
            case .none:
                break
            case .auto:
                if selection.codemapAutoEnabled {
                    for fileID in codemapIssueFileIDs(resolution.codemapPresentation) {
                        await append(store.file(id: fileID))
                    }
                } else {
                    await appendManualCodemapFiles(
                        selection: selection,
                        store: store,
                        rootScope: rootScope,
                        profile: profile,
                        append: append
                    )
                }
            case .selected:
                for entry in resolution.entries {
                    append(entry.file)
                }
                await appendManualCodemapFiles(
                    selection: selection,
                    store: store,
                    rootScope: rootScope,
                    profile: profile,
                    append: append
                )
                for fileID in codemapIssueFileIDs(resolution.codemapPresentation) {
                    await append(store.file(id: fileID))
                }
            case .complete:
                for fileID in codemapIssueFileIDs(resolution.codemapPresentation) {
                    await append(store.file(id: fileID))
                }
            }
            return files
        }

        private static func appendManualCodemapFiles(
            selection: StoredSelection,
            store: WorkspaceFileContextStore,
            rootScope: WorkspaceLookupRootScope,
            profile: PathLocateProfile,
            append: (WorkspaceFileRecord?) -> Void
        ) async {
            guard !selection.manualCodemapPaths.isEmpty else { return }
            let requests = selection.manualCodemapPaths.map {
                WorkspacePathLookupRequest(userPath: $0, profile: profile, rootScope: rootScope)
            }
            let results = await store.lookupPaths(requests)
            for path in selection.manualCodemapPaths {
                append(results[path]?.file)
            }
        }

        private static func codemapIssueFileIDs(
            _ presentation: WorkspaceCodemapOperationPresentation
        ) -> [UUID] {
            var ids: [UUID] = []
            var seen = Set<UUID>()
            func append(_ id: UUID) {
                if seen.insert(id).inserted {
                    ids.append(id)
                }
            }
            for issue in presentation.issues + coverageIssues(presentation.coverage) {
                for id in codemapIssueFileIDs(issue) {
                    append(id)
                }
            }
            return ids
        }

        private static func codemapIssueFileIDs(
            _ issue: WorkspaceCodemapOperationIssue
        ) -> [UUID] {
            switch issue {
            case .coordinationUnavailable, .cancelled, .freezeUnavailable,
                 .publicationStale:
                return []
            case let .automatic(coverage):
                return automaticCoverageFileIDs(coverage)
            case let .candidate(candidateIssue):
                return candidateIssueFileIDs(candidateIssue)
            case let .pending(fileID, _), let .unavailable(fileID, _):
                return [fileID]
            case let .renderUnavailable(_, reason):
                if case let .noRenderableCodemap(fileID) = reason {
                    return [fileID]
                }
                return []
            }
        }

        private static func candidateIssueFileIDs(
            _ issue: WorkspaceCodemapOperationCandidateIssue
        ) -> [UUID] {
            switch issue {
            case let .fileNotCataloged(fileID),
                 let .fileOutsideRootScope(fileID),
                 let .logicalPathUnavailable(fileID):
                [fileID]
            case let .incompleteRootSet(missingFileIDs):
                missingFileIDs
            }
        }

        static func logicalIssuePath(
            _ path: String,
            roots: [WorkspaceRootRef],
            rootDisplayNamesByRootID: [UUID: String],
            lookupContext: WorkspaceLookupContext,
            display: FilePathDisplay
        ) -> String {
            guard path.hasPrefix("/") else { return path }
            let absolute = StandardizedPath.absolute(path)
            let authorizingRoots = roots.filter {
                absolute == $0.standardizedFullPath || absolute.hasPrefix($0.standardizedFullPath + "/")
            }
            guard authorizingRoots.count == 1, let authorizedRoot = authorizingRoots.first else {
                return "unmapped:\(URL(fileURLWithPath: path).lastPathComponent)"
            }
            if let projected = lookupContext.bindingProjection?.projectedLogicalDisplayPath(
                forPhysicalPath: absolute,
                display: display
            ) {
                return projected
            }
            if display == .full {
                return absolute
            }
            if let label = rootDisplayNamesByRootID[authorizedRoot.id] {
                let relative = String(absolute.dropFirst(authorizedRoot.standardizedFullPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return relative.isEmpty ? label : "\(label)/\(relative)"
            }
            return "unmapped:\(URL(fileURLWithPath: path).lastPathComponent)"
        }

        private static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
            lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
        }

        private static func pathMetadata(
            for file: WorkspaceFileRecord,
            entry _: ResolvedPromptFileEntry? = nil,
            formatter: PathFormatter
        ) async -> (rootPath: String, pathWithinRoot: String) {
            if let override = formatter.rootMetadataOverrides[file.standardizedFullPath] {
                let safeRootPath = override.rootPath.hasPrefix("/")
                    ? URL(fileURLWithPath: override.rootPath).lastPathComponent
                    : override.rootPath
                return (safeRootPath, override.pathWithinRoot)
            }
            let store = await MainActor.run { formatter.owner.promptVM.workspaceFileContextStore }
            let lookupContext = WorkspaceLookupContext(
                rootScope: formatter.rootScope,
                bindingProjection: formatter.projection
            )
            let labels = await lookupContext.logicalRootDisplayNamesByRootID(store: store)
            return (
                labels[file.rootID] ?? "workspace",
                file.standardizedRelativePath
            )
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
                let metadata = await pathMetadata(for: file, entry: entry.entry, formatter: formatter)
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
                    let codemapTokenCount = tokens.codemapTokens(
                        for: file,
                        codemapPresentation: collections.codemapPresentation
                    )
                    let hasCodemap = codemapTokenCount > 0
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
                let metadata = await pathMetadata(for: file, entry: entry.entry, formatter: formatter)
                let rawCodemapTokens = tokens.codemapTokens(
                    for: file,
                    codemapPresentation: collections.codemapPresentation
                )
                let tokenCount = if rawCodemapTokens == 0, collections.codeMapUsage == .selected {
                    tokens.fullTokens(for: entry.entry)
                } else {
                    rawCodemapTokens
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
            pathProjection: WorkspaceRootBindingProjection? = nil,
            displayPathOverrides: [String: String] = [:]
        ) async -> ToolResultDTOs.SelectionReply {
            var blocks: [String]? = nil
            if includeBlocks {
                let generated = generateBlocks(
                    selected: collections.selected,
                    codemap: collections.codemap,
                    codemapPresentation: collections.codemapPresentation,
                    display: display,
                    projection: pathProjection,
                    displayPathOverrides: displayPathOverrides
                )
                blocks = generated
            }

            var invalid = collections.invalid
            for candidate in extraInvalid where !invalid.contains(candidate) {
                invalid.append(candidate)
            }

            // MCP replies never await an immediate recount. Use the latest published
            // active-tab snapshot only when no tab-scoped override was prepared, and do not
            // schedule a refresh from reply formatting itself.
            let needsFallbackPublished = tokenStatsOverride == nil || tokenAccountingOverride == nil
            let fallbackPublished: TokenCountingViewModel.PublishedTokenSnapshot? = if needsFallbackPublished {
                await MainActor.run {
                    tokens?.owner.promptVM.tokenCountingViewModel.latestPublishedTokenSnapshot(
                        for: nil,
                        scheduleRefreshIfNeeded: false
                    )
                }
            } else {
                nil
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
            return PromptPackagingService.generateFileContents(
                selected.map(\.entry),
                filePathDisplay: display,
                codemapPresentation: .empty,
                displayPathResolver: { entry in
                    projection?.projectedLogicalDisplayPath(forPhysicalPath: entry.file.standardizedFullPath, display: display)
                }
            )
        }

        static func generateBlocks(
            selected: [SelectedEntry],
            codemap: [CodemapEntry],
            codemapPresentation: WorkspaceCodemapOperationPresentation,
            display: FilePathDisplay,
            projection: WorkspaceRootBindingProjection? = nil,
            displayPathOverrides: [String: String] = [:]
        ) -> [String] {
            let renderableCodemaps = codemap.compactMap { item -> ResolvedPromptFileEntry? in
                if item.origin == .selectedMode || codemapPresentation.renderedEntriesByFileID[item.file.id] != nil {
                    return item.entry
                }
                return nil
            }
            let entries = selected.map(\.entry) + renderableCodemaps
            guard !entries.isEmpty else { return [] }
            let (codemapBlocks, contentBlocks) = PromptPackagingService.generatePartitionedFileBlocks(
                entries,
                filePathDisplay: display,
                codemapPresentation: codemapPresentation,
                displayPathResolver: { entry in
                    displayPathOverrides[entry.file.standardizedFullPath]
                        ?? projection?.projectedLogicalDisplayPath(
                            forPhysicalPath: entry.file.standardizedFullPath,
                            display: display
                        )
                }
            )
            return contentBlocks + codemapBlocks
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
                let metadata = await pathMetadata(for: file, entry: entry.entry, formatter: formatter)
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
                tokenAccounting: reply.tokenAccounting,
                copyPresetProjection: reply.copyPresetProjection
            )
        }
    }

    struct CodeStructureBuilder {
        unowned let owner: MCPServerViewModel
        let lookupContext: WorkspaceLookupContext

        func build(
            for collections: SelectionReplyAssembler.SelectionCollections
        ) async -> ToolResultDTOs.SelectedCodeStructureDTO? {
            await build(
                rendering: collections.selected.map(\.file) + collections.codemap.map(\.file),
                diagnostics: SelectionReplyAssembler.codemapDiagnosticFiles(for: collections),
                presentation: collections.codemapPresentation
            )
        }

        private func build(
            rendering renderingFiles: [WorkspaceFileRecord],
            diagnostics diagnosticFiles: [WorkspaceFileRecord],
            presentation: WorkspaceCodemapOperationPresentation
        ) async -> ToolResultDTOs.SelectedCodeStructureDTO? {
            guard !renderingFiles.isEmpty || !diagnosticFiles.isEmpty else { return nil }
            let disabled = await MainActor.run { owner.promptVM.codeMapsGloballyDisabled }
            guard !disabled else { return nil }

            let fileIDs = Set(renderingFiles.map(\.id))
            let rendered = presentation.orderedEntries.filter { fileIDs.contains($0.fileID) }
            let included = Array(rendered.prefix(25))
            let diagnostics = await SelectionReplyAssembler.missingCodemapDiagnostics(
                for: diagnosticFiles,
                presentation: presentation
            ) { file in
                if let projected = lookupContext.bindingProjection?.projectedLogicalDisplayPath(
                    forPhysicalPath: file.standardizedFullPath,
                    display: .relative
                ) {
                    return projected
                }
                return file.standardizedRelativePath
            }
            guard !included.isEmpty || !diagnostics.isEmpty else { return nil }
            return ToolResultDTOs.SelectedCodeStructureDTO(
                fileCount: included.count,
                content: included.map(\.text).joined(separator: "\n\n"),
                unmappedPaths: diagnostics.unmappedPaths.isEmpty ? nil : diagnostics.unmappedPaths,
                pendingPaths: diagnostics.pendingPaths.isEmpty ? nil : diagnostics.pendingPaths,
                omittedCount: rendered.count > included.count ? rendered.count - included.count : nil,
                worktreeScope: ToolResultDTOs.WorktreeScopeDTO.sessionBound(
                    from: lookupContext.bindingProjection
                )
            )
        }
    }
}
