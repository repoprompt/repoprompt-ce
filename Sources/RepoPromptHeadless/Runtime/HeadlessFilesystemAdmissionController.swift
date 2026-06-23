import Foundation

enum HeadlessFilesystemAdmissionPolicy {
    static let capacity = 4

    static func weight(forToolNamed name: String) -> Int? {
        switch name {
        case "file_search":
            capacity
        case "get_file_tree", "get_code_structure", "read_file":
            1
        default:
            nil
        }
    }
}

actor HeadlessFilesystemAdmissionController {
    enum AdmissionError: Error, Equatable, LocalizedError {
        case invalidWeight(Int, capacity: Int)

        var errorDescription: String? {
            switch self {
            case let .invalidWeight(weight, capacity):
                "Filesystem admission weight must be in 1...\(capacity); received \(weight)."
            }
        }
    }

    struct Snapshot: Equatable {
        let activeWeight: Int
        let activeLeaseCount: Int
        let waitingWeights: [Int]
    }

    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var releaseAction: (() -> Void)?

        fileprivate init(controller: HeadlessFilesystemAdmissionController, weight: Int) {
            releaseAction = { [weak controller] in
                guard let controller else { return }
                Task {
                    await controller.release(weight: weight)
                }
            }
        }

        @discardableResult
        func release() -> Bool {
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
        let weight: Int
        let continuation: CheckedContinuation<Lease, Error>
    }

    static let shared = HeadlessFilesystemAdmissionController(capacity: HeadlessFilesystemAdmissionPolicy.capacity)

    let capacity: Int
    private var activeWeight = 0
    private var activeLeaseCount = 0
    private var waiters: [Waiter] = []

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func acquire(weight: Int) async throws -> Lease {
        guard (1 ... capacity).contains(weight) else {
            throw AdmissionError.invalidWeight(weight, capacity: capacity)
        }
        try Task.checkCancellation()

        let waiterID = UUID()
        let lease: Lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Lease, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if waiters.isEmpty, activeWeight + weight <= capacity {
                    activeWeight += weight
                    activeLeaseCount += 1
                    continuation.resume(returning: makeLease(weight: weight))
                } else {
                    waiters.append(Waiter(id: waiterID, weight: weight, continuation: continuation))
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID)
            }
        }

        do {
            try Task.checkCancellation()
            return lease
        } catch {
            lease.release()
            throw error
        }
    }

    func snapshotForTesting() -> Snapshot {
        Snapshot(
            activeWeight: activeWeight,
            activeLeaseCount: activeLeaseCount,
            waitingWeights: waiters.map(\.weight)
        )
    }

    private func makeLease(weight: Int) -> Lease {
        Lease(controller: self, weight: weight)
    }

    private func release(weight: Int) {
        precondition(activeWeight >= weight && activeLeaseCount > 0)
        activeWeight -= weight
        activeLeaseCount -= 1
        admitWaitingRequests()
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        admitWaitingRequests()
    }

    private func admitWaitingRequests() {
        while let waiter = waiters.first, activeWeight + waiter.weight <= capacity {
            waiters.removeFirst()
            activeWeight += waiter.weight
            activeLeaseCount += 1
            waiter.continuation.resume(returning: makeLease(weight: waiter.weight))
        }
    }
}
