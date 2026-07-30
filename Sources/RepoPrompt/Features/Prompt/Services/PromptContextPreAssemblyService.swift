import Foundation

enum SelectedGitDiffArtifactPolicy {
    case includeBeforeGitInclusion
    case respectGitInclusion
}

struct PromptContextPreAssemblyRequest {
    let cfg: PromptContextResolved
    let selection: StoredSelection
    let store: WorkspaceFileContextStore
    let lookupContext: WorkspaceLookupContext
    let filePathDisplay: FilePathDisplay
    let onlyIncludeRootsWithSelectedFiles: Bool
    let includeFileTreeLegend: Bool
    let showCodeMapMarkers: Bool
    let codeMapUsage: CodeMapUsage
    let entryResolutionProfile: PathLocateProfile
    let selectedGitDiffFolderPolicy: SelectedGitDiffFolderPolicy
    let selectedGitDiffLookupProfile: PathLocateProfile
    /// Compatibility input retained for callers that previously requested hidden local-definition discovery.
    let includeLocalDefinitionsInFileTree: Bool
    let selectedGitDiffArtifactPolicy: SelectedGitDiffArtifactPolicy
    let reviewGitContext: FrozenPromptGitReviewContext
    let sourceTabID: UUID?
    let finalReviewAuthorization: ContextBuilderFinalReviewAuthorization?
    let selectedGitDiffProvider: (AutomaticReviewGitDiffRequest) async -> AutomaticReviewGitDiffResult
    let completeGitDiffProvider: () async -> String?

    init(
        cfg: PromptContextResolved,
        selection: StoredSelection,
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext,
        filePathDisplay: FilePathDisplay,
        onlyIncludeRootsWithSelectedFiles: Bool,
        includeFileTreeLegend: Bool = true,
        showCodeMapMarkers: Bool,
        codeMapUsage: CodeMapUsage? = nil,
        entryResolutionProfile: PathLocateProfile = .uiAssisted,
        selectedGitDiffFolderPolicy: SelectedGitDiffFolderPolicy,
        selectedGitDiffLookupProfile: PathLocateProfile? = nil,
        includeLocalDefinitionsInFileTree: Bool = false,
        selectedGitDiffArtifactPolicy: SelectedGitDiffArtifactPolicy = .includeBeforeGitInclusion,
        reviewGitContext: FrozenPromptGitReviewContext,
        sourceTabID: UUID? = nil,
        finalReviewAuthorization: ContextBuilderFinalReviewAuthorization? = nil,
        selectedGitDiffProvider: @escaping (AutomaticReviewGitDiffRequest) async -> AutomaticReviewGitDiffResult,
        completeGitDiffProvider: @escaping () async -> String?
    ) {
        self.cfg = cfg
        self.selection = selection
        self.store = store
        self.lookupContext = lookupContext
        self.filePathDisplay = filePathDisplay
        self.onlyIncludeRootsWithSelectedFiles = onlyIncludeRootsWithSelectedFiles
        self.includeFileTreeLegend = includeFileTreeLegend
        self.showCodeMapMarkers = showCodeMapMarkers
        self.codeMapUsage = codeMapUsage ?? cfg.codeMapUsage
        self.entryResolutionProfile = entryResolutionProfile
        self.selectedGitDiffFolderPolicy = selectedGitDiffFolderPolicy
        self.selectedGitDiffLookupProfile = selectedGitDiffLookupProfile ?? entryResolutionProfile
        self.includeLocalDefinitionsInFileTree = includeLocalDefinitionsInFileTree
        self.selectedGitDiffArtifactPolicy = selectedGitDiffArtifactPolicy
        self.reviewGitContext = reviewGitContext
        self.sourceTabID = sourceTabID
        self.finalReviewAuthorization = finalReviewAuthorization
        self.selectedGitDiffProvider = selectedGitDiffProvider
        self.completeGitDiffProvider = completeGitDiffProvider
    }
}

enum PromptGitDiffResolution: Equatable {
    case none
    case selectedArtifact(String)
    case automatic(AutomaticReviewGitDiffResult)
    case complete(String?)

    var text: String? {
        switch self {
        case .none:
            nil
        case let .selectedArtifact(text):
            text
        case let .automatic(result):
            result.text
        case let .complete(text):
            text
        }
    }
}

