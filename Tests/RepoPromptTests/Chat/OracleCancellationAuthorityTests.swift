import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

@MainActor
final class OracleCancellationAuthorityTests: XCTestCase {
    func testForegroundExplicitCancelPreservesResolvedAuthorityForReloadAndContinuation() async throws {
        try await assertCancellationPreservesAuthority(.explicit)
    }

    func testPreTokenTransportCancelPreservesResolvedAuthorityForReloadAndContinuation() async throws {
        try await assertCancellationPreservesAuthority(.transport)
    }

    private enum CancellationKind: Equatable {
        case explicit
        case transport
    }

    private func assertCancellationPreservesAuthority(_ cancellationKind: CancellationKind) async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: cancellationKind == .explicit ? -9340 : -9341,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OracleCancellationAuthority-\(UUID().uuidString)", isDirectory: true)
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
        let promptMarker = "CANCELLED ORACLE CUSTOM REVIEW"
        composition.promptManager.storedPrompts.append(
            StoredPromptRecord(id: promptID, title: "[Cancelled Review]", content: promptMarker)
        )
        let chatPreset = ChatPreset(
            name: "Cancelled Review",
            mode: .review,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
            gitInclusion: GitInclusion.none,
            storedPromptIds: [promptID],
            useStoredPromptsAsSystem: true
        )
        let modelPreset = try ModelPreset(
            name: "Cancelled Oracle",
            model: .gpt54Mini,
            chatPresetMappings: ChatPresetMappings(reviewPresetID: chatPreset.id)
        )
        let profile = AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt54.rawValue)
        let startSnapshot = snapshot(
            profile: profile,
            modelPresets: [modelPreset],
            chatPreset: chatPreset,
            exposed: true
        )
        var capturedMessages: [AIMessage] = []
        var capturedModels: [AIModel] = []
        var heldContinuation: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation?
        composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { message, model in
            capturedMessages.append(message)
            capturedModels.append(model)
            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                switch cancellationKind {
                case .explicit:
                    heldContinuation = continuation
                case .transport:
                    continuation.finish(throwing: CancellationError())
                }
            }
            return (UUID(), stream)
        }

        let request = Task { @MainActor in
            try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
                args: [
                    "message": .string("Cancel before response"),
                    "mode": .string("review"),
                    "model": .string(modelPreset.name),
                    "new_chat": .bool(true)
                ],
                promptVM: composition.promptManager,
                tabContext: makeTabContext(workspaceID: workspace.id, tabID: tab.id),
                capturedProfile: profile,
                selectionSnapshotOverride: startSnapshot
            )
        }

        if cancellationKind == .explicit {
            try await AsyncTestWait.waitUntil("Oracle explicit-cancel stream start") {
                heldContinuation != nil && composition.oracleViewModel.sessions.contains {
                    $0.selectedChatPresetID == chatPreset.id
                }
            }
            let session = try XCTUnwrap(
                composition.oracleViewModel.sessions.first(where: { $0.selectedChatPresetID == chatPreset.id })
            )
            await composition.oracleViewModel.cancelAIResponse(in: session.id, skipPartialParseAndSave: false)
            heldContinuation?.finish(throwing: CancellationError())
        }

        do {
            _ = try await request.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch let error as ChatToolError {
            XCTAssertTrue(error.message.localizedCaseInsensitiveContains("cancel"), error.message)
        }

        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
        let cancelledSession = try XCTUnwrap(
            composition.oracleViewModel.sessions.first(where: { $0.selectedChatPresetID == chatPreset.id })
        )
        let savedURL = try XCTUnwrap(cancelledSession.fileURL)
        let persisted = try await composition.oracleViewModel.chatData.loadChatSession(from: savedURL)
        XCTAssertFalse(persisted.messages.contains { !$0.isUser && $0.rawText.isEmpty })
        XCTAssertEqual(persisted.preferredAIModel, AIModel.gpt54Mini.rawValue)
        XCTAssertEqual(persisted.selectedChatPresetID, chatPreset.id)

        composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { message, model in
            capturedMessages.append(message)
            capturedModels.append(model)
            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                continuation.yield(
                    ChatStreamOutput(text: "continued", reasoning: nil, tokens: ChatTokenInfo(), terminalOutcome: .completed)
                )
                continuation.finish()
            }
            return (UUID(), stream)
        }
        let continuationSnapshot = snapshot(
            profile: AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt54.rawValue),
            modelPresets: [],
            chatPreset: chatPreset,
            exposed: false
        )
        _ = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Continue after cancellation"),
                "mode": .string("review"),
                "chat_id": .string(cancelledSession.shortID)
            ],
            promptVM: composition.promptManager,
            tabContext: makeTabContext(workspaceID: workspace.id, tabID: tab.id),
            capturedProfile: continuationSnapshot.agentModelsProfile,
            selectionSnapshotOverride: continuationSnapshot
        )

        XCTAssertEqual(capturedModels, [.gpt54Mini, .gpt54Mini])
        XCTAssertEqual(capturedMessages.count, 2)
        XCTAssertTrue(capturedMessages.allSatisfy { $0.systemPrompt.contains(promptMarker) })
    }

    private func snapshot(
        profile: AgentModelsSettingsProfile,
        modelPresets: [ModelPreset],
        chatPreset: ChatPreset,
        exposed: Bool
    ) -> OracleSelectionSnapshot {
        OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: profile,
            modelPresets: modelPresets,
            modelPresetsExposed: exposed,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all() + [chatPreset],
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
    }

    private func makeTabContext(workspaceID: UUID, tabID: UUID) -> OracleViewModel.OracleSendTabContext {
        OracleViewModel.OracleSendTabContext(
            tabID: tabID,
            workspaceID: workspaceID,
            activationPolicy: .foregroundWhenActive,
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
