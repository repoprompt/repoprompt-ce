import Darwin
import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

private let lifecycleAwaitTimeoutSeconds: TimeInterval = 5

@MainActor
final class AgentModeRunServiceLifecycleTests: XCTestCase {
    private var temporaryURLs: [URL] = []
    private var lifecycleHosts: [AgentModeViewModel] = []
    private var acpControllers: [ObjectIdentifier: ACPAgentSessionController] = [:]

    override func tearDown() async throws {
        await cleanupRegisteredRuntime()
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        try await super.tearDown()
    }

    func testTerminalCommitPreservesRebuiltToolCorrelationIndexes() async throws {
        let recorder = LifecycleRecorder()
        let barrier = AgentRunTerminalCommitBarrier(hooks: makeHooks(recorder: recorder))
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        let invocationID = UUID()
        session.setItemsSilently([
            .user("prior", sequenceIndex: 0),
            .assistant("done", sequenceIndex: 1),
            .user("active", sequenceIndex: 2),
            .toolCall(
                name: "read_file",
                invocationID: invocationID,
                argsJSON: #"{"path":"Sources/Active.swift"}"#,
                sequenceIndex: 3
            )
        ], reason: .persistedSessionHydration)
        session.runID = UUID()
        session.runState = .running
        let ownership = session.beginRunAttempt(source: "test.correlationIndex")

        var completed = try XCTUnwrap(session.items.last)
        completed.kind = .toolResult
        completed.toolResultJSON = #"{"content":"ok"}"#
        completed.text = completed.toolResultJSON ?? ""
        session.replaceItem(at: 3, with: completed)
        let revision = await barrier.commit(.init(
            session: session,
            ownership: ownership,
            expectedRunID: session.runID,
            terminalState: .completed,
            source: "test.correlationIndex",
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: false,
            supportsFollowUp: false,
            notifyTurnComplete: false
        ))

        XCTAssertNotNil(revision)
        XCTAssertEqual(session.indexedToolItemIndices(invocationID: invocationID), [3])
        XCTAssertEqual(session.liveItemIDs, Set(session.items.map(\.id)))
        session.testAssertSourceItemDerivedStateIsConsistent()
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

    func testCodexFallbackAndRejectedSendVariantsPreserveReusedOwnership() async {
        let rows: [(LifecycleNoopCodexController.SendBehavior, Bool)] = [
            (.failure, true),
            (.cancellation, true),
            (.success, false)
        ]

        for (behavior, activatesThread) in rows {
            let recorder = LifecycleRecorder()
            let codexController = LifecycleNoopCodexController(
                recorder: recorder,
                sendBehavior: behavior,
                activatesThread: activatesThread
            )
            let harness = makeHarness(recorder: recorder, codexController: codexController)
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            session.selectedAgent = .codexExec
            session.runState = .running
            session.runID = UUID()
            let ownership = session.beginRunAttempt(source: "test.reusedCodexVariant")

            let outcome = await harness.service.startRun(
                tabID: session.tabID,
                session: session,
                initialUserMessage: "reused rejected send",
                initialMessageForRun: "reused rejected send",
                attachments: []
            )

            if activatesThread {
                guard case .queuedFallback? = outcome else {
                    return XCTFail("Expected durable Codex fallback for \(behavior)")
                }
            } else {
                guard case .failed? = outcome else {
                    return XCTFail("Expected rejected Codex send for \(behavior)")
                }
            }
            XCTAssertEqual(session.activeRunOwnership, ownership, "\(behavior)")
            XCTAssertEqual(session.runState, .running, "\(behavior)")
            _ = session.endRunAttempt(ifCurrent: ownership, source: "test.cleanup")
        }
    }

    func testStartRunDispatchesCurrentProviderFamiliesWithoutHeadlessFallback() async throws {
        do {
            let recorder = LifecycleRecorder()
            let codexController = LifecycleNoopCodexController(recorder: recorder)
            let harness = makeHarness(recorder: recorder, codexController: codexController)
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            session.selectedAgent = .codexExec
            session.testInstallPersistentSessionBinding(sessionID: UUID())

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
            let provider = LifecycleFakeACPProvider(
                providerID: .openCode,
                commandPath: "/usr/bin/true",
                recorder: recorder
            )
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
            XCTAssertTrue(recorder.contains("provider:support"))
            XCTAssertTrue(recorder.contains("factory:acp-controller"))
            assertOrderedEvents(["factory:acp-provider", "provider:support", "factory:acp-controller"], in: recorder)
            XCTAssertFalse(recorder.contains("factory:claude"))
            XCTAssertFalse(recorder.contains("factory:headless"))
        }

        do {
            let recorder = LifecycleRecorder()
            let provider = LifecycleFakeACPProvider(
                providerID: .openCode,
                commandPath: "/usr/bin/true",
                supportResult: .unsupported(reason: "fixture unsupported"),
                recorder: recorder
            )
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
                initialUserMessage: "unsupported acp",
                initialMessageForRun: "unsupported acp",
                attachments: []
            )

            XCTAssertNil(outcome)
            XCTAssertEqual(session.runState, .failed)
            XCTAssertNil(session.activeRunOwnership)
            XCTAssertTrue(recorder.contains("factory:acp-provider"))
            XCTAssertTrue(recorder.contains("provider:support"))
            XCTAssertFalse(recorder.contains("factory:acp-controller"))
        }

        do {
            let recorder = LifecycleRecorder()
            let provider = LifecycleFakeACPProvider(
                providerID: .openCode,
                commandPath: "/usr/bin/true",
                cancelSupport: true,
                recorder: recorder
            )
            let harness = makeHarness(
                recorder: recorder,
                acpProviderFactory: { _, _ in
                    recorder.record("factory:acp-provider")
                    return provider
                },
                acpControllerFactory: { _, _ in
                    recorder.record("factory:acp-controller")
                    throw LifecycleTestError.unexpectedACPControllerCreation
                }
            )
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            session.selectedAgent = .openCode

            let outcome = await harness.service.startRun(
                tabID: session.tabID,
                session: session,
                initialUserMessage: "cancelled support",
                initialMessageForRun: "cancelled support",
                attachments: []
            )

            XCTAssertNil(outcome)
            XCTAssertEqual(session.runState, .cancelled)
            XCTAssertNil(session.activeRunOwnership)
            XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
            XCTAssertTrue(recorder.contains("provider:support"))
            XCTAssertFalse(recorder.contains("factory:acp-controller"))
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

    func testCursorACPSubmitsInitialPromptWhenMCPRoutingIsDeferredUntilPrompt() async throws {
        let recorder = LifecycleRecorder()
        let workspace = try makeTemporaryDirectory()
        let recordURL = workspace.appendingPathComponent("cursor-deferred-routing.jsonl")
        let scriptURL = try makeOpenCodeModeFlowServerScript()
        let provider = LifecycleFakeACPProvider(
            providerID: .cursor,
            commandPath: scriptURL.path,
            environment: ["ACP_RECORD_PATH": recordURL.path],
            recorder: recorder
        )
        let harness = makeHarness(
            recorder: recorder,
            workspacePathProvider: { _ in workspace.path },
            acpProviderFactory: { agent, _ in
                XCTAssertEqual(agent, .cursor)
                recorder.record("factory:acp-provider")
                return provider
            }
        )
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .cursor

        let outcome = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "Cursor prompt",
            initialMessageForRun: "Cursor prompt",
            attachments: []
        )

        XCTAssertNil(outcome)
        try await withLifecycleTimeout("Cursor ACP deferred routing run") {
            await session.agentTask?.value
        }

        let methods = recordedOpenCodeFlowRequests(at: recordURL).map(\.method)
        XCTAssertTrue(methods.contains("session/new"))
        XCTAssertTrue(methods.contains("session/prompt"))
        XCTAssertFalse(session.items.contains { $0.text.contains("MCP routing did not complete") })
        XCTAssertEqual(session.runState, .completed)
    }

    func testCursorACPReusedSessionInstallsDeferredPolicyForFollowUpPrompt() async throws {
        let recorder = LifecycleRecorder()
        let workspace = try makeTemporaryDirectory()
        let recordURL = workspace.appendingPathComponent("cursor-deferred-follow-up-routing.jsonl")
        let scriptURL = try makeOpenCodeModeFlowServerScript()
        let provider = LifecycleFakeACPProvider(
            providerID: .cursor,
            commandPath: scriptURL.path,
            environment: ["ACP_RECORD_PATH": recordURL.path],
            recorder: recorder
        )
        let harness = makeHarness(
            recorder: recorder,
            workspacePathProvider: { _ in workspace.path },
            acpProviderFactory: { agent, _ in
                XCTAssertEqual(agent, .cursor)
                recorder.record("factory:acp-provider")
                return provider
            }
        )
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .cursor

        let firstOutcome = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "Cursor prompt one",
            initialMessageForRun: "Cursor prompt one",
            attachments: []
        )
        XCTAssertNil(firstOutcome)
        try await withLifecycleTimeout("Cursor ACP initial deferred routing run") {
            await session.agentTask?.value
        }
        XCTAssertEqual(session.runState, .completed)
        let firstRunID = try XCTUnwrap(session.runID)

        let secondOutcome = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "Cursor prompt two",
            initialMessageForRun: "Cursor prompt two",
            attachments: []
        )
        XCTAssertNil(secondOutcome)
        try await withLifecycleTimeout("Cursor ACP deferred routing follow-up run") {
            await session.agentTask?.value
        }

