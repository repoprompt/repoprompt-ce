import Foundation

/// Window-scoped response-lane coordinator for Agent Mode `read_file` and eligible `file_search`
/// automatic selection.
///
/// Agent Mode reads and content-search slice replies enqueue a lightweight intent and return without
/// awaiting structural selection mutation, UI mirroring, token recounts, or workspace durability.
/// Explicit consumers drain a finite accepted high-water mark when they require stable selection state.
@MainActor
final class MCPReadFileAutoSelectionCoordinator {
    enum DrainRequirement: String, Equatable {
        case canonicalSelection = "canonical"
        case mirroredSelectionAndMetrics = "mirrored"
    }

    enum DrainResult: Equatable {
        case completed
        case cancelled
    }

    enum Route: Hashable {
        case bound(connectionID: UUID, runID: UUID?)
        case activeTabCompatibility

        var diagnosticScope: String {
            switch self {
            case .bound: "bound"
            case .activeTabCompatibility: "active_compatibility"
            }
        }
    }

    struct ContextKey: Hashable {
        let windowID: Int
        let workspaceID: UUID?
        let tabID: UUID
        let route: Route
        let bindingGeneration: UInt64

        var mirrorKey: TabMirrorKey {
            TabMirrorKey(windowID: windowID, workspaceID: workspaceID, tabID: tabID)
        }
    }

    struct TabMirrorKey: Hashable {
        let windowID: Int
        let workspaceID: UUID?
        let tabID: UUID
    }

    enum CoverageCertificateOutcome: Equatable {
        case hit
        case authoritativeFallback(ReadFileAutoSelectionCoverageCertificateMissReason)
    }

    struct CanonicalApplyResult {
        enum Disposition: String {
            case changed
            case semanticNoOp
            case rejected
        }

        let mirrorKey: TabMirrorKey?
        let disposition: Disposition
        let coverageCertificateOutcome: CoverageCertificateOutcome?

        init(
            mirrorKey: TabMirrorKey?,
            disposition: Disposition? = nil,
            coverageCertificateOutcome: CoverageCertificateOutcome? = nil
        ) {
            self.mirrorKey = mirrorKey
            self.disposition = disposition ?? (mirrorKey == nil ? .semanticNoOp : .changed)
            self.coverageCertificateOutcome = coverageCertificateOutcome
        }

        static let unchanged = CanonicalApplyResult(mirrorKey: nil, disposition: .semanticNoOp)
        static let rejected = CanonicalApplyResult(mirrorKey: nil, disposition: .rejected)
    }

    #if DEBUG
        enum DebugCanonicalApplyOutcome: String, Equatable {
            case changed
            case semanticNoOp = "semantic_noop"
            case rejected
            case invalidated
        }

        struct DebugCanonicalApplySample: Equatable {
            let ordinal: UInt64
            let durationMilliseconds: Double
            let outcome: DebugCanonicalApplyOutcome
            let acceptedIntentCount: UInt64
            let completedHighWaterSequence: UInt64
            let coverageCertificateOutcome: CoverageCertificateOutcome?
        }

        struct DebugContextSnapshot: Equatable {
            let acceptedHighWaterSequence: UInt64
            let completedHighWaterSequence: UInt64
            let acceptedIntentCount: UInt64
            let completedIntentCount: UInt64
            let canonicalApplyAttemptCount: UInt64
            let changedApplyCount: UInt64
            let semanticNoOpApplyCount: UInt64
            let rejectedApplyCount: UInt64
            let changedIntentCount: UInt64
            let semanticNoOpIntentCount: UInt64
            let rejectedIntentCount: UInt64
            let invalidatedIntentCount: UInt64
            let coverageCertificateHitCount: UInt64
            let authoritativeFallbackCount: UInt64
            let coverageCertificateMissReasonCounts: [ReadFileAutoSelectionCoverageCertificateMissReason: UInt64]
            let mutationTotalMilliseconds: Double
            let mutationSamples: [DebugCanonicalApplySample]
            let sampleOverflowCount: UInt64
            let workerActive: Bool
            let pendingWork: Bool
            let waiterCount: Int
        }

        struct DebugDrainResult: Equatable {
            let result: DrainResult
            let capturedTargetSequence: UInt64
        }

        struct DebugSnapshot: Equatable {
            let canonicalLaneCount: Int
            let canonicalWorkerCount: Int
            let mirrorLaneCount: Int
            let mirrorWorkerCount: Int
            let closingContextCount: Int
            let pendingCanonicalBatchCount: Int
            let pendingMirrorBatchCount: Int
            let canonicalWaiterCount: Int
            let mirrorWaiterCount: Int
        }
    #endif

