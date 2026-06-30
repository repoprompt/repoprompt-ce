import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class AgentModeProviderConversationCleanupTests: XCTestCase {
    func testLiveCodexCleanupInvokesControllerAndReportsOutcome() async {
        let previousAction = GlobalSettingsStore.shared.providerConversationCleanupAction()
        GlobalSettingsStore.shared.setProviderConversationCleanupAction(.archive, commit: false)
        defer { GlobalSettingsStore.shared.setProviderConversationCleanupAction(previousAction, commit: false) }

        let controller = CleanupRecordingCodexController(
            outcome: .succeeded(message: "controller cleanup")
        )
        let viewModel = makeViewModel(codexController: controller)
        let session = viewModel.session(for: UUID())
        session.selectedAgent = .codexExec
        session.codexController = controller
        session.providerCleanupHandle = ProviderConversationCleanupHandle(
            provider: AgentProviderKind.codexExec.rawValue,
            conversationID: "explicit-live-thread",
            rolloutPath: "/tmp/explicit-live-rollout.jsonl"
        )
        session.codexConversationID = "live-thread"
        session.codexRolloutPath = "/tmp/live-rollout.jsonl"

        let outcome = await viewModel.cleanupProviderConversationForDeletedAgentSession(session)

        XCTAssertEqual(outcome, .succeeded(message: "controller cleanup"))
        let calls = controller.cleanupCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.handle.conversationID, "explicit-live-thread")
        XCTAssertEqual(calls.first?.handle.rolloutPath, "/tmp/explicit-live-rollout.jsonl")
        XCTAssertEqual(calls.first?.action, .archive)
    }

    func testDeleteSessionCleansLiveProviderConversationOnce() async {
        let previousAction = GlobalSettingsStore.shared.providerConversationCleanupAction()
        GlobalSettingsStore.shared.setProviderConversationCleanupAction(.archive, commit: false)
        defer { GlobalSettingsStore.shared.setProviderConversationCleanupAction(previousAction, commit: false) }

        let controller = CleanupRecordingCodexController(
            outcome: .succeeded(message: "controller cleanup")
        )
        let viewModel = makeViewModel(codexController: controller)
        let sessionID = UUID()
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.selectedAgent = .codexExec
        session.codexController = controller
        session.providerCleanupHandle = ProviderConversationCleanupHandle(
            provider: AgentProviderKind.codexExec.rawValue,
            conversationID: "delete-thread",
            rolloutPath: "/tmp/delete-rollout.jsonl"
        )

        let outcome = await viewModel.deleteSession(tabID: tabID)

        XCTAssertEqual(outcome, .succeeded(message: "controller cleanup"))
        let calls = controller.cleanupCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.handle.conversationID, "delete-thread")
        XCTAssertEqual(calls.first?.action, .archive)
    }

    func testPersistedCodexCleanupUsesStoredConversationMetadata() async {
        let previousAction = GlobalSettingsStore.shared.providerConversationCleanupAction()
        GlobalSettingsStore.shared.setProviderConversationCleanupAction(.archive, commit: false)
        defer { GlobalSettingsStore.shared.setProviderConversationCleanupAction(previousAction, commit: false) }

        let recorder = PersistedCleanupRecorder(outcome: .succeeded(message: "persisted cleanup"))
        let viewModel = makeViewModel(
            persistedProviderConversationCleaner: { handle, action in
                recorder.record(handle: handle, action: action)
                return recorder.outcome
            }
        )
        let agentSession = AgentSession(
            agentKind: AgentProviderKind.codexExec.rawValue,
            autoEditEnabled: true,
            codexConversationID: "persisted-thread",
            codexRolloutPath: "/tmp/persisted-rollout.jsonl"
        )

        let outcome = await viewModel.cleanupProviderConversationForPersistedAgentSession(agentSession)

        XCTAssertEqual(outcome, .succeeded(message: "persisted cleanup"))
        let calls = recorder.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.handle.conversationID, "persisted-thread")
        XCTAssertEqual(calls.first?.handle.rolloutPath, "/tmp/persisted-rollout.jsonl")
        XCTAssertEqual(calls.first?.action, .archive)
    }

    func testPersistedCodexCleanupPrefersStoredGenericHandle() async {
        let previousAction = GlobalSettingsStore.shared.providerConversationCleanupAction()
        GlobalSettingsStore.shared.setProviderConversationCleanupAction(.archive, commit: false)
        defer { GlobalSettingsStore.shared.setProviderConversationCleanupAction(previousAction, commit: false) }

        let recorder = PersistedCleanupRecorder(outcome: .succeeded(message: "persisted cleanup"))
        let viewModel = makeViewModel(
            persistedProviderConversationCleaner: { handle, action in
                recorder.record(handle: handle, action: action)
                return recorder.outcome
            }
        )
        let agentSession = AgentSession(
            agentKind: AgentProviderKind.codexExec.rawValue,
            providerCleanupHandle: ProviderConversationCleanupHandle(
                provider: AgentProviderKind.codexExec.rawValue,
                conversationID: "canonical-thread",
                rolloutPath: "/tmp/canonical-rollout.jsonl"
            ),
            autoEditEnabled: true,
            codexConversationID: "legacy-thread",
            codexRolloutPath: "/tmp/legacy-rollout.jsonl"
        )

        let outcome = await viewModel.cleanupProviderConversationForPersistedAgentSession(agentSession)

        XCTAssertEqual(outcome, .succeeded(message: "persisted cleanup"))
        let calls = recorder.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.handle.conversationID, "canonical-thread")
        XCTAssertEqual(calls.first?.handle.rolloutPath, "/tmp/canonical-rollout.jsonl")
        XCTAssertEqual(calls.first?.action, .archive)
    }

    func testPersistedUnsupportedProviderReportsUnsupportedAndSkipsCodexCleaner() async {
        let previousAction = GlobalSettingsStore.shared.providerConversationCleanupAction()
        GlobalSettingsStore.shared.setProviderConversationCleanupAction(.archive, commit: false)
        defer { GlobalSettingsStore.shared.setProviderConversationCleanupAction(previousAction, commit: false) }

        let recorder = PersistedCleanupRecorder(outcome: .succeeded())
        let viewModel = makeViewModel(
            persistedProviderConversationCleaner: { handle, action in
                recorder.record(handle: handle, action: action)
                return recorder.outcome
            }
        )
        let agentSession = AgentSession(
            agentKind: AgentProviderKind.openCode.rawValue,
            providerSessionID: "open-code-provider-session",
            autoEditEnabled: true
        )

        let outcome = await viewModel.cleanupProviderConversationForPersistedAgentSession(agentSession)

        XCTAssertEqual(
            outcome,
            .unsupported(message: "ACP provider openCode has session metadata but no verified conversation cleanup API.")
        )
        XCTAssertTrue(recorder.calls().isEmpty)
    }

    func testProviderCleanupRegistryRoutesCodexToCodexCleaner() async {
        let recorder = PersistedCleanupRecorder(outcome: .succeeded(message: "codex cleaner"))
        let registry = ProviderConversationCleanupRegistry { handle, action in
            recorder.record(handle: handle, action: action)
            return recorder.outcome
        }
        let handle = ProviderConversationCleanupHandle(
            provider: AgentProviderKind.codexExec.rawValue,
            conversationID: "thread-id"
        )

        let outcome = await registry.cleanup(handle, action: .archive)

        XCTAssertEqual(outcome, .succeeded(message: "codex cleaner"))
        XCTAssertEqual(recorder.calls().count, 1)
        XCTAssertEqual(recorder.calls().first?.handle, handle)
        XCTAssertEqual(recorder.calls().first?.action, .archive)
    }

    func testProviderCleanupRegistryReportsUnsupportedForNonCodexProviders() async {
        let recorder = PersistedCleanupRecorder(outcome: .succeeded())
        let registry = ProviderConversationCleanupRegistry { handle, action in
            recorder.record(handle: handle, action: action)
            return recorder.outcome
        }

        let claude = await registry.cleanup(
            ProviderConversationCleanupHandle(provider: AgentProviderKind.claudeCode.rawValue, sessionID: "claude-session"),
            action: .archive
        )
        let openCode = await registry.cleanup(
            ProviderConversationCleanupHandle(provider: AgentProviderKind.openCode.rawValue, sessionID: "open-code-session"),
            action: .archive
        )
        let cursor = await registry.cleanup(
            ProviderConversationCleanupHandle(provider: AgentProviderKind.cursor.rawValue, sessionID: "cursor-session"),
            action: .archive
        )
        let unknown = await registry.cleanup(
            ProviderConversationCleanupHandle(provider: "unknownProvider", sessionID: "unknown-session"),
            action: .archive
        )

        XCTAssertEqual(
            claude,
            .unsupported(message: "Provider claudeCode has resumable session metadata but no verified conversation cleanup API.")
        )
        XCTAssertEqual(
            openCode,
            .unsupported(message: "ACP provider openCode has session metadata but no verified conversation cleanup API.")
        )
        XCTAssertEqual(
            cursor,
            .unsupported(message: "ACP provider cursor has session metadata but no verified conversation cleanup API.")
        )
        XCTAssertEqual(
            unknown,
            .unsupported(message: "Provider unknownProvider has no registered conversation cleanup implementation.")
        )
        XCTAssertTrue(recorder.calls().isEmpty)
    }

    private func makeViewModel(
        codexController: (any CodexSessionControlling)? = nil,
        persistedProviderConversationCleaner: @escaping AgentModeViewModel.PersistedProviderConversationCleaner = { _, _ in
            .unsupported(message: "test cleaner not installed")
        }
    ) -> AgentModeViewModel {
        AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in
                codexController ?? CleanupRecordingCodexController(outcome: .succeeded())
            },
            providerConversationCleanupRegistry: ProviderConversationCleanupRegistry(codexCleaner: persistedProviderConversationCleaner)
        )
    }
}

