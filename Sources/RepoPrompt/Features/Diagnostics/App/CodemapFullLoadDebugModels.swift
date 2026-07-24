import Foundation

#if DEBUG
    enum CodemapFullLoadAggregateState: String, Equatable {
        case ready
        case pending
        case failed
        case superseded
        case incompleteDiagnostics = "incomplete_diagnostics"
    }

    enum CodemapFullLoadRootState: String, Equatable {
        case ready
        case terminalIneligible = "terminal_ineligible"
        case excluded
        case pending
        case failed
        case superseded
    }

    struct CodemapFullLoadRootIdentity: Equatable {
        let rootEpoch: WorkspaceCodemapRootEpoch
        let catalogGeneration: UInt64
        let ingressGeneration: UInt64
        let engineIdentity: ObjectIdentifier?
    }

    struct CodemapFullLoadMilestone: Equatable {
        let kind: String
        let uptimeNanoseconds: UInt64
    }

    struct CodemapFullLoadRootSnapshot: Equatable {
        let rootEpoch: WorkspaceCodemapRootEpoch
        let catalogGeneration: UInt64
        let ingressGeneration: UInt64
        let rootKind: String
        let state: CodemapFullLoadRootState
        let reason: String?
        let launchPhase: String?
        let graphIndexPhase: String?
        let supportedCandidateCount: UInt64?
        let processedCandidateCount: UInt64?
        let terminalCount: UInt64?
        let lastGraphChangeSequence: UInt64?
        let readyUptimeNanoseconds: UInt64?
        let metrics: [String: UInt64]
        let resources: [String: UInt64]
        let queueWaitMilliseconds: [UInt64]
        let milestones: [CodemapFullLoadMilestone]
    }

    struct CodemapFullLoadAggregateSnapshot: Equatable {
        let expectedWorkspaceID: UUID
        let state: CodemapFullLoadAggregateState
        let sampledUptimeNanoseconds: UInt64
        let visibleRootCount: Int
        let eligibleRootCount: Int
        let readyRootCount: Int
        let terminalIneligibleRootCount: Int
        let excludedRootCount: Int
        let pendingRootCount: Int
        let failedRootCount: Int
        let supersededRootCount: Int
        let cohort: String
        let roots: [CodemapFullLoadRootSnapshot]
        let metrics: [String: UInt64]
        let resources: [String: UInt64]
        let queueWaitMilliseconds: [UInt64]
    }

    enum CodemapFullLoadSwitchResult: String, Equatable {
        case pending
        case switched
        case cancelled
        case blocked
    }

    struct CodemapFullLoadCorrelation: Equatable {
        let armID: UUID
        let targetWorkspaceID: UUID
        let targetWorkspaceName: String
        let pollIntervalMilliseconds: Int
        let timeoutMilliseconds: Int
        let armedUptimeNanoseconds: UInt64
        var operationID: UUID?
        var acceptedUptimeNanoseconds: UInt64?
        var switchResult: CodemapFullLoadSwitchResult
        var invalidReason: String?

        mutating func recordAccepted(
            operationID: UUID,
            targetWorkspaceID: UUID,
            uptimeNanoseconds: UInt64
        ) -> Bool {
            guard invalidReason == nil,
                  self.targetWorkspaceID == targetWorkspaceID,
                  self.operationID == nil
            else { return false }
            self.operationID = operationID
            acceptedUptimeNanoseconds = uptimeNanoseconds
            switchResult = .pending
            return true
        }

        mutating func recordCompletion(
            operationID: UUID,
            result: WorkspaceSwitchResult
        ) -> Bool {
            guard invalidReason == nil, self.operationID == operationID else { return false }
            switch result {
            case .switched:
                switchResult = .switched
            case .cancelled:
                switchResult = .cancelled
                invalidReason = "switch_cancelled"
            case .blocked:
                switchResult = .blocked
                invalidReason = "switch_blocked"
            }
            return true
        }
    }

    enum CodemapFullLoadArmError: Error, Equatable {
        case targetNotFound
        case targetAmbiguous
        case targetAlreadyActive
    }

    struct CodemapFullLoadSampleStatistics: Equatable {
        let raw: [Double]
        let median: Double
        let nearestRankP95: Double
        let mean: Double
        let sampleStandardDeviation: Double
        let coefficientOfVariation: Double
        let medianAbsoluteDeviation: Double
        let relativeMedianAbsoluteDeviation: Double
        let tukeyOutlierIndices: [Int]
        let reliability: String
    }

    enum CodemapFullLoadDebugSupport {
        static func universeMatches(
            _ lhs: [CodemapFullLoadRootIdentity],
            _ rhs: [CodemapFullLoadRootIdentity]
        ) -> Bool {
            lhs == rhs
        }

        static func aggregateState(for roots: [CodemapFullLoadRootSnapshot]) -> CodemapFullLoadAggregateState {
            guard !roots.isEmpty else { return .incompleteDiagnostics }
            if roots.contains(where: { $0.state == .superseded }) {
                return .superseded
            }
            if roots.contains(where: { $0.state == .failed }) {
                return .failed
            }
            if roots.allSatisfy({ $0.state == .ready || $0.state == .terminalIneligible || $0.state == .excluded }) {
                return .ready
            }
            return .pending
        }

        static func cohort(metrics: [String: UInt64]) -> String {
            if (metrics["graph_index_artifact_builds_started"] ?? 0) > 0 ||
                (metrics["materializations"] ?? 0) > 0
            {
                return "cold-build"
            }
            if (metrics["classifications"] ?? 0) > 0 ||
                (metrics["locator_fast_paths"] ?? 0) > 0 ||
                (metrics["cas_fast_paths"] ?? 0) > 0
            {
                return "reuse-partial"
            }
            let candidates = metrics["graph_index_catalog_candidates"] ?? 0
            if candidates > 0, (metrics["graph_index_envelope_hits"] ?? 0) >= candidates {
                return "warm-envelope"
            }
            return "mixed"
        }

        static func adding(
            _ lhs: [String: UInt64],
            _ rhs: [String: UInt64]
        ) -> [String: UInt64] {
            rhs.reduce(into: lhs) { result, entry in
                let (sum, overflow) = (result[entry.key] ?? 0).addingReportingOverflow(entry.value)
                result[entry.key] = overflow ? .max : sum
            }
        }

        static func statistics(_ raw: [Double]) -> CodemapFullLoadSampleStatistics? {
            guard !raw.isEmpty else { return nil }
            let sorted = raw.sorted()
            let median = percentile(sorted, fraction: 0.5)
            let p95 = nearestRank(sorted, percentile: 0.95)
            let mean = raw.reduce(0, +) / Double(raw.count)
            let variance = raw.count > 1
                ? raw.reduce(0) { $0 + pow($1 - mean, 2) } / Double(raw.count - 1)
                : 0
            let standardDeviation = sqrt(variance)
            let deviations = raw.map { abs($0 - median) }.sorted()
            let mad = percentile(deviations, fraction: 0.5)
            let cv = mean == 0 ? 0 : standardDeviation / mean
            let relativeMAD = median == 0 ? 0 : mad / median
            var outliers: [Int] = []
            if raw.count >= 4 {
                let q1 = percentile(sorted, fraction: 0.25)
                let q3 = percentile(sorted, fraction: 0.75)
                let iqr = q3 - q1
                let lower = q1 - 1.5 * iqr
                let upper = q3 + 1.5 * iqr
                outliers = raw.indices.filter { raw[$0] < lower || raw[$0] > upper }
            }
            let reliability = cv <= 0.10 ? "high" : (cv <= 0.20 ? "moderate" : "low")
            return CodemapFullLoadSampleStatistics(
                raw: raw,
                median: median,
                nearestRankP95: p95,
                mean: mean,
                sampleStandardDeviation: standardDeviation,
                coefficientOfVariation: cv,
                medianAbsoluteDeviation: mad,
                relativeMedianAbsoluteDeviation: relativeMAD,
                tukeyOutlierIndices: outliers,
                reliability: reliability
            )
        }

        private static func percentile(_ sorted: [Double], fraction: Double) -> Double {
            guard sorted.count > 1 else { return sorted[0] }
            let position = fraction * Double(sorted.count - 1)
            let lower = Int(position.rounded(.down))
            let upper = Int(position.rounded(.up))
            guard lower != upper else { return sorted[lower] }
            let weight = position - Double(lower)
            return sorted[lower] * (1 - weight) + sorted[upper] * weight
        }

        private static func nearestRank(_ sorted: [Double], percentile: Double) -> Double {
            let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
            return sorted[min(rank - 1, sorted.count - 1)]
        }

        static func graphIndexPhaseName(_ phase: WorkspaceCodemapGraphIndexPhase) -> String {
            switch phase {
            case .scheduled: "scheduled"
            case .waitingForAdmission: "waiting_for_admission"
            case .readingCatalogPage: "reading_catalog_page"
            case .loadingEnvelopes: "loading_envelopes"
            case .classifyingBatch: "classifying_batch"
            case .resolvingArtifacts: "resolving_artifacts"
            case .writingManifestCheckpoint: "writing_manifest_checkpoint"
            case .publishingGraphChanges: "publishing_graph_changes"
            case .checkpointed: "checkpointed"
            case .suspendedBusy: "suspended_busy"
            case .budgetLimited: "budget_limited"
            case .complete: "complete"
            case .cancelled: "cancelled"
            case .superseded: "superseded"
            }
        }

        static func launchPhaseName(_ phase: WorkspaceCodemapGraphIndexLaunchPhase) -> String {
            switch phase {
            case .notScheduled: "not_scheduled"
            case .eligibilityQueued: "eligibility_queued"
            case .setupJoining: "setup_joining"
            case .engineScheduling: "engine_scheduling"
            case .handedOff: "handed_off"
            case .terminalNonGit: "terminal_non_git"
            case .transientRetry: "transient_retry"
            case .cancelled: "cancelled"
            case .superseded: "superseded"
            }
        }

        static func rootKindName(_ kind: WorkspaceRootKind) -> String {
            switch kind {
            case .primaryWorkspace: "primary_workspace"
            case .workspaceGitData: "workspace_git_data"
            case .supplementalSystem: "supplemental_system"
            case .sessionWorktree: "session_worktree"
            }
        }

        static func metrics(_ accounting: WorkspaceCodemapBindingEngineAccounting) -> [String: UInt64] {
            let counters = accounting.counters
            return [
                "classifications": counters.classifications,
                "locator_fast_paths": counters.locatorFastPaths,
                "cas_fast_paths": counters.casFastPaths,
                "materializations": counters.materializations,
                "materialized_bytes": counters.materializedBytes,
                "validated_worktree_reads": counters.validatedWorktreeReads,
                "validated_worktree_bytes": counters.validatedWorktreeBytes,
                "graph_index_runs_scheduled": counters.graphIndexRunsScheduled,
                "graph_index_runs_started": counters.graphIndexRunsStarted,
                "graph_index_envelope_hits": counters.graphIndexEnvelopeHits,
                "graph_index_envelope_stale": counters.graphIndexEnvelopeStale,
                "graph_index_envelope_invalid": counters.graphIndexEnvelopeInvalid,
                "graph_index_locator_misses": counters.graphIndexLocatorMisses,
                "graph_index_locator_corruptions": counters.graphIndexLocatorCorruptions,
                "graph_index_cas_misses": counters.graphIndexCASMisses,
                "graph_index_artifact_builds_joined": counters.graphIndexArtifactBuildsJoined,
                "graph_index_artifact_builds_started": counters.graphIndexArtifactBuildsStarted,
                "graph_index_artifact_builds_completed": counters.graphIndexArtifactBuildsCompleted,
                "graph_index_catalog_pages": counters.graphIndexCatalogPages,
                "graph_index_catalog_candidates": counters.graphIndexCatalogCandidates,
                "graph_index_catalog_path_bytes": counters.graphIndexCatalogPathBytes,
                "graph_index_changes_published": counters.graphIndexChangesPublished,
                "graph_index_change_bytes": counters.graphIndexChangeBytes,
                "graph_index_retries": counters.graphIndexRetries,
                "graph_index_budget_rejections": counters.graphIndexBudgetRejections,
                "manifest_writes": counters.manifestWrites,
                "manifest_failures": counters.manifestFailures,
                "failures": counters.failures
            ]
        }

        static func resources(_ accounting: WorkspaceCodemapBindingEngineAccounting) -> [String: UInt64] {
            let resources = accounting.graphIndexResources
            return [
                "retained_path_bytes": resources.retainedPathBytes,
                "retained_source_bytes": resources.retainedSourceBytes,
                "retained_graph_index_bytes": resources.retainedGraphIndexBytes,
                "staged_graph_bytes": resources.stagedGraphBytes,
                "resident_graph_bytes": resources.residentGraphBytes,
                "queued_manifest_mutation_bytes": resources.queuedManifestMutationBytes
            ]
        }

        static func privacySafeRootPayload(_ root: CodemapFullLoadRootSnapshot) -> [String: Any] {
            [
                "root_id": root.rootEpoch.rootID.uuidString,
                "root_lifetime_id": root.rootEpoch.rootLifetimeID.uuidString,
                "catalog_generation": root.catalogGeneration,
                "ingress_generation": root.ingressGeneration,
                "root_kind": root.rootKind,
                "state": root.state.rawValue,
                "reason": root.reason ?? NSNull(),
                "launch_phase": root.launchPhase ?? NSNull(),
                "graph_index_phase": root.graphIndexPhase ?? NSNull(),
                "supported_candidate_count": root.supportedCandidateCount ?? NSNull(),
                "processed_candidate_count": root.processedCandidateCount ?? NSNull(),
                "terminal_count": root.terminalCount ?? NSNull(),
                "last_graph_change_sequence": root.lastGraphChangeSequence ?? NSNull(),
                "ready_uptime_ns": root.readyUptimeNanoseconds ?? NSNull(),
                "metrics": root.metrics,
                "resources": root.resources,
                "queue_wait_ms": root.queueWaitMilliseconds,
                "milestones": root.milestones.map {
                    [
                        "kind": $0.kind,
                        "uptime_ns": $0.uptimeNanoseconds
                    ]
                }
            ]
        }
    }
#endif
