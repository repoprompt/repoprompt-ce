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
        let timeoutDuration = Duration.seconds(max(0, timeout))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeoutDuration)
        let maximumDelay = max(1, min(maximumDelayNanoseconds, UInt64(Int64.max)))
        var delay = max(1, min(initialDelayNanoseconds, maximumDelay))

        while true {
            if try await condition() { return }
            let now = clock.now
            guard now < deadline else {
                throw AsyncTestConditionTimeout(description: description, timeout: timeout)
            }
            let sleepDeadline = min(
                deadline,
                now.advanced(by: .nanoseconds(Int64(delay)))
            )
            try await clock.sleep(until: sleepDeadline, tolerance: .zero)
            delay = min(delay > maximumDelay / 2 ? maximumDelay : delay * 2, maximumDelay)
        }
    }
}

/// Test-only append-notify condition primitive.
///
/// This helper is intentionally small: tests mutate a protected snapshot and waiters
/// are resumed exactly when a later mutation satisfies their predicate. The only
/// sleep is the bounded timeout timer; it is not used for polling state.
///
/// Hang guarantees:
/// - sticky cancel (timeout/cancel-before-register fails closed; late register cannot park forever)
/// - synchronous `onCancel` via lock-backed state (no `Task { await }` hop)
final class AsyncTestCondition<Value>: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let predicate: (Value) -> Bool
        let continuation: CheckedContinuation<Void, Error>
    }

    private enum WaiterState {
        case pendingRegistration
        case registered
        case completed
    }

    private let lock = NSLock()
    private var value: Value
    private var waiters: [Waiter] = []
    /// Sticky cancel-before-register: timeout/cancel may race ahead of waiter registration.
    private var cancelledWaiters: [UUID: Error] = [:]
    /// Tracks terminal waiter IDs so cleanup after a successful wait cannot create
    /// stale sticky-cancel entries for IDs that will never register again.
    private var waiterStates: [UUID: WaiterState] = [:]

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
            waiterStates[waiter.id] = .completed
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
        lock.lock()
        waiterStates[waiterID] = .pendingRegistration
        lock.unlock()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.waitForSignal(id: waiterID, predicate: predicate)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(max(0, timeout)))
                self.cancelWaiter(
                    id: waiterID,
                    error: AsyncTestConditionTimeout(description: description, timeout: timeout)
                )
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
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var resumeResult: Result<Void, Error>?
                lock.lock()
                if let error = cancelledWaiters.removeValue(forKey: id) {
                    waiterStates.removeValue(forKey: id)
                    resumeResult = .failure(error)
                } else if Task.isCancelled {
                    waiterStates.removeValue(forKey: id)
                    resumeResult = .failure(CancellationError())
                } else if predicate(value) {
                    waiterStates[id] = .completed
                    resumeResult = .success(())
                } else {
                    waiters.append(Waiter(id: id, predicate: predicate, continuation: continuation))
                    waiterStates[id] = .registered
                }
                lock.unlock()

                switch resumeResult {
                case .success:
                    continuation.resume()
                case let .failure(error):
                    continuation.resume(throwing: error)
                case nil:
                    break
                }
            }
        } onCancel: {
            cancelWaiter(id: id, error: CancellationError())
        }
    }

    private func cancelWaiter(id: UUID, error: Error) {
        var continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        switch waiterStates[id] {
        case .registered:
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                continuation = waiters.remove(at: index).continuation
            }
            waiterStates[id] = .completed
        case .pendingRegistration:
            if cancelledWaiters[id] == nil {
                cancelledWaiters[id] = error
            }
        case .completed:
            waiterStates.removeValue(forKey: id)
            cancelledWaiters.removeValue(forKey: id)
        case nil:
            cancelledWaiters.removeValue(forKey: id)
        }
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}
