import Foundation

/// Optional config struct for controlling various thresholds.
enum IndentationConfig {
    /// Maximum absolute shift we allow (in spaces) before falling back or clamping.
    static let maxAllowedShift: Int = 12
    /// Acceptable slope range for affine transforms.
    static let slopeMin: Double = 0.5
    static let slopeMax: Double = 2.0
    /// Multiplier for median absolute deviation outlier filtering.
    static let outlierMultiplier: Double = 2.5
    /// If average indent difference is below this threshold, we consider them "already aligned."
    static let preCheckThreshold: Double = 1.5

    /// Maximum number of lines to consider when gathering line pairs
    /// (helps prevent O(n^2) blowups on large blocks).
    static let maxLinePairs: Int = 50

    /// Guard: how many adjacent-indent "shape" sign flips we allow (0.0–1.0 of edges).
    static let shapeFlipTolerance: Double = 0.4
    /// Guard: max per-edge change as a multiple of a single indent unit.
    static let shapeEdgeMagnitudeMultiplier: Double = 2.0
    /// Hard cap on any absolute shift (in spaces); used to bound effectiveMaxShift.
    static let hardMaxAllowedShift: Int = maxAllowedShift * 2
}

/**
 A small helper struct to hold precomputed data for each block:
 - rawLines: The lines (encoded) after unifyIndentStyles
 - indentLevels: The cached indentation level for each line (computed once)
 - trimmedLines: The cached version of each line trimmed (minus indentation tags)
 - indentType: The detected indentation type, from analyzing all lines
 - indentSize: The detected indentation size (e.g. 4 spaces or the numeric tab count)
 */
private struct IndentCache {
    let rawLines: [String]
    let indentLevels: [Int]
    let trimmedLines: [String]

    let indentType: String
    let indentSize: Int

