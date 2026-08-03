import Foundation

package enum DomainReadSideEffectError: Error, Equatable, Sendable {
    case runtimeMismatch
    case operationCollision
    case receiptUnavailable
    case stopped
}

/// Independent ordering domains for read-derived effects. Selection publication must not be
/// head-of-line blocked by Git artifact work (or vice versa), while effects in one class and
/// context retain strict revision order.
package enum DomainReadSideEffectClass: String, Hashable, Sendable {
    case selection
    case gitArtifacts
}

package struct DomainReadSideEffectReceipt: Equatable, Sendable {
    package let operationID: UUID
    package let context: DomainContextIdentity
    package let effectClass: DomainReadSideEffectClass
    package let revision: UInt64

    package init(
        operationID: UUID,
        context: DomainContextIdentity,
        effectClass: DomainReadSideEffectClass,
        revision: UInt64
    ) {
        self.operationID = operationID
        self.context = context
        self.effectClass = effectClass
        self.revision = revision
    }
}

/// Context- and effect-class-keyed revision authority for read-derived effects.
///
/// Accepted operations are strictly ordered within a lane. A terminal failure is observable by
/// the submitting caller but is not inherited by later operations or future high-water drains.
package actor DomainReadSideEffectCoordinator {
    private struct LaneKey: Hashable, Sendable {
        let context: DomainContextIdentity
        let effectClass: DomainReadSideEffectClass
    }

    private struct RecordedOperation: Sendable {
        let fingerprint: String
        let receipt: DomainReadSideEffectReceipt
    }

    private struct LaneState: Sendable {
        var acceptedRevision: UInt64 = 0
        var terminalRevision: UInt64 = 0
        var tasks: [UInt64: Task<Void, Error>] = [:]
        var operations: [UUID: RecordedOperation] = [:]
        var expiredOperationIDs: [UUID] = []
    }

    private let identity: DomainRuntimeIdentity
    private var states: [LaneKey: LaneState] = [:]
    private var stopped = false

    package init(identity: DomainRuntimeIdentity) {
        self.identity = identity
    }

    package func highWaterRevision(
        for handle: DomainReadContextHandle,
        effectClass: DomainReadSideEffectClass
    ) throws -> UInt64 {
        try validate(handle)
        return states[LaneKey(context: handle.context, effectClass: effectClass)]?.acceptedRevision ?? 0
    }

    package func submit(
        handle: DomainReadContextHandle,
        effectClass: DomainReadSideEffectClass,
        operationID: UUID,
        fingerprint: String,
        operation: @Sendable @escaping () async throws -> Void
    ) throws -> DomainReadSideEffectReceipt {
        try validate(handle)
        guard !stopped else { throw DomainReadSideEffectError.stopped }
        let key = LaneKey(context: handle.context, effectClass: effectClass)
        var state = states[key] ?? LaneState()
        if let recorded = state.operations[operationID] {
            guard recorded.fingerprint == fingerprint else {
                throw DomainReadSideEffectError.operationCollision
            }
            return recorded.receipt
        }
        guard !state.expiredOperationIDs.contains(operationID) else {
            throw DomainReadSideEffectError.receiptUnavailable
        }

        let revision = state.acceptedRevision &+ 1
        let previous = state.tasks[state.acceptedRevision]
        let task = Task {
            // A previous terminal error belongs to its submitter. It must never poison this lane.
            if let previous { _ = await previous.result }
            try Task.checkCancellation()
            try await operation()
        }
        let receipt = DomainReadSideEffectReceipt(
            operationID: operationID,
            context: handle.context,
            effectClass: effectClass,
            revision: revision
        )
        state.acceptedRevision = revision
        state.tasks[revision] = task
        state.operations[operationID] = RecordedOperation(
            fingerprint: fingerprint,
            receipt: receipt
        )
        states[key] = state

        Task { [weak self] in
            _ = await task.result
            await self?.markTerminal(key: key, revision: revision)
        }
        return receipt
    }

    /// Waits for the exact submitted operation and preserves its success/failure/cancellation.
    /// Cancellation of the waiter does not cancel the coordinator-owned shared effect.
    package func wait(
        handle: DomainReadContextHandle,
        receipt: DomainReadSideEffectReceipt
    ) async throws {
        try validate(handle)
        let key = LaneKey(context: handle.context, effectClass: receipt.effectClass)
        guard receipt.context == handle.context,
              let state = states[key],
              state.operations[receipt.operationID]?.receipt == receipt,
              let task = state.tasks[receipt.revision]
        else { throw DomainReadSideEffectError.receiptUnavailable }
        try await awaitCompletion(of: task, cancelUnderlyingOnCancellation: false)
    }

    /// Waits until the lane has reached a revision. Historical effect failures are terminal and
    /// intentionally do not fail an unrelated later read; cancellation of this request still does.
    package func drain(
        handle: DomainReadContextHandle,
        effectClass: DomainReadSideEffectClass,
        through revision: UInt64
    ) async throws {
        try validate(handle)
        try Task.checkCancellation()
        guard revision > 0 else { return }
        let key = LaneKey(context: handle.context, effectClass: effectClass)
        guard let state = states[key] else { return }
        if state.terminalRevision >= revision { return }
        guard let task = state.tasks[revision] else {
            throw DomainReadSideEffectError.receiptUnavailable
        }
        // A drain observes ordering, not the earlier submitter's failure. It must still be promptly
        // cancellable without canceling shared work owned by another request.
        do {
            try await awaitCompletion(of: task, cancelUnderlyingOnCancellation: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Earlier terminal failures belong only to their exact submitters.
        }
        try Task.checkCancellation()
    }

    package func shutdown() {
        stopped = true
        for state in states.values {
            for task in state.tasks.values { task.cancel() }
        }
    }

    private func awaitCompletion(
        of task: Task<Void, Error>,
        cancelUnderlyingOnCancellation: Bool
    ) async throws {
        let stream = AsyncThrowingStream<Void, Error> { continuation in
            let observer = Task {
                switch await task.result {
                case .success:
                    continuation.finish()
                case let .failure(error):
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                observer.cancel()
                if cancelUnderlyingOnCancellation,
                   case .cancelled = termination
                {
                    task.cancel()
                }
            }
        }
        for try await _ in stream {}
        try Task.checkCancellation()
    }

    private func validate(_ handle: DomainReadContextHandle) throws {
        guard handle.runtimeID == identity.runtimeID,
              handle.runtimeGeneration == identity.lifecycleGeneration
        else {
            throw DomainReadSideEffectError.runtimeMismatch
        }
    }

    private func markTerminal(key: LaneKey, revision: UInt64) {
        guard var state = states[key] else { return }
        state.terminalRevision = max(state.terminalRevision, revision)
        if state.terminalRevision > 32 {
            let floor = state.terminalRevision - 32
            state.tasks = state.tasks.filter { $0.key >= floor }
            let expired = state.operations.filter { $0.value.receipt.revision < floor }.map(\.key)
            state.operations = state.operations.filter { $0.value.receipt.revision >= floor }
            state.expiredOperationIDs.append(contentsOf: expired)
            if state.expiredOperationIDs.count > 32 {
                state.expiredOperationIDs.removeFirst(state.expiredOperationIDs.count - 32)
            }
        }
        states[key] = state
    }
}
