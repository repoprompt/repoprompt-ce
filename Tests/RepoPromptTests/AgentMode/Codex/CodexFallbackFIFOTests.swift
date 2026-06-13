import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class CodexFallbackFIFOTests: XCTestCase {
    func testMismatchRetriesOnceWithActualIDThenQueuesExactlyOnce() async {
        let firstFailure = requestFailure(
            message: "expected turn mismatch",
            data: .object(["actualTurnId": .string("actual-turn")])
        )
        let controller = FallbackFIFOController(
            steerResults: [
                .failure(CodexTurnSteerError.expectedTurnMismatch(
                    expectedTurnID: "turn",
                    actualTurnID: "actual-turn",
                    failure: firstFailure
                )),
                .failure(CodexTurnSteerError.activeTurnNotSteerable(
                    turnKind: "review",
                    failure: requestFailure(message: "cannot steer a review turn")
                ))
            ]
        )
        let (viewModel, session) = makeRunningSession(controller: controller)

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "retry me",
            attachments: []
        )

        guard case let .queuedFallback(queueID, reason) = outcome else {
            return XCTFail("Expected durable fallback queue insertion, got \(outcome)")
        }
        XCTAssertEqual(controller.steerTurnIDs, ["turn", "actual-turn"])
        XCTAssertEqual(session.codexFallbackQueue.map(\.id), [queueID])
        XCTAssertEqual(session.codexFallbackQueue.first?.fallbackReason, reason)
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "turn")
    }

    func testSteerAcceptedIntoDifferentTurnReconcilesWithoutResend() async {
        let controller = FallbackFIFOController(
            steerResults: [.success(.init(acceptedTurnID: "actual-turn"))]
        )
        let (viewModel, session) = makeRunningSession(controller: controller)

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "steer me",
            attachments: []
        )

        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(controller.steerTurnIDs, ["turn"])
        XCTAssertEqual(controller.startCount, 0)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        XCTAssertEqual(session.codexPendingSteerLifecycleReconciliation?.priorIdentity.turnID, "turn")
        XCTAssertEqual(
            session.codexPendingSteerLifecycleReconciliation?.acceptedDispatchTurnID,
            "actual-turn"
        )
    }

    func testMismatchRetrySuccessReconcilesOnlyWhenActualLifecycleCompletes() async {
        let mismatch = requestFailure(message: "expected turn mismatch")
        let controller = FallbackFIFOController(
            steerResults: [
                .failure(CodexTurnSteerError.expectedTurnMismatch(
                    expectedTurnID: "turn",
                    actualTurnID: "actual-turn",
                    failure: mismatch
                )),
                .success(CodexTurnSteerReceipt(acceptedTurnID: "actual-turn"))
            ]
        )
        let (viewModel, session) = makeRunningSession(controller: controller)

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "retry succeeds",
            attachments: []
        )

        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(controller.steerTurnIDs, ["turn", "actual-turn"])
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "turn")
        XCTAssertEqual(
            session.codexPendingSteerLifecycleReconciliation?.acceptedDispatchTurnID,
            "actual-turn"
        )
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "actual-turn", status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .completed)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        XCTAssertNil(session.codexPendingSteerLifecycleReconciliation)
        XCTAssertNotNil(session.lastTerminalCommitRevision)
    }

    func testMismatchRetryAcceptedThenActualStartReconcilesRealControllerForExactCancellation() async {
        let recorder = MismatchRetryNativeControllerRecorder()
        let controller = makeNativeController(recorder: recorder)
        controller.test_installThreadState(
            threadID: "thread",
            authoritativeTurnID: "turn",
            routingTurnID: "turn"
        )
        let (viewModel, session) = makeRunningSession(controller: controller)

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "retry against actual",
            attachments: []
        )

        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(controller.test_authoritativeLifecycleTurnID, "turn")
        await controller.test_handleNotification(
            method: "turn/started",
            params: lifecycleParams(turnID: "actual-turn")
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "actual-turn"),
            session: session
        )

        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "actual-turn")
        XCTAssertEqual(controller.test_authoritativeLifecycleTurnID, "actual-turn")

        await viewModel.test_codexCoordinator.cancelCodexRun(session)

        XCTAssertEqual(recorder.interruptedTurnIDs, ["actual-turn"])
    }

    func testMismatchRetryAcceptedThenActualCompletionClearsRealControllerForReuse() async throws {
        let recorder = MismatchRetryNativeControllerRecorder()
        let controller = makeNativeController(recorder: recorder)
        controller.test_installThreadState(
            threadID: "thread",
            authoritativeTurnID: "turn",
            routingTurnID: "turn"
        )
        let (viewModel, session) = makeRunningSession(controller: controller)

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "complete actual",
            attachments: []
        )
        XCTAssertEqual(outcome, .sent)

        await controller.test_handleNotification(
            method: "turn/completed",
            params: lifecycleParams(turnID: "actual-turn", status: "completed")
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "actual-turn", status: .completed),
            session: session
        )

        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        XCTAssertNil(controller.test_authoritativeLifecycleTurnID)

        let nextRunID = UUID()
        session.runID = nextRunID
        session.runState = .running
        session.beginRunAttempt(source: "test.codexFallback.reuse")
        session.codexPendingTurnKind = .user
        await controller.test_handleNotification(
            method: "turn/started",
            params: lifecycleParams(turnID: "next-turn")
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "next-turn"),
            session: session
        )

        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "next-turn")
        XCTAssertEqual(controller.test_authoritativeLifecycleTurnID, "next-turn")
        let receipt = try await controller.interruptUserTurn(expectedTurnID: "next-turn")
        XCTAssertEqual(receipt.interruptedTurnID, "next-turn")
        XCTAssertEqual(recorder.interruptedTurnIDs, ["next-turn"])
    }

    func testNoActiveFallbackAcknowledgesQueueThenIdlePumpStartsHead() async throws {
        let controller = FallbackFIFOController(
            snapshot: .idle,
            activeTurnIDs: [],
            steerResults: [
                .failure(CodexTurnSteerError.noActiveTurn(
                    requestFailure(message: "no active turn to steer")
                ))
            ]
        )
        let (viewModel, session) = makeRunningSession(controller: controller)
        let attemptID = session.codexSteerAckTracker.beginAttempt()
        let queueID = UUID()
        let context = fallbackContext(
            queueID: queueID,
            origin: .mcp(attemptID: attemptID),
            text: "start after idle"
        )

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: context.providerText,
            attachments: [],
            fallbackContext: context
        )

        let ackState = await session.codexSteerAckTracker.awaitTerminalState(
            attemptID: attemptID
        )
        XCTAssertEqual(ackState, .durablyQueued(queueID: queueID))
        guard case .queuedFallback(queueID: queueID, reason: .noActiveTurn) = outcome else {
            return XCTFail("Expected typed no-active queue outcome, got \(outcome)")
        }
        try await waitUntil {
            controller.startCount == 1
                && session.codexFallbackQueue.isEmpty
                && session.codexFallbackDispatchInFlight?.id == queueID
        }
        XCTAssertNil(session.codexAuthoritativeActiveTurn)
    }

    func testNoActiveFallbackRetriesTransientSnapshotFailure() async throws {
        let idleSnapshot = CodexNativeSessionController.ThreadSnapshot(
            conversationID: "thread",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
        let controller = FallbackFIFOController(
            snapshotResults: [
                .failure(FallbackFIFOTestError.transientSnapshotFailure),
                .success(idleSnapshot)
            ],
            steerResults: [
                .failure(CodexTurnSteerError.noActiveTurn(
                    requestFailure(message: "no active turn to steer")
                ))
            ]
        )
        let (viewModel, session) = makeRunningSession(controller: controller)

        _ = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "retry snapshot",
            attachments: []
        )

        try await waitUntil { controller.startCount == 1 }
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
    }

    func testMatchingCompletionAndPublicationDrainExactlyOneThenTailWaitsForSuccessor() async throws {
        let nonSteerable = CodexTurnSteerError.activeTurnNotSteerable(
            turnKind: "compact",
            failure: requestFailure(message: "cannot steer a compact turn")
        )
        let controller = FallbackFIFOController(
            steerResults: [.failure(nonSteerable), .failure(nonSteerable)]
        )
        let (viewModel, session) = makeRunningSession(controller: controller)

        _ = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "first",
            attachments: []
        )
        _ = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "second",
            attachments: []
        )
        XCTAssertEqual(session.codexFallbackQueue.count, 2)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )
        try await waitUntil { controller.startCount == 1 }
        XCTAssertEqual(session.codexFallbackQueue.count, 1)
        XCTAssertNotNil(session.codexFallbackDispatchInFlight)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )
        XCTAssertEqual(controller.startCount, 1)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "successor-1"),
            session: session
        )
        XCTAssertNil(session.codexFallbackDispatchInFlight)
        XCTAssertEqual(session.codexFallbackQueue.first?.blockingTurn?.turnID, "successor-1")

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "successor-1", status: .completed),
            session: session
        )
        try await waitUntil { controller.startCount == 2 }
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
    }

    func testPublishedSuccessorClaimsHeadBeforeProviderStartReturns() async throws {
        let startGate = FallbackStartGate()
        let nonSteerable = CodexTurnSteerError.activeTurnNotSteerable(
            turnKind: "compact",
            failure: requestFailure(message: "cannot steer a compact turn")
        )
        let controller = FallbackFIFOController(
            steerResults: [.failure(nonSteerable), .failure(nonSteerable)],
            startGate: startGate
        )
        let (viewModel, session) = makeRunningSession(controller: controller)

        _ = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "claim before await",
            attachments: []
        )
        _ = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "tail",
            attachments: []
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        try await waitUntil { controller.startCount == 1 }
        XCTAssertEqual(session.codexFallbackQueue.count, 1)
        XCTAssertEqual(session.codexFallbackDispatchInFlight?.state, .dispatching)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "successor-before-receipt"),
            session: session
        )
        XCTAssertEqual(session.codexFallbackQueue.first?.blockingTurn?.turnID, "successor-before-receipt")

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "successor-before-receipt", status: .completed),
            session: session
        )
        XCTAssertEqual(controller.startCount, 1)

        await startGate.release()
        try await waitUntil { controller.startCount == 2 }
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
    }

    func testManualFallbackQueuedDuringDispatchingRebindsToObservedSuccessor() async throws {
        let startGate = FallbackStartGate()
        let nonSteerable = CodexTurnSteerError.activeTurnNotSteerable(
            turnKind: "compact",
            failure: requestFailure(message: "cannot steer a compact turn")
        )
        let controller = FallbackFIFOController(
            steerResults: [.failure(nonSteerable)],
            startGate: startGate
        )
        let (viewModel, session) = makeRunningSession(controller: controller)

        _ = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "first",
            attachments: []
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )
        try await waitUntil {
            session.codexFallbackDispatchInFlight?.state == .dispatching
        }

        _ = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "manual during dispatch",
            attachments: []
        )
        XCTAssertEqual(session.codexFallbackQueue.first?.blockingTurn?.turnID, "turn")

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "successor-dispatching"),
            session: session
        )
        XCTAssertEqual(session.codexFallbackQueue.first?.blockingTurn?.turnID, "successor-dispatching")

        await startGate.release()
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "successor-dispatching", status: .completed),
            session: session
        )
        try await waitUntil { controller.startCount == 2 }
    }

    func testMCPFallbackQueuedWhileAwaitingLifecycleStartRebindsAndDrains() async throws {
        let startGate = FallbackStartGate()
        let nonSteerable = CodexTurnSteerError.activeTurnNotSteerable(
            turnKind: "compact",
            failure: requestFailure(message: "cannot steer a compact turn")
        )
        let controller = FallbackFIFOController(
            steerResults: [.failure(nonSteerable)],
            startGate: startGate
        )
        let (viewModel, session) = makeRunningSession(controller: controller)

        _ = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "first",
            attachments: []
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )
        try await waitUntil { controller.startCount == 1 }
        await startGate.release()
        try await waitUntil {
            session.codexFallbackDispatchInFlight?.state == .awaitingLifecycleStart
        }

        let attemptID = session.codexSteerAckTracker.beginAttempt()
        let queueID = UUID()
        let context = fallbackContext(
            queueID: queueID,
            origin: .mcp(attemptID: attemptID),
            text: "mcp while awaiting lifecycle"
        )
        _ = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: context.providerText,
            attachments: [],
            fallbackContext: context
        )
        let terminalState = await session.codexSteerAckTracker.awaitTerminalState(
            attemptID: attemptID
        )
        XCTAssertEqual(terminalState, .durablyQueued(queueID: queueID))
        XCTAssertEqual(session.codexFallbackQueue.first?.blockingTurn?.turnID, "turn")

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "successor-awaiting"),
            session: session
        )
        XCTAssertEqual(session.codexFallbackQueue.first?.blockingTurn?.turnID, "successor-awaiting")

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "successor-awaiting", status: .completed),
            session: session
        )
        try await waitUntil { controller.startCount == 2 }
    }

    func testRejectedTerminalPublicationRetriesAndThenStartsEligibleSuccessor() async throws {
        let nonSteerable = CodexTurnSteerError.activeTurnNotSteerable(
            turnKind: "compact",
            failure: requestFailure(message: "cannot steer a compact turn")
        )
        let controller = FallbackFIFOController(
            steerResults: [.failure(nonSteerable)]
        )
        let (viewModel, session) = makeRunningSession(controller: controller)
        var publicationAttempts = 0
        viewModel.test_setTerminalPublicationOverride { _, _, _ in
            publicationAttempts += 1
            return publicationAttempts == 1
                ? .rejected(reason: "transient")
                : .accepted(successorEpoch: nil)
        }

        _ = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "publish then retry",
            attachments: []
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        try await waitUntil {
            publicationAttempts == 2 && controller.startCount == 1
        }
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
    }

    func testTransientPublicationRetryStopsAndAbandonsQueueWhenMCPControlDeactivates() async throws {
        let controller = FallbackFIFOController(
            steerResults: [
                .failure(CodexTurnSteerError.activeTurnNotSteerable(
                    turnKind: "compact",
                    failure: requestFailure(message: "cannot steer a compact turn")
                ))
            ]
        )
        let (viewModel, session, sessionID) = try await makeMCPRunningSession(controller: controller)
        var publicationAttempts = 0
        viewModel.test_setTerminalPublicationOverride { _, _, _ in
            publicationAttempts += 1
            return .rejected(reason: "transient")
        }

        let attemptID = session.codexSteerAckTracker.beginAttempt()
        let context = fallbackContext(
            queueID: UUID(),
            origin: .mcp(attemptID: attemptID),
            text: "deactivate while retrying"
        )
        _ = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: context.providerText,
            attachments: [],
            fallbackContext: context
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )
        try await waitUntil {
            publicationAttempts >= 2 && session.codexFallbackSuccessorRetryTask != nil
        }

        await viewModel.mcpDeactivateControlContext(
            sessionID: sessionID,
            cleanupSessionStore: true
        )
        let attemptsAfterDeactivation = publicationAttempts
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(publicationAttempts, attemptsAfterDeactivation)
        XCTAssertNil(session.codexFallbackSuccessorRetryTask)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        XCTAssertNil(session.codexFallbackDispatchInFlight)
        XCTAssertNil(session.mcpControlContext)
        XCTAssertEqual(controller.startCount, 0)
    }

    func testTransientPublicationRetryStopsAndAbandonsQueueWhenMCPControlIsReplaced() async throws {
        let controller = FallbackFIFOController(
            steerResults: [
                .failure(CodexTurnSteerError.activeTurnNotSteerable(
                    turnKind: "compact",
                    failure: requestFailure(message: "cannot steer a compact turn")
                ))
            ]
        )
        let (viewModel, session, sessionID) = try await makeMCPRunningSession(controller: controller)
        let originalActivationID = try XCTUnwrap(session.mcpControlContext?.activationID)
        var publicationAttempts = 0
        viewModel.test_setTerminalPublicationOverride { _, _, _ in
            publicationAttempts += 1
            return .rejected(reason: "transient")
        }

        _ = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "replace while retrying",
            attachments: []
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )
        try await waitUntil {
            publicationAttempts >= 2 && session.codexFallbackSuccessorRetryTask != nil
        }

        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil
        )
        let attemptsAfterReplacement = publicationAttempts
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNotEqual(session.mcpControlContext?.activationID, originalActivationID)
        XCTAssertEqual(publicationAttempts, attemptsAfterReplacement)
        XCTAssertNil(session.codexFallbackSuccessorRetryTask)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        XCTAssertNil(session.codexFallbackDispatchInFlight)
        XCTAssertEqual(controller.startCount, 0)
        await viewModel.mcpDeactivateControlContext(
            sessionID: sessionID,
            cleanupSessionStore: true
        )
    }

    func testMissingTerminalPublicationEnvelopePermanentlyAbandonsEligibleQueue() async throws {
        let controller = FallbackFIFOController(
            steerResults: [
                .failure(CodexTurnSteerError.activeTurnNotSteerable(
                    turnKind: "compact",
                    failure: requestFailure(message: "cannot steer a compact turn")
                ))
            ]
        )
        let (viewModel, session, sessionID) = try await makeMCPRunningSession(
            controller: controller,
            prepareEpoch: false
        )

        let attemptID = session.codexSteerAckTracker.beginAttempt()
        let context = fallbackContext(
            queueID: UUID(),
            origin: .mcp(attemptID: attemptID),
            text: "missing envelope"
        )
        _ = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: context.providerText,
            attachments: [],
            fallbackContext: context
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        XCTAssertEqual(
            session.lastTerminalPublicationResult,
            .rejected(reason: "missing_terminal_publication_envelope")
        )
        XCTAssertNil(session.codexFallbackSuccessorRetryTask)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        XCTAssertNil(session.codexFallbackDispatchInFlight)
        XCTAssertEqual(controller.startCount, 0)
        await viewModel.mcpDeactivateControlContext(
            sessionID: sessionID,
            cleanupSessionStore: true
        )
    }

    func testNilCompletionDoesNotDrainAndFailedCompletionAbandonsBlockedHead() async throws {
        let controller = FallbackFIFOController(
            steerResults: [
                .failure(CodexTurnSteerError.activeTurnNotSteerable(
                    turnKind: "review",
                    failure: requestFailure(message: "cannot steer a review turn")
                ))
            ]
        )
        let (nilViewModel, nilSession) = makeRunningSession(controller: controller)
        _ = await nilViewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: nilSession,
            text: "nil completion",
            attachments: []
        )

        await nilViewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: nil, status: .completed),
            session: nilSession
        )
        XCTAssertEqual(controller.startCount, 0)
        XCTAssertEqual(nilSession.codexFallbackQueue.count, 1)
        XCTAssertEqual(nilSession.runState, .running)
        XCTAssertEqual(nilSession.codexAuthoritativeActiveTurn?.turnID, "turn")

        await nilViewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: nilSession
        )
        try await waitUntil { controller.startCount == 1 }
        XCTAssertTrue(nilSession.codexFallbackQueue.isEmpty)

        let failedController = FallbackFIFOController(
            steerResults: [
                .failure(CodexTurnSteerError.activeTurnNotSteerable(
                    turnKind: "review",
                    failure: requestFailure(message: "cannot steer a review turn")
                )),
                .failure(CodexTurnSteerError.activeTurnNotSteerable(
                    turnKind: "review",
                    failure: requestFailure(message: "cannot steer a review turn")
                ))
            ]
        )
        let (failedViewModel, failedSession) = makeRunningSession(controller: failedController)
        _ = await failedViewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: failedSession,
            text: "failed completion",
            attachments: []
        )
        _ = await failedViewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: failedSession,
            text: "failed completion tail",
            attachments: []
        )
        XCTAssertEqual(failedSession.codexFallbackQueue.count, 2)

        await failedViewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .failed),
            session: failedSession
        )
        XCTAssertEqual(failedController.startCount, 0)
        XCTAssertTrue(failedSession.codexFallbackQueue.isEmpty)
    }

    func testManualFallbackKeepsSingleOptimisticBubbleAndDoesNotRestoreDraft() async throws {
        let controller = FallbackFIFOController(
            steerResults: [
                .failure(CodexTurnSteerError.activeTurnNotSteerable(
                    turnKind: "review",
                    failure: requestFailure(message: "cannot steer a review turn")
                ))
            ]
        )
        let (viewModel, session) = makeRunningSession(controller: controller)
        viewModel.storeDraftText(for: session.tabID, "queued manual")
        let userItem = AgentChatItem.user(
            "queued manual",
            sequenceIndex: session.nextSequenceIndex
        )
        session.appendItem(userItem)
        let context = AgentModeViewModel.TabSession.CodexFallbackSubmissionContext(
            queueID: UUID(),
            providerText: "queued manual",
            images: [],
            taggedFileAttachments: [],
            draftText: "queued manual",
            optimisticUserItemID: userItem.id,
            origin: .manual,
            dispatchTicket: nil
        )

        _ = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "queued manual",
            attachments: [],
            fallbackContext: context
        )

        XCTAssertEqual(session.items.filter { $0.kind == .user }.map(\.text), ["queued manual"])
        XCTAssertEqual(viewModel.retrieveDraftText(for: session.tabID), "queued manual")

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )
        try await waitUntil { controller.startCount == 1 }
        XCTAssertEqual(session.items.filter { $0.kind == .user }.map(\.text), ["queued manual"])
    }

    func testClearChatDiscardsFallbackInputWithoutReversingDeliveryAcknowledgement() async {
        let controller = FallbackFIFOController(
            steerResults: [
                .failure(CodexTurnSteerError.activeTurnNotSteerable(
                    turnKind: "review",
                    failure: requestFailure(message: "cannot steer a review turn")
                ))
            ]
        )
        let (viewModel, session) = makeRunningSession(controller: controller)
        let attemptID = session.codexSteerAckTracker.beginAttempt()
        let queueID = UUID()
        let context = fallbackContext(
            queueID: queueID,
            origin: .mcp(attemptID: attemptID),
            text: "discarded queued input"
        )

        _ = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "discarded queued input",
            attachments: [],
            fallbackContext: context
        )
        XCTAssertEqual(session.codexFallbackQueue.count, 1)

        viewModel.clearChat(tabID: session.tabID)

        let terminalState = await session.codexSteerAckTracker.awaitTerminalState(
            attemptID: attemptID,
            timeoutSeconds: 0.1
        )
        XCTAssertEqual(terminalState, .durablyQueued(queueID: queueID))
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        XCTAssertNil(session.codexFallbackDispatchInFlight)
        XCTAssertTrue(session.items.isEmpty)
        XCTAssertNil(viewModel.draftRestorationEvent)
    }

    private func makeRunningSession(
        controller: any CodexSessionControlling
    ) -> (AgentModeViewModel, AgentModeViewModel.TabSession) {
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in controller }
        )
        viewModel.test_initializeRunService()
        let session = viewModel.session(for: UUID())
        let runID = UUID()
        session.selectedAgent = .codexExec
        session.runID = runID
        session.runState = .running
        session.beginRunAttempt(source: "test.codexFallback")
        session.codexController = controller
        session.codexConversationID = "thread"
        session.codexAuthoritativeActiveTurn = .init(
            threadID: "thread",
            turnID: "turn",
            turnKind: .user,
            controllerInstanceID: ObjectIdentifier(controller),
            controllerGeneration: session.codexControllerGeneration,
            runID: runID,
            runAttemptID: session.activeRunAttemptID!
        )
        session.codexRoutingObservedTurnID = "turn"
        session.codexControllerGoalSupportEnabled = CodexGoalSupport.isEnabled
        return (viewModel, session)
    }

    private func makeMCPRunningSession(
        controller: any CodexSessionControlling,
        prepareEpoch: Bool = true
    ) async throws -> (AgentModeViewModel, AgentModeViewModel.TabSession, UUID) {
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in controller }
        )
        viewModel.test_initializeRunService()
        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            startPending: true
        )
        if prepareEpoch {
            await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        }
        let runID = UUID()
        session.selectedAgent = .codexExec
        session.runID = runID
        session.runState = .running
        session.beginRunAttempt(source: "test.codexFallback.mcp")
        session.codexController = controller
        session.codexConversationID = "thread"
        session.codexAuthoritativeActiveTurn = .init(
            threadID: "thread",
            turnID: "turn",
            turnKind: .user,
            controllerInstanceID: ObjectIdentifier(controller),
            controllerGeneration: session.codexControllerGeneration,
            runID: runID,
            runAttemptID: session.activeRunAttemptID!
        )
        session.codexRoutingObservedTurnID = "turn"
        session.codexControllerGoalSupportEnabled = CodexGoalSupport.isEnabled
        return (viewModel, session, sessionID)
    }

    private func makeNativeController(
        recorder: MismatchRetryNativeControllerRecorder
    ) -> CodexNativeSessionController {
        CodexNativeSessionController(
            client: CodexAppServerClient(),
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: "/tmp/workspace",
            requestExecutor: { method, params, timeout in
                try recorder.handle(method: method, params: params, timeout: timeout)
            }
        )
    }

    private func lifecycleParams(
        turnID: String,
        status: String? = nil
    ) -> [String: CodexJSONValue] {
        var turn: [String: CodexJSONValue] = ["id": .string(turnID)]
        if let status {
            turn["status"] = .string(status)
        }
        return [
            "threadId": .string("thread"),
            "turn": .object(turn)
        ]
    }

    private func fallbackContext(
        queueID: UUID,
        origin: AgentModeViewModel.TabSession.CodexFallbackOrigin,
        text: String
    ) -> AgentModeViewModel.TabSession.CodexFallbackSubmissionContext {
        .init(
            queueID: queueID,
            providerText: text,
            images: [],
            taggedFileAttachments: [],
            draftText: text,
            optimisticUserItemID: nil,
            origin: origin,
            dispatchTicket: nil
        )
    }

    private func requestFailure(
        message: String,
        data: CodexJSONValue? = nil
    ) -> CodexAppServerClient.RequestFailure {
        .init(method: "turn/steer", code: -32602, message: message, data: data)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for Codex fallback FIFO state")
    }
}

