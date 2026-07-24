import Foundation
import RepoPromptClaudeCompatibleProvider

typealias ClaudeCompatiblePluginID = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleProviderPluginID
typealias ClaudeCompatiblePluginBackendID = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleBackendID
typealias ClaudeCompatiblePluginRuntimeMode = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleRuntimeMode
typealias ClaudeCompatiblePluginToolContext = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleToolContext
typealias ClaudeCompatiblePluginBackendConfig = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleBackendConfig
typealias ClaudeCompatiblePluginBackendAuth = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleBackendAuth
typealias ClaudeCompatiblePluginBackendModelBehavior = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleBackendModelBehavior
typealias ClaudeCompatiblePluginSlotMapping = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleSlotMapping
typealias ClaudeCompatiblePluginRuntimeConfig = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleRuntimeConfig
typealias ClaudeCompatiblePluginLaunchEnvironment = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleLaunchEnvironment
typealias ClaudeCompatiblePluginAvailability = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleProviderAvailability
typealias ClaudeCompatiblePluginModelOption = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelOption
typealias ClaudeCompatiblePluginModelCatalogSnapshot = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelCatalogSnapshot
typealias ClaudeCompatiblePluginStreamResult = RepoPromptClaudeCompatibleProvider.ClaudeProviderStreamResult
typealias ClaudeCompatiblePluginRuntimeVariant = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleRuntimeVariant
typealias ClaudeCompatiblePluginProviderError = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleProviderError
typealias ClaudeCompatiblePluginPromptDeliveryMode = RepoPromptClaudeCompatibleProvider.ClaudeCompatiblePromptDeliveryMode
typealias ClaudeCompatiblePluginProtocolCodec = RepoPromptClaudeCompatibleProvider.ClaudeSDKProtocolCodec
typealias ClaudeCompatiblePluginNDJSONTranslator = RepoPromptClaudeCompatibleProvider.ClaudeSDKNDJSONTranslator
typealias ClaudeCompatiblePluginJSONValue = RepoPromptClaudeCompatibleProvider.ClaudeProviderJSONValue

/// Infrastructure-level facade for pure Claude-compatible provider package
/// helpers. This keeps lower-level Claude provider code from depending upward on
/// Agent Mode's feature bridge while preserving a single package import point.
enum ClaudeCompatibleProviderRuntimeBridge {
    static func pluginRuntimeVariant(for runtimeVariant: ClaudeCodeRuntimeVariant) -> ClaudeCompatiblePluginRuntimeVariant {
        switch runtimeVariant {
        case .standard:
            .standard
        case .glm:
            .glm
        case .kimi:
            .kimi
        case .customCompatible:
            .customCompatible
        }
    }

    static func runtimeVariant(for pluginVariant: ClaudeCompatiblePluginRuntimeVariant) -> ClaudeCodeRuntimeVariant {
        switch pluginVariant {
        case .standard:
            .standard
        case .glm:
            .glm
        case .kimi:
            .kimi
        case .customCompatible:
            .customCompatible
        }
    }

    static func pluginBackendID(for backendID: ClaudeCodeCompatibleBackendID) -> ClaudeCompatiblePluginBackendID {
        switch backendID {
        case .glmZAI:
            .glmZAI
        case .kimi:
            .kimi
        case .custom:
            .custom
        }
    }

    static func coreBackendID(for pluginBackendID: ClaudeCompatiblePluginBackendID) -> ClaudeCodeCompatibleBackendID {
        switch pluginBackendID {
        case .glmZAI:
            .glmZAI
        case .kimi:
            .kimi
        case .custom:
            .custom
        }
    }

    static func pluginBackendConfig(from config: ClaudeCodeCompatibleBackendConfig) -> ClaudeCompatiblePluginBackendConfig {
        let normalized = config.normalized
        return ClaudeCompatiblePluginBackendConfig(
            id: pluginBackendID(for: normalized.id),
            isEnabled: normalized.isEnabled,
            displayName: normalized.normalizedDisplayName,
            baseURL: normalized.normalizedBaseURL ?? normalized.baseURL,
            auth: pluginAuth(from: normalized.auth),
            modelBehavior: pluginModelBehavior(from: normalized.modelBehavior)
        )
    }

