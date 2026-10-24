import Foundation
@testable import RepoPromptSecureStorage
import RepoPromptTestSupport
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
                "JevRouterAPIKey",
                "OpenAIDecisionsRouterAPIKey",
                "rp.agent.permissions.subagent.v1",
                "rp.agent.permissions.codex.v1",
                "rp.agent.permissions.claude.v1",
                "rp.agent.permissions.openCode.v1",
                "rp.agent.permissions.cursor.v1",
                "rp.agent.permissions.grokBuild.v1",
                "rp.agent.permissions.antigravity.v1",
                "rp.agent.permissions.devin.v1"
            ]
        )
        XCTAssertEqual(Set(SecureStorageAccountCatalog.allAccounts.map(\.identifier)).count, 28)
    }

    func testDecisionsAccountIsIsolatedAndIncludedInRepairInventory() {
        let account = SecureStorageAccount.openAIDecisionsRouterAPIKey
        XCTAssertEqual(account.identifier, "OpenAIDecisionsRouterAPIKey")
        XCTAssertEqual(SecureStorageAccountCatalog.allAccounts.count(where: { $0 == account }), 1)
        XCTAssertFalse(SecureStorageAccountCatalog.providerAndCLIAccounts.contains(account))
        XCTAssertFalse(SecureStorageAccountCatalog.claudeCompatibleAccounts.contains(account))
        XCTAssertFalse(SecureStorageAccountCatalog.agentPermissionAccounts.contains(account))
        XCTAssertFalse(SecureStorageAccountCatalog.identityMigrationV2Accounts.contains(account))
        XCTAssertEqual(SecureStorageAccountCatalog.identityMigrationV2Accounts.count, 24)
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

    func testSecureStorageBackendBoundaryRemainsCentralized() throws {
        let root = try RepoRoot.url()
        let sourceRoot = root.appendingPathComponent("Sources/RepoPromptSecureStorage", isDirectory: true)
        let allowedFiles: Set = [
            "Sources/RepoPromptSecureStorage/EphemeralSecureKeyValueStore.swift",
            "Sources/RepoPromptSecureStorage/KeychainService.swift",
            "Sources/RepoPromptSecureStorage/SecureKeyService.swift",
            "Sources/RepoPromptSecureStorage/SecureKeyValueStorageBackend.swift",
            "Sources/RepoPromptSecureStorage/SecureStorageIdentityMigration.swift",
            "Sources/RepoPromptSecureStorage/SecureStorageRepairService.swift"
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
