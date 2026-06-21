//
//  StringExtensions.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2024-07-25.
//

import Darwin
import Foundation
import RepoPromptC

public extension String {
    internal static func truncateModelName(_ text: String, maxLength: Int = 40) -> String {
        if text.count <= maxLength {
            return text
        }

        if let lastSlashIndex = text.lastIndex(of: "/") {
            let trimmedText = String(text[lastSlashIndex...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if trimmedText.count <= maxLength {
                return trimmedText
            }
        }

        let startIndex = text.index(text.endIndex, offsetBy: -maxLength)
        return "…\(text[startIndex...])"
    }

    internal func similarity(to other: String) -> Double {
        similarityFast(to: other)
    }

    /// Fast similarity calculation using hybrid approach
    /// - For strings ≤ 64 chars: optimized Levenshtein with single row
    /// - For longer strings: Dice coefficient (linear time, allocation-free)
    internal func similarityFast(to other: String) -> Double {
        withCString { aPtr in
            other.withCString { bPtr in
                repo_similarity_score(aPtr, bPtr)
            }
        }
    }

    internal func isSimilar(to other: String, threshold: Double) -> Bool {
        let trimmedSelf = trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOther = other.trimmingCharacters(in: .whitespacesAndNewlines)

        // If both strings are empty after trimming, consider them similar
        if trimmedSelf.isEmpty && trimmedOther.isEmpty {
            return true
        }

        // If one string is empty after trimming and the other isn't, they're not similar
        if trimmedSelf.isEmpty || trimmedOther.isEmpty {
            return false
        }

        if trimmedSelf == trimmedOther {
            return true
        }

        // Use the fast similarity function
        return trimmedSelf.similarityFast(to: trimmedOther) >= threshold
    }

    internal func longestCommonSubsequence(with other: String) -> String {
        withCString { aPtr in
            other.withCString { bPtr in
                guard let cRes = repo_longest_common_subsequence(aPtr, bPtr) else {
                    return ""
                }
                defer { free(cRes) }
                return String(cString: cRes)
            }
        }
    }

    /*
     func similarityScore(with other: String) -> Double {
     let lcs = self.longestCommonSubsequence(with: other)
     return Double(2 * lcs.count) / Double(self.count + other.count)
     }
     */

    /// Public, full-distance call (preserves previous API surface).
    /// Falls back to the optimized core without a cap.
    internal func levenshteinDistance(to other: String) -> Int {
        withCString { aPtr in
            other.withCString { bPtr in
                Int(repo_levenshtein_distance(aPtr, bPtr, -1))
            }
        }
    }

    /// Public capped-distance overload. Returns `maxAllowedDistance + 1` when the true
    /// edit distance is guaranteed to exceed the supplied cap (useful for fast threshold checks).
    internal func levenshteinDistance(to other: String, maxAllowedDistance: Int) -> Int {
        withCString { aPtr in
            other.withCString { bPtr in
                Int(repo_levenshtein_distance(aPtr, bPtr, Int32(maxAllowedDistance)))
            }
        }
    }

    internal func splitIntoLines(usesSpaces: Bool, indentSize: Int) -> [String] {
        let (lines, _) = String.splitContentPreservingLineEndings(self)
        return lines.map { line in
            // Since we assume spaces, use encodeIndentationAsSpaces
            String.encodeIndentationAsSpaces(line)
        }
    }

    static func splitContentPreservingLineEndings(_ content: String) -> ([String], String) {
        content.withCString { contentPtr in
            guard let result = repo_split_content_preserving_endings(contentPtr) else {
                return ([], "\n")
            }
            defer { repo_free_split_result(result) }

            // Convert C string array to Swift array
            var lines: [String] = []
            for i in 0 ..< result.pointee.line_count {
                if let linePtr = result.pointee.lines.advanced(by: Int(i)).pointee {
                    lines.append(String(cString: linePtr))
                }
            }

            // Get detected ending
            let detectedEnding = result.pointee.detected_ending != nil
                ? String(cString: result.pointee.detected_ending)
                : "\n"

            return (lines, detectedEnding)
        }
    }

    static func encodeIndentationAsTabs(_ line: String) -> String {
        // Separate the leading whitespace from the rest of the line
        let indentation = line.prefix { $0.isWhitespace }
        let contentStart = line.index(line.startIndex, offsetBy: indentation.count)
        let content = String(line[contentStart...]).trimmingCharacters(in: .whitespaces)

        // Convert mixed indentation (tabs + spaces) to an effective width in *spaces*
        let effectiveSpaces = indentation.reduce(0) { total, ch in
            total + (ch == "\t" ? 4 : 1)
        }

        // Derive the tab count (round up so partial groups of 4 spaces become a full tab)
        let tabCount = effectiveSpaces == 0
            ? 0
            : (effectiveSpaces / 4 + (effectiveSpaces % 4 == 0 ? 0 : 1))

        // Emit the encoded line
        if content.isEmpty {
            return "<t\(tabCount)>"
        } else {
            return "<t\(tabCount)>\(content)"
        }
    }

    static func encodeIndentation(_ line: String, fallbackIndentationType: String = "s") -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let indentation = line.prefix(while: { $0.isWhitespace })

        // Handle empty or whitespace-only lines
        if trimmed.isEmpty {
            if indentation.contains("\t") {
                let tabCount = indentation.count(where: { $0 == "\t" })
                return "<t\(tabCount)>"
            } else {
                let spaceCount = indentation.count
                return "<s\(spaceCount)>"
            }
        }

        if indentation.contains("\t") {
            let tabCount = indentation.count(where: { $0 == "\t" })
            return "<t\(tabCount)>\(trimmed)"
        } else if indentation.isEmpty {
            // Use fallback indentation type if there is zero indentation
            return "<\(fallbackIndentationType)0>\(trimmed)"
        } else {
            let spaceCount = indentation.count
            return "<s\(spaceCount)>\(trimmed)"
        }
    }

    /// Encodes the line’s indentation using the provided desired type.
    /// If the actual indentation doesn’t match the desired type, it converts:
    /// - Tabs → Spaces (4 spaces per tab) when desired type is "s"
    /// - Spaces → Tabs (1 tab per 4 spaces, rounding up) when desired type is "t"
    ///
    /// For empty or whitespace-only lines, only the tag is returned.
    ///
    /// Examples:
    ///   "    foo" encoded as tabs becomes "<t1>foo"
    ///   "\tbar" encoded as spaces becomes "<s4>bar"
    static func encodeIndentationWithConversion(_ line: String, desiredIndentationType: String = "s") -> String {
        // Get the content without leading/trailing whitespace.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Capture the leading whitespace.
        let originalIndentation = line.prefix { $0.isWhitespace }
        // We treat any line containing a tab as tab-indented.
        let isTabBased = originalIndentation.contains("\t")

        /// Helper closure: encode tag using provided type and a count.
        func encodeTag(_ count: Int, content: String = "") -> String {
            "<\(desiredIndentationType)\(count)>" + content
        }

        // If the line is empty or only whitespace, just encode the indentation tag.
        if trimmed.isEmpty {
            if desiredIndentationType == "s" {
                if isTabBased {
                    // Convert each tab to 4 spaces.
                    let tabCount = originalIndentation.count(where: { $0 == "\t" })
                    return encodeTag(tabCount * 4)
                } else {
                    let spaceCount = originalIndentation.count
                    return encodeTag(spaceCount)
                }
            } else if desiredIndentationType == "t" {
                if isTabBased {
                    let tabCount = originalIndentation.count(where: { $0 == "\t" })
                    return encodeTag(tabCount)
                } else {
                    let spaceCount = originalIndentation.count
                    // Convert spaces to tabs: 1 tab per 4 spaces (round up)
                    let tabCount = spaceCount / 4 + (spaceCount % 4 > 0 ? 1 : 0)
                    return encodeTag(tabCount)
                }
            } else {
                // Unknown desired type; simply encode the count.
                return "<\(desiredIndentationType)\(originalIndentation.count)>"
            }
        }

        // For lines with content:
        if desiredIndentationType == "s" {
            if isTabBased {
                let tabCount = originalIndentation.count(where: { $0 == "\t" })
                // Convert each tab to 4 spaces.
                return encodeTag(tabCount * 4, content: trimmed)
            } else {
                let spaceCount = originalIndentation.count
                return encodeTag(spaceCount, content: trimmed)
            }
        } else if desiredIndentationType == "t" {
            if !isTabBased {
                let spaceCount = originalIndentation.count
                // Convert spaces to tabs: 1 tab per 4 spaces (round up)
                let tabCount = spaceCount / 4 + (spaceCount % 4 > 0 ? 1 : 0)
                return encodeTag(tabCount, content: trimmed)
            } else {
                let tabCount = originalIndentation.count(where: { $0 == "\t" })
                return encodeTag(tabCount, content: trimmed)
            }
        } else {
            // Fallback if desiredIndentationType is unknown.
            return "<\(desiredIndentationType)\(originalIndentation.count)>" + trimmed
        }
    }

    static func encodeIndentationAsSpacesPreservingLineEndings(_ text: String) -> String {
        let (lines, lineEnding) = String.splitContentPreservingLineEndings(text)
        let encodedLines = lines.map { String.encodeIndentationAsSpaces($0) }
        return encodedLines.joined(separator: lineEnding)
    }

    static func encodeIndentationAsSpaces(_ line: String) -> String {
        // Split leading whitespace and remainder
        line.withCString { cLine in
            guard let raw = repo_encode_indentation(cLine, CChar(115)) else {
                return line
            }
            defer { free(raw) }
            return String(cString: raw)
        }
    }

    static func decodeIndentation(_ encodedLine: String) -> String {
        let parts = encodedLine.split(separator: ">", maxSplits: 1) // anchor placeholder
        _ = parts // silence unused-var warning
        return encodedLine.withCString { cLine in
            guard let raw = repo_decode_indentation(cLine) else {
                return encodedLine
            }
            defer { free(raw) }
            return String(cString: raw)
        }
    }

    static func decodeIndentationPreservingAllLineEndings(_ content: String) -> String {
        let linesWithEndings = splitContentPreservingAllLineEndings(content)
        let decoded: [String] = linesWithEndings.map { pair in
            let decodedLine = decodeIndentation(pair.line)
            return decodedLine + pair.ending
        }
        return decoded.joined()
    }

    static func trimCommonLeadingWhitespacePreservingLineEndings(_ content: String) -> String {
        content.withCString { ptr in
            guard let raw = repo_trim_common_leading_whitespace_preserving_endings(ptr) else {
                return content
            }
            defer { free(raw) }
            return String(cString: raw)
        }
    }

    /// Extracts the indentation type and count from an encoded indentation string.
    /// For example, given "<t4>some code", it returns ("t", 4).
    static func getIndentationEncoding(from encodedLine: String) -> (type: String, count: Int) {
        // Split the line at the first ">" to isolate the encoding tag.
        let parts = encodedLine.split(separator: ">", maxSplits: 1)
        guard let tag = parts.first, tag.count >= 2 else {
            return ("s", 0)
        }

        // The tag is expected to be in the form "<t4" or "<s20".
        // We extract the character after "<" as the type.
        let typeChar = tag[tag.index(tag.startIndex, offsetBy: 1)]

        // The rest of the tag (after the type) is the indent count.
        let countStr = tag.dropFirst(2)
        let count = Int(countStr) ?? 0

        return (String(typeChar), count)
    }

    /// Given an array of encoded lines, returns the indentation type and size
    /// from the first non-empty decoded line. If none found, defaults to spaces (size 4).
    static func detectIndentationTypeFromEncodedLines(_ lines: [String]) -> (type: String, size: Int) {
        for line in lines {
            let decoded = String.decodeIndentation(line)
            if !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let encoding = String.getIndentationEncoding(from: line)
                return (type: encoding.type, size: encoding.count)
            }
        }
        return ("s", 4)
    }

