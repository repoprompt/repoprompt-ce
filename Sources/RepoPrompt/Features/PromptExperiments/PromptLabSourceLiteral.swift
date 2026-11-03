#if DEBUG
    import Foundation

    /// The exact source token is sealed separately from its decoded runtime prompt. Replacing
    /// this token, rather than arbitrary prompt text, preserves the surrounding program.
    struct PromptLabSourceLiteral: Codable, Equatable {
        enum Language: String, Codable { case json, python, javascript, swift }
        var language: Language
        var token: String
    }

    enum PromptLabSourceCodec {
        private struct Token {
            var range: Range<Int>
            var content: Range<Int>
            var quote: UInt8
            var triple: Bool
            var prefix: String
            var hashes: Int
        }

        static func isPlainText(_ url: URL) -> Bool {
            ["md", "markdown", "txt", "text", "prompt", "tmpl", "jinja", "jinja2", "j2", "mustache", "hbs"].contains(url.pathExtension.lowercased())
        }

        static func importLiteral(source: String, selection: String, url: URL) throws -> (prompt: String, literal: PromptLabSourceLiteral) {
            let language = try language(for: url)
            let bytes = Array(source.utf8)
            let selected = Array(selection.utf8)
            guard !selected.isEmpty, let range = source.range(of: selection),
                  source.range(of: selection, range: range.upperBound ..< source.endIndex) == nil
            else { throw refusal("Select one complete string literal, or all of its contents, occurring exactly once in the source.") }
            let start = source.utf8.distance(from: source.utf8.startIndex, to: range.lowerBound)
            let selectedRange = start ..< (start + selected.count)
            let candidates = try tokens(in: bytes, language: language)
            guard let token = candidates.first(where: { $0.range == selectedRange || $0.content == selectedRange }) else {
                throw refusal("The selected passage is not one complete static string literal. Include its quotes, or select its complete encoded contents.")
            }
            try requireStatic(token, bytes: bytes, language: language, candidates: candidates)
            let content = String(decoding: bytes[token.content], as: UTF8.self)
            let value = try decoded(content, token: token, language: language)
            return (value, .init(language: language, token: String(decoding: bytes[token.range], as: UTF8.self)))
        }

        static func replacement(source: PromptLabSource, original: String, candidate: String) throws -> String {
            guard let path = source.filePath else { throw refusal("Reimport the source file before applying a candidate.") }
            let url = URL(fileURLWithPath: path)
            guard let selection = source.selection else {
                guard isPlainText(url) else { throw refusal("Choose a prompt string inside this code file before starting an experiment; the complete code file cannot be replaced with a prompt.") }
                return candidate + (original.hasSuffix("\n") && !candidate.hasSuffix("\n") ? "\n" : "")
            }
            if isPlainText(url) {
                guard source.literal == nil, selection == source.prompt, original.components(separatedBy: selection).count == 2 else {
                    throw refusal("The selected prompt region no longer matches the imported source.")
                }
                return original.replacingOccurrences(of: selection, with: candidate)
            }
            let imported = try importLiteral(source: original, selection: selection, url: url)
            guard imported.prompt == source.prompt, source.literal == nil || source.literal == imported.literal else {
                throw refusal("The source literal no longer matches the imported prompt. Reimport it before applying a candidate.")
            }
            guard original.components(separatedBy: imported.literal.token).count == 2 else {
                throw refusal("The complete source literal is ambiguous. Select a unique prompt definition.")
            }
            let result = original.replacingOccurrences(of: imported.literal.token, with: encoded(candidate, language: imported.literal.language))
            if imported.literal.language == .json {
                guard (try? JSONSerialization.jsonObject(with: Data(result.utf8), options: [.fragmentsAllowed])) != nil else {
                    throw refusal("The replacement would not be valid JSON.")
                }
            }
            return result
        }

        /// A conventional quoted literal avoids delimiter collisions, interpolation and
        /// indentation changes. Newlines stay encoded; bytes outside the token stay exact.
        static func encoded(_ value: String, language: PromptLabSourceLiteral.Language) -> String {
            var result = "\""
            for scalar in value.unicodeScalars {
                switch scalar.value {
                case 0x22: result += "\\\""
                case 0x5C: result += "\\\\"
                case 0x0A: result += "\\n"
                case 0x0D: result += "\\r"
                case 0x09: result += "\\t"
                case 0 ... 0x1F, 0x2028, 0x2029:
                    if language == .swift { result += "\\u{\(String(scalar.value, radix: 16))}" }
                    else { result += String(format: "\\u%04x", scalar.value) }
                default: result.unicodeScalars.append(scalar)
                }
            }
            return result + "\""
        }

        private static func language(for url: URL) throws -> PromptLabSourceLiteral.Language {
            switch url.pathExtension.lowercased() {
            case "json": return .json
            case "py", "pyi": return .python
            case "js", "jsx", "ts", "tsx", "mjs", "cjs": return .javascript
            case "swift": return .swift
            default: throw refusal("Automatic source application supports text templates and static JSON, Python, JavaScript/TypeScript, or Swift string literals.")
            }
        }

        private static func refusal(_ detail: String) -> PromptExperimentAuthorityError {
            .invalidRequest(detail + " For dynamic or unsupported expressions, paste the resolved prompt to optimize it and export the result for manual integration.")
        }

        private static func tokens(in bytes: [UInt8], language: PromptLabSourceLiteral.Language) throws -> [Token] {
            if language == .json, (try? JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed])) == nil {
                throw refusal("The selected file is not valid JSON.")
            }
            var result: [Token] = []
            var index = 0
            while index < bytes.count {
                if language == .python, bytes[index] == 35 {
                    while index < bytes.count, bytes[index] != 10 {
                        index += 1
                    }
                    continue
                }
                if language == .swift || language == .javascript, matches([47, 47], bytes, index) {
                    while index < bytes.count, bytes[index] != 10 {
                        index += 1
                    }
                    continue
                }
                if language == .swift || language == .javascript, matches([47, 42], bytes, index) {
                    index = try skipComment(bytes, from: index, nested: language == .swift)
                    continue
                }
                if language == .javascript, bytes[index] == 47, likelyRegularExpression(bytes, at: index) {
                    index = try skipRegularExpression(bytes, from: index)
                    continue
                }
                let quote = bytes[index]
                guard quote == 34 || (quote == 39 && (language == .python || language == .javascript)) || (quote == 96 && language == .javascript) else {
                    index += 1
                    continue
                }
                var start = index
                var prefix = ""
                var hashes = 0
                if language == .python {
                    while start > 0, isLetter(bytes[start - 1]) {
                        start -= 1
                    }
                    prefix = String(decoding: bytes[start ..< index], as: UTF8.self).lowercased()
                } else if language == .swift {
                    while start > 0, bytes[start - 1] == 35 {
                        start -= 1
                        hashes += 1
                    }
                }
                let triple = (language == .python || language == .swift) && matches([quote, quote, quote], bytes, index)
                let quoteCount = triple ? 3 : 1
                let contentStart = index + quoteCount
                let closing = Array(repeating: quote, count: quoteCount) + Array(repeating: UInt8(35), count: hashes)
                index = contentStart
                while index < bytes.count {
                    if matches(closing, bytes, index) { break }
                    if bytes[index] == 92 {
                        let escape = [UInt8(92)] + Array(repeating: UInt8(35), count: hashes)
                        if matches(escape, bytes, index) { index += escape.count + 1
                            continue
                        }
                    }
                    index += 1
                }
                guard index < bytes.count else { throw refusal("The source contains an unterminated string literal.") }
                result.append(Token(range: start ..< (index + closing.count), content: contentStart ..< index, quote: quote, triple: triple, prefix: prefix, hashes: hashes))
                index += closing.count
            }
            return result
        }

        private static func requireStatic(_ token: Token, bytes: [UInt8], language: PromptLabSourceLiteral.Language, candidates: [Token]) throws {
            let before = bytes[..<token.range.lowerBound].lastIndex(where: { !isWhitespace($0) })
            let after = bytes[token.range.upperBound...].firstIndex(where: { !isWhitespace($0) })
            if language == .json {
                if let after, bytes[after] == 58 { throw refusal("Select a JSON string value, not its property name.") }
                return
            }
            if language == .python, !["", "u", "r"].contains(token.prefix) {
                throw refusal("Formatted, byte, and dynamically prefixed Python strings cannot be applied automatically.")
            }
            if let before, bytes[before] == 43 { throw refusal("Concatenated prompt expressions require manual integration.") }
            if let after, bytes[after] == 43 { throw refusal("Concatenated prompt expressions require manual integration.") }
            if language == .python, let after,
               bytes[after] == 37 || bytes[after] == 46
            {
                throw refusal("Formatted or transformed Python prompt expressions require manual integration.")
            }
            if language == .python {
                for other in candidates where other.range != token.range {
                    let gap: Range<Int>? = if other.range.upperBound <= token.range.lowerBound { other.range.upperBound ..< token.range.lowerBound }
                    else if token.range.upperBound <= other.range.lowerBound { token.range.upperBound ..< other.range.lowerBound }
                    else { nil }
                    if let gap, bytes[gap].allSatisfy(isWhitespace) { throw refusal("Adjacent Python literals form a concatenated prompt; select or extract one complete static prompt definition.") }
                }
            }
            if language == .javascript, token.quote == 96, let before,
               isLetter(bytes[before]) || bytes[before] == 41 || bytes[before] == 93
            {
                throw refusal("Tagged template literals require manual integration.")
            }
        }

        private static func decoded(_ raw: String, token: Token, language: PromptLabSourceLiteral.Language) throws -> String {
            var content = raw
            if token.triple || token.quote == 96 { content = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
            else if content.contains("\n") || content.contains("\r") { throw refusal("Use a valid multiline literal for a multiline source prompt.") }
            if language == .swift, token.triple { content = try swiftMultiline(content) }
            if language == .python, token.prefix == "r" { return content }
            let scalars = Array(content.unicodeScalars)
            var result = String.UnicodeScalarView()
            var index = 0
            while index < scalars.count {
                let scalar = scalars[index]
                if language == .javascript, token.quote == 96, scalar == "$", index + 1 < scalars.count, scalars[index + 1] == "{" {
                    throw refusal("Interpolated JavaScript templates require manual integration.")
                }
                guard scalar == "\\", escapeMarkerMatches(scalars, at: index, hashes: token.hashes) else {
                    result.append(scalar)
                    index += 1
                    continue
                }
                index += 1 + token.hashes
                guard index < scalars.count else { throw refusal("The source literal ends with an incomplete escape.") }
                let escaped = scalars[index]
                index += 1
                switch escaped {
                case "\"", "\\": result.append(escaped)
                case "'" where language != .json: result.append(escaped)
                case "/" where language == .json || language == .javascript: result.append(escaped)
                case "`" where language == .javascript, "$" where language == .javascript: result.append(escaped)
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "b" where language != .swift: result.append("\u{8}")
                case "f" where language != .swift: result.append("\u{C}")
                case "v" where language == .python || language == .javascript: result.append("\u{B}")
                case "a" where language == .python: result.append("\u{7}")
                case "0" where language == .swift: result.append("\0")
                case "0" where language == .javascript:
                    guard index == scalars.count || !("0" ... "9").contains(scalars[index]) else { throw refusal("Legacy JavaScript octal escapes are not supported.") }
                    result.append("\0")
                case "0" ... "7" where language == .python:
                    var digits = String(escaped)
                    while digits.count < 3, index < scalars.count, ("0" ... "7").contains(scalars[index]) {
                        digits.unicodeScalars.append(scalars[index])
                        index += 1
                    }
                    guard let value = UInt32(digits, radix: 8), let scalar = UnicodeScalar(value) else { throw refusal("Invalid octal escape.") }
                    result.append(scalar)
                case "u", "U", "x":
                    let value = try unicodeEscape(escaped, scalars: scalars, index: &index, language: language)
                    result.append(value)
                case "\n" where language == .python || language == .javascript: break
                case "(" where language == .swift: throw refusal("Interpolated Swift strings require manual integration.")
                default: throw refusal("The source literal contains an unsupported or dynamic escape.")
                }
            }
            return String(result)
        }

        private static func unicodeEscape(_ escape: UnicodeScalar, scalars: [UnicodeScalar], index: inout Int, language: PromptLabSourceLiteral.Language) throws -> UnicodeScalar {
            var value: UInt32
            if escape == "u", language == .swift || language == .javascript, index < scalars.count, scalars[index] == "{" {
                index += 1
                let start = index
                while index < scalars.count, scalars[index] != "}" {
                    index += 1
                }
                guard index < scalars.count, index > start, index - start <= 8,
                      let parsed = UInt32(String(String.UnicodeScalarView(scalars[start ..< index])), radix: 16)
                else { throw refusal("Invalid Unicode escape.") }
                value = parsed
                index += 1
            } else {
                guard language != .swift, escape != "U" || language == .python,
                      escape != "x" || language == .python || language == .javascript
                else { throw refusal("Unsupported Unicode escape syntax.") }
                value = try hex(scalars, index: &index, count: escape == "U" ? 8 : escape == "x" ? 2 : 4)
                if language == .python, (0xD800 ... 0xDFFF).contains(value) {
                    throw refusal("Python surrogate escapes cannot be represented as a Unicode prompt. Use actual Unicode characters or export for manual integration.")
                }
                if (0xD800 ... 0xDBFF).contains(value) {
                    guard index + 2 <= scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" else { throw refusal("Unpaired Unicode surrogate escape.") }
                    index += 2
                    let low = try hex(scalars, index: &index, count: 4)
                    guard (0xDC00 ... 0xDFFF).contains(low) else { throw refusal("Unpaired Unicode surrogate escape.") }
                    value = 0x10000 + ((value - 0xD800) << 10) + low - 0xDC00
                }
            }
            guard let scalar = UnicodeScalar(value) else { throw refusal("Invalid Unicode scalar in source string.") }
            return scalar
        }

        private static func hex(_ scalars: [UnicodeScalar], index: inout Int, count: Int) throws -> UInt32 {
            guard index + count <= scalars.count,
                  let value = UInt32(String(String.UnicodeScalarView(scalars[index ..< (index + count)])), radix: 16)
            else { throw refusal("Invalid hexadecimal string escape.") }
            index += count
            return value
        }

        private static func swiftMultiline(_ content: String) throws -> String {
            guard content.hasPrefix("\n") else { throw refusal("Swift multiline strings must start on the next line.") }
            let remainder = String(content.dropFirst())
            let lines = remainder.components(separatedBy: "\n")
            let indentation = lines.last ?? ""
            guard indentation.allSatisfy({ $0 == " " || $0 == "\t" }) else { throw refusal("The Swift multiline closing delimiter must be on its own line.") }
            return try lines.dropLast().map { line in
                if line.hasPrefix(indentation) { return String(line.dropFirst(indentation.count)) }
                if line.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
                throw refusal("The Swift multiline string has inconsistent indentation.")
            }.joined(separator: "\n")
        }

        private static func escapeMarkerMatches(_ scalars: [UnicodeScalar], at index: Int, hashes: Int) -> Bool {
            guard index + hashes < scalars.count else { return false }
            return (1 ... max(1, hashes)).allSatisfy { hashes == 0 || scalars[index + $0] == "#" }
        }

        private static func matches(_ expected: [UInt8], _ bytes: [UInt8], _ index: Int) -> Bool {
            index + expected.count <= bytes.count && bytes[index ..< (index + expected.count)].elementsEqual(expected)
        }

        private static func isLetter(_ byte: UInt8) -> Bool {
            (65 ... 90).contains(byte) || (97 ... 122).contains(byte) || byte == 95
        }

        private static func isWhitespace(_ byte: UInt8) -> Bool {
            [9, 10, 13, 32].contains(byte)
        }

        private static func skipComment(_ bytes: [UInt8], from start: Int, nested: Bool) throws -> Int {
            var index = start + 2
            var depth = 1
            while index < bytes.count {
                if matches([42, 47], bytes, index) { depth -= 1
                    index += 2
                    if depth == 0 { return index }
                } else if nested, matches([47, 42], bytes, index) { depth += 1
                    index += 2
                } else { index += 1 }
            }
            throw refusal("The source contains an unterminated comment.")
        }

        private static func likelyRegularExpression(_ bytes: [UInt8], at index: Int) -> Bool {
            guard let previous = bytes[..<index].last(where: { !isWhitespace($0) }) else { return true }
            return [61, 40, 58, 44, 91, 33, 63, 59, 123].contains(previous)
        }

        private static func skipRegularExpression(_ bytes: [UInt8], from start: Int) throws -> Int {
            var index = start + 1
            var inClass = false
            while index < bytes.count, bytes[index] != 10 {
                if bytes[index] == 92 { index += 2
                    continue
                }
                if bytes[index] == 91 { inClass = true }
                else if bytes[index] == 93 { inClass = false }
                else if bytes[index] == 47, !inClass { return index + 1 }
                index += 1
            }
            throw refusal("The JavaScript source contains a regular expression that cannot be located safely.")
        }
    }
#endif
