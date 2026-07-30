import Darwin
import Foundation

/// Reschedulable activity timeout for one Git subprocess.
///
/// Every schedule and cancellation advances a generation. Timeout tasks must
/// claim that generation while holding the controller lock before signaling
/// the process, preventing a superseded activity timer from acting on the
/// currently active command.
final class GitProcessActivityTimeoutController: @unchecked Sendable {
    enum TestingSleepPhase: Hashable {
        case activityTimeout
        case terminationGrace
    }

    #if DEBUG
        struct TestingHooks {
            var sleep: (@Sendable (Duration, UInt64, TestingSleepPhase) async throws -> Void)?
            var beforeTimeoutClaim: (@Sendable (UInt64) async -> Void)?
            var afterTimeoutClaim: (@Sendable (UInt64, Bool) async -> Void)?
            var beforeKillClaim: (@Sendable (UInt64) async -> Void)?
            var afterKillClaim: (@Sendable (UInt64, Bool) async -> Void)?
            var isProcessRunning: (@Sendable (GitProcessLifecycleTarget) -> Bool)?
            var terminate: (@Sendable (GitProcessLifecycleTarget) -> Bool)?
            var forceKill: (@Sendable (pid_t) -> Bool)?

            init(
                sleep: (@Sendable (Duration, UInt64, TestingSleepPhase) async throws -> Void)? = nil,
                beforeTimeoutClaim: (@Sendable (UInt64) async -> Void)? = nil,
                afterTimeoutClaim: (@Sendable (UInt64, Bool) async -> Void)? = nil,
                beforeKillClaim: (@Sendable (UInt64) async -> Void)? = nil,
                afterKillClaim: (@Sendable (UInt64, Bool) async -> Void)? = nil,
                isProcessRunning: (@Sendable (GitProcessLifecycleTarget) -> Bool)? = nil,
                terminate: (@Sendable (GitProcessLifecycleTarget) -> Bool)? = nil,
                forceKill: (@Sendable (pid_t) -> Bool)? = nil
            ) {
                self.sleep = sleep
                self.beforeTimeoutClaim = beforeTimeoutClaim
                self.afterTimeoutClaim = afterTimeoutClaim
                self.beforeKillClaim = beforeKillClaim
                self.afterKillClaim = afterKillClaim
                self.isProcessRunning = isProcessRunning
                self.terminate = terminate
                self.forceKill = forceKill
            }
        }
    #endif

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var timedOut = false

    #if DEBUG
        private let testingHooks: TestingHooks?
    #endif

    init() {
        #if DEBUG
            testingHooks = nil
        #endif
    }

