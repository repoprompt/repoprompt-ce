import Cuchardet
import Foundation
import UniversalCharsetDetection

private extension String.Encoding {
    init(ianaCharsetName name: String) {
        let cfEnc = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        self.init(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
    }
}

// MARK: - Encoding detection helpers & priority tables

/// Run a streaming detector (Cuchardet) over the entire byte sequence.
/// Falls back to Foundation’s heuristic if the detector is unavailable.
private func detectEncodingFull(_ data: Data) -> String.Encoding {
    // 1) Primary - Cuchardet
    if let label = data.detectedCharacterEncoding { // DataProtocol extension from Cuchardet
        return .init(ianaCharsetName: label)
    }

    // 2) Fallback - Foundation heuristic
    var lossy = ObjCBool(false)
    let guess = NSString.stringEncoding(
        for: data,
        encodingOptions: [:],
        convertedString: nil,
        usedLossyConversion: &lossy
    )
    return guess != 0 ? .init(rawValue: guess) : .utf8
}

/// The workspace's versioned automatic source decoder policy. Both legacy
/// content loading and content-addressed source envelopes use this exact pure
/// transformation so they cannot drift on byte-to-text interpretation.
func decodeWorkspaceAutomaticV1(_ data: Data) -> DetectedText? {
    if data.isEmpty {
        return DetectedText(string: "", encoding: .utf8)
    }
    if let utf8String = String(data: data, encoding: .utf8) {
        return DetectedText(string: utf8String, encoding: .utf8)
    }
    let encoding = detectEncodingFull(data)
    guard let string = String(data: data, encoding: encoding) else {
        return nil
    }
    return DetectedText(string: string, encoding: encoding)
}

private enum ContentReadMode {
    case automatic
    case streamed
}

private struct ContentReadRequest {
    let cacheKey: String
    let relativePath: String
    let absolutePath: String
    let standardizedRootPath: String
    let canonicalRootPath: String
    let skipSymlinks: Bool
    let chunkSize: Int
    let fileSizeLimit: Int64
    let mode: ContentReadMode
    let workloadClass: ContentReadWorkloadClass
    let schedulerOwnerID: UUID
    #if DEBUG
        let chunkReadHandler: (@Sendable (String) async -> Void)?
    #endif
}

private enum ContentReadTelemetryOutcome: String {
    case loaded
    case unavailable
    case oversized
}

private struct ContentReadResult {
    let absolutePath: String
    let content: String?
    let detectedEncodingRawValue: UInt?
    let modificationDate: Date?
    let fingerprint: FileContentFingerprint?
    let telemetryOutcome: ContentReadTelemetryOutcome

