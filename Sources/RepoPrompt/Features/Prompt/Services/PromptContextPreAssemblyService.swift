import Foundation
import RepoPromptCore

enum SelectedGitDiffArtifactPolicy {
    case includeBeforeGitInclusion
    case respectGitInclusion
}

struct PromptContextPreAssemblyRequest {
    let cfg: PromptContextResolved
    let selection: StoredSelection
    /// App-owned artifact authorization receives only exact frozen-root catalog operations.
    let authorizationCatalog: any PromptGitAuthorizationCatalogReading
    #if DEBUG
        /// XCTest-only compatibility for legacy callers that intentionally omit a provider.
        let debugAuthorizationStore: WorkspaceFileContextStore
    #endif
    let lookupContext: WorkspaceLookupContext
    let factualProvider: (any PromptFactualContextProviding)?
    let admissionToken: WorkspaceSessionAdmissionToken?
    let filePathDisplay: FilePathDisplay
    let onlyIncludeRootsWithSelectedFiles: Bool
    let includeFileTreeLegend: Bool
    let showCodeMapMarkers: Bool
    let codeMapUsage: CodeMapUsage
    let entryResolutionProfile: PathLocateProfile
    let selectedGitDiffFolderPolicy: SelectedGitDiffFolderPolicy
    let selectedGitDiffLookupProfile: PathLocateProfile
    let factualIngressPolicy: PromptFactualIngressPolicy
    let includeLocalDefinitionsInFileTree: Bool
    let selectedGitDiffArtifactPolicy: SelectedGitDiffArtifactPolicy
    let reviewGitContext: FrozenPromptGitReviewContext
    let sourceTabID: UUID?
    let finalReviewAuthorization: ContextBuilderFinalReviewAuthorization?
    let sessionQuery: WorkspaceSessionQueryCapability?
    let selectedGitDiffProvider: (AutomaticReviewGitDiffRequest) async -> AutomaticReviewGitDiffResult
    let completeGitDiffProvider: () async -> String?

    init(
        cfg: PromptContextResolved,
        selection: StoredSelection,
        store: WorkspaceFileContextStore,
        authorizationCatalog: (any PromptGitAuthorizationCatalogReading)? = nil,
        lookupContext: WorkspaceLookupContext,
        factualProvider: (any PromptFactualContextProviding)? = nil,
        admissionToken: WorkspaceSessionAdmissionToken? = nil,
        filePathDisplay: FilePathDisplay,
        onlyIncludeRootsWithSelectedFiles: Bool,
        includeFileTreeLegend: Bool = true,
        showCodeMapMarkers: Bool,
        codeMapUsage: CodeMapUsage? = nil,
        entryResolutionProfile: PathLocateProfile = .uiAssisted,
        selectedGitDiffFolderPolicy: SelectedGitDiffFolderPolicy,
        selectedGitDiffLookupProfile: PathLocateProfile? = nil,
        factualIngressPolicy: PromptFactualIngressPolicy = .awaitPending,
        includeLocalDefinitionsInFileTree: Bool = false,
        selectedGitDiffArtifactPolicy: SelectedGitDiffArtifactPolicy = .includeBeforeGitInclusion,
        reviewGitContext: FrozenPromptGitReviewContext,
        sourceTabID: UUID? = nil,
        finalReviewAuthorization: ContextBuilderFinalReviewAuthorization? = nil,
        sessionQuery: WorkspaceSessionQueryCapability? = nil,
        selectedGitDiffProvider: @escaping (AutomaticReviewGitDiffRequest) async -> AutomaticReviewGitDiffResult,
        completeGitDiffProvider: @escaping () async -> String?
    ) {
        self.cfg = cfg
        self.selection = selection
        #if DEBUG
            debugAuthorizationStore = store
            let effectiveSessionQuery = sessionQuery
                ?? WorkspaceSessionStoreLifecycleFactory.makeQueryCapability(store: store)
            self.sessionQuery = effectiveSessionQuery
            self.authorizationCatalog = authorizationCatalog ?? effectiveSessionQuery
        #else
            self.sessionQuery = sessionQuery
            self.authorizationCatalog = authorizationCatalog ?? store
        #endif
        self.lookupContext = lookupContext
        self.factualProvider = factualProvider
        self.admissionToken = admissionToken
        self.filePathDisplay = filePathDisplay
        self.onlyIncludeRootsWithSelectedFiles = onlyIncludeRootsWithSelectedFiles
        self.includeFileTreeLegend = includeFileTreeLegend
        self.showCodeMapMarkers = showCodeMapMarkers
        self.codeMapUsage = codeMapUsage ?? cfg.codeMapUsage
        self.entryResolutionProfile = entryResolutionProfile
        self.selectedGitDiffFolderPolicy = selectedGitDiffFolderPolicy
        self.selectedGitDiffLookupProfile = selectedGitDiffLookupProfile ?? entryResolutionProfile
        self.factualIngressPolicy = factualIngressPolicy
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
        case .none: nil
        case let .selectedArtifact(text): text
        case let .automatic(result): result.text
        case let .complete(text): text
        }
    }
}

