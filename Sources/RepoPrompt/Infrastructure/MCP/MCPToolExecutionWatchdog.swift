import Foundation

enum MCPToolExecutionSettlement: String, Equatable {
    case success
    case cancellation
    case error
}

enum MCPToolExecutionCancellationOrigin: String, Equatable {
    case watchdogDeadline = "watchdog_deadline"
    case requestCancellation = "request_cancellation"
}

struct MCPToolExecutionCancelledError: Error, Equatable, LocalizedError {
    var errorDescription: String? {
        "Tool execution was cancelled."
    }

    static func matches(_ error: Error) -> Bool {
        error is CancellationError || error is MCPToolExecutionCancelledError
    }
}

enum MCPToolExecutionWatchdogEvent: Equatable {
    case deadlineExpired
    case cancellationRequested(origin: MCPToolExecutionCancellationOrigin)
    case settledDuringGrace(MCPToolExecutionSettlement)
    case cleanupGraceExpired
    case detachedForSettlement
}

enum MCPToolExecutionWatchdogError: Error, Equatable {
    case executionTimedOut(settlement: MCPToolExecutionSettlement)
    case executionDetached
    case cleanupUnresponsive
}

struct MCPToolExecutionWatchdogEnvironment {
    let now: @Sendable () async -> Duration
    let sleep: @Sendable (Duration) async throws -> Void

    static func continuous() -> Self {
        let clock = ContinuousClock()
        let origin = clock.now
        return Self(
            now: { origin.duration(to: clock.now) },
            sleep: { duration in
                try await Task.sleep(for: duration)
            }
        )
    }
}

enum MCPToolExecutionWatchdog {
    private struct ResultBox<T>: @unchecked Sendable {
        let result: Result<T, Error>
    }

    private enum Event<T>: @unchecked Sendable {
        case operationCompleted(ResultBox<T>)
        case deadlineExpired
        case cleanupGraceExpired
    }

    private final class OperationState<T>: @unchecked Sendable {
        enum RecordAction {
            case deliver
            case deferred
            case settleDetached
            case settleAbandoned
        }

        enum DetachPreparation {
            case completed(ResultBox<T>)
            case ready
        }

        private enum Mode {
            case running
            case detaching
            case detached
            case abandoned
        }

        private let lock = NSLock()
        private var mode: Mode = .running
        private var completed: ResultBox<T>?

        func recordCompletion(_ box: ResultBox<T>) -> RecordAction {
            lock.withLock {
                switch mode {
                case .running:
                    completed = box
                    return .deliver
                case .detaching:
                    completed = box
                    return .deferred
                case .detached:
                    return .settleDetached
                case .abandoned:
                    return .settleAbandoned
                }
            }
        }

        func consumeDeliveredCompletion() {
            lock.withLock {
                completed = nil
            }
        }

        func takeCompletionBeforeDeadline() -> ResultBox<T>? {
            lock.withLock {
                guard case .running = mode else { return nil }
                defer { completed = nil }
                return completed
            }
        }

        func prepareDetach() -> DetachPreparation {
            lock.withLock {
                if let completed {
                    self.completed = nil
                    return .completed(completed)
                }
                mode = .detaching
                return .ready
            }
        }

        func activateDetach() -> ResultBox<T>? {
            lock.withLock {
                guard case .detaching = mode else { return nil }
                mode = .detached
                defer { completed = nil }
                return completed
            }
        }

        func abandon() -> ResultBox<T>? {
            lock.withLock {
                switch mode {
                case .detached, .abandoned:
                    return nil
                case .running, .detaching:
                    mode = .abandoned
                    defer { completed = nil }
                    return completed
                }
            }
        }
    }

    private final class TaskStore: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [Task<Void, Never>] = []

        func append(_ task: Task<Void, Never>) {
            lock.withLock {
                tasks.append(task)
            }
        }