    typealias IsContextCurrent = @MainActor (ContextKey) -> Bool
    typealias ApplyCanonical = @MainActor (ContextKey, CanonicalBatch) async -> CanonicalApplyResult
    typealias ApplyMirror = @MainActor (TabMirrorKey) async -> Void

    private struct QueuedCanonicalBatch {
        var batch: CanonicalBatch
        let lowestSequence: UInt64
        var highestSequence: UInt64
        var acceptedIntentCount: UInt64
        var lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
        let queueWaitState: EditFlowPerf.IntervalState?
    }

    private enum CanonicalWaitResult {
        case completed(requiredMirrorTicket: UInt64?)
        case cancelled
    }

    private enum SequenceWaitResult {
        case completed
        case cancelled
    }

    private struct CanonicalSequenceWaiter {
        let target: UInt64
        let continuation: CheckedContinuation<CanonicalWaitResult, Never>
    }

    private struct SequenceWaiter {
        let target: UInt64
        let continuation: CheckedContinuation<SequenceWaitResult, Never>
    }

    private struct CanonicalLane {
        var acceptedSequence: UInt64 = 0
        var completedSequence: UInt64 = 0
        var pending: QueuedCanonicalBatch?
        var latestRequiredMirrorTicket: UInt64?
        var waiters: [UUID: CanonicalSequenceWaiter] = [:]
    }

    private struct QueuedMirrorBatch {
        var highestTicket: UInt64
        var lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
        let queueWaitState: EditFlowPerf.IntervalState?
    }

    private struct MirrorLane {
        var acceptedTicket: UInt64 = 0
        var completedTicket: UInt64 = 0
        var pending: QueuedMirrorBatch?
        var waiters: [UUID: SequenceWaiter] = [:]
    }

    private let isContextCurrent: IsContextCurrent
    private let applyCanonical: ApplyCanonical
    private let applyMirror: ApplyMirror
    private var nextSequence: UInt64 = 0
    private var canonicalLanes: [ContextKey: CanonicalLane] = [:]
    private var canonicalWorkers = Set<ContextKey>()
    private var canonicalWorkerIDs: [ContextKey: UUID] = [:]
    private var mirrorLanes: [TabMirrorKey: MirrorLane] = [:]
    private var mirrorWorkers = Set<TabMirrorKey>()
    private var mirrorWorkerIDs: [TabMirrorKey: UUID] = [:]
    private var closingContexts = Set<ContextKey>()
    private var invalidatedContexts = Set<ContextKey>()
    private var retiringContexts = Set<ContextKey>()
    #if DEBUG
        private struct DebugContextAccounting {
            var acceptedIntentCount: UInt64 = 0
            var completedIntentCount: UInt64 = 0
            var canonicalApplyAttemptCount: UInt64 = 0
            var changedApplyCount: UInt64 = 0
            var semanticNoOpApplyCount: UInt64 = 0
            var rejectedApplyCount: UInt64 = 0
            var changedIntentCount: UInt64 = 0
            var semanticNoOpIntentCount: UInt64 = 0
            var rejectedIntentCount: UInt64 = 0
            var invalidatedIntentCount: UInt64 = 0
            var coverageCertificateHitCount: UInt64 = 0
            var authoritativeFallbackCount: UInt64 = 0
            var coverageCertificateMissReasonCounts: [ReadFileAutoSelectionCoverageCertificateMissReason: UInt64] = [:]
            var mutationTotalMilliseconds: Double = 0
            var nextSampleOrdinal: UInt64 = 0
            var mutationSamples: [DebugCanonicalApplySample] = []
            var sampleOverflowCount: UInt64 = 0
        }

        private static let debugMutationSampleLimit = 256
        private var canonicalApplyGateForTesting: (() async -> Void)?
        private var debugAccountingByContext: [ContextKey: DebugContextAccounting] = [:]
    #endif

    init(
        isContextCurrent: @escaping IsContextCurrent,
        applyCanonical: @escaping ApplyCanonical,
        applyMirror: @escaping ApplyMirror
    ) {
        self.isContextCurrent = isContextCurrent
        self.applyCanonical = applyCanonical
        self.applyMirror = applyMirror
    }

