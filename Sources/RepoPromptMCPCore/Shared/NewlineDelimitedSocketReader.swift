//
//  NewlineDelimitedSocketReader.swift
//  RepoPrompt
//
//  Shared helper that reads newline-delimited frames from a non-blocking socket
//  using DispatchSourceRead. Keeps blocking work off actor executors and yields
//  frames via callbacks.
//

import Dispatch
import Foundation
import Logging

#if canImport(Darwin)
    import Darwin

    private let systemRead = Darwin.read
#elseif canImport(Glibc)
    import Glibc

    private let systemRead = Glibc.read
#endif

public enum ReadSourceFDPreflightError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case invalidFileDescriptor(label: String, fd: Int32)
    case descriptorCheckFailed(label: String, fd: Int32, errno: Int32)

    public var description: String {
        switch self {
        case let .invalidFileDescriptor(label, fd):
            "Invalid file descriptor for \(label): \(fd)"
        case let .descriptorCheckFailed(label, fd, errno):
            "File descriptor check failed for \(label) fd=\(fd) errno=\(errno)"
        }
    }

    public var errorDescription: String? {
        description
    }
}

public enum ReadSourceFDPreflight {
    public static func validateOpenFD(_ fd: Int32, label: String) throws {
        guard fd >= 0 else {
            throw ReadSourceFDPreflightError.invalidFileDescriptor(label: label, fd: fd)
        }

        guard fcntl(fd, F_GETFL) >= 0 else {
            throw ReadSourceFDPreflightError.descriptorCheckFailed(label: label, fd: fd, errno: errno)
        }
    }

    public static func makeReadSource(
        fileDescriptor fd: Int32,
        queue: DispatchQueue,
        label: String
    ) throws -> DispatchSourceRead {
        try validateOpenFD(fd, label: label)
        return DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    }
}

public enum NewlineDelimitedSocketReaderTerminal: @unchecked Sendable {
    case eof(hasResidualData: Bool)
    case error(Swift.Error)
}

/// Event-driven reader for newline-delimited socket frames.
/// Not actor-isolated; intended to be driven from transports on a dedicated queue.
/// Each instance is single-use; create a new reader after stop or terminal delivery.
public final class NewlineDelimitedSocketReader {
    typealias ReadOperation = (Int32, UnsafeMutableRawPointer?, Int) -> Int

    private struct ReadEventSource {
        let id: ObjectIdentifier
        private let setEventHandlerImpl: (@escaping () -> Void) -> Void
        private let setCancelHandlerImpl: (@escaping () -> Void) -> Void
        private let resumeImpl: () -> Void
        private let cancelImpl: () -> Void

        init(_ source: DispatchSourceRead) {
            id = ObjectIdentifier(source as AnyObject)
            setEventHandlerImpl = { source.setEventHandler(handler: $0) }
            setCancelHandlerImpl = { source.setCancelHandler(handler: $0) }
            resumeImpl = { source.resume() }
            cancelImpl = { source.cancel() }
        }

        func setEventHandler(_ handler: @escaping () -> Void) {
            setEventHandlerImpl(handler)
        }

        func setCancelHandler(_ handler: @escaping () -> Void) {
            setCancelHandlerImpl(handler)
        }

        func resume() {
            resumeImpl()
        }

        func cancel() {
            cancelImpl()
        }
    }

    private enum Lifecycle: Equatable {
        case idle
        case running
        case terminal
        case stopped
    }

    private static let defaultMaxReadCallsPerEvent = 32
    private static let defaultMaxBytesPerEvent = 256 * 1024
    private static let defaultMaxFramesPerEvent = 128

    private let fd: Int32
    private let queue: DispatchQueue
    private let logger: Logger
    private let delimiter: UInt8
    private let chunkSize: Int
    private let bufferReservation: Int
    private let maxReadCallsPerEvent: Int
    private let maxBytesPerEvent: Int
    private let maxFramesPerEvent: Int
    private let readOperation: ReadOperation
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let onFrame: (Data) -> Void
    private let onEOF: (_ hasResidualData: Bool) -> Void
    private let onError: (Swift.Error) -> Void
    private let onBytesRead: (() -> Void)?
    private let onCancel: (() -> Void)?

    private var source: ReadEventSource?
    private var pendingCancelledSources: [ObjectIdentifier: ReadEventSource] = [:]
    private var buffer = Data()
    private var lifecycle = Lifecycle.idle
    private var generation: UInt64 = 0
    private var pumpRunning = false
    private var pumpScheduled = false
    private var readableEventPending = false

