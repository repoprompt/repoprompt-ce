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
        defer {
            Task {
                await AgentRunSessionStore.cleanup(registration: registration)
            }
        }
        session.mcpControlContext = .init(
            sessionID: sessionID,
            activationID: UUID(),
            registration: registration,
            currentEpoch: nil,
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
        session.beginRunAttempt(source: "test.mcpAckCancellation")
        session.codexController = controller
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
        session.codexControllerGoalSupportEnabled = CodexGoalSupport.isEnabled
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

        dispatch.cancel()
        do {
            _ = try await dispatch.value
            XCTFail("Expected MCP dispatch cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let cancelledState = await session.codexSteerAckTracker.awaitTerminalState(
            attemptID: attemptID
        )
        XCTAssertEqual(cancelledState, .cancelled)

        await gate.release()
        let providerCompleted = await gate.waitUntilCompleted()
        XCTAssertTrue(providerCompleted)
        let lateState = await session.codexSteerAckTracker.awaitTerminalState(
            attemptID: attemptID
        )
        XCTAssertEqual(lateState, .cancelled)
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

private final class AckTrackerCodexController: CodexSessionControlling {
    private let gate: AckTrackerSteerGate
    private(set) var hasActiveThread = true
    var onEnsureEventsStreamReady: (() -> Void)?

    init(gate: AckTrackerSteerGate) {
        self.gate = gate
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
        for _ in 0 ..< 500 {
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
        for _ in 0 ..< 500 {
            if completed { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return completed
    }
}
