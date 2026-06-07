import Foundation

enum MCPToolExecutionSettlement: String, Equatable {
    case success
    case cancellation
    case error
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
    case cancellationRequested
    case settledDuringGrace(MCPToolExecutionSettlement)
    case cleanupGraceExpired
}

enum MCPToolExecutionWatchdogError: Error, Equatable {
    case executionTimedOut(settlement: MCPToolExecutionSettlement)
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

    private final class TaskStore: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [Task<Void, Never>] = []

        func append(_ task: Task<Void, Never>) {
            lock.lock()
            tasks.append(task)
            lock.unlock()
        }

        func cancelAll() {
            lock.lock()
            let captured = tasks
            lock.unlock()
            captured.forEach { $0.cancel() }
        }
    }

    static func execute<T: Sendable>(
        deadline: Duration,
        cancellationGrace: Duration,
        environment: MCPToolExecutionWatchdogEnvironment = .continuous(),
        onEvent: @escaping @Sendable (MCPToolExecutionWatchdogEvent) async -> Void = { _ in },
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let (stream, continuation) = AsyncStream<Event<T>>.makeStream()
        let tasks = TaskStore()

        let operationTask = Task {
            let result: Result<T, Error>
            do {
                result = try await .success(operation())
            } catch {
                result = .failure(error)
            }
            continuation.yield(.operationCompleted(ResultBox(result: result)))
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
                    if deadlineDidExpire {
                        tasks.cancelAll()
                        continuation.finish()
                        let settlement: MCPToolExecutionSettlement = switch box.result {
                        case .success:
                            .success
                        case let .failure(error):
                            MCPToolExecutionCancelledError.matches(error) ? .cancellation : .error
                        }
                        await onEvent(.settledDuringGrace(settlement))
                        throw MCPToolExecutionWatchdogError.executionTimedOut(settlement: settlement)
                    }

                    tasks.cancelAll()
                    continuation.finish()
                    return try box.result.get()

                case .deadlineExpired:
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
                    await onEvent(.cancellationRequested)

                case .cleanupGraceExpired:
                    guard deadlineDidExpire else { continue }
                    tasks.cancelAll()
                    continuation.finish()
                    await onEvent(.cleanupGraceExpired)
                    throw MCPToolExecutionWatchdogError.cleanupUnresponsive
                }
            }

            tasks.cancelAll()
            throw CancellationError()
        } onCancel: {
            tasks.cancelAll()
            continuation.finish()
        }
    }
}
