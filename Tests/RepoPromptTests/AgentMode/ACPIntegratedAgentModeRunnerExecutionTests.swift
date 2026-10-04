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
        callbacks.settled(result, turn)
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
        absent.settled(result, turn)
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
        try callbacks.settled(OracleGroupResult(groupID: OracleGroupID(rawValue: UUID()), status: result.status, oracleResults: result.oracleResults), turn)
        XCTAssertEqual(session.items.first?.toolResultJSON, failedPayload, "Wrong group has no row authority")
        callbacks.settled(result, OracleTurnID(rawValue: UUID()))
        XCTAssertEqual(session.items.first?.toolResultJSON, failedPayload, "Wrong turn has no row authority")
        currentOwner = nil
        callbacks.settled(result, turn)
        XCTAssertEqual(session.items.first?.toolResultJSON, failedPayload, "Replaced tab owner fences the old settlement")
        currentOwner = session
        callbacks.settled(result, turn)
        XCTAssertEqual(session.items.map(\.id), [rowID])
        XCTAssertTrue(session.items.first?.toolArgsJSON?.contains("new_chat") == true)
        XCTAssertEqual(session.items.first?.toolIsError, true)
        let execution = try XCTUnwrap(AgentTranscriptToolNormalizer.toolExecution(for: session.items[0]))
        XCTAssertEqual(execution.status, .warning)
        XCTAssertTrue(execution.resultJSON?.contains(group.rawValue.uuidString) == true)
        let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: execution.resultJSON))
        let coverage = try XCTUnwrap(OracleLaneCoverage(lanes: dto.oracleResults, oracleCount: dto.oracleCount))
        XCTAssertEqual(coverage.completedCount, 1)
        XCTAssertEqual(coverage.totalCount, 2)
        let settledPayload = session.items.first?.toolResultJSON
        session.installRunID(UUID())
        let changed = try OracleGroupResult(groupID: group, status: .completed, oracleResults: [
            OracleLaneResult(laneIndex: 0, chatID: "primary", providerID: nil, modelID: "primary-model", status: .completed, response: "changed"),
            OracleLaneResult(laneIndex: 1, chatID: "sibling", providerID: nil, modelID: "sibling-model", status: .completed, response: "changed")
        ])
        callbacks.settled(changed, turn)
        XCTAssertEqual(session.items.first?.toolResultJSON, settledPayload, "Installing a successor run ID already fences the old settlement")
        session.beginRunAttempt(source: "successor")
        callbacks.settled(changed, turn)
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
    func testSubstantiveTerminalTextAndArraysReplaceProviderLifecycleOnBothRunnerPaths() throws {
        for trackerPath in [false, true] {
            for output: Any in ["terminal finding", [["type": "text", "text": "terminal finding"]]] {
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
