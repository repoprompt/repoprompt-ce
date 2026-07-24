import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

/// Fail-closed pre-first-turn routing boundary for Codex children (issue #514).
///
/// When a Codex child's app-server thread starts but RepoPrompt MCP routing never confirms, the run
/// must fail closed before its first turn: no `startUserTurn`, a failed run the parent's send outcome
/// and terminal publication both report, and no leaked bootstrap gate, routing waiter, or pending
/// connection policy. A reconnecting child whose routing does confirm must instead proceed, and a run
/// cancelled while the routing wait is suspended must unwind without dispatching a turn.
///
/// The harness drives the real `MCPBootstrapLease` routing wait, `HeadlessAgentConnectionGate`, and
/// `ServerNetworkManager` connection-policy machinery through a fake Codex app-server controller that
/// answers `startOrResume` (so a thread is active) but whose child never connects MCP. Because that
/// machinery is process-global, each test runs under `MCPSharedServerTestLease` (the shared-MCP-state
/// serialization lease other bootstrap suites use) on a distinctive window ID, and cleanup is scoped to
/// the run IDs this suite creates — it never cancels the gate globally or clears shared routing history.
@MainActor
final class CodexMCPRoutingReadinessTests: XCTestCase {
    /// A distinctive window so this suite's connection policies never key-collide with the shared
    /// default window (1) other suites use.
    private let testWindowID = 5_140_514
    private let routingTimeoutMs = 500
    private let codexClientName = AgentProviderKind.codexExec.mcpClientNameHint ?? "RepoPromptCE"
    private var trackedRunIDs: [UUID] = []

