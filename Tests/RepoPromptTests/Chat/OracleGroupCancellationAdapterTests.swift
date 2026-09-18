import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

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
