import Foundation
@testable import RepoPromptApp
import XCTest

final class OpenCodeIntegrationConfigurationTests: XCTestCase {
    func testEphemeralOverlayDisablesInheritedNonRepoPromptMCPNames() throws {
        let home = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let configDir = home.appendingPathComponent(".config/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try writeJSON(
            [
                "mcp": [
                    "AITrader": [
                        "type": "local",
                        "command": ["/usr/bin/false"]
                    ],
                    "Hang": [
                        "type": "local",
                        "command": ["/bin/sleep", "120"]
                    ],
                    "RepoPromptCE": [
                        "type": "local",
                        "command": ["/usr/bin/true"]
                    ]
                ]
            ],
            to: configDir.appendingPathComponent("opencode.json")
        )

        let dict = OpenCodeIntegrationConfiguration.ephemeralACPConfigDict(
            includeRepoPromptMCPServer: true,
            repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(
                command: "/tmp/repoprompt_ce_cli",
                args: ["--backend", "app"]
            ),
            workingDirectory: home.path,
            environment: ["HOME": home.path]
        )

        let mcp = try XCTUnwrap(dict["mcp"] as? [String: Any])
        XCTAssertEqual(Set(mcp.keys), ["AITrader", "Hang", "RepoPromptCE"])

        let disabledAITrader = try XCTUnwrap(mcp["AITrader"] as? [String: Any])
        XCTAssertEqual(disabledAITrader["enabled"] as? Bool, false)
        XCTAssertEqual((disabledAITrader["command"] as? [String])?.first, "/usr/bin/false")

        let disabledHang = try XCTUnwrap(mcp["Hang"] as? [String: Any])
        XCTAssertEqual(disabledHang["enabled"] as? Bool, false)

        let repoPrompt = try XCTUnwrap(mcp["RepoPromptCE"] as? [String: Any])
        XCTAssertNil(repoPrompt["enabled"] as? Bool)
        XCTAssertEqual(
            repoPrompt["command"] as? [String],
            ["/tmp/repoprompt_ce_cli", "--backend", "app"]
        )
    }