    init(_ lines: [String]) {
        rawLines = lines
        var levels: [Int] = []
        var trimmed: [String] = []
        levels.reserveCapacity(lines.count)
        trimmed.reserveCapacity(lines.count)

        for line in lines {
            levels.append(String.getIndentationLevel(from: line))
            trimmed.append(String.removeIndentationTag(line).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        indentLevels = levels
        trimmedLines = trimmed

        // Because these lines are already in <sNN> / <tNN> form, we detect from encoded lines:
        let (type, size) = String.detectIndentationTypeFromEncodedLines(lines)
        indentType = type
        indentSize = size
    }
}

/// A utility for re-indenting snippets to match existing code blocks, optimized to reduce repeated computations.
class IndentCorrectionUtility {
    // MARK: - Config Constants

    private static let MAX_SHIFT = IndentationConfig.maxAllowedShift
    private static let SLOPE_MIN = IndentationConfig.slopeMin
    private static let SLOPE_MAX = IndentationConfig.slopeMax
    private static let OUTLIER_MULTIPLIER = IndentationConfig.outlierMultiplier
    private static let PRECHECK_THRESHOLD = IndentationConfig.preCheckThreshold

    // MARK: - Public Entry Point

    /**
     Attempt to re-indent `newSnippet` so it matches `oldBlock`, leveraging `searchBlock` if possible.
     If everything fails or the transform degrades indentation, fallback to the original snippet lines.
     */
    static func reIndentUsingSearchBlock(
        oldBlock: [String],
        searchBlock: [String],
        newSnippet: [String],
        tabPromotionEnabled: Bool = true
    ) -> [String] {
        // 🔰 Promote leading "\t"/"\u0009" escapes in the snippet content INTO the indent tag
        // BEFORE computing any transform. This prevents double-application (transform + later sanitize).
        // 1) Convert snippet to match oldBlock's style (no up-front content mutation).
        let (unifiedOld, unifiedSearch, unifiedSnippet0, oldType, oldLevel) = unifyIndentStyles(
            oldBlock, searchBlock, newSnippet
        )

        // 🔰 Sanitize BEFORE any alignment checks/heuristics:
        //    a) Promote escaped \t / \u0009 into the tag
        //    b) Absorb any leading literal tabs/spaces from content into the tag
        //       (so content never starts with whitespace for space-based files).
        let spacesTabStop = (oldType == "s") ? max(oldLevel, 4) : 4
        let promotedSearch = String.promoteEscapedTabsInEncodedLines(
            unifiedSearch,
            spacesTabStop: spacesTabStop,
            enabled: tabPromotionEnabled
        )
        let promotedSnippet = String.promoteEscapedTabsInEncodedLines(
            unifiedSnippet0,
            spacesTabStop: spacesTabStop,
            enabled: tabPromotionEnabled
        )

        // Effective unit used to absorb leaked *literal* tabs in content:
        // - space files: treat one tab as `max(oldLevel, 4)` spaces (fallback to 4 when detection yields 0)
        // - tab files:   each tab == 1 logical unit
        let effectiveUnit = (oldType == "s") ? max(oldLevel, 4) : 1

        let sanitizedSearch = absorbLeakedLeadingIndent(
            in: promotedSearch,
            fileIndentType: oldType,
            indentUnit: effectiveUnit
        )
        let sanitizedSnippet = absorbLeakedLeadingIndent(
            in: promotedSnippet,
            fileIndentType: oldType,
            indentUnit: effectiveUnit
        )

        // Build caches on sanitized inputs to avoid repeated string parsing.
        let oldCache = IndentCache(unifiedOld)
        let searchCache = IndentCache(sanitizedSearch)
        let snippetCache = IndentCache(sanitizedSnippet)

        // 2) Pre-check: if snippet is already aligned, return it unchanged (idempotent).
        if snippetAlreadyAligned(snippet: snippetCache, oldBlock: oldCache, baseIndentUnit: effectiveUnit) {
            return sanitizedSnippet
        }

        // 3) Attempt to derive a transform from oldBlock vs. searchBlock.
        if let transformed = attemptSearchBlockDerivedReIndent(
            oldCache: oldCache,
            searchCache: searchCache,
            snippetCache: snippetCache,
            indentUnit: effectiveUnit
        ) {
            // 3a) Post-check: measure if we actually improved alignment against the original sanitized snippet.
            let beforeScore = measureAlignment(snippet: snippetCache, oldBlock: oldCache)
            let afterScore = measureAlignment(snippet: IndentCache(transformed), oldBlock: oldCache)
            if afterScore > beforeScore {
                if shouldLogIndentDebug() {
                    print("[IndentCorrection] Final transform made alignment worse (\(beforeScore)->\(afterScore)). Reverting to original snippet.")
                }
            } else if String.snippetCollapsedMultiLevels(
                original: sanitizedSnippet, transformed: transformed
            ) {
                if shouldLogIndentDebug() {
                    print("[IndentCorrection] We collapsed multi-level indentation. Reverting to original snippet.")
                }
            } else {
                // ✅ Return the improved transform.
                return transformed
            }
        }

        // 4) Fallback => Just return the sanitized unified snippet (no shifting).
        if shouldLogIndentDebug() {
            print("[IndentCorrection] Transform either failed or was discarded; falling back to original snippet lines.")
        }
        return sanitizedSnippet
    }

    // MARK: - Unify Indentation Styles

    private static func unifyIndentStyles(
        _ oldBlock: [String],
        _ searchBlock: [String],
        _ snippet: [String]
    ) -> ([String], [String], [String], String, Int) {
        // For the old block, we assume it's correctly encoded already
        let (oldType, oldLevel) = String.detectIndentationTypeFromEncodedLines(oldBlock)

        // For searchBlock, use each line's tag and convert to oldType
        let fixedSearch = searchBlock.map { line in
            let (searchType, _) = String.getIndentationEncoding(from: line)
            return String.matchIndentation(
                line,
                snippetIndentType: searchType,
                fileIndentType: oldType
            )
        }

        // For snippet, also use each line's tag and convert to oldType
        let fixedSnippet = snippet.map { line in
            let (snippetType, _) = String.getIndentationEncoding(from: line)
            return String.matchIndentation(
                line,
                snippetIndentType: snippetType,
                fileIndentType: oldType
            )
        }

        if shouldLogIndentDebug() {
            print("Old indent type: \(oldType) - line 0: \(oldBlock.first ?? "")")
            let snippetEncoding = String.getIndentationEncoding(from: snippet.first ?? "")
            print("Snippet indent type: \(snippetEncoding.type) - line 0: \(snippet.first ?? "")")
        }

        return (oldBlock, fixedSearch, fixedSnippet, oldType, oldLevel)
    }

    // MARK: - Attempt Search-Block Derived ReIndent

    private static func attemptSearchBlockDerivedReIndent(
        oldCache: IndentCache,
        searchCache: IndentCache,
        snippetCache: IndentCache,
        indentUnit: Int
    ) -> [String]? {
        let linePairs = gatherComparableLinePairs(oldCache: oldCache, searchCache: searchCache)
        guard !linePairs.isEmpty else {
            if shouldLogIndentDebug() {
                print("[IndentCorrection] No comparable line pairs found. Cannot compute offset.")
            }
            return nil
        }
        if shouldLogIndentDebug() {
            print("[IndentCorrection] Gathered \(linePairs.count) comparable line pairs.")
        }

        let snippetDistinct = Set(snippetCache.indentLevels)
        let oldDistinct = Set(oldCache.indentLevels)
        let hasMultiLevels = (snippetDistinct.count > 1 && oldDistinct.count > 1)

        // Try a two-stage approach if conditions are right
        if hasMultiLevels, shouldTryTwoStage(linePairs: linePairs, oldCache: oldCache, snippetCache: snippetCache) {
            if let candidate = attemptTwoStageApproach(
                linePairs: linePairs,
                snippetCache: snippetCache,
                oldCache: oldCache,
                baseIndentUnit: indentUnit
            ) {
                if isValidIndentCandidate(candidate) {
                    return candidate
                }
            }
        }

        // Uniform median-based approach
        if let uniformDelta = computeUniformDelta(linePairs: linePairs, indentUnit: indentUnit) {
            let maxShift = effectiveMaxShift(forCache: oldCache)
            if abs(uniformDelta) > maxShift {
                // Fallback to discrete shifts if the delta is too large.
                if shouldLogIndentDebug() {
                    print("[IndentCorrection] Uniform delta \(uniformDelta) > effective max shift \(maxShift) => discrete fallback.")
                }
                if let candidate = tryDiscreteShifts(
                    snippetCache: snippetCache,
                    possibleDeltas: [-12, -8, -4, 0, 4, 8, 12] // include 0 to allow no-op when best
                ) {
                    return candidate
                }
                // else fall through
            } else {
                if shouldLogIndentDebug() {
                    print("[IndentCorrection] Computed uniform delta: \(uniformDelta)")
                }
                let candidate = applyUniformDeltaToSnippet(snippetCache.rawLines, snippetCache.indentLevels, uniformDelta: uniformDelta)
                if isValidIndentCandidate(candidate) {
                    return candidate
                }
            }
        } else if shouldLogIndentDebug() {
            print("[IndentCorrection] No uniform delta found. Trying affine transform.")
        }

        // Two-anchor affine transform.
        if let (a, b) = computeTwoAnchorAffine(linePairs: linePairs) {
            let clampedA = min(max(a, SLOPE_MIN), SLOPE_MAX)
            if shouldLogIndentDebug() {
                print("[IndentCorrection] Affine transform => a=\(a) => clamped=\(clampedA), b=\(b)")
            }
            let candidate = applyAffineTransform(snippetCache, a: clampedA, b: b)
            if isValidIndentCandidate(candidate) {
                return candidate
            }
        } else if shouldLogIndentDebug() {
            print("[IndentCorrection] Could not compute a valid two-anchor transform.")
        }

        // Discrete shift fallback if multi-level
        if hasMultiLevels {
            if shouldLogIndentDebug() {
                print("[IndentCorrection] Attempting discrete shift search for multi-level snippet.")
            }
            if let best = tryDiscreteShifts(
                snippetCache: snippetCache,
                possibleDeltas: [-12, -8, -4, 0, 4, 8, 12, 16]
            ) {
                return best
            }
        }

        if shouldLogIndentDebug() {
            print("[IndentCorrection] Could not find a stable transform.")
        }
        return nil
    }

    // MARK: - Additional Checks

    /// Quick pre-check: if snippet is already near oldBlock, skip transforms.
    /// Now also checks that the first line isn’t off by at least one indent level.
    private static func snippetAlreadyAligned(
        snippet: IndentCache,
        oldBlock: IndentCache,
        baseIndentUnit: Int
    ) -> Bool {
        let diffScore = measureAlignment(snippet: snippet, oldBlock: oldBlock)

        guard !oldBlock.indentLevels.isEmpty, !snippet.indentLevels.isEmpty else {
            return false
        }
        let topLineOld = oldBlock.indentLevels[0]
        let topLineSnippet = snippet.indentLevels[0]
        let topLineDiff = abs(topLineOld - topLineSnippet)

        // print("Top line diff: \(topLineDiff) / old \(topLineOld) / snippet \(topLineSnippet)")

        // *** If old block is tabs, treat "1" as a full indent level. Otherwise, use the old block's indentSize. ***
        let threshold = (oldBlock.indentType == "t") ? 1 : baseIndentUnit
        // print("Threshold: \(threshold) - type \(oldBlock.indentType)")

        // If the first line is off by a whole indent level, bail out
        if topLineDiff >= threshold {
            // print("Diff too high: \(topLineDiff)")
            return false
        }

        // Also, check the maximum difference among corresponding lines
        let count = min(snippet.indentLevels.count, oldBlock.indentLevels.count)
        var maxDiff = 0
        for i in 0 ..< count {
            maxDiff = max(maxDiff, abs(snippet.indentLevels[i] - oldBlock.indentLevels[i]))
        }
        if Double(maxDiff) > PRECHECK_THRESHOLD {
            return false
        }

        return diffScore <= PRECHECK_THRESHOLD
    }

    /// Evaluate how well snippet matches oldBlock in terms of indentation difference.
    /// Lower is better (0 means perfect alignment).
    private static func measureAlignment(
        snippet: IndentCache,
        oldBlock: IndentCache
    ) -> Double {
        let count = min(snippet.indentLevels.count, oldBlock.indentLevels.count)
        if count == 0 {
            return Double.infinity
        }
        var sumAbsDiff = 0
        for i in 0 ..< count {
            sumAbsDiff += abs(snippet.indentLevels[i] - oldBlock.indentLevels[i])
        }
        return Double(sumAbsDiff) / Double(count)
    }

    // MARK: - Two-Stage Approach

    private static func attemptTwoStageApproach(
        linePairs: [(oldIndent: Int, searchIndent: Int)],
        snippetCache: IndentCache,
        oldCache: IndentCache,
        baseIndentUnit: Int
    ) -> [String]? {
        guard !snippetCache.rawLines.isEmpty else { return nil }

        // (A) Compute a top-line delta from up to 3 pairs (after outlier filtering)
        let sampleCount = min(3, linePairs.count)
        let sampleDeltas = Array(linePairs.prefix(sampleCount)).map { $0.oldIndent - $0.searchIndent }
        let filteredTop = filterOutliers(deltas: sampleDeltas)
        guard !filteredTop.isEmpty else {
            return nil
        }

        let topLineDelta = computeMedian(of: filteredTop)
        if shouldLogIndentDebug() {
            print("[IndentCorrection:TwoStage] topLineDelta = \(topLineDelta)")
        }

        var candidate = snippetCache.rawLines

        // Replace or shift the top line.
        let oldTopTrimmed = oldCache.trimmedLines[0]
        let snippetTopTrimmed = snippetCache.trimmedLines[0]
        if snippetTopTrimmed == oldTopTrimmed {
            candidate[0] = oldCache.rawLines[0]
        } else {
            candidate[0] = applyIndentDelta(candidate[0], delta: topLineDelta)
        }

        // (B) Compute blockDelta for the remainder.
        guard let blockDelta = computeBlockDeltaForRemainder(linePairs: linePairs) else {
            if shouldLogIndentDebug() {
                print("[IndentCorrection:TwoStage] Could not compute block delta from remainder.")
            }
            return nil
        }

        let maxShift = effectiveMaxShift(forCache: oldCache)
        if abs(blockDelta) > maxShift {
            return nil
        }

        // Apply the computed blockDelta to every line except the top.
        for i in 1 ..< candidate.count {
            candidate[i] = applyIndentDelta(candidate[i], delta: blockDelta)
        }

        // Post-check: ensure the correction improved alignment.
        let beforeScore = measureAlignment(snippet: snippetCache, oldBlock: oldCache)
        let afterScore = measureAlignment(snippet: IndentCache(candidate), oldBlock: oldCache)
        if afterScore > beforeScore {
            if shouldLogIndentDebug() {
                print("[IndentCorrection:TwoStage] Post-check => alignment got worse (\(beforeScore)->\(afterScore)). Reverting.")
            }
            return nil
        }

        if String.snippetCollapsedMultiLevels(original: snippetCache.rawLines, transformed: candidate) {
            if shouldLogIndentDebug() {
                print("[IndentCorrection:TwoStage] Flattened multi-level code. Reverting.")
            }
            return nil
        }

        // Shape guard disabled for now; it proved too restrictive in fuzz/outlier cases.
        return candidate
    }

    private static func shouldTryTwoStage(
        linePairs: [(oldIndent: Int, searchIndent: Int)],
        oldCache: IndentCache,
        snippetCache: IndentCache
    ) -> Bool {
        guard !oldCache.rawLines.isEmpty,
              !snippetCache.rawLines.isEmpty,
              !linePairs.isEmpty
        else {
            return false
        }

        // top-line difference
        let oFirst = oldCache.indentLevels[0]
        let sFirst = snippetCache.indentLevels[0]
        let diff = abs(oFirst - sFirst)

        // If the top line is off by at least one full indent unit => do two-stage
        let baseIndentUnit = oldCache.indentSize
        if diff >= baseIndentUnit {
            return true
        }

        // Filter out outliers among all linePairs
        let rawDeltas = linePairs.map { $0.oldIndent - $0.searchIndent }
        let filtered = filterOutliers(deltas: rawDeltas)

        // If we have fewer than 3 stable pairs, skip two-stage
        if filtered.count < 3 {
            return false
        }

        return true
    }

    private static func computeBlockDeltaForRemainder(
        linePairs: [(oldIndent: Int, searchIndent: Int)]
    ) -> Int? {
        if linePairs.count < 2 {
            return nil
        }
        let tail = Array(linePairs.dropFirst(1))
        let rawDeltas = tail.map { $0.oldIndent - $0.searchIndent }
        let filtered = filterOutliers(deltas: rawDeltas)
        if filtered.isEmpty {
            return nil
        }

        let medianDiff = computeMedian(of: filtered)
        if abs(medianDiff) > MAX_SHIFT {
            return nil
        }
        return medianDiff
    }

    // MARK: - Uniform Delta Approach

    private static func computeUniformDelta(
        linePairs: [(oldIndent: Int, searchIndent: Int)],
        indentUnit: Int
    ) -> Int? {
        guard !linePairs.isEmpty else { return nil }
        // don’t divide by zero
        guard indentUnit != 0 else {
            if shouldLogIndentDebug() {
                print("[Uniform] indentUnit is zero; skipping uniform-delta path")
            }
            return nil
        }

        let rawDeltas = linePairs.map { $0.oldIndent - $0.searchIndent }
        let filtered = filterOutliers(deltas: rawDeltas)
        guard !filtered.isEmpty else { return nil }

        let medianDiff = Double(computeMedian(of: filtered))
        // If the median difference is within half an indent unit, treat it as zero.
        if abs(medianDiff) <= Double(indentUnit) / 2.0 {
            return 0
        }

        let ratio = medianDiff / Double(indentUnit)
        // make sure it’s not ±∞ or NaN
        guard ratio.isFinite else {
            if shouldLogIndentDebug() {
                print("[Uniform] ratio is \(ratio); skipping uniform-delta path")
            }
            return nil
        }

        let levelDelta = Int(round(ratio))
        return levelDelta * indentUnit
    }

    private static func applyUniformDeltaToSnippet(
        _ lines: [String],
        _ indentLevels: [Int],
        uniformDelta: Int
    ) -> [String] {
        let log = shouldLogIndentDebug()
        var result = [String]()
        result.reserveCapacity(lines.count)

        for (i, line) in lines.enumerated() {
            let shifted = applyIndentDelta(line, delta: uniformDelta)
            if log {
                let oldIndent = indentLevels[i]
                let newIndent = String.getIndentationLevel(from: shifted)
                print("  [Uniform] Line #\(i): old=\(oldIndent), new=\(newIndent), delta=\(uniformDelta)")
            }
            result.append(shifted)
        }
        return result
    }

    // MARK: - Affine Approach

    private static func computeTwoAnchorAffine(
        linePairs: [(oldIndent: Int, searchIndent: Int)]
    ) -> (Double, Double)? {
        // Simple approach: check pairs in O(n^2), but we cap linePairs in gatherComparableLinePairs to keep it bounded.
        let count = linePairs.count
        for i in 0 ..< (count - 1) {
            for j in (i + 1) ..< count {
                let p1 = linePairs[i]
                let p2 = linePairs[j]
                if p1.searchIndent != p2.searchIndent {
                    let a = Double(p2.oldIndent - p1.oldIndent)
                        / Double(p2.searchIndent - p1.searchIndent)
                    let b = Double(p1.oldIndent) - a * Double(p1.searchIndent)
                    return (a, b)
                }
            }
        }
        return nil
    }

    private static func applyAffineTransform(
        _ snippetCache: IndentCache,
        a: Double,
        b: Double
    ) -> [String] {
        var result: [String] = []
        result.reserveCapacity(snippetCache.rawLines.count)

        let log = shouldLogIndentDebug()

        // For tabs, we treat 1 tab as 4 spaces worth of limiting factor
        let maxShift = snippetCache.indentType == "t" ? (MAX_SHIFT / 4) : MAX_SHIFT

        for (index, line) in snippetCache.rawLines.enumerated() {
            let oldIndent = snippetCache.indentLevels[index]
            let rawVal = a * Double(oldIndent) + b
            let clampedRaw = max(0.0, rawVal)
            var newIndent = Int(round(clampedRaw))

            // clamp per-line delta
            let delta = newIndent - oldIndent
            let clampedDelta = min(max(delta, -maxShift), maxShift)
            newIndent = oldIndent + clampedDelta

            let shiftedLine = applyIndentDelta(line, delta: clampedDelta)

            if log {
                print("  [Affine] #\(index): old=\(oldIndent), rawVal=\(rawVal), clampedDelta=\(clampedDelta)")
            }
            result.append(shiftedLine)
        }
        return result
    }

    // MARK: - Discrete Shift

    private static func tryDiscreteShifts(
        snippetCache: IndentCache,
        possibleDeltas: [Int]
    ) -> [String]? {
        // Adjust discrete shifts based on snippet's indent type: if tabs, scale by 4
        let conversionFactor = (snippetCache.indentType == "t") ? 4 : 1
        let adjustedDeltas = possibleDeltas.map { $0 / conversionFactor }

        var bestCandidate: [String]?
        var bestScore = Double.infinity

        for delta in adjustedDeltas {
            let candidate = snippetCache.rawLines.map { applyIndentDelta($0, delta: delta) }
            if !isValidIndentCandidate(candidate) {
                continue
            }
            let score = evaluateSnippetIndentScore(candidate, originalIndentCount: Set(snippetCache.indentLevels).count)
            if score < bestScore {
                bestScore = score
                bestCandidate = candidate
            }
        }
        if let best = bestCandidate, bestScore < Double.infinity {
            if shouldLogIndentDebug() {
                print("[IndentCorrection] Discrete shift => best score=\(bestScore)")
            }
            return best
        }
        return nil
    }

    /**
     A simple measure of "range width" in the snippet.
     Lower might mean more flattening. If the snippet had multiple indent levels originally,
     we penalize solutions that collapse to a single indent level.
     */
    private static func evaluateSnippetIndentScore(
        _ lines: [String],
        originalIndentCount: Int
    ) -> Double {
        let indents = lines.map { String.getIndentationLevel(from: $0) }
        if originalIndentCount > 1, Set(indents).count <= 1 {
            return Double.infinity
        }
        guard let minIndent = indents.min(), let maxIndent = indents.max() else {
            return Double.infinity
        }
        return Double(maxIndent - minIndent)
    }

    // MARK: - Low-Level Helpers

    /// Absorb any leading `\t` or spaces that appear **after** the <sN>/<tN> tag
    /// into the tag itself, removing those characters from the content.
    /// - Assumes lines are already unified to `fileIndentType`.
    private static func absorbLeakedLeadingIndent(
        in lines: [String],
        fileIndentType: String,
        indentUnit: Int
    ) -> [String] {
        guard !lines.isEmpty else { return lines }
        return lines.map { absorbLeakedLeadingIndent(in: $0, fileIndentType: fileIndentType, indentUnit: indentUnit) }
    }

    private static func absorbLeakedLeadingIndent(
        in line: String,
        fileIndentType: String,
        indentUnit: Int
    ) -> String {
        // Extract current tag + content
        let content = String.removeIndentationTag(line)
        if content.isEmpty {
            return line
        }

        // Count leaked prefix indentation **in the content** (tabs & spaces).
        var leakedTabs = 0
        var leakedSpaces = 0
        for ch in content {
            if ch == "\t" {
                leakedTabs += 1
            } else if ch == " " {
                leakedSpaces += 1
            } else {
                break
            }
        }

        if leakedTabs == 0, leakedSpaces == 0 {
            return line
        }

        // Compute how much to add to the tag, and how many characters to strip
        // from the content based on the file's indent style.
        var deltaForTag = 0
        var charsToStrip = 0

        if fileIndentType == "s" {
            // 1 tab == `indentUnit` spaces when file uses spaces
            deltaForTag = leakedTabs * indentUnit + leakedSpaces
            charsToStrip = leakedTabs + leakedSpaces
        } else {
            // file uses tabs; consume full groups of spaces as tabs (4:1 convention)
            let spacesPerTab = 4
            deltaForTag = leakedTabs + (leakedSpaces / spacesPerTab)
            charsToStrip = leakedTabs + (leakedSpaces / spacesPerTab) * spacesPerTab
        }

        if deltaForTag == 0, charsToStrip == 0 {
            return line
        }

        // Bump the tag by `deltaForTag`.
        let bumped = String.applyIndentationDelta(to: line, delta: deltaForTag)

        // Strip consumed prefix chars from the bumped content.
        let bumpedContent = String.removeIndentationTag(bumped)
        let strippedContent = String(bumpedContent.dropFirst(charsToStrip))

        // Reconstruct using the bumped tag.
        let (t, c) = String.getIndentationEncoding(from: bumped)
        return "<\(t)\(c)>" + strippedContent
    }

    private static func gatherComparableLinePairs(
        oldCache: IndentCache,
        searchCache: IndentCache
    ) -> [(oldIndent: Int, searchIndent: Int)] {
        let count = min(oldCache.rawLines.count, searchCache.rawLines.count)
        if count == 0 {
            return []
        }

        let step = max(count / max(1, IndentationConfig.maxLinePairs), 1)
        var pairs: [(Int, Int)] = []

        for i in stride(from: 0, to: count, by: step) {
            let oldTrim = oldCache.trimmedLines[i]
            let searchTrim = searchCache.trimmedLines[i]
            guard !oldTrim.isEmpty, !searchTrim.isEmpty else { continue }
            let oldIndent = oldCache.indentLevels[i]
            let searchIndent = searchCache.indentLevels[i]
            pairs.append((oldIndent, searchIndent))
        }

        return pairs
    }

    private static func filterOutliers(deltas: [Int]) -> [Int] {
        guard !deltas.isEmpty else { return [] }

        let medianVal = Double(computeMedian(of: deltas))
        let absDeviations = deltas.map { abs(Double($0) - medianVal) }

        let computedMAD = computeMedianDouble(of: absDeviations)
        let devMedian = max(computedMAD, 1.0)

        let threshold = devMedian * OUTLIER_MULTIPLIER
        if shouldLogIndentDebug() {
            print("[IndentCorrection] Outlier filter => median=\(medianVal), MAD=\(devMedian), threshold=\(threshold)")
        }

        let result = deltas.filter {
            let dist = abs(Double($0) - medianVal)
            return dist <= threshold
        }
        if shouldLogIndentDebug(), result.count < deltas.count {
            print("[IndentCorrection] Filtered out \(deltas.count - result.count) outlier(s).")
        }
        return result
    }

    private static func computeMedian(of values: [Int]) -> Int {
        let sortedVals = values.sorted()
        let c = sortedVals.count
        if c == 0 {
            return 0
        }
        if c % 2 == 1 {
            return sortedVals[c / 2]
        } else {
            let m1 = sortedVals[c / 2 - 1]
            let m2 = sortedVals[c / 2]
            return (m1 + m2) / 2
        }
    }

    private static func computeMedianDouble(of values: [Double]) -> Double {
        let sortedVals = values.sorted()
        let c = sortedVals.count
        if c == 0 {
            return 0.0
        }
        if c % 2 == 1 {
            return sortedVals[c / 2]
        } else {
            let m1 = sortedVals[c / 2 - 1]
            let m2 = sortedVals[c / 2]
            return (m1 + m2) / 2.0
        }
    }

    private static func applyIndentDelta(_ line: String, delta: Int) -> String {
        String.applyIndentationDelta(to: line, delta: delta)
    }

    private static func isValidIndentCandidate(_ lines: [String]) -> Bool {
        for line in lines {
            let indent = String.getIndentationLevel(from: line)
            // If negative or huge, discard
            if indent < 0 || indent > 999 {
                return false
            }
        }
        return true
    }

    private static func effectiveMaxShift(forCache cache: IndentCache) -> Int {
        // For tabs, treat each tab as 4 spaces for shift limiting
        let defaultMaxShift = MAX_SHIFT
        // Calculate the minimum indent in the old block
        let minIndent = cache.indentLevels.min() ?? 0

        // Soft limit: larger of default max or the old block's minimum indent
        return max(defaultMaxShift, minIndent)
    }

    // MARK: - Shape Guard (preserve relative indent structure)

    /// Compute adjacent indentation differences (line[i] - line[i-1]).
    private static func adjacentDiffs(_ levels: [Int]) -> [Int] {
        guard levels.count > 1 else { return [] }
        var diffs: [Int] = []
        diffs.reserveCapacity(levels.count - 1)
        for i in 1 ..< levels.count {
            diffs.append(levels[i] - levels[i - 1])
        }
        return diffs
    }

    /// Check that the candidate preserves the "shape" of indentation:
    /// - limits how many adjacent-edge sign flips occur,
    /// - and caps per-edge change magnitude.
    private static func passesIndentShapeGuard(
        original: IndentCache,
        transformed: IndentCache,
        baseIndentUnit: Int
    ) -> Bool {
        let flipsTolerance = IndentationConfig.shapeFlipTolerance
        let magnitudeLimit = max(2, Int(Double(baseIndentUnit) * IndentationConfig.shapeEdgeMagnitudeMultiplier))

        let orig = adjacentDiffs(original.indentLevels)
        let now = adjacentDiffs(transformed.indentLevels)
        let m = min(orig.count, now.count)
        if m == 0 {
            return true
        } // nothing to compare

        var flips = 0
        var largeChanges = 0

        @inline(__always) func sign(_ v: Int) -> Int {
            if v > 0 {
                return 1
            }
            if v < 0 {
                return -1
            }
            return 0
        }

        for i in 0 ..< m {
            let o = orig[i]
            let n = now[i]
            if sign(o) != 0, sign(n) != 0, sign(o) != sign(n) {
                flips += 1
            }
            if abs(n - o) > magnitudeLimit {
                largeChanges += 1
            }
        }

        let flipRatio = Double(flips) / Double(m)
        if flipRatio > flipsTolerance {
            return false
        }
        if largeChanges > 0 {
            return false
        }
        return true
    }

    // MARK: - Debug Logging

    static func shouldLogIndentDebug() -> Bool {
        false
    }
}
