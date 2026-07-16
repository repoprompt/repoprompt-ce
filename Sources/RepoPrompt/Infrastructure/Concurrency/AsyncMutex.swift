import Foundation

actor AsyncMutex {
    private var isLocked = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    func withLock<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let acquired = await lock()
        guard acquired else {
            throw CancellationError()
        }
        defer {
            if acquired {
                unlock()
            }
        }
        return try await body()
    }

    /// Returns `true` if the lock was acquired, `false` if the waiter was
    /// removed due to task cancellation (caller must NOT enter the critical section).
    private func lock() async -> Bool {
        if !isLocked {
            isLocked = true
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    // Already cancelled before we got here — don't enqueue.
                    continuation.resume(returning: false)
                    return
                }
                waiters.append((id: waiterID, continuation: continuation))
            }
        } onCancel: { [weak self] in
            Task { await self?.removeCancelledWaiter(waiterID) }
        }
    }

    private func removeCancelledWaiter(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            // Resume with false — caller was NOT granted the lock.
            waiter.continuation.resume(returning: false)
        }
    }

    private func unlock() {
        if waiters.isEmpty {
            isLocked = false
            return
        }
        let next = waiters.removeFirst()
        // Resume with true — caller IS granted the lock.
        next.continuation.resume(returning: true)
    }
}
