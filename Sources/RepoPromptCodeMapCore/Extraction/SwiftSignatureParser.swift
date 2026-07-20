//
//  SwiftSignatureParser.swift
//  RepoPrompt
//
//  Lightweight Swift signature parsing helpers.
//

import Foundation

enum SwiftSignatureParser {
    static func extractReturnType(from signature: String) -> String? {
        let trimmed = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let arrowRange = TopLevelScanner.firstTopLevelRange(of: "->", in: trimmed, track: .all) else {
            return nil
        }
        var tail = String(trimmed[arrowRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return nil }
        if let whereRange = topLevelKeywordRange("where", in: tail) {
            tail = String(tail[..<whereRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return tail.isEmpty ? nil : tail
    }

    private static func topLevelKeywordRange(_ keyword: String, in input: String) -> Range<String.Index>? {
        var searchStart = input.startIndex
        while searchStart < input.endIndex {
            let slice = String(input[searchStart...])
            guard let rangeInSlice = TopLevelScanner.firstTopLevelRange(of: keyword, in: slice, track: .all) else {
                return nil
            }
            let lowerOffset = slice.distance(from: slice.startIndex, to: rangeInSlice.lowerBound)
            let upperOffset = slice.distance(from: slice.startIndex, to: rangeInSlice.upperBound)
            let lower = input.index(searchStart, offsetBy: lowerOffset)
            let upper = input.index(searchStart, offsetBy: upperOffset)
            let range = lower ..< upper
            if isWordBoundary(range, in: input) {
                return range
            }
            searchStart = upper
        }
        return nil
    }

    private static func isWordBoundary(_ range: Range<String.Index>, in input: String) -> Bool {
        if range.lowerBound > input.startIndex {
            let before = input[input.index(before: range.lowerBound)]
            if before.isLetter || before.isNumber || before == "_" {
                return false
            }
        }
        if range.upperBound < input.endIndex {
            let after = input[range.upperBound]
            if after.isLetter || after.isNumber || after == "_" {
                return false
            }
        }
        return true
    }
}
