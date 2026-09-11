import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class OraclePresetExecutionTests: XCTestCase {
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
        let preset = try ModelPreset(
            name: "Review-Group",
            modelStrings: [AIModel.gpt54Mini.rawValue, AIModel.gpt54Mini.rawValue],
            chatPresetMappings: ChatPresetMappings(reviewPresetID: chatPreset.id)
        )
        let profile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54.rawValue,
            additionalOracleModelRaws: [AIModel.gpt54.rawValue]
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

        let changedProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54.rawValue,
            additionalOracleModelRaws: []
        )
        let continued = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Second"),
                "mode": .string("review"),
                "chat_id": .string(chatID)
            ],
            promptVM: composition.promptManager,
            tabContext: context,
            capturedProfile: changedProfile,
            selectionSnapshotOverride: snapshot
        )
        XCTAssertEqual(continued["oracle_group_id"]?.stringValue, groupID)
        XCTAssertEqual(continued["oracle_count"]?.intValue, 2)
        XCTAssertEqual(capturedMessages.count, 4)
        XCTAssertTrue(capturedMessages.allSatisfy { $0.systemPrompt.contains(promptMarker) })
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
