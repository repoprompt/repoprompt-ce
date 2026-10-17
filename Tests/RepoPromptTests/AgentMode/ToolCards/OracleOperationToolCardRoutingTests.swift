import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import XCTest

#if DEBUG
    /// Real Oracle tool execution: a real `MCPOracleToolService` and job center over the window's
    /// `OracleViewModel` roster dispatch. Only the post-packaging provider transport is substituted,
    /// by `ControlledOracleProvider`, so tickets, claims, lane scopes, and persistence stay real.
    @MainActor
    enum OracleTicketExecutionHarness {
        /// Fixed provider behavior for the whole fixture. `.held` streams end only by cancellation.
        enum Outcome { case held, failed, completed, partialGroup }

        enum EntryPath: CaseIterable { case blocking, ticket }

        /// Nested types don't inherit the enum's isolation; its members read main-actor state.
        @MainActor
        struct Context {
            let driver: ContextBuilderMultiRootDiscoveryDriver
            let service: MCPOracleToolService
            let invocation: ToolInvocationContext
            let provider: ControlledOracleProvider
            let preparation: PreparationGate

            var oracle: OracleViewModel {
                driver.window.oracleViewModel
            }

            var owner: OracleConversationOwner {
                get throws { try OracleViewModel.oracleGroupOwner(workspaceID: driver.fixture.workspace.id, tabID: driver.tabID) }
            }

            /// The same canonical store the app's Oracle group runtime and lane claims use.
            func loadGroup(_ groupID: String) async throws -> OracleGroupDocument {
                let id = try OracleGroupID(rawValue: XCTUnwrap(UUID(uuidString: groupID)))
                let loaded = try await AppDomainRuntimeComposition.shared.oracleConversationStore.load(groupID: id, owner: owner)
                return try XCTUnwrap(loaded)
            }

            /// Lane projections ordered by lane index.
            func lanes(ofGroup groupID: String) -> [ChatSession] {
                oracle.sessions
                    .filter { $0.oracleGroupID?.uuidString == groupID }
                    .sorted { ($0.oracleLaneIndex ?? 0) < ($1.oracleLaneIndex ?? 0) }
            }

            func awaitSends(_ count: Int) async throws {
                try await driver.fixture.awaitGateEvent(provider.sendsReached(count))
            }
        }

        /// Suspends the next real Oracle preparation at its first await (context stabilization),
        /// before job admission. Single-shot so later preparations run unimpeded.
        @MainActor
        final class PreparationGate {
            private var suspension: (entered: XCTestExpectation, gate: AsyncStream<Void>)?
            private var release: AsyncStream<Void>.Continuation?

            /// Arms the gate; the returned expectation is fulfilled once preparation is suspended.
            func arm() -> XCTestExpectation {
                let entered = XCTestExpectation(description: "Oracle preparation suspended")
                let (stream, continuation) = AsyncStream<Void>.makeStream()
                suspension = (entered, stream)
                release = continuation
                return entered
            }

            func open() {
                release?.finish()
                release = nil
            }

            func passThrough() async {
                guard let armed = suspension else { return }
                suspension = nil
                armed.entered.fulfill()
                for await _ in armed.gate {}
            }
        }

        static func withFixture(
            outcome: Outcome,
            retention: TimeInterval = 3600,
            _ body: @escaping @MainActor (ContextBuilderMultiRootDiscoveryDriver, MCPOracleToolService, ToolInvocationContext) async throws -> Void
        ) async throws {
            try await withControlledFixture(
                rootName: "OracleTicketCard",
                additionalModels: outcome == .partialGroup ? [.gpt54] : [],
                retention: retention,
                allowsRebind: false
            ) { context in
                context.provider.behavior = { model in
                    switch outcome {
                    case .held: .hold
                    case .failed: .fail
                    case .completed: .complete
                    case .partialGroup: model == .gpt54 ? .fail : .complete
                    }
                }
                try await body(context.driver, context.service, context.invocation)
            }
        }

        /// The primary lane is `.gpt54Mini`; `additionalModels` configure further lanes.
        /// Explicit `chat_id` continuations rebind the visible chat; `allowsRebind: false`
        /// asserts a request never does.
        static func withControlledFixture(
            rootName: String = "OracleTicketExecution",
            additionalModels: [AIModel],
            retention: TimeInterval = 3600,
            allowsRebind: Bool = true,
            _ body: @escaping @MainActor (Context) async throws -> Void
        ) async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: [rootName]) { driver in
                let settings = GlobalSettingsStore.shared
                let previousExposure = settings.mcpShowModelPresets()
                let previousDisabled = settings.mcpTemporarilyDisablePresets()
                let provider = ControlledOracleProvider()
                let preparation = PreparationGate()
                defer {
                    preparation.open()
                    settings.setMCPShowModelPresets(previousExposure, commit: false)
                    settings.setMCPTemporarilyDisablePresets(previousDisabled, commit: false)
                    driver.window.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting(nil)
                }
                settings.setMCPShowModelPresets(false, commit: false)
                settings.setMCPTemporarilyDisablePresets(false, commit: false)
                settings.setWorkspaceAgentModelsProfile(workspaceID: driver.fixture.workspace.id, profile: .init(planningModelRaw: AIModel.gpt54Mini.rawValue, additionalOracleModelRaws: additionalModels.map(\.rawValue)))
                driver.window.apiSettingsViewModel.openAIApiKey = "test-key"
                driver.window.apiSettingsViewModel.isOpenAIKeyValid = true
                driver.window.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { [provider] message, model in
                    provider.transport(message, model)
                }
                let context = MCPTabContextSnapshot(tabID: driver.tabID, windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id, promptText: "", selection: StoredSelection(), selectedMetaPromptIDs: [], tabName: rootName, runID: nil, frozenLookupContext: .visibleWorkspace, explicitlyBound: true)
                let invocation = ToolInvocationContext.trustedLocal(toolName: "oracle_send", metadata: MCPRequestMetadata(connectionID: UUID(), clientName: "oracle-ticket-execution-harness", windowID: driver.window.windowID))
                let service = MCPOracleToolService(
                    askOracleToolName: "ask_oracle", oracleSendToolName: "oracle_send", oracleChatLogToolName: "oracle_chat_log",
                    promptVM: driver.window.promptManager, oracleVM: driver.window.oracleViewModel,
                    liveRunPurpose: { _ in .unknown }, resolveTabContextSnapshot: { _ in .init(snapshot: context) }, requireCurrentTabContext: { _ in context }, stabilizedVirtualContext: { [preparation] snapshot in
                        await preparation.passThrough()
                        return snapshot
                    },
                    resolveDelegatedReviewPackaging: { _, _, _, _ in nil },
                    rebindChatSessionIfNeeded: { _, _ in if !allowsRebind { XCTFail("New ticket requests must not rebind") } },
                    resolveTabIDForAgentMode: { _, _ in driver.tabID }, requireTargetWindow: { driver.window }, rawExplicitTabID: { _ in nil }, sendStageProgress: { _, _, _, _ in }, withHeartbeat: { _, _, _, _, operation in try await operation() },
                    resolveStartExecution: { mode, model, workspaceID in try driver.window.oracleViewModel.resolveMCPFollowUpExecution(mode: mode, modelParam: model, workspaceID: workspaceID) },
                    sendChat: { args, prompt, tabContext in try await driver.window.oracleViewModel.tool_chatSendWithConfiguredRoster(args: args, promptVM: prompt, tabContext: tabContext) },
                    exportOracleResponse: { _ in throw ChatToolError.internalError("Unexpected fixture export") }, jobCenter: MCPLongRunningJobCenter(store: DomainLongRunningJobStore(retention: retention))
                )
                let fixtureContext = Context(driver: driver, service: service, invocation: invocation, provider: provider, preparation: preparation)
                do {
                    try await body(fixtureContext)
                    preparation.open()
                    provider.finishHeld()
                    await driver.window.oracleViewModel.drainTrackedAutosaves(for: driver.fixture.workspace.id)
                } catch {
                    // Never leave a producer parked on a held stream across driver shutdown.
                    preparation.open()
                    provider.finishHeld()
                    await driver.window.oracleViewModel.drainTrackedAutosaves(for: driver.fixture.workspace.id)
                    throw error
                }
            }
        }

        static func execute(_ tool: String, args: [String: Value], service: MCPOracleToolService, invocation: ToolInvocationContext) async throws -> Value {
            try await (tool == "ask_oracle" ? service.executeAskOracle(args: args, invocationContext: invocation) : service.executeOracleSend(args: args, invocationContext: invocation))
        }
    }

    /// Provider transport whose streams complete, fail, or hold until the test releases them.
    /// Waits are expectation-based (`sendsReached`), never wall-clock polling.
    @MainActor
    final class ControlledOracleProvider {
        enum Behavior { case complete, fail, hold }

        static let failureMessage = "Controlled provider failure"
        static let completedText = "PRIVATE_CARD_RESPONSE"

        var behavior: (AIModel) -> Behavior = { _ in .complete }
        private(set) var models: [AIModel] = []
        private var held: [AsyncThrowingStream<ChatStreamOutput, Error>.Continuation] = []
        private var sendWaiters: [(count: Int, expectation: XCTestExpectation)] = []

        var sendCount: Int {
            models.count
        }

        var heldCount: Int {
            held.count
        }

        func transport(_: AIMessage, _ model: AIModel) -> (id: ChatStreamID, stream: AsyncThrowingStream<ChatStreamOutput, Error>) {
            let (stream, continuation) = AsyncThrowingStream<ChatStreamOutput, Error>.makeStream()
            switch behavior(model) {
            case .complete:
                Self.complete(continuation, text: Self.completedText)
            case .fail:
                continuation.finish(throwing: ChatToolError.internalError(Self.failureMessage))
            case .hold:
                held.append(continuation)
            }
            models.append(model)
            let reached = sendWaiters.filter { $0.count <= models.count }
            sendWaiters.removeAll { $0.count <= models.count }
            reached.forEach { $0.expectation.fulfill() }
            return (UUID(), stream)
        }

        /// Fulfilled once `count` provider sends have started (immediately if already reached).
        func sendsReached(_ count: Int) -> XCTestExpectation {
            let expectation = XCTestExpectation(description: "\(count) Oracle provider sends")
            if models.count >= count { expectation.fulfill() } else { sendWaiters.append((count: count, expectation: expectation)) }
            return expectation
        }

        /// Completes every held stream with a provider-completed answer.
        func releaseHeld(text: String = completedText) {
            let pending = held
            held.removeAll()
            pending.forEach { Self.complete($0, text: text) }
        }

        /// Ends every held stream without a provider answer (fixture cleanup only).
        func finishHeld() {
            let pending = held
            held.removeAll()
            pending.forEach { $0.finish() }
        }

        private static func complete(_ continuation: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation, text: String) {
            continuation.yield(.init(text: text, reasoning: nil, tokens: .init(), terminalOutcome: .completed))
            continuation.finish()
        }
    }
#endif

