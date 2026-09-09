import Foundation
@testable import RepoPromptApp
import XCTest

/// Devin's isolated `XDG_CONFIG_HOME` overlay is the only delivery path its `mcp_*`
/// gateway tools can see (session-scoped ACP `mcpServers` connect but are never
/// registered), so the merge behavior it depends on is covered directly.
final class DevinIntegrationConfigurationTests: XCTestCase {
    func testOverlayOverwritesStaleEntryPreservesNativeConfigurationAndLinksSiblings() throws {
        let sourceRoot = try makeTestDirectory(name: "DevinOverlaySource")
        let sourceDevin = sourceRoot.appendingPathComponent("devin", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDevin, withIntermediateDirectories: true)
        let auth = sourceDevin.appendingPathComponent("auth.json")
        try Data(#"{"synthetic":"not-a-credential"}"#.utf8).write(to: auth)

        let nativeStdio: [String: Any] = ["transport": "stdio", "command": "/bin/echo", "args": ["native"]]
        let explicitStdio: [String: Any] = [
            "transport": "stdio",
            "command": "/bin/echo",
            "env": ["XDG_CONFIG_HOME": "/explicit/native/root"]
        ]
        let remote: [String: Any] = ["transport": "http", "url": "https://example.invalid"]
        // A stale user-level RepoPrompt entry pointing at a non-CE bundle must be replaced,
        // not merged: it collides on the same server key.
        let staleRepoPrompt: [String: Any] = [
            "transport": "stdio",
            "command": "/Applications/RepoPrompt.app/Contents/MacOS/repoprompt-mcp"
        ]
        let sourceJSON = try JSONSerialization.data(
            withJSONObject: [
                "custom": "retained",
                "mcpServers": [
                    "Native": nativeStdio,
                    "Explicit": explicitStdio,
                    "Remote": remote,
                    RepoPromptMCPServerConfiguration.defaultServerName: staleRepoPrompt
                ]
            ],
            options: [.sortedKeys]
        )
        let sourceConfigURL = sourceDevin.appendingPathComponent("mcp_config.json")
        try sourceJSON.write(to: sourceConfigURL)

        let prepared = try DevinIntegrationConfiguration.prepare(
            workingDirectory: sourceRoot.path,
            repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(
                command: "/bin/echo",
                args: ["--backend", "app"],
                env: [.init(name: "RP_MARKER", value: "run-scoped")]
            ),
            sourceEnvironment: ["XDG_CONFIG_HOME": sourceRoot.path]
        )
        defer { DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact) }

        let overlayRoot = try URL(fileURLWithPath: XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"]))
        XCTAssertEqual(prepared.environment.count, 1, "the overlay contributes exactly one launch override")
        XCTAssertEqual(prepared.cleanupArtifact.providerID, .devin)
        XCTAssertEqual(prepared.cleanupArtifact.kind, DevinIntegrationConfiguration.cleanupArtifactKind)

        let overlayConfigURL = overlayRoot.appendingPathComponent("devin/mcp_config.json")
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: overlayConfigURL)) as? [String: Any]
        )
        XCTAssertEqual(root["custom"] as? String, "retained", "unrelated root keys survive the merge")
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: [String: Any]])

        let injected = try XCTUnwrap(servers[RepoPromptMCPServerConfiguration.defaultServerName])
        XCTAssertEqual(injected["transport"] as? String, "stdio")
        XCTAssertEqual(injected["command"] as? String, "/bin/echo")
        XCTAssertEqual(injected["args"] as? [String], ["--backend", "app"])
        XCTAssertEqual(
            injected["env"] as? [String: String],
            ["RP_MARKER": "run-scoped", "XDG_CONFIG_HOME": sourceRoot.path]
        )

        // Known stdio children keep reading the user's real configuration root.
        XCTAssertEqual(
            servers["Native"]?["env"] as? [String: String],
            ["XDG_CONFIG_HOME": sourceRoot.path]
        )
        // An explicit per-server override is never rewritten.
        XCTAssertEqual(
            servers["Explicit"]?["env"] as? [String: String],
            ["XDG_CONFIG_HOME": "/explicit/native/root"]
        )
        // Non-stdio entries pass through untouched.
        XCTAssertEqual(servers["Remote"] as NSDictionary?, remote as NSDictionary)

        // The user's own configuration file is never mutated.
        XCTAssertEqual(try Data(contentsOf: sourceConfigURL), sourceJSON)

        // Siblings are symlinked, so native credential refreshes stay visible.
        let linkedAuth = overlayRoot.appendingPathComponent("devin/auth.json")
        XCTAssertEqual(linkedAuth.resolvingSymlinksInPath(), auth.resolvingSymlinksInPath())
        try Data(#"{"synthetic":"refreshed"}"#.utf8).write(to: auth)
        XCTAssertEqual(try Data(contentsOf: linkedAuth), Data(#"{"synthetic":"refreshed"}"#.utf8))
    }

    func testSourceRootFallsBackToHomeConfigWhenXDGIsUnsetOrBlank() throws {
        let home = try makeTestDirectory(name: "DevinOverlayHome")
        let sourceDevin = home.appendingPathComponent(".config/devin", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDevin, withIntermediateDirectories: true)
        try Data(#"{"homeMarker":true,"mcpServers":{}}"#.utf8)
            .write(to: sourceDevin.appendingPathComponent("mcp_config.json"))

        for xdg in [nil, "  "] as [String?] {
            var environment = ["HOME": home.path]
            environment["XDG_CONFIG_HOME"] = xdg

            let prepared = try DevinIntegrationConfiguration.prepare(
                workingDirectory: home.path,
                repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(command: "/bin/echo"),
                sourceEnvironment: environment
            )
            defer { DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact) }

            let overlayRoot = try URL(fileURLWithPath: XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"]))
            let root = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: overlayRoot.appendingPathComponent("devin/mcp_config.json"))
                ) as? [String: Any]
            )
            XCTAssertEqual(root["homeMarker"] as? Bool, true, "expected $HOME/.config fallback for XDG=\(xdg ?? "nil")")
        }
    }

    func testPreparationRejectsAMissingRepoPromptCommand() throws {
        let sourceRoot = try makeTestDirectory(name: "DevinOverlayInvalidCommand")
        XCTAssertThrowsError(
            try DevinIntegrationConfiguration.prepare(
                workingDirectory: sourceRoot.path,
                repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(
                    command: sourceRoot.appendingPathComponent("missing-repoprompt-mcp").path
                ),
                sourceEnvironment: ["XDG_CONFIG_HOME": sourceRoot.path]
            )
        )
    }

    func testCleanupRemovesTheOverlayAndIgnoresForeignArtifacts() throws {
        let sourceRoot = try makeTestDirectory(name: "DevinOverlayCleanup")
        let prepared = try DevinIntegrationConfiguration.prepare(
            workingDirectory: sourceRoot.path,
            repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(command: "/bin/echo"),
            sourceEnvironment: ["XDG_CONFIG_HOME": sourceRoot.path]
        )
        let overlayRoot = try XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"])

        DevinIntegrationConfiguration.cleanup(
            artifact: ACPLaunchCleanupArtifact(providerID: .cursor, id: prepared.cleanupArtifact.id, kind: DevinIntegrationConfiguration.cleanupArtifactKind)
        )
        DevinIntegrationConfiguration.cleanup(
            artifact: ACPLaunchCleanupArtifact(providerID: .devin, id: prepared.cleanupArtifact.id, kind: "someOtherKind")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: overlayRoot))

        DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact)
        XCTAssertFalse(FileManager.default.fileExists(atPath: overlayRoot))
    }
}
