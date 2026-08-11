import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
extension AgentModeRunServiceLifecycleTests {
    func testQueuedClaudeSteeringRecreatesControllerBeforeSendWhenPermissionsTighten() async {
        let recorder = LifecycleRecorder()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "old",
            hasTurnInFlight: true
        )
        let newController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "new",
            hasTurnInFlight: false
        )
        let harness = makeHarness(
            recorder: recorder,
            idleWaiter: { _ in recorder.record("idle") },
            claudeControllerFactory: { _, _, _, settings in
                recorder.record("factory:claude:\(settings.permissionMode ?? "nil"):\(String(describing: settings.allowNativeBashTool)):\(String(describing: settings.mcpStrictMode))")
                return newController
            }
        )
        let session = makeRunningClaudeSession(controller: oldController, host: harness.host)
        session.permissionProfile = .mcpSafeDefaults
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: ClaudeAgentToolPreferences.PermissionLevel.fullAccess.permissionMode,
            allowNativeBashTool: true,
            mcpStrictMode: false
        )
        session.pendingClaudeSteeringInstructions = [makeClaudeSteeringInstruction(session: session, text: "tighten before send")]

        let queueStarted = await harness.service.submitQueuedClaudeSteeringIfSupported(session: session)
        XCTAssertTrue(queueStarted)
        await session.claudeSteeringFlushTask?.value

        XCTAssertTrue(session.pendingClaudeSteeringInstructions.isEmpty)
        let launchSettings = harness.host.claudeCoordinator.test_controllerLaunchSettings(for: session)
        XCTAssertEqual(
            launchSettings?.permissionMode,
            ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode
        )
        XCTAssertEqual(launchSettings?.allowNativeBashTool, false)
        XCTAssertEqual(launchSettings?.mcpStrictMode, true)
        XCTAssertFalse(recorder.contains("old:send"))
        assertOrderedEvents([
            "idle",
            "old:interrupt:interrupt",
            "old:shutdown",
            "factory:claude:default:Optional(false):Optional(true)",
            "new:start",
            "new:send",
            "delivered"
        ], in: recorder)
    }

    func testQueuedClaudeSteeringRevalidatesPermissionsImmediatelyBeforeDispatch() async {
        let recorder = LifecycleRecorder()
        let eventsReadyGate = LifecycleAsyncGate()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "old",
            hasTurnInFlight: false,
            eventsStreamReadyGate: eventsReadyGate
        )
        let newController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "new",
            hasTurnInFlight: false
        )
        let harness = makeHarness(
            recorder: recorder,
            idleWaiter: { _ in recorder.record("idle") },
            claudeControllerFactory: { _, _, _, settings in
                recorder.record("factory:claude:\(settings.permissionMode ?? "nil"):\(String(describing: settings.allowNativeBashTool)):\(String(describing: settings.mcpStrictMode))")
                return newController
            }
        )
        let session = makeRunningClaudeSession(controller: oldController, host: harness.host)
        let initialProfile = AgentProviderPermissionProfile.providerOverride(.claude(.fullAccess))
        let initialRuntime = resolvedClaudeLaunchPolicy(
            profile: initialProfile,
            harness: harness
        )
        session.permissionProfile = initialProfile
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: initialRuntime?.permissionMode,
            allowNativeBashTool: initialRuntime?.allowNativeBashTool,
            mcpStrictMode: initialRuntime?.mcpStrictMode
        )
        session.pendingClaudeSteeringInstructions = [makeClaudeSteeringInstruction(session: session, text: "tighten at dispatch")]

        let queueStarted = await harness.service.submitQueuedClaudeSteeringIfSupported(session: session)
        XCTAssertTrue(queueStarted)
        await eventsReadyGate.waitUntilArrived()
        session.permissionProfile = .mcpSafeDefaults
        await eventsReadyGate.release()
        await session.claudeSteeringFlushTask?.value

        XCTAssertTrue(session.pendingClaudeSteeringInstructions.isEmpty)
        let launchSettings = harness.host.claudeCoordinator.test_controllerLaunchSettings(for: session)
        XCTAssertEqual(
            launchSettings?.permissionMode,
            ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode
        )
        XCTAssertEqual(launchSettings?.allowNativeBashTool, false)
        XCTAssertEqual(launchSettings?.mcpStrictMode, true)
        XCTAssertFalse(recorder.contains("old:send"))
        assertOrderedEvents([
            "old:start",
            "old:events-ready",
            "old:shutdown",
            "factory:claude:default:Optional(false):Optional(true)",
            "new:start",
            "new:send",
            "delivered"
        ], in: recorder)
    }

    func testQueuedClaudeSteeringRevalidatesWorkspaceImmediatelyBeforeDispatch() async {
        let recorder = LifecycleRecorder()
        let eventsReadyGate = LifecycleAsyncGate()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "old-workspace-dispatch",
            eventsStreamReadyGate: eventsReadyGate
        )
        let newController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "new-workspace-dispatch"
        )
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in
                recorder.record("factory:workspace-dispatch")
                return newController
            }
        )
        let session = makeRunningClaudeSession(controller: oldController, host: harness.host)
        let runtime = resolvedClaudeLaunchPolicy(
            profile: .mcpSafeDefaults,
            harness: harness
        )
        session.permissionProfile = .mcpSafeDefaults
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )
        session.pendingClaudeSteeringInstructions = [makeClaudeSteeringInstruction(session: session, text: "workspace at dispatch")]

        let queueStarted = await harness.service.submitQueuedClaudeSteeringIfSupported(session: session)
        XCTAssertTrue(queueStarted)
        await eventsReadyGate.waitUntilArrived()
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            workspacePath: "/stale/workspace",
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )
        await eventsReadyGate.release()
        await session.claudeSteeringFlushTask?.value

        XCTAssertTrue(session.pendingClaudeSteeringInstructions.isEmpty)
        XCTAssertFalse(recorder.contains("old-workspace-dispatch:send"))
        assertOrderedEvents([
            "old-workspace-dispatch:events-ready",
            "old-workspace-dispatch:shutdown",
            "factory:workspace-dispatch",
            "new-workspace-dispatch:start",
            "new-workspace-dispatch:send",
            "delivered"
        ], in: recorder)
    }

    func testQueuedClaudeSteeringRecycleDoesNotClearReplacementControllerAfterAwait() async {
        let recorder = LifecycleRecorder()
        let currentSessionRefGate = LifecycleAsyncGate()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "old",
            hasTurnInFlight: true,
            currentSessionRefGate: currentSessionRefGate
        )
        let replacementController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "replacement",
            hasTurnInFlight: false
        )
        let fallbackController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "fallback",
            hasTurnInFlight: false
        )
        let harness = makeHarness(
            recorder: recorder,
            idleWaiter: { _ in recorder.record("idle") },
            claudeControllerFactory: { _, _, _, _ in
                recorder.record("factory:unexpected")
                return fallbackController
            }
        )
        let session = makeRunningClaudeSession(controller: oldController, host: harness.host)
        session.permissionProfile = .mcpSafeDefaults
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: ClaudeAgentToolPreferences.PermissionLevel.fullAccess.permissionMode,
            allowNativeBashTool: true,
            mcpStrictMode: false
        )
        session.pendingClaudeSteeringInstructions = [makeClaudeSteeringInstruction(session: session, text: "replace while recycling")]

        let queueStarted = await harness.service.submitQueuedClaudeSteeringIfSupported(session: session)
        XCTAssertTrue(queueStarted)
        await currentSessionRefGate.waitUntilArrived()
        session.claudeController = replacementController
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode,
            allowNativeBashTool: false,
            mcpStrictMode: true
        )
        await currentSessionRefGate.release()
        await session.claudeSteeringFlushTask?.value

        guard let finalController = session.claudeController else {
            XCTFail("Expected replacement controller to remain installed")
            return
        }
        XCTAssertEqual(
            ObjectIdentifier(finalController as AnyObject),
            ObjectIdentifier(replacementController as AnyObject)
        )
        XCTAssertTrue(session.pendingClaudeSteeringInstructions.isEmpty)
        XCTAssertFalse(recorder.contains("factory:unexpected"))
        XCTAssertFalse(recorder.contains("old:send"))
        assertOrderedEvents([
            "idle",
            "old:interrupt:interrupt",
            "old:current-ref",
            "old:shutdown",
            "replacement:start",
            "replacement:send",
            "delivered"
        ], in: recorder)
    }

    func testClaudeWorkspaceRecycleDoesNotClearReplacementAfterCurrentSessionAwait() async throws {
        let recorder = LifecycleRecorder()
        let currentSessionRefGate = LifecycleAsyncGate()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "old-workspace",
            currentSessionRefGate: currentSessionRefGate
        )
        let replacementController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "replacement-workspace"
        )
        let fallbackController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "fallback-workspace"
        )
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in
                recorder.record("factory:workspace-unexpected")
                return fallbackController
            }
        )
        let session = makeRunningClaudeSession(controller: oldController, host: harness.host)
        let runtime = resolvedClaudeLaunchPolicy(
            profile: .mcpSafeDefaults,
            harness: harness
        )
        let currentWorkspacePath = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        ).standardizedFileURL.path
        session.permissionProfile = .mcpSafeDefaults
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            workspacePath: "/stale/workspace",
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )

        let ownership = try XCTUnwrap(session.activeRunOwnership)
        let runID = try XCTUnwrap(session.runID)
        let ensureTask = Task {
            await harness.host.claudeCoordinator.ensureClaudeNativeSession(
                session: session,
                intent: .runAttempt(ownership: ownership, runID: runID)
            )
        }
        await currentSessionRefGate.waitUntilArrived()
        session.claudeController = replacementController
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            workspacePath: currentWorkspacePath,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )
        await currentSessionRefGate.release()
        _ = await ensureTask.value

        guard let finalController = session.claudeController else {
            XCTFail("Expected replacement workspace controller to remain installed")
            return
        }
        XCTAssertEqual(
            ObjectIdentifier(finalController as AnyObject),
            ObjectIdentifier(replacementController as AnyObject)
        )
        XCTAssertFalse(recorder.contains("factory:workspace-unexpected"))
        assertOrderedEvents([
            "old-workspace:current-ref",
            "old-workspace:shutdown"
        ], in: recorder)
    }

    func testClaudeSendCompletionDoesNotFailReplacementController() async throws {
        let recorder = LifecycleRecorder()
        let sendGate = LifecycleAsyncGate()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "stale-send",
            sendUserMessageGate: sendGate
        )
        let replacementController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "replacement-send"
        )
        let harness = makeHarness(
            recorder: recorder,
            claudeController: oldController
        )
        let session = makeRunningClaudeSession(controller: oldController, host: harness.host)
        let runtime = resolvedClaudeLaunchPolicy(
            profile: session.permissionProfile,
            harness: harness
        )
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )

        let ownership = try XCTUnwrap(session.activeRunOwnership)
        let runID = try XCTUnwrap(session.runID)
        let readiness = await harness.host.claudeCoordinator.ensureClaudeNativeSession(
            session: session,
            intent: .runAttempt(ownership: ownership, runID: runID)
        )
        guard readiness == .ready else {
            return XCTFail("Expected the exact live session to be ready before the send race, got \(readiness)")
        }
        let sendTask = Task {
            await harness.host.claudeCoordinator.sendClaudeNativeMessage(
                session: session,
                text: "do not fail replacement",
                attachments: [],
                intent: .runAttempt(ownership: ownership, runID: runID)
            )
        }
        await sendGate.waitUntilArrived()
        session.claudeController = replacementController
        await sendGate.release()

        let sendOutcome = await sendTask.value
        XCTAssertEqual(sendOutcome, .superseded)
        guard let finalController = session.claudeController else {
            XCTFail("Expected replacement controller to remain installed")
            return
        }
        XCTAssertEqual(
            ObjectIdentifier(finalController as AnyObject),
            ObjectIdentifier(replacementController as AnyObject)
        )
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
        XCTAssertTrue(recorder.contains("stale-send:shutdown"))
    }

    func testClaudeRunnerSettlesCurrentAttemptWhenControllerReplacementSupersedesSend() async throws {
        let recorder = LifecycleRecorder()
        let sendGate = LifecycleAsyncGate()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "runner-superseded",
            sendUserMessageGate: sendGate
        )
        let replacementController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "runner-replacement"
        )
        let harness = makeHarness(
            recorder: recorder,
            claudeController: oldController
        )
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.claudeController = oldController
        harness.host.test_installLiveSession(session)
        let runtime = resolvedClaudeLaunchPolicy(
            profile: session.permissionProfile,
            harness: harness
        )
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )

        _ = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "settle superseded send",
            initialMessageForRun: "settle superseded send",
            attachments: []
        )
        let ownership = try XCTUnwrap(session.activeRunOwnership)
        await sendGate.waitUntilArrived()
        let agentTask = try XCTUnwrap(session.agentTask)
        session.claudeController = replacementController
        await sendGate.release()
        await agentTask.value

        XCTAssertEqual(session.runState, .cancelled)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertEqual(session.lastTerminalCommitRevision?.ownership, ownership)
        XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, .cancelled)
        XCTAssertEqual(recorder.events.count(where: { $0.hasPrefix("commit:") }), 1)
        XCTAssertEqual(recorder.events.count(where: { $0 == "run-active:false" }), 1)
        XCTAssertEqual(recorder.events.count(where: { $0 == "handoff:false" }), 1)
        XCTAssertTrue(recorder.contains("attachments:deleteFiles"))
        XCTAssertTrue(recorder.contains("runner-superseded:shutdown"))
        XCTAssertFalse(recorder.contains("runner-replacement:shutdown"))
    }

    func testClaudeRunnerClassifiesNativeTerminalEventsThroughSharedExecutionCore() async throws {
        let rows: [(
            name: String,
            nativeStatus: NativeAgentRuntimeTurnStatus,
            expectedState: AgentSessionRunState
        )] = [
            ("completed", .completed, .completed),
            ("cancelled", .cancelled, .cancelled),
            ("failed", .failed, .failed)
        ]

        for row in rows {
            let recorder = LifecycleRecorder()
            let controller = LifecycleFakeNativeController(
                recorder: recorder,
                label: "terminal-\(row.name)",
                turnStatusOnSend: row.nativeStatus
            )
            let harness = makeHarness(recorder: recorder, claudeController: controller)
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            session.selectedAgent = .claudeCode
            harness.host.test_installLiveSession(session)

            _ = await harness.service.startRun(
                tabID: session.tabID,
                session: session,
                initialUserMessage: row.name,
                initialMessageForRun: row.name,
                attachments: []
            )
            let ownership = try XCTUnwrap(session.activeRunOwnership)
            let agentTask = try XCTUnwrap(session.agentTask)
            await agentTask.value

            XCTAssertEqual(session.runState, row.expectedState, row.name)
            XCTAssertNil(session.activeRunOwnership, row.name)
            XCTAssertEqual(session.lastTerminalCommitRevision?.ownership, ownership, row.name)
            XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, row.expectedState, row.name)
            XCTAssertEqual(recorder.events.count(where: { $0.hasPrefix("commit:") }), 1, row.name)
            XCTAssertEqual(recorder.events.count(where: { $0 == "run-active:false" }), 1, row.name)
            XCTAssertEqual(recorder.events.count(where: { $0 == "handoff:true" }), 1, row.name)
            XCTAssertEqual(recorder.events.count(where: { $0 == "handoff:false" }), 0, row.name)
            XCTAssertTrue(recorder.contains("attachments:deleteFiles"), row.name)
            XCTAssertNotNil(session.claudeController, row.name)
            XCTAssertFalse(recorder.contains("terminal-\(row.name):shutdown"), row.name)
        }
    }

    func testClaudeRunnerPreservesUnexpectedStreamEndFailureEvidenceWithoutShutdown() async throws {
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            label: "stream-end",
            finishEventsAfterSend: true
        )
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        harness.host.test_installLiveSession(session)

        _ = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "end stream",
            initialMessageForRun: "end stream",
            attachments: []
        )
        let agentTask = try XCTUnwrap(session.agentTask)
        await agentTask.value

        XCTAssertEqual(session.runState, .failed)
        XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, .failed)
        XCTAssertEqual(
            session.items.last(where: { $0.kind == .error })?.text,
            "Claude events stream ended unexpectedly. The run may need to be restarted."
        )
        XCTAssertEqual(recorder.events.count(where: { $0.hasPrefix("commit:") }), 1)
        XCTAssertEqual(recorder.events.count(where: { $0 == "handoff:true" }), 1)
        XCTAssertEqual(recorder.events.count(where: { $0 == "handoff:false" }), 0)
        XCTAssertNotNil(session.claudeController)
        XCTAssertFalse(recorder.contains("stream-end:shutdown"))
    }

    func testClaudeRunnerPreservesRuntimeInitFailureShutdownPolicy() async throws {
        let recorder = LifecycleRecorder()
        let runtimeInitFailure = NativeAgentRuntimeRuntimeInitStatus(
            sessionID: "runtime-init-failure",
            tools: [],
            mcpServerStatuses: [MCPIntegrationHelper.repoPromptMCPServerName: "failed"],
            initializeResponse: nil
        )
        let shutdownGate = LifecycleAsyncGate()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            label: "runtime-init-failure",
            shutdownGate: shutdownGate,
            runtimeInitStatusOnSend: runtimeInitFailure
        )
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        harness.host.test_installLiveSession(session)

        _ = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "fail runtime init",
            initialMessageForRun: "fail runtime init",
            attachments: []
        )
        let agentTask = try XCTUnwrap(session.agentTask)
        await agentTask.value

        XCTAssertEqual(session.runState, .failed)
        XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, .failed)
        XCTAssertEqual(
            session.items.last(where: { $0.kind == .error })?.text,
            "RepoPrompt MCP failed to initialize for Claude (session runtime-init-failure)."
        )
        XCTAssertNil(session.claudeController)
        await shutdownGate.waitUntilArrived()
        await shutdownGate.release()
        await harness.host.claudeCoordinator.awaitPendingClaudeResumeTransferIfNeeded(for: session)
        XCTAssertTrue(recorder.contains("runtime-init-failure:shutdown"))
        XCTAssertEqual(recorder.events.count(where: { $0.hasPrefix("commit:") }), 1)
    }

    func testClaudeSendFailureReportsEvidenceWithoutTerminalizingSession() async {
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            label: "no-vm",
            failSend: true
        )
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.providerSessionID = "lifecycle-claude-session"
        let runID = UUID()
        session.installRunID(runID)
        session.runState = .running
        session.setRunningStatus("Thinking…", source: .transport)
        let ownership = session.beginRunAttempt(source: "test.coordinatorFailure")
        var projectedSessions: [AgentModeViewModel.TabSession] = []
        var projectedStates: [AgentSessionRunState] = []
        let capabilities = ClaudeAgentModeCoordinator.HostCapabilities(
            isSessionCurrent: { $0 === session },
            requestUIRefresh: { projectedSession, urgent in
                projectedSessions.append(projectedSession)
                projectedStates.append(projectedSession.runState)
                recorder.record("host:refresh:\(urgent)")
            },
            scheduleSave: { projectedSession in
                projectedSessions.append(projectedSession)
                projectedStates.append(projectedSession.runState)
                recorder.record("host:save")
            },
            stageClaudeResumeRecoveryHandoff: { _ in },
            prependPendingHandoff: { outboundText, projectedSession in
                projectedSessions.append(projectedSession)
                projectedStates.append(projectedSession.runState)
                recorder.record("host:prepend")
                return outboundText
            }
        )
        let providerBindingService = AgentModeProviderBindingService()
        let coordinator = ClaudeAgentModeCoordinator(
            windowID: 1,
            workspacePathProvider: { _ in "/workspace" },
            claudeControllerFactory: { _, _, _, _ in controller }
        )
        coordinator.installHostCapabilities(
            capabilities,
            providerBindingService: providerBindingService
        )

        let sendOutcome = await coordinator.sendClaudeNativeMessage(
            session: session,
            text: "fail deterministically",
            attachments: [],
            intent: .runAttempt(ownership: ownership, runID: runID)
        )
        withExtendedLifetime(providerBindingService) {}

        guard case let .failed(message) = sendOutcome else {
            return XCTFail("Expected explicit Claude send failure")
        }
        XCTAssertEqual(message, "Claude native send failed: Expected Claude send failure.")
        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunOwnership, ownership)
        XCTAssertEqual(session.runningStatusText, "Thinking…")
        XCTAssertEqual(session.runningStatusSource, .transport)
        XCTAssertNil(session.lastTerminalCommitRevision)
        XCTAssertEqual(session.items.count(where: { $0.kind == .error }), 1)
        XCTAssertTrue(projectedSessions.allSatisfy { $0 === session })
        XCTAssertEqual(projectedStates, [.running, .running, .running])
        XCTAssertEqual(
            recorder.events,
            [
                "no-vm:start",
                "host:prepend",
                "no-vm:send",
                "host:refresh:true",
                "host:save"
            ]
        )
    }

    func testOwnershiplessClaudeReconnectFailureNormalizesIdleWithEvidenceAndRetainsProviderIdentity() async {
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            label: "reconnect-fail",
            startOrResumeFailure: NativeAgentRuntimeControllerError.processNotRunning
        )
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let session = await harness.host.ensureSessionReady(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.providerSessionID = "retained-provider-session"
        let runID = UUID()
        session.installRunID(runID)
        session.runState = .running
        harness.host.setAgentRunActive(session, isActive: true)
        let saveGenerationBefore = session.saveRequestGeneration

        _ = await harness.host.ensureSessionReady(
            tabID: session.tabID,
            reconnectActiveProviders: true
        )

        XCTAssertEqual(session.runState, .idle)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertEqual(session.runID, runID)
        XCTAssertEqual(session.providerSessionID, "retained-provider-session")
        XCTAssertNil(session.activeAgentRunStartedAt)
        XCTAssertNil(session.lastTerminalCommitRevision)
        XCTAssertEqual(session.items.count(where: { $0.kind == .error }), 1)
        XCTAssertTrue(session.items.last?.text.contains("Claude native start failed") == true)
        XCTAssertTrue(session.isDirty)
        XCTAssertGreaterThan(session.saveRequestGeneration, saveGenerationBefore)
        XCTAssertTrue(recorder.contains("reconnect-fail:start-failed"))
    }

    func testClaudeReconnectRacingLiveOwnershipWritesNothingAndPreservesOwnerCurrency() async {
        let recorder = LifecycleRecorder()
        let startGate = LifecycleAsyncGate()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            label: "reconnect-owner-race",
            startOrResumeGate: startGate,
            startOrResumeFailure: NativeAgentRuntimeControllerError.processNotRunning
        )
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let session = await harness.host.ensureSessionReady(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.providerSessionID = "owner-race-provider-session"
        let runID = UUID()
        session.installRunID(runID)
        session.runState = .running
        let saveGenerationBefore = session.saveRequestGeneration
        let sourceRevisionBefore = session.sourceItemsRevision

        let reconnectTask = Task { @MainActor in
            await harness.host.ensureSessionReady(
                tabID: session.tabID,
                reconnectActiveProviders: true
            )
        }
        await startGate.waitUntilArrived()
        let ownership = session.beginRunAttempt(source: "test.reconnectOwnerRace")
        await startGate.release()
        _ = await reconnectTask.value

        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunOwnership, ownership)
        XCTAssertEqual(session.runID, runID)
        XCTAssertEqual(session.providerSessionID, "owner-race-provider-session")
        XCTAssertEqual(session.sourceItemsRevision, sourceRevisionBefore)
        XCTAssertEqual(session.saveRequestGeneration, saveGenerationBefore)
        XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
        XCTAssertTrue(
            session.isCurrentRunAttemptForCurrentBinding(
                ownership,
                expectedRunID: runID
            )
        )
        XCTAssertNil(session.lastTerminalCommitRevision)
    }

    func testConcurrentOwnershiplessClaudeReconnectFailuresAppendOneError() async {
        let recorder = LifecycleRecorder()
        let startGate = LifecycleAsyncGate()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            label: "reconnect-concurrent",
            startOrResumeGate: startGate,
            startOrResumeFailure: NativeAgentRuntimeControllerError.processNotRunning,
            repeatsStartOrResumeFailure: true
        )
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let session = await harness.host.ensureSessionReady(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.providerSessionID = "concurrent-provider-session"
        let runID = UUID()
        session.installRunID(runID)
        session.runState = .running

        let first = Task { @MainActor in
            await harness.host.ensureSessionReady(
                tabID: session.tabID,
                reconnectActiveProviders: true
            )
        }
        await startGate.waitUntilArrived()
        let second = Task { @MainActor in
            await harness.host.ensureSessionReady(
                tabID: session.tabID,
                reconnectActiveProviders: true
            )
        }
        await startGate.waitUntilArrivals(2)
        await startGate.release()
        _ = await first.value
        _ = await second.value

        XCTAssertEqual(session.runState, .idle)
        XCTAssertEqual(session.runID, runID)
        XCTAssertEqual(session.providerSessionID, "concurrent-provider-session")
        XCTAssertEqual(session.items.count(where: { $0.kind == .error }), 1)
        XCTAssertEqual(
            recorder.events.count(where: { $0 == "reconnect-concurrent:start-failed" }),
            2
        )
        XCTAssertNil(session.lastTerminalCommitRevision)
    }

    func testClaudeReconnectFailureWritesNothingAfterTabRecycleOrBindingChange() async {
        do {
            let recorder = LifecycleRecorder()
            let startGate = LifecycleAsyncGate()
            let controller = LifecycleFakeNativeController(
                recorder: recorder,
                label: "reconnect-recycled",
                startOrResumeGate: startGate,
                startOrResumeFailure: NativeAgentRuntimeControllerError.processNotRunning
            )
            let harness = makeHarness(recorder: recorder, claudeController: controller)
            let session = await harness.host.ensureSessionReady(tabID: UUID())
            session.selectedAgent = .claudeCode
            session.providerSessionID = "recycled-provider-session"
            let runID = UUID()
            session.installRunID(runID)
            session.runState = .running
            let saveGenerationBefore = session.saveRequestGeneration
            let sourceRevisionBefore = session.sourceItemsRevision

            let reconnectTask = Task { @MainActor in
                await harness.host.ensureSessionReady(
                    tabID: session.tabID,
                    reconnectActiveProviders: true
                )
            }
            await startGate.waitUntilArrived()
            let successor = AgentModeViewModel.TabSession(tabID: session.tabID)
            successor.selectedAgent = .claudeCode
            successor.providerSessionID = "successor-provider-session"
            successor.runState = .idle
            harness.host.test_installLiveSession(successor)
            await startGate.release()
            _ = await reconnectTask.value

            XCTAssertEqual(session.runState, .running)
            XCTAssertEqual(session.runID, runID)
            XCTAssertEqual(session.providerSessionID, "recycled-provider-session")
            XCTAssertEqual(session.sourceItemsRevision, sourceRevisionBefore)
            XCTAssertEqual(session.saveRequestGeneration, saveGenerationBefore)
            XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
            XCTAssertEqual(successor.runState, .idle)
            XCTAssertEqual(successor.providerSessionID, "successor-provider-session")
            XCTAssertTrue(successor.items.isEmpty)
        }

        do {
            let recorder = LifecycleRecorder()
            let startGate = LifecycleAsyncGate()
            let controller = LifecycleFakeNativeController(
                recorder: recorder,
                label: "reconnect-rebound",
                startOrResumeGate: startGate,
                startOrResumeFailure: NativeAgentRuntimeControllerError.processNotRunning
            )
            let harness = makeHarness(recorder: recorder, claudeController: controller)
            let session = await harness.host.ensureSessionReady(tabID: UUID())
            session.selectedAgent = .claudeCode
            session.providerSessionID = "rebound-provider-session"
            let runID = UUID()
            session.installRunID(runID)
            session.runState = .running
            _ = harness.host.test_installPersistentSessionBinding(sessionID: UUID(), on: session)

            let reconnectTask = Task { @MainActor in
                await harness.host.ensureSessionReady(
                    tabID: session.tabID,
                    reconnectActiveProviders: true
                )
            }
            await startGate.waitUntilArrived()
            _ = harness.host.test_installPersistentSessionBinding(sessionID: UUID(), on: session)
            let reboundBinding = session.persistentSessionBindingIdentity
            let saveGenerationAfterRebind = session.saveRequestGeneration
            let sourceRevisionAfterRebind = session.sourceItemsRevision
            await startGate.release()
            _ = await reconnectTask.value

            XCTAssertEqual(session.runState, .running)
            XCTAssertEqual(session.runID, runID)
            XCTAssertEqual(session.providerSessionID, "rebound-provider-session")
            XCTAssertEqual(session.persistentSessionBindingIdentity, reboundBinding)
            XCTAssertEqual(session.sourceItemsRevision, sourceRevisionAfterRebind)
            XCTAssertEqual(session.saveRequestGeneration, saveGenerationAfterRebind)
            XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
        }
    }

    func testInvalidatedClaudeResumeTransferCannotRestoreClearedSessionID() async {
        let recorder = LifecycleRecorder()
        let sessionRefGate = LifecycleAsyncGate()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            currentSessionRefGate: sessionRefGate
        )
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let session = makeRunningClaudeSession(controller: controller, host: harness.host)
        session.providerSessionID = "session-to-clear"

        let detached = harness.host.claudeCoordinator.prepareClaudeCancelSync(session)
        harness.host.claudeCoordinator.beginClaudeResumeTransferIfNeeded(
            for: session,
            oldController: detached
        )
        await sessionRefGate.waitUntilArrived()
        harness.host.claudeCoordinator.invalidatePendingClaudeResumeTransfer(for: session)
        session.providerSessionID = nil
        await sessionRefGate.release()
        await harness.host.claudeCoordinator.awaitPendingClaudeResumeTransferIfNeeded(for: session)

        XCTAssertNil(session.providerSessionID)
        XCTAssertFalse(
            harness.host.claudeCoordinator.test_hasPendingOrRetiredResumeTransfers(for: session)
        )
        XCTAssertTrue(recorder.contains("claude:shutdown"))
    }

    // MARK: - Shutdown run-identity scoping

    func testWorkspaceSwitchFinalizeDetachCapturesControllerAndRetiresHandleOnly() async {
        let recorder = LifecycleRecorder()
        let harness = makeHarness(recorder: recorder)
        let controller = LifecycleFakeNativeController(recorder: recorder, label: "warm")
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.claudeController = controller
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: "default",
            allowNativeBashTool: nil,
            mcpStrictMode: nil
        )
        session.installRunID(UUID())
        session.pendingSupersedingTurnCompletions = 2

        let detached = harness.host.claudeCoordinator.detachForWorkspaceSwitchFinalizeSync(session)
        XCTAssertNotNil(detached)
        XCTAssertNil(session.claudeController)
        XCTAssertNil(harness.host.claudeCoordinator.test_controllerLaunchSettings(for: session))
        XCTAssertEqual(session.pendingSupersedingTurnCompletions, 0)
        XCTAssertFalse(
            recorder.contains("warm:shutdown"),
            "finalize detach is synchronous; the process shuts down at retire time"
        )

        // Same-tab successor metadata installed after finalize must survive the
        // background retire untouched: the retire path is handle-only.
        let successorSettings = ClaudeAgentModeCoordinator.ControllerLaunchSettings(
            runtimeVariant: .standard,
            workspacePath: "/successor",
            permissionMode: "successor",
            allowNativeBashTool: true,
            mcpStrictMode: true
        )
        harness.host.claudeCoordinator.test_setControllerLaunchSettings(successorSettings, for: session)

        guard let detached else { return }
        await harness.host.claudeCoordinator.retireDetachedControllerForWorkspaceSwitch(
            detached,
            discardedSession: session
        )
        XCTAssertTrue(recorder.contains("warm:shutdown"))
        XCTAssertEqual(
            harness.host.claudeCoordinator.test_controllerLaunchSettings(for: session),
            successorSettings,
            "handle retire must not touch tab-keyed coordinator registries"
        )
    }

    func testClaudeFreshStartRetryAbortsWhenSupersededDuringControllerShutdown() async {
        // Coordinator-level supersession coverage for the resume→fresh-start
        // retry path: a successor that installs its own run identity while the
        // failed controller is shutting down must abort the retry before it
        // clears provider identity or launches a fresh controller.
        let recorder = LifecycleRecorder()
        let shutdownGate = LifecycleAsyncGate()
        let failingController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "resume-fail",
            shutdownGate: shutdownGate,
            startOrResumeFailure: NativeAgentRuntimeControllerError.processNotRunning
        )
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in
                recorder.record("factory:claude:invocation")
                return failingController
            }
        )
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.providerSessionID = "existing-session"
        let originalRunID = UUID()
        session.installRunID(originalRunID)
        session.runState = .running
        harness.host.test_installLiveSession(session)
        let initialRunState = session.runState

        let ownership = session.beginRunAttempt(source: "test.resumeFallback")
        let ensureTask = Task { @MainActor in
            await harness.host.claudeCoordinator.ensureClaudeNativeSession(
                session: session,
                intent: .runAttempt(ownership: ownership, runID: originalRunID)
            )
        }
        await shutdownGate.waitUntilArrived()
        let successorRunID = UUID()
        session.installRunID(successorRunID)
        await shutdownGate.release()
        let ensureOutcome = await ensureTask.value

        XCTAssertEqual(ensureOutcome, .superseded)
        XCTAssertTrue(recorder.contains("resume-fail:start-failed"))
        XCTAssertEqual(
            session.runID,
            successorRunID,
            "the superseded retry must not clear or replace the successor's run identity"
        )
        XCTAssertEqual(
            session.providerSessionID,
            "existing-session",
            "the superseded retry must not reset provider identity"
        )
        XCTAssertEqual(
            recorder.events.count(where: { $0 == "factory:claude:invocation" }),
            1,
            "no fresh controller may launch after supersession"
        )
        XCTAssertTrue(session.items.isEmpty, "a superseded retry is silent; no failure item")
        XCTAssertEqual(session.runState, initialRunState)
    }

    func testShutdownClaudeSessionForceClearsRunIdentityOnTabTerminalPath() async {
        // Tab/context-terminal shutdown is a force reset by contract: any run
        // present — including one installed after shutdown began — must not
        // survive the transition. This pins the clobber as intent, not accident.
        let recorder = LifecycleRecorder()
        let harness = makeHarness(recorder: recorder)
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.installRunID(UUID())

        await harness.host.claudeCoordinator.shutdownClaudeSession(session)
        XCTAssertNil(session.runID)
    }

    private func resolvedClaudeLaunchPolicy(
        profile: AgentProviderPermissionProfile,
        harness: LifecycleHarness
    ) -> ClaudeControllerLaunchPolicy? {
        let providerBindingService = harness.host.providerBindingService
        let permissionMode = providerBindingService.runtimePermission(
            for: .claudeCode,
            profile: profile
        ).claudePermissionMode
        let preferences = providerBindingService.preferences
        return ClaudeControllerLaunchPolicy.resolve(
            permissionMode: permissionMode,
            profile: profile,
            defaults: preferences.defaults,
            securePermissions: preferences.securePermissions
        )
    }

    private func setClaudeControllerLaunchSettings(
        for session: AgentModeViewModel.TabSession,
        coordinator: ClaudeAgentModeCoordinator,
        workspacePath: String? = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        ).standardizedFileURL.path,
        permissionMode: String?,
        allowNativeBashTool: Bool?,
        mcpStrictMode: Bool?
    ) {
        coordinator.test_setControllerLaunchSettings(
            .init(
                runtimeVariant: .standard,
                workspacePath: workspacePath,
                permissionMode: permissionMode,
                allowNativeBashTool: allowNativeBashTool,
                mcpStrictMode: mcpStrictMode
            ),
            for: session
        )
    }
}

