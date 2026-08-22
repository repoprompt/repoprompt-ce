import Combine
import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class CodexAgentModeCoordinatorLivenessTests: XCTestCase {
    private var retainedHosts: [AgentModeViewModel] = []

    override func tearDown() async throws {
        for host in retainedHosts {
            await host.prepareForWindowClose()
        }
        retainedHosts.removeAll()
        try await super.tearDown()
    }

    func testThreadSnapshotParsesAuthoritativeActiveCommandItem() throws {
        let itemID = UUID().uuidString
        let snapshot = CodexNativeSessionController.test_parseThreadSnapshot(
            [
                "thread": [
                    "id": "thread",
                    "status": ["type": "active", "activeFlags": []],
                    "turns": [[
                        "id": "turn",
                        "status": "inProgress",
                        "itemsView": "full",
                        "items": [[
                            "id": itemID,
                            "type": "commandExecution",
                            "status": "inProgress",
                            "processId": "97027"
                        ]]
                    ]]
                ]
            ],
            fallbackEffort: nil
        )

        XCTAssertTrue(snapshot.hasAuthoritativeActiveTurnItems)
        let item = try XCTUnwrap(snapshot.activeToolItems.first)
        XCTAssertEqual(item.turnID, "turn")
        XCTAssertEqual(item.itemID, itemID)
        XCTAssertEqual(item.invocationID, UUID(uuidString: itemID))
        XCTAssertEqual(item.kind, .commandExecution)
        XCTAssertEqual(item.processID, "97027")
        XCTAssertEqual(item.status, .inProgress)
    }

    func testThreadSnapshotPreservesToolIdentityAcrossMultipleActiveTurns() {
        let firstItemID = UUID().uuidString
        let secondItemID = UUID().uuidString
        let snapshot = CodexNativeSessionController.test_parseThreadSnapshot(
            [
                "thread": [
                    "id": "thread",
                    "status": ["type": "active", "activeFlags": []],
                    "turns": [
                        [
                            "id": "turn-a",
                            "status": "inProgress",
                            "itemsView": "full",
                            "items": [[
                                "id": firstItemID,
                                "type": "commandExecution",
                                "status": "inProgress",
                                "processId": "process-a"
                            ]]
                        ],
                        [
                            "id": "turn-b",
                            "status": "inProgress",
                            "itemsView": "full",
                            "items": [[
                                "id": secondItemID,
                                "type": "commandExecution",
                                "status": "inProgress",
                                "processId": "process-b"
                            ]]
                        ]
                    ]
                ]
            ],
            fallbackEffort: nil
        )

        XCTAssertTrue(snapshot.hasAuthoritativeActiveTurnItems)
        XCTAssertEqual(snapshot.activeTurnIDs, ["turn-a", "turn-b"])
        XCTAssertEqual(snapshot.activeToolItems.map(\.turnID), ["turn-a", "turn-b"])
        XCTAssertEqual(snapshot.activeToolItems.map(\.processID), ["process-a", "process-b"])
    }

    func testThreadSnapshotWithIncompleteActiveTurnItemsFailsClosed() {
        let snapshot = CodexNativeSessionController.test_parseThreadSnapshot(
            [
                "thread": [
                    "id": "thread",
                    "status": ["type": "active", "activeFlags": []],
                    "turns": [
                        [
                            "id": "turn-a",
                            "status": "inProgress",
                            "itemsView": "full",
                            "items": []
                        ],
                        [
                            "id": "turn-b",
                            "status": "inProgress",
                            "itemsView": "summary",
                            "items": [[
                                "id": UUID().uuidString,
                                "type": "commandExecution",
                                "status": "inProgress",
                                "processId": "process-b"
                            ]]
                        ]
                    ]
                ]
            ],
            fallbackEffort: nil
        )

        XCTAssertFalse(snapshot.hasAuthoritativeActiveTurnItems)
        XCTAssertEqual(snapshot.activeTurnIDs, ["turn-a", "turn-b"])
    }

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

    func testRepeatedIdenticalActiveSnapshotReattachesWithoutModelInputOrInterrupt() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("partial answer"),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        try await waitUntil {
            viewModel.test_codexCoordinator.test_codexActiveReattachReconciliationIsComplete(
                session: session
            )
        }

        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "turn")
        XCTAssertEqual(controller.shutdownCountSync(), 1)
        XCTAssertEqual(controller.startOrResumeCountSync(), 1)
        XCTAssertFalse(controller.startOrResumeObservedCancellationSync())
        XCTAssertTrue(controller.readSnapshotIncludeTurnsValuesSync().contains(true))
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(controller.steerUserTurnIDsSync().isEmpty)
        XCTAssertEqual(controller.startUserTurnCountSync(), 0)
        XCTAssertTrue(controller.interruptedTurnIDsSync().isEmpty)
        XCTAssertEqual(session.items.filter { $0.kind == .assistant }.map(\.text), ["partial answer"])
        XCTAssertFalse(session.items.contains { $0.kind == .error })
        XCTAssertNil(session.lastTerminalCommitRevision)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .completed)
        XCTAssertFalse(session.items.contains { $0.kind == .error })
    }

    func testCompletionDuringActiveReattachReconciliationIsBufferedAndReplayed() async throws {
        let snapshotGate = LivenessSnapshotReadGate()
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            postReattachSnapshotReadGate: snapshotGate
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        defer { snapshotGate.release() }

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("partial answer"),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        try await waitUntil {
            snapshotGate.isWaitingSync()
                && viewModel.test_codexCoordinator.test_codexReattachReconciliationIsPending(
                    session: session
                )
        }

        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session,
            sourceController: controller
        )

        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(viewModel.test_codexCoordinator.test_codexReattachReconciliationIsPending(
            session: session
        ))

        snapshotGate.release()
        try await waitUntil {
            session.runState == .completed
        }

        XCTAssertFalse(viewModel.test_codexCoordinator.test_codexReattachReconciliationIsPending(
            session: session
        ))
        XCTAssertEqual(controller.shutdownCountSync(), 1)
        XCTAssertEqual(controller.startOrResumeCountSync(), 1)
        XCTAssertTrue(controller.steerUserTurnIDsSync().isEmpty)
        XCTAssertEqual(controller.startUserTurnCountSync(), 0)
        XCTAssertTrue(controller.interruptedTurnIDsSync().isEmpty)
        XCTAssertEqual(session.items.filter { $0.kind == .assistant }.map(\.text), ["partial answer"])
        XCTAssertFalse(session.items.contains { $0.kind == .error })
        XCTAssertNotNil(session.lastTerminalCommitRevision)
    }

    func testCompletionDuringActiveReattachReconciliationReplaysWhenSnapshotIsIdle() async throws {
        let snapshotGate = LivenessSnapshotReadGate()
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            postReattachSnapshotStatus: .idle,
            postReattachActiveTurnIDs: [],
            postReattachSnapshotReadGate: snapshotGate
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        defer { snapshotGate.release() }

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("partial answer"),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        try await waitUntil {
            snapshotGate.isWaitingSync()
                && viewModel.test_codexCoordinator.test_codexReattachReconciliationIsPending(
                    session: session
                )
        }

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session,
            sourceController: controller
        )

        XCTAssertEqual(session.runState, .running)
        snapshotGate.release()
        try await waitUntil {
            session.runState == .completed
        }

        XCTAssertFalse(viewModel.test_codexCoordinator.test_codexReattachReconciliationIsPending(
            session: session
        ))
        XCTAssertEqual(controller.shutdownCountSync(), 1)
        XCTAssertEqual(controller.startOrResumeCountSync(), 1)
        XCTAssertFalse(session.items.contains { $0.kind == .error })
        XCTAssertNotNil(session.lastTerminalCommitRevision)
    }

    func testCompletionDuringActiveReattachReconciliationReplaysWhenSnapshotFails() async throws {
        let snapshotGate = LivenessSnapshotReadGate()
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            failsPostReattachSnapshotRead: true,
            postReattachSnapshotReadGate: snapshotGate
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        defer { snapshotGate.release() }

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("partial answer"),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        try await waitUntil {
            snapshotGate.isWaitingSync()
                && viewModel.test_codexCoordinator.test_codexReattachReconciliationIsPending(
                    session: session
                )
        }

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session,
            sourceController: controller
        )

        XCTAssertEqual(session.runState, .running)
        snapshotGate.release()
        try await waitUntil {
            session.runState == .completed
        }

        XCTAssertFalse(viewModel.test_codexCoordinator.test_codexReattachReconciliationIsPending(
            session: session
        ))
        XCTAssertEqual(controller.shutdownCountSync(), 1)
        XCTAssertEqual(controller.startOrResumeCountSync(), 1)
        XCTAssertFalse(session.items.contains { $0.kind == .error })
        XCTAssertNotNil(session.lastTerminalCommitRevision)
    }

    func testChangingActiveSnapshotsRemainValidProgress() async throws {
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: ["phase-a"]),
            snapshotSequence: [
                .active(activeFlags: ["phase-a"]),
                .active(activeFlags: ["phase-b"])
            ]
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("progress"),
            session: session
        )
        // Model a suite-loaded watchdog whose first probe begins after the recovery deadline.
        session.codexWatchdogState.lastProgressAt = Date().addingTimeInterval(-1)

        try await waitUntil {
            controller.readSnapshotCountSync() >= 3
        }

        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(controller.interruptedTurnIDsSync().isEmpty)

        session.pendingUserInputRequest = makeUserInputRequest(id: "stop-watchdog")
    }

    func testActiveToIdleProbeTransitionDoesNotCountAsProgress() async {
        let controller = LivenessFakeCodexController(
            snapshot: .idle,
            activeTurnIDs: [],
            snapshotSequence: [
                .active(activeFlags: []),
                .idle,
                .idle
            ]
        )
        let viewModel = makeViewModel(
            controller: controller,
            watchdogProbeThreshold: 10,
            watchdogRecoveryThreshold: 10
        )
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let originalProgressDate = Date().addingTimeInterval(-20)
        session.codexWatchdogState.lastProgressAt = originalProgressDate
        let originalProgressGeneration = session.codexWatchdogState.progressGeneration

        _ = await viewModel.test_codexCoordinator.test_attemptCodexStallRecovery(session: session)
        XCTAssertEqual(session.codexWatchdogState.lastAmbiguousProbeKind, "active")

        _ = await viewModel.test_codexCoordinator.test_attemptCodexStallRecovery(session: session)

        XCTAssertEqual(session.codexWatchdogState.lastAmbiguousProbeKind, "no-active-turn")
        XCTAssertEqual(session.codexWatchdogState.lastProgressAt, originalProgressDate)
        XCTAssertEqual(session.codexWatchdogState.progressGeneration, originalProgressGeneration)
        XCTAssertEqual(controller.startUserTurnCountSync(), 0)
        XCTAssertEqual(session.runState, .running)
    }

    func testProviderProgressDuringSnapshotProbeSupersedesStaleTerminalization() async throws {
        let snapshotGate = LivenessSnapshotReadGate()
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            snapshotReadGate: snapshotGate
        )
        let viewModel = makeViewModel(
            controller: controller,
            watchdogProbeThreshold: 10,
            watchdogRecoveryThreshold: 10
        )
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.codexWatchdogState.lastProgressAt = Date().addingTimeInterval(-20)

        let recoveryTask = Task {
            await viewModel.test_codexCoordinator.test_attemptCodexStallRecovery(session: session)
        }
        try await waitUntil {
            snapshotGate.isWaitingSync()
        }

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("fresh provider progress"),
            session: session
        )
        snapshotGate.release()

        let attemptedTerminalSettlement = await recoveryTask.value
        XCTAssertFalse(attemptedTerminalSettlement)
        XCTAssertEqual(session.runState, .running)
        XCTAssertNotNil(session.codexController)
        XCTAssertTrue(controller.interruptedTurnIDsSync().isEmpty)
        XCTAssertEqual(controller.shutdownCountSync(), 0)

        session.pendingUserInputRequest = makeUserInputRequest(id: "stop-watchdog")
    }

    func testPriorAttemptSuspendedSnapshotProbeCannotSettleSuccessorWithAliasedGeneration() async throws {
        let snapshotGate = LivenessSnapshotReadGate()
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            snapshotReadGate: snapshotGate
        )
        let viewModel = makeViewModel(
            controller: controller,
            watchdogProbeThreshold: 10,
            watchdogRecoveryThreshold: 10
        )
        let runID = UUID()
        let session = preparedCodexSession(in: viewModel, controller: controller, runID: runID)
        session.codexWatchdogState.lastProgressAt = Date().addingTimeInterval(-20)
        let attemptA = try XCTUnwrap(session.activeRunOwnership)
        let aliasedProgressGeneration = session.codexWatchdogState.progressGeneration

        let recoveryTask = Task {
            await viewModel.test_codexCoordinator.test_attemptCodexStallRecovery(session: session)
        }
        try await waitUntil {
            snapshotGate.isWaitingSync()
        }

        XCTAssertTrue(session.endRunAttempt(ifCurrent: attemptA, source: "test.watchdog.attemptA.terminal"))
        let attemptB = session.beginRunAttempt(source: "test.watchdog.attemptB")
        session.installRunID(runID)
        session.runState = .running
        session.codexController = controller
        session.codexWatchdogState = .init()
        XCTAssertEqual(session.codexWatchdogState.progressGeneration, aliasedProgressGeneration)
        session.codexAuthoritativeActiveTurn = .init(
            threadID: "fake",
            turnID: "turn-b",
            turnKind: .user,
            controllerInstanceID: ObjectIdentifier(controller),
            controllerGeneration: session.codexControllerGeneration,
            runID: runID,
            runAttemptID: attemptB.attemptID
        )
        session.codexRoutingObservedTurnID = "turn-b"

        snapshotGate.release()

        let attemptedTerminalSettlement = await recoveryTask.value
        XCTAssertFalse(attemptedTerminalSettlement)
        XCTAssertEqual(session.runID, runID)
        XCTAssertEqual(session.activeRunAttemptID, attemptB.attemptID)
        XCTAssertEqual(session.runState, .running)
        XCTAssertNotNil(session.codexController)
        XCTAssertTrue(controller.interruptedTurnIDsSync().isEmpty)
        XCTAssertEqual(controller.shutdownCountSync(), 0)
        XCTAssertNil(session.lastTerminalCommitRevision)
        XCTAssertFalse(session.items.contains { $0.kind == .error })

        session.pendingUserInputRequest = makeUserInputRequest(id: "stop-watchdog")
    }

    func testAlternatingStableSnapshotAndProbeFailureRemainsRunning() async throws {
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            failsEveryEvenSnapshotRead: true
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("partial answer"),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        try await waitUntil {
            controller.readSnapshotCountSync() >= 4
        }

        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(controller.interruptedTurnIDsSync().isEmpty)
        XCTAssertEqual(controller.shutdownCountSync(), 0)
        XCTAssertEqual(session.items.filter { $0.kind == .assistant }.map(\.text), ["partial answer"])
        XCTAssertFalse(session.items.contains { $0.kind == .error })
        XCTAssertNil(session.lastTerminalCommitRevision)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )
        XCTAssertEqual(session.runState, .completed)
    }

    func testPersistentProbeFailureRecoversOnceThenFailsClearly() async throws {
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            alwaysFailsSnapshotRead: true
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("partial answer"),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        try await waitUntil(timeout: 15) {
            session.runState == .failed
        }

        XCTAssertGreaterThanOrEqual(controller.readSnapshotCountSync(), 5)
        XCTAssertEqual(controller.shutdownCountSync(), 1)
        XCTAssertTrue(controller.interruptedTurnIDsSync().isEmpty)
        XCTAssertEqual(session.items.count(where: { $0.kind == .error }), 1)
        XCTAssertNotNil(session.lastTerminalCommitRevision)
    }

    func testContinuedActiveSilenceAfterReattachDoesNotLoopOrTerminalize() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("partial answer"),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        try await waitUntil {
            controller.shutdownCountSync() == 1
        }
        let snapshotCountAfterReattach = controller.readSnapshotCountSync()
        try await waitUntil {
            controller.readSnapshotCountSync() >= snapshotCountAfterReattach + 4
        }

        XCTAssertEqual(controller.shutdownCountSync(), 1)
        XCTAssertEqual(controller.startOrResumeCountSync(), 1)
        XCTAssertTrue(controller.steerUserTurnIDsSync().isEmpty)
        XCTAssertEqual(controller.startUserTurnCountSync(), 0)
        XCTAssertTrue(controller.interruptedTurnIDsSync().isEmpty)
        XCTAssertEqual(session.runState, .running)
        XCTAssertFalse(session.items.contains { $0.kind == .error })

        session.pendingUserInputRequest = makeUserInputRequest(id: "stop-watchdog")
    }

    func testSilentCommandWithoutRunIDSurvivesRecoveryWindowAndLaterCompletes() async throws {
        let invocationID = UUID()
        let toolItem = makeCommandToolItem(
            itemID: UUID(),
            processID: "97027",
            status: .inProgress
        )
        let unrelatedToolItem = makeCommandToolItem(
            itemID: UUID(),
            processID: "unrelated-process",
            status: .inProgress
        )
        XCTAssertNotEqual(invocationID, toolItem.invocationID)
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            activeToolItems: [toolItem, unrelatedToolItem],
            hasAuthoritativeActiveTurnItems: true
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller, runID: nil)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolCall(
                name: "bash",
                invocationID: invocationID,
                argsJSON: #"{"command":"sleep 420"}"#
            ),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .commandExecutionRunning(.init(
                invocationID: invocationID,
                processID: "97027",
                appendedOutput: nil
            )),
            session: session
        )
        session.codexWatchdogState.lastProgressAt = Date().addingTimeInterval(-1)

        try await waitUntil {
            controller.readSnapshotCountSync() >= 5
        }

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.codexNativeToolLiveness.inFlight.count, 1)
        XCTAssertEqual(controller.shutdownCountSync(), 0)
        XCTAssertTrue(controller.readSnapshotIncludeTurnsValuesSync().allSatisfy(\.self))
        XCTAssertTrue(controller.interruptedTurnIDsSync().isEmpty)
        XCTAssertFalse(session.items.contains { $0.kind == .error })

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolResult(
                name: "bash",
                invocationID: invocationID,
                argsJSON: #"{"command":"sleep 420"}"#,
                resultJSON: #"{"status":"completed","processId":"97027","exitCode":0}"#,
                isError: false
            ),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .completed)
        XCTAssertTrue(session.codexNativeToolLiveness.inFlight.isEmpty)
        XCTAssertTrue(session.bashLiveExecutionByKey.isEmpty)
        XCTAssertNotNil(session.lastTerminalCommitRevision)
        XCTAssertFalse(session.items.contains { $0.kind == .error })
    }

    func testSilentCompositeWaitCorrelatesToAuthoritativeCommandAndLaterCompletes() async throws {
        let itemID = "call_composite_wait_1"
        let eventParser = CodexNativeSessionController(
            client: CodexAppServerClient(),
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePaths: .uniform(nil)
        )
        let started = try XCTUnwrap(eventParser.test_parseToolLifecycleEvent(
            method: "item/started",
            params: [
                "threadId": "thread",
                "turnId": "turn",
                "item": [
                    "type": "dynamicToolCall",
                    "id": itemID,
                    "name": "wait",
                    "arguments": ["cell_id": "1", "yield_time_ms": 320_000]
                ]
            ]
        ))
        let invocationID = try XCTUnwrap(started.invocationID)
        XCTAssertEqual(started.kind, "call")
        XCTAssertEqual(started.name, "wait")

        let snapshot = CodexNativeSessionController.test_parseThreadSnapshot(
            [
                "thread": [
                    "id": "thread",
                    "status": ["type": "active", "activeFlags": []],
                    "turns": [[
                        "id": "turn",
                        "status": "inProgress",
                        "itemsView": "full",
                        "items": [[
                            "id": itemID,
                            "type": "commandExecution",
                            "status": "inProgress",
                            "processId": "cell:1"
                        ]]
                    ]]
                ]
            ],
            fallbackEffort: nil
        )
        let toolItem = try XCTUnwrap(snapshot.activeToolItems.first)
        XCTAssertEqual(toolItem.itemID, itemID)
        XCTAssertEqual(toolItem.invocationID, invocationID)
        XCTAssertEqual(toolItem.kind, .commandExecution)

        let controller = LivenessFakeCodexController(
            snapshot: snapshot.runtimeStatus,
            activeTurnIDs: snapshot.activeTurnIDs,
            activeToolItems: snapshot.activeToolItems,
            hasAuthoritativeActiveTurnItems: snapshot.hasAuthoritativeActiveTurnItems
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller, runID: nil)
        let argsJSON = try XCTUnwrap(started.argsJSON)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolCall(name: started.name, invocationID: invocationID, argsJSON: argsJSON),
            session: session
        )
        XCTAssertEqual(session.codexNativeToolLiveness.inFlight.keys.first?.invocationID, invocationID)
        session.codexWatchdogState.lastProgressAt = Date().addingTimeInterval(-1)

        try await waitUntil {
            controller.readSnapshotCountSync() >= 5
        }

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.codexNativeToolLiveness.inFlight.count, 1)
        XCTAssertEqual(controller.shutdownCountSync(), 0)
        XCTAssertTrue(controller.readSnapshotIncludeTurnsValuesSync().allSatisfy(\.self))
        XCTAssertTrue(controller.interruptedTurnIDsSync().isEmpty)
        XCTAssertFalse(session.items.contains { $0.kind == .error })

        let completed = try XCTUnwrap(eventParser.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: [
                "threadId": "thread",
                "turnId": "turn",
                "item": [
                    "type": "dynamicToolCall",
                    "id": itemID,
                    "name": "wait",
                    "arguments": ["cell_id": "1", "yield_time_ms": 320_000],
                    "result": ["status": "completed", "cell_id": "1"]
                ]
            ]
        ))
        XCTAssertEqual(completed.kind, "result")
        XCTAssertEqual(completed.invocationID, invocationID)
        try await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolResult(
                name: completed.name,
                invocationID: completed.invocationID,
                argsJSON: completed.argsJSON,
                resultJSON: XCTUnwrap(completed.resultJSON),
                isError: completed.isError
            ),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        XCTAssertEqual(session.runState, .completed)
        XCTAssertTrue(session.codexNativeToolLiveness.inFlight.isEmpty)
        XCTAssertEqual(session.items.first(where: { $0.toolInvocationID == invocationID })?.kind, .toolResult)
        XCTAssertEqual(controller.shutdownCountSync(), 0)
        XCTAssertNotNil(session.lastTerminalCommitRevision)
        XCTAssertFalse(session.items.contains { $0.kind == .error })
    }

    func testTerminalCommandSnapshotWithoutRunIDClearsStaleSpanAndFailsBoundedly() async throws {
        let invocationID = UUID()
        let toolItem = makeCommandToolItem(
            itemID: UUID(),
            processID: "97027",
            status: .terminal
        )
        XCTAssertNotEqual(invocationID, toolItem.invocationID)
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            activeToolItems: [toolItem],
            hasAuthoritativeActiveTurnItems: true
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller, runID: nil)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolCall(
                name: "bash",
                invocationID: invocationID,
                argsJSON: #"{"command":"sleep 420"}"#
            ),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .commandExecutionRunning(.init(
                invocationID: invocationID,
                processID: "97027",
                appendedOutput: nil
            )),
            session: session
        )
        session.codexWatchdogState.lastProgressAt = Date().addingTimeInterval(-1)

        try await waitUntil {
            session.runState == .failed
        }

        XCTAssertGreaterThan(controller.readSnapshotCountSync(), 0)
        XCTAssertTrue(session.codexNativeToolLiveness.inFlight.isEmpty)
        XCTAssertTrue(session.bashLiveExecutionByKey.isEmpty)
        XCTAssertEqual(controller.shutdownCountSync(), 0)
        XCTAssertEqual(session.items.count(where: { $0.kind == .error }), 1)
        XCTAssertNotNil(session.lastTerminalCommitRevision)
    }

    func testTerminalTurnFinalizesPersistedRunningCompositeExecResult() async throws {
        let invocationID = UUID()
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let argsJSON = #"{"cmd":"sleep 420"}"#
        let runningResultJSON = #"{"type":"commandExecution","status":"running","processId":"cell:1"}"#

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolCall(name: "exec", invocationID: invocationID, argsJSON: argsJSON),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolResult(
                name: "exec",
                invocationID: invocationID,
                argsJSON: argsJSON,
                resultJSON: runningResultJSON,
                isError: false
            ),
            session: session
        )

        let persistedRunningItem = try XCTUnwrap(session.items.first(where: { $0.toolInvocationID == invocationID }))
        XCTAssertEqual(persistedRunningItem.kind, .toolResult)
        XCTAssertEqual(persistedRunningItem.toolName, "exec")
        XCTAssertTrue(BashToolResultParser.parseLivenessMetadata(raw: persistedRunningItem.toolResultJSON).isRunning)
        XCTAssertTrue(session.bashLiveExecutionByKey.isEmpty)
        XCTAssertTrue(session.codexNativeToolLiveness.inFlight.isEmpty)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        let finalizedItem = try XCTUnwrap(session.items.first(where: { $0.id == persistedRunningItem.id }))
        let resultData = try XCTUnwrap(finalizedItem.toolResultJSON?.data(using: .utf8))
        let resultObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        )
        XCTAssertEqual(session.runState, .completed)
        XCTAssertEqual(finalizedItem.toolName, "exec")
        XCTAssertEqual(finalizedItem.toolInvocationID, invocationID)
        XCTAssertEqual(resultObject["type"] as? String, "commandExecution")
        XCTAssertEqual(resultObject["status"] as? String, "completed")
        XCTAssertEqual(resultObject["exitCode"] as? Int, 0)
        XCTAssertFalse(BashToolResultParser.parseLivenessMetadata(raw: finalizedItem.toolResultJSON).isRunning)
        XCTAssertEqual(finalizedItem.toolIsError, false)
    }

    func testUnrelatedInProgressCommandDoesNotCorroborateLocalSpan() async {
        let localInvocationID = UUID()
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            activeToolItems: [makeCommandToolItem(
                itemID: UUID(),
                processID: "snapshot-process",
                status: .inProgress
            )],
            hasAuthoritativeActiveTurnItems: true
        )
        let viewModel = makeViewModel(
            controller: controller,
            watchdogProbeThreshold: 10,
            watchdogRecoveryThreshold: 10
        )
        let session = preparedCodexSession(in: viewModel, controller: controller, runID: nil)
        await openRunningCommand(
            invocationID: localInvocationID,
            processID: "local-process",
            viewModel: viewModel,
            session: session
        )
        let originalProgressDate = Date().addingTimeInterval(-20)
        session.codexWatchdogState.lastProgressAt = originalProgressDate
        let originalProgressGeneration = session.codexWatchdogState.progressGeneration

        _ = await viewModel.test_codexCoordinator.test_attemptCodexStallRecovery(session: session)

        XCTAssertEqual(session.codexWatchdogState.lastProgressAt, originalProgressDate)
        XCTAssertEqual(session.codexWatchdogState.progressGeneration, originalProgressGeneration)
        XCTAssertEqual(session.codexNativeToolLiveness.inFlight.count, 1)
        XCTAssertEqual(session.bashLiveExecutionByKey.values.filter(\.isRunning).count, 1)
    }

    func testNamelessMCPItemDoesNotCorroborateNamedLocalSpan() async {
        let invocationID = UUID()
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            activeToolItems: [.init(
                turnID: "turn",
                itemID: invocationID.uuidString,
                invocationID: invocationID,
                kind: .mcpToolCall,
                toolName: nil,
                processID: nil,
                status: .inProgress
            )],
            hasAuthoritativeActiveTurnItems: true
        )
        let viewModel = makeViewModel(
            controller: controller,
            watchdogProbeThreshold: 10,
            watchdogRecoveryThreshold: 10
        )
        let session = preparedCodexSession(in: viewModel, controller: controller, runID: nil)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolCall(name: "lookup", invocationID: invocationID, argsJSON: "{}"),
            session: session
        )
        let originalProgressDate = Date().addingTimeInterval(-20)
        session.codexWatchdogState.lastProgressAt = originalProgressDate
        let originalProgressGeneration = session.codexWatchdogState.progressGeneration

        _ = await viewModel.test_codexCoordinator.test_attemptCodexStallRecovery(session: session)

        XCTAssertEqual(session.codexWatchdogState.lastProgressAt, originalProgressDate)
        XCTAssertEqual(session.codexWatchdogState.progressGeneration, originalProgressGeneration)
        XCTAssertEqual(session.codexNativeToolLiveness.inFlight.count, 1)
    }

    func testUnrelatedTerminalCommandDoesNotFinalizeOrClearLocalSpan() async {
        let localInvocationID = UUID()
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            activeToolItems: [makeCommandToolItem(
                itemID: UUID(),
                processID: "snapshot-process",
                status: .terminal
            )],
            hasAuthoritativeActiveTurnItems: true
        )
        let viewModel = makeViewModel(
            controller: controller,
            watchdogProbeThreshold: 10,
            watchdogRecoveryThreshold: 10
        )
        let session = preparedCodexSession(in: viewModel, controller: controller, runID: nil)
        await openRunningCommand(
            invocationID: localInvocationID,
            processID: "local-process",
            viewModel: viewModel,
            session: session
        )
        session.codexWatchdogState.lastProgressAt = Date().addingTimeInterval(-20)

        _ = await viewModel.test_codexCoordinator.test_attemptCodexStallRecovery(session: session)

        XCTAssertEqual(session.codexNativeToolLiveness.inFlight.count, 1)
        let liveState = session.bashLiveExecutionByKey.values.first
        XCTAssertEqual(liveState?.invocationID, localInvocationID)
        XCTAssertEqual(liveState?.isRunning, true)
    }

    func testTerminalSnapshotAmongMultipleCommandsOnlyClearsExactIdentity() async {
        let completedInvocationID = UUID()
        let runningInvocationID = UUID()
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            activeToolItems: [
                makeCommandToolItem(
                    itemID: completedInvocationID,
                    processID: "completed-process",
                    status: .terminal
                ),
                makeCommandToolItem(
                    itemID: UUID(),
                    processID: "unrelated-process",
                    status: .terminal
                )
            ],
            hasAuthoritativeActiveTurnItems: true
        )
        let viewModel = makeViewModel(
            controller: controller,
            watchdogProbeThreshold: 10,
            watchdogRecoveryThreshold: 10
        )
        let session = preparedCodexSession(in: viewModel, controller: controller, runID: nil)
        await openRunningCommand(
            invocationID: completedInvocationID,
            processID: "completed-process",
            command: "sleep 1",
            viewModel: viewModel,
            session: session
        )
        await openRunningCommand(
            invocationID: runningInvocationID,
            processID: "running-process",
            command: "sleep 420",
            viewModel: viewModel,
            session: session
        )
        session.codexWatchdogState.lastProgressAt = Date().addingTimeInterval(-20)

        _ = await viewModel.test_codexCoordinator.test_attemptCodexStallRecovery(session: session)

        XCTAssertEqual(session.codexNativeToolLiveness.inFlight.count, 1)
        XCTAssertEqual(session.codexNativeToolLiveness.inFlight.keys.first?.invocationID, runningInvocationID)
        let runningStates = session.bashLiveExecutionByKey.values.filter(\.isRunning)
        XCTAssertEqual(runningStates.count, 1)
        XCTAssertEqual(runningStates.first?.invocationID, runningInvocationID)
    }

    func testSnapshotItemFromAnotherActiveTurnCannotAffectCurrentTurnSpan() async {
        let invocationID = UUID()
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            activeTurnIDs: ["turn", "other-turn"],
            activeToolItems: [makeCommandToolItem(
                turnID: "other-turn",
                itemID: invocationID,
                processID: "97027",
                status: .terminal
            )],
            hasAuthoritativeActiveTurnItems: true
        )
        let viewModel = makeViewModel(
            controller: controller,
            watchdogProbeThreshold: 10,
            watchdogRecoveryThreshold: 10
        )
        let session = preparedCodexSession(in: viewModel, controller: controller, runID: nil)
        await openRunningCommand(
            invocationID: invocationID,
            processID: "97027",
            viewModel: viewModel,
            session: session
        )
        session.codexWatchdogState.lastProgressAt = Date().addingTimeInterval(-20)

        _ = await viewModel.test_codexCoordinator.test_attemptCodexStallRecovery(session: session)

        XCTAssertEqual(session.codexNativeToolLiveness.inFlight.count, 1)
        XCTAssertEqual(session.bashLiveExecutionByKey.values.first?.isRunning, true)
    }

    func testDuplicateSnapshotProcessHandlesFailClosed() async {
        let localInvocationID = UUID()
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            activeToolItems: [
                makeCommandToolItem(
                    itemID: UUID(),
                    processID: "shared-process",
                    status: .inProgress
                ),
                makeCommandToolItem(
                    itemID: UUID(),
                    processID: "shared-process",
                    status: .inProgress
                )
            ],
            hasAuthoritativeActiveTurnItems: true
        )
        let viewModel = makeViewModel(
            controller: controller,
            watchdogProbeThreshold: 10,
            watchdogRecoveryThreshold: 10
        )
        let session = preparedCodexSession(in: viewModel, controller: controller, runID: nil)
        await openRunningCommand(
            invocationID: localInvocationID,
            processID: "shared-process",
            viewModel: viewModel,
            session: session
        )
        let originalProgressDate = Date().addingTimeInterval(-20)
        session.codexWatchdogState.lastProgressAt = originalProgressDate
        let originalProgressGeneration = session.codexWatchdogState.progressGeneration

        _ = await viewModel.test_codexCoordinator.test_attemptCodexStallRecovery(session: session)

        XCTAssertEqual(session.codexWatchdogState.lastProgressAt, originalProgressDate)
        XCTAssertEqual(session.codexWatchdogState.progressGeneration, originalProgressGeneration)
        XCTAssertEqual(session.codexNativeToolLiveness.inFlight.count, 1)
    }

    func testDuplicateLocalProcessHandlesFailClosed() async {
        let firstInvocationID = UUID()
        let secondInvocationID = UUID()
        let controller = LivenessFakeCodexController(
            snapshot: .active(activeFlags: []),
            activeToolItems: [makeCommandToolItem(
                itemID: UUID(),
                processID: "shared-process",
                status: .inProgress
            )],
            hasAuthoritativeActiveTurnItems: true
        )
        let viewModel = makeViewModel(
            controller: controller,
            watchdogProbeThreshold: 10,
            watchdogRecoveryThreshold: 10
        )
        let session = preparedCodexSession(in: viewModel, controller: controller, runID: nil)
        await openRunningCommand(
            invocationID: firstInvocationID,
            processID: "shared-process",
            command: "sleep 1",
            viewModel: viewModel,
            session: session
        )
        await openRunningCommand(
            invocationID: secondInvocationID,
            processID: "shared-process",
            viewModel: viewModel,
            session: session
        )
        let originalProgressDate = Date().addingTimeInterval(-20)
        session.codexWatchdogState.lastProgressAt = originalProgressDate
        let originalProgressGeneration = session.codexWatchdogState.progressGeneration

        _ = await viewModel.test_codexCoordinator.test_attemptCodexStallRecovery(session: session)

        XCTAssertEqual(session.codexWatchdogState.lastProgressAt, originalProgressDate)
        XCTAssertEqual(session.codexWatchdogState.progressGeneration, originalProgressGeneration)
        XCTAssertEqual(session.codexNativeToolLiveness.inFlight.count, 2)
        XCTAssertEqual(session.bashLiveExecutionByKey.values.filter(\.isRunning).count, 2)
    }

    func testTurnStartSilenceRemainsRunningWithoutSpeculativeRedispatch() async throws {
        let controller = LivenessFakeCodexController(
            snapshot: .idle,
            activeTurnIDs: [],
            startUserTurnDelayNanos: 40_000_000
        )
        let viewModel = makeViewModel(
            controller: controller,
            watchdogRecoveryThreshold: 30
        )
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.runState = .idle
        session.codexAuthoritativeActiveTurn = nil
        session.codexAnonymousActiveTurn = nil
        session.codexRoutingObservedTurnID = nil

        let sendTask = Task {
            await viewModel.test_codexCoordinator.sendCodexNativeMessage(
                session: session,
                text: "hello",
                attachments: []
            )
        }
        try await waitUntil {
            controller.startUserTurnCountSync() == 1
        }

        let outcome = await sendTask.value
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(controller.startUserTurnCountSync(), 1)
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(controller.interruptedTurnIDsSync().isEmpty)
        XCTAssertEqual(controller.shutdownCountSync(), 0)
        XCTAssertFalse(session.items.contains { $0.kind == .error })

        session.pendingUserInputRequest = makeUserInputRequest(id: "stop-watchdog")
    }

    func testLateStartCancellationAfterRunAndControllerReplacementPreservesSuccessor() async {
        let cancellationGate = LivenessSnapshotReadGate()
        let controller = LivenessFakeCodexController(
            snapshot: .idle,
            activeTurnIDs: [],
            startUserTurnCancellationGate: cancellationGate
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.runState = .idle
        session.codexAuthoritativeActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        let attachment = AgentImageAttachment(
            source: .localFile(path: "/tmp/stale-cancelled-send.png"),
            title: "stale-cancelled-send.png"
        )
        let reservationID = UUID()
        session.attachmentTurnState = .reserved(
            reservationID: reservationID,
            attachments: [attachment]
        )

        let sendTask = Task {
            await viewModel.test_codexCoordinator.sendCodexNativeMessage(
                session: session,
                text: "stale send",
                attachments: [attachment],
                attachmentReservationID: reservationID
            )
        }
        await cancellationGate.waitUntilWaiting()

        let successorRunID = UUID()
        let successorController = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        session.installRunID(successorRunID)
        session.beginRunAttempt(source: "test.successor")
        session.codexController = successorController
        session.runState = .running
        session.codexPendingTurnKind = .user
        let successorAuthRetryTurn = AgentTabSession.CodexPendingAuthRetryTurn(
            text: "successor retry",
            images: [],
            model: "gpt-5.6",
            reasoningEffort: "high",
            serviceTier: "priority",
            attachmentReservationID: nil,
            expectedTurnID: "successor-turn"
        )
        session.codexPendingAuthRetryTurn = successorAuthRetryTurn
        session.runningStatusText = "Newer run active"
        session.runningStatusSource = .transport
        cancellationGate.release()

        let outcome = await sendTask.value
        guard case let .stale(reason) = outcome else {
            return XCTFail("Expected stale cancellation outcome, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("active run/controller changed"))
        XCTAssertEqual(session.runID, successorRunID)
        XCTAssertTrue((session.codexController as AnyObject) === successorController)
        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.codexPendingTurnKind, .user)
        XCTAssertEqual(session.codexPendingAuthRetryTurn, successorAuthRetryTurn)
        XCTAssertEqual(session.runningStatusText, "Newer run active")
        XCTAssertEqual(session.runningStatusSource, .transport)
        XCTAssertEqual(session.pendingImageAttachments, [attachment])
        guard case .idle = session.attachmentTurnState else {
            return XCTFail("The stale send's scoped attachment reservation was not released")
        }
    }

    func testCurrentStartCancellationStillTerminalizesRun() async {
        let cancellationGate = LivenessSnapshotReadGate()
        let controller = LivenessFakeCodexController(
            snapshot: .idle,
            activeTurnIDs: [],
            startUserTurnCancellationGate: cancellationGate
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.runState = .idle
        session.codexAuthoritativeActiveTurn = nil
        session.codexRoutingObservedTurnID = nil

        let sendTask = Task {
            await viewModel.test_codexCoordinator.sendCodexNativeMessage(
                session: session,
                text: "current send",
                attachments: []
            )
        }
        await cancellationGate.waitUntilWaiting()
        cancellationGate.release()

        let outcome = await sendTask.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(session.runState, .cancelled)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertNil(session.runningStatusText)
        XCTAssertTrue((session.codexController as AnyObject) === controller)
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

    func testStructuredFailedCompletionUsesOneTerminalCommitAndPreservesTail() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let baselineDrainGeneration = session.providerTerminalDrainGeneration

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("assistant tail"),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(
                turnID: "turn",
                status: .failed,
                failure: .init(message: "authoritative provider error")
            ),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(
                turnID: "turn",
                status: .failed,
                failure: .init(message: "duplicate provider error")
            ),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .error("Codex transport closed unexpectedly."),
            session: session
        )

        XCTAssertEqual(session.runState, .failed)
        XCTAssertNil(session.activeRunOwnership)
        let revision = session.lastTerminalCommitRevision
        XCTAssertNotNil(revision)
        XCTAssertEqual(session.providerTerminalDrainGeneration, baselineDrainGeneration + 1)
        XCTAssertEqual(revision?.providerDrainGeneration, session.providerTerminalDrainGeneration)
        XCTAssertEqual(
            session.items.filter { $0.kind == .assistant || $0.kind == .error }.map(\.kind),
            [.assistant, .error]
        )
        XCTAssertEqual(
            session.items.filter { $0.kind == .error }.map(\.text),
            ["authoritative provider error"]
        )
    }

    func testTurnCompletionCoalescesBufferedAssistantTailBeforeTerminalSeal() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let baselineDrainGeneration = session.providerTerminalDrainGeneration
        session.appendItem(.user("question", sequenceIndex: session.nextSequenceIndex))
        let commandInvocationID = UUID()
        session.appendItem(.toolResult(
            name: "bash",
            invocationID: commandInvocationID,
            argsJSON: "{}",
            resultJSON: #"{"status":"completed"}"#,
            isError: false,
            sequenceIndex: session.nextSequenceIndex
        ))

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("answer"),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        let streamingPrefix = try XCTUnwrap(session.items.last)
        XCTAssertEqual(streamingPrefix.kind, .assistant)
        XCTAssertEqual(streamingPrefix.text, "answer")
        XCTAssertTrue(streamingPrefix.isStreaming)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("."),
            session: session
        )
        XCTAssertEqual(session.pendingAssistantDelta, ".")
        XCTAssertNotNil(session.assistantDeltaFlushTask)
        session.pendingCommandRunningByKey["terminal-test"] = .init(
            invocationID: commandInvocationID,
            processID: nil,
            appendedOutput: nil,
            sealsAssistantBoundary: false
        )
        session.pendingCommandRunningFlushTask = Task {}
        XCTAssertFalse(viewModel.test_codexCoordinator.codexTerminalBuffersAreDrained(session))

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["answer."])
        XCTAssertEqual(assistantItems.map(\.isStreaming), [false])
        XCTAssertTrue(session.pendingAssistantDelta.isEmpty)
        XCTAssertNil(session.assistantDeltaFlushTask)
        XCTAssertTrue(session.pendingCommandRunningByKey.isEmpty)
        XCTAssertNil(session.pendingCommandRunningFlushTask)
        XCTAssertTrue(viewModel.test_codexCoordinator.codexTerminalBuffersAreDrained(session))

        let revision = try XCTUnwrap(session.lastTerminalCommitRevision)
        XCTAssertEqual(session.runState, .completed)
        XCTAssertEqual(revision.terminalState, .completed)
        XCTAssertEqual(revision.sourceItemsRevision, session.sourceItemsRevision)
        XCTAssertEqual(revision.assistantDeltaFlushGeneration, session.assistantDeltaFlushGeneration)
        XCTAssertEqual(session.providerTerminalDrainGeneration, baselineDrainGeneration + 1)
        XCTAssertEqual(revision.providerDrainGeneration, session.providerTerminalDrainGeneration)
    }

    func testCanonicalAssistantCompletionReconcilesNoDeltaExactPrefixUTF8DuplicateAndEmpty() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)

        let noDeltaScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-no-delta"
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: noDeltaScope, text: "no delta")),
            session: session
        )

        let exactScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-exact"
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "exact", scope: exactScope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: exactScope, text: "exact")),
            session: session
        )

        let prefixScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-prefix"
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "answer", scope: prefixScope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: prefixScope, text: "answer.")),
            session: session
        )

        let utf8Scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-utf8"
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "👨", scope: utf8Scope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        let utf8Completion = CodexNativeSessionController.AssistantCompletionPayload(
            scope: utf8Scope,
            text: "👨‍👩‍👧"
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(utf8Completion),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(utf8Completion),
            session: session
        )

        let removedScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-empty"
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "remove me", scope: removedScope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: removedScope, text: "")),
            session: session
        )

        let assistants = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistants.map(\.text), ["no delta", "exact", "answer.", "👨‍👩‍👧"])
        XCTAssertTrue(assistants.allSatisfy { !$0.isStreaming })
        XCTAssertNil(session.codexAssistantRowIDByScope[removedScope])
    }

    func testCanonicalAssistantCompletionFlushesEarlierPendingScopeFirst() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let firstScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-first"
        )
        let secondScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-second"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "first", scope: firstScope),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: secondScope, text: "second")),
            session: session
        )

        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["first", "second"])
        XCTAssertTrue(assistantItems.allSatisfy { !$0.isStreaming })
    }

    func testCanonicalAssistantNonPrefixCompletionReplacesMappedRowAcrossToolBoundary() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-before-tool"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "draft response", scope: scope),
            session: session
        )
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        let originalRowID = try XCTUnwrap(session.items.last?.id)
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolCall(name: "lookup", invocationID: UUID(), argsJSON: "{}"),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantCompleted(.init(scope: scope, text: "final response")),
            session: session
        )

        XCTAssertEqual(session.items.count, 2)
        XCTAssertEqual(session.items[0].id, originalRowID)
        XCTAssertEqual(session.items[0].kind, .assistant)
        XCTAssertEqual(session.items[0].text, "final response")
        XCTAssertFalse(session.items[0].isStreaming)
        XCTAssertEqual(session.items[1].kind, .toolCall)
    }

    func testCanonicalMCPResultOnlyDoesNotOverwriteDifferentInvocation() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let firstInvocationID = UUID()
        let resultOnlyInvocationID = UUID()

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolCall(
                name: "lookup",
                invocationID: firstInvocationID,
                argsJSON: #"{"query":"first"}"#
            ),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolResult(
                name: "lookup",
                invocationID: resultOnlyInvocationID,
                argsJSON: #"{"query":"second"}"#,
                resultJSON: #"{"content":"second result"}"#,
                isError: false
            ),
            session: session
        )

        let toolItems = session.items.filter { $0.kind == .toolCall || $0.kind == .toolResult }
        XCTAssertEqual(toolItems.map(\.kind), [.toolCall, .toolResult])
        XCTAssertEqual(toolItems.map(\.toolInvocationID), [firstInvocationID, resultOnlyInvocationID])
    }

    func testMismatchedBashMirrorInvocationStillReconcilesRunningRow() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let startedInvocationID = UUID()
        let completedInvocationID = UUID()
        let argsJSON = #"{"command":"printf probe"}"#

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolCall(name: "bash", invocationID: startedInvocationID, argsJSON: argsJSON),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolResult(
                name: "bash",
                invocationID: startedInvocationID,
                argsJSON: argsJSON,
                resultJSON: #"{"type":"commandExecution","status":"inProgress","processId":"probe-1","delta":"running"}"#,
                isError: false
            ),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolResult(
                name: "bash",
                invocationID: completedInvocationID,
                argsJSON: argsJSON,
                resultJSON: #"{"type":"commandExecution","status":"completed","processId":"probe-1","aggregatedOutput":"done"}"#,
                isError: false
            ),
            session: session
        )

        let toolItems = session.items.filter { $0.kind == .toolCall || $0.kind == .toolResult }
        XCTAssertEqual(toolItems.count, 1)
        XCTAssertEqual(toolItems.first?.toolInvocationID, completedInvocationID)
    }

    func testReasoningSealsEarlierPendingAssistantBeforeMaterializing() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let assistantScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-before-reasoning"
        )
        let reasoningScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "reasoning-after-assistant"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .canonicalAssistantDelta(text: "assistant first", scope: assistantScope),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningDelta(.init(
                text: "draft reasoning",
                kind: .summary,
                itemID: reasoningScope.itemID,
                groupID: "summary:\(reasoningScope.itemID):0",
                index: 0,
                scope: reasoningScope
            )),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningCompleted(.init(
                scope: reasoningScope,
                summary: ["final reasoning"],
                content: []
            )),
            session: session
        )

        XCTAssertEqual(
            session.items.filter { $0.kind == .assistant || $0.kind == .thinking }.map(\.kind),
            [.assistant, .thinking]
        )
        XCTAssertEqual(
            session.items.filter { $0.kind == .assistant || $0.kind == .thinking }.map(\.text),
            ["assistant first", "final reasoning"]
        )
    }

    func testCanonicalReasoningCompletionMaterializesReplacesAndRemovesSegments() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "reasoning-item"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningDelta(.init(
                text: "Draft summary",
                kind: .summary,
                itemID: scope.itemID,
                groupID: "summary:\(scope.itemID):0",
                index: 0,
                scope: scope
            )),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningDelta(.init(
                text: "orphan body",
                kind: .text,
                itemID: scope.itemID,
                groupID: "text:\(scope.itemID):1",
                index: 1,
                scope: scope
            )),
            session: session
        )
        XCTAssertEqual(session.items.count(where: { $0.kind == .thinking }), 2)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningCompleted(.init(
                scope: scope,
                summary: ["Final summary"],
                content: ["Final body"]
            )),
            session: session
        )

        var thinkingItems = session.items.filter { $0.kind == .thinking }
        XCTAssertEqual(thinkingItems.map(\.text), ["Final summary\n\nFinal body"])
        XCTAssertEqual(thinkingItems.map(\.isStreaming), [false])
        XCTAssertEqual(Set(session.codexReasoningSegmentsByKey.keys), ["reasoning:reasoning-item:0"])

        let noDeltaScope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "reasoning-no-delta"
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningCompleted(.init(
                scope: noDeltaScope,
                summary: ["First", "Second"],
                content: ["Body one", "Body two"]
            )),
            session: session
        )

        thinkingItems = session.items.filter { $0.kind == .thinking }
        XCTAssertEqual(
            thinkingItems.map(\.text),
            ["Final summary\n\nFinal body", "First\n\nBody one", "Second\n\nBody two"]
        )
        XCTAssertTrue(thinkingItems.allSatisfy { !$0.isStreaming })
    }

    func testCanonicalReasoningCompletionInsertsMissingLowerIndexBeforeStreamedRow() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "reasoning-partial"
        )

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningDelta(.init(
                text: "Second draft",
                kind: .summary,
                itemID: scope.itemID,
                groupID: "summary:\(scope.itemID):1",
                index: 1,
                scope: scope
            )),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolCall(name: "lookup", invocationID: UUID(), argsJSON: "{}"),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .reasoningCompleted(.init(
                scope: scope,
                summary: ["First", "Second"],
                content: []
            )),
            session: session
        )

        XCTAssertEqual(
            session.items.filter { $0.kind == .thinking }.map(\.text),
            ["First", "Second"]
        )
        XCTAssertEqual(
            session.items.filter { $0.kind == .thinking || $0.kind == .toolCall }.map(\.kind),
            [.thinking, .thinking, .toolCall]
        )
    }

    func testCancellationClearsCanonicalAssistantAndReasoningReconciliationState() {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let scope = CodexNativeSessionController.ItemScope(
            turnID: "turn",
            itemID: "assistant-item"
        )
        let rowID = UUID()
        session.pendingCodexAssistantScope = scope
        session.codexAssistantRowIDByScope[scope] = rowID
        session.activeReasoningItemID = rowID
        session.reasoningItemIDsByGroupID["reasoning-group"] = rowID
        session.codexReasoningSegmentsByKey["reasoning:reasoning-item:0"] = .init(
            summaryMarkdown: "draft",
            transcriptItemID: rowID
        )

        viewModel.test_codexCoordinator.drainCodexTerminalBuffersForCancellation(session)

        XCTAssertNil(session.pendingCodexAssistantScope)
        XCTAssertTrue(session.codexAssistantRowIDByScope.isEmpty)
        XCTAssertNil(session.activeReasoningItemID)
        XCTAssertTrue(session.reasoningItemIDsByGroupID.isEmpty)
        XCTAssertTrue(session.codexReasoningSegmentsByKey.isEmpty)
    }

    func testTurnCompletionClearsEmptyScheduledAssistantFlushBeforeBarrier() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let baselineDrainGeneration = session.providerTerminalDrainGeneration
        session.appendItem(.user("question", sequenceIndex: session.nextSequenceIndex))

        viewModel.test_codexCoordinator.test_enqueueAssistantDelta("answer", session: session)
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)
        viewModel.test_codexCoordinator.test_enqueueAssistantDelta("", session: session)

        XCTAssertTrue(session.pendingAssistantDelta.isEmpty)
        XCTAssertNotNil(session.assistantDeltaFlushTask)
        XCTAssertFalse(viewModel.test_codexCoordinator.codexTerminalBuffersAreDrained(session))

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnCompleted(turnID: "turn", status: .completed),
            session: session
        )

        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["answer"])
        XCTAssertEqual(assistantItems.map(\.isStreaming), [false])
        XCTAssertTrue(session.pendingAssistantDelta.isEmpty)
        XCTAssertNil(session.assistantDeltaFlushTask)
        XCTAssertTrue(viewModel.test_codexCoordinator.codexTerminalBuffersAreDrained(session))

        let revision = try XCTUnwrap(session.lastTerminalCommitRevision)
        XCTAssertEqual(session.providerTerminalDrainGeneration, baselineDrainGeneration + 1)
        XCTAssertEqual(revision.providerDrainGeneration, session.providerTerminalDrainGeneration)
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

    func testRepeatedNoActiveSnapshotReattachesAndReconcilesMissedCompletion() async throws {
        let controller = LivenessFakeCodexController(
            snapshot: .idle,
            activeTurnIDs: [],
            latestTurnStatus: .completed
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.assistantDelta("progress"), session: session)
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        try await waitUntil(timeout: 10) {
            session.runState == .completed
        }

        XCTAssertGreaterThanOrEqual(controller.readSnapshotCountSync(), 3)
        XCTAssertEqual(controller.shutdownCountSync(), 1)
        XCTAssertEqual(controller.startOrResumeCountSync(), 1)
        XCTAssertTrue(controller.readSnapshotIncludeTurnsValuesSync().contains(true))
        XCTAssertEqual(controller.startUserTurnCountSync(), 0)
        XCTAssertTrue(controller.steerUserTurnIDsSync().isEmpty)
        XCTAssertTrue(controller.interruptedTurnIDsSync().isEmpty)
        XCTAssertTrue(session.items.contains {
            $0.kind == .system && $0.text.contains("confirmed that Codex completed the turn")
        })
        XCTAssertEqual(session.items.filter { $0.kind == .assistant }.map(\.text), ["progress"])
        XCTAssertFalse(session.items.contains { $0.kind == .error })
        XCTAssertNotNil(session.lastTerminalCommitRevision)
    }

    func testRepeatedNoActiveSnapshotReattachesAndReconcilesFailure() async throws {
        let controller = LivenessFakeCodexController(
            snapshot: .idle,
            activeTurnIDs: [],
            latestTurnStatus: .failed
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.assistantDelta("progress"), session: session)
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        try await waitUntil(timeout: 10) {
            session.runState == .failed
        }

        XCTAssertEqual(controller.shutdownCountSync(), 1)
        XCTAssertEqual(controller.startOrResumeCountSync(), 1)
        XCTAssertTrue(controller.readSnapshotIncludeTurnsValuesSync().contains(true))
        XCTAssertEqual(controller.startUserTurnCountSync(), 0)
        XCTAssertTrue(controller.steerUserTurnIDsSync().isEmpty)
        XCTAssertTrue(controller.interruptedTurnIDsSync().isEmpty)
        XCTAssertEqual(session.items.filter { $0.kind == .error }.map(\.text), [
            "Codex's last turn failed while Repo Prompt was reconnecting."
        ])
        XCTAssertNotNil(session.lastTerminalCommitRevision)
    }

    func testRepeatedNoActiveSnapshotWithoutTerminalStatusReturnsControlWithoutModelInput() async throws {
        let controller = LivenessFakeCodexController(snapshot: .idle, activeTurnIDs: [])
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(.assistantDelta("progress"), session: session)
        viewModel.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        try await waitUntil(timeout: 10) {
            session.runState == .cancelled
        }

        XCTAssertEqual(controller.shutdownCountSync(), 1)
        XCTAssertEqual(controller.startOrResumeCountSync(), 1)
        XCTAssertTrue(controller.readSnapshotIncludeTurnsValuesSync().contains(true))
        XCTAssertEqual(controller.startUserTurnCountSync(), 0)
        XCTAssertTrue(controller.steerUserTurnIDsSync().isEmpty)
        XCTAssertTrue(controller.interruptedTurnIDsSync().isEmpty)
        XCTAssertTrue(session.items.contains {
            $0.kind == .system && $0.text.contains("Send a message to continue")
        })
        XCTAssertFalse(session.items.contains { $0.kind == .error })
        XCTAssertNotNil(session.lastTerminalCommitRevision)
    }

    func testOutstandingNativeWaitAgentCallSuppressesIdleRecovery() async {
        let controller = LivenessFakeCodexController(
            snapshot: .idle,
            activeTurnIDs: [],
            outstandingBlockingNativeToolNames: ["wait_agent"]
        )
        let viewModel = makeViewModel(
            controller: controller,
            watchdogProbeThreshold: 10,
            watchdogRecoveryThreshold: 10
        )
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let originalProgressGeneration = session.codexWatchdogState.progressGeneration

        let attemptedTerminalSettlement = await viewModel.test_codexCoordinator
            .test_attemptCodexStallRecovery(session: session)

        XCTAssertFalse(attemptedTerminalSettlement)
        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(controller.shutdownCountSync(), 0)
        XCTAssertEqual(controller.startOrResumeCountSync(), 0)
        XCTAssertGreaterThan(session.codexWatchdogState.progressGeneration, originalProgressGeneration)
        XCTAssertNil(session.codexWatchdogState.lastAmbiguousProbeKind)

        session.pendingUserInputRequest = makeUserInputRequest(id: "stop-watchdog")
    }

    func testProgressDuringBlockingNativeToolProbeSupersedesStaleResult() async throws {
        let blockingToolProbeGate = LivenessSnapshotReadGate()
        let controller = LivenessFakeCodexController(
            snapshot: .idle,
            activeTurnIDs: [],
            outstandingBlockingNativeToolNames: ["wait_agent"],
            blockingNativeToolReadGate: blockingToolProbeGate
        )
        let viewModel = makeViewModel(
            controller: controller,
            watchdogProbeThreshold: 10,
            watchdogRecoveryThreshold: 10
        )
        let session = preparedCodexSession(in: viewModel, controller: controller)

        let recoveryTask = Task {
            await viewModel.test_codexCoordinator.test_attemptCodexStallRecovery(session: session)
        }
        try await waitUntil {
            blockingToolProbeGate.isWaitingSync()
        }

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("fresh provider progress"),
            session: session
        )
        let progressGenerationAfterEvent = session.codexWatchdogState.progressGeneration
        blockingToolProbeGate.release()

        let attemptedTerminalSettlement = await recoveryTask.value
        XCTAssertFalse(attemptedTerminalSettlement)
        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(controller.shutdownCountSync(), 0)
        XCTAssertEqual(controller.startOrResumeCountSync(), 0)
        XCTAssertEqual(session.codexWatchdogState.progressGeneration, progressGenerationAfterEvent)

        session.pendingUserInputRequest = makeUserInputRequest(id: "stop-watchdog")
    }

    func testWatchdogFlushesCachedExplicitErrorWhenProbeFindsNoActiveTurn() async throws {
        let controller = LivenessFakeCodexController(
            snapshot: .idle,
            activeTurnIDs: [],
            pendingTurnFailure: .init(message: "explicit watchdog error")
        )
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("progress"),
            session: session
        )

        try await waitUntil {
            session.runState == .failed
        }

        XCTAssertEqual(session.items.filter { $0.kind == .error }.map(\.text), [
            "explicit watchdog error"
        ])
        let remainingFailure = await controller.pendingTurnFailure(turnID: "turn")
        XCTAssertNil(remainingFailure)
        XCTAssertNotEqual(
            session.runningStatusText,
            "Repo Prompt thinks Codex has stalled or timed out. You can stop and resume."
        )
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
            let steeringMarker = "<<rpce-steering-provenance-same-parent>>"
            let parentWaitTask = harness.startWait()
            let externalWaitTask = harness.startExternalWait()
            try await harness.waitUntilBothBlocked()

            let ordering = CodexDrainSendOrderingRecorder()
            let controller = LivenessFakeCodexController(
                snapshot: .active(activeFlags: []),
                onSendUserTurn: { ordering.recordSend() }
            )
            let viewModel = makeViewModel(controller: controller) { runID, runAttemptID, source, steeringMessage in
                XCTAssertEqual(runID, harness.parentRunID)
                XCTAssertNotNil(runAttemptID)
                XCTAssertEqual(source, "codex-native-active-send")
                XCTAssertEqual(steeringMessage, steeringMarker)
                let drained = await harness.drain(
                    source: source,
                    steeringMessage: steeringMessage
                )
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

            let fallbackContext = AgentModeViewModel.TabSession.CodexFallbackSubmissionContext(
                queueID: UUID(),
                providerText: steeringMarker,
                images: [],
                taggedFileAttachments: [],
                draftText: steeringMarker,
                optimisticUserItemID: nil,
                origin: .manual,
                dispatchTicket: nil
            )
            let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
                session: session,
                text: fallbackContext.providerText,
                attachments: [],
                fallbackContext: fallbackContext
            )
            let parentWaitValue = try await parentWaitTask.value
            let externalWaitValue = try await externalWaitTask.value
            let parentWaitObject = try XCTUnwrap(parentWaitValue.objectValue)
            let externalWaitObject = try XCTUnwrap(externalWaitValue.objectValue)
            let parentFormattedBlocks = ToolOutputFormatter.formatAgentRun(
                args: ["op": .string("wait")],
                value: parentWaitValue
            )
            let externalFormattedBlocks = ToolOutputFormatter.formatAgentRun(
                args: ["op": .string("wait")],
                value: externalWaitValue
            )
            guard case let .text(parentFormattedWait, _, _)? = parentFormattedBlocks.first,
                  case let .text(externalFormattedWait, _, _)? = externalFormattedBlocks.first
            else {
                return XCTFail("Expected formatted agent_run.wait text")
            }
            let providerInput = try XCTUnwrap(controller.steeredUserTurnTextsSync().first)
            let completions = await harness.completionRecorder.completions()
            let registrationRemainsActive = await AgentRunSessionStore.hasActiveRegistration(
                sessionID: harness.fixture.sessionID
            )
            let orderingSnapshot = ordering.snapshot()

            XCTAssertEqual(outcome, .sent)
            XCTAssertEqual(
                parentWaitObject["wait"]?.objectValue?["result"]?.stringValue,
                "interrupted_by_steering"
            )
            XCTAssertNil(
                parentWaitObject["wait"]?.objectValue?["steering_message"]
            )
            XCTAssertEqual(
                externalWaitObject["wait"]?.objectValue?["result"]?.stringValue,
                "interrupted_by_steering"
            )
            XCTAssertEqual(
                externalWaitObject["wait"]?.objectValue?["steering_message"]?.stringValue,
                steeringMarker,
                "A different supervisor must retain the exact steering payload"
            )
            XCTAssertEqual(parentFormattedWait.components(separatedBy: steeringMarker).count - 1, 0)
            XCTAssertEqual(externalFormattedWait.components(separatedBy: steeringMarker).count - 1, 1)
            XCTAssertEqual(providerInput, steeringMarker)
            XCTAssertEqual(controller.steeredUserTurnTextsSync(), [steeringMarker])
            XCTAssertEqual(controller.startUserTurnCountSync(), 0)
            XCTAssertEqual(controller.steerUserTurnIDsSync(), ["turn"])
            XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "turn")
            XCTAssertTrue(orderingSnapshot.drainSucceeded)
            XCTAssertEqual(orderingSnapshot.activeScopeCountAtDrainCompletion, 0)
            XCTAssertTrue(orderingSnapshot.sendObservedAfterDrain)
            XCTAssertEqual(harness.activeScopeCount(), 0)
            XCTAssertEqual(harness.externalActiveScopeCount(), 0)
            XCTAssertEqual(completions.count, 2)
            XCTAssertTrue(completions.allSatisfy { $0.result == "interrupted_by_steering" })
            XCTAssertTrue(registrationRemainsActive)

            let sameParentVisibleMarkerCount =
                parentFormattedWait.components(separatedBy: steeringMarker).count - 1
                    + providerInput.components(separatedBy: steeringMarker).count - 1
            // The provider input remains authoritative; only the same-parent wait projection omits the duplicate.
            XCTAssertEqual(
                sameParentVisibleMarkerCount,
                1,
                "The same parent provider conversation must see one logical steering instruction exactly once"
            )
        }
    }

    func testActiveCodexNativeSendRejectsBeforeDispatchWhenAgentRunDrainFails() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller) { _, _, _, _ in false }
        let session = preparedCodexSession(in: viewModel, controller: controller)

        let outcome = await viewModel.test_codexCoordinator.sendCodexNativeMessage(
            session: session,
            text: "hello",
            attachments: []
        )

        guard case let .preDispatchRejected(message) = outcome else {
            return XCTFail("Expected pre-dispatch rejection, got \(outcome)")
        }
        XCTAssertTrue(message.contains("agent_run.wait"))
        XCTAssertEqual(controller.startUserTurnCountSync(), 0)
        XCTAssertTrue(controller.steerUserTurnIDsSync().isEmpty)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
        XCTAssertTrue(session.items.contains { $0.kind == .error && $0.text == message })
        XCTAssertEqual(session.runState, .running)
    }

    func testActiveCodexNativeSendRejectsBeforeDispatchWhenActiveRunChangesDuringDrain() async {
        let drainGate = LivenessSnapshotReadGate()
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller) { _, _, _, _ in
            await drainGate.wait()
            return true
        }
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let capturedRunID = session.runID

        let sendTask = Task {
            await viewModel.test_codexCoordinator.sendCodexNativeMessage(
                session: session,
                text: "hello",
                attachments: []
            )
        }
        await drainGate.waitUntilWaiting()
        session.installRunID(UUID())
        drainGate.release()

        let outcome = await sendTask.value
        guard case let .preDispatchRejected(message) = outcome else {
            return XCTFail("Expected pre-dispatch rejection, got \(outcome)")
        }
        XCTAssertTrue(message.contains("active run changed"))
        XCTAssertNotEqual(session.runID, capturedRunID)
        XCTAssertEqual(controller.startUserTurnCountSync(), 0)
        XCTAssertTrue(controller.steerUserTurnIDsSync().isEmpty)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
    }

    func testComposerActiveSendDrainRejectionRemovesOnlyOptimisticBubbleAndRestoresFullComposerState() async throws {
        let drainGate = LivenessSnapshotReadGate()
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller) { _, _, _, _ in
            await drainGate.wait()
            return false
        }
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        viewModel.test_setCurrentTabIDOverride(session.tabID)
        defer {
            drainGate.release()
            viewModel.test_setCurrentTabIDOverride(nil)
        }

        let existingUserItem = AgentChatItem.user(
            "existing confirmed user item",
            sequenceIndex: session.nextSequenceIndex
        )
        session.appendItem(existingUserItem)
        let inFlightAssistantItem = AgentChatItem.assistant(
            "in-flight assistant progress",
            sequenceIndex: session.nextSequenceIndex
        )
        session.appendItem(inFlightAssistantItem)
        let inFlightAnchor = AgentModeViewModel.TabSession.AgentTurnRuntimeAnchor(
            userItemID: existingUserItem.id,
            userSequenceIndex: existingUserItem.sequenceIndex,
            startedAt: Date(timeIntervalSinceNow: -240)
        )
        session.pendingTurnRuntimeAnchors = [inFlightAnchor]
        let runStartedAtBeforeSubmit = Date(timeIntervalSinceNow: -120)
        session.activeAgentRunStartedAt = runStartedAtBeforeSubmit

        let image = AgentImageAttachment(
            source: .localFile(path: "/tmp/rejected-composer-image.png"),
            title: "rejected-composer-image.png"
        )
        session.pendingImageAttachments = [image]
        let taggedFile = AgentTaggedFileAttachment(
            relativePath: "Sources/Feature/File.swift",
            displayName: "File.swift"
        )
        session.pendingTaggedFileAttachments = [taggedFile]
        let workflow = AgentWorkflowDefinition(
            customID: UUID(),
            displayName: "Test Workflow",
            template: "Wrapped: $ARGUMENTS"
        )
        session.selectedWorkflow = workflow

        let rawDraft = "\n  restore this draft  \n"
        let providerText = rawDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.storeDraftText(for: session.tabID, rawDraft)
        let target = try XCTUnwrap(viewModel.makeComposerSubmitTarget(tabID: session.tabID, session: session))
        let attempt = AgentComposerSubmitAttempt(
            id: UUID(),
            target: target,
            inputRevision: 1,
            noticeRevision: 0,
            rawDraftSnapshot: rawDraft
        )
        let claim: AgentModeViewModel.AgentComposerSubmitClaim
        switch viewModel.claimComposerSubmitAttempt(attempt) {
        case let .claimed(acceptedClaim):
            claim = acceptedClaim
        case let .rejected(rejection):
            return XCTFail("Expected composer submit claim, got \(rejection)")
        }

        let result = await viewModel.executeComposerSubmitAttempt(text: providerText, claim: claim)

        XCTAssertEqual(result, .submitted)
        try await waitUntil {
            drainGate.isWaitingSync()
        }
        XCTAssertEqual(viewModel.retrieveDraftText(for: session.tabID), "")
        XCTAssertTrue(session.pendingImageAttachments.isEmpty)
        XCTAssertTrue(session.pendingTaggedFileAttachments.isEmpty)
        XCTAssertNil(session.selectedWorkflow)
        XCTAssertEqual(
            session.items.filter { $0.kind == .user }.map(\.text),
            [existingUserItem.text, providerText]
        )
        // While the send is in flight, the optimistic submission has staged its
        // turn-runtime bookkeeping: prior in-flight anchor consumed into a
        // footer, new anchor pending, elapsed timer restarted.
        XCTAssertEqual(session.pendingTurnRuntimeAnchors.count, 1)
        XCTAssertNotEqual(session.pendingTurnRuntimeAnchors.first?.userItemID, existingUserItem.id)
        XCTAssertNotNil(session.agentMessageRuntimeFootersByItemID[inFlightAssistantItem.id])
        XCTAssertNotEqual(session.activeAgentRunStartedAt, runStartedAtBeforeSubmit)

        // Simulate newer runtime activity winning the same footer while the
        // pre-dispatch drain remains suspended.
        let newerFooter = AgentMessageRuntimeFooter(
            itemID: inFlightAssistantItem.id,
            anchorDate: inFlightAnchor.startedAt,
            completedDate: Date(),
            statusText: "Newer runtime footer"
        )
        session.agentMessageRuntimeFootersByItemID[inFlightAssistantItem.id] = newerFooter

        drainGate.release()
        try await waitUntil {
            viewModel.draftRestorationEvent?.text == rawDraft
                && session.items.contains { $0.kind == .error && $0.text.contains("agent_run.wait") }
        }

        XCTAssertEqual(
            session.items.filter { $0.kind == .user }.map(\.id),
            [existingUserItem.id]
        )
        XCTAssertEqual(viewModel.retrieveDraftText(for: session.tabID), rawDraft)
        XCTAssertEqual(viewModel.draftRestorationEvent?.strategy, .replaceAlways)
        XCTAssertEqual(session.pendingImageAttachments, [image])
        XCTAssertEqual(session.pendingTaggedFileAttachments, [taggedFile])
        XCTAssertEqual(session.selectedWorkflow, workflow)
        XCTAssertEqual(viewModel.selectedWorkflow, workflow)
        // The newer footer remains authoritative, and its already-accounted
        // anchor is not reinserted for a second attribution.
        XCTAssertTrue(session.pendingTurnRuntimeAnchors.isEmpty)
        XCTAssertEqual(
            session.agentMessageRuntimeFootersByItemID[inFlightAssistantItem.id],
            newerFooter
        )
        XCTAssertEqual(session.activeAgentRunStartedAt, runStartedAtBeforeSubmit)
        XCTAssertEqual(controller.startUserTurnCountSync(), 0)
        XCTAssertTrue(controller.steerUserTurnIDsSync().isEmpty)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
    }

    func testComposerActiveSendDrainRejectionDoesNotOverwriteNewerComposerChoices() async throws {
        let drainGate = LivenessSnapshotReadGate()
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller) { _, _, _, _ in
            await drainGate.wait()
            return false
        }
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        viewModel.test_setCurrentTabIDOverride(session.tabID)
        defer {
            drainGate.release()
            viewModel.test_setCurrentTabIDOverride(nil)
        }

        let rejectedTaggedFile = AgentTaggedFileAttachment(
            relativePath: "Sources/Feature/File.swift",
            displayName: "File.swift"
        )
        session.pendingTaggedFileAttachments = [rejectedTaggedFile]
        let rejectedWorkflow = AgentWorkflowDefinition(
            customID: UUID(),
            displayName: "Rejected Workflow"
        )
        session.selectedWorkflow = rejectedWorkflow

        let rawDraft = "rejected draft"
        viewModel.storeDraftText(for: session.tabID, rawDraft)
        let target = try XCTUnwrap(viewModel.makeComposerSubmitTarget(tabID: session.tabID, session: session))
        let attempt = AgentComposerSubmitAttempt(
            id: UUID(),
            target: target,
            inputRevision: 1,
            noticeRevision: 0,
            rawDraftSnapshot: rawDraft
        )
        let claim: AgentModeViewModel.AgentComposerSubmitClaim
        switch viewModel.claimComposerSubmitAttempt(attempt) {
        case let .claimed(acceptedClaim):
            claim = acceptedClaim
        case let .rejected(rejection):
            return XCTFail("Expected composer submit claim, got \(rejection)")
        }
        let result = await viewModel.executeComposerSubmitAttempt(text: rawDraft, claim: claim)
        XCTAssertEqual(result, .submitted)
        try await waitUntil {
            drainGate.isWaitingSync()
        }

        // While the rejected submission is still in flight, the user makes
        // newer composer choices; the restoration must not displace them.
        let newerWorkflow = AgentWorkflowDefinition(
            customID: UUID(),
            displayName: "Newer Workflow"
        )
        viewModel.selectWorkflow(newerWorkflow)
        viewModel.selectWorkflow(nil)
        let newerTaggedFile = AgentTaggedFileAttachment(
            relativePath: "Sources/Feature/Other.swift",
            displayName: "Other.swift"
        )
        session.pendingTaggedFileAttachments = [newerTaggedFile]
        viewModel.storeDraftText(for: session.tabID, "newer typing")

        drainGate.release()
        try await waitUntil {
            viewModel.draftRestorationEvent != nil
                && session.items.contains { $0.kind == .error && $0.text.contains("agent_run.wait") }
        }

        XCTAssertNil(session.selectedWorkflow)
        XCTAssertNil(viewModel.selectedWorkflow)
        XCTAssertEqual(
            session.pendingTaggedFileAttachments,
            [rejectedTaggedFile, newerTaggedFile]
        )
        XCTAssertEqual(
            viewModel.retrieveDraftText(for: session.tabID),
            "rejected draft\nnewer typing"
        )
        let restorationEvent = try XCTUnwrap(viewModel.draftRestorationEvent)
        XCTAssertEqual(restorationEvent.strategy, .replaceAlways)
        let restorationOperation = try XCTUnwrap(restorationEvent.operation)
        XCTAssertEqual(
            AgentComposerDraftRestorationReducer.apply(
                restorationOperation,
                to: "newer typing after model composition",
                lastAppliedRestorationEventID: restorationOperation.previousRestorationEventID
            ),
            "rejected draft\nnewer typing after model composition"
        )

        let unappliedEarlierEventID = UUID()
        let coalescedOperation = AgentComposerDraftRestorationOperation(
            rejectedDraftText: "second rejected draft",
            draftTextBeforeRestoration: "first rejected draft",
            composedDraftText: "second rejected draft\nfirst rejected draft",
            previousRestorationEventID: unappliedEarlierEventID
        )
        XCTAssertEqual(
            AgentComposerDraftRestorationReducer.apply(
                coalescedOperation,
                to: "typing before either event rendered",
                lastAppliedRestorationEventID: nil
            ),
            "second rejected draft\nfirst rejected draft\ntyping before either event rendered"
        )
    }

    func testComposerTabSessionReplacementBeforeDispatchRestoresIntoAuthoritativeSession() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let sourceSession = preparedCodexSession(in: viewModel, controller: controller)
        sourceSession.testInstallPersistentSessionBinding(sessionID: UUID())
        viewModel.test_setCurrentTabIDOverride(sourceSession.tabID)
        defer {
            viewModel.test_setCurrentTabIDOverride(nil)
        }

        let blockingTicket = sourceSession.codexDispatchSerialGate.issueTicket()
        let rejectedImage = AgentImageAttachment(
            source: .localFile(path: "/tmp/rejected-session-image.png"),
            title: "rejected-session-image.png"
        )
        let rejectedTaggedFile = AgentTaggedFileAttachment(
            relativePath: "Sources/Feature/Rejected.swift",
            displayName: "Rejected.swift"
        )
        let rejectedWorkflow = AgentWorkflowDefinition(
            customID: UUID(),
            displayName: "Rejected Workflow"
        )
        sourceSession.pendingImageAttachments = [rejectedImage]
        sourceSession.pendingTaggedFileAttachments = [rejectedTaggedFile]
        sourceSession.selectedWorkflow = rejectedWorkflow
        sourceSession.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())

        let rejectedDraft = "rejected draft"
        viewModel.storeDraftText(for: sourceSession.tabID, rejectedDraft)
        let target = try XCTUnwrap(
            viewModel.makeComposerSubmitTarget(tabID: sourceSession.tabID, session: sourceSession)
        )
        let attempt = AgentComposerSubmitAttempt(
            id: UUID(),
            target: target,
            inputRevision: 1,
            noticeRevision: 0,
            rawDraftSnapshot: rejectedDraft
        )
        let claim: AgentModeViewModel.AgentComposerSubmitClaim
        switch viewModel.claimComposerSubmitAttempt(attempt) {
        case let .claimed(acceptedClaim):
            claim = acceptedClaim
        case let .rejected(rejection):
            return XCTFail("Expected composer submit claim, got \(rejection)")
        }

        let result = await viewModel.executeComposerSubmitAttempt(text: rejectedDraft, claim: claim)
        XCTAssertEqual(result, .submitted)
        XCTAssertEqual(sourceSession.items.count(where: { $0.kind == .user }), 1)
        XCTAssertEqual(sourceSession.pendingTurnRuntimeAnchors.count, 1)
        XCTAssertNotNil(sourceSession.pendingCodexComputerUseActivation)

        let replacementSession = AgentModeViewModel.TabSession(tabID: sourceSession.tabID)
        replacementSession.selectedAgent = .codexExec
        viewModel.test_installLiveSession(replacementSession)
        let newerImage = AgentImageAttachment(
            source: .localFile(path: "/tmp/newer-session-image.png"),
            title: "newer-session-image.png"
        )
        let newerTaggedFile = AgentTaggedFileAttachment(
            relativePath: "Sources/Feature/Newer.swift",
            displayName: "Newer.swift"
        )
        let newerWorkflow = AgentWorkflowDefinition(
            customID: UUID(),
            displayName: "Newer Workflow"
        )
        replacementSession.pendingImageAttachments = [newerImage]
        replacementSession.pendingTaggedFileAttachments = [newerTaggedFile]
        viewModel.storeDraftText(for: replacementSession.tabID, "newer typing")
        viewModel.selectWorkflow(newerWorkflow)

        let restoration = expectation(description: "composer restored into replacement session")
        var cancellable: AnyCancellable?
        cancellable = viewModel.$draftRestorationEvent
            .compactMap(\.self)
            .filter { $0.tabID == replacementSession.tabID }
            .sink { _ in restoration.fulfill() }
        sourceSession.codexDispatchSerialGate.finish(blockingTicket)
        await fulfillment(of: [restoration], timeout: 2)
        withExtendedLifetime(cancellable) {}

        XCTAssertTrue(sourceSession.items.filter { $0.kind == .user }.isEmpty)
        XCTAssertTrue(sourceSession.pendingTurnRuntimeAnchors.isEmpty)
        XCTAssertNil(sourceSession.pendingCodexComputerUseActivation)
        XCTAssertTrue(replacementSession.items.filter { $0.kind == .user }.isEmpty)
        XCTAssertEqual(
            replacementSession.pendingImageAttachments,
            [rejectedImage, newerImage]
        )
        XCTAssertEqual(
            replacementSession.pendingTaggedFileAttachments,
            [rejectedTaggedFile, newerTaggedFile]
        )
        XCTAssertEqual(replacementSession.selectedWorkflow, newerWorkflow)
        XCTAssertEqual(viewModel.selectedWorkflow, newerWorkflow)
        XCTAssertEqual(
            viewModel.retrieveDraftText(for: replacementSession.tabID),
            "rejected draft\nnewer typing"
        )
        XCTAssertEqual(viewModel.draftRestorationEvent?.strategy, .replaceAlways)
        XCTAssertEqual(controller.startUserTurnCountSync(), 0)
        XCTAssertTrue(controller.steerUserTurnIDsSync().isEmpty)
        XCTAssertTrue(sourceSession.codexFallbackQueue.isEmpty)
        XCTAssertTrue(replacementSession.codexFallbackQueue.isEmpty)
    }

    func testBackToBackComposerActiveSendDrainRejectionsRestoreEachDraftExactlyOnce() async throws {
        let drainGate = LivenessSnapshotReadGate()
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller) { _, _, _, _ in
            await drainGate.wait()
            return false
        }
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        viewModel.test_setCurrentTabIDOverride(session.tabID)
        defer {
            drainGate.release()
            viewModel.test_setCurrentTabIDOverride(nil)
        }

        let existingUserItem = AgentChatItem.user(
            "existing confirmed user item",
            sequenceIndex: session.nextSequenceIndex
        )
        session.appendItem(existingUserItem)
        let existingAssistantItem = AgentChatItem.assistant(
            "existing assistant progress",
            sequenceIndex: session.nextSequenceIndex
        )
        session.appendItem(existingAssistantItem)
        let originalAnchor = AgentModeViewModel.TabSession.AgentTurnRuntimeAnchor(
            userItemID: existingUserItem.id,
            userSequenceIndex: existingUserItem.sequenceIndex,
            startedAt: Date(timeIntervalSinceNow: -240)
        )
        session.pendingTurnRuntimeAnchors = [originalAnchor]
        let originalRunStartedAt = Date(timeIntervalSinceNow: -120)
        session.activeAgentRunStartedAt = originalRunStartedAt

        func submitDraft(_ draft: String) async throws {
            viewModel.storeDraftText(for: session.tabID, draft)
            let target = try XCTUnwrap(viewModel.makeComposerSubmitTarget(tabID: session.tabID, session: session))
            let attempt = AgentComposerSubmitAttempt(
                id: UUID(),
                target: target,
                inputRevision: 1,
                noticeRevision: 0,
                rawDraftSnapshot: draft
            )
            let claim: AgentModeViewModel.AgentComposerSubmitClaim
            switch viewModel.claimComposerSubmitAttempt(attempt) {
            case let .claimed(acceptedClaim):
                claim = acceptedClaim
            case let .rejected(rejection):
                return XCTFail("Expected composer submit claim, got \(rejection)")
            }
            let result = await viewModel.executeComposerSubmitAttempt(text: draft, claim: claim)
            XCTAssertEqual(result, .submitted)
        }

        try await submitDraft("repeated rejected draft")
        try await submitDraft("repeated rejected draft")
        try await waitUntil {
            drainGate.isWaitingSync()
        }
        XCTAssertEqual(viewModel.retrieveDraftText(for: session.tabID), "")
        XCTAssertEqual(
            session.items.filter { $0.kind == .user }.map(\.text),
            [existingUserItem.text, "repeated rejected draft", "repeated rejected draft"]
        )

        let expectedComposedDraft = "repeated rejected draft\nrepeated rejected draft"
        drainGate.release()
        try await waitUntil {
            session.items.count(where: { $0.kind == .error && $0.text.contains("agent_run.wait") }) == 2
                && viewModel.retrieveDraftText(for: session.tabID) == expectedComposedDraft
        }

        // Each rejected draft is restored exactly once, both optimistic
        // bubbles are removed, and no undelivered-turn anchors remain.
        XCTAssertEqual(viewModel.retrieveDraftText(for: session.tabID), expectedComposedDraft)
        XCTAssertEqual(
            session.items.filter { $0.kind == .user }.map(\.id),
            [existingUserItem.id]
        )
        XCTAssertEqual(session.pendingTurnRuntimeAnchors, [originalAnchor])
        XCTAssertTrue(session.agentMessageRuntimeFootersByItemID.isEmpty)
        XCTAssertEqual(session.activeAgentRunStartedAt, originalRunStartedAt)
        XCTAssertTrue(session.codexFallbackQueue.isEmpty)
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

    // MARK: - Shutdown run-identity scoping

    func testIdleReclaimShutdownSkipsTailWhenSuccessorStartsDuringRetirement() async {
        let shutdownGate = LivenessSnapshotReadGate()
        let controller = LivenessFakeCodexController(
            snapshot: .idle,
            shutdownGate: shutdownGate
        )
        let viewModel = makeViewModel(controller: controller)
        let session = viewModel.session(for: UUID())
        session.selectedAgent = .codexExec
        // Post-run idle shape: a completed run's identity is retained for
        // follow-up reuse; no attempt ownership is active.
        let retainedRunID = UUID()
        session.installRunID(retainedRunID)
        session.runState = .completed
        session.codexController = controller

        let shutdownTask = Task {
            await viewModel.test_codexCoordinator.shutdownCodexSession(
                session,
                reclaimOnlyIfStillIdle: true
            )
        }
        await shutdownGate.waitUntilWaiting()

        // A follow-up begins while the idle reclaim is suspended in controller
        // retirement. Codex follow-ups reuse the retained run ID, so run-ID
        // staleness alone cannot detect the successor — the reclaim tail must
        // key off idle/ownership/controller state instead.
        let successorController = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let successorOwnership = session.beginRunAttempt(source: "test.idleReclaimSuccessor")
        session.runState = .running
        session.codexController = successorController
        XCTAssertEqual(session.runID, retainedRunID)

        shutdownGate.release()
        await shutdownTask.value

        XCTAssertEqual(
            session.runID,
            retainedRunID,
            "idle reclaim must not clear a successor's (reused) run identity"
        )
        XCTAssertEqual(session.activeRunOwnership, successorOwnership)
        XCTAssertNotNil(session.codexController)
        XCTAssertEqual(session.runState, .running)
    }

    func testIdleReclaimShutdownClearsRetainedRunIdentityWhenStillIdle() async {
        let controller = LivenessFakeCodexController(snapshot: .idle)
        let viewModel = makeViewModel(controller: controller)
        let session = viewModel.session(for: UUID())
        session.selectedAgent = .codexExec
        session.installRunID(UUID())
        session.runState = .completed
        session.codexController = controller

        await viewModel.test_codexCoordinator.shutdownCodexSession(
            session,
            reclaimOnlyIfStillIdle: true
        )

        XCTAssertNil(session.runID, "still-idle reclaim performs the normal shutdown tail")
        XCTAssertNil(session.codexController)
        XCTAssertEqual(controller.shutdownCountSync(), 1)
    }

    func testWorkspaceSwitchFinalizeDetachCapturesCodexControllerAndRetiresHandleOnly() async {
        let controller = LivenessFakeCodexController(snapshot: .idle)
        let viewModel = makeViewModel(controller: controller)
        let session = viewModel.session(for: UUID())
        session.selectedAgent = .codexExec
        let preparedRunID = UUID()
        session.installRunID(preparedRunID)
        session.codexController = controller

        let detached = viewModel.test_codexCoordinator.detachForWorkspaceSwitchFinalizeSync(
            session,
            runIDs: [preparedRunID]
        )
        XCTAssertNotNil(detached)
        XCTAssertNil(session.codexController)
        XCTAssertEqual(
            controller.shutdownCountSync(),
            0,
            "finalize detach is synchronous; the process shuts down at retire time"
        )

        // Successor state installed after finalize must not be touched by the
        // handle-only retire.
        let successorRunID = UUID()
        session.installRunID(successorRunID)
        let successorController = LivenessFakeCodexController(snapshot: .idle)
        session.codexController = successorController

        guard let detached else { return }
        await viewModel.test_codexCoordinator.retireDetachedControllerForWorkspaceSwitch(detached)
        XCTAssertEqual(controller.shutdownCountSync(), 1)
        XCTAssertEqual(
            session.runID,
            successorRunID,
            "handle retire must not clear a successor's run identity"
        )
        XCTAssertTrue((session.codexController as AnyObject) === successorController)
        XCTAssertEqual(successorController.shutdownCountSync(), 0)
    }

    private func makeCommandToolItem(
        turnID: String = "turn",
        itemID: UUID,
        processID: String?,
        status: CodexNativeSessionController.ThreadSnapshot.ToolItemObservation.Status
    ) -> CodexNativeSessionController.ThreadSnapshot.ToolItemObservation {
        .init(
            turnID: turnID,
            itemID: itemID.uuidString,
            invocationID: itemID,
            kind: .commandExecution,
            toolName: nil,
            processID: processID,
            status: status
        )
    }

    private func openRunningCommand(
        invocationID: UUID,
        processID: String,
        command: String = "sleep 420",
        viewModel: AgentModeViewModel,
        session: AgentModeViewModel.TabSession
    ) async {
        let argsJSON = #"{"command":"\#(command)"}"#
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .toolCall(name: "bash", invocationID: invocationID, argsJSON: argsJSON),
            session: session
        )
        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .commandExecutionRunning(.init(
                invocationID: invocationID,
                processID: processID,
                appendedOutput: nil
            )),
            session: session
        )
    }

    func testPendingCodexHookReviewSuppressesStallWatchdog() async throws {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(
            controller: controller,
            watchdogProbeThreshold: 0.02,
            watchdogRecoveryThreshold: 0.06
        )
        let session = preparedCodexSession(in: viewModel, controller: controller)
        session.pendingCodexHookReview = makeHookReviewRequest(for: session)
        session.runState = .waitingForApproval

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .assistantDelta("blocked"),
            session: session,
            sourceController: controller
        )
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(controller.readSnapshotCountSync(), 0)
        XCTAssertNotNil(session.pendingCodexHookReview)
    }

    func testTurnStartedDoesNotClearBindingScopedCodexHookReview() async {
        let controller = LivenessFakeCodexController(snapshot: .active(activeFlags: []))
        let viewModel = makeViewModel(controller: controller)
        let session = preparedCodexSession(in: viewModel, controller: controller)
        let request = makeHookReviewRequest(for: session)
        session.pendingCodexHookReview = request
        session.runState = .waitingForApproval

        await viewModel.test_codexCoordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "replacement-turn"),
            session: session,
            sourceController: controller
        )

        XCTAssertEqual(session.pendingCodexHookReview?.id, request.id)
    }

    private func makeHookReviewRequest(
        for session: AgentModeViewModel.TabSession
    ) -> AgentCodexHookReviewRequest {
        AgentCodexHookReviewRequest(
            tabID: session.tabID,
            runAttemptID: session.activeRunAttemptID,
            runID: session.runID,
            executionCWD: "/tmp",
            hooks: [],
            phase: .discoveryFailed,
            errorMessage: "Discovery failed",
            gateGeneration: session.codexHookGateGeneration
        )
    }

    private func makeViewModel(
        controller: LivenessFakeCodexController,
        drain: AgentModeViewModel.CodexAgentRunWaitDrain? = nil,
        watchdogProbeThreshold: TimeInterval = 0.02,
        watchdogRecoveryThreshold: TimeInterval = 0.06
    ) -> AgentModeViewModel {
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in controller },
            testCodexActiveAgentRunWaitDrain: drain,
            testCodexStallWatchdogPollIntervalNanos: 10_000_000,
            testCodexStallWatchdogProbeThreshold: watchdogProbeThreshold,
            testCodexStallWatchdogRecoveryThreshold: watchdogRecoveryThreshold
        )
        viewModel.test_initializeRunService()
        retainedHosts.append(viewModel)
        return viewModel
    }

    private func preparedCodexSession(
        in viewModel: AgentModeViewModel,
        controller: LivenessFakeCodexController,
        runID: UUID? = UUID()
    ) -> AgentModeViewModel.TabSession {
        let session = viewModel.session(for: UUID())
        session.selectedAgent = .codexExec
        if let runID {
            session.installRunID(runID)
        }
        session.runState = .running
        session.beginRunAttempt(source: "test.codexLiveness")
        session.codexController = controller
        session.codexControllerPermissionProfile = session.permissionProfile
        session.codexControllerTaskLabelKind = session.mcpControlContext?.taskLabelKind
        session.codexControllerWorkspacePaths = .uniform(nil)
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
        session.codexControllerFeatureState = .init(
            computerUseEnabled: false,
            goalSupportEnabled: CodexGoalSupport.isEnabled,
            reasoningSummariesEnabled: CodexReasoningSummaries.isEnabled,
            memoriesEnabled: CodexMemories.isEnabled
        )
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

private enum LivenessSnapshotError: Error {
    case probeFailed
}

private final class LivenessSnapshotReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var waitingObservers: [CheckedContinuation<Void, Never>] = []
    private var started = false
    private var released = false

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResumeImmediately: Bool
            let observersToResume: [CheckedContinuation<Void, Never>]
            lock.lock()
            started = true
            if released {
                shouldResumeImmediately = true
                observersToResume = []
            } else {
                shouldResumeImmediately = false
                self.continuation = continuation
                observersToResume = waitingObservers
                waitingObservers.removeAll()
            }
            lock.unlock()

            observersToResume.forEach { $0.resume() }
            if shouldResumeImmediately {
                continuation.resume()
            }
        }
    }

    func waitUntilWaiting() async {
        let shouldReturnImmediately: Bool = lock.withLock {
            if started, !released, continuation != nil {
                true
            } else {
                false
            }
        }
        if shouldReturnImmediately { return }
        await withCheckedContinuation { observer in
            let shouldResumeImmediately: Bool = lock.withLock {
                if started, !released, continuation != nil {
                    return true
                } else {
                    waitingObservers.append(observer)
                    return false
                }
            }
            if shouldResumeImmediately {
                observer.resume()
            }
        }
    }

    func isWaitingSync() -> Bool {
        lock.lock()
        let isWaiting = started && !released && continuation != nil
        lock.unlock()
        return isWaiting
    }

    func release() {
        let continuationToResume: CheckedContinuation<Void, Never>?
        lock.lock()
        released = true
        continuationToResume = continuation
        continuation = nil
        lock.unlock()

        continuationToResume?.resume()
    }
}

