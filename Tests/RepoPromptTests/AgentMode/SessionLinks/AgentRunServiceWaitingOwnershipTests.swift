import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class AgentRunServiceWaitingOwnershipTests: XCTestCase {
    func testServiceStartedTurnsKeepWaitingSteerCurrentAfterRestoreAndProviderInit() async throws {
        try await assertWaitingSteer(agents: [.codexExec, .claudeCode, .openCode])
    }

    func testLateCodexTurnStartedPreservesParkedInstructionWait() async throws {
        try await assertWaitingSteer(agents: [.codexExec], delayCodexTurnStarted: true)
    }

    func testInstructionTimeoutClaimsOwnedAndUnownedWaitsBeforeTerminalJoin() async throws {
        for mode in ["unownedTimer", "owned", "terminalInProgress"] {
            let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
            let host = harness.host
            let tabID = UUID()
            let workspace = AgentSessionLinkEndpointTestSupport.installWorkspace(on: host, tabID: tabID, name: "Instruction timeout")
            let session = host.session(for: tabID)
            _ = try XCTUnwrap(host.test_installPersistentSessionBinding(sessionID: UUID(), on: session, updateWorkspaceMetadata: true))
            session.hasLoadedPersistedState = true
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            session.selectedAgent = .openCode
            let execution = host.test_initializeRunService()
            if mode != "unownedTimer" {
                session.installRunID(UUID())
                _ = session.beginRunAttempt(source: "instruction timeout fixture")
            } else {
                XCTAssertNil(session.activeRunOwnership)
                XCTAssertNil(session.runID)
            }
            let runtime = host.linkExecutionRuntime
            let command = try XCTUnwrap(runtime.instructionCommand(for: session))
            let scope = command.writer.scope
            // This fixture exercises the instruction/terminal owners, not the independent
            // approval-store snapshot projection, which can reconcile an otherwise empty wait.
            await scope.installedInteractions?.teardownApprovalSync(for: session, cleanupScope: false)
            let waitID = UUID()
            let installed = expectation(description: "timeout wait installed")
            let attachment = scope.presentation.attach(session, sink: .init(
                activityChanged: { _, _ in }, refresh: { _, _, _ in }, turnComplete: { _ in }, turnFailed: { _, _ in },
                binding: { _ in if session.instructionWaitID == waitID { installed.fulfill() } }
            ))
            let committing = mode == "terminalInProgress" ? nil : expectation(description: "timeout owns terminal cancellation")
            var release: CheckedContinuation<Void, Never>?
            var cancellationCommits = 0
            execution.testBeforeCancellationCommit = { current in
                XCTAssertTrue(current === session)
                XCTAssertNil(current.instructionWait)
                cancellationCommits += 1
                guard let committing else { return }
                await withCheckedContinuation { continuation in
                    release = continuation
                    committing.fulfill()
                }
            }
            var returned = false
            let waiting = Task {
                let response = try await runtime.waitForInstruction(
                    command: command, waitID: waitID, prompt: "Next?",
                    timeoutSeconds: mode == "unownedTimer" ? 0.001 : nil
                )
                returned = true
                return response
            }
            defer {
                release?.resume()
                execution.testBeforeCancellationCommit = nil
                AgentSessionInteractionRuntime.cancelPendingInstruction(for: session)
                waiting.cancel()
                session.saveDebounceTask?.cancel()
            }
            await fulfillment(of: [installed], timeout: 3)
            scope.presentation.detach(attachment)
            if mode == "terminalInProgress" {
                XCTAssertTrue(session.runLifecycle.beginTerminalCommit())
                let ownership = session.activeRunOwnership
                await runtime.expireInstructionWait(session: session, waitID: waitID, timeout: 2)
                let response = try await waiting.value
                XCTAssertTrue(response.timedOut)
                XCTAssertEqual(cancellationCommits, 0)
                XCTAssertEqual(session.activeRunOwnership, ownership)
                XCTAssertTrue(session.terminalCommitInProgress)
                XCTAssertEqual(session.runState, .waitingForUser, "The in-flight terminal owner owns its state transition")
                session.runLifecycle.completeTerminalCommit()
            } else {
                let expiry = mode == "owned" ? Task { await runtime.expireInstructionWait(session: session, waitID: waitID, timeout: 2) } : nil
                try await fulfillment(of: [XCTUnwrap(committing)], timeout: 3)
                XCTAssertFalse(returned, "Timeout response must join terminal publication")
                XCTAssertEqual(cancellationCommits, 1)
                // The ordinary explicit-Stop preparation cannot resume a wait already taken by
                // the timeout's cancellation claim, even while its terminal publication is held.
                host.prepareAgentRunCancellation(session: session, intent: .userStop, origin: .explicitStop)
                XCTAssertFalse(returned)
                release?.resume()
                release = nil
                await expiry?.value
                let response = try await waiting.value
                XCTAssertTrue(response.timedOut)
                XCTAssertEqual(response.elapsedSeconds, mode == "owned" ? 2 : 0)
                XCTAssertEqual(session.runState, .cancelled)
                XCTAssertNotNil(session.lastTerminalCommitRevision)
                await runtime.expireInstructionWait(session: session, waitID: waitID, timeout: 2)
                XCTAssertEqual(cancellationCommits, 1, "A late timeout cannot cancel again")
            }
            withExtendedLifetime(workspace) {}
        }
    }

    private func assertWaitingSteer(agents: [AgentProviderKind], delayCodexTurnStarted: Bool = false) async throws {
        for agent in agents {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WaitingOwner-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let gate = try AgentSessionLinkACPResponseGate(directory: directory)
            defer { gate.release() }
            let provider = try AgentSessionLinkCapturingACPProvider(providerID: .openCode, commandPath: AgentSessionLinkACPServerScript.write(to: directory).path, environment: [
                "ACP_HOLD_METHOD": "session/prompt", "ACP_RESPONSE_GATE": gate.path
            ])
            let codex = MonitorFakeCodexController(dispatches: MonitorCodexDispatchRecorder())
            let claude = MonitorFakeNativeController()
            let harness = AgentSessionLinkRunnerHarness(
                headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() },
                acpProviderFactory: { _, _ in provider }, workspacePath: directory.path,
                codexController: codex, claudeControllerFactory: { _, _, _, _ in claude }
            )
            let host = harness.host
            let tabID = UUID()
            let workspace = AgentSessionLinkEndpointTestSupport.installWorkspace(on: host, tabID: tabID, name: "Waiting ownership")
            let session = host.session(for: tabID)
            addTeardownBlock { @MainActor in
                host.prepareAgentRunCancellation(session: session, intent: .userStop, origin: .internalLifecycle)
                await session.acpController?.shutdown()
                await session.claudeController?.shutdown()
                await session.codexController?.shutdown()
                await session.agentTask?.value
                session.saveDebounceTask?.cancel()
            }
            session.selectedAgent = agent
            _ = try XCTUnwrap(host.test_installPersistentSessionBinding(sessionID: UUID(), on: session, updateWorkspaceMetadata: true))
            session.hasLoadedPersistedState = true
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            XCTAssertNil(session.runID)
            XCTAssertNil(session.activeRunOwnership)
            let binding = session.currentRestorationBindingToken
            for turn in 1 ... 2 {
                _ = try await harness.composition.startRun(tabID: tabID, session: session, origin: harness.startCommand(for: session), initialUserMessage: "turn \(turn)", initialMessageForRun: "turn \(turn)", attachments: [])
                let owner = try XCTUnwrap(session.activeRunOwnership, "\(agent) turn \(turn)")
                XCTAssertTrue(session.isCurrentRunAttemptForCurrentBinding(owner))
                XCTAssertTrue(session.quietLedger.isOpen(owner: owner))
                if agent == .claudeCode {
                    try await AsyncTestWait.waitUntil("Claude sends through the real runner") { await claude.sentCount == turn }
                    XCTAssertEqual(session.providerSessionID, "monitor-native-session")
                } else if agent == .openCode {
                    try await AsyncTestWait.waitUntil("ACP sends through session/new and prompt") { provider.promptedMessages.count == turn }
                    XCTAssertNotNil(session.providerSessionID)
                } else {
                    XCTAssertEqual(codex.startedTurns.count, turn)
                    XCTAssertEqual(session.codexConversationID, "monitor-thread")
                    if !delayCodexTurnStarted || turn == 1 {
                        codex.emit(.turnStarted(turnID: "turn-\(turn)"))
                        try await AsyncTestWait.waitUntil("Codex turnStarted is applied") {
                            session.codexAuthoritativeActiveTurn?.turnID == "turn-\(turn)"
                                && session.runState == .running
                        }
                    }
                }
                XCTAssertEqual(session.currentRestorationBindingToken, binding)
                if turn == 2 {
                    host.storeDraftText(for: tabID, "untouched local draft")
                    let waiting = Task { @MainActor in try await host.waitForNextUserInstruction(tabID: tabID, prompt: "Next?", timeoutSeconds: 10) }
                    try await AsyncTestWait.waitUntil("real instruction wait is parked") {
                        host.agentSessionLinkManagedSteerRoute(for: session) == .waitingInstruction
                    }
                    if delayCodexTurnStarted {
                        // Apply the first start notification only after the MCP wait has parked.
                        // Await the handler itself, so a route assertion cannot pass before ingress.
                        await host.test_codexCoordinator.test_handleCodexNativeEvent(
                            .turnStarted(turnID: "turn-\(turn)"), session: session, sourceController: codex
                        )
                        XCTAssertEqual(session.codexAuthoritativeActiveTurn?.turnID, "turn-\(turn)")
                        XCTAssertEqual(session.runState, .waitingForUser)
                        XCTAssertEqual(host.agentSessionLinkManagedSteerRoute(for: session), .waitingInstruction)
                    }
                    XCTAssertTrue(session.isCurrentRunAttemptForCurrentBinding(owner))
                    XCTAssertTrue(session.quietLedger.isOpen(owner: owner))
                    let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(host, tabID: tabID)
                    let sink = AgentSessionLinkManagedSteerSink()
                    let frame = AgentModeViewModel.mcpResidentTaskFrame("next instruction")
                    let input = AgentNoncomposerTurn(endpoint: endpoint, providerText: frame, sink: sink)
                    XCTAssertTrue(host.submitNoncomposerSteer(tabID: tabID, session: session, displayText: frame, turn: input, route: .waitingInstruction))
                    let outcome = await sink.awaitOutcome(timeoutSeconds: 10)
                    guard case .delivered(.deliveredToWaitingInstruction) = outcome else { return XCTFail("\(agent): \(outcome)") }
                    let response = try await waiting.value
                    XCTAssertEqual(response.text, frame)
                    XCTAssertFalse(response.timedOut)
                    XCTAssertEqual(host.draftRuntime.text(for: tabID), "untouched local draft")
                    XCTAssertEqual(session.items.count(where: { $0.kind == .user && $0.text == frame }), 1)
                    XCTAssertNil(session.instructionContinuation)
                    XCTAssertEqual(session.activeRunOwnership, owner)
                }
                if agent == .claudeCode {
                    try await claude.emit(.turnCompleted(turnID: XCTUnwrap(session.claudeExpectedTurnIDs.first), status: .completed))
                } else if agent == .openCode {
                    if turn == 1 { gate.release() }
                    else {
                        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: gate.path))
                        try handle.write(contentsOf: Data([1]))
                        try handle.close()
                    }
                } else { codex.emit(.turnCompleted(turnID: "turn-\(turn)", status: .completed)) }
                try await AsyncTestWait.waitUntil("real terminal completion (\(agent))", timeout: 10) { session.runState == .completed && session.activeRunOwnership == nil }
                await session.agentTask?.value
                XCTAssertNotNil(session.runLifecycle.lastTerminalCommitRevision)
            }
            withExtendedLifetime(workspace) {}
        }
    }
}
