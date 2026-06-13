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

    enum Intent: Equatable {
        case full(paths: [String])
        case slices(entries: [WorkspaceSelectionSliceInput])
    }

    struct CanonicalBatch: Equatable {
        private(set) var fullPaths: [String] = []
        private(set) var sliceEntries: [WorkspaceSelectionSliceInput] = []

        private var fullPathKeys = Set<String>()
        private var slicePathOrder: [String] = []
        private var sliceRangesByPath: [String: [LineRange]] = [:]
        private var originalSlicePathByKey: [String: String] = [:]

        init(intent: Intent) {
            merge(intent)
        }

        mutating func merge(_ intent: Intent) {
            switch intent {
            case let .full(paths):
                for rawPath in paths {
                    guard let path = Self.trimmed(rawPath),
                          let key = StoredSelectionPathNormalization.standardizedPath(path)
                    else { continue }
                    if fullPathKeys.insert(key).inserted {
                        fullPaths.append(path)
                    }
                    sliceRangesByPath.removeValue(forKey: key)
                    originalSlicePathByKey.removeValue(forKey: key)
                }
            case let .slices(entries):
                for entry in entries {
                    guard let path = Self.trimmed(entry.path),
                          let key = StoredSelectionPathNormalization.standardizedPath(path),
                          !fullPathKeys.contains(key)
                    else { continue }
                    if originalSlicePathByKey[key] == nil {
                        slicePathOrder.append(key)
                        originalSlicePathByKey[key] = path
                    }
                    sliceRangesByPath[key, default: []].append(contentsOf: entry.ranges)
                }
            }
            rebuildSliceEntries()
        }

        private mutating func rebuildSliceEntries() {
            sliceEntries = slicePathOrder.compactMap { key in
                guard !fullPathKeys.contains(key),
                      let path = originalSlicePathByKey[key]
                else { return nil }
                let ranges = SliceRangeMath.normalize(sliceRangesByPath[key] ?? [])
                guard !ranges.isEmpty else { return nil }
                return WorkspaceSelectionSliceInput(path: path, ranges: ranges)
            }
        }

        private static func trimmed(_ rawPath: String) -> String? {
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        }
    }

    struct CanonicalApplyResult {
        let mirrorKey: TabMirrorKey?

        static let unchanged = CanonicalApplyResult(mirrorKey: nil)
    }

    #if DEBUG
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
        private var canonicalApplyGateForTesting: (() async -> Void)?
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
            pending.batch.merge(intent)
            pending.highestSequence = sequence
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
                batch: CanonicalBatch(intent: intent),
                lowestSequence: sequence,
                highestSequence: sequence,
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
            if !invalidatedContexts.contains(key), isContextCurrent(key) {
                #if DEBUG
                    if let canonicalApplyGateForTesting {
                        await canonicalApplyGateForTesting()
                    }
                #endif
                // The debug gate models any suspension before mutation. Revalidate identity
                // afterward so an invalidated or replaced route can never apply stale work.
                if !invalidatedContexts.contains(key), isContextCurrent(key) {
                    let result = await EditFlowPerf.$currentLifecycleCorrelation.withValue(queued.lifecycleCorrelation) {
                        await EditFlowPerf.measure(
                            EditFlowPerf.Stage.ReadFile.AutoSelect.canonicalMutation,
                            EditFlowPerf.Dimensions(status: key.route.diagnosticScope)
                        ) {
                            await applyCanonical(key, queued.batch)
                        }
                    }
                    if !invalidatedContexts.contains(key), isContextCurrent(key), let mirrorKey = result.mirrorKey {
                        mirrorTicket = enqueueMirror(
                            for: mirrorKey,
                            lifecycleCorrelation: queued.lifecycleCorrelation
                        )
                        outcome = "changed"
                    } else if !invalidatedContexts.contains(key), isContextCurrent(key) {
                        outcome = "unchanged"
                    }
                }
            }
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFileAutoSelect.canonicalApplyEnded,
                correlation: queued.lifecycleCorrelation,
                EditFlowPerf.Dimensions(status: key.route.diagnosticScope, outcome: outcome)
            )
            completeCanonicalBatch(
                for: key,
                throughSequence: queued.highestSequence,
                mirrorTicket: mirrorTicket
            )
            await Task.yield()
        }
    }

    private func completeCanonicalBatch(for key: ContextKey, throughSequence: UInt64, mirrorTicket: UInt64?) {
        guard var lane = canonicalLanes[key] else { return }
        lane.completedSequence = max(lane.completedSequence, throughSequence)
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
        closingContexts.remove(key)
        invalidatedContexts.remove(key)
        retiringContexts.remove(key)
    }
}
