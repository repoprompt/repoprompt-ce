import Foundation

struct SelectedGitArtifactAuthorizationRequest {
    let physicalSelection: StoredSelection
    let capability: SelectedGitArtifactCapability
    let store: WorkspaceFileContextStore
    let delegationConsumer: SelectedGitArtifactDelegationConsumer?

    init(
        physicalSelection: StoredSelection,
        capability: SelectedGitArtifactCapability,
        store: WorkspaceFileContextStore,
        delegationConsumer: SelectedGitArtifactDelegationConsumer? = nil
    ) {
        self.physicalSelection = physicalSelection
        self.capability = capability
        self.store = store
        self.delegationConsumer = delegationConsumer
    }
}

struct ExactSelectedGitArtifactAuthorizationRequest {
    let exactAbsolutePaths: [String]
    let capability: SelectedGitArtifactCapability
    let store: WorkspaceFileContextStore
    let delegationConsumer: SelectedGitArtifactDelegationConsumer?

    init(
        exactAbsolutePaths: [String],
        capability: SelectedGitArtifactCapability,
        store: WorkspaceFileContextStore,
        delegationConsumer: SelectedGitArtifactDelegationConsumer? = nil
    ) {
        self.exactAbsolutePaths = exactAbsolutePaths
        self.capability = capability
        self.store = store
        self.delegationConsumer = delegationConsumer
    }
}

struct SelectedGitArtifactCheckoutProvenance: Equatable {
    let checkoutRootPath: String
    let repoKey: String
    let repositoryID: String
    let worktreeID: String
    let kind: FrozenVisibleGitCheckoutKind
}

struct SelectedGitArtifactAuthorizationResult {
    let entries: [ResolvedPromptFileEntry]
    let consumedSelectionPaths: Set<String>
    let dispositions: [SelectedGitArtifactDisposition]
    let displayAliasesByAbsolutePath: [String: String]
    let checkoutProvenanceByAbsolutePath: [String: SelectedGitArtifactCheckoutProvenance]

    init(
        entries: [ResolvedPromptFileEntry],
        consumedSelectionPaths: Set<String>,
        dispositions: [SelectedGitArtifactDisposition],
        displayAliasesByAbsolutePath: [String: String] = [:],
        checkoutProvenanceByAbsolutePath: [String: SelectedGitArtifactCheckoutProvenance] = [:]
    ) {
        self.entries = entries
        self.consumedSelectionPaths = consumedSelectionPaths
        self.dispositions = dispositions
        self.displayAliasesByAbsolutePath = displayAliasesByAbsolutePath
        self.checkoutProvenanceByAbsolutePath = checkoutProvenanceByAbsolutePath
    }

    var rejectedDisplayDiagnostics: [String] {
        dispositions.compactMap { disposition in
            guard case let .rejected(path, reason) = disposition else { return nil }
            let displayPath = displayAliasesByAbsolutePath[path] ?? path
            return "\(displayPath): \(reason.diagnosticLabel)"
        }
    }

    var dispositionsByAbsolutePath: [String: SelectedGitArtifactDisposition] {
        Dictionary(uniqueKeysWithValues: dispositions.map { disposition in
            switch disposition {
            case let .authorized(path, _, _), let .rejected(path, _):
                (path, disposition)
            }
        })
    }
}

enum SelectedGitArtifactKind: String, Equatable {
    case map
    case patch
}

enum SelectedGitArtifactReadability: Equatable {
    case readable
    case empty
}

enum SelectedGitArtifactRejectionReason: Equatable {
    case invalidAbsolutePath
    case outsideWorkspaceGitData
    case capabilityRootUnavailable
    case notCataloged
    case unsupportedArtifactPath
    case manifestNotCataloged
    case manifestUnreadable
    case manifestInvalid
    case manifestIdentityMismatch
    case tabMismatch
    case legacyTabNotAllowed
    case repositoryProvenanceMissing
    case checkoutProvenanceMismatch
    case unlistedPatch
    case contentUnreadable
    case notInDelegatedSelection
    case delegationConsumerMismatch
    case delegationWorkspaceMismatch
    case legacyArtifactNotDelegable
    case delegationBindingMismatch

