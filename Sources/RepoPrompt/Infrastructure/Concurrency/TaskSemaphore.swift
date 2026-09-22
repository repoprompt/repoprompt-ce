import Foundation

/// A tiny async-await friendly semaphore that limits the number of
/// concurrent tasks doing heavy work (e.g. disk I/O).
///
/// Usage:
///   let sem = TaskSemaphore(4)
///   guard await sem.acquire() else { throw CancellationError() }
///   defer { await sem.release() }
public actor TaskSemaphore {
    private typealias Waiter = (id: UUID, continuation: CheckedContinuation<Bool, Never>)

    private let capacity: Int
    private var permits: Int
    private var waiters: [Waiter] = []

    public init(_ permits: Int) {
        precondition(permits > 0, "Semaphore must have at least one permit")
        capacity = permits
        self.permits = permits
    }

    /// Suspend until a permit is available, then take it.
    ///
    /// Returns `false` when the caller is already cancelled or is cancelled
    /// while waiting. A cancelled waiter never consumes a permit.
    @discardableResult
    public func acquire() async -> Bool {
        if permits > 0 {
            guard !Task.isCancelled else { return false }
            permits -= 1
            return true
        }

        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append((id: waiterID, continuation: continuation))
                }
            }
        } onCancel: { [weak self] in
            Task { await self?.removeCancelledWaiter(waiterID) }
        }

        guard acquired else { return false }
        guard !Task.isCancelled else {
            release()
            return false
        }
        return true
    }

    /// Return a permit to the pool and resume the next waiter if any.
    public func release() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: true)
        } else {
            #if DEBUG
                assert(permits < capacity, "TaskSemaphore over-release detected")
            #endif
            permits += 1
        }
    }

    private func removeCancelledWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    /// Structured helper: acquires, runs `body`, then releases exactly once.
    public func withPermit<T>(_ body: @Sendable () async throws -> T) async throws -> T {
        guard await acquire() else { throw CancellationError() }
        defer { release() } // actor-local; no extra Task hop
        try Task.checkCancellation()
        return try await body()
    }
}
