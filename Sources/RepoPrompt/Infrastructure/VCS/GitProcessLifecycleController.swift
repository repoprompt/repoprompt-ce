import Foundation

/// Linearizes one Git child's spawn, termination, cancellation, and result
/// finalization. Cancellation is accepted until `commitFinalization()` wins the
/// lock; requests after that commit are consistently too late and inert.
final class GitProcessLifecycleController: @unchecked Sendable {
    enum SpawnState: Equatable {
        case running
        case cancellationRequested
        case terminated
    }

    struct FinalizationState: Equatable {
        let cancellationRequested: Bool
        let internalTerminationRequested: Bool

        var requiresProcessGroupCleanup: Bool {
            cancellationRequested || internalTerminationRequested
        }

        var cancellationError: CancellationError? {
            cancellationRequested ? CancellationError() : nil
        }
    }

    private let lock = NSLock()
    private var cancellationRequested = false
    private var internalTerminationRequested = false
    private var target: GitProcessLifecycleTarget?
    private var finalized = false
    private var committedState: FinalizationState?
    private var terminationEscalationTask: Task<Void, Never>?

    func checkCancellationBeforeSpawn() throws {
        lock.lock()
        let shouldCancel = cancellationRequested && !finalized
        lock.unlock()
        if shouldCancel {
            throw CancellationError()
        }
    }

    func didSpawn(
        target: GitProcessLifecycleTarget,
        terminationGrace: Duration
    ) -> SpawnState {
        lock.lock()
        if finalized {
            let wasCancelled = cancellationRequested
            lock.unlock()
            target.deactivate()
            return wasCancelled ? .cancellationRequested : .terminated
        }

        self.target = target
        let shouldTerminate = cancellationRequested || internalTerminationRequested
        if shouldTerminate {
            armTerminationEscalationLocked(
                target: target,
                terminationGrace: terminationGrace
            )
        }
        let wasCancelled = cancellationRequested
        lock.unlock()

        if shouldTerminate {
            target.terminate()
        }
        return wasCancelled ? .cancellationRequested : .running
    }

    /// Records caller cancellation only while finalization is still open.
    func requestCancellation(terminationGrace: Duration) {
        requestTermination(terminationGrace: terminationGrace, isCancellation: true)
    }

    /// Stops a child for an internal capture/spool failure without converting
    /// that failure into caller cancellation.
    func requestInternalTermination(terminationGrace: Duration) {
        requestTermination(terminationGrace: terminationGrace, isCancellation: false)
    }

    func shouldKeepNormalTimeout() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancellationRequested && !internalTerminationRequested && !finalized
    }

    /// Serializes timer installation with cancellation/internal termination so
    /// a callback can never revive a timeout after lifecycle termination wins.
    func installNormalTimeoutIfActive(_ install: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancellationRequested, !internalTerminationRequested, !finalized else { return }
        install()
    }

    func cancellationErrorIfRequested() -> CancellationError? {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested ? CancellationError() : nil
    }

    /// Atomic result commit. Its snapshot is authoritative for post-reap family
    /// cleanup and cancellation result selection. Later cancellation is ignored.
    func commitFinalization() -> FinalizationState {
        lock.lock()
        if let committedState {
            lock.unlock()
            return committedState
        }
        let state = FinalizationState(
            cancellationRequested: cancellationRequested,
            internalTerminationRequested: internalTerminationRequested
        )
        finalized = true
        committedState = state
        let target = target
        self.target = nil
        let escalationTask = terminationEscalationTask
        terminationEscalationTask = nil
        lock.unlock()

        target?.deactivate()
        escalationTask?.cancel()
        return state
    }

    private func requestTermination(
        terminationGrace: Duration,
        isCancellation: Bool
    ) {
        lock.lock()
        guard !finalized else {
            lock.unlock()
            return
        }
        if isCancellation {
            cancellationRequested = true
        } else {
            internalTerminationRequested = true
        }
        let target = target
        if let target {
            armTerminationEscalationLocked(
                target: target,
                terminationGrace: terminationGrace
            )
        }
        lock.unlock()

        target?.terminate()
    }

    private func armTerminationEscalationLocked(
        target: GitProcessLifecycleTarget,
        terminationGrace: Duration
    ) {
        guard terminationEscalationTask == nil else { return }
        terminationEscalationTask = Task.detached { [self] in
            do {
                try await Task.sleep(for: terminationGrace)
            } catch {
                return
            }
            sendTerminationKillIfNeeded(target: target)
        }
    }

    private func sendTerminationKillIfNeeded(target: GitProcessLifecycleTarget) {
        lock.lock()
        let shouldSignal = !finalized
            && (cancellationRequested || internalTerminationRequested)
            && self.target === target
        lock.unlock()
        if shouldSignal {
            target.forceKill()
        }
    }
}
