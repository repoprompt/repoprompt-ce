import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class CodexAgentModeCoordinatorLivenessTests: XCTestCase {
    func testActiveThreadSnapshotCountsAsWatchdogLivenessAndReconcilesWaitingFlags() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: ["waiting_for_user_input"]))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let waitingStatus = "Codex reports it is waiting for user input…"

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.assistantDelta("progress"), session: session)

        try await waitUntil {
            controller.readSnapshotCountSync() > 0 && session.runningStatusText == waitingStatus
        }

        XCTAssertEqual(session.runningStatusText, waitingStatus)
        XCTAssertFalse(session.items.contains { item in
            item.kind == .error && item.text.contains("Repo Prompt thinks Codex has stalled")
        })
    }

    func testStructuredLivenessAdvancesLifecycleWithoutTranscriptRows() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let baselineItems = session.items
        let previousSequence = session.activeRunLiveness?.lastAcceptedSequence ?? 0

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .livenessActivity(.init(
                kind: .mcpToolProgress,
                method: "item/mcpToolCall/progress",
                threadID: "fake",
                turnID: "turn",
                itemID: "item",
                activeFlags: ["waiting_for_user_input"],
                message: "progress"
            )),
            session: session
        )

        XCTAssertEqual(session.items, baselineItems)
        XCTAssertGreaterThan(session.activeRunLiveness?.lastAcceptedSequence ?? 0, previousSequence)
        XCTAssertEqual(session.activeRunLiveness?.stage, .running)
        XCTAssertEqual(session.runningStatusText, "Codex reports it is waiting for user input…")
        XCTAssertEqual(session.runState, .running)
    }

    func testUnmatchedCompletionOnlyWebResultPreservesArgsForPersistenceAndReplay() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let invocationID = UUID()
        let argsJSON = #"{"action":"find_in_page","url":"https://example.com/docs","pattern":"install"}"#
        let resultJSON = #"{"status":"completed","match_count":2}"#

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolResult(
                name: "search",
                invocationID: invocationID,
                argsJSON: argsJSON,
                resultJSON: resultJSON,
                isError: false
            ),
            session: session
        )

        let item = try XCTUnwrap(session.items.last)
        XCTAssertEqual(item.kind, .toolResult)
        XCTAssertEqual(item.toolInvocationID, invocationID)
        XCTAssertEqual(item.toolArgsJSON, argsJSON)
        let livePresentation = try XCTUnwrap(
            NativeToolCardPresentationBuilder.build(item: item, normalizedToolName: "search")
        )
        XCTAssertEqual(livePresentation.title, "Find In Page")

        let persisted = AgentChatItemPersist(from: item)
        let restored = persisted.toItem()
        XCTAssertEqual(restored.toolInvocationID, invocationID)
        let restoredPresentation = try XCTUnwrap(
            NativeToolCardPresentationBuilder.build(item: restored, normalizedToolName: "search")
        )
        XCTAssertEqual(restoredPresentation.title, "Find In Page")
        XCTAssertEqual(restoredPresentation.detailText, "2 matches")
    }

    func testStructuredRetryAndMissingMetadataFallbackRemainActiveWithoutRows() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let baselineItems = session.items

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "provider retry",
                willRetry: true,
                threadID: "fake",
                turnID: "turn"
            )),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunLiveness?.stage, .retrying)
        XCTAssertEqual(session.activeRunLiveness?.retryIntent, .providerManaged)
        XCTAssertEqual(session.items, baselineItems)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "Reconnecting... legacy payload",
                willRetry: nil,
                threadID: "fake",
                turnID: "turn"
            )),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunLiveness?.stage, .retrying)
        XCTAssertEqual(session.items, baselineItems)
    }

    func testStructuredNonRetryingErrorUsesTerminalCommit() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "fatal provider error",
                willRetry: false,
                threadID: "fake",
                turnID: "turn"
            )),
            session: session
        )

        XCTAssertEqual(session.runState, .failed)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertNotNil(session.lastTerminalCommitRevision)
        XCTAssertEqual(session.items.last?.kind, .error)
        XCTAssertEqual(session.items.last?.text, "fatal provider error")
    }

    func testStaleStructuredScopeIsIgnored() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let baselineItems = session.items
        let baselineLiveness = session.activeRunLiveness

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "stale fatal error",
                willRetry: false,
                threadID: "fake",
                turnID: "old-turn",
                itemID: "old-item"
            )),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunLiveness, baselineLiveness)
        XCTAssertEqual(session.items, baselineItems)
    }

    func testWatchdogPauseRemainsRunningAndDoesNotAppendTranscriptFailure() async throws {
        let controller = LivenessFakeCodexController(snapshot: .idle, activeTurnIDs: [])
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let baselineItems = session.items

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.assistantDelta("progress"), session: session)
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        try await waitUntil {
            session.codexWatchdogState.isPausedAfterWarning
        }

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.items.count, baselineItems.count + 1)
        XCTAssertEqual(session.items.last?.kind, .assistant)
        XCTAssertEqual(session.items.last?.text, "progress")
        XCTAssertFalse(session.items.contains { $0.kind == .error })
        XCTAssertEqual(session.runningStatusText, "Repo Prompt thinks Codex has stalled or timed out. You can stop and resume.")
    }

    func testPendingRequestUserInputSuppressesWatchdogAndPreservesQueue() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let pending = makeUserInputRequest(id: "pending")
        let queued = makeUserInputRequest(id: "queued")
        session.pendingUserInputRequest = pending
        session.queuedUserInputRequests = [queued]

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.assistantDelta("progress"), session: session)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(controller.readSnapshotCountSync(), 0)
        XCTAssertEqual(session.pendingUserInputRequest?.requestID, pending.requestID)
        XCTAssertEqual(session.queuedUserInputRequests.map(\.requestID), [queued.requestID])
    }

    func testInactiveCommandRunningOutputWithoutAnchorCreatesMinimalAnchorOnly() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let activeTabID = UUID()
        let inactiveTabID = UUID()
        viewModel.test_setCurrentTabIDOverride(activeTabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }
        _ = await viewModel.ensureSessionReady(tabID: activeTabID)
        let session = await viewModel.ensureSessionReady(tabID: inactiveTabID)
        session.selectedAgent = .codexExec
        session.runState = .running
        let invocationID = UUID()

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .commandExecutionRunning(.init(
                invocationID: invocationID,
                processID: "inactive-123",
                appendedOutput: "inactive first chunk\n"
            )),
            session: session
        )

        try await waitUntil {
            session.bashLiveExecutionByKey.values.first?.parsedResult.output?.contains("inactive first chunk") == true
        }
        let bashItem = try XCTUnwrap(session.items.first(where: { $0.toolName == "bash" }))
        XCTAssertFalse(bashItem.toolResultJSON?.contains("inactive first chunk") == true)
        XCTAssertFalse(bashItem.text.contains("inactive first chunk"))
    }

    func testStaleCompletionBeforeObservedStartPreservesPendingTurnThenMatchingTurnFinalizes() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let ownership = session.activeRunOwnership
        session.codexCurrentTurnID = nil
        session.codexCurrentTurnKind = nil
        session.codexTurnKindsByID.removeAll()
        session.codexPendingTurnKind = .user

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "stale-turn", status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunOwnership, ownership)
        XCTAssertEqual(session.codexPendingTurnKind, .user)
        XCTAssertNil(session.codexCurrentTurnID)
        XCTAssertNil(session.codexCurrentTurnKind)
        XCTAssertNil(session.lastTerminalCommitRevision)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "current-turn"),
            session: session
        )

        XCTAssertNil(session.codexPendingTurnKind)
        XCTAssertEqual(session.codexCurrentTurnID, "current-turn")
        XCTAssertEqual(session.codexCurrentTurnKind, .user)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "current-turn", status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .completed)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertNotNil(session.lastTerminalCommitRevision)
    }

    func testMismatchedNonNilCompletionAfterStartPreservesCurrentCorrelation() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let ownership = session.activeRunOwnership

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "different-turn", status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunOwnership, ownership)
        XCTAssertEqual(session.codexCurrentTurnID, "turn")
        XCTAssertEqual(session.codexCurrentTurnKind, .user)
        XCTAssertEqual(session.codexTurnKindsByID["turn"], .user)
        XCTAssertNil(session.lastTerminalCommitRevision)
    }

    func testNilCompletionAfterIdentifiedStartCompletesCurrentTurn() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: nil, status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .completed)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertNil(session.codexCurrentTurnID)
        XCTAssertNil(session.codexCurrentTurnKind)
        XCTAssertNotNil(session.lastTerminalCommitRevision)
    }

    func testNilStartFollowedByNilCompletionCompletesAnonymousTurn() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.codexCurrentTurnID = nil
        session.codexCurrentTurnKind = nil
        session.codexTurnKindsByID.removeAll()
        session.codexPendingTurnKind = .user

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: nil),
            session: session
        )

        XCTAssertNil(session.codexCurrentTurnID)
        XCTAssertEqual(session.codexCurrentTurnKind, .user)
        XCTAssertNil(session.codexPendingTurnKind)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: nil, status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .completed)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertNotNil(session.lastTerminalCommitRevision)
    }

    func testNilCompletionWithoutObservedStartIsRejectedAndPreservesPendingTurn() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let ownership = session.activeRunOwnership
        session.codexCurrentTurnID = nil
        session.codexCurrentTurnKind = nil
        session.codexTurnKindsByID.removeAll()
        session.codexPendingTurnKind = .user

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: nil, status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunOwnership, ownership)
        XCTAssertEqual(session.codexPendingTurnKind, .user)
        XCTAssertNil(session.codexCurrentTurnID)
        XCTAssertNil(session.codexCurrentTurnKind)
        XCTAssertNil(session.lastTerminalCommitRevision)
    }

    func testActiveCodexNativeSendWaitsForAgentRunDrainBeforeSending() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        var drainStarted = false
        var drainContinuation: CheckedContinuation<Bool, Never>?
        let viewModel = makeViewModel(controller: controller) { _, source in
            XCTAssertEqual(source, "codex-native-active-send")
            drainStarted = true
            return await withCheckedContinuation { continuation in
                drainContinuation = continuation
            }
        }
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let runID = try XCTUnwrap(session.runID)

        let sendTask = Task {
            await viewModel.test_codexCoordinator.sendCodexNativeMessage(
                session: session,
                text: "hello",
                attachments: []
            )
        }

        try await waitUntil { drainStarted }
        XCTAssertEqual(controller.sendUserTurnCountSync(), 0)
        XCTAssertEqual(session.runID, runID)

        drainContinuation?.resume(returning: true)
        let outcome = await sendTask.value
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(controller.sendUserTurnCountSync(), 1)
    }

    func testActiveCodexNativeSendFailsWithoutSendingWhenAgentRunDrainFails() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller) { _, _ in false }
        let session = preparedCodexSession(in: viewModel, controller: controller)

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )

        guard case let .failed(message) = outcome else {
            return XCTFail("Expected failed outcome, got \(outcome)")
        }
        XCTAssertTrue(message.contains("agent_run.wait"))
        XCTAssertEqual(controller.sendUserTurnCountSync(), 0)
        XCTAssertEqual(session.runState, .running)
    }

    private func makeViewModel(
        controller: LivenessFakeCodexController,
        drain: AgentModeViewModel.CodexAgentRunWaitDrain? = nil
    ) -> AgentModeViewModel {
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in controller },
            testCodexActiveAgentRunWaitDrain: drain,
            testCodexStallWatchdogPollIntervalNanos: 10_000_000,
            testCodexStallWatchdogProbeThreshold: 0.02,
            testCodexStallWatchdogRecoveryThreshold: 0.02
        )
        viewModel.test_initializeRunService()
        return viewModel
    }

    private func preparedCodexSession(
        in viewModel: AgentModeViewModel,
        controller: LivenessFakeCodexController
    ) -> AgentModeViewModel.TabSession {
        let session = viewModel.session(for: UUID())
        session.selectedAgent = .codexExec
        session.runID = UUID()
        session.runState = .running
        session.beginRunAttempt(source: "test.codexLiveness")
        session.codexController = controller
        session.codexConversationID = "fake"
        session.codexCurrentTurnID = "turn"
        session.codexCurrentTurnKind = .user
        session.codexTurnKindsByID["turn"] = .user
        session.codexControllerGoalSupportEnabled = CodexGoalSupport.isEnabled
        return session
    }

    private func makeUserInputRequest(id: String) -> AgentRequestUserInputRequest {
        AgentRequestUserInputRequest(
            requestID: .string(id),
            method: "request_user_input",
            threadID: "thread",
            turnID: "turn",
            itemID: id,
            questions: [
                AgentRequestUserInputQuestion(
                    id: "question",
                    header: "Question",
                    question: "Continue?",
                    isOther: false,
                    isSecret: false,
                    options: [AgentRequestUserInputOption(label: "Yes", description: "Continue")]
                )
            ]
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

private final class LivenessFakeCodexController: CodexSessionControlling {
    private var readSnapshotCount = 0
    private var sendUserTurnCount = 0
    private let snapshotStatus: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus
    private let snapshotActiveTurnIDs: [String]

    init(
        snapshot: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus,
        activeTurnIDs: [String] = ["turn"]
    ) {
        snapshotStatus = snapshot
        snapshotActiveTurnIDs = activeTurnIDs
    }

    var hasActiveThread: Bool {
        true
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in continuation.finish() }
    }

    func ensureEventsStreamReady() {}

    func readSnapshotCountSync() -> Int {
        readSnapshotCount
    }

    func sendUserTurnCountSync() -> Int {
        sendUserTurnCount
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(
        includeTurns: Bool,
        timeout: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        readSnapshotCount += 1
        return CodexNativeSessionController.ThreadSnapshot(
            conversationID: "fake",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: snapshotStatus,
            currentTurnID: snapshotActiveTurnIDs.first,
            activeTurnIDs: snapshotActiveTurnIDs,
            latestTurnStatus: nil
        )
    }

    func setThreadName(_ name: String, threadID: String?) async throws {}
    func sendUserMessage(_ text: String) async throws {}
    func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {
        sendUserTurnCount += 1
    }

    func sendUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?) async throws {
        sendUserTurnCount += 1
    }

    func sendUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?, serviceTier: String?) async throws {
        sendUserTurnCount += 1
    }

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
