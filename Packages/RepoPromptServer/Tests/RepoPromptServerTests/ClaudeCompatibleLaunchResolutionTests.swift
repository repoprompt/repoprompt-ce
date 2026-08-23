import Foundation
@testable import RepoPromptHeadlessRuntime
import RepoPromptAgentRuntimeCore
@testable import RepoPromptServiceHTTP
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class ClaudeCompatibleLaunchResolutionTests: XCTestCase {
    func testGLMLaunchEnvAndArgvFromStoredConfigAndSecret() async throws {
        let harness = try await Harness.make()
        defer { harness.tearDown() }

        let storedGLM = try await harness.portal.backendSettings(for: .claudeGLM)
        let settings = try XCTUnwrap(storedGLM)
        XCTAssertEqual(settings.sonnetModel, "glm-5.2[1m]")
        try await harness.connect(providerID: .claudeGLM, method: .authToken, secret: "glm-launch-secret")

        let runtime = try await harness.portal.runtimeDefaults(for: .claudeGLM)
        let environment = try await harness.environment.environment(
            for: .claudeCompatible,
            model: "sonnet",
            policy: .init(providerSettings: runtime.providerSettings)
        )
        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], "https://api.z.ai/api/anthropic")
        XCTAssertEqual(environment["ANTHROPIC_AUTH_TOKEN"], "glm-launch-secret")
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertEqual(environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "glm-4.5-air")
        XCTAssertEqual(environment["ANTHROPIC_DEFAULT_SONNET_MODEL"], "glm-5.2[1m]")
        XCTAssertEqual(environment["ANTHROPIC_DEFAULT_OPUS_MODEL"], "glm-5.2[1m]")
        XCTAssertEqual(environment["API_TIMEOUT_MS"], "3000000")
        XCTAssertEqual(environment["CLAUDE_CODE_AUTO_COMPACT_WINDOW"], "1000000")

        let packaging = try ClaudeNativeProviderRuntime.launchPackaging(
            .init(
                kind: .claudeCompatible,
                model: "sonnet",
                prompt: "hello",
                workingDirectory: "/workspace",
                runID: UUID(),
                policy: .init(providerSettings: runtime.providerSettings)
            )
        )
        XCTAssertEqual(modelValue(packaging.arguments), "sonnet")

        let directTurbo = try ClaudeNativeProviderRuntime.launchPackaging(
            .init(
                kind: .claudeCompatible,
                model: "glm-5-turbo:max",
                prompt: "hello",
                workingDirectory: "/workspace",
                runID: UUID(),
                policy: .init(providerSettings: runtime.providerSettings)
            )
        )
        XCTAssertEqual(modelValue(directTurbo.arguments), "sonnet")
        let turboEnv = try await harness.environment.environment(
            for: .claudeCompatible,
            model: "glm-5-turbo:max",
            policy: .init(providerSettings: runtime.providerSettings)
        )
        XCTAssertEqual(turboEnv["ANTHROPIC_DEFAULT_SONNET_MODEL"], "glm-5-turbo")
        XCTAssertNil(turboEnv["CLAUDE_CODE_AUTO_COMPACT_WINDOW"])
        XCTAssertEqual(
            ClaudeCompatibleLaunchResolver.removedEnvironmentKeys(for: settings),
            ["ANTHROPIC_API_KEY"]
        )
    }

    func testCustomDisabledFailClosesEvenWithSecret() async throws {
        let harness = try await Harness.make()
        defer { harness.tearDown() }

        let storedCustom = try await harness.portal.backendSettings(for: .claudeCustom)
        let disabled = try XCTUnwrap(storedCustom)
        XCTAssertFalse(disabled.isEnabled)
        let disabledRuntime = try await harness.portal.runtimeDefaults(for: .claudeCustom)
        XCTAssertNil(disabledRuntime.providerSettings["claude.backendID"])

        try await harness.connect(providerID: .claudeCustom, method: .apiKey, secret: "custom-disabled-secret")
        do {
            _ = try await harness.environment.environment(
                for: .claudeCompatible,
                model: "custom-claude-compatible",
                policy: .init(providerSettings: ["claude.backendID": ProviderSettingsID.claudeCustom.rawValue])
            )
            XCTFail("disabled Custom must not launch")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .providerUnavailable)
            XCTAssertTrue(error.message.contains("invalid backend configuration"))
        }
    }

    func testMissingSecretFailCloses() async throws {
        let harness = try await Harness.make()
        defer { harness.tearDown() }

        let connectionID = UUID()
        let now = Date()
        _ = try await harness.store.upsertProviderConnection(
            .init(
                record: .init(
                    connectionID: connectionID,
                    providerID: .claudeGLM,
                    authenticationMethod: .authToken,
                    state: .connected,
                    lastTestedAt: now,
                    testState: .valid,
                    detail: "Validated",
                    createdAt: now,
                    updatedAt: now,
                    revision: 1
                ),
                credentialReference: connectionID
            ),
            expectedRevision: 0
        )
        let runtime = try await harness.portal.runtimeDefaults(for: .claudeGLM)
        do {
            _ = try await harness.environment.environment(
                for: .claudeCompatible,
                model: "sonnet",
                policy: .init(providerSettings: runtime.providerSettings)
            )
            XCTFail("missing vault secret must fail-close")
        } catch let error as ServiceAPIError {
            XCTAssertTrue([ServiceErrorCode.notFound, .providerUnavailable].contains(error.code))
        }
    }

    func testKimiNoModelDropsModelAndSuppressesEffort() async throws {
        let harness = try await Harness.make()
        defer { harness.tearDown() }

        try await harness.connect(providerID: .claudeKimi, method: .apiKey, secret: "kimi-launch-secret")
        let runtime = try await harness.portal.runtimeDefaults(for: .claudeKimi)
        XCTAssertEqual(runtime.providerSettings["claude.backendModelBehavior"], "noModel")
        XCTAssertFalse(ClaudeCompatibleLaunchResolver.shouldApplyEffort(providerSettings: runtime.providerSettings))

        let environment = try await harness.environment.environment(
            for: .claudeCompatible,
            model: "kimi-code",
            policy: .init(providerSettings: runtime.providerSettings)
        )
        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], "https://api.kimi.com/coding/")
        XCTAssertEqual(environment["ANTHROPIC_API_KEY"], "kimi-launch-secret")
        XCTAssertNil(environment["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"])
        XCTAssertNil(environment["API_TIMEOUT_MS"])

        let packaging = try ClaudeNativeProviderRuntime.launchPackaging(
            .init(
                kind: .claudeCompatible,
                model: "kimi-code",
                prompt: "hello",
                workingDirectory: "/workspace",
                runID: UUID(),
                policy: .init(providerSettings: runtime.providerSettings.merging([
                    "provider.reasoningEffort": "high"
                ]) { _, new in new })
            )
        )
        XCTAssertNil(modelValue(packaging.arguments))

        do {
            _ = try ClaudeNativeProviderRuntime.launchPackaging(
                .init(
                    kind: .claudeCompatible,
                    model: "kimi-code:xhigh",
                    prompt: "hello",
                    workingDirectory: "/workspace",
                    runID: UUID(),
                    policy: .init(providerSettings: runtime.providerSettings)
                )
            )
            XCTFail("noModel backends must reject effort-encoded selections")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .providerUnavailable)
        }
    }

    func testKimiSlotMappingUsesKimiDocumentNotCustom() async throws {
        let harness = try await Harness.make()
        defer { harness.tearDown() }

        _ = try await harness.portal.update(.init(expectedRevision: 0, changes: [
            PortalDesktopSettingKey.claudeCustomEnabled.rawValue: "true",
            PortalDesktopSettingKey.claudeCustomBaseURL.rawValue: "https://custom.example/v1",
            PortalDesktopSettingKey.claudeCustomModelBehavior.rawValue: "claudeSlotMapping",
            PortalDesktopSettingKey.claudeCustomHaikuModel.rawValue: "custom-haiku",
            PortalDesktopSettingKey.claudeCustomSonnetModel.rawValue: "custom-sonnet",
            PortalDesktopSettingKey.claudeCustomOpusModel.rawValue: "custom-opus",
            PortalDesktopSettingKey.claudeKimiModelBehavior.rawValue: "claudeSlotMapping",
            PortalDesktopSettingKey.claudeKimiHaikuModel.rawValue: "kimi-haiku",
            PortalDesktopSettingKey.claudeKimiSonnetModel.rawValue: "kimi-sonnet",
            PortalDesktopSettingKey.claudeKimiOpusModel.rawValue: "kimi-opus"
        ]))
        try await harness.connect(providerID: .claudeKimi, method: .apiKey, secret: "kimi-slot-secret")

        let runtime = try await harness.portal.runtimeDefaults(for: .claudeKimi)
        XCTAssertEqual(runtime.providerSettings["claude.backendHaikuModel"], "kimi-haiku")
        XCTAssertNotEqual(runtime.providerSettings["claude.backendHaikuModel"], "custom-haiku")

        let environment = try await harness.environment.environment(
            for: .claudeCompatible,
            model: "kimi-haiku",
            policy: .init(providerSettings: runtime.providerSettings)
        )
        XCTAssertEqual(environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "kimi-haiku")
        XCTAssertEqual(environment["ANTHROPIC_DEFAULT_SONNET_MODEL"], "kimi-sonnet")
        XCTAssertEqual(environment["ANTHROPIC_DEFAULT_OPUS_MODEL"], "kimi-opus")
        XCTAssertEqual(environment["ANTHROPIC_API_KEY"], "kimi-slot-secret")

        let packaging = try ClaudeNativeProviderRuntime.launchPackaging(
            .init(
                kind: .claudeCompatible,
                model: "kimi-haiku",
                prompt: "hello",
                workingDirectory: "/workspace",
                runID: UUID(),
                policy: .init(providerSettings: runtime.providerSettings)
            )
        )
        XCTAssertEqual(modelValue(packaging.arguments), "haiku")
        XCTAssertTrue(ClaudeCompatibleLaunchResolver.shouldApplyEffort(providerSettings: runtime.providerSettings))
    }

    private func modelValue(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--model"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private struct Harness {
    let directory: URL
    let store: SQLiteServiceStore
    let vault: ProviderCredentialVault
    let portal: PortalDesktopSettingsService
    let environment: VaultProviderProcessEnvironment

    static func make() async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let vault = try ProviderCredentialVault(
            fileURL: directory.appendingPathComponent("provider.vault"),
            activeKey: .init(keyID: "test", material: Data(repeating: 7, count: 32))
        )
        let portal = PortalDesktopSettingsService(store: store)
        let environment = VaultProviderProcessEnvironment(store: store, vault: vault, backendSettings: portal)
        return Harness(directory: directory, store: store, vault: vault, portal: portal, environment: environment)
    }

    func connect(providerID: ProviderSettingsID, method: ProviderAuthenticationMethod, secret: String) async throws {
        let connectionID = UUID()
        let now = Date()
        try await vault.store(secret: Data(secret.utf8), providerID: providerID, connectionID: connectionID)
        _ = try await store.upsertProviderConnection(
            .init(
                record: .init(
                    connectionID: connectionID,
                    providerID: providerID,
                    authenticationMethod: method,
                    state: .connected,
                    lastTestedAt: now,
                    testState: .valid,
                    detail: "Validated",
                    createdAt: now,
                    updatedAt: now,
                    revision: 1
                ),
                credentialReference: connectionID
            ),
            expectedRevision: 0
        )
    }

    func tearDown() {
        Task { try? await store.close() }
        try? FileManager.default.removeItem(at: directory)
    }
}
