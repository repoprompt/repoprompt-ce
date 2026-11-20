import Foundation
import RepoPromptDomainRuntime
import RepoPromptInstrumentation

// MARK: - MCP tool-call concurrency evidence (Stage 0 of the concurrency plan)

// Release-safe, always-on, bounded evidence layer for MCP tool-call concurrency.
//
// Purpose: capture the stage/queue evidence needed to evaluate later concurrency
// changes (see `docs/designs/mcp-tool-call-concurrency-first-principles-2026-07-26.md`,
// §P6 / Stage 0) without changing admission behavior or limits.
//
// Entry points:
// - The `tools/call` pipeline in `the app connection host` records lane waits, resource
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
package enum MCPToolConcurrencyEvidenceClass: String, CaseIterable {
    case exclusive
    case control
    case smallRead = "small_read"
    case fileRead = "file_read"
    case gitRead = "git_read"
    case fileSearch = "file_search"
    case unclassified

    package init(admissionClass: MCPToolAdmissionClass?) {
        switch admissionClass {
        case .exclusive: self = .exclusive
        case .control: self = .control
        case .smallRead: self = .smallRead
        case .fileRead: self = .fileRead
        case .gitRead: self = .gitRead
        case .fileSearch: self = .fileSearch
        case nil: self = .unclassified
        }
    }
}

/// Pipeline stages measurable accurately at existing boundaries.
package enum MCPToolConcurrencyEvidenceStage: String, CaseIterable {
    /// Connection-lane (per-connection `AsyncLimiter`) admission wait.
    case laneWait = "lane_wait"
    /// Cross-connection resource lease wait (window/app mutation, per-window
    /// small-read/file-read, per-repository git tool lease).
    case leaseWait = "lease_wait"
    /// Provider execution from dispatch origin to handler completion, sourced from
    /// `MCPToolExecutionTraceEvent(.handlerCompleted)`.
    case execution
    /// Full `tools/call` envelope from arrival to reply construction.
    case total
}

/// Typed reasons for counted admission-path rejections/terminations. Counts only.
package enum MCPToolConcurrencyEvidenceRejectionReason: String, CaseIterable {
    case unclassifiedTool = "unclassified_tool"
    case laneWaitCancelled = "lane_wait_cancelled"
    case leaseWaitCancelled = "lease_wait_cancelled"
    case leaseWaitFailed = "lease_wait_failed"

    /// Classifies a lease-acquire failure without assuming every error is a
    /// cancellation: only `CancellationError` counts as cancelled, everything
    /// else is an accurate generic failure.
    package static func leaseWaitTermination(for error: Error) -> MCPToolConcurrencyEvidenceRejectionReason {
        error is CancellationError ? .leaseWaitCancelled : .leaseWaitFailed
    }
}

