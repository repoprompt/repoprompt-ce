import Foundation
@testable import RepoPromptApp
import SwiftOpenAI
import XCTest

final class ProviderStreamCompletionTests: XCTestCase {
    func testOpenAIStopReasonReportsSuccessfulCompletion() {
        XCTAssertEqual(openAIChatCompletionOutcome(.string("stop")), .completed)
        XCTAssertNil(openAIChatCompletionOutcome(nil))
    }

    func testOpenAIIncompleteStopReasonIsPreserved() {
        XCTAssertEqual(
            openAIChatCompletionOutcome(.string("length")),
            .incomplete(reason: "length")
        )
    }

    func testAnthropicSuccessfulCompletionReasonsAreExplicit() {
        XCTAssertTrue(AnthropicProvider.isSuccessfulCompletionStopReason("end_turn"))
        XCTAssertTrue(AnthropicProvider.isSuccessfulCompletionStopReason("stop_sequence"))
        XCTAssertFalse(AnthropicProvider.isSuccessfulCompletionStopReason("max_tokens"))
        XCTAssertFalse(AnthropicProvider.isSuccessfulCompletionStopReason("tool_use"))
    }

    func testAIQueriesNormalizesIncompleteTerminationWithoutMarkingSuccess() throws {
        let result = AIStreamResult(
            type: AIStreamResult.incompleteType,
            text: nil,
            stopReason: "max_tokens"
        )

        let outcome = try AIQueriesService.terminalOutcome(for: result)

        XCTAssertEqual(outcome, .incomplete(reason: "max_tokens"))
        XCTAssertNotEqual(outcome, .completed)
    }

    func testAIQueriesRejectsIncompleteTerminationWithoutReason() {
        let result = AIStreamResult(type: AIStreamResult.incompleteType, text: nil)

        XCTAssertThrowsError(try AIQueriesService.terminalOutcome(for: result)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The provider reported incomplete termination without a reason."
            )
        }
    }

    func testResponsesKeepaliveReportsActivityWithoutInventingContentOrCompletion() async throws {
        let provider = OpenAIProvider(apiKey: "test-key")
        let events = AsyncThrowingStream<ResponseStreamEvent, Error> { continuation in
            continuation.yield(.keepalive)
            continuation.finish()
        }
        var results: [AIStreamResult] = []
        for try await result in provider.bridgeResponseStream(events) {
            results.append(result)
        }
        XCTAssertEqual(results.map(\.type), [AIStreamResult.transportActivityType])
        XCTAssertNil(results.first?.text)
        XCTAssertNil(results.first?.reasoning)
    }
}

final class OpenAIBackgroundLivenessTests: XCTestCase {
    @MainActor
    func testProPollsInBackgroundAndReportsUnchangedStatusUntilDraftCompletes() async throws {
        OpenAIBackgroundURLProtocol.fixture.reset([
            .response("queued"), .response("in_progress"),
            .response("in_progress"), .response("completed", text: "draft")
        ])
        let provider = BackgroundTestOpenAIProvider()
        let stream = try await provider.streamMessage(
            AIMessage(systemPrompt: "Plan", userMessage: "Prepare a draft"),
            model: .gpt6AstraProHigh,
            maxTokens: nil
        )
        var results: [AIStreamResult] = []
        for try await result in stream {
            results.append(result)
        }

        let requests = OpenAIBackgroundURLProtocol.fixture.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET", "GET", "GET"])
        let body = try XCTUnwrap(requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-6-astra")
        XCTAssertEqual(json["background"] as? Bool, true)
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual((json["reasoning"] as? [String: Any])?["mode"] as? String, "pro")
        XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "high")

        let activities = results.filter { $0.type == AIStreamResult.transportActivityType }
        XCTAssertEqual(activities.count, 2, "Identical in-progress polls must both renew liveness")
        XCTAssertTrue(activities.allSatisfy { $0.text == nil && $0.reasoning == nil })
        XCTAssertEqual(results.compactMap(\.text).joined(), "draft")
        XCTAssertEqual(results.last?.type, "message_stop")

        // Model a reasoning interval exceeding the real ten-minute budget, then
        // verify that a truly silent transport still exhausts that same budget.
        let state = ContextBuilderFollowUpFinalizationState(startedAt: 0)
        for (index, activity) in activities.enumerated() {
            let output = try XCTUnwrap(AIQueriesService.transportActivityOutput(for: activity))
            let kind = try XCTUnwrap(OracleViewModel.lifecycleActivityKind(for: output))
            let now = Double(index + 1) * 590
            _ = await state.record(OracleMessageLifecycleActivityEvent(kind: kind), at: now)
            let timeout = await state.timeoutSnapshot(at: now, configuration: .production)
            XCTAssertNil(timeout)
        }
        let timeout = await state.timeoutSnapshot(at: 1780, configuration: .production)
        XCTAssertEqual(timeout?.kind, .inactivity)
    }

