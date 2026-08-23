import Foundation
import RepoPromptHeadlessRuntime
import RepoPromptMCPAdapter
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class HeadlessMCPProvisioningTests: XCTestCase {
    func testRootSessionAdvertisesAgentRunAndExplore() {
        let names = HeadlessCodexMCPToolPolicy.advertisedToolNames(isRootSession: true)
        XCTAssertTrue(names.contains("agent_run"))
        XCTAssertTrue(names.contains("agent_manage"))
        XCTAssertTrue(names.contains("agent_explore"))
    }

    func testChildSessionAdvertisesExploreAndHidesAgentRun() {
        let names = HeadlessCodexMCPToolPolicy.advertisedToolNames(isRootSession: false)
        XCTAssertFalse(names.contains("agent_run"))
        XCTAssertFalse(names.contains("agent_manage"))
        XCTAssertTrue(names.contains("agent_explore"))
    }

    func testIsolatedCodexHomeWritesDesktopShapedRepoPromptMCPBlock() throws {
        let sessionID = UUID()
        let existing = """
        model = "gpt-5.3"
        [mcp_servers.Other]
        command = "/bin/true"
        """
        let rendered = CodexRepoPromptMCPConfig.apply(
            to: existing,
            command: "/usr/local/bin/RepoPromptServer",
            arguments: ["mcp-stdio"],
            sessionID: sessionID,
            socketPath: "/run/repoprompt/mcp.sock"
        )
        XCTAssertTrue(rendered.contains("model = \"gpt-5.3\""))
        XCTAssertTrue(rendered.contains("[mcp_servers.Other]"))
        XCTAssertTrue(rendered.contains("[mcp_servers.RepoPromptCE]"))
        XCTAssertTrue(rendered.contains("command = \"/usr/local/bin/RepoPromptServer\""))
        XCTAssertTrue(rendered.contains("args = [\"mcp-stdio\"]"))
        XCTAssertTrue(rendered.contains("supports_parallel_tool_calls = true"))
        XCTAssertTrue(rendered.contains("enabled = true"))
        XCTAssertTrue(rendered.contains("[mcp_servers.RepoPromptCE.env]"))
        XCTAssertTrue(rendered.contains("REPOPROMPT_MCP_SESSION_ID = \"\(sessionID.uuidString)\""))
        XCTAssertTrue(rendered.contains("REPOPROMPT_MCP_SOCKET = \"/run/repoprompt/mcp.sock\""))
        XCTAssertEqual(rendered.components(separatedBy: "[mcp_servers.RepoPromptCE]").count, 2)
    }

    func testWriteIfNeededRequiresSessionIdentity() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertFalse(try CodexRepoPromptMCPConfig.writeIfNeeded(codexHome: home, policy: .init()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("config.toml").path))

        let sessionID = UUID()
        XCTAssertTrue(try CodexRepoPromptMCPConfig.writeIfNeeded(
            codexHome: home,
            policy: .init(providerSettings: [
                CodexRepoPromptMCPConfig.sessionIDSettingsKey: sessionID.uuidString
            ]),
            environment: [
                "REPOPROMPT_MCP_COMMAND": "/tmp/RepoPromptServer",
                "REPOPROMPT_MCP_SOCKET": "/tmp/mcp.sock"
            ]
        ))
        let written = try String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(written.contains("command = \"/tmp/RepoPromptServer\""))
        XCTAssertTrue(written.contains(sessionID.uuidString))
    }
}
