import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel

/// Every host-owned live event consumer must register one of these roles. The
/// hub is the guard: there is no subscription API that can bypass its durable
/// `(storeID, globalSequence)` cursor gate.
public enum ServiceEventConsumerKind: String, CaseIterable, Codable, Sendable {
    case sse
    case portal
    case mcpNotification
    case counter
    case projection
}

public enum ServiceEventConsumerDeliveryMode: String, Codable, Sendable {
    case cursorGatedLive
    case durableQuery
    case absent
}

public struct ServiceEventConsumerRegistration: Codable, Sendable, Equatable {
    public let kind: ServiceEventConsumerKind
    public let deliveryMode: ServiceEventConsumerDeliveryMode
    public let detail: String
}

/// Exhaustive PR5 consumer registry. Portal delivery remains PR6 scope and this
/// server exposes no MCP notification bridge; counters/projections are derived
/// from durable queries rather than live delivery.
public enum ServiceEventConsumerRegistry {
    public static let registrations: [ServiceEventConsumerRegistration] = [
        .init(kind: .sse, deliveryMode: .cursorGatedLive, detail: "client-resumable EventDeliveryCursorGate"),
        .init(kind: .portal, deliveryMode: .absent, detail: "portal event projection is not present before PR6"),
        .init(kind: .mcpNotification, deliveryMode: .absent, detail: "no MCP event-notification surface is exposed"),
        .init(kind: .counter, deliveryMode: .durableQuery, detail: "metrics derive from SQLite operational snapshots"),
        .init(kind: .projection, deliveryMode: .durableQuery, detail: "authority projections derive from committed rows")
    ]

    public static func registration(for kind: ServiceEventConsumerKind) -> ServiceEventConsumerRegistration {
        precondition(registrations.count == ServiceEventConsumerKind.allCases.count)
        return registrations.first(where: { $0.kind == kind })!
    }
}

public actor ServiceEventHub {
    private struct Subscriber {
        let kind: ServiceEventConsumerKind
        let continuation: AsyncThrowingStream<EventEnvelope, Error>.Continuation
        var gate: EventDeliveryCursorGate
    }

    public struct Snapshot: Sendable, Equatable {
        public let activeSubscribers: Int
        public let activeSubscribersByKind: [ServiceEventConsumerKind: Int]
        public let slowSubscriberTerminations: Int64
        public let lastPublishedCursor: ServiceCursor?
    }

    private var subscribers: [UUID: Subscriber] = [:]
    private let subscriberBufferLimit: Int
    private var slowSubscriberTerminations: Int64 = 0
    private var lastPublishedCursor: ServiceCursor?

    public init(subscriberBufferLimit: Int = 1024) {
        self.subscriberBufferLimit = subscriberBufferLimit
    }

    public func publish(_ event: EventEnvelope) {
        var exhausted: [UUID] = []
        var advanced: [(UUID, Subscriber)] = []
        for (id, var subscriber) in subscribers {
            if let greatest = subscriber.gate.greatestDelivered,
               greatest.storeID != event.storeID
            {
                subscriber.continuation.finish(
                    throwing: ServiceAPIError(
                        code: .cursorExpired,
                        message: "Event store identity changed; obtain a new authoritative snapshot",
                        retryable: false,
                        cursor: greatest
                    )
                )
                exhausted.append(id)
                continue
            }
            var candidate = subscriber.gate
            guard candidate.shouldDeliver(event.cursor) else { continue }
            if case .dropped = subscriber.continuation.yield(event) {
                subscriber.continuation.finish(
                    throwing: ServiceAPIError(
                        code: .rateLimited,
                        message: "Event subscriber fell behind; reconnect from the supplied cursor",
                        retryable: true,
                        cursor: subscriber.gate.greatestDelivered
                    )
                )
                exhausted.append(id)
                slowSubscriberTerminations += 1
            } else {
                subscriber.gate = candidate
                advanced.append((id, subscriber))
            }
        }
        lastPublishedCursor = event.cursor
        for (id, subscriber) in advanced {
            subscribers[id] = subscriber
        }
        for id in exhausted {
            subscribers[id] = nil
        }
    }

    public func subscribe(
        consumer kind: ServiceEventConsumerKind,
        after cursor: ServiceCursor? = nil
    ) -> AsyncThrowingStream<EventEnvelope, Error> {
        let registration = ServiceEventConsumerRegistry.registration(for: kind)
        guard registration.deliveryMode == .cursorGatedLive else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: ServiceAPIError(
                    code: .capabilityMissing,
                    message: "Event consumer \(kind.rawValue) is \(registration.deliveryMode.rawValue): \(registration.detail)",
                    retryable: false
                ))
            }
        }
        let id = UUID()
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(subscriberBufferLimit)) { continuation in
            subscribers[id] = Subscriber(
                kind: kind,
                continuation: continuation,
                gate: EventDeliveryCursorGate(greatestDelivered: cursor)
            )
            continuation.onTermination = { _ in Task { await self.remove(id) } }
        }
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            activeSubscribers: subscribers.count,
            activeSubscribersByKind: Dictionary(
                grouping: subscribers.values,
                by: \.kind
            ).mapValues(\.count),
            slowSubscriberTerminations: slowSubscriberTerminations,
            lastPublishedCursor: lastPublishedCursor
        )
    }

    public func finish() {
        for subscriber in subscribers.values {
            subscriber.continuation.finish()
        }
        subscribers.removeAll()
    }

    private func remove(_ id: UUID) {
        subscribers[id] = nil
    }
}
