import Foundation
@testable import RepoPromptApp
import XCTest

private struct AgentSessionLinkAsyncWaitTimeout: Error, LocalizedError {
    let description: String
    let timeout: TimeInterval

    var errorDescription: String? {
        "Timed out after \(timeout)s waiting for \(description)"
    }
}

enum AsyncTestWait {
    /// Bounded async wait for actor state that has no explicit test signal.
    static func waitUntil(
        _ description: String,
        timeout: TimeInterval = 3,
        initialDelayNanoseconds: UInt64 = 1_000_000,
        maximumDelayNanoseconds: UInt64 = 25_000_000,
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(0, timeout)))
        let maximumDelay = max(1, min(maximumDelayNanoseconds, UInt64(Int64.max)))
        var delay = max(1, min(initialDelayNanoseconds, maximumDelay))

        while true {
            if await condition() {
                return
            }
            let now = clock.now
            guard now < deadline else {
                throw AgentSessionLinkAsyncWaitTimeout(description: description, timeout: timeout)
            }
            let sleepDeadline = min(deadline, now.advanced(by: .nanoseconds(Int64(delay))))
            try await clock.sleep(until: sleepDeadline, tolerance: .zero)
            delay = min(delay > maximumDelay / 2 ? maximumDelay : delay * 2, maximumDelay)
        }
    }
}

/// Minimal hang-hardened release fence used by oversight transaction tests.
final class TestReleaseFence: @unchecked Sendable {
    private let name: String
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var cancelledWaiters = Set<UUID>()

    init(name: String = "test release fence") {
        self.name = name
    }

    func enterAndWait() async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                condition.lock()
                entered = true
                condition.broadcast()
                if released || Task.isCancelled || cancelledWaiters.remove(waiterID) != nil {
                    condition.unlock()
                    continuation.resume()
                } else {
                    continuations[waiterID] = continuation
                    condition.unlock()
                }
            }
        } onCancel: {
            condition.lock()
            let continuation = continuations.removeValue(forKey: waiterID)
            if continuation == nil {
                cancelledWaiters.insert(waiterID)
            }
            condition.broadcast()
            condition.unlock()
            continuation?.resume()
        }
    }

    @discardableResult
    func waitUntilEntered(timeout: TimeInterval = 10, failOnTimeout: Bool = true) async -> Bool {
        if hasEntered {
            return true
        }
        do {
            try await AsyncTestWait.waitUntil("\(name) entered", timeout: timeout) {
                self.hasEntered
            }
            return true
        } catch {
            if failOnTimeout {
                XCTFail(error.localizedDescription)
            }
            return hasEntered
        }
    }

    func release() {
        condition.lock()
        released = true
        let pending = Array(continuations.values)
        continuations.removeAll()
        cancelledWaiters.removeAll()
        condition.broadcast()
        condition.unlock()
        for continuation in pending {
            continuation.resume()
        }
    }

    private var hasEntered: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }
}

protocol CodexSessionControllerTurnDispatchTestDefaults: CodexSessionControlling {}

extension CodexSessionControllerTurnDispatchTestDefaults {
    func listHooksForCurrentWorkspace() async throws -> CodexHookInventory {
        try CodexHookInventory(executionCWD: "/tmp", hooks: [])
    }

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        CodexTurnStartReceipt(provisionalSubmissionID: "<test-submission>")
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
    }

    func prepareLifecycleAuthorityReconciliationAfterAcceptedMismatch(
        expectedCurrentTurnID _: String,
        acceptedDispatchTurnID _: String
    ) async -> Bool {
        true
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
    }

    func reconcileAndInterruptCurrentTurn() async throws -> CodexTurnInterruptReceipt {
        try await interruptUserTurn(expectedTurnID: "<test-turn>")
    }

    func pendingTurnFailure(turnID _: String?) async -> CodexNativeSessionController.TurnFailure? {
        nil
    }

    func acknowledgePendingTurnFailure(
        turnID _: String?,
        failure _: CodexNativeSessionController.TurnFailure
    ) async {}
}

protocol CodexSessionControllerPassiveStubDefaults: CodexSessionControllerTurnDispatchTestDefaults {}

extension CodexSessionControllerPassiveStubDefaults {
    var hasActiveThread: Bool {
        false
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        try await startOrResume(
            existing: existing,
            baseInstructions: baseInstructions,
            model: nil,
            reasoningEffort: nil,
            serviceTier: nil
        )
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        try await startOrResume(
            existing: existing,
            baseInstructions: baseInstructions,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: nil
        )
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(
            conversationID: "fake",
            rolloutPath: nil,
            model: model,
            reasoningEffort: reasoningEffort
        )
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "fake",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func setThreadName(_: String, threadID _: String?) async throws {}
    func compactThread() async throws {}

    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}

final class LifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

final class LifecycleNoopCodexController: CodexSessionControllerTurnDispatchTestDefaults {
    private let recorder: LifecycleRecorder
    private(set) var hasActiveThread = false

    init(recorder: LifecycleRecorder) {
        self.recorder = recorder
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { _ in }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        try await startOrResume(
            existing: nil,
            baseInstructions: "",
            model: nil,
            reasoningEffort: nil,
            serviceTier: nil
        )
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        try await startOrResume(
            existing: nil,
            baseInstructions: "",
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: nil
        )
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        hasActiveThread = true
        return CodexNativeSessionController.SessionRef(
            conversationID: "lifecycle",
            rolloutPath: nil,
            model: model,
            reasoningEffort: reasoningEffort
        )
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "lifecycle",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func setThreadName(_: String, threadID _: String?) async throws {}

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        recorder.record("codex:send")
        return CodexTurnStartReceipt(provisionalSubmissionID: "lifecycle-submission")
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        recorder.record("codex:send")
        return CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        recorder.record("codex:interrupt:\(expectedTurnID)")
        return CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
    }

    func compactThread() async throws {}

    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {
        recorder.record("codex:cancel")
    }

    func shutdown() async {
        recorder.record("codex:shutdown")
    }

    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}
