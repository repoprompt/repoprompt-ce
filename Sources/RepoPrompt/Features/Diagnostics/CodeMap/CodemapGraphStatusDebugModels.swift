import Foundation

#if DEBUG
    /// Stable, privacy-safe payload model for the attachable `codemap_graph_status` DEBUG MCP operation.
    struct CodemapGraphStatusStoreEventSnapshot: Equatable {
        let ordinal: UInt64
        let rootEpoch: WorkspaceCodemapRootEpoch
        let kind: String
        let launchPhase: String
        let uptimeNanoseconds: UInt64
    }

    struct CodemapGraphStatusStoreEventPage: Equatable {
        let firstOrdinal: UInt64
        let lastOrdinal: UInt64
        let nextOrdinal: UInt64?
        let events: [CodemapGraphStatusStoreEventSnapshot]
    }

    struct CodemapGraphStatusRetrySnapshot: Equatable {
        let attempt: Int
        let deadlineUptimeNanoseconds: UInt64
    }

    struct CodemapGraphStatusRetryExhaustionSnapshot: Equatable {
        let attempt: Int
        let uptimeNanoseconds: UInt64
    }

    struct CodemapGraphStatusLaunchSnapshot: Equatable {
        let id: UUID
        let phase: WorkspaceCodemapGraphIndexLaunchPhase
        let retryAttempt: Int
        let taskPresent: Bool
        let createdUptimeNanoseconds: UInt64
        let phaseEnteredUptimeNanoseconds: UInt64
        let retry: CodemapGraphStatusRetrySnapshot?
        let retryExhaustion: CodemapGraphStatusRetryExhaustionSnapshot?
    }

    struct CodemapGraphStatusAdmissionSnapshot: Equatable {
        let metrics: [String: UInt64]
        let queueWaitMilliseconds: [UInt64]
    }

    struct CodemapGraphStatusManifestSnapshot: Equatable {
        let failureCounts: [WorkspaceCodemapManifestFailureReason: UInt64]
        let lastFailure: WorkspaceCodemapManifestFailureDiagnostic?
        let measurements: WorkspaceCodemapManifestMeasurementSnapshot
    }

    struct CodemapGraphStatusRootSnapshot: Equatable {
        let rootEpoch: WorkspaceCodemapRootEpoch
        let catalogGeneration: UInt64
        let ingressGeneration: UInt64
        let rootKind: WorkspaceRootKind
        let eligibilityFlightPresent: Bool
        let launch: CodemapGraphStatusLaunchSnapshot?
        let job: WorkspaceCodemapBindingEngineGraphIndexRootAccounting?
        let admission: CodemapGraphStatusAdmissionSnapshot?
        let manifest: CodemapGraphStatusManifestSnapshot?
        let milestones: [CodemapGraphStatusStoreEventSnapshot]
        let engineEvents: WorkspaceCodemapGraphIndexDebugEventPage?
    }

    struct CodemapGraphStatusSnapshot: Equatable {
        let sampledUptimeNanoseconds: UInt64
        let roots: [CodemapGraphStatusRootSnapshot]
        let storeEvents: CodemapGraphStatusStoreEventPage?
        let graphIndexJobCount: Int
        let queuedGraphIndexBatchCount: Int
        let activeGraphIndexBatchCount: Int
        let drainingGraphIndexTaskCount: Int
    }

    enum CodemapGraphStatusDebugSupport {
        static func payload(
            snapshot: CodemapGraphStatusSnapshot,
            op: String,
            windowID: Int,
            workspaceID: UUID?
        ) -> [String: Any] {
            [
                "ok": true,
                "op": op,
                "schema_version": 1,
                "window_id": windowID,
                "workspace_id": workspaceID?.uuidString ?? NSNull(),
                "sampled_uptime_ns": snapshot.sampledUptimeNanoseconds,
                "roots": snapshot.roots.map { rootPayload($0, sampled: snapshot.sampledUptimeNanoseconds) },
                "store_events": snapshot.storeEvents.map(storeEventPagePayload) ?? NSNull(),
                "engine_events": snapshot.roots.compactMap { root -> [String: Any]? in
                    guard let page = root.engineEvents else { return nil }
                    return [
                        "root_id": root.rootEpoch.rootID.uuidString,
                        "first_ordinal": page.firstOrdinal,
                        "last_ordinal": page.lastOrdinal,
                        "next_ordinal": page.nextOrdinal ?? NSNull(),
                        "events": page.events.map(eventPayload)
                    ]
                },
                "totals": [
                    "job_count": snapshot.graphIndexJobCount,
                    "queued_batches": snapshot.queuedGraphIndexBatchCount,
                    "active_batches": snapshot.activeGraphIndexBatchCount,
                    "draining_tasks": snapshot.drainingGraphIndexTaskCount
                ]
            ]
        }

        private static func rootPayload(
            _ root: CodemapGraphStatusRootSnapshot,
            sampled: UInt64
        ) -> [String: Any] {
            [
                "root_id": root.rootEpoch.rootID.uuidString,
                "root_lifetime_id": root.rootEpoch.rootLifetimeID.uuidString,
                "root_kind": CodemapFullLoadDebugSupport.rootKindName(root.rootKind),
                "catalog_generation": root.catalogGeneration,
                "ingress_generation": root.ingressGeneration,
                "eligibility_flight_present": root.eligibilityFlightPresent,
                "launch": root.launch.map { launchPayload($0, sampled: sampled) } ?? NSNull(),
                "job": root.job.map { jobPayload($0, sampled: sampled) } ?? NSNull(),
                "engine_admission": root.admission.map {
                    [
                        "metrics": $0.metrics,
                        "queue_wait_ms": $0.queueWaitMilliseconds
                    ]
                } ?? NSNull(),
                "manifest": root.manifest.map(manifestPayload) ?? NSNull(),
                "milestones": root.milestones.map(storeEventPayload)
            ]
        }

        private static func launchPayload(
            _ launch: CodemapGraphStatusLaunchSnapshot,
            sampled: UInt64
        ) -> [String: Any] {
            [
                "id": launch.id.uuidString,
                "phase": CodemapFullLoadDebugSupport.launchPhaseName(launch.phase),
                "retry_attempt": launch.retryAttempt,
                "task_present": launch.taskPresent,
                "created_uptime_ns": launch.createdUptimeNanoseconds,
                "phase_entered_uptime_ns": launch.phaseEnteredUptimeNanoseconds,
                "phase_age_ms": ageMilliseconds(sampled: sampled, instant: launch.phaseEnteredUptimeNanoseconds),
                "retry": launch.retry.map {
                    [
                        "attempt": $0.attempt,
                        "deadline_uptime_ns": $0.deadlineUptimeNanoseconds,
                        "deadline_in_ms": signedMilliseconds(from: sampled, to: $0.deadlineUptimeNanoseconds)
                    ]
                } ?? NSNull(),
                "retry_exhausted": launch.retryExhaustion.map {
                    [
                        "attempt": $0.attempt,
                        "uptime_ns": $0.uptimeNanoseconds
                    ]
                } ?? NSNull()
            ]
        }

        private static func jobPayload(
            _ job: WorkspaceCodemapBindingEngineGraphIndexRootAccounting,
            sampled: UInt64
        ) -> [String: Any] {
            let counts = job.progress.counts
            return [
                "id": job.jobID.uuidString,
                "phase": CodemapFullLoadDebugSupport.graphIndexPhaseName(job.phase),
                "worker_present": job.workerPresent,
                "worker_recovery_count": job.workerRecoveryCount,
                "worker_completion_reason": job.lastWorkerCompletionReason?.rawValue ?? NSNull(),
                "priority_promoted": job.isPriorityPromoted,
                "queued_for_admission": job.isQueuedForAdmission,
                "queue_position": job.queuePosition ?? NSNull(),
                "queued_batch_count": job.queuedBatchCount,
                "active_batch_count": job.activeBatchCount,
                "draining_batch_count": job.drainingBatchCount,
                "scheduled_uptime_ns": job.scheduledUptimeNanoseconds,
                "admission_wait_start_uptime_ns": job.admissionWaitStartUptimeNanoseconds ?? NSNull(),
                "admitted_uptime_ns": job.admittedUptimeNanoseconds ?? NSNull(),
                "phase_entered_uptime_ns": job.phaseEnteredUptimeNanoseconds,
                "phase_age_ms": ageMilliseconds(sampled: sampled, instant: job.phaseEnteredUptimeNanoseconds),
                "last_progress_uptime_ns": job.lastProgressUptimeNanoseconds,
                "last_progress_age_ms": ageMilliseconds(sampled: sampled, instant: job.lastProgressUptimeNanoseconds),
                "worker_finished_uptime_ns": job.workerFinishedUptimeNanoseconds ?? NSNull(),
                "retry_attempt": job.retryAttempt,
                "retry": job.retry.map { retry -> [String: Any] in
                    [
                        "attempt": retry.attempt,
                        "retry_after_ms": retry.retryAfterMilliseconds.map { $0 as Any } ?? NSNull(),
                        "next_eligible_admission_uptime_ns":
                            retry.nextEligibleAdmissionUptimeNanoseconds.map { $0 as Any } ?? NSNull()
                    ]
                } ?? NSNull(),
                "budget": job.budget.map {
                    [
                        "dimension": String(describing: $0.dimension),
                        "attempted": $0.attempted,
                        "limit": $0.limit
                    ]
                } ?? NSNull(),
                "checkpoint_present": job.checkpointPresent,
                "page_ordinal": job.pageOrdinal,
                "cursor_present": job.cursorPresent,
                "cursor_fingerprint": job.cursorFingerprint ?? NSNull(),
                "projected_supported_candidate_total":
                    job.lastProjectedSupportedCandidateTotal ?? NSNull(),
                "page_start_processed_candidate_baseline":
                    job.pageStartProcessedCandidateBaseline ?? NSNull(),
                "counts": [
                    "supported": counts.supportedCandidateCount,
                    "processed": counts.processedCandidateCount,
                    "contributed": counts.contributedCount,
                    "empty": counts.emptyCount,
                    "terminal_artifacts": counts.terminalArtifactCount,
                    "terminal_excluded": counts.terminalExcludedCount,
                    "transient": counts.transientCount
                ],
                "in_batch": job.inBatchCandidateCount.map {
                    [
                        "candidate_count": $0,
                        "resolved": job.inBatchResolvedCandidateCount ?? 0
                    ]
                } ?? NSNull(),
                "published": [
                    "change_count": job.progress.publishedGraphChangeCount,
                    "change_bytes": job.progress.publishedGraphChangeByteCount
                ],
                "resources": resourcePayload(job.resources),
                "manifest_measurements": manifestMeasurementPayload(job.manifestMeasurements)
            ]
        }

        private static func eventPayload(
            _ event: WorkspaceCodemapGraphIndexDebugEvent
        ) -> [String: Any] {
            [
                "ordinal": event.ordinal,
                "uptime_ns": event.uptimeNanoseconds,
                "kind": event.kind.rawValue,
                "root_id": event.rootID.uuidString,
                "root_lifetime_id": event.rootLifetimeID.uuidString,
                "job_id": event.jobID?.uuidString ?? NSNull(),
                "phase": event.phase.map(CodemapFullLoadDebugSupport.graphIndexPhaseName) ?? NSNull(),
                "worker_present": event.workerPresent ?? NSNull(),
                "queued_for_admission": event.isQueuedForAdmission ?? NSNull(),
                "queue_position": event.queuePosition ?? NSNull(),
                "active_batch": event.isActiveBatch ?? NSNull(),
                "draining_batch_count": event.drainingBatchCount ?? NSNull(),
                "admission_wait_age_ms": event.admissionWaitAgeMilliseconds ?? NSNull(),
                "phase_age_ms": event.phaseAgeMilliseconds ?? NSNull(),
                "last_progress_age_ms": event.lastProgressAgeMilliseconds ?? NSNull(),
                "page_ordinal": event.pageOrdinal ?? NSNull(),
                "cursor_fingerprint": event.cursorFingerprint ?? NSNull(),
                "numeric_value": event.numericValue,
                "projected_supported_candidate_total":
                    event.projectedSupportedCandidateTotal ?? NSNull(),
                "processed_candidate_count": event.processedCandidateCount ?? NSNull(),
                "candidate_count": event.candidateCount ?? NSNull(),
                "completed_candidate_count": event.completedCandidateCount ?? NSNull(),
                "retry_attempt": event.retryAttempt ?? NSNull(),
                "retry_after_ms": event.retryAfterMilliseconds ?? NSNull(),
                "reason": event.reason?.rawValue ?? NSNull(),
                "manifest_failure_reason": event.manifestFailureReason?.rawValue ?? NSNull(),
                "manifest_failure_operation": event.manifestFailureOperation ?? NSNull(),
                "current_authority_generation": event.currentAuthorityGeneration ?? NSNull(),
                "observed_predecessor_authority_generation":
                    event.observedPredecessorAuthorityGeneration ?? NSNull(),
                "manifest_attempt_started_uptime_ns":
                    event.manifestAttemptStartedUptimeNanoseconds ?? NSNull(),
                "manifest_attempt_completed_uptime_ns":
                    event.manifestAttemptCompletedUptimeNanoseconds ?? NSNull(),
                "manifest_attempt_duration_ns": event.manifestAttemptDurationNanoseconds ?? NSNull(),
                "manifest_measurement_origin": event.manifestMeasurementOrigin?.rawValue ?? NSNull(),
                "manifest_measurement_retry_kind":
                    event.manifestMeasurementRetryKind?.rawValue ?? NSNull(),
                "manifest_mutation_bytes": event.manifestMutationByteCount ?? NSNull(),
                "manifest_store_attempt": event.manifestStoreAttempt.map(manifestAttemptPayload) ?? NSNull(),
                "coalesced_count": event.coalescedCount
            ]
        }

        private static func manifestPayload(
            _ snapshot: CodemapGraphStatusManifestSnapshot
        ) -> [String: Any] {
            [
                "failure_counts": Dictionary(uniqueKeysWithValues: snapshot.failureCounts.map {
                    ($0.key.rawValue, $0.value)
                }),
                "last_failure": snapshot.lastFailure.map { failure in
                    [
                        "reason": failure.reason.rawValue,
                        "operation": failure.operation.map { $0 as Any } ?? NSNull(),
                        "current_authority_generation":
                            failure.currentAuthorityGeneration.map { $0 as Any } ?? NSNull(),
                        "observed_predecessor_authority_generation":
                            failure.observedPredecessorAuthorityGeneration.map { $0 as Any } ?? NSNull(),
                        "attempt_started_uptime_ns": failure.attemptStartedUptimeNanoseconds,
                        "attempt_completed_uptime_ns": failure.attemptCompletedUptimeNanoseconds,
                        "attempt_duration_ns": failure.attemptDurationNanoseconds
                    ]
                } ?? NSNull(),
                "measurements": Dictionary(uniqueKeysWithValues: snapshot.measurements.byOrigin.map {
                    ($0.key.rawValue, manifestMeasurementPayload($0.value))
                })
            ]
        }

        private static func manifestMeasurementPayload(
            _ measurement: WorkspaceCodemapManifestMeasurementAggregate
        ) -> [String: UInt64] {
            [
                "load_count": measurement.loadCount,
                "load_duration_ns": measurement.loadDurationNanoseconds,
                "submission_count": measurement.submissionCount,
                "wait_count": measurement.waitCount,
                "store_attempt_count": measurement.storeAttemptCount,
                "write_count": measurement.writeCount,
                "failure_count": measurement.failureCount,
                "retry_attempt_count": measurement.retryAttemptCount,
                "mutation_count_volume": measurement.mutationCountVolume,
                "mutation_byte_volume": measurement.mutationByteVolume,
                "input_snapshot_record_volume": measurement.inputSnapshotRecordVolume,
                "input_snapshot_byte_volume": measurement.inputSnapshotByteVolume,
                "decoded_byte_volume": measurement.decodedByteVolume,
                "attempted_output_snapshot_record_volume":
                    measurement.attemptedOutputSnapshotRecordVolume,
                "attempted_output_snapshot_byte_volume":
                    measurement.attemptedOutputSnapshotByteVolume,
                "output_snapshot_record_volume": measurement.outputSnapshotRecordVolume,
                "output_snapshot_byte_volume": measurement.outputSnapshotByteVolume,
                "load_read_decode_duration_ns": measurement.loadReadDecodeDurationNanoseconds,
                "merge_duration_ns": measurement.mergeDurationNanoseconds,
                "sort_duration_ns": measurement.sortDurationNanoseconds,
                "encode_duration_ns": measurement.encodeDurationNanoseconds,
                "temporary_write_duration_ns": measurement.temporaryWriteDurationNanoseconds,
                "temporary_file_sync_duration_ns": measurement.temporaryFileSyncDurationNanoseconds,
                "atomic_replace_duration_ns": measurement.atomicReplaceDurationNanoseconds,
                "manifest_directory_sync_duration_ns":
                    measurement.manifestDirectorySyncDurationNanoseconds,
                "readback_decode_duration_ns": measurement.readbackDecodeDurationNanoseconds,
                "total_duration_ns": measurement.totalDurationNanoseconds
            ]
        }

        private static func manifestAttemptPayload(
            _ attempt: CodeMapRootManifestDebugAttemptMetrics
        ) -> [String: Any] {
            [
                "ordinal": attempt.ordinal,
                "started_uptime_ns": attempt.startedUptimeNanoseconds,
                "completed_uptime_ns": attempt.completedUptimeNanoseconds,
                "succeeded": attempt.succeeded,
                "published": attempt.published,
                "input_snapshot_record_count": attempt.inputSnapshotRecordCount,
                "input_snapshot_encoded_bytes": attempt.inputSnapshotEncodedByteCount,
                "decoded_bytes": attempt.decodedByteCount,
                "mutation_count": attempt.mutationCount,
                "output_snapshot_record_count": attempt.outputSnapshotRecordCount,
                "output_snapshot_encoded_bytes": attempt.outputSnapshotEncodedByteCount,
                "load_read_decode_duration_ns": attempt.loadReadDecodeDurationNanoseconds,
                "merge_duration_ns": attempt.mergeDurationNanoseconds,
                "sort_duration_ns": attempt.sortDurationNanoseconds,
                "encode_duration_ns": attempt.encodeDurationNanoseconds,
                "temporary_write_duration_ns": attempt.temporaryWriteDurationNanoseconds,
                "temporary_file_sync_duration_ns": attempt.temporaryFileSyncDurationNanoseconds,
                "atomic_replace_duration_ns": attempt.atomicReplaceDurationNanoseconds,
                "manifest_directory_sync_duration_ns":
                    attempt.manifestDirectorySyncDurationNanoseconds,
                "readback_decode_duration_ns": attempt.readbackDecodeDurationNanoseconds,
                "total_duration_ns": attempt.totalDurationNanoseconds
            ]
        }

        private static func storeEventPagePayload(
            _ page: CodemapGraphStatusStoreEventPage
        ) -> [String: Any] {
            [
                "first_ordinal": page.firstOrdinal,
                "last_ordinal": page.lastOrdinal,
                "next_ordinal": page.nextOrdinal ?? NSNull(),
                "events": page.events.map(storeEventPayload)
            ]
        }

        private static func storeEventPayload(
            _ event: CodemapGraphStatusStoreEventSnapshot
        ) -> [String: Any] {
            [
                "ordinal": event.ordinal,
                "root_id": event.rootEpoch.rootID.uuidString,
                "root_lifetime_id": event.rootEpoch.rootLifetimeID.uuidString,
                "kind": event.kind,
                "launch_phase": event.launchPhase,
                "uptime_ns": event.uptimeNanoseconds
            ]
        }

        private static func resourcePayload(
            _ resources: WorkspaceCodemapGraphIndexResourceAccounting
        ) -> [String: UInt64] {
            [
                "retained_path_bytes": resources.retainedPathBytes,
                "retained_source_bytes": resources.retainedSourceBytes,
                "retained_graph_index_bytes": resources.retainedGraphIndexBytes,
                "staged_graph_bytes": resources.stagedGraphBytes,
                "resident_graph_bytes": resources.residentGraphBytes,
                "queued_manifest_mutation_bytes": resources.queuedManifestMutationBytes
            ]
        }

        private static func ageMilliseconds(sampled: UInt64, instant: UInt64) -> UInt64 {
            sampled >= instant ? (sampled - instant) / 1_000_000 : 0
        }

        private static func signedMilliseconds(from sampled: UInt64, to deadline: UInt64) -> Int64 {
            if deadline >= sampled {
                return Int64(clamping: (deadline - sampled) / 1_000_000)
            }
            return -Int64(clamping: (sampled - deadline) / 1_000_000)
        }
    }
#endif
