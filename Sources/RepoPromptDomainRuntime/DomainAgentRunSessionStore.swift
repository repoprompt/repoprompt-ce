import Foundation

package struct DomainAgentSessionRegistration: Codable, Equatable, Hashable, Sendable {
    package let runtimeID: UUID
    package let runtimeGeneration: UInt64
    package let sessionID: UUID
    package let generation: UInt64

    package init(
        runtimeID: UUID,
        runtimeGeneration: UInt64,
        sessionID: UUID,
        generation: UInt64
    ) {
        self.runtimeID = runtimeID
        self.runtimeGeneration = runtimeGeneration
        self.sessionID = sessionID
        self.generation = generation
    }
}

package struct DomainAgentSessionWaitCursor: Equatable, Hashable, Sendable {
    package let registration: DomainAgentSessionRegistration
    package let epoch: DomainAgentRunTurnEpoch?

    package init(
        registration: DomainAgentSessionRegistration,
        epoch: DomainAgentRunTurnEpoch?
    ) {
        self.registration = registration
        self.epoch = epoch
    }
}

package enum DomainAgentSessionDurableState: String, Codable, Sendable {
    case dormant
    case active
    case interrupted
    case terminal
}

package struct DomainAgentSessionDurableMetadata: Codable, Equatable, Sendable {
    package let sessionID: UUID
    package let owningRuntimeID: UUID
    package let owningRuntimeGeneration: UInt64
    package let registrationGeneration: UInt64
    package let lastEpochOrdinal: UInt64
    package let continuityGeneration: UInt64
    package let state: DomainAgentSessionDurableState
    package let resumable: Bool
    package let updatedAt: Date

    package var isLive: Bool {
        state == .active
    }
}

package struct DomainAgentSessionShutdownResult: Equatable, Sendable {
    package let cooperativeSessionIDs: [UUID]
    package let interruptedSessionIDs: [UUID]
}

package enum DomainAgentSessionResumeClaimResult: Equatable, Sendable {
    case accepted(DomainAgentSessionRegistration)
    case unavailable
    case alreadyActive
    case shuttingDown
}

package enum DomainAgentSessionPersistenceHealth: Equatable, Sendable {
    case ready
    case degradedReadOnly(reason: String)
}

package struct DomainAgentSessionStoreSnapshot: Equatable, Sendable {
    package let persistenceHealth: DomainAgentSessionPersistenceHealth
    package let retainedMetadataCount: Int
    package let omittedRetentionCount: UInt64
    package let pendingPersistenceCount: Int
}

private enum DomainAgentSessionMetadataDecodeError: Error {
    case futureVersion
    case wrongProfile
    case corrupt

    var reason: String {
        switch self {
        case .futureVersion:
            "future_agent_session_metadata"
        case .wrongProfile:
            "wrong_agent_session_profile"
        case .corrupt:
            "agent_session_metadata_decode_failed"
        }
    }
}

private struct DomainAgentSessionMetadataDocument: Codable, Sendable {
    static let schemaVersion = 1

    let version: Int
    let profileIdentifier: String
    let revision: UInt64
    let sessions: [DomainAgentSessionDurableMetadata]
    let updatedAt: Date

    init(
        profileIdentifier: String,
        revision: UInt64,
        sessions: [DomainAgentSessionDurableMetadata],
        updatedAt: Date
    ) {
        version = Self.schemaVersion
        self.profileIdentifier = profileIdentifier
        self.revision = revision
        self.sessions = sessions
        self.updatedAt = updatedAt
    }
}

private actor DomainAgentCancellationCompletionTracker {
    private var completed: Set<UUID> = []

    func markCompleted(_ sessionID: UUID) {
        completed.insert(sessionID)
    }

    func snapshot() -> Set<UUID> {
        completed
    }
}

