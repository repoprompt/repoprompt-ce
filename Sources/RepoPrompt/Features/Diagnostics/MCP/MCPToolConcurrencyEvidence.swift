import Foundation

// MARK: - MCP tool-call concurrency evidence (Stage 0 of the concurrency plan)

// Release-safe, always-on, bounded evidence layer for MCP tool-call concurrency.
//
// Purpose: capture the stage/queue evidence needed to evaluate later concurrency
// changes (see `docs/designs/mcp-tool-call-concurrency-first-principles-2026-07-26.md`,
// §P6 / Stage 0) without changing admission behavior or limits.
//
// Entry points:
// - The `tools/call` pipeline in `ServerNetworkManager` records lane waits, resource
//   lease waits, rejections, and total pipeline durations at its existing stage
//   boundaries (the same boundaries the DEBUG-only `EditFlowPerf` stages annotate).
// - `MCPToolExecutionTracer.emit` forwards every execution lifecycle/watchdog trace
//   event (already constructed unconditionally in release builds), which yields
//   execution-stage latency and watchdog escalation counters without new probes.
// - The DEBUG diagnostics surface exposes a deterministic snapshot via the
//   `mcp_tool_concurrency_evidence_snapshot` op (with optional `reset`).
//
// Privacy posture (matches `EditFlowPerf` rules): canonical tool names, admission
// class keys, counts, and durations only. Never prompts, arguments, file contents,
// user paths, or result bodies. Per-tool counts are restricted to names present in
// the static admission classification table; anything else aggregates under
// `(unclassified)`.
//
// Bounded by construction: fixed class keys × fixed stages × fixed histogram
// buckets plus a handful of counters (single-digit KB total). No per-call records
// are retained. Per-call overhead is a few `ContinuousClock` reads and O(1)
// lock-protected counter updates.

/// Stable aggregation key. Mirrors `MCPToolAdmissionClass` plus a catch-all for
/// tools without a static classification.
enum MCPToolConcurrencyEvidenceClass: String, CaseIterable {
    case exclusive
    case control
    case smallRead = "small_read"
    case gitRead = "git_read"
    case fileSearch = "file_search"
    case unclassified

    init(admissionClass: MCPToolAdmissionClass?) {
        switch admissionClass {
        case .exclusive: self = .exclusive
        case .control: self = .control
        case .smallRead: self = .smallRead
        case .gitRead: self = .gitRead
        case .fileSearch: self = .fileSearch
        case nil: self = .unclassified
        }
    }
}

/// Pipeline stages measurable accurately at existing boundaries.
enum MCPToolConcurrencyEvidenceStage: String, CaseIterable {
    /// Connection-lane (per-connection `AsyncLimiter`) admission wait.
    case laneWait = "lane_wait"
    /// Cross-connection resource lease wait (window/app mutation, per-window
    /// small-read, per-repository git tool lease).
    case leaseWait = "lease_wait"
    /// Provider execution from dispatch origin to handler completion, sourced from
    /// `MCPToolExecutionTraceEvent(.handlerCompleted)`.
    case execution
    /// Full `tools/call` envelope from arrival to reply construction.
    case total
}

/// Typed reasons for counted admission-path rejections/terminations. Counts only.
enum MCPToolConcurrencyEvidenceRejectionReason: String, CaseIterable {
    case unclassifiedTool = "unclassified_tool"
    case laneWaitCancelled = "lane_wait_cancelled"
    case leaseWaitCancelled = "lease_wait_cancelled"
    case leaseWaitFailed = "lease_wait_failed"

    /// Classifies a lease-acquire failure without assuming every error is a
    /// cancellation: only `CancellationError` counts as cancelled, everything
    /// else is an accurate generic failure.
    static func leaseWaitTermination(for error: Error) -> MCPToolConcurrencyEvidenceRejectionReason {
        error is CancellationError ? .leaseWaitCancelled : .leaseWaitFailed
    }
}

/// Fixed-bucket latency histogram (milliseconds). Value type; aggregation happens
/// under the recorder's lock.
struct MCPToolConcurrencyLatencyHistogram: Equatable {
    /// Log-scale upper bounds in milliseconds; the final implicit bucket is +inf.
    static let bucketUpperBoundsMilliseconds: [Double] = [
        1, 2, 5, 10, 25, 50, 100, 250, 500,
        1000, 2500, 5000, 10000, 30000, 60000
    ]

    private(set) var bucketCounts: [UInt64]
    private(set) var count: UInt64 = 0
    private(set) var sumMilliseconds: Double = 0
    private(set) var maxMilliseconds: Double = 0

