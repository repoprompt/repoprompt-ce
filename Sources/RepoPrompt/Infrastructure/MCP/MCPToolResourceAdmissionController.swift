import Foundation

/// Bounded admission keyed by the state resource being protected. Connection lanes provide
/// client ordering; this controller provides cross-connection mutation and read/store limits.
final class MCPToolResourceAdmissionController: @unchecked Sendable {
    enum Resource: Hashable {
        case appWide
        case window(Int)
    }

    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var releaseAction: (() -> Void)?

        fileprivate init(releaseAction: @escaping () -> Void) {
            self.releaseAction = releaseAction
        }

        func release() {
            let action: (() -> Void)? = lock.withLock {
                defer { releaseAction = nil }
                return releaseAction
            }
            action?()
        }

        deinit {
            release()
        }
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Lease, Error>
    }

    let limit: Int
    private let lock = NSLock()
    private var activeCountByResource: [Resource: Int] = [:]
    private var waitersByResource: [Resource: [Waiter]] = [:]
    private var resourceByWaiterID: [UUID: Resource] = [:]
    private var cancelledWaiterIDs: Set<UUID> = []

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    func acquire(_ resource: Resource) async throws -> Lease {
        try Task.checkCancellation()

        let waiterID = UUID()
        let lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediateResult: Result<Lease, Error>? = lock.withLock {
                    if cancelledWaiterIDs.remove(waiterID) != nil || Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    guard canAcquire(resource), waitersByResource[resource]?.isEmpty != false else {
                        let waiter = Waiter(id: waiterID, continuation: continuation)
                        waitersByResource[resource, default: []].append(waiter)
                        resourceByWaiterID[waiterID] = resource
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
            self.cancelWaiter(waiterID)
        }

        do {
            try Task.checkCancellation()
            return lease
        } catch {
            _ = lock.withLock { cancelledWaiterIDs.remove(waiterID) }
            lease.release()
            throw error
        }
    }

    func activeCount(for resource: Resource) -> Int {
        lock.withLock { activeCountByResource[resource] ?? 0 }
    }

    func waiterCount(for resource: Resource) -> Int {
        lock.withLock { waitersByResource[resource]?.count ?? 0 }
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
            while canAcquire(resource), var waiters = waitersByResource[resource], !waiters.isEmpty {
                let next = waiters.removeFirst()
                resourceByWaiterID.removeValue(forKey: next.id)
                if waiters.isEmpty {
                    waitersByResource.removeValue(forKey: resource)
                } else {
                    waitersByResource[resource] = waiters
                }
                activate(resource)
                handoffs.append((next.continuation, makeLease(for: resource)))
            }
            return handoffs
        }
        for handoff in handoffs {
            handoff.0.resume(returning: handoff.1)
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        let continuation: CheckedContinuation<Lease, Error>? = lock.withLock {
            guard let resource = resourceByWaiterID.removeValue(forKey: waiterID),
                  var waiters = waitersByResource[resource],
                  let index = waiters.firstIndex(where: { $0.id == waiterID })
            else {
                cancelledWaiterIDs.insert(waiterID)
                return nil
            }

            let waiter = waiters.remove(at: index)
            if waiters.isEmpty {
                waitersByResource.removeValue(forKey: resource)
            } else {
                waitersByResource[resource] = waiters
            }
            return waiter.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}
