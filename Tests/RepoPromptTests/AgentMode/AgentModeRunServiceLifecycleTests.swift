import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

private let lifecycleAwaitTimeoutSeconds: TimeInterval = 5

@MainActor
final class AgentModeRunServiceLifecycleTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    func testStartupFailureTransitionsBeforeProviderDispatch() async {
        for agent in [AgentProviderKind.codexExec, .claudeCode, .openCode] {
            let recorder = LifecycleRecorder()
            let harness = makeHarness(
                recorder: recorder,
                workspacePathProvider: { _ in throw LifecycleTestError.workspaceMissing }
            )
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            session.selectedAgent = agent
            session.beginRunAttempt(source: "test")

            let outcome = await harness.service.startRun(
                tabID: session.tabID,
                session: session,
                initialUserMessage: "start",
                initialMessageForRun: "start",
                attachments: []
            )

            XCTAssertEqual(session.runState, .failed, agent.rawValue)
            XCTAssertNil(session.activeRunAttemptID, agent.rawValue)
            XCTAssertNil(session.agentTask, agent.rawValue)
            XCTAssertNil(session.provider, agent.rawValue)
            XCTAssertEqual(session.items.filter { $0.kind == .error }.map(\.text), [LifecycleTestError.workspaceMissing.errorDescription ?? ""], agent.rawValue)
            XCTAssertTrue(recorder.contains("handoff:false"), agent.rawValue)
            XCTAssertTrue(recorder.contains("run-active:false"), agent.rawValue)
            XCTAssertTrue(recorder.contains("attachments:deleteFiles"), agent.rawValue)
            XCTAssertTrue(recorder.contains("bindings"), agent.rawValue)
            XCTAssertTrue(recorder.contains("save"), agent.rawValue)
            XCTAssertFalse(recorder.contains(prefix: "factory:"), agent.rawValue)
            if agent == .codexExec {
                guard case let .failed(message)? = outcome else {
                    XCTFail("Expected Codex startup failure outcome", file: #filePath, line: #line)
                    continue
                }
                XCTAssertEqual(message, LifecycleTestError.workspaceMissing.errorDescription ?? "")
            } else {
                XCTAssertNil(outcome, agent.rawValue)
            }
        }
    }

    func testCodexRejectedSendOnlyEndsOwnershipCreatedByInvocation() async {
        let recorder = LifecycleRecorder()
        let codexController = LifecycleNoopCodexController(recorder: recorder, failSend: true)
        let harness = makeHarness(recorder: recorder, codexController: codexController)
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .codexExec

        let freshOutcome = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "fresh failure",
            initialMessageForRun: "fresh failure",
            attachments: []
        )

        guard case .failed? = freshOutcome else {
            return XCTFail("Expected fresh Codex send to fail")
        }
        XCTAssertNil(session.activeRunOwnership)