    public convenience init(
        fd: Int32,
        queue: DispatchQueue,
        logger: Logger,
        delimiter: UInt8 = UInt8(ascii: "\n"),
        chunkSize: Int = 16384,
        bufferReservation: Int = 64 * 1024,
        onFrame: @escaping (Data) -> Void,
        onTerminal: @escaping (NewlineDelimitedSocketReaderTerminal) -> Void,
        onBytesRead: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.init(
            fd: fd,
            queue: queue,
            logger: logger,
            delimiter: delimiter,
            chunkSize: chunkSize,
            bufferReservation: bufferReservation,
            onFrame: onFrame,
            onEOF: { onTerminal(.eof(hasResidualData: $0)) },
            onError: { onTerminal(.error($0)) },
            onBytesRead: onBytesRead,
            onCancel: onCancel
        )
    }

    public convenience init(
        fd: Int32,
        queue: DispatchQueue,
        logger: Logger,
        delimiter: UInt8 = UInt8(ascii: "\n"),
        chunkSize: Int = 16384,
        bufferReservation: Int = 64 * 1024,
        onFrame: @escaping (Data) -> Void,
        onEOF: @escaping (_ hasResidualData: Bool) -> Void,
        onError: @escaping (Swift.Error) -> Void,
        onBytesRead: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.init(
            fd: fd,
            queue: queue,
            logger: logger,
            delimiter: delimiter,
            chunkSize: chunkSize,
            bufferReservation: bufferReservation,
            maxReadCallsPerEvent: Self.defaultMaxReadCallsPerEvent,
            maxBytesPerEvent: Self.defaultMaxBytesPerEvent,
            maxFramesPerEvent: Self.defaultMaxFramesPerEvent,
            readOperation: systemRead,
            onFrame: onFrame,
            onEOF: onEOF,
            onError: onError,
            onBytesRead: onBytesRead,
            onCancel: onCancel
        )
    }

    init(
        fd: Int32,
        queue: DispatchQueue,
        logger: Logger,
        delimiter: UInt8 = UInt8(ascii: "\n"),
        chunkSize: Int = 16384,
        bufferReservation: Int = 64 * 1024,
        maxReadCallsPerEvent: Int = NewlineDelimitedSocketReader.defaultMaxReadCallsPerEvent,
        maxBytesPerEvent: Int = NewlineDelimitedSocketReader.defaultMaxBytesPerEvent,
        maxFramesPerEvent: Int = NewlineDelimitedSocketReader.defaultMaxFramesPerEvent,
        readOperation: @escaping ReadOperation,
        onFrame: @escaping (Data) -> Void,
        onEOF: @escaping (_ hasResidualData: Bool) -> Void,
        onError: @escaping (Swift.Error) -> Void,
        onBytesRead: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.fd = fd
        self.queue = queue
        self.logger = logger
        self.delimiter = delimiter
        self.chunkSize = chunkSize
        self.bufferReservation = bufferReservation
        self.maxReadCallsPerEvent = max(1, maxReadCallsPerEvent)
        self.maxBytesPerEvent = max(1, maxBytesPerEvent)
        self.maxFramesPerEvent = max(1, maxFramesPerEvent)
        self.readOperation = readOperation
        self.onFrame = onFrame
        self.onEOF = onEOF
        self.onError = onError
        self.onBytesRead = onBytesRead
        self.onCancel = onCancel
        buffer.reserveCapacity(bufferReservation)
        queue.setSpecific(key: queueKey, value: 1)
    }

    public func start() throws {
        try syncOnQueue {
            guard lifecycle == .idle else { return }

            generation &+= 1
            let sourceGeneration = generation
            buffer.removeAll(keepingCapacity: true)
            readableEventPending = false
            pumpRunning = false
            pumpScheduled = false

            let dispatchSource = try ReadSourceFDPreflight.makeReadSource(
                fileDescriptor: fd,
                queue: queue,
                label: "newline-delimited socket reader"
            )
            let source = ReadEventSource(dispatchSource)
            let sourceID = source.id
            self.source = source
            lifecycle = .running

            source.setEventHandler { [weak self] in
                self?.handleReadableEventOnQueue(generation: sourceGeneration)
            }
            source.setCancelHandler { [weak self] in
                self?.handleSourceCancelledOnQueue(sourceID: sourceID)
            }
            source.resume()
        }
    }

    func processReadableEvent() {
        syncOnQueue {
            if lifecycle == .idle {
                generation &+= 1
                lifecycle = .running
            }
            handleReadableEventOnQueue(generation: generation)
        }
    }

    private func handleReadableEventOnQueue(generation eventGeneration: UInt64) {
        guard eventGeneration == generation, lifecycle == .running else { return }
        readableEventPending = true
        guard !pumpRunning else { return }
        runReadablePumpOnQueue(generation: eventGeneration)
    }

