import Foundation

actor AgentFreshTaskRoutingCoordinator {
    private struct Reservation {
        let ownershipID: UUID
        let backendID: AgentTaskRouterBackendID
        var task: Task<Void, Never>?
        var continuation: CheckedContinuation<AgentTaskRoutingBackendOutcome, Never>?
    }

    private let registry: AgentTaskRouterRegistry
    private var reservationsByRequestID: [UUID: Reservation] = [:]

    init(registry: AgentTaskRouterRegistry) {
        self.registry = registry
    }

    func route(
        backendID: AgentTaskRouterBackendID,
        request: AgentTaskRoutingRequest
    ) async -> AgentTaskRoutingBackendOutcome {
        guard reservationsByRequestID[request.requestID] == nil else {
            return .failed(category: .invalidRequest, retryable: false, evidence: nil)
        }
        let ownershipID = UUID()
        reservationsByRequestID[request.requestID] = Reservation(
            ownershipID: ownershipID,
            backendID: backendID,
            task: nil,
            continuation: nil
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                install(
                    continuation: continuation,
                    request: request,
                    backendID: backendID,
                    ownershipID: ownershipID
                )
            }
        } onCancel: {
            Task { await self.cancel(requestID: request.requestID, ownershipID: ownershipID) }
        }
    }

    func cancel(requestID: UUID) {
        guard let reservation = reservationsByRequestID.removeValue(forKey: requestID) else { return }
        reservation.task?.cancel()
        reservation.continuation?.resume(returning: .cancelled)
    }

    func cancelAll() {
        let reservations = reservationsByRequestID.values
        reservationsByRequestID.removeAll()
        for reservation in reservations {
            reservation.task?.cancel()
            reservation.continuation?.resume(returning: .cancelled)
        }
    }

    private func install(
        continuation: CheckedContinuation<AgentTaskRoutingBackendOutcome, Never>,
        request: AgentTaskRoutingRequest,
        backendID: AgentTaskRouterBackendID,
        ownershipID: UUID
    ) {
        guard owns(requestID: request.requestID, ownershipID: ownershipID) else {
            continuation.resume(returning: .cancelled)
            return
        }
        reservationsByRequestID[request.requestID]?.continuation = continuation
        let task = Task { [weak self] in
            guard let self else { return }
            await execute(request: request, backendID: backendID, ownershipID: ownershipID)
        }
        reservationsByRequestID[request.requestID]?.task = task
    }

    private func execute(
        request: AgentTaskRoutingRequest,
        backendID: AgentTaskRouterBackendID,
        ownershipID: UUID
    ) async {
        guard let registration = await registry.registration(for: backendID) else {
            finish(.failed(category: .invalidRequest, retryable: false, evidence: nil), requestID: request.requestID, ownershipID: ownershipID)
            return
        }
        guard owns(requestID: request.requestID, ownershipID: ownershipID), !Task.isCancelled else { return }
        let capturedReadiness = await registration.backend.readinessSnapshot()
        guard owns(requestID: request.requestID, ownershipID: ownershipID), !Task.isCancelled else { return }
        guard case .ready = capturedReadiness else {
            finish(.failed(category: .policyUnavailable, retryable: false, evidence: nil), requestID: request.requestID, ownershipID: ownershipID)
            return
        }
        let outcome = await registration.backend.route(request)
        guard owns(requestID: request.requestID, ownershipID: ownershipID), !Task.isCancelled else { return }
        let currentReadiness = await registration.backend.readinessSnapshot()
        guard owns(requestID: request.requestID, ownershipID: ownershipID), !Task.isCancelled else { return }
        guard currentReadiness == capturedReadiness,
              case let .ready(_, policyVersion) = capturedReadiness
        else {
            finish(.failed(category: .policyUnavailable, retryable: false, evidence: nil), requestID: request.requestID, ownershipID: ownershipID)
            return
        }
        finish(validate(outcome, request: request, policyVersion: policyVersion), requestID: request.requestID, ownershipID: ownershipID)
    }

    private func cancel(requestID: UUID, ownershipID: UUID) {
        guard owns(requestID: requestID, ownershipID: ownershipID),
              let reservation = reservationsByRequestID.removeValue(forKey: requestID)
        else { return }
        reservation.task?.cancel()
        reservation.continuation?.resume(returning: .cancelled)
    }

    private func finish(
        _ outcome: AgentTaskRoutingBackendOutcome,
        requestID: UUID,
        ownershipID: UUID
    ) {
        guard owns(requestID: requestID, ownershipID: ownershipID),
              let reservation = reservationsByRequestID.removeValue(forKey: requestID)
        else { return }
        reservation.continuation?.resume(returning: outcome)
    }

    private func owns(requestID: UUID, ownershipID: UUID) -> Bool {
        reservationsByRequestID[requestID]?.ownershipID == ownershipID
    }

    private func validate(
        _ outcome: AgentTaskRoutingBackendOutcome,
        request: AgentTaskRoutingRequest,
        policyVersion: String
    ) -> AgentTaskRoutingBackendOutcome {
        let evidence: AgentTaskRoutingDecisionEvidence?
        switch outcome {
        case let .selected(key, selectedEvidence):
            let keys = request.candidates.map(\.opaqueKey)
            guard keys.count(where: { $0 == key }) == 1 else {
                return .failed(category: .invalidResponse, retryable: false, evidence: nil)
            }
            evidence = selectedEvidence
        case let .abstained(_, abstainedEvidence):
            evidence = abstainedEvidence
        case let .failed(_, _, failedEvidence):
            evidence = failedEvidence
        case .cancelled:
            return outcome
        }
        guard validate(evidence: evidence, request: request, policyVersion: policyVersion) else {
            return .failed(category: .invalidResponse, retryable: false, evidence: nil)
        }
        return outcome
    }

    private func validate(
        evidence: AgentTaskRoutingDecisionEvidence?,
        request: AgentTaskRoutingRequest,
        policyVersion: String
    ) -> Bool {
        guard let evidence else { return true }
        let keys = request.candidates.map(\.opaqueKey)
        return (evidence.policyVersion.map { $0 == policyVersion } ?? true)
            && (evidence.scores?.allSatisfy {
                keys.contains($0.key) && $0.value.isFinite && (0 ... 1).contains($0.value)
            } ?? true)
            && (evidence.confidence.map { $0.isFinite && (0 ... 1).contains($0) } ?? true)
            && (evidence.inputTokens.map { $0 >= 0 } ?? true)
            && (evidence.outputTokens.map { $0 >= 0 } ?? true)
    }
}