    static func runtimeConfig(
        from config: ClaudeCodeAgentConfig,
        mode explicitMode: ClaudeCompatiblePluginRuntimeMode? = nil
    ) -> ClaudeCompatiblePluginRuntimeConfig {
        let runtimeVariant = config.runtimeVariant
        return ClaudeCompatiblePluginRuntimeConfig(
            pluginID: pluginRuntimeVariant(for: runtimeVariant).pluginID,
            mode: explicitMode ?? pluginRuntimeMode(for: config.toolContext),
            commandName: config.commandName,
            additionalPathHints: config.additionalPathHints,
            modelString: config.modelString,
            enableDebugLogging: config.enableDebugLogging,
            sdkConnectTimeoutSeconds: config.sdkConnectTimeoutSeconds,
            sdkRelaunchMaxAttempts: config.sdkRelaunchMaxAttempts,
            permissionMode: config.permissionMode,
            allowNativeBashTool: config.allowNativeBashTool,
            toolContext: pluginToolContext(for: config.toolContext),
            disallowedBuiltInTools: config.disallowedBuiltInTools,
            mcpStrictMode: config.mcpStrictMode,
            toolSearchEnabled: config.toolSearchEnabled,
            effortLevel: config.effortLevel?.envValue,
            processEnvironmentOverrides: config.processEnvironmentOverrides,
            effortEnvironmentOverrides: config.effortEnvironmentOverrides,
            backendConfig: runtimeVariant.compatibleBackendID.map { pluginBackendConfig(from: ClaudeCodeCompatibleBackendStore.shared.config(for: $0).normalized) }
        )
    }

    static func launchEnvironment(from environment: ClaudeCodeLaunchEnvironment) -> ClaudeCompatiblePluginLaunchEnvironment {
        let backendID: ClaudeCompatiblePluginBackendID? = switch environment.backend {
        case .defaultClaude:
            nil
        case let .compatible(id):
            pluginBackendID(for: id)
        }
        return ClaudeCompatiblePluginLaunchEnvironment(
            effectiveModel: environment.effectiveModel,
            environmentOverrides: environment.environmentOverrides,
            removedEnvironmentKeys: environment.removedEnvironmentKeys,
            backendID: backendID,
            suppressesEffortSettings: environment.suppressesEffortSettings
        )
    }

    static func coreLaunchEnvironment(from environment: ClaudeCompatiblePluginLaunchEnvironment) -> ClaudeCodeLaunchEnvironment {
        let backend: ClaudeCodeLaunchEnvironment.Backend = if let backendID = environment.backendID {
            .compatible(coreBackendID(for: backendID))
        } else {
            .defaultClaude
        }
        return ClaudeCodeLaunchEnvironment(
            effectiveModel: environment.effectiveModel,
            environmentOverrides: environment.environmentOverrides,
            removedEnvironmentKeys: environment.removedEnvironmentKeys,
            backend: backend,
            suppressesEffortSettings: environment.suppressesEffortSettings
        )
    }

    static func resolveLaunchEnvironment(
        variant: ClaudeCodeRuntimeVariant,
        requestedModel: String?,
        requestedEffort: String? = nil,
        backendConfigProvider: @escaping @Sendable (ClaudeCodeCompatibleBackendID) -> ClaudeCodeCompatibleBackendConfig,
        zaiKeyProvider: @escaping @Sendable () async throws -> String?,
        backendSecretProvider: @escaping @Sendable (ClaudeCodeCompatibleBackendID) async throws -> String?
    ) async throws -> ClaudeCodeLaunchEnvironment {
        let resolver = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleLaunchEnvironmentResolver(
            backendConfigProvider: { backendID in
                pluginBackendConfig(from: backendConfigProvider(coreBackendID(for: backendID)))
            },
            zaiSecretProvider: zaiKeyProvider,
            backendSecretProvider: { backendID in
                try await backendSecretProvider(coreBackendID(for: backendID))
            }
        )
        do {
            let resolved = try await resolver.resolve(
                variant: pluginRuntimeVariant(for: variant),
                requestedModel: requestedModel,
                requestedEffort: requestedEffort
            )
            return coreLaunchEnvironment(from: resolved)
        } catch let ClaudeCompatiblePluginProviderError.invalidConfiguration(detail) {
            throw AIProviderError.invalidConfiguration(detail: detail)
        }
    }

    static func backendEnvironment(
        config: ClaudeCodeCompatibleBackendConfig,
        apiKey: String,
        selectedBackendModelID: String? = nil
    ) -> [String: String] {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleBackendEnvironmentBuilder.environment(
            config: pluginBackendConfig(from: config),
            apiKey: apiKey,
            selectedBackendModelID: selectedBackendModelID
        )
    }

