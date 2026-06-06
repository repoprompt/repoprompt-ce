import Foundation

actor AgentRunSessionStore {
    static let shared = AgentRunSessionStore()

    struct Registration: Equatable, Hashable {
        let sessionID: UUID
        let generation: UInt64
    }

    enum WaitDisposition: Equatable {
        case snapshotReady(AgentRunMCPSnapshot)
        case noteworthySnapshot(AgentRunMCPSnapshot, WakeReason)
        case timedOut
        case expired
        case cancelled
    }

    enum WakeReason: String, Equatable {
        case instructionDelivered = "instruction_delivered"
        /// A steering request was accepted locally. This wakes only currently-blocked
        /// waits so the caller can issue a fresh wait for post-steer progress.
        case steeringRequested = "steering_requested"
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<WaitDisposition, Never>
        let timeoutTask: Task<Void, Never>?
    }

    private struct Record {
        var registration: Registration
        var latestSnapshot: AgentRunMCPSnapshot?
        var pendingNoteworthySnapshot: AgentRunMCPSnapshot?
        var pendingWakeReason: WakeReason?
        var lastCommittedPublicationID: UUID?
        var waiters: [Waiter] = []
        var expiryTask: Task<Void, Never>?
    }

    private static let terminalSnapshotTTL: TimeInterval = 300

    private var records: [UUID: Record] = [:]
    private var nextGeneration: UInt64 = 1

    func register(sessionID: UUID) -> Registration {
        if let previous = records.removeValue(forKey: sessionID) {
            previous.expiryTask?.cancel()
            expireWaiters(previous.waiters)
            recordRejectedOperation(
                "register",
                supplied: previous.registration,
                current: nil,
                reason: "replaced_registration"
            )
        }
        let registration = makeRegistration(sessionID: sessionID)
        records[sessionID] = Record(registration: registration)
        return registration
    }

    /// Clears the stored snapshot for a freshly dispatched turn and rotates the
    /// publication generation. Already-parked waiters remain attached to the new turn.
    @discardableResult
    func resetSnapshotForNewTurn(registration: Registration) -> Registration? {
        guard var record = currentRecord(for: registration, operation: "reset_new_turn") else { return nil }
        record.expiryTask?.cancel()
        record.expiryTask = nil
        record.registration = makeRegistration(sessionID: registration.sessionID)
        record.latestSnapshot = nil
        record.pendingNoteworthySnapshot = nil
        record.pendingWakeReason = nil
        record.lastCommittedPublicationID = nil
        records[registration.sessionID] = record
        return record.registration
    }

    func noteSnapshot(_ snapshot: AgentRunMCPSnapshot, registration: Registration) {
        ingestSnapshot(snapshot, registration: registration, wakeReason: nil)
    }

    func noteSnapshotAndWakeWaiters(
        _ snapshot: AgentRunMCPSnapshot,
        registration: Registration,
        reason: WakeReason
    ) {
        ingestSnapshot(snapshot, registration: registration, wakeReason: reason)
    }

    func signalCommittedSnapshot(
        _ snapshot: AgentRunMCPSnapshot,
        registration: Registration,
        commitID: UUID
    ) {
        guard snapshot.sessionID == registration.sessionID else {
            recordRejectedOperation(
                "publish_terminal_commit",
                supplied: registration,
                current: records[registration.sessionID]?.registration,
                reason: "session_mismatch"
            )
            return
        }
        guard var record = currentRecord(for: registration, operation: "publish_terminal_commit") else { return }
        if record.lastCommittedPublicationID == commitID {
            #if DEBUG
                AgentModePerfDiagnostics.increment("mcp.waitStore.terminalCommit.duplicate")
            #endif
            return
        }
        guard record.lastCommittedPublicationID == nil else {
            recordRejectedOperation(
                "publish_terminal_commit",
                supplied: registration,
                current: record.registration,
                reason: "different_commit_already_published"
            )
            return
        }
        record.lastCommittedPublicationID = commitID
        records[registration.sessionID] = record
        ingestSnapshot(snapshot, registration: registration, wakeReason: nil)
        #if DEBUG
            AgentModePerfDiagnostics.increment("mcp.waitStore.terminalCommit.accepted")
        #endif
    }

    func wakeCurrentWaiters(
        _ snapshot: AgentRunMCPSnapshot,
        registration: Registration,
        reason: WakeReason
    ) {
        guard snapshot.sessionID == registration.sessionID else {
            recordRejectedOperation("wake", supplied: registration, current: records[registration.sessionID]?.registration, reason: "session_mismatch")
            return
        }
        guard var record = currentRecord(for: registration, operation: "wake") else { return }
        print("[AgentRunSteeringWake] store wake requested sessionID=\(snapshot.sessionID) generation=\(registration.generation) reason=\(reason.rawValue) status=\(snapshot.status.rawValue) waiters=\(record.waiters.count) pending=\(record.pendingWakeReason?.rawValue ?? "none") latest=\(record.latestSnapshot?.status.rawValue ?? "none")")
        if let latestSnapshot = record.latestSnapshot {
            if latestSnapshot.status.isTerminal {
                print("[AgentRunSteeringWake] store wake ignored terminal latest sessionID=\(snapshot.sessionID) latest=\(latestSnapshot.status.rawValue)")
                return
            }
            if !snapshot.status.isTerminal, latestSnapshot.updatedAt > snapshot.updatedAt {
                record.latestSnapshot = latestSnapshot
            } else {
                record.latestSnapshot = snapshot
            }
        } else {
            record.latestSnapshot = snapshot
        }
        let waiters = record.waiters
        guard !waiters.isEmpty else {
            records[snapshot.sessionID] = record
            print("[AgentRunSteeringWake] store wake no current waiters sessionID=\(snapshot.sessionID) reason=\(reason.rawValue)")
            return
        }
        record.waiters.removeAll()
        records[snapshot.sessionID] = record
        let returnedSnapshot = record.latestSnapshot ?? snapshot
        print("[AgentRunSteeringWake] store wake resuming waiters sessionID=\(snapshot.sessionID) reason=\(reason.rawValue) count=\(waiters.count) returnedStatus=\(returnedSnapshot.status.rawValue)")
        for waiter in waiters {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(returning: .noteworthySnapshot(returnedSnapshot, reason))
        }
    }

    private func ingestSnapshot(
        _ snapshot: AgentRunMCPSnapshot,
        registration: Registration,
        wakeReason: WakeReason?
    ) {
        guard snapshot.sessionID == registration.sessionID else {
            recordRejectedOperation("publish", supplied: registration, current: records[registration.sessionID]?.registration, reason: "session_mismatch")
            return
        }
        guard var record = currentRecord(for: registration, operation: "publish") else { return }
        var acceptedSnapshot = snapshot
        var shouldStoreIncomingSnapshot = true
        if let latestSnapshot = record.latestSnapshot {
            if latestSnapshot.status.isTerminal {
                // Terminal snapshots block later non-terminal regressions.
                // Allow newer terminal snapshots to refine status text / counts.
                if !(snapshot.status.isTerminal && snapshot.updatedAt >= latestSnapshot.updatedAt) {
                    acceptedSnapshot = latestSnapshot
                    shouldStoreIncomingSnapshot = false
                }
            } else if !snapshot.status.isTerminal, latestSnapshot.updatedAt > snapshot.updatedAt {
                // Non-terminal: reject older non-terminal snapshots (terminal always wins).
                acceptedSnapshot = latestSnapshot
                shouldStoreIncomingSnapshot = false
            }
        }
        if shouldStoreIncomingSnapshot {
            record.latestSnapshot = snapshot
            if snapshot.isActionableForMCPWait {
                record.pendingNoteworthySnapshot = nil
                record.pendingWakeReason = nil
            }
        }

        let waiterDisposition: WaitDisposition? = {
            if acceptedSnapshot.isActionableForMCPWait {
                return .snapshotReady(acceptedSnapshot)
            }
            if let wakeReason {
                return .noteworthySnapshot(acceptedSnapshot, wakeReason)
            }
            return nil
        }()
        let waiters = waiterDisposition == nil ? [] : record.waiters
        if waiterDisposition != nil {
            record.waiters.removeAll()
        }
        if case .noteworthySnapshot = waiterDisposition, waiters.isEmpty {
            record.pendingNoteworthySnapshot = acceptedSnapshot
            record.pendingWakeReason = wakeReason
        } else if waiterDisposition != nil {
            record.pendingNoteworthySnapshot = nil
            record.pendingWakeReason = nil
        }

        if shouldStoreIncomingSnapshot, snapshot.status.isTerminal {
            record.expiryTask?.cancel()
            record.expiryTask = Task { [registration] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(Self.terminalSnapshotTTL * 1_000_000_000))
                    await Self.shared.expire(registration: registration)
                } catch {
                    // Ignore cancellation.
                }
            }
        }

        records[snapshot.sessionID] = record

        if let waiterDisposition {
            for waiter in waiters {
                waiter.timeoutTask?.cancel()
                waiter.continuation.resume(returning: waiterDisposition)
            }
        }
    }

    func waitUntilInteresting(
        registration: Registration,
        timeoutSeconds: TimeInterval? = nil
    ) async -> WaitDisposition {
        guard let record = currentRecord(for: registration, operation: "wait") else {
            print("[AgentRunSteeringWake] store wait expired missing or stale registration sessionID=\(registration.sessionID) generation=\(registration.generation)")
            return .expired
        }
        if let snapshot = record.latestSnapshot,
           snapshot.isActionableForMCPWait
        {
            print("[AgentRunSteeringWake] store wait immediate snapshot sessionID=\(registration.sessionID) status=\(snapshot.status.rawValue) interaction=\(snapshot.interaction != nil)")
            return .snapshotReady(snapshot)
        }
        if let snapshot = record.pendingNoteworthySnapshot,
           let reason = record.pendingWakeReason
        {
            let returnedSnapshot = record.latestSnapshot ?? snapshot
            var updated = record
            updated.pendingNoteworthySnapshot = nil
            updated.pendingWakeReason = nil
            records[registration.sessionID] = updated
            print("[AgentRunSteeringWake] store wait consumed pending wake sessionID=\(registration.sessionID) reason=\(reason.rawValue) returnedStatus=\(returnedSnapshot.status.rawValue)")
            return .noteworthySnapshot(returnedSnapshot, reason)
        }
        if let timeout = timeoutSeconds, timeout <= 0 {
            print("[AgentRunSteeringWake] store wait timed out immediately sessionID=\(registration.sessionID)")
            return .timedOut
        }

        let waiterID = UUID()
        print("[AgentRunSteeringWake] store wait registering waiter sessionID=\(registration.sessionID) generation=\(registration.generation) waiterID=\(waiterID) timeout=\(timeoutSeconds.map { String($0) } ?? "none") latest=\(record.latestSnapshot?.status.rawValue ?? "none") existingWaiters=\(record.waiters.count)")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<WaitDisposition, Never>) in
                guard var current = currentRecord(for: registration, operation: "wait_park") else {
                    print("[AgentRunSteeringWake] store wait continuation expired stale registration sessionID=\(registration.sessionID) waiterID=\(waiterID)")
                    continuation.resume(returning: .expired)
                    return
                }
                if let snapshot = current.latestSnapshot,
                   snapshot.isActionableForMCPWait
                {
                    print("[AgentRunSteeringWake] store wait continuation immediate snapshot sessionID=\(registration.sessionID) waiterID=\(waiterID) status=\(snapshot.status.rawValue)")
                    continuation.resume(returning: .snapshotReady(snapshot))
                    return
                }
                if let snapshot = current.pendingNoteworthySnapshot,
                   let reason = current.pendingWakeReason
                {
                    let returnedSnapshot = current.latestSnapshot ?? snapshot
                    current.pendingNoteworthySnapshot = nil
                    current.pendingWakeReason = nil
                    records[registration.sessionID] = current
                    print("[AgentRunSteeringWake] store wait continuation consumed pending wake sessionID=\(registration.sessionID) waiterID=\(waiterID) reason=\(reason.rawValue) returnedStatus=\(returnedSnapshot.status.rawValue)")
                    continuation.resume(returning: .noteworthySnapshot(returnedSnapshot, reason))
                    return
                }
                var timeoutTask: Task<Void, Never>?
                if let timeout = timeoutSeconds {
                    timeoutTask = Task { [weak self] in
                        do {
                            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                            await self?.timeoutWaiter(sessionID: registration.sessionID, waiterID: waiterID)
                        } catch {
                            // Cancelled — snapshot or cleanup woke the waiter first.
                        }
                    }
                }
                current.waiters.append(Waiter(id: waiterID, continuation: continuation, timeoutTask: timeoutTask))
                print("[AgentRunSteeringWake] store wait waiter parked sessionID=\(registration.sessionID) waiterID=\(waiterID) waiters=\(current.waiters.count)")
                records[registration.sessionID] = current
            }
        } onCancel: {
            Task { await self.cancelWaiter(sessionID: registration.sessionID, waiterID: waiterID) }
        }
    }

    func snapshot(for registration: Registration) -> AgentRunMCPSnapshot? {
        currentRecord(for: registration, operation: "snapshot")?.latestSnapshot
    }

    func currentRegistration(for sessionID: UUID) -> Registration? {
        records[sessionID]?.registration
    }

    func hasActiveRegistration(sessionID: UUID) -> Bool {
        records[sessionID] != nil
    }

    func cleanup(registration: Registration) {
        guard let record = currentRecord(for: registration, operation: "cleanup") else { return }
        records.removeValue(forKey: registration.sessionID)
        record.expiryTask?.cancel()
        expireWaiters(record.waiters)
    }

    private func cancelWaiter(sessionID: UUID, waiterID: UUID) {
        guard var record = records[sessionID],
              let index = record.waiters.firstIndex(where: { $0.id == waiterID })
        else {
            print("[AgentRunSteeringWake] store wait cancel ignored sessionID=\(sessionID) waiterID=\(waiterID)")
            return
        }
        let waiter = record.waiters.remove(at: index)
        records[sessionID] = record
        waiter.timeoutTask?.cancel()
        print("[AgentRunSteeringWake] store wait cancelled sessionID=\(sessionID) waiterID=\(waiterID) remaining=\(record.waiters.count)")
        waiter.continuation.resume(returning: .cancelled)
    }

    private func timeoutWaiter(sessionID: UUID, waiterID: UUID) {
        guard var record = records[sessionID],
              let index = record.waiters.firstIndex(where: { $0.id == waiterID })
        else {
            print("[AgentRunSteeringWake] store wait timeout ignored sessionID=\(sessionID) waiterID=\(waiterID)")
            return
        }
        let waiter = record.waiters.remove(at: index)
        records[sessionID] = record
        print("[AgentRunSteeringWake] store wait timed out sessionID=\(sessionID) waiterID=\(waiterID) remaining=\(record.waiters.count)")
        waiter.continuation.resume(returning: .timedOut)
    }

    private func expire(registration: Registration) {
        guard let record = currentRecord(for: registration, operation: "expire") else { return }
        records.removeValue(forKey: registration.sessionID)
        expireWaiters(record.waiters)
    }

    private func makeRegistration(sessionID: UUID) -> Registration {
        let registration = Registration(sessionID: sessionID, generation: nextGeneration)
        nextGeneration &+= 1
        return registration
    }

    private func currentRecord(for registration: Registration, operation: String) -> Record? {
        guard let record = records[registration.sessionID] else {
            recordRejectedOperation(operation, supplied: registration, current: nil, reason: "missing")
            return nil
        }
        guard record.registration == registration else {
            recordRejectedOperation(operation, supplied: registration, current: record.registration, reason: "stale_generation")
            return nil
        }
        return record
    }

    private func expireWaiters(_ waiters: [Waiter]) {
        for waiter in waiters {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(returning: .expired)
        }
    }

    private func recordRejectedOperation(
        _ operation: String,
        supplied: Registration,
        current: Registration?,
        reason: String
    ) {
        print("[AgentRunSessionStore] ignored operation=\(operation) sessionID=\(supplied.sessionID) suppliedGeneration=\(supplied.generation) currentGeneration=\(current.map { String($0.generation) } ?? "none") reason=\(reason)")
        #if DEBUG
            AgentModePerfDiagnostics.increment("mcp.waitStore.rejected.\(operation).\(reason)")
        #endif
    }
}

