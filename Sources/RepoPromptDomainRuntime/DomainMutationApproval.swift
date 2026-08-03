import Foundation

package enum DomainMutationApprovalRisk: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
}

package struct DomainMutationApprovalRequest: Hashable, Identifiable, Sendable {
    package let id: UUID
    package let principalSummary: String
    package let toolName: String
    package let action: String
    package let risk: DomainMutationApprovalRisk
    package let summary: String
    package let windowID: Int?
    package let deadline: Date

    package init(
        id: UUID = UUID(),
        principalSummary: String,
        toolName: String,
        action: String,
        risk: DomainMutationApprovalRisk,
        summary: String,
        windowID: Int?,
        deadline: Date
    ) {
        self.id = id
        self.principalSummary = principalSummary
        self.toolName = toolName
        self.action = action
        self.risk = risk
        self.summary = summary
        self.windowID = windowID
        self.deadline = deadline
    }
}

package enum DomainMutationApprovalResult: Hashable, Sendable {
    case approved(alwaysAllow: Bool)
    case denied
    case timeout
    case cancelled
    case presenterUnavailable
}

package struct DomainMutationApprovalPresenter: Sendable {
    package let present: @Sendable (DomainMutationApprovalRequest) async -> Bool
    package let dismiss: @Sendable (UUID) async -> Void

    package init(
        present: @Sendable @escaping (DomainMutationApprovalRequest) async -> Bool,
        dismiss: @Sendable @escaping (UUID) async -> Void
    ) {
        self.present = present
        self.dismiss = dismiss
    }
}

package struct DomainMutationApprovalBrokerSnapshot: Sendable {
    package let activeRequestID: UUID?
    package let queuedRequestIDs: [UUID]
    package let presenterGeneration: UInt64
}

package actor DomainMutationApprovalBroker {
    private struct Pending {
        let request: DomainMutationApprovalRequest
        let continuation: CheckedContinuation<DomainMutationApprovalResult, Never>
    }

    private var presenter: DomainMutationApprovalPresenter?
    private var presenterGeneration: UInt64 = 0
    private var active: Pending?
    private var queue: [Pending] = []
    private let waitForDeadline: @Sendable (Date) async throws -> Void
    private var timeoutTask: Task<Void, Never>?
    private var isShuttingDown = false

    package init(
        waitForDeadline: @escaping @Sendable (Date) async throws -> Void = { deadline in
            let delay = max(0, deadline.timeIntervalSinceNow)
            try await Task.sleep(for: .seconds(delay))
        }
    ) {
        self.waitForDeadline = waitForDeadline
    }

    package func registerPresenter(_ presenter: DomainMutationApprovalPresenter) {
        guard !isShuttingDown else { return }
        self.presenter = presenter
        presenterGeneration &+= 1
        if active == nil, !queue.isEmpty {
            Task { await self.activateNextIfNeeded() }
        }
    }

    package func unregisterPresenter() async {
        presenter = nil
        presenterGeneration &+= 1
        let ids = queue.map(\.request.id) + [active?.request.id].compactMap { $0 }
        for id in ids {
            await finish(id: id, result: .presenterUnavailable)
        }
    }

    package func request(_ request: DomainMutationApprovalRequest) async -> DomainMutationApprovalResult {
        if isShuttingDown || Task.isCancelled {
            return .cancelled
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || isShuttingDown {
                    continuation.resume(returning: .cancelled)
                    return
                }
                queue.append(Pending(request: request, continuation: continuation))
                Task { await self.activateNextIfNeeded() }
            }
        } onCancel: {
            Task { await self.cancel(requestID: request.id) }
        }
    }

    package func resolve(
        requestID: UUID,
        approved: Bool,
        alwaysAllow: Bool = false
    ) async {
        guard active?.request.id == requestID else { return }
        await finish(
            id: requestID,
            result: approved ? .approved(alwaysAllow: alwaysAllow) : .denied
        )
    }

    package func cancel(requestID: UUID) async {
        await finish(id: requestID, result: .cancelled)
    }

    package func cancel(requestIDs: Set<UUID>) async {
        for id in requestIDs {
            await finish(id: id, result: .cancelled)
        }
    }

    package func cancel(windowID: Int) async {
        let ids = queue.compactMap { $0.request.windowID == windowID ? $0.request.id : nil }
            + [active?.request].compactMap { $0?.windowID == windowID ? $0?.id : nil }
        for id in ids {
            await finish(id: id, result: .cancelled)
        }
    }

    package func shutdown() async {
        isShuttingDown = true
        timeoutTask?.cancel()
        timeoutTask = nil
        let ids = queue.map(\.request.id) + [active?.request.id].compactMap { $0 }
        for id in ids {
            await finish(id: id, result: .cancelled, activateNext: false)
        }
        presenter = nil
        presenterGeneration &+= 1
    }

    package func snapshot() -> DomainMutationApprovalBrokerSnapshot {
        DomainMutationApprovalBrokerSnapshot(
            activeRequestID: active?.request.id,
            queuedRequestIDs: queue.map(\.request.id),
            presenterGeneration: presenterGeneration
        )
    }

    private func activateNextIfNeeded() async {
        guard !isShuttingDown, active == nil, !queue.isEmpty else { return }
        let pending = queue.removeFirst()
        active = pending
        guard let presenter else {
            await finish(id: pending.request.id, result: .presenterUnavailable)
            return
        }
        let generation = presenterGeneration
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self, waitForDeadline] in
            do {
                try await waitForDeadline(pending.request.deadline)
            } catch {
                return
            }
            await self?.timeout(requestID: pending.request.id)
        }
        let accepted = await presenter.present(pending.request)
        guard active?.request.id == pending.request.id,
              presenterGeneration == generation
        else {
            return
        }
        guard accepted else {
            await finish(id: pending.request.id, result: .presenterUnavailable)
            return
        }
    }

    private func timeout(requestID: UUID) async {
        guard active?.request.id == requestID else { return }
        await finish(id: requestID, result: .timeout)
    }

    private func finish(
        id: UUID,
        result: DomainMutationApprovalResult,
        activateNext: Bool = true
    ) async {
        if active?.request.id == id, let pending = active {
            active = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            await presenter?.dismiss(id)
            pending.continuation.resume(returning: result)
            if activateNext {
                await activateNextIfNeeded()
            }
            return
        }
        guard let index = queue.firstIndex(where: { $0.request.id == id }) else { return }
        let pending = queue.remove(at: index)
        pending.continuation.resume(returning: result)
    }
}
