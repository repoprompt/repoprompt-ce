import Foundation

/// A deliberately bounded TOML subset for MCP definitions, not a general config parser.
/// Unknown layouts are rejected rather than copied into a working managed configuration.
enum CodexUserMCPImportValidation {
    enum Kind: Equatable {
        case string, boolean, number, integer, strings, stringMap
    }

    static let rootKinds: [String: Kind] = [
        "command": .string, "args": .strings, "env": .stringMap, "env_vars": .strings,
        "cwd": .string, "url": .string, "bearer_token_env_var": .string,
        "http_headers": .stringMap, "env_http_headers": .stringMap,
        "startup_timeout_sec": .number, "startup_timeout_ms": .integer, "tool_timeout_sec": .number,
        "enabled": .boolean, "required": .boolean, "enabled_tools": .strings, "disabled_tools": .strings,
        "tools": .strings, "supports_parallel_tool_calls": .boolean
    ]

    static func validate(_ value: String, as kind: Kind) throws {
        var parser = Parser(characters: Array(value))
        parser.skip(horizontalOnly: true)
        try parser.value(kind)
        parser.skip()
        guard parser.index == parser.characters.count else { throw CodexUserMCPImport.Failure.unsupportedConfiguration }
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

        mutating func value(_ kind: Kind) throws {
            switch kind {
            case .string:
                _ = try string()
            case .boolean, .number, .integer:
                let start = index
                while let character = current, ![" ", "\t", "\n", "\r\n", "#"].contains(character) {
                    index += 1
                }
                let token = String(characters[start ..< index])
                if kind == .boolean {
                    guard token == "true" || token == "false" else { throw CodexUserMCPImport.Failure.unsupportedConfiguration }
                } else {
                    let pattern = #"^\+?(?:0|[1-9][0-9]*(?:_[0-9]+)*)(?:\.[0-9]+(?:_[0-9]+)*)?(?:[eE][+-]?[0-9]+(?:_[0-9]+)*)?$"#
                    let cleaned = token.replacingOccurrences(of: "_", with: "")
                    let isInteger = !cleaned.contains(".") && !cleaned.lowercased().contains("e")
                    guard token.count <= 64, token.range(of: pattern, options: .regularExpression) != nil,
                          kind != .integer || isInteger,
                          !isInteger || Int64(cleaned) != nil,
                          let number = Double(cleaned), number.isFinite,
                          number >= 0, number <= Double(Int.max) else { throw CodexUserMCPImport.Failure.unsupportedConfiguration }
                }
            case .strings:
                try take("[")
                skip()
                while current != "]" {
                    _ = try string()
                    skip()
                    if current == "]" { break }
                    try take(",")
                    skip()
                }
                try take("]")
            case .stringMap:
                try take("{")
                skip(horizontalOnly: true)
                var names = Set<String>()
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
                    guard names.insert(key).inserted else { throw CodexUserMCPImport.Failure.unsupportedConfiguration }
                    skip(horizontalOnly: true)
                    try take("=")
                    skip(horizontalOnly: true)
                    _ = try string()
                    skip(horizontalOnly: true)
                    if current == "}" { break }
                    try take(",")
                    skip(horizontalOnly: true)
                    // TOML 1.0 inline tables cannot have a trailing comma or structural newline.
                    guard current != "}" else { throw CodexUserMCPImport.Failure.unsupportedConfiguration }
                }
                try take("}")
            }
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
