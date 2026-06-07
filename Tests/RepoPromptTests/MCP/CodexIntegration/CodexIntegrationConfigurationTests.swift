import Foundation
@testable import RepoPrompt
import XCTest

final class CodexIntegrationConfigurationTests: XCTestCase {
    private let repoPromptName = RepoPromptMCPServerConfiguration.defaultServerName
    private let repoPromptHeader = "[mcp_servers.RepoPromptCE]"

    private var serverCommand: String {
        RepoPromptMCPServerConfiguration.repoPrompt.command
    }

    private func mutateCodexPersistentConfigForInstall(_ content: String) -> CodexIntegrationConfiguration.PersistentMCPConfigMutationResult {
        CodexIntegrationConfiguration.mutatedPersistentMCPConfigContent(
            from: content,
            defaultEnabledIfMissing: true,
            forceEnabled: true
        )
    }

    private func allToolOutputLimitLines(in content: String) -> [String] {
        content.components(separatedBy: "\n")
            .filter { $0.contains("tool_output_token_limit") }
    }

    private func topLevelToolOutputLimitLines(in content: String) -> [String] {
        let lines = content.components(separatedBy: "\n")
        let firstHeaderIndex = lines.firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("[") && (trimmed.hasSuffix("]") || trimmed.contains("] #"))
        } ?? lines.count
        return lines[..<firstHeaderIndex].filter { $0.contains("tool_output_token_limit") }
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    func testDiscoveryEnsureWritesBareRepoPromptCEServerHeader() throws {
        var lines: [String] = []

        let result = CodexIntegrationConfiguration.ensureRepoPromptServer(
            in: &lines,
            defaultEnabledIfMissing: false,
            forceEnabled: nil
        )

        XCTAssertTrue(result.changed)
        XCTAssertFalse(result.wasPresent)

        let content = lines.joined(separator: "\n")
        XCTAssertTrue(content.contains(repoPromptHeader))
        XCTAssertTrue(content.contains("command = \"\(serverCommand)\""))
        XCTAssertTrue(content.contains("args = []"))
        XCTAssertTrue(content.contains("tool_timeout_sec = 10000"))
        XCTAssertTrue(content.contains("enabled = false"))

        let entry = try XCTUnwrap(CodexIntegrationConfiguration.mcpServerEntries(from: content).first)
        XCTAssertEqual(entry.normalizedName, "RepoPromptCE")
        XCTAssertEqual(entry.cliPathComponent, "RepoPromptCE")
    }

    func testRepoPromptCEServerEntryProducesBareCodexOverrideKeysForExactName() throws {
        let content = """
        [mcp_servers.RepoPromptCE]
        command = "\(serverCommand)"
        args = []
        enabled = false

        [mcp_servers.repopromptce]
        command = "/tmp/lowercase-rp"
        args = []

        [mcp_servers.OtherServer]
        command = "/tmp/other"
        args = []
        """

        let entries = CodexIntegrationConfiguration.mcpServerEntries(from: content)
        XCTAssertEqual(entries.map(\.normalizedName), ["RepoPromptCE", "repopromptce", "OtherServer"])
        let repoPromptEntry = try XCTUnwrap(entries.first { $0.normalizedName == "RepoPromptCE" })
        XCTAssertEqual(repoPromptEntry.cliPathComponent, "RepoPromptCE")

        let policy = CodexOverrides.MCPPolicy.enableOnlyRepoPrompt(
            repoPromptNormalizedName: repoPromptName,
            exceptBroken: Set<String>()
        )
        let cliArgs = CodexOverrides.cliMCPServerArgs(entries: entries, policy: policy)
        XCTAssertTrue(cliArgs.contains("mcp_servers.RepoPromptCE.enabled=true"))
        XCTAssertTrue(cliArgs.contains("mcp_servers.repopromptce.enabled=false"))
        XCTAssertTrue(cliArgs.contains("mcp_servers.OtherServer.enabled=false"))

        let appServerMap = CodexOverrides.appServerMCPServerMap(entries: entries, policy: policy)
        XCTAssertEqual(appServerMap["mcp_servers.RepoPromptCE.enabled"] as? Bool, true)
        XCTAssertEqual(appServerMap["mcp_servers.repopromptce.enabled"] as? Bool, false)
        XCTAssertEqual(appServerMap["mcp_servers.OtherServer.enabled"] as? Bool, false)
    }

    func testMCPServerEntryParserHandlesQuotedBareAndNestedHeaders() {
        let content = """
        [mcp_servers.RepoPromptCE]
        command = "\(serverCommand)"

        [mcp_servers."server.with.dot"]
        command = "/server"

        [mcp_servers."server.with.dot".env]
        TOKEN = "abc"

        [mcp_servers.'literal server'] # managed
        command = "/literal"

        [mcp_servers.RepoPromptCE.env]
        FOO = "bar"
        """

        let entries = CodexIntegrationConfiguration.mcpServerEntries(from: content)

        XCTAssertEqual(entries.map(\.normalizedName), ["RepoPromptCE", "server.with.dot", "literal server"])
        XCTAssertEqual(entries.map(\.cliPathComponent), ["RepoPromptCE", "\"server.with.dot\"", "\"literal server\""])
    }

    func testRepoPromptNestedSubsectionDoesNotCountAsServerBlock() {
        let content = """
        [mcp_servers.RepoPromptCE.env]
        FOO = "bar"
        """

        let entries = CodexIntegrationConfiguration.mcpServerEntries(from: content)

        XCTAssertFalse(entries.contains { $0.normalizedName == "RepoPromptCE" })
        XCTAssertTrue(entries.isEmpty)
    }

