import Foundation

public enum FileSystemDelta: Sendable, Equatable {
    case fileAdded(String)
    case fileRemoved(String)
    case folderAdded(String)
    case folderRemoved(String)
    case fileModified(String, Date?) // observed disk mtime when available
    case folderModified(String, Date? = nil) // observed disk mtime when available
}

package enum FileSystemDeltaPublicationSource: String {
    case watcher
    case syntheticMutation
    case watcherBarrierNoop
    case overflowRootRescan
}

package struct FileSystemDeltaPublication {
    package let servicePublicationSequence: UInt64
    package let source: FileSystemDeltaPublicationSource
    package let watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark?
    package let correlationID: UUID?
    package let deltas: [FileSystemDelta]

    package init(
        servicePublicationSequence: UInt64,
        source: FileSystemDeltaPublicationSource,
        watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark?,
        correlationID: UUID? = nil,
        deltas: [FileSystemDelta]
    ) {
        self.servicePublicationSequence = servicePublicationSequence
        self.source = source
        self.watcherAcceptedWatermark = watcherAcceptedWatermark
        self.correlationID = correlationID
        self.deltas = deltas
    }
}

package typealias PendingFSEvent = (path: String, flags: FileSystemWatchEventFlags, id: FileSystemWatchEventID)

package struct PendingFSEventBatch {
    package var events: [PendingFSEvent] = []
    package var watcherAcceptedHighWatermark: FileSystemWatcherIngressMailbox.Watermark?
    package var publicationSource: FileSystemDeltaPublicationSource = .watcher
    package var watcherIngressGeneration: UInt64?

    package var isEmpty: Bool {
        events.isEmpty
    }
}

public enum CatalogRegularFileIneligibilityReason: Sendable, Equatable, CustomStringConvertible {
    case invalidRelativePath
    case outsideRoot
    case missingOrDirectory
    case symbolicLink
    case nonRegularFile
    case symlinkComponent
    case outsideCanonicalRoot
    case ignored

    public var description: String {
        switch self {
        case .invalidRelativePath:
            "invalid relative path"
        case .outsideRoot:
            "path is outside the workspace root"
        case .missingOrDirectory:
            "path is missing or is a directory"
        case .symbolicLink:
            "path is a symbolic link"
        case .nonRegularFile:
            "path is not a regular file"
        case .symlinkComponent:
            "path contains a symbolic-link component"
        case .outsideCanonicalRoot:
            "canonical path is outside the workspace root"
        case .ignored:
            "path is ignored by workspace policy"
        }
    }
}

public enum CatalogRegularFileEligibility: Sendable, Equatable {
    case eligible
    case ineligible(CatalogRegularFileIneligibilityReason)

    public var isEligible: Bool {
        if case .eligible = self { return true }
        return false
    }
}

package struct FSItemDTO {
    package let relativePath: String
    package let isDirectory: Bool
    package let hierarchy: Int
}

package struct FSPreparedChunk {
    package let folders: [FSItemDTO]
    package let files: [FSItemDTO]
}

#if DEBUG
    package struct PublishedDeltaCoalescingDiagnostics: Equatable {
        let rawDeltaCount: Int
        let publishedDeltaCount: Int
    }
#endif

package enum LoadContentsEvent {
    case totalFileCount(Int) // emitted at least once, first emission precedes item payloads
    case items([(any FileSystemItem, [String])]) // legacy compatibility
    case preparedItems(FSPreparedChunk) // preferred streaming payload
}

package enum ContentReadWorkloadClass: String {
    case interactiveRead
    case contentSearch
    case codemap
    case encodingDetection
    case unspecified
}

// MARK: - Encoding support -----------------------------------------------------

/// Bundles the decoded text with the encoding that produced it.
package struct DetectedText {
    package let string: String
    package let encoding: String.Encoding
}

package enum FileSystemError: Error {
    case fileAlreadyExists
    case fileNotFound
    case failedToCreateFile(Error)
    case failedToEditFile(Error)
    case failedToDeleteFile(Error)
    case failedToReadFile
    case failedToEnumerateDirectory
    case fileTooLarge
    case isDirectory
    case failedToCreateDirectory(Error)
    case invalidRelativePath
    case mutationBackendUnavailable
}

extension FileSystemError: LocalizedError {
    package var errorDescription: String? {
        switch self {
        case .invalidRelativePath:
            "Unsafe workspace mutation path: target escapes the loaded root, contains traversal, or uses a symbolic-link component."
        case .mutationBackendUnavailable:
            "Workspace mutation is unavailable in this runtime."
        default:
            nil
        }
    }
}