private final class PersistedCleanupRecorder: @unchecked Sendable {
    struct Call {
        let handle: ProviderConversationCleanupHandle
        let action: ProviderConversationCleanupAction
    }

    let outcome: ProviderConversationCleanupOutcome
    private let lock = NSLock()
    private var recordedCalls: [Call] = []

    init(outcome: ProviderConversationCleanupOutcome) {
        self.outcome = outcome
    }

    func record(handle: ProviderConversationCleanupHandle, action: ProviderConversationCleanupAction) {
        lock.lock()
        recordedCalls.append(.init(handle: handle, action: action))
        lock.unlock()
    }

    func calls() -> [Call] {
        lock.lock()
        let calls = recordedCalls
        lock.unlock()
        return calls
    }
}

private final class CleanupRecordingCodexController: CodexSessionControlling, @unchecked Sendable {
    struct CleanupCall {
        let handle: ProviderConversationCleanupHandle
        let action: ProviderConversationCleanupAction
    }

    var hasActiveThread: Bool {
        true
    }

    let events: AsyncStream<CodexNativeSessionController.Event> = AsyncStream { _ in }

    private let lock = NSLock()
    private let outcome: ProviderConversationCleanupOutcome
    private var recordedCleanupCalls: [CleanupCall] = []

    init(outcome: ProviderConversationCleanupOutcome) {
        self.outcome = outcome
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "unused", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model _: String?,
        reasoningEffort _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "unused", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "unused", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        throw CleanupControllerTestError.unexpectedCall
    }

