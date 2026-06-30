import Foundation

enum GitProcessAdmissionPriority: Int, CaseIterable, Hashable {
    case rootBootstrap = 0
    case userInitiatedAuthority = 1
    case codemapDemand = 2
    case background = 3
}

struct GitProcessAdmissionDeadline: Equatable, Comparable {
    let uptimeNanoseconds: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.uptimeNanoseconds < rhs.uptimeNanoseconds
    }
}

struct GitProcessAdmissionClock {
    static let continuous = GitProcessAdmissionClock(
        now: { DispatchTime.now().uptimeNanoseconds },
        sleepUntil: { deadline in
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline > now else { return }
            try await Task.sleep(nanoseconds: deadline - now)
        }
    )

    let now: @Sendable () -> UInt64
    let sleepUntil: @Sendable (UInt64) async throws -> Void
}

enum GitProcessAdmissionError: LocalizedError, Equatable {
    case queueFull
    case repositoryQueueFull
    case deadlineQueueFull
    case deadlineUnsupported
    case deadlineExceeded

    var errorDescription: String? {
        switch self {
        case .queueFull:
            "The bounded Git process queue is full."
        case .repositoryQueueFull:
            "The bounded Git process queue for this repository is full."
        case .deadlineQueueFull:
            "The bounded foreground Git deadline queue is full."
        case .deadlineUnsupported:
            "Only root-bootstrap and user-initiated authority work may request a Git start deadline."
        case .deadlineExceeded:
            "The foreground Git operation could not start before its admission deadline."
        }
    }
}

