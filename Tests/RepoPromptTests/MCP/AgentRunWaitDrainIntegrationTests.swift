import Foundation
import MCP
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class AgentRunWaitDrainIntegrationTests: XCTestCase {
    func testRealParentWaitScopeDrainInterruptsOnceAndAllowsCleanRewait() async throws {
        try await AgentRunWaitDrainTestHarness.withHarness { harness in
            let firstWait = harness.startWait()
            try await harness.waitUntilBlocked()

            XCTAssertTrue(harness.server.hasActiveChildAgentRunWaits(runID: harness.parentRunID))
            XCTAssertEqual(harness.activeScopeCount(), 1)

            let steeringMessage = "real drain accepted steering"
            let drained = await harness.drain(
                source: "test-real-wait-scope-drain",
                steeringMessage: steeringMessage
            )
            XCTAssertTrue(drained)

            let interruptedValue = try await firstWait.value
            let interruptedObject = try XCTUnwrap(interruptedValue.objectValue)
            XCTAssertEqual(
                interruptedObject["wait"]?.objectValue?["result"]?.stringValue,
                "interrupted_by_steering"
            )
            XCTAssertNil(
                interruptedObject["wait"]?.objectValue?["steering_message"]
            )
            let formatted = try Self.onlyText(ToolOutputFormatter.formatAgentRun(
                args: ["op": .string("wait")],
                value: interruptedValue
            ))
            XCTAssertEqual(formatted.components(separatedBy: steeringMessage).count - 1, 0)
            XCTAssertEqual(
                interruptedObject["_meta"]?.objectValue?["wake_reason"]?.stringValue,
                AgentRunSessionStore.WakeReason.steeringRequested.rawValue
            )
            XCTAssertFalse(harness.server.hasActiveChildAgentRunWaits(runID: harness.parentRunID))
            XCTAssertEqual(harness.activeScopeCount(), 0)
            let firstCompletions = await harness.completionRecorder.completions()
            let registrationRemainsActive = await AgentRunSessionStore.hasActiveRegistration(
                sessionID: harness.fixture.sessionID
            )
            XCTAssertEqual(firstCompletions.count, 1)
            XCTAssertEqual(firstCompletions.first?.result, "interrupted_by_steering")
            XCTAssertTrue(registrationRemainsActive)

            let secondWait = harness.startWait()
            try await harness.waitUntilBlocked()
            try await Task.sleep(nanoseconds: 50_000_000)

            XCTAssertTrue(harness.server.hasActiveChildAgentRunWaits(runID: harness.parentRunID))
            XCTAssertEqual(harness.activeScopeCount(), 1)
            let secondWaiterCount = await AgentRunSessionStore.shared.test_waiterCount(
                registration: harness.fixture.registration
            )
            XCTAssertEqual(
                secondWaiterCount,
                1,
                "A stale steering wake must not complete the subsequent wait"
            )

            try await harness.publishTerminal()
            let terminalValue = try await secondWait.value
            XCTAssertEqual(terminalValue.objectValue?["status"]?.stringValue, AgentRunMCPSnapshot.Status.completed.rawValue)
            XCTAssertNil(terminalValue.objectValue?["wait"]?.objectValue?["steering_message"])
            XCTAssertFalse(harness.server.hasActiveChildAgentRunWaits(runID: harness.parentRunID))
            XCTAssertEqual(harness.activeScopeCount(), 0)
            let allCompletions = await harness.completionRecorder.completions()
            XCTAssertEqual(allCompletions.count, 2)
            XCTAssertEqual(allCompletions.last?.reason, .snapshotReady)
        }
    }

    func testStaleManualSubmitPreservesWaitSteeringMessageAfterWakeSuspension() async throws {
        try await AgentRunWaitDrainTestHarness.withHarness { harness in
            let steeringMarker = "<<stale-manual-steering-origin>>"
            let waitTask = harness.startWait()
            try await harness.waitUntilBlocked()

            let barrier = AgentRunWaiterWakeBarrier()
            harness.server.setBeforeAgentRunWaiterWakeForTesting { targetRunID, _ in
                guard targetRunID == harness.parentRunID else { return }
                await barrier.suspend()
            }
            defer {
                harness.server.setBeforeAgentRunWaiterWakeForTesting(nil)
                Task { await barrier.release() }
            }

            let session = await harness.viewModel.ensureSessionReady(tabID: UUID())
            session.selectedAgent = .openCode
            session.runID = harness.parentRunID
            session.runState = .running
            _ = session.beginRunAttempt(source: "test.staleManualWake")

            let submission = harness.viewModel.submitUserTurn(
                text: steeringMarker,
                tabID: session.tabID
            )
            guard case .submitted = submission else {
                return XCTFail("Expected the manual steering turn to be submitted")
            }

            await barrier.waitUntilSuspended()
            Self.rotateRunIdentity(session, source: "test.staleManualWake.rotate")
            await barrier.release()

            let value = try await waitTask.value
            try Self.assertExactSteeringMessage(
                steeringMarker,
                in: value,
                message: "A stale manual origin must fail open after the wake suspension"
            )
        }
    }

    func testStaleClaudeDispatchPreservesWaitSteeringMessageAfterWakeSuspension() async throws {
        try await assertStaleProviderDispatchPreservesWaitSteeringMessage(
            delivery: .queuedClaudeInterrupt,
            selectedAgent: .claudeCode,
            steeringMarker: "<<stale-claude-steering-origin>>"
        )
    }

    func testStaleACPDispatchPreservesWaitSteeringMessageAfterWakeSuspension() async throws {
        try await assertStaleProviderDispatchPreservesWaitSteeringMessage(
            delivery: .queuedACPInterrupt,
            selectedAgent: .openCode,
            steeringMarker: "<<stale-acp-steering-origin>>"
        )
    }

    private func assertStaleProviderDispatchPreservesWaitSteeringMessage(
        delivery: AgentModeViewModel.MCPInstructionDispatch,
        selectedAgent: AgentProviderKind,
        steeringMarker: String
    ) async throws {
        try await AgentRunWaitDrainTestHarness.withHarness { harness in
            let waitTask = harness.startWait()
            try await harness.waitUntilBlocked()

            let sessionID = UUID()
            let session = await harness.viewModel.ensureSessionReady(tabID: UUID())
            session.selectedAgent = selectedAgent
            session.runID = harness.parentRunID
            session.runState = .running
            _ = session.beginRunAttempt(source: "test.staleProviderWake")
            _ = harness.viewModel.test_installPersistentSessionBinding(
                sessionID: sessionID,
                on: session
            )
            try await harness.viewModel.mcpActivateControlContext(
                forTabID: session.tabID,
                sessionID: sessionID,
                originatingConnectionID: nil,
                startPending: true
            )
            await harness.viewModel.prepareMCPWaitTrackingForRunStart(session: session)
            let registration = try XCTUnwrap(session.mcpControlContext?.registration)

            let barrier = AgentRunWaiterWakeBarrier()
            harness.server.setBeforeAgentRunWaiterWakeForTesting { targetRunID, _ in
                guard targetRunID == harness.parentRunID else { return }
                await barrier.suspend()
            }
            harness.trackAdditionalRegistration(registration)
            defer {
                harness.server.setBeforeAgentRunWaiterWakeForTesting(nil)
                Task { await barrier.release() }
            }

            let wakeTask = Task { @MainActor in
                await harness.viewModel.test_wakeMCPWaitersForActiveDispatch(
                    delivery: delivery,
                    session: session,
                    sessionID: sessionID,
                    steeringMessage: steeringMarker
                )
            }

            await barrier.waitUntilSuspended()
            Self.rotateRunIdentity(session, source: "test.staleProviderWake.rotate")
            await barrier.release()

            let didWakeCurrentSession = await wakeTask.value
            XCTAssertFalse(
                didWakeCurrentSession,
                "The stale dispatch must not claim the successor as its current controlled session"
            )
            let value = try await waitTask.value
            try Self.assertExactSteeringMessage(
                steeringMarker,
                in: value,
                message: "A stale provider origin must fail open after the wake suspension"
            )
        }
    }

    private static func rotateRunIdentity(
        _ session: AgentModeViewModel.TabSession,
        source: String
    ) {
        if let ownership = session.activeRunOwnership {
            session.endRunAttempt(ifCurrent: ownership, source: source)
        }
        session.runID = UUID()
        _ = session.beginRunAttempt(source: source)
        session.runState = .running
    }

    private static func assertExactSteeringMessage(
        _ steeringMessage: String,
        in value: Value,
        message: String
    ) throws {
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(
            object["wait"]?.objectValue?["result"]?.stringValue,
            "interrupted_by_steering"
        )
        XCTAssertEqual(
            object["wait"]?.objectValue?["steering_message"]?.stringValue,
            steeringMessage,
            message
        )
    }

    private static func onlyText(_ blocks: [MCP.Tool.Content]) throws -> String {
        let first = try XCTUnwrap(blocks.first)
        guard case let .text(text, _, _) = first else {
            XCTFail("Expected text content")
            return ""
        }
        return text
    }
}