struct PromptContextPreAssemblyResult {
    let physicalSelection: StoredSelection
    let entries: [ResolvedPromptFileEntry]
    let missingPaths: [String]
    let invalidPaths: [String]
    let codemapPresentation: WorkspaceCodemapOperationPresentation
    let fileTreeContent: String?
    let gitDiff: String?
    let gitDiffResolution: PromptGitDiffResolution
    let selectedGitArtifactDispositions: [SelectedGitArtifactDisposition]
    let lookupContext: WorkspaceLookupContext
    let filePathDisplay: FilePathDisplay
    let roots: [WorkspaceRootRef]
    let logicalRootDisplayNamesByRootID: [UUID: String]

    func displayPath(for entry: ResolvedPromptFileEntry) -> String? {
        lookupContext.logicalDisplayPath(
            for: entry.file,
            roots: roots,
            rootDisplayNamesByRootID: logicalRootDisplayNamesByRootID,
            display: filePathDisplay
        )
    }
}

enum PromptContextPreAssemblyService {
    private struct ArtifactSnapshotEntry: Equatable {
        let path: String
        let content: String?
    }

    private struct PreparedRequest {
        let physicalSelection: StoredSelection
        let ordinarySelection: StoredSelection
        let ordinaryRootScope: WorkspaceLookupRootScope
        let artifactAuthorization: SelectedGitArtifactAuthorizationResult
    }

    static func resolve(
        _ request: PromptContextPreAssemblyRequest,
        accountingService: PromptContextAccountingService = PromptContextAccountingService(),
        codemapPresentation: WorkspaceCodemapOperationPresentation? = nil
    ) async -> PromptContextPreAssemblyResult {
        do {
            return try await withResolved(
                request,
                accountingService: accountingService,
                codemapPresentation: codemapPresentation
            ) { $0 }
        } catch {
            let issue: WorkspaceCodemapOperationIssue = if Task.isCancelled || error is CancellationError {
                .cancelled
            } else {
                .coordinationUnavailable
            }
            return emptyResult(request: request, issue: issue)
        }
    }

    static func withResolved<Value>(
        _ request: PromptContextPreAssemblyRequest,
        accountingService: PromptContextAccountingService = PromptContextAccountingService(),
        codemapPresentation: WorkspaceCodemapOperationPresentation? = nil,
        presentationCoordinator: WorkspaceCodemapPresentationCoordinator? = nil,
        operation: (PromptContextPreAssemblyResult) async throws -> Value
    ) async throws -> Value {
        precondition(
            request.finalReviewAuthorization == nil,
            "Strict Context Builder review packaging must use withResolvedStrict"
        )
        let prepared = await prepare(request)
        return try await withPrepared(
            request: request,
            prepared: prepared,
            accountingService: accountingService,
            codemapPresentation: codemapPresentation,
            presentationCoordinator: presentationCoordinator,
            operation: operation
        )
    }

    static func withResolvedStrict<Value>(
        _ request: PromptContextPreAssemblyRequest,
        accountingService: PromptContextAccountingService = PromptContextAccountingService(),
        codemapPresentation: WorkspaceCodemapOperationPresentation? = nil,
        presentationCoordinator: WorkspaceCodemapPresentationCoordinator? = nil,
        operation: (PromptContextPreAssemblyResult) async throws -> Value
    ) async throws -> Value {
        guard let authorization = request.finalReviewAuthorization else {
            return try await withResolved(
                request,
                accountingService: accountingService,
                codemapPresentation: codemapPresentation,
                presentationCoordinator: presentationCoordinator,
                operation: operation
            )
        }
        let physicalSelection = request.lookupContext.physicalizeSelection(request.selection)
        let artifactAuthorization = try await validateStrictAuthorization(
            request: request,
            physicalSelection: physicalSelection,
            authorization: authorization
        )
        let ordinaryRootScope = request.lookupContext.rootScope.excludingWorkspaceGitData
        let prepared = PreparedRequest(
            physicalSelection: physicalSelection,
            ordinarySelection: selection(
                physicalSelection,
                excluding: artifactAuthorization.consumedSelectionPaths
            ),
            ordinaryRootScope: ordinaryRootScope,
            artifactAuthorization: artifactAuthorization
        )
        let value = try await withPrepared(
            request: request,
            prepared: prepared,
            accountingService: accountingService,
            codemapPresentation: codemapPresentation,
            presentationCoordinator: presentationCoordinator,
            operation: operation
        )
        let finalArtifactAuthorization = try await validateStrictAuthorization(
            request: request,
            physicalSelection: physicalSelection,
            authorization: authorization
        )
        guard artifactSnapshot(finalArtifactAuthorization) == artifactSnapshot(artifactAuthorization) else {
            throw ContextBuilderReviewTargetUnavailableReason.unauthorizedSelectedArtifact(
                count: authorization.selectedArtifactAuthorizations.count
            )
        }
        return value
    }

