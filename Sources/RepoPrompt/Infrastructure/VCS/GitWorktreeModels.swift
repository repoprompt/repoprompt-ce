import Foundation
import RepoPromptInstrumentation
import RepoPromptVCS

// MARK: - App-integrated Worktree Mutation Models

public struct GitWorktreeCreateRequest: Sendable, Equatable {
    public let path: URL
    public let branch: String?
    public let baseRef: String?
    public let detach: Bool
    public let force: Bool
    public let lockReason: String?
    public let allowExternalPath: Bool
    public let appManagedContainer: URL?
    public let mainWorktreeRoot: URL?
    public let knownWorktreeRoots: [URL]
    public let copyWorktreeIncludeFiles: Bool
    /// Also copy untracked, non-ignored files selected by `.worktreeinclude`. Off by default;
    /// ignored files remain the only files copied unless a caller explicitly opts in.
    public let copyWorktreeIncludeUntrackedFiles: Bool
    /// Materialize tracked files as APFS clones of a clean, same-tree source checkout when
    /// every safety check passes; otherwise Git performs an ordinary checkout.
    public let cloneTrackedCheckout: Bool

    public init(
        path: URL,
        branch: String? = nil,
        baseRef: String? = nil,
        detach: Bool = false,
        force: Bool = false,
        lockReason: String? = nil,
        allowExternalPath: Bool = false,
        appManagedContainer: URL? = nil,
        mainWorktreeRoot: URL? = nil,
        knownWorktreeRoots: [URL] = [],
        copyWorktreeIncludeFiles: Bool = false,
        copyWorktreeIncludeUntrackedFiles: Bool = false,
        cloneTrackedCheckout: Bool = false
    ) {
        self.path = path
        self.branch = branch
        self.baseRef = baseRef
        self.detach = detach
        self.force = force
        self.lockReason = lockReason
        self.allowExternalPath = allowExternalPath
        self.appManagedContainer = appManagedContainer
        self.mainWorktreeRoot = mainWorktreeRoot
        self.knownWorktreeRoots = knownWorktreeRoots
        self.copyWorktreeIncludeFiles = copyWorktreeIncludeFiles
        self.copyWorktreeIncludeUntrackedFiles = copyWorktreeIncludeUntrackedFiles
        self.cloneTrackedCheckout = cloneTrackedCheckout
    }
}

/// How the tracked files of a newly created worktree were materialized.
public struct GitWorktreeCheckoutReport: Sendable, Equatable {
    public enum Strategy: String, Sendable, Equatable {
        /// `git worktree add` performed its normal checkout.
        case ordinary
        /// Tracked files are APFS clones of the source checkout, verified by an index refresh.
        case cloned
        /// Cloning failed after `git worktree add --no-checkout`; `git reset --hard` in the new
        /// worktree produced an ordinary, verified-clean checkout instead.
        case checkoutFallback
    }

    public let strategy: Strategy
    /// Stable, path-free reason the clone fast path was not attempted (`ordinary` only).
    public let ineligibilityReason: String?
    /// Diagnostic reason the attempted clone was abandoned (`checkoutFallback` only).
    public let fallbackReason: String?
    public let clonedFileCount: Int
    public let symbolicLinkCount: Int
    public let clonedByteCount: Int64
    /// Diagnostic phase durations: read-only eligibility probing, descriptor-based cloning,
    /// and Git index build plus verification (or the checkout fallback).
    public let eligibilityMilliseconds: Double?
    public let materializationMilliseconds: Double?
    public let verificationMilliseconds: Double?

    public init(
        strategy: Strategy,
        ineligibilityReason: String? = nil,
        fallbackReason: String? = nil,
        clonedFileCount: Int = 0,
        symbolicLinkCount: Int = 0,
        clonedByteCount: Int64 = 0,
        eligibilityMilliseconds: Double? = nil,
        materializationMilliseconds: Double? = nil,
        verificationMilliseconds: Double? = nil
    ) {
        self.strategy = strategy
        self.ineligibilityReason = ineligibilityReason
        self.fallbackReason = fallbackReason
        self.clonedFileCount = clonedFileCount
        self.symbolicLinkCount = symbolicLinkCount
        self.clonedByteCount = clonedByteCount
        self.eligibilityMilliseconds = eligibilityMilliseconds
        self.materializationMilliseconds = materializationMilliseconds
        self.verificationMilliseconds = verificationMilliseconds
    }

    func withEligibilityMilliseconds(_ milliseconds: Double) -> GitWorktreeCheckoutReport {
        GitWorktreeCheckoutReport(
            strategy: strategy,
            ineligibilityReason: ineligibilityReason,
            fallbackReason: fallbackReason,
            clonedFileCount: clonedFileCount,
            symbolicLinkCount: symbolicLinkCount,
            clonedByteCount: clonedByteCount,
            eligibilityMilliseconds: milliseconds,
            materializationMilliseconds: materializationMilliseconds,
            verificationMilliseconds: verificationMilliseconds
        )
    }
}

public struct GitWorktreeCreateResult: Sendable, Equatable {
    public let descriptor: GitWorktreeDescriptor
    public let includeCopyResult: GitWorktreeIncludeCopyResult?
    public let checkoutReport: GitWorktreeCheckoutReport?
    let initializationReceipt: GitWorktreeCreationReceipt?
    let initializationFallbackReason: WorkspaceRootSeedFallbackReason?

