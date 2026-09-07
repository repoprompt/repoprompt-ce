import Foundation

extension MCPServerCatalog {
    func renderClaudeJSON() throws -> String {
        var rendered: [String: Any] = [:]
        for server in servers {
            switch server.transport {
            case let .stdio(command, args, environment):
                var definition: [String: Any] = ["args": args, "command": command]
                if !environment.isEmpty { definition["env"] = environment }
                rendered[server.name] = definition
            case let .http(url):
                rendered[server.name] = ["type": "http", "url": url]
            }
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["mcpServers": rendered],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let result = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return result
    }

    func renderCodexTOML() -> String {
        servers.map { server in
            var lines = ["[mcp_servers.\(Self.renderKey(server.name))]"]
            switch server.transport {
            case let .stdio(command, args, environment):
                lines.append("command = \(Self.renderString(command))")
                lines.append("args = [\(args.map(Self.renderString).joined(separator: ", "))]")
                if !environment.isEmpty {
                    let entries = environment.keys.sorted().map { key in
                        "\(Self.renderKey(key)) = \(Self.renderString(environment[key]!))"
                    }
                    lines.append("env = { \(entries.joined(separator: ", ")) }")
                }
            case let .http(url):
                lines.append("url = \(Self.renderString(url))")
            }
            Self.append(server.policy.enabled, key: "enabled", to: &lines)
            Self.append(server.policy.required, key: "required", to: &lines)
            Self.append(server.policy.enabledTools, key: "enabled_tools", to: &lines)
            Self.append(server.policy.tools, key: "tools", to: &lines)
            Self.append(
                server.policy.supportsParallelToolCalls,
                key: "supports_parallel_tool_calls",
                to: &lines
            )
            Self.append(server.policy.toolTimeoutSeconds, key: "tool_timeout_sec", to: &lines)
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func append(_ value: Bool?, key: String, to lines: inout [String]) {
        if let value { lines.append("\(key) = \(value)") }
    }

    private static func append(_ value: Int?, key: String, to lines: inout [String]) {
        if let value { lines.append("\(key) = \(value)") }
    }

    private static func append(_ value: [String]?, key: String, to lines: inout [String]) {
        if let value {
            lines.append("\(key) = [\(value.map(renderString).joined(separator: ", "))]")
        }
    }

    private static func renderKey(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        return !value.isEmpty && value.unicodeScalars.allSatisfy(allowed.contains) ? value : renderString(value)
    }

    private static func renderString(_ value: String) -> String {
        var rendered = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": rendered += "\\\""
            case "\\": rendered += "\\\\"
            case "\u{08}": rendered += "\\b"
            case "\u{0C}": rendered += "\\f"
            case "\n": rendered += "\\n"
            case "\r": rendered += "\\r"
            case "\t": rendered += "\\t"
            case "\u{00}" ... "\u{1F}": rendered += String(format: "\\u%04X", scalar.value)
            default: rendered.unicodeScalars.append(scalar)
            }
        }
        return rendered + "\""
    }
}
