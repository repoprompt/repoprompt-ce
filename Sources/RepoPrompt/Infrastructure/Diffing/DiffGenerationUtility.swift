import Foundation

enum DiffGenerationError: Error {
    case emptyContent
    case invalidSelector
    case noMatchFound
    case ambiguousMatch(String)
    case invalidRange(start: Int, end: Int)
    case timeout
}

/// Improve error reporting across the app and MCP tools.
/// Conform to LocalizedError so `error.localizedDescription` is informative
/// instead of the default "The operation couldn’t be completed …" message.
extension DiffGenerationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .emptyContent:
            "file content is empty – nothing to edit"
        case .invalidSelector:
            "search block is empty or invalid; provide non-empty search text"
        case .noMatchFound:
            "search block not found in file (matches are exact, including whitespace/indentation)"
        case let .ambiguousMatch(message):
            // Message is produced upstream with line numbers when available
            message.isEmpty
                ? "search block matches multiple locations; make it more specific or use replace_all=true"
                : message
        case let .invalidRange(start, end):
            "invalid search range (start: \(start), end: \(end))"
        case .timeout:
            "diff generation timed out; try a shorter search block or smaller scope"
        }
    }
}

/// Provide stable error codes for logging/bridging if needed.
extension DiffGenerationError: CustomNSError {
    static var errorDomain: String {
        "RepoPrompt.DiffGenerationError"
    }

    var errorCode: Int {
        switch self {
        case .emptyContent: 1
        case .invalidSelector: 2
        case .noMatchFound: 3
        case .ambiguousMatch: 4
        case .invalidRange: 5
        case .timeout: 6
        }
    }
}

public enum DiffPrecision: String, CaseIterable {
    case normal = "Normal"
    case high = "High"
}

class DiffGenerationUtility {
    /// Controls whether detailed logging is enabled. Set to true for debugging diff generation.
    static let enableDetailedLogging: Bool = false

    struct LineData {
        let original: String
        let cleaned: String // truncated version for n-grams
        let removedTags: String // truncated version for partial checks
        let removedTagsHigh: String // full version for exact matching
    }

    /// 🚩 Public façade
    static func generateDiff(
        fileContent: [String],
        lineIndexMap: [String: [Int]]?,
        startSelector: [String]?,
        endSelector: [String]?,
        searchBlock: [String]?,
        newContent: [String],
        action: FileAction,
        diffPrecision: DiffPrecision = .normal,
        searchStartLine: Int = 0,
        mcpAmbiguityCheck: Bool = false,
        replaceAll: Bool = false,
        tabPromotionEnabled: Bool = true
    ) async throws -> [DiffChunk] {
        switch action {
        case .create:
            return generateCreateDiff(newContent: newContent)

        case .delete:
            return generateDeleteDiff(fileContent: fileContent)

        case .rewrite, .modify:
            let isStartSelectorEmpty = startSelector?.isEmpty ?? true
            let isEndSelectorEmpty = endSelector?.isEmpty ?? true
            let isSearchBlockEmpty = searchBlock?.isEmpty ?? true

            if !isSearchBlockEmpty {
                return try await generateDiffWithSearchBlock(
                    fileContent: fileContent,
                    searchBlock: searchBlock!,
                    newContent: newContent,
                    diffPrecision: diffPrecision,
                    lineIndexMap: lineIndexMap,
                    searchStartLine: searchStartLine,
                    mcpAmbiguityCheck: mcpAmbiguityCheck,
                    replaceAll: replaceAll,
                    tabPromotionEnabled: tabPromotionEnabled
                )
            } else if isStartSelectorEmpty, isEndSelectorEmpty {
                return generateRewriteDiff(fileContent: fileContent, newContent: newContent)
            }

            throw DiffGenerationError.noMatchFound
            /*
             // ------- (unchanged selector-based branch below) -------
             guard !fileContent.isEmpty else {
             	throw DiffGenerationError.emptyContent
             }

             //let processedFileContent = fileContent.map(processLineOld)
             let processedStartSelector = startSelector?.map(processLineOld)
             let processedEndSelector = endSelector?.map(processLineOld)

             do {
             	return try await withTimeout(seconds: 5) {
             		try await generateDiffCore(
             			fileContent: processedLineData,
             			lineIndexMap: lineIndexMap,
             			startSelector: processedStartSelector,
             			endSelector: processedEndSelector,
             			newContent: newContent
             		)
             	}
             } catch {
             	throw DiffGenerationError.noMatchFound
             }
             */
        }
    }

    private static func generateCreateDiff(newContent: [String]) -> [DiffChunk] {
        var additions: [DiffLine] = []
        additions.reserveCapacity(newContent.count)
        for line in newContent {
            additions.append(DiffLine(content: "+" + line))
        }
        return [DiffChunk(lines: additions, startLine: 0)]
    }

    private static func generateDeleteDiff(fileContent: [String]) -> [DiffChunk] {
        var removals: [DiffLine] = []
        removals.reserveCapacity(fileContent.count)
        for line in fileContent {
            removals.append(DiffLine(content: "-" + line))
        }
        return [DiffChunk(lines: removals, startLine: 0)]
    }

    static func generateRewriteDiff(fileContent: [String], newContent: [String]) -> [DiffChunk] {
        let diffEdits = DiffEditCreator.myersDiff(oldLines: fileContent, newLines: newContent)
        var diffLines = convertDiffEditsToLines(diffEdits)

        // Find the index of the first addition or removal
        let firstChangeIndex = diffLines.firstIndex { $0.type != .context } ?? 0

        // Find the last context line before the first change
        let matchedLineIndex = firstChangeIndex > 0 ? firstChangeIndex - 1 : 0

        // Count the number of actual file lines before the matched line
        let linesToRemove = diffLines[..<matchedLineIndex].count(where: { $0.type == .context })

        // Remove all lines before the matched line
        diffLines.removeFirst(matchedLineIndex)

        return splitDiffLinesIntoChunks(diffLines: diffLines, startingAt: linesToRemove)
    }

    private static func convertDiffEditsToLines(_ diffEdits: [DiffEdit]) -> [DiffLine] {
        var diffLines: [DiffLine] = []
        diffLines.reserveCapacity(diffEdits.reduce(0) { $0 + $1.lines.count })

        for edit in diffEdits {
            switch edit.type {
            case .addition:
                for line in edit.lines {
                    diffLines.append(DiffLine(content: "+" + line))
                }
            case .deletion:
                for line in edit.lines {
                    diffLines.append(DiffLine(content: "-" + line))
                }
            case .equal:
                for line in edit.lines {
                    diffLines.append(DiffLine(content: " " + line))
                }
            }
        }

        return diffLines
    }