    #if DEBUG
        init(testingHooks: TestingHooks) {
            self.testingHooks = testingHooks
        }
    #endif

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func schedule(
        target: GitProcessLifecycleTarget,
        timeout: Duration,
        terminationGrace: Duration
    ) {
        lock.lock()
        // Once this process has crossed the timeout boundary, late output must
        // not revoke SIGKILL escalation or turn the timeout into activity.
        guard !timedOut else {
            lock.unlock()
            return
        }
        generation &+= 1
        let scheduledGeneration = generation
        task?.cancel()

        // An already-consumed spawn budget is authoritative synchronously.
        // Do not rely on scheduling a zero-duration Task: a fast child/reaper
        // could otherwise commit success before the timer runs.
        if timeout <= .zero {
            guard isProcessRunning(target) else {
                task = nil
                lock.unlock()
                return
            }
            guard terminate(target) else {
                task = nil
                lock.unlock()
                return
            }
            timedOut = true
            task = Task { [self] in
                do {
                    try await sleep(
                        for: terminationGrace,
                        generation: scheduledGeneration,
                        phase: .terminationGrace
                    )
                    await beforeKillClaim(generation: scheduledGeneration)
                    let claimedKill = claimKillAndTerminate(
                        generation: scheduledGeneration,
                        target: target
                    )
                    await afterKillClaim(generation: scheduledGeneration, claimed: claimedKill)
                } catch {
                    // Cancellation makes the escalation generation inert.
                }
                clearTask(generation: scheduledGeneration)
            }
            lock.unlock()
            return
        }

        task = Task { [self] in
            do {
                try await sleep(for: timeout, generation: scheduledGeneration, phase: .activityTimeout)
                await beforeTimeoutClaim(generation: scheduledGeneration)
                let claimedTimeout = claimTimeoutAndTerminate(
                    generation: scheduledGeneration,
                    target: target
                )
                await afterTimeoutClaim(generation: scheduledGeneration, claimed: claimedTimeout)
                guard claimedTimeout else {
                    clearTask(generation: scheduledGeneration)
                    return
                }

                try await sleep(for: terminationGrace, generation: scheduledGeneration, phase: .terminationGrace)
                await beforeKillClaim(generation: scheduledGeneration)
                let claimedKill = claimKillAndTerminate(
                    generation: scheduledGeneration,
                    target: target
                )
                await afterKillClaim(generation: scheduledGeneration, claimed: claimedKill)
            } catch {
                // Cancellation and sleep errors both make this generation inert.
            }
            clearTask(generation: scheduledGeneration)
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        generation &+= 1
        task?.cancel()
        task = nil
        lock.unlock()
    }

    private func claimTimeoutAndTerminate(
        generation scheduledGeneration: UInt64,
        target: GitProcessLifecycleTarget
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == scheduledGeneration, !Task.isCancelled, isProcessRunning(target) else {
            return false
        }
        guard terminate(target) else { return false }
        timedOut = true
        return true
    }

    private func claimKillAndTerminate(
        generation scheduledGeneration: UInt64,
        target: GitProcessLifecycleTarget
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == scheduledGeneration, !Task.isCancelled, isProcessRunning(target) else {
            return false
        }
        return forceKill(target)
    }

    private func clearTask(generation scheduledGeneration: UInt64) {
        lock.lock()
        if generation == scheduledGeneration {
            task = nil
        }
        lock.unlock()
    }

    private func sleep(
        for duration: Duration,
        generation: UInt64,
        phase: TestingSleepPhase
    ) async throws {
        #if DEBUG
            if let sleep = testingHooks?.sleep {
                try await sleep(duration, generation, phase)
                return
            }
        #endif
        try await Task.sleep(for: duration)
    }

    private func beforeTimeoutClaim(generation: UInt64) async {
        #if DEBUG
            await testingHooks?.beforeTimeoutClaim?(generation)
        #endif
    }

    private func afterTimeoutClaim(generation: UInt64, claimed: Bool) async {
        #if DEBUG
            await testingHooks?.afterTimeoutClaim?(generation, claimed)
        #endif
    }

    private func beforeKillClaim(generation: UInt64) async {
        #if DEBUG
            await testingHooks?.beforeKillClaim?(generation)
        #endif
    }

    private func afterKillClaim(generation: UInt64, claimed: Bool) async {
        #if DEBUG
            await testingHooks?.afterKillClaim?(generation, claimed)
        #endif
    }

    private func isProcessRunning(_ target: GitProcessLifecycleTarget) -> Bool {
        #if DEBUG
            if let isProcessRunning = testingHooks?.isProcessRunning {
                return isProcessRunning(target)
            }
        #endif
        return target.isRunning
    }

    private func terminate(_ target: GitProcessLifecycleTarget) -> Bool {
        #if DEBUG
            if let terminate = testingHooks?.terminate {
                return terminate(target)
            }
        #endif
        return target.terminate()
    }

    private func forceKill(_ target: GitProcessLifecycleTarget) -> Bool {
        #if DEBUG
            if let forceKill = testingHooks?.forceKill {
                return forceKill(target.processIdentifier)
            }
        #endif
        return target.forceKill()
    }
}
