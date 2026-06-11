import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class PromptAgentAvailabilityRefreshTests: XCTestCase {
    func testSavingGLMSecretPublishesSingleAvailabilityRefresh() async throws {
        let restoredDefaults = preserveDefaults(Self.availabilityDefaultsKeys)
        defer { restoreDefaults(restoredDefaults) }
        resetAvailabilityDefaults(glmConfigured: false)

        let notification = expectation(description: "GLM availability refresh is published once")
        let observer = NotificationCenter.default.addObserver(
            forName: .claudeCodeGLMAvailabilityChanged,
            object: nil,
            queue: nil
        ) { _ in
            notification.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let viewModel = makeViewModel()

        try await viewModel.saveCompatibleBackendSecret("zai-test-key", for: .glmZAI)

        await fulfillment(of: [notification], timeout: 1.0)
        XCTAssertTrue(viewModel.compatibleBackendHasSecret(.glmZAI))
        XCTAssertTrue(ClaudeCodeGLMIntegration.isConfigured())
    }

    func testLoadingPreconfiguredZAIKeyPublishesGLMAvailabilityRefresh() async {
        let restoredDefaults = preserveDefaults(Self.availabilityDefaultsKeys)
        defer { restoreDefaults(restoredDefaults) }
        resetAvailabilityDefaults(glmConfigured: true)

        let notification = expectation(description: "GLM availability refresh is published")
        notification.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(
            forName: .claudeCodeGLMAvailabilityChanged,
            object: nil,
            queue: nil
        ) { _ in
            notification.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let viewModel = makeViewModel()

        await viewModel.loadStoredData(accessMode: .nonInteractive(reason: .test))

        await fulfillment(of: [notification], timeout: 1.0)
        XCTAssertTrue(viewModel.compatibleBackendHasSecret(.glmZAI))
        XCTAssertTrue(ClaudeCodeGLMIntegration.isConfigured())
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
