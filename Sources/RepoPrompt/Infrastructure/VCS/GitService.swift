import CryptoKit
import Darwin
import Foundation

/// Async Git helper for fetching repository information
/// Based on the macOS 14+ Swift Git integration guide
actor GitService {
    private static let gitProcessTimeout: Duration = .seconds(120)
    private static let gitProcessTerminationGrace: Duration = .seconds(5)
    private static let gitCheckAttrOutputByteLimit = 4 * 1024 * 1024
    private static let gitBlobSizeOutputByteLimit = 64
    private static let gitBlobDiagnosticOutputByteLimit = 64 * 1024
    /// Root/search startup snapshots and receipts are process-local. A process-local salt
    /// provides one path-free repository namespace shared by all GitService instances while
    /// intentionally making restart/receipt loss fall back to the full crawler.
    private static let workspaceAuthorityNamespaceSalt = Data(
        SHA256.hash(data: Data((UUID().uuidString + UUID().uuidString).utf8))
    )

    // MARK: - Types

    struct GitError: LocalizedError {
        let message: String
        var errorDescription: String? {
            GitService.friendlyErrorDescription(for: message)
        }
    }

    private enum GitProcessCaptureError: Error {
        case stdoutByteLimitExceeded
        case stderrByteLimitExceeded
        case timedOut
    }

    private enum GitProcessRepositoryBinding {
        case inferred
        case exactObjectRead(GitRepositoryLayout)
        case exactWorktree(GitRepositoryLayout)
    }

    // MARK: - Worktree Layout Cache

    private struct CachedWorktreeLayout {
        var layout: GitRepositoryLayout
        var accessOrdinal: UInt64
        var retainCountsByGitDirectory: [String: Int]
        var isInvalidated: Bool

        var retainCount: Int {
            retainCountsByGitDirectory.values.reduce(0, +)
        }
    }

    #if DEBUG
        struct WorktreeLayoutCacheSnapshot: Equatable {
            let entryCount: Int
            let retainedPaths: Set<String>
            let invalidatedPaths: Set<String>
            let paths: Set<String>
        }
    #endif

    /// Cached Git repository layouts to avoid repeated filesystem checks.
    /// Key: standardized repo root path
    /// Value: resolved layout (only non-nil results are cached)
    private var worktreeLayoutCache: [String: CachedWorktreeLayout] = [:]
    private let worktreeLayoutCacheLimit: Int
    private var worktreeLayoutCacheAccessOrdinal: UInt64 = 0

    /// Get the repository layout for a given repo URL, using cache when available.
    /// Only caches successful resolutions to prevent unbounded cache growth from
    /// calls with non-repo paths.
    private func getLayout(for repoURL: URL) -> GitRepositoryLayout? {
        let key = repoURL.standardizedFileURL.path

        if var cached = worktreeLayoutCache[key], !cached.isInvalidated {
            worktreeLayoutCacheAccessOrdinal &+= 1
            cached.accessOrdinal = worktreeLayoutCacheAccessOrdinal
            worktreeLayoutCache[key] = cached
            return cached.layout
        }

        let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: repoURL)
        // Only cache non-nil to avoid unbounded growth from failed lookups
        if let layout {
            cacheLayout(layout, forKey: key)
        }
        return layout
    }

    private func cacheLayout(
        _ layout: GitRepositoryLayout,
        forKey key: String
    ) {
        worktreeLayoutCacheAccessOrdinal &+= 1
        let existingRetains = worktreeLayoutCache[key]?.retainCountsByGitDirectory ?? [:]
        worktreeLayoutCache[key] = CachedWorktreeLayout(
            layout: layout,
            accessOrdinal: worktreeLayoutCacheAccessOrdinal,
            retainCountsByGitDirectory: existingRetains,
            isInvalidated: false
        )
        evictWorktreeLayoutsIfNeeded()
    }

    private func evictWorktreeLayoutsIfNeeded() {
        while worktreeLayoutCache.count > worktreeLayoutCacheLimit,
              let candidate = worktreeLayoutCache
              .filter({ $0.value.retainCount == 0 })
              .min(by: { $0.value.accessOrdinal < $1.value.accessOrdinal })
        {
            worktreeLayoutCache.removeValue(forKey: candidate.key)
        }
    }

    func retainRepositoryLayout(_ layout: GitRepositoryLayout) {
        let key = layout.workTreeRoot.standardizedFileURL.path
        let gitDirectoryKey = layout.gitDir.standardizedFileURL.path
        worktreeLayoutCacheAccessOrdinal &+= 1
        var retains = worktreeLayoutCache[key]?.retainCountsByGitDirectory ?? [:]
        retains[gitDirectoryKey, default: 0] += 1
        worktreeLayoutCache[key] = CachedWorktreeLayout(
            layout: layout,
            accessOrdinal: worktreeLayoutCacheAccessOrdinal,
            retainCountsByGitDirectory: retains,
            isInvalidated: false
        )
        evictWorktreeLayoutsIfNeeded()
    }

    func releaseRepositoryLayout(
        workTreeRoot: URL,
        expectedGitDirectory: URL
    ) {
        let key = workTreeRoot.standardizedFileURL.path
        let gitDirectoryKey = expectedGitDirectory.standardizedFileURL.path
        guard var cached = worktreeLayoutCache[key],
              let existingCount = cached.retainCountsByGitDirectory[gitDirectoryKey],
              existingCount > 0
        else { return }
        if existingCount == 1 {
            cached.retainCountsByGitDirectory.removeValue(forKey: gitDirectoryKey)
        } else {
            cached.retainCountsByGitDirectory[gitDirectoryKey] = existingCount - 1
        }
        if cached.retainCount == 0 {
            worktreeLayoutCache.removeValue(forKey: key)
        } else {
            worktreeLayoutCache[key] = cached
        }
        evictWorktreeLayoutsIfNeeded()
    }

    /// Clear the worktree layout cache (e.g., when workspace changes).
    func clearLayoutCache() {
        for key in Array(worktreeLayoutCache.keys) {
            guard var cached = worktreeLayoutCache[key] else { continue }
            if cached.retainCount == 0 {
                worktreeLayoutCache.removeValue(forKey: key)
            } else {
                cached.isInvalidated = true
                worktreeLayoutCache[key] = cached
            }
        }
    }

    #if DEBUG
        func worktreeLayoutCacheSnapshotForTesting() -> WorktreeLayoutCacheSnapshot {
            WorktreeLayoutCacheSnapshot(
                entryCount: worktreeLayoutCache.count,
                retainedPaths: Set(worktreeLayoutCache.compactMap { key, value in
                    value.retainCount > 0 ? key : nil
                }),
                invalidatedPaths: Set(worktreeLayoutCache.compactMap { key, value in
                    value.isInvalidated ? key : nil
                }),
                paths: Set(worktreeLayoutCache.keys)
            )
        }
    #endif

    private let worktreeMutationCoordinator = GitWorktreeMutationCoordinator()
    private let inheritedProcessEnvironment: [String: String]
    private let gitExecutableURL: URL
    private let processAdmissionController: GitProcessAdmissionController
    private let workspaceStateAuthority: GitWorkspaceStateAuthority
    private let creationReceiptCoordinator = WorkspaceRootCreationReceiptCoordinator()
    private let processTerminationGrace: Duration
    private var preparedBaseProcessEnvironment: [String: String]?

    init(
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        processAdmissionController: GitProcessAdmissionController = .shared,
        workspaceStateAuthority: GitWorkspaceStateAuthority = .shared,
        processTerminationGrace: Duration = GitService.gitProcessTerminationGrace,
        worktreeLayoutCacheLimit: Int = 128,
        inheritedProcessEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        precondition(worktreeLayoutCacheLimit > 0)
        self.gitExecutableURL = gitExecutableURL
        self.processAdmissionController = processAdmissionController
        self.workspaceStateAuthority = workspaceStateAuthority
        self.processTerminationGrace = processTerminationGrace
        self.worktreeLayoutCacheLimit = worktreeLayoutCacheLimit
        self.inheritedProcessEnvironment = inheritedProcessEnvironment
    }

    struct UncommittedFile: Equatable {
        let path: String
        let status: String // M, A, D, R, C, U, ?, !
        let additions: Int?
        let deletions: Int?

        init(
            path: String,
            status: String,
            additions: Int? = nil,
            deletions: Int? = nil
        ) {
            self.path = path
            self.status = status
            self.additions = additions
            self.deletions = deletions
        }
    }

    struct Branch {
        let name: String
        let isCurrent: Bool
        let lastCommitDate: Date?
    }

    struct Tag {
        let name: String
        let commitDate: Date?
    }

    /// Determines which reference the working tree is compared against
    enum CompareBase {
        /// Compare working tree against HEAD (includes staged & unstaged changes)
        case head
        /// Compare working tree/current branch against the specified branch
        case branch(String)
    }

    // MARK: - Public API

    /// Find the git repository root starting from the given path
    func findGitRoot(from path: URL) async throws -> URL? {
        let (stdout, _, exitCode) = try await runGit(
            ["rev-parse", "--show-toplevel"],
            at: path
        )

        guard exitCode == 0 else {
            return nil // Not a git repository or not found
        }

        let rootPath = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: rootPath)
    }

    /// Check if the given path is within a git repository
    func isGitRepository(at path: URL) async -> Bool {
        do {
            let _ = try await findGitRoot(from: path)
            return true
        } catch {
            return false
        }
    }

    /// Distinguishes a bare repository from an ordinary non-Git directory when
    /// `--show-toplevel` cannot produce a worktree root.
    func gitRepositoryKind(at path: URL) async throws -> GitRepositoryKind {
        if try await findGitRoot(from: path) != nil {
            return .worktree
        }
        let (stdout, _, exitCode) = try await runGit(
            ["rev-parse", "--is-bare-repository"],
            at: path
        )
        guard exitCode == 0 else {
            // `rev-parse` has no repository context to inspect when this structured probe
            // exits unsuccessfully. Do not parse localized diagnostics to distinguish it.
            if Self.hasGitControlEntry(inOrAbove: path) {
                throw GitError(message: "git repository kind probe failed")
            }
            return .nonGit
        }
        switch stdout.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "true": return .bare
        case "false": return .worktree
        default:
            throw GitBlobIdentityError.malformedGitOutput("invalid bare repository response")
        }
    }

    private nonisolated static func hasGitControlEntry(inOrAbove path: URL) -> Bool {
        var directory = path.resolvingSymlinksInPath().standardizedFileURL
        for _ in 0 ..< 512 {
            var value = stat()
            let controlPath = directory.appendingPathComponent(".git").path
            if lstat(controlPath, &value) == 0 || errno == EACCES || errno == EPERM {
                return true
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return false }
            directory = parent
        }
        return false
    }

    /// List Git worktrees for the repository using porcelain output.
    /// Prefers `--porcelain -z` and falls back to newline-delimited porcelain on older Git versions.
    func listWorktrees(at repoURL: URL) async throws -> [GitWorktreeDescriptor] {
        let (stdout, stderr, exitCode) = try await runGit(
            ["worktree", "list", "--porcelain", "-z"],
            at: repoURL
        )

        if exitCode == 0 {
            let records = try GitWorktreePorcelainParser.parse(stdout, format: .nulTerminated)
            return try await makeWorktreeDescriptors(from: records, currentRepoURL: repoURL)
        }

        guard Self.shouldFallbackFromWorktreeListZError(stderr) else {
            throw GitError(message: "git worktree list --porcelain -z failed: \(stderr)")
        }

        let (fallbackStdout, fallbackStderr, fallbackExitCode) = try await runGit(
            ["worktree", "list", "--porcelain"],
            at: repoURL
        )
        guard fallbackExitCode == 0 else {
            throw GitError(message: "git worktree list --porcelain failed: \(fallbackStderr)")
        }

        let records = try GitWorktreePorcelainParser.parse(fallbackStdout, format: .newlineTerminated)
        return try await makeWorktreeDescriptors(from: records, currentRepoURL: repoURL)
    }

    /// Create a Git worktree using the existing Git subprocess plumbing.
    func createWorktree(
        request: GitWorktreeCreateRequest,
        at repoURL: URL
    ) async throws -> GitWorktreeDescriptor {
        let result = try await createWorktreeWithResult(request: request, at: repoURL)
        return result.descriptor
    }

    /// Create a Git worktree and return best-effort `.worktreeinclude` copy details.
    /// Receipt observation is additive and fail-open: creation remains successful when
    /// authority or witness evidence cannot be proven.
    func createWorktreeWithResult(
        request: GitWorktreeCreateRequest,
        at repoURL: URL,
        initializationContext: GitWorktreeInitializationContext? = nil
    ) async throws -> GitWorktreeCreateResult {
        let sourceLayout = getLayout(for: repoURL)
        let mutationKey = sourceLayout?.commonDir.standardizedFileURL.path
            ?? repoURL.standardizedFileURL.path

        return try await worktreeMutationCoordinator.withLock(key: mutationKey) { [weak self] in
            guard let self else {
                throw GitError(message: "git service was released before worktree creation")
            }
            if let mainWorktreeRoot = request.mainWorktreeRoot {
                try GitWorktreeDefaultPathPlanner.validate(
                    path: request.path,
                    mainWorktreeRoot: mainWorktreeRoot,
                    knownWorktreeRoots: request.knownWorktreeRoots,
                    appManagedContainer: request.appManagedContainer,
                    allowExternalPath: request.allowExternalPath
                )
            }

            let destinationIsAppManaged = request.appManagedContainer.map {
                Self.isPath(request.path, equalToOrInside: $0)
            } ?? false
            let reusableReceiptDestinationIsEligible = destinationIsAppManaged
                && request.copyWorktreeIncludeFiles
            var parentEvidence: (
                lease: GitWorkspaceAuthorityLease,
                snapshot: WorkspaceRootReusableSnapshot,
                baseTree: GitObjectID
            )?
            var witnessSession: WorkspaceRootCreationReceiptCoordinator.Session?
            if let initializationContext,
               initializationContext.observeReceipt,
               reusableReceiptDestinationIsEligible,
               let sourceLayout,
               let reusableEvidence = try? await reusableParentEvidence(
                   layout: sourceLayout,
                   prefix: initializationContext.repositoryRelativeRootPrefix
               ),
               let targetTree = try? await resolveTreeOID(
                   request.baseRef?.isEmpty == false ? request.baseRef! : "HEAD",
                   in: sourceLayout
               )
            {
                parentEvidence = (reusableEvidence.lease, reusableEvidence.snapshot, targetTree)
                witnessSession = creationReceiptCoordinator.start(destinationURL: request.path)
            }

            let mutationToken: GitWorkspaceMutationToken? = if let sourceLayout {
                await workspaceStateAuthority.beginMutation(
                    repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: sourceLayout),
                    kind: .worktreeCreate,
                    correlationID: initializationContext?.correlationID
                )
            } else {
                nil
            }
            do {
                var args = ["worktree", "add"]
                if request.force { args.append("--force") }
                if request.detach { args.append("--detach") }
                if let lockReason = request.lockReason {
                    args.append("--lock")
                    if !lockReason.isEmpty {
                        args.append("--reason")
                        args.append(lockReason)
                    }
                }
                if let branch = request.branch, !branch.isEmpty {
                    args.append("-b")
                    args.append(branch)
                }
                args.append(request.path.standardizedFileURL.path)
                if let baseRef = request.baseRef, !baseRef.isEmpty { args.append(baseRef) }

                let (_, stderr, exitCode) = try await runGit(args, at: repoURL)
                guard exitCode == 0 else {
                    throw GitError(message: "git worktree add failed: \(stderr)")
                }

                await clearLayoutCache()
                let createdPath = request.path.standardizedFileURL.path
                let worktrees = try await listWorktrees(at: repoURL)
                guard let created = worktrees.first(where: { $0.path == createdPath }) else {
                    throw GitError(message: "git worktree add succeeded but created worktree was not listed: \(createdPath)")
                }
                let destinationURL = URL(fileURLWithPath: created.path, isDirectory: true)
                let includeCopyResult = await copyWorktreeIncludeFilesIfRequested(
                    request: request,
                    sourceRepoURL: repoURL,
                    destinationURL: destinationURL
                )

                let targetLayout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: destinationURL)
                let witnessCoverage = witnessSession.map(creationReceiptCoordinator.finish)
                witnessSession = nil
                if let mutationToken {
                    await workspaceStateAuthority.finishMutation(mutationToken, outcome: .succeeded)
                }
                let targetAuthority: GitWorkspaceAuthoritySnapshot? = if let targetLayout,
                                                                         let initializationContext,
                                                                         parentEvidence != nil
                {
                    try? await generationFencedAuthoritySnapshot(
                        layout: targetLayout,
                        prefix: initializationContext.repositoryRelativeRootPrefix
                    )
                } else {
                    nil
                }
                let includeCopyHadFailures = includeCopyResult.map {
                    !$0.skippedSummaries.isEmpty || !$0.errorSummaries.isEmpty
                } ?? false
                let includeCopyWasComplete = reusableReceiptDestinationIsEligible
                    && !includeCopyHadFailures
                    && (includeCopyResult.map {
                        $0.copiedCount == $0.matchedCount
                            && $0.copiedRelativePaths.count == $0.copiedCount
                    } ?? true)

                let receipt: GitWorktreeCreationReceipt? = if let initializationContext,
                                                              let parentEvidence,
                                                              let targetLayout,
                                                              let targetAuthority,
                                                              let witnessCoverage
                {
                    GitWorktreeCreationReceipt(
                        id: UUID(),
                        agentSessionID: initializationContext.agentSessionID,
                        correlationID: initializationContext.correlationID,
                        standardizedLogicalRootPath: initializationContext.standardizedLogicalRootPath,
                        expectedOwnerBindingGeneration: initializationContext.expectedOwnerBindingGeneration,
                        mutationID: mutationToken?.id ?? UUID(),
                        parentSnapshotIdentity: parentEvidence.snapshot.identity,
                        parentCompatibilityKey: parentEvidence.snapshot.compatibilityKey,
                        parentAuthorityBefore: parentEvidence.lease.snapshot,
                        targetAuthorityAfter: targetAuthority,
                        requestedBaseRef: request.baseRef,
                        resolvedBaseTreeOID: parentEvidence.baseTree,
                        repositoryRelativeRootPrefix: initializationContext.repositoryRelativeRootPrefix,
                        plannedTargetPath: request.path.standardizedFileURL.path,
                        actualTargetPath: created.path,
                        exactCopiedRelativePaths: includeCopyResult?.copiedRelativePaths ?? [],
                        includeCopyHadFailures: includeCopyHadFailures,
                        includeCopyWasComplete: includeCopyWasComplete,
                        destinationIsAppManaged: destinationIsAppManaged,
                        worktree: created,
                        targetLayout: targetLayout,
                        witnessCoverage: witnessCoverage,
                        expiresAtUptimeNanoseconds: witnessCoverage.endedAtUptimeNanoseconds
                            + UInt64(60 * NSEC_PER_SEC)
                    )
                } else {
                    nil
                }
                let initializationFallbackReason: WorkspaceRootSeedFallbackReason? = if initializationContext?.observeReceipt == true {
                    if !destinationIsAppManaged {
                        .unsupportedDestination
                    } else if !includeCopyWasComplete {
                        .includeCopyFailure
                    } else if receipt == nil {
                        .authorityUnstable
                    } else {
                        nil
                    }
                } else {
                    nil
                }
                return GitWorktreeCreateResult(
                    descriptor: created,
                    includeCopyResult: includeCopyResult,
                    initializationReceipt: receipt,
                    initializationFallbackReason: initializationFallbackReason
                )
            } catch is CancellationError {
                if let witnessSession { _ = creationReceiptCoordinator.finish(witnessSession) }
                if let mutationToken {
                    await workspaceStateAuthority.finishMutation(mutationToken, outcome: .cancelled)
                }
                throw CancellationError()
            } catch {
                if let witnessSession { _ = creationReceiptCoordinator.finish(witnessSession) }
                if let mutationToken {
                    await workspaceStateAuthority.finishMutation(mutationToken, outcome: .failed)
                }
                throw error
            }
        }
    }

    private func reusableParentEvidence(
        layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix
    ) async throws -> (lease: GitWorkspaceAuthorityLease, snapshot: WorkspaceRootReusableSnapshot)? {
        if let lease = try? await currentAuthorityLease(layout: layout, prefix: prefix),
           let snapshot = await workspaceStateAuthority.currentReusableSnapshot(capturedUsing: lease)
        {
            return (lease, snapshot)
        }

        var discoveryObservation: GitWorkspaceMetadataMonitor.RetainToken?
        var replacementObservation: GitWorkspaceMetadataMonitor.RetainToken?
        do {
            let discoveryToken = try await workspaceStateAuthority.retainMetadataObservation(for: layout)
            discoveryObservation = discoveryToken
            let discovery = try await workspaceAuthoritySnapshot(in: layout, prefix: prefix)
            let discoveredExternalPaths = Self.canonicalPathSet(
                discovery.metadata.resolvedExternalAuthorityPaths
            )
            let observation = try await workspaceStateAuthority.retainMetadataObservation(
                for: layout,
                additionalAuthorityPaths: discovery.metadata.resolvedExternalAuthorityPaths
            )
            replacementObservation = observation
            await workspaceStateAuthority.releaseMetadataObservation(discoveryToken)
            discoveryObservation = nil

            let scope = GitWorkspaceAuthorityScopeKey(
                repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: layout),
                repositoryRelativeRootPrefix: prefix
            )
            let captureToken: GitWorkspaceAuthorityCaptureToken
            switch await workspaceStateAuthority.beginCollection(scopeKey: scope) {
            case let .success(value): captureToken = value
            case .failure:
                await workspaceStateAuthority.releaseMetadataObservation(observation)
                return nil
            }
            let captured = try await workspaceAuthoritySnapshot(in: layout, prefix: prefix)
            guard Self.canonicalPathSet(captured.metadata.resolvedExternalAuthorityPaths) == discoveredExternalPaths,
                  await workspaceStateAuthority.metadataObservationIsCurrent(
                      observation,
                      for: layout,
                      additionalAuthorityPaths: captured.metadata.resolvedExternalAuthorityPaths,
                      expectedAcceptedWatermark: captureToken.acceptedMetadataWatermark
                  )
            else {
                await workspaceStateAuthority.releaseMetadataObservation(observation)
                return nil
            }
            let lease: GitWorkspaceAuthorityLease
            switch await workspaceStateAuthority.install(captured.snapshot, capturedUsing: captureToken) {
            case let .success(value): lease = value
            case .failure:
                await workspaceStateAuthority.releaseMetadataObservation(observation)
                return nil
            }
            guard let snapshot = await workspaceStateAuthority.reusableSnapshot(compatibleWith: captured.snapshot) else {
                await workspaceStateAuthority.releaseMetadataObservation(observation)
                return nil
            }
            replacementObservation = nil
            guard await workspaceStateAuthority.admitReusableSnapshot(
                snapshot,
                capturedUsing: lease,
                observationToken: observation
            ) else { return nil }
            return (lease, snapshot)
        } catch {
            if let discoveryObservation {
                await workspaceStateAuthority.releaseMetadataObservation(discoveryObservation)
            }
            if let replacementObservation {
                await workspaceStateAuthority.releaseMetadataObservation(replacementObservation)
            }
            throw error
        }
    }

    /// Collects a point-in-time target authority only through the authority's
    /// generation/watermark conditional install. The observation is held until
    /// the installed lease is proven current, then discarded with the immutable
    /// snapshot; milestone 8B never serves from this evidence.
    func generationFencedAuthoritySnapshot(
        layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix
    ) async throws -> GitWorkspaceAuthoritySnapshot {
        let fence = try await pendingInitializationAuthorityFence(
            layout: layout,
            prefix: prefix
        )
        await workspaceStateAuthority.retireEphemeralAuthorityLease(
            fence.lease,
            observationToken: fence.metadataObservationToken
        )
        return fence.snapshot
    }

    /// Captures exact target authority while retaining every metadata path
    /// (including dynamically resolved external policy files) needed to prove
    /// the lease current through hidden root preparation and publication.
    func pendingInitializationAuthorityFence(
        layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix
    ) async throws -> GitWorkspacePendingInitializationAuthorityFence {
        try await capturePendingInitializationAuthorityFence(
            layout: layout,
            prefix: prefix,
            revalidationUsed: false
        )
    }

    /// Returns without issuing Git commands while the retained lease is
    /// current. Once invalidated, all already accepted signals coalesce into
    /// one generation-fenced recapture. A changed snapshot, an event during
    /// recapture, or any later invalidation fails closed and releases the
    /// consumed fence. No timer or polling path exists.
    func validateOrRevalidatePendingInitializationAuthorityFence(
        _ fence: GitWorkspacePendingInitializationAuthorityFence
    ) async throws -> GitWorkspacePendingInitializationAuthorityFence {
        switch await workspaceStateAuthority.pendingInitializationFenceDecision(fence) {
        case .current:
            return fence
        case .fallback:
            await workspaceStateAuthority.releasePendingInitializationAuthorityFence(fence)
            throw GitWorkspaceAuthorityUnavailableReason.superseded
        case let .revalidationRequired(latestAcceptedMetadataWatermark):
            do {
                let replacement = try await capturePendingInitializationAuthorityFence(
                    layout: fence.targetLayout,
                    prefix: fence.repositoryRelativeRootPrefix,
                    revalidationUsed: true
                )
                guard replacement.snapshot == fence.snapshot,
                      replacement.acceptedMetadataWatermark >= latestAcceptedMetadataWatermark,
                      await workspaceStateAuthority.pendingInitializationAuthorityFenceIsCurrent(replacement)
                else {
                    await workspaceStateAuthority.releasePendingInitializationAuthorityFence(replacement)
                    throw GitWorkspaceAuthorityUnavailableReason.superseded
                }
                await workspaceStateAuthority.releasePendingInitializationAuthorityFence(fence)
                return replacement
            } catch {
                await workspaceStateAuthority.releasePendingInitializationAuthorityFence(fence)
                throw error
            }
        }
    }

    func releasePendingInitializationAuthorityFence(
        _ fence: GitWorkspacePendingInitializationAuthorityFence
    ) async {
        await workspaceStateAuthority.releasePendingInitializationAuthorityFence(fence)
    }

    /// Captures fresh published-root authority after an event-driven
    /// invalidation. Unlike pending bootstrap's one-shot revalidation budget,
    /// each completed published mutation receives a new exact fence; callers
    /// decide whether an unchanged snapshot permits targeted reuse or requires
    /// one authoritative filesystem reconciliation.
    func recapturePublishedInitializationAuthorityFence(
        replacing fence: GitWorkspacePendingInitializationAuthorityFence
    ) async throws -> GitWorkspacePendingInitializationAuthorityFence {
        try await capturePendingInitializationAuthorityFence(
            layout: fence.targetLayout,
            prefix: fence.repositoryRelativeRootPrefix,
            revalidationUsed: false
        )
    }

    private func capturePendingInitializationAuthorityFence(
        layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        revalidationUsed: Bool
    ) async throws -> GitWorkspacePendingInitializationAuthorityFence {
        let scope = GitWorkspaceAuthorityScopeKey(
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: layout),
            repositoryRelativeRootPrefix: prefix
        )
        // Refuse before the first Git command. This catches a newly materialized
        // linked-worktree key through the common-directory mutation fence.
        if let reason = await workspaceStateAuthority.collectionMutationFenceReason(
            for: scope.repositoryKey
        ) {
            throw reason
        }

        var discoveryObservation: GitWorkspaceMetadataMonitor.RetainToken?
        var replacementObservation: GitWorkspaceMetadataMonitor.RetainToken?
        do {
            let discoveryToken = try await workspaceStateAuthority.retainMetadataObservation(for: layout)
            discoveryObservation = discoveryToken
            let discovery = try await workspaceAuthoritySnapshot(in: layout, prefix: prefix)
            let discoveredExternalPaths = Self.canonicalPathSet(
                discovery.metadata.resolvedExternalAuthorityPaths
            )
            let observation = try await workspaceStateAuthority.retainMetadataObservation(
                for: layout,
                additionalAuthorityPaths: discovery.metadata.resolvedExternalAuthorityPaths
            )
            replacementObservation = observation
            await workspaceStateAuthority.releaseMetadataObservation(discoveryToken)
            discoveryObservation = nil

            let scope = GitWorkspaceAuthorityScopeKey(
                repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: layout),
                repositoryRelativeRootPrefix: prefix
            )
            let captureToken: GitWorkspaceAuthorityCaptureToken
            switch await workspaceStateAuthority.beginCollection(scopeKey: scope) {
            case let .success(value): captureToken = value
            case let .failure(reason): throw reason
            }
            let captured = try await workspaceAuthoritySnapshot(in: layout, prefix: prefix)
            guard Self.canonicalPathSet(captured.metadata.resolvedExternalAuthorityPaths) == discoveredExternalPaths,
                  await workspaceStateAuthority.metadataObservationIsCurrent(
                      observation,
                      for: layout,
                      additionalAuthorityPaths: captured.metadata.resolvedExternalAuthorityPaths,
                      expectedAcceptedWatermark: captureToken.acceptedMetadataWatermark
                  )
            else { throw GitWorkspaceAuthorityUnavailableReason.invalidatedDuringCollection }
            let lease: GitWorkspaceAuthorityLease
            switch await workspaceStateAuthority.install(captured.snapshot, capturedUsing: captureToken) {
            case let .success(value): lease = value
            case let .failure(reason): throw reason
            }
            guard await workspaceStateAuthority.isCurrent(lease) else {
                throw GitWorkspaceAuthorityUnavailableReason.invalidatedDuringCollection
            }
            replacementObservation = nil
            return GitWorkspacePendingInitializationAuthorityFence(
                snapshot: lease.snapshot,
                lease: lease,
                metadataObservationToken: observation,
                acceptedMetadataWatermark: lease.acceptedMetadataWatermark,
                targetLayout: layout,
                repositoryRelativeRootPrefix: prefix,
                additionalAuthorityPaths: captured.metadata.resolvedExternalAuthorityPaths,
                revalidationUsed: revalidationUsed
            )
        } catch {
            if let discoveryObservation {
                await workspaceStateAuthority.releaseMetadataObservation(discoveryObservation)
            }
            if let replacementObservation {
                await workspaceStateAuthority.releaseMetadataObservation(replacementObservation)
            }
            throw error
        }
    }

    private func currentAuthorityLease(
        layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix
    ) async throws -> GitWorkspaceAuthorityLease {
        switch await workspaceStateAuthority.currentLease(
            for: GitWorkspaceAuthorityRepositoryKey(layout: layout),
            prefix: prefix
        ) {
        case let .success(lease): return lease
        case let .failure(reason): throw reason
        }
    }

    private func copyWorktreeIncludeFilesIfRequested(
        request: GitWorktreeCreateRequest,
        sourceRepoURL: URL,
        destinationURL: URL
    ) async -> GitWorktreeIncludeCopyResult? {
        guard request.copyWorktreeIncludeFiles,
              let appManagedContainer = request.appManagedContainer,
              Self.isPath(destinationURL, equalToOrInside: appManagedContainer)
        else { return nil }
        let includeURL = sourceRepoURL.appendingPathComponent(".worktreeinclude", isDirectory: false)
        guard FileManager.default.fileExists(atPath: includeURL.path) else { return nil }

        do {
            let (stdout, stderr, exitCode) = try await runGit(
                ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"],
                at: sourceRepoURL
            )
            guard exitCode == 0 else {
                return GitWorktreeIncludeCopyResult(
                    copiedCount: 0,
                    matchedCount: 0,
                    errorSummaries: ["could not list Git-ignored files: \(stderr)"]
                )
            }
            return GitWorktreeIncludeCopier.copyIncludedFiles(
                from: sourceRepoURL,
                to: destinationURL,
                ignoredFilesNULOutput: stdout,
                appManagedContainer: appManagedContainer
            )
        } catch {
            return GitWorktreeIncludeCopyResult(
                copiedCount: 0,
                matchedCount: 0,
                errorSummaries: ["could not copy .worktreeinclude files: \(error.localizedDescription)"]
            )
        }
    }

    private static func canonicalPathSet(_ paths: [URL]) -> Set<String> {
        Set(paths.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
    }

    private static func isPath(_ path: URL, equalToOrInside root: URL) -> Bool {
        StandardizedPath.isDescendant(
            StandardizedPath.absolute(path.path),
            of: StandardizedPath.absolute(root.path)
        )
    }

    // MARK: - Worktree Merge Primitives

    func getMergeBase(sourceHead: String, targetHead: String, at repoURL: URL) async throws -> String {
        let (stdout, stderr, exitCode) = try await runGit(
            ["merge-base", targetHead, sourceHead],
            at: repoURL
        )
        guard exitCode == 0 else {
            throw GitError(message: "git merge-base failed: \(stderr)")
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isAncestor(_ ancestor: String, of descendant: String, at repoURL: URL) async throws -> Bool {
        let (_, stderr, exitCode) = try await runGit(
            ["merge-base", "--is-ancestor", ancestor, descendant],
            at: repoURL
        )
        if exitCode == 0 { return true }
        if exitCode == 1 { return false }
        throw GitError(message: "git merge-base --is-ancestor failed: \(stderr)")
    }

    func inspectMergeState(at repoURL: URL) async throws -> GitWorktreeMergeState {
        let layout = try requireLayout(for: repoURL)
        let mergeHeadURL = layout.gitDir.appendingPathComponent("MERGE_HEAD")
        let mergeHead: String? = if FileManager.default.fileExists(atPath: mergeHeadURL.path) {
            try String(contentsOf: mergeHeadURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            nil
        }
        let conflicts = try await getUnmergedConflictFiles(at: repoURL)
        return GitWorktreeMergeState(
            inProgress: mergeHead?.isEmpty == false,
            mergeHead: mergeHead?.isEmpty == false ? mergeHead : nil,
            conflictFiles: conflicts
        )
    }

    func predictWorktreeMergeConflicts(
        sourceHead: String,
        targetHead: String,
        at repoURL: URL
    ) async throws -> GitWorktreeMergeConflictPrediction {
        let (stdout, stderr, exitCode) = try await runGit(
            ["merge-tree", "--write-tree", "--name-only", "--no-messages", targetHead, sourceHead],
            at: repoURL
        )

        if exitCode == 0 {
            return GitWorktreeMergeConflictPrediction(status: .clean)
        }
        if exitCode == 1 {
            return GitWorktreeMergeConflictPrediction(
                status: .conflicts,
                files: parseMergeTreeConflictFiles(stdout),
                message: stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "git merge-tree predicted conflicts" : nil
            )
        }

        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "git merge-tree conflict prediction unavailable"
            : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return GitWorktreeMergeConflictPrediction(status: .unavailable, message: message)
    }

    func getWorktreeMergeSummary(
        sourceHead: String,
        targetHead: String,
        mergeBase: String,
        at repoURL: URL,
        detectRenames: Bool = false
    ) async throws -> GitWorktreeMergeSummary {
        let sourceOnlyRevspec = "\(targetHead)..\(sourceHead)"
        let previewDiffRevspec = "\(mergeBase)..\(sourceHead)"
        let (commitCountOut, commitCountErr, commitCountExit) = try await runGit(
            ["rev-list", "--count", sourceOnlyRevspec],
            at: repoURL
        )
        guard commitCountExit == 0 else {
            throw GitError(message: "git rev-list --count failed: \(commitCountErr)")
        }
        let commits = Int(commitCountOut.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let files = try await getChangedFilesStats(
            compare: .revspec(previewDiffRevspec),
            includeUntrackedWhenApplicable: false,
            detectRenames: detectRenames,
            at: repoURL
        )
        return GitWorktreeMergeSummary(
            commits: commits,
            files: files.count,
            insertions: files.reduce(0) { $0 + ($1.additions ?? 0) },
            deletions: files.reduce(0) { $0 + ($1.deletions ?? 0) }
        )
    }

    func makeWorktreeMergeVisualization(
        source: GitWorktreeMergeEndpoint,
        target: GitWorktreeMergeEndpoint,
        summary: GitWorktreeMergeSummary,
        graphLimit: Int,
        at repoURL: URL
    ) async -> String {
        let header = """
        target \(target.branch ?? target.displayName)      \(target.shortHead)  \(target.path)
           \\
            +-- merge preview: \(summary.commits) commits, \(summary.files) files (+\(summary.insertions) -\(summary.deletions))
           /
        source \(source.branch ?? source.displayName)      \(source.shortHead)  \(source.path)
        """
        let limit = max(0, min(graphLimit, 80))
        guard limit > 0 else { return header }
        let graphRange = "\(target.head)..\(source.head)"
        do {
            let (stdout, _, exitCode) = try await runGit(
                ["log", "--graph", "--decorate", "--oneline", "--color=never", "-n", "\(limit)", graphRange],
                at: repoURL
            )
            let graph = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard exitCode == 0, !graph.isEmpty else { return header }
            return header + "\n\n" + graph
        } catch {
            return header
        }
    }

    func inspectWorktreeMerge(_ request: GitWorktreeMergeInspectRequest) async throws -> GitWorktreeMergeInspection {
        let sourceURL = request.source.url
        let targetURL = request.target.url
        try await validateCurrentEndpoint(request.source, label: "Source")
        try await validateCurrentEndpoint(request.target, label: "Target")
        let mergeBase = try await getMergeBase(
            sourceHead: request.source.head,
            targetHead: request.target.head,
            at: targetURL
        )
        async let sourceStatus = getWorkingStatus(at: sourceURL)
        async let targetStatus = getWorkingStatus(at: targetURL)
        async let sourceMergeState = inspectMergeState(at: sourceURL)
        async let targetMergeState = inspectMergeState(at: targetURL)
        async let sourceFingerprint = getStatusFingerprint(at: sourceURL, baseRef: "HEAD")
        async let targetFingerprint = getStatusFingerprint(at: targetURL, baseRef: "HEAD")
        async let conflictPrediction = predictWorktreeMergeConflicts(
            sourceHead: request.source.head,
            targetHead: request.target.head,
            at: targetURL
        )
        async let summary = getWorktreeMergeSummary(
            sourceHead: request.source.head,
            targetHead: request.target.head,
            mergeBase: mergeBase,
            at: targetURL
        )
        async let sourceAlreadyMerged = isAncestor(request.source.head, of: request.target.head, at: targetURL)

        var blockers: [GitWorktreeMergeBlocker] = []
        if request.source.repositoryID != request.target.repositoryID {
            blockers.append(.init(code: .differentRepository, message: "Source and target worktrees are from different repositories."))
        }
        if request.source.worktreeID == request.target.worktreeID {
            blockers.append(.init(code: .sameWorktree, message: "Source and target worktrees are the same worktree."))
        }

        let resolvedSourceStatus = try await sourceStatus
        let resolvedTargetStatus = try await targetStatus
        let resolvedSourceMergeState = try await sourceMergeState
        let resolvedTargetMergeState = try await targetMergeState
        if !resolvedSourceStatus.isClean {
            blockers.append(.init(
                code: .sourceDirty,
                message: "Source worktree must be clean and committed before merge.",
                paths: resolvedSourceStatus.changedPaths
            ))
        }
        if !resolvedTargetStatus.isClean {
            blockers.append(.init(
                code: .targetDirty,
                message: "Target worktree must be clean before merge.",
                paths: resolvedTargetStatus.changedPaths
            ))
        }
        if resolvedSourceMergeState.inProgress {
            blockers.append(.init(code: .sourceMergeInProgress, message: "Source worktree already has a merge in progress."))
        }
        if resolvedTargetMergeState.inProgress {
            blockers.append(.init(code: .targetMergeInProgress, message: "Target worktree already has a merge in progress."))
        }
        if try await sourceAlreadyMerged {
            blockers.append(.init(code: .noSourceCommits, message: "Source HEAD is already reachable from the target HEAD."))
        }

        let resolvedSummary = try await summary
        let visualization = await makeWorktreeMergeVisualization(
            source: request.source,
            target: request.target,
            summary: resolvedSummary,
            graphLimit: request.graphLimit,
            at: targetURL
        )

        return try await GitWorktreeMergeInspection(
            source: request.source,
            target: request.target,
            mergeBase: mergeBase,
            sourceHead: request.source.head,
            targetHead: request.target.head,
            sourceFingerprint: sourceFingerprint,
            targetFingerprint: targetFingerprint,
            blockers: blockers,
            conflictPrediction: conflictPrediction,
            summary: resolvedSummary,
            visualization: visualization
        )
    }

    func withWorktreeMergeAdvisoryLock<T: Sendable>(
        at repoURL: URL,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let commonGitDir = try requireLayout(for: repoURL).commonDir.standardizedFileURL.path
        return try await worktreeMutationCoordinator.withLock(key: commonGitDir) {
            try await GitWorktreeMergeAdvisoryLock.withLock(commonGitDir: commonGitDir, operation: operation)
        }
    }

    func applyNoCommitWorktreeMerge(
        sourceHead: String,
        at targetRepoURL: URL
    ) async throws -> GitWorktreeMergeState {
        try await withWorkspaceAuthorityMutation(at: targetRepoURL, kind: .mergeApply) {
            try await withWorktreeMergeAdvisoryLock(at: targetRepoURL) { [weak self] in
                guard let self else {
                    throw GitError(message: "git service was released before merge apply")
                }
                let (_, stderr, exitCode) = try await runGit(
                    ["merge", "--no-ff", "--no-commit", "--no-edit", sourceHead],
                    at: targetRepoURL
                )
                if exitCode == 0 || exitCode == 1 {
                    return try await inspectMergeState(at: targetRepoURL)
                }
                throw GitError(message: "git merge --no-commit failed: \(stderr)")
            }
        }
    }

    func applyAndCommitWorktreeMerge(
        sourceHead: String,
        message: String,
        at targetRepoURL: URL
    ) async throws -> (state: GitWorktreeMergeState, commit: String?) {
        try await withWorkspaceAuthorityMutation(at: targetRepoURL, kind: .mergeApply) {
            try await withWorktreeMergeAdvisoryLock(at: targetRepoURL) { [weak self] in
                guard let self else {
                    throw GitError(message: "git service was released before merge apply")
                }
                let (_, stderr, exitCode) = try await runGit(
                    ["merge", "--no-ff", "--no-commit", "--no-edit", sourceHead],
                    at: targetRepoURL
                )
                if exitCode == 0 || exitCode == 1 {
                    let state = try await inspectMergeState(at: targetRepoURL)
                    guard state.conflictFiles.isEmpty else { return (state: state, commit: nil) }
                    guard state.inProgress else { return (state: state, commit: nil) }
                    let commit = try await commitCurrentMergeWithoutLock(message: message, at: targetRepoURL)
                    return (state: state, commit: commit)
                }
                throw GitError(message: "git merge --no-commit failed: \(stderr)")
            }
        }
    }

    func commitWorktreeMerge(message: String, at targetRepoURL: URL) async throws -> String {
        try await withWorkspaceAuthorityMutation(at: targetRepoURL, kind: .mergeCommit) {
            try await withWorktreeMergeAdvisoryLock(at: targetRepoURL) { [weak self] in
                guard let self else {
                    throw GitError(message: "git service was released before merge commit")
                }
                return try await commitCurrentMergeWithoutLock(message: message, at: targetRepoURL)
            }
        }
    }

    func continueWorktreeMerge(message: String, at targetRepoURL: URL) async throws -> String {
        try await withWorkspaceAuthorityMutation(at: targetRepoURL, kind: .mergeContinue) {
            try await withWorktreeMergeAdvisoryLock(at: targetRepoURL) { [weak self] in
                guard let self else {
                    throw GitError(message: "git service was released before merge continue")
                }
                return try await commitCurrentMergeWithoutLock(message: message, at: targetRepoURL)
            }
        }
    }

    func abortWorktreeMerge(at targetRepoURL: URL) async throws -> Bool {
        let state = try await inspectMergeState(at: targetRepoURL)
        guard state.inProgress else { return false }
        return try await withWorkspaceAuthorityMutation(at: targetRepoURL, kind: .mergeAbort) {
            try await withWorktreeMergeAdvisoryLock(at: targetRepoURL) { [weak self] in
                guard let self else {
                    throw GitError(message: "git service was released before merge abort")
                }
                let (_, stderr, exitCode) = try await runGit(["merge", "--abort"], at: targetRepoURL)
                guard exitCode == 0 else {
                    throw GitError(message: "git merge --abort failed: \(stderr)")
                }
                return true
            }
        }
    }

    private func commitCurrentMergeWithoutLock(message: String, at targetRepoURL: URL) async throws -> String {
        let state = try await inspectMergeState(at: targetRepoURL)
        guard state.inProgress else {
            throw GitError(message: "No Git merge is in progress at \(targetRepoURL.path)")
        }
        guard state.conflictFiles.isEmpty else {
            throw GitError(message: "Cannot commit merge with unresolved conflicts: \(state.conflictFiles.joined(separator: ", "))")
        }
        let (_, stderr, exitCode) = try await runGit(
            ["commit", "--no-gpg-sign", "-m", message],
            at: targetRepoURL
        )
        guard exitCode == 0 else {
            throw GitError(message: "git commit failed: \(stderr)")
        }
        return try await getHeadSHA(at: targetRepoURL)
    }

    private func requireLayout(for repoURL: URL) throws -> GitRepositoryLayout {
        guard let layout = getLayout(for: repoURL) else {
            throw GitError(message: "Not a Git worktree: \(repoURL.path)")
        }
        return layout
    }

    private func validateCurrentEndpoint(_ endpoint: GitWorktreeMergeEndpoint, label: String) async throws {
        let worktrees = try await listWorktrees(at: endpoint.url)
        let standardizedPath = endpoint.url.standardizedFileURL.path
        guard let current = worktrees.first(where: { $0.path == standardizedPath }) else {
            throw GitError(message: "\(label) worktree is unavailable: \(endpoint.path)")
        }
        guard current.worktreeID == endpoint.worktreeID else {
            throw GitError(message: "\(label) worktree identity changed since it was resolved: \(endpoint.path)")
        }
        guard current.repository.repositoryID == endpoint.repositoryID else {
            throw GitError(message: "\(label) repository identity changed since it was resolved: \(endpoint.path)")
        }
        guard current.head == endpoint.head else {
            throw GitError(message: "\(label) worktree HEAD changed since it was resolved: \(endpoint.path)")
        }
    }

    private func getUnmergedConflictFiles(at repoURL: URL) async throws -> [String] {
        let (stdout, stderr, exitCode) = try await runGit(
            ["diff", "--name-only", "--diff-filter=U", "-z"],
            at: repoURL
        )
        guard exitCode == 0 || exitCode == 1 else {
            throw GitError(message: "git diff --diff-filter=U failed: \(stderr)")
        }
        return stdout.split(separator: "\0", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
            .sorted()
    }

    private func parseMergeTreeConflictFiles(_ stdout: String) -> [String] {
        stdout.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isHexObjectID($0) }
            .sorted()
    }

    private func isHexObjectID(_ text: String) -> Bool {
        guard text.count >= 40 else { return false }
        return text.allSatisfy { character in
            character.isNumber || ("a" ... "f").contains(character.lowercased())
        }
    }

    /// Get uncommitted modified files in the repository
    func getUncommittedFiles(at repoURL: URL) async throws -> [UncommittedFile] {
        let (stdout, stderr, exitCode) = try await runGit(
            ["status", "--porcelain", "--untracked-files=all"],
            at: repoURL
        )

        guard exitCode == 0 else {
            throw GitError(message: "git status failed: \(stderr)")
        }

        return parseStatusOutput(stdout)
    }

    /// Get the current HEAD SHA for the repository.
    func getHeadSHA(at repoURL: URL) async throws -> String {
        let (stdout, stderr, exitCode) = try await runGit(
            ["rev-parse", "HEAD"],
            at: repoURL
        )
        guard exitCode == 0 else {
            throw GitError(message: "git rev-parse HEAD failed: \(stderr)")
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolve any ref (branch, tag, commit-ish) to a SHA.
    func getRefSHA(at repoURL: URL, ref: String) async throws -> String {
        let (stdout, stderr, exitCode) = try await runGit(
            ["rev-parse", ref],
            at: repoURL
        )
        guard exitCode == 0 else {
            throw GitError(message: "git rev-parse \(ref) failed: \(stderr)")
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Get git status output in porcelain format with NUL delimiters.
    func getStatusPorcelainZ(at repoURL: URL) async throws -> Data {
        let (stdout, stderr, exitCode) = try await runGit(
            ["status", "--porcelain", "-z", "--untracked-files=all"],
            at: repoURL
        )
        guard exitCode == 0 else {
            throw GitError(message: "git status --porcelain -z failed: \(stderr)")
        }
        return Data(stdout.utf8)
    }

    /// Get a status fingerprint for staleness detection.
    func getStatusFingerprint(at repoURL: URL, baseRef: String = "HEAD") async throws -> GitDiffFingerprint {
        let headSHA = try await getHeadSHA(at: repoURL)
        let baseRefSHA = if baseRef == "HEAD" {
            headSHA
        } else {
            try await getRefSHA(at: repoURL, ref: baseRef)
        }
        let statusData = try await getStatusPorcelainZ(at: repoURL)
        var fingerprintData = Data()
        fingerprintData.append(statusData)
        fingerprintData.append(0)
        fingerprintData.append(Data(baseRefSHA.utf8))
        fingerprintData.append(0)

        // Include per-path size/mtime to invalidate cache when modified file content changes.
        let paths = MCPToolWorkCountDiagnostics.measureGitParse {
            changedPathsFromPorcelainZ(statusData)
        }
        let fm = FileManager.default
        for path in Set(paths).sorted() {
            fingerprintData.append(Data(path.utf8))
            fingerprintData.append(0)
            let absPath = repoURL.appendingPathComponent(path).path
            if let attrs = try? fm.attributesOfItem(atPath: absPath) {
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
                fingerprintData.append(Data("\(size)\t\(mtime)".utf8))
            } else {
                fingerprintData.append(Data("missing".utf8))
            }
            fingerprintData.append(0)
        }
        let statusHash = MCPToolWorkCountDiagnostics.measureGitParse {
            sha256Hex(fingerprintData)
        }
        return GitDiffFingerprint(
            headSHA: headSHA,
            baseRef: baseRef,
            statusHash: statusHash,
            generatedAt: Date()
        )
    }

    private func changedPathsFromPorcelainZ(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return []
        }

        let entries = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var paths: [String] = []
        var i = 0
        while i < entries.count {
            let entry = entries[i]
            guard entry.count >= 3 else {
                i += 1
                continue
            }

            let indexStatus = entry[entry.startIndex]
            let pathStart = entry.index(entry.startIndex, offsetBy: 3)
            let path1 = String(entry[pathStart...])
            guard !path1.isEmpty else {
                i += 1
                continue
            }

            // Renames/copies include a second path after NUL; prefer destination.
            if indexStatus == "R" || indexStatus == "C" {
                if i + 1 < entries.count, !entries[i + 1].isEmpty {
                    paths.append(entries[i + 1])
                } else {
                    paths.append(path1)
                }
                i += 2
                continue
            }

            paths.append(path1)
            i += 1
        }

        return paths
    }

    /// Get diff between specified branch and working tree
    func getDiff(from branch: String, at repoURL: URL) async throws -> String {
        // Compare branch to working tree to include all uncommitted changes
        let (stdout, stderr, exitCode) = try await runGit(
            ["diff", branch],
            at: repoURL
        )

        guard exitCode == 0 || exitCode == 1 else {
            throw GitError(message: "git diff failed: \(stderr)")
        }

        return stdout
    }

    /// Get diff between specified branch and working tree for specific files
    func getDiff(from branch: String, for files: [String], at repoURL: URL) async throws -> String {
        // Prefer normal argv for smaller file sets (compatibility),
        // use pathspec-from-file when args are large, and chunk as a fallback.
        let maxChunk = 3000
        let pathspecByteLimit = 128 * 1024
        let pathspecBytes = files.reduce(0) { $0 + $1.lengthOfBytes(using: .utf8) + 1 }

        if !files.isEmpty, pathspecBytes >= pathspecByteLimit {
            do {
                let stdin = makePathspecStdinData(files)
                let args = ["diff", "--pathspec-from-file=-", "--pathspec-file-nul", branch]
                let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL, stdin: stdin)
                guard exitCode == 0 || exitCode == 1 else {
                    throw GitError(message: "git diff failed: \(stderr)")
                }
                return stdout
            } catch {
                if !shouldFallbackFromPathspecError(error) {
                    throw error
                }
            }
        }

        if files.count <= maxChunk {
            var args = ["diff", branch, "--"]
            args.append(contentsOf: files)
            let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
            guard exitCode == 0 || exitCode == 1 else {
                throw GitError(message: "git diff failed: \(stderr)")
            }
            return stdout
        }

        var combined = ""
        for chunk in files.chunked(into: maxChunk) {
            var args = ["diff", branch, "--"]
            args.append(contentsOf: chunk)
            let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
            guard exitCode == 0 || exitCode == 1 else {
                throw GitError(message: "git diff failed: \(stderr)")
            }
            if !stdout.isEmpty {
                combined += stdout
                if !combined.hasSuffix("\n") { combined += "\n" }
            }
        }
        return combined
    }

    /// Split a unified diff output into per-file diff strings.
    static func splitUnifiedDiffByFile(_ diff: String) -> [String: String] {
        guard !diff.isEmpty else { return [:] }
        let endsWithNewline = diff.hasSuffix("\n")
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [String: String] = [:]
        var currentBlock: [String] = []

        for line in lines {
            if line.hasPrefix("diff --git ") {
                finalizeUnifiedDiffBlock(currentBlock, endsWithNewline: endsWithNewline, into: &result)
                currentBlock = [line]
                continue
            }
            guard !currentBlock.isEmpty else { continue }
            currentBlock.append(line)
        }

        finalizeUnifiedDiffBlock(currentBlock, endsWithNewline: endsWithNewline, into: &result)
        return result
    }

    private static func finalizeUnifiedDiffBlock(
        _ block: [String],
        endsWithNewline: Bool,
        into result: inout [String: String]
    ) {
        guard !block.isEmpty, let path = canonicalPath(forUnifiedDiffBlock: block) else { return }
        var text = block.joined(separator: "\n")
        if endsWithNewline, !text.hasSuffix("\n") {
            text += "\n"
        }
        result[path] = text
    }

    private struct PatchHeaderPaths {
        let oldPath: String
        let newPath: String
        let prefixes: Set<String>
    }

    private static func canonicalPath(forUnifiedDiffBlock block: [String]) -> String? {
        var headerPaths: PatchHeaderPaths?
        var renameToPath: String?
        var copyToPath: String?
        var plusPath: String?
        var minusPath: String?

        for line in block {
            if line.hasPrefix("diff --git ") {
                headerPaths = parseDiffGitHeaderPaths(line)
                continue
            }
            if line.hasPrefix("rename to ") {
                renameToPath = parseGitPathRemainder(String(line.dropFirst("rename to ".count)))
                continue
            }
            if line.hasPrefix("copy to ") {
                copyToPath = parseGitPathRemainder(String(line.dropFirst("copy to ".count)))
                continue
            }
            if line.hasPrefix("+++ ") {
                plusPath = parseGitPathRemainder(String(line.dropFirst("+++ ".count))).flatMap {
                    normalizePatchHeaderPath($0, stripping: headerPaths?.prefixes)
                }
                continue
            }
            if line.hasPrefix("--- ") {
                minusPath = parseGitPathRemainder(String(line.dropFirst("--- ".count))).flatMap {
                    normalizePatchHeaderPath($0, stripping: headerPaths?.prefixes)
                }
                continue
            }
            if line.hasPrefix("@@") {
                break
            }
        }

        return renameToPath ?? copyToPath ?? plusPath ?? minusPath ?? headerPaths?.newPath ?? headerPaths?.oldPath
    }

    private static func parseDiffGitHeaderPaths(_ line: String) -> PatchHeaderPaths? {
        let prefix = "diff --git "
        guard line.hasPrefix(prefix) else { return nil }
        let remainder = String(line.dropFirst(prefix.count))
        let tokens = parseDiffGitTokens(remainder)
        let prefixes = patchHeaderPrefixes(oldRawPath: tokens.first, newRawPath: tokens.dropFirst().first)
        guard tokens.count >= 2,
              let oldPath = normalizePatchHeaderPath(tokens[0], stripping: prefixes),
              let newPath = normalizePatchHeaderPath(tokens[1], stripping: prefixes)
        else {
            return nil
        }
        return PatchHeaderPaths(oldPath: oldPath, newPath: newPath, prefixes: prefixes)
    }

    private static func parseGitPathRemainder(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.first == "\"" {
            return parseDiffGitTokens(trimmed).first
        }
        return trimmed
    }

    private static func normalizePatchHeaderPath(_ rawPath: String, stripping prefixes: Set<String>? = nil) -> String? {
        var normalized = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != "/dev/null" else { return nil }
        let prefixes = prefixes ?? defaultPatchHeaderPrefixes
        if prefixes.contains(String(normalized.prefix(2))) {
            normalized = String(normalized.dropFirst(2))
        }
        if normalized.hasPrefix("./") {
            normalized = String(normalized.dropFirst(2))
        }
        return normalized.isEmpty ? nil : normalized
    }

    private static let defaultPatchHeaderPrefixes: Set<String> = ["a/", "b/"]

    private static let knownPatchHeaderPrefixPairs: [(old: String, new: String)] = [
        ("a/", "b/"),
        ("c/", "w/"),
        ("i/", "w/"),
        ("o/", "w/"),
        ("1/", "2/")
    ]

    private static func patchHeaderPrefixes(oldRawPath: String?, newRawPath: String?) -> Set<String> {
        guard let oldRawPath,
              let newRawPath,
              let oldPrefix = patchHeaderPrefix(in: oldRawPath),
              let newPrefix = patchHeaderPrefix(in: newRawPath),
              knownPatchHeaderPrefixPairs.contains(where: { $0.old == oldPrefix && $0.new == newPrefix })
        else {
            return defaultPatchHeaderPrefixes
        }
        return [oldPrefix, newPrefix]
    }

    private static func patchHeaderPrefix(in rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        let prefix = String(trimmed.prefix(2))
        guard knownPatchHeaderPrefixPairs.contains(where: { $0.old == prefix || $0.new == prefix }) else {
            return nil
        }
        return prefix
    }

    private static func parseDiffGitTokens(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var isQuoted = false
        var idx = input.startIndex

        while idx < input.endIndex {
            let ch = input[idx]
            if isQuoted {
                if ch == "\\" {
                    let next = input.index(after: idx)
                    if next >= input.endIndex { break }
                    let escaped = input[next]
                    if let octal = parseOctalEscape(escaped, input: input, start: next) {
                        current.append(octal.character)
                        idx = octal.nextIndex
                        continue
                    }
                    current.append(unescapeGitDiffCharacter(escaped))
                    idx = input.index(after: next)
                    continue
                }
                if ch == "\"" {
                    isQuoted = false
                    idx = input.index(after: idx)
                    continue
                }
                current.append(ch)
                idx = input.index(after: idx)
                continue
            }

            if ch == "\"" {
                isQuoted = true
                idx = input.index(after: idx)
                continue
            }
            if ch == " " {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                idx = input.index(after: idx)
                continue
            }
            current.append(ch)
            idx = input.index(after: idx)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func unescapeGitDiffCharacter(_ ch: Character) -> Character {
        switch ch {
        case "n": "\n"
        case "t": "\t"
        case "r": "\r"
        case "\"": "\""
        case "\\": "\\"
        default: ch
        }
    }

    private static func parseOctalEscape(
        _ first: Character,
        input: String,
        start: String.Index
    ) -> (character: Character, nextIndex: String.Index)? {
        guard ("0" ... "7").contains(first) else { return nil }
        var digits = String(first)
        var nextIndex = input.index(after: start)
        while digits.count < 3, nextIndex < input.endIndex {
            let ch = input[nextIndex]
            guard ("0" ... "7").contains(ch) else { break }
            digits.append(ch)
            nextIndex = input.index(after: nextIndex)
        }
        guard let scalar = UInt8(digits, radix: 8) else { return nil }
        let scalarValue = UnicodeScalar(scalar)
        return (Character(scalarValue), nextIndex)
    }

    /// Get untracked-file patches in one no-index Git process.
    func getUntrackedDiff(for files: [String], contextLines: Int, at repoURL: URL) async throws -> String {
        guard !files.isEmpty else { return "" }

        let fileManager = FileManager.default
        let batchRoot = fileManager.temporaryDirectory
            .appendingPathComponent("RepoPrompt-GitUntrackedDiff-\(UUID().uuidString)", isDirectory: true)
        let emptyRoot = batchRoot.appendingPathComponent("empty", isDirectory: true)
        let mirrorRoot = batchRoot.appendingPathComponent("mirror", isDirectory: true)
        try fileManager.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: mirrorRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: batchRoot) }

        let standardizedRepo = repoURL.standardizedFileURL.path
        let repoPrefix = standardizedRepo.hasSuffix("/") ? standardizedRepo : standardizedRepo + "/"
        for file in files {
            let source = repoURL.appendingPathComponent(file).standardizedFileURL
            guard source.path.hasPrefix(repoPrefix) else {
                throw GitError(message: "untracked diff path escapes repository: \(file)")
            }
            let destination = mirrorRoot.appendingPathComponent(file)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: destination)
        }

        let args = [
            "diff", "--no-index", "--unified=\(contextLines)",
            "--no-ext-diff", "--no-textconv", "--color=never", "--", "../empty", "."
        ]
        let (stdout, stderr, exitCode) = try await runGit(
            args,
            at: mirrorRoot,
            requiresRepoContext: false,
            budgetRepoURL: repoURL
        )
        guard exitCode == 0 || exitCode == 1 else {
            throw GitError(message: "git diff --no-index failed: \(stderr)")
        }
        return Self.normalizeBatchedUntrackedDiffPaths(stdout)
    }

    nonisolated static func normalizeBatchedUntrackedDiffPaths(_ output: String) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let text = String(line)
            guard text.hasPrefix("diff --git ")
                || text.hasPrefix("--- ")
                || text.hasPrefix("+++ ")
                || text.hasPrefix("Binary files ")
            else { return text }
            return text
                .replacingOccurrences(of: "1/./", with: "a/")
                .replacingOccurrences(of: "2/./", with: "b/")
                .replacingOccurrences(of: "a/./", with: "a/")
                .replacingOccurrences(of: "b/./", with: "b/")
                .replacingOccurrences(of: "\"1/./", with: "\"a/")
                .replacingOccurrences(of: "\"2/./", with: "\"b/")
                .replacingOccurrences(of: "\"a/./", with: "\"a/")
                .replacingOccurrences(of: "\"b/./", with: "\"b/")
        }.joined(separator: "\n")
    }

    /// Get diff for specific files (all uncommitted changes - staged and unstaged)
    func getDiff(for files: [String]? = nil, at repoURL: URL) async throws -> String {
        var combined = ""
        if let files, !files.isEmpty {
            let maxChunk = 3000
            if files.count <= maxChunk {
                var args = ["diff", "--unified=3", "HEAD", "--"]
                args.append(contentsOf: files)
                let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
                guard exitCode == 0 || exitCode == 1 else {
                    throw GitError(message: "git diff failed: \(stderr)")
                }
                return stdout
            }
            for chunk in files.chunked(into: maxChunk) {
                var args = ["diff", "--unified=3", "HEAD", "--"]
                args.append(contentsOf: chunk)
                let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
                guard exitCode == 0 || exitCode == 1 else {
                    throw GitError(message: "git diff failed: \(stderr)")
                }
                if !stdout.isEmpty {
                    combined += stdout
                    if !combined.hasSuffix("\n") { combined += "\n" }
                }
            }
            return combined
        } else {
            let args = ["diff", "--unified=3", "HEAD"]
            let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
            guard exitCode == 0 || exitCode == 1 else {
                throw GitError(message: "git diff failed: \(stderr)")
            }
            return stdout
        }
    }

    private func runDiff(
        argsPrefix: [String],
        contextLines: Int?,
        detectRenames: Bool,
        refArg: String?,
        paths: [String]?,
        at repoURL: URL
    ) async throws -> String {
        let maxChunk = 3000
        let pathspecByteLimit = 128 * 1024
        let cleanedPaths = (paths ?? []).filter { !$0.isEmpty }
        let pathspecBytes = cleanedPaths.reduce(0) { $0 + $1.lengthOfBytes(using: .utf8) + 1 }
        let usePathspec = !cleanedPaths.isEmpty && pathspecBytes >= pathspecByteLimit

        func baseArgs() -> [String] {
            var args = argsPrefix
            if let contextLines {
                args.append("--unified=\(contextLines)")
            }
            if detectRenames {
                args.append("-M")
            }
            args.append("--no-ext-diff")
            args.append("--color=never")
            return args
        }

        if usePathspec {
            do {
                var args = baseArgs()
                args.append(contentsOf: ["--pathspec-from-file=-", "--pathspec-file-nul"])
                if let refArg, !refArg.isEmpty {
                    args.append(refArg)
                }
                let stdin = makePathspecStdinData(cleanedPaths)
                let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL, stdin: stdin)
                guard exitCode == 0 || exitCode == 1 else {
                    throw GitError(message: "git diff failed: \(stderr)")
                }
                return stdout
            } catch {
                if !shouldFallbackFromPathspecError(error) {
                    throw error
                }
            }
        }

        guard !cleanedPaths.isEmpty else {
            var args = baseArgs()
            if let refArg, !refArg.isEmpty {
                args.append(refArg)
            }
            let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
            guard exitCode == 0 || exitCode == 1 else {
                throw GitError(message: "git diff failed: \(stderr)")
            }
            return stdout
        }

        if cleanedPaths.count <= maxChunk {
            var args = baseArgs()
            if let refArg, !refArg.isEmpty {
                args.append(refArg)
            }
            args.append("--")
            args.append(contentsOf: cleanedPaths)
            let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
            guard exitCode == 0 || exitCode == 1 else {
                throw GitError(message: "git diff failed: \(stderr)")
            }
            return stdout
        }

        var combined = ""
        for chunk in cleanedPaths.chunked(into: maxChunk) {
            var args = baseArgs()
            if let refArg, !refArg.isEmpty {
                args.append(refArg)
            }
            args.append("--")
            args.append(contentsOf: chunk)
            let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
            guard exitCode == 0 || exitCode == 1 else {
                throw GitError(message: "git diff failed: \(stderr)")
            }
            if !stdout.isEmpty {
                combined += stdout
                if !combined.hasSuffix("\n") { combined += "\n" }
            }
        }
        return combined
    }

    func getDiffUncommitted(
        base: String,
        paths: [String]?,
        contextLines: Int,
        detectRenames: Bool,
        at repoURL: URL
    ) async throws -> String {
        try await runDiff(
            argsPrefix: ["diff"],
            contextLines: contextLines,
            detectRenames: detectRenames,
            refArg: base,
            paths: paths,
            at: repoURL
        )
    }

    func getDiffUncommittedMergeBase(
        base: String,
        paths: [String]?,
        contextLines: Int,
        detectRenames: Bool,
        at repoURL: URL
    ) async throws -> String {
        try await runDiff(
            argsPrefix: ["diff", "--merge-base"],
            contextLines: contextLines,
            detectRenames: detectRenames,
            refArg: base,
            paths: paths,
            at: repoURL
        )
    }

    func getDiffStaged(
        base: String,
        paths: [String]?,
        contextLines: Int,
        detectRenames: Bool,
        at repoURL: URL
    ) async throws -> String {
        try await runDiff(
            argsPrefix: ["diff", "--cached"],
            contextLines: contextLines,
            detectRenames: detectRenames,
            refArg: base,
            paths: paths,
            at: repoURL
        )
    }

    func getDiffStagedMergeBase(
        base: String,
        paths: [String]?,
        contextLines: Int,
        detectRenames: Bool,
        at repoURL: URL
    ) async throws -> String {
        try await runDiff(
            argsPrefix: ["diff", "--cached", "--merge-base"],
            contextLines: contextLines,
            detectRenames: detectRenames,
            refArg: base,
            paths: paths,
            at: repoURL
        )
    }

    func getDiffUnstaged(
        paths: [String]?,
        contextLines: Int,
        detectRenames: Bool,
        at repoURL: URL
    ) async throws -> String {
        try await runDiff(
            argsPrefix: ["diff"],
            contextLines: contextLines,
            detectRenames: detectRenames,
            refArg: nil,
            paths: paths,
            at: repoURL
        )
    }

    func getDiffRevspec(
        _ revspec: String,
        paths: [String]?,
        contextLines: Int,
        detectRenames: Bool,
        at repoURL: URL
    ) async throws -> String {
        try await runDiff(
            argsPrefix: ["diff"],
            contextLines: contextLines,
            detectRenames: detectRenames,
            refArg: revspec,
            paths: paths,
            at: repoURL
        )
    }

    /// Get diff for specific files with error handling per file
    /// Returns tuple of (combinedDiff, failedFiles)
    func getDiffWithFailures(for files: [String], at repoURL: URL) async -> (String, [String]) {
        var combinedDiff = ""
        var failedFiles: [String] = []

        // Try to get diff for all files at once first
        do {
            let diff = try await getDiff(for: files, at: repoURL)
            return (diff, [])
        } catch {
            // If batch diff fails, try each file individually
            for file in files {
                do {
                    let fileDiff = try await getDiff(for: [file], at: repoURL)
                    if !fileDiff.isEmpty {
                        combinedDiff += fileDiff
                        if !combinedDiff.hasSuffix("\n") {
                            combinedDiff += "\n"
                        }
                    }
                } catch {
                    failedFiles.append(file)
                }
            }
        }

        return (combinedDiff, failedFiles)
    }

    /// Get list of local branches with last commit dates
    func getLocalBranches(at repoURL: URL, limit: Int? = nil) async throws -> [Branch] {
        var arguments = [
            "for-each-ref",
            "--sort=-committerdate",
            "--format=%(refname:short)%09%(committerdate:iso8601)%09%(HEAD)"
        ]
        if let limit {
            arguments.append("--count=\(max(0, limit))")
        }
        arguments.append("refs/heads")

        let (stdout, stderr, exitCode) = try await runGit(
            arguments,
            at: repoURL
        )

        guard exitCode == 0 else {
            throw GitError(message: "git for-each-ref failed: \(stderr)")
        }

        return parseBranchOutputWithDates(stdout)
    }

    func gitBranchSwitchOptions(at repoURL: URL) async throws -> GitBranchSwitchOptions {
        let branches = try await getLocalBranches(at: repoURL)
        let currentBranch = try await currentBranchOrNil(at: repoURL)
        let currentHead = try await getHeadSHA(at: repoURL)
        let worktreeOccupancy = try await branchWorktreeOccupancyByBranchName(excludingCurrentCheckoutAt: repoURL)
        return GitBranchSwitchOptions(
            rootPath: repoURL.standardizedFileURL.path,
            repoRootPath: repoURL.standardizedFileURL.path,
            currentBranch: currentBranch,
            currentHead: currentHead,
            isDetached: currentBranch == nil,
            branches: branches.map { branch in
                VCSBranch(
                    name: branch.name,
                    isCurrent: branch.name == currentBranch || branch.isCurrent,
                    lastCommitDate: branch.lastCommitDate,
                    checkedOutWorktree: worktreeOccupancy[branch.name]
                )
            }
        )
    }

    func preflightGitBranchSwitch(branchName: String, at repoURL: URL) async throws -> GitBranchSwitchPreflight {
        try Self.validateLocalBranchName(branchName)
        try await requireLocalBranch(branchName, at: repoURL)
        try await requireBranchNotCheckedOutInAnotherWorktree(branchName, at: repoURL)
        let currentBranch = try await currentBranchOrNil(at: repoURL)
        let currentHead = try await getHeadSHA(at: repoURL)
        async let dirtyFilesTask = getUncommittedFiles(at: repoURL)
        async let mergeStateTask = inspectMergeState(at: repoURL)
        let dirtyFiles = try await dirtyFilesTask
        let mergeState = try await mergeStateTask
        var warnings: [GitBranchSwitchPreflightWarning] = []
        if currentBranch == nil {
            warnings.append(.detachedHead)
        }
        if !dirtyFiles.isEmpty {
            warnings.append(.uncommittedChanges)
        }
        if mergeState.inProgress {
            warnings.append(.mergeInProgress)
        }
        return GitBranchSwitchPreflight(
            rootPath: repoURL.standardizedFileURL.path,
            repoRootPath: repoURL.standardizedFileURL.path,
            targetBranch: branchName,
            currentBranch: currentBranch,
            currentHead: currentHead,
            isCurrentBranch: currentBranch == branchName,
            warnings: warnings
        )
    }

    func switchGitBranch(_ request: GitBranchSwitchRequest, at repoURL: URL) async throws -> GitBranchSwitchResult {
        let mutationKey = getLayout(for: repoURL)?.commonDir.standardizedFileURL.path
            ?? repoURL.standardizedFileURL.path

        return try await worktreeMutationCoordinator.withLock(key: mutationKey) { [weak self] in
            guard let self else {
                throw GitBranchSwitchError.unavailable("git service was released before branch switching")
            }
            try Self.validateLocalBranchName(request.branchName)
            try await requireLocalBranch(request.branchName, at: repoURL)

            let previousBranch = try await currentBranchOrNil(at: repoURL)
            let previousHead = try await getHeadSHA(at: repoURL)
            try Self.validateExpectedCheckout(
                expectedBranch: request.expectedCurrentBranch,
                expectedHead: request.expectedCurrentHead,
                actualBranch: previousBranch,
                actualHead: previousHead
            )
            if previousBranch == request.branchName {
                return GitBranchSwitchResult(
                    rootPath: repoURL.standardizedFileURL.path,
                    repoRootPath: repoURL.standardizedFileURL.path,
                    previousBranch: previousBranch,
                    previousHead: previousHead,
                    newBranch: request.branchName,
                    newHead: previousHead,
                    didSwitch: false
                )
            }

            try await requireBranchNotCheckedOutInAnotherWorktree(request.branchName, at: repoURL)

            return try await withWorkspaceAuthorityMutation(at: repoURL, kind: .branchSwitch) {
                let switchResult = try await self.runGit(["switch", "--no-guess", request.branchName], at: repoURL)
                if switchResult.2 != 0 {
                    if Self.shouldFallbackFromGitSwitchError(switchResult.1) {
                        let checkoutResult = try await self.runGit(["checkout", request.branchName], at: repoURL)
                        guard checkoutResult.2 == 0 else {
                            throw GitBranchSwitchError.gitRefused("git checkout failed: \(checkoutResult.1)")
                        }
                    } else {
                        throw GitBranchSwitchError.gitRefused("git switch failed: \(switchResult.1)")
                    }
                }

                let newBranch = try await self.currentBranchOrNil(at: repoURL)
                let newHead = try await self.getHeadSHA(at: repoURL)
                guard newBranch == request.branchName else {
                    throw GitBranchSwitchError.gitRefused("Git reported success, but the checkout is now on \(newBranch ?? "detached HEAD") instead of \(request.branchName).")
                }
                return GitBranchSwitchResult(
                    rootPath: repoURL.standardizedFileURL.path,
                    repoRootPath: repoURL.standardizedFileURL.path,
                    previousBranch: previousBranch,
                    previousHead: previousHead,
                    newBranch: request.branchName,
                    newHead: newHead,
                    didSwitch: true
                )
            }
        }
    }

    private func currentBranchOrNil(at repoURL: URL) async throws -> String? {
        let branch = try await getCurrentBranch(at: repoURL).trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty || branch == "HEAD" ? nil : branch
    }

    private static func validateLocalBranchName(_ branchName: String) throws {
        let trimmed = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == branchName,
              !branchName.isEmpty,
              !branchName.hasPrefix("-"),
              !branchName.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else {
            throw GitBranchSwitchError.invalidBranchName(branchName)
        }
    }

    private func requireLocalBranch(_ branchName: String, at repoURL: URL) async throws {
        let (_, _, exitCode) = try await runGit(
            ["show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"],
            at: repoURL
        )
        guard exitCode == 0 else {
            throw GitBranchSwitchError.branchNotLocal(branchName)
        }
    }

    private func branchWorktreeOccupancyByBranchName(
        excludingCurrentCheckoutAt repoURL: URL
    ) async throws -> [String: VCSBranchWorktreeOccupancy] {
        let worktrees = try await listWorktrees(at: repoURL)
        var result: [String: VCSBranchWorktreeOccupancy] = [:]

        for descriptor in worktrees {
            guard let branch = descriptor.branch?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !branch.isEmpty,
                  !descriptor.isDetached,
                  !descriptor.isCurrent
            else { continue }

            result[branch] = VCSBranchWorktreeOccupancy(
                worktreePath: descriptor.path,
                worktreeName: descriptor.name,
                worktreeID: descriptor.worktreeID
            )
        }

        return result
    }

    private func requireBranchNotCheckedOutInAnotherWorktree(_ branchName: String, at repoURL: URL) async throws {
        let worktreeOccupancy = try await branchWorktreeOccupancyByBranchName(excludingCurrentCheckoutAt: repoURL)
        guard let occupied = worktreeOccupancy[branchName] else { return }
        throw GitBranchSwitchError.branchCheckedOutInWorktree(
            branch: branchName,
            worktreePath: occupied.worktreePath,
            worktreeName: occupied.worktreeName
        )
    }

    private static func validateExpectedCheckout(
        expectedBranch: String?,
        expectedHead: String?,
        actualBranch: String?,
        actualHead: String
    ) throws {
        if let expectedBranch, expectedBranch != actualBranch {
            throw GitBranchSwitchError.staleCheckout(
                expectedBranch: expectedBranch,
                actualBranch: actualBranch,
                expectedHead: expectedHead,
                actualHead: actualHead
            )
        }
        if let expectedHead, expectedHead != actualHead {
            throw GitBranchSwitchError.staleCheckout(
                expectedBranch: expectedBranch,
                actualBranch: actualBranch,
                expectedHead: expectedHead,
                actualHead: actualHead
            )
        }
    }

    private static func shouldFallbackFromGitSwitchError(_ stderr: String) -> Bool {
        let lowercased = stderr.lowercased()
        return lowercased.contains("'switch' is not a git command")
            || lowercased.contains("unknown command 'switch'")
            || lowercased.contains("unknown subcommand: switch")
    }

    /// Get list of remote branches with last commit dates, sorted by most recent
    /// Filters out symbolic HEAD refs (e.g., origin/HEAD)
    func getRemoteBranches(at repoURL: URL, limit: Int = 10) async throws -> [Branch] {
        let (stdout, stderr, exitCode) = try await runGit(
            ["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)%09%(committerdate:iso8601)", "refs/remotes", "--count=\(limit + 5)"],
            at: repoURL
        )

        guard exitCode == 0 else {
            throw GitError(message: "git for-each-ref failed: \(stderr)")
        }

        // Parse and filter out HEAD symbolic refs (e.g., origin/HEAD)
        // Reuse parseBranchOutputWithDates since it handles 2-field format (name + date)
        let branches = parseBranchOutputWithDates(stdout)
            .filter { !$0.name.hasSuffix("/HEAD") }

        // Return only up to limit after filtering
        return Array(branches.prefix(limit))
    }

    /// Fetch updates from all remotes
    /// Updates local tracking refs (e.g., origin/main) to match remote state
    func fetch(at repoURL: URL) async throws {
        try await withWorkspaceAuthorityMutation(at: repoURL, kind: .fetch) {
            let (_, stderr, exitCode) = try await runGit(
                ["fetch", "--all", "--prune"],
                at: repoURL
            )

            guard exitCode == 0 else {
                throw GitError(message: "git fetch failed: \(stderr)")
            }
        }
    }

    /// Check if a given ref name exists under refs/remotes.
    func hasRemoteTrackingRef(named refName: String, at repoURL: URL) async -> Bool {
        let ref = "refs/remotes/\(refName)"
        do {
            let (_, _, exitCode) = try await runGit(
                ["show-ref", "--verify", "--quiet", ref],
                at: repoURL
            )
            return exitCode == 0
        } catch {
            return false
        }
    }

    /// Get recent tags sorted by commit date
    func getTags(at repoURL: URL, limit: Int = 10) async throws -> [Tag] {
        // Get tags with their commit dates using for-each-ref
        let (stdout, stderr, exitCode) = try await runGit(
            ["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)%09%(committerdate:iso8601)", "refs/tags", "--count=\(limit)"],
            at: repoURL
        )

        guard exitCode == 0 else {
            throw GitError(message: "git for-each-ref failed: \(stderr)")
        }

        return parseTagOutputWithDates(stdout)
    }

    /// Get current branch name
    func getCurrentBranch(at repoURL: URL) async throws -> String {
        // Try the symbolic-ref command first (more reliable)
        let (stdout, stderr, exitCode) = try await runGit(
            ["symbolic-ref", "--short", "HEAD"],
            at: repoURL
        )

        if exitCode == 0 {
            return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Fallback to branch --show-current
        let (stdout2, stderr2, exitCode2) = try await runGit(
            ["branch", "--show-current"],
            at: repoURL
        )

        if exitCode2 == 0 {
            return stdout2.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Final fallback to rev-parse
        let (stdout3, stderr3, exitCode3) = try await runGit(
            ["rev-parse", "--abbrev-ref", "HEAD"],
            at: repoURL
        )

        guard exitCode3 == 0 else {
            throw GitError(message: "All git branch commands failed. symbolic-ref: \(stderr), branch: \(stderr2), rev-parse: \(stderr3)")
        }

        return stdout3.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Get list of changed files with per-file additions / deletions statistics
    /// Get changed files with statistics, including untracked files
    /// - Parameters:
    ///   - base: Comparison baseline (`.head` or `.branch("main")`)
    ///   - repoURL: URL of the repository root
    /// - Returns: Array of `UncommittedFile` including tracked changes and untracked files
    func getChangedFilesStats(
        relativeTo base: CompareBase,
        at repoURL: URL
    ) async throws -> [UncommittedFile] {
        // Build argument lists ---------------------------------------------------
        let reference: [String] = switch base {
        case .head: ["HEAD"]
        case let .branch(ref): [ref]
        }

        let numstatArgs = ["diff"] + reference + ["--numstat"]
        let nameStatusArgs = ["diff"] + reference + ["--name-status"]

        // Run all commands in parallel -----------------------------------------
        async let numstatResult = runGit(numstatArgs, at: repoURL)
        async let nameStatResult = runGit(nameStatusArgs, at: repoURL)
        async let untrackedResult = runGit(["ls-files", "--others", "--exclude-standard"], at: repoURL)

        let (numOut, numErr, numExit) = try await numstatResult
        guard numExit == 0 || numExit == 1 else {
            throw GitError(message: "git diff --numstat failed: \(numErr)")
        }

        let (nameOut, nameErr, nameExit) = try await nameStatResult
        guard nameExit == 0 || nameExit == 1 else {
            throw GitError(message: "git diff --name-status failed: \(nameErr)")
        }

        let (untrackedOut, _, untrackedExit) = try await untrackedResult
        guard untrackedExit == 0 else {
            throw GitError(message: "git ls-files failed")
        }

        // Parse outputs ----------------------------------------------------------
        let (statsMap, statusMap) = MCPToolWorkCountDiagnostics.measureGitParse {
            (parseNumstatOutput(numOut), parseNameStatusOutput(nameOut))
        }

        // Merge into unified results --------------------------------------------
        var results: [UncommittedFile] = []
        let allPaths = Set(statsMap.keys).union(statusMap.keys)

        for path in allPaths {
            let status = statusMap[path] ?? "M"
            let tuple = statsMap[path]
            let additions = tuple?.0
            let deletions = tuple?.1
            results.append(
                UncommittedFile(
                    path: path,
                    status: status,
                    additions: additions,
                    deletions: deletions
                )
            )
        }

        // Add untracked files ----------------------------------------------------
        let untrackedFiles = untrackedOut
            .split(separator: "\n")
            .map { String($0) }
            .filter { !$0.isEmpty }

        for path in untrackedFiles {
            // Only add if not already in the results (avoid duplicates)
            if !allPaths.contains(path) {
                let stats = untrackedLineStats(for: path, repoURL: repoURL)
                results.append(
                    UncommittedFile(
                        path: path,
                        status: "??",
                        additions: stats.additions,
                        deletions: stats.deletions
                    )
                )
            }
        }

        // Stable, human-friendly order
        let keyed = results.map { file in
            (lower: file.path.lowercased(), original: file.path, file: file)
        }
        return keyed.sorted { lhs, rhs in
            if lhs.lower != rhs.lower {
                return lhs.lower < rhs.lower
            }
            return lhs.original < rhs.original
        }.map(\.file)
    }

    private enum DiffStatKind {
        case numstat
        case nameStatus
    }

    private func diffArgs(
        for compare: GitDiffCompareSpec,
        kind: DiffStatKind
    ) -> (argsPrefix: [String], refArg: String?) {
        var argsPrefix = ["diff"]
        switch compare {
        case .staged:
            argsPrefix.append("--cached")
        case .stagedMergeBase:
            argsPrefix.append("--cached")
            argsPrefix.append("--merge-base")
        case .uncommittedMergeBase:
            argsPrefix.append("--merge-base")
        default:
            break
        }
        switch kind {
        case .numstat:
            argsPrefix.append("--numstat")
        case .nameStatus:
            argsPrefix.append("--name-status")
        }

        let refArg: String? = switch compare {
        case let .uncommitted(base):
            base
        case let .uncommittedMergeBase(base):
            base
        case let .staged(base):
            base
        case let .stagedMergeBase(base):
            base
        case .unstaged:
            nil
        case let .revspec(revspec):
            revspec
        }
        return (argsPrefix, refArg)
    }

    func getDiffNumstat(
        compare: GitDiffCompareSpec,
        detectRenames: Bool = false,
        at repoURL: URL
    ) async throws -> String {
        let (argsPrefix, refArg) = diffArgs(for: compare, kind: .numstat)
        return try await runDiff(
            argsPrefix: argsPrefix,
            contextLines: nil,
            detectRenames: detectRenames,
            refArg: refArg,
            paths: nil,
            at: repoURL
        )
    }

    func getDiffNameStatus(
        compare: GitDiffCompareSpec,
        detectRenames: Bool = false,
        at repoURL: URL
    ) async throws -> String {
        let (argsPrefix, refArg) = diffArgs(for: compare, kind: .nameStatus)
        return try await runDiff(
            argsPrefix: argsPrefix,
            contextLines: nil,
            detectRenames: detectRenames,
            refArg: refArg,
            paths: nil,
            at: repoURL
        )
    }

    func getChangedFilesStats(
        compare: GitDiffCompareSpec,
        includeUntrackedWhenApplicable: Bool,
        detectRenames: Bool = false,
        at repoURL: URL
    ) async throws -> [UncommittedFile] {
        let includeUntracked = includeUntrackedWhenApplicable && {
            switch compare {
            case .uncommitted, .uncommittedMergeBase, .unstaged:
                true
            case .staged, .stagedMergeBase, .revspec:
                false
            }
        }()

        async let numOutTask = getDiffNumstat(compare: compare, detectRenames: detectRenames, at: repoURL)
        async let nameOutTask = getDiffNameStatus(compare: compare, detectRenames: detectRenames, at: repoURL)
        async let untrackedFilesTask = includeUntracked ? getUntrackedPaths(at: repoURL) : []
        let (numOut, nameOut, untrackedFiles) = try await (numOutTask, nameOutTask, untrackedFilesTask)
        let (statsMap, statusMap) = MCPToolWorkCountDiagnostics.measureGitParse {
            (parseNumstatOutput(numOut), parseNameStatusOutput(nameOut))
        }

        var results: [UncommittedFile] = []
        let allPaths = Set(statsMap.keys).union(statusMap.keys)

        for path in allPaths {
            let status = statusMap[path] ?? "M"
            let tuple = statsMap[path]
            let additions = tuple?.0
            let deletions = tuple?.1
            results.append(
                UncommittedFile(
                    path: path,
                    status: status,
                    additions: additions,
                    deletions: deletions
                )
            )
        }

        if includeUntracked {
            for path in untrackedFiles {
                if !allPaths.contains(path) {
                    let stats = untrackedLineStats(for: path, repoURL: repoURL)
                    results.append(
                        UncommittedFile(
                            path: path,
                            status: "??",
                            additions: stats.additions,
                            deletions: stats.deletions
                        )
                    )
                }
            }
        }

        let keyed = results.map { file in
            (lower: file.path.lowercased(), original: file.path, file: file)
        }
        return keyed.sorted { lhs, rhs in
            if lhs.lower != rhs.lower {
                return lhs.lower < rhs.lower
            }
            return lhs.original < rhs.original
        }.map(\.file)
    }

    private func getUntrackedPaths(at repoURL: URL) async throws -> [String] {
        let (stdout, stderr, exitCode) = try await runGit(
            ["ls-files", "--others", "--exclude-standard"],
            at: repoURL
        )
        guard exitCode == 0 else {
            throw GitError(message: "git ls-files failed: \(stderr)")
        }
        return stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    func getCommitGraph(maxLines: Int, at repoURL: URL) async throws -> String {
        let args = ["log", "--graph", "--decorate", "--oneline", "--color=never", "-n", "\(maxLines)"]
        let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
        guard exitCode == 0 else {
            throw GitError(message: "git log failed: \(stderr)")
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Return how many commits the current HEAD is ahead/behind the given branch.
    /// Positive `ahead` means local commits not in *branch*,
    /// positive `behind` means commits present in *branch* but not in HEAD.
    func getAheadBehind(
        vs branch: String,
        at repoURL: URL
    ) async throws -> (ahead: Int, behind: Int) {
        let args = ["rev-list", "--left-right", "--count", "\(branch)...HEAD"]
        let (stdout, stderr, exit) = try await runGit(args, at: repoURL)
        guard exit == 0 else {
            throw GitError(message: "git rev-list failed: \(stderr)")
        }
        let parts = stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t")
            .map(String.init)
        guard parts.count == 2,
              let behind = Int(parts[0]),
              let ahead = Int(parts[1])
        else {
            throw GitError(message: "Unexpected rev-list output: \(stdout)")
        }
        return (ahead: ahead, behind: behind)
    }

    // MARK: - Unified Git Tool Support

    /// Get the upstream tracking branch for the current branch.
    /// Returns nil if no upstream is set.
    func getUpstreamRef(at repoURL: URL) async throws -> String? {
        let args = ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]
        let (stdout, _, exitCode) = try await runGit(args, at: repoURL)
        guard exitCode == 0 else {
            return nil // No upstream configured
        }
        let result = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// Structured working directory status.
    struct WorkingStatus: Equatable {
        let staged: [String]
        let modified: [String]
        let untracked: [String]
    }

    struct RepositoryStatus: Equatable {
        let branch: String?
        let headID: String?
        let upstream: String?
        let ahead: Int?
        let behind: Int?
        let workingStatus: WorkingStatus
    }

    /// Read branch metadata and working-tree state from one porcelain-v2 snapshot.
    func getRepositoryStatus(at repoURL: URL) async throws -> RepositoryStatus {
        let args = ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"]
        let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
        guard exitCode == 0 else {
            throw GitError(message: "git status --porcelain=v2 failed: \(stderr)")
        }
        let parsed = try MCPToolWorkCountDiagnostics.measureGitParse {
            try GitStatusPorcelainV2Parser.parse(stdout)
        }
        return RepositoryStatus(
            branch: parsed.branch,
            headID: parsed.headID,
            upstream: parsed.upstream,
            ahead: parsed.ahead,
            behind: parsed.behind,
            workingStatus: WorkingStatus(
                staged: parsed.staged,
                modified: parsed.modified,
                untracked: parsed.untracked
            )
        )
    }

    /// Compatibility wrapper for callers that only need working-tree paths.
    func getWorkingStatus(at repoURL: URL) async throws -> WorkingStatus {
        try await getRepositoryStatus(at: repoURL).workingStatus
    }

    // MARK: - Git Blob Identity Shadow Plumbing

    /// Resolve the actual repository layout for a loaded root, including roots that are
    /// subdirectories of a checkout. The shared `commonDir` remains authoritative for
    /// object-store identity while `gitDir` owns this worktree's index.
    func resolveGitBlobRepository(containing workspaceRoot: URL) async throws -> GitRepositoryLayout? {
        guard let repositoryRoot = try await findGitRoot(from: workspaceRoot) else { return nil }
        let standardizedRoot = repositoryRoot.standardizedFileURL
        let key = standardizedRoot.path
        let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: standardizedRoot)
        if let layout {
            cacheLayout(layout, forKey: key)
        } else {
            worktreeLayoutCache.removeValue(forKey: key)
        }
        return layout
    }

    // MARK: - Bounded Worktree Initialization Authority

    func resolveTreeOID(
        _ ref: String,
        in layout: GitRepositoryLayout,
        priority: GitProcessAdmissionPriority = .rootBootstrap
    ) async throws -> GitObjectID {
        guard !ref.isEmpty, ref.utf8.count <= 4096, !ref.utf8.contains(0) else {
            throw GitWorktreeInitializationError.malformedOutput("invalid tree reference")
        }
        let format = try await boundedObjectFormat(in: layout, priority: priority, timeout: .seconds(5))
        let data = try await runBoundedAuthorityGit(
            ["rev-parse", "--verify", "--end-of-options", "\(ref)^{tree}"],
            layout: layout,
            limits: .delta,
            priority: priority,
            family: .treeResolution
        )
        guard let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw GitWorktreeInitializationError.malformedOutput("tree object ID is not UTF-8")
        }
        return try GitObjectID(objectFormat: format, lowercaseHex: value)
    }

    func listTree(
        _ treeOID: GitObjectID,
        in layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        limits: GitWorktreeInitializationLimits = .treeInventory,
        priority: GitProcessAdmissionPriority = .rootBootstrap
    ) async throws -> GitTreeInventorySnapshot {
        var args = [
            "ls-tree", "-r", "-t", "-z", "--full-tree",
            "--format=%(objectmode) %(objecttype) %(objectname)%x09%(path)",
            treeOID.lowercaseHex
        ]
        appendLiteralPrefix(prefix, to: &args)
        let data = try await runBoundedAuthorityGit(
            args,
            layout: layout,
            limits: limits,
            priority: priority,
            family: .treeInventory
        )
        return try GitTreeInventoryParser.parseTreeInventory(
            data,
            treeOID: treeOID,
            rootPrefix: prefix,
            limits: limits
        )
    }

    func diffTrees(
        baseTreeOID: GitObjectID,
        targetTreeOID: GitObjectID,
        in layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        limits: GitWorktreeInitializationLimits = .delta,
        priority: GitProcessAdmissionPriority = .rootBootstrap
    ) async throws -> [GitTreeDeltaRecord] {
        guard baseTreeOID.objectFormat == targetTreeOID.objectFormat else {
            throw GitWorktreeInitializationError.malformedOutput("tree object formats differ")
        }
        var args = [
            "diff-tree", "-r", "--raw", "-z", "--no-commit-id",
            "--find-renames", "--find-copies", "--no-ext-diff",
            baseTreeOID.lowercaseHex, targetTreeOID.lowercaseHex
        ]
        appendLiteralPrefix(prefix, to: &args)
        let data = try await runBoundedAuthorityGit(
            args,
            layout: layout,
            limits: limits,
            priority: priority,
            family: .treeDelta
        )
        return try GitTreeInventoryParser.parseTreeDelta(
            data,
            objectFormat: baseTreeOID.objectFormat,
            rootPrefix: prefix,
            limits: limits
        )
    }

    func indexManifest(
        in layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        limits: GitWorktreeInitializationLimits = .index,
        priority: GitProcessAdmissionPriority = .rootBootstrap
    ) async throws -> GitIndexManifest {
        let format = try await boundedObjectFormat(in: layout, priority: priority, timeout: limits.commandTimeout)
        let sparseLimits = GitWorktreeInitializationLimits(
            maximumRecordCount: 1,
            maximumOutputBytes: 16,
            maximumPathUTF8Bytes: 16,
            maximumPathDepth: 1,
            commandTimeout: limits.commandTimeout
        )
        let sparseData = try await runBoundedAuthorityGit(
            ["config", "--bool", "-z", "--get", "core.sparseCheckout"],
            layout: layout,
            limits: sparseLimits,
            priority: priority,
            family: .authorityMetadata,
            allowedExitCodes: [0, 1]
        )
        let sparseCheckoutEnabled: Bool
        if sparseData.isEmpty {
            sparseCheckoutEnabled = false
        } else if sparseData == Data("true\0".utf8) {
            sparseCheckoutEnabled = true
        } else if sparseData == Data("false\0".utf8) {
            sparseCheckoutEnabled = false
        } else {
            throw GitWorktreeInitializationError.malformedOutput("invalid core.sparseCheckout boolean")
        }
        var args = ["ls-files", "--stage", "-v", "-z"]
        appendLiteralPrefix(prefix, to: &args)
        let data = try await runBoundedAuthorityGit(
            args,
            layout: layout,
            limits: limits,
            priority: priority,
            family: .indexManifest
        )
        return try GitTreeInventoryParser.parseIndexManifest(
            data,
            objectFormat: format,
            rootPrefix: prefix,
            limits: limits,
            sparseCheckoutEnabled: sparseCheckoutEnabled
        )
    }

    func worktreeStatus(
        in layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        includeUntracked: Bool = true,
        includeIgnored: Bool = true,
        limits: GitWorktreeInitializationLimits = .status,
        priority: GitProcessAdmissionPriority = .rootBootstrap
    ) async throws -> GitStatusPorcelainV2Snapshot {
        var args = [
            "status", "--porcelain=v2", "-z",
            includeUntracked ? "--untracked-files=all" : "--untracked-files=no"
        ]
        if includeIgnored {
            args.append("--ignored=matching")
        }
        appendLiteralPrefix(prefix, to: &args)
        let data = try await runBoundedAuthorityGit(
            args,
            layout: layout,
            limits: limits,
            priority: priority,
            family: .status
        )
        return try GitTreeInventoryParser.validateStatusSnapshot(
            data,
            rootPrefix: prefix,
            limits: limits
        )
    }

    func authorityMetadata(
        in layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        priority: GitProcessAdmissionPriority = .rootBootstrap
    ) async throws -> GitWorkspaceAuthorityMetadata {
        let format = try await boundedObjectFormat(in: layout, priority: priority, timeout: .seconds(5))
        let headCommit = try await boundedObjectID(
            "HEAD^{commit}",
            objectFormat: format,
            layout: layout,
            priority: priority
        )
        let tree = try await boundedObjectID(
            "HEAD^{tree}",
            objectFormat: format,
            layout: layout,
            priority: priority
        )
        let configLimits = GitWorktreeInitializationLimits(
            maximumRecordCount: 4096,
            maximumOutputBytes: 1024 * 1024,
            commandTimeout: .seconds(5)
        )
        let configData = try await runBoundedAuthorityGit(
            [
                "config", "--null", "--show-origin", "--get-regexp",
                "^(core\\.(autocrlf|eol|attributesfile|excludesfile|sparsecheckout|sparsecheckoutcone)|filter\\.)"
            ],
            layout: layout,
            limits: configLimits,
            priority: priority,
            family: .authorityMetadata,
            allowedExitCodes: [0, 1]
        )
        // Configured authority paths are operational metadata only. Reusable
        // policy identity carries their resolved contents below, never the
        // machine-local absolute path stored in Git config.
        let rootNeutralPolicyConfigData = try await runBoundedAuthorityGit(
            [
                "config", "--null", "--get-regexp",
                "^(core\\.(autocrlf|eol|sparsecheckout|sparsecheckoutcone)|filter\\.)"
            ],
            layout: layout,
            limits: configLimits,
            priority: priority,
            family: .authorityMetadata,
            allowedExitCodes: [0, 1]
        )
        let resolvedExcludesFileURL = try await boundedConfigPath(
            "core.excludesFile",
            layout: layout,
            priority: priority
        )
        let resolvedAttributesFileURL = try await boundedConfigPath(
            "core.attributesFile",
            layout: layout,
            priority: priority
        )
        let resolvedExcludesFileIdentity = try resolvedExcludesFileURL.map {
            try Self.boundedAuthorityContentIdentity(at: $0)
        }
        let resolvedAttributesFileIdentity = try resolvedAttributesFileURL.map {
            try Self.boundedAuthorityContentIdentity(at: $0)
        }
        let prefixControlIdentities = try Self.boundedPrefixControlIdentities(
            layout: layout,
            prefix: prefix,
            limits: .delta
        )
        let ignoreControlIdentities = prefixControlIdentities.filter { $0.kind != .gitAttributes }
        let attributeControlIdentities = prefixControlIdentities.filter { $0.kind == .gitAttributes }
        let indexDigest = try Self.boundedAuthorityFileDigest([
            ("index", layout.gitDir.appendingPathComponent("index"))
        ], maximumBytesPerFile: 32 * 1024 * 1024)
        let repositoryIgnoreDigest = try Self.boundedAuthorityFileDigest([
            ("info/exclude", layout.commonDir.appendingPathComponent("info/exclude"))
        ])
        let repositoryAttributeDigest = try Self.boundedAuthorityFileDigest([
            ("info/attributes", layout.commonDir.appendingPathComponent("info/attributes"))
        ])
        let sparseDigest = try Self.boundedAuthorityFileDigest([
            ("sparse-checkout", layout.gitDir.appendingPathComponent("info/sparse-checkout"))
        ])
        let metadataDigest = try Self.boundedAuthorityFileDigest([
            ("dot-git", layout.dotGitPath),
            ("head", layout.gitDir.appendingPathComponent("HEAD")),
            ("packed-refs", layout.commonDir.appendingPathComponent("packed-refs")),
            ("config", layout.commonDir.appendingPathComponent("config")),
            ("config.worktree", layout.gitDir.appendingPathComponent("config.worktree"))
        ])
        let committedIgnoreControlDigest = Self.canonicalControlIdentityDigest(ignoreControlIdentities)
        let prefixAttributeDigest = Self.canonicalControlIdentityDigest(attributeControlIdentities)
        let configuredIgnoreAuthorityDigest = Self.sha256Hex(
            rootNeutralPolicyConfigData
                + Data(repositoryIgnoreDigest.utf8)
                + Self.canonicalOptionalContentIdentityData(resolvedExcludesFileIdentity)
        )
        let attributePolicyDigest = Self.sha256Hex(
            rootNeutralPolicyConfigData
                + Data(repositoryAttributeDigest.utf8)
                + Data(prefixAttributeDigest.utf8)
                + Self.canonicalOptionalContentIdentityData(resolvedAttributesFileIdentity)
        )
        let policyIdentity = GitWorkspacePolicyIdentity(
            mandatoryIgnorePolicyIdentity: "git-ignore-policy-v1",
            committedIgnoreControlDigest: committedIgnoreControlDigest,
            configuredIgnoreAuthorityDigest: configuredIgnoreAuthorityDigest,
            attributePolicyDigest: attributePolicyDigest,
            sparsePolicyDigest: Self.sha256Hex(rootNeutralPolicyConfigData + Data(sparseDigest.utf8)),
            searchABI: .current,
            resolvedExcludesFileIdentity: resolvedExcludesFileIdentity,
            resolvedAttributesFileIdentity: resolvedAttributesFileIdentity,
            prefixControlIdentities: prefixControlIdentities
        )
        return GitWorkspaceAuthorityMetadata(
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: layout),
            objectFormat: format,
            headCommitOID: headCommit,
            treeOID: tree,
            repositoryRelativeRootPrefix: prefix,
            indexGeneration: indexDigest,
            checkoutConfigurationGeneration: Self.sha256Hex(configData),
            ignoreAuthorityGeneration: configuredIgnoreAuthorityDigest,
            attributeAuthorityGeneration: attributePolicyDigest,
            sparsePolicyGeneration: policyIdentity.sparsePolicyDigest,
            metadataGeneration: metadataDigest,
            policyIdentity: policyIdentity,
            resolvedExternalAuthorityPaths: [resolvedExcludesFileURL, resolvedAttributesFileURL].compactMap(\.self)
        )
    }

    func workspaceAuthoritySnapshot(
        in layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        priority: GitProcessAdmissionPriority = .rootBootstrap
    ) async throws -> (metadata: GitWorkspaceAuthorityMetadata, snapshot: GitWorkspaceAuthoritySnapshot) {
        let metadata = try await authorityMetadata(in: layout, prefix: prefix, priority: priority)
        return try (metadata, makeWorkspaceAuthoritySnapshot(metadata: metadata, layout: layout))
    }

    func makeWorkspaceAuthoritySnapshot(
        metadata: GitWorkspaceAuthorityMetadata,
        layout: GitRepositoryLayout
    ) throws -> GitWorkspaceAuthoritySnapshot {
        let namespace = try GitBlobRepositoryNamespace(
            repositoryLayout: layout,
            salt: Self.workspaceAuthorityNamespaceSalt
        )
        let repositoryBindingEpoch = Self.sha256Hex(Data(
            ("workspace-authority-repository-v1\u{0}" + namespace.rawValue).utf8
        ))
        let worktreeBindingEpoch = Self.sha256Hex(Data(
            [
                "workspace-authority-worktree-v1",
                layout.gitDir.standardizedFileURL.path,
                metadata.indexGeneration,
                metadata.metadataGeneration
            ].joined(separator: "\u{0}").utf8
        ))
        let layoutGeneration = Self.sha256Hex(Data(
            [
                "workspace-authority-layout-v1",
                layout.commonDir.standardizedFileURL.path,
                layout.gitDir.standardizedFileURL.path,
                layout.workTreeRoot.standardizedFileURL.path,
                layout.isLinkedWorktree ? "linked" : "main"
            ].joined(separator: "\u{0}").utf8
        ))
        return GitWorkspaceAuthoritySnapshot(
            repositoryKey: metadata.repositoryKey,
            repositoryNamespace: namespace,
            objectFormat: metadata.objectFormat,
            headCommitOID: metadata.headCommitOID,
            treeOID: metadata.treeOID,
            repositoryRelativeRootPrefix: metadata.repositoryRelativeRootPrefix,
            repositoryBindingEpoch: repositoryBindingEpoch,
            worktreeBindingEpoch: worktreeBindingEpoch,
            layoutGeneration: layoutGeneration,
            indexGeneration: metadata.indexGeneration,
            checkoutConfigurationGeneration: metadata.checkoutConfigurationGeneration,
            metadataGeneration: metadata.metadataGeneration,
            policyIdentity: metadata.policyIdentity
        )
    }

    private func boundedConfigPath(
        _ key: String,
        layout: GitRepositoryLayout,
        priority: GitProcessAdmissionPriority
    ) async throws -> URL? {
        let limits = GitWorktreeInitializationLimits(
            maximumRecordCount: 1,
            maximumOutputBytes: 16 * 1024,
            commandTimeout: .seconds(5)
        )
        let data = try await runBoundedAuthorityGit(
            ["config", "--path", "-z", "--get", key],
            layout: layout,
            limits: limits,
            priority: priority,
            family: .authorityMetadata,
            allowedExitCodes: [0, 1]
        )
        guard !data.isEmpty else { return nil }
        guard data.last == 0 else {
            throw GitWorktreeInitializationError.malformedOutput("config path is not NUL terminated")
        }
        let records = data.dropLast().split(separator: 0, omittingEmptySubsequences: false)
        guard records.count == 1,
              let value = String(data: records[0], encoding: .utf8),
              !value.isEmpty,
              !value.contains("\0")
        else {
            throw GitWorktreeInitializationError.malformedOutput("invalid config path")
        }
        let url = value.hasPrefix("/")
            ? URL(fileURLWithPath: value)
            : layout.workTreeRoot.appendingPathComponent(value)
        return url.standardizedFileURL
    }

    private func boundedObjectID(
        _ specification: String,
        objectFormat: GitObjectFormat,
        layout: GitRepositoryLayout,
        priority: GitProcessAdmissionPriority
    ) async throws -> GitObjectID {
        let data = try await runBoundedAuthorityGit(
            ["rev-parse", "--verify", "--end-of-options", specification],
            layout: layout,
            limits: .delta,
            priority: priority,
            family: .treeResolution
        )
        guard let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw GitWorktreeInitializationError.malformedOutput("object ID is not UTF-8")
        }
        return try GitObjectID(objectFormat: objectFormat, lowercaseHex: value)
    }

    private func boundedObjectFormat(
        in layout: GitRepositoryLayout,
        priority: GitProcessAdmissionPriority,
        timeout: Duration
    ) async throws -> GitObjectFormat {
        let limits = GitWorktreeInitializationLimits(
            maximumRecordCount: 1,
            maximumOutputBytes: 64,
            commandTimeout: timeout
        )
        let data = try await runBoundedAuthorityGit(
            ["rev-parse", "--show-object-format"],
            layout: layout,
            limits: limits,
            priority: priority,
            family: .treeResolution
        )
        guard let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw GitWorktreeInitializationError.malformedOutput("object format is not UTF-8")
        }
        do {
            return try GitObjectFormat(gitValue: value)
        } catch {
            throw GitWorktreeInitializationError.malformedOutput("unsupported object format")
        }
    }

    private func runBoundedAuthorityGit(
        _ args: [String],
        layout: GitRepositoryLayout,
        limits: GitWorktreeInitializationLimits,
        priority: GitProcessAdmissionPriority,
        family: GitProcessCommandFamily,
        allowedExitCodes: Set<Int32> = [0]
    ) async throws -> Data {
        do {
            let (stdout, _, exitCode) = try await runGitData(
                args,
                at: layout.workTreeRoot,
                env: ["GIT_LITERAL_PATHSPECS": "1"],
                stdoutByteLimit: limits.maximumOutputBytes,
                stderrByteLimit: 64 * 1024,
                repositoryBinding: .exactWorktree(layout),
                admissionPriority: priority,
                admissionDeadline: priority == .rootBootstrap || priority == .userInitiatedAuthority
                    ? Self.gitAdmissionDeadline(after: limits.commandTimeout)
                    : nil,
                commandFamily: family,
                commandTimeout: limits.commandTimeout
            )
            guard allowedExitCodes.contains(exitCode) else {
                throw GitWorktreeInitializationError.gitFailure(exitCode: exitCode)
            }
            return stdout
        } catch GitProcessCaptureError.stdoutByteLimitExceeded,
            GitProcessCaptureError.stderrByteLimitExceeded
        {
            throw GitWorktreeInitializationError.outputLimitExceeded
        } catch GitProcessCaptureError.timedOut {
            throw GitWorktreeInitializationError.timeout
        } catch is CancellationError {
            throw CancellationError()
        }
    }

    private nonisolated static func boundedAuthorityFileDigest(
        _ files: [(String, URL)],
        maximumBytesPerFile: Int = 4 * 1024 * 1024
    ) throws -> String {
        var canonical = Data()
        for (label, url) in files.sorted(by: { $0.0 < $1.0 }) {
            appendLengthPrefixed(Data(label.utf8), to: &canonical)
            var value = stat()
            if lstat(url.path, &value) != 0 {
                guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                appendLengthPrefixed(Data("missing".utf8), to: &canonical)
                continue
            }
            let kind = value.st_mode & S_IFMT
            if kind == S_IFDIR {
                appendLengthPrefixed(Data("directory".utf8), to: &canonical)
                continue
            }
            guard kind == S_IFREG else {
                throw GitWorktreeInitializationError.malformedOutput("authority evidence is not a regular file")
            }
            appendLengthPrefixed(Data("regular".utf8), to: &canonical)
            let data = try boundedRead(url, maximumBytes: maximumBytesPerFile)
            appendLengthPrefixed(data, to: &canonical)
        }
        return sha256Hex(canonical)
    }

    private nonisolated static func boundedAuthorityContentIdentity(
        at url: URL,
        maximumBytes: Int = 4 * 1024 * 1024
    ) throws -> GitWorkspaceAuthorityContentIdentity {
        var value = stat()
        if lstat(url.path, &value) != 0 {
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return GitWorkspaceAuthorityContentIdentity(
                exists: false,
                sha256: sha256Hex(Data("missing".utf8)),
                byteCount: 0
            )
        }
        guard value.st_mode & S_IFMT == S_IFREG else {
            throw GitWorktreeInitializationError.malformedOutput("configured authority path is not a regular file")
        }
        let data = try boundedRead(url, maximumBytes: maximumBytes)
        return GitWorkspaceAuthorityContentIdentity(
            exists: true,
            sha256: sha256Hex(data),
            byteCount: data.count
        )
    }

    private nonisolated static func boundedPrefixControlIdentities(
        layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        limits: GitWorktreeInitializationLimits
    ) throws -> [GitWorkspacePrefixControlIdentity] {
        let controlKinds: [String: GitWorkspacePrefixControlKind] = [
            ".gitignore": .gitignore,
            ".repo_ignore": .repoIgnore,
            ".cursorignore": .cursorIgnore,
            ".gitattributes": .gitAttributes
        ]
        let root = layout.workTreeRoot.standardizedFileURL
        let prefixRoot = prefix.value.isEmpty
            ? root
            : root.appendingPathComponent(prefix.value, isDirectory: true).standardizedFileURL
        var prefixIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: prefixRoot.path, isDirectory: &prefixIsDirectory),
              prefixIsDirectory.boolValue
        else {
            throw GitWorktreeInitializationError.malformedOutput("loaded-root prefix directory is unavailable")
        }

        var candidates: [String: GitWorkspacePrefixControlKind] = [:]
        func addCandidate(_ url: URL, kind: GitWorkspacePrefixControlKind) throws {
            let path = url.standardizedFileURL.path
            let rootPath = root.path
            guard path.hasPrefix(rootPath + "/") else {
                throw GitWorktreeInitializationError.malformedOutput("control path escapes repository root")
            }
            let relative = String(path.dropFirst(rootPath.count + 1))
            guard !relative.isEmpty,
                  relative.utf8.count <= limits.maximumPathUTF8Bytes,
                  relative.split(separator: "/", omittingEmptySubsequences: false).count <= limits.maximumPathDepth,
                  !relative.split(separator: "/", omittingEmptySubsequences: false)
                  .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            else {
                throw GitWorktreeInitializationError.pathLimitExceeded
            }
            candidates[relative] = kind
        }

        var ancestor = root
        let prefixComponents = prefix.value.isEmpty ? [] : prefix.value.split(separator: "/").map(String.init)
        for depth in 0 ... prefixComponents.count {
            for (name, kind) in controlKinds {
                let url = ancestor.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    try addCandidate(url, kind: kind)
                }
            }
            if depth < prefixComponents.count {
                ancestor.appendPathComponent(prefixComponents[depth], isDirectory: true)
            }
        }

        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: prefixRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw GitWorktreeInitializationError.malformedOutput("prefix control enumeration failed")
        }
        var inspectedCount = 0
        while let url = enumerator.nextObject() as? URL {
            inspectedCount += 1
            guard inspectedCount <= limits.maximumRecordCount else {
                throw GitWorktreeInitializationError.recordLimitExceeded
            }
            if url.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            guard let kind = controlKinds[url.lastPathComponent] else { continue }
            try addCandidate(url, kind: kind)
        }
        if let enumerationError { throw enumerationError }

        var result: [GitWorkspacePrefixControlIdentity] = []
        var totalBytes = 0
        for (relativePath, kind) in candidates.sorted(by: { $0.key < $1.key }) {
            let identity = try boundedAuthorityContentIdentity(
                at: root.appendingPathComponent(relativePath),
                maximumBytes: min(4 * 1024 * 1024, limits.maximumOutputBytes)
            )
            let addition = totalBytes.addingReportingOverflow(identity.byteCount)
            guard !addition.overflow, addition.partialValue <= limits.maximumOutputBytes else {
                throw GitWorktreeInitializationError.outputLimitExceeded
            }
            totalBytes = addition.partialValue
            result.append(GitWorkspacePrefixControlIdentity(
                repositoryRelativePath: relativePath,
                kind: kind,
                content: identity
            ))
        }
        return result
    }

    private nonisolated static func canonicalControlIdentityDigest(
        _ identities: [GitWorkspacePrefixControlIdentity]
    ) -> String {
        var data = Data()
        for identity in identities.sorted(by: { $0.repositoryRelativePath < $1.repositoryRelativePath }) {
            appendLengthPrefixed(Data(identity.repositoryRelativePath.utf8), to: &data)
            appendLengthPrefixed(Data(identity.kind.rawValue.utf8), to: &data)
            appendLengthPrefixed(canonicalContentIdentityData(identity.content), to: &data)
        }
        return sha256Hex(data)
    }

    private nonisolated static func canonicalOptionalContentIdentityData(
        _ identity: GitWorkspaceAuthorityContentIdentity?
    ) -> Data {
        guard let identity else { return Data("unset".utf8) }
        return canonicalContentIdentityData(identity)
    }

    private nonisolated static func canonicalContentIdentityData(
        _ identity: GitWorkspaceAuthorityContentIdentity
    ) -> Data {
        var data = Data()
        appendLengthPrefixed(Data(identity.exists ? "present".utf8 : "missing".utf8), to: &data)
        appendLengthPrefixed(Data(identity.sha256.utf8), to: &data)
        appendUInt64(UInt64(clamping: identity.byteCount), to: &data)
        return data
    }

    private nonisolated static func boundedRead(_ url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw GitWorktreeInitializationError.outputLimitExceeded
        }
        return data
    }

    private nonisolated static func appendLengthPrefixed(_ value: Data, to data: inout Data) {
        appendUInt64(UInt64(clamping: value.count), to: &data)
        data.append(value)
    }

    private nonisolated static func appendUInt64(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func gitAdmissionDeadline(
        after duration: Duration
    ) -> GitProcessAdmissionDeadline {
        let components = duration.components
        let seconds = UInt64(clamping: max(0, components.seconds))
        let attoseconds = UInt64(clamping: max(0, components.attoseconds))
        let secondsNanoseconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let nanoseconds = secondsNanoseconds.overflow
            ? UInt64.max
            : secondsNanoseconds.partialValue.addingReportingOverflow(attoseconds / 1_000_000_000).partialValue
        let now = DispatchTime.now().uptimeNanoseconds
        let deadline = now.addingReportingOverflow(nanoseconds)
        return GitProcessAdmissionDeadline(
            uptimeNanoseconds: deadline.overflow ? UInt64.max : deadline.partialValue
        )
    }

    private nonisolated func appendLiteralPrefix(
        _ prefix: GitRepositoryRelativeRootPrefix,
        to args: inout [String]
    ) {
        guard !prefix.value.isEmpty else { return }
        args.append("--")
        args.append(prefix.value)
    }

    func gitBlobObjectFormat(at repositoryRoot: URL) async throws -> GitObjectFormat {
        let (stdout, stderr, exitCode) = try await runGit(
            ["rev-parse", "--show-object-format"],
            at: repositoryRoot,
            admissionPriority: .codemapDemand,
            commandFamily: .codemapAuthority
        )
        guard exitCode == 0 else {
            throw GitBlobIdentityError.unsupportedGit(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let value: String = if stdout.hasSuffix("\n") {
            String(stdout.dropLast())
        } else {
            stdout
        }
        guard !value.isEmpty,
              !value.utf8.contains(0),
              value.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) })
        else {
            throw GitBlobIdentityError.invalidObjectFormat(stdout)
        }
        return try GitObjectFormat(gitValue: value)
    }

    func gitBlobObjectSize(in layout: GitRepositoryLayout, oid: GitBlobOID) async throws -> UInt64 {
        do {
            let (stdout, _, exitCode) = try await runGit(
                ["cat-file", "-s", oid.lowercaseHex],
                at: layout.workTreeRoot,
                stdoutByteLimit: Self.gitBlobSizeOutputByteLimit,
                stderrByteLimit: Self.gitBlobDiagnosticOutputByteLimit,
                repositoryBinding: .exactObjectRead(layout),
                admissionPriority: .codemapDemand,
                commandFamily: .codemapAuthority
            )
            guard exitCode == 0 else { throw GitBlobObjectReadError.unavailable }
            let value = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  value.utf8.allSatisfy({ (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) }),
                  let size = UInt64(value)
            else {
                throw GitBlobObjectReadError.malformedSize
            }
            return size
        } catch GitProcessCaptureError.stdoutByteLimitExceeded {
            throw GitBlobObjectReadError.stdoutLimitExceeded
        } catch GitProcessCaptureError.stderrByteLimitExceeded {
            throw GitBlobObjectReadError.stderrLimitExceeded
        }
    }

    func gitBlobObjectBytes(
        in layout: GitRepositoryLayout,
        oid: GitBlobOID,
        expectedByteCount: Int
    ) async throws -> Data {
        let (captureLimit, overflow) = expectedByteCount.addingReportingOverflow(1)
        guard expectedByteCount >= 0, !overflow else {
            throw GitBlobObjectReadError.stdoutLimitExceeded
        }
        do {
            let (stdout, _, exitCode) = try await runGitData(
                ["cat-file", "blob", oid.lowercaseHex],
                at: layout.workTreeRoot,
                stdoutByteLimit: captureLimit,
                stderrByteLimit: Self.gitBlobDiagnosticOutputByteLimit,
                repositoryBinding: .exactObjectRead(layout),
                admissionPriority: .codemapDemand,
                commandFamily: .codemapAuthority
            )
            guard exitCode == 0 else { throw GitBlobObjectReadError.unavailable }
            return stdout
        } catch GitProcessCaptureError.stdoutByteLimitExceeded {
            throw GitBlobObjectReadError.stdoutLimitExceeded
        } catch GitProcessCaptureError.stderrByteLimitExceeded {
            throw GitBlobObjectReadError.stderrLimitExceeded
        }
    }

    func gitBlobIndexEntries(
        at repositoryRoot: URL,
        repositoryRelativePaths: [String]
    ) async throws -> [GitBlobIndexEntry] {
        try Self.validateGitBlobPathBatch(repositoryRelativePaths)
        var args = ["ls-files", "--stage", "-v", "-z", "--"]
        args.append(contentsOf: repositoryRelativePaths)
        let (stdout, stderr, exitCode) = try await runGit(
            args,
            at: repositoryRoot,
            env: ["GIT_LITERAL_PATHSPECS": "1"],
            admissionPriority: .codemapDemand,
            commandFamily: .codemapAuthority
        )
        guard exitCode == 0 else {
            throw GitError(message: "git ls-files for blob identity failed: \(stderr)")
        }
        let requested = Set(repositoryRelativePaths)
        return try stdout
            .split(separator: "\0", omittingEmptySubsequences: true)
            .compactMap { raw -> GitBlobIndexEntry? in
                let record = String(raw)
                guard record.count >= 3 else {
                    throw GitBlobIdentityError.malformedGitOutput("short ls-files record")
                }
                let tag = record.first!
                let payload = record.dropFirst(2)
                guard let tab = payload.firstIndex(of: "\t") else {
                    throw GitBlobIdentityError.malformedGitOutput("ls-files record has no path separator")
                }
                let metadata = payload[..<tab].split(separator: " ", omittingEmptySubsequences: true)
                guard metadata.count == 3, let stage = Int(metadata[2]), (0 ... 3).contains(stage) else {
                    throw GitBlobIdentityError.malformedGitOutput("invalid ls-files stage record")
                }
                let path = String(payload[payload.index(after: tab)...])
                guard requested.contains(path) else { return nil }
                return GitBlobIndexEntry(
                    mode: String(metadata[0]),
                    oid: String(metadata[1]).lowercased(),
                    stage: stage,
                    path: path,
                    assumeUnchanged: tag.isLowercase,
                    skipWorktree: tag == "S" || tag == "s"
                )
            }
    }

    func gitBlobStatusRecords(
        at repositoryRoot: URL,
        repositoryRelativePaths: [String]
    ) async throws -> [GitPorcelainV2PathRecord] {
        try Self.validateGitBlobPathBatch(repositoryRelativePaths)
        var args = [
            "status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignored=matching", "--"
        ]
        args.append(contentsOf: repositoryRelativePaths)
        let (stdout, stderr, exitCode) = try await runGit(
            args,
            at: repositoryRoot,
            env: ["GIT_LITERAL_PATHSPECS": "1"],
            admissionPriority: .codemapDemand,
            commandFamily: .codemapAuthority
        )
        guard exitCode == 0 else {
            throw GitError(message: "git status for blob identity failed: \(stderr)")
        }
        let requested = Set(repositoryRelativePaths)
        return try GitStatusPorcelainV2Parser.parse(stdout).pathRecords.filter { record in
            requested.contains(record.path) || {
                if case let .renamedOrCopied(originalPath, _) = record.kind {
                    return requested.contains(originalPath)
                }
                return false
            }()
        }
    }

    func gitBlobAttributes(
        at repositoryRoot: URL,
        repositoryRelativePaths: [String]
    ) async throws -> [String: GitBlobPathAttributes] {
        try Self.validateGitBlobPathBatch(repositoryRelativePaths)
        let relevantAttributes = ["text", "eol", "filter", "ident", "working-tree-encoding"]
        let relevantAttributeSet = Set(relevantAttributes)
        let args = ["check-attr", "-z", "--all", "--stdin"]
        let stdout: String
        let stderr: String
        let exitCode: Int32
        do {
            (stdout, stderr, exitCode) = try await runGit(
                args,
                at: repositoryRoot,
                env: ["GIT_LITERAL_PATHSPECS": "1"],
                stdin: makePathspecStdinData(repositoryRelativePaths),
                stdoutByteLimit: Self.gitCheckAttrOutputByteLimit,
                admissionPriority: .codemapDemand,
                commandFamily: .codemapAuthority
            )
        } catch GitProcessCaptureError.stdoutByteLimitExceeded {
            throw GitBlobIdentityError.malformedGitOutput("check-attr output exceeds byte limit")
        }
        guard exitCode == 0 else {
            throw GitError(message: "git check-attr for blob identity failed: \(stderr)")
        }
        guard stdout.utf8.count <= Self.gitCheckAttrOutputByteLimit else {
            throw GitBlobIdentityError.malformedGitOutput("check-attr output exceeds byte limit")
        }
        let fields = stdout.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        let completeFieldCount = fields.last == "" ? fields.count - 1 : fields.count
        guard completeFieldCount.isMultiple(of: 3), completeFieldCount / 3 <= 4096 else {
            throw GitBlobIdentityError.malformedGitOutput("invalid or oversized check-attr record set")
        }
        let requestedPaths = Set(repositoryRelativePaths)
        var relevantRecordCount = 0
        var raw: [String: [String: GitAttributeState]] = [:]
        if completeFieldCount > 0 {
            for index in stride(from: 0, to: completeFieldCount, by: 3) {
                let path = fields[index]
                let attribute = fields[index + 1]
                guard requestedPaths.contains(path) else {
                    throw GitBlobIdentityError.malformedGitOutput("unexpected check-attr path")
                }
                guard relevantAttributeSet.contains(attribute) else { continue }
                relevantRecordCount += 1
                guard relevantRecordCount <= repositoryRelativePaths.count * relevantAttributes.count else {
                    throw GitBlobIdentityError.malformedGitOutput("oversized relevant check-attr record set")
                }
                let state: GitAttributeState = switch fields[index + 2] {
                case "unset": .unset
                case "set": .set("")
                default: .set(fields[index + 2])
                }
                raw[path, default: [:]][attribute] = state
            }
        }
        var result: [String: GitBlobPathAttributes] = [:]
        for path in repositoryRelativePaths {
            let values = raw[path] ?? [:]
            result[path] = GitBlobPathAttributes(
                text: values["text"] ?? .unspecified,
                eol: values["eol"] ?? .unspecified,
                filter: values["filter"] ?? .unspecified,
                ident: values["ident"] ?? .unspecified,
                workingTreeEncoding: values["working-tree-encoding"] ?? .unspecified
            )
        }
        return result
    }

    func gitBlobCheckoutConfiguration(at repositoryRoot: URL) async throws -> GitBlobCheckoutConfiguration {
        async let autoCRLFResult = runGit(
            ["config", "--get", "core.autocrlf"],
            at: repositoryRoot,
            admissionPriority: .codemapDemand,
            commandFamily: .codemapAuthority
        )
        async let eolResult = runGit(
            ["config", "--get", "core.eol"],
            at: repositoryRoot,
            admissionPriority: .codemapDemand,
            commandFamily: .codemapAuthority
        )
        async let filtersResult = runGit(
            ["config", "--null", "--get-regexp", "^filter\\..*\\.(clean|smudge|process|required)$"],
            at: repositoryRoot,
            admissionPriority: .codemapDemand,
            commandFamily: .codemapAuthority
        )
        let (autoCRLF, eol, filters) = try await (autoCRLFResult, eolResult, filtersResult)
        func optionalValue(_ result: (String, String, Int32), name: String) throws -> String? {
            if result.2 == 1 { return nil }
            guard result.2 == 0 else {
                throw GitError(message: "git config --get \(name) failed: \(result.1)")
            }
            let value = result.0.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value.lowercased()
        }
        var drivers: [String: String] = [:]
        if filters.2 != 1 {
            guard filters.2 == 0 else {
                throw GitError(message: "git config filter query failed: \(filters.1)")
            }
            for record in filters.0.split(separator: "\0", omittingEmptySubsequences: true) {
                let value = String(record)
                guard let separator = value.firstIndex(where: { $0 == "\n" || $0 == " " }) else {
                    throw GitBlobIdentityError.malformedGitOutput("invalid filter configuration record")
                }
                drivers[String(value[..<separator]).lowercased()] = String(value[value.index(after: separator)...])
            }
        }
        return try GitBlobCheckoutConfiguration(
            coreAutoCRLF: optionalValue(autoCRLF, name: "core.autocrlf"),
            coreEOL: optionalValue(eol, name: "core.eol"),
            filterDriverConfiguration: drivers
        )
    }

    func gitCodemapAuthorityConfiguration(at repositoryRoot: URL) async throws
        -> GitCodemapAuthorityConfiguration
    {
        async let checkout = gitBlobCheckoutConfiguration(at: repositoryRoot)
        async let attributesFile = runGit(
            ["config", "--path", "--get", "core.attributesFile"],
            at: repositoryRoot,
            admissionPriority: .codemapDemand,
            commandFamily: .codemapAuthority
        )
        async let sparseCheckout = runGit(
            ["config", "--bool", "--get", "core.sparseCheckout"],
            at: repositoryRoot,
            admissionPriority: .codemapDemand,
            commandFamily: .codemapAuthority
        )
        async let sparseCone = runGit(
            ["config", "--bool", "--get", "core.sparseCheckoutCone"],
            at: repositoryRoot,
            admissionPriority: .codemapDemand,
            commandFamily: .codemapAuthority
        )
        let (checkoutValue, attributesResult, sparseResult, coneResult) = try await (
            checkout, attributesFile, sparseCheckout, sparseCone
        )

        func optionalValue(_ result: (String, String, Int32), name: String) throws -> String? {
            if result.2 == 1 { return nil }
            guard result.2 == 0 else {
                throw GitError(message: "git config --get \(name) failed")
            }
            let value = result.0.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        func booleanValue(_ result: (String, String, Int32), name: String) throws -> Bool {
            guard let value = try optionalValue(result, name: name)?.lowercased() else { return false }
            switch value {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default:
                throw GitBlobIdentityError.malformedGitOutput("invalid boolean Git configuration")
            }
        }

        return try GitCodemapAuthorityConfiguration(
            checkout: checkoutValue,
            attributesFilePath: optionalValue(attributesResult, name: "core.attributesFile"),
            sparseCheckoutEnabled: booleanValue(sparseResult, name: "core.sparseCheckout"),
            sparseCheckoutConeEnabled: booleanValue(coneResult, name: "core.sparseCheckoutCone")
        )
    }

    private nonisolated static func validateGitBlobPathBatch(_ paths: [String]) throws {
        guard !paths.isEmpty, paths.count <= 256 else {
            throw GitBlobIdentityError.batchTooLarge
        }
        var bytes = 0
        for path in paths {
            let count = path.utf8.count
            guard count <= 256 * 1024 - bytes else {
                throw GitBlobIdentityError.batchTooLarge
            }
            bytes += count
            guard !path.isEmpty, !path.utf8.contains(0) else {
                throw GitBlobIdentityError.invalidRelativePath
            }
        }
    }

    /// Summary of a commit for log output.
    struct CommitSummary {
        let sha: String
        let shortSHA: String
        let author: String
        let dateISO: String
        let message: String
        let filesChanged: Int
        let insertions: Int
        let deletions: Int
    }

    /// Get commit log summaries with stats.
    func getLogSummaries(
        count: Int,
        path: String? = nil,
        at repoURL: URL
    ) async throws -> [CommitSummary] {
        // Use a custom format with a separator to parse commits
        // Format: __C__<sha>\t<short>\t<author>\t<date>\t<subject>
        // Followed by --numstat lines
        var args = [
            "log",
            "-n", "\(count)",
            "--date=iso-strict",
            "--pretty=format:__C__%H%x09%h%x09%an%x09%ad%x09%s",
            "--numstat",
            "--no-ext-diff",
            "--no-textconv",
            "--color=never"
        ]
        if let path, !path.isEmpty {
            args.append("--")
            args.append(path)
        }

        let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
        guard exitCode == 0 else {
            throw GitError(message: "git log failed: \(stderr)")
        }

        return parseLogSummaries(stdout)
    }

    private func parseLogSummaries(_ output: String) -> [CommitSummary] {
        var results: [CommitSummary] = []
        let blocks = output.components(separatedBy: "__C__").filter { !$0.isEmpty }

        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            guard let headerLine = lines.first else { continue }

            let headerParts = headerLine.split(separator: "\t", maxSplits: 4).map(String.init)
            guard headerParts.count >= 5 else { continue }

            let sha = headerParts[0]
            let shortSHA = headerParts[1]
            let author = headerParts[2]
            let dateISO = headerParts[3]
            let message = headerParts[4]

            // Parse numstat lines for this commit
            var filesChanged = 0
            var insertions = 0
            var deletions = 0

            for i in 1 ..< lines.count {
                let line = lines[i].trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard parts.count >= 2 else { continue }

                filesChanged += 1
                if let adds = Int(parts[0]) {
                    insertions += adds
                }
                if let dels = Int(parts[1]) {
                    deletions += dels
                }
            }

            results.append(CommitSummary(
                sha: sha,
                shortSHA: shortSHA,
                author: author,
                dateISO: dateISO,
                message: message,
                filesChanged: filesChanged,
                insertions: insertions,
                deletions: deletions
            ))
        }

        return results
    }

    /// Detailed commit info for `show` operation.
    struct CommitInfo {
        let sha: String
        let shortSHA: String
        let author: String
        let dateISO: String
        let message: String
    }

    /// Get commit info (metadata only, no diff).
    func commitInfo(ref: String, at repoURL: URL) async throws -> CommitInfo {
        let args = [
            "show",
            "-s",
            "--date=iso-strict",
            "--format=%H%x09%h%x09%an%x09%ad%x09%B",
            "--no-ext-diff",
            "--no-textconv",
            "--color=never",
            ref
        ]
        let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
        guard exitCode == 0 else {
            throw GitError(message: "git show failed: \(stderr)")
        }

        let parts = stdout.split(separator: "\t", maxSplits: 4).map(String.init)
        guard parts.count >= 5 else {
            throw GitError(message: "Unexpected git show output format")
        }

        return CommitInfo(
            sha: parts[0],
            shortSHA: parts[1],
            author: parts[2],
            dateISO: parts[3],
            message: parts[4].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// A single line of blame output.
    struct BlameLine {
        let line: Int
        let sha: String
        let author: String
        let dateISO: String
        let content: String
    }

    /// Get blame for a file, optionally for a specific line range.
    func blame(
        path: String,
        lineRange: ClosedRange<Int>? = nil,
        at repoURL: URL
    ) async throws -> [BlameLine] {
        var args = [
            "blame",
            "--line-porcelain"
        ]
        if let range = lineRange {
            args.append("-L")
            args.append("\(range.lowerBound),\(range.upperBound)")
        }
        args.append("--")
        args.append(path)

        let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
        guard exitCode == 0 else {
            throw GitError(message: "git blame failed: \(stderr)")
        }

        return parseBlameOutput(stdout)
    }

    private func parseBlameOutput(_ output: String) -> [BlameLine] {
        var results: [BlameLine] = []
        let lines = output.components(separatedBy: "\n")

        var currentSHA: String?
        var currentAuthor: String?
        var currentAuthorTime: String?
        var currentLineNum: Int?
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // First line of a block: <sha> <origLine> <finalLine> [<numLines>]
            if line.count >= 40, !line.hasPrefix("\t") {
                let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
                if parts.count >= 3, parts[0].count == 40 {
                    currentSHA = parts[0]
                    currentLineNum = Int(parts[2])
                }
            } else if line.hasPrefix("author ") {
                currentAuthor = String(line.dropFirst("author ".count))
            } else if line.hasPrefix("author-time ") {
                // Unix timestamp
                if let timestamp = Int(line.dropFirst("author-time ".count)) {
                    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime]
                    currentAuthorTime = formatter.string(from: date)
                }
            } else if line.hasPrefix("\t") {
                // Content line
                let content = String(line.dropFirst())
                if let sha = currentSHA,
                   let author = currentAuthor,
                   let time = currentAuthorTime,
                   let lineNum = currentLineNum
                {
                    results.append(BlameLine(
                        line: lineNum,
                        sha: String(sha.prefix(7)),
                        author: author,
                        dateISO: time,
                        content: content
                    ))
                }
            }

            i += 1
        }

        return results
    }

    // MARK: - Private Implementation

    // Use AsyncStream to collect pipe output without locks/queues per chunk

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func mergedProcessEnvironment(
        baseEnvironment: [String: String],
        shellEnvironment: [String: String]
    ) -> [String: String] {
        var environment = baseEnvironment
        environment.merge(shellEnvironment) { _, new in new }
        return environment
    }

    nonisolated static func friendlyErrorDescription(for rawMessage: String) -> String {
        let lowercased = rawMessage.lowercased()
        guard lowercased.contains("git-lfs"), lowercased.contains("command not found") else {
            return rawMessage
        }

        let action = if lowercased.hasPrefix("git diff") {
            "Git diff"
        } else if lowercased.hasPrefix("git fetch") {
            "Git fetch"
        } else if lowercased.hasPrefix("git status") {
            "Git status"
        } else {
            "Git"
        }

        return "\(action) couldn’t launch git-lfs from RepoPrompt’s subprocess environment. If git-lfs is installed, restart RepoPrompt and make sure it’s available from your login shell PATH.\n\nRaw error: \(rawMessage)"
    }

    private func processEnvironment() async -> [String: String] {
        if let preparedBaseProcessEnvironment {
            return preparedBaseProcessEnvironment
        }
        let shellEnvironment = await CLIEnvironmentCache.shared.environment(enableLogging: false)
        let environment = Self.mergedProcessEnvironment(
            baseEnvironment: inheritedProcessEnvironment,
            shellEnvironment: shellEnvironment
        )
        preparedBaseProcessEnvironment = environment
        return environment
    }

    nonisolated static func isVerifiedReadOnlyGitOperation(_ args: [String]) -> Bool {
        guard let command = args.first else { return false }
        switch command {
        case "rev-parse", "status", "ls-files", "ls-tree", "diff", "diff-tree", "check-attr", "merge-base", "merge-tree",
             "show-ref", "for-each-ref", "log", "rev-list", "show", "blame", "cat-file":
            return true
        case "worktree":
            return args.dropFirst().first == "list"
        case "symbolic-ref":
            return args.contains("--short") && args.last == "HEAD"
        case "branch":
            return args == ["branch", "--show-current"]
        case "config":
            return args.contains("--get") || args.contains("--get-regexp")
        default:
            if command == "--git-dir", let configIndex = args.firstIndex(of: "config") {
                return args[configIndex...].contains("--get")
            }
            return false
        }
    }

    private func withWorkspaceAuthorityMutation<T>(
        at repoURL: URL,
        kind: GitWorkspaceMutationKind,
        correlationID: UUID? = nil,
        operation: () async throws -> T
    ) async throws -> T {
        guard let layout = getLayout(for: repoURL) else {
            return try await operation()
        }
        let token = await workspaceStateAuthority.beginMutation(
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: layout),
            kind: kind,
            correlationID: correlationID
        )
        do {
            let value = try await operation()
            await workspaceStateAuthority.finishMutation(token, outcome: .succeeded)
            return value
        } catch is CancellationError {
            await workspaceStateAuthority.finishMutation(token, outcome: .cancelled)
            throw CancellationError()
        } catch {
            await workspaceStateAuthority.finishMutation(token, outcome: .failed)
            throw error
        }
    }

    private func runGit(
        _ args: [String],
        at repoURL: URL,
        env: [String: String] = [:],
        stdin: Data? = nil,
        requiresRepoContext: Bool = true,
        budgetRepoURL: URL? = nil,
        stdoutByteLimit: Int? = nil,
        stderrByteLimit: Int? = nil,
        repositoryBinding: GitProcessRepositoryBinding = .inferred,
        admissionPriority: GitProcessAdmissionPriority = .userInitiatedAuthority,
        admissionDeadline: GitProcessAdmissionDeadline? = nil,
        commandFamily: GitProcessCommandFamily? = nil,
        commandTimeout: Duration = GitService.gitProcessTimeout
    ) async throws -> (String, String, Int32) {
        let (stdout, stderr, exitCode) = try await runGitData(
            args,
            at: repoURL,
            env: env,
            stdin: stdin,
            requiresRepoContext: requiresRepoContext,
            budgetRepoURL: budgetRepoURL,
            stdoutByteLimit: stdoutByteLimit,
            stderrByteLimit: stderrByteLimit,
            repositoryBinding: repositoryBinding,
            admissionPriority: admissionPriority,
            admissionDeadline: admissionDeadline,
            commandFamily: commandFamily,
            commandTimeout: commandTimeout
        )
        return (
            String(data: stdout, encoding: .utf8) ?? "",
            String(data: stderr, encoding: .utf8) ?? "",
            exitCode
        )
    }

    private func runGitData(
        _ args: [String],
        at repoURL: URL,
        env: [String: String] = [:],
        stdin: Data? = nil,
        requiresRepoContext: Bool = true,
        budgetRepoURL: URL? = nil,
        stdoutByteLimit: Int? = nil,
        stderrByteLimit: Int? = nil,
        repositoryBinding: GitProcessRepositoryBinding = .inferred,
        admissionPriority: GitProcessAdmissionPriority = .userInitiatedAuthority,
        admissionDeadline: GitProcessAdmissionDeadline? = nil,
        commandFamily: GitProcessCommandFamily? = nil,
        commandTimeout: Duration = GitService.gitProcessTimeout
    ) async throws -> (Data, Data, Int32) {
        var environment = await processEnvironment()
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        if Self.isVerifiedReadOnlyGitOperation(args) {
            environment["GIT_OPTIONAL_LOCKS"] = "0"
        }

        switch repositoryBinding {
        case .inferred:
            // For gitfile worktrees, inject GIT_DIR and GIT_WORK_TREE to ensure
            // git commands operate in the correct context.
            // Skip for commands that don't need repo context (e.g., --no-index diffs).
            if requiresRepoContext, let layout = getLayout(for: repoURL), layout.isWorktree {
                environment["GIT_DIR"] = layout.gitDir.path
                environment["GIT_WORK_TREE"] = layout.workTreeRoot.path
            }
            environment.merge(env) { _, new in new }
        case let .exactObjectRead(layout):
            environment.merge(env) { _, new in new }
            environment = Self.capabilityBoundObjectReadEnvironment(
                baseEnvironment: environment,
                layout: layout
            )
        case let .exactWorktree(layout):
            environment.merge(env) { _, new in new }
            environment = Self.exactWorktreeEnvironment(
                baseEnvironment: environment,
                layout: layout
            )
        }

        let budgetURL = budgetRepoURL ?? repoURL
        let repositoryKey = switch repositoryBinding {
        case .inferred:
            getLayout(for: budgetURL)?.commonDir.standardizedFileURL.path
                ?? budgetURL.standardizedFileURL.path
        case let .exactObjectRead(layout):
            layout.commonDir.standardizedFileURL.path
        case let .exactWorktree(layout):
            layout.commonDir.standardizedFileURL.path
        }
        let lease = try await processAdmissionController.acquire(
            repositoryKey: repositoryKey,
            priority: admissionPriority,
            deadline: admissionDeadline
        )
        do {
            try Task.checkCancellation()
            let result = try await runAdmittedGitData(
                args,
                at: repoURL,
                environment: environment,
                stdin: stdin,
                diagnosticRepositoryPath: budgetURL.standardizedFileURL.path,
                processQueueWaitMicroseconds: lease.queueWaitMicroseconds,
                stdoutByteLimit: stdoutByteLimit,
                stderrByteLimit: stderrByteLimit,
                admissionPriority: admissionPriority,
                commandFamily: commandFamily ?? Self.commandFamily(for: args),
                commandTimeout: commandTimeout
            )
            await processAdmissionController.release(lease)
            return result
        } catch {
            await processAdmissionController.release(lease)
            try Task.checkCancellation()
            throw error
        }
    }

    private nonisolated static func capabilityBoundObjectReadEnvironment(
        baseEnvironment: [String: String],
        layout: GitRepositoryLayout
    ) -> [String: String] {
        var environment = baseEnvironment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_DIR"] = layout.gitDir.standardizedFileURL.path
        environment["GIT_COMMON_DIR"] = layout.commonDir.standardizedFileURL.path
        environment["GIT_WORK_TREE"] = layout.workTreeRoot.standardizedFileURL.path
        environment["GIT_OBJECT_DIRECTORY"] = layout.commonDir
            .appendingPathComponent("objects", isDirectory: true)
            .standardizedFileURL.path
        environment["GIT_INDEX_FILE"] = layout.gitDir
            .appendingPathComponent("index")
            .standardizedFileURL.path
        environment["GIT_NO_LAZY_FETCH"] = "1"
        environment["GIT_NO_REPLACE_OBJECTS"] = "1"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_LITERAL_PATHSPECS"] = "1"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_COUNT"] = "0"
        environment["GIT_PROTOCOL_FROM_USER"] = "0"
        environment["GIT_ALLOW_PROTOCOL"] = ""
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        return environment
    }

    private nonisolated static func exactWorktreeEnvironment(
        baseEnvironment: [String: String],
        layout: GitRepositoryLayout
    ) -> [String: String] {
        var environment = baseEnvironment
        environment["GIT_DIR"] = layout.gitDir.standardizedFileURL.path
        environment["GIT_COMMON_DIR"] = layout.commonDir.standardizedFileURL.path
        environment["GIT_WORK_TREE"] = layout.workTreeRoot.standardizedFileURL.path
        environment["GIT_INDEX_FILE"] = layout.gitDir
            .appendingPathComponent("index")
            .standardizedFileURL.path
        environment["GIT_LITERAL_PATHSPECS"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        return environment
    }

    private nonisolated static func commandFamily(for args: [String]) -> GitProcessCommandFamily {
        guard let command = args.first else { return .repositoryRead }
        switch command {
        case "status": return .status
        case "ls-files": return .indexManifest
        case "ls-tree": return .treeInventory
        case "diff-tree": return .treeDelta
        case "rev-parse": return .treeResolution
        default:
            return isVerifiedReadOnlyGitOperation(args) ? .repositoryRead : .mutation
        }
    }

    private func runAdmittedGitData(
        _ args: [String],
        at repoURL: URL,
        environment: [String: String],
        stdin: Data?,
        diagnosticRepositoryPath: String,
        processQueueWaitMicroseconds: Int,
        stdoutByteLimit: Int?,
        stderrByteLimit: Int?,
        admissionPriority: GitProcessAdmissionPriority,
        commandFamily: GitProcessCommandFamily,
        commandTimeout: Duration
    ) async throws -> (Data, Data, Int32) {
        #if DEBUG
            let benchmarkMetricTag = WorktreeStartupInstrumentation.currentBenchmarkMetricTag
        #endif
        let process = Process()
        let timeoutController = GitProcessTimeoutController()
        let lifecycleController = GitProcessLifecycleController()
        let commandRecorder = MCPToolWorkCountDiagnostics.gitCommandRecorder()
        process.executableURL = gitExecutableURL
        process.arguments = args
        process.currentDirectoryURL = repoURL
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var inPipe: Pipe?
        if let _ = stdin {
            let p = Pipe()
            process.standardInput = p
            inPipe = p
            // Suppress SIGPIPE on this write FD so closed readers won’t crash the app
            let fd = p.fileHandleForWriting.fileDescriptor
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        }

        // Build async streams for stdout/stderr and single consumer tasks to collect data.
        // GitProcessPipeDrain serializes readability callbacks with termination/cancellation
        // so a final chunk cannot be read by a callback and then dropped after stream closure.
        let (outStream, outDrain) = try GitProcessPipeDrain.makeStream(
            readingFrom: outPipe.fileHandleForReading,
            byteLimit: stdoutByteLimit
        )
        let (errStream, errDrain) = try GitProcessPipeDrain.makeStream(
            readingFrom: errPipe.fileHandleForReading,
            byteLimit: stderrByteLimit
        )

        let processMetrics = GitProcessMetricsBox()
        let commandStartedAt = DispatchTime.now().uptimeNanoseconds
        let outCollector = Task(priority: .userInitiated) { () -> Data in
            var buf = Data()
            for await chunk in outStream {
                if !chunk.isEmpty { buf.append(chunk) }
            }
            return buf
        }
        let errCollector = Task(priority: .userInitiated) { () -> Data in
            var buf = Data()
            for await chunk in errStream {
                if !chunk.isEmpty { buf.append(chunk) }
            }
            return buf
        }

        let result = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<(Data, Data, Int32), any Error>) in
                // Drain stdout
                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    if outDrain.consumeAvailableData() {
                        handle.readabilityHandler = nil
                    }
                    if outDrain.didExceedByteLimit {
                        lifecycleController.requestCancellation(
                            process: process,
                            terminationGrace: self.processTerminationGrace
                        )
                    }
                }
                // Drain stderr
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    if errDrain.consumeAvailableData() {
                        handle.readabilityHandler = nil
                    }
                    if errDrain.didExceedByteLimit {
                        lifecycleController.requestCancellation(
                            process: process,
                            terminationGrace: self.processTerminationGrace
                        )
                    }
                }

                process.terminationHandler = { proc in
                    lifecycleController.didTerminate()
                    timeoutController.cancel()

                    // Stop handlers to break strong reference cycles
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil

                    // Drain bytes that arrived between the last readability callback and
                    // process termination, then close each stream after any in-flight callback.
                    outDrain.finishReading()
                    errDrain.finishReading()

                    Task {
                        let stdoutData = await outCollector.value
                        let stderrData = await errCollector.value

                        commandRecorder(
                            diagnosticRepositoryPath,
                            args,
                            processQueueWaitMicroseconds,
                            processMetrics.spawnMicroseconds,
                            stdoutData.count + stderrData.count
                        )

                        let commandFinishedAt = DispatchTime.now().uptimeNanoseconds
                        WorktreeStartupInstrumentation.recordGitCommand(
                            family: commandFamily,
                            priority: admissionPriority,
                            queueWaitMicroseconds: processQueueWaitMicroseconds,
                            durationMicroseconds: Int(
                                clamping: commandFinishedAt >= commandStartedAt
                                    ? (commandFinishedAt - commandStartedAt) / 1000
                                    : 0
                            ),
                            outputByteCount: stdoutData.count + stderrData.count,
                            cancelled: lifecycleController.cancellationErrorIfRequested() != nil
                        )
                        #if DEBUG
                            WorktreeStartupInstrumentation.recordBenchmarkGitCommand(
                                tag: benchmarkMetricTag,
                                family: commandFamily,
                                priority: admissionPriority,
                                queueWaitMicroseconds: processQueueWaitMicroseconds,
                                durationMicroseconds: Int(
                                    clamping: commandFinishedAt >= commandStartedAt
                                        ? (commandFinishedAt - commandStartedAt) / 1000
                                        : 0
                                ),
                                outputByteCount: stdoutData.count + stderrData.count,
                                cancelled: lifecycleController.cancellationErrorIfRequested() != nil
                            )
                        #endif

                        if timeoutController.didTimeOut {
                            continuation.resume(throwing: GitProcessCaptureError.timedOut)
                            return
                        }

                        if outDrain.didExceedByteLimit {
                            continuation.resume(throwing: GitProcessCaptureError.stdoutByteLimitExceeded)
                            return
                        }
                        if errDrain.didExceedByteLimit {
                            continuation.resume(throwing: GitProcessCaptureError.stderrByteLimitExceeded)
                            return
                        }

                        continuation.resume(returning: (stdoutData, stderrData, proc.terminationStatus))
                    }
                }

                do {
                    try lifecycleController.checkCancellationBeforeSpawn()
                    let spawnStart = DispatchTime.now().uptimeNanoseconds
                    try process.run()
                    let processIdentifier = process.processIdentifier
                    let spawnState = lifecycleController.didSpawn(
                        process: process,
                        processIdentifier: processIdentifier,
                        terminationGrace: processTerminationGrace
                    )
                    if spawnState == .running {
                        timeoutController.schedule(
                            process: process,
                            processIdentifier: processIdentifier,
                            timeout: commandTimeout,
                            terminationGrace: processTerminationGrace
                        )
                        if !lifecycleController.shouldKeepNormalTimeout() {
                            timeoutController.cancel()
                        }
                    }
                    let spawnEnd = DispatchTime.now().uptimeNanoseconds
                    processMetrics.spawnMicroseconds = Int(
                        clamping: spawnEnd >= spawnStart ? (spawnEnd - spawnStart) / 1000 : 0
                    )

                    // If stdin data was provided, write it after the process starts.
                    // Use raw FD writes via FDWriteSupport instead of FileHandle.write()
                    // because FileHandle.write() throws ObjC NSFileHandleOperationException
                    // on broken pipe, which Swift do/catch cannot intercept.
                    // If the write fails (e.g. child exited early or task was cancelled),
                    // we still let the process terminate normally so stderr and exit code
                    // are collected — this preserves fallback logic in runDiff.
                    if let stdin {
                        if let inPipe {
                            let fd = inPipe.fileHandleForWriting.fileDescriptor
                            do {
                                try FDWriteSupport.writeAll(stdin, to: fd)
                            } catch {
                                // Broken pipe / bad fd — child exited early or was terminated.
                                // Swallow the error; the process termination handler will
                                // still collect stdout, stderr, and exit code normally.
                                // This preserves runDiff's pathspec fallback behavior.
                            }
                            inPipe.fileHandleForWriting.closeFile()
                        }
                    }
                } catch {
                    commandRecorder(
                        diagnosticRepositoryPath,
                        args,
                        processQueueWaitMicroseconds,
                        processMetrics.spawnMicroseconds,
                        0
                    )
                    let commandFinishedAt = DispatchTime.now().uptimeNanoseconds
                    WorktreeStartupInstrumentation.recordGitCommand(
                        family: commandFamily,
                        priority: admissionPriority,
                        queueWaitMicroseconds: processQueueWaitMicroseconds,
                        durationMicroseconds: Int(
                            clamping: commandFinishedAt >= commandStartedAt
                                ? (commandFinishedAt - commandStartedAt) / 1000
                                : 0
                        ),
                        outputByteCount: 0,
                        cancelled: lifecycleController.cancellationErrorIfRequested() != nil
                    )
                    #if DEBUG
                        WorktreeStartupInstrumentation.recordBenchmarkGitCommand(
                            tag: benchmarkMetricTag,
                            family: commandFamily,
                            priority: admissionPriority,
                            queueWaitMicroseconds: processQueueWaitMicroseconds,
                            durationMicroseconds: Int(
                                clamping: commandFinishedAt >= commandStartedAt
                                    ? (commandFinishedAt - commandStartedAt) / 1000
                                    : 0
                            ),
                            outputByteCount: 0,
                            cancelled: lifecycleController.cancellationErrorIfRequested() != nil
                        )
                    #endif
                    // Ensure handlers and collectors are released when launch fails.
                    timeoutController.cancel()
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    outDrain.cancel()
                    errDrain.cancel()
                    continuation.resume(throwing: lifecycleController.cancellationErrorIfRequested() ?? error)
                }
            }
        }, onCancel: {
            timeoutController.cancel()
            // Keep stdout/stderr drains active until termination. A child may flush more than
            // pipe capacity while handling SIGTERM; closing the drains here can block that
            // flush forever and prevent the termination handler from reaping the process.
            lifecycleController.requestCancellation(
                process: process,
                terminationGrace: processTerminationGrace
            )
        })
        try Task.checkCancellation()
        return result
    }

    static func shouldFallbackFromWorktreeListZError(_ stderr: String) -> Bool {
        let lowercased = stderr.lowercased()
        return lowercased.contains("unknown option")
            || lowercased.contains("unknown switch")
            || lowercased.contains("invalid option")
            || lowercased.contains("usage: git worktree")
    }

    private func resolveMainWorktreeRoot(
        for layout: GitRepositoryLayout,
        at repoURL: URL
    ) async -> URL? {
        if let knownRoot = layout.knownMainWorktreeRoot {
            return knownRoot
        }

        let queries: [(arguments: [String], directory: URL, requiresRepoContext: Bool)] = [
            (["config", "--path", "--get", "core.worktree"], repoURL, true),
            (["--git-dir", layout.commonDir.path, "config", "--worktree", "--path", "--get", "core.worktree"], layout.commonDir, false)
        ]
        for query in queries {
            guard let result = try? await runGit(
                query.arguments,
                at: query.directory,
                requiresRepoContext: query.requiresRepoContext
            ), result.2 == 0
            else {
                continue
            }
            let rawPath = result.0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawPath.isEmpty else { continue }

            let candidate = if rawPath.hasPrefix("/") {
                URL(fileURLWithPath: rawPath).standardizedFileURL
            } else {
                layout.commonDir.appendingPathComponent(rawPath).standardizedFileURL
            }
            guard let candidateLayout = getLayout(for: candidate),
                  !candidateLayout.isLinkedWorktree,
                  candidateLayout.commonDir.standardizedFileURL.path == layout.commonDir.standardizedFileURL.path
            else {
                continue
            }
            return candidate
        }
        return nil
    }

    private func normalizedWorktreeRecords(
        _ records: [GitWorktreePorcelainRecord],
        currentLayout: GitRepositoryLayout?,
        resolvedMainRoot: URL?
    ) -> [GitWorktreePorcelainRecord] {
        guard let currentLayout else { return records }
        let commonGitDirPath = currentLayout.commonDir.standardizedFileURL.path

        return records.compactMap { record in
            let recordPath = URL(fileURLWithPath: record.path).standardizedFileURL.path
            guard recordPath == commonGitDirPath else {
                return record
            }
            guard let resolvedMainRoot else {
                return nil
            }
            var normalized = record
            normalized.path = resolvedMainRoot.standardizedFileURL.path
            return normalized
        }
    }

    private func makeWorktreeDescriptors(
        from records: [GitWorktreePorcelainRecord],
        currentRepoURL: URL
    ) async throws -> [GitWorktreeDescriptor] {
        let currentLayout = getLayout(for: currentRepoURL)
        let resolvedMainRoot: URL? = if let currentLayout {
            await resolveMainWorktreeRoot(for: currentLayout, at: currentRepoURL)
        } else {
            nil
        }
        let worktreeRecords = normalizedWorktreeRecords(
            records.filter { !$0.isBare },
            currentLayout: currentLayout,
            resolvedMainRoot: resolvedMainRoot
        )
        guard !worktreeRecords.isEmpty else { return [] }

        let layoutsByPath: [String: GitRepositoryLayout] = Dictionary(
            uniqueKeysWithValues: worktreeRecords.compactMap { record -> (String, GitRepositoryLayout)? in
                let pathURL = URL(fileURLWithPath: record.path)
                guard let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: pathURL) else {
                    return nil
                }
                return (pathURL.standardizedFileURL.path, layout)
            }
        )

        let commonGitDir = currentLayout?.commonDir
            ?? layoutsByPath.values.first?.commonDir
        guard let commonGitDir else {
            throw GitError(message: "git worktree list succeeded but repository layout could not be resolved")
        }

        let discoveredMainRoot = worktreeRecords.first { record in
            let path = URL(fileURLWithPath: record.path).standardizedFileURL.path
            return layoutsByPath[path].map { !$0.isLinkedWorktree } ?? false
        }.map { URL(fileURLWithPath: $0.path).standardizedFileURL }
        let mainURL = resolvedMainRoot ?? discoveredMainRoot
        let repository = GitWorktreeIdentity.repositoryIdentity(
            commonGitDir: commonGitDir,
            mainWorktreeRoot: mainURL
        )
        let currentPath = currentRepoURL.standardizedFileURL.path

        return worktreeRecords.map { record in
            let pathURL = URL(fileURLWithPath: record.path).standardizedFileURL
            let path = pathURL.path
            let layout = layoutsByPath[path]
            let gitDir = layout?.gitDir.standardizedFileURL
            let isMain: Bool = if let layout {
                !layout.isLinkedWorktree
            } else {
                mainURL?.path == path && !record.isBare
            }
            let worktreeID = GitWorktreeIdentity.worktreeID(
                repositoryID: repository.repositoryID,
                gitDir: gitDir,
                isMain: isMain,
                path: pathURL
            )

            return GitWorktreeDescriptor(
                worktreeID: worktreeID,
                repository: repository,
                path: path,
                gitDir: gitDir?.path,
                name: pathURL.lastPathComponent.isEmpty ? nil : pathURL.lastPathComponent,
                branch: record.branch,
                head: record.head,
                isMain: isMain,
                isCurrent: path == currentPath,
                isDetached: record.isDetached,
                isLocked: record.isLocked,
                lockReason: record.lockReason,
                isPrunable: record.isPrunable,
                prunableReason: record.prunableReason
            )
        }
    }

    private func parseStatusOutput(_ output: String) -> [UncommittedFile] {
        output
            .split(separator: "\n")
            .compactMap { raw in
                let line = String(raw)

                guard line.count >= 3 else { return nil }

                let statusCode = String(line.prefix(2))
                let status = statusCode.trimmingCharacters(in: .whitespaces)

                let pathStart = line.index(line.startIndex, offsetBy: 3)
                var path = String(line[pathStart...])
                // Handle rename/copy lines which look like: "R  old/path -> new/path"
                if status.hasPrefix("R") || status.hasPrefix("C"),
                   let arrowRange = path.range(of: " -> ")
                {
                    path = String(path[arrowRange.upperBound...])
                }

                guard !path.hasSuffix("/") else { return nil }

                return UncommittedFile(path: path, status: status)
            }
    }

    private func makePathspecStdinData(_ files: [String]) -> Data {
        var data = Data()
        for path in files {
            if let encoded = path.data(using: .utf8) {
                data.append(encoded)
            }
            data.append(0)
        }
        return data
    }

    private func shouldFallbackFromPathspecError(_ error: Error) -> Bool {
        guard let gitError = error as? GitError else { return false }
        let message = gitError.message.lowercased()
        return message.contains("unknown option") || message.contains("pathspec-from-file")
    }

    private func parseBranchOutput(_ output: String) -> [Branch] {
        output
            .split(separator: "\n")
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }

                let isCurrent = trimmed.hasPrefix("*")
                let name = isCurrent ?
                    String(trimmed.dropFirst(2)) :
                    String(trimmed)

                return Branch(name: name, isCurrent: isCurrent, lastCommitDate: nil)
            }
    }

    private func parseBranchOutputWithDates(_ output: String) -> [Branch] {
        output
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard parts.count >= 2 else { return nil }

                let name = parts[0]
                let dateString = parts[1]
                let isCurrent = parts.count > 2 && parts[2] == "*"
                let date = parseGitDate(dateString)

                return Branch(name: name, isCurrent: isCurrent, lastCommitDate: date)
            }
    }

    private func parseTagOutputWithDates(_ output: String) -> [Tag] {
        output
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard !parts.isEmpty else { return nil }

                let name = parts[0]
                let date = parts.count > 1 ? parseGitDate(parts[1]) : nil

                return Tag(name: name, commitDate: date)
            }
    }

    /// Accept both Git's "yyyy-MM-dd HH:mm:ss Z" (e.g. "+0000") and RFC3339
    private static let gitDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return df
    }()

    private static let rfc3339Formatter: ISO8601DateFormatter = {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withSpaceBetweenDateAndTime]
        return df
    }()

    private func parseGitDate(_ s: String) -> Date? {
        if let d = Self.gitDateFormatter.date(from: s) { return d }
        return Self.rfc3339Formatter.date(from: s)
    }

    private func untrackedLineStats(for path: String, repoURL: URL) -> (additions: Int?, deletions: Int?) {
        let fileURL = repoURL.appendingPathComponent(path)
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return (nil, nil)
        }
        defer {
            try? handle.close()
        }

        let chunkSize = 64 * 1024
        var sawData = false
        var lineCount = 0
        var lastByte: UInt8?

        while true {
            guard let data = try? handle.read(upToCount: chunkSize),
                  !data.isEmpty
            else {
                break
            }
            sawData = true
            for byte in data {
                if byte == 0 {
                    return (nil, nil)
                }
                if byte == 0x0A {
                    lineCount += 1
                }
                lastByte = byte
            }
        }

        if sawData {
            if let lastByte, lastByte != 0x0A {
                lineCount += 1
            }
        }

        return (lineCount, 0)
    }

    /// Parses `git diff --numstat` output into a map of path → (additions, deletions)
    nonisolated func parseNumstatOutput(_ output: String) -> [String: (Int?, Int?)] {
        var map: [String: (Int?, Int?)] = [:]

        for rawLine in output.split(separator: "\n") {
            let parts = rawLine.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }

            let addStr = parts[0]
            let delStr = parts[1]
            let pathRaw = parts[2]
            let path = normalizeRenamedPath(pathRaw)

            let additions = Int(addStr) // nil when "-"
            let deletions = Int(delStr)

            map[path] = (additions, deletions)
        }
        return map
    }

    /// Convert numstat rename formats to the final/new path so they line up with name-status.
    /// Handles:
    ///  - "old/path => new/path"
    ///  - "dir/{old => new}/file.swift"
    nonisolated func normalizeRenamedPath(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Brace segment renames: "a/{old => new}/b"
        if trimmed.contains("{"), trimmed.contains("}"), trimmed.contains(" => ") {
            var out = ""
            var i = trimmed.startIndex
            var handledBraceRename = false
            while i < trimmed.endIndex {
                if trimmed[i] == "{", let end = trimmed[i...].firstIndex(of: "}") {
                    let inner = trimmed[trimmed.index(after: i) ..< end]
                    if let sep = inner.range(of: " => ") {
                        handledBraceRename = true
                        out += inner[sep.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        out.append("{")
                        out += inner
                        out.append("}")
                    }
                    i = trimmed.index(after: end)
                } else {
                    out.append(trimmed[i])
                    i = trimmed.index(after: i)
                }
            }
            if handledBraceRename {
                return out
            }
        }

        // Simple "old/path => new/path" whole-path rename
        if let arrow = trimmed.range(of: " => ") {
            return String(trimmed[arrow.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }

    /// Parses `git diff --name-status` lines into a map of path → single-letter status
    nonisolated func parseNameStatusOutput(_ output: String) -> [String: String] {
        var map: [String: String] = [:]

        for rawLine in output.split(separator: "\n") {
            let parts = rawLine
                .split(separator: "\t", omittingEmptySubsequences: false)
                .map(String.init)
            guard !parts.isEmpty else { continue }

            let statusCode = parts[0].trimmingCharacters(in: .whitespaces)

            // Handle rename/copy which provide two paths
            let path: String = if statusCode.hasPrefix("R") || statusCode.hasPrefix("C") {
                // new path is last field
                parts.last ?? ""
            } else {
                parts.count > 1 ? parts[1] : ""
            }

            if !path.isEmpty {
                map[path] = String(statusCode.prefix(1)) // e.g. "M"
            }
        }
        return map
    }
}

/// Serializes pipe readability callbacks with process termination and cancellation.
private final class GitProcessMetricsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSpawnMicroseconds = 0

    var spawnMicroseconds: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedSpawnMicroseconds
        }
        set {
            lock.lock()
            storedSpawnMicroseconds = max(0, newValue)
            lock.unlock()
        }
    }
}