/// Bounds Git subprocess fanout across the process and within one repository.
///
/// Deadline-bearing root-bootstrap/first-read authority work uses strict earliest-
/// deadline-first admission at the next feasible grant. Ordinary work uses a
/// persistent 8:4:2:1 weighted ring, bounding service gaps under sustained mixed
/// traffic. Active subprocesses remain non-preemptive, so an already saturated
/// pool can cause a deadline to fail rather than weakening the ordering contract.
actor GitProcessAdmissionController {
    nonisolated static let defaultGlobalLimit = 8
    nonisolated static let defaultPerRepositoryLimit = 2
    nonisolated static let defaultMaximumWaiterCount = 1024
    nonisolated static let defaultMaximumWaitersPerRepository = 256
    nonisolated static let defaultMaximumDeadlineWaiterCount = 128
    nonisolated static let serviceRing: [GitProcessAdmissionPriority] = [
        .rootBootstrap, .userInitiatedAuthority,
        .rootBootstrap, .codemapDemand,
        .rootBootstrap, .userInitiatedAuthority,
        .rootBootstrap, .background,
        .rootBootstrap, .userInitiatedAuthority,
        .rootBootstrap, .codemapDemand,
        .rootBootstrap, .userInitiatedAuthority,
        .rootBootstrap
    ]
    static let shared = GitProcessAdmissionController(
        globalLimit: defaultGlobalLimit,
        perRepositoryLimit: defaultPerRepositoryLimit
    )

    struct Lease {
        fileprivate let id: UUID
        fileprivate let repositoryKey: String
        let priority: GitProcessAdmissionPriority
        let queueWaitMicroseconds: Int
    }

    struct Snapshot: Equatable {
        let activeGlobal: Int
        let activeByRepository: [String: Int]
        let activeLeaseCount: Int
        let waiterCount: Int
        let deadlineWaiterCount: Int
        let waitersByPriority: [GitProcessAdmissionPriority: Int]
        let recentGrantedPriorities: [GitProcessAdmissionPriority]

        /// Grant history is bounded diagnostic evidence, not live resource
        /// state. Preserve snapshot equality as the existing permit/queue
        /// balance contract while exposing history for fairness assertions.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.activeGlobal == rhs.activeGlobal
                && lhs.activeByRepository == rhs.activeByRepository
                && lhs.activeLeaseCount == rhs.activeLeaseCount
                && lhs.waiterCount == rhs.waiterCount
                && lhs.deadlineWaiterCount == rhs.deadlineWaiterCount
                && lhs.waitersByPriority == rhs.waitersByPriority
        }
    }

    private struct Waiter {
        let id: UUID
        let repositoryKey: String
        let priority: GitProcessAdmissionPriority
        let deadline: GitProcessAdmissionDeadline?
        let enqueuedAt: UInt64
        let ordinal: UInt64
        let continuation: CheckedContinuation<Lease, any Error>
    }

    let globalLimit: Int
    let perRepositoryLimit: Int
    let maximumWaiterCount: Int
    let maximumWaitersPerRepository: Int
    let maximumDeadlineWaiterCount: Int

    private let clock: GitProcessAdmissionClock
    private var activeGlobal = 0
    private var activeByRepository: [String: Int] = [:]
    private var activeLeaseIDs: Set<UUID> = []
    private var waiters: [Waiter] = []
    private var deadlineTasks: [UUID: Task<Void, Never>] = [:]
    private var nextOrdinal: UInt64 = 0
    private var serviceRingCursor = 0
    private var recentGrantedPriorities: [GitProcessAdmissionPriority] = []

    init(
        globalLimit: Int,
        perRepositoryLimit: Int,
        maximumWaiterCount: Int = defaultMaximumWaiterCount,
        maximumWaitersPerRepository: Int = defaultMaximumWaitersPerRepository,
        maximumDeadlineWaiterCount: Int = defaultMaximumDeadlineWaiterCount,
        clock: GitProcessAdmissionClock = .continuous
    ) {
        precondition(globalLimit > 0, "Git global process limit must be positive")
        precondition(perRepositoryLimit > 0, "Git per-repository limit must be positive")
        precondition(maximumWaiterCount >= 0, "Git waiter limit must not be negative")
        precondition(maximumWaitersPerRepository >= 0, "Git repository waiter limit must not be negative")
        precondition(maximumDeadlineWaiterCount >= 0, "Git deadline waiter limit must not be negative")
        self.globalLimit = globalLimit
        self.perRepositoryLimit = perRepositoryLimit
        self.maximumWaiterCount = maximumWaiterCount
        self.maximumWaitersPerRepository = maximumWaitersPerRepository
        self.maximumDeadlineWaiterCount = maximumDeadlineWaiterCount
        self.clock = clock
    }

    func acquire(
        repositoryKey: String,
        priority: GitProcessAdmissionPriority = .userInitiatedAuthority,
        deadline: GitProcessAdmissionDeadline? = nil
    ) async throws -> Lease {
        try Task.checkCancellation()
        if deadline != nil,
           priority != .rootBootstrap,
           priority != .userInitiatedAuthority
        {
            throw GitProcessAdmissionError.deadlineUnsupported
        }
        let now = clock.now()
        if let deadline, deadline.uptimeNanoseconds <= now {
            throw GitProcessAdmissionError.deadlineExceeded
        }
        let normalizedKey = repositoryKey.isEmpty ? "<unknown>" : repositoryKey
        let leaseID = UUID()

        // Once any waiter exists, enter the same scheduler as queued work. This
        // prevents newly arriving ordinary work from bypassing queued deadlines.
        if waiters.isEmpty, canAcquire(repositoryKey: normalizedKey) {
            reserve(id: leaseID, repositoryKey: normalizedKey, priority: priority)
            return Lease(
                id: leaseID,
                repositoryKey: normalizedKey,
                priority: priority,
                queueWaitMicroseconds: 0
            )
        }

        guard waiters.count < maximumWaiterCount else {
            throw GitProcessAdmissionError.queueFull
        }
        guard waiters.count(where: { $0.repositoryKey == normalizedKey }) < maximumWaitersPerRepository else {
            throw GitProcessAdmissionError.repositoryQueueFull
        }
        if deadline != nil {
            guard deadlineTasks.count < maximumDeadlineWaiterCount else {
                throw GitProcessAdmissionError.deadlineQueueFull
            }
        }

        let lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Lease, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let ordinal = nextOrdinal
                nextOrdinal &+= 1
                waiters.append(Waiter(
                    id: leaseID,
                    repositoryKey: normalizedKey,
                    priority: priority,
                    deadline: deadline,
                    enqueuedAt: now,
                    ordinal: ordinal,
                    continuation: continuation
                ))
                if let deadline {
                    scheduleDeadline(deadline, waiterID: leaseID)
                }
                drainWaiters()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: leaseID) }
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
            waiterCount: waiters.count,
            deadlineWaiterCount: deadlineTasks.count,
            waitersByPriority: Dictionary(grouping: waiters, by: \.priority).mapValues(\.count),
            recentGrantedPriorities: recentGrantedPriorities
        )
    }

    private func canAcquire(repositoryKey: String) -> Bool {
        activeGlobal < globalLimit
            && (activeByRepository[repositoryKey] ?? 0) < perRepositoryLimit
    }

    private func reserve(
        id: UUID,
        repositoryKey: String,
        priority: GitProcessAdmissionPriority
    ) {
        activeGlobal += 1
        activeByRepository[repositoryKey, default: 0] += 1
        activeLeaseIDs.insert(id)
        recentGrantedPriorities.append(priority)
        if recentGrantedPriorities.count > 256 {
            recentGrantedPriorities.removeFirst(recentGrantedPriorities.count - 256)
        }
    }

    private func drainWaiters() {
        expireDueWaiters()
        while activeGlobal < globalLimit {
            guard let selection = nextWaiterSelection() else { return }
            let waiter = waiters.remove(at: selection.index)
            cancelDeadlineTask(waiter.id)
            if let ringCursor = selection.nextRingCursor {
                serviceRingCursor = ringCursor
            }
            reserve(id: waiter.id, repositoryKey: waiter.repositoryKey, priority: waiter.priority)
            let now = clock.now()
            let waitMicroseconds = Int(clamping: now >= waiter.enqueuedAt ? (now - waiter.enqueuedAt) / 1000 : 0)
            waiter.continuation.resume(returning: Lease(
                id: waiter.id,
                repositoryKey: waiter.repositoryKey,
                priority: waiter.priority,
                queueWaitMicroseconds: waitMicroseconds
            ))
            expireDueWaiters()
        }
    }

    private func nextWaiterSelection() -> (index: Int, nextRingCursor: Int?)? {
        let eligible = waiters.indices.filter { canAcquire(repositoryKey: waiters[$0].repositoryKey) }
        guard !eligible.isEmpty else { return nil }

        let deadlineEligible = eligible.filter { waiters[$0].deadline != nil }
        if let index = deadlineEligible.min(by: { lhs, rhs in
            let left = waiters[lhs]
            let right = waiters[rhs]
            if left.deadline != right.deadline { return left.deadline! < right.deadline! }
            if left.priority.rawValue != right.priority.rawValue {
                return left.priority.rawValue < right.priority.rawValue
            }
            return left.ordinal < right.ordinal
        }) {
            return (index, nil)
        }

        for offset in 0 ..< Self.serviceRing.count {
            let ringIndex = (serviceRingCursor + offset) % Self.serviceRing.count
            let priority = Self.serviceRing[ringIndex]
            if let index = eligible
                .filter({ waiters[$0].deadline == nil && waiters[$0].priority == priority })
                .min(by: { waiters[$0].ordinal < waiters[$1].ordinal })
            {
                return (index, (ringIndex + 1) % Self.serviceRing.count)
            }
        }
        return nil
    }

    private func scheduleDeadline(_ deadline: GitProcessAdmissionDeadline, waiterID: UUID) {
        let clock = clock
        deadlineTasks[waiterID] = Task { [weak self] in
            do {
                try await clock.sleepUntil(deadline.uptimeNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.expireWaiter(id: waiterID)
            } catch {
                return
            }
        }
    }

    private func expireDueWaiters() {
        let now = clock.now()
        let expiredIDs: [UUID] = waiters.compactMap { waiter -> UUID? in
            guard let deadline = waiter.deadline, deadline.uptimeNanoseconds <= now else { return nil }
            return waiter.id
        }
        for id in expiredIDs {
            expireWaiterNow(id: id)
        }
    }

    private func expireWaiter(id: UUID) {
        guard let waiter = waiters.first(where: { $0.id == id }),
              let deadline = waiter.deadline
        else { return }
        guard deadline.uptimeNanoseconds <= clock.now() else {
            scheduleDeadline(deadline, waiterID: id)
            return
        }
        expireWaiterNow(id: id)
        drainWaiters()
    }

    private func expireWaiterNow(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        cancelDeadlineTask(id)
        waiter.continuation.resume(throwing: GitProcessAdmissionError.deadlineExceeded)
    }

    private func cancelDeadlineTask(_ id: UUID) {
        deadlineTasks.removeValue(forKey: id)?.cancel()
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        cancelDeadlineTask(id)
        waiter.continuation.resume(throwing: CancellationError())
        drainWaiters()
    }
}
