@testable import RepoPrompt
import XCTest

@MainActor
final class CodexSteerAckTrackerTests: XCTestCase {
    func testOverlappingAttemptsAuthorizeAndResolveIndependently() async {
        let tracker = CodexSteerAckTracker()
        let first = tracker.beginAttempt()
        let second = tracker.beginAttempt()

        let firstDispatch = Task { await tracker.awaitDispatchAuthorization(attemptID: first) }
        let secondDispatch = Task { await tracker.awaitDispatchAuthorization(attemptID: second) }
        tracker.authorizeDispatch(attemptID: second)

        let secondAuthorized = await secondDispatch.value
        XCTAssertTrue(secondAuthorized)
        XCTAssertFalse(firstDispatch.isCancelled)

        tracker.resolve(attemptID: second, state: .durablyQueued(queueID: UUID()))
        tracker.authorizeDispatch(attemptID: first)
        tracker.resolve(attemptID: first, state: .steerAccepted)

        let firstAuthorized = await firstDispatch.value
        let firstState = await tracker.awaitTerminalState(attemptID: first)
        let secondState = await tracker.awaitTerminalState(attemptID: second)
        XCTAssertTrue(firstAuthorized)
        XCTAssertEqual(firstState, .steerAccepted)
        guard case .durablyQueued = secondState else {
            return XCTFail("Expected the second attempt to retain its own queued resolution")
        }
    }

    func testTimeoutTombstoneIgnoresLateResolution() async {
        let tracker = CodexSteerAckTracker()
        let attemptID = tracker.beginAttempt()
        tracker.authorizeDispatch(attemptID: attemptID)

        let result = await tracker.awaitTerminalState(
            attemptID: attemptID,
            timeoutSeconds: 0.1
        )
        XCTAssertEqual(result, .timedOut)

        tracker.resolve(attemptID: attemptID, state: .steerAccepted)
        let lateState = await tracker.awaitTerminalState(attemptID: attemptID)
        XCTAssertEqual(lateState, .timedOut)
    }

    func testCancellationUnblocksDispatchAndTombstonesAttempt() async {
        let tracker = CodexSteerAckTracker()
        let attemptID = tracker.beginAttempt()
        let dispatch = Task { await tracker.awaitDispatchAuthorization(attemptID: attemptID) }

        tracker.cancel(attemptID: attemptID)

        let authorized = await dispatch.value
        let cancelledState = await tracker.awaitTerminalState(attemptID: attemptID)
        XCTAssertFalse(authorized)
        XCTAssertEqual(cancelledState, .cancelled)
        tracker.resolve(attemptID: attemptID, state: .startAccepted)
        let lateState = await tracker.awaitTerminalState(attemptID: attemptID)
        XCTAssertEqual(lateState, .cancelled)
    }

    func testCancellingAwaitTombstonesOnlyMatchingAttemptAndIgnoresLateResolution() async {
        let tracker = CodexSteerAckTracker()
        let cancelledAttempt = tracker.beginAttempt()
        let survivingAttempt = tracker.beginAttempt()

        let cancelledWait = Task {
            await tracker.awaitTerminalState(
                attemptID: cancelledAttempt,
                timeoutSeconds: 10
            )
        }
        let survivingWait = Task {
            await tracker.awaitTerminalState(
                attemptID: survivingAttempt,
                timeoutSeconds: 10
            )
        }
        await Task.yield()
        cancelledWait.cancel()

        let cancelledState = await cancelledWait.value
        XCTAssertEqual(cancelledState, .cancelled)
        tracker.resolve(attemptID: cancelledAttempt, state: .steerAccepted)
        tracker.resolve(attemptID: survivingAttempt, state: .startAccepted)

        let lateCancelledState = await tracker.awaitTerminalState(
            attemptID: cancelledAttempt
        )
        let survivingState = await survivingWait.value
        XCTAssertEqual(lateCancelledState, .cancelled)
        XCTAssertEqual(survivingState, .startAccepted)
    }

