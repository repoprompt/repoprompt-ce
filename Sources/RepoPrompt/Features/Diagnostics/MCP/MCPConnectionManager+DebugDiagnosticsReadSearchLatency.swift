// MARK: - DEBUG MCP Read/Search Latency Diagnostics

import Foundation
import MCP

#if DEBUG
    extension ServerNetworkManager {
        func debugMCPReadSearchCaptureBeginPayload(op: String, arguments: [String: Value]) -> CallTool.Result {
            guard let rawLabel = debugString(arguments, "label"),
                  let label = debugMCPReadSearchCaptureLabel(rawLabel)
            else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "Missing required non-empty string argument `label`.")
            }

            let maxSamples: Int
            switch debugBoundedInt(arguments, "max_samples", defaultValue: 20000, range: 100 ... 100_000) {
            case let .value(parsed), let .defaulted(parsed):
                maxSamples = parsed
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`max_samples` must be an integer between 100 and 100000.")
            }

            switch EditFlowPerf.beginDebugCapture(label: label, maxSamples: maxSamples) {
            case let .started(snapshot):
                return debugDiagnosticsResult([
                    "ok": true,
                    "op": op,
                    "capture": snapshot.payload()
                ])
            case let .busy(snapshot):
                return debugDiagnosticsError(
                    op: op,
                    code: "capture_busy",
                    message: "A read/search latency capture is already active with label `\(snapshot.label)`."
                )
            }
        }

        func debugMCPReadSearchCaptureSnapshotPayload(op: String, arguments: [String: Value]) -> CallTool.Result {
            let finish = debugBool(arguments, "finish") ?? true
            let includeTimeline = debugBool(arguments, "include_timeline") ?? true
            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: finish)
            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "capture": snapshot.payload(includeTimeline: includeTimeline)
            ])
        }

        func debugMCPReadSearchAdmissionSnapshotPayload(
            op: String,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            let requestedWindowID: Int?
            switch debugSearchLaneWindowID(arguments, op: op) {
            case let .success(windowID):
                requestedWindowID = windowID
            case let .failure(result):
                return result
            }

            let targets = await debugSearchLaneTargets(windowID: requestedWindowID)
            if let requestedWindowID, targets.isEmpty {
                return debugDiagnosticsError(op: op, code: "no_window", message: "No RepoPrompt window matched window_id \(requestedWindowID).")
            }
            let entries = await debugSearchLaneSnapshots(targets)
            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "admission": searchLaneAdmissionPayload(entries)
            ])
        }

        func debugMCPReadSearchAdmissionConfigurePayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            let requestedWindowID: Int?
            switch debugSearchLaneWindowID(arguments, op: op) {
            case let .success(windowID):
                requestedWindowID = windowID
            case let .failure(result):
                return result
            }

            let maxQueueWaitMilliseconds: Int
            switch debugBoundedInt(arguments, "max_queue_wait_ms", defaultValue: 0, range: 100 ... 60000) {
            case let .value(parsed):
                maxQueueWaitMilliseconds = parsed
            case .defaulted, .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`max_queue_wait_ms` must be an integer between 100 and 60000.")
            }

            let retryAfterMilliseconds: Int
            switch debugBoundedInt(arguments, "retry_after_ms", defaultValue: 1000, range: 0 ... 60000) {
            case let .value(parsed), let .defaulted(parsed):
                retryAfterMilliseconds = parsed
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`retry_after_ms` must be an integer between 0 and 60000.")
            }

            let productionConfiguration = StoreBackedWorkspaceSearchLane.Configuration.production
            let maxActiveLeases: Int
            switch debugBoundedInt(
                arguments,
                "max_active_leases",
                defaultValue: productionConfiguration.maxActiveLeases,
                range: 1 ... 64
            ) {
            case let .value(parsed), let .defaulted(parsed):
                maxActiveLeases = parsed
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`max_active_leases` must be an integer between 1 and 64.")
            }

            let maxQueuedWaiters: Int
            switch debugBoundedInt(
                arguments,
                "max_queued_waiters",
                defaultValue: productionConfiguration.maxQueuedWaiters,
                range: 1 ... 64
            ) {
            case let .value(parsed), let .defaulted(parsed):
                maxQueuedWaiters = parsed
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`max_queued_waiters` must be an integer between 1 and 64.")
            }

            let targets = await debugSearchLaneTargets(windowID: requestedWindowID)
            guard !targets.isEmpty else {
                let message = requestedWindowID.map { "No RepoPrompt window matched window_id \($0)." }
                    ?? "No RepoPrompt windows are available for search-lane configuration."
                return debugDiagnosticsError(op: op, code: "no_window", message: message)
            }

            let before = await debugSearchLaneSnapshots(targets)
            guard before.allSatisfy(\.snapshot.isIdle) else {
                return debugDiagnosticsResult([
                    "ok": false,
                    "op": op,
                    "code": "admission_busy",
                    "error": "Search-lane configuration can only change while every targeted lane is idle.",
                    "admission": searchLaneAdmissionPayload(before)
                ], isError: true)
            }

            let configuration = StoreBackedWorkspaceSearchLane.Configuration(
                maxActiveLeases: maxActiveLeases,
                maxQueuedWaiters: maxQueuedWaiters,
                maxQueueWait: .milliseconds(maxQueueWaitMilliseconds),
                retryAfterMilliseconds: retryAfterMilliseconds
            )
            var didRaceBusy = false
            for target in targets {
                switch await target.store.configureSearchLaneForTesting(configuration) {
                case .applied:
                    break
                case .busy:
                    didRaceBusy = true
                }
            }
            let after = await debugSearchLaneSnapshots(targets)
            if didRaceBusy {
                return debugDiagnosticsResult([
                    "ok": false,
                    "op": op,
                    "code": "admission_busy",
                    "error": "A targeted search lane became busy while DEBUG configuration was being applied.",
                    "partial": true,
                    "admission": searchLaneAdmissionPayload(after)
                ], isError: true)
            }
            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "admission": searchLaneAdmissionPayload(after)
            ])
        }

        func debugMCPReadSearchContentReadSchedulerSnapshotPayload(op: String) async -> CallTool.Result {
            let snapshot = await FileSystemService.contentReadWorkerLimiterSnapshotForTesting()
            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "scheduler": snapshot.payload()
            ])
        }

        func debugMCPReadSearchRuntimeSnapshotPayload(
            op: String,
            connectionID: UUID,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            guard let requestedConnectionID = debugOptionalUUID(arguments, "connection_id", op: op) else {
                return debugDiagnosticsError(
                    op: op,
                    code: "invalid_params",
                    message: "`connection_id` must be a UUID string when provided."
                )
            }

            let requestedWindowID: Int?
            switch debugSearchLaneWindowID(arguments, op: op) {
            case let .success(windowID):
                requestedWindowID = windowID
            case let .failure(result):
                return result
            }

            let recentPublicationLimit: Int
            switch debugBoundedInt(arguments, "recent_publication_limit", defaultValue: 8, range: 0 ... 32) {
            case let .value(parsed), let .defaulted(parsed):
                recentPublicationLimit = parsed
            case .invalid:
                return debugDiagnosticsError(
                    op: op,
                    code: "invalid_params",
                    message: "`recent_publication_limit` must be an integer between 0 and 32."
                )
            }

            let rootLimit: Int
            switch debugBoundedInt(arguments, "root_limit", defaultValue: 64, range: 1 ... 256) {
            case let .value(parsed), let .defaulted(parsed):
                rootLimit = parsed
            case .invalid:
                return debugDiagnosticsError(
                    op: op,
                    code: "invalid_params",
                    message: "`root_limit` must be an integer between 1 and 256."
                )
            }

            let targets = await debugReadSearchRuntimeTargets(windowID: requestedWindowID)
            if let requestedWindowID, targets.isEmpty {
                return debugDiagnosticsError(
                    op: op,
                    code: "no_window",
                    message: "No RepoPrompt window matched window_id \(requestedWindowID)."
                )
            }

            var windows: [[String: Any]] = []
            windows.reserveCapacity(targets.count)
            for target in targets {
                let snapshots = await target.store.readSearchRootDiagnosticsSnapshot(
                    recentPublicationLimit: recentPublicationLimit
                )
                let ordered = snapshots.sorted { $0.rootToken.uuidString < $1.rootToken.uuidString }
                let included = Array(ordered.prefix(rootLimit))
                windows.append([
                    "window_id": target.windowID,
                    "root_count": ordered.count,
                    "omitted_root_count": max(0, ordered.count - included.count),
                    "handled_projection_event_count": target.projection.handledEventCount,
                    "projection_direct_file_id_lookup_count": target.projection.directFileIDLookupCount,
                    "projection_direct_folder_id_lookup_count": target.projection.directFolderIDLookupCount,
                    "projection_direct_id_lookup_miss_count": target.projection.directIDLookupMissCount,
                    "projection_canonical_resync_count": target.projection.canonicalResyncCount,
                    "read_file_auto_selection": readFileAutoSelectionPayload(target.readFileAutoSelection),
                    "roots": included.map { root in
                        readSearchRuntimeRootPayload(
                            root,
                            handledGeneration: target.projection.handledGenerationByRootID[root.rootID] ?? 0
                        )
                    }
                ])
            }

            let targetConnectionID = requestedConnectionID ?? connectionID
            let limiter = await connectionLimiterDiagnosticsSnapshot(connectionID: targetConnectionID)
            var limiterPayload = limiter.map { readSearchLimiterPayload($0) } ?? ["found": false]
            limiterPayload["connection_id"] = targetConnectionID.uuidString
            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "runtime": [
                    "consistency": "best_effort",
                    "limiter": limiterPayload,
                    "observers": [
                        "tool_call_observer_count": toolCallObserverCount(),
                        "tool_event_observer_count": toolEventObserverCount()
                    ],
                    "window_count": windows.count,
                    "windows": windows
                ]
            ])
        }

        private struct DebugReadSearchRuntimeTarget {
            let windowID: Int
            let store: WorkspaceFileContextStore
            let projection: WorkspaceFilesViewModel.AppliedIndexProjectionDiagnosticsSnapshot
            let readFileAutoSelection: MCPReadFileAutoSelectionCoordinator.DebugSnapshot
        }

        private enum DebugSearchLaneWindowIDResult {
            case success(Int?)
            case failure(CallTool.Result)
        }

        private func debugSearchLaneWindowID(
            _ arguments: [String: Value],
            op: String
        ) -> DebugSearchLaneWindowIDResult {
            guard arguments["window_id"] != nil else { return .success(nil) }
            switch debugBoundedInt(arguments, "window_id", defaultValue: 0, range: 1 ... Int.max) {
            case let .value(windowID):
                return .success(windowID)
            case .defaulted, .invalid:
                return .failure(debugDiagnosticsError(
                    op: op,
                    code: "invalid_params",
                    message: "`window_id` must be a positive integer."
                ))
            }
        }

        private func debugReadSearchRuntimeTargets(windowID: Int?) async -> [DebugReadSearchRuntimeTarget] {
            await MainActor.run {
                WindowStatesManager.shared.allWindows
                    .filter { windowID == nil || $0.windowID == windowID }
                    .sorted { $0.windowID < $1.windowID }
                    .map { window in
                        DebugReadSearchRuntimeTarget(
                            windowID: window.windowID,
                            store: window.workspaceFileContextStore,
                            projection: window.workspaceFilesViewModel.appliedIndexProjectionDiagnosticsSnapshot(),
                            readFileAutoSelection: window.mcpServer.readFileAutoSelectionDiagnosticsSnapshot()
                        )
                    }
            }
        }

        private func readFileAutoSelectionPayload(
            _ snapshot: MCPReadFileAutoSelectionCoordinator.DebugSnapshot
        ) -> [String: Any] {
            [
                "canonical_lane_count": snapshot.canonicalLaneCount,
                "canonical_worker_count": snapshot.canonicalWorkerCount,
                "mirror_lane_count": snapshot.mirrorLaneCount,
                "mirror_worker_count": snapshot.mirrorWorkerCount,
                "closing_context_count": snapshot.closingContextCount,
                "pending_canonical_batch_count": snapshot.pendingCanonicalBatchCount,
                "pending_mirror_batch_count": snapshot.pendingMirrorBatchCount
            ]
        }

        private func readSearchLimiterPayload(
            _ snapshot: MCPConnectionCallLimiterDebugSnapshot
        ) -> [String: Any] {
            [
                "found": true,
                "lane_count": snapshot.laneCount,
                "limit": snapshot.limit,
                "permits": snapshot.permits,
                "active_permit_count": snapshot.activePermitCount,
                "waiter_count": snapshot.waiterCount,
                "in_flight_count": snapshot.inFlight,
                "oldest_waiter_age_ms": Self.debugOptionalValue(snapshot.oldestWaiterAgeMilliseconds),
                "cancelled_waiter_count": snapshot.cancelledWaiterCount,
                "is_closed": snapshot.isClosed,
                "is_idle": snapshot.isIdle,
                "lanes": [
                    MCPConnectionCallLane.ordinary.rawValue: readSearchLimiterLanePayload(snapshot.ordinary),
                    MCPConnectionCallLane.fileSearch.rawValue: readSearchLimiterLanePayload(snapshot.fileSearch)
                ]
            ]
        }

        private func readSearchLimiterLanePayload(_ snapshot: AsyncLimiter.DebugSnapshot) -> [String: Any] {
            [
                "limit": snapshot.limit,
                "permits": snapshot.permits,
                "active_permit_count": snapshot.activePermitCount,
                "waiter_count": snapshot.waiterCount,
                "in_flight_count": snapshot.inFlight,
                "oldest_waiter_age_ms": Self.debugOptionalValue(snapshot.oldestWaiterAgeMilliseconds),
                "cancelled_waiter_count": snapshot.cancelledWaiterCount,
                "is_closed": snapshot.isClosed,
                "is_idle": snapshot.isIdle
            ]
        }

        private func readSearchRuntimeRootPayload(
            _ root: WorkspaceFileContextStore.ReadSearchRootDiagnosticsSnapshot,
            handledGeneration: UInt64
        ) -> [String: Any] {
            let producedGeneration = root.producedAppliedIndexGeneration
            let generationLag = producedGeneration >= handledGeneration
                ? producedGeneration - handledGeneration
                : 0
            return [
                "root_token": root.rootToken.uuidString,
                "ingress": readSearchIngressPayload(root.ingress),
                "barrier": readSearchBarrierPayload(root.barrier),
                "invalidation": readSearchInvalidationPayload(root.invalidation),
                "projection": [
                    "produced_generation": producedGeneration,
                    "handled_generation": handledGeneration,
                    "generation_lag": generationLag
                ]
            ]
        }

        private func readSearchIngressPayload(
            _ snapshot: WorkspaceFileSystemIngressCoordinator.DebugSnapshot
        ) -> [String: Any] {
            [
                "is_open": snapshot.isOpen,
                "queued_publication_count": snapshot.queuedPublicationCount,
                "applying_publication_count": snapshot.applyingPublicationCount,
                "outstanding_publication_count": snapshot.outstandingPublicationCount,
                "waiter_count": snapshot.waiterCount,
                "accepted_service_publication_sequence": snapshot.acceptedServicePublicationSequence,
                "applied_service_publication_sequence": snapshot.appliedServicePublicationSequence,
                "accepted_applied_sequence_gap": snapshot.acceptedAppliedSequenceGap,
                "applied_watcher_watermark": snapshot.appliedWatcherWatermark,
                "oldest_outstanding_publication_age_ms": Self.debugOptionalValue(
                    snapshot.oldestOutstandingPublicationAgeMilliseconds
                )
            ]
        }

        private func readSearchBarrierPayload(
            _ snapshot: WorkspaceFileContextStore.ScopedIngressBarrierDebugSnapshot
        ) -> [String: Any] {
            let active = snapshot.active.map { active in
                [
                    "target_watcher_watermark": active.targetWatcherWatermark,
                    "target_service_publication_sequence": active.targetServicePublicationSequence,
                    "age_ms": active.ageMilliseconds
                ]
            }
            let pending = snapshot.pending.map { pending in
                [
                    "target_watcher_watermark": pending.targetWatcherWatermark,
                    "target_service_publication_sequence": pending.targetServicePublicationSequence,
                    "age_ms": pending.ageMilliseconds
                ]
            }
            let completed = snapshot.lastCompleted.map { completed in
                [
                    "token": completed.token,
                    "target_watcher_watermark": completed.targetWatcherWatermark,
                    "target_service_publication_sequence": completed.targetServicePublicationSequence,
                    "published_service_publication_sequence": completed.publishedServicePublicationSequence,
                    "applied_service_publication_sequence": completed.appliedServicePublicationSequence,
                    "applied_watcher_watermark": completed.appliedWatcherWatermark,
                    "duration_ms": completed.durationMilliseconds
                ]
            }
            return [
                "launch_count": snapshot.launchCount,
                "join_count": snapshot.joinCount,
                "successor_count": snapshot.successorCount,
                "coalesced_successor_count": snapshot.coalescedSuccessorCount,
                "completion_count": snapshot.completionCount,
                "active": Self.debugOptionalValue(active),
                "pending": Self.debugOptionalValue(pending),
                "last_completed": Self.debugOptionalValue(completed)
            ]
        }

        private func readSearchInvalidationPayload(
            _ snapshot: WorkspaceFileContextStore.PublicationInvalidationHistoryDebugSnapshot
        ) -> [String: Any] {
            [
                "retained_sample_limit": snapshot.retainedSampleLimit,
                "total_observed_publication_count": snapshot.totalObservedPublicationCount,
                "dropped_publication_sample_count": snapshot.droppedPublicationSampleCount,
                "returned_sample_count": snapshot.samples.count,
                "recent_publications": snapshot.samples.map(readSearchInvalidationSamplePayload)
            ]
        }

        private func readSearchInvalidationSamplePayload(
            _ sample: WorkspaceFileContextStore.PublicationInvalidationDebugSample
        ) -> [String: Any] {
            [
                "service_publication_sequence": Self.debugOptionalValue(sample.servicePublicationSequence),
                "watcher_accepted_watermark": Self.debugOptionalValue(sample.watcherAcceptedWatermark),
                "prepared_delta_count": sample.preparedDeltaCount,
                "topology_invalidation_count": sample.topologyInvalidationCount,
                "catalog_generation_advance_count": sample.catalogGenerationAdvanceCount,
                "search_catalog_cache_clear_count": sample.searchCatalogCacheClearCount,
                "path_worker_invalidation_request_count": sample.pathWorkerInvalidationRequestCount,
                "content_invalidation_count": sample.contentInvalidationCount,
                "distinct_content_key_count": sample.distinctContentKeyCount,
                "decoded_cache_invalidation_request_count": sample.decodedCacheInvalidationRequestCount,
                "codemap_invalidation_request_count": sample.codemapInvalidationRequestCount,
                "applied_index_event_yield_count": sample.appliedIndexEventYieldCount
            ]
        }

        private func debugSearchLaneTargets(
            windowID: Int?
        ) async -> [(windowID: Int, store: WorkspaceFileContextStore)] {
            await MainActor.run {
                WindowStatesManager.shared.allWindows
                    .filter { windowID == nil || $0.windowID == windowID }
                    .sorted { $0.windowID < $1.windowID }
                    .map { ($0.windowID, $0.workspaceFileContextStore) }
            }
        }

        private func debugSearchLaneSnapshots(
            _ targets: [(windowID: Int, store: WorkspaceFileContextStore)]
        ) async -> [(windowID: Int, snapshot: StoreBackedWorkspaceSearchLane.Snapshot)] {
            var entries: [(windowID: Int, snapshot: StoreBackedWorkspaceSearchLane.Snapshot)] = []
            entries.reserveCapacity(targets.count)
            for target in targets {
                await entries.append((target.windowID, target.store.searchLaneSnapshotForTesting()))
            }
            return entries
        }

        private func searchLaneAdmissionPayload(
            _ entries: [(windowID: Int, snapshot: StoreBackedWorkspaceSearchLane.Snapshot)]
        ) -> [String: Any] {
            [
                "idle": entries.allSatisfy(\.snapshot.isIdle),
                "window_count": entries.count,
                "active_count": entries.reduce(0) { $0 + $1.snapshot.activePermitCount },
                "queued_count": entries.reduce(0) { $0 + $1.snapshot.waiterCount },
                "grant_count": entries.reduce(0) { $0 + $1.snapshot.grantCount },
                "overload_count": entries.reduce(0) { $0 + $1.snapshot.overloadCount },
                "wait_expiry_count": entries.reduce(0) { $0 + $1.snapshot.waitExpiryCount },
                "queued_cancellation_count": entries.reduce(0) { $0 + $1.snapshot.queuedCancellationCount },
                "lanes": entries.map { entry in
                    [
                        "window_id": entry.windowID,
                        "configuration": [
                            "active_capacity": entry.snapshot.configuration.maxActiveLeases,
                            "max_queued": entry.snapshot.configuration.maxQueuedWaiters,
                            "max_queue_wait_ms": entry.snapshot.configuration.maxQueueWaitMilliseconds,
                            "retry_after_ms": entry.snapshot.configuration.retryAfterMilliseconds
                        ],
                        "idle": entry.snapshot.isIdle,
                        "active_count": entry.snapshot.activePermitCount,
                        "queued_count": entry.snapshot.waiterCount,
                        "grant_count": entry.snapshot.grantCount,
                        "overload_count": entry.snapshot.overloadCount,
                        "wait_expiry_count": entry.snapshot.waitExpiryCount,
                        "queued_cancellation_count": entry.snapshot.queuedCancellationCount,
                        "maximum_active_count": entry.snapshot.maximumActivePermitCount,
                        "maximum_queued_count": entry.snapshot.maximumWaiterCount
                    ]
                }
            ]
        }

        private func debugMCPReadSearchCaptureLabel(_ raw: String) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            let replacement = UnicodeScalar("_")
            let scalars = trimmed.unicodeScalars.map { scalar in
                allowed.contains(scalar) ? scalar : replacement
            }
            return String(String.UnicodeScalarView(scalars.prefix(64)))
        }
    }

    private extension ContentReadAsyncLimiter.Snapshot {
        func payload() -> [String: Any] {
            [
                "capacity": capacity,
                "max_queued_waiters": maxQueuedWaiterCount,
                "idle": isIdle,
                "active_permit_count": activePermitCount,
                "queued_waiter_count": queuedWaiterCount,
                "owner_lane_count": ownerLaneCount,
                "cancellation_count": cancellationCount,
                "grant_count": grantCount,
                "overload_count": overloadCount,
                "interactive_grant_count": interactiveGrantCount,
                "normal_grant_count": normalGrantCount,
                "bulk_grant_count": bulkGrantCount
            ]
        }
    }
#endif
