import Foundation

/// Tool-level Git admission keyed by canonical repository identity. The lower-level WI-9
/// GitProcessAdmissionController remains the global/per-repository subprocess budget.
@MainActor
final class MCPGitToolAdmissionController {
    struct Lease: Equatable {
        fileprivate let id: UUID
        fileprivate let repositoryKeys: [String]
    }

    private struct Waiter {
        let id: UUID
        let repositoryKeys: [String]
        let continuation: CheckedContinuation<Lease, Error>
    }

    static let shared = MCPGitToolAdmissionController(
        perRepositoryLimit: MCPToolAdmissionPolicy.gitReadPerRepositoryLimit
    )

    let perRepositoryLimit: Int
    private var activeByRepository: [String: Int] = [:]
    private var activeLeaseIDs: Set<UUID> = []
    private var waiters: [Waiter] = []

    init(perRepositoryLimit: Int) {
        precondition(perRepositoryLimit > 0)
        self.perRepositoryLimit = perRepositoryLimit
    }

    func acquire(repositoryRoots: [URL]) async throws -> Lease {
        try await acquire(repositoryKeys: repositoryRoots.map(Self.repositoryKey(for:)))
    }

    func acquire(repositoryKeys rawKeys: [String]) async throws -> Lease {
        let repositoryKeys = Array(Set(rawKeys.map(Self.canonicalRepositoryKey))).sorted()
        precondition(!repositoryKeys.isEmpty)
        try Task.checkCancellation()

        if canAcquire(repositoryKeys) {
            return activate(repositoryKeys)
        }

        let waiterID = UUID()
        let lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Lease, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if canAcquire(repositoryKeys), waiters.isEmpty {
                    continuation.resume(returning: activate(repositoryKeys))
                    return
                }
                waiters.append(Waiter(
                    id: waiterID,
                    repositoryKeys: repositoryKeys,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID)
            }
        }
        do {
            try Task.checkCancellation()
            return lease
        } catch {
            release(lease)
            throw error
        }
    }

    func release(_ lease: Lease) {
        guard activeLeaseIDs.remove(lease.id) != nil else { return }
        for key in lease.repositoryKeys {
            let next = max(0, (activeByRepository[key] ?? 0) - 1)
            if next == 0 {
                activeByRepository.removeValue(forKey: key)
            } else {
                activeByRepository[key] = next
            }
        }
        admitWaitersInFIFOOrder()
    }

    func activeCount(repositoryRoot: URL) -> Int {
        activeByRepository[Self.repositoryKey(for: repositoryRoot)] ?? 0
    }

    func activeCount(repositoryKey: String) -> Int {
        activeByRepository[Self.canonicalRepositoryKey(repositoryKey)] ?? 0
    }

    func waiterCount() -> Int {
        waiters.count
    }

    nonisolated static func repositoryKey(for checkoutRoot: URL) -> String {
        let standardizedRoot = checkoutRoot.standardizedFileURL
        let repositoryIdentity = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: standardizedRoot)?.commonDir
            ?? standardizedRoot
        return canonicalRepositoryKey(repositoryIdentity.path)
    }

    private nonisolated static func canonicalRepositoryKey(_ key: String) -> String {
        URL(fileURLWithPath: key)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path.lowercased()
    }

    private func canAcquire(_ repositoryKeys: [String]) -> Bool {
        repositoryKeys.allSatisfy { (activeByRepository[$0] ?? 0) < perRepositoryLimit }
    }

    private func activate(_ repositoryKeys: [String]) -> Lease {
        let id = UUID()
        for key in repositoryKeys {
            activeByRepository[key, default: 0] += 1
        }
        activeLeaseIDs.insert(id)
        return Lease(id: id, repositoryKeys: repositoryKeys)
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        admitWaitersInFIFOOrder()
    }

    private func admitWaitersInFIFOOrder() {
        while let index = waiters.firstIndex(where: { canAcquire($0.repositoryKeys) }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: activate(waiter.repositoryKeys))
        }
    }
}