    static func resolveStrict(
        _ request: PromptContextPreAssemblyRequest
    ) async throws -> PromptContextPreAssemblyResult {
        try await withResolvedStrict(request) { $0 }
    }

    private static func withPrepared<Value>(
        request: PromptContextPreAssemblyRequest,
        prepared: PreparedRequest,
        accountingService: PromptContextAccountingService,
        codemapPresentation: WorkspaceCodemapOperationPresentation?,
        presentationCoordinator: WorkspaceCodemapPresentationCoordinator?,
        operation: (PromptContextPreAssemblyResult) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        if let codemapPresentation {
            let result = try await buildResult(
                request: request,
                prepared: prepared,
                accountingService: accountingService,
                codemapPresentation: codemapPresentation
            )
            try Task.checkCancellation()
            return try await operation(result)
        }
        let plan = await WorkspaceCodemapPresentationIntentResolver.plan(
            codeMapUsage: request.codeMapUsage,
            selection: prepared.ordinarySelection,
            store: request.store,
            rootScope: prepared.ordinaryRootScope,
            profile: request.entryResolutionProfile
        )
        let rootDisplayNames = await request.lookupContext.logicalRootDisplayNamesByRootID(
            store: request.store
        )
        let coordinator = presentationCoordinator ?? WorkspaceCodemapPresentationCoordinator(
            store: request.store
        )
        return try await coordinator.withPresentation(
            for: plan.intent,
            rootScope: prepared.ordinaryRootScope,
            logicalRootDisplayNamesByRootID: rootDisplayNames
        ) { presentation in
            let result = try await buildResult(
                request: request,
                prepared: prepared,
                accountingService: accountingService,
                codemapPresentation: WorkspaceCodemapPresentationIntentResolver.merging(
                    presentation,
                    preflightIssues: plan.preflightIssues
                )
            )
            try Task.checkCancellation()
            return try await operation(result)
        }
    }

    private static func prepare(
        _ request: PromptContextPreAssemblyRequest
    ) async -> PreparedRequest {
        let physicalSelection = request.lookupContext.physicalizeSelection(request.selection)
        let ordinaryRootScope = request.lookupContext.rootScope.excludingWorkspaceGitData
        let artifactAuthorization = await authorizeSelectedGitArtifacts(
            request: request,
            physicalSelection: physicalSelection
        )
        let ordinarySelection = selection(
            physicalSelection,
            excluding: artifactAuthorization.consumedSelectionPaths
        )
        return PreparedRequest(
            physicalSelection: physicalSelection,
            ordinarySelection: ordinarySelection,
            ordinaryRootScope: ordinaryRootScope,
            artifactAuthorization: artifactAuthorization
        )
    }

    private static func buildResult(
        request: PromptContextPreAssemblyRequest,
        prepared: PreparedRequest,
        accountingService: PromptContextAccountingService,
        codemapPresentation: WorkspaceCodemapOperationPresentation
    ) async throws -> PromptContextPreAssemblyResult {
        let logicalRootDisplayNamesByRootID = await request.lookupContext
            .logicalRootDisplayNamesByRootID(store: request.store)
        let roots = await request.store.rootRefs(scope: prepared.ordinaryRootScope)
        let resolution = await accountingService.resolveEntries(
            selection: prepared.ordinarySelection,
            store: request.store,
            rootScope: prepared.ordinaryRootScope,
            profile: request.entryResolutionProfile,
            codeMapUsage: request.codeMapUsage,
            codemapPresentation: codemapPresentation,
            codemapLogicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
        )
        let fileTreeSelection = fileTreeSelectionForPreassembly(
            base: prepared.ordinarySelection,
            resolvedEntries: resolution.entries,
            request: request
        )
        let fileTreeContent = await resolveFileTreeContent(
            request: request,
            physicalSelection: fileTreeSelection,
            codemapPresentation: resolution.codemapPresentation,
            rootScope: prepared.ordinaryRootScope
        )
        let allEntries = prepared.artifactAuthorization.entries + resolution.entries
        let gitDiffResolution = try await resolveGitDiff(
            request: request,
            physicalSelection: prepared.ordinarySelection,
            entries: allEntries,
            rootScope: prepared.ordinaryRootScope
        )
        let packagingEntries = entriesForPackaging(request: request, entries: allEntries)

        return PromptContextPreAssemblyResult(
            physicalSelection: prepared.physicalSelection,
            entries: packagingEntries,
            missingPaths: resolution.missingPaths,
            invalidPaths: resolution.invalidPaths,
            codemapPresentation: resolution.codemapPresentation,
            fileTreeContent: fileTreeContent,
            gitDiff: gitDiffResolution.text,
            gitDiffResolution: gitDiffResolution,
            selectedGitArtifactDispositions: prepared.artifactAuthorization.dispositions,
            lookupContext: request.lookupContext,
            filePathDisplay: request.filePathDisplay,
            roots: roots,
            logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
        )
    }

