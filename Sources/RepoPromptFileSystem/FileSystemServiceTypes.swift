import CoreServices
import Foundation
import RepoPromptFoundation
#if DEBUG || EDIT_FLOW_PERF
    import os
#endif

package enum FileSystemPublishPerf {
    #if DEBUG || EDIT_FLOW_PERF
        package typealias State = OSSignpostIntervalState
        package static let signposter = OSSignposter(subsystem: "com.repoprompt.workspace", category: "fs-publish")
        package static var isEnabled: Bool {
            FileSystemRuntimeHooks.current.preferenceEnabled("enableRepoFileReplaySignposts")
        }

        package static func begin(_ name: StaticString) -> State? {
            guard isEnabled else { return nil }
            return signposter.beginInterval(name)
        }

        package static func end(_ name: StaticString, _ state: State?) {
            guard isEnabled, let state else { return }
            signposter.endInterval(name, state)
        }
    #else
        package struct State {}
        package static var isEnabled: Bool {
            false
        }

        package static func begin(_ name: StaticString) -> State? {
            nil
        }

        package static func end(_ name: StaticString, _ state: State?) {}
    #endif
}

public enum FileSystemDelta: Sendable, Equatable {
    case fileAdded(String)
    case fileRemoved(String)
    case folderAdded(String)
    case folderRemoved(String)
    case fileModified(String, Date?) // observed disk mtime when available
    case folderModified(String, Date? = nil) // observed disk mtime when available
}

package enum FileSystemWatcherActivationError: LocalizedError, Equatable {
    case streamCreationFailed(path: String)
    case streamStartFailed(path: String)
    case deliveryBarrierTimedOut(path: String)
    case eventIDsWrapped(path: String)

    package var errorDescription: String? {
        switch self {
        case let .streamCreationFailed(path):
            "Failed to create FSEvent stream for \(path)"
        case let .streamStartFailed(path):
            "Failed to start FSEvent stream for \(path)"
        case let .deliveryBarrierTimedOut(path):
            "Timed out waiting for FSEvent stream delivery for \(path)"
        case let .eventIDsWrapped(path):
            "FSEvent stream event IDs wrapped; watcher recovery is required for \(path)"
        }
    }
}

package enum FileSystemDeltaPublicationSource: String {
    case watcher
    case syntheticMutation
    case watcherBarrierNoop
    case overflowRootRescan
    case recoveryFullResync
    case authorityTargetedReconcile
}

package enum FileSystemEditModificationPublicationPolicy: Equatable {
    case publishSyntheticModification
    case deferSyntheticModificationToSuccessfulCaller
}

package struct FileSystemDeferredEditPublicationToken: Equatable {
    package let serviceToken: UUID
    package let mutationID: UUID
    package init(serviceToken: UUID, mutationID: UUID) {
        self.serviceToken = serviceToken
        self.mutationID = mutationID
    }
}

package enum FileSystemDeferredEditPublicationResolution: Equatable {
    case callerPublishedCanonicalModification
    case publishSyntheticFallback
}

package struct FileSystemDeferredEditPublication {
    package let relativePath: String
    package let modificationDate: Date?
    package init(relativePath: String, modificationDate: Date?) {
        self.relativePath = relativePath
        self.modificationDate = modificationDate
    }
}

package struct FileSystemDeltaPublication {
    package let servicePublicationSequence: UInt64
    package let source: FileSystemDeltaPublicationSource
    package let watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark?
    package let requiresFullResync: Bool
    package let deltas: [FileSystemDelta]

    package init(
        servicePublicationSequence: UInt64,
        source: FileSystemDeltaPublicationSource,
        watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark?,
        requiresFullResync: Bool = false,
        deltas: [FileSystemDelta]
    ) {
        self.servicePublicationSequence = servicePublicationSequence
        self.source = source
        self.watcherAcceptedWatermark = watcherAcceptedWatermark
        self.requiresFullResync = requiresFullResync
        self.deltas = deltas
    }
}

package typealias PendingFSEvent = (path: String, flags: FSEventStreamEventFlags, id: FSEventStreamEventId)

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
        if case .eligible = self {
            return true
        }
        return false
    }
}

package struct FSItemDTO {
    package let relativePath: String
    package let relativePathBytes: Data
    package let isDirectory: Bool
    package let hierarchy: Int
    package let isSymbolicLink: Bool
    package let fileSystemMode: UInt16

    package init(
        relativePath: String,
        relativePathBytes: Data? = nil,
        isDirectory: Bool,
        hierarchy: Int,
        isSymbolicLink: Bool = false,
        fileSystemMode: UInt16 = 0
    ) {
        self.relativePath = relativePath
        self.relativePathBytes = relativePathBytes ?? Data(relativePath.utf8)
        self.isDirectory = isDirectory
        self.hierarchy = hierarchy
        self.isSymbolicLink = isSymbolicLink
        self.fileSystemMode = fileSystemMode
    }
}

package struct FSPreparedChunk {
    package let folders: [FSItemDTO]
    package let files: [FSItemDTO]
    package init(folders: [FSItemDTO], files: [FSItemDTO]) {
        self.folders = folders
        self.files = files
    }
}

#if DEBUG
    package struct PublishedDeltaCoalescingDiagnostics: Equatable {
        package let rawDeltaCount: Int
        package let publishedDeltaCount: Int
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
    case promptAccounting
    case unspecified
}

package enum ContentReadSchedulerError: LocalizedError, Equatable {
    case queueFull(retryAfterMilliseconds: Int)

    package var retryAfterMilliseconds: Int {
        switch self {
        case let .queueFull(retryAfterMilliseconds):
            retryAfterMilliseconds
        }
    }

    package var errorDescription: String? {
        switch self {
        case .queueFull:
            "Content-read capacity is temporarily busy and the bounded wait queue is full."
        }
    }
}

// MARK: - Encoding support -----------------------------------------------------

/// Bundles the decoded text with the encoding that produced it.
package struct DetectedText {
    package let string: String
    package let encoding: String.Encoding
    package init(string: String, encoding: String.Encoding) {
        self.string = string
        self.encoding = encoding
    }
}

package enum FileSystemError: Error {
    case fileAlreadyExists
    case fileNotFound
    case failedToCreateFile(Error)
    case incompleteFileCreation(path: String, underlying: Error)
    case failedToEditFile(Error)
    case failedToDeleteFile(Error)
    case failedToReadFile
    case failedToEnumerateDirectory
    case fileTooLarge
    case isDirectory
    case failedToCreateDirectory(Error)
    case invalidRelativePath
    case mutationInProgress
    case fileContentChanged
}

extension FileSystemError: LocalizedError {
    package var errorDescription: String? {
        switch self {
        case .fileAlreadyExists:
            "The destination file already exists."
        case let .failedToCreateFile(error):
            "File creation failed: \(error.localizedDescription)"
        case let .incompleteFileCreation(path, underlying):
            "File creation failed after exclusively claiming '\(path)'; incomplete output may remain at that path. Inspect it before retrying and do not blindly retry. Underlying error: \(underlying.localizedDescription)"
        case .isDirectory:
            "The destination path is a directory."
        case .invalidRelativePath:
            "Unsafe workspace mutation path: target escapes the loaded root, contains traversal, or uses a symbolic-link component."
        case .mutationInProgress:
            "A conflicting filesystem mutation is still completing. The operation was not started."
        case .fileContentChanged:
            "The file changed after review. Retry apply_edits to review the current content."
        default:
            nil
        }
    }
}
