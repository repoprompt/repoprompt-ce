import Foundation
@testable import RepoPromptServiceHTTP
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class ClaudeCompatibleBackendPersistTests: XCTestCase {
    func testKimiSlotsAndBehaviorDoNotComeFromCustomKeys() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = PortalDesktopSettingsService(store: store)

        let afterCustom = try await service.update(.init(expectedRevision: 0, changes: [
            PortalDesktopSettingKey.claudeCustomModelBehavior.rawValue: "claudeSlotMapping",
            PortalDesktopSettingKey.claudeCustomHaikuModel.rawValue: "custom-haiku",
            PortalDesktopSettingKey.claudeCustomSonnetModel.rawValue: "custom-sonnet",
            PortalDesktopSettingKey.claudeCustomOpusModel.rawValue: "custom-opus"
        ]))
        let leakedSettings = try await service.backendSettings(for: .claudeKimi)
        let leaked = try XCTUnwrap(leakedSettings)
        XCTAssertEqual(leaked.modelBehavior, .noModel)
        XCTAssertEqual(leaked.haikuModel, "")
        XCTAssertEqual(leaked.sonnetModel, "")
        XCTAssertEqual(leaked.opusModel, "")

        _ = try await service.update(.init(expectedRevision: afterCustom.revision, changes: [
            PortalDesktopSettingKey.claudeKimiModelBehavior.rawValue: "claudeSlotMapping",
            PortalDesktopSettingKey.claudeKimiHaikuModel.rawValue: "kimi-haiku",
            PortalDesktopSettingKey.claudeKimiSonnetModel.rawValue: "kimi-sonnet",
            PortalDesktopSettingKey.claudeKimiOpusModel.rawValue: "kimi-opus"
        ]))
        let kimiSettings = try await service.backendSettings(for: .claudeKimi)
        let kimi = try XCTUnwrap(kimiSettings)
        XCTAssertEqual(kimi.modelBehavior, .claudeSlotMapping)
        XCTAssertEqual(kimi.haikuModel, "kimi-haiku")
        XCTAssertEqual(kimi.sonnetModel, "kimi-sonnet")
        XCTAssertEqual(kimi.opusModel, "kimi-opus")

        let customSettings = try await service.backendSettings(for: .claudeCustom)
        let custom = try XCTUnwrap(customSettings)
        XCTAssertEqual(custom.modelBehavior, .claudeSlotMapping)
        XCTAssertEqual(custom.haikuModel, "custom-haiku")
    }

    func testCustomIsEnabledDefaultsFalseThenPersistsAndLiveReads() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = PortalDesktopSettingsService(store: store)

        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.values[PortalDesktopSettingKey.claudeCustomEnabled.rawValue], "false")
        let disabledSettings = try await service.backendSettings(for: .claudeCustom)
        let disabled = try XCTUnwrap(disabledSettings)
        XCTAssertFalse(disabled.isEnabled)
        let disabledRuntime = try await service.runtimeDefaults(for: .claudeCustom)
        XCTAssertNil(disabledRuntime.providerSettings["claude.backendID"])

        _ = try await service.update(.init(expectedRevision: snapshot.revision, changes: [
            PortalDesktopSettingKey.claudeCustomEnabled.rawValue: "true",
            PortalDesktopSettingKey.claudeCustomBaseURL.rawValue: "https://claude.example/v1"
        ]))
        let enabledSettings = try await service.backendSettings(for: .claudeCustom)
        let enabled = try XCTUnwrap(enabledSettings)
        XCTAssertTrue(enabled.isEnabled)
        XCTAssertEqual(enabled.baseURL, "https://claude.example/v1")
        let enabledRuntime = try await service.runtimeDefaults(for: .claudeCustom)
        XCTAssertEqual(enabledRuntime.providerSettings["claude.backendID"], ProviderSettingsID.claudeCustom.rawValue)
        XCTAssertEqual(enabledRuntime.providerSettings["claude.backendBaseURL"], "https://claude.example/v1")
    }

    func testGLMStillReadsGLMKeysIndependentlyOfCustomAndKimi() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = PortalDesktopSettingsService(store: store)

        let defaultSettings = try await service.backendSettings(for: .claudeGLM)
        let defaults = try XCTUnwrap(defaultSettings)
        XCTAssertTrue(defaults.isEnabled)
        XCTAssertEqual(defaults.modelBehavior, .claudeSlotMapping)
        XCTAssertEqual(defaults.haikuModel, "glm-4.5-air")
        XCTAssertEqual(defaults.sonnetModel, "glm-5.2[1m]")
        XCTAssertEqual(defaults.opusModel, "glm-5.2[1m]")
        XCTAssertEqual(defaults.authHeader, .anthropicAuthToken)

        _ = try await service.update(.init(expectedRevision: 0, changes: [
            PortalDesktopSettingKey.claudeGLMHaikuModel.rawValue: "glm-haiku-override",
            PortalDesktopSettingKey.claudeGLMSonnetModel.rawValue: "glm-sonnet-override",
            PortalDesktopSettingKey.claudeGLMOpusModel.rawValue: "glm-opus-override",
            PortalDesktopSettingKey.claudeCustomHaikuModel.rawValue: "custom-haiku",
            PortalDesktopSettingKey.claudeKimiHaikuModel.rawValue: "kimi-haiku"
        ]))
        let glmSettings = try await service.backendSettings(for: .claudeGLM)
        let glm = try XCTUnwrap(glmSettings)
        XCTAssertEqual(glm.haikuModel, "glm-haiku-override")
        XCTAssertEqual(glm.sonnetModel, "glm-sonnet-override")
        XCTAssertEqual(glm.opusModel, "glm-opus-override")
        let runtime = try await service.runtimeDefaults(for: .claudeGLM)
        XCTAssertEqual(runtime.providerSettings["claude.backendHaikuModel"], "glm-haiku-override")
        XCTAssertEqual(runtime.providerSettings["claude.backendSonnetModel"], "glm-sonnet-override")
        XCTAssertEqual(runtime.providerSettings["claude.backendOpusModel"], "glm-opus-override")
    }
}
