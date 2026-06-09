package actor WorkspaceTaskSemaphore {
    private let capacity: Int
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    package init(_ permits: Int) {
        precondition(permits > 0)
        capacity = permits
        self.permits = permits
    }

    package func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    package func release() {
        if let continuation = waiters.first {
            waiters.removeFirst()
            continuation.resume()
        } else {
            assert(permits < capacity)
            permits += 1
        }
    }

    package func withPermit<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}
