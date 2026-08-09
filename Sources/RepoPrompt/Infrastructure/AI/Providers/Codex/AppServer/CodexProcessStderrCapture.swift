import Foundation

/// Generation-local raw stderr tail. The capture never decodes evidence and
/// exposes a bounded completion wait without cancelling the producer.
final class CodexProcessStderrCapture: @unchecked Sendable {
    struct Snapshot: Equatable {
        let bytes: Data
        let wasTruncated: Bool
    }

    private struct Waiter {
        var continuation: CheckedContinuation<Bool, Never>?
        var timeoutTask: Task<Void, Never>?
        var terminalResult: Bool?
    }

    private let lock = NSLock()
    private let byteLimit: Int
    private var tail = Data()
    private var wasTruncated = false
    private var isFinished = false
    private var waiters: [UUID: Waiter] = [:]

    init(byteLimit: Int) {
        self.byteLimit = max(byteLimit, 0)
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }

        guard byteLimit > 0 else {
            wasTruncated = true
            return
        }
        if chunk.count >= byteLimit {
            if !tail.isEmpty || chunk.count > byteLimit {
                wasTruncated = true
            }
            tail = Data(chunk.suffix(byteLimit))
            return
        }

        let overflow = max(tail.count + chunk.count - byteLimit, 0)
        if overflow > 0 {
            tail.removeFirst(overflow)
            wasTruncated = true
        }
        tail.append(chunk)
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        var pendingWaiters: [Waiter] = []
        for waiterID in Array(waiters.keys) {
            guard var waiter = waiters[waiterID], waiter.terminalResult == nil else { continue }
            waiter.terminalResult = true
            if waiter.continuation == nil {
                waiters[waiterID] = waiter
            } else {
                waiters.removeValue(forKey: waiterID)
                pendingWaiters.append(waiter)
            }
        }
        lock.unlock()

        for waiter in pendingWaiters {
            waiter.timeoutTask?.cancel()
            waiter.continuation?.resume(returning: true)
        }
    }

    func waitUntilFinished(timeout: TimeInterval) async -> Bool {
        let waiterID = UUID()
        let timeoutNanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let immediateResult = registerWaiter(continuation, for: waiterID) {
                    continuation.resume(returning: immediateResult)
                    return
                }

                let timeoutTask = Task.detached { [weak self] in
                    do {
                        if timeoutNanoseconds > 0 {
                            try await Task.sleep(nanoseconds: timeoutNanoseconds)
                        }
                        try Task.checkCancellation()
                    } catch {
                        return
                    }
                    self?.settleWaiter(waiterID, returning: false)
                }
                installTimeoutTask(timeoutTask, for: waiterID)
            }
        } onCancel: {
            settleWaiter(waiterID, returning: false)
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let snapshot = Snapshot(bytes: tail, wasTruncated: wasTruncated)
        lock.unlock()
        return snapshot
    }

    private func registerWaiter(
        _ continuation: CheckedContinuation<Bool, Never>,
        for waiterID: UUID
    ) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        if isFinished {
            return true
        }
        if Task<Never, Never>.isCancelled {
            return false
        }
        waiters[waiterID] = Waiter(
            continuation: continuation,
            timeoutTask: nil,
            terminalResult: nil
        )
        return nil
    }

    private func installTimeoutTask(_ timeoutTask: Task<Void, Never>, for waiterID: UUID) {
        lock.lock()
        guard var waiter = waiters[waiterID] else {
            lock.unlock()
            timeoutTask.cancel()
            return
        }
        waiter.timeoutTask = timeoutTask
        waiters[waiterID] = waiter
        lock.unlock()
    }

    private func settleWaiter(_ waiterID: UUID, returning result: Bool) {
        lock.lock()
        guard var waiter = waiters[waiterID], waiter.terminalResult == nil else {
            lock.unlock()
            return
        }
        waiter.terminalResult = result
        let continuation = waiter.continuation
        let timeoutTask = waiter.timeoutTask
        if continuation == nil {
            waiters[waiterID] = waiter
        } else {
            waiters.removeValue(forKey: waiterID)
        }
        lock.unlock()
        timeoutTask?.cancel()
        continuation?.resume(returning: result)
    }
}
