#if DEBUG
    actor MCPSharedServerTestLease {
        struct Ownership {
            fileprivate init() {}
        }

        static let shared = MCPSharedServerTestLease()

        private var occupied = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func withLease<T>(_ operation: (Ownership) async throws -> T) async rethrows -> T {
            if occupied {
                await withCheckedContinuation { waiters.append($0) }
            }
            occupied = true
            defer {
                if waiters.isEmpty {
                    occupied = false
                } else {
                    waiters.removeFirst().resume()
                }
            }
            return try await operation(Ownership())
        }
    }
#endif
