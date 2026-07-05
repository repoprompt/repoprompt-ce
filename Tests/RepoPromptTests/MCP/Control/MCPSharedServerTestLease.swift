#if DEBUG
    import Foundation

    actor MCPSharedServerTestLease {
        struct Ownership {
            fileprivate init() {}
        }

        private struct Waiter {
            let id: UUID
            let continuation: CheckedContinuation<Void, Error>
        }

        static let shared = MCPSharedServerTestLease()

        private var occupied = false
        private var waiters: [Waiter] = []
        private var cancelledWaiterIDs: Set<UUID> = []
        private var grantedWaiterIDs: Set<UUID> = []

        func withLease<T>(_ operation: (Ownership) async throws -> T) async throws -> T {
            var ownsLease = false
            try await acquireLease()
            ownsLease = true
            defer {
                if ownsLease {
                    ownsLease = false
                    releaseLease()
                }
            }
            return try await operation(Ownership())
        }

        private func acquireLease() async throws {
            guard occupied else {
                occupied = true
                do {
                    try Task.checkCancellation()
                } catch {
                    releaseLease()
                    throw error
                }
                return
            }

            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    registerWaiter(id: waiterID, continuation: continuation)
                }
            } onCancel: {
                Task { await Self.shared.cancelWaiter(id: waiterID) }
            }

            grantedWaiterIDs.remove(waiterID)
            do {
                try Task.checkCancellation()
            } catch {
                releaseLease()
                throw error
            }
        }

        private func registerWaiter(id: UUID, continuation: CheckedContinuation<Void, Error>) {
            if cancelledWaiterIDs.remove(id) != nil {
                continuation.resume(throwing: CancellationError())
            } else {
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        }

        private func releaseLease() {
            if waiters.isEmpty {
                occupied = false
            } else {
                let waiter = waiters.removeFirst()
                grantedWaiterIDs.insert(waiter.id)
                waiter.continuation.resume()
            }
        }

        private func cancelWaiter(id: UUID) {
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                let waiter = waiters.remove(at: index)
                waiter.continuation.resume(throwing: CancellationError())
            } else if !grantedWaiterIDs.contains(id) {
                cancelledWaiterIDs.insert(id)
            }
        }
    }
#endif
