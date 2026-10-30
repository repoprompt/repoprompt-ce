import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptHTTPProviders

struct AnthropicAppHost: AnthropicHTTPHost {
    func canStream(for model: AIModel) -> Bool {
        model.canStream
    }

    func modelName(for model: AIModel) -> String {
        model.modelName
    }

    func effectiveTemperature(for message: RepoPromptDomainRuntime.AIMessage, model: AIModel) -> Double? {
        message.effectiveTemperature(for: model)
    }
}

struct OpenRouterAppHost: OpenRouterHTTPHost {
    func canStream(for model: AIModel) -> Bool {
        model.canStream
    }

    func modelName(for model: AIModel) -> String {
        model.modelName
    }

    func effectiveTemperature(for message: RepoPromptDomainRuntime.AIMessage, model: AIModel) -> Double? {
        message.effectiveTemperature(for: model)
    }

    func configuration() -> OpenRouterConfiguration {
        ProviderConfigurationManager.shared.getOpenRouterConfiguration()
    }
}

struct CustomOpenAIAppHost: CustomOpenAIHTTPHost {
    func canStream(for model: AIModel) -> Bool {
        model.canStream
    }

    func modelName(for model: AIModel) -> String {
        model.modelName
    }

    func effectiveTemperature(for message: RepoPromptDomainRuntime.AIMessage, model: AIModel) -> Double? {
        message.effectiveTemperature(for: model)
    }

    func validateEndpoint(_ baseURL: String, apiKey: String, customHeaders: [String: String], consentEndpoint: String?) throws {
        try ProviderEndpointConsent.validate(baseURL, credentialBearing: ProviderEndpointConsent.hasCredentials(apiKey: apiKey, customHeaders: customHeaders), consentEndpoint: consentEndpoint)
    }
}