    private static func emptyResult(
        request: PromptContextPreAssemblyRequest,
        issue: WorkspaceCodemapOperationIssue
    ) -> PromptContextPreAssemblyResult {
        let presentation = WorkspaceCodemapOperationPresentation(
            orderedEntries: [],
            coverage: .unavailable([issue]),
            issues: [issue],
            publicationReceipt: nil
        )
        return PromptContextPreAssemblyResult(
            physicalSelection: request.lookupContext.physicalizeSelection(request.selection),
            entries: [],
            missingPaths: [],
            invalidPaths: [],
            codemapPresentation: presentation,
            fileTreeContent: nil,
            gitDiff: nil,
            gitDiffResolution: .none,
            selectedGitArtifactDispositions: [],
            lookupContext: request.lookupContext,
            filePathDisplay: request.filePathDisplay,
            roots: [],
            logicalRootDisplayNamesByRootID: [:]
        )
    }

    private static func validateStrictAuthorization(
        request: PromptContextPreAssemblyRequest,
        physicalSelection: StoredSelection,
        authorization: ContextBuilderFinalReviewAuthorization
    ) async throws -> SelectedGitArtifactAuthorizationResult {
        guard request.sourceTabID == authorization.tabID,
              request.selection == authorization.committedSelection,
              request.lookupContext == authorization.lookupContext,
              request.reviewGitContext == authorization.reviewGitContext,
              authorization.workspaceID == authorization.target.workspaceID,
              authorization.tabID == authorization.target.tabID,
              authorization.committedSelectionRevision == authorization.target.sourceSelectionRevision,
              authorization.reviewGitContext.artifactCapability == authorization.target.artifactCapability,
              authorization.reviewGitContext.displayContext == authorization.target.displayContext
        else {
            throw ContextBuilderReviewTargetUnavailableReason.workspaceOrTabMismatch
        }
        guard authorization.selectedArtifactAuthorizations.allSatisfy({ artifact in
            authorization.target.checkouts.contains { $0.matches(artifact.provenance) }
        }) else {
            throw ContextBuilderReviewTargetUnavailableReason.unauthorizedSelectedArtifact(
                count: authorization.selectedArtifactAuthorizations.count
            )
        }

        if let reason = await ContextBuilderReviewTargetResolver().revalidate(
            authorization.target,
            store: request.store
        ) {
            throw reason
        }

        let candidatePaths = SelectedGitArtifactSelectionClassifier.artifactCandidatePaths(
            from: physicalSelection,
            capability: request.reviewGitContext.artifactCapability
        )
        let candidateIdentities = try Set(candidatePaths.map { rawPath -> String in
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("/"), !StandardizedPath.containsNUL(trimmed) else {
                throw ContextBuilderReviewTargetUnavailableReason.unauthorizedSelectedArtifact(
                    count: candidatePaths.count
                )
            }
            return StandardizedPath.absolute(trimmed)
        })
        let expectedIdentities = Set(
            authorization.selectedArtifactAuthorizations.map(\.absolutePath)
        )
        guard candidateIdentities == expectedIdentities else {
            throw ContextBuilderReviewTargetUnavailableReason.unauthorizedSelectedArtifact(
                count: max(candidateIdentities.count, expectedIdentities.count)
            )
        }

        let artifactAuthorization: SelectedGitArtifactAuthorizationResult
        if let capability = request.reviewGitContext.artifactCapability {
            artifactAuthorization = await SelectedGitDiffArtifactAuthorizationService().authorize(
                SelectedGitArtifactAuthorizationRequest(
                    physicalSelection: physicalSelection,
                    capability: capability,
                    store: request.store,
                    delegationConsumer: request.reviewGitContext.artifactDelegationConsumer
                )
            )
        } else {
            guard candidateIdentities.isEmpty, expectedIdentities.isEmpty else {
                throw ContextBuilderReviewTargetUnavailableReason.unauthorizedSelectedArtifact(
                    count: max(candidateIdentities.count, expectedIdentities.count)
                )
            }
            artifactAuthorization = SelectedGitArtifactAuthorizationResult(
                entries: [],
                consumedSelectionPaths: [],
                dispositions: []
            )
        }

        guard artifactAuthorization.rejectedDisplayDiagnostics.isEmpty else {
            throw ContextBuilderReviewTargetUnavailableReason.unauthorizedSelectedArtifact(
                count: artifactAuthorization.rejectedDisplayDiagnostics.count
            )
        }
        let actualAuthorizations = artifactAuthorization.dispositions.compactMap {
            disposition -> ContextBuilderFinalSelectedArtifactAuthorization? in
            guard case let .authorized(path, kind, readability) = disposition,
                  let provenance = artifactAuthorization.checkoutProvenanceByAbsolutePath[path]
            else { return nil }
            return ContextBuilderFinalSelectedArtifactAuthorization(
                absolutePath: path,
                kind: kind,
                readability: readability,
                provenance: provenance
            )
        }.sorted { $0.absolutePath < $1.absolutePath }
        let expectedAuthorizations = authorization.selectedArtifactAuthorizations.sorted {
            $0.absolutePath < $1.absolutePath
        }
        guard actualAuthorizations == expectedAuthorizations else {
            throw ContextBuilderReviewTargetUnavailableReason.unauthorizedSelectedArtifact(
                count: max(actualAuthorizations.count, expectedAuthorizations.count)
            )
        }

        if let reason = await ContextBuilderReviewTargetResolver().revalidate(
            authorization.target,
            store: request.store
        ) {
            throw reason
        }
        return artifactAuthorization
    }