///
/// `FileHandle.readabilityHandler` may already be executing when a process termination
/// handler clears it. Foundation may also invalidate its file handle before a queued callback
/// runs. The drain owns a close-on-exec duplicate descriptor so all reads and closure are
/// serialized independently of the `FileHandle` lifecycle.
final class GitProcessPipeDrain: @unchecked Sendable {
    private enum DescriptorReadResult {
        case data(Data)
        case unavailable
        case terminal
    }

    private static let readBufferSize = 64 * 1024

    private let lock = NSLock()
    private let continuation: AsyncStream<Data>.Continuation
    private let byteLimit: Int?
    private var ownedDescriptor: Int32?
    private var emittedByteCount = 0
    private var exceededByteLimit = false
    private var isFinished = false

    private init(
        continuation: AsyncStream<Data>.Continuation,
        byteLimit: Int?,
        ownedDescriptor: Int32? = nil
    ) {
        self.continuation = continuation
        self.byteLimit = byteLimit
        self.ownedDescriptor = ownedDescriptor
    }

    var didExceedByteLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exceededByteLimit
    }

    #if DEBUG
        var ownedDescriptorForTesting: Int32? {
            lock.lock()
            defer { lock.unlock() }
            return ownedDescriptor
        }
    #endif

    deinit {
        if let ownedDescriptor {
            _ = Darwin.close(ownedDescriptor)
        }
    }

    static func makeStream() -> (stream: AsyncStream<Data>, drain: GitProcessPipeDrain) {
        makeStream(byteLimit: nil, ownedDescriptor: nil)
    }

    static func makeStream(
        readingFrom handle: FileHandle,
        byteLimit: Int? = nil
    ) throws -> (stream: AsyncStream<Data>, drain: GitProcessPipeDrain) {
        let duplicateDescriptor = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicateDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let statusFlags = fcntl(duplicateDescriptor, F_GETFL)
        guard statusFlags >= 0 else {
            let failureErrno = errno
            _ = Darwin.close(duplicateDescriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failureErrno))
        }
        guard fcntl(duplicateDescriptor, F_SETFL, statusFlags | O_NONBLOCK) >= 0 else {
            let failureErrno = errno
            _ = Darwin.close(duplicateDescriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failureErrno))
        }

        return makeStream(byteLimit: byteLimit, ownedDescriptor: duplicateDescriptor)
    }

    private static func makeStream(
        byteLimit: Int?,
        ownedDescriptor: Int32?
    ) -> (stream: AsyncStream<Data>, drain: GitProcessPipeDrain) {
        var drain: GitProcessPipeDrain?
        let stream = AsyncStream<Data>(bufferingPolicy: .unbounded) { continuation in
            drain = GitProcessPipeDrain(
                continuation: continuation,
                byteLimit: byteLimit,
                ownedDescriptor: ownedDescriptor
            )
        }
        return (stream, drain!)
    }

    /// Returns true when the `FileHandle` should stop monitoring readability.
    @discardableResult
    func consumeAvailableData() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished, let ownedDescriptor else { return true }

        switch Self.readChunk(from: ownedDescriptor) {
        case let .data(data):
            yieldLocked(data)
            return false
        case .unavailable:
            return false
        case .terminal:
            finishLocked()
            return true
        }
    }

    func finishReading() {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished, let ownedDescriptor else { return }

        while true {
            switch Self.readChunk(from: ownedDescriptor) {
            case let .data(data):
                yieldLocked(data)
            case .unavailable, .terminal:
                finishLocked()
                return
            }
        }
    }

    func consume(read: () -> Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }

        let data = read()
        if !data.isEmpty {
            yieldLocked(data)
        }
    }

    func finish(
        readRemaining: () -> Data,
        onWillLock: (() -> Void)? = nil
    ) {
        onWillLock?()
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }

        let data = readRemaining()
        if !data.isEmpty {
            yieldLocked(data)
        }
        finishLocked()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }

        finishLocked()
    }

    private func finishLocked() {
        isFinished = true
        if let ownedDescriptor {
            self.ownedDescriptor = nil
            _ = Darwin.close(ownedDescriptor)
        }
        continuation.finish()
    }

    private func yieldLocked(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let byteLimit else {
            continuation.yield(data)
            return
        }

        let remaining = max(0, byteLimit - emittedByteCount)
        if remaining > 0 {
            let retained = data.prefix(remaining)
            continuation.yield(Data(retained))
            emittedByteCount += retained.count
        }
        if data.count > remaining {
            exceededByteLimit = true
        }
    }

    private static func readChunk(from descriptor: Int32) -> DescriptorReadResult {
        var buffer = [UInt8](repeating: 0, count: readBufferSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                return .data(Data(buffer.prefix(Int(count))))
            }
            if count == 0 {
                return .terminal
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return .unavailable
            }
            return .terminal
        }
    }
}

