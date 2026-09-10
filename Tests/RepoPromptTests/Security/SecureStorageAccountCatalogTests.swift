import Foundation
@testable import RepoPromptApp
import XCTest

final class SecureStorageAccountCatalogTests: XCTestCase {
    func testCatalogFreezesExactAccountIdentifiers() {
        XCTAssertEqual(
            SecureStorageAccountCatalog.allAccounts.map(\.identifier),
            [
                "AnthropicAPI",
                "OpenAIAPI",
                "GeminiAPI",
                "OpenRouterAPI",
                "OllamaURL",
                "AzureAPI",
                "DeepSeekAPI",
                "CustomProviderAPI",
                "FireworksAPI",
                "GrokAPI",
                "GroqAPI",
                "ClaudeCodeAPI",
                "CodexCLIAPI",
                "OpenCodeCLIAPI",
                "CursorCLIAPI",
                "ZAIAPI",
                "ClaudeCompatibleBackend.kimi.apiKey",
                "ClaudeCompatibleBackend.custom.apiKey",
                "rp.agent.permissions.subagent.v1",
                "rp.agent.permissions.codex.v1",
                "rp.agent.permissions.claude.v1",
                "rp.agent.permissions.openCode.v1",
                "rp.agent.permissions.cursor.v1",
                "rp.agent.permissions.grokBuild.v1",
                "rp.agent.permissions.antigravity.v1"
            ]
        )
        XCTAssertEqual(Set(SecureStorageAccountCatalog.allAccounts.map(\.identifier)).count, 25)
    }

    func testIdentityMigrationV2CatalogRemainsFrozen() {
        XCTAssertEqual(
            SecureStorageAccountCatalog.identityMigrationV2Accounts.map(\.identifier),
            [
                "AnthropicAPI",
                "OpenAIAPI",
                "GeminiAPI",
                "OpenRouterAPI",
                "OllamaURL",
                "AzureAPI",
                "DeepSeekAPI",
                "CustomProviderAPI",
                "FireworksAPI",
                "GrokAPI",
                "GroqAPI",
                "ClaudeCodeAPI",
                "CodexCLIAPI",
                "OpenCodeCLIAPI",
                "CursorCLIAPI",
                "ZAIAPI",
                "ClaudeCompatibleBackend.kimi.apiKey",
                "ClaudeCompatibleBackend.custom.apiKey",
                "rp.agent.permissions.subagent.v1",
                "rp.agent.permissions.codex.v1",
                "rp.agent.permissions.claude.v1",
                "rp.agent.permissions.openCode.v1",
                "rp.agent.permissions.cursor.v1",
                "rp.agent.permissions.grokBuild.v1"
            ]
        )
    }

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

        XCTAssertEqual(mappings.map(\.0.secureStorageAccount), mappings.map { Optional($0.1) })
        XCTAssertEqual(mappings.map(\.1), SecureStorageAccountCatalog.providerAndCLIAccounts)

        // Grok Build reuses the xAI account; Oh My Pi authenticates entirely through its own
        // CLI, so it must not own or borrow a secure-storage account.
        XCTAssertEqual(AIProviderType.grokBuild.secureStorageAccount, .grokAPI)
        XCTAssertNil(AIProviderType.omp.secureStorageAccount)
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

    func testSecureStorageBackendBoundaryRemainsCentralized() throws {
        let root = try RepoRoot.url()
        let sourceRoot = root.appendingPathComponent("Sources/RepoPrompt", isDirectory: true)
        let allowedFiles: Set = [
            "Sources/RepoPrompt/Infrastructure/Security/EphemeralSecureKeyValueStore.swift",
            "Sources/RepoPrompt/Infrastructure/Security/KeychainService.swift",
            "Sources/RepoPrompt/Infrastructure/Security/SecureKeyService.swift",
            "Sources/RepoPrompt/Infrastructure/Security/SecureKeyValueStorageBackend.swift",
            "Sources/RepoPrompt/Infrastructure/Security/SecureStorageIdentityMigration.swift",
            "Sources/RepoPrompt/Infrastructure/Security/SecureStorageRepairService.swift"
        ]

        var filesUsingBackend: Set<String> = []
        let enumerator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            if text.contains("SecureKeyValueStorageBackend") {
                filesUsingBackend.insert(RepoRoot.relativePath(for: fileURL, relativeTo: root))
            }
        }

        XCTAssertEqual(filesUsingBackend, allowedFiles)
    }
}
