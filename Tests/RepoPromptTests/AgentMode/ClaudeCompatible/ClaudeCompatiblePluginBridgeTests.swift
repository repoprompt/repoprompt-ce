import Foundation
@testable import RepoPromptApp
import XCTest

final class ClaudeCompatiblePluginBridgeTests: XCTestCase {
    func testBridgeRuntimeSmokeMapsPluginIDsDiscoveryRuntimeAndHeadlessAdapters() throws {
        let cases: [(AgentProviderKind, String)] = [
            (.claudeCode, "claude-code"),
            (.claudeCodeGLM, "zai-claude-code"),
            (.kimiCode, "kimi-claude-code"),
            (.customClaudeCompatible, "custom-claude-compatible")
        ]

        for (agentKind, expectedPluginID) in cases {
            XCTAssertEqual(ClaudeCompatiblePluginBridge.pluginID(for: agentKind)?.rawValue, expectedPluginID)
            XCTAssertEqual(try ClaudeCompatiblePluginBridge.agentKind(for: XCTUnwrap(ClaudeCompatiblePluginBridge.pluginID(for: agentKind))), agentKind)

            let provider = AgentRuntimeProviderService.shared.makeProvider(
                for: agentKind,
                modelString: "sonnet"
            )
            let adapter = try XCTUnwrap(provider as? ClaudeCompatibleHeadlessProviderAdapter)
            XCTAssertEqual(adapter.runtimeConfig.pluginID.rawValue, expectedPluginID)
            XCTAssertEqual(adapter.runtimeConfig.mode.rawValue, "discovery")
            XCTAssertEqual(adapter.runtimeConfig.commandName, "claude")
            XCTAssertEqual(adapter.runtimeConfig.modelString, "sonnet")
        }
        XCTAssertNil(ClaudeCompatiblePluginBridge.pluginID(for: .codexExec))

        let config = try XCTUnwrap(ClaudeCompatiblePluginBridge.discoveryRuntimeConfig(
            agentKind: .claudeCodeGLM,
            modelString: "sonnet",
            enableDebugLogging: true
        ))
        XCTAssertEqual(config.pluginID.rawValue, "zai-claude-code")
        XCTAssertEqual(config.mode.rawValue, "discovery")
        XCTAssertEqual(config.commandName, "claude")
        XCTAssertEqual(config.permissionMode, "bypassPermissions")
        XCTAssertFalse(config.allowNativeBashTool)
        XCTAssertEqual(config.toolContext.rawValue, "discoverRun")
        XCTAssertTrue(config.mcpStrictMode)
        XCTAssertFalse(config.toolSearchEnabled)
        XCTAssertEqual(config.backendConfig?.id.rawValue, "glmZAI")
    }

    func testGLMOldDefaultSlotMappingMigratesOnConfigLookup() throws {
        let defaults = try makeIsolatedDefaults()
        let store = ClaudeCodeCompatibleBackendStore(defaults: defaults)
        let updatedAt = Date(timeIntervalSince1970: 1_703_000_000)
        let oldConfig = oldGLMDefaultConfig(updatedAt: updatedAt)
        try persistConfigs([.glmZAI: oldConfig], defaults: defaults)

        let migrated = store.config(for: .glmZAI)

        XCTAssertEqual(migrated.modelBehavior, ClaudeCodeCompatibleBackendID.glmZAI.defaultPreset.modelBehavior)
        XCTAssertEqual(migrated.id, oldConfig.id)
        XCTAssertEqual(migrated.isEnabled, oldConfig.isEnabled)
        XCTAssertEqual(migrated.displayName, oldConfig.displayName)
        XCTAssertEqual(migrated.baseURL, oldConfig.baseURL)
        XCTAssertEqual(migrated.auth, oldConfig.auth)
        XCTAssertEqual(migrated.updatedAt, updatedAt)

        let persisted = try loadPersistedConfig(for: .glmZAI, defaults: defaults)
        XCTAssertEqual(persisted, migrated)

        let secondRead = store.config(for: .glmZAI)
        XCTAssertEqual(secondRead, migrated)
        XCTAssertEqual(secondRead.updatedAt, updatedAt)
    }

