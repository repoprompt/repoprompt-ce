import Dispatch
import Foundation

/// Owns ordered publisher-to-store ingress synchronously at the Combine sink boundary.
///
/// Every accepted publication is queued before the sink returns. One retained drain task per
/// root applies publications serially, preserving watcher and synthetic publication order while
/// allowing barriers to await an exact service-publication cut through canonical application.
final class WorkspaceFileSystemIngressCoordinator: @unchecked Sendable {
    struct Subscription: Hashable {
        let rootID: UUID
        let generation: UInt64
    }

    struct AppliedSnapshot: Equatable {
        let acceptedServicePublicationSequence: UInt64
        let appliedServicePublicationSequence: UInt64
        let appliedWatcherWatermark: FileSystemWatcherIngressMailbox.Watermark
    }

    enum TerminationOutcome: String, Equatable {
        case graceful
        case forced
        case missing
        case superseded
    }

    struct TerminationReport: Equatable {
        let rootID: UUID
        let stateIdentity: UUID?
        let outcome: TerminationOutcome
        let graceNanoseconds: UInt64
        let queuedPublicationCount: Int
        let applyingPublicationCount: Int
        let waiterCount: Int
        let acceptedServicePublicationSequence: UInt64
        let appliedServicePublicationSequence: UInt64
        let acceptedAppliedSequenceGap: UInt64
        let appliedWatcherWatermark: UInt64
        let oldestOutstandingPublicationAgeMilliseconds: UInt64?
    }

    #if DEBUG
        struct DebugSnapshot: Equatable {
            let isOpen: Bool
            let queuedPublicationCount: Int
            let applyingPublicationCount: Int
            let outstandingPublicationCount: Int
            let waiterCount: Int
            let acceptedServicePublicationSequence: UInt64
            let appliedServicePublicationSequence: UInt64
            let acceptedAppliedSequenceGap: UInt64
            let appliedWatcherWatermark: UInt64
            let oldestOutstandingPublicationAgeMilliseconds: UInt64?
        }
    #endif

    typealias DrainHandler = @Sendable (FileSystemDeltaPublication, EditFlowPerf.LifecycleCorrelation?) async -> Void

    private struct QueuedPublication {
        let publication: FileSystemDeltaPublication
        let lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
        let drainHandler: DrainHandler
        let acceptedAtNanoseconds: UInt64
    }

    private final class RootState {
        let identity = UUID()
        var generation: UInt64 = 0
        var isOpen = false
        var queue: [QueuedPublication] = []
        var queueHead = 0
        var drainTask: Task<Void, Never>?
        var activeDrainToken: UInt64?
        var drainHandler: DrainHandler?
        var applyingCount = 0
        var acceptedServicePublicationSequence: UInt64 = 0
        var appliedServicePublicationSequence: UInt64 = 0
        var appliedWatcherWatermark = FileSystemWatcherIngressMailbox.Watermark.zero
        var applyingPublicationAcceptedAtNanoseconds: UInt64?

        var pendingQueueCount: Int {
            queue.count - queueHead
        }

        var oldestOutstandingPublicationAcceptedAtNanoseconds: UInt64? {
            let queued = queueHead < queue.count ? queue[queueHead].acceptedAtNanoseconds : nil
            return [applyingPublicationAcceptedAtNanoseconds, queued].compactMap(\.self).min()
        }

        func append(_ publication: QueuedPublication) {
            queue.append(publication)
        }

        func takeNextPublication() -> QueuedPublication? {
            guard queueHead < queue.count else { return nil }
            let publication = queue[queueHead]
            queueHead += 1
            compactConsumedPublicationsIfNeeded()
            return publication
        }

        private func compactConsumedPublicationsIfNeeded() {
            guard queueHead > 0 else { return }
            if queueHead == queue.count {
                queue.removeAll(keepingCapacity: true)
                queueHead = 0
            } else if queueHead >= 64, queueHead * 2 >= queue.count {
                queue.removeFirst(queueHead)
                queueHead = 0
            }
        }
    }

    private struct Waiter {
        let stateIdentity: UUID
        let targetServicePublicationSequence: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct TerminationCapture {
        let rootID: UUID
        let stateIdentity: UUID?
        let subscriptionGeneration: UInt64
        let targetServicePublicationSequence: UInt64
    }