private extension GitService.WorkingStatus {
    var isClean: Bool {
        staged.isEmpty && modified.isEmpty && untracked.isEmpty
    }

    var changedPaths: [String] {
        Array(Set(staged + modified + untracked)).sorted()
    }
}

private final class GitProcessTimeoutController: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var timedOut = false

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func schedule(
        process: Process,
        processIdentifier: pid_t,
        timeout: Duration,
        terminationGrace: Duration
    ) {
        lock.lock()
        defer { lock.unlock() }
        task?.cancel()
        timedOut = false
        task = Task {
            do {
                try await Task.sleep(for: timeout)
                guard !Task.isCancelled, process.isRunning else { return }
                self.markTimedOut()
                process.terminate()
                try await Task.sleep(for: terminationGrace)
                guard !Task.isCancelled, process.isRunning else { return }
                kill(processIdentifier, SIGKILL)
            } catch {
                return
            }
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        task?.cancel()
        task = nil
    }

    private func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }
}

private final class GitProcessLifecycleController: @unchecked Sendable {
    enum SpawnState: Equatable {
        case running
        case cancellationRequested
        case terminated
    }

    private let lock = NSLock()
    private var cancellationRequested = false
    private var processIdentifier: pid_t?
    private var terminated = false
    private var cancellationEscalationTask: Task<Void, Never>?