    /*
     private static func generateDiffCore(
     	fileContent: [LineData],
     	lineIndexMap: [String: [Int]]?,
     	startSelector: [LineData]?,
     	endSelector: [LineData]?,
     	newContent: [String]
     ) async throws -> [DiffChunk] {
     	// 1) Validate base content
     	guard !fileContent.isEmpty else {
     		throw DiffGenerationError.emptyContent
     	}

     	let matchedLine: Int
     	let endLine: Int

     	// 2) Handle start selector with validation
     	if let startSelector = startSelector, !startSelector.isEmpty {
     		matchedLine = try await findBestMatchUsingNGrams(selector: startSelector, in: fileContent, lineIndexMap: lineIndexMap)
     		// No need to check for -1 as findBestMatchUsingNGrams now throws on no match
     		guard matchedLine >= 0, matchedLine < fileContent.count else {
     			throw DiffGenerationError.invalidRange(start: matchedLine, end: fileContent.count)
     		}
     	} else {
     		matchedLine = 0 // Start of the file
     	}

     	// 3) Handle end selector with validation
     	if let endSelector = endSelector, !endSelector.isEmpty {
     		// Check matchedLine bounds before slicing
     		guard matchedLine < fileContent.count else {
     			throw DiffGenerationError.invalidRange(start: matchedLine, end: fileContent.count)
     		}

     		let searchRange = Array(fileContent[matchedLine...])
     		endLine = try await findBestEndMatchUsingNGrams(selector: endSelector, in: searchRange, startLine: matchedLine)

     		if endLine == -1 {
     			throw DiffGenerationError.noMatchFound
     		}

     		// Verify endLine is within valid range
     		guard endLine > matchedLine, endLine <= fileContent.count else {
     			throw DiffGenerationError.invalidRange(start: matchedLine, end: endLine)
     		}
     	} else {
     		endLine = fileContent.count // End of the file
     	}

     	// 4) Double-check ranges are valid
     	guard matchedLine < endLine else {
     		print("Error: Invalid range: matchedLine (\(matchedLine)) >= end (\(endLine))")
     		throw DiffGenerationError.invalidRange(start: matchedLine, end: endLine)
     	}

     	// 5) Verify slice bounds before accessing
     	guard matchedLine >= 0, endLine <= fileContent.count else {
     		throw DiffGenerationError.invalidRange(start: matchedLine, end: endLine)
     	}

     	// 6) Check for Task cancellation before expensive operations
     	if Task.isCancelled {
     		throw CancellationError()
     	}

     	let oldContent = fileContent[matchedLine..<endLine].map { $0.original }
     	let diffEdits = DiffEditCreator.myersDiff(oldLines: Array(oldContent), newLines: newContent)

     	let diffLines = convertDiffEditsToLines(diffEdits)

     	return splitDiffLinesIntoChunks(diffLines: diffLines, startingAt: matchedLine)
     }
     */

    /// 🚩 Offset-aware search-block diff
    static func generateDiffWithSearchBlock(
        fileContent: [String],
        searchBlock: [String],
        newContent: [String],
        diffPrecision: DiffPrecision = .normal,
        lineIndexMap: [String: [Int]]? = nil,
        searchStartLine: Int = 0,
        mcpAmbiguityCheck: Bool = false,
        replaceAll: Bool = false,
        tabPromotionEnabled: Bool = true
    ) async throws -> [DiffChunk] {
        guard !fileContent.isEmpty else { throw DiffGenerationError.emptyContent }
        guard !searchBlock.isEmpty else { throw DiffGenerationError.invalidSelector }
        guard searchStartLine < fileContent.count else {
            if enableDetailedLogging {
                print("Invalid Range: \(searchStartLine)/\(fileContent.count)")
            }
            throw DiffGenerationError.invalidRange(start: searchStartLine, end: fileContent.count)
        }

        // 🧹 Normalize the *search* block: promote leading "\t"/"\u0009" escapes
        // into the indentation tag so the matcher doesn't look for literal "\t".
        // Narrow scope: only affects the prefix after <sN>/<tN>, idempotent.
        let sanitizedSearch = String.promoteEscapedTabsInEncodedLines(
            searchBlock,
            enabled: tabPromotionEnabled
        )

        // Precompute processed selector once (used in both single + replace_all paths)
        let processedSearch = sanitizedSearch.map { processLine($0, precision: diffPrecision) }

        // Handle replace_all by finding multiple matches
        if replaceAll {
            var allChunks: [DiffChunk] = []
            allChunks.reserveCapacity(1)
            var currentStartLine = searchStartLine

            while currentStartLine < fileContent.count {
                // ➊ Search only after `currentStartLine`
                let fileSlice = fileContent[currentStartLine...]
                let processedFileSlice = fileSlice.map { processLine($0, precision: diffPrecision) }

                let sliceIndexMap = lineIndexMap ?? buildLineIndexMapHigh(content: processedFileSlice)

                // ➋ Locate match *inside* the slice
                let localMatch: Int
                do {
                    localMatch = try await findBestMatchUsingNGrams(
                        selector: processedSearch,
                        in: processedFileSlice,
                        lineIndexMap: sliceIndexMap,
                        mcpAmbiguityCheck: false // Skip ambiguity check for replace_all
                    )
                } catch DiffGenerationError.noMatchFound {
                    break // No more matches found
                }

                if localMatch == -1 {
                    break
                }

                // Convert to absolute indices in original file
                let globalMatch = localMatch + currentStartLine
                let globalEnd = globalMatch + sanitizedSearch.count

                guard globalEnd <= fileContent.count else {
                    break // Skip invalid ranges
                }

                // ➌ Produce diff for this match (same as single-match logic)
                let oldBlock = Array(fileContent[globalMatch ..< globalEnd])
                let correctedNew = IndentCorrectionUtility.reIndentUsingSearchBlock(
                    oldBlock: oldBlock,
                    searchBlock: sanitizedSearch,
                    newSnippet: newContent,
                    tabPromotionEnabled: tabPromotionEnabled
                )

                // ✅ Final guard: avoid introducing broken indentation
                let sanitizedNew = String.promoteEscapedTabsInEncodedLines(
                    correctedNew,
                    enabled: tabPromotionEnabled
                )

                #if DEBUG
                    if sanitizedNew != correctedNew {
                        let fixed = String.findLinesWithLeadingEscapedTabs(correctedNew)
                        print("🧹 Normalized leading \\t/\\u0009 in replacement lines (replace-all): \(fixed)")
                    }
                #endif

                // Use `sanitizedNew` from here forward
                let edits = DiffEditCreator.myersDiff(oldLines: oldBlock, newLines: sanitizedNew)
                let diffLines = convertDiffEditsToLines(edits)

                // ➍ Create chunks at original-file positions. The applier adjusts later
                // chunks as preceding insertions or deletions are applied.
                let chunks = splitDiffLinesIntoChunks(diffLines: diffLines, startingAt: globalMatch)
                allChunks.append(contentsOf: chunks)

                // Move cursor past the replaced section
                currentStartLine = globalEnd
            }

            if allChunks.isEmpty {
                throw DiffGenerationError.noMatchFound
            }

            return allChunks
        }

        // Original single-match logic
        // ➊ Search only after `searchStartLine`
        let fileSlice = fileContent[searchStartLine...]
        let processedFileSlice = fileSlice.map { processLine($0, precision: diffPrecision) }

        let sliceIndexMap = lineIndexMap ?? buildLineIndexMapHigh(content: processedFileSlice)

        // ➂ Locate match *inside* the slice
        let localMatch = try await findBestMatchUsingNGrams(
            selector: processedSearch,
            in: processedFileSlice,
            lineIndexMap: sliceIndexMap,
            mcpAmbiguityCheck: mcpAmbiguityCheck
        )
        if localMatch == -1 {
            throw DiffGenerationError.noMatchFound
        }

        // Convert to absolute indices
        let globalMatch = localMatch + searchStartLine
        let globalEnd = globalMatch + sanitizedSearch.count
        guard globalEnd <= fileContent.count else {
            throw DiffGenerationError.invalidRange(start: globalMatch, end: globalEnd)
        }

        // ➌ Produce diff
        let oldBlock = Array(fileContent[globalMatch ..< globalEnd])
        let correctedNew = IndentCorrectionUtility.reIndentUsingSearchBlock(
            oldBlock: oldBlock,
            searchBlock: sanitizedSearch,
            newSnippet: newContent,
            tabPromotionEnabled: tabPromotionEnabled
        )

        // ✅ Final guard: avoid introducing broken indentation
        let sanitizedNew = String.promoteEscapedTabsInEncodedLines(
            correctedNew,
            enabled: tabPromotionEnabled
        )

        #if DEBUG
            if sanitizedNew != correctedNew {
                let fixed = String.findLinesWithLeadingEscapedTabs(correctedNew)
                print("🧹 Normalized leading \\t/\\u0009 in replacement lines (single match): \(fixed)")
            }
        #endif

        // Use `sanitizedNew` from here forward
        let edits = DiffEditCreator.myersDiff(oldLines: oldBlock, newLines: sanitizedNew)
        let diffLines = convertDiffEditsToLines(edits)

        // ➍ Return absolute-position chunks
        return splitDiffLinesIntoChunks(diffLines: diffLines, startingAt: globalMatch)
    }