    public init(
        descriptor: GitWorktreeDescriptor,
        includeCopyResult: GitWorktreeIncludeCopyResult? = nil,
        checkoutReport: GitWorktreeCheckoutReport? = nil
    ) {
        self.descriptor = descriptor
        self.includeCopyResult = includeCopyResult
        self.checkoutReport = checkoutReport
        initializationReceipt = nil
        initializationFallbackReason = nil
    }

    init(
        descriptor: GitWorktreeDescriptor,
        includeCopyResult: GitWorktreeIncludeCopyResult?,
        checkoutReport: GitWorktreeCheckoutReport? = nil,
        initializationReceipt: GitWorktreeCreationReceipt?,
        initializationFallbackReason: WorkspaceRootSeedFallbackReason? = nil
    ) {
        self.descriptor = descriptor
        self.includeCopyResult = includeCopyResult
        self.checkoutReport = checkoutReport
        self.initializationReceipt = initializationReceipt
        self.initializationFallbackReason = initializationFallbackReason
    }
}

public struct GitWorktreeIncludeCopyResult: Sendable, Equatable {
    public let copiedCount: Int
    public let matchedCount: Int
    public let copiedRelativePaths: [String]
    public let skippedSummaries: [String]
    public let errorSummaries: [String]
    /// Copied files that were APFS clones (the rest used a byte-copy fallback).
    public let clonedCount: Int
    /// Copied files that were untracked but not ignored (explicit opt-in only).
    public let copiedUntrackedCount: Int

    public init(
        copiedCount: Int,
        matchedCount: Int,
        copiedRelativePaths: [String] = [],
        skippedSummaries: [String] = [],
        errorSummaries: [String] = [],
        clonedCount: Int = 0,
        copiedUntrackedCount: Int = 0
    ) {
        self.copiedCount = copiedCount
        self.matchedCount = matchedCount
        self.copiedRelativePaths = copiedRelativePaths
        self.skippedSummaries = skippedSummaries
        self.errorSummaries = errorSummaries
        self.clonedCount = clonedCount
        self.copiedUntrackedCount = copiedUntrackedCount
    }

    public var warningText: String? {
        let details = (skippedSummaries + errorSummaries).filter { !$0.isEmpty }
        guard !details.isEmpty else { return nil }
        let detailText = details.prefix(5).joined(separator: "; ")
        let remaining = details.count - min(details.count, 5)
        let suffix = remaining > 0 ? "; +\(remaining) more" : ""
        return ".worktreeinclude copied \(copiedCount) of \(matchedCount) eligible file(s); some files were skipped or failed: \(detailText)\(suffix)"
    }
}

// MARK: - Git Worktree Mutation Coordinator

actor GitWorktreeMutationCoordinator {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var busyKeys: Set<String> = []
    private var waitersByKey: [String: [Waiter]] = [:]
    #if DEBUG
        private var queuedWaiterObservationContinuationsByKey: [
            String: [CheckedContinuation<Void, Never>]
        ] = [:]
    #endif

    func withLock<T: Sendable>(
        key: String,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        #if DEBUG
            let benchmarkMetricTag = WorktreeStartupInstrumentation.currentBenchmarkMetricTag
            let waitStarted = DispatchTime.now().uptimeNanoseconds
        #endif
        try await acquire(key: key)
        #if DEBUG
            let acquired = DispatchTime.now().uptimeNanoseconds
        #endif
        do {
            try Task.checkCancellation()
            let value = try await operation()
            #if DEBUG
                let finished = DispatchTime.now().uptimeNanoseconds
                WorktreeStartupInstrumentation.recordBenchmarkMutationLock(
                    tag: benchmarkMetricTag,
                    queueWaitMicroseconds: (acquired - waitStarted) / 1000,
                    heldMicroseconds: (finished - acquired) / 1000
                )
            #endif
            release(key: key)
            return value
        } catch {
            #if DEBUG
                let finished = DispatchTime.now().uptimeNanoseconds
                WorktreeStartupInstrumentation.recordBenchmarkMutationLock(
                    tag: benchmarkMetricTag,
                    queueWaitMicroseconds: (acquired - waitStarted) / 1000,
                    heldMicroseconds: (finished - acquired) / 1000
                )
            #endif
            release(key: key)
            throw error
        }
    }

    private func acquire(key: String) async throws {
        if !busyKeys.contains(key) {
            busyKeys.insert(key)
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waitersByKey[key, default: []].append(Waiter(id: waiterID, continuation: continuation))
                #if DEBUG
                    let observationContinuations = queuedWaiterObservationContinuationsByKey
                        .removeValue(forKey: key) ?? []
                    for observationContinuation in observationContinuations {
                        observationContinuation.resume()
                    }
                #endif
            }
        } onCancel: {
            Task { await self.cancelWaiter(key: key, id: waiterID) }
        }
    }

    private func release(key: String) {
        guard var waiters = waitersByKey[key], !waiters.isEmpty else {
            busyKeys.remove(key)
            waitersByKey.removeValue(forKey: key)
            return
        }

        let next = waiters.removeFirst()
        waitersByKey[key] = waiters.isEmpty ? nil : waiters
        next.continuation.resume()
    }

    private func cancelWaiter(key: String, id: UUID) {
        guard var waiters = waitersByKey[key],
              let index = waiters.firstIndex(where: { $0.id == id })
        else { return }

        let waiter = waiters.remove(at: index)
        waitersByKey[key] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume(throwing: CancellationError())
    }

    #if DEBUG
        func waitForQueuedWaiterForTesting(key: String) async {
            if waitersByKey[key]?.isEmpty == false {
                return
            }
            await withCheckedContinuation { continuation in
                queuedWaiterObservationContinuationsByKey[key, default: []].append(continuation)
            }
        }
    #endif
}