    private let lock = NSLock()
    private var rootStatesByID: [UUID: RootState] = [:]
    private var waitersByRootID: [UUID: [UUID: Waiter]] = [:]
    private var nextDrainToken: UInt64 = 0
    private var nextSubscriptionGeneration: UInt64 = 0
    private let nowNanoseconds: @Sendable () -> UInt64
    #if DEBUG
        private let debugFinishApplyingHandler: (@Sendable (UUID, UInt64) -> Void)?
    #endif

    #if DEBUG
        init(
            debugNowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
            debugFinishApplyingHandler: (@Sendable (UUID, UInt64) -> Void)? = nil
        ) {
            nowNanoseconds = debugNowNanoseconds
            self.debugFinishApplyingHandler = debugFinishApplyingHandler
        }
    #else
        init() {
            nowNanoseconds = { DispatchTime.now().uptimeNanoseconds }
        }
    #endif

    func openPublisherIngress(rootID: UUID, drainHandler: @escaping DrainHandler) -> Subscription {
        lock.lock()
        defer { lock.unlock() }

        let state = rootState(for: rootID)
        nextSubscriptionGeneration &+= 1
        state.generation = nextSubscriptionGeneration
        state.isOpen = true
        state.drainHandler = drainHandler
        scheduleDrainIfNeeded(rootID: rootID, stateIdentity: state.identity)
        return Subscription(rootID: rootID, generation: state.generation)
    }

    func closePublisherIngress(rootID: UUID) {
        lock.lock()
        defer { lock.unlock() }

        guard let state = rootStatesByID[rootID] else { return }
        nextSubscriptionGeneration &+= 1
        state.generation = nextSubscriptionGeneration
        state.isOpen = false
    }

    func isPublisherIngressOpen(_ subscription: Subscription) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let state = rootStatesByID[subscription.rootID] else { return false }
        return state.isOpen && state.generation == subscription.generation
    }

    func hasOpenPublisherIngress(rootID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return rootStatesByID[rootID]?.isOpen == true
    }

    @discardableResult
    func accept(
        _ subscription: Subscription,
        publication: FileSystemDeltaPublication,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
    ) -> Bool {
        let acceptedAtNanoseconds = nowNanoseconds()
        lock.lock()
        defer { lock.unlock() }

        guard let state = rootStatesByID[subscription.rootID],
              state.isOpen,
              state.generation == subscription.generation,
              let drainHandler = state.drainHandler
        else {
            return false
        }
        state.append(QueuedPublication(
            publication: publication,
            lifecycleCorrelation: lifecycleCorrelation,
            drainHandler: drainHandler,
            acceptedAtNanoseconds: acceptedAtNanoseconds
        ))
        state.acceptedServicePublicationSequence = max(
            state.acceptedServicePublicationSequence,
            publication.servicePublicationSequence
        )
        scheduleDrainIfNeeded(rootID: subscription.rootID, stateIdentity: state.identity)
        return true
    }

    func waitUntilApplied(rootID: UUID, servicePublicationSequence: UInt64) async {
        guard servicePublicationSequence > 0 else { return }
        let stateIdentity: UUID? = {
            lock.lock()
            defer { lock.unlock() }
            return rootStatesByID[rootID]?.identity
        }()
        guard let stateIdentity else { return }
        await waitUntilApplied(
            rootID: rootID,
            stateIdentity: stateIdentity,
            servicePublicationSequence: servicePublicationSequence
        )
    }

    func waitForCurrentPublisherIngress(rootIDs: Set<UUID>) async {
        let targets: [(rootID: UUID, stateIdentity: UUID, servicePublicationSequence: UInt64)] = {
            lock.lock()
            defer { lock.unlock() }
            return rootIDs.compactMap { rootID in
                guard let state = rootStatesByID[rootID] else { return nil }
                return (rootID, state.identity, state.acceptedServicePublicationSequence)
            }
        }()
        for target in targets {
            guard !Task.isCancelled else { break }
            await waitUntilApplied(
                rootID: target.rootID,
                stateIdentity: target.stateIdentity,
                servicePublicationSequence: target.servicePublicationSequence
            )
        }
    }

