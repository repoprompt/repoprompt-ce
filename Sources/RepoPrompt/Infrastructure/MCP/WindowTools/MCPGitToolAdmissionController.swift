import Foundation
import OSLog

enum MCPGitToolAdmissionError: LocalizedError, Equatable {
    case waitTimedOut

    var errorDescription: String? {
        switch self {
        case .waitTimedOut:
            "Timed out waiting for another Git artifact export to finish for this repository. The earlier export may still be running or stuck; retry shortly. Read-only Git status/diff calls do not wait on this artifact-export gate."
        }
    }
}

/// Tool-level Git artifact-publication admission keyed by canonical repository identity.
///
/// This controller intentionally does not guard plain read-only Git operations such as
/// status, log, show, blame, or non-artifact diff. Those calls use the lower-level
/// GitProcessAdmissionController subprocess budget instead. Keeping this gate scoped to
/// artifact publication prevents one stuck snapshot/export path from freezing ordinary
/// Git reads across chats.
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

    /// Bounded UX wait for queued artifact publication. Plain read-only Git operations
    /// do not use this controller, so they do not inherit this queue.
    nonisolated static let defaultWaitTimeout: Duration = .seconds(30)
    /// Last-resort watchdog for leaked artifact-publication leases. Expiry is short
    /// enough to heal a wedged export promptly; actual Git subprocess fanout is still
    /// governed by GitProcessAdmissionController.
    nonisolated static let defaultLeaseTimeout: Duration = .seconds(120)

    private static let log = Logger(subsystem: "com.repoprompt.mcp", category: "GitArtifactAdmission")

    let perRepositoryLimit: Int
    private let waitTimeout: Duration?
    private let leaseTimeout: Duration?
    private var activeByRepository: [String: Int] = [:]
    private var activeLeaseIDs: Set<UUID> = []
    private var waiters: [Waiter] = []
    private var waiterTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var leaseTimeoutTasks: [UUID: Task<Void, Never>] = [:]

    init(
        perRepositoryLimit: Int,
        waitTimeout: Duration? = MCPGitToolAdmissionController.defaultWaitTimeout,
        leaseTimeout: Duration? = MCPGitToolAdmissionController.defaultLeaseTimeout
    ) {
        precondition(perRepositoryLimit > 0)
        self.perRepositoryLimit = perRepositoryLimit
        self.waitTimeout = waitTimeout
        self.leaseTimeout = leaseTimeout
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
                scheduleWaitTimeout(waiterID)
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
        leaseTimeoutTasks.removeValue(forKey: lease.id)?.cancel()
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

    func waiterTimeoutTaskCount() -> Int {
        waiterTimeoutTasks.count
    }

    func leaseTimeoutTaskCount() -> Int {
        leaseTimeoutTasks.count
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
        scheduleLeaseTimeout(id, repositoryKeys: repositoryKeys)
        return Lease(id: id, repositoryKeys: repositoryKeys)
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = waiters.remove(at: index)
        waiterTimeoutTasks.removeValue(forKey: waiterID)?.cancel()
        waiter.continuation.resume(throwing: CancellationError())
        admitWaitersInFIFOOrder()
    }

    private func timeoutWaiter(_ waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = waiters.remove(at: index)
        waiterTimeoutTasks.removeValue(forKey: waiterID)?.cancel()
        Self.log.warning("Git artifact admission wait timed out for repositories: \(waiter.repositoryKeys.joined(separator: ", "))")
        waiter.continuation.resume(throwing: MCPGitToolAdmissionError.waitTimedOut)
        admitWaitersInFIFOOrder()
    }

    private func expireLease(_ leaseID: UUID, repositoryKeys: [String]) {
        guard activeLeaseIDs.remove(leaseID) != nil else { return }
        leaseTimeoutTasks.removeValue(forKey: leaseID)?.cancel()
        Self.log.warning("Expired stale Git artifact admission lease for repositories: \(repositoryKeys.joined(separator: ", "))")
        for key in repositoryKeys {
            let next = max(0, (activeByRepository[key] ?? 0) - 1)
            if next == 0 {
                activeByRepository.removeValue(forKey: key)
            } else {
                activeByRepository[key] = next
            }
        }
        admitWaitersInFIFOOrder()
    }

    private func scheduleWaitTimeout(_ waiterID: UUID) {
        guard let waitTimeout else { return }
        waiterTimeoutTasks[waiterID]?.cancel()
        waiterTimeoutTasks[waiterID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: waitTimeout)
            } catch {
                return
            }
            self?.timeoutWaiter(waiterID)
        }
    }

    private func scheduleLeaseTimeout(_ leaseID: UUID, repositoryKeys: [String]) {
        guard let leaseTimeout else { return }
        leaseTimeoutTasks[leaseID]?.cancel()
        leaseTimeoutTasks[leaseID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: leaseTimeout)
            } catch {
                return
            }
            self?.expireLease(leaseID, repositoryKeys: repositoryKeys)
        }
    }

    private func admitWaitersInFIFOOrder() {
        while let index = waiters.firstIndex(where: { canAcquire($0.repositoryKeys) }) {
            let waiter = waiters.remove(at: index)
            waiterTimeoutTasks.removeValue(forKey: waiter.id)?.cancel()
            waiter.continuation.resume(returning: activate(waiter.repositoryKeys))
        }
    }
}
