import Foundation
@testable import RepoPromptApp
import XCTest

final class OracleMCPFollowUpModelSelectionTests: XCTestCase {
    @MainActor
    func testCapturedPlanningModelWinsWithoutChangingExplicitOrOrdinaryPresetSelection() async throws {
        let settings = GlobalSettingsStore.shared
        let previousShowPresets = settings.mcpShowModelPresets()
        let previousTemporarilyDisabled = settings.mcpTemporarilyDisablePresets()
        settings.setMCPShowModelPresets(true, commit: false)
        settings.setMCPTemporarilyDisablePresets(false, commit: false)
        defer {
            settings.setMCPShowModelPresets(previousShowPresets, commit: false)
            settings.setMCPTemporarilyDisablePresets(previousTemporarilyDisabled, commit: false)
        }

        let fixture = makeFixture()
        fixture.apiSettings.openAIApiKey = "test-key"
        fixture.apiSettings.isOpenAIKeyValid = true

        let capturedPlanningModel = AIModel.gpt54
        let presetModel = AIModel.gpt54Mini
        let preset = ModelPreset(name: "review_preset", model: presetModel)

        let capturedSelection = try await fixture.oracle.resolveMCPFollowUpModel(
            mode: "review",
            planningModelRawOverride: capturedPlanningModel.rawValue,
            allPresetsOverride: [preset]
        )
        XCTAssertEqual(capturedSelection.model, capturedPlanningModel)

        let explicitSelection = try await fixture.oracle.resolveMCPFollowUpModel(
            mode: "review",
            modelParam: preset.name,
            planningModelRawOverride: capturedPlanningModel.rawValue,
            allPresetsOverride: [preset]
        )
        XCTAssertEqual(explicitSelection.model, presetModel)

        let ordinarySelection = try await fixture.oracle.resolveMCPFollowUpModel(
            mode: "review",
            allPresetsOverride: [preset]
        )
        XCTAssertEqual(ordinarySelection.model, presetModel)

        do {
            _ = try await fixture.oracle.resolveMCPFollowUpModel(
                mode: "review",
                planningModelRawOverride: AIModel.claude4Sonnet.rawValue,
                allPresetsOverride: [preset]
            )
            XCTFail("An unavailable captured primary must not fall back to a preset")
        } catch let error as ChatToolError {
            XCTAssertEqual(error.code, .invalidParams)
        }

        do {
            _ = try await fixture.oracle.resolveMCPFollowUpModel(
                mode: "review",
                planningModelRawOverride: "not_a_real_model",
                allPresetsOverride: [preset]
            )
            XCTFail("An invalid captured primary must not fall back to a preset")
        } catch let error as ChatToolError {
            XCTAssertEqual(error.code, .invalidParams)
        }
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
