import Foundation

package enum FileContentFreshnessPolicy {
    /// Trust existing metadata/cache fast paths.
    case cachedMetadata
    /// Validate disk metadata before trusting cached content; never return stale fallback on validation/load failure.
    case validateDiskMetadata
}

/// Snapshot of file content plus a stable in-memory revision for search cache identity.
package struct FileSearchContentSnapshot {
    package let content: String?
    package let contentRevision: UInt64?
    package let modificationDate: Date
    package let isFresh: Bool

    package init(
        content: String?,
        contentRevision: UInt64?,
        modificationDate: Date,
        isFresh: Bool
    ) {
        self.content = content
        self.contentRevision = contentRevision
        self.modificationDate = modificationDate
        self.isFresh = isFresh
    }
}
