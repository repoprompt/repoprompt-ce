import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

final class ClaudeCompatiblePluginBridgeTests: XCTestCase {
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

@MainActor
final class ClaudeCompactionContextUsageTests: XCTestCase {
    func testCompactionBoundaryInvalidatesRingUntilFreshOccupancyArrives() {
        for trigger in ["manual", "auto"] {
            let session = AgentTabSession(tabID: UUID())
            session.selectedAgent = .claudeCode
            let estimator = ClaudeContextUsageEstimator(
                tokenEstimator: { _ in 10 },
                contextUsageBuilder: AgentModeViewModel.contextUsageFromClaudeProviderTokens
            )
            var translator = ClaudeSDKNDJSONTranslator()
            let sidebar = AgentRuntimeSidebarViewModel()
            func consume(_ line: String) {
                for result in translator.parseNDJSONLine(Data(line.utf8)) {
                    switch result.type {
                    case "usage":
                        estimator.ingestUsageSignal(
                            promptTokens: result.promptTokens, completionTokens: result.completionTokens,
                            contextUsedTokens: result.contextUsedTokens, modelContextWindow: result.modelContextWindow,
                            session: session
                        )
                    case "status":
                        estimator.ingestStatusSignal(result.text, session: session)
                    case "system":
                        estimator.ingestSystemSignal(result.text, session: session)
                    case "message_stop":
                        estimator.ingestTurnFinalizationSignal(
                            contextUsedTokens: result.contextUsedTokens, modelContextWindow: result.modelContextWindow,
                            session: session
                        )
                        _ = estimator.finalizeTurn(
                            promptTokens: result.promptTokens, completionTokens: result.completionTokens,
                            contextUsedTokens: result.contextUsedTokens, session: session
                        )
                    default:
                        break
                    }
                }
                sidebar.update(items: [], codexUsage: session.codexContextUsage)
            }
            let usage = #"{"type":"assistant","message":{"role":"assistant","content":[],"usage":{"input_tokens":1000,"cache_read_input_tokens":149000,"output_tokens":10}}}"#
            let result = #"{"type":"result","subtype":"success","usage":{"input_tokens":150000,"output_tokens":10},"modelUsage":{"claude-sonnet-4-6":{"contextWindow":200000}}}"#
            estimator.beginTurn(session: session, initialMessage: "Earlier turn")
            consume(usage)
            consume(result)
            XCTAssertEqual(sidebar.snapshot.usedTokens, 150_000)

            estimator.beginTurn(session: session, initialMessage: "/compact")
            // Automatic compaction can occur after this turn already reported its old context.
            consume(usage)
            consume(#"{"type":"system","subtype":"status","status":"compacting"}"#)
            consume("{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"compact_metadata\":{\"trigger\":\"\(trigger)\",\"pre_tokens\":150000}}")
            XCTAssertNil(session.contextUsageSnapshot?.used, trigger)
            XCTAssertNil(sidebar.snapshot.usedTokens, trigger)
            XCTAssertEqual(sidebar.snapshot.contextWindowTokens, 200_000)
            XCTAssertNotNil(session.contextUsageSnapshot?.compactedAt)
            XCTAssertNil(session.activeNonCodexTurnTokenAccumulator?.observedContextUsedTokens)

            // Init has no post-compaction size; result usage is billed aggregate, not occupancy.
            consume(#"{"type":"system","subtype":"init","session_id":"compact-fixture","model":"claude-sonnet-4-6"}"#)
            estimator.ingestUsageSignal(
                promptTokens: 150_000, completionTokens: nil, contextUsedTokens: nil,
                modelContextWindow: nil, session: session
            )
            XCTAssertNil(session.contextUsageSnapshot?.used, "Billed input alone cannot establish post-compaction occupancy")
            consume(result)
            XCTAssertNil(sidebar.snapshot.usedTokens, "Finalization must not restore old context")
            XCTAssertNil(session.providerTokenUsageByTurn.last?.contextUsedTokens)
            estimator.beginTurn(session: session, initialMessage: "Continue")
            consume(result)
            XCTAssertNil(sidebar.snapshot.usedTokens, "Unmeasured later turns must remain unknown")

            estimator.beginTurn(session: session, initialMessage: "Fresh measurement")
            consume(#"{"type":"assistant","message":{"role":"assistant","content":[],"usage":{"input_tokens":2000,"cache_read_input_tokens":8000,"output_tokens":10}}}"#)
            XCTAssertEqual(sidebar.snapshot.usedTokens, 10000)
            consume(result)
            XCTAssertEqual(sidebar.snapshot.usedTokens, 10000)
            XCTAssertEqual(session.providerTokenUsageByTurn.last?.contextUsedTokens, 10000)
        }
    }
}
