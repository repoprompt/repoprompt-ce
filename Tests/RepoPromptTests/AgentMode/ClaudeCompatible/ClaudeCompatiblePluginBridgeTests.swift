import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptSettingsCore
import XCTest

final class ClaudeCompatiblePluginBridgeTests: XCTestCase {
    @MainActor
    func testCustomRequestLimitsSurviveStoreAndRuntimeBridge() throws {
        let defaults = try makeIsolatedDefaults()
        let store = ClaudeCodeCompatibleBackendStore(defaults: defaults)
        var config = ClaudeCodeCompatibleBackendID.custom.defaultPreset
        config.baseURL = "http://127.0.0.1:8000"
        config.requestTimeoutMilliseconds = 600_000
        config.contextWindowTokens = 262_144
        store.saveConfig(config)
        let restored = ClaudeCodeCompatibleBackendStore(defaults: defaults).config(for: .custom)
        XCTAssertTrue(restored.isValid)
        let environment = try ClaudeCompatibleProviderRuntimeBridge.backendEnvironment(config: restored, apiKey: "dummy")
        XCTAssertEqual(environment["API_TIMEOUT_MS"], "600000")
        XCTAssertEqual(environment["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "262144")
        XCTAssertNil(environment["CLAUDE_CODE_AUTO_COMPACT_WINDOW"])
        config.contextWindowTokens = 0
        XCTAssertFalse(config.isValid)
        config.contextWindowTokens = nil
        config.requestTimeoutMilliseconds = -1
        XCTAssertFalse(config.isValid)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        legacy.removeValue(forKey: "contextWindowTokens")
        legacy.removeValue(forKey: "requestTimeoutMilliseconds")
        let decoded = try JSONDecoder().decode(ClaudeCodeCompatibleBackendConfig.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.contextWindowTokens)
        XCTAssertNil(decoded.requestTimeoutMilliseconds)
        XCTAssertTrue(decoded.isValid)
        for timeout in [600, 999, Int(Int32.max) + 1] {
            config.requestTimeoutMilliseconds = timeout
            XCTAssertFalse(config.isValid)
        }

        let restore = installTemporaryCustomSlotMapping()
        defer { restore() }
        var sharedConfig = ClaudeCodeCompatibleBackendStore.shared.config(for: .custom)
        sharedConfig.contextWindowTokens = 262_144
        ClaudeCodeCompatibleBackendStore.shared.saveConfig(sharedConfig)
        XCTAssertEqual(ClaudeCompatibleModelCatalogAdapter.contextWindowTokens(forRequestedModelRaw: "sonnet", agentKind: .customClaudeCompatible), 262_144)
        var sidebar = AgentRuntimeSidebarViewModel.ContextSnapshot(selectedAgent: .customClaudeCompatible, selectedModelRaw: "sonnet")
        XCTAssertEqual(sidebar.effectiveContextWindowTokens, 262_144)
        sidebar.contextWindowTokens = 128_000
        XCTAssertEqual(sidebar.effectiveContextWindowTokens, 128_000, "A provider-reported window remains authoritative")

        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .customClaudeCompatible
        session.selectedModelRaw = "sonnet"
        let estimator = ClaudeContextUsageEstimator(tokenEstimator: { _ in 0 }, contextUsageBuilder: { usage, window in
            AgentModeViewModel.contextUsageFromClaudeProviderTokens(usage, modelContextWindow: window)
        })
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 250_000, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 262_144)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 250_000, "Configured windows prevent valid usage above 200K from being discarded")
        _ = estimator.ingestTurnFinalizationSignal(contextUsedTokens: 250_000, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 262_144)
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 100_000, modelContextWindow: 128_000, session: session)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 128_000)
        _ = estimator.ingestTurnFinalizationSignal(contextUsedTokens: 100_000, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 128_000, "A later window-less event must retain the last reported window")

        estimator.ingestSystemSignal("Context compacted", session: session)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 128_000)
        XCTAssertNil(session.codexContextUsage?.lastTotalTokens)
        XCTAssertEqual(session.codexContextUsage?.awaitingPostCompactionUsage, true)
        _ = estimator.ingestUsageSignal(promptTokens: 100_000, completionTokens: nil, contextUsedTokens: nil, modelContextWindow: nil, session: session)
        XCTAssertNil(session.codexContextUsage?.lastTotalTokens, "Billed input must not replace unknown post-compaction occupancy")
        XCTAssertEqual(session.codexContextUsage?.awaitingPostCompactionUsage, true)
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 80000, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 128_000)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 80000)
        XCTAssertNotEqual(session.codexContextUsage?.awaitingPostCompactionUsage, true)
    }

    @MainActor
    func testConfiguredCustomWindowAcceptsFreshOccupancyAfterCompaction() {
        let restore = installTemporaryCustomSlotMapping()
        defer { restore() }
        var config = ClaudeCodeCompatibleBackendStore.shared.config(for: .custom)
        config.contextWindowTokens = 262_144
        ClaudeCodeCompatibleBackendStore.shared.saveConfig(config)

        for hasPriorUsage in [true, false] {
            let session = AgentTabSession(tabID: UUID())
            session.selectedAgent = .customClaudeCompatible
            session.selectedModelRaw = "sonnet"
            let estimator = ClaudeContextUsageEstimator(tokenEstimator: { _ in 0 }, contextUsageBuilder: { usage, window in
                AgentModeViewModel.contextUsageFromClaudeProviderTokens(usage, modelContextWindow: window)
            })
            if hasPriorUsage {
                _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 250_000, modelContextWindow: nil, session: session)
                XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 262_144)
                XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 250_000)
            }

            estimator.ingestSystemSignal("Context compacted", session: session)
            XCTAssertEqual(session.codexContextUsage?.modelContextWindow, hasPriorUsage ? 262_144 : nil)
            XCTAssertNil(session.codexContextUsage?.lastTotalTokens)
            XCTAssertEqual(session.codexContextUsage?.awaitingPostCompactionUsage, true)

            if hasPriorUsage {
                _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 250_000, modelContextWindow: nil, session: session)
            } else {
                XCTAssertTrue(estimator.finalizeTurn(promptTokens: nil, completionTokens: nil, contextUsedTokens: 250_000, session: session))
                XCTAssertEqual(session.providerTokenUsageByTurn.last?.contextUsedTokens, 250_000)
            }
            XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 262_144)
            XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 250_000, "Fresh occupancy above the default 200K must remain valid; prior usage: \(hasPriorUsage)")
            XCTAssertNotEqual(session.codexContextUsage?.awaitingPostCompactionUsage, true)
        }
    }

    @MainActor
    func testNativeSDKToolInputApprovalRoundTripPreservesMCPTypesAndStrictInventoryLimits() throws {
        let cases: [(literal: String, value: Value, acceptedLimit: Int?)] = [
            ("0", .int(0), nil), ("1", .int(1), 1), ("2", .int(2), 2),
            ("500", .int(500), 500), ("501", .int(501), nil),
            ("1.5", .double(1.5), nil), ("true", .bool(true), nil), ("false", .bool(false), nil)
        ]
        let nested: Value = .object([
            "values": .array([.int(0), .int(1), .int(2), .int(500), .int(501), .double(1.5), .bool(true), .bool(false)])
        ])
        for (literal, expected, acceptedLimit) in cases {
            let line = Data("{\"type\":\"control_request\",\"request_id\":\"numeric-input\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"mcp__RepoPrompt__session_admin\",\"input\":{\"op\":\"inventory\",\"limit\":\(literal),\"nested\":{\"values\":[0,1,2,500,501,1.5,true,false]}}}}".utf8)
            guard case let .controlRequest(request)? = try ClaudeSDKProtocolCodec.decodeLine(line) else {
                return XCTFail("Expected production SDK control request")
            }
            XCTAssertEqual(request.subtype, "can_use_tool")
            let allow = ClaudeNativeProcessSessionController.allowPermissionResponsePayload(
                pendingRequest: request.request, includeUpdatedPermissions: false
            )
            let encoded = try ClaudeSDKProtocolCodec.encodeControlResponseSuccess(requestID: request.requestID, response: allow)
            guard case let .controlResponse(response)? = try ClaudeSDKProtocolCodec.decodeLine(encoded) else {
                return XCTFail("Expected production SDK allow response")
            }
            let updatedInput = try XCTUnwrap(response.response?["updatedInput"] as? [String: Any])
            // The SDK reuses updatedInput for the subsequent tools/call. Decode those actual
            // parameter bytes with the MCP SDK, rather than hand-constructing Value.int(1).
            let parameterBytes = try JSONSerialization.data(withJSONObject: ["name": "session_admin", "arguments": updatedInput])
            let parameters = try JSONDecoder().decode(CallTool.Parameters.self, from: parameterBytes)
            let arguments = try XCTUnwrap(parameters.arguments)
            XCTAssertEqual(arguments["limit"], expected, "literal=\(literal)")
            XCTAssertEqual(arguments["nested"], nested, "nested tool arguments must retain exact JSON types")
            if let acceptedLimit {
                XCTAssertEqual(try AgentSessionAdminArguments.limit(arguments), acceptedLimit)
            } else {
                XCTAssertThrowsError(try AgentSessionAdminArguments.limit(arguments)) { error in
                    guard let mcpError = error as? MCPError, case .invalidParams = mcpError else {
                        return XCTFail("Expected strict invalidParams, got \(error)")
                    }
                }
            }
        }
    }

    func testClaudeCodeCatalogExposesOpus55AcrossAgentSelection() {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: false,
            openCodeAvailable: false
        )
        let options = AgentModelCatalog.options(for: .claudeCode, availability: availability)
        let opus55Options = options.filter { $0.rawValue.hasPrefix("claude-opus-5-5:") }

        XCTAssertEqual(
            opus55Options.map(\.rawValue),
            [
                "claude-opus-5-5:low",
                "claude-opus-5-5:medium",
                "claude-opus-5-5:high",
                "claude-opus-5-5:xhigh",
                "claude-opus-5-5:max"
            ]
        )
        XCTAssertEqual(opus55Options.first?.displayName, "Opus 5.5 Low")
        XCTAssertTrue(AgentModelCatalog.isValid(
            rawModel: "claude-opus-5-5:xhigh",
            for: .claudeCode,
            availability: availability
        ))
        XCTAssertTrue(AgentModel.modelsForAgent(.claudeCode).contains(.claudeOpus55))
    }

    func testClaudeCodeCatalogExposesSonnet55AndRestrictedMythos51() {
        let availability = AgentModelCatalog.AvailabilityContext.current
        for raw in ["claude-sonnet-5-5:xhigh", "claude-sonnet-5-5:max", "claude-mythos-5-1:high"] {
            XCTAssertTrue(
                AgentModelCatalog.isValid(rawModel: raw, for: .claudeCode, availability: availability),
                raw
            )
        }
        let claudeModels = AgentModel.modelsForAgent(.claudeCode)
        XCTAssertTrue(claudeModels.contains(.claudeSonnet55))
        XCTAssertTrue(claudeModels.contains(.claudeMythos51))
        XCTAssertEqual(AgentModel.claudeSonnet55.contextWindowTokens, 1_000_000)
        XCTAssertEqual(AgentModel.claudeSonnet55.discoveryTags, [.balanced, .engineering, .extendedContext])
        // The restricted tier is selectable but never a recommendation target.
        XCTAssertEqual(AgentModel.claudeMythos51.discoveryTags, [])
        XCTAssertEqual(AgentModel.resolvedModel(forRaw: "claude-sonnet-5-5:high", agentKind: .claudeCode), .claudeSonnet55)
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

#if DEBUG
    @MainActor
    final class ClaudeCompactionContextUsageTests: XCTestCase {
        func testProviderSwitchClearsPendingClaudeCompactionUsage() throws {
            let viewModel = AgentModeViewModel(
                testWindowID: -972,
                testWorkspacePath: FileManager.default.currentDirectoryPath,
                codexControllerFactory: { _, _, _, _, _, _ in preconditionFailure("Provider switch must not launch a provider") },
                connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
                mcpServerEnabler: { true }
            )
            let session = viewModel.session(for: UUID())
            defer { session.saveDebounceTask?.cancel() }
            session.selectedAgent = .claudeCode
            session.appendItem(.user("Historical transcript retained across the provider switch."))
            session.codexContextUsage = AgentContextUsage(
                modelContextWindow: 200_000,
                lastTotalTokens: nil,
                totalTotalTokens: nil,
                awaitingPostCompactionUsage: true
            )
            let sidebar = AgentRuntimeSidebarViewModel()
            func refreshSidebar() {
                sidebar.update(
                    snapshot: AgentTranscriptAnalyticsBuilder.build(from: session.transcript, selectedAgent: session.selectedAgent),
                    codexUsage: session.codexContextUsage
                )
            }
            refreshSidebar()
            XCTAssertTrue(sidebar.snapshot.awaitingPostCompactionUsage)
            XCTAssertNil(sidebar.snapshot.displayUsedTokens)

            viewModel.test_codexCoordinator.handleProviderSwitch(from: .claudeCode, to: .openCode, session: session)
            session.selectedAgent = .openCode
            refreshSidebar()

            XCTAssertNil(session.codexContextUsage?.awaitingPostCompactionUsage)
            XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 200_000)
            XCTAssertFalse(sidebar.snapshot.awaitingPostCompactionUsage)
            XCTAssertGreaterThan(try XCTUnwrap(sidebar.snapshot.displayUsedTokens), 0)
            XCTAssertEqual(sidebar.snapshot.displayUsageLabel, "Estimated")
        }

        func testCompactionBoundaryInvalidatesRingUntilFreshOccupancyArrives() async throws {
            for trigger in ["manual", "auto"] {
                let viewModel = AgentModeViewModel(
                    testWindowID: -972,
                    testWorkspacePath: FileManager.default.currentDirectoryPath,
                    codexControllerFactory: { _, _, _, _, _, _ in preconditionFailure("Replay must not launch a provider") },
                    connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
                    mcpServerEnabler: { true }
                )
                let session = viewModel.session(for: UUID())
                defer { session.saveDebounceTask?.cancel() }
                session.selectedAgent = .claudeCode
                session.appendItem(.user(String(repeating: "Pre-compaction transcript context. ", count: 1000)))
                let runID = UUID()
                let attemptID = UUID()
                session.installRunID(runID)
                session.beginRunAttempt(source: "compaction-replay", attemptID: attemptID)
                var translator = ClaudeSDKNDJSONTranslator()
                let sidebar = AgentRuntimeSidebarViewModel()
                func consume(_ line: String) async throws {
                    var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                    envelope["session_id"] = "72c65f88-2b76-4406-9b32-93d61df09272"
                    envelope["uuid"] = UUID().uuidString
                    for result in try translator.parseNDJSONLine(JSONSerialization.data(withJSONObject: envelope)) {
                        await viewModel.test_handleStreamResult(result, session: session, runID: runID, runAttemptID: attemptID)
                    }
                    sidebar.update(
                        snapshot: AgentTranscriptAnalyticsBuilder.build(from: session.transcript, selectedAgent: session.selectedAgent),
                        codexUsage: session.codexContextUsage
                    )
                }
                let usage = #"{"type":"assistant","message":{"id":"msg_before_compaction","role":"assistant","content":[],"usage":{"input_tokens":1000,"cache_read_input_tokens":149000,"output_tokens":10}}}"#
                let result = #"{"type":"result","subtype":"success","is_error":false,"result":"Done","duration_ms":100,"duration_api_ms":100,"num_turns":1,"total_cost_usd":0,"usage":{"input_tokens":150000,"output_tokens":10},"modelUsage":{"claude-sonnet-4-6":{"contextWindow":200000}}}"#
                viewModel.startNonCodexTurnAccountingIfNeeded(for: session, initialMessage: "Earlier turn")
                try await consume(usage)
                try await consume(result)
                XCTAssertEqual(sidebar.snapshot.usedTokens, 150_000)
                try await consume(#"{"type":"system","subtype":"task_notification","task_id":"worker-1","status":"completed","summary":"Context compacted inside worker task"}"#)
                try await consume(#"{"type":"system","message":"The worker reported context compacted successfully"}"#)
                XCTAssertEqual(sidebar.snapshot.usedTokens, 150_000, "Task prose is not a compaction boundary")
                XCTAssertFalse(session.providerTokenUsageByTurn.contains(where: \.contextCompacted))

                viewModel.startNonCodexTurnAccountingIfNeeded(for: session, initialMessage: "/compact")
                // Automatic compaction can occur after this turn already reported its old context.
                if trigger == "auto" { try await consume(usage) }
                try await consume(#"{"type":"system","subtype":"status","status":"compacting"}"#)
                try await consume("{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"compact_metadata\":{\"trigger\":\"\(trigger)\",\"pre_tokens\":150000}}")
                XCTAssertNil(session.contextUsageSnapshot?.used, trigger)
                XCTAssertNil(sidebar.snapshot.usedTokens, trigger)
                XCTAssertEqual(sidebar.snapshot.contextWindowTokens, 200_000)
                XCTAssertNotNil(session.contextUsageSnapshot?.compactedAt)
                XCTAssertTrue(sidebar.snapshot.awaitingPostCompactionUsage)
                XCTAssertEqual(sidebar.snapshot.displayUsageLabel, "Awaiting post-compaction usage")
                XCTAssertNotEqual(sidebar.snapshot.usageSource, .codexLive)
                XCTAssertGreaterThan(try XCTUnwrap(sidebar.snapshot.estimatedTranscriptTokens), 0)
                XCTAssertNil(sidebar.snapshot.displayUsedTokens, "Never substitute the whole historical transcript while pending")
                XCTAssertNil(session.activeNonCodexTurnTokenAccumulator?.observedContextUsedTokens)

                if trigger == "auto" {
                    // Auto-compaction continues the SAME turn with a new API context before result.
                    try await consume(#"{"type":"assistant","message":{"id":"msg_after_auto","role":"assistant","content":[],"usage":{"input_tokens":2000,"cache_read_input_tokens":8000,"output_tokens":10}}}"#)
                    try await consume(result)
                    XCTAssertEqual(sidebar.snapshot.usedTokens, 10000)
                    XCTAssertFalse(sidebar.snapshot.awaitingPostCompactionUsage)
                    viewModel.startNonCodexTurnAccountingIfNeeded(for: session, initialMessage: "Unmeasured after recovery")
                    try await consume(result)
                    XCTAssertEqual(sidebar.snapshot.usedTokens, 10000)
                    XCTAssertFalse(sidebar.snapshot.awaitingPostCompactionUsage)
                    continue
                }

                // Init has no post-compaction size; result usage is billed aggregate, not occupancy.
                try await consume(#"{"type":"system","subtype":"init","session_id":"compact-fixture","model":"claude-sonnet-4-6"}"#)
                await viewModel.test_handleStreamResult(
                    AIStreamResult(type: "usage", text: nil, promptTokens: 150_000),
                    session: session, runID: runID, runAttemptID: attemptID
                )
                XCTAssertNil(session.contextUsageSnapshot?.used, "Billed input alone cannot establish post-compaction occupancy")
                try await consume(result)
                XCTAssertNil(sidebar.snapshot.usedTokens, "Finalization must not restore old context")
                XCTAssertNil(session.providerTokenUsageByTurn.last?.contextUsedTokens)
                viewModel.startNonCodexTurnAccountingIfNeeded(for: session, initialMessage: "Continue")
                try await consume(result)
                XCTAssertNil(sidebar.snapshot.usedTokens, "Unmeasured later turns must remain unknown")

                viewModel.startNonCodexTurnAccountingIfNeeded(for: session, initialMessage: "Fresh measurement")
                try await consume(#"{"type":"assistant","message":{"id":"msg_after_manual_compaction","role":"assistant","content":[],"usage":{"input_tokens":2000,"cache_read_input_tokens":8000,"output_tokens":10}}}"#)
                XCTAssertEqual(sidebar.snapshot.usedTokens, 10000)
                XCTAssertFalse(sidebar.snapshot.awaitingPostCompactionUsage)
                try await consume(result)
                XCTAssertEqual(sidebar.snapshot.usedTokens, 10000)
                XCTAssertEqual(session.providerTokenUsageByTurn.last?.contextUsedTokens, 10000)
            }
        }

        func testCompactionFenceRoundTripAndLegacyUsageDecoding() throws {
            let legacy = Data(#"{"promptTokens":150000,"completionTokens":10,"contextUsedTokens":150000,"timestamp":0}"#.utf8)
            let old = try JSONDecoder().decode(AgentTokenUsagePersist.self, from: legacy)
            XCTAssertFalse(old.contextCompacted)
            let oldSnapshot = try JSONDecoder().decode(AgentContextUsage.self, from: Data(#"{"modelContextWindow":200000,"lastTotalTokens":150000,"totalTotalTokens":150000}"#.utf8))
            XCTAssertNotEqual(oldSnapshot.awaitingPostCompactionUsage, true)
            let sidebar = AgentRuntimeSidebarViewModel()
            sidebar.update(
                snapshot: AgentTranscriptAnalyticsSnapshot(estimatedTranscriptTokens: 1000),
                codexUsage: AgentContextUsage(modelContextWindow: 200_000, lastTotalTokens: nil, totalTotalTokens: nil)
            )
            XCTAssertEqual(sidebar.snapshot.usageSource, .unavailable, "A window without occupancy is not Live")
            XCTAssertEqual(sidebar.snapshot.displayUsageLabel, "Estimated")
            let fence = AgentTokenUsagePersist(promptTokens: 0, completionTokens: 0, contextCompacted: true)
            let unmeasured = AgentTokenUsagePersist(promptTokens: 42, completionTokens: 5)
            let rows = try JSONDecoder().decode([AgentTokenUsagePersist].self, from: JSONEncoder().encode([old, fence, unmeasured]))
            XCTAssertEqual(rows, [old, fence, unmeasured])
            XCTAssertEqual(rows.map(\.providerTotalTokens).reduce(0, +), 150_057, "A compaction fence is not billable usage")
            let pending = AgentModeViewModel.contextUsageFromClaudeProviderTokens(rows, modelContextWindow: nil)
            XCTAssertNil(pending?.lastTotalTokens)
            XCTAssertEqual(pending?.awaitingPostCompactionUsage, true, "The fence works even without a known window")
            let fresh = AgentTokenUsagePersist(promptTokens: 1000, completionTokens: 10, contextUsedTokens: 10000)
            let recovered = AgentModeViewModel.contextUsageFromClaudeProviderTokens(rows + [fresh, unmeasured], modelContextWindow: 200_000)
            XCTAssertEqual(recovered?.lastTotalTokens, 10000)
            XCTAssertNotEqual(recovered?.awaitingPostCompactionUsage, true)
        }

        func testPendingOccupancySurvivesHydrationAndHistoryReopen() async throws {
            GlobalSettingsStore.installApplicationModelIdentityPolicy()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCompactionHydration-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            defer {
                for session in window.agentModeViewModel.sessions.values {
                    session.saveDebounceTask?.cancel()
                }
                WindowStatesManager.shared.unregisterWindowState(window)
                GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            }
            await window.workspaceManager.awaitInitialized()
            let workspace = window.workspaceManager.createWorkspace(name: "Compaction hydration", repoPaths: [root.path], ephemeral: true)
            await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "compactionHydrationTests")
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
            let tabID = try XCTUnwrap(activeWorkspace.activeComposeTabID)
            let index = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == activeWorkspace.id })
            window.workspaceManager.workspaces[index].customStoragePath = root.appendingPathComponent("sessions", isDirectory: true)
            let oldRequest = AgentChatItem.user(String(repeating: "Old context. ", count: 1000))
            let storedTranscript = AgentTranscript(turns: [AgentTranscriptTurn(
                request: AgentTranscriptRequestAnchor(from: oldRequest),
                terminalState: .completed,
                startedAt: oldRequest.timestamp,
                completedAt: oldRequest.timestamp
            )], nextSequenceIndex: 1)
            let compactedAt = Date(timeIntervalSince1970: 100)
            let rows = [
                AgentTokenUsagePersist(promptTokens: 150_000, completionTokens: 10, contextUsedTokens: 150_000),
                AgentTokenUsagePersist(promptTokens: 0, completionTokens: 0, contextCompacted: true, timestamp: compactedAt),
                AgentTokenUsagePersist(promptTokens: 150_000, completionTokens: 10)
            ]
            let viewModel = window.agentModeViewModel
            func save(_ usage: [AgentTokenUsagePersist], staleStoredCount: Int? = nil) async throws -> UUID {
                let id = UUID()
                let persisted = AgentSession(
                    id: id, workspaceID: activeWorkspace.id, composeTabID: tabID, name: "Compacted Claude",
                    transcript: storedTranscript, agentKind: AgentProviderKind.claudeCode.rawValue,
                    agentModel: "claude-sonnet-4-6", lastRunState: "completed", providerTokenUsageByTurn: usage,
                    codexContextWindow: 200_000, codexLastTotalTokens: staleStoredCount, codexTotalTotalTokens: staleStoredCount
                )
                _ = try await AgentSessionDataService.shared.saveAgentSession(persisted, for: window.workspaceManager.workspaces[index])
                return id
            }
            func assertPending(_ session: AgentTabSession, file: StaticString = #filePath, line: UInt = #line) {
                let sidebar = AgentRuntimeSidebarViewModel()
                XCTAssertFalse(session.transcript.turns.isEmpty, file: file, line: line)
                sidebar.update(
                    snapshot: AgentTranscriptAnalyticsBuilder.build(from: session.transcript, selectedAgent: session.selectedAgent),
                    codexUsage: session.codexContextUsage
                )
                XCTAssertGreaterThan(sidebar.snapshot.estimatedTranscriptTokens ?? 0, 0, file: file, line: line)
                XCTAssertNil(sidebar.snapshot.displayUsedTokens, file: file, line: line)
                XCTAssertEqual(sidebar.snapshot.displayUsageLabel, "Awaiting post-compaction usage", file: file, line: line)
                XCTAssertTrue(sidebar.snapshot.awaitingPostCompactionUsage, file: file, line: line)
                XCTAssertNil(session.codexContextUsage?.lastTotalTokens, file: file, line: line)
                XCTAssertEqual(session.contextCompactedAt, compactedAt, file: file, line: line)
            }
            let initialID = try await save(rows)
            let initial = viewModel.session(for: tabID)
            _ = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(sessionID: initialID, on: initial, updateWorkspaceMetadata: true))
            initial.hasLoadedPersistedState = false
            let hydrated = await viewModel.ensureSessionReady(tabID: tabID)
            XCTAssertTrue(hydrated.permitsBoundOperationAndSave)
            assertPending(hydrated)

            // A different saved conversation takes the history-route hydration branch, not ensure-ready's fast path.
            let historyID = try await save(rows, staleStoredCount: 150_000)
            let routed = await viewModel.activateRoutedAgentSession(tabID: tabID, sessionID: historyID, workspace: window.workspaceManager.workspaces[index])
            XCTAssertEqual(routed, .ready)
            let reopened = try XCTUnwrap(viewModel.sessions[tabID])
            XCTAssertEqual(reopened.activeAgentSessionID, historyID)
            assertPending(reopened)

            let fresh = AgentTokenUsagePersist(promptTokens: 1000, completionTokens: 10, contextUsedTokens: 10000)
            let recoveredID = try await save(rows + [fresh, AgentTokenUsagePersist(promptTokens: 500, completionTokens: 5)])
            let recoveredRoute = await viewModel.activateRoutedAgentSession(tabID: tabID, sessionID: recoveredID, workspace: window.workspaceManager.workspaces[index])
            XCTAssertEqual(recoveredRoute, .ready)
            let recovered = try XCTUnwrap(viewModel.sessions[tabID])
            XCTAssertEqual(recovered.codexContextUsage?.lastTotalTokens, 10000)
            XCTAssertNotEqual(recovered.codexContextUsage?.awaitingPostCompactionUsage, true)
        }
    }
#endif
