import CoreFoundation
import CoreServices
import Dispatch
import Foundation
import RepoPromptCore

package enum MacOSFSEventsJournal {
    package static func currentEventID() -> FileSystemWatchEventID {
        FileSystemWatchEventID(FSEventsGetCurrentEventId())
    }
}

package protocol MacOSFSEventStreamToken: AnyObject, Sendable {}

package protocol MacOSFSEventStreamBackend: Sendable {
    func createStream(
        path: String,
        from eventID: FileSystemWatchEventID,
        callback: FSEventStreamCallback,
        contextInfo: UnsafeMutableRawPointer,
        callbackQueue: DispatchQueue
    ) -> (any MacOSFSEventStreamToken)?
    func startStream(_ stream: any MacOSFSEventStreamToken) -> Bool
    func flushStream(_ stream: any MacOSFSEventStreamToken)
    func latestEventID(_ stream: any MacOSFSEventStreamToken) -> FileSystemWatchEventID
    func disposeStream(_ stream: any MacOSFSEventStreamToken, wasStarted: Bool)
}

private final class CoreServicesFSEventStreamToken: MacOSFSEventStreamToken, @unchecked Sendable {
    let stream: FSEventStreamRef

    init(stream: FSEventStreamRef) {
        self.stream = stream
    }
}

private struct CoreServicesFSEventStreamBackend: MacOSFSEventStreamBackend {
    func createStream(
        path: String,
        from eventID: FileSystemWatchEventID,
        callback: FSEventStreamCallback,
        contextInfo: UnsafeMutableRawPointer,
        callbackQueue: DispatchQueue
    ) -> (any MacOSFSEventStreamToken)? {
        var streamContext = FSEventStreamContext(
            version: 0,
            info: contextInfo,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &streamContext,
            [path] as CFArray,
            FSEventStreamEventId(eventID),
            0,
            flags
        ) else { return nil }
        FSEventStreamSetDispatchQueue(stream, callbackQueue)
        return CoreServicesFSEventStreamToken(stream: stream)
    }

    func startStream(_ stream: any MacOSFSEventStreamToken) -> Bool {
        guard let token = stream as? CoreServicesFSEventStreamToken else { return false }
        return FSEventStreamStart(token.stream)
    }

    func flushStream(_ stream: any MacOSFSEventStreamToken) {
        guard let token = stream as? CoreServicesFSEventStreamToken else { return }
        FSEventStreamFlushSync(token.stream)
    }

    func latestEventID(_ stream: any MacOSFSEventStreamToken) -> FileSystemWatchEventID {
        guard let token = stream as? CoreServicesFSEventStreamToken else { return 0 }
        return FileSystemWatchEventID(FSEventStreamGetLatestEventId(token.stream))
    }

    func disposeStream(_ stream: any MacOSFSEventStreamToken, wasStarted: Bool) {
        guard let token = stream as? CoreServicesFSEventStreamToken else { return }
        if wasStarted {
            FSEventStreamStop(token.stream)
            FSEventStreamFlushSync(token.stream)
        }
        FSEventStreamInvalidate(token.stream)
        FSEventStreamRelease(token.stream)
    }
}

