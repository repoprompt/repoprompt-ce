import CryptoKit
import Foundation

enum SliceRebaseEngine {
    struct Result {
        let rebased: [LineRange]
        let dropped: [LineRange]
        let didChange: Bool
        let isStale: Bool
    }

    private struct RangeKey: Hashable {
        let start: Int
        let end: Int
    }

    /// Zero-based, half-open coordinates in the pre- and post-edit documents.
    private struct EditRegion {
        let oldStart: Int
        let oldEnd: Int
        let newStart: Int
        let newEnd: Int
    }

    private enum BoundaryAffinity {
        case rangeStart
        case rangeEnd
    }

    private enum BoundaryKind {
        case start
        case end
    }

    /// Caps Myers trace growth for a replaced middle while preserving ordinary sparse edits.
    /// Larger edit distances fall back to one conservative replacement region.
    private static let maximumSparseEditDistance = 512

    static func rebase(
        oldText: String?,
        newText: String,
        oldRanges: [LineRange],
        anchors: [SliceAnchor]?
    ) -> Result {
        let normalizedOld = SliceRangeMath.normalize(oldRanges)
        guard !normalizedOld.isEmpty else {
            return Result(rebased: [], dropped: [], didChange: false, isStale: false)
        }

        let newLines = lines(from: newText)
        guard !newLines.isEmpty else {
            return Result(rebased: [], dropped: normalizedOld, didChange: true, isStale: false)
        }

        if let oldText, oldText != newText {
            let oldLines = lines(from: oldText)
            guard !oldLines.isEmpty else {
                return staleResult(normalizedOld)
            }

            let clampedOld = clamp(normalizedOld, to: oldLines.count)
            guard anchorsMatchOldLines(anchors, oldLines: oldLines, ranges: clampedOld) else {
                return staleResult(normalizedOld)
            }

            let regions = editRegions(oldLines: oldLines, newLines: newLines)
            let mapped = clampedOld.compactMap {
                mapRange($0, through: regions, newLineCount: newLines.count)
            }
            guard mapped.count == clampedOld.count else {
                return staleResult(normalizedOld)
            }

            let normalizedMapped = SliceRangeMath.normalize(mapped)
            return Result(
                rebased: normalizedMapped,
                dropped: [],
                didChange: normalizedMapped != normalizedOld,
                isStale: false
            )
        }

        guard let mapped = rebaseWithAnchors(
            ranges: normalizedOld,
            anchors: anchors,
            newLines: newLines
        ) else {
            return staleResult(normalizedOld)
        }

        let normalizedMapped = SliceRangeMath.normalize(mapped)
        return Result(
            rebased: normalizedMapped,
            dropped: [],
            didChange: normalizedMapped != normalizedOld,
            isStale: false
        )
    }

    static func buildAnchors(content: String, ranges: [LineRange], maxSignatureLines: Int = 3) -> [SliceAnchor] {
        buildAnchors(lines: lines(from: content), ranges: ranges, maxSignatureLines: maxSignatureLines)
    }

    private static func buildAnchors(
        lines contentLines: [String],
        ranges: [LineRange],
        maxSignatureLines: Int
    ) -> [SliceAnchor] {
        let normalized = SliceRangeMath.normalize(ranges)
        guard !normalized.isEmpty, !contentLines.isEmpty else { return [] }

        let clamped = clamp(normalized, to: contentLines.count)
        guard !clamped.isEmpty else { return [] }

        let maxWindow = max(1, maxSignatureLines)
        var anchors: [SliceAnchor] = []
        anchors.reserveCapacity(clamped.count)

        for range in clamped {
            let length = max(1, range.end - range.start + 1)
            let upperWindow = min(maxWindow, length)
            let startSignatures: [String] = (1 ... upperWindow).map { window in
                let startIndex = range.start - 1
                return signature(for: Array(contentLines[startIndex ..< (startIndex + window)]))
            }
            let endSignatures: [String] = (1 ... upperWindow).map { window in
                let startIndex = range.end - window
                return signature(for: Array(contentLines[startIndex ..< range.end]))
            }
            anchors.append(
                SliceAnchor(
                    range: range,
                    startSignature: startSignatures,
                    endSignature: endSignatures
                )
            )
        }

        return anchors
    }

    private static func staleResult(_ ranges: [LineRange]) -> Result {
        Result(rebased: ranges, dropped: [], didChange: false, isStale: true)
    }

