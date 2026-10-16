import Foundation
@testable import RepoPromptApp

/// Deterministic replacement for the Auto-wake snooze clock.
///
/// Controls one monotonic instant, records sleepers by deadline, and resumes each due sleeper exactly
/// once when the test advances it. Nothing here ever sleeps against wall time, so the expiry, delayed
/// timer, extension race, and stale token cases are decided by explicit steps rather than by timing.
///
/// `advance(by:)` is deliberately split into "move the clock" and "let the deadline task run", because
/// the load-bearing invariant is that an *elapsed but not yet cleaned up* record is already inactive
/// for scheduling and for final physical acquisition.
@MainActor
final class AgentSessionLinkAutoWakeSnoozeTestClock {
    typealias Instant = ContinuousClock.Instant

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private(set) var instant: Instant
    private(set) var wallNow: Date
    private var sleepers: [Sleeper] = []
    /// Every sleep ever registered, so a test can prove a re-arm actually replaced the previous task.
    private(set) var registeredSleepCount = 0
    private(set) var resumedSleepCount = 0

    init(
        instant: Instant = ContinuousClock.now,
        wallNow: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) {
        self.instant = instant
        self.wallNow = wallNow
    }

    /// The value to install on a `TabSession`.
    var clock: AgentSessionLinkAutoWakeSnoozeClock {
        AgentSessionLinkAutoWakeSnoozeClock(
            now: { MainActor.assumeIsolated { self.instant } },
            wallNow: { MainActor.assumeIsolated { self.wallNow } },
            sleepUntil: { deadline in try await self.sleep(until: deadline) }
        )
    }

    /// Sleepers still waiting for their deadline.
    var pendingSleepCount: Int {
        sleepers.count
    }

    var pendingDeadlines: [Instant] {
        sleepers.map(\.deadline)
    }

    /// Moves the monotonic clock without letting any deadline task observe it.
    ///
    /// This is the "delayed timer" state: records have elapsed, but nothing has cleaned them up.
    func advanceWithoutFiring(seconds: Int) {
        instant = instant.advanced(by: .seconds(seconds))
        wallNow = wallNow.addingTimeInterval(TimeInterval(seconds))
    }

    /// Resumes every sleeper whose deadline is now due, exactly once.
    func fireDueSleepers() {
        let due = sleepers.filter { $0.deadline <= instant }
        sleepers.removeAll { $0.deadline <= instant }
        for sleeper in due {
            resumedSleepCount += 1
            sleeper.continuation.resume()
        }
    }

    func advance(seconds: Int) {
        advanceWithoutFiring(seconds: seconds)
        fireDueSleepers()
    }

    private func sleep(until deadline: Instant) async throws {
        if instant >= deadline { return }
        let id = UUID()
        registeredSleepCount += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor in self.cancelSleeper(id) }
        }
    }

    private func cancelSleeper(_ id: UUID) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        let sleeper = sleepers.remove(at: index)
        sleeper.continuation.resume(throwing: CancellationError())
    }
}