    static func removedBackendEnvironmentKeys(config: ClaudeCodeCompatibleBackendConfig) -> Set<String> {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleBackendEnvironmentBuilder.removedEnvironmentKeys(
            config: pluginBackendConfig(from: config)
        )
    }

    static func decoratedUserMessage(_ userMessage: String, instructions: String) -> String {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatiblePromptDelivery.decoratedUserMessage(
            userMessage,
            instructions: instructions
        )
    }

    static func providerBoundUserMessage(
        _ userMessage: String,
        instructions: String,
        delivery: ClaudeAgentToolPreferences.AgentModePromptDelivery
    ) -> String {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatiblePromptDelivery.userMessage(
            userMessage,
            instructions: instructions,
            mode: pluginPromptDeliveryMode(for: delivery)
        )
    }

    static func sendsRepoPromptAsUserMessage(
        delivery: ClaudeAgentToolPreferences.AgentModePromptDelivery
    ) -> Bool {
        pluginPromptDeliveryMode(for: delivery).sendsRepoPromptAsUserMessage
    }

    static func nativeSystemPromptOverride(
        instructions: String,
        delivery: ClaudeAgentToolPreferences.AgentModePromptDelivery
    ) -> String? {
        pluginPromptDeliveryMode(for: delivery).nativeSystemPromptOverride(instructions: instructions)
    }

    static func buildHeadlessArguments(
        config: ClaudeCodeAgentConfig,
        context: HeadlessAgentContext,
        resumeSessionID: String? = nil,
        systemPromptOverride: String? = nil
    ) -> [String] {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleHeadlessRuntime.buildArguments(
            RepoPromptClaudeCompatibleProvider.ClaudeCompatibleHeadlessArgumentsRequest(
                runtimeConfig: runtimeConfig(from: config, mode: .discovery),
                mcpConfigPath: context.configURL?.path,
                launchEnvironment: context.launchEnvironment.map(launchEnvironment(from:)),
                resumeSessionID: resumeSessionID,
                systemPromptOverride: systemPromptOverride
            )
        )
    }

    static func modelCatalogSnapshot(
        pluginID: ClaudeCompatiblePluginID,
        backendConfig: ClaudeCodeCompatibleBackendConfig? = nil,
        includeEffortVariants: Bool = true
    ) -> ClaudeCompatiblePluginModelCatalogSnapshot {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelCatalog.snapshot(
            pluginID: pluginID,
            backendConfig: backendConfig.map(pluginBackendConfig(from:)),
            includeEffortVariants: includeEffortVariants
        )
    }

    static func streamResult(from providerResult: ClaudeCompatiblePluginStreamResult) -> AIStreamResult {
        AIStreamResult(
            type: providerResult.type,
            text: providerResult.text,
            reasoning: providerResult.reasoning,
            promptTokens: providerResult.promptTokens,
            completionTokens: providerResult.completionTokens,
            cost: providerResult.cost,
            toolName: providerResult.toolName,
            toolArgs: providerResult.toolArgs,
            toolOutput: providerResult.toolOutput,
            toolInvocationID: providerResult.toolInvocationID,
            toolResultJSON: providerResult.toolResultJSON,
            toolArgsJSON: providerResult.toolArgsJSON,
            toolIsError: providerResult.toolIsError,
            providerSessionID: providerResult.providerSessionID,
            stopReason: providerResult.stopReason,
            modelContextWindow: providerResult.modelContextWindow,
            contextUsedTokens: providerResult.contextUsedTokens,
            contentMessageID: providerResult.contentMessageID
        )
    }

    static func providerStreamResult(from streamResult: AIStreamResult) -> ClaudeCompatiblePluginStreamResult {
        ClaudeCompatiblePluginStreamResult(
            type: streamResult.type,
            text: streamResult.text,
            reasoning: streamResult.reasoning,
            promptTokens: streamResult.promptTokens,
            completionTokens: streamResult.completionTokens,
            cost: streamResult.cost,
            toolName: streamResult.toolName,
            toolArgs: streamResult.toolArgs,
            toolOutput: streamResult.toolOutput,
            toolInvocationID: streamResult.toolInvocationID,
            toolResultJSON: streamResult.toolResultJSON,
            toolArgsJSON: streamResult.toolArgsJSON,
            toolIsError: streamResult.toolIsError,
            providerSessionID: streamResult.providerSessionID,
            stopReason: streamResult.stopReason,
            modelContextWindow: streamResult.modelContextWindow,
            contextUsedTokens: streamResult.contextUsedTokens,
            contentMessageID: streamResult.contentMessageID
        )
    }

