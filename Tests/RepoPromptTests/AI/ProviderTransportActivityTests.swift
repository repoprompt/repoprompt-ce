import Foundation
import RepoPromptAIContracts
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptFoundation
import XCTest

/// #803: providers report transport liveness so silent-but-alive Oracle lanes renew
/// the Context Builder inactivity budget, and stop once the transport has settled.
@MainActor
final class ProviderTransportActivityTests: XCTestCase {
    func testPendingCompletionHeartbeatFeedsExistingAppLifecycleMapping() throws {
        let event: AIStreamResult? = ProviderTransportActivity.result()
        let output = try XCTUnwrap(event.flatMap { AIQueriesService.transportActivityOutput(for: $0) })
        XCTAssertEqual(OracleViewModel.lifecycleActivityKind(for: output), .streamActivity)
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
