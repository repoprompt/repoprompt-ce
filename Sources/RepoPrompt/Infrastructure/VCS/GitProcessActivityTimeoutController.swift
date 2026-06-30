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
            var isProcessRunning: (@Sendable (Process) -> Bool)?
            var terminate: (@Sendable (Process) -> Void)?
            var forceKill: (@Sendable (pid_t) -> Void)?

            init(
                sleep: (@Sendable (Duration, UInt64, TestingSleepPhase) async throws -> Void)? = nil,
                beforeTimeoutClaim: (@Sendable (UInt64) async -> Void)? = nil,
                afterTimeoutClaim: (@Sendable (UInt64, Bool) async -> Void)? = nil,
                beforeKillClaim: (@Sendable (UInt64) async -> Void)? = nil,
                afterKillClaim: (@Sendable (UInt64, Bool) async -> Void)? = nil,
                isProcessRunning: (@Sendable (Process) -> Bool)? = nil,
                terminate: (@Sendable (Process) -> Void)? = nil,
                forceKill: (@Sendable (pid_t) -> Void)? = nil
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
        process: Process,
        processIdentifier: pid_t,
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
        task = Task { [self] in
            do {
                try await sleep(for: timeout, generation: scheduledGeneration, phase: .activityTimeout)
                await beforeTimeoutClaim(generation: scheduledGeneration)
                let claimedTimeout = claimTimeoutAndTerminate(
                    generation: scheduledGeneration,
                    process: process
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
                    process: process,
                    processIdentifier: processIdentifier
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

    private func claimTimeoutAndTerminate(generation scheduledGeneration: UInt64, process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == scheduledGeneration, !Task.isCancelled, isProcessRunning(process) else {
            return false
        }
        timedOut = true
        terminate(process)
        return true
    }

    private func claimKillAndTerminate(
        generation scheduledGeneration: UInt64,
        process: Process,
        processIdentifier: pid_t
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == scheduledGeneration, !Task.isCancelled, isProcessRunning(process) else {
            return false
        }
        forceKill(processIdentifier)
        return true
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

    private func isProcessRunning(_ process: Process) -> Bool {
        #if DEBUG
            if let isProcessRunning = testingHooks?.isProcessRunning {
                return isProcessRunning(process)
            }
        #endif
        return process.isRunning
    }

    private func terminate(_ process: Process) {
        #if DEBUG
            if let terminate = testingHooks?.terminate {
                terminate(process)
                return
            }
        #endif
        process.terminate()
    }

    private func forceKill(_ processIdentifier: pid_t) {
        #if DEBUG
            if let forceKill = testingHooks?.forceKill {
                forceKill(processIdentifier)
                return
            }
        #endif
        kill(processIdentifier, SIGKILL)
    }
}
