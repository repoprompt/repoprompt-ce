import Foundation

/// Settles a probe's consumer independently of filesystem work that may not be interruptible.
/// Each invocation owns its own settlement; adapters retain scheduling and capacity policy.
enum CancellableProbe {
    /// Calls `startWorker` exactly once, even if the consumer is already cancelled. An adapter
    /// that reserves capacity before entering must release it in the worker, before completion.
    /// Do cancellation admission checks before reserving, not between reservation and this call.
    /// Startup must promptly return a task; blocking work belongs in that task, not this closure.
    static func run<Value: Sendable>(
        startWorker: (_ complete: @escaping @Sendable (Result<Value, Error>) -> Void) -> Task<Void, Never>
    ) async throws -> Value {
        let settlement = Settlement<Value>()
        let value: Value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                settlement.install(continuation)
                let worker = startWorker { settlement.complete($0) }
                settlement.attach(worker)
            }
        } onCancel: {
            settlement.cancel()
        }
        try Task.checkCancellation()
        return value
    }

    /// Cancellation settles the consumer, not an uninterruptible syscall. Late results are
    /// discarded. Resuming a continuation or cancelling a task must always happen outside the lock.
    private final class Settlement<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Value, Error>?
        private var continuation: CheckedContinuation<Value, Error>?
        private var worker: Task<Void, Never>?

        func install(_ continuation: CheckedContinuation<Value, Error>) {
            let ready = lock.withLock { () -> Result<Value, Error>? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }

        func attach(_ worker: Task<Void, Never>) {
            let settled = lock.withLock {
                guard result == nil else { return true }
                self.worker = worker
                return false
            }
            if settled { worker.cancel() }
        }

        func complete(_ result: Result<Value, Error>) {
            let pending = lock.withLock {
                worker = nil
                guard self.result == nil else { return nil as CheckedContinuation<Value, Error>? }
                self.result = result
                let pending = continuation
                continuation = nil
                return pending
            }
            pending?.resume(with: result)
        }

        func cancel() {
            let (pending, worker) = lock.withLock {
                let worker = self.worker
                self.worker = nil
                guard result == nil else { return (nil as CheckedContinuation<Value, Error>?, worker) }
                result = .failure(CancellationError())
                let pending = continuation
                continuation = nil
                return (pending, worker)
            }
            worker?.cancel()
            pending?.resume(throwing: CancellationError())
        }
    }
}