    override func tearDown() async throws {
        // Scope cleanup to the run IDs this suite created: revoke each retained one-shot policy (a routed
        // run legitimately keeps its policy for the real connection) and drop its routing waiter. No
        // gate cancel-all or global routing-history clear, which would disrupt other suites.
        for runID in trackedRunIDs {
            await ServerNetworkManager.shared.revokeClientConnectionPolicy(
                for: codexClientName,
                windowID: testWindowID,
                runID: runID
            )
            await MCPRoutingWaiter.cleanup(runID: runID)
        }
        trackedRunIDs.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fail closed

    func testUnroutedChildFailsClosedBeforeFirstTurnWithoutLeakingBootstrapState() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let controller = RoutingReadinessFakeCodexController()
            let recorder = TerminalPublicationRecorder()
            let coordinator = makeCoordinator(controller: controller, recorder: recorder)

            // Leave runState inactive so the send is treated as a fresh first turn (the send captures
            // wasRunAlreadyActive before it flips the run to running).
            let session = makeCodexSession()
            session.beginRunAttempt(source: "test.routing-readiness.fail")

            let outcome = await coordinator.sendCodexNativeMessage(
                session: session,
                text: "first turn",
                attachments: []
            )
            if let runID = session.runID {
                trackedRunIDs.append(runID)
            }

            XCTAssertEqual(controller.startUserTurnCount, 0, "startUserTurn must never fire when routing never confirmed")

            XCTAssertEqual(outcome, .failed(message: "Codex native send failed: session not ready"))
            // Exactly-once is the contract the native-start-failure prefix protects: the send path must
            // recognize the already-recorded failure instead of publishing or appending a second one.
            XCTAssertEqual(recorder.publishedStates, [.failed], "the failed run must publish exactly one failed terminal state")
            XCTAssertEqual(session.runState, .failed)

            let readinessErrors = session.items.filter {
                $0.kind == .error
                    && $0.text.hasPrefix("Codex native start failed:")
                    && $0.text.contains("RepoPrompt MCP routing was not confirmed")
            }
            XCTAssertEqual(
                readinessErrors.count,
                1,
                "exactly one readiness error must be recorded, got \(session.items.filter { $0.kind == .error }.map(\.text))"
            )

            XCTAssertNil(session.codexController, "the unrouted controller must be released from the session")
            let usedRunID = try XCTUnwrap(session.runID)
            let activeGate = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertNil(activeGate, "the bootstrap gate must not remain owned")
            let gateQueueDepth = await HeadlessAgentConnectionGate.shared.debugWaitingCount()
            XCTAssertEqual(gateQueueDepth, 0, "no bootstrap gate waiters may remain")
            let pendingWaiters = await MCPRoutingWaiter.debugContinuationCount(runID: usedRunID)
            XCTAssertEqual(pendingWaiters, 0, "no routing waiters may remain for the run")
            let pendingPolicies = await ServerNetworkManager.shared.debugPendingPolicySnapshot(for: codexClientName)
            XCTAssertTrue(
                pendingPolicies.allSatisfy { $0.runID != usedRunID },
                "the one-shot connection policy must be cleared when routing fails closed"
            )
        }
    }

    func testUnroutedResumeFailsClosedWithResumeFailurePrefix() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let controller = RoutingReadinessFakeCodexController()
            let recorder = TerminalPublicationRecorder()
            let coordinator = makeCoordinator(controller: controller, recorder: recorder)

            let session = makeCodexSession()
            session.setItemsSilently(
                [
                    .user("earlier", sequenceIndex: 0),
                    .assistant("earlier reply", sequenceIndex: 1)
                ],
                reason: .persistedSessionHydration
            )
            session.codexConversationID = "resume-thread"
            session.codexNeedsReconnect = true
            session.beginRunAttempt(source: "test.routing-readiness.resume-fail")

            let outcome = await coordinator.sendCodexNativeMessage(
                session: session,
                text: "next turn",
                attachments: []
            )
            if let runID = session.runID {
                trackedRunIDs.append(runID)
            }

            XCTAssertEqual(controller.startUserTurnCount, 0, "startUserTurn must never fire when resumed routing never confirmed")
            XCTAssertEqual(outcome, .failed(message: "Codex native send failed: session not ready"))
            XCTAssertEqual(recorder.publishedStates, [.failed], "the failed resumed run must publish exactly one failed terminal state")

            let resumeReadinessErrors = session.items.filter {
                $0.kind == .error
                    && $0.text.hasPrefix("Codex native resume failed:")
                    && $0.text.contains("RepoPrompt MCP routing was not confirmed")
            }
            XCTAssertEqual(
                resumeReadinessErrors.count,
                1,
                "unrouted resumes must report a resume failure prefix, got \(session.items.filter { $0.kind == .error }.map(\.text))"
            )
            XCTAssertFalse(
                session.items.contains { $0.kind == .error && $0.text.hasPrefix("Codex native start failed:") },
                "unrouted resumes must not be mislabeled as fresh native starts"
            )
        }
    }

    func testResumeFallbackToFreshRoutingFailureUsesStartPrefixAndDeduplicates() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let controller = RoutingReadinessFakeCodexController(failFirstResumeForMissingRollout: true)
            let recorder = TerminalPublicationRecorder()
            let coordinator = makeCoordinator(controller: controller, recorder: recorder)

            let session = makeCodexSession()
            session.setItemsSilently(
                [
                    .user("earlier", sequenceIndex: 0),
                    .assistant("earlier reply", sequenceIndex: 1)
                ],
                reason: .persistedSessionHydration
            )
            session.codexConversationID = "missing-rollout-thread"
            session.codexRolloutPath = "/missing/rollout.jsonl"
            session.codexNeedsReconnect = true
            session.beginRunAttempt(source: "test.routing-readiness.resume-fallback-fail")

            let outcome = await coordinator.sendCodexNativeMessage(
                session: session,
                text: "next turn",
                attachments: []
            )
            if let runID = session.runID {
                trackedRunIDs.append(runID)
            }

            XCTAssertEqual(controller.startAttemptWasResume, [true, false])
            XCTAssertEqual(controller.startUserTurnCount, 0)
            XCTAssertEqual(outcome, .failed(message: "Codex native send failed: session not ready"))
            XCTAssertEqual(recorder.publishedStates, [.failed])

            let startReadinessErrors = session.items.filter {
                $0.kind == .error
                    && $0.text.hasPrefix("Codex native start failed:")
                    && $0.text.contains("RepoPrompt MCP routing was not confirmed")
            }
            XCTAssertEqual(startReadinessErrors.count, 1)
            XCTAssertFalse(
                session.items.contains { $0.kind == .error && $0.text.hasPrefix("Codex native resume failed:") },
                "a successful fresh fallback must not be labeled as a resume failure"
            )
            XCTAssertEqual(
                session.items.count(where: {
                    $0.kind == .system
                        && $0.text == "Codex couldn't resume the previous thread because its rollout file was missing. Started a fresh thread."
                }),
                1,
                "the fallback must disclose that native model context was not resumed"
            )
            #if DEBUG
                XCTAssertTrue(
                    CodexAgentModeCoordinator.debugIsCodexNativeSessionFailureText(
                        "Codex native start failed: RepoPrompt MCP routing was not confirmed",
                        disposition: .resumed
                    ),
                    "a stale resumed disposition must still deduplicate a later fresh-start failure"
                )
            #endif
        }
    }

    func testMissingRolloutFallbackClassifierMatchesOnlyKnownMissingForms() {
        let existing = CodexNativeSessionController.SessionRef(
            conversationID: "019f775c-4070-7200-b41c-933196989588",
            rolloutPath: "/missing/rollout.jsonl",
            model: nil,
            reasoningEffort: nil
        )

        for message in [
            "no rollout found for thread id 019f775c-4070-7200-b41c-933196989588",
            "  NO ROLLOUT FOUND FOR THREAD ID 019f775c-4070-7200-b41c-933196989588\n",
            "failed to load rollout: no such file"
        ] {
            XCTAssertTrue(
                CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
                    existingRef: existing,
                    errorDescription: message
                ),
                message
            )
        }

        for message in [
            "no rollout found for thread id",
            "no rollout found for thread id thread extra",
            "rollout not found for thread id thread",
            "failed to load rollout: permission denied",
            "rollout is corrupt"
        ] {
            XCTAssertFalse(
                CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
                    existingRef: existing,
                    errorDescription: message
                ),
                message
            )
        }
    }

    // MARK: - Cancellation cannot cross the first-turn boundary

    func testCancellationDuringRoutingWaitDoesNotReachFirstTurn() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let controller = RoutingReadinessFakeCodexController()
            let recorder = TerminalPublicationRecorder()
            let runIDBox = RunIDBox()
            // A long routing timeout so the wait is genuinely suspended when the test cancels — the
            // cancellation, not the timeout, must drive the outcome.
            let coordinator = makeCoordinator(
                controller: controller,
                recorder: recorder,
                routingTimeoutMs: 60000,
                capturedRunID: runIDBox
            )

            let session = makeCodexSession()
            session.beginRunAttempt(source: "test.routing-readiness.cancel")

            let sendTask = Task { @MainActor in
                await coordinator.sendCodexNativeMessage(session: session, text: "first turn", attachments: [])
            }

            // Wait until requireRouting is genuinely suspended on the routing waiter (a registered
            // continuation), then cancel. This is condition-driven, not a fixed sleep.
            var suspended = false
            for _ in 0 ..< 20000 {
                if let runID = runIDBox.value, await MCPRoutingWaiter.debugContinuationCount(runID: runID) >= 1 {
                    suspended = true
                    break
                }
                await Task.yield()
            }
            XCTAssertTrue(suspended, "requireRouting never suspended on the routing waiter")

            sendTask.cancel()
            let outcome = await sendTask.value
            if let runID = runIDBox.value {
                trackedRunIDs.append(runID)
            }

            XCTAssertEqual(controller.startUserTurnCount, 0, "a cancelled routing wait must not reach startUserTurn")
            XCTAssertEqual(outcome, .cancelled, "a cancelled startup must return a cancelled outcome, got \(outcome)")
            XCTAssertTrue(
                recorder.publishedStates.isEmpty,
                "cancellation must not publish a fail-closed terminal state, got \(recorder.publishedStates)"
            )
        }
    }

    // MARK: - Routed resume proceeds

    func testRestoredResumeRequiresRealMatchingMCPAdmissionBeforeFirstTurn() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { _ in
                // Real policy admission resolves the tab through the registered window before
                // committing its run route. A restored session alone has no routable UI snapshot.
                let session = makeCodexSession()
                let window = makeRegisteredRoutingWindow()
                try await installRoutingSnapshot(for: session.tabID, in: window)
                let controller = RoutingReadinessFakeCodexController()
                let recorder = TerminalPublicationRecorder()
                let runIDBox = RunIDBox()
                let manager = ServerNetworkManager.shared
                let connectionID = UUID()
                let clientName = codexClientName
                let windowID = window.windowID
                addTeardownBlock { @MainActor in
                    if let runID = runIDBox.value {
                        await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: runID)
                        await manager.clearClientConnectionPolicy(
                            for: clientName,
                            windowID: windowID,
                            runID: runID
                        )
                    }
                    await manager.removeConnection(connectionID)
                    if let runID = runIDBox.value {
                        await manager.cleanupRunRoutingState(for: runID, windowID: windowID)
                        await MCPRoutingWaiter.cleanup(runID: runID)
                    }
                    window.beginClose()
                    await window.tearDown()
                    WindowStatesManager.shared.unregisterWindowState(window)
                }
                let coordinator = makeCoordinator(
                    controller: controller,
                    recorder: recorder,
                    routingTimeoutMs: 60000,
                    capturedRunID: runIDBox,
                    windowID: windowID
                )

                // A restored session has conversation metadata but no persisted process or route.
                session.setItemsSilently(
                    [
                        .user("earlier", sequenceIndex: 0),
                        .assistant("earlier reply", sequenceIndex: 1)
                    ],
                    reason: .persistedSessionHydration
                )
                session.codexConversationID = "resume-thread"
                session.codexNeedsReconnect = true
                session.beginRunAttempt(source: "test.routing-readiness.real-admission")

                let sendTask = Task { @MainActor in
                    await coordinator.sendCodexNativeMessage(
                        session: session,
                        text: "next turn",
                        attachments: []
                    )
                }
                defer { sendTask.cancel() }

                var admittedRunID: UUID?
                for _ in 0 ..< 20000 {
                    if let runID = runIDBox.value,
                       await manager.debugRunPolicyState(for: runID) != nil,
                       await MCPRoutingWaiter.debugContinuationCount(runID: runID) >= 1
                    {
                        admittedRunID = runID
                        break
                    }
                    await Task.yield()
                }
                let runID = try XCTUnwrap(admittedRunID, "Codex never armed its per-run routing policy")
                XCTAssertEqual(controller.startUserTurnCount, 0, "thread/resume alone must not cross the first-turn boundary")

                await manager.registerExpectedAgentPID(getpid(), for: codexClientName, runID: runID)
                let applied = await manager.debugApplyPendingPolicy(
                    clientName: codexClientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: codexClientName,
                    sessionKey: "codex-real-admission-\(runID.uuidString)",
                    pidGateTimeout: 0.25
                )
                XCTAssertEqual(applied.outcome, "applied")
                XCTAssertEqual(applied.runID, runID)
                XCTAssertEqual(applied.windowID, windowID)

                let outcome = await sendTask.value
                XCTAssertTrue(outcome.didSend, "a genuinely admitted resume must dispatch its turn, got \(outcome)")
                XCTAssertEqual(controller.startAttemptWasResume, [true])
                XCTAssertEqual(controller.startUserTurnCount, 1)
                XCTAssertTrue(recorder.publishedStates.isEmpty)
            }
        #else
            throw XCTSkip("Expected-PID policy admission diagnostics are DEBUG-only.")
        #endif
    }

    func testToolPreferenceChangeDuringSuspendedStartPreservesReconnectForNextEnsure() async {
        let startGate = RoutingReadinessAsyncGate()
        var controllers: [RoutingReadinessFakeCodexController] = []
        let host = AgentModeViewModel(
            testWorkspacePath: FileManager.default.temporaryDirectory.path,
            shouldManageCodexTooling: false,
            codexControllerFactory: { _, _, _, _, _, _ in
                let controller = RoutingReadinessFakeCodexController(
                    startGate: controllers.isEmpty ? startGate : nil
                )
                controllers.append(controller)
                return controller
            }
        )
        host.test_initializeRunService()
        let coordinator = host.test_codexCoordinator
        let session = host.session(for: UUID())
        session.selectedAgent = .codexExec

        let firstEnsure = Task { @MainActor in
            await coordinator.ensureCodexNativeSession(session: session)
        }
        await startGate.waitUntilStarted()
        coordinator.handleToolPreferencesChanged(for: session)
        XCTAssertEqual(session.codexToolPreferencesGeneration, 1)
        XCTAssertTrue(session.codexNeedsReconnect)

        await startGate.release()
        await firstEnsure.value
        XCTAssertEqual(controllers.count, 1)
        XCTAssertTrue(
            session.codexNeedsReconnect,
            "a generation change during thread/start must remain pending because turn/start has no config override bag"
        )

        await coordinator.ensureCodexNativeSession(session: session)
        XCTAssertEqual(controllers.count, 2)
        XCTAssertEqual(controllers.first?.shutdownCallCount, 1)
        XCTAssertFalse(session.codexNeedsReconnect)

        await coordinator.shutdownCodexSession(session)
    }

    // MARK: - Harness

    private func makeCodexSession() -> AgentModeViewModel.TabSession {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        return session
    }

    private func makeCoordinator(
        controller: RoutingReadinessFakeCodexController,
        recorder: TerminalPublicationRecorder,
        routingTimeoutMs: Int? = nil,
        capturedRunID: RunIDBox? = nil,
        windowID: Int? = nil
    ) -> CodexAgentModeCoordinator {
        // Install the real per-run policy so the expected-PID policy arms. Routed tests must
        // confirm readiness through real policy admission rather than signalling the waiter directly.
        let policyInstaller: AgentModeViewModel.ConnectionPolicyInstaller = { clientName, windowID, restrictedTools, oneShot, reason, ttl, tabID, runID, additionalTools, purpose, taskLabelKind, allowsAgentExternalControlTools, requiresExpectedAgentPID in
            if let runID {
                capturedRunID?.set(runID)
            }
            await ServerNetworkManager.shared.installClientConnectionPolicy(
                for: clientName,
                windowID: windowID,
                restrictedTools: restrictedTools,
                oneShot: oneShot,
                reason: reason,
                ttl: ttl,
                tabID: tabID,
                runID: runID,
                additionalTools: additionalTools,
                purpose: purpose,
                taskLabelKind: taskLabelKind,
                allowsAgentExternalControlTools: allowsAgentExternalControlTools,
                requiresExpectedAgentPID: requiresExpectedAgentPID
            )
        }

        let host = AgentModeViewModel(
            testWindowID: windowID ?? testWindowID,
            testWorkspacePath: FileManager.default.temporaryDirectory.path,
            shouldManageCodexTooling: true,
            codexControllerFactory: { _, _, _, _, _, _ in controller },
            connectionPolicyInstaller: policyInstaller,
            testCodexLeaseRoutingTimeoutMs: routingTimeoutMs ?? self.routingTimeoutMs
        )
        let coordinator = host.test_codexCoordinator
        coordinator.installTerminalCommitBarrier(AgentRunTerminalCommitBarrier(hooks: makeHooks(recorder: recorder)))
        return coordinator
    }

    private func makeRegisteredRoutingWindow() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        return window
    }

    private func installRoutingSnapshot(
        for tabID: UUID,
        in window: WindowState
    ) async throws {
        let workspace = window.workspaceManager.createWorkspace(
            name: "Codex routing admission \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        let initialSwitchResult = await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "codexRoutingAdmissionInitial"
        )
        XCTAssertEqual(initialSwitchResult, .switched)
        let workspaceIndex = try XCTUnwrap(
            window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id }
        )
        window.workspaceManager.workspaces[workspaceIndex].composeTabs = [
            ComposeTabState(id: tabID, name: "Restored Codex")
        ]
        window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = tabID
        let reloadResult = await window.workspaceManager.reactivateWorkspaceAfterReplacement(
            window.workspaceManager.workspaces[workspaceIndex],
            reason: "codexRoutingAdmissionTab"
        )
        XCTAssertEqual(reloadResult, .switched)
        XCTAssertEqual(
            window.workspaceManager.resolveComposeTabRoutingSnapshot(
                for: tabID,
                captureActiveUIState: false
            )?.snapshot.id,
            tabID
        )
    }

    private func makeHooks(recorder: TerminalPublicationRecorder) -> AgentModeRunService.Hooks {
        AgentModeRunService.Hooks(
            estimateRuntimeTokens: { $0.count },
            addUserInputTokensToActiveNonCodexTurn: { _, _ in },
            startNonCodexTurnAccountingIfNeeded: { _, _ in },
            reserveAttachmentsForTurn: { _, _ in nil },
            markAttachmentsConsumed: { _, _ in },
            stageConsumedAttachmentFilesForDeferredCleanup: { _, _ in },
            consumeDeferredAttachmentCleanup: { _, _ in },
            finalizeAttachmentsForTurn: { _, _, _ in },
            setAgentRunActive: { _, _ in },
            updateBindings: { _ in },
            requestUIRefresh: { _, _ in },
            scheduleSave: { _ in },
            notifyAgentTurnComplete: { _ in },
            handleHeadlessStreamResult: { _, _, _, _ in },
            buildHeadlessAgentMessage: { _, text, _, _ in AgentMessage(userMessage: text) },
            finalizeStreamingItems: { _ in },
            finalizePendingToolCalls: { _, _ in },
            finalizePendingToolCallsWithUpperBound: { _, _, _ in },
            finalizeNonCodexTurnUsage: { _, _, _, _ in },
            cancelPendingQuestion: { _ in },
            cancelPendingApproval: { _ in },
            cancelPendingApplyEditsReview: { _, _ in },
            cancelPendingWorktreeMergeReview: { _, _ in },
            flushPendingAssistantDelta: { _ in },
            clearPendingAssistantDelta: { _ in },
            prepareTerminalPublication: { _ in },
            makeTerminalPublicationEnvelope: { _, _, _, _ in nil },
            publishTerminalCommit: { _, revision, _ in
                recorder.record(revision.terminalState)
                return .accepted(successorEpoch: nil)
            },
            startFollowUpRun: { _, _ in },
            restoreDraftText: { _, _, _, _ in },
            augmentUserMessageForProviderSend: { text, _, _, _ in text },
            stageResumeRecoveryHandoffIfNeeded: { _ in },
            prependPendingHandoffIfNeeded: { text, _ in text },
            recordPendingHandoffSendOutcome: { _, _ in },
            signalMCPInstructionDelivered: { _ in }
        )
    }
}

