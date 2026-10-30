import Foundation
import RepoPromptAIContracts
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptFoundation
import SwiftAnthropic
import XCTest

final class RemainingHTTPEncodingTests: XCTestCase {
    func testAnthropicSuccessfulCompletionReasonsAreExplicit() {
        XCTAssertTrue(AnthropicProvider.isSuccessfulCompletionStopReason("end_turn"))
        XCTAssertTrue(AnthropicProvider.isSuccessfulCompletionStopReason("stop_sequence"))
        XCTAssertFalse(AnthropicProvider.isSuccessfulCompletionStopReason("max_tokens"))
        XCTAssertFalse(AnthropicProvider.isSuccessfulCompletionStopReason("tool_use"))
    }

    func testAnthropicAttachesOnlyToFinalUserTurn() throws {
        let json = try jsonObject(AnthropicProvider.makeMessages(for: makeMessage()))
        let text = try jsonText(json)

        XCTAssertEqual(countObjects(type: "image", in: json), 1)
        XCTAssertTrue(text.contains("Image title: Diagram"))
        XCTAssertTrue(text.contains("AQID"))
        XCTAssertFalse(text.contains("/Users/secret.png"))
        let messages = try XCTUnwrap(json as? [[String: Any]])
        XCTAssertFalse(try jsonText(messages[0]).contains("AQID"))
        XCTAssertTrue(try jsonText(XCTUnwrap(messages.last)).contains("AQID"))
    }

    func testAnthropicSynthesizesUserTurnWhenNoUserEntryExists() throws {
        let message = AIMessage(
            systemPrompt: "system",
            fileTree: "root",
            conversationMessages: [.init(role: .assistant, content: "answer")],
            attachments: [
                .init(payload: .image(.png, Data([1, 2, 3])), fileName: "image.png", title: "Diagram")
            ],
            temperature: nil,
            promptSectionsOrder: [.fileMap],
            disabledPromptSections: []
        )
        let json = try jsonObject(AnthropicProvider.makeMessages(for: message))
        let messages = try XCTUnwrap(json as? [[String: Any]])
        let synthesized = try XCTUnwrap(messages.last)

        XCTAssertEqual(synthesized["role"] as? String, "user")
        XCTAssertEqual(countObjects(type: "image", in: json), 1)
        XCTAssertTrue(try jsonText(synthesized).contains("AQID"))
    }

    func testAnthropicImageTurnOmitsEmptyTextAndNormalizesTitles() throws {
        let message = AIMessage(
            systemPrompt: "system",
            conversationMessages: [.init(role: .user, content: "")],
            attachments: [
                .init(payload: .image(.png, Data([1, 2, 3])), fileName: "image.png", title: "  Diagram  ")
            ],
            temperature: nil,
            promptSectionsOrder: [],
            disabledPromptSections: []
        )
        let json = try jsonObject(AnthropicProvider.makeMessages(for: message))
        let messages = try XCTUnwrap(json as? [[String: Any]])
        let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        let textBlocks = content.filter { $0["type"] as? String == "text" }

        // Anthropic rejects empty text blocks; only the normalized title line may appear.
        XCTAssertTrue(textBlocks.allSatisfy { (($0["text"] as? String) ?? "").isEmpty == false })
        XCTAssertTrue(try jsonText(content).contains("Image title: Diagram"))
        XCTAssertFalse(try jsonText(content).contains("  Diagram  "))
        XCTAssertEqual(countObjects(type: "image", in: json), 1)
    }

    func testCustomOpenAITextOnlyMessagesRemainScalar() throws {
        let message = AIMessage(systemPrompt: "system", userMessage: "plain")
        let provider = CustomOpenAIProvider(
            host: RemainingHTTPTestHost(), baseURL: "https://example.test/v1",
            apiKey: "key",
            defaultModel: "text-model"
        )
        let custom = try XCTUnwrap(try jsonObject(
            provider.serializedMessagesForTesting(message)
        ) as? [[String: Any]])
        XCTAssertTrue(custom.allSatisfy { $0["content"] is String })
    }

