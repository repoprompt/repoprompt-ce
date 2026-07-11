import Foundation

enum ContextBuilderReviewTargetUnavailableReason: Equatable, LocalizedError {
    case missingFrozenTarget
    case emptySelection
    case unresolvedSelection(count: Int)
    case nonGitSelection(count: Int)
    case ambiguousOwnership
    case unauthorizedSelectedArtifact(count: Int)
    case deferredArtifactSelection(count: Int)
    case artifactOwnershipConflict
    case staleWorkspaceRoot
    case checkoutIdentityChanged
    case selectionOwnershipChanged
    case workspaceOrTabMismatch

    var errorDescription: String? {
        switch self {
        case .missingFrozenTarget:
            "The Agent Context Builder run is missing its frozen review repository target."
        case .emptySelection:
            "Context Builder review requires at least one selected file or authorized Git artifact."
        case let .unresolvedSelection(count):
            "Context Builder could not resolve \(count) selected item(s) within the frozen workspace scope."
        case let .nonGitSelection(count):
            "Context Builder found \(count) selected item(s) without an exact Git checkout owner."
        case .ambiguousOwnership:
            "Context Builder selected repository ownership is ambiguous."
        case let .unauthorizedSelectedArtifact(count):
            "Context Builder found \(count) selected Git artifact(s) without frozen checkout authority."
        case let .deferredArtifactSelection(count):
            "A deferred Context Builder review cannot authorize \(count) Git artifact candidate(s) selected after discovery."
        case .artifactOwnershipConflict:
            "Selected Git artifacts conflict with the ordinary selected repository ownership."
        case .staleWorkspaceRoot:
            "A frozen Context Builder workspace root was unloaded or replaced."
        case .checkoutIdentityChanged:
            "A frozen Context Builder Git checkout identity changed."
        case .selectionOwnershipChanged:
            "Context Builder selection moved outside its frozen repository target."
        case .workspaceOrTabMismatch:
            "Context Builder review target provenance does not match the completed workspace and tab."
        }
    }
}

struct ContextBuilderReviewCheckoutTarget: Equatable, Hashable {
    let logicalWorkspaceRoot: WorkspaceRootRef
    let physicalWorkspaceRoot: WorkspaceRootRef
    let physicalWorkspaceRootKind: WorkspaceRootKind
    let checkoutRootPath: String
    let repoKey: String
    let repositoryID: String
    let worktreeID: String
    let kind: FrozenVisibleGitCheckoutKind
    let sessionRootAuthorization: WorkspaceSessionRootAuthorization?

    var identityKey: String {
        [repoKey, repositoryID, worktreeID, GitRepoRootAuthorization.canonicalPath(checkoutRootPath)]
            .joined(separator: "\u{1f}")
    }

    func matches(_ repo: GitRepoDescriptor) -> Bool {
        repo.repoKey == repoKey
            && GitRepoRootAuthorization.canonicalPath(repo.rootPath)
            == GitRepoRootAuthorization.canonicalPath(checkoutRootPath)
    }

    func matches(_ provenance: SelectedGitArtifactCheckoutProvenance) -> Bool {
        provenance.repoKey == repoKey
            && provenance.repositoryID == repositoryID
            && provenance.worktreeID == worktreeID
            && provenance.kind == kind
            && GitRepoRootAuthorization.canonicalPath(provenance.checkoutRootPath)
            == GitRepoRootAuthorization.canonicalPath(checkoutRootPath)
    }

    func matches(_ manifest: GitDiffSnapshotManifest) -> Bool {
        guard let manifestRepoKey = manifest.repoKey,
              let manifestRoot = manifest.repoRoot
        else { return false }
        return manifestRepoKey == repoKey
            && GitRepoRootAuthorization.canonicalPath(manifestRoot)
            == GitRepoRootAuthorization.canonicalPath(checkoutRootPath)
            && (kind == .linkedWorktree) == (manifest.isWorktree == true)
    }
}

struct ContextBuilderReviewTarget: Equatable {
    let workspaceID: UUID
    let tabID: UUID
    let sourceSelectionRevision: UInt64
    let initialOrdinarySelectionIdentities: [String]
    let initialSelectedArtifactIdentities: [String]
    let checkouts: [ContextBuilderReviewCheckoutTarget]
    let primaryCheckout: ContextBuilderReviewCheckoutTarget
    let artifactCapability: SelectedGitArtifactCapability?
    let displayContext: ReviewGitDisplayContext

    var identityKeys: Set<String> {
        Set(checkouts.map(\.identityKey))
    }

    func repositories(from allRepos: [GitRepoDescriptor]) -> [GitRepoDescriptor]? {
        let resolved = checkouts.compactMap { target in
            allRepos.first(where: target.matches)
        }
        guard resolved.count == checkouts.count else { return nil }
        return resolved
    }