    func checkCancellationBeforeSpawn() throws {
        lock.lock()
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel {
            throw CancellationError()
        }
    }

    func didSpawn(
        process: Process,
        processIdentifier: pid_t,
        terminationGrace: Duration
    ) -> SpawnState {
        lock.lock()
        if terminated {
            let wasCancelled = cancellationRequested
            lock.unlock()
            return wasCancelled ? .cancellationRequested : .terminated
        }

        self.processIdentifier = processIdentifier
        let shouldTerminate = cancellationRequested
        if shouldTerminate {
            armCancellationEscalationLocked(
                process: process,
                processIdentifier: processIdentifier,
                terminationGrace: terminationGrace
            )
        }
        lock.unlock()

        if shouldTerminate, process.isRunning {
            process.terminate()
        }
        return shouldTerminate ? .cancellationRequested : .running
    }

    func requestCancellation(
        process: Process,
        terminationGrace: Duration
    ) {
        lock.lock()
        cancellationRequested = true
        let processIdentifier = terminated ? nil : processIdentifier
        if let processIdentifier {
            armCancellationEscalationLocked(
                process: process,
                processIdentifier: processIdentifier,
                terminationGrace: terminationGrace
            )
        }
        lock.unlock()

        if processIdentifier != nil, process.isRunning {
            process.terminate()
        }
    }

