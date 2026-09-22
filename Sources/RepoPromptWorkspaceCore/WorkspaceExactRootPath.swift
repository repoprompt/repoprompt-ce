import Foundation

package struct WorkspaceExactRootPath: Hashable {
    package let normalizedPath: String
    package let comparisonPath: String

    package init?(_ rawPath: String) {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let normalizedPath = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard !normalizedPath.isEmpty else { return nil }
        self.normalizedPath = normalizedPath
        comparisonPath = normalizedPath.lowercased()
    }

    package static func contains(_ exactRoot: WorkspaceRootSetKey, in rawPaths: [String]) -> Bool {
        guard exactRoot.normalizedPaths.count == 1,
              let expectedPath = exactRoot.normalizedPaths.first
        else { return false }
        let expectedComparisonPath = expectedPath.lowercased()
        return rawPaths.contains {
            WorkspaceExactRootPath($0)?.comparisonPath == expectedComparisonPath
        }
    }

    /// Compares normalized roots with an input that the caller has already canonicalized.
    /// The input is intentionally not normalized here so invalid boundary values remain rejected.
    package static func contains(canonicalComparisonPath: String, in rawPaths: [String]) -> Bool {
        guard !canonicalComparisonPath.isEmpty else { return false }
        return rawPaths.contains {
            WorkspaceExactRootPath($0)?.comparisonPath == canonicalComparisonPath
        }
    }
}
