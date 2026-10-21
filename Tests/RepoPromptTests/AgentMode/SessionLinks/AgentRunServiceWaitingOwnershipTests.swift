import Foundation
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class AgentRunServiceWaitingOwnershipTests: XCTestCase {
    func testServiceStartedTurnsKeepWaitingSteerCurrentAfterRestoreAndProviderInit() async throws {
        for agent in [AgentProviderKind.codexExec, .claudeCode, .openCode] {
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
                _ = await harness.service.startRun(tabID: tabID, session: session, initialUserMessage: "turn \(turn)", initialMessageForRun: "turn \(turn)", attachments: [])
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
                    codex.emit(.turnStarted(turnID: "turn-\(turn)"))
                }
                XCTAssertEqual(session.currentRestorationBindingToken, binding)
                if turn == 2 {
                    host.storeDraftText(for: tabID, "untouched local draft")
                    let waiting = Task { @MainActor in try await host.waitForNextUserInstruction(tabID: tabID, prompt: "Next?", timeoutSeconds: 10) }
                    try await AsyncTestWait.waitUntil("real instruction wait is parked") { session.instructionContinuation != nil }
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
                    XCTAssertEqual(host.retrieveDraftText(for: tabID), "untouched local draft")
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
