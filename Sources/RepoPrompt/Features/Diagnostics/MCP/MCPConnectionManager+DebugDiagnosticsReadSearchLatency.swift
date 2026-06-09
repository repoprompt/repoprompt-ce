// MARK: - DEBUG MCP Read/Search Latency Diagnostics

import Foundation
import MCP
import RepoPromptCore

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
                            "active_capacity": 1,
                            "max_queued": 1,
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
