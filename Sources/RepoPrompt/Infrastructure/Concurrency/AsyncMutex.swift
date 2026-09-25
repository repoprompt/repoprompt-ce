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
        defer { if acquired { unlock() } }
        // Cancellation removal can lose to unlock's queued handoff. We own the
        // grant here, so release it through defer without entering cancelled work.
        try Task.checkCancellation()
        return try await body()
    }

    /// Acquires the lock even when the current task is already cancelled.
    ///
    /// Use this only for state restoration that must finish before a cancelled
    /// operation can return.
    func withLockIgnoringCancellation<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        await lockIgnoringCancellation()
        defer { unlock() }
        return try await body()
    }

    /// Returns `true` if the lock was acquired, `false` if the waiter was
    /// removed due to task cancellation (caller must NOT enter the critical section).
    private func lock() async -> Bool {
        guard !Task.isCancelled else { return false }
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
                #if DEBUG
                    didEnqueueWaiterForTesting?()
                #endif
            }
        } onCancel: { [weak self] in
            Task { await self?.removeCancelledWaiter(waiterID) }
        }
    }

    private func lockIgnoringCancellation() async {
        if !isLocked {
            isLocked = true
            return
        }
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            waiters.append((id: UUID(), continuation: continuation))
        }
    }

    private func removeCancelledWaiter(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            // Resume with false — caller was NOT granted the lock.
            waiter.continuation.resume(returning: false)
        }
    }

    #if DEBUG
        private var didEnqueueWaiterForTesting: (@Sendable () -> Void)?

        func setDidEnqueueWaiterForTesting(_ action: (@Sendable () -> Void)?) {
            didEnqueueWaiterForTesting = action
        }

        private var willResumeNextWaiterForTesting: (@Sendable () -> Void)?

        var queuedWaiterCountForTesting: Int {
            waiters.count
        }

        func setWillResumeNextWaiterForTesting(_ action: @escaping @Sendable () -> Void) {
            willResumeNextWaiterForTesting = action
        }
    #endif

    private func unlock() {
        if waiters.isEmpty {
            isLocked = false
            return
        }
        let next = waiters.removeFirst()
        #if DEBUG
            // One-shot synchronous seam: cancel after dequeue, before the grant
            // resumes, while cancellation removal cannot re-enter this actor.
            let willResume = willResumeNextWaiterForTesting
            willResumeNextWaiterForTesting = nil
            willResume?()
        #endif
        // Resume with true — caller IS granted the lock.
        next.continuation.resume(returning: true)
    }
}
