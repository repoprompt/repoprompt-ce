import Foundation

/// Owns ordered publisher-to-store ingress synchronously at the Combine sink boundary.
///
/// Every accepted publication is queued before the sink returns. One retained drain task per
/// root applies publications serially, preserving watcher and synthetic publication order while
/// allowing barriers to await an exact service-publication cut through canonical application.
package final class WorkspaceFileSystemIngressCoordinator: @unchecked Sendable {
    package struct Subscription: Hashable {
        let rootID: UUID
        let generation: UInt64
    }

    package struct AppliedSnapshot: Equatable {
        let acceptedServicePublicationSequence: UInt64
        let appliedServicePublicationSequence: UInt64
        let appliedWatcherWatermark: FileSystemWatcherIngressMailbox.Watermark
    }

    package typealias DrainHandler = @Sendable (FileSystemDeltaPublication, WorkspaceRuntimePerf.LifecycleCorrelation?) async -> Void

    private struct QueuedPublication {
        let publication: FileSystemDeltaPublication
        let lifecycleCorrelation: WorkspaceRuntimePerf.LifecycleCorrelation?
        let drainHandler: DrainHandler
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

        var pendingQueueCount: Int {
            queue.count - queueHead
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
        let targetServicePublicationSequence: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var rootStatesByID: [UUID: RootState] = [:]
    private var waitersByRootID: [UUID: [UUID: Waiter]] = [:]
    private var nextDrainToken: UInt64 = 0

    package func openPublisherIngress(rootID: UUID, drainHandler: @escaping DrainHandler) -> Subscription {
        lock.lock()
        defer { lock.unlock() }

        let state = rootState(for: rootID)
        state.generation &+= 1
        state.isOpen = true
        state.drainHandler = drainHandler
        scheduleDrainIfNeeded(rootID: rootID)
        return Subscription(rootID: rootID, generation: state.generation)
    }

    package func closePublisherIngress(rootID: UUID) {
        lock.lock()
        defer { lock.unlock() }

        guard let state = rootStatesByID[rootID] else { return }
        state.generation &+= 1
        state.isOpen = false
    }

    package func isPublisherIngressOpen(_ subscription: Subscription) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let state = rootStatesByID[subscription.rootID] else { return false }
        return state.isOpen && state.generation == subscription.generation
    }

    package func hasOpenPublisherIngress(rootID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return rootStatesByID[rootID]?.isOpen == true
    }

    @discardableResult
    package func accept(
        _ subscription: Subscription,
        publication: FileSystemDeltaPublication,
        lifecycleCorrelation: WorkspaceRuntimePerf.LifecycleCorrelation?
    ) -> Bool {
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
            drainHandler: drainHandler
        ))
        state.acceptedServicePublicationSequence = max(
            state.acceptedServicePublicationSequence,
            publication.servicePublicationSequence
        )
        scheduleDrainIfNeeded(rootID: subscription.rootID)
        return true
    }

    package func waitUntilApplied(rootID: UUID, servicePublicationSequence: UInt64) async {
        guard servicePublicationSequence > 0 else { return }
        await withCheckedContinuation { continuation in
            lock.lock()
            guard let state = rootStatesByID[rootID],
                  state.appliedServicePublicationSequence < servicePublicationSequence
            else {
                lock.unlock()
                continuation.resume()
                return
            }
            waitersByRootID[rootID, default: [:]][UUID()] = Waiter(
                targetServicePublicationSequence: servicePublicationSequence,
                continuation: continuation
            )
            lock.unlock()
        }
    }

    package func waitForCurrentPublisherIngress(rootIDs: Set<UUID>) async {
        let targets: [(rootID: UUID, servicePublicationSequence: UInt64)] = {
            lock.lock()
            defer { lock.unlock() }
            return rootIDs.compactMap { rootID in
                guard let state = rootStatesByID[rootID] else { return nil }
                return (rootID, state.acceptedServicePublicationSequence)
            }
        }()
        for target in targets {
            await waitUntilApplied(
                rootID: target.rootID,
                servicePublicationSequence: target.servicePublicationSequence
            )
        }
    }

    package func appliedSnapshot(rootID: UUID) -> AppliedSnapshot {
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

    package func pendingPublisherIngressCount(rootIDs: Set<UUID>) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return rootIDs.reduce(into: 0) { count, rootID in
            guard let state = rootStatesByID[rootID] else { return }
            count += state.pendingQueueCount + state.applyingCount
        }
    }

    package func finishPublisherIngress(rootIDs: Set<UUID>) {
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
        return queued
    }

    private func finishApplying(rootID: UUID, publication: FileSystemDeltaPublication) {
        var continuations: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        if let state = rootStatesByID[rootID] {
            state.applyingCount = max(0, state.applyingCount - 1)
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
