import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

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
        let session = makeRunningClaudeSession(controller: oldController)
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
        let session = makeRunningClaudeSession(controller: oldController)
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
        let session = makeRunningClaudeSession(controller: oldController)
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
        let session = makeRunningClaudeSession(controller: oldController)
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

    func testClaudeWorkspaceRecycleDoesNotClearReplacementAfterCurrentSessionAwait() async {
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
        let session = makeRunningClaudeSession(controller: oldController)
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

        let ensureTask = Task {
            await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)
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
        await ensureTask.value

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

    func testClaudeSendCompletionDoesNotFailReplacementController() async {
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
        let session = makeRunningClaudeSession(controller: oldController)
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

        let sendTask = Task {
            await harness.host.claudeCoordinator.sendClaudeNativeMessage(
                session: session,
                text: "do not fail replacement",
                attachments: []
            )
        }
        await sendGate.waitUntilArrived()
        session.claudeController = replacementController
        await sendGate.release()

        let didSend = await sendTask.value
        XCTAssertFalse(didSend)
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

    func testInvalidatedClaudeResumeTransferCannotRestoreClearedSessionID() async {
        let recorder = LifecycleRecorder()
        let sessionRefGate = LifecycleAsyncGate()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            currentSessionRefGate: sessionRefGate
        )
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let session = makeRunningClaudeSession(controller: controller)
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
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrived = true
        let arrivalWaiters = arrivalWaiters
        self.arrivalWaiters.removeAll()
        for waiter in arrivalWaiters {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilArrived() async {
        guard !arrived else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
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
    private let sendUserMessageGate: LifecycleAsyncGate?
    private let sessionRef = NativeAgentRuntimeSessionRef(sessionID: "lifecycle-claude-session")
    private let stream: AsyncStream<NativeAgentRuntimeEvent>

    init(
        recorder: LifecycleRecorder,
        label: String = "claude",
        hasTurnInFlight: Bool = false,
        failSend: Bool = false,
        currentSessionRefGate: LifecycleAsyncGate? = nil,
        eventsStreamReadyGate: LifecycleAsyncGate? = nil,
        sendUserMessageGate: LifecycleAsyncGate? = nil
    ) {
        self.recorder = recorder
        self.label = label
        turnInFlight = hasTurnInFlight
        self.failSend = failSend
        self.currentSessionRefGate = currentSessionRefGate
        self.eventsStreamReadyGate = eventsStreamReadyGate
        self.sendUserMessageGate = sendUserMessageGate
        stream = AsyncStream { _ in }
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
        return UUID()
    }

    func interruptTurn(reason: String) async -> NativeAgentRuntimeInterruptOutcome {
        recorder.record("\(label):interrupt:\(reason)")
        return .noTurnInFlight
    }

    func shutdown() async {
        recorder.record("\(label):shutdown")
    }

    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async {}
}
