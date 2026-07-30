#if DEBUG
    import Foundation

    /// Privacy-safe, attachable DEBUG evidence for the live codemap graph-index pipeline.
    /// Entries contain identifiers, ordinals, counts, and monotonic uptime only—never paths or source text.
    enum WorkspaceCodemapGraphIndexDebugReason: String, Hashable {
        case scheduled
        case queued
        case admitted
        case phaseEntered
        case pageAccepted
        case checkpointed
        case retry
        case restartGeneration
        case restartPage
        case cancelled
        case superseded
        case budgetLimited
        case complete
        case rootOvertake
        case explicitOvertake
        case workerFinished
        case workerComplete
        case workerBudgetLimited
        case workerCancelled
        case workerSuperseded
        case workerCurrentnessLost
        case workerAdmissionUnavailable
        case workerCheckpointTransitionRejected
        case workerGenerationResetRejected
        case workerRetryCancelled
        case watchdogNoProgress
        case watchdogRecoveryExhausted
        case prioritizeRestart
    }

    enum WorkspaceCodemapManifestFailureReason: String, CaseIterable, Hashable {
        case staleAuthority
        case staleWriterAuthority
        case quotaExceeded
        case corruptRecord
        case invalidContribution
        case inputTooLarge
        case insecureDirectory
        case insecureLeaf
        case ioFailure
        case backpressure
        case cancellation
        case other
    }

    struct WorkspaceCodemapManifestFailureDiagnostic: Equatable {
        let reason: WorkspaceCodemapManifestFailureReason
        let operation: String?
        let currentAuthorityGeneration: UInt64?
        let observedPredecessorAuthorityGeneration: UInt64?
        let attemptStartedUptimeNanoseconds: UInt64
        let attemptCompletedUptimeNanoseconds: UInt64
        let attemptDurationNanoseconds: UInt64
    }

    enum WorkspaceCodemapManifestMeasurementOrigin: String, CaseIterable, Hashable {
        case page
        case adoption
        case demand
        case seal
    }

    enum WorkspaceCodemapManifestMeasurementRetryKind: String, Hashable {
        case none
        case authority
        case deferred
        case boundedSubset = "bounded_subset"
    }

    struct WorkspaceCodemapManifestMeasurementAggregate: Equatable {
        var loadCount: UInt64 = 0
        var loadDurationNanoseconds: UInt64 = 0
        var submissionCount: UInt64 = 0
        var waitCount: UInt64 = 0
        var storeAttemptCount: UInt64 = 0
        var writeCount: UInt64 = 0
        var failureCount: UInt64 = 0
        var retryAttemptCount: UInt64 = 0
        var mutationCountVolume: UInt64 = 0
        var mutationByteVolume: UInt64 = 0
        var inputSnapshotRecordVolume: UInt64 = 0
        var inputSnapshotByteVolume: UInt64 = 0
        var decodedByteVolume: UInt64 = 0
        var attemptedOutputSnapshotRecordVolume: UInt64 = 0
        var attemptedOutputSnapshotByteVolume: UInt64 = 0
        var outputSnapshotRecordVolume: UInt64 = 0
        var outputSnapshotByteVolume: UInt64 = 0
        var loadReadDecodeDurationNanoseconds: UInt64 = 0
        var mergeDurationNanoseconds: UInt64 = 0
        var sortDurationNanoseconds: UInt64 = 0
        var encodeDurationNanoseconds: UInt64 = 0
        var temporaryWriteDurationNanoseconds: UInt64 = 0
        var temporaryFileSyncDurationNanoseconds: UInt64 = 0
        var atomicReplaceDurationNanoseconds: UInt64 = 0
        var manifestDirectorySyncDurationNanoseconds: UInt64 = 0
        var readbackDecodeDurationNanoseconds: UInt64 = 0
        var totalDurationNanoseconds: UInt64 = 0

        mutating func add(_ keyPath: WritableKeyPath<Self, UInt64>, _ value: UInt64 = 1) {
            let (sum, overflow) = self[keyPath: keyPath].addingReportingOverflow(value)
            self[keyPath: keyPath] = overflow ? .max : sum
        }

        mutating func recordStoreAttempt(
            _ attempt: CodeMapRootManifestDebugAttemptMetrics,
            mutationByteCount: UInt64,
            succeeded: Bool,
            retryKind: WorkspaceCodemapManifestMeasurementRetryKind
        ) {
            add(\.storeAttemptCount)
            if attempt.published {
                add(\.writeCount)
            }
            if !succeeded {
                add(\.failureCount)
            }
            if retryKind != .none {
                add(\.retryAttemptCount)
            }
            add(\.mutationCountVolume, attempt.mutationCount)
            add(\.mutationByteVolume, mutationByteCount)
            add(\.inputSnapshotRecordVolume, attempt.inputSnapshotRecordCount)
            add(\.inputSnapshotByteVolume, attempt.inputSnapshotEncodedByteCount)
            add(\.decodedByteVolume, attempt.decodedByteCount)
            add(\.attemptedOutputSnapshotRecordVolume, attempt.outputSnapshotRecordCount)
            add(\.attemptedOutputSnapshotByteVolume, attempt.outputSnapshotEncodedByteCount)
            if attempt.published {
                add(\.outputSnapshotRecordVolume, attempt.outputSnapshotRecordCount)
                add(\.outputSnapshotByteVolume, attempt.outputSnapshotEncodedByteCount)
            }
            add(\.loadReadDecodeDurationNanoseconds, attempt.loadReadDecodeDurationNanoseconds)
            add(\.mergeDurationNanoseconds, attempt.mergeDurationNanoseconds)
            add(\.sortDurationNanoseconds, attempt.sortDurationNanoseconds)
            add(\.encodeDurationNanoseconds, attempt.encodeDurationNanoseconds)
            add(\.temporaryWriteDurationNanoseconds, attempt.temporaryWriteDurationNanoseconds)
            add(\.temporaryFileSyncDurationNanoseconds, attempt.temporaryFileSyncDurationNanoseconds)
            add(\.atomicReplaceDurationNanoseconds, attempt.atomicReplaceDurationNanoseconds)
            add(
                \.manifestDirectorySyncDurationNanoseconds,
                attempt.manifestDirectorySyncDurationNanoseconds
            )
            add(\.readbackDecodeDurationNanoseconds, attempt.readbackDecodeDurationNanoseconds)
            add(\.totalDurationNanoseconds, attempt.totalDurationNanoseconds)
        }
    }

    struct WorkspaceCodemapManifestMeasurementSnapshot: Equatable {
        let byOrigin: [
            WorkspaceCodemapManifestMeasurementOrigin: WorkspaceCodemapManifestMeasurementAggregate
        ]
    }

    enum WorkspaceCodemapManifestFailureClassifier {
        static func classify(_ error: Error) -> (
            reason: WorkspaceCodemapManifestFailureReason,
            operation: String?,
            currentAuthorityGeneration: UInt64?,
            observedPredecessorAuthorityGeneration: UInt64?
        ) {
            if let error = error as? WorkspaceCodemapObservedStaleAuthorityError {
                return (
                    .staleAuthority,
                    nil,
                    error.currentAuthorityGeneration,
                    error.observedPredecessorAuthorityGeneration
                )
            }
            if error is CancellationError {
                return (.cancellation, nil, nil, nil)
            }
            if let error = error as? CodeMapRootManifestStoreError {
                switch error {
                case .insecureDirectory: return (.insecureDirectory, nil, nil, nil)
                case .insecureLeaf: return (.insecureLeaf, nil, nil, nil)
                case .quotaExceeded: return (.quotaExceeded, nil, nil, nil)
                case .staleWriterAuthority: return (.staleWriterAuthority, nil, nil, nil)
                case let .ioFailure(operation, _):
                    return (.ioFailure, boundedOperation(operation), nil, nil)
                case .invalidRoot, .simulatedProcessTermination:
                    return (.other, nil, nil, nil)
                }
            }
            if let error = error as? CodeMapRootManifestModelError {
                switch error {
                case .staleAuthority: return (.staleAuthority, nil, nil, nil)
                case .corruptRecord: return (.corruptRecord, nil, nil, nil)
                case .invalidContribution: return (.invalidContribution, nil, nil, nil)
                case .inputTooLarge: return (.inputTooLarge, nil, nil, nil)
                default: return (.other, nil, nil, nil)
                }
            }
            return (.other, nil, nil, nil)
        }

        private static func boundedOperation(_ operation: String) -> String {
            switch operation {
            case "manifest-anchor-lock", "manifest-open", "temporary-open", "temporary-fsync",
                 "manifest-publish", "manifest-directory-fsync", "remove-open", "existing-open",
                 "quarantine-rename", "quarantine-source-fsync", "quarantine-destination-fsync",
                 "root-anchor-open", "root-parent-component-open", "root-component-open",
                 "directory-create", "directory-open", "directory-fsync", "directory-parent-fsync",
                 "directory-fstat", "directory-mutation-fstat", "directory-fstatat", "directory-dup",
                 "directory-open-stream", "directory-read", "maintenance-open",
                 "maintenance-file-fsync", "maintenance-parent-fsync", "maintenance-quarantine",
                 "maintenance-quarantine-source-fsync", "maintenance-quarantine-destination-fsync",
                 "file-fstat", "file-fstatat", "shard-prune-parent-fsync", "shard-prune",
                 "manifest-read", "manifest-write", "open", "private-rename", "private-unlink",
                 "descriptor-stat", "path-stat":
                operation
            default:
                "other"
            }
        }
    }

    struct WorkspaceCodemapGraphIndexDebugEvent: Hashable {
        let ordinal: UInt64
        let uptimeNanoseconds: UInt64
        let kind: WorkspaceCodemapBindingEngineHookKind
        let rootID: UUID
        let rootLifetimeID: UUID
        let jobID: UUID?
        let phase: WorkspaceCodemapGraphIndexPhase?
        let workerPresent: Bool?
        let isQueuedForAdmission: Bool?
        let queuePosition: Int?
        let isActiveBatch: Bool?
        let drainingBatchCount: Int?
        let admissionWaitAgeMilliseconds: UInt64?
        let phaseAgeMilliseconds: UInt64?
        let lastProgressAgeMilliseconds: UInt64?
        let pageOrdinal: UInt64?
        let cursorFingerprint: String?
        let numericValue: UInt64
        let projectedSupportedCandidateTotal: UInt64?
        let processedCandidateCount: UInt64?
        let candidateCount: UInt64?
        let completedCandidateCount: UInt64?
        let retryAttempt: UInt64?
        let retryAfterMilliseconds: UInt64?
        let reason: WorkspaceCodemapGraphIndexDebugReason?
        let manifestFailureReason: WorkspaceCodemapManifestFailureReason?
        let manifestFailureOperation: String?
        let currentAuthorityGeneration: UInt64?
        let observedPredecessorAuthorityGeneration: UInt64?
        let manifestAttemptStartedUptimeNanoseconds: UInt64?
        let manifestAttemptCompletedUptimeNanoseconds: UInt64?
        let manifestAttemptDurationNanoseconds: UInt64?
        let manifestMeasurementOrigin: WorkspaceCodemapManifestMeasurementOrigin?
        let manifestMeasurementRetryKind: WorkspaceCodemapManifestMeasurementRetryKind?
        let manifestMutationByteCount: UInt64?
        let manifestStoreAttempt: CodeMapRootManifestDebugAttemptMetrics?
        let coalescedCount: UInt64
    }

    struct WorkspaceCodemapGraphIndexDebugEventDraft {
        let uptimeNanoseconds: UInt64
        let kind: WorkspaceCodemapBindingEngineHookKind
        let rootEpoch: WorkspaceCodemapRootEpoch
        let jobID: UUID?
        let phase: WorkspaceCodemapGraphIndexPhase?
        let workerPresent: Bool?
        let isQueuedForAdmission: Bool?
        let queuePosition: Int?
        let isActiveBatch: Bool?
        let drainingBatchCount: Int?
        let admissionWaitAgeMilliseconds: UInt64?
        let phaseAgeMilliseconds: UInt64?
        let lastProgressAgeMilliseconds: UInt64?
        let pageOrdinal: UInt64?
        let cursorFingerprint: String?
        let numericValue: UInt64
        let projectedSupportedCandidateTotal: UInt64?
        let processedCandidateCount: UInt64?
        let candidateCount: UInt64?
        let completedCandidateCount: UInt64?
        let retryAttempt: UInt64?
        let retryAfterMilliseconds: UInt64?
        let reason: WorkspaceCodemapGraphIndexDebugReason?
        let manifestFailureReason: WorkspaceCodemapManifestFailureReason?
        let manifestFailureOperation: String?
        let currentAuthorityGeneration: UInt64?
        let observedPredecessorAuthorityGeneration: UInt64?
        let manifestAttemptStartedUptimeNanoseconds: UInt64?
        let manifestAttemptCompletedUptimeNanoseconds: UInt64?
        let manifestAttemptDurationNanoseconds: UInt64?
        let manifestMeasurementOrigin: WorkspaceCodemapManifestMeasurementOrigin?
        let manifestMeasurementRetryKind: WorkspaceCodemapManifestMeasurementRetryKind?
        let manifestMutationByteCount: UInt64?
        let manifestStoreAttempt: CodeMapRootManifestDebugAttemptMetrics?
    }

    struct WorkspaceCodemapGraphIndexDebugEventPage: Equatable {
        let events: [WorkspaceCodemapGraphIndexDebugEvent]
        /// Bounds of the retained ring, not the returned slice.
        let firstOrdinal: UInt64
        let lastOrdinal: UInt64
        /// Exclusive cursor for the next request: the last event returned by this slice.
        let nextOrdinal: UInt64?
    }

    struct WorkspaceCodemapGraphIndexDebugEventRing {
        static let capacity = 512

        private(set) var events: [WorkspaceCodemapGraphIndexDebugEvent] = []
        private var nextOrdinal: UInt64 = 0

        mutating func append(_ draft: WorkspaceCodemapGraphIndexDebugEventDraft) {
            if shouldCoalesce(draft), let last = events.last,
               last.kind == draft.kind,
               last.rootID == draft.rootEpoch.rootID,
               last.rootLifetimeID == draft.rootEpoch.rootLifetimeID,
               last.jobID == draft.jobID,
               last.phase == draft.phase,
               last.reason == nil,
               draft.reason == nil
            {
                nextOrdinal = addingSaturating(nextOrdinal, 1)
                events[events.count - 1] = WorkspaceCodemapGraphIndexDebugEvent(
                    ordinal: nextOrdinal,
                    uptimeNanoseconds: draft.uptimeNanoseconds,
                    kind: last.kind,
                    rootID: last.rootID,
                    rootLifetimeID: last.rootLifetimeID,
                    jobID: last.jobID,
                    phase: last.phase,
                    workerPresent: draft.workerPresent ?? last.workerPresent,
                    isQueuedForAdmission: draft.isQueuedForAdmission ?? last.isQueuedForAdmission,
                    queuePosition: draft.queuePosition ?? last.queuePosition,
                    isActiveBatch: draft.isActiveBatch ?? last.isActiveBatch,
                    drainingBatchCount: draft.drainingBatchCount ?? last.drainingBatchCount,
                    admissionWaitAgeMilliseconds: draft.admissionWaitAgeMilliseconds
                        ?? last.admissionWaitAgeMilliseconds,
                    phaseAgeMilliseconds: draft.phaseAgeMilliseconds ?? last.phaseAgeMilliseconds,
                    lastProgressAgeMilliseconds: draft.lastProgressAgeMilliseconds
                        ?? last.lastProgressAgeMilliseconds,
                    pageOrdinal: draft.pageOrdinal ?? last.pageOrdinal,
                    cursorFingerprint: draft.cursorFingerprint ?? last.cursorFingerprint,
                    numericValue: addingSaturating(last.numericValue, draft.numericValue),
                    projectedSupportedCandidateTotal: draft.projectedSupportedCandidateTotal
                        ?? last.projectedSupportedCandidateTotal,
                    processedCandidateCount: draft.processedCandidateCount ?? last.processedCandidateCount,
                    candidateCount: draft.candidateCount ?? last.candidateCount,
                    completedCandidateCount: draft.completedCandidateCount ?? last.completedCandidateCount,
                    retryAttempt: draft.retryAttempt ?? last.retryAttempt,
                    retryAfterMilliseconds: draft.retryAfterMilliseconds ?? last.retryAfterMilliseconds,
                    reason: nil,
                    manifestFailureReason: nil,
                    manifestFailureOperation: nil,
                    currentAuthorityGeneration: nil,
                    observedPredecessorAuthorityGeneration: nil,
                    manifestAttemptStartedUptimeNanoseconds: nil,
                    manifestAttemptCompletedUptimeNanoseconds: nil,
                    manifestAttemptDurationNanoseconds: nil,
                    manifestMeasurementOrigin: nil,
                    manifestMeasurementRetryKind: nil,
                    manifestMutationByteCount: nil,
                    manifestStoreAttempt: nil,
                    coalescedCount: addingSaturating(last.coalescedCount, 1)
                )
                return
            }

            nextOrdinal = addingSaturating(nextOrdinal, 1)
            events.append(WorkspaceCodemapGraphIndexDebugEvent(
                ordinal: nextOrdinal,
                uptimeNanoseconds: draft.uptimeNanoseconds,
                kind: draft.kind,
                rootID: draft.rootEpoch.rootID,
                rootLifetimeID: draft.rootEpoch.rootLifetimeID,
                jobID: draft.jobID,
                phase: draft.phase,
                workerPresent: draft.workerPresent,
                isQueuedForAdmission: draft.isQueuedForAdmission,
                queuePosition: draft.queuePosition,
                isActiveBatch: draft.isActiveBatch,
                drainingBatchCount: draft.drainingBatchCount,
                admissionWaitAgeMilliseconds: draft.admissionWaitAgeMilliseconds,
                phaseAgeMilliseconds: draft.phaseAgeMilliseconds,
                lastProgressAgeMilliseconds: draft.lastProgressAgeMilliseconds,
                pageOrdinal: draft.pageOrdinal,
                cursorFingerprint: draft.cursorFingerprint,
                numericValue: draft.numericValue,
                projectedSupportedCandidateTotal: draft.projectedSupportedCandidateTotal,
                processedCandidateCount: draft.processedCandidateCount,
                candidateCount: draft.candidateCount,
                completedCandidateCount: draft.completedCandidateCount,
                retryAttempt: draft.retryAttempt,
                retryAfterMilliseconds: draft.retryAfterMilliseconds,
                reason: draft.reason,
                manifestFailureReason: draft.manifestFailureReason,
                manifestFailureOperation: draft.manifestFailureOperation,
                currentAuthorityGeneration: draft.currentAuthorityGeneration,
                observedPredecessorAuthorityGeneration: draft.observedPredecessorAuthorityGeneration,
                manifestAttemptStartedUptimeNanoseconds: draft.manifestAttemptStartedUptimeNanoseconds,
                manifestAttemptCompletedUptimeNanoseconds: draft.manifestAttemptCompletedUptimeNanoseconds,
                manifestAttemptDurationNanoseconds: draft.manifestAttemptDurationNanoseconds,
                manifestMeasurementOrigin: draft.manifestMeasurementOrigin,
                manifestMeasurementRetryKind: draft.manifestMeasurementRetryKind,
                manifestMutationByteCount: draft.manifestMutationByteCount,
                manifestStoreAttempt: draft.manifestStoreAttempt,
                coalescedCount: 1
            ))
            if events.count > Self.capacity {
                events.removeFirst(events.count - Self.capacity)
            }
        }

        func page(
            rootID: UUID? = nil,
            sinceOrdinal: UInt64?,
            limit: Int
        ) -> WorkspaceCodemapGraphIndexDebugEventPage {
            let boundedLimit = min(max(0, limit), 1024)
            let rootEvents = events.filter { event in
                rootID.map { event.rootID == $0 } ?? true
            }
            let filtered = rootEvents.lazy.filter { event in
                sinceOrdinal.map { event.ordinal > $0 } ?? true
            }
            let pageEvents = Array(filtered.prefix(boundedLimit))
            return WorkspaceCodemapGraphIndexDebugEventPage(
                events: pageEvents,
                firstOrdinal: rootEvents.first?.ordinal ?? 0,
                lastOrdinal: rootEvents.last?.ordinal ?? 0,
                nextOrdinal: pageEvents.last?.ordinal
            )
        }

        private func shouldCoalesce(_ draft: WorkspaceCodemapGraphIndexDebugEventDraft) -> Bool {
            switch draft.kind {
            case .graphIndexCatalogCandidates, .graphIndexCatalogPathBytes,
                 .graphIndexChangePublished, .graphIndexEnvelopeHit,
                 .graphIndexTerminalRecordHit, .graphIndexLocatorMiss,
                 .graphIndexLocatorCorrupt, .graphIndexCASMiss,
                 .graphIndexArtifactBuildJoined, .graphIndexArtifactBuildStarted,
                 .graphIndexArtifactBuildCompleted:
                true
            default:
                false
            }
        }

        private func addingSaturating(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? .max : sum
        }
    }
#endif
