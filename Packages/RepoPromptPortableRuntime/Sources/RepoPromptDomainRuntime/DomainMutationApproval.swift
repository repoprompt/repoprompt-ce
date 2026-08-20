import Foundation

public enum DomainMutationApprovalRisk: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
}

public struct DomainMutationApprovalRequest: Hashable, Identifiable, Sendable {
    public let id: UUID
    public let principalSummary: String
    public let toolName: String
    public let action: String
    public let risk: DomainMutationApprovalRisk
    public let summary: String
    public let windowID: Int?
    public let deadline: Date

    public init(
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

public enum DomainMutationApprovalResult: Hashable, Sendable {
    case approved(alwaysAllow: Bool)
    case denied
    case timeout
    case cancelled
    case presenterUnavailable
}

public struct DomainMutationApprovalPresenter: Sendable {
    public let present: @Sendable (DomainMutationApprovalRequest) async -> Bool
    public let dismiss: @Sendable (UUID) async -> Void

    public init(
        present: @Sendable @escaping (DomainMutationApprovalRequest) async -> Bool,
        dismiss: @Sendable @escaping (UUID) async -> Void
    ) {
        self.present = present
        self.dismiss = dismiss
    }
}

public struct DomainMutationApprovalBrokerSnapshot: Sendable {
    public let activeRequestID: UUID?
    public let queuedRequestIDs: [UUID]
    public let presenterGeneration: UInt64
}

public actor DomainMutationApprovalBroker {
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

    public init(
        waitForDeadline: @escaping @Sendable (Date) async throws -> Void = { deadline in
            let delay = max(0, deadline.timeIntervalSinceNow)
            try await Task.sleep(for: .seconds(delay))
        }
    ) {
        self.waitForDeadline = waitForDeadline
    }

    public func registerPresenter(_ presenter: DomainMutationApprovalPresenter) {
        guard !isShuttingDown else { return }
        self.presenter = presenter
        presenterGeneration &+= 1
        if active == nil, !queue.isEmpty {
            Task { await self.activateNextIfNeeded() }
        }
    }

    public func unregisterPresenter() async {
        presenter = nil
        presenterGeneration &+= 1
        let ids = queue.map(\.request.id) + [active?.request.id].compactMap { $0 }
        for id in ids {
            await finish(id: id, result: .presenterUnavailable)
        }
    }

    public func request(_ request: DomainMutationApprovalRequest) async -> DomainMutationApprovalResult {
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

    public func resolve(
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

    public func cancel(requestID: UUID) async {
        await finish(id: requestID, result: .cancelled)
    }

    public func cancel(requestIDs: Set<UUID>) async {
        for id in requestIDs {
            await finish(id: id, result: .cancelled)
        }
    }

    public func cancel(windowID: Int) async {
        let ids = queue.compactMap { $0.request.windowID == windowID ? $0.request.id : nil }
            + [active?.request].compactMap { $0?.windowID == windowID ? $0?.id : nil }
        for id in ids {
            await finish(id: id, result: .cancelled)
        }
    }

    public func shutdown() async {
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

    public func snapshot() -> DomainMutationApprovalBrokerSnapshot {
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