    @discardableResult
    func enqueue(
        intent: Intent,
        coverageIdentity: CoverageIdentity? = nil,
        for key: ContextKey,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation? = EditFlowPerf.currentLifecycleCorrelation
    ) -> Bool {
        let enqueueState = EditFlowPerf.begin(
            EditFlowPerf.Stage.ReadFile.AutoSelect.responseEnqueue,
            EditFlowPerf.Dimensions(status: key.route.diagnosticScope)
        )
        var outcome = "accepted"
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.AutoSelect.responseEnqueue,
                enqueueState,
                EditFlowPerf.Dimensions(status: key.route.diagnosticScope, outcome: outcome)
            )
        }

        guard !closingContexts.contains(key), isContextCurrent(key) else {
            outcome = "invalidated"
            return false
        }

        nextSequence &+= 1
        let sequence = nextSequence
        var lane = canonicalLanes[key] ?? CanonicalLane()
        let previousAcceptedSequence = lane.acceptedSequence
        lane.acceptedSequence = sequence
        if var pending = lane.pending {
            pending.batch.merge(intent, coverageIdentity: coverageIdentity)
            pending.highestSequence = sequence
            pending.acceptedIntentCount &+= 1
            pending.lifecycleCorrelation = lifecycleCorrelation ?? pending.lifecycleCorrelation
            lane.pending = pending
            outcome = "coalesced"
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFileAutoSelect.enqueueCoalesced,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(status: key.route.diagnosticScope, queueDepth: 1)
            )
        } else {
            lane.pending = QueuedCanonicalBatch(
                batch: CanonicalBatch(intent: intent, coverageIdentity: coverageIdentity),
                lowestSequence: sequence,
                highestSequence: sequence,
                acceptedIntentCount: 1,
                lifecycleCorrelation: lifecycleCorrelation,
                queueWaitState: EditFlowPerf.begin(
                    EditFlowPerf.Stage.ReadFile.AutoSelect.canonicalQueueWait,
                    EditFlowPerf.Dimensions(status: key.route.diagnosticScope, queueDepth: 1)
                )
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFileAutoSelect.enqueueAccepted,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(status: key.route.diagnosticScope, queueDepth: 1)
            )
        }
        canonicalLanes[key] = lane
        #if DEBUG
            debugAccountingByContext[key, default: DebugContextAccounting()].acceptedIntentCount &+= 1
        #endif
        scheduleCanonicalWorkerIfNeeded(for: key)
        emitCanonicalDiagnostic(
            .acceptedHighWaterAdvanced,
            for: key,
            lane: lane,
            target: sequence,
            previousAcceptedHighWater: previousAcceptedSequence
        )
        return true
    }

    @discardableResult
    func drain(
        _ requirement: DrainRequirement,
        for key: ContextKey,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation? = EditFlowPerf.currentLifecycleCorrelation,
        onCanonicalWaiterRegistered: (() -> Void)? = nil
    ) async -> DrainResult {
        guard !Task.isCancelled else { return .cancelled }
        let target = canonicalLanes[key]?.acceptedSequence ?? 0
        guard target > 0 else { return .completed }
        emitCanonicalDiagnostic(
            .drainHighWaterCaptured,
            for: key,
            target: target
        )
        let drainState = EditFlowPerf.begin(
            EditFlowPerf.Stage.ReadFile.AutoSelect.drainWait,
            EditFlowPerf.Dimensions(status: requirement.rawValue)
        )
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.ReadFileAutoSelect.drainBegan,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(status: requirement.rawValue)
        )
        var outcome = "completed"
        defer {
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFileAutoSelect.drainEnded,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(status: requirement.rawValue, outcome: outcome)
            )
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.AutoSelect.drainWait,
                drainState,
                EditFlowPerf.Dimensions(status: requirement.rawValue, outcome: outcome)
            )
        }

        let canonicalResult = await waitForCanonicalSequence(
            target,
            for: key,
            onWaiterRegistered: onCanonicalWaiterRegistered
        )
        guard case let .completed(mirrorTicket) = canonicalResult, !Task.isCancelled else {
            outcome = "cancelled"
            return .cancelled
        }
        if requirement == .mirroredSelectionAndMetrics,
           let mirrorTicket
        {
            emitMirrorDiagnostic(
                .drainHighWaterCaptured,
                for: key.mirrorKey,
                target: mirrorTicket
            )
            guard case .completed = await waitForMirrorTicket(mirrorTicket, for: key.mirrorKey),
                  !Task.isCancelled
            else {
                outcome = "cancelled"
                return .cancelled
            }
        }
        return .completed
    }

    func finish(
        context key: ContextKey,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation? = EditFlowPerf.currentLifecycleCorrelation
    ) async -> DrainResult {
        closingContexts.insert(key)
        let result = await drain(.mirroredSelectionAndMetrics, for: key, lifecycleCorrelation: lifecycleCorrelation)
        retiringContexts.insert(key)
        cleanupRetiredContextIfSettled(key)
        return result
    }

    func invalidate(context key: ContextKey) {
        closingContexts.insert(key)
        invalidatedContexts.insert(key)
        if canonicalLanes[key]?.pending != nil {
            scheduleCanonicalWorkerIfNeeded(for: key)
        }
        cleanupRetiredContextIfSettled(key)
    }

    #if DEBUG
        func setCanonicalApplyGateForTesting(_ gate: (() async -> Void)?) {
            canonicalApplyGateForTesting = gate
        }

        func debugContextSnapshot(for key: ContextKey) -> DebugContextSnapshot? {
            guard let lane = canonicalLanes[key] else { return nil }
            let accounting = debugAccountingByContext[key] ?? DebugContextAccounting()
            return DebugContextSnapshot(
                acceptedHighWaterSequence: lane.acceptedSequence,
                completedHighWaterSequence: lane.completedSequence,
                acceptedIntentCount: accounting.acceptedIntentCount,
                completedIntentCount: accounting.completedIntentCount,
                canonicalApplyAttemptCount: accounting.canonicalApplyAttemptCount,
                changedApplyCount: accounting.changedApplyCount,
                semanticNoOpApplyCount: accounting.semanticNoOpApplyCount,
                rejectedApplyCount: accounting.rejectedApplyCount,
                changedIntentCount: accounting.changedIntentCount,
                semanticNoOpIntentCount: accounting.semanticNoOpIntentCount,
                rejectedIntentCount: accounting.rejectedIntentCount,
                invalidatedIntentCount: accounting.invalidatedIntentCount,
                coverageCertificateHitCount: accounting.coverageCertificateHitCount,
                authoritativeFallbackCount: accounting.authoritativeFallbackCount,
                coverageCertificateMissReasonCounts: accounting.coverageCertificateMissReasonCounts,
                mutationTotalMilliseconds: accounting.mutationTotalMilliseconds,
                mutationSamples: accounting.mutationSamples,
                sampleOverflowCount: accounting.sampleOverflowCount,
                workerActive: canonicalWorkers.contains(key),
                pendingWork: lane.pending != nil,
                waiterCount: lane.waiters.count
            )
        }

        func debugDrainCanonical(for key: ContextKey) async -> DebugDrainResult {
            let target = canonicalLanes[key]?.acceptedSequence ?? 0
            let result = await drain(.canonicalSelection, for: key)
            return DebugDrainResult(result: result, capturedTargetSequence: target)
        }

        func debugSnapshot() -> DebugSnapshot {
            DebugSnapshot(
                canonicalLaneCount: canonicalLanes.count,
                canonicalWorkerCount: canonicalWorkers.count,
                mirrorLaneCount: mirrorLanes.count,
                mirrorWorkerCount: mirrorWorkers.count,
                closingContextCount: closingContexts.union(retiringContexts).count,
                pendingCanonicalBatchCount: canonicalLanes.values.count(where: { $0.pending != nil }),
                pendingMirrorBatchCount: mirrorLanes.values.count(where: { $0.pending != nil }),
                canonicalWaiterCount: canonicalLanes.values.reduce(0) { $0 + $1.waiters.count },
                mirrorWaiterCount: mirrorLanes.values.reduce(0) { $0 + $1.waiters.count }
            )
        }
    #endif

    private func scheduleCanonicalWorkerIfNeeded(for key: ContextKey) {
        guard canonicalWorkers.insert(key).inserted else { return }
        let workerID = UUID()
        canonicalWorkerIDs[key] = workerID
        emitCanonicalDiagnostic(
            .workerStarted,
            for: key,
            workerID: workerID
        )
        Task { @MainActor [weak self] in
            await self?.runCanonicalWorker(for: key, workerID: workerID)
        }
    }

    private func runCanonicalWorker(for key: ContextKey, workerID: UUID) async {
        defer {
            canonicalWorkers.remove(key)
            canonicalWorkerIDs.removeValue(forKey: key)
            emitCanonicalDiagnostic(
                .workerStopped,
                for: key,
                workerID: workerID
            )
            cleanupRetiredContextIfSettled(key)
        }
        while var lane = canonicalLanes[key], let queued = lane.pending {
            lane.pending = nil
            canonicalLanes[key] = lane
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.AutoSelect.canonicalQueueWait,
                queued.queueWaitState,
                EditFlowPerf.Dimensions(status: key.route.diagnosticScope, outcome: "started")
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFileAutoSelect.canonicalApplyBegan,
                correlation: queued.lifecycleCorrelation,
                EditFlowPerf.Dimensions(status: key.route.diagnosticScope)
            )

            var outcome = "invalidated"
            var mirrorTicket: UInt64?
            #if DEBUG
                var debugApplyOutcome: DebugCanonicalApplyOutcome?
                var debugMutationDurationMilliseconds: Double?
                var debugCoverageCertificateOutcome: CoverageCertificateOutcome?
            #endif
            if !invalidatedContexts.contains(key), isContextCurrent(key) {
                #if DEBUG
                    if let canonicalApplyGateForTesting {
                        await canonicalApplyGateForTesting()
                    }
                #endif
                // The debug gate models any suspension before mutation. Revalidate identity
                // afterward so an invalidated or replaced route can never apply stale work.
                if !invalidatedContexts.contains(key), isContextCurrent(key) {
                    #if DEBUG
                        let debugMutationClock = ContinuousClock()
                        let debugMutationStartedAt = debugMutationClock.now
                    #endif
                    let result = await EditFlowPerf.$currentLifecycleCorrelation.withValue(queued.lifecycleCorrelation) {
                        await EditFlowPerf.measure(
                            EditFlowPerf.Stage.ReadFile.AutoSelect.canonicalMutation,
                            EditFlowPerf.Dimensions(status: key.route.diagnosticScope)
                        ) {
                            await applyCanonical(key, queued.batch)
                        }
                    }
                    #if DEBUG
                        debugMutationDurationMilliseconds = Self.debugMilliseconds(
                            debugMutationStartedAt.duration(to: debugMutationClock.now)
                        )
                        debugCoverageCertificateOutcome = result.coverageCertificateOutcome
                    #endif
                    if !invalidatedContexts.contains(key), isContextCurrent(key) {
                        switch result.disposition {
                        case .changed:
                            if let mirrorKey = result.mirrorKey {
                                mirrorTicket = enqueueMirror(
                                    for: mirrorKey,
                                    lifecycleCorrelation: queued.lifecycleCorrelation
                                )
                                outcome = "changed"
                                #if DEBUG
                                    debugApplyOutcome = .changed
                                #endif
                            } else {
                                outcome = "rejected"
                                #if DEBUG
                                    debugApplyOutcome = .rejected
                                #endif
                            }
                        case .semanticNoOp:
                            outcome = "unchanged"
                            #if DEBUG
                                debugApplyOutcome = .semanticNoOp
                            #endif
                        case .rejected:
                            outcome = "rejected"
                            #if DEBUG
                                debugApplyOutcome = .rejected
                            #endif
                        }
                    } else {
                        #if DEBUG
                            debugApplyOutcome = .invalidated
                        #endif
                    }
                }
            }
            #if DEBUG
                if let debugApplyOutcome, let debugMutationDurationMilliseconds {
                    recordDebugCanonicalApply(
                        for: key,
                        outcome: debugApplyOutcome,
                        acceptedIntentCount: queued.acceptedIntentCount,
                        durationMilliseconds: debugMutationDurationMilliseconds,
                        completedHighWaterSequence: queued.highestSequence,
                        coverageCertificateOutcome: debugCoverageCertificateOutcome
                    )
                } else {
                    debugAccountingByContext[key, default: DebugContextAccounting()].invalidatedIntentCount &+= queued.acceptedIntentCount
                }
            #endif
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFileAutoSelect.canonicalApplyEnded,
                correlation: queued.lifecycleCorrelation,
                EditFlowPerf.Dimensions(status: key.route.diagnosticScope, outcome: outcome)
            )
            completeCanonicalBatch(
                for: key,
                throughSequence: queued.highestSequence,
                acceptedIntentCount: queued.acceptedIntentCount,
                mirrorTicket: mirrorTicket
            )
            await Task.yield()
        }
    }

    private func completeCanonicalBatch(
        for key: ContextKey,
        throughSequence: UInt64,
        acceptedIntentCount: UInt64,
        mirrorTicket: UInt64?
    ) {
        guard var lane = canonicalLanes[key] else { return }
        lane.completedSequence = max(lane.completedSequence, throughSequence)
        #if DEBUG
            debugAccountingByContext[key, default: DebugContextAccounting()].completedIntentCount &+= acceptedIntentCount
        #endif
        if let mirrorTicket {
            lane.latestRequiredMirrorTicket = max(lane.latestRequiredMirrorTicket ?? 0, mirrorTicket)
        }
        let satisfied = lane.waiters.filter { $0.value.target <= lane.completedSequence }
        for (id, _) in satisfied {
            lane.waiters.removeValue(forKey: id)
        }
        canonicalLanes[key] = lane
        for (id, waiter) in satisfied {
            emitCanonicalDiagnostic(
                .waiterResumed,
                for: key,
                lane: lane,
                target: waiter.target,
                waiterID: id
            )
            waiter.continuation.resume(returning: .completed(requiredMirrorTicket: lane.latestRequiredMirrorTicket))
        }
    }

    #if DEBUG
        private func recordDebugCanonicalApply(
            for key: ContextKey,
            outcome: DebugCanonicalApplyOutcome,
            acceptedIntentCount: UInt64,
            durationMilliseconds: Double,
            completedHighWaterSequence: UInt64,
            coverageCertificateOutcome: CoverageCertificateOutcome?
        ) {
            var accounting = debugAccountingByContext[key] ?? DebugContextAccounting()
            accounting.canonicalApplyAttemptCount &+= 1
            switch outcome {
            case .changed:
                accounting.changedApplyCount &+= 1
                accounting.changedIntentCount &+= acceptedIntentCount
            case .semanticNoOp:
                accounting.semanticNoOpApplyCount &+= 1
                accounting.semanticNoOpIntentCount &+= acceptedIntentCount
            case .rejected:
                accounting.rejectedApplyCount &+= 1
                accounting.rejectedIntentCount &+= acceptedIntentCount
            case .invalidated:
                accounting.rejectedApplyCount &+= 1
                accounting.invalidatedIntentCount &+= acceptedIntentCount
            }
            switch coverageCertificateOutcome {
            case .hit:
                accounting.coverageCertificateHitCount &+= 1
            case let .authoritativeFallback(reason):
                accounting.authoritativeFallbackCount &+= 1
                accounting.coverageCertificateMissReasonCounts[reason, default: 0] &+= 1
            case nil:
                break
            }
            accounting.mutationTotalMilliseconds += durationMilliseconds
            accounting.nextSampleOrdinal &+= 1
            let sample = DebugCanonicalApplySample(
                ordinal: accounting.nextSampleOrdinal,
                durationMilliseconds: durationMilliseconds,
                outcome: outcome,
                acceptedIntentCount: acceptedIntentCount,
                completedHighWaterSequence: completedHighWaterSequence,
                coverageCertificateOutcome: coverageCertificateOutcome
            )
            if accounting.mutationSamples.count == Self.debugMutationSampleLimit {
                accounting.mutationSamples.removeFirst()
                accounting.sampleOverflowCount &+= 1
            }
            accounting.mutationSamples.append(sample)
            debugAccountingByContext[key] = accounting
        }

        private nonisolated static func debugMilliseconds(_ duration: Duration) -> Double {
            let components = duration.components
            return Double(components.seconds) * 1000
                + Double(components.attoseconds) / 1_000_000_000_000_000
        }
    #endif

    @discardableResult
    private func enqueueMirror(
        for key: TabMirrorKey,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
    ) -> UInt64 {
        let enqueueState = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.mirrorEnqueue)
        defer { EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.mirrorEnqueue, enqueueState) }
        var lane = mirrorLanes[key] ?? MirrorLane()
        let previousAcceptedTicket = lane.acceptedTicket
        lane.acceptedTicket &+= 1
        let ticket = lane.acceptedTicket
        if var pending = lane.pending {
            pending.highestTicket = ticket
            pending.lifecycleCorrelation = lifecycleCorrelation ?? pending.lifecycleCorrelation
            lane.pending = pending
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFileAutoSelect.mirrorCoalesced,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(queueDepth: 1)
            )
        } else {
            lane.pending = QueuedMirrorBatch(
                highestTicket: ticket,
                lifecycleCorrelation: lifecycleCorrelation,
                queueWaitState: EditFlowPerf.begin(
                    EditFlowPerf.Stage.ReadFile.AutoSelect.mirrorQueueWait,
                    EditFlowPerf.Dimensions(queueDepth: 1)
                )
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFileAutoSelect.mirrorScheduled,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(queueDepth: 1)
            )
        }
        mirrorLanes[key] = lane
        scheduleMirrorWorkerIfNeeded(for: key)
        emitMirrorDiagnostic(
            .acceptedHighWaterAdvanced,
            for: key,
            lane: lane,
            target: ticket,
            previousAcceptedHighWater: previousAcceptedTicket
        )
        return ticket
    }

    private func scheduleMirrorWorkerIfNeeded(for key: TabMirrorKey) {
        guard mirrorWorkers.insert(key).inserted else { return }
        let workerID = UUID()
        mirrorWorkerIDs[key] = workerID
        emitMirrorDiagnostic(
            .workerStarted,
            for: key,
            workerID: workerID
        )
        Task { @MainActor [weak self] in
            await self?.runMirrorWorker(for: key, workerID: workerID)
        }
    }

    private func runMirrorWorker(for key: TabMirrorKey, workerID: UUID) async {
        defer {
            mirrorWorkers.remove(key)
            mirrorWorkerIDs.removeValue(forKey: key)
            emitMirrorDiagnostic(
                .workerStopped,
                for: key,
                workerID: workerID
            )
            cleanupMirrorLaneIfSettled(key)
        }
        while var lane = mirrorLanes[key], let queued = lane.pending {
            lane.pending = nil
            mirrorLanes[key] = lane
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.AutoSelect.mirrorQueueWait,
                queued.queueWaitState,
                EditFlowPerf.Dimensions(outcome: "started")
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFileAutoSelect.mirrorApplyBegan,
                correlation: queued.lifecycleCorrelation
            )
            await EditFlowPerf.$currentLifecycleCorrelation.withValue(queued.lifecycleCorrelation) {
                await EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.AutoSelect.mirrorApply) {
                    await applyMirror(key)
                }
            }
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFileAutoSelect.mirrorApplyEnded,
                correlation: queued.lifecycleCorrelation
            )
            completeMirrorBatch(for: key, throughTicket: queued.highestTicket)
            await Task.yield()
        }
    }

    private func completeMirrorBatch(for key: TabMirrorKey, throughTicket: UInt64) {
        guard var lane = mirrorLanes[key] else { return }
        lane.completedTicket = max(lane.completedTicket, throughTicket)
        let satisfied = lane.waiters.filter { $0.value.target <= lane.completedTicket }
        for (id, _) in satisfied {
            lane.waiters.removeValue(forKey: id)
        }
        mirrorLanes[key] = lane
        for (id, waiter) in satisfied {
            emitMirrorDiagnostic(
                .waiterResumed,
                for: key,
                lane: lane,
                target: waiter.target,
                waiterID: id
            )
            waiter.continuation.resume(returning: .completed)
        }
    }

    private func waitForCanonicalSequence(
        _ target: UInt64,
        for key: ContextKey,
        onWaiterRegistered: (() -> Void)?
    ) async -> CanonicalWaitResult {
        if Task.isCancelled {
            return .cancelled
        }
        if let lane = canonicalLanes[key], lane.completedSequence >= target {
            return .completed(requiredMirrorTicket: lane.latestRequiredMirrorTicket)
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var lane = canonicalLanes[key] ?? CanonicalLane()
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                } else if lane.completedSequence >= target {
                    continuation.resume(returning: .completed(requiredMirrorTicket: lane.latestRequiredMirrorTicket))
                } else {
                    lane.waiters[waiterID] = CanonicalSequenceWaiter(target: target, continuation: continuation)
                    canonicalLanes[key] = lane
                    emitCanonicalDiagnostic(
                        .waiterRegistered,
                        for: key,
                        lane: lane,
                        target: target,
                        waiterID: waiterID
                    )
                    onWaiterRegistered?()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelCanonicalWaiter(waiterID, for: key)
            }
        }
    }

    private func waitForMirrorTicket(_ target: UInt64, for key: TabMirrorKey) async -> SequenceWaitResult {
        if Task.isCancelled {
            return .cancelled
        }
        guard (mirrorLanes[key]?.completedTicket ?? 0) < target else { return .completed }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var lane = mirrorLanes[key] ?? MirrorLane()
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                } else if lane.completedTicket >= target {
                    continuation.resume(returning: .completed)
                } else {
                    lane.waiters[waiterID] = SequenceWaiter(target: target, continuation: continuation)
                    mirrorLanes[key] = lane
                    emitMirrorDiagnostic(
                        .waiterRegistered,
                        for: key,
                        lane: lane,
                        target: target,
                        waiterID: waiterID
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelMirrorWaiter(waiterID, for: key)
            }
        }
    }

    private func cancelCanonicalWaiter(_ waiterID: UUID, for key: ContextKey) {
        guard var lane = canonicalLanes[key],
              let waiter = lane.waiters.removeValue(forKey: waiterID)
        else { return }
        canonicalLanes[key] = lane
        emitCanonicalDiagnostic(
            .waiterResumed,
            for: key,
            lane: lane,
            target: waiter.target,
            waiterID: waiterID
        )
        waiter.continuation.resume(returning: .cancelled)
        cleanupRetiredContextIfSettled(key)
    }

    private func cancelMirrorWaiter(_ waiterID: UUID, for key: TabMirrorKey) {
        guard var lane = mirrorLanes[key],
              let waiter = lane.waiters.removeValue(forKey: waiterID)
        else { return }
        mirrorLanes[key] = lane
        emitMirrorDiagnostic(
            .waiterResumed,
            for: key,
            lane: lane,
            target: waiter.target,
            waiterID: waiterID
        )
        waiter.continuation.resume(returning: .cancelled)
        cleanupMirrorLaneIfSettled(key)
    }

    private func emitCanonicalDiagnostic(
        _ kind: MCPReadFileAutoSelectionDiagnosticEvent.Kind,
        for key: ContextKey,
        lane: CanonicalLane? = nil,
        target: UInt64? = nil,
        previousAcceptedHighWater: UInt64? = nil,
        waiterID: UUID? = nil,
        workerID: UUID? = nil
    ) {
        let lane = lane ?? canonicalLanes[key] ?? CanonicalLane()
        MCPReadFileAutoSelectionDiagnosticTracer.emit(MCPReadFileAutoSelectionDiagnosticEvent(
            kind: kind,
            lane: .canonical,
            windowID: key.windowID,
            workspaceID: key.workspaceID,
            tabID: key.tabID,
            routeScope: key.route.diagnosticScope,
            bindingGeneration: key.bindingGeneration,
            target: target,
            previousAcceptedHighWater: previousAcceptedHighWater,
            acceptedHighWater: lane.acceptedSequence,
            completedHighWater: lane.completedSequence,
            waiterCount: lane.waiters.count,
            workerActive: canonicalWorkers.contains(key),
            pendingWork: lane.pending != nil,
            waiterID: waiterID,
            workerID: workerID ?? canonicalWorkerIDs[key],
            requiredMirrorTicket: lane.latestRequiredMirrorTicket
        ))
    }

    private func emitMirrorDiagnostic(
        _ kind: MCPReadFileAutoSelectionDiagnosticEvent.Kind,
        for key: TabMirrorKey,
        lane: MirrorLane? = nil,
        target: UInt64? = nil,
        previousAcceptedHighWater: UInt64? = nil,
        waiterID: UUID? = nil,
        workerID: UUID? = nil
    ) {
        let lane = lane ?? mirrorLanes[key] ?? MirrorLane()
        MCPReadFileAutoSelectionDiagnosticTracer.emit(MCPReadFileAutoSelectionDiagnosticEvent(
            kind: kind,
            lane: .mirror,
            windowID: key.windowID,
            workspaceID: key.workspaceID,
            tabID: key.tabID,
            routeScope: nil,
            bindingGeneration: nil,
            target: target,
            previousAcceptedHighWater: previousAcceptedHighWater,
            acceptedHighWater: lane.acceptedTicket,
            completedHighWater: lane.completedTicket,
            waiterCount: lane.waiters.count,
            workerActive: mirrorWorkers.contains(key),
            pendingWork: lane.pending != nil,
            waiterID: waiterID,
            workerID: workerID ?? mirrorWorkerIDs[key],
            requiredMirrorTicket: nil
        ))
    }

    private func cleanupRetiredContextIfSettled(_ key: ContextKey) {
        guard invalidatedContexts.contains(key) || retiringContexts.contains(key),
              !canonicalWorkers.contains(key),
              canonicalLanes[key]?.pending == nil,
              canonicalLanes[key]?.waiters.isEmpty != false
        else { return }
        canonicalLanes.removeValue(forKey: key)
        #if DEBUG
            debugAccountingByContext.removeValue(forKey: key)
        #endif
        closingContexts.remove(key)
        invalidatedContexts.remove(key)
        retiringContexts.remove(key)
        cleanupMirrorLaneIfSettled(key.mirrorKey)
    }

    private func cleanupMirrorLaneIfSettled(_ key: TabMirrorKey) {
        guard !mirrorWorkers.contains(key),
              mirrorLanes[key]?.pending == nil,
              mirrorLanes[key]?.waiters.isEmpty != false,
              !canonicalLanes.keys.contains(where: { $0.mirrorKey == key })
        else { return }
        mirrorLanes.removeValue(forKey: key)
    }
}