    private static func artifactSnapshot(
        _ authorization: SelectedGitArtifactAuthorizationResult
    ) -> [ArtifactSnapshotEntry] {
        authorization.entries
            .map {
                ArtifactSnapshotEntry(
                    path: $0.file.standardizedFullPath,
                    content: $0.loadedContent
                )
            }
            .sorted { $0.path < $1.path }
    }

    private static func authorizeSelectedGitArtifacts(
        request: PromptContextPreAssemblyRequest,
        physicalSelection: StoredSelection
    ) async -> SelectedGitArtifactAuthorizationResult {
        guard let capability = request.reviewGitContext.artifactCapability else {
            return SelectedGitArtifactAuthorizationResult(
                entries: [],
                consumedSelectionPaths: [],
                dispositions: []
            )
        }
        return await SelectedGitDiffArtifactAuthorizationService().authorize(
            SelectedGitArtifactAuthorizationRequest(
                physicalSelection: physicalSelection,
                capability: capability,
                store: request.store,
                delegationConsumer: request.reviewGitContext.artifactDelegationConsumer
            )
        )
    }

    private static func selection(
        _ selection: StoredSelection,
        excluding consumedPaths: Set<String>
    ) -> StoredSelection {
        guard !consumedPaths.isEmpty else { return selection }
        let normalizedConsumed = Set(consumedPaths.compactMap(StoredSelectionPathNormalization.standardizedPath))
        func isConsumed(_ path: String) -> Bool {
            consumedPaths.contains(path)
                || StoredSelectionPathNormalization.standardizedPath(path).map(normalizedConsumed.contains) == true
        }
        return StoredSelection(
            selectedPaths: selection.selectedPaths.filter { !isConsumed($0) },
            manualCodemapPaths: selection.manualCodemapPaths,
            slices: selection.slices.filter { !isConsumed($0.key) },
            codemapAutoEnabled: selection.codemapAutoEnabled
        )
    }

    private static func fileTreeSelectionForPreassembly(
        base: StoredSelection,
        resolvedEntries: [ResolvedPromptFileEntry],
        request: PromptContextPreAssemblyRequest
    ) -> StoredSelection {
        guard request.codeMapUsage == .auto,
              base.codemapAutoEnabled
        else { return base }

        var selectedPaths = base.selectedPaths
        var seen = Set(selectedPaths.compactMap(StoredSelectionPathNormalization.standardizedPath))
        for entry in resolvedEntries where entry.isCodemap && entry.mode == .codemap {
            let path = entry.file.standardizedFullPath
            let key = StoredSelectionPathNormalization.standardizedPath(path) ?? path
            guard seen.insert(key).inserted else { continue }
            selectedPaths.append(path)
        }
        guard selectedPaths.count != base.selectedPaths.count else { return base }
        return StoredSelection(
            selectedPaths: selectedPaths,
            slices: base.slices,
            codemapAutoEnabled: base.codemapAutoEnabled
        )
    }