    var diagnosticLabel: String {
        switch self {
        case .invalidAbsolutePath: "invalid selected artifact path"
        case .outsideWorkspaceGitData: "outside the frozen workspace Git-data root"
        case .capabilityRootUnavailable: "frozen Git-data root is no longer available"
        case .notCataloged: "selected artifact is not cataloged"
        case .unsupportedArtifactPath: "unsupported selected artifact path"
        case .manifestNotCataloged: "artifact manifest is not cataloged"
        case .manifestUnreadable: "artifact manifest is unreadable"
        case .manifestInvalid: "artifact manifest is invalid"
        case .manifestIdentityMismatch: "artifact manifest identity does not match"
        case .tabMismatch: "artifact belongs to a different tab"
        case .legacyTabNotAllowed: "legacy artifact is not allowed in a bound worktree"
        case .repositoryProvenanceMissing: "repository provenance is missing"
        case .checkoutProvenanceMismatch: "checkout provenance does not match"
        case .unlistedPatch: "patch is not listed by the artifact manifest"
        case .contentUnreadable: "selected artifact content is unreadable"
        case .notInDelegatedSelection: "artifact was not selected in the delegated launch snapshot"
        case .delegationConsumerMismatch: "delegated artifact consumer does not match"
        case .delegationWorkspaceMismatch: "delegated artifact workspace does not match"
        case .legacyArtifactNotDelegable: "legacy artifact without tab provenance cannot be delegated"
        case .delegationBindingMismatch: "delegated artifact checkout binding does not match"
        }
    }
}

enum SelectedGitArtifactDisposition: Equatable {
    case authorized(
        path: String,
        kind: SelectedGitArtifactKind,
        readability: SelectedGitArtifactReadability
    )
    case rejected(path: String, reason: SelectedGitArtifactRejectionReason)
}

/// Authorizes only already-selected, already-cataloged artifacts under one frozen Git-data root.
///
/// This service never broadens the caller's workspace scope and never falls back to raw filesystem
/// reads. MAP.txt is returned as an ordinary full-file entry; patch identity remains explicit.
struct SelectedGitDiffArtifactAuthorizationService {
    private enum Candidate {
        case map(snapshotRef: GitDiffSnapshotStore.GitDiffSnapshotRef)
        case patch(snapshotRef: GitDiffSnapshotStore.GitDiffSnapshotRef, relativePath: String)

        var snapshotRef: GitDiffSnapshotStore.GitDiffSnapshotRef {
            switch self {
            case let .map(snapshotRef), let .patch(snapshotRef, _):
                snapshotRef
            }
        }

        var kind: SelectedGitArtifactKind {
            switch self {
            case .map:
                .map
            case .patch:
                .patch
            }
        }
    }

    private enum CheckoutAuthorization: Equatable {
        case bound
        case visibleLinked
        case unbound
    }

    private struct AuthorizedCheckout: Equatable {
        let authority: CheckoutAuthorization
        let provenance: SelectedGitArtifactCheckoutProvenance
    }

    private let vcsService: VCSService
    private let snapshotStore = GitDiffSnapshotStore()

    init(vcsService: VCSService = .shared) {
        self.vcsService = vcsService
    }

