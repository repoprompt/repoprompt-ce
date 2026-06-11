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
        XCTAssertEqual(config.normalizedDisplayName, "Claude Code GLM")
        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], "https://api.z.ai/api/anthropic")
        XCTAssertEqual(environment["ANTHROPIC_AUTH_TOKEN"], "secret")
        XCTAssertEqual(environment["API_TIMEOUT_MS"], "3000000")
        XCTAssertEqual(environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "h")
        XCTAssertEqual(environment["ANTHROPIC_DEFAULT_SONNET_MODEL"], "s")
        XCTAssertEqual(environment["ANTHROPIC_DEFAULT_OPUS_MODEL"], "o")
        XCTAssertEqual(ClaudeCompatibleBackendEnvironmentBuilder.removedEnvironmentKeys(config: config), ["ANTHROPIC_API_KEY"])

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
        XCTAssertFalse(glm.suppressesEffortSettings)

        let kimi = try await resolver.resolve(variant: .kimi, requestedModel: "kimi-code")
        XCTAssertEqual(kimi.backendID, .kimi)
        XCTAssertNil(kimi.effectiveModel)
        XCTAssertEqual(kimi.environmentOverrides["ANTHROPIC_API_KEY"], "kimi-secret")
        XCTAssertTrue(kimi.suppressesEffortSettings)

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
                effectiveModel: "sonnet",
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
    }

    func testProviderCatalogDefaultsExposeStableRawValues() {
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

        let zai = ClaudeCompatibleModelCatalog.snapshot(pluginID: .zaiClaudeCode, includeEffortVariants: false)
        XCTAssertEqual(zai.defaultModelRaw, "sonnet")
        XCTAssertEqual(zai.options.map(\.rawValue), ["haiku", "sonnet", "opus"])
        XCTAssertEqual(zai.options.first { $0.isProviderDefault }?.rawValue, "sonnet")

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
}
