import Foundation

package enum StoredSelectionPathNormalization {
    /// Canonicalizes stored selection path state.
    /// Policy: canonical absolute keys win over legacy/raw variants for the same file.
    package static func standardizedPath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return StandardizedPath.absolute(trimmed)
    }

    package static func standardizedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(paths.count)
        for rawPath in paths {
            guard let standardized = standardizedPath(rawPath), seen.insert(standardized).inserted else { continue }
            result.append(standardized)
        }
        return result
    }

    package static func standardizedSlices(_ slices: [String: [LineRange]]) -> [String: [LineRange]] {
        guard !slices.isEmpty else { return [:] }

        var canonical: [String: [LineRange]] = [:]
        var legacyFallbacks: [String: [LineRange]] = [:]

        for (rawPath, ranges) in slices where !ranges.isEmpty {
            guard let standardized = standardizedPath(rawPath) else { continue }
            if rawPath == standardized {
                canonical[standardized] = ranges
                continue
            }

            if var existing = legacyFallbacks[standardized] {
                existing.append(contentsOf: ranges)
                legacyFallbacks[standardized] = SliceRangeMath.normalize(existing)
            } else {
                legacyFallbacks[standardized] = ranges
            }
        }

        for (path, ranges) in legacyFallbacks where canonical[path] == nil {
            canonical[path] = ranges
        }
        return canonical
    }
}
