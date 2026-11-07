import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime

/// Required policy capabilities. Providers invoke these at existing reads, never from a cached request snapshot.
package protocol AnthropicHTTPHost {
    func canStream(for model: AIModel) -> Bool
    func modelName(for model: AIModel) -> String
    func effectiveTemperature(for message: RepoPromptDomainRuntime.AIMessage, model: AIModel) -> Double?
}

package protocol OpenRouterHTTPHost {
    func canStream(for model: AIModel) -> Bool
    func modelName(for model: AIModel) -> String
    func effectiveTemperature(for message: RepoPromptDomainRuntime.AIMessage, model: AIModel) -> Double?
    func configuration() -> OpenRouterConfiguration
}

package protocol CustomOpenAIHTTPHost {
    func canStream(for model: AIModel) -> Bool
    func modelName(for model: AIModel) -> String
    func effectiveTemperature(for message: RepoPromptDomainRuntime.AIMessage, model: AIModel) -> Double?
    func validateEndpoint(_ baseURL: String, apiKey: String, customHeaders: [String: String], consentEndpoint: String?) throws
}

package protocol AzureOpenAIHTTPHost {
    func validateEndpoint(_ url: URL, apiKey: String, customHeaders: [String: String], consentEndpoint: String?) throws
    func modelFromName(_ name: String) -> AIModel?
    func modelName(for model: AIModel) -> String
    func rawValue(for model: AIModel) -> String
    func displayName(for model: AIModel) -> String
    func usesResponsesAPI(for model: AIModel) -> Bool
    func canStream(for model: AIModel) -> Bool
    func defaultReasoningEffort(for model: AIModel) -> String?
    func effectiveTemperature(for message: RepoPromptDomainRuntime.AIMessage, model: AIModel) -> Double?
    func defaultDescriptor(for identifier: String) -> AzureOpenAIConfiguration.ModelDescriptor?
    func discoveryDescriptor(id: String, baseModelID: String?) -> AzureOpenAIConfiguration.ModelDescriptor
}
