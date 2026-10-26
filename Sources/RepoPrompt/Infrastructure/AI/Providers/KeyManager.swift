import RepoPromptSecureStorage

/// Preserve the provider-specific cache key while secure storage owns the cache.
typealias KeyManager = SecureStorageKeyManager<AIProviderType>

extension SecureStorageKeyManager where Provider == AIProviderType {
    init(secureService: SecureKeysService = SecureKeysService()) {
        self.init(secureService: secureService) { $0.secureStorageAccount }
    }
}

extension AIProviderType {
    /// Maps each provider to its frozen secure-storage account.
    var secureStorageAccount: SecureStorageAccount? {
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
        case .grokBuild: .grokAPI
        case .zAI: .zAIAPI
        case .devin: nil
        }
    }
}
