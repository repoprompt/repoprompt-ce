import Foundation
import RepoPromptACPProviders
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptHTTPProviders
import RepoPromptInstrumentation

class AIProviderFactory {
    /// Installed once by the app composition root; Infrastructure must not construct
    /// the app-side recorder itself (that would be a wrong-way edge into Features).
    private static let perfRecorderSlot = AgentModePerfRecorderBox()

    static func installPerfRecorder(_ recorder: any AgentModePerfRecording) {
        perfRecorderSlot.install(recorder)
    }

    /// The app-installed recorder (Noop until the composition root installs one).
    static var perfRecorder: any AgentModePerfRecording {
        perfRecorderSlot.snapshot()
    }

    static func createProvider(
        for providerType: AIProviderType,
        keyManager: KeyManager,
        ollamaURL: URL? = nil,
        azureConfiguration: AzureOpenAIConfiguration? = nil
    ) async throws -> AIProvider {
        // If Azure config is provided, skip key fetching
        if providerType == .azure, let config = azureConfiguration {
            return try await createProvider(
                for: providerType,
                key: "",
                ollamaURL: ollamaURL,
                azureConfiguration: config
            )
        }

        // CLI providers don't need API keys - they leverage existing authentication
        if providerType == .claudeCode || providerType == .codex || providerType == .openCode || providerType == .cursor || providerType == .grokBuild || providerType == .devin {
            return try await createProvider(
                for: providerType,
                key: "",
                ollamaURL: ollamaURL,
                azureConfiguration: azureConfiguration
            )
        }

        guard let key = try await keyManager.getAPIKey(for: providerType) else {
            throw AIProviderError.missingAPIKey
        }
        return try await createProvider(
            for: providerType,
            key: key,
            ollamaURL: ollamaURL,
            azureConfiguration: azureConfiguration
        )
    }

