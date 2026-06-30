import CoreServices
import Foundation
#if DEBUG || EDIT_FLOW_PERF
    import os
#endif

enum FileSystemPublishPerf {
    #if DEBUG || EDIT_FLOW_PERF
        typealias State = OSSignpostIntervalState
        static let signposter = OSSignposter(subsystem: "com.repoprompt.workspace", category: "fs-publish")
        static var isEnabled: Bool {
            UserDefaults.standard.bool(forKey: "enableRepoFileReplaySignposts")
        }

        static func begin(_ name: StaticString) -> State? {
            guard isEnabled else { return nil }
            return signposter.beginInterval(name)
        }

        static func end(_ name: StaticString, _ state: State?) {
            guard isEnabled, let state else { return }
            signposter.endInterval(name, state)
        }
    #else
        struct State {}
        static var isEnabled: Bool {
            false
        }

        static func begin(_ name: StaticString) -> State? {
            nil
        }

        static func end(_ name: StaticString, _ state: State?) {}
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

enum FileSystemWatcherActivationError: LocalizedError, Equatable {
    case streamCreationFailed(path: String)
    case streamStartFailed(path: String)

    var errorDescription: String? {
        switch self {
        case let .streamCreationFailed(path):
            "Failed to create FSEvent stream for \(path)"
        case let .streamStartFailed(path):
            "Failed to start FSEvent stream for \(path)"
        }
    }
}

enum FileSystemDeltaPublicationSource: String {
    case watcher
    case syntheticMutation
    case watcherBarrierNoop
    case overflowRootRescan
    case recoveryFullResync
}

enum FileSystemEditModificationPublicationPolicy: Equatable {
    case publishSyntheticModification
    case deferSyntheticModificationToSuccessfulCaller
}

struct FileSystemDeferredEditPublicationToken: Equatable {
    let serviceToken: UUID
    let mutationID: UUID
}

enum FileSystemDeferredEditPublicationResolution: Equatable {
    case callerPublishedCanonicalModification
    case publishSyntheticFallback
}

struct FileSystemDeferredEditPublication {
    let relativePath: String
    let modificationDate: Date?
}

struct FileSystemDeltaPublication {
    let servicePublicationSequence: UInt64
    let source: FileSystemDeltaPublicationSource
    let watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark?
    let requiresFullResync: Bool
    let deltas: [FileSystemDelta]

    init(
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

typealias PendingFSEvent = (path: String, flags: FSEventStreamEventFlags, id: FSEventStreamEventId)

struct PendingFSEventBatch {
    var events: [PendingFSEvent] = []
    var watcherAcceptedHighWatermark: FileSystemWatcherIngressMailbox.Watermark?
    var publicationSource: FileSystemDeltaPublicationSource = .watcher
    var watcherIngressGeneration: UInt64?

    var isEmpty: Bool {
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

struct FSItemDTO {
    let relativePath: String
    let relativePathBytes: Data
    let isDirectory: Bool
    let hierarchy: Int
    let isSymbolicLink: Bool
    let fileSystemMode: UInt16

    init(
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

struct FSPreparedChunk {
    let folders: [FSItemDTO]
    let files: [FSItemDTO]
}

#if DEBUG
    struct PublishedDeltaCoalescingDiagnostics: Equatable {
        let rawDeltaCount: Int
        let publishedDeltaCount: Int
    }
#endif

enum LoadContentsEvent {
    case totalFileCount(Int) // emitted at least once, first emission precedes item payloads
    case items([(any FileSystemItem, [String])]) // legacy compatibility
    case preparedItems(FSPreparedChunk) // preferred streaming payload
}

enum ContentReadWorkloadClass: String {
    case interactiveRead
    case contentSearch
    case codemap
    case encodingDetection
    case promptAccounting
    case unspecified
}

enum ContentReadSchedulerError: LocalizedError, Equatable {
    case queueFull(retryAfterMilliseconds: Int)

    var retryAfterMilliseconds: Int {
        switch self {
        case let .queueFull(retryAfterMilliseconds):
            retryAfterMilliseconds
        }
    }

    var errorDescription: String? {
        switch self {
        case .queueFull:
            "Content-read capacity is temporarily busy and the bounded wait queue is full."
        }
    }
}

// MARK: - Encoding support -----------------------------------------------------

/// Bundles the decoded text with the encoding that produced it.
struct DetectedText {
    let string: String
    let encoding: String.Encoding
}

enum FileSystemError: Error {
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
}

extension FileSystemError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidRelativePath:
            "Unsafe workspace mutation path: target escapes the loaded root, contains traversal, or uses a symbolic-link component."
        default:
            nil
        }
    }
}