@MainActor
final class AgentRunWaitDrainTestHarness {
    struct Fixture {
        let sessionID: UUID
        let registration: AgentRunSessionStore.Registration
        let epoch: AgentRunTurnEpoch
        let cursor: AgentRunSessionStore.WaitCursor
        let runningSnapshot: AgentRunMCPSnapshot
    }

    let window: WindowState
    let server: MCPServerViewModel
    let viewModel: AgentModeViewModel
    let parentRunID: UUID
    let connectionID: UUID
    let externalSupervisorRunID: UUID
    let externalConnectionID: UUID
    let fixture: Fixture
    let completionRecorder: AgentRunWaitDrainCompletionRecorder

    private let service: AgentRunMCPToolService
    private let externalService: AgentRunMCPToolService
    private let liveSnapshots: AgentRunWaitDrainLiveSnapshots
    private var waitTasks: [Task<Value, Error>] = []
    private var additionalRegistrations: [AgentRunSessionStore.Registration] = []
    private var didCleanup = false

    private init(
        window: WindowState,
        viewModel: AgentModeViewModel,
        parentRunID: UUID,
        connectionID: UUID,
        externalSupervisorRunID: UUID,
        externalConnectionID: UUID,
        fixture: Fixture,
        completionRecorder: AgentRunWaitDrainCompletionRecorder,
        service: AgentRunMCPToolService,
        externalService: AgentRunMCPToolService,
        liveSnapshots: AgentRunWaitDrainLiveSnapshots
    ) {
        self.window = window
        server = window.mcpServer
        self.viewModel = viewModel
        self.parentRunID = parentRunID
        self.connectionID = connectionID
        self.externalSupervisorRunID = externalSupervisorRunID
        self.externalConnectionID = externalConnectionID
        self.fixture = fixture
        self.completionRecorder = completionRecorder
        self.service = service
        self.externalService = externalService
        self.liveSnapshots = liveSnapshots
    }

