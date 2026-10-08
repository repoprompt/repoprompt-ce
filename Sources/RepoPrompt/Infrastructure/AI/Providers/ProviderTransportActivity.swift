import Foundation
import RepoPromptDomainRuntime

/// Transport-liveness signalling for Oracle provider streams.
///
/// Context Builder follow-ups renew their inactivity budget only from stream
/// activity. Long-reasoning models can stay semantically silent for longer than
/// that budget while the transport is demonstrably alive, so providers report
/// liveness with the existing `transport_activity` result instead of content.
/// Liveness must come from a live transport (bytes received, or a child process
/// still running); a dead process or socket stops producing it, so a real hang
/// still exhausts the budget.
enum ProviderTransportActivity {
    /// Interval between liveness results while a buffered child-process request is in flight.
    static let pendingCompletionHeartbeatInterval: TimeInterval = 30
    /// Minimum spacing between liveness results derived from received transport bytes.
    static let receivedBytesMinimumInterval: Duration = .seconds(5)

    static func result() -> AIStreamResult {
        AIStreamResult(type: AIStreamResult.transportActivityType, text: nil)
    }
}

/// Rate-limits liveness results derived from received transport bytes.
struct ProviderTransportActivityThrottle {
    let minimumInterval: Duration
    private var lastEmission: ContinuousClock.Instant?

    init(minimumInterval: Duration = ProviderTransportActivity.receivedBytesMinimumInterval) {
        self.minimumInterval = minimumInterval
    }

    mutating func shouldEmit(at now: ContinuousClock.Instant) -> Bool {
        if let lastEmission, now - lastEmission < minimumInterval {
            return false
        }
        lastEmission = now
        return true
    }
}

/// Streams a buffered completion whose only liveness evidence is that its request
/// (for example a CLI child process that has not exited) is still in flight.
///
/// While `complete` is pending, a `transport_activity` result is yielded every
/// `heartbeatInterval`. Heartbeats stop as soon as `complete` returns or throws,
/// which for a child-process request means the child has exited and been reaped,
/// and every heartbeat precedes the completion's `content` and `message_stop`.
/// `sleep` must honor task cancellation.
///
/// Cancelling the consuming task cancels `complete` and surfaces
/// `CancellationError`, matching the behavior of awaiting `complete` directly.
enum ProviderPendingCompletionStream {
    typealias Sleep = @Sendable (_ seconds: TimeInterval) async throws -> Void

    static func make(
        heartbeatInterval: TimeInterval = ProviderTransportActivity.pendingCompletionHeartbeatInterval,
        sleep: @escaping Sleep = { seconds in try await Task.sleep(for: .seconds(seconds)) },
        complete: @escaping @Sendable () async throws -> AICompletionResult
    ) -> AsyncThrowingStream<AIStreamResult, Error> {
        let (events, continuation) = AsyncThrowingStream<AIStreamResult, Error>.makeStream()
        let heartbeat = Task {
            while !Task.isCancelled {
                do {
                    try await sleep(heartbeatInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                if case .terminated = continuation.yield(ProviderTransportActivity.result()) {
                    return
                }
            }
        }
        let request = Task {
            do {
                let completion = try await complete()
                // No liveness may be reported once the request has settled.
                heartbeat.cancel()
                await heartbeat.value
                continuation.yield(AIStreamResult(type: "content", text: completion.text))
                continuation.yield(
                    AIStreamResult(
                        type: "message_stop",
                        text: nil,
                        reasoning: nil,
                        promptTokens: completion.promptTokens,
                        completionTokens: completion.completionTokens,
                        cost: completion.cost
                    )
                )
                continuation.finish()
            } catch {
                heartbeat.cancel()
                await heartbeat.value
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            heartbeat.cancel()
            request.cancel()
        }

        // Pull through the consumer's task so its cancellation reaches `events`
        // (terminating it and cancelling `request`) and is rethrown rather than
        // ending the stream as if it had completed normally.
        let iterator = PendingCompletionIterator(events.makeAsyncIterator())
        return AsyncThrowingStream<AIStreamResult, Error>(unfolding: {
            if let next = try await iterator.next() {
                return next
            }
            try Task.checkCancellation()
            return nil
        })
    }
}

/// Serially consumed by the single pulling task of the outer unfolding stream.
private final class PendingCompletionIterator: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<AIStreamResult, Error>.Iterator

    init(_ iterator: AsyncThrowingStream<AIStreamResult, Error>.Iterator) {
        self.iterator = iterator
    }

    func next() async throws -> AIStreamResult? {
        try await iterator.next()
    }
}