    func testCustomOpenAIEncodesFinalUserAsContentArray() throws {
        let provider = CustomOpenAIProvider(
            host: RemainingHTTPTestHost(), baseURL: "https://example.test/v1",
            apiKey: "key",
            defaultModel: "vision-model"
        )
        let json = try jsonObject(provider.serializedMessagesForTesting(makeMessage()))
        let messages = try XCTUnwrap(json as? [[String: Any]])
        let earlierContent = messages[1]["content"]
        let finalMessage = try XCTUnwrap(messages.last)
        let finalContent = try XCTUnwrap(finalMessage["content"] as? [[String: Any]])

        XCTAssertTrue(earlierContent is String)
        XCTAssertEqual(countObjects(type: "image_url", in: finalContent), 1)
        let finalText = try jsonText(finalContent)
        XCTAssertTrue(
            finalText.contains("data:image/png;base64,AQID") ||
                finalText.contains("data:image\\/png;base64,AQID")
        )
    }

    func testCustomOpenAISynthesizedImageTurnKeepsAdditionsBeforeImages() throws {
        let provider = CustomOpenAIProvider(
            host: RemainingHTTPTestHost(), baseURL: "https://example.test/v1",
            apiKey: "key",
            defaultModel: "vision-model"
        )
        let message = AIMessage(
            systemPrompt: "system",
            fileTree: "root",
            conversationMessages: [.init(role: .assistant, content: "answer")],
            attachments: [
                .init(payload: .image(.png, Data([1, 2, 3])), fileName: "image.png", title: "Diagram")
            ],
            temperature: nil,
            promptSectionsOrder: [.fileMap],
            disabledPromptSections: []
        )
        let json = try jsonObject(provider.serializedMessagesForTesting(message))
        let messages = try XCTUnwrap(json as? [[String: Any]])
        let synthesized = try XCTUnwrap(messages.last)
        let parts = try XCTUnwrap(synthesized["content"] as? [[String: Any]])

        XCTAssertEqual(synthesized["role"] as? String, "user")
        XCTAssertEqual(parts.first?["type"] as? String, "text")
        XCTAssertTrue((parts.first?["text"] as? String)?.contains("root") == true)
        XCTAssertEqual(parts.last?["type"] as? String, "image_url")
    }

    private func makeMessage() -> AIMessage {
        AIMessage(
            systemPrompt: "system",
            conversationMessages: [
                .init(role: .user, content: "first"),
                .init(role: .assistant, content: "answer"),
                .init(role: .user, content: "final")
            ],
            attachments: [
                .init(payload: .image(.png, Data([1, 2, 3])), fileName: "image.png", title: "Diagram")
            ],
            temperature: nil,
            promptSectionsOrder: [],
            disabledPromptSections: []
        )
    }

    private func jsonObject(_ value: some Encodable) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func jsonText(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func countObjects(type: String, in value: Any) -> Int {
        if let object = value as? [String: Any] {
            return (object["type"] as? String == type ? 1 : 0)
                + object.values.reduce(0) { $0 + countObjects(type: type, in: $1) }
        }
        if let array = value as? [Any] {
            return array.reduce(0) { $0 + countObjects(type: type, in: $1) }
        }
        return 0
    }
}

final class RemainingHTTPPDFEncodingTests: XCTestCase {
    func testAnthropicSendsPDFCSVAndPNGInOneRequest() throws {
        let json = try Self.json(AnthropicProvider.makeMessages(for: Self.message([
            Self.sample(.pdf), Self.sample(.text), Self.sample(.image)
        ])))
        let messages = try XCTUnwrap(json as? [[String: Any]])
        let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.compactMap { $0["type"] as? String }.sorted(), ["document", "image", "text"])
        let text = try XCTUnwrap(parts.first { $0["type"] as? String == "text" }?["text"] as? String)
        XCTAssertTrue(text.hasPrefix("Attached file: data.csv\n```\na,b\n1,2\n```"), text)
        XCTAssertTrue(text.hasSuffix("Question"), text)
        let document = try XCTUnwrap(parts.first { $0["type"] as? String == "document" })
        XCTAssertEqual((document["source"] as? [String: Any])?["media_type"] as? String, "application/pdf")
    }

    func testAnthropicRefusesBeforeTheSDKWhenEncodedPDFsExceedTheRequestCap() throws {
        let limit = try XCTUnwrap(AttachmentRouteCapability.capability(for: .anthropicMessages).maxEncodedRequestBytes)
        let size = limit / 4 * 3 / 2 + 1024
        let pdfs = ["first.pdf", "second.pdf"].map {
            OracleAttachment(payload: .pdf(Self.pdfBytes(extra: size)), fileName: $0, title: nil)
        }
        XCTAssertThrowsError(try AnthropicProvider.makeMessages(for: Self.message(pdfs))) { error in
            XCTAssertTrue(error is AttachmentAdmissionError, "\(error)")
        }
    }