        let reusedOwnership = session.beginRunAttempt(source: "test.reusedCodex")
        let reusedOutcome = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "reused failure",
            initialMessageForRun: "reused failure",
            attachments: []
        )

        guard case .failed? = reusedOutcome else {
            return XCTFail("Expected reused Codex send to fail")
        }
        XCTAssertEqual(session.activeRunOwnership, reusedOwnership)
        session.endRunAttempt(ifCurrent: reusedOwnership, source: "test.cleanup")
    }

    func testStartRunDispatchesCurrentProviderFamiliesWithoutHeadlessFallback() async throws {
        do {
            let recorder = LifecycleRecorder()
            let codexController = LifecycleNoopCodexController(recorder: recorder)
            let harness = makeHarness(recorder: recorder, codexController: codexController)
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            session.selectedAgent = .codexExec
            session.activeAgentSessionID = UUID()

            let outcome = await harness.service.startRun(
                tabID: session.tabID,
                session: session,
                initialUserMessage: "codex",
                initialMessageForRun: "codex",
                attachments: []
            )

            XCTAssertEqual(outcome, .sent)
            XCTAssertEqual(session.activeRunOwnership?.binding.tabID, session.tabID)
            XCTAssertEqual(session.activeRunOwnership?.binding.persistentSessionID, session.activeAgentSessionID)
            XCTAssertEqual(session.activeRunLiveness?.stage, .running)
            XCTAssertTrue(recorder.contains("codex:send"))
            XCTAssertFalse(recorder.contains("factory:claude"))
            XCTAssertFalse(recorder.contains("factory:acp-provider"))
            XCTAssertFalse(recorder.contains("factory:headless"))
            await harness.service.cancelRun(tabID: session.tabID, session: session)
            XCTAssertNil(session.activeRunOwnership)
        }

        do {
            let recorder = LifecycleRecorder()
            let claudeController = LifecycleFakeNativeController(
                recorder: recorder,
                hasTurnInFlight: false,
                failSend: true
            )
            let harness = makeHarness(recorder: recorder, claudeController: claudeController)
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            session.selectedAgent = .claudeCode

            let outcome = await harness.service.startRun(
                tabID: session.tabID,
                session: session,
                initialUserMessage: "claude",
                initialMessageForRun: "claude",
                attachments: []
            )

            XCTAssertNil(outcome)
            XCTAssertNotNil(session.activeRunOwnership)
            XCTAssertEqual(session.activeRunOwnership?.binding.tabID, session.tabID)
            try await waitUntil("Claude dispatch should reach its native controller") {
                recorder.contains("claude:send")
            }
            XCTAssertTrue(recorder.contains("factory:claude"))
            XCTAssertFalse(recorder.contains("factory:acp-provider"))
            XCTAssertFalse(recorder.contains("factory:headless"))
            await session.agentTask?.value
        }

        do {
            let recorder = LifecycleRecorder()
            let provider = LifecycleFakeACPProvider(providerID: .openCode, commandPath: "/usr/bin/true")
            let harness = makeHarness(
                recorder: recorder,
                acpProviderFactory: { _, _ in
                    recorder.record("factory:acp-provider")
                    return provider
                },
                acpControllerFactory: { _, _ in
                    recorder.record("factory:acp-controller")
                    throw LifecycleTestError.expectedACPDispatchStop
                }
            )
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            session.selectedAgent = .openCode

            let outcome = await harness.service.startRun(
                tabID: session.tabID,
                session: session,
                initialUserMessage: "acp",
                initialMessageForRun: "acp",
                attachments: []
            )

            XCTAssertNil(outcome)
            XCTAssertEqual(session.runState, .failed)
            XCTAssertNil(session.activeRunOwnership)
            XCTAssertTrue(recorder.contains("factory:acp-provider"))
            XCTAssertTrue(recorder.contains("factory:acp-controller"))
            XCTAssertFalse(recorder.contains("factory:claude"))
            XCTAssertFalse(recorder.contains("factory:headless"))
        }
    }

    func testQueuedClaudeSteeringWaitsForMCPIdleThenDrainsOrRestoresDraft() async {
        do {
            let recorder = LifecycleRecorder()
            let claudeController = LifecycleFakeNativeController(
                recorder: recorder,
                hasTurnInFlight: true,
                failSend: false
            )
            let harness = makeHarness(
                recorder: recorder,
                idleWaiter: { _ in recorder.record("idle") },
                claudeController: claudeController
            )
            let session = makeRunningClaudeSession(controller: claudeController)
            session.pendingClaudeSteeringInstructions = [makeClaudeSteeringInstruction(session: session, text: "steer successfully")]

            let queueStarted = await harness.service.submitQueuedClaudeSteeringIfSupported(session: session)
            XCTAssertTrue(queueStarted)
            await session.claudeSteeringFlushTask?.value

            XCTAssertTrue(session.pendingClaudeSteeringInstructions.isEmpty)
            XCTAssertTrue(recorder.contains("delivered"))
            assertOrderedEvents(["idle", "claude:interrupt:interrupt", "claude:send", "delivered"], in: recorder)
        }

        do {
            let recorder = LifecycleRecorder()
            let claudeController = LifecycleFakeNativeController(
                recorder: recorder,
                hasTurnInFlight: true,
                failSend: true
            )
            let harness = makeHarness(
                recorder: recorder,
                idleWaiter: { _ in recorder.record("idle") },
                claudeController: claudeController
            )
            let session = makeRunningClaudeSession(controller: claudeController)
            session.pendingClaudeSteeringInstructions = [makeClaudeSteeringInstruction(session: session, text: "restore me")]
            session.pendingNonCodexUserInputTokenQueue = [7]

            let queueStarted = await harness.service.submitQueuedClaudeSteeringIfSupported(session: session)
            XCTAssertTrue(queueStarted)
            await session.claudeSteeringFlushTask?.value

            XCTAssertTrue(session.pendingClaudeSteeringInstructions.isEmpty)
            XCTAssertEqual(session.pendingNonCodexUserInputTokenQueue, [7])
            XCTAssertTrue(recorder.contains("draft:restore me"))
            XCTAssertFalse(recorder.contains("delivered"))
            assertOrderedEvents(["idle", "claude:interrupt:interrupt", "claude:send", "draft:restore me"], in: recorder)
        }
    }

    func testQueuedACPSteeringWaitsForMCPIdleThenInterruptsPromptsOrRestoresFollowUp() async throws {
        do {
            let recorder = LifecycleRecorder()
            let scriptURL = try makeFakeACPServerScript()
            let provider = LifecycleFakeACPProvider(providerID: .openCode, commandPath: scriptURL.path)
            let workspacePath = FileManager.default.temporaryDirectory.path
            let request = makeACPRunRequest(workspacePath: workspacePath)
            let controller = try makeACPController(provider: provider, request: request, recorder: recorder)
            try await withACPController(controller) { controller in
                try await withLifecycleTimeout("ACP bootstrap") {
                    _ = try await controller.bootstrap()
                }
                let initialPrompt = Task {
                    try await controller.prompt(AgentMessage(userMessage: "initial prompt"), request: request)
                }
                defer { initialPrompt.cancel() }
                try await waitUntil("Initial ACP prompt should be in flight") {
                    recorder.contains("acp:session/prompt")
                }
                let harness = makeHarness(
                    recorder: recorder,
                    workspacePathProvider: { _ in workspacePath },
                    idleWaiter: { _ in recorder.record("idle") }
                )
                let session = makeRunningACPSession(controller: controller)
                session.pendingACPSteeringInstructions = [makeACPSteeringInstruction(session: session, text: "steer ACP")]
                defer { session.acpSteeringFlushTask?.cancel() }

                let queueStarted = try await withLifecycleTimeout("ACP steering submission") {
                    await harness.service.submitQueuedACPSteeringIfSupported(session: session)
                }
                XCTAssertTrue(queueStarted)
                try await withLifecycleTimeout("ACP steering flush") {
                    await session.acpSteeringFlushTask?.value
                }
                try await withLifecycleTimeout("initial ACP prompt completion") {
                    try await initialPrompt.value
                }

                XCTAssertTrue(session.pendingACPSteeringInstructions.isEmpty)
                XCTAssertTrue(recorder.contains("delivered"))
                assertOrderedEvents(["idle", "acp:session/cancel", "acp:session/prompt", "delivered"], in: recorder, afterFirstMatchOf: "acp:session/prompt")
            }
        }

        do {
            let recorder = LifecycleRecorder()
            let scriptURL = try makeFakeACPServerScript()
            let provider = LifecycleFakeACPProvider(providerID: .openCode, commandPath: scriptURL.path)
            let request = makeACPRunRequest(workspacePath: FileManager.default.temporaryDirectory.path)
            let controller = try makeACPController(provider: provider, request: request, recorder: recorder)
            try await withACPController(controller) { controller in
                let harness = makeHarness(
                    recorder: recorder,
                    idleWaiter: { _ in throw CancellationError() }
                )
                let session = makeRunningACPSession(controller: controller)
                session.pendingACPSteeringInstructions = [makeACPSteeringInstruction(session: session, text: "preserve ACP follow-up")]
                defer { session.acpSteeringFlushTask?.cancel() }

                let queueStarted = try await withLifecycleTimeout("ACP steering submission") {
                    await harness.service.submitQueuedACPSteeringIfSupported(session: session)
                }
                XCTAssertTrue(queueStarted)
                try await withLifecycleTimeout("ACP steering flush") {
                    await session.acpSteeringFlushTask?.value
                }

                XCTAssertTrue(session.pendingACPSteeringInstructions.isEmpty)
                XCTAssertEqual(session.pendingInstructions, ["preserve ACP follow-up"])
                XCTAssertFalse(recorder.contains("delivered"))
            }
        }
    }

    func testCancelRunCleansClaudeAndACPProvidersAfterCommonMCPToolCancellation() async throws {
        for row in LifecycleCancellationRow.allCases {
            let recorder = LifecycleRecorder()
            let harness = makeHarness(
                recorder: recorder,
                cancelMCPTools: { _, _ in recorder.record("mcp-cancel") }
            )
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            session.runState = .running
            session.runID = UUID()
            session.beginRunAttempt(source: "test")

            switch row {
            case .claudeNative:
                let controller = LifecycleFakeNativeController(
                    recorder: recorder,
                    hasTurnInFlight: false,
                    failSend: false
                )
                session.selectedAgent = .claudeCode
                session.claudeController = controller

                await harness.service.cancelRun(tabID: session.tabID, session: session)

                XCTAssertNil(session.claudeController, row.rawValue)
                assertOrderedEvents(["mcp-cancel", "claude:interrupt:interrupt", "claude:shutdown"], in: recorder, row: row.rawValue)
            case .acp:
                let scriptURL = try makeFakeACPServerScript()
                let provider = LifecycleFakeACPProvider(providerID: .openCode, commandPath: scriptURL.path)
                let request = makeACPRunRequest(workspacePath: FileManager.default.temporaryDirectory.path)
                let controller = try makeACPController(provider: provider, request: request, recorder: recorder)
                try await withACPController(controller) { controller in
                    try await withLifecycleTimeout("ACP bootstrap") {
                        _ = try await controller.bootstrap()
                    }
                    session.selectedAgent = .openCode
                    session.acpController = controller

                    try await withLifecycleTimeout("ACP cancel run") {
                        await harness.service.cancelRun(tabID: session.tabID, session: session)
                    }

                    XCTAssertNil(session.acpController, row.rawValue)
                    let hasReusableSession = try await withLifecycleTimeout("ACP reusable-session check") {
                        await controller.hasReusableSession
                    }
                    XCTAssertFalse(hasReusableSession, row.rawValue)
                    assertOrderedEvents(["mcp-cancel", "acp:session/cancel"], in: recorder, row: row.rawValue)
                }
            }

            XCTAssertEqual(session.runState, .cancelled, row.rawValue)
            XCTAssertNil(session.activeRunAttemptID, row.rawValue)
            XCTAssertTrue(recorder.contains("attachments:deleteFiles"), row.rawValue)
        }
    }

    private func makeHarness(
        recorder: LifecycleRecorder,
        workspacePathProvider: @escaping (AgentModeViewModel.TabSession) throws -> String? = { _ in FileManager.default.currentDirectoryPath },
        idleWaiter: @escaping LifecycleMCPIdleWaiter = { _ in },
        cancelMCPTools: @escaping (_ runID: UUID, _ reason: String) -> Void = { _, _ in },
        codexController: LifecycleNoopCodexController? = nil,
        claudeController: LifecycleFakeNativeController? = nil,
        headlessProviderFactory: AgentModeViewModel.HeadlessProviderFactory? = nil,
        acpProviderFactory: AgentModeViewModel.ACPProviderFactory? = nil,
        acpControllerFactory: AgentModeViewModel.ACPControllerFactory? = nil
    ) -> LifecycleHarness {
        let codexController = codexController ?? LifecycleNoopCodexController(recorder: recorder)
        let claudeController = claudeController ?? LifecycleFakeNativeController(recorder: recorder)
        let headlessProviderFactory = headlessProviderFactory ?? { _, _ in
            recorder.record("factory:headless")
            return LifecycleNoopHeadlessProvider()
        }
        let acpProviderFactory = acpProviderFactory ?? { _, _ in
            recorder.record("factory:acp-provider")
            return nil
        }
        let acpControllerFactory = acpControllerFactory ?? { provider, request in
            recorder.record("factory:acp-controller")
            return try ACPAgentSessionController(provider: provider, runRequest: request)
        }
        let policyInstaller: AgentModeViewModel.ConnectionPolicyInstaller = { _, _, _, _, _, _, _, _, _, _, _, _, _ in }
        let serverEnabler: AgentModeViewModel.MCPServerEnabler = {}
        let host = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in codexController },
            claudeControllerFactory: { _, _, _, _, _, _, _ in
                recorder.record("factory:claude")
                return claudeController
            },
            headlessProviderFactory: headlessProviderFactory,
            acpProviderFactory: acpProviderFactory,
            acpControllerFactory: acpControllerFactory,
            connectionPolicyInstaller: policyInstaller,
            mcpServerEnabler: serverEnabler
        )
        let dependencies = AgentModeRunService.Dependencies(
            windowID: 1,
            headlessProviderFactory: headlessProviderFactory,
            acpProviderFactory: acpProviderFactory,
            acpControllerFactory: acpControllerFactory,
            connectionPolicyInstaller: policyInstaller,
            mcpServerEnabler: serverEnabler,
            workspacePathProvider: workspacePathProvider,
            codexCoordinator: host.test_codexCoordinator,
            claudeCoordinator: host.claudeCoordinator,
            shouldManageCodexTooling: false,
            providerRuntimePermissionResolver: { [bindingService = host.providerBindingService] agent, profile in
                bindingService.runtimePermission(for: agent, profile: profile)
            },
            cancelMCPToolsForRun: cancelMCPTools,
            awaitNoActiveMCPTools: idleWaiter,
            activeAgentRunWaitQuery: { _ in false },
            childAgentRunWaitDrainTimeoutSeconds: 0.01
        )
        return LifecycleHarness(
            service: AgentModeRunService(
                dependencies: dependencies,
                hooks: makeHooks(recorder: recorder),
                toolTrackingHooks: .noOp
            ),
            host: host
        )
    }

    private func makeHooks(recorder: LifecycleRecorder) -> AgentModeRunService.Hooks {
        AgentModeRunService.Hooks(
            estimateRuntimeTokens: { $0.count },
            addUserInputTokensToActiveNonCodexTurn: { tokens, _ in recorder.record("tokens:\(tokens)") },
            startNonCodexTurnAccountingIfNeeded: { _, _ in },
            reserveAttachmentsForTurn: { _, _ in nil },
            markAttachmentsConsumed: { _, _ in },
            stageConsumedAttachmentFilesForDeferredCleanup: { _, _ in },
            consumeDeferredAttachmentCleanup: { _, _ in },
            finalizeAttachmentsForTurn: { _, _, disposition in recorder.record("attachments:\(disposition)") },
            setAgentRunActive: { _, isActive in recorder.record("run-active:\(isActive)") },
            updateBindings: { _ in recorder.record("bindings") },
            requestUIRefresh: { _, _ in },
            scheduleSave: { _ in recorder.record("save") },
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
            clearPendingAssistantDelta: { _ in },
            startFollowUpRun: { _, _ in },
            restoreDraftText: { _, text, _, _ in recorder.record("draft:\(text)") },
            augmentUserMessageForProviderSend: { text, _, _, _ in text },
            stageResumeRecoveryHandoffIfNeeded: { _ in },
            prependPendingHandoffIfNeeded: { text, _ in text },
            recordPendingHandoffSendOutcome: { _, didSend in recorder.record("handoff:\(didSend)") },
            signalMCPInstructionDelivered: { _ in recorder.record("delivered") }
        )
    }

    private func makeRunningClaudeSession(controller: LifecycleFakeNativeController) -> AgentModeViewModel.TabSession {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.runState = .running
        session.runID = UUID()
        session.beginRunAttempt(source: "test")
        session.claudeController = controller
        return session
    }

    private func makeClaudeSteeringInstruction(
        session: AgentModeViewModel.TabSession,
        text: String
    ) -> AgentModeViewModel.TabSession.ClaudeSteeringInstruction {
        AgentModeViewModel.TabSession.ClaudeSteeringInstruction(
            id: UUID(),
            targetRunID: session.runID,
            targetRunAttemptID: session.activeRunAttemptID,
            providerText: text,
            attachments: [],
            taggedFileAttachments: [],
            draftText: text,
            optimisticUserItemID: nil,
            createdAt: Date()
        )
    }

    private func makeRunningACPSession(controller: ACPAgentSessionController) -> AgentModeViewModel.TabSession {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .openCode
        session.runState = .running
        session.runID = UUID()
        session.beginRunAttempt(source: "test")
        session.acpController = controller
        return session
    }

    private func makeACPSteeringInstruction(
        session: AgentModeViewModel.TabSession,
        text: String
    ) -> AgentModeViewModel.TabSession.ACPSteeringInstruction {
        AgentModeViewModel.TabSession.ACPSteeringInstruction(
            id: UUID(),
            targetRunID: session.runID,
            targetRunAttemptID: session.activeRunAttemptID,
            providerText: text,
            interruptedPromptProviderText: nil,
            attachments: [],
            taggedFileAttachments: [],
            draftText: text,
            optimisticUserItemID: nil,
            createdAt: Date()
        )
    }

    private func makeACPRunRequest(workspacePath: String) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .openCode,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
    }

    private func makeACPController(
        provider: LifecycleFakeACPProvider,
        request: ACPRunRequest,
        recorder: LifecycleRecorder
    ) throws -> ACPAgentSessionController {
        try ACPAgentSessionController(
            provider: provider,
            runRequest: request,
            diagnosticSink: { event in
                guard case let .outboundJSON(line) = event,
                      let data = line.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let method = payload["method"] as? String
                else {
                    return
                }
                recorder.record("acp:\(method)")
            }
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentModeRunServiceLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private func makeFakeACPServerScript() throws -> URL {
        let directory = try makeTemporaryDirectory()
        let scriptURL = directory.appendingPathComponent("fake_acp_server.py")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import sys

        prompt_count = 0
        pending_prompt_id = None

        def respond(request_id, result=None):
            payload = {"jsonrpc": "2.0", "id": request_id, "result": result or {}}
            print(json.dumps(payload), flush=True)

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            method = request.get("method")
            if method == "initialize":
                respond(request.get("id"), {"agentCapabilities": {"loadSession": True}, "authMethods": []})
            elif method == "session/new":
                respond(request.get("id"), {"sessionId": "lifecycle-session"})
            elif method == "session/prompt":
                prompt_count += 1
                if prompt_count == 1:
                    pending_prompt_id = request.get("id")
                else:
                    respond(request.get("id"), {"stopReason": "end_turn", "usage": {"inputTokens": 1, "outputTokens": 2}})
            elif method == "session/cancel":
                if pending_prompt_id is not None:
                    respond(pending_prompt_id, {"stopReason": "cancelled", "usage": {"inputTokens": 1, "outputTokens": 0}})
                    pending_prompt_id = None
            else:
                respond(request.get("id"), {})
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func withACPController(
        _ controller: ACPAgentSessionController,
        operation: (ACPAgentSessionController) async throws -> Void
    ) async throws {
        do {
            try await operation(controller)
            try await shutdownACPController(controller)
        } catch {
            await shutdownACPControllerAfterFailure(controller)
            throw error
        }
    }

    private func shutdownACPController(_ controller: ACPAgentSessionController) async throws {
        try await withLifecycleTimeout("ACP controller shutdown", cancelOperationOnTimeout: false) {
            await controller.shutdown()
        }
    }

    private func shutdownACPControllerAfterFailure(_ controller: ACPAgentSessionController) async {
        do {
            try await shutdownACPController(controller)
        } catch {
            XCTFail("ACP controller cleanup failed: \(error.localizedDescription)")
        }
    }

    private func withLifecycleTimeout<Value: Sendable>(
        _ operationDescription: String,
        timeoutSeconds: TimeInterval = lifecycleAwaitTimeoutSeconds,
        cancelOperationOnTimeout: Bool = true,
        operation: @escaping () async throws -> Value
    ) async throws -> Value {
        let operationTask = Task {
            try await operation()
        }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = LifecycleTimeoutGate(continuation: continuation)
            Task {
                let result = await operationTask.result
                await gate.resume(with: result)
            }
            Task {
                let timeoutNanoseconds = UInt64((timeoutSeconds * 1_000_000_000).rounded())
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                let error = LifecycleTimeoutError(
                    operation: operationDescription,
                    timeoutSeconds: timeoutSeconds
                )
                if await gate.resume(with: .failure(error)), cancelOperationOnTimeout {
                    operationTask.cancel()
                }
            }
        }
    }

    private func waitUntil(
        _ message: String,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0 ..< 500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        throw LifecycleTimeoutError(operation: message, timeoutSeconds: 0.5)
    }

    private func assertOrderedEvents(
        _ expected: [String],
        in recorder: LifecycleRecorder,
        afterFirstMatchOf marker: String? = nil,
        row: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let events = recorder.events
        var cursor = marker.flatMap { events.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        for event in expected {
            guard let index = events[cursor...].firstIndex(of: event) else {
                XCTFail("Missing ordered event \(event) for \(row ?? "row"). Events: \(events)", file: file, line: line)
                return
            }
            cursor = index + 1
        }
    }
}

private typealias LifecycleMCPIdleWaiter = (_ runID: UUID) async throws -> Void

private struct LifecycleTimeoutError: LocalizedError {
    let operation: String
    let timeoutSeconds: TimeInterval

    var errorDescription: String? {
        "Lifecycle test timed out waiting for \(operation) after \(timeoutSeconds)s."
    }
}

private actor LifecycleTimeoutGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?

    init(continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(with result: Result<Value, Error>) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(with: result)
        return true
    }
}

private struct LifecycleHarness {
    let service: AgentModeRunService
    let host: AgentModeViewModel
}

private enum LifecycleCancellationRow: String, CaseIterable {
    case claudeNative
    case acp
}

private enum LifecycleTestError: LocalizedError {
    case workspaceMissing
    case expectedACPDispatchStop
    case expectedClaudeSendFailure
    case expectedCodexSendFailure

    var errorDescription: String? {
        switch self {
        case .workspaceMissing:
            "Lifecycle test workspace is missing."
        case .expectedACPDispatchStop:
            "Expected ACP dispatch stop."
        case .expectedClaudeSendFailure:
            "Expected Claude send failure."
        case .expectedCodexSendFailure:
            "Expected Codex send failure."
        }
    }
}

private final class LifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    func contains(_ event: String) -> Bool {
        events.contains(event)
    }

    func contains(prefix: String) -> Bool {
        events.contains(where: { $0.hasPrefix(prefix) })
    }
}

