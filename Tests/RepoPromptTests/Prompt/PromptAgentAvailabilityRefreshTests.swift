import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class PromptAgentAvailabilityRefreshTests: XCTestCase {
    func testSavingGLMSecretRefreshesAgentAvailability() async throws {
        let restoredDefaults = preserveDefaults(Self.availabilityDefaultsKeys)
        defer { restoreDefaults(restoredDefaults) }
        resetAvailabilityDefaults(glmConfigured: false)

        let viewModel = makeViewModel()
        XCTAssertFalse(viewModel.agentAvailability.zaiConfigured)

        try await viewModel.saveCompatibleBackendSecret("zai-test-key", for: .glmZAI)

        XCTAssertTrue(viewModel.agentAvailability.zaiConfigured)
        XCTAssertTrue(viewModel.compatibleBackendHasSecret(.glmZAI))
        XCTAssertTrue(ClaudeCodeGLMIntegration.isConfigured())
    }

    func testLoadingPreconfiguredZAIKeyRefreshesAgentAvailability() async {
        let restoredDefaults = preserveDefaults(Self.availabilityDefaultsKeys)
        defer { restoreDefaults(restoredDefaults) }
        resetAvailabilityDefaults(glmConfigured: true)

        let viewModel = makeViewModel()
        XCTAssertFalse(viewModel.agentAvailability.zaiConfigured)

        await viewModel.loadStoredData(accessMode: .nonInteractive(reason: .test))

        XCTAssertTrue(viewModel.agentAvailability.zaiConfigured)
        XCTAssertTrue(viewModel.compatibleBackendHasSecret(.glmZAI))
        XCTAssertTrue(ClaudeCodeGLMIntegration.isConfigured())
    }

    func testPromptRefreshesAvailableAgentKindsWhenPreconfiguredZAIKeyLoadsWithStaleSecretPresenceMirror() async {
        let restoredDefaults = preserveDefaults(Self.availabilityDefaultsKeys)
        defer { restoreDefaults(restoredDefaults) }
        resetAvailabilityDefaults(glmConfigured: true)

        let apiSettings = makeViewModel()
        let prompt = PromptViewModel(
            fileManager: WorkspaceFilesViewModel(),
            apiSettingsViewModel: apiSettings,
            windowID: 999,
            settingsManager: WindowSettingsManager(windowID: 999)
        )

        XCTAssertFalse(prompt.availableAgentKinds.contains(.claudeCodeGLM))

        apiSettings.compatibleBackendSecretPresence[.glmZAI] = true
        await apiSettings.loadStoredData(accessMode: .nonInteractive(reason: .test))
        await drainMainQueue()

        XCTAssertTrue(apiSettings.agentAvailability.zaiConfigured)
        XCTAssertTrue(
            prompt.availableAgentKinds.contains(.claudeCodeGLM),
            "PromptViewModel should refresh IDE agent options even when the secret-presence mirror was already populated before startup key load."
        )
    }

    func testLateConstructedPromptViewModelSeesPreconfiguredZAIAvailability() async {
        let restoredDefaults = preserveDefaults(Self.availabilityDefaultsKeys)
        defer { restoreDefaults(restoredDefaults) }
        resetAvailabilityDefaults(glmConfigured: true)

        let apiSettings = makeViewModel()
        await apiSettings.loadStoredData(accessMode: .nonInteractive(reason: .test))
        XCTAssertTrue(apiSettings.agentAvailability.zaiConfigured)

        // Simulates a window restored after the startup key load finished: the
        // replayed `agentAvailability` value must initialize the picker without
        // any further change event.
        let prompt = PromptViewModel(
            fileManager: WorkspaceFilesViewModel(),
            apiSettingsViewModel: apiSettings,
            windowID: 998,
            settingsManager: WindowSettingsManager(windowID: 998)
        )
        await drainMainQueue()

        XCTAssertTrue(
            prompt.availableAgentKinds.contains(.claudeCodeGLM),
            "A PromptViewModel constructed after startup key load should initialize Z.ai availability from the replayed value."
        )
    }

    private static var availabilityDefaultsKeys: [String] {
        [
            "ClaudeCodeConnected",
            "CodexCLIConnected",
            "OpenCodeCLIConnected",
            "CursorCLIConnected",
            ClaudeCodeGLMIntegration.configuredDefaultsKey,
            ClaudeCodeCompatibleBackendStore.configsDefaultsKey
        ] + ClaudeCodeCompatibleBackendID.allCases.map {
            ClaudeCodeCompatibleBackendStore.shared.configuredDefaultsKey(for: $0)
        }
    }

    private func resetAvailabilityDefaults(glmConfigured: Bool) {
        UserDefaults.standard.set(false, forKey: "ClaudeCodeConnected")
        UserDefaults.standard.set(false, forKey: "CodexCLIConnected")
        UserDefaults.standard.set(false, forKey: "OpenCodeCLIConnected")
        UserDefaults.standard.set(false, forKey: "CursorCLIConnected")
        UserDefaults.standard.removeObject(forKey: ClaudeCodeCompatibleBackendStore.configsDefaultsKey)
        for id in ClaudeCodeCompatibleBackendID.allCases {
            UserDefaults.standard.set(
                id == .glmZAI && glmConfigured,
                forKey: ClaudeCodeCompatibleBackendStore.shared.configuredDefaultsKey(for: id)
            )
        }
        UserDefaults.standard.set(glmConfigured, forKey: ClaudeCodeGLMIntegration.configuredDefaultsKey)
    }

    private func makeViewModel() -> APISettingsViewModel {
        let secureService = SecureKeysService(secureStorage: TestSecureStorageBackend(values: [
            .zAIAPI: "zai-test-key"
        ]))
        let keyManager = KeyManager(secureService: secureService)
        return APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async {
            drained.fulfill()
        }
        await fulfillment(of: [drained], timeout: 1.0)
    }

    private func preserveDefaults(_ keys: [String]) -> [String: Any?] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
    }

    private func restoreDefaults(_ snapshot: [String: Any?]) {
        for (key, value) in snapshot {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