    func testCancellingMCPDispatchTombstonesItsAttemptBeforeLateProviderAcceptance() async throws {
        let gate = AckTrackerSteerGate()
        let controller = AckTrackerCodexController(gate: gate)
        let (viewModel, session, sessionID, registration) = try await makeMCPRunningSession(
            controller: controller,
            source: "test.mcpAckCancellation"
        )
        defer {
            Task {
                await AgentRunSessionStore.cleanup(registration: registration)
            }
        }

        let dispatch = Task {
            try await viewModel.mcpDispatchInstruction(
                sessionID: sessionID,
                text: "cancel this dispatch",
                allowStartingRun: false
            )
        }
        guard await gate.waitUntilStarted() else {
            dispatch.cancel()
            do {
                let result = try await dispatch.value
                return XCTFail(
                    """
                    MCP dispatch completed before provider steering: \(result); \
                    fallback=\(String(describing: session.codexFallbackQueue.first?.fallbackReason)); \
                    authority=\(String(describing: session.codexAuthoritativeActiveTurn)); \
                    runState=\(session.runState); runAttempt=\(String(describing: session.activeRunAttemptID))
                    """
                )
            } catch {
                return XCTFail("MCP dispatch failed before provider steering: \(error)")
            }
        }
        let attemptID = try XCTUnwrap(session.codexSteerAckTracker.test_latestAttemptID)
        XCTAssertTrue(
            session.codexSteerAckTracker.test_openAttemptIDs.contains(attemptID),
            "Expected the MCP dispatch attempt to remain open before cancellation."
        )

        dispatch.cancel()
        let attemptCancelledByProductionPath = await waitUntil {
            !session.codexSteerAckTracker.test_openAttemptIDs.contains(attemptID)
        }
        XCTAssertTrue(
            attemptCancelledByProductionPath,
            "Expected cancellation to tombstone the MCP dispatch attempt."
        )
        await gate.release()
        do {
            _ = try await dispatch.value
            XCTFail("Expected MCP dispatch cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTAssertTrue(String(describing: error).contains("cancelled"), String(describing: error))
        }
        let cancelledState = await session.codexSteerAckTracker.awaitTerminalState(
            attemptID: attemptID
        )
        XCTAssertEqual(cancelledState, .cancelled)

        let providerCompleted = await gate.waitUntilCompleted()
        XCTAssertTrue(providerCompleted)
        let lateState = await session.codexSteerAckTracker.awaitTerminalState(
            attemptID: attemptID
        )
        XCTAssertEqual(lateState, .cancelled)
    }

    func testActiveMCPWaiterIsNotInterruptedBeforeCodexProviderAck() async throws {
        let gate = AckTrackerSteerGate()
        let controller = AckTrackerCodexController(gate: gate)
        let (viewModel, session, sessionID, registration) = try await makeMCPRunningSession(
            controller: controller,
            source: "test.codexAckDelayedWake"
        )
        defer {
            Task {
                await AgentRunSessionStore.cleanup(registration: registration)
            }
        }
        let cursor = AgentRunSessionStore.WaitCursor(
            registration: registration,
            epoch: session.mcpControlContext?.currentEpoch
        )
        let wait = await AckTrackerWaiterStarter().start(cursor: cursor, timeoutSeconds: 5)

        let dispatch = Task {
            try await viewModel.mcpDispatchInstruction(
                sessionID: sessionID,
                text: "ack before wake",
                allowStartingRun: false
            )
        }
        guard await gate.waitUntilStarted() else {
            dispatch.cancel()
            return XCTFail("Provider steer was not reached")
        }
        let prematureDisposition = await AgentRunSessionStore.waitUntilInteresting(
            cursor: cursor,
            timeoutSeconds: 0.05
        )
        assertDidNotReleaseAsSteering(prematureDisposition, sessionID: sessionID)

        await gate.release()
        let delivery = try await dispatch.value
        XCTAssertEqual(delivery, .dispatchedCodexTurn)
        let disposition = await wait.value
        assertAcceptedDispatchReleasedWaiter(disposition, sessionID: sessionID)
    }

    func testAcceptedCodexAckAfterRunReplacementDoesNotWakeReplacementWaiters() async throws {
        let gate = AckTrackerSteerGate()
        let controller = AckTrackerCodexController(gate: gate)
        let (viewModel, session, sessionID, registration) = try await makeMCPRunningSession(
            controller: controller,
            source: "test.codexAckReplacementNoWake"
        )
        defer {
            Task {
                await AgentRunSessionStore.cleanup(registration: registration)
            }
        }
        let cursor = AgentRunSessionStore.WaitCursor(
            registration: registration,
            epoch: session.mcpControlContext?.currentEpoch
        )
        let wait = await AckTrackerWaiterStarter().start(cursor: cursor, timeoutSeconds: 0.2)

        let dispatch = Task {
            try await viewModel.mcpDispatchInstruction(
                sessionID: sessionID,
                text: "ack after replacement",
                allowStartingRun: false
            )
        }
        guard await gate.waitUntilStarted() else {
            dispatch.cancel()
            return XCTFail("Provider steer was not reached")
        }

        let replacementController = AckTrackerCodexController(gate: AckTrackerSteerGate())
        let replacementRunID = UUID()
        session.runID = replacementRunID
        session.runState = .running
        session.beginRunAttempt(source: "test.codexAckReplacementNoWake.replacement")
        session.codexController = replacementController
        session.codexConversationID = "replacement-thread"
        session.codexAuthoritativeActiveTurn = try .init(
            threadID: "replacement-thread",
            turnID: "replacement-turn",
            turnKind: .user,
            controllerInstanceID: ObjectIdentifier(replacementController),
            controllerGeneration: session.codexControllerGeneration,
            runID: replacementRunID,
            runAttemptID: XCTUnwrap(session.activeRunAttemptID)
        )
        session.codexRoutingObservedTurnID = "replacement-turn"
        session.codexControllerFeatureState = .init(
            computerUseEnabled: false,
            goalSupportEnabled: CodexGoalSupport.isEnabled,
            reasoningSummariesEnabled: CodexReasoningSummaries.isEnabled
        )

        await gate.release()
        let delivery = try await dispatch.value
        XCTAssertEqual(delivery, .dispatchedCodexTurn)

        let disposition = await wait.value
        assertDidNotReleaseAsSteering(disposition, sessionID: sessionID)
    }

    func testFailedActiveCodexMCPAckDoesNotInterruptExistingWaiter() async throws {
        let gate = AckTrackerSteerGate()
        let controller = AckTrackerCodexController(
            gate: gate,
            steerResult: .failure(AckTrackerTestError.providerRejected)
        )
        let (viewModel, session, sessionID, registration) = try await makeMCPRunningSession(
            controller: controller,
            source: "test.codexAckFailureNoWake"
        )
        defer {
            Task {
                await AgentRunSessionStore.cleanup(registration: registration)
            }
        }
        let cursor = AgentRunSessionStore.WaitCursor(
            registration: registration,
            epoch: session.mcpControlContext?.currentEpoch
        )
        let wait = await AckTrackerWaiterStarter().start(cursor: cursor, timeoutSeconds: 0.2)

        let dispatch = Task {
            try await viewModel.mcpDispatchInstruction(
                sessionID: sessionID,
                text: "failed steer",
                allowStartingRun: false
            )
        }
        guard await gate.waitUntilStarted() else {
            dispatch.cancel()
            return XCTFail("Provider steer was not reached")
        }
        let prematureDisposition = await AgentRunSessionStore.waitUntilInteresting(
            cursor: cursor,
            timeoutSeconds: 0.05
        )
        assertDidNotReleaseAsSteering(prematureDisposition, sessionID: sessionID)

        await gate.release()
        do {
            _ = try await dispatch.value
            XCTFail("Expected Codex steer failure to be reported to the MCP caller")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("provider rejected steer"),
                String(describing: error)
            )
        }
        XCTAssertFalse(
            session.items.filter { $0.kind == .user }.map(\.text).contains("failed steer"),
            "The optimistic MCP Codex user bubble should be removed when the steer never reaches Codex."
        )

        let disposition = await wait.value
        assertDidNotReleaseAsSteering(disposition, sessionID: sessionID)
    }