    private static func splitDiffLinesIntoChunks(diffLines: [DiffLine], startingAt startLine: Int) -> [DiffChunk] {
        var chunks: [DiffChunk] = []
        var currentChunkLines: [DiffLine] = []
        var currentStartLine = startLine
        var contextLineBuffer: [DiffLine] = []

        for line in diffLines {
            switch line.type {
            case .addition, .removal:
                // If there are buffered context lines, add them to the current chunk
                if !contextLineBuffer.isEmpty {
                    currentChunkLines.append(contentsOf: contextLineBuffer)
                    contextLineBuffer.removeAll()
                }
                currentChunkLines.append(line)
            case .context:
                contextLineBuffer.append(line)
                if contextLineBuffer.count >= 3 {
                    // Remove trailing context lines from current chunk
                    while let lastLine = currentChunkLines.last, lastLine.type == .context {
                        contextLineBuffer.insert(currentChunkLines.removeLast(), at: 0)
                    }

                    // Only add the chunk if it contains at least one addition or removal
                    if currentChunkLines.contains(where: { $0.type != .context }) {
                        let chunk = DiffChunk(lines: currentChunkLines, startLine: currentStartLine)
                        chunks.append(chunk)
                    }

                    // Update the start line
                    currentStartLine += currentChunkLines.count(where: { $0.type != .addition }) + contextLineBuffer.count

                    // Prepare for the next chunk
                    currentChunkLines.removeAll()
                    contextLineBuffer.removeAll()
                }
            }
        }

        // Handle any remaining lines after the loop
        if !currentChunkLines.isEmpty || !contextLineBuffer.isEmpty {
            // Remove trailing context lines from current chunk
            while let lastLine = currentChunkLines.last, lastLine.type == .context {
                contextLineBuffer.insert(currentChunkLines.removeLast(), at: 0)
            }

            // Only add the chunk if it contains at least one addition or removal
            if currentChunkLines.contains(where: { $0.type != .context }) {
                let chunk = DiffChunk(lines: currentChunkLines, startLine: currentStartLine)
                chunks.append(chunk)
            }
        }

        return chunks
    }

    /// Finds the best match for a selector in the given content using an n-gram similarity search,
    /// then refines that match in a smaller window.
    static func findBestMatchUsingNGrams(selector: [LineData], in content: [LineData], lineIndexMap: [String: [Int]], mcpAmbiguityCheck: Bool = false) async throws -> Int {
        // 1) Basic validation - ensure inputs are valid
        guard !selector.isEmpty else {
            throw DiffGenerationError.invalidSelector
        }
        guard !content.isEmpty else {
            throw DiffGenerationError.emptyContent
        }

        // First try quick consecutive exact matches for at least 3 lines
        if enableDetailedLogging {
            print("🔍 Attempting consecutive exact match for selector with \(selector.count) lines")
        }

        let quickIndex: Int? = if mcpAmbiguityCheck {
            try matchSelectorFastWithAmbiguityCheck(selector: selector, content: content, lineIndex: lineIndexMap)
        } else {
            try matchSelectorFast(selector: selector, content: content, lineIndex: lineIndexMap)
        }

        if let quickIndex {
            if enableDetailedLogging {
                print("✅ Found consecutive exact match at index \(quickIndex)")
            }
            return quickIndex
        } else {
            if enableDetailedLogging {
                print("❌ No consecutive exact match found, error thrown")
            }
            throw DiffGenerationError.noMatchFound
        }

        if enableDetailedLogging {
            print("❌ No consecutive exact match found, falling back to n-gram matching")
        }

        // ---------- FALL BACK TO N-GRAM LOGIC ----------

        // 2) Check array bounds before operations
        let maxIndex = content.count - selector.count
        guard maxIndex >= 0 else {
            // Means the selector is bigger than the content, so no valid match
            throw DiffGenerationError.invalidSelector
        }

        let selectorNGrams = createNGrams(from: selector.map(\.removedTags))
        var bestMatch = -1
        var bestScore = 0.0

        // Use moderate step size that scales with selector size
        let step = max(1, min(selector.count / 8, 3))

        // Clamp the loop to 0...maxIndex
        for i in stride(from: 0, through: maxIndex, by: step) {
            // 3) Check for Task cancellation during potentially long loop
            if Task.isCancelled {
                throw CancellationError()
            }

            // 4) Carefully validate slice bounds before array access
            let sliceEnd = i + selector.count
            guard sliceEnd <= content.count else {
                // Should never happen with our maxIndex check, but safe to verify
                continue
            }

            // Safely slice content
            let contentSlice = Array(content[i ..< sliceEnd])
            let contentNGrams = createNGrams(from: contentSlice.map(\.removedTags))
            let score = calculateNGramSimilarity(selectorNGrams, contentNGrams)

            if score > bestScore {
                bestScore = score
                bestMatch = i
                // Early exit if we find a very good match
                if score > 0.98 {
                    break
                }
            }
        }

        // 5) Check result before refinement
        if bestMatch == -1 {
            throw DiffGenerationError.noMatchFound
        }

        // Always refine within a window if we found something
        let windowSize = if selector.count > 50 {
            min(10, selector.count / 5) // Large selectors
        } else if selector.count > 20 {
            min(15, selector.count / 3) // Medium selectors
        } else {
            min(10, selector.count) // Small selectors
        }

        bestMatch = refineMatch(selector: selector, in: content, around: bestMatch, windowSize: windowSize)

        return bestMatch
    }

