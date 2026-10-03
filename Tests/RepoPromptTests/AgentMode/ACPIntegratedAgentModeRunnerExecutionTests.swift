@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import XCTest

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