    private static func anchorsMatchOldLines(
        _ anchors: [SliceAnchor]?,
        oldLines: [String],
        ranges: [LineRange]
    ) -> Bool {
        guard let anchors, !anchors.isEmpty else { return true }

        var supplied: [RangeKey: SliceAnchor] = [:]
        for anchor in anchors {
            supplied[RangeKey(start: anchor.range.start, end: anchor.range.end)] = anchor
        }
        var generated: [RangeKey: SliceAnchor] = [:]
        for anchor in buildAnchors(lines: oldLines, ranges: ranges, maxSignatureLines: 3) {
            generated[RangeKey(start: anchor.range.start, end: anchor.range.end)] = anchor
        }

        guard supplied.count == ranges.count else { return false }
        for range in ranges {
            let key = RangeKey(start: range.start, end: range.end)
            guard let suppliedAnchor = supplied[key], generated[key] == suppliedAnchor else {
                return false
            }
        }
        return true
    }

    private static func editRegions(oldLines: [String], newLines: [String]) -> [EditRegion] {
        var prefix = 0
        let prefixLimit = min(oldLines.count, newLines.count)
        while prefix < prefixLimit, oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < oldLines.count - prefix,
              suffix < newLines.count - prefix,
              oldLines[oldLines.count - suffix - 1] == newLines[newLines.count - suffix - 1]
        {
            suffix += 1
        }

        let oldMiddle = Array(oldLines[prefix ..< (oldLines.count - suffix)])
        let newMiddle = Array(newLines[prefix ..< (newLines.count - suffix)])
        guard !oldMiddle.isEmpty || !newMiddle.isEmpty else { return [] }

        let edits = DiffEditCreator.myersDiff(
            oldLines: oldMiddle,
            newLines: newMiddle,
            maximumEditDistance: maximumSparseEditDistance
        )
        guard !edits.isEmpty else {
            return [EditRegion(
                oldStart: prefix,
                oldEnd: oldLines.count - suffix,
                newStart: prefix,
                newEnd: newLines.count - suffix
            )]
        }

        var regions: [EditRegion] = []
        var oldCursor = prefix
        var newCursor = prefix
        var regionOldStart: Int?
        var regionNewStart: Int?

        func flushRegion() {
            guard let oldStart = regionOldStart, let newStart = regionNewStart else { return }
            regions.append(EditRegion(
                oldStart: oldStart,
                oldEnd: oldCursor,
                newStart: newStart,
                newEnd: newCursor
            ))
            regionOldStart = nil
            regionNewStart = nil
        }

        for edit in edits {
            switch edit.type {
            case .equal:
                flushRegion()
                oldCursor += edit.lines.count
                newCursor += edit.lines.count
            case .deletion:
                if regionOldStart == nil {
                    regionOldStart = oldCursor
                    regionNewStart = newCursor
                }
                oldCursor += edit.lines.count
            case .addition:
                if regionOldStart == nil {
                    regionOldStart = oldCursor
                    regionNewStart = newCursor
                }
                newCursor += edit.lines.count
            }
        }
        flushRegion()
        return regions
    }

    private static func mapRange(
        _ range: LineRange,
        through regions: [EditRegion],
        newLineCount: Int
    ) -> LineRange? {
        guard newLineCount > 0 else { return nil }

        let oldStartBoundary = range.start - 1
        let oldEndBoundary = range.end
        let newStartBoundary = mapBoundary(
            oldStartBoundary,
            through: regions,
            affinity: .rangeStart
        )
        let newEndBoundary = mapBoundary(
            oldEndBoundary,
            through: regions,
            affinity: .rangeEnd
        )

        if newStartBoundary < newEndBoundary {
            return clampedRange(
                start: newStartBoundary + 1,
                end: newEndBoundary,
                newLineCount: newLineCount,
                description: range.description
            )
        }

        let anchorLine = newStartBoundary < newLineCount
            ? newStartBoundary + 1
            : newLineCount
        return LineRange(start: anchorLine, end: anchorLine, description: range.description)
    }

    private static func mapBoundary(
        _ position: Int,
        through regions: [EditRegion],
        affinity: BoundaryAffinity
    ) -> Int {
        var delta = 0

        for region in regions {
            if position < region.oldStart {
                return position + delta
            }
            if position > region.oldEnd {
                delta = region.newEnd - region.oldEnd
                continue
            }

            if region.oldStart == region.oldEnd {
                return affinity == .rangeStart ? region.newEnd : region.newStart
            }
            if position == region.oldStart {
                return region.newStart
            }
            if position == region.oldEnd {
                return region.newEnd
            }
            return affinity == .rangeStart ? region.newStart : region.newEnd
        }

        return position + delta
    }

