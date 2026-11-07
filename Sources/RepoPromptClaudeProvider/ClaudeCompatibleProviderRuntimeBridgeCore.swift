import Foundation
import RepoPromptAIContracts
import RepoPromptClaudeCompatibleProvider
import RepoPromptDomainRuntime
import RepoPromptProviderQuota

package typealias ClaudeCompatiblePluginID = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleProviderPluginID
package typealias ClaudeCompatiblePluginBackendID = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleBackendID
package typealias ClaudeCompatiblePluginRuntimeMode = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleRuntimeMode
package typealias ClaudeCompatiblePluginToolContext = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleToolContext
package typealias ClaudeCompatibleBackendLimits = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleBackendLimits
package typealias ClaudeCompatiblePluginBackendConfig = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleBackendConfig
package typealias ClaudeCompatiblePluginBackendAuth = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleBackendAuth
package typealias ClaudeCompatiblePluginBackendModelBehavior = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleBackendModelBehavior
package typealias ClaudeCompatiblePluginSlotMapping = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleSlotMapping
package typealias ClaudeCompatiblePluginRuntimeConfig = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleRuntimeConfig
package typealias ClaudeCompatiblePluginLaunchEnvironment = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleLaunchEnvironment
package typealias ClaudeCompatiblePluginAvailability = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleProviderAvailability
package typealias ClaudeCompatiblePluginModelOption = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelOption
package typealias ClaudeCompatiblePluginModelCatalogSnapshot = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelCatalogSnapshot
package typealias ClaudeCompatiblePluginRateLimitInfo = RepoPromptClaudeCompatibleProvider.ClaudeProviderRateLimitInfo
package typealias ClaudeCompatiblePluginStreamResult = RepoPromptClaudeCompatibleProvider.ClaudeProviderStreamResult
package typealias ClaudeCompatiblePluginRuntimeVariant = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleRuntimeVariant
package typealias ClaudeCompatiblePluginProviderError = RepoPromptClaudeCompatibleProvider.ClaudeCompatibleProviderError
package typealias ClaudeCompatiblePluginPromptDeliveryMode = RepoPromptClaudeCompatibleProvider.ClaudeCompatiblePromptDeliveryMode
package typealias ClaudeCompatiblePluginProtocolCodec = RepoPromptClaudeCompatibleProvider.ClaudeSDKProtocolCodec
package typealias ClaudeCompatiblePluginNDJSONTranslator = RepoPromptClaudeCompatibleProvider.ClaudeSDKNDJSONTranslator
package typealias ClaudeCompatiblePluginJSONValue = RepoPromptClaudeCompatibleProvider.ClaudeProviderJSONValue
package typealias ClaudeCompatiblePluginAutoCompactWindow = RepoPromptClaudeCompatibleProvider.ClaudeAutoCompactWindow

/// Infrastructure-level facade for pure Claude-compatible provider package
/// helpers. This keeps lower-level Claude provider code from depending upward on
/// Agent Mode's feature bridge while preserving a single package import point.
package enum ClaudeCompatibleProviderRuntimeBridge {
    package static func buildHeadlessArguments(
        runtimeConfig: ClaudeCompatiblePluginRuntimeConfig,
        mcpConfigPath: String?,
        launchEnvironment: ClaudeCompatiblePluginLaunchEnvironment?,
        resumeSessionID: String?,
        systemPromptOverride: String?
    ) -> [String] {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleHeadlessRuntime.buildArguments(
            RepoPromptClaudeCompatibleProvider.ClaudeCompatibleHeadlessArgumentsRequest(
                runtimeConfig: runtimeConfig,
                mcpConfigPath: mcpConfigPath,
                launchEnvironment: launchEnvironment,
                resumeSessionID: resumeSessionID,
                systemPromptOverride: systemPromptOverride
            )
        )
    }

    package static func quotaObservation(from info: ClaudeCompatiblePluginRateLimitInfo) -> ClaudeProviderQuotaObservation {
        let status: ClaudeProviderQuotaObservation.Status = switch info.status {
        case .allowed: .allowed
        case .allowedWarning: .allowedWarning
        case .rejected: .rejected
        }
        return ClaudeProviderQuotaObservation(status: status, resetsAt: info.resetsAt, rateLimitType: info.rateLimitType, utilization: info.utilization)
    }

    package static func pluginRuntimeVariant(for runtimeVariant: ClaudeCodeRuntimeVariant) -> ClaudeCompatiblePluginRuntimeVariant {
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

    package static func runtimeVariant(for pluginVariant: ClaudeCompatiblePluginRuntimeVariant) -> ClaudeCodeRuntimeVariant {
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

    package static func decoratedUserMessage(_ userMessage: String, instructions: String) -> String {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatiblePromptDelivery.decoratedUserMessage(
            userMessage,
            instructions: instructions
        )
    }

    package static func streamResult(from providerResult: ClaudeCompatiblePluginStreamResult) -> RepoPromptDomainRuntime.AIStreamResult {
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

    package static func providerStreamResult(from streamResult: RepoPromptDomainRuntime.AIStreamResult) -> ClaudeCompatiblePluginStreamResult {
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

    package static func normalizedRequestedModel(_ rawModel: String?) -> String? {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.normalizedRequestedModel(rawModel)
    }

    package static func supportsGLMXHighEffort(backendModelID: String?) -> Bool {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.supportsXHighEffort(backendModelID)
    }

    package static func contextWindowTokens(forGLMBackendModelID backendModelID: String?) -> Int? {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.contextWindowTokens(
            forBackendModelID: backendModelID
        )
    }

    package static var glmDefaultModelRawValue: String {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.defaultModelRawValue
    }

    package static var glmHaikuEquivalentModelRawValue: String {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.haikuEquivalentModelRawValue
    }

    package static var glmOpusEquivalentModelRawValue: String {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.opusEquivalentModelRawValue
    }

    package static var glmDefaultRequestedModelRawValue: String {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.defaultRequestedModelRawValue
    }

    package static var glmHaikuRequestedModelRawValue: String {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.haikuRequestedModelRawValue
    }

    package static var glmOpusRequestedModelRawValue: String {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.opusRequestedModelRawValue
    }

    package static var glmSupportedModelRawValues: [String] {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.supportedModelRawValues
    }

    package static var directSelectableGLMModelRawValues: [String] {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.directSelectableGLMModelRawValues
    }

    package static func isDirectSelectableGLMModel(_ rawModel: String?) -> Bool {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.isDirectSelectableGLMModel(rawModel)
    }

    package static func directSelectableGLMSlotRawValue(for rawModel: String?) -> String? {
        RepoPromptClaudeCompatibleProvider.ClaudeCompatibleModelNormalizer.directSelectableGLMSlotRawValue(for: rawModel)
    }
}