    func setThreadName(_: String, threadID _: String?) async throws {}

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        .init(provisionalSubmissionID: "unused")
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        .init(acceptedTurnID: expectedTurnID)
    }

    func prepareLifecycleAuthorityReconciliationAfterAcceptedMismatch(
        expectedCurrentTurnID _: String,
        acceptedDispatchTurnID _: String
    ) async -> Bool {
        false
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        .init(interruptedTurnID: expectedTurnID)
    }

    func reconcileAndInterruptCurrentTurn() async throws -> CodexTurnInterruptReceipt {
        .init(interruptedTurnID: "unused")
    }

    func compactThread() async throws {}

    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CleanupControllerTestError.unexpectedCall
    }

    func setThreadGoalStatus(_: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CleanupControllerTestError.unexpectedCall
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func pendingTurnFailure(turnID _: String?) async -> CodexNativeSessionController.TurnFailure? {
        nil
    }

    func acknowledgePendingTurnFailure(
        turnID _: String?,
        failure _: CodexNativeSessionController.TurnFailure
    ) async {}

    func cancelCurrentTurn() async {}

    func cleanupConversation(
        _ handle: ProviderConversationCleanupHandle,
        action: ProviderConversationCleanupAction
    ) async -> ProviderConversationCleanupOutcome {
        lock.lock()
        recordedCleanupCalls.append(.init(handle: handle, action: action))
        lock.unlock()
        return outcome
    }

    func shutdown() async {}

    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}

    func cleanupCalls() -> [CleanupCall] {
        lock.lock()
        let calls = recordedCleanupCalls
        lock.unlock()
        return calls
    }
}

private enum CleanupControllerTestError: Error {
    case unexpectedCall
}
