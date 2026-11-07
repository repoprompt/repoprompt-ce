import Foundation

/// The persistence lifetime owns in-flight work, coalescing and drain waiters, not its
/// optional presenter. Completion releases one admitted write and returns whether a
/// subsequent write was requested; the owning runtime schedules that write after release.
@MainActor
final class AgentSessionSaveQueue {
    private(set) var inFlightSessionIDs: Set<UUID> = []
    private var requestedWhileInFlight: Set<UUID> = []
    private var completionWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    func begin(sessionID: UUID) -> Bool {
        guard inFlightSessionIDs.insert(sessionID).inserted else {
            requestFollowUp(sessionID: sessionID)
            return false
        }
        return true
    }

    func requestFollowUp(sessionID: UUID) {
        requestedWhileInFlight.insert(sessionID)
    }

    /// Deletion withdraws follow-up intent without pretending an admitted effect drained.
    func discardFollowUp(sessionID: UUID) {
        requestedWhileInFlight.remove(sessionID)
    }

    func finish(sessionID: UUID) -> Bool {
        precondition(inFlightSessionIDs.remove(sessionID) != nil)
        let waiters = completionWaiters.removeValue(forKey: sessionID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
        return requestedWhileInFlight.remove(sessionID) != nil
    }

    /// Cancellation is not a durable drain acknowledgment. A cancelled caller still waits
    /// for the admitted writer to leave storage before deciding whether it may retire.
    func waitForInFlightSave(sessionID: UUID) async {
        guard inFlightSessionIDs.contains(sessionID) else { return }
        await withCheckedContinuation { continuation in
            completionWaiters[sessionID, default: []].append(continuation)
        }
    }
}
