import Foundation

actor AgentRunSessionStore {
    static let shared = AgentRunSessionStore()

    private static func timeoutNanoseconds(_ timeoutSeconds: TimeInterval) -> UInt64 {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else { return 0 }
        let maxSeconds = Double(UInt64.max) / 1_000_000_000
        return UInt64((min(timeoutSeconds, maxSeconds) * 1_000_000_000).rounded(.up))
    }

    struct Registration: Equatable, Hashable {
        let sessionID: UUID
        let generation: UInt64
    }

    struct WaitCursor: Equatable, Hashable {
        let registration: Registration
        let epoch: AgentRunTurnEpoch?
    }

    enum EpochBeginResult: Equatable {
        case accepted(AgentRunTurnEpoch)
        case stale(currentEpoch: AgentRunTurnEpoch?)
        case rejected(reason: String)
    }

    enum WaitDisposition: Equatable {
        case snapshotReady(AgentRunMCPSnapshot)
        case noteworthySnapshot(AgentRunMCPSnapshot, WakeReason)
        case epochAdvanced(AgentRunTurnEpoch, AgentRunEpochTransitionKind)
        case terminalPublicationRejected(epoch: AgentRunTurnEpoch, reason: String)
        case timedOut
        case expired
        case cancelled
    }

    enum WakeReason: String, Equatable {
        case instructionDelivered = "instruction_delivered"
        case steeringRequested = "steering_requested"
    }

    private struct Waiter {
        let id: UUID
        let cursor: WaitCursor
        let continuation: CheckedContinuation<WaitDisposition, Never>
        let timeoutTask: Task<Void, Never>?
    }

    private struct EpochState {
        let epoch: AgentRunTurnEpoch?
        var latestSnapshot: AgentRunMCPSnapshot?
        var pendingNoteworthySnapshot: AgentRunMCPSnapshot?
        var pendingWakeReason: WakeReason?
        var terminalCommitID: UUID?
        var terminalSnapshot: AgentRunMCPSnapshot?
        var successorEpoch: AgentRunTurnEpoch?
        var terminalPublicationFailure: String?

        init(epoch: AgentRunTurnEpoch?) {
            self.epoch = epoch
        }
    }

    private struct Record {
        let registration: Registration
        var currentEpoch: AgentRunTurnEpoch?
        var preEpochState = EpochState(epoch: nil)
        var epochStates: [UUID: EpochState] = [:]
        var waiters: [Waiter] = []
        var expiryTask: Task<Void, Never>?
        var nextEpochOrdinal: UInt64 = 1
        var continuityGeneration: UInt64 = 0
    }

    private static let terminalSnapshotTTL: TimeInterval = 300
    private static let retainedCommittedEpochLimit = 32

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

    func registerIfMissing(sessionID: UUID) -> Registration? {
        guard records[sessionID] == nil else { return nil }
        let registration = makeRegistration(sessionID: sessionID)
        records[sessionID] = Record(registration: registration)
        return registration
    }

    func beginEpoch(
        registration: Registration,
        activationID: UUID,
        expectedCurrentEpoch: AgentRunTurnEpoch?,
        transitionKind: AgentRunEpochTransitionKind,
        seedSnapshot: AgentRunMCPSnapshot? = nil
    ) -> EpochBeginResult {
        guard var record = currentRecord(for: registration, operation: "begin_epoch") else {
            return .rejected(reason: "stale_activation")
        }
        guard record.currentEpoch == expectedCurrentEpoch else {
            recordRejectedOperation(
                "begin_epoch",
                supplied: registration,
                current: record.registration,
                reason: "unexpected_current_epoch"
            )
            return .stale(currentEpoch: record.currentEpoch)
        }

        if transitionKind == .unrelated {
            record.continuityGeneration &+= 1
        }
        let epoch = AgentRunTurnEpoch(
            sessionID: registration.sessionID,
            activationID: activationID,
            registrationGeneration: registration.generation,
            id: UUID(),
            ordinal: record.nextEpochOrdinal,
            continuityGeneration: record.continuityGeneration,
            transitionKind: transitionKind
        )
        record.nextEpochOrdinal &+= 1
        var state = EpochState(epoch: epoch)
        state.latestSnapshot = seedSnapshot
        record.epochStates[epoch.id] = state
        record.currentEpoch = epoch
        pruneCommittedEpochStates(in: &record)
        record.expiryTask?.cancel()
        record.expiryTask = nil
        let waiters = takeWaiters(from: &record) { $0.cursor.epoch != epoch }
        records[registration.sessionID] = record
        resume(waiters, with: .epochAdvanced(epoch, transitionKind))
        return .accepted(epoch)
    }

    func noteSnapshot(_ snapshot: AgentRunMCPSnapshot, cursor: WaitCursor) {
        ingestSnapshot(snapshot, cursor: cursor, wakeReason: nil)
    }

    func noteSnapshotAndWakeWaiters(
        _ snapshot: AgentRunMCPSnapshot,
        cursor: WaitCursor,
        reason: WakeReason
    ) {
        ingestSnapshot(snapshot, cursor: cursor, wakeReason: reason)
    }

    func publishTerminal(
        _ envelope: AgentRunTerminalPublicationEnvelope,
        registration: Registration,
        commitID: UUID,
        successorKind: AgentRunEpochTransitionKind?
    ) -> AgentRunTerminalPublicationResult {
        guard envelope.snapshot.sessionID == registration.sessionID,
              envelope.epoch.sessionID == registration.sessionID,
              envelope.epoch.registrationGeneration == registration.generation
        else {
            recordRejectedOperation(
                "publish_terminal_commit",
                supplied: registration,
                current: records[registration.sessionID]?.registration,
                reason: "session_or_activation_mismatch"
            )
            return .rejected(reason: "session_or_activation_mismatch")
        }
        guard var record = currentRecord(for: registration, operation: "publish_terminal_commit") else {
            return .rejected(reason: "stale_activation")
        }
        guard var state = record.epochStates[envelope.epoch.id], state.epoch == envelope.epoch else {
            recordRejectedOperation(
                "publish_terminal_commit",
                supplied: registration,
                current: record.registration,
                reason: "unknown_epoch"
            )
            return .rejected(reason: "unknown_epoch")
        }
        if state.terminalCommitID == commitID {
            if let successorEpoch = state.successorEpoch {
                return .accepted(successorEpoch: successorEpoch)
            }
            return record.currentEpoch == envelope.epoch
                ? .accepted(successorEpoch: nil)
                : .stale
        }
        if state.terminalCommitID != nil {
            let reason = "different_commit_already_published"
            state.terminalPublicationFailure = reason
            record.epochStates[envelope.epoch.id] = state
            let waiters = record.currentEpoch == envelope.epoch
                ? takeWaiters(from: &record) { $0.cursor.epoch == envelope.epoch }
                : []
            records[registration.sessionID] = record
            resume(waiters, with: .terminalPublicationRejected(epoch: envelope.epoch, reason: reason))
            recordRejectedOperation(
                "publish_terminal_commit",
                supplied: registration,
                current: record.registration,
                reason: reason
            )
            return .rejected(reason: reason)
        }

        state.terminalCommitID = commitID
        state.terminalSnapshot = envelope.snapshot
        state.latestSnapshot = envelope.snapshot
        state.pendingNoteworthySnapshot = nil
        state.pendingWakeReason = nil

        guard record.currentEpoch == envelope.epoch else {
            record.epochStates[envelope.epoch.id] = state
            pruneCommittedEpochStates(in: &record)
            records[registration.sessionID] = record
            #if DEBUG
                AgentModePerfDiagnostics.increment("mcp.waitStore.terminalCommit.staleAccepted")
            #endif
            return .stale
        }

        if let successorKind {
            let successor: AgentRunTurnEpoch
            if let existing = state.successorEpoch {
                successor = existing
            } else {
                if successorKind == .unrelated {
                    record.continuityGeneration &+= 1
                }
                successor = AgentRunTurnEpoch(
                    sessionID: registration.sessionID,
                    activationID: envelope.epoch.activationID,
                    registrationGeneration: registration.generation,
                    id: UUID(),
                    ordinal: record.nextEpochOrdinal,
                    continuityGeneration: record.continuityGeneration,
                    transitionKind: successorKind
                )
                record.nextEpochOrdinal &+= 1
                state.successorEpoch = successor
                record.epochStates[successor.id] = EpochState(epoch: successor)
            }
            record.epochStates[envelope.epoch.id] = state
            record.currentEpoch = successor
            pruneCommittedEpochStates(in: &record)
            record.expiryTask?.cancel()
            record.expiryTask = nil
            let waiters = takeWaiters(from: &record) { $0.cursor.epoch == envelope.epoch }
            records[registration.sessionID] = record
            resume(waiters, with: .epochAdvanced(successor, successorKind))
            #if DEBUG
                AgentModePerfDiagnostics.increment("mcp.waitStore.terminalCommit.acceptedWithSuccessor")
            #endif
            return .accepted(successorEpoch: successor)
        }

        record.epochStates[envelope.epoch.id] = state
        let waiters = takeWaiters(from: &record) { $0.cursor.epoch == envelope.epoch }
        scheduleExpiry(for: &record, cursor: WaitCursor(registration: registration, epoch: envelope.epoch))
        records[registration.sessionID] = record
        resume(waiters, with: .snapshotReady(envelope.snapshot))
        #if DEBUG
            AgentModePerfDiagnostics.increment("mcp.waitStore.terminalCommit.accepted")
        #endif
        return .accepted(successorEpoch: nil)
    }

    func wakeCurrentWaiters(
        _ snapshot: AgentRunMCPSnapshot,
        cursor: WaitCursor,
        reason: WakeReason
    ) {
        guard snapshot.sessionID == cursor.registration.sessionID else { return }
        guard var record = currentRecord(for: cursor.registration, operation: "wake") else { return }
        guard cursor.epoch == record.currentEpoch else { return }
        let acceptedSnapshot = acceptedSnapshot(snapshot, existing: latestSnapshot(in: record, cursor: cursor))
        if acceptedSnapshot == snapshot {
            updateLatestSnapshot(snapshot, in: &record, cursor: cursor)
        }
        let waiters = takeWaiters(from: &record) { $0.cursor == cursor }
        if acceptedSnapshot.isActionableForMCPWait {
            clearPendingWake(in: &record, cursor: cursor)
        }
        records[snapshot.sessionID] = record
        guard !waiters.isEmpty else { return }
        let disposition: WaitDisposition = acceptedSnapshot.isActionableForMCPWait
            ? .snapshotReady(acceptedSnapshot)
            : .noteworthySnapshot(acceptedSnapshot, reason)
        resume(waiters, with: disposition)
    }

    private func ingestSnapshot(
        _ snapshot: AgentRunMCPSnapshot,
        cursor: WaitCursor,
        wakeReason: WakeReason?
    ) {
        guard snapshot.sessionID == cursor.registration.sessionID else {
            recordRejectedOperation(
                "publish",
                supplied: cursor.registration,
                current: records[cursor.registration.sessionID]?.registration,
                reason: "session_mismatch"
            )
            return
        }
        guard var record = currentRecord(for: cursor.registration, operation: "publish") else { return }
        guard cursor.epoch == record.currentEpoch else {
            recordRejectedOperation(
                "publish",
                supplied: cursor.registration,
                current: record.registration,
                reason: "stale_epoch"
            )
            return
        }

        let acceptedSnapshot = acceptedSnapshot(snapshot, existing: latestSnapshot(in: record, cursor: cursor))
        if acceptedSnapshot == snapshot {
            updateLatestSnapshot(snapshot, in: &record, cursor: cursor)
            if snapshot.isActionableForMCPWait {
                clearPendingWake(in: &record, cursor: cursor)
            }
        }

        let disposition: WaitDisposition? = if acceptedSnapshot.isActionableForMCPWait {
            .snapshotReady(acceptedSnapshot)
        } else if let wakeReason {
            .noteworthySnapshot(acceptedSnapshot, wakeReason)
        } else {
            nil
        }
        let waiters = disposition == nil ? [] : takeWaiters(from: &record) { $0.cursor == cursor }
        if case .noteworthySnapshot = disposition, waiters.isEmpty {
            setPendingWake(snapshot: acceptedSnapshot, reason: wakeReason, in: &record, cursor: cursor)
        } else if disposition != nil {
            clearPendingWake(in: &record, cursor: cursor)
        }
        if snapshot.status.isTerminal {
            scheduleExpiry(for: &record, cursor: cursor)
        }
        records[snapshot.sessionID] = record
        if let disposition {
            resume(waiters, with: disposition)
        }
    }

    func waitUntilInteresting(
        cursor: WaitCursor,
        timeoutSeconds: TimeInterval? = nil
    ) async -> WaitDisposition {
        guard let record = currentRecord(for: cursor.registration, operation: "wait") else {
            return .expired
        }
        if cursor.epoch != record.currentEpoch {
            guard let currentEpoch = record.currentEpoch else { return .expired }
            return .epochAdvanced(currentEpoch, transitionKind(from: cursor.epoch, to: currentEpoch))
        }
        if let failure = terminalPublicationFailure(in: record, cursor: cursor), let epoch = cursor.epoch {
            return .terminalPublicationRejected(epoch: epoch, reason: failure)
        }
        if let snapshot = latestSnapshot(in: record, cursor: cursor), snapshot.isActionableForMCPWait {
            return .snapshotReady(snapshot)
        }
        if let pending = pendingWake(in: record, cursor: cursor) {
            var updated = record
            clearPendingWake(in: &updated, cursor: cursor)
            records[cursor.registration.sessionID] = updated
            return .noteworthySnapshot(latestSnapshot(in: updated, cursor: cursor) ?? pending.snapshot, pending.reason)
        }
        if let timeoutSeconds, timeoutSeconds <= 0 {
            return .timedOut
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard var current = currentRecord(for: cursor.registration, operation: "wait_park") else {
                    continuation.resume(returning: .expired)
                    return
                }
                if cursor.epoch != current.currentEpoch {
                    guard let currentEpoch = current.currentEpoch else {
                        continuation.resume(returning: .expired)
                        return
                    }
                    continuation.resume(returning: .epochAdvanced(
                        currentEpoch,
                        transitionKind(from: cursor.epoch, to: currentEpoch)
                    ))
                    return
                }
                if let failure = terminalPublicationFailure(in: current, cursor: cursor), let epoch = cursor.epoch {
                    continuation.resume(returning: .terminalPublicationRejected(epoch: epoch, reason: failure))
                    return
                }
                if let snapshot = latestSnapshot(in: current, cursor: cursor), snapshot.isActionableForMCPWait {
                    continuation.resume(returning: .snapshotReady(snapshot))
                    return
                }
                if let pending = pendingWake(in: current, cursor: cursor) {
                    clearPendingWake(in: &current, cursor: cursor)
                    records[cursor.registration.sessionID] = current
                    continuation.resume(returning: .noteworthySnapshot(
                        latestSnapshot(in: current, cursor: cursor) ?? pending.snapshot,
                        pending.reason
                    ))
                    return
                }
                let timeoutTask: Task<Void, Never>? = timeoutSeconds.map { timeout in
                    Task { [weak self] in
                        do {
                            try await Task.sleep(
                                nanoseconds: Self.timeoutNanoseconds(timeout)
                            )
                            await self?.timeoutWaiter(sessionID: cursor.registration.sessionID, waiterID: waiterID)
                        } catch {}
                    }
                }
                current.waiters.append(Waiter(
                    id: waiterID,
                    cursor: cursor,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                ))
                records[cursor.registration.sessionID] = current
            }
        } onCancel: {
            Task { await self.cancelWaiter(sessionID: cursor.registration.sessionID, waiterID: waiterID) }
        }
    }

    func waitUntilInteresting(
        registration: Registration,
        timeoutSeconds: TimeInterval? = nil
    ) async -> WaitDisposition {
        guard let cursor = currentCursor(for: registration) else { return .expired }
        return await waitUntilInteresting(cursor: cursor, timeoutSeconds: timeoutSeconds)
    }

    func snapshot(for cursor: WaitCursor) -> AgentRunMCPSnapshot? {
        guard let record = currentRecord(for: cursor.registration, operation: "snapshot") else { return nil }
        return latestSnapshot(in: record, cursor: cursor)
    }

    func snapshot(for registration: Registration) -> AgentRunMCPSnapshot? {
        guard let cursor = currentCursor(for: registration) else { return nil }
        return snapshot(for: cursor)
    }

    func currentCursor(for registration: Registration) -> WaitCursor? {
        guard let record = currentRecord(for: registration, operation: "current_cursor") else { return nil }
        return WaitCursor(registration: registration, epoch: record.currentEpoch)
    }

    func currentRegistration(for sessionID: UUID) -> Registration? {
        records[sessionID]?.registration
    }

    func currentEpoch(for registration: Registration) -> AgentRunTurnEpoch? {
        currentRecord(for: registration, operation: "current_epoch")?.currentEpoch
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

    private func transitionKind(
        from previousEpoch: AgentRunTurnEpoch?,
        to currentEpoch: AgentRunTurnEpoch
    ) -> AgentRunEpochTransitionKind {
        guard let previousEpoch else { return currentEpoch.transitionKind }
        guard previousEpoch.continuityGeneration == currentEpoch.continuityGeneration else {
            return .unrelated
        }
        return currentEpoch.transitionKind
    }

    private func pruneCommittedEpochStates(in record: inout Record) {
        var protectedEpochIDs = Set(record.waiters.compactMap { $0.cursor.epoch?.id })
        if let currentEpochID = record.currentEpoch?.id {
            protectedEpochIDs.insert(currentEpochID)
        }
        let removableEpochIDs = record.epochStates.values
            .filter { state in
                guard let epoch = state.epoch else { return false }
                return state.terminalCommitID != nil && !protectedEpochIDs.contains(epoch.id)
            }
            .sorted { lhs, rhs in
                (lhs.epoch?.ordinal ?? 0) > (rhs.epoch?.ordinal ?? 0)
            }
            .dropFirst(Self.retainedCommittedEpochLimit)
            .compactMap { $0.epoch?.id }
        for epochID in removableEpochIDs {
            record.epochStates.removeValue(forKey: epochID)
        }
    }

    private func acceptedSnapshot(
        _ snapshot: AgentRunMCPSnapshot,
        existing: AgentRunMCPSnapshot?
    ) -> AgentRunMCPSnapshot {
        guard let existing else { return snapshot }
        if existing.status.isTerminal {
            if snapshot.status.isTerminal, snapshot.updatedAt >= existing.updatedAt {
                return snapshot
            }
            return existing
        }
        if !snapshot.status.isTerminal, existing.updatedAt > snapshot.updatedAt {
            return existing
        }
        return snapshot
    }

    private func updateLatestSnapshot(_ snapshot: AgentRunMCPSnapshot, in record: inout Record, cursor: WaitCursor) {
        if let epoch = cursor.epoch {
            guard var state = record.epochStates[epoch.id], state.epoch == epoch else { return }
            state.latestSnapshot = snapshot
            record.epochStates[epoch.id] = state
        } else {
            record.preEpochState.latestSnapshot = snapshot
        }
    }

    private func latestSnapshot(in record: Record, cursor: WaitCursor) -> AgentRunMCPSnapshot? {
        if let epoch = cursor.epoch {
            return record.epochStates[epoch.id]?.latestSnapshot
        }
        return record.preEpochState.latestSnapshot
    }

    private func terminalPublicationFailure(in record: Record, cursor: WaitCursor) -> String? {
        guard let epoch = cursor.epoch else { return nil }
        return record.epochStates[epoch.id]?.terminalPublicationFailure
    }

    private func pendingWake(in record: Record, cursor: WaitCursor) -> (snapshot: AgentRunMCPSnapshot, reason: WakeReason)? {
        let state: EpochState? = if let epoch = cursor.epoch {
            record.epochStates[epoch.id]
        } else {
            record.preEpochState
        }
        guard let snapshot = state?.pendingNoteworthySnapshot,
              let reason = state?.pendingWakeReason
        else {
            return nil
        }
        return (snapshot, reason)
    }

    private func setPendingWake(
        snapshot: AgentRunMCPSnapshot,
        reason: WakeReason?,
        in record: inout Record,
        cursor: WaitCursor
    ) {
        guard let reason else { return }
        if let epoch = cursor.epoch {
            guard var state = record.epochStates[epoch.id] else { return }
            state.pendingNoteworthySnapshot = snapshot
            state.pendingWakeReason = reason
            record.epochStates[epoch.id] = state
        } else {
            record.preEpochState.pendingNoteworthySnapshot = snapshot
            record.preEpochState.pendingWakeReason = reason
        }
    }

    private func clearPendingWake(in record: inout Record, cursor: WaitCursor) {
        if let epoch = cursor.epoch {
            guard var state = record.epochStates[epoch.id] else { return }
            state.pendingNoteworthySnapshot = nil
            state.pendingWakeReason = nil
            record.epochStates[epoch.id] = state
        } else {
            record.preEpochState.pendingNoteworthySnapshot = nil
            record.preEpochState.pendingWakeReason = nil
        }
    }

    private func takeWaiters(
        from record: inout Record,
        matching predicate: (Waiter) -> Bool
    ) -> [Waiter] {
        var selected: [Waiter] = []
        record.waiters.removeAll { waiter in
            guard predicate(waiter) else { return false }
            selected.append(waiter)
            return true
        }
        return selected
    }

    private func resume(_ waiters: [Waiter], with disposition: WaitDisposition) {
        for waiter in waiters {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(returning: disposition)
        }
    }

    private func cancelWaiter(sessionID: UUID, waiterID: UUID) {
        guard var record = records[sessionID],
              let index = record.waiters.firstIndex(where: { $0.id == waiterID })
        else { return }
        let waiter = record.waiters.remove(at: index)
        records[sessionID] = record
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(returning: .cancelled)
    }

    private func timeoutWaiter(sessionID: UUID, waiterID: UUID) {
        guard var record = records[sessionID],
              let index = record.waiters.firstIndex(where: { $0.id == waiterID })
        else { return }
        let waiter = record.waiters.remove(at: index)
        records[sessionID] = record
        waiter.continuation.resume(returning: .timedOut)
    }

    private func scheduleExpiry(for record: inout Record, cursor: WaitCursor) {
        record.expiryTask?.cancel()
        record.expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.terminalSnapshotTTL * 1_000_000_000))
                await self?.expire(cursor: cursor)
            } catch {}
        }
    }

    private func expire(cursor: WaitCursor) {
        guard let record = currentRecord(for: cursor.registration, operation: "expire"),
              record.currentEpoch == cursor.epoch
        else { return }
        records.removeValue(forKey: cursor.registration.sessionID)
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
        resume(waiters, with: .expired)
    }

    private func recordRejectedOperation(
        _ operation: String,
        supplied _: Registration,
        current _: Registration?,
        reason: String
    ) {
        #if DEBUG
            AgentModePerfDiagnostics.increment("mcp.waitStore.rejected.\(operation).\(reason)")
        #endif
    }
}

