//
//  JSTSSignatureExtractor.swift
//  RepoPrompt
//
//  Created by Claude on 2026-01-29.
//

import Foundation

/// Context for JS/TS signature extraction - determines how braces are interpreted
enum JSTSSignatureContext {
    /// Function-like declarations (function, method, arrow function)
    /// Cuts at the body `{` when it can be distinguished from type literals.
    /// Typed return functions may retain `{` in the signature.
    case functionLike

    /// Statement-like declarations (const, let, var, type alias)
    /// Does NOT treat `{` as a body delimiter - uses `;` or end of line
    case statementLike
}

/// Extracts clean signatures from JS/TS declarations.
/// Handles type literals, generics, and arrow functions correctly.
enum JSTSSignatureExtractor {
    /// Extracts a signature from a single line based on the context.
    ///
    /// - Parameters:
    ///   - line: The declaration line to extract from
    ///   - context: Whether this is a function-like or statement-like declaration
    /// - Returns: The extracted signature
    static func extract(
        from line: String,
        context: JSTSSignatureContext,
        perfStats: CodeMapPerformanceCollector? = nil,
        perfOptions: CodeMapPerfOptions = .disabled
    ) -> String {
        if perfOptions.collectCounters {
            switch context {
            case .functionLike:
                perfStats?.jstsSignatureCallsFunctionLike += 1
            case .statementLike:
                perfStats?.jstsSignatureCallsStatementLike += 1
            }
        }
        let start = perfOptions.enabled ? CFAbsoluteTimeGetCurrent() : 0
        let result: String = switch context {
        case .functionLike:
            extractFunctionSignature(line)
        case .statementLike:
            extractStatementSignature(line)
        }
        let normalized = normalizeSingleLine(result)
        if perfOptions.enabled {
            perfStats?.jstsSignatureDuration += (CFAbsoluteTimeGetCurrent() - start)
        }
        return normalized
    }

    // MARK: - Function-like extraction