package actor DomainAgentRunSessionStore {
    package typealias Registration = DomainAgentSessionRegistration
    package typealias WaitCursor = DomainAgentSessionWaitCursor

    private static func timeoutNanoseconds(_ timeoutSeconds: TimeInterval) -> UInt64 {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else { return 0 }
        let maxSeconds = Double(UInt64.max) / 1_000_000_000
        return UInt64((min(timeoutSeconds, maxSeconds) * 1_000_000_000).rounded(.up))
    }

    package enum EpochBeginResult: Equatable, Sendable {
        case accepted(DomainAgentRunTurnEpoch)
        case stale(currentEpoch: DomainAgentRunTurnEpoch?)
        case rejected(reason: String)
    }

    package enum WaitDisposition: Equatable, Sendable {
        case snapshotReady(DomainAgentRunSnapshot)
        case noteworthySnapshot(NoteworthyWake)
        case epochAdvanced(DomainAgentRunTurnEpoch, DomainAgentRunEpochTransitionKind)
        case terminalPublicationRejected(epoch: DomainAgentRunTurnEpoch, reason: String)
        case timedOut
        case expired
        case cancelled
    }

    package enum WakeReason: String, Equatable, Sendable {
        case instructionDelivered = "instruction_delivered"
        case steeringRequested = "steering_requested"
    }

    package struct NoteworthyWake: Equatable, Sendable {
        package let snapshot: DomainAgentRunSnapshot
        package let reason: WakeReason
        package let steeringMessage: String?
        package let steeringOriginRunID: UUID?

        package init(
            snapshot: DomainAgentRunSnapshot,
            reason: WakeReason,
            steeringMessage: String?,
            steeringOriginRunID: UUID? = nil
        ) {
            self.snapshot = snapshot
            self.reason = reason
            self.steeringMessage = steeringMessage
            self.steeringOriginRunID = steeringOriginRunID
        }
    }

    private struct Waiter {
        let id: UUID
        let cursor: WaitCursor
        let continuation: CheckedContinuation<WaitDisposition, Never>
        let timeoutTask: Task<Void, Never>?
    }

    private struct EpochState {
        let epoch: DomainAgentRunTurnEpoch?
        var latestSnapshot: DomainAgentRunSnapshot?
        var pendingNoteworthyWake: NoteworthyWake?
        var terminalCommitID: UUID?
        var terminalSnapshot: DomainAgentRunSnapshot?
        var successorEpoch: DomainAgentRunTurnEpoch?
        var terminalPublicationFailure: String?

        init(epoch: DomainAgentRunTurnEpoch?) {
            self.epoch = epoch
        }
    }

    private struct Record {
        let registration: Registration
        var currentEpoch: DomainAgentRunTurnEpoch?
        var preEpochState = EpochState(epoch: nil)
        var epochStates: [UUID: EpochState] = [:]
        var waiters: [Waiter] = []
        var expiryTask: Task<Void, Never>?
        var nextEpochOrdinal: UInt64 = 1
        var continuityGeneration: UInt64 = 0
    }

    private static let terminalSnapshotTTL: TimeInterval = 300
    private static let retainedCommittedEpochLimit = 32
    private static let retainedMetadataLimit = 512
    private static let retainedInactiveAge: TimeInterval = 30 * 24 * 60 * 60
    private static let persistenceDebounce: Duration = .milliseconds(100)
    private static let persistenceRetryLimit = 3

    private let identity: DomainRuntimeIdentity
    private let persistence: DomainPersistenceCoordinator
    private let profileIdentifier: String
    private var records: [UUID: Record] = [:]
    private var durableMetadata: [UUID: DomainAgentSessionDurableMetadata] = [:]
    private var persistedMetadataBase: [UUID: DomainAgentSessionDurableMetadata] = [:]
    private var dirtyMetadataSessionIDs: Set<UUID> = []
    private var cancellationHandlers: [UUID: @Sendable () async -> Void] = [:]
    private var persistenceHealth: DomainAgentSessionPersistenceHealth = .ready
    private var persistedRevision: UInt64 = 0
    private var omittedRetentionCount: UInt64 = 0
    private var nextGeneration: UInt64 = 1
    private var didBootstrap = false
    private var isShuttingDown = false
    private var persistenceDebounceTask: Task<Void, Never>?
    private var activePersistenceFlush: (id: UUID, task: Task<Bool, Never>)?
    #if DEBUG
        private var testMetadataFlushBeforeCAS: (@Sendable () async -> Void)?
        private var testShutdownAfterDetach: (@Sendable () async -> Void)?
    #endif

    package init(
        identity: DomainRuntimeIdentity,
        persistence: DomainPersistenceCoordinator,
        profileIdentifier: String
    ) {
        self.identity = identity
        self.persistence = persistence
        self.profileIdentifier = profileIdentifier
    }

    package func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        do {
            let current = try await persistence.loadAgentSessionMetadataData()
            if let data = current.data {
                try bootstrapCurrentDocument(data)
            } else {
                try await bootstrapLegacyDocument()
            }
            pruneDurableMetadata(now: Date())
            if !dirtyMetadataSessionIDs.isEmpty {
                scheduleMetadataPersistence()
            }
        } catch let error as DomainAgentSessionMetadataDecodeError {
            persistenceHealth = .degradedReadOnly(reason: error.reason)
        } catch {
            persistenceHealth = .degradedReadOnly(reason: "agent_session_metadata_io_failed")
        }
    }

    package func restoredMetadata() -> [DomainAgentSessionDurableMetadata] {
        durableMetadata.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    package func snapshot() -> DomainAgentSessionStoreSnapshot {
        DomainAgentSessionStoreSnapshot(
            persistenceHealth: persistenceHealth,
            retainedMetadataCount: durableMetadata.count,
            omittedRetentionCount: omittedRetentionCount,
            pendingPersistenceCount: dirtyMetadataSessionIDs.count
        )
    }

    package func claimResumableSession(sessionID: UUID) async -> DomainAgentSessionResumeClaimResult {
        guard !isShuttingDown else { return .shuttingDown }
        guard records[sessionID] == nil else { return .alreadyActive }
        guard persistenceHealth == .ready,
              let metadata = durableMetadata[sessionID],
              metadata.resumable,
              let persisted = persistedMetadataBase[sessionID],
              persisted.state != .active
        else {
            return .unavailable
        }
        let registration = makeRegistration(sessionID: sessionID)
        var record = Record(registration: registration)
        record.nextEpochOrdinal = max(1, metadata.lastEpochOrdinal &+ 1)
        record.continuityGeneration = metadata.continuityGeneration
        records[sessionID] = record
        updateMetadata(for: record, state: .active, resumable: true)
        guard await persistMetadataImmediately() else {
            records.removeValue(forKey: sessionID)
            durableMetadata[sessionID] = metadata
            dirtyMetadataSessionIDs.remove(sessionID)
            return .unavailable
        }
        return .accepted(registration)
    }

    package func register(sessionID: UUID) -> Registration {
        guard !isShuttingDown else {
            return Registration(
                runtimeID: identity.runtimeID,
                runtimeGeneration: identity.lifecycleGeneration,
                sessionID: sessionID,
                generation: 0
            )
        }
        if let previous = records.removeValue(forKey: sessionID) {
            previous.expiryTask?.cancel()
            expireWaiters(previous.waiters)
            cancellationHandlers.removeValue(forKey: sessionID)
            recordRejectedOperation(
                "register",
                supplied: previous.registration,
                current: nil,
                reason: "replaced_registration"
            )
        }
        let registration = makeRegistration(sessionID: sessionID)
        records[sessionID] = Record(registration: registration)
        updateMetadata(for: records[sessionID], state: .active, resumable: true)
        scheduleMetadataPersistence()
        return registration
    }

    package func registerIfMissing(sessionID: UUID) -> Registration? {
        guard !isShuttingDown, records[sessionID] == nil else { return nil }
        let registration = makeRegistration(sessionID: sessionID)
        records[sessionID] = Record(registration: registration)
        updateMetadata(for: records[sessionID], state: .active, resumable: true)
        scheduleMetadataPersistence()
        return registration
    }

    package func beginEpoch(
        registration: Registration,
        activationID: UUID,
        expectedCurrentEpoch: DomainAgentRunTurnEpoch?,
        transitionKind: DomainAgentRunEpochTransitionKind,
        seedSnapshot: DomainAgentRunSnapshot? = nil
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
        let epoch = DomainAgentRunTurnEpoch(
            runtimeID: identity.runtimeID,
            runtimeGeneration: identity.lifecycleGeneration,
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
        updateMetadata(for: record, state: .active, resumable: true)
        scheduleMetadataPersistence()
        resume(waiters, with: .epochAdvanced(epoch, transitionKind))
        return .accepted(epoch)
    }

    package func noteSnapshot(_ snapshot: DomainAgentRunSnapshot, cursor: WaitCursor) {
        ingestSnapshot(snapshot, cursor: cursor, wakeReason: nil)
    }

    package func noteSnapshotAndWakeWaiters(
        _ snapshot: DomainAgentRunSnapshot,
        cursor: WaitCursor,
        reason: WakeReason,
        steeringMessage: String? = nil,
        steeringOriginRunID: UUID? = nil
    ) {
        ingestSnapshot(
            snapshot,
            cursor: cursor,
            wakeReason: reason,
            steeringMessage: steeringMessage,
            steeringOriginRunID: steeringOriginRunID
        )
    }

    package func publishTerminal(
        _ envelope: DomainAgentRunTerminalPublicationEnvelope,
        registration: Registration,
        commitID: UUID,
        successorKind: DomainAgentRunEpochTransitionKind?
    ) -> DomainAgentRunTerminalPublicationResult {
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
        state.pendingNoteworthyWake = nil

        guard record.currentEpoch == envelope.epoch else {
            record.epochStates[envelope.epoch.id] = state
            pruneCommittedEpochStates(in: &record)
            records[registration.sessionID] = record
            return .stale
        }

        if let successorKind {
            let successor: DomainAgentRunTurnEpoch
            if let existing = state.successorEpoch {
                successor = existing
            } else {
                if successorKind == .unrelated {
                    record.continuityGeneration &+= 1
                }
                successor = DomainAgentRunTurnEpoch(
                    runtimeID: identity.runtimeID,
                    runtimeGeneration: identity.lifecycleGeneration,
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
            updateMetadata(for: record, state: .active, resumable: true)
            scheduleMetadataPersistence()
            resume(waiters, with: .epochAdvanced(successor, successorKind))
            return .accepted(successorEpoch: successor)
        }

        record.epochStates[envelope.epoch.id] = state
        let waiters = takeWaiters(from: &record) { $0.cursor.epoch == envelope.epoch }
        scheduleExpiry(for: &record, cursor: WaitCursor(registration: registration, epoch: envelope.epoch))
        records[registration.sessionID] = record
        updateMetadata(for: record, state: .terminal, resumable: true)
        scheduleMetadataPersistence()
        resume(waiters, with: .snapshotReady(envelope.snapshot))
        return .accepted(successorEpoch: nil)
    }

    package func wakeCurrentWaiters(
        _ snapshot: DomainAgentRunSnapshot,
        cursor: WaitCursor,
        reason: WakeReason,
        steeringMessage: String? = nil,
        steeringOriginRunID: UUID? = nil
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
            : .noteworthySnapshot(NoteworthyWake(
                snapshot: acceptedSnapshot,
                reason: reason,
                steeringMessage: steeringMessage,
                steeringOriginRunID: steeringOriginRunID
            ))
        resume(waiters, with: disposition)
    }

    private func ingestSnapshot(
        _ snapshot: DomainAgentRunSnapshot,
        cursor: WaitCursor,
        wakeReason: WakeReason?,
        steeringMessage: String? = nil,
        steeringOriginRunID: UUID? = nil
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
            .noteworthySnapshot(NoteworthyWake(
                snapshot: acceptedSnapshot,
                reason: wakeReason,
                steeringMessage: steeringMessage,
                steeringOriginRunID: steeringOriginRunID
            ))
        } else {
            nil
        }
        let waiters = disposition == nil ? [] : takeWaiters(from: &record) { $0.cursor == cursor }
        if case let .noteworthySnapshot(wake) = disposition, waiters.isEmpty {
            setPendingWake(wake, in: &record, cursor: cursor)
        } else if disposition != nil {
            clearPendingWake(in: &record, cursor: cursor)
        }
        if snapshot.status.isTerminal {
            scheduleExpiry(for: &record, cursor: cursor)
            updateMetadata(for: record, state: .terminal, resumable: true)
            scheduleMetadataPersistence()
        }
        records[snapshot.sessionID] = record
        if let disposition {
            resume(waiters, with: disposition)
        }
    }

    package func waitUntilInteresting(
        cursor: WaitCursor,
        timeoutSeconds: TimeInterval? = nil
    ) async -> WaitDisposition {
        guard !isShuttingDown else { return .cancelled }
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
            return .noteworthySnapshot(NoteworthyWake(
                snapshot: latestSnapshot(in: updated, cursor: cursor) ?? pending.snapshot,
                reason: pending.reason,
                steeringMessage: pending.steeringMessage,
                steeringOriginRunID: pending.steeringOriginRunID
            ))
        }
        if let timeoutSeconds, timeoutSeconds <= 0 {
            return .timedOut
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !isShuttingDown else {
                    continuation.resume(returning: .cancelled)
                    return
                }
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
                    continuation.resume(returning: .noteworthySnapshot(NoteworthyWake(
                        snapshot: latestSnapshot(in: current, cursor: cursor) ?? pending.snapshot,
                        reason: pending.reason,
                        steeringMessage: pending.steeringMessage,
                        steeringOriginRunID: pending.steeringOriginRunID
                    )))
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

    package func waitUntilInteresting(
        registration: Registration,
        timeoutSeconds: TimeInterval? = nil
    ) async -> WaitDisposition {
        guard !isShuttingDown else { return .cancelled }
        guard let cursor = currentCursor(for: registration) else { return .expired }
        return await waitUntilInteresting(cursor: cursor, timeoutSeconds: timeoutSeconds)
    }

    package func snapshot(for cursor: WaitCursor) -> DomainAgentRunSnapshot? {
        guard let record = currentRecord(for: cursor.registration, operation: "snapshot") else { return nil }
        return latestSnapshot(in: record, cursor: cursor)
    }

    package func snapshot(for registration: Registration) -> DomainAgentRunSnapshot? {
        guard let cursor = currentCursor(for: registration) else { return nil }
        return snapshot(for: cursor)
    }

    package func currentCursor(for registration: Registration) -> WaitCursor? {
        guard let record = currentRecord(for: registration, operation: "current_cursor") else { return nil }
        return WaitCursor(registration: registration, epoch: record.currentEpoch)
    }

    package func currentRegistration(for sessionID: UUID) -> Registration? {
        records[sessionID]?.registration
    }

    package func currentEpoch(for registration: Registration) -> DomainAgentRunTurnEpoch? {
        currentRecord(for: registration, operation: "current_epoch")?.currentEpoch
    }

    package func hasActiveRegistration(sessionID: UUID) -> Bool {
        records[sessionID] != nil
    }

    package func cleanup(registration: Registration) {
        guard let record = currentRecord(for: registration, operation: "cleanup") else { return }
        records.removeValue(forKey: registration.sessionID)
        record.expiryTask?.cancel()
        expireWaiters(record.waiters)
        cancellationHandlers.removeValue(forKey: registration.sessionID)
        updateMetadata(for: record, state: .dormant, resumable: true)
        scheduleMetadataPersistence()
    }

    @discardableResult
    package func installCancellationHandler(
        registration: Registration,
        handler: @escaping @Sendable () async -> Void
    ) -> Bool {
        guard !isShuttingDown,
              currentRecord(for: registration, operation: "install_cancellation") != nil
        else {
            return false
        }
        cancellationHandlers[registration.sessionID] = handler
        return true
    }

    package func removeCancellationHandler(registration: Registration) {
        guard currentRecord(for: registration, operation: "remove_cancellation") != nil else { return }
        cancellationHandlers.removeValue(forKey: registration.sessionID)
    }

    package func shutdown(deadline: Duration = .seconds(5)) async -> DomainAgentSessionShutdownResult {
        guard !isShuttingDown else {
            return DomainAgentSessionShutdownResult(cooperativeSessionIDs: [], interruptedSessionIDs: [])
        }
        isShuttingDown = true
        let activeRecords = records
        records.removeAll()
        let handlers = cancellationHandlers
        cancellationHandlers.removeAll()
        #if DEBUG
            await testShutdownAfterDetach?()
        #endif
        for record in activeRecords.values {
            record.expiryTask?.cancel()
            resume(record.waiters, with: .cancelled)
        }

        let tracker = DomainAgentCancellationCompletionTracker()
        var cancellationTasks: [UUID: Task<Void, Never>] = [:]
        for (sessionID, handler) in handlers {
            cancellationTasks[sessionID] = Task {
                await handler()
                await tracker.markCompleted(sessionID)
            }
        }
        let clock = ContinuousClock()
        let deadlineInstant = clock.now.advanced(by: deadline)
        let sessionsWithoutHandlers = Set(activeRecords.keys).subtracting(handlers.keys)
        var completedHandlers = await tracker.snapshot()
        while completedHandlers.count < handlers.count, clock.now < deadlineInstant {
            let remaining = clock.now.duration(to: deadlineInstant)
            do {
                try await Task.sleep(for: min(remaining, .milliseconds(10)))
            } catch {
                break
            }
            completedHandlers = await tracker.snapshot()
        }
        completedHandlers = await tracker.snapshot()
        for (sessionID, task) in cancellationTasks where !completedHandlers.contains(sessionID) {
            task.cancel()
        }
        let cooperativeSet = sessionsWithoutHandlers.union(completedHandlers)
        let cooperative = Array(cooperativeSet)
        let interrupted = activeRecords.keys.filter { !cooperativeSet.contains($0) }
        for record in activeRecords.values {
            updateMetadata(
                for: record,
                state: cooperativeSet.contains(record.registration.sessionID) ? .dormant : .interrupted,
                resumable: true
            )
        }
        await persistMetadata()
        return DomainAgentSessionShutdownResult(
            cooperativeSessionIDs: cooperative.sorted { $0.uuidString < $1.uuidString },
            interruptedSessionIDs: interrupted.sorted { $0.uuidString < $1.uuidString }
        )
    }

    private func transitionKind(
        from previousEpoch: DomainAgentRunTurnEpoch?,
        to currentEpoch: DomainAgentRunTurnEpoch
    ) -> DomainAgentRunEpochTransitionKind {
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
        _ snapshot: DomainAgentRunSnapshot,
        existing: DomainAgentRunSnapshot?
    ) -> DomainAgentRunSnapshot {
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

    private func updateLatestSnapshot(_ snapshot: DomainAgentRunSnapshot, in record: inout Record, cursor: WaitCursor) {
        if let epoch = cursor.epoch {
            guard var state = record.epochStates[epoch.id], state.epoch == epoch else { return }
            state.latestSnapshot = snapshot
            record.epochStates[epoch.id] = state
        } else {
            record.preEpochState.latestSnapshot = snapshot
        }
    }

    private func latestSnapshot(in record: Record, cursor: WaitCursor) -> DomainAgentRunSnapshot? {
        if let epoch = cursor.epoch {
            return record.epochStates[epoch.id]?.latestSnapshot
        }
        return record.preEpochState.latestSnapshot
    }

    private func terminalPublicationFailure(in record: Record, cursor: WaitCursor) -> String? {
        guard let epoch = cursor.epoch else { return nil }
        return record.epochStates[epoch.id]?.terminalPublicationFailure
    }

    private func pendingWake(in record: Record, cursor: WaitCursor) -> NoteworthyWake? {
        if let epoch = cursor.epoch {
            return record.epochStates[epoch.id]?.pendingNoteworthyWake
        }
        return record.preEpochState.pendingNoteworthyWake
    }

    private func setPendingWake(
        _ wake: NoteworthyWake,
        in record: inout Record,
        cursor: WaitCursor
    ) {
        if let epoch = cursor.epoch {
            guard var state = record.epochStates[epoch.id] else { return }
            state.pendingNoteworthyWake = wake
            record.epochStates[epoch.id] = state
        } else {
            record.preEpochState.pendingNoteworthyWake = wake
        }
    }

    private func clearPendingWake(in record: inout Record, cursor: WaitCursor) {
        if let epoch = cursor.epoch {
            guard var state = record.epochStates[epoch.id] else { return }
            state.pendingNoteworthyWake = nil
            record.epochStates[epoch.id] = state
        } else {
            record.preEpochState.pendingNoteworthyWake = nil
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
        cancellationHandlers.removeValue(forKey: cursor.registration.sessionID)
        updateMetadata(for: record, state: .dormant, resumable: true)
        scheduleMetadataPersistence()
    }

    private func makeRegistration(sessionID: UUID) -> Registration {
        let registration = Registration(
            runtimeID: identity.runtimeID,
            runtimeGeneration: identity.lifecycleGeneration,
            sessionID: sessionID,
            generation: nextGeneration
        )
        nextGeneration &+= 1
        return registration
    }

    private func currentRecord(for registration: Registration, operation: String) -> Record? {
        guard registration.runtimeID == identity.runtimeID,
              registration.runtimeGeneration == identity.lifecycleGeneration
        else {
            recordRejectedOperation(operation, supplied: registration, current: nil, reason: "stale_runtime")
            return nil
        }
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
        _ = operation
        _ = reason
    }

    private func updateMetadata(
        for record: Record?,
        state: DomainAgentSessionDurableState,
        resumable: Bool
    ) {
        guard let record else { return }
        let sessionID = record.registration.sessionID
        durableMetadata[sessionID] = DomainAgentSessionDurableMetadata(
            sessionID: sessionID,
            owningRuntimeID: identity.runtimeID,
            owningRuntimeGeneration: identity.lifecycleGeneration,
            registrationGeneration: record.registration.generation,
            lastEpochOrdinal: record.currentEpoch?.ordinal ?? 0,
            continuityGeneration: record.currentEpoch?.continuityGeneration ?? record.continuityGeneration,
            state: state,
            resumable: resumable && persistenceHealth == .ready,
            updatedAt: Date()
        )
        if persistenceHealth == .ready {
            dirtyMetadataSessionIDs.insert(sessionID)
            pruneDurableMetadata(now: Date())
        }
    }

    private func bootstrapCurrentDocument(_ data: Data) throws {
        let document = try decodeDocument(data)
        persistedRevision = document.revision
        for value in document.sessions {
            guard persistedMetadataBase[value.sessionID] == nil else {
                throw DomainAgentSessionMetadataDecodeError.corrupt
            }
            persistedMetadataBase[value.sessionID] = value
            durableMetadata[value.sessionID] = restoredProjection(value)
            nextGeneration = max(nextGeneration, value.registrationGeneration &+ 1)
        }
    }

    private func bootstrapLegacyDocument() async throws {
        let legacy = try await persistence.loadLegacyAgentSessionMetadataData()
        guard let data = legacy.data else { return }
        guard let values = try? JSONDecoder().decode([DomainAgentSessionDurableMetadata].self, from: data) else {
            throw DomainAgentSessionMetadataDecodeError.corrupt
        }
        for value in values {
            guard durableMetadata[value.sessionID] == nil else {
                throw DomainAgentSessionMetadataDecodeError.corrupt
            }
            persistedMetadataBase[value.sessionID] = value
            durableMetadata[value.sessionID] = restoredProjection(value)
            dirtyMetadataSessionIDs.insert(value.sessionID)
            nextGeneration = max(nextGeneration, value.registrationGeneration &+ 1)
        }
    }

    private func restoredProjection(
        _ value: DomainAgentSessionDurableMetadata
    ) -> DomainAgentSessionDurableMetadata {
        DomainAgentSessionDurableMetadata(
            sessionID: value.sessionID,
            owningRuntimeID: value.owningRuntimeID,
            owningRuntimeGeneration: value.owningRuntimeGeneration,
            registrationGeneration: value.registrationGeneration,
            lastEpochOrdinal: value.lastEpochOrdinal,
            continuityGeneration: value.continuityGeneration,
            state: value.state == .terminal ? .terminal : .dormant,
            resumable: value.resumable,
            updatedAt: value.updatedAt
        )
    }

    private func decodeDocument(_ data: Data) throws -> DomainAgentSessionMetadataDocument {
        guard let document = try? JSONDecoder().decode(DomainAgentSessionMetadataDocument.self, from: data) else {
            throw DomainAgentSessionMetadataDecodeError.corrupt
        }
        guard document.version <= DomainAgentSessionMetadataDocument.schemaVersion else {
            throw DomainAgentSessionMetadataDecodeError.futureVersion
        }
        guard document.version == DomainAgentSessionMetadataDocument.schemaVersion else {
            throw DomainAgentSessionMetadataDecodeError.corrupt
        }
        guard document.profileIdentifier == profileIdentifier else {
            throw DomainAgentSessionMetadataDecodeError.wrongProfile
        }
        var seenSessionIDs: Set<UUID> = []
        for value in document.sessions {
            guard seenSessionIDs.insert(value.sessionID).inserted else {
                throw DomainAgentSessionMetadataDecodeError.corrupt
            }
        }
        return document
    }

    private func pruneDurableMetadata(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retainedInactiveAge)
        let expired = durableMetadata.values.filter {
            ($0.state == .dormant || $0.state == .terminal) && $0.updatedAt < cutoff
        }
        for metadata in expired {
            durableMetadata.removeValue(forKey: metadata.sessionID)
            if persistenceHealth == .ready {
                dirtyMetadataSessionIDs.insert(metadata.sessionID)
            }
        }
        guard durableMetadata.count > Self.retainedMetadataLimit else { return }
        let retainedIDs = Set(durableMetadata.values.sorted { lhs, rhs in
            let lhsPriority = lhs.state == .active || lhs.state == .interrupted ? 0 : 1
            let rhsPriority = rhs.state == .active || rhs.state == .interrupted ? 0 : 1
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return lhs.updatedAt > rhs.updatedAt
        }.prefix(Self.retainedMetadataLimit).map(\.sessionID))
        let removed = durableMetadata.values.filter { !retainedIDs.contains($0.sessionID) }
        for metadata in removed {
            if metadata.state == .active || metadata.state == .interrupted {
                omittedRetentionCount &+= 1
            }
            durableMetadata.removeValue(forKey: metadata.sessionID)
            if persistenceHealth == .ready {
                dirtyMetadataSessionIDs.insert(metadata.sessionID)
            }
        }
    }

    private func scheduleMetadataPersistence() {
        guard didBootstrap,
              persistenceHealth == .ready,
              !dirtyMetadataSessionIDs.isEmpty,
              persistenceDebounceTask == nil
        else { return }
        persistenceDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.persistenceDebounce)
            } catch {
                return
            }
            await self?.runScheduledPersistence()
        }
    }

    private func runScheduledPersistence() async {
        persistenceDebounceTask = nil
        _ = await persistMetadataImmediately()
        if !dirtyMetadataSessionIDs.isEmpty {
            scheduleMetadataPersistence()
        }
    }

    private func persistMetadataImmediately() async -> Bool {
        persistenceDebounceTask?.cancel()
        persistenceDebounceTask = nil
        if let activePersistenceFlush {
            let completed = await activePersistenceFlush.task.value
            if dirtyMetadataSessionIDs.isEmpty || !completed {
                return completed
            }
        }
        let flushID = UUID()
        let task = Task { [weak self] in
            await self?.performMetadataFlush() ?? false
        }
        activePersistenceFlush = (flushID, task)
        let result = await task.value
        if activePersistenceFlush?.id == flushID {
            activePersistenceFlush = nil
        }
        return result
    }

    private func performMetadataFlush() async -> Bool {
        guard persistenceHealth == .ready else { return false }
        guard !dirtyMetadataSessionIDs.isEmpty else { return true }

        for attempt in 0 ..< Self.persistenceRetryLimit {
            let changedIDs = dirtyMetadataSessionIDs
            let changes = changedIDs.map { sessionID in
                (
                    sessionID: sessionID,
                    base: persistedMetadataBase[sessionID],
                    value: durableMetadata[sessionID]
                )
            }
            do {
                let latest = try await persistence.loadAgentSessionMetadataData()
                let latestDocument: DomainAgentSessionMetadataDocument
                if let data = latest.data {
                    latestDocument = try decodeDocument(data)
                } else {
                    latestDocument = DomainAgentSessionMetadataDocument(
                        profileIdentifier: profileIdentifier,
                        revision: 0,
                        sessions: [],
                        updatedAt: Date.distantPast
                    )
                }
                var merged = Dictionary(
                    uniqueKeysWithValues: latestDocument.sessions.map { ($0.sessionID, $0) }
                )
                for change in changes {
                    guard merged[change.sessionID] == change.base else {
                        persistenceHealth = .degradedReadOnly(reason: "agent_session_ownership_conflict")
                        return false
                    }
                    merged[change.sessionID] = change.value
                }
                let bounded = Self.boundedPersistedMetadata(Array(merged.values), now: Date())
                let document = DomainAgentSessionMetadataDocument(
                    profileIdentifier: profileIdentifier,
                    revision: max(persistedRevision, latestDocument.revision) &+ 1,
                    sessions: bounded,
                    updatedAt: Date()
                )
                #if DEBUG
                    await testMetadataFlushBeforeCAS?()
                #endif
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(document)
                try await persistence.compareAndSwapAgentSessionMetadataData(
                    expectedDigest: latest.digest,
                    data: data
                )
                let committed = Dictionary(uniqueKeysWithValues: bounded.map { ($0.sessionID, $0) })
                persistedRevision = document.revision
                for change in changes {
                    persistedMetadataBase[change.sessionID] = committed[change.sessionID]
                    if durableMetadata[change.sessionID] == change.value {
                        dirtyMetadataSessionIDs.remove(change.sessionID)
                    }
                }
                return true
            } catch DomainPersistenceError.externalDocumentConflict where attempt + 1 < Self.persistenceRetryLimit {
                continue
            } catch let error as DomainAgentSessionMetadataDecodeError {
                persistenceHealth = .degradedReadOnly(reason: error.reason)
                return false
            } catch DomainPersistenceError.externalDocumentConflict {
                persistenceHealth = .degradedReadOnly(reason: "agent_session_metadata_conflict")
                return false
            } catch {
                persistenceHealth = .degradedReadOnly(reason: "agent_session_metadata_write_failed")
                return false
            }
        }
        persistenceHealth = .degradedReadOnly(reason: "agent_session_metadata_conflict")
        return false
    }

    private static func boundedPersistedMetadata(
        _ values: [DomainAgentSessionDurableMetadata],
        now: Date
    ) -> [DomainAgentSessionDurableMetadata] {
        let cutoff = now.addingTimeInterval(-retainedInactiveAge)
        return values.filter {
            !(($0.state == .dormant || $0.state == .terminal) && $0.updatedAt < cutoff)
        }.sorted { lhs, rhs in
            let lhsPriority = lhs.state == .active || lhs.state == .interrupted ? 0 : 1
            let rhsPriority = rhs.state == .active || rhs.state == .interrupted ? 0 : 1
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return lhs.updatedAt > rhs.updatedAt
        }.prefix(retainedMetadataLimit).map { $0 }
    }

    private func persistMetadata() async {
        _ = await persistMetadataImmediately()
    }
}

#if DEBUG
    extension DomainAgentRunSessionStore {
        package func test_waiterCount(registration: Registration) -> Int {
            guard records[registration.sessionID]?.registration == registration else { return 0 }
            return records[registration.sessionID]?.waiters.count ?? 0
        }

        package func test_waiterIDs(registration: Registration) -> [UUID] {
            guard records[registration.sessionID]?.registration == registration else { return [] }
            return records[registration.sessionID]?.waiters.map(\.id) ?? []
        }

        package func test_cancelWaiter(sessionID: UUID, waiterID: UUID) {
            cancelWaiter(sessionID: sessionID, waiterID: waiterID)
        }

        package func test_shutdownOwnedState() -> (recordCount: Int, cancellationHandlerCount: Int) {
            (records.count, cancellationHandlers.count)
        }

        package func test_setShutdownAfterDetach(
            _ hook: (@Sendable () async -> Void)?
        ) {
            testShutdownAfterDetach = hook
        }

        package func test_expire(cursor: WaitCursor) {
            expire(cursor: cursor)
        }

        package func test_setMetadataFlushBeforeCAS(
            _ hook: (@Sendable () async -> Void)?
        ) {
            testMetadataFlushBeforeCAS = hook
        }

        package func test_setTerminalCommitID(_ commitID: UUID, cursor: WaitCursor) {
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