    init() {
        bucketCounts = Array(
            repeating: 0,
            count: Self.bucketUpperBoundsMilliseconds.count + 1
        )
    }

    mutating func record(milliseconds: Double) {
        let value = max(0, milliseconds)
        let index = Self.bucketUpperBoundsMilliseconds.firstIndex { value <= $0 }
            ?? Self.bucketUpperBoundsMilliseconds.count
        bucketCounts[index] += 1
        count += 1
        sumMilliseconds += value
        maxMilliseconds = max(maxMilliseconds, value)
    }

    /// Deterministic conservative quantile estimate: the upper bound of the bucket
    /// containing the requested rank (`maxMilliseconds` for the overflow bucket).
    func estimatedQuantileMilliseconds(_ quantile: Double) -> Double? {
        guard count > 0 else { return nil }
        let clamped = min(max(quantile, 0), 1)
        let rank = UInt64((clamped * Double(count)).rounded(.up))
        let targetRank = max(rank, 1)
        var cumulative: UInt64 = 0
        for (index, bucketCount) in bucketCounts.enumerated() {
            cumulative += bucketCount
            if cumulative >= targetRank {
                if index < Self.bucketUpperBoundsMilliseconds.count {
                    return Self.bucketUpperBoundsMilliseconds[index]
                }
                return maxMilliseconds
            }
        }
        return maxMilliseconds
    }
}

/// Deterministic, `Sendable` snapshot of all evidence counters.
struct MCPToolConcurrencyEvidenceSnapshot: Equatable {
    struct ClassSnapshot: Equatable {
        let classKey: String
        let stageHistograms: [String: MCPToolConcurrencyLatencyHistogram]
        let laneWaitingHighWater: Int
        let laneHeldHighWater: Int
        let laneAdmittedCount: UInt64
        let laneWaitAbandonedCount: UInt64
        let rejectionCounts: [String: UInt64]
        let executionTracePhaseCounts: [String: UInt64]
    }

    static let schemaVersion = 1

    /// Sorted by `classKey` for deterministic iteration.
    let classes: [ClassSnapshot]
    /// Completed-call counts per canonical tool name (classified catalog only).
    let completedCallCountsByTool: [String: UInt64]
}

/// Process-wide evidence recorder. `@unchecked Sendable` justified by the single
/// internal lock guarding all mutable state; no callouts run under the lock.
final class MCPToolConcurrencyEvidenceRecorder: @unchecked Sendable {
    static let shared = MCPToolConcurrencyEvidenceRecorder()

    static let unclassifiedToolKey = "(unclassified)"

    private struct ClassState {
        var stageHistograms: [MCPToolConcurrencyEvidenceStage: MCPToolConcurrencyLatencyHistogram] = [:]
        var laneWaiting = 0
        var laneWaitingHighWater = 0
        var laneHeld = 0
        var laneHeldHighWater = 0
        var laneAdmittedCount: UInt64 = 0
        var laneWaitAbandonedCount: UInt64 = 0
        var rejectionCounts: [MCPToolConcurrencyEvidenceRejectionReason: UInt64] = [:]
        var executionTracePhaseCounts: [String: UInt64] = [:]
    }

    private let lock = NSLock()
    private var classStates: [MCPToolConcurrencyEvidenceClass: ClassState] = [:]
    private var completedCallCountsByTool: [String: UInt64] = [:]

    // MARK: Lane (per-connection limiter) admission

    func recordLaneWaitBegan(classKey: MCPToolConcurrencyEvidenceClass) {
        withClassState(classKey) { state in
            state.laneWaiting += 1
            state.laneWaitingHighWater = max(state.laneWaitingHighWater, state.laneWaiting)
        }
    }

    func recordLaneAdmitted(
        classKey: MCPToolConcurrencyEvidenceClass,
        waitMilliseconds: Double
    ) {
        withClassState(classKey) { state in
            state.laneWaiting = max(0, state.laneWaiting - 1)
            state.laneAdmittedCount += 1
            state.laneHeld += 1
            state.laneHeldHighWater = max(state.laneHeldHighWater, state.laneHeld)
            state.stageHistograms[.laneWait, default: .init()].record(milliseconds: waitMilliseconds)
        }
    }

    func recordLanePermitReleased(classKey: MCPToolConcurrencyEvidenceClass) {
        withClassState(classKey) { state in
            state.laneHeld = max(0, state.laneHeld - 1)
        }
    }

    func recordLaneWaitAbandoned(classKey: MCPToolConcurrencyEvidenceClass) {
        withClassState(classKey) { state in
            state.laneWaiting = max(0, state.laneWaiting - 1)
            state.laneWaitAbandonedCount += 1
        }
    }

