//
//  ProviderConfiguration.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-03-01.
//

import Foundation
import RepoPromptAIContracts

/// Base provider configuration
struct ProviderConfiguration: Codable {
    var temperature: Double?
    var maxTokens: Int?

    init(temperature: Double? = nil, maxTokens: Int? = nil) {
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

/// OpenRouter-specific configuration
struct OpenRouterConfiguration: Codable {
    var baseConfig: ProviderConfiguration
    var customHeaders: [String: String]
    var useCustomSettings: Bool

    init(temperature: Double? = nil, maxTokens: Int? = nil, customHeaders: [String: String] = [:], useCustomSettings: Bool = true) {
        baseConfig = ProviderConfiguration(temperature: temperature, maxTokens: maxTokens)
        self.customHeaders = customHeaders
        self.useCustomSettings = useCustomSettings
    }
}

/// Singleton to manage provider configurations
class ProviderConfigurationManager {
    static let shared = ProviderConfigurationManager()

    private init() {}

    /// Standardized key format
    private func storageKey(for providerType: AIProviderType) -> String {
        "provider_config_\(providerType)"
    }

    /// Generic configuration
    func getConfiguration(for providerType: AIProviderType) -> ProviderConfiguration {
        let key = storageKey(for: providerType)
        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(ProviderConfiguration.self, from: data)
        else {
            return ProviderConfiguration()
        }
        return config
    }

    func saveConfiguration(_ config: ProviderConfiguration, for providerType: AIProviderType) {
        let key = storageKey(for: providerType)
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// OpenRouter specific configuration
    func getOpenRouterConfiguration() -> OpenRouterConfiguration {
        let key = "openrouter_configuration"
        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(OpenRouterConfiguration.self, from: data)
        else {
            return OpenRouterConfiguration()
        }
        return config
    }

    func saveOpenRouterConfiguration(_ config: OpenRouterConfiguration) {
        let key = "openrouter_configuration"
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