    private static func rebaseWithAnchors(
        ranges: [LineRange],
        anchors: [SliceAnchor]?,
        newLines: [String]
    ) -> [LineRange]? {
        guard let anchors, !anchors.isEmpty else { return nil }

        var anchorMap: [RangeKey: SliceAnchor] = [:]
        for anchor in anchors {
            anchorMap[RangeKey(start: anchor.range.start, end: anchor.range.end)] = anchor
        }
        var rebased: [LineRange] = []
        rebased.reserveCapacity(ranges.count)

        for range in ranges {
            let key = RangeKey(start: range.start, end: range.end)
            guard let anchor = anchorMap[key],
                  let mapped = rebaseWithAnchor(range: range, anchor: anchor, newLines: newLines)
            else { return nil }
            rebased.append(mapped)
        }
        return rebased
    }

    private static func rebaseWithAnchor(
        range: LineRange,
        anchor: SliceAnchor,
        newLines: [String]
    ) -> LineRange? {
        let targetLength = max(1, range.end - range.start + 1)
        let predictedStart = range.start
        let predictedEnd = range.end

        let startCandidates = boundaryCandidates(
            signatures: anchor.startSignature,
            contentLines: newLines,
            boundary: .start
        )
        let endCandidates = boundaryCandidates(
            signatures: anchor.endSignature,
            contentLines: newLines,
            boundary: .end
        )

        var bestPair: (start: Int, end: Int, score: Int)?
        for start in startCandidates {
            for end in endCandidates where end >= start {
                let score = abs(start - predictedStart) + abs(end - predictedEnd)
                if let current = bestPair {
                    if score < current.score {
                        bestPair = (start, end, score)
                    }
                } else {
                    bestPair = (start, end, score)
                }
            }
        }

        if let pair = bestPair {
            return clampedRange(
                start: pair.start,
                end: pair.end,
                newLineCount: newLines.count,
                description: range.description
            )
        }

        if let start = nearest(startCandidates, to: predictedStart) {
            return clampedRange(
                start: start,
                end: start + targetLength - 1,
                newLineCount: newLines.count,
                description: range.description
            )
        }

        if let end = nearest(endCandidates, to: predictedEnd) {
            return clampedRange(
                start: end - targetLength + 1,
                end: end,
                newLineCount: newLines.count,
                description: range.description
            )
        }

        return nil
    }

    private static func boundaryCandidates(
        signatures: [String],
        contentLines: [String],
        boundary: BoundaryKind
    ) -> [Int] {
        guard !signatures.isEmpty, !contentLines.isEmpty else { return [] }

        let largestWindow = min(signatures.count, contentLines.count)
        for window in stride(from: largestWindow, through: 1, by: -1) {
            let expected = signatures[window - 1]
            guard !expected.isEmpty else { continue }

            var candidates: [Int] = []
            for start in 0 ... (contentLines.count - window) {
                let digest = signature(for: Array(contentLines[start ..< (start + window)]))
                guard digest == expected else { continue }
                switch boundary {
                case .start:
                    candidates.append(start + 1)
                case .end:
                    candidates.append(start + window)
                }
            }
            if !candidates.isEmpty {
                return candidates
            }
        }

        return []
    }

    private static func nearest(_ values: [Int], to target: Int) -> Int? {
        guard let first = values.first else { return nil }
        var best = first
        var bestDistance = abs(first - target)
        for value in values.dropFirst() {
            let distance = abs(value - target)
            if distance < bestDistance {
                bestDistance = distance
                best = value
            }
        }
        return best
    }

    private static func clampedRange(
        start: Int,
        end: Int,
        newLineCount: Int,
        description: String?
    ) -> LineRange? {
        guard newLineCount > 0 else { return nil }
        let clampedStart = min(max(1, start), newLineCount)
        let clampedEnd = min(max(clampedStart, end), newLineCount)
        return LineRange(start: clampedStart, end: clampedEnd, description: description)
    }

    private static func clamp(_ ranges: [LineRange], to lineCount: Int) -> [LineRange] {
        guard lineCount > 0 else { return [] }
        let normalized = SliceRangeMath.normalize(ranges)
        guard !normalized.isEmpty else { return [] }

        var clamped: [LineRange] = []
        clamped.reserveCapacity(normalized.count)

        for range in normalized {
            let start = min(max(1, range.start), lineCount)
            let end = min(max(start, range.end), lineCount)
            clamped.append(LineRange(start: start, end: end, description: range.description))
        }
        return SliceRangeMath.normalize(clamped)
    }

    private static func lines(from content: String) -> [String] {
        String.splitContentPreservingAllLineEndings(content).map(\.line)
    }

    private static func signature(for lines: [String]) -> String {
        SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