    func shouldKeepNormalTimeout() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancellationRequested && !terminated
    }

    func cancellationErrorIfRequested() -> CancellationError? {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested ? CancellationError() : nil
    }

    func didTerminate() {
        lock.lock()
        terminated = true
        processIdentifier = nil
        let escalationTask = cancellationEscalationTask
        cancellationEscalationTask = nil
        lock.unlock()
        escalationTask?.cancel()
    }

    private func armCancellationEscalationLocked(
        process: Process,
        processIdentifier: pid_t,
        terminationGrace: Duration
    ) {
        guard cancellationEscalationTask == nil else { return }
        cancellationEscalationTask = Task.detached { [self] in
            do {
                try await Task.sleep(for: terminationGrace)
            } catch {
                return
            }
            sendCancellationKillIfNeeded(
                process: process,
                processIdentifier: processIdentifier
            )
        }
    }

    private func sendCancellationKillIfNeeded(
        process: Process,
        processIdentifier: pid_t
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard cancellationRequested,
              !terminated,
              self.processIdentifier == processIdentifier,
              process.isRunning
        else {
            return
        }
        _ = kill(processIdentifier, SIGKILL)
    }
}

// MARK: - Worktree Merge Advisory Lock

private enum GitWorktreeMergeAdvisoryLock {
    static func withLock<T: Sendable>(
        commonGitDir: String,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let fileManager = FileManager.default
        let mutexDir = URL(fileURLWithPath: commonGitDir, isDirectory: true)
            .appendingPathComponent("repoprompt-mutex", isDirectory: true)
        try fileManager.createDirectory(at: mutexDir, withIntermediateDirectories: true)
        let lockPath = mutexDir.appendingPathComponent("worktree.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw GitService.GitError(message: "Unable to open Git worktree merge lock at \(lockPath): errno \(errno)")
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw GitService.GitError(message: "Unable to acquire Git worktree merge lock at \(lockPath): errno \(errno)")
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try await operation()
    }
}

// MARK: - Shell Escaping Extension

private extension String {
    /// Returns a single-quoted string the shell treats as one token
    var shellEscaped: String {
        replacingOccurrences(of: "'", with: "'\\''").surrounding(with: "'")
    }

    func surrounding(with quote: String) -> String {
        quote + self + quote
    }
}

private extension Sequence<String> {
    func shellEscaped() -> [String] {
        map(\.shellEscaped)
    }
}