    func testTerminalStateClassifiesConfirmedDeliveryAndFailureDescriptions() {
        let queueID = UUID()
        XCTAssertTrue(CodexSteerAckTracker.TerminalState.steerAccepted.confirmsInstructionDeliveryOrDurableQueue)
        XCTAssertTrue(CodexSteerAckTracker.TerminalState.startAccepted.confirmsInstructionDeliveryOrDurableQueue)
        XCTAssertTrue(CodexSteerAckTracker.TerminalState.controlAccepted.confirmsInstructionDeliveryOrDurableQueue)
        XCTAssertTrue(CodexSteerAckTracker.TerminalState.durablyQueued(queueID: queueID).confirmsInstructionDeliveryOrDurableQueue)
        XCTAssertFalse(CodexSteerAckTracker.TerminalState.failed(message: "nope").confirmsInstructionDeliveryOrDurableQueue)
        XCTAssertFalse(CodexSteerAckTracker.TerminalState.cancelled.confirmsInstructionDeliveryOrDurableQueue)
        XCTAssertFalse(CodexSteerAckTracker.TerminalState.stale(reason: "changed").confirmsInstructionDeliveryOrDurableQueue)
        XCTAssertFalse(CodexSteerAckTracker.TerminalState.timedOut.confirmsInstructionDeliveryOrDurableQueue)
        XCTAssertEqual(
            CodexSteerAckTracker.TerminalState.failed(message: "").failureDescriptionForMCP,
            "Codex steer failed before reaching the active run."
        )
        XCTAssertEqual(
            CodexSteerAckTracker.TerminalState.stale(reason: "").failureDescriptionForMCP,
            "Codex steer was dropped because the active run changed before delivery."
        )
    }

