import Foundation

/// Marker for a private, lease-backed target evidence or seed-plan handle.
///
/// The coordinator deliberately has no knowledge of the artifact's records. A
/// producer must return a handle only after every source stream has reached its
/// verified footer and the attempt has been sealed to Git authority.
protocol WorkspaceRootTargetEvidenceHandle: Sendable {}

/// A flight-scoped resource whose release must happen exactly once after the
/// producer and every claim have stopped using it. Producers transfer
/// ownership immediately after acquisition so cancellation and thrown errors
/// cannot strand an authority fence or artifact lease.
protocol WorkspaceRootTargetEvidenceAttemptResource: Sendable {
    func release() async
}

struct WorkspaceRootTargetEvidenceFlightKey: Hashable {
    struct PhysicalWorktreeIdentity: Hashable {
        let canonicalRootPath: String
        let deviceID: UInt64
        let inode: UInt64
        let canonicalGitDirectoryPath: String
    }

    let physicalWorktree: PhysicalWorktreeIdentity
    let gitAuthorityRepositoryIdentity: Data
    let repositoryRelativeRootPrefix: Data
    let reusableSnapshotIdentity: Data
    let catalogPolicyIdentity: Data
    let creationCutIdentity: Data
    let namespaceAcquisitionIdentity: Data
    let inventorySchema: UInt32
    let searchSchema: UInt32
}

struct WorkspaceRootTargetEvidenceAttemptContext {
    let attemptID: UUID
    let attemptIndex: Int
    let requiredAuthoritySnapshotIdentity: Data?
    private let retainResourceAction: @Sendable (
        any WorkspaceRootTargetEvidenceAttemptResource
    ) async throws -> Void

    fileprivate init(
        attemptID: UUID,
        attemptIndex: Int,
        requiredAuthoritySnapshotIdentity: Data?,
        retainResourceAction: @escaping @Sendable (
            any WorkspaceRootTargetEvidenceAttemptResource
        ) async throws -> Void
    ) {
        self.attemptID = attemptID
        self.attemptIndex = attemptIndex
        self.requiredAuthoritySnapshotIdentity = requiredAuthoritySnapshotIdentity
        self.retainResourceAction = retainResourceAction
    }

    /// Transfers the attempt resource to the coordinator. If the flight was
    /// cancelled before transfer completes, the resource is released here.
    func retainResource(_ resource: any WorkspaceRootTargetEvidenceAttemptResource) async throws {
        do {
            try await retainResourceAction(resource)
        } catch {
            await resource.release()
            throw error
        }
    }
}

enum WorkspaceRootTargetEvidenceAttemptOutcome {
    case sealed(
        handle: any WorkspaceRootTargetEvidenceHandle,
        authoritySnapshotIdentity: Data
    )
    case authorityInvalidated(
        originalAuthoritySnapshotIdentity: Data,
        replacementAuthoritySnapshotIdentity: Data
    )
}

enum WorkspaceRootTargetEvidenceCoordinatorError: Error, Equatable {
    case waiterDeadlineExceeded
    case authoritySnapshotChanged
    case authorityUnstable
    case attemptResourceAlreadyRegistered
}

final class WorkspaceRootTargetEvidenceClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var retainedHandle: (any WorkspaceRootTargetEvidenceHandle)?
    private var releaseAction: (@Sendable () async -> Void)?

    fileprivate init(
        handle: any WorkspaceRootTargetEvidenceHandle,
        releaseAction: @escaping @Sendable () async -> Void
    ) {
        retainedHandle = handle
        self.releaseAction = releaseAction
    }

    /// Returns the shared private handle while this claim remains live.
    /// Consumers should not retain the returned handle beyond the claim.
    func handle<Handle: WorkspaceRootTargetEvidenceHandle>(as _: Handle.Type = Handle.self) -> Handle? {
        lock.lock()
        defer { lock.unlock() }
        return retainedHandle as? Handle
    }

    /// Releases this client's claim. This operation is idempotent.
    func release() async {
        let action = takeReleaseAction()
        await action?()
    }

    deinit {
        guard let action = takeReleaseAction() else { return }
        Task {
            await action()
        }
    }

    private func takeReleaseAction() -> (@Sendable () async -> Void)? {
        lock.lock()
        let action = releaseAction
        releaseAction = nil
        retainedHandle = nil
        lock.unlock()
        return action
    }
}