    /// Refines an already found approximate match (`initialMatch`) by searching
    /// in the window `[initialMatch - windowSize ... initialMatch + windowSize]`.
    private static func refineMatch(selector: [LineData], in content: [LineData], around initialMatch: Int, windowSize: Int) -> Int {
        // 1) Validate inputs
        guard !selector.isEmpty else { return initialMatch }
        guard !content.isEmpty else { return initialMatch }

        // 2) Validate initialMatch index before using
        guard initialMatch >= 0, initialMatch < content.count else {
            return initialMatch
        }

        // If selector is bigger than content, no point refining
        let maxStart = content.count - selector.count
        if maxStart < 0 {
            return initialMatch
        }

        // 3) Calculate search window bounds with safety checks
        let start = max(0, initialMatch - windowSize)
        let end = min(maxStart, initialMatch + windowSize)
        guard start <= end else {
            return initialMatch
        }

        // 4) Check access bounds for initialMatch before array access
        let initialUpper = initialMatch + selector.count
        guard initialUpper <= content.count else {
            return initialMatch
        }

        var bestMatch = initialMatch
        var bestScore = calculateRefinedMatchScore(
            selector: selector,
            content: Array(content[initialMatch ..< initialUpper])
        )

        // Early exit if initial match is already excellent
        if bestScore > 0.98 * Double(selector.count) {
            return bestMatch
        }

        for i in start ... end where i != initialMatch {
            // 5) Check for Task cancellation during loop
            if Task.isCancelled {
                return initialMatch
            }

            let upper = i + selector.count
            // Safety check in case slicing would go out of range
            guard i >= 0, upper <= content.count else { continue }

            let contentSlice = Array(content[i ..< upper])
            let score = calculateRefinedMatchScore(selector: selector, content: contentSlice)

            if score > bestScore {
                bestScore = score
                bestMatch = i

                // Break out early if we hit a near-perfect score
                if bestScore > 0.98 * Double(selector.count) {
                    break
                }
            }
        }

        return bestMatch
    }

    private static func calculateRefinedMatchScore(selector: [LineData], content: [LineData]) -> Double {
        var totalScore = 0.0
        let minAcceptableScore = 0.5 * Double(selector.count)

        for (index, pair) in zip(selector, content).enumerated() {
            let (selectorLine, contentLine) = pair
            let similarity = selectorLine.cleaned.similarity(to: contentLine.cleaned)
            totalScore += similarity

            // Early exit if score is too low to be competitive
            let remainingPossibleScore = totalScore + Double(selector.count - index - 1)
            if remainingPossibleScore < minAcceptableScore {
                return 0.0
            }
        }

        return totalScore
    }

    /// Finds the best match for an end selector in the given content using an n-gram similarity search,
    /// then refines that match in a smaller window around `initialMatch`.
    private static func findBestEndMatchUsingNGrams(selector: [LineData], in content: [LineData], startLine: Int) async throws -> Int {
        // Ensure selector is not empty and not larger than content
        guard !selector.isEmpty else {
            throw DiffGenerationError.invalidSelector
        }
        let maxIndex = content.count - selector.count
        guard maxIndex >= 0 else {
            // Means the selector is bigger than the content, so no valid match
            throw DiffGenerationError.invalidSelector
        }

        let selectorNGrams = createNGrams(from: selector.map(\.removedTags))
        var bestMatch = -1
        var bestScore = 0.0

        // Use larger steps for initial scanning
        let step = max(1, selector.count / 4)

        // Clamp the loop to 0...maxIndex
        for i in stride(from: 0, through: maxIndex, by: step) {
            let contentSlice = Array(content[i ..< (i + selector.count)])
            let contentNGrams = createNGrams(from: contentSlice.map(\.removedTags))
            let score = calculateNGramSimilarity(selectorNGrams, contentNGrams)

            if score > bestScore {
                bestScore = score
                bestMatch = i
                // Early exit if we find a very good match
                if score > 0.95 {
                    break
                }
            }
        }

        // If a match was found and selector isn't too large, refine it
        if bestMatch != -1 && selector.count <= 20 {
            bestMatch = refineEndMatch(selector: selector, in: content, around: bestMatch, startLine: startLine)
        }

        // If nothing valid was found, return -1; otherwise offset by startLine
        return bestMatch != -1 ? bestMatch + startLine : -1
    }

    /// Similar to `refineMatch` but used for end selectors, with a slightly different
    /// threshold. We clamp the range the same way to avoid out-of-range slices.
    private static func refineEndMatch(selector: [LineData], in content: [LineData], around initialMatch: Int, startLine: Int) -> Int {
        let windowSize = min(5, selector.count)
        // If selector is bigger than content, no point refining
        let maxStart = content.count - selector.count
        if maxStart < 0 {
            return initialMatch
        }

        let start = max(0, initialMatch - windowSize)
        let end = min(maxStart, initialMatch + windowSize)
        guard start <= end else {
            return initialMatch
        }

        var bestMatch = initialMatch
        var bestScore = calculateRefinedMatchScore(
            selector: selector,
            content: Array(content[initialMatch ..< (initialMatch + selector.count)])
        )

        if bestScore > 0.95 * Double(selector.count) {
            return bestMatch
        }

        for i in start ... end where i != initialMatch {
            let upper = i + selector.count
            if upper > content.count {
                break
            }

            let contentSlice = Array(content[i ..< upper])
            let score = calculateRefinedMatchScore(selector: selector, content: contentSlice)

            if score > bestScore {
                bestScore = score
                bestMatch = i

                // Break early if we get a near-perfect match
                if bestScore > 0.95 * Double(selector.count) {
                    break
                }
            }
        }

        return bestMatch
    }

    private static func createNGrams(from strings: [String], size: Int = 3) -> Set<String> {
        // Ensure size is at least 1 and no more than 3
        let ngramSize = max(1, min(10, size))

        var ngrams = Set<String>()
        for string in strings {
            if string.count < ngramSize {
                ngrams.insert(string)
            } else {
                // Use stride to skip some characters for very long strings
                let step = string.count > 100 ? 2 : 1
                for i in stride(from: 0, through: string.count - ngramSize, by: step) {
                    let startIndex = string.index(string.startIndex, offsetBy: i)
                    let endIndex = string.index(startIndex, offsetBy: ngramSize)
                    ngrams.insert(String(string[startIndex ..< endIndex]))
                }
            }
        }
        return ngrams
    }

