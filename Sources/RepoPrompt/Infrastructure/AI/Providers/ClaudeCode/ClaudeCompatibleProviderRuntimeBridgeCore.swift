import Foundation
import RepoPromptAIContracts
import RepoPromptClaudeCompatibleProvider
import RepoPromptDomainRuntime
import RepoPromptProviderQuota

typealias ClaudeCompatiblePluginID = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleProviderPluginID
typealias ClaudeCompatiblePluginBackendID = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleBackendID
typealias ClaudeCompatiblePluginRuntimeMode = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleRuntimeMode
typealias ClaudeCompatiblePluginToolContext = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleToolContext
typealias ClaudeCompatibleBackendLimits = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleBackendLimits
typealias ClaudeCompatiblePluginBackendConfig = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleBackendConfig
typealias ClaudeCompatiblePluginBackendAuth = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleBackendAuth
typealias ClaudeCompatiblePluginBackendModelBehavior = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleBackendModelBehavior
typealias ClaudeCompatiblePluginSlotMapping = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleSlotMapping
typealias ClaudeCompatiblePluginRuntimeConfig = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleRuntimeConfig
typealias ClaudeCompatiblePluginLaunchEnvironment = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleLaunchEnvironment
typealias ClaudeCompatiblePluginAvailability = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleProviderAvailability
typealias ClaudeCompatiblePluginModelOption = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelOption
typealias ClaudeCompatiblePluginModelCatalogSnapshot = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelCatalogSnapshot
typealias ClaudeCompatiblePluginRateLimitInfo = RepoPromptClaudeCompatibleProvider.ClaudeProviderRateLimitInfo
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
    static func quotaObservation(from info: ClaudeCompatiblePluginRateLimitInfo) -> ClaudeProviderQuotaObservation {
        let status: ClaudeProviderQuotaObservation.Status = switch info.status {
        case .allowed: .allowed
        case .allowedWarning: .allowedWarning
        case .rejected: .rejected
        }
        return ClaudeProviderQuotaObservation(status: status, resetsAt: info.resetsAt, rateLimitType: info.rateLimitType, utilization: info.utilization)
    }

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

    static func decoratedUserMessage(_ userMessage: String, instructions: String) -> String {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatiblePromptDelivery.decoratedUserMessage(
            userMessage,
            instructions: instructions
        )
    }

    static func streamResult(from providerResult: ClaudeCompatiblePluginStreamResult) -> RepoPromptDomainRuntime.AIStreamResult {
        RepoPromptDomainRuntime.AIStreamResult(
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
            claudeToolUseID: providerResult.claudeToolUseID,
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

    static func providerStreamResult(from streamResult: RepoPromptDomainRuntime.AIStreamResult) -> ClaudeCompatiblePluginStreamResult {
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
            claudeToolUseID: streamResult.claudeToolUseID,
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

}
