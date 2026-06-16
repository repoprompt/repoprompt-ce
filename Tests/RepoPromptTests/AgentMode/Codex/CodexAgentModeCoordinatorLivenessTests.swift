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

    func testScopedErrorWithoutAuthoritativeIdentityFailsClosed() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.codexAuthoritativeActiveTurn = nil
        let baselineItems = session.items
        let baselineOwnership = session.activeRunOwnership

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "stale fatal error",
                willRetry: false,
                threadID: "fake",
                turnID: "untrusted-routing-turn"
            )),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunOwnership, baselineOwnership)
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
        session.codexAuthoritativeActiveTurn = nil
        session.codexAnonymousActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        session.codexPendingTurnKind = .user

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "stale-turn", status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunOwnership, ownership)
        XCTAssertEqual(session.codexPendingTurnKind, .user)
        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        XCTAssertNil(session.codexAnonymousActiveTurn)
        XCTAssertNil(session.lastTerminalCommitRevision)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "current-turn"),
            session: session
        )

        XCTAssertNil(session.codexPendingTurnKind)
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "current-turn")
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnKind, .user)

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
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "turn")
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnKind, .user)
        XCTAssertNil(session.lastTerminalCommitRevision)
    }

    func testMismatchedStartCannotReplaceAuthoritativeIdentityAndDuplicateIsIdempotent() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let originalIdentity = session.codexAuthoritativeActiveTurn

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "different-turn"),
            session: session
        )

        XCTAssertEqual(session.codexAuthoritativeActiveTurn, originalIdentity)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "turn"),
            session: session
        )

        XCTAssertEqual(session.codexAuthoritativeActiveTurn, originalIdentity)
        XCTAssertEqual(session.runState, .running)
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
        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        XCTAssertNil(session.codexAnonymousActiveTurn)
        XCTAssertNotNil(session.lastTerminalCommitRevision)
    }

    func testNilStartFollowedByNilCompletionCompletesAnonymousTurn() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.codexAuthoritativeActiveTurn = nil
        session.codexAnonymousActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        session.codexPendingTurnKind = .user

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: nil),
            session: session
        )

        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        XCTAssertEqual(session.codexAnonymousActiveTurn?.turnKind, .user)
        XCTAssertNil(session.codexPendingTurnKind)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: nil, status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .completed)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertNil(session.codexAnonymousActiveTurn)
        XCTAssertNotNil(session.lastTerminalCommitRevision)
    }

    func testNilCompletionWithoutObservedStartIsRejectedAndPreservesPendingTurn() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let ownership = session.activeRunOwnership
        session.codexAuthoritativeActiveTurn = nil
        session.codexAnonymousActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        session.codexPendingTurnKind = .user

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: nil, status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunOwnership, ownership)
        XCTAssertEqual(session.codexPendingTurnKind, .user)
        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        XCTAssertNil(session.codexAnonymousActiveTurn)
        XCTAssertNil(session.lastTerminalCommitRevision)
    }

    func testActiveCodexNativeSendUsesRealAgentRunDrainBeforeSending() async throws {
        try await AgentRunWaitDrainTestHarness.withHarness { harness in
            let waitTask = harness.startWait()
            try await harness.waitUntilBlocked()

            let ordering = CodexDrainSendOrderingRecorder()
            let controller = LivenessFakeCodexController(
                snapshot: .active(activeFlags: []),
                onSendUserTurn: { ordering.recordSend() }
            )
            let viewModel = makeViewModel(controller: controller) { runID, source in
                XCTAssertEqual(runID, harness.parentRunID)
                XCTAssertEqual(source, "codex-native-active-send")
                let drained = await harness.drain(source: source)
                ordering.recordDrainCompletion(
                    succeeded: drained,
                    activeScopeCount: harness.activeScopeCount()
                )
                return drained
            }
            let session = preparedCodexSession(
                in: viewModel,
                controller: controller,
                runID: harness.parentRunID
            )
            session.codexRoutingObservedTurnID = "routing-hint-only"

            let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
                session: session,
                text: "hello",
                attachments: []
            )
            let interruptedValue = try await waitTask.value
            let interruptedObject = try XCTUnwrap(interruptedValue.objectValue)
            let completions = await harness.completionRecorder.completions()
            let registrationRemainsActive = await AgentRunSessionStore.hasActiveRegistration(
                sessionID: harness.fixture.sessionID
            )
            let orderingSnapshot = ordering.snapshot()

            XCTAssertEqual(outcome, .sent)
            XCTAssertEqual(
                interruptedObject["wait"]?.objectValue?["result"]?.stringValue,
                "interrupted_by_steering"
            )
            XCTAssertEqual(controller.startUserTurnCountSync(), 0)
            XCTAssertEqual(controller.steerUserTurnIDsSync(), ["turn"])
            XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "turn")
            XCTAssertTrue(orderingSnapshot.drainSucceeded)
            XCTAssertEqual(orderingSnapshot.activeScopeCountAtDrainCompletion, 0)
            XCTAssertTrue(orderingSnapshot.sendObservedAfterDrain)
            XCTAssertEqual(harness.activeScopeCount(), 0)
            XCTAssertEqual(completions.count, 1)
            XCTAssertEqual(completions.first?.result, "interrupted_by_steering")
            XCTAssertTrue(registrationRemainsActive)
        }
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
        XCTAssertEqual(controller.startUserTurnCountSync(), 0)
        XCTAssertTrue(controller.steerUserTurnIDsSync().isEmpty)
        XCTAssertEqual(session.runState, .running)
    }

    func testInactiveCodexNativeSendStartsTurnWithoutInstallingLifecycleIdentity() async {
        let controller = LivenessFakeCodexController(snapshot: .idle, activeTurnIDs: [])
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.runState = .idle
        session.codexAuthoritativeActiveTurn = nil
        session.codexRoutingObservedTurnID = nil

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )

        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(controller.startUserTurnCountSync(), 1)
        XCTAssertTrue(controller.steerUserTurnIDsSync().isEmpty)
        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        XCTAssertEqual(session.codexPendingTurnKind, .user)
    }

    func testActiveCodexNativeSendWithoutExactIdentityQueuesWithoutStarting() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.codexAuthoritativeActiveTurn = nil
        session.codexRoutingObservedTurnID = "routing-only-turn"

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )

        guard case .queuedFallback(_, .activeWithoutAuthoritativeIdentity) = outcome else {
            return XCTFail("Expected missing-identity fallback queue, got \(outcome)")
        }
        XCTAssertEqual(controller.startUserTurnCountSync(), 0)
        XCTAssertTrue(controller.steerUserTurnIDsSync().isEmpty)
        XCTAssertEqual(session.codexFallbackQueue.count, 1)
    }

    func testTypedSteerRejectionReturnsFallbackWithoutReplacingAuthoritativeIdentity() async {
        let failure = CodexAppServerClient.RequestFailure(
            method: "turn/steer",
            code: -32602,
            message: "no active turn to steer",
            data: nil
        )
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            steerError: CodexTurnSteerError.noActiveTurn(failure)
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let identity = session.codexAuthoritativeActiveTurn

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )

        guard case .queuedFallback(_, .noActiveTurn(failure: failure)) = outcome else {
            return XCTFail("Expected no-active fallback queue, got \(outcome)")
        }
        XCTAssertEqual(controller.steerUserTurnIDsSync(), ["turn"])
        XCTAssertEqual(session.codexAuthoritativeActiveTurn, identity)
        XCTAssertEqual(session.codexFallbackQueue.count, 1)
    }

    func testManualTypedFallbackKeepsOptimisticBubbleAndDraft() async throws {
        let failure = CodexAppServerClient.RequestFailure(
            method: "turn/steer",
            code: -32602,
            message: "no active turn to steer",
            data: nil
        )
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            steerError: CodexTurnSteerError.noActiveTurn(failure)
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        viewModel.storeDraftText(for: session.tabID, "restore me")

        let result = viewModel.submitUserTurn(text: "restore me", tabID: session.tabID)

        XCTAssertEqual(result, .submitted)
        try await waitUntil {
            controller.steerUserTurnIDsSync() == ["turn"]
                && session.codexFallbackQueue.count == 1
        }
        XCTAssertEqual(session.items.filter { $0.kind == .user }.map(\.text), ["restore me"])
        XCTAssertEqual(viewModel.retrieveDraftText(for: session.tabID), "restore me")
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "turn")
    }

    func testAcceptedSteerRemainsSentWhenMatchingTurnCompletesBeforeReceiptResumes() async throws {
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            steerDelayNanos: 50_000_000
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let sendTask = Task {
            await viewModel.test_codexCoordinator.sendCodexNativeMessage(
                session: session,
                text: "hello",
                attachments: []
            )
        }
        try await waitUntil {
            controller.steerUserTurnIDsSync() == ["turn"]
        }

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        let outcome = await sendTask.value
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(session.runState, .completed)
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
        controller: LivenessFakeCodexController,
        runID: UUID = UUID()
    ) -> AgentModeViewModel.TabSession {
        let session = viewModel.session(for: UUID())
        session.selectedAgent = .codexExec
        session.runID = runID
        session.runState = .running
        session.beginRunAttempt(source: "test.codexLiveness")
        session.codexController = controller
        session.codexConversationID = "fake"
        session.codexAuthoritativeActiveTurn = .init(
            threadID: "fake",
            turnID: "turn",
            turnKind: .user,
            controllerInstanceID: ObjectIdentifier(controller),
            controllerGeneration: session.codexControllerGeneration,
            runID: runID,
            runAttemptID: session.activeRunAttemptID!
        )
        session.codexRoutingObservedTurnID = "turn"
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

private final class CodexDrainSendOrderingRecorder: @unchecked Sendable {
    struct Snapshot {
        let drainSucceeded: Bool
        let activeScopeCountAtDrainCompletion: Int?
        let sendObservedAfterDrain: Bool
    }

    private let lock = NSLock()
    private var drainSucceeded = false
    private var activeScopeCountAtDrainCompletion: Int?
    private var sendObservedAfterDrain = false

    func recordDrainCompletion(succeeded: Bool, activeScopeCount: Int) {
        lock.lock()
        drainSucceeded = succeeded
        activeScopeCountAtDrainCompletion = activeScopeCount
        lock.unlock()
    }

    func recordSend() {
        lock.lock()
        sendObservedAfterDrain = drainSucceeded && activeScopeCountAtDrainCompletion == 0
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let snapshot = Snapshot(
            drainSucceeded: drainSucceeded,
            activeScopeCountAtDrainCompletion: activeScopeCountAtDrainCompletion,
            sendObservedAfterDrain: sendObservedAfterDrain
        )
        lock.unlock()
        return snapshot
    }
}

private final class LivenessFakeCodexController: CodexSessionControlling {
    private var readSnapshotCount = 0
    private var startUserTurnCount = 0
    private var steerUserTurnIDs: [String] = []
    private let snapshotStatus: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus
    private let snapshotActiveTurnIDs: [String]
    private let onSendUserTurn: (() -> Void)?
    private let steerError: Error?
    private let steerDelayNanos: UInt64

    init(
        snapshot: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus,
        activeTurnIDs: [String] = ["turn"],
        onSendUserTurn: (() -> Void)? = nil,
        steerError: Error? = nil,
        steerDelayNanos: UInt64 = 0
    ) {
        snapshotStatus = snapshot
        snapshotActiveTurnIDs = activeTurnIDs
        self.onSendUserTurn = onSendUserTurn
        self.steerError = steerError
        self.steerDelayNanos = steerDelayNanos
    }

    var hasActiveThread: Bool {
        true
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { _ in }
    }

    func ensureEventsStreamReady() {}

    func readSnapshotCountSync() -> Int {
        readSnapshotCount
    }

    func startUserTurnCountSync() -> Int {
        startUserTurnCount
    }

    func steerUserTurnIDsSync() -> [String] {
        steerUserTurnIDs
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
        recordSendUserTurn()
    }

    func sendUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?) async throws {
        recordSendUserTurn()
    }

    func sendUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?, serviceTier: String?) async throws {
        recordSendUserTurn()
    }

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        recordSendUserTurn()
        startUserTurnCount += 1
        return CodexTurnStartReceipt(provisionalSubmissionID: "liveness-submission-\(startUserTurnCount)")
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        recordSendUserTurn()
        steerUserTurnIDs.append(expectedTurnID)
        if let steerError {
            throw steerError
        }
        if steerDelayNanos > 0 {
            try await Task.sleep(nanoseconds: steerDelayNanos)
        }
        return CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
    }

    private func recordSendUserTurn() {
        onSendUserTurn?()
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
