import Foundation
@testable import RepoPromptApp
import XCTest

final class MCPServerCatalogAuthorityTests: XCTestCase {
    func testBothDirectProvidersProjectTheSameArbitrarySelectedMembership() throws {
        let catalog = try MCPServerCatalog(servers: [
            .init(name: "ArbitraryAdditional", transport: .http(url: "https://extra.example.invalid/mcp")),
            .init(name: "DisabledServer", transport: .http(url: "https://off.example.invalid/mcp")),
            .init(
                name: "RepoPromptCE",
                transport: .stdio(command: "/redacted/rp", args: ["--backend", "app"], environment: [:])
            )
        ])
        let authority = MCPServerCatalogAuthority(
            catalogProvider: { catalog },
            enabledNamesProvider: { _ in [" arbitraryadditional "] }
        )

        let codex = try authority.catalog(for: .codex, scope: .directSelected)
        let claude = try authority.catalog(for: .claude, scope: .directSelected)

        XCTAssertEqual(codex.servers.map(\.name), ["ArbitraryAdditional", "RepoPromptCE"])
        XCTAssertEqual(claude.servers.map(\.name), codex.servers.map(\.name))
        XCTAssertEqual(
            try claude.renderClaudeJSON(),
            #"{"mcpServers":{"ArbitraryAdditional":{"type":"http","url":"https://extra.example.invalid/mcp"},"RepoPromptCE":{"args":["--backend","app"],"command":"/redacted/rp"}}}"#
        )
        XCTAssertTrue(codex.renderCodexTOML().contains("[mcp_servers.ArbitraryAdditional]"))
        XCTAssertFalse(codex.renderCodexTOML().contains("DisabledServer"))
    }

    func testRestrictedScopeAlwaysProjectsOnlyRepoPrompt() throws {
        let catalog = try MCPServerCatalog(servers: [
            .init(name: "SelectedThirdParty", transport: .http(url: "https://selected.example.invalid/mcp")),
            .init(
                name: "RepoPromptCE",
                transport: .stdio(command: "/redacted/rp", args: [], environment: [:])
            )
        ])
        let authority = MCPServerCatalogAuthority(
            catalogProvider: { catalog },
            enabledNamesProvider: { _ in ["SelectedThirdParty"] }
        )

        XCTAssertEqual(
            try authority.catalog(for: .codex, scope: .repoPromptOnly).servers.map(\.name),
            ["RepoPromptCE"]
        )
        XCTAssertEqual(
            try authority.catalog(for: .claude, scope: .repoPromptOnly).servers.map(\.name),
            ["RepoPromptCE"]
        )
    }

    func testDirectCodexLaunchOverridesUseCompleteAndSelectedProjection() throws {
        let catalog = try MCPServerCatalog(servers: [
            .init(name: "ArbitraryAdditional", transport: .http(url: "https://extra.example.invalid/mcp")),
            .init(name: "DisabledServer", transport: .http(url: "https://off.example.invalid/mcp")),
            .init(
                name: "RepoPromptCE",
                transport: .stdio(command: "/redacted/rp", args: [], environment: [:])
            )
        ])
        let authority = MCPServerCatalogAuthority(
            catalogProvider: { catalog },
            enabledNamesProvider: { _ in ["ArbitraryAdditional"] }
        )

        let overrides = CodexNativeSessionController.defaultAppServerConfigOverrides(
            mcpCatalogAuthority: authority
        )

        XCTAssertEqual(overrides["mcp_servers.arbitraryadditional.enabled"] as? Bool, true)
        XCTAssertEqual(overrides["mcp_servers.disabledserver.enabled"] as? Bool, false)
        XCTAssertEqual(overrides["mcp_servers.repopromptce.enabled"] as? Bool, true)
    }
}
