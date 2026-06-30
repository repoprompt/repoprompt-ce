// MARK: - Hidden DEBUG Diagnostics Surface

import Foundation
import MCP

#if DEBUG
    extension ServerNetworkManager {
        static let debugDiagnosticsToolName = "__repoprompt_debug_diagnostics"
        static let legacyDebugTransportToolName = "__repoprompt_debug_transport"
        static let debugDiagnosticsToolNames: Set<String> = [
            debugDiagnosticsToolName,
            legacyDebugTransportToolName
        ]

        nonisolated static func isDebugDiagnosticsToolName(_ toolName: String) -> Bool {
            debugDiagnosticsToolNames.contains(toolName)
        }

        func handleDebugDiagnosticsTool(
            connectionID: UUID,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            guard let op = debugString(arguments, "op"), !op.isEmpty else {
                return debugDiagnosticsError(op: nil, code: "invalid_params", message: "Missing required string argument `op`.")
            }

            switch op {
            case "ping":
                return await debugDiagnosticsResult(debugPingPayload(connectionID: connectionID, op: op, arguments: arguments))
            case "connection_snapshot":
                return await debugConnectionSnapshotToolPayload(op: op, connectionID: connectionID, arguments: arguments)
            case "transport_snapshot":
                return await debugTransportIngressSnapshotToolPayload(op: op, connectionID: connectionID, arguments: arguments)
            case "routing_snapshot":
                return await debugRoutingSnapshotToolPayload(op: op, connectionID: connectionID, arguments: arguments)
            case "connection_history":
                return debugConnectionHistoryToolPayload(op: op, arguments: arguments)
            case "run_routing_history":
                return debugRunRoutingHistoryToolPayload(op: op, arguments: arguments)
            case "clear_connection_history":
                return debugClearConnectionHistoryToolPayload(op: op, arguments: arguments)
            case "wait_for_reconnect":
                return await debugWaitForReconnectToolPayload(op: op, connectionID: connectionID, arguments: arguments)
            case "clear_routing_state":
                return debugClearRoutingStateToolPayload(op: op, connectionID: connectionID, arguments: arguments)
            case "clear_persisted_routing_session":
                return debugClearPersistedRoutingSessionToolPayload(op: op, arguments: arguments)
            case "seed_routing_affinity":
                return await debugSeedRoutingAffinityToolPayload(op: op, connectionID: connectionID, arguments: arguments)
            case "shutdown_and_restart":
                return debugShutdownAndRestartToolPayload(op: op, arguments: arguments)
            case "restart_status":
                return debugRestartStatusToolPayload(op: op, arguments: arguments)
            case "connections":
                return await debugConnectionsPayload(op: op, arguments: arguments)
            case "sleep":
                return await debugSleepPayload(op: op, arguments: arguments)
            case "large_response":
                return debugLargeResponsePayload(op: op, arguments: arguments)
            case "sleep_then_large_response":
                return await debugSleepThenLargeResponsePayload(op: op, arguments: arguments)
            case "force_remove_connection":
                return await debugForceRemoveConnectionPayload(op: op, connectionID: connectionID, arguments: arguments)
            case "seed_active_tool_probe":
                return await debugSeedActiveToolProbePayload(op: op, arguments: arguments)
            case "active_tool_probe_status":
                return await debugActiveToolProbeStatusPayload(op: op, arguments: arguments)
            case "clear_active_tool_probe":
                return await debugClearActiveToolProbePayload(op: op, arguments: arguments)
            case "restore_perf_metrics":
                #if DEBUG
                    return debugRestorePerfMetricsPayload(op: op, arguments: arguments)
                #else
                    return debugDiagnosticsError(op: op, code: "unavailable", message: "`restore_perf_metrics` is only available in DEBUG builds.")
                #endif
            case "workspace_selection_fixture":
                #if DEBUG
                    return await debugWorkspaceSelectionFixturePayload(op: op, arguments: arguments)
                #else
                    return debugDiagnosticsError(op: op, code: "unavailable", message: "`workspace_selection_fixture` is only available in DEBUG builds.")
                #endif
            case "large_workspace_memory":
                #if DEBUG
                    return await debugLargeWorkspaceMemoryPayload(op: op, arguments: arguments)
                #else
                    return debugDiagnosticsError(op: op, code: "unavailable", message: "`large_workspace_memory` is only available in DEBUG builds.")
                #endif
            #if DEBUG
                case "worktree_startup_benchmark":
                    return await debugWorktreeStartupBenchmarkPayload(
                        op: op,
                        connectionID: connectionID,
                        arguments: arguments
                    )
            #endif
            case "agent_perf_metrics":
                #if DEBUG
                    return await debugAgentPerfMetricsPayload(op: op, arguments: arguments)
                #else
                    return debugDiagnosticsError(op: op, code: "unavailable", message: "`agent_perf_metrics` is only available in DEBUG builds.")
                #endif
            case "seed_agent_text_derivation_fixture":
                #if DEBUG
                    return await debugSeedAgentTextDerivationFixturePayload(op: op, arguments: arguments)
                #else
                    return debugDiagnosticsError(op: op, code: "unavailable", message: "`seed_agent_text_derivation_fixture` is only available in DEBUG builds.")
                #endif
            case "font_scale_metrics":
                #if DEBUG
                    return await debugFontScaleMetricsPayload(op: op, arguments: arguments)
                #else
                    return debugDiagnosticsError(op: op, code: "unavailable", message: "`font_scale_metrics` is only available in DEBUG builds.")
                #endif
            case "chat_preview_context_latency":
                #if DEBUG
                    return await debugChatPreviewContextLatencyPayload(op: op, arguments: arguments)
                #else
                    return debugDiagnosticsError(op: op, code: "unavailable", message: "`chat_preview_context_latency` is only available in DEBUG builds.")
                #endif
            case "workspace_loading_snapshot":
                #if DEBUG
                    return await debugWorkspaceLoadingSnapshotPayload(op: op, arguments: arguments)
                #else
                    return debugDiagnosticsError(op: op, code: "unavailable", message: "`workspace_loading_snapshot` is only available in DEBUG builds.")
                #endif
            case "mcp_read_search_capture_begin":
                #if DEBUG
                    return debugMCPReadSearchCaptureBeginPayload(op: op, arguments: arguments)
                #else
                    return debugDiagnosticsError(op: op, code: "unavailable", message: "`mcp_read_search_capture_begin` is only available in DEBUG builds.")
                #endif
            case "mcp_read_search_capture_snapshot":
                #if DEBUG
                    return debugMCPReadSearchCaptureSnapshotPayload(op: op, arguments: arguments)
                #else
                    return debugDiagnosticsError(op: op, code: "unavailable", message: "`mcp_read_search_capture_snapshot` is only available in DEBUG builds.")
                #endif
            case "mcp_tool_duration_inventory":
                return debugMCPToolDurationInventoryPayload(op: op)
            case "mcp_read_search_admission_snapshot":
                #if DEBUG
                    return await debugMCPReadSearchAdmissionSnapshotPayload(op: op, arguments: arguments)
                #else
                    return debugDiagnosticsError(op: op, code: "unavailable", message: "`mcp_read_search_admission_snapshot` is only available in DEBUG builds.")
                #endif
            case "mcp_read_search_admission_configure":
                #if DEBUG
                    return await debugMCPReadSearchAdmissionConfigurePayload(op: op, arguments: arguments)
                #else
                    return debugDiagnosticsError(op: op, code: "unavailable", message: "`mcp_read_search_admission_configure` is only available in DEBUG builds.")
                #endif
            case "mcp_read_search_content_read_scheduler_snapshot":
                #if DEBUG
                    return await debugMCPReadSearchContentReadSchedulerSnapshotPayload(op: op)
                #else
                    return debugDiagnosticsError(op: op, code: "unavailable", message: "`mcp_read_search_content_read_scheduler_snapshot` is only available in DEBUG builds.")
                #endif
            case "mcp_read_search_runtime_snapshot":
                #if DEBUG
                    return await debugMCPReadSearchRuntimeSnapshotPayload(
                        op: op,
                        connectionID: connectionID,
                        arguments: arguments
                    )
                #else
                    return debugDiagnosticsError(op: op, code: "unavailable", message: "`mcp_read_search_runtime_snapshot` is only available in DEBUG builds.")
                #endif
            case "mcp_read_file_auto_selection_probe_begin":
                #if DEBUG
                    return await debugMCPReadFileAutoSelectionProbeBeginPayload(op: op, arguments: arguments)
                #else
                    return debugDiagnosticsError(op: op, code: "unavailable", message: "`mcp_read_file_auto_selection_probe_begin` is only available in DEBUG builds.")
                #endif
            case "mcp_read_file_auto_selection_probe_drain":
                #if DEBUG
                    return await debugMCPReadFileAutoSelectionProbeDrainPayload(op: op, arguments: arguments)
                #else
                    return debugDiagnosticsError(op: op, code: "unavailable", message: "`mcp_read_file_auto_selection_probe_drain` is only available in DEBUG builds.")
                #endif
            case "mcp_read_file_auto_selection_probe_cancel":
                #if DEBUG
                    return await debugMCPReadFileAutoSelectionProbeCancelPayload(op: op, arguments: arguments)
                #else
                    return debugDiagnosticsError(op: op, code: "unavailable", message: "`mcp_read_file_auto_selection_probe_cancel` is only available in DEBUG builds.")
                #endif
            case "mcp_apply_edits_rebase_probe_begin":
                #if DEBUG
                    return await debugMCPApplyEditsRebaseProbeBeginPayload(op: op, arguments: arguments)
                #else
                    return debugDiagnosticsError(op: op, code: "unavailable", message: "`mcp_apply_edits_rebase_probe_begin` is only available in DEBUG builds.")
                #endif
            case "mcp_apply_edits_rebase_probe_drain":
                #if DEBUG
                    return await debugMCPApplyEditsRebaseProbeDrainPayload(op: op, arguments: arguments)
                #else
                    return debugDiagnosticsError(op: op, code: "unavailable", message: "`mcp_apply_edits_rebase_probe_drain` is only available in DEBUG builds.")
                #endif
            case "mcp_apply_edits_rebase_probe_cancel":
                #if DEBUG
                    return await debugMCPApplyEditsRebaseProbeCancelPayload(op: op, arguments: arguments)
                #else
                    return debugDiagnosticsError(op: op, code: "unavailable", message: "`mcp_apply_edits_rebase_probe_cancel` is only available in DEBUG builds.")
                #endif
            case "bootstrap_diagnostics":
                return await debugBootstrapDiagnosticsPayload(op: op)
            case "sparkle_status":
                return await debugSparkleStatusPayload(op: op)
            case "sparkle_appcast_request":
                return debugSparkleAppcastRequestPayload(op: op, arguments: arguments)
            case "sparkle_fetch_appcast":
                return await debugSparkleFetchAppcastPayload(op: op, arguments: arguments)
            case "sparkle_passive_check_dry_run":
                return await debugSparklePassiveCheckDryRunPayload(op: op, arguments: arguments)
            case "sparkle_trigger_passive_check":
                return await debugSparkleTriggerPassiveCheckPayload(op: op, arguments: arguments)
            default:
                return debugDiagnosticsError(op: op, code: "unknown_op", message: "Unknown debug diagnostics op: \(op)")
            }
        }

        nonisolated func debugDiagnosticsResult(_ object: [String: Any], isError: Bool = false) -> CallTool.Result {
            CallTool.Result(
                content: [MCP.Tool.Content.text(text: Self.debugJSONString(object), annotations: nil, _meta: nil)],
                isError: isError
            )
        }

        nonisolated func debugDiagnosticsError(op: String?, code: String, message: String) -> CallTool.Result {
            var payload: [String: Any] = [
                "ok": false,
                "code": code,
                "error": message
            ]
            payload["op"] = op ?? NSNull()
            return debugDiagnosticsResult(payload, isError: true)
        }

        nonisolated func debugString(_ arguments: [String: Value], _ key: String) -> String? {
            arguments[key]?.stringValue
        }

        nonisolated func debugBool(_ arguments: [String: Value], _ key: String) -> Bool? {
            guard let value = arguments[key] else { return nil }
            switch value {
            case let .bool(bool):
                return bool
            case let .int(int):
                return int != 0
            case let .string(string):
                switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "1", "yes": return true
                case "false", "0", "no": return false
                default: return nil
                }
            default:
                return nil
            }
        }

        nonisolated func debugDouble(_ arguments: [String: Value], _ key: String) -> Double? {
            guard let value = arguments[key] else { return nil }
            switch value {
            case let .double(double):
                return double
            case let .int(int):
                return Double(int)
            case let .string(string):
                return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
            default:
                return nil
            }
        }

        enum DebugIntParseResult {
            case value(Int)
            case defaulted(Int)
            case invalid
        }

        enum DebugDiagnosticsPayloadResult {
            case payload([String: Any])
            case error(code: String, message: String)
        }

        nonisolated func debugBoundedInt(
            _ arguments: [String: Value],
            _ key: String,
            defaultValue: Int,
            range: ClosedRange<Int>
        ) -> DebugIntParseResult {
            guard let rawValue = arguments[key] else {
                return range.contains(defaultValue) ? .defaulted(defaultValue) : .invalid
            }

            let parsed: Int
            switch rawValue {
            case let .int(int):
                parsed = int
            case let .double(double):
                guard double.isFinite,
                      double.rounded(.towardZero) == double,
                      double >= Double(Int.min),
                      double <= Double(Int.max)
                else {
                    return .invalid
                }
                parsed = Int(double)
            case let .string(string):
                guard let int = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    return .invalid
                }
                parsed = int
            default:
                return .invalid
            }

            guard range.contains(parsed) else { return .invalid }
            return .value(parsed)
        }

        func debugStringArray(_ arguments: [String: Value], _ key: String, op _: String) -> [String]?? {
            guard let value = arguments[key] else { return .some(nil) }
            if let string = value.stringValue {
                return .some([string])
            }
            guard let array = value.arrayValue else { return nil }
            var strings: [String] = []
            strings.reserveCapacity(array.count)
            for item in array {
                guard let string = item.stringValue else { return nil }
                strings.append(string)
            }
            return .some(strings)
        }

        func debugOptionalUUID(_ arguments: [String: Value], _ key: String, op _: String) -> UUID?? {
            guard let raw = debugString(arguments, key) else { return .some(nil) }
            guard let uuid = UUID(uuidString: raw) else { return nil }
            return .some(uuid)
        }

        func debugUUIDSet(_ arguments: [String: Value], _ key: String, op: String) -> Set<UUID>? {
            guard let stringsOptional = debugStringArray(arguments, key, op: op) else { return nil }
            guard let strings = stringsOptional else { return [] }
            var result = Set<UUID>()
            for string in strings {
                guard let uuid = UUID(uuidString: string) else { return nil }
                result.insert(uuid)
            }
            return result
        }

        static func debugOptionalValue(_ value: (some Any)?) -> Any {
            if let value { return value }
            return NSNull()
        }

        static func debugMedian(_ sortedValues: [Double]) -> Double {
            guard !sortedValues.isEmpty else { return 0 }
            let midpoint = sortedValues.count / 2
            if sortedValues.count.isMultiple(of: 2) {
                return debugRoundedMS((sortedValues[midpoint - 1] + sortedValues[midpoint]) / 2.0)
            }
            return debugRoundedMS(sortedValues[midpoint])
        }

        static func debugNearestRankPercentile(_ sortedValues: [Double], percentile: Double) -> Double {
            guard !sortedValues.isEmpty else { return 0 }
            let rank = Int(ceil(percentile * Double(sortedValues.count))) - 1
            let clamped = min(max(rank, 0), sortedValues.count - 1)
            return debugRoundedMS(sortedValues[clamped])
        }

        static func debugRoundedMS(_ value: Double) -> Double {
            (value * 10.0).rounded() / 10.0
        }

        private nonisolated static func debugJSONString(_ object: [String: Any]) -> String {
            do {
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                return String(data: data, encoding: .utf8) ?? "{\"ok\":false,\"error\":\"Unable to encode debug response.\"}"
            } catch {
                let escaped = String(describing: error).replacingOccurrences(of: "\"", with: "\\\"")
                return "{\"ok\":false,\"error\":\"Unable to encode debug response: \(escaped)\"}"
            }
        }

        func debugLargeWorkspaceMemoryPayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            #if DEBUG
                let action = debugString(arguments, "action")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() ?? "snapshot"
                let sampler = DebugProcessMemorySampler.shared

                let response: DebugProcessMemorySampler.DebugMemorySamplerResponse
                switch action {
                case "start":
                    let intervalMS: Int
                    switch debugBoundedInt(arguments, "interval_ms", defaultValue: 100, range: 50 ... 5000) {
                    case let .value(parsed), let .defaulted(parsed):
                        intervalMS = parsed
                    case .invalid:
                        return debugDiagnosticsError(op: op, code: "invalid_params", message: "`interval_ms` must be an integer between 50 and 5000.")
                    }
                    let label = debugString(arguments, "label")?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let reset = debugBool(arguments, "reset") ?? false
                    response = await sampler.start(
                        label: (label?.isEmpty == false ? label : nil) ?? "large-workspace-memory",
                        intervalMS: intervalMS,
                        reset: reset,
                        benchmarkGate: debugBool(arguments, "benchmark_gate") ?? false
                    )
                case "mark":
                    guard let mark = debugString(arguments, "mark")?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !mark.isEmpty
                    else {
                        return debugDiagnosticsError(op: op, code: "invalid_params", message: "`mark` must be a non-empty string for action `mark`.")
                    }
                    response = await sampler.mark(mark)
                case "stop":
                    guard let rawSessionID = debugString(arguments, "session_id")?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        let sessionID = UUID(uuidString: rawSessionID)
                    else {
                        return debugDiagnosticsError(
                            op: op,
                            code: "invalid_params",
                            message: "`session_id` must be a UUID for action `stop`."
                        )
                    }
                    let settleSeconds = debugDouble(arguments, "settle_seconds") ?? 0
                    guard settleSeconds.isFinite, settleSeconds >= 0, settleSeconds <= 300 else {
                        return debugDiagnosticsError(op: op, code: "invalid_params", message: "`settle_seconds` must be a number between 0 and 300.")
                    }
                    response = await sampler.stop(sessionID: sessionID, settleSeconds: settleSeconds)
                case "snapshot":
                    let limit: Int
                    switch debugBoundedInt(arguments, "limit", defaultValue: 50, range: 1 ... 1000) {
                    case let .value(parsed), let .defaulted(parsed):
                        limit = parsed
                    case .invalid:
                        return debugDiagnosticsError(op: op, code: "invalid_params", message: "`limit` must be an integer between 1 and 1000.")
                    }
                    response = await sampler.snapshot(limit: limit)
                case "current":
                    let limit: Int
                    switch debugBoundedInt(arguments, "limit", defaultValue: 50, range: 1 ... 1000) {
                    case let .value(parsed), let .defaulted(parsed):
                        limit = parsed
                    case .invalid:
                        return debugDiagnosticsError(op: op, code: "invalid_params", message: "`limit` must be an integer between 1 and 1000.")
                    }
                    response = await sampler.current(limit: limit)
                case "reset":
                    response = await sampler.reset()
                default:
                    return debugDiagnosticsError(op: op, code: "invalid_params", message: "Unknown `large_workspace_memory` action: \(action).")
                }

                switch response {
                case var .payload(payload):
                    payload["op"] = op
                    payload["action"] = action
                    return debugDiagnosticsResult(payload)
                case let .error(code, message):
                    return debugDiagnosticsError(op: op, code: code, message: message)
                }
            #else
                return debugDiagnosticsError(op: op, code: "unavailable", message: "`large_workspace_memory` is only available in DEBUG builds.")
            #endif
        }
    }
#endif
