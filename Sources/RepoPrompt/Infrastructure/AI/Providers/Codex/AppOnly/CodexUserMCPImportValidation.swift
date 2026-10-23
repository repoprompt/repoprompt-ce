import Foundation

/// A deliberately bounded TOML subset for MCP definitions, not a general config parser.
/// Unknown layouts are rejected rather than copied into a working managed configuration.
enum CodexUserMCPImportValidation {
    indirect enum Value {
        case string(String), boolean(Bool), number(Double, integer: Bool)
        case array([Value]), object([String: Value])
    }

    struct InvalidKey: Error {
        let path: [String]
    }

    static func parse(_ text: String) throws -> Value {
        var parser = Parser(characters: Array(text))
        parser.skip(horizontalOnly: true)
        let value = try parser.value()
        parser.skip()
        guard parser.index == parser.characters.count else { throw CodexUserMCPImport.Failure.unsupportedConfiguration }
        return value
    }

    static func validate(_ object: [String: Value]) throws {
        let definitions = CodexUserMCPSchema.definitions
        try validate(.object(object), schema: definitions["RawMcpServerConfig"] as? [String: Any] ?? [:], definitions: definitions, path: [])
        let command = object["command"] != nil
        guard command != (object["url"] != nil) else { throw InvalidKey(path: ["command", "url"]) }
        let incompatible = command
            ? ["url", "bearer_token_env_var", "http_headers_helper", "http_headers", "env_http_headers", "oauth", "oauth_resource", "auth"]
            : ["args", "env", "env_vars", "cwd"]
        for key in incompatible where object[key] != nil {
            throw InvalidKey(path: [key])
        }
        for key in ["startup_timeout_sec", "tool_timeout_sec"] {
            if case let .number(value, _) = object[key], value < 0 || value >= Double(UInt64.max) { throw InvalidKey(path: [key]) }
        }
        if case let .array(entries) = object["env_vars"] {
            for entry in entries {
                if case let .object(fields) = entry, case let .string(source) = fields["source"], !["local", "remote"].contains(source) {
                    throw InvalidKey(path: ["env_vars", "source"])
                }
            }
        }
        if case let .string(helper) = object["http_headers_helper"] {
            guard !helper.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InvalidKey(path: ["http_headers_helper"]) }
            if case let .string(environment) = object["environment_id"], environment != "local" { throw InvalidKey(path: ["environment_id"]) }
        }
        if case let .object(oauth) = object["oauth"] {
            if case let .string(secret) = oauth["client_secret"] {
                guard !secret.isEmpty, case let .string(client) = oauth["client_id"], !client.isEmpty else { throw InvalidKey(path: ["oauth", "client_secret"]) }
            }
            if oauth["authorization_server_issuer"] != nil {
                guard case .string("ema_auth") = object["auth"] else { throw InvalidKey(path: ["oauth", "authorization_server_issuer"]) }
            }
        }
    }

    private static func validate(_ value: Value, schema: [String: Any], definitions: [String: Any], path: [String]) throws {
        if let ref = schema["$ref"] as? String, let target = definitions[String(ref.split(separator: "/").last ?? "")] as? [String: Any] {
            return try validate(value, schema: target, definitions: definitions, path: path)
        }
        if let all = schema["allOf"] as? [[String: Any]] {
            for child in all {
                try validate(value, schema: child, definitions: definitions, path: path)
            }
            return
        }
        if let options = (schema["oneOf"] ?? schema["anyOf"]) as? [[String: Any]] {
            guard options.contains(where: { (try? validate(value, schema: $0, definitions: definitions, path: path)) != nil }) else { throw InvalidKey(path: path) }
            return
        }
        switch (schema["type"] as? String, value) {
        case let ("string", .string(text)):
            if let choices = schema["enum"] as? [String], !choices.contains(text) { throw InvalidKey(path: path) }
        case ("boolean", .boolean): break
        case let (type?, .number(number, integer)) where type == "number" || type == "integer":
            guard type != "integer" || integer,
                  number >= (schema["minimum"] as? Double ?? -Double.greatestFiniteMagnitude),
                  number <= (schema["maximum"] as? Double ?? Double.greatestFiniteMagnitude) else { throw InvalidKey(path: path) }
            if let format = schema["format"] as? String, format.hasPrefix("uint") {
                guard number >= 0, number < Double(UInt64.max), format != "uint16" || number <= 65535 else { throw InvalidKey(path: path) }
            }
        case let ("array", .array(items)):
            guard let itemSchema = schema["items"] as? [String: Any] else { throw InvalidKey(path: path) }
            for item in items {
                try validate(item, schema: itemSchema, definitions: definitions, path: path)
            }
        case let ("object", .object(fields)):
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            for required in schema["required"] as? [String] ?? [] where fields[required] == nil {
                throw InvalidKey(path: path + [required])
            }
            for (key, field) in fields {
                guard let child = properties[key] ?? schema["additionalProperties"] as? [String: Any] else { throw InvalidKey(path: path + [key]) }
                try validate(field, schema: child, definitions: definitions, path: path + [key])
            }
        default: throw InvalidKey(path: path)
        }
    }

    private struct Parser {
        let characters: [Character]
        var index = 0
        var current: Character? {
            index < characters.count ? characters[index] : nil
        }

        mutating func skip(horizontalOnly: Bool = false) {
            while let character = current {
                if character == " " || character == "\t" || (!horizontalOnly && (character == "\n" || character == "\r\n")) {
                    index += 1
                } else if !horizontalOnly, character == "#" {
                    while let next = current, next != "\n", next != "\r\n" {
                        index += 1
                    }
                } else {
                    break
                }
            }
        }

        mutating func take(_ expected: Character) throws {
            guard current == expected else { throw CodexUserMCPImport.Failure.unsupportedConfiguration }
            index += 1
        }

        mutating func value(depth: Int = 0) throws -> Value {
            guard depth < 16 else { throw CodexUserMCPImport.Failure.unsupportedConfiguration }
            if current == "\"" || current == "'" { return try .string(string()) }
            if current == "[" {
                try take("[")
                skip()
                var values: [Value] = []
                while current != "]" {
                    try values.append(value(depth: depth + 1))
                    skip()
                    if current == "]" { break }
                    try take(",")
                    skip()
                }
                try take("]")
                return .array(values)
            }
            if current == "{" {
                try take("{")
                skip(horizontalOnly: true)
                var fields: [String: Value] = [:]
                while current != "}" {
                    let key: String
                    if current == "\"" || current == "'" {
                        key = try string(allowsMultiline: false)
                    } else {
                        let start = index
                        while let character = current, character.isASCII,
                              character.isLetter || character.isNumber || character == "_" || character == "-"
                        {
                            index += 1
                        }
                        guard index > start else { throw CodexUserMCPImport.Failure.unsupportedConfiguration }
                        key = String(characters[start ..< index])
                    }
                    guard fields[key] == nil else { throw CodexUserMCPImport.Failure.unsupportedConfiguration }
                    skip(horizontalOnly: true)
                    try take("=")
                    skip(horizontalOnly: true)
                    fields[key] = try value(depth: depth + 1)
                    skip(horizontalOnly: true)
                    if current == "}" { break }
                    try take(",")
                    skip(horizontalOnly: true)
                    guard current != "}" else { throw CodexUserMCPImport.Failure.unsupportedConfiguration }
                }
                try take("}")
                return .object(fields)
            }
            let start = index
            while let character = current, ![" ", "\t", "\n", "\r\n", "#", ",", "]", "}"].contains(character) {
                index += 1
            }
            let token = String(characters[start ..< index])
            if token == "true" || token == "false" { return .boolean(token == "true") }
            let pattern = #"^[+-]?(?:0|[1-9][0-9]*(?:_[0-9]+)*)(?:\.[0-9]+(?:_[0-9]+)*)?(?:[eE][+-]?[0-9]+(?:_[0-9]+)*)?$"#
            let cleaned = token.replacingOccurrences(of: "_", with: "")
            let integer = !cleaned.contains(".") && !cleaned.lowercased().contains("e")
            guard token.count <= 64, token.range(of: pattern, options: .regularExpression) != nil,
                  !integer || Int64(cleaned) != nil,
                  let number = Double(cleaned), number.isFinite else { throw CodexUserMCPImport.Failure.unsupportedConfiguration }
            return .number(number, integer: integer)
        }

        mutating func string(allowsMultiline: Bool = true) throws -> String {
            guard let quote = current, quote == "\"" || quote == "'" else {
                throw CodexUserMCPImport.Failure.unsupportedConfiguration
            }
            index += 1
            let multiline = index + 1 < characters.count && characters[index] == quote && characters[index + 1] == quote
            if multiline {
                guard allowsMultiline else { throw CodexUserMCPImport.Failure.unsupportedConfiguration }
                index += 2
            }
            var decoded = ""
            while let character = current {
                if character == quote {
                    if !multiline {
                        index += 1
                        return decoded
                    }
                    var end = index
                    while end < characters.count, characters[end] == quote {
                        end += 1
                    }
                    if end - index >= 3 {
                        guard end - index <= 5 else { throw CodexUserMCPImport.Failure.unsupportedConfiguration }
                        decoded += String(repeating: String(quote), count: end - index - 3)
                        index = end
                        return decoded
                    }
                }
                if character == "\\", quote == "\"" {
                    index += 1
                    guard let escape = current else { throw CodexUserMCPImport.Failure.unsupportedConfiguration }
                    if multiline, escape == "\n" || escape == "\r\n" || escape == " " || escape == "\t" {
                        while current == " " || current == "\t" {
                            index += 1
                        }
                        guard current == "\n" || current == "\r\n" else { throw CodexUserMCPImport.Failure.unsupportedConfiguration }
                        while let next = current, [" ", "\t", "\n", "\r\n"].contains(next) {
                            index += 1
                        }
                        continue
                    }
                    let count = escape == "u" ? 5 : (escape == "U" ? 9 : 1)
                    guard index + count <= characters.count else { throw CodexUserMCPImport.Failure.unsupportedConfiguration }
                    let raw = "\\" + String(characters[index ..< index + count])
                    guard let value = CodexIntegrationConfiguration.decodeDoubleQuotedTomlKey(raw) else {
                        throw CodexUserMCPImport.Failure.unsupportedConfiguration
                    }
                    decoded += value
                    index += count
                    continue
                }
                guard character.unicodeScalars.allSatisfy({
                    $0.value == 9 || (multiline && ($0.value == 10 || $0.value == 13)) || ($0.value >= 32 && $0.value != 127)
                }) else { throw CodexUserMCPImport.Failure.unsupportedConfiguration }
                decoded.append(character)
                index += 1
            }
            throw CodexUserMCPImport.Failure.unsupportedConfiguration
        }
    }
}
