import Foundation
import MCP

package enum DomainInteractionProviderKind: String, Sendable {
    case elicitation
    case appUI = "app_ui"
}

package struct DomainInteractionRequest: Hashable, Sendable {
    package let id: UUID
    package let toolName: String
    package let clientID: UUID?
    package let invocationID: UUID?
    package let runID: UUID?
    package let payload: [String: Value]
    package let deadline: Date

    package init(
        id: UUID = UUID(),
        toolName: String,
        clientID: UUID? = nil,
        invocationID: UUID? = nil,
        runID: UUID? = nil,
        payload: [String: Value],
        deadline: Date
    ) {
        self.id = id
        self.toolName = toolName
        self.clientID = clientID
        self.invocationID = invocationID
        self.runID = runID
        self.payload = payload
        self.deadline = deadline
    }
}

package struct DomainInteractionProvider: Sendable {
    package let kind: DomainInteractionProviderKind
    package let isAvailable: @Sendable (DomainInteractionRequest) async -> Bool
    package let present: @Sendable (DomainInteractionRequest) async throws -> Value
    package let cancel: @Sendable (UUID) async -> Void

    package init(
        kind: DomainInteractionProviderKind,
        isAvailable: @Sendable @escaping (DomainInteractionRequest) async -> Bool = { _ in true },
        present: @Sendable @escaping (DomainInteractionRequest) async throws -> Value,
        cancel: @Sendable @escaping (UUID) async -> Void = { _ in }
    ) {
        self.kind = kind
        self.isAvailable = isAvailable
        self.present = present
        self.cancel = cancel
    }
}

package enum DomainInteractionResult: Equatable, Sendable {
    case response(Value, provider: DomainInteractionProviderKind)
    case timedOut
    case cancelled
    case unavailable
    case failed(String)
}

package struct DomainInteractionBrokerSnapshot: Sendable {
    package let generation: UInt64
    package let pendingRequestIDs: [UUID]
    package let ignoredLateResponseCount: UInt64
}

