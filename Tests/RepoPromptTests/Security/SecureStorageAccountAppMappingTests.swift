import Foundation
@testable import RepoPromptApp
@testable import RepoPromptSecureStorage
import XCTest

final class SecureStorageAccountAppMappingTests: XCTestCase {
    func testProviderMappingsUseCatalogAccounts() {
        let mappings: [(AIProviderType, SecureStorageAccount)] = [
            (.anthropic, .anthropicAPI),
            (.openAI, .openAIAPI),
            (.gemini, .geminiAPI),
            (.openRouter, .openRouterAPI),
            (.ollama, .ollamaURL),
            (.azure, .azureAPI),
            (.deepseek, .deepSeekAPI),
            (.customProvider, .customProviderAPI),
            (.fireworks, .fireworksAPI),
            (.grok, .grokAPI),
            (.groq, .groqAPI),
            (.claudeCode, .claudeCodeAPI),
            (.codex, .codexCLIAPI),
            (.openCode, .openCodeCLIAPI),
            (.cursor, .cursorCLIAPI),
            (.zAI, .zAIAPI)
        ]

        XCTAssertEqual(mappings.map(\.0.secureStorageAccount), mappings.map(\.1))
        XCTAssertEqual(mappings.map(\.1), SecureStorageAccountCatalog.providerAndCLIAccounts)
    }

    func testClaudeCompatibleMappingsUseCatalogAccounts() {
        XCTAssertEqual(
            ClaudeCodeCompatibleBackendID.allCases.map(\.secureStorageAccount),
            SecureStorageAccountCatalog.claudeCompatibleAccounts
        )
    }

    func testAgentPermissionMappingsUseCatalogAccounts() {
        XCTAssertEqual(
            AgentPermissionSecureDomain.allCases.map(\.secureStorageAccount),
            SecureStorageAccountCatalog.agentPermissionAccounts
        )
    }
}