    var detectedEncoding: String.Encoding? {
        detectedEncodingRawValue.map(String.Encoding.init(rawValue:))
    }
}

private struct RawContentReadResult {
    let data: Data
    let modificationDate: Date
    let fingerprint: FileContentFingerprint
}

struct FileContentPrefix {
    let content: String
    let truncated: Bool
}

private struct ValidatedContentFile {
    let url: URL
    let fileSize: Int64
    let modificationDate: Date
    let fingerprint: FileContentFingerprint
}

private enum BoundedDataReadResult {
    case data(Data)
    case tooLarge(observedByteCount: Int64)
}

enum ContentReadForegroundActivityKind: String, CaseIterable, Hashable {
    case materialization
    case rootLoad
    case storeBackedSearch
    case readResolution
    case interactiveRead
}

struct ContentReadForegroundActivityToken: Hashable {
    fileprivate let id: UUID
    let kind: ContentReadForegroundActivityKind
}

actor ContentReadAsyncLimiter {
    #if DEBUG
        struct Snapshot: Equatable {
            let capacity: Int
            let maxQueuedWaiterCount: Int
            let activePermitCount: Int
            let queuedWaiterCount: Int
            let ownerLaneCount: Int
            let cancellationCount: Int
            let grantCount: Int
            let overloadCount: Int
            let interactiveGrantCount: Int
            let normalGrantCount: Int
            let bulkGrantCount: Int
            let backgroundPermitLimit: Int
            let activeBackgroundPermitCount: Int
            let activeCodemapPermitCount: Int
            let queuedCodemapWaiterCount: Int
            let foregroundActivityCount: Int
            let foregroundActivityCountsByKind: [ContentReadForegroundActivityKind: Int]
            let codemapGrantWhileForegroundCount: Int

            var isIdle: Bool {
                activePermitCount == 0 && queuedWaiterCount == 0 && ownerLaneCount == 0
                    && foregroundActivityCount == 0
            }
        }
    #endif

    private enum PriorityClass: Int, CaseIterable {
        case interactive
        case normal
        case bulk
    }

    private struct PermitAcquisition {
        let ownerID: UUID
        let workloadClass: ContentReadWorkloadClass
        let priorityClass: PriorityClass
        let waited: Bool
        let queueDepth: Int
        let waiterCount: Int
    }

    private struct WaiterState {
        let continuation: CheckedContinuation<PermitAcquisition, Error>
        let workloadClass: ContentReadWorkloadClass
        let ownerID: UUID
        let priorityClass: PriorityClass
        let lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
        let enqueueOrdinal: UInt64
        let enqueuedAtUptimeNanoseconds: UInt64
    }

    private let capacity: Int
    private let maxQueuedWaiterCount: Int
    private let retryAfterMilliseconds: Int
    private let agePromotionNanoseconds: UInt64
    private let maxConsecutiveInteractiveGrants: Int
    private let backgroundPermitLimit: Int
    private let nowUptimeNanoseconds: @Sendable () -> UInt64
    private var availablePermits: Int
    private var activeBackgroundPermitCount = 0
    private var activeCodemapPermitCount = 0
    private var foregroundActivitiesByTokenID: [UUID: ContentReadForegroundActivityKind] = [:]
    private var waiterStates: [UUID: WaiterState] = [:]
    private var activePermitCountsByOwner: [UUID: Int] = [:]
    private var lastGrantOrdinalByOwner: [UUID: UInt64] = [:]
    private var nextEnqueueOrdinal: UInt64 = 0
    private var nextGrantOrdinal: UInt64 = 0
    private var consecutiveInteractiveGrants = 0
    private var cancellationCount = 0
    private var grantCount = 0
    private var overloadCount = 0
    private var interactiveGrantCount = 0
    private var normalGrantCount = 0
    private var bulkGrantCount = 0
    private var codemapGrantWhileForegroundCount = 0

    init(
        capacity: Int,
        maxQueuedWaiterCount: Int = 512,
        retryAfterMilliseconds: Int = 1000,
        agePromotionNanoseconds: UInt64 = 1_000_000_000,
        maxConsecutiveInteractiveGrants: Int = 4,
        nowUptimeNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        precondition(capacity > 0, "Content read limiter must have at least one permit")
        precondition(maxQueuedWaiterCount >= 0)
        precondition(retryAfterMilliseconds >= 0)
        precondition(maxConsecutiveInteractiveGrants > 0)
        self.capacity = capacity
        self.maxQueuedWaiterCount = maxQueuedWaiterCount
        self.retryAfterMilliseconds = retryAfterMilliseconds
        self.agePromotionNanoseconds = agePromotionNanoseconds
        self.maxConsecutiveInteractiveGrants = maxConsecutiveInteractiveGrants
        backgroundPermitLimit = capacity > 1 ? capacity - 1 : 1
        self.nowUptimeNanoseconds = nowUptimeNanoseconds
        availablePermits = capacity
    }

    func beginForegroundActivity(
        kind: ContentReadForegroundActivityKind
    ) -> ContentReadForegroundActivityToken {
        let token = ContentReadForegroundActivityToken(id: UUID(), kind: kind)
        foregroundActivitiesByTokenID[token.id] = kind
        return token
    }

    func endForegroundActivity(_ token: ContentReadForegroundActivityToken) {
        guard foregroundActivitiesByTokenID[token.id] == token.kind else {
            assertionFailure("Content read foreground activity token mismatch or over-release")
            return
        }
        foregroundActivitiesByTokenID.removeValue(forKey: token.id)
        if foregroundActivitiesByTokenID.isEmpty {
            scheduleAvailablePermits()
        }
    }

    func withForegroundActivity<T>(
        kind: ContentReadForegroundActivityKind,
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        let token = beginForegroundActivity(kind: kind)
        do {
            let result = try await body()
            endForegroundActivity(token)
            return result
        } catch {
            endForegroundActivity(token)
            throw error
        }
    }

    func withCodeMapArtifactBuildPermit<T: Sendable>(
        ownerID: UUID,
        priority: TaskPriority,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withPermit(workloadClass: .codemap, ownerID: ownerID) {
            let task = Task.detached(priority: priority, operation: operation)
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
    }

    func withPermit<T>(
        workloadClass: ContentReadWorkloadClass,
        ownerID: UUID,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        #if DEBUG
            let coldStartCollector = WorkspaceFileSearchDebugContext.coldStartCollector
            let schedulerRequestStart = WorkspaceFileSearchDebugTiming.now()
            let benchmarkMetricTag = WorktreeStartupInstrumentation.currentBenchmarkMetricTag
            coldStartCollector?.recordSchedulerRequest(workload: workloadClass.rawValue)
        #endif
        let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        let permitWaitState = EditFlowPerf.begin(
            EditFlowPerf.Stage.FileSystem.contentReadWorkerPermitWait,
            EditFlowPerf.Dimensions(
                workloadClass: workloadClass.rawValue,
                queueDepth: waiterStates.count,
                waiterCount: waiterStates.count
            )
        )
        let acquisition: PermitAcquisition
        do {
            acquisition = try await acquire(
                workloadClass: workloadClass,
                ownerID: ownerID,
                lifecycleCorrelation: lifecycleCorrelation
            )
            #if DEBUG
                coldStartCollector?.recordSchedulerGrant(
                    workload: workloadClass.rawValue,
                    waitNanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                        since: schedulerRequestStart,
                        through: WorkspaceFileSearchDebugTiming.now()
                    )
                )
            #endif
            EditFlowPerf.end(
                EditFlowPerf.Stage.FileSystem.contentReadWorkerPermitWait,
                permitWaitState,
                EditFlowPerf.Dimensions(
                    outcome: acquisition.waited ? "acquiredAfterWait" : "immediate",
                    workloadClass: workloadClass.rawValue,
                    queueDepth: acquisition.queueDepth,
                    waiterCount: acquisition.waiterCount
                )
            )
        } catch {
            #if DEBUG
                if case ContentReadSchedulerError.queueFull = error {
                    WorktreeStartupInstrumentation.recordBenchmarkContentReadWork(
                        tag: benchmarkMetricTag,
                        waitMicroseconds: 0,
                        executionMicroseconds: 0,
                        overloaded: true
                    )
                }
            #endif
            EditFlowPerf.end(
                EditFlowPerf.Stage.FileSystem.contentReadWorkerPermitWait,
                permitWaitState,
                EditFlowPerf.Dimensions(
                    outcome: error is CancellationError ? "cancelled" : "error",
                    workloadClass: workloadClass.rawValue,
                    queueDepth: waiterStates.count,
                    waiterCount: waiterStates.count
                )
            )
            throw error
        }
        #if DEBUG
            let executionStart = WorkspaceFileSearchDebugTiming.now()
            do {
                try Task.checkCancellation()
                let result = try await body()
                let executionNanoseconds = WorkspaceFileSearchDebugTiming.elapsed(
                    since: executionStart,
                    through: WorkspaceFileSearchDebugTiming.now()
                )
                release(acquisition)
                coldStartCollector?.recordSchedulerCompletion(
                    workload: workloadClass.rawValue,
                    executionNanoseconds: executionNanoseconds,
                    cancelled: false,
                    failed: false
                )
                WorktreeStartupInstrumentation.recordBenchmarkContentReadWork(
                    tag: benchmarkMetricTag,
                    waitMicroseconds: WorkspaceFileSearchDebugTiming.elapsed(
                        since: schedulerRequestStart,
                        through: executionStart
                    ) / 1000,
                    executionMicroseconds: executionNanoseconds / 1000,
                    overloaded: false
                )
                return result
            } catch {
                let executionNanoseconds = WorkspaceFileSearchDebugTiming.elapsed(
                    since: executionStart,
                    through: WorkspaceFileSearchDebugTiming.now()
                )
                release(acquisition)
                coldStartCollector?.recordSchedulerCompletion(
                    workload: workloadClass.rawValue,
                    executionNanoseconds: executionNanoseconds,
                    cancelled: error is CancellationError,
                    failed: !(error is CancellationError)
                )
                WorktreeStartupInstrumentation.recordBenchmarkContentReadWork(
                    tag: benchmarkMetricTag,
                    waitMicroseconds: WorkspaceFileSearchDebugTiming.elapsed(
                        since: schedulerRequestStart,
                        through: executionStart
                    ) / 1000,
                    executionMicroseconds: executionNanoseconds / 1000,
                    overloaded: false
                )
                throw error
            }
        #else
            defer { release(acquisition) }
            try Task.checkCancellation()
            return try await body()
        #endif
    }

    private func acquire(
        workloadClass: ContentReadWorkloadClass,
        ownerID: UUID,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
    ) async throws -> PermitAcquisition {
        try Task.checkCancellation()
        scheduleAvailablePermits()
        let priorityClass = Self.priorityClass(for: workloadClass)
        if waiterStates.isEmpty, canAllocatePermit(workloadClass: workloadClass) {
            return allocatePermit(
                ownerID: ownerID,
                workloadClass: workloadClass,
                priorityClass: priorityClass,
                waited: false
            )
        }
        guard canEnqueueWaiter(workloadClass: workloadClass) else {
            overloadCount &+= 1
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.FileSystem.contentReadWorkerOverloaded,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    workloadClass: workloadClass.rawValue,
                    queueDepth: waiterStates.count,
                    waiterCount: waiterStates.count
                )
            )
            throw ContentReadSchedulerError.queueFull(retryAfterMilliseconds: retryAfterMilliseconds)
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueueWaiter(
                    id: waiterID,
                    continuation: continuation,
                    workloadClass: workloadClass,
                    ownerID: ownerID,
                    lifecycleCorrelation: lifecycleCorrelation
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func enqueueWaiter(
        id: UUID,
        continuation: CheckedContinuation<PermitAcquisition, Error>,
        workloadClass: ContentReadWorkloadClass,
        ownerID: UUID,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
    ) {
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        guard canEnqueueWaiter(workloadClass: workloadClass) else {
            overloadCount &+= 1
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.FileSystem.contentReadWorkerOverloaded,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    workloadClass: workloadClass.rawValue,
                    queueDepth: waiterStates.count,
                    waiterCount: waiterStates.count
                )
            )
            continuation.resume(throwing: ContentReadSchedulerError.queueFull(
                retryAfterMilliseconds: retryAfterMilliseconds
            ))
            return
        }
        nextEnqueueOrdinal &+= 1
        waiterStates[id] = WaiterState(
            continuation: continuation,
            workloadClass: workloadClass,
            ownerID: ownerID,
            priorityClass: Self.priorityClass(for: workloadClass),
            lifecycleCorrelation: lifecycleCorrelation,
            enqueueOrdinal: nextEnqueueOrdinal,
            enqueuedAtUptimeNanoseconds: nowUptimeNanoseconds()
        )
        #if DEBUG
            WorkspaceFileSearchDebugContext.coldStartCollector?.recordSchedulerEnqueue(
                workload: workloadClass.rawValue
            )
        #endif
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.FileSystem.contentReadWorkerPermitWaitBegan,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(
                workloadClass: workloadClass.rawValue,
                queueDepth: waiterStates.count,
                waiterCount: waiterStates.count
            )
        )
        scheduleAvailablePermits()
    }

    private func cancelWaiter(id: UUID) {
        guard let state = waiterStates.removeValue(forKey: id) else { return }
        cancellationCount &+= 1
        cleanupOwnerIfIdle(state.ownerID)
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.FileSystem.contentReadWorkerPermitCancelled,
            correlation: state.lifecycleCorrelation,
            EditFlowPerf.Dimensions(
                workloadClass: state.workloadClass.rawValue,
                queueDepth: waiterStates.count,
                waiterCount: waiterStates.count
            )
        )
        state.continuation.resume(throwing: CancellationError())
        scheduleAvailablePermits()
    }

    private func release(_ acquisition: PermitAcquisition) {
        if acquisition.priorityClass == .bulk {
            #if DEBUG
                assert(activeBackgroundPermitCount > 0, "Content read limiter background over-release detected")
            #endif
            activeBackgroundPermitCount = max(0, activeBackgroundPermitCount - 1)
        }
        if acquisition.workloadClass == .codemap {
            #if DEBUG
                assert(activeCodemapPermitCount > 0, "Content read limiter codemap over-release detected")
            #endif
            activeCodemapPermitCount = max(0, activeCodemapPermitCount - 1)
        }
        if let activeCount = activePermitCountsByOwner[acquisition.ownerID] {
            if activeCount <= 1 {
                activePermitCountsByOwner.removeValue(forKey: acquisition.ownerID)
            } else {
                activePermitCountsByOwner[acquisition.ownerID] = activeCount - 1
            }
        }
        #if DEBUG
            assert(availablePermits < capacity, "Content read limiter over-release detected")
        #endif
        availablePermits = min(availablePermits + 1, capacity)
        cleanupOwnerIfIdle(acquisition.ownerID)
        scheduleAvailablePermits()
    }

    private func scheduleAvailablePermits() {
        while availablePermits > 0, let waiterID = nextWaiterID() {
            guard let state = waiterStates.removeValue(forKey: waiterID) else { continue }
            let acquisition = allocatePermit(
                ownerID: state.ownerID,
                workloadClass: state.workloadClass,
                priorityClass: state.priorityClass,
                waited: true
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.FileSystem.contentReadWorkerPermitAcquired,
                correlation: state.lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    workloadClass: state.workloadClass.rawValue,
                    queueDepth: waiterStates.count,
                    waiterCount: waiterStates.count
                )
            )
            state.continuation.resume(returning: acquisition)
        }
    }

    private func nextWaiterID() -> UUID? {
        let now = nowUptimeNanoseconds()
        let hasQueuedForegroundWork = waiterStates.values.contains {
            Self.isForegroundWorkload($0.workloadClass) && canAllocatePermit(workloadClass: $0.workloadClass)
        }
        let eligibleWaiters = waiterStates.filter {
            canAllocatePermit(workloadClass: $0.value.workloadClass)
                && !(hasQueuedForegroundWork && $0.value.workloadClass == .codemap)
        }
        if let aged = eligibleWaiters.min(by: { lhs, rhs in
            let lhsAged = elapsedNanoseconds(since: lhs.value.enqueuedAtUptimeNanoseconds, now: now) >= agePromotionNanoseconds
            let rhsAged = elapsedNanoseconds(since: rhs.value.enqueuedAtUptimeNanoseconds, now: now) >= agePromotionNanoseconds
            if lhsAged != rhsAged { return lhsAged && !rhsAged }
            return lhs.value.enqueueOrdinal < rhs.value.enqueueOrdinal
        }), elapsedNanoseconds(since: aged.value.enqueuedAtUptimeNanoseconds, now: now) >= agePromotionNanoseconds {
            return aged.key
        }

        let hasInteractive = waiterStates.values.contains {
            $0.priorityClass == .interactive && canAllocatePermit(workloadClass: $0.workloadClass)
        }
        let hasNormal = waiterStates.values.contains {
            $0.priorityClass == .normal && canAllocatePermit(workloadClass: $0.workloadClass)
        }
        let hasBulk = waiterStates.values.contains {
            $0.priorityClass == .bulk
                && canAllocatePermit(workloadClass: $0.workloadClass)
                && !(hasQueuedForegroundWork && $0.workloadClass == .codemap)
        }
        let selectedPriority: PriorityClass
        if hasInteractive,
           consecutiveInteractiveGrants < maxConsecutiveInteractiveGrants || (!hasNormal && !hasBulk)
        {
            selectedPriority = .interactive
        } else if hasNormal {
            selectedPriority = .normal
        } else if hasBulk {
            selectedPriority = .bulk
        } else if hasInteractive {
            selectedPriority = .interactive
        } else {
            return nil
        }
        return nextWaiterID(
            priorityClass: selectedPriority,
            suppressCodemap: hasQueuedForegroundWork
        )
    }

    private func nextWaiterID(
        priorityClass: PriorityClass,
        suppressCodemap: Bool
    ) -> UUID? {
        var firstByOwner: [UUID: (id: UUID, state: WaiterState)] = [:]
        for (id, state) in waiterStates
            where state.priorityClass == priorityClass
            && canAllocatePermit(workloadClass: state.workloadClass)
            && !(suppressCodemap && state.workloadClass == .codemap)
        {
            if let existing = firstByOwner[state.ownerID], existing.state.enqueueOrdinal <= state.enqueueOrdinal {
                continue
            }
            firstByOwner[state.ownerID] = (id, state)
        }
        return firstByOwner.values.min { lhs, rhs in
            let lhsGrant = lastGrantOrdinalByOwner[lhs.state.ownerID]
            let rhsGrant = lastGrantOrdinalByOwner[rhs.state.ownerID]
            switch (lhsGrant, rhsGrant) {
            case (nil, nil):
                return lhs.state.enqueueOrdinal < rhs.state.enqueueOrdinal
            case (nil, _):
                return true
            case (_, nil):
                return false
            case let (lhsGrant?, rhsGrant?):
                if lhsGrant != rhsGrant { return lhsGrant < rhsGrant }
                return lhs.state.enqueueOrdinal < rhs.state.enqueueOrdinal
            }
        }?.id
    }

    private func allocatePermit(
        ownerID: UUID,
        workloadClass: ContentReadWorkloadClass,
        priorityClass: PriorityClass,
        waited: Bool
    ) -> PermitAcquisition {
        #if DEBUG
            assert(canAllocatePermit(workloadClass: workloadClass), "Content read limiter allocation exceeded workload capacity")
        #endif
        availablePermits -= 1
        if priorityClass == .bulk {
            activeBackgroundPermitCount += 1
        }
        if workloadClass == .codemap {
            activeCodemapPermitCount += 1
            if !foregroundActivitiesByTokenID.isEmpty {
                codemapGrantWhileForegroundCount &+= 1
            }
        }
        activePermitCountsByOwner[ownerID, default: 0] += 1
        nextGrantOrdinal &+= 1
        lastGrantOrdinalByOwner[ownerID] = nextGrantOrdinal
        grantCount &+= 1
        switch priorityClass {
        case .interactive:
            interactiveGrantCount &+= 1
            consecutiveInteractiveGrants += 1
        case .normal:
            normalGrantCount &+= 1
            consecutiveInteractiveGrants = 0
        case .bulk:
            bulkGrantCount &+= 1
            consecutiveInteractiveGrants = 0
        }
        return PermitAcquisition(
            ownerID: ownerID,
            workloadClass: workloadClass,
            priorityClass: priorityClass,
            waited: waited,
            queueDepth: waiterStates.count,
            waiterCount: waiterStates.count
        )
    }

    private func canAllocatePermit(workloadClass: ContentReadWorkloadClass) -> Bool {
        guard availablePermits > 0 else { return false }
        if workloadClass == .codemap, !foregroundActivitiesByTokenID.isEmpty {
            return false
        }
        let priorityClass = Self.priorityClass(for: workloadClass)
        return priorityClass != .bulk || activeBackgroundPermitCount < backgroundPermitLimit
    }

    private func canEnqueueWaiter(workloadClass: ContentReadWorkloadClass) -> Bool {
        let foregroundQueueReserve = maxQueuedWaiterCount > 1 ? 1 : 0
        let workloadQueueLimit = workloadClass == .codemap
            ? maxQueuedWaiterCount - foregroundQueueReserve
            : maxQueuedWaiterCount
        return waiterStates.count < workloadQueueLimit
    }

    private func cleanupOwnerIfIdle(_ ownerID: UUID) {
        guard activePermitCountsByOwner[ownerID] == nil,
              !waiterStates.values.contains(where: { $0.ownerID == ownerID })
        else { return }
        lastGrantOrdinalByOwner.removeValue(forKey: ownerID)
    }

    private func elapsedNanoseconds(since start: UInt64, now: UInt64) -> UInt64 {
        now >= start ? now - start : 0
    }

    private static func priorityClass(for workloadClass: ContentReadWorkloadClass) -> PriorityClass {
        switch workloadClass {
        case .interactiveRead:
            .interactive
        case .contentSearch:
            .normal
        case .codemap, .encodingDetection, .promptAccounting, .unspecified:
            .bulk
        }
    }

    private static func isForegroundWorkload(_ workloadClass: ContentReadWorkloadClass) -> Bool {
        workloadClass == .interactiveRead || workloadClass == .contentSearch
    }

    #if DEBUG
        func snapshotForTesting() -> Snapshot {
            let queuedOwners = Set(waiterStates.values.map(\.ownerID))
            let ownerLaneCount = queuedOwners.union(activePermitCountsByOwner.keys).count
            return Snapshot(
                capacity: capacity,
                maxQueuedWaiterCount: maxQueuedWaiterCount,
                activePermitCount: capacity - availablePermits,
                queuedWaiterCount: waiterStates.count,
                ownerLaneCount: ownerLaneCount,
                cancellationCount: cancellationCount,
                grantCount: grantCount,
                overloadCount: overloadCount,
                interactiveGrantCount: interactiveGrantCount,
                normalGrantCount: normalGrantCount,
                bulkGrantCount: bulkGrantCount,
                backgroundPermitLimit: backgroundPermitLimit,
                activeBackgroundPermitCount: activeBackgroundPermitCount,
                activeCodemapPermitCount: activeCodemapPermitCount,
                queuedCodemapWaiterCount: waiterStates.values.count(where: { $0.workloadClass == .codemap }),
                foregroundActivityCount: foregroundActivitiesByTokenID.count,
                foregroundActivityCountsByKind: Dictionary(
                    grouping: foregroundActivitiesByTokenID.values,
                    by: { $0 }
                ).mapValues(\.count),
                codemapGrantWhileForegroundCount: codemapGrantWhileForegroundCount
            )
        }
    #endif
}

