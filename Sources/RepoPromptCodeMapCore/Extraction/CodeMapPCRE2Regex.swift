//
//  CodeMapPCRE2Regex.swift
//  RepoPrompt
//
//  Thin PCRE2 helpers for developer-authored codemap regex constants.
//

import Foundation
import RepoPromptRegexCore

struct CodeMapPCRE2Match {
    private let captures: [String?]

    init(subject: String, match: PCRE2Match) {
        let utf8 = subject.utf8
        captures = match.captureByteRanges.map { range in
            guard let range else { return nil }
            return Self.substring(in: utf8, byteRange: range)
        }
    }

    private static func substring(in utf8: String.UTF8View, byteRange: Range<Int>) -> String? {
        guard byteRange.lowerBound >= 0, byteRange.upperBound >= byteRange.lowerBound else { return nil }
        guard let lower = utf8.index(utf8.startIndex, offsetBy: byteRange.lowerBound, limitedBy: utf8.endIndex),
              let upper = utf8.index(utf8.startIndex, offsetBy: byteRange.upperBound, limitedBy: utf8.endIndex)
        else {
            return nil
        }
        return String(decoding: utf8[lower ..< upper], as: UTF8.self)
    }

    func capture(_ index: Int) -> String? {
        guard index >= 0, index < captures.count else { return nil }
        return captures[index]
    }

    func trimmedCapture(_ index: Int) -> String? {
        capture(index)?.trimmingCharacters(in: .whitespaces)
    }
}

struct CodeMapPCRE2Pattern {
    private let regex: PCRE2Regex

    init(
        _ pattern: String,
        caseInsensitive: Bool = false,
        multilineAnchors: Bool = false,
        jitMode: PCRE2JITMode? = nil,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        let resolvedJITMode = jitMode ?? RepoPromptRegexRuntime.pcre2JITMode
        var options: PCRE2CompileOptions = [.utf, .unicodeProperties]
        if caseInsensitive {
            options.insert(.caseless)
        }
        if multilineAnchors {
            options.insert(.multiline)
        }

        do {
            regex = try PCRE2Regex(pattern, options: options, jit: resolvedJITMode)
        } catch {
            preconditionFailure("Invalid codemap PCRE2 pattern at \(file):\(line): \(error)")
        }
    }

    func firstMatch(in text: String) -> CodeMapPCRE2Match? {
        guard let match = try? regex.firstMatch(in: text) else { return nil }
        return CodeMapPCRE2Match(subject: text, match: match)
    }

    func firstCapture(_ index: Int = 1, in text: String) -> String? {
        firstMatch(in: text)?.capture(index)
    }

    func trimmedCapture(_ index: Int = 1, in text: String) -> String? {
        firstMatch(in: text)?.trimmedCapture(index)
    }

    func matches(_ text: String) -> Bool {
        (try? regex.firstMatch(in: text)) != nil
    }

    func wholeMatch(in text: String) -> Bool {
        guard let match = try? regex.firstMatch(in: text) else { return false }
        return match.byteRange == 0 ..< text.utf8.count
    }

    func replacingMatches(in text: String, with replacement: String = "") -> String {
        let byteCount = text.utf8.count
        var sourceBytes: [UInt8]? = nil
        var replacementBytes: [UInt8]? = nil
        var output: [UInt8] = []
        var cursor = 0

        do {
            try regex.enumerateMatches(in: text) { match in
                let range = match.byteRange
                guard range.lowerBound >= cursor, range.upperBound <= byteCount else {
                    return true
                }
                if sourceBytes == nil {
                    sourceBytes = Array(text.utf8)
                    replacementBytes = Array(replacement.utf8)
                    output.reserveCapacity(sourceBytes?.count ?? 0)
                }
                guard let sourceBytes, let replacementBytes else { return true }
                output.append(contentsOf: sourceBytes[cursor ..< range.lowerBound])
                output.append(contentsOf: replacementBytes)
                cursor = range.upperBound
                return true
            }
        } catch {
            preconditionFailure("Codemap PCRE2 replacement failed for pattern \(regex.pattern): \(error)")
        }

        guard let sourceBytes else { return text }
        output.append(contentsOf: sourceBytes[cursor...])
        return String(decoding: output, as: UTF8.self)
    }
}
