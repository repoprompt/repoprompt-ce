import CoreFoundation
import CoreServices
import Dispatch
import Foundation

/// macOS adapter for CoreServices FSEvents lifecycle and raw-flag translation.
///
/// Reusable filesystem policy receives only deep-copied, semantic `FileSystemWatchEvent` values.
/// Stream references, callback context retention, and native bit mapping remain adapter-owned.
final class MacOSFSEventsWatcher: FileSystemWatching, @unchecked Sendable {
    private let path: String
    private let callbackQueue: DispatchQueue
    private let lock = NSLock()
    private var streamRef: FSEventStreamRef?
    private var retainedSelfPointer: UnsafeMutableRawPointer?
    private var eventHandler: (@Sendable (FileSystemWatchEventPayload) -> Void)?

    init(path: String) {
        self.path = path
        callbackQueue = DispatchQueue(
            label: "com.repoprompt.filesystem.fsevents.\(UUID().uuidString)",
            qos: .utility
        )
    }

    var isWatching: Bool {
        lock.lock()
        defer { lock.unlock() }
        return streamRef != nil
    }

    @discardableResult
    func start(eventHandler: @escaping @Sendable (FileSystemWatchEventPayload) -> Void) -> Bool {
        lock.lock()
        guard streamRef == nil else {
            lock.unlock()
            return true
        }
        self.eventHandler = eventHandler
        let retainedSelfPointer = Unmanaged.passRetained(self).toOpaque()
        self.retainedSelfPointer = retainedSelfPointer
        lock.unlock()

        var streamContext = FSEventStreamContext(
            version: 0,
            info: retainedSelfPointer,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        let createdStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &streamContext,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0,
            createFlags
        )
        guard let createdStream else {
            releaseRetainedSelfPointerIfNeeded()
            print("Failed to create FSEventStream for \(path)")
            return false
        }

        FSEventStreamSetDispatchQueue(createdStream, callbackQueue)
        guard FSEventStreamStart(createdStream) else {
            FSEventStreamInvalidate(createdStream)
            FSEventStreamRelease(createdStream)
            releaseRetainedSelfPointerIfNeeded()
            print("Failed to start FSEventStream for \(path)")
            return false
        }

        lock.lock()
        streamRef = createdStream
        lock.unlock()
        return true
    }

