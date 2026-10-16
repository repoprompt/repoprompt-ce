//
//  TopLevelScanner.swift
//  RepoPrompt
//
//  Shared helpers for scanning and splitting strings at top-level delimiters.
//

import Foundation

enum TopLevelScanner {
    struct TrackDelimiters: OptionSet {
        let rawValue: Int
        static let angle = TrackDelimiters(rawValue: 1 << 0) // < >
        static let paren = TrackDelimiters(rawValue: 1 << 1) // ( )
        static let brace = TrackDelimiters(rawValue: 1 << 2) // { }
        static let square = TrackDelimiters(rawValue: 1 << 3) // [ ]
        static let all: TrackDelimiters = [.angle, .paren, .brace, .square]
    }

    static func splitTopLevel(
        _ input: String,
        separator: Character,
        track: TrackDelimiters = .all
    ) -> [Range<String.Index>] {
        var results: [Range<String.Index>] = []
        var angle = 0
        var paren = 0
        var brace = 0
        var square = 0
        var start = input.startIndex

        for i in input.indices {
            let c = input[i]
            switch c {
            case "<": if track.contains(.angle) { angle += 1 }
            case ">": if track.contains(.angle) { angle = max(0, angle - 1) }
            case "(": if track.contains(.paren) { paren += 1 }
            case ")": if track.contains(.paren) { paren = max(0, paren - 1) }
            case "{": if track.contains(.brace) { brace += 1 }
            case "}": if track.contains(.brace) { brace = max(0, brace - 1) }
            case "[": if track.contains(.square) { square += 1 }
            case "]": if track.contains(.square) { square = max(0, square - 1) }
            case separator:
                if angle == 0, paren == 0, brace == 0, square == 0 {
                    let range = start ..< i
                    if !range.isEmpty { results.append(range) }
                    start = input.index(after: i)
                }
            default:
                break
            }
        }

        let remainder = start ..< input.endIndex
        if !remainder.isEmpty { results.append(remainder) }
        return results
    }

    static func splitTopLevel(
        _ input: String,
        operators: Set<Character>,
        track: TrackDelimiters = .all
    ) -> [Range<String.Index>] {
        var results: [Range<String.Index>] = []
        var angle = 0
        var paren = 0
        var brace = 0
        var square = 0
        var start = input.startIndex

        for i in input.indices {
            let c = input[i]
            switch c {
            case "<": if track.contains(.angle) { angle += 1 }
            case ">": if track.contains(.angle) { angle = max(0, angle - 1) }
            case "(": if track.contains(.paren) { paren += 1 }
            case ")": if track.contains(.paren) { paren = max(0, paren - 1) }
            case "{": if track.contains(.brace) { brace += 1 }
            case "}": if track.contains(.brace) { brace = max(0, brace - 1) }
            case "[": if track.contains(.square) { square += 1 }
            case "]": if track.contains(.square) { square = max(0, square - 1) }
            default: break
            }

            if operators.contains(c), angle == 0, paren == 0, brace == 0, square == 0 {
                let range = start ..< i
                if !range.isEmpty { results.append(range) }
                start = input.index(after: i)
            }
        }

        let remainder = start ..< input.endIndex
        if !remainder.isEmpty { results.append(remainder) }
        return results
    }

    static func firstTopLevelIndex(
        of char: Character,
        in input: String,
        track: TrackDelimiters = .all
    ) -> String.Index? {
        var angle = 0
        var paren = 0
        var brace = 0
        var square = 0

        for (i, c) in input.enumerated() {
            if c == char, angle == 0, paren == 0, brace == 0, square == 0 {
                return input.index(input.startIndex, offsetBy: i)
            }
            switch c {
            case "<": if track.contains(.angle) { angle += 1 }
            case ">": if track.contains(.angle) { angle = max(0, angle - 1) }
            case "(": if track.contains(.paren) { paren += 1 }
            case ")": if track.contains(.paren) { paren = max(0, paren - 1) }
            case "{": if track.contains(.brace) { brace += 1 }
            case "}": if track.contains(.brace) { brace = max(0, brace - 1) }
            case "[": if track.contains(.square) { square += 1 }
            case "]": if track.contains(.square) { square = max(0, square - 1) }
            default:
                break
            }
        }
        return nil
    }

    static func firstTopLevelRange(
        of needle: String,
        in input: String,
        track: TrackDelimiters = .all
    ) -> Range<String.Index>? {
        guard !needle.isEmpty else { return nil }
        let needleChars = Array(needle)
        var angle = 0
        var paren = 0
        var brace = 0
        var square = 0

        var i = input.startIndex
        while i < input.endIndex {
            let c = input[i]
            switch c {
            case "<": if track.contains(.angle) { angle += 1 }
            case ">": if track.contains(.angle) { angle = max(0, angle - 1) }
            case "(": if track.contains(.paren) { paren += 1 }
            case ")": if track.contains(.paren) { paren = max(0, paren - 1) }
            case "{": if track.contains(.brace) { brace += 1 }
            case "}": if track.contains(.brace) { brace = max(0, brace - 1) }
            case "[": if track.contains(.square) { square += 1 }
            case "]": if track.contains(.square) { square = max(0, square - 1) }
            default:
                break
            }
            if angle == 0, paren == 0, brace == 0, square == 0, c == needleChars.first {
                var end = i
                var matched = true
                for idx in 1 ..< needleChars.count {
                    end = input.index(after: end)
                    if end == input.endIndex || input[end] != needleChars[idx] {
                        matched = false
                        break
                    }
                }
                if matched {
                    let upper = input.index(after: end)
                    return i ..< upper
                }
            }
            i = input.index(after: i)
        }
        return nil
    }

    static func containsTopLevel(
        _ needle: String,
        in input: String,
        track: TrackDelimiters = .all
    ) -> Bool {
        firstTopLevelRange(of: needle, in: input, track: track) != nil
    }
}
