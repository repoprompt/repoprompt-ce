import Foundation

actor WorkspaceCodemapSelectionGraph {
    private let rootEpoch: WorkspaceCodemapRootEpoch
    private let policy: WorkspaceCodemapSelectionGraphRuntimePolicy
    private let admission: CodeMapSelectionGraphAdmission
    private let diagnostics: WorkspaceCodemapSelectionGraphRuntimeDiagnostics
    private let processAdmissionWaitHook: @Sendable () async -> Void

    private var observedKey: WorkspaceCodemapSelectionGraphRuntimeKey?
    private var observationSerial: UInt64 = 0
    private var nextOperationID: UInt64 = 0
    private var latestOperationID: UInt64?
    private var publishedShard: ImmutableShard?
    private var stagedProjection: StagedProjection?
    private var projectionCoverage: WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage?
    private var residentProjectionByteCount: UInt64 = 0
    private var activeOperations: [UInt64: ActiveOperation] = [:]
    private var activeRebuildCount = 0
    private var reservedInputBindingCount = 0
    private var lastUnavailableReason: WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason?
    private var revokedReason: WorkspaceCodemapSelectionGraphRuntimeExternalUnavailableReason?
    private var hasCurrentnessConflict = false

    private var publishedCount: UInt64 = 0
    private var emptyPublishedCount: UInt64 = 0
    private var actorBusyCount: UInt64 = 0
    private var processBusyCount: UInt64 = 0
    private var cancelledCount: UInt64 = 0
    private var budgetRejectedCount: UInt64 = 0
    private var invalidSnapshotCount: UInt64 = 0
    private var supersededPublicationCount: UInt64 = 0
    private var materializedQueryResultCount: UInt64 = 0
    private var acceptedProjectionSegmentCount: UInt64 = 0
    private var exactDuplicateProjectionSegmentCount: UInt64 = 0
    private var rejectedProjectionSegmentCount: UInt64 = 0
    private var completedProjectionCoverageCount: UInt64 = 0
    private var revokedProjectionCoverageCount: UInt64 = 0

    init(
        rootEpoch: WorkspaceCodemapRootEpoch,
        policy: WorkspaceCodemapSelectionGraphRuntimePolicy = .initial,
        admission: CodeMapSelectionGraphAdmission = .processWide,
        diagnostics: WorkspaceCodemapSelectionGraphRuntimeDiagnostics = .none,
        processAdmissionWaitHook: @escaping @Sendable () async -> Void = {}
    ) {
        self.rootEpoch = rootEpoch
        self.policy = policy
        self.admission = admission
        self.diagnostics = diagnostics
        self.processAdmissionWaitHook = processAdmissionWaitHook
    }

    func waitForProcessAdmissionAvailability(bindingCount: Int) async {
        guard !Task.isCancelled else { return }
        await processAdmissionWaitHook()
        guard !Task.isCancelled else { return }
        await admission.waitForAvailability(bindingCount: bindingCount)
    }

    func observeDesiredKey(_ key: WorkspaceCodemapSelectionGraphRuntimeKey) -> Bool {
        guard key.rootEpoch == rootEpoch, revokedReason == nil else { return false }
        if let current = observedKey {
            if key.contributionGeneration < current.contributionGeneration {
                return false
            }
            if key.contributionGeneration == current.contributionGeneration {
                guard key == current, !hasCurrentnessConflict else {
                    lastUnavailableReason = .invalidSnapshot
                    hasCurrentnessConflict = true
                    increment(&invalidSnapshotCount)
                    _ = advanceObservationSerial()
                    for operation in activeOperations.values {
                        operation.task.cancel()
                    }
                    return false
                }
                return true
            }
        }

        guard advanceObservationSerial() else { return false }
        revokeProjectionState(clearPublishedShard: false)
        observedKey = key
        lastUnavailableReason = .rebuilding
        hasCurrentnessConflict = false
        latestOperationID = nil
        for operation in activeOperations.values {
            operation.task.cancel()
        }
        return true
    }

    func rebuild(
        from snapshot: WorkspaceCodemapLiveGraphSnapshot
    ) async -> WorkspaceCodemapSelectionGraphRuntimeRebuildDisposition {
        let key = WorkspaceCodemapSelectionGraphRuntimeKey(snapshot: snapshot)
        guard !Task.isCancelled else { return .cancelled(key) }
        guard snapshot.rootEpoch == rootEpoch else {
            return .rejected(key, .rootEpochMismatch)
        }
        if let revokedReason {
            return .rejected(key, .rootUnavailable(revokedReason))
        }
        if let current = observedKey {
            if key.contributionGeneration < current.contributionGeneration {
                return .rejected(
                    key,
                    .staleSnapshot(
                        received: key.contributionGeneration,
                        current: current.contributionGeneration
                    )
                )
            }
            if key.contributionGeneration == current.contributionGeneration {
                if key != current {
                    lastUnavailableReason = .invalidSnapshot
                    hasCurrentnessConflict = true
                    increment(&invalidSnapshotCount)
                    _ = advanceObservationSerial()
                    for operation in activeOperations.values {
                        operation.task.cancel()
                    }
                    return .rejected(key, .equalGenerationAuthorityConflict)
                }
                if hasCurrentnessConflict {
                    return .rejected(key, .equalGenerationAuthorityConflict)
                }
            }
        }

        if let duplicateReason = Self.duplicateIdentityReason(in: snapshot) {
            if observedKey == key {
                lastUnavailableReason = .invalidSnapshot
                hasCurrentnessConflict = true
                increment(&invalidSnapshotCount)
                _ = advanceObservationSerial()
                for operation in activeOperations.values {
                    operation.task.cancel()
                }
            }
            return .rejected(key, .invalidSnapshot(duplicateReason))
        }

        if observedKey == key, projectionCoverage != nil {
            // Projection staging/sealing owns this exact generation. A live-overlay freeze may
            // still serve structure from an older shard, but it cannot downgrade or race the
            // normalized projection state.
            return .superseded(key)
        }

        if observedKey != key {
            guard advanceObservationSerial() else {
                return .rejected(key, .rootUnavailable(.authorityRevoked))
            }
            revokeProjectionState(clearPublishedShard: false)
            observedKey = key
            lastUnavailableReason = nil
            hasCurrentnessConflict = false
        }
        let operationObservationSerial = observationSerial

        guard snapshot.bindings.count <= policy.maximumInputBindingCount else {
            lastUnavailableReason = .budgetExceeded
            increment(&budgetRejectedCount)
            return .rejected(
                key,
                .inputBindingLimit(
                    attempted: snapshot.bindings.count,
                    limit: policy.maximumInputBindingCount
                )
            )
        }

        guard activeRebuildCount < policy.maximumActiveRebuildCount else {
            let reason = WorkspaceCodemapSelectionGraphRuntimeBusyReason.actorActiveRebuildLimit
            lastUnavailableReason = .actorAdmissionRejected(reason)
            increment(&actorBusyCount)
            return .busy(key, reason)
        }
        let (nextReservedCount, reservedOverflow) = reservedInputBindingCount.addingReportingOverflow(
            snapshot.bindings.count
        )
        guard !reservedOverflow else {
            lastUnavailableReason = .budgetExceeded
            increment(&budgetRejectedCount)
            return .rejected(key, .accountingOverflow)
        }
        guard nextReservedCount <= policy.maximumReservedBindingCount else {
            let reason = WorkspaceCodemapSelectionGraphRuntimeBusyReason.actorReservedBindingLimit
            lastUnavailableReason = .actorAdmissionRejected(reason)
            increment(&actorBusyCount)
            return .busy(key, reason)
        }

        let permit: CodeMapSelectionGraphAdmissionPermit
        do {
            permit = try admission.reserve(bindingCount: snapshot.bindings.count)
        } catch let CodeMapSelectionGraphAdmissionError.busy(reason) {
            lastUnavailableReason = .processAdmissionRejected(reason)
            increment(&processBusyCount)
            return .busy(key, .processAdmission(reason))
        } catch {
            lastUnavailableReason = .budgetExceeded
            increment(&budgetRejectedCount)
            return .rejected(key, .accountingOverflow)
        }

        guard let operationID = issueOperationID() else {
            permit.close()
            lastUnavailableReason = .budgetExceeded
            increment(&budgetRejectedCount)
            return .rejected(key, .accountingOverflow)
        }
        activeRebuildCount += 1
        reservedInputBindingCount = nextReservedCount
        latestOperationID = operationID
        if publishedShard?.key != key {
            lastUnavailableReason = .rebuilding
        }

        let sizePolicy = policy.graphSizePolicy
        let operationDiagnostics = diagnostics
        let task = Task.detached(priority: .utility) {
            operationDiagnostics.handle(.init(
                operationID: operationID,
                key: key,
                kind: .buildStarted
            ))
            let output = Self.buildShard(snapshot: snapshot, key: key, sizePolicy: sizePolicy)
            guard case .success = output else { return output }
            guard !Task.isCancelled else { return .cancelled }
            operationDiagnostics.handle(.init(
                operationID: operationID,
                key: key,
                kind: .beforePublication
            ))
            return Task.isCancelled ? .cancelled : output
        }
        activeOperations[operationID] = ActiveOperation(key: key, task: task)

        let output = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        activeOperations.removeValue(forKey: operationID)
        activeRebuildCount -= 1
        reservedInputBindingCount -= snapshot.bindings.count
        permit.close()

        if Task.isCancelled || output == .cancelled {
            if observedKey == key, publishedShard?.key != key {
                lastUnavailableReason = .cancelled
            }
            increment(&cancelledCount)
            return .cancelled(key)
        }

        guard revokedReason == nil,
              !hasCurrentnessConflict,
              operationObservationSerial == observationSerial,
              observedKey == key,
              latestOperationID == operationID
        else {
            increment(&supersededPublicationCount)
            return .superseded(key)
        }

        switch output {
        case let .success(shard):
            publishedShard = shard
            projectionCoverage = nil
            residentProjectionByteCount = 0
            lastUnavailableReason = nil
            if shard.summary.isEmpty {
                increment(&emptyPublishedCount)
                return .publishedEmpty(shard.summary)
            }
            increment(&publishedCount)
            return .published(shard.summary)
        case let .rejected(reason):
            recordRejection(reason, key: key)
            return .rejected(key, reason)
        case .cancelled:
            increment(&cancelledCount)
            lastUnavailableReason = .cancelled
            return .cancelled(key)
        }
    }

    func applyProjectionSnapshot(
        _ snapshot: WorkspaceCodemapProjectionSnapshot
    ) async -> WorkspaceCodemapProjectionSnapshotDisposition {
        guard !Task.isCancelled else { return .superseded }
        return switch snapshot {
        case let .segment(segment):
            stageProjectionSegment(segment)
        case let .seal(proof):
            await sealProjection(proof)
        }
    }

    func applyEquivalentProjectionSuccessor(
        _ seal: WorkspaceCodemapProjectionSuccessorSeal,
        liveSnapshot: WorkspaceCodemapLiveGraphSnapshot
    ) -> WorkspaceCodemapProjectionSnapshotDisposition {
        guard !Task.isCancelled else { return .superseded }
        let predecessor = seal.predecessorProof
        let successor = seal.successorProof
        let predecessorKey = WorkspaceCodemapSelectionGraphRuntimeKey(generation: predecessor.generation)
        let successorKey = WorkspaceCodemapSelectionGraphRuntimeKey(generation: successor.generation)
        guard predecessor.generation.rootEpoch == rootEpoch,
              successor.generation.rootEpoch == rootEpoch,
              predecessor.successor(
                  contributionGeneration: liveSnapshot.contributionGeneration
              ) == successor,
              successorKey == WorkspaceCodemapSelectionGraphRuntimeKey(snapshot: liveSnapshot)
        else { return .stale }
        if case let .complete(currentProof, _, _, _)? = projectionCoverage,
           currentProof == successor,
           observedKey == successorKey,
           publishedShard?.key == successorKey,
           revokedReason == nil,
           !hasCurrentnessConflict
        {
            return .exactDuplicate(completedProgress(proof: successor, previous: .notStarted))
        }
        guard revokedReason == nil,
              !hasCurrentnessConflict,
              activeOperations.isEmpty,
              stagedProjection == nil,
              observedKey == predecessorKey,
              case let .complete(currentProof, _, _, _)? = projectionCoverage,
              currentProof == predecessor,
              let shard = publishedShard,
              shard.key == predecessorKey,
              let projectionFingerprints = shard.projectionFingerprintsByFileID,
              liveSnapshot.bindings.count <= policy.maximumInputBindingCount
        else { return .superseded }

        let bindings: [WorkspaceCodemapArtifactBinding]
        do {
            bindings = try Self.validatedSortedBindings(
                snapshot: liveSnapshot,
                key: successorKey
            )
        } catch {
            return .superseded
        }
        let bindingFileIDs = Set(bindings.map(\.identity.fileID))
        guard !bindings.isEmpty,
              bindings.count == projectionFingerprints.count,
              bindingFileIDs.count == bindings.count,
              bindingFileIDs == Set(projectionFingerprints.keys),
              bindings.allSatisfy({ binding in
                  guard let fingerprint = Self.projectionShardFingerprint(for: binding) else {
                      return false
                  }
                  return projectionFingerprints[binding.identity.fileID] == fingerprint
              })
        else { return .superseded }

        guard advanceObservationSerial() else { return .superseded }
        latestOperationID = nil
        observedKey = successorKey
        let coverage = WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage.complete(
            proof: successor,
            candidateCount: successor.candidateCount,
            contributedCount: successor.contributedCount,
            terminalCount: successor.terminalCount
        )
        projectionCoverage = coverage
        publishedShard = shard.replacingKey(successorKey, coverage: coverage)
        lastUnavailableReason = nil
        increment(&completedProjectionCoverageCount)
        emitProjectionDiagnostic(key: successorKey, kind: .projectionCoverageSealed)
        return .accepted(completedProgress(proof: successor, previous: .notStarted))
    }

    private static func duplicateIdentityReason(
        in snapshot: WorkspaceCodemapLiveGraphSnapshot
    ) -> WorkspaceCodemapSelectionGraphRuntimeValidationReason? {
        var fileIDs = Set<UUID>()
        var relativePaths = Set<String>()
        for binding in snapshot.bindings {
            if !fileIDs.insert(binding.identity.fileID).inserted {
                return .duplicateFileID
            }
            if !relativePaths.insert(binding.identity.standardizedRelativePath).inserted {
                return .duplicateRelativePath
            }
        }
        return nil
    }

    private func stageProjectionSegment(
        _ segment: WorkspaceCodemapProjectionSegment
    ) -> WorkspaceCodemapProjectionSnapshotDisposition {
        let generation = segment.generation
        let key = WorkspaceCodemapSelectionGraphRuntimeKey(generation: generation)
        guard generation.rootEpoch == rootEpoch else { return .stale }
        if let revokedReason {
            return .unavailable(unavailableReason(for: revokedReason))
        }
        if stagedProjection == nil,
           let terminalDisposition = terminalProjectionDisposition(for: key)
        {
            return terminalDisposition
        }
        guard prepareProjectionGeneration(generation) else {
            increment(&rejectedProjectionSegmentCount)
            return projectionGenerationDisposition(for: generation)
        }

        let normalizedSegmentBytes: UInt64
        switch WorkspaceCodemapSelectionGraphProjectionByteAccounting.normalizedByteCount(
            entries: segment.entries
        ) {
        case let .success(bytes):
            normalizedSegmentBytes = max(bytes, segment.byteCount)
        case .failure:
            setProjectionCoverage(.unavailable(.accountingOverflow), key: key)
            increment(&rejectedProjectionSegmentCount)
            return .unavailable(.accountingOverflow)
        }
        guard normalizedSegmentBytes <= policy.maximumProjectionSegmentByteCount else {
            let coverage = WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage.budget(
                dimension: .retainedProjectionBytes,
                attempted: normalizedSegmentBytes,
                limit: policy.maximumProjectionSegmentByteCount
            )
            setProjectionCoverage(coverage, key: key)
            increment(&budgetRejectedCount)
            increment(&rejectedProjectionSegmentCount)
            return .budget(
                dimension: .retainedProjectionBytes,
                attempted: normalizedSegmentBytes,
                limit: policy.maximumProjectionSegmentByteCount
            )
        }

        var staging = stagedProjection ?? StagedProjection(
            generation: generation,
            progress: .notStarted
        )
        guard staging.generation == generation else {
            markProjectionInvalid(key: key, reason: .corrupt)
            increment(&rejectedProjectionSegmentCount)
            return .unavailable(.corrupt)
        }

        let fingerprints = segment.entries.map(ProjectionEntryFingerprint.init).sorted()
        if let existing = staging.segmentReceipts[segment.sequence] {
            let receipt = ProjectionSegmentReceipt(
                sequence: segment.sequence,
                fingerprints: fingerprints,
                progress: segment.progress,
                declaredByteCount: segment.byteCount
            )
            guard existing == receipt else {
                markProjectionInvalid(key: key, reason: .corrupt)
                increment(&rejectedProjectionSegmentCount)
                return .unavailable(.corrupt)
            }
            increment(&exactDuplicateProjectionSegmentCount)
            return .exactDuplicate(staging.progress)
        }

        guard segment.sequence == staging.nextSequence else {
            if segment.sequence > staging.nextSequence {
                let coverage = WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage.busy(
                    progress: staging.progress,
                    retryAfterMilliseconds: nil
                )
                setProjectionCoverage(coverage, key: key)
                return .busy(retryAfterMilliseconds: nil)
            }
            markProjectionInvalid(key: key, reason: .corrupt)
            increment(&rejectedProjectionSegmentCount)
            return .unavailable(.corrupt)
        }

        guard let expectedPublishedCount = incrementing(segment.sequence),
              segment.progress.publishedSegmentCount == expectedPublishedCount,
              progressIsMonotonic(segment.progress, after: staging.progress),
              progressCountsAreInternallyConsistent(segment.progress.counts),
              segment.progress.phase != .complete,
              segment.progress.catalogCompletion?.token == nil ||
              segment.progress.catalogCompletion?.token == generation.catalogToken
        else {
            markProjectionInvalid(key: key, reason: .corrupt)
            increment(&rejectedProjectionSegmentCount)
            return .unavailable(.corrupt)
        }
        let (expectedPublishedBytes, publishedByteOverflow) = staging.progress
            .publishedSegmentByteCount.addingReportingOverflow(segment.byteCount)
        guard !publishedByteOverflow,
              segment.progress.publishedSegmentByteCount == expectedPublishedBytes
        else {
            markProjectionInvalid(key: key, reason: .accountingOverflow)
            increment(&rejectedProjectionSegmentCount)
            return .unavailable(.accountingOverflow)
        }

        var newEntries: [WorkspaceCodemapProjectionEntry] = []
        var seenPaths = staging.fileIDByRelativePath
        for entry in segment.entries {
            if let existing = staging.entriesByFileID[entry.identity.fileID] {
                guard existing == entry else {
                    markProjectionInvalid(key: key, reason: .corrupt)
                    increment(&rejectedProjectionSegmentCount)
                    return .unavailable(.corrupt)
                }
                continue
            }
            if let existingFileID = seenPaths[entry.identity.standardizedRelativePath],
               existingFileID != entry.identity.fileID
            {
                markProjectionInvalid(key: key, reason: .corrupt)
                increment(&rejectedProjectionSegmentCount)
                return .unavailable(.corrupt)
            }
            seenPaths[entry.identity.standardizedRelativePath] = entry.identity.fileID
            newEntries.append(entry)
        }

        let retainedDelta: UInt64
        switch WorkspaceCodemapSelectionGraphProjectionByteAccounting.normalizedByteCount(
            entries: newEntries
        ) {
        case let .success(bytes):
            retainedDelta = bytes
        case .failure:
            markProjectionInvalid(key: key, reason: .accountingOverflow)
            increment(&rejectedProjectionSegmentCount)
            return .unavailable(.accountingOverflow)
        }
        let (attemptedStagedBytes, stagedByteOverflow) = staging.byteCount.addingReportingOverflow(
            retainedDelta
        )
        guard !stagedByteOverflow else {
            markProjectionInvalid(key: key, reason: .accountingOverflow)
            increment(&rejectedProjectionSegmentCount)
            return .unavailable(.accountingOverflow)
        }
        guard attemptedStagedBytes <= policy.maximumStagedProjectionByteCount else {
            stagedProjection = nil
            let coverage = WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage.budget(
                dimension: .stagedGraphBytes,
                attempted: attemptedStagedBytes,
                limit: policy.maximumStagedProjectionByteCount
            )
            setProjectionCoverage(coverage, key: key)
            increment(&budgetRejectedCount)
            increment(&rejectedProjectionSegmentCount)
            return .budget(
                dimension: .stagedGraphBytes,
                attempted: attemptedStagedBytes,
                limit: policy.maximumStagedProjectionByteCount
            )
        }

        for entry in newEntries {
            staging.entriesByFileID[entry.identity.fileID] = entry
        }
        staging.fileIDByRelativePath = seenPaths
        staging.byteCount = attemptedStagedBytes
        staging.progress = segment.progress
        staging.segmentReceipts[segment.sequence] = ProjectionSegmentReceipt(
            sequence: segment.sequence,
            fingerprints: fingerprints,
            progress: segment.progress,
            declaredByteCount: segment.byteCount
        )
        staging.nextSequence = expectedPublishedCount
        stagedProjection = staging

        guard stagedCountsMatchProgress(staging) else {
            markProjectionInvalid(key: key, reason: .invalidCompletenessProof)
            increment(&rejectedProjectionSegmentCount)
            return .unavailable(.invalidCompletenessProof)
        }
        let remainingCount = projectionRemainingCount(segment.progress)
        let coverage = WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage.incomplete(
            progress: segment.progress,
            remainingCount: remainingCount,
            retry: nil
        )
        setProjectionCoverage(coverage, key: key)
        increment(&acceptedProjectionSegmentCount)
        emitProjectionDiagnostic(key: key, kind: .projectionSegmentAccepted)
        return .accepted(segment.progress)
    }

    private func sealProjection(
        _ proof: WorkspaceCodemapProjectionCoverageProof
    ) async -> WorkspaceCodemapProjectionSnapshotDisposition {
        let generation = proof.generation
        let key = WorkspaceCodemapSelectionGraphRuntimeKey(generation: generation)
        guard generation.rootEpoch == rootEpoch else { return .stale }
        if let revokedReason {
            return .unavailable(unavailableReason(for: revokedReason))
        }
        if case let .complete(existingProof, _, _, _)? = projectionCoverage,
           existingProof == proof,
           publishedShard?.key == key
        {
            return .exactDuplicate(completedProgress(proof: proof, previous: .notStarted))
        }
        if stagedProjection == nil,
           let terminalDisposition = terminalProjectionDisposition(for: key)
        {
            return terminalDisposition
        }
        guard prepareProjectionGeneration(generation) else {
            return projectionGenerationDisposition(for: generation)
        }

        var staging = stagedProjection
        if staging == nil, proof.candidateCount == 0, proof.lastSegmentSequence == nil {
            staging = StagedProjection(generation: generation, progress: .notStarted)
            stagedProjection = staging
        }
        guard let staging,
              staging.generation == generation,
              sealMatchesStaging(proof, staging: staging)
        else {
            markProjectionInvalid(key: key, reason: .invalidCompletenessProof)
            return .unavailable(.invalidCompletenessProof)
        }

        let nodeEntryCount = staging.entriesByFileID.values.reduce(into: 0) { count, entry in
            switch entry.outcome {
            case .contributed, .empty:
                count += 1
            case .terminalArtifact, .terminalExcluded:
                break
            }
        }
        guard activeRebuildCount < policy.maximumActiveRebuildCount else {
            let coverage = WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage.busy(
                progress: staging.progress,
                retryAfterMilliseconds: nil
            )
            setProjectionCoverage(coverage, key: key)
            increment(&actorBusyCount)
            return .busy(retryAfterMilliseconds: nil)
        }
        let (nextReservedCount, reservedOverflow) = reservedInputBindingCount.addingReportingOverflow(
            nodeEntryCount
        )
        guard !reservedOverflow else {
            markProjectionInvalid(key: key, reason: .accountingOverflow)
            return .unavailable(.accountingOverflow)
        }
        guard nextReservedCount <= policy.maximumReservedBindingCount else {
            let coverage = WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage.busy(
                progress: staging.progress,
                retryAfterMilliseconds: nil
            )
            setProjectionCoverage(coverage, key: key)
            increment(&actorBusyCount)
            return .busy(retryAfterMilliseconds: nil)
        }

        let permit: CodeMapSelectionGraphAdmissionPermit
        do {
            permit = try admission.reserve(bindingCount: nodeEntryCount)
        } catch let CodeMapSelectionGraphAdmissionError.busy(reason) {
            let coverage = WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage.busy(
                progress: staging.progress,
                retryAfterMilliseconds: nil
            )
            setProjectionCoverage(coverage, key: key)
            lastUnavailableReason = .processAdmissionRejected(reason)
            increment(&processBusyCount)
            return .busy(retryAfterMilliseconds: nil)
        } catch {
            markProjectionInvalid(key: key, reason: .accountingOverflow)
            return .unavailable(.accountingOverflow)
        }

        guard let operationID = issueOperationID() else {
            permit.close()
            markProjectionInvalid(key: key, reason: .accountingOverflow)
            return .unavailable(.accountingOverflow)
        }
        activeRebuildCount += 1
        reservedInputBindingCount = nextReservedCount
        latestOperationID = operationID
        let operationObservationSerial = observationSerial
        let entries = Array(staging.entriesByFileID.values)
        let sizePolicy = policy.graphSizePolicy
        let operationDiagnostics = diagnostics
        let task = Task.detached(priority: .utility) {
            operationDiagnostics.handle(.init(operationID: operationID, key: key, kind: .buildStarted))
            let output = Self.buildProjectionShard(
                entries: entries,
                proof: proof,
                key: key,
                sizePolicy: sizePolicy
            )
            guard case .success = output else { return output }
            guard !Task.isCancelled else { return .cancelled }
            operationDiagnostics.handle(.init(
                operationID: operationID,
                key: key,
                kind: .beforePublication
            ))
            return Task.isCancelled ? .cancelled : output
        }
        activeOperations[operationID] = ActiveOperation(key: key, task: task)
        let output = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        activeOperations.removeValue(forKey: operationID)
        activeRebuildCount -= 1
        reservedInputBindingCount -= nodeEntryCount
        permit.close()

        guard !Task.isCancelled else { return .superseded }
        guard revokedReason == nil,
              !hasCurrentnessConflict,
              operationObservationSerial == observationSerial,
              observedKey == key,
              latestOperationID == operationID,
              let currentStaging = stagedProjection,
              currentStaging.generation == generation,
              sealMatchesStaging(proof, staging: currentStaging)
        else {
            increment(&supersededPublicationCount)
            return .superseded
        }

        switch output {
        case let .success(shard):
            publishedShard = shard
            stagedProjection = nil
            let coverage = WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage.complete(
                proof: proof,
                candidateCount: proof.candidateCount,
                contributedCount: proof.contributedCount,
                terminalCount: proof.terminalCount
            )
            projectionCoverage = coverage
            residentProjectionByteCount = shard.summary.sizeAccounting.bytes
            lastUnavailableReason = nil
            increment(&completedProjectionCoverageCount)
            if shard.summary.isEmpty {
                increment(&emptyPublishedCount)
            } else {
                increment(&publishedCount)
            }
            emitProjectionDiagnostic(key: key, kind: .projectionCoverageSealed)
            return .accepted(completedProgress(proof: proof, previous: staging.progress))
        case let .rejected(.graphSize(rejection)):
            stagedProjection = nil
            switch rejection {
            case .arithmeticOverflow:
                markProjectionInvalid(key: key, reason: .accountingOverflow)
                return .unavailable(.accountingOverflow)
            case let .limitExceeded(dimension, attempted, limit):
                let budgetDimension = WorkspaceCodemapProjectionBudgetDimension.residentGraph(
                    dimension
                )
                let coverage = WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage.budget(
                    dimension: budgetDimension,
                    attempted: attempted,
                    limit: limit
                )
                setProjectionCoverage(coverage, key: key)
                increment(&budgetRejectedCount)
                return .budget(
                    dimension: budgetDimension,
                    attempted: attempted,
                    limit: limit
                )
            }
        case .rejected:
            markProjectionInvalid(key: key, reason: .corrupt)
            return .unavailable(.corrupt)
        case .cancelled:
            increment(&cancelledCount)
            return .superseded
        }
    }

    func query(
        _ query: WorkspaceCodemapSelectionGraphRuntimeQuery
    ) -> WorkspaceCodemapSelectionGraphRuntimeQueryDisposition {
        if let revokedReason {
            return .unavailable(.explicitRootUnavailable(revokedReason))
        }
        guard let observedKey else { return .unavailable(.notBuilt) }
        guard query.key == observedKey else {
            return .unavailable(.staleCurrentness(currentKey: observedKey))
        }
        guard !hasCurrentnessConflict else { return .unavailable(.invalidSnapshot) }
        if let coverage = effectiveProjectionCoverage(for: observedKey),
           !coverage.isCompleteForRuntimeKey(observedKey)
        {
            return .definitionUniverse(coverage)
        }
        if let shard = publishedShard, shard.key == observedKey {
            guard shard.summary.definitionUniverseCoverage.isCompleteForRuntimeKey(observedKey) else {
                return .definitionUniverse(shard.summary.definitionUniverseCoverage)
            }
            return queryShard(query, in: shard)
        }
        if activeOperations.values.contains(where: { $0.key == observedKey }) {
            return .unavailable(.rebuilding)
        }
        return .unavailable(lastUnavailableReason ?? .notBuilt)
    }

    func queryStructure(
        _ query: WorkspaceCodemapSelectionGraphRuntimeStructureQuery
    ) -> WorkspaceCodemapSelectionGraphRuntimeStructureDisposition {
        if Task.isCancelled { return .unavailable(.cancelled) }
        if let revokedReason {
            return .unavailable(.explicitRootUnavailable(revokedReason))
        }
        guard let observedKey else { return .unavailable(.notBuilt) }
        guard query.key == observedKey else {
            return .unavailable(.staleCurrentness(currentKey: observedKey))
        }
        guard !hasCurrentnessConflict else { return .unavailable(.invalidSnapshot) }
        if let coverage = effectiveProjectionCoverage(for: observedKey),
           !coverage.isCompleteForRuntimeKey(observedKey)
        {
            return .definitionUniverse(coverage)
        }
        if let shard = publishedShard, shard.key == observedKey {
            let coverage = effectiveProjectionCoverage(for: observedKey)
                ?? shard.summary.definitionUniverseCoverage
            guard coverage.isCompleteForRuntimeKey(observedKey) else {
                return .definitionUniverse(coverage)
            }
            return queryStructureShard(query, in: shard.replacingCoverage(coverage))
        }
        if activeOperations.values.contains(where: { $0.key == observedKey }) {
            return .unavailable(.rebuilding)
        }
        return .unavailable(lastUnavailableReason ?? .notBuilt)
    }

    func fenceContributionsForPathInvalidation(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> Bool {
        guard rootEpoch == self.rootEpoch, revokedReason == nil else { return false }
        observedKey = nil
        publishedShard = nil
        revokeProjectionState(clearPublishedShard: true)
        latestOperationID = nil
        lastUnavailableReason = .rebuilding
        hasCurrentnessConflict = false
        advanceObservationSerial()
        for operation in activeOperations.values {
            operation.task.cancel()
        }
        return true
    }

    func invalidateCurrentness(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapSelectionGraphRuntimeExternalUnavailableReason
    ) -> Bool {
        guard rootEpoch == self.rootEpoch, revokedReason == nil else { return false }
        revokedReason = reason
        lastUnavailableReason = .explicitRootUnavailable(reason)
        publishedShard = nil
        revokeProjectionState(clearPublishedShard: true)
        advanceObservationSerial()
        for operation in activeOperations.values {
            operation.task.cancel()
        }
        return true
    }

    func accounting() -> WorkspaceCodemapSelectionGraphRuntimeAccounting {
        let unavailableReason: WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason? = if let revokedReason {
            .explicitRootUnavailable(revokedReason)
        } else if hasCurrentnessConflict {
            .invalidSnapshot
        } else if let projectionCoverage {
            switch projectionCoverage {
            case .complete:
                nil
            case .incomplete:
                .rebuilding
            case .busy:
                .rebuilding
            case .budget:
                .budgetExceeded
            case .unavailable:
                .invalidSnapshot
            }
        } else if publishedShard?.key == observedKey {
            nil
        } else if let observedKey,
                  activeOperations.values.contains(where: { $0.key == observedKey })
        {
            .rebuilding
        } else {
            lastUnavailableReason
        }
        return WorkspaceCodemapSelectionGraphRuntimeAccounting(
            activeRebuildCount: activeRebuildCount,
            reservedInputBindingCount: reservedInputBindingCount,
            publishedSummary: publishedShard?.summary,
            currentObservedKey: observedKey,
            currentUnavailableReason: unavailableReason,
            publishedCount: publishedCount,
            emptyPublishedCount: emptyPublishedCount,
            actorBusyCount: actorBusyCount,
            processBusyCount: processBusyCount,
            cancelledCount: cancelledCount,
            budgetRejectedCount: budgetRejectedCount,
            invalidSnapshotCount: invalidSnapshotCount,
            supersededPublicationCount: supersededPublicationCount,
            materializedQueryResultCount: materializedQueryResultCount,
            stagedProjectionByteCount: stagedProjection?.byteCount ?? 0,
            residentProjectionByteCount: residentProjectionByteCount,
            acceptedProjectionSegmentCount: acceptedProjectionSegmentCount,
            exactDuplicateProjectionSegmentCount: exactDuplicateProjectionSegmentCount,
            rejectedProjectionSegmentCount: rejectedProjectionSegmentCount,
            completedProjectionCoverageCount: completedProjectionCoverageCount,
            revokedProjectionCoverageCount: revokedProjectionCoverageCount
        )
    }

    private func queryShard(
        _ query: WorkspaceCodemapSelectionGraphRuntimeQuery,
        in shard: ImmutableShard
    ) -> WorkspaceCodemapSelectionGraphRuntimeQueryDisposition {
        guard query.selectedSources.count <= policy.maximumSelectedSourceCountPerQuery else {
            return .unavailable(.budgetExceeded)
        }

        var generationsByFileID: [UUID: UInt64] = [:]
        for source in query.selectedSources {
            if let generation = generationsByFileID[source.fileID], generation != source.requestGeneration {
                return .unavailable(.invalidQuery)
            }
            generationsByFileID[source.fileID] = source.requestGeneration
        }
        let selectedSources = generationsByFileID.map {
            WorkspaceCodemapSelectionGraphRuntimeQuerySource(
                fileID: $0.key,
                requestGeneration: $0.value
            )
        }.sorted(by: querySourcePrecedes)
        guard selectedSources.count <= policy.maximumSelectedSourceCountPerQuery else {
            return .unavailable(.budgetExceeded)
        }

        var materializedByteCount = 128
        func reserveMaterializedBytes(_ byteCount: Int) -> Bool {
            let (next, overflow) = materializedByteCount.addingReportingOverflow(byteCount)
            guard !overflow, next <= query.outputBudget.maximumByteCount else { return false }
            materializedByteCount = next
            return true
        }
        let (selectedSourceBytes, selectedSourceByteOverflow) =
            selectedSources.count.multipliedReportingOverflow(by: 24)
        guard !selectedSourceByteOverflow,
              reserveMaterializedBytes(selectedSourceBytes)
        else {
            return .unavailable(.outputBudgetExceeded(.bytes))
        }

        let selectedFileIDs = Set(generationsByFileID.keys)
        var coverage: [WorkspaceCodemapSelectionGraphRuntimeSourceCoverage] = []
        var resolutions: [IndexedResolution] = []
        var targetIndices = Set<Int>()
        var failures: [IndexedFailure] = []

        for source in selectedSources {
            guard let sourceIndex = shard.nodeIndexByFileID[source.fileID] else {
                guard reserveMaterializedBytes(32) else {
                    return .unavailable(.outputBudgetExceeded(.bytes))
                }
                coverage.append(.init(source: source, state: .missing))
                continue
            }
            let sourceNode = shard.nodes[sourceIndex]
            guard sourceNode.requestGeneration == source.requestGeneration else {
                return .unavailable(.staleCurrentness(currentKey: shard.key))
            }
            guard reserveMaterializedBytes(32) else {
                return .unavailable(.outputBudgetExceeded(.bytes))
            }
            coverage.append(.init(source: source, state: .covered))
            let sourceEndpoint = shard.endpoint(at: sourceIndex)

            for targetIndex in shard.adjacency[sourceIndex, default: []] {
                guard shard.nodes.indices.contains(targetIndex) else {
                    return .unavailable(.invalidSnapshot)
                }
                let targetNode = shard.nodes[targetIndex]
                guard !selectedFileIDs.contains(targetNode.fileID) else { continue }
                if !targetIndices.contains(targetIndex) {
                    guard targetIndices.count < policy.maximumResolvedTargetCountPerQuery else {
                        return .unavailable(.budgetExceeded)
                    }
                    guard targetIndices.count < query.outputBudget.maximumResolvedTargetCount else {
                        return .unavailable(.outputBudgetExceeded(.resolvedTargets))
                    }
                    guard reserveMaterializedBytes(56) else {
                        return .unavailable(.outputBudgetExceeded(.bytes))
                    }
                    targetIndices.insert(targetIndex)
                }
                guard resolutions.count < query.outputBudget.maximumResolutionCount else {
                    return .unavailable(.outputBudgetExceeded(.resolutions))
                }
                guard reserveMaterializedBytes(112) else {
                    return .unavailable(.outputBudgetExceeded(.bytes))
                }
                resolutions.append(.init(
                    sourceIndex: sourceIndex,
                    targetIndex: targetIndex,
                    value: .init(source: sourceEndpoint, target: shard.endpoint(at: targetIndex))
                ))
            }
            for failure in shard.referenceFailures[sourceIndex, default: []] {
                guard failures.count < policy.maximumReferenceFailureCountPerQuery else {
                    return .unavailable(.budgetExceeded)
                }
                guard failures.count < query.outputBudget.maximumReferenceFailureCount else {
                    return .unavailable(.outputBudgetExceeded(.referenceFailures))
                }
                let (failureBytes, failureByteOverflow) =
                    failure.referencedName.utf8.count.addingReportingOverflow(64)
                guard !failureByteOverflow,
                      reserveMaterializedBytes(failureBytes)
                else {
                    return .unavailable(.outputBudgetExceeded(.bytes))
                }
                failures.append(.init(
                    sourceIndex: sourceIndex,
                    record: .init(
                        source: sourceEndpoint,
                        referencedName: failure.referencedName,
                        failure: failure.failure
                    )
                ))
            }
        }

        resolutions.sort {
            if $0.sourceIndex != $1.sourceIndex { return $0.sourceIndex < $1.sourceIndex }
            return $0.targetIndex < $1.targetIndex
        }
        failures.sort {
            if $0.sourceIndex != $1.sourceIndex { return $0.sourceIndex < $1.sourceIndex }
            return utf8Precedes($0.record.referencedName, $1.record.referencedName)
        }
        let targets = targetIndices.sorted().map(shard.endpoint(at:))
        increment(&materializedQueryResultCount)
        return .readyPartial(.init(
            key: shard.key,
            selectedSources: selectedSources,
            targets: targets,
            resolutions: resolutions.map(\.value),
            sourceCoverage: coverage,
            definitionUniverseCoverage: shard.summary.definitionUniverseCoverage,
            referenceFailures: failures.map(\.record),
            publishedSummary: shard.summary,
            materializedByteCount: materializedByteCount
        ))
    }

    private func queryStructureShard(
        _ query: WorkspaceCodemapSelectionGraphRuntimeStructureQuery,
        in shard: ImmutableShard
    ) -> WorkspaceCodemapSelectionGraphRuntimeStructureDisposition {
        guard !query.seeds.isEmpty,
              query.seeds.count <= policy.maximumSelectedSourceCountPerQuery
        else { return .unavailable(.invalidQuery) }

        var generationsByFileID: [UUID: UInt64] = [:]
        for seed in query.seeds {
            if let generation = generationsByFileID[seed.fileID], generation != seed.requestGeneration {
                return .unavailable(.invalidQuery)
            }
            generationsByFileID[seed.fileID] = seed.requestGeneration
        }
        let seeds = generationsByFileID.map {
            WorkspaceCodemapSelectionGraphRuntimeQuerySource(
                fileID: $0.key,
                requestGeneration: $0.value
            )
        }.sorted(by: querySourcePrecedes)

        var seedIndices: [Int] = []
        for seed in seeds {
            guard let index = shard.nodeIndexByFileID[seed.fileID],
                  shard.nodes[index].requestGeneration == seed.requestGeneration
            else { return .unavailable(.invalidQuery) }
            seedIndices.append(index)
        }
        seedIndices.sort()

        var materializedByteCount = 128
        var visitsByIndex: [Int: TraversalVisit] = [:]
        var queue: [Int] = []
        var examinedEdges = Set<LocalEdge>()
        var failures: [IndexedFailure] = []

        func result() -> WorkspaceCodemapSelectionGraphRuntimeStructureResult {
            let nodes = visitsByIndex.map { index, visit in
                WorkspaceCodemapSelectionGraphRuntimeStructureNode(
                    endpoint: shard.endpoint(at: index),
                    depth: visit.depth,
                    reachedBy: visit.reachedBy
                )
            }.sorted {
                if $0.depth != $1.depth { return $0.depth < $1.depth }
                let lhsIndex = shard.nodeIndexByFileID[$0.endpoint.fileID] ?? .max
                let rhsIndex = shard.nodeIndexByFileID[$1.endpoint.fileID] ?? .max
                return lhsIndex < rhsIndex
            }
            let orderedFailures = failures.sorted {
                if $0.sourceIndex != $1.sourceIndex { return $0.sourceIndex < $1.sourceIndex }
                return utf8Precedes($0.record.referencedName, $1.record.referencedName)
            }
            return WorkspaceCodemapSelectionGraphRuntimeStructureResult(
                key: shard.key,
                seeds: seeds,
                nodes: nodes,
                examinedEdgeCount: examinedEdges.count,
                definitionUniverseCoverage: shard.summary.definitionUniverseCoverage,
                referenceFailures: orderedFailures.map(\.record),
                publishedSummary: shard.summary,
                materializedByteCount: materializedByteCount
            )
        }

        func reserveBytes(_ count: Int) -> Bool {
            let (next, overflow) = materializedByteCount.addingReportingOverflow(count)
            guard !overflow, next <= query.limits.maximumByteCount else { return false }
            materializedByteCount = next
            return true
        }

        for index in seedIndices {
            guard visitsByIndex[index] == nil else { continue }
            guard visitsByIndex.count < query.limits.maximumNodeCount else {
                return .budget(result(), .nodes)
            }
            guard reserveBytes(64) else { return .budget(result(), .bytes) }
            visitsByIndex[index] = TraversalVisit(depth: 0, reachedBy: [])
            queue.append(index)
        }

        var cursor = 0
        while cursor < queue.count {
            if Task.isCancelled { return .unavailable(.cancelled) }
            let currentIndex = queue[cursor]
            cursor += 1
            guard let currentVisit = visitsByIndex[currentIndex],
                  currentVisit.depth < query.limits.maximumDepth
            else { continue }

            if query.direction != .referrers {
                for failure in shard.referenceFailures[currentIndex, default: []] {
                    let (bytes, overflow) = failure.referencedName.utf8.count.addingReportingOverflow(64)
                    guard !overflow, reserveBytes(bytes) else { return .budget(result(), .bytes) }
                    failures.append(.init(
                        sourceIndex: currentIndex,
                        record: .init(
                            source: shard.endpoint(at: currentIndex),
                            referencedName: failure.referencedName,
                            failure: failure.failure
                        )
                    ))
                }
            }

            var neighbors: [TraversalNeighbor] = []
            if query.direction != .referrers {
                neighbors.append(contentsOf: shard.adjacency[currentIndex, default: []].map {
                    TraversalNeighbor(
                        index: $0,
                        edge: LocalEdge(sourceIndex: currentIndex, targetIndex: $0),
                        direction: .referencedDefinitions
                    )
                })
            }
            if query.direction != .referencedDefinitions {
                neighbors.append(contentsOf: shard.reverseAdjacency[currentIndex, default: []].map {
                    TraversalNeighbor(
                        index: $0,
                        edge: LocalEdge(sourceIndex: $0, targetIndex: currentIndex),
                        direction: .referrers
                    )
                })
            }
            neighbors.sort {
                if $0.index != $1.index { return $0.index < $1.index }
                return $0.direction.rawValue < $1.direction.rawValue
            }

            for neighbor in neighbors {
                guard shard.nodes.indices.contains(neighbor.index) else {
                    return .unavailable(.invalidSnapshot)
                }
                if examinedEdges.insert(neighbor.edge).inserted {
                    guard examinedEdges.count <= query.limits.maximumEdgeCount else {
                        examinedEdges.remove(neighbor.edge)
                        return .budget(result(), .edges)
                    }
                    guard reserveBytes(24) else {
                        examinedEdges.remove(neighbor.edge)
                        return .budget(result(), .bytes)
                    }
                }

                let nextDepth = currentVisit.depth + 1
                if var existing = visitsByIndex[neighbor.index] {
                    if existing.depth == nextDepth {
                        existing.reachedBy.insert(neighbor.direction)
                        visitsByIndex[neighbor.index] = existing
                    }
                    continue
                }
                guard visitsByIndex.count < query.limits.maximumNodeCount else {
                    return .budget(result(), .nodes)
                }
                guard reserveBytes(64) else { return .budget(result(), .bytes) }
                visitsByIndex[neighbor.index] = TraversalVisit(
                    depth: nextDepth,
                    reachedBy: [neighbor.direction]
                )
                queue.append(neighbor.index)
            }
        }

        increment(&materializedQueryResultCount)
        return .readyPartial(result())
    }

    private func recordRejection(
        _ reason: WorkspaceCodemapSelectionGraphRuntimeRejectionReason,
        key: WorkspaceCodemapSelectionGraphRuntimeKey
    ) {
        guard observedKey == key, publishedShard?.key != key else { return }
        switch reason {
        case .inputBindingLimit, .graphSize, .accountingOverflow:
            lastUnavailableReason = .budgetExceeded
            increment(&budgetRejectedCount)
        case .invalidSnapshot, .modelStore, .edge, .equalGenerationAuthorityConflict:
            lastUnavailableReason = .invalidSnapshot
            increment(&invalidSnapshotCount)
        case let .rootUnavailable(reason):
            lastUnavailableReason = .explicitRootUnavailable(reason)
        case .rootEpochMismatch, .staleSnapshot:
            break
        }
    }

    private func issueOperationID() -> UInt64? {
        guard nextOperationID < .max else { return nil }
        nextOperationID += 1
        return nextOperationID
    }

    @discardableResult
    private func advanceObservationSerial() -> Bool {
        guard observationSerial < .max else {
            if revokedReason == nil {
                revokedReason = .authorityRevoked
                lastUnavailableReason = .explicitRootUnavailable(.authorityRevoked)
            }
            for operation in activeOperations.values {
                operation.task.cancel()
            }
            return false
        }
        observationSerial += 1
        return true
    }

    private func increment(_ value: inout UInt64) {
        if value < .max {
            value += 1
        }
    }

    private func prepareProjectionGeneration(
        _ generation: WorkspaceCodemapProjectionGeneration
    ) -> Bool {
        let key = WorkspaceCodemapSelectionGraphRuntimeKey(generation: generation)
        if let current = observedKey {
            if key.contributionGeneration < current.contributionGeneration {
                return false
            }
            if key.contributionGeneration == current.contributionGeneration {
                guard key == current, !hasCurrentnessConflict else {
                    hasCurrentnessConflict = true
                    lastUnavailableReason = .invalidSnapshot
                    increment(&invalidSnapshotCount)
                    _ = advanceObservationSerial()
                    for operation in activeOperations.values {
                        operation.task.cancel()
                    }
                    revokeProjectionState(clearPublishedShard: true)
                    return false
                }
                if let stagedProjection, stagedProjection.generation != generation {
                    hasCurrentnessConflict = true
                    lastUnavailableReason = .invalidSnapshot
                    increment(&invalidSnapshotCount)
                    _ = advanceObservationSerial()
                    for operation in activeOperations.values {
                        operation.task.cancel()
                    }
                    revokeProjectionState(clearPublishedShard: true)
                    return false
                }
                if case let .complete(proof, _, _, _)? = projectionCoverage,
                   proof.generation != generation
                {
                    hasCurrentnessConflict = true
                    lastUnavailableReason = .invalidSnapshot
                    increment(&invalidSnapshotCount)
                    _ = advanceObservationSerial()
                    revokeProjectionState(clearPublishedShard: true)
                    return false
                }
                if stagedProjection == nil, projectionCoverage == nil {
                    // First normalized segment for an already-observed live key takes ownership
                    // of that generation. Fence any detached live rebuild before it can publish
                    // over staged progress; an already-published live shard remains available to
                    // structure traversal with the staged coverage overlaid.
                    guard advanceObservationSerial() else { return false }
                    latestOperationID = nil
                    for operation in activeOperations.values where operation.key == key {
                        operation.task.cancel()
                    }
                }
                return true
            }
        }

        revokeProjectionState(clearPublishedShard: false)
        observedKey = key
        lastUnavailableReason = .rebuilding
        hasCurrentnessConflict = false
        guard advanceObservationSerial() else { return false }
        latestOperationID = nil
        for operation in activeOperations.values {
            operation.task.cancel()
        }
        return true
    }

    private func projectionGenerationDisposition(
        for generation: WorkspaceCodemapProjectionGeneration
    ) -> WorkspaceCodemapProjectionSnapshotDisposition {
        let key = WorkspaceCodemapSelectionGraphRuntimeKey(generation: generation)
        if let current = observedKey,
           key.contributionGeneration < current.contributionGeneration
        {
            return .stale
        }
        return hasCurrentnessConflict ? .unavailable(.corrupt) : .superseded
    }

    private func terminalProjectionDisposition(
        for key: WorkspaceCodemapSelectionGraphRuntimeKey
    ) -> WorkspaceCodemapProjectionSnapshotDisposition? {
        guard observedKey == key, let projectionCoverage else { return nil }
        return switch projectionCoverage {
        case let .budget(dimension, attempted, limit):
            .budget(dimension: dimension, attempted: attempted, limit: limit)
        case let .unavailable(reason):
            .unavailable(reason)
        case .complete:
            .superseded
        case .incomplete, .busy:
            nil
        }
    }

    private func setProjectionCoverage(
        _ coverage: WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage,
        key: WorkspaceCodemapSelectionGraphRuntimeKey
    ) {
        guard observedKey == key else { return }
        projectionCoverage = coverage
        if let shard = publishedShard, shard.key == key {
            publishedShard = shard.replacingCoverage(coverage)
        }
    }

    private func markProjectionInvalid(
        key: WorkspaceCodemapSelectionGraphRuntimeKey,
        reason: WorkspaceCodemapSelectionGraphUnavailableReason
    ) {
        stagedProjection = nil
        setProjectionCoverage(.unavailable(reason), key: key)
        lastUnavailableReason = reason == .accountingOverflow ? .budgetExceeded : .invalidSnapshot
        if reason == .accountingOverflow {
            increment(&budgetRejectedCount)
        } else {
            increment(&invalidSnapshotCount)
        }
    }

    private func revokeProjectionState(clearPublishedShard: Bool) {
        if stagedProjection != nil || projectionCoverage != nil || residentProjectionByteCount > 0 {
            increment(&revokedProjectionCoverageCount)
            if let key = observedKey {
                emitProjectionDiagnostic(key: key, kind: .projectionCoverageRevoked)
            }
        }
        stagedProjection = nil
        projectionCoverage = nil
        if clearPublishedShard {
            residentProjectionByteCount = 0
            publishedShard = nil
        } else if let publishedShard,
                  publishedShard.summary.definitionUniverseCoverage.isCompleteForRuntimeKey(publishedShard.key)
        {
            residentProjectionByteCount = publishedShard.summary.sizeAccounting.bytes
        } else {
            residentProjectionByteCount = 0
        }
    }

    private func effectiveProjectionCoverage(
        for key: WorkspaceCodemapSelectionGraphRuntimeKey
    ) -> WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage? {
        guard observedKey == key else { return nil }
        return projectionCoverage
    }

    private func unavailableReason(
        for reason: WorkspaceCodemapSelectionGraphRuntimeExternalUnavailableReason
    ) -> WorkspaceCodemapSelectionGraphUnavailableReason {
        switch reason {
        case .rootUnloaded:
            .rootUnloaded
        case .authorityRevoked:
            .authorityRevoked
        }
    }

    private func progressIsMonotonic(
        _ next: WorkspaceCodemapProjectionProgress,
        after previous: WorkspaceCodemapProjectionProgress
    ) -> Bool {
        let lhs = previous.counts
        let rhs = next.counts
        return rhs.supportedCandidateCount >= lhs.supportedCandidateCount &&
            rhs.processedCandidateCount >= lhs.processedCandidateCount &&
            rhs.contributedCount >= lhs.contributedCount &&
            rhs.emptyCount >= lhs.emptyCount &&
            rhs.terminalArtifactCount >= lhs.terminalArtifactCount &&
            rhs.terminalExcludedCount >= lhs.terminalExcludedCount &&
            rhs.transientCount >= lhs.transientCount &&
            next.catalogPageCount >= previous.catalogPageCount &&
            next.catalogPathByteCount >= previous.catalogPathByteCount &&
            next.publishedSegmentCount >= previous.publishedSegmentCount &&
            next.publishedSegmentByteCount >= previous.publishedSegmentByteCount &&
            (previous.catalogCompletion == nil || next.catalogCompletion == previous.catalogCompletion)
    }

    private func progressCountsAreInternallyConsistent(
        _ counts: WorkspaceCodemapProjectionCounts
    ) -> Bool {
        let (artifactCount, artifactOverflow) = counts.contributedCount.addingReportingOverflow(
            counts.emptyCount
        )
        let (terminalCount, terminalOverflow) = counts.terminalArtifactCount.addingReportingOverflow(
            counts.terminalExcludedCount
        )
        let (coveredCount, coveredOverflow) = artifactCount.addingReportingOverflow(terminalCount)
        let (processedCount, processedOverflow) = coveredCount.addingReportingOverflow(
            counts.transientCount
        )
        return !artifactOverflow && !terminalOverflow && !coveredOverflow && !processedOverflow &&
            processedCount == counts.processedCandidateCount &&
            counts.processedCandidateCount <= counts.supportedCandidateCount
    }

    private func stagedCountsMatchProgress(_ staging: StagedProjection) -> Bool {
        var contributed: UInt64 = 0
        var empty: UInt64 = 0
        var terminalArtifact: UInt64 = 0
        var terminalExcluded: UInt64 = 0
        for entry in staging.entriesByFileID.values {
            switch entry.outcome {
            case .contributed:
                guard contributed < .max else { return false }
                contributed += 1
            case .empty:
                guard empty < .max else { return false }
                empty += 1
            case .terminalArtifact:
                guard terminalArtifact < .max else { return false }
                terminalArtifact += 1
            case .terminalExcluded:
                guard terminalExcluded < .max else { return false }
                terminalExcluded += 1
            }
        }
        let counts = staging.progress.counts
        return counts.contributedCount == contributed &&
            counts.emptyCount == empty &&
            counts.terminalArtifactCount == terminalArtifact &&
            counts.terminalExcludedCount == terminalExcluded
    }

    private func projectionRemainingCount(
        _ progress: WorkspaceCodemapProjectionProgress
    ) -> UInt64? {
        guard progress.catalogCompletion != nil,
              progress.counts.supportedCandidateCount >= progress.counts.processedCandidateCount
        else { return nil }
        return progress.counts.supportedCandidateCount - progress.counts.processedCandidateCount
    }

    private func sealMatchesStaging(
        _ proof: WorkspaceCodemapProjectionCoverageProof,
        staging: StagedProjection
    ) -> Bool {
        guard proof.generation == staging.generation,
              progressCountsAreInternallyConsistent(proof.counts),
              stagedCountsMatchProgress(staging),
              UInt64(exactly: staging.entriesByFileID.count) == proof.candidateCount
        else { return false }

        if proof.candidateCount == 0 {
            guard proof.lastSegmentSequence == nil,
                  staging.segmentReceipts.isEmpty
            else { return false }
        } else {
            guard let lastSequence = proof.lastSegmentSequence,
                  incrementing(lastSequence) == staging.nextSequence,
                  UInt64(exactly: staging.segmentReceipts.count) == staging.nextSequence
            else { return false }
        }
        if staging.segmentReceipts.isEmpty {
            return proof.counts == .zero &&
                proof.catalogCompletion.supportedCandidateCount == 0
        }
        return staging.progress.counts == proof.counts &&
            staging.progress.catalogCompletion == proof.catalogCompletion
    }

    private func completedProgress(
        proof: WorkspaceCodemapProjectionCoverageProof,
        previous: WorkspaceCodemapProjectionProgress
    ) -> WorkspaceCodemapProjectionProgress {
        WorkspaceCodemapProjectionProgress(
            phase: .complete,
            counts: proof.counts,
            catalogPageCount: previous.catalogPageCount,
            catalogPathByteCount: previous.catalogPathByteCount,
            publishedSegmentCount: proof.lastSegmentSequence.flatMap(incrementing) ?? 0,
            publishedSegmentByteCount: previous.publishedSegmentByteCount,
            catalogCompletion: proof.catalogCompletion
        )
    }

    private func emitProjectionDiagnostic(
        key: WorkspaceCodemapSelectionGraphRuntimeKey,
        kind: WorkspaceCodemapSelectionGraphRuntimeDiagnosticEventKind
    ) {
        guard let operationID = issueOperationID() else { return }
        diagnostics.handle(.init(operationID: operationID, key: key, kind: kind))
    }

    private func incrementing(_ value: UInt64) -> UInt64? {
        value == .max ? nil : value + 1
    }

    private static func buildShard(
        snapshot: WorkspaceCodemapLiveGraphSnapshot,
        key: WorkspaceCodemapSelectionGraphRuntimeKey,
        sizePolicy: WorkspaceCodemapSelectionGraphSizePolicy
    ) -> BuildOutput {
        do {
            try Task.checkCancellation()
            let bindings = try validatedSortedBindings(snapshot: snapshot, key: key)
            if bindings.isEmpty {
                let summary = WorkspaceCodemapSelectionGraphRuntimePublishedSummary(
                    key: key,
                    nodeCount: 0,
                    uniqueEdgeCount: 0,
                    sizeAccounting: .zero,
                    isEmpty: true
                )
                return .success(.init(
                    key: key,
                    nodes: [],
                    nodeIndexByFileID: [:],
                    adjacency: [:],
                    reverseAdjacency: [:],
                    referenceFailures: [:],
                    summary: summary,
                    projectionFingerprintsByFileID: nil
                ))
            }

            guard let store = WorkspaceCodemapSelectionGraphModelStore.authorized(
                by: bindings[0],
                contributionGeneration: key.contributionGeneration,
                schemaVersion: key.schemaVersion,
                policyVersion: key.policyVersion,
                sizePolicy: sizePolicy
            ) else {
                return .rejected(.invalidSnapshot(.inconsistentCompletionAuthority))
            }

            var graphNodes: [WorkspaceCodemapSelectionGraphNode] = []
            for binding in bindings {
                try Task.checkCancellation()
                switch store.accept(binding) {
                case let .accepted(node, _):
                    graphNodes.append(node)
                case let .exactDuplicate(node, _):
                    graphNodes.append(node)
                case let .rejected(.sizeLimitExceeded(rejection)):
                    return .rejected(.graphSize(rejection))
                case let .rejected(rejection):
                    return .rejected(.modelStore(rejection))
                }
            }

            let nodes = graphNodes.map {
                ImmutableNode(fileID: $0.identity.fileID, requestGeneration: $0.identity.requestGeneration)
            }
            let indexByIdentity = Dictionary(uniqueKeysWithValues: graphNodes.indices.map {
                (graphNodes[$0].identity, $0)
            })
            let nodeIndexByFileID = Dictionary(uniqueKeysWithValues: nodes.indices.map {
                (nodes[$0].fileID, $0)
            })
            var lookupCache: [String: CachedLookup] = [:]
            var uniqueEdges = Set<LocalEdge>()
            var adjacency: [Int: [Int]] = [:]
            var reverseAdjacency: [Int: [Int]] = [:]
            var referenceFailures: [Int: [ImmutableReferenceFailure]] = [:]

            for sourceIndex in graphNodes.indices {
                let source = graphNodes[sourceIndex]
                for referencedName in source.references {
                    try Task.checkCancellation()
                    let lookup: CachedLookup
                    if let cached = lookupCache[referencedName] {
                        lookup = cached
                    } else {
                        switch store.definitionCandidates(named: referencedName, among: graphNodes) {
                        case let .candidates(candidates) where candidates.orderedCandidates.isEmpty:
                            lookup = .failure(.unresolvedDefinitionUniverse)
                        case let .candidates(candidates):
                            lookup = .targets(candidates.orderedCandidates)
                        case .candidateOverflow:
                            lookup = .failure(.candidateOverflow)
                        case .graphMismatch:
                            return .rejected(.invalidSnapshot(.inconsistentCompletionAuthority))
                        }
                        lookupCache[referencedName] = lookup
                    }

                    switch lookup {
                    case let .failure(failure):
                        referenceFailures[sourceIndex, default: []].append(.init(
                            referencedName: referencedName,
                            failure: failure
                        ))
                    case let .targets(targets):
                        for targetIdentity in targets {
                            try Task.checkCancellation()
                            guard let targetIndex = indexByIdentity[targetIdentity] else {
                                return .rejected(.invalidSnapshot(.inconsistentCompletionAuthority))
                            }
                            let localEdge = LocalEdge(sourceIndex: sourceIndex, targetIndex: targetIndex)
                            guard uniqueEdges.insert(localEdge).inserted else { continue }
                            switch store.makeEdge(source: source.identity, target: targetIdentity) {
                            case .edge:
                                adjacency[sourceIndex, default: []].append(targetIndex)
                                reverseAdjacency[targetIndex, default: []].append(sourceIndex)
                            case let .rejected(.sizeLimitExceeded(rejection)):
                                return .rejected(.graphSize(rejection))
                            case let .rejected(rejection):
                                return .rejected(.edge(rejection))
                            }
                        }
                    }
                }
            }
            for sourceIndex in Array(adjacency.keys) {
                adjacency[sourceIndex]?.sort()
            }
            for targetIndex in Array(reverseAdjacency.keys) {
                reverseAdjacency[targetIndex]?.sort()
            }
            for sourceIndex in Array(referenceFailures.keys) {
                referenceFailures[sourceIndex]?.sort {
                    utf8Precedes($0.referencedName, $1.referencedName)
                }
            }
            try Task.checkCancellation()

            let baseAccounting = WorkspaceCodemapSelectionGraphRuntimeSizeAccounting(store.accounting)
            let (reverseBytes, reverseByteOverflow) = UInt64(uniqueEdges.count)
                .multipliedReportingOverflow(by: 16)
            guard !reverseByteOverflow else {
                return .rejected(.graphSize(.arithmeticOverflow(.bytes)))
            }
            let (totalBytes, totalByteOverflow) = baseAccounting.bytes.addingReportingOverflow(
                reverseBytes
            )
            guard !totalByteOverflow else {
                return .rejected(.graphSize(.arithmeticOverflow(.bytes)))
            }
            guard totalBytes <= sizePolicy.maxBytes else {
                return .rejected(.graphSize(.limitExceeded(
                    dimension: .bytes,
                    attempted: totalBytes,
                    limit: sizePolicy.maxBytes
                )))
            }
            let accounting = WorkspaceCodemapSelectionGraphRuntimeSizeAccounting(
                nodes: baseAccounting.nodes,
                postings: baseAccounting.postings,
                edges: baseAccounting.edges,
                bytes: totalBytes
            )
            let summary = WorkspaceCodemapSelectionGraphRuntimePublishedSummary(
                key: key,
                nodeCount: accounting.nodes,
                uniqueEdgeCount: accounting.edges,
                sizeAccounting: accounting,
                isEmpty: false
            )
            return .success(.init(
                key: key,
                nodes: nodes,
                nodeIndexByFileID: nodeIndexByFileID,
                adjacency: adjacency,
                reverseAdjacency: reverseAdjacency,
                referenceFailures: referenceFailures,
                summary: summary,
                projectionFingerprintsByFileID: nil
            ))
        } catch is CancellationError {
            return .cancelled
        } catch let BuildValidationError.reason(reason) {
            return .rejected(.invalidSnapshot(reason))
        } catch {
            return .rejected(.accountingOverflow)
        }
    }

    private static func buildProjectionShard(
        entries: [WorkspaceCodemapProjectionEntry],
        proof: WorkspaceCodemapProjectionCoverageProof,
        key: WorkspaceCodemapSelectionGraphRuntimeKey,
        sizePolicy: WorkspaceCodemapSelectionGraphSizePolicy
    ) -> BuildOutput {
        guard !Task.isCancelled else { return .cancelled }
        let coverage = WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage.complete(
            proof: proof,
            candidateCount: proof.candidateCount,
            contributedCount: proof.contributedCount,
            terminalCount: proof.terminalCount
        )
        let graphEntries = entries.compactMap { entry -> ProjectionGraphEntry? in
            let contribution: CodeMapSelectionGraphContribution
            switch entry.outcome {
            case let .contributed(value), let .empty(value):
                contribution = value
            case .terminalArtifact, .terminalExcluded:
                return nil
            }
            return ProjectionGraphEntry(
                fileID: entry.identity.fileID,
                requestGeneration: entry.requestGeneration,
                standardizedRelativePath: entry.identity.standardizedRelativePath,
                contribution: contribution
            )
        }.sorted(by: projectionGraphEntryPrecedes)

        if graphEntries.isEmpty {
            let summary = WorkspaceCodemapSelectionGraphRuntimePublishedSummary(
                key: key,
                nodeCount: 0,
                uniqueEdgeCount: 0,
                sizeAccounting: .zero,
                isEmpty: true,
                definitionUniverseCoverage: coverage
            )
            return .success(.init(
                key: key,
                nodes: [],
                nodeIndexByFileID: [:],
                adjacency: [:],
                reverseAdjacency: [:],
                referenceFailures: [:],
                summary: summary,
                projectionFingerprintsByFileID: [:]
            ))
        }

        guard let nodeCount = UInt64(exactly: graphEntries.count) else {
            return .rejected(.graphSize(.arithmeticOverflow(.nodes)))
        }
        guard nodeCount <= sizePolicy.maxNodes else {
            return .rejected(.graphSize(.limitExceeded(
                dimension: .nodes,
                attempted: nodeCount,
                limit: sizePolicy.maxNodes
            )))
        }

        var postingCount: UInt64 = 0
        var baseBytes: UInt64 = 0
        var definitionIndices: [String: [Int]] = [:]
        let nodes = graphEntries.enumerated().map { index, entry in
            for definition in entry.contribution.sortedUniqueDefinitions {
                definitionIndices[definition, default: []].append(index)
            }
            return ImmutableNode(fileID: entry.fileID, requestGeneration: entry.requestGeneration)
        }
        for entry in graphEntries {
            guard !Task.isCancelled else { return .cancelled }
            let names = entry.contribution.sortedUniqueDefinitions +
                entry.contribution.sortedUniqueReferences
            guard let nameCount = UInt64(exactly: names.count),
                  let keyBytes = UInt64(exactly: entry.contribution.artifactKey.canonicalBytes.count),
                  let pathBytes = UInt64(exactly: entry.standardizedRelativePath.utf8.count)
            else { return .rejected(.graphSize(.arithmeticOverflow(.bytes))) }
            let (nextPostingCount, postingOverflow) = postingCount.addingReportingOverflow(nameCount)
            guard !postingOverflow else {
                return .rejected(.graphSize(.arithmeticOverflow(.postings)))
            }
            postingCount = nextPostingCount

            var nodeBytes: UInt64 = 40
            for value in [keyBytes, UInt64(CodeMapSHA256Digest.byteCount), pathBytes] {
                let (next, overflow) = nodeBytes.addingReportingOverflow(value)
                guard !overflow else {
                    return .rejected(.graphSize(.arithmeticOverflow(.bytes)))
                }
                nodeBytes = next
            }
            for name in names {
                guard let nameBytes = UInt64(exactly: name.utf8.count) else {
                    return .rejected(.graphSize(.arithmeticOverflow(.bytes)))
                }
                let (next, overflow) = nodeBytes.addingReportingOverflow(nameBytes)
                guard !overflow else {
                    return .rejected(.graphSize(.arithmeticOverflow(.bytes)))
                }
                nodeBytes = next
            }
            let (nextBaseBytes, baseOverflow) = baseBytes.addingReportingOverflow(nodeBytes)
            guard !baseOverflow else {
                return .rejected(.graphSize(.arithmeticOverflow(.bytes)))
            }
            baseBytes = nextBaseBytes
        }
        guard postingCount <= sizePolicy.maxPostings else {
            return .rejected(.graphSize(.limitExceeded(
                dimension: .postings,
                attempted: postingCount,
                limit: sizePolicy.maxPostings
            )))
        }

        let nodeIndexByFileID = Dictionary(uniqueKeysWithValues: nodes.indices.map {
            (nodes[$0].fileID, $0)
        })
        let projectionFingerprintsByFileID = Dictionary(uniqueKeysWithValues: graphEntries.map {
            ($0.fileID, ProjectionShardFingerprint(
                standardizedRelativePath: $0.standardizedRelativePath,
                requestGeneration: $0.requestGeneration,
                artifactKey: $0.contribution.artifactKey,
                contributionDigest: $0.contribution.contributionDigest
            ))
        })
        var uniqueEdges = Set<LocalEdge>()
        var adjacency: [Int: [Int]] = [:]
        var reverseAdjacency: [Int: [Int]] = [:]
        var referenceFailures: [Int: [ImmutableReferenceFailure]] = [:]
        for sourceIndex in graphEntries.indices {
            let source = graphEntries[sourceIndex]
            for referencedName in source.contribution.sortedUniqueReferences {
                guard !Task.isCancelled else { return .cancelled }
                let candidates = definitionIndices[referencedName, default: []]
                guard let candidateCount = UInt64(exactly: candidates.count) else {
                    return .rejected(.graphSize(.arithmeticOverflow(.edges)))
                }
                if candidateCount > sizePolicy.maxDefinitionCandidates {
                    referenceFailures[sourceIndex, default: []].append(.init(
                        referencedName: referencedName,
                        failure: .candidateOverflow
                    ))
                    continue
                }
                if candidates.isEmpty {
                    referenceFailures[sourceIndex, default: []].append(.init(
                        referencedName: referencedName,
                        failure: .provenMissingDefinition
                    ))
                    continue
                }
                for targetIndex in candidates {
                    let edge = LocalEdge(sourceIndex: sourceIndex, targetIndex: targetIndex)
                    guard uniqueEdges.insert(edge).inserted else { continue }
                    adjacency[sourceIndex, default: []].append(targetIndex)
                    reverseAdjacency[targetIndex, default: []].append(sourceIndex)
                }
            }
        }
        guard let edgeCount = UInt64(exactly: uniqueEdges.count) else {
            return .rejected(.graphSize(.arithmeticOverflow(.edges)))
        }
        guard edgeCount <= sizePolicy.maxEdges else {
            return .rejected(.graphSize(.limitExceeded(
                dimension: .edges,
                attempted: edgeCount,
                limit: sizePolicy.maxEdges
            )))
        }
        let (edgeBytes, edgeByteOverflow) = edgeCount.multipliedReportingOverflow(by: 80)
        guard !edgeByteOverflow else {
            return .rejected(.graphSize(.arithmeticOverflow(.bytes)))
        }
        let (totalBytes, totalByteOverflow) = baseBytes.addingReportingOverflow(edgeBytes)
        guard !totalByteOverflow else {
            return .rejected(.graphSize(.arithmeticOverflow(.bytes)))
        }
        guard totalBytes <= sizePolicy.maxBytes else {
            return .rejected(.graphSize(.limitExceeded(
                dimension: .bytes,
                attempted: totalBytes,
                limit: sizePolicy.maxBytes
            )))
        }
        for sourceIndex in Array(adjacency.keys) {
            adjacency[sourceIndex]?.sort()
        }
        for targetIndex in Array(reverseAdjacency.keys) {
            reverseAdjacency[targetIndex]?.sort()
        }
        for sourceIndex in Array(referenceFailures.keys) {
            referenceFailures[sourceIndex]?.sort {
                utf8Precedes($0.referencedName, $1.referencedName)
            }
        }
        let accounting = WorkspaceCodemapSelectionGraphRuntimeSizeAccounting(
            nodes: nodeCount,
            postings: postingCount,
            edges: edgeCount,
            bytes: totalBytes
        )
        let summary = WorkspaceCodemapSelectionGraphRuntimePublishedSummary(
            key: key,
            nodeCount: nodeCount,
            uniqueEdgeCount: edgeCount,
            sizeAccounting: accounting,
            isEmpty: false,
            definitionUniverseCoverage: coverage
        )
        return .success(.init(
            key: key,
            nodes: nodes,
            nodeIndexByFileID: nodeIndexByFileID,
            adjacency: adjacency,
            reverseAdjacency: reverseAdjacency,
            referenceFailures: referenceFailures,
            summary: summary,
            projectionFingerprintsByFileID: projectionFingerprintsByFileID
        ))
    }

    private static func projectionShardFingerprint(
        for binding: WorkspaceCodemapArtifactBinding
    ) -> ProjectionShardFingerprint? {
        guard case let .resolved(completion) = binding.availability else { return nil }
        let contribution: CodeMapSelectionGraphContribution
        switch completion.outcome {
        case let .ready(artifact):
            contribution = CodeMapSelectionGraphContribution(
                artifactKey: completion.artifactKey,
                artifact: artifact
            )
        case .readyNoSymbols:
            contribution = CodeMapSelectionGraphContribution(
                artifactKey: completion.artifactKey,
                definitions: [] as [String],
                references: [] as [String]
            )
        case .oversize, .decodeFailed, .parseFailed:
            return nil
        }
        return ProjectionShardFingerprint(
            standardizedRelativePath: binding.identity.standardizedRelativePath,
            requestGeneration: completion.token.requestGeneration,
            artifactKey: contribution.artifactKey,
            contributionDigest: contribution.contributionDigest
        )
    }

    private static func validatedSortedBindings(
        snapshot: WorkspaceCodemapLiveGraphSnapshot,
        key: WorkspaceCodemapSelectionGraphRuntimeKey
    ) throws -> [WorkspaceCodemapArtifactBinding] {
        var fileIDs = Set<UUID>()
        var relativePaths = Set<String>()
        for binding in snapshot.bindings {
            try Task.checkCancellation()
            guard binding.identity.rootID == key.rootEpoch.rootID,
                  binding.identity.rootLifetimeID == key.rootEpoch.rootLifetimeID
            else { throw BuildValidationError.reason(.bindingRootEpochMismatch) }
            guard fileIDs.insert(binding.identity.fileID).inserted else {
                throw BuildValidationError.reason(.duplicateFileID)
            }
            guard relativePaths.insert(binding.identity.standardizedRelativePath).inserted else {
                throw BuildValidationError.reason(.duplicateRelativePath)
            }
            switch binding.availability {
            case .pending:
                throw BuildValidationError.reason(.bindingNotResolved)
            case .unsupported:
                throw BuildValidationError.reason(.terminalBinding)
            case let .resolved(completion):
                guard completion.token.isFactoryValidated,
                      completion.sourceProof.isFactoryValidated,
                      completion.token.identity == binding.identity,
                      completion.sourceProof == completion.token.sourceExpectation
                else { throw BuildValidationError.reason(.inconsistentCompletionAuthority) }
                guard completion.sourceProof.sourceAuthority.rootEpoch == key.rootEpoch else {
                    throw BuildValidationError.reason(.bindingRootEpochMismatch)
                }
                guard completion.token.catalogGeneration == key.catalogGeneration else {
                    throw BuildValidationError.reason(.catalogGenerationMismatch)
                }
                guard completion.sourceProof.sourceAuthority.repositoryAuthority == key.repositoryAuthority else {
                    throw BuildValidationError.reason(.repositoryAuthorityMismatch)
                }
                switch completion.outcome {
                case .ready, .readyNoSymbols:
                    guard key.schemaVersion == CodeMapSelectionGraphContribution.currentSchemaVersion else {
                        throw BuildValidationError.reason(.contributionSchemaMismatch)
                    }
                    guard key.policyVersion == CodeMapSelectionGraphContribution.currentPolicyVersion else {
                        throw BuildValidationError.reason(.contributionPolicyMismatch)
                    }
                case .oversize, .decodeFailed, .parseFailed:
                    throw BuildValidationError.reason(.terminalBinding)
                }
            }
        }
        return snapshot.bindings.sorted {
            if $0.identity.standardizedRelativePath != $1.identity.standardizedRelativePath {
                return utf8Precedes(
                    $0.identity.standardizedRelativePath,
                    $1.identity.standardizedRelativePath
                )
            }
            if $0.identity.fileID != $1.identity.fileID {
                return uuidPrecedes($0.identity.fileID, $1.identity.fileID)
            }
            return requestGeneration(of: $0) < requestGeneration(of: $1)
        }
    }
}

private struct ImmutableNode: Hashable {
    let fileID: UUID
    let requestGeneration: UInt64
}

private struct ImmutableReferenceFailure: Hashable {
    let referencedName: String
    let failure: WorkspaceCodemapSelectionGraphReferenceFailure
}

private struct ImmutableShard: Hashable {
    let key: WorkspaceCodemapSelectionGraphRuntimeKey
    let nodes: [ImmutableNode]
    let nodeIndexByFileID: [UUID: Int]
    let adjacency: [Int: [Int]]
    let reverseAdjacency: [Int: [Int]]
    let referenceFailures: [Int: [ImmutableReferenceFailure]]
    let summary: WorkspaceCodemapSelectionGraphRuntimePublishedSummary
    let projectionFingerprintsByFileID: [UUID: ProjectionShardFingerprint]?

    func endpoint(at index: Int) -> WorkspaceCodemapSelectionGraphRuntimeEndpoint {
        let node = nodes[index]
        return .init(rootEpoch: key.rootEpoch, fileID: node.fileID, requestGeneration: node.requestGeneration)
    }

    func replacingCoverage(
        _ coverage: WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage
    ) -> Self {
        Self(
            key: key,
            nodes: nodes,
            nodeIndexByFileID: nodeIndexByFileID,
            adjacency: adjacency,
            reverseAdjacency: reverseAdjacency,
            referenceFailures: referenceFailures,
            summary: WorkspaceCodemapSelectionGraphRuntimePublishedSummary(
                key: summary.key,
                nodeCount: summary.nodeCount,
                uniqueEdgeCount: summary.uniqueEdgeCount,
                sizeAccounting: summary.sizeAccounting,
                isEmpty: summary.isEmpty,
                definitionUniverseCoverage: coverage
            ),
            projectionFingerprintsByFileID: projectionFingerprintsByFileID
        )
    }

    func replacingKey(
        _ key: WorkspaceCodemapSelectionGraphRuntimeKey,
        coverage: WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage
    ) -> Self {
        Self(
            key: key,
            nodes: nodes,
            nodeIndexByFileID: nodeIndexByFileID,
            adjacency: adjacency,
            reverseAdjacency: reverseAdjacency,
            referenceFailures: referenceFailures,
            summary: WorkspaceCodemapSelectionGraphRuntimePublishedSummary(
                key: key,
                nodeCount: summary.nodeCount,
                uniqueEdgeCount: summary.uniqueEdgeCount,
                sizeAccounting: summary.sizeAccounting,
                isEmpty: summary.isEmpty,
                definitionUniverseCoverage: coverage
            ),
            projectionFingerprintsByFileID: projectionFingerprintsByFileID
        )
    }
}

private struct ProjectionShardFingerprint: Hashable {
    let standardizedRelativePath: String
    let requestGeneration: UInt64
    let artifactKey: CodeMapArtifactKey
    let contributionDigest: CodeMapSHA256Digest
}

private struct StagedProjection {
    let generation: WorkspaceCodemapProjectionGeneration
    var nextSequence: UInt64 = 0
    var segmentReceipts: [UInt64: ProjectionSegmentReceipt] = [:]
    var entriesByFileID: [UUID: WorkspaceCodemapProjectionEntry] = [:]
    var fileIDByRelativePath: [String: UUID] = [:]
    var progress: WorkspaceCodemapProjectionProgress
    var byteCount: UInt64 = 0
}

private struct ProjectionSegmentReceipt: Hashable {
    let sequence: UInt64
    let fingerprints: [ProjectionEntryFingerprint]
    let progress: WorkspaceCodemapProjectionProgress
    let declaredByteCount: UInt64
}

private struct ProjectionEntryFingerprint: Hashable, Comparable {
    let fileID: UUID
    let standardizedRelativePath: String
    let requestGeneration: UInt64
    let pathGeneration: UInt64
    let pipelineIdentity: CodeMapPipelineIdentity
    let outcome: ProjectionOutcomeFingerprint

    init(_ entry: WorkspaceCodemapProjectionEntry) {
        fileID = entry.identity.fileID
        standardizedRelativePath = entry.identity.standardizedRelativePath
        requestGeneration = entry.requestGeneration
        pathGeneration = entry.pathGeneration
        pipelineIdentity = entry.pipelineIdentity
        outcome = switch entry.outcome {
        case let .contributed(contribution):
            .contributed(
                artifactKey: contribution.artifactKey,
                digest: contribution.contributionDigest
            )
        case let .empty(contribution):
            .empty(
                artifactKey: contribution.artifactKey,
                digest: contribution.contributionDigest
            )
        case let .terminalArtifact(reason):
            .terminalArtifact(reason)
        case let .terminalExcluded(reason):
            .terminalExcluded(reason)
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.standardizedRelativePath != rhs.standardizedRelativePath {
            return utf8Precedes(lhs.standardizedRelativePath, rhs.standardizedRelativePath)
        }
        if lhs.fileID != rhs.fileID {
            return uuidPrecedes(lhs.fileID, rhs.fileID)
        }
        if lhs.requestGeneration != rhs.requestGeneration {
            return lhs.requestGeneration < rhs.requestGeneration
        }
        return lhs.pathGeneration < rhs.pathGeneration
    }
}

private enum ProjectionOutcomeFingerprint: Hashable {
    case contributed(artifactKey: CodeMapArtifactKey, digest: CodeMapSHA256Digest)
    case empty(artifactKey: CodeMapArtifactKey, digest: CodeMapSHA256Digest)
    case terminalArtifact(WorkspaceCodemapProjectionTerminalArtifactReason)
    case terminalExcluded(WorkspaceCodemapProjectionTerminalExclusionReason)
}

private struct ProjectionGraphEntry {
    let fileID: UUID
    let requestGeneration: UInt64
    let standardizedRelativePath: String
    let contribution: CodeMapSelectionGraphContribution
}

private struct LocalEdge: Hashable {
    let sourceIndex: Int
    let targetIndex: Int
}

private struct TraversalVisit {
    let depth: Int
    var reachedBy: Set<WorkspaceCodemapStructureTraversalReachDirection>
}

private struct TraversalNeighbor {
    let index: Int
    let edge: LocalEdge
    let direction: WorkspaceCodemapStructureTraversalReachDirection
}

private enum CachedLookup {
    case targets([WorkspaceCodemapSelectionGraphNodeIdentity])
    case failure(WorkspaceCodemapSelectionGraphReferenceFailure)
}

private enum BuildOutput: Equatable {
    case success(ImmutableShard)
    case rejected(WorkspaceCodemapSelectionGraphRuntimeRejectionReason)
    case cancelled
}

private enum BuildValidationError: Error {
    case reason(WorkspaceCodemapSelectionGraphRuntimeValidationReason)
}

private struct ActiveOperation {
    let key: WorkspaceCodemapSelectionGraphRuntimeKey
    let task: Task<BuildOutput, Never>
}

private struct IndexedResolution {
    let sourceIndex: Int
    let targetIndex: Int
    let value: WorkspaceCodemapSelectionGraphRuntimeResolution
}

private struct IndexedFailure {
    let sourceIndex: Int
    let record: WorkspaceCodemapSelectionGraphRuntimeReferenceFailureRecord
}

private func querySourcePrecedes(
    _ lhs: WorkspaceCodemapSelectionGraphRuntimeQuerySource,
    _ rhs: WorkspaceCodemapSelectionGraphRuntimeQuerySource
) -> Bool {
    if lhs.fileID != rhs.fileID { return uuidPrecedes(lhs.fileID, rhs.fileID) }
    return lhs.requestGeneration < rhs.requestGeneration
}

private func projectionGraphEntryPrecedes(
    _ lhs: ProjectionGraphEntry,
    _ rhs: ProjectionGraphEntry
) -> Bool {
    if lhs.standardizedRelativePath != rhs.standardizedRelativePath {
        return utf8Precedes(lhs.standardizedRelativePath, rhs.standardizedRelativePath)
    }
    if lhs.fileID != rhs.fileID {
        return uuidPrecedes(lhs.fileID, rhs.fileID)
    }
    return lhs.requestGeneration < rhs.requestGeneration
}

private extension WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage {
    func isCompleteForRuntimeKey(_ key: WorkspaceCodemapSelectionGraphRuntimeKey) -> Bool {
        guard case let .complete(proof, candidateCount, contributedCount, terminalCount) = self else {
            return false
        }
        let generation = proof.generation
        return generation.rootEpoch == key.rootEpoch &&
            generation.catalogGeneration == key.catalogGeneration &&
            generation.repositoryAuthority == key.repositoryAuthority &&
            generation.contributionGeneration == key.contributionGeneration &&
            generation.schemaVersion == key.schemaVersion &&
            generation.policyVersion == key.policyVersion &&
            candidateCount == proof.candidateCount &&
            contributedCount == proof.contributedCount &&
            terminalCount == proof.terminalCount
    }
}

private func requestGeneration(of binding: WorkspaceCodemapArtifactBinding) -> UInt64 {
    switch binding.availability {
    case let .pending(token): token.requestGeneration
    case let .resolved(completion): completion.token.requestGeneration
    case .unsupported: 0
    }
}

private func uuidPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
    lhs.uuidString.utf8.lexicographicallyPrecedes(rhs.uuidString.utf8)
}

private func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}