package final class MacOSFSEventsWatcher: FileSystemWatching, @unchecked Sendable {
    private let path: String
    private let callbackQueue: DispatchQueue
    private let disposalQueue: DispatchQueue
    private let streamBackend: any MacOSFSEventStreamBackend
    private let callbackQueueToken = CallbackQueueToken()
    private let deliveryThreadKey = "com.repoprompt.filesystem.fsevents.delivery.\(UUID().uuidString)"
    private let condition = NSCondition()

    private var lifecycleState: LifecycleState = .idle
    private var nextGeneration: UInt64 = 0
    private var activeDeliveryCount = 0
    private var retainedLatestEventID: FileSystemWatchEventID?

    package convenience init(path: String) {
        self.init(path: path, streamBackend: CoreServicesFSEventStreamBackend())
    }

    package init(path: String, streamBackend: any MacOSFSEventStreamBackend) {
        self.path = path
        self.streamBackend = streamBackend
        callbackQueue = DispatchQueue(
            label: "com.repoprompt.filesystem.fsevents.\(UUID().uuidString)",
            qos: .utility
        )
        disposalQueue = DispatchQueue(
            label: "com.repoprompt.filesystem.fsevents.dispose.\(UUID().uuidString)",
            qos: .utility
        )
        callbackQueue.setSpecific(key: Self.callbackQueueKey, value: callbackQueueToken)
    }

    package var isWatching: Bool {
        condition.withLock {
            if case .watching = lifecycleState { return true }
            return false
        }
    }

    package func start(
        from eventID: FileSystemWatchEventID,
        eventHandler: @escaping @Sendable (FileSystemWatchEventPayload) -> Void
    ) throws {
        while true {
            condition.lock()
            switch lifecycleState {
            case .idle:
                let generation = nextGenerationLocked()
                let context = CallbackContext(watcher: self, generation: generation)
                let attempt = StartAttempt(
                    generation: generation,
                    startEventID: eventID,
                    handler: eventHandler,
                    context: context
                )
                lifecycleState = .starting(attempt)
                condition.unlock()
                try runStartAttempt(attempt)
                return
            case .watching:
                condition.unlock()
                return
            case .starting:
                condition.wait()
                condition.unlock()
            }
        }
    }

    package func flush() {
        let stream: (any MacOSFSEventStreamToken)? = condition.withLock {
            guard case let .watching(active) = lifecycleState else { return nil }
            return active.stream
        }
        if let stream {
            streamBackend.flushStream(stream)
        }
    }

    package func latestEventID() -> FileSystemWatchEventID? {
        condition.withLock {
            if case let .watching(active) = lifecycleState {
                return max(
                    retainedLatestEventID ?? 0,
                    streamBackend.latestEventID(active.stream)
                )
            }
            return retainedLatestEventID
        }
    }

    package func stop() {
        condition.lock()
        let disposal: StreamDisposal?
        switch lifecycleState {
        case .idle:
            disposal = nil
        case .starting:
            lifecycleState = .idle
            condition.broadcast()
            disposal = nil
        case let .watching(active):
            retainedLatestEventID = max(
                retainedLatestEventID ?? 0,
                streamBackend.latestEventID(active.stream)
            )
            lifecycleState = .idle
            condition.broadcast()
            disposal = StreamDisposal(
                stream: active.stream,
                wasStarted: true,
                context: active.context
            )
        }
        let isReentrantDelivery = Thread.current.threadDictionary[deliveryThreadKey] as? Bool == true
        if !isReentrantDelivery {
            while activeDeliveryCount > 0 {
                condition.wait()
            }
        }
        condition.unlock()

        if let disposal {
            disposeStream(disposal)
        }
    }

    deinit {
        stop()
    }

    private func runStartAttempt(_ attempt: StartAttempt) throws {
        guard let stream = streamBackend.createStream(
            path: path,
            from: attempt.startEventID,
            callback: Self.callback,
            contextInfo: Unmanaged.passUnretained(attempt.context).toOpaque(),
            callbackQueue: callbackQueue
        ) else {
            clearStartingAttemptIfCurrent(attempt)
            throw FileSystemWatcherStartError.streamCreationFailed(path: path)
        }

        guard isStartingAttemptCurrent(attempt) else {
            disposeStream(StreamDisposal(stream: stream, wasStarted: false, context: attempt.context))
            return
        }

        guard streamBackend.startStream(stream) else {
            clearStartingAttemptIfCurrent(attempt)
            disposeStream(StreamDisposal(stream: stream, wasStarted: false, context: attempt.context))
            throw FileSystemWatcherStartError.streamStartFailed(path: path)
        }

        let committed = condition.withLock {
            guard case let .starting(current) = lifecycleState,
                  current.generation == attempt.generation
            else { return false }
            lifecycleState = .watching(
                ActiveStream(
                    generation: attempt.generation,
                    handler: attempt.handler,
                    stream: stream,
                    context: attempt.context
                )
            )
            condition.broadcast()
            return true
        }
        if !committed {
            disposeStream(StreamDisposal(stream: stream, wasStarted: true, context: attempt.context))
        }
    }

    private func clearStartingAttemptIfCurrent(_ attempt: StartAttempt) {
        condition.withLock {
            guard case let .starting(current) = lifecycleState,
                  current.generation == attempt.generation
            else { return }
            lifecycleState = .idle
            condition.broadcast()
        }
    }

    private func isStartingAttemptCurrent(_ attempt: StartAttempt) -> Bool {
        condition.withLock {
            guard case let .starting(current) = lifecycleState else { return false }
            return current.generation == attempt.generation
        }
    }

    private func accept(_ payload: FileSystemWatchEventPayload, generation: UInt64) {
        let handler: (@Sendable (FileSystemWatchEventPayload) -> Void)? = condition.withLock {
            let acceptedHandler: (@Sendable (FileSystemWatchEventPayload) -> Void)? = switch lifecycleState {
            case let .starting(attempt) where attempt.generation == generation:
                attempt.handler
            case let .watching(active) where active.generation == generation:
                active.handler
            case .idle, .starting, .watching:
                nil
            }
            if acceptedHandler != nil {
                activeDeliveryCount += 1
            }
            return acceptedHandler
        }
        guard let handler else { return }
        Thread.current.threadDictionary[deliveryThreadKey] = true
        defer {
            Thread.current.threadDictionary.removeObject(forKey: deliveryThreadKey)
            condition.withLock {
                activeDeliveryCount -= 1
                condition.broadcast()
            }
        }
        handler(payload)
    }

    private func disposeStream(_ disposal: StreamDisposal) {
        let streamBackend = streamBackend
        let dispose: @Sendable () -> Void = {
            withExtendedLifetime(disposal.context) {
                streamBackend.disposeStream(disposal.stream, wasStarted: disposal.wasStarted)
            }
        }
        if DispatchQueue.getSpecific(key: Self.callbackQueueKey) === callbackQueueToken {
            disposalQueue.async(execute: dispose)
        } else {
            dispose()
        }
    }

    private func nextGenerationLocked() -> UInt64 {
        nextGeneration &+= 1
        if nextGeneration == 0 { nextGeneration = 1 }
        return nextGeneration
    }

    private static let callbackQueueKey = DispatchSpecificKey<CallbackQueueToken>()

    private static let callback: FSEventStreamCallback = {
        _, context, count, paths, flags, ids in
        guard let context else { return }
        let callbackContext = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
        guard let payload = buildOwnedPayload(
            numEvents: Int(count),
            eventPaths: paths,
            eventFlags: flags,
            eventIDs: ids
        ) else { return }
        callbackContext.watcher?.accept(payload, generation: callbackContext.generation)
    }

    package nonisolated static func buildOwnedPayload(
        numEvents: Int,
        eventPaths: UnsafeMutableRawPointer,
        eventFlags: UnsafePointer<FSEventStreamEventFlags>,
        eventIDs: UnsafePointer<FSEventStreamEventId>
    ) -> FileSystemWatchEventPayload? {
        guard numEvents > 0 else { return nil }
        let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        let safeCount = min(numEvents, CFArrayGetCount(array))
        guard safeCount > 0 else { return nil }

        var entries: [FileSystemWatchEvent] = []
        entries.reserveCapacity(safeCount)
        for index in 0 ..< safeCount {
            guard let rawValue = CFArrayGetValueAtIndex(array, index) else { continue }
            let object = unsafeBitCast(rawValue, to: CFTypeRef.self)
            let path: String? = if CFGetTypeID(object) == CFStringGetTypeID() {
                deepCopyEventPath(unsafeBitCast(rawValue, to: CFString.self))
            } else if let string = object as? String {
                deepCopySwiftString(string)
            } else {
                nil
            }
            guard let path else { continue }
            entries.append(
                FileSystemWatchEvent(
                    path: path,
                    flags: semanticFlags(for: eventFlags[index]),
                    id: FileSystemWatchEventID(eventIDs[index])
                )
            )
        }
        return entries.isEmpty ? nil : FileSystemWatchEventPayload(entries: entries)
    }

    package nonisolated static func semanticFlags(
        for rawFlags: FSEventStreamEventFlags
    ) -> FileSystemWatchEventFlags {
        let raw = UInt32(rawFlags)
        var flags: FileSystemWatchEventFlags = []
        func map(_ nativeFlag: Int, to semanticFlag: FileSystemWatchEventFlags) {
            if raw & UInt32(nativeFlag) != 0 { flags.insert(semanticFlag) }
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
        map(kFSEventStreamEventFlagHistoryDone, to: .historyDone)
        map(kFSEventStreamEventFlagEventIdsWrapped, to: .eventIDsWrapped)
        return flags
    }

    package nonisolated static func deepCopySwiftString(_ source: String) -> String {
        String(decoding: Array(source.utf8), as: UTF8.self)
    }

    package nonisolated static func deepCopyEventPath(_ source: CFString) -> String? {
        let length = CFStringGetLength(source)
        if length == 0 { return "" }
        let encoding = CFStringBuiltInEncodings.UTF8.rawValue
        if let direct = CFStringGetCStringPtr(source, encoding) {
            return String(cString: direct)
        }
        let capacity = max(CFStringGetMaximumSizeForEncoding(length, encoding) + 1, 1)
        var buffer = [CChar](repeating: 0, count: capacity)
        if buffer.withUnsafeMutableBufferPointer({
            CFStringGetCString(source, $0.baseAddress, $0.count, encoding)
        }) {
            return String(cString: buffer)
        }
        var utf16 = [UniChar](repeating: 0, count: length)
        CFStringGetCharacters(source, CFRange(location: 0, length: length), &utf16)
        return String(utf16CodeUnits: utf16, count: utf16.count)
    }

    private enum LifecycleState {
        case idle
        case starting(StartAttempt)
        case watching(ActiveStream)
    }

    private struct StartAttempt {
        let generation: UInt64
        let startEventID: FileSystemWatchEventID
        let handler: @Sendable (FileSystemWatchEventPayload) -> Void
        let context: CallbackContext
    }

    private struct ActiveStream {
        let generation: UInt64
        let handler: @Sendable (FileSystemWatchEventPayload) -> Void
        let stream: any MacOSFSEventStreamToken
        let context: CallbackContext
    }

    private struct StreamDisposal: @unchecked Sendable {
        let stream: any MacOSFSEventStreamToken
        let wasStarted: Bool
        let context: CallbackContext
    }

    private final class CallbackContext: @unchecked Sendable {
        weak var watcher: MacOSFSEventsWatcher?
        let generation: UInt64

        init(watcher: MacOSFSEventsWatcher, generation: UInt64) {
            self.watcher = watcher
            self.generation = generation
        }
    }

    private final class CallbackQueueToken: @unchecked Sendable {}
}

package struct MacOSFSEventsWatcherFactory: FileSystemWatcherCreating {
    package init() {}

    package func makeWatcher(path: String) -> any FileSystemWatching {
        MacOSFSEventsWatcher(path: path)
    }
}

private extension NSCondition {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