actor WorkspaceRootTargetEvidenceCoordinator {
    typealias Producer = @Sendable (
        WorkspaceRootTargetEvidenceFlightKey,
        WorkspaceRootTargetEvidenceAttemptContext
    ) async throws -> WorkspaceRootTargetEvidenceAttemptOutcome

    enum Event: Equatable {
        case flightStarted
        case waiterJoined(waiterCount: Int)
        case attemptStarted(index: Int)
        case authorityInvalidated(index: Int)
        case retryStarted
        case waiterDeadlineExceeded
        case waiterCancelled
        case lastWaiterCancelled
        case flightSealed(claimCount: Int)
        case claimReleased(remainingClaimCount: Int)
        case flightCleaned
    }

    struct DiagnosticsSnapshot: Equatable {
        let activeFlightCount: Int
        let flightsStarted: UInt64
        let joinedWaiterCount: UInt64
        let attemptsStarted: UInt64
        let retriesStarted: UInt64
        let waiterDeadlineCount: UInt64
        let waiterCancellationCount: UInt64
        let lastWaiterCancellationCount: UInt64
        let claimsIssued: UInt64
        let claimsReleased: UInt64
        let flightsCleaned: UInt64
    }

    static let shared = WorkspaceRootTargetEvidenceCoordinator()

    private struct Counters {
        var flightsStarted: UInt64 = 0
        var joinedWaiterCount: UInt64 = 0
        var attemptsStarted: UInt64 = 0
        var retriesStarted: UInt64 = 0
        var waiterDeadlineCount: UInt64 = 0
        var waiterCancellationCount: UInt64 = 0
        var lastWaiterCancellationCount: UInt64 = 0
        var claimsIssued: UInt64 = 0
        var claimsReleased: UInt64 = 0
        var flightsCleaned: UInt64 = 0
    }

    private struct Waiter {
        let continuation: CheckedContinuation<WorkspaceRootTargetEvidenceClaim, any Error>
        var deadlineTask: Task<Void, Never>?
    }

    private final class Flight {
        let id: UUID
        var producerTask: Task<Void, Never>?
        var waiters: [UUID: Waiter] = [:]
        var claimIDs = Set<UUID>()
        var retainedHandle: (any WorkspaceRootTargetEvidenceHandle)?
        var retainedAttemptResource: (any WorkspaceRootTargetEvidenceAttemptResource)?
        var activeAttemptID: UUID?

        init(id: UUID) {
            self.id = id
        }
    }

    private enum TerminalResult: @unchecked Sendable {
        case sealed(
            handle: any WorkspaceRootTargetEvidenceHandle,
            authoritySnapshotIdentity: Data
        )
        case failed(any Error)
    }

    private let eventSink: (@Sendable (Event) -> Void)?
    private var flights: [WorkspaceRootTargetEvidenceFlightKey: Flight] = [:]
    private var counters = Counters()

    init(eventSink: (@Sendable (Event) -> Void)? = nil) {
        self.eventSink = eventSink
    }

    /// Joins a compatible physical-worktree flight or starts one.
    ///
    /// The deadline belongs only to this waiter. It is never inherited by the
    /// shared producer or its Git subprocesses.
    func claim(
        for key: WorkspaceRootTargetEvidenceFlightKey,
        deadline: ContinuousClock.Instant? = nil,
        producer: @escaping Producer
    ) async throws -> WorkspaceRootTargetEvidenceClaim {
        let waiterID = UUID()
        let claim = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<WorkspaceRootTargetEvidenceClaim, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                registerWaiter(
                    waiterID,
                    key: key,
                    deadline: deadline,
                    producer: producer,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID, key: key)
            }
        }

        if Task.isCancelled {
            await claim.release()
            throw CancellationError()
        }
        return claim
    }

    func diagnosticsSnapshot() -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            activeFlightCount: flights.count,
            flightsStarted: counters.flightsStarted,
            joinedWaiterCount: counters.joinedWaiterCount,
            attemptsStarted: counters.attemptsStarted,
            retriesStarted: counters.retriesStarted,
            waiterDeadlineCount: counters.waiterDeadlineCount,
            waiterCancellationCount: counters.waiterCancellationCount,
            lastWaiterCancellationCount: counters.lastWaiterCancellationCount,
            claimsIssued: counters.claimsIssued,
            claimsReleased: counters.claimsReleased,
            flightsCleaned: counters.flightsCleaned
        )
    }

    private func registerWaiter(
        _ waiterID: UUID,
        key: WorkspaceRootTargetEvidenceFlightKey,
        deadline: ContinuousClock.Instant?,
        producer: @escaping Producer,
        continuation: CheckedContinuation<WorkspaceRootTargetEvidenceClaim, any Error>
    ) {
        if let deadline, deadline <= ContinuousClock.now {
            counters.waiterDeadlineCount &+= 1
            emit(.waiterDeadlineExceeded)
            continuation.resume(
                throwing: WorkspaceRootTargetEvidenceCoordinatorError.waiterDeadlineExceeded
            )
            return
        }

        let flight: Flight
        if let existing = flights[key] {
            flight = existing
            counters.joinedWaiterCount &+= 1
            emit(.waiterJoined(
                waiterCount: existing.waiters.count + existing.claimIDs.count + 1
            ))
            if let handle = existing.retainedHandle {
                let claim = makeClaim(handle: handle, key: key, flight: existing)
                continuation.resume(returning: claim)
                return
            }
        } else {
            let created = Flight(id: UUID())
            flights[key] = created
            flight = created
            counters.flightsStarted &+= 1
            emit(.flightStarted)
            created.producerTask = Task {
                let result = await self.runProducer(
                    key: key,
                    flightID: created.id,
                    producer: producer
                )
                await self.finishFlight(key: key, flightID: created.id, result: result)
            }
        }

        flight.waiters[waiterID] = Waiter(continuation: continuation, deadlineTask: nil)
        guard let deadline else { return }
        flight.waiters[waiterID]?.deadlineTask = Task {
            do {
                try await ContinuousClock().sleep(until: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self.expireWaiter(waiterID, key: key)
        }
    }

    private func retainAttemptResource(
        _ resource: any WorkspaceRootTargetEvidenceAttemptResource,
        key: WorkspaceRootTargetEvidenceFlightKey,
        flightID: UUID,
        attemptID: UUID
    ) throws {
        guard let flight = flights[key], flight.id == flightID else {
            throw CancellationError()
        }
        guard flight.retainedAttemptResource == nil, flight.activeAttemptID == nil else {
            throw WorkspaceRootTargetEvidenceCoordinatorError.attemptResourceAlreadyRegistered
        }
        flight.retainedAttemptResource = resource
        flight.activeAttemptID = attemptID
    }

    private func releaseAttemptResource(
        key: WorkspaceRootTargetEvidenceFlightKey,
        flightID: UUID,
        attemptID: UUID
    ) async {
        guard let flight = flights[key], flight.id == flightID,
              flight.activeAttemptID == attemptID
        else { return }
        let resource = takeAttemptResource(flight)
        await resource?.release()
    }

    private func takeAttemptResource(
        _ flight: Flight
    ) -> (any WorkspaceRootTargetEvidenceAttemptResource)? {
        let resource = flight.retainedAttemptResource
        flight.retainedAttemptResource = nil
        flight.activeAttemptID = nil
        return resource
    }

    private func runProducer(
        key: WorkspaceRootTargetEvidenceFlightKey,
        flightID: UUID,
        producer: @escaping Producer
    ) async -> TerminalResult {
        var requiredAuthoritySnapshotIdentity: Data?
        for attemptIndex in 0 ... 1 {
            counters.attemptsStarted &+= 1
            emit(.attemptStarted(index: attemptIndex))
            let attemptID = UUID()
            let context = WorkspaceRootTargetEvidenceAttemptContext(
                attemptID: attemptID,
                attemptIndex: attemptIndex,
                requiredAuthoritySnapshotIdentity: requiredAuthoritySnapshotIdentity
            ) { [weak self] resource in
                guard let self else { throw CancellationError() }
                try await retainAttemptResource(
                    resource,
                    key: key,
                    flightID: flightID,
                    attemptID: attemptID
                )
            }

            do {
                switch try await producer(key, context) {
                case let .sealed(handle, authoritySnapshotIdentity):
                    if let requiredAuthoritySnapshotIdentity,
                       authoritySnapshotIdentity != requiredAuthoritySnapshotIdentity
                    {
                        await releaseAttemptResource(
                            key: key,
                            flightID: flightID,
                            attemptID: attemptID
                        )
                        return .failed(WorkspaceRootTargetEvidenceCoordinatorError.authoritySnapshotChanged)
                    }
                    return .sealed(
                        handle: handle,
                        authoritySnapshotIdentity: authoritySnapshotIdentity
                    )

                case let .authorityInvalidated(original, replacement):
                    emit(.authorityInvalidated(index: attemptIndex))
                    guard original == replacement else {
                        await releaseAttemptResource(
                            key: key,
                            flightID: flightID,
                            attemptID: attemptID
                        )
                        return .failed(WorkspaceRootTargetEvidenceCoordinatorError.authoritySnapshotChanged)
                    }
                    guard attemptIndex == 0 else {
                        await releaseAttemptResource(
                            key: key,
                            flightID: flightID,
                            attemptID: attemptID
                        )
                        return .failed(WorkspaceRootTargetEvidenceCoordinatorError.authorityUnstable)
                    }
                    await releaseAttemptResource(
                        key: key,
                        flightID: flightID,
                        attemptID: attemptID
                    )
                    requiredAuthoritySnapshotIdentity = replacement
                    counters.retriesStarted &+= 1
                    emit(.retryStarted)
                }
            } catch {
                await releaseAttemptResource(
                    key: key,
                    flightID: flightID,
                    attemptID: attemptID
                )
                return .failed(error)
            }
        }
        return .failed(WorkspaceRootTargetEvidenceCoordinatorError.authorityUnstable)
    }

    private func finishFlight(
        key: WorkspaceRootTargetEvidenceFlightKey,
        flightID: UUID,
        result: TerminalResult
    ) async {
        guard let flight = flights[key], flight.id == flightID else { return }
        flight.producerTask = nil

        switch result {
        case let .sealed(handle, _):
            flight.retainedHandle = handle
            let waiters = flight.waiters
            flight.waiters.removeAll(keepingCapacity: false)
            for waiter in waiters.values {
                waiter.deadlineTask?.cancel()
                let claim = makeClaim(handle: handle, key: key, flight: flight)
                waiter.continuation.resume(returning: claim)
            }
            emit(.flightSealed(claimCount: flight.claimIDs.count))

        case let .failed(error):
            let waiters = flight.waiters.values
            flight.waiters.removeAll(keepingCapacity: false)
            flights.removeValue(forKey: key)
            let resource = takeAttemptResource(flight)
            await resource?.release()
            for waiter in waiters {
                waiter.deadlineTask?.cancel()
                waiter.continuation.resume(throwing: error)
            }
            markFlightCleaned()
        }
    }

    private func cancelWaiter(
        _ waiterID: UUID,
        key: WorkspaceRootTargetEvidenceFlightKey
    ) async {
        guard let flight = flights[key], let waiter = flight.waiters.removeValue(forKey: waiterID) else {
            return
        }
        waiter.deadlineTask?.cancel()
        counters.waiterCancellationCount &+= 1
        emit(.waiterCancelled)
        await cancelFlightIfUnclaimed(key: key, flight: flight)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func expireWaiter(
        _ waiterID: UUID,
        key: WorkspaceRootTargetEvidenceFlightKey
    ) async {
        guard let flight = flights[key], let waiter = flight.waiters.removeValue(forKey: waiterID) else {
            return
        }
        counters.waiterDeadlineCount &+= 1
        emit(.waiterDeadlineExceeded)
        await cancelFlightIfUnclaimed(key: key, flight: flight)
        waiter.continuation.resume(
            throwing: WorkspaceRootTargetEvidenceCoordinatorError.waiterDeadlineExceeded
        )
    }

    private func cancelFlightIfUnclaimed(
        key: WorkspaceRootTargetEvidenceFlightKey,
        flight: Flight
    ) async {
        guard flight.waiters.isEmpty, flight.claimIDs.isEmpty else { return }
        flights.removeValue(forKey: key)
        let producerTask = flight.producerTask
        flight.producerTask = nil
        producerTask?.cancel()
        await producerTask?.value
        flight.retainedHandle = nil
        let resource = takeAttemptResource(flight)
        await resource?.release()
        counters.lastWaiterCancellationCount &+= 1
        emit(.lastWaiterCancelled)
        markFlightCleaned()
    }

    private func releaseClaim(
        _ claimID: UUID,
        key: WorkspaceRootTargetEvidenceFlightKey,
        flightID: UUID
    ) async {
        guard let flight = flights[key], flight.id == flightID,
              flight.claimIDs.remove(claimID) != nil
        else {
            return
        }
        counters.claimsReleased &+= 1
        emit(.claimReleased(remainingClaimCount: flight.claimIDs.count))
        guard flight.claimIDs.isEmpty, flight.waiters.isEmpty else { return }
        flights.removeValue(forKey: key)
        flight.retainedHandle = nil
        let resource = takeAttemptResource(flight)
        await resource?.release()
        markFlightCleaned()
    }

    private func makeClaim(
        handle: any WorkspaceRootTargetEvidenceHandle,
        key: WorkspaceRootTargetEvidenceFlightKey,
        flight: Flight
    ) -> WorkspaceRootTargetEvidenceClaim {
        let claimID = UUID()
        let flightID = flight.id
        flight.claimIDs.insert(claimID)
        counters.claimsIssued &+= 1
        return WorkspaceRootTargetEvidenceClaim(handle: handle) { [weak self] in
            await self?.releaseClaim(claimID, key: key, flightID: flightID)
        }
    }

    private func markFlightCleaned() {
        counters.flightsCleaned &+= 1
        emit(.flightCleaned)
    }

    private func emit(_ event: Event) {
        eventSink?(event)
    }
}
