@testable import RepoPrompt
import XCTest

@MainActor
final class PromptAgentAvailabilityRefreshTests: XCTestCase {
    func testPromptRefreshesAvailableAgentKindsWhenPreconfiguredZAIKeyLoadsAtStartup() async throws {
        let defaults = UserDefaults.standard
        let store = ClaudeCodeCompatibleBackendStore.shared
        let configuredKey = store.configuredDefaultsKey(for: .glmZAI)
        let legacyConfiguredKey = ClaudeCodeGLMIntegration.configuredDefaultsKey
        let configsKey = ClaudeCodeCompatibleBackendStore.configsDefaultsKey

        let originalConfigured = defaults.object(forKey: configuredKey)
        let originalLegacyConfigured = defaults.object(forKey: legacyConfiguredKey)
        let originalConfigs = defaults.object(forKey: configsKey)
        defer {
            restoreDefaultsValue(originalConfigured, forKey: configuredKey, in: defaults)
            restoreDefaultsValue(originalLegacyConfigured, forKey: legacyConfiguredKey, in: defaults)
            restoreDefaultsValue(originalConfigs, forKey: configsKey, in: defaults)
        }

        store.saveConfig(ClaudeCodeCompatibleBackendID.glmZAI.defaultPreset)
        _ = store.setConfigured(true, for: .glmZAI)

        let secureStorage = EphemeralSecureKeyValueStore()
        let secureService = SecureKeysService(secureStorage: secureStorage)
        let keyManager = KeyManager(secureService: secureService)
        try await keyManager.saveAPIKey("test-zai-key", for: .zAI, accessMode: .nonInteractive(reason: .test))

        let aiQueriesService = AIQueriesService(keyManager: keyManager)
        let apiSettings = APISettingsViewModel(aiQueriesService: aiQueriesService, keyManager: keyManager, loadStoredDataOnInit: false)
        let prompt = PromptViewModel(
            fileManager: WorkspaceFilesViewModel(),
            aiQueriesService: aiQueriesService,
            apiSettingsViewModel: apiSettings,
            windowID: 999,
            settingsManager: WindowSettingsManager(windowID: 999)
        )

        XCTAssertFalse(apiSettings.agentModeAvailabilityContext.zaiConfigured)
        XCTAssertFalse(prompt.availableAgentKinds.contains(.claudeCodeGLM))

        await apiSettings.loadStoredData(accessMode: .nonInteractive(reason: .test))
        XCTAssertTrue(apiSettings.agentModeAvailabilityContext.zaiConfigured)
        XCTAssertTrue(apiSettings.compatibleBackendIsActive(.glmZAI))

        await drainMainQueue()

        XCTAssertTrue(
            prompt.availableAgentKinds.contains(.claudeCodeGLM),
            "PromptViewModel should refresh IDE agent options after an already-configured ZAI key loads during startup."
        )
    }

    private func drainMainQueue(file: StaticString = #filePath, line: UInt = #line) async {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async {
            drained.fulfill()
        }
        await fulfillment(of: [drained], timeout: 1)
    }

    private func restoreDefaultsValue(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