    static func withHarness<T>(
        parentRunID: UUID = UUID(),
        operation: @MainActor (AgentRunWaitDrainTestHarness) async throws -> T
    ) async throws -> T {
        let harness = try await make(parentRunID: parentRunID)
        do {
            let result = try await operation(harness)
            await harness.cleanup()
            return result
        } catch {
            await harness.cleanup()
            throw error
        }
    }

    static func make(parentRunID: UUID = UUID()) async throws -> AgentRunWaitDrainTestHarness {
        let window = makeWindow()
        let connectionID = UUID()
        let externalSupervisorRunID = UUID()
        let externalConnectionID = UUID()
        let liveSnapshots = AgentRunWaitDrainLiveSnapshots()
        let completionRecorder = AgentRunWaitDrainCompletionRecorder()
        let childViewModel = makeChildViewModel(
            windowID: window.windowID,
            mcpServer: window.mcpServer
        )
        let fixture: Fixture
        do {
            fixture = try await installRunningSession(
                in: childViewModel,
                liveSnapshots: liveSnapshots
            )
        } catch {
            WindowStatesManager.shared.unregisterWindowState(window)
            throw error
        }

        guard window.mcpServer.registerRunIDMapping(
            connectionID: connectionID,
            runID: parentRunID,
            windowID: window.windowID
        ) else {
            await AgentRunSessionStore.cleanup(registration: fixture.registration)
            WindowStatesManager.shared.unregisterWindowState(window)
            throw AgentRunWaitDrainHarnessError.failedToRegisterRunMapping
        }
        guard window.mcpServer.registerRunIDMapping(
            connectionID: externalConnectionID,
            runID: externalSupervisorRunID,
            windowID: window.windowID
        ) else {
            window.mcpServer.cleanupRunIDMapping(runID: parentRunID, connectionID: connectionID)
            await AgentRunSessionStore.cleanup(registration: fixture.registration)
            WindowStatesManager.shared.unregisterWindowState(window)
            throw AgentRunWaitDrainHarnessError.failedToRegisterRunMapping
        }

        func makeWaitService(connectionID: UUID, clientName: String) -> AgentRunMCPToolService {
            var service = AgentRunMCPToolService(
                toolName: MCPWindowToolName.agentRun,
                captureRequestMetadata: {
                    MCPServerViewModel.RequestMetadata(
                        connectionID: connectionID,
                        clientName: clientName,
                        windowID: window.windowID
                    )
                },
                requireTargetWindow: { window },
                resolveRequestedTabID: { _ in nil },
                resolveSpawnParentSourceTabID: { _ in nil },
                resolveSpawnParentSessionID: { _, _ in nil },
                withHeartbeat: { _, _, _, _, operation in try await operation() },
                startRun: { _, _, _, _, _, _, _, _, _, _, _ in
                    throw MCPError.internalError("startRun should not be used by wait-drain tests")
                }
            )
            service.beginAgentRunWait = { metadata, sessionIDs, timeoutSeconds in
                await window.mcpServer.test_beginAgentRunWaitScope(
                    metadata: metadata,
                    sessionIDs: sessionIDs,
                    timeoutSeconds: timeoutSeconds
                )
            }
            service.endAgentRunWait = { token, completion in
                await window.mcpServer.test_endAgentRunWaitScope(token, completion: completion)
                await completionRecorder.record(completion)
            }
            service.currentSnapshotProvider = { sessionID, _ in
                await liveSnapshots.snapshot(for: sessionID)
            }
            service.testAgentModeViewModel = childViewModel
            return service
        }

        let service = makeWaitService(
            connectionID: connectionID,
            clientName: "agent-run-wait-drain-tests"
        )
        let externalService = makeWaitService(
            connectionID: externalConnectionID,
            clientName: "agent-run-wait-drain-external-supervisor-tests"
        )

        return AgentRunWaitDrainTestHarness(
            window: window,
            viewModel: childViewModel,
            parentRunID: parentRunID,
            connectionID: connectionID,
            externalSupervisorRunID: externalSupervisorRunID,
            externalConnectionID: externalConnectionID,
            fixture: fixture,
            completionRecorder: completionRecorder,
            service: service,
            externalService: externalService,
            liveSnapshots: liveSnapshots
        )
    }

