import Foundation

/// Platform-neutral filesystem event sequence used for watcher coalescing and scan deduplication.
package typealias FileSystemWatchEventID = UInt64

/// Semantic watcher flags consumed by reusable filesystem policy.
///
/// Platform adapters translate native event bits into this stable vocabulary before events enter
/// the reusable mailbox. Keeping these semantics neutral lets coalescing, overflow recovery,
/// ignore evaluation, and delta generation move into the core target unchanged.
package struct FileSystemWatchEventFlags: OptionSet, Equatable {
    package let rawValue: UInt32

    package init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    package static let itemCreated = Self(rawValue: 1 << 0)
    package static let itemRemoved = Self(rawValue: 1 << 1)
    package static let itemRenamed = Self(rawValue: 1 << 2)
    package static let contentChanged = Self(rawValue: 1 << 3)
    package static let metadataChanged = Self(rawValue: 1 << 4)
    package static let itemIsFile = Self(rawValue: 1 << 5)
    package static let itemIsDirectory = Self(rawValue: 1 << 6)
    package static let itemIsSymlink = Self(rawValue: 1 << 7)
    package static let mustScanSubdirectories = Self(rawValue: 1 << 8)
    package static let droppedEvents = Self(rawValue: 1 << 9)
    package static let rootChanged = Self(rawValue: 1 << 10)

    package static let overflowRootRescan: Self = [.mustScanSubdirectories, .rootChanged]
}

package struct FileSystemWatchEvent: Equatable {
    package let path: String
    package let flags: FileSystemWatchEventFlags
    package let id: FileSystemWatchEventID

    package init(path: String, flags: FileSystemWatchEventFlags, id: FileSystemWatchEventID) {
        self.path = path
        self.flags = flags
        self.id = id
    }
}

package struct FileSystemWatchEventPayload: Equatable {
    package let entries: [FileSystemWatchEvent]

    package init(entries: [FileSystemWatchEvent]) {
        self.entries = entries
    }

    package var count: Int {
        entries.count
    }
}

/// Injected lifecycle boundary for filesystem watching.
///
/// The event handler must run synchronously from the platform callback after native payloads have
/// been deep-copied. `FileSystemService` accepts the payload into its bounded mailbox before
/// scheduling actor work, preserving callback-cut flush barriers under load.
package protocol FileSystemWatching: AnyObject, Sendable {
    var isWatching: Bool { get }

    @discardableResult
    func start(eventHandler: @escaping @Sendable (FileSystemWatchEventPayload) -> Void) -> Bool

    func stop()
}

package protocol FileSystemWatcherCreating: Sendable {
    func makeWatcher(path: String) -> any FileSystemWatching
}