    func testMCPServerConfigurationParserExtractsRuntimeFields() throws {
        let content = """
        [mcp_servers."computer-use"]
        command = "./bin/computer-use"
        args = ["mcp", "--flag"]
        cwd = "helpers"
        enabled = false
        tool_timeout_sec = 10_000

        [mcp_servers."computer-use".env]
        SKY_CUA_SERVICE_PATH = "./service"
        TOKEN = "abc"

        [mcp_servers.RepoPromptCE.env]
        IGNORED = "true"
        """

        let configuration = try XCTUnwrap(CodexIntegrationConfiguration.mcpServerConfiguration(
            named: "Computer-Use",
            fromConfigContent: content
        ))
        XCTAssertEqual(configuration.normalizedName, "computer-use")
        XCTAssertEqual(configuration.command, "./bin/computer-use")
        XCTAssertEqual(configuration.args, ["mcp", "--flag"])
        XCTAssertEqual(configuration.cwd, "helpers")
        XCTAssertEqual(configuration.enabled, false)
        XCTAssertEqual(configuration.toolTimeoutSec, 10000)
        XCTAssertEqual(configuration.env, [
            "SKY_CUA_SERVICE_PATH": "./service",
            "TOKEN": "abc"
        ])
    }

    func testPersistentMutationPreservesUnderscoredGlobalLimitAndStripsServerLevelLimit() {
        let input = """
        tool_output_token_limit = 25_000 # user configured

        [mcp_servers."RepoPromptCE"] # managed
        command = "/old/path"
        args = []
        "tool_output_token_limit"\t=\t25000
        enabled = false
        """

        let result = mutateCodexPersistentConfigForInstall(input)

        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.wasRepoPromptServerPresent)
        XCTAssertTrue(result.content.contains("[mcp_servers.\"RepoPromptCE\"] # managed"))
        XCTAssertTrue(result.content.contains("command = \"\(serverCommand)\""))
        XCTAssertEqual(allToolOutputLimitLines(in: result.content), ["tool_output_token_limit = 25_000 # user configured"])
        XCTAssertFalse(result.content.contains("\"tool_output_token_limit\"\t=\t25000"))
        XCTAssertFalse(result.content.contains("tool_output_token_limit = 25000"))
    }

    func testPersistentMutationRepairsDuplicateValidGlobalsPreservingFirst() {
        let input = """
        "tool_output_token_limit" = 25_000
        tool_output_token_limit = 25000

        [profiles.default]
        model = "gpt-5"
        """

        let result = mutateCodexPersistentConfigForInstall(input)

        XCTAssertEqual(topLevelToolOutputLimitLines(in: result.content), ["\"tool_output_token_limit\" = 25_000"])
        XCTAssertFalse(result.content.contains("\ntool_output_token_limit = 25000"))
    }

    func testPersistentMutationAddsGlobalLimitWhenExistingNumericIsQuoted() {
        let input = """
        tool_output_token_limit = "25000"

        [profiles.default]
        model = "gpt-5"
        """

        let result = mutateCodexPersistentConfigForInstall(input)

        XCTAssertEqual(topLevelToolOutputLimitLines(in: result.content), [
            "tool_output_token_limit = \"25000\"",
            "tool_output_token_limit = 25000"
        ])
    }

    func testPersistentMutationIsIdempotentAfterRepair() {
        let input = """
        tool_output_token_limit = 25_000

        [mcp_servers."RepoPromptCE"]
        command = "/old/path"
        args = []
        tool_output_token_limit = 25000
        enabled = false
        """

        let first = mutateCodexPersistentConfigForInstall(input)
        let second = mutateCodexPersistentConfigForInstall(first.content)

        XCTAssertTrue(first.changed)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.content, first.content)
        XCTAssertEqual(occurrences(of: "[mcp_servers.\"RepoPromptCE\"]", in: second.content), 1)
    }

    func testToolTimeoutMutationHandlesCommandCommentsAndUnderscoredTimeout() {
        let input = """
        tool_output_token_limit = 25_000

        [mcp_servers."RepoPromptCE"] # managed
        command = "\(serverCommand)" # stable helper
        args = []
        tool_timeout_sec = 10_000 # already equivalent
        """

        let result = CodexIntegrationConfiguration.mutatedToolTimeoutConfigContent(from: input)

        XCTAssertTrue(result.foundTarget)
        XCTAssertFalse(result.changed)
        XCTAssertTrue(result.content.contains("tool_timeout_sec = 10_000 # already equivalent"))
    }

    func testToolTimeoutMutationAcceptsIntegerRadixAndSignVariants() {
        let variants = [
            "+10_000",
            "0x2710",
            "0o23420",
            "0b10011100010000"
        ]

        for value in variants {
            let input = """
            tool_output_token_limit = 25_000

            [mcp_servers.RepoPromptCE]
            command = "\(serverCommand)"
            args = []
            tool_timeout_sec = \(value)
            """

            let result = CodexIntegrationConfiguration.mutatedToolTimeoutConfigContent(from: input)

            XCTAssertTrue(result.foundTarget, value)
            XCTAssertFalse(result.changed, value)
            XCTAssertTrue(result.content.contains("tool_timeout_sec = \(value)"), value)
        }
    }

    func testToolTimeoutMutationRejectsQuotedNumericTimeout() {
        let input = """
        tool_output_token_limit = 25_000

        [mcp_servers.RepoPromptCE]
        command = "\(serverCommand)"
        args = []
        tool_timeout_sec = "10000"
        """

        let result = CodexIntegrationConfiguration.mutatedToolTimeoutConfigContent(from: input)

        XCTAssertTrue(result.foundTarget)
        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.content.contains("tool_timeout_sec = 10000"))
        XCTAssertFalse(result.content.contains("tool_timeout_sec = \"10000\""))
    }
}
