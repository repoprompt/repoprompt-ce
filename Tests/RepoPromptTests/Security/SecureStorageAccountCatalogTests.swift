import Foundation
@testable import RepoPrompt
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
                "rp.agent.permissions.cursor.v1"
            ]
        )
        XCTAssertEqual(Set(SecureStorageAccountCatalog.allAccounts.map(\.identifier)).count, 23)
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

    func testSecureStorageBackendBoundaryRemainsCentralized() throws {
        let root = try RepoRoot.url()
        let sourceRoot = root.appendingPathComponent("Sources/RepoPrompt", isDirectory: true)
        let allowedFiles: Set = [
            "Sources/RepoPrompt/Infrastructure/Security/EphemeralSecureKeyValueStore.swift",
            "Sources/RepoPrompt/Infrastructure/Security/KeychainService.swift",
            "Sources/RepoPrompt/Infrastructure/Security/SecureKeyService.swift",
            "Sources/RepoPrompt/Infrastructure/Security/SecureKeyValueStorageBackend.swift",
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
