import MCP
import RepoPromptACPProviders
import RepoPromptAIContracts
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import XCTest

@MainActor
final class ACPToolObservationCorrelationTests: XCTestCase {
    private var currentOwner: AgentTabSession?
    private var accountedOutputs: [String?] = []

    func testHealthyOracleSettlementCountsOutputOnceAndPreservesTheRealMCPEnvelope() async throws {
        let noOp = AgentToolTrackingHooks.noOp
        let hooks = AgentToolTrackingHooks(
            flushPendingAssistantDelta: noOp.flushPendingAssistantDelta, endActiveAssistantSegment: noOp.endActiveAssistantSegment,
            endActiveReasoningSegment: noOp.endActiveReasoningSegment, sealAssistantBoundary: noOp.sealAssistantBoundary,
            requestUIRefresh: noOp.requestUIRefresh, scheduleSave: noOp.scheduleSave, addToolInputTokens: noOp.addToolInputTokens,
            addToolOutputTokens: { [weak self] payload, _ in self?.accountedOutputs.append(payload) }
        )
        let (harness, session, runner) = fixture(toolTrackingHooks: hooks)
        _ = harness
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        session.installRunID(UUID())
        session.runState = .running
        session.beginRunAttempt(source: "healthy-oracle")
        let tracker = UUID()
        runner.testHandleTrackerToolCall(invocationID: tracker, toolName: "ask_oracle", args: ["new_chat": .bool(true)], session: session)
        let rowID = try XCTUnwrap(session.items.first?.id)
        let callbacks = try XCTUnwrap(runner.oracleToolSettlementCallbacks(session: session, invocationID: tracker, toolName: "ask_oracle", isOwnerCurrent: { true }))
        let result = try OracleGroupResult(groupID: OracleGroupID(rawValue: UUID()), status: .completed, oracleResults: [
            OracleLaneResult(laneIndex: 0, chatID: "primary", providerID: nil, modelID: "primary-model", status: .completed, response: "87"),
            OracleLaneResult(laneIndex: 1, chatID: "sibling", providerID: nil, modelID: "sibling-model", status: .completed, response: "87")
        ])
        let turn = OracleTurnID(rawValue: UUID())
        await callbacks.prepared(result.groupID, turn)
        callbacks.settled(result, turn, nil)
        var fields = OracleGroupMCPCodec.groupFields(result)
        fields["chat_id"] = .string(result.primary.chatID)
        fields["mode"] = .string("review")
        fields["oracle_export_path"] = .string("/fixture/export.md")
        let realPayload = ToolOutputFormatter.rawJSONString(.object(fields))
        runner.testHandleTrackerToolResult(invocationID: tracker, toolName: "ask_oracle", args: nil, resultJSON: realPayload, isError: false, session: session)
        XCTAssertEqual(session.items.map(\.id), [rowID])
        XCTAssertEqual(session.items.first?.toolResultJSON, realPayload)
        XCTAssertEqual(accountedOutputs.count, 1, "Settlement and ordinary MCP delivery share first-result accounting")
        XCTAssertTrue(accountedOutputs.compactMap(\.self).first?.contains("87") == true)
        let absent = try XCTUnwrap(runner.oracleToolSettlementCallbacks(session: session, invocationID: UUID(), toolName: "ask_oracle", isOwnerCurrent: { true }))
        await absent.prepared(result.groupID, turn)
        absent.settled(result, turn, nil)
        XCTAssertEqual(session.items.map(\.id), [rowID], "Missing prepared row must not synthesize a transcript invocation")
        XCTAssertEqual(accountedOutputs.count, 1)
    }