    func terminateClosedPublisherIngress(
        rootIDs: [UUID],
        gracefulDrainTimeoutNanoseconds: UInt64,
        sleep: @escaping @Sendable (UInt64) async -> Void
    ) async -> [TerminationReport] {
        let captures: [TerminationCapture] = {
            lock.lock()
            defer { lock.unlock() }
            return rootIDs.map { rootID in
                guard let state = rootStatesByID[rootID] else {
                    return TerminationCapture(
                        rootID: rootID,
                        stateIdentity: nil,
                        subscriptionGeneration: 0,
                        targetServicePublicationSequence: 0
                    )
                }
                return TerminationCapture(
                    rootID: rootID,
                    stateIdentity: state.identity,
                    subscriptionGeneration: state.generation,
                    targetServicePublicationSequence: state.acceptedServicePublicationSequence
                )
            }
        }()

        return await withTaskGroup(of: (Int, TerminationReport).self) { group in
            for (index, capture) in captures.enumerated() {
                group.addTask { [self] in
                    let report = await terminateClosedPublisherIngress(
                        capture: capture,
                        gracefulDrainTimeoutNanoseconds: gracefulDrainTimeoutNanoseconds,
                        sleep: sleep
                    )
                    return (index, report)
                }
            }
            var reports: [(Int, TerminationReport)] = []
            for await report in group {
                reports.append(report)
            }
            return reports.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    func appliedSnapshot(rootID: UUID) -> AppliedSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard let state = rootStatesByID[rootID] else {
            return AppliedSnapshot(
                acceptedServicePublicationSequence: 0,
                appliedServicePublicationSequence: 0,
                appliedWatcherWatermark: .zero
            )
        }
        return AppliedSnapshot(
            acceptedServicePublicationSequence: state.acceptedServicePublicationSequence,
            appliedServicePublicationSequence: state.appliedServicePublicationSequence,
            appliedWatcherWatermark: state.appliedWatcherWatermark
        )
    }

    func pendingPublisherIngressCount(rootIDs: Set<UUID>) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return rootIDs.reduce(into: 0) { count, rootID in
            guard let state = rootStatesByID[rootID] else { return }
            count += state.pendingQueueCount + state.applyingCount
        }
    }

    #if DEBUG
        func debugSnapshot(rootID: UUID) -> DebugSnapshot {
            let now = nowNanoseconds()
            lock.lock()
            defer { lock.unlock() }
            guard let state = rootStatesByID[rootID] else {
                return DebugSnapshot(
                    isOpen: false,
                    queuedPublicationCount: 0,
                    applyingPublicationCount: 0,
                    outstandingPublicationCount: 0,
                    waiterCount: 0,
                    acceptedServicePublicationSequence: 0,
                    appliedServicePublicationSequence: 0,
                    acceptedAppliedSequenceGap: 0,
                    appliedWatcherWatermark: 0,
                    oldestOutstandingPublicationAgeMilliseconds: nil
                )
            }
            return DebugSnapshot(
                isOpen: state.isOpen,
                queuedPublicationCount: state.pendingQueueCount,
                applyingPublicationCount: state.applyingCount,
                outstandingPublicationCount: state.pendingQueueCount + state.applyingCount,
                waiterCount: waiterCount(rootID: rootID, stateIdentity: state.identity),
                acceptedServicePublicationSequence: state.acceptedServicePublicationSequence,
                appliedServicePublicationSequence: state.appliedServicePublicationSequence,
                acceptedAppliedSequenceGap: acceptedAppliedSequenceGap(state),
                appliedWatcherWatermark: state.appliedWatcherWatermark.rawValue,
                oldestOutstandingPublicationAgeMilliseconds: oldestOutstandingAgeMilliseconds(state, now: now)
            )
        }
    #endif