    func authorize(
        _ request: SelectedGitArtifactAuthorizationRequest
    ) async -> SelectedGitArtifactAuthorizationResult {
        var entries: [ResolvedPromptFileEntry] = []
        var consumedPaths = Set<String>()
        var dispositions: [SelectedGitArtifactDisposition] = []
        var displayAliasesByAbsolutePath: [String: String] = [:]
        var checkoutProvenanceByAbsolutePath: [String: SelectedGitArtifactCheckoutProvenance] = [:]
        var seenPaths = Set<String>()

        let capability = request.capability
        let expectedGitDataPath = StandardizedPath.join(
            standardizedRoot: capability.workspaceDirectoryPath,
            standardizedRelativePath: "_git_data"
        )
        let currentGitDataRoot = await request.store.exactRootRef(
            path: capability.gitDataRoot.standardizedFullPath,
            kind: .workspaceGitData
        )
        let capabilityRootIsCurrent =
            capability.gitDataRoot.standardizedFullPath == expectedGitDataPath &&
            currentGitDataRoot == capability.gitDataRoot

        for rawPath in SelectedGitArtifactSelectionClassifier.selectionCandidatePaths(
            from: request.physicalSelection
        ) {
            guard let path = exactAbsolutePath(rawPath) else {
                if rawPath.hasPrefix(capability.gitDataRoot.standardizedFullPath + "/") {
                    consumedPaths.insert(rawPath)
                    if let alias = displayAlias(
                        for: rawPath,
                        gitDataRootPath: capability.gitDataRoot.standardizedFullPath
                    ) {
                        displayAliasesByAbsolutePath[rawPath] = alias
                    }
                    dispositions.append(.rejected(path: rawPath, reason: .invalidAbsolutePath))
                }
                continue
            }
            guard seenPaths.insert(path).inserted else { continue }

            guard StandardizedPath.isDescendant(path, of: capability.gitDataRoot.standardizedFullPath) else {
                continue
            }
            consumedPaths.insert(rawPath)
            if let alias = displayAlias(
                for: path,
                gitDataRootPath: capability.gitDataRoot.standardizedFullPath
            ) {
                displayAliasesByAbsolutePath[path] = alias
            }

            if let delegationRejection = authorizeDelegation(
                path: path,
                capability: capability,
                consumer: request.delegationConsumer
            ) {
                dispositions.append(.rejected(path: path, reason: delegationRejection))
                continue
            }

            guard capabilityRootIsCurrent else {
                dispositions.append(.rejected(path: path, reason: .capabilityRootUnavailable))
                continue
            }
            guard let file = await request.store.exactCatalogFile(
                absolutePath: path,
                expectedRoot: capability.gitDataRoot,
                expectedKind: .workspaceGitData
            ) else {
                dispositions.append(.rejected(path: path, reason: .notCataloged))
                continue
            }
            guard let candidate = candidate(
                for: path,
                gitDataRootPath: capability.gitDataRoot.standardizedFullPath
            ) else {
                dispositions.append(.rejected(path: path, reason: .unsupportedArtifactPath))
                continue
            }

            let manifestPath = StandardizedPath.join(
                standardizedRoot: capability.gitDataRoot.standardizedFullPath,
                standardizedRelativePath: candidate.snapshotRef.snapshotDirRel + "/manifest.json"
            )
            guard let manifestFile = await request.store.exactCatalogFile(
                absolutePath: manifestPath,
                expectedRoot: capability.gitDataRoot,
                expectedKind: .workspaceGitData
            ) else {
                dispositions.append(.rejected(path: path, reason: .manifestNotCataloged))
                continue
            }
            guard let manifestContent = await request.store.readExactCatalogFile(
                manifestFile,
                expectedRoot: capability.gitDataRoot
            ) else {
                dispositions.append(.rejected(path: path, reason: .manifestUnreadable))
                continue
            }
            guard let manifest = decodeManifest(manifestContent) else {
                dispositions.append(.rejected(path: path, reason: .manifestInvalid))
                continue
            }
            guard manifestMatches(candidate.snapshotRef, manifest: manifest) else {
                dispositions.append(.rejected(path: path, reason: .manifestIdentityMismatch))
                continue
            }
            guard let checkoutAuthorization = await authorizeCheckout(
                manifest: manifest,
                capability: capability,
                store: request.store
            ) else {
                let reason: SelectedGitArtifactRejectionReason =
                    manifest.repoRoot == nil ? .repositoryProvenanceMissing : .checkoutProvenanceMismatch
                dispositions.append(.rejected(path: path, reason: reason))
                continue
            }

            switch capability.access {
            case .direct:
                if let manifestTabID = manifest.tabID {
                    guard manifestTabID == capability.creatorTabID else {
                        dispositions.append(.rejected(path: path, reason: .tabMismatch))
                        continue
                    }
                } else if checkoutAuthorization.authority == .bound || checkoutAuthorization.authority == .visibleLinked {
                    dispositions.append(.rejected(path: path, reason: .legacyTabNotAllowed))
                    continue
                }
            case .delegated:
                guard let manifestTabID = manifest.tabID else {
                    dispositions.append(.rejected(path: path, reason: .legacyArtifactNotDelegable))
                    continue
                }
                guard manifestTabID == capability.creatorTabID else {
                    dispositions.append(.rejected(path: path, reason: .tabMismatch))
                    continue
                }
            }

            guard isWhitelisted(candidate, manifest: manifest) else {
                let reason: SelectedGitArtifactRejectionReason =
                    candidate.kind == .patch ? .unlistedPatch : .unsupportedArtifactPath
                dispositions.append(.rejected(path: path, reason: reason))
                continue
            }
            guard let content = await request.store.readExactCatalogFile(
                file,
                expectedRoot: capability.gitDataRoot
            ) else {
                dispositions.append(.rejected(path: path, reason: .contentUnreadable))
                continue
            }

            let readability: SelectedGitArtifactReadability =
                candidate.kind == .patch && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? .empty
                    : .readable
            entries.append(
                ResolvedPromptFileEntry(
                    file: file,
                    isCodemap: false,
                    mode: .fullFile,
                    loadedContent: content,
                    rootFolderPath: capability.gitDataRoot.standardizedFullPath,
                    role: candidate.kind == .patch ? .authorizedGitDiffArtifact : .ordinary
                )
            )
            dispositions.append(
                .authorized(path: path, kind: candidate.kind, readability: readability)
            )
            checkoutProvenanceByAbsolutePath[path] = checkoutAuthorization.provenance
        }

        return SelectedGitArtifactAuthorizationResult(
            entries: entries,
            consumedSelectionPaths: consumedPaths,
            dispositions: dispositions,
            displayAliasesByAbsolutePath: displayAliasesByAbsolutePath,
            checkoutProvenanceByAbsolutePath: checkoutProvenanceByAbsolutePath
        )
    }

