import Foundation
import RepoPromptCodeMapCore

/// Root-local derived graph authority. Overlay generations are freshness metadata; queries always
/// pin the latest immutable commit and destructive safety is enforced independently by fences.
actor WorkspaceCodemapSelectionGraph {
    private struct CandidateBuild {
        let snapshot: WorkspaceCodemapGraphCommittedSnapshot
        let changedFileCount: Int
        let affectedSourceCount: Int
        let resync: Bool
    }

    private enum CandidateBuildOutcome {
        case success(CandidateBuild)
        case failure(WorkspaceCodemapGraphApplyRejection)
        case cancelled
    }

    private let rootEpoch: WorkspaceCodemapRootEpoch
    private let graphPolicy: WorkspaceCodemapGraphPolicy
    private let applyBuildHook: @Sendable () async -> Void
    private let uptimeNanoseconds: @Sendable () -> UInt64
    private let reconciliationWaiter: @Sendable (UInt64) async -> Void

    private var repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken?
    private var committedSnapshot: WorkspaceCodemapGraphCommittedSnapshot?
    private var appliedGeneration = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 0)
    private var observedGeneration = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 0)
    private var graphRevision: UInt64 = 0
    private var fenceIdentities: Set<WorkspaceCodemapGraphFenceIdentity> = []
    private var safetyCounter: UInt64 = 0
    private var revocationReason: WorkspaceCodemapGraphRevocationReason?
    private var activeApply = false
    private var applyWaiters: [CheckedContinuation<Void, Never>] = []
    private var shuttingDown = false
    private var activeCandidateTask: Task<CandidateBuildOutcome, Never>?

    private var reconciling = false
    private var reconciliationAttempt = 0
    private var reconciliationStartedUptimeNanoseconds: UInt64?
    private var reconciliationNeedsFollowingPass = false
    private var reconciliationCycleID: UUID?
    private var reconciliationDeadlineTask: Task<Void, Never>?

    private var successfulCommitCount: UInt64 = 0
    private var resyncCommitCount: UInt64 = 0
    private var rejectedApplyCount: UInt64 = 0
    private var lastCommittedUptimeNanoseconds: UInt64?
    private var lastCommitIntervalMilliseconds: UInt64?
    private var statusContinuations: [
        UUID: AsyncStream<WorkspaceCodemapGraphIncrementalAccounting>.Continuation
    ] = [:]
    private var materializedQueryResultCount: UInt64 = 0
    private var diffPullCount: UInt64 = 0
    private var resyncPullCount: UInt64 = 0
    private var revokedPullCount: UInt64 = 0
    private var lastChangedFileCount = 0
    private var lastAffectedSourceCount = 0
    private var totalChangedFileCount: UInt64 = 0
    private var totalAffectedSourceCount: UInt64 = 0
    private var currentQueryCount: UInt64 = 0
    private var pendingQueryCount: UInt64 = 0
    private var partialCoverageQueryCount: UInt64 = 0
    private var reconciliationStartedCount: UInt64 = 0
    private var reconciliationCoalescedCount: UInt64 = 0
    private var reconciliationCommittedCount: UInt64 = 0
    private var reconciliationRetryCount: UInt64 = 0
    private var reconciliationRevokedCount: UInt64 = 0
    private var receiptValidationCount: UInt64 = 0
    private var receiptRejectionCount: UInt64 = 0
    private var applyStartedUptimeNanoseconds: UInt64?
    private var lastApplyDurationMilliseconds: UInt64?
    private var maximumApplyDurationMilliseconds: UInt64?
    private var highFanoutApplyCount: UInt64 = 0
    private var reconciliationExpiryHandler: (@Sendable () async -> Void)?

    init(
        rootEpoch: WorkspaceCodemapRootEpoch,
        repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken? = nil,
        graphPolicy: WorkspaceCodemapGraphPolicy = .initial,
        applyBuildHook: @escaping @Sendable () async -> Void = {},
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        reconciliationWaiter: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.rootEpoch = rootEpoch
        self.repositoryAuthority = repositoryAuthority
        self.graphPolicy = graphPolicy
        self.applyBuildHook = applyBuildHook
        self.uptimeNanoseconds = uptimeNanoseconds
        self.reconciliationWaiter = reconciliationWaiter
    }

    func installReconciliationExpiryHandler(
        _ handler: @escaping @Sendable () async -> Void
    ) {
        reconciliationExpiryHandler = handler
    }

    func observe(
        generation: WorkspaceCodemapSelectionGraphContributionGeneration
    ) {
        if generation > observedGeneration {
            observedGeneration = generation
            publishAccounting()
        }
    }

    func apply(
        _ changes: WorkspaceCodemapGraphChangesDisposition
    ) async -> WorkspaceCodemapGraphApplyDisposition {
        await acquireApplyLane()
        applyStartedUptimeNanoseconds = uptimeNanoseconds()
        defer {
            recordApplyDuration()
            releaseApplyLane()
            publishAccounting()
        }

        switch changes {
        case .diff: diffPullCount &+= 1
        case .resync: resyncPullCount &+= 1
        case .revoked: revokedPullCount &+= 1
        case .unchanged: break
        }

        if let revocationReason { return .revoked(revocationReason) }
        if shuttingDown { return .cancelled }

        switch changes {
        case let .unchanged(generation):
            observe(generation: generation)
            return .unchanged(generation: generation)
        case let .revoked(reason):
            revoke(reason)
            return .revoked(reason)
        case let .diff(changedSlots, removed, coverage, generation):
            observe(generation: generation)
            guard generation > appliedGeneration else {
                if generation == appliedGeneration { return .unchanged(generation: generation) }
                rejectedApplyCount &+= 1
                return .rejected(.staleGeneration)
            }
            guard let base = committedSnapshot else {
                rejectedApplyCount &+= 1
                return .rejected(.generationContinuity)
            }
            return await buildAndCommit(
                base: base,
                slots: changedSlots,
                removed: removed,
                coverage: coverage,
                generation: generation,
                schemaVersion: base.schemaVersion,
                policyVersion: base.policyVersion,
                authority: base.repositoryAuthority,
                resync: false
            )
        case let .resync(checkpoint, generation):
            observe(generation: generation)
            guard checkpoint.generation == generation else {
                rejectedApplyCount &+= 1
                return .rejected(.invalidCheckpoint)
            }
            return await buildAndCommit(
                base: nil,
                slots: checkpoint.slots,
                removed: [],
                coverage: checkpoint.coverage,
                generation: generation,
                schemaVersion: checkpoint.schemaVersion,
                policyVersion: checkpoint.policyVersion,
                authority: checkpoint.repositoryAuthority,
                resync: true
            )
        }
    }

    private func buildAndCommit(
        base: WorkspaceCodemapGraphCommittedSnapshot?,
        slots: [WorkspaceCodemapGraphSlot],
        removed: [WorkspaceCodemapGraphRemoval],
        coverage: WorkspaceCodemapGraphCatalogCoverage,
        generation: WorkspaceCodemapSelectionGraphContributionGeneration,
        schemaVersion: UInt32,
        policyVersion: UInt32,
        authority: WorkspaceCodemapRepositoryAuthorityToken,
        resync: Bool
    ) async -> WorkspaceCodemapGraphApplyDisposition {
        guard coverage.rootEpoch == rootEpoch,
              slots.allSatisfy({ $0.rootEpoch == rootEpoch }),
              removed.allSatisfy({ $0.rootEpoch == rootEpoch })
        else {
            rejectedApplyCount &+= 1
            return .rejected(.rootEpochMismatch)
        }
        if let currentAuthority = repositoryAuthority, currentAuthority != authority {
            rejectedApplyCount &+= 1
            return .rejected(.repositoryAuthorityMismatch)
        }
        guard schemaVersion == CodeMapSelectionGraphContribution.currentSchemaVersion else {
            rejectedApplyCount &+= 1
            return .rejected(.schemaMismatch)
        }
        guard policyVersion == CodeMapSelectionGraphContribution.currentPolicyVersion else {
            rejectedApplyCount &+= 1
            return .rejected(.policyMismatch)
        }
        guard let watermark = coverage.catalogWatermark else {
            rejectedApplyCount &+= 1
            return .rejected(.invalidCheckpoint)
        }
        if let oldWatermark = committedSnapshot?.catalogWatermark,
           oldWatermark.catalogGeneration > watermark.catalogGeneration
        {
            rejectedApplyCount &+= 1
            return .rejected(.catalogWatermarkRegression)
        }

        let baseRevision = graphRevision
        let (nextRevision, revisionOverflow) = baseRevision.addingReportingOverflow(1)
        guard !revisionOverflow else {
            revoke(.accountingOverflow)
            return .revoked(.accountingOverflow)
        }
        let policy = graphPolicy
        let capturedRootEpoch = rootEpoch
        await applyBuildHook()
        guard !shuttingDown, revocationReason == nil else { return .cancelled }
        let candidateTask = Task.detached(priority: .utility) {
            Self.makeCandidate(
                base: resync ? nil : base,
                changedSlots: slots,
                removed: removed,
                rootEpoch: capturedRootEpoch,
                authority: authority,
                watermark: watermark,
                coverage: coverage,
                generation: generation,
                schemaVersion: schemaVersion,
                policyVersion: policyVersion,
                nextRevision: nextRevision,
                graphPolicy: policy,
                resync: resync
            )
        }
        activeCandidateTask = candidateTask
        let build = await candidateTask.value
        activeCandidateTask = nil

        guard !shuttingDown else { return .cancelled }
        if let revocationReason { return .revoked(revocationReason) }
        guard graphRevision == baseRevision else {
            rejectedApplyCount &+= 1
            return .rejected(.generationContinuity)
        }
        switch build {
        case .cancelled:
            return .cancelled
        case let .failure(rejection):
            rejectedApplyCount &+= 1
            return .rejected(rejection)
        case let .success(candidate):
            let destructiveFileIDs = Set(removed.filter(\.reason.requiresSafetyFence).map(\.fileID))
            let destructiveIdentities = Set(destructiveFileIDs.map {
                WorkspaceCodemapGraphFenceIdentity(fileID: $0, slot: base?.slotsByFileID[$0])
            })
            let newFenceIdentities = destructiveIdentities.subtracting(fenceIdentities)
            guard fenceIdentities.count + newFenceIdentities.count <= graphPolicy.maximumFencedFileIDCount else {
                revoke(.fenceCapacityExceeded)
                return .revoked(.fenceCapacityExceeded)
            }
            if !newFenceIdentities.isEmpty {
                let (nextCounter, overflow) = safetyCounter.addingReportingOverflow(1)
                guard !overflow else {
                    revoke(.safetyCounterExhausted)
                    return .revoked(.safetyCounterExhausted)
                }
                fenceIdentities.formUnion(newFenceIdentities)
                safetyCounter = nextCounter
            }
            repositoryAuthority = authority
            committedSnapshot = candidate.snapshot
            appliedGeneration = generation
            if observedGeneration < generation { observedGeneration = generation }
            graphRevision = candidate.snapshot.graphRevision
            successfulCommitCount &+= 1
            lastChangedFileCount = candidate.changedFileCount
            lastAffectedSourceCount = candidate.affectedSourceCount
            totalChangedFileCount &+= UInt64(candidate.changedFileCount)
            totalAffectedSourceCount &+= UInt64(candidate.affectedSourceCount)
            if candidate.affectedSourceCount >= graphPolicy.candidateOverflowThreshold {
                highFanoutApplyCount &+= 1
            }
            if resync {
                resyncCommitCount &+= 1
                if reconciling { reconciliationCommittedCount &+= 1 }
            }
            let committedAt = uptimeNanoseconds()
            if let previous = lastCommittedUptimeNanoseconds, committedAt >= previous {
                lastCommitIntervalMilliseconds = (committedAt - previous) / 1_000_000
            }
            lastCommittedUptimeNanoseconds = committedAt
            if reconciling, resync {
                reconciling = false
                reconciliationAttempt = 0
                reconciliationStartedUptimeNanoseconds = nil
                cancelReconciliationDeadline()
                if reconciliationNeedsFollowingPass {
                    reconciliationNeedsFollowingPass = false
                    reconciling = true
                    reconciliationAttempt = 1
                    reconciliationStartedUptimeNanoseconds = uptimeNanoseconds()
                    scheduleReconciliationDeadline()
                }
            }
            return .committed(
                revision: graphRevision,
                appliedGeneration: generation,
                changedFileCount: candidate.changedFileCount,
                affectedSourceCount: candidate.affectedSourceCount,
                resync: resync
            )
        }
    }

    func latestSnapshot() -> WorkspaceCodemapGraphLatestSnapshotDisposition {
        if let revocationReason { return .revoked(revocationReason) }
        guard let snapshot = committedSnapshot,
              let receipt = WorkspaceCodemapGraphSnapshotReceipt(
                  snapshotID: snapshot.snapshotID,
                  graphRevision: snapshot.graphRevision,
                  rootEpoch: snapshot.rootEpoch,
                  repositoryAuthority: snapshot.repositoryAuthority,
                  catalogWatermark: snapshot.catalogWatermark,
                  appliedGeneration: snapshot.appliedGeneration,
                  safetyCounter: safetyCounter,
                  schemaVersion: snapshot.schemaVersion,
                  policyVersion: snapshot.policyVersion
              )
        else { return .pending }
        let freshness: WorkspaceCodemapGraphSnapshotFreshness = observedGeneration > appliedGeneration
            ? .updatesPending(observedGeneration: observedGeneration)
            : .current
        return .ready(WorkspaceCodemapGraphPinnedSnapshot(
            snapshot: snapshot,
            receipt: receipt,
            freshness: freshness,
            reconciling: reconciling,
            fenceIdentities: fenceIdentities
        ))
    }

    func automaticSelectionLatest(
        _ query: WorkspaceCodemapAutomaticSelectionGraphQuery
    ) -> WorkspaceCodemapAutomaticSelectionGraphDisposition {
        guard query.rootEpoch == rootEpoch else {
            return .revoked(.repositoryAuthorityChanged)
        }
        if Task.isCancelled { return .cancelled }
        switch latestSnapshot() {
        case .pending:
            pendingQueryCount &+= 1
            publishAccounting()
            return .pending
        case let .revoked(reason):
            return .revoked(reason)
        case let .ready(pinned):
            recordQuery(pinned)
            let snapshot = pinned.snapshot
            let groupedSeeds = Dictionary(grouping: query.sources, by: \.fileID)
            let sourceIDs = Set(groupedSeeds.keys)
            let orderedSourceIDs = groupedSeeds.keys.sorted {
                Self.fileIDPrecedes($0, $1, snapshot: snapshot)
            }
            var sources: [WorkspaceCodemapAutomaticSelectionGraphSource] = []
            var targetIDs = Set<UUID>()
            var resolutionCount = 0
            var referenceFailureCount = 0

            for fileID in orderedSourceIDs {
                let seeds = groupedSeeds[fileID] ?? []
                let requestedGenerations = Set(seeds.map(\.requestGeneration))
                let requestedGeneration = requestedGenerations.min() ?? 0
                let slot = snapshot.slotsByFileID[fileID]
                let state: WorkspaceCodemapAutomaticSelectionGraphSourceState = if requestedGenerations.count != 1 {
                    .staleGeneration(
                        expected: requestedGeneration,
                        committed: slot?.requestGeneration
                    )
                } else if pinned.isFenced(fileID) {
                    .fenced
                } else if let slot {
                    if slot.requestGeneration != requestedGeneration ||
                        slot.pathGeneration != requestedGeneration
                    {
                        .staleGeneration(
                            expected: requestedGeneration,
                            committed: slot.requestGeneration
                        )
                    } else {
                        switch slot.state {
                        case .pending:
                            .pending
                        case .contributed, .empty:
                            .covered
                        case .terminalArtifact, .terminalExcluded:
                            .excluded
                        }
                    }
                } else {
                    .notIndexed
                }
                sources.append(.init(
                    fileID: fileID,
                    requestGeneration: requestedGeneration,
                    state: state
                ))
                guard state == .covered else { continue }
                let edges = (snapshot.outgoingEdgesBySource[fileID] ?? []).filter {
                    !pinned.isFenced($0.targetFileID)
                }
                let (nextResolutionCount, resolutionOverflow) = resolutionCount.addingReportingOverflow(edges.count)
                guard !resolutionOverflow else { return .budget(.accountingOverflow) }
                resolutionCount = nextResolutionCount
                for edge in edges where !sourceIDs.contains(edge.targetFileID) {
                    targetIDs.insert(edge.targetFileID)
                }
                let failures = snapshot.unresolvedBySource[fileID]?.count ?? 0
                let (nextFailureCount, failureOverflow) = referenceFailureCount.addingReportingOverflow(failures)
                guard !failureOverflow else { return .budget(.accountingOverflow) }
                referenceFailureCount = nextFailureCount
            }

            if resolutionCount > query.maximumResolutionCount {
                return .budget(.resolutionLimit(
                    attempted: resolutionCount,
                    limit: query.maximumResolutionCount
                ))
            }
            if referenceFailureCount > query.maximumReferenceFailureCount {
                return .budget(.referenceFailureLimit(
                    attempted: referenceFailureCount,
                    limit: query.maximumReferenceFailureCount
                ))
            }

            let orderedTargetIDs = targetIDs.sorted {
                Self.fileIDPrecedes($0, $1, snapshot: snapshot)
            }
            if orderedTargetIDs.count > query.maximumTargetCount {
                return .budget(.targetLimit(
                    attempted: orderedTargetIDs.count,
                    limit: query.maximumTargetCount
                ))
            }
            var byteCount = 0
            var targets: [WorkspaceCodemapAutomaticSelectionGraphTarget] = []
            targets.reserveCapacity(orderedTargetIDs.count)
            for fileID in orderedTargetIDs {
                guard let node = snapshot.nodesByFileID[fileID],
                      let slot = snapshot.slotsByFileID[fileID],
                      slot.requestGeneration == node.requestGeneration,
                      slot.pathGeneration == node.pathGeneration
                else { continue }
                let (withFixedOverhead, fixedOverflow) = byteCount.addingReportingOverflow(64)
                let (withPath, pathOverflow) = withFixedOverhead.addingReportingOverflow(
                    node.standardizedRelativePath.utf8.count
                )
                guard !fixedOverflow, !pathOverflow else { return .budget(.accountingOverflow) }
                byteCount = withPath
                targets.append(.init(
                    fileID: fileID,
                    requestGeneration: node.requestGeneration,
                    standardizedRelativePath: node.standardizedRelativePath
                ))
            }
            if byteCount > query.maximumByteCount {
                return .budget(.byteLimit(attempted: byteCount, limit: query.maximumByteCount))
            }
            return .ready(.init(
                rootEpoch: rootEpoch,
                receipt: pinned.receipt,
                coverage: snapshot.coverage,
                freshness: pinned.freshness,
                reconciling: pinned.reconciling,
                sources: sources,
                targets: targets,
                resolutionCount: resolutionCount,
                referenceFailureCount: referenceFailureCount,
                materializedByteCount: byteCount
            ))
        }
    }

    func traverseLatest(
        _ query: WorkspaceCodemapGraphStructureQuery
    ) throws -> WorkspaceCodemapGraphStructureRootResult {
        try Task.checkCancellation()
        guard !query.seedFileIDs.isEmpty else {
            return WorkspaceCodemapGraphStructureRootResult(
                rootEpoch: rootEpoch,
                status: .unavailable,
                coverage: committedSnapshot?.coverage,
                updatesPending: observedGeneration > appliedGeneration,
                reconciling: reconciling,
                receipt: nil,
                seeds: [],
                nodes: [],
                edges: [],
                unresolved: [],
                truncation: nil,
                issues: [.emptySeeds]
            )
        }
        switch latestSnapshot() {
        case .pending:
            pendingQueryCount &+= 1
            publishAccounting()
            return WorkspaceCodemapGraphStructureRootResult(
                rootEpoch: rootEpoch,
                status: .pending,
                coverage: nil,
                updatesPending: true,
                reconciling: reconciling,
                receipt: nil,
                seeds: query.seedFileIDs.map {
                    WorkspaceCodemapGraphStructureSeed(
                        fileID: $0,
                        standardizedRelativePath: nil,
                        state: .pending
                    )
                },
                nodes: [],
                edges: [],
                unresolved: [],
                truncation: nil,
                issues: [.graphPending]
            )
        case let .revoked(reason):
            return WorkspaceCodemapGraphStructureRootResult(
                rootEpoch: rootEpoch,
                status: .unavailable,
                coverage: committedSnapshot?.coverage,
                updatesPending: false,
                reconciling: false,
                receipt: nil,
                seeds: query.seedFileIDs.map {
                    WorkspaceCodemapGraphStructureSeed(
                        fileID: $0,
                        standardizedRelativePath: committedSnapshot?.slotsByFileID[$0]?.standardizedRelativePath,
                        state: .notIndexed
                    )
                },
                nodes: [],
                edges: [],
                unresolved: [],
                truncation: nil,
                issues: [.graphRevoked(reason)]
            )
        case let .ready(pinned):
            recordQuery(pinned)
            return try traverse(query, pinned: pinned)
        }
    }

    private func traverse(
        _ query: WorkspaceCodemapGraphStructureQuery,
        pinned: WorkspaceCodemapGraphPinnedSnapshot
    ) throws -> WorkspaceCodemapGraphStructureRootResult {
        let snapshot = pinned.snapshot
        let orderedSeedIDs = Set(query.seedFileIDs).sorted {
            Self.fileIDPrecedes($0, $1, snapshot: snapshot)
        }
        var issues: [WorkspaceCodemapGraphStructureIssue] = []
        var seeds: [WorkspaceCodemapGraphStructureSeed] = []
        var usableSeedIDs: [UUID] = []
        for fileID in orderedSeedIDs {
            let slot = snapshot.slotsByFileID[fileID]
            let path = snapshot.nodesByFileID[fileID]?.standardizedRelativePath
                ?? slot?.standardizedRelativePath
            let state: WorkspaceCodemapStructureSeedState
            if pinned.isFenced(fileID) {
                state = .notIndexed
                issues.append(.seedFenced(fileID))
            } else if snapshot.nodesByFileID[fileID] != nil {
                state = .covered
                usableSeedIDs.append(fileID)
            } else if let slot {
                switch slot.state {
                case .pending:
                    state = .pending
                    issues.append(.seedPending(fileID))
                case .terminalExcluded:
                    state = .excluded
                    issues.append(.seedExcluded(fileID))
                case .terminalArtifact:
                    state = .notIndexed
                    issues.append(.seedNotIndexed(fileID))
                case .contributed, .empty:
                    state = .notIndexed
                    issues.append(.seedNotIndexed(fileID))
                }
            } else {
                state = .notIndexed
                issues.append(.seedNotIndexed(fileID))
            }
            seeds.append(WorkspaceCodemapGraphStructureSeed(
                fileID: fileID,
                standardizedRelativePath: path,
                state: state
            ))
        }

        if case .updatesPending = pinned.freshness { issues.append(.updatesPending) }
        if pinned.reconciling { issues.append(.watcherGapReconciling) }
        if !snapshot.coverage.isComplete { issues.append(.indexing) }

        guard !usableSeedIDs.isEmpty else {
            let hasPending = seeds.contains { $0.state == .pending } || !snapshot.coverage.isComplete
            return WorkspaceCodemapGraphStructureRootResult(
                rootEpoch: rootEpoch,
                status: hasPending ? .pending : .unavailable,
                coverage: snapshot.coverage,
                updatesPending: pinned.freshness != .current,
                reconciling: pinned.reconciling,
                receipt: pinned.receipt,
                seeds: seeds,
                nodes: [],
                edges: [],
                unresolved: [],
                truncation: nil,
                issues: issues
            )
        }

        let (deadlineDelta, deadlineOverflow) = graphPolicy.requestDeadlineMilliseconds
            .multipliedReportingOverflow(by: 1_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        let (candidateDeadline, deadlineAdditionOverflow) = now.addingReportingOverflow(deadlineDelta)
        let deadline = deadlineOverflow || deadlineAdditionOverflow ? UInt64.max : candidateDeadline
        let maximumDepth = query.direction == nil ? 0 : query.maximumDepth
        var nodesByFileID: [UUID: WorkspaceCodemapGraphStructureNode] = [:]
        var queue: [UUID] = []
        var queueIndex = 0
        var graphBytes: UInt64 = 0
        var droppedNodeCount = 0
        var truncated = false
        var deadlineReached = false

        func nodeByteCount(_ node: WorkspaceCodemapGraphSnapshotNode) -> UInt64? {
            guard let pathBytes = UInt64(exactly: node.standardizedRelativePath.utf8.count) else { return nil }
            let (value, overflow) = pathBytes.addingReportingOverflow(96)
            return overflow ? nil : value
        }

        for fileID in usableSeedIDs {
            guard let snapshotNode = snapshot.nodesByFileID[fileID],
                  !pinned.isFenced(fileID)
            else { continue }
            guard nodesByFileID.count < query.budget.maximumNodeCount,
                  let nodeBytes = nodeByteCount(snapshotNode),
                  graphBytes <= query.budget.maximumGraphByteCount,
                  nodeBytes <= query.budget.maximumGraphByteCount - graphBytes
            else {
                droppedNodeCount += 1
                truncated = true
                continue
            }
            graphBytes += nodeBytes
            nodesByFileID[fileID] = WorkspaceCodemapGraphStructureNode(
                fileID: fileID,
                standardizedRelativePath: snapshotNode.standardizedRelativePath,
                depth: 0,
                isSeed: true,
                reachedBy: []
            )
            queue.append(fileID)
        }

        var emittedEdges = Set<WorkspaceCodemapGraphStructureEdge>()
        traversal: while queueIndex < queue.count {
            try Task.checkCancellation()
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                deadlineReached = true
                break
            }
            let currentID = queue[queueIndex]
            queueIndex += 1
            guard let currentNode = nodesByFileID[currentID], currentNode.depth < maximumDepth else { continue }

            var neighbors: [(evidence: WorkspaceCodemapGraphEdgeEvidence, fileID: UUID, reachedBy: WorkspaceCodemapStructureTraversalReachDirection)] = []
            switch query.direction {
            case .none:
                break
            case .referencedDefinitions:
                neighbors = (snapshot.outgoingEdgesBySource[currentID] ?? []).map {
                    ($0, $0.targetFileID, .referencedDefinitions)
                }
            case .referrers:
                neighbors = (snapshot.reverseEdgesByTarget[currentID] ?? []).map {
                    ($0, $0.sourceFileID, .referrers)
                }
            case .both:
                neighbors = (snapshot.outgoingEdgesBySource[currentID] ?? []).map {
                    ($0, $0.targetFileID, .referencedDefinitions)
                } + (snapshot.reverseEdgesByTarget[currentID] ?? []).map {
                    ($0, $0.sourceFileID, .referrers)
                }
            }
            neighbors.sort { lhs, rhs in
                if lhs.fileID != rhs.fileID {
                    return Self.fileIDPrecedes(lhs.fileID, rhs.fileID, snapshot: snapshot)
                }
                if lhs.reachedBy != rhs.reachedBy {
                    return lhs.reachedBy.rawValue < rhs.reachedBy.rawValue
                }
                return Self.edgePrecedes(lhs.evidence, rhs.evidence, nodes: snapshot.nodesByFileID)
            }

            for neighbor in neighbors {
                try Task.checkCancellation()
                guard !pinned.isFenced(neighbor.fileID),
                      !pinned.isFenced(neighbor.evidence.sourceFileID),
                      !pinned.isFenced(neighbor.evidence.targetFileID),
                      let snapshotNode = snapshot.nodesByFileID[neighbor.fileID]
                else { continue }

                let nextDepth = currentNode.depth + 1
                if let existing = nodesByFileID[neighbor.fileID] {
                    if existing.depth == nextDepth, !existing.reachedBy.contains(neighbor.reachedBy) {
                        var reachedBy = existing.reachedBy
                        reachedBy.insert(neighbor.reachedBy)
                        nodesByFileID[neighbor.fileID] = WorkspaceCodemapGraphStructureNode(
                            fileID: existing.fileID,
                            standardizedRelativePath: existing.standardizedRelativePath,
                            depth: existing.depth,
                            isSeed: existing.isSeed,
                            reachedBy: reachedBy
                        )
                    }
                } else {
                    guard nodesByFileID.count < query.budget.maximumNodeCount,
                          let nodeBytes = nodeByteCount(snapshotNode),
                          graphBytes <= query.budget.maximumGraphByteCount,
                          nodeBytes <= query.budget.maximumGraphByteCount - graphBytes
                    else {
                        droppedNodeCount += 1
                        truncated = true
                        break traversal
                    }
                    graphBytes += nodeBytes
                    nodesByFileID[neighbor.fileID] = WorkspaceCodemapGraphStructureNode(
                        fileID: neighbor.fileID,
                        standardizedRelativePath: snapshotNode.standardizedRelativePath,
                        depth: nextDepth,
                        isSeed: false,
                        reachedBy: [neighbor.reachedBy]
                    )
                    queue.append(neighbor.fileID)
                }

                let edge = WorkspaceCodemapGraphStructureEdge(
                    sourceFileID: neighbor.evidence.sourceFileID,
                    targetFileID: neighbor.evidence.targetFileID,
                    symbols: neighbor.evidence.matchedNames,
                    ambiguous: neighbor.evidence.ambiguous
                )
                if !emittedEdges.contains(edge) {
                    let symbolBytes = edge.symbols.reduce(0) { $0 + $1.utf8.count }
                    guard emittedEdges.count < query.budget.maximumEdgeCount,
                          let payloadBytes = UInt64(exactly: 128 + symbolBytes),
                          graphBytes <= query.budget.maximumGraphByteCount,
                          payloadBytes <= query.budget.maximumGraphByteCount - graphBytes
                    else {
                        truncated = true
                        break traversal
                    }
                    graphBytes += payloadBytes
                    emittedEdges.insert(edge)
                }
            }
        }

        let orderedNodes = nodesByFileID.values.sorted {
            if $0.depth != $1.depth { return $0.depth < $1.depth }
            if $0.standardizedRelativePath != $1.standardizedRelativePath {
                return Self.utf8Precedes($0.standardizedRelativePath, $1.standardizedRelativePath)
            }
            return $0.fileID.uuidString < $1.fileID.uuidString
        }
        let orderedEdges = emittedEdges.sorted {
            let leftSource = snapshot.nodesByFileID[$0.sourceFileID]?.standardizedRelativePath ?? ""
            let rightSource = snapshot.nodesByFileID[$1.sourceFileID]?.standardizedRelativePath ?? ""
            if leftSource != rightSource { return Self.utf8Precedes(leftSource, rightSource) }
            let leftTarget = snapshot.nodesByFileID[$0.targetFileID]?.standardizedRelativePath ?? ""
            let rightTarget = snapshot.nodesByFileID[$1.targetFileID]?.standardizedRelativePath ?? ""
            if leftTarget != rightTarget { return Self.utf8Precedes(leftTarget, rightTarget) }
            return $0.symbols.lexicographicallyPrecedes($1.symbols, by: Self.utf8Precedes)
        }
        let visitedIDs = Set(nodesByFileID.keys)
        var unresolved: [WorkspaceCodemapGraphStructureUnresolved] = []
        for sourceID in visitedIDs.sorted(by: { Self.fileIDPrecedes($0, $1, snapshot: snapshot) }) {
            for record in snapshot.unresolvedBySource[sourceID] ?? [] {
                unresolved.append(WorkspaceCodemapGraphStructureUnresolved(
                    sourceFileID: sourceID,
                    referencedName: record.referencedName,
                    reason: record.reason
                ))
            }
        }
        unresolved.sort { lhs, rhs in
            if lhs.sourceFileID != rhs.sourceFileID {
                return Self.fileIDPrecedes(lhs.sourceFileID, rhs.sourceFileID, snapshot: snapshot)
            }
            if lhs.referencedName != rhs.referencedName {
                return Self.utf8Precedes(lhs.referencedName, rhs.referencedName)
            }
            return String(describing: lhs.reason) < String(describing: rhs.reason)
        }

        if truncated { issues.append(.maxTokens) }
        if deadlineReached { issues.append(.deadline) }
        let hasPartialIssue = !issues.isEmpty || unresolved.contains { $0.reason == .notIndexedYet }
        return WorkspaceCodemapGraphStructureRootResult(
            rootEpoch: rootEpoch,
            status: hasPartialIssue ? .partial : .ok,
            coverage: snapshot.coverage,
            updatesPending: pinned.freshness != .current,
            reconciling: pinned.reconciling,
            receipt: pinned.receipt,
            seeds: seeds,
            nodes: orderedNodes,
            edges: orderedEdges,
            unresolved: unresolved,
            truncation: truncated ? WorkspaceCodemapGraphStructureTruncation(
                droppedNodeCount: droppedNodeCount
            ) : nil,
            issues: issues
        )
    }

    func fenceFiles(
        fileIDs: Set<UUID>,
        reason: WorkspaceCodemapGraphFenceReason
    ) -> WorkspaceCodemapGraphFenceDisposition {
        guard let repositoryAuthority else { return .rejected(.repositoryAuthorityMismatch) }
        return fenceFiles(authority: repositoryAuthority, fileIDs: fileIDs, reason: reason)
    }

    func fenceFiles(
        authority: WorkspaceCodemapRepositoryAuthorityToken,
        fileIDs: Set<UUID>,
        reason _: WorkspaceCodemapGraphFenceReason
    ) -> WorkspaceCodemapGraphFenceDisposition {
        guard !fileIDs.isEmpty else { return .rejected(.emptyFileIDs) }
        guard let currentAuthority = repositoryAuthority else {
            return .rejected(.repositoryAuthorityMismatch)
        }
        guard currentAuthority == authority else { return .rejected(.repositoryAuthorityMismatch) }
        let requestedIdentities = Set(fileIDs.compactMap { fileID -> WorkspaceCodemapGraphFenceIdentity? in
            let currentSlot = committedSnapshot?.slotsByFileID[fileID]
            if currentSlot == nil, fenceIdentities.contains(where: { $0.fileID == fileID }) {
                return nil
            }
            return WorkspaceCodemapGraphFenceIdentity(fileID: fileID, slot: currentSlot)
        })
        let newFenceIdentities = requestedIdentities.subtracting(fenceIdentities)
        guard fenceIdentities.count + newFenceIdentities.count <= graphPolicy.maximumFencedFileIDCount else {
            revoke(.fenceCapacityExceeded)
            return .revoked(.fenceCapacityExceeded)
        }
        guard !newFenceIdentities.isEmpty else { return .fenced(safetyCounter: safetyCounter) }
        let (nextCounter, overflow) = safetyCounter.addingReportingOverflow(1)
        guard !overflow else {
            revoke(.safetyCounterExhausted)
            return .revoked(.safetyCounterExhausted)
        }
        fenceIdentities.formUnion(newFenceIdentities)
        safetyCounter = nextCounter
        publishAccounting()
        return .fenced(safetyCounter: safetyCounter)
    }

    func revalidate(
        _ receipt: WorkspaceCodemapGraphSnapshotReceipt,
        affectedFileIDs: Set<UUID>
    ) -> WorkspaceCodemapGraphReceiptDisposition {
        defer { publishAccounting() }
        receiptValidationCount &+= 1
        if let revocationReason {
            receiptRejectionCount &+= 1
            return .revoked(revocationReason)
        }
        guard receipt.rootEpoch == rootEpoch else {
            receiptRejectionCount &+= 1
            return .invalid(.rootEpochMismatch)
        }
        guard receipt.repositoryAuthority == repositoryAuthority else {
            receiptRejectionCount &+= 1
            return .invalid(.repositoryAuthorityMismatch)
        }
        guard receipt.schemaVersion == CodeMapSelectionGraphContribution.currentSchemaVersion else {
            receiptRejectionCount &+= 1
            return .invalid(.schemaMismatch)
        }
        guard receipt.policyVersion == CodeMapSelectionGraphContribution.currentPolicyVersion else {
            receiptRejectionCount &+= 1
            return .invalid(.policyMismatch)
        }
        let fencedIdentityFileIDs = Set(fenceIdentities.map(\.fileID))
        if receipt.safetyCounter != safetyCounter,
           !affectedFileIDs.isDisjoint(with: fencedIdentityFileIDs)
        {
            receiptRejectionCount &+= 1
            return .invalid(.fencedFileOverlap)
        }
        let freshness: WorkspaceCodemapGraphSnapshotFreshness = observedGeneration > appliedGeneration
            ? .updatesPending(observedGeneration: observedGeneration)
            : .current
        return .valid(freshness)
    }

    func beginWatcherGapReconciliation() -> WorkspaceCodemapGraphReconciliationDisposition {
        guard let repositoryAuthority else { return .revoked(.repositoryAuthorityChanged) }
        return beginWatcherGapReconciliation(authority: repositoryAuthority)
    }

    func beginWatcherGapReconciliation(
        authority: WorkspaceCodemapRepositoryAuthorityToken
    ) -> WorkspaceCodemapGraphReconciliationDisposition {
        if let revocationReason { return .revoked(revocationReason) }
        guard repositoryAuthority == authority else {
            revoke(.repositoryAuthorityChanged)
            return .revoked(.repositoryAuthorityChanged)
        }
        if reconciling {
            reconciliationNeedsFollowingPass = true
            reconciliationCoalescedCount &+= 1
            publishAccounting()
            return .coalesced(attempt: reconciliationAttempt)
        }
        reconciling = true
        reconciliationAttempt = 1
        reconciliationStartedCount &+= 1
        reconciliationStartedUptimeNanoseconds = uptimeNanoseconds()
        scheduleReconciliationDeadline()
        publishAccounting()
        return .started(attempt: reconciliationAttempt)
    }

    func recordWatcherGapReconciliationFailure() -> WorkspaceCodemapGraphReconciliationDisposition {
        guard let repositoryAuthority else { return .revoked(.repositoryAuthorityChanged) }
        return recordWatcherGapReconciliationFailure(authority: repositoryAuthority)
    }

    func recordWatcherGapReconciliationFailure(
        authority: WorkspaceCodemapRepositoryAuthorityToken
    ) -> WorkspaceCodemapGraphReconciliationDisposition {
        if let revocationReason { return .revoked(revocationReason) }
        guard repositoryAuthority == authority else {
            revoke(.repositoryAuthorityChanged)
            return .revoked(.repositoryAuthorityChanged)
        }
        if !reconciling {
            reconciling = true
            reconciliationAttempt = 1
            reconciliationStartedUptimeNanoseconds = uptimeNanoseconds()
            reconciliationStartedCount &+= 1
            scheduleReconciliationDeadline()
        } else {
            reconciliationAttempt += 1
            reconciliationRetryCount &+= 1
        }
        let elapsedMilliseconds: UInt64 = reconciliationStartedUptimeNanoseconds.map { started in
            let now = uptimeNanoseconds()
            return now >= started ? (now - started) / 1_000_000 : 0
        } ?? 0
        if reconciliationAttempt >= graphPolicy.maximumReconciliationAttemptCount ||
            elapsedMilliseconds >= graphPolicy.maximumReconciliationWallClockMilliseconds
        {
            reconciliationRevokedCount &+= 1
            revoke(.reconciliationFailed)
            return .revoked(.reconciliationFailed)
        }
        publishAccounting()
        return .failedRetryable(attempt: reconciliationAttempt)
    }

    func incrementalAccounting() -> WorkspaceCodemapGraphIncrementalAccounting {
        let reconciliationDeadline = reconciliationStartedUptimeNanoseconds.flatMap { started in
            let milliseconds = graphPolicy.maximumReconciliationWallClockMilliseconds
            let (nanoseconds, multiplyOverflow) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
            let (deadline, addOverflow) = started.addingReportingOverflow(nanoseconds)
            return multiplyOverflow || addOverflow ? UInt64.max : deadline
        }
        return WorkspaceCodemapGraphIncrementalAccounting(
            graphRevision: graphRevision,
            coverage: committedSnapshot?.coverage,
            appliedGeneration: appliedGeneration,
            observedGeneration: observedGeneration,
            safetyCounter: safetyCounter,
            fencedFileCount: fenceIdentities.count,
            updatesPending: observedGeneration > appliedGeneration,
            reconciling: reconciling,
            reconciliationAttempt: reconciling ? reconciliationAttempt : nil,
            reconciliationDeadlineUptimeNanoseconds: reconciliationDeadline,
            activeApply: activeApply,
            successfulCommitCount: successfulCommitCount,
            resyncCommitCount: resyncCommitCount,
            rejectedApplyCount: rejectedApplyCount,
            lastCommittedUptimeNanoseconds: lastCommittedUptimeNanoseconds,
            lastCommitIntervalMilliseconds: lastCommitIntervalMilliseconds,
            revocationReason: revocationReason,
            diffPullCount: diffPullCount,
            resyncPullCount: resyncPullCount,
            revokedPullCount: revokedPullCount,
            lastChangedFileCount: lastChangedFileCount,
            lastAffectedSourceCount: lastAffectedSourceCount,
            totalChangedFileCount: totalChangedFileCount,
            totalAffectedSourceCount: totalAffectedSourceCount,
            currentQueryCount: currentQueryCount,
            pendingQueryCount: pendingQueryCount,
            partialCoverageQueryCount: partialCoverageQueryCount,
            reconciliationStartedCount: reconciliationStartedCount,
            reconciliationCoalescedCount: reconciliationCoalescedCount,
            reconciliationCommittedCount: reconciliationCommittedCount,
            reconciliationRetryCount: reconciliationRetryCount,
            reconciliationRevokedCount: reconciliationRevokedCount,
            receiptValidationCount: receiptValidationCount,
            receiptRejectionCount: receiptRejectionCount,
            lastApplyDurationMilliseconds: lastApplyDurationMilliseconds,
            maximumApplyDurationMilliseconds: maximumApplyDurationMilliseconds,
            highFanoutApplyCount: highFanoutApplyCount,
            observedToAppliedGenerationLag: observedGeneration.rawValue >= appliedGeneration.rawValue
                ? observedGeneration.rawValue - appliedGeneration.rawValue
                : 0
        )
    }

    func statusUpdates() -> AsyncStream<WorkspaceCodemapGraphIncrementalAccounting> {
        let id = UUID()
        return AsyncStream<WorkspaceCodemapGraphIncrementalAccounting>(bufferingPolicy: .bufferingNewest(1)) {
            continuation in
            statusContinuations[id] = continuation
            continuation.yield(incrementalAccounting())
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeStatusContinuation(id) }
            }
        }
    }

    private func removeStatusContinuation(_ id: UUID) {
        statusContinuations.removeValue(forKey: id)
    }

    private func publishAccounting() {
        let accounting = incrementalAccounting()
        for continuation in statusContinuations.values {
            continuation.yield(accounting)
        }
    }

    #if DEBUG
        func hasActiveCandidateBuildForTesting() -> Bool {
            activeCandidateTask != nil
        }
    #endif

    func shutdown(reason: WorkspaceCodemapGraphRevocationReason = .rootUnloaded) async {
        shuttingDown = true
        revoke(reason)
        if let activeCandidateTask {
            activeCandidateTask.cancel()
            await activeCandidateTask.value
            self.activeCandidateTask = nil
        }
    }

    private func acquireApplyLane() async {
        while activeApply {
            await withCheckedContinuation { applyWaiters.append($0) }
        }
        activeApply = true
        publishAccounting()
    }

    private func releaseApplyLane() {
        activeApply = false
        publishAccounting()
        let waiters = applyWaiters
        applyWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func revoke(_ reason: WorkspaceCodemapGraphRevocationReason) {
        revocationReason = reason
        reconciling = false
        cancelReconciliationDeadline()
        activeCandidateTask?.cancel()
        publishAccounting()
    }

    private func recordQuery(_ pinned: WorkspaceCodemapGraphPinnedSnapshot) {
        defer { publishAccounting() }
        switch pinned.freshness {
        case .current: currentQueryCount &+= 1
        case .updatesPending: pendingQueryCount &+= 1
        }
        if !pinned.snapshot.coverage.isComplete { partialCoverageQueryCount &+= 1 }
    }

    private func recordApplyDuration() {
        guard let started = applyStartedUptimeNanoseconds else { return }
        let finished = uptimeNanoseconds()
        let duration = finished >= started ? (finished - started) / 1_000_000 : 0
        lastApplyDurationMilliseconds = duration
        maximumApplyDurationMilliseconds = max(maximumApplyDurationMilliseconds ?? 0, duration)
        applyStartedUptimeNanoseconds = nil
    }

    private func scheduleReconciliationDeadline() {
        cancelReconciliationDeadline()
        let cycleID = UUID()
        reconciliationCycleID = cycleID
        let milliseconds = graphPolicy.maximumReconciliationWallClockMilliseconds
        let (nanoseconds, overflow) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
        let wait = overflow ? UInt64.max : nanoseconds
        reconciliationDeadlineTask = Task { [weak self, reconciliationWaiter] in
            await reconciliationWaiter(wait)
            guard !Task.isCancelled else { return }
            await self?.expireReconciliation(cycleID: cycleID)
        }
    }

    private func cancelReconciliationDeadline() {
        reconciliationDeadlineTask?.cancel()
        reconciliationDeadlineTask = nil
        reconciliationCycleID = nil
    }

    private func expireReconciliation(cycleID: UUID) async {
        guard reconciling, reconciliationCycleID == cycleID, revocationReason == nil else { return }
        reconciliationRevokedCount &+= 1
        revoke(.reconciliationFailed)
        await reconciliationExpiryHandler?()
    }

    // MARK: - Candidate construction

    private static func makeCandidate(
        base: WorkspaceCodemapGraphCommittedSnapshot?,
        changedSlots: [WorkspaceCodemapGraphSlot],
        removed: [WorkspaceCodemapGraphRemoval],
        rootEpoch: WorkspaceCodemapRootEpoch,
        authority: WorkspaceCodemapRepositoryAuthorityToken,
        watermark: WorkspaceCodemapGraphIndexCatalogToken,
        coverage: WorkspaceCodemapGraphCatalogCoverage,
        generation: WorkspaceCodemapSelectionGraphContributionGeneration,
        schemaVersion: UInt32,
        policyVersion: UInt32,
        nextRevision: UInt64,
        graphPolicy: WorkspaceCodemapGraphPolicy,
        resync: Bool
    ) -> CandidateBuildOutcome {
        guard !Task.isCancelled else { return .cancelled }
        var slots = base?.slotsByFileID ?? [:]
        let oldSlots = slots
        if resync { slots.removeAll(keepingCapacity: true) }
        for removal in removed {
            guard !Task.isCancelled else { return .cancelled }
            slots.removeValue(forKey: removal.fileID)
        }
        for slot in changedSlots {
            guard !Task.isCancelled else { return .cancelled }
            slots[slot.fileID] = slot
        }

        let changedIDs = Set(oldSlots.keys).union(slots.keys).filter { oldSlots[$0] != slots[$0] }
        var nodes = base?.nodesByFileID ?? [:]
        var definitions = base?.definitionPostings ?? [:]
        var references = base?.referencePostings ?? [:]
        var outgoing = base?.outgoingEdgesBySource ?? [:]
        var reverse = base?.reverseEdgesByTarget ?? [:]
        var unresolved = base?.unresolvedBySource ?? [:]

        // Update the two posting tables only for changed nodes. Their definition deltas identify
        // every source whose edge or unresolved evidence can change.
        var changedDefinitionNames = Set<String>()
        for fileID in changedIDs {
            guard !Task.isCancelled else { return .cancelled }
            if let oldNode = nodes.removeValue(forKey: fileID) {
                changedDefinitionNames.formUnion(oldNode.contribution.sortedUniqueDefinitions)
                for name in oldNode.contribution.sortedUniqueDefinitions {
                    definitions[name]?.removeAll { $0 == fileID }
                    if definitions[name]?.isEmpty == true { definitions.removeValue(forKey: name) }
                }
                for name in oldNode.contribution.sortedUniqueReferences {
                    references[name]?.removeAll { $0 == fileID }
                    if references[name]?.isEmpty == true { references.removeValue(forKey: name) }
                }
            }
            guard let slot = slots[fileID], let node = snapshotNode(from: slot) else { continue }
            nodes[fileID] = node
            changedDefinitionNames.formUnion(node.contribution.sortedUniqueDefinitions)
            for name in node.contribution.sortedUniqueDefinitions {
                definitions[name, default: []].append(fileID)
            }
            for name in node.contribution.sortedUniqueReferences {
                references[name, default: []].append(fileID)
            }
        }
        for name in changedDefinitionNames {
            definitions[name]?.sort { fileIDPrecedes($0, $1, nodes: nodes) }
        }
        let changedReferenceNames = changedIDs.reduce(into: Set<String>()) { names, fileID in
            if let old = base?.nodesByFileID[fileID] {
                names.formUnion(old.contribution.sortedUniqueReferences)
            }
            if let new = nodes[fileID] { names.formUnion(new.contribution.sortedUniqueReferences) }
        }
        for name in changedReferenceNames {
            references[name]?.sort { fileIDPrecedes($0, $1, nodes: nodes) }
        }

        var affectedSources = changedIDs
        for name in changedDefinitionNames {
            affectedSources.formUnion(base?.referencePostings[name] ?? [])
            affectedSources.formUnion(references[name] ?? [])
        }
        if base?.coverage.isComplete != coverage.isComplete {
            // A completeness transition changes missing/not-indexed-yet evidence globally.
            affectedSources.formUnion(nodes.keys)
        }

        // Remove old evidence only for affected sources, including its reverse adjacency entries.
        for source in affectedSources {
            guard !Task.isCancelled else { return .cancelled }
            for evidence in outgoing.removeValue(forKey: source) ?? [] {
                reverse[evidence.targetFileID]?.removeAll { $0.sourceFileID == source }
                if reverse[evidence.targetFileID]?.isEmpty == true {
                    reverse.removeValue(forKey: evidence.targetFileID)
                }
            }
            unresolved.removeValue(forKey: source)
        }

        // Re-resolve only sources whose own contribution or referenced definition candidates changed.
        for source in affectedSources {
            guard !Task.isCancelled else { return .cancelled }
            guard let node = nodes[source] else { continue }
            var namesByTarget: [UUID: Set<String>] = [:]
            var candidateCountByTarget: [UUID: UInt64] = [:]
            for name in node.contribution.sortedUniqueReferences {
                let candidates = definitions[name] ?? []
                guard !candidates.isEmpty else {
                    unresolved[source, default: []].append(.init(
                        sourceFileID: source,
                        referencedName: name,
                        reason: coverage.isComplete ? .missing : .notIndexedYet
                    ))
                    continue
                }
                guard candidates.count <= graphPolicy.candidateOverflowThreshold else {
                    unresolved[source, default: []].append(.init(
                        sourceFileID: source,
                        referencedName: name,
                        reason: .tooCommon
                    ))
                    continue
                }
                for target in candidates {
                    namesByTarget[target, default: []].insert(name)
                    candidateCountByTarget[target] = UInt64(candidates.count)
                }
            }
            for target in namesByTarget.keys {
                let count = candidateCountByTarget[target] ?? 0
                let evidence = WorkspaceCodemapGraphEdgeEvidence(
                    sourceFileID: source,
                    targetFileID: target,
                    matchedNames: (namesByTarget[target] ?? []).sorted(by: utf8Precedes),
                    candidateCount: count,
                    ambiguous: count > 1
                )
                outgoing[source, default: []].append(evidence)
                reverse[target, default: []].append(evidence)
            }
            outgoing[source]?.sort { edgePrecedes($0, $1, nodes: nodes) }
            unresolved[source]?.sort {
                if $0.referencedName != $1.referencedName {
                    return utf8Precedes($0.referencedName, $1.referencedName)
                }
                return String(describing: $0.reason) < String(describing: $1.reason)
            }
        }
        let affectedTargets = Set(affectedSources.flatMap { outgoing[$0]?.map(\.targetFileID) ?? [] })
        for target in affectedTargets {
            reverse[target]?.sort { edgePrecedes($0, $1, nodes: nodes) }
        }

        guard let postingCount = checkedAdd(checkedCount(definitions.values), checkedCount(references.values)),
              let edgeCount = checkedCount(outgoing.values)
        else { return .failure(.accountingOverflow) }
        var byteCount: UInt64 = 0
        for node in nodes.values {
            guard !Task.isCancelled else { return .cancelled }
            guard let pathBytes = UInt64(exactly: node.standardizedRelativePath.utf8.count),
                  let definitionBytes = checkedStringBytes(node.contribution.sortedUniqueDefinitions),
                  let referenceBytes = checkedStringBytes(node.contribution.sortedUniqueReferences),
                  let withNode = checkedAdd(byteCount, 192),
                  let withPath = checkedAdd(withNode, pathBytes),
                  let withDefinitions = checkedAdd(withPath, definitionBytes),
                  let withReferences = checkedAdd(withDefinitions, referenceBytes)
            else { return .failure(.accountingOverflow) }
            byteCount = withReferences
        }
        // Account conservatively for every retained immutable collection. Contributions appear
        // in both slots and nodes by design, and both adjacency directions retain edge evidence.
        for slot in slots.values {
            guard !Task.isCancelled else { return .cancelled }
            let contribution: CodeMapSelectionGraphContribution? = switch slot.state {
            case let .contributed(value), let .empty(value): value
            case .pending, .terminalArtifact, .terminalExcluded: nil
            }
            guard let pathBytes = UInt64(exactly: slot.standardizedRelativePath.utf8.count),
                  let definitionBytes = checkedStringBytes(contribution?.sortedUniqueDefinitions ?? []),
                  let referenceBytes = checkedStringBytes(contribution?.sortedUniqueReferences ?? []),
                  let withSlot = checkedAdd(byteCount, 192),
                  let withPath = checkedAdd(withSlot, pathBytes),
                  let withDefinitions = checkedAdd(withPath, definitionBytes),
                  let withReferences = checkedAdd(withDefinitions, referenceBytes)
            else { return .failure(.accountingOverflow) }
            byteCount = withReferences
        }
        for (name, fileIDs) in definitions.merging(references, uniquingKeysWith: +) {
            guard !Task.isCancelled else { return .cancelled }
            guard let nameBytes = UInt64(exactly: name.utf8.count),
                  let fileIDBytes = checkedMultiply(UInt64(fileIDs.count), 16),
                  let withPosting = checkedAdd(byteCount, 64),
                  let withName = checkedAdd(withPosting, nameBytes),
                  let withFileIDs = checkedAdd(withName, fileIDBytes)
            else { return .failure(.accountingOverflow) }
            byteCount = withFileIDs
        }
        for evidence in outgoing.values.flatMap(\.self) + reverse.values.flatMap(\.self) {
            guard !Task.isCancelled else { return .cancelled }
            guard let nameBytes = checkedStringBytes(evidence.matchedNames),
                  let withEvidence = checkedAdd(byteCount, 128),
                  let withNames = checkedAdd(withEvidence, nameBytes)
            else { return .failure(.accountingOverflow) }
            byteCount = withNames
        }
        for record in unresolved.values.flatMap(\.self) {
            guard !Task.isCancelled else { return .cancelled }
            guard let nameBytes = UInt64(exactly: record.referencedName.utf8.count),
                  let withRecord = checkedAdd(byteCount, 96),
                  let withName = checkedAdd(withRecord, nameBytes)
            else { return .failure(.accountingOverflow) }
            byteCount = withName
        }
        guard let edgeBytes = checkedMultiply(edgeCount, 96),
              let postingBytes = checkedMultiply(postingCount, 24),
              let withEdges = checkedAdd(byteCount, edgeBytes),
              let totalBytes = checkedAdd(withEdges, postingBytes),
              let nodeCount = UInt64(exactly: nodes.count)
        else { return .failure(.accountingOverflow) }
        byteCount = totalBytes
        let size = WorkspaceCodemapGraphSizeAccounting(
            nodes: nodeCount,
            postings: postingCount,
            edges: edgeCount,
            bytes: byteCount
        )
        let limits = graphPolicy.graphSizePolicy
        if size.nodes > limits.maxNodes { return .failure(.graphSize(.limitExceeded(dimension: .nodes, attempted: size.nodes, limit: limits.maxNodes))) }
        if size.postings > limits.maxPostings { return .failure(.graphSize(.limitExceeded(dimension: .postings, attempted: size.postings, limit: limits.maxPostings))) }
        if size.edges > limits.maxEdges { return .failure(.graphSize(.limitExceeded(dimension: .edges, attempted: size.edges, limit: limits.maxEdges))) }
        if size.bytes > limits.maxBytes { return .failure(.graphSize(.limitExceeded(dimension: .bytes, attempted: size.bytes, limit: limits.maxBytes))) }

        let snapshot = WorkspaceCodemapGraphCommittedSnapshot(
            snapshotID: UUID(),
            graphRevision: nextRevision,
            rootEpoch: rootEpoch,
            repositoryAuthority: authority,
            catalogWatermark: watermark,
            coverage: coverage,
            appliedGeneration: generation,
            schemaVersion: schemaVersion,
            policyVersion: policyVersion,
            slotsByFileID: slots,
            nodesByFileID: nodes,
            definitionPostings: definitions,
            referencePostings: references,
            outgoingEdgesBySource: outgoing,
            reverseEdgesByTarget: reverse,
            unresolvedBySource: unresolved,
            sizeAccounting: size
        )
        return .success(CandidateBuild(
            snapshot: snapshot,
            changedFileCount: changedIDs.count,
            affectedSourceCount: affectedSources.count,
            resync: resync
        ))
    }

    private static func snapshotNode(
        from slot: WorkspaceCodemapGraphSlot
    ) -> WorkspaceCodemapGraphSnapshotNode? {
        guard let contribution = slot.state.contribution else { return nil }
        return WorkspaceCodemapGraphSnapshotNode(
            fileID: slot.fileID,
            standardizedRelativePath: slot.standardizedRelativePath,
            requestGeneration: slot.requestGeneration,
            pathGeneration: slot.pathGeneration,
            contribution: contribution
        )
    }

    private static func checkedAdd(_ lhs: UInt64?, _ rhs: UInt64?) -> UInt64? {
        guard let lhs, let rhs else { return nil }
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : result
    }

    private static func checkedMultiply(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? nil : result
    }

    private static func checkedCount<S: Sequence>(_ values: S) -> UInt64?
        where S.Element: Collection
    {
        var result: UInt64 = 0
        for value in values {
            guard let count = UInt64(exactly: value.count), let next = checkedAdd(result, count) else { return nil }
            result = next
        }
        return result
    }

    private static func checkedStringBytes(_ strings: [String]) -> UInt64? {
        var result: UInt64 = 0
        for string in strings {
            guard let count = UInt64(exactly: string.utf8.count),
                  let withPayload = checkedAdd(result, count),
                  let withOverhead = checkedAdd(withPayload, 16)
            else { return nil }
            result = withOverhead
        }
        return result
    }

    private static func fileIDPrecedes(
        _ lhs: UUID,
        _ rhs: UUID,
        snapshot: WorkspaceCodemapGraphCommittedSnapshot
    ) -> Bool {
        fileIDPrecedes(lhs, rhs, nodes: snapshot.nodesByFileID)
    }

    private static func fileIDPrecedes(
        _ lhs: UUID,
        _ rhs: UUID,
        nodes: [UUID: WorkspaceCodemapGraphSnapshotNode]
    ) -> Bool {
        let left = nodes[lhs]?.standardizedRelativePath ?? ""
        let right = nodes[rhs]?.standardizedRelativePath ?? ""
        if left != right { return utf8Precedes(left, right) }
        return lhs.uuidString < rhs.uuidString
    }

    private static func edgePrecedes(
        _ lhs: WorkspaceCodemapGraphEdgeEvidence,
        _ rhs: WorkspaceCodemapGraphEdgeEvidence,
        nodes: [UUID: WorkspaceCodemapGraphSnapshotNode]
    ) -> Bool {
        if lhs.sourceFileID != rhs.sourceFileID { return fileIDPrecedes(lhs.sourceFileID, rhs.sourceFileID, nodes: nodes) }
        if lhs.targetFileID != rhs.targetFileID { return fileIDPrecedes(lhs.targetFileID, rhs.targetFileID, nodes: nodes) }
        return lhs.matchedNames.lexicographicallyPrecedes(rhs.matchedNames, by: utf8Precedes)
    }

    private static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

private extension WorkspaceCodemapGraphSlotState {
    var contribution: CodeMapSelectionGraphContribution? {
        switch self {
        case let .contributed(value), let .empty(value): value
        case .pending, .terminalArtifact, .terminalExcluded: nil
        }
    }
}
