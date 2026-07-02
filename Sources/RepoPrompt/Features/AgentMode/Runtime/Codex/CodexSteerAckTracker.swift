import Foundation

/// Correlates MCP-initiated Codex dispatch attempts with their explicit submit path.
///
/// Attempts are independent: dispatch authorization, delivery resolution, timeout, and
/// cancellation are all keyed by attempt ID. Terminal attempts remain tombstoned so a late
/// provider result cannot be buffered for, or accidentally resolve, a newer attempt.
@MainActor
final class CodexSteerAckTracker {
    nonisolated static let defaultTimeoutSeconds: TimeInterval = 2.5
    private var terminalStateTimeoutSeconds = CodexSteerAckTracker.defaultTimeoutSeconds

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func cancel() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    enum TerminalState: Equatable {
        case steerAccepted
        case startAccepted
        case controlAccepted
        case durablyQueued(queueID: UUID)
        case failed(message: String)
        case cancelled
        case stale(reason: String)
        case timedOut

        var confirmsInstructionDeliveryOrDurableQueue: Bool {
            switch self {
            case .steerAccepted, .startAccepted, .controlAccepted, .durablyQueued:
                true
            case .failed, .cancelled, .stale, .timedOut:
                false
            }
        }

        var failureDescriptionForMCP: String? {
            switch self {
            case .steerAccepted, .startAccepted, .controlAccepted, .durablyQueued:
                nil
            case let .failed(message):
                message.isEmpty
                    ? "Codex steer failed before reaching the active run."
                    : message
            case .cancelled:
                "Codex steer was cancelled before it reached the active run."
            case let .stale(reason):
                reason.isEmpty
                    ? "Codex steer was dropped because the active run changed before delivery."
                    : reason
            case .timedOut:
                "Timed out waiting for Codex to acknowledge the steer message. The run may have changed state."
            }
        }
    }

    private struct AttemptRecord {
        let cancellationFlag = CancellationFlag()
        var isDispatchAuthorized = false
        var dispatchContinuation: CheckedContinuation<Bool, Never>?
        var terminalState: TerminalState?
        var terminalContinuation: CheckedContinuation<TerminalState, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    private var attempts: [UUID: AttemptRecord] = [:]
    private var terminalAttemptOrder: [UUID] = []
    private let maxTerminalTombstones = 512
    #if DEBUG
        private(set) var test_latestAttemptID: UUID?

        var test_openAttemptIDs: [UUID] {
            attempts.compactMap { attemptID, record in
                record.terminalState == nil ? attemptID : nil
            }
        }

        @discardableResult
        func test_cancelOpenAttempts() -> [UUID] {
            let attemptIDs = test_openAttemptIDs
            for attemptID in attemptIDs {
                cancel(attemptID: attemptID)
            }
            return attemptIDs
        }

        func test_setTerminalStateTimeoutSeconds(_ timeoutSeconds: TimeInterval) {
            terminalStateTimeoutSeconds = timeoutSeconds
        }
    #endif

    func beginAttempt() -> UUID {
        let attemptID = UUID()
        attempts[attemptID] = AttemptRecord()
        #if DEBUG
            test_latestAttemptID = attemptID
        #endif
        return attemptID
    }

    func authorizeDispatch(attemptID: UUID) {
        guard var record = attempts[attemptID],
              record.terminalState == nil
        else { return }
        if record.cancellationFlag.isCancelled {
            resolve(attemptID: attemptID, state: .cancelled)
            return
        }
        record.isDispatchAuthorized = true
        let continuation = record.dispatchContinuation
        record.dispatchContinuation = nil
        attempts[attemptID] = record
        continuation?.resume(returning: true)
    }

    func awaitDispatchAuthorization(attemptID: UUID) async -> Bool {
        guard let cancellationFlag = attempts[attemptID]?.cancellationFlag else {
            return false
        }
        if Task.isCancelled {
            cancellationFlag.cancel()
            cancel(attemptID: attemptID)
            return false
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard var record = attempts[attemptID],
                      record.terminalState == nil
                else {
                    continuation.resume(returning: false)
                    return
                }
                if record.isDispatchAuthorized {
                    continuation.resume(returning: true)
                    return
                }
                record.dispatchContinuation = continuation
                attempts[attemptID] = record
            }
        } onCancel: {
            cancellationFlag.cancel()
            Task { @MainActor [weak self] in
                self?.cancel(attemptID: attemptID)
            }
        }
    }

    func resolve(attemptID: UUID, state: TerminalState) {
        guard var record = attempts[attemptID],
              record.terminalState == nil
        else { return }
        let resolvedState: TerminalState = record.cancellationFlag.isCancelled
            ? .cancelled
            : state
        record.terminalState = resolvedState
        record.timeoutTask?.cancel()
        record.timeoutTask = nil
        let dispatchContinuation = record.dispatchContinuation
        record.dispatchContinuation = nil
        let terminalContinuation = record.terminalContinuation
        record.terminalContinuation = nil
        attempts[attemptID] = record
        terminalAttemptOrder.append(attemptID)
        pruneTerminalTombstonesIfNeeded()
        dispatchContinuation?.resume(returning: false)
        terminalContinuation?.resume(returning: resolvedState)
    }

    func cancel(attemptID: UUID) {
        attempts[attemptID]?.cancellationFlag.cancel()
        resolve(attemptID: attemptID, state: .cancelled)
    }

    func markStale(attemptID: UUID, reason: String) {
        resolve(attemptID: attemptID, state: .stale(reason: reason))
    }

    func awaitTerminalState(
        attemptID: UUID,
        timeoutSeconds: TimeInterval? = nil
    ) async -> TerminalState {
        guard let cancellationFlag = attempts[attemptID]?.cancellationFlag else {
            return .stale(reason: "Codex dispatch attempt was not registered.")
        }
        if Task.isCancelled {
            cancellationFlag.cancel()
            cancel(attemptID: attemptID)
            return .cancelled
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard var record = attempts[attemptID] else {
                    continuation.resume(returning: .stale(
                        reason: "Codex dispatch attempt was not registered."
                    ))
                    return
                }
                if let terminalState = record.terminalState {
                    continuation.resume(returning: terminalState)
                    return
                }
                record.terminalContinuation = continuation
                let timeout = max(0.1, timeoutSeconds ?? terminalStateTimeoutSeconds)
                record.timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    self?.resolve(attemptID: attemptID, state: .timedOut)
                }
                attempts[attemptID] = record
            }
        } onCancel: {
            cancellationFlag.cancel()
            Task { @MainActor [weak self] in
                self?.cancel(attemptID: attemptID)
            }
        }
    }

    private func pruneTerminalTombstonesIfNeeded() {
        var index = 0
        while terminalAttemptOrder.count > maxTerminalTombstones, index < terminalAttemptOrder.count {
            let expiredID = terminalAttemptOrder[index]
            if let record = attempts[expiredID],
               record.terminalState == nil
               || record.dispatchContinuation != nil
               || record.terminalContinuation != nil
            {
                // Keep attempts with live waiters tracked so a later prune can still remove them.
                index += 1
                continue
            }
            attempts.removeValue(forKey: expiredID)
            terminalAttemptOrder.remove(at: index)
        }
    }
}