    func checkout(matching repo: GitRepoDescriptor) -> ContextBuilderReviewCheckoutTarget? {
        checkouts.first(where: { $0.matches(repo) })
    }

    func contains(_ repo: GitRepoDescriptor) -> Bool {
        checkout(matching: repo) != nil
    }
}

struct ContextBuilderDeferredReviewAuthority: Equatable {
    let workspaceID: UUID
    let tabID: UUID
    let initialSelectionRevision: UInt64
    let lookupContext: WorkspaceLookupContext
    let reviewGitContext: FrozenPromptGitReviewContext
}

enum ContextBuilderReviewElectionOrigin: Equatable {
    case initiallyAvailable
    case deferred
}

struct ContextBuilderFinalReviewCheckoutAuthorization: Equatable {
    let checkout: ContextBuilderReviewCheckoutTarget
    let ordinaryPhysicalPaths: [String]
}

struct ContextBuilderFinalSelectedArtifactAuthorization: Equatable {
    let absolutePath: String
    let kind: SelectedGitArtifactKind
    let readability: SelectedGitArtifactReadability
    let provenance: SelectedGitArtifactCheckoutProvenance
}

struct ContextBuilderFinalReviewAuthorization: Equatable {
    let electionOrigin: ContextBuilderReviewElectionOrigin
    let workspaceID: UUID
    let tabID: UUID
    let committedSelectionRevision: UInt64
    let committedSelection: StoredSelection
    let lookupContext: WorkspaceLookupContext
    let reviewGitContext: FrozenPromptGitReviewContext
    let target: ContextBuilderReviewTarget
    let checkoutAuthorizations: [ContextBuilderFinalReviewCheckoutAuthorization]
    let selectedArtifactAuthorizations: [ContextBuilderFinalSelectedArtifactAuthorization]
}

enum ContextBuilderReviewTargetResolution: Equatable {
    case available(ContextBuilderReviewTarget)
    case deferred(ContextBuilderDeferredReviewAuthority)
    case unavailable(ContextBuilderReviewTargetUnavailableReason)

    var availableTarget: ContextBuilderReviewTarget? {
        guard case let .available(target) = self else { return nil }
        return target
    }
}

struct ContextBuilderReviewTargetInput {
    let workspaceID: UUID
    let tabID: UUID
    let selectionRevision: UInt64
    let selection: StoredSelection
    let lookupContext: WorkspaceLookupContext
    let reviewGitContext: FrozenPromptGitReviewContext
}

struct ContextBuilderReviewTargetResolver {
    private struct OwnershipPipelineResult {
        let ordinarySelectionIdentities: [String]
        let ordinaryPhysicalPathsByCheckoutIdentity: [String: [String]]
        let selectedArtifactAuthorizations: [ContextBuilderFinalSelectedArtifactAuthorization]
        let checkouts: [ContextBuilderReviewCheckoutTarget]
        let primaryCheckout: ContextBuilderReviewCheckoutTarget
        let artifactCapability: SelectedGitArtifactCapability?
    }

    private enum OwnershipPipelineResolution {
        case available(OwnershipPipelineResult)
        case unavailable(ContextBuilderReviewTargetUnavailableReason)
    }

    private let ownershipResolver: ReviewGitSelectedPathOwnershipResolver
    private let vcsService: VCSService
    private let diagnosticSink: ContextBuilderReviewDiagnosticSink

    init(
        vcsService: VCSService = .shared,
        diagnosticSink: ContextBuilderReviewDiagnosticSink? = nil
    ) {
        self.vcsService = vcsService
        self.diagnosticSink = diagnosticSink ?? ContextBuilderReviewDiagnosticTracer.emit
        ownershipResolver = ReviewGitSelectedPathOwnershipResolver(
            dependencies: .live(vcsService: vcsService)
        )
    }

    func resolve(
        input: ContextBuilderReviewTargetInput,
        store: WorkspaceFileContextStore
    ) async throws -> ContextBuilderReviewTargetResolution {
        let physicalSelection = input.lookupContext.physicalizeSelection(input.selection)
        guard !Self.reviewCandidates(
            from: physicalSelection,
            capability: input.reviewGitContext.artifactCapability
        ).isEmpty else {
            return .deferred(ContextBuilderDeferredReviewAuthority(
                workspaceID: input.workspaceID,
                tabID: input.tabID,
                initialSelectionRevision: input.selectionRevision,
                lookupContext: input.lookupContext,
                reviewGitContext: input.reviewGitContext
            ))
        }

        return switch try await resolveOwnership(
            input: input,
            store: store,
            phase: .initialElection
        ) {
        case let .unavailable(reason):
            .unavailable(reason)
        case let .available(ownership):
            .available(makeReviewTarget(input: input, ownership: ownership))
        }
    }

