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
            let coordinator = makeCoordinator(controller: controller, recorder: recorder, routeOnPolicyInstall: false)

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
            let coordinator = makeCoordinator(controller: controller, recorder: recorder, routeOnPolicyInstall: false)

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
                routeOnPolicyInstall: false,
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

    func testResumingChildWhoseRoutingConfirmsReachesFirstTurn() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let controller = RoutingReadinessFakeCodexController()
            let recorder = TerminalPublicationRecorder()
            let coordinator = makeCoordinator(controller: controller, recorder: recorder, routeOnPolicyInstall: true)

            // A resumed session: a prior turn exists and the controller needs a reconnect, so the routing
            // wait is armed exactly as for a fresh start. Its routing then confirms.
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
            session.beginRunAttempt(source: "test.routing-readiness.resume")

            let outcome = await coordinator.sendCodexNativeMessage(
                session: session,
                text: "next turn",
                attachments: []
            )
            if let runID = session.runID {
                trackedRunIDs.append(runID)
            }

            // A healthy resume whose connection routes must not be failed closed.
            XCTAssertTrue(outcome.didSend, "a routed resume must dispatch its turn, got \(outcome)")
            XCTAssertEqual(controller.startUserTurnCount, 1, "a routed resume must reach startUserTurn exactly once")
            XCTAssertTrue(recorder.publishedStates.isEmpty, "an in-flight routed turn must not publish a terminal state")
        }
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
        routeOnPolicyInstall: Bool,
        routingTimeoutMs: Int? = nil,
        capturedRunID: RunIDBox? = nil
    ) -> CodexAgentModeCoordinator {
        // Install the real per-run policy so the expected-PID policy arms; optionally signal routing so
        // the routed case's wait resolves. The routing waiter is registered before policy install, so
        // signalling here resolves the subsequent requireRouting wait.
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
            if routeOnPolicyInstall, let runID {
                await MCPRoutingWaiter.notifyRouted(runID: runID)
            }
        }

        let host = AgentModeViewModel(
            testWindowID: testWindowID,
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

/// Fake Codex controller whose `startOrResume` binds a thread (so the coordinator treats the thread as
/// active and reaches the routing gate) but whose child never connects MCP. It counts `startUserTurn`
/// calls so a test can prove the first turn never fired when routing fails closed.
private final class RoutingReadinessFakeCodexController: CodexSessionControllerTurnDispatchTestDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var turnCount = 0

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

    private func markStarted() {
        lock.lock()
        started = true
        lock.unlock()
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
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
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

    func shutdown() async {
        lock.lock()
        started = false
        lock.unlock()
    }

    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}
