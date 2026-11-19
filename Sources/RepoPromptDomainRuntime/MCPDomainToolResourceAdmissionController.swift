import Foundation

package enum MCPDomainToolAdmissionLimits {
    /// Correctness ordering, independent of host capacity.
    package static let exclusiveConnection = 1
    // Outer widths bound pending calls; physical work shares HostResourceBudget.
    // Control waits must remain independent so cancel/stop can make progress.
    // Preserve at least the existing wait/cancel headroom on small hosts: these
    // permits often represent suspended control calls rather than CPU work.
    package static let controlConnection = max(8, HostResourceCapacity.baseline.total)
    package static let smallReadConnection = HostResourceCapacity.baseline.cpu
    package static let smallReadPerWindow = HostResourceCapacity.baseline.cpu
    package static let fileReadConnection = ContentReadConcurrencyCapacity.maximumConcurrentReads
    package static let fileReadPerWindow = ContentReadConcurrencyCapacity.maximumConcurrentReads
    package static let gitReadConnection = max(1, HostResourceCapacity.baseline.subprocess)
    package static let fileSearchConnection = HostResourceCapacity.baseline.cpu
    /// Same-repository snapshot exclusion is not a host-utilization knob.
    package static let gitReadPerRepository = 1
}

/// Protocol-neutral, cancellation-safe admission keyed by the physical state resource.
/// Connection lanes provide client ordering; this controller bounds cross-connection work.
package final class MCPDomainToolResourceAdmissionController: @unchecked Sendable {
    // Preserve the existing explicit package sendability contracts.
    // swiftformat:disable redundantSendable
    package enum AdmissionError: Error, Equatable, Sendable {
        case closed
    }

    package struct Snapshot: Equatable, Sendable {
        package let activeLeaseCount: Int
        package let waiterCount: Int
        package let isClosed: Bool
    }

    package enum Resource: Hashable, Sendable {
        case appWide
        case window(Int)
        case repository(String)
    }

    // swiftformat:enable redundantSendable

    package final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var releaseAction: (() -> Void)?

        init(releaseAction: @escaping () -> Void) {
            self.releaseAction = releaseAction
        }

        @discardableResult
        package func release() -> Bool {
            let action: (() -> Void)? = lock.withLock {
                defer { releaseAction = nil }
                return releaseAction
            }
            action?()
            return action != nil
        }

        deinit {
            release()
        }
    }

    /// Indexed FIFO so handing off the head or cancelling any queued waiter
    /// only touches that waiter and its neighbors under the controller lock.
    private struct WaiterQueue {
        struct Waiter {
            let continuation: CheckedContinuation<Lease, Error>
            var previousID: UUID?
            var nextID: UUID?
        }

        private(set) var waiters: [UUID: Waiter] = [:]
        private var firstID: UUID?
        private var lastID: UUID?

        mutating func append(_ id: UUID, continuation: CheckedContinuation<Lease, Error>) {
            if let lastID {
                waiters[lastID]?.nextID = id
            } else {
                firstID = id
            }
            waiters[id] = Waiter(continuation: continuation, previousID: lastID)
            lastID = id
        }

        mutating func popFirst() -> CheckedContinuation<Lease, Error>? {
            guard let firstID else { return nil }
            return remove(firstID)
        }

        mutating func remove(_ id: UUID) -> CheckedContinuation<Lease, Error>? {
            guard let waiter = waiters.removeValue(forKey: id) else { return nil }
            if let previousID = waiter.previousID {
                waiters[previousID]?.nextID = waiter.nextID
            } else {
                firstID = waiter.nextID
            }
            if let nextID = waiter.nextID {
                waiters[nextID]?.previousID = waiter.previousID
            } else {
                lastID = waiter.previousID
            }
            return waiter.continuation
        }
    }

    package let limit: Int
    private let lock = NSLock()
    private var activeCountByResource: [Resource: Int] = [:]
    private var waitersByResource: [Resource: WaiterQueue] = [:]
    private var isClosed = false

    package init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    package func acquire(
        _ resource: Resource,
        admissionDeadline: MCPDomainAdmissionDeadline? = nil
    ) async throws -> Lease {
        guard let admissionDeadline else {
            return try await acquireWithoutDeadline(resource)
        }
        try admissionDeadline.check()
        return try await withThrowingTaskGroup(of: Lease.self) { group in
            group.addTask {
                try await self.acquireWithoutDeadline(resource)
            }
            group.addTask {
                try await admissionDeadline.waitUntilExpired()
            }
            do {
                guard let lease = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                try? await group.waitForAll()
                do {
                    try admissionDeadline.check()
                    return lease
                } catch {
                    lease.release()
                    throw error
                }
            } catch {
                group.cancelAll()
                try? await group.waitForAll()
                throw error
            }
        }
    }

    private func acquireWithoutDeadline(_ resource: Resource) async throws -> Lease {
        try Task.checkCancellation()

        let waiterID = UUID()
        let lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediateResult: Result<Lease, Error>? = lock.withLock {
                    // Cancellation before insertion is visible on the task;
                    // after insertion the handler removes the waiter under the same lock.
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    guard !isClosed else {
                        return .failure(AdmissionError.closed)
                    }
                    guard canAcquire(resource), waitersByResource[resource] == nil else {
                        waitersByResource[resource, default: WaiterQueue()].append(waiterID, continuation: continuation)
                        return nil
                    }
                    activate(resource)
                    return .success(makeLease(for: resource))
                }
                if let immediateResult {
                    continuation.resume(with: immediateResult)
                }
            }
        } onCancel: {
            self.cancelWaiter(waiterID, for: resource)
        }

        do {
            try Task.checkCancellation()
            return lease
        } catch {
            lease.release()
            throw error
        }
    }

    package func activeCount(for resource: Resource) -> Int {
        lock.withLock { activeCountByResource[resource] ?? 0 }
    }

    package func waiterCount(for resource: Resource) -> Int {
        lock.withLock { waitersByResource[resource]?.waiters.count ?? 0 }
    }

    package func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                activeLeaseCount: activeCountByResource.values.reduce(0, +),
                waiterCount: waitersByResource.values.reduce(0) { $0 + $1.waiters.count },
                isClosed: isClosed
            )
        }
    }

    @discardableResult
    package func close() -> Int {
        let queues: [Resource: WaiterQueue] = lock.withLock {
            guard !isClosed else { return [:] }
            isClosed = true
            let queues = waitersByResource
            waitersByResource = [:]
            return queues
        }
        var cancelledCount = 0
        for queue in queues.values {
            for waiter in queue.waiters.values {
                waiter.continuation.resume(throwing: AdmissionError.closed)
                cancelledCount += 1
            }
        }
        return cancelledCount
    }

    private func canAcquire(_ resource: Resource) -> Bool {
        (activeCountByResource[resource] ?? 0) < limit
    }

    private func activate(_ resource: Resource) {
        activeCountByResource[resource, default: 0] += 1
    }

    private func makeLease(for resource: Resource) -> Lease {
        Lease { [weak self] in
            self?.release(resource)
        }
    }

    private func release(_ resource: Resource) {
        let handoffs: [(CheckedContinuation<Lease, Error>, Lease)] = lock.withLock {
            let nextCount = max(0, (activeCountByResource[resource] ?? 0) - 1)
            if nextCount == 0 {
                activeCountByResource.removeValue(forKey: resource)
            } else {
                activeCountByResource[resource] = nextCount
            }

            var handoffs: [(CheckedContinuation<Lease, Error>, Lease)] = []
            while !isClosed, canAcquire(resource), let next = waitersByResource[resource]?.popFirst() {
                removeEmptyWaiterQueue(for: resource)
                activate(resource)
                handoffs.append((next, makeLease(for: resource)))
            }
            return handoffs
        }
        for handoff in handoffs {
            handoff.0.resume(returning: handoff.1)
        }
    }

    private func cancelWaiter(_ waiterID: UUID, for resource: Resource) {
        let continuation = lock.withLock {
            let removed = waitersByResource[resource]?.remove(waiterID)
            removeEmptyWaiterQueue(for: resource)
            return removed
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func removeEmptyWaiterQueue(for resource: Resource) {
        if waitersByResource[resource]?.waiters.isEmpty == true {
            waitersByResource.removeValue(forKey: resource)
        }
    }
}
