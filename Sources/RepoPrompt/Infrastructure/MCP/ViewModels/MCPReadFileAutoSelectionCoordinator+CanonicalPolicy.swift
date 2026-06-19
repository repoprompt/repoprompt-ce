import Foundation

extension MCPReadFileAutoSelectionCoordinator {
    enum Intent: Equatable {
        case full(paths: [String])
        case slices(entries: [WorkspaceSelectionSliceInput])
    }

    /// Exact normalized physical coverage requested by one complete canonical batch.
    /// Logical/display paths remain in `Intent`; this identity is carried separately so
    /// equivalent ordering/coalescing compares equal without ever projecting the fast path.
    struct CoverageIdentity: Hashable {
        struct Slice: Hashable {
            let path: String
            let ranges: [LineRange]
        }

        let fullPaths: [String]
        let slices: [Slice]

        init?(intent: Intent, resolvedPaths: [String]) {
            var fullPathKeys = Set<String>()
            var rangesByPath: [String: [LineRange]] = [:]

            switch intent {
            case let .full(paths):
                guard paths.count == resolvedPaths.count else { return nil }
                for resolvedPath in resolvedPaths {
                    guard let path = Self.normalizedPhysicalPath(resolvedPath) else { return nil }
                    fullPathKeys.insert(path)
                }
            case let .slices(entries):
                guard entries.count == resolvedPaths.count else { return nil }
                for (entry, resolvedPath) in zip(entries, resolvedPaths) {
                    guard let path = Self.normalizedPhysicalPath(resolvedPath) else { return nil }
                    let ranges = SliceRangeMath.normalize(entry.ranges).map {
                        LineRange(start: $0.start, end: $0.end)
                    }
                    guard !ranges.isEmpty else { return nil }
                    rangesByPath[path, default: []].append(contentsOf: ranges)
                }
            }

            self.init(fullPathKeys: fullPathKeys, rangesByPath: rangesByPath)
        }

        private init(fullPathKeys: Set<String>, rangesByPath: [String: [LineRange]]) {
            fullPaths = fullPathKeys.sorted()
            slices = rangesByPath.keys
                .filter { !fullPathKeys.contains($0) }
                .sorted()
                .compactMap { path in
                    let ranges = SliceRangeMath.normalize(rangesByPath[path] ?? []).map {
                        LineRange(start: $0.start, end: $0.end)
                    }
                    return ranges.isEmpty ? nil : Slice(path: path, ranges: ranges)
                }
        }

        func merging(_ other: CoverageIdentity) -> CoverageIdentity {
            var fullPathKeys = Set(fullPaths)
            fullPathKeys.formUnion(other.fullPaths)
            var rangesByPath = Dictionary(uniqueKeysWithValues: slices.map { ($0.path, $0.ranges) })
            for slice in other.slices {
                rangesByPath[slice.path, default: []].append(contentsOf: slice.ranges)
            }
            return CoverageIdentity(fullPathKeys: fullPathKeys, rangesByPath: rangesByPath)
        }

        func isCovered(by physicalSelection: StoredSelection) -> Bool {
            let selectedPathKeys = Set(StoredSelectionPathNormalization.standardizedPaths(physicalSelection.selectedPaths))
            let normalizedSlices = StoredSelectionPathNormalization.standardizedSlices(physicalSelection.slices)

            for path in fullPaths {
                guard selectedPathKeys.contains(path), normalizedSlices[path]?.isEmpty != false else { return false }
            }
            for slice in slices {
                guard selectedPathKeys.contains(slice.path) else { return false }
                guard normalizedSlices[slice.path]?.isEmpty != false || Self.ranges(slice.ranges, areCoveredBy: normalizedSlices[slice.path] ?? []) else {
                    return false
                }
            }
            return true
        }

        private static func ranges(_ requested: [LineRange], areCoveredBy selected: [LineRange]) -> Bool {
            let selected = SliceRangeMath.normalize(selected)
            return requested.allSatisfy { request in
                selected.contains { $0.start <= request.start && $0.end >= request.end }
            }
        }

        private static func normalizedPhysicalPath(_ rawPath: String) -> String? {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("/") else { return nil }
            return StandardizedPath.absolute((trimmed as NSString).expandingTildeInPath)
        }
    }