    static func normalizedRequestedModel(_ rawModel: String?) -> String? {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.normalizedRequestedModel(rawModel)
    }

    static func isGLMModel(_ rawModel: String?, config: ClaudeCodeCompatibleBackendConfig) -> Bool {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.isGLMModel(
            rawModel,
            config: pluginBackendConfig(from: config)
        )
    }

    static func normalizedGLMModel(_ rawModel: String?, config: ClaudeCodeCompatibleBackendConfig) -> String? {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.normalizedGLMModel(
            rawModel,
            config: pluginBackendConfig(from: config)
        )
    }

    static func normalizedSlotModel(
        _ rawModel: String?,
        config: ClaudeCodeCompatibleBackendConfig
    ) -> String? {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.normalizedSlotModel(
            rawModel,
            config: pluginBackendConfig(from: config)
        )
    }

    static func noModelRawValue(for backendID: ClaudeCodeCompatibleBackendID) -> String {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.noModelRawValue(
            for: pluginBackendID(for: backendID)
        )
    }

    static func supportsGLMXHighEffort(backendModelID: String?) -> Bool {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.supportsXHighEffort(backendModelID)
    }

    static func contextWindowTokens(forGLMBackendModelID backendModelID: String?) -> Int? {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.contextWindowTokens(
            forBackendModelID: backendModelID
        )
    }

    static var glmDefaultModelRawValue: String {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.defaultModelRawValue
    }

    static var glmHaikuEquivalentModelRawValue: String {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.haikuEquivalentModelRawValue
    }

    static var glmOpusEquivalentModelRawValue: String {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.opusEquivalentModelRawValue
    }

    static var glmDefaultRequestedModelRawValue: String {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.defaultRequestedModelRawValue
    }

    static var glmHaikuRequestedModelRawValue: String {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.haikuRequestedModelRawValue
    }

    static var glmOpusRequestedModelRawValue: String {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.opusRequestedModelRawValue
    }

    static var glmSupportedModelRawValues: [String] {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.supportedModelRawValues
    }

    static var directSelectableGLMModelRawValues: [String] {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.directSelectableGLMModelRawValues
    }

    static func isDirectSelectableGLMModel(_ rawModel: String?) -> Bool {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.isDirectSelectableGLMModel(rawModel)
    }

    static func directSelectableGLMSlotRawValue(for rawModel: String?) -> String? {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.directSelectableGLMSlotRawValue(for: rawModel)
    }

    private static func pluginRuntimeMode(for toolContext: MCPIntegrationHelper.CLIToolContext) -> ClaudeCompatiblePluginRuntimeMode {
        switch toolContext {
        case .agentRun, .terminal, .promptOnly:
            .agentMode
        case .discoverRun:
            .discovery
        }
    }

    private static func pluginToolContext(for toolContext: MCPIntegrationHelper.CLIToolContext) -> ClaudeCompatiblePluginToolContext {
        switch toolContext {
        case .agentRun:
            .agentRun
        case .discoverRun:
            .discoverRun
        case .terminal:
            .terminal
        case .promptOnly:
            .promptOnly
        }
    }

    private static func pluginAuth(from auth: ClaudeCodeCompatibleBackendConfig.Auth) -> ClaudeCompatiblePluginBackendAuth {
        switch auth {
        case .anthropicAPIKey:
            .anthropicAPIKey
        case .anthropicAuthToken:
            .anthropicAuthToken
        }
    }

    private static func pluginModelBehavior(
        from behavior: ClaudeCodeCompatibleBackendConfig.ModelBehavior
    ) -> ClaudeCompatiblePluginBackendModelBehavior {
        switch behavior {
        case .noModel:
            return .noModel
        case let .claudeSlotMapping(mapping):
            let normalized = mapping.normalized
            return .claudeSlotMapping(ClaudeCompatiblePluginSlotMapping(
                haiku: normalized.haiku,
                sonnet: normalized.sonnet,
                opus: normalized.opus
            ))
        }
    }

    private static func pluginPromptDeliveryMode(
        for delivery: ClaudeAgentToolPreferences.AgentModePromptDelivery
    ) -> ClaudeCompatiblePluginPromptDeliveryMode {
        switch delivery {
        case .userMessageXML:
            .userMessageXML
        case .userMessageXMLWithEmptySystemPrompt:
            .userMessageXMLWithEmptySystemPrompt
        case .nativeSystemPrompt:
            .nativeSystemPrompt
        }
    }
}