final class OracleOperationToolCardRoutingTests: XCTestCase {
    @MainActor
    func testContextBuilderValidatedACPTicketOutranksConflictingContentInLiveAndRestoredCards() async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -9863, deferredInitialAgentSystemWorkspaceRefresh: true, sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        defer {
            composition.contextBuilderAgentViewModel.prepareForWindowClose()
            composition.workspaceManager.prepareForWindowClose()
        }
        addTeardownBlock { await composition.workspaceManager.awaitOwnSavesForWindowClose() }
        let tabID = UUID()
        let jobID = UUID()
        let context = ContextBuilderCardContext(
            tabID: tabID, contextBuilderAgentVM: composition.contextBuilderAgentViewModel,
            oracleOpenContext: nil
        )
        func normalizedItem(rawOutput: [String: Any]) throws -> AgentChatItem {
            let events = CursorACPEventNormalizer.normalize([
                "sessionUpdate": "tool_call_update", "toolCallId": "fixture-context-builder-observation",
                "title": "context_builder", "status": "completed", "rawOutput": rawOutput,
                "content": [["type": "text", "text": #"{"status":"completed"}"#]]
            ])
            guard events.count == 1, case let .stream(output) = events[0] else {
                throw NSError(domain: "ContextBuilderACPFixture", code: 1)
            }
            XCTAssertEqual(output.type, "tool_result")
            XCTAssertEqual(output.toolName, "context_builder")
            return try AgentChatItem(
                kind: .toolResult, text: "", toolName: output.toolName, toolInvocationID: output.toolInvocationID,
                toolResultJSON: XCTUnwrap(output.toolResultJSON), toolIsError: output.toolIsError
            )
        }
        let original = try normalizedItem(rawOutput: [
            "job_id": jobID.uuidString,
            "job": ["id": jobID.uuidString, "context_id": tabID.uuidString, "status": "running", "revision": 3]
        ])
        let rawPayload = try XCTUnwrap(original.toolResultJSON)
        let normalizedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rawPayload.utf8)) as? [String: Any])
        XCTAssertNotNil(normalizedObject["content"], "Exercise the real ACP envelope, including its conflicting structured content")
        XCTAssertNotNil(normalizedObject["rawOutput"])
        let sanitized = AgentToolResultPersistencePolicy.sanitizeItem(original)
        let bubble = AgentMessageBubble(
            item: sanitized, windowID: -9863, currentTabID: tabID, contextBuilderContext: context,
            rawToolResultPayload: rawPayload
        )
        let liveItem = bubble.renderingItem
        XCTAssertEqual(liveItem.toolResultJSON, rawPayload, "Exercise the actual live raw-payload override, not the sanitized summary")
        let dto = try XCTUnwrap(ToolJSON.decodeResult(ToolResultDTOs.ContextBuilderDTO.self, from: liveItem.toolResultJSON))
        XCTAssertEqual(dto.ticket?.jobID, jobID)
        XCTAssertEqual(dto.ticket?.job.status, .running)
        let liveCard = ContextBuilderResultCard(item: liveItem, context: context)
        XCTAssertEqual(liveCard.status, .neutral)
        XCTAssertTrue(liveCard.summary.contains("running"), liveCard.summary)
        XCTAssertTrue(liveCard.summary.contains(jobID.uuidString), liveCard.summary)

        var restored = original
        for _ in 0 ..< 2 {
            restored.toolResultJSON = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: restored)).resultJSON
            restored = try JSONDecoder().decode(AgentChatItem.self, from: JSONEncoder().encode(restored))
            let restoredDTO = try XCTUnwrap(ToolJSON.decodeResult(ToolResultDTOs.ContextBuilderDTO.self, from: restored.toolResultJSON))
            XCTAssertEqual(restoredDTO.ticket?.jobID, jobID)
            let restoredCard = ContextBuilderResultCard(item: restored, context: context)
            XCTAssertEqual(restoredCard.status, .neutral)
            XCTAssertTrue(restoredCard.summary.contains("Live job state unknown"), restoredCard.summary)
        }
        for nonTicket in [
            ["status": "running", "message": "untrusted arbitrary raw output"],
            ["job_id": jobID.uuidString, "job": ["id": UUID().uuidString, "status": "running"]]
        ] as [[String: Any]] {
            let item = try normalizedItem(rawOutput: nonTicket)
            let decoded = try XCTUnwrap(ToolJSON.decodeResult(ToolResultDTOs.ContextBuilderDTO.self, from: item.toolResultJSON))
            XCTAssertNil(decoded.ticket)
            XCTAssertEqual(decoded.status, "completed", "Non-ticket content keeps the legacy structured-envelope precedence")
            XCTAssertEqual(ContextBuilderResultCard(item: item, context: context).status, .success)
        }
        let legacy = AgentChatItem(kind: .toolResult, text: "", toolName: "context_builder", toolResultJSON: #"{"status":"completed"}"#, toolIsError: false)
        XCTAssertEqual(ContextBuilderResultCard(item: legacy, context: context).status, .success)
    }

    #if DEBUG
        /// Only control operations and detached starts are observation-only call cards. A blocking
        /// start (detach omitted/false/non-boolean) follows the real tab run and follow-up state.
        @MainActor
        func testBlockingContextBuilderStartKeepsLiveCardWhileDetachedStartAndControlOpsObserve() async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver { driver in
                let vm = driver.vm
                let tabID = driver.tabID
                let jobID = UUID().uuidString
                let cases: [(args: [String: Any], observes: Bool)] = [
                    (["op": "start"], false),
                    (["op": "start", "detach": false], false),
                    (["op": "start", "detach": "true"], false),
                    (["detach": true], false),
                    (["op": "status", "job_id": jobID], false),
                    (["op": "start", "detach": true], true),
                    (["op": " Poll ", "job_id": jobID], true),
                    (["op": "wait", "job_id": jobID, "timeout": 1], true),
                    (["op": "cancel", "job_id": jobID], true)
                ]
                func callRow(_ args: [String: Any], sequence: Int) -> AgentChatItem {
                    AgentChatItem(
                        kind: .toolCall, text: "", toolName: "context_builder", toolInvocationID: UUID(),
                        toolArgsJSON: self.jsonString(args), sequenceIndex: sequence
                    )
                }
                func card(_ item: AgentChatItem, rows: [AgentChatItem]) -> ContextBuilderCallCard {
                    ContextBuilderCallCard(item: item, context: ContextBuilderCardContext(
                        tabID: tabID, contextBuilderAgentVM: vm, oracleOpenContext: nil,
                        transcriptMetadata: ContextBuilderTranscriptMetadata(rows: rows)
                    ))
                }

                // A real UI run holds its provider stream, so the tab's run is genuinely active.
                let entered = XCTestExpectation(description: "Context Builder provider stream entered")
                let hold = driver.fixture.makeGate()
                driver.streamBody = { _ in
                    entered.fulfill()
                    await hold.wait()
                }
                vm.runContextBuilderAgent()
                let runID = try XCTUnwrap(vm.activeRunIDForTesting(tabID: tabID))
                try await driver.fixture.awaitGateEvent(entered)
                XCTAssertTrue(vm.tabsWithActiveContextBuilderRun.contains(tabID))
                for (args, observes) in cases {
                    let call = callRow(args, sequence: 1)
                    XCTAssertEqual(ContextBuilderTranscriptMetadata(rows: [call]).activeCallItemID, call.id)
                    let active = card(call, rows: [call])
                    XCTAssertEqual(active.title, observes ? "Context Builder observation" : "Context Builder", "\(args)")
                    XCTAssertEqual(active.status, observes ? .neutral : .running, "\(args)")
                    if observes {
                        XCTAssertEqual(active.summary, "Ticket request observation", "\(args)")
                    } else {
                        XCTAssertTrue(active.summary.hasPrefix("running"), "\(args): \(active.summary)")
                    }
                }

                // An unrelated historical blocking call stays completed while a later invocation runs.
                let historical = callRow(["op": "start"], sequence: 1)
                let historicalResult = AgentChatItem(
                    kind: .toolResult, text: "", toolName: "context_builder", toolInvocationID: historical.toolInvocationID,
                    toolResultJSON: #"{"status":"completed"}"#, toolIsError: false, sequenceIndex: 2
                )
                let current = callRow(["op": "start"], sequence: 3)
                let rows = [historical, historicalResult, current]
                XCTAssertEqual(card(historical, rows: rows).status, .success)
                XCTAssertEqual(card(current, rows: rows).status, .running)

                await vm.cancelAgentRun()
                hold.release()
                try await driver.fixture.awaitGateEvent(driver.teardownExpectation(runID: runID))
                XCTAssertFalse(vm.tabsWithActiveContextBuilderRun.contains(tabID))

                // A blocking start that returns a ticket snapshot (observation timeout) is still an
                // observation result; its settled call card no longer claims the live run.
                let returned = AgentChatItem(
                    kind: .toolResult, text: "", toolName: "context_builder", toolInvocationID: current.toolInvocationID,
                    toolResultJSON: self.jsonString(["job_id": jobID, "job": ["id": jobID, "context_id": tabID.uuidString, "status": "running", "revision": 1]]),
                    toolIsError: false, sequenceIndex: 4
                )
                let resultContext = ContextBuilderCardContext(
                    tabID: tabID, contextBuilderAgentVM: vm, oracleOpenContext: nil,
                    transcriptMetadata: ContextBuilderTranscriptMetadata(rows: rows + [returned])
                )
                let resultCard = ContextBuilderResultCard(item: returned, context: resultContext)
                XCTAssertEqual(resultCard.title, "Context Builder observation")
                XCTAssertEqual(resultCard.status, .neutral)
                XCTAssertTrue(resultCard.summary.contains(jobID), resultCard.summary)
                XCTAssertEqual(ContextBuilderCallCard(item: current, context: resultContext).status, .success)

                // Follow-up generation keeps its plan-progress presentation for blocking starts only.
                vm.setBackgroundPlanGenerating(true, forTabID: tabID)
                defer { vm.setBackgroundPlanGenerating(false, forTabID: tabID) }
                for (args, observes) in cases {
                    let call = callRow(args, sequence: 1)
                    let generating = card(call, rows: [call])
                    XCTAssertEqual(generating.status, observes ? .neutral : .running, "\(args)")
                    XCTAssertEqual(generating.summary.hasPrefix("generating"), !observes, "\(args): \(generating.summary)")
                }
            }
        }
    #endif

    @MainActor
    func testContextBuilderTicketObservationsDoNotBecomeCompletedRuns() async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -9861, deferredInitialAgentSystemWorkspaceRefresh: true, sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        defer {
            composition.contextBuilderAgentViewModel.prepareForWindowClose()
            composition.workspaceManager.prepareForWindowClose()
        }
        addTeardownBlock { await composition.workspaceManager.awaitOwnSavesForWindowClose() }
        let tabID = UUID()
        let jobID = UUID().uuidString
        let context = ContextBuilderCardContext(
            tabID: tabID, contextBuilderAgentVM: composition.contextBuilderAgentViewModel,
            oracleOpenContext: nil
        )
        var rows: [AgentChatItem] = []
        for (sequence, operation) in ["start", "wait", "wait"].enumerated() {
            let invocationID = UUID()
            rows.append(AgentChatItem(
                kind: .toolCall, text: "", toolName: "context_builder", toolInvocationID: invocationID,
                toolArgsJSON: jsonString(operation == "start" ? ["op": operation, "detach": true] : ["op": operation, "job_id": jobID]), sequenceIndex: sequence * 2
            ))
            let result = AgentChatItem(
                kind: .toolResult, text: "", toolName: "context_builder", toolInvocationID: invocationID,
                toolResultJSON: jsonString([
                    "job_id": jobID, "job": [
                        "id": jobID,
                        "kind": "context_builder",
                        "context_id": tabID.uuidString,
                        "status": "running",
                        "revision": sequence + 1
                    ]
                ]), toolIsError: false, sequenceIndex: sequence * 2 + 1
            )
            rows.append(result)
            let card = ContextBuilderResultCard(item: result, context: context)
            XCTAssertEqual(card.status, .neutral)
            XCTAssertTrue(card.summary.contains("running"), card.summary)
            XCTAssertTrue(card.summary.contains(jobID), card.summary)
            var acpResult = result
            let rawOutput = try JSONSerialization.jsonObject(with: Data(XCTUnwrap(result.toolResultJSON).utf8))
            acpResult.toolResultJSON = jsonString(["status": "success", "acp_status": "completed", "rawOutput": rawOutput])
            let acpCard = ContextBuilderResultCard(item: acpResult, context: context)
            XCTAssertEqual(acpCard.status, .neutral)
            XCTAssertTrue(acpCard.summary.contains("running"), acpCard.summary)
            XCTAssertTrue(acpCard.summary.contains(jobID), acpCard.summary)
        }
        XCTAssertEqual(rows.count, 6, "Control observations must remain in history")
        let foreignTabID = UUID()
        let foreignInvocationID = UUID()
        rows.append(AgentChatItem(
            kind: .toolResult, text: "", toolName: "context_builder", toolInvocationID: foreignInvocationID,
            toolResultJSON: jsonString([
                "job_id": jobID, "job": ["id": jobID, "context_id": foreignTabID.uuidString, "status": "running", "revision": 9]
            ]), toolIsError: false, sequenceIndex: 7
        ))
        let projection = ContextBuilderTranscriptMetadata(rows: rows)
        XCTAssertEqual(projection.ticket(forInvocationID: rows[0].toolInvocationID)?.job.contextID, tabID)
        XCTAssertEqual(projection.ticket(forInvocationID: foreignInvocationID)?.job.contextID, foreignTabID)
        let projectedContext = ContextBuilderCardContext(
            tabID: tabID, contextBuilderAgentVM: composition.contextBuilderAgentViewModel,
            oracleOpenContext: nil,
            transcriptMetadata: projection
        )
        for call in rows.filter({ $0.kind == .toolCall }) {
            let card = ContextBuilderCallCard(item: call, context: projectedContext)
            XCTAssertEqual(card.title, "Context Builder observation")
            XCTAssertEqual(card.status, .neutral)
            XCTAssertTrue(card.summary.contains(jobID), card.summary)
        }
        XCTAssertTrue(try projection.isHistoricalResult(rows[1].id, job: XCTUnwrap(projection.ticket(forInvocationID: rows[0].toolInvocationID)?.job)))
        for (jobStatus, completedCount, exportFailed, expected) in [
            ("completed", 1, false, ToolCardStatus.warning),
            ("completed", 0, false, .failure),
            ("cancelled", 1, false, .failure),
            ("completed", 2, true, .warning)
        ] {
            let lanes = try (0 ..< 2).map { index in
                try OracleLaneResult(
                    laneIndex: index, chatID: "fixture-chat-\(index)", providerID: "custom", modelID: "model-\(index)",
                    status: index < completedCount ? .completed : .failed,
                    response: index < completedCount ? "Paid answer" : nil,
                    error: index < completedCount ? nil : OracleLaneError(code: "provider_error", message: "Provider stopped")
                )
            }
            let result = try OracleGroupResult(
                groupID: OracleGroupID(rawValue: UUID()),
                status: completedCount == 2 ? .completed : completedCount > 0 ? .partialFailure : .failed,
                oracleResults: lanes
            )
            let reply = try JSONSerialization.jsonObject(with: JSONEncoder().encode(OracleGroupMCPCodec.groupFields(result)))
            var payload: [String: Any] = [
                "status": "success", "response_type": "review", "review": reply,
                "job_id": jobID, "job": ["id": jobID, "context_id": tabID.uuidString, "status": jobStatus]
            ]
            if exportFailed { payload["oracle_export_error"] = "Export cancelled; paid text retained" }
            let item = AgentChatItem(kind: .toolResult, text: "", toolName: "context_builder", toolResultJSON: jsonString(payload), toolIsError: false)
            let freshCard = ContextBuilderResultCard(item: item, context: context)
            XCTAssertEqual(freshCard.status, expected)
            if exportFailed { XCTAssertTrue(freshCard.summary.contains("export incomplete"), freshCard.summary) }
            var restored = item
            for _ in 0 ..< 2 {
                restored.toolResultJSON = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: restored)).resultJSON
                let restoredCard = ContextBuilderResultCard(item: restored, context: context)
                XCTAssertEqual(restoredCard.status, expected)
                if exportFailed { XCTAssertTrue(restoredCard.summary.contains("export incomplete"), restoredCard.summary) }
                let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: restored.toolResultJSON))
                XCTAssertEqual(dto.ticket?.jobID.uuidString, jobID)
                XCTAssertEqual(dto.ticket?.job.status.rawValue, jobStatus)
            }
        }
        let expired = AgentChatItem(
            kind: .toolResult, text: "", toolName: "context_builder",
            toolResultJSON: jsonString(["job_id": jobID, "job": ["id": jobID, "status": "expired"]]), toolIsError: false
        )
        XCTAssertEqual(ContextBuilderResultCard(item: expired, context: context).status, .warning)
        let legacy = AgentChatItem(kind: .toolResult, text: "", toolName: "context_builder", toolResultJSON: #"{"status":"completed"}"#, toolIsError: false)
        XCTAssertEqual(ContextBuilderResultCard(item: legacy, context: context).status, .success)
    }

    @MainActor
    func testContextBuilderRepeatedWaitBubbleKeepsOneJobCardAndAllObservationHistory() async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -9864, deferredInitialAgentSystemWorkspaceRefresh: true, sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        defer {
            composition.contextBuilderAgentViewModel.prepareForWindowClose()
            composition.workspaceManager.prepareForWindowClose()
        }
        addTeardownBlock { await composition.workspaceManager.awaitOwnSavesForWindowClose() }
        let tabID = try XCTUnwrap(UUID(uuidString: "33F100C7-B1DE-4DDA-9E60-6807BB309E2F"))
        let jobID = "081AD0C7-0076-49A6-B678-58B075F587E1"
        let invocations = try [
            "D0997750-9338-55B5-8D05-0586C8E1F521", "EA5DF0E2-81DC-5EE5-A8C3-86967C9677AC",
            "2792BE94-7883-50FC-A732-69E6C9E041CA", "7548C77B-D329-5438-8C1D-0615F8E181C4"
        ].map { try XCTUnwrap(UUID(uuidString: $0)) }
        let revisions = [1, 18, 25, 33]
        var rows = [AgentChatItem.user("Observe one builder job", sequenceIndex: 0)]
        for (index, revision) in revisions.enumerated() {
            rows.append(.assistant("Observation \(index)", sequenceIndex: rows.count))
            var payload: [String: Any] = [
                "job_id": jobID, "job": ["id": jobID, "context_id": tabID.uuidString, "status": index == 3 ? "completed" : "running", "revision": revision]
            ]
            if index == 3 {
                payload["status"] = "success"
                payload["response_type"] = "question"
                let lanes = try (0 ..< 4).map { lane in
                    try OracleLaneResult(
                        laneIndex: lane, chatID: "fixture-chat-\(lane)", providerID: "custom", modelID: "model-\(lane)",
                        status: .completed, response: "Retained answer \(lane)"
                    )
                }
                let group = try OracleGroupResult(groupID: OracleGroupID(rawValue: UUID()), status: .completed, oracleResults: lanes)
                payload["plan"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(OracleGroupMCPCodec.groupFields(group)))
            }
            rows.append(AgentChatItem(
                timestamp: Date(timeIntervalSince1970: Double(revision)), kind: .toolResult, text: "",
                toolName: "context_builder", toolInvocationID: invocations[index],
                toolArgsJSON: jsonString(index == 0 ? ["op": "start", "detach": true] : ["op": "wait", "job_id": jobID, "timeout": 1]),
                toolResultJSON: jsonString(payload), toolIsError: false, sequenceIndex: rows.count
            ))
        }
        let originalRows = rows
        let originalHistory = AgentTranscriptIO.buildConversationHistory(from: AgentTranscriptIO.importLegacyItems(rows))

        func assembledViews<Value>(_ items: [AgentChatItem], as type: Value.Type) -> [Value] {
            let context = ContextBuilderCardContext(
                tabID: tabID, contextBuilderAgentVM: composition.contextBuilderAgentViewModel,
                oracleOpenContext: nil, transcriptMetadata: ContextBuilderTranscriptMetadata(rows: items)
            )
            return items.filter { $0.kind == .toolResult }.flatMap { item in
                allocatedBubbleViews(in: AgentMessageBubble(item: item, windowID: -9864, currentTabID: tabID, contextBuilderContext: context).body, as: type)
            }
        }
        for count in [1, 2, 3, 4] {
            let observed = Array(rows.prefix(1 + count * 2))
            let cards = assembledViews(observed, as: ContextBuilderResultCard.self)
            let history = assembledViews(observed, as: ContextBuilderObservationHistoryRow.self)
            XCTAssertEqual(history.map(\.item.toolInvocationID), Array(invocations.prefix(count - 1)).map(Optional.some))
            XCTAssertEqual(history.map(\.item.id), observed.filter { $0.kind == .toolResult }.dropLast().map(\.id))
            XCTAssertEqual(history.map(\.ticket.job.revision), Array(revisions.prefix(count - 1)).map(Optional.some))
            XCTAssertTrue(history.allSatisfy { $0.summary.contains("running") })
            XCTAssertEqual(cards.count, 1, "Actual bubble allocation after \(count) distinct invocations")
            XCTAssertEqual(cards.last?.item.toolInvocationID, invocations[count - 1], "Use the exact latest-revision result, not a synthesized payload")
            XCTAssertEqual(cards.last?.status, count == 4 ? .success : .neutral)
            if count == 4 {
                XCTAssertTrue(cards.last?.summary.contains("4/4 lanes") == true)
                XCTAssertEqual(cards.last?.followUpChatID, "fixture-chat-0")
            }
        }
        XCTAssertEqual(rows, originalRows)
        XCTAssertEqual(AgentTranscriptIO.buildConversationHistory(from: AgentTranscriptIO.importLegacyItems(rows)), originalHistory)
        for _ in 0 ..< 2 {
            rows = try JSONDecoder().decode([AgentChatItem].self, from: JSONEncoder().encode(rows.map(AgentToolResultPersistencePolicy.sanitizeItem)))
            let results = rows.filter { $0.kind == .toolResult }
            XCTAssertEqual(results.map(\.toolInvocationID), invocations.map(Optional.some))
            XCTAssertEqual(try results.map { try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: $0.toolResultJSON)?.ticket?.job.revision) }, revisions)
            XCTAssertEqual(rows.map(\.id), originalRows.map(\.id))
            XCTAssertEqual(AgentTranscriptIO.buildConversationHistory(from: AgentTranscriptIO.importLegacyItems(rows)), originalHistory)
            let running = assembledViews(Array(rows.prefix(7)), as: ContextBuilderResultCard.self)
            XCTAssertEqual(running.count, 1)
            XCTAssertEqual(running.last?.status, .neutral)
            XCTAssertTrue(running.last?.summary.contains("Live job state unknown") == true)
        }
    }

    @MainActor
    func testContextBuilderBubbleCompactionPreservesExceptionalAndUnidentifiedObservations() async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -9865, deferredInitialAgentSystemWorkspaceRefresh: true, sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        defer {
            composition.contextBuilderAgentViewModel.prepareForWindowClose()
            composition.workspaceManager.prepareForWindowClose()
        }
        addTeardownBlock { await composition.workspaceManager.awaitOwnSavesForWindowClose() }
        let tabID = UUID()
        let jobID = UUID().uuidString
        func result(status: String = "running", revision: Int? = 18, contextID: UUID? = nil, error: Bool = false) -> AgentChatItem {
            var job: [String: Any] = ["id": jobID, "context_id": (contextID ?? tabID).uuidString, "status": status]
            if let revision { job["revision"] = revision }
            return AgentChatItem(
                kind: .toolResult, text: "", toolName: "context_builder", toolInvocationID: UUID(),
                toolArgsJSON: jsonString(["op": "wait", "job_id": jobID, "timeout": 1]),
                toolResultJSON: jsonString(["job_id": jobID, "job": job]), toolIsError: error
            )
        }
        func views<Value>(_ rows: [AgentChatItem], as type: Value.Type) -> [Value] {
            let context = ContextBuilderCardContext(
                tabID: tabID, contextBuilderAgentVM: composition.contextBuilderAgentViewModel,
                oracleOpenContext: .init(windowID: -9865, workspaceID: UUID(), tabID: tabID),
                showRunScopedToolCancel: true, cancelActiveToolsAction: {},
                transcriptMetadata: ContextBuilderTranscriptMetadata(rows: rows)
            )
            return rows.flatMap {
                allocatedBubbleViews(in: AgentMessageBubble(item: $0, windowID: -9865, currentTabID: tabID, contextBuilderContext: context).body, as: type)
            }
        }
        for (name, prior, expected) in [
            ("abort", result(error: true), ToolCardStatus.failure),
            ("failed job", result(status: "failed"), .failure),
            ("cancelled job", result(status: "cancelled"), .failure),
            ("expired job", result(status: "expired"), .warning),
            ("unknown job", result(status: "unknown"), .neutral),
            ("missing revision", result(revision: nil), .neutral),
            ("foreign context", result(contextID: UUID()), .neutral)
        ] {
            let rows = [prior, result(revision: 25)]
            let cards = views(rows, as: ContextBuilderResultCard.self)
            XCTAssertEqual(cards.map(\.item.id), rows.map(\.id), name)
            XCTAssertEqual(cards.first?.status, expected, name)
            XCTAssertTrue(views(rows, as: ContextBuilderObservationHistoryRow.self).isEmpty, name)
            XCTAssertEqual(cards.first?.item.toolResultJSON, prior.toolResultJSON, name)
            XCTAssertEqual(cards.first?.item.toolIsError, prior.toolIsError, name)
        }
        var unidentified = result()
        unidentified.toolInvocationID = nil
        var malformed = result()
        malformed.toolResultJSON = jsonString(["job_id": jobID, "job": ["id": UUID().uuidString, "context_id": tabID.uuidString, "status": "running", "revision": 18]])
        var exportWarning = result(status: "completed")
        let exportPayload = try XCTUnwrap(ToolJSON.rawObject(from: exportWarning.toolResultJSON))
        exportWarning.toolResultJSON = jsonString(exportPayload.merging(["oracle_export_error": "Paid answer retained; export failed"]) { _, incoming in incoming })
        for prior in [unidentified, malformed, exportWarning, result(status: "running", revision: 25)] {
            let rows = [prior, result(status: "completed", revision: 25)]
            XCTAssertEqual(views(rows, as: ContextBuilderResultCard.self).map(\.item.id), rows.map(\.id))
            XCTAssertTrue(views(rows, as: ContextBuilderObservationHistoryRow.self).isEmpty)
        }
        var completed = result(status: "completed", revision: 33)
        let completedPayload = try XCTUnwrap(ToolJSON.rawObject(from: completed.toolResultJSON))
        completed.toolResultJSON = jsonString(completedPayload.merging([
            "status": "success", "response_type": "question", "plan": ["chat_id": "exact-recovery-chat", "mode": "chat"]
        ]) { _, incoming in incoming })
        let staleRows = [completed, result(revision: 18)]
        let primary = views(staleRows, as: ContextBuilderResultCard.self)
        XCTAssertEqual(primary.map(\.item.id), [completed.id], "Late lower revision must not displace the exact terminal row")
        XCTAssertEqual(primary.first?.followUpChatID, "exact-recovery-chat")
        XCTAssertEqual(primary.first?.status, .success)
        XCTAssertEqual(views(staleRows, as: ContextBuilderObservationHistoryRow.self).map(\.item.id), [staleRows[1].id])
        let pending = AgentChatItem(
            kind: .toolCall, text: "", toolName: "context_builder", toolInvocationID: UUID(),
            toolArgsJSON: jsonString(["op": "wait", "job_id": jobID, "timeout": 1]), sequenceIndex: 1
        )
        let pendingRows = [result(), pending]
        XCTAssertEqual(views(pendingRows, as: ContextBuilderCallCard.self).map(\.item.id), [pending.id], "Pending control/cancel scope is not a settled duplicate")
        XCTAssertEqual(views(pendingRows, as: ContextBuilderResultCard.self).count, 1)
        XCTAssertTrue(views(pendingRows, as: ContextBuilderObservationHistoryRow.self).isEmpty)
    }

    @MainActor
    func testContextBuilderTicketRestoreKeepsBoundedIdentityWithoutClaimingLiveness() async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -9862, deferredInitialAgentSystemWorkspaceRefresh: true, sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        defer {
            composition.contextBuilderAgentViewModel.prepareForWindowClose()
            composition.workspaceManager.prepareForWindowClose()
        }
        addTeardownBlock { await composition.workspaceManager.awaitOwnSavesForWindowClose() }
        let tabID = UUID()
        let jobID = UUID().uuidString
        let context = ContextBuilderCardContext(
            tabID: tabID, contextBuilderAgentVM: composition.contextBuilderAgentViewModel,
            oracleOpenContext: nil
        )
        var item = AgentChatItem(
            kind: .toolResult, text: "", toolName: "context_builder",
            toolResultJSON: jsonString([
                "job_id": jobID, "job": [
                    "id": jobID,
                    "kind": "context_builder",
                    "context_id": tabID.uuidString,
                    "status": "running",
                    "revision": 3,
                    "message": String(repeating: "PRIVATE BODY", count: 500)
                ]
            ]), toolIsError: false
        )
        for _ in 0 ..< 2 {
            let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: item))
            XCTAssertLessThanOrEqual(summary.resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
            XCTAssertFalse(summary.resultJSON.contains("PRIVATE BODY"))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(summary.resultJSON.utf8)) as? [String: Any])
            XCTAssertEqual(object["job_id"] as? String, jobID)
            XCTAssertEqual((object["job"] as? [String: Any])?["context_id"] as? String, tabID.uuidString)
            XCTAssertEqual((object["job"] as? [String: Any])?["status"] as? String, "running")
            item.toolResultJSON = summary.resultJSON
            item = try JSONDecoder().decode(AgentChatItem.self, from: JSONEncoder().encode(item))
            let card = ContextBuilderResultCard(item: item, context: context)
            XCTAssertEqual(card.status, .neutral)
            XCTAssertTrue(card.summary.contains("Live job state unknown"), card.summary)
            XCTAssertTrue(card.summary.contains(jobID), card.summary)
        }
    }

    func testContextBuilderSelectsExactPlanOrReviewChatID() throws {
        let planDTO = try contextBuilderDTO(responseType: "plan")
        let questionDTO = try contextBuilderDTO(responseType: "question")
        let reviewDTO = try contextBuilderDTO(responseType: "review")
        let normalizedPlanDTO = try contextBuilderDTO(responseType: "  PlAn\n")
        let normalizedQuestionDTO = try contextBuilderDTO(responseType: "\tQuEsTiOn ")
        let normalizedReviewDTO = try contextBuilderDTO(responseType: " ReViEw ")

        XCTAssertEqual(contextBuilderFollowUpChatID(for: planDTO), "plan-chat")
        XCTAssertEqual(contextBuilderFollowUpChatID(for: questionDTO), "plan-chat")
        XCTAssertEqual(contextBuilderFollowUpChatID(for: reviewDTO), "review-chat")
        XCTAssertEqual(contextBuilderFollowUpChatID(for: normalizedPlanDTO), "plan-chat")
        XCTAssertEqual(contextBuilderFollowUpChatID(for: normalizedQuestionDTO), "plan-chat")
        XCTAssertEqual(contextBuilderFollowUpChatID(for: normalizedReviewDTO), "review-chat")

        let tabID = UUID()
        let workspaceID = UUID()
        let openContext = AgentOracleOpenContext(
            windowID: 42,
            workspaceID: workspaceID,
            tabID: tabID,
            chatID: "ambient-chat"
        )
        let userInfo = try XCTUnwrap(contextBuilderOraclePopoverUserInfo(
            openContext: openContext,
            chatID: contextBuilderFollowUpChatID(for: reviewDTO)
        ))

        XCTAssertEqual(userInfo["windowID"] as? Int, 42)
        XCTAssertEqual(userInfo["workspaceID"] as? UUID, workspaceID)
        XCTAssertEqual(userInfo["tabID"] as? UUID, tabID)
        XCTAssertEqual(userInfo["chatID"] as? String, "review-chat")
        XCTAssertEqual(userInfo["presentation"] as? String, "generated_answer_read_only")
        XCTAssertEqual(
            AgentOraclePopoverRoute(notificationUserInfo: userInfo)?.presentation,
            .generatedAnswerReadOnly
        )
    }

    func testContextBuilderOperationRoutingRejectsMissingOrBlankChatIDWithoutAmbientFallback() {
        let openContext = AgentOracleOpenContext(
            windowID: 42,
            workspaceID: UUID(),
            tabID: UUID(),
            chatID: "ambient-chat"
        )

        XCTAssertNil(contextBuilderOraclePopoverUserInfo(openContext: openContext, chatID: nil))
        XCTAssertNil(contextBuilderOraclePopoverUserInfo(openContext: openContext, chatID: "   \n"))
        XCTAssertNil(contextBuilderOraclePopoverUserInfo(
            openContext: AgentOracleOpenContext(windowID: 42, workspaceID: nil, tabID: UUID()),
            chatID: "exact-chat"
        ))
        XCTAssertNil(contextBuilderOraclePopoverUserInfo(
            openContext: AgentOracleOpenContext(windowID: 42, workspaceID: UUID(), tabID: nil),
            chatID: "exact-chat"
        ))
    }

    func testDrawerBuilderGeneratedAnswerRoutingAndTooltipsUseAnswerWording() throws {
        let route = ContextBuilderGeneratedAnswerRoute(
            workspaceID: UUID(),
            tabID: UUID(),
            chatID: "  generated-answer-chat  "
        )
        let changedWorkspaceID = UUID()
        let changedTabID = UUID()
        XCTAssertNotEqual(changedWorkspaceID, route.workspaceID)
        XCTAssertNotEqual(changedTabID, route.tabID)

        let ready = ContextBuilderPlanStatus.ready(route: route, previewText: "Generated answer")
        var callbackRoute: ContextBuilderGeneratedAnswerRoute?
        if case let .ready(readyRoute, _) = ready {
            let openGeneratedAnswerChat: (ContextBuilderGeneratedAnswerRoute) -> Void = {
                callbackRoute = $0
            }
            openGeneratedAnswerChat(readyRoute)
        }
        XCTAssertEqual(callbackRoute, route)

        let userInfo = try XCTUnwrap(agentContextDrawerGeneratedAnswerPopoverUserInfo(
            windowID: 8,
            route: route
        ))

        XCTAssertEqual(Set(userInfo.keys.compactMap { $0 as? String }), [
            "windowID",
            "workspaceID",
            "tabID",
            "chatID",
            "presentation"
        ])
        XCTAssertEqual(userInfo["windowID"] as? Int, 8)
        XCTAssertEqual(userInfo["workspaceID"] as? UUID, route.workspaceID)
        XCTAssertEqual(userInfo["tabID"] as? UUID, route.tabID)
        XCTAssertEqual(userInfo["chatID"] as? String, "generated-answer-chat")
        XCTAssertEqual(userInfo["presentation"] as? String, "generated_answer_read_only")
        let decodedRoute = try XCTUnwrap(AgentOraclePopoverRoute(notificationUserInfo: userInfo))
        XCTAssertEqual(decodedRoute.chatID, "generated-answer-chat")
        XCTAssertEqual(decodedRoute.presentation, .generatedAnswerReadOnly)

        let tooltips = [
            ContextBuilderGeneratedAnswerActionText.useAsPromptTooltip,
            ContextBuilderGeneratedAnswerActionText.copyTooltip,
            ContextBuilderGeneratedAnswerActionText.previewTooltip,
            ContextBuilderGeneratedAnswerActionText.viewInChatTooltip
        ]
        XCTAssertEqual(tooltips, [
            "Use the generated answer as your prompt",
            "Copy answer to clipboard",
            "Preview the generated answer",
            "Open answer in chat view"
        ])
        XCTAssertFalse(tooltips.contains { $0.localizedCaseInsensitiveContains("plan") })
    }

    func testOracleLatestPopoverRouteOmitsChatIDAndPreservesScope() throws {
        let workspaceID = UUID()
        let contextTabID = UUID()
        let overrideTabID = UUID()
        let openContext = AgentOracleOpenContext(
            windowID: 42,
            workspaceID: workspaceID,
            tabID: contextTabID,
            chatID: "ambient-chat"
        )
        let route = try XCTUnwrap(AgentOracleLatestPopoverRoute(
            openContext: openContext,
            tabID: overrideTabID
        ))

        XCTAssertEqual(route.windowID, 42)
        XCTAssertEqual(route.workspaceID, workspaceID)
        XCTAssertEqual(route.tabID, overrideTabID)

        let userInfo = route.notificationUserInfo
        XCTAssertEqual(userInfo["windowID"] as? Int, 42)
        XCTAssertEqual(userInfo["workspaceID"] as? UUID, workspaceID)
        XCTAssertEqual(userInfo["tabID"] as? UUID, overrideTabID)
        XCTAssertEqual(userInfo["route"] as? String, "latest")
        XCTAssertNil(userInfo["chatID"])
        XCTAssertEqual(AgentOracleLatestPopoverRoute(notificationUserInfo: userInfo), route)
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: userInfo))

        XCTAssertNil(AgentOracleLatestPopoverRoute(openContext: nil))
        XCTAssertNil(AgentOracleLatestPopoverRoute(
            openContext: AgentOracleOpenContext(windowID: 42, workspaceID: nil, tabID: contextTabID)
        ))
        XCTAssertNil(AgentOracleLatestPopoverRoute(
            openContext: AgentOracleOpenContext(windowID: 42, workspaceID: workspaceID, tabID: nil)
        ))
        XCTAssertNil(AgentOracleLatestPopoverRoute(notificationUserInfo: [
            "windowID": 42,
            "workspaceID": workspaceID,
            "tabID": contextTabID
        ]))
        XCTAssertNil(AgentOracleLatestPopoverRoute(notificationUserInfo: [
            "windowID": 42,
            "workspaceID": workspaceID,
            "tabID": contextTabID,
            "route": "other"
        ]))
        XCTAssertNil(AgentOracleLatestPopoverRoute(notificationUserInfo: [
            "windowID": 42,
            "workspaceID": workspaceID,
            "tabID": contextTabID,
            "route": "latest",
            "chatID": "exact-chat"
        ]))
    }

    func testOraclePopoverRoutePreservesNotificationTypesAndCompatibilityDecoding() throws {
        let workspaceID = UUID()
        let contextTabID = UUID()
        let overrideTabID = UUID()
        let openContext = AgentOracleOpenContext(
            windowID: 42,
            workspaceID: workspaceID,
            tabID: contextTabID,
            chatID: "ambient-chat"
        )
        let route = try XCTUnwrap(AgentOraclePopoverRoute(
            openContext: openContext,
            chatID: "  exact-short-id  ",
            tabID: overrideTabID
        ))

        XCTAssertEqual(route.windowID, 42)
        XCTAssertEqual(route.workspaceID, workspaceID)
        XCTAssertEqual(route.tabID, overrideTabID)
        XCTAssertEqual(route.chatID, "exact-short-id")
        XCTAssertEqual(route.presentation, .standard)

        let userInfo = route.notificationUserInfo
        XCTAssertEqual(userInfo["windowID"] as? Int, 42)
        XCTAssertEqual(userInfo["workspaceID"] as? UUID, workspaceID)
        XCTAssertEqual(userInfo["tabID"] as? UUID, overrideTabID)
        XCTAssertEqual(userInfo["chatID"] as? String, "exact-short-id")
        XCTAssertNil(userInfo["presentation"])
        XCTAssertEqual(AgentOraclePopoverRoute(notificationUserInfo: userInfo), route)

        let stringCompatibleRoute = try XCTUnwrap(AgentOraclePopoverRoute(notificationUserInfo: [
            "windowID": 7,
            "workspaceID": workspaceID.uuidString,
            "tabID": contextTabID.uuidString,
            "chatID": "  short-chat  ",
            "extra": true
        ]))
        XCTAssertEqual(stringCompatibleRoute.workspaceID, workspaceID)
        XCTAssertEqual(stringCompatibleRoute.tabID, contextTabID)
        XCTAssertEqual(stringCompatibleRoute.chatID, "short-chat")
        XCTAssertEqual(stringCompatibleRoute.presentation, .standard)

        let readOnlyRoute = try XCTUnwrap(AgentOraclePopoverRoute(
            openContext: openContext,
            chatID: "exact-short-id",
            tabID: overrideTabID,
            presentation: .generatedAnswerReadOnly
        ))
        XCTAssertNotEqual(readOnlyRoute, route)
        XCTAssertEqual(readOnlyRoute.notificationUserInfo["presentation"] as? String, "generated_answer_read_only")
        XCTAssertEqual(AgentOraclePopoverRoute(notificationUserInfo: readOnlyRoute.notificationUserInfo), readOnlyRoute)

        let chatUUID = UUID()
        let uuidChatRoute = try XCTUnwrap(AgentOraclePopoverRoute(notificationUserInfo: [
            "windowID": 7,
            "workspaceID": workspaceID,
            "tabID": contextTabID,
            "chatID": chatUUID
        ]))
        XCTAssertEqual(uuidChatRoute.chatID, chatUUID.uuidString)
    }

    func testOraclePopoverRouteRejectsMissingMalformedAndAmbientFallbackInputs() {
        let workspaceID = UUID()
        let tabID = UUID()
        let openContext = AgentOracleOpenContext(
            windowID: 42,
            workspaceID: workspaceID,
            tabID: tabID,
            chatID: "ambient-chat"
        )

        XCTAssertNil(AgentOraclePopoverRoute(openContext: nil, chatID: "exact-chat"))
        XCTAssertNil(AgentOraclePopoverRoute(
            openContext: AgentOracleOpenContext(windowID: 42, workspaceID: nil, tabID: tabID),
            chatID: "exact-chat"
        ))
        XCTAssertNil(AgentOraclePopoverRoute(
            openContext: AgentOracleOpenContext(windowID: 42, workspaceID: workspaceID, tabID: nil),
            chatID: "exact-chat"
        ))
        XCTAssertNil(AgentOraclePopoverRoute(openContext: openContext, chatID: nil))
        XCTAssertNil(AgentOraclePopoverRoute(openContext: openContext, chatID: "  \n"))

        let valid: [AnyHashable: Any] = [
            "windowID": 42,
            "workspaceID": workspaceID,
            "tabID": tabID,
            "chatID": "exact-chat"
        ]
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: nil))
        for key in ["windowID", "workspaceID", "tabID", "chatID"] {
            var missing = valid
            missing.removeValue(forKey: key)
            XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: missing), key)
        }

        var malformed = valid
        malformed["windowID"] = "42"
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: malformed))
        malformed = valid
        malformed["workspaceID"] = "not-a-uuid"
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: malformed))
        malformed = valid
        malformed["tabID"] = 42
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: malformed))
        malformed = valid
        malformed["chatID"] = "  \n"
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: malformed))
        malformed = valid
        malformed["chatID"] = 42
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: malformed))
        malformed = valid
        malformed["presentation"] = "unknown"
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: malformed))
        malformed = valid
        malformed["presentation"] = 42
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: malformed))
    }

    func testDirectOracleResultRoutingRequiresExactResultChatID() throws {
        let tabID = UUID()
        let openContext = AgentOracleOpenContext(
            windowID: 7,
            workspaceID: UUID(),
            tabID: tabID,
            chatID: "ambient-chat"
        )
        let exactItem = toolResultItem(
            toolName: "ask_oracle",
            payload: ["chat_id": "  exact-result-chat  ", "mode": "review"]
        )
        let exactUserInfo = try XCTUnwrap(oracleToolResultPopoverUserInfo(
            item: exactItem,
            openContext: openContext
        ))

        XCTAssertEqual(exactUserInfo["windowID"] as? Int, 7)
        XCTAssertEqual(exactUserInfo["tabID"] as? UUID, tabID)
        XCTAssertEqual(exactUserInfo["chatID"] as? String, "exact-result-chat")

        let exactOracleSendUserInfo = oracleToolResultPopoverUserInfo(
            item: toolResultItem(
                toolName: "oracle_send",
                payload: ["chat_id": "exact-oracle-send-chat"]
            ),
            openContext: openContext
        )
        XCTAssertEqual(exactOracleSendUserInfo?["chatID"] as? String, "exact-oracle-send-chat")

        let malformedOptionalPayloadUserInfo = oracleToolResultPopoverUserInfo(
            item: toolResultItem(
                toolName: "ask_oracle",
                payload: ["chat_id": "exact-despite-malformed-diffs", "diffs": [["path": 42]]]
            ),
            openContext: openContext
        )
        XCTAssertEqual(
            malformedOptionalPayloadUserInfo?["chatID"] as? String,
            "exact-despite-malformed-diffs"
        )

        XCTAssertNil(oracleToolResultPopoverUserInfo(
            item: toolResultItem(toolName: "ask_oracle", payload: ["mode": "review"]),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolResultPopoverUserInfo(
            item: toolResultItem(toolName: "ask_oracle", payload: ["chat_id": "\n  "]),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolResultPopoverUserInfo(
            item: toolResultItem(toolName: "oracle_send", payload: ["chat_id": "   "]),
            openContext: openContext
        ))
    }

    func testOracleToolCallRoutingRequiresExactArgumentChatID() throws {
        let openContext = AgentOracleOpenContext(
            windowID: 9,
            workspaceID: UUID(),
            tabID: UUID(),
            chatID: "ambient-chat"
        )
        let exactItem = AgentChatItem(
            kind: .toolCall,
            text: "",
            toolName: "oracle_send",
            toolArgsJSON: jsonString(["chat_id": "  exact-call-chat  "])
        )
        let exactUserInfo = try XCTUnwrap(oracleToolCallPopoverUserInfo(
            item: exactItem,
            openContext: openContext
        ))

        XCTAssertEqual(exactUserInfo["chatID"] as? String, "exact-call-chat")

        let completedExactUserInfo = try XCTUnwrap(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: jsonString(["message": "start a new chat"]),
                toolResultJSON: jsonString(["chat_id": "  exact-result-chat  ", "mode": "review"]),
                toolIsError: false
            ),
            openContext: openContext
        ))
        XCTAssertEqual(completedExactUserInfo["chatID"] as? String, "exact-result-chat")
        XCTAssertNil(completedExactUserInfo["route"])

        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: jsonString(["message": "start a new chat"]),
                toolResultJSON: jsonString(["status": "failed"]),
                toolIsError: true
            ),
            openContext: openContext
        ))

        let latestUserInfo = try XCTUnwrap(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: jsonString(["message": "start a new chat"])
            ),
            openContext: openContext
        ))
        XCTAssertEqual(latestUserInfo["windowID"] as? Int, openContext.windowID)
        XCTAssertEqual(latestUserInfo["workspaceID"] as? UUID, openContext.workspaceID)
        XCTAssertEqual(latestUserInfo["tabID"] as? UUID, openContext.tabID)
        XCTAssertEqual(latestUserInfo["route"] as? String, "latest")
        XCTAssertNil(latestUserInfo["chatID"])
        XCTAssertNotNil(AgentOracleLatestPopoverRoute(notificationUserInfo: latestUserInfo))
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: latestUserInfo))
        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "oracle_send",
                toolArgsJSON: jsonString(["chat_id": "\t "])
            ),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: jsonString(["chatID": "camel-alias"])
            ),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: jsonString(["message": "continue", "payload": ["chat_id": "nested"]])
            ),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: "{bad json"
            ),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: "  \n"
            ),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: "[]"
            ),
            openContext: openContext
        ))
    }

    func testDirectOracleRoutingRejectsNestedAliasedAndConflictingChatIDs() {
        let openContext = AgentOracleOpenContext(
            windowID: 11,
            workspaceID: UUID(),
            tabID: UUID()
        )

        let rejectedPayloads: [[String: Any]] = [
            ["result": ["chat_id": "nested-only"]],
            ["chatID": "camel-only"],
            ["chat_id": 42],
            ["chat_id": "authoritative", "result": ["chat_id": "conflict"]],
            ["chat_id": "authoritative", "items": [["chatID": "conflict"]]]
        ]

        for payload in rejectedPayloads {
            XCTAssertNil(oracleToolResultPopoverUserInfo(
                item: toolResultItem(toolName: "ask_oracle", payload: payload),
                openContext: openContext
            ))
            XCTAssertNil(oracleToolCallPopoverUserInfo(
                item: AgentChatItem(
                    kind: .toolCall,
                    text: "",
                    toolName: "oracle_send",
                    toolArgsJSON: jsonString(payload)
                ),
                openContext: openContext
            ))
        }
    }

    func testAuthoritativeChatIDPolicyPreservesFailClosedRootRulesAcrossEntryPoints() {
        let acceptedPayloads: [([String: Any], String)] = [
            (["chat_id": "  exact-chat  "], "exact-chat"),
            (["chat_id": "exact-with-unrelated-data", "diffs": [["path": 42]]], "exact-with-unrelated-data")
        ]
        for (payload, expected) in acceptedPayloads {
            XCTAssertEqual(
                AgentOracleAuthoritativeChatIDPolicy.extract(fromRootObject: payload),
                expected
            )
            XCTAssertEqual(
                AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: jsonString(payload)),
                expected
            )
        }

        let rejectedPayloads: [[String: Any]] = [
            [:],
            ["chatID": "camel-only"],
            ["chat_id": "exact", "chatID": "alias"],
            ["chat_id": 42],
            ["chat_id": "  \n"],
            ["chat_id": "exact", "result": ["chat_id": "nested"]],
            ["chat_id": "exact", "items": [["chatID": "nested"]]]
        ]
        for payload in rejectedPayloads {
            XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromRootObject: payload))
            XCTAssertNil(
                AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: jsonString(payload))
            )
        }

        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: nil))
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: "  \n"))
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: "not-json"))
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: "null"))
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: "42"))
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: "[]"))
    }

    func testAuthoritativeChatIDPolicyRoutesCanonicalGroupsWithoutAdmittingConflictingIDs() {
        let lanes: [[String: Any]] = [
            ["lane_index": 0, "role": "primary", "chat_id": "primary-chat", "model_id": "primary-model", "status": "completed"],
            ["lane_index": 1, "role": "additional", "chat_id": "additional-chat", "model_id": "additional-model", "status": "completed"]
        ]
        let digest: [String: Any] = [
            "chat_id": "primary-chat", "oracle_group_id": UUID().uuidString,
            "oracle_count": 2, "oracle_results": lanes, "status": "success", "summary_only": true
        ]
        var live = digest
        live["oracle_results"] = lanes.map { $0.merging(["response": "answer"]) { current, _ in current } }
        live["status"] = "completed"
        live.removeValue(forKey: "summary_only")
        for payload in [digest, live] {
            XCTAssertEqual(AgentOracleAuthoritativeChatIDPolicy.extract(fromRootObject: payload), "primary-chat")
            XCTAssertEqual(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: jsonString(payload)), "primary-chat")
        }

        var rejected: [[String: Any]] = []
        for changes: [String: Any] in [
            ["chat_id": "wrong-primary"], ["oracle_count": 3], ["oracle_group_id": "not-a-group-id"],
            ["chatID": "alias"], ["result": ["chat_id": "unrelated"]]
        ] {
            rejected.append(digest.merging(changes) { _, new in new })
        }
        var missingGroup = digest
        missingGroup.removeValue(forKey: "oracle_group_id")
        rejected.append(missingGroup)
        for changes: [String: Any] in [
            ["lane_index": 0], ["lane_index": true], ["role": "primary"], ["chat_id": "primary-chat"],
            ["chat_id": "  "], ["chatID": "alias"], ["result": ["chat_id": "nested"]], ["status": "unknown"]
        ] {
            var malformedLanes = lanes
            malformedLanes[1].merge(changes) { _, new in new }
            var payload = digest
            payload["oracle_results"] = malformedLanes
            rejected.append(payload)
        }
        for payload in rejected {
            XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromRootObject: payload))
            XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: jsonString(payload)))
            XCTAssertFalse(AgentOracleAuthoritativeChatIDPolicy.allowsLatestFallback(fromSerializedJSON: jsonString(payload)))
        }
    }

    func testContextBuilderRoutingRejectsMismatchedOrUnknownResponseBranch() throws {
        let reviewWithPlanOnly = try XCTUnwrap(ToolJSON.decode(
            ToolResultDTOs.ContextBuilderDTO.self,
            from: jsonString([
                "status": "success",
                "response_type": "review",
                "plan": ["chat_id": "wrong-plan-chat", "mode": "plan"]
            ])
        ))
        let unknownWithPlan = try XCTUnwrap(ToolJSON.decode(
            ToolResultDTOs.ContextBuilderDTO.self,
            from: jsonString([
                "status": "success",
                "response_type": "clarify",
                "plan": ["chat_id": "wrong-plan-chat", "mode": "plan"]
            ])
        ))
        let planWithReviewOnly = try XCTUnwrap(ToolJSON.decode(
            ToolResultDTOs.ContextBuilderDTO.self,
            from: jsonString([
                "status": "success",
                "response_type": "plan",
                "review": ["chat_id": "wrong-review-chat", "mode": "review"]
            ])
        ))
        let missingResponseType = try XCTUnwrap(ToolJSON.decode(
            ToolResultDTOs.ContextBuilderDTO.self,
            from: jsonString([
                "status": "success",
                "plan": ["chat_id": "wrong-plan-chat", "mode": "plan"],
                "review": ["chat_id": "wrong-review-chat", "mode": "review"]
            ])
        ))

        XCTAssertNil(contextBuilderFollowUpChatID(for: reviewWithPlanOnly))
        XCTAssertNil(contextBuilderFollowUpChatID(for: unknownWithPlan))
        XCTAssertNil(contextBuilderFollowUpChatID(for: planWithReviewOnly))
        XCTAssertNil(contextBuilderFollowUpChatID(for: missingResponseType))
    }

    @MainActor
    private func allocatedBubbleViews<Value>(in value: Any, as type: Value.Type, depth: Int = 0) -> [Value] {
        if let view = value as? Value { return [view] }
        // Walk only evaluated SwiftUI builder/identity wrappers. No test-local grouping or view-model traversal.
        let mirror = Mirror(reflecting: value)
        let name = String(describing: mirror.subjectType)
        guard depth < 24, mirror.displayStyle == .enum || mirror.displayStyle == .tuple
            || name.hasPrefix("AnyView") || name.hasPrefix("_ConditionalContent<") || name.hasPrefix("TupleView<")
            || name.hasPrefix("ModifiedContent<") || name.hasPrefix("IDView<")
        else { return [] }
        return mirror.children.flatMap { allocatedBubbleViews(in: $0.value, as: type, depth: depth + 1) }
    }

    private func contextBuilderDTO(responseType: String) throws -> ToolResultDTOs.ContextBuilderDTO {
        let raw = jsonString([
            "status": "success",
            "response_type": responseType,
            "plan": ["chat_id": "plan-chat", "mode": "plan"],
            "review": ["chat_id": "review-chat", "mode": "review"]
        ])
        return try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: raw))
    }

    private func toolResultItem(toolName: String, payload: [String: Any]) -> AgentChatItem {
        let raw = jsonString(payload)
        return AgentChatItem(
            kind: .toolResult,
            text: raw,
            toolName: toolName,
            toolResultJSON: raw
        )
    }

    private func jsonString(
        _ object: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(object), file: file, line: line)
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}

