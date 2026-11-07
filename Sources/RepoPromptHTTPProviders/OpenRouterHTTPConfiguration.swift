import Foundation

/// Base provider configuration
package struct ProviderConfiguration: Codable {
    package var temperature: Double?
    package var maxTokens: Int?

    package init(temperature: Double? = nil, maxTokens: Int? = nil) {
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

/// OpenRouter-specific configuration
package struct OpenRouterConfiguration: Codable {
    package var baseConfig: ProviderConfiguration
    package var customHeaders: [String: String]
    package var useCustomSettings: Bool

    package init(temperature: Double? = nil, maxTokens: Int? = nil, customHeaders: [String: String] = [:], useCustomSettings: Bool = true) {
        baseConfig = ProviderConfiguration(temperature: temperature, maxTokens: maxTokens)
        self.customHeaders = customHeaders
        self.useCustomSettings = useCustomSettings
    }
}
