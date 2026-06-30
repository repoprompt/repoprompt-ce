import Darwin
import Foundation

struct GitPrefixControlEvidenceCacheLimits: Equatable {
    static let production = GitPrefixControlEvidenceCacheLimits(
        maximumEntryCount: 32,
        maximumEntriesPerRepository: 4,
        maximumResidentBytes: 64 * 1024,
        maximumArtifactBytes: 0,
        maximumPendingAdmissionCount: 8,
        maximumPendingResidentBytes: 16 * 1024,
        maximumPendingArtifactBytes: 0
    )

    let maximumEntryCount: Int
    let maximumEntriesPerRepository: Int
    let maximumResidentBytes: Int
    let maximumArtifactBytes: UInt64
    let maximumPendingAdmissionCount: Int
    let maximumPendingResidentBytes: Int
    let maximumPendingArtifactBytes: UInt64
}

enum GitPrefixControlEvidenceCacheError: Error, Equatable {
    case invalidatedDuringCollection
    case rootIdentityChanged
    case corruptFooter
    case resourceAdmission
}

struct GitPrefixControlCollectionDetail: Equatable {
    let collectionCompleted: Bool
    let ignoreControlCount: Int
    let attributeControlCount: Int
    let prunedRootCount: Int
    /// Domain-separated digest of every pruned repository-relative root in
    /// canonical traversal order. This keeps cache carriage constant-size;
    /// count overflow or an unavailable digest makes the detail invalid rather
    /// than silently truncating diagnostic evidence.
    let prunedRootSummarySHA256: String
}

struct GitPrefixControlCollectedEvidence: Equatable {
    let footer: GitPrefixControlEvidenceManifestFooter
    let collectionDetail: GitPrefixControlCollectionDetail?
}

private final class GitWorkspaceAuthoritySynchronousState: @unchecked Sendable {
    private struct RepositoryState {
        let invalidationGeneration: UInt64
        let mutationDepth: Int
        let monitorCoverageUnavailable: Bool
        let publicationGenerations: [GitWorkspaceAuthorityScopeKey: UInt64]
    }

    private let lock = NSLock()
    private var repositories: [GitWorkspaceAuthorityRepositoryKey: RepositoryState] = [:]

    func update(
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        invalidationGeneration: UInt64,
        mutationDepth: Int,
        monitorCoverageUnavailable: Bool,
        publicationGenerations: [GitWorkspaceAuthorityScopeKey: UInt64]
    ) {
        lock.lock()
        repositories[repositoryKey] = RepositoryState(
            invalidationGeneration: invalidationGeneration,
            mutationDepth: mutationDepth,
            monitorCoverageUnavailable: monitorCoverageUnavailable,
            publicationGenerations: publicationGenerations
        )
        lock.unlock()
    }

    func isCurrent(_ fence: GitWorkspacePendingInitializationAuthorityFence) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return matches(fence)
    }

    func withCurrentFences<T>(
        _ fences: [GitWorkspacePendingInitializationAuthorityFence],
        _ body: () -> T?
    ) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard fences.allSatisfy(matches) else { return nil }
        return body()
    }

    private func matches(_ fence: GitWorkspacePendingInitializationAuthorityFence) -> Bool {
        guard let state = repositories[fence.repositoryKey] else { return false }
        return state.invalidationGeneration == fence.lease.invalidationGeneration
            && state.mutationDepth == 0
            && !state.monitorCoverageUnavailable
            && state.publicationGenerations[fence.lease.scopeKey] == fence.lease.authorityGeneration
    }
}

