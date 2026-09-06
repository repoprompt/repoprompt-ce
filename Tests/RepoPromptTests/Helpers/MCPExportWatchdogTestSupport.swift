import Foundation
import RepoPromptDomainRuntime

actor MCPExportWatchdogManualClock {
    private static let synchronizationTimeout: Duration = .seconds(10)

    private nonisolated let timeState = TimeState()
    /// Lock-backed sleeper registry so `onCancel` can remove/resume synchronously.
    private let sleeperState = SleeperState()

    nonisolated var environment: MCPToolExecutionWatchdogEnvironment {
        environment()
    }

    nonisolated func environment(
        eventDidProduce: @escaping @Sendable (MCPToolExecutionWatchdogSchedulingPoint) async -> Void = { _ in },
        beforeEventConsumption: @escaping @Sendable (MCPToolExecutionWatchdogSchedulingPoint) async -> Void = { _ in },
        beforeCleanupGraceTaskRegistration: @escaping @Sendable () async -> Void = {},
        beforeDetachActivation: @escaping @Sendable () -> Void = {}
    ) -> MCPToolExecutionWatchdogEnvironment {
        MCPToolExecutionWatchdogEnvironment(
            now: { self.currentTime() },
            sleep: { try await self.sleep(for: $0) },
            eventDidProduce: eventDidProduce,
            beforeEventConsumption: beforeEventConsumption,
            beforeCleanupGraceTaskRegistration: beforeCleanupGraceTaskRegistration,
            beforeDetachActivation: beforeDetachActivation
        )
    }

    nonisolated func currentTime() -> Duration {
        timeState.current
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID()
        let wakeTime = timeState.current + duration
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.sleeperState.register(
                    id: id,
                    duration: duration,
                    wakeTime: wakeTime,
                    continuation: continuation
                )
            }
        } onCancel: {
            sleeperState.cancel(id: id)
        }
    }

    func sleeperCount() -> Int {
        sleeperState.count
    }

    func waitForSleeperCount(
        _ count: Int,
        timeout: Duration = synchronizationTimeout
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while sleeperState.count < count {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw ClockError.sleeperDidNotRegister(expected: count, actual: sleeperState.count)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func advanceWithoutSleepers(by duration: Duration) throws {
        guard duration > .zero else {
            throw ClockError.nonPositiveAdvance(duration)
        }
        guard sleeperState.count == 0 else {
            throw ClockError.sleepersRegistered(sleeperState.count)
        }
        timeState.advance(by: duration)
    }

    func advanceWithoutWakingSleepers(by duration: Duration) throws {
        guard duration > .zero else {
            throw ClockError.nonPositiveAdvance(duration)
        }
        timeState.advance(by: duration)
    }

    func advanceNext(expected: Duration) throws {
        guard let sleeper = sleeperState.popNext() else {
            throw ClockError.noSleeper
        }
        guard sleeper.duration == expected else {
            throw ClockError.unexpectedDuration(expected: expected, actual: sleeper.duration)
        }
        timeState.advance(toAtLeast: sleeper.wakeTime)
        sleeper.continuation.resume()
    }

    func advanceSleeper(expected: Duration) throws {
        guard let sleeper = sleeperState.pop(duration: expected) else {
            throw ClockError.noSleeper
        }
        timeState.advance(toAtLeast: sleeper.wakeTime)
        sleeper.continuation.resume()
    }

    private enum ClockError: Error {
        case noSleeper
        case nonPositiveAdvance(Duration)
        case sleeperDidNotRegister(expected: Int, actual: Int)
        case sleepersRegistered(Int)
        case unexpectedDuration(expected: Duration, actual: Duration)
    }

    private final class TimeState: @unchecked Sendable {
        private let lock = NSLock()
        private var elapsed: Duration = .zero

        var current: Duration {
            lock.withLock { elapsed }
        }

        func advance(by duration: Duration) {
            lock.withLock {
                elapsed += duration
            }
        }

        func advance(toAtLeast instant: Duration) {
            lock.withLock {
                elapsed = max(elapsed, instant)
            }
        }
    }

    /// Sync-cancelable sleeper registry for the manual watchdog clock.
    private final class SleeperState: @unchecked Sendable {
        private struct Sleeper {
            let duration: Duration
            let wakeTime: Duration
            let continuation: CheckedContinuation<Void, Error>
        }

        private let lock = NSLock()
        private var sleeperOrder: [UUID] = []
        private var sleepers: [UUID: Sleeper] = [:]
        private var cancelledIDs = Set<UUID>()

        var count: Int {
            lock.withLock { sleepers.count }
        }

        func register(
            id: UUID,
            duration: Duration,
            wakeTime: Duration,
            continuation: CheckedContinuation<Void, Error>
        ) {
            lock.lock()
            if cancelledIDs.remove(id) != nil {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            sleeperOrder.append(id)
            sleepers[id] = Sleeper(
                duration: duration,
                wakeTime: wakeTime,
                continuation: continuation
            )
            lock.unlock()
        }

        func cancel(id: UUID) {
            lock.lock()
            sleeperOrder.removeAll { $0 == id }
            let sleeper = sleepers.removeValue(forKey: id)
            if sleeper == nil {
                cancelledIDs.insert(id)
            }
            lock.unlock()
            sleeper?.continuation.resume(throwing: CancellationError())
        }

        func popNext() -> (
            duration: Duration,
            wakeTime: Duration,
            continuation: CheckedContinuation<Void, Error>
        )? {
            lock.lock()
            defer { lock.unlock() }
            guard let id = sleeperOrder.first else { return nil }
            sleeperOrder.removeFirst()
            guard let sleeper = sleepers.removeValue(forKey: id) else { return nil }
            return (sleeper.duration, sleeper.wakeTime, sleeper.continuation)
        }

        func pop(duration: Duration) -> (
            duration: Duration,
            wakeTime: Duration,
            continuation: CheckedContinuation<Void, Error>
        )? {
            lock.lock()
            defer { lock.unlock() }
            guard let index = sleeperOrder.firstIndex(where: { sleepers[$0]?.duration == duration }) else {
                return nil
            }
            let id = sleeperOrder.remove(at: index)
            guard let sleeper = sleepers.removeValue(forKey: id) else { return nil }
            return (sleeper.duration, sleeper.wakeTime, sleeper.continuation)
        }
    }
}
