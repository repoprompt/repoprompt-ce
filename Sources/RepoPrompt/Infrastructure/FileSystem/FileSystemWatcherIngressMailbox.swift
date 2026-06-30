import CoreServices
import Foundation

/// Owns deep-copied FSEvent callback payloads synchronously before actor entry.
///
/// The FSEvents callback can run outside the `FileSystemService` actor. This mailbox
/// assigns a per-root monotonic watermark before any task is created, preserves FIFO
/// payload order, and retains at most one drain task. Under pressure it collapses
/// queued details to the existing root-rescan sentinel contract without discarding
/// accepted progress.
final class FileSystemWatcherIngressMailbox: @unchecked Sendable {
    struct Watermark: Hashable, Comparable {
        let rawValue: UInt64

        static let zero = Watermark(rawValue: 0)

        static func < (lhs: Watermark, rhs: Watermark) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct AcceptedPayload: @unchecked Sendable {
        enum Contents: @unchecked Sendable {
            case entries([FSEventCallbackEntry])
            case overflowRootRescan(
                highestEventID: FSEventStreamEventId,
                changedIgnoreAbsolutePaths: Set<String>
            )
        }

        let lowestAcceptedWatermark: Watermark
        let acceptedHighWatermark: Watermark
        let contents: Contents
        let lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?

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
            let queuedAcceptedWatermarkRange: ClosedRange<Watermark>?
            let queuedPayloadCount: Int
            let queuedRawEntryCount: Int
            let hasOverflowRootRescan: Bool
            let isAutomaticDrainPaused: Bool
        }
    #endif

    private let lock = NSLock()
    private let maxQueuedRawEntries: Int
    private var isAccepting = true
    private var isAutomaticDrainPaused = false
    private var nextAcceptedSequence: UInt64 = 0
    private var acceptedHighWatermark = Watermark.zero
    private var queuedPayloads: [AcceptedPayload] = []
    private var queuedPayloadHead = 0
    private var queuedRawEntryCount = 0
    private var hasOverflowRootRescan = false
    private var nextDrainToken: UInt64 = 0
    private var activeDrainToken: UInt64?
    private var drainTask: Task<Void, Never>?

    init(maxQueuedRawEntries: Int) {
        self.maxQueuedRawEntries = max(1, maxQueuedRawEntries)
    }

    func startAccepting() {
        lock.lock()
        isAccepting = true
        lock.unlock()
    }

    /// Stops callback acceptance from scheduling actor drain work. Explicit FIFO
    /// takes remain available so a seeded initialization can replay a precise cut.
    func pauseAutomaticDraining() {
        lock.lock()
        isAutomaticDrainPaused = true
        lock.unlock()
    }

    /// Restores ordinary callback-driven draining and immediately schedules any
    /// payloads that accumulated while the mailbox was paused.
    func resumeAutomaticDraining(
        scheduleDrain: @escaping @Sendable () async -> Void
    ) {
        lock.lock()
        isAutomaticDrainPaused = false
        scheduleDrainIfNeeded(scheduleDrain)
        lock.unlock()
    }

    func stopAcceptingAndDiscardPending() {
        lock.lock()
        isAccepting = false
        isAutomaticDrainPaused = false
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

    func captureAcceptedWatermark() -> Watermark {
        lock.lock()
        defer { lock.unlock() }
        return acceptedHighWatermark
    }

    @discardableResult
    func accept(
        _ payload: FSEventCallbackPayload,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?,
        scheduleDrain: (@Sendable () async -> Void)?
    ) -> Watermark? {
        guard !payload.entries.isEmpty else { return nil }

        lock.lock()
        guard isAccepting else {
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
            lifecycleCorrelation: lifecycleCorrelation
        )
        appendOrCollapse(acceptedPayload)
        if let scheduleDrain {
            scheduleDrainIfNeeded(scheduleDrain)
        }
        lock.unlock()
        return watermark
    }

    func takeNextAcceptedPayload(through target: Watermark? = nil) -> AcceptedPayload? {
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
                queuedAcceptedWatermarkRange: queuedPayloadHead < queuedPayloads.count
                    ? queuedPayloads[queuedPayloadHead].lowestAcceptedWatermark ... queuedPayloads[queuedPayloads.count - 1].acceptedHighWatermark
                    : nil,
                queuedPayloadCount: queuedPayloads.count - queuedPayloadHead,
                queuedRawEntryCount: queuedRawEntryCount,
                hasOverflowRootRescan: hasOverflowRootRescan,
                isAutomaticDrainPaused: isAutomaticDrainPaused
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
        var highestEventID: FSEventStreamEventId = 0
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
            lifecycleCorrelation: payload.lifecycleCorrelation
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
        guard isAccepting,
              !isAutomaticDrainPaused,
              activeDrainToken == nil,
              queuedPayloadHead < queuedPayloads.count
        else { return }
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
