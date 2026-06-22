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
    let includeLocalDefinitionsInFileTree: Bool
    let selectedGitDiffArtifactPolicy: SelectedGitDiffArtifactPolicy
    let reviewGitContext: FrozenPromptGitReviewContext
    let selectedGitDiffProvider: (AutomaticReviewGitDiffRequest) async -> AutomaticReviewGitDiffResult
    let completeGitDiffProvider: () async -> String?

    init(
        cfg: PromptContextResolved,
        selection: StoredSelection,
        store: WorkspaceFileContextStore,
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
        includeLocalDefinitionsInFileTree: Bool = false,
        selectedGitDiffArtifactPolicy: SelectedGitDiffArtifactPolicy = .includeBeforeGitInclusion,
        reviewGitContext: FrozenPromptGitReviewContext,
        selectedGitDiffProvider: @escaping (AutomaticReviewGitDiffRequest) async -> AutomaticReviewGitDiffResult,
        completeGitDiffProvider: @escaping () async -> String?
    ) {
        self.cfg = cfg
        self.selection = selection
        authorizationCatalog = store
        #if DEBUG
            debugAuthorizationStore = store
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
        self.includeLocalDefinitionsInFileTree = includeLocalDefinitionsInFileTree
        self.selectedGitDiffArtifactPolicy = selectedGitDiffArtifactPolicy
        self.reviewGitContext = reviewGitContext
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
    static func resolve(
        _ request: PromptContextPreAssemblyRequest
    ) async -> PromptContextPreAssemblyOutcome {
        let physicalSelection = request.lookupContext.physicalizeSelection(request.selection)
        let authorization = await authorizeSelectedGitArtifacts(
            request: request,
            physicalSelection: physicalSelection
        )
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
            selectedDiffLookupProfile: request.selectedGitDiffLookupProfile
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
            let resolution = await resolveGitDiff(request: request, snapshot: snapshot)
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
    ) async -> PromptGitDiffResolution {
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
