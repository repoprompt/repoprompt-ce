import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class ContextBuilderOraclePresetTests: XCTestCase {
    func testOraclePresetAcceptsGeneratingResponseTypesAndRejectsContextOnlyRuns() throws {
        for responseType in [ContextBuilderResponseType.plan, .question, .review] {
            XCTAssertEqual(
                try MCPContextBuilderToolProvider.parseOraclePreset(
                    .string("  Deep Review  "),
                    responseType: responseType
                ),
                "Deep Review"
            )
        }

        for responseType in [ContextBuilderResponseType?.none, .some(.clarify)] {
            XCTAssertThrowsError(
                try MCPContextBuilderToolProvider.parseOraclePreset(
                    .string("Deep Review"),
                    responseType: responseType
                )
            )
        }
    }

    func testOraclePresetRejectsMalformedIdentifiersBeforeDispatch() {
        let oversized = String(repeating: "x", count: OracleRosterContract.maximumModelIdentifierLength + 1)
        for value in [Value.int(1), .string("   "), .string(oversized)] {
            XCTAssertThrowsError(
                try MCPContextBuilderToolProvider.parseOraclePreset(value, responseType: .plan)
            )
        }
    }

    @MainActor
    func testPresetAuthorityCapturesModeRosterPromptAndOrderedPresentation() throws {
        let chat = ChatPreset(name: "Mapped Chat", mode: .chat)
        let plan = ChatPreset(name: "Mapped Plan", mode: .plan)
        let review = ChatPreset(name: "Mapped Review", mode: .review)
        let preset = try ModelPreset(
            name: "Deep",
            modelStrings: [AIModel.gpt54.rawValue, AIModel.gpt54Mini.rawValue],
            supportedModes: SupportedModes(chat: true, plan: true, review: true),
            chatPresetMappings: ChatPresetMappings(
                chatPresetID: chat.id,
                planPresetID: plan.id,
                reviewPresetID: review.id
            )
        )
        let snapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: AgentModelsSettingsProfile(planningModelRaw: AIModel.claude4Sonnet.rawValue),
            modelPresets: [preset],
            modelPresetsExposed: true,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: [chat, plan, review],
            defaultChatPresets: [.chat: ChatPreset.BuiltIn.chat, .plan: ChatPreset.BuiltIn.plan, .review: ChatPreset.BuiltIn.review]
        )
        let resolver = makeResolver()

        let cases: [(HeadlessMode, String, UUID)] = [
            (.plan, "plan", plan.id),
            (.chat, "chat", chat.id),
            (.review, "review", review.id)
        ]
        for (headlessMode, oracleMode, expectedPresetID) in cases {
            let execution = try resolver.resolve(
                choice: .contextBuilderPreset(preset.id.uuidString),
                mode: oracleMode,
                snapshot: snapshot
            )
            let authority = ContextBuilderGeneratedResponseAuthority.generate(
                mode: headlessMode,
                execution: execution
            )
            XCTAssertEqual(execution.roster.orderedModels.map(\.modelID), preset.modelStrings)
            XCTAssertEqual(execution.promptConfiguration.chatPresetID, expectedPresetID)
            XCTAssertEqual(execution.promptConfiguration.systemPrompt, "provider-visible-\(expectedPresetID.uuidString)")
            XCTAssertEqual(
                authority.planningModelName,
                [AIModel.gpt54.displayName, AIModel.gpt54Mini.displayName].joined(separator: ", ")
            )
        }
    }

    @MainActor
    func testCapturedExecutionFailsWhenAvailabilityIsLostWithoutReselection() throws {
        let preset = try ModelPreset(
            name: "Captured",
            modelStrings: [AIModel.gpt54.rawValue, AIModel.gpt54Mini.rawValue]
        )
        let snapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: AgentModelsSettingsProfile(planningModelRaw: AIModel.claude4Sonnet.rawValue),
            modelPresets: [preset],
            modelPresetsExposed: true,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: [ChatPreset.BuiltIn.plan],
            defaultChatPresets: [.plan: ChatPreset.BuiltIn.plan]
        )
        let execution = try makeResolver().resolve(
            choice: .contextBuilderPreset("Captured"),
            mode: "plan",
            snapshot: snapshot
        )

        XCTAssertThrowsError(
            try execution.validateAvailability(using: { $0 == AIModel.gpt54 })
        ) { error in
            XCTAssertEqual(
                error as? OracleExecutionResolutionError,
                .unavailableModel(presetName: "Captured", laneIndex: 1, model: .gpt54Mini)
            )
        }
        XCTAssertEqual(execution.models, [.gpt54, .gpt54Mini])
    }

    @MainActor
    func testNonfocusedActiveWorkspaceSinglePersistsCapturedAuthorityForContinuation() async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -9330,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderOraclePresetN1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting(nil)
            composition.workspaceManager.prepareForWindowClose()
            composition.oracleViewModel.sessions = []
            try? FileManager.default.removeItem(at: root)
        }

        let workspace = composition.workspaceManager.createWorkspace(
            name: "Context Builder captured N1",
            repoPaths: [root.path],
            ephemeral: true
        )
        let focusedTab = ComposeTabState(name: "Focused")
        let targetTab = ComposeTabState(name: "Target")
        let workspaceIndex = try XCTUnwrap(
            composition.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id })
        )
        composition.workspaceManager.workspaces[workspaceIndex].composeTabs = [focusedTab, targetTab]
        composition.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = focusedTab.id
        await composition.workspaceManager.switchWorkspace(
            to: composition.workspaceManager.workspaces[workspaceIndex],
            saveState: false,
            reason: #function
        )
        composition.promptManager.loadComposeTabsFromWorkspace(
            composition.workspaceManager.workspaces[workspaceIndex],
            syncPromptText: true
        )
        composition.apiSettingsViewModel.openAIApiKey = "test-key"
        composition.apiSettingsViewModel.isOpenAIKeyValid = true
        composition.promptManager.preferredModel = AIModel.gpt54.rawValue
        composition.promptManager.selectedChatPresetID = ChatPreset.BuiltIn.chat.id

        let marker = "CAPTURED CONTEXT BUILDER N1 PROMPT"
        let promptID = UUID()
        composition.promptManager.storedPrompts.append(
            StoredPromptRecord(id: promptID, title: "[Captured N1 Review]", content: marker)
        )
        let chatPreset = ChatPreset(
            name: "Captured N1 Review",
            mode: .review,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
            gitInclusion: GitInclusion.none,
            storedPromptIds: [promptID],
            useStoredPromptsAsSystem: true
        )
        let profile = AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt54Mini.rawValue)
        let execution = try OracleExecutionResolver(promptViewModel: composition.promptManager).resolve(
            choice: .automatic,
            mode: "review",
            snapshot: OracleSelectionSnapshot(
                origin: .mcp,
                agentModelsProfile: profile,
                modelPresets: [],
                modelPresetsExposed: false,
                modelPresetsTemporarilyDisabled: false,
                chatPresets: [chatPreset],
                defaultChatPresets: [.review: chatPreset]
            )
        )
        var capturedMessages: [AIMessage] = []
        var capturedModels: [AIModel] = []
        composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { message, model in
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

        let reply = try await composition.contextBuilderAgentViewModel.runMCPPlanOrQuestion(
            for: WorkspaceSelectionIdentity(workspaceID: workspace.id, tabID: targetTab.id),
            oracleViewModel: composition.oracleViewModel,
            mode: .review,
            execution: execution,
            prompt: "Review the change",
            selection: targetTab.selection,
            reviewGitContext: .automaticOnly()
        )
        XCTAssertEqual(composition.promptManager.activeComposeTabID, focusedTab.id)
        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
        let session = try XCTUnwrap(
            composition.oracleViewModel.sessions.first(where: { $0.id == reply.chatId })
        )
        let savedURL = try XCTUnwrap(session.fileURL)
        let persisted = try await composition.oracleViewModel.chatData.loadChatSession(from: savedURL)
        XCTAssertEqual(persisted.preferredAIModel, AIModel.gpt54Mini.rawValue)
        XCTAssertEqual(persisted.selectedChatPresetID, chatPreset.id)

        let continuationSnapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt54.rawValue),
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
                "message": .string("Continue captured review"),
                "mode": .string("review"),
                "chat_id": .string(reply.shortId)
            ],
            promptVM: composition.promptManager,
            tabContext: makeTabContext(workspaceID: workspace.id, tabID: targetTab.id),
            capturedProfile: continuationSnapshot.agentModelsProfile,
            selectionSnapshotOverride: continuationSnapshot
        )
        XCTAssertEqual(capturedModels, [.gpt54Mini, .gpt54Mini])
        XCTAssertEqual(capturedMessages.count, 2)
        XCTAssertTrue(capturedMessages.allSatisfy { $0.systemPrompt.contains(marker) })
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

    @MainActor
    private func makeResolver() -> OracleExecutionResolver {
        OracleExecutionResolver(
            resolveModel: AIModel.fromModelName,
            isModelAvailable: { _ in true },
            capturePromptConfiguration: { preset, mode in
                OraclePromptConfiguration(
                    chatPreset: preset,
                    mode: mode,
                    promptContext: PromptContextResolved(
                        includeFiles: true,
                        includeUserPrompt: true,
                        includeMetaPrompts: true,
                        includeFileTree: true,
                        fileTreeMode: .auto,
                        codeMapUsage: .auto,
                        gitInclusion: .none,
                        storedPromptIds: preset.storedPromptIds
                    ),
                    systemPrompt: "provider-visible-\(preset.id.uuidString)",
                    metaInstructions: []
                )
            }
        )
    }
}