    private static func sample(_ kind: AttachmentKind) -> OracleAttachment {
        switch kind {
        case .image:
            OracleAttachment(payload: .image(.png, Data([1, 2, 3])), fileName: "diagram.png", title: nil)
        case .pdf:
            OracleAttachment(payload: .pdf(pdfBytes()), fileName: "report.pdf", title: nil)
        case .text:
            OracleAttachment(payload: .text("a,b\n1,2\n", Data("a,b\n1,2\n".utf8)), fileName: "data.csv", title: nil)
        case .binary:
            OracleAttachment(payload: .binary(Data([0, 1, 2, 3])), fileName: "blob.bin", title: nil)
        }
    }

    private static func pdfBytes(extra: Int = 0) -> Data {
        var data = Data("%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n".utf8)
        if extra > 0 { data.append(Data(count: extra)) }
        return data
    }

    private static func message(_ attachments: [OracleAttachment]) -> AIMessage {
        AIMessage(
            systemPrompt: "",
            conversationMessages: [.init(role: .user, content: "Question")],
            attachments: attachments,
            temperature: nil,
            promptSectionsOrder: [],
            disabledPromptSections: []
        )
    }

    private static func json(_ value: some Encodable) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}

@MainActor
final class RemainingHTTPKeepaliveTests: XCTestCase {
    func testCustomOpenAIReportsKeepaliveBytesAsTransportActivity() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KeepaliveSSEURLProtocol.self]
        let provider = CustomOpenAIProvider(
            host: RemainingHTTPTestHost(), baseURL: "https://liveness.invalid/v1",
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

final class RemainingHTTPExecutionTests: XCTestCase {
    func testAzureDiscoveryKeepsValidationVersionFallbackFilteringAndPerVersionMapping() async throws {
        let host = RemainingHTTPTestHost()
        let fixture = RemainingWireFixture { index, _ in
            switch index {
            case 0: (503, "unavailable")
            case 1: (200, #"{"data":[{"id":"discard","status":"failed"}]}"#)
            default: (200, #"{"data":[{"id":"beta","model":"base-b","status":"running"},{"id":"alpha","model":"base-a","status":"succeeded"}]}"#)
            }
        }
        defer { fixture.dispose() }
        let result = try await AzureOpenAIProvider.discoverDeployments(
            baseURL: fixture.url, apiKey: "fixture-key", apiVersions: [" a ", "a", "", "b", "c"],
            host: host, httpClient: DefaultHTTPClient(configuration: fixture.configuration())
        )
        XCTAssertEqual(result.map(\.id), ["alpha", "beta"])
        XCTAssertEqual(result.map(\.displayName), ["mapped-alpha", "mapped-beta"])
        XCTAssertEqual(fixture.requests.compactMap { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value }, ["a", "b", "c"])
        XCTAssertEqual(host.calls.filter { $0.hasPrefix("map:") }, ["map:beta", "map:alpha"])
        XCTAssertEqual(host.calls.first, "validate")
        XCTAssertEqual(host.calls.count(where: { $0 == "validate" }), 1)
    }

    func testAzureEmptyDiscoveryStillValidatesBeforeItsOriginalError() async throws {
        let host = RemainingHTTPTestHost()
        host.denies = true
        do {
            _ = try await AzureOpenAIProvider.discoverDeployments(baseURL: XCTUnwrap(URL(string: "https://empty.invalid")), apiKey: "fixture-key", apiVersions: [], host: host)
            XCTFail("must reject even without transport versions")
        } catch RemainingHTTPFailure.denied {} catch { XCTFail("unexpected \(error)") }
        XCTAssertEqual(host.calls, ["validate"])
        host.denies = false
        do {
            _ = try await AzureOpenAIProvider.discoverDeployments(baseURL: XCTUnwrap(URL(string: "https://empty.invalid")), apiKey: "fixture-key", apiVersions: [], host: host)
            XCTFail("original empty-version failure must remain")
        } catch {
            XCTAssertEqual((error as NSError).domain, "AzureDiscovery")
            XCTAssertEqual((error as NSError).code, -1)
            XCTAssertEqual(error.localizedDescription, "Unable to fetch Azure deployments.")
        }
        XCTAssertEqual(host.calls, ["validate", "validate"])
    }

    func testAzureValidatesEveryRequestBeforeItsOnceLazyServiceCreation() async throws {
        let host = RemainingHTTPTestHost()
        let fixture = RemainingWireFixture { _, _ in (200, Self.responseJSON(status: "completed")) }
        defer { fixture.dispose() }
        let provider = AzureOpenAIProvider(configuration: .init(baseURL: fixture.url, apiKey: "fixture-key", apiVersion: "fixture"), host: host, sessionConfigurationFactory: {
            host.record("session")
            return fixture.configuration()
        })
        XCTAssertTrue(host.calls.isEmpty)
        host.denies = true
        do { _ = try await provider.fetchResponse(id: "resp-fixture")
            XCTFail("must reject")
        } catch RemainingHTTPFailure.denied {} catch { XCTFail("unexpected \(error)") }
        XCTAssertEqual(host.calls, ["validate"])
        XCTAssertTrue(fixture.requests.isEmpty)
        host.denies = false
        let first = try await provider.fetchResponse(id: "resp-fixture")
        let second = try await provider.fetchResponse(id: "resp-fixture")
        XCTAssertEqual(first.status, .completed)
        XCTAssertEqual(second.status, .completed)
        XCTAssertEqual(host.calls.count(where: { $0 == "session" }), 1)
        XCTAssertEqual(host.calls.count(where: { $0 == "validate" }), 3)
        XCTAssertEqual(Array(host.calls.prefix(3)), ["validate", "validate", "session"])
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testAzurePollingCancellationKeepsTheExistingServerCancel() async throws {
        let cancelled = expectation(description: "intercepted server cancel")
        let fixture = RemainingWireFixture { _, request in
            if request.url.path.hasSuffix("/cancel") {
                cancelled.fulfill()
                return (200, Self.responseJSON(status: "cancelled"))
            }
            return (200, Self.responseJSON(status: "queued"))
        }
        defer { fixture.dispose() }
        let clock = RemainingPollClock()
        let provider = AzureOpenAIProvider(configuration: .init(baseURL: fixture.url, apiKey: "fixture-key", apiVersion: "fixture"), host: RemainingHTTPTestHost(), sessionConfigurationFactory: { fixture.configuration() }, pollSleep: { try await clock.sleep($0) })
        let stream = try await provider.streamResponse(id: "resp-fixture")
        let consumer = Task {
            var events: [AIStreamResult] = []
            for try await event in stream {
                events.append(event)
            }
            return events
        }
        await fulfillment(of: [clock.reached], timeout: 2)
        consumer.cancel()
        let events = try? await consumer.value
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertFalse(events?.contains { $0.type == "message_stop" } ?? false)
        let intervals = await clock.intervals
        XCTAssertEqual(intervals, [.seconds(3)])
        XCTAssertEqual(fixture.requests.count(where: { $0.url.path.hasSuffix("/cancel") }), 1)
    }

    func testAzureRawModelDiagnosticStaysInsideDisabledDebugAutoclosure() async throws {
        let host = RemainingHTTPTestHost()
        let fixture = RemainingWireFixture { _, _ in (200, Self.responseJSON(status: "queued")) }
        defer { fixture.dispose() }
        let old = AzureOpenAIProvider.enableDebugLogging
        defer { AzureOpenAIProvider.enableDebugLogging = old }
        let descriptor = AzureOpenAIConfiguration.ModelDescriptor(id: "deployment", endpoint: .responses, baseModelID: "base")
        let provider = AzureOpenAIProvider(configuration: .init(baseURL: fixture.url, apiKey: "fixture-key", apiVersion: "fixture", models: [descriptor]), host: host, sessionConfigurationFactory: { fixture.configuration() })
        AzureOpenAIProvider.enableDebugLogging = false
        _ = try await provider.createBackgroundResponse(AIMessage(systemPrompt: "system", userMessage: "question"), model: .azureCustom(name: "deployment"), maxTokens: 100)
        XCTAssertFalse(host.calls.contains("rawValue"))
        AzureOpenAIProvider.enableDebugLogging = true
        _ = try await provider.createBackgroundResponse(AIMessage(systemPrompt: "system", userMessage: "question"), model: .azureCustom(name: "deployment"), maxTokens: 100)
        XCTAssertEqual(host.calls.count(where: { $0 == "rawValue" }), 1)
    }

    func testOpenRouterReadsParameterAndHeaderConfigurationsIndependently() async throws {
        let host = RemainingHTTPTestHost()
        let fixture = RemainingWireFixture(aliasHost: "openrouter.ai") { _, _ in (200, Self.chatJSON) }
        defer { fixture.dispose() }
        let provider = OpenRouterProvider(apiKey: "fixture-key", host: host, sessionConfigurationFactory: { fixture.configuration() })
        XCTAssertTrue(host.calls.isEmpty)
        let result = try await provider.completeMessage(AIMessage(systemPrompt: "system", userMessage: "question"), model: .openrouterGpt5, maxTokens: nil)
        XCTAssertEqual(result.text, "answer")
        XCTAssertEqual(result.completionOutcome, .completed)
        XCTAssertEqual(host.calls.count(where: { $0 == "configuration" }), 2)
        let request = try XCTUnwrap(fixture.requests.first)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, 111)
        XCTAssertEqual(request.headers.first { $0.key.lowercased() == "x-fixture" }?.value, "2")
    }

    func testCustomRetryReadsCurrentPolicyInsideEachAttemptWithoutWallClockSleep() async throws {
        let host = RemainingHTTPTestHost()
        host.name = "before-retry"
        host.temperature = 0.1
        let fixture = RemainingWireFixture { index, _ in
            index == 0 ? (503, #"{"error":{"message":"retry"}}"#) : (200, Self.chatJSON)
        }
        defer { fixture.dispose() }
        let provider = CustomOpenAIProvider(host: host, retrySleep: { delay in
            XCTAssertEqual(delay, 1)
            host.name = "after-retry"
            host.temperature = 0.9
        }, baseURL: fixture.url.absoluteString, apiKey: "fixture-key", defaultModel: "fixture", httpClient: DefaultHTTPClient(configuration: fixture.configuration()))
        let result = try await provider.completeMessage(AIMessage(systemPrompt: "system", userMessage: "question"), model: .openrouterGpt5, maxTokens: nil)
        XCTAssertEqual(result.text, "answer")
        let bodies = try fixture.requests.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0.body) as? [String: Any]) }
        XCTAssertEqual(bodies.compactMap { $0["model"] as? String }, ["before-retry", "after-retry"])
        XCTAssertEqual(bodies.compactMap { $0["temperature"] as? Double }, [0.1, 0.9])
        XCTAssertEqual(host.calls.count(where: { $0 == "temperature" }), 2)
        XCTAssertEqual(host.calls.count(where: { $0 == "validate" }), 2)
    }

    func testAnthropicActualSDKKeepsNonstreamTemperatureAbsentAndStreamTerminalUsage() async throws {
        let host = RemainingHTTPTestHost()
        host.name = "claude-sonnet-4"
        let fixture = RemainingWireFixture(aliasHost: "api.anthropic.com") { index, _ in
            if index == 0 { return (200, #"{"id":"msg-fixture","type":"message","role":"assistant","model":"claude-sonnet-4","content":[{"type":"text","text":"answer"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":3,"output_tokens":2}}"#) }
            return (200, "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"answer\"}}\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"input_tokens\":3,\"output_tokens\":2}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
        }
        defer { fixture.dispose() }
        let adapter = SwiftAnthropic.URLSessionHTTPClientAdapter(urlSession: URLSession(configuration: fixture.configuration()))
        let provider = AnthropicProvider(apiKey: "fixture-key", host: host, httpClient: adapter)
        let message = AIMessage(systemPrompt: "system", userMessage: "question")
        let result = try await provider.completeMessage(message, model: .claude4Sonnet)
        XCTAssertEqual(result.text, "answer")
        XCTAssertEqual(result.completionOutcome, .completed)
        XCTAssertFalse(host.calls.contains("temperature"))
        var events: [AIStreamResult] = []
        for try await event in try await provider.streamMessage(message, model: .claude4Sonnet) {
            events.append(event)
        }
        XCTAssertEqual(events.compactMap(\.text).joined(), "answer")
        XCTAssertEqual(events.count(where: { $0.type == "message_stop" }), 1)
        XCTAssertEqual(events.last?.promptTokens, 3)
        XCTAssertEqual(events.last?.completionTokens, 2)
        XCTAssertEqual(host.calls.count(where: { $0 == "temperature" }), 1)
        let bodies = try fixture.requests.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0.body) as? [String: Any]) }
        XCTAssertNil(bodies.first?["temperature"])
        XCTAssertEqual(bodies.last?["temperature"] as? Double, 0.4)
    }

    func testCustomErrorBridgeKeepsExistingDomainAndCaseOrdinals() throws {
        let errors: [CustomOpenAIProviderError] = [
            .invalidToken(), .invalidModel(), .requestFailed(statusCode: 418, message: "fixture"),
            .invalidResponse(), .streamingNotSupported(), .rateLimitExceeded(),
            .serverError(), .serviceUnavailable(), .requestTooLarge(),
            .invalidToken(statusCode: 410, message: "fixture-0"),
            .invalidModel(statusCode: 411, message: "fixture-1"),
            .requestFailed(statusCode: 412, message: "fixture-2"),
            .invalidResponse(statusCode: 413, message: "fixture-3"),
            .streamingNotSupported(statusCode: 414, message: "fixture-4"),
            .rateLimitExceeded(statusCode: 415, message: "fixture-5"),
            .serverError(statusCode: 416, message: "fixture-6"),
            .serviceUnavailable(statusCode: 417, message: "fixture-7"),
            .requestTooLarge(statusCode: 418, message: "fixture-8")
        ]
        var measured: [[String: Any]] = []
        for (index, error) in errors.enumerated() {
            let code = index % 9
            let bridged = error as NSError
            XCTAssertEqual(bridged.domain, "RepoPromptApp.CustomOpenAIProviderError")
            XCTAssertEqual(bridged.code, code)
            XCTAssertEqual(bridged.localizedDescription, NSError(domain: "RepoPromptApp.CustomOpenAIProviderError", code: code).localizedDescription)
            XCTAssertTrue(bridged.userInfo.isEmpty)
            measured.append([
                "index": index, "domain": bridged.domain, "code": bridged.code,
                "userInfo": bridged.userInfo, "localizedDescription": bridged.localizedDescription,
                "statusCode": error.statusCode, "message": error.errorMessage,
                "friendly": error.friendlyErrorString, "reflectedType": String(reflecting: type(of: error))
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: measured, options: [.sortedKeys])
        print("M8_CUSTOM_ERROR_BRIDGE " + String(decoding: data, as: UTF8.self))
    }

    func testPortableConfigurationsKeepTheirExactLegacyWireEncoding() throws {
        let azure = try JSONDecoder().decode(AzureOpenAIConfiguration.self, from: Data(#"{"baseURL":"https://fixture.invalid","apiKey":"fixture-key","apiVersion":"version"}"#.utf8))
        XCTAssertEqual(azure.models, [])
        XCTAssertNil(azure.httpCredentialConsentEndpoint)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(azure)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["baseURL", "apiKey", "apiVersion", "models"])
        XCTAssertEqual(object["baseURL"] as? String, "https://fixture.invalid")
        let router = OpenRouterConfiguration(temperature: 0.7, maxTokens: 123, customHeaders: ["X-Test": "fixture"], useCustomSettings: false)
        let routerObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(router)) as? [String: Any])
        XCTAssertEqual(Set(routerObject.keys), ["baseConfig", "customHeaders", "useCustomSettings"])
        XCTAssertEqual((routerObject["baseConfig"] as? [String: Any])?["maxTokens"] as? Int, 123)
        XCTAssertEqual(routerObject["useCustomSettings"] as? Bool, false)
    }

    private static let chatJSON = #"{"id":"chat-fixture","object":"chat.completion","created":0,"model":"fixture","choices":[{"index":0,"message":{"role":"assistant","content":"answer"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}"#
    private static func responseJSON(status: String) -> String {
        "{\"created_at\":0,\"id\":\"resp-fixture\",\"metadata\":{},\"model\":\"fixture\",\"object\":\"response\",\"output\":[],\"parallel_tool_calls\":false,\"status\":\"\(status)\"}"
    }
}

private enum RemainingHTTPFailure: Error { case denied, unexpectedRequest }

private final class RemainingHTTPTestHost: AnthropicHTTPHost, OpenRouterHTTPHost, CustomOpenAIHTTPHost, AzureOpenAIHTTPHost {
    var name = "fixture-model"
    var temperature = 0.4
    var denies = false
    private let lock = NSLock()
    private var recorded: [String] = []
    private var configurationCount = 0
    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ value: String) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }

    func canStream(for _: AIModel) -> Bool {
        record("canStream")
        return true
    }

    func modelName(for _: AIModel) -> String {
        record("modelName")
        return name
    }

    func rawValue(for _: AIModel) -> String {
        record("rawValue")
        return name
    }

    func displayName(for _: AIModel) -> String {
        name
    }

    func modelFromName(_: String) -> AIModel? {
        .gpt41
    }

    func usesResponsesAPI(for _: AIModel) -> Bool {
        false
    }

    func defaultReasoningEffort(for _: AIModel) -> String? {
        nil
    }

    func effectiveTemperature(for _: AIMessage, model _: AIModel) -> Double? {
        record("temperature")
        return temperature
    }

    func defaultDescriptor(for _: String) -> AzureOpenAIConfiguration.ModelDescriptor? {
        nil
    }

    func discoveryDescriptor(id: String, baseModelID: String?) -> AzureOpenAIConfiguration.ModelDescriptor {
        record("map:" + id)
        return .init(id: id, displayName: "mapped-" + id, baseModelID: baseModelID)
    }

    func configuration() -> OpenRouterConfiguration {
        lock.lock()
        configurationCount += 1
        let count = configurationCount
        recorded.append("configuration")
        lock.unlock()
        return .init(maxTokens: count == 1 ? 111 : 222, customHeaders: ["X-Fixture": String(count)])
    }

    func validateEndpoint(_: URL, apiKey _: String, customHeaders _: [String: String], consentEndpoint _: String?) throws {
        record("validate")
        if denies { throw RemainingHTTPFailure.denied }
    }

    func validateEndpoint(_: String, apiKey _: String, customHeaders _: [String: String], consentEndpoint _: String?) throws {
        record("validate")
        if denies { throw RemainingHTTPFailure.denied }
    }
}