private final class LivenessFakeCodexController: CodexSessionControllerTurnDispatchTestDefaults {
    private var readSnapshotCount = 0
    private var readSnapshotIncludeTurnsValues: [Bool] = []
    private var startOrResumeCount = 0
    private var startOrResumeObservedCancellation = false
    private var startUserTurnCount = 0
    private var startedUserTurnTexts: [String] = []
    private var steerUserTurnIDs: [String] = []
    private var steeredUserTurnTexts: [String] = []
    private var interruptedTurnIDs: [String] = []
    private var shutdownCount = 0
    private let snapshotStatuses: [CodexNativeSessionController.ThreadSnapshot.RuntimeStatus]
    private let snapshotActiveTurnIDs: [String]
    private let snapshotLatestTurnStatus: CodexNativeSessionController.TurnStatus?
    private let activeToolItems: [CodexNativeSessionController.ThreadSnapshot.ToolItemObservation]
    private let hasAuthoritativeActiveTurnItems: Bool
    private let onSendUserTurn: (() -> Void)?
    private let steerError: Error?
    private let steerDelayNanos: UInt64
    private let startUserTurnDelayNanos: UInt64
    private let startUserTurnCancellationGate: LivenessSnapshotReadGate?
    private let alwaysFailsSnapshotRead: Bool
    private let failsEveryEvenSnapshotRead: Bool
    private let failsPostReattachSnapshotRead: Bool
    private let postReattachSnapshotStatus: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus?
    private let postReattachActiveTurnIDs: [String]?
    private let snapshotReadGate: LivenessSnapshotReadGate?
    private let postReattachSnapshotReadGate: LivenessSnapshotReadGate?
    private let shutdownGate: LivenessSnapshotReadGate?
    private let outstandingBlockingNativeToolNames: [String]
    private let blockingNativeToolReadGate: LivenessSnapshotReadGate?
    private var pendingTurnFailure: CodexNativeSessionController.TurnFailure?