    private func makeMCPRunningSession(
        controller: AckTrackerCodexController,
        source: String
    ) async throws -> (
        AgentModeViewModel,
        AgentModeViewModel.TabSession,
        UUID,
        AgentRunSessionStore.Registration
    ) {
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in controller }
        )
        viewModel.test_initializeRunService()
        let tabID = UUID()
        let sessionID = UUID()
        let session = viewModel.session(for: tabID)
        let runID = UUID()
        session.testInstallPersistentSessionBinding(sessionID: sessionID)
        session.hasLoadedPersistedState = true
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        let activationID = UUID()
        let epochResult = await AgentRunSessionStore.beginEpoch(
            registration: registration,
            activationID: activationID,
            expectedCurrentEpoch: nil,
            transitionKind: .initial
        )
        let currentEpoch: AgentRunTurnEpoch?
        switch epochResult {
        case let .accepted(epoch):
            currentEpoch = epoch
        case let .stale(epoch):
            currentEpoch = epoch
        case let .rejected(reason):
            XCTFail("Failed to start MCP wait epoch: \(reason)")
            throw CancellationError()
        }
        session.mcpControlContext = .init(
            sessionID: sessionID,
            activationID: activationID,
            registration: registration,
            currentEpoch: currentEpoch,
            preparedEpoch: nil,
            pendingEpochTransition: nil,
            originatingConnectionID: nil,
            interactionTransport: .mcp(
                sessionID: sessionID,
                originatingConnectionID: nil
            ),
            suppressUserNotifications: true,
            forceAutoEditEnabled: false,
            autoEditEnabledBeforeOverride: true,
            taskLabelKind: nil
        )
        viewModel.test_setMCPControlledTabIDs([tabID])
        session.selectedAgent = .codexExec
        session.runID = runID
        session.runState = .running
        session.beginRunAttempt(source: source)
        session.codexController = controller
        session.codexSteerAckTracker.test_setTerminalStateTimeoutSeconds(30)
        session.codexConversationID = "thread"
        session.codexAuthoritativeActiveTurn = try .init(
            threadID: "thread",
            turnID: "turn",
            turnKind: .user,
            controllerInstanceID: ObjectIdentifier(controller),
            controllerGeneration: session.codexControllerGeneration,
            runID: runID,
            runAttemptID: XCTUnwrap(session.activeRunAttemptID)
        )
        session.codexRoutingObservedTurnID = "turn"
        session.codexControllerFeatureState = .init(
            computerUseEnabled: false,
            goalSupportEnabled: CodexGoalSupport.isEnabled,
            reasoningSummariesEnabled: CodexReasoningSummaries.isEnabled
        )
        controller.onEnsureEventsStreamReady = { [weak session, weak controller] in
            guard let session, let controller,
                  let runID = session.runID,
                  let runAttemptID = session.activeRunAttemptID
            else { return }
            session.codexAuthoritativeActiveTurn = .init(
                threadID: "thread",
                turnID: "turn",
                turnKind: .user,
                controllerInstanceID: ObjectIdentifier(controller),
                controllerGeneration: session.codexControllerGeneration,
                runID: runID,
                runAttemptID: runAttemptID
            )
            session.codexRoutingObservedTurnID = "turn"
        }
        return (viewModel, session, sessionID, registration)
    }

    private func assertAcceptedDispatchReleasedWaiter(
        _ disposition: AgentRunSessionStore.WaitDisposition,
        sessionID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch disposition {
        case let .noteworthySnapshot(snapshot, .steeringRequested),
             let .snapshotReady(snapshot):
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
        if case let .noteworthySnapshot(snapshot, reason) = disposition,
           reason == .steeringRequested
        {
            XCTAssertEqual(snapshot.sessionID, sessionID, file: file, line: line)
            XCTFail("Failed Codex steer must not release waiters as steeringRequested", file: file, line: line)
        }
    }

    private func assertSteeringRequested(
        _ disposition: AgentRunSessionStore.WaitDisposition,
        sessionID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .noteworthySnapshot(snapshot, reason) = disposition else {
            return XCTFail("Expected steering wake, got \(disposition)", file: file, line: line)
        }
        XCTAssertEqual(reason, .steeringRequested, file: file, line: line)
        XCTAssertEqual(snapshot.sessionID, sessionID, file: file, line: line)
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    func testSerialDispatchGatePreservesIssuedOrderAcrossSuspension() async {
        let gate = AgentModeViewModel.TabSession.CodexDispatchSerialGate()
        let first = gate.issueTicket()
        let second = gate.issueTicket()
        let firstEntered = await gate.awaitTurn(first)
        XCTAssertTrue(firstEntered)

        var secondEntered = false
        let secondTask = Task { @MainActor in
            guard await gate.awaitTurn(second) else { return }
            secondEntered = true
        }
        await Task.yield()
        XCTAssertFalse(secondEntered)

        gate.finish(first)
        _ = await secondTask.value
        XCTAssertTrue(secondEntered)
        gate.finish(second)
    }
}

private actor AckTrackerWaiterStarter {
    func start(
        cursor: AgentRunSessionStore.WaitCursor,
        timeoutSeconds: TimeInterval
    ) -> Task<AgentRunSessionStore.WaitDisposition, Never> {
        Task {
            await AgentRunSessionStore.waitUntilInteresting(
                cursor: cursor,
                timeoutSeconds: timeoutSeconds
            )
        }
    }
}

private enum AckTrackerTestError: LocalizedError {
    case providerRejected

    var errorDescription: String? {
        switch self {
        case .providerRejected:
            "provider rejected steer"
        }
    }
}

private final class AckTrackerCodexController: CodexSessionControlling {
    private let gate: AckTrackerSteerGate
    private let steerResult: Result<CodexTurnSteerReceipt, Error>?
    private(set) var hasActiveThread = true
    var onEnsureEventsStreamReady: (() -> Void)?

    init(
        gate: AckTrackerSteerGate,
        steerResult: Result<CodexTurnSteerReceipt, Error>? = nil
    ) {
        self.gate = gate
        self.steerResult = steerResult
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { _ in }
    }

    func ensureEventsStreamReady() {
        MainActor.assumeIsolated {
            onEnsureEventsStreamReady?()
        }
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(
            conversationID: "thread",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil
        )
    }

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        .init(provisionalSubmissionID: "submission")
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        await gate.block()
        if let steerResult {
            return try steerResult.get()
        }
        return .init(acceptedTurnID: expectedTurnID)
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

private actor AckTrackerSteerGate {
    private static let waitPollLimit = 5000

    private var started = false
    private var completed = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func block() async {
        started = true
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        completed = true
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0 ..< Self.waitPollLimit {
            if started { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return started
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func waitUntilCompleted() async -> Bool {
        for _ in 0 ..< Self.waitPollLimit {
            if completed { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return completed
    }
}