    /// Extracts a function signature, cutting at the body `{` when it can be distinguished from type literals.
    ///
    /// Rules:
    /// 1. If contains top-level `=>`, return up to and including `=>`
    /// 2. Find the last `)` of the parameter list
    /// 3. If there's a `:` after that (return type annotation), scan through it
    /// 4. The body brace is the first `{` that's NOT inside the return type annotation
    /// 5. Cut before the body brace
    private static func extractFunctionSignature(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.contains("=>"), !line.contains("{") {
            return stripTrailingSemicolon(trimmed)
        }
        var angleDepth = 0 // Track < > nesting
        var parenDepth = 0 // Track ( ) nesting
        var bracketDepth = 0 // Track [ ] nesting
        var braceDepth = 0 // Track { } nesting (for type literals in return type)

        var lastTopLevelCloseParen: String.Index? = nil
        var arrowIndex: String.Index? = nil
        var firstArrowAnyDepth: String.Index? = nil
        var colonAfterParamIndex: String.Index? = nil
        var bodyBraceIndex: String.Index? = nil
        var inReturnType = false
        var returnTypeStartsWithBrace: Bool? = nil
        var hasTopLevelAssignment = false

        var inSingleQuote = false
        var inDoubleQuote = false
        var inTemplateString = false
        var inLineComment = false
        var inBlockComment = false
        var escapeNext = false

        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            let nextIdx = line.index(after: i)
            let next = nextIdx < line.endIndex ? line[nextIdx] : nil

            if inLineComment {
                if ch == "\n" {
                    inLineComment = false
                }
                i = line.index(after: i)
                continue
            }

            if inBlockComment {
                if ch == "*", next == "/" {
                    inBlockComment = false
                    i = line.index(after: nextIdx)
                    continue
                }
                i = line.index(after: i)
                continue
            }

            if inSingleQuote || inDoubleQuote || inTemplateString {
                if escapeNext {
                    escapeNext = false
                    i = line.index(after: i)
                    continue
                }
                if ch == "\\" {
                    escapeNext = true
                    i = line.index(after: i)
                    continue
                }
                if inSingleQuote, ch == "'" {
                    inSingleQuote = false
                } else if inDoubleQuote, ch == "\"" {
                    inDoubleQuote = false
                } else if inTemplateString, ch == "`" {
                    inTemplateString = false
                }
                i = line.index(after: i)
                continue
            }

            if ch == "/", next == "/" {
                inLineComment = true
                i = line.index(after: nextIdx)
                continue
            }
            if ch == "/", next == "*" {
                inBlockComment = true
                i = line.index(after: nextIdx)
                continue
            }
            if ch == "'" {
                inSingleQuote = true
                i = line.index(after: i)
                continue
            }
            if ch == "\"" {
                inDoubleQuote = true
                i = line.index(after: i)
                continue
            }
            if ch == "`" {
                inTemplateString = true
                i = line.index(after: i)
                continue
            }

            switch ch {
            case "<":
                angleDepth += 1
            case ">":
                if angleDepth > 0 { angleDepth -= 1 }
            case "(":
                parenDepth += 1
            case ")":
                if parenDepth > 0 {
                    parenDepth -= 1
                    if parenDepth == 0, angleDepth == 0, bracketDepth == 0, braceDepth == 0 {
                        lastTopLevelCloseParen = i
                        inReturnType = false // Reset - will check for : next
                        returnTypeStartsWithBrace = nil
                    }
                }
            case "[":
                bracketDepth += 1
            case "]":
                if bracketDepth > 0 { bracketDepth -= 1 }
            case "{":
                let isTopLevel = (parenDepth == 0 && angleDepth == 0 && bracketDepth == 0 && braceDepth == 0)
                if inReturnType {
                    if returnTypeStartsWithBrace == nil {
                        if isTopLevel {
                            returnTypeStartsWithBrace = true
                            braceDepth = max(braceDepth, 1)
                        } else {
                            braceDepth += 1
                        }
                    } else if returnTypeStartsWithBrace == false, isTopLevel {
                        if bodyBraceIndex == nil {
                            bodyBraceIndex = i
                        }
                    } else {
                        braceDepth += 1
                    }
                } else if isTopLevel {
                    if bodyBraceIndex == nil {
                        bodyBraceIndex = i
                    }
                } else {
                    braceDepth += 1
                }
            case "}":
                if braceDepth > 0 {
                    braceDepth -= 1
                    if inReturnType, braceDepth == 0, returnTypeStartsWithBrace == true {
                        inReturnType = false
                    }
                }
            case ":":
                if let closeP = lastTopLevelCloseParen,
                   i > closeP,
                   colonAfterParamIndex == nil,
                   parenDepth == 0, angleDepth == 0, bracketDepth == 0, braceDepth == 0
                {
                    colonAfterParamIndex = i
                    inReturnType = true
                    returnTypeStartsWithBrace = nil
                }
            case "=":
                if let nextChar = next, nextChar == ">" {
                    if firstArrowAnyDepth == nil {
                        firstArrowAnyDepth = nextIdx
                    }
                    if parenDepth == 0, angleDepth == 0, bracketDepth == 0, braceDepth == 0 {
                        arrowIndex = nextIdx
                    }
                } else if parenDepth == 0, angleDepth == 0, bracketDepth == 0, braceDepth == 0 {
                    hasTopLevelAssignment = true
                }
            default:
                break
            }

            if inReturnType, returnTypeStartsWithBrace == nil, ch.isWhitespace == false {
                if ch == "{" {
                    returnTypeStartsWithBrace = true
                    braceDepth = max(braceDepth, 1)
                } else {
                    returnTypeStartsWithBrace = false
                }
            }

            i = line.index(after: i)
        }