/// Owns currentness and metadata observation for worktree bootstrap. Collection
/// is always bracketed by a scope-bound capture token and conditional install;
/// reusable snapshot storage/eviction is bounded and remains observation-only.
actor GitWorkspaceStateAuthority {
    static let shared = GitWorkspaceStateAuthority()

    #if DEBUG
        struct Snapshot: Equatable {
            let recordCount: Int
            let publishedScopeCount: Int
            let activeMutationCount: Int
            let metadataEventCount: Int
            let authorityGenerations: [GitWorkspaceAuthorityRepositoryKey: UInt64]
            let reusableSnapshotCount: Int
            let reusableSnapshotAliasCount: Int
            let reusableSnapshotEstimatedBytes: Int
            let reusableSnapshotArtifactBytes: UInt64
            let pendingReusableSnapshotAdmissionCount: Int
            let pendingReusableSnapshotArtifactBytes: UInt64
            let reusableSnapshotArtifactBudgetRejectionCount: UInt64
            let invalidationSubscriberCount: Int
            let prefixControlCacheEntryCount: Int
            let prefixControlCacheResidentBytes: Int
            let prefixControlCacheArtifactBytes: UInt64
            let pendingPrefixControlAdmissionCount: Int
            let pendingPrefixControlResidentBytes: Int
            let pendingPrefixControlArtifactBytes: UInt64
            let prefixControlCacheHitCount: UInt64
            let prefixControlCacheMissCount: UInt64
            let prefixControlCacheCoalescedWaiterCount: UInt64
            let prefixControlCacheAdmissionCount: UInt64
            let prefixControlCacheEvictionCount: UInt64
            let prefixControlCacheInvalidationCount: UInt64
            let prefixControlCacheBypassCount: UInt64
            let prefixControlPhysicalScanCount: UInt64
        }
    #endif

    private struct Record {
        var invalidationGeneration: UInt64 = 0
        var mutationDepth: Int = 0
        var metadataEventCount: Int = 0
        var monitorCoverageUnavailable = false
        var snapshotsByScope: [GitWorkspaceAuthorityScopeKey: GitWorkspaceAuthoritySnapshot] = [:]
        var publicationGenerationByScope: [GitWorkspaceAuthorityScopeKey: UInt64] = [:]
        var acceptedWatermarkByScope: [GitWorkspaceAuthorityScopeKey: UInt64] = [:]
    }

    private struct ReusableSnapshotCacheEntry {
        let snapshot: WorkspaceRootReusableSnapshot
        var lastAccessOrdinal: UInt64
    }

    private struct ReusableSnapshotAlias {
        let admissionID: UUID
        let lease: GitWorkspaceAuthorityLease
        let snapshotIdentity: WorkspaceRootReusableSnapshotIdentity
        let observationToken: GitWorkspaceMetadataMonitor.RetainToken
    }

    struct PreparedReusableSnapshotAdmission: Hashable {
        fileprivate let id: UUID
    }

    struct ReusableSnapshotAdmissionReceipt: Hashable {
        fileprivate let id: UUID
        let snapshotIdentity: WorkspaceRootReusableSnapshotIdentity
    }

    private struct PendingReusableSnapshotAdmission {
        let snapshot: WorkspaceRootReusableSnapshot
        let lease: GitWorkspaceAuthorityLease
        let observationToken: GitWorkspaceMetadataMonitor.RetainToken
        let reservedArtifactBytes: UInt64
    }

    private struct PrefixControlRootIdentity: Hashable {
        let canonicalPath: String
        let device: UInt64
        let inode: UInt64
    }

    private struct PrefixControlCacheKey: Hashable {
        let repositoryKey: GitWorkspaceAuthorityRepositoryKey
        let rootIdentity: PrefixControlRootIdentity
        let prefix: GitRepositoryRelativeRootPrefix
        let policyAuthorityIdentity: String
        let collectorFormatVersion: UInt32
    }

    private struct PrefixControlCurrentnessKey: Hashable {
        let invalidationGeneration: UInt64
        let publicationGeneration: UInt64
        let acceptedWatermark: UInt64
        let mutationDepth: Int
        let monitorCoverageUnavailable: Bool
    }

    private struct PrefixControlCacheEntry {
        let id: UUID
        let evidence: GitPrefixControlCollectedEvidence
        let observationToken: GitWorkspaceMetadataMonitor.RetainToken
        var currentness: PrefixControlCurrentnessKey
        var lastAccessOrdinal: UInt64
        let residentBytes: Int
        let artifactBytes: UInt64
    }

    private struct PendingPrefixControlAdmission {
        let id: UUID
        let task: Task<GitPrefixControlCollectedEvidence, Error>
        let observationToken: GitWorkspaceMetadataMonitor.RetainToken
        let currentness: PrefixControlCurrentnessKey
        let repositoryRoot: URL
        var waiters: [UUID: CheckedContinuation<GitPrefixControlCollectedEvidence, Error>]
        var isCancelled: Bool
        let reservedResidentBytes: Int
        let reservedArtifactBytes: UInt64
    }

    private struct PendingUncachedPrefixControlFlight {
        let id: UUID
        let task: Task<GitPrefixControlCollectedEvidence, Error>
        var waiters: [UUID: CheckedContinuation<GitPrefixControlCollectedEvidence, Error>]
        var isCancelled: Bool
        let reservedResidentBytes: Int
        let reservedArtifactBytes: UInt64
    }

    private let metadataMonitor: GitWorkspaceMetadataMonitor
    private nonisolated let synchronousState = GitWorkspaceAuthoritySynchronousState()
    private let reusableSnapshotCacheLimits: WorkspaceRootReusableSnapshotCacheLimits
    private let prefixControlCacheLimits: GitPrefixControlEvidenceCacheLimits
    private var records: [GitWorkspaceAuthorityRepositoryKey: Record] = [:]
    private var activeMutations: [UUID: GitWorkspaceMutationToken] = [:]
    private var reusableSnapshotsByIdentity: [WorkspaceRootReusableSnapshotIdentity: ReusableSnapshotCacheEntry] = [:]
    private var reusableSnapshotAliasesByScope: [GitWorkspaceAuthorityScopeKey: ReusableSnapshotAlias] = [:]
    private var pendingReusableSnapshotAdmissions: [UUID: PendingReusableSnapshotAdmission] = [:]
    private var reusableSnapshotAccessOrdinal: UInt64 = 0
    private var reusableSnapshotEstimatedBytes = 0
    private var reusableSnapshotArtifactBytes: UInt64 = 0
    private var pendingReusableSnapshotArtifactBytes: UInt64 = 0
    private var reusableSnapshotArtifactBudgetRejectionCount: UInt64 = 0
    private var invalidationContinuations: [UUID: AsyncStream<GitWorkspaceAuthorityInvalidationEvent>.Continuation] = [:]
    private var prefixControlCacheEntries: [PrefixControlCacheKey: PrefixControlCacheEntry] = [:]
    private var pendingPrefixControlAdmissions: [PrefixControlCacheKey: PendingPrefixControlAdmission] = [:]
    private var pendingUncachedPrefixControlFlights: [PrefixControlCacheKey: PendingUncachedPrefixControlFlight] = [:]
    private var prefixControlCacheAccessOrdinal: UInt64 = 0
    private var prefixControlCacheResidentBytes = 0
    private var prefixControlCacheArtifactBytes: UInt64 = 0
    private var pendingPrefixControlResidentBytes = 0
    private var pendingPrefixControlArtifactBytes: UInt64 = 0
    private var pendingUncachedPrefixControlResidentBytes = 0
    private var pendingUncachedPrefixControlArtifactBytes: UInt64 = 0
    private var prefixControlCacheHitCount: UInt64 = 0
    private var prefixControlCacheMissCount: UInt64 = 0
    private var prefixControlCacheCoalescedWaiterCount: UInt64 = 0
    private var prefixControlCacheAdmissionCount: UInt64 = 0
    private var prefixControlCacheEvictionCount: UInt64 = 0
    private var prefixControlCacheInvalidationCount: UInt64 = 0
    private var prefixControlCacheBypassCount: UInt64 = 0
    private var prefixControlPhysicalScanCount: UInt64 = 0

    init(
        metadataMonitor: GitWorkspaceMetadataMonitor = GitWorkspaceMetadataMonitor(),
        reusableSnapshotCacheLimits: WorkspaceRootReusableSnapshotCacheLimits = .production,
        prefixControlCacheLimits: GitPrefixControlEvidenceCacheLimits = .production
    ) {
        precondition(reusableSnapshotCacheLimits.maximumSnapshotCount > 0)
        precondition(reusableSnapshotCacheLimits.maximumSnapshotsPerRepository > 0)
        precondition(reusableSnapshotCacheLimits.maximumEstimatedBytes > 0)
        precondition(reusableSnapshotCacheLimits.maximumArtifactBytes > 0)
        precondition(prefixControlCacheLimits.maximumEntryCount > 0)
        precondition(prefixControlCacheLimits.maximumEntriesPerRepository > 0)
        precondition(prefixControlCacheLimits.maximumResidentBytes > 0)
        precondition(prefixControlCacheLimits.maximumPendingAdmissionCount > 0)
        precondition(prefixControlCacheLimits.maximumPendingResidentBytes > 0)
        self.metadataMonitor = metadataMonitor
        self.reusableSnapshotCacheLimits = reusableSnapshotCacheLimits
        self.prefixControlCacheLimits = prefixControlCacheLimits
    }

    func collectionMutationFenceReason(
        for repositoryKey: GitWorkspaceAuthorityRepositoryKey
    ) -> GitWorkspaceAuthorityUnavailableReason? {
        let record = records[repositoryKey]
        return hasActiveMutation(for: repositoryKey) || (record?.mutationDepth ?? 0) > 0
            ? .mutationInProgress
            : nil
    }

    func prefixControlEvidence(
        in layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        cacheMode: GitPrefixControlEvidenceCacheMode,
        policyAuthorityIdentity: String = "",
        collector: @escaping @Sendable () async throws -> GitPrefixControlEvidenceManifestFooter
    ) async throws -> GitPrefixControlEvidenceManifestFooter {
        try await prefixControlCollectedEvidence(
            in: layout,
            prefix: prefix,
            cacheMode: cacheMode,
            policyAuthorityIdentity: policyAuthorityIdentity,
            requiresCollectionDetail: false
        ) {
            try await GitPrefixControlCollectedEvidence(
                footer: collector(),
                collectionDetail: nil
            )
        }.footer
    }

    func prefixControlEvidenceWithDetail(
        in layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        cacheMode: GitPrefixControlEvidenceCacheMode,
        policyAuthorityIdentity: String = "",
        collector: @escaping @Sendable () async throws -> GitPrefixControlCollectedEvidence
    ) async throws -> GitPrefixControlCollectedEvidence {
        try await prefixControlCollectedEvidence(
            in: layout,
            prefix: prefix,
            cacheMode: cacheMode,
            policyAuthorityIdentity: policyAuthorityIdentity,
            requiresCollectionDetail: true,
            collector: collector
        )
    }

    private func prefixControlCollectedEvidence(
        in layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        cacheMode: GitPrefixControlEvidenceCacheMode,
        policyAuthorityIdentity: String,
        requiresCollectionDetail: Bool,
        collector: @escaping @Sendable () async throws -> GitPrefixControlCollectedEvidence
    ) async throws -> GitPrefixControlCollectedEvidence {
        #if DEBUG
            let recorder = WorktreeStartupPreparationInstrumentation.currentRecorder
        #endif
        let validatedCollector: @Sendable () async throws -> GitPrefixControlCollectedEvidence = {
            let evidence = try await collector()
            guard !requiresCollectionDetail
                || (evidence.collectionDetail != nil && Self.prefixControlEvidenceIsValid(evidence))
            else {
                throw GitPrefixControlEvidenceCacheError.corruptFooter
            }
            return evidence
        }
        if cacheMode == .bypassReadAndAdmission {
            prefixControlCacheBypassCount &+= 1
            prefixControlPhysicalScanCount &+= 1
            #if DEBUG
                recorder?.increment(.prefixCacheBypasses)
                recorder?.recordReason(.bypassed)
            #endif
            return try await validatedCollector()
        }

        #if DEBUG
            let lookupSpan = recorder?.begin(.prefixControlCacheLookup)
        #endif

        let repositoryKey = GitWorkspaceAuthorityRepositoryKey(layout: layout)
        guard policyAuthorityIdentity.utf8.count <= 128,
              !policyAuthorityIdentity.contains("\0")
        else { throw GitPrefixControlEvidenceCacheError.resourceAdmission }
        let rootIdentity = try Self.prefixControlRootIdentity(for: layout.workTreeRoot)
        let key = PrefixControlCacheKey(
            repositoryKey: repositoryKey,
            rootIdentity: rootIdentity,
            prefix: prefix,
            policyAuthorityIdentity: policyAuthorityIdentity,
            collectorFormatVersion: GitPrefixControlEvidenceManifestHeader.currentSchemaVersion
        )
        let scopeKey = GitWorkspaceAuthorityScopeKey(
            repositoryKey: repositoryKey,
            repositoryRelativeRootPrefix: prefix
        )

        let replacedRootEntryKeys = prefixControlCacheEntries.keys.filter {
            $0.repositoryKey == repositoryKey
                && $0.prefix == prefix
                && $0.collectorFormatVersion == key.collectorFormatVersion
                && $0.rootIdentity != rootIdentity
        }
        for replacedKey in replacedRootEntryKeys {
            #if DEBUG
                recorder?.increment(.prefixCacheInvalidations)
                recorder?.recordReason(.rootIdentityChanged)
            #endif
            await removePrefixControlCacheEntry(replacedKey, invalidated: true)
        }
        let replacedRootPendingKeys = pendingPrefixControlAdmissions.keys.filter {
            $0.repositoryKey == repositoryKey
                && $0.prefix == prefix
                && $0.collectorFormatVersion == key.collectorFormatVersion
                && $0.rootIdentity != rootIdentity
        }
        for replacedKey in replacedRootPendingKeys {
            #if DEBUG
                recorder?.recordReason(.rootIdentityChanged)
            #endif
            await cancelPendingPrefixControlAdmission(replacedKey, invalidated: true)
        }

        if var entry = prefixControlCacheEntries[key] {
            let expectedEntryID = entry.id
            let expectedCurrentness = entry.currentness
            let coverageCurrent = await metadataMonitor.flushCoverageAndCheckCurrent(
                entry.observationToken,
                repositoryKey: repositoryKey,
                repositoryRoot: layout.workTreeRoot,
                prefix: prefix,
                expectedAcceptedWatermark: expectedCurrentness.acceptedWatermark
            )
            let currentRootIdentity = try? Self.prefixControlRootIdentity(for: layout.workTreeRoot)
            if coverageCurrent,
               currentRootIdentity == rootIdentity,
               prefixControlCacheEntries[key]?.id == expectedEntryID,
               prefixControlCurrentness(for: scopeKey) == expectedCurrentness,
               Self.prefixControlEvidenceIsValid(entry.evidence),
               !requiresCollectionDetail || entry.evidence.collectionDetail != nil
            {
                prefixControlCacheAccessOrdinal &+= 1
                entry.lastAccessOrdinal = prefixControlCacheAccessOrdinal
                prefixControlCacheEntries[key] = entry
                prefixControlCacheHitCount &+= 1
                #if DEBUG
                    recorder?.increment(.prefixCacheHits)
                    lookupSpan?.end()
                #endif
                return entry.evidence
            }
            #if DEBUG
                recorder?.increment(.prefixCacheInvalidations)
                if currentRootIdentity != rootIdentity {
                    recorder?.recordReason(.rootIdentityChanged)
                } else if metadataMonitor.acceptedWatermark(for: repositoryKey)
                    != expectedCurrentness.acceptedWatermark
                {
                    recorder?.recordReason(.watermarkAdvanced)
                } else if !coverageCurrent {
                    recorder?.recordReason(.coverageLost)
                } else {
                    recorder?.recordReason(.authorityGenerationChanged)
                }
            #endif
            await removePrefixControlCacheEntry(key, invalidated: true)
        }

        if let pending = pendingPrefixControlAdmissions[key] {
            if pending.isCancelled {
                #if DEBUG
                    recorder?.recordReason(.fallback)
                    lookupSpan?.end()
                #endif
                throw GitPrefixControlEvidenceCacheError.resourceAdmission
            }
            if pending.currentness == prefixControlCurrentness(for: scopeKey),
               (try? Self.prefixControlRootIdentity(for: layout.workTreeRoot)) == rootIdentity
            {
                prefixControlCacheCoalescedWaiterCount &+= 1
                #if DEBUG
                    recorder?.increment(.prefixCacheCoalesces)
                    lookupSpan?.end()
                #endif
                let evidence = try await waitForPendingPrefixControlAdmission(key: key, flightID: pending.id)
                if requiresCollectionDetail, evidence.collectionDetail == nil {
                    await removePrefixControlCacheEntry(key, invalidated: false)
                    return try await prefixControlCollectedEvidence(
                        in: layout,
                        prefix: prefix,
                        cacheMode: cacheMode,
                        policyAuthorityIdentity: policyAuthorityIdentity,
                        requiresCollectionDetail: true,
                        collector: collector
                    )
                }
                return evidence
            }
            #if DEBUG
                recorder?.recordReason(.staleCurrentness)
                lookupSpan?.end()
            #endif
            await cancelPendingPrefixControlAdmission(key, invalidated: true)
            throw GitPrefixControlEvidenceCacheError.resourceAdmission
        }

        if let pending = pendingUncachedPrefixControlFlights[key] {
            if pending.isCancelled {
                #if DEBUG
                    recorder?.recordReason(.fallback)
                    lookupSpan?.end()
                #endif
                throw GitPrefixControlEvidenceCacheError.resourceAdmission
            }
            prefixControlCacheCoalescedWaiterCount &+= 1
            #if DEBUG
                recorder?.increment(.prefixCacheCoalesces)
                lookupSpan?.end()
            #endif
            let evidence = try await waitForPendingUncachedPrefixControlFlight(key: key, flightID: pending.id)
            if requiresCollectionDetail, evidence.collectionDetail == nil {
                return try await prefixControlCollectedEvidence(
                    in: layout,
                    prefix: prefix,
                    cacheMode: cacheMode,
                    policyAuthorityIdentity: policyAuthorityIdentity,
                    requiresCollectionDetail: true,
                    collector: collector
                )
            }
            return evidence
        }

        prefixControlCacheMissCount &+= 1
        #if DEBUG
            recorder?.increment(.prefixCacheMisses)
            recorder?.recordReason(.absent)
            lookupSpan?.end()
        #endif
        let observationToken: GitWorkspaceMetadataMonitor.RetainToken
        do {
            observationToken = try await metadataMonitor.retainPrefixControlScope(
                repositoryKey: repositoryKey,
                repositoryRoot: layout.workTreeRoot,
                prefix: prefix
            ) { [weak self] kinds in
                Task { await self?.metadataDidChange(repositoryKey: repositoryKey, kinds: kinds) }
            }
        } catch {
            // Monitoring is an optimization prerequisite, not an authority
            // prerequisite. Preserve the old uncached collector on any
            // unavailable or ambiguous coverage setup.
            prefixControlPhysicalScanCount &+= 1
            #if DEBUG
                recorder?.recordReason(.monitorUnavailable)
            #endif
            return try await validatedCollector()
        }

        let currentness = prefixControlCurrentness(for: scopeKey)
        guard currentness.mutationDepth == 0,
              (try? Self.prefixControlRootIdentity(for: layout.workTreeRoot)) == rootIdentity
        else {
            await metadataMonitor.release(observationToken)
            #if DEBUG
                recorder?.recordReason(.staleCurrentness)
            #endif
            throw GitPrefixControlEvidenceCacheError.invalidatedDuringCollection
        }

        let reservedResidentBytes = requiresCollectionDetail
            ? Self.maximumPrefixControlEvidenceResidentBytes
            : Self.maximumPrefixControlFooterResidentBytes
        let reservedArtifactBytes: UInt64 = 0
        let (nextPendingResidentBytes, residentOverflow) = pendingPrefixControlResidentBytes
            .addingReportingOverflow(reservedResidentBytes)
        let (nextPendingArtifactBytes, artifactOverflow) = pendingPrefixControlArtifactBytes
            .addingReportingOverflow(reservedArtifactBytes)
        guard !residentOverflow,
              !artifactOverflow,
              pendingPrefixControlAdmissions.count < prefixControlCacheLimits.maximumPendingAdmissionCount,
              nextPendingResidentBytes <= prefixControlCacheLimits.maximumPendingResidentBytes,
              nextPendingArtifactBytes <= prefixControlCacheLimits.maximumPendingArtifactBytes
        else {
            await metadataMonitor.release(observationToken)
            #if DEBUG
                recorder?.recordReason(.fallback)
            #endif
            return try await startOrJoinBoundedUncachedPrefixControlFlight(
                key: key,
                reservedResidentBytes: reservedResidentBytes,
                collector: validatedCollector
            )
        }

        let flightID = UUID()
        prefixControlPhysicalScanCount &+= 1
        let task = Task { try await validatedCollector() }
        pendingPrefixControlResidentBytes = nextPendingResidentBytes
        pendingPrefixControlArtifactBytes = nextPendingArtifactBytes
        pendingPrefixControlAdmissions[key] = PendingPrefixControlAdmission(
            id: flightID,
            task: task,
            observationToken: observationToken,
            currentness: currentness,
            repositoryRoot: layout.workTreeRoot,
            waiters: [:],
            isCancelled: false,
            reservedResidentBytes: reservedResidentBytes,
            reservedArtifactBytes: reservedArtifactBytes
        )
        Task { [weak self] in
            let result: Result<GitPrefixControlCollectedEvidence, Error>
            do {
                result = try await .success(task.value)
            } catch {
                result = .failure(error)
            }
            await self?.completePendingPrefixControlAdmission(
                key: key,
                flightID: flightID,
                result: result
            )
        }
        return try await waitForPendingPrefixControlAdmission(key: key, flightID: flightID)
    }

    private func waitForPendingPrefixControlAdmission(
        key: PrefixControlCacheKey,
        flightID: UUID
    ) async throws -> GitPrefixControlCollectedEvidence {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard var pending = pendingPrefixControlAdmissions[key],
                      pending.id == flightID
                else {
                    continuation.resume(throwing: GitPrefixControlEvidenceCacheError.invalidatedDuringCollection)
                    return
                }
                pending.waiters[waiterID] = continuation
                pendingPrefixControlAdmissions[key] = pending
                if Task.isCancelled {
                    Task { await self.cancelPrefixControlWaiter(
                        key: key,
                        flightID: flightID,
                        waiterID: waiterID
                    ) }
                }
            }
        } onCancel: {
            Task { await self.cancelPrefixControlWaiter(
                key: key,
                flightID: flightID,
                waiterID: waiterID
            ) }
        }
    }

    private func cancelPrefixControlWaiter(
        key: PrefixControlCacheKey,
        flightID: UUID,
        waiterID: UUID
    ) async {
        guard var pending = pendingPrefixControlAdmissions[key],
              pending.id == flightID,
              let waiter = pending.waiters.removeValue(forKey: waiterID)
        else { return }
        waiter.resume(throwing: CancellationError())
        if pending.waiters.isEmpty {
            pendingPrefixControlAdmissions[key] = pending
            await cancelPendingPrefixControlAdmission(key, invalidated: false)
        } else {
            pendingPrefixControlAdmissions[key] = pending
        }
    }

    private func completePendingPrefixControlAdmission(
        key: PrefixControlCacheKey,
        flightID: UUID,
        result: Result<GitPrefixControlCollectedEvidence, Error>
    ) async {
        guard let initial = pendingPrefixControlAdmissions[key],
              initial.id == flightID
        else { return }

        if initial.isCancelled {
            let pending = takePendingPrefixControlAdmission(key, flightID: flightID)
            if let pending { await metadataMonitor.release(pending.observationToken) }
            return
        }

        switch result {
        case let .failure(error):
            let pending = takePendingPrefixControlAdmission(key, flightID: flightID)
            pending?.waiters.values.forEach { $0.resume(throwing: error) }
            if let pending { await metadataMonitor.release(pending.observationToken) }
        case let .success(evidence):
            #if DEBUG
                let admissionSpan = WorktreeStartupPreparationInstrumentation.currentRecorder?
                    .begin(.prefixControlCacheAdmit)
                defer { admissionSpan?.end() }
            #endif
            guard Self.prefixControlEvidenceIsValid(evidence) else {
                let pending = takePendingPrefixControlAdmission(key, flightID: flightID)
                pending?.waiters.values.forEach {
                    $0.resume(throwing: GitPrefixControlEvidenceCacheError.corruptFooter)
                }
                if let pending { await metadataMonitor.release(pending.observationToken) }
                #if DEBUG
                    WorktreeStartupPreparationInstrumentation.currentRecorder?.recordReason(.failure)
                #endif
                return
            }
            let coverageCurrent = await metadataMonitor.flushCoverageAndCheckCurrent(
                initial.observationToken,
                repositoryKey: key.repositoryKey,
                repositoryRoot: initial.repositoryRoot,
                prefix: key.prefix,
                expectedAcceptedWatermark: initial.currentness.acceptedWatermark
            )
            guard let pending = pendingPrefixControlAdmissions[key],
                  pending.id == flightID,
                  !pending.isCancelled,
                  coverageCurrent,
                  (try? Self.prefixControlRootIdentity(for: pending.repositoryRoot)) == key.rootIdentity,
                  prefixControlCurrentness(for: GitWorkspaceAuthorityScopeKey(
                      repositoryKey: key.repositoryKey,
                      repositoryRelativeRootPrefix: key.prefix
                  )) == pending.currentness
            else {
                let removed = takePendingPrefixControlAdmission(key, flightID: flightID)
                removed?.waiters.values.forEach {
                    $0.resume(throwing: GitPrefixControlEvidenceCacheError.invalidatedDuringCollection)
                }
                if let removed { await metadataMonitor.release(removed.observationToken) }
                #if DEBUG
                    WorktreeStartupPreparationInstrumentation.currentRecorder?
                        .increment(.prefixCacheInvalidations)
                    WorktreeStartupPreparationInstrumentation.currentRecorder?
                        .recordReason(.staleCurrentness)
                #endif
                return
            }

            guard let completed = takePendingPrefixControlAdmission(key, flightID: flightID) else { return }
            let residentBytes = Self.prefixControlEvidenceResidentBytes(evidence)
            let artifactBytes: UInt64 = 0
            prefixControlCacheAccessOrdinal &+= 1
            let entry = PrefixControlCacheEntry(
                id: UUID(),
                evidence: evidence,
                observationToken: completed.observationToken,
                currentness: completed.currentness,
                lastAccessOrdinal: prefixControlCacheAccessOrdinal,
                residentBytes: residentBytes,
                artifactBytes: artifactBytes
            )
            if let replaced = prefixControlCacheEntries.updateValue(entry, forKey: key) {
                prefixControlCacheResidentBytes = max(0, prefixControlCacheResidentBytes - replaced.residentBytes)
                prefixControlCacheArtifactBytes = prefixControlCacheArtifactBytes >= replaced.artifactBytes
                    ? prefixControlCacheArtifactBytes - replaced.artifactBytes
                    : 0
                await metadataMonitor.release(replaced.observationToken)
            }
            prefixControlCacheResidentBytes += residentBytes
            prefixControlCacheArtifactBytes += artifactBytes
            prefixControlCacheAdmissionCount &+= 1
            #if DEBUG
                WorktreeStartupPreparationInstrumentation.currentRecorder?
                    .increment(.prefixCacheAdmissions)
            #endif
            await evictPrefixControlCacheIfNeeded()
            completed.waiters.values.forEach { $0.resume(returning: evidence) }
        }
    }

    private func startOrJoinBoundedUncachedPrefixControlFlight(
        key: PrefixControlCacheKey,
        reservedResidentBytes: Int,
        collector: @escaping @Sendable () async throws -> GitPrefixControlCollectedEvidence
    ) async throws -> GitPrefixControlCollectedEvidence {
        if let pending = pendingUncachedPrefixControlFlights[key], !pending.isCancelled {
            prefixControlCacheCoalescedWaiterCount &+= 1
            #if DEBUG
                WorktreeStartupPreparationInstrumentation.currentRecorder?
                    .increment(.prefixCacheCoalesces)
            #endif
            return try await waitForPendingUncachedPrefixControlFlight(key: key, flightID: pending.id)
        }

        let reservedArtifactBytes: UInt64 = 0
        let (nextResidentBytes, residentOverflow) = pendingUncachedPrefixControlResidentBytes
            .addingReportingOverflow(reservedResidentBytes)
        let (nextArtifactBytes, artifactOverflow) = pendingUncachedPrefixControlArtifactBytes
            .addingReportingOverflow(reservedArtifactBytes)
        guard !residentOverflow,
              !artifactOverflow,
              pendingUncachedPrefixControlFlights.count < Self.maximumPendingUncachedPrefixControlFlightCount,
              nextResidentBytes <= Self.maximumPendingUncachedPrefixControlResidentBytes,
              nextArtifactBytes <= Self.maximumPendingUncachedPrefixControlArtifactBytes
        else { throw GitPrefixControlEvidenceCacheError.resourceAdmission }

        let flightID = UUID()
        prefixControlPhysicalScanCount &+= 1
        let task = Task { try await collector() }
        pendingUncachedPrefixControlResidentBytes = nextResidentBytes
        pendingUncachedPrefixControlArtifactBytes = nextArtifactBytes
        pendingUncachedPrefixControlFlights[key] = PendingUncachedPrefixControlFlight(
            id: flightID,
            task: task,
            waiters: [:],
            isCancelled: false,
            reservedResidentBytes: reservedResidentBytes,
            reservedArtifactBytes: reservedArtifactBytes
        )
        Task { [weak self] in
            let result: Result<GitPrefixControlCollectedEvidence, Error>
            do {
                result = try await .success(task.value)
            } catch {
                result = .failure(error)
            }
            await self?.completePendingUncachedPrefixControlFlight(
                key: key,
                flightID: flightID,
                result: result
            )
        }
        return try await waitForPendingUncachedPrefixControlFlight(key: key, flightID: flightID)
    }

    private func waitForPendingUncachedPrefixControlFlight(
        key: PrefixControlCacheKey,
        flightID: UUID
    ) async throws -> GitPrefixControlCollectedEvidence {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard var pending = pendingUncachedPrefixControlFlights[key],
                      pending.id == flightID,
                      !pending.isCancelled
                else {
                    continuation.resume(throwing: GitPrefixControlEvidenceCacheError.invalidatedDuringCollection)
                    return
                }
                pending.waiters[waiterID] = continuation
                pendingUncachedPrefixControlFlights[key] = pending
                if Task.isCancelled {
                    Task { await self.cancelUncachedPrefixControlWaiter(
                        key: key,
                        flightID: flightID,
                        waiterID: waiterID
                    ) }
                }
            }
        } onCancel: {
            Task { await self.cancelUncachedPrefixControlWaiter(
                key: key,
                flightID: flightID,
                waiterID: waiterID
            ) }
        }
    }

    private func cancelUncachedPrefixControlWaiter(
        key: PrefixControlCacheKey,
        flightID: UUID,
        waiterID: UUID
    ) {
        guard var pending = pendingUncachedPrefixControlFlights[key],
              pending.id == flightID,
              let waiter = pending.waiters.removeValue(forKey: waiterID)
        else { return }
        waiter.resume(throwing: CancellationError())
        if pending.waiters.isEmpty {
            pending.isCancelled = true
            pending.task.cancel()
        }
        pendingUncachedPrefixControlFlights[key] = pending
    }

    private func completePendingUncachedPrefixControlFlight(
        key: PrefixControlCacheKey,
        flightID: UUID,
        result: Result<GitPrefixControlCollectedEvidence, Error>
    ) {
        guard let completed = takePendingUncachedPrefixControlFlight(key, flightID: flightID) else { return }
        guard !completed.isCancelled else { return }
        switch result {
        case let .success(evidence):
            completed.waiters.values.forEach { $0.resume(returning: evidence) }
        case let .failure(error):
            completed.waiters.values.forEach { $0.resume(throwing: error) }
        }
    }

    private func prefixControlCurrentness(
        for scopeKey: GitWorkspaceAuthorityScopeKey
    ) -> PrefixControlCurrentnessKey {
        let record = records[scopeKey.repositoryKey] ?? Record()
        return PrefixControlCurrentnessKey(
            invalidationGeneration: record.invalidationGeneration,
            publicationGeneration: record.publicationGenerationByScope[scopeKey] ?? 0,
            acceptedWatermark: metadataMonitor.acceptedWatermark(for: scopeKey.repositoryKey),
            mutationDepth: hasActiveMutation(for: scopeKey.repositoryKey) ? max(1, record.mutationDepth) : record.mutationDepth,
            monitorCoverageUnavailable: record.monitorCoverageUnavailable
        )
    }

    func beginCollection(
        scopeKey: GitWorkspaceAuthorityScopeKey
    ) -> Result<GitWorkspaceAuthorityCaptureToken, GitWorkspaceAuthorityUnavailableReason> {
        let record = records[scopeKey.repositoryKey] ?? Record()
        guard !hasActiveMutation(for: scopeKey.repositoryKey),
              record.mutationDepth == 0
        else { return .failure(.mutationInProgress) }
        guard !record.monitorCoverageUnavailable else { return .failure(.monitorCoverageUnavailable) }
        records[scopeKey.repositoryKey] = record
        updateSynchronousState(repositoryKey: scopeKey.repositoryKey, record: record)
        return .success(GitWorkspaceAuthorityCaptureToken(
            scopeKey: scopeKey,
            invalidationGeneration: record.invalidationGeneration,
            scopePublicationGeneration: record.publicationGenerationByScope[scopeKey] ?? 0,
            acceptedMetadataWatermark: metadataMonitor.acceptedWatermark(for: scopeKey.repositoryKey)
        ))
    }

    func collectAndInstall(
        scopeKey: GitWorkspaceAuthorityScopeKey,
        collector: @Sendable () async throws -> GitWorkspaceAuthoritySnapshot
    ) async throws -> Result<GitWorkspaceAuthorityLease, GitWorkspaceAuthorityUnavailableReason> {
        let token: GitWorkspaceAuthorityCaptureToken
        switch beginCollection(scopeKey: scopeKey) {
        case let .success(value): token = value
        case let .failure(reason): return .failure(reason)
        }
        let snapshot = try await collector()
        return install(snapshot, capturedUsing: token)
    }

    @discardableResult
    func install(
        _ snapshot: GitWorkspaceAuthoritySnapshot,
        capturedUsing token: GitWorkspaceAuthorityCaptureToken
    ) -> Result<GitWorkspaceAuthorityLease, GitWorkspaceAuthorityUnavailableReason> {
        let scopeKey = GitWorkspaceAuthorityScopeKey(
            repositoryKey: snapshot.repositoryKey,
            repositoryRelativeRootPrefix: snapshot.repositoryRelativeRootPrefix
        )
        guard scopeKey == token.scopeKey else { return .failure(.collectionScopeMismatch) }
        guard var record = records[scopeKey.repositoryKey] else {
            return .failure(.invalidatedDuringCollection)
        }
        guard !hasActiveMutation(for: scopeKey.repositoryKey),
              record.mutationDepth == 0
        else { return .failure(.mutationInProgress) }
        guard !record.monitorCoverageUnavailable else { return .failure(.monitorCoverageUnavailable) }
        guard record.invalidationGeneration == token.invalidationGeneration,
              (record.publicationGenerationByScope[scopeKey] ?? 0) == token.scopePublicationGeneration,
              metadataMonitor.acceptedWatermark(for: scopeKey.repositoryKey) == token.acceptedMetadataWatermark
        else {
            return .failure(.invalidatedDuringCollection)
        }

        let lease = metadataMonitor.withCurrentAcceptedWatermark(
            for: scopeKey.repositoryKey,
            expected: token.acceptedMetadataWatermark
        ) {
            let publicationGeneration = token.scopePublicationGeneration &+ 1
            record.publicationGenerationByScope[scopeKey] = publicationGeneration
            record.snapshotsByScope[scopeKey] = snapshot
            record.acceptedWatermarkByScope[scopeKey] = token.acceptedMetadataWatermark
            records[scopeKey.repositoryKey] = record
            updateSynchronousState(repositoryKey: scopeKey.repositoryKey, record: record)
            let promotedCurrentness = PrefixControlCurrentnessKey(
                invalidationGeneration: record.invalidationGeneration,
                publicationGeneration: publicationGeneration,
                acceptedWatermark: token.acceptedMetadataWatermark,
                mutationDepth: record.mutationDepth,
                monitorCoverageUnavailable: record.monitorCoverageUnavailable
            )
            let promotableKeys = prefixControlCacheEntries.keys.filter { key in
                guard let entry = prefixControlCacheEntries[key] else { return false }
                return key.repositoryKey == scopeKey.repositoryKey
                    && key.prefix == scopeKey.repositoryRelativeRootPrefix
                    && entry.currentness.invalidationGeneration == record.invalidationGeneration
                    && entry.currentness.publicationGeneration == token.scopePublicationGeneration
                    && entry.currentness.acceptedWatermark == token.acceptedMetadataWatermark
                    && entry.currentness.mutationDepth == 0
                    && !entry.currentness.monitorCoverageUnavailable
            }
            for key in promotableKeys {
                guard var entry = prefixControlCacheEntries[key] else { continue }
                entry.currentness = promotedCurrentness
                prefixControlCacheEntries[key] = entry
            }
            return GitWorkspaceAuthorityLease(
                scopeKey: scopeKey,
                authorityGeneration: publicationGeneration,
                invalidationGeneration: record.invalidationGeneration,
                acceptedMetadataWatermark: token.acceptedMetadataWatermark,
                snapshot: snapshot
            )
        }
        guard let lease else { return .failure(.invalidatedDuringCollection) }
        return .success(lease)
    }

    /// Test/support convenience for an already collected immutable value. There
    /// is no suspension between token issue and conditional installation.
    @discardableResult
    func install(_ snapshot: GitWorkspaceAuthoritySnapshot) throws -> GitWorkspaceAuthorityLease {
        let scopeKey = GitWorkspaceAuthorityScopeKey(
            repositoryKey: snapshot.repositoryKey,
            repositoryRelativeRootPrefix: snapshot.repositoryRelativeRootPrefix
        )
        let token: GitWorkspaceAuthorityCaptureToken
        switch beginCollection(scopeKey: scopeKey) {
        case let .success(value): token = value
        case let .failure(reason): throw reason
        }
        switch install(snapshot, capturedUsing: token) {
        case let .success(lease): return lease
        case let .failure(reason): throw reason
        }
    }

    func currentLease(
        for repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        prefix: GitRepositoryRelativeRootPrefix
    ) -> Result<GitWorkspaceAuthorityLease, GitWorkspaceAuthorityUnavailableReason> {
        let scopeKey = GitWorkspaceAuthorityScopeKey(
            repositoryKey: repositoryKey,
            repositoryRelativeRootPrefix: prefix
        )
        guard let record = records[repositoryKey] else { return .failure(.noSnapshot) }
        guard !hasActiveMutation(for: scopeKey.repositoryKey),
              record.mutationDepth == 0
        else { return .failure(.mutationInProgress) }
        guard !record.monitorCoverageUnavailable else { return .failure(.monitorCoverageUnavailable) }
        guard let snapshot = record.snapshotsByScope[scopeKey] else { return .failure(.metadataEventPending) }
        let watermark = metadataMonitor.acceptedWatermark(for: repositoryKey)
        guard record.acceptedWatermarkByScope[scopeKey] == watermark else {
            return .failure(.invalidatedDuringCollection)
        }
        return .success(GitWorkspaceAuthorityLease(
            scopeKey: scopeKey,
            authorityGeneration: record.publicationGenerationByScope[scopeKey] ?? 0,
            invalidationGeneration: record.invalidationGeneration,
            acceptedMetadataWatermark: watermark,
            snapshot: snapshot
        ))
    }

    func isCurrent(_ lease: GitWorkspaceAuthorityLease) -> Bool {
        guard let record = records[lease.repositoryKey] else { return false }
        return !hasActiveMutation(for: lease.repositoryKey)
            && record.mutationDepth == 0
            && !record.monitorCoverageUnavailable
            && record.invalidationGeneration == lease.invalidationGeneration
            && record.publicationGenerationByScope[lease.scopeKey] == lease.authorityGeneration
            && record.snapshotsByScope[lease.scopeKey] == lease.snapshot
            && record.acceptedWatermarkByScope[lease.scopeKey] == lease.acceptedMetadataWatermark
            && metadataMonitor.acceptedWatermark(for: lease.repositoryKey) == lease.acceptedMetadataWatermark
    }

    /// Retains no paths and performs no polling. Events are path-free wakeups;
    /// the accepted watermark and lease remain the authority for currentness.
    func invalidationEvents() -> AsyncStream<GitWorkspaceAuthorityInvalidationEvent> {
        let subscriptionID = UUID()
        return AsyncStream { continuation in
            invalidationContinuations[subscriptionID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeInvalidationContinuation(subscriptionID) }
            }
        }
    }

    func pendingInitializationFenceDecision(
        _ fence: GitWorkspacePendingInitializationAuthorityFence
    ) async -> GitWorkspacePendingAuthorityFenceDecision {
        if await pendingInitializationAuthorityFenceIsCurrent(fence) {
            return .current
        }
        guard !fence.revalidationUsed else { return .fallback }
        return .revalidationRequired(
            latestAcceptedMetadataWatermark: metadataMonitor.acceptedWatermark(for: fence.repositoryKey)
        )
    }

    func pendingInitializationAuthorityFenceIsCurrent(
        _ fence: GitWorkspacePendingInitializationAuthorityFence
    ) async -> Bool {
        guard fence.snapshot == fence.lease.snapshot,
              fence.acceptedMetadataWatermark == fence.lease.acceptedMetadataWatermark,
              fence.repositoryKey == GitWorkspaceAuthorityRepositoryKey(layout: fence.targetLayout),
              fence.repositoryRelativeRootPrefix == fence.lease.scopeKey.repositoryRelativeRootPrefix,
              fence.repositoryRelativeRootPrefix == fence.snapshot.repositoryRelativeRootPrefix,
              isCurrent(fence.lease),
              metadataMonitor.acceptedWatermarkIsCurrent(
                  for: fence.repositoryKey,
                  expected: fence.acceptedMetadataWatermark
              )
        else { return false }
        guard await metadataObservationIsCurrent(
            fence.metadataObservationToken,
            for: fence.targetLayout,
            additionalAuthorityPaths: fence.additionalAuthorityPaths,
            expectedAcceptedWatermark: fence.acceptedMetadataWatermark
        ) else { return false }
        // The monitor actor hop above is an await boundary. Reprove both actor
        // generation and callback-accepted watermark after resumption.
        return isCurrent(fence.lease)
            && metadataMonitor.acceptedWatermarkIsCurrent(
                for: fence.repositoryKey,
                expected: fence.acceptedMetadataWatermark
            )
    }

    nonisolated func pendingInitializationAuthorityFenceIsSynchronouslyCurrent(
        _ fence: GitWorkspacePendingInitializationAuthorityFence
    ) -> Bool {
        guard synchronousState.isCurrent(fence) else { return false }
        guard metadataMonitor.acceptedWatermarkIsCurrent(
            for: fence.repositoryKey,
            expected: fence.acceptedMetadataWatermark
        ) else { return false }
        // Recheck the actor-owned generation mirror after the watermark read so
        // mutation begin and metadata callback acceptance cannot straddle this proof.
        return synchronousState.isCurrent(fence)
    }

    /// Serializes the pending-to-published store commit with both mutation
    /// invalidation and callback-accepted Git metadata watermarks. An
    /// invalidation that wins the permit makes publication fail; one that
    /// arrives afterward is necessarily a published-root reconciliation.
    nonisolated func withPendingInitializationAuthorityPublicationPermit<T>(
        _ fences: [GitWorkspacePendingInitializationAuthorityFence],
        _ body: () -> T
    ) -> T? {
        var expectedWatermarks: [GitWorkspaceAuthorityRepositoryKey: UInt64] = [:]
        for fence in fences {
            if let existing = expectedWatermarks[fence.repositoryKey],
               existing != fence.acceptedMetadataWatermark
            {
                return nil
            }
            expectedWatermarks[fence.repositoryKey] = fence.acceptedMetadataWatermark
        }
        return synchronousState.withCurrentFences(fences) {
            metadataMonitor.withCurrentAcceptedWatermarks(expectedWatermarks, body)
        }
    }

    func releasePendingInitializationAuthorityFence(
        _ fence: GitWorkspacePendingInitializationAuthorityFence
    ) async {
        await retireEphemeralAuthorityLease(
            fence.lease,
            observationToken: fence.metadataObservationToken
        )
    }

    @discardableResult
    func admitReusableSnapshot(
        _ snapshot: WorkspaceRootReusableSnapshot,
        capturedUsing lease: GitWorkspaceAuthorityLease,
        observationToken: GitWorkspaceMetadataMonitor.RetainToken
    ) async -> Bool {
        guard let prepared = await prepareReusableSnapshotAdmission(
            snapshot,
            capturedUsing: lease,
            observationToken: observationToken
        ) else { return false }
        return await admitPreparedReusableSnapshot(prepared) != nil
    }

    func prepareReusableSnapshotAdmission(
        _ snapshot: WorkspaceRootReusableSnapshot,
        capturedUsing lease: GitWorkspaceAuthorityLease,
        observationToken: GitWorkspaceMetadataMonitor.RetainToken
    ) async -> PreparedReusableSnapshotAdmission? {
        guard isCurrent(lease),
              snapshot.hasValidContentAddress(),
              snapshot.compatibilityKey == WorkspaceRootSeedCompatibilityKey(authority: lease.snapshot),
              snapshot.estimatedByteCount <= reusableSnapshotCacheLimits.maximumEstimatedBytes
        else {
            await metadataMonitor.release(observationToken)
            return nil
        }

        let (retainedAndPendingBytes, retainedAndPendingOverflow) = reusableSnapshotArtifactBytes
            .addingReportingOverflow(pendingReusableSnapshotArtifactBytes)
        let (reservedTotal, reservationOverflow) = retainedAndPendingBytes
            .addingReportingOverflow(snapshot.artifactByteCount)
        guard !retainedAndPendingOverflow,
              !reservationOverflow,
              snapshot.artifactByteCount <= reusableSnapshotCacheLimits.maximumArtifactBytes,
              reservedTotal <= reusableSnapshotCacheLimits.maximumArtifactBytes
        else {
            reusableSnapshotArtifactBudgetRejectionCount &+= 1
            await metadataMonitor.release(observationToken)
            return nil
        }

        let prepared = PreparedReusableSnapshotAdmission(id: UUID())
        pendingReusableSnapshotArtifactBytes += snapshot.artifactByteCount
        pendingReusableSnapshotAdmissions[prepared.id] = PendingReusableSnapshotAdmission(
            snapshot: snapshot,
            lease: lease,
            observationToken: observationToken,
            reservedArtifactBytes: snapshot.artifactByteCount
        )
        return prepared
    }

    func preparedReusableSnapshotAdmissionIsCurrent(
        _ prepared: PreparedReusableSnapshotAdmission
    ) -> Bool {
        guard let pending = pendingReusableSnapshotAdmissions[prepared.id] else { return false }
        return isCurrent(pending.lease)
    }

    func cancelPreparedReusableSnapshotAdmission(
        _ prepared: PreparedReusableSnapshotAdmission
    ) async {
        guard let pending = takePendingReusableSnapshotAdmission(prepared) else { return }
        await metadataMonitor.release(pending.observationToken)
    }

    func admitPreparedReusableSnapshot(
        _ prepared: PreparedReusableSnapshotAdmission
    ) async -> ReusableSnapshotAdmissionReceipt? {
        guard let pending = takePendingReusableSnapshotAdmission(prepared) else { return nil }
        let snapshot = pending.snapshot
        let lease = pending.lease
        let observationToken = pending.observationToken
        guard isCurrent(lease),
              snapshot.hasValidContentAddress(),
              snapshot.compatibilityKey == WorkspaceRootSeedCompatibilityKey(authority: lease.snapshot)
        else {
            await metadataMonitor.release(observationToken)
            return nil
        }

        reusableSnapshotAccessOrdinal &+= 1
        if var existing = reusableSnapshotsByIdentity[snapshot.identity] {
            guard existing.snapshot.compatibilityKey == snapshot.compatibilityKey,
                  existing.snapshot.inventoryManifest.manifestDigest
                  == snapshot.inventoryManifest.manifestDigest,
                  existing.snapshot.inventoryManifest.footer == snapshot.inventoryManifest.footer,
                  existing.snapshot.hasValidContentAddress()
            else {
                await metadataMonitor.release(observationToken)
                return nil
            }
            existing.lastAccessOrdinal = reusableSnapshotAccessOrdinal
            reusableSnapshotsByIdentity[snapshot.identity] = existing
        } else {
            reusableSnapshotsByIdentity[snapshot.identity] = ReusableSnapshotCacheEntry(
                snapshot: snapshot,
                lastAccessOrdinal: reusableSnapshotAccessOrdinal
            )
            reusableSnapshotEstimatedBytes += snapshot.estimatedByteCount
            reusableSnapshotArtifactBytes += snapshot.artifactByteCount
        }

        let previous = reusableSnapshotAliasesByScope.updateValue(
            ReusableSnapshotAlias(
                admissionID: prepared.id,
                lease: lease,
                snapshotIdentity: snapshot.identity,
                observationToken: observationToken
            ),
            forKey: lease.scopeKey
        )
        let retained = await evictReusableSnapshotsIfNeeded()
        guard retained,
              reusableSnapshotsByIdentity[snapshot.identity] != nil
        else {
            if let previous {
                reusableSnapshotAliasesByScope[lease.scopeKey] = previous
            } else {
                reusableSnapshotAliasesByScope.removeValue(forKey: lease.scopeKey)
            }
            if reusableSnapshotAliasesByScope.values.contains(where: { $0.snapshotIdentity == snapshot.identity }) == false {
                removeUnaliasedReusableSnapshot(snapshot.identity)
            }
            await metadataMonitor.release(observationToken)
            return nil
        }
        if let previous {
            await metadataMonitor.release(previous.observationToken)
            if previous.snapshotIdentity != snapshot.identity {
                removeUnaliasedReusableSnapshot(previous.snapshotIdentity)
            }
        }
        return ReusableSnapshotAdmissionReceipt(
            id: prepared.id,
            snapshotIdentity: snapshot.identity
        )
    }

    func reusableSnapshotAdmissionIsCurrent(
        _ receipt: ReusableSnapshotAdmissionReceipt
    ) -> Bool {
        guard let alias = reusableSnapshotAliasesByScope.values.first(where: { $0.admissionID == receipt.id }) else {
            return false
        }
        return alias.snapshotIdentity == receipt.snapshotIdentity && isCurrent(alias.lease)
    }

    func revokeReusableSnapshotAdmission(
        _ receipt: ReusableSnapshotAdmissionReceipt
    ) async {
        guard let (scopeKey, alias) = reusableSnapshotAliasesByScope.first(where: { $0.value.admissionID == receipt.id }) else {
            return
        }
        reusableSnapshotAliasesByScope.removeValue(forKey: scopeKey)
        removeUnaliasedReusableSnapshot(receipt.snapshotIdentity)
        await metadataMonitor.release(alias.observationToken)
    }

    func revokeReusableSnapshotAdmissions(
        snapshotIdentity: WorkspaceRootReusableSnapshotIdentity
    ) async {
        let aliases = reusableSnapshotAliasesByScope.filter { $0.value.snapshotIdentity == snapshotIdentity }
        for (scopeKey, alias) in aliases {
            reusableSnapshotAliasesByScope.removeValue(forKey: scopeKey)
            await metadataMonitor.release(alias.observationToken)
        }
        removeUnaliasedReusableSnapshot(snapshotIdentity)
    }

    func currentReusableSnapshot(
        capturedUsing lease: GitWorkspaceAuthorityLease
    ) async -> WorkspaceRootReusableSnapshot? {
        guard isCurrent(lease),
              let alias = reusableSnapshotAliasesByScope[lease.scopeKey],
              alias.lease == lease,
              var entry = reusableSnapshotsByIdentity[alias.snapshotIdentity],
              entry.snapshot.hasValidContentAddress(),
              entry.snapshot.compatibilityKey == WorkspaceRootSeedCompatibilityKey(authority: lease.snapshot)
        else {
            if let alias = reusableSnapshotAliasesByScope[lease.scopeKey],
               alias.lease == lease
            {
                reusableSnapshotAliasesByScope.removeValue(forKey: lease.scopeKey)
                await metadataMonitor.release(alias.observationToken)
            }
            return nil
        }
        reusableSnapshotAccessOrdinal &+= 1
        entry.lastAccessOrdinal = reusableSnapshotAccessOrdinal
        reusableSnapshotsByIdentity[alias.snapshotIdentity] = entry
        return entry.snapshot
    }

    func reusableSnapshot(
        compatibleWith snapshot: GitWorkspaceAuthoritySnapshot
    ) -> WorkspaceRootReusableSnapshot? {
        let key = WorkspaceRootSeedCompatibilityKey(authority: snapshot)
        guard let identity = reusableSnapshotsByIdentity.first(where: {
            $0.value.snapshot.compatibilityKey == key && $0.value.snapshot.hasValidContentAddress()
        })?.key else { return nil }
        reusableSnapshotAccessOrdinal &+= 1
        reusableSnapshotsByIdentity[identity]?.lastAccessOrdinal = reusableSnapshotAccessOrdinal
        return reusableSnapshotsByIdentity[identity]?.snapshot
    }

    func reusableSnapshot(
        identity: WorkspaceRootReusableSnapshotIdentity,
        expectedCompatibilityKey: WorkspaceRootSeedCompatibilityKey
    ) -> WorkspaceRootReusableSnapshot? {
        guard identity.searchABI == .current,
              var entry = reusableSnapshotsByIdentity[identity],
              entry.snapshot.compatibilityKey == expectedCompatibilityKey,
              entry.snapshot.hasValidContentAddress()
        else { return nil }
        reusableSnapshotAccessOrdinal &+= 1
        entry.lastAccessOrdinal = reusableSnapshotAccessOrdinal
        reusableSnapshotsByIdentity[identity] = entry
        return entry.snapshot
    }

    private func evictReusableSnapshotsIfNeeded() async -> Bool {
        while reusableSnapshotsByIdentity.count > reusableSnapshotCacheLimits.maximumSnapshotCount
            || reusableSnapshotEstimatedBytes > reusableSnapshotCacheLimits.maximumEstimatedBytes
            || reusableSnapshotArtifactBytes > reusableSnapshotCacheLimits.maximumArtifactBytes
            || repositorySnapshotCountExceedsLimit()
        {
            let pinnedIdentities = Set(reusableSnapshotAliasesByScope.values.map(\.snapshotIdentity))
            let overfullNamespaces = repositorySnapshotCounts()
                .filter { $0.value > reusableSnapshotCacheLimits.maximumSnapshotsPerRepository }
                .map(\.key)
            let candidates = reusableSnapshotsByIdentity.filter { identity, entry in
                !pinnedIdentities.contains(identity)
                    && (
                        overfullNamespaces.isEmpty
                            || overfullNamespaces.contains(entry.snapshot.compatibilityKey.repositoryNamespace)
                    )
            }
            guard let candidate = candidates.min(by: {
                $0.value.lastAccessOrdinal < $1.value.lastAccessOrdinal
            }) else { return false }
            removeUnaliasedReusableSnapshot(candidate.key)
        }
        return true
    }

    private func repositorySnapshotCountExceedsLimit() -> Bool {
        repositorySnapshotCounts().values.contains {
            $0 > reusableSnapshotCacheLimits.maximumSnapshotsPerRepository
        }
    }

    private func repositorySnapshotCounts() -> [GitBlobRepositoryNamespace: Int] {
        Dictionary(grouping: reusableSnapshotsByIdentity.values) {
            $0.snapshot.compatibilityKey.repositoryNamespace
        }.mapValues(\.count)
    }

    private func removeReusableSnapshot(_ identity: WorkspaceRootReusableSnapshotIdentity) async {
        guard let removed = reusableSnapshotsByIdentity.removeValue(forKey: identity) else { return }
        reusableSnapshotEstimatedBytes = max(0, reusableSnapshotEstimatedBytes - removed.snapshot.estimatedByteCount)
        reusableSnapshotArtifactBytes = reusableSnapshotArtifactBytes >= removed.snapshot.artifactByteCount
            ? reusableSnapshotArtifactBytes - removed.snapshot.artifactByteCount
            : 0
        let aliases = reusableSnapshotAliasesByScope.filter { $0.value.snapshotIdentity == identity }
        for (scopeKey, alias) in aliases {
            reusableSnapshotAliasesByScope.removeValue(forKey: scopeKey)
            await metadataMonitor.release(alias.observationToken)
        }
    }

    private func removeUnaliasedReusableSnapshot(
        _ identity: WorkspaceRootReusableSnapshotIdentity
    ) {
        guard !reusableSnapshotAliasesByScope.values.contains(where: { $0.snapshotIdentity == identity }),
              let removed = reusableSnapshotsByIdentity.removeValue(forKey: identity)
        else { return }
        reusableSnapshotEstimatedBytes = max(
            0,
            reusableSnapshotEstimatedBytes - removed.snapshot.estimatedByteCount
        )
        reusableSnapshotArtifactBytes = reusableSnapshotArtifactBytes >= removed.snapshot.artifactByteCount
            ? reusableSnapshotArtifactBytes - removed.snapshot.artifactByteCount
            : 0
    }

    private func takePendingReusableSnapshotAdmission(
        _ prepared: PreparedReusableSnapshotAdmission
    ) -> PendingReusableSnapshotAdmission? {
        guard let pending = pendingReusableSnapshotAdmissions.removeValue(forKey: prepared.id) else { return nil }
        pendingReusableSnapshotArtifactBytes = pendingReusableSnapshotArtifactBytes >= pending.reservedArtifactBytes
            ? pendingReusableSnapshotArtifactBytes - pending.reservedArtifactBytes
            : 0
        return pending
    }

    func beginMutation(
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        kind: GitWorkspaceMutationKind,
        correlationID: UUID? = nil
    ) async -> GitWorkspaceMutationToken {
        let affectedKeys = Set(records.keys.filter { Self.sameCommonDirectory($0, repositoryKey) })
            .union([repositoryKey])
        let token = GitWorkspaceMutationToken(
            id: UUID(),
            repositoryKey: repositoryKey,
            affectedRepositoryKeys: affectedKeys,
            kind: kind,
            correlationID: correlationID
        )
        for key in affectedKeys {
            var record = records[key] ?? Record()
            record.mutationDepth += 1
            record.invalidationGeneration &+= 1
            record.snapshotsByScope.removeAll(keepingCapacity: true)
            records[key] = record
            updateSynchronousState(repositoryKey: key, record: record)
            emitInvalidation(
                repositoryKey: key,
                record: record,
                kind: .mutationBegan(kind)
            )
        }
        await invalidatePrefixControlCache(for: affectedKeys)
        await removeReusableSnapshotAliases(for: affectedKeys)
        activeMutations[token.id] = token
        return token
    }

    /// Completion balances mutation state exactly once. Invalidation occurs at
    /// begin, so a collection spanning even a failed/cancelled mutation cannot
    /// reinstall stale evidence.
    func finishMutation(
        _ token: GitWorkspaceMutationToken,
        outcome: GitWorkspaceMutationOutcome
    ) {
        guard activeMutations.removeValue(forKey: token.id) != nil else { return }
        for key in token.affectedRepositoryKeys {
            var record = records[key] ?? Record()
            record.mutationDepth = max(0, record.mutationDepth - 1)
            records[key] = record
            updateSynchronousState(repositoryKey: key, record: record)
            emitInvalidation(
                repositoryKey: key,
                record: record,
                kind: .mutationCompleted(token.kind, outcome)
            )
        }
    }

    func metadataDidChange(
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        kinds: Set<GitWorkspaceMetadataEventKind>
    ) async {
        var record = records[repositoryKey] ?? Record()
        record.metadataEventCount &+= 1
        record.invalidationGeneration &+= 1
        record.snapshotsByScope.removeAll(keepingCapacity: true)
        if kinds.contains(.monitorGap) {
            record.monitorCoverageUnavailable = true
        }
        records[repositoryKey] = record
        updateSynchronousState(repositoryKey: repositoryKey, record: record)
        emitInvalidation(
            repositoryKey: repositoryKey,
            record: record,
            kind: .metadata(kinds)
        )
        await invalidatePrefixControlCache(for: [repositoryKey])
        await removeReusableSnapshotAliases(for: [repositoryKey])
    }

    private func removeReusableSnapshotAliases(
        for repositoryKeys: Set<GitWorkspaceAuthorityRepositoryKey>
    ) async {
        let aliases = reusableSnapshotAliasesByScope.filter {
            repositoryKeys.contains($0.key.repositoryKey)
        }
        for (scopeKey, alias) in aliases {
            reusableSnapshotAliasesByScope.removeValue(forKey: scopeKey)
            await metadataMonitor.release(alias.observationToken)
        }
    }

    func retainMetadataObservation(
        for layout: GitRepositoryLayout,
        additionalAuthorityPaths: [URL] = []
    ) async throws -> GitWorkspaceMetadataMonitor.RetainToken {
        let key = GitWorkspaceAuthorityRepositoryKey(layout: layout)
        let paths = Self.metadataPaths(for: layout) + additionalAuthorityPaths
        let token = try await metadataMonitor.retain(repositoryKey: key, paths: paths) { [weak self] kinds in
            Task { await self?.metadataDidChange(repositoryKey: key, kinds: kinds) }
        }
        let acceptedWatermark = metadataMonitor.acceptedWatermark(for: key)
        let hasValidatedFullCoverage = await metadataMonitor.flushCoverageAndCheckCurrent(
            token,
            repositoryKey: key,
            paths: paths,
            expectedAcceptedWatermark: acceptedWatermark
        )
        var record = records[key] ?? Record()
        if record.monitorCoverageUnavailable, hasValidatedFullCoverage {
            record.monitorCoverageUnavailable = false
            record.invalidationGeneration &+= 1
            record.snapshotsByScope.removeAll(keepingCapacity: true)
            await invalidatePrefixControlCache(for: [key])
        }
        records[key] = record
        updateSynchronousState(repositoryKey: key, record: record)
        return token
    }

    func metadataObservationIsCurrent(
        _ token: GitWorkspaceMetadataMonitor.RetainToken,
        for layout: GitRepositoryLayout,
        additionalAuthorityPaths: [URL] = [],
        expectedAcceptedWatermark: UInt64
    ) async -> Bool {
        await metadataMonitor.coverageIsCurrent(
            token,
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: layout),
            paths: Self.metadataPaths(for: layout) + additionalAuthorityPaths,
            expectedAcceptedWatermark: expectedAcceptedWatermark
        )
    }

    func retireEphemeralAuthorityLease(
        _ lease: GitWorkspaceAuthorityLease,
        observationToken: GitWorkspaceMetadataMonitor.RetainToken
    ) async {
        await metadataMonitor.release(observationToken)
        guard var record = records[lease.repositoryKey],
              record.publicationGenerationByScope[lease.scopeKey] == lease.authorityGeneration,
              record.snapshotsByScope[lease.scopeKey] == lease.snapshot
        else { return }
        record.monitorCoverageUnavailable = true
        record.invalidationGeneration &+= 1
        record.snapshotsByScope.removeAll(keepingCapacity: true)
        records[lease.repositoryKey] = record
        updateSynchronousState(repositoryKey: lease.repositoryKey, record: record)
        await invalidatePrefixControlCache(for: [lease.repositoryKey])
        await removeReusableSnapshotAliases(for: [lease.repositoryKey])
    }

    func releaseMetadataObservation(_ token: GitWorkspaceMetadataMonitor.RetainToken) async {
        await metadataMonitor.release(token)
    }

    private func takePendingPrefixControlAdmission(
        _ key: PrefixControlCacheKey,
        flightID: UUID
    ) -> PendingPrefixControlAdmission? {
        guard let pending = pendingPrefixControlAdmissions[key],
              pending.id == flightID
        else { return nil }
        pendingPrefixControlAdmissions.removeValue(forKey: key)
        pendingPrefixControlResidentBytes = max(
            0,
            pendingPrefixControlResidentBytes - pending.reservedResidentBytes
        )
        pendingPrefixControlArtifactBytes = pendingPrefixControlArtifactBytes >= pending.reservedArtifactBytes
            ? pendingPrefixControlArtifactBytes - pending.reservedArtifactBytes
            : 0
        return pending
    }

    private func cancelPendingPrefixControlAdmission(
        _ key: PrefixControlCacheKey,
        invalidated: Bool
    ) async {
        guard var pending = pendingPrefixControlAdmissions[key],
              !pending.isCancelled
        else { return }
        pending.isCancelled = true
        let waiters = pending.waiters
        pending.waiters.removeAll(keepingCapacity: false)
        pendingPrefixControlAdmissions[key] = pending
        pending.task.cancel()
        let error: Error = invalidated
            ? GitPrefixControlEvidenceCacheError.invalidatedDuringCollection
            : CancellationError()
        waiters.values.forEach { $0.resume(throwing: error) }
        if invalidated {
            prefixControlCacheInvalidationCount &+= 1
            #if DEBUG
                WorktreeStartupPreparationInstrumentation.currentRecorder?
                    .increment(.prefixCacheInvalidations)
            #endif
        }
    }

    private func takePendingUncachedPrefixControlFlight(
        _ key: PrefixControlCacheKey,
        flightID: UUID
    ) -> PendingUncachedPrefixControlFlight? {
        guard let pending = pendingUncachedPrefixControlFlights[key],
              pending.id == flightID
        else { return nil }
        pendingUncachedPrefixControlFlights.removeValue(forKey: key)
        pendingUncachedPrefixControlResidentBytes = max(
            0,
            pendingUncachedPrefixControlResidentBytes - pending.reservedResidentBytes
        )
        pendingUncachedPrefixControlArtifactBytes = pendingUncachedPrefixControlArtifactBytes >= pending.reservedArtifactBytes
            ? pendingUncachedPrefixControlArtifactBytes - pending.reservedArtifactBytes
            : 0
        return pending
    }

    private func removePrefixControlCacheEntry(
        _ key: PrefixControlCacheKey,
        invalidated: Bool
    ) async {
        guard let removed = prefixControlCacheEntries.removeValue(forKey: key) else { return }
        prefixControlCacheResidentBytes = max(0, prefixControlCacheResidentBytes - removed.residentBytes)
        prefixControlCacheArtifactBytes = prefixControlCacheArtifactBytes >= removed.artifactBytes
            ? prefixControlCacheArtifactBytes - removed.artifactBytes
            : 0
        if invalidated { prefixControlCacheInvalidationCount &+= 1 }
        await metadataMonitor.release(removed.observationToken)
    }

    private func invalidatePrefixControlCache(
        for repositoryKeys: Set<GitWorkspaceAuthorityRepositoryKey>
    ) async {
        let entryKeys = prefixControlCacheEntries.keys.filter {
            repositoryKeys.contains($0.repositoryKey)
        }
        for key in entryKeys {
            await removePrefixControlCacheEntry(key, invalidated: true)
        }
        let pendingKeys = pendingPrefixControlAdmissions.keys.filter {
            repositoryKeys.contains($0.repositoryKey)
        }
        for key in pendingKeys {
            await cancelPendingPrefixControlAdmission(key, invalidated: true)
        }
    }

    private func evictPrefixControlCacheIfNeeded() async {
        while prefixControlCacheEntries.count > prefixControlCacheLimits.maximumEntryCount
            || prefixControlCacheResidentBytes > prefixControlCacheLimits.maximumResidentBytes
            || prefixControlCacheArtifactBytes > prefixControlCacheLimits.maximumArtifactBytes
            || prefixControlRepositoryEntryLimitExceeded()
        {
            let overfullRepositories = Set(
                Dictionary(grouping: prefixControlCacheEntries.keys, by: \.repositoryKey)
                    .filter { $0.value.count > prefixControlCacheLimits.maximumEntriesPerRepository }
                    .map(\.key)
            )
            let candidates = prefixControlCacheEntries.filter {
                overfullRepositories.isEmpty || overfullRepositories.contains($0.key.repositoryKey)
            }
            guard let candidate = candidates.min(by: {
                if $0.value.lastAccessOrdinal != $1.value.lastAccessOrdinal {
                    return $0.value.lastAccessOrdinal < $1.value.lastAccessOrdinal
                }
                return $0.value.id.uuidString < $1.value.id.uuidString
            }) else { break }
            prefixControlCacheEvictionCount &+= 1
            #if DEBUG
                WorktreeStartupPreparationInstrumentation.currentRecorder?
                    .increment(.prefixCacheEvictions)
                WorktreeStartupPreparationInstrumentation.currentRecorder?
                    .recordReason(.capacityEviction)
            #endif
            await removePrefixControlCacheEntry(candidate.key, invalidated: false)
        }
    }

    private func prefixControlRepositoryEntryLimitExceeded() -> Bool {
        Dictionary(grouping: prefixControlCacheEntries.keys, by: \.repositoryKey)
            .values
            .contains { $0.count > prefixControlCacheLimits.maximumEntriesPerRepository }
    }

    private nonisolated static let maximumPrefixControlFooterResidentBytes = 512
    private nonisolated static let maximumPrefixControlEvidenceResidentBytes = 8 * 1024
    private nonisolated static let maximumPendingUncachedPrefixControlFlightCount = 1
    private nonisolated static let maximumPendingUncachedPrefixControlResidentBytes =
        maximumPrefixControlEvidenceResidentBytes
    private nonisolated static let maximumPendingUncachedPrefixControlArtifactBytes: UInt64 = 0

    private nonisolated static func prefixControlFooterResidentBytes(
        _ footer: GitPrefixControlEvidenceManifestFooter
    ) -> Int {
        MemoryLayout<GitPrefixControlEvidenceManifestFooter>.stride
            + footer.ignoreControlDigest.count
            + footer.attributeControlDigest.count
            + footer.artifactDigest.count
    }

    private nonisolated static func prefixControlFooterIsValid(
        _ footer: GitPrefixControlEvidenceManifestFooter
    ) -> Bool {
        guard footer.ignoreControlDigest.count == 32,
              footer.attributeControlDigest.count == 32,
              footer.artifactDigest.count == 32,
              prefixControlFooterResidentBytes(footer) <= maximumPrefixControlFooterResidentBytes
        else { return false }
        let (_, recordOverflow) = footer.recordPayloadByteCount.addingReportingOverflow(footer.recordCount)
        let (_, pathOverflow) = footer.pathPayloadByteCount.addingReportingOverflow(footer.recordCount)
        return !recordOverflow && !pathOverflow
    }

    private nonisolated static func prefixControlEvidenceResidentBytes(
        _ evidence: GitPrefixControlCollectedEvidence
    ) -> Int {
        let footerBytes = prefixControlFooterResidentBytes(evidence.footer)
        guard let detail = evidence.collectionDetail else { return footerBytes }
        return footerBytes + MemoryLayout<GitPrefixControlCollectionDetail>.stride
            + detail.prunedRootSummarySHA256.utf8.count
    }

    private nonisolated static func prefixControlEvidenceIsValid(
        _ evidence: GitPrefixControlCollectedEvidence
    ) -> Bool {
        guard prefixControlFooterIsValid(evidence.footer),
              prefixControlEvidenceResidentBytes(evidence) <= maximumPrefixControlEvidenceResidentBytes
        else { return false }
        guard let detail = evidence.collectionDetail else { return true }
        guard detail.collectionCompleted,
              detail.ignoreControlCount >= 0,
              detail.attributeControlCount >= 0,
              detail.prunedRootCount >= 0,
              detail.prunedRootSummarySHA256.utf8.count == 64,
              detail.prunedRootSummarySHA256.utf8.allSatisfy({ byte in
                  (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
                      || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
              })
        else { return false }
        let expectedRecordCount = detail.ignoreControlCount.addingReportingOverflow(
            detail.attributeControlCount
        )
        return !expectedRecordCount.overflow
            && UInt64(exactly: expectedRecordCount.partialValue) == evidence.footer.recordCount
    }

    private nonisolated static func prefixControlRootIdentity(
        for root: URL
    ) throws -> PrefixControlRootIdentity {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalRoot.isFileURL,
              canonicalRoot.path.hasPrefix("/"),
              !canonicalRoot.path.contains("\0")
        else { throw GitPrefixControlEvidenceCacheError.rootIdentityChanged }
        var value = stat()
        guard lstat(canonicalRoot.path, &value) == 0,
              value.st_mode & S_IFMT == S_IFDIR
        else { throw GitPrefixControlEvidenceCacheError.rootIdentityChanged }
        return PrefixControlRootIdentity(
            canonicalPath: canonicalRoot.path,
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino)
        )
    }

    #if DEBUG
        func snapshotForTesting() -> Snapshot {
            Snapshot(
                recordCount: records.count,
                publishedScopeCount: records.values.reduce(0) { $0 + $1.snapshotsByScope.count },
                activeMutationCount: activeMutations.count,
                metadataEventCount: records.values.reduce(0) { $0 + $1.metadataEventCount },
                authorityGenerations: records.mapValues(\.invalidationGeneration),
                reusableSnapshotCount: reusableSnapshotsByIdentity.count,
                reusableSnapshotAliasCount: reusableSnapshotAliasesByScope.count,
                reusableSnapshotEstimatedBytes: reusableSnapshotEstimatedBytes,
                reusableSnapshotArtifactBytes: reusableSnapshotArtifactBytes,
                pendingReusableSnapshotAdmissionCount: pendingReusableSnapshotAdmissions.count,
                pendingReusableSnapshotArtifactBytes: pendingReusableSnapshotArtifactBytes,
                reusableSnapshotArtifactBudgetRejectionCount: reusableSnapshotArtifactBudgetRejectionCount,
                invalidationSubscriberCount: invalidationContinuations.count,
                prefixControlCacheEntryCount: prefixControlCacheEntries.count,
                prefixControlCacheResidentBytes: prefixControlCacheResidentBytes,
                prefixControlCacheArtifactBytes: prefixControlCacheArtifactBytes,
                pendingPrefixControlAdmissionCount: pendingPrefixControlAdmissions.count
                    + pendingUncachedPrefixControlFlights.count,
                pendingPrefixControlResidentBytes: pendingPrefixControlResidentBytes
                    + pendingUncachedPrefixControlResidentBytes,
                pendingPrefixControlArtifactBytes: pendingPrefixControlArtifactBytes
                    + pendingUncachedPrefixControlArtifactBytes,
                prefixControlCacheHitCount: prefixControlCacheHitCount,
                prefixControlCacheMissCount: prefixControlCacheMissCount,
                prefixControlCacheCoalescedWaiterCount: prefixControlCacheCoalescedWaiterCount,
                prefixControlCacheAdmissionCount: prefixControlCacheAdmissionCount,
                prefixControlCacheEvictionCount: prefixControlCacheEvictionCount,
                prefixControlCacheInvalidationCount: prefixControlCacheInvalidationCount,
                prefixControlCacheBypassCount: prefixControlCacheBypassCount,
                prefixControlPhysicalScanCount: prefixControlPhysicalScanCount
            )
        }

        func metadataMonitorForTesting() -> GitWorkspaceMetadataMonitor {
            metadataMonitor
        }
    #endif

    private func hasActiveMutation(
        for repositoryKey: GitWorkspaceAuthorityRepositoryKey
    ) -> Bool {
        activeMutations.values.contains { token in
            token.affectedRepositoryKeys.contains(where: {
                Self.sameCommonDirectory($0, repositoryKey)
            })
        }
    }

    private func emitInvalidation(
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        record: Record,
        kind: GitWorkspaceAuthorityInvalidationKind
    ) {
        let event = GitWorkspaceAuthorityInvalidationEvent(
            repositoryKey: repositoryKey,
            invalidationGeneration: record.invalidationGeneration,
            acceptedMetadataWatermark: metadataMonitor.acceptedWatermark(for: repositoryKey),
            kind: kind
        )
        for continuation in invalidationContinuations.values {
            continuation.yield(event)
        }
    }

    private func updateSynchronousState(
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        record: Record
    ) {
        synchronousState.update(
            repositoryKey: repositoryKey,
            invalidationGeneration: record.invalidationGeneration,
            mutationDepth: record.mutationDepth,
            monitorCoverageUnavailable: record.monitorCoverageUnavailable,
            publicationGenerations: record.publicationGenerationByScope
        )
    }

    private func removeInvalidationContinuation(_ id: UUID) {
        invalidationContinuations.removeValue(forKey: id)
    }

    private nonisolated static func sameCommonDirectory(
        _ lhs: GitWorkspaceAuthorityRepositoryKey,
        _ rhs: GitWorkspaceAuthorityRepositoryKey
    ) -> Bool {
        lhs.standardizedCommonDirectoryPath == rhs.standardizedCommonDirectoryPath
            && lhs.commonDirectoryDevice == rhs.commonDirectoryDevice
            && lhs.commonDirectoryInode == rhs.commonDirectoryInode
    }

    private nonisolated static func metadataPaths(for layout: GitRepositoryLayout) -> [URL] {
        [
            layout.dotGitPath,
            layout.gitDir.appendingPathComponent("HEAD"),
            layout.gitDir.appendingPathComponent("index"),
            layout.gitDir.appendingPathComponent("config.worktree"),
            layout.gitDir.appendingPathComponent("info/sparse-checkout"),
            layout.commonDir.appendingPathComponent("HEAD"),
            layout.commonDir.appendingPathComponent("packed-refs"),
            layout.commonDir.appendingPathComponent("refs", isDirectory: true),
            layout.commonDir.appendingPathComponent("config"),
            layout.commonDir.appendingPathComponent("info/exclude"),
            layout.commonDir.appendingPathComponent("info/attributes")
        ]
    }
}
