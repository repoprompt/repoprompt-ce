import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import SwiftOpenAI

/// App-owned policy evaluated synchronously at each existing provider read/effect point.
/// This capability is required; the HTTP owner must not install ambient policy defaults.
package protocol OpenAIProviderHost {
    func validateEndpoint(_ url: URL, apiKey: String, consentEndpoint: String?) throws
    func serviceTierBase(for model: AIModel) -> AIModel
    func serviceTierOverride(for model: AIModel) -> String?
    func usesResponsesAPI(for model: AIModel) -> Bool
    func canStream(for model: AIModel) -> Bool
    func providerModel(for model: AIModel) -> SwiftOpenAI.Model
    func defaultReasoningEffort(for model: AIModel) -> String?
    func effectiveTemperature(for message: RepoPromptDomainRuntime.AIMessage, model: AIModel) -> Double?
    func displayName(for model: AIModel) -> String
    func maxTokens(for model: AIModel) -> Int?
    func friendlyErrorDescription(_ error: any Error) -> String
}
