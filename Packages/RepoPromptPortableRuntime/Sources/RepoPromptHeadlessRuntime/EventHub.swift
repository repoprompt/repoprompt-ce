import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel

public actor ServiceEventHub {
    private var subscribers: [UUID: AsyncThrowingStream<EventEnvelope, Error>.Continuation] = [:]
    private let subscriberBufferLimit: Int

    public init(subscriberBufferLimit: Int = 1024) {
        self.subscriberBufferLimit = subscriberBufferLimit
    }

    public func publish(_ event: EventEnvelope) {
        var exhausted: [UUID] = []
        for (id, continuation) in subscribers {
            if case .dropped = continuation.yield(event) {
                continuation.finish(
                    throwing: ServiceAPIError(
                        code: .rateLimited,
                        message: "Event subscriber fell behind; reconnect from the supplied cursor",
                        retryable: true,
                        cursor: event.cursor
                    )
                )
                exhausted.append(id)
            }
        }
        for id in exhausted {
            subscribers[id] = nil
        }
    }

    public func subscribe() -> AsyncThrowingStream<EventEnvelope, Error> {
        let id = UUID()
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(subscriberBufferLimit)) { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { _ in Task { await self.remove(id) } }
        }
    }

    private func remove(_ id: UUID) {
        subscribers[id] = nil
    }
}