    func testCanonicalOracleSettlementReconcilesCapturedRowAfterCancellationAndRejectsSuccessors() async throws {
        let (harness, session, runner) = fixture()
        let runID = UUID()
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        session.installRunID(runID)
        session.runState = .running
        let ownership = session.beginRunAttempt(source: "oracle-cancel-reconciliation")
        let tracker = UUID()
        try deliver("owned-oracle", status: "pending", title: "ask_oracle", runner: runner, session: session)
        runner.testHandleTrackerToolCall(invocationID: tracker, toolName: "ask_oracle", args: ["new_chat": .bool(true)], session: session)
        let rowID = try XCTUnwrap(session.items.first?.id)
        currentOwner = session
        let callbacks = try XCTUnwrap(runner.oracleToolSettlementCallbacks(session: session, invocationID: tracker, toolName: "ask_oracle", isOwnerCurrent: { [weak self, weak session] in
            guard let self, let session else { return false }
            return currentOwner === session
        }))
        let group = OracleGroupID(rawValue: UUID())
        let turn = OracleTurnID(rawValue: UUID())
        await callbacks.prepared(group, turn)
        try deliver("owned-oracle", status: "failed", runner: runner, session: session)
        runner.testRetireToolCorrelation(tabID: session.tabID)
        _ = await AgentRunTerminalCommitBarrier().commit(.init(
            binding: harness.hooks.bindTerminalSession(session), ownership: ownership, expectedRunID: runID,
            terminalState: .cancelled, source: "oracle-cancel", completion: .terminalTeardownCompleted, attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: false, supportsFollowUp: false, notifyTurnComplete: false,
            providerDrainGeneration: session.providerTerminalDrainGeneration,
            prepareProviderState: { session.clearRunID(ifCurrent: runID)
                return nil
            }
        ))
        let result = try OracleGroupResult(groupID: group, status: .partialFailure, oracleResults: [
            OracleLaneResult(laneIndex: 0, chatID: "primary", providerID: nil, modelID: "primary-model", status: .completed, response: "87"),
            OracleLaneResult(laneIndex: 1, chatID: "sibling", providerID: nil, modelID: "sibling-model", status: .cancelled, error: .init(code: "cancelled", message: "Owner cancelled"))
        ])
        let failedPayload = session.items.first?.toolResultJSON
        try callbacks.settled(OracleGroupResult(groupID: OracleGroupID(rawValue: UUID()), status: result.status, oracleResults: result.oracleResults), turn, nil)
        XCTAssertEqual(session.items.first?.toolResultJSON, failedPayload, "Wrong group has no row authority")
        callbacks.settled(result, OracleTurnID(rawValue: UUID()), nil)
        XCTAssertEqual(session.items.first?.toolResultJSON, failedPayload, "Wrong turn has no row authority")
        currentOwner = nil
        callbacks.settled(result, turn, nil)
        XCTAssertEqual(session.items.first?.toolResultJSON, failedPayload, "Replaced tab owner fences the old settlement")
        currentOwner = session
        let capturedGuidance = "  Retain disagreements after cancellation.\nRead every lane.  "
        callbacks.settled(result, turn, capturedGuidance)
        XCTAssertEqual(session.items.map(\.id), [rowID])
        XCTAssertTrue(session.items.first?.toolArgsJSON?.contains("new_chat") == true)
        XCTAssertEqual(session.items.first?.toolIsError, true)
        let execution = try XCTUnwrap(AgentTranscriptToolNormalizer.toolExecution(for: session.items[0]))
        XCTAssertEqual(execution.status, .warning)
        XCTAssertTrue(execution.resultJSON?.contains(group.rawValue.uuidString) == true)
        let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: execution.resultJSON))
        XCTAssertEqual(dto.oracleReconciliationGuidance, capturedGuidance)
        let coverage = try XCTUnwrap(OracleLaneCoverage(lanes: dto.oracleResults, oracleCount: dto.oracleCount))
        XCTAssertEqual(coverage.completedCount, 1)
        XCTAssertEqual(coverage.totalCount, 2)
        let settledPayload = session.items.first?.toolResultJSON
        session.installRunID(UUID())
        let changed = try OracleGroupResult(groupID: group, status: .completed, oracleResults: [
            OracleLaneResult(laneIndex: 0, chatID: "primary", providerID: nil, modelID: "primary-model", status: .completed, response: "changed"),
            OracleLaneResult(laneIndex: 1, chatID: "sibling", providerID: nil, modelID: "sibling-model", status: .completed, response: "changed")
        ])
        callbacks.settled(changed, turn, nil)
        XCTAssertEqual(session.items.first?.toolResultJSON, settledPayload, "Installing a successor run ID already fences the old settlement")
        session.beginRunAttempt(source: "successor")
        callbacks.settled(changed, turn, nil)
        XCTAssertEqual(session.items.first?.toolResultJSON, settledPayload, "A successor attempt fences the old settlement")
    }

    func testAbortedProviderTerminalPreservesSettledOracleCoverageOnTheSameRow() throws {
        let (harness, session, runner) = fixture()
        _ = harness
        let tracker = UUID()
        let args: [String: Value] = ["new_chat": .bool(true)]
        runner.testHandleTrackerToolCall(invocationID: tracker, toolName: "ask_oracle", args: args, session: session)
        let rowID = try XCTUnwrap(session.items.first?.id)
        let group = try OracleGroupResult(groupID: OracleGroupID(rawValue: UUID()), status: .partialFailure, oracleResults: [
            OracleLaneResult(laneIndex: 0, chatID: "primary", providerID: nil, modelID: "primary-model", status: .completed, response: "87"),
            OracleLaneResult(laneIndex: 1, chatID: "sibling", providerID: nil, modelID: "sibling-model", status: .cancelled, error: .init(code: "cancelled", message: "Owner cancelled"))
        ])
        let settled = ToolOutputFormatter.rawJSONString(.object(OracleGroupMCPCodec.groupFields(group)))
        runner.testHandleTrackerToolResult(invocationID: tracker, toolName: "ask_oracle", args: args, resultJSON: settled, isError: false, session: session)
        try deliver("cancelled-oracle", status: "pending", title: "ask_oracle", runner: runner, session: session)
        try deliver("cancelled-oracle", status: "failed", runner: runner, session: session)
        XCTAssertEqual(session.items.map(\.id), [rowID])
        XCTAssertEqual(session.items.first?.toolResultJSON, settled)
        XCTAssertEqual(session.items.first?.toolIsError, true, "The provider abort remains transport truth, independently of canonical lane coverage")
        XCTAssertEqual(AgentTranscriptToolNormalizer.toolExecution(for: session.items[0])?.status, .warning)
    }

    func testLateEmptyProviderStartsPairDistinctCompletedTrackerCallsAndSurviveDiskRestore() async throws {
        let (harness, session, runner) = fixture()
        _ = harness
        let trackers = [UUID(), UUID()]
        for id in trackers {
            runner.testHandleTrackerToolCall(invocationID: id, toolName: "get_file_tree", args: ["type": .string("roots")], session: session)
        }
        XCTAssertEqual(session.items.count, 2, "Identical calls with distinct tracker IDs are distinct invocations")
        guard session.items.count == 2 else { return }
        let rowIDs = session.items.map(\.id)
        let outputs = [#"{"roots":["first"]}"#, #"{"roots":["second"]}"#]
        for (index, id) in trackers.enumerated() {
            runner.testHandleTrackerToolResult(invocationID: id, toolName: "get_file_tree", args: ["type": .string("roots")], resultJSON: outputs[index], isError: false, session: session)
        }
        let providerIDs = ["toolu_e0c16e4f4d4bea2981b8d6ea5fac4ba2", "toolu_2403d22501fbf23b8ccbcffae9ad0c90"]
        for (index, id) in providerIDs.enumerated() {
            try deliver(id, status: "pending", input: index == 0 ? nil : [:], title: "get_file_tree", runner: runner, session: session)
            try deliver(id, status: "pending", title: "get_file_tree", runner: runner, session: session)
            try deliver(id, status: "completed", runner: runner, session: session)
            // Repeated tracker completion must still resolve its retained provider alias.
            runner.testHandleTrackerToolResult(invocationID: trackers[index], toolName: "get_file_tree", args: ["type": .string("roots")], resultJSON: outputs[index], isError: false, session: session)
        }
        XCTAssertEqual(session.items.map(\.id), rowIDs)
        XCTAssertEqual(session.items.map(\.toolResultJSON), outputs.map(Optional.some))
        XCTAssertEqual(session.items.map(\.toolInvocationID), providerIDs.map { Optional(ACPRuntimeEventParsing.stableInvocationUUID(rawValue: $0)) })
        for row in session.items {
            XCTAssertTrue(row.toolArgsJSON?.contains("roots") == true)
            XCTAssertEqual(AgentTranscriptToolNormalizer.toolExecution(for: row)?.status, .success)
        }
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("ACPIdentityFixture-\(UUID().uuidString)")
        let workspace = WorkspaceModel(name: "ACP identity fixture", repoPaths: [], customStoragePath: storage)
        defer { try? FileManager.default.removeItem(at: storage) }
        let activities = session.items.map { AgentTranscriptActivity(from: $0, toolExecution: AgentTranscriptToolNormalizer.toolExecution(for: $0)) }
        let saved = AgentSession(workspaceID: workspace.id, composeTabID: session.tabID, name: "Identity fixture", transcript: AgentTranscript(turns: [AgentTranscriptTurn(responseSpans: [AgentTranscriptProviderResponseSpan(lifecycle: .open, startedAt: session.items[0].timestamp, activities: activities)], terminalState: .completed, startedAt: session.items[0].timestamp)], nextSequenceIndex: 2), lastRunState: "completed")
        let file = try await AgentSessionDataService().saveAgentSession(saved, for: workspace)
        let loaded = try await AgentSessionDataService().loadAgentSession(from: file)
        let restored = try XCTUnwrap(loaded.transcript).turns.flatMap(\.allActivities)
        XCTAssertEqual(restored.map(\.id), rowIDs)
        XCTAssertEqual(restored.compactMap { $0.toolExecution?.status }, [.success, .success])
    }

    func testProviderFirstEmptyInputsPairNilAndEmptyTrackerArguments() throws {
        for args: [String: Value]? in [nil, [:]] {
            let (harness, session, runner) = fixture()
            _ = harness
            try deliver("empty-tracker-input", status: "pending", title: "get_file_tree", runner: runner, session: session)
            let rowID = session.items.first?.id
            let tracker = UUID()
            runner.testHandleTrackerToolCall(invocationID: tracker, toolName: "get_file_tree", args: args, session: session)
            runner.testHandleTrackerToolResult(invocationID: tracker, toolName: "get_file_tree", args: args, resultJSON: #"{"roots":[]}"#, isError: false, session: session)
            XCTAssertEqual(session.items.count, 1)
            XCTAssertEqual(session.items.first?.id, rowID)
            XCTAssertEqual(session.items.first?.toolInvocationID, ACPRuntimeEventParsing.stableInvocationUUID(rawValue: "empty-tracker-input"))
            XCTAssertEqual(AgentTranscriptToolNormalizer.toolExecution(for: session.items[0])?.status, .success)
        }
    }

    func testSubstantiveDelayedProviderStartChoosesOlderCompletedTrackerBeforeNewerPendingCall() throws {
        let (harness, session, runner) = fixture()
        _ = harness
        let trackers = [UUID(), UUID()]
        runner.testHandleTrackerToolCall(invocationID: trackers[0], toolName: "get_file_tree", args: ["type": .string("roots")], session: session)
        runner.testHandleTrackerToolResult(invocationID: trackers[0], toolName: "get_file_tree", args: ["type": .string("roots")], resultJSON: #"{"roots":["older"]}"#, isError: false, session: session)
        runner.testHandleTrackerToolCall(invocationID: trackers[1], toolName: "get_file_tree", args: ["type": .string("roots")], session: session)
        try deliver("older-provider", status: "pending", input: ["type": "roots"], title: "get_file_tree", runner: runner, session: session)
        XCTAssertEqual(session.items[0].toolInvocationID, ACPRuntimeEventParsing.stableInvocationUUID(rawValue: "older-provider"))
        XCTAssertEqual(session.items[1].toolInvocationID, trackers[1])
        try deliver("newer-provider", status: "pending", input: ["type": "roots"], title: "get_file_tree", runner: runner, session: session)
        XCTAssertEqual(session.items[1].toolInvocationID, ACPRuntimeEventParsing.stableInvocationUUID(rawValue: "newer-provider"))
        XCTAssertEqual(session.items.count, 2)
        XCTAssertEqual(session.items[0].toolResultJSON, #"{"roots":["older"]}"#)
        XCTAssertEqual(session.items[1].kind, .toolCall)
    }

    func testProviderOnlyEmptyAndSubstantiveCallsStayDistinctAndSparseTerminalsComplete() throws {
        let (harness, session, runner) = fixture()
        _ = harness
        for id in ["empty-one", "empty-two"] {
            try deliver(id, status: "pending", input: [:], title: "get_file_tree", runner: runner, session: session)
        }
        try deliver("substantive", status: "pending", input: ["pattern": "needle"], title: "file_search", runner: runner, session: session)
        XCTAssertEqual(session.items.count, 3)
        XCTAssertTrue(session.items.allSatisfy { $0.kind == .toolCall })
        for id in ["empty-one", "empty-two", "substantive"] {
            try deliver(id, status: "completed", output: "provider output", runner: runner, session: session)
        }
        XCTAssertEqual(session.items.count, 3)
        XCTAssertTrue(session.items.allSatisfy { AgentTranscriptToolNormalizer.toolExecution(for: $0)?.status == .success })
        XCTAssertTrue(session.items.last?.toolArgsJSON?.contains("needle") == true)
    }

    func testOriginalFourteenProviderIdentitiesProduceFourteenRowsAfterDelayedStarts() throws {
        // Identity/name sequence from the live final-provider-tool-parts artifact.
        // Timing is deliberately adversarial; it is not a recovered wire trace.
        let observed: [(String, String)] = [
            ("get_file_tree", "call_00_dfkm60wtt9gsej0lq98orrbs"),
            ("workspace_context", "call_00_rrc1t1u4v7p40r0kfv436yz6"),
            ("manage_selection", "call_00_ekm56elkyc7mhb51dj7mozof"),
            ("get_file_tree", "call_00_qnax9q0ibhs9k2785znhjl9k"),
            ("get_file_tree", "call_00_rbz0dq2g6qnet6xli4cj9uzk"),
            ("get_file_tree", "call_01_z17kai67qwt7pjmh0v7uhpem"),
            ("get_file_tree", "call_00_3zk6wpg4sz1nywy8du6u2ee3"),
            ("manage_selection", "call_00_6f6okzdi0af2yl5hz72ke5r0"),
            ("workspace_context", "call_00_a27b4nvd35llmxxepp8ihyeb"),
            ("ask_oracle", "call_00_o7oet33e3fi74ktm0e2eik5p"),
            ("get_file_tree", "call_00_b7tzgbk6kayfgennjejoy665"),
            ("workspace_context", "call_01_1k7as6o1ayuqo5skf4eft4sr"),
            ("ask_oracle", "call_00_ldswv0w1v1nsismwud42zv90"),
            ("ask_oracle", "call_00_ufi9qzlohfqmglar2eryj4zn")
        ]
        let (harness, session, runner) = fixture()
        _ = harness
        for (index, entry) in observed.enumerated() {
            let tracker = UUID()
            let args: [String: Value] = entry.0 == "get_file_tree" ? ["type": .string("roots")] : ["fixture_index": .int(index)]
            runner.testHandleTrackerToolCall(invocationID: tracker, toolName: entry.0, args: args, session: session)
            runner.testHandleTrackerToolResult(invocationID: tracker, toolName: entry.0, args: args, resultJSON: #"{"fixture_result":true}"#, isError: index == 3, session: session)
        }
        let rowIDs = session.items.map(\.id)
        for entry in observed {
            try deliver(entry.1, status: "pending", title: entry.0, runner: runner, session: session)
            try deliver(entry.1, status: "completed", runner: runner, session: session)
        }
        XCTAssertEqual(session.items.count, 14, "Delayed provider observations must not create six phantom rows")
        XCTAssertEqual(session.items.map(\.id), rowIDs)
        XCTAssertEqual(session.items.map(\.toolInvocationID), observed.map { Optional(ACPRuntimeEventParsing.stableInvocationUUID(rawValue: $0.1)) })
        XCTAssertTrue(session.items.allSatisfy { $0.kind == .toolResult })
        XCTAssertEqual(AgentTranscriptToolNormalizer.toolExecution(for: session.items[3])?.status, .failed)
    }

    func testMultipleProviderFirstPlaceholdersPairDistinctTrackers() throws {
        for terminalBeforeTracker in [false, true] {
            let (harness, session, runner) = fixture()
            _ = harness
            for id in ["first-placeholder", "second-placeholder"] {
                try deliver(id, status: "pending", title: "get_file_tree", runner: runner, session: session)
                if terminalBeforeTracker {
                    try deliver(id, status: "completed", runner: runner, session: session)
                }
            }
            let rowIDs = session.items.map(\.id)
            for _ in 0 ..< 2 {
                let tracker = UUID()
                runner.testHandleTrackerToolCall(invocationID: tracker, toolName: "get_file_tree", args: ["type": .string("roots")], session: session)
                runner.testHandleTrackerToolResult(invocationID: tracker, toolName: "get_file_tree", args: ["type": .string("roots")], resultJSON: #"{"roots":[]}"#, isError: false, session: session)
            }
            XCTAssertEqual(session.items.map(\.id), rowIDs)
            XCTAssertEqual(session.items.count, 2)
            XCTAssertTrue(session.items.allSatisfy { AgentTranscriptToolNormalizer.toolExecution(for: $0)?.status == .success })
        }
    }

    func testProviderFirstPlaceholderPairsOnlyOneTrackerWithIdenticalArguments() throws {
        let (harness, session, runner) = fixture()
        _ = harness
        try deliver("provider-first", status: "pending", title: "get_file_tree", runner: runner, session: session)
        let firstRow = session.items.first?.id
        let trackers = [UUID(), UUID()]
        for id in trackers {
            runner.testHandleTrackerToolCall(invocationID: id, toolName: "get_file_tree", args: ["type": .string("roots")], session: session)
        }
        XCTAssertEqual(session.items.count, 2)
        XCTAssertEqual(session.items.first?.id, firstRow)
        try deliver("provider-second", status: "pending", title: "get_file_tree", runner: runner, session: session)
        for id in trackers {
            runner.testHandleTrackerToolResult(invocationID: id, toolName: "get_file_tree", args: ["type": .string("roots")], resultJSON: #"{"roots":[]}"#, isError: false, session: session)
        }
        XCTAssertEqual(session.items.count, 2)
        XCTAssertTrue(session.items.allSatisfy { AgentTranscriptToolNormalizer.toolExecution(for: $0)?.status == .success })
    }

    private func fixture(toolTrackingHooks: AgentToolTrackingHooks = .noOp) -> (AgentSessionLinkRunnerHarness, AgentTabSession, ACPIntegratedAgentModeRunner) {
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
        let runner = ACPIntegratedAgentModeRunner(hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier(), toolTrackingHooks: toolTrackingHooks)
        return (harness, harness.makeSession(agent: .devin), runner)
    }

    private func deliver(_ id: String, status: String, input: [String: Any]? = nil, output: Any? = nil, title: String? = nil, runner: ACPIntegratedAgentModeRunner, session: AgentTabSession) throws {
        var update: [String: Any] = ["sessionUpdate": status == "pending" ? "tool_call" : "tool_call_update", "toolCallId": id, "status": status]
        update["rawInput"] = input
        update["rawOutput"] = output
        update["title"] = title
        let events = ACPDefaultSessionUpdateNormalizer.normalize(update, providerID: .openCode)
        guard case let .stream(result) = events.first else { return XCTFail("Missing normalized event") }
        let event = try XCTUnwrap(AgentToolStreamEvent.from(result))
        XCTAssertTrue(runner.handleToolStreamEvent(event, session: session), "Known sparse terminal must remain observable")
    }
}

@MainActor
final class ACPIntegratedAgentModeRunnerExecutionTests: XCTestCase {
    func testComposedStartupRefusalSettlesOnlyItsOwnAttemptAndCannotAcknowledgeSuccessor() async throws {
        for replacesAttempt in [false, true] {
            let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
            let session = try harness.makeBoundSession(agent: .devin)
            let origin = try harness.startCommand(for: session)
            let provider = AgentSessionLinkCapturingACPProvider(providerID: .devin, commandPath: "/usr/bin/false")
            let entered = expectation(description: "Construction is held after execution admission")
            var release: CheckedContinuation<Void, Never>?
            defer { release?.resume() }
            var controllerConstructions = 0
            let resources = AgentRunProviderComposition(
                headless: { _, _ in AgentSessionLinkCapturingHeadlessProvider() },
                acp: { _, _ in
                    await withCheckedContinuation { continuation in release = continuation
                        entered.fulfill()
                    }
                    return provider
                },
                controller: { provider, request in
                    controllerConstructions += 1
                    return try ACPAgentSessionController(provider: provider, runRequest: request)
                }
            )
            let composition = AgentModeRunComposition(execution: harness.service, resources: resources, workspace: harness.workspace)
            let outcome = AgentRunStartOutcomeRecorder()
            let fence = AgentRunStartStopFence(session: session)
            let start = Task { await composition.startRun(
                tabID: session.tabID, session: session, origin: origin, initialUserMessage: "turn", initialMessageForRun: "turn",
                attachments: [], startOutcome: outcome, stopFence: fence
            ) }
            await fulfillment(of: [entered], timeout: 3)
            let originating = session.activeRunOwnership
            if replacesAttempt {
                await harness.service.cancelRun(tabID: session.tabID, session: session, completion: .terminalTeardownCompleted)
                session.beginRunAttempt(source: "successor while old construction settles")
                session.installRunID(UUID())
                session.runState = .running
            } else {
                // A producer fence can be withdrawn before a cancellation command publishes terminal.
                session.stopState.invalidateScheduledStarts()
            }
            let expectedOwner = session.activeRunOwnership
            release?.resume()
            release = nil
            _ = await start.value
            XCTAssertFalse(outcome.outcome.didStart, "A different active attempt is not evidence this request installed work")
            XCTAssertEqual(controllerConstructions, 0)
            XCTAssertEqual(provider.supportCallCount, 0)
            XCTAssertNil(session.acpController)
            if replacesAttempt {
                XCTAssertNotEqual(expectedOwner, originating)
                XCTAssertEqual(session.activeRunOwnership, expectedOwner)
                XCTAssertEqual(session.runState, .running)
                await harness.service.cancelRun(tabID: session.tabID, session: session, completion: .terminalTeardownCompleted)
            } else {
                XCTAssertEqual(session.runState, .cancelled, "Refusal must not strand a running attempt without a task")
                XCTAssertNil(session.activeRunOwnership)
            }
        }
    }

    func testFreshACPConstructionReleasesResourcesWithoutSettlingAReacquiredWriter() async throws {
        enum Stage { case queued, provider, providerFailure, support, supportFailure, controller, retiring }
        struct ConstructionFailure: Error {}
        @MainActor final class Snapshot {
            var owner: AgentRunOwnership?
            var runID: UUID?
            var dirty = false
            var saveGeneration: UInt64 = 0
        }
        for stage in [Stage.queued, .provider, .providerFailure, .support, .supportFailure, .controller, .retiring] {
            let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
            let session = try harness.makeBoundSession(agent: .devin)
            let origin = try harness.startCommand(for: session)
            let scope = origin.writer.scope
            let before = Snapshot()
            let drift: @MainActor @Sendable () -> Void = {
                before.owner = session.activeRunOwnership
                before.runID = session.runID
                before.dirty = session.isDirty
                before.saveGeneration = session.saveRequestGeneration
                if stage == .retiring {
                    scope.beginRetirement()
                } else {
                    var members = scope.sessions
                    members.removeValue(forKey: session.tabID)
                    scope.replaceSessions(members)
                    members[session.tabID] = session
                    scope.replaceSessions(members)
                    XCTAssertFalse(origin.writer.ownsPersistentClaim)
                }
            }
            let provider = AgentSessionLinkCapturingACPProvider(
                providerID: .devin, commandPath: "/usr/bin/false",
                supportOperation: {
                    if stage == .support || stage == .supportFailure || stage == .retiring { await drift() }
                    if stage == .supportFailure { throw ConstructionFailure() }
                    return .supported
                }
            )
            var constructedController: ACPAgentSessionController?
            let resources = AgentRunProviderComposition(
                headless: { _, _ in AgentSessionLinkCapturingHeadlessProvider() },
                acp: { _, _ in
                    if stage == .provider || stage == .providerFailure { drift() }
                    if stage == .providerFailure { throw ConstructionFailure() }
                    return provider
                },
                controller: { provider, request in
                    let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
                    constructedController = controller
                    drift()
                    return controller
                }
            )
            var capturedLease: MCPBootstrapLease?
            let runner = ACPIntegratedAgentModeRunner(hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier(), toolTrackingHooks: .noOp)
            let outcome = AgentRunStartOutcomeRecorder()
            let prepared = await runner.prepareRun(
                tabID: session.tabID, session: session, origin: origin, workspace: harness.workspace,
                initialUserMessage: "turn", initialMessageForRun: "turn", attachments: [],
                runRequest: ACPRunRequest(agentKind: .devin, modelString: nil, workspacePath: nil, resumeSessionID: nil, attachments: [], taskLabelKind: nil),
                startOutcome: outcome, makeLease: { runID in
                    let lease = harness.makeLease(runID: runID, tabID: session.tabID)
                    capturedLease = lease
                    return lease
                }
            )
            let lease = try XCTUnwrap(capturedLease)
            if stage == .queued { drift() }
            await resources.fulfill(prepared)
            XCTAssertFalse(outcome.outcome.didStart)
            XCTAssertNil(session.acpController)
            XCTAssertNil(session.agentTask)
            let leaseCanAcquire = await lease.acquire()
            XCTAssertFalse(leaseCanAcquire, "Captured unacquired lease must be permanently released")
            if let constructedController {
                let retired = await constructedController.isRetired
                XCTAssertTrue(retired, "A returned but uninstalled controller must be shut down")
            }
            if stage == .retiring {
                XCTAssertEqual(session.runState, .cancelled, "The original retiring claim can drain its attempt")
            } else {
                XCTAssertEqual(session.activeRunOwnership, before.owner)
                XCTAssertEqual(session.runID, before.runID)
                XCTAssertEqual(session.isDirty, before.dirty)
                XCTAssertEqual(session.saveRequestGeneration, before.saveGeneration)
                XCTAssertNil(session.lastTerminalCommitRevision, "Old construction cannot publish terminal for a new claim")
                XCTAssertTrue(session.runState.isActive)
                // Only the current claim may settle this shared attempt. Stop must work even
                // though resource construction never installed an agentTask or controller.
                _ = try harness.startCommand(for: session)
                await harness.service.cancelRun(tabID: session.tabID, session: session, completion: .terminalTeardownCompleted)
                XCTAssertEqual(session.runState, .cancelled)
                XCTAssertNil(session.activeRunOwnership)
            }
            session.saveDebounceTask?.cancel()
        }
    }

    func testACPUnsentPromptDoesNotCreateAnEventConsumer() async throws {
        for (cancelDuringProof, refuseRelease) in [(false, false), (true, false), (false, true)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let script = try AgentSessionLinkACPServerScript.write(to: directory)
            let promptLog = directory.appendingPathComponent("prompts.jsonl")
            let provider = AgentSessionLinkCapturingACPProvider(providerID: .antigravity, commandPath: script.path, environment: ["ACP_PROMPT_LOG": promptLog.path])
            let request = ACPRunRequest(agentKind: .antigravity, modelString: nil, workspacePath: directory.path, resumeSessionID: nil, attachments: [], taskLabelKind: nil)
            let controller = try ACPAgentSessionController(provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true)
            addTeardownBlock { await controller.shutdown() }
            let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
            let session = try harness.makeBoundSession(agent: .antigravity)
            let origin = try harness.startCommand(for: session)
            let barrier = AgentRunTerminalCommitBarrier()
            let runner = ACPIntegratedAgentModeRunner(hooks: harness.hooks, terminalCommitBarrier: barrier, toolTrackingHooks: .noOp)
            var consumers = 0
            runner.testPromptConsumerCreated = { consumers += 1 }
            var task: Task<Void, Never>?
            var ownership: AgentRunOwnership?
            harness.beforeProviderInputProof = {
                task = session.agentTask
                ownership = session.activeRunOwnership
                await Task.yield()
                XCTAssertEqual(consumers, 0, "Input proof must not race a consumer that can mutate the session")
                XCTAssertEqual(session.runLifecycle.liveness?.stage, .preparingRuntime)
                if cancelDuringProof { task?.cancel() }
            }
            var releases = 0
            if refuseRelease {
                harness.providerInputReleaseOverride = {
                    releases += 1
                    XCTAssertEqual(consumers, 0)
                    XCTAssertEqual(session.runLifecycle.liveness?.stage, .preparingRuntime)
                    return AgentSessionLinkProviderInputRelease.handoffAcceptedReplay(nil, proof: nil, isCurrent: false, requiresLaneBatch: true)
                }
            }
            let prepared = await runner.prepareRun(
                tabID: session.tabID, session: session, origin: origin, workspace: harness.workspace,
                initialUserMessage: "turn", initialMessageForRun: "turn", attachments: [], runRequest: request,
                makeLease: { harness.makeLease(runID: $0, tabID: session.tabID) }
            )
            let resources = AgentRunProviderComposition(
                headless: { _, _ in AgentSessionLinkCapturingHeadlessProvider() },
                acp: { _, _ in provider }, controller: { _, _ in controller }
            )
            await resources.fulfill(prepared)
            try await AsyncTestWait.waitUntil("ACP input proof") { task != nil }
            await task?.value
            let finishedOwner = try XCTUnwrap(ownership)
            await barrier.awaitTerminalTeardown(for: finishedOwner, lifecycle: session.runLifecycle)
            let refused = cancelDuringProof || refuseRelease
            XCTAssertEqual(releases, refuseRelease ? 1 : 0)
            XCTAssertEqual(consumers, refused ? 0 : 1)
            XCTAssertEqual(session.runState, refused ? .cancelled : .completed)
            if refused {
                XCTAssertFalse(FileManager.default.fileExists(atPath: promptLog.path))
            } else {
                let prompts = try String(contentsOf: promptLog, encoding: .utf8).split(separator: "\n")
                XCTAssertEqual(prompts.count, 1, "The dispatched turn must still consume its terminal event")
            }
            await controller.shutdown()
            session.saveDebounceTask?.cancel()
        }
    }

    func testACPControlCommandDoesNotConsumeEventsBeforeAdmission() async throws {
        enum Refusal { case none, conversationChanged, cancelled }
        for refusal in [Refusal.none, .conversationChanged, .cancelled] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let script = try AgentSessionLinkACPServerScript.write(to: directory)
            let rpcLog = directory.appendingPathComponent("requests.jsonl")
            let provider = AgentSessionLinkCapturingACPProvider(providerID: .antigravity, commandPath: script.path, environment: [
                "ACP_RPC_LOG": rpcLog.path, "ACP_ADVERTISE_COMMANDS": "compact", "ACP_ADVERTISE_BEFORE_NEW_RESPONSE": "1"
            ])
            let request = ACPRunRequest(agentKind: .antigravity, modelString: nil, workspacePath: directory.path, resumeSessionID: nil, attachments: [], taskLabelKind: nil)
            let controller = try ACPAgentSessionController(provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true)
            addTeardownBlock { await controller.shutdown() }
            let bootstrap = try await controller.bootstrap()
            let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
            let session = try harness.makeBoundSession(agent: .antigravity)
            session.acpController = controller
            session.providerSessionID = bootstrap.providerSessionIdentity.loadSessionID ?? bootstrap.providerSessionIdentity.runtimeSessionID
            _ = AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
            let command = try AgentProviderControlCommand.compact(expectedBinding: XCTUnwrap(session.persistentSessionBindingIdentity), expectedProviderConversation: XCTUnwrap(session.providerSessionID))
            let runner = ACPIntegratedAgentModeRunner(hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier(), toolTrackingHooks: .noOp)
            var consumers = 0
            var task: Task<Void, Never>?
            runner.testPromptConsumerCreated = { consumers += 1 }
            runner.testAtStartupBoundary = { boundary in
                guard boundary == .controlPromptAdmission else { return }
                task = session.agentTask
                XCTAssertEqual(consumers, 0)
                switch refusal {
                case .none: break
                case .conversationChanged: session.providerSessionID = "replacement-conversation"
                case .cancelled: session.agentTask?.cancel()
                }
            }
            _ = try await runner.prepareRun(
                tabID: session.tabID, session: session, origin: harness.startCommand(for: session), workspace: harness.workspace,
                initialUserMessage: command.providerText, initialMessageForRun: command.providerText, attachments: [], runRequest: request,
                providerControlCommand: command, makeLease: { harness.makeLease(runID: $0, tabID: session.tabID) }
            )
            try await AsyncTestWait.waitUntil("control command admission") { task != nil }
            await task?.value
            XCTAssertEqual(consumers, refusal == .none ? 1 : 0)
            let rpcText = try String(contentsOf: rpcLog, encoding: .utf8)
            XCTAssertEqual(rpcText.contains("session/prompt"), refusal == .none)
            if refusal == .none { XCTAssertEqual(session.runState, .completed) }
            if refusal == .conversationChanged {
                XCTAssertEqual(session.runState, .failed)
                XCTAssertTrue(session.acpController === controller)
            }
            if refusal == .cancelled { XCTAssertEqual(session.runState, .cancelled) }
            await controller.shutdown()
            session.saveDebounceTask?.cancel()
        }
    }

    func testACPFreshBootstrapAndConfigurationKeepTheirOriginalWriter() async throws {
        typealias Boundary = ACPIntegratedAgentModeRunner.StartupBoundary
        enum Drift { case reacquire, retire, successor, detached, transientConflict, none }
        @MainActor final class Counters { var installed = 0, cleared = 0 }
        let boundaries: [Boundary] = [.bootstrapStarting, .bootstrapCompleted, .resumeRecoveryStaged, .configuration, .routingReleased, .prePromptFailure]
        let cases = boundaries.flatMap { [($0, Drift.reacquire, false), ($0, Drift.retire, false)] }
            + [
                (.bootstrapCompleted, .successor, false),
                (.routingReleased, .none, false),
                (.bootstrapCompleted, .detached, false),
                (.configuration, .transientConflict, false),
                (.configuration, .reacquire, true),
                (.configuration, .retire, true)
            ]
        for (boundary, drift, afterConfigurationRPC) in cases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let script = try AgentSessionLinkACPServerScript.write(to: directory)
            let rpcLog = directory.appendingPathComponent("requests.jsonl")
            var environment = ["ACP_RPC_LOG": rpcLog.path]
            if boundary == .prePromptFailure { environment["ACP_FAIL_METHOD"] = "session/new" }
            if boundary == .resumeRecoveryStaged { environment["ACP_FAIL_LOAD"] = "1" }
            let provider = AgentSessionLinkCapturingACPProvider(providerID: .antigravity, commandPath: script.path, environment: environment)
            let request = ACPRunRequest(
                agentKind: .antigravity, modelString: nil, workspacePath: directory.path,
                resumeSessionID: boundary == .resumeRecoveryStaged ? "missing-session" : nil,
                attachments: [], taskLabelKind: nil, sessionModeID: "auto_edit"
            )
            let controller = try ACPAgentSessionController(provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true)
            addTeardownBlock { await controller.shutdown() }
            let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
            let session = try harness.makeBoundSession(agent: .antigravity)
            let origin = try harness.startCommand(for: session)
            let scope = origin.writer.scope
            harness.pendingHandoffSendOutcome = { session, sent in scope.handoff.recordSendOutcome(for: session, didSend: sent) }
            session.pendingHandoff.payload = "unsent handoff"
            session.pendingHandoff.isStagedForSend = true
            let barrier = AgentRunTerminalCommitBarrier()
            let runner = ACPIntegratedAgentModeRunner(hooks: harness.hooks, terminalCommitBarrier: barrier, toolTrackingHooks: .noOp)
            var reached = false
            var task: Task<Void, Never>?
            var owner: AgentRunOwnership?
            var dirty = false
            var saves: UInt64 = 0
            var identity: String?
            var previousTeardown: AgentRunAttemptTerminalResources.Teardown?
            let conflicting = AgentSessionRuntimeStore.shared.makeScope()
            defer { conflicting.replaceSessions([:]) }
            var consumers = 0
            runner.testPromptConsumerCreated = { consumers += 1 }
            runner.testAtStartupBoundary = { point in
                if point == boundary, reached, drift == .transientConflict {
                    conflicting.replaceSessions([:])
                    XCTAssertTrue(origin.isCurrent)
                }
                guard point == boundary, !reached else { return }
                if afterConfigurationRPC {
                    let text = (try? String(contentsOf: rpcLog, encoding: .utf8)) ?? ""
                    guard text.contains("session/set_config_option") else { return }
                }
                reached = true
                task = session.agentTask
                dirty = session.isDirty
                saves = session.saveRequestGeneration
                identity = session.providerSessionID
                switch drift {
                case .reacquire:
                    var members = scope.sessions
                    members.removeValue(forKey: session.tabID)
                    scope.replaceSessions(members)
                    members[session.tabID] = session
                    scope.replaceSessions(members)
                case .retire:
                    scope.beginRetirement()
                case .successor, .detached:
                    if let oldOwner = session.activeRunOwnership {
                        previousTeardown = session.claimRunAttemptTerminalTeardown(ownership: oldOwner, terminalState: .cancelled)
                    }
                    if drift == .successor {
                        _ = session.beginRunAttempt(source: "successor during bootstrap")
                    } else {
                        session.acpController = nil
                    }
                case .transientConflict:
                    let duplicate = conflicting.makeSession(tabID: UUID())
                    duplicate.installPersistentSessionBinding(.init(
                        tabID: duplicate.tabID, sessionID: origin.identity.sessionID,
                        workspaceID: origin.identity.workspaceID
                    ))
                    conflicting.replaceSessions([duplicate.tabID: duplicate])
                    XCTAssertFalse(origin.isCurrent)
                case .none:
                    break
                }
                owner = session.activeRunOwnership
            }
            let gateID = UUID()
            let counters = Counters()
            var lease: MCPBootstrapLease?
            let prepared = await runner.prepareRun(
                tabID: session.tabID, session: session, origin: origin, workspace: harness.workspace,
                initialUserMessage: "turn", initialMessageForRun: "turn", attachments: [], runRequest: request,
                makeLease: { runID in
                    let result = MCPBootstrapLease(
                        spec: MCPBootstrapLeaseSpec(
                            runID: runID, gateID: gateID, windowID: 1, tabID: session.tabID,
                            clientName: "RepoPromptCE", restrictedTools: [], additionalTools: nil,
                            oneShot: true, reason: "fresh bootstrap writer test", ttl: 60, purpose: .agentModeRun,
                            taskLabelKind: nil, allowsAgentExternalControlTools: false, requiresExpectedAgentPID: false
                        ),
                        mcpServerEnabler: { true },
                        policyInstaller: { spec in
                            await MainActor.run { counters.installed += 1 }
                            await MCPRoutingWaiter.notifyRouted(runID: spec.runID)
                        },
                        expectedPIDPolicyArmer: { _ in true },
                        policyClearer: { _ in await MainActor.run { counters.cleared += 1 } }
                    )
                    lease = result
                    return result
                }
            )
            let resources = AgentRunProviderComposition(
                headless: { _, _ in AgentSessionLinkCapturingHeadlessProvider() },
                acp: { _, _ in provider }, controller: { _, _ in controller }
            )
            await resources.fulfill(prepared)
            try await AsyncTestWait.waitUntil("fresh ACP boundary \(boundary), \(drift)") { reached }
            await task?.value
            XCTAssertNotNil(task)
            XCTAssertEqual(counters.installed, 1)
            if drift == .retire || drift == .transientConflict {
                try await barrier.awaitTerminalTeardown(for: XCTUnwrap(owner), lifecycle: session.runLifecycle)
            }
            let gate = await HeadlessAgentConnectionGate.snapshot()
            XCTAssertNotEqual(gate.activeConnectionID, gateID, "boundary=\(boundary), drift=\(drift)")
            XCTAssertEqual(consumers, drift == .none ? 1 : 0)
            let rpcText = (try? String(contentsOf: rpcLog, encoding: .utf8)) ?? ""
            if drift == .none {
                XCTAssertEqual(session.runState, .completed)
                XCTAssertTrue(rpcText.contains("session/set_config_option"))
                XCTAssertTrue(rpcText.contains("session/prompt"))
            } else {
                XCTAssertFalse(rpcText.contains("session/prompt"))
                if boundary == .bootstrapStarting { XCTAssertTrue(rpcText.isEmpty) }
                if boundary != .routingReleased, !afterConfigurationRPC { XCTAssertFalse(rpcText.contains("session/set_config_option")) }
                if afterConfigurationRPC { XCTAssertTrue(rpcText.contains("session/set_config_option")) }
                if drift == .retire || drift == .transientConflict {
                    XCTAssertEqual(session.runState, boundary == .prePromptFailure ? .failed : .cancelled)
                    XCTAssertNil(session.acpController)
                    XCTAssertEqual(counters.cleared, 1)
                } else {
                    XCTAssertEqual(session.activeRunOwnership, owner)
                    XCTAssertEqual(session.providerSessionID, identity)
                    XCTAssertEqual(session.isDirty, dirty)
                    XCTAssertEqual(session.saveRequestGeneration, saves)
                    XCTAssertNil(session.lastTerminalCommitRevision)
                    XCTAssertEqual(session.acpController === controller, drift != .detached)
                    XCTAssertEqual(counters.cleared, 0)
                    if drift == .detached {
                        let retired = await controller.isRetired
                        XCTAssertTrue(retired, "Detached late bootstrap remains the original operation's cleanup")
                    } else if boundary != .bootstrapStarting, boundary != .prePromptFailure {
                        let reusable = await controller.hasReusableSession
                        XCTAssertTrue(reusable, "The stale task must not retire the installed controller")
                    }
                    if let previousTeardown { await previousTeardown() }
                    if drift == .reacquire || drift == .successor || drift == .detached {
                        await harness.service.cancelRun(tabID: session.tabID, session: session, completion: .terminalTeardownCompleted)
                        XCTAssertEqual(session.runState, .cancelled)
                        XCTAssertEqual(counters.cleared, 1)
                        XCTAssertNil(session.acpController)
                        let reusable = await controller.hasReusableSession
                        XCTAssertFalse(reusable, "Current-owner Stop must retire the bootstrapped controller")
                    }
                }
            }
            if let lease { await lease.cancelAndCleanup() }
            await controller.shutdown()
            session.saveDebounceTask?.cancel()
        }
    }

    func testACPReusedSetupAndDeferredLeaseKeepTheirOriginalWriter() async throws {
        typealias Boundary = ACPIntegratedAgentModeRunner.StartupBoundary
        enum Drift { case reacquire, retire, transientConflict, successor, none }
        @MainActor final class Counters { var installed = 0, cleared = 0 }
        let boundaries: [Boundary] = [.reusabilityProbed, .configuration, .deferredLeaseAcquired, .routingReleased, .prePromptFailure]
        let cases = boundaries.flatMap { [($0, Drift.reacquire, false, false), ($0, Drift.retire, false, false)] }
            + [
                (.configuration, .transientConflict, false, false), (.routingReleased, .none, false, false),
                (.deferredLeaseAcquired, .reacquire, true, false), (.deferredLeaseAcquired, .retire, true, false),
                (.configuration, .reacquire, false, true), (.configuration, .retire, false, true),
                (.configuration, .successor, false, true)
            ]
        for (boundary, drift, acquireFails, dedicatedNote) in cases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let script = try AgentSessionLinkACPServerScript.write(to: directory)
            let rpcLog = directory.appendingPathComponent("requests.jsonl")
            var environment = ["ACP_RPC_LOG": rpcLog.path]
            if boundary == .prePromptFailure { environment["ACP_FAIL_METHOD"] = "session/set_config_option" }
            let provider = AgentSessionLinkCapturingACPProvider(providerID: .antigravity, commandPath: script.path, environment: environment)
            let request = ACPRunRequest(agentKind: .antigravity, modelString: nil, workspacePath: directory.path, resumeSessionID: nil, attachments: [], taskLabelKind: nil, sessionModeID: "auto_edit")
            let controller = try ACPAgentSessionController(provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true)
            addTeardownBlock { await controller.shutdown() }
            _ = try await controller.bootstrap()
            let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
            let session = try harness.makeBoundSession(agent: .antigravity)
            session.acpController = controller
            let processRunID = AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
            let origin = try harness.startCommand(for: session)
            let scope = origin.writer.scope
            harness.pendingHandoffSendOutcome = { session, sent in scope.handoff.recordSendOutcome(for: session, didSend: sent) }
            session.pendingHandoff.payload = "unsent handoff"
            session.pendingHandoff.isStagedForSend = true
            let message: String
            if dedicatedNote {
                var state = AgentSelfCompactState()
                _ = state.reserve(note: "dedicated note", idempotencyKey: "reuse-note", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes)
                state.active?.phase = .dispatchingNote
                session.selfCompactState = state
                message = AgentSelfCompactNoteEnvelope.frame("dedicated note")
            } else { message = "turn" }
            let barrier = AgentRunTerminalCommitBarrier()
            let runner = ACPIntegratedAgentModeRunner(hooks: harness.hooks, terminalCommitBarrier: barrier, toolTrackingHooks: .noOp)
            let conflicting = AgentSessionRuntimeStore.shared.makeScope()
            defer { conflicting.replaceSessions([:]) }
            var reached = false
            var task: Task<Void, Never>?
            var owner: AgentRunOwnership?
            var previousTeardown: AgentRunAttemptTerminalResources.Teardown?
            var saves: UInt64 = 0
            var dirty = false
            var consumers = 0
            runner.testPromptConsumerCreated = { consumers += 1 }
            runner.testAtStartupBoundary = { point in
                if point == boundary, reached, drift == .transientConflict {
                    conflicting.replaceSessions([:])
                    XCTAssertTrue(origin.isCurrent)
                }
                guard point == boundary, !reached else { return }
                // Cover the post-RPC configuration gate, not just its entry check.
                if boundary == .configuration, drift != .transientConflict {
                    let text = (try? String(contentsOf: rpcLog, encoding: .utf8)) ?? ""
                    guard text.contains("session/set_config_option") else { return }
                }
                reached = true
                task = session.agentTask
                saves = session.saveRequestGeneration
                dirty = session.isDirty
                switch drift {
                case .reacquire:
                    var members = scope.sessions
                    members.removeValue(forKey: session.tabID)
                    scope.replaceSessions(members)
                    members[session.tabID] = session
                    scope.replaceSessions(members)
                case .retire:
                    scope.beginRetirement()
                case .transientConflict:
                    let duplicate = conflicting.makeSession(tabID: UUID())
                    duplicate.installPersistentSessionBinding(.init(tabID: duplicate.tabID, sessionID: origin.identity.sessionID, workspaceID: origin.identity.workspaceID))
                    conflicting.replaceSessions([duplicate.tabID: duplicate])
                case .successor:
                    if let previous = session.activeRunOwnership {
                        previousTeardown = session.claimRunAttemptTerminalTeardown(ownership: previous, terminalState: .cancelled)
                    }
                    _ = session.beginRunAttempt(source: "successor dedicated note")
                case .none:
                    break
                }
                owner = session.activeRunOwnership
            }
            let counters = Counters()
            let gateID = UUID()
            var lease: MCPBootstrapLease?
            let prepared = await runner.prepareRun(
                tabID: session.tabID, session: session, origin: origin, workspace: harness.workspace,
                initialUserMessage: message, initialMessageForRun: message, attachments: [], runRequest: request,
                makeLease: { runID in
                    let value = MCPBootstrapLease(
                        spec: MCPBootstrapLeaseSpec(runID: runID, gateID: gateID, windowID: 1, tabID: session.tabID, clientName: "RepoPromptCE", restrictedTools: [], additionalTools: nil, oneShot: true, reason: "reused setup writer test", ttl: 60, purpose: .agentModeRun, taskLabelKind: nil, allowsAgentExternalControlTools: false, requiresExpectedAgentPID: false),
                        mcpServerEnabler: { !acquireFails },
                        policyInstaller: { spec in
                            await MainActor.run { counters.installed += 1 }
                            await MCPRoutingWaiter.notifyRouted(runID: spec.runID)
                        },
                        expectedPIDPolicyArmer: { _ in true },
                        policyClearer: { _ in await MainActor.run { counters.cleared += 1 } }
                    )
                    lease = value
                    return value
                }
            )
            XCTAssertNil(prepared, "A warm controller requires no provider construction")
            XCTAssertNotNil(lease, "Reused fixture needs a deferred lease")
            try await AsyncTestWait.waitUntil("reused ACP boundary \(boundary), \(drift)") { reached }
            await task?.value
            XCTAssertNotNil(task)
            if drift == .retire || drift == .transientConflict {
                try await barrier.awaitTerminalTeardown(for: XCTUnwrap(owner), lifecycle: session.runLifecycle)
            }
            let gate = await HeadlessAgentConnectionGate.snapshot()
            XCTAssertNotEqual(gate.activeConnectionID, gateID)
            XCTAssertEqual(consumers, drift == .none ? 1 : 0)
            let rpcText = (try? String(contentsOf: rpcLog, encoding: .utf8)) ?? ""
            XCTAssertEqual(rpcText.contains("session/prompt"), drift == .none)
            if drift == .none {
                XCTAssertEqual(session.runState, .completed)
            } else if drift == .retire || drift == .transientConflict {
                XCTAssertEqual(session.runState, boundary == .prePromptFailure ? .failed : .cancelled)
                if boundary == .prePromptFailure { XCTAssertNil(session.acpController) }
                else {
                    XCTAssertTrue(session.acpController === controller)
                    XCTAssertEqual(session.runID, processRunID)
                    let reusable = await controller.hasReusableSession
                    XCTAssertTrue(reusable)
                    XCTAssertFalse(session.pendingHandoff.isStagedForSend)
                }
                if dedicatedNote { XCTAssertEqual(session.selfCompactState.active?.phase, .parked) }
                if boundary == .deferredLeaseAcquired, !acquireFails {
                    XCTAssertEqual(counters.installed, 1)
                    XCTAssertEqual(counters.cleared, 1)
                }
            } else {
                XCTAssertEqual(session.activeRunOwnership, owner)
                XCTAssertEqual(session.saveRequestGeneration, saves)
                XCTAssertEqual(session.isDirty, dirty)
                XCTAssertNil(session.lastTerminalCommitRevision)
                XCTAssertTrue(session.acpController === controller)
                if dedicatedNote { XCTAssertEqual(session.selfCompactState.active?.phase, .dispatchingNote) }
                if !acquireFails { XCTAssertEqual(counters.cleared, 0) }
                if boundary == .deferredLeaseAcquired, !acquireFails { XCTAssertEqual(counters.installed, 1) }
                if let previousTeardown { await previousTeardown() }
                await harness.service.cancelRun(tabID: session.tabID, session: session, completion: .terminalTeardownCompleted)
                XCTAssertEqual(session.runState, .cancelled)
                XCTAssertNil(session.acpController)
                let reusable = await controller.hasReusableSession
                XCTAssertFalse(reusable, "Current-owner Stop must retire the installed controller")
                if boundary == .deferredLeaseAcquired, !acquireFails { XCTAssertEqual(counters.cleared, 1) }
            }
            if let lease { await lease.cancelAndCleanup() }
            await controller.shutdown()
            session.saveDebounceTask?.cancel()
        }
    }

    func testACPStoppedReusedSetupReparksOnlyItsOriginalDedicatedNote() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try AgentSessionLinkACPServerScript.write(to: directory)
        let gate = try AgentSessionLinkACPResponseGate(directory: directory)
        defer { gate.release() }
        let provider = AgentSessionLinkCapturingACPProvider(providerID: .antigravity, commandPath: script.path, environment: ["ACP_HOLD_METHOD": "session/set_config_option", "ACP_RESPONSE_GATE": gate.path])
        let request = ACPRunRequest(agentKind: .antigravity, modelString: nil, workspacePath: directory.path, resumeSessionID: nil, attachments: [], taskLabelKind: nil, sessionModeID: "auto_edit")
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true)
        addTeardownBlock { await controller.shutdown() }
        _ = try await controller.bootstrap()
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
        let session = try harness.makeBoundSession(agent: .antigravity)
        session.acpController = controller
        _ = AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
        var state = AgentSelfCompactState()
        _ = state.reserve(note: "stopped note", idempotencyKey: "stopped-reuse", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes)
        state.active?.phase = .dispatchingNote
        session.selfCompactState = state
        let message = AgentSelfCompactNoteEnvelope.frame("stopped note")
        let runner = ACPIntegratedAgentModeRunner(hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier(), toolTrackingHooks: .noOp)
        _ = try await runner.prepareRun(
            tabID: session.tabID, session: session, origin: harness.startCommand(for: session), workspace: harness.workspace,
            initialUserMessage: message, initialMessageForRun: message, attachments: [], runRequest: request,
            makeLease: { harness.makeLease(runID: $0, tabID: session.tabID) }
        )
        let task = try XCTUnwrap(session.agentTask)
        let owner = try XCTUnwrap(session.activeRunOwnership)
        try await gate.waitUntilEntered()
        await harness.service.cancelRun(tabID: session.tabID, session: session, completion: .terminalTeardownCompleted)
        gate.release()
        await task.value
        XCTAssertEqual(session.lastTerminalCommitRevision?.ownership, owner)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertEqual(session.runState, .cancelled)
        XCTAssertEqual(session.selfCompactState.active?.phase, .parked)
        await controller.shutdown()
        session.saveDebounceTask?.cancel()
    }

    func testACPTaskEntryAndLeaseCompletionKeepTheirOriginalWriter() async throws {
        typealias Boundary = ACPIntegratedAgentModeRunner.StartupBoundary
        @MainActor final class Counters {
            var installed = 0, cleared = 0, enabled = 0
        }
        let cases: [(Boundary, Bool, Bool)] = [
            (.taskEntry, false, false), (.toolTrackingCompleted, false, false),
            (.taskEntry, true, false), (.toolTrackingCompleted, true, false),
            (.leaseAcquired, false, false), (.acquireFailureOutcome, false, false),
            (.taskEntry, false, true), (.taskEntry, true, true), (.leaseAcquired, false, true),
            (.toolTrackingCompleted, false, true), (.toolTrackingCompleted, true, true),
            (.acquireFailureOutcome, false, true)
        ]
        for (boundary, reused, retiring) in cases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let script = try AgentSessionLinkACPServerScript.write(to: directory)
            let rpcLog = directory.appendingPathComponent("requests.jsonl")
            let provider = AgentSessionLinkCapturingACPProvider(providerID: .antigravity, commandPath: script.path, environment: ["ACP_RPC_LOG": rpcLog.path])
            let request = ACPRunRequest(agentKind: .antigravity, modelString: nil, workspacePath: directory.path, resumeSessionID: nil, attachments: [], taskLabelKind: nil)
            let controller = try ACPAgentSessionController(provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true)
            addTeardownBlock { await controller.shutdown() }
            if reused { _ = try await controller.bootstrap() }
            let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
            let session = try harness.makeBoundSession(agent: .antigravity)
            if reused {
                session.acpController = controller
                _ = AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
            }
            let origin = try harness.startCommand(for: session)
            let scope = origin.writer.scope
            harness.pendingHandoffSendOutcome = { session, sent in scope.handoff.recordSendOutcome(for: session, didSend: sent) }
            session.pendingHandoff.payload = "unsent handoff"
            session.pendingHandoff.isStagedForSend = true
            let input = AgentChatItem.user("turn", sequenceIndex: session.nextSequenceIndex)
            session.appendItem(input)
            let candidate = session.registerLocalComposerCandidate(itemID: input.id, at: session.items.count - 1)
            let barrier = AgentRunTerminalCommitBarrier()
            let runner = ACPIntegratedAgentModeRunner(hooks: harness.hooks, terminalCommitBarrier: barrier, toolTrackingHooks: .noOp)
            var reached = false
            var task: Task<Void, Never>?
            var owner: AgentRunOwnership?
            var dirty = false
            var saves: UInt64 = 0
            runner.testAtStartupBoundary = { point in
                guard point == boundary else { return }
                reached = true
                task = session.agentTask
                owner = session.activeRunOwnership
                dirty = session.isDirty
                saves = session.saveRequestGeneration
                if retiring {
                    scope.beginRetirement()
                } else {
                    var members = scope.sessions
                    members.removeValue(forKey: session.tabID)
                    scope.replaceSessions(members)
                    members[session.tabID] = session
                    scope.replaceSessions(members)
                }
            }
            let gateID = UUID()
            let counters = Counters()
            var lease: MCPBootstrapLease?
            let prepared = await runner.prepareRun(
                tabID: session.tabID, session: session, origin: origin, workspace: harness.workspace,
                initialUserMessage: "turn", initialMessageForRun: "turn", attachments: [], runRequest: request,
                makeLease: { runID in
                    let result = MCPBootstrapLease(
                        spec: MCPBootstrapLeaseSpec(
                            runID: runID, gateID: gateID, windowID: 1, tabID: session.tabID,
                            clientName: "RepoPromptCE", restrictedTools: [], additionalTools: nil,
                            oneShot: true, reason: "writer receipt test", ttl: 60, purpose: .agentModeRun,
                            taskLabelKind: nil, allowsAgentExternalControlTools: false, requiresExpectedAgentPID: false
                        ),
                        mcpServerEnabler: {
                            await MainActor.run { counters.enabled += 1 }
                            return boundary != .acquireFailureOutcome
                        },
                        policyInstaller: { _ in await MainActor.run { counters.installed += 1 } },
                        expectedPIDPolicyArmer: { _ in true },
                        policyClearer: { _ in await MainActor.run { counters.cleared += 1 } }
                    )
                    lease = result
                    return result
                }, localComposerCandidate: candidate
            )
            let resources = AgentRunProviderComposition(
                headless: { _, _ in AgentSessionLinkCapturingHeadlessProvider() },
                acp: { _, _ in provider }, controller: { _, _ in controller }
            )
            await resources.fulfill(prepared)
            try await AsyncTestWait.waitUntil("persistent ACP task reaches its writer boundary") { reached }
            await task?.value
            XCTAssertNotNil(task)
            if retiring {
                let ownership = try XCTUnwrap(owner)
                await barrier.awaitTerminalTeardown(for: ownership, lifecycle: session.runLifecycle)
            }
            XCTAssertEqual(counters.enabled, boundary == .leaseAcquired || boundary == .acquireFailureOutcome ? 1 : 0)
            XCTAssertEqual(counters.installed, boundary == .leaseAcquired ? 1 : 0)
            let gate = await HeadlessAgentConnectionGate.snapshot()
            XCTAssertNotEqual(gate.activeConnectionID, gateID, "A stale task cannot retain the process-wide bootstrap gate")
            if retiring {
                XCTAssertEqual(session.runState, .cancelled)
                XCTAssertEqual(session.test_unsettledLocalComposerCandidateCount, 0)
                XCTAssertEqual(session.items.first(where: { $0.id == input.id })?.userInputOrigin, .localComposer)
                XCTAssertFalse(session.pendingHandoff.isStagedForSend)
                XCTAssertEqual(session.pendingHandoff.payload, "unsent handoff")
                if reused {
                    XCTAssertTrue(session.acpController === controller)
                    let reusable = await controller.hasReusableSession
                    XCTAssertTrue(reusable)
                } else { XCTAssertNil(session.acpController) }
            } else {
                XCTAssertEqual(session.activeRunOwnership, owner)
                XCTAssertEqual(session.isDirty, dirty)
                XCTAssertEqual(session.saveRequestGeneration, saves)
                XCTAssertNil(session.lastTerminalCommitRevision)
                XCTAssertTrue(session.acpController === controller)
                XCTAssertEqual(counters.cleared, 0, "The old task must not revoke the shared attempt's policy")
                XCTAssertEqual(session.test_unsettledLocalComposerCandidateCount, 1)
                XCTAssertNil(session.items.first(where: { $0.id == input.id })?.userInputOrigin)
                if reused {
                    let reusable = await controller.hasReusableSession
                    XCTAssertTrue(reusable)
                } else {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: rpcLog.path), "No provider request may follow lost admission")
                }
                await harness.service.cancelRun(tabID: session.tabID, session: session, completion: .terminalTeardownCompleted)
                XCTAssertEqual(session.runState, .cancelled)
            }
            if boundary == .leaseAcquired { XCTAssertEqual(counters.cleared, 1, "retiring=\(retiring), reused=\(reused)") }
            if let lease { await lease.cancelAndCleanup() }
            await controller.shutdown()
            session.saveDebounceTask?.cancel()
        }
    }

    func testExistingACPControllerProbesCannotAdoptAReacquiredWriter() async throws {
        typealias Probe = ACPIntegratedAgentModeRunner.ExistingControllerProbe
        let cases: [(Probe, Bool, Bool, Bool)] = [
            (.compatibility, false, false, false), (.reusability, false, false, false),
            (.replacementShutdown, false, false, false), (.controlCommand, false, false, false),
            (.compatibility, true, false, false), (.reusability, true, false, false),
            (.replacementShutdown, true, false, false), (.controlCommand, true, false, false),
            (.replacementShutdown, false, true, false), (.compatibility, false, false, true)
        ]
        for (probe, retire, unchanged, successorAttempt) in cases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let script = try AgentSessionLinkACPServerScript.write(to: directory)
            let provider = AgentSessionLinkCapturingACPProvider(providerID: .antigravity, commandPath: script.path)
            let request = ACPRunRequest(agentKind: .antigravity, modelString: nil, workspacePath: directory.path, resumeSessionID: nil, attachments: [], taskLabelKind: nil)
            let controller = try ACPAgentSessionController(provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true)
            _ = try await controller.bootstrap()
            addTeardownBlock { await controller.shutdown() }
            let initiallyReusable = await controller.hasReusableSession
            XCTAssertTrue(initiallyReusable)
            let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
            let session = try harness.makeBoundSession(agent: .antigravity)
            session.acpController = controller
            _ = AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
            let origin = try harness.startCommand(for: session)
            let scope = origin.writer.scope
            harness.pendingHandoffSendOutcome = { session, sent in scope.handoff.recordSendOutcome(for: session, didSend: sent) }
            session.pendingHandoff.payload = "retained handoff"
            session.pendingHandoff.isStagedForSend = true
            let runner = ACPIntegratedAgentModeRunner(hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier(), toolTrackingHooks: .noOp)
            var reached = false
            var owner: AgentRunOwnership?
            var runID: UUID?
            var dirty = false
            var saveGeneration: UInt64 = 0
            runner.testAfterExistingControllerProbe = { point in
                guard point == probe else { return }
                reached = true
                owner = session.activeRunOwnership
                runID = session.runID
                dirty = session.isDirty
                saveGeneration = session.saveRequestGeneration
                if successorAttempt {
                    _ = session.beginRunAttempt(source: "successor during controller probe")
                    owner = session.activeRunOwnership
                } else if retire {
                    scope.beginRetirement()
                } else if !unchanged {
                    var sessions = scope.sessions
                    sessions.removeValue(forKey: session.tabID)
                    scope.replaceSessions(sessions)
                    sessions[session.tabID] = session
                    scope.replaceSessions(sessions)
                }
            }
            var leases: [MCPBootstrapLease] = []
            let outcome = AgentRunStartOutcomeRecorder()
            // A changed logical workspace takes the replacement path after the same real actor probes.
            let nextRequest = probe == .replacementShutdown
                ? ACPRunRequest(agentKind: .antigravity, modelString: nil, workspacePath: directory.appendingPathComponent("other").path, resumeSessionID: nil, attachments: [], taskLabelKind: nil)
                : request
            let control: AgentProviderControlCommand? = probe == .controlCommand
                ? .compact(expectedBinding: origin.writer.binding, expectedProviderConversation: "fixture") : nil
            let prepared: AgentRunResourceRequest?
            if successorAttempt {
                harness.service.testAfterACPExistingControllerProbe = runner.testAfterExistingControllerProbe
                let result = await harness.service.prepareRun(
                    tabID: session.tabID, session: session, origin: origin, workspace: harness.workspace,
                    initialUserMessage: "turn", initialMessageForRun: "turn", attachments: [], startOutcome: outcome
                )
                if case .completed = result { prepared = nil } else {
                    XCTFail("A superseded probe cannot return resource construction")
                    prepared = nil
                }
            } else {
                prepared = await runner.prepareRun(
                    tabID: session.tabID, session: session, origin: origin, workspace: harness.workspace,
                    initialUserMessage: "turn", initialMessageForRun: "turn", attachments: [], runRequest: nextRequest,
                    startOutcome: outcome, providerControlCommand: control,
                    makeLease: { runID in
                        let lease = harness.makeLease(runID: runID, tabID: session.tabID)
                        leases.append(lease)
                        return lease
                    }
                )
            }
            XCTAssertTrue(reached)
            XCTAssertNil(session.agentTask)
            if unchanged {
                XCTAssertNotNil(prepared, "An unchanged writer may prepare replacement resources")
                XCTAssertEqual(leases.count, 1)
            } else {
                XCTAssertNil(prepared)
                XCTAssertTrue(leases.isEmpty, "Refused probes cannot mint a fresh routing lease")
                XCTAssertTrue(outcome.hasRecordedOutcome)
                XCTAssertFalse(outcome.outcome.didStart)
                if retire {
                    XCTAssertEqual(session.runState, .cancelled)
                    XCTAssertEqual(AgentModeProcessRunIdentity.existingProcessRunID(for: session), runID)
                    XCTAssertEqual(session.pendingHandoff.payload, "retained handoff")
                    XCTAssertFalse(session.pendingHandoff.isStagedForSend, "An owned refusal reparks the unsent handoff")
                } else {
                    XCTAssertEqual(session.activeRunOwnership, owner)
                    XCTAssertEqual(session.runID, runID)
                    XCTAssertEqual(session.isDirty, dirty)
                    XCTAssertEqual(session.saveRequestGeneration, saveGeneration)
                    XCTAssertNil(session.lastTerminalCommitRevision)
                }
            }
            let reusable = await controller.hasReusableSession
            if probe == .replacementShutdown {
                XCTAssertNil(session.acpController)
                XCTAssertFalse(reusable, "Only the controller detached before the await is retired")
            } else {
                XCTAssertTrue(session.acpController === controller)
                XCTAssertTrue(reusable, "Claim loss or suspended admission cannot retire the shared controller")
            }
            if !retire {
                await harness.service.cancelRun(tabID: session.tabID, session: session, completion: .terminalTeardownCompleted)
                XCTAssertEqual(session.runState, .cancelled)
            }
            await harness.resources.fulfill(prepared) // Cancelled preparation settles without constructing.
            for lease in leases {
                await lease.cancelAndCleanup()
            }
            await controller.shutdown()
            session.saveDebounceTask?.cancel()
        }
    }

    func testWorkspaceAdmissionRetainsLogicalRootAndRevalidatesWorktreeAndBinding() throws {
        let session = AgentTabSession(tabID: UUID())
        let sessionID = UUID()
        session.testInstallPersistentSessionBinding(sessionID: sessionID)
        let ownership = session.beginRunAttempt(source: "workspace admission")
        let input = AgentRunWorkspaceInput(fallbackWorkspacePath: "/captured/logical-root")
        let admission = AgentACPWorkspaceAdmission(
            input: input, ownership: ownership, session: session
        )
        XCTAssertTrue(admission.isCurrent(for: session))
        XCTAssertEqual(try admission.input.resolve(bindings: []), "/captured/logical-root")
        let missing = AgentSessionWorktreeBinding(
            id: "binding", repositoryID: "repository", repoKey: "repository",
            logicalRootPath: "/captured/logical-root", worktreeID: "worktree",
            worktreeRootPath: "/nonexistent-m9-worktree-\(UUID().uuidString)", source: "test"
        )
        XCTAssertThrowsError(try admission.input.resolve(bindings: [missing]), "A captured root is not cached filesystem authority")
        session.testInstallPersistentSessionBinding(sessionID: sessionID)
        XCTAssertFalse(admission.isCurrent(for: session), "Same session UUID with a new binding cannot reuse the admitted workspace")
        XCTAssertEqual(session.activeRunOwnership, ownership)
        _ = session.beginPersistentBindingTransition()
        let duringTransition = AgentACPWorkspaceAdmission(
            input: input, ownership: ownership, session: session
        )
        XCTAssertFalse(duringTransition.isCurrent(for: session), "Matching values do not admit a binding transition in progress")

        // Runtime-only attempts have no restoration token. Their existing transition generation
        // still fences an old admission after a nil-to-nil binding transition settles.
        let runtimeOnly = AgentTabSession(tabID: UUID())
        let runtimeOwner = runtimeOnly.beginRunAttempt(source: "runtime-only workspace")
        let runtimeAdmission = AgentACPWorkspaceAdmission(input: input, ownership: runtimeOwner, session: runtimeOnly)
        XCTAssertTrue(runtimeAdmission.isCurrent(for: runtimeOnly))
        let transition = runtimeOnly.beginPersistentBindingTransition()
        runtimeOnly.finishPersistentBindingTransition(generation: transition)
        XCTAssertNil(runtimeOnly.currentRestorationBindingToken)
        XCTAssertFalse(runtimeAdmission.isCurrent(for: runtimeOnly))
    }

    func testPreparedHeadlessConstructionIsOneShotAndStopFencesFactoryInvocation() async throws {
        var constructions = 0
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in
            constructions += 1
            return AgentSessionLinkCapturingHeadlessProvider()
        })
        let session = harness.makeSession(agent: .claudeCode)
        let runner = harness.makeHeadlessRunner()
        let request = await runner.prepareRun(
            tabID: session.tabID, session: session, initialUserMessage: "turn",
            initialMessageForRun: "turn", attachments: [],
            makeLease: { harness.makeLease(runID: $0, tabID: session.tabID) }
        )
        let prepared = try XCTUnwrap(request)
        XCTAssertEqual(constructions, 0, "Execution must not construct a provider while admitting the turn")
        await harness.service.cancelRun(tabID: session.tabID, session: session, completion: .terminalTeardownCompleted)
        await harness.resources.fulfill(prepared)
        await harness.resources.fulfill(prepared)
        XCTAssertEqual(constructions, 0, "A cancelled preparation cannot construct, including a repeated delivery")
        XCTAssertNil(session.provider)
        XCTAssertEqual(session.runState, .cancelled)
    }

    func testStoppedACPProviderConstructionCannotConstructControllerOrInstallSuccessor() async throws {
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
        let session = try harness.makeBoundSession(agent: .devin)
        let origin = try harness.startCommand(for: session)
        let runner = ACPIntegratedAgentModeRunner(hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier(), toolTrackingHooks: .noOp)
        let provider = AgentSessionLinkCapturingACPProvider(providerID: .devin, commandPath: "/usr/bin/false")
        let entered = expectation(description: "Provider construction held outside execution")
        var release: CheckedContinuation<Void, Never>?
        defer { release?.resume() }
        var providerConstructions = 0
        var controllerConstructions = 0
        let resources = AgentRunProviderComposition(
            headless: { _, _ in AgentSessionLinkCapturingHeadlessProvider() },
            acp: { _, _ in
                providerConstructions += 1
                await withCheckedContinuation { continuation in
                    release = continuation
                    entered.fulfill()
                }
                return provider
            },
            controller: { provider, request in
                controllerConstructions += 1
                return try ACPAgentSessionController(provider: provider, runRequest: request)
            }
        )
        let prepared = await runner.prepareRun(
            tabID: session.tabID, session: session, origin: origin, workspace: .init(fallbackWorkspacePath: nil), initialUserMessage: "turn", initialMessageForRun: "turn", attachments: [],
            runRequest: ACPRunRequest(agentKind: .devin, modelString: nil, workspacePath: nil, resumeSessionID: nil, attachments: [], taskLabelKind: nil),
            makeLease: { harness.makeLease(runID: $0, tabID: session.tabID) }
        )
        XCTAssertNotNil(prepared)
        XCTAssertEqual(providerConstructions, 0)
        let construction = Task { await resources.fulfill(prepared) }
        await fulfillment(of: [entered], timeout: 3)
        await resources.fulfill(prepared)
        XCTAssertEqual(providerConstructions, 1, "Repeated delivery during construction cannot invoke a second factory")
        await harness.service.cancelRun(tabID: session.tabID, session: session, completion: .terminalTeardownCompleted)
        let terminal = session.lastTerminalCommitRevision
        release?.resume()
        release = nil
        await construction.value
        await resources.fulfill(prepared)
        XCTAssertEqual(providerConstructions, 1)
        XCTAssertEqual(controllerConstructions, 0)
        XCTAssertEqual(provider.supportCallCount, 0, "A stale provider must not perform support work")
        XCTAssertNil(session.acpController)
        XCTAssertEqual(session.lastTerminalCommitRevision, terminal)
        XCTAssertEqual(session.runState, .cancelled)
        XCTAssertTrue(provider.promptedMessages.isEmpty)
    }

    override func setUp() {
        super.setUp()
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
    }

    func testCompletedTerminalUsesSharedExecutionClassification() async {
        let classification = await ACPIntegratedAgentModeRunner.testClassifyTransientTerminal(
            state: .completed,
            errorText: nil
        )

        XCTAssertEqual(
            classification.result,
            .terminal(.completed(assistantText: nil))
        )
        XCTAssertNil(classification.errorText)
        XCTAssertEqual(
            classification.trace,
            [.executionStarted, .terminalOutcomeProduced(.completed)]
        )
    }

    func testCancelledTerminalUsesSharedExecutionClassification() async {
        let classification = await ACPIntegratedAgentModeRunner.testClassifyTransientTerminal(
            state: .cancelled,
            errorText: nil
        )

        XCTAssertEqual(
            classification.result,
            .terminal(.cancelled())
        )
        XCTAssertNil(classification.errorText)
        XCTAssertEqual(
            classification.trace,
            [.executionStarted, .terminalOutcomeProduced(.cancelled)]
        )
    }

    func testFailedTerminalPreservesProviderErrorText() async {
        let classification = await ACPIntegratedAgentModeRunner.testClassifyTransientTerminal(
            state: .failed,
            errorText: "ACP provider refused the turn."
        )

        XCTAssertEqual(
            classification.result,
            .terminal(.failed(assistantText: "ACP provider refused the turn."))
        )
        XCTAssertEqual(classification.errorText, "ACP provider refused the turn.")
        XCTAssertEqual(
            classification.trace,
            [.executionStarted, .terminalOutcomeProduced(.failed)]
        )
    }

    func testFailedTerminalPreservesAbsentProviderErrorTextForSettlement() async {
        let classification = await ACPIntegratedAgentModeRunner.testClassifyTransientTerminal(
            state: .failed,
            errorText: nil
        )

        guard case let .terminal(outcome) = classification.result else {
            return XCTFail("Expected terminal classification")
        }
        XCTAssertEqual(outcome.kind, .failed)
        XCTAssertNil(classification.errorText)
        XCTAssertEqual(
            classification.trace,
            [.executionStarted, .terminalOutcomeProduced(.failed)]
        )
    }

    func testSupersededExecutionRemainsNonterminal() async {
        let classification = await ACPIntegratedAgentModeRunner.testClassifyTransientSupersession()

        XCTAssertEqual(classification.result, .superseded)
        XCTAssertNil(classification.errorText)
        XCTAssertEqual(
            classification.trace,
            [.executionStarted, .executionSuperseded]
        )
    }

    func testConfigurationSequenceStopsAfterOwnershipChangesDuringAwaitedStep() async throws {
        var isCurrent = true
        var providerMutations: [String] = []

        let completed = try await ACPIntegratedAgentModeRunner.testPerformConfigurationSequenceIfCurrent(
            isCurrent: { isCurrent },
            operations: [
                {
                    providerMutations.append("model")
                    await Task.yield()
                    isCurrent = false
                },
                {
                    providerMutations.append("parameters")
                }
            ]
        )

        XCTAssertFalse(completed)
        XCTAssertEqual(providerMutations, ["model"])
    }

    func testModelParameterApplicationAcceptsAppliedAndAlreadyCurrentSelections() throws {
        let selection = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .thinking,
            configID: "thought_level",
            valueRaw: "high"
        )

        XCTAssertNoThrow(try ACPIntegratedAgentModeRunner.testValidateModelParameterApplicationReport(.init(
            applied: [selection],
            alreadyCurrent: [],
            skipped: []
        )))
        XCTAssertNoThrow(try ACPIntegratedAgentModeRunner.testValidateModelParameterApplicationReport(.init(
            applied: [],
            alreadyCurrent: [selection],
            skipped: []
        )))
    }

    func testModelParameterApplicationRejectsStaleUnsupportedSelectionBeforePrompt() {
        let selection = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .speed,
            configID: "fast",
            valueRaw: "true"
        )

        XCTAssertThrowsError(try ACPIntegratedAgentModeRunner.testValidateModelParameterApplicationReport(.init(
            applied: [],
            alreadyCurrent: [],
            skipped: [selection]
        ))) { error in
            XCTAssertTrue(error.localizedDescription.contains("stale or unsupported"))
            XCTAssertTrue(error.localizedDescription.contains("fast=true"))
        }
    }

    func testCursorKnownModelPassesReleaseCatalogValidationBeforePrompt() throws {
        let model = try ACPIntegratedAgentModeRunner.testExplicitSelectedModel(
            agentKind: .cursor,
            modelString: "grok-4.6"
        )

        XCTAssertEqual(model, "grok-4.6")
    }

    func testCursorAutoAliasPassesReleaseCatalogValidationBeforePrompt() throws {
        let model = try ACPIntegratedAgentModeRunner.testExplicitSelectedModel(
            agentKind: .cursor,
            modelString: AgentModel.cursorAuto.rawValue
        )

        XCTAssertEqual(model, AgentModel.cursorAuto.rawValue)
    }

    func testCursorNewConcreteModelReachesRuntimeValidationWithoutReleaseGate() throws {
        XCTAssertEqual(try ACPIntegratedAgentModeRunner.testExplicitSelectedModel(
            agentKind: .cursor,
            modelString: "grok-4.7"
        ), "grok-4.7")
    }
}

