import Foundation
import MCP
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class AgentRunMCPToolServiceWaitTests: XCTestCase {
    func testSingleWaitSteeringInterruptCompletesOnceAndKeepsRegistrationActive() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let fixture = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        defer { Task { await AgentRunSessionStore.cleanup(registration: fixture.registration) } }
        let service = makeService(
            window: window,
            viewModel: viewModel,
            liveSnapshots: liveSnapshots,
            recorder: recorder
        )

        let firstWait = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_id": .string(fixture.sessionID.uuidString),
                "timeout": .double(2)
            ])
        }
        try await waitForWaiter(registration: fixture.registration)

        await AgentRunSessionStore.wakeCurrentWaiters(
            fixture.runningSnapshot,
            cursor: fixture.cursor,
            reason: .steeringRequested
        )

        let interruptedValue = try await firstWait.value
        let interruptedObject = try XCTUnwrap(interruptedValue.objectValue)
        let interruptedMeta = try XCTUnwrap(interruptedObject["_meta"]?.objectValue)
        let interruptedWait = try XCTUnwrap(interruptedObject["wait"]?.objectValue)
        XCTAssertEqual(
            interruptedMeta["wake_reason"]?.stringValue,
            AgentRunSessionStore.WakeReason.steeringRequested.rawValue
        )
        XCTAssertEqual(interruptedWait["result"]?.stringValue, "interrupted_by_steering")
        XCTAssertTrue(interruptedWait["instruction"]?.stringValue?.contains("agent_run.wait") == true)
        XCTAssertNil(interruptedObject["assistant_text"])
        let registrationRemainsActive = await AgentRunSessionStore.hasActiveRegistration(
            sessionID: fixture.sessionID
        )
        XCTAssertTrue(registrationRemainsActive)

        let firstCompletions = await recorder.completions()
        XCTAssertEqual(firstCompletions.count, 1)
        XCTAssertEqual(firstCompletions[0].reason, .cancelled)
        XCTAssertEqual(firstCompletions[0].result, "interrupted_by_steering")
        XCTAssertNil(firstCompletions[0].winnerSessionID)
        XCTAssertEqual(firstCompletions[0].pendingSessionIDs, [fixture.sessionID])

        let secondWait = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_id": .string(fixture.sessionID.uuidString),
                "timeout": .double(2)
            ])
        }
        try await waitForWaiter(registration: fixture.registration)
        let terminalRunID = UUID()
        let terminal = makeSnapshot(sessionID: fixture.sessionID, runID: terminalRunID, status: .completed)
        await liveSnapshots.set(terminal)
        _ = await AgentRunSessionStore.publishTerminal(
            .init(epoch: fixture.epoch, snapshot: terminal),
            registration: fixture.registration,
            commitID: UUID(),
            successorKind: nil
        )

        let resumedValue = try await secondWait.value
        XCTAssertEqual(resumedValue.objectValue?["status"]?.stringValue, AgentRunMCPSnapshot.Status.completed.rawValue)
        XCTAssertEqual(resumedValue.objectValue?["run_id"]?.stringValue, terminalRunID.uuidString)
        XCTAssertNil(resumedValue.objectValue?["_meta"]?.objectValue?["wake_reason"])
        let allCompletions = await recorder.completions()
        XCTAssertEqual(allCompletions.count, 2)
        XCTAssertEqual(allCompletions[1].reason, .snapshotReady)
        XCTAssertEqual(allCompletions[1].winnerSessionID, fixture.sessionID)
    }

    func testSingleWaitCancellationDoesNotFabricateSteering() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let fixture = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        defer { Task { await AgentRunSessionStore.cleanup(registration: fixture.registration) } }
        let service = makeService(
            window: window,
            viewModel: viewModel,
            liveSnapshots: liveSnapshots,
            recorder: recorder
        )

        let waitTask = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_id": .string(fixture.sessionID.uuidString),
                "timeout": .double(2)
            ])
        }
        try await waitForWaiter(registration: fixture.registration)
        waitTask.cancel()

        do {
            _ = try await waitTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}

        let completions = await recorder.completions()
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions[0].reason, .cancelled)
        XCTAssertEqual(completions[0].result, "cancelled")
        XCTAssertNil(completions[0].winnerSessionID)
        XCTAssertEqual(completions[0].pendingSessionIDs, [fixture.sessionID])
    }

    func testMultiWaitSteeringInterruptReturnsAllPendingIDsAndCompletesAggregateScopeOnce() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let first = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        let second = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        defer {
            Task {
                await AgentRunSessionStore.cleanup(registration: first.registration)
                await AgentRunSessionStore.cleanup(registration: second.registration)
            }
        }
        let service = makeService(
            window: window,
            viewModel: viewModel,
            liveSnapshots: liveSnapshots,
            recorder: recorder
        )

        let waitTask = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_ids": .array([
                    .string(first.sessionID.uuidString),
                    .string(second.sessionID.uuidString)
                ]),
                "timeout": .double(2)
            ])
        }
        try await waitForWaiter(registration: first.registration)
        try await waitForWaiter(registration: second.registration)

        await AgentRunSessionStore.wakeCurrentWaiters(
            second.runningSnapshot,
            cursor: second.cursor,
            reason: .steeringRequested
        )

        let value = try await waitTask.value
        let object = try XCTUnwrap(value.objectValue)
        let meta = try XCTUnwrap(object["_meta"]?.objectValue)
        let wait = try XCTUnwrap(object["wait"]?.objectValue)
        XCTAssertEqual(
            meta["wake_reason"]?.stringValue,
            AgentRunSessionStore.WakeReason.steeringRequested.rawValue
        )
        XCTAssertEqual(object["session_id"]?.stringValue, second.sessionID.uuidString)
        XCTAssertEqual(wait["result"]?.stringValue, "interrupted_by_steering")
        XCTAssertNil(wait["winner_session_id"]?.stringValue)
        XCTAssertEqual(wait["interrupted_session_id"]?.stringValue, second.sessionID.uuidString)
        XCTAssertEqual(
            wait["pending_session_ids"]?.arrayValue?.compactMap(\.stringValue),
            [first.sessionID.uuidString, second.sessionID.uuidString]
        )
        let firstRegistrationRemainsActive = await AgentRunSessionStore.hasActiveRegistration(
            sessionID: first.sessionID
        )
        let secondRegistrationRemainsActive = await AgentRunSessionStore.hasActiveRegistration(
            sessionID: second.sessionID
        )
        XCTAssertTrue(firstRegistrationRemainsActive)
        XCTAssertTrue(secondRegistrationRemainsActive)

        let beginRecords = await recorder.beginRecords()
        let completions = await recorder.completions()
        XCTAssertEqual(beginRecords.count, 1)
        XCTAssertEqual(beginRecords[0], Set([first.sessionID, second.sessionID]))
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions[0].reason, .cancelled)
        XCTAssertEqual(completions[0].result, "interrupted_by_steering")
        XCTAssertEqual(completions[0].pendingSessionIDs, Set([first.sessionID, second.sessionID]))
    }

    func testMultiWaitCancellationDoesNotFabricateSteering() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let first = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        let second = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        defer {
            Task {
                await AgentRunSessionStore.cleanup(registration: first.registration)
                await AgentRunSessionStore.cleanup(registration: second.registration)
            }
        }
        let service = makeService(
            window: window,
            viewModel: viewModel,
            liveSnapshots: liveSnapshots,
            recorder: recorder
        )

        let waitTask = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_ids": .array([
                    .string(first.sessionID.uuidString),
                    .string(second.sessionID.uuidString)
                ]),
                "timeout": .double(2)
            ])
        }
        try await waitForWaiter(registration: first.registration)
        try await waitForWaiter(registration: second.registration)
        waitTask.cancel()

        do {
            _ = try await waitTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}

        let completions = await recorder.completions()
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions[0].reason, .cancelled)
        XCTAssertEqual(completions[0].result, "cancelled")
        XCTAssertNil(completions[0].winnerSessionID)
        XCTAssertEqual(completions[0].pendingSessionIDs, Set([first.sessionID, second.sessionID]))
    }

    func testMultiWaitInstructionDeliveredContinuesUntilActionableAndCompletesOnce() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let first = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        let second = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        defer {
            Task {
                await AgentRunSessionStore.cleanup(registration: first.registration)
                await AgentRunSessionStore.cleanup(registration: second.registration)
            }
        }
        let service = makeService(
            window: window,
            viewModel: viewModel,
            liveSnapshots: liveSnapshots,
            recorder: recorder
        )

        let waitTask = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_ids": .array([
                    .string(first.sessionID.uuidString),
                    .string(second.sessionID.uuidString)
                ]),
                "timeout": .double(2)
            ])
        }
        try await waitForWaiter(registration: first.registration)
        try await waitForWaiter(registration: second.registration)

        await AgentRunSessionStore.wakeCurrentWaiters(
            second.runningSnapshot,
            cursor: second.cursor,
            reason: .instructionDelivered
        )
        try await waitForWaiter(registration: second.registration)

        let terminal = makeSnapshot(sessionID: first.sessionID, status: .completed)
        await liveSnapshots.set(terminal)
        _ = await AgentRunSessionStore.publishTerminal(
            .init(epoch: first.epoch, snapshot: terminal),
            registration: first.registration,
            commitID: UUID(),
            successorKind: nil
        )

        let value = try await waitTask.value
        let object = try XCTUnwrap(value.objectValue)
        let wait = try XCTUnwrap(object["wait"]?.objectValue)
        XCTAssertEqual(object["session_id"]?.stringValue, first.sessionID.uuidString)
        XCTAssertEqual(wait["result"]?.stringValue, "snapshot_ready")
        XCTAssertEqual(wait["winner_session_id"]?.stringValue, first.sessionID.uuidString)
        XCTAssertEqual(
            wait["pending_session_ids"]?.arrayValue?.compactMap(\.stringValue),
            [second.sessionID.uuidString]
        )
        XCTAssertNil(object["_meta"]?.objectValue?["wake_reason"])

        let completions = await recorder.completions()
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions[0].reason, .snapshotReady)
        XCTAssertEqual(completions[0].winnerSessionID, first.sessionID)
        XCTAssertEqual(completions[0].pendingSessionIDs, [second.sessionID])
    }

    func testParkedWaitPollAndLaterWaitUseStoredTerminalSnapshot() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let fixture = try await installRunningSession(
            in: viewModel,
            liveSnapshots: liveSnapshots
        )
        defer { Task { await AgentRunSessionStore.cleanup(registration: fixture.registration) } }
        let service = makeService(
            window: window,
            viewModel: viewModel,
            liveSnapshots: liveSnapshots,
            recorder: recorder
        )
        let sentinel = "complete-terminal-sentinel."
        let liveRunning = makeSnapshot(
            sessionID: fixture.sessionID,
            status: .running,
            latestAssistantPreview: "live-running-sentinel"
        )
        await liveSnapshots.set(liveRunning)

        let preterminalPoll = try await service.execute(args: [
            "op": .string("poll"),
            "session_id": .string(fixture.sessionID.uuidString)
        ])
        XCTAssertEqual(
            preterminalPoll.objectValue?["assistant_text"]?.stringValue,
            "live-running-sentinel"
        )

        let firstWait = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_id": .string(fixture.sessionID.uuidString),
                "timeout": .double(2)
            ])
        }
        try await waitForWaiter(registration: fixture.registration)

        let terminal = makeSnapshot(
            sessionID: fixture.sessionID,
            status: .completed,
            latestAssistantPreview: sentinel
        )
        _ = await AgentRunSessionStore.publishTerminal(
            .init(epoch: fixture.epoch, snapshot: terminal),
            registration: fixture.registration,
            commitID: UUID(),
            successorKind: nil
        )

        let firstValue = try await firstWait.value
        XCTAssertEqual(firstValue.objectValue?["assistant_text"]?.stringValue, sentinel)

        let pollValue = try await service.execute(args: [
            "op": .string("poll"),
            "session_id": .string(fixture.sessionID.uuidString)
        ])
        XCTAssertEqual(pollValue.objectValue?["assistant_text"]?.stringValue, sentinel)

        let laterWaitValue = try await service.execute(args: [
            "op": .string("wait"),
            "session_id": .string(fixture.sessionID.uuidString),
            "timeout": .double(2)
        ])
        XCTAssertEqual(
            laterWaitValue.objectValue?["assistant_text"]?.stringValue,
            sentinel
        )
        XCTAssertEqual(
            laterWaitValue.objectValue?["status"]?.stringValue,
            AgentRunMCPSnapshot.Status.completed.rawValue
        )
    }

    private func makeWindow() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        return window
    }

    private func makeViewModel(windowID: Int) -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in WaitTestCodexController() }
        )
    }

    private func installRunningSession(
        in viewModel: AgentModeViewModel,
        liveSnapshots: LiveSnapshots
    ) async throws -> RunningSessionFixture {
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
        let context = try XCTUnwrap(session.mcpControlContext)
        let epoch = try XCTUnwrap(context.currentEpoch)
        let cursor = AgentRunSessionStore.WaitCursor(
            registration: context.registration,
            epoch: epoch
        )
        let runningSnapshot = makeSnapshot(
            sessionID: sessionID,
            status: .running,
            latestAssistantPreview: "stale assistant text"
        )
        await liveSnapshots.set(runningSnapshot)
        await AgentRunSessionStore.signalSnapshot(runningSnapshot, cursor: cursor)
        return RunningSessionFixture(
            sessionID: sessionID,
            registration: context.registration,
            epoch: epoch,
            cursor: cursor,
            runningSnapshot: runningSnapshot
        )
    }

    private func makeService(
        window: WindowState,
        viewModel: AgentModeViewModel,
        liveSnapshots: LiveSnapshots,
        recorder: WaitScopeRecorder
    ) -> AgentRunMCPToolService {
        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: nil,
                    clientName: "agent-run-wait-tests",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("startRun should not be used by wait tests")
            }
        )
        service.beginAgentRunWait = {
            (_: MCPServerViewModel.RequestMetadata, sessionIDs: Set<UUID>, _: TimeInterval?) async -> UUID? in
            await recorder.begin(sessionIDs: sessionIDs)
        }
        service.endAgentRunWait = {
            (token: UUID, completion: AgentRunWaitScopeCompletion) async in
            await recorder.end(token: token, completion: completion)
        }
        service.currentSnapshotProvider = {
            (sessionID: UUID, _: AgentModeViewModel) async -> AgentRunMCPSnapshot? in
            await liveSnapshots.snapshot(for: sessionID)
        }
        service.testAgentModeViewModel = viewModel
        return service
    }

    private func waitForWaiter(
        registration: AgentRunSessionStore.Registration,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0 ..< 300 {
            if await AgentRunSessionStore.shared.test_waiterCount(registration: registration) == 1 {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for store waiter", file: file, line: line)
    }

    private func makeSnapshot(
        sessionID: UUID,
        runID: UUID? = nil,
        status: AgentRunMCPSnapshot.Status,
        latestAssistantPreview: String? = nil
    ) -> AgentRunMCPSnapshot {
        AgentRunMCPSnapshot(
            sessionID: sessionID,
            runID: runID,
            tabID: nil,
            sessionName: "Child Agent",
            agentRaw: AgentProviderKind.codexExec.rawValue,
            agentDisplayName: AgentProviderKind.codexExec.displayName,
            modelRaw: "codex",
            reasoningEffortRaw: nil,
            status: status,
            statusText: status.rawValue,
            latestAssistantPreview: latestAssistantPreview,
            interaction: nil,
            transcriptItemCount: 1,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )
    }
}

private struct RunningSessionFixture {
    let sessionID: UUID
    let registration: AgentRunSessionStore.Registration
    let epoch: AgentRunTurnEpoch
    let cursor: AgentRunSessionStore.WaitCursor
    let runningSnapshot: AgentRunMCPSnapshot
}

private actor LiveSnapshots {
    private var snapshots: [UUID: AgentRunMCPSnapshot] = [:]

    func set(_ snapshot: AgentRunMCPSnapshot) {
        snapshots[snapshot.sessionID] = snapshot
    }

    func snapshot(for sessionID: UUID) -> AgentRunMCPSnapshot? {
        snapshots[sessionID]
    }
}

private final class WaitTestCodexController: CodexSessionControllerTurnDispatchTestDefaults {
    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "wait-test", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "wait-test", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "wait-test", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        .init(
            conversationID: "wait-test",
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

private actor WaitScopeRecorder {
    private var startedSessionIDs: [Set<UUID>] = []
    private var recordedCompletions: [AgentRunWaitScopeCompletion] = []

    func begin(sessionIDs: Set<UUID>) -> UUID {
        startedSessionIDs.append(sessionIDs)
        return UUID()
    }

    func end(token _: UUID, completion: AgentRunWaitScopeCompletion) {
        recordedCompletions.append(completion)
    }

    func beginRecords() -> [Set<UUID>] {
        startedSessionIDs
    }

    func completions() -> [AgentRunWaitScopeCompletion] {
        recordedCompletions
    }
}
