import CryptoKit
import Foundation

package enum SliceRebaseEngine {
    package struct Result {
        package let rebased: [LineRange]
        package let dropped: [LineRange]
        package let didChange: Bool

        package init(rebased: [LineRange], dropped: [LineRange], didChange: Bool) {
            self.rebased = rebased
            self.dropped = dropped
            self.didChange = didChange
        }
    }

    private struct RangeKey: Hashable {
        let start: Int
        let end: Int
    }

    private struct FastPathResult {
        let rebased: [LineRange]
        let unresolved: [LineRange]
    }

    package static func rebase(
        oldText: String?,
        newText: String,
        oldRanges: [LineRange],
        anchors: [SliceAnchor]?
    ) -> Result {
        let normalizedOld = SliceRangeMath.normalize(oldRanges)
        guard !normalizedOld.isEmpty else {
            return Result(rebased: [], dropped: [], didChange: false)
        }

        let newLines = lines(from: newText)
        guard !newLines.isEmpty else {
            return Result(rebased: [], dropped: normalizedOld, didChange: true)
        }

        // P0 fix: Only trust oldText for fast-path / anchor generation when it
        // actually differs from newText.  When they're equal the "old" snapshot
        // may have been overwritten by an already-updated cache, making the
        // fast-path produce delta=0 and short-circuiting before anchors can
        // correct the line numbers.
        let oldTextIsUsable: Bool = {
            guard let oldText else { return false }
            return oldText != newText
        }()

        var rebased: [LineRange] = []
        var unresolved = normalizedOld

        if oldTextIsUsable, let oldText {
            let oldLines = lines(from: oldText)
            let clamped = clamp(normalizedOld, to: oldLines.count)
            let fastResult = fastSingleDeltaRebase(oldLines: oldLines, newLines: newLines, ranges: clamped)
            rebased = fastResult.rebased
            unresolved = fastResult.unresolved
        }

        // Only early-return when the fast-path ran with trustworthy old text.
        // When oldText was unusable we must still attempt anchor-based mapping.
        if unresolved.isEmpty, oldTextIsUsable {
            let normalizedRebased = SliceRangeMath.normalize(rebased)
            return Result(
                rebased: normalizedRebased,
                dropped: [],
                didChange: normalizedRebased != normalizedOld
            )
        }

        var anchorMap: [RangeKey: SliceAnchor] = [:]
        if let anchors {
            for anchor in anchors {
                let key = RangeKey(start: anchor.range.start, end: anchor.range.end)
                anchorMap[key] = anchor
            }
        }
        if anchorMap.isEmpty, oldTextIsUsable, let oldText {
            let generated = buildAnchors(content: oldText, ranges: normalizedOld)
            for anchor in generated {
                let key = RangeKey(start: anchor.range.start, end: anchor.range.end)
                anchorMap[key] = anchor
            }
        }

        var dropped: [LineRange] = []
        for range in unresolved {
            let key = RangeKey(start: range.start, end: range.end)
            guard let anchor = anchorMap[key] else {
                dropped.append(range)
                continue
            }
            if let mapped = rebaseWithAnchor(range: range, anchor: anchor, newLines: newLines) {
                rebased.append(mapped)
            } else {
                dropped.append(range)
            }
        }

        let normalizedRebased = SliceRangeMath.normalize(rebased)
        let didChange = (normalizedRebased != normalizedOld) || !dropped.isEmpty
        return Result(
            rebased: normalizedRebased,
            dropped: dropped,
            didChange: didChange
        )
    }

    package static func buildAnchors(content: String, ranges: [LineRange], maxSignatureLines: Int = 3) -> [SliceAnchor] {
        let normalized = SliceRangeMath.normalize(ranges)
        guard !normalized.isEmpty else { return [] }

        let contentLines = lines(from: content)
        guard !contentLines.isEmpty else { return [] }

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
                let endIndex = startIndex + window
                let slice = contentLines[startIndex ..< endIndex]
                return signature(for: Array(slice))
            }
            let endSignatures: [String] = (1 ... upperWindow).map { window in
                let startIndex = range.end - window
                let endIndex = range.end
                let slice = contentLines[startIndex ..< endIndex]
                return signature(for: Array(slice))
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

    private static func fastSingleDeltaRebase(
        oldLines: [String],
        newLines: [String],
        ranges: [LineRange]
    ) -> FastPathResult {
        guard !ranges.isEmpty else {
            return FastPathResult(rebased: [], unresolved: [])
        }

        let oldCount = oldLines.count
        let newCount = newLines.count

        var prefix = 0
        let prefixLimit = min(oldCount, newCount)
        while prefix < prefixLimit, oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < (oldCount - prefix),
              suffix < (newCount - prefix),
              oldLines[oldCount - 1 - suffix] == newLines[newCount - 1 - suffix]
        {
            suffix += 1
        }

        let oldMiddleStart = prefix + 1
        let oldMiddleEnd = oldCount - suffix
        let oldMiddleCount = max(0, oldMiddleEnd - oldMiddleStart + 1)
        let newMiddleCount = max(0, (newCount - suffix) - (prefix + 1) + 1)
        let delta = newMiddleCount - oldMiddleCount
        let headEnd = oldMiddleStart - 1
        let tailStart = oldMiddleEnd + 1

        var rebased: [LineRange] = []
        var unresolved: [LineRange] = []
        rebased.reserveCapacity(ranges.count)
        unresolved.reserveCapacity(ranges.count)

        for range in ranges {
            if range.end <= headEnd {
                if let mapped = shiftAndClamp(range, by: 0, newLineCount: newCount) {
                    rebased.append(mapped)
                } else {
                    unresolved.append(range)
                }
            } else if range.start >= tailStart {
                if let mapped = shiftAndClamp(range, by: delta, newLineCount: newCount) {
                    rebased.append(mapped)
                } else {
                    unresolved.append(range)
                }
            } else {
                unresolved.append(range)
            }
        }

        return FastPathResult(rebased: rebased, unresolved: unresolved)
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
            newLines: newLines,
            boundary: .start
        )
        let endCandidates = boundaryCandidates(
            signatures: anchor.endSignature,
            newLines: newLines,
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
            let end = start + targetLength - 1
            return clampedRange(
                start: start,
                end: end,
                newLineCount: newLines.count,
                description: range.description
            )
        }

        if let end = nearest(endCandidates, to: predictedEnd) {
            let start = end - targetLength + 1
            return clampedRange(
                start: start,
                end: end,
                newLineCount: newLines.count,
                description: range.description
            )
        }

        return nil
    }

    private enum BoundaryKind {
        case start
        case end
    }

    private static func boundaryCandidates(
        signatures: [String],
        newLines: [String],
        boundary: BoundaryKind
    ) -> [Int] {
        guard !signatures.isEmpty, !newLines.isEmpty else { return [] }

        for window in stride(from: signatures.count, through: 1, by: -1) {
            let signatureIndex = window - 1
            guard signatureIndex < signatures.count else { continue }
            let expected = signatures[signatureIndex]
            if expected.isEmpty { continue }
            if window > newLines.count { continue }

            var matches: [Int] = []
            matches.reserveCapacity(4)

            for start in 0 ... (newLines.count - window) {
                let end = start + window
                let windowSignature = signature(for: Array(newLines[start ..< end]))
                guard windowSignature == expected else { continue }
                switch boundary {
                case .start:
                    matches.append(start + 1)
                case .end:
                    matches.append(end)
                }
            }

            if !matches.isEmpty {
                return matches
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

    private static func shiftAndClamp(_ range: LineRange, by delta: Int, newLineCount: Int) -> LineRange? {
        guard newLineCount > 0 else { return nil }
        let shiftedStart = range.start + delta
        let shiftedEnd = range.end + delta
        return clampedRange(
            start: shiftedStart,
            end: shiftedEnd,
            newLineCount: newLineCount,
            description: range.description
        )
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
        guard clampedEnd >= clampedStart else { return nil }
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
        let payload = lines.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
