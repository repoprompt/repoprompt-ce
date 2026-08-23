import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServiceProtocol

/// Desktop `CodexIntegrationConfiguration.ensureRepoPromptServer` writes
/// `[mcp_servers.RepoPromptCE]` with a real `command`/`args` into Codex's
/// `config.toml`. Linux isolated homes are auth-only unless this same block is
/// applied to the per-run `CODEX_HOME`.
public enum CodexRepoPromptMCPConfig {
    public static let sessionIDSettingsKey = "repoprompt.sessionID"
    public static let provisionedSettingsKey = "repoprompt.mcpProvisioned"
    public static let serverName = "RepoPromptCE"
    public static let defaultCommand = "/usr/local/bin/RepoPromptServer"
    public static let defaultArguments = ["mcp-stdio"]
    public static let defaultSocketPath = "/run/repoprompt/mcp.sock"
    public static let toolTimeoutSeconds = 10_000

    public static func command(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let configured = environment["REPOPROMPT_MCP_COMMAND"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, !configured.isEmpty { return configured }
        let executable = environment["REPOPROMPT_SERVER_EXECUTABLE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let executable, !executable.isEmpty { return executable }
        return defaultCommand
    }

    public static func socketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let configured = environment["REPOPROMPT_MCP_SOCKET"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, !configured.isEmpty { return configured }
        return defaultSocketPath
    }

    public static func isProvisioned(_ settings: [String: String]) -> Bool {
        settings[provisionedSettingsKey] == "true"
    }

    public static func sessionID(from settings: [String: String]) -> UUID? {
        settings[sessionIDSettingsKey].flatMap(UUID.init(uuidString:))
    }

    @discardableResult
    public static func writeIfNeeded(
        codexHome: URL,
        policy: ProviderExecutionPolicy,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Bool {
        guard let sessionID = sessionID(from: policy.providerSettings) else { return false }
        let configURL = codexHome.appendingPathComponent("config.toml")
        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let next = apply(
            to: existing,
            command: command(environment: environment),
            arguments: defaultArguments,
            sessionID: sessionID,
            socketPath: socketPath(environment: environment)
        )
        guard next != existing else { return true }
        try next.write(to: configURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        return true
    }

    public static func apply(
        to existing: String,
        command: String,
        arguments: [String],
        sessionID: UUID,
        socketPath: String
    ) -> String {
        var lines = splitTOMLLines(existing)
        stripRepoPromptBlocks(from: &lines)
        appendBlock(repoPromptSnippet(
            command: command,
            arguments: arguments,
            sessionID: sessionID,
            socketPath: socketPath
        ), to: &lines)
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func repoPromptSnippet(
        command: String,
        arguments: [String],
        sessionID: UUID,
        socketPath: String
    ) -> [String] {
        let args = arguments.map { "\"\(escapeTOML($0))\"" }.joined(separator: ", ")
        return [
            "[mcp_servers.\(serverName)]",
            "command = \"\(escapeTOML(command))\"",
            "args = [\(args)]",
            "tool_timeout_sec = \(toolTimeoutSeconds)",
            "supports_parallel_tool_calls = true",
            "enabled = true",
            "",
            "[mcp_servers.\(serverName).env]",
            "REPOPROMPT_MCP_SESSION_ID = \"\(escapeTOML(sessionID.uuidString))\"",
            "REPOPROMPT_MCP_SOCKET = \"\(escapeTOML(socketPath))\""
        ]
    }

    private static func stripRepoPromptBlocks(from lines: inout [String]) {
        var index = 0
        var ranges: [Range<Int>] = []
        while index < lines.count {
            if isTOMLHeader(lines[index]) {
                let end = nextHeaderIndex(after: index + 1, in: lines)
                if isRepoPromptHeader(lines[index]) {
                    ranges.append(index ..< end)
                }
                index = end
            } else {
                index += 1
            }
        }
        for range in ranges.reversed() {
            lines.removeSubrange(range)
        }
    }

    private static func appendBlock(_ block: [String], to lines: inout [String]) {
        if lines.isEmpty {
            lines.append(contentsOf: block)
            return
        }
        if let last = lines.last, !last.isEmpty {
            lines.append("")
        }
        lines.append(contentsOf: block)
    }

    private static func splitTOMLLines(_ content: String) -> [String] {
        content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func nextHeaderIndex(after start: Int, in lines: [String]) -> Int {
        var index = start
        while index < lines.count {
            if isTOMLHeader(lines[index]) { return index }
            index += 1
        }
        return lines.count
    }

    private static func isTOMLHeader(_ line: String) -> Bool {
        let trimmed = stripComment(line).trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
    }

    private static func isRepoPromptHeader(_ line: String) -> Bool {
        let trimmed = stripComment(line).trimmingCharacters(in: .whitespaces)
        return trimmed == "[mcp_servers.\(serverName)]"
            || trimmed.hasPrefix("[mcp_servers.\(serverName).")
    }

    private static func stripComment(_ line: String) -> String {
        var inString = false
        var escaped = false
        for (index, character) in line.enumerated() {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" && inString {
                escaped = true
                continue
            }
            if character == "\"" {
                inString.toggle()
                continue
            }
            if character == "#", !inString {
                return String(line.prefix(index))
            }
        }
        return line
    }

    private static func escapeTOML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