    private static func calculateNGramSimilarity(_ set1: Set<String>, _ set2: Set<String>) -> Double {
        let union = set1.union(set2).count
        // Prevent division by zero
        guard union > 0 else { return 0.0 }
        let intersection = set1.intersection(set2).count
        return Double(intersection) / Double(union)
    }

    private static func findBestMatch(selector: [LineData], in content: [LineData]) -> (match: Int, score: Double) {
        guard !selector.isEmpty else {
            if enableDetailedLogging {
                print("Error: Invalid selector (empty)")
            }
            return (-1, 0.0)
        }

        var bestScore = 0.0
        var bestIndex = -1

        for i in 0 ... (content.count - selector.count) {
            let contentSlice = Array(content[i ..< (i + selector.count)])
            let score = calculateMatchScore(selector: selector, content: contentSlice)

            if score > bestScore {
                bestScore = score
                bestIndex = i
            }

            if bestScore == Double(selector.count) { // Perfect match
                break
            }
        }

        return (bestIndex, bestScore)
    }

    private static func findBestEndMatch(selector: [LineData], in content: [LineData]) async -> Int {
        var bestScore = 0.0
        var bestMatches: [(index: Int, score: Double)] = []

        // Guard: if selector is longer than content, no possible match.
        guard selector.count <= content.count else {
            return -1
        }

        for i in 0 ... (content.count - selector.count) {
            let contentSlice = Array(content[i ..< (i + selector.count)])
            let score = calculateMatchScore(selector: selector, content: contentSlice)

            if score > bestScore {
                bestScore = score
                bestMatches = [(i, score)]
            } else if score == bestScore {
                bestMatches.append((i, score))
            }
        }

        // If no matches found, avoid force unwrapping on an empty array
        guard !bestMatches.isEmpty else {
            return -1
        }

        // If multiple best matches, choose one closest to the start
        return bestMatches.min(by: { $0.index < $1.index })!.index
    }

    private static func calculateMatchScore(selector: [LineData], content: [LineData]) -> Double {
        zip(selector, content).reduce(0.0) { score, pair in
            let (selectorLine, contentLine) = pair
            let similarity = selectorLine.cleaned.similarity(to: contentLine.cleaned)
            return score + similarity
        }
    }

    // MARK: – Line pre-processing -------------------------------------------------

    /// Collapse runs of “banner / ruler” glyphs so stylistic comment rulers
    /// don’t upset hashing (e.g. “────────”, “━━━”, “–––”, “___” → “-”).
    @inline(__always)
    static func collapseSeparatorRuns(_ s: String) -> String {
        let pattern = #"[-_–—─━═]{2,}"#
        return s.replacingOccurrences(
            of: pattern,
            with: "-",
            options: [.regularExpression]
        )
    }

    /// Internal normalisation pipeline – **all** string surgery happens here.
    @inline(__always)
    private static func normalized(_ raw: String) -> String {
        // 1. Decode HTML entities & lowercase.
        var s = raw.decodingHTMLEntities().lowercased()

        // 2. Collapse NBSP → space, coalesce whitespace, trim.
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")
            .condensingWhitespace()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 3. Strip one leading qualifier (fast path, no regex).
        for q in [
            "public",
            "private",
            "internal",
            "fileprivate",
            "open",
            "final",
            "static",
            "class",
            "override"
        ] where s.hasPrefix(q + " ") {
            s.removeFirst(q.count + 1)
            break
        }

        // 4. Collapse separator runs.
        s = collapseSeparatorRuns(s)

        // 5. Cap to 150 chars to bound fuzzy-match CPU.
        if s.count > 150 {
            s = String(s.prefix(150))
        }

        // 6. Strip *one* trailing delimiter token.
        for tok in ["->", "=>", ":=", "=", ":"] where s.hasSuffix(tok) {
            s.removeLast(tok.count)
            s = s.trimmingCharacters(in: .whitespaces)
            break
        }

        return s
    }

    /// Canonicalises a raw source line for hashing / comparison.
    /// Returns `nil` when the line is empty *after* normalisation.
    @inline(__always)
    static func canonicalKey(_ raw: String) -> String? {
        let key = normalized(raw)
        return key.isEmpty ? nil : key
    }

    /// Returns the strict & loose hash keys plus the cleaned text for a line.
    static func processLine(
        _ raw: String,
        precision: DiffPrecision = .normal
    ) -> LineData {
        guard let base = canonicalKey(raw) else {
            return LineData(
                original: raw,
                cleaned: "",
                removedTags: "",
                removedTagsHigh: ""
            )
        }

        // High-fidelity key (≤150 chars, punctuation kept).
        let strictKey = String(String.removeIndentationTag(base).prefix(150))

        // Loose key (≤25 chars by default, or ≤150 in .high precision mode).
        let looseCap = (precision == .normal) ? 25 : 150
        let looseKey = String(String.removeIndentationTag(base).prefix(looseCap))

        return LineData(
            original: raw,
            cleaned: base,
            removedTags: looseKey,
            removedTagsHigh: strictKey
        )
    }

    /*
     private static func getIndentation(_ line: String) -> Int {
     if let match = line.range(of: "^<[ts](\\d+)>", options: .regularExpression) {
     let indentStr = line[match].dropFirst(2).dropLast()
     return Int(indentStr) ?? 0
     }
     return 0
     }
     */

    /*
     Indexes each line of `content` by its `.removedTags` property.
     Returns a dictionary: lineString -> list of indexes where that line occurs.
     */

    // MARK: – Dual‑key line index -------------------------------------------------

    /// Builds a lookup table that stores **both** a strict and a loose key for every
    /// file line so that tiny punctuation / case drift does not force a fallback to
    /// the expensive fuzzy path.
    static func buildLineIndexMapHigh(content: [LineData]) -> [String: [Int]] {
        var map: [String: [Int]] = [:]
        map.reserveCapacity(content.count * 2)
        for (i, ln) in content.enumerated() {
            map[ln.removedTagsHigh, default: []].append(i) // strict
            map[ln.removedTags, default: []].append(i) // loose
        }
        return map
    }

