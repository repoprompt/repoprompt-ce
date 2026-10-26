import Foundation

package enum GitRepoRootAuthorization {
    package static func canonicalPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded: String = if trimmed.hasPrefix("~") {
            (trimmed as NSString).expandingTildeInPath
        } else {
            trimmed
        }
        let standardized = (expanded as NSString).standardizingPath
        let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        return (resolved as NSString).standardizingPath
    }

    package static func isPathWithinAuthorizedRoots(_ path: String, roots: [String]) -> Bool {
        let candidate = canonicalPath(path)
        for rawRoot in roots {
            let root = canonicalPath(rawRoot)
            let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
            if candidate == root || candidate.hasPrefix(rootWithSlash) {
                return true
            }
        }
        return false
    }
}