    private func resolveOwnership(
        input: ContextBuilderReviewTargetInput,
        store: WorkspaceFileContextStore,
        phase: ContextBuilderReviewDiagnosticEvent.Phase
    ) async throws -> OwnershipPipelineResolution {
        let physicalSelection = input.lookupContext.physicalizeSelection(input.selection)
        let artifactCapability = input.reviewGitContext.artifactCapability
        let candidates = Self.reviewCandidates(
            from: physicalSelection,
            capability: artifactCapability
        )
        guard !candidates.isEmpty else { return .unavailable(.emptySelection) }

        let artifactPaths = Self.artifactCandidates(
            from: physicalSelection,
            capability: artifactCapability
        )

        var selectedArtifactAuthorizations: [ContextBuilderFinalSelectedArtifactAuthorization] = []
        if !artifactPaths.isEmpty {
            guard let artifactCapability else {
                return .unavailable(.unauthorizedSelectedArtifact(count: artifactPaths.count))
            }
            let authorization = await SelectedGitDiffArtifactAuthorizationService(vcsService: vcsService).authorizeExactPaths(
                ExactSelectedGitArtifactAuthorizationRequest(
                    exactAbsolutePaths: artifactPaths,
                    capability: artifactCapability,
                    store: store
                )
            )
            let rejectedCount = authorization.dispositions.reduce(into: 0) { count, disposition in
                if case .rejected = disposition {
                    count += 1
                }
            }
            let authorizedArtifacts = authorization.dispositions.compactMap { disposition
                -> ContextBuilderFinalSelectedArtifactAuthorization? in
                guard case let .authorized(path, kind, readability) = disposition,
                      let provenance = authorization.checkoutProvenanceByAbsolutePath[path]
                else { return nil }
                return ContextBuilderFinalSelectedArtifactAuthorization(
                    absolutePath: path,
                    kind: kind,
                    readability: readability,
                    provenance: provenance
                )
            }
            guard rejectedCount == 0,
                  authorization.checkoutProvenanceByAbsolutePath.count == Set(artifactPaths).count,
                  authorizedArtifacts.count == Set(artifactPaths).count
            else {
                return .unavailable(.unauthorizedSelectedArtifact(count: max(1, rejectedCount)))
            }
            selectedArtifactAuthorizations = authorizedArtifacts.sorted {
                $0.absolutePath < $1.absolutePath
            }
        }
        let artifactProvenance = selectedArtifactAuthorizations.map(\.provenance)

        let artifactPathSet = Set(artifactPaths)
        let ordinaryCandidates = candidates.filter { !artifactPathSet.contains($0) }
        var resolvedOrdinaryPaths: [String] = []
        var seenResolvedPaths = Set<String>()
        var unresolvedCandidates: [String] = []
        var canonicalCandidates: [String] = []
        var exactCandidateCount = 0
        var exactResolvedCandidateCount = 0
        var exactUnresolvedCandidateCount = 0
        var exactBlockedCount = 0
        var exactAuthorizations: [WorkspaceSessionRootAuthorization] = []

        func appendResolved(_ path: String) {
            let standardized = StandardizedPath.absolute(path)
            guard seenResolvedPaths.insert(standardized).inserted else { return }
            resolvedOrdinaryPaths.append(standardized)
        }

        for candidate in ordinaryCandidates {
            let expanded = (candidate as NSString).expandingTildeInPath
            let standardized = expanded.hasPrefix("/")
                ? StandardizedPath.absolute(expanded)
                : StandardizedPath.relative(expanded)
            guard standardized.hasPrefix("/"),
                  let boundRoot = input.lookupContext.bindingProjection?
                  .boundRoot(containingPhysicalAbsolutePath: standardized)
            else {
                canonicalCandidates.append(candidate)
                continue
            }

            exactCandidateCount += 1
            guard let authorization = boundRoot.sessionRootAuthorization else {
                emitResolutionDiagnostic(
                    input: input,
                    phase: phase,
                    outcome: .staleAuthority,
                    candidateCount: exactCandidateCount,
                    resolvedCount: exactResolvedCandidateCount,
                    unresolvedCount: exactUnresolvedCandidateCount,
                    authorizations: exactAuthorizations,
                    mismatch: .token
                )
                return .unavailable(.staleWorkspaceRoot)
            }
            exactAuthorizations.append(authorization)
            switch try await store.resolveContextBuilderSelectionCandidate(
                path: standardized,
                authorization: authorization,
                folderPolicy: .expandFolders
            ) {
            case let .resolved(files, _):
                exactResolvedCandidateCount += 1
                files.forEach { appendResolved($0.standardizedFullPath) }
            case .noCandidate:
                exactUnresolvedCandidateCount += 1
                unresolvedCandidates.append(candidate)
            case .blockedOrAmbiguous:
                exactBlockedCount += 1
                exactUnresolvedCandidateCount += 1
                unresolvedCandidates.append(candidate)
            case let .staleAuthority(mismatch):
                emitResolutionDiagnostic(
                    input: input,
                    phase: phase,
                    outcome: .staleAuthority,
                    candidateCount: exactCandidateCount,
                    resolvedCount: exactResolvedCandidateCount,
                    unresolvedCount: exactUnresolvedCandidateCount,
                    authorizations: exactAuthorizations,
                    mismatch: mismatch
                )
                return .unavailable(.staleWorkspaceRoot)
            }
        }

        if !canonicalCandidates.isEmpty {
            let canonicalResolution = await WorkspaceGitDiffSelectionResolver.resolveSelectedGitDiffPaths(
                for: StoredSelection(
                    selectedPaths: canonicalCandidates,
                    codemapAutoEnabled: false
                ),
                store: store,
                rootScope: input.lookupContext.rootScope.excludingWorkspaceGitData,
                folderPolicy: .expandFolders,
                profile: .mcpSelection,
                allowFilesystemFallback: false,
                excluding: []
            )
            canonicalResolution.paths.forEach(appendResolved)
            unresolvedCandidates.append(contentsOf: canonicalResolution.unresolvedCandidates)
        }

        let ordinaryResolution = WorkspaceSelectedGitPathResolution(
            paths: resolvedOrdinaryPaths,
            unresolvedCandidates: unresolvedCandidates
        )
        if let stale = await firstStaleAuthorization(
            in: exactAuthorizations,
            store: store
        ) {
            emitResolutionDiagnostic(
                input: input,
                phase: phase,
                outcome: .staleAuthority,
                candidateCount: exactCandidateCount,
                resolvedCount: exactResolvedCandidateCount,
                unresolvedCount: exactUnresolvedCandidateCount,
                authorizations: exactAuthorizations,
                mismatch: stale
            )
            return .unavailable(.staleWorkspaceRoot)
        }
        guard ordinaryResolution.unresolvedCandidates.isEmpty else {
            if exactCandidateCount > 0 {
                emitResolutionDiagnostic(
                    input: input,
                    phase: phase,
                    outcome: exactBlockedCount > 0 ? .blocked : .noCandidate,
                    candidateCount: exactCandidateCount,
                    resolvedCount: exactResolvedCandidateCount,
                    unresolvedCount: exactUnresolvedCandidateCount,
                    authorizations: exactAuthorizations,
                    mismatch: nil
                )
            }
            return .unavailable(.unresolvedSelection(count: ordinaryResolution.unresolvedCandidates.count))
        }

        let ownership: ReviewGitSelectedPathOwnershipResolution
        do {
            ownership = try await ownershipResolver.resolve(
                ordinaryResolution,
                displayContext: input.reviewGitContext.displayContext
            )
        } catch {
            if let stale = await firstStaleAuthorization(
                in: exactAuthorizations,
                store: store
            ) {
                emitResolutionDiagnostic(
                    input: input,
                    phase: phase,
                    outcome: .staleAuthority,
                    candidateCount: exactCandidateCount,
                    resolvedCount: exactResolvedCandidateCount,
                    unresolvedCount: exactUnresolvedCandidateCount,
                    authorizations: exactAuthorizations,
                    mismatch: stale
                )
                return .unavailable(.staleWorkspaceRoot)
            }
            return .unavailable(.checkoutIdentityChanged)
        }
        if let stale = await firstStaleAuthorization(
            in: exactAuthorizations,
            store: store
        ) {
            emitResolutionDiagnostic(
                input: input,
                phase: phase,
                outcome: .staleAuthority,
                candidateCount: exactCandidateCount,
                resolvedCount: exactResolvedCandidateCount,
                unresolvedCount: exactUnresolvedCandidateCount,
                authorizations: exactAuthorizations,
                mismatch: stale
            )
            return .unavailable(.staleWorkspaceRoot)
        }
        guard ownership.pathIssues.isEmpty else {
            return .unavailable(.nonGitSelection(count: ownership.pathIssues.count))
        }
        let scopedRoots = await store.rootRefs(scope: input.lookupContext.rootScope.excludingWorkspaceGitData)
        if let stale = await firstStaleAuthorization(
            in: exactAuthorizations,
            store: store
        ) {
            emitResolutionDiagnostic(
                input: input,
                phase: phase,
                outcome: .staleAuthority,
                candidateCount: exactCandidateCount,
                resolvedCount: exactResolvedCandidateCount,
                unresolvedCount: exactUnresolvedCandidateCount,
                authorizations: exactAuthorizations,
                mismatch: stale
            )
            return .unavailable(.staleWorkspaceRoot)
        }
        let ordinaryTargets: [ContextBuilderReviewCheckoutTarget]
        do {
            ordinaryTargets = try ownership.checkouts.map {
                try makeTarget(
                    checkoutRootPath: $0.checkoutRootPath,
                    repoKey: $0.repoKey,
                    repositoryID: $0.repositoryID,
                    worktreeID: $0.worktreeID,
                    kind: $0.kind,
                    selectedPaths: $0.selectedPaths,
                    scopedRoots: scopedRoots,
                    lookupContext: input.lookupContext
                )
            }
        } catch let reason as ContextBuilderReviewTargetUnavailableReason {
            return .unavailable(reason)
        } catch {
            return .unavailable(.ambiguousOwnership)
        }

        var ordinaryPhysicalPathsByCheckoutIdentity: [String: [String]] = [:]
        for (ownershipCheckout, target) in zip(ownership.checkouts, ordinaryTargets) {
            ordinaryPhysicalPathsByCheckoutIdentity[target.identityKey, default: []]
                .append(contentsOf: ownershipCheckout.selectedPaths.map(StandardizedPath.absolute))
        }
        ordinaryPhysicalPathsByCheckoutIdentity = ordinaryPhysicalPathsByCheckoutIdentity.mapValues {
            Array(Set($0)).sorted()
        }

        let artifactTargets: [ContextBuilderReviewCheckoutTarget]
        do {
            artifactTargets = try artifactProvenance.map { provenance in
                try makeTarget(
                    checkoutRootPath: provenance.checkoutRootPath,
                    repoKey: provenance.repoKey,
                    repositoryID: provenance.repositoryID,
                    worktreeID: provenance.worktreeID,
                    kind: provenance.kind,
                    selectedPaths: [provenance.checkoutRootPath],
                    scopedRoots: scopedRoots,
                    lookupContext: input.lookupContext
                )
            }
        } catch let reason as ContextBuilderReviewTargetUnavailableReason {
            return .unavailable(reason)
        } catch {
            return .unavailable(.ambiguousOwnership)
        }

        let ordinaryKeys = Set(ordinaryTargets.map(\.identityKey))
        if !ordinaryKeys.isEmpty,
           artifactTargets.contains(where: { !ordinaryKeys.contains($0.identityKey) })
        {
            return .unavailable(.artifactOwnershipConflict)
        }

        let combined = ordinaryTargets.isEmpty ? artifactTargets : ordinaryTargets
        let targets = Dictionary(grouping: combined, by: \.identityKey)
            .compactMap { _, values in Set(values).count == 1 ? values.first : nil }
            .sorted { lhs, rhs in
                if lhs.logicalWorkspaceRoot.name != rhs.logicalWorkspaceRoot.name {
                    return lhs.logicalWorkspaceRoot.name < rhs.logicalWorkspaceRoot.name
                }
                if lhs.repoKey != rhs.repoKey {
                    return lhs.repoKey < rhs.repoKey
                }
                if lhs.repositoryID != rhs.repositoryID {
                    return lhs.repositoryID < rhs.repositoryID
                }
                return lhs.worktreeID < rhs.worktreeID
            }
        guard !targets.isEmpty else { return .unavailable(.emptySelection) }

        let primary: ContextBuilderReviewCheckoutTarget = if let firstOrdinaryPath = ordinaryResolution.paths.first,
                                                             let owner = targets.first(where: {
                                                                 StandardizedPath.isDescendant(firstOrdinaryPath, of: $0.checkoutRootPath)
                                                             })
        {
            owner
        } else {
            targets[0]
        }

        if exactCandidateCount > 0 {
            emitResolutionDiagnostic(
                input: input,
                phase: phase,
                outcome: .resolved,
                candidateCount: exactCandidateCount,
                resolvedCount: exactResolvedCandidateCount,
                unresolvedCount: exactUnresolvedCandidateCount,
                authorizations: exactAuthorizations,
                mismatch: nil
            )
        }
        return .available(OwnershipPipelineResult(
            ordinarySelectionIdentities: ordinaryResolution.paths.sorted(),
            ordinaryPhysicalPathsByCheckoutIdentity: ordinaryPhysicalPathsByCheckoutIdentity,
            selectedArtifactAuthorizations: selectedArtifactAuthorizations,
            checkouts: targets,
            primaryCheckout: primary,
            artifactCapability: artifactCapability
        ))
    }