    /**
     Tries to find a consecutive exact match in `content` for the *entire*
     selector (or at least a required minimum) using `removedTagsHigh` for
     final verification.

     - If `selector` < 3 lines: require a perfect match of all lines (1 or 2).
     - If `selector` ≥ 3 lines: require at least `requiredConsecutiveMatches`.
     For performance, we still do the intersection trick for lines 0 and 1
     using the *truncated* (`removedTags`) field, but we re-check with
     `removedTagsHigh` in the loop.

     Returns the start index if found, or `nil` if no such consecutive match.
     */
    private static func findConsecutiveExactMatch(
        selector: [LineData],
        content: [LineData],
        lineIndexMap: [String: [Int]],
        requiredConsecutiveMatches: Int = 3
    ) throws -> Int? {
        guard !selector.isEmpty, !content.isEmpty else {
            if enableDetailedLogging {
                print("⚠️  Empty selector or content in findConsecutiveExactMatch")
            }
            throw DiffGenerationError.invalidSelector
        }

        // If the selector has only 1 or 2 lines, we require matching all lines in a row.
        let minTarget = (selector.count < 3) ? selector.count : requiredConsecutiveMatches
        // For bigger selectors, we don't check more than 15 consecutive lines in detail.
        let maxTarget = min(15, selector.count)

        if enableDetailedLogging {
            print("🎯 Looking for \(minTarget) consecutive matches (selector: \(selector.count) lines, maxTarget: \(maxTarget))")
        }

        // 1) Build candidate positions for the *first* line using `removedTagsHigh`.
        guard let firstSelectorLine = selector.first?.removedTagsHigh,
              var candidatePositions = lineIndexMap[firstSelectorLine],
              !candidatePositions.isEmpty
        else {
            // If the first line wasn't found at all in `removedTagsHigh`, throw
            if enableDetailedLogging {
                print("❌ First selector line not found in lineIndexMap: '\(selector.first?.removedTagsHigh ?? "nil")'")
                print("   Original first line: '\(selector.first?.original ?? "nil")'")
                print("📋 Available keys in lineIndexMap (first 5): \(Array(lineIndexMap.keys.prefix(5)))")
                if let first = selector.first {
                    print("🔍 Debug: removedTags='\(first.removedTags)', removedTagsHigh='\(first.removedTagsHigh)'")
                }
            }
            throw DiffGenerationError.invalidSelector
        }

        if enableDetailedLogging {
            print("🔎 Found \(candidatePositions.count) candidate positions for first line: \(candidatePositions)")
            if candidatePositions.count == 1 {
                let pos = candidatePositions[0]
                if pos < content.count {
                    print("   Single candidate at \(pos) - content line: '\(content[pos].original)'")
                } else {
                    print("   Single candidate at \(pos) - OUT OF BOUNDS (content has \(content.count) lines)")
                }
            }
        }

        // 2) If there's at least a second line in the selector, do an intersection-based filter:
        if selector.count > 1 {
            let secondSelectorTrunc = selector[1].removedTagsHigh
            if enableDetailedLogging {
                print("🔍 Looking for second line: '\(secondSelectorTrunc)'")
            }
            guard let secondLinePositions = lineIndexMap[secondSelectorTrunc], !secondLinePositions.isEmpty else {
                if enableDetailedLogging {
                    print("❌ Second selector line not found in lineIndexMap: '\(secondSelectorTrunc)'")
                }
                throw DiffGenerationError.invalidSelector
            }

            if enableDetailedLogging {
                print("🔎 Found \(secondLinePositions.count) positions for second line: \(secondLinePositions)")
            }

            // Shift second-line positions by -1 to align them with where line0 must have been.
            let secondLineCandidatesShifted = Set(secondLinePositions.map { $0 - 1 })
            if enableDetailedLogging {
                print("🔄 Shifted second line candidates: \(secondLineCandidatesShifted)")
            }

            // Intersect with our candidatePositions:
            candidatePositions = candidatePositions.filter { secondLineCandidatesShifted.contains($0) }
            if enableDetailedLogging {
                print("🎯 After intersection, remaining candidates: \(candidatePositions)")
            }

            if candidatePositions.isEmpty {
                if enableDetailedLogging {
                    print("❌ No candidates remain after intersection")
                }
                throw DiffGenerationError.invalidSelector
            }
        }

        var bestCandidateIndex: Int?
        var bestConsecutiveCount = 0

        // 3) Now for each candidate start index, do the "real" check using `removedTagsHigh`.
        if enableDetailedLogging {
            print("🧪 Testing \(candidatePositions.count) candidate positions...")
            print("🔍 Expected first selector line: '\(selector.first?.removedTagsHigh ?? "nil")'")
        }

        outerLoop: for startIndex in candidatePositions {
            let remaining = content.count - startIndex
            if remaining < 1 {
                if enableDetailedLogging {
                    print("⚠️  Skipping candidate \(startIndex) - not enough remaining content (total: \(content.count), remaining: \(remaining))")
                }
                continue
            }

            // Additional check for selector size vs remaining content
            if remaining < selector.count, enableDetailedLogging {
                print("⚠️  Candidate \(startIndex) has insufficient content: need \(selector.count) lines, only \(remaining) remaining")
            }

            // We'll check up to `maxTarget` lines (or until we run out of selector lines).
            let limit = min(remaining, maxTarget, selector.count)
            if enableDetailedLogging {
                print("🔬 Testing candidate \(startIndex) with limit \(limit)")
            }

            var consecutiveCount = 0
            for offset in 0 ..< limit {
                // Compare the more precise `removedTagsHigh` field
                let contentLine = content[startIndex + offset].removedTagsHigh
                let selectorLine = selector[offset].removedTagsHigh

                if contentLine == selectorLine {
                    consecutiveCount += 1
                    if enableDetailedLogging {
                        print("  ✅ Match at offset \(offset): consecutive=\(consecutiveCount)")
                    }
                } else {
                    if enableDetailedLogging {
                        print("  ❌ Mismatch at offset \(offset):")
                        print("     Content processed:  '\(contentLine)'")
                        print("     Selector processed: '\(selectorLine)'")
                        print("     Content original:   '\(content[startIndex + offset].original)'")
                        print("     Selector original:  '\(selector[offset].original)'")
                    }
                    break
                }
            }

            if enableDetailedLogging {
                print("📊 Final consecutive count for candidate \(startIndex): \(consecutiveCount)")
            }

            if consecutiveCount > bestConsecutiveCount {
                bestConsecutiveCount = consecutiveCount
                bestCandidateIndex = startIndex
                if enableDetailedLogging {
                    print("🏆 New best candidate: index=\(startIndex), count=\(consecutiveCount)")
                }

                // If we matched as many lines as the entire selector, we can short-circuit:
                if bestConsecutiveCount == selector.count {
                    if enableDetailedLogging {
                        print("🎯 Perfect match found - short-circuiting")
                    }
                    break outerLoop
                }
            }
        }

        // 4) Final logic to see if the consecutiveCount meets requirements
        if enableDetailedLogging {
            print("🏁 Final decision: bestCount=\(bestConsecutiveCount), minTarget=\(minTarget), selectorCount=\(selector.count)")
        }

        if selector.count < 3 {
            // If the selector is 1 or 2 lines, require perfect match
            guard let idx = bestCandidateIndex,
                  bestConsecutiveCount == selector.count
            else {
                if enableDetailedLogging {
                    print("❌ Small selector failed: need perfect match (\(selector.count)) but got \(bestConsecutiveCount)")
                }
                return nil
            }
            if enableDetailedLogging {
                print("✅ Small selector success: perfect match at \(idx)")
            }
            return idx
        } else {
            // For bigger selectors, we only need at least `minTarget` consecutive lines
            guard let idx = bestCandidateIndex,
                  bestConsecutiveCount >= minTarget
            else {
                if enableDetailedLogging {
                    print("❌ Large selector failed: need \(minTarget) consecutive but got \(bestConsecutiveCount)")
                }
                return nil
            }
            if enableDetailedLogging {
                print("✅ Large selector success: \(bestConsecutiveCount) consecutive matches at \(idx)")
            }
            return idx
        }
    }