    func testGLMPartialLegacySlotMappingMigratesUntouchedSlotsOnly() throws {
        let defaults = try makeIsolatedDefaults()
        let store = ClaudeCodeCompatibleBackendStore(defaults: defaults)
        var partiallyCustomized = oldGLMDefaultConfig()
        partiallyCustomized.modelBehavior = .claudeSlotMapping(.init(
            haiku: "glm-4.7",
            sonnet: "glm-5-turbo",
            opus: "custom-opus"
        ))
        try persistConfigs([.glmZAI: partiallyCustomized], defaults: defaults)

        var expected = partiallyCustomized
        expected.modelBehavior = .claudeSlotMapping(.init(
            haiku: "glm-4.5-air",
            sonnet: "glm-5.2[1m]",
            opus: "custom-opus"
        ))

        XCTAssertEqual(store.config(for: .glmZAI), expected)
        XCTAssertEqual(try loadPersistedConfig(for: .glmZAI, defaults: defaults), expected)
    }

    func testGLMFullyCustomSlotMappingDoesNotMigrate() throws {
        let defaults = try makeIsolatedDefaults()
        let store = ClaudeCodeCompatibleBackendStore(defaults: defaults)
        var customized = oldGLMDefaultConfig()
        customized.modelBehavior = .claudeSlotMapping(.init(
            haiku: "custom-haiku",
            sonnet: "custom-sonnet",
            opus: "custom-opus"
        ))
        try persistConfigs([.glmZAI: customized], defaults: defaults)

        XCTAssertEqual(store.config(for: .glmZAI), customized)
        XCTAssertEqual(try loadPersistedConfig(for: .glmZAI, defaults: defaults), customized)
    }

    func testGLMMigrationDoesNotAffectNonGLMConfigs() throws {
        let defaults = try makeIsolatedDefaults()
        let store = ClaudeCodeCompatibleBackendStore(defaults: defaults)
        let custom = ClaudeCodeCompatibleBackendConfig(
            id: .custom,
            isEnabled: true,
            displayName: "Custom old-looking GLM",
            baseURL: "https://custom.example.test/anthropic",
            auth: .anthropicAPIKey,
            modelBehavior: .claudeSlotMapping(.init(
                haiku: "glm-4.7",
                sonnet: "glm-5-turbo",
                opus: "glm-5.1"
            )),
            updatedAt: Date(timeIntervalSince1970: 1_704_000_000)
        )
        let kimi = ClaudeCodeCompatibleBackendConfig(
            id: .kimi,
            isEnabled: true,
            displayName: "Moonshot",
            baseURL: "https://api.kimi.com/coding/",
            auth: .anthropicAPIKey,
            modelBehavior: .noModel,
            updatedAt: Date(timeIntervalSince1970: 1_705_000_000)
        )
        try persistConfigs([.custom: custom, .kimi: kimi], defaults: defaults)

        XCTAssertEqual(store.config(for: .custom), custom)
        XCTAssertEqual(store.config(for: .kimi), kimi)
        XCTAssertEqual(try loadPersistedConfig(for: .custom, defaults: defaults), custom)
        XCTAssertEqual(try loadPersistedConfig(for: .kimi, defaults: defaults), kimi)
    }

    func testGLMCompatibleBackendPickerLabelsSlotsAndLegacyChoicesDistinctly() throws {
        let restore = installTemporaryOldGLMDefaultSlotMapping()
        defer { restore() }

        let models = ClaudeCodeAIModelCatalog.compatibleBackendModelsForPicker(.glmZAI)
        let menu = AIModel.claudeCodeMenu(for: models)
        let group = try XCTUnwrap(menu.groups.first { $0.baseModelRaw == "compatible:glmzai" })

        XCTAssertEqual(group.displayName, "Saved CC Zai")
        XCTAssertEqual(group.options.map(\.displayName), [
            "GLM 4.5 Air — Haiku",
            "GLM 5.2 (1M) — Sonnet",
            "GLM 5.2 (1M) — Opus",
            "GLM 4.7",
            "GLM 5 Turbo",
            "GLM 5.1"
        ])
    }

