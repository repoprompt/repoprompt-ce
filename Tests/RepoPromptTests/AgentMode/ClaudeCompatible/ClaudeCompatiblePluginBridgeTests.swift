import Foundation
@testable import RepoPrompt
import XCTest

final class ClaudeCompatiblePluginBridgeTests: XCTestCase {
    func testOnlyBridgeImportsProviderPackage() throws {
        let repoRoot = try RepoRoot.url()
        let sourcesRoot = repoRoot.appendingPathComponent("Sources/RepoPrompt", isDirectory: true)
        let expected = "Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/ClaudeCompatibleProviderRuntimeBridge.swift"
        let imports = try sourceFilesImportingProviderPackage(under: sourcesRoot, repoRoot: repoRoot)

        XCTAssertEqual(imports, [expected])
    }

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

    func testRootBridgeCatalogRawValueSmokeIsNonMutating() throws {
        XCTAssertEqual(ClaudeCompatibleProviderRuntimeBridge.noModelRawValue(for: .glmZAI), AgentModel.claudeSonnet.rawValue)
        XCTAssertEqual(ClaudeCompatibleProviderRuntimeBridge.noModelRawValue(for: .kimi), AgentModel.kimiCode.rawValue)
        XCTAssertEqual(ClaudeCompatibleProviderRuntimeBridge.noModelRawValue(for: .custom), AgentModel.customClaudeCompatible.rawValue)
        XCTAssertEqual(ClaudeCodeGLMIntegration.defaultRequestedModelRawValue, AgentModel.claudeSonnet.rawValue)
        XCTAssertEqual(ClaudeCodeGLMIntegration.haikuRequestedModelRawValue, AgentModel.claudeHaiku.rawValue)
        XCTAssertEqual(ClaudeCodeGLMIntegration.opusRequestedModelRawValue, AgentModel.claudeOpus.rawValue)
        XCTAssertEqual(ClaudeCodeGLMIntegration.haikuEquivalentModelRawValue, "glm-4.5-air")
        XCTAssertEqual(ClaudeCodeGLMIntegration.defaultModelRawValue, "glm-5.2[1m]")
        XCTAssertEqual(ClaudeCodeGLMIntegration.opusEquivalentModelRawValue, "glm-5.2[1m]")
        XCTAssertEqual(ClaudeCodeGLMIntegration.normalizedGLMModel("glm-4.7"), AgentModel.claudeHaiku.rawValue)
        XCTAssertEqual(ClaudeCodeGLMIntegration.normalizedGLMModel("glm-5.2"), AgentModel.claudeSonnet.rawValue)
        XCTAssertEqual(ClaudeCodeGLMIntegration.normalizedGLMModel("glm-5.2[1m]"), AgentModel.claudeSonnet.rawValue)
        XCTAssertEqual(ClaudeCodeGLMIntegration.normalizedGLMModel("glm-5-turbo"), AgentModel.claudeSonnet.rawValue)
        XCTAssertEqual(ClaudeCodeGLMIntegration.normalizedGLMModel("glm-5.1"), AgentModel.claudeOpus.rawValue)

        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            zaiConfigured: true,
            kimiConfigured: true,
            customClaudeCompatibleConfigured: true
        )
        let snapshot = try XCTUnwrap(ClaudeCompatibleModelCatalogAdapter.catalogSnapshot(
            for: .claudeCode,
            availability: availability,
            includeClaudeEffortVariants: false
        ))
        XCTAssertEqual(snapshot.pluginID.rawValue, "claude-code")
        XCTAssertEqual(snapshot.defaultModelRaw, "opus")
        XCTAssertEqual(snapshot.options.first?.rawValue, "default")
        XCTAssertEqual(snapshot.options.first?.isPlaceholderDefault, true)
        XCTAssertTrue(snapshot.options.contains { $0.rawValue == "claude-fable-5" && $0.supportedEffortLevels.contains("xhigh") })
        XCTAssertTrue(snapshot.options.contains { $0.rawValue == "opus" && $0.supportedEffortLevels.contains("xhigh") })
        let sonnet5BaseOption = try XCTUnwrap(snapshot.options.first { $0.rawValue == "claude-sonnet-5" })
        XCTAssertEqual(sonnet5BaseOption.displayName, "Sonnet 5")
        XCTAssertEqual(sonnet5BaseOption.supportedEffortLevels, ["low", "medium", "high", "max", "xhigh"])