    func authorizeExactPaths(
        _ request: ExactSelectedGitArtifactAuthorizationRequest
    ) async -> SelectedGitArtifactAuthorizationResult {
        await authorize(
            SelectedGitArtifactAuthorizationRequest(
                physicalSelection: StoredSelection(selectedPaths: request.exactAbsolutePaths),
                capability: request.capability,
                store: request.store,
                delegationConsumer: request.delegationConsumer
            )
        )
    }

    private func authorizeDelegation(
        path: String,
        capability: SelectedGitArtifactCapability,
        consumer: SelectedGitArtifactDelegationConsumer?
    ) -> SelectedGitArtifactRejectionReason? {
        guard case let .delegated(delegation) = capability.access else {
            return consumer == nil ? nil : .delegationConsumerMismatch
        }
        guard let consumer else { return .delegationConsumerMismatch }

        guard capability.workspaceID == delegation.sourceWorkspaceID,
              delegation.sourceWorkspaceID == delegation.targetWorkspaceID,
              consumer.workspaceID == delegation.targetWorkspaceID
        else { return .delegationWorkspaceMismatch }

        guard delegation.exactSelectedArtifactPaths.contains(path) else {
            return .notInDelegatedSelection
        }

        guard capability.creatorTabID == delegation.sourceTabID,
              capability.sessionID == delegation.sourceAgentSessionID,
              consumer.tabID == delegation.targetTabID,
              consumer.agentSessionID == delegation.targetAgentSessionID,
              consumer.agentRunID == delegation.targetAgentRunID
        else { return .delegationConsumerMismatch }

        // The source capability owns manifest checkout authority. Target bindings are only the
        // exact child-consumer lifetime snapshot and may intentionally differ from the source.
        guard Set(delegation.targetBoundCheckouts) == Set(consumer.boundCheckouts) else {
            return .delegationBindingMismatch
        }

        return nil
    }