extension AgentRunSessionStore {
    static func register(sessionID: UUID) async -> Registration {
        await shared.register(sessionID: sessionID)
    }

    static func noteSnapshot(_ snapshot: AgentRunMCPSnapshot, registration: Registration) async {
        await shared.noteSnapshot(snapshot, registration: registration)
    }

    static func noteSnapshotAndWakeWaiters(
        _ snapshot: AgentRunMCPSnapshot,
        registration: Registration,
        reason: WakeReason
    ) async {
        await shared.noteSnapshotAndWakeWaiters(snapshot, registration: registration, reason: reason)
    }

    static func waitUntilInteresting(
        registration: Registration,
        timeoutSeconds: TimeInterval? = nil
    ) async -> WaitDisposition {
        await shared.waitUntilInteresting(registration: registration, timeoutSeconds: timeoutSeconds)
    }

    static func snapshot(for registration: Registration) async -> AgentRunMCPSnapshot? {
        await shared.snapshot(for: registration)
    }

    static func currentRegistration(for sessionID: UUID) async -> Registration? {
        await shared.currentRegistration(for: sessionID)
    }

    static func hasActiveRegistration(sessionID: UUID) async -> Bool {
        await shared.hasActiveRegistration(sessionID: sessionID)
    }

    static func cleanup(registration: Registration) async {
        await shared.cleanup(registration: registration)
    }
}

