import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
@testable import RepoPromptHTTPProviders
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
}

final class OpenAITransportChunkTests: XCTestCase {
    func testOpenAIDecodedChunkAdapterPreservesChoiceAndDeltaSemantics() throws {
        func chunk(_ object: [String: Any]) throws -> ChatCompletionChunkObject {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try JSONDecoder().decode(ChatCompletionChunkObject.self, from: data)
        }

        let heartbeatChoice: [String: Any] = ["delta": [String: Any](), "index": 0]
        let semanticChoice: [String: Any] = ["delta": ["content": "content"], "index": 1]

        XCTAssertTrue(try OpenAIProvider.isTransportActivityChunk(chunk(["choices": [heartbeatChoice]])))
        XCTAssertTrue(try OpenAIProvider.isTransportActivityChunk(chunk([
            "choices": [heartbeatChoice, semanticChoice]
        ])))
        XCTAssertFalse(try OpenAIProvider.isTransportActivityChunk(chunk(["choices": []])))
        XCTAssertFalse(try OpenAIProvider.isTransportActivityChunk(chunk([
            "choices": [["index": 0]]
        ])))

        let semanticDeltas: [[String: Any]] = [
            ["content": "content"],
            ["reasoning_content": "reasoning"],
            ["role": "assistant"],
            ["tool_calls": [[
                "index": 0,
                "id": "call-1",
                "type": "function",
                "function": ["arguments": "{}", "name": "tool"]
            ]]],
            ["function_call": ["arguments": "{}", "name": "tool"]],
            ["refusal": "refusal"]
        ]
        for delta in semanticDeltas {
            XCTAssertFalse(try OpenAIProvider.isTransportActivityChunk(chunk([
                "choices": [["delta": delta, "index": 0]]
            ])))
        }

        XCTAssertFalse(try OpenAIProvider.isTransportActivityChunk(chunk([
            "choices": [["delta": [String: Any](), "finish_reason": "stop", "index": 0]]
        ])))
        XCTAssertFalse(try OpenAIProvider.isTransportActivityChunk(chunk([
            "choices": [heartbeatChoice],
            "usage": ["prompt_tokens": 1, "completion_tokens": 2, "total_tokens": 3]
        ])))
    }

    func testOpenAITransportPredicateRejectsEachSemanticFact() {
        func classifies(
            hasChoice: Bool = true,
            hasDelta: Bool = true,
            content: String? = nil,
            reasoning: String? = nil,
            role: String? = nil,
            hasToolCalls: Bool = false,
            hasFunctionCall: Bool = false,
            refusal: String? = nil,
            hasFinishReason: Bool = false,
            hasUsage: Bool = false
        ) -> Bool {
            OpenAIProvider.isTransportActivityChunk(
                hasChoice: hasChoice,
                hasDelta: hasDelta,
                content: content,
                reasoning: reasoning,
                role: role,
                hasToolCalls: hasToolCalls,
                hasFunctionCall: hasFunctionCall,
                refusal: refusal,
                hasFinishReason: hasFinishReason,
                hasUsage: hasUsage
            )
        }

        XCTAssertTrue(classifies())
        XCTAssertFalse(classifies(hasChoice: false))
        XCTAssertFalse(classifies(hasDelta: false))
        XCTAssertFalse(classifies(content: "content"))
        XCTAssertFalse(classifies(reasoning: "reasoning"))
        XCTAssertFalse(classifies(role: "assistant"))
        XCTAssertFalse(classifies(hasToolCalls: true))
        XCTAssertFalse(classifies(hasFunctionCall: true))
        XCTAssertFalse(classifies(refusal: "refusal"))
        XCTAssertFalse(classifies(hasFinishReason: true))
        XCTAssertFalse(classifies(hasUsage: true))
    }
}

