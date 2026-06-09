import Foundation

package struct WorkspaceSliceSegment: Equatable {
    package let range: LineRange
    package let text: String

    package init(range: LineRange, text: String) {
        self.range = range
        self.text = text
    }
}

package struct WorkspaceSliceAssembly: Equatable {
    package let segments: [WorkspaceSliceSegment]
    package let combinedText: String
    package let totalLines: Int
    package let detectedLineEnding: String
    package let usedRanges: [LineRange]
    package let isFullFile: Bool

    package var totalCharacters: Int {
        combinedText.count
    }

    package init(
        segments: [WorkspaceSliceSegment],
        combinedText: String,
        totalLines: Int,
        detectedLineEnding: String,
        usedRanges: [LineRange],
        isFullFile: Bool
    ) {
        self.segments = segments
        self.combinedText = combinedText
        self.totalLines = totalLines
        self.detectedLineEnding = detectedLineEnding
        self.usedRanges = usedRanges
        self.isFullFile = isFullFile
    }
}

package enum SliceAssemblyBuilder {
    package static func build(from content: String, ranges: [LineRange]?) -> WorkspaceSliceAssembly {
        let pairs = String.splitContentPreservingAllLineEndings(content)
        let (_, detectedEnding) = String.splitContentPreservingLineEndings(content)
        let totalLines = pairs.count

        func fullFileAssembly() -> WorkspaceSliceAssembly {
            let segment: WorkspaceSliceSegment? = {
                if totalLines > 0 || !content.isEmpty {
                    let rangeEnd = totalLines > 0 ? totalLines : 1
                    return WorkspaceSliceSegment(range: LineRange(start: 1, end: rangeEnd), text: content)
                }
                return nil
            }()
            return WorkspaceSliceAssembly(
                segments: segment.map { [$0] } ?? [],
                combinedText: content,
                totalLines: totalLines,
                detectedLineEnding: detectedEnding,
                usedRanges: [],
                isFullFile: true
            )
        }

        guard let ranges, !ranges.isEmpty else {
            return fullFileAssembly()
        }

        let normalized = normalizeSlices(ranges, maxLine: totalLines)
        guard !normalized.isEmpty else {
            return fullFileAssembly()
        }

        var segments: [WorkspaceSliceSegment] = []
        segments.reserveCapacity(normalized.count)
        var combined = String()
        combined.reserveCapacity(content.count)

        for range in normalized {
            let startIndex = max(range.start - 1, 0)
            let endIndex = min(range.end, totalLines)
            guard startIndex < endIndex else { continue }

            let slicePairs = pairs[startIndex ..< endIndex]
            let sliceText = slicePairs.map { $0.line + $0.ending }.joined()
            if !sliceText.isEmpty {
                combined.append(sliceText)
            }
            let clampedRange = LineRange(start: startIndex + 1, end: endIndex, description: range.description)
            segments.append(WorkspaceSliceSegment(range: clampedRange, text: sliceText))
        }

        if segments.isEmpty {
            return fullFileAssembly()
        }

        return WorkspaceSliceAssembly(
            segments: segments,
            combinedText: combined,
            totalLines: totalLines,
            detectedLineEnding: detectedEnding,
            usedRanges: segments.map(\.range),
            isFullFile: false
        )
    }

    private static func normalizeSlices(_ ranges: [LineRange], maxLine: Int) -> [LineRange] {
        guard maxLine > 0 else { return [] }

        var cleaned: [LineRange] = []
        cleaned.reserveCapacity(ranges.count)

        for range in ranges {
            let start = max(1, range.start)
            let end = min(max(start, range.end), maxLine)
            if start > maxLine { continue }
            cleaned.append(LineRange(start: start, end: end, description: range.description))
        }

        if cleaned.isEmpty { return [] }

        cleaned.sort { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.end < rhs.end
            }
            return lhs.start < rhs.start
        }

        var merged: [LineRange] = []
        for range in cleaned {
            if var last = merged.last, range.start <= last.end + 1 {
                let mergedDescription: String? = if let lastDesc = last.description, let rangeDesc = range.description, lastDesc != rangeDesc {
                    lastDesc + "; " + rangeDesc
                } else {
                    last.description ?? range.description
                }
                last = LineRange(start: last.start, end: max(last.end, range.end), description: mergedDescription)
                merged[merged.count - 1] = last
            } else {
                merged.append(range)
            }
        }

        return merged
    }
}
