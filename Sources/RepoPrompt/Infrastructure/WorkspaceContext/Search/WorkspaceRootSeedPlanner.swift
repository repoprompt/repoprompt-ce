import CryptoKit
import Foundation

enum WorkspaceRootSeedServingPlanningOutcome {
    case planned(
        handle: WorkspaceRootTargetSeedPlanHandle,
        authorityClaim: WorkspaceRootSeedServingAuthorityClaim
    )
    case fallback(WorkspaceRootSeedFallbackReason)
}

/// A non-owning view of the flight's shared authority fence. Retaining this
/// claim keeps the coordinator-owned fence alive; releasing one claim never
/// releases the fence while another compatible waiter still has a claim.
final class WorkspaceRootSeedServingAuthorityClaim: @unchecked Sendable {
    private let evidenceClaim: WorkspaceRootTargetEvidenceClaim

    fileprivate init(evidenceClaim: WorkspaceRootTargetEvidenceClaim) {
        self.evidenceClaim = evidenceClaim
    }

    func authorityFence() async -> GitWorkspacePendingInitializationAuthorityFence? {
        guard let shared = evidenceClaim.handle(as: WorkspaceRootSeedServingFlightHandle.self) else {
            return nil
        }
        return await shared.authorityResource.currentFence()
    }

    func recapturePublishedAuthorityFence(
        replacing fence: GitWorkspacePendingInitializationAuthorityFence
    ) async throws -> GitWorkspacePendingInitializationAuthorityFence {
        guard let shared = evidenceClaim.handle(as: WorkspaceRootSeedServingFlightHandle.self) else {
            throw GitWorkspaceAuthorityUnavailableReason.superseded
        }
        return try await shared.authorityResource.recapturePublishedFence(replacing: fence)
    }

    func validatePendingAuthorityFence(
        replacing fence: GitWorkspacePendingInitializationAuthorityFence
    ) async throws -> GitWorkspacePendingInitializationAuthorityFence {
        guard let shared = evidenceClaim.handle(as: WorkspaceRootSeedServingFlightHandle.self) else {
            throw GitWorkspaceAuthorityUnavailableReason.superseded
        }
        return try await shared.authorityResource.validatePendingFence(replacing: fence)
    }

    func release() async {
        await evidenceClaim.release()
    }
}

private final class WorkspaceRootSeedServingFlightHandle: WorkspaceRootTargetEvidenceHandle,
    @unchecked Sendable
{
    let planHandle: WorkspaceRootTargetSeedPlanHandle
    let authorityResource: WorkspaceRootSeedAuthorityFenceResource

    init(
        planHandle: WorkspaceRootTargetSeedPlanHandle,
        authorityResource: WorkspaceRootSeedAuthorityFenceResource
    ) {
        self.planHandle = planHandle
        self.authorityResource = authorityResource
    }
}

/// The coordinator is the sole owner of the operational authority lease. All
/// serving claims observe this owner, which coalesces publication transitions
/// and releases the current fence only after the final claim is gone.
private actor WorkspaceRootSeedAuthorityFenceResource:
    WorkspaceRootTargetEvidenceAttemptResource,
    Sendable
{
    private struct Transition {
        let id: UUID
        let replacing: GitWorkspacePendingInitializationAuthorityFence
        let task: Task<GitWorkspacePendingInitializationAuthorityFence, any Error>
    }

    nonisolated let initialFence: GitWorkspacePendingInitializationAuthorityFence
    private let gitService: GitService
    private let authority: GitWorkspaceStateAuthority
    private var fence: GitWorkspacePendingInitializationAuthorityFence?
    private var transition: Transition?
    private var isReleased = false

    init(
        fence: GitWorkspacePendingInitializationAuthorityFence,
        gitService: GitService,
        authority: GitWorkspaceStateAuthority
    ) {
        initialFence = fence
        self.fence = fence
        self.gitService = gitService
        self.authority = authority
    }

    func currentFence() -> GitWorkspacePendingInitializationAuthorityFence? {
        guard !isReleased else { return nil }
        return fence
    }

    func recapturePublishedFence(
        replacing expected: GitWorkspacePendingInitializationAuthorityFence
    ) async throws -> GitWorkspacePendingInitializationAuthorityFence {
        try await validatedCurrentFence(observedBy: expected)
    }

    func validatePendingFence(
        replacing expected: GitWorkspacePendingInitializationAuthorityFence
    ) async throws -> GitWorkspacePendingInitializationAuthorityFence {
        try await validatedCurrentFence(observedBy: expected)
    }

    /// A lagging claim may have observed an older fence than the resource now
    /// owns. Never hand that claim the newer fence until the newer fence itself
    /// has been proved current. One joined or newly-created transition exhausts
    /// this call's recapture budget; instability after that fails closed.
    private func validatedCurrentFence(
        observedBy _: GitWorkspacePendingInitializationAuthorityFence
    ) async throws -> GitWorkspacePendingInitializationAuthorityFence {
        var didUseRecapture = false
        while true {
            guard !isReleased, let current = fence else {
                throw GitWorkspaceAuthorityUnavailableReason.superseded
            }
            if let transition {
                guard !didUseRecapture else {
                    throw GitWorkspaceAuthorityUnavailableReason.superseded
                }
                _ = try await finishTransition(transition)
                didUseRecapture = true
                continue
            }

            let decision = await authority.pendingInitializationFenceDecision(current)
            guard !isReleased, fence == current, transition == nil else {
                continue
            }
            switch decision {
            case .current:
                return current
            case .fallback:
                throw GitWorkspaceAuthorityUnavailableReason.superseded
            case .revalidationRequired:
                guard !didUseRecapture else {
                    throw GitWorkspaceAuthorityUnavailableReason.superseded
                }
                _ = try await transitionFence(replacing: current)
                didUseRecapture = true
            }
        }
    }

    private func transitionFence(
        replacing expected: GitWorkspacePendingInitializationAuthorityFence
    ) async throws -> GitWorkspacePendingInitializationAuthorityFence {
        guard !isReleased, let current = fence else {
            throw GitWorkspaceAuthorityUnavailableReason.superseded
        }
        if current != expected {
            return current
        }
        let observed: Transition
        if let transition {
            observed = transition
        } else {
            let task = Task { [gitService] in
                try await gitService.recapturePublishedInitializationAuthorityFence(
                    replacing: expected
                )
            }
            observed = Transition(id: UUID(), replacing: expected, task: task)
            transition = observed
        }
        return try await finishTransition(observed)
    }

    private func finishTransition(
        _ observed: Transition
    ) async throws -> GitWorkspacePendingInitializationAuthorityFence {
        let replacement: GitWorkspacePendingInitializationAuthorityFence
        do {
            replacement = try await observed.task.value
        } catch {
            if transition?.id == observed.id {
                transition = nil
            }
            throw error
        }
        guard !isReleased else {
            throw GitWorkspaceAuthorityUnavailableReason.superseded
        }
        guard transition?.id == observed.id else {
            guard let current = fence else {
                throw GitWorkspaceAuthorityUnavailableReason.superseded
            }
            return current
        }
        guard fence == observed.replacing else {
            transition = nil
            await gitService.releasePendingInitializationAuthorityFence(replacement)
            guard let current = fence else {
                throw GitWorkspaceAuthorityUnavailableReason.superseded
            }
            return current
        }
        let replaced = fence
        fence = replacement
        transition = nil
        if let replaced, replaced != replacement {
            await gitService.releasePendingInitializationAuthorityFence(replaced)
        }
        return replacement
    }

    func release() async {
        guard !isReleased else { return }
        isReleased = true
        let pendingTransition = transition
        transition = nil
        let retainedFence = fence
        fence = nil
        pendingTransition?.task.cancel()
        var replacement: GitWorkspacePendingInitializationAuthorityFence?
        if let pendingTransition {
            replacement = try? await pendingTransition.task.value
        }
        if let retainedFence {
            await gitService.releasePendingInitializationAuthorityFence(retainedFence)
        }
        if let replacement, replacement != retainedFence {
            await gitService.releasePendingInitializationAuthorityFence(replacement)
        }
    }
}

