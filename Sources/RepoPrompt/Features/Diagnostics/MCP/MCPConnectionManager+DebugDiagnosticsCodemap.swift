import Foundation
import MCP

#if DEBUG
    extension ServerNetworkManager {
        private struct CodemapFullLoadHarnessPayload {
            let object: [String: Any]
            let isTerminal: Bool
        }

        @MainActor
        func debugCodemapFullLoadPayload(
            op: String,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            let action = debugString(arguments, "action")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? "snapshot"
            let windowID: Int
            switch debugBoundedInt(arguments, "window_id", defaultValue: 0, range: 0 ... Int.max) {
            case let .value(value), let .defaulted(value):
                windowID = value
            case .invalid:
                return debugDiagnosticsError(
                    op: op,
                    code: "invalid_params",
                    message: "`window_id` must be a non-negative integer."
                )
            }
            guard let window = Self.debugCodemapFullLoadWindow(windowID: windowID) else {
                return debugDiagnosticsError(
                    op: op,
                    code: "no_window",
                    message: "No matching RepoPrompt window is available."
                )
            }

            switch action {
            case "arm":
                guard let target = debugString(arguments, "target_workspace")?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !target.isEmpty
                else {
                    return debugDiagnosticsError(
                        op: op,
                        code: "invalid_params",
                        message: "Missing required string argument `target_workspace`."
                    )
                }
                let pollInterval: Int
                switch debugBoundedInt(arguments, "poll_interval_ms", defaultValue: 100, range: 50 ... 1000) {
                case let .value(value), let .defaulted(value):
                    pollInterval = value
                case .invalid:
                    return debugDiagnosticsError(
                        op: op,
                        code: "invalid_params",
                        message: "`poll_interval_ms` must be between 50 and 1000."
                    )
                }
                let timeout: Int
                switch debugBoundedInt(arguments, "timeout_ms", defaultValue: 300_000, range: 1000 ... 1_800_000) {
                case let .value(value), let .defaulted(value):
                    timeout = value
                case .invalid:
                    return debugDiagnosticsError(
                        op: op,
                        code: "invalid_params",
                        message: "`timeout_ms` must be between 1000 and 1800000."
                    )
                }
                switch window.workspaceManager.debugArmCodemapFullLoad(
                    targetWorkspaceName: target,
                    pollIntervalMilliseconds: pollInterval,
                    timeoutMilliseconds: timeout
                ) {
                case let .success(correlation):
                    return debugDiagnosticsResult([
                        "ok": true,
                        "op": op,
                        "action": action,
                        "window_id": window.windowID,
                        "arm_id": correlation.armID.uuidString,
                        "target_workspace_id": correlation.targetWorkspaceID.uuidString,
                        "target_workspace_name": correlation.targetWorkspaceName,
                        "poll_interval_ms": correlation.pollIntervalMilliseconds,
                        "timeout_ms": correlation.timeoutMilliseconds,
                        "state": "armed"
                    ])
                case let .failure(error):
                    let detail = switch error {
                    case .targetNotFound:
                        ("target_not_found", "No saved workspace has the requested name.")
                    case .targetAmbiguous:
                        ("target_ambiguous", "More than one saved workspace has the requested name.")
                    case .targetAlreadyActive:
                        ("same_workspace_noop", "The target workspace is already active; no-op measurements are rejected.")
                    }
                    return debugDiagnosticsError(op: op, code: detail.0, message: detail.1)
                }

            case "clear":
                let armID = debugString(arguments, "arm_id").flatMap(UUID.init(uuidString:))
                let cleared = window.workspaceManager.debugClearCodemapFullLoad(armID: armID)
                return debugDiagnosticsResult([
                    "ok": true,
                    "op": op,
                    "action": action,
                    "window_id": window.windowID,
                    "cleared": cleared
                ])

            case "snapshot", "wait":
                guard let armIDString = debugString(arguments, "arm_id"),
                      let armID = UUID(uuidString: armIDString)
                else {
                    return debugDiagnosticsError(
                        op: op,
                        code: "invalid_params",
                        message: "A valid `arm_id` UUID is required."
                    )
                }
                if action == "snapshot" {
                    let snapshot = await Self.debugCodemapFullLoadHarnessSnapshot(
                        op: op,
                        action: action,
                        window: window,
                        armID: armID
                    )
                    return debugDiagnosticsResult(snapshot.object, isError: snapshot.object["ok"] as? Bool == false)
                }

                while true {
                    let snapshot = await Self.debugCodemapFullLoadHarnessSnapshot(
                        op: op,
                        action: action,
                        window: window,
                        armID: armID
                    )
                    if snapshot.isTerminal {
                        return debugDiagnosticsResult(
                            snapshot.object,
                            isError: snapshot.object["ok"] as? Bool == false
                        )
                    }
                    guard let correlation = window.workspaceManager
                        .debugCodemapFullLoadCorrelationSnapshot(armID: armID)
                    else {
                        return debugDiagnosticsError(
                            op: op,
                            code: "arm_not_found",
                            message: "The requested codemap full-load arm is no longer active."
                        )
                    }
                    try? await Task.sleep(
                        nanoseconds: UInt64(correlation.pollIntervalMilliseconds) * 1_000_000
                    )
                    if Task.isCancelled {
                        return debugDiagnosticsError(
                            op: op,
                            code: "cancelled",
                            message: "Codemap full-load wait was cancelled."
                        )
                    }
                }

            default:
                return debugDiagnosticsError(
                    op: op,
                    code: "invalid_params",
                    message: "Unknown `codemap_full_load` action. Use `arm`, `clear`, `snapshot`, or `wait`."
                )
            }
        }

        @MainActor
        private static func debugCodemapFullLoadWindow(windowID: Int) -> WindowState? {
            let manager = WindowStatesManager.shared
            if windowID > 0 {
                return manager.allWindows.first { $0.windowID == windowID }
            }
            return manager.allWindows.first { $0.isCurrentlyFocused } ?? manager.latestWindowState
        }

        @MainActor
        private static func debugCodemapFullLoadHarnessSnapshot(
            op: String,
            action: String,
            window: WindowState,
            armID: UUID
        ) async -> CodemapFullLoadHarnessPayload {
            guard let correlation = window.workspaceManager
                .debugCodemapFullLoadCorrelationSnapshot(armID: armID)
            else {
                return CodemapFullLoadHarnessPayload(
                    object: [
                        "ok": false,
                        "op": op,
                        "action": action,
                        "window_id": window.windowID,
                        "arm_id": armID.uuidString,
                        "state": "invalid",
                        "invalid_reason": "arm_not_found"
                    ],
                    isTerminal: true
                )
            }

            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = now >= correlation.armedUptimeNanoseconds
                ? now - correlation.armedUptimeNanoseconds
                : 0
            let timeoutNanoseconds = UInt64(correlation.timeoutMilliseconds) * 1_000_000
            if elapsed >= timeoutNanoseconds, correlation.invalidReason == nil {
                window.workspaceManager.debugInvalidateCodemapFullLoad(
                    armID: armID,
                    reason: "timeout"
                )
            }
            guard let current = window.workspaceManager
                .debugCodemapFullLoadCorrelationSnapshot(armID: armID)
            else {
                return CodemapFullLoadHarnessPayload(
                    object: [
                        "ok": false,
                        "op": op,
                        "action": action,
                        "window_id": window.windowID,
                        "arm_id": armID.uuidString,
                        "state": "invalid",
                        "invalid_reason": "arm_not_found"
                    ],
                    isTerminal: true
                )
            }

            var base: [String: Any] = [
                "ok": current.invalidReason == nil,
                "op": op,
                "action": action,
                "window_id": window.windowID,
                "arm_id": current.armID.uuidString,
                "target_workspace_id": current.targetWorkspaceID.uuidString,
                "target_workspace_name": current.targetWorkspaceName,
                "operation_id": current.operationID?.uuidString ?? NSNull(),
                "accepted_uptime_ns": current.acceptedUptimeNanoseconds ?? NSNull(),
                "armed_uptime_ns": current.armedUptimeNanoseconds,
                "poll_interval_ms": current.pollIntervalMilliseconds,
                "timeout_ms": current.timeoutMilliseconds,
                "switch_result": current.switchResult.rawValue,
                "active_workspace_id": window.workspaceManager.activeWorkspace?.id.uuidString ?? NSNull(),
                "active_workspace_name": window.workspaceManager.activeWorkspace?.name ?? NSNull()
            ]

            if let invalidReason = current.invalidReason {
                base["state"] = "invalid"
                base["invalid_reason"] = invalidReason
                if invalidReason == "timeout",
                   current.switchResult == .switched,
                   window.workspaceManager.activeWorkspace?.id == current.targetWorkspaceID
                {
                    let aggregate = await window.workspaceFileContextStore
                        .debugCodemapFullLoadAggregateSnapshot(expectedWorkspaceID: current.targetWorkspaceID)
                    base["aggregate"] = debugCodemapFullLoadAggregatePayload(aggregate)
                    base["cohort"] = aggregate.cohort
                    base["workspace_switch_trace"] = window.workspaceManager.debugWorkspaceOpenTraceSnapshot()
                }
                return CodemapFullLoadHarnessPayload(object: base, isTerminal: true)
            }
            guard current.operationID != nil, current.acceptedUptimeNanoseconds != nil else {
                base["state"] = "armed"
                return CodemapFullLoadHarnessPayload(object: base, isTerminal: false)
            }
            guard current.switchResult == .switched else {
                base["state"] = "switching"
                return CodemapFullLoadHarnessPayload(object: base, isTerminal: false)
            }
            guard window.workspaceManager.activeWorkspace?.id == current.targetWorkspaceID else {
                window.workspaceManager.debugInvalidateCodemapFullLoad(
                    armID: armID,
                    reason: "wrong_active_workspace_after_switch"
                )
                base["ok"] = false
                base["state"] = "invalid"
                base["invalid_reason"] = "wrong_active_workspace_after_switch"
                return CodemapFullLoadHarnessPayload(object: base, isTerminal: true)
            }

            let aggregate = await window.workspaceFileContextStore
                .debugCodemapFullLoadAggregateSnapshot(expectedWorkspaceID: current.targetWorkspaceID)
            let aggregatePayload = debugCodemapFullLoadAggregatePayload(aggregate)
            base["aggregate"] = aggregatePayload
            base["cohort"] = aggregate.cohort
            base["workspace_switch_trace"] = window.workspaceManager.debugWorkspaceOpenTraceSnapshot()

            if let accepted = current.acceptedUptimeNanoseconds,
               aggregate.sampledUptimeNanoseconds >= accepted
            {
                base["accepted_to_authoritative_ready_ms"] =
                    Double(aggregate.sampledUptimeNanoseconds - accepted) / 1_000_000
                let lastProof = aggregate.roots.compactMap(\.coverageCompletedUptimeNanoseconds).max()
                base["accepted_to_last_eligible_proof_ms"] = lastProof.map {
                    Double($0 >= accepted ? $0 - accepted : 0) / 1_000_000
                } ?? NSNull()
            }

            switch aggregate.state {
            case .ready:
                base["state"] = "ready"
                return CodemapFullLoadHarnessPayload(object: base, isTerminal: true)
            case .pending:
                base["state"] = "pending"
                return CodemapFullLoadHarnessPayload(object: base, isTerminal: false)
            case .failed, .superseded, .incompleteDiagnostics:
                let reason = aggregate.state.rawValue
                window.workspaceManager.debugInvalidateCodemapFullLoad(armID: armID, reason: reason)
                base["ok"] = false
                base["state"] = "invalid"
                base["invalid_reason"] = reason
                return CodemapFullLoadHarnessPayload(object: base, isTerminal: true)
            }
        }

        private static func debugCodemapFullLoadAggregatePayload(
            _ aggregate: CodemapFullLoadAggregateSnapshot
        ) -> [String: Any] {
            [
                "state": aggregate.state.rawValue,
                "sampled_uptime_ns": aggregate.sampledUptimeNanoseconds,
                "visible_root_count": aggregate.visibleRootCount,
                "eligible_root_count": aggregate.eligibleRootCount,
                "proof_complete_root_count": aggregate.proofCompleteRootCount,
                "terminal_ineligible_root_count": aggregate.terminalIneligibleRootCount,
                "excluded_root_count": aggregate.excludedRootCount,
                "pending_root_count": aggregate.pendingRootCount,
                "failed_root_count": aggregate.failedRootCount,
                "superseded_root_count": aggregate.supersededRootCount,
                "cohort": aggregate.cohort,
                "metrics": aggregate.metrics,
                "resources": aggregate.resources,
                "queue_wait_ms": aggregate.queueWaitMilliseconds,
                "roots": aggregate.roots.map(CodemapFullLoadDebugSupport.privacySafeRootPayload)
            ]
        }
    }
#endif