    func revalidate(
        _ target: ContextBuilderReviewTarget,
        store: WorkspaceFileContextStore
    ) async -> ContextBuilderReviewTargetUnavailableReason? {
        var sessionAuthorizations: [WorkspaceSessionRootAuthorization] = []
        for checkout in target.checkouts {
            let sessionAuthorization: WorkspaceSessionRootAuthorization?
            if checkout.physicalWorkspaceRootKind == .sessionWorktree {
                guard let authorization = checkout.sessionRootAuthorization else {
                    emitRevalidationDiagnostic(
                        target: target,
                        outcome: .staleAuthority,
                        authorization: nil,
                        mismatch: .token
                    )
                    return .staleWorkspaceRoot
                }
                if let mismatch = await store.validateSessionRootAuthorization(authorization) {
                    emitRevalidationDiagnostic(
                        target: target,
                        outcome: .staleAuthority,
                        authorization: authorization,
                        mismatch: mismatch
                    )
                    return .staleWorkspaceRoot
                }
                sessionAuthorizations.append(authorization)
                sessionAuthorization = authorization
            } else {
                guard await store.exactRootRef(
                    path: checkout.physicalWorkspaceRoot.standardizedFullPath,
                    kind: checkout.physicalWorkspaceRootKind
                ) == checkout.physicalWorkspaceRoot else {
                    return .staleWorkspaceRoot
                }
                sessionAuthorization = nil
            }

            guard let resolved = await vcsService.resolveRepo(
                from: URL(fileURLWithPath: checkout.checkoutRootPath, isDirectory: true)
            ),
                resolved.backendKind == .git,
                GitRepoRootAuthorization.canonicalPath(resolved.rootURL.path)
                == GitRepoRootAuthorization.canonicalPath(checkout.checkoutRootPath),
                let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: resolved.rootURL)
            else { return .checkoutIdentityChanged }

            if let authorization = sessionAuthorization,
               let mismatch = await store.validateSessionRootAuthorization(authorization)
            {
                emitRevalidationDiagnostic(
                    target: target,
                    outcome: .staleAuthority,
                    authorization: authorization,
                    mismatch: mismatch
                )
                return .staleWorkspaceRoot
            }

            let identity = GitWorktreeIdentity.repositoryIdentity(
                commonGitDir: layout.commonDir,
                mainWorktreeRoot: layout.knownMainWorktreeRoot
            )
            let worktreeID = GitWorktreeIdentity.worktreeID(
                repositoryID: identity.repositoryID,
                gitDir: layout.gitDir,
                isMain: !layout.isLinkedWorktree,
                path: layout.workTreeRoot
            )
            guard GitRepoDescriptor(rootURL: layout.workTreeRoot).repoKey == checkout.repoKey,
                  identity.repositoryID == checkout.repositoryID,
                  worktreeID == checkout.worktreeID,
                  (layout.isLinkedWorktree ? FrozenVisibleGitCheckoutKind.linkedWorktree : .canonical) == checkout.kind
            else { return .checkoutIdentityChanged }
        }

