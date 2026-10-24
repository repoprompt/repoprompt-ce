import Foundation

/// Captured redacted authority for one call; never carries a credential or an executable target.
struct DecisionInvocationContext: Equatable {
    let serviceID: DecisionServiceID
    let consumerID: DecisionConsumerID
    let requestID: UUID
    let readinessGeneration: UInt64
    let acceptancePolicyVersion: String
    let configurationContextID: String?
}

/// One finite-choice dispatch path for every registered decision consumer.
actor DecisionCoordinator {
    private struct Reservation {
        let ownershipID: UUID
        let consumerID: DecisionConsumerID
        let consumerRevision: UInt64?
        let settlement: DecisionSettlement
        var task: Task<Void, Never>?
    }

    private let registry: DecisionServiceRegistry
    private let beforeSettlement: (@Sendable (UUID, DecisionOutcome) -> Void)?
    private let validator = FiniteChoiceDecisionValidator()
    private var reservationsByRequestID: [UUID: Reservation] = [:]
    private var latestRevisionByConsumerID: [DecisionConsumerID: UInt64] = [:]

    init(
        registry: DecisionServiceRegistry,
        beforeSettlement: (@Sendable (UUID, DecisionOutcome) -> Void)? = nil
    ) {
        self.registry = registry
        self.beforeSettlement = beforeSettlement
    }

    func decide(
        serviceID: DecisionServiceID,
        request: FiniteChoiceDecisionRequest,
        consumerRevision: UInt64? = nil
    ) async -> DecisionOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard reservationsByRequestID[request.requestID] == nil else { return .invalidRequest }
        if let consumerRevision {
            let latest = latestRevisionByConsumerID[request.consumerID]
            guard latest.map({ consumerRevision >= $0 }) ?? true else { return .cancelled }
            advanceConsumerRevision(consumerID: request.consumerID, revision: consumerRevision)
        }
        let ownershipID = UUID()
        let settlement = DecisionSettlement()
        reservationsByRequestID[request.requestID] = Reservation(
            ownershipID: ownershipID,
            consumerID: request.consumerID,
            consumerRevision: consumerRevision,
            settlement: settlement,
            task: nil
        )
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard settlement.install(continuation) else {
                    cancel(requestID: request.requestID, ownershipID: ownershipID)
                    return
                }
                install(serviceID: serviceID, request: request, ownershipID: ownershipID)
            }
        } onCancel: {
            // The caller claims cancellation synchronously; actor-owned cleanup follows
            // when the suspended decide call resumes, without a competing queued task.
            settlement.settle(.cancelled)
        }
        if settlement.isCancelled {
            cancel(requestID: request.requestID, ownershipID: ownershipID)
        }
        return outcome
    }

    func advanceConsumerRevision(consumerID: DecisionConsumerID, revision: UInt64) {
        guard latestRevisionByConsumerID[consumerID].map({ revision > $0 }) ?? true else { return }
        latestRevisionByConsumerID[consumerID] = revision
        let staleRequestIDs = reservationsByRequestID.compactMap { id, reservation in
            reservation.consumerID == consumerID
                && reservation.consumerRevision.map { $0 < revision } == true ? id : nil
        }
        for id in staleRequestIDs {
            cancel(requestID: id)
        }
    }

    func cancel(requestID: UUID) {
        guard let reservation = reservationsByRequestID.removeValue(forKey: requestID) else { return }
        reservation.settlement.settle(.cancelled)
        reservation.task?.cancel()
    }

    func cancelAll(consumerID: DecisionConsumerID? = nil) {
        let requestIDs = reservationsByRequestID.compactMap { id, reservation in
            consumerID == nil || reservation.consumerID == consumerID ? id : nil
        }
        for id in requestIDs {
            cancel(requestID: id)
        }
    }

    private func install(
        serviceID: DecisionServiceID,
        request: FiniteChoiceDecisionRequest,
        ownershipID: UUID
    ) {
        guard let reservation = reservationsByRequestID[request.requestID],
              reservation.ownershipID == ownershipID
        else { return }
        guard !reservation.settlement.isCancelled else {
            cancel(requestID: request.requestID, ownershipID: ownershipID)
            return
        }
        let task = Task {
            await execute(serviceID: serviceID, request: request, ownershipID: ownershipID)
        }
        reservationsByRequestID[request.requestID]?.task = task
    }

    private func execute(
        serviceID: DecisionServiceID,
        request: FiniteChoiceDecisionRequest,
        ownershipID: UUID
    ) async {
        guard let registration = await registry.registration(for: serviceID) else {
            finish(.unavailable, requestID: request.requestID, ownershipID: ownershipID)
            return
        }
        guard isActive(requestID: request.requestID, ownershipID: ownershipID) else { return }
        do {
            try validator.validateRequest(request, capabilities: registration.capabilities)
        } catch {
            finish(.invalidRequest, requestID: request.requestID, ownershipID: ownershipID)
            return
        }
        let capturedReadiness = await registration.service.readinessSnapshot()
        guard isActive(requestID: request.requestID, ownershipID: ownershipID) else { return }
        guard case let .ready(generation, policyVersion) = capturedReadiness else {
            finish(.unavailable, requestID: request.requestID, ownershipID: ownershipID)
            return
        }
        let invocation = DecisionInvocationContext(
            serviceID: serviceID,
            consumerID: request.consumerID,
            requestID: request.requestID,
            readinessGeneration: generation,
            acceptancePolicyVersion: policyVersion,
            configurationContextID: registration.configuration?.credentialContext?.contextID
        )
        let outcome = await registration.service.decide(request)
        guard isActive(requestID: request.requestID, ownershipID: ownershipID) else { return }
        let currentReadiness = await registration.service.readinessSnapshot()
        guard isActive(requestID: request.requestID, ownershipID: ownershipID) else { return }
        guard currentReadiness == capturedReadiness else {
            finish(.unavailable, requestID: request.requestID, ownershipID: ownershipID)
            return
        }
        finish(
            validator.validateOutcome(outcome, request: request, acceptancePolicyVersion: invocation.acceptancePolicyVersion),
            requestID: request.requestID,
            ownershipID: ownershipID
        )
    }

    private func cancel(requestID: UUID, ownershipID: UUID) {
        guard owns(requestID: requestID, ownershipID: ownershipID) else { return }
        cancel(requestID: requestID)
    }

    private func finish(_ outcome: DecisionOutcome, requestID: UUID, ownershipID: UUID) {
        guard let reservation = reservationsByRequestID[requestID],
              reservation.ownershipID == ownershipID
        else { return }
        // A synchronous test seam can cancel the caller at this precise boundary.
        beforeSettlement?(requestID, outcome)
        reservationsByRequestID.removeValue(forKey: requestID)
        reservation.settlement.settle(outcome)
    }

    private func owns(requestID: UUID, ownershipID: UUID) -> Bool {
        reservationsByRequestID[requestID]?.ownershipID == ownershipID
    }

    private func isActive(requestID: UUID, ownershipID: UUID) -> Bool {
        guard let reservation = reservationsByRequestID[requestID],
              reservation.ownershipID == ownershipID
        else { return false }
        return !reservation.settlement.isCancelled && !Task.isCancelled
    }
}

/// The caller's cancellation handler is nonisolated. This one-shot gate makes its terminal
/// claim synchronous while the actor continues to own request IDs, workers, and cleanup.
private final class DecisionSettlement: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DecisionOutcome, Never>?
    private var terminal: DecisionOutcome?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .cancelled = terminal { return true }
        return false
    }

    /// Returns false when cancellation settled before the continuation was installed.
    func install(_ continuation: CheckedContinuation<DecisionOutcome, Never>) -> Bool {
        lock.lock()
        if let terminal {
            lock.unlock()
            continuation.resume(returning: terminal)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func settle(_ outcome: DecisionOutcome) {
        lock.lock()
        guard terminal == nil else {
            lock.unlock()
            return
        }
        terminal = outcome
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
    }
}