final class OpenAIMessageEncodingTests: XCTestCase {
    func testOpenAITextOnlyMessagesRemainScalar() throws {
        let message = AIMessage(systemPrompt: "system", userMessage: "plain")
        let chat = try XCTUnwrap(try jsonObject(
            message.openAIChatMessages(embedSystemPrompt: false)
        ) as? [[String: Any]])
        XCTAssertTrue(chat.allSatisfy { $0["content"] is String })

        let assistantOnly = AIMessage(
            systemPrompt: "",
            fileTree: "root",
            conversationMessages: [.init(role: .assistant, content: "answer")],
            temperature: nil,
            promptSectionsOrder: [.fileMap],
            disabledPromptSections: []
        )
        let responses = try XCTUnwrap(try jsonObject(
            assistantOnly.openAIResponsesInput()
        ) as? [[String: Any]])
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?["role"] as? String, "assistant")
    }

    func testOpenAIChatAttachesOnlyToFinalUserTurn() throws {
        let json = try jsonObject(makeMessage().openAIChatMessages(embedSystemPrompt: false))
        let text = try jsonText(json)
        let messages = try XCTUnwrap(json as? [[String: Any]])

        XCTAssertEqual(countObjects(type: "image_url", in: json), 1)
        XCTAssertTrue(
            text.contains("data:image/png;base64,AQID") ||
                text.contains("data:image\\/png;base64,AQID")
        )
        XCTAssertTrue(text.contains("Image title: Diagram"))
        XCTAssertFalse(try jsonText(messages[1]).contains("AQID"))
        XCTAssertTrue(try jsonText(XCTUnwrap(messages.last)).contains("AQID"))
    }

    func testOpenAIResponsesAttachesOnlyToFinalUserTurn() throws {
        let json = try jsonObject(makeMessage().openAIResponsesInput())
        let text = try jsonText(json)

        XCTAssertEqual(countObjects(type: "input_image", in: json), 1)
        XCTAssertTrue(
            text.contains("data:image/png;base64,AQID") ||
                text.contains("data:image\\/png;base64,AQID")
        )
        XCTAssertTrue(text.contains("Image title: Diagram"))
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

final class ZAIHTTPProviderEndpointTests: XCTestCase {
    func testDefaultProviderUsesGeneralZAIEndpoint() {
        let provider = ZAIProvider(host: HTTPTestHost(), apiKey: "test-key")

        XCTAssertEqual(provider.endpoint, .generalAPI)
        XCTAssertEqual(provider.endpoint.baseURL.absoluteString, "https://api.z.ai/api/paas")
    }

    func testCodingPlanProviderUsesDedicatedCodingEndpoint() {
        let provider = ZAIProvider(host: HTTPTestHost(), apiKey: "test-key", endpoint: .codingPlan)

        XCTAssertEqual(provider.endpoint, .codingPlan)
        XCTAssertEqual(provider.endpoint.baseURL.absoluteString, "https://api.z.ai/api/coding/paas")
    }
}

final class OpenAIHTTPExecutionTests: XCTestCase {
    func testResponseBuildersReadCurrentHostAtEachExistingPolicySite() throws {
        let host = HTTPTestHost()
        let provider = OpenAIProvider(host: host)
        XCTAssertTrue(host.calls.isEmpty, "Construction must not snapshot request-time policy")
        let message = AIMessage(systemPrompt: "system", userMessage: "question")
        host.baseOverride = .gpt41
        host.sdkModelName = "first-model"
        host.tier = "flex"
        let first = try json(provider.buildForegroundResponseParameters(message, model: .gpt41, maxTokens: 7, stream: false))
        host.sdkModelName = "second-model"
        host.tier = "priority"
        let second = try json(provider.buildForegroundResponseParameters(message, model: .gpt41, maxTokens: 9, stream: true))
        XCTAssertEqual(first["model"] as? String, "first-model")
        XCTAssertEqual(second["model"] as? String, "second-model")
        XCTAssertEqual(first["service_tier"] as? String, "flex")
        XCTAssertEqual(second["service_tier"] as? String, "priority")
        XCTAssertEqual(first["max_output_tokens"] as? Int, 7)
        XCTAssertEqual(second["max_output_tokens"] as? Int, 9)
        XCTAssertEqual(host.calls.count(where: { $0 == "serviceTierBase" }), 6)
        XCTAssertEqual(host.calls.count(where: { $0 == "providerModel" }), 2)
        XCTAssertEqual(host.calls.count(where: { $0 == "serviceTierOverride" }), 2)
        host.baseOverride = nil
        host.effort = "low"
        let low = try json(provider.buildForegroundResponseParameters(message, model: .gpt61Terra, maxTokens: nil, stream: false))
        host.effort = "high"
        let high = try json(provider.buildForegroundResponseParameters(message, model: .gpt61Terra, maxTokens: nil, stream: false))
        XCTAssertEqual((low["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertEqual((high["reasoning"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertEqual(host.calls.count(where: { $0 == "defaultReasoningEffort" }), 2)
    }

    func testBothCanStreamReadsAndCurrentTemperatureReachOnlyInjectedTransport() async throws {
        let fixture = HTTPFixture(mode: .completion)
        defer { fixture.dispose() }
        let host = HTTPTestHost()
        host.canStreamAnswers = [true, false]
        host.temperature = 0.7
        let provider = FixtureOpenAIProvider(host: host, fixture: fixture)
        let message = AIMessage(systemPrompt: "system", userMessage: "question")
        var events: [AIStreamResult] = []
        for try await event in try await provider.streamMessage(message, model: .gpt41, maxTokens: nil) {
            events.append(event)
        }
        XCTAssertEqual(events.map(\.type), ["content", "message_stop"])
        XCTAssertEqual(events.first?.text, "answer")
        XCTAssertEqual(events.last?.promptTokens, 3)
        XCTAssertEqual(events.last?.completionTokens, 2)
        XCTAssertEqual(host.calls.count(where: { $0 == "canStream" }), 2, "Keep both independent reads; the second can change routing")
        XCTAssertEqual(fixture.requests.count, 1)
        let first = try requestJSON(XCTUnwrap(fixture.requests.first))
        XCTAssertEqual(first["model"] as? String, "fixture-model")
        XCTAssertEqual(first["temperature"] as? Double, 0.7)
        host.sdkModelName = "changed-model"
        host.temperature = 0.2
        let completed = try await provider.completeMessage(message, model: .gpt41, maxTokens: 17)
        XCTAssertEqual(completed.text, "answer")
        XCTAssertEqual(fixture.requests.count, 2)
        let second = try requestJSON(XCTUnwrap(fixture.requests.last))
        XCTAssertEqual(second["model"] as? String, "changed-model")
        XCTAssertEqual(second["temperature"] as? Double, 0.2)
        XCTAssertEqual(second["max_tokens"] as? Int, 17)
        XCTAssertEqual(host.calls.count(where: { $0 == "effectiveTemperature" }), 2)
    }

    func testInjectedSDKStreamKeepsTransportActivityBeforeAnswerAndTerminalUsage() async throws {
        let fixture = HTTPFixture(mode: .stream)
        defer { fixture.dispose() }
        let provider = FixtureOpenAIProvider(host: HTTPTestHost(), fixture: fixture)
        var events: [AIStreamResult] = []
        for try await event in try await provider.streamMessage(.init(systemPrompt: "", userMessage: "question"), model: .gpt41, maxTokens: nil) {
            events.append(event)
        }
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(events.first?.type, AIStreamResult.transportActivityType)
        let semantic = events.filter { $0.type != AIStreamResult.transportActivityType }
        XCTAssertEqual(semantic.map(\.type), ["content", "message_stop"])
        XCTAssertEqual(semantic.first?.text, "answer")
        XCTAssertEqual(semantic.last?.promptTokens, 3)
        XCTAssertEqual(semantic.last?.completionTokens, 2)
    }

    func testConsumerCancellationStopsTheExistingSDKRequest() async {
        let fixture = HTTPFixture(mode: .parkedStream)
        defer { fixture.dispose() }
        let provider = FixtureOpenAIProvider(host: HTTPTestHost(), fixture: fixture)
        let worker = Task {
            var types: [String] = []
            for try await event in try await provider.streamMessage(.init(systemPrompt: "", userMessage: "question"), model: .gpt41, maxTokens: nil) {
                types.append(event.type)
            }
            return types
        }
        await fulfillment(of: [fixture.started], timeout: 3)
        XCTAssertFalse(fixture.didStop, "The intercepted request must still be pending at the cancellation boundary")
        worker.cancel()
        await fulfillment(of: [fixture.stopped], timeout: 3)
        let outcome = await worker.result
        XCTAssertTrue(worker.isCancelled)
        if case let .success(types) = outcome {
            XCTAssertFalse(types.contains("message_stop"), "Cancellation must not deliver a successful terminal event")
        }
        // The existing API may surface SDK cancellation or end iteration; transport cancellation
        // is the observable contract here, not a new forced caller-error policy.
        XCTAssertTrue(fixture.didStop)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testEndpointConsentPortRunsBeforeServiceConstructionAndIsNotCached() throws {
        let host = HTTPTestHost()
        host.endpointDenied = true
        let provider = try OpenAIProvider(host: host, apiKey: "fixture-key", baseURL: XCTUnwrap(URL(string: "http://fixture.invalid")))
        XCTAssertTrue(host.calls.isEmpty)
        XCTAssertThrowsError(try provider.getService()) { error in
            XCTAssertEqual(error as? HTTPFixtureError, .endpointDenied)
        }
        host.endpointDenied = false
        XCTAssertNoThrow(try provider.getService()) // Constructs a service, never performs a request.
        XCTAssertEqual(host.calls, ["validateEndpoint", "validateEndpoint"])
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private func requestJSON(_ request: HTTPFixture.CapturedRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }
}

private enum HTTPFixtureError: Error, Equatable { case endpointDenied, missingFixture, unreadableBody }

/// Test-only mutable policy. It stores fixture answers, never production policy switches.
private final class HTTPTestHost: OpenAIProviderHost {
    var calls: [String] = []
    var baseOverride: AIModel?
    var tier: String?
    var sdkModelName = "fixture-model"
    var effort: String?
    var temperature: Double?
    var canStreamAnswers: [Bool] = []
    var endpointDenied = false

    func validateEndpoint(_: URL, apiKey _: String, consentEndpoint _: String?) throws {
        calls.append("validateEndpoint")
        if endpointDenied { throw HTTPFixtureError.endpointDenied }
    }

    func serviceTierBase(for model: AIModel) -> AIModel {
        calls.append("serviceTierBase")
        return baseOverride ?? model
    }

    func serviceTierOverride(for _: AIModel) -> String? {
        calls.append("serviceTierOverride")
        return tier
    }

    func usesResponsesAPI(for _: AIModel) -> Bool {
        calls.append("usesResponsesAPI")
        return false
    }

    func canStream(for _: AIModel) -> Bool {
        calls.append("canStream")
        return canStreamAnswers.isEmpty ? true : canStreamAnswers.removeFirst()
    }

    func providerModel(for _: AIModel) -> SwiftOpenAI.Model {
        calls.append("providerModel")
        return .custom(sdkModelName)
    }

    func defaultReasoningEffort(for _: AIModel) -> String? {
        calls.append("defaultReasoningEffort")
        return effort
    }

    func effectiveTemperature(for _: RepoPromptDomainRuntime.AIMessage, model _: AIModel) -> Double? {
        calls.append("effectiveTemperature")
        return temperature
    }

    func displayName(for _: AIModel) -> String {
        "fixture"
    }

    func maxTokens(for _: AIModel) -> Int? {
        nil
    }

    func friendlyErrorDescription(_: any Error) -> String {
        "fixture-error"
    }
}

private final class FixtureOpenAIProvider: OpenAIProvider {
    private let fixture: HTTPFixture

    init(host: HTTPTestHost, fixture: HTTPFixture) {
        self.fixture = fixture
        super.init(host: host, apiKey: "fixture-key", baseURL: fixture.baseURL)
    }

    override func getService() throws -> OpenAIService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPFixtureURLProtocol.self]
        return OpenAIServiceFactory.service(apiKey: "fixture-key", overrideBaseURL: fixture.baseURL.absoluteString, configuration: configuration)
    }
}

private final class HTTPFixture {
    enum Mode: Equatable { case completion, stream, parkedStream }
    struct CapturedRequest { let body: Data }
    let mode: Mode
    let baseURL: URL
    let started = XCTestExpectation(description: "intercepted SDK request started")
    let stopped = XCTestExpectation(description: "intercepted SDK request cancelled")
    private let lock = NSLock()
    private var recorded: [CapturedRequest] = []
    private var hasStarted = false
    private var hasStopped = false

    init(mode: Mode) {
        self.mode = mode
        baseURL = URL(string: "https://fixture-\(UUID().uuidString.lowercased()).invalid")!
        HTTPFixtureURLProtocol.register(self)
    }

    var requests: [CapturedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var didStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasStopped
    }

    func dispose() {
        HTTPFixtureURLProtocol.unregister(self)
    }

    func record(_ request: URLRequest) throws {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw HTTPFixtureError.unreadableBody }
                if count == 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        lock.lock()
        recorded.append(.init(body: body))
        lock.unlock()
    }

    func noteStarted() {
        lock.lock()
        let first = !hasStarted
        hasStarted = true
        lock.unlock()
        if first { started.fulfill() }
    }

    func noteStopped() {
        lock.lock()
        let first = !hasStopped
        hasStopped = true
        lock.unlock()
        if first { stopped.fulfill() }
    }
}

/// All URLSession requests are intercepted, including unexpected URLs (which fail locally).
private final class HTTPFixtureURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var fixtures: [String: HTTPFixture] = [:]
    private var fixture: HTTPFixture?

    static func register(_ fixture: HTTPFixture) {
        lock.lock()
        fixtures[fixture.baseURL.host!] = fixture
        lock.unlock()
    }

    static func unregister(_ fixture: HTTPFixture) {
        lock.lock()
        fixtures.removeValue(forKey: fixture.baseURL.host!)
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
        let selected = Self.fixtures[request.url?.host ?? ""]
        Self.lock.unlock()
        guard let selected else { client?.urlProtocol(self, didFailWithError: HTTPFixtureError.missingFixture)
            return
        }
        fixture = selected
        do { try selected.record(request) } catch { client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let isStream = selected.mode != .completion
        let headers = ["Content-Type": isStream ? "text/event-stream" : "application/json"]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if selected.mode == .completion {
            let body = #"{"id":"chatcmpl-fixture","object":"chat.completion","created":0,"model":"fixture-model","choices":[{"index":0,"message":{"role":"assistant","content":"answer"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}"#
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } else if selected.mode == .stream {
            let rows = [
                #"{"id":"chatcmpl-fixture","object":"chat.completion.chunk","created":0,"model":"fixture-model","choices":[{"index":0,"delta":{}}]}"#,
                #"{"id":"chatcmpl-fixture","object":"chat.completion.chunk","created":0,"model":"fixture-model","choices":[{"index":0,"delta":{"content":"answer"}}]}"#,
                #"{"id":"chatcmpl-fixture","object":"chat.completion.chunk","created":0,"model":"fixture-model","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}"#
            ]
            let body = rows.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        selected.noteStarted()
    }

    override func stopLoading() {
        fixture?.noteStopped()
    }
}
