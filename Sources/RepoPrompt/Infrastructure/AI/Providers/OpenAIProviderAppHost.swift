import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptHTTPProviders
import SwiftOpenAI

/// Composition adapter only. Keep these live reads at the provider's original request boundaries.
struct OpenAIProviderAppHost: OpenAIProviderHost {
    func validateEndpoint(_ url: URL, apiKey: String, consentEndpoint: String?) throws {
        try ProviderEndpointConsent.validate(url, apiKey: apiKey, consentEndpoint: consentEndpoint)
    }

    func serviceTierBase(for model: AIModel) -> AIModel {
        model.openAIServiceTierBase
    }

    func serviceTierOverride(for model: AIModel) -> String? {
        model.openAIServiceTierOverride
    }

    func usesResponsesAPI(for model: AIModel) -> Bool {
        model.usesResponsesAPI
    }

    func canStream(for model: AIModel) -> Bool {
        model.canStream
    }

    func providerModel(for model: AIModel) -> SwiftOpenAI.Model {
        model.toProviderModel() as! SwiftOpenAI.Model
    }

    func defaultReasoningEffort(for model: AIModel) -> String? {
        model.defaultReasoningEffort
    }

    func effectiveTemperature(for message: RepoPromptDomainRuntime.AIMessage, model: AIModel) -> Double? {
        message.effectiveTemperature(for: model)
    }

    func displayName(for model: AIModel) -> String {
        model.displayName
    }

    func maxTokens(for model: AIModel) -> Int? {
        model.maxTokens
    }

    func friendlyErrorDescription(_ error: any Error) -> String {
        error.asFriendlyString()
    }
}