private final class FallbackFIFOController: CodexSessionControlling {
    private let snapshot: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus
    private let activeTurnIDs: [String]
    private var snapshotResults: [Result<CodexNativeSessionController.ThreadSnapshot, Error>]
    private var steerResults: [Result<CodexTurnSteerReceipt, Error>]
    private let startGate: FallbackStartGate?

    private(set) var steerTurnIDs: [String] = []
    private(set) var startCount = 0
    private(set) var hasActiveThread = true

    init(
        snapshot: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus = .active(activeFlags: []),
        activeTurnIDs: [String] = ["turn"],
        snapshotResults: [Result<CodexNativeSessionController.ThreadSnapshot, Error>] = [],
        steerResults: [Result<CodexTurnSteerReceipt, Error>],
        startGate: FallbackStartGate? = nil
    ) {
        self.snapshot = snapshot
        self.activeTurnIDs = activeTurnIDs
        self.snapshotResults = snapshotResults
        self.steerResults = steerResults
        self.startGate = startGate
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { _ in }
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
        .init(
            conversationID: "thread",
            rolloutPath: nil,
            model: model,
            reasoningEffort: reasoningEffort
        )
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        if !snapshotResults.isEmpty {
            return try snapshotResults.removeFirst().get()
        }
        return .init(
            conversationID: "thread",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: snapshot,
            currentTurnID: activeTurnIDs.first,
            activeTurnIDs: activeTurnIDs,
            latestTurnStatus: nil
        )
    }

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        startCount += 1
        await startGate?.wait()
        return .init(provisionalSubmissionID: "submission-\(startCount)")
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        steerTurnIDs.append(expectedTurnID)
        guard !steerResults.isEmpty else {
            return .init(acceptedTurnID: expectedTurnID)
        }
        return try steerResults.removeFirst().get()
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        .init(interruptedTurnID: expectedTurnID)
    }

    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(
        _: CodexNativeSessionController.ThreadGoalStatus
    ) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}

private enum FallbackFIFOTestError: Error {
    case transientSnapshotFailure
}

private final class MismatchRetryNativeControllerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var steerAttemptCount = 0
    private var recordedInterruptedTurnIDs: [String] = []

    var interruptedTurnIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInterruptedTurnIDs
    }

    func handle(
        method: String,
        params: [String: Any]?,
        timeout _: TimeInterval?
    ) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        switch method {
        case "turn/steer":
            steerAttemptCount += 1
            if steerAttemptCount == 1 {
                let failure = CodexAppServerClient.RequestFailure(
                    method: method,
                    code: -32602,
                    message: "expected active turn id `turn` but found `actual-turn`",
                    data: .object(["actualTurnId": .string("actual-turn")])
                )
                throw CodexAppServerClient.ClientError.requestFailed(failure)
            }
            return ["turnId": params?["expectedTurnId"] as? String ?? ""]
        case "turn/interrupt":
            if let turnID = params?["turnId"] as? String {
                recordedInterruptedTurnIDs.append(turnID)
            }
            return [:]
        default:
            return [:]
        }
    }
}

private actor FallbackStartGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