// MARK: - Test doubles

/// Records terminal-commit publications so a test can assert what the parent's agent_run snapshot sees.
private final class TerminalPublicationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [AgentSessionRunState] = []

    func record(_ state: AgentSessionRunState) {
        lock.lock()
        states.append(state)
        lock.unlock()
    }

    var publishedStates: [AgentSessionRunState] {
        lock.lock()
        defer { lock.unlock() }
        return states
    }
}

/// Captures the run ID the bootstrap lease installs, so a test can observe the routing waiter for it.
private final class RunIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UUID?

    func set(_ value: UUID) {
        lock.lock()
        if stored == nil {
            stored = value
        }
        lock.unlock()
    }

    var value: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private actor RoutingReadinessAsyncGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStartedAndWaitForRelease() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

/// Fake Codex controller whose `startOrResume` binds a thread (so the coordinator treats the thread as
/// active and reaches the routing gate) but whose child never connects MCP. It counts `startUserTurn`
/// calls so a test can prove the first turn never fired when routing fails closed.
private final class RoutingReadinessFakeCodexController: CodexSessionControllerTurnDispatchTestDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private let failFirstResumeForMissingRollout: Bool
    private let startGate: RoutingReadinessAsyncGate?
    private var didFailResume = false
    private var started = false
    private var turnCount = 0
    private var shutdownCount = 0
    private var resumeAttempts: [Bool] = []

    init(
        failFirstResumeForMissingRollout: Bool = false,
        startGate: RoutingReadinessAsyncGate? = nil
    ) {
        self.failFirstResumeForMissingRollout = failFirstResumeForMissingRollout
        self.startGate = startGate
    }

    var hasActiveThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    var startUserTurnCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return turnCount
    }

    var startAttemptWasResume: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return resumeAttempts
    }

    var shutdownCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return shutdownCount
    }

    private func markStarted() {
        lock.lock()
        started = true
        lock.unlock()
    }

    private func recordStartAttempt(existing: CodexNativeSessionController.SessionRef?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let isResume = existing != nil
        resumeAttempts.append(isResume)
        let shouldFail = failFirstResumeForMissingRollout && isResume && !didFailResume
        if shouldFail {
            didFailResume = true
        }
        return shouldFail
    }

    /// A never-finishing stream: a stream that ends would trip the coordinator's unexpected-stream-end
    /// recovery mid-turn. The event task simply suspends until the controller is torn down.
    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { _ in }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        markStarted()
        return CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        markStarted()
        return CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        if let startGate {
            await startGate.markStartedAndWaitForRelease()
        }
        if recordStartAttempt(existing: existing) {
            throw NSError(
                domain: "CodexMCPRoutingReadinessTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "no rollout found for thread id missing-rollout-thread"]
            )
        }
        markStarted()
        return CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        lock.lock()
        turnCount += 1
        lock.unlock()
        return CodexTurnStartReceipt(provisionalSubmissionID: "<test-submission>")
    }

    func shutdown() async {
        lock.lock()
        shutdownCount += 1
        started = false
        lock.unlock()
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "fake",
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

    func setThreadGoalStatus(_: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}

    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}
