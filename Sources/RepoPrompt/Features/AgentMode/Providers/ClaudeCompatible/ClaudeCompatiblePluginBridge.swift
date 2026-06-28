import Foundation

/// Agent Mode facade for Claude-compatible provider package DTOs.
///
/// Package imports and pure provider/runtime helpers live in
/// `ClaudeCompatibleProviderRuntimeBridge` under Infrastructure so lower-level
/// Claude provider code does not depend upward on Agent Mode. This bridge keeps
/// Agent Mode-specific mappings (provider kind, catalog availability, stream DTO
/// translation) centralized for the feature layer.
enum ClaudeCompatiblePluginBridge {
    static func pluginID(for agentKind: AgentProviderKind) -> ClaudeCompatiblePluginID? {
        switch agentKind {
        case .claudeCode:
            .claudeCode
        case .claudeCodeGLM:
            .zaiClaudeCode
        case .kimiCode:
            .kimiClaudeCode
        case .customClaudeCompatible:
            .customClaudeCompatible
        case .codexExec, .openCode, .cursor, .grokBuild:
            nil
        }
    }

    static func pluginID(for runtimeVariant: ClaudeCodeRuntimeVariant) -> ClaudeCompatiblePluginID {
        pluginRuntimeVariant(for: runtimeVariant).pluginID
    }

    static func pluginRuntimeVariant(for runtimeVariant: ClaudeCodeRuntimeVariant) -> ClaudeCompatiblePluginRuntimeVariant {
        ClaudeCompatibleProviderRuntimeBridge.pluginRuntimeVariant(for: runtimeVariant)
    }

    static func agentKind(for pluginID: ClaudeCompatiblePluginID) -> AgentProviderKind {
        switch pluginID {
        case .claudeCode:
            .claudeCode
        case .zaiClaudeCode:
            .claudeCodeGLM
        case .kimiClaudeCode:
            .kimiCode
        case .customClaudeCompatible:
            .customClaudeCompatible
        }
    }

    static func runtimeVariant(for pluginID: ClaudeCompatiblePluginID) -> ClaudeCodeRuntimeVariant {
        runtimeVariant(for: ClaudeCompatiblePluginRuntimeVariant(pluginID: pluginID))
    }

    static func runtimeVariant(for pluginVariant: ClaudeCompatiblePluginRuntimeVariant) -> ClaudeCodeRuntimeVariant {
        ClaudeCompatibleProviderRuntimeBridge.runtimeVariant(for: pluginVariant)
    }

    static func pluginBackendID(for backendID: ClaudeCodeCompatibleBackendID) -> ClaudeCompatiblePluginBackendID {
        ClaudeCompatibleProviderRuntimeBridge.pluginBackendID(for: backendID)
    }

    static func coreBackendID(for pluginBackendID: ClaudeCompatiblePluginBackendID) -> ClaudeCodeCompatibleBackendID {
        ClaudeCompatibleProviderRuntimeBridge.coreBackendID(for: pluginBackendID)
    }

    static func pluginBackendConfig(for backendID: ClaudeCodeCompatibleBackendID) -> ClaudeCompatiblePluginBackendConfig {
        pluginBackendConfig(from: ClaudeCodeCompatibleBackendStore.shared.config(for: backendID).normalized)
    }

    static func pluginBackendConfig(from config: ClaudeCodeCompatibleBackendConfig) -> ClaudeCompatiblePluginBackendConfig {
        ClaudeCompatibleProviderRuntimeBridge.pluginBackendConfig(from: config)
    }

    static func runtimeConfig(
        from config: ClaudeCodeAgentConfig,
        mode explicitMode: ClaudeCompatiblePluginRuntimeMode? = nil
    ) -> ClaudeCompatiblePluginRuntimeConfig {
        ClaudeCompatibleProviderRuntimeBridge.runtimeConfig(from: config, mode: explicitMode)
    }

    static func agentModeRuntimeConfig(
        agentKind: AgentProviderKind,
        modelString: String?,
        enableDebugLogging: Bool
    ) -> ClaudeCompatiblePluginRuntimeConfig? {
        guard let runtimeVariant = agentKind.claudeRuntimeVariant else { return nil }
        let config = ClaudeCodeAgentConfig.agentMode(
            modelString: modelString,
            runtimeVariant: runtimeVariant,
            enableDebugLogging: enableDebugLogging
        )
        return runtimeConfig(from: config, mode: .agentMode)
    }

    static func discoveryRuntimeConfig(
        agentKind: AgentProviderKind,
        modelString: String?,
        enableDebugLogging: Bool
    ) -> ClaudeCompatiblePluginRuntimeConfig? {
        guard let runtimeVariant = agentKind.claudeRuntimeVariant else { return nil }
        let config = ClaudeCodeAgentConfig.discovery(
            modelString: modelString,
            runtimeVariant: runtimeVariant,
            enableDebugLogging: enableDebugLogging
        )
        return runtimeConfig(from: config, mode: .discovery)
    }

