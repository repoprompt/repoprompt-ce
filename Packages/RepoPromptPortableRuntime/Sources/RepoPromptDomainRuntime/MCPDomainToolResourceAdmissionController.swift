import Foundation

public enum MCPDomainToolAdmissionLimits {
    public static let exclusiveConnection = 1
    public static let controlConnection = 8
    public static let smallReadConnection = 2
    public static let smallReadPerWindow = 2
    public static let fileReadConnection = ContentReadConcurrencyCapacity.maximumConcurrentReads
    public static let fileReadPerWindow = ContentReadConcurrencyCapacity.maximumConcurrentReads
    public static let gitReadConnection = 2
    public static let fileSearchConnection = 4
    public static let gitReadPerRepository = 1
}

/// Protocol-neutral, cancellation-safe admission keyed by the physical state resource.
/// Connection lanes provide client ordering; this controller bounds cross-connection work.
public final class MCPDomainToolResourceAdmissionController: @unchecked Sendable {
    public enum AdmissionError: Error, Equatable, Sendable {
        case closed
    }

    public struct Snapshot: Equatable, Sendable {
        public let activeLeaseCount: Int
        public let waiterCount: Int
        public let isClosed: Bool
    }

    public enum Resource: Hashable, Sendable {
        case appWide
        case window(Int)
        case repository(String)
    }

    public final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var releaseAction: (() -> Void)?

        fileprivate init(releaseAction: @escaping () -> Void) {
            self.releaseAction = releaseAction
        }

        @discardableResult
        public func release() -> Bool {
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

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Lease, Error>
    }

    public let limit: Int
    private let lock = NSLock()
    private var activeCountByResource: [Resource: Int] = [:]
    private var waitersByResource: [Resource: [Waiter]] = [:]
    private var resourceByWaiterID: [UUID: Resource] = [:]
    private var cancelledWaiterIDs: Set<UUID> = []
    private var isClosed = false

    public init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    public func acquire(_ resource: Resource) async throws -> Lease {
        try Task.checkCancellation()

        let waiterID = UUID()
        let lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediateResult: Result<Lease, Error>? = lock.withLock {
                    if cancelledWaiterIDs.remove(waiterID) != nil || Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    guard !isClosed else {
                        return .failure(AdmissionError.closed)
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

    public func activeCount(for resource: Resource) -> Int {
        lock.withLock { activeCountByResource[resource] ?? 0 }
    }

    public func waiterCount(for resource: Resource) -> Int {
        lock.withLock { waitersByResource[resource]?.count ?? 0 }
    }

    public func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                activeLeaseCount: activeCountByResource.values.reduce(0, +),
                waiterCount: resourceByWaiterID.count,
                isClosed: isClosed
            )
        }
    }

    @discardableResult
    public func close() -> Int {
        let waiters: [Waiter] = lock.withLock {
            guard !isClosed else { return [] }
            isClosed = true
            let waiters = waitersByResource.values.flatMap { $0 }
            waitersByResource.removeAll()
            resourceByWaiterID.removeAll()
            cancelledWaiterIDs.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.continuation.resume(throwing: AdmissionError.closed)
        }
        return waiters.count
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
            while !isClosed, canAcquire(resource), var waiters = waitersByResource[resource], !waiters.isEmpty {
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
                if !isClosed {
                    cancelledWaiterIDs.insert(waiterID)
                }
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