        if let stale = await firstStaleAuthorization(
            in: sessionAuthorizations,
            store: store
        ) {
            let authorization = Set(sessionAuthorizations).count == 1
                ? sessionAuthorizations.first
                : nil
            emitRevalidationDiagnostic(
                target: target,
                outcome: .staleAuthority,
                authorization: authorization,
                mismatch: stale
            )
            return .staleWorkspaceRoot
        }

        if let authorization = Set(sessionAuthorizations).count == 1
            ? sessionAuthorizations.first
            : nil
        {
            emitRevalidationDiagnostic(
                target: target,
                outcome: .resolved,
                authorization: authorization,
                mismatch: nil
            )
        }
        return nil
    }

    func finalizeSelection(
        input: ContextBuilderReviewTargetInput,
        initialResolution: ContextBuilderReviewTargetResolution,
        store: WorkspaceFileContextStore
    ) async throws -> ContextBuilderFinalReviewAuthorization {
        let electionOrigin: ContextBuilderReviewElectionOrigin
        let frozenTarget: ContextBuilderReviewTarget?
        let phase: ContextBuilderReviewDiagnosticEvent.Phase

        switch initialResolution {
        case let .available(target):
            guard target.workspaceID == input.workspaceID,
                  target.tabID == input.tabID
            else {
                throw ContextBuilderReviewTargetUnavailableReason.workspaceOrTabMismatch
            }
            electionOrigin = .initiallyAvailable
            frozenTarget = target
            phase = .revalidation

        case let .deferred(authority):
            guard authority.workspaceID == input.workspaceID,
                  authority.tabID == input.tabID,
                  input.selectionRevision >= authority.initialSelectionRevision,
                  authority.lookupContext == input.lookupContext,
                  authority.reviewGitContext == input.reviewGitContext
            else {
                throw ContextBuilderReviewTargetUnavailableReason.workspaceOrTabMismatch
            }
            let physicalSelection = input.lookupContext.physicalizeSelection(input.selection)
            let artifactCandidates = Self.artifactCandidates(
                from: physicalSelection,
                capability: input.reviewGitContext.artifactCapability
            )
            guard artifactCandidates.isEmpty else {
                throw ContextBuilderReviewTargetUnavailableReason.deferredArtifactSelection(
                    count: artifactCandidates.count
                )
            }
            electionOrigin = .deferred
            frozenTarget = nil
            phase = .finalElection

        case let .unavailable(reason):
            throw reason
        }

        let current: OwnershipPipelineResult
        switch try await resolveOwnership(
            input: input,
            store: store,
            phase: phase
        ) {
        case let .available(ownership):
            current = ownership
        case let .unavailable(reason):
            throw reason
        }

        let finalTarget = makeReviewTarget(input: input, ownership: current)
        if let frozenTarget {
            guard !current.checkouts.isEmpty,
                  Set(current.checkouts.map(\.identityKey)).isSubset(of: frozenTarget.identityKeys)
            else {
                throw ContextBuilderReviewTargetUnavailableReason.selectionOwnershipChanged
            }
            if let reason = await revalidate(frozenTarget, store: store) {
                throw reason
            }
        }
        if let reason = await revalidate(finalTarget, store: store) {
            throw reason
        }

        return ContextBuilderFinalReviewAuthorization(
            electionOrigin: electionOrigin,
            workspaceID: input.workspaceID,
            tabID: input.tabID,
            committedSelectionRevision: input.selectionRevision,
            committedSelection: input.selection,
            lookupContext: input.lookupContext,
            reviewGitContext: input.reviewGitContext,
            target: finalTarget,
            checkoutAuthorizations: finalTarget.checkouts.map { checkout in
                ContextBuilderFinalReviewCheckoutAuthorization(
                    checkout: checkout,
                    ordinaryPhysicalPaths: current
                        .ordinaryPhysicalPathsByCheckoutIdentity[checkout.identityKey] ?? []
                )
            },
            selectedArtifactAuthorizations: current.selectedArtifactAuthorizations
        )
    }

    private func makeReviewTarget(
        input: ContextBuilderReviewTargetInput,
        ownership: OwnershipPipelineResult
    ) -> ContextBuilderReviewTarget {
        ContextBuilderReviewTarget(
            workspaceID: input.workspaceID,
            tabID: input.tabID,
            sourceSelectionRevision: input.selectionRevision,
            initialOrdinarySelectionIdentities: ownership.ordinarySelectionIdentities,
            initialSelectedArtifactIdentities: ownership.selectedArtifactAuthorizations
                .map(\.absolutePath)
                .sorted(),
            checkouts: ownership.checkouts,
            primaryCheckout: ownership.primaryCheckout,
            artifactCapability: ownership.artifactCapability,
            displayContext: input.reviewGitContext.displayContext
        )
    }

    private func makeTarget(
        checkoutRootPath: String,
        repoKey: String,
        repositoryID: String,
        worktreeID: String,
        kind: FrozenVisibleGitCheckoutKind,
        selectedPaths: [String],
        scopedRoots: [WorkspaceRootRef],
        lookupContext: WorkspaceLookupContext
    ) throws -> ContextBuilderReviewCheckoutTarget {
        let canonicalPaths = selectedPaths.map(GitRepoRootAuthorization.canonicalPath)
        let matchingRoots = scopedRoots.filter { root in
            let rootPath = GitRepoRootAuthorization.canonicalPath(root.standardizedFullPath)
            return canonicalPaths.allSatisfy {
                $0 == rootPath || StandardizedPath.isDescendant($0, of: rootPath)
            }
        }
        let longest = matchingRoots.map { GitRepoRootAuthorization.canonicalPath($0.standardizedFullPath).count }.max()
        let mostSpecific = matchingRoots.filter {
            GitRepoRootAuthorization.canonicalPath($0.standardizedFullPath).count == longest
        }
        guard mostSpecific.count == 1, let physicalRoot = mostSpecific.first else {
            throw ContextBuilderReviewTargetUnavailableReason.ambiguousOwnership
        }
        let boundRoot = lookupContext.bindingProjection?.boundRootsForMetadata.first {
            $0.physicalRoot.id == physicalRoot.id
                && $0.physicalRoot.standardizedFullPath == physicalRoot.standardizedFullPath
        }
        let isSessionWorktreeRoot: Bool = switch lookupContext.rootScope {
        case let .sessionBoundWorkspace(_, physicalRootPaths):
            physicalRootPaths.contains(physicalRoot.standardizedFullPath)
        case let .validatedSessionBoundWorkspace(_, physicalRoots):
            physicalRoots.contains(where: {
                $0.id == physicalRoot.id
                    && $0.standardizedFullPath == physicalRoot.standardizedFullPath
            })
        case .visibleWorkspace, .visibleWorkspacePlusGitData, .allLoaded, .allLoadedExcludingGitData:
            false
        }
        let sessionRootAuthorization: WorkspaceSessionRootAuthorization?
        if isSessionWorktreeRoot {
            guard let authorization = boundRoot?.sessionRootAuthorization else {
                throw ContextBuilderReviewTargetUnavailableReason.staleWorkspaceRoot
            }
            sessionRootAuthorization = authorization
        } else {
            sessionRootAuthorization = nil
        }
        return ContextBuilderReviewCheckoutTarget(
            logicalWorkspaceRoot: boundRoot?.logicalRoot ?? physicalRoot,
            physicalWorkspaceRoot: physicalRoot,
            physicalWorkspaceRootKind: isSessionWorktreeRoot ? .sessionWorktree : .primaryWorkspace,
            checkoutRootPath: GitRepoRootAuthorization.canonicalPath(checkoutRootPath),
            repoKey: repoKey,
            repositoryID: repositoryID,
            worktreeID: worktreeID,
            kind: kind,
            sessionRootAuthorization: sessionRootAuthorization
        )
    }

    private func firstStaleAuthorization(
        in authorizations: [WorkspaceSessionRootAuthorization],
        store: WorkspaceFileContextStore
    ) async -> WorkspaceSessionRootAuthorizationMismatch? {
        for authorization in Set(authorizations) {
            if let mismatch = await store.validateSessionRootAuthorization(authorization) {
                return mismatch
            }
        }
        return nil
    }

    private func emitResolutionDiagnostic(
        input: ContextBuilderReviewTargetInput,
        phase: ContextBuilderReviewDiagnosticEvent.Phase,
        outcome: ContextBuilderReviewDiagnosticEvent.Outcome,
        candidateCount: Int,
        resolvedCount: Int,
        unresolvedCount: Int,
        authorizations: [WorkspaceSessionRootAuthorization],
        mismatch: WorkspaceSessionRootAuthorizationMismatch?
    ) {
        let distinctAuthorizations = Set(authorizations)
        let authorization = distinctAuthorizations.count == 1
            ? distinctAuthorizations.first
            : nil
        diagnosticSink(ContextBuilderReviewDiagnosticEvent(
            phase: phase,
            outcome: outcome,
            workspaceID: input.workspaceID,
            tabID: input.tabID,
            sessionID: authorization?.sessionID ?? input.lookupContext.bindingProjection?.sessionID,
            rootID: authorization?.root.id,
            ownershipGeneration: authorization?.ownershipGeneration,
            lifetimeID: authorization?.lifetimeID,
            candidateCount: candidateCount,
            resolvedCount: resolvedCount,
            unresolvedCount: unresolvedCount,
            mismatch: mismatch
        ))
    }

    private func emitRevalidationDiagnostic(
        target: ContextBuilderReviewTarget,
        outcome: ContextBuilderReviewDiagnosticEvent.Outcome,
        authorization: WorkspaceSessionRootAuthorization?,
        mismatch: WorkspaceSessionRootAuthorizationMismatch?
    ) {
        diagnosticSink(ContextBuilderReviewDiagnosticEvent(
            phase: .revalidation,
            outcome: outcome,
            workspaceID: target.workspaceID,
            tabID: target.tabID,
            sessionID: authorization?.sessionID,
            rootID: authorization?.root.id,
            ownershipGeneration: authorization?.ownershipGeneration,
            lifetimeID: authorization?.lifetimeID,
            candidateCount: target.checkouts.count,
            resolvedCount: outcome == .resolved ? target.checkouts.count : 0,
            unresolvedCount: outcome == .resolved ? 0 : 1,
            mismatch: mismatch
        ))
    }

    private static func reviewCandidates(
        from selection: StoredSelection,
        capability: SelectedGitArtifactCapability?
    ) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        func append(_ path: String) {
            guard seen.insert(path).inserted else { return }
            candidates.append(path)
        }

        WorkspaceGitDiffSelectionResolver.candidates(from: selection).forEach(append)
        artifactCandidates(from: selection, capability: capability).forEach(append)
        return candidates
    }

    private static func artifactCandidates(
        from selection: StoredSelection,
        capability: SelectedGitArtifactCapability?
    ) -> [String] {
        SelectedGitArtifactSelectionClassifier.artifactCandidatePaths(
            from: selection,
            capability: capability
        )
    }
}