extension FileSystemService {
    private static let contentReadWorkerLimit = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount))
    private static let contentReadWorkerLimiter = ContentReadAsyncLimiter(
        capacity: contentReadWorkerLimit,
        maxQueuedWaiterCount: 512
    )

    nonisolated static func withContentReadForegroundActivity<T>(
        kind: ContentReadForegroundActivityKind,
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await contentReadWorkerLimiter.withForegroundActivity(kind: kind, body)
    }

    nonisolated static func withCodeMapArtifactBuildPermit<T: Sendable>(
        ownerID: UUID,
        priority: TaskPriority,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await contentReadWorkerLimiter.withCodeMapArtifactBuildPermit(
            ownerID: ownerID,
            priority: priority,
            operation: operation
        )
    }

    #if DEBUG
        nonisolated static var contentReadWorkerLimitForTesting: Int {
            contentReadWorkerLimit
        }

        nonisolated static func contentReadWorkerLimiterSnapshotForTesting() async -> ContentReadAsyncLimiter.Snapshot {
            await contentReadWorkerLimiter.snapshotForTesting()
        }
    #endif

    func contentFingerprint(ofRelativePath relativePath: String) async throws -> FileContentFingerprint {
        #if DEBUG
            contentFingerprintRequestCountForTesting += 1
        #endif
        let request = try makeContentReadRequest(
            cacheKey: relativePath,
            chunkSize: 1_048_576,
            fileSizeLimit: 10_000_000,
            mode: .automatic,
            workloadClass: .contentSearch
        )
        return try await Task.detached(priority: Task.currentPriority) {
            try Self.validateContentFileForReading(request).fingerprint
        }.value
    }

    func loadValidatedContent(
        ofRelativePath relativePath: String,
        expectedFingerprint: FileContentFingerprint,
        workloadClass: ContentReadWorkloadClass = .contentSearch,
        schedulerOwnerID: UUID? = nil
    ) async throws -> ValidatedFileContentSnapshot {
        let request = try makeContentReadRequest(
            cacheKey: relativePath,
            chunkSize: 1_048_576,
            fileSizeLimit: 10_000_000,
            mode: .automatic,
            workloadClass: workloadClass,
            schedulerOwnerID: schedulerOwnerID
        )
        let result = try await performMeasuredContentReadOffActor(
            request,
            lifecycleCorrelation: EditFlowPerf.currentLifecycleCorrelation,
            expectedFingerprint: expectedFingerprint,
            requirePostReadValidation: true
        )
        try Task.checkCancellation()
        guard let acceptedFingerprint = result.fingerprint,
              acceptedFingerprint == expectedFingerprint
        else {
            throw FileContentValidationError.fingerprintChanged
        }
        commitContentReadResultIfCurrent(result, cacheKey: request.cacheKey)
        return ValidatedFileContentSnapshot(
            content: result.content,
            detectedEncodingRawValue: result.detectedEncodingRawValue,
            modificationDate: result.modificationDate ?? acceptedFingerprint.modificationDate,
            fingerprint: acceptedFingerprint
        )
    }

    func loadValidatedRawContent(
        ofRelativePath relativePath: String,
        expectedFingerprint: FileContentFingerprint? = nil,
        maximumBytes: Int64 = 10_000_000,
        workloadClass: ContentReadWorkloadClass = .codemap,
        schedulerOwnerID: UUID? = nil
    ) async throws -> ValidatedRawFileContentSnapshot {
        guard maximumBytes >= 0 else {
            throw FileSystemError.fileTooLarge
        }
        let request = try makeContentReadRequest(
            cacheKey: relativePath,
            chunkSize: 1_048_576,
            fileSizeLimit: maximumBytes,
            mode: .automatic,
            workloadClass: workloadClass,
            schedulerOwnerID: schedulerOwnerID
        )
        let result = try await Self.performRawContentReadOffActor(
            request,
            expectedFingerprint: expectedFingerprint
        )
        try Task.checkCancellation()
        return ValidatedRawFileContentSnapshot(
            data: result.data,
            modificationDate: result.modificationDate,
            fingerprint: result.fingerprint
        )
    }

    func loadContentPrefix(
        ofRelativePath relativePath: String,
        maximumBytes: Int,
        workloadClass: ContentReadWorkloadClass = .unspecified
    ) async throws -> FileContentPrefix? {
        guard maximumBytes > 0 else { return FileContentPrefix(content: "", truncated: true) }
        if Self.hasAlwaysBinaryExtension(relativePath) { return nil }
        let request = try makeContentReadRequest(
            cacheKey: relativePath,
            chunkSize: min(maximumBytes + 1, 1_048_576),
            fileSizeLimit: 10_000_000,
            mode: .automatic,
            workloadClass: workloadClass
        )
        let prefix = try await Self.performContentPrefixReadOffActor(request, maximumBytes: maximumBytes)
        try Task.checkCancellation()
        return prefix
    }

    func loadContent(
        ofRelativePath relativePath: String,
        workloadClass: ContentReadWorkloadClass = .unspecified
    ) async throws -> String? {
        let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.FileSystem.contentLoadEntered,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(workloadClass: workloadClass.rawValue, rootToken: diagnosticRootToken.uuidString)
        )
        let contentLoadState = EditFlowPerf.begin(
            EditFlowPerf.Stage.FileSystem.contentLoadTotal,
            EditFlowPerf.Dimensions(workloadClass: workloadClass.rawValue, rootToken: diagnosticRootToken.uuidString)
        )
        var contentLoadOutcome = "error"
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.FileSystem.contentLoadTotal,
                contentLoadState,
                EditFlowPerf.Dimensions(
                    outcome: contentLoadOutcome,
                    workloadClass: workloadClass.rawValue,
                    rootToken: diagnosticRootToken.uuidString
                )
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.FileSystem.contentLoadReturned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    outcome: contentLoadOutcome,
                    workloadClass: workloadClass.rawValue,
                    rootToken: diagnosticRootToken.uuidString
                )
            )
        }
        if Self.hasAlwaysBinaryExtension(relativePath) {
            contentLoadOutcome = "unavailable"
            return nil
        }

        let preparationState = EditFlowPerf.begin(
            EditFlowPerf.Stage.FileSystem.contentReadRequestPreparation,
            EditFlowPerf.Dimensions(workloadClass: workloadClass.rawValue, rootToken: diagnosticRootToken.uuidString)
        )
        let request: ContentReadRequest
        do {
            request = try makeContentReadRequest(
                cacheKey: relativePath,
                chunkSize: 1_048_576,
                fileSizeLimit: 10_000_000,
                mode: .automatic,
                workloadClass: workloadClass
            )
            EditFlowPerf.end(
                EditFlowPerf.Stage.FileSystem.contentReadRequestPreparation,
                preparationState,
                EditFlowPerf.Dimensions(outcome: "prepared", workloadClass: workloadClass.rawValue)
            )
        } catch {
            EditFlowPerf.end(
                EditFlowPerf.Stage.FileSystem.contentReadRequestPreparation,
                preparationState,
                EditFlowPerf.Dimensions(outcome: "error", workloadClass: workloadClass.rawValue)
            )
            throw error
        }
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.FileSystem.contentReadRequestPrepared,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(workloadClass: workloadClass.rawValue, rootToken: diagnosticRootToken.uuidString)
        )
        #if DEBUG
            if shouldUseSerialContentReadFallback {
                do {
                    let content = try await loadContentSerialForTesting(request)
                    contentLoadOutcome = Self.telemetryOutcomeForSerialFallback(content)
                    return content
                } catch {
                    contentLoadOutcome = error is CancellationError ? "cancelled" : "error"
                    throw error
                }
            }
        #endif
        let result: ContentReadResult
        do {
            result = try await performMeasuredContentReadOffActor(request, lifecycleCorrelation: lifecycleCorrelation)
        } catch {
            contentLoadOutcome = error is CancellationError ? "cancelled" : "error"
            throw error
        }
        do {
            try Task.checkCancellation()
        } catch {
            contentLoadOutcome = "cancelled"
            throw error
        }
        commitContentReadResultIfCurrent(result, cacheKey: request.cacheKey)
        contentLoadOutcome = result.telemetryOutcome.rawValue
        return result.content
    }

    /// For backward compatibility - delegates to the new implementation
    func loadContent(
        of url: URL,
        workloadClass: ContentReadWorkloadClass = .unspecified
    ) async throws -> String? {
        let relativePath = url.relativePath(from: URL(fileURLWithPath: path))
        return try await loadContent(ofRelativePath: relativePath, workloadClass: workloadClass)
    }

    func loadContentWithDate(
        ofRelativePath relativePath: String,
        workloadClass: ContentReadWorkloadClass = .unspecified
    ) async throws -> (content: String?, modificationDate: Date) {
        async let content = loadContent(ofRelativePath: relativePath, workloadClass: workloadClass)
        async let modDate = getFileModificationDate(atRelativePath: relativePath)
        return try await (content, modDate)
    }

    /// Loads large files in chunks, detecting encoding on-the-fly.
    ///
    /// Order of precedence:
    ///   1. BOM (cheap, deterministic)
    ///   2. Cuchardet’s streaming detector
    ///   3. Default to UTF-8          ← no further fall-backs
    func loadEntireFileContentOptimized(
        ofRelativePath relativePath: String,
        chunkSize: Int = 1_048_576, // 1 MB
        fileSizeLimit: Int64 = 10_000_000, // 10 MB
        workloadClass: ContentReadWorkloadClass = .unspecified
    ) async throws -> String? {
        let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.FileSystem.contentLoadEntered,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(workloadClass: workloadClass.rawValue, rootToken: diagnosticRootToken.uuidString)
        )
        let contentLoadState = EditFlowPerf.begin(
            EditFlowPerf.Stage.FileSystem.contentLoadTotal,
            EditFlowPerf.Dimensions(workloadClass: workloadClass.rawValue, rootToken: diagnosticRootToken.uuidString)
        )
        var contentLoadOutcome = "error"
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.FileSystem.contentLoadTotal,
                contentLoadState,
                EditFlowPerf.Dimensions(
                    outcome: contentLoadOutcome,
                    workloadClass: workloadClass.rawValue,
                    rootToken: diagnosticRootToken.uuidString
                )
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.FileSystem.contentLoadReturned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    outcome: contentLoadOutcome,
                    workloadClass: workloadClass.rawValue,
                    rootToken: diagnosticRootToken.uuidString
                )
            )
        }
        if Self.hasAlwaysBinaryExtension(relativePath) {
            contentLoadOutcome = "unavailable"
            return nil
        }

        let preparationState = EditFlowPerf.begin(
            EditFlowPerf.Stage.FileSystem.contentReadRequestPreparation,
            EditFlowPerf.Dimensions(workloadClass: workloadClass.rawValue, rootToken: diagnosticRootToken.uuidString)
        )
        let request: ContentReadRequest
        do {
            request = try makeContentReadRequest(
                cacheKey: relativePath,
                chunkSize: chunkSize,
                fileSizeLimit: fileSizeLimit,
                mode: .streamed,
                workloadClass: workloadClass
            )
            EditFlowPerf.end(
                EditFlowPerf.Stage.FileSystem.contentReadRequestPreparation,
                preparationState,
                EditFlowPerf.Dimensions(outcome: "prepared", workloadClass: workloadClass.rawValue)
            )
        } catch {
            EditFlowPerf.end(
                EditFlowPerf.Stage.FileSystem.contentReadRequestPreparation,
                preparationState,
                EditFlowPerf.Dimensions(outcome: "error", workloadClass: workloadClass.rawValue)
            )
            throw error
        }
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.FileSystem.contentReadRequestPrepared,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(workloadClass: workloadClass.rawValue, rootToken: diagnosticRootToken.uuidString)
        )
        #if DEBUG
            if shouldUseSerialContentReadFallback {
                do {
                    let content = try await loadEntireFileContentOptimizedSerialForTesting(request)
                    contentLoadOutcome = Self.telemetryOutcomeForSerialFallback(content)
                    return content
                } catch {
                    contentLoadOutcome = error is CancellationError ? "cancelled" : "error"
                    throw error
                }
            }
        #endif
        let result: ContentReadResult
        do {
            result = try await performMeasuredContentReadOffActor(request, lifecycleCorrelation: lifecycleCorrelation)
        } catch {
            contentLoadOutcome = error is CancellationError ? "cancelled" : "error"
            throw error
        }
        do {
            try Task.checkCancellation()
        } catch {
            contentLoadOutcome = "cancelled"
            throw error
        }
        commitContentReadResultIfCurrent(result, cacheKey: request.cacheKey)
        contentLoadOutcome = result.telemetryOutcome.rawValue
        return result.content
    }

    #if DEBUG
        private nonisolated static func telemetryOutcomeForSerialFallback(_ content: String?) -> String {
            guard let content else { return ContentReadTelemetryOutcome.unavailable.rawValue }
            return content.hasPrefix("[File too large: ")
                ? ContentReadTelemetryOutcome.oversized.rawValue
                : ContentReadTelemetryOutcome.loaded.rawValue
        }
    #endif

    private func makeContentReadRequest(
        cacheKey: String,
        chunkSize: Int,
        fileSizeLimit: Int64,
        mode: ContentReadMode,
        workloadClass: ContentReadWorkloadClass,
        schedulerOwnerID: UUID? = nil
    ) throws -> ContentReadRequest {
        let contentLoadState = EditFlowPerf.begin(EditFlowPerf.Stage.FileSystem.contentLoadActorBody)
        defer { EditFlowPerf.end(EditFlowPerf.Stage.FileSystem.contentLoadActorBody, contentLoadState) }

        guard !cacheKey.hasPrefix("/"), !StandardizedPath.containsNUL(cacheKey) else {
            throw FileSystemError.invalidRelativePath
        }
        let relativePath = StandardizedPath.relative(cacheKey)
        guard !relativePath.isEmpty, relativePath != "..", !relativePath.hasPrefix("../") else {
            throw FileSystemError.invalidRelativePath
        }
        let absolutePath = StandardizedPath.join(
            standardizedRoot: standardizedRootPath,
            standardizedRelativePath: relativePath
        )
        guard absolutePath != standardizedRootPath,
              StandardizedPath.isDescendant(absolutePath, of: standardizedRootPath)
        else {
            throw FileSystemError.invalidRelativePath
        }
        #if DEBUG
            return ContentReadRequest(
                cacheKey: cacheKey,
                relativePath: relativePath,
                absolutePath: absolutePath,
                standardizedRootPath: standardizedRootPath,
                canonicalRootPath: canonicalRootPath,
                skipSymlinks: skipSymlinks,
                chunkSize: chunkSize,
                fileSizeLimit: fileSizeLimit,
                mode: mode,
                workloadClass: workloadClass,
                schedulerOwnerID: schedulerOwnerID ?? diagnosticRootToken,
                chunkReadHandler: contentReadChunkHandler
            )
        #else
            return ContentReadRequest(
                cacheKey: cacheKey,
                relativePath: relativePath,
                absolutePath: absolutePath,
                standardizedRootPath: standardizedRootPath,
                canonicalRootPath: canonicalRootPath,
                skipSymlinks: skipSymlinks,
                chunkSize: chunkSize,
                fileSizeLimit: fileSizeLimit,
                mode: mode,
                workloadClass: workloadClass,
                schedulerOwnerID: schedulerOwnerID ?? diagnosticRootToken
            )
        #endif
    }

    private func performMeasuredContentReadOffActor(
        _ request: ContentReadRequest,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?,
        expectedFingerprint: FileContentFingerprint? = nil,
        requirePostReadValidation: Bool = false
    ) async throws -> ContentReadResult {
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.FileSystem.contentReadOffActorScheduled,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(workloadClass: request.workloadClass.rawValue, rootToken: diagnosticRootToken.uuidString)
        )
        let offActorState = EditFlowPerf.begin(
            EditFlowPerf.Stage.FileSystem.contentReadOffActorAwait,
            EditFlowPerf.Dimensions(workloadClass: request.workloadClass.rawValue, rootToken: diagnosticRootToken.uuidString)
        )
        do {
            let result = try await Self.performContentReadOffActor(
                request,
                expectedFingerprint: expectedFingerprint,
                requirePostReadValidation: requirePostReadValidation
            )
            EditFlowPerf.end(
                EditFlowPerf.Stage.FileSystem.contentReadOffActorAwait,
                offActorState,
                EditFlowPerf.Dimensions(outcome: result.telemetryOutcome.rawValue, workloadClass: request.workloadClass.rawValue)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.FileSystem.contentReadWorkerReturned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    outcome: result.telemetryOutcome.rawValue,
                    workloadClass: request.workloadClass.rawValue,
                    rootToken: diagnosticRootToken.uuidString
                )
            )
            return result
        } catch {
            let outcome = error is CancellationError ? "cancelled" : "error"
            EditFlowPerf.end(
                EditFlowPerf.Stage.FileSystem.contentReadOffActorAwait,
                offActorState,
                EditFlowPerf.Dimensions(outcome: outcome, workloadClass: request.workloadClass.rawValue)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.FileSystem.contentReadWorkerReturned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    outcome: outcome,
                    workloadClass: request.workloadClass.rawValue,
                    rootToken: diagnosticRootToken.uuidString
                )
            )
            throw error
        }
    }

    private func commitContentReadResultIfCurrent(_ result: ContentReadResult, cacheKey: String) {
        guard let detectedEncoding = result.detectedEncoding,
              let fingerprint = result.fingerprint
        else { return }
        let contentLoadState = EditFlowPerf.begin(EditFlowPerf.Stage.FileSystem.contentLoadActorBody)
        defer { EditFlowPerf.end(EditFlowPerf.Stage.FileSystem.contentLoadActorBody, contentLoadState) }

        guard (try? FileContentFingerprintReader.fingerprint(atPath: result.absolutePath)) == fingerprint else { return }
        encodingMap[cacheKey] = detectedEncoding
    }

    private nonisolated static func performContentPrefixReadOffActor(
        _ request: ContentReadRequest,
        maximumBytes: Int
    ) async throws -> FileContentPrefix? {
        let workerPriority = Task.currentPriority
        return try await contentReadWorkerLimiter.withPermit(
            workloadClass: request.workloadClass,
            ownerID: request.schedulerOwnerID
        ) {
            try await withThrowingTaskGroup(of: FileContentPrefix?.self) { group in
                group.addTask(priority: workerPriority) {
                    try await readContentPrefixFromDisk(request, maximumBytes: maximumBytes)
                }
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return result
            }
        }
    }

    private nonisolated static func performContentReadOffActor(
        _ request: ContentReadRequest,
        expectedFingerprint: FileContentFingerprint? = nil,
        requirePostReadValidation: Bool = false
    ) async throws -> ContentReadResult {
        let workerPriority = Task.currentPriority
        return try await contentReadWorkerLimiter.withPermit(
            workloadClass: request.workloadClass,
            ownerID: request.schedulerOwnerID
        ) {
            try await withThrowingTaskGroup(of: ContentReadResult.self) { group in
                group.addTask(priority: workerPriority) {
                    try await readContentFromDisk(
                        request,
                        expectedFingerprint: expectedFingerprint,
                        requirePostReadValidation: requirePostReadValidation
                    )
                }
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return result
            }
        }
    }

    private nonisolated static func performRawContentReadOffActor(
        _ request: ContentReadRequest,
        expectedFingerprint: FileContentFingerprint?
    ) async throws -> RawContentReadResult {
        let workerPriority = Task.currentPriority
        return try await contentReadWorkerLimiter.withPermit(
            workloadClass: request.workloadClass,
            ownerID: request.schedulerOwnerID
        ) {
            try await withThrowingTaskGroup(of: RawContentReadResult.self) { group in
                group.addTask(priority: workerPriority) {
                    try await readRawContentFromDisk(
                        request,
                        expectedFingerprint: expectedFingerprint
                    )
                }
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return result
            }
        }
    }

    private nonisolated static func readContentPrefixFromDisk(
        _ request: ContentReadRequest,
        maximumBytes: Int
    ) async throws -> FileContentPrefix? {
        if hasAlwaysBinaryExtension(request.relativePath) {
            return nil
        }
        try Task.checkCancellation()
        let requestedByteCount = max(0, maximumBytes)
        let validated = try validateContentFileForReading(request)
        if validated.fileSize <= Int64(requestedByteCount) {
            let result = try await readAutomaticContent(
                request,
                validated: validated,
                requireStableIdentity: false
            )
            return result.content.map { FileContentPrefix(content: $0, truncated: false) }
        }

        let handle = try openValidatedContentHandle(
            request,
            validated: validated,
            requireStableIdentity: false
        )
        defer { try? handle.close() }

        try await runContentReadChunkHook(request)
        let data = try handle.read(upToCount: requestedByteCount + 1) ?? Data()
        try Task.checkCancellation()
        guard !data.isEmpty else {
            return FileContentPrefix(content: "", truncated: false)
        }

        let probe = data.prefix(min(data.count, 8192))
        if isProbablyBinary(probe) {
            return nil
        }

        let wasTruncated = data.count > requestedByteCount || validated.fileSize > Int64(requestedByteCount)
        var prefixData = Data(data.prefix(requestedByteCount))
        let encoding: String.Encoding = detectBOMEncoding(in: prefixData) ?? detectEncodingFull(prefixData)
        while !prefixData.isEmpty {
            if let decoded = String(data: prefixData, encoding: encoding) {
                return FileContentPrefix(content: decoded, truncated: wasTruncated)
            }
            prefixData.removeLast()
        }
        return FileContentPrefix(content: "", truncated: wasTruncated)
    }

    private nonisolated static func readContentFromDisk(
        _ request: ContentReadRequest,
        expectedFingerprint: FileContentFingerprint? = nil,
        requirePostReadValidation: Bool = false
    ) async throws -> ContentReadResult {
        let workerBodyState = EditFlowPerf.begin(
            EditFlowPerf.Stage.FileSystem.contentReadWorkerBody,
            EditFlowPerf.Dimensions(
                workloadClass: request.workloadClass.rawValue,
                contentSource: "disk"
            )
        )
        var workerBodyOutcome = "failed"
        var workerBodyFileBytes: Int?
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.FileSystem.contentReadWorkerBody,
                workerBodyState,
                EditFlowPerf.Dimensions(
                    outcome: workerBodyOutcome,
                    fileBytes: workerBodyFileBytes,
                    workloadClass: request.workloadClass.rawValue,
                    contentSource: "disk"
                )
            )
        }

        do {
            if hasAlwaysBinaryExtension(request.relativePath), !requirePostReadValidation {
                workerBodyOutcome = ContentReadTelemetryOutcome.unavailable.rawValue
                return ContentReadResult(
                    absolutePath: request.absolutePath,
                    content: nil,
                    detectedEncodingRawValue: nil,
                    modificationDate: nil,
                    fingerprint: nil,
                    telemetryOutcome: .unavailable
                )
            }

            try Task.checkCancellation()
            let validated = try validateContentFileForReading(request)
            if let expectedFingerprint, validated.fingerprint != expectedFingerprint {
                throw FileContentValidationError.fingerprintChanged
            }
            workerBodyFileBytes = telemetryFileBytes(validated.fileSize)
            MCPToolWorkCountDiagnostics.recordReadFileDiskRead(
                bytes: workerBodyFileBytes ?? 0,
                decodeMicroseconds: 0
            )
            let result: ContentReadResult = switch request.mode {
            case .automatic:
                try await readAutomaticContent(
                    request,
                    validated: validated,
                    requireStableIdentity: requirePostReadValidation
                )
            case .streamed:
                try await readStreamedContent(
                    request,
                    validated: validated,
                    requireStableIdentity: requirePostReadValidation
                )
            }
            if requirePostReadValidation {
                let postReadFingerprint = try FileContentFingerprintReader.fingerprint(atPath: request.absolutePath)
                guard postReadFingerprint == validated.fingerprint else {
                    throw FileContentValidationError.fingerprintChanged
                }
            }
            workerBodyOutcome = result.telemetryOutcome.rawValue
            return result
        } catch {
            workerBodyOutcome = error is CancellationError ? "cancelled" : "failed"
            throw error
        }
    }

    private nonisolated static func readRawContentFromDisk(
        _ request: ContentReadRequest,
        expectedFingerprint: FileContentFingerprint?
    ) async throws -> RawContentReadResult {
        do {
            try Task.checkCancellation()
            let validated = try validateContentFileForReading(request)
            if let expectedFingerprint, validated.fingerprint != expectedFingerprint {
                throw FileContentValidationError.fingerprintChanged
            }

            let handle = try openValidatedContentHandle(
                request,
                validated: validated,
                requireStableIdentity: true
            )
            defer { try? handle.close() }
            guard try validateContentFileForReading(request).fingerprint == validated.fingerprint else {
                throw FileContentValidationError.fingerprintChanged
            }

            guard validated.fileSize <= request.fileSizeLimit else {
                throw FileSystemError.fileTooLarge
            }
            let data: Data = switch try await readBoundedData(request, handle: handle) {
            case let .data(data):
                data
            case .tooLarge:
                throw FileSystemError.fileTooLarge
            }
            try Task.checkCancellation()
            guard try FileContentFingerprintReader.fingerprint(fileDescriptor: handle.fileDescriptor)
                == validated.fingerprint
            else {
                throw FileContentValidationError.fingerprintChanged
            }
            guard try validateContentFileForReading(request).fingerprint == validated.fingerprint else {
                throw FileContentValidationError.fingerprintChanged
            }

            return RawContentReadResult(
                data: data,
                modificationDate: validated.modificationDate,
                fingerprint: validated.fingerprint
            )
        } catch {
            throw error
        }
    }

    private nonisolated static func telemetryFileBytes(_ fileSize: Int64) -> Int {
        Int(clamping: max(0, fileSize))
    }

    private nonisolated static func readAutomaticContent(
        _ request: ContentReadRequest,
        validated: ValidatedContentFile,
        requireStableIdentity: Bool
    ) async throws -> ContentReadResult {
        let handle = try openValidatedContentHandle(
            request,
            validated: validated,
            requireStableIdentity: requireStableIdentity
        )
        defer { try? handle.close() }

        let skipProbe = shouldSkipBinaryProbe(url: validated.url)
        if !skipProbe {
            try await runContentReadChunkHook(request)
            let probe = try handle.read(upToCount: 8192) ?? Data()
            try Task.checkCancellation()
            if isProbablyBinary(probe) {
                return try validateOpenContentHandle(
                    handle,
                    validated: validated,
                    result: noEncodingContentReadResult(request, validated: validated, content: nil),
                    required: requireStableIdentity
                )
            }
            try handle.seek(toOffset: 0)
        }

        if validated.fileSize < 2_000_000 {
            let data: Data
            switch try await readBoundedData(request, handle: handle) {
            case let .data(readData):
                data = readData
            case let .tooLarge(observedByteCount):
                return try validateOpenContentHandle(
                    handle,
                    validated: validated,
                    result: oversizedContentReadResult(request, validated: validated, observedByteCount: observedByteCount),
                    required: requireStableIdentity
                )
            }
            let decodeStart = DispatchTime.now().uptimeNanoseconds
            let detected = try decodeSmallFileData(data)
            let decodeEnd = DispatchTime.now().uptimeNanoseconds
            MCPToolWorkCountDiagnostics.recordReadFileDiskRead(
                bytes: 0,
                decodeMicroseconds: Int(clamping: decodeEnd >= decodeStart ? (decodeEnd - decodeStart) / 1000 : 0)
            )
            try Task.checkCancellation()
            return try validateOpenContentHandle(
                handle,
                validated: validated,
                result: ContentReadResult(
                    absolutePath: request.absolutePath,
                    content: detected.string,
                    detectedEncodingRawValue: detected.encoding.rawValue,
                    modificationDate: validated.modificationDate,
                    fingerprint: validated.fingerprint,
                    telemetryOutcome: .loaded
                ),
                required: requireStableIdentity
            )
        }
        return try await readStreamedContent(
            request,
            validated: validated,
            handle: handle,
            requireStableIdentity: requireStableIdentity
        )
    }

    private nonisolated static func readStreamedContent(
        _ request: ContentReadRequest,
        validated: ValidatedContentFile,
        requireStableIdentity: Bool
    ) async throws -> ContentReadResult {
        if validated.fileSize > request.fileSizeLimit {
            return noEncodingContentReadResult(
                request,
                validated: validated,
                content: "[File too large: \(validated.fileSize) bytes]",
                telemetryOutcome: .oversized
            )
        }

        let handle = try openValidatedContentHandle(
            request,
            validated: validated,
            requireStableIdentity: requireStableIdentity
        )
        defer { try? handle.close() }
        return try await readStreamedContent(
            request,
            validated: validated,
            handle: handle,
            requireStableIdentity: requireStableIdentity
        )
    }

    private nonisolated static func readStreamedContent(
        _ request: ContentReadRequest,
        validated: ValidatedContentFile,
        handle: FileHandle,
        requireStableIdentity: Bool
    ) async throws -> ContentReadResult {
        let skipProbe = shouldSkipBinaryProbe(url: validated.url)
        var fullData = Data()
        fullData.reserveCapacity(Int(validated.fileSize))
        let detector = CharacterEncodingDetector()

        try await runContentReadChunkHook(request)
        let initialData = try handle.read(upToCount: request.chunkSize) ?? Data()
        try Task.checkCancellation()
        if !skipProbe, isProbablyBinary(initialData) {
            return try validateOpenContentHandle(
                handle,
                validated: validated,
                result: noEncodingContentReadResult(request, validated: validated, content: nil),
                required: requireStableIdentity
            )
        }
        if Int64(initialData.count) > request.fileSizeLimit {
            return try validateOpenContentHandle(
                handle,
                validated: validated,
                result: oversizedContentReadResult(request, validated: validated, observedByteCount: Int64(initialData.count)),
                required: requireStableIdentity
            )
        }
        fullData.append(initialData)
        _ = detector.analyzeNextChunk(initialData)

        while true {
            try await runContentReadChunkHook(request)
            let next = try handle.read(upToCount: request.chunkSize) ?? Data()
            try Task.checkCancellation()
            if next.isEmpty { break }
            let observedByteCount = Int64(fullData.count) + Int64(next.count)
            if observedByteCount > request.fileSizeLimit {
                return try validateOpenContentHandle(
                    handle,
                    validated: validated,
                    result: oversizedContentReadResult(request, validated: validated, observedByteCount: observedByteCount),
                    required: requireStableIdentity
                )
            }
            fullData.append(next)
            _ = detector.analyzeNextChunk(next)

            if fullData.count > 100_000_000 {
                fullData.append("\n[Truncated large file...]\n".data(using: .utf8)!)
                break
            }
        }

        let encoding: String.Encoding = if let bom = detectBOMEncoding(in: initialData) {
            bom
        } else if let label = detector.finish() {
            .init(ianaCharsetName: label)
        } else {
            .utf8
        }
        let decodeStart = DispatchTime.now().uptimeNanoseconds
        let decodedContent = String(data: fullData, encoding: encoding) ?? "[Binary data or unknown encoding]"
        let decodeEnd = DispatchTime.now().uptimeNanoseconds
        MCPToolWorkCountDiagnostics.recordReadFileDiskRead(
            bytes: 0,
            decodeMicroseconds: Int(clamping: decodeEnd >= decodeStart ? (decodeEnd - decodeStart) / 1000 : 0)
        )
        return try validateOpenContentHandle(
            handle,
            validated: validated,
            result: ContentReadResult(
                absolutePath: request.absolutePath,
                content: decodedContent,
                detectedEncodingRawValue: encoding.rawValue,
                modificationDate: validated.modificationDate,
                fingerprint: validated.fingerprint,
                telemetryOutcome: .loaded
            ),
            required: requireStableIdentity
        )
    }

    private nonisolated static func validateContentFileForReading(_ request: ContentReadRequest) throws -> ValidatedContentFile {
        let standardizedAbsolutePath = StandardizedPath.absolute(request.absolutePath)
        guard standardizedAbsolutePath != request.standardizedRootPath,
              StandardizedPath.isDescendant(standardizedAbsolutePath, of: request.standardizedRootPath)
        else {
            throw FileSystemError.invalidRelativePath
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: standardizedAbsolutePath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw FileSystemError.fileNotFound
        }
        let url = URL(fileURLWithPath: standardizedAbsolutePath)
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            if values.isSymbolicLink == true { throw FileSystemError.invalidRelativePath }
            if values.isRegularFile == false { throw FileSystemError.invalidRelativePath }
        }
        if request.skipSymlinks, pathContainsSymlinkComponent(request.relativePath, rootURL: URL(fileURLWithPath: request.standardizedRootPath)) {
            throw FileSystemError.invalidRelativePath
        }

        let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard StandardizedPath.isDescendant(canonicalPath, of: request.canonicalRootPath) else {
            throw FileSystemError.invalidRelativePath
        }
        let fingerprint = try FileContentFingerprintReader.fingerprint(atPath: standardizedAbsolutePath)
        return ValidatedContentFile(
            url: url,
            fileSize: fingerprint.byteSize,
            modificationDate: fingerprint.modificationDate,
            fingerprint: fingerprint
        )
    }

    private nonisolated static func readBoundedData(
        _ request: ContentReadRequest,
        handle: FileHandle
    ) async throws -> BoundedDataReadResult {
        var data = Data()
        while true {
            try await runContentReadChunkHook(request)
            let next = try handle.read(upToCount: request.chunkSize) ?? Data()
            try Task.checkCancellation()
            if next.isEmpty { break }
            let observedByteCount = Int64(data.count) + Int64(next.count)
            if observedByteCount > request.fileSizeLimit {
                return .tooLarge(observedByteCount: observedByteCount)
            }
            data.append(next)
        }
        return .data(data)
    }

    private nonisolated static func openValidatedContentHandle(
        _ request: ContentReadRequest,
        validated: ValidatedContentFile,
        requireStableIdentity: Bool
    ) throws -> FileHandle {
        let handle = try FileContentFingerprintReader.openReadOnlyFileHandle(atPath: request.absolutePath)
        do {
            if requireStableIdentity {
                guard try FileContentFingerprintReader.fingerprint(fileDescriptor: handle.fileDescriptor) == validated.fingerprint else {
                    throw FileContentValidationError.fingerprintChanged
                }
            }
            return handle
        } catch {
            try? handle.close()
            throw error
        }
    }

    private nonisolated static func validateOpenContentHandle(
        _ handle: FileHandle,
        validated: ValidatedContentFile,
        result: ContentReadResult,
        required: Bool
    ) throws -> ContentReadResult {
        if required {
            guard try FileContentFingerprintReader.fingerprint(fileDescriptor: handle.fileDescriptor) == validated.fingerprint else {
                throw FileContentValidationError.fingerprintChanged
            }
        }
        return result
    }

    private nonisolated static func oversizedContentReadResult(
        _ request: ContentReadRequest,
        validated: ValidatedContentFile,
        observedByteCount: Int64
    ) -> ContentReadResult {
        noEncodingContentReadResult(
            request,
            validated: validated,
            content: "[File too large: \(observedByteCount) bytes]",
            telemetryOutcome: .oversized
        )
    }

    private nonisolated static func noEncodingContentReadResult(
        _ request: ContentReadRequest,
        validated: ValidatedContentFile,
        content: String?,
        telemetryOutcome: ContentReadTelemetryOutcome = .unavailable
    ) -> ContentReadResult {
        ContentReadResult(
            absolutePath: request.absolutePath,
            content: content,
            detectedEncodingRawValue: nil,
            modificationDate: validated.modificationDate,
            fingerprint: validated.fingerprint,
            telemetryOutcome: telemetryOutcome
        )
    }

    private nonisolated static func shouldSkipBinaryProbe(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return alwaysTextExtensions.contains(ext)
            || (ext.isEmpty && alwaysTextFilenames.contains(url.lastPathComponent.lowercased()))
    }

    private nonisolated static func hasAlwaysBinaryExtension(_ relativePath: String) -> Bool {
        let ext = ((relativePath as NSString).pathExtension).lowercased()
        return !ext.isEmpty && alwaysBinaryExtensions.contains(ext)
    }

    private nonisolated static func pathContainsSymlinkComponent(_ relativePath: String, rootURL: URL) -> Bool {
        var current = rootURL
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component))
            if ((try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false) == true {
                return true
            }
        }
        return false
    }

    private nonisolated static func decodeSmallFileData(_ data: Data) throws -> DetectedText {
        guard let detected = decodeWorkspaceAutomaticV1(data) else {
            throw FileSystemError.failedToReadFile
        }
        return detected
    }

    private nonisolated static func runContentReadChunkHook(_ request: ContentReadRequest) async throws {
        try Task.checkCancellation()
        #if DEBUG
            if let chunkReadHandler = request.chunkReadHandler {
                await chunkReadHandler(request.relativePath)
            }
        #endif
        try Task.checkCancellation()
    }

    #if DEBUG
        private var shouldUseSerialContentReadFallback: Bool {
            isTestMode || fileManagerOverride != nil
        }

        private func loadContentSerialForTesting(_ request: ContentReadRequest) async throws -> String? {
            let contentLoadState = EditFlowPerf.begin(EditFlowPerf.Stage.FileSystem.contentLoadActorBody)
            defer { EditFlowPerf.end(EditFlowPerf.Stage.FileSystem.contentLoadActorBody, contentLoadState) }

            let fm = fm
            guard fm.fileExists(atPath: request.absolutePath, isDirectory: nil) else {
                throw FileSystemError.fileNotFound
            }
            let attributes = try fm.attributesOfItem(atPath: request.absolutePath)
            let fileSize = attributes[.size] as? Int64 ?? 0
            let url = URL(fileURLWithPath: request.absolutePath)
            let skipProbe = Self.shouldSkipBinaryProbe(url: url)
            if !skipProbe, let handle = try? FileHandle(forReadingFrom: url) {
                let probe = try handle.read(upToCount: 8192) ?? Data()
                try? handle.close()
                if Self.isProbablyBinary(probe) { return nil }
            }
            if fileSize < 2_000_000 {
                let detected = try readDataAndDetectEncoding(request.absolutePath)
                encodingMap[request.cacheKey] = detected.encoding
                return detected.string
            }
            return try await loadEntireFileContentOptimizedSerialForTesting(request)
        }

        private func loadEntireFileContentOptimizedSerialForTesting(_ request: ContentReadRequest) async throws -> String? {
            let contentLoadState = EditFlowPerf.begin(EditFlowPerf.Stage.FileSystem.contentLoadActorBody)
            defer { EditFlowPerf.end(EditFlowPerf.Stage.FileSystem.contentLoadActorBody, contentLoadState) }

            let fm = fm
            guard fm.fileExists(atPath: request.absolutePath, isDirectory: nil) else {
                throw FileSystemError.fileNotFound
            }
            let attributes = try fm.attributesOfItem(atPath: request.absolutePath)
            let fileSize = attributes[.size] as? Int64 ?? 0
            if fileSize > request.fileSizeLimit {
                return "[File too large: \(fileSize) bytes]"
            }

            let url = URL(fileURLWithPath: request.absolutePath)
            let skipProbe = Self.shouldSkipBinaryProbe(url: url)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var fullData = Data()
            fullData.reserveCapacity(Int(fileSize))
            let detector = CharacterEncodingDetector()
            let initialData = try handle.read(upToCount: request.chunkSize) ?? Data()
            if !skipProbe, Self.isProbablyBinary(initialData) { return nil }
            fullData.append(initialData)
            _ = detector.analyzeNextChunk(initialData)
            try Task.checkCancellation()

            while true {
                let next = try handle.read(upToCount: request.chunkSize) ?? Data()
                if next.isEmpty { break }
                fullData.append(next)
                _ = detector.analyzeNextChunk(next)
                if fullData.count > 100_000_000 {
                    fullData.append("\n[Truncated large file...]\n".data(using: .utf8)!)
                    break
                }
                try Task.checkCancellation()
            }

            let encoding: String.Encoding = if let bom = Self.detectBOMEncoding(in: initialData) {
                bom
            } else if let label = detector.finish() {
                .init(ianaCharsetName: label)
            } else {
                .utf8
            }
            encodingMap[request.cacheKey] = encoding
            return String(data: fullData, encoding: encoding) ?? "[Binary data or unknown encoding]"
        }
    #endif

    /// Attempt to decode with all post‑UTF‑8 fall‑backs, including region‑specific ones.
    func tryDecodeWithFallbackEncodings(_ data: Data) -> String? {
        for enc in Self.orderedFallbackEncodings + Self.regionSpecificEncodings {
            if let s = String(data: data, encoding: enc) { return s }
        }
        return nil
    }

    /// Detect the most probable encoding from an initial data slice.
    ///
    /// Fast-path order:
    ///   1. Byte-order-mark (BOM)
    ///   2. Cuchardet on the same bytes
    ///   3. Strict UTF-8
    ///   4. Western single-byte fall-backs
    ///   5. Heuristic UTF-16 without BOM
    ///   6. Region-specific legacies
    func detectEncodingForInitialChunk(initialData: Data) throws -> String.Encoding {
        guard !initialData.isEmpty else { return .utf8 }

        // 1) Honor BOM immediately
        if let bomEncoding = Self.detectBOMEncoding(in: initialData) {
            return bomEncoding
        }

        // 2) Cuchardet (fast – O(n) on the *same* bytes)
        if let label = initialData.detectedCharacterEncoding {
            return .init(ianaCharsetName: label)
        }

        // 3) UTF-8 strict
        if String(data: initialData, encoding: .utf8) != nil {
            return .utf8
        }

        // 4) Western single-byte encodings
        for enc in Self.orderedFallbackEncodings where String(data: initialData, encoding: enc) != nil {
            return enc
        }

        // 5) Heuristic UTF-16 without BOM
        if Self.looksLikeUTF16(initialData) {
            for enc in [String.Encoding.utf16LittleEndian, .utf16BigEndian]
                where String(data: initialData, encoding: enc) != nil
            {
                return enc
            }
        }

        // 6) Region-specific encodings
        for enc in Self.regionSpecificEncodings where String(data: initialData, encoding: enc) != nil {
            return enc
        }

        // Fallback to UTF-8 with replacement
        return .utf8
    }

    /// Example approach if you want a standalone data-based detection
    func detectFileEncodingFromData(_ data: Data) async throws -> String.Encoding {
        // 1) BOM check
        if let bom = Self.detectBOMEncoding(in: data) { return bom }

        // 2) UTF‑8 strict
        if String(data: data, encoding: .utf8) != nil { return .utf8 }

        // 3–4) CP‑1252 / Mac Roman
        for enc in Self.orderedFallbackEncodings where String(data: data, encoding: enc) != nil {
            return enc
        }

        // 5) UTF‑16 heuristic without BOM
        if Self.looksLikeUTF16(data) {
            // fully qualify to String.Encoding
            for enc in [String.Encoding.utf16LittleEndian, String.Encoding.utf16BigEndian]
                where String(data: data, encoding: enc) != nil
            {
                return enc
            }
        }

        // 6) Region‑specific encodings
        for enc in Self.regionSpecificEncodings where String(data: data, encoding: enc) != nil {
            return enc
        }

        // Last‑resort default
        return .utf8
    }

    // MARK: - Binary detection helpers

    /// ─────────────────────────────────────────────────────────────────────────────
    /// Binary detection heuristic (Git-style, UTF-8 tolerant)
    ///
    /// • Any NUL byte → binary
    /// • Control bytes 0x00–0x1F **except** TAB/LF/CR
    /// • If ≥ 30 % of the bytes in the sample are control bytes → binary
    static func isProbablyBinary(_ data: Data, sampleSize: Int = 8192) -> Bool {
        guard !data.isEmpty else { return false }
        let sample = data.prefix(sampleSize)

        // Immediate NUL check
        if sample.contains(0) { return true }

        var ctrl = 0
        var printableOrUtf8 = 0

        for byte in sample {
            switch byte {
            case 0x09, 0x0A, 0x0D, 0x20 ... 0x7E: // HT, LF, CR, printable ASCII
                printableOrUtf8 += 1
            case 0x01 ... 0x08, 0x0B ... 0x0C, 0x0E ... 0x1F: // Other ASCII control chars
                ctrl += 1
            default: // 0x80–0xFF → UTF-8 part or extended ASCII
                printableOrUtf8 += 1
            }
        }

        let total = ctrl + printableOrUtf8
        guard total > 0 else { return false }
        return Double(ctrl) / Double(total) > 0.30
    }

    // MARK: - Encoding detection helpers & priority tables

    /// Encodings to try **after** UTF‑8 fails, in the exact order mandated
    /// by the research note: Windows‑1252 → Mac Roman → UTF‑16 (LE/BE)
    static let orderedFallbackEncodings: [String.Encoding] = [
        .windowsCP1252,
        .macOSRoman
    ]

    /// Optional, low‑priority locale‑specific single‑byte encodings
    static let regionSpecificEncodings: [String.Encoding] = [
        .shiftJIS, .japaneseEUC, .iso2022JP, // Japanese
        // Mainland‑China GB18030
        String.Encoding(
            rawValue:
            CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        ),
        // Traditional‑Chinese Big5
        String.Encoding(
            rawValue:
            CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue)
            )
        ),
        .windowsCP1251, .isoLatin2 // Cyrillic / Central‑Europe
    ]

    // MARK: - Extension / filename whitelists

    /// Extensions that are always treated as binary; we short-circuit before any filesystem queries.
    static let alwaysBinaryExtensions: Set<String> = [
        // ── Video ───────────────────────────────────────────────────
        "mp4", "m4v", "mov", "avi", "mkv", "webm", "flv", "wmv", "mpeg", "mpg", "m2ts", "mts", "3gp", "3g2", "ogv",
        "asf", "rm", "rmvb", "vob", "ogm", "f4v", "mpe", "m1v", "m2v", "divx", "xvid", "dv",
        // ── Audio ───────────────────────────────────────────────────
        "wav", "aiff", "aif", "flac", "ogg", "oga", "opus", "m4a", "aac", "mp3", "mid", "midi", "caf", "ape", "alac", "dsf", "dff",
        // ── Images ──────────────────────────────────────────────────
        "png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "ico", "icns", "psd", "ai", "eps", "heic", "heif",
        "raw", "cr2", "nef", "arw", "dng", "orf", "rw2", "svgz",
        // ── 3D / assets ─────────────────────────────────────────────
        "fbx", "blend", "blend1", "3ds", "dae", "glb",
        // ── Fonts ───────────────────────────────────────────────────
        "ttf", "otf", "ttc", "woff", "woff2",
        // ── Archives / packages / disk images ───────────────────────
        "zip", "rar", "7z", "7zip", "tar", "gz", "bz2", "bz", "xz", "zst", "tgz", "tbz", "tbz2", "dmg", "iso", "cab", "pkg", "msi", "crx",
        "jar", "war", "ear", "apk", "ipa",
        // ── Object / compiled / binaries ────────────────────────────
        "o", "a", "so", "dylib", "dll", "exe", "bin", "class", "wasm", "pdb", "lib", "obj",
        // ── Databases / data containers ─────────────────────────────
        "db", "sqlite", "sqlite3", "realm", "mdb", "accdb", "parquet", "feather", "arrow",
        // ── Documents (binary containers) ───────────────────────────
        "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "rtf", "sketch", "indd", "idml"
    ]

    /// Extensions that are **always** treated as plain-text – we skip the binary probe entirely.
    static let alwaysTextExtensions: Set<String> = [
        // ── General text / docs ─────────────────────────────────────
        "txt", "text", "md", "markdown", "rst", "mdx",
        // ── Data / config ───────────────────────────────────────────
        "json", "jsonc", "xml", "yaml", "yml", "toml", "ini", "cfg", "conf", "properties",
        "csv", "tsv", "proto",
        // ── Web assets ──────────────────────────────────────────────
        "html", "htm", "css", "scss", "sass", "less", "styl",
        "js", "mjs", "jsx", "ts", "tsx", "vue", "svelte", "astro", "pug", "jade",
        // ── Programming languages ──────────────────────────────────
        "swift", "c", "cpp", "cc", "h", "hpp", "m", "mm",
        "cs", "csx", // C-sharp
        "java", "kt", "kts", "groovy", "scala", "go", "rs", "dart", "zig", "nim",
        "py", "pyw", "pyx", "rb", "php", "phtml", "php5", "phps", "pl", "pm",
        "ex", "exs", "erl", "elixir", "clj", "cljs", "cljc", "coffee",
        "sh", "bash", "zsh", "fish", "cmd", "bat", "ps1", "psm1", "lua",
        "sql"
    ]

    /// Filenames with **no** extension that are always text.
    static let alwaysTextFilenames: Set<String> = [
        "makefile", "dockerfile", "readme", "license",
        "gitignore", ".gitignore", ".ignore", ".env",
        ".gitattributes", ".editorconfig"
    ]

    /// Detect a Unicode BOM and return the matching encoding, or `nil`.
    static func detectBOMEncoding(in data: Data) -> String.Encoding? {
        guard data.count >= 2 else { return nil }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8 } // UTF‑8 BOM
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return .utf32BigEndian }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return .utf32LittleEndian }
        if data.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        if data.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        return nil
    }

    /// Attempts to detect the file’s encoding and return the decoded text.
    /// The fast-path now uses the length-aware `String(data:encoding:)`
    /// instead of `String(validatingUTF8:)`, eliminating crashes caused by
    /// missing NUL-termination in `Data` buffers.
    func readDataAndDetectEncoding(_ fullPath: String) throws -> DetectedText {
        let data = try Data(contentsOf: URL(fileURLWithPath: fullPath))
        guard let detected = decodeWorkspaceAutomaticV1(data) else {
            throw FileSystemError.failedToReadFile
        }
        return detected
    }

    /// Quick heuristic: UTF‑16 text usually contains many NUL bytes.
    static func looksLikeUTF16(_ data: Data) -> Bool {
        let sample = data.prefix(256)
        let zeroCount = sample.count(where: { $0 == 0 })
        return zeroCount > sample.count / 4 // > 25 % zeros ⇒ likely UTF‑16
    }

    // A minimal directory entry representation

    func detectFileEncoding(atRelativePath relativePath: String) async throws -> String.Encoding {
        let request = try makeContentReadRequest(
            cacheKey: relativePath,
            chunkSize: 1_048_576,
            fileSizeLimit: 10_000_000,
            mode: .automatic,
            workloadClass: .encodingDetection
        )
        #if DEBUG
            if shouldUseSerialContentReadFallback {
                return try detectFileEncodingSerialForTesting(request.absolutePath)
            }
        #endif
        return try await Self.performEncodingDetectionOffActor(request)
    }

    private nonisolated static func performEncodingDetectionOffActor(_ request: ContentReadRequest) async throws -> String.Encoding {
        let workerPriority = Task.currentPriority
        return try await contentReadWorkerLimiter.withPermit(
            workloadClass: request.workloadClass,
            ownerID: request.schedulerOwnerID
        ) {
            try await withThrowingTaskGroup(of: String.Encoding.self) { group in
                group.addTask(priority: workerPriority) {
                    let workerBodyState = EditFlowPerf.begin(
                        EditFlowPerf.Stage.FileSystem.contentReadWorkerBody,
                        EditFlowPerf.Dimensions(
                            workloadClass: request.workloadClass.rawValue,
                            contentSource: "disk"
                        )
                    )
                    var workerBodyOutcome = "failed"
                    var workerBodyFileBytes: Int?
                    defer {
                        EditFlowPerf.end(
                            EditFlowPerf.Stage.FileSystem.contentReadWorkerBody,
                            workerBodyState,
                            EditFlowPerf.Dimensions(
                                outcome: workerBodyOutcome,
                                fileBytes: workerBodyFileBytes,
                                workloadClass: request.workloadClass.rawValue,
                                contentSource: "disk"
                            )
                        )
                    }
                    do {
                        try Task.checkCancellation()
                        let validated = try validateContentFileForReading(request)
                        workerBodyFileBytes = telemetryFileBytes(validated.fileSize)
                        let handle = try openValidatedContentHandle(
                            request,
                            validated: validated,
                            requireStableIdentity: false
                        )
                        defer { try? handle.close() }
                        switch try await readBoundedData(request, handle: handle) {
                        case let .data(data):
                            _ = try validateOpenContentHandle(
                                handle,
                                validated: validated,
                                result: noEncodingContentReadResult(request, validated: validated, content: nil),
                                required: false
                            )
                            workerBodyOutcome = "loaded"
                            return detectFileEncoding(in: data)
                        case .tooLarge:
                            workerBodyOutcome = "oversized"
                            throw FileSystemError.fileTooLarge
                        }
                    } catch {
                        if error is CancellationError {
                            workerBodyOutcome = "cancelled"
                        }
                        throw error
                    }
                }
                guard let encoding = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return encoding
            }
        }
    }

    private nonisolated static func detectFileEncoding(in data: Data) -> String.Encoding {
        var usedLossyConversion = ObjCBool(false)
        let encodingValue = NSString.stringEncoding(
            for: data,
            encodingOptions: [:],
            convertedString: nil,
            usedLossyConversion: &usedLossyConversion
        )
        if encodingValue != 0 {
            return String.Encoding(rawValue: encodingValue)
        }

        let encodings: [String.Encoding] = [
            .utf8,
            .macOSRoman,
            .ascii,
            .utf16,
            .utf16BigEndian,
            .utf16LittleEndian,
            .utf32,
            .utf32BigEndian,
            .utf32LittleEndian,
            .windowsCP1252,
            .isoLatin1,
            .unicode,
            .shiftJIS,
            .nonLossyASCII
        ]

        for encoding in encodings where String(data: data, encoding: encoding) != nil {
            return encoding
        }
        return .utf8
    }

    #if DEBUG
        private func detectFileEncodingSerialForTesting(_ fullPath: String) throws -> String.Encoding {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: fullPath)) else {
                throw FileSystemError.failedToReadFile
            }
            return Self.detectFileEncoding(in: data)
        }
    #endif
}