    /// ─────────────────────────────────────────────────────────────────────────────
    ///  adaptive Dice threshold
    ///  Short tokens lose Dice similarity rapidly with even a 1‑char typo.
    ///  This piece‑wise table was tuned empirically on the test‑suite corpus
    ///  (≈ 20k unique selector lines) – it is branch‑free for the hot path
    ///  and needs no floating‑point maths other than one cast.
    ///
    ///  len ≤ 4      → 0.25   (ultra‑short keys, e.g. "int", "id")
    ///  len 5–7      → 0.35   (e.g. "logout", "await")
    ///  len 8–12     → 0.50   (medium identifiers)
    ///  len 13–20    → 0.65   (longer statements)
    ///  len 21–40    → 0.70   (whole‑line anchors with minor punctuation drift)
    ///  len > 40     → 0.80   (very long anchors – still allow some drift)
    @inline(__always)
    private static func adaptiveDiceThreshold(forShortestLine len: Int) -> Double {
        switch len {
        case ...4: 0.25
        case ...7: 0.35
        case ...12: 0.50
        case ...20: 0.65
        case ...40: 0.70 // ← NEW band: be less strict for 21‑40‑char lines
        default: 0.80
        }
    }

    /// Attempts to anchor `selector` inside `content` quickly.
    ///
    ///  ➤ Phase A  Strict head + tail boxing (first **2** & last **2** lines)
    ///  ➤ Phase B  Classic consecutive-run check for short blocks (< 6 lines)
    ///  ➤ Phase C  If **no** candidates from the map, run a *tiny* fuzzy probe:
    ///             scan at most `maxFuzzyKeys` map entries and keep keys whose
    ///             bi-gram Dice coefficient ≥ `fuzzyThreshold`.
    ///
    /// The function touches at most a few hundred strings, so CPU / RAM overhead
    /// is negligible compared to the n-gram routine it replaces.
    static func matchSelectorFast(
        selector: [LineData],
        content: [LineData],
        lineIndex: [String: [Int]],
        maxFuzzyKeys maxKeys: Int = 400,
        fuzzyThreshold sim: Double = 0.90
    ) throws -> Int? {
        // ── Guard rails ─────────────────────────────────────────────────────────
        guard !selector.isEmpty, !content.isEmpty else {
            throw DiffGenerationError.invalidSelector
        }
        let selCount = selector.count
        let isLong = selCount >= 6 // unchanged

        // Medium-sized selectors (3-5 lines) now need ≥ 3 consecutive head hits.
        let requiredHeadForMedium = min(3, selCount)

        // Tiny selectors (1–2 lines) keep their length-aware fuzzy gate.
        let fuzzyThresh: Double = {
            if selCount >= 6 { // large blocks – keep caller-supplied
                return sim
            } else if selCount >= 3 { // medium blocks
                return max(0.60, sim * 0.95)
            } else { // 1–2-line selectors
                let minLen = selector.map(\.removedTagsHigh.count).min() ?? 0
                return adaptiveDiceThreshold(forShortestLine: minLen)
            }
        }()

        if enableDetailedLogging {
            print("🔵 [matchSelectorFast] selector=\(selCount) line(s)  content=\(content.count) line(s)")
        }

        /// ── Helper: candidate list for selector line 0 --------------------------
        func strictOrLoosePositions(for line: LineData) -> [Int] {
            lineIndex[line.removedTagsHigh] ?? lineIndex[line.removedTags] ?? []
        }

        var starts = strictOrLoosePositions(for: selector[0])
        starts.removeDuplicatesInPlace() // dedup right away

        // While probing we cache Dice scores *per* content index so we can reuse
        // them later without recomputing.
        var fuzzyScoreMap: [Int: Double] = [:] // contentIdx → Dice coeff

        if enableDetailedLogging {
            print("  🏷️  Initial candidates for first line: \(starts.count)")
        }

        // ── Light fuzzy probe if nothing matched strictly -----------------------
        if starts.isEmpty {
            let sKey = selector[0].removedTagsHigh
            var seen = 0
            for (k, pos) in lineIndex {
                if seen >= maxKeys {
                    break
                }
                seen += 1
                let coeff = sKey.diceCoefficient(against: k)
                if enableDetailedLogging {
                    print("  🔍 Fuzzy probe test \(seen)/\(maxKeys): \(sKey) ↔ \(k)  Dice: \(coeff)")
                }
                guard coeff >= fuzzyThresh else { continue }
                for p in pos {
                    starts.append(p)
                    fuzzyScoreMap[p] = max(fuzzyScoreMap[p] ?? 0, coeff)
                }
            }
            if enableDetailedLogging {
                print("  🔍 Fuzzy probe added \(starts.count) candidate(s)")
            }
            if starts.isEmpty {
                return nil
            } // nothing at all found
        }

        // ── Optional second-line intersection -----------------------------------
        if selCount > 1 {
            var second = strictOrLoosePositions(for: selector[1]).compactMap { $0 > 0 ? $0 - 1 : nil }
            if second.isEmpty {
                // fuzzy probe for second line (reuse threshold logic)
                let sKey = selector[1].removedTagsHigh
                var collected: [Int] = []
                var scanned = 0
                for (k, pos) in lineIndex where scanned < maxKeys {
                    scanned += 1
                    if sKey.diceCoefficient(against: k) >= fuzzyThresh {
                        collected += pos.compactMap { $0 > 0 ? $0 - 1 : nil }
                    }
                }
                second = collected
            }
            let inter = starts.filter { second.contains($0) }
            if !inter.isEmpty {
                starts = inter
            }

            // keep fuzzyScoreMap in-sync with surviving candidates
            fuzzyScoreMap = fuzzyScoreMap.filter { starts.contains($0.key) }

            if enableDetailedLogging {
                print("  ✂️  After second-line intersection: \(starts.count) candidate(s)")
            }
        }

        // ── Evaluate each start index ------------------------------------------
        let headLen = isLong ? 2 : selCount // ← was 3
        let tailLen = isLong ? 2 : 0
        var best: (idx: Int, score: Int) = (-1, 0)

        for s in starts {
            if s + selCount > content.count {
                continue
            }

            // Head run
            var head = 0
            for o in 0 ..< headLen
                where content[s + o].removedTagsHigh == selector[o].removedTagsHigh
            {
                head += 1
            }

            // Tail run
            var tail = 0
            if tailLen > 0 {
                for o in 0 ..< tailLen {
                    let selIdx = selCount - tailLen + o
                    let fileIdx = s + selIdx
                    if content[fileIdx].removedTagsHigh == selector[selIdx].removedTagsHigh {
                        tail += 1
                    }
                }
            }

            // stricter pass-logic for 3-5 lines ──────────────────────────────
            let passes: Bool = if isLong {
                head == headLen && tail == tailLen
            } else if selCount < 3 {
                head == selCount // 1–2 lines → perfect head
            } else {
                head >= requiredHeadForMedium // 3–5 lines → ≥ 3 head lines
            }

            let score = head + tail
            if enableDetailedLogging {
                print("    • Start @\(s): head=\(head) tail=\(tail) score=\(score) \(passes ? "✅" : "❌")")
            }

            if passes, score > best.score {
                best = (s, score)
                if score == selCount {
                    break
                } // perfect anchor
            }
        }

        // ── Return strict match if any ------------------------------------------
        if best.idx != -1 {
            if enableDetailedLogging {
                print("✅  [matchSelectorFast] BEST index=\(best.idx) score=\(best.score)")
            }
            return best.idx
        }

        // ── Fuzzy-probe fallback for 1–2-line selectors -------------------------
        if selCount <= 2, !starts.isEmpty {
            let fallbackIdx = starts.max { (fuzzyScoreMap[$0] ?? 0) < (fuzzyScoreMap[$1] ?? 0) }!
            if enableDetailedLogging {
                let coeff = fuzzyScoreMap[fallbackIdx] ?? -1
                print("🟡  Fuzzy-probe fallback accepted @\(fallbackIdx)  Dice=\(coeff)")
            }
            return fallbackIdx
        }

        if enableDetailedLogging {
            print("🚫  [matchSelectorFast] No acceptable candidate found")
        }
        return nil
    }

