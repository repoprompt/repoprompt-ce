import Foundation

/// Canonical identity for comparing workspace roots, Git worktree paths, and checkout bindings.
///
/// This is intentionally narrower than general file-path display normalization: branch switching
/// needs one answer to "do these paths refer to the same checkout?" across the UI, actor cache,
/// and persisted session bindings.
package struct CheckoutPathIdentity: Hashable, CustomStringConvertible {
    package let path: String

    package init?(_ rawPath: String?) {
        guard let canonical = Self.canonicalPath(rawPath) else {
            return nil
        }
        path = canonical
    }

    package var description: String {
        path
    }

    package static func canonicalPath(_ rawPath: String?) -> String? {
        guard let trimmed = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = if expanded.hasPrefix("/") {
            URL(fileURLWithPath: expanded).standardizedFileURL.path
        } else {
            StandardizedPath.absolute(expanded)
        }
        return standardized.precomposedStringWithCanonicalMapping
    }

    package static func canonicalPathOrOriginal(_ rawPath: String) -> String {
        canonicalPath(rawPath) ?? rawPath
    }

    package static func same(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = CheckoutPathIdentity(lhs),
              let rhs = CheckoutPathIdentity(rhs)
        else { return false }
        return lhs == rhs
    }
}