        let options = AgentModelCatalog.options(for: .claudeCode, availability: availability)
        let menu = AgentModelCatalog.claudeMenu(for: options, agentKind: .claudeCode)
        XCTAssertEqual(AgentModelCatalog.defaultModelRaw(for: .claudeCode, availability: availability), "opus")
        XCTAssertEqual(menu.defaultOption?.rawValue, "default")
        let groupRaws = Set(menu.groups.map(\.baseModelRaw))
        XCTAssertTrue(groupRaws.contains("claude-fable-5"))
        XCTAssertTrue(groupRaws.contains("opus[1m]"))
        XCTAssertTrue(groupRaws.contains("opus"))
        XCTAssertTrue(groupRaws.contains("sonnet"))
        XCTAssertTrue(groupRaws.contains("claude-sonnet-5"))
        let sonnet5Group = try XCTUnwrap(menu.groups.first { $0.baseModelRaw == "claude-sonnet-5" })
        XCTAssertEqual(sonnet5Group.displayName, "Sonnet 5")
        XCTAssertEqual(sonnet5Group.options.map(\.rawValue), [
            "claude-sonnet-5:low",
            "claude-sonnet-5:medium",
            "claude-sonnet-5:high",
            "claude-sonnet-5:max",
            "claude-sonnet-5:xhigh"
        ])
        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "claude-sonnet-5", for: .claudeCode, availability: availability))
        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "claude-sonnet-5:max", for: .claudeCode, availability: availability))
        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "claude-sonnet-5:xhigh", for: .claudeCode, availability: availability))

        let discovery = try XCTUnwrap(AgentModelCatalog.discoveryAgents(availability: availability).first { $0.agent == .claudeCode })
        XCTAssertEqual(discovery.defaults.modelRaw, "opus")
        XCTAssertEqual(discovery.defaults.selectionID?.rawValue, "claudeCode:opus")
        XCTAssertEqual(discovery.runtime, "claude_native")
        XCTAssertTrue(discovery.models.contains { $0.id == "default" })
        XCTAssertTrue(discovery.models.contains { $0.id == "claude-fable-5" && $0.contextWindowTokens == 1_000_000 })
        XCTAssertTrue(discovery.models.contains { $0.id == "opus" })
        let sonnet5Discovery = try XCTUnwrap(discovery.models.first { $0.id == "claude-sonnet-5" })
        XCTAssertEqual(sonnet5Discovery.contextWindowTokens, 1_000_000)
        XCTAssertTrue(sonnet5Discovery.tags.contains(.balanced))
        XCTAssertTrue(sonnet5Discovery.tags.contains(.extendedContext))
        XCTAssertEqual(
            sonnet5Discovery.startTargets.first { $0.modelRaw == "claude-sonnet-5:xhigh" }?.contextWindowTokens,
            1_000_000
        )
        XCTAssertEqual(
            sonnet5Discovery.startTargets.first { $0.modelRaw == "claude-sonnet-5:max" }?.contextWindowTokens,
            1_000_000
        )

        let glmBaseSnapshot = try XCTUnwrap(ClaudeCompatibleModelCatalogAdapter.catalogSnapshot(
            for: .claudeCodeGLM,
            availability: availability,
            includeClaudeEffortVariants: false
        ))
        XCTAssertEqual(glmBaseSnapshot.defaultModelRaw, AgentModel.claudeSonnet.rawValue)
        XCTAssertEqual(glmBaseSnapshot.options.first { $0.rawValue == "sonnet" }?.displayName, "GLM 5.2 (1M) — Sonnet")
        XCTAssertEqual(glmBaseSnapshot.options.first { $0.rawValue == "opus" }?.displayName, "GLM 5.2 (1M) — Opus")
        XCTAssertTrue(glmBaseSnapshot.options.contains { $0.rawValue == "glm-4.7" && $0.displayName == "GLM 4.7" })
        XCTAssertTrue(glmBaseSnapshot.options.contains { $0.rawValue == "glm-5-turbo" && $0.displayName == "GLM 5 Turbo" })
        XCTAssertTrue(glmBaseSnapshot.options.contains { $0.rawValue == "glm-5.1" && $0.displayName == "GLM 5.1" })

        let glmSnapshot = try XCTUnwrap(ClaudeCompatibleModelCatalogAdapter.catalogSnapshot(
            for: .claudeCodeGLM,
            availability: availability,
            includeClaudeEffortVariants: true
        ))
        XCTAssertTrue(glmSnapshot.options.contains { $0.rawValue == "sonnet:xhigh" })
        XCTAssertTrue(glmSnapshot.options.contains { $0.rawValue == "opus:xhigh" })
        XCTAssertTrue(glmSnapshot.options.contains { $0.rawValue == "glm-4.7:max" })
        XCTAssertTrue(glmSnapshot.options.contains { $0.rawValue == "glm-5-turbo:max" })
        XCTAssertTrue(glmSnapshot.options.contains { $0.rawValue == "glm-5.1:max" })
        XCTAssertFalse(glmSnapshot.options.contains { $0.rawValue == "haiku:xhigh" })
        XCTAssertFalse(glmSnapshot.options.contains { $0.rawValue == "glm-4.7:xhigh" })
        XCTAssertFalse(glmSnapshot.options.contains { $0.rawValue == "glm-5-turbo:xhigh" })
        XCTAssertFalse(glmSnapshot.options.contains { $0.rawValue == "glm-5.1:xhigh" })
        XCTAssertEqual(ClaudeCompatibleModelCatalogAdapter.canonicalClaudeGLMModelRaw("glm-5-turbo"), "glm-5-turbo")
        XCTAssertEqual(ClaudeCompatibleModelCatalogAdapter.canonicalClaudeGLMModelRaw("glm-5.1:max"), "glm-5.1:max")
        XCTAssertEqual(ClaudeCompatibleModelCatalogAdapter.canonicalClaudeGLMModelRaw("glm-4.7"), "glm-4.7")
        XCTAssertEqual(ClaudeCompatibleModelCatalogAdapter.canonicalClaudeGLMModelRaw("glm-5.2"), AgentModel.claudeSonnet.rawValue)
        XCTAssertEqual(
            ClaudeCompatibleModelCatalogAdapter.contextWindowTokens(
                forRequestedModelRaw: "sonnet:xhigh",
                agentKind: .claudeCodeGLM
            ),
            1_000_000
        )
        XCTAssertTrue(ClaudeCompatibleModelCatalogAdapter.isValid(
            rawModel: "glm-5-turbo:max",
            for: .claudeCodeGLM,
            availability: availability
        ) ?? false)
        XCTAssertFalse(ClaudeCompatibleModelCatalogAdapter.isValid(
            rawModel: "glm-5-turbo:xhigh",
            for: .claudeCodeGLM,
            availability: availability
        ) ?? true)
        XCTAssertTrue(ClaudeCompatibleModelCatalogAdapter.isValid(
            rawModel: "glm-5.1",
            for: .claudeCodeGLM,
            availability: availability
        ) ?? false)
        XCTAssertFalse(ClaudeCompatibleModelCatalogAdapter.isValid(
            rawModel: "glm-5.1:xhigh",
            for: .claudeCodeGLM,
            availability: availability
        ) ?? true)
        XCTAssertFalse(AgentModelCatalog.modelOptionIsSelected(
            optionRaw: "glm-5-turbo",
            selectedRaw: AgentModel.claudeSonnet.rawValue,
            agentKind: .claudeCodeGLM
        ))
        XCTAssertFalse(AgentModelCatalog.modelOptionIsSelected(
            optionRaw: "glm-5.1",
            selectedRaw: AgentModel.claudeOpus.rawValue,
            agentKind: .claudeCodeGLM
        ))
        XCTAssertTrue(ClaudeCompatibleModelCatalogAdapter.claudeEffort(
            .xhigh,
            isSupportedForBaseModelRaw: AgentModel.claudeSonnet.rawValue,
            agentKind: .claudeCodeGLM
        ))
        XCTAssertFalse(ClaudeCompatibleModelCatalogAdapter.claudeEffort(
            .xhigh,
            isSupportedForBaseModelRaw: AgentModel.claudeHaiku.rawValue,
            agentKind: .claudeCodeGLM
        ))
        XCTAssertFalse(ClaudeCompatibleModelCatalogAdapter.claudeEffort(
            .xhigh,
            isSupportedForBaseModelRaw: AgentModel.kimiCode.rawValue,
            agentKind: .kimiCode
        ))
        XCTAssertFalse(ClaudeCompatibleModelCatalogAdapter.claudeEffort(
            .xhigh,
            isSupportedForBaseModelRaw: AgentModel.customClaudeCompatible.rawValue,
            agentKind: .customClaudeCompatible
        ))

        let compatiblePluginOptions = [
            ClaudeCompatiblePluginModelOption(
                rawValue: AgentModel.claudeSonnet.rawValue,
                displayName: "GLM Sonnet",
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: true,
                supportedEffortLevels: ["low", "medium", "high", "max"]
            ),
            ClaudeCompatiblePluginModelOption(
                rawValue: AgentModel.kimiCode.rawValue,
                displayName: "Kimi Code",
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: true,
                supportedEffortLevels: []
            ),
            ClaudeCompatiblePluginModelOption(
                rawValue: AgentModel.customClaudeCompatible.rawValue,
                displayName: "CC Custom",
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: true,
                supportedEffortLevels: []
            )
        ]
        XCTAssertEqual(
            ClaudeCompatibleModelCatalogAdapter.modelOptions(from: [compatiblePluginOptions[0]], for: .claudeCodeGLM).map(\.rawValue),
            [AgentModel.claudeSonnet.rawValue]
        )
        XCTAssertEqual(
            ClaudeCompatibleModelCatalogAdapter.modelOptions(from: [compatiblePluginOptions[1]], for: .kimiCode).map(\.rawValue),
            [AgentModel.kimiCode.rawValue]
        )
        XCTAssertEqual(
            ClaudeCompatibleModelCatalogAdapter.modelOptions(from: [compatiblePluginOptions[2]], for: .customClaudeCompatible).map(\.rawValue),
            [AgentModel.customClaudeCompatible.rawValue]
        )
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

    func testGLMOldDefaultSlotMappingMigratesBeforeCatalogOptions() throws {
        let restore = installTemporaryOldGLMDefaultSlotMapping()
        defer { restore() }

        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            zaiConfigured: true
        )
        let baseSnapshot = try XCTUnwrap(ClaudeCompatibleModelCatalogAdapter.catalogSnapshot(
            for: .claudeCodeGLM,
            availability: availability,
            includeClaudeEffortVariants: false
        ))
        let snapshot = try XCTUnwrap(ClaudeCompatibleModelCatalogAdapter.catalogSnapshot(
            for: .claudeCodeGLM,
            availability: availability,
            includeClaudeEffortVariants: true
        ))

        XCTAssertEqual(baseSnapshot.defaultModelRaw, AgentModel.claudeSonnet.rawValue)
        XCTAssertTrue(snapshot.options.contains { $0.rawValue == "sonnet:xhigh" })
        XCTAssertTrue(snapshot.options.contains { $0.rawValue == "opus:xhigh" })
        XCTAssertTrue(baseSnapshot.options.contains { $0.rawValue == "glm-4.7" && $0.displayName == "GLM 4.7" })
        XCTAssertTrue(baseSnapshot.options.contains { $0.rawValue == "glm-5-turbo" && $0.displayName == "GLM 5 Turbo" })
        XCTAssertTrue(baseSnapshot.options.contains { $0.rawValue == "glm-5.1" && $0.displayName == "GLM 5.1" })
        XCTAssertTrue(baseSnapshot.options.contains { $0.rawValue == "sonnet" && $0.displayName == "GLM 5.2 (1M) — Sonnet" })
        XCTAssertTrue(baseSnapshot.options.contains { $0.rawValue == "opus" && $0.displayName == "GLM 5.2 (1M) — Opus" })
        XCTAssertEqual(
            ClaudeCompatibleModelCatalogAdapter.contextWindowTokens(
                forRequestedModelRaw: "sonnet:xhigh",
                agentKind: .claudeCodeGLM
            ),
            1_000_000
        )
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

    func testCustomSlotMappingUsesBackendModelIDForXHighAndContextSupport() throws {
        let restore = installTemporaryCustomSlotMapping()
        defer { restore() }

        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            customClaudeCompatibleConfigured: true
        )
        let snapshot = try XCTUnwrap(ClaudeCompatibleModelCatalogAdapter.catalogSnapshot(
            for: .customClaudeCompatible,
            availability: availability,
            includeClaudeEffortVariants: true
        ))
        XCTAssertTrue(snapshot.options.contains { $0.rawValue == "sonnet:xhigh" })
        XCTAssertTrue(snapshot.options.contains { $0.rawValue == "opus:xhigh" })
        XCTAssertFalse(snapshot.options.contains { $0.rawValue == "haiku:xhigh" })
        XCTAssertEqual(
            ClaudeCompatibleModelCatalogAdapter.contextWindowTokens(
                forRequestedModelRaw: "sonnet:xhigh",
                agentKind: .customClaudeCompatible
            ),
            1_000_000
        )
        XCTAssertNil(ClaudeCompatibleModelCatalogAdapter.contextWindowTokens(
            forRequestedModelRaw: "opus:xhigh",
            agentKind: .customClaudeCompatible
        ))
        XCTAssertTrue(ClaudeCompatibleModelCatalogAdapter.claudeEffort(
            .xhigh,
            isSupportedForBaseModelRaw: AgentModel.claudeSonnet.rawValue,
            agentKind: .customClaudeCompatible
        ))
        XCTAssertFalse(ClaudeCompatibleModelCatalogAdapter.claudeEffort(
            .xhigh,
            isSupportedForBaseModelRaw: AgentModel.claudeHaiku.rawValue,
            agentKind: .customClaudeCompatible
        ))
        XCTAssertFalse(ClaudeCompatibleModelCatalogAdapter.claudeEffort(
            .xhigh,
            isSupportedForBaseModelRaw: AgentModel.kimiCode.rawValue,
            agentKind: .kimiCode
        ))
    }

    /// XHigh eligibility is declared in three places: the provider package's
    /// per-model effort lists (read here through the adapter snapshot), the
    /// adapter's eligibility set, and the AI picker's model definitions. This
    /// guards against the hand-synced copies drifting apart.
    func testClaudeXHighEligibilityIsConsistentAcrossCatalogSurfaces() throws {
        let availability = AgentModelCatalog.AvailabilityContext(claudeCodeAvailable: true)
        let snapshot = try XCTUnwrap(ClaudeCompatibleModelCatalogAdapter.catalogSnapshot(
            for: .claudeCode,
            availability: availability,
            includeClaudeEffortVariants: false
        ))

        var pickerBaseRaws: Set<String> = []
        var pickerXHighBaseRaws: Set<String> = []
        for model in ClaudeCodeAIModelCatalog.modelsForPicker() {
            guard let raw = ClaudeCodeAIModelCatalog.runtimeSpecifierRaw(for: model) else { continue }
            let specifier = ClaudeModelSpecifier(raw: raw)
            guard let base = specifier.baseModel?.lowercased() else { continue }
            pickerBaseRaws.insert(base)
            if specifier.explicitEffortLevel == .xhigh {
                pickerXHighBaseRaws.insert(base)
            }
        }

        var comparedPickerRaws = 0
        for option in snapshot.options where !option.isPlaceholderDefault {
            let base = option.rawValue.lowercased()
            let providerXHigh = option.supportedEffortLevels.contains("xhigh")
            let adapterXHigh = ClaudeCompatibleModelCatalogAdapter.claudeEffort(
                .xhigh,
                isSupportedForBaseModelRaw: option.rawValue,
                agentKind: .claudeCode
            )
            XCTAssertEqual(
                providerXHigh,
                adapterXHigh,
                "XHigh eligibility for \(option.rawValue) drifted between the provider catalog and the adapter"
            )
            guard pickerBaseRaws.contains(base) else { continue }
            comparedPickerRaws += 1
            XCTAssertEqual(
                providerXHigh,
                pickerXHighBaseRaws.contains(base),
                "XHigh exposure for \(option.rawValue) drifted between the provider catalog and the AI picker"
            )
        }
        XCTAssertGreaterThanOrEqual(
            comparedPickerRaws,
            6,
            "AI picker shares too few base raws with the provider catalog; the consistency check lost coverage"
        )
    }

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

    private func sourceFilesImportingProviderPackage(
        under sourcesRoot: URL,
        repoRoot: URL
    ) throws -> [String] {
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var imports: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }
            let contents = try String(contentsOf: url, encoding: .utf8)
            guard contents.contains("import RepoPromptClaudeCompatibleProvider") else { continue }
            imports.append(RepoRoot.relativePath(for: url, relativeTo: repoRoot))
        }
        return imports.sorted()
    }
}
