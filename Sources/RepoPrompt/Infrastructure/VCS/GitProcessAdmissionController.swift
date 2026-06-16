import Foundation

/// Bounds Git subprocess fanout across the process and within one repository.
/// A permit is granted only when both budgets are available, so callers never
/// hold one budget while waiting for the other.
actor GitProcessAdmissionController {
    nonisolated static let defaultGlobalLimit = 8
    nonisolated static let defaultPerRepositoryLimit = 2
    static let shared = GitProcessAdmissionController(
        globalLimit: defaultGlobalLimit,
        perRepositoryLimit: defaultPerRepositoryLimit
    )

    struct Lease {
        fileprivate let id: UUID
        fileprivate let repositoryKey: String
        let queueWaitMicroseconds: Int
    }

    struct Snapshot: Equatable {
        let activeGlobal: Int
        let activeByRepository: [String: Int]
        let activeLeaseCount: Int
        let waiterCount: Int
    }

    private struct Waiter {
        let id: UUID
        let repositoryKey: String
        let enqueuedAt: UInt64
        let continuation: CheckedContinuation<Lease, any Error>
    }

    let globalLimit: Int
    let perRepositoryLimit: Int

    private var activeGlobal = 0
    private var activeByRepository: [String: Int] = [:]
    private var activeLeaseIDs: Set<UUID> = []
    private var waiters: [Waiter] = []

    init(globalLimit: Int, perRepositoryLimit: Int) {
        precondition(globalLimit > 0, "Git global process limit must be positive")
        precondition(perRepositoryLimit > 0, "Git per-repository process limit must be positive")
        self.globalLimit = globalLimit
        self.perRepositoryLimit = perRepositoryLimit
    }

    func acquire(repositoryKey: String) async throws -> Lease {
        try Task.checkCancellation()
        let normalizedKey = repositoryKey.isEmpty ? "<unknown>" : repositoryKey
        let leaseID = UUID()
        let enqueuedAt = DispatchTime.now().uptimeNanoseconds

        if canAcquire(repositoryKey: normalizedKey) {
            reserve(id: leaseID, repositoryKey: normalizedKey)
            return Lease(id: leaseID, repositoryKey: normalizedKey, queueWaitMicroseconds: 0)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(
                    id: leaseID,
                    repositoryKey: normalizedKey,
                    enqueuedAt: enqueuedAt,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: leaseID) }
        }
    }

    func release(_ lease: Lease) {
        guard activeLeaseIDs.remove(lease.id) != nil else { return }
        activeGlobal = max(0, activeGlobal - 1)
        let repositoryCount = max(0, (activeByRepository[lease.repositoryKey] ?? 1) - 1)
        activeByRepository[lease.repositoryKey] = repositoryCount == 0 ? nil : repositoryCount
        drainWaiters()
    }

    func snapshot() -> Snapshot {
        Snapshot(
            activeGlobal: activeGlobal,
            activeByRepository: activeByRepository,
            activeLeaseCount: activeLeaseIDs.count,
            waiterCount: waiters.count
        )
    }

    private func canAcquire(repositoryKey: String) -> Bool {
        activeGlobal < globalLimit
            && (activeByRepository[repositoryKey] ?? 0) < perRepositoryLimit
    }

    private func reserve(id: UUID, repositoryKey: String) {
        activeGlobal += 1
        activeByRepository[repositoryKey, default: 0] += 1
        activeLeaseIDs.insert(id)
    }

    private func drainWaiters() {
        while activeGlobal < globalLimit {
            guard let index = waiters.firstIndex(where: { canAcquire(repositoryKey: $0.repositoryKey) }) else {
                return
            }
            let waiter = waiters.remove(at: index)
            reserve(id: waiter.id, repositoryKey: waiter.repositoryKey)
            let now = DispatchTime.now().uptimeNanoseconds
            let waitMicroseconds = Int(clamping: now >= waiter.enqueuedAt ? (now - waiter.enqueuedAt) / 1000 : 0)
            waiter.continuation.resume(returning: Lease(
                id: waiter.id,
                repositoryKey: waiter.repositoryKey,
                queueWaitMicroseconds: waitMicroseconds
            ))
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
