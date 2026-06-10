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
        #if DEBUG
            let acceptedAtNanoseconds: UInt64
        #endif
    }

    private final class RootState {
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
        #if DEBUG
            var applyingPublicationAcceptedAtNanoseconds: UInt64?
        #endif

        var pendingQueueCount: Int {
            queue.count - queueHead
        }

        #if DEBUG
            var oldestOutstandingPublicationAcceptedAtNanoseconds: UInt64? {
                let queued = queueHead < queue.count ? queue[queueHead].acceptedAtNanoseconds : nil
                return [applyingPublicationAcceptedAtNanoseconds, queued].compactMap(\.self).min()
            }
        #endif

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
        let targetServicePublicationSequence: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var rootStatesByID: [UUID: RootState] = [:]
    private var waitersByRootID: [UUID: [UUID: Waiter]] = [:]
    private var nextDrainToken: UInt64 = 0
    #if DEBUG
        private let debugNowNanoseconds: @Sendable () -> UInt64

        init(
            debugNowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
        ) {
            self.debugNowNanoseconds = debugNowNanoseconds
        }
    #else
        init() {}
    #endif

    func openPublisherIngress(rootID: UUID, drainHandler: @escaping DrainHandler) -> Subscription {
        lock.lock()
        defer { lock.unlock() }

        let state = rootState(for: rootID)
        state.generation &+= 1
        state.isOpen = true
        state.drainHandler = drainHandler
        scheduleDrainIfNeeded(rootID: rootID)
        return Subscription(rootID: rootID, generation: state.generation)
    }

    func closePublisherIngress(rootID: UUID) {
        lock.lock()
        defer { lock.unlock() }

        guard let state = rootStatesByID[rootID] else { return }
        state.generation &+= 1
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
        #if DEBUG
            let acceptedAtNanoseconds = debugNowNanoseconds()
        #endif
        lock.lock()
        defer { lock.unlock() }

        guard let state = rootStatesByID[subscription.rootID],
              state.isOpen,
              state.generation == subscription.generation,
              let drainHandler = state.drainHandler
        else {
            return false
        }
        #if DEBUG
            state.append(QueuedPublication(
                publication: publication,
                lifecycleCorrelation: lifecycleCorrelation,
                drainHandler: drainHandler,
                acceptedAtNanoseconds: acceptedAtNanoseconds
            ))
        #else
            state.append(QueuedPublication(
                publication: publication,
                lifecycleCorrelation: lifecycleCorrelation,
                drainHandler: drainHandler
            ))
        #endif
        state.acceptedServicePublicationSequence = max(
            state.acceptedServicePublicationSequence,
            publication.servicePublicationSequence
        )
        scheduleDrainIfNeeded(rootID: subscription.rootID)
        return true
    }

    func waitUntilApplied(rootID: UUID, servicePublicationSequence: UInt64) async {
        guard servicePublicationSequence > 0 else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard !Task.isCancelled,
                      let state = rootStatesByID[rootID],
                      state.appliedServicePublicationSequence < servicePublicationSequence
                else {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waitersByRootID[rootID, default: [:]][waiterID] = Waiter(
                    targetServicePublicationSequence: servicePublicationSequence,
                    continuation: continuation
                )
                lock.unlock()
            }
        } onCancel: {
            cancelWaiter(rootID: rootID, waiterID: waiterID)
        }
    }

    func waitForCurrentPublisherIngress(rootIDs: Set<UUID>) async {
        let targets: [(rootID: UUID, servicePublicationSequence: UInt64)] = {
            lock.lock()
            defer { lock.unlock() }
            return rootIDs.compactMap { rootID in
                guard let state = rootStatesByID[rootID] else { return nil }
                return (rootID, state.acceptedServicePublicationSequence)
            }
        }()
        for target in targets {
            guard !Task.isCancelled else { break }
            await waitUntilApplied(
                rootID: target.rootID,
                servicePublicationSequence: target.servicePublicationSequence
            )
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
            let now = debugNowNanoseconds()
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
            let gap = state.acceptedServicePublicationSequence >= state.appliedServicePublicationSequence
                ? state.acceptedServicePublicationSequence - state.appliedServicePublicationSequence
                : 0
            let oldestAge = state.oldestOutstandingPublicationAcceptedAtNanoseconds.map { acceptedAt in
                Self.elapsedMilliseconds(since: acceptedAt, now: now)
            }
            return DebugSnapshot(
                isOpen: state.isOpen,
                queuedPublicationCount: state.pendingQueueCount,
                applyingPublicationCount: state.applyingCount,
                outstandingPublicationCount: state.pendingQueueCount + state.applyingCount,
                waiterCount: waitersByRootID[rootID]?.count ?? 0,
                acceptedServicePublicationSequence: state.acceptedServicePublicationSequence,
                appliedServicePublicationSequence: state.appliedServicePublicationSequence,
                acceptedAppliedSequenceGap: gap,
                appliedWatcherWatermark: state.appliedWatcherWatermark.rawValue,
                oldestOutstandingPublicationAgeMilliseconds: oldestAge
            )
        }

        private static func elapsedMilliseconds(since start: UInt64, now: UInt64) -> UInt64 {
            guard now >= start else { return 0 }
            return (now - start) / 1_000_000
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
            continuations.append(contentsOf: (waitersByRootID.removeValue(forKey: rootID) ?? [:]).values.map(\.continuation))
        }
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    private func rootState(for rootID: UUID) -> RootState {
        if let state = rootStatesByID[rootID] { return state }
        let state = RootState()
        rootStatesByID[rootID] = state
        return state
    }

    private func scheduleDrainIfNeeded(rootID: UUID) {
        guard let state = rootStatesByID[rootID],
              state.drainTask == nil,
              state.pendingQueueCount > 0
        else { return }
        nextDrainToken &+= 1
        let token = nextDrainToken
        state.activeDrainToken = token
        state.drainTask = Task { [self] in
            await drain(rootID: rootID, token: token)
        }
    }

    private func drain(rootID: UUID, token: UInt64) async {
        while let queued = takeNextPublication(rootID: rootID) {
            await queued.drainHandler(queued.publication, queued.lifecycleCorrelation)
            finishApplying(rootID: rootID, publication: queued.publication)
        }
        lock.lock()
        if let state = rootStatesByID[rootID], state.activeDrainToken == token {
            state.drainTask = nil
            state.activeDrainToken = nil
            scheduleDrainIfNeeded(rootID: rootID)
        }
        lock.unlock()
    }

    private func takeNextPublication(rootID: UUID) -> QueuedPublication? {
        lock.lock()
        defer { lock.unlock() }
        guard let state = rootStatesByID[rootID], let queued = state.takeNextPublication() else { return nil }
        state.applyingCount += 1
        #if DEBUG
            state.applyingPublicationAcceptedAtNanoseconds = queued.acceptedAtNanoseconds
        #endif
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

    private func finishApplying(rootID: UUID, publication: FileSystemDeltaPublication) {
        var continuations: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        if let state = rootStatesByID[rootID] {
            state.applyingCount = max(0, state.applyingCount - 1)
            #if DEBUG
                state.applyingPublicationAcceptedAtNanoseconds = nil
            #endif
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
    }
}
