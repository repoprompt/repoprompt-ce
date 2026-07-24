@testable import RepoPromptClaudeCompatibleProvider
import XCTest

final class ClaudeCompatibleRuntimeSupportTests: XCTestCase {
    func testRuntimeLaunchAndHeadlessSmokesPromptEnvironmentAndModels() async throws {
        let decorated = ClaudeCompatiblePromptDelivery.decoratedUserMessage(
            "Do the work",
            instructions: " Be careful "
        )
        XCTAssertEqual(decorated, """
        <claude_code_instructions>
        Be careful
        </claude_code_instructions>

        Do the work
        """)
        XCTAssertTrue(ClaudeCompatiblePromptDeliveryMode.userMessageXML.sendsRepoPromptAsUserMessage)
        XCTAssertEqual(
            ClaudeCompatiblePromptDeliveryMode.userMessageXMLWithEmptySystemPrompt.nativeSystemPromptOverride(instructions: "ignored"),
            ""
        )
        XCTAssertEqual(
            ClaudeCompatiblePromptDeliveryMode.nativeSystemPrompt.nativeSystemPromptOverride(instructions: "system"),
            "system"
        )

        let config = ClaudeCompatibleBackendConfig(
            id: .glmZAI,
            isEnabled: true,
            displayName: " Claude Code GLM ",
            baseURL: " https://api.z.ai/api/anthropic ",
            auth: .anthropicAuthToken,
            modelBehavior: .claudeSlotMapping(.init(haiku: " h ", sonnet: " s ", opus: " o "))
        )
        let environment = ClaudeCompatibleBackendEnvironmentBuilder.environment(config: config, apiKey: "secret")
        let defaultGLMEnvironment = ClaudeCompatibleBackendEnvironmentBuilder.environment(
            config: ClaudeCompatibleBackendID.glmZAI.defaultPreset,
            apiKey: "secret"
        )
        XCTAssertEqual(config.normalizedDisplayName, "Claude Code GLM")
        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], "https://api.z.ai/api/anthropic")
        XCTAssertEqual(environment["ANTHROPIC_AUTH_TOKEN"], "secret")
        XCTAssertEqual(environment["API_TIMEOUT_MS"], "3000000")
        XCTAssertNil(environment["CLAUDE_CODE_AUTO_COMPACT_WINDOW"])
        XCTAssertEqual(environment["ANTHROPIC_MODEL"], "s")
        XCTAssertEqual(environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "h")
        XCTAssertEqual(environment["ANTHROPIC_DEFAULT_SONNET_MODEL"], "s")
        XCTAssertEqual(environment["ANTHROPIC_DEFAULT_OPUS_MODEL"], "o")
        XCTAssertEqual(environment["ANTHROPIC_SMALL_FAST_MODEL"], "h")
        XCTAssertEqual(environment["CLAUDE_CODE_SUBAGENT_MODEL"], "h")
        XCTAssertEqual(ClaudeCompatibleBackendEnvironmentBuilder.removedEnvironmentKeys(config: config), ["ANTHROPIC_API_KEY"])
        let customNoModelRemovedKeys = ClaudeCompatibleBackendEnvironmentBuilder.removedEnvironmentKeys(
            config: ClaudeCompatibleBackendID.custom.defaultPreset
        )
        XCTAssertTrue(customNoModelRemovedKeys.isSuperset(of: [
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_SMALL_FAST_MODEL",
            "CLAUDE_CODE_SUBAGENT_MODEL"
        ]))
        XCTAssertFalse(customNoModelRemovedKeys.contains("ANTHROPIC_API_KEY"))
        XCTAssertEqual(defaultGLMEnvironment["ANTHROPIC_MODEL"], "glm-5.2[1m]")
        XCTAssertEqual(defaultGLMEnvironment["CLAUDE_CODE_AUTO_COMPACT_WINDOW"], "1000000")

        let oneMillionEnvironment = ClaudeCompatibleBackendEnvironmentBuilder.environment(
            config: ClaudeCompatibleBackendID.glmZAI.defaultPreset,
            apiKey: "secret",
            selectedBackendModelID: " glm-5.2[1m] "
        )
        XCTAssertEqual(oneMillionEnvironment["API_TIMEOUT_MS"], "3000000")
        XCTAssertEqual(oneMillionEnvironment["ANTHROPIC_MODEL"], "glm-5.2[1m]")
        XCTAssertEqual(oneMillionEnvironment["CLAUDE_CODE_AUTO_COMPACT_WINDOW"], "1000000")
        let haikuEnvironment = ClaudeCompatibleBackendEnvironmentBuilder.environment(
            config: ClaudeCompatibleBackendID.glmZAI.defaultPreset,
            apiKey: "secret",
            selectedBackendModelID: "glm-4.5-air"
        )
        XCTAssertEqual(haikuEnvironment["API_TIMEOUT_MS"], "3000000")
        XCTAssertEqual(haikuEnvironment["ANTHROPIC_MODEL"], "glm-4.5-air")
        XCTAssertNil(haikuEnvironment["CLAUDE_CODE_AUTO_COMPACT_WINDOW"])

        let resolver = ClaudeCompatibleLaunchEnvironmentResolver(
            backendConfigProvider: { id in
                switch id {
                case .glmZAI:
                    ClaudeCompatibleBackendConfig(
                        id: .glmZAI,
                        isEnabled: true,
                        displayName: "CC Zai",
                        baseURL: "https://api.z.ai/api/anthropic",
                        auth: .anthropicAuthToken,
                        modelBehavior: .claudeSlotMapping(.init(haiku: "glm-haiku", sonnet: "glm-sonnet", opus: "glm-opus"))
                    )
                case .kimi:
                    .init(
                        id: .kimi,
                        isEnabled: true,
                        displayName: "CC Moonshot",
                        baseURL: "https://api.kimi.com/coding/",
                        auth: .anthropicAPIKey,
                        modelBehavior: .noModel
                    )
                case .custom:
                    ClaudeCompatibleBackendID.custom.defaultPreset
                }
            },
            zaiSecretProvider: { " zai-secret " },
            backendSecretProvider: { id in
                XCTAssertEqual(id, .kimi)
                return "kimi-secret"
            }
        )

        let glm = try await resolver.resolve(variant: .glm, requestedModel: "glm-opus")
        XCTAssertEqual(glm.backendID, .glmZAI)
        XCTAssertEqual(glm.effectiveModel, "opus")
        XCTAssertEqual(glm.environmentOverrides["ANTHROPIC_AUTH_TOKEN"], "zai-secret")
        XCTAssertEqual(glm.environmentOverrides["ANTHROPIC_MODEL"], "glm-opus")
        XCTAssertFalse(glm.suppressesEffortSettings)

        let kimi = try await resolver.resolve(variant: .kimi, requestedModel: "kimi-code")
        XCTAssertEqual(kimi.backendID, .kimi)
        XCTAssertNil(kimi.effectiveModel)
        XCTAssertEqual(kimi.environmentOverrides["ANTHROPIC_API_KEY"], "kimi-secret")
        XCTAssertNil(kimi.environmentOverrides["ANTHROPIC_MODEL"])
        XCTAssertNil(kimi.environmentOverrides["ANTHROPIC_DEFAULT_HAIKU_MODEL"])
        XCTAssertNil(kimi.environmentOverrides["ANTHROPIC_SMALL_FAST_MODEL"])
        XCTAssertNil(kimi.environmentOverrides["CLAUDE_CODE_SUBAGENT_MODEL"])
        XCTAssertTrue(kimi.removedEnvironmentKeys.isSuperset(of: [
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_SMALL_FAST_MODEL",
            "CLAUDE_CODE_SUBAGENT_MODEL"
        ]))
        XCTAssertTrue(kimi.suppressesEffortSettings)

        let deepSeekConfig = ClaudeCompatibleBackendConfig(
            id: .custom,
            isEnabled: true,
            displayName: "CC DS",
            baseURL: "https://api.deepseek.com/anthropic",
            auth: .anthropicAuthToken,
            modelBehavior: .claudeSlotMapping(.init(
                haiku: "deepseek-v4-flash",
                sonnet: "deepseek-v4-pro[1m]",
                opus: "deepseek-v4-pro[1m]"
            ))
        )
        let deepSeekResolver = ClaudeCompatibleLaunchEnvironmentResolver(
            backendConfigProvider: { id in id == .custom ? deepSeekConfig : id.defaultPreset },
            zaiSecretProvider: { nil },
            backendSecretProvider: { id in
                XCTAssertEqual(id, .custom)
                return " deepseek-secret "
            }
        )
        let deepSeekHaiku = try await deepSeekResolver.resolve(variant: .customCompatible, requestedModel: "haiku:low")
        XCTAssertEqual(deepSeekHaiku.backendID, .custom)
        XCTAssertEqual(deepSeekHaiku.effectiveModel, "haiku")
        XCTAssertEqual(deepSeekHaiku.environmentOverrides["ANTHROPIC_BASE_URL"], "https://api.deepseek.com/anthropic")
        XCTAssertEqual(deepSeekHaiku.environmentOverrides["ANTHROPIC_AUTH_TOKEN"], "deepseek-secret")
        XCTAssertNil(deepSeekHaiku.environmentOverrides["ANTHROPIC_API_KEY"])
        XCTAssertEqual(deepSeekHaiku.environmentOverrides["ANTHROPIC_MODEL"], "deepseek-v4-flash")
        XCTAssertEqual(deepSeekHaiku.environmentOverrides["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "deepseek-v4-flash")
        XCTAssertEqual(deepSeekHaiku.environmentOverrides["ANTHROPIC_DEFAULT_SONNET_MODEL"], "deepseek-v4-pro[1m]")
        XCTAssertEqual(deepSeekHaiku.environmentOverrides["ANTHROPIC_DEFAULT_OPUS_MODEL"], "deepseek-v4-pro[1m]")
        XCTAssertEqual(deepSeekHaiku.environmentOverrides["ANTHROPIC_SMALL_FAST_MODEL"], "deepseek-v4-flash")
        XCTAssertEqual(deepSeekHaiku.environmentOverrides["CLAUDE_CODE_SUBAGENT_MODEL"], "deepseek-v4-flash")

        do {
            _ = try await deepSeekResolver.resolve(variant: .customCompatible, requestedModel: "glm-5-turbo")
            XCTFail("Expected custom slot-mapped backends to reject GLM-only aliases")
        } catch ClaudeCompatibleProviderError.invalidConfiguration {
            // Expected.
        }

        let runtimeConfig = ClaudeCompatibleRuntimeConfig(
            pluginID: .claudeCode,
            mode: .discovery,
            commandName: "claude",
            additionalPathHints: [],
            modelString: "sonnet",
            enableDebugLogging: false,
            sdkConnectTimeoutSeconds: 10,
            sdkRelaunchMaxAttempts: 1,
            permissionMode: "bypassPermissions",
            allowNativeBashTool: false,
            toolContext: .discoverRun,
            disallowedBuiltInTools: ["Bash", "Edit"],
            mcpStrictMode: true,
            toolSearchEnabled: false,
            effortLevel: nil,
            processEnvironmentOverrides: [:],
            effortEnvironmentOverrides: [:],
            backendConfig: nil
        )
        let args = ClaudeCompatibleHeadlessRuntime.buildArguments(.init(
            runtimeConfig: runtimeConfig,
            mcpConfigPath: "/tmp/mcp.json",
            launchEnvironment: .init(
                effectiveModel: "sonnet:xhigh",
                environmentOverrides: [:],
                backendID: nil
            ),
            resumeSessionID: "session-1",
            systemPromptOverride: "system"
        ))

        XCTAssertEqual(args, [
            "-p",
            "--verbose",
            "--output-format", "stream-json",
            "--resume", "session-1",
            "--model", "sonnet",
            "--system-prompt", "system",
            "--dangerously-skip-permissions",
            "--mcp-config", "/tmp/mcp.json",
            "--strict-mcp-config",
            "--disallowedTools", "Bash,Edit"
        ])

        let compatibleRuntimeConfig = ClaudeCompatibleRuntimeConfig(
            pluginID: .customClaudeCompatible,
            mode: .discovery,
            commandName: "claude",
            additionalPathHints: [],
            modelString: "sonnet",
            enableDebugLogging: false,
            sdkConnectTimeoutSeconds: 10,
            sdkRelaunchMaxAttempts: 1,
            permissionMode: "bypassPermissions",
            allowNativeBashTool: false,
            toolContext: .discoverRun,
            disallowedBuiltInTools: [],
            mcpStrictMode: false,
            toolSearchEnabled: false,
            effortLevel: nil,
            processEnvironmentOverrides: [:],
            effortEnvironmentOverrides: [:],
            backendConfig: nil
        )
        let compatibleArgs = ClaudeCompatibleHeadlessRuntime.buildArguments(.init(
            runtimeConfig: compatibleRuntimeConfig,
            mcpConfigPath: nil,
            launchEnvironment: .init(
                effectiveModel: "sonnet",
                environmentOverrides: [:],
                backendID: .custom
            )
        ))
        XCTAssertTrue(compatibleArgs.contains("--bare"), "compatible backends must not inherit user settings env: \(compatibleArgs)")
        let settingSourcesIndex = try XCTUnwrap(compatibleArgs.firstIndex(of: "--setting-sources"), "compatible backends must restrict user settings sources: \(compatibleArgs)")
        XCTAssertEqual(compatibleArgs[compatibleArgs.index(after: settingSourcesIndex)], "project,local")
    }

    func testProviderCatalogDefaultsExposeStableRawValues() throws {
        XCTAssertEqual(ClaudeCompatibleProviderPluginID.allCases.map(\.rawValue), [
            "claude-code",
            "zai-claude-code",
            "kimi-claude-code",
            "custom-claude-compatible"
        ])
        XCTAssertEqual(ClaudeCompatibleRuntimeVariant(pluginID: .claudeCode), .standard)
        XCTAssertEqual(ClaudeCompatibleRuntimeVariant(pluginID: .zaiClaudeCode), .glm)
        XCTAssertEqual(ClaudeCompatibleRuntimeVariant(pluginID: .kimiClaudeCode), .kimi)
        XCTAssertEqual(ClaudeCompatibleRuntimeVariant(pluginID: .customClaudeCompatible), .customCompatible)

        let claude = ClaudeCompatibleModelCatalog.snapshot(pluginID: .claudeCode, includeEffortVariants: false)
        XCTAssertEqual(claude.pluginID, .claudeCode)
        XCTAssertEqual(claude.defaultModelRaw, "opus")
        XCTAssertEqual(claude.options.first?.rawValue, "default")
        XCTAssertEqual(claude.options.first?.isPlaceholderDefault, true)
        XCTAssertTrue(claude.options.contains { $0.rawValue == "claude-fable-5" && $0.supportedEffortLevels.contains("xhigh") })
        XCTAssertTrue(claude.options.contains { $0.rawValue == "opus[1m]" && $0.supportedEffortLevels.contains("xhigh") })
        let sonnet5 = try XCTUnwrap(claude.options.first { $0.rawValue == "claude-sonnet-5" })
        XCTAssertEqual(sonnet5.displayName, "Sonnet 5")
        XCTAssertEqual(sonnet5.supportedEffortLevels, ["low", "medium", "high", "max", "xhigh"])

        let expandedClaude = ClaudeCompatibleModelCatalog.snapshot(pluginID: .claudeCode)
        XCTAssertTrue(expandedClaude.options.contains { $0.rawValue == "claude-sonnet-5:max" })
        XCTAssertTrue(expandedClaude.options.contains { $0.rawValue == "claude-sonnet-5:xhigh" })

        let zai = ClaudeCompatibleModelCatalog.snapshot(pluginID: .zaiClaudeCode, includeEffortVariants: false)
        XCTAssertEqual(zai.defaultModelRaw, "sonnet")
        XCTAssertEqual(zai.options.map(\.rawValue), ["haiku", "sonnet", "opus", "glm-4.7", "glm-5-turbo", "glm-5.1"])
        XCTAssertEqual(zai.options.first { $0.rawValue == "haiku" }?.displayName, "GLM 4.5 Air — Haiku")
        XCTAssertEqual(zai.options.first { $0.rawValue == "sonnet" }?.displayName, "GLM 5.2 (1M) — Sonnet")
        XCTAssertEqual(zai.options.first { $0.rawValue == "opus" }?.displayName, "GLM 5.2 (1M) — Opus")
        XCTAssertEqual(zai.options.first { $0.rawValue == "glm-4.7" }?.displayName, "GLM 4.7")
        XCTAssertEqual(zai.options.first { $0.rawValue == "glm-5-turbo" }?.displayName, "GLM 5 Turbo")
        XCTAssertEqual(zai.options.first { $0.rawValue == "glm-5.1" }?.displayName, "GLM 5.1")
        XCTAssertEqual(zai.options.first { $0.rawValue == "haiku" }?.supportedEffortLevels, ["low", "medium", "high", "max"])
        XCTAssertEqual(zai.options.first { $0.rawValue == "sonnet" }?.supportedEffortLevels, ["low", "medium", "high", "max", "xhigh"])
        XCTAssertEqual(zai.options.first { $0.rawValue == "opus" }?.supportedEffortLevels, ["low", "medium", "high", "max", "xhigh"])
        XCTAssertEqual(zai.options.first { $0.isProviderDefault }?.rawValue, "sonnet")

        let expandedZai = ClaudeCompatibleModelCatalog.snapshot(pluginID: .zaiClaudeCode)
        XCTAssertTrue(expandedZai.options.contains { $0.rawValue == "sonnet:xhigh" })
        XCTAssertTrue(expandedZai.options.contains { $0.rawValue == "opus:xhigh" })
        XCTAssertTrue(expandedZai.options.contains { $0.rawValue == "glm-4.7:max" })
        XCTAssertTrue(expandedZai.options.contains { $0.rawValue == "glm-5-turbo:max" })
        XCTAssertTrue(expandedZai.options.contains { $0.rawValue == "glm-5.1:max" })
        XCTAssertFalse(expandedZai.options.contains { $0.rawValue == "haiku:xhigh" })
        XCTAssertFalse(expandedZai.options.contains { $0.rawValue == "glm-4.7:xhigh" })
        XCTAssertFalse(expandedZai.options.contains { $0.rawValue == "glm-5-turbo:xhigh" })
        XCTAssertFalse(expandedZai.options.contains { $0.rawValue == "glm-5.1:xhigh" })

        XCTAssertEqual(ClaudeCompatibleBackendID.glmZAI.defaultPreset.modelBehavior, .claudeSlotMapping(.init(
            haiku: "glm-4.5-air",
            sonnet: "glm-5.2[1m]",
            opus: "glm-5.2[1m]"
        )))
        XCTAssertEqual(ClaudeCompatibleModelNormalizer.normalizedRequestedModel("sonnet:xhigh"), "sonnet")
        XCTAssertEqual(ClaudeCompatibleModelNormalizer.normalizedSlotModel("sonnet:xhigh", config: ClaudeCompatibleBackendID.glmZAI.defaultPreset), "sonnet")
        XCTAssertEqual(ClaudeCompatibleModelNormalizer.normalizedSlotModel("glm-5.2[1m]:xhigh", config: ClaudeCompatibleBackendID.glmZAI.defaultPreset), "sonnet")
        XCTAssertEqual(ClaudeCompatibleHeadlessRuntime.runtimeModelParam("opus:xhigh"), "opus")
        XCTAssertEqual(ClaudeCompatibleHeadlessRuntime.runtimeModelParam("claude-sonnet-5:xhigh"), "claude-sonnet-5")
        XCTAssertEqual(ClaudeCompatibleModelNormalizer.normalizedGLMModel("glm-4.5-air", config: ClaudeCompatibleBackendID.glmZAI.defaultPreset), "haiku")
        XCTAssertEqual(ClaudeCompatibleModelNormalizer.normalizedGLMModel("glm-4.7", config: ClaudeCompatibleBackendID.glmZAI.defaultPreset), "haiku")
        XCTAssertEqual(ClaudeCompatibleModelNormalizer.normalizedGLMModel("glm-5.2", config: ClaudeCompatibleBackendID.glmZAI.defaultPreset), "sonnet")
        XCTAssertEqual(ClaudeCompatibleModelNormalizer.normalizedGLMModel("glm-5.2[1m]", config: ClaudeCompatibleBackendID.glmZAI.defaultPreset), "sonnet")
        XCTAssertEqual(ClaudeCompatibleModelNormalizer.normalizedGLMModel("glm-5-turbo", config: ClaudeCompatibleBackendID.glmZAI.defaultPreset), "sonnet")
        XCTAssertEqual(ClaudeCompatibleModelNormalizer.normalizedGLMModel("glm-5.1", config: ClaudeCompatibleBackendID.glmZAI.defaultPreset), "opus")
        XCTAssertTrue(ClaudeCompatibleModelNormalizer.isDirectSelectableGLMModel("glm-5-turbo:max"))
        XCTAssertTrue(ClaudeCompatibleModelNormalizer.isDirectSelectableGLMModel("glm-5.1"))
        XCTAssertEqual(ClaudeCompatibleModelNormalizer.directSelectableGLMSlotRawValue(for: "glm-5-turbo:max"), "sonnet")
        XCTAssertEqual(ClaudeCompatibleModelNormalizer.directSelectableGLMSlotRawValue(for: "glm-5.1"), "opus")
        XCTAssertTrue(ClaudeCompatibleModelNormalizer.supportsXHighEffort("glm-5.2"))
        XCTAssertTrue(ClaudeCompatibleModelNormalizer.supportsXHighEffort("glm-5.2[1m]"))
        XCTAssertEqual(ClaudeCompatibleModelNormalizer.contextWindowTokens(forBackendModelID: "glm-5.2[1m]"), 1_000_000)

        let kimi = ClaudeCompatibleModelCatalog.snapshot(pluginID: .kimiClaudeCode, includeEffortVariants: false)
        XCTAssertEqual(kimi.defaultModelRaw, "kimi-code")
        XCTAssertEqual(kimi.options.map(\.rawValue), ["kimi-code"])
        XCTAssertEqual(kimi.options.first?.displayName, "Kimi Code")
        XCTAssertEqual(kimi.options.first?.isProviderDefault, true)

        let custom = ClaudeCompatibleModelCatalog.snapshot(pluginID: .customClaudeCompatible, includeEffortVariants: false)
        XCTAssertEqual(custom.defaultModelRaw, "custom-claude-compatible")
        XCTAssertEqual(custom.options.map(\.rawValue), ["custom-claude-compatible"])
        XCTAssertEqual(custom.options.first?.displayName, "CC Custom")
        XCTAssertEqual(custom.options.first?.isProviderDefault, true)
    }

    func testResolverStripsEncodedEffortAndValidatesXHighAgainstBackendModelID() async throws {
        let config = ClaudeCompatibleBackendConfig(
            id: .glmZAI,
            isEnabled: true,
            displayName: "CC Zai",
            baseURL: "https://api.z.ai/api/anthropic",
            auth: .anthropicAuthToken,
            modelBehavior: .claudeSlotMapping(.init(
                haiku: "glm-4.5-air",
                sonnet: "glm-5.2[1m]",
                opus: "glm-5.2"
            ))
        )
        let resolver = ClaudeCompatibleLaunchEnvironmentResolver(
            backendConfigProvider: { id in
                id == .glmZAI ? config : id.defaultPreset
            },
            zaiSecretProvider: { "secret" },
            backendSecretProvider: { _ in "secret" }
        )

        let sonnet = try await resolver.resolve(variant: .glm, requestedModel: "sonnet:xhigh")
        XCTAssertEqual(sonnet.effectiveModel, "sonnet")
        XCTAssertEqual(sonnet.environmentOverrides["CLAUDE_CODE_AUTO_COMPACT_WINDOW"], "1000000")

        let opus = try await resolver.resolve(variant: .glm, requestedModel: "opus:xhigh")
        XCTAssertEqual(opus.effectiveModel, "opus")
        XCTAssertNil(opus.environmentOverrides["CLAUDE_CODE_AUTO_COMPACT_WINDOW"])

        let haikuMax = try await resolver.resolve(variant: .glm, requestedModel: "haiku:max")
        XCTAssertEqual(haikuMax.effectiveModel, "haiku")

        let directTurbo = try await resolver.resolve(variant: .glm, requestedModel: "glm-5-turbo:max")
        XCTAssertEqual(directTurbo.effectiveModel, "sonnet")
        XCTAssertEqual(directTurbo.environmentOverrides["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "glm-4.5-air")
        XCTAssertEqual(directTurbo.environmentOverrides["ANTHROPIC_DEFAULT_SONNET_MODEL"], "glm-5-turbo")
        XCTAssertEqual(directTurbo.environmentOverrides["ANTHROPIC_DEFAULT_OPUS_MODEL"], "glm-5.2")
        XCTAssertNil(directTurbo.environmentOverrides["CLAUDE_CODE_AUTO_COMPACT_WINDOW"])

        let directGLM51 = try await resolver.resolve(variant: .glm, requestedModel: "glm-5.1")
        XCTAssertEqual(directGLM51.effectiveModel, "opus")
        XCTAssertEqual(directGLM51.environmentOverrides["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "glm-4.5-air")
        XCTAssertEqual(directGLM51.environmentOverrides["ANTHROPIC_DEFAULT_SONNET_MODEL"], "glm-5.2[1m]")
        XCTAssertEqual(directGLM51.environmentOverrides["ANTHROPIC_DEFAULT_OPUS_MODEL"], "glm-5.1")
        XCTAssertEqual(config.modelBehavior, .claudeSlotMapping(.init(
            haiku: "glm-4.5-air",
            sonnet: "glm-5.2[1m]",
            opus: "glm-5.2"
        )))

        do {
            _ = try await resolver.resolve(variant: .glm, requestedModel: "glm-5-turbo:xhigh")
            XCTFail("Expected glm-5-turbo:xhigh to be rejected")
        } catch ClaudeCompatibleProviderError.invalidConfiguration {
            // Expected.
        }

        do {
            _ = try await resolver.resolve(variant: .glm, requestedModel: "glm-5-turbo", requestedEffort: "xhigh")
            XCTFail("Expected glm-5-turbo with separate xhigh effort to be rejected")
        } catch ClaudeCompatibleProviderError.invalidConfiguration {
            // Expected.
        }

        do {
            _ = try await resolver.resolve(variant: .glm, requestedModel: "haiku", requestedEffort: "x-high")
            XCTFail("Expected haiku with separate x-high effort to be rejected")
        } catch ClaudeCompatibleProviderError.invalidConfiguration {
            // Expected.
        }

        do {
            _ = try await resolver.resolve(variant: .glm, requestedModel: "glm-5.1:xhigh")
            XCTFail("Expected glm-5.1:xhigh to be rejected")
        } catch ClaudeCompatibleProviderError.invalidConfiguration {
            // Expected.
        }

        do {
            _ = try await resolver.resolve(variant: .glm, requestedModel: "haiku:xhigh")
            XCTFail("Expected haiku:xhigh to be rejected when haiku maps to glm-4.5-air")
        } catch ClaudeCompatibleProviderError.invalidConfiguration {
            // Expected.
        }

        do {
            _ = try await resolver.resolve(variant: .glm, requestedModel: "glm-4.5-air:xhigh")
            XCTFail("Expected glm-4.5-air:xhigh to be rejected")
        } catch ClaudeCompatibleProviderError.invalidConfiguration {
            // Expected.
        }
    }

    func testNoModelBackendRejectsEffortEncodedSelections() async throws {
        let resolver = ClaudeCompatibleLaunchEnvironmentResolver(
            backendConfigProvider: { id in id.defaultPreset },
            zaiSecretProvider: { "secret" },
            backendSecretProvider: { _ in "secret" }
        )

        let kimi = try await resolver.resolve(variant: .kimi, requestedModel: "kimi-code")
        XCTAssertNil(kimi.effectiveModel)
        XCTAssertTrue(kimi.suppressesEffortSettings)

        do {
            _ = try await resolver.resolve(variant: .kimi, requestedModel: "kimi-code:xhigh")
            XCTFail("Expected no-model backend to reject effort-encoded selections")
        } catch ClaudeCompatibleProviderError.invalidConfiguration {
            // Expected.
        }

        do {
            _ = try await resolver.resolve(variant: .kimi, requestedModel: "kimi-code", requestedEffort: "max")
            XCTFail("Expected no-model backend to reject separate effort selections")
        } catch ClaudeCompatibleProviderError.invalidConfiguration {
            // Expected.
        }
    }
}
