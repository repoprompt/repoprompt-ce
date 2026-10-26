//
//  DisposableProviderPool.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-01-08.
//

import Foundation

actor DisposableProviderPool {
    private let keyManager: KeyManager

    /// Caches for fallback if KeyManager returns invalid/empty values.
    /// Key-based providers (OpenAI, Anthropic, etc.) will store their key here.
    private var cachedKeys: [AIProviderType: String] = [:]

    /// Azure providers store their entire configuration so we can re-use them if fetching fails.
    private var cachedAzureConfigs: [AIProviderType: AzureOpenAIConfiguration] = [:]

    init(keyManager: KeyManager) {
        self.keyManager = keyManager
    }

    /// Returns a brand-new provider every time it's called.
    func createProvider(
        for model: AIModel,
        ollamaURL: URL? = nil,
        azureConfiguration: AzureOpenAIConfiguration? = nil
    ) async throws -> AIProvider {
        let providerType = model.providerType

        switch providerType {
        case .ollama:
            // For Ollama, the "key" is actually the user-typed URL
            return try await createOllamaProvider(for: providerType, ollamaURL: ollamaURL, azureConfiguration: azureConfiguration)

        case .azure:
            // For Azure, parse the stored JSON configuration
            return try await createAzureProvider(for: providerType, ollamaURL: ollamaURL, azureConfiguration: azureConfiguration)

        default:
            // For all other providers, pass the retrieved value as the API key
            return try await createStandardProvider(
                for: model,
                ollamaURL: ollamaURL,
                azureConfiguration: azureConfiguration
            )
        }
    }

    private func createOllamaProvider(
        for providerType: AIProviderType,
        ollamaURL: URL?,
        azureConfiguration: AzureOpenAIConfiguration?
    ) async throws -> AIProvider {
        let freshKeyOrNil = try? await keyManager.getAPIKey(for: providerType)

        // The user typically stores the URL in the KeyManager for Ollama
        if let typedURLStr = freshKeyOrNil, !typedURLStr.isEmpty, let typedURL = URL(string: typedURLStr) {
            // Found a valid URL from key manager
            return try await AIProviderFactory.createProvider(
                for: .ollama,
                key: "", // No actual API key for Ollama
                ollamaURL: typedURL,
                azureConfiguration: azureConfiguration
            )
        } else {
            // Fall back to default (http://localhost:11434)
            let fallbackURL = ollamaURL ?? URL(string: "http://localhost:11434")!
            return try await AIProviderFactory.createProvider(
                for: .ollama,
                key: "",
                ollamaURL: fallbackURL,
                azureConfiguration: azureConfiguration
            )
        }
    }

    private func createAzureProvider(
        for providerType: AIProviderType,
        ollamaURL: URL?,
        azureConfiguration: AzureOpenAIConfiguration?
    ) async throws -> AIProvider {
        // If an Azure config is directly provided, skip key fetching
        if let directConfig = azureConfiguration {
            return try await AIProviderFactory.createProvider(
                for: providerType,
                key: "", // We already have config
                ollamaURL: ollamaURL,
                azureConfiguration: directConfig
            )
        }

        // Otherwise, try to retrieve from KeyManager
        let freshKeyOrNil = try? await keyManager.getAPIKey(for: providerType)

        if let freshJSON = freshKeyOrNil,
           !freshJSON.isEmpty,
           let data = freshJSON.data(using: .utf8)
        {
            do {
                let config = try JSONDecoder().decode(AzureOpenAIConfiguration.self, from: data)
                cachedAzureConfigs[providerType] = config

                return try await AIProviderFactory.createProvider(
                    for: providerType,
                    key: "",
                    ollamaURL: ollamaURL,
                    azureConfiguration: config
                )
            } catch {
                AzureOpenAIProvider.debug("Failed to decode Azure configuration: \(error)")
            }
        }

        if let cachedConfig = cachedAzureConfigs[providerType] {
            // Fall back to previously cached config if available
            return try await AIProviderFactory.createProvider(
                for: providerType,
                key: "",
                ollamaURL: ollamaURL,
                // Cached configuration must not resurrect a revoked cleartext approval
                // when secure storage is temporarily unavailable.
                azureConfiguration: cachedConfig.revokingHTTPConsent()
            )
        } else {
            // If everything fails, create a blank provider
            return try await AIProviderFactory.createProvider(
                for: providerType,
                key: "",
                ollamaURL: ollamaURL,
                azureConfiguration: nil
            )
        }
    }

    private func createStandardProvider(
        for model: AIModel,
        ollamaURL: URL?,
        azureConfiguration: AzureOpenAIConfiguration?
    ) async throws -> AIProvider {
        let providerType = model.providerType

        // Try fetching a fresh key
        let freshKeyOrNil = try? await keyManager.getAPIKey(for: providerType)

        // Decide the final key
        let finalKey: String
        if let freshKey = freshKeyOrNil, !freshKey.isEmpty {
            finalKey = freshKey
            // Update our cache with the new fresh key
            cachedKeys[providerType] = freshKey
        } else if let cachedKey = cachedKeys[providerType], !cachedKey.isEmpty {
            finalKey = cachedKey
        } else {
            // If we fail to get anything from KeyManager AND we have no cached fallback,
            // fallback to empty string or handle error as you wish
            finalKey = ""
        }

        return try await AIProviderFactory.createProvider(
            for: providerType,
            key: finalKey,
            ollamaURL: ollamaURL,
            azureConfiguration: azureConfiguration,
            model: model.rawValue
        )
    }

    /// Optional convenience helper to handle disposal automatically.
    func withProvider<T>(
        for model: AIModel,
        ollamaURL: URL? = nil,
        azureConfiguration: AzureOpenAIConfiguration? = nil,
        body: (AIProvider) async throws -> T
    ) async throws -> T {
        let provider = try await createProvider(
            for: model,
            ollamaURL: ollamaURL,
            azureConfiguration: azureConfiguration
        )
        do {
            let result = try await body(provider)
            // Dispose after successful operation
            await provider.dispose()
            return result
        } catch {
            // Dispose after error
            await provider.dispose()
            throw error
        }
    }
}