    /// XHigh eligibility is declared in three places: the provider package's
    /// per-model effort lists (read here through the adapter snapshot), the
    /// adapter's eligibility set, and the AI picker's model definitions. This
    /// guards against the hand-synced copies drifting apart.
    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "ClaudeCompatiblePluginBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func oldGLMDefaultConfig(updatedAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)) -> ClaudeCodeCompatibleBackendConfig {
        ClaudeCodeCompatibleBackendConfig(
            id: .glmZAI,
            isEnabled: false,
            displayName: "Saved CC Zai",
            baseURL: "https://saved.example.test/api/anthropic",
            auth: .anthropicAPIKey,
            modelBehavior: .claudeSlotMapping(.init(
                haiku: "glm-4.7",
                sonnet: "glm-5-turbo",
                opus: "glm-5.1"
            )),
            updatedAt: updatedAt
        )
    }

    private func persistConfigs(
        _ configs: [ClaudeCodeCompatibleBackendID: ClaudeCodeCompatibleBackendConfig],
        defaults: UserDefaults
    ) throws {
        let keyedConfigs = Dictionary(uniqueKeysWithValues: configs.map { ($0.key.rawValue, $0.value) })
        let data = try JSONEncoder().encode(keyedConfigs)
        defaults.set(data, forKey: ClaudeCodeCompatibleBackendStore.configsDefaultsKey)
    }

    private func loadPersistedConfig(
        for id: ClaudeCodeCompatibleBackendID,
        defaults: UserDefaults
    ) throws -> ClaudeCodeCompatibleBackendConfig {
        let data = try XCTUnwrap(defaults.data(forKey: ClaudeCodeCompatibleBackendStore.configsDefaultsKey))
        let configs = try JSONDecoder().decode([String: ClaudeCodeCompatibleBackendConfig].self, from: data)
        return try XCTUnwrap(configs[id.rawValue])
    }

    private func installTemporaryOldGLMDefaultSlotMapping() -> () -> Void {
        let defaults = UserDefaults.standard
        let store = ClaudeCodeCompatibleBackendStore.shared
        let configsKey = ClaudeCodeCompatibleBackendStore.configsDefaultsKey
        let configuredKey = store.configuredDefaultsKey(for: .glmZAI)
        let legacyConfiguredKey = ClaudeCodeGLMIntegration.configuredDefaultsKey
        let previousConfigs = defaults.data(forKey: configsKey)
        let previousConfigured = defaults.object(forKey: configuredKey)
        let previousLegacyConfigured = defaults.object(forKey: legacyConfiguredKey)

        try? persistConfigs([.glmZAI: oldGLMDefaultConfig()], defaults: defaults)
        _ = store.setConfigured(true, for: .glmZAI)

        return {
            if let previousConfigs {
                defaults.set(previousConfigs, forKey: configsKey)
            } else {
                defaults.removeObject(forKey: configsKey)
            }
            if let previousConfigured {
                defaults.set(previousConfigured, forKey: configuredKey)
            } else {
                defaults.removeObject(forKey: configuredKey)
            }
            if let previousLegacyConfigured {
                defaults.set(previousLegacyConfigured, forKey: legacyConfiguredKey)
            } else {
                defaults.removeObject(forKey: legacyConfiguredKey)
            }
        }
    }

    private func installTemporaryCustomSlotMapping() -> () -> Void {
        let defaults = UserDefaults.standard
        let store = ClaudeCodeCompatibleBackendStore.shared
        let configsKey = ClaudeCodeCompatibleBackendStore.configsDefaultsKey
        let configuredKey = store.configuredDefaultsKey(for: .custom)
        let previousConfigs = defaults.data(forKey: configsKey)
        let previousConfigured = defaults.object(forKey: configuredKey)

        store.saveConfig(ClaudeCodeCompatibleBackendConfig(
            id: .custom,
            isEnabled: true,
            displayName: "CC Custom GLM",
            baseURL: "https://example.test/anthropic",
            auth: .anthropicAPIKey,
            modelBehavior: .claudeSlotMapping(.init(
                haiku: "custom-fast",
                sonnet: "glm-5.2[1m]",
                opus: "glm-5.2"
            ))
        ))
        _ = store.setConfigured(true, for: .custom)

        return {
            if let previousConfigs {
                defaults.set(previousConfigs, forKey: configsKey)
            } else {
                defaults.removeObject(forKey: configsKey)
            }
            if let previousConfigured {
                defaults.set(previousConfigured, forKey: configuredKey)
            } else {
                defaults.removeObject(forKey: configuredKey)
            }
        }
    }
}
