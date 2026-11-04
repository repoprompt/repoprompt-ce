import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import XCTest

private enum OracleFoundationContext {
    @TaskLocal static var marker: Int?
}

@MainActor
private final class OracleFoundationGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        opened = true
        let ready = waiters
        waiters.removeAll()
        ready.forEach { $0.resume() }
    }
}

@MainActor
final class OracleGroupCancellationAdapterTests: XCTestCase {
    func testStreamedPrimaryProgressSuppliesCancellationPartialAfterAuxiliarySettles() async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -9325,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OracleGroupCancellationAdapterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting(nil)
            composition.workspaceManager.prepareForWindowClose()
            composition.oracleViewModel.sessions = []
            try? FileManager.default.removeItem(at: root)
        }

        var workspace = try XCTUnwrap(composition.workspaceManager.activeWorkspace)
        let tab = ComposeTabState(id: UUID())
        workspace.customStoragePath = root
        workspace.composeTabs = [tab]
        workspace.activeComposeTabID = tab.id
        if let index = composition.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }) {
            composition.workspaceManager.workspaces[index] = workspace
        }
        composition.workspaceManager.activeWorkspace = workspace
        composition.promptManager.loadComposeTabsFromWorkspace(workspace)
        composition.apiSettingsViewModel.openAIApiKey = "test-key"
        composition.apiSettingsViewModel.isOpenAIKeyValid = true

        let preset = try ModelPreset(
            name: "Cancellation-Group",
            modelStrings: [AIModel.gpt54Mini.rawValue, AIModel.gpt54.rawValue]
        )
        let profile = AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt54.rawValue)
        let snapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: profile,
            modelPresets: [preset],
            modelPresetsExposed: true,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all(),
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
        let primaryProgressObserved = expectation(description: "primary stream progress observed")
        let auxiliarySettled = expectation(description: "auxiliary lane settled")
        composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { _, model in
            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                Task { @MainActor in
                    if model == .gpt54Mini {
                        continuation.yield(ChatStreamOutput(
                            text: "primary partial",
                            reasoning: nil,
                            tokens: ChatTokenInfo()
                        ))
                        await self.fulfillment(of: [auxiliarySettled], timeout: 2)
                        continuation.finish(throwing: CancellationError())
                    } else {
                        await self.fulfillment(of: [primaryProgressObserved], timeout: 2)
                        continuation.yield(ChatStreamOutput(
                            text: "auxiliary answer",
                            reasoning: nil,
                            tokens: ChatTokenInfo(),
                            terminalOutcome: .completed
                        ))
                        continuation.finish()
                    }
                }
            }
            return (UUID(), stream)
        }

        let context = makeTabContext(workspaceID: workspace.id, tabID: tab.id)
        let owner = try OracleViewModel.oracleGroupOwner(workspaceID: workspace.id, tabID: tab.id)
        let store = AppDomainRuntimeComposition.shared.oracleConversationStore
        var groupIDForCleanup: OracleGroupID?
        defer {
            if let groupIDForCleanup {
                addTeardownBlock {
                    if let retained = try await store.load(groupID: groupIDForCleanup, owner: owner) {
                        try await store.delete(
                            groupID: retained.group.id,
                            owner: owner,
                            expectedRevision: retained.revision
                        )
                    }
                }
            }
        }

        let completion = try await composition.oracleViewModel.tool_chatSendWithConfiguredRosterCompletion(
            args: [
                "message": .string("Cancel after streaming"),
                "mode": .string("review"),
                "model": .string(preset.name),
                "new_chat": .bool(true)
            ],
            promptVM: composition.promptManager,
            tabContext: context,
            callbacks: AppOracleGroupExecutionCallbacks(
                prepared: { groupID, _, _ in
                    groupIDForCleanup = groupID
                },
                progress: { event in
                    if event.kind == .laneSettled, event.laneID?.index == 1 {
                        auxiliarySettled.fulfill()
                    }
                },
                laneProgress: { laneID, text, _ in
                    if laneID.index == 0, text == "primary partial" {
                        primaryProgressObserved.fulfill()
                    }
                }
            ),
            capturedProfile: profile,
            selectionSnapshotOverride: snapshot
        )
        groupIDForCleanup = completion.result.groupID

        XCTAssertEqual(completion.result.status, .failed)
        XCTAssertEqual(completion.result.oracleResults.map(\.laneIndex), [0, 1])
        XCTAssertEqual(completion.result.oracleResults.map(\.status), [.cancelled, .completed])
        XCTAssertNil(completion.result.primary.response)
        XCTAssertEqual(completion.result.primary.error?.code, "cancelled")
        XCTAssertEqual(completion.result.primary.error?.partialResponse, "primary partial")
        XCTAssertEqual(completion.result.oracleResults[1].response, "auxiliary answer")
        let beforeClear = try await store.load(groupID: completion.result.groupID, owner: owner)
        XCTAssertNil(beforeClear?.turns.last?.backgroundExecution, "This is a foreground group, not a background-only deletion case")
        let sibling = try XCTUnwrap(composition.oracleViewModel.resolveSession(id: completion.result.oracleResults[1].chatID))
        await composition.oracleViewModel.switchToSession(sibling.id)
        XCTAssertFalse(composition.oracleViewModel.messages.isEmpty)
        await composition.oracleViewModel.clearChat()
        let afterClear = try await store.load(groupID: completion.result.groupID, owner: owner)
        XCTAssertNil(afterClear, "Baseline Clear already deletes the entire canonical group through deleteSession")
        XCTAssertFalse(composition.oracleViewModel.sessions.contains { $0.oracleGroupID == completion.result.groupID.rawValue })
    }

    func testAppServiceCollectColdRecoveryAndStop() async throws {
        let fixture = try await AgentRunMCPControlledSessionContext.make(workspaceNamePrefix: "Background Oracle", workspaceSwitchReason: "oracle fixture", clientName: "oracle-fixture", unusedStartRunMessage: "No parent provider")
        addTeardownBlock { await fixture.cleanup() }
        let window = fixture.window, session = fixture.session, registry = AppDomainRuntimeComposition.shared.oracleBackgroundInvocations
        let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspaceID)
        let settings = GlobalSettingsStore.shared, priorAdditional = settings.additionalOracleModelRaws()
        try settings.setAdditionalOracleModelRaws([AIModel.gpt54.rawValue], commit: false)
        defer { try? settings.setAdditionalOracleModelRaws(priorAdditional, commit: false)
            window.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting(nil)
        }
        window.apiSettingsViewModel.openAIApiKey = "test-key"
        window.apiSettingsViewModel.isOpenAIKeyValid = true
        let connectionID = UUID(), ordinaryConnectionID = UUID()
        func snapshot() -> MCPTabContextSnapshot {
            .init(tabID: session.tabID, windowID: window.windowID, workspaceID: workspaceID, promptText: "", selection: StoredSelection(), selectedMetaPromptIDs: [], tabName: "Oracle fixture", runID: session.runID, activeAgentSessionID: fixture.sessionID, frozenLookupContext: .visibleWorkspace, explicitlyBound: true)
        }
        var heartbeats = 0, scopeAvailable = true
        let blockingReply: [String: Value] = ["chat_id": .string("fixed"), "response": .string("  unchanged\n"), "errors": .null]
        var forwarded: [[String: Value]] = []
        let service = MCPOracleToolService(
            askOracleToolName: "ask_oracle", oracleSendToolName: "oracle_send", oracleChatLogToolName: "oracle_chat_log",
            promptVM: window.promptManager, oracleVM: window.oracleViewModel, liveRunPurpose: { id in id == connectionID ? .agentModeRun : .unknown },
            resolveTabContextSnapshot: { _ in .init(snapshot: snapshot()) }, requireCurrentTabContext: { _ in
                guard scopeAvailable else { throw MCPError.invalidParams("Fixture missing owner") }
                return snapshot()
            },
            stabilizedVirtualContext: { $0 }, resolveDelegatedReviewPackaging: { _, _, _, _ in nil }, rebindChatSessionIfNeeded: { _, _ in XCTFail("Control must not rebind") },
            resolveTabIDForAgentMode: { _, _ in session.tabID }, requireTargetWindow: { window }, rawExplicitTabID: { _ in nil },
            sendStageProgress: { _, _, _, _ in }, withHeartbeat: { _, _, _, _, operation in heartbeats += 1
                return try await operation()
            },
            sendChat: { args, prompt, context in
                if args["message"] == .string("conflict") { throw OracleGroupClaimError.conflict }
                if args["message"] == .string("parity") { forwarded.append(args)
                    return blockingReply
                }
                return try await window.oracleViewModel.tool_chatSendWithConfiguredRoster(args: args, promptVM: prompt, tabContext: context)
            },
            exportOracleResponse: { _ in throw CancellationError() }
        )
        func invocation(agentConnection: Bool = true) -> ToolInvocationContext {
            .trustedLocal(toolName: "ask_oracle", metadata: .init(connectionID: agentConnection ? connectionID : ordinaryConnectionID, clientName: "oracle-fixture", windowID: window.windowID, invocationID: UUID()))
        }
        func collect(_ args: [String: Value] = [:]) async throws -> Value {
            try await service.executeOracleChatLog(args: args.merging(["op": .string("collect")]) { _, new in new }, invocationContext: invocation())
        }
        let store = AppDomainRuntimeComposition.shared.oracleConversationStore
        let canonicalOwner = try OracleViewModel.oracleGroupOwner(workspaceID: workspaceID, tabID: session.tabID)
        for schedule in ["targeted", "activeStop", "idleStop", "managedStop", "refusedRouteStop"] {
            session.installRunID(UUID())
            _ = session.beginRunAttempt(source: "oracle-fixture")
            session.runState = .running
            let creatingRun = try XCTUnwrap(session.runID)
            var streams: [AIModel: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation] = [:]
            let dispatched = expectation(description: "both exact lanes dispatched")
            dispatched.expectedFulfillmentCount = 2
            let secondaryCancelled = expectation(description: "secondary provider stream cancelled: \(schedule)")
            window.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { _, model in
                let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                    streams[model] = continuation
                    if model == .gpt54 {
                        continuation.onTermination = { termination in
                            if case .cancelled = termination { secondaryCancelled.fulfill() }
                        }
                    }
                }
                dispatched.fulfill()
                return (UUID(), stream)
            }
            defer { streams.values.forEach { $0.finish() } }
            let args: [String: Value] = ["message": .string("fixture"), "mode": .string("chat"), "new_chat": .bool(true), "model": .string(AIModel.gpt54Mini.rawValue), "background": .bool(true)]
            if schedule == "targeted" {
                let before = window.oracleViewModel.sessions.map(\.id)
                scopeAvailable = false
                let stale = try await service.executeAskOracle(args: args, invocationContext: invocation())
                XCTAssertEqual(stale.objectValue?["code"]?.stringValue, "oracle_background_unsupported")
                XCTAssertEqual(stale.objectValue?["reason"]?.stringValue, "session")
                scopeAvailable = true
                XCTAssertEqual(window.oracleViewModel.sessions.map(\.id), before)
                for (extra, reason): ([String: Value], String) in [(["export_response": .bool(true)], "export"), (["additional_oracles": .array([])], "group")] {
                    let refusal = try await service.executeAskOracle(args: args.merging(extra) { _, new in new }, invocationContext: invocation())
                    XCTAssertEqual(refusal.objectValue?["code"]?.stringValue, "oracle_background_unsupported")
                    XCTAssertEqual(refusal.objectValue?["reason"]?.stringValue, reason)
                    XCTAssertEqual(window.oracleViewModel.sessions.map(\.id), before)
                }
                do { _ = try await service.executeAskOracle(args: args.merging(["background": .string("true")]) { _, new in new }, invocationContext: invocation())
                    XCTFail("Wrong type must refuse")
                } catch let MCPError.invalidParams(message) { XCTAssertEqual(message, "Invalid background; expected boolean.") }
            }
            let initialHeartbeats = heartbeats
            let receipt = try await service.executeAskOracle(args: args, invocationContext: invocation())
            XCTAssertEqual(receipt.objectValue?["status"]?.stringValue, "running")
            XCTAssertNil(receipt.objectValue?["response"])
            XCTAssertEqual(receipt.objectValue?["lanes"]?.arrayValue?.count, 2)
            XCTAssertEqual(heartbeats, initialHeartbeats)
            await fulfillment(of: [dispatched], timeout: 3)
            let owner = try XCTUnwrap(session.oracleBackgroundOwner)
            let live = try XCTUnwrap(registry.snapshot(for: owner).invocations.first { $0.phase.isLive })
            let primary = try XCTUnwrap(live.queries[0])
            streams[.gpt54Mini]?.yield(.init(text: "exact current answer", reasoning: nil, tokens: ChatTokenInfo(), terminalOutcome: .completed))
            streams[.gpt54Mini]?.finish()
            let primaryAnswer = try await window.oracleViewModel.waitForContextBuilderCompletion(primary.queryID)
            XCTAssertEqual(primaryAnswer, "exact current answer")
            let handle: [String: Value] = try ["oracle_group_id": XCTUnwrap(receipt.objectValue?["oracle_group_id"]), "oracle_turn_id": XCTUnwrap(receipt.objectValue?["oracle_turn_id"])]
            let inspected = try await collect(handle)
            let lanes = try XCTUnwrap(inspected.objectValue?["lanes"]?.arrayValue)
            XCTAssertEqual(lanes[0].objectValue?["response"]?.stringValue, "exact current answer")
            XCTAssertEqual(lanes[0].objectValue?["answer_ready"], .bool(true))
            XCTAssertNil(lanes[1].objectValue?["response"])
            let missing = await window.oracleViewModel.backgroundOracleCompletedResponse(.init(sessionID: primary.sessionID, queryID: UUID(), oracleGeneration: primary.oracleGeneration))
            XCTAssertNil(missing, "Never substitute the prior assistant answer")
            _ = session.endCurrentRunAttempt(source: "ordinary terminal")
            session.runState = .completed
            XCTAssertTrue(registry.hasLiveOwner(owner), "Natural turn end cannot cancel session work")
            if schedule == "refusedRouteStop" {
                let generation = session.bindingTransitionGeneration
                let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
                let refused = await window.agentModeViewModel.activateRoutedAgentSession(tabID: session.tabID, sessionID: UUID(), workspace: workspace)
                XCTAssertEqual(refused, .sessionNotFound)
                XCTAssertGreaterThan(session.bindingTransitionGeneration, generation)
                XCTAssertEqual(session.persistentSessionBindingIdentity, owner.binding)
                XCTAssertEqual(session.oracleBackgroundOwner, owner)
                XCTAssertTrue(registry.hasLiveOwner(owner), "A refused route is not a session rebind or Stop")
                XCTAssertFalse(registry.admissionIsClosed(for: owner))
            }
            session.installRunID(UUID())
            _ = session.beginRunAttempt(source: "later user turn")
            session.runState = .running
            if schedule == "refusedRouteStop" {
                do {
                    _ = try await service.executeAskOracle(args: ["message": .int(7), "background": .bool(true)], invocationContext: invocation())
                    XCTFail("Malformed send must refuse without replacing the live owner")
                } catch MCPError.invalidParams {}
                XCTAssertEqual(session.oracleBackgroundOwner, owner)
                let busy = try await service.executeAskOracle(args: ["message": .string("background continuation"), "chat_id": XCTUnwrap(receipt.objectValue?["chat_id"]), "background": .bool(true)], invocationContext: invocation())
                XCTAssertEqual(busy.objectValue?["code"]?.stringValue, "oracle_background_busy")
                XCTAssertEqual(busy.objectValue?["oracle_turn_id"], receipt.objectValue?["oracle_turn_id"])
                XCTAssertEqual(session.oracleBackgroundOwner, owner)
            }
            let recovered = try await collect()
            XCTAssertEqual(recovered.objectValue?["open_count"], .int(1))
            XCTAssertEqual(recovered.objectValue?["scope"], .string("current_process"))
            XCTAssertEqual(recovered.objectValue?["turns"]?.arrayValue?.first?.objectValue?["agent_run_id"]?.stringValue, creatingRun.uuidString)
            let caller = try await service.backgroundCaller(args: [:], invocation: invocation(), tool: "ask_oracle")
            let claimedBusy = try await service.backgroundBusyAfterClaim(args: ["chat_id": XCTUnwrap(receipt.objectValue?["chat_id"])], caller: caller)
            XCTAssertEqual(claimedBusy?.objectValue?["oracle_turn_id"], receipt.objectValue?["oracle_turn_id"], "Only a proven owned prepared background turn maps a foreground claim collision")
            let busy = try await service.executeAskOracle(args: ["message": .string("continue"), "chat_id": XCTUnwrap(receipt.objectValue?["chat_id"])], invocationContext: invocation())
            XCTAssertEqual(busy.objectValue?["code"]?.stringValue, "oracle_background_busy")
            do { _ = try await service.executeOracleChatLog(args: ["chat_id": XCTUnwrap(receipt.objectValue?["chat_id"])], invocationContext: invocation())
                XCTFail("Legacy read must retain exact-run ownership")
            } catch {}
            if schedule == "targeted" {
                let cancelled = try await service.executeAskOracle(args: handle.merging(["op": .string("cancel")]) { _, new in new }, invocationContext: invocation())
                XCTAssertEqual(cancelled.objectValue?["status"]?.stringValue, "cancelling")
                try await registry.join(owner: owner, reference: live.reference)
            } else {
                if schedule == "idleStop" || schedule == "managedStop" { _ = session.endCurrentRunAttempt(source: "idle")
                    session.runState = .completed
                }
                let attempt = session.activeRunAttemptID
                if schedule == "managedStop" {
                    window.agentModeViewModel.withdrawQueuedWorkForManagedStop(session: session)
                    let joined = await window.agentModeViewModel.awaitOracleBackgroundDrain(for: session)
                    XCTAssertTrue(joined, "Claim-time Stop survives subsequent run admission refusal")
                } else { await window.agentModeViewModel.cancelAgentRun(tabID: session.tabID) }
                if schedule == "idleStop" || schedule == "managedStop" { XCTAssertEqual(session.activeRunAttemptID, attempt, "Idle Oracle Stop must not manufacture a run") }
                XCTAssertTrue(registry.isDrained(owner))
                session.installRunID(UUID())
                _ = session.beginRunAttempt(source: "post Stop inspection")
                session.runState = .running
            }
            await fulfillment(of: [secondaryCancelled], timeout: 3)
            let terminal = try await collect(handle)
            XCTAssertEqual(terminal.objectValue?["oracle_results"]?.arrayValue?.first?.objectValue?["response"]?.stringValue, "exact current answer")
            XCTAssertEqual(terminal.objectValue?["oracle_results"]?.arrayValue?[1].objectValue?["status"]?.stringValue, "cancelled")
            let repeated = try await service.executeAskOracle(args: handle.merging(["op": .string("cancel")]) { _, new in new }, invocationContext: invocation())
            XCTAssertEqual(repeated.objectValue?["status"]?.stringValue, "not_running")
            await registry.close(owner).value
            try registry.remove(owner)
            let empty = try await collect()
            XCTAssertEqual(empty.objectValue?["status"]?.stringValue, "empty")
            XCTAssertEqual(empty.objectValue?["scope"]?.stringValue, "current_process")
            let cold = try await collect(handle)
            XCTAssertEqual(cold.objectValue?["oracle_results"], terminal.objectValue?["oracle_results"])
            let legacy = try await service.executeAskOracle(args: ["message": .string("continue"), "chat_id": XCTUnwrap(receipt.objectValue?["chat_id"])], invocationContext: invocation())
            XCTAssertNil(legacy.objectValue?["response"]?.stringValue)
            XCTAssertTrue(legacy.objectValue?["oracle_results"]?.arrayValue?.allSatisfy { $0.objectValue?["status"]?.stringValue != "completed" } ?? false, "Existing grouped continuation returns lane ownership refusals, not an earlier answer")
            if schedule == "targeted", let projection = window.oracleViewModel.sessions.first(where: { $0.id == primary.sessionID }) {
                let original = window.oracleViewModel.sessions
                window.oracleViewModel.sessions.append(projection)
                do {
                    let uncertain = try await service.executeAskOracle(args: ["message": .string("conflicting projection"), "chat_id": XCTUnwrap(receipt.objectValue?["chat_id"]), "background": .bool(true)], invocationContext: invocation())
                    XCTAssertEqual(uncertain.objectValue?["code"]?.stringValue, "oracle_background_unavailable", "Internal projection uncertainty must not escape as a raw nested error")
                } catch { window.oracleViewModel.sessions = original
                    throw error
                }
                window.oracleViewModel.sessions = original
            }
            let loaded = try await store.load(groupID: live.reference.groupID, owner: canonicalOwner)
            let saved = try XCTUnwrap(loaded)
            XCTAssertEqual(saved.turns.last?.state, .terminal, "The drain includes canonical publication")
            // Deletion acquires the same group claim: success also proves runtime claim release.
            try await store.delete(groupID: saved.group.id, owner: canonicalOwner, expectedRevision: saved.revision)
        }
        for provenance in [nil, OracleBackgroundExecution(agentSessionID: UUID(), agentRunID: UUID(), invocationID: UUID()), OracleBackgroundExecution(agentSessionID: fixture.sessionID, agentRunID: UUID(), invocationID: UUID())] {
            let models = try ["cold-primary", "cold-secondary"].map { try OracleModelReference(providerID: "fixture", modelID: $0) }
            let members = try models.enumerated().map { try OracleGroupMember(laneID: .init(index: $0.offset), publicChatID: "cold-\(UUID().uuidString)", model: $0.element) }
            let cold = try OracleGroupDocument(group: .init(size: 2), owner: canonicalOwner, name: "cold prepared", revision: 1, createdAt: Date(timeIntervalSince1970: 1000), updatedAt: Date(timeIntervalSince1970: 1000), roster: .init(primary: models[0], additional: [models[1]]), members: members, turns: [.init(input: OracleInput(mode: .chat, userMessage: "cold"), state: .prepared, startedAt: Date(timeIntervalSince1970: 1000), backgroundExecution: provenance)])
            try await store.create(cold)
            let reply = try await collect(["oracle_group_id": .string(cold.group.id.rawValue.uuidString)])
            XCTAssertEqual(reply.objectValue?["status"]?.stringValue, provenance?.agentSessionID == fixture.sessionID ? "interrupted" : "not_found")
            if provenance?.agentSessionID == fixture.sessionID {
                XCTAssertEqual(reply.objectValue?["chat_id"], .string(members[0].publicChatID))
                XCTAssertEqual(reply.objectValue?["mode"], .string("chat"))
                XCTAssertEqual(reply.objectValue?["agent_run_id"], try .string(XCTUnwrap(provenance).agentRunID.uuidString))
                XCTAssertEqual(reply.objectValue?["lanes"], .array(members.map { member in
                    .object(["lane_index": .int(member.laneID.index), "chat_id": .string(member.publicChatID), "model_id": .string(member.model.modelID), "status": .string("interrupted"), "answer_ready": .bool(false), "partial": .bool(false), "truncated": .bool(false)])
                }))
                XCTAssertNil(reply.objectValue?["response"])
                XCTAssertNil(reply.objectValue?["oracle_results"])
            } else { XCTAssertNil(reply.objectValue?["lanes"], "Foreign/legacy history must not disclose its roster") }
            let unchanged = try await store.load(groupID: cold.group.id, owner: canonicalOwner)
            XCTAssertEqual(unchanged, cold, "Cold collection must not recover or rewrite prepared history")
            try await store.delete(groupID: cold.group.id, owner: canonicalOwner, expectedRevision: cold.revision)
        }
        let baseline = try await service.executeAskOracle(args: ["message": .string("parity"), "new_chat": .bool(true)], invocationContext: invocation())
        let explicit = try await service.executeAskOracle(args: ["message": .string("parity"), "new_chat": .bool(true), "background": .bool(false), "op": .string("send")], invocationContext: invocation())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(baseline), try encoder.encode(explicit), "False/omitted must preserve bytes, null and whitespace")
        XCTAssertEqual(forwarded.count, 2)
        XCTAssertEqual(forwarded.first, forwarded.last)
        XCTAssertNil(forwarded.last?["background"])
        XCTAssertNil(forwarded.last?["op"])
        // A foreground conflict without an owned background turn preserves the baseline throw,
        // for both trusted Agent and ordinary callers, rather than fabricating a collect action.
        for isAgent in [true, false] {
            for ask in [true, false] {
                do {
                    let args: [String: Value] = ["message": .string("conflict"), "new_chat": .bool(true)]
                    if ask { _ = try await service.executeAskOracle(args: args, invocationContext: invocation(agentConnection: isAgent)) }
                    else { _ = try await service.executeOracleSend(args: args, invocationContext: invocation(agentConnection: isAgent)) }
                    XCTFail("Unrelated foreground claim conflict must retain its thrown error")
                } catch OracleGroupClaimError.conflict {}
            }
        }
        let absent = try await collect(["oracle_group_id": .string(UUID().uuidString)])
        XCTAssertEqual(absent.objectValue?["code"]?.stringValue, "oracle_background_not_found")
        for malformed in [["limit": Value.int(1)], ["oracle_turn_id": .string(UUID().uuidString)], ["include_finished": .bool(false), "chat_id": .string("chat")]] {
            do { _ = try await collect(malformed)
                XCTFail("Malformed collect must refuse")
            } catch MCPError.invalidParams {}
        }
        window.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { _, _ in (UUID(), AsyncThrowingStream<ChatStreamOutput, Error> { _ in }) }
        let closing = try await service.executeAskOracle(args: ["message": .string("close fixture"), "new_chat": .bool(true), "model": .string(AIModel.gpt54Mini.rawValue), "background": .bool(true)], invocationContext: invocation())
        let closingID = try OracleGroupID(rawValue: XCTUnwrap(UUID(uuidString: XCTUnwrap(closing.objectValue?["oracle_group_id"]?.stringValue))))
        let closingOwner = try XCTUnwrap(session.oracleBackgroundOwner)
        window.beginClose()
        let closingDrain = try XCTUnwrap(session.oracleBackgroundDrain)
        await closingDrain.value
        XCTAssertTrue(registry.isDrained(closingOwner), "Window close joins accepted work before resource disposal")
        let closed = try await store.load(groupID: closingID, owner: canonicalOwner)
        XCTAssertEqual(closed?.turns.last?.state, .terminal)
        if let closed { try await store.delete(groupID: closingID, owner: canonicalOwner, expectedRevision: closed.revision) }
    }

    func testRegistryHandoffAndRequestCancellation() async throws {
        typealias Registry = OracleBackgroundInvocationRegistry
        for commitFirst in [false, true] {
            let latch = OracleBackgroundHandoff()
            if commitFirst {
                XCTAssertTrue(latch.commit())
                latch.abortPending()
                try await latch.waitForCommit()
                XCTAssertFalse(latch.isCancelled)
            } else {
                latch.abortPending()
                XCTAssertFalse(latch.commit())
                do { try await latch.waitForCommit()
                    XCTFail("Aborted gate must not dispatch")
                } catch { XCTAssertTrue(error is CancellationError) }
            }
        }
        for schedule in ["beforePrepared", "requestAtCommit", "stopAtCommit", "afterCommit"] {
            let registry = Registry()
            let owner = registryOwner()
            let preparation = OracleFoundationGate(), completion = OracleFoundationGate()
            defer { preparation.release()
                completion.release()
            }
            let entered = expectation(description: "worker entered")
            let dispatched = schedule == "afterCommit" ? expectation(description: "provider gate opened") : nil
            var currentRun = UUID()
            let creatingRun = currentRun
            var checks = 0, providerCalls = 0
            var request: Task<Registry.Reference, Error>?
            request = Task { @MainActor in
                try await OracleFoundationContext.$marker.withValue(1) {
                    try await registry.start(owner: owner, runID: creatingRun, invocationID: UUID(), admissionIsCurrent: {
                        checks += 1
                        if checks == 2, schedule == "requestAtCommit" { request?.cancel() }
                        if checks == 2, schedule == "stopAtCommit" { _ = registry.close(owner) }
                        return currentRun == creatingRun
                    }) { job in
                        XCTAssertNil(OracleFoundationContext.marker, "Worker must not inherit request task-local authority")
                        let document = try self.registryPrepared(job)
                        entered.fulfill()
                        if schedule == "beforePrepared" { await preparation.wait() }
                        try await job.prepared(document)
                        providerCalls += 1
                        let identity = Registry.QueryIdentity(sessionID: document.members[0].memberID.rawValue, queryID: UUID(), oracleGeneration: 1)
                        try job.registerQuery(laneIndex: 0, identity: identity, isCurrent: { $0 == identity }, cancel: { _ in })
                        job.recordLaneOutcome(.completed, laneIndex: 0, sequence: 1)
                        job.recordLaneOutcome(.failed, laneIndex: 0, sequence: 2)
                        dispatched?.fulfill()
                        await completion.wait()
                        try job.recordPublishedTurn(self.registryTerminal(document))
                    }
                }
            }
            await fulfillment(of: [entered], timeout: 2)
            if schedule == "beforePrepared" { request?.cancel()
                preparation.release()
            }
            let ownedRequest = try XCTUnwrap(request)
            let outcome = await ownedRequest.result
            if schedule == "afterCommit" {
                let reference = try outcome.get()
                currentRun = UUID()
                request?.cancel()
                let dispatchObserved = try XCTUnwrap(dispatched)
                await fulfillment(of: [dispatchObserved], timeout: 2)
                let live = try XCTUnwrap(registry.snapshot(for: owner).invocations.first)
                XCTAssertEqual(live.phase, .running)
                XCTAssertEqual(live.reference.provenance.agentRunID, creatingRun)
                XCTAssertEqual(live.laneOutcomes[0], .completed, "Progress must not regress a finalized lane")
                let generation = registry.awarenessVersion(for: owner).generation
                XCTAssertEqual(registry.snapshot(for: owner).generation, generation, "Collection is observational")
                completion.release()
                try await registry.join(owner: owner, reference: reference)
                XCTAssertEqual(registry.snapshot(for: owner).invocations.first?.phase, .settled)
                XCTAssertTrue(registry.snapshot(for: owner).invocations.first?.queries.isEmpty == true)
                XCTAssertEqual(providerCalls, 1)
            } else {
                if case let .failure(error) = outcome { XCTAssertTrue(error is CancellationError) }
                else { XCTFail("Uncommitted work must not return a receipt") }
                XCTAssertEqual(providerCalls, 0)
                XCTAssertTrue(registry.snapshot(for: owner).invocations.isEmpty)
            }
            completion.release()
            await registry.close(owner).value
        }
    }

    func testRegistryQueryCleanupAndOwnerFences() async throws {
        typealias Registry = OracleBackgroundInvocationRegistry
        let registry = Registry(), owner = registryOwner()
        let provider = OracleFoundationGate(), cleanup = OracleFoundationGate()
        defer { provider.release()
            cleanup.release()
        }
        let registered = expectation(description: "exact primary query registered")
        let cleaning = expectation(description: "retained exact cleanups entered")
        cleaning.expectedFulfillmentCount = 2
        var cleanupCalls = 0
        var cancelled: [UUID] = []
        var currentPrimary: UUID?
        var retainedJob: Registry.Job?
        let reference = try await registry.start(owner: owner, runID: UUID(), invocationID: UUID(), admissionIsCurrent: { true }) { job in
            retainedJob = job
            let document = try self.registryPrepared(job)
            try await job.prepared(document)
            let primary = Registry.QueryIdentity(sessionID: document.members[0].memberID.rawValue, queryID: UUID(), oracleGeneration: 1)
            currentPrimary = primary.queryID
            let cancel: @MainActor (Registry.QueryIdentity) async -> Void = { identity in
                cleanupCalls += 1
                cleaning.fulfill()
                await cleanup.wait()
                // Same exact-query fence used by the adapter's cleanupOwnerIsCurrent callback.
                if identity.sessionID != primary.sessionID || currentPrimary == identity.queryID { cancelled.append(identity.queryID) }
            }
            try job.registerQuery(laneIndex: 0, identity: primary, isCurrent: { $0 == primary }, cancel: cancel)
            job.recordLaneOutcome(.completed, laneIndex: 0, sequence: 1)
            registered.fulfill()
            await provider.wait()
            XCTAssertTrue(job.isCancellationRequested)
            let secondary = Registry.QueryIdentity(sessionID: document.members[1].memberID.rawValue, queryID: UUID(), oracleGeneration: 1)
            try job.registerQuery(laneIndex: 1, identity: secondary, isCurrent: { $0 == secondary }, cancel: cancel)
            try job.registerQuery(laneIndex: 1, identity: secondary, isCurrent: { _ in true }, cancel: cancel)
            await job.joinQueryCleanup(laneIndex: 0)
            await job.joinQueryCleanup(laneIndex: 1)
            try job.recordPublishedTurn(self.registryTerminal(document, cancelSecondary: true))
        }
        await fulfillment(of: [registered], timeout: 2)
        let successor = UUID()
        let conflicting = Registry.QueryIdentity(sessionID: reference.members[0].memberID.rawValue, queryID: successor, oracleGeneration: 2)
        XCTAssertThrowsError(try retainedJob?.registerQuery(laneIndex: 0, identity: conflicting, isCurrent: { _ in true }, cancel: { _ in XCTFail("Query registration must not replace its captured identity") }))
        let runningEpoch = registry.awarenessVersion(for: owner).epoch
        let drain = registry.close(owner)
        XCTAssertNotEqual(registry.awarenessVersion(for: owner).epoch, runningEpoch)
        XCTAssertTrue(registry.admissionIsClosed(for: owner))
        let stoppingGeneration = registry.awarenessVersion(for: owner).generation
        _ = registry.close(owner)
        XCTAssertTrue(try registry.cancel(owner: owner, reference: reference))
        XCTAssertEqual(registry.awarenessVersion(for: owner).generation, stoppingGeneration)
        XCTAssertThrowsError(try registry.reopen(owner, admissionIsCurrent: { true }))
        provider.release()
        await fulfillment(of: [cleaning], timeout: 2)
        XCTAssertEqual(cleanupCalls, 2, "Repeated Stop/cancel and repeated query registration must share cleanup")
        XCTAssertEqual(registry.snapshot(for: owner).invocations.first?.phase, .cancelling)
        let timedOut = await Registry.awaitDrain(drain, timeout: 0)
        XCTAssertFalse(timedOut, "A deadline releases the waiter, not retained cleanup ownership")
        XCTAssertTrue(registry.hasLiveOwner(owner))
        currentPrimary = successor
        let foreign = registryOwner()
        let sameSessionRebound = Registry.Owner(workspaceID: owner.workspaceID, binding: .init(tabID: owner.binding.tabID, sessionID: owner.binding.sessionID))
        XCTAssertTrue(registry.snapshot(for: sameSessionRebound).invocations.isEmpty, "A new binding cannot take live execution rights")
        XCTAssertThrowsError(try registry.cancel(owner: sameSessionRebound, reference: reference))
        XCTAssertTrue(registry.snapshot(for: foreign).invocations.isEmpty)
        XCTAssertThrowsError(try registry.cancel(owner: foreign, reference: reference))
        let rebound = Registry.Owner(workspaceID: owner.workspaceID, binding: .init(tabID: owner.binding.tabID, sessionID: UUID()))
        do {
            _ = try await registry.start(owner: rebound, runID: UUID(), invocationID: UUID(), admissionIsCurrent: { true }) { _ in XCTFail("Rebinding must wait for the old owner") }
            XCTFail("Expected busy drain fence")
        } catch { XCTAssertEqual(error as? Registry.RegistryError, .busy) }
        cleanup.release()
        await drain.value
        XCTAssertEqual(cancelled.count, 1, "Late cleanup must not touch the successor primary")
        XCTAssertFalse(cancelled.contains(successor))
        let terminal = try XCTUnwrap(registry.snapshot(for: owner).invocations.first)
        XCTAssertEqual(terminal.phase, .settled)
        XCTAssertEqual(terminal.laneOutcomes[0], .completed)
        XCTAssertEqual(terminal.laneOutcomes[1], .cancelled)
        XCTAssertFalse(try registry.cancel(owner: owner, reference: reference))
        XCTAssertEqual(registry.snapshot(for: sameSessionRebound).invocations.first?.reference, reference, "Settled discovery belongs to the persisted Agent session")
        XCTAssertFalse(try registry.cancel(owner: sameSessionRebound, reference: reference))
        let priorEpoch = registry.snapshot(for: owner).epoch
        try registry.reopen(owner, admissionIsCurrent: { true })
        XCTAssertNotEqual(registry.snapshot(for: owner).epoch, priorEpoch)
        let stale = Registry.QueryIdentity(sessionID: reference.members[0].memberID.rawValue, queryID: successor, oracleGeneration: 2)
        XCTAssertThrowsError(try retainedJob?.registerQuery(laneIndex: 0, identity: stale, isCurrent: { _ in true }, cancel: { _ in XCTFail("Stale job must not cancel a successor") }))
        await registry.close(sameSessionRebound).value
        try registry.remove(sameSessionRebound)
        XCTAssertTrue(registry.snapshot(for: owner).invocations.isEmpty)
        XCTAssertTrue(registry.snapshot(for: sameSessionRebound).invocations.isEmpty)
    }

    func testAwarenessReservationsHeadlessRetryAndReceiptFormatting() async throws {
        let fixture = try await AgentRunMCPControlledSessionContext.make(workspaceNamePrefix: "Oracle awareness", workspaceSwitchReason: "oracle awareness fixture", clientName: "oracle-awareness", unusedStartRunMessage: "No provider")
        addTeardownBlock { await fixture.cleanup() }
        let session = fixture.session, registry = OracleBackgroundInvocationRegistry(), awareness = session.oracleBackgroundAwareness
        session.installRunID(UUID())
        let owner = try OracleBackgroundInvocationRegistry.Owner(workspaceID: XCTUnwrap(fixture.window.workspaceManager.activeWorkspaceID), binding: XCTUnwrap(session.persistentSessionBindingIdentity))
        session.oracleBackgroundOwner = owner
        let provider = NSObject(), hold = OracleFoundationGate()
        defer { hold.release() }
        XCTAssertNil(awareness.reserve(session: session, providerID: ObjectIdentifier(provider), registry: registry), "Empty means zero bytes, not an empty separator")
        var job: OracleBackgroundInvocationRegistry.Job?
        let entered = expectation(description: "awareness lane registered")
        let reference = try await registry.start(owner: owner, runID: XCTUnwrap(session.runID), invocationID: UUID(), admissionIsCurrent: { true }) { active in
            job = active
            let document = try self.registryPrepared(active)
            try await active.prepared(document)
            try active.registerQuery(laneIndex: 0, identity: .init(sessionID: document.members[0].memberID.rawValue, queryID: UUID(), oracleGeneration: 1), isCurrent: { _ in true }, cancel: { _ in })
            entered.fulfill()
            await hold.wait()
            try active.recordPublishedTurn(self.registryTerminal(document))
        }
        await fulfillment(of: [entered], timeout: 2)
        func reserve() -> OracleBackgroundAwareness.Reservation? {
            awareness.reserve(session: session, providerID: ObjectIdentifier(provider), registry: registry)
        }
        let first = try XCTUnwrap(reserve())
        XCTAssertEqual(first.text, "Oracle: 1 open, 0 answers ready [g:\(reference.groupID.rawValue.uuidString)/t:\(reference.turnID.rawValue.uuidString)]")
        XCTAssertNil(reserve(), "Concurrent dispatch must not duplicate a generation")
        awareness.release(first)
        let retry = try XCTUnwrap(reserve())
        XCTAssertEqual(retry.text, first.text, "Failed dispatch leaves the supplement owed")
        job?.recordLaneOutcome(.completed, laneIndex: 0, sequence: 1)
        awareness.accept(retry, registry: registry)
        let changed = try XCTUnwrap(reserve())
        XCTAssertTrue(changed.text.contains("1 answers ready"), "A change during dispatch remains owed")
        awareness.accept(changed, registry: registry)
        XCTAssertNil(reserve())
        awareness.resetContext()
        let rebuilt = try XCTUnwrap(reserve())
        awareness.accept(changed, registry: registry)
        XCTAssertNil(reserve(), "A stale acceptance cannot release a successor reservation")
        awareness.accept(rebuilt, registry: registry)
        session.installRunID(UUID())
        let later = try XCTUnwrap(reserve())
        let drain = registry.close(owner)
        awareness.accept(later, registry: registry)
        XCTAssertNil(reserve(), "Stop withdraws the old recipient")
        hold.release()
        await drain.value
        let payload: Value = .object(["status": .string("running"), "oracle_group_id": .string(reference.groupID.rawValue.uuidString), "oracle_turn_id": .string(reference.turnID.rawValue.uuidString), "chat_id": .string(reference.members[0].publicChatID), "agent_session_id": .string(owner.binding.sessionID.uuidString), "agent_run_id": .string(reference.provenance.agentRunID.uuidString), "context_id": .string(owner.binding.tabID.uuidString), "backend": .string("app"), "lanes": .array([.object(["response": .string(String(repeating: "private answer", count: 1000))])])])
        let formatted = ToolOutputFormatter.formatAskOracle(args: [:], value: payload, emitResources: false).compactMap { content -> String? in if case let .text(text, _, _) = content { return text }
            return nil
        }.joined()
        XCTAssertTrue(formatted.contains(reference.groupID.rawValue.uuidString))
        XCTAssertTrue(formatted.contains(reference.turnID.rawValue.uuidString))
        let raw = try String(decoding: JSONEncoder().encode(payload), as: UTF8.self)
        let row = AgentChatItem(kind: .toolResult, text: raw, toolName: "ask_oracle", toolInvocationID: UUID(), toolResultJSON: raw, sequenceIndex: 0)
        XCTAssertEqual(AgentTranscriptToolNormalizer.status(for: row), .success, "Running job is a completed transport")
        let retained = try XCTUnwrap(AgentToolResultPersistencePolicy.sanitizedToolResult(for: row))
        let summary = try XCTUnwrap(retained.resultJSON)
        XCTAssertLessThanOrEqual(summary.utf8.count, 2048)
        for id in [reference.groupID.rawValue, reference.turnID.rawValue, owner.binding.sessionID, owner.binding.tabID, reference.provenance.agentRunID] {
            XCTAssertTrue(summary.contains(id.uuidString))
        }
        XCTAssertFalse(summary.contains("private answer"))
        session.oracleBackgroundOwner = nil

        // Exercise the actual app-headless physical send/acceptance calls, not a manual helper ack.
        let transport = AgentSessionLinkCapturingHeadlessProvider(failuresRemaining: 1)
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in transport })
        let recipient = try harness.makeBoundSession(agent: .openCode)
        let processRegistry = AppDomainRuntimeComposition.shared.oracleBackgroundInvocations
        let recipientOwner = try OracleBackgroundInvocationRegistry.Owner(workspaceID: XCTUnwrap(harness.host.workspaceManager?.activeWorkspaceID), binding: XCTUnwrap(recipient.persistentSessionBindingIdentity))
        recipient.oracleBackgroundOwner = recipientOwner
        let physicalHold = OracleFoundationGate()
        defer { physicalHold.release() }
        let physicalReference = try await processRegistry.start(owner: recipientOwner, runID: UUID(), invocationID: UUID(), admissionIsCurrent: { true }) { job in
            let document = try self.registryPrepared(job)
            try await job.prepared(document)
            await physicalHold.wait()
            try job.recordPublishedTurn(self.registryTerminal(document))
        }
        let runner = harness.makeHeadlessRunner()
        for accepted in [false, true] {
            recipient.runState = .idle
            var physicalProviderID: ObjectIdentifier?
            var physicalRunID: UUID?
            await runner.startRun(tabID: recipient.tabID, session: recipient, initialUserMessage: "ordinary input", initialMessageForRun: "ordinary input", attachments: [], makeLease: { runID in
                let lease = harness.makeLease(runID: runID, tabID: recipient.tabID)
                physicalProviderID = ObjectIdentifier(lease)
                physicalRunID = runID
                return lease
            })
            await recipient.agentTask?.value
            // Failed terminal cleanup clears runID. Inspect the exact dispatched context, not
            // the empty recipient or a newly minted context that would re-owe either outcome.
            try recipient.installRunID(XCTUnwrap(physicalRunID))
            let pending = try recipient.oracleBackgroundAwareness.reserve(session: recipient, providerID: XCTUnwrap(physicalProviderID))
            if accepted { XCTAssertNil(pending, "Successful physical stream creation acknowledges the snapshot") }
            else { XCTAssertNotNil(pending, "Throwing physical stream creation leaves awareness owed") }
            recipient.oracleBackgroundAwareness.release(pending)
        }
        let sent = await transport.messages
        XCTAssertEqual(sent.count, 2)
        for message in sent {
            XCTAssertEqual(message.userMessage.components(separatedBy: "Oracle: ").count, 2)
            XCTAssertTrue(message.userMessage.contains(physicalReference.groupID.rawValue.uuidString))
            XCTAssertTrue(message.userMessage.contains(physicalReference.turnID.rawValue.uuidString))
        }
        physicalHold.release()
        try await processRegistry.join(owner: recipientOwner, reference: physicalReference)
        XCTAssertFalse(processRegistry.admissionIsClosed(for: recipientOwner), "Natural settlement never needed Stop")
        XCTAssertFalse(processRegistry.isDrained(recipientOwner))
        let reboundID = UUID()
        let rebound = try XCTUnwrap(harness.host.test_installPersistentSessionBinding(sessionID: reboundID, on: recipient, updateWorkspaceMetadata: true))
        XCTAssertEqual(rebound.sessionID, reboundID, "The first synchronous bind after natural settlement must succeed")
        XCTAssertTrue(processRegistry.isDrained(recipientOwner), "An empty close is drained synchronously")
        XCTAssertNil(recipient.oracleBackgroundOwner)
        XCTAssertNil(recipient.oracleBackgroundDrain)
        try processRegistry.remove(recipientOwner)
    }

    func testRegistryActiveAndRetentionBounds() async throws {
        typealias Registry = OracleBackgroundInvocationRegistry
        var clock = 0
        let registry = Registry(now: { clock += 1
            return Date(timeIntervalSince1970: Double(clock))
        })
        let owner = registryOwner()
        let hold = OracleFoundationGate(), preparing = OracleFoundationGate()
        defer { hold.release()
            preparing.release()
        }
        let reservations = expectation(description: "four preparing reservations")
        reservations.expectedFulfillmentCount = 4
        var requests: [Task<Registry.Reference, Error>] = []
        for _ in 0 ..< 4 {
            requests.append(Task { @MainActor in
                try await registry.start(owner: owner, runID: UUID(), invocationID: UUID(), admissionIsCurrent: { true }) { job in
                    reservations.fulfill()
                    await preparing.wait()
                    let document = try self.registryPrepared(job)
                    try await job.prepared(document)
                    await hold.wait()
                    try job.recordPublishedTurn(self.registryTerminal(document))
                }
            })
        }
        await fulfillment(of: [reservations], timeout: 2)
        do {
            _ = try await registry.start(owner: owner, runID: UUID(), invocationID: UUID(), admissionIsCurrent: { true }) { _ in XCTFail("Over-cap start must not launch") }
            XCTFail("Expected active cap")
        } catch { XCTAssertEqual(error as? Registry.RegistryError, .limit) }
        preparing.release()
        var active: [Registry.Reference] = []
        for request in requests {
            try await active.append(request.value)
        }
        XCTAssertEqual(registry.snapshot(for: owner, includeFinished: false).invocations.count, 4)
        hold.release()
        for reference in active {
            try await registry.join(owner: owner, reference: reference)
        }
        let complete: @MainActor @Sendable (Registry.Job) async throws -> Void = { job in
            let document = try self.registryPrepared(job)
            try await job.prepared(document)
            try job.recordPublishedTurn(self.registryTerminal(document))
        }
        for _ in 0 ..< 65 {
            let reference = try await registry.start(owner: owner, runID: UUID(), invocationID: UUID(), admissionIsCurrent: { true }, operation: complete)
            try await registry.join(owner: owner, reference: reference)
        }
        let retained = registry.snapshot(for: owner)
        XCTAssertEqual(retained.invocations.count, 64)
        XCTAssertTrue(retained.historyTruncated)
        XCTAssertFalse(retained.invocations.contains { $0.reference == active[0] })
        let pin = OracleFoundationGate()
        defer { pin.release() }
        let pinned = try await registry.start(owner: owner, runID: UUID(), invocationID: UUID(), admissionIsCurrent: { true }) { job in
            let document = try self.registryPrepared(job)
            try await job.prepared(document)
            try job.recordPublishedTurn(self.registryTerminal(document))
            await pin.wait()
        }
        var owners = [owner]
        for _ in 0 ..< 4 {
            let another = registryOwner()
            owners.append(another)
            for _ in 0 ..< 64 {
                let reference = try await registry.start(owner: another, runID: UUID(), invocationID: UUID(), admissionIsCurrent: { true }, operation: complete)
                try await registry.join(owner: another, reference: reference)
            }
        }
        let total = owners.flatMap { registry.snapshot(for: $0).invocations }
        XCTAssertEqual(total.count(where: { !$0.phase.isLive }), 256)
        XCTAssertTrue(total.contains { $0.reference == pinned && $0.phase.isLive }, "Live execution must not be evicted")
        XCTAssertTrue(registry.snapshot(for: owner).historyTruncated)
        let finalDrain = registry.close(owner)
        pin.release()
        await finalDrain.value
    }

    func testRegistryAwarenessRemainsBoundedAtOwnerAndRetentionCaps() async throws {
        typealias Registry = OracleBackgroundInvocationRegistry
        typealias Fixture = (registry: Registry, owner: Registry.Owner, session: AgentTabSession, text: String)
        let iterations = 1000
        let provider = NSObject()
        let providerID = ObjectIdentifier(provider)

        func session(for owner: Registry.Owner) -> AgentTabSession {
            let session = AgentTabSession(tabID: owner.binding.tabID)
            session.installPersistentSessionBinding(owner.binding)
            session.installRunID(UUID())
            session.oracleBackgroundOwner = owner
            return session
        }

        func fixture(ownerCount: Int) async throws -> Fixture {
            var tick = 0
            let registry = Registry(now: { tick += 1
                return Date(timeIntervalSince1970: Double(tick))
            })
            let owners = (0 ..< ownerCount).map { _ in self.registryOwner() }
            let target = owners[ownerCount / 2]
            let hold = OracleFoundationGate()
            addTeardownBlock { @MainActor in
                hold.release()
                await registry.closeAll().value
            }
            let complete: @MainActor @Sendable (Registry.Job) async throws -> Void = { job in
                let document = try self.registryPrepared(job)
                try await job.prepared(document)
                try job.recordPublishedTurn(self.registryTerminal(document))
            }
            // Overflow the target's session cap first, then fill the process retention cap.
            for owner in [target] + owners.filter({ $0 != target }).prefix(3) {
                for _ in 0 ..< (Registry.inactiveSessionLimit + (owner == target ? 1 : 0)) {
                    let reference = try await registry.start(owner: owner, runID: UUID(), invocationID: UUID(), admissionIsCurrent: { true }, operation: complete)
                    try await registry.join(owner: owner, reference: reference)
                }
            }
            for owner in owners {
                for _ in 0 ..< Registry.activeLimit {
                    _ = try await registry.start(owner: owner, runID: UUID(), invocationID: UUID(), admissionIsCurrent: { true }) { job in
                        let document = try self.registryPrepared(job)
                        try await job.prepared(document)
                        await hold.wait()
                        try job.recordPublishedTurn(self.registryTerminal(document))
                    }
                }
            }
            let snapshots = owners.map { registry.snapshot(for: $0) }
            XCTAssertEqual(Set(owners).count, ownerCount)
            XCTAssertEqual(snapshots.count(where: { $0.epoch != nil }), ownerCount)
            XCTAssertTrue(snapshots.allSatisfy { $0.invocations.count(where: { $0.phase.isLive }) == Registry.activeLimit })
            XCTAssertEqual(snapshots.flatMap(\.invocations).count(where: { !$0.phase.isLive }), min(Registry.inactiveProcessLimit, ownerCount * Registry.inactiveSessionLimit))
            XCTAssertTrue(snapshots.allSatisfy { $0.invocations.count(where: { !$0.phase.isLive }) <= Registry.inactiveSessionLimit })
            let targetSnapshot = registry.snapshot(for: target)
            XCTAssertEqual(targetSnapshot.invocations.count(where: { !$0.phase.isLive }), Registry.inactiveSessionLimit)
            XCTAssertTrue(targetSnapshot.historyTruncated)
            XCTAssertEqual(snapshots.count(where: \.historyTruncated), 1)
            let counts = ["owners": ownerCount, "registeredOwners": snapshots.count(where: { $0.epoch != nil }), "active": snapshots.flatMap(\.invocations).count(where: { $0.phase.isLive }), "inactive": snapshots.flatMap(\.invocations).count(where: { !$0.phase.isLive }), "targetInactive": targetSnapshot.invocations.count(where: { !$0.phase.isLive }), "truncatedOwners": snapshots.count(where: \.historyTruncated)]
            let fixtureData = try JSONSerialization.data(withJSONObject: counts, options: [.sortedKeys])
            print("ORACLE_REGISTRY_SCALE_FIXTURE \(String(decoding: fixtureData, as: UTF8.self))")
            do {
                _ = try await registry.start(owner: target, runID: UUID(), invocationID: UUID(), admissionIsCurrent: { true }) { _ in
                    XCTFail("A fifth active invocation must not launch")
                }
                XCTFail("Expected the active-session cap")
            } catch {
                XCTAssertEqual(error as? Registry.RegistryError, .limit)
            }
            let emptyOwner = registryOwner()
            let empty = OracleBackgroundAwareness().reserve(session: session(for: emptyOwner), providerID: providerID, registry: registry)
            XCTAssertNil(empty)
            XCTAssertEqual((empty?.text ?? "").utf8.count, 0)
            XCTAssertNil(registry.awarenessVersion(for: emptyOwner).epoch, "An empty lookup must not create an owner")
            let reference = try XCTUnwrap(registry.snapshot(for: target, includeFinished: false).invocations.last?.reference)
            let text = "Oracle: 4 open, 0 answers ready [g:\(reference.groupID.rawValue.uuidString)/t:\(reference.turnID.rawValue.uuidString); +3]"
            let targetSession = session(for: target)
            let awareness = OracleBackgroundAwareness()
            let reservation = try XCTUnwrap(awareness.reserve(session: targetSession, providerID: providerID, registry: registry))
            XCTAssertEqual(reservation.text, text)
            awareness.release(reservation)
            return (registry, target, targetSession, text)
        }

        func sample(expected: Int, operation: () -> Int) -> Double {
            var consumed = 0
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0 ..< iterations {
                consumed += operation()
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            XCTAssertEqual(consumed, expected * iterations)
            return Double(elapsed) / Double(iterations)
        }

        func measure(_ fixture: Fixture) throws -> [String: Double] {
            let registry = fixture.registry, owner = fixture.owner
            let version = registry.awarenessVersion(for: owner)
            XCTAssertNotNil(version.epoch)
            XCTAssertFalse(registry.admissionIsClosed(for: owner))
            let awareness = OracleBackgroundAwareness()
            let primed = try XCTUnwrap(awareness.reserve(session: fixture.session, providerID: providerID, registry: registry))
            XCTAssertEqual(primed.text, fixture.text)
            awareness.release(primed)
            let bytes = fixture.text.utf8.count
            let timings = [
                "awarenessVersion_ns": sample(expected: Int(version.generation)) {
                    Int(registry.awarenessVersion(for: owner).generation)
                },
                "admissionIsClosed_ns": sample(expected: 0) {
                    registry.admissionIsClosed(for: owner) ? 1 : 0
                },
                "warmReserveRelease_ns": sample(expected: bytes) {
                    let reservation = awareness.reserve(session: fixture.session, providerID: providerID, registry: registry)
                    awareness.release(reservation)
                    return reservation?.text.utf8.count ?? 0
                },
                "coldReserveRelease_ns": sample(expected: bytes) {
                    let fresh = OracleBackgroundAwareness()
                    let reservation = fresh.reserve(session: fixture.session, providerID: providerID, registry: registry)
                    fresh.release(reservation)
                    return reservation?.text.utf8.count ?? 0
                }
            ]
            XCTAssertEqual(registry.awarenessVersion(for: owner).generation, version.generation, "Samples must not mutate the target")
            return timings
        }

        let small = try await fixture(ownerCount: 3)
        let large = try await fixture(ownerCount: 300)
        var samples: [Int: [[String: Double]]] = [3: [], 300: []]
        // Alternate order; five independent 1,000-call batches avoid a ratio on one tiny lookup.
        for round in 0 ..< 5 {
            for count in round.isMultiple(of: 2) ? [3, 300] : [300, 3] {
                let timings = try measure(count == 3 ? small : large)
                samples[count, default: []].append(timings)
                let data = try JSONSerialization.data(withJSONObject: ["round": round, "owners": count, "iterations": iterations, "ns_per_call": timings], options: [.sortedKeys])
                print("ORACLE_REGISTRY_SCALE \(String(decoding: data, as: UTF8.self))")
            }
        }
        func median(ownerCount: Int, path: String) throws -> Double {
            let values = try XCTUnwrap(samples[ownerCount]).compactMap { $0[path] }.sorted()
            XCTAssertEqual(values.count, 5)
            return try XCTUnwrap(values.dropFirst(values.count / 2).first)
        }
        // Calibration: warm reserve/release peaked at 2.74 us; round 5x up to 20 us.
        // Lookup batches were 0.24–0.46 us/call: a 1 us floor avoids a noisy tiny ratio.
        for path in ["awarenessVersion_ns", "admissionIsClosed_ns", "warmReserveRelease_ns"] {
            let smallMedian = try median(ownerCount: 3, path: path)
            let largeMedian = try median(ownerCount: 300, path: path)
            XCTAssertLessThanOrEqual(largeMedian, max(smallMedian * 4, 1000), "Warm owner lookup must stay within a small multiple: \(path)")
            XCTAssertLessThanOrEqual(largeMedian, 20000, "Warm owner lookup exceeded its calibrated absolute budget: \(path)")
        }
        let cold = try XCTUnwrap(samples[300]?.compactMap { $0["coldReserveRelease_ns"] }.max())
        XCTAssertLessThanOrEqual(cold, 1_000_000, "Cold awareness must consume at most 1 ms of a 16 ms main-actor frame")
    }

    private func registryOwner() -> OracleBackgroundInvocationRegistry.Owner {
        .init(workspaceID: UUID(), binding: .init(tabID: UUID(), sessionID: UUID()))
    }

    private func registryPrepared(_ job: OracleBackgroundInvocationRegistry.Job) throws -> OracleGroupDocument {
        let models = try ["primary", "secondary"].map { try OracleModelReference(providerID: "fixture", modelID: $0) }
        let members = try models.enumerated().map { index, model in
            try OracleGroupMember(laneID: .init(index: index), publicChatID: "fixture-\(UUID().uuidString)", model: model)
        }
        return try OracleGroupDocument(
            group: .init(size: 2), owner: OracleViewModel.oracleGroupOwner(workspaceID: job.owner.workspaceID, tabID: job.owner.binding.tabID),
            name: "fixture", revision: 1, createdAt: Date(timeIntervalSince1970: 1000), updatedAt: Date(timeIntervalSince1970: 1000),
            roster: .init(primary: models[0], additional: [models[1]]), members: members,
            turns: [.init(input: OracleInput(mode: .chat, userMessage: "fixture"), state: .prepared, startedAt: Date(timeIntervalSince1970: 1000), backgroundExecution: job.provenance)]
        )
    }

    private func registryTerminal(_ document: OracleGroupDocument, cancelSecondary: Bool = false) throws -> OracleGroupDocument {
        let results = try document.members.map { member in
            try OracleLaneResult(
                laneIndex: member.laneID.index, chatID: member.publicChatID, providerID: member.model.providerID, modelID: member.model.modelID,
                status: cancelSecondary && member.laneID.index == 1 ? .cancelled : .completed,
                response: cancelSecondary && member.laneID.index == 1 ? nil : "answer",
                error: cancelSecondary && member.laneID.index == 1 ? OracleLaneError(code: "cancelled", message: "fixture") : nil
            )
        }
        return try document.settling(.init(groupID: document.group.id, status: cancelSecondary ? .partialFailure : .completed, oracleResults: results))
    }

    private func makeTabContext(workspaceID: UUID, tabID: UUID) -> OracleViewModel.OracleSendTabContext {
        OracleViewModel.OracleSendTabContext(
            tabID: tabID,
            workspaceID: workspaceID,
            activationPolicy: .background,
            packaging: OracleViewModel.OracleSendPackagingContext(
                sourceTabID: tabID,
                sourceWorkspaceID: workspaceID,
                sourceSelectionRevision: 0,
                sourceAgentSessionID: nil,
                sourceAgentRunID: nil,
                promptText: "",
                selection: StoredSelection(),
                lookupContext: nil,
                reviewGitContext: .automaticOnly(),
                provenance: .direct
            )
        )
    }
}
