#if DEBUG
    import Foundation
    import MCP
    import RepoPromptSettingsCore
    import XCTest
    @_spi(TestSupport) @testable import RepoPromptApp

    /// W0(a), not tool registration/certification. No tool receives a quiet exemption here.
    /// Candidate eligibility isolates correlation vetoes; it does not certify these ordinary tools.
    @MainActor
    final class AgentQuietInvocationFeasibilityTests: XCTestCase {
        private func fixture(_ agent: AgentProviderKind = .claudeCode, routine: Bool = true) -> (AgentSessionLinkRunnerHarness, AgentTabSession, AgentRunOwnership) {
            let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
            let session = harness.makeSession(agent: agent)
            session.installRunID(UUID())
            session.runState = .running
            let owner = session.beginRunAttempt(source: "W0-invocation-feasibility")
            if routine { session.quietLedger.markRoutineWake(owner: owner, wakeID: UUID()) }
            return (harness, session, owner)
        }

        func testClaudeNilIDSignatureAndNameJoinsVetoBeforeUUIDAssignmentAndStayOrdinaryAfterExactResult() throws {
            for argsJSON in [#"{"path":"a"}"#, #"{"path":"other"}"#] {
                let (harness, session, owner) = fixture()
                _ = harness
                let handler = ClaudeAgentToolTrackingHandler()
                handler.handleClaudeProviderRepoPromptToolCall(invocationID: nil, toolName: "mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__read_file", argsJSON: argsJSON, session: session)
                let rowID = try XCTUnwrap(session.items.first?.id)
                XCTAssertNotNil(session.quietLedger.candidateStartKey(owner: owner), "Unjoined representation is provisional only in this W0 injection")
                let hostID = UUID()
                var sawAssignment = false
                session.onSourceItemsChanged = { observed, _ in
                    if observed.items.first?.toolInvocationID == hostID {
                        sawAssignment = true
                        XCTAssertNil(observed.quietLedger.candidateStartKey(owner: owner), "Veto must precede publishing a borrowed host UUID")
                    }
                }
                handler.handleTrackerToolCall(invocationID: hostID, toolName: "read_file", args: ["path": .string("a")], session: session)
                XCTAssertTrue(sawAssignment)
                handler.handleTrackerToolResult(invocationID: hostID, toolName: "read_file", args: nil, resultJSON: #"{"result":"done"}"#, isError: false, session: session)
                XCTAssertEqual(session.items.map(\.id), [rowID])
                XCTAssertEqual(session.items.first?.toolInvocationID, hostID, "UUID equality at seal would incorrectly approve this heuristic join")
                XCTAssertEqual(session.items.first?.kind, .toolResult)
                XCTAssertNil(session.quietLedger.candidateStartKey(owner: owner), "Later exact merge cannot erase provenance loss")
            }
        }

        func testClaudeProviderFirstAndTrackerFirstDifferentIdentityJoinsAreIrreversible() {
            for providerFirst in [true, false] {
                let (harness, session, owner) = fixture()
                _ = harness
                let handler = ClaudeAgentToolTrackingHandler()
                let hostID = UUID()
                let providerID = UUID()
                func provider() {
                    handler.handleClaudeProviderRepoPromptToolCall(invocationID: providerID, toolName: "mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__read_file", argsJSON: #"{"path":"a"}"#, session: session)
                }
                if providerFirst { provider() }
                handler.handleTrackerToolCall(invocationID: hostID, toolName: "read_file", args: ["path": .string("a")], session: session)
                if !providerFirst {
                    XCTAssertNotNil(session.quietLedger.candidateStartKey(owner: owner))
                    provider()
                }
                XCTAssertNil(session.quietLedger.candidateStartKey(owner: owner))
                handler.handleTrackerToolResult(invocationID: hostID, toolName: "read_file", args: nil, resultJSON: "{}", isError: false, session: session)
                XCTAssertEqual(session.items.count, 1)
                XCTAssertEqual(session.items.first?.toolInvocationID, providerID, "Signature mapping is not a host identity join")
                XCTAssertNil(session.quietLedger.candidateStartKey(owner: owner))
            }
        }

        func testClaudeAmbiguousNilIDRepresentationsCannotQualifyAfterCanonicalDeduplication() {
            let (harness, session, owner) = fixture()
            _ = harness
            let handler = ClaudeAgentToolTrackingHandler()
            // Separate provider slots can already exist before the tracker callback arrives.
            for _ in 0 ..< 2 {
                session.appendItem(.toolCall(name: "read_file", argsJSON: "{}", sequenceIndex: session.nextSequenceIndex))
            }
            handler.handleTrackerToolCall(invocationID: UUID(), toolName: "read_file", args: [:], session: session)
            XCTAssertNil(session.quietLedger.candidateStartKey(owner: owner))
            XCTAssertEqual(session.items.count, 2)
        }

        func testClaudeTrackerOnlyHostIdentityIsPreservedByExactCompletion() throws {
            let (harness, session, owner) = fixture()
            _ = harness
            let handler = ClaudeAgentToolTrackingHandler()
            let hostID = UUID()
            handler.handleTrackerToolCall(invocationID: hostID, toolName: "read_file", args: [:], session: session)
            handler.handleTrackerToolResult(invocationID: hostID, toolName: "read_file", args: nil, resultJSON: "{}", isError: false, session: session)
            XCTAssertEqual(session.items.count, 1)
            XCTAssertEqual(session.items.first?.toolInvocationID, hostID)
            XCTAssertNotNil(session.quietLedger.candidateStartKey(owner: owner), "Only this injected tracker-only correlation has positive host identity")
            let canonical = try XCTUnwrap(AgentTranscriptToolNormalizer.toolExecution(for: session.items[0]))
            XCTAssertEqual(canonical.invocationID, hostID)
        }

        func testClaudeNativeErrorWithoutHostCompletionKeepsOrdinaryResultVisible() async throws {
            for routine in [false, true] {
                let (harness, session, _) = fixture(routine: routine)
                _ = harness
                let handler = ClaudeAgentToolTrackingHandler()
                try await handler.startTracking(runID: XCTUnwrap(session.runID), session: session, clientNameHint: nil)
                let providerID = UUID()
                let name = "mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__read_file"
                XCTAssertTrue(handler.handleProviderToolEvent(.toolCall(.init(
                    toolName: name, invocationID: providerID, argsJSON: "{}", claudeToolUseID: "toolu_denied"
                )), session: session))
                XCTAssertTrue(handler.handleProviderToolEvent(.toolResult(.init(
                    toolName: name, invocationID: providerID, argsJSON: "{}", resultJSON: "Permission denied",
                    isError: true, claudeToolUseID: "toolu_denied"
                )), session: session))
                XCTAssertEqual(session.items.count, 1)
                XCTAssertEqual(session.items.first?.kind, .toolResult)
                XCTAssertEqual(session.items.first?.toolResultJSON, "Permission denied")
                XCTAssertEqual(session.items.first?.toolIsError, true)
                await handler.stopTracking(for: session)
            }
        }

        func testCodexHostIdentitySurvivesNativeEchoWhileOrdinaryToolLivenessStillVetoes() async {
            for exact in [true, false] {
                let (harness, session, owner) = fixture(.codexExec)
                let coordinator = harness.host.test_codexCoordinator
                let hostID: UUID? = exact ? UUID() : nil
                coordinator.testSimulateRepoPromptToolCall(invocationID: hostID, toolName: "read_file", args: [:], session: session)
                coordinator.testSimulateRepoPromptToolResult(invocationID: hostID, toolName: "read_file", args: [:], resultJSON: "{}", isError: false, session: session)
                XCTAssertEqual(session.items.count, 1)
                XCTAssertEqual(session.items.first?.toolInvocationID, hostID)
                XCTAssertEqual(session.quietLedger.candidateStartKey(owner: owner) != nil, exact)
                // Actual native event ingress suppresses explicit host-tool echoes, not their IDs.
                await coordinator.test_handleCodexNativeEvent(.toolCall(name: "mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__read_file", invocationID: UUID(), argsJSON: "{}"), session: session)
                XCTAssertEqual(session.items.count, 1)
                XCTAssertEqual(session.items.first?.toolInvocationID, hostID)
                XCTAssertNil(session.quietLedger.candidateStartKey(owner: owner), "This ordinary tool still records liveness and vetoes at native ingress; no declaration exemption was installed")
            }
        }

        func testACPTrackerIdentityAndProviderFallbackDoNotExpandUnsupportedPolicy() {
            let (harness, session, owner) = fixture(.devin)
            let runner = ACPIntegratedAgentModeRunner(hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier(), toolTrackingHooks: .noOp, providerFactory: { _, _ in nil }, controllerFactory: { provider, request in try ACPAgentSessionController(provider: provider, runRequest: request) })
            XCTAssertFalse(AgentSessionLinkPrompts.supportsQuietCheckIn(.devin))
            XCTAssertNil(session.quietLedger.candidateStartKey(owner: owner))
            session.quietLedger = AgentRunQuietLedger()
            session.quietLedger.begin(owner: owner, startKey: session.nextSequenceIndex, provider: .codexExec)
            session.quietLedger.markRoutineWake(owner: owner, wakeID: UUID())
            let hostID = UUID()
            runner.testHandleTrackerToolCall(invocationID: hostID, toolName: "read_file", args: [:], session: session)
            runner.testHandleTrackerToolResult(invocationID: hostID, toolName: "read_file", args: nil, resultJSON: "{}", isError: false, session: session)
            XCTAssertEqual(session.items.first?.toolInvocationID, hostID)
            XCTAssertNotNil(session.quietLedger.candidateStartKey(owner: owner), "W0-only injected eligibility isolates exact versus heuristic ACP correlation")
            let event = AgentToolStreamEvent.toolCall(.init(toolName: "mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__read_file", invocationID: UUID(), argsJSON: "{}"))
            XCTAssertTrue(runner.handleToolStreamEvent(event, session: session))
            XCTAssertEqual(session.items.count, 1)
            XCTAssertFalse(AgentSessionLinkPrompts.supportsQuietCheckIn(.devin))
            XCTAssertNil(session.quietLedger.candidateStartKey(owner: owner))
        }
    }
#endif
