import Foundation

actor KeyManager {
    private let secureService: SecureKeysService

    /// Simple in-memory store of keys
    private var cache = [AIProviderType: String]()

    init(secureService: SecureKeysService = SecureKeysService()) {
        self.secureService = secureService
    }

    /// Lazily loads the key from disk only if not already in the `cache`.
    func getAPIKey(
        for provider: AIProviderType,
        accessMode: KeychainAccessMode = .interactive
    ) async throws -> String? {
        if let cached = cache[provider] {
            return cached
        }

        let account = provider.secureStorageAccount
        let keyFromDisk = try await secureService.getAPIKey(for: account, accessMode: accessMode)

        if let k = keyFromDisk {
            cache[provider] = k
        }

        return keyFromDisk
    }

    /// Saves to both in-memory cache and disk.
    func saveAPIKey(
        _ key: String,
        for provider: AIProviderType,
        accessMode: KeychainAccessMode = .interactive
    ) throws {
        cache[provider] = key
        let account = provider.secureStorageAccount
        try secureService.saveAPIKey(key, for: account, accessMode: accessMode)
    }

    /// Deletes from both in-memory cache and disk.
    func deleteAPIKey(
        for provider: AIProviderType,
        accessMode: KeychainAccessMode = .interactive
    ) throws {
        cache.removeValue(forKey: provider)
        let account = provider.secureStorageAccount
        try secureService.deleteAPIKey(for: account, accessMode: accessMode)
    }
}

extension AIProviderType {
    /// Maps each provider to its frozen secure-storage account.
    var secureStorageAccount: SecureStorageAccount {
        switch self {
        case .anthropic: .anthropicAPI
        case .openAI: .openAIAPI
        case .gemini: .geminiAPI
        case .openRouter: .openRouterAPI
        case .ollama: .ollamaURL
        case .azure: .azureAPI
        case .deepseek: .deepSeekAPI
        case .customProvider: .customProviderAPI
        case .fireworks: .fireworksAPI
        case .grok: .grokAPI
        case .groq: .groqAPI
        case .claudeCode: .claudeCodeAPI
        case .codex: .codexCLIAPI
        case .openCode: .openCodeCLIAPI
        case .cursor: .cursorCLIAPI
        case .zAI: .zAIAPI
        }
    }
}
