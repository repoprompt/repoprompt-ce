import Foundation

package typealias FileSystemWatchEventID = UInt64

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
    package static let historyDone = Self(rawValue: 1 << 11)
    package static let eventIDsWrapped = Self(rawValue: 1 << 12)
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
}

package enum FileSystemWatcherStartError: Error, Equatable {
    case streamCreationFailed(path: String)
    case streamStartFailed(path: String)
}

package protocol FileSystemWatching: AnyObject, Sendable {
    var isWatching: Bool { get }

    func start(
        from eventID: FileSystemWatchEventID,
        eventHandler: @escaping @Sendable (FileSystemWatchEventPayload) -> Void
    ) throws

    func flush()
    func latestEventID() -> FileSystemWatchEventID?
    func stop()
}

package protocol FileSystemWatcherCreating: Sendable {
    func makeWatcher(path: String) -> any FileSystemWatching
}