    func testFailedStatusPollPropagatesErrorWithoutCompletion() async throws {
        OpenAIBackgroundURLProtocol.fixture.reset([
            .response("queued"), .failure(URLError(.networkConnectionLost))
        ])
        let stream = try await BackgroundTestOpenAIProvider().streamResponse(id: "resp_test")
        var results: [AIStreamResult] = []
        do {
            for try await result in stream {
                results.append(result)
            }
            XCTFail("A failed poll must terminate with its error")
        } catch {
            XCTAssertEqual((error as NSError).code, NSURLErrorNetworkConnectionLost)
        }
        XCTAssertFalse(results.contains { $0.type == "message_stop" })
        XCTAssertEqual(results.count(where: { $0.type == AIStreamResult.transportActivityType }), 1)
    }

    func testCancellingPollingCancelsTheServerJob() async throws {
        OpenAIBackgroundURLProtocol.fixture.reset([
            .response("in_progress"), .response("cancelled")
        ])
        let stream = try await BackgroundTestOpenAIProvider().streamResponse(id: "resp_test")
        let receivedActivity = expectation(description: "Received status-poll activity")
        let cancelledJob = expectation(description: "Cancelled background response")
        OpenAIBackgroundURLProtocol.fixture.onCancel = { cancelledJob.fulfill() }
        let consumer = Task {
            for try await result in stream where result.type == AIStreamResult.transportActivityType {
                receivedActivity.fulfill()
            }
        }
        await fulfillment(of: [receivedActivity], timeout: 2)
        consumer.cancel()
        _ = await consumer.result
        await fulfillment(of: [cancelledJob], timeout: 2)
        XCTAssertEqual(OpenAIBackgroundURLProtocol.fixture.requests.last?.url?.lastPathComponent, "cancel")
    }
}

private final class BackgroundTestOpenAIProvider: OpenAIProvider {
    init() {
        super.init(apiKey: "test-key")
    }

    override func getService() throws -> OpenAIService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAIBackgroundURLProtocol.self]
        return OpenAIServiceFactory.service(apiKey: "test-key", configuration: configuration)
    }
}

private final class OpenAIBackgroundURLProtocol: URLProtocol {
    enum Reply {
        case response(String, text: String = "")
        case failure(URLError)
    }

    final class Fixture: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [Reply] = []
        private var recordedRequests: [URLRequest] = []
        private var cancellationHandler: (() -> Void)?

        var requests: [URLRequest] {
            lock.withLock { recordedRequests }
        }

        var onCancel: (() -> Void)? {
            get { lock.withLock { cancellationHandler } }
            set { lock.withLock { cancellationHandler = newValue } }
        }

        func reset(_ replies: [Reply]) {
            lock.withLock {
                self.replies = replies
                recordedRequests = []
                cancellationHandler = nil
            }
        }

        func next(for request: URLRequest) -> Reply {
            // URLSession exposes the POST body as a stream to URLProtocol on macOS.
            // Capture it here, before the request leaves this in-memory transport.
            var capturedRequest = request
            if capturedRequest.httpBody == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while true {
                    let count = stream.read(&buffer, maxLength: 1024)
                    guard count > 0 else { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
                capturedRequest.httpBody = body
            }
            return lock.withLock {
                recordedRequests.append(capturedRequest)
                return replies.isEmpty ? .failure(URLError(.badServerResponse)) : replies.removeFirst()
            }
        }
    }

    static let fixture = Fixture()

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        switch Self.fixture.next(for: request) {
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        case let .response(status, text):
            let output: [[String: Any]] = text.isEmpty ? [] : [[
                "type": "message", "id": "msg_test", "role": "assistant",
                "content": [["type": "output_text", "text": text, "annotations": []]]
            ]]
            let body: [String: Any] = [
                "id": "resp_test", "object": "response", "created_at": 0,
                "model": "gpt-6-astra", "metadata": [String: String](),
                "parallel_tool_calls": false, "status": status, "output": output
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: body)
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: XCTUnwrap(request.url), statusCode: 200,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
                ))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
                if request.url?.lastPathComponent == "cancel" { Self.fixture.onCancel?() }
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}
