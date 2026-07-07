import Foundation

struct AsyncTestConditionTimeout: Error, LocalizedError {
    let description: String
    let timeout: TimeInterval

    var errorDescription: String? {
        "Timed out after \(timeout)s waiting for \(description)"
    }
}

enum AsyncTestWait {
    /// Bounded async wait for actor/debug state that has no explicit test signal.
    /// Uses exponential backoff so tests avoid scheduler spin while preserving a
    /// deterministic timeout diagnostic.
    static func waitUntil(
        _ description: String,
        timeout: TimeInterval = 3,
        initialDelayNanoseconds: UInt64 = 1_000_000,
        maximumDelayNanoseconds: UInt64 = 25_000_000,
        condition: @escaping () async -> Bool
    ) async throws {
        try await waitUntilThrowing(
            description,
            timeout: timeout,
            initialDelayNanoseconds: initialDelayNanoseconds,
            maximumDelayNanoseconds: maximumDelayNanoseconds,
            condition: condition
        )
    }

    static func waitUntilThrowing(
        _ description: String,
        timeout: TimeInterval = 3,
        initialDelayNanoseconds: UInt64 = 1_000_000,
        maximumDelayNanoseconds: UInt64 = 25_000_000,
        condition: @escaping () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var delay = initialDelayNanoseconds
        while true {
            if try await condition() { return }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw AsyncTestConditionTimeout(description: description, timeout: timeout)
            }
            let remainingNanoseconds = UInt64((remaining * 1_000_000_000).rounded(.up))
            try await Task.sleep(nanoseconds: min(delay, remainingNanoseconds))
            delay = min(delay * 2, maximumDelayNanoseconds)
        }
    }
}

/// Test-only append-notify condition primitive.
///
/// This helper is intentionally small: tests mutate a protected snapshot and waiters
/// are resumed exactly when a later mutation satisfies their predicate. The only
/// sleep is the bounded timeout timer; it is not used for polling state.
final class AsyncTestCondition<Value>: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let predicate: (Value) -> Bool
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var value: Value
    private var waiters: [Waiter] = []

    init(_ value: Value) {
        self.value = value
    }

    func snapshot() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func update(_ mutate: (inout Value) -> Void) {
        var ready: [CheckedContinuation<Void, Error>] = []
        lock.lock()
        mutate(&value)
        waiters.removeAll { waiter in
            guard waiter.predicate(value) else { return false }
            ready.append(waiter.continuation)
            return true
        }
        lock.unlock()

        for continuation in ready {
            continuation.resume()
        }
    }

    func waitUntil(
        _ description: String,
        timeout: TimeInterval = 3,
        predicate: @escaping (Value) -> Bool
    ) async throws {
        let waiterID = UUID()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.waitForSignal(id: waiterID, predicate: predicate)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64((timeout * 1_000_000_000).rounded()))
                self.cancelWaiter(id: waiterID, error: AsyncTestConditionTimeout(description: description, timeout: timeout))
                throw AsyncTestConditionTimeout(description: description, timeout: timeout)
            }
            defer {
                group.cancelAll()
                cancelWaiter(id: waiterID, error: CancellationError())
            }
            _ = try await group.next()
        }
    }

    private func waitForSignal(id: UUID, predicate: @escaping (Value) -> Bool) async throws {
        try await withCheckedThrowingContinuation { continuation in
            var shouldResume = false
            lock.lock()
            if predicate(value) {
                shouldResume = true
            } else {
                waiters.append(Waiter(id: id, predicate: predicate, continuation: continuation))
            }
            lock.unlock()

            if shouldResume {
                continuation.resume()
            }
        }
    }

    private func cancelWaiter(id: UUID, error: Error) {
        var continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            continuation = waiters.remove(at: index).continuation
        }
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}