private final class LifecycleNoopHeadlessProvider: HeadlessAgentProvider {
    func streamAgentMessage(_ message: AgentMessage, runID: UUID?) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func dispose() async {}
}

private final class LifecycleNoopCodexController: CodexSessionControlling {
    private let recorder: LifecycleRecorder
    private let failSend: Bool
    private(set) var hasActiveThread = false

    init(recorder: LifecycleRecorder, failSend: Bool = false) {
        self.recorder = recorder
        self.failSend = failSend
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { _ in }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String) async throws -> CodexNativeSessionController.SessionRef {
        hasActiveThread = true
        return CodexNativeSessionController.SessionRef(conversationID: "lifecycle", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?) async throws -> CodexNativeSessionController.SessionRef {
        hasActiveThread = true
        return CodexNativeSessionController.SessionRef(conversationID: "lifecycle", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexNativeSessionController.SessionRef {
        hasActiveThread = true
        return CodexNativeSessionController.SessionRef(conversationID: "lifecycle", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(includeTurns: Bool, timeout: TimeInterval?) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "lifecycle",
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
    func sendUserMessage(_ text: String) async throws {
        try recordCodexSend()
    }

    func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {
        try recordCodexSend()
    }

    func sendUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?) async throws {
        try recordCodexSend()
    }

    func sendUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?, serviceTier: String?) async throws {
        try recordCodexSend()
    }

    private func recordCodexSend() throws {
        recorder.record("codex:send")
        if failSend {
            throw LifecycleTestError.expectedCodexSendFailure
        }
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

    func cancelCurrentTurn() async {
        recorder.record("codex:cancel")
    }

    func shutdown() async {
        recorder.record("codex:shutdown")
    }

    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}

private actor LifecycleFakeNativeController: NativeAgentRuntimeControlling {
    private let recorder: LifecycleRecorder
    private let turnInFlight: Bool
    private let failSend: Bool
    private let sessionRef = NativeAgentRuntimeSessionRef(sessionID: "lifecycle-claude-session")
    private let stream: AsyncStream<NativeAgentRuntimeEvent>

    init(
        recorder: LifecycleRecorder,
        hasTurnInFlight: Bool = false,
        failSend: Bool = false
    ) {
        self.recorder = recorder
        turnInFlight = hasTurnInFlight
        self.failSend = failSend
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

    func ensureEventsStreamReady() async {}
    func resetEventsStreamForNewRun() async {}

    func startOrResume(
        existingSessionID: String?,
        model: String?,
        effortLevel: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride: String?
    ) async throws -> NativeAgentRuntimeSessionRef {
        recorder.record("claude:start")
        return sessionRef
    }

    func currentSessionRef() async -> NativeAgentRuntimeSessionRef {
        sessionRef
    }

    func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws {}

    func sendUserMessage(_ text: String) async throws -> UUID {
        recorder.record("claude:send")
        if failSend {
            throw LifecycleTestError.expectedClaudeSendFailure
        }
        return UUID()
    }

    func interruptTurn(reason: String) async -> NativeAgentRuntimeInterruptOutcome {
        recorder.record("claude:interrupt:\(reason)")
        return .noTurnInFlight
    }

    func shutdown() async {
        recorder.record("claude:shutdown")
    }

    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async {}
}

private struct LifecycleFakeACPProvider: ACPAgentProvider {
    let providerID: ACPProviderID
    let commandPath: String

    func support(for request: ACPRunRequest) async -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        ACPLaunchConfiguration(
            providerID: providerID,
            command: commandPath,
            arguments: [],
            environment: [:],
            workingDirectory: request.workspacePath,
            additionalPathHints: [],
            enableDebugLogging: false
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        ACPSessionConfiguration(
            mode: .new,
            workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
            mcpServers: []
        )
    }

    func buildPromptBlocks(
        for message: AgentMessage,
        request: ACPRunRequest
    ) throws -> [[String: Any]] {
        [["type": "text", "text": message.userMessage]]
    }

    func normalizeSessionUpdate(
        _ payload: [String: Any],
        sessionID: String
    ) -> [NormalizedAgentRuntimeEvent] {
        []
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }
}