        let methods = recordedOpenCodeFlowRequests(at: recordURL).map(\.method)
        XCTAssertEqual(methods.count(where: { $0 == "session/new" }), 1)
        XCTAssertEqual(methods.count(where: { $0 == "session/prompt" }), 2)
        XCTAssertEqual(session.runID, firstRunID)
        XCTAssertFalse(session.items.contains { $0.text.contains("MCP routing did not complete") })
        XCTAssertEqual(session.runState, .completed)

        let policyEvents = recorder.events.filter { $0.hasPrefix("policy:cursor:") }
        XCTAssertEqual(policyEvents.count, 2)
        XCTAssertEqual(Set(policyEvents).count, 1)
    }

    func testLifecycleCleanupReapsCompletedReusableOpenCodeProcess() async throws {
        let recorder = LifecycleRecorder()
        let workspace = try makeTemporaryDirectory()
        let processIDURL = workspace.appendingPathComponent("opencode-process-id.txt")
        let scriptURL = try makeOpenCodeModeFlowServerScript()
        let provider = LifecycleFakeACPProvider(
            providerID: .openCode,
            commandPath: scriptURL.path,
            environment: ["ACP_PID_PATH": processIDURL.path],
            recorder: recorder
        )
        let harness = makeHarness(
            recorder: recorder,
            workspacePathProvider: { _ in workspace.path },
            acpProviderFactory: { agent, _ in
                XCTAssertEqual(agent, .openCode)
                return provider
            },
            autoSignalACPRouting: true
        )
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .openCode

        let outcome = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "Complete and remain reusable",
            initialMessageForRun: "Complete and remain reusable",
            attachments: []
        )

        XCTAssertNil(outcome)
        try await withLifecycleTimeout("OpenCode reusable-session run") {
            await session.agentTask?.value
        }
        XCTAssertEqual(session.runState, .completed)
        let controller = try XCTUnwrap(session.acpController)
        let wasReusable = await controller.hasReusableSession
        XCTAssertTrue(wasReusable)

        try await waitUntil("OpenCode process ID should be recorded") {
            FileManager.default.fileExists(atPath: processIDURL.path)
        }
        let processIDText = try String(contentsOf: processIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let processID = try XCTUnwrap(pid_t(processIDText))
        XCTAssertTrue(Self.processIsRunning(processID))

        await cleanupRegisteredRuntime()

        try await waitUntil("OpenCode process should exit during lifecycle cleanup") {
            !Self.processIsRunning(processID)
        }
        XCTAssertFalse(Self.processIsRunning(processID))
        let remainsReusable = await controller.hasReusableSession
        XCTAssertFalse(remainsReusable)
    }

    func testTerminalBarrierRejectsStaleOwnership() async {
        let recorder = LifecycleRecorder()
        let barrier = AgentRunTerminalCommitBarrier(hooks: makeHooks(recorder: recorder))
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.runID = UUID()
        session.runState = .running
        let staleOwnership = session.beginRunAttempt(source: "test.stale")
        session.endRunAttempt(ifCurrent: staleOwnership, source: "test.rotate")
        let currentOwnership = session.beginRunAttempt(source: "test.current")

        let staleRevision = await barrier.commit(.init(
            session: session,
            ownership: staleOwnership,
            expectedRunID: session.runID,
            terminalState: .completed,
            source: "test.stale",
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: false,
            notifyTurnComplete: false
        ))
        XCTAssertNil(staleRevision)
        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.activeRunOwnership, currentOwnership)
        XCTAssertFalse(recorder.contains(prefix: "commit:"))
    }

    func testNewAttemptResetsProviderDrainGenerationAcrossProviderFamilies() async {
        let recorder = LifecycleRecorder()
        let barrier = AgentRunTerminalCommitBarrier(hooks: makeHooks(recorder: recorder))
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.runID = UUID()
        session.runState = .running
        let codexOwnership = session.beginRunAttempt(source: "test.codex")
        session.providerTerminalDrainGeneration = 4
        _ = session.endRunAttempt(ifCurrent: codexOwnership, source: "test.rotate")

        let claudeOwnership = session.beginRunAttempt(source: "test.claude")
        XCTAssertEqual(session.providerTerminalDrainGeneration, 0)
        let revision = await barrier.commit(.init(
            session: session,
            ownership: claudeOwnership,
            expectedRunID: session.runID,
            terminalState: .completed,
            source: "test.claude",
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: false,
            notifyTurnComplete: false
        ))

        XCTAssertNotNil(revision)
        XCTAssertEqual(session.runState, .completed)
        XCTAssertEqual(revision?.providerDrainGeneration, 0)
    }

    func testClaudeCancellationDrainsBufferedAssistantTailIntoCanonicalTerminalRevision() async throws {
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(recorder: recorder)
        var publishedRevision: AgentRunTerminalCommitRevision?
        var publishedTail: String?
        let harness = makeHarness(
            recorder: recorder,
            claudeController: controller,
            flushPendingAssistantDelta: { session in
                recorder.record("assistant-flush")
                guard !session.pendingAssistantDelta.isEmpty else { return }
                let tail = session.pendingAssistantDelta
                session.pendingAssistantDelta = ""
                session.assistantDeltaFlushGeneration &+= 1
                session.appendItem(.assistant(tail, sequenceIndex: session.nextSequenceIndex))
            },
            publishTerminalCommit: { session, revision in
                publishedRevision = revision
                publishedTail = session.items.last?.text
                recorder.record("commit:\(revision.commitID.uuidString)")
            }
        )
        let session = makeRunningClaudeSession(controller: controller)
        session.pendingAssistantDelta = "buffered terminal tail"

        await harness.service.cancelRun(
            tabID: session.tabID,
            session: session,
            completion: .terminalPublished
        )

        let revision = try XCTUnwrap(publishedRevision)
        XCTAssertEqual(session.runState, .cancelled)
        XCTAssertEqual(publishedTail, "buffered terminal tail")
        XCTAssertEqual(revision.sourceItemsRevision, session.sourceItemsRevision)
        XCTAssertEqual(revision.assistantDeltaFlushGeneration, session.assistantDeltaFlushGeneration)
        XCTAssertEqual(session.lastTerminalCommitRevision, revision)

        await harness.service.cancelRun(
            tabID: session.tabID,
            session: session,
            completion: .terminalPublished
        )
        XCTAssertEqual(recorder.events.count(where: { $0.hasPrefix("commit:") }), 1)

        assertOrderedEvents(
            ["assistant-flush", "bindings", "save", "commit:"],
            in: recorder,
            prefixMatches: true
        )
    }

    func testCodexCancellationCoalescesBufferedAssistantTailBeforeTerminalSeal() async throws {
        let recorder = LifecycleRecorder()
        let controller = LifecycleNoopCodexController(recorder: recorder)
        var publishedRevision: AgentRunTerminalCommitRevision?
        let harness = makeHarness(
            recorder: recorder,
            codexController: controller,
            publishTerminalCommit: { _, revision in
                publishedRevision = revision
                recorder.record("commit:\(revision.commitID.uuidString)")
            }
        )
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        session.runState = .running
        session.runID = UUID()
        session.beginRunAttempt(source: "test.codexBufferedCancellation")
        let baselineDrainGeneration = session.providerTerminalDrainGeneration
        session.codexController = controller
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

        harness.host.test_codexCoordinator.test_enqueueAssistantDelta("answer", session: session)
        harness.host.test_codexCoordinator.test_flushPendingAssistantDelta(session)

        let streamingPrefix = try XCTUnwrap(session.items.last)
        XCTAssertEqual(streamingPrefix.kind, .assistant)
        XCTAssertEqual(streamingPrefix.text, "answer")
        XCTAssertTrue(streamingPrefix.isStreaming)

        harness.host.test_codexCoordinator.test_enqueueAssistantDelta(".", session: session)
        XCTAssertEqual(session.pendingAssistantDelta, ".")
        XCTAssertNotNil(session.assistantDeltaFlushTask)
        session.pendingCommandRunningByKey["terminal-test"] = .init(
            invocationID: commandInvocationID,
            processID: nil,
            appendedOutput: nil,
            sealsAssistantBoundary: false
        )
        session.pendingCommandRunningFlushTask = Task {}
        XCTAssertFalse(harness.host.test_codexCoordinator.codexTerminalBuffersAreDrained(session))

        await harness.service.cancelRun(
            tabID: session.tabID,
            session: session,
            completion: .terminalPublished
        )

        let assistantItems = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantItems.map(\.text), ["answer."])
        XCTAssertEqual(assistantItems.map(\.isStreaming), [false])
        XCTAssertTrue(session.pendingAssistantDelta.isEmpty)
        XCTAssertNil(session.assistantDeltaFlushTask)
        XCTAssertTrue(session.pendingCommandRunningByKey.isEmpty)
        XCTAssertNil(session.pendingCommandRunningFlushTask)
        XCTAssertTrue(harness.host.test_codexCoordinator.codexTerminalBuffersAreDrained(session))

        let revision = try XCTUnwrap(publishedRevision)
        XCTAssertEqual(session.runState, .cancelled)
        XCTAssertEqual(revision.terminalState, .cancelled)
        XCTAssertEqual(revision.sourceItemsRevision, session.sourceItemsRevision)
        XCTAssertEqual(revision.assistantDeltaFlushGeneration, session.assistantDeltaFlushGeneration)
        XCTAssertEqual(session.providerTerminalDrainGeneration, baselineDrainGeneration + 1)
        XCTAssertEqual(revision.providerDrainGeneration, session.providerTerminalDrainGeneration)
        XCTAssertEqual(session.lastTerminalCommitRevision, revision)
    }

    func testDuplicateTerminalBarrierInvocationRetriesUnresolvedPublicationWithoutRecommitting() async throws {
        let recorder = LifecycleRecorder()
        var publicationAttempts = 0
        let hooks = makeHooks(
            recorder: recorder,
            publishTerminalCommitResult: { _, _, _ in
                publicationAttempts += 1
                return publicationAttempts == 1
                    ? .rejected(reason: "test_transient_rejection")
                    : .accepted(successorEpoch: nil)
            }
        )
        let barrier = AgentRunTerminalCommitBarrier(hooks: hooks)
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.runID = UUID()
        session.runState = .running
        let ownership = session.beginRunAttempt(source: "test.retryPublication")
        let request = AgentRunTerminalCommitBarrier.Request(
            session: session,
            ownership: ownership,
            expectedRunID: session.runID,
            terminalState: .completed,
            source: "test.retryPublication",
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: false,
            notifyTurnComplete: false
        )

        let firstRevision = await barrier.commit(request)
        let first = try XCTUnwrap(firstRevision)
        XCTAssertEqual(session.lastTerminalPublicationResult, .rejected(reason: "test_transient_rejection"))
        let duplicateRevision = await barrier.commit(request)
        let duplicate = try XCTUnwrap(duplicateRevision)

        XCTAssertEqual(first, duplicate)
        XCTAssertEqual(publicationAttempts, 2)
        XCTAssertEqual(session.lastTerminalPublicationResult, .accepted(successorEpoch: nil))
        XCTAssertEqual(recorder.events.count(where: { $0 == "assistant-flush" }), 1)
    }

    func testQueuedFollowUpStartsOnlyAfterCanonicalSuccessorPublicationResolves() async {
        let recorder = LifecycleRecorder()
        let sessionID = UUID()
        let activationID = UUID()
        let registrationGeneration: UInt64 = 7
        let epoch = AgentRunTurnEpoch(
            sessionID: sessionID,
            activationID: activationID,
            registrationGeneration: registrationGeneration,
            id: UUID(),
            ordinal: 1,
            continuityGeneration: 0,
            transitionKind: .initial
        )
        let successor = AgentRunTurnEpoch(
            sessionID: sessionID,
            activationID: activationID,
            registrationGeneration: registrationGeneration,
            id: UUID(),
            ordinal: 2,
            continuityGeneration: 0,
            transitionKind: .relatedFollowUp
        )
        var publicationAttempts = 0
        let hooks = makeHooks(
            recorder: recorder,
            publishTerminalCommitResult: { _, _, _ in
                publicationAttempts += 1
                return publicationAttempts == 1
                    ? .rejected(reason: "test_transient_rejection")
                    : .accepted(successorEpoch: successor)
            },
            makeTerminalPublicationEnvelope: { _, _, _, _ in
                .init(epoch: epoch, snapshot: .expired(sessionID: sessionID))
            },
            startFollowUpRun: { _, text in recorder.record("follow-up:\(text)") }
        )
        let barrier = AgentRunTerminalCommitBarrier(hooks: hooks)
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.runID = UUID()
        session.runState = .running
        session.pendingInstructions = ["continue"]
        let ownership = session.beginRunAttempt(source: "test.followUpPublication")
        let request = AgentRunTerminalCommitBarrier.Request(
            session: session,
            ownership: ownership,
            expectedRunID: session.runID,
            terminalState: .completed,
            source: "test.followUpPublication",
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: true,
            notifyTurnComplete: false
        )

        _ = await barrier.commit(request)
        XCTAssertEqual(session.pendingInstructions, ["continue"])
        XCTAssertTrue(session.mcpFollowUpRunPending)
        XCTAssertFalse(recorder.contains("follow-up:continue"))

        _ = await barrier.commit(request)
        XCTAssertTrue(session.pendingInstructions.isEmpty)
        XCTAssertEqual(recorder.events.count(where: { $0 == "follow-up:continue" }), 1)
        XCTAssertEqual(session.lastTerminalPublicationResult, .accepted(successorEpoch: successor))
    }

    func testProviderSuccessorConsumesOnceAfterAcceptedPublicationWithoutTouchingGenericQueue() async {
        let recorder = LifecycleRecorder()
        var publicationAttempts = 0
        var consumedRevisions: [UUID] = []
        let hooks = makeHooks(
            recorder: recorder,
            publishTerminalCommitResult: { _, _, _ in
                publicationAttempts += 1
                return publicationAttempts == 1
                    ? .rejected(reason: "transient")
                    : .accepted(successorEpoch: nil)
            }
        )
        let barrier = AgentRunTerminalCommitBarrier(hooks: hooks)
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.runID = UUID()
        session.runState = .running
        session.pendingInstructions = ["unrelated generic instruction"]
        let ownership = session.beginRunAttempt(source: "test.providerSuccessor")
        let successorID = UUID()
        let request = AgentRunTerminalCommitBarrier.Request(
            session: session,
            ownership: ownership,
            expectedRunID: session.runID,
            terminalState: .completed,
            source: "test.providerSuccessor",
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: false,
            supportsFollowUp: false,
            providerSuccessor: .init(
                id: successorID,
                transitionKind: .relatedFollowUp,
                consumeAfterPublication: { revision, result in
                    if case .accepted = result {
                        consumedRevisions.append(revision.commitID)
                        return true
                    }
                    return false
                }
            ),
            notifyTurnComplete: false
        )

        _ = await barrier.commit(request)
        XCTAssertTrue(consumedRevisions.isEmpty)
        XCTAssertEqual(session.pendingInstructions, ["unrelated generic instruction"])

        _ = await barrier.commit(request)
        _ = await barrier.commit(request)
        XCTAssertEqual(consumedRevisions.count, 1)
        XCTAssertEqual(session.pendingInstructions, ["unrelated generic instruction"])
        XCTAssertEqual(session.lastTerminalCommitRevision?.providerSuccessorID, successorID)
    }

    func testConcurrentPublicationOnlyCancellationWaitsForCanonicalPublication() async throws {
        let recorder = LifecycleRecorder()
        let publicationGate = LifecyclePublicationGate()
        let harness = makeHarness(
            recorder: recorder,
            publishTerminalCommit: { _, revision in
                recorder.record("commit:start:\(revision.commitID.uuidString)")
                await publicationGate.wait()
                recorder.record("commit:finish:\(revision.commitID.uuidString)")
            }
        )
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .cursor
        session.runState = .running
        session.runID = UUID()
        session.beginRunAttempt(source: "test.blockedPublication")

        let firstCancelTask = Task {
            await harness.service.cancelRun(
                tabID: session.tabID,
                session: session,
                completion: .terminalPublished
            )
            recorder.record("cancel:first-return")
        }
        try await waitUntil("First cancellation should reach terminal publication") {
            recorder.contains(prefix: "commit:start:")
        }

        let secondCancelTask = Task {
            await harness.service.cancelRun(
                tabID: session.tabID,
                session: session,
                completion: .terminalPublished
            )
            recorder.record("cancel:second-return")
        }
        await Task.yield()
        XCTAssertFalse(recorder.contains("cancel:first-return"))
        XCTAssertFalse(recorder.contains("cancel:second-return"))

        await publicationGate.release()
        try await withLifecycleTimeout("both publication-only cancellations") {
            await firstCancelTask.value
            await secondCancelTask.value
        }

        assertOrderedEvents(
            ["commit:start:", "commit:finish:", "cancel:first-return"],
            in: recorder,
            prefixMatches: true
        )
        assertOrderedEvents(
            ["commit:start:", "commit:finish:", "cancel:second-return"],
            in: recorder,
            prefixMatches: true
        )
    }

    func testCancellationPublishesTerminalStateBeforeSlowHeadlessDisposalCompletes() async throws {
        let recorder = LifecycleRecorder()
        let provider = LifecycleBlockingHeadlessProvider(recorder: recorder)
        let harness = makeHarness(
            recorder: recorder,
            headlessProviderFactory: { _, _ in provider }
        )
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .cursor
        session.runState = .running
        session.runID = UUID()
        session.beginRunAttempt(source: "test.slowDisposal")
        session.provider = provider

        try await withLifecycleTimeout("terminal cancellation publication", timeoutSeconds: 0.2) {
            await harness.service.cancelRun(
                tabID: session.tabID,
                session: session,
                completion: .terminalPublished
            )
        }

        XCTAssertEqual(session.runState, .cancelled)
        XCTAssertNil(session.provider)
        XCTAssertNil(session.runID)
        XCTAssertNotNil(session.lastTerminalCommitRevision)
        try await waitUntil("Slow disposal should start asynchronously") {
            recorder.contains("headless:blocking-dispose-start")
        }
        let disposeFinishedBeforeRelease = await provider.isDisposeFinished()
        XCTAssertFalse(disposeFinishedBeforeRelease)
        assertOrderedEvents(
            ["commit:", "headless:blocking-dispose-start"],
            in: recorder,
            prefixMatches: true
        )

        await provider.releaseDispose()
        try await waitUntil("Slow disposal should finish after release") {
            recorder.contains("headless:blocking-dispose-finish")
        }
    }

    func testCancellationCanAwaitTrackedTerminalTeardownCompletion() async throws {
        let recorder = LifecycleRecorder()
        let provider = LifecycleBlockingHeadlessProvider(recorder: recorder)
        let harness = makeHarness(
            recorder: recorder,
            headlessProviderFactory: { _, _ in provider }
        )
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .cursor
        session.runState = .running
        session.runID = UUID()
        session.beginRunAttempt(source: "test.awaitTeardown")
        session.provider = provider

        let cancelTask = Task {
            await harness.service.cancelRun(
                tabID: session.tabID,
                session: session,
                completion: .terminalTeardownCompleted
            )
            recorder.record("cancel:return")
        }

        try await waitUntil("Terminal publication and teardown should start") {
            recorder.contains(prefix: "commit:")
                && recorder.contains("headless:blocking-dispose-start")
        }
        XCTAssertEqual(session.runState, .cancelled)
        XCTAssertFalse(recorder.contains("cancel:return"))

        await provider.releaseDispose()
        try await withLifecycleTimeout("cleanup-waiting cancellation return") {
            await cancelTask.value
        }

        XCTAssertTrue(recorder.contains("cancel:return"))
        assertOrderedEvents(
            ["commit:", "headless:blocking-dispose-start", "headless:blocking-dispose-finish", "cancel:return"],
            in: recorder,
            prefixMatches: true
        )
    }

    func testCleanupWaitAfterPriorTerminalPublicationAwaitsSameTeardownExactlyOnce() async throws {
        let recorder = LifecycleRecorder()
        let provider = LifecycleBlockingHeadlessProvider(recorder: recorder)
        let harness = makeHarness(
            recorder: recorder,
            headlessProviderFactory: { _, _ in provider }
        )
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .cursor
        session.runState = .running
        session.runID = UUID()
        session.beginRunAttempt(source: "test.lateAwaitTeardown")
        session.provider = provider

        await harness.service.cancelRun(
            tabID: session.tabID,
            session: session,
            completion: .terminalPublished
        )
        try await waitUntil("Publication-only cancellation should start teardown") {
            recorder.contains("headless:blocking-dispose-start")
        }

        let cleanupWaitTask = Task {
            await harness.service.cancelRun(
                tabID: session.tabID,
                session: session,
                completion: .terminalTeardownCompleted
            )
            recorder.record("late-cleanup:return")
        }
        await Task.yield()
        XCTAssertFalse(recorder.contains("late-cleanup:return"))
        XCTAssertEqual(recorder.events.count(where: { $0 == "headless:blocking-dispose-start" }), 1)

        await provider.releaseDispose()
        try await withLifecycleTimeout("late cleanup wait return") {
            await cleanupWaitTask.value
        }

        XCTAssertTrue(recorder.contains("late-cleanup:return"))
        XCTAssertEqual(recorder.events.count(where: { $0 == "headless:blocking-dispose-finish" }), 1)
    }

    func testExecutionLocationCancellationReturnsAfterSynchronousProviderDetachment() async throws {
        let recorder = LifecycleRecorder()
        let provider = LifecycleBlockingHeadlessProvider(recorder: recorder)
        let harness = makeHarness(
            recorder: recorder,
            headlessProviderFactory: { _, _ in provider }
        )
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .cursor
        session.runState = .running
        session.runID = UUID()
        session.beginRunAttempt(source: "test.executionLocation")
        session.provider = provider

        try await withLifecycleTimeout("execution-location terminal publication", timeoutSeconds: 0.2) {
            await harness.service.cancelRun(
                tabID: session.tabID,
                session: session,
                intent: .executionLocationChange,
                completion: .terminalPublished
            )
        }

        XCTAssertEqual(session.runState, .cancelled)
        XCTAssertNil(session.provider)
        XCTAssertNil(session.runID)
        XCTAssertNotNil(session.lastTerminalCommitRevision)
        try await waitUntil("Execution-location teardown should continue asynchronously") {
            recorder.contains("headless:blocking-dispose-start")
        }
        let disposeFinishedBeforeRelease = await provider.isDisposeFinished()
        XCTAssertFalse(disposeFinishedBeforeRelease)

        await provider.releaseDispose()
        try await waitUntil("Execution-location teardown should finish after release") {
            recorder.contains("headless:blocking-dispose-finish")
        }
    }

    func testCancelRunCleansClaudeAndACPProvidersAfterCommonMCPToolCancellation() async throws {
        for row in LifecycleCancellationRow.allCases {
            let recorder = LifecycleRecorder()
            let codexController = LifecycleNoopCodexController(recorder: recorder)
            let headlessProvider = LifecycleRecordingHeadlessProvider(recorder: recorder)
            let harness = makeHarness(
                recorder: recorder,
                cancelMCPTools: { _, _ in recorder.record("mcp-cancel") },
                codexController: codexController,
                headlessProviderFactory: { _, _ in headlessProvider }
            )
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            session.runState = .running
            session.runID = UUID()
            session.beginRunAttempt(source: "test")

            switch row {
            case .codex:
                session.selectedAgent = .codexExec
                session.codexController = codexController

                await harness.service.cancelRun(
                    tabID: session.tabID,
                    session: session,
                    completion: .terminalPublished
                )

                XCTAssertNil(session.codexController, row.rawValue)
                try await waitUntil("Codex teardown should complete after terminal publication") {
                    recorder.contains("codex:shutdown")
                }
                assertOrderedEvents(["mcp-cancel", "commit:", "codex:cancel", "codex:shutdown"], in: recorder, row: row.rawValue, prefixMatches: true)
            case .claudeNative:
                let controller = LifecycleFakeNativeController(
                    recorder: recorder,
                    hasTurnInFlight: false,
                    failSend: false
                )
                session.selectedAgent = .claudeCode
                session.claudeController = controller

                await harness.service.cancelRun(
                    tabID: session.tabID,
                    session: session,
                    completion: .terminalPublished
                )

                XCTAssertNil(session.claudeController, row.rawValue)
                try await waitUntil("Claude teardown should complete after terminal publication") {
                    recorder.contains("claude:shutdown")
                }
                assertOrderedEvents(["mcp-cancel", "commit:", "claude:interrupt:interrupt", "claude:shutdown"], in: recorder, row: row.rawValue, prefixMatches: true)
            case .headless:
                session.selectedAgent = .cursor
                session.provider = headlessProvider

                await harness.service.cancelRun(
                    tabID: session.tabID,
                    session: session,
                    completion: .terminalPublished
                )

                XCTAssertNil(session.provider, row.rawValue)
                try await waitUntil("Headless teardown should complete after terminal publication") {
                    recorder.contains("headless:dispose")
                }
                assertOrderedEvents(["mcp-cancel", "commit:", "headless:dispose"], in: recorder, row: row.rawValue, prefixMatches: true)
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
                        await harness.service.cancelRun(
                            tabID: session.tabID,
                            session: session,
                            completion: .terminalPublished
                        )
                    }

                    XCTAssertNil(session.acpController, row.rawValue)
                    try await waitUntil("ACP teardown should complete after terminal publication") {
                        recorder.contains("acp:session/cancel")
                    }
                    let hasReusableSession = try await withLifecycleTimeout("ACP reusable-session check") {
                        await controller.hasReusableSession
                    }
                    XCTAssertFalse(hasReusableSession, row.rawValue)
                    assertOrderedEvents(["mcp-cancel", "commit:", "acp:session/cancel"], in: recorder, row: row.rawValue, prefixMatches: true)
                }
            }

            XCTAssertEqual(session.runState, .cancelled, row.rawValue)
            XCTAssertNil(session.activeRunAttemptID, row.rawValue)
            let expectedAttachmentDisposition = row == .codex
                ? "attachments:restoreToPending"
                : "attachments:deleteFiles"
            XCTAssertTrue(recorder.contains(expectedAttachmentDisposition), row.rawValue)
        }
    }

    func testCancelRunInterruptsCapturedSessionOwnedCodexTurnByExactID() async throws {
        let recorder = LifecycleRecorder()
        let controller = LifecycleNoopCodexController(recorder: recorder)
        let harness = makeHarness(
            recorder: recorder,
            codexController: controller
        )
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        let runID = UUID()
        session.selectedAgent = .codexExec
        session.runID = runID
        session.runState = .running
        session.codexConversationID = "lifecycle"
        session.codexController = controller
        session.beginRunAttempt(source: "test.codexExactCancellation")
        session.codexAuthoritativeActiveTurn = try .init(
            threadID: "lifecycle",
            turnID: "owned-turn",
            turnKind: .user,
            controllerInstanceID: ObjectIdentifier(controller),
            controllerGeneration: session.codexControllerGeneration,
            runID: runID,
            runAttemptID: XCTUnwrap(session.activeRunAttemptID)
        )

        await harness.service.cancelRun(
            tabID: session.tabID,
            session: session,
            completion: .terminalTeardownCompleted
        )

        XCTAssertTrue(recorder.contains("codex:interrupt:owned-turn"))
        XCTAssertFalse(recorder.contains("codex:cancel"))
        XCTAssertNil(session.codexAuthoritativeActiveTurn)
        assertOrderedEvents(
            ["commit:", "codex:interrupt:owned-turn", "codex:shutdown"],
            in: recorder,
            prefixMatches: true
        )
    }

    func testOpenCodePermissionModesUseModernConfigAfterModelAndBeforePrompt() async throws {
        let rows: [(OpenCodeAgentToolPreferences.PermissionLevel, String)] = [
            (.managedDefault, OpenCodeAgentConfig.managedSessionModeID),
            (.fullAccess, OpenCodeAgentConfig.managedFullAccessSessionModeID)
        ]

        for (level, expectedMode) in rows {
            let recorder = LifecycleRecorder()
            let directory = try makeTemporaryDirectory()
            let recordURL = directory.appendingPathComponent("opencode-flow-\(level.rawValue).jsonl")
            let scriptURL = try makeOpenCodeModeFlowServerScript()
            let provider = LifecycleFakeACPProvider(
                providerID: .openCode,
                commandPath: scriptURL.path,
                environment: ["ACP_RECORD_PATH": recordURL.path]
            )
            let harness = makeHarness(
                recorder: recorder,
                workspacePathProvider: { _ in directory.path },
                acpProviderFactory: { agent, _ in
                    XCTAssertEqual(agent, .openCode)
                    return provider
                },
                autoSignalACPRouting: true
            )
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            session.selectedAgent = .openCode
            session.selectedModelRaw = "model-b"
            session.permissionProfile = .providerOverride(.openCode(level))

            let outcome = await harness.service.startRun(
                tabID: session.tabID,
                session: session,
                initialUserMessage: "OpenCode flow",
                initialMessageForRun: "OpenCode flow",
                attachments: []
            )
            XCTAssertNil(outcome, level.rawValue)
            await session.agentTask?.value

            let requests = recordedOpenCodeFlowRequests(at: recordURL)
            let relevant = requests.filter { request in
                request.method == "session/new"
                    || request.method == "session/set_config_option"
                    || request.method == "session/prompt"
            }
            XCTAssertEqual(
                relevant.map(\.method),
                ["session/new", "session/set_config_option", "session/set_config_option", "session/prompt"],
                level.rawValue
            )
            XCTAssertEqual(relevant[1].params["configId"] as? String, "model", level.rawValue)
            XCTAssertEqual(relevant[1].params["value"] as? String, "model-b", level.rawValue)
            XCTAssertEqual(relevant[2].params["configId"] as? String, "mode", level.rawValue)
            XCTAssertEqual(relevant[2].params["value"] as? String, expectedMode, level.rawValue)
            XCTAssertFalse(session.items.contains { $0.kind == .error }, level.rawValue)

            await harness.service.cancelRun(tabID: session.tabID, session: session)
        }
    }

    private struct RecordedOpenCodeFlowRequest {
        let method: String
        let params: [String: Any]
    }

    private func recordedOpenCodeFlowRequests(at url: URL) -> [RecordedOpenCodeFlowRequest] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(whereSeparator: { $0.isNewline }).compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String
            else { return nil }
            return RecordedOpenCodeFlowRequest(
                method: method,
                params: object["params"] as? [String: Any] ?? [:]
            )
        }
    }

    func makeHarness(
        recorder: LifecycleRecorder,
        workspacePathProvider: @escaping (AgentModeViewModel.TabSession) throws -> String? = { _ in FileManager.default.currentDirectoryPath },
        idleWaiter: @escaping LifecycleMCPIdleWaiter = { _ in },
        cancelMCPTools: @escaping (_ runID: UUID, _ reason: String) -> Void = { _, _ in },
        codexController: LifecycleNoopCodexController? = nil,
        claudeController: LifecycleFakeNativeController? = nil,
        claudeControllerFactory: ClaudeAgentModeCoordinator.ClaudeControllerFactory? = nil,
        headlessProviderFactory: AgentModeViewModel.HeadlessProviderFactory? = nil,
        acpProviderFactory: AgentModeViewModel.ACPProviderFactory? = nil,
        acpControllerFactory: AgentModeViewModel.ACPControllerFactory? = nil,
        flushPendingAssistantDelta: ((AgentModeViewModel.TabSession) -> Void)? = nil,
        publishTerminalCommit: ((AgentModeViewModel.TabSession, AgentRunTerminalCommitRevision) async -> Void)? = nil,
        autoSignalACPRouting: Bool = false
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
        let baseACPControllerFactory = acpControllerFactory ?? { provider, request in
            recorder.record("factory:acp-controller")
            return try ACPAgentSessionController(provider: provider, runRequest: request)
        }
        let trackedACPControllerFactory: AgentModeViewModel.ACPControllerFactory = { [weak self] provider, request in
            let controller = try baseACPControllerFactory(provider, request)
            self?.registerACPController(controller)
            return controller
        }
        let policyInstaller: AgentModeViewModel.ConnectionPolicyInstaller = { clientName, _, _, _, _, _, _, runID, _, _, _, _, _ in
            recorder.record("policy:\(clientName):\(runID?.uuidString ?? "nil")")
            if autoSignalACPRouting, let runID {
                await MCPRoutingWaiter.notifyRouted(runID: runID)
            }
        }
        let serverEnabler: AgentModeViewModel.MCPServerEnabler = {}
        let host = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in codexController },
            claudeControllerFactory: claudeControllerFactory ?? { _, _, _, _ in
                recorder.record("factory:claude")
                return claudeController
            },
            headlessProviderFactory: headlessProviderFactory,
            acpProviderFactory: acpProviderFactory,
            acpControllerFactory: trackedACPControllerFactory,
            connectionPolicyInstaller: policyInstaller,
            mcpServerEnabler: serverEnabler
        )
        lifecycleHosts.append(host)
        let dependencies = AgentModeRunService.Dependencies(
            windowID: 1,
            headlessProviderFactory: headlessProviderFactory,
            acpProviderFactory: acpProviderFactory,
            acpControllerFactory: trackedACPControllerFactory,
            connectionPolicyInstaller: policyInstaller,
            expectedPIDPolicyArmer: { _ in true },
            mcpServerEnabler: serverEnabler,
            workspacePathProvider: workspacePathProvider,
            codexCoordinator: host.test_codexCoordinator,
            claudeCoordinator: host.claudeCoordinator,
            shouldManageCodexTooling: false,
            providerRuntimePermissionResolver: { [bindingService = host.providerBindingService] agent, profile in
                bindingService.runtimePermission(for: agent, profile: profile)
            },
            bindPendingOracleReviewContext: { _, _ in },
            cancelMCPToolsForRun: cancelMCPTools,
            awaitNoActiveMCPTools: idleWaiter,
            activeAgentRunWaitQuery: { _ in false },
            childAgentRunWaitDrainTimeoutSeconds: 0.01
        )
        return LifecycleHarness(
            service: AgentModeRunService(
                dependencies: dependencies,
                hooks: makeHooks(
                    recorder: recorder,
                    flushPendingAssistantDelta: flushPendingAssistantDelta,
                    publishTerminalCommit: publishTerminalCommit
                ),
                toolTrackingHooks: .noOp
            ),
            host: host
        )
    }

    private func makeHooks(
        recorder: LifecycleRecorder,
        flushPendingAssistantDelta: ((AgentModeViewModel.TabSession) -> Void)? = nil,
        publishTerminalCommit: ((AgentModeViewModel.TabSession, AgentRunTerminalCommitRevision) async -> Void)? = nil,
        publishTerminalCommitResult: ((
            AgentModeViewModel.TabSession,
            AgentRunTerminalCommitRevision,
            AgentRunEpochTransitionKind?
        ) async -> AgentRunTerminalPublicationResult)? = nil,
        makeTerminalPublicationEnvelope: ((
            AgentModeViewModel.TabSession,
            AgentRunOwnership,
            AgentSessionRunState,
            UUID?
        ) -> AgentRunTerminalPublicationEnvelope?)? = nil,
        startFollowUpRun: ((UUID, String) -> Void)? = nil
    ) -> AgentModeRunService.Hooks {
        let flushPendingAssistantDelta = flushPendingAssistantDelta ?? { _ in
            recorder.record("assistant-flush")
        }
        let publishTerminalCommit = publishTerminalCommit ?? { _, revision in
            recorder.record("commit:\(revision.commitID.uuidString)")
        }
        return AgentModeRunService.Hooks(
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
            flushPendingAssistantDelta: flushPendingAssistantDelta,
            clearPendingAssistantDelta: { _ in },
            prepareTerminalPublication: { _ in recorder.record("prepare-publication") },
            makeTerminalPublicationEnvelope: makeTerminalPublicationEnvelope ?? { _, _, _, _ in nil },
            publishTerminalCommit: { session, revision, successorKind in
                if let publishTerminalCommitResult {
                    return await publishTerminalCommitResult(session, revision, successorKind)
                }
                await publishTerminalCommit(session, revision)
                return .accepted(successorEpoch: nil)
            },
            startFollowUpRun: startFollowUpRun ?? { _, _ in },
            restoreDraftText: { _, text, _, _ in recorder.record("draft:\(text)") },
            augmentUserMessageForProviderSend: { text, _, _, _ in text },
            stageResumeRecoveryHandoffIfNeeded: { _ in },
            prependPendingHandoffIfNeeded: { text, _ in text },
            recordPendingHandoffSendOutcome: { _, didSend in recorder.record("handoff:\(didSend)") },
            signalMCPInstructionDelivered: { _ in recorder.record("delivered") }
        )
    }

    func makeRunningClaudeSession(controller: LifecycleFakeNativeController) -> AgentModeViewModel.TabSession {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.runState = .running
        session.runID = UUID()
        session.beginRunAttempt(source: "test")
        session.claudeController = controller
        return session
    }

    func makeClaudeSteeringInstruction(
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
        let controller = try ACPAgentSessionController(
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
        registerACPController(controller)
        return controller
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentModeRunServiceLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private func makeOpenCodeModeFlowServerScript() throws -> URL {
        let directory = try makeTemporaryDirectory()
        let scriptURL = directory.appendingPathComponent("fake_opencode_mode_flow_server.py")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import os
        import sys

        record_path = os.environ.get("ACP_RECORD_PATH")
        pid_path = os.environ.get("ACP_PID_PATH")
        current_model = "model-a"
        current_mode = "ask"

        if pid_path:
            with open(pid_path, "w", encoding="utf-8") as handle:
                handle.write(str(os.getpid()))

        def record(method, params):
            if not record_path:
                return
            with open(record_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"method": method, "params": params}) + "\n")

        def config_options():
            return [
                {
                    "id": "model",
                    "name": "Model",
                    "category": "model",
                    "type": "select",
                    "currentValue": current_model,
                    "options": [
                        {"value": "model-a", "name": "Model A"},
                        {"value": "model-b", "name": "Model B"}
                    ]
                },
                {
                    "id": "mode",
                    "name": "Session Mode",
                    "category": "mode",
                    "type": "select",
                    "currentValue": current_mode,
                    "options": [
                        {"value": "ask", "name": "Ask"},
                        {"value": "repoprompt_acp", "name": "RepoPrompt"},
                        {"value": "repoprompt_acp_full_access", "name": "RepoPrompt Full Access"}
                    ]
                }
            ]

        def respond(request_id, result=None):
            print(json.dumps({
                "jsonrpc": "2.0",
                "id": request_id,
                "result": result if result is not None else {}
            }), flush=True)

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            method = request.get("method")
            params = request.get("params") or {}
            record(method, params)
            if method == "initialize":
                respond(request.get("id"), {"agentCapabilities": {"loadSession": True}, "authMethods": []})
            elif method == "session/new":
                respond(request.get("id"), {
                    "sessionId": "opencode-mode-flow",
                    "configOptions": config_options()
                })
            elif method == "session/set_config_option":
                if params.get("configId") == "model":
                    current_model = params.get("value")
                elif params.get("configId") == "mode":
                    current_mode = params.get("value")
                respond(request.get("id"), {"configOptions": config_options()})
            elif method == "session/prompt":
                respond(request.get("id"), {
                    "stopReason": "end_turn",
                    "usage": {"inputTokens": 1, "outputTokens": 1}
                })
            else:
                respond(request.get("id"), {})
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
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
        acpControllers.removeValue(forKey: ObjectIdentifier(controller))
    }

    private func shutdownACPControllerAfterFailure(_ controller: ACPAgentSessionController) async {
        do {
            try await shutdownACPController(controller)
        } catch {
            XCTFail("ACP controller cleanup failed: \(error.localizedDescription)")
        }
    }

    private func registerACPController(_ controller: ACPAgentSessionController) {
        acpControllers[ObjectIdentifier(controller)] = controller
    }

    private func cleanupRegisteredRuntime() async {
        let hosts = lifecycleHosts.reversed()
        lifecycleHosts.removeAll()
        for host in hosts {
            await host.prepareForWindowClose()
        }

        let controllers = Array(acpControllers.values)
        acpControllers.removeAll()
        for controller in controllers {
            await controller.shutdown()
        }
    }

    private nonisolated static func processIsRunning(_ processID: pid_t) -> Bool {
        if kill(processID, 0) == 0 {
            return true
        }
        return errno == EPERM
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

    func assertOrderedEvents(
        _ expected: [String],
        in recorder: LifecycleRecorder,
        afterFirstMatchOf marker: String? = nil,
        row: String? = nil,
        prefixMatches: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let events = recorder.events
        var cursor = marker.flatMap { events.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        for event in expected {
            let index = events[cursor...].firstIndex { candidate in
                prefixMatches ? candidate.hasPrefix(event) : candidate == event
            }
            guard let index else {
                XCTFail("Missing ordered event \(event) for \(row ?? "row"). Events: \(events)", file: file, line: line)
                return
            }
            cursor = index + 1
        }
    }
}

typealias LifecycleMCPIdleWaiter = (_ runID: UUID) async throws -> Void

private struct LifecycleTimeoutError: LocalizedError {
    let operation: String
    let timeoutSeconds: TimeInterval

    var errorDescription: String? {
        "Lifecycle test timed out waiting for \(operation) after \(timeoutSeconds)s."
    }
}

private actor LifecyclePublicationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
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

struct LifecycleHarness {
    let service: AgentModeRunService
    let host: AgentModeViewModel
}

private enum LifecycleCancellationRow: String, CaseIterable {
    case codex
    case claudeNative
    case headless
    case acp
}

enum LifecycleTestError: LocalizedError {
    case workspaceMissing
    case expectedACPDispatchStop
    case unexpectedACPControllerCreation
    case expectedClaudeSendFailure
    case expectedCodexSendFailure

    var errorDescription: String? {
        switch self {
        case .workspaceMissing:
            "Lifecycle test workspace is missing."
        case .expectedACPDispatchStop:
            "Expected ACP dispatch stop."
        case .unexpectedACPControllerCreation:
            "ACP controller creation was not expected."
        case .expectedClaudeSendFailure:
            "Expected Claude send failure."
        case .expectedCodexSendFailure:
            "Expected Codex send failure."
        }
    }
}

final class LifecycleRecorder: @unchecked Sendable {
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

private actor LifecycleBlockingHeadlessProvider: HeadlessAgentProvider {
    private let recorder: LifecycleRecorder
    private var disposeContinuation: CheckedContinuation<Void, Never>?
    private var disposeFinished = false

    init(recorder: LifecycleRecorder) {
        self.recorder = recorder
    }

    func streamAgentMessage(_ message: AgentMessage, runID: UUID?) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func dispose() async {
        recorder.record("headless:blocking-dispose-start")
        await withCheckedContinuation { continuation in
            disposeContinuation = continuation
        }
        disposeFinished = true
        recorder.record("headless:blocking-dispose-finish")
    }

    func isDisposeFinished() -> Bool {
        disposeFinished
    }

    func releaseDispose() {
        disposeContinuation?.resume()
        disposeContinuation = nil
    }
}

private final class LifecycleRecordingHeadlessProvider: HeadlessAgentProvider {
    private let recorder: LifecycleRecorder

    init(recorder: LifecycleRecorder) {
        self.recorder = recorder
    }

    func streamAgentMessage(_ message: AgentMessage, runID: UUID?) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func dispose() async {
        recorder.record("headless:dispose")
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

final class LifecycleNoopCodexController: CodexSessionControlling {
    enum SendBehavior: CustomStringConvertible {
        case success
        case failure
        case cancellation

        var description: String {
            switch self {
            case .success: "success"
            case .failure: "failure"
            case .cancellation: "cancellation"
            }
        }
    }

    private let recorder: LifecycleRecorder
    private let sendBehavior: SendBehavior
    private let activatesThread: Bool
    private(set) var hasActiveThread = false

    init(recorder: LifecycleRecorder, failSend: Bool = false) {
        self.recorder = recorder
        sendBehavior = failSend ? .failure : .success
        activatesThread = true
    }

    init(recorder: LifecycleRecorder, sendBehavior: SendBehavior, activatesThread: Bool) {
        self.recorder = recorder
        self.sendBehavior = sendBehavior
        self.activatesThread = activatesThread
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { _ in }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String) async throws -> CodexNativeSessionController.SessionRef {
        hasActiveThread = activatesThread
        return CodexNativeSessionController.SessionRef(conversationID: "lifecycle", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?) async throws -> CodexNativeSessionController.SessionRef {
        hasActiveThread = activatesThread
        return CodexNativeSessionController.SessionRef(conversationID: "lifecycle", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexNativeSessionController.SessionRef {
        hasActiveThread = activatesThread
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
    func startUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexTurnStartReceipt {
        try recordCodexSend()
        return CodexTurnStartReceipt(provisionalSubmissionID: "lifecycle-submission")
    }

    func steerUserTurn(text: String, images: [AgentImageAttachment], expectedTurnID: String) async throws -> CodexTurnSteerReceipt {
        try recordCodexSend()
        return CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        recorder.record("codex:interrupt:\(expectedTurnID)")
        return CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
    }

    private func recordCodexSend() throws {
        recorder.record("codex:send")
        switch sendBehavior {
        case .success:
            return
        case .failure:
            throw LifecycleTestError.expectedCodexSendFailure
        case .cancellation:
            throw CancellationError()
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

private struct LifecycleFakeACPProvider: ACPAgentProvider {
    let providerID: ACPProviderID
    let commandPath: String
    var environment: [String: String] = [:]
    var supportResult: ACPSupportResult = .supported
    var cancelSupport = false
    var recorder: LifecycleRecorder?

    func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
        recorder?.record("provider:support")
        if cancelSupport {
            throw CancellationError()
        }
        return supportResult
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        ACPLaunchConfiguration(
            providerID: providerID,
            command: commandPath,
            arguments: [],
            environment: environment,
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
