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
        case deferred
        case invalidated
        case cancelled
    }

    enum Route: Hashable {
        case bound(connectionID: UUID, runID: UUID?)

        var diagnosticScope: String {
            "bound"
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

    enum AutomaticCodemapDisposition: Hashable {
        case preserve
        case disableAutomaticPreservingManual

        func merging(_ other: AutomaticCodemapDisposition) -> AutomaticCodemapDisposition {
            if self == .disableAutomaticPreservingManual || other == .disableAutomaticPreservingManual {
                return .disableAutomaticPreservingManual
            }
            return .preserve
        }
    }

    enum Intent: Equatable {
        case full(
            paths: [String],
            automaticCodemapDisposition: AutomaticCodemapDisposition = .preserve
        )
        case slices(
            entries: [WorkspaceSelectionSliceInput],
            automaticCodemapDisposition: AutomaticCodemapDisposition = .preserve
        )

        var automaticCodemapDisposition: AutomaticCodemapDisposition {
            switch self {
            case let .full(_, disposition), let .slices(_, disposition): disposition
            }
        }
    }

    /// Exact normalized physical coverage requested by one complete canonical batch.
    /// Logical/display paths remain in `Intent`; this identity is carried separately so
    /// equivalent ordering/coalescing compares equal without ever projecting the fast path.
    struct CoverageIdentity: Hashable {
        struct Slice: Hashable {
            let path: String
            let ranges: [LineRange]
        }

        let fullPaths: [String]
        let slices: [Slice]
        let automaticCodemapDisposition: AutomaticCodemapDisposition

        init?(intent: Intent, resolvedPaths: [String]) {
            var fullPathKeys = Set<String>()
            var rangesByPath: [String: [LineRange]] = [:]

            switch intent {
            case let .full(paths, _):
                guard paths.count == resolvedPaths.count else { return nil }
                for resolvedPath in resolvedPaths {
                    guard let path = Self.normalizedPhysicalPath(resolvedPath) else { return nil }
                    fullPathKeys.insert(path)
                }
            case let .slices(entries, _):
                guard entries.count == resolvedPaths.count else { return nil }
                for (entry, resolvedPath) in zip(entries, resolvedPaths) {
                    guard let path = Self.normalizedPhysicalPath(resolvedPath) else { return nil }
                    let ranges = SliceRangeMath.normalize(entry.ranges).map {
                        LineRange(start: $0.start, end: $0.end)
                    }
                    guard !ranges.isEmpty else { return nil }
                    rangesByPath[path, default: []].append(contentsOf: ranges)
                }
            }

            self.init(
                fullPathKeys: fullPathKeys,
                rangesByPath: rangesByPath,
                automaticCodemapDisposition: intent.automaticCodemapDisposition
            )
        }

        private init(
            fullPathKeys: Set<String>,
            rangesByPath: [String: [LineRange]],
            automaticCodemapDisposition: AutomaticCodemapDisposition
        ) {
            fullPaths = fullPathKeys.sorted()
            slices = rangesByPath.keys
                .filter { !fullPathKeys.contains($0) }
                .sorted()
                .compactMap { path in
                    let ranges = SliceRangeMath.normalize(rangesByPath[path] ?? []).map {
                        LineRange(start: $0.start, end: $0.end)
                    }
                    return ranges.isEmpty ? nil : Slice(path: path, ranges: ranges)
                }
            self.automaticCodemapDisposition = automaticCodemapDisposition
        }

        func merging(_ other: CoverageIdentity) -> CoverageIdentity {
            var fullPathKeys = Set(fullPaths)
            fullPathKeys.formUnion(other.fullPaths)
            var rangesByPath = Dictionary(uniqueKeysWithValues: slices.map { ($0.path, $0.ranges) })
            for slice in other.slices {
                rangesByPath[slice.path, default: []].append(contentsOf: slice.ranges)
            }
            return CoverageIdentity(
                fullPathKeys: fullPathKeys,
                rangesByPath: rangesByPath,
                automaticCodemapDisposition: automaticCodemapDisposition.merging(other.automaticCodemapDisposition)
            )
        }

        func isCovered(by physicalSelection: StoredSelection) -> Bool {
            if automaticCodemapDisposition == .disableAutomaticPreservingManual,
               physicalSelection.codemapAutoEnabled
            {
                return false
            }
            let selectedPathKeys = Set(StoredSelectionPathNormalization.standardizedPaths(physicalSelection.selectedPaths))
            let normalizedSlices = StoredSelectionPathNormalization.standardizedSlices(physicalSelection.slices)

            for path in fullPaths {
                guard selectedPathKeys.contains(path), normalizedSlices[path]?.isEmpty != false else { return false }
            }
            for slice in slices {
                guard selectedPathKeys.contains(slice.path) else { return false }
                guard normalizedSlices[slice.path]?.isEmpty != false || Self.ranges(slice.ranges, areCoveredBy: normalizedSlices[slice.path] ?? []) else {
                    return false
                }
            }
            return true
        }

        private static func ranges(_ requested: [LineRange], areCoveredBy selected: [LineRange]) -> Bool {
            let selected = SliceRangeMath.normalize(selected)
            return requested.allSatisfy { request in
                selected.contains { $0.start <= request.start && $0.end >= request.end }
            }
        }

        private static func normalizedPhysicalPath(_ rawPath: String) -> String? {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("/") else { return nil }
            return StandardizedPath.absolute((trimmed as NSString).expandingTildeInPath)
        }
    }

    static func authoritativeReadSelection(
        _ expected: StoredSelection,
        isPreservedBy candidate: StoredSelection
    ) -> Bool {
        let expectedWithoutAutomaticCodemaps = StoredSelection(
            selectedPaths: expected.selectedPaths,
            manualCodemapPaths: expected.manualCodemapPaths,
            slices: expected.slices,
            codemapAutoEnabled: false
        )
        return authoritativeSelection(expectedWithoutAutomaticCodemaps, isPreservedBy: candidate)
    }

    static func authoritativeSelection(
        _ expected: StoredSelection,
        isPreservedBy candidate: StoredSelection,
        automaticCodemapDisposition: AutomaticCodemapDisposition
    ) -> Bool {
        switch automaticCodemapDisposition {
        case .preserve:
            authoritativeSelection(expected, isPreservedBy: candidate)
        case .disableAutomaticPreservingManual:
            authoritativeReadSelection(expected, isPreservedBy: candidate)
        }
    }

    static func authoritativeSelection(
        _ expected: StoredSelection,
        isPreservedBy candidate: StoredSelection
    ) -> Bool {
        let expectedSelectedPaths = Set(StoredSelectionPathNormalization.standardizedPaths(expected.selectedPaths))
        let candidateSelectedPaths = Set(StoredSelectionPathNormalization.standardizedPaths(candidate.selectedPaths))
        guard expectedSelectedPaths.isSubset(of: candidateSelectedPaths) else { return false }
        let expectedManualCodemapPaths = Set(
            StoredSelectionPathNormalization.standardizedPaths(expected.manualCodemapPaths)
        )
        let candidateManualCodemapPaths = Set(
            StoredSelectionPathNormalization.standardizedPaths(candidate.manualCodemapPaths)
        )
        guard expectedManualCodemapPaths.isSubset(
            of: candidateManualCodemapPaths.union(candidateSelectedPaths)
        ) else { return false }

        guard expected.codemapAutoEnabled == candidate.codemapAutoEnabled else { return false }

        let expectedSlices = StoredSelectionPathNormalization.standardizedSlices(expected.slices).mapValues {
            SliceRangeMath.normalize($0)
        }
        let candidateSlices = StoredSelectionPathNormalization.standardizedSlices(candidate.slices).mapValues {
            SliceRangeMath.normalize($0)
        }

        for path in expectedSelectedPaths {
            let expectedRanges = expectedSlices[path] ?? []
            let candidateRanges = candidateSlices[path] ?? []
            if expectedRanges.isEmpty {
                guard candidateRanges.isEmpty else { return false }
            } else if !candidateRanges.isEmpty {
                guard ranges(expectedRanges, areCoveredBy: candidateRanges) else { return false }
            }
        }

        for (path, expectedRanges) in expectedSlices where !expectedRanges.isEmpty {
            guard candidateSelectedPaths.contains(path) else { return false }
            let candidateRanges = candidateSlices[path] ?? []
            if !candidateRanges.isEmpty,
               !ranges(expectedRanges, areCoveredBy: candidateRanges)
            {
                return false
            }
        }
        return true
    }

    private static func ranges(_ expected: [LineRange], areCoveredBy candidate: [LineRange]) -> Bool {
        let candidate = SliceRangeMath.normalize(candidate)
        return SliceRangeMath.normalize(expected).allSatisfy { expectedRange in
            candidate.contains { $0.start <= expectedRange.start && $0.end >= expectedRange.end }
        }
    }

    enum CoverageCertificateOutcome: Equatable {
        case hit
        case authoritativeFallback(ReadFileAutoSelectionCoverageCertificateMissReason)
    }

    struct CanonicalBatch: Equatable {
        private(set) var fullPaths: [String] = []
        private(set) var sliceEntries: [WorkspaceSelectionSliceInput] = []
        private(set) var coverageIdentity: CoverageIdentity?
        private(set) var automaticCodemapDisposition: AutomaticCodemapDisposition = .preserve

        private var fullPathKeys = Set<String>()
        private var slicePathOrder: [String] = []
        private var sliceRangesByPath: [String: [LineRange]] = [:]
        private var originalSlicePathByKey: [String: String] = [:]
        private var coveragePermitted: Bool

        init(intent: Intent, coverageIdentity: CoverageIdentity? = nil) {
            self.coverageIdentity = nil
            coveragePermitted = coverageIdentity != nil
            merge(intent, coverageIdentity: coverageIdentity)
        }

        mutating func merge(_ intent: Intent, coverageIdentity incomingCoverageIdentity: CoverageIdentity? = nil) {
            automaticCodemapDisposition = automaticCodemapDisposition.merging(intent.automaticCodemapDisposition)
            if coveragePermitted {
                if let incomingCoverageIdentity {
                    coverageIdentity = coverageIdentity?.merging(incomingCoverageIdentity) ?? incomingCoverageIdentity
                } else {
                    coveragePermitted = false
                    coverageIdentity = nil
                }
            }
            switch intent {
            case let .full(paths, _):
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
            case let .slices(entries, _):
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
            let inFlightMirrorBatchCount: Int
            let retiredMirrorWorkerCount: Int
            let liveMirrorDeadlineCount: Int
            let mirrorSettlementRangeCount: Int
        }
    #endif

    typealias IsContextCurrent = @MainActor (ContextKey) -> Bool
    typealias ApplyCanonical = @MainActor (ContextKey, CanonicalBatch) async -> CanonicalApplyResult
    typealias ApplyMirror = @MainActor (TabMirrorKey) async -> WorkspaceSelectionCoordinator.SelectionMirrorOutcome

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
        case invalidated
        case cancelled
    }

    private enum SequenceWaitResult: Equatable {
        case converged
        case deferred
        case invalidated
        case cancelled
    }

    private struct CanonicalSequenceWaiter {
        let target: UInt64
        let continuation: CheckedContinuation<CanonicalWaitResult, Never>
    }

    private struct SequenceWaiter {
        let contextKey: ContextKey
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
        var owners: Set<ContextKey>
        var lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
        let queueWaitState: EditFlowPerf.IntervalState?
    }

    private struct MirrorLane {
        var acceptedTicket: UInt64 = 0
        var completedTicket: UInt64 = 0
        var convergedTicket: UInt64 = 0
        var pending: QueuedMirrorBatch?
        var inFlight: QueuedMirrorBatch?
        var waiters: [UUID: SequenceWaiter] = [:]
        var settlements: [MirrorSettlement] = []
    }

    private struct MirrorSettlement: Equatable {
        var lowerTicket: UInt64
        var upperTicket: UInt64
        let result: SequenceWaitResult
    }

    private struct MirrorWorker {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let isContextCurrent: IsContextCurrent
    private let applyCanonical: ApplyCanonical
    private let applyMirror: ApplyMirror
    private var nextSequence: UInt64 = 0
    private var canonicalLanes: [ContextKey: CanonicalLane] = [:]
    private var canonicalWorkers = Set<ContextKey>()
    private var canonicalWorkerIDs: [ContextKey: UUID] = [:]
    private var mirrorLanes: [TabMirrorKey: MirrorLane] = [:]
    private var mirrorWorkers: [TabMirrorKey: MirrorWorker] = [:]
    private var retiredMirrorWorkerTasks: [UUID: Task<Void, Never>] = [:]
    private var mirrorWaiterDeadlineTasks: [UUID: Task<Void, Never>] = [:]
    private var closingContexts = Set<ContextKey>()
    private var invalidatedContexts = Set<ContextKey>()
    private var retiringContexts = Set<ContextKey>()
    private var mirrorWaitTimeout: Duration
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
        applyMirror: @escaping ApplyMirror,
        mirrorWaitTimeout: Duration = .seconds(10)
    ) {
        self.isContextCurrent = isContextCurrent
        self.applyCanonical = applyCanonical
        self.applyMirror = applyMirror
        self.mirrorWaitTimeout = mirrorWaitTimeout
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
        guard !Task.isCancelled else {
            outcome = "cancelled"
            return .cancelled
        }
        let mirrorTicket: UInt64?
        switch canonicalResult {
        case let .completed(requiredMirrorTicket):
            mirrorTicket = requiredMirrorTicket
        case .invalidated:
            outcome = "invalidated"
            return .invalidated
        case .cancelled:
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
            let mirrorResult = await waitForMirrorTicket(mirrorTicket, for: key.mirrorKey, context: key)
            guard !Task.isCancelled else {
                outcome = "cancelled"
                return .cancelled
            }
            switch mirrorResult {
            case .converged:
                break
            case .deferred:
                outcome = "deferred"
                return .deferred
            case .invalidated:
                outcome = "invalidated"
                return .invalidated
            case .cancelled:
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
        settleCanonicalWaiters(for: key, result: .invalidated)
        cancelMirrorWaiters(for: key, result: .invalidated)
        retireMirrorOwnership(for: key)
        if canonicalLanes[key]?.pending != nil {
            scheduleCanonicalWorkerIfNeeded(for: key)
        }
        cleanupRetiredContextIfSettled(key)
    }

    #if DEBUG
        func setCanonicalApplyGateForTesting(_ gate: (() async -> Void)?) {
            canonicalApplyGateForTesting = gate
        }

        func setMirrorWaitTimeoutForTesting(_ timeout: Duration) {
            mirrorWaitTimeout = timeout
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
                mirrorWaiterCount: mirrorLanes.values.reduce(0) { $0 + $1.waiters.count },
                inFlightMirrorBatchCount: mirrorLanes.values.count(where: { $0.inFlight != nil }),
                retiredMirrorWorkerCount: retiredMirrorWorkerTasks.count,
                liveMirrorDeadlineCount: mirrorWaiterDeadlineTasks.count,
                mirrorSettlementRangeCount: mirrorLanes.values.reduce(0) { $0 + $1.settlements.count }
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
                                    owner: key,
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
        owner: ContextKey,
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
            pending.owners.insert(owner)
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
                owners: [owner],
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
        guard mirrorWorkers[key] == nil,
              mirrorLanes[key]?.pending != nil
        else { return }
        let workerID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await runMirrorWorker(for: key, workerID: workerID)
        }
        mirrorWorkers[key] = MirrorWorker(id: workerID, task: task)
        emitMirrorDiagnostic(
            .workerStarted,
            for: key,
            workerID: workerID
        )
    }

    private func runMirrorWorker(for key: TabMirrorKey, workerID: UUID) async {
        defer {
            let ownsLane = mirrorWorkers[key]?.id == workerID
            if ownsLane {
                mirrorWorkers.removeValue(forKey: key)
            }
            retiredMirrorWorkerTasks.removeValue(forKey: workerID)
            emitMirrorDiagnostic(
                .workerStopped,
                for: key,
                workerID: workerID
            )
            if ownsLane {
                scheduleMirrorWorkerIfNeeded(for: key)
                cleanupMirrorLaneIfSettled(key)
            }
        }
        while ownsMirrorLane(key, workerID: workerID),
              var lane = mirrorLanes[key],
              let queued = lane.pending
        {
            lane.pending = nil
            lane.inFlight = queued
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
            let mirrorOutcome = await EditFlowPerf.$currentLifecycleCorrelation.withValue(queued.lifecycleCorrelation) {
                await EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.AutoSelect.mirrorApply) {
                    await applyMirror(key)
                }
            }
            guard ownsMirrorLane(key, workerID: workerID) else { return }
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFileAutoSelect.mirrorApplyEnded,
                correlation: queued.lifecycleCorrelation
            )
            completeMirrorBatch(
                for: key,
                throughTicket: queued.highestTicket,
                outcome: mirrorOutcome
            )
            await Task.yield()
            guard ownsMirrorLane(key, workerID: workerID) else { return }
        }
    }

    private func ownsMirrorLane(_ key: TabMirrorKey, workerID: UUID) -> Bool {
        mirrorWorkers[key]?.id == workerID
    }

    private func completeMirrorBatch(
        for key: TabMirrorKey,
        throughTicket: UInt64,
        outcome: WorkspaceSelectionCoordinator.SelectionMirrorOutcome
    ) {
        guard var lane = mirrorLanes[key] else { return }
        let lowerTicket = lane.completedTicket &+ 1
        lane.completedTicket = max(lane.completedTicket, throughTicket)
        lane.inFlight = nil
        let terminalResult: SequenceWaitResult?
        switch outcome {
        case .converged:
            terminalResult = nil
            lane.convergedTicket = max(lane.convergedTicket, throughTicket)
        case .deferred:
            terminalResult = .deferred
        case .invalidated:
            terminalResult = .invalidated
        case .cancelled:
            terminalResult = .cancelled
        }
        if let terminalResult {
            recordMirrorSettlement(
                MirrorSettlement(lowerTicket: lowerTicket, upperTicket: throughTicket, result: terminalResult),
                in: &lane
            )
        }
        let satisfied = lane.waiters.filter { $0.value.target <= lane.completedTicket }
        for (id, _) in satisfied {
            lane.waiters.removeValue(forKey: id)
        }
        mirrorLanes[key] = lane
        for (id, waiter) in satisfied {
            mirrorWaiterDeadlineTasks.removeValue(forKey: id)?.cancel()
            emitMirrorDiagnostic(
                .waiterResumed,
                for: key,
                lane: lane,
                target: waiter.target,
                waiterID: id
            )
            let result = resolvedMirrorWaitResult(for: waiter.target, in: lane, context: waiter.contextKey)
            waiter.continuation.resume(returning: result)
        }
        pruneMirrorSettlements(for: key)
    }

    private func recordMirrorSettlement(_ settlement: MirrorSettlement, in lane: inout MirrorLane) {
        guard settlement.lowerTicket <= settlement.upperTicket else { return }
        if var last = lane.settlements.last,
           last.result == settlement.result,
           last.upperTicket &+ 1 == settlement.lowerTicket
        {
            last.upperTicket = settlement.upperTicket
            lane.settlements[lane.settlements.count - 1] = last
        } else {
            lane.settlements.append(settlement)
        }
    }

    private func mirrorSettlement(for ticket: UInt64, in lane: MirrorLane) -> SequenceWaitResult? {
        lane.settlements.last(where: { $0.lowerTicket <= ticket && ticket <= $0.upperTicket })?.result
    }

    /// Exact context invalidation is authoritative. Otherwise, a later successful physical apply
    /// for the shared tab upgrades earlier deferred/cancelled tickets owned by still-live peers.
    private func resolvedMirrorWaitResult(
        for ticket: UInt64,
        in lane: MirrorLane,
        context: ContextKey
    ) -> SequenceWaitResult {
        if invalidatedContexts.contains(context) { return .invalidated }
        if lane.convergedTicket >= ticket { return .converged }
        return mirrorSettlement(for: ticket, in: lane) ?? .deferred
    }

    private func pruneMirrorSettlements(for key: TabMirrorKey) {
        guard var lane = mirrorLanes[key] else { return }
        let requiredTickets = canonicalLanes
            .filter { $0.key.mirrorKey == key }
            .compactMap(\.value.latestRequiredMirrorTicket)
            + lane.waiters.values.map(\.target)
        guard !requiredTickets.isEmpty else {
            // A mirror can physically settle before its canonical worker publishes the required
            // ticket. Retain one compact terminal range for that handoff window.
            lane.settlements = lane.settlements.last.map { [$0] } ?? []
            mirrorLanes[key] = lane
            return
        }
        let latest = lane.settlements.last
        lane.settlements = lane.settlements.filter { settlement in
            latest.map { $0 == settlement } == true || requiredTickets.contains(where: {
                settlement.lowerTicket <= $0 && $0 <= settlement.upperTicket
            })
        }
        mirrorLanes[key] = lane
    }

    private func waitForCanonicalSequence(
        _ target: UInt64,
        for key: ContextKey,
        onWaiterRegistered: (() -> Void)?
    ) async -> CanonicalWaitResult {
        if Task.isCancelled {
            return .cancelled
        }
        if invalidatedContexts.contains(key) { return .invalidated }
        if let lane = canonicalLanes[key], lane.completedSequence >= target {
            return .completed(requiredMirrorTicket: lane.latestRequiredMirrorTicket)
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var lane = canonicalLanes[key] ?? CanonicalLane()
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                } else if invalidatedContexts.contains(key) {
                    continuation.resume(returning: .invalidated)
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

    private func waitForMirrorTicket(
        _ target: UInt64,
        for key: TabMirrorKey,
        context contextKey: ContextKey
    ) async -> SequenceWaitResult {
        if Task.isCancelled {
            return .cancelled
        }
        if invalidatedContexts.contains(contextKey) { return .invalidated }
        if let lane = mirrorLanes[key], lane.completedTicket >= target {
            return resolvedMirrorWaitResult(for: target, in: lane, context: contextKey)
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var lane = mirrorLanes[key] ?? MirrorLane()
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                } else if invalidatedContexts.contains(contextKey) {
                    continuation.resume(returning: .invalidated)
                } else if lane.completedTicket >= target {
                    continuation.resume(returning: resolvedMirrorWaitResult(
                        for: target,
                        in: lane,
                        context: contextKey
                    ))
                } else {
                    lane.waiters[waiterID] = SequenceWaiter(
                        contextKey: contextKey,
                        target: target,
                        continuation: continuation
                    )
                    mirrorLanes[key] = lane
                    let timeout = mirrorWaitTimeout
                    mirrorWaiterDeadlineTasks[waiterID] = Task { @MainActor [weak self] in
                        do {
                            try await Task.sleep(for: timeout)
                        } catch {
                            return
                        }
                        self?.cancelMirrorWaiter(waiterID, for: key, result: .deferred)
                    }
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
                self?.cancelMirrorWaiter(waiterID, for: key, result: .cancelled)
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

    private func settleCanonicalWaiters(for key: ContextKey, result: CanonicalWaitResult) {
        guard var lane = canonicalLanes[key], !lane.waiters.isEmpty else { return }
        let waiters = lane.waiters
        lane.waiters.removeAll()
        canonicalLanes[key] = lane
        for (id, waiter) in waiters {
            emitCanonicalDiagnostic(.waiterResumed, for: key, lane: lane, target: waiter.target, waiterID: id)
            waiter.continuation.resume(returning: result)
        }
        cleanupRetiredContextIfSettled(key)
    }

    private func cancelMirrorWaiter(
        _ waiterID: UUID,
        for key: TabMirrorKey,
        result: SequenceWaitResult
    ) {
        guard var lane = mirrorLanes[key],
              let waiter = lane.waiters.removeValue(forKey: waiterID)
        else { return }
        mirrorWaiterDeadlineTasks.removeValue(forKey: waiterID)?.cancel()
        mirrorLanes[key] = lane
        emitMirrorDiagnostic(
            .waiterResumed,
            for: key,
            lane: lane,
            target: waiter.target,
            waiterID: waiterID
        )
        waiter.continuation.resume(returning: result)
        cleanupMirrorLaneIfSettled(key)
    }

    private func cancelMirrorWaiters(for contextKey: ContextKey, result: SequenceWaitResult) {
        let key = contextKey.mirrorKey
        guard var lane = mirrorLanes[key] else { return }
        let cancelled = lane.waiters.filter { $0.value.contextKey == contextKey }
        guard !cancelled.isEmpty else { return }
        for (id, _) in cancelled {
            lane.waiters.removeValue(forKey: id)
            mirrorWaiterDeadlineTasks.removeValue(forKey: id)?.cancel()
        }
        mirrorLanes[key] = lane
        for (id, waiter) in cancelled {
            emitMirrorDiagnostic(.waiterResumed, for: key, lane: lane, target: waiter.target, waiterID: id)
            waiter.continuation.resume(returning: result)
        }
        cleanupMirrorLaneIfSettled(key)
    }

    /// Invalidating one exact route must not let its parked worker keep ownership of the shared
    /// tab lane. Surviving same-tab owners are requeued under a new worker ID; the old task is
    /// retained only until its body physically exits and is fenced from every lane mutation.
    private func retireMirrorOwnership(for contextKey: ContextKey) {
        let key = contextKey.mirrorKey
        guard var lane = mirrorLanes[key] else { return }

        if var pending = lane.pending {
            pending.owners.remove(contextKey)
            lane.pending = pending.owners.isEmpty ? nil : pending
        }
        if var inFlight = lane.inFlight {
            inFlight.owners.remove(contextKey)
            if let worker = mirrorWorkers[key] {
                mirrorWorkers.removeValue(forKey: key)
                retiredMirrorWorkerTasks[worker.id] = worker.task
                worker.task.cancel()
                lane.inFlight = nil
                if inFlight.owners.isEmpty {
                    let lowerTicket = lane.completedTicket &+ 1
                    lane.completedTicket = max(lane.completedTicket, inFlight.highestTicket)
                    recordMirrorSettlement(
                        MirrorSettlement(
                            lowerTicket: lowerTicket,
                            upperTicket: inFlight.highestTicket,
                            result: .invalidated
                        ),
                        in: &lane
                    )
                } else if var pending = lane.pending {
                    pending.highestTicket = max(pending.highestTicket, inFlight.highestTicket)
                    pending.owners.formUnion(inFlight.owners)
                    lane.pending = pending
                } else {
                    lane.pending = inFlight
                }
            }
        }
        mirrorLanes[key] = lane
        scheduleMirrorWorkerIfNeeded(for: key)
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
            workerActive: mirrorWorkers[key] != nil,
            pendingWork: lane.pending != nil,
            waiterID: waiterID,
            workerID: workerID ?? mirrorWorkers[key]?.id,
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
        guard mirrorWorkers[key] == nil,
              mirrorLanes[key]?.pending == nil,
              mirrorLanes[key]?.inFlight == nil,
              mirrorLanes[key]?.waiters.isEmpty != false,
              !canonicalLanes.keys.contains(where: { $0.mirrorKey == key })
        else { return }
        mirrorLanes.removeValue(forKey: key)
    }
}
