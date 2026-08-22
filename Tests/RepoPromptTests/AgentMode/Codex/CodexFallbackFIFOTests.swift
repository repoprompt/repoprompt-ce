import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

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
        session.installRunID(nextRunID)
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

    func testIdlePumpDrainsQueueTailInOrderAfterHeadOpensItsOwnTurn() async throws {
        let noActiveTurn = CodexTurnSteerError.noActiveTurn(
            requestFailure(message: "no active turn to steer")
        )
        let controller = FallbackFIFOController(
            snapshot: .idle,
            activeTurnIDs: [],
            steerResults: [.failure(noActiveTurn), .failure(noActiveTurn)]
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

        try await waitUntil { controller.startCount == 1 }
        XCTAssertEqual(session.codexFallbackQueue.count, 1)
        XCTAssertEqual(controller.startedTexts, ["first"])

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "pumped-1"),
            session: session
        )
        XCTAssertEqual(session.codexFallbackQueue.first?.blockingTurn?.turnID, "pumped-1")
        XCTAssertEqual(controller.startCount, 1)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "pumped-1", status: .completed),
            session: session
        )
        try await waitUntil { controller.startCount == 2 }
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        XCTAssertEqual(controller.startedTexts, ["first", "second"])
    }

    // MARK: - Owner-turn binding races

    /// Sequences a hook-gate owner to accept its turn while the pump's thread read is already
    /// in flight, so the pump resumes holding an idle answer that predates the binding.
    private func makeOwnerBindingRaceSession(
        startGate: FallbackAsyncGate? = nil,
        snapshotGate: FallbackAsyncGate? = nil
    ) -> (AgentModeViewModel, AgentModeViewModel.TabSession, FallbackFIFOController) {
        let controller = FallbackFIFOController(
            snapshot: .idle,
            activeTurnIDs: [],
            steerResults: [
                .failure(CodexTurnSteerError.noActiveTurn(
                    requestFailure(message: "no active turn to steer")
                ))
            ],
            startGate: startGate,
            snapshotGate: snapshotGate
        )
        let (viewModel, session) = makeRunningSession(controller: controller)
        session.runState = .idle
        return (viewModel, session, controller)
    }

    func testIdleSnapshotDeliveredAfterOwnerBindingDoesNotReleaseTheQueue() async throws {
        let snapshotGate = FallbackAsyncGate()
        let (viewModel, session, controller) = makeOwnerBindingRaceSession(snapshotGate: snapshotGate)
        session.runState = .running

        let queued = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "queued behind the owner",
            attachments: []
        )
        guard case .queuedFallback = queued else {
            await snapshotGate.release()
            return XCTFail("Expected queued follow-up, got \(queued)")
        }
        guard await snapshotGate.waitUntilWaiting() else {
            return XCTFail("Idle pump did not reach the thread read")
        }

        // The read is now in flight against an unblocked head: the state the pump would
        // otherwise act on when the answer arrives.
        session.codexFallbackQueue[0].blockingTurn = nil
        session.codexAuthoritativeActiveTurn = nil
        session.runState = .idle

        let ownerOutcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "owner start",
            attachments: []
        )
        XCTAssertEqual(ownerOutcome, .sent)
        XCTAssertEqual(controller.startCount, 1)
        let boundTurnID = session.codexFallbackQueue.first?.blockingTurn?.turnID
        XCTAssertEqual(boundTurnID, "submission-1")
        XCTAssertNotNil(session.codexFallbackHookGateOwnerBlocker)

        await snapshotGate.release()
        try await waitUntil { session.codexFallbackPumpTask == nil }

        XCTAssertEqual(controller.startCount, 1)
        XCTAssertEqual(controller.startedTexts, ["owner start"])
        XCTAssertEqual(session.codexFallbackQueue.count, 1)
        XCTAssertEqual(session.codexFallbackQueue.first?.blockingTurn?.turnID, "submission-1")
        XCTAssertNil(session.codexFallbackDispatchInFlight)
    }

    func testOwnerLifecycleCompletingBeforeStartReceiptStillDrainsQueueInOrder() async throws {
        let startGate = FallbackAsyncGate()
        let (viewModel, session, controller) = makeOwnerBindingRaceSession(startGate: startGate)

        let ownerSend = try await startGatedOwnerWithCoalescedFollowUp(
            viewModel: viewModel,
            session: session,
            startGate: startGate
        )

        // Both lifecycle events land while the owner's turn/start call is still outstanding.
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "owner-turn"),
            session: session
        )
        XCTAssertEqual(session.codexFallbackQueue.first?.blockingTurn?.turnID, "owner-turn")
        XCTAssertEqual(controller.startCount, 1)

        // Successor release coalesces behind the very gate this owner still holds, so the
        // completion is delivered now and settles once the outstanding call returns.
        let completion = Task {
            await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
                .turnCompleted(turnID: "owner-turn", status: .completed),
                session: session
            )
        }

        await startGate.release()
        let ownerOutcome = await ownerSend.value
        XCTAssertEqual(ownerOutcome, .sent)
        await completion.value
        try await waitUntil { controller.startCount == 2 }
        try await waitUntil { session.codexFallbackPumpTask == nil }
        XCTAssertEqual(controller.startedTexts, ["owner start", "queued follow-up"])
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        XCTAssertNil(session.codexFallbackHookGateOwnerBlocker)
    }

    func testAnonymousOwnerTurnTerminalRestoresBoundFollowUps() async throws {
        let startGate = FallbackAsyncGate()
        let (viewModel, session, controller) = makeOwnerBindingRaceSession(startGate: startGate)

        let ownerSend = try await startGatedOwnerWithCoalescedFollowUp(
            viewModel: viewModel,
            session: session,
            startGate: startGate
        )

        try await settleGatedOwnerReceipt(
            viewModel: viewModel,
            session: session,
            controller: controller,
            startGate: startGate,
            ownerSend: ownerSend
        )

        // A nil-ID lifecycle can never be matched by successor release, so the follow-up has
        // to come back rather than wait on a turn that is already gone.
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: nil),
            session: session
        )
        XCTAssertEqual(session.codexFallbackQueue.first?.blockingTurn?.turnID, "submission-1")
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: nil, status: .completed),
            session: session
        )

        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        XCTAssertNil(session.codexFallbackHookGateOwnerBlocker)
        XCTAssertNil(session.codexFallbackDispatchInFlight)
        XCTAssertEqual(controller.startCount, 1)
        XCTAssertEqual(controller.startedTexts, ["owner start"])
        let restoration = try XCTUnwrap(viewModel.draftRestorationEvent)
        XCTAssertEqual(restoration.text, "queued follow-up")
    }

    func testAnonymousOwnerTurnInterruptedAbandonsBoundFollowUps() async throws {
        let startGate = FallbackAsyncGate()
        let (viewModel, session, controller) = makeOwnerBindingRaceSession(startGate: startGate)

        let ownerSend = try await startGatedOwnerWithCoalescedFollowUp(
            viewModel: viewModel,
            session: session,
            startGate: startGate
        )

        try await settleGatedOwnerReceipt(
            viewModel: viewModel,
            session: session,
            controller: controller,
            startGate: startGate,
            ownerSend: ownerSend
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: nil),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: nil, status: .interrupted),
            session: session
        )

        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        XCTAssertNil(session.codexFallbackHookGateOwnerBlocker)
        XCTAssertEqual(controller.startCount, 1)
        let restoration = try XCTUnwrap(viewModel.draftRestorationEvent)
        XCTAssertEqual(restoration.tabID, session.tabID)
        XCTAssertEqual(restoration.text, "queued follow-up")
    }

    func testControllerReplacementDuringStartRPCDropsTheOwnerBinding() async throws {
        let startGate = FallbackAsyncGate()
        let (viewModel, session, controller) = makeOwnerBindingRaceSession(startGate: startGate)

        let ownerSend = try await startGatedOwnerWithCoalescedFollowUp(
            viewModel: viewModel,
            session: session,
            startGate: startGate
        )

        // The controller is retired while the request is still outstanding. Its queue is
        // pinned to that instance, so it can never be claimed again under any later lineage.
        viewModel.test_codexCoordinator.test_retireCodexControllerInstance(session: session)

        await startGate.release()
        _ = await ownerSend.value

        try assertFollowUpReturnedToComposer(
            viewModel: viewModel,
            session: session,
            controller: controller
        )
        XCTAssertEqual(controller.startCount, 1)
    }

    /// Drives an owner to the point where it holds the hook gate inside `turn/start` with a
    /// coalesced, unblocked follow-up behind it — the window where the owner has no blocker
    /// yet and the queue has nothing to wait on but the gate.
    private func startGatedOwnerWithCoalescedFollowUp(
        viewModel: AgentModeViewModel,
        session: AgentModeViewModel.TabSession,
        startGate: FallbackAsyncGate
    ) async throws -> Task<CodexAgentModeCoordinator.NativeSendOutcome, Never> {
        let ownerSend = Task {
            await viewModel.test_codexCoordinator.sendCodexNativeMessage(
                session: session,
                text: "owner start",
                attachments: []
            )
        }
        guard await startGate.waitUntilWaiting() else {
            ownerSend.cancel()
            XCTFail("Owner send did not reach turn/start")
            return ownerSend
        }
        let queued = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "queued follow-up",
            attachments: []
        )
        guard case .queuedFallback = queued else {
            ownerSend.cancel()
            await startGate.release()
            XCTFail("Expected queued follow-up, got \(queued)")
            return ownerSend
        }
        // The pump clears the finished fixture turn and then coalesces behind the owner's gate.
        try await waitUntil { session.codexFallbackQueue.first?.blockingTurn == nil }
        return ownerSend
    }

    /// Lets the gated owner's `turn/start` return, which binds the queue to the receipt and
    /// releases the coalesced waiter. Returns once that waiter has run its claim and been
    /// refused, so a scenario can deliver lifecycle events against a settled arrangement.
    private func settleGatedOwnerReceipt(
        viewModel: AgentModeViewModel,
        session: AgentModeViewModel.TabSession,
        controller: FallbackFIFOController,
        startGate: FallbackAsyncGate,
        ownerSend: Task<CodexAgentModeCoordinator.NativeSendOutcome, Never>
    ) async throws {
        await startGate.release()
        let ownerOutcome = await ownerSend.value
        XCTAssertEqual(ownerOutcome, .sent)
        try await waitUntil { session.codexFallbackPumpTask == nil }
        XCTAssertEqual(controller.startCount, 1)
        XCTAssertEqual(session.codexFallbackQueue.first?.blockingTurn?.turnID, "submission-1")
    }

    private func assertFollowUpReturnedToComposer(
        viewModel: AgentModeViewModel,
        session: AgentModeViewModel.TabSession,
        controller: FallbackFIFOController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertTrue(session.codexFallbackQueue.isEmpty, file: file, line: line)
        XCTAssertNil(session.codexFallbackDispatchInFlight, file: file, line: line)
        XCTAssertNil(session.codexFallbackHookGateOwnerBlocker, file: file, line: line)
        XCTAssertEqual(controller.startedTexts, ["owner start"], file: file, line: line)
        let restoration = try XCTUnwrap(viewModel.draftRestorationEvent, file: file, line: line)
        XCTAssertEqual(restoration.tabID, session.tabID, file: file, line: line)
        XCTAssertEqual(restoration.text, "queued follow-up", file: file, line: line)
    }

    func testAnonymousOwnerLifecycleBeforeStartReceiptReturnsFollowUpToComposer() async throws {
        let startGate = FallbackAsyncGate()
        let (viewModel, session, controller) = makeOwnerBindingRaceSession(startGate: startGate)
        let ownerSend = try await startGatedOwnerWithCoalescedFollowUp(
            viewModel: viewModel,
            session: session,
            startGate: startGate
        )

        // Both nil-ID events land while the owner's turn/start is still outstanding, so no
        // blocker exists yet and no identity will ever exist to release the queue.
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: nil),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: nil, status: .completed),
            session: session
        )
        try assertFollowUpReturnedToComposer(
            viewModel: viewModel,
            session: session,
            controller: controller
        )

        await startGate.release()
        let ownerOutcome = await ownerSend.value
        XCTAssertEqual(ownerOutcome, .sent)
        try assertFollowUpReturnedToComposer(
            viewModel: viewModel,
            session: session,
            controller: controller
        )
        XCTAssertEqual(controller.startCount, 1)
    }

    func testServerRequestIssueBeforeAuthoritativeStartReturnsFollowUpToComposer() async throws {
        let startGate = FallbackAsyncGate()
        let (viewModel, session, controller) = makeOwnerBindingRaceSession(startGate: startGate)
        let ownerSend = try await startGatedOwnerWithCoalescedFollowUp(
            viewModel: viewModel,
            session: session,
            startGate: startGate
        )

        // Terminalizes the run directly: no turnCompleted is ever correlated for this turn.
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .serverRequestIssue(.init(
                requestID: .int(1),
                method: "applyPatchApproval",
                kind: .unsupportedMethod,
                message: "server request issue"
            )),
            session: session
        )
        try assertFollowUpReturnedToComposer(
            viewModel: viewModel,
            session: session,
            controller: controller
        )

        await startGate.release()
        let ownerOutcome = await ownerSend.value
        XCTAssertEqual(ownerOutcome, .sent)
        try assertFollowUpReturnedToComposer(
            viewModel: viewModel,
            session: session,
            controller: controller
        )
        XCTAssertEqual(controller.startCount, 1)
    }

    func testIdlePumpFallbackWaitsForHookReviewBeforeClaimingHeadOrAttachments() async throws {
        let image = AgentImageAttachment(
            source: .localFile(path: "/tmp/idle-hook-gate.png"),
            title: "idle-hook-gate.png"
        )
        let reservationID = UUID()
        let controller = try FallbackFIFOController(
            snapshot: .idle,
            activeTurnIDs: [],
            steerResults: [
                .failure(CodexTurnSteerError.noActiveTurn(
                    requestFailure(message: "no active turn to steer")
                ))
            ],
            hookInventory: fallbackHookInventory()
        )
        let (viewModel, session) = makeRunningSession(controller: controller)
        let originalAttemptID = session.activeRunAttemptID
        session.attachmentTurnState = .reserved(
            reservationID: reservationID,
            attachments: [image]
        )
        let context = fallbackContext(
            queueID: UUID(),
            origin: .manual,
            text: "idle gated fallback",
            images: [image]
        )

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: context.providerText,
            attachments: [image],
            fallbackContext: context,
            attachmentReservationID: reservationID
        )
        guard case .queuedFallback = outcome else {
            return XCTFail("Expected queued fallback, got \(outcome)")
        }
        let request = try await waitForHookRequest(session)

        XCTAssertEqual(controller.hookListCount, 1)
        XCTAssertEqual(controller.startCount, 0)
        XCTAssertEqual(session.codexFallbackQueue.first?.state, .queued)
        XCTAssertNil(session.codexFallbackDispatchInFlight)
        XCTAssertEqual(session.activeRunAttemptID, originalAttemptID)
        guard case .idle = session.attachmentTurnState else {
            return XCTFail("Fallback attachments must remain detached while review is suspended")
        }

        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: request.id,
            decision: .continueWithoutHooks
        )
        try await waitUntil { controller.startCount == 1 }
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        XCTAssertNotNil(session.codexFallbackDispatchInFlight)
        XCTAssertEqual(session.activeRunAttemptID, originalAttemptID)
        guard case let .consumed(storedID, attachments) = session.attachmentTurnState else {
            return XCTFail("Claimed idle fallback must consume its attachment reservation")
        }
        XCTAssertEqual(storedID, reservationID)
        XCTAssertEqual(attachments, [image])
    }

    func testFollowUpDuringInitialHookDiscoveryCoalescesGateAndPreservesRun() async throws {
        let discoveryGate = FallbackAsyncGate()
        let dispatchGate = FallbackAsyncGate()
        let controller = try FallbackFIFOController(
            snapshot: .idle,
            activeTurnIDs: [],
            steerResults: [
                .failure(CodexTurnSteerError.noActiveTurn(
                    requestFailure(message: "no active turn to steer")
                ))
            ],
            startGate: dispatchGate,
            hookInventory: fallbackHookInventory(),
            hookListGate: discoveryGate
        )
        let (viewModel, session) = makeRunningSession(controller: controller)
        let runID = session.runID
        session.runState = .idle

        let initialSend = Task {
            await viewModel.test_codexCoordinator.sendCodexNativeMessage(
                session: session,
                text: "initial gated send",
                attachments: []
            )
        }
        guard await discoveryGate.waitUntilWaiting() else {
            initialSend.cancel()
            return XCTFail("Initial send did not enter hook discovery")
        }

        let followUp = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "queued while discovery is active",
            attachments: [],
            fallbackContext: fallbackContext(
                queueID: UUID(),
                origin: .manual,
                text: "queued while discovery is active"
            )
        )
        guard case .queuedFallback = followUp else {
            initialSend.cancel()
            await discoveryGate.release()
            return XCTFail("Expected queued follow-up, got \(followUp)")
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.hookListCount, 1)

        await discoveryGate.release()
        let request = try await waitForHookRequest(session)
        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: request.id,
            decision: .continueWithoutHooks
        )

        guard await dispatchGate.waitUntilWaiting() else {
            initialSend.cancel()
            return XCTFail("Initial gated send did not reach turn/start")
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.startedTexts, ["initial gated send"])
        XCTAssertEqual(session.codexFallbackQueue.count, 1)

        await dispatchGate.release()
        let initialOutcome = await initialSend.value
        XCTAssertEqual(initialOutcome, .sent)

        // The pump task only finishes once the resumed waiter has run its claim, so waiting
        // on it proves the claim path executed and was refused rather than merely delayed.
        try await waitUntil { session.codexFallbackPumpTask == nil }
        XCTAssertEqual(controller.startCount, 1)
        XCTAssertEqual(controller.startedTexts, ["initial gated send"])
        XCTAssertNil(session.codexFallbackDispatchInFlight)
        XCTAssertEqual(session.codexFallbackQueue.count, 1)
        XCTAssertEqual(session.codexFallbackQueue.first?.state, .queued)
        XCTAssertEqual(
            session.codexFallbackQueue.first?.blockingTurn?.turnID,
            "submission-1"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "initial-turn"),
            session: session
        )
        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "initial-turn")
        XCTAssertEqual(
            session.codexFallbackQueue.first?.blockingTurn?.turnID,
            "initial-turn"
        )
        XCTAssertEqual(controller.startCount, 1)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "initial-turn", status: .completed),
            session: session
        )
        try await waitUntil { controller.startCount == 2 }
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        XCTAssertEqual(session.runID, runID)
        XCTAssertEqual(controller.hookListCount, 1)
        XCTAssertEqual(session.codexHookGateGeneration, 1)
        XCTAssertEqual(
            controller.startedTexts,
            ["initial gated send", "queued while discovery is active"]
        )
    }

    func testTerminalSuccessorFallbackWaitsForHookReviewBeforeSuccessorClaim() async throws {
        let image = AgentImageAttachment(
            source: .localFile(path: "/tmp/successor-hook-gate.png"),
            title: "successor-hook-gate.png"
        )
        let reservationID = UUID()
        let nonSteerable = CodexTurnSteerError.activeTurnNotSteerable(
            turnKind: "compact",
            failure: requestFailure(message: "cannot steer a compact turn")
        )
        let controller = try FallbackFIFOController(
            steerResults: [.failure(nonSteerable)],
            hookInventory: fallbackHookInventory()
        )
        let (viewModel, session) = makeRunningSession(controller: controller)
        let originalAttemptID = session.activeRunAttemptID
        session.attachmentTurnState = .reserved(
            reservationID: reservationID,
            attachments: [image]
        )
        let context = fallbackContext(
            queueID: UUID(),
            origin: .manual,
            text: "successor gated fallback",
            images: [image]
        )

        _ = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: context.providerText,
            attachments: [image],
            fallbackContext: context,
            attachmentReservationID: reservationID
        )
        let completion = Task {
            await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
                .turnCompleted(turnID: "turn", status: .completed),
                session: session
            )
        }
        let request = try await waitForHookRequest(session)

        XCTAssertEqual(controller.hookListCount, 1)
        XCTAssertEqual(controller.startCount, 0)
        XCTAssertEqual(session.codexFallbackQueue.first?.state, .queued)
        XCTAssertNil(session.codexFallbackDispatchInFlight)
        XCTAssertEqual(session.activeRunAttemptID, originalAttemptID)
        guard case .idle = session.attachmentTurnState else {
            return XCTFail("Successor attachments must remain detached while review is suspended")
        }

        try await viewModel.test_codexCoordinator.resolveCodexHookReview(
            session: session,
            requestID: request.id,
            decision: .continueWithoutHooks
        )
        await completion.value
        try await waitUntil { controller.startCount == 1 }
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        let inFlight = try XCTUnwrap(session.codexFallbackDispatchInFlight)
        XCTAssertNotEqual(session.activeRunAttemptID, originalAttemptID)
        XCTAssertEqual(inFlight.attachmentReservationID, reservationID)
        XCTAssertEqual(inFlight.images, [image])
    }

    func testDurablyQueuedMCPFallbackInterruptsWaiterOnlyAfterQueueAck() async throws {
        let steerGate = FallbackAsyncGate()
        let controller = FallbackFIFOController(
            snapshot: .idle,
            activeTurnIDs: [],
            steerResults: [
                .failure(CodexTurnSteerError.noActiveTurn(
                    requestFailure(message: "no active turn to steer")
                ))
            ],
            steerGate: steerGate
        )
        let (viewModel, session, sessionID) = try await makeMCPRunningSession(controller: controller)
        let context = try XCTUnwrap(session.mcpControlContext)
        defer {
            Task {
                await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
            }
        }
        let cursor = AgentRunSessionStore.WaitCursor(
            registration: context.registration,
            epoch: context.currentEpoch
        )
        let wait = Task.detached {
            await AgentRunSessionStore.waitUntilInteresting(cursor: cursor, timeoutSeconds: 5)
        }

        let dispatch = Task {
            try await viewModel.mcpDispatchInstruction(
                sessionID: sessionID,
                text: "start after idle",
                allowStartingRun: false
            )
        }
        guard await steerGate.waitUntilWaiting() else {
            dispatch.cancel()
            return XCTFail("Codex steer did not reach the gated provider path")
        }
        let prematureDisposition = await AgentRunSessionStore.waitUntilInteresting(
            cursor: cursor,
            timeoutSeconds: 0.05
        )
        assertDidNotReleaseAsSteering(prematureDisposition, sessionID: sessionID)
        XCTAssertTrue(
            session.codexFallbackQueue.isEmpty,
            "The fallback should not be visible before the provider failure is converted into a durable queue entry."
        )

        await steerGate.release()
        let delivery = try await dispatch.value
        XCTAssertEqual(delivery, .queuedFollowUp)
        let attemptID = try XCTUnwrap(session.codexSteerAckTracker.test_latestAttemptID)
        let terminalState = await session.codexSteerAckTracker.awaitTerminalState(attemptID: attemptID)
        guard case .durablyQueued = terminalState else {
            return XCTFail("Expected durable queue acknowledgement for MCP fallback, got \(terminalState)")
        }
        let disposition = await wait.value
        assertAcceptedDispatchReleasedWaiter(
            disposition,
            sessionID: sessionID,
            expectedSteeringMessage: "start after idle"
        )
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
        let startGate = FallbackAsyncGate()
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
        let startGate = FallbackAsyncGate()
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
        let startGate = FallbackAsyncGate()
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
        session.deferredActiveAgentRunTimerRollback = .init(
            originalStartedAt: Date(timeIntervalSinceNow: -60)
        )

        viewModel.clearChat(tabID: session.tabID)

        let terminalState = await session.codexSteerAckTracker.awaitTerminalState(
            attemptID: attemptID,
            timeoutSeconds: 0.1
        )
        XCTAssertEqual(terminalState, .durablyQueued(queueID: queueID))
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        XCTAssertNil(session.codexFallbackDispatchInFlight)
        XCTAssertTrue(session.items.isEmpty)
        XCTAssertNil(session.deferredActiveAgentRunTimerRollback)
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
        session.installRunID(runID)
        session.runState = .running
        session.beginRunAttempt(source: "test.codexFallback")
        session.codexController = controller
        session.codexControllerPermissionProfile = session.permissionProfile
        session.codexControllerTaskLabelKind = session.mcpControlContext?.taskLabelKind
        session.codexControllerWorkspacePaths = .uniform(nil)
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
        session.codexControllerFeatureState = .init(
            computerUseEnabled: false,
            goalSupportEnabled: CodexGoalSupport.isEnabled,
            reasoningSummariesEnabled: CodexReasoningSummaries.isEnabled,
            memoriesEnabled: CodexMemories.isEnabled
        )
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
        session.installRunID(runID)
        session.runState = .running
        session.beginRunAttempt(source: "test.codexFallback.mcp")
        session.codexController = controller
        session.codexControllerPermissionProfile = session.permissionProfile
        session.codexControllerTaskLabelKind = session.mcpControlContext?.taskLabelKind
        session.codexControllerWorkspacePaths = .uniform(nil)
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
        session.codexControllerFeatureState = .init(
            computerUseEnabled: false,
            goalSupportEnabled: CodexGoalSupport.isEnabled,
            reasoningSummariesEnabled: CodexReasoningSummaries.isEnabled,
            memoriesEnabled: CodexMemories.isEnabled
        )
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
            workspacePaths: .uniform("/tmp/workspace"),
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
        text: String,
        images: [AgentImageAttachment] = []
    ) -> AgentModeViewModel.TabSession.CodexFallbackSubmissionContext {
        .init(
            queueID: queueID,
            providerText: text,
            images: images,
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

    private func assertAcceptedDispatchReleasedWaiter(
        _ disposition: AgentRunSessionStore.WaitDisposition,
        sessionID: UUID,
        expectedSteeringMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch disposition {
        case let .noteworthySnapshot(wake):
            XCTAssertEqual(wake.reason, .steeringRequested, file: file, line: line)
            XCTAssertEqual(wake.snapshot.sessionID, sessionID, file: file, line: line)
            XCTAssertEqual(wake.steeringMessage, expectedSteeringMessage, file: file, line: line)
        case let .snapshotReady(snapshot):
            XCTAssertEqual(snapshot.sessionID, sessionID, file: file, line: line)
        default:
            XCTFail("Expected accepted dispatch to release waiter, got \(disposition)", file: file, line: line)
        }
    }

    private func assertDidNotReleaseAsSteering(
        _ disposition: AgentRunSessionStore.WaitDisposition,
        sessionID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case let .noteworthySnapshot(wake) = disposition,
           wake.reason == .steeringRequested
        {
            XCTAssertEqual(wake.snapshot.sessionID, sessionID, file: file, line: line)
            XCTFail("Codex fallback must not release waiters as steeringRequested before durable queue ack", file: file, line: line)
        }
    }

    private func assertSteeringRequested(
        _ disposition: AgentRunSessionStore.WaitDisposition,
        sessionID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .noteworthySnapshot(wake) = disposition else {
            return XCTFail("Expected steering wake, got \(disposition)", file: file, line: line)
        }
        XCTAssertEqual(wake.reason, .steeringRequested, file: file, line: line)
        XCTAssertEqual(wake.snapshot.sessionID, sessionID, file: file, line: line)
    }

    private func fallbackHookInventory() throws -> CodexHookInventory {
        try CodexHookInventory(
            executionCWD: "/repo",
            hooks: [
                CodexHookMetadata(
                    eventName: "PreToolUse",
                    source: "project",
                    sourcePath: "/repo/.codex/config.toml",
                    key: "fallback-hook",
                    currentHash: "fallback-hash",
                    enabled: true,
                    handlerType: "command",
                    trustStatus: .untrusted,
                    commandOrHandler: "./hooks/fallback"
                )
            ]
        )
    }

    private func waitForHookRequest(
        _ session: AgentModeViewModel.TabSession,
        timeout: TimeInterval = 2
    ) async throws -> AgentCodexHookReviewRequest {
        try await waitForPendingCodexHookReview(
            in: session,
            timeout: timeout,
            diagnostic: "Timed out waiting for fallback hook review"
        )
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
    private let startGate: FallbackAsyncGate?
    private let steerGate: FallbackAsyncGate?
    private let snapshotGate: FallbackAsyncGate?
    private let hookInventory: CodexHookInventory?
    private let hookListGate: FallbackAsyncGate?

    private(set) var steerTurnIDs: [String] = []
    private(set) var startedTexts: [String] = []
    private(set) var startCount = 0
    private(set) var hookListCount = 0
    private(set) var hasActiveThread = true

    init(
        snapshot: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus = .active(activeFlags: []),
        activeTurnIDs: [String] = ["turn"],
        snapshotResults: [Result<CodexNativeSessionController.ThreadSnapshot, Error>] = [],
        steerResults: [Result<CodexTurnSteerReceipt, Error>],
        startGate: FallbackAsyncGate? = nil,
        steerGate: FallbackAsyncGate? = nil,
        snapshotGate: FallbackAsyncGate? = nil,
        hookInventory: CodexHookInventory? = nil,
        hookListGate: FallbackAsyncGate? = nil
    ) {
        self.snapshot = snapshot
        self.activeTurnIDs = activeTurnIDs
        self.snapshotResults = snapshotResults
        self.steerResults = steerResults
        self.startGate = startGate
        self.steerGate = steerGate
        self.snapshotGate = snapshotGate
        self.hookInventory = hookInventory
        self.hookListGate = hookListGate
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
        // Held after the answer is determined, so the caller observes a read that was issued
        // against one state and delivered against another.
        await snapshotGate?.wait()
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
        text: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        startedTexts.append(text)
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
        await steerGate?.wait()
        guard !steerResults.isEmpty else {
            return .init(acceptedTurnID: expectedTurnID)
        }
        return try steerResults.removeFirst().get()
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        .init(interruptedTurnID: expectedTurnID)
    }

    func compactThread() async throws {}

    func listHooksForCurrentWorkspace() async throws -> CodexHookInventory {
        hookListCount += 1
        await hookListGate?.wait()
        if let hookInventory {
            return hookInventory
        }
        return try CodexHookInventory(executionCWD: "/tmp", hooks: [])
    }

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

private actor FallbackAsyncGate {
    // A gated call can be entered more than once concurrently — an owner turn and the queued
    // follow-up released behind it both sit on the same gate — so every waiter is retained.
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var waiting = false

    func wait() async {
        guard !released else { return }
        waiting = true
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitUntilWaiting(timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if waiting { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return waiting
    }

    func release() {
        released = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
