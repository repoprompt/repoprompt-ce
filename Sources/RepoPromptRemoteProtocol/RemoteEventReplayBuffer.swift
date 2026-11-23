import Foundation

public enum RemoteEventReplayResult: Sendable, Equatable {
    case events([RemoteEvent])
    case snapshotRequired
}

public struct RemoteEventSubscription: Sendable {
    public let initialEvents: [RemoteEvent]
    public let liveEvents: AsyncStream<RemoteEvent>

    public init(initialEvents: [RemoteEvent], liveEvents: AsyncStream<RemoteEvent>) {
        self.initialEvents = initialEvents
        self.liveEvents = liveEvents
    }
}

public enum RemoteEventSubscriptionResult: Sendable {
    case subscription(RemoteEventSubscription)
    case snapshotRequired
}

/// Bounded, in-memory event history for a single desktop instance.
///
/// The gateway owns one buffer and uses it for reconnects. If a mobile cursor is
/// older than the retained range, the caller must send a complete authoritative
/// snapshot before resuming live events.
public actor RemoteEventReplayBuffer {
    public let capacity: Int
    private var events: [RemoteEvent] = []
    private struct Subscriber {
        let desktopInstanceID: String
        let continuation: AsyncStream<RemoteEvent>.Continuation
    }

    private var eventIDs: Set<UUID> = []
    private var nextSequence: UInt64 = 1
    private var subscribers: [UUID: Subscriber] = [:]

    public init(capacity: Int = 512) {
        precondition(capacity > 0, "Remote event replay capacity must be positive")
        self.capacity = capacity
    }

    @discardableResult
    public func append(_ event: RemoteEvent) -> RemoteEvent {
        guard !eventIDs.contains(event.eventID) else {
            return events.first(where: { $0.eventID == event.eventID }) ?? event
        }

        let sequenced = event.assigning(sequence: nextSequence)
        nextSequence += 1
        events.append(sequenced)
        eventIDs.insert(sequenced.eventID)

        if events.count > capacity {
            let removeCount = events.count - capacity
            for _ in 0 ..< removeCount {
                let event = events.removeFirst()
                eventIDs.remove(event.eventID)
            }
        }
        var terminatedSubscriptionIDs: [UUID] = []
        for (subscriptionID, subscriber) in subscribers
            where subscriber.desktopInstanceID == sequenced.desktopInstanceID
        {
            switch subscriber.continuation.yield(sequenced) {
            case .enqueued:
                break
            case .dropped, .terminated:
                // A stalled consumer must reconnect from its last applied
                // cursor rather than accumulating memory or observing a gap.
                subscriber.continuation.finish()
                terminatedSubscriptionIDs.append(subscriptionID)
            @unknown default:
                subscriber.continuation.finish()
                terminatedSubscriptionIDs.append(subscriptionID)
            }
        }
        for subscriptionID in terminatedSubscriptionIDs {
            subscribers.removeValue(forKey: subscriptionID)
        }
        return sequenced
    }

    public func replay(
        after cursor: UInt64?,
        desktopInstanceID: String
    ) -> RemoteEventReplayResult {
        guard let cursor else { return .events(events) }
        guard let first = events.first else { return .events([]) }
        guard cursor >= first.sequence - 1 else { return .snapshotRequired }

        return .events(events.filter {
            $0.desktopInstanceID == desktopInstanceID && $0.sequence > cursor
        })
    }

    /// Atomically captures the retained replay and registers live delivery.
    /// Events appended after this actor method returns are buffered in
    /// `liveEvents` while the caller sends `initialEvents`, closing the replay/live race.
    public func subscribe(
        after cursor: UInt64?,
        desktopInstanceID: String
    ) -> RemoteEventSubscriptionResult {
        let initialEvents: [RemoteEvent]
        switch replay(after: cursor, desktopInstanceID: desktopInstanceID) {
        case let .events(events):
            initialEvents = events
        case .snapshotRequired:
            return .snapshotRequired
        }

        let subscriptionID = UUID()
        var capturedContinuation: AsyncStream<RemoteEvent>.Continuation?
        let stream = AsyncStream<RemoteEvent>(bufferingPolicy: .bufferingOldest(capacity)) { continuation in
            capturedContinuation = continuation
        }
        guard let continuation = capturedContinuation else {
            preconditionFailure("AsyncStream did not synchronously vend its continuation")
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(subscriptionID) }
        }
        subscribers[subscriptionID] = Subscriber(
            desktopInstanceID: desktopInstanceID,
            continuation: continuation
        )
        return .subscription(RemoteEventSubscription(initialEvents: initialEvents, liveEvents: stream))
    }

    public func latestCursor() -> UInt64 {
        events.last?.sequence ?? 0
    }

    public func removeAll() {
        events.removeAll(keepingCapacity: true)
        eventIDs.removeAll(keepingCapacity: true)
    }

    public func finishSubscriptions() {
        let continuations = subscribers.values.map(\.continuation)
        subscribers.removeAll(keepingCapacity: true)
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