    init(
        snapshot: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus,
        activeTurnIDs: [String] = ["turn"],
        snapshotSequence: [CodexNativeSessionController.ThreadSnapshot.RuntimeStatus]? = nil,
        latestTurnStatus: CodexNativeSessionController.TurnStatus? = nil,
        activeToolItems: [CodexNativeSessionController.ThreadSnapshot.ToolItemObservation] = [],
        hasAuthoritativeActiveTurnItems: Bool = false,
        onSendUserTurn: (() -> Void)? = nil,
        steerError: Error? = nil,
        steerDelayNanos: UInt64 = 0,
        startUserTurnDelayNanos: UInt64 = 0,
        startUserTurnCancellationGate: LivenessSnapshotReadGate? = nil,
        alwaysFailsSnapshotRead: Bool = false,
        failsEveryEvenSnapshotRead: Bool = false,
        failsPostReattachSnapshotRead: Bool = false,
        postReattachSnapshotStatus: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus? = nil,
        postReattachActiveTurnIDs: [String]? = nil,
        snapshotReadGate: LivenessSnapshotReadGate? = nil,
        postReattachSnapshotReadGate: LivenessSnapshotReadGate? = nil,
        shutdownGate: LivenessSnapshotReadGate? = nil,
        outstandingBlockingNativeToolNames: [String] = [],
        blockingNativeToolReadGate: LivenessSnapshotReadGate? = nil,
        pendingTurnFailure: CodexNativeSessionController.TurnFailure? = nil
    ) {
        snapshotStatuses = if let snapshotSequence, !snapshotSequence.isEmpty {
            snapshotSequence
        } else {
            [snapshot]
        }
        snapshotActiveTurnIDs = activeTurnIDs
        snapshotLatestTurnStatus = latestTurnStatus
        self.activeToolItems = activeToolItems
        self.hasAuthoritativeActiveTurnItems = hasAuthoritativeActiveTurnItems
        self.onSendUserTurn = onSendUserTurn
        self.steerError = steerError
        self.steerDelayNanos = steerDelayNanos
        self.startUserTurnDelayNanos = startUserTurnDelayNanos
        self.startUserTurnCancellationGate = startUserTurnCancellationGate
        self.alwaysFailsSnapshotRead = alwaysFailsSnapshotRead
        self.failsEveryEvenSnapshotRead = failsEveryEvenSnapshotRead
        self.failsPostReattachSnapshotRead = failsPostReattachSnapshotRead
        self.postReattachSnapshotStatus = postReattachSnapshotStatus
        self.postReattachActiveTurnIDs = postReattachActiveTurnIDs
        self.snapshotReadGate = snapshotReadGate
        self.postReattachSnapshotReadGate = postReattachSnapshotReadGate
        self.shutdownGate = shutdownGate
        self.outstandingBlockingNativeToolNames = outstandingBlockingNativeToolNames
        self.blockingNativeToolReadGate = blockingNativeToolReadGate
        self.pendingTurnFailure = pendingTurnFailure
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

    func readSnapshotIncludeTurnsValuesSync() -> [Bool] {
        readSnapshotIncludeTurnsValues
    }

    func startOrResumeCountSync() -> Int {
        startOrResumeCount
    }

    func startOrResumeObservedCancellationSync() -> Bool {
        startOrResumeObservedCancellation
    }

    func startUserTurnCountSync() -> Int {
        startUserTurnCount
    }

    func startedUserTurnTextsSync() -> [String] {
        startedUserTurnTexts
    }

    func steerUserTurnIDsSync() -> [String] {
        steerUserTurnIDs
    }

    func steeredUserTurnTextsSync() -> [String] {
        steeredUserTurnTexts
    }

    func interruptedTurnIDsSync() -> [String] {
        interruptedTurnIDs
    }

    func shutdownCountSync() -> Int {
        shutdownCount
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String) async throws -> CodexNativeSessionController.SessionRef {
        startOrResumeCount += 1
        startOrResumeObservedCancellation = startOrResumeObservedCancellation || Task.isCancelled
        return CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?) async throws -> CodexNativeSessionController.SessionRef {
        startOrResumeCount += 1
        startOrResumeObservedCancellation = startOrResumeObservedCancellation || Task.isCancelled
        return CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexNativeSessionController.SessionRef {
        startOrResumeCount += 1
        startOrResumeObservedCancellation = startOrResumeObservedCancellation || Task.isCancelled
        return CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(
        includeTurns: Bool,
        timeout: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        let snapshotIndex = readSnapshotCount % snapshotStatuses.count
        readSnapshotCount += 1
        readSnapshotIncludeTurnsValues.append(includeTurns)
        let isPostReattachSnapshot = includeTurns && startOrResumeCount > 0
        if isPostReattachSnapshot, let postReattachSnapshotReadGate {
            await postReattachSnapshotReadGate.wait()
        } else if let snapshotReadGate {
            await snapshotReadGate.wait()
        }
        if alwaysFailsSnapshotRead
            || (failsEveryEvenSnapshotRead && readSnapshotCount.isMultiple(of: 2))
            || (failsPostReattachSnapshotRead && isPostReattachSnapshot)
        {
            throw LivenessSnapshotError.probeFailed
        }
        let runtimeStatus = if isPostReattachSnapshot {
            postReattachSnapshotStatus ?? snapshotStatuses[snapshotIndex]
        } else {
            snapshotStatuses[snapshotIndex]
        }
        let activeTurnIDs = if isPostReattachSnapshot {
            postReattachActiveTurnIDs ?? snapshotActiveTurnIDs
        } else {
            snapshotActiveTurnIDs
        }
        return CodexNativeSessionController.ThreadSnapshot(
            conversationID: "fake",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: runtimeStatus,
            currentTurnID: activeTurnIDs.first,
            activeTurnIDs: activeTurnIDs,
            latestTurnStatus: includeTurns ? snapshotLatestTurnStatus : nil,
            activeToolItems: includeTurns ? activeToolItems : [],
            hasAuthoritativeActiveTurnItems: includeTurns && hasAuthoritativeActiveTurnItems
        )
    }

    func outstandingBlockingNativeToolCallNames() async -> [String] {
        if let blockingNativeToolReadGate {
            await blockingNativeToolReadGate.wait()
        }
        return outstandingBlockingNativeToolNames
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
        text: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        recordSendUserTurn()
        startUserTurnCount += 1
        startedUserTurnTexts.append(text)
        if let startUserTurnCancellationGate {
            await startUserTurnCancellationGate.wait()
            throw CancellationError()
        }
        if startUserTurnDelayNanos > 0 {
            try await Task.sleep(nanoseconds: startUserTurnDelayNanos)
        }
        return CodexTurnStartReceipt(provisionalSubmissionID: "liveness-submission-\(startUserTurnCount)")
    }

    func steerUserTurn(
        text: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        recordSendUserTurn()
        steerUserTurnIDs.append(expectedTurnID)
        steeredUserTurnTexts.append(text)
        if let steerError {
            throw steerError
        }
        if steerDelayNanos > 0 {
            try await Task.sleep(nanoseconds: steerDelayNanos)
        }
        return CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        interruptedTurnIDs.append(expectedTurnID)
        return CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
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

    func pendingTurnFailure(
        turnID _: String?
    ) async -> CodexNativeSessionController.TurnFailure? {
        pendingTurnFailure
    }

    func acknowledgePendingTurnFailure(
        turnID _: String?,
        failure: CodexNativeSessionController.TurnFailure
    ) async {
        if pendingTurnFailure == failure {
            pendingTurnFailure = nil
        }
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {
        shutdownCount += 1
        if let shutdownGate {
            await shutdownGate.wait()
        }
    }

    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}
