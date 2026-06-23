import Foundation

package enum FileContentFreshnessPolicy {
    case cachedMetadata
    case validateDiskMetadata
}

package struct FileSearchContentSnapshot {
    package let content: String?
    package let contentRevision: UInt64?
    package let modificationDate: Date
    package let isFresh: Bool

    package init(content: String?, contentRevision: UInt64?, modificationDate: Date, isFresh: Bool) {
        self.content = content
        self.contentRevision = contentRevision
        self.modificationDate = modificationDate
        self.isFresh = isFresh
    }
}

package enum FilePathDisplay: String, CaseIterable {
    case full = "Full"
    case relative = "Relative"
}

package enum FileManagerError: Error, LocalizedError {
    case failedToLoadFolder(Error)
    case failedToLoadFile(Error)
    case fileSystemServiceNotFound
    case failedToLoadContent
    case fileSystemServiceNotFoundWithContext(String)

    package var errorDescription: String? {
        switch self {
        case let .failedToLoadFolder(error): "Failed to load folder: \(error.localizedDescription)"
        case let .failedToLoadFile(error): "Failed to load file: \(error.localizedDescription)"
        case .fileSystemServiceNotFound: "No matching workspace folder for the requested path."
        case .failedToLoadContent: "Failed to load content."
        case let .fileSystemServiceNotFoundWithContext(context): context
        }
    }
}
