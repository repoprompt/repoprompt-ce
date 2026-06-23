import Foundation

/// A tiny async-await friendly semaphore that limits the number of
/// concurrent tasks doing heavy work (e.g. disk I/O).
///
/// Usage:
///   let sem = TaskSemaphore(4)
///   await sem.acquire()
///   defer { await sem.release() }
public actor TaskSemaphore {
    private let capacity: Int
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(_ permits: Int) {
        precondition(permits > 0, "Semaphore must have at least one permit")
        capacity = permits
        self.permits = permits
    }

    /// Suspend until a permit is available, then take it.
    public func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    /// Return a permit to the pool and resume the next waiter if any.
    public func release() {
        if !waiters.isEmpty {
            let cont = waiters.removeFirst()
            cont.resume()
        } else {
            #if DEBUG
                assert(permits < capacity, "TaskSemaphore over-release detected")
            #endif
            permits += 1
        }
    }

    /// Structured helper: acquires, runs `body`, then releases exactly once.
    public func withPermit<T>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() } // actor-local; no extra Task hop
        return try await body()
    }
}
