package struct WorkspaceRootSetKey: Hashable {
    package let normalizedPaths: [String]

    package var isEmpty: Bool {
        normalizedPaths.isEmpty
    }

    package init(paths: [String]) {
        var canonicalByLowercasedPath: [String: String] = [:]
        for rawPath in paths {
            guard let exactRootPath = WorkspaceExactRootPath(rawPath) else { continue }
            if let existing = canonicalByLowercasedPath[exactRootPath.comparisonPath] {
                canonicalByLowercasedPath[exactRootPath.comparisonPath] = min(
                    existing,
                    exactRootPath.normalizedPath
                )
            } else {
                canonicalByLowercasedPath[exactRootPath.comparisonPath] = exactRootPath.normalizedPath
            }
        }
        normalizedPaths = canonicalByLowercasedPath.values.sorted {
            let lhsKey = $0.lowercased()
            let rhsKey = $1.lowercased()
            if lhsKey != rhsKey {
                return lhsKey < rhsKey
            }
            return $0 < $1
        }
    }

    package static func == (lhs: WorkspaceRootSetKey, rhs: WorkspaceRootSetKey) -> Bool {
        lhs.normalizedPaths.map { $0.lowercased() } == rhs.normalizedPaths.map { $0.lowercased() }
    }

    package func hash(into hasher: inout Hasher) {
        for path in normalizedPaths {
            hasher.combine(path.lowercased())
        }
    }
}