actor LifecycleAsyncGate {
    private var arrivalCount = 0
    private var released = false
    private var arrivalWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrivalCount += 1
        let readyWaiters = arrivalWaiters.filter { $0.count <= arrivalCount }
        arrivalWaiters.removeAll { $0.count <= arrivalCount }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilArrived() async {
        await waitUntilArrivals(1)
    }

    func waitUntilArrivals(_ count: Int) async {
        guard arrivalCount < count else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append((count: count, continuation: continuation))
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let releaseWaiters = releaseWaiters
        self.releaseWaiters.removeAll()
        for waiter in releaseWaiters {
            waiter.resume()
        }
    }
}

actor LifecycleFakeNativeController: NativeAgentRuntimeControlling {
    private let recorder: LifecycleRecorder
    private let label: String
    private let turnInFlight: Bool
    private let failSend: Bool
    private let currentSessionRefGate: LifecycleAsyncGate?
    private let eventsStreamReadyGate: LifecycleAsyncGate?
    private let startOrResumeGate: LifecycleAsyncGate?
    private let sendUserMessageGate: LifecycleAsyncGate?
    private let shutdownGate: LifecycleAsyncGate?
    private let repeatsStartOrResumeFailure: Bool
    private var pendingStartOrResumeFailure: Error?
    private let turnStatusOnSend: NativeAgentRuntimeTurnStatus?
    private let runtimeInitStatusOnSend: NativeAgentRuntimeRuntimeInitStatus?
    private let finishEventsAfterSend: Bool
    private let sessionRef = NativeAgentRuntimeSessionRef(sessionID: "lifecycle-claude-session")
    private let stream: AsyncStream<NativeAgentRuntimeEvent>
    private let eventsContinuation: AsyncStream<NativeAgentRuntimeEvent>.Continuation

    init(
        recorder: LifecycleRecorder,
        label: String = "claude",
        hasTurnInFlight: Bool = false,
        failSend: Bool = false,
        currentSessionRefGate: LifecycleAsyncGate? = nil,
        eventsStreamReadyGate: LifecycleAsyncGate? = nil,
        startOrResumeGate: LifecycleAsyncGate? = nil,
        sendUserMessageGate: LifecycleAsyncGate? = nil,
        shutdownGate: LifecycleAsyncGate? = nil,
        startOrResumeFailure: Error? = nil,
        repeatsStartOrResumeFailure: Bool = false,
        turnStatusOnSend: NativeAgentRuntimeTurnStatus? = nil,
        runtimeInitStatusOnSend: NativeAgentRuntimeRuntimeInitStatus? = nil,
        finishEventsAfterSend: Bool = false
    ) {
        self.recorder = recorder
        self.label = label
        turnInFlight = hasTurnInFlight
        self.failSend = failSend
        self.currentSessionRefGate = currentSessionRefGate
        self.eventsStreamReadyGate = eventsStreamReadyGate
        self.startOrResumeGate = startOrResumeGate
        self.sendUserMessageGate = sendUserMessageGate
        self.shutdownGate = shutdownGate
        self.repeatsStartOrResumeFailure = repeatsStartOrResumeFailure
        pendingStartOrResumeFailure = startOrResumeFailure
        self.turnStatusOnSend = turnStatusOnSend
        self.runtimeInitStatusOnSend = runtimeInitStatusOnSend
        self.finishEventsAfterSend = finishEventsAfterSend
        let eventPipe = AsyncStream<NativeAgentRuntimeEvent>.makeStream()
        stream = eventPipe.stream
        eventsContinuation = eventPipe.continuation
    }

    var hasActiveSession: Bool {
        true
    }

    var hasTurnInFlight: Bool {
        turnInFlight
    }

    var events: AsyncStream<NativeAgentRuntimeEvent> {
        stream
    }

    func ensureEventsStreamReady() async {
        if let eventsStreamReadyGate {
            recorder.record("\(label):events-ready")
            await eventsStreamReadyGate.arriveAndWait()
        }
    }

    func resetEventsStreamForNewRun() async {}

    func startOrResume(
        existingSessionID: String?,
        model: String?,
        effortLevel: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride: String?
    ) async throws -> NativeAgentRuntimeSessionRef {
        if let startOrResumeGate {
            recorder.record("\(label):start-arrived")
            await startOrResumeGate.arriveAndWait()
        }
        if let failure = pendingStartOrResumeFailure {
            if !repeatsStartOrResumeFailure {
                pendingStartOrResumeFailure = nil
            }
            recorder.record("\(label):start-failed")
            throw failure
        }
        recorder.record("\(label):start")
        return sessionRef
    }

    func currentSessionRef() async -> NativeAgentRuntimeSessionRef {
        if let currentSessionRefGate {
            recorder.record("\(label):current-ref")
            await currentSessionRefGate.arriveAndWait()
        }
        return sessionRef
    }

    func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws {}

    func sendUserMessage(_ text: String) async throws -> UUID {
        recorder.record("\(label):send")
        if let sendUserMessageGate {
            await sendUserMessageGate.arriveAndWait()
        }
        if failSend {
            throw LifecycleTestError.expectedClaudeSendFailure
        }
        let turnID = UUID()
        if let runtimeInitStatusOnSend {
            eventsContinuation.yield(.runtimeInit(runtimeInitStatusOnSend))
        }
        if let turnStatusOnSend {
            eventsContinuation.yield(.turnCompleted(turnID: turnID, status: turnStatusOnSend))
        }
        if finishEventsAfterSend {
            eventsContinuation.finish()
        }
        return turnID
    }

    func interruptTurn(reason: String) async -> NativeAgentRuntimeInterruptOutcome {
        recorder.record("\(label):interrupt:\(reason)")
        return .noTurnInFlight
    }

    func shutdown() async {
        if let shutdownGate {
            recorder.record("\(label):shutdown-arrived")
            await shutdownGate.arriveAndWait()
        }
        recorder.record("\(label):shutdown")
    }

    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async {}
}