extension AgentRunSessionStore {
    static func signalSnapshot(_ snapshot: AgentRunMCPSnapshot, registration: Registration) async {
        await shared.noteSnapshot(snapshot, registration: registration)
    }

    static func signalCommittedSnapshot(
        _ snapshot: AgentRunMCPSnapshot,
        registration: Registration,
        commitID: UUID
    ) async {
        await shared.signalCommittedSnapshot(snapshot, registration: registration, commitID: commitID)
    }

    static func signalSnapshotAndWakeWaiters(
        _ snapshot: AgentRunMCPSnapshot,
        registration: Registration,
        reason: WakeReason
    ) async {
        await shared.noteSnapshotAndWakeWaiters(snapshot, registration: registration, reason: reason)
    }

    static func wakeCurrentWaiters(
        _ snapshot: AgentRunMCPSnapshot,
        registration: Registration,
        reason: WakeReason
    ) async {
        await shared.wakeCurrentWaiters(snapshot, registration: registration, reason: reason)
    }

    @discardableResult
    static func resetSnapshotForNewTurn(registration: Registration) async -> Registration? {
        await shared.resetSnapshotForNewTurn(registration: registration)
    }
}

#if DEBUG
    extension AgentRunSessionStore {
        func test_waiterCount(registration: Registration) -> Int {
            guard records[registration.sessionID]?.registration == registration else { return 0 }
            return records[registration.sessionID]?.waiters.count ?? 0
        }

        func test_expire(registration: Registration) {
            expire(registration: registration)
        }
    }
#endif
