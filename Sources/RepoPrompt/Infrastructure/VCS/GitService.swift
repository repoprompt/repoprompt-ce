import CryptoKit
import Darwin
import Foundation

enum GitPrefixControlEvidenceCacheMode {
    case automatic
    case bypassReadAndAdmission
}

struct GitLoadedRootTreeInventorySpool: @unchecked Sendable {
    static let commandFormat = "git-ls-tree-recursive-full-tree-z-v1"

    let rawOutput: GitRawOutputSpoolLease
    let stdoutSHA256: Data
    let treeOID: GitObjectID
    let rootPrefix: GitRepositoryRelativeRootPrefix
}

protocol GitPrefixControlCandidateSource: AnyObject {
    func nextCandidate() throws -> URL?
    func skipDescendants()
    var currentCandidateKind: GitPrefixControlCandidateKind { get }
}

enum GitPrefixControlCandidateKind {
    case directory
    case regularFile
    case symbolicLink
    case other
}

extension GitPrefixControlCandidateSource {
    var currentCandidateKind: GitPrefixControlCandidateKind {
        .other
    }
}

private final class GitFileManagerPrefixControlCandidateSource: GitPrefixControlCandidateSource {
    private final class ErrorBox {
        var error: Error?
    }

    private let enumerator: FileManager.DirectoryEnumerator
    private let errorBox: ErrorBox
    private(set) var currentCandidateKind: GitPrefixControlCandidateKind = .other

