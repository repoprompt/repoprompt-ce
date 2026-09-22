import Foundation
@testable import RepoPromptApp
import XCTest

final class OracleMCPFollowUpModelSelectionTests: XCTestCase {
    @MainActor
    func testCapturedProfileUsesAutomaticPresetAndExplicitRawOverrideRetainsAdditions() throws {
        let fixture = makeFixture()
        fixture.apiSettings.openAIApiKey = "test-key"
        fixture.apiSettings.isOpenAIKeyValid = true
        let automaticPreset = try ModelPreset(
            name: "review_preset",
            modelStrings: [AIModel.gpt54Mini.rawValue]
        )
        let profile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54.rawValue,
            additionalOracleModelRaws: [AIModel.gpt54Mini.rawValue]
        )
        let snapshot = makeSnapshot(profile: profile, presets: [automaticPreset])

        let automatic = try fixture.oracle.resolveOracleStartExecution(
            mode: "review",
            modelParam: nil,
            profile: profile,
            promptVM: fixture.oracle.promptViewModel,
            snapshotOverride: snapshot
        )
        XCTAssertEqual(automatic.models, [.gpt54Mini])
        XCTAssertEqual(automatic.selection, .automaticPreset(id: automaticPreset.id, name: automaticPreset.name))

        let rawOverride = try fixture.oracle.resolveOracleStartExecution(
            mode: "review",
            modelParam: AIModel.gpt54.rawValue,
            profile: profile,
            promptVM: fixture.oracle.promptViewModel,
            snapshotOverride: snapshot
        )
        XCTAssertEqual(rawOverride.models, [.gpt54, .gpt54Mini])
        XCTAssertEqual(rawOverride.selection, .rawPrimaryOverride(AIModel.gpt54.rawValue))
    }

    @MainActor
    private func makeSnapshot(
        profile: AgentModelsSettingsProfile,
        presets: [ModelPreset]
    ) -> OracleSelectionSnapshot {
        OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: profile,
            modelPresets: presets,
            modelPresetsExposed: true,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all(),
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
    }

    @MainActor
    private func makeFixture() -> (oracle: OracleViewModel, apiSettings: APISettingsViewModel) {
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let aiQueriesService = AIQueriesService(keyManager: keyManager)
        let fileManager = WorkspaceFilesViewModel()
        let apiSettings = APISettingsViewModel(
            aiQueriesService: aiQueriesService,
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -896,
            settingsManager: WindowSettingsManager(windowID: -896)
        )
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let oracle = OracleViewModel(
            aiQueriesService: aiQueriesService,
            promptViewModel: prompt,
            workspaceManager: workspaceManager,
            chatData: ChatDataService()
        )
        return (oracle, apiSettings)
    }
}
