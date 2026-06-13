import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class AgentModeWorkspaceSwitchCleanupTests: XCTestCase {
    func testWorkspaceSwitchClearsForegroundBeforeSlowProviderDisposeCompletes() async throws {
        let provider = BlockingHeadlessProvider()
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .openCode
        session.provider = provider
        session.runID = UUID()
        session.runState = .running

        await viewModel.handleWorkspaceSwitch(nil)

        XCTAssertTrue(viewModel.sessions.isEmpty)
        let finishedBeforeRelease = await provider.isDisposeFinished()
        XCTAssertFalse(finishedBeforeRelease)

        try await waitUntil { await provider.isDisposeStarted() }
        await provider.releaseDispose()
        try await waitUntil { await provider.isDisposeFinished() }
    }

    func testWorkspaceSwitchBackgroundCleanupUsesCapturedRunIDAfterForegroundSessionsAreCleared() async throws {
        let routing = RoutingRecorder()
        let cancelled = RoutingRecorder()
        let oldRunID = UUID()
        let viewModel = makeViewModel(
            mcpRunRoutingCleaner: { runID, _, reason in
                await routing.record(runID: runID, reason: reason)
            },
            mcpRunToolCanceller: { runID, reason in
                cancelled.recordSync(runID: runID, reason: reason ?? "nil")
                return 1
            }
        )
        let session = viewModel.session(for: UUID())
        session.selectedAgent = .openCode
        session.runID = oldRunID
        session.runState = .running

        await viewModel.handleWorkspaceSwitch(nil)

        XCTAssertTrue(viewModel.sessions.isEmpty)
        try await waitUntil { await routing.contains(runID: oldRunID, reason: "workspace_switch") }
        XCTAssertTrue(cancelled.containsSync(runID: oldRunID, reason: "workspace_switch"))
    }

    func testDetachedMCPTeardownDoesNotDeactivateNewLiveControlContextWithSameSessionID() async throws {
        let routing = RoutingRecorder()
        let mcpSessionID = UUID()
        let oldRunID = UUID()
        let tabID = UUID()
        let viewModel = makeViewModel(
            mcpRunRoutingCleaner: { runID, _, reason in
                await routing.record(runID: runID, reason: reason)
            }
        )
        let oldSession = viewModel.session(for: tabID)
        oldSession.selectedAgent = .openCode
        oldSession.runID = oldRunID
        oldSession.mcpControlContext = makeMCPControlContext(sessionID: mcpSessionID)

        await viewModel.handleWorkspaceSwitch(nil)
        let newSession = viewModel.session(for: tabID)
        newSession.selectedAgent = .openCode
        newSession.mcpControlContext = makeMCPControlContext(sessionID: mcpSessionID)
        viewModel.test_setMCPControlledTabIDs([tabID])

        try await waitUntil { await routing.contains(runID: oldRunID, reason: "workspace_switch") }
        XCTAssertEqual(newSession.mcpControlContext?.sessionID, mcpSessionID)
    }

    func testDetachedWorkspaceSwitchCleanupDoesNotClearNewSessionOnSameTab() async throws {
        let provider = BlockingHeadlessProvider()
        let tabID = UUID()
        let oldRunID = UUID()
        let newRunID = UUID()
        let viewModel = makeViewModel()
        let oldSession = viewModel.session(for: tabID)
        oldSession.selectedAgent = .openCode
        oldSession.provider = provider
        oldSession.providerSessionID = "old-provider-session"
        oldSession.runID = oldRunID
        oldSession.runState = .running

        await viewModel.handleWorkspaceSwitch(nil)
        let newSession = viewModel.session(for: tabID)
        newSession.selectedAgent = .openCode
        newSession.providerSessionID = "new-provider-session"
        newSession.runID = newRunID
        newSession.runState = .running

        try await waitUntil { await provider.isDisposeStarted() }
        await provider.releaseDispose()
        try await waitUntil { await provider.isDisposeFinished() }

        XCTAssertTrue(viewModel.sessions[tabID] === newSession)
        XCTAssertEqual(newSession.providerSessionID, "new-provider-session")
        XCTAssertEqual(newSession.runID, newRunID)
        XCTAssertEqual(newSession.runState, .running)
    }

    private func makeMCPControlContext(sessionID: UUID) -> AgentModeViewModel.AgentMCPControlContext {
        AgentModeViewModel.AgentMCPControlContext(
            sessionID: sessionID,
            activationID: UUID(),
            registration: .init(sessionID: sessionID, generation: 0),
            currentEpoch: nil,
            preparedEpoch: nil,
            pendingEpochTransition: nil,
            originatingConnectionID: nil,
            interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil),
            suppressUserNotifications: false,
            forceAutoEditEnabled: false,
            autoEditEnabledBeforeOverride: true,
            taskLabelKind: nil
        )
    }

    private func makeViewModel(
        mcpRunRoutingCleaner: @escaping AgentModeViewModel.MCPRunRoutingCleaner = { _, _, _ in },
        mcpRunToolCanceller: AgentModeViewModel.MCPRunToolCanceller? = nil
    ) -> AgentModeViewModel {
        AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in FakeCodexSessionController() },
            mcpRunRoutingCleaner: mcpRunRoutingCleaner,
            mcpRunToolCanceller: mcpRunToolCanceller
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

private actor BlockingHeadlessProvider: HeadlessAgentProvider {
    private var disposeContinuation: CheckedContinuation<Void, Never>?
    private(set) var disposeStarted = false
    private(set) var disposeFinished = false

    func streamAgentMessage(_ message: AgentMessage, runID: UUID?) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func dispose() async {
        disposeStarted = true
        await withCheckedContinuation { continuation in
            disposeContinuation = continuation
        }
        disposeFinished = true
    }

    func releaseDispose() {
        disposeContinuation?.resume()
        disposeContinuation = nil
    }

    func isDisposeStarted() -> Bool {
        disposeStarted
    }

    func isDisposeFinished() -> Bool {
        disposeFinished
    }
}

private final class RoutingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(UUID, String)] = []

    func record(runID: UUID, reason: String) async {
        recordSync(runID: runID, reason: reason)
    }

    func contains(runID: UUID, reason: String) async -> Bool {
        containsSync(runID: runID, reason: reason)
    }

    func recordSync(runID: UUID, reason: String) {
        lock.lock()
        records.append((runID, reason))
        lock.unlock()
    }

    func containsSync(runID: UUID, reason: String) -> Bool {
        lock.lock()
        let result = records.contains { $0.0 == runID && $0.1 == reason }
        lock.unlock()
        return result
    }
}

private final class FakeCodexSessionController: CodexSessionControllerTurnDispatchTestDefaults {
    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in continuation.finish() }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(
        includeTurns: Bool,
        timeout: TimeInterval?
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

    func setThreadName(_ name: String, threadID: String?) async throws {}
    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_ objective: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_ status: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}
