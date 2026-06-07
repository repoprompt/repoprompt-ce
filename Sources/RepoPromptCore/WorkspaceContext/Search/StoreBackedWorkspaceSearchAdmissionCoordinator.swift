import Foundation

package enum BroadSearchAdmissionClass: String {
    case unscopedContent
    case unscopedBoth
}

package enum StoreBackedWorkspaceSearchAdmissionError: LocalizedError, Equatable {
    package enum QueueScope: String {
        case perStore
        case global
    }

    case queueFull(scope: QueueScope, retryAfterMilliseconds: Int)
    case waitExpired(retryAfterMilliseconds: Int)
    case contentFetchQueueFull(scope: QueueScope, retryAfterMilliseconds: Int)
    case contentFetchWaitExpired(retryAfterMilliseconds: Int)

    package var retryAfterMilliseconds: Int {
        switch self {
        case let .queueFull(_, retryAfterMilliseconds),
             let .waitExpired(retryAfterMilliseconds),
             let .contentFetchQueueFull(_, retryAfterMilliseconds),
             let .contentFetchWaitExpired(retryAfterMilliseconds):
            retryAfterMilliseconds
        }
    }

    package var suggestion: String {
        "Retry after the suggested delay, or use filter.paths to narrow the content search when a smaller scope is acceptable."
    }

    package var errorDescription: String? {
        switch self {
        case .queueFull:
            "Broad content search capacity is temporarily busy and the bounded wait queue is full."
        case .waitExpired:
            "Broad content search capacity remained busy until the bounded queue wait expired."
        case .contentFetchQueueFull:
            "Content-search fetch capacity is temporarily busy and the bounded wait queue is full."
        case .contentFetchWaitExpired:
            "Content-search fetch capacity remained busy until the bounded queue wait expired."
        }
    }
}

