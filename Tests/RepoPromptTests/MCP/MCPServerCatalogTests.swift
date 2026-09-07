import Foundation
@testable import RepoPromptApp
import XCTest

final class MCPServerCatalogTests: XCTestCase {
    func testCurrentCodexShapePreservesEveryDefinitionAndPolicyField() throws {
        let source = #"""
        [mcp_servers.RepoPromptCE]
        command = "/redacted/repoprompt-mcp"
        args = ["--backend", "app"]
        env = { MODE = "redacted" }
        enabled = true
        required = true
        enabled_tools = ["read_file"]
        tools = ["read_file", "file_search"]
        supports_parallel_tool_calls = true
        tool_timeout_sec = 7200

        [mcp_servers.NewServer]
        url = "https://mcp.example.invalid/redacted"
        enabled = true
        required = false
        enabled_tools = ["lookup"]
        tools = ["lookup", "status"]
        supports_parallel_tool_calls = false
        tool_timeout_sec = 30
        """#

        let catalog = try MCPServerCatalog(migratingCodexTOML: source)

        XCTAssertEqual(
            catalog.servers,
            [
                .init(
                    name: "NewServer",
                    transport: .http(url: "https://mcp.example.invalid/redacted"),
                    policy: .init(
                        enabled: true,
                        required: false,
                        enabledTools: ["lookup"],
                        tools: ["lookup", "status"],
                        supportsParallelToolCalls: false,
                        toolTimeoutSeconds: 30
                    )
                ),
                .init(
                    name: "RepoPromptCE",
                    transport: .stdio(
                        command: "/redacted/repoprompt-mcp",
                        args: ["--backend", "app"],
                        environment: ["MODE": "redacted"]
                    ),
                    policy: .init(
                        enabled: true,
                        required: true,
                        enabledTools: ["read_file"],
                        tools: ["read_file", "file_search"],
                        supportsParallelToolCalls: true,
                        toolTimeoutSeconds: 7200
                    )
                )
            ]
        )
        XCTAssertEqual(
            catalog.renderCodexTOML(),
            #"""
            [mcp_servers.NewServer]
            url = "https://mcp.example.invalid/redacted"
            enabled = true
            required = false
            enabled_tools = ["lookup"]
            tools = ["lookup", "status"]
            supports_parallel_tool_calls = false
            tool_timeout_sec = 30

            [mcp_servers.RepoPromptCE]
            command = "/redacted/repoprompt-mcp"
            args = ["--backend", "app"]
            env = { MODE = "redacted" }
            enabled = true
            required = true
            enabled_tools = ["read_file"]
            tools = ["read_file", "file_search"]
            supports_parallel_tool_calls = true
            tool_timeout_sec = 7200
            """#
        )
        XCTAssertEqual(
            try catalog.renderClaudeJSON(),
            #"{"mcpServers":{"NewServer":{"type":"http","url":"https://mcp.example.invalid/redacted"},"RepoPromptCE":{"args":["--backend","app"],"command":"/redacted/repoprompt-mcp","env":{"MODE":"redacted"}}}}"#
        )
    }

    func testSelectionsDefaultNewServersOffAndCannotDisableRepoPromptCE() throws {
        let catalog = try MCPServerCatalog(
            servers: [
                .init(
                    name: "NewServer",
                    transport: .http(url: "https://mcp.example.invalid/redacted"),
                    policy: .init(enabled: true, required: true)
                ),
                .init(
                    name: "RepoPromptCE",
                    transport: .stdio(command: "/redacted/rp", args: [], environment: [:]),
                    policy: .init(enabled: false, required: false)
                )
            ]
        )

        XCTAssertEqual(catalog.servers.last?.policy.enabled, true)
        XCTAssertEqual(catalog.servers.last?.policy.required, true)
        XCTAssertEqual(catalog.selectedServers(enabledNames: []).map(\.name), ["RepoPromptCE"])
        XCTAssertEqual(
            catalog.selectedServers(enabledNames: ["NEWSERVER"]).map(\.name),
            ["NewServer", "RepoPromptCE"]
        )
    }

    func testMigrationRejectsAmbiguousOrIncompleteTransportDefinitions() {
        let malformedDefinitions = [
            """
            [mcp_servers.Both]
            command = "/redacted/bin"
            url = "https://mcp.example.invalid/redacted"
            """,
            """
            [mcp_servers.RemoteWithArgs]
            url = "https://mcp.example.invalid/redacted"
            args = ["--not-valid-for-http"]
            """,
            """
            [mcp_servers.MissingTransport]
            enabled = true
            """
        ]

        for source in malformedDefinitions {
            XCTAssertThrowsError(try MCPServerCatalog(migratingCodexTOML: source))
        }
    }

    func testMigrationRejectsDuplicateNormalizedNamesAndFields() {
        XCTAssertThrowsError(
            try MCPServerCatalog(
                migratingCodexTOML: """
                [mcp_servers.Example]
                command = "/redacted/one"
                [mcp_servers." example "]
                command = "/redacted/two"
                """
            )
        )
        XCTAssertThrowsError(
            try MCPServerCatalog(
                migratingCodexTOML: """
                [mcp_servers.Example]
                command = "/redacted/one"
                command = "/redacted/two"
                """
            )
        )
    }

    func testMigrationRejectsUnknownOrWronglyTypedPolicyFields() {
        let malformedPolicies = [
            "unsupported = true",
            "enabled = \"true\"",
            "enabled_tools = [\"read_file\", 42]",
            "tool_timeout_sec = -1"
        ]

        for policy in malformedPolicies {
            XCTAssertThrowsError(
                try MCPServerCatalog(
                    migratingCodexTOML: """
                    [mcp_servers.Example]
                    command = "/redacted/bin"
                    \(policy)
                    """
                )
            )
        }
    }
}
