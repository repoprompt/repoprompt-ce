import Foundation
@testable import RepoPromptApp
import XCTest

final class OpenCodeIntegrationConfigurationTests: XCTestCase {
    func testEphemeralOverlayDisablesInheritedNonRepoPromptMCPNames() throws {
        let home = try makeTemporaryDirectory()
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

    func testInheritedNamesIncludeProjectConfigPaths() throws {
        let project = try makeTemporaryDirectory()
        try writeJSON(
            [
                "mcp": [
                    "ProjectMCP": [
                        "type": "local",
                        "command": ["/usr/bin/true"]
                    ]
                ]
            ],
            to: project.appendingPathComponent("opencode.json")
        )

        let names = OpenCodeIntegrationConfiguration.discoverInheritedMCPServerNames(
            workingDirectory: project.path,
            environment: [
                "HOME": project.appendingPathComponent("no-global-home").path
            ]
        )
        XCTAssertEqual(names, ["ProjectMCP"])
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

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
