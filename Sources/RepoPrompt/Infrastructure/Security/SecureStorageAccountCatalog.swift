import Foundation

/// Closed inventory of every account identifier persisted through secure storage.
///
/// These identifiers are persistence keys. Changing one requires an explicit migration.
enum SecureStorageAccount: CaseIterable, Hashable, Identifiable {
    // Provider and CLI accounts.
    case anthropicAPI
    case openAIAPI
    case geminiAPI
    case openRouterAPI
    case ollamaURL
    case azureAPI
    case deepSeekAPI
    case customProviderAPI
    case fireworksAPI
    case grokAPI
    case groqAPI
    case claudeCodeAPI
    case codexCLIAPI
    case openCodeCLIAPI
    case cursorCLIAPI
    case zAIAPI

    // Claude-compatible backend accounts.
    case claudeCompatibleKimiAPIKey
    case claudeCompatibleCustomAPIKey

    // Agent permission document accounts.
    case agentPermissionSubagentDocument
    case agentPermissionCodexDocument
    case agentPermissionClaudeDocument
    case agentPermissionOpenCodeDocument
    case agentPermissionCursorDocument

    var identifier: String {
        switch self {
        case .anthropicAPI:
            "AnthropicAPI"
        case .openAIAPI:
            "OpenAIAPI"
        case .geminiAPI:
            "GeminiAPI"
        case .openRouterAPI:
            "OpenRouterAPI"
        case .ollamaURL:
            "OllamaURL"
        case .azureAPI:
            "AzureAPI"
        case .deepSeekAPI:
            "DeepSeekAPI"
        case .customProviderAPI:
            "CustomProviderAPI"
        case .fireworksAPI:
            "FireworksAPI"
        case .grokAPI:
            "GrokAPI"
        case .groqAPI:
            "GroqAPI"
        case .claudeCodeAPI:
            "ClaudeCodeAPI"
        case .codexCLIAPI:
            "CodexCLIAPI"
        case .openCodeCLIAPI:
            "OpenCodeCLIAPI"
        case .cursorCLIAPI:
            "CursorCLIAPI"
        case .zAIAPI:
            "ZAIAPI"
        case .claudeCompatibleKimiAPIKey:
            "ClaudeCompatibleBackend.kimi.apiKey"
        case .claudeCompatibleCustomAPIKey:
            "ClaudeCompatibleBackend.custom.apiKey"
        case .agentPermissionSubagentDocument:
            Self.decode([
                40, 42, 116, 59, 61, 63, 52, 46, 116, 42, 63, 40, 55, 51, 41, 41,
                51, 53, 52, 41, 116, 41, 47, 56, 59, 61, 63, 52, 46, 116, 44, 107
            ])
        case .agentPermissionCodexDocument:
            Self.decode([
                40, 42, 116, 59, 61, 63, 52, 46, 116, 42, 63, 40, 55, 51, 41, 41,
                51, 53, 52, 41, 116, 57, 53, 62, 63, 34, 116, 44, 107
            ])
        case .agentPermissionClaudeDocument:
            Self.decode([
                40, 42, 116, 59, 61, 63, 52, 46, 116, 42, 63, 40, 55, 51, 41, 41,
                51, 53, 52, 41, 116, 57, 54, 59, 47, 62, 63, 116, 44, 107
            ])
        case .agentPermissionOpenCodeDocument:
            Self.decode([
                40, 42, 116, 59, 61, 63, 52, 46, 116, 42, 63, 40, 55, 51, 41, 41,
                51, 53, 52, 41, 116, 53, 42, 63, 52, 25, 53, 62, 63, 116, 44, 107
            ])
        case .agentPermissionCursorDocument:
            Self.decode([
                40, 42, 116, 59, 61, 63, 52, 46, 116, 42, 63, 40, 55, 51, 41, 41,
                51, 53, 52, 41, 116, 57, 47, 40, 41, 53, 40, 116, 44, 107
            ])
        }
    }

    var id: String {
        identifier
    }

    var displayName: String {
        switch self {
        case .anthropicAPI: "Anthropic API key"
        case .openAIAPI: "OpenAI API key"
        case .geminiAPI: "Gemini API key"
        case .openRouterAPI: "OpenRouter API key"
        case .ollamaURL: "Local model URL"
        case .azureAPI: "Azure OpenAI credentials"
        case .deepSeekAPI: "DeepSeek API key"
        case .customProviderAPI: "Custom provider API key"
        case .fireworksAPI: "Fireworks API key"
        case .grokAPI: "Grok API key"
        case .groqAPI: "Groq API key"
        case .claudeCodeAPI: "Claude Code API key"
        case .codexCLIAPI: "Codex CLI API key"
        case .openCodeCLIAPI: "OpenCode CLI API key"
        case .cursorCLIAPI: "Cursor CLI API key"
        case .zAIAPI: "Z.AI API key"
        case .claudeCompatibleKimiAPIKey: "Kimi compatible API key"
        case .claudeCompatibleCustomAPIKey: "Custom Claude-compatible API key"
        case .agentPermissionSubagentDocument: "Subagent permissions"
        case .agentPermissionCodexDocument: "Codex permissions"
        case .agentPermissionClaudeDocument: "Claude permissions"
        case .agentPermissionOpenCodeDocument: "OpenCode permissions"
        case .agentPermissionCursorDocument: "Cursor permissions"
        }
    }

    private static func decode(_ bytes: [UInt8]) -> String {
        SecurityObfuscation.decode(bytes)
    }
}

enum SecureStorageAccountCatalog {
    static let providerAndCLIAccounts: [SecureStorageAccount] = [
        .anthropicAPI,
        .openAIAPI,
        .geminiAPI,
        .openRouterAPI,
        .ollamaURL,
        .azureAPI,
        .deepSeekAPI,
        .customProviderAPI,
        .fireworksAPI,
        .grokAPI,
        .groqAPI,
        .claudeCodeAPI,
        .codexCLIAPI,
        .openCodeCLIAPI,
        .cursorCLIAPI,
        .zAIAPI
    ]

    static let claudeCompatibleAccounts: [SecureStorageAccount] = [
        .zAIAPI,
        .claudeCompatibleKimiAPIKey,
        .claudeCompatibleCustomAPIKey
    ]

    static let agentPermissionAccounts: [SecureStorageAccount] = [
        .agentPermissionSubagentDocument,
        .agentPermissionCodexDocument,
        .agentPermissionClaudeDocument,
        .agentPermissionOpenCodeDocument,
        .agentPermissionCursorDocument
    ]

    static let allAccounts = SecureStorageAccount.allCases
}
