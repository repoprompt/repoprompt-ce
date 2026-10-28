//
//  REPLInputParser.swift
//  repoprompt-mcp
//
//  Lightweight parsing helpers for the interactive REPL.
//

import Foundation

enum REPLCommandSeparator: Equatable {
    case always // ;
    case onSuccess // &&
}

struct REPLParsedLine: Equatable {
    struct Segment: Equatable {
        let command: String
        let separatorAfter: REPLCommandSeparator?
    }

    let segments: [Segment]
    let outputRedirectPath: String?
    let appendMode: Bool // true for >>, false for >
}

enum REPLInputParser {
    /// Parses a full input line into command segments and optional output redirect.
    ///
    /// Supported:
    /// - Command chaining via `;` and `&&` (outside quotes)
    /// - Output redirect via `> path` (truncate) or `>> path` (append)
    /// - Quoted paths: `> "path with spaces"` or `>> 'path'`
    static func parse(_ line: String) -> REPLParsedLine {
        let (commandLine, redirect, appendMode) = splitRedirect(line)
        let segments = splitSegments(commandLine)
        return REPLParsedLine(segments: segments, outputRedirectPath: redirect, appendMode: appendMode)
    }

    // MARK: - Redirect

    private static func splitRedirect(_ line: String) -> (command: String, redirect: String?, appendMode: Bool) {
        guard let index = lastUnquotedIndex(of: ">", in: line) else {
            return (line, nil, false)
        }

        // Check if this is >> (append) by looking at the character before
        var appendMode = false
        var commandEndIndex = index
        if index > line.startIndex {
            let prevIndex = line.index(before: index)
            if line[prevIndex] == ">" {
                appendMode = true
                commandEndIndex = prevIndex
            }
        }

        let before = line[..<commandEndIndex]
        let after = line[line.index(after: index)...]

        let command = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileSpec = after.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileSpec.isEmpty else { return (line, nil, false) }

        if let quoted = parseQuotedString(fileSpec) {
            return (command, quoted, appendMode)
        }

        // Unquoted: must not contain whitespace
        if fileSpec.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return (line, nil, false)
        }
        return (command, fileSpec, appendMode)
    }

    private static func parseQuotedString(_ s: String) -> String? {
        guard let first = s.first, first == "\"" || first == "'" else { return nil }
        let quote = first

        var escaped = false
        var out = ""
        var idx = s.index(after: s.startIndex)
        while idx < s.endIndex {
            let ch = s[idx]
            if quote == "\"", !escaped, ch == "\\" {
                escaped = true
                idx = s.index(after: idx)
                continue
            }
            if !escaped, ch == quote {
                let rest = s[s.index(after: idx)...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard rest.isEmpty else { return nil }
                return out
            }
            out.append(ch)
            escaped = false
            idx = s.index(after: idx)
        }

        return nil
    }

    // MARK: - Segments

    private static func splitSegments(_ line: String) -> [REPLParsedLine.Segment] {
        var segments: [REPLParsedLine.Segment] = []
        segments.reserveCapacity(4)

        var current = ""
        var inSingle = false
        var inDouble = false
        var escaped = false

        func flush(separatorAfter: REPLCommandSeparator?) {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(.init(command: trimmed, separatorAfter: separatorAfter))
            }
            current.removeAll(keepingCapacity: true)
        }

        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]

            if escaped {
                current.append(ch)
                escaped = false
                idx = line.index(after: idx)
                continue
            }

            if ch == "\\", inDouble {
                escaped = true
                current.append(ch)
                idx = line.index(after: idx)
                continue
            }

            if ch == "'", !inDouble {
                inSingle.toggle()
                current.append(ch)
                idx = line.index(after: idx)
                continue
            }

            if ch == "\"", !inSingle {
                inDouble.toggle()
                current.append(ch)
                idx = line.index(after: idx)
                continue
            }

            if !inSingle, !inDouble {
                if ch == ";" {
                    flush(separatorAfter: .always)
                    idx = line.index(after: idx)
                    continue
                }
                if ch == "&" {
                    let next = line.index(after: idx)
                    if next < line.endIndex, line[next] == "&" {
                        flush(separatorAfter: .onSuccess)
                        idx = line.index(after: next)
                        continue
                    }
                }
            }

            current.append(ch)
            idx = line.index(after: idx)
        }

        flush(separatorAfter: nil)
        return segments
    }

    // MARK: - Scan Helpers

    private static func lastUnquotedIndex(of needle: Character, in line: String) -> String.Index? {
        var inSingle = false
        var inDouble = false
        var escaped = false
        var result: String.Index? = nil

        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]

            if escaped {
                escaped = false
                idx = line.index(after: idx)
                continue
            }

            if inDouble, ch == "\\" {
                escaped = true
                idx = line.index(after: idx)
                continue
            }

            if ch == "'", !inDouble {
                inSingle.toggle()
                idx = line.index(after: idx)
                continue
            }
            if ch == "\"", !inSingle {
                inDouble.toggle()
                idx = line.index(after: idx)
                continue
            }

            if !inSingle, !inDouble, ch == needle {
                result = idx
            }

            idx = line.index(after: idx)
        }

        return result
    }
}