extension AgentRunSessionStore {
    static func register(sessionID: UUID) async -> Registration {
        await shared.register(sessionID: sessionID)
    }

    static func registerIfMissing(sessionID: UUID) async -> Registration? {
        await shared.registerIfMissing(sessionID: sessionID)
    }

    static func beginEpoch(
        registration: Registration,
        activationID: UUID,
        expectedCurrentEpoch: AgentRunTurnEpoch?,
        transitionKind: AgentRunEpochTransitionKind,
        seedSnapshot: AgentRunMCPSnapshot? = nil
    ) async -> EpochBeginResult {
        await shared.beginEpoch(
            registration: registration,
            activationID: activationID,
            expectedCurrentEpoch: expectedCurrentEpoch,
            transitionKind: transitionKind,
            seedSnapshot: seedSnapshot
        )
    }

    static func waitUntilInteresting(
        cursor: WaitCursor,
        timeoutSeconds: TimeInterval? = nil
    ) async -> WaitDisposition {
        await shared.waitUntilInteresting(cursor: cursor, timeoutSeconds: timeoutSeconds)
    }

    static func waitUntilInteresting(
        registration: Registration,
        timeoutSeconds: TimeInterval? = nil
    ) async -> WaitDisposition {
        await shared.waitUntilInteresting(registration: registration, timeoutSeconds: timeoutSeconds)
    }