private actor RemainingPollClock {
    nonisolated let reached = XCTestExpectation(description: "poll fake clock reached")
    private var waiter: CheckedContinuation<Void, Error>?
    private(set) var intervals: [Duration] = []
    func sleep(_ interval: Duration) async throws {
        intervals.append(interval)
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) } else { waiter = continuation
                    reached.fulfill()
                }
            }
        } onCancel: { Task { await self.cancel() } }
    }

    private func cancel() {
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}

private final class RemainingWireFixture {
    struct Request { let url: URL
        let headers: [String: String]
        let body: Data
    }

    let url = URL(string: "https://remaining-\(UUID().uuidString.lowercased()).invalid")!
    private let lock = NSLock()
    private var captured: [Request] = []
    let reply: (Int, Request) -> (Int, String)
    init(aliasHost: String? = nil, reply: @escaping (Int, Request) -> (Int, String)) {
        self.reply = reply
        RemainingWireProtocol.register(self, alias: aliasHost)
    }

    func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [RemainingWireProtocol.self]
        return c
    }

    func dispose() {
        RemainingWireProtocol.unregister(self)
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func receive(_ request: URLRequest) throws -> (Int, String) {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n < 0 { throw RemainingHTTPFailure.unexpectedRequest }
                if n == 0 { break }
                body.append(contentsOf: buffer.prefix(n))
            }
        }
        let value = Request(url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: body)
        lock.lock()
        let index = captured.count
        captured.append(value)
        lock.unlock()
        return reply(index, value)
    }
}

/// Every request in each injected session is intercepted; unknown hosts fail locally.
private final class RemainingWireProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var fixtures: [String: RemainingWireFixture] = [:]
    static func register(_ fixture: RemainingWireFixture, alias: String?) {
        lock.lock()
        fixtures[fixture.url.host!] = fixture
        if let alias { fixtures[alias] = fixture }
        lock.unlock()
    }

    static func unregister(_ fixture: RemainingWireFixture) {
        lock.lock()
        fixtures = fixtures.filter { $0.value !== fixture }
        lock.unlock()
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let fixture = Self.fixtures[request.url?.host ?? ""]
        Self.lock.unlock()
        guard let fixture else { client?.urlProtocol(self, didFailWithError: RemainingHTTPFailure.unexpectedRequest)
            return
        }
        do {
            let (status, body) = try fixture.receive(request)
            let headers = ["Content-Type": body.hasPrefix("event:") ? "text/event-stream" : "application/json"]
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() {}
}
