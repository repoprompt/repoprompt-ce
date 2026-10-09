import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptFoundation
import XCTest

/// #803: providers report transport liveness so silent-but-alive Oracle lanes renew
/// the Context Builder inactivity budget, and stop once the transport has settled.
@MainActor
final class ProviderTransportActivityTests: XCTestCase {
    func testPendingCompletionReportsLivenessUntilSettledThenDeliversAnswer() async throws {
        let ticker = LivenessTicker()
        let request = PendingCompletionRequest()
        let stream = ProviderPendingCompletionStream.make(
            heartbeatInterval: 30,
            sleep: { _ in try await ticker.sleep() },
            complete: { try await request.wait() }
        )
        var iterator = stream.makeAsyncIterator()

        for _ in 1 ... 3 {
            ticker.allowOneTick()
            let event = try await iterator.next()
            XCTAssertEqual(event?.type, AIStreamResult.transportActivityType)
            let output = try XCTUnwrap(event.flatMap { AIQueriesService.transportActivityOutput(for: $0) })
            XCTAssertEqual(OracleViewModel.lifecycleActivityKind(for: output), .streamActivity)
        }
        XCTAssertTrue(request.isStarted)
        XCTAssertFalse(request.wasCancelled)

        request.resolve(.success(AICompletionResult(text: "answer", promptTokens: 3, completionTokens: 5, cost: 0.01)))
        let content = try await iterator.next()
        XCTAssertEqual(content?.type, "content")
        XCTAssertEqual(content?.text, "answer")
        let stop = try await iterator.next()
        XCTAssertEqual(stop?.type, "message_stop")
        XCTAssertEqual(stop?.promptTokens, 3)
        XCTAssertEqual(stop?.completionTokens, 5)
        XCTAssertEqual(stop?.cost, 0.01)
        let end = try await iterator.next()
        XCTAssertNil(end)
        // The pending heartbeat was cancelled when the request settled, not left running.
        XCTAssertEqual(ticker.cancelledSleeps, 1)
    }

    func testFailedRequestStopsLivenessAndSurfacesItsError() async {
        let ticker = LivenessTicker()
        let request = PendingCompletionRequest()
        let stream = ProviderPendingCompletionStream.make(
            heartbeatInterval: 30,
            sleep: { _ in try await ticker.sleep() },
            complete: { try await request.wait() }
        )
        var iterator = stream.makeAsyncIterator()
        ticker.allowOneTick()
        let heartbeat = try? await iterator.next()
        XCTAssertEqual(heartbeat?.type, AIStreamResult.transportActivityType)

        request.resolve(.failure(AIProviderError.invalidResponse(detail: "child exited 1")))
        do {
            let next = try await iterator.next()
            XCTFail("Expected the request failure, got \(String(describing: next?.type))")
        } catch {
            XCTAssertTrue(String(describing: error).contains("child exited 1"), "\(error)")
        }
        XCTAssertEqual(ticker.cancelledSleeps, 1)
    }

    func testConsumerCancellationCancelsRequestAndSurfacesCancellation() async {
        let ticker = LivenessTicker()
        let request = PendingCompletionRequest()
        let stream = ProviderPendingCompletionStream.make(
            heartbeatInterval: 30,
            sleep: { _ in try await ticker.sleep() },
            complete: { try await request.wait() }
        )
        let consumer = Task { () -> Error? in
            do {
                for try await _ in stream {}
                return nil
            } catch {
                return error
            }
        }
        // The request starts only on the consumer's first pull, so once it has started the consumer
        // is inside the stream's producer and its cancellation must be rethrown, not race the pull.
        let started = await eventually { request.isStarted }
        XCTAssertTrue(started)

        consumer.cancel()
        let outcome = await consumer.value
        XCTAssertTrue(outcome is CancellationError, "Expected cancellation, got \(String(describing: outcome))")
        let cancelled = await eventually { request.wasCancelled }
        XCTAssertTrue(cancelled, "Consumer cancellation must cancel the in-flight request")
    }