    func testEphemeralOverlayCanDisableRepoPromptMCPWhileNeutralizingInheritedNames() {
        let dict = OpenCodeIntegrationConfiguration.ephemeralACPConfigDict(
            includeRepoPromptMCPServer: false,
            inheritedMCPServerNamesOverride: ["AITrader", "RepoPromptCE", "Other"]
        )
        let mcp = dict["mcp"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(mcp.keys), ["AITrader", "Other", "RepoPromptCE"])
        XCTAssertEqual((mcp["AITrader"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertEqual((mcp["Other"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertEqual((mcp["RepoPromptCE"] as? [String: Any])?["enabled"] as? Bool, false)
    }

    func testInheritedNamesIncludeEveryGlobalConfigFilenameAndJSONC() throws {
        let root = try makeTemporaryDirectory()
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(
            at: worktree.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let xdgConfigHome = root.appendingPathComponent("xdg", isDirectory: true)
        let configDirectory = xdgConfigHome.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        try writeMCPConfig(named: "GlobalConfig", to: configDirectory.appendingPathComponent("config.json"))
        try writeMCPConfig(named: "GlobalJSON", to: configDirectory.appendingPathComponent("opencode.json"))
        try writeText(
            """
            {
              // OpenCode accepts comments and trailing commas in JSONC.
              "mcp": {
                "GlobalJSONC": {
                  "type": "remote",
                  "url": "https://example.com/mcp//endpoint",
                },
              },
            }
            """,
            to: configDirectory.appendingPathComponent("opencode.jsonc")
        )

        let names = OpenCodeIntegrationConfiguration.discoverInheritedMCPServerNames(
            workingDirectory: worktree.path,
            environment: [
                "HOME": root.appendingPathComponent("no-global-home").path,
                "XDG_CONFIG_HOME": xdgConfigHome.path
            ]
        )
        XCTAssertEqual(names, ["GlobalConfig", "GlobalJSON", "GlobalJSONC"])
    }

    func testInheritedNamesIncludeAncestorAndDotOpenCodeConfigsWithinWorktreeBoundary() throws {
        let container = try makeTemporaryDirectory()
        try writeMCPConfig(
            named: "OutsideWorktree",
            to: container.appendingPathComponent("opencode.json")
        )

        let project = container.appendingPathComponent("repo", isDirectory: true)
        let nested = project.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeText(
            """
            {
              /* Ancestor project JSONC is loaded before more specific files. */
              "mcp": {
                "AncestorProject": {
                  "type": "local",
                  "command": ["/usr/bin/true"],
                },
              },
            }
            """,
            to: project.appendingPathComponent("opencode.jsonc")
        )
        let dotOpenCode = project.appendingPathComponent(".opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: dotOpenCode, withIntermediateDirectories: true)
        try writeMCPConfig(
            named: "DotOpenCode",
            to: dotOpenCode.appendingPathComponent("opencode.json")
        )
        let sourceDirectory = project.appendingPathComponent("Sources", isDirectory: true)
        try writeMCPConfig(
            named: "CurrentProject",
            to: sourceDirectory.appendingPathComponent("opencode.json")
        )

        let names = OpenCodeIntegrationConfiguration.discoverInheritedMCPServerNames(
            workingDirectory: nested.path,
            environment: [
                "HOME": container.appendingPathComponent("no-global-home").path
            ]
        )
        XCTAssertEqual(names, ["AncestorProject", "CurrentProject", "DotOpenCode"])
        XCTAssertFalse(names.contains("OutsideWorktree"))
    }

    func testInheritedNamesIncludeEnvironmentDirectedConfigSources() throws {
        let project = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let customFileDirectory = project.appendingPathComponent("custom", isDirectory: true)
        try FileManager.default.createDirectory(at: customFileDirectory, withIntermediateDirectories: true)
        try writeText(
            """
            {
              "mcp": {
                "CustomFile": {
                  "type": "local",
                  "command": ["/usr/bin/true"],
                },
              },
            }
            """,
            to: customFileDirectory.appendingPathComponent("settings.jsonc")
        )

        let customDirectory = project.appendingPathComponent("custom-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        try writeMCPConfig(
            named: "CustomDirectoryJSON",
            to: customDirectory.appendingPathComponent("opencode.json")
        )
        try writeText(
            """
            {
              // OPENCODE_CONFIG_DIR supports JSONC too.
              "mcp": {
                "CustomDirectoryJSONC": {
                  "type": "local",
                  "command": ["/usr/bin/true"],
                },
              },
            }
            """,
            to: customDirectory.appendingPathComponent("opencode.jsonc")
        )

        let names = OpenCodeIntegrationConfiguration.discoverInheritedMCPServerNames(
            workingDirectory: project.path,
            environment: [
                "HOME": project.appendingPathComponent("no-global-home").path,
                "OPENCODE_CONFIG": "custom/settings.jsonc",
                "OPENCODE_CONFIG_DIR": "custom-dir"
            ]
        )
        XCTAssertEqual(names, ["CustomDirectoryJSON", "CustomDirectoryJSONC", "CustomFile"])
    }

    func testProjectConfigDiscoveryHonorsOpenCodeDisableFlag() throws {
        let project = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeMCPConfig(
            named: "ProjectMCP",
            to: project.appendingPathComponent("opencode.json")
        )

        let names = OpenCodeIntegrationConfiguration.discoverInheritedMCPServerNames(
            workingDirectory: project.path,
            environment: [
                "HOME": project.appendingPathComponent("no-global-home").path,
                "OPENCODE_DISABLE_PROJECT_CONFIG": "1"
            ]
        )
        XCTAssertEqual(names, [])
    }

    func testParentInlineConfigContentIsNotScannedBecauseLaunchOverlayReplacesIt() throws {
        let project = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )

        let names = OpenCodeIntegrationConfiguration.discoverInheritedMCPServerNames(
            workingDirectory: project.path,
            environment: [
                "HOME": project.appendingPathComponent("no-global-home").path,
                "OPENCODE_CONFIG_CONTENT": "{\"mcp\":{\"ParentInline\":{\"enabled\":true}}}"
            ]
        )
        XCTAssertEqual(names, [])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeIntegrationConfigurationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func writeMCPConfig(named name: String, to url: URL) throws {
        try writeJSON(
            [
                "mcp": [
                    name: [
                        "type": "local",
                        "command": ["/usr/bin/true"]
                    ]
                ]
            ],
            to: url
        )
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func writeText(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
