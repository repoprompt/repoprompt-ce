import Foundation

/// Transport-liveness signalling for Oracle provider streams.
///
/// Context Builder follow-ups renew their inactivity budget only from stream
/// activity. Long-reasoning models can stay semantically silent for longer than
/// that budget while the transport is demonstrably alive, so providers report
/// liveness with the existing `transport_activity` result instead of content.
/// Liveness must come from a live transport (bytes received, or a child process
/// still running); a dead process or socket stops producing it, so a real hang
/// still exhausts the budget.
package enum ProviderTransportActivity {
    /// Interval between liveness results while a buffered child-process request is in flight.
    package static let pendingCompletionHeartbeatInterval: TimeInterval = 30
    /// Minimum spacing between liveness results derived from received transport bytes.
    package static let receivedBytesMinimumInterval: Duration = .seconds(5)

    package static func result() -> RepoPromptDomainRuntime.AIStreamResult {
        RepoPromptDomainRuntime.AIStreamResult(type: RepoPromptDomainRuntime.AIStreamResult.transportActivityType, text: nil)
    }
}

/// Rate-limits liveness results derived from received transport bytes.
package struct ProviderTransportActivityThrottle {
    let minimumInterval: Duration
    private var lastEmission: ContinuousClock.Instant?

    package init(minimumInterval: Duration = ProviderTransportActivity.receivedBytesMinimumInterval) {
        self.minimumInterval = minimumInterval
    }

    package mutating func shouldEmit(at now: ContinuousClock.Instant) -> Bool {
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
package enum ProviderPendingCompletionStream {
    package typealias Sleep = @Sendable (_ seconds: TimeInterval) async throws -> Void

    package static func make(
        heartbeatInterval: TimeInterval = ProviderTransportActivity.pendingCompletionHeartbeatInterval,
        sleep: @escaping Sleep = { seconds in try await Task.sleep(for: .seconds(seconds)) },
        complete: @escaping @Sendable () async throws -> RepoPromptDomainRuntime.AICompletionResult
    ) -> AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error> {
        // Start the request on the consumer's first pull, not here. `AsyncThrowingStream(unfolding:)`
        // never calls `produce` for a consumer that is already cancelled when it pulls; it ends that
        // iteration with `nil`. Starting eagerly therefore raced the consumer's first pull: a consumer
        // cancelled before pulling saw a normal end while a request it never observed was running.
        // Started lazily, that consumer starts no work, and a consumer cancelled while it waits
        // inside `produce` has the cancellation rethrown. Releasing the outer stream releases
        // `events`' iterator, which terminates it and cancels any request still in flight.
        let iterator = PendingCompletionIterator {
            ProviderPendingCompletionStream.startPendingCompletion(
                heartbeatInterval: heartbeatInterval,
                sleep: sleep,
                complete: complete
            )
        }
        return AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error>(unfolding: {
            if let next = try await iterator.next() {
                return next
            }
            try Task.checkCancellation()
            return nil
        })
    }

    private static func startPendingCompletion(
        heartbeatInterval: TimeInterval,
        sleep: @escaping Sleep,
        complete: @escaping @Sendable () async throws -> RepoPromptDomainRuntime.AICompletionResult
    ) -> AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error>.Iterator {
        let (events, continuation) = AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error>.makeStream()
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
                continuation.yield(RepoPromptDomainRuntime.AIStreamResult(type: "content", text: completion.text))
                continuation.yield(
                    RepoPromptDomainRuntime.AIStreamResult(
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

        // Pulled through the consumer's task so its cancellation reaches `events`
        // (terminating it and cancelling `request`) and is rethrown rather than
        // ending the stream as if it had completed normally.
        return events.makeAsyncIterator()
    }
}

/// Serially consumed by the single pulling task of the outer unfolding stream.
private final class PendingCompletionIterator: @unchecked Sendable {
    private let start: () -> AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error>.Iterator
    private var iterator: AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error>.Iterator?

    init(start: @escaping () -> AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error>.Iterator) {
        self.start = start
    }

    func next() async throws -> RepoPromptDomainRuntime.AIStreamResult? {
        var current = iterator ?? start()
        defer { iterator = current }
        return try await current.next()
    }
}
