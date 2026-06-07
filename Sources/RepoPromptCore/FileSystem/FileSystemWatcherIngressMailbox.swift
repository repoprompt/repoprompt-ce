import Foundation

/// Owns deep-copied filesystem watcher callback payloads synchronously before actor entry.
///
/// The platform watcher callback can run outside the `FileSystemService` actor. This mailbox
/// assigns a per-root monotonic watermark before any task is created, preserves FIFO
/// payload order, and retains at most one drain task. Under pressure it collapses
/// queued details to the existing root-rescan sentinel contract without discarding
/// accepted progress.
package final class FileSystemWatcherIngressMailbox: @unchecked Sendable {
    package struct AcceptanceGeneration: Hashable {
        package let rawValue: UInt64
    }

    package struct Watermark: Hashable, Comparable {
        package let rawValue: UInt64

        package static let zero = Watermark(rawValue: 0)

        package static func < (lhs: Watermark, rhs: Watermark) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    package struct AcceptedPayload: @unchecked Sendable {
        enum Contents: @unchecked Sendable {
            case entries([FileSystemWatchEvent])
            case overflowRootRescan(
                highestEventID: FileSystemWatchEventID,
                changedIgnoreAbsolutePaths: Set<String>
            )
        }

        let lowestAcceptedWatermark: Watermark
        let acceptedHighWatermark: Watermark
        let contents: Contents
        let diagnosticContext: FileSystemDiagnosticContext?

        var rawEntryCount: Int {
            switch contents {
            case let .entries(entries):
                entries.count
            case .overflowRootRescan:
                1
            }
        }
    }

    #if DEBUG
        struct Snapshot: Equatable {
            let acceptedHighWatermark: Watermark
            let queuedPayloadCount: Int
            let queuedRawEntryCount: Int
            let hasOverflowRootRescan: Bool
        }
    #endif

    private let lock = NSLock()
    private let maxQueuedRawEntries: Int
    private var isAccepting = false
    private var nextAcceptanceGeneration: UInt64 = 0
    private var activeAcceptanceGeneration: AcceptanceGeneration?
    private var nextAcceptedSequence: UInt64 = 0
    private var acceptedHighWatermark = Watermark.zero
    private var queuedPayloads: [AcceptedPayload] = []
    private var queuedPayloadHead = 0
    private var queuedRawEntryCount = 0
    private var hasOverflowRootRescan = false
    private var nextDrainToken: UInt64 = 0
    private var activeDrainToken: UInt64?
    private var drainTask: Task<Void, Never>?

    package init(maxQueuedRawEntries: Int) {
        self.maxQueuedRawEntries = max(1, maxQueuedRawEntries)
    }

    package func startAccepting() -> AcceptanceGeneration {
        lock.lock()
        nextAcceptanceGeneration &+= 1
        let generation = AcceptanceGeneration(rawValue: nextAcceptanceGeneration)
        activeAcceptanceGeneration = generation
        isAccepting = true
        lock.unlock()
        return generation
    }

    /// Closes callback admission without discarding any payload that already returned accepted.
    @discardableResult
    package func stopAccepting() -> Watermark {
        lock.lock()
        isAccepting = false
        activeAcceptanceGeneration = nil
        let watermark = acceptedHighWatermark
        lock.unlock()
        return watermark
    }

    /// Destructive reset used only after the accepted cut has been flushed.
    package func discardPendingAndCancelDrain() {
        lock.lock()
        isAccepting = false
        activeAcceptanceGeneration = nil
        queuedPayloads.removeAll(keepingCapacity: false)
        queuedPayloadHead = 0
        queuedRawEntryCount = 0
        hasOverflowRootRescan = false
        activeDrainToken = nil
        let task = drainTask
        drainTask = nil
        lock.unlock()
        task?.cancel()
    }

    package func captureAcceptedWatermark() -> Watermark {
        lock.lock()
        defer { lock.unlock() }
        return acceptedHighWatermark
    }

    @discardableResult
    package func accept(
        _ payload: FileSystemWatchEventPayload,
        acceptanceGeneration: AcceptanceGeneration,
        diagnosticContext: FileSystemDiagnosticContext?,
        scheduleDrain: (@Sendable () async -> Void)?
    ) -> Watermark? {
        guard !payload.entries.isEmpty else { return nil }

        lock.lock()
        guard isAccepting, activeAcceptanceGeneration == acceptanceGeneration else {
            lock.unlock()
            return nil
        }

        nextAcceptedSequence &+= 1
        let watermark = Watermark(rawValue: nextAcceptedSequence)
        acceptedHighWatermark = watermark
        let acceptedPayload = AcceptedPayload(
            lowestAcceptedWatermark: watermark,
            acceptedHighWatermark: watermark,
            contents: .entries(payload.entries),
            diagnosticContext: diagnosticContext
        )
        appendOrCollapse(acceptedPayload)
        if let scheduleDrain {
            scheduleDrainIfNeeded(scheduleDrain)
        }
        lock.unlock()
        return watermark
    }

    package func takeNextAcceptedPayload(through target: Watermark? = nil) -> AcceptedPayload? {
        lock.lock()
        defer { lock.unlock() }
        guard queuedPayloadHead < queuedPayloads.count else { return nil }
        let first = queuedPayloads[queuedPayloadHead]
        if let target, first.lowestAcceptedWatermark > target {
            return nil
        }
        queuedPayloadHead += 1
        queuedRawEntryCount -= first.rawEntryCount
        compactConsumedPayloadsIfNeeded()
        return first
    }

    #if DEBUG
        func snapshotForTesting() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return Snapshot(
                acceptedHighWatermark: acceptedHighWatermark,
                queuedPayloadCount: queuedPayloads.count - queuedPayloadHead,
                queuedRawEntryCount: queuedRawEntryCount,
                hasOverflowRootRescan: hasOverflowRootRescan
            )
        }
    #endif

    private func appendOrCollapse(_ payload: AcceptedPayload) {
        if hasOverflowRootRescan {
            collapseQueuedPayloads(with: payload)
            return
        }

        let projectedRawEntryCount = queuedRawEntryCount + payload.rawEntryCount
        guard projectedRawEntryCount > maxQueuedRawEntries else {
            queuedPayloads.append(payload)
            queuedRawEntryCount = projectedRawEntryCount
            return
        }
        collapseQueuedPayloads(with: payload)
    }

    private func collapseQueuedPayloads(with payload: AcceptedPayload) {
        let payloads = Array(queuedPayloads.dropFirst(queuedPayloadHead)) + [payload]
        var lowestAcceptedWatermark = payload.lowestAcceptedWatermark
        var acceptedHighWatermark = payload.acceptedHighWatermark
        var highestEventID: FileSystemWatchEventID = 0
        var changedIgnoreAbsolutePaths = Set<String>()
        for queuedPayload in payloads {
            lowestAcceptedWatermark = min(lowestAcceptedWatermark, queuedPayload.lowestAcceptedWatermark)
            acceptedHighWatermark = max(acceptedHighWatermark, queuedPayload.acceptedHighWatermark)
            switch queuedPayload.contents {
            case let .entries(entries):
                for entry in entries {
                    highestEventID = max(highestEventID, entry.id)
                    if Self.isIgnoreControlPath(entry.path) {
                        changedIgnoreAbsolutePaths.insert(entry.path)
                    }
                }
            case let .overflowRootRescan(queuedHighestEventID, queuedIgnorePaths):
                highestEventID = max(highestEventID, queuedHighestEventID)
                changedIgnoreAbsolutePaths.formUnion(queuedIgnorePaths)
            }
        }
        queuedPayloads = [AcceptedPayload(
            lowestAcceptedWatermark: lowestAcceptedWatermark,
            acceptedHighWatermark: acceptedHighWatermark,
            contents: .overflowRootRescan(
                highestEventID: highestEventID,
                changedIgnoreAbsolutePaths: changedIgnoreAbsolutePaths
            ),
            diagnosticContext: payload.diagnosticContext
        )]
        queuedPayloadHead = 0
        queuedRawEntryCount = 1
        hasOverflowRootRescan = true
    }

    private func compactConsumedPayloadsIfNeeded() {
        guard queuedPayloadHead > 0 else { return }
        if queuedPayloadHead == queuedPayloads.count {
            queuedPayloads.removeAll(keepingCapacity: true)
            queuedPayloadHead = 0
            hasOverflowRootRescan = false
        } else if queuedPayloadHead >= 64, queuedPayloadHead * 2 >= queuedPayloads.count {
            queuedPayloads.removeFirst(queuedPayloadHead)
            queuedPayloadHead = 0
        }
    }

    private func scheduleDrainIfNeeded(_ scheduleDrain: @escaping @Sendable () async -> Void) {
        guard isAccepting, activeDrainToken == nil, queuedPayloadHead < queuedPayloads.count else { return }
        nextDrainToken &+= 1
        let token = nextDrainToken
        activeDrainToken = token
        drainTask = Task { [weak self] in
            await scheduleDrain()
            self?.drainTaskDidFinish(token: token, scheduleDrain: scheduleDrain)
        }
    }

    private func drainTaskDidFinish(
        token: UInt64,
        scheduleDrain: @escaping @Sendable () async -> Void
    ) {
        lock.lock()
        guard activeDrainToken == token else {
            lock.unlock()
            return
        }
        activeDrainToken = nil
        drainTask = nil
        scheduleDrainIfNeeded(scheduleDrain)
        lock.unlock()
    }

    private static func isIgnoreControlPath(_ path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent.lowercased()
        return filename == ".gitignore" || filename == ".repo_ignore" || filename == ".cursorignore"
    }
}
