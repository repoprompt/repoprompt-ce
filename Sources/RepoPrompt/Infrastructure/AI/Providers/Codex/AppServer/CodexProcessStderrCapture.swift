import Foundation

/// Generation-local raw stderr tail. The capture never decodes evidence and
/// exposes a bounded completion wait without cancelling the producer.
final class CodexProcessStderrCapture: @unchecked Sendable {
    struct Snapshot: Equatable {
        let bytes: Data
        let wasTruncated: Bool
    }

    private let lock = NSLock()
    private let byteLimit: Int
    private var tail = Data()
    private var wasTruncated = false
    private var isFinished = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

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
        let continuations = waiters.values
        waiters.removeAll()
        lock.unlock()

        for continuation in continuations {
            continuation.resume(returning: true)
        }
    }

    func waitUntilFinished(timeout: TimeInterval) async -> Bool {
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            lock.lock()
            if isFinished {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            waiters[waiterID] = continuation
            lock.unlock()

            let timeoutNanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
            Task.detached { [weak self] in
                if timeoutNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                }
                self?.expireWaiter(waiterID)
            }
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let snapshot = Snapshot(bytes: tail, wasTruncated: wasTruncated)
        lock.unlock()
        return snapshot
    }

    private func expireWaiter(_ waiterID: UUID) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: waiterID)
        lock.unlock()
        continuation?.resume(returning: false)
    }
}