struct PromptContextPreAssemblyResult {
    let factualSnapshot: PromptFactualContextSnapshot
    let gitDiffResolution: PromptGitDiffResolution
    let selectedGitArtifactDispositions: [SelectedGitArtifactDisposition]
    #if DEBUG
        let debugPhysicalSelection: StoredSelection
        let debugEntries: [ResolvedPromptFileEntry]
        let debugCodemapSnapshotBundle: WorkspaceCodemapSnapshotBundle
        let debugLookupContext: WorkspaceLookupContext
        let debugFilePathDisplay: FilePathDisplay
    #endif

    var rendered: PromptFactualRenderedSections {
        factualSnapshot.rendered
    }

    var fileTreeContent: String? {
        factualSnapshot.rendered.fileTreeContent
    }

    var gitDiff: String? {
        gitDiffResolution.text
    }
}

#if DEBUG
    extension PromptContextPreAssemblyResult {
        var physicalSelection: StoredSelection {
            debugPhysicalSelection
        }

        var entries: [ResolvedPromptFileEntry] {
            debugEntries
        }

        var codemapSnapshotBundle: WorkspaceCodemapSnapshotBundle {
            debugCodemapSnapshotBundle
        }

        func displayPath(for entry: ResolvedPromptFileEntry) -> String? {
            debugLookupContext.bindingProjection?.projectedLogicalDisplayPath(
                forPhysicalPath: entry.file.standardizedFullPath,
                display: debugFilePathDisplay
            )
        }
    }
#endif

enum PromptContextPreAssemblyOutcome {
    case ready(PromptContextPreAssemblyResult)
    case unavailable(PromptFactualCaptureFailure)
    case cancelled
}

#if DEBUG
    extension PromptContextPreAssemblyOutcome {
        private var debugReady: PromptContextPreAssemblyResult? {
            guard case let .ready(result) = self else { return nil }
            return result
        }

        var physicalSelection: StoredSelection {
            debugReady?.debugPhysicalSelection ?? StoredSelection()
        }

        var entries: [ResolvedPromptFileEntry] {
            debugReady?.debugEntries ?? []
        }

        var codemapSnapshotBundle: WorkspaceCodemapSnapshotBundle {
            debugReady?.debugCodemapSnapshotBundle ?? .empty
        }

        var fileTreeContent: String? {
            debugReady?.fileTreeContent
        }

        var gitDiff: String? {
            debugReady?.gitDiff
        }

        var gitDiffResolution: PromptGitDiffResolution {
            debugReady?.gitDiffResolution ?? .none
        }

        var selectedGitArtifactDispositions: [SelectedGitArtifactDisposition] {
            debugReady?.selectedGitArtifactDispositions ?? []
        }

        func displayPath(for entry: ResolvedPromptFileEntry) -> String? {
            debugReady?.debugLookupContext.bindingProjection?.projectedLogicalDisplayPath(
                forPhysicalPath: entry.file.standardizedFullPath,
                display: debugReady?.debugFilePathDisplay ?? .relative
            )
        }
    }
#endif

enum PromptContextPreAssemblyService {
    private struct ArtifactSnapshotEntry: Equatable {
        let path: String
        let content: String?
    }

    static func resolve(
        _ request: PromptContextPreAssemblyRequest
    ) async -> PromptContextPreAssemblyOutcome {
        precondition(
            request.finalReviewAuthorization == nil,
            "Strict Context Builder review packaging must use resolveStrict"
        )
        let physicalSelection = request.lookupContext.physicalizeSelection(request.selection)
        let authorization = await authorizeSelectedGitArtifacts(
            request: request,
            physicalSelection: physicalSelection
        )
        do {
            return try await resolveCore(
                request,
                physicalSelection: physicalSelection,
                authorization: authorization
            )
        } catch {
            return .unavailable(.invalidFrozenInput)
        }
    }