actor WorkspaceRootSeedPlanner {
    static let shared = WorkspaceRootSeedPlanner()

    private enum PlanningFailure: Error {
        case fallback(WorkspaceRootSeedFallbackReason)
    }

    private enum UncoalescedPlanningOutcome {
        case planned(
            handle: WorkspaceRootTargetSeedPlanHandle,
            authorityResource: WorkspaceRootSeedAuthorityFenceResource
        )
        case authorityInvalidated(expectedAuthoritySnapshotIdentity: Data)
        case fallback(WorkspaceRootSeedFallbackReason)
    }

    private struct BaseValue {
        let entry: RootNeutralTreeInventoryEntry
        let path: Data
    }

    private struct DeltaValue {
        let record: GitTargetTreeDeltaEvidenceRecord
        let path: Data
    }

    private struct IndexValue {
        let record: GitTargetIndexEvidenceRecord
        let path: Data
    }

    private struct StatusValue {
        let record: GitTargetStatusEvidenceRecord
        let path: Data
        let sourcePath: Data?
    }

    private struct TargetTreeValue {
        let mode: Data
        let objectID: Data
    }

    private let gitService: GitService
    private let authority: GitWorkspaceStateAuthority
    private let flightCoordinator: WorkspaceRootTargetEvidenceCoordinator
    private let namespaceResourcePolicy: WorkspaceRootNamespaceManifestResourcePolicy
    private let evidenceResourcePolicy: GitTargetEvidenceResourcePolicy
    private let planResourcePolicy: WorkspaceRootTargetSeedPlanResourcePolicy

    init(
        gitService: GitService = GitService(),
        authority: GitWorkspaceStateAuthority = .shared,
        flightCoordinator: WorkspaceRootTargetEvidenceCoordinator = .shared,
        namespaceResourcePolicy: WorkspaceRootNamespaceManifestResourcePolicy = .default,
        evidenceResourcePolicy: GitTargetEvidenceResourcePolicy = .default,
        planResourcePolicy: WorkspaceRootTargetSeedPlanResourcePolicy = .default
    ) {
        self.gitService = gitService
        self.authority = authority
        self.flightCoordinator = flightCoordinator
        self.namespaceResourcePolicy = namespaceResourcePolicy
        self.evidenceResourcePolicy = evidenceResourcePolicy
        self.planResourcePolicy = planResourcePolicy
    }

    func plan(
        hint: WorkspaceRootMaterializationHint,
        service: FileSystemService
    ) async -> WorkspaceRootSeedPlannerOutcome {
        let result = await planForServing(hint: hint, service: service)
        switch result {
        case let .fallback(reason):
            return .fallback(reason)
        case let .planned(handle, authorityClaim):
            await authorityClaim.release()
            return .planned(handle)
        }
    }

    func planForServing(
        hint: WorkspaceRootMaterializationHint,
        service: FileSystemService
    ) async -> WorkspaceRootSeedServingPlanningOutcome {
        if let reason = hint.validationFallbackReason ?? hint.creationReceipt.fallbackReason() {
            return .fallback(reason)
        }
        do {
            let key = try await flightKey(hint: hint, service: service)
            let claim = try await flightCoordinator.claim(for: key) { [self] _, context in
                switch await uncoalescedPlanningResult(
                    hint: hint,
                    service: service,
                    attemptContext: context
                ) {
                case let .fallback(reason):
                    throw PlanningFailure.fallback(reason)
                case let .planned(handle, authorityResource):
                    return .sealed(
                        handle: WorkspaceRootSeedServingFlightHandle(
                            planHandle: handle,
                            authorityResource: authorityResource
                        ),
                        authoritySnapshotIdentity: Self.authoritySnapshotIdentity(
                            authorityResource.initialFence.snapshot
                        )
                    )
                case let .authorityInvalidated(expectedAuthoritySnapshotIdentity):
                    return .authorityInvalidated(
                        originalAuthoritySnapshotIdentity: expectedAuthoritySnapshotIdentity,
                        replacementAuthoritySnapshotIdentity: expectedAuthoritySnapshotIdentity
                    )
                }
            }
            guard let shared = claim.handle(as: WorkspaceRootSeedServingFlightHandle.self) else {
                await claim.release()
                return .fallback(.targetEvidenceIncoherent)
            }
            return .planned(
                handle: shared.planHandle,
                authorityClaim: WorkspaceRootSeedServingAuthorityClaim(evidenceClaim: claim)
            )
        } catch {
            return .fallback(Self.fallbackReason(for: error))
        }
    }

    private func uncoalescedPlanningResult(
        hint: WorkspaceRootMaterializationHint,
        service: FileSystemService,
        attemptContext: WorkspaceRootTargetEvidenceAttemptContext
    ) async -> UncoalescedPlanningOutcome {
        if let reason = hint.validationFallbackReason ?? hint.creationReceipt.fallbackReason() {
            return .fallback(reason)
        }
        guard let snapshot = await authority.reusableSnapshot(
            identity: hint.creationReceipt.parentSnapshotIdentity,
            expectedCompatibilityKey: hint.creationReceipt.parentCompatibilityKey
        ) else { return .fallback(.baseEvicted) }

        do {
            let fence = try await gitService.pendingInitializationAuthorityFence(
                layout: hint.creationReceipt.targetLayout,
                prefix: hint.creationReceipt.repositoryRelativeRootPrefix
            )
            let authorityResource = WorkspaceRootSeedAuthorityFenceResource(
                fence: fence,
                gitService: gitService,
                authority: authority
            )
            do {
                try await attemptContext.retainResource(authorityResource)
            } catch {
                throw CancellationError()
            }

            try Task.checkCancellation()
            let identity = Self.authoritySnapshotIdentity(fence.snapshot)
            if let required = attemptContext.requiredAuthoritySnapshotIdentity,
               required != identity
            {
                throw WorkspaceRootTargetEvidenceCoordinatorError.authoritySnapshotChanged
            }
            let compatibility = WorkspaceRootSeedCompatibilityKey(authority: fence.snapshot)
            let compatibilityEvaluation = compatibility.deltaCompatibilityEvaluation(
                with: snapshot.compatibilityKey,
                source: .planner
            )
            let catalogPolicyComparisonReached = compatibilityEvaluation.decision == .compatible
            let catalogPolicyMatched = catalogPolicyComparisonReached
                ? await service.currentWorkspaceRootCatalogPolicyIdentity() == snapshot.catalogPolicyIdentity
                : nil
            let compatibilityFallback: WorkspaceRootSeedFallbackReason? =
                compatibilityEvaluation.decision == .compatible && catalogPolicyMatched == true
                    ? nil
                    : .compatibilityMismatch
            #if DEBUG
                WorktreeStartupInstrumentation.recordDeltaCompatibilityEvaluation(
                    correlationID: hint.correlationID,
                    evaluation: compatibilityEvaluation,
                    policyCanonicalizationComparison: GitWorkspacePolicyCanonicalizationDiagnostics.comparison(
                        base: snapshot.compatibilityKey.policyIdentity,
                        target: hint.creationReceipt.targetAuthorityAfter.policyIdentity
                    ),
                    exactSnapshotLookupReached: true,
                    exactSnapshotLookupPassed: true,
                    targetAuthorityComparisonReached: true,
                    targetAuthorityComparisonPassed: true,
                    currentSearchABIReached: false,
                    currentSearchABIMatched: nil,
                    catalogPolicyComparisonReached: catalogPolicyComparisonReached,
                    catalogPolicyMatched: catalogPolicyMatched,
                    terminalFallback: compatibilityFallback
                )
            #endif
            guard compatibilityFallback == nil else {
                throw PlanningFailure.fallback(.compatibilityMismatch)
            }

            let handle = try await buildAttempt(
                hint: hint,
                snapshot: snapshot,
                fence: fence,
                service: service
            )
            switch await authority.pendingInitializationFenceDecision(fence) {
            case .current:
                return .planned(handle: handle, authorityResource: authorityResource)
            case .revalidationRequired:
                return .authorityInvalidated(expectedAuthoritySnapshotIdentity: identity)
            case .fallback:
                throw PlanningFailure.fallback(.authorityUnstable)
            }
        } catch {
            return .fallback(Self.fallbackReason(for: error))
        }
    }

    private func buildAttempt(
        hint: WorkspaceRootMaterializationHint,
        snapshot: WorkspaceRootReusableSnapshot,
        fence: GitWorkspacePendingInitializationAuthorityFence,
        service: FileSystemService
    ) async throws -> WorkspaceRootTargetSeedPlanHandle {
        let receipt = hint.creationReceipt
        let namespaceStore = try WorkspaceRootNamespaceManifestStore()
        let evidenceStore = try GitTargetEvidenceManifestStore()
        let planStore = try WorkspaceRootTargetSeedPlanManifestStore()
        let attemptID = UUID()
        let provenance = Self.creationCutProvenance(receipt)

        #if DEBUG
            let benchmarkMetricTag = WorktreeStartupInstrumentation.currentBenchmarkMetricTag
            var benchmarkPhaseStarted = DispatchTime.now().uptimeNanoseconds
        #endif
        let namespace = try await service.workspaceRootNamespaceManifest(
            in: namespaceStore,
            resourcePolicy: namespaceResourcePolicy
        )
        #if DEBUG
            var benchmarkPhaseFinished = DispatchTime.now().uptimeNanoseconds
            WorktreeStartupInstrumentation.recordBenchmarkPlannerPhase(
                tag: benchmarkMetricTag,
                phase: .targetNamespace,
                durationMicroseconds: (benchmarkPhaseFinished - benchmarkPhaseStarted) / 1000,
                itemCount: Int(clamping: namespace.footer.recordCount)
            )
        #endif
        let expectedNamespaceRoot = try WorkspaceRootNamespaceRootIdentity(
            rootURL: URL(fileURLWithPath: hint.standardizedTargetPath, isDirectory: true)
        )
        guard namespace.header.identity.catalogPolicy == snapshot.catalogPolicyIdentity,
              namespace.header.identity.root == expectedNamespaceRoot
        else { throw PlanningFailure.fallback(.changedIgnoreAuthority) }

        #if DEBUG
            benchmarkPhaseStarted = DispatchTime.now().uptimeNanoseconds
        #endif
        let tree = try await gitService.writeTreeDeltaEvidence(
            baseTreeOID: snapshot.compatibilityKey.treeOID,
            in: receipt.targetLayout,
            prefix: receipt.repositoryRelativeRootPrefix,
            authorityFence: fence,
            attemptID: attemptID,
            suppliedCreationCutProvenanceBytes: provenance,
            store: evidenceStore,
            evidenceResourcePolicy: evidenceResourcePolicy
        )
        #if DEBUG
            benchmarkPhaseFinished = DispatchTime.now().uptimeNanoseconds
            WorktreeStartupInstrumentation.recordBenchmarkPlannerPhase(
                tag: benchmarkMetricTag,
                phase: .treeEvidence,
                durationMicroseconds: (benchmarkPhaseFinished - benchmarkPhaseStarted) / 1000,
                itemCount: Int(clamping: tree.footer.recordCount)
            )
            benchmarkPhaseStarted = DispatchTime.now().uptimeNanoseconds
        #endif
        let index = try await gitService.writeIndexEvidence(
            in: receipt.targetLayout,
            prefix: receipt.repositoryRelativeRootPrefix,
            authorityFence: fence,
            attemptID: attemptID,
            suppliedCreationCutProvenanceBytes: provenance,
            store: evidenceStore,
            evidenceResourcePolicy: evidenceResourcePolicy
        )
        #if DEBUG
            benchmarkPhaseFinished = DispatchTime.now().uptimeNanoseconds
            WorktreeStartupInstrumentation.recordBenchmarkPlannerPhase(
                tag: benchmarkMetricTag,
                phase: .indexEvidence,
                durationMicroseconds: (benchmarkPhaseFinished - benchmarkPhaseStarted) / 1000,
                itemCount: Int(clamping: index.footer.recordCount)
            )
            benchmarkPhaseStarted = DispatchTime.now().uptimeNanoseconds
        #endif
        let status = try await gitService.writeStatusEvidence(
            in: receipt.targetLayout,
            prefix: receipt.repositoryRelativeRootPrefix,
            authorityFence: fence,
            attemptID: attemptID,
            suppliedCreationCutProvenanceBytes: provenance,
            store: evidenceStore,
            evidenceResourcePolicy: evidenceResourcePolicy
        )
        #if DEBUG
            benchmarkPhaseFinished = DispatchTime.now().uptimeNanoseconds
            WorktreeStartupInstrumentation.recordBenchmarkPlannerPhase(
                tag: benchmarkMetricTag,
                phase: .statusEvidence,
                durationMicroseconds: (benchmarkPhaseFinished - benchmarkPhaseStarted) / 1000,
                itemCount: Int(clamping: status.footer.recordCount)
            )
        #endif
        let evidence = try GitTargetEvidenceBundleLease(treeDelta: tree, index: index, status: status)
        #if DEBUG
            benchmarkPhaseStarted = DispatchTime.now().uptimeNanoseconds
        #endif
        let plan = try await Self.reconcile(
            snapshot: snapshot,
            targetTreeOID: fence.snapshot.treeOID,
            prefix: receipt.repositoryRelativeRootPrefix,
            namespace: namespace,
            evidence: evidence,
            planStore: planStore,
            resourcePolicy: planResourcePolicy
        )
        #if DEBUG
            benchmarkPhaseFinished = DispatchTime.now().uptimeNanoseconds
            WorktreeStartupInstrumentation.recordBenchmarkPlannerPhase(
                tag: benchmarkMetricTag,
                phase: .reconcile,
                durationMicroseconds: (benchmarkPhaseFinished - benchmarkPhaseStarted) / 1000,
                itemCount: Int(clamping: plan.footer.recordCount)
            )
        #endif
        return try WorkspaceRootTargetSeedPlanHandle(
            snapshot: snapshot,
            namespaceManifest: namespace,
            gitEvidence: evidence,
            planManifest: plan
        )
    }

    /// Performs one byte-exact streaming merge. At most one record from each
    /// source plus a fixed-size output batch is resident; the reusable base is
    /// already process-shared and is never copied into target-local storage.
    static func reconcile(
        snapshot: WorkspaceRootReusableSnapshot,
        targetTreeOID: GitObjectID,
        prefix: GitRepositoryRelativeRootPrefix,
        namespace: WorkspaceRootNamespaceManifestLease,
        evidence: GitTargetEvidenceBundleLease,
        planStore: WorkspaceRootTargetSeedPlanManifestStore,
        resourcePolicy: WorkspaceRootTargetSeedPlanResourcePolicy = .default
    ) async throws -> WorkspaceRootTargetSeedPlanManifestLease {
        guard snapshot.compatibilityKey.repositoryRelativeRootPrefix == prefix,
              snapshot.compatibilityKey.objectFormat == targetTreeOID.objectFormat,
              evidence.index.header.identity.sparseCheckoutEnabled == false,
              evidence.treeDelta.header.identity.targetObjectIDBytes == Data(targetTreeOID.lowercaseHex.utf8),
              evidence.treeDelta.header.identity.baseObjectIDBytes == Data(snapshot.compatibilityKey.treeOID.lowercaseHex.utf8),
              evidence.treeDelta.header.identity.repositoryRelativeRootPrefixBytes == Data(prefix.value.utf8)
        else { throw PlanningFailure.fallback(.compatibilityMismatch) }

        let treeReader = try evidence.makeTreeDeltaReader()
        let indexReader = try evidence.makeIndexReader()
        let statusReader = try evidence.makeStatusReader()
        let namespaceReader = try namespace.makeReader()
        let baseReader = try snapshot.inventoryManifest.makeReader()
        let header = WorkspaceRootTargetSeedPlanManifestHeader(
            snapshotIdentityBytes: Data(snapshot.identity.sha256.utf8),
            targetTreeOIDBytes: Data(targetTreeOID.lowercaseHex.utf8),
            objectFormatBytes: Data(targetTreeOID.objectFormat.rawValue.utf8),
            repositoryRelativeRootPrefixBytes: Data(prefix.value.utf8),
            namespaceIdentity: namespace.header.identity,
            namespaceDigest: namespace.digest,
            treeDeltaDigest: evidence.treeDelta.digest,
            indexDigest: evidence.index.digest,
            statusDigest: evidence.status.digest,
            authorityIdentity: evidence.treeDelta.header.identity.authority,
            suppliedCreationCutProvenanceBytes: evidence.treeDelta.header.identity.suppliedCreationCutProvenanceBytes
        )
        let writer = try planStore.makeWriter(header: header, resourcePolicy: resourcePolicy)

        var base: BaseValue? = try nextBase(baseReader)
        var delta = try nextDelta(treeReader, prefix: prefix)
        var index = try nextIndex(indexReader, prefix: prefix)
        var status = try nextStatus(statusReader, prefix: prefix)
        var namespaceRecord = try namespaceReader.next()
        var outputBatch: [WorkspaceRootTargetSeedPlanRecord] = []
        outputBatch.reserveCapacity(256)

        do {
            while let path = minimumPath([
                base?.path,
                delta?.path,
                index?.path,
                status?.path,
                namespaceRecord?.relativePathBytes
            ]) {
                try Task.checkCancellation()
                let baseAtPath = base?.path == path ? base : nil
                let deltaAtPath = delta?.path == path ? delta : nil
                let indexAtPath = index?.path == path ? index : nil
                let statusAtPath = status?.path == path ? status : nil
                let namespaceAtPath = namespaceRecord?.relativePathBytes == path ? namespaceRecord : nil

                if let baseAtPath {
                    try validateBaseEntry(baseAtPath.entry)
                }
                let targetTree = try targetTreeValue(base: baseAtPath, delta: deltaAtPath)
                try validateIndex(indexAtPath, targetTree: targetTree)
                try validateStatus(statusAtPath)
                let record = try planRecord(
                    path: path,
                    base: baseAtPath,
                    targetTree: targetTree,
                    index: indexAtPath,
                    status: statusAtPath,
                    namespace: namespaceAtPath
                )
                if let record {
                    outputBatch.append(record)
                    if outputBatch.count == 256 {
                        try await writer.append(contentsOf: outputBatch)
                        outputBatch.removeAll(keepingCapacity: true)
                    }
                }

                if baseAtPath != nil {
                    base = try nextBase(baseReader)
                }
                if deltaAtPath != nil { delta = try nextDelta(treeReader, prefix: prefix) }
                if indexAtPath != nil { index = try nextIndex(indexReader, prefix: prefix) }
                if statusAtPath != nil { status = try nextStatus(statusReader, prefix: prefix) }
                if namespaceAtPath != nil { namespaceRecord = try namespaceReader.next() }
            }

            guard baseReader.validationState == .verified,
                  treeReader.validationState == .verified,
                  indexReader.validationState == .verified,
                  statusReader.validationState == .verified,
                  namespaceReader.validationState == .verified
            else { throw PlanningFailure.fallback(.compatibilityMismatch) }
            if !outputBatch.isEmpty {
                try await writer.append(contentsOf: outputBatch)
            }
            return try await writer.finish()
        } catch {
            await writer.cancel()
            throw error
        }
    }

    private static func planRecord(
        path: Data,
        base: BaseValue?,
        targetTree: TargetTreeValue?,
        index: IndexValue?,
        status: StatusValue?,
        namespace: WorkspaceRootNamespaceRecord?
    ) throws -> WorkspaceRootTargetSeedPlanRecord? {
        let searchableBase = base?.entry.isSearchableFile == true ? base : nil
        let baseOrdinal = searchableBase.flatMap { UInt64(exactly: $0.entry.ordinal) }
        if searchableBase != nil, baseOrdinal == nil {
            throw PlanningFailure.fallback(.compatibilityMismatch)
        }

        if let namespace {
            guard !pathContainsRepositoryMetadata(path) else {
                throw PlanningFailure.fallback(.submoduleOrNestedRepository)
            }
            guard !namespace.isSymbolicLink,
                  namespace.fileSystemMode & UInt16(S_IFMT) != UInt16(S_IFLNK)
            else { throw PlanningFailure.fallback(.symlinkOrSpecialTopology) }

            switch namespace.kind {
            case .directory:
                guard namespace.fileSystemMode == 0 ||
                    namespace.fileSystemMode & UInt16(S_IFMT) == UInt16(S_IFDIR),
                    index == nil
                else { throw PlanningFailure.fallback(.symlinkOrSpecialTopology) }
                return WorkspaceRootTargetSeedPlanRecord(
                    relativePathBytes: path,
                    disposition: .ordinaryDirectory,
                    baseAction: searchableBase == nil ? .none : .tombstone,
                    fileSystemMode: namespace.fileSystemMode,
                    baseOrdinal: baseOrdinal
                )

            case .file:
                guard namespace.fileSystemMode == 0 ||
                    namespace.fileSystemMode & UInt16(S_IFMT) == UInt16(S_IFREG)
                else { throw PlanningFailure.fallback(.symlinkOrSpecialTopology) }
                if status?.record.kind == .ignored {
                    throw PlanningFailure.fallback(.changedIgnoreAuthority)
                }
                if status?.record.workTreeStatus == UInt8(ascii: "D") {
                    throw PlanningFailure.fallback(.unexplainedFilesystemEntry)
                }
                if index == nil, status?.record.kind != .untracked {
                    throw PlanningFailure.fallback(.unexplainedFilesystemEntry)
                }
                let reusable = canReuse(
                    base: searchableBase,
                    targetTree: targetTree,
                    index: index,
                    status: status,
                    namespace: namespace
                )
                return WorkspaceRootTargetSeedPlanRecord(
                    relativePathBytes: path,
                    disposition: .ordinaryFile,
                    baseAction: reusable ? .reuse : .overlay,
                    fileSystemMode: namespace.fileSystemMode,
                    baseOrdinal: reusable ? baseOrdinal : nil,
                    targetModeBytes: index?.record.modeBytes,
                    targetObjectIDBytes: index?.record.objectIDBytes
                )
            }
        }

        if let index {
            let deleted = status?.record.workTreeStatus == UInt8(ascii: "D")
            if !deleted {
                // A tracked regular file omitted by the exact ordinary crawler
                // is policy-ignored. Porcelain proves it exists (otherwise D),
                // while the namespace manifest proves it is not publicly visible.
                return WorkspaceRootTargetSeedPlanRecord(
                    relativePathBytes: path,
                    disposition: .policyIgnoredTrackedFile,
                    baseAction: searchableBase == nil ? .none : .tombstone,
                    baseOrdinal: baseOrdinal,
                    targetModeBytes: index.record.modeBytes,
                    targetObjectIDBytes: index.record.objectIDBytes
                )
            }
        }

        if let status {
            switch status.record.kind {
            case .ignored:
                break
            case .untracked:
                if status.record.isDirectoryMarker {
                    // `--untracked-files=all` reports ordinary files directly;
                    // a remaining directory marker is an embedded repository or
                    // another route that needs the ordinary full crawl.
                    throw PlanningFailure.fallback(.submoduleOrNestedRepository)
                }
                throw PlanningFailure.fallback(.unexplainedFilesystemEntry)
            case .ordinary, .renamed, .copied:
                guard status.record.workTreeStatus == UInt8(ascii: "D") else {
                    throw PlanningFailure.fallback(.unexplainedFilesystemEntry)
                }
            case .unmerged:
                throw PlanningFailure.fallback(.conflictOrUnmergedIndex)
            }
        }

        if let searchableBase {
            return WorkspaceRootTargetSeedPlanRecord(
                relativePathBytes: path,
                disposition: .baseTombstone,
                baseAction: .tombstone,
                baseOrdinal: UInt64(searchableBase.entry.ordinal)
            )
        }
        return nil
    }

    private static func canReuse(
        base: BaseValue?,
        targetTree: TargetTreeValue?,
        index: IndexValue?,
        status: StatusValue?,
        namespace: WorkspaceRootNamespaceRecord
    ) -> Bool {
        guard let base, let targetTree, let index,
              Data(base.entry.mode.utf8) == targetTree.mode,
              Data(base.entry.objectID.lowercaseHex.utf8) == targetTree.objectID,
              index.record.modeBytes == targetTree.mode,
              index.record.objectIDBytes == targetTree.objectID,
              status == nil || (
                  status?.record.indexStatus == UInt8(ascii: ".") &&
                      status?.record.workTreeStatus == UInt8(ascii: ".")
              )
        else { return false }
        let expectedExecutable = base.entry.mode == "100755"
        return namespace.fileSystemMode == 0 || namespace.isExecutable == expectedExecutable
    }

    private static func targetTreeValue(
        base: BaseValue?,
        delta: DeltaValue?
    ) throws -> TargetTreeValue? {
        if let delta {
            let record = delta.record
            if record.status == .unmerged {
                throw PlanningFailure.fallback(.conflictOrUnmergedIndex)
            }
            if let oldMode = record.oldModeBytes,
               record.status != .renamed,
               record.status != .copied
            {
                guard let base,
                      Data(base.entry.mode.utf8) == oldMode,
                      record.oldObjectIDBytes == Data(base.entry.objectID.lowercaseHex.utf8)
                else { throw PlanningFailure.fallback(.compatibilityMismatch) }
            }
            switch record.status {
            case .deleted, .renamedSource:
                return nil
            case .added, .modified, .typeChanged, .renamed, .copied:
                guard let mode = record.newModeBytes, let objectID = record.newObjectIDBytes else {
                    throw PlanningFailure.fallback(.gitMalformedOutput)
                }
                try validateSupportedGitMode(mode)
                return TargetTreeValue(mode: mode, objectID: objectID)
            case .unmerged:
                throw PlanningFailure.fallback(.conflictOrUnmergedIndex)
            }
        }
        guard let base else { return nil }
        return TargetTreeValue(
            mode: Data(base.entry.mode.utf8),
            objectID: Data(base.entry.objectID.lowercaseHex.utf8)
        )
    }

    private static func validateBaseEntry(_ entry: RootNeutralTreeInventoryEntry) throws {
        let mode = Data(entry.mode.utf8)
        if mode == Data("160000".utf8) || entry.kind == .commit {
            throw PlanningFailure.fallback(.submoduleOrNestedRepository)
        }
        try validateSupportedGitMode(mode)
    }

    private static func validateIndex(
        _ value: IndexValue?,
        targetTree _: TargetTreeValue?
    ) throws {
        guard let value else { return }
        let record = value.record
        guard record.stage == 0 else { throw PlanningFailure.fallback(.conflictOrUnmergedIndex) }
        guard !record.assumeUnchanged else { throw PlanningFailure.fallback(.assumeUnchangedIndexEntry) }
        guard !record.skipWorktree else { throw PlanningFailure.fallback(.sparseCheckout) }
        try validateSupportedGitMode(record.modeBytes)
    }

    private static func validateStatus(_ value: StatusValue?) throws {
        guard let value else { return }
        let record = value.record
        guard record.kind != .unmerged else { throw PlanningFailure.fallback(.conflictOrUnmergedIndex) }
        if let submodule = record.submoduleStateBytes,
           submodule.first != UInt8(ascii: "N")
        {
            throw PlanningFailure.fallback(.submoduleOrNestedRepository)
        }
        if record.kind == .untracked, record.isDirectoryMarker {
            throw PlanningFailure.fallback(.submoduleOrNestedRepository)
        }
        if let sourcePath = value.sourcePath, pathContainsRepositoryMetadata(sourcePath) {
            throw PlanningFailure.fallback(.submoduleOrNestedRepository)
        }
    }

    private static func validateSupportedGitMode(_ mode: Data) throws {
        switch mode {
        case Data("040000".utf8), Data("100644".utf8), Data("100755".utf8):
            return
        case Data("120000".utf8):
            // The ordinary catalog policy skips symlinks. A tracked symlink is
            // safe only when the exact namespace manifest omits it; planRecord
            // then retains it as an excluded tracked entry and never serves it.
            return
        case Data("160000".utf8):
            throw PlanningFailure.fallback(.submoduleOrNestedRepository)
        default:
            throw PlanningFailure.fallback(.symlinkOrSpecialTopology)
        }
    }

    private static func nextBase(
        _ reader: WorkspaceRootReusableInventoryManifestReader
    ) throws -> BaseValue? {
        guard let entry = try reader.next() else { return nil }
        let path = Data(entry.relativePath.utf8)
        guard !path.isEmpty else { throw PlanningFailure.fallback(.compatibilityMismatch) }
        return BaseValue(entry: entry, path: path)
    }

    private static func nextDelta(
        _ reader: GitTargetTreeDeltaEvidenceReader,
        prefix: GitRepositoryRelativeRootPrefix
    ) throws -> DeltaValue? {
        guard let record = try reader.next() else { return nil }
        guard let path = rootRelative(record.repositoryRelativePathBytes, prefix: prefix) else {
            throw PlanningFailure.fallback(.compatibilityMismatch)
        }
        return DeltaValue(record: record, path: path)
    }

    private static func nextIndex(
        _ reader: GitTargetIndexEvidenceReader,
        prefix: GitRepositoryRelativeRootPrefix
    ) throws -> IndexValue? {
        guard let record = try reader.next() else { return nil }
        guard let path = rootRelative(record.repositoryRelativePathBytes, prefix: prefix) else {
            throw PlanningFailure.fallback(.compatibilityMismatch)
        }
        return IndexValue(record: record, path: path)
    }

    private static func nextStatus(
        _ reader: GitTargetStatusEvidenceReader,
        prefix: GitRepositoryRelativeRootPrefix
    ) throws -> StatusValue? {
        guard let record = try reader.next() else { return nil }
        guard let path = rootRelative(record.repositoryRelativePathBytes, prefix: prefix) else {
            throw PlanningFailure.fallback(.compatibilityMismatch)
        }
        let sourcePath = try record.sourceRepositoryRelativePathBytes.map { source -> Data in
            guard let relative = rootRelative(source, prefix: prefix) else {
                throw PlanningFailure.fallback(.compatibilityMismatch)
            }
            return relative
        }
        return StatusValue(record: record, path: path, sourcePath: sourcePath)
    }

    private static func rootRelative(
        _ repositoryRelativePath: Data,
        prefix: GitRepositoryRelativeRootPrefix
    ) -> Data? {
        let prefixBytes = Data(prefix.value.utf8)
        guard !prefixBytes.isEmpty else { return repositoryRelativePath }
        var required = prefixBytes
        required.append(UInt8(ascii: "/"))
        guard repositoryRelativePath.starts(with: required), repositoryRelativePath.count > required.count else {
            return nil
        }
        return Data(repositoryRelativePath.dropFirst(required.count))
    }

    private static func minimumPath(_ paths: [Data?]) -> Data? {
        paths.compactMap(\.self).min { $0.lexicographicallyPrecedes($1) }
    }

    private static func pathContainsRepositoryMetadata(_ path: Data) -> Bool {
        path.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
            .contains { $0.elementsEqual(Data(".git".utf8)) }
    }

    private func flightKey(
        hint: WorkspaceRootMaterializationHint,
        service: FileSystemService
    ) async throws -> WorkspaceRootTargetEvidenceFlightKey {
        let receipt = hint.creationReceipt
        let rootIdentity = try WorkspaceRootNamespaceRootIdentity(rootURL: service.rootURL)
        let policy = await service.currentWorkspaceRootCatalogPolicyIdentity()
        let repositoryKey = GitWorkspaceAuthorityRepositoryKey(layout: receipt.targetLayout)
        let searchABI = receipt.parentCompatibilityKey.searchABI
        let catalogPolicyIdentity = Self.digestFields([
            String(policy.schemaVersion),
            policy.mandatoryIgnorePolicyIdentity,
            policy.globalIgnoreDefaultsDigest,
            policy.respectRepoIgnore ? "1" : "0",
            policy.respectCursorignore ? "1" : "0",
            policy.enableHierarchicalIgnores ? "1" : "0",
            policy.skipSymlinks ? "1" : "0"
        ])
        return WorkspaceRootTargetEvidenceFlightKey(
            physicalWorktree: .init(
                canonicalRootPath: service.rootURL.resolvingSymlinksInPath().standardizedFileURL.path,
                deviceID: rootIdentity.device,
                inode: rootIdentity.inode,
                canonicalGitDirectoryPath: receipt.targetLayout.gitDir
                    .resolvingSymlinksInPath().standardizedFileURL.path
            ),
            gitAuthorityRepositoryIdentity: Self.digestFields([
                repositoryKey.standardizedCommonDirectoryPath,
                repositoryKey.standardizedGitDirectoryPath,
                repositoryKey.commonDirectoryDevice.map(String.init) ?? "nil",
                repositoryKey.commonDirectoryInode.map(String.init) ?? "nil"
            ]),
            repositoryRelativeRootPrefix: Data(receipt.repositoryRelativeRootPrefix.value.utf8),
            reusableSnapshotIdentity: Self.digestFields([
                receipt.parentSnapshotIdentity.sha256,
                String(searchABI.matcherSchemaVersion),
                String(searchABI.projectedKeySchemaVersion),
                String(searchABI.comparatorSchemaVersion),
                String(searchABI.pathNormalizationSchemaVersion)
            ]),
            catalogPolicyIdentity: catalogPolicyIdentity,
            creationCutIdentity: Self.creationCutFlightIdentity(receipt),
            namespaceAcquisitionIdentity: Self.digestFields([
                rootIdentity.canonicalPathBytes.base64EncodedString(),
                String(rootIdentity.device),
                String(rootIdentity.inode),
                catalogPolicyIdentity.base64EncodedString()
            ]),
            inventorySchema: UInt32(receipt.parentCompatibilityKey.inventorySchemaVersion),
            searchSchema: UInt32(searchABI.projectedKeySchemaVersion)
        )
    }

    private static func authoritySnapshotIdentity(_ snapshot: GitWorkspaceAuthoritySnapshot) -> Data {
        let policy = snapshot.policyIdentity
        let fields = [
            snapshot.repositoryKey.standardizedCommonDirectoryPath,
            snapshot.repositoryKey.standardizedGitDirectoryPath,
            snapshot.repositoryKey.commonDirectoryDevice.map(String.init) ?? "nil",
            snapshot.repositoryKey.commonDirectoryInode.map(String.init) ?? "nil",
            snapshot.repositoryNamespace.rawValue,
            snapshot.objectFormat.rawValue,
            snapshot.headCommitOID.lowercaseHex,
            snapshot.treeOID.lowercaseHex,
            snapshot.repositoryRelativeRootPrefix.value,
            snapshot.repositoryBindingEpoch,
            snapshot.worktreeBindingEpoch,
            snapshot.layoutGeneration,
            snapshot.indexGeneration,
            snapshot.checkoutConfigurationGeneration,
            snapshot.metadataGeneration,
            policy.mandatoryIgnorePolicyIdentity,
            policy.committedIgnoreControlDigest,
            policy.configuredIgnoreAuthorityDigest,
            policy.attributePolicyDigest,
            policy.sparsePolicyDigest
        ]
        return digestFields(fields)
    }

    private static func digestFields(_ fields: [String]) -> Data {
        var digest = SHA256()
        for field in fields {
            var count = UInt64(field.utf8.count).bigEndian
            withUnsafeBytes(of: &count) { digest.update(data: Data($0)) }
            digest.update(data: Data(field.utf8))
        }
        return Data(digest.finalize())
    }

    private static func creationCutProvenance(_ receipt: GitWorktreeCreationReceipt) -> Data {
        var digest = SHA256()
        for value in [
            receipt.id.uuidString.lowercased(),
            receipt.mutationID.uuidString.lowercased(),
            receipt.correlationID.uuidString.lowercased(),
            receipt.actualTargetPath,
            receipt.repositoryRelativeRootPrefix.value,
            String(receipt.witnessCoverage.startEventID),
            String(receipt.witnessCoverage.endEventID),
            String(receipt.witnessCoverage.endAcceptedCallbackWatermark),
            String(receipt.witnessCoverage.endedAtUptimeNanoseconds)
        ] {
            var length = UInt64(value.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { digest.update(data: Data($0)) }
            digest.update(data: Data(value.utf8))
        }
        for path in receipt.exactCopiedRelativePaths {
            var length = UInt64(path.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { digest.update(data: Data($0)) }
            digest.update(data: Data(path.utf8))
        }
        return Data(digest.finalize())
    }

    /// Join identity deliberately excludes waiter/session/correlation/receipt IDs.
    /// Compatible inherited sessions share the same physical cut and authority work.
    private static func creationCutFlightIdentity(_ receipt: GitWorktreeCreationReceipt) -> Data {
        digestFields([
            receipt.actualTargetPath,
            receipt.repositoryRelativeRootPrefix.value,
            String(receipt.witnessCoverage.startEventID),
            String(receipt.witnessCoverage.endEventID),
            String(receipt.witnessCoverage.startAcceptedCallbackWatermark),
            String(receipt.witnessCoverage.endAcceptedCallbackWatermark),
            String(receipt.witnessCoverage.startedAtUptimeNanoseconds),
            String(receipt.witnessCoverage.endedAtUptimeNanoseconds)
        ] + receipt.exactCopiedRelativePaths)
    }

    private static func fallbackReason(for error: Error) -> WorkspaceRootSeedFallbackReason {
        if let failure = error as? PlanningFailure,
           case let .fallback(reason) = failure
        { return reason }
        if error is CancellationError { return .cancellation }
        if let error = error as? WorkspaceRootTargetEvidenceCoordinatorError {
            return switch error {
            case .waiterDeadlineExceeded: .evidenceWaitDeadlineExceeded
            case .authoritySnapshotChanged, .authorityUnstable: .authorityUnstable
            case .attemptResourceAlreadyRegistered: .targetEvidenceIncoherent
            }
        }
        if let reason = error as? GitWorkspaceAuthorityUnavailableReason {
            return switch reason {
            case .mutationInProgress, .metadataEventPending: .authorityChanging
            case .noSnapshot, .monitorCoverageUnavailable, .superseded,
                 .invalidatedDuringCollection, .collectionScopeMismatch: .authorityUnstable
            }
        }
        if let error = error as? GitTargetEvidenceCollectionError {
            return switch error {
            case .authorityChanged: .authorityUnstable
            case .activityTimeout: .gitTimeout
            case .malformedGitOutput: .gitMalformedOutput
            case let .gitInitialization(initialization):
                switch initialization.reason {
                case .malformedOutput, .invalidRootPrefix: .gitMalformedOutput
                case .timeout: .gitTimeout
                case .cancelled: .cancellation
                case .gitError, .cappedOutput, .recordLimitExceeded, .pathLimitExceeded: .gitError
                }
            case .admission, .processCapture: .gitResourceUnavailable
            case let .spool(spool):
                switch spool {
                case .resourceAdmission: .evidenceResourceUnavailable
                case .io: .evidenceIOFailure
                case .invalidConfiguration, .closed, .corrupt: .gitEvidenceCorrupt
                }
            case .resourceAdmission: .evidenceResourceUnavailable
            case .artifact: .gitEvidenceCorrupt
            case .io: .evidenceIOFailure
            case .processLaunch, .gitFailure, .gitSignal: .gitError
            }
        }
        if let error = error as? WorkspaceRootNamespaceManifestError {
            return switch error {
            case .resourceAdmission: .evidenceResourceUnavailable
            case .io: .evidenceIOFailure
            case .invalidConfiguration, .invalidRecord, .duplicatePath, .outOfOrder,
                 .closed, .corrupt: .namespaceEvidenceCorrupt
            }
        }
        if let error = error as? WorkspaceRootTargetSeedPlanManifestError {
            return switch error {
            case .resourceAdmission: .evidenceResourceUnavailable
            case .io: .evidenceIOFailure
            case .invalidConfiguration, .invalidRecord, .duplicatePath, .outOfOrder,
                 .closed, .corrupt: .targetEvidenceIncoherent
            }
        }
        if let error = error as? WorkspaceRootReusableInventoryManifestError {
            return switch error {
            case .resourceAdmission: .evidenceResourceUnavailable
            case .io: .evidenceIOFailure
            case .invalidConfiguration, .invalidRecord, .duplicateRecord,
                 .canonicalPathCollision, .outOfOrder, .closed, .corrupt:
                .gitEvidenceCorrupt
            }
        }
        return .gitError
    }
}