    private func runReadablePumpOnQueue(generation pumpGeneration: UInt64) {
        guard pumpGeneration == generation, lifecycle == .running else { return }
        pumpRunning = true
        readableEventPending = false
        let needsContinuation = processReadableEventPass(generation: pumpGeneration)
        pumpRunning = false
        if needsContinuation {
            readableEventPending = true
        }
        schedulePendingReadableEventIfNeeded(generation: pumpGeneration)
    }

    private func processReadableEventPass(generation pumpGeneration: UInt64) -> Bool {
        let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { readBuffer.deallocate() }

        var notifiedBytesRead = false
        var readCallCount = 0
        var byteCount = 0
        var frameCount = 0

        while pumpGeneration == generation, lifecycle == .running {
            frameCount += drainCompleteFrames(
                limit: maxFramesPerEvent - frameCount,
                generation: pumpGeneration
            )
            guard pumpGeneration == generation, lifecycle == .running else { return false }
            if frameCount >= maxFramesPerEvent {
                return true
            }
            if readCallCount >= maxReadCallsPerEvent || byteCount >= maxBytesPerEvent {
                return true
            }

            let requestedBytes = min(chunkSize, maxBytesPerEvent - byteCount)
            readCallCount += 1
            let bytesRead = readOperation(fd, readBuffer, requestedBytes)

            if bytesRead < 0 {
                let err = errno
                if err == EINTR {
                    continue
                } else if err == EAGAIN || err == EWOULDBLOCK {
                    break
                } else {
                    let posixError = POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
                    logger.error("NewlineDelimitedSocketReader read error: \(err)")
                    finishTerminalOnQueue(.failure(posixError), generation: pumpGeneration)
                    return false
                }
            }

            if bytesRead == 0 {
                finishTerminalOnQueue(.success(!buffer.isEmpty), generation: pumpGeneration)
                return false
            }

            buffer.append(readBuffer, count: bytesRead)
            byteCount += bytesRead
            if !notifiedBytesRead {
                notifiedBytesRead = true
                onBytesRead?()
                guard pumpGeneration == generation, lifecycle == .running else { return false }
            }
        }
        return false
    }

    @discardableResult
    private func drainCompleteFrames(limit: Int, generation pumpGeneration: UInt64) -> Int {
        guard limit > 0 else { return 0 }

        var drainedCount = 0
        while drainedCount < limit,
              pumpGeneration == generation,
              lifecycle == .running,
              let newlineIndex = buffer.firstIndex(of: delimiter)
        {
            let frame = Data(buffer[..<newlineIndex])
            let nextStart = buffer.index(after: newlineIndex)
            buffer.removeSubrange(..<nextStart)
            drainedCount += 1

            if !frame.isEmpty {
                onFrame(frame)
            }
        }
        return drainedCount
    }

    private func schedulePendingReadableEventIfNeeded(generation pumpGeneration: UInt64) {
        guard pumpGeneration == generation,
              lifecycle == .running,
              readableEventPending
        else {
            readableEventPending = false
            return
        }
        guard !pumpScheduled else { return }
        pumpScheduled = true
        queue.async { [weak self] in
            guard let self else { return }
            pumpScheduled = false
            guard pumpGeneration == generation,
                  lifecycle == .running,
                  readableEventPending
            else {
                return
            }
            runReadablePumpOnQueue(generation: pumpGeneration)
        }
    }

    public func stop() {
        syncOnQueue {
            stopOnQueue()
        }
    }

    private func stopOnQueue() {
        guard lifecycle != .stopped else { return }
        generation &+= 1
        lifecycle = .stopped
        readableEventPending = false
        pumpScheduled = false
        buffer.removeAll(keepingCapacity: true)
        cancelCurrentSourceOnQueue()
    }

    private func finishTerminalOnQueue(
        _ result: Result<Bool, Swift.Error>,
        generation terminalGeneration: UInt64
    ) {
        guard terminalGeneration == generation, lifecycle == .running else { return }
        lifecycle = .terminal
        readableEventPending = false
        pumpScheduled = false
        cancelCurrentSourceOnQueue()

        switch result {
        case let .success(hasResidualData):
            onEOF(hasResidualData)
        case let .failure(error):
            onError(error)
        }
    }

    private func cancelCurrentSourceOnQueue() {
        guard let source else { return }
        self.source = nil
        pendingCancelledSources[source.id] = source
        source.cancel()
    }

    private func handleSourceCancelledOnQueue(sourceID: ObjectIdentifier) {
        guard pendingCancelledSources.removeValue(forKey: sourceID) != nil else { return }
        onCancel?()
    }

    private func syncOnQueue<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try operation()
        }
        return try queue.sync(execute: operation)
    }
}