        // Rule 1: If contains =>, return up to and including =>
        if let arrow = arrowIndex {
            return String(line[...arrow]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if hasTopLevelAssignment, let arrow = firstArrowAnyDepth {
            return String(line[...arrow]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Rule 2-5: Cut at body brace if found
        if let brace = bodyBraceIndex {
            return String(line[..<brace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Fallback: cut at semicolon if present
        if let semi = line.firstIndex(of: ";") {
            return String(line[..<semi]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return stripTrailingSemicolon(trimmed)
    }

    // MARK: - Statement-like extraction

    /// Extracts a statement signature (const, let, var, type alias).
    /// Does NOT treat `{` as a body delimiter.
    ///
    /// Rules:
    /// 1. Return text up to the first top-level `;` (if present)
    /// 2. Otherwise return the trimmed line
    private static func extractStatementSignature(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.contains(";") {
            return trimmed
        }
        var angleDepth = 0
        var parenDepth = 0
        var bracketDepth = 0
        var braceDepth = 0

        var inSingleQuote = false
        var inDoubleQuote = false
        var inTemplateString = false
        var inLineComment = false
        var inBlockComment = false
        var escapeNext = false

        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            let nextIdx = line.index(after: i)
            let next = nextIdx < line.endIndex ? line[nextIdx] : nil

            if inLineComment {
                if ch == "\n" {
                    inLineComment = false
                }
                i = line.index(after: i)
                continue
            }

            if inBlockComment {
                if ch == "*", next == "/" {
                    inBlockComment = false
                    i = line.index(after: nextIdx)
                    continue
                }
                i = line.index(after: i)
                continue
            }

            if inSingleQuote || inDoubleQuote || inTemplateString {
                if escapeNext {
                    escapeNext = false
                    i = line.index(after: i)
                    continue
                }
                if ch == "\\" {
                    escapeNext = true
                    i = line.index(after: i)
                    continue
                }
                if inSingleQuote, ch == "'" {
                    inSingleQuote = false
                } else if inDoubleQuote, ch == "\"" {
                    inDoubleQuote = false
                } else if inTemplateString, ch == "`" {
                    inTemplateString = false
                }
                i = line.index(after: i)
                continue
            }

            if ch == "/", next == "/" {
                inLineComment = true
                i = line.index(after: nextIdx)
                continue
            }
            if ch == "/", next == "*" {
                inBlockComment = true
                i = line.index(after: nextIdx)
                continue
            }
            if ch == "'" {
                inSingleQuote = true
                i = line.index(after: i)
                continue
            }
            if ch == "\"" {
                inDoubleQuote = true
                i = line.index(after: i)
                continue
            }
            if ch == "`" {
                inTemplateString = true
                i = line.index(after: i)
                continue
            }

            switch ch {
            case "<":
                angleDepth += 1
            case ">":
                if angleDepth > 0 { angleDepth -= 1 }
            case "(":
                parenDepth += 1
            case ")":
                if parenDepth > 0 { parenDepth -= 1 }
            case "[":
                bracketDepth += 1
            case "]":
                if bracketDepth > 0 { bracketDepth -= 1 }
            case "{":
                braceDepth += 1
            case "}":
                if braceDepth > 0 { braceDepth -= 1 }
            case ";":
                if angleDepth == 0, parenDepth == 0, bracketDepth == 0, braceDepth == 0 {
                    return String(line[..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            default:
                break
            }

            i = line.index(after: i)
        }

        return stripTrailingSemicolon(trimmed)
    }

    /// Extracts a variable signature by stripping the initializer from const/let/var lines.
    /// Keeps the full line for non-variable statements (e.g. type aliases).
    static func extractVariableSignature(from line: String) -> String {
        let normalized = normalizeSingleLine(line)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("type ") { return trimmed }

        var probe = trimmed
        let prefixes = ["export default ", "export ", "declare "]
        for prefix in prefixes {
            if probe.hasPrefix(prefix) {
                probe = String(probe.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        let isVarDecl = probe.hasPrefix("const ") || probe.hasPrefix("let ") || probe.hasPrefix("var ")
        guard isVarDecl else { return trimmed }

        if let eqIndex = TopLevelScanner.firstTopLevelIndex(of: "=", in: trimmed, track: .all) {
            return String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func normalizeSingleLine(_ line: String) -> String {
        var out = ""
        out.reserveCapacity(line.count)
        var previousWasWhitespace = true
        for ch in line {
            if ch.isWhitespace {
                if !previousWasWhitespace {
                    out.append(" ")
                    previousWasWhitespace = true
                }
            } else {
                out.append(ch)
                previousWasWhitespace = false
            }
        }
        if out.last == " " {
            out.removeLast()
        }
        return stripTrailingSemicolon(out)
    }

    private static func stripTrailingSemicolon(_ line: String) -> String {
        var out = line
        if out.hasSuffix(";") {
            out.removeLast()
            out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }
}
