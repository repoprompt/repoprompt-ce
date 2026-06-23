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
    /// Canonical codemap inclusion is now controlled exclusively by `selection.autoCodemapPaths`.
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
    let codemapSnapshotBundle: WorkspaceCodemapSnapshotBundle
    let fileTreeContent: String?
    let gitDiff: String?
    let gitDiffResolution: PromptGitDiffResolution
    let selectedGitArtifactDispositions: [SelectedGitArtifactDisposition]
    let lookupContext: WorkspaceLookupContext
    let filePathDisplay: FilePathDisplay

    func displayPath(for entry: ResolvedPromptFileEntry) -> String? {
        lookupContext.bindingProjection?.projectedLogicalDisplayPath(
            forPhysicalPath: entry.file.standardizedFullPath,
            display: filePathDisplay
        )
    }
}

enum PromptContextPreAssemblyService {
    private struct ArtifactSnapshotEntry: Equatable {
        let path: String
        let content: String?
    }

    static func resolve(_ request: PromptContextPreAssemblyRequest) async -> PromptContextPreAssemblyResult {
        precondition(
            request.finalReviewAuthorization == nil,
            "Strict Context Builder review packaging must use resolveStrict"
        )
        let physicalSelection = request.lookupContext.physicalizeSelection(request.selection)
        let artifactAuthorization = await authorizeSelectedGitArtifacts(
            request: request,
            physicalSelection: physicalSelection
        )
        do {
            return try await resolveCore(
                request,
                physicalSelection: physicalSelection,
                artifactAuthorization: artifactAuthorization
            )
        } catch {
            preconditionFailure("Non-strict prompt preassembly unexpectedly failed: \(error)")
        }
    }

