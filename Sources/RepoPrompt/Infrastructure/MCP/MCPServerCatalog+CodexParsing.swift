import Foundation

extension MCPServerCatalog {
    static func optionalString(_ draft: Draft, _ key: String) throws -> String? {
        try draft.values[key].map { try decodeString($0, server: draft.name, key: key) }
    }

    static func optionalStrings(_ draft: Draft, _ key: String) throws -> [String]? {
        try draft.values[key].map { value in
            guard let data = value.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  decoded.allSatisfy({ $0 is String })
            else {
                throw MigrationError.malformedValue(server: draft.name, key: key)
            }
            return decoded.compactMap { $0 as? String }
        }
    }

    static func optionalBoolean(_ draft: Draft, _ key: String) throws -> Bool? {
        try draft.values[key].map {
            guard $0 == "true" || $0 == "false" else {
                throw MigrationError.malformedValue(server: draft.name, key: key)
            }
            return $0 == "true"
        }
    }

    static func optionalInteger(_ draft: Draft, _ key: String) throws -> Int? {
        try draft.values[key].map {
            guard let value = Int($0) else {
                throw MigrationError.malformedValue(server: draft.name, key: key)
            }
            return value
        }
    }

    static func optionalEnvironment(_ draft: Draft) throws -> [String: String]? {
        guard let raw = draft.values["env"] else { return nil }
        guard raw.first == "{", raw.last == "}" else {
            throw MigrationError.malformedValue(server: draft.name, key: "env")
        }
        let body = raw.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for entry in try splitTopLevel(body) {
            guard let separator = firstUnquoted("=", in: entry) else {
                throw MigrationError.malformedValue(server: draft.name, key: "env")
            }
            let key = try decodeKey(entry[..<separator].trimmingCharacters(in: .whitespaces))
            let value = try decodeString(
                entry[entry.index(after: separator)...].trimmingCharacters(in: .whitespaces),
                server: draft.name,
                key: "env"
            )
            guard !key.isEmpty, result.updateValue(value, forKey: key) == nil else {
                throw MigrationError.malformedValue(server: draft.name, key: "env")
            }
        }
        return result
    }

    static func migrationServerName(from header: String) throws -> String? {
        guard header.last == "]", !header.hasPrefix("[[") else {
            throw MigrationError.malformedHeader(header)
        }
        let inner = header.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("mcp_servers") else { return nil }
        let suffix = inner.dropFirst("mcp_servers".count)
        guard suffix.first == "." else { throw MigrationError.malformedHeader(header) }
        let name = try decodeKey(suffix.dropFirst().trimmingCharacters(in: .whitespaces))
        guard !name.isEmpty else { throw MigrationError.malformedHeader(header) }
        return name
    }

    static func decodeKey(_ token: String) throws -> String {
        if token.first == "\"" {
            return try decodeString(token, server: "", key: token)
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        guard !token.isEmpty, token.unicodeScalars.allSatisfy(allowed.contains) else {
            throw MigrationError.malformedHeader(token)
        }
        return token
    }

    static func decodeString(_ value: String, server: String, key: String) throws -> String {
        guard value.first == "\"", value.last == "\"",
              let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8))
        else {
            throw MigrationError.malformedValue(server: server, key: key)
        }
        return decoded
    }

    static func splitTopLevel(_ input: String) throws -> [String] {
        var parts: [String] = []
        var start = input.startIndex
        var quoted = false
        var escaped = false
        for index in input.indices {
            let character = input[index]
            if quoted {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { quoted = false }
            } else if character == "\"" {
                quoted = true
            } else if character == "," {
                let part = input[start ..< index].trimmingCharacters(in: .whitespaces)
                guard !part.isEmpty else { throw MigrationError.malformedHeader(input) }
                parts.append(part)
                start = input.index(after: index)
            }
        }
        let final = input[start...].trimmingCharacters(in: .whitespaces)
        guard !quoted, !escaped, !final.isEmpty else { throw MigrationError.malformedHeader(input) }
        parts.append(final)
        return parts
    }

    static func withoutComment(_ line: String) -> String {
        firstUnquoted("#", in: line).map { String(line[..<$0]) } ?? line
    }

    static func firstUnquoted(_ target: Character, in input: String) -> String.Index? {
        var quoted = false
        var escaped = false
        for index in input.indices {
            let character = input[index]
            if quoted {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { quoted = false }
            } else if character == "\"" {
                quoted = true
            } else if character == target {
                return index
            }
        }
        return nil
    }
}
