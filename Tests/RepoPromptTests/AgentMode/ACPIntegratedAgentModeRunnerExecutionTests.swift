import MCP
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
        let runner = ACPIntegratedAgentModeRunner(hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier(), toolTrackingHooks: toolTrackingHooks, providerFactory: { _, _ in nil }, controllerFactory: { provider, request in try ACPAgentSessionController(provider: provider, runRequest: request) })
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
            toolTrackingHooks: .noOp, providerFactory: { _, _ in nil },
            controllerFactory: { provider, request in
                try ACPAgentSessionController(provider: provider, runRequest: request)
            }
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
    func testRawOutputLifecycleTerminalUpdatesOnBothRunnerPaths() throws {
        for trackerPath in [false, true] {
            for (terminalStatus, output) in [
                ("completed", [String: Any]() as Any), ("completed", [Any]() as Any),
                ("completed", "terminal finding" as Any), ("completed", [["type": "text", "text": "terminal finding"]] as Any),
                ("failed", [Any]() as Any), ("failed", "Tool execution aborted" as Any),
                ("failed", ["error": "Tool execution aborted"] as Any)
            ] {
                let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
                let session = harness.makeSession(agent: .devin)
                let runner = ACPIntegratedAgentModeRunner(
                    hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier(),
                    toolTrackingHooks: .noOp, providerFactory: { _, _ in nil },
                    controllerFactory: { provider, request in
                        try ACPAgentSessionController(provider: provider, runRequest: request)
                    }
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
                let running = try deliver("running", output: ["output": "streamed finding"])
                let rowID = try XCTUnwrap(session.items.first).id
                let terminal = try deliver(terminalStatus, output: output)
                XCTAssertEqual(session.items.count, 1)
                let row = try XCTUnwrap(session.items.first)
                XCTAssertEqual(row.id, rowID)
                XCTAssertEqual(row.toolInvocationID, running.toolInvocationID)
                if terminalStatus == "completed", AgentToolResultPayloadRetention.terminalMarkerStatus(terminal.toolResultJSON) != nil {
                    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(row.toolResultJSON).utf8)) as? [String: Any])
                    XCTAssertEqual(object["status"] as? String, "completed", "tracker path: \(trackerPath)")
                    XCTAssertEqual((object["rawOutput"] as? [String: Any])?["output"] as? String, "streamed finding")
                    XCTAssertTrue(row.toolResultJSON?.contains("working") == true)
                } else {
                    XCTAssertEqual(row.toolResultJSON, terminal.toolResultJSON, "tracker path: \(trackerPath)")
                }
                XCTAssertEqual(row.text, row.toolResultJSON)
                XCTAssertEqual(row.toolIsError, terminalStatus == "failed")
                XCTAssertEqual(AgentTranscriptToolNormalizer.toolExecution(for: row)?.status, terminalStatus == "failed" ? .failed : .success)
            }
        }
    }

    @MainActor
    func testNestedNativeRawOutputSurvivesTerminalEchoOnBothRunnerPaths() async throws {
        let storage = try makeTestDirectory(name: "NativeObservationParity")
        let workspace = WorkspaceModel(name: "Native observation parity", repoPaths: [], customStoragePath: storage)
        let composition = WindowStateCompositionFactory.make(
            windowID: -9857, deferredInitialAgentSystemWorkspaceRefresh: true, sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        defer {
            composition.contextBuilderAgentViewModel.prepareForWindowClose()
            composition.workspaceManager.prepareForWindowClose()
        }
        addTeardownBlock { await composition.workspaceManager.awaitOwnSavesForWindowClose() }
        let tabID = UUID()
        func restore(_ item: AgentChatItem) async throws -> AgentChatItem {
            let saved = AgentSession(
                workspaceID: workspace.id, composeTabID: tabID, name: "Native observation",
                transcript: AgentTranscriptIO.importLegacyItems([.user("Inspect", sequenceIndex: 0), item]), lastRunState: "completed"
            )
            let file = try await AgentSessionDataService().saveAgentSession(saved, for: workspace)
            let bytes = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(bytes.contains("PRIVATE_INPUT"))
            XCTAssertFalse(bytes.contains("PRIVATE_RESPONSE_BODY"))
            let loaded = try await AgentSessionDataService().loadAgentSession(from: file)
            let projection = try AgentTranscriptProjectionBuilder.build(from: XCTUnwrap(loaded.transcript))
            let rows = (projection.archivedBlocks + projection.workingBlocks).flatMap(\.rows)
            let restored = try XCTUnwrap(rows.first { $0.kind == .toolResult && $0.toolInvocationID == item.toolInvocationID })
            XCTAssertNil(restored.toolArgsJSON)
            XCTAssertLessThanOrEqual(try XCTUnwrap(restored.toolResultJSON).utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
            return restored
        }
        func verifyFailedTicketObservation(_ item: AgentChatItem, expectedJobStatus: String) async throws {
            for (restored, row) in try await [(false, item), (true, restore(item))] {
                let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: row.toolResultJSON))
                XCTAssertEqual(dto.ticket?.job.status.rawValue, expectedJobStatus)
                XCTAssertEqual(row.toolIsError, true)
                let context = ContextBuilderCardContext(
                    tabID: tabID, contextBuilderAgentVM: composition.contextBuilderAgentViewModel,
                    oracleOpenContext: .init(windowID: -9857, workspaceID: workspace.id, tabID: tabID),
                    transcriptMetadata: ContextBuilderTranscriptMetadata(rows: [row])
                )
                let card = ContextBuilderResultCard(item: row, context: context)
                XCTAssertEqual(card.status, .failure, "Failed control observation must remain visible, restored=\(restored)")
                XCTAssertTrue(card.summary.contains("Observation failed"), card.summary)
                XCTAssertTrue(card.summary.contains(expectedJobStatus), "Do not rewrite job state: \(card.summary)")
                if restored, expectedJobStatus != "completed" {
                    XCTAssertTrue(card.summary.contains("Live job state unknown"), card.summary)
                }
                XCTAssertNil(card.followUpChatID, "A transport error must not grant running/unknown/completed tickets recovery authority")
                if expectedJobStatus == "completed" {
                    let later = try AgentChatItem.toolResult(
                        name: "context_builder", invocationID: UUID(), argsJSON: nil,
                        resultJSON: XCTUnwrap(row.toolResultJSON), isError: false, sequenceIndex: row.sequenceIndex + 1
                    )
                    let historicalContext = ContextBuilderCardContext(
                        tabID: tabID, contextBuilderAgentVM: composition.contextBuilderAgentViewModel,
                        oracleOpenContext: context.oracleOpenContext,
                        transcriptMetadata: ContextBuilderTranscriptMetadata(rows: [row, later])
                    )
                    let historical = ContextBuilderResultCard(item: row, context: historicalContext)
                    XCTAssertEqual(historical.status, .failure, "Historical observation must not hide its control failure")
                    XCTAssertTrue(historical.summary.contains("Observation failed"), historical.summary)
                }
                var clean = row
                clean.toolIsError = false
                let cleanCard = ContextBuilderResultCard(item: clean, context: context)
                XCTAssertFalse(cleanCard.summary.contains("Observation failed"))
                if expectedJobStatus != "completed" { XCTAssertEqual(cleanCard.status, .neutral) }
                let foreign = ContextBuilderCardContext(
                    tabID: UUID(), contextBuilderAgentVM: composition.contextBuilderAgentViewModel,
                    oracleOpenContext: context.oracleOpenContext, transcriptMetadata: context.transcriptMetadata
                )
                XCTAssertNil(ContextBuilderResultCard(item: row, context: foreign).followUpChatID)
            }
        }
        let group = try OracleGroupResult(groupID: OracleGroupID(rawValue: UUID()), status: .completed, oracleResults: [
            OracleLaneResult(laneIndex: 0, chatID: "primary", providerID: nil, modelID: "primary-model", status: .completed, response: "retained answer"),
            OracleLaneResult(laneIndex: 1, chatID: "sibling", providerID: nil, modelID: "sibling-model", status: .completed, response: "retained answer")
        ])
        let groupObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ToolOutputFormatter.rawJSONString(.object(OracleGroupMCPCodec.groupFields(group))).utf8)) as? [String: Any])
        let jobID = UUID().uuidString
        let ticket: [String: Any] = [
            "job_id": jobID,
            "job": ["id": jobID, "context_id": tabID.uuidString, "status": "running", "revision": 3, "chat_id": "captured-chat"]
        ]
        let ticketVariants = try ["running", "cancelling", "unknown", "completed"].map { status in
            var value = ticket
            var job = try XCTUnwrap(ticket["job"] as? [String: Any])
            job["status"] = status
            value["job"] = job
            return value
        }
        for trackerPath in [false, true] {
            for native in [groupObject] + ticketVariants {
                for (terminalStatus, echo) in [
                    ("completed", [Any]() as Any), ("completed", "terminal echo" as Any),
                    ("completed", [["type": "text", "text": "terminal echo"]] as Any),
                    ("failed", [Any]() as Any), ("failed", "Tool execution aborted" as Any),
                    ("failed", ["error": "Tool execution aborted"] as Any)
                ] {
                    let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
                    let session = harness.makeSession(agent: .devin)
                    let runner = ACPIntegratedAgentModeRunner(
                        hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier(),
                        toolTrackingHooks: .noOp, providerFactory: { _, _ in nil },
                        controllerFactory: { provider, request in
                            try ACPAgentSessionController(provider: provider, runRequest: request)
                        }
                    )
                    let toolName = native["job"] == nil ? "ask_oracle" : "context_builder"
                    func deliver(_ status: String, output: Any) throws -> AIStreamResult {
                        let events = ACPDefaultSessionUpdateNormalizer.normalize([
                            "sessionUpdate": "tool_call_update", "toolCallId": "native-raw-output", "title": toolName,
                            "status": status, "rawOutput": output, "content": [["type": "text", "text": "provider echo"]]
                        ], providerID: .devin)
                        guard case let .stream(result) = events.first else { throw NSError(domain: "Missing ACP event", code: 1) }
                        if trackerPath {
                            try runner.testHandleTrackerToolResult(
                                invocationID: XCTUnwrap(result.toolInvocationID), toolName: toolName, args: nil,
                                resultJSON: XCTUnwrap(result.toolResultJSON), isError: result.toolIsError == true, session: session
                            )
                        } else {
                            XCTAssertTrue(try runner.handleToolStreamEvent(.toolResult(.init(
                                toolName: toolName, invocationID: result.toolInvocationID, argsJSON: nil,
                                resultJSON: XCTUnwrap(result.toolResultJSON), isError: result.toolIsError
                            )), session: session))
                        }
                        return result
                    }
                    _ = try deliver("running", output: native)
                    let rowID = try XCTUnwrap(session.items.first?.id)
                    let terminal = try deliver(terminalStatus, output: echo)
                    XCTAssertEqual(session.items.map(\.id), [rowID])
                    let row = try XCTUnwrap(session.items.first)
                    let payload = try XCTUnwrap(row.toolResultJSON)
                    guard let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else {
                        XCTFail("Provider terminal echo erased the native envelope: \(payload)")
                        continue
                    }
                    let expectedOuterStatus = terminalStatus == "completed" && AgentToolResultPayloadRetention.terminalMarkerStatus(terminal.toolResultJSON) != nil ? "completed" : "running"
                    XCTAssertEqual(row.toolIsError, terminalStatus == "failed", "Transport failure remains visible on both paths")
                    XCTAssertEqual(object["status"] as? String, expectedOuterStatus, "tracker path: \(trackerPath)")
                    guard let retained = object["rawOutput"] as? [String: Any] else {
                        XCTFail("Failed provider echo erased the nested native facts: \(payload)")
                        continue
                    }
                    XCTAssertEqual(NSDictionary(dictionary: retained), NSDictionary(dictionary: native))
                    if native["job"] != nil {
                        let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: row.toolResultJSON))
                        XCTAssertEqual(dto.ticket?.jobID.uuidString, jobID)
                        let nativeStatus = try XCTUnwrap((native["job"] as? [String: Any])?["status"] as? String)
                        XCTAssertEqual(dto.ticket?.job.status.rawValue, nativeStatus, "Provider completion must not finish the app-owned job")
                        if terminalStatus == "failed" {
                            var observed = row
                            observed.toolArgsJSON = #"{"op":"wait","message":"PRIVATE_INPUT"}"#
                            try await verifyFailedTicketObservation(observed, expectedJobStatus: nativeStatus)
                        }
                    }
                    var replacement = native
                    if var job = native["job"] as? [String: Any] {
                        job["revision"] = 4
                        job["status"] = "cancelled"
                        replacement["job"] = job
                    } else if var lanes = native["oracle_results"] as? [[String: Any]] {
                        lanes[0]["response"] = "new canonical answer"
                        replacement["oracle_results"] = lanes
                    }
                    let newerEnvelope = try deliver("running", output: replacement)
                    XCTAssertEqual(session.items.first?.toolResultJSON, newerEnvelope.toolResultJSON, "A genuine nested native update must replace the older facts")
                    let directNative = try deliver("failed", output: replacement)
                    XCTAssertEqual(session.items.first?.toolResultJSON, directNative.toolResultJSON, "A genuine direct native result still replaces its envelope")
                    XCTAssertEqual(session.items.first?.toolIsError, true)
                }
            }
        }

        let partial = try OracleGroupResult(groupID: OracleGroupID(rawValue: UUID()), status: .partialFailure, oracleResults: [
            OracleLaneResult(laneIndex: 0, chatID: "primary", providerID: nil, modelID: "primary-model", status: .completed, response: "PRIVATE_RESPONSE_BODY"),
            OracleLaneResult(
                laneIndex: 1,
                chatID: "sibling",
                providerID: nil,
                modelID: "sibling-model",
                status: .cancelled,
                error: OracleLaneError(code: "cancelled", message: "Sibling cancelled")
            )
        ])
        var fields = OracleGroupMCPCodec.groupFields(partial)
        fields["chat_id"] = .string(partial.primary.chatID)
        fields["mode"] = .string("review")
        fields["response"] = .string("PRIVATE_RESPONSE_BODY")
        let partialJSON = ToolOutputFormatter.rawJSONString(.object(fields))
        let partialObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(partialJSON.utf8)) as? [String: Any])
        var representations = [("direct", partialJSON)]
        for provider in [ACPProviderID.devin, .cursor] {
            for stringOutput in [false, true] {
                for conflictingContent in [false, true] {
                    var update: [String: Any] = [
                        "sessionUpdate": "tool_call_update", "toolCallId": "partial-group", "title": "ask_oracle",
                        "status": provider == .cursor ? "completed" : "running", "rawOutput": stringOutput ? partialJSON : partialObject
                    ]
                    if conflictingContent { update["content"] = [["type": "text", "text": #"{"status":"completed","chat_id":"wrong-chat"}"#]] }
                    let events = provider == .cursor
                        ? CursorACPEventNormalizer.normalize(update)
                        : ACPDefaultSessionUpdateNormalizer.normalize(update, providerID: provider)
                    guard case let .stream(result) = events.first else { throw NSError(domain: "Missing native group event", code: 1) }
                    try representations.append(("\(provider) string=\(stringOutput) conflict=\(conflictingContent)", XCTUnwrap(result.toolResultJSON)))
                }
            }
        }
        // Native root facts outrank an incidental older group envelope and structured content.
        for stringOutput in [false, true] {
            var direct = partialObject
            direct["rawOutput"] = stringOutput ? ToolOutputFormatter.rawJSONString(.object(OracleGroupMCPCodec.groupFields(group))) : groupObject
            direct["content"] = [["type": "text", "text": #"{"status":"completed","chat_id":"wrong-chat"}"#]]
            try representations.append(("direct authority string=\(stringOutput)", String(decoding: JSONSerialization.data(withJSONObject: direct), as: UTF8.self)))
        }
        for trackerPath in [false, true] {
            for (representation, payload) in representations {
                let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
                let session = harness.makeSession(agent: .devin)
                let runner = ACPIntegratedAgentModeRunner(
                    hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier(), toolTrackingHooks: .noOp,
                    providerFactory: { _, _ in nil }, controllerFactory: { provider, request in
                        try ACPAgentSessionController(provider: provider, runRequest: request)
                    }
                )
                let invocationID = UUID()
                func deliver(_ json: String) {
                    if trackerPath {
                        runner.testHandleTrackerToolResult(invocationID: invocationID, toolName: "ask_oracle", args: ["message": .string("PRIVATE_INPUT")], resultJSON: json, isError: false, session: session)
                    } else {
                        XCTAssertTrue(runner.handleToolStreamEvent(.toolResult(.init(
                            toolName: "ask_oracle", invocationID: invocationID, argsJSON: #"{"message":"PRIVATE_INPUT"}"#,
                            resultJSON: json, isError: false
                        )), session: session))
                    }
                }
                deliver(partialJSON)
                let rowID = try XCTUnwrap(session.items.first?.id)
                deliver(payload)
                XCTAssertEqual(session.items.map(\.id), [rowID])
                let incoming = try XCTUnwrap(session.items.first)
                for (restored, row) in try await [(false, incoming), (true, restore(incoming))] {
                    let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: row.toolResultJSON))
                    XCTAssertEqual(dto.status, "partial_failure", "\(representation), restored=\(restored)")
                    XCTAssertEqual(dto.chatID, "primary")
                    XCTAssertEqual(dto.oracleGroupID, partial.groupID.rawValue.uuidString)
                    XCTAssertEqual(dto.oracleCount, 2)
                    XCTAssertEqual(dto.oracleResults?.map(\.status), ["completed", "cancelled"])
                    XCTAssertEqual(dto.oracleResults?.last?.error?.code, "cancelled")
                    XCTAssertEqual(ChatSendResultCard(item: row, oracleOpenContext: nil).status, .warning, representation)
                    XCTAssertEqual(row.toolIsError, incoming.toolIsError, "Persistence must preserve the actual runner transport flag")
                    if restored { XCTAssertTrue(dto.oracleResults?.allSatisfy { $0.response == nil } == true) }
                }
            }
        }
        // Invalid groups and unsupported deeper wrappers keep legacy content precedence.
        var invalidGroup = partialObject
        invalidGroup["oracle_count"] = 3
        for rawOutput in [invalidGroup, ["rawOutput": partialObject]] {
            for stringOutput in [false, true] {
                let outputJSON = try String(decoding: JSONSerialization.data(withJSONObject: rawOutput), as: UTF8.self)
                let envelope: [String: Any] = [
                    "status": "success", "acp_status": "completed", "rawOutput": stringOutput ? outputJSON : rawOutput,
                    "content": [["type": "text", "text": #"{"status":"completed","chat_id":"legacy-chat"}"#]]
                ]
                let json = try String(decoding: JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
                let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: json))
                XCTAssertEqual(dto.chatID, "legacy-chat")
                XCTAssertEqual(dto.status, "completed")
                XCTAssertNil(dto.oracleResults)
                XCTAssertNil(ToolResultDTOs.ChatSendDTO.nativeOracleGroupJSONData(from: json))
            }
        }
    }

    @MainActor
    func testNativeObservationsSurviveProductionTerminalRepairOnBothRunnerPaths() throws {
        let group = try OracleGroupResult(groupID: OracleGroupID(rawValue: UUID()), status: .partialFailure, oracleResults: [
            OracleLaneResult(laneIndex: 0, chatID: "paid-primary", providerID: nil, modelID: "primary", status: .completed, response: "PRIVATE_RESPONSE_BODY"),
            OracleLaneResult(laneIndex: 1, chatID: "cancelled-sibling", providerID: nil, modelID: "sibling", status: .cancelled, error: .init(code: "cancelled", message: "Sibling cancelled"))
        ])
        let groupObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ToolOutputFormatter.rawJSONString(.object(OracleGroupMCPCodec.groupFields(group))).utf8)) as? [String: Any])
        let jobID = UUID().uuidString
        let tickets = ["running", "cancelling", "unknown", "completed", "failed", "cancelled", "expired"].map { status in
            ["job_id": jobID, "job": ["id": jobID, "status": status, "revision": 4]] as [String: Any]
        }
        for trackerPath in [false, true] {
            for native in [groupObject] + tickets {
                let toolName = native["job"] == nil ? "ask_oracle" : "context_builder"
                for representation in ["direct", "object", "string"] {
                    for isError in [false, true] {
                        let row = try nativeObservationRow(native, toolName: toolName, representation: representation, trackerPath: trackerPath, isError: isError)
                        for terminalState in [AgentSessionRunState.completed, .cancelled, .failed] {
                            let pending = AgentChatItem.toolCall(name: "read_file", argsJSON: nil, sequenceIndex: row.sequenceIndex + 1)
                            let running = AgentChatItem.toolResult(name: "get_file_tree", argsJSON: nil, resultJSON: #"{"status":"running"}"#, isError: false, sequenceIndex: row.sequenceIndex + 2)
                            var items = [row, pending, running]
                            let repaired = AgentTranscriptQualityRepair.finalizePendingTerminalTools(
                                in: &items, terminalState: terminalState, context: .liveTerminal(agentKind: .devin), nonToolBoundary: 6
                            )
                            XCTAssertEqual(repaired, 2, "Only unresolved calls need terminal fallback: \(toolName), \(representation), tracker=\(trackerPath)")
                            XCTAssertEqual(items[0].id, row.id)
                            XCTAssertEqual(items[0].toolResultJSON, row.toolResultJSON, "Terminal fallback must not erase returned native facts")
                            XCTAssertEqual(items[0].toolIsError, isError, "A run terminal is not a new error in an already-returned control observation")
                            XCTAssertEqual(items[1].kind, .toolResult)
                            XCTAssertEqual(items[1].toolIsError, true)
                            XCTAssertEqual(items[2].toolIsError, true)
                            XCTAssertFalse(items[2].toolResultJSON == running.toolResultJSON)
                            if toolName == "ask_oracle" {
                                let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: items[0].toolResultJSON))
                                XCTAssertEqual(dto.oracleGroupID, group.groupID.rawValue.uuidString)
                                XCTAssertEqual(dto.oracleResults?.map(\.status), ["completed", "cancelled"])
                                XCTAssertEqual(dto.oracleResults?.first?.response, "PRIVATE_RESPONSE_BODY")
                                XCTAssertEqual(dto.oracleResults?.last?.error?.code, "cancelled")
                            } else {
                                let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: items[0].toolResultJSON))
                                XCTAssertEqual(dto.ticket?.jobID.uuidString, jobID)
                                XCTAssertEqual(dto.ticket?.job.status.rawValue, (native["job"] as? [String: Any])?["status"] as? String)
                                XCTAssertEqual(dto.ticket?.job.revision, 4)
                            }
                        }
                    }
                }
            }
        }
        // Malformed tickets and deeper provider wrappers are not native observations.
        for rawOutput in [
            ["job_id": jobID, "job": ["id": UUID().uuidString, "status": "running"]] as [String: Any],
            ["rawOutput": tickets[0]]
        ] {
            for trackerPath in [false, true] {
                var items = try [nativeObservationRow(rawOutput, toolName: "context_builder", representation: "object", trackerPath: trackerPath, isError: false)]
                XCTAssertEqual(AgentTranscriptQualityRepair.finalizePendingTerminalTools(
                    in: &items, terminalState: .cancelled, context: .liveTerminal(agentKind: .devin), nonToolBoundary: 6
                ), 1)
                XCTAssertEqual(items[0].toolIsError, true)
            }
        }
    }

    @MainActor
    func testCleanContextBuilderObservationsPreserveNativeStateThroughDiskRestore() async throws {
        let storage = try makeTestDirectory(name: "CleanNativeObservationRestore")
        let workspace = WorkspaceModel(name: "Clean native observation", repoPaths: [], customStoragePath: storage)
        let composition = WindowStateCompositionFactory.make(
            windowID: -9858, deferredInitialAgentSystemWorkspaceRefresh: true, sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        defer {
            composition.contextBuilderAgentViewModel.prepareForWindowClose()
            composition.workspaceManager.prepareForWindowClose()
        }
        addTeardownBlock { await composition.workspaceManager.awaitOwnSavesForWindowClose() }
        let tabID = UUID()
        let jobID = UUID().uuidString
        let partialGroup = try OracleGroupResult(groupID: OracleGroupID(rawValue: UUID()), status: .partialFailure, oracleResults: [
            OracleLaneResult(laneIndex: 0, chatID: "paid-chat", providerID: nil, modelID: "primary", status: .completed, response: "PRIVATE_RESPONSE_BODY"),
            OracleLaneResult(laneIndex: 1, chatID: "sibling", providerID: nil, modelID: "sibling", status: .cancelled, error: .init(code: "cancelled", message: "Sibling cancelled"))
        ])
        let partialReply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ToolOutputFormatter.rawJSONString(.object(OracleGroupMCPCodec.groupFields(partialGroup))).utf8)) as? [String: Any])
        let jobCases = ["running", "cancelling", "unknown", "completed", "failed", "cancelled", "expired"].map { ($0, false) } + [("completed", true)]
        for trackerPath in [false, true] {
            for (jobStatus, hasPartialReply) in jobCases {
                var native: [String: Any] = [
                    "job_id": jobID,
                    "job": ["id": jobID, "context_id": tabID.uuidString, "status": jobStatus, "revision": 5, "chat_id": "paid-chat"]
                ]
                if jobStatus == "completed" {
                    native["status"] = "success"
                    native["response_type"] = "plan"
                    var reply = hasPartialReply ? partialReply : [:]
                    reply["chat_id"] = "paid-chat"
                    reply["mode"] = "plan"
                    reply["response"] = "PRIVATE_RESPONSE_BODY"
                    native["plan"] = reply
                }
                for representation in ["direct", "object", "string"] {
                    for isError in [false, true] {
                        var row = try nativeObservationRow(native, toolName: "context_builder", representation: representation, trackerPath: trackerPath, isError: isError)
                        row.toolArgsJSON = #"{"op":"wait","message":"PRIVATE_INPUT"}"#
                        let saved = AgentSession(
                            workspaceID: workspace.id, composeTabID: tabID, name: "Clean observation",
                            transcript: AgentTranscriptIO.importLegacyItems([.user("Inspect", sequenceIndex: 0), row]), lastRunState: "completed"
                        )
                        let file = try await AgentSessionDataService().saveAgentSession(saved, for: workspace)
                        let bytes = try String(contentsOf: file, encoding: .utf8)
                        XCTAssertFalse(bytes.contains("PRIVATE_INPUT"))
                        XCTAssertFalse(bytes.contains("PRIVATE_RESPONSE_BODY"))
                        let loaded = try await AgentSessionDataService().loadAgentSession(from: file)
                        let projection = try AgentTranscriptProjectionBuilder.build(from: XCTUnwrap(loaded.transcript))
                        let rows = (projection.archivedBlocks + projection.workingBlocks).flatMap(\.rows)
                        let restored = try XCTUnwrap(rows.first { $0.kind == .toolResult && $0.toolInvocationID == row.toolInvocationID })
                        XCTAssertEqual(restored.toolIsError, isError, "Cold restore must not manufacture observation failure: \(representation), \(jobStatus), tracker=\(trackerPath)")
                        XCTAssertNil(restored.toolArgsJSON)
                        XCTAssertLessThanOrEqual(try XCTUnwrap(restored.toolResultJSON).utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
                        let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: restored.toolResultJSON))
                        XCTAssertEqual(dto.ticket?.jobID.uuidString, jobID)
                        XCTAssertEqual(dto.ticket?.job.contextID, tabID)
                        XCTAssertEqual(dto.ticket?.job.status.rawValue, jobStatus)
                        XCTAssertEqual(dto.ticket?.job.revision, 5)
                        XCTAssertEqual(dto.ticket?.summaryOnly, true)
                        XCTAssertEqual(AgentTranscriptToolNormalizer.status(for: restored), isError ? .failed : hasPartialReply ? .warning : .success, "A returned control observation is settled, not its job")
                        let context = ContextBuilderCardContext(
                            tabID: tabID, contextBuilderAgentVM: composition.contextBuilderAgentViewModel,
                            oracleOpenContext: .init(windowID: -9858, workspaceID: workspace.id, tabID: tabID),
                            transcriptMetadata: ContextBuilderTranscriptMetadata(rows: [restored])
                        )
                        let card = ContextBuilderResultCard(item: restored, context: context)
                        XCTAssertEqual(card.summary.contains("Observation failed"), isError, card.summary)
                        if isError {
                            XCTAssertEqual(card.status, .failure)
                        } else {
                            switch jobStatus {
                            case "completed":
                                XCTAssertEqual(card.status, hasPartialReply ? .warning : .success)
                                XCTAssertEqual(dto.plan?.chatID, "paid-chat")
                                XCTAssertNil(dto.plan?.response)
                                if hasPartialReply {
                                    XCTAssertEqual(dto.plan?.oracleGroupID, partialGroup.groupID.rawValue.uuidString)
                                    XCTAssertEqual(dto.plan?.oracleResults?.map(\.status), ["completed", "cancelled"])
                                    XCTAssertEqual(dto.plan?.oracleResults?.last?.error?.code, "cancelled")
                                    XCTAssertTrue(dto.plan?.oracleResults?.allSatisfy { $0.response == nil } == true)
                                }
                                XCTAssertEqual(card.followUpChatID, "paid-chat")
                            case "failed", "cancelled": XCTAssertEqual(card.status, .failure)
                            case "expired": XCTAssertEqual(card.status, .warning)
                            default:
                                XCTAssertEqual(card.status, .neutral)
                                XCTAssertTrue(card.summary.contains("Live job state unknown"), card.summary)
                                XCTAssertNil(card.followUpChatID, "An archived observation does not establish liveness")
                            }
                        }
                    }
                }
            }
        }
        // Cold restoration must still cancel a genuinely unresolved ordinary call.
        let generic = AgentChatItem.toolResult(name: "get_file_tree", argsJSON: nil, resultJSON: #"{"status":"running"}"#, isError: false, sequenceIndex: 1)
        let saved = AgentSession(workspaceID: workspace.id, composeTabID: tabID, name: "Unresolved", transcript: AgentTranscriptIO.importLegacyItems([.user("Inspect", sequenceIndex: 0), generic]), lastRunState: "running")
        let file = try await AgentSessionDataService().saveAgentSession(saved, for: workspace)
        let loaded = try await AgentSessionDataService().loadAgentSession(from: file)
        let restored = try AgentTranscriptIO.workingSourceItems(from: XCTUnwrap(loaded.transcript))
        let result = try XCTUnwrap(restored.first { $0.kind == .toolResult })
        XCTAssertEqual(result.toolIsError, true)
        XCTAssertEqual(AgentTranscriptToolNormalizer.status(for: result), .cancelled)
    }

    @MainActor
    private func nativeObservationRow(
        _ native: [String: Any], toolName: String, representation: String, trackerPath: Bool, isError: Bool
    ) throws -> AgentChatItem {
        let json = try String(decoding: JSONSerialization.data(withJSONObject: native, options: [.sortedKeys]), as: UTF8.self)
        let events = ACPDefaultSessionUpdateNormalizer.normalize([
            "sessionUpdate": "tool_call_update", "toolCallId": "native-observation", "title": toolName,
            "status": representation == "direct" ? "completed" : "running",
            "rawOutput": representation == "string" ? json : native
        ], providerID: .devin)
        guard case let .stream(result) = events.first else { throw NSError(domain: "Missing native observation", code: 1) }
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
        let session = harness.makeSession(agent: .devin)
        let runner = ACPIntegratedAgentModeRunner(
            hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier(), toolTrackingHooks: .noOp,
            providerFactory: { _, _ in nil }, controllerFactory: { provider, request in
                try ACPAgentSessionController(provider: provider, runRequest: request)
            }
        )
        if trackerPath {
            try runner.testHandleTrackerToolResult(invocationID: XCTUnwrap(result.toolInvocationID), toolName: toolName, args: nil, resultJSON: XCTUnwrap(result.toolResultJSON), isError: isError, session: session)
        } else {
            XCTAssertTrue(try runner.handleToolStreamEvent(.toolResult(.init(
                toolName: toolName, invocationID: result.toolInvocationID, argsJSON: nil,
                resultJSON: XCTUnwrap(result.toolResultJSON), isError: isError
            )), session: session))
        }
        return try XCTUnwrap(session.items.first)
    }

    private let rich = #"{"review":{"chat_id":"c","oracle_results":[]},"status":"success"}"#

    func testEmptyLaterUpdateKeepsEarlierResult() {
        for thin in [nil, "", "  \n", "{}", "[]", "null", "\"\""] {
            XCTAssertTrue(
                AgentToolResultPayloadRetention.shouldKeepExisting(existing: rich, incoming: thin, incomingIsError: false),
                String(describing: thin)
            )
        }
    }

    func testRealUpdatesAndErrorsStillReplace() {
        XCTAssertFalse(AgentToolResultPayloadRetention.shouldKeepExisting(existing: rich, incoming: #"{"status":"x"}"#, incomingIsError: false))
        XCTAssertFalse(AgentToolResultPayloadRetention.shouldKeepExisting(existing: rich, incoming: "", incomingIsError: true))
        XCTAssertFalse(AgentToolResultPayloadRetention.shouldKeepExisting(existing: "", incoming: "", incomingIsError: false))
        XCTAssertFalse(AgentToolResultPayloadRetention.shouldKeepExisting(existing: rich, incoming: "plain text", incomingIsError: false))
    }

    func testProgressUpdatesNeverReplaceARealResult() {
        let running = #"{"title":"Called manage_selection from RepoPromptCE","status":"running"}"#
        let finalContent = #"[{"type":"content","content":{"type":"text","text":"Selection set"}}]"#
        // Devin sends a progress update after RepoPrompt's own result arrived.
        XCTAssertTrue(AgentToolResultPayloadRetention.shouldKeepExisting(
            existing: rich, incoming: running, incomingIsError: false, requireObjectReplacement: true
        ))
        // A real result always replaces a progress placeholder, even a text echo.
        XCTAssertFalse(AgentToolResultPayloadRetention.shouldKeepExisting(
            existing: running, incoming: finalContent, incomingIsError: false, requireObjectReplacement: true
        ))
        XCTAssertFalse(AgentToolResultPayloadRetention.shouldKeepExisting(
            existing: running, incoming: rich, incomingIsError: false, requireObjectReplacement: true
        ))
        // A result that merely has a running status plus real fields is not progress.
        XCTAssertFalse(AgentToolResultPayloadRetention.isProgress(#"{"status":"running","context_id":"x"}"#))
    }

    func testBareTerminalMarkerCompletesStreamedProgressAndKeepsRealResults() throws {
        let streamed = #"{"content":[{"type":"content"}],"status":"running"}"#
        let completed = #"{"status":"completed"}"#
        let merged = try XCTUnwrap(AgentToolResultPayloadRetention.resolvedPayload(
            existing: streamed, incoming: completed, incomingIsError: false
        ))
        XCTAssertTrue(merged.contains(#""status":"completed""#), merged)
        XCTAssertTrue(merged.contains(#""content""#), merged)
        // A terminal marker never erases RepoPrompt's own structured result.
        XCTAssertNil(AgentToolResultPayloadRetention.resolvedPayload(
            existing: rich, incoming: completed, incomingIsError: false, requireObjectReplacement: true
        ))
        // With nothing earlier, the marker is stored as-is.
        XCTAssertEqual(
            AgentToolResultPayloadRetention.resolvedPayload(existing: nil, incoming: completed, incomingIsError: false),
            completed
        )
    }

    @MainActor
    func testDetachedAgentRunSnapshotSurvivesProviderTerminalEchoOnBothRunnerPaths() {
        let snapshot = #"{"status":"running","session_id":"detached-child","context_id":"child-context"}"#
        for trackerPath in [false, true] {
            let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
            let session = harness.makeSession(agent: .devin)
            let runner = ACPIntegratedAgentModeRunner(
                hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier(),
                toolTrackingHooks: .noOp, providerFactory: { _, _ in nil },
                controllerFactory: { provider, request in
                    try ACPAgentSessionController(provider: provider, runRequest: request)
                }
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

    func testPrettyPrintedDevinSkillLifecycleCompletes() {
        let running = "{\n  \"status\" : \"running\"\n}"
        let completed = "{\n  \"status\" : \"completed\"\n}"
        XCTAssertEqual(
            AgentToolResultPayloadRetention.resolvedPayload(existing: running, incoming: completed, incomingIsError: false),
            #"{"status":"completed"}"#
        )
    }

    func testTerminalMarkerFinishesSanitizedPresentationSummary() throws {
        let summary = #"{"render_summary":{"detail_text":"running","op":"skill","status":"running","title":"Skill","tool_name":"skill"},"status":"running","summary_only":true,"summary_text":"running"}"#
        let merged = try XCTUnwrap(AgentToolResultPayloadRetention.resolvedPayload(
            existing: summary, incoming: "{\n  \"status\" : \"completed\"\n}", incomingIsError: false
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any])
        let render = try XCTUnwrap(object["render_summary"] as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "completed")
        XCTAssertEqual(render["status"] as? String, "success")
        XCTAssertNil(render["detail_text"])
        XCTAssertNil(object["summary_text"])
        XCTAssertEqual(render["title"] as? String, "Skill")
        // Compaction cannot transfer ownership of native MCP status to the provider.
        XCTAssertNil(AgentToolResultPayloadRetention.resolvedPayload(
            existing: summary, incoming: #"{"status":"completed"}"#, incomingIsError: false,
            requireObjectReplacement: true
        ))
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

    func testObjectReplacementModeKeepsObjectOverText() {
        XCTAssertTrue(AgentToolResultPayloadRetention.shouldKeepExisting(
            existing: rich, incoming: "Context built.", incomingIsError: false, requireObjectReplacement: true
        ))
        XCTAssertFalse(AgentToolResultPayloadRetention.shouldKeepExisting(
            existing: rich, incoming: #"{"status":"success"}"#, incomingIsError: false, requireObjectReplacement: true
        ))
        XCTAssertFalse(AgentToolResultPayloadRetention.shouldKeepExisting(
            existing: "text", incoming: "other text", incomingIsError: false, requireObjectReplacement: true
        ))
    }
}

@MainActor
final class ACPOracleNativeObservationTests: XCTestCase {
    func testIssuedOracleTicketsSurviveACPRepairAndBoundedDiskRestore() async throws {
        for tool in ["ask_oracle", "oracle_send"] {
            try await withOracleFixture(holdTransport: true) { driver, service, invocation in
                let start = try await self.execute(tool, args: ["op": .string("start"), "detach": .bool(true), "message": .string("PRIVATE_INPUT"), "new_chat": .bool(true)], service: service, invocation: invocation)
                let id = try XCTUnwrap(start.objectValue?["job_id"]?.stringValue)
                let poll = try await self.execute(tool, args: ["op": .string("poll"), "job_id": .string(id)], service: service, invocation: invocation)
                XCTAssertEqual(poll.objectValue?["job_id"]?.stringValue, id)
                XCTAssertEqual(poll.objectValue?["job"]?.objectValue?["status"]?.stringValue, "running")
                let cancel = try await self.execute(tool, args: ["op": .string("cancel"), "job_id": .string(id)], service: service, invocation: invocation)
                _ = try await self.execute(tool, args: ["op": .string("wait"), "job_id": .string(id), "timeout": .int(5)], service: service, invocation: invocation)
                for issued in [start, cancel] {
                    let native = try self.object(issued)
                    let expected = try JSONDecoder().decode(ToolResultDTOs.LongRunningJobTicketDTO.self, from: JSONSerialization.data(withJSONObject: native))
                    for representation in ["direct", "object", "string"] {
                        for tracker in [false, true] {
                            for terminal in ["none", "text", "abort", "abort-marker"] {
                                let row = try self.observation(native, tool: tool, representation: representation, tracker: tracker, terminal: terminal)
                                var items = [row]
                                XCTAssertEqual(AgentTranscriptQualityRepair.finalizePendingTerminalTools(in: &items, terminalState: .cancelled, context: .liveTerminal(agentKind: .devin), nonToolBoundary: 6), 0, "A returned \(tool) ticket is not a missing result")
                                XCTAssertEqual(items[0].toolResultJSON, row.toolResultJSON)
                                XCTAssertEqual(items[0].toolIsError, terminal.hasPrefix("abort"))
                                let restored = try await self.saveLoad(items[0], workspace: driver.fixture.workspace, tabID: driver.tabID)
                                let dto = ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: restored.toolResultJSON)
                                XCTAssertEqual(dto?.ticket?.jobID, expected.jobID)
                                XCTAssertEqual(dto?.ticket?.job.contextID, expected.job.contextID)
                                XCTAssertEqual(dto?.ticket?.job.revision, expected.job.revision)
                                XCTAssertEqual(dto?.ticket?.job.status, expected.job.status, "Saved status is the observation, not a new live query")
                                XCTAssertEqual(dto?.ticket?.summaryOnly, true)
                                XCTAssertEqual(restored.toolIsError, terminal.hasPrefix("abort"))
                                XCTAssertEqual(AgentTranscriptToolNormalizer.status(for: restored), terminal.hasPrefix("abort") ? .failed : .success)
                            }
                        }
                    }
                }
            }
        }
    }

    func testProducedSingletonRepliesSurviveACPEchoAbortAndBoundedDiskRestore() async throws {
        for tool in ["ask_oracle", "oracle_send"] {
            try await withOracleFixture(holdTransport: false) { driver, service, invocation in
                // Real single-roster packaging/send builds the actual ChatSendReply, not a permissive DTO fixture.
                let issued = try await self.execute(tool, args: ["message": .string("PRIVATE_INPUT"), "new_chat": .bool(true)], service: service, invocation: invocation)
                let native = try self.object(issued)
                let expectedChat = try XCTUnwrap(native["chat_id"] as? String)
                let expectedMode = try XCTUnwrap(native["mode"] as? String)
                XCTAssertNil(native["oracle_results"])
                XCTAssertEqual(native["response"] as? String, "PRIVATE_RESPONSE_BODY")
                for representation in ["direct", "object", "string"] {
                    for tracker in [false, true] {
                        for terminal in ["none", "text", "abort", "abort-marker"] {
                            let row = try self.observation(native, tool: tool, representation: representation, tracker: tracker, terminal: terminal)
                            var items = [row]
                            XCTAssertEqual(AgentTranscriptQualityRepair.finalizePendingTerminalTools(in: &items, terminalState: .completed, context: .liveTerminal(agentKind: .devin), nonToolBoundary: 6), 0)
                            XCTAssertEqual(items[0].toolResultJSON, row.toolResultJSON)
                            XCTAssertEqual(items[0].toolIsError, terminal.hasPrefix("abort"))
                            let live = ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: items[0].toolResultJSON)
                            XCTAssertEqual(live?.chatID, expectedChat)
                            XCTAssertEqual(live?.mode, expectedMode)
                            XCTAssertEqual(live?.response, "PRIVATE_RESPONSE_BODY")
                            let restored = try await self.saveLoad(items[0], workspace: driver.fixture.workspace, tabID: driver.tabID)
                            let dto = ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: restored.toolResultJSON)
                            XCTAssertEqual(dto?.chatID, expectedChat)
                            XCTAssertEqual(dto?.mode, expectedMode)
                            XCTAssertNil(dto?.response)
                            XCTAssertEqual(restored.toolIsError, terminal.hasPrefix("abort"))
                            XCTAssertEqual(AgentTranscriptToolNormalizer.status(for: restored), terminal.hasPrefix("abort") ? .failed : .success)
                        }
                    }
                }
            }
        }
    }

    func testNativeSelectionRejectsMalformedAndDeeperRepliesWithoutWeakeningDirectAuthority() throws {
        let singleton = try object(ChatSendReply(chatId: UUID(), shortId: "single", mode: "chat", response: "answer", errors: nil).toMCPValue())
        let group = try OracleGroupResult(groupID: OracleGroupID(rawValue: UUID()), status: .partialFailure, oracleResults: [
            OracleLaneResult(laneIndex: 0, chatID: "primary", providerID: nil, modelID: "primary", status: .completed, response: "answer"),
            OracleLaneResult(laneIndex: 1, chatID: "sibling", providerID: nil, modelID: "sibling", status: .cancelled, error: .init(code: "cancelled", message: "Cancelled"))
        ])
        let groupObject = try object(.object(OracleGroupMCPCodec.groupFields(group)))
        for native in [singleton, groupObject] {
            var direct = native
            direct["rawOutput"] = native["oracle_results"] == nil ? groupObject : singleton
            let raw = try String(decoding: JSONSerialization.data(withJSONObject: direct), as: UTF8.self)
            let dto = ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: raw)
            if native["oracle_results"] == nil {
                XCTAssertEqual(dto?.chatID, "single", "Valid direct native singleton outranks a nested echo")
                XCTAssertNil(dto?.oracleResults)
            } else {
                XCTAssertEqual(dto?.oracleGroupID, group.groupID.rawValue.uuidString)
                XCTAssertEqual(dto?.oracleResults?.map(\.status), ["completed", "cancelled"])
            }
        }
        let jobID = UUID().uuidString
        for invalid in [
            ["chat_id": "single"], ["mode": "chat"], ["chat_id": 42, "mode": "chat"],
            ["chat_id": "single", "mode": 42], ["chat_id": "single", "mode": "chat", "response": 42],
            ["chat_id": "single", "mode": "chat", "errors": [42]],
            ["chat_id": "single", "mode": "chat", "oracle_count": 2, "oracle_results": []],
            ["rawOutput": singleton],
            ["job_id": jobID, "job": ["id": UUID().uuidString, "status": "running"]]
        ] as [[String: Any]] {
            for tool in ["ask_oracle", "oracle_send", "context_builder"] {
                let row = try observation(invalid, tool: tool, representation: "object", tracker: false, terminal: "none", expectRetention: false)
                var items = [row]
                XCTAssertEqual(AgentTranscriptQualityRepair.finalizePendingTerminalTools(in: &items, terminalState: .failed, context: .liveTerminal(agentKind: .devin), nonToolBoundary: 6), 1)
                XCTAssertEqual(items[0].toolIsError, true)
            }
        }
        var generic = [AgentChatItem.toolResult(name: "get_file_tree", argsJSON: nil, resultJSON: #"{"status":"running"}"#, isError: false, sequenceIndex: 1)]
        XCTAssertEqual(AgentTranscriptQualityRepair.finalizePendingTerminalTools(in: &generic, terminalState: .completed, context: .liveTerminal(agentKind: .devin), nonToolBoundary: 6), 1)
        XCTAssertEqual(generic[0].toolIsError, true)
    }

    private func observation(_ native: [String: Any], tool: String, representation: String, tracker: Bool, terminal: String, expectRetention: Bool = true) throws -> AgentChatItem {
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
        let session = harness.makeSession(agent: .devin)
        let runner = ACPIntegratedAgentModeRunner(hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier(), toolTrackingHooks: .noOp, providerFactory: { _, _ in nil }, controllerFactory: { provider, request in try ACPAgentSessionController(provider: provider, runRequest: request) })
        let raw = try String(decoding: JSONSerialization.data(withJSONObject: native), as: UTF8.self)
        func deliver(_ update: [String: Any]) throws {
            let events = ACPDefaultSessionUpdateNormalizer.normalize(update, providerID: .devin)
            guard case let .stream(event) = events.first else { throw NSError(domain: "Missing normalized tool result", code: 1) }
            let invocation = try XCTUnwrap(event.toolInvocationID)
            let payload = try XCTUnwrap(event.toolResultJSON)
            if tracker {
                runner.testHandleTrackerToolResult(invocationID: invocation, toolName: tool, args: nil, resultJSON: payload, isError: event.toolIsError ?? false, session: session)
            } else {
                XCTAssertTrue(runner.handleToolStreamEvent(.toolResult(.init(toolName: tool, invocationID: invocation, argsJSON: nil, resultJSON: payload, isError: event.toolIsError ?? false)), session: session))
            }
        }
        try deliver(["sessionUpdate": "tool_call_update", "toolCallId": "native-observation", "title": tool, "status": representation == "direct" ? "completed" : "running", "rawOutput": representation == "string" ? raw : native])
        let original = try XCTUnwrap(session.items.first)
        if terminal != "none" {
            try deliver(["sessionUpdate": "tool_call_update", "toolCallId": "native-observation", "title": tool, "status": terminal.hasPrefix("abort") ? "failed" : "completed", "rawOutput": terminal.hasPrefix("abort") ? "Provider transport aborted" : "Provider terminal echo"])
        }
        if terminal == "abort-marker" {
            // A later empty successful echo is not a new native result and cannot clear the genuine abort.
            try deliver(["sessionUpdate": "tool_call_update", "toolCallId": "native-observation", "title": tool, "status": "completed", "rawOutput": [String: Any]()])
        }
        var row = try XCTUnwrap(session.items.first)
        XCTAssertEqual(session.items.count, 1)
        XCTAssertEqual(row.id, original.id)
        if expectRetention { XCTAssertEqual(row.toolResultJSON, original.toolResultJSON, "Returned native facts survive the provider \(terminal) on tracker=\(tracker), representation=\(representation)") }
        XCTAssertEqual(row.toolIsError, terminal.hasPrefix("abort"), "The actual failed ACP event must remain an error")
        row.toolArgsJSON = #"{"message":"PRIVATE_INPUT"}"#
        return row
    }

    private func saveLoad(_ row: AgentChatItem, workspace: WorkspaceModel, tabID: UUID) async throws -> AgentChatItem {
        let saved = AgentSession(workspaceID: workspace.id, composeTabID: tabID, name: "Native observation", transcript: AgentTranscriptIO.importLegacyItems([.user("Inspect", sequenceIndex: 0), row]), lastRunState: "completed")
        let file = try await AgentSessionDataService().saveAgentSession(saved, for: workspace)
        let bytes = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(bytes.contains("PRIVATE_INPUT"))
        XCTAssertFalse(bytes.contains("PRIVATE_RESPONSE_BODY"))
        let loaded = try await AgentSessionDataService().loadAgentSession(from: file)
        let projection = try AgentTranscriptProjectionBuilder.build(from: XCTUnwrap(loaded.transcript))
        let rows = (projection.archivedBlocks + projection.workingBlocks).flatMap(\.rows)
        let restored = try XCTUnwrap(rows.first { $0.kind == .toolResult && $0.toolInvocationID == row.toolInvocationID })
        XCTAssertNil(restored.toolArgsJSON)
        XCTAssertLessThanOrEqual(try XCTUnwrap(restored.toolResultJSON).utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
        return restored
    }

    private func object(_ value: Value) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ToolOutputFormatter.rawJSONString(value).utf8)) as? [String: Any])
    }

    private func execute(_ tool: String, args: [String: Value], service: MCPOracleToolService, invocation: ToolInvocationContext) async throws -> Value {
        try await (tool == "ask_oracle" ? service.executeAskOracle(args: args, invocationContext: invocation) : service.executeOracleSend(args: args, invocationContext: invocation))
    }

    private func withOracleFixture(holdTransport: Bool, _ body: @escaping @MainActor (ContextBuilderMultiRootDiscoveryDriver, MCPOracleToolService, ToolInvocationContext) async throws -> Void) async throws {
        try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: ["NativeObservation"]) { driver in
            let settings = GlobalSettingsStore.shared
            let previousExposure = settings.mcpShowModelPresets()
            let previousDisabled = settings.mcpTemporarilyDisablePresets()
            defer {
                settings.setMCPShowModelPresets(previousExposure, commit: false)
                settings.setMCPTemporarilyDisablePresets(previousDisabled, commit: false)
                driver.window.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting(nil)
            }
            settings.setMCPShowModelPresets(false, commit: false)
            settings.setMCPTemporarilyDisablePresets(false, commit: false)
            settings.setWorkspaceAgentModelsProfile(workspaceID: driver.fixture.workspace.id, profile: .init(planningModelRaw: AIModel.gpt54Mini.rawValue, additionalOracleModelRaws: []))
            driver.window.apiSettingsViewModel.openAIApiKey = "test-key"
            driver.window.apiSettingsViewModel.isOpenAIKeyValid = true
            driver.window.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { _, _ in
                let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                    if !holdTransport {
                        continuation.yield(.init(text: "PRIVATE_RESPONSE_BODY", reasoning: nil, tokens: .init(), terminalOutcome: .completed))
                        continuation.finish()
                    }
                }
                return (UUID(), stream)
            }
            let context = MCPTabContextSnapshot(tabID: driver.tabID, windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id, promptText: "", selection: StoredSelection(), selectedMetaPromptIDs: [], tabName: "Native observation", runID: nil, frozenLookupContext: .visibleWorkspace, explicitlyBound: true)
            let invocation = ToolInvocationContext.trustedLocal(toolName: "oracle_send", metadata: MCPRequestMetadata(connectionID: UUID(), clientName: "native-observation-fixture", windowID: driver.window.windowID))
            let service = MCPOracleToolService(
                askOracleToolName: "ask_oracle", oracleSendToolName: "oracle_send", oracleChatLogToolName: "oracle_chat_log",
                promptVM: driver.window.promptManager, oracleVM: driver.window.oracleViewModel,
                liveRunPurpose: { _ in .unknown }, resolveTabContextSnapshot: { _ in .init(snapshot: context) }, requireCurrentTabContext: { _ in context }, stabilizedVirtualContext: { $0 },
                resolveDelegatedReviewPackaging: { _, _, _, _ in nil }, rebindChatSessionIfNeeded: { _, _ in XCTFail("Fresh native requests must not rebind") },
                resolveTabIDForAgentMode: { _, _ in driver.tabID }, requireTargetWindow: { driver.window }, rawExplicitTabID: { _ in nil }, sendStageProgress: { _, _, _, _ in }, withHeartbeat: { _, _, _, _, operation in try await operation() },
                resolveStartExecution: { mode, model, workspaceID in try driver.window.oracleViewModel.resolveMCPFollowUpExecution(mode: mode, modelParam: model, workspaceID: workspaceID) },
                sendChat: { args, prompt, tabContext in try await driver.window.oracleViewModel.tool_chatSendWithConfiguredRoster(args: args, promptVM: prompt, tabContext: tabContext) },
                exportOracleResponse: { _ in throw ChatToolError.internalError("Unexpected fixture export") }, jobCenter: MCPLongRunningJobCenter()
            )
            do {
                try await body(driver, service, invocation)
                await driver.window.oracleViewModel.drainTrackedAutosaves(for: driver.fixture.workspace.id)
            } catch {
                await driver.window.oracleViewModel.drainTrackedAutosaves(for: driver.fixture.workspace.id)
                throw error
            }
        }
    }
}
