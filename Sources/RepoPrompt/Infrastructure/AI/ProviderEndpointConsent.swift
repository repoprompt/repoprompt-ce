import Foundation
import RepoPromptClaudeCompatibleProvider

/// Use the same intended-endpoint policy at app requests and Claude-compatible launches.
/// Neither this policy nor an acknowledgement secures redirects or proxy routing.
typealias ProviderEndpointConsent = ProviderEndpointConsentPolicy

extension ProviderEndpointConsentPolicy {
    static func hasCredentials(apiKey: String, customHeaders: [String: String] = [:]) -> Bool {
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        let nonSecretHeaders: Set = ["accept", "content-type"]
        return customHeaders.contains { key, value in
            !value.isEmpty && !nonSecretHeaders.contains(key.lowercased())
        }
    }

    static func validate(_ url: URL, apiKey: String, customHeaders: [String: String] = [:], consentEndpoint: String?) throws {
        try validate(url.absoluteString, credentialBearing: hasCredentials(apiKey: apiKey, customHeaders: customHeaders), consentEndpoint: consentEndpoint)
    }
}
