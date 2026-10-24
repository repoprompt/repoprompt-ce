import Foundation

package enum SliceRangeMath {
    package static func normalize(_ ranges: [LineRange]) -> [LineRange] {
        let filtered = ranges.filter { $0.start <= $0.end }
        guard !filtered.isEmpty else { return [] }
        func mergedDescription(_ lhs: LineRange, _ rhs: LineRange) -> String? {
            if let lhsDesc = lhs.description, let rhsDesc = rhs.description, lhsDesc != rhsDesc {
                return lhsDesc + "; " + rhsDesc
            }
            return lhs.description ?? rhs.description
        }
        let sorted = filtered.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.end < rhs.end
            }
            return lhs.start < rhs.start
        }
        var merged: [LineRange] = []
        for range in sorted {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            if range.start <= last.end + 1 {
                let combinedEnd = max(last.end, range.end)
                merged.removeLast()
                let description = mergedDescription(last, range)
                merged.append(LineRange(start: last.start, end: combinedEnd, description: description))
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    package static func coalesce(_ lhs: [LineRange], _ rhs: [LineRange]) -> [LineRange] {
        normalize(lhs + rhs)
    }

    package static func subtract(_ base: [LineRange], removing: [LineRange]) -> [LineRange] {
        let baseNormalized = normalize(base)
        let removingNormalized = normalize(removing)
        guard !baseNormalized.isEmpty, !removingNormalized.isEmpty else {
            return baseNormalized
        }

        var result: [LineRange] = []
        var removalIndex = 0
        let removalCount = removingNormalized.count

        for range in baseNormalized {
            let currentStart = range.start
            let currentEnd = range.end

            while removalIndex < removalCount, removingNormalized[removalIndex].end < currentStart {
                removalIndex += 1
            }

            var index = removalIndex
            var localStart = currentStart

            while index < removalCount {
                let removal = removingNormalized[index]
                if removal.start > currentEnd {
                    break
                }

                if removal.start > localStart {
                    let newEnd = min(removal.start - 1, currentEnd)
                    if newEnd >= localStart {
                        result.append(LineRange(start: localStart, end: newEnd, description: range.description))
                    }
                }

                if removal.end >= currentEnd {
                    localStart = currentEnd + 1
                    break
                } else {
                    localStart = max(localStart, removal.end + 1)
                    index += 1
                }
            }

            if localStart <= currentEnd {
                result.append(LineRange(start: localStart, end: currentEnd, description: range.description))
            }
        }

        return normalize(result)
    }
}