    static func snapshot(for cursor: WaitCursor) async -> AgentRunMCPSnapshot? {
        await shared.snapshot(for: cursor)
    }

    static func snapshot(for registration: Registration) async -> AgentRunMCPSnapshot? {
        await shared.snapshot(for: registration)
    }

    static func currentCursor(for registration: Registration) async -> WaitCursor? {
        await shared.currentCursor(for: registration)
    }

    static func currentRegistration(for sessionID: UUID) async -> Registration? {
        await shared.currentRegistration(for: sessionID)
    }

    static func currentEpoch(for registration: Registration) async -> AgentRunTurnEpoch? {
        await shared.currentEpoch(for: registration)
    }

    static func hasActiveRegistration(sessionID: UUID) async -> Bool {
        await shared.hasActiveRegistration(sessionID: sessionID)
    }

    static func cleanup(registration: Registration) async {
        await shared.cleanup(registration: registration)
    }

    static func signalSnapshot(_ snapshot: AgentRunMCPSnapshot, cursor: WaitCursor) async {
        await shared.noteSnapshot(snapshot, cursor: cursor)
    }

    static func publishTerminal(
        _ envelope: AgentRunTerminalPublicationEnvelope,
        registration: Registration,
        commitID: UUID,
        successorKind: AgentRunEpochTransitionKind?
    ) async -> AgentRunTerminalPublicationResult {
        await shared.publishTerminal(
            envelope,
            registration: registration,
            commitID: commitID,
            successorKind: successorKind
        )
    }