final class OracleLaneCoverageTests: XCTestCase {
    @MainActor
    func testCancelledPartialGroupRetainsCanonicalOutcomeAndLaneCoverage() throws {
        var payload = try canonicalGroupPayload(completedCount: 1)
        var lanes = try XCTUnwrap(payload["oracle_results"] as? [[String: Any]])
        lanes[1]["status"] = "cancelled"
        lanes[1]["error"] = ["code": "cancelled", "message": "Cancelled"]
        payload["oracle_results"] = lanes
        var row = AgentChatItem(
            kind: .toolResult, text: "", toolName: "ask_oracle",
            toolResultJSON: jsonString(payload), toolIsError: true
        )
        for _ in 0 ... 2 {
            XCTAssertEqual(AgentTranscriptToolNormalizer.status(for: row), .warning)
            let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: row.toolResultJSON))
            XCTAssertEqual(dto.status, "partial_failure")
            XCTAssertEqual(dto.oracleGroupID, payload["oracle_group_id"] as? String)
            let coverage = try XCTUnwrap(OracleLaneCoverage(lanes: dto.oracleResults, oracleCount: dto.oracleCount))
            XCTAssertEqual(coverage.completedCount, 1)
            XCTAssertEqual(coverage.totalCount, 2)
            XCTAssertEqual(coverage.incompleteLanes.map(\.reason), ["cancelled"])
            XCTAssertEqual(ChatSendResultCard(item: row, oracleOpenContext: nil).status, .warning)
            row.toolResultJSON = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: row)).resultJSON
        }
    }

    @MainActor
    func testOversizedGroupSummariesKeepIncompleteCardOutcomeWithoutInventingCoverage() async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -9820, deferredInitialAgentSystemWorkspaceRefresh: true, sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        defer {
            composition.contextBuilderAgentViewModel.prepareForWindowClose()
            composition.workspaceManager.prepareForWindowClose()
        }
        addTeardownBlock { await composition.workspaceManager.awaitOwnSavesForWindowClose() }
        let context = ContextBuilderCardContext(
            tabID: nil, contextBuilderAgentVM: composition.contextBuilderAgentViewModel,
            oracleOpenContext: nil
        )
        for completedCount in [1, 0] {
            for tool in ["ask_oracle", "oracle_send", "plan", "review"] {
                let reply = try canonicalGroupPayload(completedCount: completedCount, laneCount: 5, oversized: true)
                let isBuilder = tool == "plan" || tool == "review"
                let raw = isBuilder ? ["status": "success", "response_type": tool, tool: reply] : reply
                var item = AgentChatItem(
                    kind: .toolResult,
                    text: "",
                    toolName: isBuilder ? "context_builder" : tool,
                    toolResultJSON: jsonString(raw),
                    toolIsError: false
                )
                let expected: ToolCardStatus = completedCount == 0 ? .failure : .warning
                for pass in 1 ... 2 {
                    let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: item))
                    XCTAssertLessThanOrEqual(summary.resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
                    XCTAssertFalse(summary.resultJSON.contains("oracle_results"), "fixture must exercise budget fallback")
                    XCTAssertFalse(summary.resultJSON.contains("RESPONSE_BODY"))
                    item.toolResultJSON = summary.resultJSON
                    item.text = summary.resultJSON
                    if isBuilder {
                        let card = ContextBuilderResultCard(item: item, context: context)
                        XCTAssertEqual(card.status, expected, "\(tool) pass \(pass)")
                        XCTAssertFalse(["success", "completed"].contains(card.summary), card.summary)
                        let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: item.toolResultJSON))
                        XCTAssertNil(contextBuilderOracleLaneCoverage(for: dto))
                        XCTAssertEqual(contextBuilderFollowUpChatID(for: dto), "fixture-chat-0")
                    } else {
                        XCTAssertEqual(ChatSendResultCard(item: item, oracleOpenContext: nil).status, expected, "\(tool) pass \(pass)")
                        let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: item.toolResultJSON))
                        XCTAssertNil(OracleLaneCoverage(lanes: dto.oracleResults, oracleCount: dto.oracleCount))
                        XCTAssertEqual(dto.chatID, "fixture-chat-0")
                    }
                }
            }
        }
    }

    func testTimeoutReasonBeyondDigestCutoffSurvivesRepeatedSummary() throws {
        for timedOut in [false, true] {
            let reply = try canonicalGroupPayload(completedCount: 1, errorMessage: String(repeating: "x", count: 96) + (timedOut ? " request timed out" : " provider refused"))
            var item = AgentChatItem(kind: .toolResult, text: "", toolName: "ask_oracle", toolResultJSON: jsonString(reply), toolIsError: false)
            for pass in 0 ... 2 {
                let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: item.toolResultJSON))
                let coverage = try XCTUnwrap(OracleLaneCoverage(lanes: dto.oracleResults, oracleCount: dto.oracleCount))
                XCTAssertEqual(coverage.incompleteLanes.map(\.reason), [timedOut ? "timed out" : "failed"], "pass \(pass)")
                if pass > 0 {
                    XCTAssertEqual(dto.oracleResults?.last?.error?.code, "provider_error")
                    XCTAssertLessThanOrEqual(dto.oracleResults?.last?.error?.message.count ?? Int.max, 96)
                }
                if pass < 2 {
                    item.toolResultJSON = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: item)).resultJSON
                }
            }
        }
    }

    @MainActor
    func testFreshDiskStoreAndProductionPresentationPreserveOracleOutcomeAndHandle() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("OracleDiskFixture-\(UUID().uuidString)")
        let workspace = WorkspaceModel(name: "Oracle disk fixture", repoPaths: [], customStoragePath: storage)
        defer { try? FileManager.default.removeItem(at: storage) }
        let composition = WindowStateCompositionFactory.make(
            windowID: -9821, deferredInitialAgentSystemWorkspaceRefresh: true, sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        defer {
            composition.contextBuilderAgentViewModel.prepareForWindowClose()
            composition.workspaceManager.prepareForWindowClose()
        }
        addTeardownBlock { await composition.workspaceManager.awaitOwnSavesForWindowClose() }
        let tabID = UUID()
        let openContext = AgentOracleOpenContext(windowID: 42, workspaceID: workspace.id, tabID: tabID, chatID: "ambient-wrong-chat")
        let context = ContextBuilderCardContext(
            tabID: nil, contextBuilderAgentVM: composition.contextBuilderAgentViewModel,
            oracleOpenContext: openContext
        )
        let cases: [(completed: Int, oversized: Bool, toolError: Bool)] = [
            (2, false, false), (1, false, false), (0, false, false), (1, false, true),
            (1, true, false), (0, true, false)
        ]
        for fixture in cases {
            for tool in ["ask_oracle", "oracle_send", "plan", "review"] {
                let reply = try canonicalGroupPayload(
                    completedCount: fixture.completed, laneCount: fixture.oversized ? 5 : 2, oversized: fixture.oversized,
                    errorMessage: String(repeating: "x", count: 96) + " request timed out"
                )
                let isBuilder = tool == "plan" || tool == "review"
                let raw = isBuilder ? ["status": "success", "response_type": tool, tool: reply] : reply
                let row = AgentChatItem(
                    kind: .toolResult,
                    text: "",
                    toolName: isBuilder ? "context_builder" : tool,
                    toolInvocationID: UUID(),
                    toolResultJSON: jsonString(raw),
                    toolIsError: fixture.toolError
                )
                if !isBuilder {
                    let liveRoute = oracleToolResultPopoverUserInfo(item: row, openContext: openContext)
                    XCTAssertEqual(liveRoute?["chatID"] as? String, "fixture-chat-0", "Live encoded groups must route to the same primary chat as restored digests")
                }
                let unfinished = AgentChatItem.toolCall(name: "file_search", invocationID: UUID(), argsJSON: #"{"pattern":"pending"}"#, sequenceIndex: 1)
                let activities = [row, unfinished].map { AgentTranscriptActivity(from: $0, toolExecution: AgentTranscriptToolNormalizer.toolExecution(for: $0)) }
                var saved = AgentSession(
                    workspaceID: workspace.id, composeTabID: tabID, name: "Oracle fixture",
                    transcript: AgentTranscript(turns: [AgentTranscriptTurn(
                        responseSpans: [AgentTranscriptProviderResponseSpan(lifecycle: .open, startedAt: row.timestamp, activities: activities)],
                        terminalState: .running, startedAt: row.timestamp
                    )], nextSequenceIndex: 2), lastRunState: "running"
                )
                let expected: ToolCardStatus = (fixture.toolError && isBuilder) || fixture.completed == 0 ? .failure : fixture.completed == 2 && !fixture.oversized ? .success : .warning
                for pass in 1 ... 2 {
                    // Each awaited service call settles its exact file+metadata writes;
                    // neither load nor presentation can fall back to the source rows.
                    let fileURL = try await AgentSessionDataService().saveAgentSession(saved, for: workspace)
                    let data = try Data(contentsOf: fileURL)
                    let bytes = try XCTUnwrap(String(data: data, encoding: .utf8))
                    XCTAssertFalse(bytes.contains("RESPONSE_BODY"))
                    let onDisk = try JSONDecoder().decode(AgentSession.self, from: data)
                    let storedActivity = try XCTUnwrap(onDisk.transcript?.turns.flatMap(\.allActivities).first { $0.id == row.id })
                    let storedJSON = try XCTUnwrap(storedActivity.toolExecution?.resultJSON)
                    XCTAssertLessThanOrEqual(storedJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
                    saved = try await AgentSessionDataService().loadAgentSession(from: fileURL)
                    let transcript = try XCTUnwrap(saved.transcript)
                    let presentation = AgentSessionRestoreSupport.buildTranscriptPresentation(
                        from: transcript, sourceItems: saved.items.map { $0.toItem() }, selectedAgent: .devin,
                        previousPerformanceSnapshot: .init(), projectionProtection: .none,
                        isCompressedHistoryRevealed: true, isColdLoad: true
                    )
                    let restored = try XCTUnwrap((presentation.fullProjection.workingRows + presentation.fullProjection.archivedRows).first { $0.id == row.id })
                    XCTAssertEqual(restored.toolInvocationID, row.toolInvocationID)
                    XCTAssertEqual(transcript.turns.first?.terminalState, .cancelled)
                    XCTAssertEqual(transcript.turns.flatMap(\.allActivities).first { $0.id == unfinished.id }?.toolExecution?.status, .cancelled)
                    let dto: ToolResultDTOs.ChatSendDTO?
                    if isBuilder {
                        let builderDTO = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: restored.toolResultJSON))
                        dto = tool == "plan" ? builderDTO.plan : builderDTO.review
                        XCTAssertEqual(contextBuilderFollowUpChatID(for: builderDTO), "fixture-chat-0")
                        let card = ContextBuilderResultCard(item: restored, context: context)
                        XCTAssertEqual(card.status, expected, "\(tool) \(fixture) pass \(pass)")
                        if fixture.oversized {
                            XCTAssertFalse(["success", "completed"].contains(card.summary), card.summary)
                        } else {
                            XCTAssertEqual(
                                card.summary,
                                ContextBuilderResultCard(item: row, context: context).summary,
                                "fitting digest must preserve the live outcome wording"
                            )
                        }
                    } else {
                        dto = ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: restored.toolResultJSON)
                        XCTAssertEqual(ChatSendResultCard(item: restored, oracleOpenContext: openContext).status, expected, "\(tool) \(fixture) pass \(pass)")
                        XCTAssertEqual(dto?.chatID, "fixture-chat-0")
                        let route = oracleToolResultPopoverUserInfo(item: restored, openContext: openContext)
                        XCTAssertEqual(route?["chatID"] as? String, "fixture-chat-0", "Saved primary route must survive fitting digests and budget fallback")
                    }
                    if !isBuilder, fixture.completed == 1 {
                        XCTAssertEqual(dto?.status, "partial_failure", "canonical group outcome must survive persistence")
                    }
                    let coverage = OracleLaneCoverage(lanes: dto?.oracleResults, oracleCount: dto?.oracleCount)
                    if fixture.oversized {
                        XCTAssertNil(coverage)
                    } else {
                        XCTAssertEqual(coverage?.completedCount, fixture.completed)
                        XCTAssertEqual(coverage?.totalCount, 2)
                        XCTAssertEqual(coverage?.incompleteLanes.map(\.model), (fixture.completed ..< 2).map { "model-\($0)" })
                        XCTAssertEqual(coverage?.incompleteLanes.map(\.reason), Array(repeating: "timed out", count: 2 - fixture.completed))
                    }
                }
            }
        }
    }

    private func canonicalGroupPayload(
        completedCount: Int, laneCount: Int = 2, oversized: Bool = false, errorMessage: String = "Request timed out"
    ) throws -> [String: Any] {
        let lanes = try (0 ..< laneCount).map { index in
            let model = oversized ? "model-\(index)-" + String(repeating: "m", count: 48) : "model-\(index)"
            return try OracleLaneResult(
                laneIndex: index, chatID: "fixture-chat-\(index)", providerID: "custom", modelID: model,
                status: index < completedCount ? .completed : .failed,
                executionProfile: OracleExecutionProfile(providerID: "custom", modelID: model),
                response: index < completedCount ? "RESPONSE_BODY-\(index)" : nil,
                error: index < completedCount ? nil : OracleLaneError(
                    code: "provider_error", message: oversized ? String(repeating: "e", count: 96) : errorMessage,
                    partialResponse: "PARTIAL_RESPONSE_BODY-\(index)"
                )
            )
        }
        let group = try OracleGroupResult(
            groupID: OracleGroupID(rawValue: UUID()),
            status: completedCount == laneCount ? .completed : completedCount == 0 ? .failed : .partialFailure,
            oracleResults: lanes
        )
        var reply = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(OracleGroupMCPCodec.groupFields(group))) as? [String: Any])
        reply["chat_id"] = group.primary.chatID
        reply["mode"] = "review"
        reply["response"] = group.primary.response
        return reply
    }

    func testCoverageIsSilentForSingleLaneResults() {
        XCTAssertNil(OracleLaneCoverage(lanes: nil, oracleCount: nil))
        XCTAssertNil(OracleLaneCoverage(lanes: [lane(0, "gpt-6.1-sol", "completed")], oracleCount: 1))
    }

    func testShortModelNameDropsProviderPrefixes() {
        XCTAssertEqual(OracleLaneCoverage.shortModelName("anthropic/claude-opus-5"), "claude-opus-5")
        XCTAssertEqual(OracleLaneCoverage.shortModelName("claude_code__sonnet:medium"), "sonnet:medium")
        XCTAssertEqual(OracleLaneCoverage.shortModelName(" "), "model")
    }

    func testPartialGroupReportsCoverageAndWarns() throws {
        let coverage = try XCTUnwrap(OracleLaneCoverage(lanes: [
            lane(1, "anthropic/claude-opus-5", "failed", errorCode: "provider_error", errorMessage: "Request timed out after 600s"),
            lane(0, "astra-2", "completed")
        ], oracleCount: 2))
        XCTAssertEqual(coverage.completedCount, 1)
        XCTAssertEqual(coverage.totalCount, 2)
        XCTAssertEqual(coverage.summaryText, "1/2 lanes · claude-opus-5 timed out")
        XCTAssertEqual(coverage.cardStatus, .warning)
        XCTAssertFalse(coverage.summaryText.lowercased().contains("reconcil"))
    }

    @MainActor
    func testFailedPrimaryRemainsFailedWithCompletedAdditionalLaneCoverage() throws {
        let group = try OracleGroupResult(
            groupID: OracleGroupID(rawValue: UUID()), status: .failed,
            oracleResults: [
                OracleLaneResult(
                    laneIndex: 0, chatID: "failed-primary", providerID: "fixture", modelID: "primary",
                    status: .failed, error: OracleLaneError(code: "provider_error", message: "Primary failed")
                ),
                OracleLaneResult(
                    laneIndex: 1, chatID: "completed-additional", providerID: "fixture", modelID: "additional",
                    status: .completed, response: "Additional answer"
                )
            ]
        )
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(OracleGroupMCPCodec.groupFields(group))) as? [String: Any])
        for tool in ["ask_oracle", "oracle_send"] {
            var row = AgentChatItem(kind: .toolResult, text: "", toolName: tool, toolResultJSON: jsonString(payload), toolIsError: false)
            for pass in 0 ... 2 {
                XCTAssertEqual(ChatSendResultCard(item: row, oracleOpenContext: nil).status, .failure, "\(tool), pass \(pass)")
                let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: row.toolResultJSON))
                XCTAssertEqual(dto.status, "failed")
                let coverage = try XCTUnwrap(OracleLaneCoverage(lanes: dto.oracleResults, oracleCount: dto.oracleCount))
                XCTAssertEqual(coverage.summaryText, "1/2 lanes · primary failed")
                row.toolResultJSON = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: row)).resultJSON
            }
        }
    }

    func testCompleteAndFullyFailedGroups() throws {
        let complete = try XCTUnwrap(OracleLaneCoverage(lanes: [
            lane(0, "a", "completed"), lane(1, "b", "completed")
        ], oracleCount: 2))
        XCTAssertEqual(complete.summaryText, "2/2 lanes")
        XCTAssertNil(complete.cardStatus)

        let failed = try XCTUnwrap(OracleLaneCoverage(lanes: [
            lane(0, "a", "cancelled", errorCode: "cancelled", errorMessage: "Oracle lane was cancelled."),
            lane(1, "b", "failed", errorCode: "empty_response", errorMessage: "Oracle lane returned an empty response."),
            lane(2, "c", "failed", errorCode: "provider_error", errorMessage: "boom")
        ], oracleCount: 3))
        XCTAssertEqual(failed.summaryText, "0/3 lanes · a cancelled +2")
        XCTAssertEqual(failed.cardStatus, .failure)
        XCTAssertEqual(failed.incompleteLanes.map(\.reason), ["cancelled", "empty response", "failed"])
    }

    func testCompletedContextBuilderOutcomeDoesNotOverstateLaneSuccess() throws {
        let complete = try XCTUnwrap(OracleLaneCoverage(lanes: [lane(0, "a", "completed"), lane(1, "b", "completed")], oracleCount: 2))
        let partial = try XCTUnwrap(OracleLaneCoverage(lanes: [lane(0, "a", "completed"), lane(1, "b", "failed")], oracleCount: 2))
        let failed = try XCTUnwrap(OracleLaneCoverage(lanes: [lane(0, "a", "failed"), lane(1, "b", "cancelled")], oracleCount: 2))
        for label in ["success", "completed"] {
            XCTAssertEqual(contextBuilderCompletedOutcomeLabel(label, coverage: complete, toolIsError: false), label)
            XCTAssertEqual(contextBuilderCompletedOutcomeLabel(label, coverage: partial, toolIsError: false), "partial success")
            XCTAssertEqual(contextBuilderCompletedOutcomeLabel(label, coverage: failed, toolIsError: false), "Oracle incomplete")
            XCTAssertEqual(contextBuilderCompletedOutcomeLabel(label, coverage: partial, toolIsError: true), "error")
        }
        for label in ["error", "failed", "cancelled", "partial"] {
            XCTAssertEqual(contextBuilderCompletedOutcomeLabel(label, coverage: partial, toolIsError: false), label)
        }
    }

    func testPersistedContextBuilderReviewKeepsLaneDigestWithoutResponses() throws {
        let raw: [String: Any] = [
            "context_id": "CA9D86FB-FDA0-482A-8F46-6910C089E853",
            "response_type": "review",
            "status": "success",
            "review": [
                "chat_id": "course-review-34AE57",
                "mode": "review",
                "response": String(repeating: "finding ", count: 2000),
                "oracle_group_id": "6F1E0C55-6C1F-4C1B-9B7E-1C2D3E4F5A6B",
                "status": "partial_failure",
                "oracle_count": 2,
                "oracle_results": [
                    rawLane(0, "astra-2", "completed", response: "long answer"),
                    rawLane(
                        1,
                        "claude_code__opus:high",
                        "failed",
                        profileModel: "claude-opus-5",
                        errorCode: "provider_error",
                        errorMessage: "Request timed out"
                    )
                ]
            ]
        ]
        let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(
            for: AgentChatItem(kind: .toolResult, text: "", toolName: "context_builder", toolResultJSON: jsonString(raw), toolIsError: false)
        ))
        XCTAssertLessThanOrEqual(summary.resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
        XCTAssertFalse(summary.resultJSON.contains("finding finding"), summary.resultJSON)
        XCTAssertFalse(summary.resultJSON.contains("long answer"), summary.resultJSON)

        let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: summary.resultJSON))
        XCTAssertEqual(dto.review?.chatID, "course-review-34AE57")
        let coverage = try XCTUnwrap(contextBuilderOracleLaneCoverage(for: dto))
        XCTAssertEqual(coverage.summaryText, "1/2 lanes · claude-opus-5 timed out")
        XCTAssertEqual(contextBuilderOracleLaneSummaries(for: dto).map(\.status), ["done", "failed"])

        let item = AgentChatItem(kind: .toolResult, text: jsonString(raw), toolName: "context_builder", toolResultJSON: jsonString(raw), toolIsError: false)
        let execution = try XCTUnwrap(AgentTranscriptToolNormalizer.toolExecution(for: item))
        let activity = AgentTranscriptActivity(from: item, toolExecution: execution)
        var transcript = AgentTranscript(turns: [AgentTranscriptTurn(
            responseSpans: [AgentTranscriptProviderResponseSpan(lifecycle: .completed, startedAt: item.timestamp, completedAt: item.timestamp, activities: [activity])],
            startedAt: item.timestamp,
            completedAt: item.timestamp
        )], nextSequenceIndex: 1)
        for pass in 1 ... 2 {
            let persisted = AgentTranscriptPolicyPipeline.persistedTranscript(from: transcript).transcript
            let encoded = try JSONEncoder().encode(persisted)
            let decoded = try JSONDecoder().decode(AgentTranscript.self, from: encoded)
            let restored = AgentTranscriptPolicyPipeline.runtimeTranscript(decoded)
            let row = try XCTUnwrap((restored.projection.workingRows + restored.projection.archivedRows).first { $0.id == item.id })
            let restoredDTO = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: row.toolResultJSON))
            XCTAssertEqual(contextBuilderOracleLaneCoverage(for: restoredDTO)?.summaryText, coverage.summaryText, "round trip \(pass)")
            XCTAssertFalse(row.toolResultJSON?.contains("finding finding") == true)
            transcript = restored.transcript
        }
    }

    func testPersistedAskOracleKeepsLaneDigest() throws {
        let raw: [String: Any] = [
            "chat_id": "review-chat",
            "mode": "review",
            "response": "primary answer",
            "status": "partial_failure",
            "oracle_count": 2,
            "oracle_results": [
                rawLane(0, "astra-2", "completed", response: "primary answer"),
                rawLane(1, "claude-opus-5", "cancelled", errorCode: "cancelled", errorMessage: "Oracle lane was cancelled.")
            ]
        ]
        let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(
            for: AgentChatItem(kind: .toolResult, text: "", toolName: "ask_oracle", toolResultJSON: jsonString(raw), toolIsError: false)
        ))
        XCTAssertFalse(summary.resultJSON.contains("primary answer"), summary.resultJSON)
        let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: summary.resultJSON))
        XCTAssertEqual(dto.chatID, "review-chat")
        XCTAssertEqual(OracleLaneCoverage(lanes: dto.oracleResults, oracleCount: dto.oracleCount)?.summaryText, "1/2 lanes · claude-opus-5 cancelled")
    }

    func testSingleLanePersistedSummaryIsUnchanged() throws {
        let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(
            for: AgentChatItem(
                kind: .toolResult,
                text: "",
                toolName: "ask_oracle",
                toolResultJSON: jsonString(["chat_id": "c", "mode": "chat", "response": "x"]),
                toolIsError: false
            )
        ))
        XCTAssertFalse(summary.resultJSON.contains("oracle_results"), summary.resultJSON)
    }

    func testInvalidGroupMetadataCannotClaimCompleteCoverageOrPersistInventedCount() throws {
        let valid = [rawLane(0, "a", "completed"), rawLane(1, "b", "completed")]
        var wrongRole = valid
        wrongRole[1]["role"] = "primary"
        var negativeIndex = valid
        negativeIndex[0]["lane_index"] = -1
        let cases: [(String, Int?, [[String: Any]])] = [
            ("missing count", nil, valid), ("declared larger", 3, valid), ("declared smaller", 1, valid),
            ("duplicate index", 2, [valid[0], valid[0]]),
            ("gap", 2, [valid[0], rawLane(2, "b", "completed")]),
            ("negative index", 2, negativeIndex), ("wrong role", 2, wrongRole)
        ]
        for (label, count, lanes) in cases {
            var reply: [String: Any] = ["chat_id": "review-chat", "oracle_results": lanes]
            if let count { reply["oracle_count"] = count }
            let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: jsonString([
                "response_type": "review", "review": reply
            ])))
            XCTAssertTrue(contextBuilderOracleLaneSummaries(for: dto).isEmpty, label)
            XCTAssertNil(contextBuilderOracleLaneCoverage(for: dto), label)
            XCTAssertNil(AgentToolResultPersistencePolicy.oracleGroupDigest(from: reply), label)
            let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(
                for: AgentChatItem(kind: .toolResult, text: "", toolName: "context_builder", toolResultJSON: jsonString([
                    "response_type": "review", "review": reply
                ]), toolIsError: false)
            ))
            let restored = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: summary.resultJSON))
            XCTAssertEqual(restored.review?.chatID, "review-chat", label)
            XCTAssertNil(restored.review?.oracleCount, label)
            XCTAssertNil(contextBuilderOracleLaneCoverage(for: restored), label)
        }
    }

    @MainActor
    func testInvalidGroupMetadataPreservesExplicitIncompleteCardStatus() throws {
        for (groupStatus, expected) in [("partial_failure", ToolCardStatus.warning), ("failed", .failure)] {
            let raw: [String: Any] = [
                "chat_id": "review-chat", "response": "primary answer", "status": groupStatus,
                "oracle_count": 3,
                "oracle_results": [rawLane(0, "a", "completed"), rawLane(1, "b", "failed")]
            ]
            let item = AgentChatItem(kind: .toolResult, text: "", toolName: "ask_oracle", toolResultJSON: jsonString(raw), toolIsError: false)
            let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: item.toolResultJSON))
            XCTAssertNil(OracleLaneCoverage(lanes: dto.oracleResults, oracleCount: dto.oracleCount))
            XCTAssertEqual(ChatSendResultCard(item: item, oracleOpenContext: nil).status, expected)
        }
    }

    func testExplicitCancelledOracleToolResultKeepsCancellationDuringPersistence() throws {
        for tool in ["ask_oracle", "oracle_send", "context_builder"] {
            let item = AgentChatItem(
                kind: .toolResult,
                text: "",
                toolName: tool,
                toolResultJSON: #"{"status":"cancelled"}"#,
                toolIsError: true
            )
            XCTAssertEqual(AgentTranscriptToolNormalizer.status(for: item), .cancelled)
            XCTAssertEqual(try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: item)).transcriptStatus, .cancelled)
        }
    }

    // MARK: - Helpers

    private func lane(
        _ index: Int,
        _ model: String,
        _ status: String,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) -> ToolResultDTOs.ChatSendDTO.OracleLaneDTO {
        let json = jsonString(rawLane(index, model, status, errorCode: errorCode, errorMessage: errorMessage))
        return ToolJSON.decode(ToolResultDTOs.ChatSendDTO.OracleLaneDTO.self, from: json)!
    }

    private func rawLane(
        _ index: Int,
        _ model: String,
        _ status: String,
        response: String? = nil,
        profileModel: String? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) -> [String: Any] {
        var lane: [String: Any] = [
            "lane_index": index,
            "role": index == 0 ? "primary" : "additional",
            "chat_id": "chat-\(index)",
            "model_id": model,
            "status": status
        ]
        if let response { lane["response"] = response }
        if let profileModel {
            lane["execution_profile"] = ["provider_id": "provider", "model_id": profileModel, "effective_reasoning_effort": "high"]
        }
        if let errorCode {
            lane["error"] = ["code": errorCode, "message": errorMessage ?? errorCode]
        }
        return lane
    }

    private func jsonString(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class OracleTicketResultCardTests: XCTestCase {
    private typealias Harness = OracleTicketExecutionHarness

    func testIssuedRunningCancelledAndFailedTicketsProjectObservedStateThroughDiskRestore() async throws {
        for tool in ["ask_oracle", "oracle_send"] {
            for outcome in [Harness.Outcome.held, .failed] {
                try await Harness.withFixture(outcome: outcome) { driver, service, invocation in
                    let start = try await Harness.execute(tool, args: ["op": .string("start"), "detach": .bool(true), "message": .string("PRIVATE_CARD_INPUT"), "new_chat": .bool(true)], service: service, invocation: invocation)
                    let id = try XCTUnwrap(start.objectValue?["job_id"]?.stringValue)
                    try await self.assertProjection(start, tool: tool, driver: driver)
                    if outcome == .held {
                        let poll = try await Harness.execute(tool, args: ["op": .string("poll"), "job_id": .string(id)], service: service, invocation: invocation)
                        try await self.assertProjection(poll, tool: tool, driver: driver)
                        let cancel = try await Harness.execute(tool, args: ["op": .string("cancel"), "job_id": .string(id)], service: service, invocation: invocation)
                        try await self.assertProjection(cancel, tool: tool, driver: driver)
                    }
                    let terminal = try await Harness.execute(tool, args: ["op": .string("wait"), "job_id": .string(id), "timeout": .int(5)], service: service, invocation: invocation)
                    XCTAssertEqual(terminal.objectValue?["job"]?.objectValue?["status"]?.stringValue, outcome == .held ? "cancelled" : "failed")
                    if outcome == .failed {
                        // This producer failed after creating its chat, unlike pre-dispatch cancellation.
                        let chat = try XCTUnwrap(terminal.objectValue?["job"]?.objectValue?["chat_id"]?.stringValue)
                        let log = try await driver.window.oracleViewModel.tool_chatGetLog(args: ["chat_id": .string(chat)])
                        XCTAssertEqual(log["chat_id"]?.stringValue, chat)
                    }
                    try await self.assertProjection(terminal, tool: tool, driver: driver)
                }
            }
        }
    }

    func testIssuedCompletedSingletonAndPartialGroupKeepReplyCoverageAndRecovery() async throws {
        for tool in ["ask_oracle", "oracle_send"] {
            for outcome in [Harness.Outcome.completed, .partialGroup] {
                try await Harness.withFixture(outcome: outcome) { driver, service, invocation in
                    let start = try await Harness.execute(tool, args: ["op": .string("start"), "detach": .bool(true), "message": .string("PRIVATE_CARD_INPUT"), "new_chat": .bool(true)], service: service, invocation: invocation)
                    let id = try XCTUnwrap(start.objectValue?["job_id"]?.stringValue)
                    let terminal = try await Harness.execute(tool, args: ["op": .string("wait"), "job_id": .string(id), "timeout": .int(5)], service: service, invocation: invocation)
                    XCTAssertEqual(terminal.objectValue?["job"]?.objectValue?["status"]?.stringValue, "completed")
                    XCTAssertNotNil(terminal.objectValue?["chat_id"])
                    if outcome == .partialGroup {
                        XCTAssertEqual(terminal.objectValue?["status"]?.stringValue, "partial_failure")
                        XCTAssertEqual(terminal.objectValue?["oracle_count"]?.intValue, 2)
                    }
                    try await self.assertProjection(terminal, tool: tool, driver: driver)
                }
            }
        }
    }

    func testIssuedExpiredTicketWarnsAndStrictSelectionDoesNotInventRecovery() async throws {
        for tool in ["ask_oracle", "oracle_send"] {
            try await Harness.withFixture(outcome: .completed, retention: 0) { driver, service, invocation in
                let start = try await Harness.execute(tool, args: ["op": .string("start"), "detach": .bool(true), "message": .string("PRIVATE_CARD_INPUT"), "new_chat": .bool(true)], service: service, invocation: invocation)
                let id = try XCTUnwrap(start.objectValue?["job_id"]?.stringValue)
                _ = try await Harness.execute(tool, args: ["op": .string("wait"), "job_id": .string(id), "timeout": .int(5)], service: service, invocation: invocation)
                let expired = try await Harness.execute(tool, args: ["op": .string("poll"), "job_id": .string(id)], service: service, invocation: invocation)
                XCTAssertEqual(expired.objectValue?["job"]?.objectValue?["status"]?.stringValue, "expired")
                try await self.assertProjection(expired, tool: tool, driver: driver)
                let native = try self.object(expired)
                var malformed = native
                var job = try XCTUnwrap(native["job"] as? [String: Any])
                job["id"] = UUID().uuidString
                job["chat_id"] = "foreign-chat"
                malformed["job"] = job
                let open = AgentOracleOpenContext(windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id, tabID: driver.tabID)
                for invalid in [malformed, ["rawOutput": ["rawOutput": native]]] {
                    let row = try self.row(invalid, tool: tool)
                    XCTAssertFalse(ChatSendResultCard(item: row, oracleOpenContext: open).summary.contains(id))
                    XCTAssertNil(oracleToolResultPopoverUserInfo(item: row, openContext: open))
                }
                let reply = ChatSendReply(chatId: UUID(), shortId: "direct-reply", mode: "chat", response: "answer", errors: nil)
                var direct = try self.object(reply.toMCPValue())
                direct["rawOutput"] = native
                let card = try ChatSendResultCard(item: self.row(direct, tool: tool), oracleOpenContext: open)
                XCTAssertEqual(card.status, .success)
                XCTAssertEqual(card.summary, "chat • direct-reply", "A direct native reply outranks a conflicting nested ticket")
            }
        }
    }

    private func assertProjection(_ issued: Value, tool: String, driver: ContextBuilderMultiRootDiscoveryDriver) async throws {
        let native = try object(issued)
        let ticket = try JSONDecoder().decode(ToolResultDTOs.LongRunningJobTicketDTO.self, from: JSONSerialization.data(withJSONObject: native))
        let open = AgentOracleOpenContext(windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id, tabID: driver.tabID)
        for representation in ["direct", "object", "string"] {
            let value: [String: Any] = try representation == "direct" ? native : ["status": "completed", "rawOutput": representation == "string" ? String(decoding: JSONSerialization.data(withJSONObject: native), as: UTF8.self) : native]
            for observationError in [false, true] {
                let item = try row(value, tool: tool, observationError: observationError)
                let restored = try await saveLoad(item, driver: driver)
                for projected in [item, restored] {
                    let card = ChatSendResultCard(item: projected, oracleOpenContext: open)
                    let expected: ToolCardStatus = if observationError { .failure } else {
                        switch ticket.job.status {
                        case .failed, .cancelled: .failure
                        case .expired: .warning
                        case .running, .cancelling, .unknown: .neutral
                        case .completed: native["status"] as? String == "partial_failure" ? .warning : .success
                        }
                    }
                    XCTAssertEqual(card.status, expected, "\(tool) \(ticket.job.status) \(representation), archived=\(projected.id != item.id), observationError=\(observationError)")
                    XCTAssertTrue(card.summary.contains(ticket.jobID.uuidString))
                    XCTAssertEqual(card.summary.hasPrefix("Observation failed · "), observationError)
                    if ticket.job.status == .completed {
                        XCTAssertTrue(card.summary.contains("Job completed"))
                        if native["oracle_count"] as? Int == 2 { XCTAssertTrue(card.summary.contains("1/2")) }
                    } else if !ticket.job.status.isTerminal, projected.toolArgsJSON == nil {
                        XCTAssertTrue(card.summary.contains("Live job state unknown (last observed \(ticket.job.status.rawValue))"))
                    } else {
                        XCTAssertTrue(card.summary.contains("Observed \(ticket.job.status.rawValue)"))
                    }
                    // A returned failed/cancelled job is still a successful control observation.
                    if !observationError, ticket.job.status != .completed {
                        XCTAssertEqual(AgentTranscriptToolNormalizer.status(for: projected), .success)
                    }
                    let recovered = AgentOraclePopoverRoute(notificationUserInfo: oracleToolResultPopoverUserInfo(item: projected, openContext: open))
                    let chat = native["chat_id"] as? String ?? ticket.job.chatID
                    if ticket.job.status == .completed || ticket.job.status == .failed || ticket.job.status == .cancelled,
                       let chat, ticket.job.contextID == driver.tabID
                    {
                        XCTAssertEqual(recovered?.chatID, chat)
                        XCTAssertEqual(recovered?.tabID, driver.tabID)
                    } else {
                        XCTAssertNil(recovered, "Nonterminal/expired observations do not authorize opening an ambient conversation")
                    }
                    XCTAssertNil(oracleToolResultPopoverUserInfo(item: projected, openContext: AgentOracleOpenContext(windowID: open.windowID, workspaceID: open.workspaceID, tabID: UUID())), "Foreign ticket context cannot recover a chat")
                }
                XCTAssertEqual(restored.toolIsError, observationError)
            }
        }
    }

    private func row(_ value: [String: Any], tool: String, observationError: Bool = false) throws -> AgentChatItem {
        var item = try AgentChatItem.toolResult(name: tool, argsJSON: #"{"message":"PRIVATE_CARD_INPUT"}"#, resultJSON: String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self), isError: observationError, sequenceIndex: 1)
        item.toolInvocationID = UUID()
        return item
    }

    private func saveLoad(_ item: AgentChatItem, driver: ContextBuilderMultiRootDiscoveryDriver) async throws -> AgentChatItem {
        let session = AgentSession(workspaceID: driver.fixture.workspace.id, composeTabID: driver.tabID, name: "Oracle ticket card", transcript: AgentTranscriptIO.importLegacyItems([.user("Inspect", sequenceIndex: 0), item]), lastRunState: "completed")
        let file = try await AgentSessionDataService().saveAgentSession(session, for: driver.fixture.workspace)
        let bytes = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(bytes.contains("PRIVATE_CARD_INPUT"))
        XCTAssertFalse(bytes.contains("PRIVATE_CARD_RESPONSE"))
        let loaded = try await AgentSessionDataService().loadAgentSession(from: file)
        let projection = try AgentTranscriptProjectionBuilder.build(from: XCTUnwrap(loaded.transcript))
        let restored = try XCTUnwrap((projection.archivedBlocks + projection.workingBlocks).flatMap(\.rows).first { $0.kind == .toolResult && $0.toolInvocationID == item.toolInvocationID })
        XCTAssertNil(restored.toolArgsJSON)
        XCTAssertLessThanOrEqual(try XCTUnwrap(restored.toolResultJSON).utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
        return restored
    }

    private func object(_ value: Value) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ToolOutputFormatter.rawJSONString(value).utf8)) as? [String: Any])
    }
}