    // MARK: - MCP-specific matching with ambiguity check

    /// Copy of matchSelectorFast that throws on ambiguous matches instead of returning the best one.
    /// Behaviour is otherwise identical to matchSelectorFast (including the tiny-selector
    /// fuzzy-probe fallback); only the ambiguity check differs.
    static func matchSelectorFastWithAmbiguityCheck(
        selector: [LineData],
        content: [LineData],
        lineIndex: [String: [Int]],
        maxFuzzyKeys maxKeys: Int = 400,
        fuzzyThreshold sim: Double = 0.90
    ) throws -> Int? {
        // ── Guard rails ─────────────────────────────────────────────────────────
        guard !selector.isEmpty, !content.isEmpty else {
            throw DiffGenerationError.invalidSelector
        }
        let selCount = selector.count
        let isLong = selCount >= 6
        let requiredHeadForMedium = min(3, selCount)
        let fuzzyThresh: Double = {
            if selCount >= 6 {
                return sim
            } else if selCount >= 3 {
                return max(0.60, sim * 0.95)
            } else {
                let minLen = selector.map(\.removedTagsHigh.count).min() ?? 0
                return adaptiveDiceThreshold(forShortestLine: minLen)
            }
        }()

        /// ── Helper: candidate list for selector line 0 --------------------------
        func strictOrLoosePositions(for line: LineData) -> [Int] {
            lineIndex[line.removedTagsHigh] ?? lineIndex[line.removedTags] ?? []
        }

        var starts = strictOrLoosePositions(for: selector[0])
        starts.removeDuplicatesInPlace()

        // Cache Dice scores so the tiny-selector fallback can pick the “best”
        var fuzzyScoreMap: [Int: Double] = [:]

        // ── Light fuzzy probe if nothing matched strictly -----------------------
        if starts.isEmpty {
            let sKey = selector[0].removedTagsHigh
            var seen = 0
            for (k, pos) in lineIndex {
                if seen >= maxKeys {
                    break
                }
                seen += 1
                let coeff = sKey.diceCoefficient(against: k)
                guard coeff >= fuzzyThresh else { continue }
                for p in pos {
                    starts.append(p)
                    fuzzyScoreMap[p] = max(fuzzyScoreMap[p] ?? 0, coeff)
                }
            }
            if starts.isEmpty {
                return nil
            }
        }

        // ── Optional second-line intersection -----------------------------------
        if selCount > 1 {
            var second = strictOrLoosePositions(for: selector[1]).compactMap { $0 > 0 ? $0 - 1 : nil }
            if second.isEmpty {
                let sKey = selector[1].removedTagsHigh
                var collected: [Int] = []
                var scanned = 0
                for (k, pos) in lineIndex where scanned < maxKeys {
                    scanned += 1
                    if sKey.diceCoefficient(against: k) >= fuzzyThresh {
                        collected += pos.compactMap { $0 > 0 ? $0 - 1 : nil }
                    }
                }
                second = collected
            }
            let inter = starts.filter { second.contains($0) }
            if !inter.isEmpty {
                starts = inter
            }
            fuzzyScoreMap = fuzzyScoreMap.filter { starts.contains($0.key) }
        }

        // ── Evaluate each start index and collect ALL valid matches ──────────
        let headLen = isLong ? 2 : selCount
        let tailLen = isLong ? 2 : 0
        var validMatches: [(idx: Int, score: Int)] = []

        for s in starts {
            if s + selCount > content.count {
                continue
            }

            // Head run
            var head = 0
            for o in 0 ..< headLen
                where content[s + o].removedTagsHigh == selector[o].removedTagsHigh
            {
                head += 1
            }

            // Tail run
            var tail = 0
            if tailLen > 0 {
                for o in 0 ..< tailLen {
                    let selIdx = selCount - tailLen + o
                    let fileIdx = s + selIdx
                    if content[fileIdx].removedTagsHigh == selector[selIdx].removedTagsHigh {
                        tail += 1
                    }
                }
            }

            // Same pass logic as matchSelectorFast
            let passes: Bool = if isLong {
                head == headLen && tail == tailLen
            } else if selCount < 3 {
                head == selCount
            } else {
                head >= requiredHeadForMedium
            }

            if passes {
                let score = head + tail
                validMatches.append((s, score))
            }
        }

        // ── Check for ambiguity ──────────────────────────────────────────────
        if validMatches.count > 1 {
            let indices = validMatches.map(\.idx).sorted()
            let lines = indices.map { $0 + 1 }.map(String.init).joined(separator: ", ")
            throw DiffGenerationError.ambiguousMatch(
                "Search block matches multiple locations (lines \(lines)). " +
                    "Please make the block more specific or " +
                    "use the replace_all parameter to replace all occurrences."
            )
        }

        // ── Return single strict match if found ------------------------------
        if validMatches.count == 1 {
            return validMatches[0].idx
        }

        // ── Tiny-selector fuzzy-probe fallback (identical to base version) ----
        if selCount <= 2, !starts.isEmpty {
            return starts.max {
                (fuzzyScoreMap[$0] ?? 0) < (fuzzyScoreMap[$1] ?? 0)
            }!
        }

        // Nothing matched
        return nil
    }

    private static func withTimeout<T>(
        seconds: Double,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                // If already canceled, bail out
                if Task.isCancelled {
                    throw CancellationError()
                }
                return try await operation()
            }

            // The "timer" task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                // If it's still not done, throw
                throw DiffGenerationError.timeout
            }

            // Race whichever finishes first
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