    private func displayAlias(for path: String, gitDataRootPath: String) -> String? {
        guard path.hasPrefix(gitDataRootPath + "/") else { return nil }
        let relativePath = String(path.dropFirst(gitDataRootPath.count + 1))
        guard !relativePath.isEmpty,
              !StandardizedPath.containsNUL(relativePath)
        else { return nil }
        return "_git_data/\(relativePath)"
    }

    private func candidate(for path: String, gitDataRootPath: String) -> Candidate? {
        guard StandardizedPath.isDescendant(path, of: gitDataRootPath), path != gitDataRootPath else {
            return nil
        }
        let relativePath = String(path.dropFirst(gitDataRootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard GitDiffArtifactPathPolicy.isSafeRelativeArtifactPath(relativePath) else { return nil }

        if relativePath.hasSuffix("/MAP.txt") {
            let snapshotPath = String(relativePath.dropLast("/MAP.txt".count))
            guard let ref = snapshotStore.parseSnapshotRef(snapshotPath),
                  ref.repoKey != nil,
                  ref.snapshotDirRel == snapshotPath
            else { return nil }
            return .map(snapshotRef: ref)
        }

        guard let diffRange = relativePath.range(of: "/diff/", options: .backwards) else {
            return nil
        }
        let snapshotPath = String(relativePath[..<diffRange.lowerBound])
        let suffix = String(relativePath[diffRange.upperBound...])
        let artifactRelativePath = "diff/" + suffix
        let lowercased = artifactRelativePath.lowercased()
        guard lowercased.hasSuffix(".patch") || lowercased.hasSuffix(".diff"),
              let ref = snapshotStore.parseSnapshotRef(snapshotPath),
              ref.repoKey != nil,
              ref.snapshotDirRel == snapshotPath
        else { return nil }
        return .patch(snapshotRef: ref, relativePath: artifactRelativePath)
    }

    private func manifestMatches(
        _ ref: GitDiffSnapshotStore.GitDiffSnapshotRef,
        manifest: GitDiffSnapshotManifest
    ) -> Bool {
        guard let refRepoKey = ref.repoKey,
              let manifestRepoKey = manifest.repoKey,
              refRepoKey == manifestRepoKey,
              let normalizedManifestID = GitDiffSnapshotStore.normalizeSnapshotID(manifest.snapshotID),
              normalizedManifestID == manifest.snapshotID,
              normalizedManifestID == ref.snapshotID
        else { return false }
        return true
    }

    private func authorizeCheckout(
        manifest: GitDiffSnapshotManifest,
        capability: SelectedGitArtifactCapability,
        store: WorkspaceFileContextStore
    ) async -> AuthorizedCheckout? {
        guard let manifestRepoRoot = normalizedRootPath(manifest.repoRoot) else { return nil }
        let boundCheckout = capability.boundCheckouts.first {
            GitRepoRootAuthorization.canonicalPath($0.physicalWorktreeRootPath) == manifestRepoRoot
        }
        let visibleCheckout = capability.visibleRootCheckouts.first {
            $0.visibleRootPath == manifestRepoRoot
        }
        let hasWorktreeMetadata =
            manifest.isWorktree == true ||
            manifest.worktreeName != nil ||
            manifest.worktreeRoot != nil ||
            manifest.mainWorktreeRoot != nil ||
            manifest.commonGitDir != nil

        let resolved = await vcsService.resolveRepo(
            from: URL(fileURLWithPath: manifestRepoRoot, isDirectory: true)
        )
        let exactResolvedRoot = resolved.flatMap { candidate -> VCSResolvedRepo? in
            guard candidate.backendKind == .git,
                  GitRepoRootAuthorization.canonicalPath(candidate.rootURL.path) == manifestRepoRoot
            else { return nil }
            return candidate
        }
        let liveLayout = exactResolvedRoot.flatMap {
            GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: $0.rootURL)
        }
        let isLinkedCandidate = boundCheckout != nil
            || hasWorktreeMetadata
            || liveLayout?.isLinkedWorktree == true

        if isLinkedCandidate {
            let liveMainWorktreeRoot = liveLayout?.knownMainWorktreeRoot.map {
                GitRepoRootAuthorization.canonicalPath($0.path)
            }
            let manifestMainWorktreeRoot = normalizedRootPath(manifest.mainWorktreeRoot)
            guard manifest.isWorktree == true,
                  let manifestWorktreeRoot = normalizedRootPath(manifest.worktreeRoot),
                  let manifestCommonGitDir = normalizedRootPath(manifest.commonGitDir),
                  manifestWorktreeRoot == manifestRepoRoot,
                  let layout = liveLayout,
                  layout.isLinkedWorktree,
                  GitRepoRootAuthorization.canonicalPath(layout.workTreeRoot.path) == manifestWorktreeRoot,
                  GitRepoRootAuthorization.canonicalPath(layout.commonDir.path) == manifestCommonGitDir
            else { return nil }

            let repositoryIdentity = GitWorktreeIdentity.repositoryIdentity(
                commonGitDir: layout.commonDir,
                mainWorktreeRoot: layout.knownMainWorktreeRoot
            )
            let worktreeID = GitWorktreeIdentity.worktreeID(
                repositoryID: repositoryIdentity.repositoryID,
                gitDir: layout.gitDir,
                isMain: false,
                path: layout.workTreeRoot
            )

            let provenance = SelectedGitArtifactCheckoutProvenance(
                checkoutRootPath: manifestWorktreeRoot,
                repoKey: GitRepoDescriptor(rootURL: layout.workTreeRoot).repoKey,
                repositoryID: repositoryIdentity.repositoryID,
                worktreeID: worktreeID,
                kind: .linkedWorktree
            )
            if let boundCheckout,
               manifestWorktreeRoot == GitRepoRootAuthorization.canonicalPath(
                   boundCheckout.physicalWorktreeRootPath
               ),
               repositoryIdentity.repositoryID == boundCheckout.repositoryID,
               worktreeID == boundCheckout.worktreeID
            {
                return AuthorizedCheckout(authority: .bound, provenance: provenance)
            }

            guard let visibleCheckout,
                  visibleCheckout.kind == .linkedWorktree,
                  visibleCheckout.repositoryRootPath == manifestRepoRoot,
                  visibleCheckout.worktreeRootPath == manifestWorktreeRoot,
                  visibleCheckout.commonGitDirectoryPath == manifestCommonGitDir,
                  manifestMainWorktreeRoot == liveMainWorktreeRoot,
                  visibleCheckout.mainWorktreeRootPath == liveMainWorktreeRoot,
                  visibleCheckout.repositoryID == repositoryIdentity.repositoryID,
                  visibleCheckout.worktreeID == worktreeID,
                  await visibleCheckoutIsCurrent(visibleCheckout, store: store)
            else { return nil }
            return AuthorizedCheckout(authority: .visibleLinked, provenance: provenance)
        }

        guard GitRepoRootAuthorization.isPathWithinAuthorizedRoots(
            manifestRepoRoot,
            roots: capability.canonicalWorkspaceRootPaths
        ),
            let resolved = exactResolvedRoot,
            let layout = liveLayout,
            !layout.isLinkedWorktree
        else { return nil }

        if let visibleCheckout,
           visibleCheckout.kind == .canonical,
           await !visibleCheckoutIsCurrent(visibleCheckout, store: store)
        {
            return nil
        }
        let repositoryIdentity = GitWorktreeIdentity.repositoryIdentity(
            commonGitDir: layout.commonDir,
            mainWorktreeRoot: layout.knownMainWorktreeRoot
        )
        let worktreeID = GitWorktreeIdentity.worktreeID(
            repositoryID: repositoryIdentity.repositoryID,
            gitDir: layout.gitDir,
            isMain: true,
            path: layout.workTreeRoot
        )
        _ = resolved
        return AuthorizedCheckout(
            authority: .unbound,
            provenance: SelectedGitArtifactCheckoutProvenance(
                checkoutRootPath: manifestRepoRoot,
                repoKey: GitRepoDescriptor(rootURL: layout.workTreeRoot).repoKey,
                repositoryID: repositoryIdentity.repositoryID,
                worktreeID: worktreeID,
                kind: .canonical
            )
        )
    }

    func visibleRootCheckoutsAreCurrent(
        capability: SelectedGitArtifactCapability,
        store: WorkspaceFileContextStore
    ) async -> Bool {
        for checkout in capability.visibleRootCheckouts {
            guard await visibleCheckoutIsCurrent(checkout, store: store) else { return false }
        }
        for checkout in capability.visibleRootCheckouts {
            guard await store.exactRootRef(
                path: checkout.workspaceRoot.standardizedFullPath,
                kind: .primaryWorkspace
            ) == checkout.workspaceRoot else { return false }
        }
        return true
    }

    private func visibleCheckoutIsCurrent(
        _ checkout: FrozenVisibleGitCheckoutIdentity,
        store: WorkspaceFileContextStore
    ) async -> Bool {
        guard let currentRoot = await store.exactRootRef(
            path: checkout.workspaceRoot.standardizedFullPath,
            kind: .primaryWorkspace
        ),
            currentRoot == checkout.workspaceRoot,
            GitRepoRootAuthorization.canonicalPath(currentRoot.standardizedFullPath)
            == checkout.visibleRootPath,
            let resolved = await vcsService.resolveRepo(
                from: URL(fileURLWithPath: currentRoot.standardizedFullPath, isDirectory: true)
            ),
            resolved.backendKind == .git,
            GitRepoRootAuthorization.canonicalPath(resolved.rootURL.path)
            == checkout.repositoryRootPath,
            let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: resolved.rootURL),
            GitRepoRootAuthorization.canonicalPath(layout.workTreeRoot.path)
            == checkout.worktreeRootPath,
            GitRepoRootAuthorization.canonicalPath(layout.commonDir.path)
            == checkout.commonGitDirectoryPath,
            layout.isLinkedWorktree == (checkout.kind == .linkedWorktree)
        else { return false }

        let liveMainWorktreeRoot = layout.knownMainWorktreeRoot.map {
            GitRepoRootAuthorization.canonicalPath($0.path)
        }
        guard liveMainWorktreeRoot == checkout.mainWorktreeRootPath else { return false }

        let repositoryIdentity = GitWorktreeIdentity.repositoryIdentity(
            commonGitDir: layout.commonDir,
            mainWorktreeRoot: layout.knownMainWorktreeRoot
        )
        let worktreeID = GitWorktreeIdentity.worktreeID(
            repositoryID: repositoryIdentity.repositoryID,
            gitDir: layout.gitDir,
            isMain: !layout.isLinkedWorktree,
            path: layout.workTreeRoot
        )
        guard repositoryIdentity.repositoryID == checkout.repositoryID,
              worktreeID == checkout.worktreeID
        else { return false }
        return await store.exactRootRef(
            path: checkout.workspaceRoot.standardizedFullPath,
            kind: .primaryWorkspace
        ) == checkout.workspaceRoot
    }

    private func isWhitelisted(
        _ candidate: Candidate,
        manifest: GitDiffSnapshotManifest
    ) -> Bool {
        switch candidate {
        case .map:
            return true
        case let .patch(_, relativePath):
            if relativePath == "diff/all.patch" {
                return true
            }
            let listedPaths = Set(manifest.files.compactMap { file -> String? in
                guard let patchPath = file.patchPath,
                      let normalized = GitDiffArtifactPathPolicy.safeManifestPatchPath(patchPath)
                else { return nil }
                return normalized
            })
            return listedPaths.contains(relativePath)
        }
    }

    private func exactAbsolutePath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.hasPrefix("/"),
              !StandardizedPath.containsNUL(trimmed)
        else { return nil }
        let standardized = StandardizedPath.absolute(trimmed)
        guard standardized == trimmed else { return nil }
        return standardized
    }

    private func normalizedRootPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else { return nil }
        return GitRepoRootAuthorization.canonicalPath(trimmed)
    }

    private func decodeManifest(_ content: String) -> GitDiffSnapshotManifest? {
        guard let data = content.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GitDiffSnapshotManifest.self, from: data)
    }
}
