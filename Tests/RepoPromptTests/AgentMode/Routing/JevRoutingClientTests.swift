import Foundation
@testable import RepoPromptApp
import XCTest

final class JevRoutingClientTests: XCTestCase {
    func testModelValidationUsesDocumentedEndpointAndBearerKey() async throws {
        let transport = RecordingJevTransport(status: 200, body: #"{"models":[{"name":"jev"}]}"#)
        let response = try await JevRoutingClient(transport: transport).listModels(apiKey: "secret", timeout: .seconds(5))
        XCTAssertEqual(response.models.map(\.name), ["jev"])
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.typesafe.ai/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.timeoutInterval, 5, accuracy: 0.001)
    }

    func testJudgeUsesSingleSystemOneChoiceRequestWithoutProviderIdentity() async throws {
        let body = #"{"model":"jev-1.13.0","answers":{"route":{"type":"choice","choice":"opaque-a","probabilities":{"opaque-a":0.6,"opaque-b":0.4},"confidence":0.8}},"usage":{"input_tokens":4,"output_tokens":1}}"#
        let transport = RecordingJevTransport(status: 200, body: body)
        let wire = JevRoutingWireRequest(
            model: JevRouterCredentialService.pinnedModel,
            state: "task",
            questions: ["route": .init(
                type: "choice",
                instructions: "Choose one supplied task-handling rubric.",
                criteria: ["opaque-a": "Explore", "opaque-b": "Engineer"]
            )]
        )
        _ = try await JevRoutingClient(transport: transport).judge(request: wire, apiKey: "secret", timeout: .seconds(5))
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(request.httpMethod, "POST")
        let encoded = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(encoded.contains("opaque-a"))
        XCTAssertFalse(encoded.contains("codex"))
        XCTAssertFalse(encoded.contains("provider"))
        XCTAssertTrue(encoded.contains(#""questions":{"route":{"#))
        XCTAssertTrue(encoded.contains(#""criteria":{"#))
    }

    func testJudgeRoundTripsAMultiQuestionBatchInOneRequest() async throws {
        let body = #"{"model":"jev-1.13.0","answers":{"model":{"type":"choice","choice":"m2","probabilities":{"m1":0.3,"m2":0.7},"confidence":0.8},"effort":{"type":"choice","choice":"e1","probabilities":{"e1":0.9,"e2":0.1},"confidence":0.6}},"usage":{"input_tokens":9,"output_tokens":2}}"#
        let transport = RecordingJevTransport(status: 200, body: body)
        let batch = try JevJudgmentBatch(questions: [
            .init(id: "model", instructions: "Choose the base model.", criteria: [
                .init(opaqueKey: "m1", description: "M1"),
                .init(opaqueKey: "m2", description: "M2")
            ]),
            .init(id: "effort", instructions: "Choose the effort.", criteria: [
                .init(opaqueKey: "e1", description: "E1"),
                .init(opaqueKey: "e2", description: "E2")
            ])
        ])
        let wire = JevRoutingWireRequest(
            model: JevRouterCredentialService.pinnedModel,
            state: "task",
            questions: batch.wireQuestions()
        )
        let response = try await JevRoutingClient(transport: transport)
            .judge(request: wire, apiKey: "secret", timeout: .seconds(5))

        let request = try XCTUnwrap(transport.lastRequest)
        let encoded = try XCTUnwrap(request.httpBody)
        let decoded = try JSONDecoder().decode(DecodedJevWireRequest.self, from: encoded)
        XCTAssertEqual(Set(decoded.questions.keys), ["model", "effort"])
        XCTAssertEqual(decoded.questions["effort"]?.criteria, ["e1": "E1", "e2": "E2"])
        XCTAssertEqual(decoded.questions["model"]?.type, "choice")

        XCTAssertEqual(Set(response.answers.keys), ["model", "effort"])
        let validated = try JevRoutingResponseInterpreter().validate(response, batch: batch)
        XCTAssertEqual(validated.answer(forQuestionID: "model")?.selectedOpaqueKey, "m2")
        XCTAssertEqual(validated.answer(forQuestionID: "effort")?.selectedOpaqueKey, "e1")
        XCTAssertEqual(validated.inputTokens, 9)
    }

    func testOuterDeadlineCancelsTheRequestWithoutRetry() async {
        let transport = CancellationIgnoringJevTransport()
        let deadline = ControlledJevDeadline()
        let client = JevRoutingClient(transport: transport, sleep: { _ in try await deadline.wait() })
        let request = Task { () -> JevRoutingClientError? in
            do {
                _ = try await client.listModels(apiKey: "secret", timeout: .seconds(5))
                return nil
            } catch {
                return error as? JevRoutingClientError
            }
        }
        await transport.waitUntilStarted()
        await deadline.waitUntilStarted()
        await deadline.fire()
        let requestError = await request.value
        XCTAssertEqual(requestError, .timeout)

        // The cancellation-ignoring loser may finish later, but cannot replace the deadline.
        await transport.complete()
    }

    func testDocumentedErrorsAreClassifiedWithoutRetry() async {
        for (status, expected) in [
            (401, JevRoutingClientError.authentication),
            (422, .invalidRequest),
            (429, .rateLimited),
            (529, .overloaded)
        ] {
            let transport = RecordingJevTransport(status: status, body: "{}")
            do {
                _ = try await JevRoutingClient(transport: transport).listModels(apiKey: "secret", timeout: .seconds(5))
                XCTFail("Expected status \(status) to fail")
            } catch {
                XCTAssertEqual(error as? JevRoutingClientError, expected)
                XCTAssertEqual(transport.requestCount, 1)
            }
        }
    }
}

/// Decodable mirror of the encode-only wire request, so the test can assert the transmitted batch
/// structure without depending on dictionary encoding order.
private struct DecodedJevWireRequest: Decodable {
    struct Question: Decodable {
        let type: String
        let instructions: String
        let criteria: [String: String]
    }

    let model: String
    let state: String
    let questions: [String: Question]
}

private final class RecordingJevTransport: JevHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let status: Int
    private let body: Data
    private var requests: [URLRequest] = []

    init(status: Int, body: String) {
        self.status = status
        self.body = Data(body.utf8)
    }

    var lastRequest: URLRequest? {
        lock.withLock { requests.last }
    }

    var requestCount: Int {
        lock.withLock { requests.count }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        return (body, response)
    }
}

private actor CancellationIgnoringJevTransport: JevHTTPTransport {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<(Data, HTTPURLResponse), Error>?

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return try await withCheckedThrowingContinuation { completion = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func complete() {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.typesafe.ai/v1/models")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        completion?.resume(returning: (Data(#"{"models":[{"name":"jev"}]}"#.utf8), response))
        completion = nil
    }
}

private actor ControlledJevDeadline {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Error>?

    func wait() async throws {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func fire() {
        continuation?.resume()
        continuation = nil
    }
}