        func cancelAll() {
            let captured = lock.withLock { tasks }
            captured.forEach { $0.cancel() }
        }
    }

    static func execute<T: Sendable>(
        deadline: Duration,
        cancellationGrace: Duration,
        cleanupDisposition: MCPToolExecutionCleanupDisposition = .forceDisconnect,
        environment: MCPToolExecutionWatchdogEnvironment = .continuous(),
        onEvent: @escaping @Sendable (MCPToolExecutionWatchdogEvent) async -> Void = { _ in },
        onSynchronousSettlement: @escaping @Sendable (MCPToolExecutionSettlement) async -> Void = { _ in },
        onDetachedSettlement: @escaping @Sendable (MCPToolExecutionSettlement) async -> Void = { _ in },
        onAbandonedSettlement: @escaping @Sendable (MCPToolExecutionSettlement) async -> Void = { _ in },
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let (stream, continuation) = AsyncStream<Event<T>>.makeStream()
        let tasks = TaskStore()
        let operationState = OperationState<T>()

        func settlement(for box: ResultBox<T>) -> MCPToolExecutionSettlement {
            switch box.result {
            case .success:
                .success
            case let .failure(error):
                MCPToolExecutionCancelledError.matches(error) ? .cancellation : .error
            }
        }

        let operationTask = Task {
            let result: Result<T, Error>
            do {
                result = try await .success(operation())
            } catch {
                result = .failure(error)
            }
            let box = ResultBox(result: result)
            switch operationState.recordCompletion(box) {
            case .deliver:
                continuation.yield(.operationCompleted(box))
            case .deferred:
                break
            case .settleDetached:
                await onDetachedSettlement(settlement(for: box))
            case .settleAbandoned:
                await onAbandonedSettlement(settlement(for: box))
            }
        }
        tasks.append(operationTask)

        let deadlineTask = Task {
            do {
                try await environment.sleep(deadline)
                guard !Task.isCancelled else { return }
                continuation.yield(.deadlineExpired)
            } catch {
                // Cancellation is the normal completion path when the operation wins.
            }
        }
        tasks.append(deadlineTask)

        return try await withTaskCancellationHandler {
            var iterator = stream.makeAsyncIterator()
            var deadlineDidExpire = false

            while let event = await iterator.next() {
                switch event {
                case let .operationCompleted(box):
                    operationState.consumeDeliveredCompletion()
                    tasks.cancelAll()
                    continuation.finish()
                    let operationSettlement = settlement(for: box)
                    await onSynchronousSettlement(operationSettlement)
                    if deadlineDidExpire {
                        await onEvent(.settledDuringGrace(operationSettlement))
                        throw MCPToolExecutionWatchdogError.executionTimedOut(
                            settlement: operationSettlement
                        )
                    }
                    return try box.result.get()

                case .deadlineExpired:
                    if let completed = operationState.takeCompletionBeforeDeadline() {
                        tasks.cancelAll()
                        continuation.finish()
                        await onSynchronousSettlement(settlement(for: completed))
                        return try completed.result.get()
                    }
                    guard !deadlineDidExpire else { continue }
                    deadlineDidExpire = true
                    operationTask.cancel()
                    let graceTask = Task {
                        do {
                            try await environment.sleep(cancellationGrace)
                            guard !Task.isCancelled else { return }
                            continuation.yield(.cleanupGraceExpired)
                        } catch {
                            // Cancellation is the normal path when the operation settles.
                        }
                    }
                    tasks.append(graceTask)
                    await onEvent(.deadlineExpired)
                    await onEvent(.cancellationRequested(origin: .watchdogDeadline))

                case .cleanupGraceExpired:
                    guard deadlineDidExpire else { continue }

                    switch cleanupDisposition {
                    case .forceDisconnect:
                        tasks.cancelAll()
                        continuation.finish()
                        await onEvent(.cleanupGraceExpired)
                        throw MCPToolExecutionWatchdogError.cleanupUnresponsive

                    case .detachAndSettle:
                        switch operationState.prepareDetach() {
                        case let .completed(box):
                            tasks.cancelAll()
                            continuation.finish()
                            let operationSettlement = settlement(for: box)
                            await onSynchronousSettlement(operationSettlement)
                            await onEvent(.settledDuringGrace(operationSettlement))
                            throw MCPToolExecutionWatchdogError.executionTimedOut(
                                settlement: operationSettlement
                            )

                        case .ready:
                            await onEvent(.cleanupGraceExpired)
                            await onEvent(.detachedForSettlement)
                            if let completed = operationState.activateDetach() {
                                await onDetachedSettlement(settlement(for: completed))
                            }
                            tasks.cancelAll()
                            continuation.finish()
                            throw MCPToolExecutionWatchdogError.executionDetached
                        }
                    }
                }
            }

            tasks.cancelAll()
            throw CancellationError()
        } onCancel: {
            Task {
                await onEvent(.cancellationRequested(origin: .requestCancellation))
            }
            if let completed = operationState.abandon() {
                Task {
                    await onAbandonedSettlement(settlement(for: completed))
                }
            }
            tasks.cancelAll()
            continuation.finish()
        }
    }
}