    func testConsumerCancelledBeforeFirstPullStartsNoRequest() async {
        let ticker = LivenessTicker()
        let request = PendingCompletionRequest()
        let stream = ProviderPendingCompletionStream.make(
            heartbeatInterval: 30,
            sleep: { _ in try await ticker.sleep() },
            complete: { try await request.wait() }
        )
        let consumer = Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                for try await _ in stream {}
                return nil
            } catch {
                return error
            }
        }
        let outcome = await consumer.value
        // `AsyncThrowingStream(unfolding:)` ends an already-cancelled iteration without calling its
        // producer, so the outcome may be a normal end; it must never be a delivered answer or error.
        XCTAssertTrue(outcome == nil || outcome is CancellationError, "\(String(describing: outcome))")
        XCTAssertFalse(request.isStarted, "A consumer that never pulled must not start the request")
    }

    func testReceivedBytesThrottleSpacesLivenessResults() {
        var throttle = ProviderTransportActivityThrottle(minimumInterval: .seconds(5))
        let origin = ContinuousClock.now
        XCTAssertTrue(throttle.shouldEmit(at: origin))
        XCTAssertFalse(throttle.shouldEmit(at: origin.advanced(by: .seconds(4.9))))
        XCTAssertTrue(throttle.shouldEmit(at: origin.advanced(by: .seconds(5))))
        XCTAssertFalse(throttle.shouldEmit(at: origin.advanced(by: .seconds(9.9))))
        XCTAssertTrue(throttle.shouldEmit(at: origin.advanced(by: .seconds(10))))
    }

    /// The custom provider drops keepalive comments and content-less deltas; their
    /// arrival must still be reported as liveness ahead of the answer.
    func testCustomOpenAIReportsKeepaliveBytesAsTransportActivity() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KeepaliveSSEURLProtocol.self]
        let provider = CustomOpenAIProvider(
            baseURL: "https://liveness.invalid/v1",
            apiKey: "key",
            defaultModel: "reasoning-model",
            streamingHttpClient: DefaultHTTPClient(configuration: configuration)
        )
        let stream = try await provider.streamMessage(
            AIMessage(systemPrompt: "system", userMessage: "question"),
            model: .customProvider(name: "liveness", provider: "liveness", model: "reasoning-model"),
            maxTokens: nil
        )
        var events: [AIStreamResult] = []
        for try await event in stream {
            events.append(event)
        }

        XCTAssertEqual(events.first?.type, AIStreamResult.transportActivityType)
        let semantic = events.filter { $0.type != AIStreamResult.transportActivityType }
        XCTAssertEqual(semantic.map(\.type), ["content", "message_stop"])
        XCTAssertEqual(semantic.first?.text, "answer")
    }

    private func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

/// A heartbeat sleep that completes only for granted ticks and honors cancellation.
private final class LivenessTicker: @unchecked Sendable {
    private let lock = NSLock()
    private var credits = 0
    private var parked: CheckedContinuation<Void, Never>?
    private var cancelled = 0

    var cancelledSleeps: Int {
        lock.withLock { cancelled }
    }

    func allowOneTick() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard let parked else {
                credits += 1
                return nil
            }
            self.parked = nil
            return parked
        }
        continuation?.resume()
    }

    func sleep() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if credits > 0 {
                        credits -= 1
                        return true
                    }
                    if Task.isCancelled { return true }
                    parked = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { self.parked = nil }
                return self.parked
            }
            continuation?.resume()
        }
        if Task.isCancelled {
            lock.withLock { cancelled += 1 }
            throw CancellationError()
        }
    }
}

private final class PendingCompletionRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AICompletionResult, Error>?
    private var started = false
    private var cancelled = false

    var isStarted: Bool {
        lock.withLock { started }
    }

    var wasCancelled: Bool {
        lock.withLock { cancelled }
    }

    func wait() async throws -> AICompletionResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AICompletionResult, Error>) in
                let cancelNow = lock.withLock { () -> Bool in
                    started = true
                    if Task.isCancelled {
                        cancelled = true
                        return true
                    }
                    self.continuation = continuation
                    return false
                }
                if cancelNow { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = self.lock.withLock { () -> CheckedContinuation<AICompletionResult, Error>? in
                self.cancelled = true
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func resolve(_ result: Result<AICompletionResult, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<AICompletionResult, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

/// Serves a reasoning-model SSE response: a keepalive comment and a reasoning-only
/// delta (both dropped by the provider) before the answer.
private final class KeepaliveSSEURLProtocol: URLProtocol {
    private static let body = Data("""
    : keep-alive

    data: {"choices":[{"delta":{"reasoning_content":"thinking"},"index":0,"finish_reason":null}]}

    data: {"choices":[{"delta":{"content":"answer"},"index":0,"finish_reason":null}]}

    data: [DONE]

    """.utf8)

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/event-stream"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
