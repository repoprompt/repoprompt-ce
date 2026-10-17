import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import XCTest

@MainActor
final class OraclePresetExecutionTests: XCTestCase {
    #if DEBUG
        func testTicketImplicitGroupContinuationKeepsCapturedGroupAfterSelectionChanges() async throws {
            try await withTicketRoutingFixture { driver, service, invocation in
                let oracle = driver.window.oracleViewModel
                var models: [AIModel] = []
                oracle.setOraclePostPackagingTransportOverrideForTesting { _, model in
                    models.append(model)
                    let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                        continuation.yield(.init(text: "controlled answer", reasoning: nil, tokens: .init(), terminalOutcome: .completed))
                        continuation.finish()
                    }
                    return (UUID(), stream)
                }
                let initial = try await service.executeOracleSend(args: ["message": .string("Create original group"), "new_chat": .bool(true)], invocationContext: invocation)
                let groupID = try XCTUnwrap(initial.objectValue?["oracle_group_id"]?.stringValue)
                await oracle.drainTrackedAutosaves(for: driver.fixture.workspace.id)
                let projections = oracle.sessions.filter { $0.oracleGroupID?.uuidString == groupID }
                var original: [ChatSession] = []
                for projection in projections {
                    try await original.append(oracle.chatData.loadChatSession(from: XCTUnwrap(projection.fileURL)))
                }
                XCTAssertEqual(original.count, 2)
                try driver.manager.setActiveChatSessionID(XCTUnwrap(original.first?.id), forTabID: driver.tabID)
                models = []
                var alternateID: UUID?
                service.jobCenter.admissionDidRegister = { _ in
                    do {
                        let alternate = try await oracle.createSession(named: "Unrelated selected chat", tabID: driver.tabID, activateInUI: false)
                        alternateID = alternate.id
                        driver.manager.setActiveChatSessionID(alternate.id, forTabID: driver.tabID)
                    } catch {
                        XCTFail("Failed to change selection: \(error)")
                    }
                }
                defer { service.jobCenter.admissionDidRegister = nil }
                let continued = try await service.executeOracleSend(args: [
                    "op": .string("start"), "timeout": .int(5), "message": .string("Continue captured group")
                ], invocationContext: invocation)
                XCTAssertEqual(continued.objectValue?["oracle_group_id"]?.stringValue, groupID)
                XCTAssertEqual(continued.objectValue?["oracle_count"]?.intValue, 2)
                XCTAssertEqual(Set(models), Set([.gpt54Mini, .gpt54]))
                XCTAssertEqual(models.count, 2)
                await oracle.drainTrackedAutosaves(for: driver.fixture.workspace.id)
                for session in original {
                    let continuedSession = try await oracle.chatData.loadChatSession(from: XCTUnwrap(session.fileURL))
                    XCTAssertEqual(continuedSession.messages.count, session.messages.count + 2)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .sortedKeys
                    XCTAssertEqual(try encoder.encode(Array(continuedSession.messages.prefix(session.messages.count))), try encoder.encode(session.messages))
                    XCTAssertEqual(continuedSession.name, session.name)
                }
                XCTAssertTrue(try XCTUnwrap(oracle.sessions.first { $0.id == alternateID }).messages.isEmpty)
            }
        }

        func testBothTicketProducersFreezeEmittedRosterAndMappedPromptAtAdmission() async throws {
            for ask in [false, true] {
                try await withTicketRoutingFixture { driver, service, invocation in
                    let promptVM = driver.window.promptManager
                    let oracle = driver.window.oracleViewModel
                    let oldID = UUID(), changedID = UUID()
                    let marker = "CAPTURED TICKET PROMPT"
                    promptVM.storedPrompts.append(.init(id: oldID, title: "Captured", content: marker))
                    promptVM.storedPrompts.append(.init(id: changedID, title: "Changed", content: "POST ADMISSION PROMPT"))
                    let capturedPrompt = ChatPreset(name: "Captured ticket review", mode: .review, gitInclusion: GitInclusion.none, storedPromptIds: [oldID], useStoredPromptsAsSystem: true)
                    let changedPrompt = ChatPreset(name: "Changed ticket review", mode: .review, gitInclusion: GitInclusion.none, storedPromptIds: [changedID], useStoredPromptsAsSystem: true)
                    ChatPresetManager.shared.add(capturedPrompt)
                    ChatPresetManager.shared.add(changedPrompt)
                    defer {
                        ChatPresetManager.shared.remove(capturedPrompt)
                        ChatPresetManager.shared.remove(changedPrompt)
                    }
                    let preset = try ModelPreset(name: "Captured ticket roster", models: [.gpt54Mini, .gpt54], chatPresetMappings: .init(reviewPresetID: capturedPrompt.id))
                    ModelPresetsManager.shared.presets = [preset]
                    GlobalSettingsStore.shared.setMCPShowModelPresets(true, commit: false)
                    var messages: [AIMessage] = []
                    var models: [AIModel] = []
                    oracle.setOraclePostPackagingTransportOverrideForTesting { message, model in
                        messages.append(message)
                        models.append(model)
                        let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                            continuation.yield(.init(text: "controlled answer", reasoning: nil, tokens: .init(), terminalOutcome: .completed))
                            continuation.finish()
                        }
                        return (UUID(), stream)
                    }
                    let changedPreset = try ModelPreset(id: preset.id, name: preset.name, model: .gpt54, chatPresetMappings: .init(reviewPresetID: changedPrompt.id))
                    service.jobCenter.admissionDidRegister = { _ in
                        ModelPresetsManager.shared.presets = [changedPreset]
                    }
                    defer { service.jobCenter.admissionDidRegister = nil }
                    var args: [String: Value] = ["message": .string("Frozen authority"), "mode": .string("review"), "new_chat": .bool(true)]
                    if !ask { args["model"] = .string(preset.name) }
                    let startArgs = args.merging(["op": .string("start"), "timeout": .int(5)]) { _, new in new }
                    let ticket = try await (ask ? service.executeAskOracle(args: startArgs, invocationContext: invocation) : service.executeOracleSend(args: startArgs, invocationContext: invocation))
                    XCTAssertEqual(ticket.objectValue?["job"]?.objectValue?["status"]?.stringValue, "completed")
                    XCTAssertEqual(ticket.objectValue?["oracle_count"]?.intValue, 2)
                    XCTAssertEqual(Set(models), Set([.gpt54Mini, .gpt54]))
                    XCTAssertEqual(messages.count, 2)
                    XCTAssertTrue(messages.allSatisfy { $0.systemPrompt.contains(marker) && !$0.systemPrompt.contains("POST ADMISSION PROMPT") })

                    // Capture is request-local: a subsequent ordinary start must use changed settings.
                    service.jobCenter.admissionDidRegister = nil
                    models = []
                    messages = []
                    _ = try await (ask ? service.executeAskOracle(args: args, invocationContext: invocation) : service.executeOracleSend(args: args, invocationContext: invocation))
                    XCTAssertEqual(models, [.gpt54])
                    XCTAssertTrue(try XCTUnwrap(messages.first).systemPrompt.contains("POST ADMISSION PROMPT"))
                }
            }
        }

        private func withTicketRoutingFixture(
            _ body: @escaping @MainActor (ContextBuilderMultiRootDiscoveryDriver, MCPOracleToolService, ToolInvocationContext) async throws -> Void
        ) async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: ["Ticket"]) { driver in
                let settings = GlobalSettingsStore.shared
                let previousPresets = ModelPresetsManager.shared.presets
                let previousExposure = settings.mcpShowModelPresets()
                let previousDisabled = settings.mcpTemporarilyDisablePresets()
                defer {
                    ModelPresetsManager.shared.presets = previousPresets
                    settings.setMCPShowModelPresets(previousExposure, commit: false)
                    settings.setMCPTemporarilyDisablePresets(previousDisabled, commit: false)
                    driver.window.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting(nil)
                }
                settings.setMCPShowModelPresets(false, commit: false)
                settings.setMCPTemporarilyDisablePresets(false, commit: false)
                settings.setWorkspaceAgentModelsProfile(workspaceID: driver.fixture.workspace.id, profile: .init(planningModelRaw: AIModel.gpt54Mini.rawValue, additionalOracleModelRaws: [AIModel.gpt54.rawValue]))
                driver.window.apiSettingsViewModel.openAIApiKey = "test-key"
                driver.window.apiSettingsViewModel.isOpenAIKeyValid = true
                let context = MCPTabContextSnapshot(tabID: driver.tabID, windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id, promptText: "", selection: StoredSelection(), selectedMetaPromptIDs: [], tabName: "Ticket", runID: nil, frozenLookupContext: .visibleWorkspace, explicitlyBound: true)
                let connectionID = UUID()
                let invocation = ToolInvocationContext.trustedLocal(toolName: "oracle_send", metadata: MCPRequestMetadata(connectionID: connectionID, clientName: "ticket-routing-fixture", windowID: driver.window.windowID))
                let service = MCPOracleToolService(
                    askOracleToolName: "ask_oracle", oracleSendToolName: "oracle_send", oracleChatLogToolName: "oracle_chat_log",
                    promptVM: driver.window.promptManager, oracleVM: driver.window.oracleViewModel,
                    liveRunPurpose: { _ in .unknown }, resolveTabContextSnapshot: { _ in .init(snapshot: context) },
                    requireCurrentTabContext: { _ in context }, stabilizedVirtualContext: { $0 },
                    resolveDelegatedReviewPackaging: { _, _, _, _ in nil }, rebindChatSessionIfNeeded: { _, _ in XCTFail("Fresh/implicit requests must not rebind") },
                    resolveTabIDForAgentMode: { _, _ in driver.tabID }, requireTargetWindow: { driver.window }, rawExplicitTabID: { _ in nil },
                    sendStageProgress: { _, _, _, _ in }, withHeartbeat: { _, _, _, _, operation in try await operation() },
                    resolveStartExecution: { mode, model, workspaceID in
                        try driver.window.oracleViewModel.resolveMCPFollowUpExecution(mode: mode, modelParam: model, workspaceID: workspaceID)
                    },
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
    #endif

    func testSchema1ReviewPresetOverridesConflictingAgentRosterAndUsesMappedPrompt() async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -9321,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OraclePresetExecutionTests-\(UUID().uuidString)", isDirectory: true)
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
        composition.promptManager.preferredModel = AIModel.gpt54.rawValue
        composition.promptManager.selectedChatPresetID = ChatPreset.BuiltIn.chat.id

        let promptID = UUID()
        let promptMarker = "CUSTOM REVIEW PRESET MARKER"
        composition.promptManager.storedPrompts.append(
            StoredPromptRecord(id: promptID, title: "[Custom Review]", content: promptMarker)
        )
        let chatPreset = ChatPreset(
            name: "Custom Review",
            mode: .review,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
            gitInclusion: GitInclusion.none,
            storedPromptIds: [promptID],
            useStoredPromptsAsSystem: true
        )
        let migratedPreset = try loadSchema1ReviewPreset(
            directory: root,
            model: AIModel.gpt54Mini,
            chatPresetID: chatPreset.id
        )
        let profile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54.rawValue,
            additionalOracleModelRaws: [AIModel.gpt54.rawValue]
        )
        let snapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: profile,
            modelPresets: [migratedPreset],
            modelPresetsExposed: true,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all() + [chatPreset],
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
        var capturedMessages: [AIMessage] = []
        var capturedModels: [AIModel] = []
        composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { message, model in
            capturedMessages.append(message)
            capturedModels.append(model)
            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                continuation.yield(
                    ChatStreamOutput(text: "36", reasoning: nil, tokens: ChatTokenInfo(), terminalOutcome: .completed)
                )
                continuation.finish()
            }
            return (UUID(), stream)
        }

        let invalidPreset = try ModelPreset(
            name: "Unavailable",
            modelStrings: [AIModel.gpt54Mini.rawValue, "missing-model"]
        )
        let invalidSnapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: profile,
            modelPresets: [invalidPreset],
            modelPresetsExposed: true,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all(),
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
        let sessionsBeforePreflight = composition.oracleViewModel.sessions.map(\.id)
        do {
            _ = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
                args: [
                    "message": .string("Must not dispatch"),
                    "mode": .string("review"),
                    "model": .string(invalidPreset.name),
                    "new_chat": .bool(true)
                ],
                promptVM: composition.promptManager,
                tabContext: makeTabContext(workspaceID: workspace.id, tabID: tab.id),
                capturedProfile: profile,
                selectionSnapshotOverride: invalidSnapshot
            )
            XCTFail("Expected whole-roster preflight failure")
        } catch let error as ChatToolError {
            XCTAssertEqual(error.code, .invalidParams)
            XCTAssertTrue(error.message.contains("lane 2"))
        }
        XCTAssertTrue(capturedMessages.isEmpty)
        XCTAssertEqual(composition.oracleViewModel.sessions.map(\.id), sessionsBeforePreflight)

        let result = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Test: reply '36'"),
                "mode": .string("review"),
                "model": .string("Review-2"),
                "new_chat": .bool(true)
            ],
            promptVM: composition.promptManager,
            tabContext: makeTabContext(workspaceID: workspace.id, tabID: tab.id),
            capturedProfile: profile,
            selectionSnapshotOverride: snapshot
        )

        XCTAssertEqual(result["response"]?.stringValue, "36")
        XCTAssertEqual(capturedModels, [.gpt54Mini])
        XCTAssertEqual(capturedMessages.count, 1)
        XCTAssertTrue(try XCTUnwrap(capturedMessages.first).systemPrompt.contains(promptMarker))
        XCTAssertTrue(composition.oracleViewModel.sessions.allSatisfy { $0.oracleGroupID == nil })
        let session = try XCTUnwrap(
            composition.oracleViewModel.sessions.first(where: { $0.selectedChatPresetID == chatPreset.id })
        )
        XCTAssertEqual(session.preferredAIModel, AIModel.gpt54Mini.rawValue)
        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
        let savedSession = try XCTUnwrap(
            composition.oracleViewModel.sessions.first(where: { $0.id == session.id })
        )
        let savedURL = try XCTUnwrap(savedSession.fileURL)
        let persistedSession = try await composition.oracleViewModel.chatData.loadChatSession(from: savedURL)
        XCTAssertEqual(persistedSession.preferredAIModel, AIModel.gpt54Mini.rawValue)
        XCTAssertEqual(persistedSession.selectedChatPresetID, chatPreset.id)

        let chatID = try XCTUnwrap(result["chat_id"]?.stringValue)
        let changedProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54.rawValue,
            additionalOracleModelRaws: [AIModel.gpt54.rawValue]
        )
        let continuationSnapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: changedProfile,
            modelPresets: [],
            modelPresetsExposed: false,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all() + [chatPreset],
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
        composition.oracleViewModel.purgeSessionStorage(session.id)
        composition.oracleViewModel.sessions = []
        composition.oracleViewModel.currentSessionID = nil
        let continuedByShortID = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Continue by short ID"),
                "mode": .string("review"),
                "chat_id": .string(chatID)
            ],
            promptVM: composition.promptManager,
            tabContext: makeTabContext(workspaceID: workspace.id, tabID: tab.id),
            capturedProfile: changedProfile,
            selectionSnapshotOverride: continuationSnapshot
        )
        XCTAssertNil(continuedByShortID["oracle_group_id"])
        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)

        composition.oracleViewModel.purgeSessionStorage(session.id)
        composition.oracleViewModel.sessions = []
        composition.oracleViewModel.currentSessionID = nil
        let continuedByUUID = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Continue by UUID"),
                "mode": .string("review"),
                "chat_id": .string(session.id.uuidString)
            ],
            promptVM: composition.promptManager,
            tabContext: makeTabContext(workspaceID: workspace.id, tabID: tab.id),
            capturedProfile: changedProfile,
            selectionSnapshotOverride: continuationSnapshot
        )
        XCTAssertNil(continuedByUUID["oracle_group_id"])
        XCTAssertEqual(capturedModels, [.gpt54Mini, .gpt54Mini, .gpt54Mini])
        XCTAssertEqual(capturedMessages.count, 3)
        XCTAssertTrue(capturedMessages.allSatisfy { $0.systemPrompt.contains(promptMarker) })
    }

    func testUnmarkedLegacySingleSessionUpgradesAndFreezesResolvedExecutionAuthority() async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -9324,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OracleLegacyPresetExecutionTests-\(UUID().uuidString)", isDirectory: true)
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

        let promptID = UUID()
        let promptMarker = "LEGACY SINGLE REVIEW MARKER"
        composition.promptManager.storedPrompts.append(
            StoredPromptRecord(id: promptID, title: "[Legacy Review]", content: promptMarker)
        )
        let reviewPreset = ChatPreset(
            name: "Legacy Review",
            mode: .review,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
            gitInclusion: GitInclusion.none,
            storedPromptIds: [promptID],
            useStoredPromptsAsSystem: true
        )
        let modelPreset = try ModelPreset(
            name: "Legacy Automatic Review",
            modelStrings: [AIModel.gpt54Mini.rawValue],
            chatPresetMappings: ChatPresetMappings(reviewPresetID: reviewPreset.id)
        )
        let profile = AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt54.rawValue)
        let legacySnapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: profile,
            modelPresets: [modelPreset],
            modelPresetsExposed: true,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all() + [reviewPreset],
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
        let legacySession = ChatSession(
            workspaceID: workspace.id,
            composeTabID: tab.id,
            name: "Legacy single",
            messages: [
                StoredMessage(isUser: true, rawText: "Earlier question", timestamp: Date(timeIntervalSince1970: 1)),
                StoredMessage(isUser: false, rawText: "Earlier answer", timestamp: Date(timeIntervalSince1970: 2))
            ],
            preferredAIModel: AIModel.gpt54.rawValue,
            selectedChatPresetID: ChatPreset.BuiltIn.chat.id
        )
        let savedURL = try await composition.oracleViewModel.chatData.saveChatSession(legacySession, for: workspace)

        var capturedMessages: [AIMessage] = []
        var capturedModels: [AIModel] = []
        var persistedAtFirstDispatch: ChatSession?
        composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { message, model in
            if capturedMessages.isEmpty {
                persistedAtFirstDispatch = try? await composition.oracleViewModel.chatData.loadChatSession(from: savedURL)
            }
            capturedMessages.append(message)
            capturedModels.append(model)
            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                continuation.yield(
                    ChatStreamOutput(text: "done", reasoning: nil, tokens: ChatTokenInfo(), terminalOutcome: .completed)
                )
                continuation.finish()
            }
            return (UUID(), stream)
        }

        _ = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("First upgraded turn"),
                "mode": .string("review"),
                "chat_id": .string(legacySession.shortID)
            ],
            promptVM: composition.promptManager,
            tabContext: makeTabContext(workspaceID: workspace.id, tabID: tab.id),
            capturedProfile: profile,
            selectionSnapshotOverride: legacySnapshot
        )
        XCTAssertEqual(persistedAtFirstDispatch?.preferredAIModel, AIModel.gpt54Mini.rawValue)
        XCTAssertEqual(persistedAtFirstDispatch?.selectedChatPresetID, reviewPreset.id)
        XCTAssertEqual(persistedAtFirstDispatch?.oracleExecutionAuthority, .frozen)
        XCTAssertEqual(capturedModels, [.gpt54Mini])
        XCTAssertTrue(try XCTUnwrap(capturedMessages.first).systemPrompt.contains(promptMarker))
        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
        let upgraded = try await composition.oracleViewModel.chatData.loadChatSession(from: savedURL)
        XCTAssertEqual(upgraded.preferredAIModel, AIModel.gpt54Mini.rawValue)
        XCTAssertEqual(upgraded.selectedChatPresetID, reviewPreset.id)
        XCTAssertEqual(upgraded.oracleExecutionAuthority, .frozen)

        let changedProfile = AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt54.rawValue)
        let changedSnapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: changedProfile,
            modelPresets: [],
            modelPresetsExposed: false,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all() + [reviewPreset],
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
        composition.oracleViewModel.purgeSessionStorage(legacySession.id)
        composition.oracleViewModel.sessions = []
        composition.oracleViewModel.currentSessionID = nil
        _ = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Frozen later turn"),
                "mode": .string("review"),
                "chat_id": .string(legacySession.id.uuidString)
            ],
            promptVM: composition.promptManager,
            tabContext: makeTabContext(workspaceID: workspace.id, tabID: tab.id),
            capturedProfile: changedProfile,
            selectionSnapshotOverride: changedSnapshot
        )
        XCTAssertEqual(capturedModels, [.gpt54Mini, .gpt54Mini])
        XCTAssertEqual(capturedMessages.count, 2)
        XCTAssertTrue(capturedMessages.allSatisfy { $0.systemPrompt.contains(promptMarker) })
        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
    }

    func testTwoLanePresetPreservesRosterPromptAndContinuationAuthority() async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -9322,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OraclePresetExecutionGroupTests-\(UUID().uuidString)", isDirectory: true)
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

        let promptID = UUID()
        composition.promptManager.preferredModel = AIModel.gpt54.rawValue
        composition.promptManager.selectedChatPresetID = ChatPreset.BuiltIn.chat.id
        let promptMarker = "GROUP CUSTOM REVIEW MARKER"
        composition.promptManager.storedPrompts.append(
            StoredPromptRecord(id: promptID, title: "[Group Review]", content: promptMarker)
        )
        let chatPreset = ChatPreset(
            name: "Group Review",
            mode: .review,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
            gitInclusion: GitInclusion.none,
            storedPromptIds: [promptID],
            useStoredPromptsAsSystem: true
        )
        let dispatchGuidance = "  Compare evidence before proposing changes.\nKeep disagreements explicit.  "
        let continuationGuidance = "Review the new evidence independently."
        let preset = try ModelPreset(
            name: "Review-Group",
            modelStrings: [AIModel.gpt54Mini.rawValue, AIModel.gpt54.rawValue],
            chatPresetMappings: ChatPresetMappings(reviewPresetID: chatPreset.id)
        )
        let profile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54.rawValue,
            additionalOracleModelRaws: [AIModel.gpt54.rawValue],
            oracleReconciliationGuidance: dispatchGuidance
        )
        let snapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: profile,
            modelPresets: [preset],
            modelPresetsExposed: true,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all() + [chatPreset],
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
        var capturedMessages: [AIMessage] = []
        var capturedModels: [AIModel] = []
        composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { message, model in
            capturedMessages.append(message)
            capturedModels.append(model)
            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                continuation.yield(
                    ChatStreamOutput(
                        text: "response-\(model.rawValue)",
                        reasoning: nil,
                        tokens: ChatTokenInfo(),
                        terminalOutcome: .completed
                    )
                )
                continuation.finish()
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

        let started = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("First"),
                "mode": .string("review"),
                "model": .string(preset.name),
                "new_chat": .bool(true)
            ],
            promptVM: composition.promptManager,
            tabContext: context,
            capturedProfile: profile,
            selectionSnapshotOverride: snapshot
        )
        let groupID = try XCTUnwrap(started["oracle_group_id"]?.stringValue)
        let groupUUID = try XCTUnwrap(UUID(uuidString: groupID))
        groupIDForCleanup = OracleGroupID(rawValue: groupUUID)
        let chatID = try XCTUnwrap(started["chat_id"]?.stringValue)
        let startedLanes = try XCTUnwrap(started["oracle_results"]?.arrayValue)
        XCTAssertEqual(startedLanes.compactMap { $0.objectValue?["model_id"]?.stringValue }, preset.modelStrings)
        XCTAssertEqual(started["oracle_count"]?.intValue, 2)
        XCTAssertEqual(started["oracle_reconciliation_guidance"]?.stringValue, dispatchGuidance)
        XCTAssertEqual(capturedMessages.count, 2)
        XCTAssertTrue(capturedMessages.allSatisfy { $0.systemPrompt.contains(promptMarker) })
        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
        let primarySession = try XCTUnwrap(
            composition.oracleViewModel.sessions.first(where: {
                $0.oracleGroupID == groupUUID && $0.oracleLaneIndex == 0
            })
        )
        let primaryURL = try XCTUnwrap(primarySession.fileURL)
        let persistedPrimary = try await composition.oracleViewModel.chatData.loadChatSession(from: primaryURL)
        XCTAssertEqual(persistedPrimary.preferredAIModel, AIModel.gpt54Mini.rawValue)
        XCTAssertEqual(persistedPrimary.selectedChatPresetID, chatPreset.id)
        XCTAssertEqual(persistedPrimary.oracleExecutionAuthority, .frozen)

        let historyEncoder = JSONEncoder()
        historyEncoder.outputFormatting = [.sortedKeys]
        let groupURL = AppDomainRuntimeComposition.shared.runtime.persistenceCoordinator.oracleStorageRoot
            .appendingPathComponent("groups/\(groupUUID.uuidString).json")
        let groupBytes = try Data(contentsOf: groupURL)
        let sibling = try XCTUnwrap(composition.oracleViewModel.sessions.first(where: {
            $0.oracleGroupID == groupUUID && $0.oracleLaneIndex == 1
        }))
        let siblingURL = try XCTUnwrap(sibling.fileURL)
        let siblingBytes = try Data(contentsOf: siblingURL)
        let changedProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54.rawValue,
            additionalOracleModelRaws: [],
            oracleReconciliationGuidance: continuationGuidance
        )
        let continued = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Second"),
                "mode": .string("review"),
                "chat_id": .string(chatID),
                "chat_name": .string("Must not rename historical group")
            ],
            promptVM: composition.promptManager,
            tabContext: context,
            capturedProfile: changedProfile,
            selectionSnapshotOverride: snapshot
        )
        XCTAssertNil(continued["oracle_group_id"])
        XCTAssertNil(continued["oracle_count"])
        XCTAssertEqual(continued["chat_id"]?.stringValue, chatID)
        XCTAssertEqual(capturedMessages.count, 3)
        XCTAssertEqual(capturedModels.last, AIModel.gpt54Mini)
        XCTAssertTrue(capturedMessages.allSatisfy { $0.systemPrompt.contains(promptMarker) })
        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
        XCTAssertEqual(try Data(contentsOf: groupURL), groupBytes)
        XCTAssertEqual(try Data(contentsOf: siblingURL), siblingBytes)
        let continuedPrimary = try await composition.oracleViewModel.chatData.loadChatSession(from: primaryURL)
        XCTAssertEqual(continuedPrimary.id, persistedPrimary.id)
        XCTAssertEqual(continuedPrimary.name, persistedPrimary.name)
        XCTAssertEqual(try historyEncoder.encode(Array(continuedPrimary.messages.prefix(persistedPrimary.messages.count))), try historyEncoder.encode(persistedPrimary.messages))
        XCTAssertEqual(continuedPrimary.messages.count, persistedPrimary.messages.count + 2)

        // Cold UUID continuation addresses the other lane, not the primary or its historical group.
        let primaryBytes = try Data(contentsOf: primaryURL)
        let persistedSibling = try await composition.oracleViewModel.chatData.loadChatSession(from: siblingURL)
        for session in composition.oracleViewModel.sessions {
            composition.oracleViewModel.purgeSessionStorage(session.id)
        }
        composition.oracleViewModel.sessions = []
        composition.oracleViewModel.currentSessionID = nil
        await composition.oracleViewModel.loadSessionsFromWorkspace()
        let siblingReply = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Only the second lane"),
                "mode": .string("review"),
                "chat_id": .string(sibling.id.uuidString), "chat_name": .string("Must not rename sibling")
            ],
            promptVM: composition.promptManager,
            tabContext: context,
            capturedProfile: changedProfile,
            selectionSnapshotOverride: snapshot
        )
        XCTAssertNil(siblingReply["oracle_group_id"])
        XCTAssertEqual(siblingReply["chat_id"]?.stringValue, sibling.shortID)
        XCTAssertEqual(capturedMessages.count, 4)
        XCTAssertEqual(capturedModels.last, AIModel.gpt54)
        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
        XCTAssertEqual(try Data(contentsOf: groupURL), groupBytes)
        XCTAssertEqual(try Data(contentsOf: primaryURL), primaryBytes)
        let continuedSibling = try await composition.oracleViewModel.chatData.loadChatSession(from: siblingURL)
        XCTAssertEqual(continuedSibling.id, persistedSibling.id)
        XCTAssertEqual(continuedSibling.name, persistedSibling.name)
        XCTAssertEqual(try historyEncoder.encode(Array(continuedSibling.messages.prefix(persistedSibling.messages.count))), try historyEncoder.encode(persistedSibling.messages))
        XCTAssertEqual(continuedSibling.messages.count, persistedSibling.messages.count + 2)

        // Implicit selected-chat continuation still continues the frozen group roster.
        composition.workspaceManager.setActiveChatSessionID(primarySession.id, forTabID: tab.id)
        let implicit = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: ["message": .string("Continue the selected group"), "mode": .string("review")],
            promptVM: composition.promptManager,
            tabContext: context,
            capturedProfile: changedProfile,
            selectionSnapshotOverride: snapshot
        )
        XCTAssertEqual(implicit["oracle_group_id"]?.stringValue, groupID)
        XCTAssertEqual(implicit["oracle_count"]?.intValue, 2)
        XCTAssertEqual(implicit["oracle_reconciliation_guidance"]?.stringValue, continuationGuidance)
        XCTAssertEqual(capturedMessages.count, 6)
        XCTAssertTrue(capturedMessages.allSatisfy { $0.systemPrompt.contains(promptMarker) })
        XCTAssertTrue(capturedMessages.allSatisfy {
            !$0.systemPrompt.contains(dispatchGuidance) && !$0.systemPrompt.contains(continuationGuidance)
        })
        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
        let implicitPrimary = try await composition.oracleViewModel.chatData.loadChatSession(from: primaryURL)
        let implicitSibling = try await composition.oracleViewModel.chatData.loadChatSession(from: siblingURL)
        XCTAssertEqual(implicitPrimary.name, continuedPrimary.name)
        XCTAssertEqual(implicitSibling.name, continuedSibling.name)
        XCTAssertEqual(try historyEncoder.encode(Array(implicitPrimary.messages.prefix(continuedPrimary.messages.count))), try historyEncoder.encode(continuedPrimary.messages))
        XCTAssertEqual(try historyEncoder.encode(Array(implicitSibling.messages.prefix(continuedSibling.messages.count))), try historyEncoder.encode(continuedSibling.messages))

        let groupSessionIDs = composition.oracleViewModel.sessions
            .filter { $0.oracleGroupID == groupUUID }
            .map(\.id)
        for sessionID in groupSessionIDs {
            let index = try XCTUnwrap(composition.oracleViewModel.sessions.firstIndex(where: { $0.id == sessionID }))
            var legacyProjection = composition.oracleViewModel.sessions[index]
            legacyProjection.preferredAIModel = AIModel.gpt54.rawValue
            legacyProjection.selectedChatPresetID = ChatPreset.BuiltIn.chat.id
            legacyProjection.oracleExecutionAuthority = nil
            _ = try await composition.oracleViewModel.chatData.saveChatSession(legacyProjection, for: workspace)
            composition.oracleViewModel.purgeSessionStorage(sessionID)
        }
        composition.oracleViewModel.sessions = []
        composition.oracleViewModel.currentSessionID = nil
        await composition.oracleViewModel.loadSessionsFromWorkspace()

        let legacySnapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: changedProfile,
            modelPresets: [],
            modelPresetsExposed: false,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all() + [chatPreset],
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: chatPreset
            ]
        )
        let legacyGroupBytes = try Data(contentsOf: groupURL)
        let legacySiblingBytes = try Data(contentsOf: siblingURL)
        let upgradedLane = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Legacy lane upgrade"),
                "mode": .string("review"),
                "chat_id": .string(chatID)
            ],
            promptVM: composition.promptManager,
            tabContext: context,
            capturedProfile: changedProfile,
            selectionSnapshotOverride: legacySnapshot
        )
        XCTAssertNil(upgradedLane["oracle_group_id"])
        XCTAssertEqual(capturedModels.last, AIModel.gpt54Mini, "canonical model wins over stale projection/settings")
        XCTAssertTrue(try XCTUnwrap(capturedMessages.last).systemPrompt.contains(promptMarker))
        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
        XCTAssertEqual(try Data(contentsOf: groupURL), legacyGroupBytes)
        XCTAssertEqual(try Data(contentsOf: siblingURL), legacySiblingBytes)

        let upgradedLegacyGroup = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Legacy group upgrade"),
                "mode": .string("review")
            ],
            promptVM: composition.promptManager,
            tabContext: context,
            capturedProfile: changedProfile,
            selectionSnapshotOverride: legacySnapshot
        )
        XCTAssertEqual(upgradedLegacyGroup["oracle_group_id"]?.stringValue, groupID)
        let upgradedLanes = try XCTUnwrap(upgradedLegacyGroup["oracle_results"]?.arrayValue)
        XCTAssertEqual(upgradedLanes.compactMap { $0.objectValue?["model_id"]?.stringValue }, preset.modelStrings)
        XCTAssertEqual(Set(capturedModels.suffix(2).map(\.rawValue)), Set(preset.modelStrings))
        XCTAssertTrue(capturedMessages.suffix(2).allSatisfy { $0.systemPrompt.contains(promptMarker) })
        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
        for sessionID in groupSessionIDs {
            let session = try XCTUnwrap(composition.oracleViewModel.sessions.first(where: { $0.id == sessionID }))
            let persisted = try await composition.oracleViewModel.chatData.loadChatSession(from: XCTUnwrap(session.fileURL))
            let laneIndex = try XCTUnwrap(persisted.oracleLaneIndex)
            XCTAssertEqual(persisted.preferredAIModel, preset.modelStrings[laneIndex])
            XCTAssertEqual(persisted.selectedChatPresetID, chatPreset.id)
            XCTAssertEqual(persisted.oracleExecutionAuthority, .frozen)
            composition.oracleViewModel.purgeSessionStorage(sessionID)
        }

        composition.oracleViewModel.sessions = []
        composition.oracleViewModel.currentSessionID = nil
        await composition.oracleViewModel.loadSessionsFromWorkspace()
        let frozenSnapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: changedProfile,
            modelPresets: [],
            modelPresetsExposed: false,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all() + [chatPreset],
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
        _ = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Frozen group continuation"),
                "mode": .string("review")
            ],
            promptVM: composition.promptManager,
            tabContext: context,
            capturedProfile: changedProfile,
            selectionSnapshotOverride: frozenSnapshot
        )
        XCTAssertEqual(Set(capturedModels.suffix(2).map(\.rawValue)), Set(preset.modelStrings))
        XCTAssertTrue(capturedMessages.suffix(2).allSatisfy { $0.systemPrompt.contains(promptMarker) })
        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
    }

    func testFiveLanePresetExecutesMaximumOrderedRosterWithMappedPrompt() async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -9323,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OraclePresetExecutionFiveLaneTests-\(UUID().uuidString)", isDirectory: true)
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

        let promptID = UUID()
        composition.promptManager.preferredModel = AIModel.gpt54.rawValue
        composition.promptManager.selectedChatPresetID = ChatPreset.BuiltIn.chat.id
        let promptMarker = "FIVE LANE CUSTOM REVIEW MARKER"
        composition.promptManager.storedPrompts.append(
            StoredPromptRecord(id: promptID, title: "[Five Lane Review]", content: promptMarker)
        )
        let chatPreset = ChatPreset(
            name: "Five Lane Review",
            mode: .review,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
            gitInclusion: GitInclusion.none,
            storedPromptIds: [promptID],
            useStoredPromptsAsSystem: true
        )
        let preset = try ModelPreset(
            name: "Review-Five",
            modelStrings: Array(repeating: AIModel.gpt54Mini.rawValue, count: 5),
            chatPresetMappings: ChatPresetMappings(reviewPresetID: chatPreset.id)
        )
        let profile = AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt54.rawValue)
        let snapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: profile,
            modelPresets: [preset],
            modelPresetsExposed: true,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all() + [chatPreset],
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
        var capturedMessages: [AIMessage] = []
        composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { message, model in
            capturedMessages.append(message)
            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                continuation.yield(
                    ChatStreamOutput(
                        text: "response-\(model.rawValue)",
                        reasoning: nil,
                        tokens: ChatTokenInfo(),
                        terminalOutcome: .completed
                    )
                )
                continuation.finish()
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

        let started = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Five lanes"),
                "mode": .string("review"),
                "model": .string(preset.name),
                "new_chat": .bool(true)
            ],
            promptVM: composition.promptManager,
            tabContext: context,
            capturedProfile: profile,
            selectionSnapshotOverride: snapshot
        )
        let groupID = try XCTUnwrap(started["oracle_group_id"]?.stringValue)
        let groupUUID = try XCTUnwrap(UUID(uuidString: groupID))
        groupIDForCleanup = OracleGroupID(rawValue: groupUUID)
        let results = try XCTUnwrap(started["oracle_results"]?.arrayValue)
        XCTAssertEqual(started["oracle_count"]?.intValue, 5)
        XCTAssertEqual(results.compactMap { $0.objectValue?["model_id"]?.stringValue }, preset.modelStrings)
        XCTAssertEqual(capturedMessages.count, 5)
        XCTAssertTrue(capturedMessages.allSatisfy { $0.systemPrompt.contains(promptMarker) })
    }

    private func loadSchema1ReviewPreset(
        directory: URL,
        model: AIModel,
        chatPresetID: UUID
    ) throws -> ModelPreset {
        let modelURL = directory.appendingPathComponent("modelPresets.json")
        let presetID = UUID()
        let json = """
        {
          "schemaVersion": 1,
          "updatedAt": "2026-09-10T00:00:00Z",
          "modelPresets": [{
            "id": "\(presetID.uuidString)",
            "name": "Review-2",
            "modelString": "\(model.rawValue)",
            "supportedModes": {"chat": false, "plan": false, "review": true},
            "chatPresetMappings": {"reviewPresetID": "\(chatPresetID.uuidString)"}
          }]
        }
        """
        try Data(json.utf8).write(to: modelURL)
        let store = PresetFileStore(
            workflowFileURL: directory.appendingPathComponent("workflowPresets.json"),
            modelFileURL: modelURL
        )
        return try XCTUnwrap(store.loadModelPresets().modelPresets.first)
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

/// Oracle sends must fail closed instead of shipping a prompt without explicitly selected files.
@MainActor
final class OracleSelectedFileContentRequirementTests: XCTestCase {
    private struct Fixture {
        let composition: WindowStateComposition
        let workspaceID: UUID
        let tabID: UUID
        let store: WorkspaceFileContextStore
        let rootRecord: WorkspaceRootRecord
        let baseURL: URL

        func path(_ relativePath: String) -> String {
            (rootRecord.standardizedFullPath as NSString).appendingPathComponent(relativePath)
        }
    }

    private actor OneShotIngressProbe {
        private(set) var fireCount = 0

        func claimFirstFire() -> Bool {
            fireCount += 1
            return fireCount == 1
        }
    }

    func testUnresolvedExplicitSelectionFailsOracleSendWithoutDispatch() async throws {
        let fixture = try await makeFixture(windowID: -9811)
        defer { tearDown(fixture) }
        var capturedMessages: [AIMessage] = []
        installTransport(on: fixture) { capturedMessages.append($0) }

        let presentPath = fixture.path("present.md")
        let missingPath = fixture.path("missing.md")
        do {
            _ = try await send(fixture, selection: StoredSelection(selectedPaths: [presentPath, missingPath]))
            XCTFail("Expected the Oracle send to fail for an unresolved selected file")
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(description.contains("Oracle send aborted"), description)
            XCTAssertTrue(description.contains(missingPath), description)
            XCTAssertFalse(description.contains(presentPath), description)
        }
        XCTAssertTrue(capturedMessages.isEmpty, "A partial prompt must never reach the provider")

        // Control: the same fixture packages a fully resolvable selection normally.
        _ = try await send(fixture, selection: StoredSelection(selectedPaths: [presentPath]))
        XCTAssertEqual(capturedMessages.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(capturedMessages.first).fileBlocks.joined().contains("PRESENT_MARKER"),
            "Resolved selected file contents must be packaged"
        )
    }

    func testOracleSendAwaitsAppliedIngressBeforeResolvingSelection() async throws {
        let fixture = try await makeFixture(windowID: -9812)
        defer { tearDown(fixture) }
        var capturedMessages: [AIMessage] = []
        installTransport(on: fixture) { capturedMessages.append($0) }

        // `late.md` only exists once the ingress barrier has captured its watermarks, so the
        // selection can resolve only if packaging awaits ingress before entry resolution.
        let lateRelativePath = "late.md"
        let lateURL = fixture.baseURL.appendingPathComponent("repo/\(lateRelativePath)")
        let probe = OneShotIngressProbe()
        let store = fixture.store
        let rootID = fixture.rootRecord.id
        await store.setAppliedIngressDidCaptureWatermarksHandler { _ in
            guard await probe.claimFirstFire() else { return }
            try? Data("LATE_MARKER".utf8).write(to: lateURL)
            await store.replayObservedFileSystemDeltas(rootID: rootID, deltas: [.fileAdded(lateRelativePath)])
        }
        addTeardownBlock { await store.setAppliedIngressDidCaptureWatermarksHandler(nil) }

        _ = try await send(fixture, selection: StoredSelection(selectedPaths: [fixture.path(lateRelativePath)]))

        let ingressFires = await probe.fireCount
        XCTAssertGreaterThan(ingressFires, 0, "Oracle packaging must await applied ingress")
        XCTAssertEqual(capturedMessages.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(capturedMessages.first).fileBlocks.joined().contains("LATE_MARKER"),
            "Selection must resolve against the post-ingress catalog"
        )
    }

    func testExcludedFilesSkipIngressInDirectAndHeadlessOraclePackaging() async throws {
        let fixture = try await makeFixture(windowID: -9813)
        defer { tearDown(fixture) }
        let probe = OneShotIngressProbe()
        await fixture.store.setAppliedIngressDidCaptureWatermarksHandler { _ in
            _ = await probe.claimFirstFire()
        }
        let store = fixture.store
        addTeardownBlock { await store.setAppliedIngressDidCaptureWatermarksHandler(nil) }
        let config = OraclePromptConfiguration(
            chatPreset: ChatPreset.BuiltIn.chat, mode: .chat,
            promptContext: PromptContextResolved(
                includeFiles: false, includeUserPrompt: true, includeMetaPrompts: false,
                includeFileTree: false, fileTreeMode: .none, codeMapUsage: .none,
                gitInclusion: .none, storedPromptIds: []
            ),
            systemPrompt: "EXCLUDED_FILES_SYSTEM", metaInstructions: []
        )
        let selection = StoredSelection(selectedPaths: [fixture.path("missing.md")])
        let prompt = fixture.composition.promptManager
        let direct = try await prompt.packagePrompt(
            conversation: [ConversationEntry(role: .user, content: "EXCLUDED_FILES_USER")],
            oraclePromptConfiguration: config, selectionOverride: selection,
            reviewGitContextOverride: .automaticOnly()
        )
        let headless = try await prompt.buildHeadlessAIMessage(
            from: HeadlessContextSnapshot(
                workspaceID: fixture.workspaceID, tabID: fixture.tabID,
                promptText: "EXCLUDED_FILES_USER", selection: selection, reviewGitContext: .automaticOnly()
            ), model: .gpt54, mode: .chat, oraclePromptConfiguration: config
        )
        XCTAssertTrue(direct.conversationMessages.contains { $0.content.contains("EXCLUDED_FILES_USER") })
        XCTAssertTrue(headless.conversationMessages.contains { $0.content.contains("EXCLUDED_FILES_USER") })
        XCTAssertTrue(direct.fileBlocks.isEmpty)
        XCTAssertTrue(headless.fileBlocks.isEmpty)
        let ingressFires = await probe.fireCount
        XCTAssertEqual(ingressFires, 0, "Intentionally excluded file content must not wait on watcher ingress")
    }

    // MARK: - Helpers

    private func makeFixture(windowID: Int) async throws -> Fixture {
        let composition = WindowStateCompositionFactory.make(
            windowID: windowID,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OracleSelectedFileContent-\(UUID().uuidString)", isDirectory: true)
        let storageURL = baseURL.appendingPathComponent("storage", isDirectory: true)
        let repoURL = baseURL.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try Data("PRESENT_MARKER".utf8).write(to: repoURL.appendingPathComponent("present.md"))

        var workspace = try XCTUnwrap(composition.workspaceManager.activeWorkspace)
        let tab = ComposeTabState(id: UUID())
        workspace.customStoragePath = storageURL
        workspace.composeTabs = [tab]
        workspace.activeComposeTabID = tab.id
        if let index = composition.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }) {
            composition.workspaceManager.workspaces[index] = workspace
        }
        composition.workspaceManager.activeWorkspace = workspace
        composition.promptManager.loadComposeTabsFromWorkspace(workspace)
        composition.apiSettingsViewModel.openAIApiKey = "test-key"
        composition.apiSettingsViewModel.isOpenAIKeyValid = true
        composition.promptManager.preferredModel = AIModel.gpt54.rawValue
        composition.promptManager.selectedChatPresetID = ChatPreset.BuiltIn.chat.id

        let store = composition.promptManager.workspaceFileContextStore
        let rootRecord = try await store.loadRoot(path: repoURL.path)
        return Fixture(
            composition: composition,
            workspaceID: workspace.id,
            tabID: tab.id,
            store: store,
            rootRecord: rootRecord,
            baseURL: baseURL
        )
    }

    private func tearDown(_ fixture: Fixture) {
        fixture.composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting(nil)
        fixture.composition.workspaceManager.prepareForWindowClose()
        fixture.composition.oracleViewModel.sessions = []
        let store = fixture.store
        let rootID = fixture.rootRecord.id
        let baseURL = fixture.baseURL
        let workspaceManager = fixture.composition.workspaceManager
        addTeardownBlock {
            await workspaceManager.awaitOwnSavesForWindowClose()
            await store.unloadRoot(id: rootID)
            try? FileManager.default.removeItem(at: baseURL)
        }
    }

    private func installTransport(on fixture: Fixture, capture: @escaping @MainActor (AIMessage) -> Void) {
        fixture.composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { message, _ in
            capture(message)
            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                continuation.yield(
                    ChatStreamOutput(text: "ok", reasoning: nil, tokens: ChatTokenInfo(), terminalOutcome: .completed)
                )
                continuation.finish()
            }
            return (UUID(), stream)
        }
    }

    private func send(_ fixture: Fixture, selection: StoredSelection) async throws -> [String: Value] {
        let profile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54.rawValue,
            additionalOracleModelRaws: []
        )
        let snapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: profile,
            modelPresets: [],
            modelPresetsExposed: false,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all(),
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
        let tabContext = OracleViewModel.OracleSendTabContext(
            tabID: fixture.tabID,
            workspaceID: fixture.workspaceID,
            activationPolicy: .background,
            packaging: OracleViewModel.OracleSendPackagingContext(
                sourceTabID: fixture.tabID,
                sourceWorkspaceID: fixture.workspaceID,
                sourceSelectionRevision: 0,
                sourceAgentSessionID: nil,
                sourceAgentRunID: nil,
                promptText: "",
                selection: selection,
                lookupContext: nil,
                reviewGitContext: .automaticOnly(),
                provenance: .direct
            )
        )
        return try await fixture.composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Summarize the selected files"),
                "mode": .string("chat"),
                "new_chat": .bool(true)
            ],
            promptVM: fixture.composition.promptManager,
            tabContext: tabContext,
            capturedProfile: profile,
            selectionSnapshotOverride: snapshot
        )
    }
}