    private static func resolveFileTreeContent(
        request: PromptContextPreAssemblyRequest,
        physicalSelection: StoredSelection,
        codemapPresentation: WorkspaceCodemapOperationPresentation,
        rootScope: WorkspaceLookupRootScope
    ) async -> String? {
        guard request.cfg.rendersFileTree else { return nil }

        let presentation = await request.store.makeFileTreePresentation(
            selection: physicalSelection,
            request: WorkspaceFileTreePresentationRequest(
                mode: WorkspaceFileTreePresentationMode(fileTreeOption: request.cfg.effectiveFileTreeMode),
                filePathDisplay: request.filePathDisplay,
                onlyIncludeRootsWithSelectedFiles: request.onlyIncludeRootsWithSelectedFiles,
                includeLegend: request.includeFileTreeLegend,
                showCodeMapMarkers: request.showCodeMapMarkers,
                rootScope: rootScope
            ),
            lookupContext: request.lookupContext,
            codemapPresentation: codemapPresentation,
            profile: request.entryResolutionProfile
        )
        return presentation.content.isEmpty ? nil : presentation.content
    }

    private static func entriesForPackaging(
        request: PromptContextPreAssemblyRequest,
        entries: [ResolvedPromptFileEntry]
    ) -> [ResolvedPromptFileEntry] {
        guard request.selectedGitDiffArtifactPolicy == .respectGitInclusion,
              request.cfg.gitInclusion == .none
        else { return entries }
        let (_, codeEntries) = PromptPackagingService.partitionPromptEntriesForGitDiff(entries)
        return codeEntries
    }

    private static func resolveGitDiff(
        request: PromptContextPreAssemblyRequest,
        physicalSelection: StoredSelection,
        entries: [ResolvedPromptFileEntry],
        rootScope: WorkspaceLookupRootScope
    ) async -> PromptGitDiffResolution {
        let (diffEntries, _) = PromptPackagingService.partitionPromptEntriesForGitDiff(entries)
        if request.selectedGitDiffArtifactPolicy == .respectGitInclusion,
           request.cfg.gitInclusion == .none
        {
            return .none
        }

        return await PromptPackagingService.resolveGitDiffResolution(fromDiffEntries: diffEntries) {
            switch request.cfg.gitInclusion {
            case .none:
                return .none
            case .selected:
                let pathResolution = await WorkspaceGitDiffSelectionResolver.resolveSelectedGitDiffPaths(
                    for: physicalSelection,
                    store: request.store,
                    rootScope: rootScope,
                    folderPolicy: request.selectedGitDiffFolderPolicy,
                    profile: request.selectedGitDiffLookupProfile,
                    allowFilesystemFallback: rootScope.allowsSelectedGitDiffFilesystemFallback,
                    excluding: []
                )
                let automaticRequest = if let finalReviewAuthorization = request.finalReviewAuthorization {
                    AutomaticReviewGitDiffRequest(
                        finalReviewAuthorization: finalReviewAuthorization,
                        compareIntent: request.reviewGitContext.compareIntent,
                        displayContext: request.reviewGitContext.displayContext
                    )
                } else {
                    AutomaticReviewGitDiffRequest(
                        pathResolution: pathResolution,
                        compareIntent: request.reviewGitContext.compareIntent,
                        displayContext: request.reviewGitContext.displayContext
                    )
                }
                let result = await request.selectedGitDiffProvider(automaticRequest)
                return .automatic(result)
            case .complete:
                if request.lookupContext.bindingProjection != nil {
                    return .complete(PromptContextGitDiffPolicy.deferredCompleteWorktreeGitDiffMessage)
                }
                return await .complete(request.completeGitDiffProvider())
            }
        }
    }
}

extension WorkspaceLookupRootScope {
    var excludingWorkspaceGitData: WorkspaceLookupRootScope {
        switch self {
        case .visibleWorkspace, .sessionBoundWorkspace, .validatedSessionBoundWorkspace:
            self
        case .visibleWorkspacePlusGitData:
            .visibleWorkspace
        case .allLoaded, .allLoadedExcludingGitData:
            .allLoadedExcludingGitData
        }
    }
}