    static func resolveStrict(
        _ request: PromptContextPreAssemblyRequest
    ) async throws -> PromptContextPreAssemblyResult {
        guard let finalAuthorization = request.finalReviewAuthorization else {
            return try await unwrap(resolve(request))
        }
        let physicalSelection = request.lookupContext.physicalizeSelection(request.selection)
        let initialAuthorization = try await validateStrictAuthorization(
            request: request,
            physicalSelection: physicalSelection,
            authorization: finalAuthorization
        )
        let result = try await unwrap(resolveCore(
            request,
            physicalSelection: physicalSelection,
            authorization: initialAuthorization
        ))
        let finalArtifactAuthorization = try await validateStrictAuthorization(
            request: request,
            physicalSelection: physicalSelection,
            authorization: finalAuthorization
        )
        guard artifactSnapshot(finalArtifactAuthorization) == artifactSnapshot(initialAuthorization) else {
            throw ContextBuilderReviewTargetUnavailableReason.unauthorizedSelectedArtifact(
                count: finalAuthorization.selectedArtifactAuthorizations.count
            )
        }
        return result
    }

    private static func unwrap(
        _ outcome: PromptContextPreAssemblyOutcome
    ) throws -> PromptContextPreAssemblyResult {
        switch outcome {
        case let .ready(result): result
        case let .unavailable(failure): throw PromptFactualPackagingError.unavailable(failure)
        case .cancelled: throw PromptFactualPackagingError.cancelled
        }
    }

    private static func resolveCore(
        _ request: PromptContextPreAssemblyRequest,
        physicalSelection: StoredSelection,
        authorization: SelectedGitArtifactAuthorizationResult
    ) async throws -> PromptContextPreAssemblyOutcome {
        let frozenArtifacts: PromptAuthorizedArtifactBatch
        do {
            frozenArtifacts = try FrozenAuthorizedGitArtifactAdapter.freeze(authorization)
        } catch {
            return .unavailable(.invalidFrozenInput)
        }

        let projection = request.lookupContext.bindingProjection?.frozenPromptProjection()
        let ordinaryRootScope = request.lookupContext.rootScope.excludingWorkspaceGitData
        let factualRequest = PromptFactualCaptureRequest(
            selection: request.selection,
            rootScope: ordinaryRootScope,
            projection: projection,
            filePathDisplay: request.filePathDisplay,
            codeMapUsage: request.codeMapUsage,
            entryResolutionProfile: request.entryResolutionProfile,
            rendersFileTree: request.cfg.rendersFileTree,
            fileTreeMode: WorkspaceFileTreeSnapshotMode(fileTreeOption: request.cfg.effectiveFileTreeMode),
            onlyIncludeRootsWithSelectedFiles: request.onlyIncludeRootsWithSelectedFiles,
            includeFileTreeLegend: request.includeFileTreeLegend,
            showCodeMapMarkers: request.showCodeMapMarkers,
            authorizedArtifactBatch: frozenArtifacts,
            selectedDiffFolderPolicy: request.selectedGitDiffFolderPolicy == .filesOnly ? .filesOnly : .expandFolders,
            selectedDiffLookupProfile: request.selectedGitDiffLookupProfile,
            ingressPolicy: request.factualIngressPolicy
        )

        let factualOutcome: PromptFactualCaptureOutcome
        if let provider = request.factualProvider {
            factualOutcome = await provider.capture(factualRequest, admission: request.admissionToken)
        } else {
            #if DEBUG
                // XCTest-only compatibility seam. Every production caller supplies the
                // construction-selected provider; release builds fail closed here.
                let first = await PromptFactualContextCaptureService.capture(
                    request: factualRequest,
                    store: request.debugAuthorizationStore
                )
                if case .unavailable(.staleGeneration) = first {
                    factualOutcome = await PromptFactualContextCaptureService.capture(
                        request: factualRequest,
                        store: request.debugAuthorizationStore
                    )
                } else {
                    factualOutcome = first
                }
            #else
                factualOutcome = .unavailable(.notReady)
            #endif
        }

        switch factualOutcome {
        case .cancelled:
            return .cancelled
        case let .unavailable(failure):
            return .unavailable(failure)
        case let .ready(snapshot):
            let resolution = try await resolveGitDiff(request: request, snapshot: snapshot)
            #if DEBUG
                let debugCompatibility = await debugCompatibilityCapture(
                    request: request,
                    physicalSelection: physicalSelection,
                    authorization: authorization
                )
            #endif
            #if DEBUG
                let result = PromptContextPreAssemblyResult(
                    factualSnapshot: snapshot,
                    gitDiffResolution: resolution,
                    selectedGitArtifactDispositions: authorization.dispositions,
                    debugPhysicalSelection: physicalSelection,
                    debugEntries: debugCompatibility.entries,
                    debugCodemapSnapshotBundle: debugCompatibility.codemaps,
                    debugLookupContext: request.lookupContext,
                    debugFilePathDisplay: request.filePathDisplay
                )
            #else
                let result = PromptContextPreAssemblyResult(
                    factualSnapshot: snapshot,
                    gitDiffResolution: resolution,
                    selectedGitArtifactDispositions: authorization.dispositions
                )
            #endif
            return .ready(result)
        }
    }