    static func authoritativeSelection(
        _ expected: StoredSelection,
        isPreservedBy candidate: StoredSelection
    ) -> Bool {
        let expectedSelectedPaths = Set(StoredSelectionPathNormalization.standardizedPaths(expected.selectedPaths))
        let candidateSelectedPaths = Set(StoredSelectionPathNormalization.standardizedPaths(candidate.selectedPaths))
        guard expectedSelectedPaths.isSubset(of: candidateSelectedPaths) else { return false }

        let expectedAutoCodemapPaths = Set(StoredSelectionPathNormalization.standardizedPaths(expected.autoCodemapPaths))
        let candidateAutoCodemapPaths = Set(StoredSelectionPathNormalization.standardizedPaths(candidate.autoCodemapPaths))
        guard expectedAutoCodemapPaths.isSubset(of: candidateAutoCodemapPaths),
              expected.codemapAutoEnabled == candidate.codemapAutoEnabled
        else { return false }

        let expectedSlices = StoredSelectionPathNormalization.standardizedSlices(expected.slices).mapValues {
            SliceRangeMath.normalize($0)
        }
        let candidateSlices = StoredSelectionPathNormalization.standardizedSlices(candidate.slices).mapValues {
            SliceRangeMath.normalize($0)
        }

        for path in expectedSelectedPaths {
            let expectedRanges = expectedSlices[path] ?? []
            let candidateRanges = candidateSlices[path] ?? []
            if expectedRanges.isEmpty {
                guard candidateRanges.isEmpty else { return false }
            } else if !candidateRanges.isEmpty {
                guard ranges(expectedRanges, areCoveredBy: candidateRanges) else { return false }
            }
        }

        for (path, expectedRanges) in expectedSlices where !expectedRanges.isEmpty {
            guard candidateSelectedPaths.contains(path) else { return false }
            let candidateRanges = candidateSlices[path] ?? []
            if !candidateRanges.isEmpty,
               !ranges(expectedRanges, areCoveredBy: candidateRanges)
            {
                return false
            }
        }
        return true
    }

    private static func ranges(_ expected: [LineRange], areCoveredBy candidate: [LineRange]) -> Bool {
        let candidate = SliceRangeMath.normalize(candidate)
        return SliceRangeMath.normalize(expected).allSatisfy { expectedRange in
            candidate.contains { $0.start <= expectedRange.start && $0.end >= expectedRange.end }
        }
    }

    struct CanonicalBatch: Equatable {
        private(set) var fullPaths: [String] = []
        private(set) var sliceEntries: [WorkspaceSelectionSliceInput] = []
        private(set) var coverageIdentity: CoverageIdentity?

        private var fullPathKeys = Set<String>()
        private var slicePathOrder: [String] = []
        private var sliceRangesByPath: [String: [LineRange]] = [:]
        private var originalSlicePathByKey: [String: String] = [:]
        private var coveragePermitted: Bool

        init(intent: Intent, coverageIdentity: CoverageIdentity? = nil) {
            self.coverageIdentity = nil
            coveragePermitted = coverageIdentity != nil
            merge(intent, coverageIdentity: coverageIdentity)
        }

        mutating func merge(_ intent: Intent, coverageIdentity incomingCoverageIdentity: CoverageIdentity? = nil) {
            if coveragePermitted {
                if let incomingCoverageIdentity {
                    coverageIdentity = coverageIdentity?.merging(incomingCoverageIdentity) ?? incomingCoverageIdentity
                } else {
                    coveragePermitted = false
                    coverageIdentity = nil
                }
            }
            switch intent {
            case let .full(paths):
                for rawPath in paths {
                    guard let path = Self.trimmed(rawPath),
                          let key = StoredSelectionPathNormalization.standardizedPath(path)
                    else { continue }
                    if fullPathKeys.insert(key).inserted {
                        fullPaths.append(path)
                    }
                    sliceRangesByPath.removeValue(forKey: key)
                    originalSlicePathByKey.removeValue(forKey: key)
                }
            case let .slices(entries):
                for entry in entries {
                    guard let path = Self.trimmed(entry.path),
                          let key = StoredSelectionPathNormalization.standardizedPath(path),
                          !fullPathKeys.contains(key)
                    else { continue }
                    if originalSlicePathByKey[key] == nil {
                        slicePathOrder.append(key)
                        originalSlicePathByKey[key] = path
                    }
                    sliceRangesByPath[key, default: []].append(contentsOf: entry.ranges)
                }
            }
            rebuildSliceEntries()
        }

        private mutating func rebuildSliceEntries() {
            sliceEntries = slicePathOrder.compactMap { key in
                guard !fullPathKeys.contains(key),
                      let path = originalSlicePathByKey[key]
                else { return nil }
                let ranges = SliceRangeMath.normalize(sliceRangesByPath[key] ?? [])
                guard !ranges.isEmpty else { return nil }
                return WorkspaceSelectionSliceInput(path: path, ranges: ranges)
            }
        }

        private static func trimmed(_ rawPath: String) -> String? {
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        }
    }
}