    func stop() {
        lock.lock()
        let stream = streamRef
        streamRef = nil
        eventHandler = nil
        lock.unlock()

        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamFlushSync(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        releaseRetainedSelfPointerIfNeeded()
    }

    deinit {
        stop()
    }

    private func accept(_ payload: FileSystemWatchEventPayload) {
        lock.lock()
        let eventHandler = eventHandler
        lock.unlock()
        eventHandler?(payload)
    }

    private func releaseRetainedSelfPointerIfNeeded() {
        lock.lock()
        let pointer = retainedSelfPointer
        retainedSelfPointer = nil
        lock.unlock()
        if let pointer {
            Unmanaged<MacOSFSEventsWatcher>.fromOpaque(pointer).release()
        }
    }

    private static let callback: FSEventStreamCallback = {
        _, context, numEvents, eventPaths, eventFlags, eventIDs in
        guard let context else { return }
        let watcher = Unmanaged<MacOSFSEventsWatcher>.fromOpaque(context).takeUnretainedValue()
        guard let payload = buildOwnedPayload(
            numEvents: Int(numEvents),
            eventPaths: eventPaths,
            eventFlags: eventFlags,
            eventIDs: eventIDs
        ) else { return }
        watcher.accept(payload)
    }

    nonisolated static func buildOwnedPayload(
        numEvents: Int,
        eventPaths: UnsafeMutableRawPointer,
        eventFlags: UnsafePointer<FSEventStreamEventFlags>,
        eventIDs: UnsafePointer<FSEventStreamEventId>
    ) -> FileSystemWatchEventPayload? {
        guard numEvents > 0 else { return nil }
        let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        let safeCount = min(numEvents, CFArrayGetCount(cfArray))
        guard safeCount > 0 else { return nil }

        var entries: [FileSystemWatchEvent] = []
        entries.reserveCapacity(safeCount)
        for index in 0 ..< safeCount {
            guard let rawValue = CFArrayGetValueAtIndex(cfArray, index) else { continue }
            let cfObject = unsafeBitCast(rawValue, to: CFTypeRef.self)
            let copiedPath: String? = if CFGetTypeID(cfObject) == CFStringGetTypeID() {
                deepCopyEventPath(unsafeBitCast(rawValue, to: CFString.self))
            } else if let string = cfObject as? String {
                deepCopySwiftString(string)
            } else {
                nil
            }
            guard let copiedPath else { continue }
            entries.append(FileSystemWatchEvent(
                path: copiedPath,
                flags: semanticFlags(for: eventFlags[index]),
                id: FileSystemWatchEventID(eventIDs[index])
            ))
        }
        return entries.isEmpty ? nil : FileSystemWatchEventPayload(entries: entries)
    }

    nonisolated static func semanticFlags(for rawFlags: FSEventStreamEventFlags) -> FileSystemWatchEventFlags {
        let raw = UInt32(rawFlags)
        var flags: FileSystemWatchEventFlags = []
        func map(_ nativeFlag: Int, to semanticFlag: FileSystemWatchEventFlags) {
            if raw & UInt32(nativeFlag) != 0 {
                flags.insert(semanticFlag)
            }
        }
        map(kFSEventStreamEventFlagItemCreated, to: .itemCreated)
        map(kFSEventStreamEventFlagItemRemoved, to: .itemRemoved)
        map(kFSEventStreamEventFlagItemRenamed, to: .itemRenamed)
        map(kFSEventStreamEventFlagItemModified, to: .contentChanged)
        map(kFSEventStreamEventFlagItemXattrMod, to: .contentChanged)
        map(kFSEventStreamEventFlagItemInodeMetaMod, to: .metadataChanged)
        map(kFSEventStreamEventFlagItemFinderInfoMod, to: .metadataChanged)
        map(kFSEventStreamEventFlagItemChangeOwner, to: .metadataChanged)
        map(kFSEventStreamEventFlagItemIsFile, to: .itemIsFile)
        map(kFSEventStreamEventFlagItemIsDir, to: .itemIsDirectory)
        map(kFSEventStreamEventFlagItemIsSymlink, to: .itemIsSymlink)
        map(kFSEventStreamEventFlagMustScanSubDirs, to: .mustScanSubdirectories)
        map(kFSEventStreamEventFlagUserDropped, to: .droppedEvents)
        map(kFSEventStreamEventFlagKernelDropped, to: .droppedEvents)
        map(kFSEventStreamEventFlagRootChanged, to: .rootChanged)
        return flags
    }

    nonisolated static func deepCopySwiftString(_ source: String) -> String {
        String(decoding: Array(source.utf8), as: UTF8.self)
    }

    nonisolated static func deepCopyEventPath(_ source: CFString) -> String? {
        let length = CFStringGetLength(source)
        if length == 0 { return "" }

        let utf8Encoding = CFStringBuiltInEncodings.UTF8.rawValue
        if let directUTF8 = CFStringGetCStringPtr(source, utf8Encoding) {
            return String(cString: directUTF8)
        }
        let maxBufferSize = max(CFStringGetMaximumSizeForEncoding(length, utf8Encoding) + 1, 1)
        var utf8Buffer = [CChar](repeating: 0, count: maxBufferSize)
        let copiedUTF8 = utf8Buffer.withUnsafeMutableBufferPointer { buffer in
            CFStringGetCString(source, buffer.baseAddress, buffer.count, utf8Encoding)
        }
        if copiedUTF8 {
            return String(cString: utf8Buffer)
        }

        var utf16Buffer = [UniChar](repeating: 0, count: length)
        CFStringGetCharacters(source, CFRange(location: 0, length: length), &utf16Buffer)
        return String(utf16CodeUnits: utf16Buffer, count: utf16Buffer.count)
    }
}

struct MacOSFSEventsWatcherFactory: FileSystemWatcherCreating {
    func makeWatcher(path: String) -> any FileSystemWatching {
        MacOSFSEventsWatcher(path: path)
    }
}