    // MARK: Resource lease waits

    func recordLeaseWait(
        classKey: MCPToolConcurrencyEvidenceClass,
        milliseconds: Double
    ) {
        withClassState(classKey) { state in
            state.stageHistograms[.leaseWait, default: .init()].record(milliseconds: milliseconds)
        }
    }

    // MARK: Rejections

    func recordRejection(
        classKey: MCPToolConcurrencyEvidenceClass,
        reason: MCPToolConcurrencyEvidenceRejectionReason
    ) {
        withClassState(classKey) { state in
            state.rejectionCounts[reason, default: 0] += 1
        }
    }

    // MARK: Completion

    func recordCallCompleted(
        classKey: MCPToolConcurrencyEvidenceClass,
        canonicalToolName: String,
        totalMilliseconds: Double
    ) {
        let countedToolName = MCPToolAdmissionPolicy.classification(
            forCanonicalToolName: canonicalToolName
        ) != nil ? canonicalToolName : Self.unclassifiedToolKey
        // Single critical section: the total histogram and the per-tool completed
        // count move together, so snapshots can never observe one without the other.
        lock.lock()
        classStates[classKey, default: ClassState()]
            .stageHistograms[.total, default: .init()]
            .record(milliseconds: totalMilliseconds)
        completedCallCountsByTool[countedToolName, default: 0] += 1
        lock.unlock()
    }

    // MARK: Execution lifecycle (fed by MCPToolExecutionTracer)

    /// Ingests every execution trace event. `handlerCompleted` feeds the execution
    /// latency histogram; every phase feeds bounded per-phase counters (this is the
    /// release-safe watchdog/escalation evidence).
    func recordExecutionTraceEvent(_ event: MCPToolExecutionTraceEvent) {
        let classKey = MCPToolConcurrencyEvidenceClass(
            admissionClass: MCPToolAdmissionPolicy.classification(
                forCanonicalToolName: event.toolName
            )
        )
        withClassState(classKey) { state in
            state.executionTracePhaseCounts[event.phase.rawValue, default: 0] += 1
            if event.phase == .handlerCompleted {
                state.stageHistograms[.execution, default: .init()]
                    .record(milliseconds: event.elapsedMilliseconds)
            }
        }
    }

    // MARK: Snapshot / reset

    func snapshot() -> MCPToolConcurrencyEvidenceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return makeSnapshotLocked()
    }

    /// Atomically snapshots and clears all counters under one lock acquisition, so
    /// no event recorded between the two operations can be dropped.
    func snapshotAndReset() -> MCPToolConcurrencyEvidenceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = makeSnapshotLocked()
        classStates = [:]
        completedCallCountsByTool = [:]
        return snapshot
    }

    private func makeSnapshotLocked() -> MCPToolConcurrencyEvidenceSnapshot {
        let classes = classStates
            .map { classKey, state in
                MCPToolConcurrencyEvidenceSnapshot.ClassSnapshot(
                    classKey: classKey.rawValue,
                    stageHistograms: Dictionary(
                        uniqueKeysWithValues: state.stageHistograms.map { ($0.key.rawValue, $0.value) }
                    ),
                    laneWaitingHighWater: state.laneWaitingHighWater,
                    laneHeldHighWater: state.laneHeldHighWater,
                    laneAdmittedCount: state.laneAdmittedCount,
                    laneWaitAbandonedCount: state.laneWaitAbandonedCount,
                    rejectionCounts: Dictionary(
                        uniqueKeysWithValues: state.rejectionCounts.map { ($0.key.rawValue, $0.value) }
                    ),
                    executionTracePhaseCounts: state.executionTracePhaseCounts
                )
            }
            .sorted { $0.classKey < $1.classKey }
        return MCPToolConcurrencyEvidenceSnapshot(
            classes: classes,
            completedCallCountsByTool: completedCallCountsByTool
        )
    }

    func reset() {
        lock.lock()
        classStates = [:]
        completedCallCountsByTool = [:]
        lock.unlock()
    }

    private func withClassState(
        _ classKey: MCPToolConcurrencyEvidenceClass,
        _ body: (inout ClassState) -> Void
    ) {
        lock.lock()
        // In-place subscript mutation (`_modify` accessor): no copy-out/write-back
        // CoW churn on the per-event hot path.
        body(&classStates[classKey, default: ClassState()])
        lock.unlock()
    }
}

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
            payload["completed_calls_by_tool"] = snapshot.completedCallCountsByTool
                .sorted { $0.key < $1.key }
                .map { ["tool": $0.key, "count": $0.value] }
            return debugDiagnosticsResult(payload)
        }
    }
#endif
