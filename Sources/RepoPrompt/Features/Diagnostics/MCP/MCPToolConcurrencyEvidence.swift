import Foundation
import RepoPromptMCPServer

#if DEBUG
    import MCP

    extension ServerNetworkManager {
        /// `mcp_tool_concurrency_evidence_snapshot` debug diagnostics op.
        /// Pass `"reset": true` to clear all counters after snapshotting.
        func debugMCPToolConcurrencyEvidencePayload(
            op: String,
            arguments: [String: Value]
        ) -> CallTool.Result {
            let recorder = MCPToolConcurrencyEvidenceRecorder.shared
            let snapshot = debugBool(arguments, "reset") == true
                ? recorder.snapshotAndReset()
                : recorder.snapshot()
            var payload: [String: Any] = [
                "ok": true,
                "op": op,
                "payload_logging": false,
                "schema_version": MCPToolConcurrencyEvidenceSnapshot.schemaVersion,
                "bucket_upper_bounds_ms": MCPToolConcurrencyLatencyHistogram.bucketUpperBoundsMilliseconds
            ]
            payload["classes"] = snapshot.classes.map { classSnapshot -> [String: Any] in
                var classPayload: [String: Any] = [
                    "class": classSnapshot.classKey,
                    "lane_waiting_high_water": classSnapshot.laneWaitingHighWater,
                    "lane_held_high_water": classSnapshot.laneHeldHighWater,
                    "lane_admitted_count": classSnapshot.laneAdmittedCount,
                    "lane_wait_abandoned_count": classSnapshot.laneWaitAbandonedCount
                ]
                classPayload["rejections"] = classSnapshot.rejectionCounts
                    .sorted { $0.key < $1.key }
                    .map { ["reason": $0.key, "count": $0.value] }
                classPayload["execution_trace_phases"] = classSnapshot.executionTracePhaseCounts
                    .sorted { $0.key < $1.key }
                    .map { ["phase": $0.key, "count": $0.value] }
                classPayload["stages"] = classSnapshot.stageHistograms
                    .sorted { $0.key < $1.key }
                    .map { stageKey, histogram -> [String: Any] in
                        var stagePayload: [String: Any] = [
                            "stage": stageKey,
                            "count": histogram.count,
                            "sum_ms": histogram.sumMilliseconds,
                            "max_ms": histogram.maxMilliseconds,
                            "bucket_counts": histogram.bucketCounts
                        ]
                        if let p50 = histogram.estimatedQuantileMilliseconds(0.5) {
                            stagePayload["p50_ms_upper_bound"] = p50
                        }
                        if let p95 = histogram.estimatedQuantileMilliseconds(0.95) {
                            stagePayload["p95_ms_upper_bound"] = p95
                        }
                        if let p99 = histogram.estimatedQuantileMilliseconds(0.99) {
                            stagePayload["p99_ms_upper_bound"] = p99
                        }
                        return stagePayload
                    }
                return classPayload
            }
            payload["operations"] = snapshot.operations.map { operationSnapshot -> [String: Any] in
                var operationPayload: [String: Any] = [
                    "tool": operationSnapshot.canonicalTool,
                    "operation": operationSnapshot.normalizedOperation,
                    "admission_class": operationSnapshot.admissionClass,
                    "completed_call_count": operationSnapshot.completedCallCount,
                    "connection_lane_limit": operationSnapshot.connectionLaneLimit.map { $0 as Any } ?? NSNull(),
                    "resource_lease_limit": operationSnapshot.resourceLeaseLimit.map { $0 as Any } ?? NSNull(),
                    "resource_lease_scope": operationSnapshot.resourceLeaseScope.map { $0 as Any } ?? NSNull()
                ]
                operationPayload["rejections"] = operationSnapshot.rejectionCounts
                    .sorted { $0.key < $1.key }
                    .map { ["reason": $0.key, "count": $0.value] }
                operationPayload["execution_trace_phases"] = operationSnapshot.executionTracePhaseCounts
                    .sorted { $0.key < $1.key }
                    .map { ["phase": $0.key, "count": $0.value] }
                operationPayload["stages"] = operationSnapshot.stageHistograms
                    .sorted { $0.key < $1.key }
                    .map { stageKey, histogram -> [String: Any] in
                        var stagePayload: [String: Any] = [
                            "stage": stageKey,
                            "count": histogram.count,
                            "sum_ms": histogram.sumMilliseconds,
                            "max_ms": histogram.maxMilliseconds,
                            "bucket_counts": histogram.bucketCounts
                        ]
                        if let p50 = histogram.estimatedQuantileMilliseconds(0.5) {
                            stagePayload["p50_ms_upper_bound"] = p50
                        }
                        if let p95 = histogram.estimatedQuantileMilliseconds(0.95) {
                            stagePayload["p95_ms_upper_bound"] = p95
                        }
                        if let p99 = histogram.estimatedQuantileMilliseconds(0.99) {
                            stagePayload["p99_ms_upper_bound"] = p99
                        }
                        return stagePayload
                    }
                return operationPayload
            }
            payload["completed_calls_by_tool"] = snapshot.completedCallCountsByTool
                .sorted { $0.key < $1.key }
                .map { ["tool": $0.key, "count": $0.value] }
            return debugDiagnosticsResult(payload)
        }
    }
#endif