package actor DomainInteractionBroker {
    private final class ProviderDeadlineArbiter: @unchecked Sendable {
        struct ProviderResolution: Sendable {
            let result: DomainInteractionResult
            let ignoredLateResponse: Bool
        }

        private let lock = NSLock()
        private var isResolved = false

        func claimProviderCompletion(
            at completedAt: Date,
            deadline: Date,
            result: DomainInteractionResult
        ) -> ProviderResolution? {
            lock.withLock {
                guard !isResolved else { return nil }
                isResolved = true
                if case .response = result, completedAt >= deadline {
                    return ProviderResolution(result: .timedOut, ignoredLateResponse: true)
                }
                return ProviderResolution(result: result, ignoredLateResponse: false)
            }
        }

        func claimTimeout() -> Bool {
            lock.withLock {
                guard !isResolved else { return false }
                isResolved = true
                return true
            }
        }

        func invalidate() {
            lock.withLock { isResolved = true }
        }
    }

    private struct Pending {
        let request: DomainInteractionRequest
        let generation: UInt64
        let provider: DomainInteractionProvider
        let arbiter: ProviderDeadlineArbiter
        let continuation: CheckedContinuation<DomainInteractionResult, Never>
        var providerTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    private var nextGeneration: UInt64 = 1
    private var pending: [UUID: Pending] = [:]
    private var ignoredLateResponseCount: UInt64 = 0
    private var isShuttingDown = false
    private var negotiatedElicitationProvider: DomainInteractionProvider?
    private var negotiatedElicitationProvidersByClient: [UUID: DomainInteractionProvider] = [:]

    package init() {}

    package func installNegotiatedElicitationProvider(
        _ provider: DomainInteractionProvider?,
        clientID: UUID? = nil
    ) {
        if let provider {
            guard provider.kind == .elicitation else { return }
        }
        if let clientID {
            negotiatedElicitationProvidersByClient[clientID] = provider
        } else {
            negotiatedElicitationProvider = provider
        }
    }

    package func request(
        _ request: DomainInteractionRequest,
        elicitation: DomainInteractionProvider? = nil,
        appUI: DomainInteractionProvider? = nil
    ) async -> DomainInteractionResult {
        guard !isShuttingDown, !Task.isCancelled else { return .cancelled }
        let provider: DomainInteractionProvider?
        let clientElicitation = request.clientID.flatMap {
            negotiatedElicitationProvidersByClient[$0]
        }
        let preferredElicitation = elicitation
            ?? clientElicitation
            ?? negotiatedElicitationProvider
        let selectedClientElicitation: Bool
        if let preferredElicitation, await preferredElicitation.isAvailable(request) {
            provider = preferredElicitation
            selectedClientElicitation = elicitation == nil && clientElicitation != nil
        } else if let appUI, await appUI.isAvailable(request) {
            provider = appUI
            selectedClientElicitation = false
        } else {
            provider = nil
            selectedClientElicitation = false
        }
        guard let provider else { return .unavailable }
        if selectedClientElicitation,
           let clientID = request.clientID,
           negotiatedElicitationProvidersByClient[clientID] == nil
        {
            return .cancelled
        }

        let generation = nextGeneration
        nextGeneration &+= 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !isShuttingDown else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                guard pending[request.id] == nil else {
                    continuation.resume(returning: .failed("duplicate interaction request id"))
                    return
                }
                let arbiter = ProviderDeadlineArbiter()
                pending[request.id] = Pending(
                    request: request,
                    generation: generation,
                    provider: provider,
                    arbiter: arbiter,
                    continuation: continuation
                )
                let providerTask = Task { [weak self] in
                    let result: DomainInteractionResult
                    do {
                        let value = try await provider.present(request)
                        result = .response(value, provider: provider.kind)
                    } catch is CancellationError {
                        result = .cancelled
                    } catch {
                        result = .failed(String(describing: error))
                    }
                    let resolution = arbiter.claimProviderCompletion(
                        at: Date(),
                        deadline: request.deadline,
                        result: result
                    )
                    guard let resolution else {
                        await self?.providerCompletionIgnored()
                        return
                    }
                    await self?.providerCompleted(
                        requestID: request.id,
                        generation: generation,
                        ignoredLateResponse: resolution.ignoredLateResponse,
                        result: resolution.result
                    )
                }
                let delay = max(0, request.deadline.timeIntervalSinceNow)
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        return
                    }
                    guard arbiter.claimTimeout() else { return }
                    await self?.timeout(requestID: request.id, generation: generation)
                }
                if var record = pending[request.id], record.generation == generation {
                    record.providerTask = providerTask
                    record.timeoutTask = timeoutTask
                    pending[request.id] = record
                } else {
                    providerTask.cancel()
                    timeoutTask.cancel()
                }
            }
        } onCancel: {
            Task { await self.cancel(requestID: request.id, generation: generation) }
        }
    }

    package func cancel(requestID: UUID) async {
        guard let record = pending[requestID] else { return }
        await finish(requestID: requestID, generation: record.generation, result: .cancelled)
    }

    package func cancel(clientID: UUID) async {
        negotiatedElicitationProvidersByClient.removeValue(forKey: clientID)
        let targets = pending.values
            .filter { $0.request.clientID == clientID }
            .map { (requestID: $0.request.id, generation: $0.generation) }
        for target in targets {
            await finish(
                requestID: target.requestID,
                generation: target.generation,
                result: .cancelled
            )
        }
    }

    package func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        negotiatedElicitationProvider = nil
        negotiatedElicitationProvidersByClient.removeAll()
        let records = pending.values
        pending.removeAll()
        for record in records {
            record.arbiter.invalidate()
            record.providerTask?.cancel()
            record.timeoutTask?.cancel()
            await record.provider.cancel(record.request.id)
            record.continuation.resume(returning: .cancelled)
        }
    }

    package func snapshot() -> DomainInteractionBrokerSnapshot {
        DomainInteractionBrokerSnapshot(
            generation: nextGeneration,
            pendingRequestIDs: pending.keys.sorted { $0.uuidString < $1.uuidString },
            ignoredLateResponseCount: ignoredLateResponseCount
        )
    }

    private func providerCompleted(
        requestID: UUID,
        generation: UInt64,
        ignoredLateResponse: Bool,
        result: DomainInteractionResult
    ) async {
        guard let record = pending[requestID], record.generation == generation else {
            ignoredLateResponseCount &+= 1
            return
        }
        if ignoredLateResponse {
            ignoredLateResponseCount &+= 1
        }
        await finish(requestID: requestID, generation: generation, result: result)
    }

    private func providerCompletionIgnored() {
        ignoredLateResponseCount &+= 1
    }

    private func timeout(requestID: UUID, generation: UInt64) async {
        await finish(requestID: requestID, generation: generation, result: .timedOut)
    }

    private func cancel(requestID: UUID, generation: UInt64) async {
        await finish(requestID: requestID, generation: generation, result: .cancelled)
    }

    private func finish(
        requestID: UUID,
        generation: UInt64,
        result: DomainInteractionResult
    ) async {
        guard let record = pending[requestID], record.generation == generation else {
            ignoredLateResponseCount &+= 1
            return
        }
        pending.removeValue(forKey: requestID)
        record.arbiter.invalidate()
        record.providerTask?.cancel()
        record.timeoutTask?.cancel()
        record.continuation.resume(returning: result)
        if result == .timedOut || result == .cancelled {
            let providerCancel = record.provider.cancel
            Task.detached(priority: .utility) {
                await providerCancel(requestID)
            }
        }
    }
}