    static func resolveStrict(
        _ request: PromptContextPreAssemblyRequest
    ) async throws -> PromptContextPreAssemblyResult {
        guard let authorization = request.finalReviewAuthorization else {
            return await resolve(request)
        }
        let physicalSelection = request.lookupContext.physicalizeSelection(request.selection)
        let artifactAuthorization = try await validateStrictAuthorization(
            request: request,
            physicalSelection: physicalSelection,
            authorization: authorization
        )
        let result = try await resolveCore(
            request,
            physicalSelection: physicalSelection,
            artifactAuthorization: artifactAuthorization
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
        return result
    }

    private static func resolveCore(
        _ request: PromptContextPreAssemblyRequest,
        physicalSelection: StoredSelection,
        artifactAuthorization: SelectedGitArtifactAuthorizationResult
    ) async throws -> PromptContextPreAssemblyResult {
        let ordinaryRootScope = request.lookupContext.rootScope.excludingWorkspaceGitData
        let ordinarySelection = selection(
            physicalSelection,
            excluding: artifactAuthorization.consumedSelectionPaths
        )
        let codemapSnapshotBundle = await request.store.codemapSnapshotBundle(
            rootScope: ordinaryRootScope
        )
        let accountingService = PromptContextAccountingService()
        let resolution = await accountingService.resolveEntries(
            selection: ordinarySelection,
            store: request.store,
            rootScope: ordinaryRootScope,
            profile: request.entryResolutionProfile,
            codeMapUsage: request.codeMapUsage,
            codemapSnapshotBundle: codemapSnapshotBundle
        )
        let fileTreeContent = await resolveFileTreeContent(
            request: request,
            physicalSelection: ordinarySelection,
            codemapSnapshotBundle: codemapSnapshotBundle,
            rootScope: ordinaryRootScope
        )
        let allEntries = artifactAuthorization.entries + resolution.entries
        let gitDiffResolution = try await resolveGitDiff(
            request: request,
            physicalSelection: ordinarySelection,
            entries: allEntries,
            rootScope: ordinaryRootScope
        )
        let packagingEntries = entriesForPackaging(request: request, entries: allEntries)

        return PromptContextPreAssemblyResult(
            physicalSelection: physicalSelection,
            entries: packagingEntries,
            missingPaths: resolution.missingPaths,
            invalidPaths: resolution.invalidPaths,
            codemapSnapshotBundle: codemapSnapshotBundle,
            fileTreeContent: fileTreeContent,
            gitDiff: gitDiffResolution.text,
            gitDiffResolution: gitDiffResolution,
            selectedGitArtifactDispositions: artifactAuthorization.dispositions,
            lookupContext: request.lookupContext,
            filePathDisplay: request.filePathDisplay
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
            autoCodemapPaths: selection.autoCodemapPaths.filter { !isConsumed($0) },
            slices: selection.slices.filter { !isConsumed($0.key) },
            codemapAutoEnabled: selection.codemapAutoEnabled
        )
    }

    private static func resolveFileTreeContent(
        request: PromptContextPreAssemblyRequest,
        physicalSelection: StoredSelection,
        codemapSnapshotBundle: WorkspaceCodemapSnapshotBundle,
        rootScope: WorkspaceLookupRootScope
    ) async -> String? {
        guard request.cfg.rendersFileTree else { return nil }

        let rawFileTreeSnapshot = await request.store.makeFileTreeSelectionSnapshot(
            selection: physicalSelection,
            request: WorkspaceFileTreeSnapshotRequest(
                mode: WorkspaceFileTreeSnapshotMode(fileTreeOption: request.cfg.effectiveFileTreeMode),
                filePathDisplay: request.filePathDisplay,
                onlyIncludeRootsWithSelectedFiles: request.onlyIncludeRootsWithSelectedFiles,
                includeLegend: request.includeFileTreeLegend,
                showCodeMapMarkers: request.showCodeMapMarkers,
                rootScope: rootScope
            ),
            codemapSnapshotBundle: codemapSnapshotBundle,
            profile: request.entryResolutionProfile
        )
        let fileTreeSnapshot = request.lookupContext.bindingProjection?.logicalizeFileTreeSnapshot(rawFileTreeSnapshot) ?? rawFileTreeSnapshot
        let tree = CodeMapExtractor.generateFileTree(using: fileTreeSnapshot)
        return tree.isEmpty ? nil : tree
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
    ) async throws -> PromptGitDiffResolution {
        let (diffEntries, _) = PromptPackagingService.partitionPromptEntriesForGitDiff(entries)
        if request.selectedGitDiffArtifactPolicy == .respectGitInclusion,
           request.cfg.gitInclusion == .none
        {
            return .none
        }

        if let selected = PromptPackagingService.selectedGitDiffText(fromDiffEntries: diffEntries) {
            return .selectedArtifact(selected)
        }

        switch request.cfg.gitInclusion {
        case .none:
            return .none
        case .selected:
            if let authorization = request.finalReviewAuthorization {
                let result = await request.selectedGitDiffProvider(
                    AutomaticReviewGitDiffRequest(
                        finalReviewAuthorization: authorization,
                        compareIntent: request.reviewGitContext.compareIntent,
                        displayContext: authorization.target.displayContext
                    )
                )
                if let failure = result.authorizationFailure {
                    throw failure
                }
                return .automatic(result)
            }
            let pathResolution = await WorkspaceGitDiffSelectionResolver.resolveSelectedGitDiffPaths(
                for: physicalSelection,
                store: request.store,
                rootScope: rootScope,
                folderPolicy: request.selectedGitDiffFolderPolicy,
                profile: request.selectedGitDiffLookupProfile,
                allowFilesystemFallback: rootScope.allowsSelectedGitDiffFilesystemFallback,
                excluding: []
            )
            let result = await request.selectedGitDiffProvider(
                AutomaticReviewGitDiffRequest(
                    pathResolution: pathResolution,
                    compareIntent: request.reviewGitContext.compareIntent,
                    displayContext: request.reviewGitContext.displayContext
                )
            )
            return .automatic(result)
        case .complete:
            if request.lookupContext.bindingProjection != nil {
                return .complete(PromptContextGitDiffPolicy.deferredCompleteWorktreeGitDiffMessage)
            }
            return await .complete(request.completeGitDiffProvider())
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
