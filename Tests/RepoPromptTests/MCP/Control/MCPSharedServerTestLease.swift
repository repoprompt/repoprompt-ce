#if DEBUG
    actor MCPSharedServerTestLease {
        struct Ownership {
            fileprivate init() {}
        }

        static let shared = MCPSharedServerTestLease()

        private var occupied = false
        private var nextWaiterID = 0
        private var pendingWaiterIDs: Set<Int> = []
        private var cancelledWaiterIDs: Set<Int> = []
        private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []

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
            waiters.count
        }

        private func waitForTurn() async throws {
            let waiterID = nextWaiterID
            nextWaiterID += 1
            pendingWaiterIDs.insert(waiterID)

            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    enqueueWaiter(id: waiterID, continuation: continuation)
                }
            } onCancel: {
                Task { await self.cancelWaiter(id: waiterID) }
            }
        }

        private func enqueueWaiter(id: Int, continuation: CheckedContinuation<Void, Error>) {
            if cancelledWaiterIDs.remove(id) != nil {
                pendingWaiterIDs.remove(id)
                continuation.resume(throwing: CancellationError())
                return
            }
            waiters.append((id, continuation))
        }

        private func cancelWaiter(id: Int) {
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                let waiter = waiters.remove(at: index)
                pendingWaiterIDs.remove(id)
                waiter.continuation.resume(throwing: CancellationError())
                return
            }
            if pendingWaiterIDs.contains(id) {
                cancelledWaiterIDs.insert(id)
            }
        }

        private func releaseLease() {
            while !waiters.isEmpty {
                let waiter = waiters.removeFirst()
                pendingWaiterIDs.remove(waiter.id)
                if cancelledWaiterIDs.remove(waiter.id) != nil {
                    waiter.continuation.resume(throwing: CancellationError())
                    continue
                }
                waiter.continuation.resume()
                return
            }
            occupied = false
        }
    }
#endif
