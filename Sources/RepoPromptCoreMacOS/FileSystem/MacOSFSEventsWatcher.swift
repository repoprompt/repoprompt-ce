import CoreFoundation
import CoreServices
import Dispatch
import Foundation
import RepoPromptCore

package protocol MacOSFSEventStreamToken: AnyObject, Sendable {}

package protocol MacOSFSEventStreamBackend: Sendable {
    func createStream(
        path: String,
        callback: FSEventStreamCallback,
        contextInfo: UnsafeMutableRawPointer,
        callbackQueue: DispatchQueue
    ) -> (any MacOSFSEventStreamToken)?

    func startStream(_ stream: any MacOSFSEventStreamToken) -> Bool

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
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &streamContext,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0,
            createFlags
        ) else { return nil }

        FSEventStreamSetDispatchQueue(stream, callbackQueue)
        return CoreServicesFSEventStreamToken(stream: stream)
    }

    func startStream(_ stream: any MacOSFSEventStreamToken) -> Bool {
        guard let token = stream as? CoreServicesFSEventStreamToken else {
            assertionFailure("Unexpected FSEvents stream token type")
            return false
        }
        return FSEventStreamStart(token.stream)
    }

    func disposeStream(_ stream: any MacOSFSEventStreamToken, wasStarted: Bool) {
        guard let token = stream as? CoreServicesFSEventStreamToken else {
            assertionFailure("Unexpected FSEvents stream token type")
            return
        }
        if wasStarted {
            FSEventStreamStop(token.stream)
            FSEventStreamFlushSync(token.stream)
        }
        FSEventStreamInvalidate(token.stream)
        FSEventStreamRelease(token.stream)
    }
}

/// macOS adapter for CoreServices FSEvents lifecycle and raw-flag translation.
///
/// Reusable filesystem policy receives only deep-copied, semantic `FileSystemWatchEvent` values.
/// Stream references, callback context retention, and native bit mapping remain adapter-owned.
package final class MacOSFSEventsWatcher: FileSystemWatching, @unchecked Sendable {
    private let path: String
    private let callbackQueue: DispatchQueue
    private let disposalQueue: DispatchQueue
    private let streamBackend: any MacOSFSEventStreamBackend
    private let callbackQueueToken = CallbackQueueToken()
    private let condition = NSCondition()
    private var lifecycleState: LifecycleState = .idle
    private var nextGeneration: UInt64 = 0

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
        condition.lock()
        defer { condition.unlock() }
        if case .watching = lifecycleState {
            return true
        }
        return false
    }

    @discardableResult
    package func start(eventHandler: @escaping @Sendable (FileSystemWatchEventPayload) -> Void) -> Bool {
        while true {
            condition.lock()
            switch lifecycleState {
            case .idle:
                let generation = nextGenerationLocked()
                let context = CallbackContext(watcher: self, generation: generation)
                let attempt = StartAttempt(
                    generation: generation,
                    handler: eventHandler,
                    context: context
                )
                lifecycleState = .starting(attempt)
                condition.unlock()
                return runStartAttempt(attempt)
            case .watching:
                condition.unlock()
                return true
            case .starting:
                condition.wait()
                condition.unlock()
            }
        }
    }

    package func stop() {
        let disposal: StreamDisposal?
        condition.lock()
        switch lifecycleState {
        case .idle:
            condition.unlock()
            return
        case .starting:
            lifecycleState = .idle
            condition.broadcast()
            condition.unlock()
            return
        case let .watching(activeStream):
            lifecycleState = .idle
            condition.broadcast()
            disposal = StreamDisposal(
                stream: activeStream.stream,
                wasStarted: true,
                context: activeStream.context
            )
            condition.unlock()
        }

        if let disposal {
            disposeStream(disposal)
        }
    }

    deinit {
        stop()
    }

    private func runStartAttempt(_ attempt: StartAttempt) -> Bool {
        guard let stream = streamBackend.createStream(
            path: path,
            callback: Self.callback,
            contextInfo: Unmanaged.passUnretained(attempt.context).toOpaque(),
            callbackQueue: callbackQueue
        ) else {
            clearStartingAttemptIfCurrent(attempt)
            print("Failed to create FSEventStream for \(path)")
            return false
        }

        guard isStartingAttemptCurrent(attempt) else {
            disposeStream(StreamDisposal(
                stream: stream,
                wasStarted: false,
                context: attempt.context
            ))
            return false
        }

        guard streamBackend.startStream(stream) else {
            clearStartingAttemptIfCurrent(attempt)
            disposeStream(StreamDisposal(
                stream: stream,
                wasStarted: false,
                context: attempt.context
            ))
            print("Failed to start FSEventStream for \(path)")
            return false
        }

        condition.lock()
        let shouldCommit: Bool
        if case let .starting(currentAttempt) = lifecycleState,
           currentAttempt.generation == attempt.generation
        {
            lifecycleState = .watching(ActiveStream(
                generation: attempt.generation,
                handler: attempt.handler,
                stream: stream,
                context: attempt.context
            ))
            condition.broadcast()
            shouldCommit = true
        } else {
            shouldCommit = false
        }
        condition.unlock()

        if shouldCommit {
            return true
        }

        disposeStream(StreamDisposal(
            stream: stream,
            wasStarted: true,
            context: attempt.context
        ))
        return false
    }

    @discardableResult
    private func clearStartingAttemptIfCurrent(_ attempt: StartAttempt) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard case let .starting(currentAttempt) = lifecycleState,
              currentAttempt.generation == attempt.generation
        else { return false }
        lifecycleState = .idle
        condition.broadcast()
        return true
    }

    private func isStartingAttemptCurrent(_ attempt: StartAttempt) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard case let .starting(currentAttempt) = lifecycleState else {
            return false
        }
        return currentAttempt.generation == attempt.generation
    }

    private func accept(_ payload: FileSystemWatchEventPayload, generation: UInt64) {
        let handler: (@Sendable (FileSystemWatchEventPayload) -> Void)?
        condition.lock()
        switch lifecycleState {
        case let .starting(attempt) where attempt.generation == generation:
            handler = attempt.handler
        case let .watching(activeStream) where activeStream.generation == generation:
            handler = activeStream.handler
        case .idle, .starting, .watching:
            handler = nil
        }
        condition.unlock()

        handler?(payload)
    }

    private func disposeStream(_ disposal: StreamDisposal) {
        let streamBackend = streamBackend
        let disposalQueue = disposalQueue
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
        if nextGeneration == 0 {
            nextGeneration = 1
        }
        return nextGeneration
    }

    private static let callbackQueueKey = DispatchSpecificKey<CallbackQueueToken>()

    private static let callback: FSEventStreamCallback = {
        _, context, numEvents, eventPaths, eventFlags, eventIDs in
        guard let context else { return }
        let callbackContext = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
        guard let payload = buildOwnedPayload(
            numEvents: Int(numEvents),
            eventPaths: eventPaths,
            eventFlags: eventFlags,
            eventIDs: eventIDs
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

    package nonisolated static func semanticFlags(for rawFlags: FSEventStreamEventFlags) -> FileSystemWatchEventFlags {
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

    package nonisolated static func deepCopySwiftString(_ source: String) -> String {
        String(decoding: Array(source.utf8), as: UTF8.self)
    }

    package nonisolated static func deepCopyEventPath(_ source: CFString) -> String? {
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

    private enum LifecycleState {
        case idle
        case starting(StartAttempt)
        case watching(ActiveStream)
    }

    private struct StartAttempt {
        let generation: UInt64
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
