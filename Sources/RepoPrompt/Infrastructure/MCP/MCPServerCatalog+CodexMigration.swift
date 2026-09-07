import Foundation

extension MCPServerCatalog {
    struct Draft {
        let name: String
        var values: [String: String] = [:]
    }

    private static let migrationKeys: Set<String> = [
        "command", "args", "env", "url", "enabled", "required",
        "enabled_tools", "tools", "supports_parallel_tool_calls", "tool_timeout_sec"
    ]

    init(migratingCodexTOML content: String) throws {
        var drafts: [Draft] = []
        var current: Draft?
        for rawLine in content.split(whereSeparator: \.isNewline).map(String.init) {
            let line = Self.withoutComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.first == "[" {
                if let current { drafts.append(current) }
                current = try Self.migrationServerName(from: line).map(Draft.init(name:))
                continue
            }
            guard var draft = current else { continue }
            guard let separator = Self.firstUnquoted("=", in: line) else {
                throw MigrationError.malformedValue(server: draft.name, key: line)
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard Self.migrationKeys.contains(key) else {
                throw MigrationError.malformedValue(server: draft.name, key: key)
            }
            guard draft.values.updateValue(value, forKey: key) == nil else {
                throw MigrationError.duplicateValue(server: draft.name, key: key)
            }
            current = draft
        }
        if let current { drafts.append(current) }
        try self.init(servers: drafts.map(Self.migrate))
    }

    private static func migrate(_ draft: Draft) throws -> Server {
        let command = try optionalString(draft, "command")
        let url = try optionalString(draft, "url")
        guard (command == nil) != (url == nil) else {
            throw MigrationError.invalidDefinition(draft.name)
        }
        let args = try optionalStrings(draft, "args")
        let environment = try optionalEnvironment(draft)
        let transport: Transport
        if let command {
            transport = .stdio(command: command, args: args ?? [], environment: environment ?? [:])
        } else {
            guard args == nil, environment == nil, let url else {
                throw MigrationError.invalidDefinition(draft.name)
            }
            transport = .http(url: url)
        }
        let timeout = try optionalInteger(draft, "tool_timeout_sec")
        guard timeout.map({ $0 > 0 }) != false else {
            throw MigrationError.malformedValue(server: draft.name, key: "tool_timeout_sec")
        }
        return try Server(
            name: draft.name,
            transport: transport,
            policy: Policy(
                enabled: optionalBoolean(draft, "enabled"),
                required: optionalBoolean(draft, "required"),
                enabledTools: optionalStrings(draft, "enabled_tools"),
                tools: optionalStrings(draft, "tools"),
                supportsParallelToolCalls: optionalBoolean(draft, "supports_parallel_tool_calls"),
                toolTimeoutSeconds: timeout
            )
        )
    }
}
