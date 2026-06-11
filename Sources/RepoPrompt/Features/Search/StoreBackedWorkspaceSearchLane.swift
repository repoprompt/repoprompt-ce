import Foundation

enum BroadSearchAdmissionClass: String {
    case unscopedContent
    case unscopedBoth
}

enum StoreBackedWorkspaceSearchAdmissionError: LocalizedError, Equatable {
    enum QueueScope: String {
        case perStore
    }

    case queueFull(scope: QueueScope, retryAfterMilliseconds: Int)
    case waitExpired(retryAfterMilliseconds: Int)
    case contentReadQueueFull(retryAfterMilliseconds: Int)

    var retryAfterMilliseconds: Int {
        switch self {
        case let .queueFull(_, retryAfterMilliseconds),
             let .waitExpired(retryAfterMilliseconds),
             let .contentReadQueueFull(retryAfterMilliseconds):
            retryAfterMilliseconds
        }
    }

    var suggestion: String {
        "Retry after the suggested delay, or use filter.paths to narrow the content search when a smaller scope is acceptable."
    }

    var errorDescription: String? {
        switch self {
        case .queueFull:
            "Broad content search capacity is temporarily busy and the per-workspace wait queue is full."
        case .waitExpired:
            "Broad content search capacity remained busy until the bounded queue wait expired."
        case .contentReadQueueFull:
            "Content-read capacity is temporarily busy and the bounded wait queue is full."
        }
    }
}