    static func splitContentPreservingAllLineEndings(_ content: String) -> [(line: String, ending: String)] {
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
                    lineStart = index
                } else {
                    result.append((line, "\r"))
                    index = next
                    lineStart = index
                }
            } else if scalar == "\n" {
                let line = String(scalars[lineStart ..< index])
                result.append((line, "\n"))
                index = scalars.index(after: index)
                lineStart = index
            } else {
                index = scalars.index(after: index)
            }
        }

        if lineStart < scalars.endIndex {
            let remainder = String(scalars[lineStart ..< scalars.endIndex])
            result.append((remainder, ""))
        }

        return result
    }

    static func removeIndentationTag(_ encodedLine: String) -> String {
        // Only split if there’s an actual '>' in the first few characters
        guard encodedLine.hasPrefix("<s") || encodedLine.hasPrefix("<t"),
              let closeIndex = encodedLine.firstIndex(of: ">")
        else {
            return encodedLine
        }

        // Return everything after the '>'
        let nextIndex = encodedLine.index(after: closeIndex)
        return String(encodedLine[nextIndex...])
    }

    static func detectIndentationTypeFromLines(_ lines: [String]) -> (type: String, size: Int) {
        var tabCount = 0
        var spaceCount = 0
        var spaceSizes: [Int] = []

        for line in lines {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            var leadingTabCount = 0
            var leadingSpaceCount = 0

            for char in line {
                if char == "\t" {
                    leadingTabCount += 1
                } else if char == " " {
                    leadingSpaceCount += 1
                } else {
                    break
                }
            }

            if leadingTabCount > 0 {
                tabCount += 1
            } else if leadingSpaceCount > 0 {
                spaceCount += 1
                spaceSizes.append(leadingSpaceCount)
            }
        }

        if tabCount > 0 {
            return ("t", 1)
        } else if spaceCount > 0 {
            // Find the most common space size
            let mostCommonSpaceSize = spaceSizes.reduce(into: [:]) { counts, size in
                counts[size, default: 0] += 1
            }.max(by: { $0.value < $1.value })?.key ?? 4

            return ("s", mostCommonSpaceSize)
        } else {
            // Default to spaces with size 4 if no indentation detected
            return ("s", 4)
        }
    }

    static func detectIndentationType(_ content: String) -> (type: String, size: Int) {
        let (lines, _) = splitContentPreservingLineEndings(content)
        return detectIndentationTypeFromLines(lines)
    }

    internal func ranges(of substring: String, options: String.CompareOptions = []) -> [Range<Index>] {
        var ranges: [Range<Index>] = []
        var startIndex = startIndex

        while startIndex < endIndex,
              let range = range(of: substring, options: options, range: startIndex ..< endIndex)
        {
            ranges.append(range)
            startIndex = range.upperBound
        }

        return ranges
    }

    internal func escapedString() -> String {
        withCString { ptr in
            guard let raw = repo_escape_string(ptr) else { return self }
            defer { free(raw) }
            return String(cString: raw)
        }
    }

    internal func unescaped() -> String {
        withCString { ptr in
            guard let raw = repo_unescape_string(ptr) else { return self }
            defer { free(raw) }
            return String(cString: raw)
        }
    }

    /// Static regex for indentation level extraction
    private static let indentationLevelRegex = try! NSRegularExpression(pattern: "^<([st])(\\d+)>")

    static func getIndentationLevel(from line: String) -> Int {
        guard let match = indentationLevelRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let countRange = Range(match.range(at: 2), in: line)
        else {
            return 0
        }
        return Int(line[countRange]) ?? 0
    }

    /// Static regex for applying indentation delta
    private static let indentationDeltaRegex = try! NSRegularExpression(pattern: "^<([st])(\\d+)>(.*)$")

    /// Apply a delta to the indentation level of a line. If no tag is found, assume `<s0>`.
    static func applyIndentationDelta(to line: String, delta: Int) -> String {
        guard let match = indentationDeltaRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            let newIndent = Swift.max(0, delta)
            return "<s\(newIndent)>\(line)"
        }

        let indentType = (line as NSString).substring(with: match.range(at: 1))
        let countStr = (line as NSString).substring(with: match.range(at: 2))
        let content = (line as NSString).substring(with: match.range(at: 3))

        let oldCount = Int(countStr) ?? 0
        let newCount = Swift.max(0, oldCount + delta)
        return "<\(indentType)\(newCount)>\(content)"
    }

    /// Computes the most frequent indentation delta between two blocks.
    /// This looks at corresponding non-empty lines (by trimming content)
    /// and returns the mode of (targetIndent - sourceIndent).
    ///
    /// If either line is empty (or effectively empty) we skip it.
    static func computeIndentationDeltaForBlocks(_ source: [String], _ target: [String]) -> Int {
        guard !source.isEmpty, !target.isEmpty else { return 0 }

        var deltas: [Int: Int] = [:]

        let sourceCount = source.count
        let targetCount = target.count
        let count = Swift.min(sourceCount, targetCount)

        for i in 0 ..< count {
            // Get the actual content by removing the indentation tag and trim whitespace
            let sourceContent = String.removeIndentationTag(source[i]).trimmingCharacters(in: .whitespaces)
            let targetContent = String.removeIndentationTag(target[i]).trimmingCharacters(in: .whitespaces)

            // Skip if either line has no actual content after trimming
            guard !sourceContent.isEmpty, !targetContent.isEmpty else { continue }

            let sourceIndent = String.getIndentationLevel(from: source[i])
            let targetIndent = String.getIndentationLevel(from: target[i])
            let delta = sourceIndent - targetIndent

            deltas[delta, default: 0] += 1
        }

        // Find the delta with the highest frequency
        return deltas.max(by: { $0.value < $1.value })?.key ?? 0
    }

    /// Applies the given indentation delta to each line in the block,
    /// preserving the same tag type (<s or <t>) as found in the line.
    /// If no tag is found, defaults to `<s0>` style plus delta (or zero if negative).
    static func applyIndentationDeltaToBlock(_ lines: [String], _ delta: Int) -> [String] {
        lines.map { line in
            String.applyIndentationDelta(to: line, delta: delta)
        }
    }

    /// If snippet uses tabs and file uses spaces (or vice versa), convert.
    static func matchIndentation(_ line: String, snippetIndentType: String, fileIndentType: String) -> String {
        if snippetIndentType == "t", fileIndentType == "s" {
            return String.convertTabsToSpaces(line)
        } else if snippetIndentType == "s", fileIndentType == "t" {
            return String.convertSpacesToTabs(line)
        }
        return line
    }

    /// Convert a line containing tabs to the same line with spaces (4 spaces per tab).
    static func convertTabsToSpaces(_ line: String) -> String {
        // Decode existing indentation tags (e.g. <t4>, <s8>) so we get actual tabs/spaces in the string
        let decoded = String.decodeIndentation(line)
        // Replace all tab characters with 4 spaces
        let replaced = decoded.replacingOccurrences(of: "\t", with: String(repeating: " ", count: 4))
        // Re-encode the indentation as <sX>
        return String.encodeIndentationAsSpacesPreservingLineEndings(replaced)
    }

    /// Convert a line containing spaces (groups of 4) to the same line with tabs (1 tab per 4 spaces).
    static func convertSpacesToTabs(_ line: String) -> String {
        let decoded = String.decodeIndentation(line)
        let fourSpaces = String(repeating: " ", count: 4)
        let replaced = decoded.replacingOccurrences(of: fourSpaces, with: "\t")
        return String.encodeIndentationAsTabs(replaced)
    }

    /// Computes a "two-stage" indentation delta between the `source` block and `snippet` block:
    /// 1) `topLineDelta` for line 0
    /// 2) `blockDelta` for lines [1..N].
    ///
    /// If `snippet` has only one line, we apply a single uniform delta to all lines
    /// by making `blockDelta` = `topLineDelta`.
    static func computeTwoStageIndentationDelta(
        source: [String],
        snippet: [String]
    ) -> (topLineDelta: Int, blockDelta: Int) {
        guard !source.isEmpty, !snippet.isEmpty else {
            return (0, 0)
        }

        // 1) Compare the first line's indentation
        let firstSourceIndent = getIndentationLevel(from: source[0])
        let firstSnippetIndent = getIndentationLevel(from: snippet[0])
        let topLineDelta = firstSourceIndent - firstSnippetIndent

        // If there's only one line in snippet, we unify the delta for all lines.
        if snippet.count == 1 {
            // We'll apply the same shift (topLineDelta) to the entire new content.
            return (topLineDelta, topLineDelta)
        }

        // Otherwise, do the normal multi-line logic.

        // 2) Apply that topLineDelta to snippet’s first line, so we can measure the block delta fairly.
        var adjustedSnippet = snippet
        if topLineDelta != 0 {
            adjustedSnippet[0] = applyIndentationDelta(to: adjustedSnippet[0], delta: topLineDelta)
        }

        // 3) Now compute the blockDelta for lines [1..N] using the standard function.
        let blockDelta = computeIndentationDeltaForBlocks(source, adjustedSnippet)
        return (topLineDelta, blockDelta)
    }

    /// Applies a "two-stage" indentation delta to a block of lines:
    ///  - `topLineDelta` to line 0
    ///  - `blockDelta` to lines [1..N]
    /// If during application we detect that lines with different original indentation
    /// have collapsed to the same indentation, we short-circuit and skip all adjustment.
    static func applyTwoStageIndentationDeltaToBlock(
        _ lines: [String],
        topLineDelta: Int,
        blockDelta: Int
    ) -> [String] {
        guard !lines.isEmpty else { return lines }

        // First, figure out the min and max indentation in the original lines.
        // If they're the same, no real "relative" indentation to worry about.
        let originalIndents = lines.map { getIndentationLevel(from: $0) }
        let origMinIndent = originalIndents.min() ?? 0
        let origMaxIndent = originalIndents.max() ?? 0
        let hasMultipleIndents = (origMaxIndent > origMinIndent)

        var result = lines
        var adjustedIndents: [Int] = []
        adjustedIndents.reserveCapacity(result.count)

        // Stage 1) Apply topLineDelta to the first line
        if topLineDelta != 0 {
            result[0] = applyIndentationDelta(to: result[0], delta: topLineDelta)
        }

        // Collect indentation for the first line
        adjustedIndents.append(getIndentationLevel(from: result[0]))

        // Stage 2) Apply blockDelta to the rest
        if blockDelta != 0 {
            for i in 1 ..< result.count {
                let originalIndent = getIndentationLevel(from: result[i])
                result[i] = applyIndentationDelta(to: result[i], delta: blockDelta)

                let newIndent = getIndentationLevel(from: result[i])
                adjustedIndents.append(newIndent)

                // If the original block had multiple distinct indent levels
                // and we see that two lines that used to differ have collapsed,
                // short-circuit out (remove all adjustments).
                if hasMultipleIndents {
                    // Compare this line's new indentation to the line before it
                    // or (optionally) keep track of min/max and check if everything collapses.

                    // Example "immediate" check: if the previous line's original indent differs
                    // but the new indent is the same. This is a quick local check.
                    let prevOriginalIndent = getIndentationLevel(from: lines[i - 1])

                    if originalIndent != prevOriginalIndent, newIndent == adjustedIndents[i - 1] {
                        // We have a collapse from distinct to same => short-circuit
                        return lines // Return the original, unmodified array
                    }
                }
            }
        } else {
            // If blockDelta == 0, just push the original indent levels
            for i in 1 ..< result.count {
                adjustedIndents.append(getIndentationLevel(from: result[i]))
            }
        }

        // Optional: a global min/max compression check (for large blocks) instead of local pairwise checks:
        /*
         if hasMultipleIndents {
         let newMin = adjustedIndents.min() ?? 0
         let newMax = adjustedIndents.max() ?? 0
         // if the original had a difference, but the new is all one level
         if newMax == newMin && origMaxIndent > origMinIndent {
         // short-circuit => revert to original lines
         return lines
         }
         }
         */

        return result
    }

    /// Compute the median of a list of doubles
    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.0 }
        let sortedVals = values.sorted()
        let mid = sortedVals.count / 2
        if sortedVals.count % 2 == 0 {
            return (sortedVals[mid - 1] + sortedVals[mid]) / 2.0
        } else {
            return sortedVals[mid]
        }
    }

    /**
     Returns true if the `original` snippet had at least 2 distinct indentation levels,
     but the `transformed` snippet has only 1 or fewer.
     This indicates that the transform effectively flattened multi-level indentation.
     */
    static func snippetCollapsedMultiLevels(
        original: [String],
        transformed: [String]
    ) -> Bool {
        let originalIndents = original.map { getIndentationLevel(from: $0) }
        let transformedIndents = transformed.map { getIndentationLevel(from: $0) }

        let originalDistinct = Set(originalIndents).count
        let transformedDistinct = Set(transformedIndents).count

        // If the original had multiple levels (≥2)
        // but the transformed snippet is now 1 or 0 levels, we've collapsed.
        return originalDistinct >= 2 && transformedDistinct <= 1
    }

    /// Attempts to find the "closest" matching path from a list of allowed paths,
    /// using several checks in order of priority:
    ///  1) Direct exact match
    ///  2) Case-insensitive match (ignoring leading/trailing whitespace)
    ///  3) Trailing component match (reverse path segments)
    ///  4) Fuzzy similarity using `String.similarity(to:)` with a tight threshold (e.g., 0.9)
    ///
    /// Returns nil if nothing meets that threshold.
    static func findClosestPath(_ requested: String, among allowed: [String]) -> String? {
        // 1) Direct exact match
        if allowed.contains(requested) {
            return requested
        }

        let trimmedReq = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let reqLower = trimmedReq.lowercased()

        // 2) Case-insensitive match
        for candidate in allowed {
            if candidate.lowercased() == reqLower {
                return candidate
            }
        }

        func isSubsequence(_ needle: [String], in haystack: [String]) -> Bool {
            guard !needle.isEmpty else { return true }
            var matchIndex = 0
            for component in haystack {
                if component == needle[matchIndex] {
                    matchIndex += 1
                    if matchIndex == needle.count {
                        return true
                    }
                }
            }
            return false
        }

        // 3) Trailing path-component match
        let reqComponents = trimmedReq.split(separator: "/").map { $0.lowercased() }
        var bestTrailingPathMatch: String?
        var bestTrailingCount = 0

        for candidate in allowed {
            let candComponents = candidate.split(separator: "/").map { $0.lowercased() }

            let reversedPairs = zip(reqComponents.reversed(), candComponents.reversed())
            let matchCount = reversedPairs.prefix(while: { $0.0 == $0.1 }).count

            if matchCount > bestTrailingCount {
                bestTrailingCount = matchCount
                bestTrailingPathMatch = candidate
            }
        }

        // Require at least min(3, numberOfRequestedComponents) trailing components to match
        let trailingThreshold = Swift.min(reqComponents.count, 3)
        if bestTrailingCount >= trailingThreshold, let match = bestTrailingPathMatch {
            return match
        }

        // 3b) Ordered subsequence fallback
        var bestSubsequenceMatch: (path: String, length: Int)?
        for candidate in allowed {
            let candComponents = candidate.split(separator: "/").map { $0.lowercased() }
            guard isSubsequence(reqComponents, in: candComponents) else { continue }
            if bestSubsequenceMatch == nil || candComponents.count < bestSubsequenceMatch!.length {
                bestSubsequenceMatch = (candidate, candComponents.count)
            }
        }
        if let match = bestSubsequenceMatch?.path {
            return match
        }

        // 4) Fuzzy similarity check with a threshold
        var bestCandidate: String?
        var bestSimilarity = 0.0
        let threshold = 0.90 // tight threshold

        for candidate in allowed {
            let score = trimmedReq.similarity(to: candidate)
            if score > bestSimilarity {
                bestSimilarity = score
                bestCandidate = candidate
            }
        }

        if let final = bestCandidate, bestSimilarity >= threshold {
            return final
        }

        return nil
    }

    /// Decodes common HTML entities like <, >, &, etc.
    internal func decodingHTMLEntities() -> String {
        withCString { ptr in
            guard let raw = repo_decode_html_entities(ptr) else { return self }
            defer { free(raw) }
            return String(cString: raw)
        }
    }

    internal func oldDecodingHTMLEntities() -> String {
        guard let data = data(using: .utf8) else {
            return self
        }

        guard let decoded = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ) else {
            return self
        }

        return decoded.string
    }

    /*
     // ------------------------------------------------------------------
     // MARK: –  Lightweight fuzzy-matching helpers
     // ------------------------------------------------------------------
     /// Sørensen–Dice coefficient on bi-grams (linear time, allocation-light).
     /// Returns 1.0 for identical strings, 0.0 for no overlap.
     func diceCoefficient(against other: String) -> Double {
     	let lhs = self.lowercased()
     	let rhs = other.lowercased()
     	guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
     	if lhs == rhs { return 1 }

     	func bigrams(_ s: String) -> Set<String> {
     		if s.count < 2 { return [s] }
     		var result = Set<String>()
     		var i = s.startIndex
     		var j = s.index(after: i)
     		while j < s.endIndex {
     			result.insert(String(s[i...j]))
     			i = j
     			j = s.index(after: j)
     		}
     		return result
     	}
     	let setA = bigrams(lhs)
     	let setB = bigrams(rhs)
     	let inter = setA.intersection(setB).count
     	return (2.0 * Double(inter)) / Double(setA.count + setB.count)
     }
     */

    internal func diceCoefficient(against other: String) -> Double {
        diceCoefficientFast(self, other)
    }

    internal func isFuzzyMatch(to other: String, threshold: Double = 0.65) -> Bool {
        if range(of: other, options: .caseInsensitive) != nil { return true }
        if abs(count - other.count) > 6 { return false }
        return diceCoefficientFast(self, other) >= threshold
    }

    // MARK: – Allocation‑free Dice coefficient ------------------------------------

    @inline(__always)
    internal func diceCoefficientFast(_ a: String, _ b: String) -> Double {
        a.withCString { aPtr in
            b.withCString { bPtr in
                repo_dice_coefficient(aPtr, bPtr)
            }
        }
    }

    /// Returns a copy where every *run* of space / tab / line-break / NBSP
    /// characters is collapsed to a single plain space (U+0020).
    ///
    /// This keeps the algorithm deterministic while avoiding the cost of
    /// `NSRegularExpression` – it's a straightforward linear scan.
    @inline(__always)
    internal func condensingWhitespace() -> String {
        withCString { ptr in
            guard let raw = repo_condense_whitespace(ptr) else { return self }
            defer { free(raw) }
            return String(cString: raw)
        }
    }

    /// 64‑bit FNV‑1a (mirrors the helper in DiffGenerationUtility)
    @inline(__always)
    internal func fnv1a64() -> UInt64 {
        withCString { ptr in
            repo_fnv1a64(ptr)
        }
    }

    /// Fuzzy space matching - spaces in pattern match any amount of whitespace in text
    @inline(__always)
    internal func fuzzySpaceMatch(_ text: String, caseInsensitive: Bool = false) -> Bool {
        withCString { patternPtr in
            text.withCString { textPtr in
                repo_fuzzy_space_match(patternPtr, textPtr, caseInsensitive ? 1 : 0) != 0
            }
        }
    }

    /// Generates a canonical key for string comparison
    @inline(__always)
    internal static func canonicalKey(_ raw: String) -> String? {
        raw.withCString { ptr in
            guard let result = repo_canonical_key(ptr) else { return nil }
            defer { free(result) }
            return String(cString: result)
        }
    }

    /// Finds the best dice coefficient match among candidates
    @inline(__always)
    internal static func bulkDiceBestMatch(pattern: String, candidates: [String], threshold: Double) -> (index: Int, score: Double)? {
        guard !candidates.isEmpty else { return nil }

        // For now, use a simple approach that keeps strings alive
        var bestIdx = -1
        var bestScore = 0.0

        pattern.withCString { patternPtr in
            for (idx, candidate) in candidates.enumerated() {
                candidate.withCString { candidatePtr in
                    let score = repo_dice_coefficient(patternPtr, candidatePtr)
                    if score >= threshold, score > bestScore {
                        bestScore = score
                        bestIdx = idx
                    }
                }
            }
        }

        return bestIdx >= 0 ? (bestIdx, bestScore) : nil
    }

    // MARK: - Encoded indentation sanitizer

    /// Matches lines like ^<s8>foo or ^<t2>bar and captures: kind ("s" or "t"), count, and content.
    private static let encodedIndentRegex: NSRegularExpression = try! NSRegularExpression(pattern: #"^<([st])(\d+)>(.*)$"#)

    /// Promote *leading* escaped tab sequences in an encoded line.
    /// Operates only on the content portion after the <sN>/<tN> prefix. Idempotent.
    ///
    /// Examples:
    ///   "<s0>\\t\\tfoo"  → "<s8>foo"    (4-space tab stop)
    ///   "<t1>\\tbar"     → "<t2>bar"
    ///   "<s4>\\u0009baz" → "<s8>baz"
    static func promoteEscapedTabsInEncodedLine(_ line: String, spacesTabStop: Int = 4, enabled: Bool = true) -> String {
        guard enabled else { return line }
        guard
            let match = encodedIndentRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        else {
            return line
        }

        let ns = line as NSString
        let indentType = ns.substring(with: match.range(at: 1)) // "s" or "t"
        var count = Int(ns.substring(with: match.range(at: 2))) ?? 0
        var content = ns.substring(with: match.range(at: 3))

        var changed = false
        while content.hasPrefix("\\t") || content.hasPrefix("\\u0009") {
            if content.hasPrefix("\\t") {
                content.removeFirst(2) // remove "\t" (two chars: backslash + t)
            } else {
                content.removeFirst(6) // remove "\u0009"
            }
            changed = true
            count += (indentType == "s") ? spacesTabStop : 1
        }

        return changed ? "<\(indentType)\(count)>\(content)" : line
    }

    /// Vectorized promotion over a block of encoded lines (idempotent).
    static func promoteEscapedTabsInEncodedLines(_ lines: [String], spacesTabStop: Int = 4, enabled: Bool = true) -> [String] {
        guard enabled else { return lines }
        return lines.map { promoteEscapedTabsInEncodedLine($0, spacesTabStop: spacesTabStop, enabled: enabled) }
    }

    // MARK: - Context detection

    private static let latexLikeExtensions: Set<String> = [
        "tex", "ltx", "sty", "cls", "bib", "dtx", "ins"
    ]

    /// Returns false for TeX/LaTeX paths (and for strong LaTeX markers in content).
    static func shouldPromoteLeadingEscapedTabs(
        path: String,
        searchRaw: String? = nil,
        replaceRaw: String? = nil
    ) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if latexLikeExtensions.contains(ext) { return false }

        func hasLaTeXMarkers(_ s: String) -> Bool {
            s.contains("\\documentclass")
                || s.contains("\\usepackage")
                || s.contains("\\begin{")
                || s.contains("\\end{")
        }

        if let s = searchRaw, hasLaTeXMarkers(s) { return false }
        if let r = replaceRaw, hasLaTeXMarkers(r) { return false }

        return true
    }

    /// Scan for encoded lines whose *content* still begins with a literal "\t" or "\u0009".
    /// Useful for diagnostics/logging. Returns zero-based indices.
    static func findLinesWithLeadingEscapedTabs(_ lines: [String]) -> [Int] {
        var bad: [Int] = []
        for (i, line) in lines.enumerated() {
            guard
                let m = encodedIndentRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
            else { continue }
            let ns = line as NSString
            let content = ns.substring(with: m.range(at: 3))
            if content.hasPrefix("\\t") || content.hasPrefix("\\u0009") {
                bad.append(i)
            }
        }
        return bad
    }

    /// Returns a substring starting at `offset` (character-based) and,
    /// if `length` is supplied, spanning at most that many characters.
    /// All indices are clipped safely – never crashes on out-of-range values.
    internal func slice(from offset: Int = 0, length: Int? = nil) -> String {
        guard !isEmpty else { return "" }
        let safeStart = Swift.max(0, offset)
        guard safeStart < count else { return "" }

        let startIdx = index(startIndex, offsetBy: safeStart)
        if let length, length >= 0 {
            guard length > 0 else { return "" }
            let endIdx = index(
                startIdx,
                offsetBy: length,
                limitedBy: endIndex
            ) ?? endIndex
            return String(self[startIdx ..< endIdx])
        } else {
            return String(self[startIdx...])
        }
    }
}