    static func signalSnapshotAndWakeWaiters(
        _ snapshot: AgentRunMCPSnapshot,
        cursor: WaitCursor,
        reason: WakeReason
    ) async {
        await shared.noteSnapshotAndWakeWaiters(snapshot, cursor: cursor, reason: reason)
    }

    static func wakeCurrentWaiters(
        _ snapshot: AgentRunMCPSnapshot,
        cursor: WaitCursor,
        reason: WakeReason
    ) async {
        await shared.wakeCurrentWaiters(snapshot, cursor: cursor, reason: reason)
    }
}

#if DEBUG
    extension AgentRunSessionStore {
        func test_waiterCount(registration: Registration) -> Int {
            guard records[registration.sessionID]?.registration == registration else { return 0 }
            return records[registration.sessionID]?.waiters.count ?? 0
        }

        func test_expire(cursor: WaitCursor) {
            expire(cursor: cursor)
        }

        func test_setTerminalCommitID(_ commitID: UUID, cursor: WaitCursor) {
            guard var record = records[cursor.registration.sessionID],
                  record.registration == cursor.registration,
                  let epoch = cursor.epoch,
                  var state = record.epochStates[epoch.id]
            else { return }
            state.terminalCommitID = commitID
            record.epochStates[epoch.id] = state
            records[cursor.registration.sessionID] = record
        }
    }
#endif
