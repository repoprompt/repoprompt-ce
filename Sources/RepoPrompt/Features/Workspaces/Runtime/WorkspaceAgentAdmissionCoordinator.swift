import CryptoKit
import Foundation
import OSLog

enum AgentAdmissionRetainedRecoveryStart: Equatable {
    case automatic
    case blockedManual(WorkspacePersistenceFailureCategory)
}

enum AgentAdmissionRetainedRecoverySettlement: Equatable {
    case complete(AgentAdmissionRecoveryOutcome)
    case blockedManual(WorkspacePersistenceFailureCategory)
}

enum AgentAdmissionRetainedRecoveryState: Equatable {
    case running
    case blockedManual(WorkspacePersistenceFailureCategory)
}

/// Serializes Agent identity mutations that target the same durable workspace.
///
/// Domain workspace CAS remains authoritative across processes. This coordinator only closes
/// the in-process preparation gap shared by windows that present the same workspace.
final class WorkspaceAgentAdmissionCoordinator: @unchecked Sendable {
    struct Snapshot: Equatable {
        let activeAdmissionCount: Int
        let waiterCount: Int
        let trackedWorkspaceCount: Int
        let provisionalSessionCount: Int
        let retainedRecoveryCount: Int
    }

    struct Event: Equatable {
        enum Kind: String {
            case queued = "agentAdmission.queued"
            case acquired = "agentAdmission.acquired"
            case cancelledWhileQueued = "agentAdmission.cancelledWhileQueued"
            case released = "agentAdmission.released"
        }

        let kind: Kind
        let workspaceKey: String
        let correlationKey: String
        let queueDepth: Int
        let waitDurationMilliseconds: Double?
        let holdDurationMilliseconds: Double?
        let terminalCategory: String?
    }

    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var releaseAction: (() -> Void)?

        fileprivate init(releaseAction: @escaping () -> Void) {
            self.releaseAction = releaseAction
        }

        @discardableResult
        func release() -> Bool {
            let action: (() -> Void)? = lock.withLock {
                defer { releaseAction = nil }
                return releaseAction
            }
            action?()
            return action != nil
        }

