import Foundation

#if DEBUG
    actor MCPSharedServerTestLease {
        struct Ownership {
            fileprivate init() {}
        }

        static let shared = MCPSharedServerTestLease()

        private var occupied = false
        /// Lock-backed waiter queue so `onCancel` can remove/resume waiters **synchronously**
        /// without an unstructured `Task { await }` hop.
        private let waiterState = LeaseWaiterState()

        func withLease<T>(_ operation: (Ownership) async throws -> T) async throws -> T {
            if occupied {
                try await waitForTurn()
                if Task.isCancelled {
                    releaseLease()
                    throw CancellationError()
                }
            }
            occupied = true
            defer {
                releaseLease()
            }
            return try await operation(Ownership())
        }

        func waiterCountForTesting() -> Int {
            waiterState.waiterCount
        }

        private func waitForTurn() async throws {
            let waiterID = waiterState.allocateWaiterID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiterState.enqueue(id: waiterID, continuation: continuation)
                }
            } onCancel: {
                // Synchronous sticky cancel — must not hop through the actor executor.
                waiterState.cancel(id: waiterID)
            }
        }

        private func releaseLease() {
            if let continuation = waiterState.dequeueNextReady() {
                continuation.resume()
                return
            }
            occupied = false
        }
    }

    /// Shared lease waiter queue. `@unchecked Sendable` lock state so cancellation handlers
    /// can run synchronously from any executor.
    private final class LeaseWaiterState: @unchecked Sendable {
        private let lock = NSLock()
        private var nextWaiterID = 0
        private var pendingWaiterIDs: Set<Int> = []
        private var cancelledWaiterIDs: Set<Int> = []
        private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []

        var waiterCount: Int {
            lock.withLock { waiters.count }
        }

        func allocateWaiterID() -> Int {
            lock.lock()
            let id = nextWaiterID
            nextWaiterID += 1
            pendingWaiterIDs.insert(id)
            lock.unlock()
            return id
        }

        func enqueue(id: Int, continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            if cancelledWaiterIDs.remove(id) != nil {
                pendingWaiterIDs.remove(id)
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            waiters.append((id, continuation))
            lock.unlock()
        }

        func cancel(id: Int) {
            lock.lock()
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                let waiter = waiters.remove(at: index)
                pendingWaiterIDs.remove(id)
                lock.unlock()
                waiter.continuation.resume(throwing: CancellationError())
                return
            }
            if pendingWaiterIDs.contains(id) {
                cancelledWaiterIDs.insert(id)
            }
            lock.unlock()
        }

        /// Returns the next non-cancelled waiter's continuation, or nil if the queue is empty.
        func dequeueNextReady() -> CheckedContinuation<Void, Error>? {
            lock.lock()
            while !waiters.isEmpty {
                let waiter = waiters.removeFirst()
                pendingWaiterIDs.remove(waiter.id)
                if cancelledWaiterIDs.remove(waiter.id) != nil {
                    lock.unlock()
                    waiter.continuation.resume(throwing: CancellationError())
                    lock.lock()
                    continue
                }
                lock.unlock()
                return waiter.continuation
            }
            lock.unlock()
            return nil
        }
    }
#endif