    func finishPublisherIngress(rootIDs: Set<UUID>) {
        var continuations: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        for rootID in rootIDs {
            guard let state = rootStatesByID[rootID],
                  !state.isOpen,
                  state.pendingQueueCount == 0,
                  state.applyingCount == 0
            else { continue }
            rootStatesByID.removeValue(forKey: rootID)
            continuations.append(contentsOf: removeWaiters(rootID: rootID, stateIdentity: state.identity))
        }
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    private func waitUntilApplied(
        rootID: UUID,
        stateIdentity: UUID,
        servicePublicationSequence: UInt64
    ) async {
        guard servicePublicationSequence > 0 else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard !Task.isCancelled,
                      let state = rootStatesByID[rootID],
                      state.identity == stateIdentity,
                      state.appliedServicePublicationSequence < servicePublicationSequence
                else {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waitersByRootID[rootID, default: [:]][waiterID] = Waiter(
                    stateIdentity: stateIdentity,
                    targetServicePublicationSequence: servicePublicationSequence,
                    continuation: continuation
                )
                lock.unlock()
            }
        } onCancel: {
            cancelWaiter(rootID: rootID, waiterID: waiterID)
        }
    }

    private func terminateClosedPublisherIngress(
        capture: TerminationCapture,
        gracefulDrainTimeoutNanoseconds: UInt64,
        sleep: @escaping @Sendable (UInt64) async -> Void
    ) async -> TerminationReport {
        guard let stateIdentity = capture.stateIdentity else {
            return emptyTerminationReport(
                rootID: capture.rootID,
                outcome: .missing,
                graceNanoseconds: gracefulDrainTimeoutNanoseconds
            )
        }

        let gracefulCompleted = await withTaskGroup(of: Bool.self) { group in
            group.addTask { [self] in
                await waitUntilApplied(
                    rootID: capture.rootID,
                    stateIdentity: stateIdentity,
                    servicePublicationSequence: capture.targetServicePublicationSequence
                )
                return true
            }
            group.addTask {
                await sleep(gracefulDrainTimeoutNanoseconds)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        if gracefulCompleted,
           let report = finishGracefulTermination(
               rootID: capture.rootID,
               stateIdentity: stateIdentity,
               subscriptionGeneration: capture.subscriptionGeneration,
               graceNanoseconds: gracefulDrainTimeoutNanoseconds
           )
        {
            return report
        }
        return forceTermination(
            rootID: capture.rootID,
            stateIdentity: stateIdentity,
            subscriptionGeneration: capture.subscriptionGeneration,
            graceNanoseconds: gracefulDrainTimeoutNanoseconds
        )
    }

    private func finishGracefulTermination(
        rootID: UUID,
        stateIdentity: UUID,
        subscriptionGeneration: UInt64,
        graceNanoseconds: UInt64
    ) -> TerminationReport? {
        let report: TerminationReport
        let continuations: [CheckedContinuation<Void, Never>]
        lock.lock()
        guard let state = rootStatesByID[rootID] else {
            lock.unlock()
            return emptyTerminationReport(rootID: rootID, outcome: .superseded, graceNanoseconds: graceNanoseconds)
        }
        guard state.identity == stateIdentity,
              state.generation == subscriptionGeneration,
              !state.isOpen
        else {
            report = makeTerminationReport(
                rootID: rootID,
                state: state,
                outcome: .superseded,
                graceNanoseconds: graceNanoseconds
            )
            lock.unlock()
            return report
        }
        guard state.pendingQueueCount == 0, state.applyingCount == 0 else {
            lock.unlock()
            return nil
        }
        report = makeTerminationReport(
            rootID: rootID,
            state: state,
            outcome: .graceful,
            graceNanoseconds: graceNanoseconds
        )
        rootStatesByID.removeValue(forKey: rootID)
        continuations = removeWaiters(rootID: rootID, stateIdentity: stateIdentity)
        lock.unlock()
        continuations.forEach { $0.resume() }
        return report
    }

    private func forceTermination(
        rootID: UUID,
        stateIdentity: UUID,
        subscriptionGeneration: UInt64,
        graceNanoseconds: UInt64
    ) -> TerminationReport {
        let report: TerminationReport
        let continuations: [CheckedContinuation<Void, Never>]
        let drainTask: Task<Void, Never>?
        lock.lock()
        guard let state = rootStatesByID[rootID] else {
            lock.unlock()
            return emptyTerminationReport(rootID: rootID, outcome: .superseded, graceNanoseconds: graceNanoseconds)
        }
        guard state.identity == stateIdentity,
              state.generation == subscriptionGeneration,
              !state.isOpen
        else {
            report = makeTerminationReport(
                rootID: rootID,
                state: state,
                outcome: .superseded,
                graceNanoseconds: graceNanoseconds
            )
            lock.unlock()
            return report
        }
        report = makeTerminationReport(
            rootID: rootID,
            state: state,
            outcome: .forced,
            graceNanoseconds: graceNanoseconds
        )
        rootStatesByID.removeValue(forKey: rootID)
        continuations = removeWaiters(rootID: rootID, stateIdentity: stateIdentity)
        drainTask = state.drainTask
        lock.unlock()
        drainTask?.cancel()
        continuations.forEach { $0.resume() }
        return report
    }

    private func rootState(for rootID: UUID) -> RootState {
        if let state = rootStatesByID[rootID] { return state }
        let state = RootState()
        rootStatesByID[rootID] = state
        return state
    }

    private func scheduleDrainIfNeeded(rootID: UUID, stateIdentity: UUID) {
        guard let state = rootStatesByID[rootID],
              state.identity == stateIdentity,
              state.drainTask == nil,
              state.pendingQueueCount > 0
        else { return }
        nextDrainToken &+= 1
        let token = nextDrainToken
        state.activeDrainToken = token
        state.drainTask = Task { [self] in
            await drain(rootID: rootID, stateIdentity: stateIdentity, token: token)
        }
    }

    private func drain(rootID: UUID, stateIdentity: UUID, token: UInt64) async {
        while let queued = takeNextPublication(rootID: rootID, stateIdentity: stateIdentity, token: token) {
            await queued.drainHandler(queued.publication, queued.lifecycleCorrelation)
            finishApplying(
                rootID: rootID,
                stateIdentity: stateIdentity,
                token: token,
                publication: queued.publication
            )
        }
        finishDrain(rootID: rootID, stateIdentity: stateIdentity, token: token)
    }

    private func finishDrain(rootID: UUID, stateIdentity: UUID, token: UInt64) {
        lock.lock()
        if let state = rootStatesByID[rootID],
           state.identity == stateIdentity,
           state.activeDrainToken == token
        {
            state.drainTask = nil
            state.activeDrainToken = nil
            scheduleDrainIfNeeded(rootID: rootID, stateIdentity: stateIdentity)
        }
        lock.unlock()
    }

    private func takeNextPublication(rootID: UUID, stateIdentity: UUID, token: UInt64) -> QueuedPublication? {
        lock.lock()
        defer { lock.unlock() }
        guard let state = rootStatesByID[rootID],
              state.identity == stateIdentity,
              state.activeDrainToken == token,
              let queued = state.takeNextPublication()
        else { return nil }
        state.applyingCount += 1
        state.applyingPublicationAcceptedAtNanoseconds = queued.acceptedAtNanoseconds
        return queued
    }

    private func cancelWaiter(rootID: UUID, waiterID: UUID) {
        let continuation: CheckedContinuation<Void, Never>?
        lock.lock()
        continuation = waitersByRootID[rootID]?.removeValue(forKey: waiterID)?.continuation
        if waitersByRootID[rootID]?.isEmpty == true {
            waitersByRootID.removeValue(forKey: rootID)
        }
        lock.unlock()
        continuation?.resume()
    }

    private func finishApplying(
        rootID: UUID,
        stateIdentity: UUID,
        token: UInt64,
        publication: FileSystemDeltaPublication
    ) {
        var continuations: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        if let state = rootStatesByID[rootID],
           state.identity == stateIdentity,
           state.activeDrainToken == token
        {
            state.applyingCount = max(0, state.applyingCount - 1)
            state.applyingPublicationAcceptedAtNanoseconds = nil
            state.appliedServicePublicationSequence = max(
                state.appliedServicePublicationSequence,
                publication.servicePublicationSequence
            )
            if let watermark = publication.watcherAcceptedWatermark {
                state.appliedWatcherWatermark = max(state.appliedWatcherWatermark, watermark)
            }
            if var waiters = waitersByRootID[rootID] {
                for waiterID in Array(waiters.keys) {
                    guard let waiter = waiters[waiterID],
                          waiter.stateIdentity == stateIdentity,
                          waiter.targetServicePublicationSequence <= state.appliedServicePublicationSequence
                    else { continue }
                    waiters.removeValue(forKey: waiterID)
                    continuations.append(waiter.continuation)
                }
                if waiters.isEmpty {
                    waitersByRootID.removeValue(forKey: rootID)
                } else {
                    waitersByRootID[rootID] = waiters
                }
            }
        }
        lock.unlock()
        continuations.forEach { $0.resume() }
        #if DEBUG
            debugFinishApplyingHandler?(rootID, publication.servicePublicationSequence)
        #endif
    }

    private func removeWaiters(rootID: UUID, stateIdentity: UUID) -> [CheckedContinuation<Void, Never>] {
        guard var waiters = waitersByRootID[rootID] else { return [] }
        var continuations: [CheckedContinuation<Void, Never>] = []
        for waiterID in Array(waiters.keys) {
            guard let waiter = waiters[waiterID], waiter.stateIdentity == stateIdentity else { continue }
            waiters.removeValue(forKey: waiterID)
            continuations.append(waiter.continuation)
        }
        if waiters.isEmpty {
            waitersByRootID.removeValue(forKey: rootID)
        } else {
            waitersByRootID[rootID] = waiters
        }
        return continuations
    }

    private func waiterCount(rootID: UUID, stateIdentity: UUID) -> Int {
        waitersByRootID[rootID]?.values.count(where: { $0.stateIdentity == stateIdentity }) ?? 0
    }

    private func makeTerminationReport(
        rootID: UUID,
        state: RootState,
        outcome: TerminationOutcome,
        graceNanoseconds: UInt64
    ) -> TerminationReport {
        TerminationReport(
            rootID: rootID,
            stateIdentity: state.identity,
            outcome: outcome,
            graceNanoseconds: graceNanoseconds,
            queuedPublicationCount: state.pendingQueueCount,
            applyingPublicationCount: state.applyingCount,
            waiterCount: waiterCount(rootID: rootID, stateIdentity: state.identity),
            acceptedServicePublicationSequence: state.acceptedServicePublicationSequence,
            appliedServicePublicationSequence: state.appliedServicePublicationSequence,
            acceptedAppliedSequenceGap: acceptedAppliedSequenceGap(state),
            appliedWatcherWatermark: state.appliedWatcherWatermark.rawValue,
            oldestOutstandingPublicationAgeMilliseconds: oldestOutstandingAgeMilliseconds(
                state,
                now: nowNanoseconds()
            )
        )
    }

    private func emptyTerminationReport(
        rootID: UUID,
        outcome: TerminationOutcome,
        graceNanoseconds: UInt64
    ) -> TerminationReport {
        TerminationReport(
            rootID: rootID,
            stateIdentity: nil,
            outcome: outcome,
            graceNanoseconds: graceNanoseconds,
            queuedPublicationCount: 0,
            applyingPublicationCount: 0,
            waiterCount: 0,
            acceptedServicePublicationSequence: 0,
            appliedServicePublicationSequence: 0,
            acceptedAppliedSequenceGap: 0,
            appliedWatcherWatermark: 0,
            oldestOutstandingPublicationAgeMilliseconds: nil
        )
    }

    private func acceptedAppliedSequenceGap(_ state: RootState) -> UInt64 {
        guard state.acceptedServicePublicationSequence >= state.appliedServicePublicationSequence else { return 0 }
        return state.acceptedServicePublicationSequence - state.appliedServicePublicationSequence
    }

    private func oldestOutstandingAgeMilliseconds(_ state: RootState, now: UInt64) -> UInt64? {
        state.oldestOutstandingPublicationAcceptedAtNanoseconds.map { acceptedAt in
            Self.elapsedMilliseconds(since: acceptedAt, now: now)
        }
    }

    private static func elapsedMilliseconds(since start: UInt64, now: UInt64) -> UInt64 {
        guard now >= start else { return 0 }
        return (now - start) / 1_000_000
    }
}