        deinit {
            release()
        }
    }

    static let shared = WorkspaceAgentAdmissionCoordinator()

    private struct Holder {
        let admissionID: UUID
        let acquiredAtUptimeNanoseconds: UInt64
    }

    private struct Waiter {
        let admissionID: UUID
        let enqueuedAtUptimeNanoseconds: UInt64
        let continuation: CheckedContinuation<Lease, Error>
    }

    private struct WorkspaceState {
        var holder: Holder?
        var waiters: [Waiter] = []
    }

    private struct ProvisionalSessionKey: Hashable {
        let workspaceID: UUID
        let sessionID: UUID
    }

    private struct ProvisionalSessionReservation {
        var ownerIDs: Set<UUID>
    }

    private struct RetainedRecovery {
        var taskID: UUID?
        var task: Task<AgentAdmissionRetainedRecoverySettlement, Never>?
        var state: AgentAdmissionRetainedRecoveryState
        let reservationKey: ProvisionalSessionKey
        let reservationOwnerID: UUID
        let operation: @MainActor @Sendable () async -> AgentAdmissionRetainedRecoverySettlement
    }

    private enum AdmissionLocation: Equatable {
        case waiter(workspaceID: UUID)
        case holder(workspaceID: UUID)
    }

    private enum Registration {
        case immediate(Result<Lease, Error>, Event?)
        case queued(Event)
    }

    private struct Handoff {
        let continuation: CheckedContinuation<Lease, Error>
        let lease: Lease
        let event: Event
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "RepoPrompt",
        category: "WorkspaceAgentAdmission"
    )

    private let lock = NSLock()
    private var stateByWorkspaceID: [UUID: WorkspaceState] = [:]
    private var admissionLocationByAdmissionID: [UUID: AdmissionLocation] = [:]
    private var cancelledBeforeEnqueueAdmissionIDs: Set<UUID> = []
    private var provisionalSessionReservations: [ProvisionalSessionKey: ProvisionalSessionReservation] = [:]
    private var retainedRecoveries: [UUID: RetainedRecovery] = [:]

    #if DEBUG
        private var eventObserver: (@Sendable (Event) -> Void)?
        private var didResumeAfterHandoffHandler: (@Sendable (UUID, UUID) async -> Void)?

        func setEventObserverForTesting(_ observer: (@Sendable (Event) -> Void)?) {
            lock.withLock {
                eventObserver = observer
            }
        }

        func setDidResumeAfterHandoffHandlerForTesting(
            _ handler: (@Sendable (UUID, UUID) async -> Void)?
        ) {
            lock.withLock {
                didResumeAfterHandoffHandler = handler
            }
        }
    #endif

    func acquire(workspaceID: UUID, admissionID: UUID) async throws -> Lease {
        try Task.checkCancellation()

        let lease: Lease
        do {
            lease = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let registration: Registration = lock.withLock {
                        assert(
                            admissionLocationByAdmissionID[admissionID] == nil,
                            "Agent workspace admission IDs must not be reused while active."
                        )
                        if cancelledBeforeEnqueueAdmissionIDs.remove(admissionID) != nil || Task.isCancelled {
                            return .immediate(.failure(CancellationError()), nil)
                        }

                        let now = DispatchTime.now().uptimeNanoseconds
                        var state = stateByWorkspaceID[workspaceID] ?? WorkspaceState()
                        guard state.holder == nil, state.waiters.isEmpty else {
                            state.waiters.append(Waiter(
                                admissionID: admissionID,
                                enqueuedAtUptimeNanoseconds: now,
                                continuation: continuation
                            ))
                            stateByWorkspaceID[workspaceID] = state
                            admissionLocationByAdmissionID[admissionID] = .waiter(
                                workspaceID: workspaceID
                            )
                            return .queued(makeEvent(
                                kind: .queued,
                                workspaceID: workspaceID,
                                admissionID: admissionID,
                                queueDepth: state.waiters.count
                            ))
                        }

                        state.holder = Holder(
                            admissionID: admissionID,
                            acquiredAtUptimeNanoseconds: now
                        )
                        stateByWorkspaceID[workspaceID] = state
                        admissionLocationByAdmissionID[admissionID] = .holder(
                            workspaceID: workspaceID
                        )
                        return .immediate(
                            .success(makeLease(workspaceID: workspaceID, admissionID: admissionID)),
                            makeEvent(
                                kind: .acquired,
                                workspaceID: workspaceID,
                                admissionID: admissionID,
                                queueDepth: 0,
                                waitDurationMilliseconds: 0
                            )
                        )
                    }

                    switch registration {
                    case let .immediate(result, event):
                        if let event {
                            emit(event)
                        }
                        continuation.resume(with: result)
                    case let .queued(event):
                        emit(event)
                    }
                }
            } onCancel: {
                self.cancelWaiter(admissionID)
            }
        } catch {
            _ = lock.withLock { cancelledBeforeEnqueueAdmissionIDs.remove(admissionID) }
            throw error
        }

        #if DEBUG
            let handoffHandler = lock.withLock { didResumeAfterHandoffHandler }
            await handoffHandler?(workspaceID, admissionID)
        #endif
        do {
            try Task.checkCancellation()
            return lease
        } catch {
            _ = lock.withLock { cancelledBeforeEnqueueAdmissionIDs.remove(admissionID) }
            lease.release()
            throw error
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                activeAdmissionCount: stateByWorkspaceID.values.reduce(into: 0) { count, state in
                    if state.holder != nil {
                        count += 1
                    }
                },
                waiterCount: stateByWorkspaceID.values.reduce(0) { count, state in
                    count + state.waiters.count
                },
                trackedWorkspaceCount: stateByWorkspaceID.count,
                provisionalSessionCount: provisionalSessionReservations.count,
                retainedRecoveryCount: retainedRecoveries.count
            )
        }
    }

    /// A provider-visible session identity remains reserved from selector resolution through
    /// acceptance or terminal recovery, including publication into another window's projection.
    func reserveProvisionalSession(
        workspaceID: UUID,
        sessionID: UUID,
        ownerID: UUID
    ) -> Bool {
        lock.withLock {
            let key = ProvisionalSessionKey(workspaceID: workspaceID, sessionID: sessionID)
            if let reservation = provisionalSessionReservations[key] {
                return reservation.ownerIDs.contains(ownerID)
            }
            provisionalSessionReservations[key] = ProvisionalSessionReservation(ownerIDs: [ownerID])
            return true
        }
    }

    func releaseProvisionalSession(
        workspaceID: UUID,
        sessionID: UUID,
        ownerID: UUID
    ) {
        lock.withLock {
            let key = ProvisionalSessionKey(workspaceID: workspaceID, sessionID: sessionID)
            guard var reservation = provisionalSessionReservations[key],
                  reservation.ownerIDs.remove(ownerID) != nil
            else { return }
            if reservation.ownerIDs.isEmpty {
                provisionalSessionReservations.removeValue(forKey: key)
            } else {
                provisionalSessionReservations[key] = reservation
            }
        }
    }

    func hasActiveProvisionalSession(
        workspaceID: UUID,
        sessionID: UUID
    ) -> Bool {
        lock.withLock {
            provisionalSessionReservations[
                ProvisionalSessionKey(workspaceID: workspaceID, sessionID: sessionID)
            ] != nil
        }
    }

    /// Retaining the task outside a window-owned view model lets durable cleanup outlive the
    /// cancelled request that created it. A blocked record keeps the same settlement operation and
    /// reservation for one later bounded retry; it never retains a workspace admission lease.
    func retainRecovery(
        recoveryID: UUID,
        workspaceID: UUID,
        sessionID: UUID,
        reservationOwnerID: UUID,
        start: AgentAdmissionRetainedRecoveryStart = .automatic,
        operation: @escaping @MainActor @Sendable () async -> AgentAdmissionRetainedRecoverySettlement
    ) {
        lock.withLock {
            guard retainedRecoveries[recoveryID] == nil else { return }
            let reservationKey = ProvisionalSessionKey(
                workspaceID: workspaceID,
                sessionID: sessionID
            )
            var reservation = provisionalSessionReservations[reservationKey]
                ?? ProvisionalSessionReservation(ownerIDs: [])
            reservation.ownerIDs.insert(reservationOwnerID)
            provisionalSessionReservations[reservationKey] = reservation

            switch start {
            case .automatic:
                let taskID = UUID()
                let task = makeRetainedRecoveryTask(
                    recoveryID: recoveryID,
                    taskID: taskID,
                    operation: operation
                )
                retainedRecoveries[recoveryID] = RetainedRecovery(
                    taskID: taskID,
                    task: task,
                    state: .running,
                    reservationKey: reservationKey,
                    reservationOwnerID: reservationOwnerID,
                    operation: operation
                )
            case let .blockedManual(category):
                retainedRecoveries[recoveryID] = RetainedRecovery(
                    taskID: nil,
                    task: nil,
                    state: .blockedManual(category),
                    reservationKey: reservationKey,
                    reservationOwnerID: reservationOwnerID,
                    operation: operation
                )
            }
        }
    }

    /// Runs the retained settlement operation again as one coalesced, bounded batch.
    func retryRetainedRecovery(
        recoveryID: UUID
    ) async -> AgentAdmissionRetainedRecoverySettlement? {
        let task: Task<AgentAdmissionRetainedRecoverySettlement, Never>? = lock.withLock {
            guard var recovery = retainedRecoveries[recoveryID] else { return nil }
            switch recovery.state {
            case .running:
                return recovery.task
            case .blockedManual:
                let taskID = UUID()
                let task = makeRetainedRecoveryTask(
                    recoveryID: recoveryID,
                    taskID: taskID,
                    operation: recovery.operation
                )
                recovery.taskID = taskID
                recovery.task = task
                recovery.state = .running
                retainedRecoveries[recoveryID] = recovery
                return task
            }
        }
        guard let task else { return nil }
        return await task.value
    }

    func retainedRecoveryState(
        recoveryID: UUID
    ) -> AgentAdmissionRetainedRecoveryState? {
        lock.withLock { retainedRecoveries[recoveryID]?.state }
    }

    func retainedRecoveryIDs(for workspaceID: UUID) -> [UUID] {
        lock.withLock {
            retainedRecoveries.compactMap { recoveryID, recovery in
                recovery.reservationKey.workspaceID == workspaceID ? recoveryID : nil
            }
        }
    }

    private func makeRetainedRecoveryTask(
        recoveryID: UUID,
        taskID: UUID,
        operation: @escaping @MainActor @Sendable () async -> AgentAdmissionRetainedRecoverySettlement
    ) -> Task<AgentAdmissionRetainedRecoverySettlement, Never> {
        Task { @MainActor [weak self] in
            let settlement = await operation()
            self?.finishRetainedRecovery(
                recoveryID: recoveryID,
                taskID: taskID,
                settlement: settlement
            )
            return settlement
        }
    }

    private func finishRetainedRecovery(
        recoveryID: UUID,
        taskID: UUID,
        settlement: AgentAdmissionRetainedRecoverySettlement
    ) {
        lock.withLock {
            guard var recovery = retainedRecoveries[recoveryID],
                  recovery.taskID == taskID
            else { return }
            switch settlement {
            case .complete:
                retainedRecoveries.removeValue(forKey: recoveryID)
                guard var reservation = provisionalSessionReservations[recovery.reservationKey],
                      reservation.ownerIDs.remove(recovery.reservationOwnerID) != nil
                else { return }
                if reservation.ownerIDs.isEmpty {
                    provisionalSessionReservations.removeValue(forKey: recovery.reservationKey)
                } else {
                    provisionalSessionReservations[recovery.reservationKey] = reservation
                }
            case let .blockedManual(category):
                recovery.taskID = nil
                recovery.task = nil
                recovery.state = .blockedManual(category)
                retainedRecoveries[recoveryID] = recovery
            }
        }
    }

    func activeCount(for workspaceID: UUID) -> Int {
        lock.withLock { stateByWorkspaceID[workspaceID]?.holder == nil ? 0 : 1 }
    }

    func waiterCount(for workspaceID: UUID) -> Int {
        lock.withLock { stateByWorkspaceID[workspaceID]?.waiters.count ?? 0 }
    }

    static func redactedID(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        let digest = SHA256.hash(data: Data(id.uuidString.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private func makeLease(workspaceID: UUID, admissionID: UUID) -> Lease {
        Lease { [weak self] in
            self?.release(workspaceID: workspaceID, admissionID: admissionID)
        }
    }

    private func release(workspaceID: UUID, admissionID: UUID) {
        let releaseResult: (Event?, Handoff?) = lock.withLock {
            guard var state = stateByWorkspaceID[workspaceID],
                  let holder = state.holder,
                  holder.admissionID == admissionID
            else {
                return (nil, nil)
            }

            let releasedLocation = admissionLocationByAdmissionID.removeValue(
                forKey: admissionID
            )
            assert(
                releasedLocation == .holder(workspaceID: workspaceID),
                "The authoritative workspace holder must have a matching admission registry entry."
            )
            let now = DispatchTime.now().uptimeNanoseconds
            let released = makeEvent(
                kind: .released,
                workspaceID: workspaceID,
                admissionID: admissionID,
                queueDepth: state.waiters.count,
                holdDurationMilliseconds: Self.elapsedMilliseconds(
                    from: holder.acquiredAtUptimeNanoseconds,
                    to: now
                ),
                terminalCategory: "released"
            )

            guard !state.waiters.isEmpty else {
                stateByWorkspaceID.removeValue(forKey: workspaceID)
                return (released, nil)
            }

            let next = state.waiters.removeFirst()
            let queuedLocation = admissionLocationByAdmissionID[next.admissionID]
            assert(
                queuedLocation == .waiter(workspaceID: workspaceID),
                "A FIFO waiter must have a matching admission registry entry before handoff."
            )
            admissionLocationByAdmissionID[next.admissionID] = .holder(
                workspaceID: workspaceID
            )
            state.holder = Holder(
                admissionID: next.admissionID,
                acquiredAtUptimeNanoseconds: now
            )
            stateByWorkspaceID[workspaceID] = state
            let handoff = Handoff(
                continuation: next.continuation,
                lease: makeLease(workspaceID: workspaceID, admissionID: next.admissionID),
                event: makeEvent(
                    kind: .acquired,
                    workspaceID: workspaceID,
                    admissionID: next.admissionID,
                    queueDepth: state.waiters.count,
                    waitDurationMilliseconds: Self.elapsedMilliseconds(
                        from: next.enqueuedAtUptimeNanoseconds,
                        to: now
                    )
                )
            )
            return (released, handoff)
        }

        if let released = releaseResult.0 {
            emit(released)
        }
        if let handoff = releaseResult.1 {
            // Emit before resumption so DEBUG tests can deterministically exercise cancellation
            // at the waiter-to-holder boundary.
            emit(handoff.event)
            handoff.continuation.resume(returning: handoff.lease)
        }
    }

    private func cancelWaiter(_ admissionID: UUID) {
        let cancellation: (CheckedContinuation<Lease, Error>?, Event?) = lock.withLock {
            switch admissionLocationByAdmissionID[admissionID] {
            case let .waiter(workspaceID):
                guard var state = stateByWorkspaceID[workspaceID],
                      let index = state.waiters.firstIndex(where: { $0.admissionID == admissionID })
                else {
                    assertionFailure(
                        "A registered waiter must have a matching FIFO workspace record."
                    )
                    return (nil, nil)
                }

                admissionLocationByAdmissionID.removeValue(forKey: admissionID)
                let waiter = state.waiters.remove(at: index)
                if state.holder == nil, state.waiters.isEmpty {
                    stateByWorkspaceID.removeValue(forKey: workspaceID)
                } else {
                    stateByWorkspaceID[workspaceID] = state
                }
                return (
                    waiter.continuation,
                    makeEvent(
                        kind: .cancelledWhileQueued,
                        workspaceID: workspaceID,
                        admissionID: admissionID,
                        queueDepth: state.waiters.count,
                        waitDurationMilliseconds: Self.elapsedMilliseconds(
                            from: waiter.enqueuedAtUptimeNanoseconds,
                            to: DispatchTime.now().uptimeNanoseconds
                        ),
                        terminalCategory: "cancelled"
                    )
                )
            case .holder:
                return (nil, nil)
            case nil:
                cancelledBeforeEnqueueAdmissionIDs.insert(admissionID)
                return (nil, nil)
            }
        }

        if let event = cancellation.1 {
            emit(event)
        }
        cancellation.0?.resume(throwing: CancellationError())
    }

    private func makeEvent(
        kind: Event.Kind,
        workspaceID: UUID,
        admissionID: UUID,
        queueDepth: Int,
        waitDurationMilliseconds: Double? = nil,
        holdDurationMilliseconds: Double? = nil,
        terminalCategory: String? = nil
    ) -> Event {
        Event(
            kind: kind,
            workspaceKey: Self.redactedID(workspaceID),
            correlationKey: Self.redactedID(admissionID),
            queueDepth: queueDepth,
            waitDurationMilliseconds: waitDurationMilliseconds,
            holdDurationMilliseconds: holdDurationMilliseconds,
            terminalCategory: terminalCategory
        )
    }

    private func emit(_ event: Event) {
        let waitDuration = event.waitDurationMilliseconds.map { String(format: "%.3f", $0) } ?? "nil"
        let holdDuration = event.holdDurationMilliseconds.map { String(format: "%.3f", $0) } ?? "nil"
        let terminal = event.terminalCategory ?? "none"
        Self.logger.notice(
            "event=\(event.kind.rawValue, privacy: .public) workspace=\(event.workspaceKey, privacy: .public) correlation=\(event.correlationKey, privacy: .public) queueDepth=\(event.queueDepth, privacy: .public) waitMS=\(waitDuration, privacy: .public) holdMS=\(holdDuration, privacy: .public) terminal=\(terminal, privacy: .public)"
        )
        #if DEBUG
            let observer = lock.withLock { eventObserver }
            observer?(event)
        #endif
    }

    private static func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end >= start ? end - start : 0) / 1_000_000
    }
}