/// Fixed-bucket latency histogram (milliseconds). Value type; aggregation happens
/// under the recorder's lock.
package struct MCPToolConcurrencyLatencyHistogram: Equatable {
    /// Log-scale upper bounds in milliseconds; the final implicit bucket is +inf.
    package static let bucketUpperBoundsMilliseconds: [Double] = [
        1, 2, 5, 10, 25, 50, 100, 250, 500,
        1000, 2500, 5000, 10000, 30000, 60000
    ]

    package private(set) var bucketCounts: [UInt64]
    package private(set) var count: UInt64 = 0
    package private(set) var sumMilliseconds: Double = 0
    package private(set) var maxMilliseconds: Double = 0

    package init() {
        bucketCounts = Array(
            repeating: 0,
            count: Self.bucketUpperBoundsMilliseconds.count + 1
        )
    }

    package mutating func record(milliseconds: Double) {
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
    package func estimatedQuantileMilliseconds(_ quantile: Double) -> Double? {
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
package struct MCPToolConcurrencyEvidenceSnapshot: Equatable {
    package struct ClassSnapshot: Equatable {
        package let classKey: String
        package let stageHistograms: [String: MCPToolConcurrencyLatencyHistogram]
        package let laneWaitingHighWater: Int
        package let laneHeldHighWater: Int
        package let laneAdmittedCount: UInt64
        package let laneWaitAbandonedCount: UInt64
        package let rejectionCounts: [String: UInt64]
        package let executionTracePhaseCounts: [String: UInt64]
    }

    package struct OperationSnapshot: Equatable {
        package let canonicalTool: String
        package let normalizedOperation: String
        package let admissionClass: String
        package let connectionLaneLimit: Int?
        package let resourceLeaseLimit: Int?
        package let resourceLeaseScope: String?
        package let completedCallCount: UInt64
        package let stageHistograms: [String: MCPToolConcurrencyLatencyHistogram]
        package let rejectionCounts: [String: UInt64]
        package let executionTracePhaseCounts: [String: UInt64]
    }

    package static let schemaVersion = 2

    /// Sorted by `classKey` for deterministic iteration. Preserved from schema v1.
    package let classes: [ClassSnapshot]
    /// Completed-call counts per canonical tool name (classified catalog only).
    /// Preserved from schema v1.
    package let completedCallCountsByTool: [String: UInt64]
    /// Sorted by `(canonicalTool, normalizedOperation)` for deterministic iteration.
    package let operations: [OperationSnapshot]

    package init(
        classes: [ClassSnapshot],
        completedCallCountsByTool: [String: UInt64],
        operations: [OperationSnapshot]
    ) {
        self.classes = classes
        self.completedCallCountsByTool = completedCallCountsByTool
        self.operations = operations
    }
}

/// Process-wide evidence recorder. `@unchecked Sendable` justified by the single
/// internal lock guarding all mutable state; no callouts run under the lock.
package final class MCPToolConcurrencyEvidenceRecorder: @unchecked Sendable {
    package static let shared = MCPToolConcurrencyEvidenceRecorder()

    package static let unclassifiedToolKey = "(unclassified)"

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

    private struct OperationState {
        var completedCallCount: UInt64 = 0
        var stageHistograms: [MCPToolConcurrencyEvidenceStage: MCPToolConcurrencyLatencyHistogram] = [:]
        var rejectionCounts: [MCPToolConcurrencyEvidenceRejectionReason: UInt64] = [:]
        var executionTracePhaseCounts: [String: UInt64] = [:]
    }

    private let lock = NSLock()
    private var classStates: [MCPToolConcurrencyEvidenceClass: ClassState] = [:]
    private var completedCallCountsByTool: [String: UInt64] = [:]
    private var operationStates: [MCPDomainToolOperationIdentity: OperationState] = [:]

    // MARK: Lane (per-connection limiter) admission

    package func recordLaneWaitBegan(classKey: MCPToolConcurrencyEvidenceClass) {
        withClassState(classKey) { state in
            state.laneWaiting += 1
            state.laneWaitingHighWater = max(state.laneWaitingHighWater, state.laneWaiting)
        }
    }

    package func recordLaneAdmitted(
        classKey: MCPToolConcurrencyEvidenceClass,
        operationIdentity: MCPDomainToolOperationIdentity? = nil,
        waitMilliseconds: Double
    ) {
        lock.lock()
        classStates[classKey, default: ClassState()].laneWaiting = max(
            0,
            classStates[classKey, default: ClassState()].laneWaiting - 1
        )
        classStates[classKey, default: ClassState()].laneAdmittedCount += 1
        classStates[classKey, default: ClassState()].laneHeld += 1
        classStates[classKey, default: ClassState()].laneHeldHighWater = max(
            classStates[classKey, default: ClassState()].laneHeldHighWater,
            classStates[classKey, default: ClassState()].laneHeld
        )
        classStates[classKey, default: ClassState()]
            .stageHistograms[.laneWait, default: .init()]
            .record(milliseconds: waitMilliseconds)
        if let operationIdentity {
            operationStates[operationIdentity, default: OperationState()]
                .stageHistograms[.laneWait, default: .init()]
                .record(milliseconds: waitMilliseconds)
        }
        lock.unlock()
    }

    package func recordLanePermitReleased(classKey: MCPToolConcurrencyEvidenceClass) {
        withClassState(classKey) { state in
            state.laneHeld = max(0, state.laneHeld - 1)
        }
    }

    package func recordLaneWaitAbandoned(classKey: MCPToolConcurrencyEvidenceClass) {
        withClassState(classKey) { state in
            state.laneWaiting = max(0, state.laneWaiting - 1)
            state.laneWaitAbandonedCount += 1
        }
    }

    // MARK: Resource lease waits

    package func recordLeaseWait(
        classKey: MCPToolConcurrencyEvidenceClass,
        operationIdentity: MCPDomainToolOperationIdentity? = nil,
        milliseconds: Double
    ) {
        lock.lock()
        classStates[classKey, default: ClassState()]
            .stageHistograms[.leaseWait, default: .init()]
            .record(milliseconds: milliseconds)
        if let operationIdentity {
            operationStates[operationIdentity, default: OperationState()]
                .stageHistograms[.leaseWait, default: .init()]
                .record(milliseconds: milliseconds)
        }
        lock.unlock()
    }

    // MARK: Rejections

    package func recordRejection(
        classKey: MCPToolConcurrencyEvidenceClass,
        operationIdentity: MCPDomainToolOperationIdentity? = nil,
        reason: MCPToolConcurrencyEvidenceRejectionReason
    ) {
        lock.lock()
        classStates[classKey, default: ClassState()].rejectionCounts[reason, default: 0] += 1
        if let operationIdentity {
            operationStates[operationIdentity, default: OperationState()]
                .rejectionCounts[reason, default: 0] += 1
        }
        lock.unlock()
    }

    // MARK: Completion

    package func recordCallCompleted(
        classKey: MCPToolConcurrencyEvidenceClass,
        canonicalToolName: String,
        operationIdentity: MCPDomainToolOperationIdentity? = nil,
        totalMilliseconds: Double
    ) {
        let countedToolName = MCPDomainToolCatalog.admissionClass(
            for: canonicalToolName
        ) != nil ? canonicalToolName : Self.unclassifiedToolKey
        // Single critical section: class/tool compatibility aggregates and the v2
        // operation terminal event move together. The tools/call caller invokes this
        // once from one outer defer, including all early and watchdog return paths.
        lock.lock()
        classStates[classKey, default: ClassState()]
            .stageHistograms[.total, default: .init()]
            .record(milliseconds: totalMilliseconds)
        completedCallCountsByTool[countedToolName, default: 0] += 1
        if let operationIdentity {
            operationStates[operationIdentity, default: OperationState()].completedCallCount += 1
            operationStates[operationIdentity, default: OperationState()]
                .stageHistograms[.total, default: .init()]
                .record(milliseconds: totalMilliseconds)
        }
        lock.unlock()
    }

    // MARK: Execution lifecycle (fed by MCPToolExecutionTracer)

    /// Ingests every execution trace event. `handlerCompleted` feeds the execution
    /// latency histogram; every phase feeds bounded per-phase counters (this is the
    /// release-safe watchdog/escalation evidence).
    package func recordExecutionTraceEvent(_ event: MCPToolExecutionTraceEvent) {
        let classKey = MCPToolConcurrencyEvidenceClass(
            admissionClass: MCPDomainToolCatalog.admissionClass(
                for: event.operationIdentity.canonicalTool
            )
        )
        lock.lock()
        classStates[classKey, default: ClassState()]
            .executionTracePhaseCounts[event.phase.rawValue, default: 0] += 1
        operationStates[event.operationIdentity, default: OperationState()]
            .executionTracePhaseCounts[event.phase.rawValue, default: 0] += 1
        if event.phase == .handlerCompleted {
            classStates[classKey, default: ClassState()]
                .stageHistograms[.execution, default: .init()]
                .record(milliseconds: event.elapsedMilliseconds)
            operationStates[event.operationIdentity, default: OperationState()]
                .stageHistograms[.execution, default: .init()]
                .record(milliseconds: event.elapsedMilliseconds)
        }
        lock.unlock()
    }

    // MARK: Snapshot / reset

    package func snapshot() -> MCPToolConcurrencyEvidenceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return makeSnapshotLocked()
    }

    /// Atomically snapshots and clears all counters under one lock acquisition, so
    /// no event recorded between the two operations can be dropped.
    package func snapshotAndReset() -> MCPToolConcurrencyEvidenceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = makeSnapshotLocked()
        classStates = [:]
        completedCallCountsByTool = [:]
        operationStates = [:]
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
        let operations = operationStates
            .map { identity, state in
                let classKey = MCPToolConcurrencyEvidenceClass(
                    admissionClass: MCPDomainToolCatalog.admissionClass(
                        for: identity.canonicalTool
                    )
                )
                let limits = MCPDomainToolCatalog.configuredLimits(for: identity.canonicalTool)
                return MCPToolConcurrencyEvidenceSnapshot.OperationSnapshot(
                    canonicalTool: identity.canonicalTool,
                    normalizedOperation: identity.normalizedOperation,
                    admissionClass: classKey.rawValue,
                    connectionLaneLimit: limits?.connectionLane,
                    resourceLeaseLimit: limits?.resourceLease,
                    resourceLeaseScope: limits?.resourceScope?.rawValue,
                    completedCallCount: state.completedCallCount,
                    stageHistograms: Dictionary(
                        uniqueKeysWithValues: state.stageHistograms.map { ($0.key.rawValue, $0.value) }
                    ),
                    rejectionCounts: Dictionary(
                        uniqueKeysWithValues: state.rejectionCounts.map { ($0.key.rawValue, $0.value) }
                    ),
                    executionTracePhaseCounts: state.executionTracePhaseCounts
                )
            }
            .sorted {
                ($0.canonicalTool, $0.normalizedOperation)
                    < ($1.canonicalTool, $1.normalizedOperation)
            }
        return MCPToolConcurrencyEvidenceSnapshot(
            classes: classes,
            completedCallCountsByTool: completedCallCountsByTool,
            operations: operations
        )
    }

    package func reset() {
        lock.lock()
        classStates = [:]
        completedCallCountsByTool = [:]
        operationStates = [:]
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