    private static func validateStrictAuthorization(
        request: PromptContextPreAssemblyRequest,
        physicalSelection: StoredSelection,
        authorization: ContextBuilderFinalReviewAuthorization
    ) async throws -> SelectedGitArtifactAuthorizationResult {
        guard let sessionQuery = request.sessionQuery else {
            throw ContextBuilderReviewTargetUnavailableReason.staleWorkspaceRoot
        }
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
            query: sessionQuery
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
        let expectedIdentities = Set(authorization.selectedArtifactAuthorizations.map(\.absolutePath))
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
                    store: request.authorizationCatalog,
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
            query: sessionQuery
        ) {
            throw reason
        }
        return artifactAuthorization
    }

    private static func artifactSnapshot(
        _ authorization: SelectedGitArtifactAuthorizationResult
    ) -> [ArtifactSnapshotEntry] {
        authorization.entries
            .map { ArtifactSnapshotEntry(path: $0.file.standardizedFullPath, content: $0.loadedContent) }
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
                store: request.authorizationCatalog,
                delegationConsumer: request.reviewGitContext.artifactDelegationConsumer
            )
        )
    }

    #if DEBUG
        private static func debugCompatibilityCapture(
            request: PromptContextPreAssemblyRequest,
            physicalSelection: StoredSelection,
            authorization: SelectedGitArtifactAuthorizationResult
        ) async -> (entries: [ResolvedPromptFileEntry], codemaps: WorkspaceCodemapSnapshotBundle) {
            // Only legacy XCTest call sites omit the selected provider. Production debug builds
            // never perform this second query.
            guard request.factualProvider == nil else { return ([], .empty) }
            let normalizedConsumed = Set(
                authorization.consumedSelectionPaths.compactMap(StoredSelectionPathNormalization.standardizedPath)
            )
            func retained(_ path: String) -> Bool {
                !authorization.consumedSelectionPaths.contains(path)
                    && StoredSelectionPathNormalization.standardizedPath(path).map {
                        !normalizedConsumed.contains($0)
                    } != false
            }
            let ordinary = StoredSelection(
                selectedPaths: physicalSelection.selectedPaths.filter(retained),
                autoCodemapPaths: physicalSelection.autoCodemapPaths.filter(retained),
                slices: physicalSelection.slices.filter { retained($0.key) },
                codemapAutoEnabled: physicalSelection.codemapAutoEnabled
            )
            let scope = request.lookupContext.rootScope.excludingWorkspaceGitData
            let codemaps = await request.debugAuthorizationStore.codemapSnapshotBundle(rootScope: scope)
            let resolved = await PromptContextAccountingService().resolveEntries(
                selection: ordinary,
                store: request.debugAuthorizationStore,
                rootScope: scope,
                profile: request.entryResolutionProfile,
                codeMapUsage: request.codeMapUsage,
                codemapSnapshotBundle: codemaps
            )
            let all = authorization.entries + resolved.entries
            if request.selectedGitDiffArtifactPolicy == .respectGitInclusion,
               request.cfg.gitInclusion == .none
            {
                return (all.filter { $0.role != .authorizedGitDiffArtifact }, codemaps)
            }
            return (all, codemaps)
        }
    #endif

    private static func resolveGitDiff(
        request: PromptContextPreAssemblyRequest,
        snapshot: PromptFactualContextSnapshot
    ) async throws -> PromptGitDiffResolution {
        if request.selectedGitDiffArtifactPolicy == .respectGitInclusion,
           request.cfg.gitInclusion == .none
        {
            return .none
        }
        if let selectedPatch = snapshot.rendered.selectedPatchText,
           !selectedPatch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .selectedArtifact(selectedPatch)
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
            let frozen = snapshot.selectedDiffPathResolution
            let result = await request.selectedGitDiffProvider(
                AutomaticReviewGitDiffRequest(
                    pathResolution: WorkspaceSelectedGitPathResolution(
                        paths: frozen.paths,
                        unresolvedCandidates: frozen.unresolvedLogicalCandidates
                    ),
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