    static func launchEnvironment(from environment: ClaudeCodeLaunchEnvironment) -> ClaudeCompatiblePluginLaunchEnvironment {
        ClaudeCompatibleProviderRuntimeBridge.launchEnvironment(from: environment)
    }

    static func coreLaunchEnvironment(from environment: ClaudeCompatiblePluginLaunchEnvironment) -> ClaudeCodeLaunchEnvironment {
        ClaudeCompatibleProviderRuntimeBridge.coreLaunchEnvironment(from: environment)
    }

    static func backendEnvironment(
        config: ClaudeCodeCompatibleBackendConfig,
        apiKey: String
    ) -> [String: String] {
        ClaudeCompatibleProviderRuntimeBridge.backendEnvironment(config: config, apiKey: apiKey)
    }

    static func removedBackendEnvironmentKeys(config: ClaudeCodeCompatibleBackendConfig) -> Set<String> {
        ClaudeCompatibleProviderRuntimeBridge.removedBackendEnvironmentKeys(config: config)
    }

    static func resolveLaunchEnvironment(
        variant: ClaudeCodeRuntimeVariant,
        requestedModel: String?,
        backendConfigProvider: @escaping @Sendable (ClaudeCodeCompatibleBackendID) -> ClaudeCodeCompatibleBackendConfig,
        zaiKeyProvider: @escaping @Sendable () async throws -> String?,
        backendSecretProvider: @escaping @Sendable (ClaudeCodeCompatibleBackendID) async throws -> String?
    ) async throws -> ClaudeCodeLaunchEnvironment {
        try await ClaudeCompatibleProviderRuntimeBridge.resolveLaunchEnvironment(
            variant: variant,
            requestedModel: requestedModel,
            backendConfigProvider: backendConfigProvider,
            zaiKeyProvider: zaiKeyProvider,
            backendSecretProvider: backendSecretProvider
        )
    }

    static func decoratedUserMessage(_ userMessage: String, instructions: String) -> String {
        ClaudeCompatibleProviderRuntimeBridge.decoratedUserMessage(userMessage, instructions: instructions)
    }

    static func providerBoundUserMessage(
        _ userMessage: String,
        instructions: String,
        delivery: ClaudeAgentToolPreferences.AgentModePromptDelivery
    ) -> String {
        ClaudeCompatibleProviderRuntimeBridge.providerBoundUserMessage(
            userMessage,
            instructions: instructions,
            delivery: delivery
        )
    }

    static func sendsRepoPromptAsUserMessage(
        delivery: ClaudeAgentToolPreferences.AgentModePromptDelivery
    ) -> Bool {
        ClaudeCompatibleProviderRuntimeBridge.sendsRepoPromptAsUserMessage(delivery: delivery)
    }

    static func nativeSystemPromptOverride(
        instructions: String,
        delivery: ClaudeAgentToolPreferences.AgentModePromptDelivery
    ) -> String? {
        ClaudeCompatibleProviderRuntimeBridge.nativeSystemPromptOverride(
            instructions: instructions,
            delivery: delivery
        )
    }

    static func buildHeadlessArguments(
        config: ClaudeCodeAgentConfig,
        context: HeadlessAgentContext,
        resumeSessionID: String? = nil,
        systemPromptOverride: String? = nil
    ) -> [String] {
        ClaudeCompatibleProviderRuntimeBridge.buildHeadlessArguments(
            config: config,
            context: context,
            resumeSessionID: resumeSessionID,
            systemPromptOverride: systemPromptOverride
        )
    }

    static func availability(
        for agentKind: AgentProviderKind,
        availability: AgentModelCatalog.AvailabilityContext = .current
    ) -> ClaudeCompatiblePluginAvailability? {
        guard let pluginID = pluginID(for: agentKind) else { return nil }
        let isAvailable = AgentModelCatalog.isAgentAvailable(agentKind, availability: availability)
        let reason: String? = isAvailable ? nil : unavailableReason(for: agentKind)
        return ClaudeCompatiblePluginAvailability(pluginID: pluginID, isAvailable: isAvailable, reason: reason)
    }

    static func streamResult(from providerResult: ClaudeCompatiblePluginStreamResult) -> AIStreamResult {
        ClaudeCompatibleProviderRuntimeBridge.streamResult(from: providerResult)
    }

    static func providerStreamResult(from streamResult: AIStreamResult) -> ClaudeCompatiblePluginStreamResult {
        ClaudeCompatibleProviderRuntimeBridge.providerStreamResult(from: streamResult)
    }

    private static func unavailableReason(for agentKind: AgentProviderKind) -> String {
        switch agentKind {
        case .claudeCode:
            "Claude Code is unavailable."
        case .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            "Claude-compatible backend is not configured."
        case .codexExec, .openCode, .cursor, .grokBuild:
            "Not a Claude-compatible provider."
        }
    }
}
