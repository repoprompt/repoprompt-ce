import Foundation
@testable import RepoPrompt
import XCTest

final class CodexComputerUseStatusTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testStatusReadinessAllowsUnsupportedLiveAvailabilityButBlocksUnavailable() {
        let ready = CodexComputerUseStatus(
            optInEnabled: true,
            prerequisites: .init(
                pluginConfiguration: .configured(serverName: "computer-use"),
                liveAvailability: .unsupported(reason: "No catalog"),
                screenRecording: .granted,
                accessibility: .granted
            )
        )
        XCTAssertTrue(ready.isReady)
        XCTAssertEqual(ready.missingRequirements, [])

        let unavailable = CodexComputerUseStatus(
            optInEnabled: true,
            prerequisites: .init(
                pluginConfiguration: .configured(serverName: "computer-use"),
                liveAvailability: .unavailable(reason: "Tool catalog missing computer-use"),
                screenRecording: .granted,
                accessibility: .granted
            )
        )
        XCTAssertFalse(unavailable.isReady)
        XCTAssertEqual(unavailable.missingRequirements, [.liveAvailability])
    }

    func testMissingPrerequisitesAreReportedSeparately() {
        let status = CodexComputerUseStatus(
            optInEnabled: true,
            prerequisites: .init(
                pluginConfiguration: .serverEntryMissing(path: "/tmp/config.toml"),
                liveAvailability: .unknown(reason: "No probe yet"),
                screenRecording: .notGranted,
                accessibility: .unknown(reason: "AX unavailable")
            )
        )

        XCTAssertFalse(status.isReady)
        XCTAssertEqual(status.missingRequirements, [.plugin, .screenRecording, .accessibility])
        XCTAssertTrue(status.primaryUnavailableMessage.contains("configure"))
        XCTAssertTrue(status.primaryUnavailableMessage.contains("Screen Recording"))
        XCTAssertTrue(status.primaryUnavailableMessage.contains("Accessibility"))
    }

    func testAppManagedPluginStatusSatisfiesConfigurationGate() {
        let status = CodexComputerUseStatus(
            optInEnabled: true,
            prerequisites: .init(
                pluginConfiguration: .appManagedPluginInstalled(
                    path: "/Users/example/.codex/computer-use/config.json",
                    version: "1.0.799"
                ),
                liveAvailability: .unsupported(reason: "No live catalog"),
                screenRecording: .notGranted,
                accessibility: .notGranted
            )
        )

        XCTAssertTrue(status.pluginConfiguration.isConfigured)
        XCTAssertTrue(status.usesCodexManagedMacPermissions)
        XCTAssertTrue(status.screenRecordingSatisfied)
        XCTAssertTrue(status.accessibilitySatisfied)
        XCTAssertTrue(status.isReady)
        XCTAssertTrue(status.pluginConfiguration.detail.contains("Codex Computer Use is installed"))
    }

    func testConfigPluginStanzaDeclaresComputerUsePlugin() {
        XCTAssertTrue(CodexComputerUseStatusService.test_configDeclaresComputerUsePlugin("""
        [plugins."computer-use@openai-bundled"]
        """))
        XCTAssertTrue(CodexComputerUseStatusService.test_configDeclaresComputerUsePlugin("""
        [plugins.computer-use@openai-bundled]
        """))
        XCTAssertFalse(CodexComputerUseStatusService.test_configDeclaresComputerUsePlugin("""
        [plugins."browser@openai-bundled"]
        """))
    }

    func testServiceUsesInjectedDependenciesAndRequestActions() {
        var requestedScreenRecording = false
        var requestedAccessibility = false
        let service = CodexComputerUseStatusService.testing(
            configProbe: { .configured(serverName: "Computer-Use") },
            permissionClient: .init(
                screenRecordingStatus: { .notGranted },
                accessibilityStatus: { .granted },
                requestScreenRecording: {
                    requestedScreenRecording = true
                    return .promptShownRefreshRequired
                },
                requestAccessibility: {
                    requestedAccessibility = true
                    return .granted
                }
            ),
            liveAvailabilityProbe: { .unknown(reason: "No live catalog") },
            now: { Date(timeIntervalSince1970: 42) }
        )

        let status = service.currentStatus(optInEnabled: true)
        XCTAssertFalse(status.isReady)
        XCTAssertEqual(status.pluginConfiguration, .configured(serverName: "Computer-Use"))
        XCTAssertEqual(status.liveAvailability, .unknown(reason: "No live catalog"))
        XCTAssertEqual(status.lastRefreshedAt, Date(timeIntervalSince1970: 42))

        XCTAssertEqual(service.requestScreenRecordingAccess(), .promptShownRefreshRequired)
        XCTAssertTrue(requestedScreenRecording)
        XCTAssertEqual(service.requestAccessibilityAccess(), .granted)
        XCTAssertTrue(requestedAccessibility)
    }

    func testCodexIntegrationConfigParserDetectsComputerUseEntryFromConfigContent() {
        let entries = CodexIntegrationConfiguration.mcpServerEntries(from: """
        [mcp_servers.RepoPromptCE]
        command = "rpce-cli-debug"

        [mcp_servers."computer-use"]
        command = "computer-use"

        [mcp_servers."computer-use".env]
        FOO = "bar"
        """)
        XCTAssertTrue(entries.contains { $0.normalizedName.caseInsensitiveCompare("computer-use") == .orderedSame })
    }

    func testRuntimeResolverResolvesExplicitMCPServerAndRelativePaths() throws {
        let codexDirectory = try makeTemporaryCodexDirectory()
        let configURL = codexDirectory.appendingPathComponent("config.toml")
        try """
        [mcp_servers."computer-use"]
        command = "./bin/computer-use"
        args = ["mcp"]
        cwd = "runtime"
        tool_timeout_sec = 123
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let resolution = CodexComputerUseRuntimeConfiguration.resolve(
            configURL: configURL,
            codexDirectoryURL: codexDirectory
        )
        guard case let .resolved(configuration) = resolution else {
            return XCTFail("Expected resolved explicit MCP server, got \(resolution)")
        }

        let expectedCWD = codexDirectory.appendingPathComponent("runtime").standardizedFileURL.path
        XCTAssertEqual(configuration.serverName, "computer-use")
        XCTAssertEqual(configuration.command, URL(fileURLWithPath: expectedCWD).appendingPathComponent("bin/computer-use").standardizedFileURL.path)
        XCTAssertEqual(configuration.args, ["mcp"])
        XCTAssertEqual(configuration.cwd, expectedCWD)
        XCTAssertEqual(configuration.toolTimeoutSec, 123)
        XCTAssertEqual(
            CodexComputerUseStatusService.configProbe(configURL: configURL, codexDirectoryURL: codexDirectory),
            .configured(serverName: "computer-use")
        )
    }

    func testRuntimeResolverResolvesAppManagedBundledPluginAndStatusSkipsRepoPromptPermissions() throws {
        let codexDirectory = try makeTemporaryCodexDirectory()
        let configURL = codexDirectory.appendingPathComponent("config.toml")
        try """
        [plugins."computer-use@openai-bundled"]
        enabled = true
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let pluginDirectory = codexDirectory.appendingPathComponent(
            "plugins/cache/openai-bundled/computer-use",
            isDirectory: true
        )
        let helperURL = pluginDirectory.appendingPathComponent("Codex Computer Use.app/Contents/MacOS/SkyComputerUseClient")
        try FileManager.default.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: helperURL, atomically: true, encoding: .utf8)
        try """
        {
          "mcpServers": {
            "computer-use": {
              "command": "./Codex Computer Use.app/Contents/MacOS/SkyComputerUseClient",
              "args": ["mcp"],
              "cwd": ".",
              "env": { "SKY_CUA_SERVICE_PATH": "./service" },
              "tool_timeout_sec": 456
            }
          }
        }
        """.write(to: pluginDirectory.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        let manifestURL = pluginDirectory.appendingPathComponent(".codex-plugin/plugin.json")
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        { "name": "computer-use", "version": "1.2.3" }
        """.write(to: manifestURL, atomically: true, encoding: .utf8)

        let resolution = CodexComputerUseRuntimeConfiguration.resolve(
            configURL: configURL,
            codexDirectoryURL: codexDirectory
        )
        guard case let .resolved(configuration) = resolution else {
            return XCTFail("Expected resolved app-managed plugin, got \(resolution)")
        }

        XCTAssertEqual(configuration.command, helperURL.standardizedFileURL.path)
        XCTAssertEqual(configuration.args, ["mcp"])
        XCTAssertEqual(configuration.cwd, pluginDirectory.standardizedFileURL.path)
        XCTAssertEqual(configuration.env, ["SKY_CUA_SERVICE_PATH": "./service"])
        XCTAssertEqual(configuration.toolTimeoutSec, 456)
        XCTAssertEqual(
            CodexComputerUseStatusService.configProbe(configURL: configURL, codexDirectoryURL: codexDirectory),
            .appManagedPluginInstalled(path: pluginDirectory.appendingPathComponent(".mcp.json").path, version: "1.2.3")
        )

        let status = CodexComputerUseStatus(
            optInEnabled: true,
            prerequisites: .init(
                pluginConfiguration: CodexComputerUseStatusService.configProbe(configURL: configURL, codexDirectoryURL: codexDirectory),
                screenRecording: .notGranted,
                accessibility: .notGranted
            )
        )
        XCTAssertTrue(status.usesCodexManagedMacPermissions)
        XCTAssertTrue(status.isReady)
    }

    func testRuntimeResolverSkipsBrokenTmpCandidateWhenCachePluginIsValid() throws {
        let codexDirectory = try makeTemporaryCodexDirectory()
        let configURL = codexDirectory.appendingPathComponent("config.toml")
        try """
        [plugins."computer-use@openai-bundled"]
        enabled = true
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let tmpPluginDirectory = codexDirectory.appendingPathComponent(
            ".tmp/bundled-marketplaces/openai-bundled/plugins/computer-use",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tmpPluginDirectory, withIntermediateDirectories: true)
        try """
        { "mcpServers": { "browser": { "command": "browser" } } }
        """.write(to: tmpPluginDirectory.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)

        let cachePluginDirectory = codexDirectory.appendingPathComponent(
            "plugins/cache/openai-bundled/computer-use",
            isDirectory: true
        )
        let helperURL = cachePluginDirectory.appendingPathComponent("Codex Computer Use.app/Contents/MacOS/SkyComputerUseClient")
        try FileManager.default.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: helperURL, atomically: true, encoding: .utf8)
        try """
        {
          "mcpServers": {
            "computer-use": {
              "command": "./Codex Computer Use.app/Contents/MacOS/SkyComputerUseClient",
              "args": ["mcp"],
              "cwd": "."
            }
          }
        }
        """.write(to: cachePluginDirectory.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)

        let resolution = CodexComputerUseRuntimeConfiguration.resolve(
            configURL: configURL,
            codexDirectoryURL: codexDirectory
        )
        guard case let .resolved(configuration) = resolution else {
            return XCTFail("Expected valid cache plugin to win after broken tmp candidate, got \(resolution)")
        }
        XCTAssertEqual(configuration.command, helperURL.standardizedFileURL.path)
        XCTAssertEqual(
            CodexComputerUseStatusService.configProbe(configURL: configURL, codexDirectoryURL: codexDirectory),
            .appManagedPluginInstalled(path: cachePluginDirectory.appendingPathComponent(".mcp.json").path, version: nil)
        )
    }

    func testRuntimeResolverTreatsPluginMarkerWithoutMCPDefinitionAsIncomplete() throws {
        let codexDirectory = try makeTemporaryCodexDirectory()
        let configURL = codexDirectory.appendingPathComponent("config.toml")
        try """
        [plugins."computer-use@openai-bundled"]
        enabled = true
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let pluginStatus = CodexComputerUseStatusService.configProbe(configURL: configURL, codexDirectoryURL: codexDirectory)
        guard case let .incomplete(path, message) = pluginStatus else {
            return XCTFail("Expected incomplete plugin status, got \(pluginStatus)")
        }
        XCTAssertEqual(path, configURL.path)
        XCTAssertTrue(message.contains(".mcp.json"))

        let status = CodexComputerUseStatus(
            optInEnabled: true,
            prerequisites: .init(
                pluginConfiguration: pluginStatus,
                screenRecording: .notGranted,
                accessibility: .notGranted
            )
        )
        XCTAssertFalse(status.isReady)
        XCTAssertEqual(status.missingRequirements, [.plugin, .screenRecording, .accessibility])
    }

    func testRuntimeResolverTreatsMissingAppManagedHelperAsIncomplete() throws {
        let codexDirectory = try makeTemporaryCodexDirectory()
        let configURL = codexDirectory.appendingPathComponent("config.toml")
        try """
        [plugins.computer-use@openai-bundled]
        enabled = true
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let pluginDirectory = codexDirectory.appendingPathComponent(
            "plugins/cache/openai-bundled/computer-use",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        try """
        {
          "mcpServers": {
            "computer-use": {
              "command": "./Missing.app/Contents/MacOS/SkyComputerUseClient",
              "args": ["mcp"],
              "cwd": "."
            }
          }
        }
        """.write(to: pluginDirectory.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)

        let pluginStatus = CodexComputerUseStatusService.configProbe(configURL: configURL, codexDirectoryURL: codexDirectory)
        guard case let .incomplete(path, message) = pluginStatus else {
            return XCTFail("Expected incomplete plugin status, got \(pluginStatus)")
        }
        XCTAssertEqual(path, pluginDirectory.appendingPathComponent(".mcp.json").path)
        XCTAssertTrue(message.contains("could not be materialized"))
    }

    private func makeTemporaryCodexDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexComputerUseStatusTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory.deletingLastPathComponent())
        return directory
    }
}
