import Foundation
import RepoPromptC

/// Owns the C string-runtime boundary for all package targets.
///
/// Callers receive Swift values only; allocation ownership and fallback behavior stay
/// encapsulated here so higher-level targets never import `RepoPromptC` directly.
package enum StringRuntimeUtilities {
    package static func similarityScore(_ lhs: String, _ rhs: String) -> Double {
        lhs.withCString { lhsPointer in
            rhs.withCString { rhsPointer in
                repo_similarity_score(lhsPointer, rhsPointer)
            }
        }
    }

    package static func longestCommonSubsequence(_ lhs: String, _ rhs: String) -> String {
        lhs.withCString { lhsPointer in
            rhs.withCString { rhsPointer in
                takeOwnedCString(
                    repo_longest_common_subsequence(lhsPointer, rhsPointer),
                    fallback: ""
                )
            }
        }
    }

    package static func levenshteinDistance(
        _ lhs: String,
        _ rhs: String,
        maxAllowedDistance: Int = -1
    ) -> Int {
        lhs.withCString { lhsPointer in
            rhs.withCString { rhsPointer in
                Int(repo_levenshtein_distance(lhsPointer, rhsPointer, Int32(maxAllowedDistance)))
            }
        }
    }

    package static func splitPreservingLineEndings(_ content: String) -> ([String], String) {
        content.withCString { contentPointer in
            guard let result = repo_split_content_preserving_endings(contentPointer) else {
                return ([], "\n")
            }
            defer { repo_free_split_result(result) }

            var lines: [String] = []
            lines.reserveCapacity(Int(result.pointee.line_count))
            for index in 0 ..< result.pointee.line_count {
                if let line = result.pointee.lines.advanced(by: Int(index)).pointee {
                    lines.append(String(cString: line))
                }
            }
            let ending = result.pointee.detected_ending != nil
                ? String(cString: result.pointee.detected_ending)
                : "\n"
            return (lines, ending)
        }
    }

    package static func encodeIndentationAsSpaces(_ line: String) -> String {
        line.withCString { pointer in
            takeOwnedCString(repo_encode_indentation(pointer, CChar(115)), fallback: line)
        }
    }

    package static func decodeIndentation(_ encodedLine: String) -> String {
        encodedLine.withCString { pointer in
            takeOwnedCString(repo_decode_indentation(pointer), fallback: encodedLine)
        }
    }

    package static func trimCommonLeadingWhitespacePreservingLineEndings(_ content: String) -> String {
        content.withCString { pointer in
            takeOwnedCString(
                repo_trim_common_leading_whitespace_preserving_endings(pointer),
                fallback: content
            )
        }
    }

    package static func escape(_ value: String) -> String {
        value.withCString { pointer in
            takeOwnedCString(repo_escape_string(pointer), fallback: value)
        }
    }

    package static func unescape(_ value: String) -> String {
        value.withCString { pointer in
            takeOwnedCString(repo_unescape_string(pointer), fallback: value)
        }
    }

    package static func decodeHTMLEntities(_ value: String) -> String {
        value.withCString { pointer in
            takeOwnedCString(repo_decode_html_entities(pointer), fallback: value)
        }
    }

    package static func diceCoefficient(_ lhs: String, _ rhs: String) -> Double {
        lhs.withCString { lhsPointer in
            rhs.withCString { rhsPointer in
                repo_dice_coefficient(lhsPointer, rhsPointer)
            }
        }
    }

    package static func condenseWhitespace(_ value: String) -> String {
        value.withCString { pointer in
            takeOwnedCString(repo_condense_whitespace(pointer), fallback: value)
        }
    }

    package static func fnv1a64(_ value: String) -> UInt64 {
        value.withCString { repo_fnv1a64($0) }
    }

    package static func fuzzySpaceMatch(
        pattern: String,
        text: String,
        caseInsensitive: Bool
    ) -> Bool {
        pattern.withCString { patternPointer in
            text.withCString { textPointer in
                repo_fuzzy_space_match(patternPointer, textPointer, caseInsensitive ? 1 : 0) != 0
            }
        }
    }

    package static func canonicalKey(_ value: String) -> String? {
        value.withCString { pointer in
            guard let result = repo_canonical_key(pointer) else { return nil }
            defer { free(result) }
            return String(cString: result)
        }
    }

    package static func bulkDiceBestMatch(
        pattern: String,
        candidates: [String],
        threshold: Double
    ) -> (index: Int, score: Double)? {
        guard !candidates.isEmpty else { return nil }

        var bestIndex = -1
        var bestScore = 0.0
        pattern.withCString { patternPointer in
            for (index, candidate) in candidates.enumerated() {
                candidate.withCString { candidatePointer in
                    let score = repo_dice_coefficient(patternPointer, candidatePointer)
                    if score >= threshold, score > bestScore {
                        bestScore = score
                        bestIndex = index
                    }
                }
            }
        }
        return bestIndex >= 0 ? (bestIndex, bestScore) : nil
    }

    private static func takeOwnedCString(
        _ pointer: UnsafeMutablePointer<CChar>?,
        fallback: String
    ) -> String {
        guard let pointer else { return fallback }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}

package enum StringLineUtilities {
    package static func splitPreservingLineEndings(_ content: String) -> ([String], String) {
        StringRuntimeUtilities.splitPreservingLineEndings(content)
    }

    package static func splitPreservingAllLineEndings(_ content: String) -> [(line: String, ending: String)] {
        guard !content.isEmpty else { return [] }
        var result: [(String, String)] = []
        result.reserveCapacity(32)
        let scalars = content.unicodeScalars
        var lineStart = scalars.startIndex
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\r" {
                let line = String(scalars[lineStart ..< index])
                let next = scalars.index(after: index)
                if next < scalars.endIndex, scalars[next] == "\n" {
                    result.append((line, "\r\n"))
                    index = scalars.index(after: next)
                } else {
                    result.append((line, "\r"))
                    index = next
                }
                lineStart = index
            } else if scalar == "\n" {
                result.append((String(scalars[lineStart ..< index]), "\n"))
                index = scalars.index(after: index)
                lineStart = index
            } else {
                index = scalars.index(after: index)
            }
        }
        if lineStart < scalars.endIndex {
            result.append((String(scalars[lineStart...]), ""))
        }
        return result
    }

    package static func fnv1a64(_ value: String) -> UInt64 {
        StringRuntimeUtilities.fnv1a64(value)
    }
}