    func startWait(timeoutSeconds: TimeInterval = 2) -> Task<Value, Error> {
        startWait(using: service, timeoutSeconds: timeoutSeconds)
    }

    func startExternalWait(timeoutSeconds: TimeInterval = 2) -> Task<Value, Error> {
        startWait(using: externalService, timeoutSeconds: timeoutSeconds)
    }

    private func startWait(
        using service: AgentRunMCPToolService,
        timeoutSeconds: TimeInterval
    ) -> Task<Value, Error> {
        let task = Task { @MainActor [service, fixture] in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_id": .string(fixture.sessionID.uuidString),
                "timeout": .double(timeoutSeconds)
            ])
        }
        waitTasks.append(task)
        return task
    }

    func waitUntilBlocked(timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let waiterCount = await AgentRunSessionStore.shared.test_waiterCount(
                registration: fixture.registration
            )
            if waiterCount == 1,
               activeScopeCount() == 1,
               server.hasActiveChildAgentRunWaits(runID: parentRunID)
            {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw AgentRunWaitDrainHarnessError.timedOutWaitingForBlockedScope
    }

    func waitUntilBothBlocked(timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let waiterCount = await AgentRunSessionStore.shared.test_waiterCount(
                registration: fixture.registration
            )
            if waiterCount == 2,
               activeScopeCount() == 1,
               externalActiveScopeCount() == 1,
               server.hasActiveChildAgentRunWaits(runID: parentRunID),
               server.hasActiveChildAgentRunWaits(runID: externalSupervisorRunID)
            {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw AgentRunWaitDrainHarnessError.timedOutWaitingForBlockedScope
    }

    func drain(source: String, steeringMessage: String? = nil) async -> Bool {
        await server.wakeAndDrainAgentRunWaitersOwnedByActiveRun(
            runID: parentRunID,
            source: source,
            steeringMessage: steeringMessage,
            timeoutSeconds: 1,
            steeringOriginRunID: { [parentRunID] in parentRunID }
        ) { [fixture] sessionID in
            guard sessionID == fixture.sessionID else { return nil }
            return (fixture.runningSnapshot, fixture.cursor)
        }
    }

    func trackAdditionalRegistration(_ registration: AgentRunSessionStore.Registration) {
        additionalRegistrations.append(registration)
    }

    func activeScopeCount() -> Int {
        server.test_agentRunWaitScopeCount(parentRunID: parentRunID)
    }

    func externalActiveScopeCount() -> Int {
        server.test_agentRunWaitScopeCount(parentRunID: externalSupervisorRunID)
    }

    func publishTerminal() async throws {
        let terminal = Self.makeSnapshot(sessionID: fixture.sessionID, status: .completed)
        await liveSnapshots.set(terminal)
        let result = await AgentRunSessionStore.publishTerminal(
            .init(epoch: fixture.epoch, snapshot: terminal),
            registration: fixture.registration,
            commitID: UUID(),
            successorKind: nil
        )
        guard case .accepted = result else {
            throw AgentRunWaitDrainHarnessError.failedToPublishTerminal
        }
    }

    func cleanup() async {
        guard !didCleanup else { return }
        didCleanup = true
        let tasks = waitTasks
        waitTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            _ = try? await task.value
        }
        server.cleanupRunIDMapping(runID: parentRunID, connectionID: connectionID)
        server.cleanupRunIDMapping(
            runID: externalSupervisorRunID,
            connectionID: externalConnectionID
        )
        await AgentRunSessionStore.cleanup(registration: fixture.registration)
        for registration in additionalRegistrations {
            await AgentRunSessionStore.cleanup(registration: registration)
        }
        additionalRegistrations.removeAll()
        WindowStatesManager.shared.unregisterWindowState(window)
    }

    private static func makeWindow() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        return window
    }

    private static func makeChildViewModel(
        windowID: Int,
        mcpServer: MCPServerViewModel
    ) -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in AgentRunWaitDrainCodexController() },
            testMCPServer: mcpServer
        )
    }

    private static func installRunningSession(
        in viewModel: AgentModeViewModel,
        liveSnapshots: AgentRunWaitDrainLiveSnapshots
    ) async throws -> Fixture {
        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        do {
            try await viewModel.mcpActivateControlContext(
                forTabID: session.tabID,
                sessionID: sessionID,
                originatingConnectionID: nil,
                startPending: true
            )
            await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
            guard let context = session.mcpControlContext,
                  let epoch = context.currentEpoch
            else {
                throw AgentRunWaitDrainHarnessError.missingControlContext
            }
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
            return Fixture(
                sessionID: sessionID,
                registration: context.registration,
                epoch: epoch,
                cursor: cursor,
                runningSnapshot: runningSnapshot
            )
        } catch {
            if let registration = session.mcpControlContext?.registration {
                await AgentRunSessionStore.cleanup(registration: registration)
            }
            throw error
        }
    }

    private static func makeSnapshot(
        sessionID: UUID,
        status: AgentRunMCPSnapshot.Status,
        latestAssistantPreview: String? = nil
    ) -> AgentRunMCPSnapshot {
        AgentRunMCPSnapshot(
            sessionID: sessionID,
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

actor AgentRunWaiterWakeBarrier {
    private var isSuspended = false
    private var isReleased = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        guard !isReleased else { return }
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

actor AgentRunWaitDrainCompletionRecorder {
    private var recordedCompletions: [AgentRunWaitScopeCompletion] = []

    func record(_ completion: AgentRunWaitScopeCompletion) {
        recordedCompletions.append(completion)
    }

    func count() -> Int {
        recordedCompletions.count
    }

    func completions() -> [AgentRunWaitScopeCompletion] {
        recordedCompletions
    }
}

actor AgentRunWaitDrainLiveSnapshots {
    private var snapshots: [UUID: AgentRunMCPSnapshot] = [:]

    func set(_ snapshot: AgentRunMCPSnapshot) {
        snapshots[snapshot.sessionID] = snapshot
    }

    func snapshot(for sessionID: UUID) -> AgentRunMCPSnapshot? {
        snapshots[sessionID]
    }
}

private enum AgentRunWaitDrainHarnessError: Error {
    case failedToRegisterRunMapping
    case timedOutWaitingForBlockedScope
    case failedToPublishTerminal
    case missingControlContext
}

private final class AgentRunWaitDrainCodexController: CodexSessionControllerTurnDispatchTestDefaults {
    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in continuation.finish() }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "wait-drain-test", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "wait-drain-test", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "wait-drain-test", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        .init(
            conversationID: "wait-drain-test",
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