final class AgentToolResultPayloadRetentionTests: XCTestCase {
    func testNormalizedEmptyTerminalUpdatesFinishStreamedLifecycleWithoutErasingContent() throws {
        let running = #"{"status":"running","content":"streamed result"}"#
        for output in ["", " \n", "[]", "{}", "null", "\"\""] {
            let events = ACPDefaultSessionUpdateNormalizer.normalize([
                "sessionUpdate": "tool_call_update", "toolCallId": "empty-terminal",
                "status": "completed", "rawOutput": output
            ], providerID: .devin)
            guard case let .stream(result) = events.first else { return XCTFail("Missing result for \(output)") }
            let incoming = try XCTUnwrap(result.toolResultJSON)
            XCTAssertEqual(AgentToolResultPayloadRetention.terminalMarkerStatus(incoming), "completed", output)
            let retained = AgentToolResultPayloadRetention.resolvedPayload(
                existing: running, incoming: incoming, incomingIsError: result.toolIsError
            ) ?? running
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(retained.utf8)) as? [String: Any])
            XCTAssertEqual(object["status"] as? String, "completed", output)
            XCTAssertEqual(object["content"] as? String, "streamed result", output)
        }
    }

    func testDecodedEmptyTerminalCollectionsFinishStreamedLifecycle() throws {
        let running = #"{"status":"running","content":"streamed result"}"#
        for output in ["[]", "{}", "null"] {
            let wire = #"{"sessionUpdate":"tool_call_update","toolCallId":"decoded-empty","status":"completed","rawOutput":OUTPUT}"#.replacingOccurrences(of: "OUTPUT", with: output)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(wire.utf8)) as? [String: Any])
            let events = ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: .devin)
            guard case let .stream(result) = events.first else { return XCTFail("Missing result for \(output)") }
            let incoming = try XCTUnwrap(result.toolResultJSON)
            XCTAssertEqual(AgentToolResultPayloadRetention.terminalMarkerStatus(incoming), "completed", output)
            let retained = AgentToolResultPayloadRetention.resolvedPayload(
                existing: running, incoming: incoming, incomingIsError: result.toolIsError,
                requireObjectReplacement: true
            ) ?? running
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(retained.utf8)) as? [String: Any])
            XCTAssertEqual(object["status"] as? String, "completed", output)
            XCTAssertEqual(object["content"] as? String, "streamed result", output)
        }
    }

    func testNormalizedTerminalUpdatesPreserveSubstantiveOutputAndFailurePrecedence() throws {
        for status in ["completed", "failed"] {
            let events = ACPDefaultSessionUpdateNormalizer.normalize([
                "sessionUpdate": "tool_call_update", "toolCallId": "terminal-output",
                "status": status, "rawOutput": ["message": "real output"]
            ], providerID: .devin)
            guard case let .stream(result) = events.first else { return XCTFail("Missing terminal event") }
            let incoming = try XCTUnwrap(result.toolResultJSON)
            XCTAssertTrue(incoming.contains("real output"))
            XCTAssertEqual(result.toolIsError, status == "failed")
            XCTAssertEqual(AgentToolResultPayloadRetention.resolvedPayload(
                existing: #"{"response":"old"}"#, incoming: incoming, incomingIsError: result.toolIsError,
                requireObjectReplacement: true
            ), incoming)
        }
        let events = ACPDefaultSessionUpdateNormalizer.normalize([
            "sessionUpdate": "tool_call_update", "toolCallId": "failed-empty", "status": "failed", "rawOutput": "[]"
        ], providerID: .devin)
        guard case let .stream(result) = events.first else { return XCTFail("Missing failed event") }
        let incoming = try XCTUnwrap(result.toolResultJSON)
        XCTAssertEqual(AgentToolResultPayloadRetention.terminalMarkerStatus(incoming), "failed")
        XCTAssertEqual(AgentToolResultPayloadRetention.resolvedPayload(
            existing: #"{"response":"old"}"#, incoming: incoming, incomingIsError: result.toolIsError,
            requireObjectReplacement: true
        ), incoming)
    }

    func testLateNormalizedRunningContentCannotReplaceAuthoritativeRepoPromptResult() throws {
        let authoritative = #"{"status":"partial_failure","oracle_count":2,"response":"authoritative"}"#
        let events = ACPDefaultSessionUpdateNormalizer.normalize([
            "sessionUpdate": "tool_call_update", "toolCallId": "oracle-call", "status": "running",
            "content": [["type": "text", "text": "provider echo"]]
        ], providerID: .devin)
        guard case let .stream(result) = events.first else { return XCTFail("Missing running event") }
        let incoming = try XCTUnwrap(result.toolResultJSON)
        XCTAssertNil(AgentToolResultPayloadRetention.resolvedPayload(
            existing: authoritative, incoming: incoming, incomingIsError: result.toolIsError,
            requireObjectReplacement: true
        ))
        // Generic tools still need content-bearing running updates, as do native progress placeholders.
        XCTAssertEqual(AgentToolResultPayloadRetention.resolvedPayload(
            existing: #"{"status":"running","title":"Oracle"}"#, incoming: incoming,
            incomingIsError: false, requireObjectReplacement: true
        ), incoming)
        XCTAssertEqual(AgentToolResultPayloadRetention.resolvedPayload(
            existing: #"{"status":"running","content":"earlier"}"#, incoming: incoming,
            incomingIsError: false
        ), incoming)
    }

    @MainActor
    func testNormalizedTrackerSequenceKeepsOneCompletedResultCard() throws {
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
        let session = harness.makeSession(agent: .devin)
        let runner = ACPIntegratedAgentModeRunner(
            hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier(),
            toolTrackingHooks: .noOp
        )
        func deliver(status: String, output: Any? = nil, content: Any? = nil) throws {
            var update: [String: Any] = [
                "sessionUpdate": "tool_call_update", "toolCallId": "same-oracle-call", "status": status
            ]
            update["rawOutput"] = output
            update["content"] = content
            let events = ACPDefaultSessionUpdateNormalizer.normalize(update, providerID: .devin)
            guard case let .stream(result) = events.first else { return XCTFail("Missing normalized update") }
            try runner.testHandleTrackerToolResult(
                invocationID: XCTUnwrap(result.toolInvocationID), toolName: "ask_oracle",
                args: status == "running" ? ["message": .string("review")] : nil,
                resultJSON: XCTUnwrap(result.toolResultJSON), isError: result.toolIsError == true,
                session: session
            )
        }
        try deliver(status: "running", content: [["type": "text", "text": "streamed finding"]])
        let rowID = try XCTUnwrap(session.items.first).id
        try deliver(status: "completed", output: "[]")
        XCTAssertEqual(session.items.count, 1)
        let finished = try XCTUnwrap(session.items.first)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(finished.toolResultJSON).utf8)) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "completed")
        XCTAssertTrue(finished.toolResultJSON?.contains("streamed finding") == true)
        let authoritative = #"{"status":"partial_failure","oracle_count":2,"response":"authoritative"}"#
        try deliver(status: "completed", output: authoritative)
        try deliver(status: "running", content: [["type": "text", "text": "late provider echo"]])
        try deliver(status: "completed", output: "{}")
        XCTAssertEqual(session.items.count, 1)
        XCTAssertEqual(session.items.first?.id, rowID)
        XCTAssertEqual(session.items.first?.kind, .toolResult)
        XCTAssertEqual(session.items.first?.toolResultJSON, authoritative)
        XCTAssertEqual(session.items.first?.text, authoritative)
        XCTAssertEqual(session.items.first?.toolIsError, false)
    }

    @MainActor
    func testSubstantiveTerminalTextAndArraysReplaceProviderLifecycleOnBothRunnerPaths() throws {
        for trackerPath in [false, true] {
            for output: Any in ["terminal finding", [["type": "text", "text": "terminal finding"]]] {
                let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
                let session = harness.makeSession(agent: .devin)
                let runner = ACPIntegratedAgentModeRunner(
                    hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier(),
                    toolTrackingHooks: .noOp
                )
                func deliver(_ status: String, output: Any? = nil) throws -> AIStreamResult {
                    var update: [String: Any] = [
                        "sessionUpdate": "tool_call_update", "toolCallId": "terminal-text-call",
                        "title": "ask_oracle", "status": status
                    ]
                    update["rawOutput"] = output
                    if status == "running" { update["content"] = [["type": "text", "text": "working"]] }
                    let events = ACPDefaultSessionUpdateNormalizer.normalize(update, providerID: .devin)
                    guard case let .stream(result) = events.first else { throw NSError(domain: "Missing ACP event", code: 1) }
                    if trackerPath {
                        try runner.testHandleTrackerToolResult(
                            invocationID: XCTUnwrap(result.toolInvocationID), toolName: "ask_oracle", args: nil,
                            resultJSON: XCTUnwrap(result.toolResultJSON), isError: result.toolIsError == true, session: session
                        )
                    } else {
                        XCTAssertTrue(try runner.handleToolStreamEvent(.toolResult(.init(
                            toolName: "ask_oracle", invocationID: result.toolInvocationID, argsJSON: nil,
                            resultJSON: XCTUnwrap(result.toolResultJSON), isError: result.toolIsError
                        )), session: session))
                    }
                    return result
                }
                let running = try deliver("running")
                let rowID = try XCTUnwrap(session.items.first).id
                let terminal = try deliver("completed", output: output)
                XCTAssertEqual(session.items.count, 1)
                let row = try XCTUnwrap(session.items.first)
                XCTAssertEqual(row.id, rowID)
                XCTAssertEqual(row.toolInvocationID, running.toolInvocationID)
                XCTAssertEqual(row.toolResultJSON, terminal.toolResultJSON, "tracker path: \(trackerPath)")
                XCTAssertEqual(row.text, terminal.toolResultJSON)
                XCTAssertEqual(row.toolIsError, false)
                XCTAssertEqual(AgentTranscriptToolNormalizer.toolExecution(for: row)?.status, .success)
            }
        }
    }

    @MainActor
    func testDetachedAgentRunSnapshotSurvivesProviderTerminalEchoOnBothRunnerPaths() {
        let snapshot = #"{"status":"running","session_id":"detached-child","context_id":"child-context"}"#
        for trackerPath in [false, true] {
            let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
            let session = harness.makeSession(agent: .devin)
            let runner = ACPIntegratedAgentModeRunner(
                hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier(),
                toolTrackingHooks: .noOp
            )
            let invocationID = UUID()
            for result in [snapshot, #"{"status":"completed"}"#] {
                if trackerPath {
                    runner.testHandleTrackerToolResult(
                        invocationID: invocationID, toolName: "agent_run", args: ["op": .string("start")],
                        resultJSON: result, isError: false, session: session
                    )
                } else {
                    XCTAssertTrue(runner.handleToolStreamEvent(.toolResult(.init(
                        toolName: "agent_run", invocationID: invocationID, argsJSON: #"{"op":"start"}"#,
                        resultJSON: result, isError: false
                    )), session: session))
                }
            }
            XCTAssertEqual(session.items.count, 1)
            XCTAssertEqual(session.items.first?.toolResultJSON, snapshot, "tracker path: \(trackerPath)")
            XCTAssertEqual(session.items.first?.text, snapshot)
        }
    }

    func testNativeLifecycleObjectCannotBeErasedByProviderTextOrArray() throws {
        let native = #"{"status":"running","context_id":"native-context"}"#
        let events = ACPDefaultSessionUpdateNormalizer.normalize([
            "sessionUpdate": "tool_call_update", "toolCallId": "native-lifecycle",
            "status": "running", "content": [["type": "text", "text": "provider echo"]]
        ], providerID: .devin)
        guard case let .stream(result) = events.first else { return XCTFail("Missing normalized lifecycle") }
        let runningEcho = try XCTUnwrap(result.toolResultJSON)
        for incoming in ["terminal echo", #"[{"type":"text","text":"terminal echo"}]"#, runningEcho] {
            XCTAssertNil(AgentToolResultPayloadRetention.resolvedPayload(
                existing: native, incoming: incoming, incomingIsError: false, requireObjectReplacement: true
            ))
        }
    }
}
