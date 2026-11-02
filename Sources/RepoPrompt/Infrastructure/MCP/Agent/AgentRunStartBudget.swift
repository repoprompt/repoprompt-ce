import Foundation

@MainActor
final class AgentRunStartExpiry {
    let toolName: String
    let budgetSeconds: TimeInterval
    let deadline: ContinuousClock.Instant
    private(set) var activatedSessionID: UUID?
    private(set) var expiredBeforeActivation = false

    init(toolName: String, budgetSeconds: TimeInterval) {
        self.toolName = toolName
        self.budgetSeconds = budgetSeconds
        deadline = ContinuousClock.now.advanced(by: .seconds(budgetSeconds))
    }

    var hasExpired: Bool {
        ContinuousClock.now >= deadline
    }

    var timeoutError: AgentRunStartSetupTimeoutError {
        .init(toolName: toolName, budgetSeconds: budgetSeconds)
    }

    func recordActivation(sessionID: UUID, tabID _: UUID) throws {
        if expiredBeforeActivation {
            throw timeoutError
        }
        activatedSessionID = sessionID
    }

    func beginNextChild() throws {
        activatedSessionID = nil
        try throwIfExpired()
    }

    func throwIfExpired() throws {
        if hasExpired {
            throw timeoutError
        }
    }

    func classifyExpiry() {
        if activatedSessionID == nil {
            expiredBeforeActivation = true
        }
    }
}

struct AgentRunStartSetupTimeoutError: LocalizedError, CustomStringConvertible, Equatable {
    let toolName: String
    let budgetSeconds: TimeInterval
    var description: String {
        "\(toolName).start timed out after \(AgentMCPToolHelpers.renderTimeout(budgetSeconds)) seconds while preparing the session. No run was started and nothing was dispatched. Retry the start."
    }

    var errorDescription: String? {
        description
    }
}

enum AgentRunStartBudget {
    private enum Outcome<Output> {
        case result(Result<Output, Error>)
        case expired
        case cancelled
    }

    private final class RaceBox<Output>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome<Output>, Never>?
        private var outcome: Outcome<Output>?
        private var tasks: [Task<Void, Never>] = []

        func install(_ continuation: CheckedContinuation<Outcome<Output>, Never>) {
            lock.lock()
            let settled = outcome
            if settled == nil {
                self.continuation = continuation
            }
            lock.unlock()
            if let settled {
                continuation.resume(returning: settled)
            }
        }

        func offer(_ value: Outcome<Output>) {
            lock.lock()
            guard outcome == nil else { lock.unlock()
                return
            }
            outcome = value
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }

        func attach(_ tasks: [Task<Void, Never>]) {
            lock.lock()
            self.tasks = tasks
            let cancelled = if case .cancelled = outcome {
                true
            } else {
                false
            }
            lock.unlock()
            if cancelled {
                tasks.forEach { $0.cancel() }
            }
        }

        func cancel() {
            offer(.cancelled)
            lock.lock()
            let tasks = tasks
            lock.unlock()
            tasks.forEach { $0.cancel() }
        }
    }

    @MainActor
    static func run<Output: Sendable>(
        expiry: AgentRunStartExpiry,
        operation: @escaping @MainActor () async throws -> Output,
        onExpiry: @MainActor () throws -> Output
    ) async throws -> Output {
        try Task.checkCancellation()
        if expiry.hasExpired {
            expiry.classifyExpiry()
            return try onExpiry()
        }
        let box = RaceBox<Output>()
        var worker: Task<Void, Never>?
        var timer: Task<Void, Never>?
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.install(continuation)
                let work = Task { @MainActor in
                    do { try await box.offer(.result(.success(operation()))) }
                    catch { box.offer(.result(.failure(error))) }
                }
                let alarm = Task { @MainActor in
                    do { try await Task.sleep(until: expiry.deadline, clock: .continuous) }
                    catch { return }
                    expiry.classifyExpiry()
                    box.offer(.expired)
                }
                worker = work
                timer = alarm
                box.attach([work, alarm])
            }
        } onCancel: {
            box.cancel()
        }
        timer?.cancel()
        switch outcome {
        case let .result(result):
            if case let .failure(error) = result, error is AgentRunStartSetupTimeoutError {
                expiry.classifyExpiry()
                return try onExpiry()
            }
            return try result.get()
        case .cancelled: throw CancellationError()
        case .expired:
            if expiry.expiredBeforeActivation {
                worker?.cancel()
            }
            return try onExpiry()
        }
    }
}