    init?(root: URL) {
        let errorBox = ErrorBox()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, error in
                errorBox.error = error
                return false
            }
        ) else { return nil }
        self.enumerator = enumerator
        self.errorBox = errorBox
    }

    func nextCandidate() throws -> URL? {
        if let url = enumerator.nextObject() as? URL {
            var status = stat()
            guard lstat(url.path, &status) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            currentCandidateKind = switch status.st_mode & S_IFMT {
            case S_IFDIR: .directory
            case S_IFREG: .regularFile
            case S_IFLNK: .symbolicLink
            default: .other
            }
            return url
        }
        if let error = errorBox.error { throw error }
        return nil
    }

    func skipDescendants() {
        enumerator.skipDescendants()
    }
}

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

    enum GitProcessCaptureError: Error, Equatable {
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
        enum ReceiptCreationFailurePointForTesting: Equatable {
            case targetTreeUnavailable
            case witnessCoverageInvalid
            case includeCopyIncomplete
            case targetLayoutUnavailable
            case targetAuthorityUnavailable
        }

        private struct ReceiptCreationFailureForTesting {
            let correlationID: UUID
            let point: ReceiptCreationFailurePointForTesting
        }

        private final class ReceiptCreationFailureHook: @unchecked Sendable {
            private let lock = NSLock()
            private var failure: ReceiptCreationFailureForTesting?

            func set(correlationID: UUID, point: ReceiptCreationFailurePointForTesting?) {
                lock.lock()
                failure = point.map {
                    ReceiptCreationFailureForTesting(correlationID: correlationID, point: $0)
                }
                lock.unlock()
            }

            func consume(
                _ point: ReceiptCreationFailurePointForTesting,
                correlationID: UUID?
            ) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard let failure,
                      failure.correlationID == correlationID,
                      failure.point == point
                else { return false }
                self.failure = nil
                return true
            }
        }

        private final class ReceiptCreationTerminalClaim: @unchecked Sendable {
            private let lock = NSLock()
            private var claimed = false

            func claim() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard !claimed else { return false }
                claimed = true
                return true
            }
        }

        private final class ReceiptParentLookupTrace: @unchecked Sendable {
            var currentLeasePresent: Bool?
            var currentLeaseCurrentAtSnapshotLookup: Bool?
            var currentSnapshotPresent: Bool?
            var currentSnapshotContentAddressValid: Bool?
            var currentSnapshotSHA256: String?
            var route: WorktreeStartupInstrumentation.ReceiptParentLookupRoute = .notAttempted
            var failure: WorktreeStartupInstrumentation.ReceiptParentLookupFailure = .none
        }

        @TaskLocal private static var currentReceiptParentLookupTrace: ReceiptParentLookupTrace?

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
    #if DEBUG
        private nonisolated let receiptCreationFailureHook = ReceiptCreationFailureHook()
        private var worktreeMutationLockAcquiredHandlerForTesting: (@Sendable (UUID?) async -> Void)?
        private var targetEvidenceDidSealBeforeCommandHandlerForTesting: (@Sendable () async throws -> Void)?
    #endif

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

    #if DEBUG
        func setReceiptCreationFailureForTesting(
            correlationID: UUID,
            point: ReceiptCreationFailurePointForTesting?
        ) {
            receiptCreationFailureHook.set(correlationID: correlationID, point: point)
        }

        func setWorktreeMutationLockAcquiredHandlerForTesting(
            _ handler: (@Sendable (UUID?) async -> Void)?
        ) {
            worktreeMutationLockAcquiredHandlerForTesting = handler
        }

        func setTargetEvidenceDidSealBeforeCommandHandlerForTesting(
            _ handler: (@Sendable () async throws -> Void)?
        ) {
            targetEvidenceDidSealBeforeCommandHandlerForTesting = handler
        }

        func waitForWorktreeMutationWaiterForTesting(at repoURL: URL) async {
            let mutationKey = getLayout(for: repoURL)?.commonDir.standardizedFileURL.path
                ?? repoURL.standardizedFileURL.path
            await worktreeMutationCoordinator.waitForQueuedWaiterForTesting(key: mutationKey)
        }

        private nonisolated func consumeReceiptCreationFailureForTesting(
            _ point: ReceiptCreationFailurePointForTesting,
            correlationID: UUID?
        ) -> Bool {
            receiptCreationFailureHook.consume(point, correlationID: correlationID)
        }

        private nonisolated static func receiptMatch(
            _ matches: Bool
        ) -> WorktreeStartupInstrumentation.ReceiptMatchState {
            matches ? .match : .mismatch
        }

        private nonisolated static func receiptAuthorityKeyDigest(
            _ key: GitWorkspaceAuthorityRepositoryKey
        ) -> String {
            WorktreeStartupInstrumentation.receiptDecisionDigest(
                [
                    key.standardizedCommonDirectoryPath,
                    key.standardizedGitDirectoryPath,
                    key.commonDirectoryDevice.map(String.init) ?? "missing-device",
                    key.commonDirectoryInode.map(String.init) ?? "missing-inode"
                ].joined(separator: "\0"),
                domain: .authorityKey
            )
        }

        private nonisolated static func applyReceiptWitnessCoverage(
            _ coverage: GitWorktreeCreationWitnessCoverage?,
            to decision: inout WorktreeStartupInstrumentation.ReceiptCreationDecision
        ) {
            decision.witnessFinished = coverage != nil
            guard let coverage else { return }
            decision.witnessStartEventID = coverage.startEventID
            decision.witnessEndEventID = coverage.endEventID
            decision.witnessStartEventIDValid = coverage.startEventID > 0
                && coverage.startEventID != UInt64.max
            decision.witnessEndEventIDValid = coverage.endEventID > 0
                && coverage.endEventID != UInt64.max
            decision.witnessStableRootAvailableBeforeMutation = coverage.stableWatchRootAvailableBeforeMutation
            decision.witnessDestinationAbsentBeforeMutation = coverage.destinationWasAbsentBeforeMutation
            decision.witnessDestinationStrictDescendant = coverage.destinationWasStrictDescendant
            decision.witnessStableRootUnchangedAfterInitialization =
                coverage.stableWatchRootUnchangedAfterInitialization
            decision.witnessStreamCreationSucceeded = coverage.streamCreationSucceeded
            decision.witnessActivationFlushCompleted = coverage.activationFlushCompleted
            decision.witnessActivationCallbackBarrierCompleted = coverage.activationCallbackBarrierCompleted
            decision.witnessEndingFlushCompleted = coverage.endingFlushCompleted
            decision.witnessEndingCallbackBarrierCompleted = coverage.endingCallbackBarrierCompleted
            decision.witnessStartAcceptedCallbackWatermark = coverage.startAcceptedCallbackWatermark
            decision.witnessEndAcceptedCallbackWatermark = coverage.endAcceptedCallbackWatermark
            decision.witnessAcceptedCallbackCount = coverage.acceptedCallbackCount
            decision.witnessAcceptedEventCount = coverage.acceptedEventCount
            decision.witnessAcceptedDestinationEventCount = coverage.acceptedDestinationEventCount
            decision.witnessAcceptedNonDestinationEventCount = coverage.acceptedNonDestinationEventCount
            decision.witnessMustScanSubDirs = coverage.mustScanSubDirs
            decision.witnessRootChanged = coverage.rootChanged
            decision.witnessUserDropped = coverage.userDropped
            decision.witnessKernelDropped = coverage.kernelDropped
            decision.witnessEventIDsWrapped = coverage.eventIDsWrapped
            decision.witnessEventIDRegressed = coverage.eventIDRegressed
            decision.witnessLifetimeExceeded = coverage.lifetimeExceeded
            decision.witnessGap = coverage.hadGap
            decision.witnessDrop = coverage.hadDrop
            decision.witnessOverflow = coverage.overflowed
            decision.witnessProvesInterval = coverage.provesCreationInterval
        }
    #endif

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
        let destinationIsAppManaged = request.appManagedContainer.map {
            Self.isPath(request.path, equalToOrInside: $0)
        } ?? false
        let reusableReceiptDestinationIsEligible = destinationIsAppManaged
            && request.copyWorktreeIncludeFiles
        #if DEBUG
            let initialReceiptDecision = initializationContext.map { context in
                var decision = WorktreeStartupInstrumentation.ReceiptCreationDecision()
                decision.sourceLayoutState = if let sourceLayout {
                    sourceLayout.isLinkedWorktree ? .linkedWorktree : .mainCheckout
                } else {
                    .missing
                }
                decision.destinationEligibility = if !destinationIsAppManaged {
                    .notAppManaged
                } else if !request.copyWorktreeIncludeFiles {
                    .includeCopyDisabled
                } else {
                    .eligible
                }
                decision.requestedPrefixDigest = WorktreeStartupInstrumentation.receiptDecisionDigest(
                    context.repositoryRelativeRootPrefix.value,
                    domain: .requestedPrefix
                )
                decision.includeCopyRequested = request.copyWorktreeIncludeFiles
                decision.witnessRequested = false
                decision.witnessStarted = false
                if let sourceLayout {
                    decision.sourceAuthorityKeyDigest = Self.receiptAuthorityKeyDigest(
                        GitWorkspaceAuthorityRepositoryKey(layout: sourceLayout)
                    )
                    decision.sourceCommonDirectoryDigest = WorktreeStartupInstrumentation.receiptDecisionDigest(
                        sourceLayout.commonDir.standardizedFileURL.path,
                        domain: .commonDirectory
                    )
                }
                return decision
            }
            let receiptCreationTerminalClaim = initializationContext.map { _ in
                ReceiptCreationTerminalClaim()
            }
            let mutationLockAcquiredHandler = worktreeMutationLockAcquiredHandlerForTesting
        #endif

        do {
            return try await worktreeMutationCoordinator.withLock(key: mutationKey) { [weak self] in
                guard let self else {
                    throw GitError(message: "git service was released before worktree creation")
                }
                #if DEBUG
                    if let mutationLockAcquiredHandler {
                        await mutationLockAcquiredHandler(initializationContext?.correlationID)
                    }
                    let parentLookupTrace = initializationContext.map { _ in ReceiptParentLookupTrace() }
                    var receiptDecision = initialReceiptDecision
                #endif
                if let mainWorktreeRoot = request.mainWorktreeRoot {
                    do {
                        try GitWorktreeDefaultPathPlanner.validate(
                            path: request.path,
                            mainWorktreeRoot: mainWorktreeRoot,
                            knownWorktreeRoots: request.knownWorktreeRoots,
                            appManagedContainer: request.appManagedContainer,
                            allowExternalPath: request.allowExternalPath
                        )
                    } catch {
                        #if DEBUG
                            if let initializationContext,
                               var receiptDecision,
                               receiptCreationTerminalClaim?.claim() == true
                            {
                                receiptDecision.outcome = .failed
                                WorktreeStartupInstrumentation.recordReceiptCreationDecision(
                                    correlationID: initializationContext.correlationID,
                                    decision: receiptDecision,
                                    terminal: true
                                )
                            }
                        #endif
                        throw error
                    }
                }
                var parentEvidence: (
                    lease: GitWorkspaceAuthorityLease,
                    snapshot: WorkspaceRootReusableSnapshot,
                    baseTree: GitObjectID
                )?
                var witnessSession: WorkspaceRootCreationReceiptCoordinator.Session?
                var reusableEvidence: (
                    lease: GitWorkspaceAuthorityLease,
                    snapshot: WorkspaceRootReusableSnapshot
                )?
                if let initializationContext,
                   initializationContext.observeReceipt,
                   reusableReceiptDestinationIsEligible,
                   let sourceLayout
                {
                    #if DEBUG
                        reusableEvidence = try? await Self.$currentReceiptParentLookupTrace.withValue(
                            parentLookupTrace
                        ) {
                            try await self.reusableParentEvidence(
                                layout: sourceLayout,
                                prefix: initializationContext.repositoryRelativeRootPrefix
                            )
                        }
                    #else
                        reusableEvidence = try? await reusableParentEvidence(
                            layout: sourceLayout,
                            prefix: initializationContext.repositoryRelativeRootPrefix
                        )
                    #endif
                }
                if let initializationContext,
                   let sourceLayout,
                   let reusableEvidence
                {
                    #if DEBUG
                        receiptDecision?.currentLeasePresent = parentLookupTrace?.currentLeasePresent
                        receiptDecision?.currentLeaseCurrentAtSnapshotLookup = parentLookupTrace?
                            .currentLeaseCurrentAtSnapshotLookup
                        receiptDecision?.currentSnapshotPresent = parentLookupTrace?.currentSnapshotPresent
                        receiptDecision?.currentSnapshotContentAddressValid = parentLookupTrace?
                            .currentSnapshotContentAddressValid
                        receiptDecision?.currentSnapshotSHA256 = parentLookupTrace?.currentSnapshotSHA256
                        receiptDecision?.parentLookupRoute = parentLookupTrace?.route ?? .notAttempted
                        receiptDecision?.parentLookupFailure = parentLookupTrace?.failure ?? .none
                        receiptDecision?.parentAuthorityKeyMatch = Self.receiptMatch(
                            reusableEvidence.lease.snapshot.repositoryKey
                                == GitWorkspaceAuthorityRepositoryKey(layout: sourceLayout)
                        )
                        receiptDecision?.parentPrefixMatch = Self.receiptMatch(
                            reusableEvidence.lease.snapshot.repositoryRelativeRootPrefix
                                == initializationContext.repositoryRelativeRootPrefix
                        )
                        receiptDecision?.repositoryNamespaceDigest = WorktreeStartupInstrumentation
                            .receiptDecisionDigest(
                                reusableEvidence.lease.snapshot.repositoryNamespace.rawValue,
                                domain: .repositoryNamespace
                            )
                    #endif
                    var targetTree = try? await resolveTreeOID(
                        request.baseRef?.isEmpty == false ? request.baseRef! : "HEAD",
                        in: sourceLayout
                    )
                    #if DEBUG
                        if consumeReceiptCreationFailureForTesting(
                            .targetTreeUnavailable,
                            correlationID: initializationContext.correlationID
                        ) {
                            targetTree = nil
                        }
                    #endif
                    if let targetTree {
                        #if DEBUG
                            receiptDecision?.targetTreeResolution = .succeeded
                            receiptDecision?.witnessRequested = true
                        #endif
                        parentEvidence = (reusableEvidence.lease, reusableEvidence.snapshot, targetTree)
                        if let stableWatchRootURL = request.appManagedContainer {
                            witnessSession = creationReceiptCoordinator.start(
                                destinationURL: request.path,
                                stableWatchRootURL: stableWatchRootURL
                            )
                        }
                        #if DEBUG
                            receiptDecision?.witnessStarted = witnessSession?.streamStartedBeforeMutation ?? false
                        #endif
                    } else {
                        #if DEBUG
                            receiptDecision?.targetTreeResolution = .failed
                        #endif
                    }
                }
                #if DEBUG
                    if parentEvidence == nil {
                        receiptDecision?.currentLeasePresent = parentLookupTrace?.currentLeasePresent
                        receiptDecision?.currentLeaseCurrentAtSnapshotLookup = parentLookupTrace?
                            .currentLeaseCurrentAtSnapshotLookup
                        receiptDecision?.currentSnapshotPresent = parentLookupTrace?.currentSnapshotPresent
                        receiptDecision?.currentSnapshotContentAddressValid = parentLookupTrace?
                            .currentSnapshotContentAddressValid
                        receiptDecision?.currentSnapshotSHA256 = parentLookupTrace?.currentSnapshotSHA256
                        receiptDecision?.parentLookupRoute = parentLookupTrace?.route ?? .notAttempted
                        receiptDecision?.parentLookupFailure = parentLookupTrace?.failure ?? .none
                    }
                #endif

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

                    #if DEBUG
                        let benchmarkMutationStarted = DispatchTime.now().uptimeNanoseconds
                    #endif
                    let (_, stderr, exitCode) = try await runGit(args, at: repoURL)
                    guard exitCode == 0 else {
                        throw GitError(message: "git worktree add failed: \(stderr)")
                    }
                    #if DEBUG
                        let benchmarkMutationFinished = DispatchTime.now().uptimeNanoseconds
                        let benchmarkPostMutationStarted = benchmarkMutationFinished
                    #endif

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

                    var targetLayout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: destinationURL)
                    #if DEBUG
                        if consumeReceiptCreationFailureForTesting(
                            .targetLayoutUnavailable,
                            correlationID: initializationContext?.correlationID
                        ) {
                            targetLayout = nil
                        }
                    #endif
                    var witnessCoverage = witnessSession.map(creationReceiptCoordinator.finish)
                    witnessSession = nil
                    #if DEBUG
                        if consumeReceiptCreationFailureForTesting(
                            .witnessCoverageInvalid,
                            correlationID: initializationContext?.correlationID
                        ), let coverage = witnessCoverage {
                            witnessCoverage = GitWorktreeCreationWitnessCoverage(
                                startedAtUptimeNanoseconds: coverage.startedAtUptimeNanoseconds,
                                endedAtUptimeNanoseconds: coverage.endedAtUptimeNanoseconds,
                                startEventID: coverage.startEventID,
                                endEventID: coverage.endEventID,
                                stableWatchRootAvailableBeforeMutation: coverage
                                    .stableWatchRootAvailableBeforeMutation,
                                destinationWasAbsentBeforeMutation: coverage.destinationWasAbsentBeforeMutation,
                                destinationWasStrictDescendant: coverage.destinationWasStrictDescendant,
                                stableWatchRootUnchangedAfterInitialization: coverage
                                    .stableWatchRootUnchangedAfterInitialization,
                                streamCreationSucceeded: coverage.streamCreationSucceeded,
                                streamStartedBeforeMutation: coverage.streamStartedBeforeMutation,
                                activationFlushCompleted: coverage.activationFlushCompleted,
                                activationCallbackBarrierCompleted: coverage
                                    .activationCallbackBarrierCompleted,
                                streamEndedAfterInitialization: coverage.streamEndedAfterInitialization,
                                endingFlushCompleted: coverage.endingFlushCompleted,
                                endingCallbackBarrierCompleted: coverage.endingCallbackBarrierCompleted,
                                startAcceptedCallbackWatermark: coverage.startAcceptedCallbackWatermark,
                                endAcceptedCallbackWatermark: coverage.endAcceptedCallbackWatermark,
                                acceptedCallbackCount: coverage.acceptedCallbackCount,
                                acceptedEventCount: coverage.acceptedEventCount,
                                acceptedDestinationEventCount: coverage.acceptedDestinationEventCount,
                                acceptedNonDestinationEventCount: coverage.acceptedNonDestinationEventCount,
                                mustScanSubDirs: coverage.mustScanSubDirs,
                                rootChanged: coverage.rootChanged,
                                userDropped: coverage.userDropped,
                                kernelDropped: coverage.kernelDropped,
                                eventIDsWrapped: coverage.eventIDsWrapped,
                                eventIDRegressed: coverage.eventIDRegressed,
                                lifetimeExceeded: coverage.lifetimeExceeded,
                                hadGap: true,
                                hadDrop: coverage.hadDrop,
                                overflowed: coverage.overflowed
                            )
                        }
                        if var decision = receiptDecision {
                            Self.applyReceiptWitnessCoverage(witnessCoverage, to: &decision)
                            receiptDecision = decision
                        }
                    #endif
                    if let mutationToken {
                        await workspaceStateAuthority.finishMutation(mutationToken, outcome: .succeeded)
                    }
                    #if DEBUG
                        let targetAuthorityWasAttempted = targetLayout != nil
                            && initializationContext != nil
                            && parentEvidence != nil
                    #endif
                    var targetAuthority: GitWorkspaceAuthoritySnapshot? = if let targetLayout,
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
                    #if DEBUG
                        if consumeReceiptCreationFailureForTesting(
                            .targetAuthorityUnavailable,
                            correlationID: initializationContext?.correlationID
                        ) {
                            targetAuthority = nil
                        }
                        receiptDecision?.targetAuthorityCapture = if targetAuthorityWasAttempted {
                            targetAuthority == nil ? .failed : .succeeded
                        } else {
                            .notAttempted
                        }
                    #endif
                    let includeCopyHadFailures = includeCopyResult.map {
                        !$0.skippedSummaries.isEmpty || !$0.errorSummaries.isEmpty
                    } ?? false
                    var includeCopyWasComplete = reusableReceiptDestinationIsEligible
                        && !includeCopyHadFailures
                        && (includeCopyResult.map {
                            $0.copiedCount == $0.matchedCount
                                && $0.copiedRelativePaths.count == $0.copiedCount
                        } ?? true)
                    #if DEBUG
                        if consumeReceiptCreationFailureForTesting(
                            .includeCopyIncomplete,
                            correlationID: initializationContext?.correlationID
                        ) {
                            includeCopyWasComplete = false
                        }
                        receiptDecision?.includeCopyResultPresent = includeCopyResult != nil
                        receiptDecision?.includeCopyComplete = includeCopyWasComplete
                        receiptDecision?.includeCopyHadFailures = includeCopyHadFailures
                        receiptDecision?.targetLayoutPresent = targetLayout != nil
                        receiptDecision?.targetLayoutLinked = targetLayout?.isLinkedWorktree
                        if let sourceLayout, let targetLayout {
                            receiptDecision?.commonDirectoryMatch = Self.receiptMatch(
                                sourceLayout.commonDir.standardizedFileURL.path
                                    == targetLayout.commonDir.standardizedFileURL.path
                            )
                        }
                        if let sourceDescriptor = worktrees.first(where: {
                            $0.path == repoURL.standardizedFileURL.path
                        }) {
                            receiptDecision?.repositoryIDDigest = WorktreeStartupInstrumentation
                                .receiptDecisionDigest(
                                    sourceDescriptor.repository.repositoryID,
                                    domain: .repositoryID
                                )
                            receiptDecision?.repositoryIDMatch = Self.receiptMatch(
                                sourceDescriptor.repository.repositoryID == created.repository.repositoryID
                            )
                        }
                        if let parentEvidence, let targetAuthority {
                            receiptDecision?.repositoryNamespaceMatch = Self.receiptMatch(
                                parentEvidence.lease.snapshot.repositoryNamespace
                                    == targetAuthority.repositoryNamespace
                            )
                            receiptDecision?.targetPrefixMatch = Self.receiptMatch(
                                targetAuthority.repositoryRelativeRootPrefix
                                    == initializationContext?.repositoryRelativeRootPrefix
                            )
                            receiptDecision?.targetTreeAuthorityMatch = Self.receiptMatch(
                                targetAuthority.treeOID == parentEvidence.baseTree
                            )
                        }
                    #endif

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
                    #if DEBUG
                        if let initializationContext,
                           var receiptDecision,
                           receiptCreationTerminalClaim?.claim() == true
                        {
                            receiptDecision.receiptEmitted = receipt != nil
                            receiptDecision.receiptFallbackReason = receipt?.fallbackReason()
                            receiptDecision.initializationFallbackReason = initializationFallbackReason
                            receiptDecision.outcome = receipt == nil ? .receiptAbsent : .receiptEmitted
                            WorktreeStartupInstrumentation.recordReceiptCreationDecision(
                                correlationID: initializationContext.correlationID,
                                decision: receiptDecision
                            )
                        }
                    #endif
                    #if DEBUG
                        let benchmarkPostMutationFinished = DispatchTime.now().uptimeNanoseconds
                        WorktreeStartupInstrumentation.recordBenchmarkMutationWork(
                            tag: WorktreeStartupInstrumentation.currentBenchmarkMetricTag,
                            mutationDurationMicroseconds: (
                                benchmarkMutationFinished - benchmarkMutationStarted
                            ) / 1000,
                            postMutationFinalizationMicroseconds: (
                                benchmarkPostMutationFinished - benchmarkPostMutationStarted
                            ) / 1000
                        )
                    #endif
                    return GitWorktreeCreateResult(
                        descriptor: created,
                        includeCopyResult: includeCopyResult,
                        initializationReceipt: receipt,
                        initializationFallbackReason: initializationFallbackReason
                    )
                } catch is CancellationError {
                    let witnessCoverage = witnessSession.map(creationReceiptCoordinator.finish)
                    if let mutationToken {
                        await workspaceStateAuthority.finishMutation(mutationToken, outcome: .cancelled)
                    }
                    #if DEBUG
                        if let initializationContext,
                           var receiptDecision,
                           receiptCreationTerminalClaim?.claim() == true
                        {
                            Self.applyReceiptWitnessCoverage(witnessCoverage, to: &receiptDecision)
                            receiptDecision.outcome = .cancelled
                            WorktreeStartupInstrumentation.recordReceiptCreationDecision(
                                correlationID: initializationContext.correlationID,
                                decision: receiptDecision,
                                terminal: true
                            )
                        }
                    #endif
                    throw CancellationError()
                } catch {
                    let witnessCoverage = witnessSession.map(creationReceiptCoordinator.finish)
                    if let mutationToken {
                        await workspaceStateAuthority.finishMutation(mutationToken, outcome: .failed)
                    }
                    #if DEBUG
                        if let initializationContext,
                           var receiptDecision,
                           receiptCreationTerminalClaim?.claim() == true
                        {
                            Self.applyReceiptWitnessCoverage(witnessCoverage, to: &receiptDecision)
                            receiptDecision.outcome = .failed
                            WorktreeStartupInstrumentation.recordReceiptCreationDecision(
                                correlationID: initializationContext.correlationID,
                                decision: receiptDecision,
                                terminal: true
                            )
                        }
                    #endif
                    throw error
                }
            }
        } catch {
            #if DEBUG
                if let initializationContext,
                   var receiptDecision = initialReceiptDecision,
                   receiptCreationTerminalClaim?.claim() == true
                {
                    receiptDecision.outcome = error is CancellationError ? .cancelled : .failed
                    WorktreeStartupInstrumentation.recordReceiptCreationDecision(
                        correlationID: initializationContext.correlationID,
                        decision: receiptDecision,
                        terminal: true
                    )
                }
            #endif
            throw error
        }
    }

    private func reusableParentEvidence(
        layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix
    ) async throws -> (lease: GitWorkspaceAuthorityLease, snapshot: WorkspaceRootReusableSnapshot)? {
        #if DEBUG
            let diagnosticTrace = Self.currentReceiptParentLookupTrace
        #endif
        let currentLease = try? await currentAuthorityLease(layout: layout, prefix: prefix)
        #if DEBUG
            diagnosticTrace?.currentLeasePresent = currentLease != nil
            if let currentLease {
                diagnosticTrace?.currentLeaseCurrentAtSnapshotLookup = await workspaceStateAuthority.isCurrent(
                    currentLease
                )
            }
        #endif
        if let currentLease {
            let currentSnapshot = await workspaceStateAuthority.currentReusableSnapshot(capturedUsing: currentLease)
            #if DEBUG
                diagnosticTrace?.currentSnapshotPresent = currentSnapshot != nil
                diagnosticTrace?.currentSnapshotContentAddressValid = currentSnapshot?.hasValidContentAddress()
                diagnosticTrace?.currentSnapshotSHA256 = currentSnapshot?.identity.sha256
            #endif
            if let currentSnapshot {
                #if DEBUG
                    diagnosticTrace?.route = .currentAlias
                    diagnosticTrace?.failure = .none
                #endif
                return (currentLease, currentSnapshot)
            }
            #if DEBUG
                diagnosticTrace?.failure = .currentSnapshotUnavailable
            #endif
        } else {
            #if DEBUG
                diagnosticTrace?.currentLeaseCurrentAtSnapshotLookup = false
                diagnosticTrace?.failure = .currentLeaseUnavailable
            #endif
        }

        var discoveryObservation: GitWorkspaceMetadataMonitor.RetainToken?
        var replacementObservation: GitWorkspaceMetadataMonitor.RetainToken?
        do {
            let discoveryToken: GitWorkspaceMetadataMonitor.RetainToken
            do {
                discoveryToken = try await workspaceStateAuthority.retainMetadataObservation(for: layout)
            } catch {
                #if DEBUG
                    diagnosticTrace?.route = .failed
                    diagnosticTrace?.failure = .recoveryObservationUnavailable
                #endif
                throw error
            }
            discoveryObservation = discoveryToken
            let discovery = try await workspaceAuthoritySnapshot(in: layout, prefix: prefix)
            let discoveredExternalPaths = Self.canonicalPathSet(
                discovery.metadata.resolvedExternalAuthorityPaths
            )
            let observation: GitWorkspaceMetadataMonitor.RetainToken
            do {
                observation = try await workspaceStateAuthority.retainMetadataObservation(
                    for: layout,
                    additionalAuthorityPaths: discovery.metadata.resolvedExternalAuthorityPaths
                )
            } catch {
                #if DEBUG
                    diagnosticTrace?.route = .failed
                    diagnosticTrace?.failure = .recoveryObservationUnavailable
                #endif
                throw error
            }
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
                #if DEBUG
                    diagnosticTrace?.route = .failed
                    diagnosticTrace?.failure = .recoveryCollectionUnavailable
                #endif
                await workspaceStateAuthority.releaseMetadataObservation(observation)
                return nil
            }
            let captured = try await workspaceAuthoritySnapshot(in: layout, prefix: prefix)
            guard Self.canonicalPathSet(captured.metadata.resolvedExternalAuthorityPaths) == discoveredExternalPaths else {
                #if DEBUG
                    diagnosticTrace?.route = .failed
                    diagnosticTrace?.failure = .externalAuthorityChanged
                #endif
                await workspaceStateAuthority.releaseMetadataObservation(observation)
                return nil
            }
            guard await workspaceStateAuthority.metadataObservationIsCurrent(
                observation,
                for: layout,
                additionalAuthorityPaths: captured.metadata.resolvedExternalAuthorityPaths,
                expectedAcceptedWatermark: captureToken.acceptedMetadataWatermark
            ) else {
                #if DEBUG
                    diagnosticTrace?.route = .failed
                    diagnosticTrace?.failure = .recoveryObservationStale
                #endif
                await workspaceStateAuthority.releaseMetadataObservation(observation)
                return nil
            }
            let lease: GitWorkspaceAuthorityLease
            switch await workspaceStateAuthority.install(captured.snapshot, capturedUsing: captureToken) {
            case let .success(value): lease = value
            case .failure:
                #if DEBUG
                    diagnosticTrace?.route = .failed
                    diagnosticTrace?.failure = .recoveryInstallFailed
                #endif
                await workspaceStateAuthority.releaseMetadataObservation(observation)
                return nil
            }
            guard let snapshot = await workspaceStateAuthority.reusableSnapshot(compatibleWith: captured.snapshot) else {
                #if DEBUG
                    diagnosticTrace?.route = .failed
                    diagnosticTrace?.failure = .compatibleSnapshotMissing
                #endif
                await workspaceStateAuthority.releaseMetadataObservation(observation)
                return nil
            }
            replacementObservation = nil
            guard await workspaceStateAuthority.admitReusableSnapshot(
                snapshot,
                capturedUsing: lease,
                observationToken: observation
            ) else {
                #if DEBUG
                    diagnosticTrace?.route = .failed
                    diagnosticTrace?.failure = .recoveryAdmissionFailed
                #endif
                return nil
            }
            #if DEBUG
                diagnosticTrace?.route = .recovered
                diagnosticTrace?.failure = .none
            #endif
            return (lease, snapshot)
        } catch {
            #if DEBUG
                if diagnosticTrace?.route != .failed {
                    diagnosticTrace?.route = .failed
                    diagnosticTrace?.failure = .unexpected
                }
            #endif
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

    /// Captures a loaded-root tree inventory without aggregating stdout or
    /// imposing a repository-cardinality ceiling. The returned descriptor-bound
    /// spool is evidence only; callers must separately preserve authority and
    /// currentness fences around its consumption.
    func spoolLoadedRootTreeInventory(
        _ treeOID: GitObjectID,
        in layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        resourcePolicy: GitRawOutputSpoolResourcePolicy = .default,
        priority: GitProcessAdmissionPriority = .rootBootstrap
    ) async throws -> GitLoadedRootTreeInventorySpool {
        let objectFormat = try await boundedObjectFormat(
            in: layout,
            priority: priority,
            timeout: resourcePolicy.activityTimeout
        )
        guard objectFormat == treeOID.objectFormat else {
            throw GitWorktreeInitializationError.malformedOutput("tree object format changed")
        }
        var arguments = [
            "ls-tree", "-r", "-t", "-z", "--full-tree",
            "--format=%(objectmode) %(objecttype) %(objectname)%x09%(path)",
            treeOID.lowercaseHex
        ]
        appendLiteralPrefix(prefix, to: &arguments)
        let environment = await Self.capabilityBoundObjectReadEnvironment(
            baseEnvironment: processEnvironment(),
            layout: layout
        )
        let rawOutput = try await runSpoolingAuthorityGit(
            arguments,
            layout: layout,
            environment: environment,
            resourcePolicy: resourcePolicy,
            priority: priority,
            family: .treeInventory
        )
        do {
            return try GitLoadedRootTreeInventorySpool(
                rawOutput: rawOutput,
                stdoutSHA256: rawOutput.sha256Digest(),
                treeOID: treeOID,
                rootPrefix: prefix
            )
        } catch {
            // Dropping the only lease unlinks the spool directory.
            throw error
        }
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

    // MARK: - Spill-backed target-seed Git evidence

    func writeTreeDeltaEvidence(
        baseTreeOID: GitObjectID,
        in layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        authorityFence: GitWorkspacePendingInitializationAuthorityFence,
        attemptID: UUID,
        suppliedCreationCutProvenanceBytes: Data?,
        store: GitTargetEvidenceManifestStore,
        evidenceResourcePolicy: GitTargetEvidenceResourcePolicy = .default,
        spoolResourcePolicy: GitRawOutputSpoolResourcePolicy = .default,
        pathPolicy: GitTargetEvidencePathPolicy = .init(),
        priority: GitProcessAdmissionPriority = .rootBootstrap
    ) async throws -> GitTargetTreeDeltaEvidenceLease {
        do {
            let targetTreeOID = authorityFence.snapshot.treeOID
            guard baseTreeOID.objectFormat == targetTreeOID.objectFormat else {
                throw GitTargetEvidenceCollectionError.malformedGitOutput(
                    "tree object formats differ"
                )
            }
            var arguments = [
                "diff-tree", "-r", "--raw", "-z", "--no-commit-id",
                "--find-renames", "--find-copies", "--no-ext-diff",
                baseTreeOID.lowercaseHex, targetTreeOID.lowercaseHex
            ]
            appendLiteralPrefix(prefix, to: &arguments)
            let sealed = try await runSealedTargetEvidenceCommand(
                arguments,
                layout: layout,
                prefix: prefix,
                authorityFence: authorityFence,
                resourcePolicy: spoolResourcePolicy,
                priority: priority,
                family: .treeDelta
            )
            let identity = try Self.targetEvidenceIdentity(
                prefix: prefix,
                authorityFence: authorityFence,
                attemptID: attemptID,
                sealedAuthority: sealed.authority,
                commandOutputDigest: sealed.commandOutputDigest,
                arguments: sealed.commandArguments,
                commandFormat: "git-diff-tree-raw-z-v2",
                baseObjectID: baseTreeOID,
                suppliedCreationCutProvenanceBytes: suppliedCreationCutProvenanceBytes,
                sparseCheckoutEnabled: nil
            )
            let writer = try store.makeTreeDeltaWriter(
                identity: identity,
                resourcePolicy: evidenceResourcePolicy
            )
            do {
                var parser = GitTargetTreeDeltaStreamingParser(
                    objectFormat: sealed.authority.objectFormat,
                    rootPrefix: prefix,
                    pathPolicy: pathPolicy
                ) { record in
                    try await writer.append(record)
                }
                try await Self.consume(sealed.rawOutput, with: &parser)
                return try await writer.finish()
            } catch {
                await writer.cancel()
                throw error
            }
        } catch {
            throw Self.targetEvidenceCollectionError(error)
        }
    }

    func writeIndexEvidence(
        in layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        authorityFence: GitWorkspacePendingInitializationAuthorityFence,
        attemptID: UUID,
        suppliedCreationCutProvenanceBytes: Data?,
        store: GitTargetEvidenceManifestStore,
        evidenceResourcePolicy: GitTargetEvidenceResourcePolicy = .default,
        spoolResourcePolicy: GitRawOutputSpoolResourcePolicy = .default,
        pathPolicy: GitTargetEvidencePathPolicy = .init(),
        priority: GitProcessAdmissionPriority = .rootBootstrap
    ) async throws -> GitTargetIndexEvidenceLease {
        do {
            var arguments = [
                "ls-files", "--stage", "-v", "-z"
            ]
            appendLiteralPrefix(prefix, to: &arguments)
            let sealed = try await runSealedTargetEvidenceCommand(
                arguments,
                layout: layout,
                prefix: prefix,
                authorityFence: authorityFence,
                resourcePolicy: spoolResourcePolicy,
                priority: priority,
                family: .indexManifest
            )
            let identity = try Self.targetEvidenceIdentity(
                prefix: prefix,
                authorityFence: authorityFence,
                attemptID: attemptID,
                sealedAuthority: sealed.authority,
                commandOutputDigest: sealed.commandOutputDigest,
                arguments: sealed.commandArguments,
                commandFormat: "git-ls-files-stage-v-z-v2",
                baseObjectID: nil,
                suppliedCreationCutProvenanceBytes: suppliedCreationCutProvenanceBytes,
                sparseCheckoutEnabled: sealed.authority.sparseCheckoutEnabled
            )
            let writer = try store.makeIndexWriter(
                identity: identity,
                resourcePolicy: evidenceResourcePolicy
            )
            do {
                var parser = GitTargetIndexStreamingParser(
                    objectFormat: sealed.authority.objectFormat,
                    rootPrefix: prefix,
                    pathPolicy: pathPolicy
                ) { record in
                    try await writer.append(record)
                }
                try await Self.consume(sealed.rawOutput, with: &parser)
                return try await writer.finish()
            } catch {
                await writer.cancel()
                throw error
            }
        } catch {
            throw Self.targetEvidenceCollectionError(error)
        }
    }

    func writeStatusEvidence(
        in layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        authorityFence: GitWorkspacePendingInitializationAuthorityFence,
        attemptID: UUID,
        suppliedCreationCutProvenanceBytes: Data?,
        store: GitTargetEvidenceManifestStore,
        includeUntracked: Bool = true,
        includeIgnored: Bool = true,
        evidenceResourcePolicy: GitTargetEvidenceResourcePolicy = .default,
        spoolResourcePolicy: GitRawOutputSpoolResourcePolicy = .default,
        pathPolicy: GitTargetEvidencePathPolicy = .init(),
        priority: GitProcessAdmissionPriority = .rootBootstrap
    ) async throws -> GitTargetStatusEvidenceLease {
        do {
            var arguments = [
                "status", "--porcelain=v2", "-z",
                includeUntracked ? "--untracked-files=all" : "--untracked-files=no"
            ]
            if includeIgnored { arguments.append("--ignored=matching") }
            appendLiteralPrefix(prefix, to: &arguments)
            let sealed = try await runSealedTargetEvidenceCommand(
                arguments,
                layout: layout,
                prefix: prefix,
                authorityFence: authorityFence,
                resourcePolicy: spoolResourcePolicy,
                priority: priority,
                family: .status
            )
            let identity = try Self.targetEvidenceIdentity(
                prefix: prefix,
                authorityFence: authorityFence,
                attemptID: attemptID,
                sealedAuthority: sealed.authority,
                commandOutputDigest: sealed.commandOutputDigest,
                arguments: sealed.commandArguments,
                commandFormat: "git-status-porcelain-v2-z-v2",
                baseObjectID: nil,
                suppliedCreationCutProvenanceBytes: suppliedCreationCutProvenanceBytes,
                sparseCheckoutEnabled: nil
            )
            let writer = try store.makeStatusWriter(
                identity: identity,
                resourcePolicy: evidenceResourcePolicy
            )
            do {
                var parser = GitTargetStatusPorcelainV2StreamingParser(
                    rootPrefix: prefix,
                    pathPolicy: pathPolicy
                ) { record in
                    try await writer.append(record)
                }
                try await Self.consume(sealed.rawOutput, with: &parser)
                return try await writer.finish()
            } catch {
                await writer.cancel()
                throw error
            }
        } catch {
            throw Self.targetEvidenceCollectionError(error)
        }
    }

    private struct GitTargetEvidenceSealedAuthority: Equatable {
        let physicalWorktree: GitTargetEvidenceFileSystemIdentity
        let repositoryCommonDirectory: GitTargetEvidenceFileSystemIdentity
        let repositoryGitDirectory: GitTargetEvidenceFileSystemIdentity
        let objectFormat: GitObjectFormat
        let headCommitOID: GitObjectID
        let headTreeOID: GitObjectID
        let indexGeneration: String
        let sparseCheckoutEnabled: Bool
        let environmentIdentity: Data
    }

    private struct GitTargetEvidenceSealedCommand {
        let rawOutput: GitRawOutputSpoolLease
        let authority: GitTargetEvidenceSealedAuthority
        let commandOutputDigest: Data
        let commandArguments: [String]
    }

    private func runSealedTargetEvidenceCommand(
        _ arguments: [String],
        layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        authorityFence: GitWorkspacePendingInitializationAuthorityFence,
        resourcePolicy: GitRawOutputSpoolResourcePolicy,
        priority: GitProcessAdmissionPriority,
        family: GitProcessCommandFamily
    ) async throws -> GitTargetEvidenceSealedCommand {
        try await validateTargetEvidenceFence(
            authorityFence,
            layout: layout,
            prefix: prefix
        )
        let environment = await Self.capabilityBoundObjectReadEnvironment(
            baseEnvironment: processEnvironment(),
            layout: layout
        )
        let environmentIdentity = Self.targetEvidenceEnvironmentIdentity(environment)
        let before = try await targetEvidenceAuthorityCapture(
            layout: layout,
            environment: environment,
            environmentIdentity: environmentIdentity,
            priority: priority,
            timeout: resourcePolicy.activityTimeout
        )
        guard before.objectFormat == authorityFence.snapshot.objectFormat,
              before.headCommitOID == authorityFence.snapshot.headCommitOID,
              before.headTreeOID == authorityFence.snapshot.treeOID,
              before.indexGeneration == authorityFence.snapshot.indexGeneration
        else { throw GitTargetEvidenceCollectionError.authorityChanged }

        #if DEBUG
            if let targetEvidenceDidSealBeforeCommandHandlerForTesting {
                try await targetEvidenceDidSealBeforeCommandHandlerForTesting()
            }
        #endif

        let commandArguments = Self.targetEvidenceGitArguments(arguments)
        let rawOutput = try await runSpoolingAuthorityGit(
            commandArguments,
            layout: layout,
            environment: environment,
            resourcePolicy: resourcePolicy,
            priority: priority,
            family: family
        )
        let commandOutputDigest = try rawOutput.sha256Digest()
        let after = try await targetEvidenceAuthorityCapture(
            layout: layout,
            environment: environment,
            environmentIdentity: environmentIdentity,
            priority: priority,
            timeout: resourcePolicy.activityTimeout
        )
        guard before == after else {
            throw GitTargetEvidenceCollectionError.authorityChanged
        }
        try await validateTargetEvidenceFence(
            authorityFence,
            layout: layout,
            prefix: prefix
        )
        return GitTargetEvidenceSealedCommand(
            rawOutput: rawOutput,
            authority: before,
            commandOutputDigest: commandOutputDigest,
            commandArguments: commandArguments
        )
    }

    private func validateTargetEvidenceFence(
        _ fence: GitWorkspacePendingInitializationAuthorityFence,
        layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix
    ) async throws {
        guard fence.targetLayout == layout,
              fence.repositoryRelativeRootPrefix == prefix,
              fence.snapshot.repositoryRelativeRootPrefix == prefix,
              fence.repositoryKey == GitWorkspaceAuthorityRepositoryKey(layout: layout),
              await workspaceStateAuthority.pendingInitializationAuthorityFenceIsCurrent(fence)
        else { throw GitTargetEvidenceCollectionError.authorityChanged }
    }

    private func targetEvidenceAuthorityCapture(
        layout: GitRepositoryLayout,
        environment: [String: String],
        environmentIdentity: Data,
        priority: GitProcessAdmissionPriority,
        timeout: Duration
    ) async throws -> GitTargetEvidenceSealedAuthority {
        let physicalWorktree = try GitTargetEvidenceFileSystemIdentity(url: layout.workTreeRoot)
        let repositoryCommonDirectory = try GitTargetEvidenceFileSystemIdentity(url: layout.commonDir)
        let repositoryGitDirectory = try GitTargetEvidenceFileSystemIdentity(url: layout.gitDir)
        let objectFormatData = try await runTargetEvidenceMetadataGit(
            ["rev-parse", "--show-object-format"],
            layout: layout,
            environment: environment,
            priority: priority,
            timeout: timeout,
            family: .treeResolution
        )
        guard let objectFormatValue = String(data: objectFormatData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw GitTargetEvidenceCollectionError.malformedGitOutput(
                "object format is not UTF-8"
            )
        }
        let objectFormat: GitObjectFormat
        do {
            objectFormat = try GitObjectFormat(gitValue: objectFormatValue)
        } catch {
            throw GitTargetEvidenceCollectionError.malformedGitOutput(
                "unsupported object format"
            )
        }
        let headCommitData = try await runTargetEvidenceMetadataGit(
            ["rev-parse", "--verify", "--end-of-options", "HEAD^{commit}"],
            layout: layout,
            environment: environment,
            priority: priority,
            timeout: timeout,
            family: .treeResolution
        )
        guard let headCommitValue = String(data: headCommitData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw GitTargetEvidenceCollectionError.malformedGitOutput(
                "HEAD commit object ID is not UTF-8"
            )
        }
        let headCommitOID = try GitObjectID(
            objectFormat: objectFormat,
            lowercaseHex: headCommitValue
        )
        let treeData = try await runTargetEvidenceMetadataGit(
            ["rev-parse", "--verify", "--end-of-options", "HEAD^{tree}"],
            layout: layout,
            environment: environment,
            priority: priority,
            timeout: timeout,
            family: .treeResolution
        )
        guard let treeValue = String(data: treeData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw GitTargetEvidenceCollectionError.malformedGitOutput(
                "HEAD tree object ID is not UTF-8"
            )
        }
        let headTreeOID = try GitObjectID(
            objectFormat: objectFormat,
            lowercaseHex: treeValue
        )
        let sparseData = try await runTargetEvidenceMetadataGit(
            ["config", "--bool", "-z", "--get", "core.sparseCheckout"],
            layout: layout,
            environment: environment,
            priority: priority,
            timeout: timeout,
            family: .authorityMetadata,
            allowedExitCodes: [0, 1]
        )
        let sparseCheckoutEnabled: Bool
        if sparseData.isEmpty || sparseData == Data("false\0".utf8) {
            sparseCheckoutEnabled = false
        } else if sparseData == Data("true\0".utf8) {
            sparseCheckoutEnabled = true
        } else {
            throw GitTargetEvidenceCollectionError.malformedGitOutput(
                "invalid core.sparseCheckout boolean"
            )
        }
        let finalPhysicalWorktree = try GitTargetEvidenceFileSystemIdentity(url: layout.workTreeRoot)
        let finalRepositoryCommonDirectory = try GitTargetEvidenceFileSystemIdentity(url: layout.commonDir)
        let finalRepositoryGitDirectory = try GitTargetEvidenceFileSystemIdentity(url: layout.gitDir)
        guard physicalWorktree == finalPhysicalWorktree,
              repositoryCommonDirectory == finalRepositoryCommonDirectory,
              repositoryGitDirectory == finalRepositoryGitDirectory
        else { throw GitTargetEvidenceCollectionError.authorityChanged }
        return try GitTargetEvidenceSealedAuthority(
            physicalWorktree: physicalWorktree,
            repositoryCommonDirectory: repositoryCommonDirectory,
            repositoryGitDirectory: repositoryGitDirectory,
            objectFormat: objectFormat,
            headCommitOID: headCommitOID,
            headTreeOID: headTreeOID,
            indexGeneration: Self.targetEvidenceIndexGeneration(layout: layout),
            sparseCheckoutEnabled: sparseCheckoutEnabled,
            environmentIdentity: environmentIdentity
        )
    }

    private func runTargetEvidenceMetadataGit(
        _ arguments: [String],
        layout: GitRepositoryLayout,
        environment: [String: String],
        priority: GitProcessAdmissionPriority,
        timeout: Duration,
        family: GitProcessCommandFamily,
        allowedExitCodes: Set<Int32> = [0]
    ) async throws -> Data {
        let admissionDeadline = priority == .rootBootstrap || priority == .userInitiatedAuthority
            ? Self.gitAdmissionDeadline(after: timeout)
            : nil
        let admissionLease = try await processAdmissionController.acquire(
            repositoryKey: layout.commonDir.standardizedFileURL.path,
            priority: priority,
            deadline: admissionDeadline
        )
        do {
            try Task.checkCancellation()
            let (stdout, stderr, exitCode) = try await runAdmittedGitData(
                Self.targetEvidenceGitArguments(arguments),
                at: layout.workTreeRoot,
                environment: environment,
                stdin: nil,
                diagnosticRepositoryPath: layout.workTreeRoot.standardizedFileURL.path,
                processQueueWaitMicroseconds: admissionLease.queueWaitMicroseconds,
                stdoutByteLimit: 4096,
                stderrByteLimit: 64 * 1024,
                admissionPriority: priority,
                commandFamily: family,
                commandTimeout: timeout
            )
            await processAdmissionController.release(admissionLease)
            guard allowedExitCodes.contains(exitCode) else {
                throw GitTargetEvidenceCollectionError.gitFailure(
                    exitCode: exitCode,
                    stderr: stderr
                )
            }
            return stdout
        } catch {
            await processAdmissionController.release(admissionLease)
            throw error
        }
    }

    private nonisolated static func targetEvidenceIdentity(
        prefix: GitRepositoryRelativeRootPrefix,
        authorityFence: GitWorkspacePendingInitializationAuthorityFence,
        attemptID: UUID,
        sealedAuthority: GitTargetEvidenceSealedAuthority,
        commandOutputDigest: Data,
        arguments: [String],
        commandFormat: String,
        baseObjectID: GitObjectID?,
        suppliedCreationCutProvenanceBytes: Data?,
        sparseCheckoutEnabled: Bool?
    ) throws -> GitTargetEvidenceArtifactIdentity {
        let snapshotDigest = targetEvidenceAuthoritySnapshotDigest(
            fence: authorityFence,
            sealedAuthority: sealedAuthority
        )
        return try GitTargetEvidenceArtifactIdentity(
            physicalWorktree: sealedAuthority.physicalWorktree,
            repositoryCommonDirectory: sealedAuthority.repositoryCommonDirectory,
            repositoryGitDirectory: sealedAuthority.repositoryGitDirectory,
            authority: GitTargetEvidenceAuthorityIdentity(
                authorityGeneration: authorityFence.lease.authorityGeneration,
                invalidationGeneration: authorityFence.lease.invalidationGeneration,
                acceptedMetadataWatermark: authorityFence.acceptedMetadataWatermark,
                attemptID: attemptID,
                snapshotDigestBytes: snapshotDigest
            ),
            commandArguments: arguments.map { Data($0.utf8) },
            commandFormatBytes: Data(commandFormat.utf8),
            environmentIdentityBytes: sealedAuthority.environmentIdentity,
            commandOutputDigestBytes: commandOutputDigest,
            repositoryRelativeRootPrefixBytes: Data(prefix.value.utf8),
            objectFormatBytes: Data(sealedAuthority.objectFormat.rawValue.utf8),
            baseObjectIDBytes: baseObjectID.map { Data($0.lowercaseHex.utf8) },
            targetObjectIDBytes: Data(sealedAuthority.headTreeOID.lowercaseHex.utf8),
            suppliedCreationCutProvenanceBytes: suppliedCreationCutProvenanceBytes,
            sparseCheckoutEnabled: sparseCheckoutEnabled
        )
    }

    private nonisolated static func targetEvidenceAuthoritySnapshotDigest(
        fence: GitWorkspacePendingInitializationAuthorityFence,
        sealedAuthority: GitTargetEvidenceSealedAuthority
    ) -> Data {
        let snapshot = fence.snapshot
        var canonical = Data("git-target-evidence-sealed-authority-v3".utf8)
        for value in [
            snapshot.repositoryNamespace.rawValue,
            snapshot.objectFormat.rawValue,
            snapshot.headCommitOID.lowercaseHex,
            snapshot.treeOID.lowercaseHex,
            sealedAuthority.objectFormat.rawValue,
            sealedAuthority.headCommitOID.lowercaseHex,
            sealedAuthority.headTreeOID.lowercaseHex,
            snapshot.repositoryRelativeRootPrefix.value,
            snapshot.repositoryBindingEpoch,
            snapshot.worktreeBindingEpoch,
            snapshot.layoutGeneration,
            snapshot.indexGeneration,
            snapshot.checkoutConfigurationGeneration,
            snapshot.metadataGeneration,
            snapshot.policyIdentity.mandatoryIgnorePolicyIdentity,
            snapshot.policyIdentity.committedIgnoreControlDigest,
            snapshot.policyIdentity.configuredIgnoreAuthorityDigest,
            snapshot.policyIdentity.attributePolicyDigest,
            snapshot.policyIdentity.sparsePolicyDigest,
            sealedAuthority.indexGeneration,
            sealedAuthority.sparseCheckoutEnabled ? "true" : "false"
        ] {
            appendLengthPrefixed(Data(value.utf8), to: &canonical)
        }
        appendUInt64(fence.lease.authorityGeneration, to: &canonical)
        appendUInt64(fence.lease.invalidationGeneration, to: &canonical)
        appendUInt64(fence.acceptedMetadataWatermark, to: &canonical)
        appendLengthPrefixed(sealedAuthority.environmentIdentity, to: &canonical)
        return Data(SHA256.hash(data: canonical))
    }

    /// Global options intentionally fixed for every Git subprocess that
    /// contributes target evidence. Local repository config remains available
    /// for data semantics, but it cannot register executable status hooks or
    /// mutable acceleration caches.
    private nonisolated static func targetEvidenceGitArguments(
        _ arguments: [String]
    ) -> [String] {
        let safetyArguments = [
            "-c", "core.fsmonitor=false",
            "-c", "core.hooksPath=/dev/null",
            "-c", "core.untrackedCache=false"
        ]
        if Array(arguments.prefix(safetyArguments.count)) == safetyArguments {
            return arguments
        }
        return safetyArguments + arguments
    }

    private nonisolated static func targetEvidenceEnvironmentIdentity(
        _ environment: [String: String]
    ) -> Data {
        var canonical = Data("git-target-evidence-environment-v1".utf8)
        let boundKeys = environment.keys.filter {
            $0.hasPrefix("GIT_") || $0 == "LC_ALL" || $0 == "LANG"
        }.sorted { Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8)) }
        for key in boundKeys {
            appendLengthPrefixed(Data(key.utf8), to: &canonical)
            appendLengthPrefixed(Data((environment[key] ?? "").utf8), to: &canonical)
        }
        return Data(SHA256.hash(data: canonical))
    }

    private nonisolated static func targetEvidenceIndexGeneration(
        layout: GitRepositoryLayout
    ) throws -> String {
        let url = layout.gitDir.appendingPathComponent("index")
        var digest = SHA256()
        func updateLengthPrefixed(_ value: Data) {
            var length = UInt64(clamping: value.count).bigEndian
            withUnsafeBytes(of: &length) { digest.update(bufferPointer: $0) }
            digest.update(data: value)
        }
        updateLengthPrefixed(Data("index".utf8))

        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 {
            guard errno == ENOENT else {
                throw GitTargetEvidenceCollectionError.io(
                    operation: "index-open",
                    code: errno
                )
            }
            updateLengthPrefixed(Data("missing".utf8))
            return Data(digest.finalize()).map { String(format: "%02x", $0) }.joined()
        }
        defer { _ = Darwin.close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0 else {
            throw GitTargetEvidenceCollectionError.io(
                operation: "index-fstat",
                code: errno
            )
        }
        guard initial.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), initial.st_size >= 0 else {
            throw GitTargetEvidenceCollectionError.authorityChanged
        }
        updateLengthPrefixed(Data("regular".utf8))
        var length = UInt64(initial.st_size).bigEndian
        withUnsafeBytes(of: &length) { digest.update(bufferPointer: $0) }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let amount = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if amount > 0 {
                digest.update(data: Data(buffer.prefix(amount)))
            } else if amount == 0 {
                break
            } else if errno != EINTR {
                throw GitTargetEvidenceCollectionError.io(
                    operation: "index-read",
                    code: errno
                )
            }
        }
        var final = stat()
        guard fstat(descriptor, &final) == 0 else {
            throw GitTargetEvidenceCollectionError.io(
                operation: "index-refstat",
                code: errno
            )
        }
        var pathStatus = stat()
        guard lstat(url.path, &pathStatus) == 0,
              initial.st_dev == final.st_dev,
              initial.st_ino == final.st_ino,
              initial.st_size == final.st_size,
              initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
              initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
              initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec,
              initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec,
              initial.st_dev == pathStatus.st_dev,
              initial.st_ino == pathStatus.st_ino
        else { throw GitTargetEvidenceCollectionError.authorityChanged }
        return Data(digest.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func consume(
        _ lease: GitRawOutputSpoolLease,
        with parser: inout GitTargetTreeDeltaStreamingParser
    ) async throws {
        let reader = try lease.makeReader()
        while let chunk = try reader.nextChunk() {
            try await parser.consume(chunk)
        }
        try await parser.finish()
    }

    private nonisolated static func consume(
        _ lease: GitRawOutputSpoolLease,
        with parser: inout GitTargetIndexStreamingParser
    ) async throws {
        let reader = try lease.makeReader()
        while let chunk = try reader.nextChunk() {
            try await parser.consume(chunk)
        }
        try await parser.finish()
    }

    private nonisolated static func consume(
        _ lease: GitRawOutputSpoolLease,
        with parser: inout GitTargetStatusPorcelainV2StreamingParser
    ) async throws {
        let reader = try lease.makeReader()
        while let chunk = try reader.nextChunk() {
            try await parser.consume(chunk)
        }
        try await parser.finish()
    }

    nonisolated static func targetEvidenceCollectionError(_ error: any Error) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? GitTargetEvidenceCollectionError { return error }
        if let error = error as? GitTargetEvidenceManifestError {
            return GitTargetEvidenceCollectionError.artifact(error)
        }
        if let error = error as? GitRawOutputSpoolError {
            return GitTargetEvidenceCollectionError.spool(error)
        }
        if let error = error as? GitProcessAdmissionError {
            return GitTargetEvidenceCollectionError.admission(error)
        }
        if let error = error as? GitWorktreeInitializationError {
            return GitTargetEvidenceCollectionError.gitInitialization(error)
        }
        if let error = error as? GitProcessCaptureError {
            return switch error {
            case .timedOut:
                GitTargetEvidenceCollectionError.activityTimeout
            case .stdoutByteLimitExceeded:
                GitTargetEvidenceCollectionError.processCapture(.stdoutLimitExceeded)
            case .stderrByteLimitExceeded:
                GitTargetEvidenceCollectionError.processCapture(.stderrLimitExceeded)
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain || nsError.domain == NSCocoaErrorDomain {
            return GitTargetEvidenceCollectionError.processLaunch(
                domain: nsError.domain,
                code: nsError.code
            )
        }
        return error
    }

    func authorityMetadata(
        in layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        priority: GitProcessAdmissionPriority = .rootBootstrap,
        cacheMode: GitPrefixControlEvidenceCacheMode = .automatic
    ) async throws -> GitWorkspaceAuthorityMetadata {
        #if DEBUG
            let authorityMetadataSpan = WorktreeStartupPreparationInstrumentation.currentRecorder?
                .begin(.authorityMetadataGit)
            defer { authorityMetadataSpan?.end() }
        #endif
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
        let indexedGitlinkData = try await indexedGitlinkAuthorityData(
            layout: layout,
            priority: priority
        )
        let indexedGitlinkPaths = try Self.indexedGitlinkPaths(
            from: indexedGitlinkData,
            objectFormat: format
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
        let globalIgnoreDefaults = await IgnoreRulesManager.shared.resolvedGlobalIgnoreContent()
        let globalIgnoreAuthorityIdentity = Self.sha256Hex(Data(globalIgnoreDefaults.utf8))
        let indexedTopologyIdentity = Self.sha256Hex(indexedGitlinkData)
        let prefixControlPolicyAuthorityIdentity = Self.sha256Hex(
            Data(globalIgnoreAuthorityIdentity.utf8) + Data(indexedTopologyIdentity.utf8)
        )
        #if DEBUG
            let collectedPrefixControlEvidence = try await workspaceStateAuthority
                .prefixControlEvidenceWithDetail(
                    in: layout,
                    prefix: prefix,
                    cacheMode: cacheMode,
                    policyAuthorityIdentity: prefixControlPolicyAuthorityIdentity
                ) {
                    let detailSink = PrefixControlCollectionDetailSink()
                    let footer = try await Self.streamedPrefixControlEvidenceCore(
                        layout: layout,
                        prefix: prefix,
                        candidateSource: nil,
                        resourcePolicy: .default,
                        collectionDetailSink: detailSink,
                        globalIgnoreDefaultsOverride: globalIgnoreDefaults,
                        indexedGitlinkPaths: indexedGitlinkPaths
                    )
                    return GitPrefixControlCollectedEvidence(
                        footer: footer,
                        collectionDetail: detailSink.snapshot()
                    )
                }
            let prefixControlEvidence = collectedPrefixControlEvidence.footer
            let cachedPrefixCollectionDetail = collectedPrefixControlEvidence.collectionDetail
        #else
            let prefixControlEvidence = try await workspaceStateAuthority.prefixControlEvidence(
                in: layout,
                prefix: prefix,
                cacheMode: cacheMode,
                policyAuthorityIdentity: prefixControlPolicyAuthorityIdentity
            ) {
                try await Self.streamedPrefixControlEvidence(
                    layout: layout,
                    prefix: prefix,
                    indexedGitlinkPaths: indexedGitlinkPaths,
                    globalIgnoreDefaultsOverride: globalIgnoreDefaults
                )
            }
        #endif
        let currentIndexedGitlinkData = try await indexedGitlinkAuthorityData(
            layout: layout,
            priority: priority
        )
        guard currentIndexedGitlinkData == indexedGitlinkData,
              await IgnoreRulesManager.shared.resolvedGlobalIgnoreContent() == globalIgnoreDefaults
        else {
            throw GitPrefixControlEvidenceManifestError.corrupt(
                "prefix-control authority changed during evaluation"
            )
        }
        let indexDigest = try Self.boundedAuthorityFileDigest([
            ("index", layout.gitDir.appendingPathComponent("index"))
        ], maximumBytesPerFile: 32 * 1024 * 1024)
        let repositoryIgnoreEvidence = try Self.boundedAuthorityFileEvidence([
            ("info/exclude", layout.commonDir.appendingPathComponent("info/exclude"))
        ])
        let repositoryIgnoreDigest = repositoryIgnoreEvidence.digest
        let repositoryAttributeEvidence = try Self.boundedAuthorityFileEvidence([
            ("info/attributes", layout.commonDir.appendingPathComponent("info/attributes"))
        ])
        let repositoryAttributeDigest = repositoryAttributeEvidence.digest
        let sparseEvidence = try Self.boundedAuthorityFileEvidence([
            ("sparse-checkout", layout.gitDir.appendingPathComponent("info/sparse-checkout"))
        ])
        let sparseDigest = sparseEvidence.digest
        let metadataDigest = try Self.boundedAuthorityFileDigest([
            ("dot-git", layout.dotGitPath),
            ("head", layout.gitDir.appendingPathComponent("HEAD")),
            ("packed-refs", layout.commonDir.appendingPathComponent("packed-refs")),
            ("config", layout.commonDir.appendingPathComponent("config")),
            ("config.worktree", layout.gitDir.appendingPathComponent("config.worktree"))
        ])
        let committedIgnoreControlDigest = Self.hex(prefixControlEvidence.ignoreControlDigest)
        let prefixAttributeDigest = Self.hex(prefixControlEvidence.attributeControlDigest)
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
        let sparsePolicyDigest = Self.sha256Hex(rootNeutralPolicyConfigData + Data(sparseDigest.utf8))
        #if DEBUG
            guard let collectionDetail = cachedPrefixCollectionDetail else {
                throw GitPrefixControlEvidenceCacheError.corruptFooter
            }
            var diagnosticCompleteness: GitWorkspacePolicyCanonicalizationDiagnostics.Completeness =
                collectionDetail.collectionCompleted ? .complete : .incomplete
            let expectedRecordCount = collectionDetail.ignoreControlCount.addingReportingOverflow(
                collectionDetail.attributeControlCount
            )
            if collectionDetail.collectionCompleted,
               expectedRecordCount.overflow
               || UInt64(exactly: expectedRecordCount.partialValue) != prefixControlEvidence.recordCount
            {
                diagnosticCompleteness = .incomplete
            }
            var committedControlCount = 0
            var committedControlSummarySHA256 = Self.emptyCommittedControlSummarySHA256
            if collectionDetail.collectionCompleted {
                do {
                    let committed = try await committedControlDiagnostics(
                        treeOID: tree,
                        layout: layout,
                        priority: priority
                    )
                    committedControlCount = committed.totalCount
                    committedControlSummarySHA256 = committed.summarySHA256
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    diagnosticCompleteness = .incomplete
                }
            }
            func commonAuthorityState(
                _ value: BoundedAuthorityFileState?
            ) -> GitWorkspacePolicyCanonicalizationDiagnostics.CommonAuthorityState {
                switch value {
                case .missing: return .missing
                case .directory: return .directory
                case .regular: return .regular
                case nil:
                    diagnosticCompleteness = .incomplete
                    return .missing
                }
            }
            func externalAuthorityIdentity(
                url: URL?,
                identity: GitWorkspaceAuthorityContentIdentity?
            ) -> GitWorkspacePolicyCanonicalizationDiagnostics.ExternalAuthorityIdentity {
                let state: GitWorkspacePolicyCanonicalizationDiagnostics.ExternalAuthorityState = if url == nil {
                    .unset
                } else if identity?.exists == true {
                    .present
                } else {
                    .missing
                }
                return .init(
                    state: state,
                    identityDigest: Self.sha256Hex(Self.canonicalOptionalContentIdentityData(identity)),
                    byteCount: identity?.byteCount ?? 0
                )
            }
            let canonicalizationDiagnostics = GitWorkspacePolicyCanonicalizationDiagnostics(
                rootNeutralPolicyConfigByteCount: rootNeutralPolicyConfigData.count,
                rootNeutralPolicyConfigSHA256: Self.sha256Hex(rootNeutralPolicyConfigData),
                commonInfoExclude: .init(
                    state: commonAuthorityState(repositoryIgnoreEvidence.statesByLabel["info/exclude"]),
                    digest: repositoryIgnoreDigest
                ),
                canonicalIgnoreFooter: .init(
                    digest: committedIgnoreControlDigest,
                    recordCount: collectionDetail.ignoreControlCount
                ),
                externalExcludes: externalAuthorityIdentity(
                    url: resolvedExcludesFileURL,
                    identity: resolvedExcludesFileIdentity
                ),
                configuredIgnorePolicyDigest: configuredIgnoreAuthorityDigest,
                commonInfoAttributes: .init(
                    state: commonAuthorityState(
                        repositoryAttributeEvidence.statesByLabel["info/attributes"]
                    ),
                    digest: repositoryAttributeDigest
                ),
                canonicalAttributeFooter: .init(
                    digest: prefixAttributeDigest,
                    recordCount: collectionDetail.attributeControlCount
                ),
                externalAttributes: externalAuthorityIdentity(
                    url: resolvedAttributesFileURL,
                    identity: resolvedAttributesFileIdentity
                ),
                attributePolicyDigest: attributePolicyDigest,
                sparsePolicyDigest: sparsePolicyDigest,
                canonicalizationPolicyVersion: WorkspaceGitignorePolicyIdentity.current.rawValue,
                prunedRootCount: collectionDetail.prunedRootCount,
                prunedRootSummarySHA256: collectionDetail.prunedRootSummarySHA256,
                completeness: diagnosticCompleteness,
                committedControlCount: committedControlCount,
                committedControlSummarySHA256: committedControlSummarySHA256
            )
            let policyIdentity = GitWorkspacePolicyIdentity(
                mandatoryIgnorePolicyIdentity: WorkspaceGitignorePolicyIdentity.current.rawValue,
                committedIgnoreControlDigest: committedIgnoreControlDigest,
                configuredIgnoreAuthorityDigest: configuredIgnoreAuthorityDigest,
                attributePolicyDigest: attributePolicyDigest,
                sparsePolicyDigest: sparsePolicyDigest,
                searchABI: .current,
                resolvedExcludesFileIdentity: resolvedExcludesFileIdentity,
                resolvedAttributesFileIdentity: resolvedAttributesFileIdentity,
                canonicalizationDiagnostics: canonicalizationDiagnostics
            )
        #else
            let policyIdentity = GitWorkspacePolicyIdentity(
                mandatoryIgnorePolicyIdentity: WorkspaceGitignorePolicyIdentity.current.rawValue,
                committedIgnoreControlDigest: committedIgnoreControlDigest,
                configuredIgnoreAuthorityDigest: configuredIgnoreAuthorityDigest,
                attributePolicyDigest: attributePolicyDigest,
                sparsePolicyDigest: sparsePolicyDigest,
                searchABI: .current,
                resolvedExcludesFileIdentity: resolvedExcludesFileIdentity,
                resolvedAttributesFileIdentity: resolvedAttributesFileIdentity
            )
        #endif
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
        priority: GitProcessAdmissionPriority = .rootBootstrap,
        cacheMode: GitPrefixControlEvidenceCacheMode = .automatic
    ) async throws -> (metadata: GitWorkspaceAuthorityMetadata, snapshot: GitWorkspaceAuthoritySnapshot) {
        let metadata = try await authorityMetadata(
            in: layout,
            prefix: prefix,
            priority: priority,
            cacheMode: cacheMode
        )
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

    private func indexedGitlinkAuthorityData(
        layout: GitRepositoryLayout,
        priority: GitProcessAdmissionPriority
    ) async throws -> Data {
        try await runBoundedAuthorityGit(
            Self.targetEvidenceGitArguments(["ls-files", "--stage", "-z"]),
            layout: layout,
            limits: GitWorktreeInitializationLimits(
                maximumRecordCount: .max,
                maximumOutputBytes: 128 * 1024 * 1024,
                commandTimeout: .seconds(10)
            ),
            priority: priority,
            family: .authorityMetadata
        )
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

    #if DEBUG
        private struct CommittedControlDiagnosticsResult {
            let totalCount: Int
            let summarySHA256: String
        }

        private static let committedControlSummaryDomain = Data("rpce-committed-control-summary-v1".utf8)
        private static let maximumCommittedControlTreeRecordBytes = 4 * 1024 * 1024

        /// Produces exact aggregate evidence without retaining a record array or
        /// imposing a repository-cardinality ceiling. `ls-tree` output is
        /// descriptor-bound and disk-spooled under `GitRawOutputSpoolResourcePolicy`;
        /// resident parsing is limited to one tree record plus one read chunk.
        /// Spool admission and per-record framing overflow are explicit failures,
        /// which the caller publishes as incomplete diagnostics rather than a
        /// deceptively complete truncated inventory.
        private func committedControlDiagnostics(
            treeOID: GitObjectID,
            layout: GitRepositoryLayout,
            priority: GitProcessAdmissionPriority
        ) async throws -> CommittedControlDiagnosticsResult {
            let prefix = try GitRepositoryRelativeRootPrefix("")
            let inventory = try await spoolLoadedRootTreeInventory(
                treeOID,
                in: layout,
                prefix: prefix,
                priority: priority
            )
            return try Self.committedControlDiagnostics(
                from: inventory.rawOutput,
                objectFormat: treeOID.objectFormat
            )
        }

        private static func committedControlDiagnostics(
            from rawOutput: GitRawOutputSpoolLease,
            objectFormat: GitObjectFormat
        ) throws -> CommittedControlDiagnosticsResult {
            let kinds: [String: GitWorkspacePrefixControlKind] = [
                ".gitignore": .gitignore,
                ".repo_ignore": .repoIgnore,
                ".cursorignore": .cursorIgnore,
                ".gitattributes": .gitAttributes
            ]
            let reader = try rawOutput.makeReader()
            var pending = Data()
            var totalCount = 0
            var digest = SHA256()
            updateLengthPrefixed(committedControlSummaryDomain, digest: &digest)

            func consume(_ rawRecord: Data) throws {
                try Task.checkCancellation()
                guard !rawRecord.isEmpty,
                      let tab = rawRecord.firstIndex(of: UInt8(ascii: "\t")),
                      let metadata = String(data: Data(rawRecord[..<tab]), encoding: .utf8),
                      let path = String(
                          data: Data(rawRecord[rawRecord.index(after: tab)...]),
                          encoding: .utf8
                      )
                else {
                    throw GitWorktreeInitializationError.malformedOutput("ls-tree diagnostics are malformed")
                }
                let fields = metadata.split(whereSeparator: \.isWhitespace)
                guard fields.count == 3 else {
                    throw GitWorktreeInitializationError.malformedOutput("ls-tree diagnostics fields are malformed")
                }
                guard fields[1] == "blob",
                      let kind = kinds[path.split(separator: "/").last.map(String.init) ?? ""]
                else { return }
                let oid = String(fields[2])
                _ = try GitObjectID(objectFormat: objectFormat, lowercaseHex: oid)
                let nextCount = totalCount.addingReportingOverflow(1)
                guard !nextCount.overflow else { throw GitWorktreeInitializationError.outputLimitExceeded }
                totalCount = nextCount.partialValue

                // Git's object ID is the authoritative content address. Hashing
                // the canonical ordered path/kind/OID tuple preserves exact
                // equivalence evidence without loading each blob or retaining it.
                updateLengthPrefixed(Data(path.utf8), digest: &digest)
                updateLengthPrefixed(Data(kind.rawValue.utf8), digest: &digest)
                updateLengthPrefixed(Data(oid.utf8), digest: &digest)
            }

            while let chunk = try reader.nextChunk() {
                var start = chunk.startIndex
                while let terminator = chunk[start...].firstIndex(of: 0) {
                    let segment = chunk[start ..< terminator]
                    let (proposedCount, overflowed) = pending.count.addingReportingOverflow(segment.count)
                    guard !overflowed, proposedCount <= maximumCommittedControlTreeRecordBytes else {
                        throw GitWorktreeInitializationError.outputLimitExceeded
                    }
                    pending.append(contentsOf: segment)
                    try consume(pending)
                    pending.removeAll(keepingCapacity: true)
                    start = chunk.index(after: terminator)
                }
                let trailing = chunk[start...]
                let (proposedCount, overflowed) = pending.count.addingReportingOverflow(trailing.count)
                guard !overflowed, proposedCount <= maximumCommittedControlTreeRecordBytes else {
                    throw GitWorktreeInitializationError.outputLimitExceeded
                }
                pending.append(contentsOf: trailing)
            }
            guard pending.isEmpty else {
                throw GitWorktreeInitializationError.malformedOutput("ls-tree diagnostics are not NUL terminated")
            }
            return CommittedControlDiagnosticsResult(
                totalCount: totalCount,
                summarySHA256: digest.finalize().map { String(format: "%02x", $0) }.joined()
            )
        }

        private static func updateLengthPrefixed(_ value: Data, digest: inout SHA256) {
            var count = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &count) { digest.update(bufferPointer: $0) }
            digest.update(data: value)
        }

        private static var emptyCommittedControlSummarySHA256: String {
            var digest = SHA256()
            updateLengthPrefixed(committedControlSummaryDomain, digest: &digest)
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
    #endif

    private enum BoundedAuthorityFileState {
        case missing
        case directory
        case regular
    }

    private struct BoundedAuthorityFileEvidence {
        let digest: String
        let statesByLabel: [String: BoundedAuthorityFileState]
    }

    private nonisolated static func boundedAuthorityFileEvidence(
        _ files: [(String, URL)],
        maximumBytesPerFile: Int = 4 * 1024 * 1024
    ) throws -> BoundedAuthorityFileEvidence {
        var canonical = Data()
        var statesByLabel: [String: BoundedAuthorityFileState] = [:]
        for (label, url) in files.sorted(by: { $0.0 < $1.0 }) {
            appendLengthPrefixed(Data(label.utf8), to: &canonical)
            var value = stat()
            if lstat(url.path, &value) != 0 {
                guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                statesByLabel[label] = .missing
                appendLengthPrefixed(Data("missing".utf8), to: &canonical)
                continue
            }
            let kind = value.st_mode & S_IFMT
            if kind == S_IFDIR {
                statesByLabel[label] = .directory
                appendLengthPrefixed(Data("directory".utf8), to: &canonical)
                continue
            }
            guard kind == S_IFREG else {
                throw GitWorktreeInitializationError.malformedOutput("authority evidence is not a regular file")
            }
            statesByLabel[label] = .regular
            appendLengthPrefixed(Data("regular".utf8), to: &canonical)
            let data = try boundedRead(url, maximumBytes: maximumBytesPerFile)
            appendLengthPrefixed(data, to: &canonical)
        }
        return BoundedAuthorityFileEvidence(
            digest: sha256Hex(canonical),
            statesByLabel: statesByLabel
        )
    }

    private nonisolated static func boundedAuthorityFileDigest(
        _ files: [(String, URL)],
        maximumBytesPerFile: Int = 4 * 1024 * 1024
    ) throws -> String {
        try boundedAuthorityFileEvidence(files, maximumBytesPerFile: maximumBytesPerFile).digest
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

    private nonisolated static func indexedGitlinkPaths(
        from data: Data,
        objectFormat: GitObjectFormat
    ) throws -> Set<String> {
        var paths: Set<String> = []
        for rawRecord in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard let tab = rawRecord.firstIndex(of: UInt8(ascii: "\t")),
                  let metadata = String(data: Data(rawRecord[..<tab]), encoding: .utf8),
                  let path = String(data: Data(rawRecord[rawRecord.index(after: tab)...]), encoding: .utf8)
            else {
                throw GitWorktreeInitializationError.malformedOutput("indexed Git topology is malformed")
            }
            let fields = metadata.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 3,
                  fields[0].count == 6,
                  fields[0].utf8.allSatisfy({ (UInt8(ascii: "0") ... UInt8(ascii: "7")).contains($0) }),
                  let stage = Int(fields[2]),
                  (0 ... 3).contains(stage)
            else {
                throw GitWorktreeInitializationError.malformedOutput("indexed Git topology fields are malformed")
            }
            _ = try GitObjectID(objectFormat: objectFormat, lowercaseHex: String(fields[1]))
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty,
                  path.utf8.count <= 16 * 1024,
                  components.count <= 512,
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            else { throw GitWorktreeInitializationError.pathLimitExceeded }
            if fields[0] == "160000" {
                paths.insert(path)
            }
        }
        return paths
    }

    private struct PrefixControlStableRead {
        let identity: GitWorkspaceAuthorityContentIdentity
        let data: Data
        let device: dev_t
        let inode: ino_t
    }

    private struct PrefixControlObservedIdentity {
        let identity: GitWorkspaceAuthorityContentIdentity
        let device: dev_t
        let inode: ino_t

        init(_ read: PrefixControlStableRead) {
            identity = read.identity
            device = read.device
            inode = read.inode
        }

        func matches(_ read: PrefixControlStableRead) -> Bool {
            identity == read.identity && device == read.device && inode == read.inode
        }
    }

    private struct PrefixControlDirectoryIdentity {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }

        func matches(_ value: stat) -> Bool {
            value.st_mode & S_IFMT == S_IFDIR
                && device == value.st_dev
                && inode == value.st_ino
                && size == value.st_size
                && modifiedSeconds == value.st_mtimespec.tv_sec
                && modifiedNanoseconds == value.st_mtimespec.tv_nsec
                && changedSeconds == value.st_ctimespec.tv_sec
                && changedNanoseconds == value.st_ctimespec.tv_nsec
        }
    }

    private struct PrefixControlDirectoryObservation {
        let url: URL
        let identity: PrefixControlDirectoryIdentity
        let observedControls: [String: PrefixControlObservedIdentity]
        let missingControls: Set<String>
        let validatesControls: Bool
        let requiresMissingNestedGitBoundary: Bool
    }

    private final class PrefixControlCollectionDetailSink: @unchecked Sendable {
        private static let prunedRootSummaryDomain = Data("rpce-pruned-root-summary-v1".utf8)

        private let lock = NSLock()
        private var collectionCompleted = false
        private var ignoreControlCount = 0
        private var attributeControlCount = 0
        private var prunedRootCount = 0
        private var prunedRootSummary = SHA256()

        init() {
            Self.updateLengthPrefixed(Self.prunedRootSummaryDomain, digest: &prunedRootSummary)
        }

        func markCompleted() {
            lock.lock()
            collectionCompleted = true
            lock.unlock()
        }

        func recordControl(kind: GitWorkspacePrefixControlKind) throws {
            lock.lock()
            defer { lock.unlock() }
            switch kind {
            case .gitAttributes:
                let next = attributeControlCount.addingReportingOverflow(1)
                guard !next.overflow else { throw GitWorktreeInitializationError.outputLimitExceeded }
                attributeControlCount = next.partialValue
            case .gitignore, .repoIgnore, .cursorIgnore:
                let next = ignoreControlCount.addingReportingOverflow(1)
                guard !next.overflow else { throw GitWorktreeInitializationError.outputLimitExceeded }
                ignoreControlCount = next.partialValue
            }
        }

        func recordPrunedRoot(fingerprint: String) throws {
            lock.lock()
            defer { lock.unlock() }
            guard fingerprint.utf8.count == SHA256.byteCount * 2 else {
                throw GitWorktreeInitializationError.malformedOutput("invalid pruned-root fingerprint")
            }
            let next = prunedRootCount.addingReportingOverflow(1)
            guard !next.overflow else { throw GitWorktreeInitializationError.outputLimitExceeded }
            prunedRootCount = next.partialValue
            Self.updateLengthPrefixed(Data(fingerprint.utf8), digest: &prunedRootSummary)
        }

        func snapshot() -> GitPrefixControlCollectionDetail {
            lock.lock()
            defer { lock.unlock() }
            var summary = prunedRootSummary
            return GitPrefixControlCollectionDetail(
                collectionCompleted: collectionCompleted,
                ignoreControlCount: ignoreControlCount,
                attributeControlCount: attributeControlCount,
                prunedRootCount: prunedRootCount,
                prunedRootSummarySHA256: summary.finalize().map { String(format: "%02x", $0) }.joined()
            )
        }

        private static func updateLengthPrefixed(_ value: Data, digest: inout SHA256) {
            var count = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &count) { digest.update(bufferPointer: $0) }
            digest.update(data: value)
        }
    }

    private struct PrefixControlReachabilityRules {
        let gitignoreOnly: IgnoreRules
        let gitignoreAndRepo: IgnoreRules
        let gitignoreAndCursor: IgnoreRules
        let allRepositoryLocal: IgnoreRules

        static func root(
            authority: IgnoreRulesManager.CompiledRootAuthority,
            repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix
        ) -> PrefixControlReachabilityRules {
            let policy = IgnoreRulePolicy.gitRoot(
                repositoryRelativeRootPrefix: repositoryRelativeRootPrefix
            )
            return PrefixControlReachabilityRules(
                gitignoreOnly: IgnoreRulesManager.makeRootRules(
                    authority: authority,
                    respectRepoIgnore: false,
                    respectCursorignore: false,
                    policy: policy
                ),
                gitignoreAndRepo: IgnoreRulesManager.makeRootRules(
                    authority: authority,
                    respectRepoIgnore: true,
                    respectCursorignore: false,
                    policy: policy
                ),
                gitignoreAndCursor: IgnoreRulesManager.makeRootRules(
                    authority: authority,
                    respectRepoIgnore: false,
                    respectCursorignore: true,
                    policy: policy
                ),
                allRepositoryLocal: IgnoreRulesManager.makeRootRules(
                    authority: authority,
                    respectRepoIgnore: true,
                    respectCursorignore: true,
                    policy: policy
                )
            )
        }

        func adding(
            gitignore: Data?,
            repoIgnore: Data?,
            cursorignore: Data?,
            directoryPath: String
        ) throws -> PrefixControlReachabilityRules {
            let next = PrefixControlReachabilityRules(
                gitignoreOnly: gitignoreOnly.clone(),
                gitignoreAndRepo: gitignoreAndRepo.clone(),
                gitignoreAndCursor: gitignoreAndCursor.clone(),
                allRepositoryLocal: allRepositoryLocal.clone()
            )
            if let gitignore {
                let content = try IgnoreRulesManager.decodeMandatoryGitIgnoreContent(gitignore)
                let compiled = GitignoreCompiler.compile(content: content, directoryPath: directoryPath)
                next.gitignoreOnly.addCompiledLayer(compiled, authority: .mandatoryGit)
                next.gitignoreAndRepo.addCompiledLayer(compiled, authority: .mandatoryGit)
                next.gitignoreAndCursor.addCompiledLayer(compiled, authority: .mandatoryGit)
                next.allRepositoryLocal.addCompiledLayer(compiled, authority: .mandatoryGit)
            }
            if let repoIgnore, let content = String(data: repoIgnore, encoding: .utf8) {
                let compiled = GitignoreCompiler.compile(content: content, directoryPath: directoryPath)
                next.gitignoreAndRepo.addCompiledLayer(compiled, authority: .secondary)
                next.allRepositoryLocal.addCompiledLayer(compiled, authority: .secondary)
            }
            if let cursorignore, let content = String(data: cursorignore, encoding: .utf8) {
                let compiled = GitignoreCompiler.compile(content: content, directoryPath: directoryPath)
                next.gitignoreAndCursor.addCompiledLayer(compiled, authority: .secondary)
                next.allRepositoryLocal.addCompiledLayer(compiled, authority: .secondary)
            }
            return next
        }

        func unanimouslyRejectTraversal(of repositoryRelativeDirectory: String) -> Bool {
            [gitignoreOnly, gitignoreAndRepo, gitignoreAndCursor, allRepositoryLocal].allSatisfy { rules in
                !WorkspaceCatalogDirectoryReachability.shouldTraverse(
                    repositoryRelativeDirectory: repositoryRelativeDirectory,
                    rules: rules.snapshot()
                )
            }
        }
    }

    private struct PrefixControlDirectoryFrame {
        let repositoryRelativeDirectory: String
        let rules: PrefixControlReachabilityRules
        let observedControls: [String: PrefixControlObservedIdentity]
    }

    static func streamedPrefixControlEvidence(
        layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        indexedGitlinkPaths: Set<String>,
        candidateSource suppliedSource: GitPrefixControlCandidateSource? = nil,
        resourcePolicy: GitPrefixControlEvidenceResourcePolicy = .default,
        globalIgnoreDefaultsOverride: String? = nil,
        postArtifactFinalizationHook: (@Sendable () async throws -> Void)? = nil
    ) async throws -> GitPrefixControlEvidenceManifestFooter {
        try await streamedPrefixControlEvidenceCore(
            layout: layout,
            prefix: prefix,
            candidateSource: suppliedSource,
            resourcePolicy: resourcePolicy,
            collectionDetailSink: nil,
            globalIgnoreDefaultsOverride: globalIgnoreDefaultsOverride,
            indexedGitlinkPaths: indexedGitlinkPaths,
            postArtifactFinalizationHook: postArtifactFinalizationHook
        )
    }

    private static func streamedPrefixControlEvidenceCore(
        layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        candidateSource suppliedSource: GitPrefixControlCandidateSource?,
        resourcePolicy: GitPrefixControlEvidenceResourcePolicy,
        collectionDetailSink: PrefixControlCollectionDetailSink?,
        globalIgnoreDefaultsOverride: String? = nil,
        indexedGitlinkPaths: Set<String>,
        postArtifactFinalizationHook: (@Sendable () async throws -> Void)? = nil
    ) async throws -> GitPrefixControlEvidenceManifestFooter {
        #if DEBUG
            let recorder = WorktreeStartupPreparationInstrumentation.currentRecorder
            let scanSpan = recorder?.begin(.prefixControlScan)
            recorder?.increment(.prefixScanCount)
            defer { scanSpan?.end() }
            var unpublishedCandidateCount: UInt64 = 0
            var unpublishedDirectoryCount: UInt64 = 0
            var unpublishedPrunedDirectoryCount: UInt64 = 0
            var controlRecordCount: UInt64 = 0
            func publishPrefixControlProgress(force: Bool = false) {
                guard force || unpublishedCandidateCount >= 4096 else { return }
                recorder?.increment(.enumeratedCandidates, by: unpublishedCandidateCount)
                recorder?.increment(.enumeratedDirectories, by: unpublishedDirectoryCount)
                recorder?.increment(.explicitlyPrunedDirectories, by: unpublishedPrunedDirectoryCount)
                unpublishedCandidateCount = 0
                unpublishedDirectoryCount = 0
                unpublishedPrunedDirectoryCount = 0
            }
        #endif
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
        let initialIndexAuthorityIdentity = try boundedAuthorityFileDigest([
            ("index", layout.gitDir.appendingPathComponent("index"))
        ], maximumBytesPerFile: 32 * 1024 * 1024)
        var rootStatus = stat()
        guard lstat(prefixRoot.path, &rootStatus) == 0,
              rootStatus.st_mode & S_IFMT == S_IFDIR
        else {
            throw GitWorktreeInitializationError.malformedOutput("loaded-root prefix directory is unavailable")
        }
        let globalIgnoreContent = if let globalIgnoreDefaultsOverride {
            globalIgnoreDefaultsOverride
        } else {
            await IgnoreRulesManager.shared.resolvedGlobalIgnoreContent()
        }
        var retainedControlBytes = UInt64(globalIgnoreContent.utf8.count)
        guard retainedControlBytes <= resourcePolicy.maximumAggregateControlBytes else {
            throw GitWorktreeInitializationError.outputLimitExceeded
        }
        let store = try GitPrefixControlEvidenceManifestStore()
        let writer = try store.makeWriter(
            rootPrefixBytes: Data(prefix.value.utf8),
            resourcePolicy: resourcePolicy
        )
        var directoryObservations: [PrefixControlDirectoryObservation] = []

        func retainControlBytes(_ read: PrefixControlStableRead, relativePath: String) throws {
            let overhead = 256
            let (dataAndPath, firstOverflow) = read.data.count.addingReportingOverflow(relativePath.utf8.count)
            let (total, secondOverflow) = dataAndPath.addingReportingOverflow(overhead)
            guard !firstOverflow, !secondOverflow, let amount = UInt64(exactly: total) else {
                throw GitWorktreeInitializationError.outputLimitExceeded
            }
            let (next, overflow) = retainedControlBytes.addingReportingOverflow(amount)
            guard !overflow, next <= resourcePolicy.maximumAggregateControlBytes else {
                throw GitWorktreeInitializationError.outputLimitExceeded
            }
            retainedControlBytes = next
        }

        @discardableResult
        func appendCandidate(
            _ url: URL,
            kind: GitWorkspacePrefixControlKind,
            stableRead suppliedRead: PrefixControlStableRead? = nil
        ) async throws -> PrefixControlStableRead {
            let standardized = url.standardizedFileURL
            let rootPath = root.path
            guard standardized.path.hasPrefix(rootPath + "/") else {
                throw GitWorktreeInitializationError.malformedOutput("control path escapes repository root")
            }
            let relative = String(standardized.path.dropFirst(rootPath.count + 1))
            let components = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard !relative.isEmpty,
                  relative.utf8.count <= 16 * 1024,
                  components.count <= 512,
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            else { throw GitWorktreeInitializationError.pathLimitExceeded }
            let stableRead: PrefixControlStableRead = if let suppliedRead {
                suppliedRead
            } else {
                try streamedAuthorityContent(at: standardized)
            }
            if suppliedRead != nil {
                try retainControlBytes(stableRead, relativePath: relative)
            }
            try await writer.append(GitPrefixControlEvidenceRecord(
                repositoryRelativePathBytes: Data(relative.utf8),
                kind: kind,
                content: stableRead.identity
            ))
            #if DEBUG
                try collectionDetailSink?.recordControl(kind: kind)
                controlRecordCount &+= 1
            #endif
            return stableRead
        }

        func recordDirectoryObservation(
            directoryURL: URL,
            repositoryRelativeDirectory: String,
            observedControls: [String: PrefixControlObservedIdentity] = [:],
            missingControls: Set<String> = [],
            validatesControls: Bool,
            requiresMissingNestedGitBoundary: Bool
        ) throws {
            var value = stat()
            guard lstat(directoryURL.path, &value) == 0,
                  value.st_mode & S_IFMT == S_IFDIR
            else {
                throw GitWorktreeInitializationError.malformedOutput(
                    "prefix control directory topology changed during observation"
                )
            }
            let overhead = 1024
            let (bytes, overflow) = repositoryRelativeDirectory.utf8.count.addingReportingOverflow(overhead)
            guard !overflow, let amount = UInt64(exactly: bytes) else {
                throw GitWorktreeInitializationError.outputLimitExceeded
            }
            let (next, aggregateOverflow) = retainedControlBytes.addingReportingOverflow(amount)
            guard !aggregateOverflow, next <= resourcePolicy.maximumAggregateControlBytes else {
                throw GitWorktreeInitializationError.outputLimitExceeded
            }
            retainedControlBytes = next
            directoryObservations.append(PrefixControlDirectoryObservation(
                url: directoryURL.standardizedFileURL,
                identity: PrefixControlDirectoryIdentity(value),
                observedControls: observedControls,
                missingControls: missingControls,
                validatesControls: validatesControls,
                requiresMissingNestedGitBoundary: requiresMissingNestedGitBoundary
            ))
        }

        func readDirectoryControls(
            directoryURL: URL,
            repositoryRelativeDirectory: String,
            inheritedRules: PrefixControlReachabilityRules?,
            isRepositoryRoot: Bool = false
        ) async throws -> PrefixControlDirectoryFrame {
            if !repositoryRelativeDirectory.isEmpty,
               indexedGitlinkPaths.contains(repositoryRelativeDirectory)
            {
                throw GitWorktreeInitializationError.malformedOutput(
                    "prefix control enumeration reached an indexed Git topology boundary"
                )
            }
            if !isRepositoryRoot {
                var nestedBoundaryStatus = stat()
                let nestedBoundary = directoryURL.appendingPathComponent(".git")
                if lstat(nestedBoundary.path, &nestedBoundaryStatus) == 0 {
                    throw GitWorktreeInitializationError.malformedOutput(
                        "prefix control enumeration reached a nested Git topology boundary"
                    )
                } else if errno != ENOENT {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            let orderedControls: [(String, GitWorkspacePrefixControlKind)] = [
                (".gitignore", .gitignore),
                (".repo_ignore", .repoIgnore),
                (".cursorignore", .cursorIgnore),
                (".gitattributes", .gitAttributes)
            ]
            var observed: [String: PrefixControlObservedIdentity] = [:]
            var missing: Set<String> = []
            var ruleData: [GitWorkspacePrefixControlKind: Data] = [:]
            for (name, kind) in orderedControls {
                try Task.checkCancellation()
                let url = directoryURL.appendingPathComponent(name)
                var status = stat()
                if lstat(url.path, &status) == 0 {
                    let stableRead = try streamedAuthorityContent(at: url)
                    try await appendCandidate(url, kind: kind, stableRead: stableRead)
                    observed[name] = PrefixControlObservedIdentity(stableRead)
                    ruleData[kind] = stableRead.data
                } else if errno != ENOENT {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                } else {
                    missing.insert(name)
                }
            }
            try recordDirectoryObservation(
                directoryURL: directoryURL,
                repositoryRelativeDirectory: repositoryRelativeDirectory,
                observedControls: observed,
                missingControls: missing,
                validatesControls: true,
                requiresMissingNestedGitBoundary: !isRepositoryRoot
            )
            let rules: PrefixControlReachabilityRules
            if isRepositoryRoot {
                rules = try .root(
                    authority: IgnoreRulesManager.compileRootAuthority(
                        gitignoreContent: ruleData[.gitignore].map {
                            try IgnoreRulesManager.decodeMandatoryGitIgnoreContent($0)
                        },
                        globalIgnoreContent: globalIgnoreContent,
                        repoIgnoreContent: ruleData[.repoIgnore].flatMap { String(data: $0, encoding: .utf8) },
                        cursorignoreContent: ruleData[.cursorIgnore].flatMap { String(data: $0, encoding: .utf8) }
                    ),
                    repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix("")
                )
            } else {
                guard let inheritedRules else {
                    throw GitWorktreeInitializationError.malformedOutput(
                        "prefix control enumeration has no inherited reachability policy"
                    )
                }
                rules = try inheritedRules.adding(
                    gitignore: ruleData[.gitignore],
                    repoIgnore: ruleData[.repoIgnore],
                    cursorignore: ruleData[.cursorIgnore],
                    directoryPath: repositoryRelativeDirectory
                )
            }
            return PrefixControlDirectoryFrame(
                repositoryRelativeDirectory: repositoryRelativeDirectory,
                rules: rules,
                observedControls: observed
            )
        }

        func validatedRelativePath(for url: URL) throws -> (path: String, components: [Substring]) {
            let standardized = url.standardizedFileURL
            let rootPath = root.path
            guard standardized.path.hasPrefix(rootPath + "/") else {
                throw GitWorktreeInitializationError.malformedOutput("control path escapes repository root")
            }
            let relative = String(standardized.path.dropFirst(rootPath.count + 1))
            let components = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard !relative.isEmpty,
                  relative.utf8.count <= 16 * 1024,
                  components.count <= 512,
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            else { throw GitWorktreeInitializationError.pathLimitExceeded }
            return (relative, components)
        }

        func validateObservedAuthority() throws {
            for observation in directoryObservations {
                try Task.checkCancellation()
                var directoryStatus = stat()
                guard lstat(observation.url.path, &directoryStatus) == 0,
                      observation.identity.matches(directoryStatus)
                else {
                    throw GitPrefixControlEvidenceManifestError.corrupt(
                        "directory changed during prefix-control finalization"
                    )
                }
                if observation.requiresMissingNestedGitBoundary {
                    var nestedBoundaryStatus = stat()
                    let nestedBoundary = observation.url.appendingPathComponent(".git")
                    guard lstat(nestedBoundary.path, &nestedBoundaryStatus) != 0,
                          errno == ENOENT
                    else {
                        throw GitPrefixControlEvidenceManifestError.corrupt(
                            "nested Git topology changed during prefix-control finalization"
                        )
                    }
                }
                guard observation.validatesControls else { continue }
                for (name, observed) in observation.observedControls {
                    let current = try streamedAuthorityContent(at: observation.url.appendingPathComponent(name))
                    guard observed.matches(current) else {
                        throw GitPrefixControlEvidenceManifestError.corrupt(
                            "control changed during prefix-control finalization"
                        )
                    }
                }
                for name in observation.missingControls {
                    var controlStatus = stat()
                    let control = observation.url.appendingPathComponent(name)
                    guard lstat(control.path, &controlStatus) != 0,
                          errno == ENOENT
                    else {
                        throw GitPrefixControlEvidenceManifestError.corrupt(
                            "control appeared during prefix-control finalization"
                        )
                    }
                }
            }
            let currentIndexAuthorityIdentity = try boundedAuthorityFileDigest([
                ("index", layout.gitDir.appendingPathComponent("index"))
            ], maximumBytesPerFile: 32 * 1024 * 1024)
            guard currentIndexAuthorityIdentity == initialIndexAuthorityIdentity else {
                throw GitPrefixControlEvidenceManifestError.corrupt(
                    "indexed Git topology changed during prefix-control finalization"
                )
            }
        }

        do {
            var ancestor = root
            var ancestorRelativePath = ""
            var ancestorRules: PrefixControlReachabilityRules?
            let components = prefix.value.isEmpty ? [] : prefix.value.split(separator: "/").map(String.init)
            var prefixFrame: PrefixControlDirectoryFrame?
            for depth in 0 ... components.count {
                if depth > 0 {
                    var nestedBoundaryStatus = stat()
                    let nestedBoundary = ancestor.appendingPathComponent(".git")
                    if lstat(nestedBoundary.path, &nestedBoundaryStatus) == 0 {
                        throw GitWorktreeInitializationError.malformedOutput(
                            "loaded-root prefix crosses a nested Git topology boundary"
                        )
                    } else if errno != ENOENT {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
                let frame = try await readDirectoryControls(
                    directoryURL: ancestor,
                    repositoryRelativeDirectory: ancestorRelativePath,
                    inheritedRules: ancestorRules,
                    isRepositoryRoot: depth == 0
                )
                ancestorRules = frame.rules
                prefixFrame = frame
                if depth < components.count {
                    ancestor.appendPathComponent(components[depth], isDirectory: true)
                    ancestorRelativePath = ancestorRelativePath.isEmpty
                        ? components[depth]
                        : ancestorRelativePath + "/" + components[depth]
                    var ancestorStatus = stat()
                    guard lstat(ancestor.path, &ancestorStatus) == 0,
                          ancestorStatus.st_mode & S_IFMT == S_IFDIR
                    else {
                        throw GitWorktreeInitializationError.malformedOutput(
                            "loaded-root prefix contains an unavailable or ambiguous directory"
                        )
                    }
                }
            }
            guard let prefixFrame else {
                throw GitWorktreeInitializationError.malformedOutput("loaded-root prefix rules are unavailable")
            }
            var frames = [prefixFrame]

            let source: GitPrefixControlCandidateSource
            if let suppliedSource {
                source = suppliedSource
            } else {
                guard let productionSource = GitFileManagerPrefixControlCandidateSource(root: prefixRoot) else {
                    throw GitWorktreeInitializationError.malformedOutput("prefix control enumeration failed")
                }
                source = productionSource
            }
            while let url = try source.nextCandidate() {
                try Task.checkCancellation()
                #if DEBUG
                    unpublishedCandidateCount &+= 1
                    if source.currentCandidateKind == .directory {
                        unpublishedDirectoryCount &+= 1
                    }
                #endif
                let validated = try validatedRelativePath(for: url)
                let relative = validated.path
                let relativeComponents = validated.components
                if indexedGitlinkPaths.contains(relative) {
                    throw GitWorktreeInitializationError.malformedOutput(
                        "prefix control enumeration reached an indexed Git topology boundary"
                    )
                }
                if source.currentCandidateKind == .symbolicLink {
                    guard controlKinds[url.lastPathComponent] == nil else {
                        throw GitWorktreeInitializationError.malformedOutput(
                            "prefix control authority is an ambiguous symbolic link"
                        )
                    }
                    // Directory enumeration never descends through symbolic links.
                    // A non-control link therefore cannot hide a reachable control;
                    // ordinary-crawl symlink inclusion remains catalog-policy-owned.
                    continue
                }
                if source.currentCandidateKind == .other {
                    throw GitWorktreeInitializationError.malformedOutput(
                        "prefix control enumeration encountered unsupported topology"
                    )
                }
                if relativeComponents.contains(".git") {
                    if relativeComponents.last == ".git" {
                        source.skipDescendants()
                        #if DEBUG
                            unpublishedPrunedDirectoryCount &+= 1
                        #endif
                    }
                    #if DEBUG
                        publishPrefixControlProgress()
                    #endif
                    continue
                }
                let parentDirectory = relativeComponents.dropLast().joined(separator: "/")
                while frames.count > 1,
                      frames.last?.repositoryRelativeDirectory != parentDirectory
                {
                    frames.removeLast()
                }
                let parentFrame = frames.last?.repositoryRelativeDirectory == parentDirectory
                    ? frames.last
                    : nil
                guard let parentFrame else {
                    throw GitWorktreeInitializationError.malformedOutput(
                        "prefix control enumeration has unknown reachability"
                    )
                }
                if source.currentCandidateKind == .directory {
                    var directoryStatus = stat()
                    guard lstat(url.path, &directoryStatus) == 0,
                          directoryStatus.st_mode & S_IFMT == S_IFDIR
                    else {
                        throw GitWorktreeInitializationError.malformedOutput(
                            "prefix control directory topology changed during enumeration"
                        )
                    }
                    var nestedBoundaryStatus = stat()
                    let nestedBoundary = url.appendingPathComponent(".git")
                    if lstat(nestedBoundary.path, &nestedBoundaryStatus) == 0 {
                        throw GitWorktreeInitializationError.malformedOutput(
                            "prefix control enumeration reached a nested Git topology boundary"
                        )
                    } else if errno != ENOENT {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    if parentFrame.rules.unanimouslyRejectTraversal(of: relative) {
                        try recordDirectoryObservation(
                            directoryURL: url,
                            repositoryRelativeDirectory: relative,
                            validatesControls: false,
                            requiresMissingNestedGitBoundary: true
                        )
                        source.skipDescendants()
                        #if DEBUG
                            try collectionDetailSink?.recordPrunedRoot(
                                fingerprint: GitWorkspacePolicyCanonicalizationDiagnostics
                                    .repositoryRelativePathFingerprint(relative)
                            )
                            unpublishedPrunedDirectoryCount &+= 1
                            publishPrefixControlProgress()
                        #endif
                        continue
                    }
                    let frame = try await readDirectoryControls(
                        directoryURL: url,
                        repositoryRelativeDirectory: relative,
                        inheritedRules: parentFrame.rules
                    )
                    frames.append(frame)
                    #if DEBUG
                        publishPrefixControlProgress()
                    #endif
                    continue
                }
                #if DEBUG
                    publishPrefixControlProgress()
                #endif
                guard controlKinds[url.lastPathComponent] != nil else { continue }
                guard let observed = parentFrame.observedControls[url.lastPathComponent] else {
                    throw GitPrefixControlEvidenceManifestError.corrupt(
                        "control appeared during prefix-control evaluation"
                    )
                }
                let current = try streamedAuthorityContent(at: url)
                guard observed.matches(current)
                else {
                    throw GitPrefixControlEvidenceManifestError.corrupt(
                        "control changed during prefix-control evaluation"
                    )
                }
            }
            try validateObservedAuthority()
            let lease = try await writer.finish()
            let reader = try lease.makeReader()
            while try await reader.next() != nil {
                try Task.checkCancellation()
            }
            guard await reader.validationState == .verified else {
                throw GitPrefixControlEvidenceManifestError.corrupt("prefix-control reader did not verify")
            }
            try await postArtifactFinalizationHook?()
            try validateObservedAuthority()
            #if DEBUG
                collectionDetailSink?.markCompleted()
                publishPrefixControlProgress(force: true)
                recorder?.increment(.controlRecordCount, by: controlRecordCount)
            #endif
            return lease.footer
        } catch {
            #if DEBUG
                publishPrefixControlProgress(force: true)
                recorder?.increment(.controlRecordCount, by: controlRecordCount)
                if error is CancellationError {
                    recorder?.recordReason(.cancellation)
                } else {
                    recorder?.recordReason(.failure)
                }
            #endif
            await writer.cancel()
            throw error
        }
    }

    private nonisolated static func streamedAuthorityContent(
        at url: URL,
        maximumBytes: Int = 4 * 1024 * 1024
    ) throws -> PrefixControlStableRead {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard before.st_mode & S_IFMT == S_IFREG else {
            throw GitWorktreeInitializationError.malformedOutput("control authority is not a regular file")
        }
        var digest = SHA256()
        var byteCount = 0
        var content = Data()
        var buffer = Data(count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let amount = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if amount == 0 { break }
            if amount < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let (nextCount, overflow) = byteCount.addingReportingOverflow(amount)
            guard !overflow, nextCount <= maximumBytes else {
                throw GitWorktreeInitializationError.outputLimitExceeded
            }
            byteCount = nextCount
            let chunk = buffer.prefix(amount)
            digest.update(data: chunk)
            content.append(chunk)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw GitPrefixControlEvidenceManifestError.corrupt("control identity changed during hashing") }
        var rebound = stat()
        guard lstat(url.path, &rebound) == 0,
              rebound.st_mode & S_IFMT == S_IFREG,
              rebound.st_dev == before.st_dev,
              rebound.st_ino == before.st_ino
        else { throw GitPrefixControlEvidenceManifestError.corrupt("control path rebound during hashing") }
        return PrefixControlStableRead(
            identity: GitWorkspaceAuthorityContentIdentity(
                exists: true,
                sha256: hex(Data(digest.finalize())),
                byteCount: byteCount
            ),
            data: content,
            device: before.st_dev,
            inode: before.st_ino
        )
    }

    private nonisolated static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
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

    /// Runs one exact-worktree Git authority command with stdout written
    /// directly to a secure raw spool. Unlike `runGitData`, this path never
    /// concatenates stdout chunks into `Data`; the pipe callback synchronously
    /// applies disk backpressure and refreshes an activity (not total-runtime)
    /// timeout after every successfully persisted chunk.
    private func runSpoolingAuthorityGit(
        _ args: [String],
        layout: GitRepositoryLayout,
        environment: [String: String],
        resourcePolicy: GitRawOutputSpoolResourcePolicy,
        priority: GitProcessAdmissionPriority,
        family: GitProcessCommandFamily,
        allowedExitCodes: Set<Int32> = [0]
    ) async throws -> GitRawOutputSpoolLease {
        let admissionDeadline = priority == .rootBootstrap || priority == .userInitiatedAuthority
            ? Self.gitAdmissionDeadline(after: resourcePolicy.activityTimeout)
            : nil
        let admissionLease = try await processAdmissionController.acquire(
            repositoryKey: layout.commonDir.standardizedFileURL.path,
            priority: priority,
            deadline: admissionDeadline
        )
        do {
            try Task.checkCancellation()
            let (spool, stderr, exitCode, terminationReason) = try await runAdmittedGitSpooling(
                args,
                at: layout.workTreeRoot,
                environment: environment,
                diagnosticRepositoryPath: layout.workTreeRoot.standardizedFileURL.path,
                processQueueWaitMicroseconds: admissionLease.queueWaitMicroseconds,
                resourcePolicy: resourcePolicy,
                admissionPriority: priority,
                commandFamily: family
            )
            await processAdmissionController.release(admissionLease)
            if terminationReason == .uncaughtSignal {
                throw GitTargetEvidenceCollectionError.gitSignal(
                    signal: exitCode,
                    stderr: stderr
                )
            }
            guard allowedExitCodes.contains(exitCode) else {
                throw GitTargetEvidenceCollectionError.gitFailure(
                    exitCode: exitCode,
                    stderr: stderr
                )
            }
            return spool
        } catch {
            await processAdmissionController.release(admissionLease)
            throw error
        }
    }

    private func runAdmittedGitSpooling(
        _ args: [String],
        at repoURL: URL,
        environment: [String: String],
        diagnosticRepositoryPath: String,
        processQueueWaitMicroseconds: Int,
        resourcePolicy: GitRawOutputSpoolResourcePolicy,
        admissionPriority: GitProcessAdmissionPriority,
        commandFamily: GitProcessCommandFamily
    ) async throws -> (GitRawOutputSpoolLease, Data, Int32, Process.TerminationReason) {
        #if DEBUG
            let benchmarkMetricTag = WorktreeStartupInstrumentation.currentBenchmarkMetricTag
        #endif
        let process = Process()
        let timeoutController = GitProcessActivityTimeoutController()
        let lifecycleController = GitProcessLifecycleController()
        let commandRecorder = MCPToolWorkCountDiagnostics.gitCommandRecorder()
        let spool = try GitRawOutputSpool(resourcePolicy: resourcePolicy)
        process.executableURL = gitExecutableURL
        process.arguments = args
        process.currentDirectoryURL = repoURL
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let activityHandler: @Sendable () -> Void = {
            let identifier = process.processIdentifier
            guard identifier > 0, process.isRunning else { return }
            timeoutController.schedule(
                process: process,
                processIdentifier: identifier,
                timeout: resourcePolicy.activityTimeout,
                terminationGrace: self.processTerminationGrace
            )
        }
        let outDrain = try GitProcessPipeSpoolDrain.make(
            readingFrom: outPipe.fileHandleForReading,
            spool: spool,
            activityHandler: activityHandler
        )
        let (errStream, errDrain) = try GitProcessPipeDrain.makeStream(
            readingFrom: errPipe.fileHandleForReading,
            byteLimit: 64 * 1024
        )
        let errCollector = Task(priority: .userInitiated) { () -> Data in
            var buffer = Data()
            for await chunk in errStream where !chunk.isEmpty {
                buffer.append(chunk)
            }
            return buffer
        }

        let processMetrics = GitProcessMetricsBox()
        let commandStartedAt = DispatchTime.now().uptimeNanoseconds
        let result = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<
                    (GitRawOutputSpoolLease, Data, Int32, Process.TerminationReason),
                    any Error
                >) in
                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    if outDrain.consumeAvailableData() {
                        handle.readabilityHandler = nil
                    }
                    if outDrain.terminalError != nil {
                        lifecycleController.requestCancellation(
                            process: process,
                            terminationGrace: self.processTerminationGrace
                        )
                    }
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    if errDrain.consumeAvailableData() {
                        handle.readabilityHandler = nil
                    } else {
                        activityHandler()
                    }
                    if errDrain.didExceedByteLimit {
                        lifecycleController.requestCancellation(
                            process: process,
                            terminationGrace: self.processTerminationGrace
                        )
                    }
                }

                process.terminationHandler = { terminatedProcess in
                    lifecycleController.didTerminate()
                    timeoutController.cancel()
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    outDrain.finishReading()
                    errDrain.finishReading()

                    Task {
                        let stderrData = await errCollector.value
                        let stdoutResult: Result<GitRawOutputSpoolLease, any Error>
                        do {
                            stdoutResult = try .success(spool.finish())
                        } catch {
                            stdoutResult = .failure(error)
                        }
                        let stdoutByteCount: UInt64 = switch stdoutResult {
                        case let .success(lease): lease.byteCount
                        case .failure: 0
                        }
                        let outputByteCount = Int(
                            clamping: stdoutByteCount + UInt64(stderrData.count)
                        )
                        commandRecorder(
                            diagnosticRepositoryPath,
                            args,
                            processQueueWaitMicroseconds,
                            processMetrics.spawnMicroseconds,
                            outputByteCount
                        )
                        let commandFinishedAt = DispatchTime.now().uptimeNanoseconds
                        let durationMicroseconds = Int(
                            clamping: commandFinishedAt >= commandStartedAt
                                ? (commandFinishedAt - commandStartedAt) / 1000
                                : 0
                        )
                        let wasCancelled = lifecycleController.cancellationErrorIfRequested() != nil
                        WorktreeStartupInstrumentation.recordGitCommand(
                            family: commandFamily,
                            priority: admissionPriority,
                            queueWaitMicroseconds: processQueueWaitMicroseconds,
                            durationMicroseconds: durationMicroseconds,
                            outputByteCount: outputByteCount,
                            cancelled: wasCancelled
                        )
                        #if DEBUG
                            WorktreeStartupInstrumentation.recordBenchmarkGitCommand(
                                tag: benchmarkMetricTag,
                                family: commandFamily,
                                priority: admissionPriority,
                                queueWaitMicroseconds: processQueueWaitMicroseconds,
                                durationMicroseconds: durationMicroseconds,
                                outputByteCount: outputByteCount,
                                cancelled: wasCancelled
                            )
                        #endif

                        if let error = outDrain.terminalError {
                            continuation.resume(throwing: error)
                        } else if case let .failure(error) = stdoutResult {
                            continuation.resume(throwing: error)
                        } else if errDrain.didExceedByteLimit {
                            continuation.resume(throwing: GitProcessCaptureError.stderrByteLimitExceeded)
                        } else if timeoutController.didTimeOut {
                            continuation.resume(throwing: GitProcessCaptureError.timedOut)
                        } else if case let .success(stdoutLease) = stdoutResult {
                            continuation.resume(returning: (
                                stdoutLease,
                                stderrData,
                                terminatedProcess.terminationStatus,
                                terminatedProcess.terminationReason
                            ))
                        } else {
                            preconditionFailure("raw spool result was not exhaustive")
                        }
                    }
                }

                do {
                    try lifecycleController.checkCancellationBeforeSpawn()
                    let spawnStart = DispatchTime.now().uptimeNanoseconds
                    try process.run()
                    let identifier = process.processIdentifier
                    let spawnState = lifecycleController.didSpawn(
                        process: process,
                        processIdentifier: identifier,
                        terminationGrace: processTerminationGrace
                    )
                    if spawnState == .running {
                        timeoutController.schedule(
                            process: process,
                            processIdentifier: identifier,
                            timeout: resourcePolicy.activityTimeout,
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
                } catch {
                    timeoutController.cancel()
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    outDrain.cancel()
                    errDrain.cancel()
                    spool.cancel()
                    commandRecorder(
                        diagnosticRepositoryPath,
                        args,
                        processQueueWaitMicroseconds,
                        processMetrics.spawnMicroseconds,
                        0
                    )
                    let commandFinishedAt = DispatchTime.now().uptimeNanoseconds
                    let durationMicroseconds = Int(
                        clamping: commandFinishedAt >= commandStartedAt
                            ? (commandFinishedAt - commandStartedAt) / 1000
                            : 0
                    )
                    let wasCancelled = lifecycleController.cancellationErrorIfRequested() != nil
                    WorktreeStartupInstrumentation.recordGitCommand(
                        family: commandFamily,
                        priority: admissionPriority,
                        queueWaitMicroseconds: processQueueWaitMicroseconds,
                        durationMicroseconds: durationMicroseconds,
                        outputByteCount: 0,
                        cancelled: wasCancelled
                    )
                    #if DEBUG
                        WorktreeStartupInstrumentation.recordBenchmarkGitCommand(
                            tag: benchmarkMetricTag,
                            family: commandFamily,
                            priority: admissionPriority,
                            queueWaitMicroseconds: processQueueWaitMicroseconds,
                            durationMicroseconds: durationMicroseconds,
                            outputByteCount: 0,
                            cancelled: wasCancelled
                        )
                    #endif
                    continuation.resume(
                        throwing: lifecycleController.cancellationErrorIfRequested() ?? error
                    )
                }
            }
        }, onCancel: {
            timeoutController.cancel()
            lifecycleController.requestCancellation(
                process: process,
                terminationGrace: processTerminationGrace
            )
        })
        try Task.checkCancellation()
        return result
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
        let timeoutController = GitProcessActivityTimeoutController()
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
