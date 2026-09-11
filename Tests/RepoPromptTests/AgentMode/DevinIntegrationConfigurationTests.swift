import Foundation
@testable import RepoPromptApp
import XCTest

final class DevinIntegrationConfigurationTests: XCTestCase {
    func testOverlayStdioChildrenReadNativeConfigurationUnlessExplicitlyOverridden() throws {
        let source = try makeTestDirectory(name: "DevinChildSource")
        let explicit = try makeTestDirectory(name: "DevinChildExplicit")
        let devin = source.appendingPathComponent("devin")
        try FileManager.default.createDirectory(at: devin, withIntermediateDirectories: true)
        try Data("native-child-config".utf8).write(to: source.appendingPathComponent("child-config"))
        try Data("explicit-child-config".utf8).write(to: explicit.appendingPathComponent("child-config"))
        let syntheticAuth = Data("synthetic-auth-not-a-credential".utf8)
        let auth = devin.appendingPathComponent("auth.json")
        try syntheticAuth.write(to: auth)
        let command = ["-c", "cat \"$XDG_CONFIG_HOME/child-config\"; printf '|%s' \"$CHILD_MARKER\""]
        let native: [String: Any] = ["transport": "stdio", "command": "/bin/sh", "args": command, "env": ["CHILD_MARKER": "preserved"]]
        let overridden: [String: Any] = [
            "transport": "stdio",
            "command": "/bin/sh",
            "args": command,
            "env": ["XDG_CONFIG_HOME": explicit.path, "CHILD_MARKER": "explicit"]
        ]
        let emptyOverride: [String: Any] = ["transport": "stdio", "command": "/bin/echo", "env": ["XDG_CONFIG_HOME": ""]]
        let remote: [String: Any] = ["transport": "http", "url": "https://example.invalid", "env": ["KEEP": "remote"]]
        let unknown: [String: Any] = ["transport": "future", "command": "/bin/echo", "custom": true]
        let original = try JSONSerialization.data(withJSONObject: ["custom": "retained", "mcpServers": [
            "Native": native, "Explicit": overridden, "Empty": emptyOverride, "Remote": remote, "Unknown": unknown
        ]], options: [.sortedKeys])
        let originalURL = devin.appendingPathComponent("mcp_config.json")
        try original.write(to: originalURL)
        XCTAssertEqual(try runChild(native, environment: ["XDG_CONFIG_HOME": source.path]), "native-child-config|preserved")

        let prepared = try DevinIntegrationConfiguration.prepare(
            workingDirectory: source.path,
            repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(
                command: "/bin/sh", args: command,
                env: [.init(name: "XDG_CONFIG_HOME", value: explicit.path), .init(name: "CHILD_MARKER", value: "run-scoped")]
            ),
            sourceEnvironment: ["XDG_CONFIG_HOME": source.path]
        )
        defer { DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact) }
        let isolated = try URL(fileURLWithPath: XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"]))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: isolated.appendingPathComponent("devin/mcp_config.json"))) as? [String: Any])
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(try runChild(XCTUnwrap(servers["Native"]), environment: prepared.environment), "native-child-config|preserved")
        XCTAssertEqual(try runChild(XCTUnwrap(servers["Explicit"]), environment: prepared.environment), "explicit-child-config|explicit")
        XCTAssertEqual(try runChild(XCTUnwrap(servers[RepoPromptMCPServerConfiguration.defaultServerName]), environment: prepared.environment), "explicit-child-config|run-scoped")
        XCTAssertEqual(servers["Empty"]?["env"] as? [String: String], ["XDG_CONFIG_HOME": ""])
        XCTAssertEqual(servers["Remote"] as NSDictionary?, remote as NSDictionary)
        XCTAssertEqual(servers["Unknown"] as NSDictionary?, unknown as NSDictionary)
        XCTAssertEqual(root["custom"] as? String, "retained")
        XCTAssertEqual(try Data(contentsOf: originalURL), original)
        let linkedAuth = isolated.appendingPathComponent("devin/auth.json")
        XCTAssertEqual(linkedAuth.resolvingSymlinksInPath(), auth.resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: linkedAuth), syntheticAuth)
        // Native-owned auth writes remain linked, not copied into ephemeral configuration.
        try Data("synthetic-native-refresh".utf8).write(to: auth)
        XCTAssertEqual(try Data(contentsOf: linkedAuth), Data("synthetic-native-refresh".utf8))
        DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact)
        XCTAssertEqual(try Data(contentsOf: auth), Data("synthetic-native-refresh".utf8))
    }

    func testOverlayRespectsChildHOMEOverrideUnlessSourceXDGIsSet() throws {
        let parentHome = try makeTestDirectory(name: "DevinParentHome")
        let childHome = try makeTestDirectory(name: "DevinChildHome")
        let parentRoot = parentHome.appendingPathComponent(".config", isDirectory: true)
        let childRoot = childHome.appendingPathComponent(".config", isDirectory: true)
        let sourceDevin = parentRoot.appendingPathComponent("devin", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDevin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: childRoot, withIntermediateDirectories: true)
        try Data("parent-config".utf8).write(to: parentRoot.appendingPathComponent("child-config"))
        try Data("isolated-child-config".utf8).write(to: childRoot.appendingPathComponent("child-config"))
        let server: [String: Any] = [
            "transport": "stdio", "command": "/bin/sh",
            "args": ["-c", "config=\"${XDG_CONFIG_HOME:-$HOME/.config}\"; /bin/cat \"$config/child-config\""],
            "env": ["HOME": childHome.path]
        ]
        let original = try JSONSerialization.data(withJSONObject: ["mcpServers": ["IsolatedChild": server]])
        let sourceURL = sourceDevin.appendingPathComponent("mcp_config.json")
        try original.write(to: sourceURL)

        for sourceXDG in [nil, parentRoot.path] as [String?] {
            var sourceEnvironment = ["HOME": parentHome.path]
            sourceEnvironment["XDG_CONFIG_HOME"] = sourceXDG
            let expected = sourceXDG == nil ? "isolated-child-config" : "parent-config"
            let nativeOutput = try runChild(server, environment: sourceEnvironment)
            XCTAssertEqual(nativeOutput, expected)

            let prepared = try DevinIntegrationConfiguration.prepare(
                workingDirectory: parentHome.path,
                repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(command: "/bin/echo"),
                sourceEnvironment: sourceEnvironment
            )
            defer { DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact) }
            let isolated = try URL(fileURLWithPath: XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"]))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: isolated.appendingPathComponent("devin/mcp_config.json"))) as? [String: Any])
            let servers = try XCTUnwrap(root["mcpServers"] as? [String: [String: Any]])
            let child = try XCTUnwrap(servers["IsolatedChild"])
            let launchEnvironment = sourceEnvironment.merging(prepared.environment) { _, overlay in overlay }
            XCTAssertEqual(try runChild(child, environment: launchEnvironment), nativeOutput)
            XCTAssertEqual((child["env"] as? [String: String])?["HOME"], childHome.path)
            XCTAssertEqual(try Data(contentsOf: sourceURL), original)
        }
    }

    func testSourceRootUsesEffectiveHOMEWhenXDGIsUnsetOrBlank() throws {
        let home = try makeTestDirectory(name: "DevinEffectiveHome")
        let source = home.appendingPathComponent(".config/devin", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"effectiveHomeMarker":true,"mcpServers":{}}"#.utf8).write(to: source.appendingPathComponent("mcp_config.json"))
        for xdg in [nil, "  "] as [String?] {
            var environment = ["HOME": home.path]
            environment["XDG_CONFIG_HOME"] = xdg
            let prepared = try DevinIntegrationConfiguration.prepare(
                workingDirectory: home.path,
                repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(command: "/bin/echo"),
                sourceEnvironment: environment
            )
            defer { DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact) }
            let root = try URL(fileURLWithPath: XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"]))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("devin/mcp_config.json"))) as? [String: Any])
            XCTAssertEqual(object["effectiveHomeMarker"] as? Bool, true)
        }
    }

    private func runChild(_ server: [String: Any], environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = try URL(fileURLWithPath: XCTUnwrap(server["command"] as? String))
        process.arguments = server["args"] as? [String] ?? []
        process.environment = environment.merging(server["env"] as? [String: String] ?? [:]) { _, explicit in explicit }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self)
    }
}