package actor StoreBackedWorkspaceSearchAdmissionCoordinator {
    package struct Configuration: Equatable {
        package static var production: Configuration {
            let processorCount = ProcessInfo.processInfo.activeProcessorCount
            // Per-store admission is the primary protection. The global cap only guards
            // pathological aggregate pressure while allowing ordinary 12+ window use.
            return Configuration(
                perStoreCapacity: 2,
                globalCapacity: max(12, min(32, processorCount * 2)),
                maxQueuedPerStore: 2,
                maxQueuedGlobally: 4,
                maxQueueWait: .seconds(8),
                retryAfterMilliseconds: 1000
            )
        }

        package let perStoreCapacity: Int
        package let globalCapacity: Int
        package let maxQueuedPerStore: Int
        package let maxQueuedGlobally: Int
        package let maxQueueWait: Duration
        package let retryAfterMilliseconds: Int

        package var maxQueueWaitMilliseconds: Int {
            let components = maxQueueWait.components
            let milliseconds = components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
            return Int(clamping: milliseconds)
        }

        package init(
            perStoreCapacity: Int,
            globalCapacity: Int,
            maxQueuedPerStore: Int,
            maxQueuedGlobally: Int,
            maxQueueWait: Duration,
            retryAfterMilliseconds: Int = 1000
        ) {
            precondition(perStoreCapacity > 0)
            precondition(globalCapacity > 0)
            precondition(maxQueuedPerStore >= 0)
            precondition(maxQueuedGlobally >= 0)
            precondition(maxQueueWait > .zero)
            precondition(retryAfterMilliseconds >= 0)
            self.perStoreCapacity = perStoreCapacity
            self.globalCapacity = globalCapacity
            self.maxQueuedPerStore = maxQueuedPerStore
            self.maxQueuedGlobally = maxQueuedGlobally
            self.maxQueueWait = maxQueueWait
            self.retryAfterMilliseconds = retryAfterMilliseconds
        }
    }

    package struct AdmissionClock {
        package static func continuous() -> AdmissionClock {
            let clock = ContinuousClock()
            let origin = clock.now
            return AdmissionClock(
                now: { origin.duration(to: clock.now) },
                sleepUntil: { deadline in
                    try await clock.sleep(until: origin.advanced(by: deadline), tolerance: nil)
                }
            )
        }

        package let now: @Sendable () -> Duration
        package let sleepUntil: @Sendable (_ deadline: Duration) async throws -> Void

        package init(
            now: @escaping @Sendable () -> Duration,
            sleepUntil: @escaping @Sendable (_ deadline: Duration) async throws -> Void
        ) {
            self.now = now
            self.sleepUntil = sleepUntil
        }
    }

    package static let shared = StoreBackedWorkspaceSearchAdmissionCoordinator()

    #if DEBUG
        /// These DEBUG snapshots retain aggregate counters only. They intentionally avoid
        /// per-caller histories so synthetic hundreds-of-caller sweeps stay bounded.
        package struct Snapshot: Equatable {
            package let activePermitCount: Int
            package let waiterCount: Int

            package var hasActivePermit: Bool {
                activePermitCount > 0
            }
        }

        package struct GlobalSnapshot: Equatable {
            package let activePermitCount: Int
            package let waiterCount: Int
            package let laneCount: Int
        }

        package struct DebugSnapshot: Equatable {
            package struct LaneLoad: Equatable {
                package let activeCount: Int
                package let queuedCount: Int
            }

            package let configuration: Configuration
            package let laneCount: Int
            package let globalActiveCount: Int
            package let globalQueuedCount: Int
            package let overloadCount: Int
            package let waitExpiryCount: Int
            package let queuedCancellationCount: Int
            package let laneLoads: [LaneLoad]

            package var isIdle: Bool {
                globalActiveCount == 0 && globalQueuedCount == 0 && laneCount == 0
            }
        }

        package enum DebugConfigurationUpdateResult: Equatable {
            case applied(DebugSnapshot)
            case busy(DebugSnapshot)
        }
    #endif

    private struct AdmissionMetrics {
        let storeActiveCount: Int
        let globalActiveCount: Int
        let storeQueueDepth: Int
        let globalQueueDepth: Int
    }

    private struct PermitAcquisition {
        let leaseID: UUID
        let storeKey: ObjectIdentifier
        let searchMode: SearchMode
        let admissionClass: BroadSearchAdmissionClass?
        let lifecycleCorrelation: WorkspaceRuntimePerf.LifecycleCorrelation?
        let waited: Bool
        let queueAgeBucket: String
        let metrics: AdmissionMetrics
    }

    private struct WaiterState {
        let continuation: CheckedContinuation<PermitAcquisition, Error>
        let searchMode: SearchMode
        let admissionClass: BroadSearchAdmissionClass?
        let lifecycleCorrelation: WorkspaceRuntimePerf.LifecycleCorrelation?
        let enqueueOrdinal: UInt64
        let enqueuedAtUptimeNanoseconds: UInt64
        let deadline: Duration
        var timeoutTask: Task<Void, Never>?
    }

    private struct Lane {
        var activeLeaseIDs = Set<UUID>()
        var waiterOrder: [UUID] = []
        var waiterStates: [UUID: WaiterState] = [:]
        var lastGrantOrdinal: UInt64?
    }

    private struct EligibleLane {
        let key: ObjectIdentifier
        let lastGrant: UInt64?
        let enqueueOrdinal: UInt64
    }

    private var configuration: Configuration
    private let clock: AdmissionClock
    private var lanes: [ObjectIdentifier: Lane] = [:]
    private var globalActiveCount = 0
    private var globalQueuedCount = 0
    private var nextEnqueueOrdinal: UInt64 = 0
    private var nextGrantOrdinal: UInt64 = 0
    private var overloadCount = 0
    private var waitExpiryCount = 0
    private var queuedCancellationCount = 0
    #if DEBUG
        private var permitAcquiredHandlerForTesting: (@Sendable (WorkspaceFileContextStore) async -> Void)?
    #endif

    package init(
        configuration: Configuration = .production,
        clock: AdmissionClock = .continuous()
    ) {
        self.configuration = configuration
        self.clock = clock
    }

    package func withBroadSearchPermit<T>(
        for store: WorkspaceFileContextStore,
        searchMode: SearchMode,
        admissionClass: BroadSearchAdmissionClass? = nil,
        operation: () async throws -> T
    ) async throws -> T {
        let storeKey = ObjectIdentifier(store)
        let lifecycleCorrelation = WorkspaceRuntimePerf.currentLifecycleCorrelation
        let initialMetrics = metrics(for: storeKey)
        let waitState = WorkspaceRuntimePerf.begin(
            WorkspaceRuntimePerf.Stage.Search.broadAdmissionWait,
            admissionDimensions(
                searchMode: searchMode,
                admissionClass: admissionClass,
                metrics: initialMetrics,
                queueAgeBucket: "immediate"
            )
        )

        let acquisition: PermitAcquisition
        do {
            acquisition = try await acquire(
                for: storeKey,
                searchMode: searchMode,
                admissionClass: admissionClass,
                lifecycleCorrelation: lifecycleCorrelation
            )
            WorkspaceRuntimePerf.end(
                WorkspaceRuntimePerf.Stage.Search.broadAdmissionWait,
                waitState,
                admissionDimensions(
                    outcome: acquisition.waited ? "acquiredAfterWait" : "immediate",
                    searchMode: searchMode,
                    admissionClass: admissionClass,
                    metrics: acquisition.metrics,
                    queueAgeBucket: acquisition.queueAgeBucket
                )
            )
        } catch {
            let currentMetrics = metrics(for: storeKey)
            WorkspaceRuntimePerf.end(
                WorkspaceRuntimePerf.Stage.Search.broadAdmissionWait,
                waitState,
                admissionDimensions(
                    outcome: Self.waitOutcome(for: error),
                    searchMode: searchMode,
                    admissionClass: admissionClass,
                    metrics: currentMetrics,
                    queueAgeBucket: queueAgeBucket(for: error)
                )
            )
            throw error
        }

        let leaseHoldState = WorkspaceRuntimePerf.begin(
            WorkspaceRuntimePerf.Stage.Search.broadAdmissionLeaseHold,
            admissionDimensions(
                searchMode: searchMode,
                admissionClass: admissionClass,
                metrics: acquisition.metrics,
                queueAgeBucket: acquisition.queueAgeBucket
            )
        )
        var leaseHoldOutcome = "completed"
        defer {
            WorkspaceRuntimePerf.end(
                WorkspaceRuntimePerf.Stage.Search.broadAdmissionLeaseHold,
                leaseHoldState,
                admissionDimensions(
                    outcome: leaseHoldOutcome,
                    searchMode: searchMode,
                    admissionClass: admissionClass,
                    metrics: metrics(for: storeKey),
                    queueAgeBucket: acquisition.queueAgeBucket
                )
            )
            release(acquisition)
        }
        do {
            try Task.checkCancellation()
            #if DEBUG
                if let permitAcquiredHandlerForTesting {
                    await permitAcquiredHandlerForTesting(store)
                }
            #endif
            try Task.checkCancellation()
            return try await operation()
        } catch {
            leaseHoldOutcome = error is CancellationError ? "cancelled" : "failed"
            throw error
        }
    }

    private static func waitOutcome(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let error = error as? StoreBackedWorkspaceSearchAdmissionError else { return "error" }
        switch error {
        case .queueFull:
            return "queueFull"
        case .waitExpired:
            return "waitExpired"
        case .contentFetchQueueFull:
            return "queueFull"
        case .contentFetchWaitExpired:
            return "waitExpired"
        }
    }

    private func queueAgeBucket(for error: Error) -> String {
        guard let error = error as? StoreBackedWorkspaceSearchAdmissionError else { return "immediate" }
        switch error {
        case .queueFull:
            return "immediate"
        case .waitExpired:
            return Self.queueAgeBucket(milliseconds: configuration.maxQueueWaitMilliseconds)
        case .contentFetchQueueFull:
            return "immediate"
        case .contentFetchWaitExpired:
            return Self.queueAgeBucket(milliseconds: configuration.maxQueueWaitMilliseconds)
        }
    }

    private static func queueAgeBucket(since enqueuedAtUptimeNanoseconds: UInt64?) -> String {
        guard let enqueuedAtUptimeNanoseconds else { return "immediate" }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= enqueuedAtUptimeNanoseconds ? now - enqueuedAtUptimeNanoseconds : 0
        return queueAgeBucket(milliseconds: Int(clamping: elapsed / 1_000_000))
    }

    private static func queueAgeBucket(milliseconds: Int) -> String {
        switch milliseconds {
        case ..<100:
            "lt100ms"
        case ..<500:
            "lt500ms"
        case ..<1000:
            "lt1s"
        case ..<2000:
            "lt2s"
        case ..<5000:
            "lt5s"
        case ..<8000:
            "lt8s"
        default:
            "gte8s"
        }
    }

    private func acquire(
        for storeKey: ObjectIdentifier,
        searchMode: SearchMode,
        admissionClass: BroadSearchAdmissionClass?,
        lifecycleCorrelation: WorkspaceRuntimePerf.LifecycleCorrelation?
    ) async throws -> PermitAcquisition {
        try Task.checkCancellation()
        scheduleAvailablePermits()
        var lane = lanes[storeKey] ?? Lane()
        if canGrantPermit(in: lane) {
            let acquisition = allocatePermit(
                for: storeKey,
                lane: &lane,
                searchMode: searchMode,
                admissionClass: admissionClass,
                lifecycleCorrelation: lifecycleCorrelation,
                waited: false
            )
            lanes[storeKey] = lane
            recordPermitAcquired(acquisition)
            return acquisition
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueueWaiter(
                    id: waiterID,
                    for: storeKey,
                    continuation: continuation,
                    searchMode: searchMode,
                    admissionClass: admissionClass,
                    lifecycleCorrelation: lifecycleCorrelation
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID, for: storeKey) }
        }
    }

    private func enqueueWaiter(
        id: UUID,
        for storeKey: ObjectIdentifier,
        continuation: CheckedContinuation<PermitAcquisition, Error>,
        searchMode: SearchMode,
        admissionClass: BroadSearchAdmissionClass?,
        lifecycleCorrelation: WorkspaceRuntimePerf.LifecycleCorrelation?
    ) {
        let enqueuedAt = clock.now()

        scheduleAvailablePermits()
        var lane = lanes[storeKey] ?? Lane()
        if canGrantPermit(in: lane) {
            let acquisition = allocatePermit(
                for: storeKey,
                lane: &lane,
                searchMode: searchMode,
                admissionClass: admissionClass,
                lifecycleCorrelation: lifecycleCorrelation,
                waited: false
            )
            lanes[storeKey] = lane
            recordPermitAcquired(acquisition)
            continuation.resume(returning: acquisition)
            return
        }

        if lane.waiterStates.count >= configuration.maxQueuedPerStore {
            recordOverload(
                scope: .perStore,
                storeKey: storeKey,
                searchMode: searchMode,
                admissionClass: admissionClass,
                lifecycleCorrelation: lifecycleCorrelation
            )
            continuation.resume(throwing: StoreBackedWorkspaceSearchAdmissionError.queueFull(
                scope: .perStore,
                retryAfterMilliseconds: configuration.retryAfterMilliseconds
            ))
            return
        }
        if globalQueuedCount >= configuration.maxQueuedGlobally {
            recordOverload(
                scope: .global,
                storeKey: storeKey,
                searchMode: searchMode,
                admissionClass: admissionClass,
                lifecycleCorrelation: lifecycleCorrelation
            )
            continuation.resume(throwing: StoreBackedWorkspaceSearchAdmissionError.queueFull(
                scope: .global,
                retryAfterMilliseconds: configuration.retryAfterMilliseconds
            ))
            return
        }

        nextEnqueueOrdinal &+= 1
        let deadline = enqueuedAt + configuration.maxQueueWait
        lane.waiterStates[id] = WaiterState(
            continuation: continuation,
            searchMode: searchMode,
            admissionClass: admissionClass,
            lifecycleCorrelation: lifecycleCorrelation,
            enqueueOrdinal: nextEnqueueOrdinal,
            enqueuedAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            deadline: deadline,
            timeoutTask: nil
        )
        lane.waiterOrder.append(id)
        globalQueuedCount += 1
        lanes[storeKey] = lane
        WorkspaceRuntimePerf.lifecycleEvent(
            WorkspaceRuntimePerf.Lifecycle.Search.broadAdmissionWaitBegan,
            correlation: lifecycleCorrelation,
            admissionDimensions(
                searchMode: searchMode,
                admissionClass: admissionClass,
                metrics: metrics(for: storeKey),
                queueAgeBucket: "lt100ms"
            )
        )

        let timeoutTask = Task { [clock] in
            do {
                try await clock.sleepUntil(deadline)
                self.expireWaiter(id: id, for: storeKey)
            } catch {
                // Grant and cancellation paths cancel the sleeper after removing the waiter.
            }
        }
        if var currentLane = lanes[storeKey], var waiter = currentLane.waiterStates[id] {
            waiter.timeoutTask = timeoutTask
            currentLane.waiterStates[id] = waiter
            lanes[storeKey] = currentLane
        } else {
            timeoutTask.cancel()
        }
        scheduleAvailablePermits()
    }

    private func cancelWaiter(id: UUID, for storeKey: ObjectIdentifier) {
        guard var lane = lanes[storeKey],
              let state = lane.waiterStates.removeValue(forKey: id)
        else { return }
        state.timeoutTask?.cancel()
        lane.waiterOrder.removeAll { $0 == id }
        globalQueuedCount = max(0, globalQueuedCount - 1)
        storeOrRemoveLane(lane, for: storeKey)
        queuedCancellationCount &+= 1
        WorkspaceRuntimePerf.lifecycleEvent(
            WorkspaceRuntimePerf.Lifecycle.Search.broadAdmissionPermitCancelled,
            correlation: state.lifecycleCorrelation,
            admissionDimensions(
                outcome: "cancelled",
                searchMode: state.searchMode,
                admissionClass: state.admissionClass,
                metrics: metrics(for: storeKey),
                queueAgeBucket: Self.queueAgeBucket(since: state.enqueuedAtUptimeNanoseconds)
            )
        )
        state.continuation.resume(throwing: CancellationError())
        scheduleAvailablePermits()
    }

    private func expireWaiter(id: UUID, for storeKey: ObjectIdentifier) {
        guard var lane = lanes[storeKey],
              let state = lane.waiterStates.removeValue(forKey: id)
        else { return }
        lane.waiterOrder.removeAll { $0 == id }
        globalQueuedCount = max(0, globalQueuedCount - 1)
        storeOrRemoveLane(lane, for: storeKey)
        waitExpiryCount &+= 1
        WorkspaceRuntimePerf.lifecycleEvent(
            WorkspaceRuntimePerf.Lifecycle.Search.broadAdmissionWaitExpired,
            correlation: state.lifecycleCorrelation,
            admissionDimensions(
                outcome: "waitExpired",
                searchMode: state.searchMode,
                admissionClass: state.admissionClass,
                metrics: metrics(for: storeKey),
                queueAgeBucket: Self.queueAgeBucket(milliseconds: configuration.maxQueueWaitMilliseconds)
            )
        )
        state.continuation.resume(throwing: StoreBackedWorkspaceSearchAdmissionError.waitExpired(
            retryAfterMilliseconds: configuration.retryAfterMilliseconds
        ))
        scheduleAvailablePermits()
    }

    private func release(_ acquisition: PermitAcquisition) {
        guard var lane = lanes[acquisition.storeKey],
              lane.activeLeaseIDs.remove(acquisition.leaseID) != nil
        else { return }
        globalActiveCount = max(0, globalActiveCount - 1)
        storeOrRemoveLane(lane, for: acquisition.storeKey)
        WorkspaceRuntimePerf.lifecycleEvent(
            WorkspaceRuntimePerf.Lifecycle.Search.broadAdmissionPermitReleased,
            correlation: acquisition.lifecycleCorrelation,
            admissionDimensions(
                outcome: "released",
                searchMode: acquisition.searchMode,
                admissionClass: acquisition.admissionClass,
                metrics: metrics(for: acquisition.storeKey),
                queueAgeBucket: acquisition.queueAgeBucket
            )
        )
        scheduleAvailablePermits()
    }

    private func scheduleAvailablePermits() {
        while globalActiveCount < configuration.globalCapacity,
              let storeKey = nextEligibleStoreKey()
        {
            guard grantNextQueuedPermit(for: storeKey) else { continue }
        }
    }

    private func nextEligibleStoreKey() -> ObjectIdentifier? {
        var candidates: [EligibleLane] = []
        for (key, lane) in lanes {
            guard lane.activeLeaseIDs.count < configuration.perStoreCapacity,
                  let waiterID = lane.waiterOrder.first,
                  let waiter = lane.waiterStates[waiterID]
            else { continue }
            candidates.append(EligibleLane(key: key, lastGrant: lane.lastGrantOrdinal, enqueueOrdinal: waiter.enqueueOrdinal))
        }
        return candidates.min { lhs, rhs in
            switch (lhs.lastGrant, rhs.lastGrant) {
            case (nil, nil):
                return lhs.enqueueOrdinal < rhs.enqueueOrdinal
            case (nil, _):
                return true
            case (_, nil):
                return false
            case let (lhsGrant?, rhsGrant?):
                if lhsGrant != rhsGrant { return lhsGrant < rhsGrant }
                return lhs.enqueueOrdinal < rhs.enqueueOrdinal
            }
        }?.key
    }

    private func grantNextQueuedPermit(for storeKey: ObjectIdentifier) -> Bool {
        guard var lane = lanes[storeKey] else { return false }
        while !lane.waiterOrder.isEmpty {
            let waiterID = lane.waiterOrder.removeFirst()
            guard let state = lane.waiterStates.removeValue(forKey: waiterID) else { continue }
            state.timeoutTask?.cancel()
            globalQueuedCount = max(0, globalQueuedCount - 1)
            let acquisition = allocatePermit(
                for: storeKey,
                lane: &lane,
                searchMode: state.searchMode,
                admissionClass: state.admissionClass,
                lifecycleCorrelation: state.lifecycleCorrelation,
                waited: true,
                queueAgeBucket: Self.queueAgeBucket(since: state.enqueuedAtUptimeNanoseconds)
            )
            lanes[storeKey] = lane
            recordPermitAcquired(acquisition)
            state.continuation.resume(returning: acquisition)
            return true
        }
        storeOrRemoveLane(lane, for: storeKey)
        return false
    }

    private func allocatePermit(
        for storeKey: ObjectIdentifier,
        lane: inout Lane,
        searchMode: SearchMode,
        admissionClass: BroadSearchAdmissionClass?,
        lifecycleCorrelation: WorkspaceRuntimePerf.LifecycleCorrelation?,
        waited: Bool,
        queueAgeBucket: String = "immediate"
    ) -> PermitAcquisition {
        let leaseID = UUID()
        lane.activeLeaseIDs.insert(leaseID)
        globalActiveCount += 1
        nextGrantOrdinal &+= 1
        lane.lastGrantOrdinal = nextGrantOrdinal
        return PermitAcquisition(
            leaseID: leaseID,
            storeKey: storeKey,
            searchMode: searchMode,
            admissionClass: admissionClass,
            lifecycleCorrelation: lifecycleCorrelation,
            waited: waited,
            queueAgeBucket: queueAgeBucket,
            metrics: metrics(for: storeKey, lane: lane)
        )
    }

    private func canGrantPermit(in lane: Lane) -> Bool {
        globalActiveCount < configuration.globalCapacity &&
            lane.activeLeaseIDs.count < configuration.perStoreCapacity
    }

    private func storeOrRemoveLane(_ lane: Lane, for storeKey: ObjectIdentifier) {
        if lane.activeLeaseIDs.isEmpty, lane.waiterStates.isEmpty {
            lanes.removeValue(forKey: storeKey)
        } else {
            lanes[storeKey] = lane
        }
    }

    private func recordPermitAcquired(_ acquisition: PermitAcquisition) {
        WorkspaceRuntimePerf.lifecycleEvent(
            WorkspaceRuntimePerf.Lifecycle.Search.broadAdmissionPermitAcquired,
            correlation: acquisition.lifecycleCorrelation,
            admissionDimensions(
                outcome: acquisition.waited ? "acquiredAfterWait" : "immediate",
                searchMode: acquisition.searchMode,
                admissionClass: acquisition.admissionClass,
                metrics: acquisition.metrics,
                queueAgeBucket: acquisition.queueAgeBucket
            )
        )
    }

    private func recordOverload(
        scope: StoreBackedWorkspaceSearchAdmissionError.QueueScope,
        storeKey: ObjectIdentifier,
        searchMode: SearchMode,
        admissionClass: BroadSearchAdmissionClass?,
        lifecycleCorrelation: WorkspaceRuntimePerf.LifecycleCorrelation?
    ) {
        overloadCount &+= 1
        WorkspaceRuntimePerf.lifecycleEvent(
            WorkspaceRuntimePerf.Lifecycle.Search.broadAdmissionOverloaded,
            correlation: lifecycleCorrelation,
            admissionDimensions(
                outcome: scope.rawValue,
                searchMode: searchMode,
                admissionClass: admissionClass,
                metrics: metrics(for: storeKey),
                queueAgeBucket: "immediate"
            )
        )
    }

    private func admissionDimensions(
        outcome: String? = nil,
        searchMode: SearchMode,
        admissionClass: BroadSearchAdmissionClass?,
        metrics: AdmissionMetrics,
        queueAgeBucket: String
    ) -> WorkspaceRuntimePerf.Dimensions {
        WorkspaceRuntimePerf.Dimensions(
            outcome: outcome,
            storeCapacity: configuration.perStoreCapacity,
            globalCapacity: configuration.globalCapacity,
            storeActiveCount: metrics.storeActiveCount,
            globalActiveCount: metrics.globalActiveCount,
            storeQueueDepth: metrics.storeQueueDepth,
            globalQueueDepth: metrics.globalQueueDepth,
            searchMode: searchMode.rawValue,
            admissionClass: admissionClass?.rawValue,
            queueAgeBucket: queueAgeBucket,
            queueDepth: metrics.storeQueueDepth,
            waiterCount: metrics.storeQueueDepth
        )
    }

    private func metrics(for storeKey: ObjectIdentifier) -> AdmissionMetrics {
        metrics(for: storeKey, lane: lanes[storeKey])
    }

    private func metrics(for _: ObjectIdentifier, lane: Lane?) -> AdmissionMetrics {
        AdmissionMetrics(
            storeActiveCount: lane?.activeLeaseIDs.count ?? 0,
            globalActiveCount: globalActiveCount,
            storeQueueDepth: lane?.waiterStates.count ?? 0,
            globalQueueDepth: globalQueuedCount
        )
    }

    #if DEBUG
        package func snapshot(for store: WorkspaceFileContextStore) -> Snapshot {
            let lane = lanes[ObjectIdentifier(store)]
            return Snapshot(
                activePermitCount: lane?.activeLeaseIDs.count ?? 0,
                waiterCount: lane?.waiterStates.count ?? 0
            )
        }

        package func snapshot() -> GlobalSnapshot {
            GlobalSnapshot(
                activePermitCount: globalActiveCount,
                waiterCount: globalQueuedCount,
                laneCount: lanes.count
            )
        }

        package func snapshotForDebug() -> DebugSnapshot {
            let laneLoads = lanes.values
                .map { DebugSnapshot.LaneLoad(activeCount: $0.activeLeaseIDs.count, queuedCount: $0.waiterStates.count) }
                .sorted {
                    if $0.activeCount == $1.activeCount {
                        return $0.queuedCount < $1.queuedCount
                    }
                    return $0.activeCount < $1.activeCount
                }

            return DebugSnapshot(
                configuration: configuration,
                laneCount: lanes.count,
                globalActiveCount: globalActiveCount,
                globalQueuedCount: globalQueuedCount,
                overloadCount: overloadCount,
                waitExpiryCount: waitExpiryCount,
                queuedCancellationCount: queuedCancellationCount,
                laneLoads: laneLoads
            )
        }

        package func configureForDebug(_ newConfiguration: Configuration) -> DebugConfigurationUpdateResult {
            guard globalActiveCount == 0,
                  globalQueuedCount == 0,
                  lanes.isEmpty
            else {
                return .busy(snapshotForDebug())
            }
            configuration = newConfiguration
            overloadCount = 0
            waitExpiryCount = 0
            queuedCancellationCount = 0
            return .applied(snapshotForDebug())
        }

        package func resetDebugConfiguration() -> DebugConfigurationUpdateResult {
            configureForDebug(.production)
        }

        package func setPermitAcquiredHandlerForTesting(
            _ handler: (@Sendable (WorkspaceFileContextStore) async -> Void)?
        ) {
            permitAcquiredHandlerForTesting = handler
        }
    #endif
}