/// Per-workspace execution lane for store-backed file search.
///
/// Path-only and explicitly scoped searches bypass broad admission. Unscoped content-capable
/// searches use a fixed-capacity batch gate: a bounded set of active leases runs concurrently
/// so a parallel burst (one connection's batched tool calls, or several agents on the same
/// workspace) shares one ingress freshness flight instead of reconstructing it serially per
/// search. Beyond the active batch, a bounded FIFO wait queue absorbs the rest of the burst;
/// overflow still fails fast so one workspace cannot monopolize another.
actor StoreBackedWorkspaceSearchLane {
    struct Configuration: Equatable {
        static let production = Configuration(
            maxActiveLeases: 4,
            maxQueuedWaiters: 4,
            maxQueueWait: .milliseconds(1500),
            retryAfterMilliseconds: 1000
        )

        let maxActiveLeases: Int
        let maxQueuedWaiters: Int
        let maxQueueWait: Duration
        let retryAfterMilliseconds: Int

        var maxQueueWaitMilliseconds: Int {
            let components = maxQueueWait.components
            let milliseconds = components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
            return Int(clamping: milliseconds)
        }

        init(
            maxActiveLeases: Int = 1,
            maxQueuedWaiters: Int = 1,
            maxQueueWait: Duration,
            retryAfterMilliseconds: Int = 1000
        ) {
            precondition(maxActiveLeases >= 1)
            precondition(maxQueuedWaiters >= 1)
            precondition(maxQueueWait > .zero)
            precondition(retryAfterMilliseconds >= 0)
            self.maxActiveLeases = maxActiveLeases
            self.maxQueuedWaiters = maxQueuedWaiters
            self.maxQueueWait = maxQueueWait
            self.retryAfterMilliseconds = retryAfterMilliseconds
        }
    }

    struct AdmissionClock {
        static func continuous() -> AdmissionClock {
            let clock = ContinuousClock()
            let origin = clock.now
            return AdmissionClock(
                now: { origin.duration(to: clock.now) },
                sleepUntil: { deadline in
                    try await clock.sleep(until: origin.advanced(by: deadline), tolerance: nil)
                }
            )
        }

        let now: @Sendable () -> Duration
        let sleepUntil: @Sendable (_ deadline: Duration) async throws -> Void
    }

    #if DEBUG
        struct Snapshot: Equatable {
            let configuration: Configuration
            let activePermitCount: Int
            let waiterCount: Int
            let grantCount: Int
            let overloadCount: Int
            let waitExpiryCount: Int
            let queuedCancellationCount: Int
            let maximumActivePermitCount: Int
            let maximumWaiterCount: Int

            var isIdle: Bool {
                activePermitCount == 0 && waiterCount == 0
            }
        }

        enum DebugConfigurationUpdateResult: Equatable {
            case applied(Snapshot)
            case busy(Snapshot)
        }
    #endif

    private struct AdmissionMetrics {
        let activeCount: Int
        let queueDepth: Int
    }

    private struct PermitAcquisition {
        let leaseID: UUID
        let searchMode: SearchMode
        let admissionClass: BroadSearchAdmissionClass
        let lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
        let waited: Bool
        let queueAgeBucket: String
        let metrics: AdmissionMetrics
    }

    private struct WaiterState {
        let continuation: CheckedContinuation<PermitAcquisition, Error>
        let searchMode: SearchMode
        let admissionClass: BroadSearchAdmissionClass
        let lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
        let enqueuedAtUptimeNanoseconds: UInt64
        let deadline: Duration
        var timeoutTask: Task<Void, Never>?
    }

    private let fileSearchActor = FileSearchActor()
    private var configuration: Configuration
    private let clock: AdmissionClock
    private var activeLeaseIDs: Set<UUID> = []
    private var waiterIDsInOrder: [UUID] = []
    private var waiterStatesByID: [UUID: WaiterState] = [:]
    private var grantCount = 0
    private var overloadCount = 0
    private var waitExpiryCount = 0
    private var queuedCancellationCount = 0
    private var maximumActivePermitCount = 0
    private var maximumWaiterCount = 0
    #if DEBUG
        private var permitAcquiredHandlerForTesting: (@Sendable () async -> Void)?
    #endif

    init(
        configuration: Configuration = .production,
        clock: AdmissionClock = .continuous()
    ) {
        self.configuration = configuration
        self.clock = clock
    }

    func withSearchAccess<T>(
        searchMode: SearchMode,
        admissionClass: BroadSearchAdmissionClass?,
        operation: @Sendable (FileSearchActor) async throws -> T
    ) async throws -> T {
        guard let admissionClass else {
            try Task.checkCancellation()
            return try await operation(fileSearchActor)
        }

        let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        let waitState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.broadAdmissionWait,
            admissionDimensions(
                searchMode: searchMode,
                admissionClass: admissionClass,
                metrics: metrics(),
                queueAgeBucket: "immediate"
            )
        )

        let acquisition: PermitAcquisition
        do {
            acquisition = try await acquire(
                searchMode: searchMode,
                admissionClass: admissionClass,
                lifecycleCorrelation: lifecycleCorrelation
            )
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.broadAdmissionWait,
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
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.broadAdmissionWait,
                waitState,
                admissionDimensions(
                    outcome: Self.waitOutcome(for: error),
                    searchMode: searchMode,
                    admissionClass: admissionClass,
                    metrics: metrics(),
                    queueAgeBucket: queueAgeBucket(for: error)
                )
            )
            throw error
        }

        let leaseHoldState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.broadAdmissionLeaseHold,
            admissionDimensions(
                searchMode: searchMode,
                admissionClass: admissionClass,
                metrics: acquisition.metrics,
                queueAgeBucket: acquisition.queueAgeBucket
            )
        )
        var leaseHoldOutcome = "completed"
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.broadAdmissionLeaseHold,
                leaseHoldState,
                admissionDimensions(
                    outcome: leaseHoldOutcome,
                    searchMode: searchMode,
                    admissionClass: admissionClass,
                    metrics: metrics(),
                    queueAgeBucket: acquisition.queueAgeBucket
                )
            )
            release(acquisition)
        }

        do {
            try Task.checkCancellation()
            #if DEBUG
                if let permitAcquiredHandlerForTesting {
                    await permitAcquiredHandlerForTesting()
                }
            #endif
            try Task.checkCancellation()
            return try await operation(fileSearchActor)
        } catch {
            leaseHoldOutcome = error is CancellationError ? "cancelled" : "failed"
            throw error
        }
    }

    private func acquire(
        searchMode: SearchMode,
        admissionClass: BroadSearchAdmissionClass,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
    ) async throws -> PermitAcquisition {
        try Task.checkCancellation()
        if activeLeaseIDs.count < configuration.maxActiveLeases {
            return allocatePermit(
                searchMode: searchMode,
                admissionClass: admissionClass,
                lifecycleCorrelation: lifecycleCorrelation,
                waited: false
            )
        }
        guard waiterStatesByID.count < configuration.maxQueuedWaiters else {
            overloadCount &+= 1
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.Search.broadAdmissionOverloaded,
                correlation: lifecycleCorrelation,
                admissionDimensions(
                    outcome: StoreBackedWorkspaceSearchAdmissionError.QueueScope.perStore.rawValue,
                    searchMode: searchMode,
                    admissionClass: admissionClass,
                    metrics: metrics(),
                    queueAgeBucket: "immediate"
                )
            )
            throw StoreBackedWorkspaceSearchAdmissionError.queueFull(
                scope: .perStore,
                retryAfterMilliseconds: configuration.retryAfterMilliseconds
            )
        }

        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueueWaiter(
                    id: id,
                    continuation: continuation,
                    searchMode: searchMode,
                    admissionClass: admissionClass,
                    lifecycleCorrelation: lifecycleCorrelation
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func enqueueWaiter(
        id: UUID,
        continuation: CheckedContinuation<PermitAcquisition, Error>,
        searchMode: SearchMode,
        admissionClass: BroadSearchAdmissionClass,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
    ) {
        if activeLeaseIDs.count < configuration.maxActiveLeases {
            continuation.resume(returning: allocatePermit(
                searchMode: searchMode,
                admissionClass: admissionClass,
                lifecycleCorrelation: lifecycleCorrelation,
                waited: false
            ))
            return
        }
        guard waiterStatesByID.count < configuration.maxQueuedWaiters else {
            overloadCount &+= 1
            continuation.resume(throwing: StoreBackedWorkspaceSearchAdmissionError.queueFull(
                scope: .perStore,
                retryAfterMilliseconds: configuration.retryAfterMilliseconds
            ))
            return
        }

        let enqueuedAt = clock.now()
        let deadline = enqueuedAt + configuration.maxQueueWait
        waiterIDsInOrder.append(id)
        waiterStatesByID[id] = WaiterState(
            continuation: continuation,
            searchMode: searchMode,
            admissionClass: admissionClass,
            lifecycleCorrelation: lifecycleCorrelation,
            enqueuedAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            deadline: deadline,
            timeoutTask: nil
        )
        maximumWaiterCount = max(maximumWaiterCount, waiterStatesByID.count)
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Search.broadAdmissionWaitBegan,
            correlation: lifecycleCorrelation,
            admissionDimensions(
                searchMode: searchMode,
                admissionClass: admissionClass,
                metrics: metrics(),
                queueAgeBucket: "lt100ms"
            )
        )

        let timeoutTask = Task { [clock] in
            do {
                try await clock.sleepUntil(deadline)
                self.expireWaiter(id: id)
            } catch {
                // Grant and cancellation paths cancel the sleeper after removing the waiter.
            }
        }
        if waiterStatesByID[id] != nil {
            waiterStatesByID[id]?.timeoutTask = timeoutTask
        } else {
            timeoutTask.cancel()
        }
    }

    private func removeWaiter(id: UUID) -> WaiterState? {
        guard let state = waiterStatesByID.removeValue(forKey: id) else { return nil }
        if let index = waiterIDsInOrder.firstIndex(of: id) {
            waiterIDsInOrder.remove(at: index)
        }
        return state
    }

    private func cancelWaiter(id: UUID) {
        guard let state = removeWaiter(id: id) else { return }
        state.timeoutTask?.cancel()
        queuedCancellationCount &+= 1
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Search.broadAdmissionPermitCancelled,
            correlation: state.lifecycleCorrelation,
            admissionDimensions(
                outcome: "cancelled",
                searchMode: state.searchMode,
                admissionClass: state.admissionClass,
                metrics: metrics(),
                queueAgeBucket: Self.queueAgeBucket(since: state.enqueuedAtUptimeNanoseconds)
            )
        )
        state.continuation.resume(throwing: CancellationError())
    }

    private func expireWaiter(id: UUID) {
        guard let state = removeWaiter(id: id) else { return }
        waitExpiryCount &+= 1
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Search.broadAdmissionWaitExpired,
            correlation: state.lifecycleCorrelation,
            admissionDimensions(
                outcome: "waitExpired",
                searchMode: state.searchMode,
                admissionClass: state.admissionClass,
                metrics: metrics(),
                queueAgeBucket: Self.queueAgeBucket(milliseconds: configuration.maxQueueWaitMilliseconds)
            )
        )
        state.continuation.resume(throwing: StoreBackedWorkspaceSearchAdmissionError.waitExpired(
            retryAfterMilliseconds: configuration.retryAfterMilliseconds
        ))
    }

    private func release(_ acquisition: PermitAcquisition) {
        guard activeLeaseIDs.remove(acquisition.leaseID) != nil else { return }
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Search.broadAdmissionPermitReleased,
            correlation: acquisition.lifecycleCorrelation,
            admissionDimensions(
                outcome: "released",
                searchMode: acquisition.searchMode,
                admissionClass: acquisition.admissionClass,
                metrics: metrics(),
                queueAgeBucket: acquisition.queueAgeBucket
            )
        )
        promoteWaitersIfPossible()
    }

    private func promoteWaitersIfPossible() {
        while activeLeaseIDs.count < configuration.maxActiveLeases,
              let id = waiterIDsInOrder.first,
              let state = removeWaiter(id: id)
        {
            state.timeoutTask?.cancel()
            let acquisition = allocatePermit(
                searchMode: state.searchMode,
                admissionClass: state.admissionClass,
                lifecycleCorrelation: state.lifecycleCorrelation,
                waited: true,
                queueAgeBucket: Self.queueAgeBucket(since: state.enqueuedAtUptimeNanoseconds)
            )
            state.continuation.resume(returning: acquisition)
        }
    }

    private func allocatePermit(
        searchMode: SearchMode,
        admissionClass: BroadSearchAdmissionClass,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?,
        waited: Bool,
        queueAgeBucket: String = "immediate"
    ) -> PermitAcquisition {
        precondition(activeLeaseIDs.count < configuration.maxActiveLeases)
        let leaseID = UUID()
        activeLeaseIDs.insert(leaseID)
        grantCount &+= 1
        maximumActivePermitCount = max(maximumActivePermitCount, activeLeaseIDs.count)
        let acquisition = PermitAcquisition(
            leaseID: leaseID,
            searchMode: searchMode,
            admissionClass: admissionClass,
            lifecycleCorrelation: lifecycleCorrelation,
            waited: waited,
            queueAgeBucket: queueAgeBucket,
            metrics: metrics()
        )
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Search.broadAdmissionPermitAcquired,
            correlation: lifecycleCorrelation,
            admissionDimensions(
                outcome: waited ? "acquiredAfterWait" : "immediate",
                searchMode: searchMode,
                admissionClass: admissionClass,
                metrics: acquisition.metrics,
                queueAgeBucket: queueAgeBucket
            )
        )
        return acquisition
    }

    private func metrics() -> AdmissionMetrics {
        AdmissionMetrics(
            activeCount: activeLeaseIDs.count,
            queueDepth: waiterStatesByID.count
        )
    }

    private func admissionDimensions(
        outcome: String? = nil,
        searchMode: SearchMode,
        admissionClass: BroadSearchAdmissionClass,
        metrics: AdmissionMetrics,
        queueAgeBucket: String
    ) -> EditFlowPerf.Dimensions {
        EditFlowPerf.Dimensions(
            outcome: outcome,
            storeCapacity: configuration.maxActiveLeases,
            globalCapacity: 0,
            storeActiveCount: metrics.activeCount,
            globalActiveCount: 0,
            storeQueueDepth: metrics.queueDepth,
            globalQueueDepth: 0,
            searchMode: searchMode.rawValue,
            admissionClass: admissionClass.rawValue,
            queueAgeBucket: queueAgeBucket,
            queueDepth: metrics.queueDepth,
            waiterCount: metrics.queueDepth
        )
    }

    private static func waitOutcome(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let error = error as? StoreBackedWorkspaceSearchAdmissionError else { return "error" }
        switch error {
        case .queueFull:
            return "queueFull"
        case .waitExpired:
            return "waitExpired"
        case .contentReadQueueFull:
            return "error"
        }
    }

    private func queueAgeBucket(for error: Error) -> String {
        guard let error = error as? StoreBackedWorkspaceSearchAdmissionError else { return "immediate" }
        switch error {
        case .queueFull, .contentReadQueueFull:
            return "immediate"
        case .waitExpired:
            return Self.queueAgeBucket(milliseconds: configuration.maxQueueWaitMilliseconds)
        }
    }

    private static func queueAgeBucket(since enqueuedAtUptimeNanoseconds: UInt64) -> String {
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
        default:
            "gte5s"
        }
    }

    #if DEBUG
        func snapshotForTesting() -> Snapshot {
            Snapshot(
                configuration: configuration,
                activePermitCount: activeLeaseIDs.count,
                waiterCount: waiterStatesByID.count,
                grantCount: grantCount,
                overloadCount: overloadCount,
                waitExpiryCount: waitExpiryCount,
                queuedCancellationCount: queuedCancellationCount,
                maximumActivePermitCount: maximumActivePermitCount,
                maximumWaiterCount: maximumWaiterCount
            )
        }

        func configureForTesting(_ newConfiguration: Configuration) -> DebugConfigurationUpdateResult {
            guard activeLeaseIDs.isEmpty, waiterStatesByID.isEmpty else {
                return .busy(snapshotForTesting())
            }
            configuration = newConfiguration
            grantCount = 0
            overloadCount = 0
            waitExpiryCount = 0
            queuedCancellationCount = 0
            maximumActivePermitCount = 0
            maximumWaiterCount = 0
            return .applied(snapshotForTesting())
        }

        func resetConfigurationForTesting() -> DebugConfigurationUpdateResult {
            configureForTesting(.production)
        }

        func setPermitAcquiredHandlerForTesting(
            _ handler: (@Sendable () async -> Void)?
        ) {
            permitAcquiredHandlerForTesting = handler
        }
    #endif
}
