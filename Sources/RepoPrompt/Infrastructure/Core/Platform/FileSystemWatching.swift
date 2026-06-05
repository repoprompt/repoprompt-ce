import Foundation

/// Platform-neutral filesystem event sequence used for watcher coalescing and scan deduplication.
typealias FileSystemWatchEventID = UInt64

/// Semantic watcher flags consumed by reusable filesystem policy.
///
/// Platform adapters translate native event bits into this stable vocabulary before events enter
/// the reusable mailbox. Keeping these semantics neutral lets coalescing, overflow recovery,
/// ignore evaluation, and delta generation move to the future core target unchanged.
struct FileSystemWatchEventFlags: OptionSet, Equatable {
    let rawValue: UInt32

    static let itemCreated = Self(rawValue: 1 << 0)
    static let itemRemoved = Self(rawValue: 1 << 1)
    static let itemRenamed = Self(rawValue: 1 << 2)
    static let contentChanged = Self(rawValue: 1 << 3)
    static let metadataChanged = Self(rawValue: 1 << 4)
    static let itemIsFile = Self(rawValue: 1 << 5)
    static let itemIsDirectory = Self(rawValue: 1 << 6)
    static let itemIsSymlink = Self(rawValue: 1 << 7)
    static let mustScanSubdirectories = Self(rawValue: 1 << 8)
    static let droppedEvents = Self(rawValue: 1 << 9)
    static let rootChanged = Self(rawValue: 1 << 10)

    static let overflowRootRescan: Self = [.mustScanSubdirectories, .rootChanged]
}

struct FileSystemWatchEvent: Equatable {
    let path: String
    let flags: FileSystemWatchEventFlags
    let id: FileSystemWatchEventID
}

struct FileSystemWatchEventPayload: Equatable {
    let entries: [FileSystemWatchEvent]

    var count: Int {
        entries.count
    }
}

/// Injected lifecycle boundary for filesystem watching.
///
/// The event handler must run synchronously from the platform callback after native payloads have
/// been deep-copied. `FileSystemService` accepts the payload into its bounded mailbox before
/// scheduling actor work, preserving callback-cut flush barriers under load.
protocol FileSystemWatching: AnyObject, Sendable {
    var isWatching: Bool { get }

    @discardableResult
    func start(eventHandler: @escaping @Sendable (FileSystemWatchEventPayload) -> Void) -> Bool

    func stop()
}

protocol FileSystemWatcherCreating: Sendable {
    func makeWatcher(path: String) -> any FileSystemWatching
}