    static func createProvider(
        for providerType: AIProviderType,
        key: String,
        ollamaURL: URL? = nil,
        azureConfiguration: AzureOpenAIConfiguration? = nil,
        model: String? = nil
    ) async throws -> AIProvider {
        switch providerType {
        case .anthropic:
            return AnthropicProvider(apiKey: key, host: AnthropicAppHost())
        case .openAI:
            let raw = UserDefaults.standard.string(forKey: "customBaseURLOpenAI")
            let split = OpenAIURLHelper.splitBaseURLAndVersion(raw)
            let baseURL = split.base
            if let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, baseURL == nil {
                throw ProviderEndpointConsent.ValidationError.invalidEndpoint
            }
            let storedVersion = UserDefaults.standard.string(forKey: "customOpenAIVersionOverride")
            let finalVersion = storedVersion ?? split.version
            let serviceTier = UserDefaults.standard.string(forKey: "openAIServiceTier")
            return OpenAIProvider(host: OpenAIProviderAppHost(), apiKey: key, baseURL: baseURL, configuredMaxTokens: nil, overrideVersion: finalVersion, serviceTier: serviceTier, httpCredentialConsentEndpoint: UserDefaults.standard.string(forKey: "openAIHTTPConsentEndpoint"))
        case .ollama:
            let baseURL = ollamaURL ?? URL(string: "http://localhost:11434")!
            return OllamaProvider(host: OpenAIProviderAppHost(), baseURL: baseURL)
        case .azure:
            guard let config = azureConfiguration else {
                return BlankProvider()
            }
            return AzureOpenAIProvider(configuration: config, host: AzureOpenAIAppHost())
        case .openRouter:
            return OpenRouterProvider(apiKey: key, host: OpenRouterAppHost())
        case .gemini:
            return GeminiProvider(host: OpenAIProviderAppHost(), apiKey: key)
        case .deepseek:
            return DeepSeekProvider(host: OpenAIProviderAppHost(), apiKey: key)
        case .fireworks: // <-- Add Fireworks case
            return FireworksProvider(host: OpenAIProviderAppHost(), apiKey: key)
        case .grok: // <-- Add Grok case
            return GrokProvider(host: OpenAIProviderAppHost(), apiKey: key)
        case .groq: // <-- Add Groq case
            return GroqProvider(host: OpenAIProviderAppHost(), apiKey: key)
        case .zAI:
            return ZAIProvider(host: OpenAIProviderAppHost(), apiKey: key)
        case .claudeCode: // <-- Add Claude Code case
            return ClaudeCodeProvider()
        case .codex:
            // Standard non-agent Codex chat owns a fresh app-server client per request.
            return CodexCLIProvider(perfRecorder: perfRecorder)
        case .openCode:
            return OpenCodeCLIProvider()
        case .cursor:
            return CursorCLIProvider()
        case .grokBuild:
            return GrokBuildCLIProvider()
        case .devin:
            return DevinCLIProvider()
        case .customProvider:
            let config = try CustomProviderConfiguration.load()

            // The config should already have base URL (without version) and apiVersion split
            // Only do regex split as fallback for legacy configs
            let baseStr: String
            let version: String?

            if let storedVersion = config.apiVersion {
                // New config format: URL and version already split
                baseStr = config.url.hasSuffix("/") ? String(config.url.dropLast()) : config.url
                version = storedVersion
            } else {
                // Legacy fallback: config might still have version in URL
                let split = OpenAIURLHelper.splitBaseURLAndVersion(config.url)
                guard let base = split.base else { throw ProviderEndpointConsent.ValidationError.invalidEndpoint }
                baseStr = base.absoluteString
                version = split.version
            }

            try ProviderEndpointConsent.validate(baseStr, credentialBearing: ProviderEndpointConsent.hasCredentials(apiKey: key, customHeaders: config.headers), consentEndpoint: config.httpCredentialConsentEndpoint)

            // Read the configured maxTokens, defaulting as before
            var configuredMaxTokens = config.maxTokens ?? 8192
            if configuredMaxTokens == 0 {
                configuredMaxTokens = 2048
            }

            // Prefer the SwiftOpenAI-backed OpenAIProvider for any OpenAI-style API version: ^v\d+(...)? (e.g., v1, v1-beta, v4, v4.1, etc.)
            let openAIStyleVersion: Bool = {
                guard let v = version?.lowercased() else { return false }
                return v.range(of: #"^v\d+([A-Za-z0-9._-]+)?$"#, options: .regularExpression) != nil
            }()

            if openAIStyleVersion {
                guard let baseURL = URL(string: baseStr) else {
                    throw AIProviderError.missingURL
                }
                return OpenAIProvider(
                    host: OpenAIProviderAppHost(),
                    apiKey: key,
                    baseURL: baseURL,
                    configuredMaxTokens: configuredMaxTokens,
                    overrideVersion: version,
                    includeUsageInStream: false,
                    httpCredentialConsentEndpoint: config.httpCredentialConsentEndpoint
                )
            }

            // Fallback: manual HTTP provider for exotic/custom formats
            return CustomOpenAIProvider(
                host: CustomOpenAIAppHost(), baseURL: baseStr,
                apiKey: key,
                defaultModel: config.defaultModel,
                defaultTemperature: 0, // Keep deterministic by default; configurable later if needed
                customHeaders: config.headers,
                configuredMaxTokens: configuredMaxTokens,
                includeContentTypeHeader: config.includeContentTypeHeader,
                apiVersion: version,
                httpCredentialConsentEndpoint: config.httpCredentialConsentEndpoint
            )
        }
    }
}

/// A minimal provider that always throws .providerNotConfigured
class BlankProvider: AIProvider {
    func streamMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int?) -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: AIProviderError.providerNotConfigured)
        }
    }

    func completeMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int?) async throws -> AICompletionResult {
        throw AIProviderError.providerNotConfigured
    }

    func dispose() async {}
}

extension AIProviderType {
    static func displayName(for provider: AIProviderType) -> String {
        switch provider {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        case .azure: "Azure"
        case .openRouter: "OpenRouter"
        case .ollama: "Local"
        case .deepseek: "DeepSeek"
        case .fireworks: "Fireworks"
        case .customProvider: "Custom"
        case .grok: "Grok (xAI)"
        case .groq: "Groq"
        case .zAI: "Z.AI"
        case .claudeCode: "Claude Code"
        case .codex: "Codex CLI"
        case .openCode: "OpenCode"
        case .cursor: "Cursor CLI"
        case .grokBuild: "Grok Build"
        case .devin: "Devin"
        }
    }

    var displayName: String {
        Self.displayName(for: self)
    }
}

public typealias ProviderConversationCleanupAction = RepoPromptDomainRuntime.ProviderConversationCleanupAction
public typealias ProviderConversationCleanupHandle = RepoPromptDomainRuntime.ProviderConversationCleanupHandle
typealias ProviderConversationCleanupOutcome = RepoPromptDomainRuntime.ProviderConversationCleanupOutcome
typealias AIProviderCompletionOutcome = RepoPromptDomainRuntime.AIProviderCompletionOutcome
typealias AIStreamResult = RepoPromptDomainRuntime.AIStreamResult
typealias AICompletionResult = RepoPromptDomainRuntime.AICompletionResult
