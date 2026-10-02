import Foundation
import MCP
import RepoPromptShared

/// Request lifetime, not child lifetime. Owns evidence and deadline revisions, never a timer.
package final class MCPAgentRunStartExecutionScope: @unchecked Sendable {
    @TaskLocal package static var current: MCPAgentRunStartExecutionScope?

    package enum Phase: String { case setup, semanticWait, returning }
    package enum DispatchState: String {
        case notAttempted = "not_attempted", unknown, accepted, refused
    }

    package struct Deadline: Equatable {
        package let revision: UInt64
        package let instant: Duration
    }

    private struct State {
        var phase: Phase = .setup
        var deadline: Deadline
        var semanticDeadline: Duration?
        var closed = false
        var settled = false
        var sessionID: UUID?
        var tabID: UUID?
        var created = false
        var dispatch: DispatchState = .notAttempted
        var response: Value?
        var activationID: UUID?
        var worktreeRecovery: String?
        var observer: (@Sendable (Deadline) -> Void)?
    }

    package let invocationID: UUID
    package let connectionID: UUID
    package let environment: MCPToolExecutionWatchdogEnvironment
    private let lock = NSLock()
    private var state: State

    package init(invocationID: UUID = UUID(), connectionID: UUID, environment: MCPToolExecutionWatchdogEnvironment) {
        self.invocationID = invocationID
        self.connectionID = connectionID
        self.environment = environment
        state = State(deadline: .init(revision: 0, instant: environment.now() + MCPTimeoutPolicy.agentRunStartSetupDeadline))
    }

    package var deadline: Deadline {
        lock.withLock { state.deadline }
    }

    package var phase: Phase {
        lock.withLock { state.phase }
    }

    package var hasAcceptedDispatch: Bool {
        lock.withLock { state.dispatch == .accepted }
    }

    package var allowsFailureCleanup: Bool {
        lock.withLock { state.dispatch == .notAttempted || state.dispatch == .refused }
    }

    package func installDeadlineObserver(_ observer: @escaping @Sendable (Deadline) -> Void) {
        lock.withLock { state.observer = observer }
    }

    package func clearDeadlineObserver() {
        lock.withLock { state.observer = nil }
    }

    package func checkAdmission() throws {
        try lock.withLock { try checkAdmissionLocked() }
    }

    private func checkAdmissionLocked() throws {
        if environment.now() >= state.deadline.instant { state.closed = true }
        guard !state.closed, !Task.isCancelled else { throw CancellationError() }
    }

    /// No await between the deadline check and mutation admission at the owner.
    package func recordTarget(sessionID: UUID, tabID: UUID, created: Bool = false) throws {
        try lock.withLock {
            try checkAdmissionLocked()
            guard state.sessionID == nil || (state.sessionID == sessionID && state.tabID == tabID) else {
                throw CancellationError()
            }
            state.sessionID = sessionID
            state.tabID = tabID
            state.created = state.created || created
        }
    }

    package var activationID: UUID? {
        lock.withLock { state.activationID }
    }

    package func recordActivation(_ id: UUID) throws {
        try lock.withLock { try checkAdmissionLocked()
            state.activationID = id
        }
    }

    package func recordWorktreeIntent(_ recovery: String) throws {
        try lock.withLock {
            try checkAdmissionLocked()
            state.worktreeRecovery = recovery
        }
    }

    package func confirmTarget() {
        lock.withLock { state.created = true }
    }

    package func beginDispatch() throws {
        try lock.withLock {
            try checkAdmissionLocked()
            guard state.dispatch == .notAttempted else { throw CancellationError() }
            state.dispatch = .unknown
        }
    }

    /// Late acknowledgements must reconcile even after admission closes.
    package func recordDispatch(accepted: Bool) {
        lock.withLock {
            if state.dispatch != .accepted { state.dispatch = accepted ? .accepted : .refused }
        }
    }

    package func cacheResponse(_ value: Value) {
        lock.withLock { state.response = value }
    }

    package func close() {
        lock.withLock { state.closed = true }
    }

    package func settle() {
        lock.withLock { state.settled = true
            state.observer = nil
        }
    }

    @discardableResult
    package func enterSemanticWait(seconds: TimeInterval) throws -> Duration {
        try lock.withLock {
            try checkAdmissionLocked()
            guard state.phase == .setup else { throw CancellationError() }
            let semantic = environment.now() + .seconds(seconds)
            state.phase = .semanticWait
            state.semanticDeadline = semantic
            state.deadline = .init(revision: state.deadline.revision + 1, instant: semantic + MCPTimeoutPolicy.agentRunStartReturnDeadline)
            state.observer?(state.deadline)
            return semantic
        }
    }

    package func enterReturn() throws {
        try lock.withLock {
            if state.phase == .returning { try checkAdmissionLocked()
                return
            }
            try checkAdmissionLocked()
            let envelope = state.semanticDeadline.map { $0 + MCPTimeoutPolicy.agentRunStartReturnDeadline }
            let proposed = environment.now() + MCPTimeoutPolicy.agentRunStartReturnDeadline
            state.phase = .returning
            state.deadline = .init(revision: state.deadline.revision + 1, instant: envelope.map { min($0, proposed) } ?? proposed)
            state.observer?(state.deadline)
        }
    }

    /// Stale timer events cannot close admission for a timely successor phase.
    package func expire(revision: UInt64) -> Bool {
        lock.withLock {
            guard state.deadline.revision == revision, environment.now() >= state.deadline.instant else { return false }
            state.closed = true
            return true
        }
    }

    package func timeoutValue(code: String, message: String) -> Value {
        var object = lock.withLock { state.response?.objectValue ?? [:] }
        object["is_error"] = .bool(true)
        object["code"] = .string(code)
        object["error"] = .string(message)
        var metadata = object["_meta"]?.objectValue ?? [:]
        metadata["start"] = .object(recoveryMetadata())
        object["_meta"] = .object(metadata)
        return .object(object)
    }

    package func recoveryMetadata() -> [String: Value] {
        lock.withLock {
            var result: [String: Value] = [
                "invocation_id": .string(invocationID.uuidString),
                "phase": .string(state.phase == .setup ? "setup" : "returning"),
                "dispatch_state": .string(state.dispatch.rawValue),
                "settlement": .string(state.settled ? "settled" : "pending"),
                "recovery": .string("Inspect the existing session; do not resend start while commitment is uncertain.")
            ]
            if let sessionID = state.sessionID { result["session_id"] = .string(sessionID.uuidString) }
            if let worktreeRecovery = state.worktreeRecovery {
                result["recovery"] = .string("Inspect the existing session; do not resend start while commitment is uncertain. " + worktreeRecovery)
            }
            return result
        }
    }
}
