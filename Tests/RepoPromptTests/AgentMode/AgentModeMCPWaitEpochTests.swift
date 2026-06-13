import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class AgentModeMCPWaitEpochTests: XCTestCase {
    func testTerminalPublicationDuringEpochBeginContextGapDoesNotLoseSessionWait() async throws {
        let viewModel = makeViewModel()
        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            startPending: true
        )
        await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        let firstOwnership = session.beginRunAttempt(source: "test.first")
        let firstEpoch = try XCTUnwrap(firstOwnership.turnEpoch)
        session.runState = .running
        viewModel.publishMCPStateChange(for: session)

        let waitTask = Task {
            await AgentRunMCPToolService.test_waitUntilActionableDisposition(
                sessionID: sessionID,
                timeoutSeconds: 1
            )
        }
        try await waitForWaiter(registration: XCTUnwrap(session.mcpControlContext?.registration))

        session.runState = .completed
        session.mcpFollowUpRunPending = true
        let gate = EpochBeginGate()
        viewModel.test_setAfterMCPStoreEpochBegan {
            await gate.pause()
        }
        defer { viewModel.test_setAfterMCPStoreEpochBegan(nil) }
        let prepareTask = Task {
            await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        }
        await gate.waitUntilPaused()

        let envelope = try XCTUnwrap(viewModel.test_makeTerminalPublicationEnvelope(
            for: session,
            ownership: firstOwnership,
            terminalState: .completed
        ))
        let revision = AgentRunTerminalCommitRevision(
            commitID: UUID(),
            ownership: firstOwnership,
            terminalState: .completed,
            sourceItemsRevision: session.sourceItemsRevision,
            assistantDeltaFlushGeneration: session.assistantDeltaFlushGeneration,
            providerDrainGeneration: session.providerTerminalDrainGeneration,
            mcpPublicationEnvelope: envelope,
            successorKind: nil,
            providerSuccessorID: nil
        )
        let oldPublication = await viewModel.test_publishTerminalCommit(
            revision,
            successorKind: nil,
            for: session
        )
        XCTAssertEqual(oldPublication, .stale)
        let storedOldTerminal = try await AgentRunSessionStore.snapshot(
            for: .init(
                registration: XCTUnwrap(session.mcpControlContext?.registration),
                epoch: firstEpoch
            )
        )
        XCTAssertEqual(storedOldTerminal?.status, .completed)

        await gate.open()
        await prepareTask.value
        let context = try XCTUnwrap(session.mcpControlContext)
        let secondEpoch = try XCTUnwrap(context.currentEpoch)
        XCTAssertNotEqual(secondEpoch, firstEpoch)
        XCTAssertEqual(secondEpoch.transitionKind, .relatedFollowUp)

        let secondTerminal = makeSnapshot(sessionID: sessionID, status: .completed)
        _ = await AgentRunSessionStore.publishTerminal(
            .init(epoch: secondEpoch, snapshot: secondTerminal),
            registration: context.registration,
            commitID: UUID(),
            successorKind: nil
        )
        let waitResult = await waitTask.value
        XCTAssertEqual(waitResult.disposition, "actionable")
        XCTAssertEqual(waitResult.snapshotStatus, AgentRunMCPSnapshot.Status.completed.rawValue)
        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testConcurrentPreparationDoesNotAdoptStaleEpochResult() async throws {
        let viewModel = makeViewModel()
        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            startPending: true
        )
        await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        _ = session.beginRunAttempt(source: "test.initial")
        let firstEpoch = try XCTUnwrap(session.mcpControlContext?.currentEpoch)
        session.runState = .completed
        session.mcpFollowUpRunPending = true

        let gate = EpochBeginGate()
        viewModel.test_setAfterMCPStoreEpochBegan {
            await gate.pauseOnce()
        }
        defer { viewModel.test_setAfterMCPStoreEpochBegan(nil) }

        let acceptedPreparation = Task {
            await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        }
        await gate.waitUntilPaused()

        let stalePreparation = Task {
            await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        }
        await stalePreparation.value

        let duringGap = try XCTUnwrap(session.mcpControlContext)
        XCTAssertEqual(duringGap.currentEpoch, firstEpoch)
        XCTAssertNil(duringGap.preparedEpoch)

        await gate.open()
        await acceptedPreparation.value

        let finalContext = try XCTUnwrap(session.mcpControlContext)
        let secondEpoch = try XCTUnwrap(finalContext.currentEpoch)
        XCTAssertEqual(secondEpoch.ordinal, firstEpoch.ordinal + 1)
        XCTAssertEqual(finalContext.preparedEpoch, secondEpoch)
        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testCanonicalTerminalEnvelopeRemainsTerminalWhileSessionProjectionIsRunning() async throws {
        let viewModel = makeViewModel()
        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            startPending: true
        )
        await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        let ownership = session.beginRunAttempt(source: "test.canonical")
        session.runState = .completed
        session.mcpFollowUpRunPending = true

        let projected = try XCTUnwrap(viewModel.mcpSnapshot(for: session))
        let envelope = try XCTUnwrap(viewModel.test_makeTerminalPublicationEnvelope(
            for: session,
            ownership: ownership,
            terminalState: .completed
        ))
        XCTAssertEqual(projected.status, .running)
        XCTAssertEqual(envelope.snapshot.status, .completed)
        XCTAssertEqual(envelope.epoch, ownership.turnEpoch)
        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testScopedInactiveSteeringCreatesOneSteeringEpochWithoutReplacingActivation() async throws {
        let viewModel = makeViewModel()
        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            startPending: true
        )
        await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        _ = session.beginRunAttempt(source: "test.initial")
        let initialContext = try XCTUnwrap(session.mcpControlContext)
        let initialEpoch = try XCTUnwrap(initialContext.currentEpoch)
        session.runState = .completed
        session.mcpFollowUpRunPending = false

        try await viewModel.withMCPRunEpochTransition(sessionID: sessionID, kind: .steering) {
            await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        }

        let steeringContext = try XCTUnwrap(session.mcpControlContext)
        let steeringEpoch = try XCTUnwrap(steeringContext.currentEpoch)
        XCTAssertEqual(steeringContext.registration, initialContext.registration)
        XCTAssertEqual(steeringEpoch.ordinal, initialEpoch.ordinal + 1)
        XCTAssertEqual(steeringEpoch.transitionKind, .steering)
        XCTAssertNil(steeringContext.pendingEpochTransition)
        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testInactiveSteeringReRegistersWaitTrackingAfterTerminalRecordExpires() async throws {
        let viewModel = makeViewModel()
        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            startPending: true
        )
        await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        _ = session.beginRunAttempt(source: "test.expiredSteering")
        let initialContext = try XCTUnwrap(session.mcpControlContext)
        let initialEpoch = try XCTUnwrap(initialContext.currentEpoch)
        session.runState = .completed
        session.mcpFollowUpRunPending = false

        let terminal = makeSnapshot(sessionID: sessionID, status: .completed)
        let publication = await AgentRunSessionStore.publishTerminal(
            .init(epoch: initialEpoch, snapshot: terminal),
            registration: initialContext.registration,
            commitID: UUID(),
            successorKind: nil
        )
        XCTAssertEqual(publication, .accepted(successorEpoch: nil))
        await AgentRunSessionStore.shared.test_expire(
            cursor: .init(registration: initialContext.registration, epoch: initialEpoch)
        )
        let hasExpiredRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasExpiredRegistration)

        try await viewModel.withMCPRunEpochTransition(sessionID: sessionID, kind: .steering) {
            await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        }

        let steeringContext = try XCTUnwrap(session.mcpControlContext)
        let steeringEpoch = try XCTUnwrap(steeringContext.currentEpoch)
        XCTAssertEqual(steeringContext.activationID, initialContext.activationID)
        XCTAssertNotEqual(steeringContext.registration, initialContext.registration)
        XCTAssertEqual(steeringEpoch.transitionKind, .steering)
        XCTAssertEqual(steeringEpoch.registrationGeneration, steeringContext.registration.generation)
        XCTAssertNil(steeringContext.pendingEpochTransition)

        let steeringCursor = AgentRunSessionStore.WaitCursor(
            registration: steeringContext.registration,
            epoch: steeringEpoch
        )
        let waitTask = Task {
            await AgentRunMCPToolService.test_waitUntilActionableDisposition(
                sessionID: sessionID,
                timeoutSeconds: 1
            )
        }
        try await waitForWaiter(registration: steeringContext.registration)
        let actionable = makeSnapshot(sessionID: sessionID, status: .waitingForInput)
        await AgentRunSessionStore.signalSnapshot(actionable, cursor: steeringCursor)
        let waitResult = await waitTask.value
        XCTAssertEqual(waitResult.disposition, "actionable")
        XCTAssertEqual(waitResult.snapshotStatus, AgentRunMCPSnapshot.Status.waitingForInput.rawValue)
        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testExpiredRegistrationRecoveryCannotOverwriteReplacementActivation() async throws {
        let viewModel = makeViewModel()
        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            startPending: true
        )
        await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        _ = session.beginRunAttempt(source: "test.expiredActivationRace")
        let initialContext = try XCTUnwrap(session.mcpControlContext)
        let initialEpoch = try XCTUnwrap(initialContext.currentEpoch)
        session.runState = .completed
        session.mcpFollowUpRunPending = false
        _ = await AgentRunSessionStore.publishTerminal(
            .init(
                epoch: initialEpoch,
                snapshot: makeSnapshot(sessionID: sessionID, status: .completed)
            ),
            registration: initialContext.registration,
            commitID: UUID(),
            successorKind: nil
        )
        await AgentRunSessionStore.shared.test_expire(
            cursor: .init(registration: initialContext.registration, epoch: initialEpoch)
        )

        let gate = EpochBeginGate()
        viewModel.test_setAfterMCPStoreEpochBegan {
            await gate.pause()
        }
        defer { viewModel.test_setAfterMCPStoreEpochBegan(nil) }
        let recoveryTask = Task {
            try await viewModel.withMCPRunEpochTransition(sessionID: sessionID, kind: .steering) {
                await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
            }
        }
        await gate.waitUntilPaused()

        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: UUID()
        )
        let replacementContext = try XCTUnwrap(session.mcpControlContext)
        XCTAssertNotEqual(replacementContext.activationID, initialContext.activationID)
        XCTAssertNotEqual(replacementContext.registration, initialContext.registration)

        await gate.open()
        try await recoveryTask.value

        let finalContext = try XCTUnwrap(session.mcpControlContext)
        let currentRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertEqual(finalContext, replacementContext)
        XCTAssertEqual(currentRegistration, replacementContext.registration)
        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testExpiredRegistrationRecoveryCleansStoreRecordAfterDeactivation() async throws {
        let viewModel = makeViewModel()
        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            startPending: true
        )
        await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        _ = session.beginRunAttempt(source: "test.expiredDeactivationRace")
        let initialContext = try XCTUnwrap(session.mcpControlContext)
        let initialEpoch = try XCTUnwrap(initialContext.currentEpoch)
        session.runState = .completed
        session.mcpFollowUpRunPending = false
        _ = await AgentRunSessionStore.publishTerminal(
            .init(
                epoch: initialEpoch,
                snapshot: makeSnapshot(sessionID: sessionID, status: .completed)
            ),
            registration: initialContext.registration,
            commitID: UUID(),
            successorKind: nil
        )
        await AgentRunSessionStore.shared.test_expire(
            cursor: .init(registration: initialContext.registration, epoch: initialEpoch)
        )

        let gate = EpochBeginGate()
        viewModel.test_setAfterMCPStoreEpochBegan {
            await gate.pause()
        }
        defer { viewModel.test_setAfterMCPStoreEpochBegan(nil) }
        let recoveryTask = Task {
            try await viewModel.withMCPRunEpochTransition(sessionID: sessionID, kind: .steering) {
                await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
            }
        }
        await gate.waitUntilPaused()

        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
        await gate.open()
        try await recoveryTask.value

        XCTAssertNil(session.mcpControlContext)
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    func testActiveRunPreparationDoesNotCreateSteeringEpoch() async throws {
        let viewModel = makeViewModel()
        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            startPending: true
        )
        await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        _ = session.beginRunAttempt(source: "test.active")
        let before = try XCTUnwrap(session.mcpControlContext)
        session.runState = .running

        await viewModel.prepareMCPWaitTrackingForRunStart(session: session)

        let after = try XCTUnwrap(session.mcpControlContext)
        XCTAssertEqual(after.registration, before.registration)
        XCTAssertEqual(after.currentEpoch, before.currentEpoch)
        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testControlledTerminalPublicationRejectsMissingCanonicalEnvelope() async throws {
        let viewModel = makeViewModel()
        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil
        )
        let ownership = session.beginRunAttempt(source: "test.missingEnvelope")
        let revision = AgentRunTerminalCommitRevision(
            commitID: UUID(),
            ownership: ownership,
            terminalState: .completed,
            sourceItemsRevision: session.sourceItemsRevision,
            assistantDeltaFlushGeneration: session.assistantDeltaFlushGeneration,
            providerDrainGeneration: session.providerTerminalDrainGeneration,
            mcpPublicationEnvelope: nil,
            successorKind: nil,
            providerSuccessorID: nil
        )

        let result = await viewModel.test_publishTerminalCommit(
            revision,
            successorKind: nil,
            for: session
        )
        XCTAssertEqual(result, .rejected(reason: "missing_terminal_publication_envelope"))
        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    private func waitForWaiter(registration: AgentRunSessionStore.Registration) async throws {
        for _ in 0 ..< 200 {
            if await AgentRunSessionStore.shared.test_waiterCount(registration: registration) == 1 {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for waiter")
    }

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in EpochTestCodexController() }
        )
    }

    private func makeSnapshot(
        sessionID: UUID,
        status: AgentRunMCPSnapshot.Status
    ) -> AgentRunMCPSnapshot {
        AgentRunMCPSnapshot(
            sessionID: sessionID,
            tabID: nil,
            sessionName: "Agent",
            agentRaw: AgentProviderKind.codexExec.rawValue,
            agentDisplayName: AgentProviderKind.codexExec.displayName,
            modelRaw: "codex",
            reasoningEffortRaw: nil,
            status: status,
            statusText: status.rawValue,
            latestAssistantPreview: nil,
            interaction: nil,
            transcriptItemCount: 0,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )
    }
}

private actor EpochBeginGate {
    private var isPaused = false
    private var didPause = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        await pauseOnce()
    }

    func pauseOnce() async {
        guard !didPause else { return }
        didPause = true
        isPaused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func open() {
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private final class EpochTestCodexController: CodexSessionControllerTurnDispatchTestDefaults {
    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { $0.finish() }
    }

    func ensureEventsStreamReady() {}
    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "epoch-test", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "epoch-test", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "epoch-test", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(includeTurns: Bool, timeout: TimeInterval?) async throws -> CodexNativeSessionController.ThreadSnapshot {
        .init(
            conversationID: "epoch-test",
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
