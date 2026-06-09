import Foundation

package enum WorkspaceRootMoveDirection {
    case up
    case down
}

package enum WorkspaceRootActions {
    package static func movedRepoPaths(
        repoPaths: [String],
        movingRootPath: String,
        direction: WorkspaceRootMoveDirection,
        visibleRootPaths: [String]? = nil
    ) -> [String] {
        let uniquePaths = standardizedUniqueRepoPaths(repoPaths)
        guard uniquePaths.count > 1 else { return uniquePaths }

        let movingKey = canonicalKey(movingRootPath)
        guard let repoIndex = uniquePaths.firstIndex(where: { canonicalKey($0) == movingKey }) else {
            return uniquePaths
        }

        let visiblePaths = standardizedUniqueRepoPaths(visibleRootPaths ?? uniquePaths)
        let visibleKeysInOrder = visiblePaths
            .map(canonicalKey)
            .filter { visibleKey in
                uniquePaths.contains { canonicalKey($0) == visibleKey }
            }
        guard let visibleIndex = visibleKeysInOrder.firstIndex(of: movingKey) else { return uniquePaths }

        let neighborVisibleIndex: Int
        switch direction {
        case .up:
            guard visibleIndex > 0 else { return uniquePaths }
            neighborVisibleIndex = visibleIndex - 1
        case .down:
            guard visibleIndex < visibleKeysInOrder.count - 1 else { return uniquePaths }
            neighborVisibleIndex = visibleIndex + 1
        }

        let neighborKey = visibleKeysInOrder[neighborVisibleIndex]
        guard let neighborRepoIndex = uniquePaths.firstIndex(where: { canonicalKey($0) == neighborKey }) else {
            return uniquePaths
        }

        var moved = uniquePaths
        moved.swapAt(repoIndex, neighborRepoIndex)
        return moved
    }

    package static func standardizedUniqueRepoPaths(_ repoPaths: [String]) -> [String] {
        var seen = Set<String>()
        var uniquePaths: [String] = []
        for path in repoPaths {
            let standardizedPath = standardized(path)
            guard seen.insert(standardizedPath.lowercased()).inserted else { continue }
            uniquePaths.append(standardizedPath)
        }
        return uniquePaths
    }

    private static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private static func canonicalKey(_ path: String) -> String {
        standardized(path).lowercased()
    }
}
