import Foundation
@testable import RepoPromptApp
import RepoPromptSecureStorage
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

final class JevDecisionServiceTests: XCTestCase {
    func testGenericChoiceMapsToFixedRouteQuestionAndPinnedModel() async throws {
        let client = RecordingJevDecisionClient()
        let credentials = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()), client: client
        )
        guard case .saved = await credentials.validateAndSave("secret", operationID: UUID()) else {
            return XCTFail("Expected synthetic credential validation")
        }
        let request = makeRequest()
        let result = await JevDecisionService(credentialService: credentials).decide(request)
        guard case let .selected(key, evidence) = result else { return XCTFail("Expected selected outcome") }
        XCTAssertEqual(key, "opaque-b")
        XCTAssertEqual(evidence?.acceptancePolicyVersion, JevRouterCredentialService.routingPolicyVersion)
        XCTAssertEqual(evidence?.confidence, 0.8)
        XCTAssertEqual(evidence?.probabilitySemantics, .probability)
        XCTAssertEqual(evidence?.probabilities?.map(\.opaqueKey).sorted(), ["opaque-a", "opaque-b"])
        XCTAssertEqual(evidence?.usage, .init(inputTokens: 12, outputTokens: 4))
        let recordedWire = await client.lastRequest
        let wire = try XCTUnwrap(recordedWire)
        XCTAssertEqual(wire.model, JevRouterCredentialService.pinnedModel)
        XCTAssertEqual(wire.state, request.textContext)
        XCTAssertEqual(wire.questions.count, 1)
        XCTAssertEqual(wire.questions["route"]?.type, "choice")
        XCTAssertEqual(wire.questions["route"]?.criteria, ["opaque-a": "Provider A", "opaque-b": "Provider B"])
        XCTAssertEqual(wire.questions["route"]?.instructions, request.question.instructions)
    }

    func testInvalidDirectRequestCannotReachCredentialOrWire() async {
        let storage = TestSecureStorageBackend()
        let client = RecordingJevDecisionClient()
        let credentials = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: storage), client: client
        )
        let adapter = JevDecisionService(credentialService: credentials)
        let duplicate = makeRequest(choices: [.init(opaqueKey: "same", description: "A"), .init(opaqueKey: "same", description: "B")])
        let duplicateOutcome = await adapter.decide(duplicate)
        XCTAssertEqual(duplicateOutcome, .invalidRequest)
        let single = makeRequest(choices: [.init(opaqueKey: "missing", description: "A")])
        let singleOutcome = await adapter.decide(single)
        XCTAssertEqual(singleOutcome, .invalidRequest)
        XCTAssertTrue(storage.calls.isEmpty)
        let lastRequest = await client.lastRequest
        XCTAssertNil(lastRequest)
    }

    private func makeRequest(choices: [DecisionChoice]? = nil) -> FiniteChoiceDecisionRequest {
        .init(
            requestID: UUID(), consumerID: .modelRouter,
            contractVersion: FiniteChoiceDecisionRequest.currentContractVersion,
            policy: ModelRouterDecisionPolicy.identity,
            textContext: "TASK:\nInvestigate a regression",
            question: .init(
                name: "model_route", instructions: "Choose one opaque candidate.",
                choices: choices ?? [
                    .init(opaqueKey: "opaque-a", description: "Provider A"),
                    .init(opaqueKey: "opaque-b", description: "Provider B")
                ]
            )
        )
    }
}

private actor RecordingJevDecisionClient: JevRoutingClientProtocol {
    private(set) var lastRequest: JevRoutingWireRequest?

    func listModels(apiKey: String, timeout: Duration) -> JevModelList {
        .init(models: [.init(name: "jev-latest")])
    }

    func judge(request: JevRoutingWireRequest, apiKey: String, timeout: Duration) -> JevRoutingWireResponse {
        lastRequest = request
        return .init(
            model: JevRouterCredentialService.pinnedModel,
            answers: ["route": .init(
                type: "choice", choice: "opaque-b",
                probabilities: ["opaque-a": 0.2, "opaque-b": 0.8], confidence: 0.8
            )],
            usage: .init(inputTokens: 12, outputTokens: 4)
        )
    }
}

final class OpenAIDecisionsDecisionServiceTests: XCTestCase {
    func testGenericQuestionMapsToDocumentedWireWithoutLeakingInternalFields() async throws {
        let recorder = DecisionsTestRecorder()
        let (adapter, _) = await readyAdapter(recorder)
        for name in ["model_route", "effort_route"] {
            let request = request(name: name)
            let result = await adapter.decide(request)
            guard case let .selected(key, evidence) = result else { return XCTFail("Expected selection") }
            XCTAssertEqual(key, "opaque-a")
            XCTAssertEqual(evidence?.acceptancePolicyVersion, OpenAIDecisionsRouterCredentialService.routingPolicyVersion)
            XCTAssertEqual(evidence?.probabilitySemantics, .probability)
            XCTAssertEqual(evidence?.probabilities?.map(\.opaqueKey).sorted(), ["opaque-a", "opaque-b"])
            let recorded = await recorder.requests.last
            let wire = try XCTUnwrap(recorded)
            XCTAssertEqual(wire.model, OpenAIDecisionsRouterCredentialService.pinnedModel)
            XCTAssertEqual(wire.questions.count, 1)
            XCTAssertEqual(wire.questions[0].name, name)
            XCTAssertEqual(wire.questions[0].choices.map(\.value), ["opaque-a", "opaque-b"])
            XCTAssertEqual(wire.input, request.textContext)
            XCTAssertEqual(wire.questions[0].instructions, request.question.instructions)
            let encoded = try String(decoding: JSONEncoder().encode(wire), as: UTF8.self)
            XCTAssertFalse(encoded.contains(request.requestID.uuidString))
            XCTAssertFalse(encoded.contains("requestID"))
            XCTAssertFalse(encoded.contains("consumerID"))
            XCTAssertFalse(encoded.contains("policyVersion"))
        }
        let count = await recorder.requests.count
        XCTAssertEqual(count, 3, "One validation and one operation per stage")
    }

    func testAutoEffortPolicyUsesDecisionsWithNarrowWireContext() async throws {
        let recorder = DecisionsTestRecorder()
        let (adapter, _) = await readyAdapter(recorder)
        let masked = try XCTUnwrap(AutoEffortTaskSummary.make(from: "Review password=private123 /Users/alice/work"))
        let prepared = try AutoEffortDecisionPolicy().build(
            requestID: UUID(), maskedTaskExcerpt: masked, selectedModelID: "gpt-6-sol",
            builtInWorkflow: .review, efforts: ["low", "medium"], capabilities: adapter.capabilities
        )
        let outcome = await adapter.decide(prepared.request)
        XCTAssertEqual(prepared.effort(for: outcome), "low")
        let recorded = await recorder.requests.last
        let wire = try XCTUnwrap(recorded)
        XCTAssertEqual(wire.questions.map(\.name), ["effort"])
        XCTAssertEqual(wire.questions[0].choices.map(\.value), ["effort-0", "effort-1"])
        XCTAssertEqual(wire.input, prepared.request.textContext)
        XCTAssertTrue(wire.input.contains("BUILT_IN_WORKFLOW_CATEGORY:\nreview"))
        XCTAssertFalse(wire.input.contains("private123"))
        XCTAssertFalse(wire.input.contains("/Users/alice/work"))
        XCTAssertFalse(wire.input.contains("workflow template"))
    }

    func testInvalidDirectRequestsAreRejectedBeforeStorageOrNetwork() async {
        let recorder = DecisionsTestRecorder()
        let storage = TestSecureStorageBackend()
        let credentials = OpenAIDecisionsRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: storage),
            decide: { request, key in try await recorder.decide(request, key: key) }
        )
        let adapter = OpenAIDecisionsDecisionService(credentialService: credentials)
        let bad = [
            request(contract: "future"), request(choices: []), request(choices: [choice("a")]),
            request(choices: [choice("a"), choice("a")]), request(choices: [choice(" "), choice("b")]),
            request(choices: (0 ..< 13).map { choice("\($0)") }),
            request(context: String(repeating: "x", count: 25 * 1024)),
            request(instructions: String(repeating: "x", count: 17 * 1024))
        ]
        for request in bad {
            let outcome = await adapter.decide(request)
            XCTAssertEqual(outcome, .invalidRequest)
        }
        XCTAssertTrue(storage.calls.isEmpty)
        let count = await recorder.requests.count
        XCTAssertEqual(count, 0)
    }

    func testNormalizedFailuresAndReadinessRemainStable() async {
        let recorder = DecisionsTestRecorder()
        let (adapter, credentials) = await readyAdapter(recorder)
        let before = await credentials.readinessSnapshot()
        let cases: [(OpenAIDecisionsRoutingClientError, DecisionOutcome)] = [
            (.policyUnavailable, .unavailable), (.authentication, .unavailable),
            (.timeout, .failed(category: .timeout, retryable: false, evidence: nil)),
            (.transport, .failed(category: .transport, retryable: false, evidence: nil)),
            (.rateLimited, .failed(category: .rateLimited, retryable: true, evidence: nil)),
            (.overloaded, .failed(category: .overloaded, retryable: true, evidence: nil)),
            (.invalidRequest, .invalidRequest), (.responseTooLarge, .invalidResponse),
            (.invalidResponse, .invalidResponse), (.cancelled, .cancelled)
        ]
        for (error, expected) in cases {
            await recorder.setError(error)
            let outcome = await adapter.decide(request())
            XCTAssertEqual(outcome, expected)
        }
        let after = await credentials.readinessSnapshot()
        XCTAssertEqual(after, before)
        let count = await recorder.requests.count
        XCTAssertEqual(count, cases.count + 1)
    }

    func testRefusalAbstainsAndPinnedModelDriftFailsClosed() async {
        let credentials = OpenAIDecisionsRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()),
            decide: { request, _ in
                if request.questions[0].name == "credential_access" { return decisionsTestResponse(request) }
                return decisionsTestResponse(request, refusal: true)
            }
        )
        _ = await credentials.validateAndSave("synthetic", operationID: UUID())
        let refusal = await OpenAIDecisionsDecisionService(credentialService: credentials).decide(request())
        XCTAssertEqual(refusal, .abstained(reasonCode: "provider_refusal", evidence: nil))
        let drift = OpenAIDecisionsRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()),
            decide: { request, _ in
                let response = decisionsTestResponse(request)
                return .init(model: request.questions[0].name == "credential_access" ? response.model : "unexpected", answers: response.answers, usage: response.usage)
            }
        )
        _ = await drift.validateAndSave("synthetic", operationID: UUID())
        let driftOutcome = await OpenAIDecisionsDecisionService(credentialService: drift).decide(request())
        XCTAssertEqual(driftOutcome, .invalidResponse)
    }

    func testRegistrationOwnsRedactedDedicatedCredentialPresentation() async throws {
        let credentials = OpenAIDecisionsRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let adapter = OpenAIDecisionsDecisionService(credentialService: credentials)
        let configuration = OpenAIDecisionsDecisionService.settingsRegistration(controller: credentials)
        let registration = DecisionServiceRegistration(service: adapter, configuration: configuration)
        XCTAssertEqual(registration.id, .openAIDecisions)
        XCTAssertEqual(adapter.displayName, "Decisions by OpenAI")
        XCTAssertEqual(configuration.presentation.title, "Decisions by OpenAI")
        XCTAssertEqual(configuration.presentation.secretFieldLabel, "API key for Decisions by OpenAI")
        XCTAssertNil(configuration.presentation.productStatus)
        let text = (
            [configuration.presentation.title, configuration.presentation.summary]
                + configuration.presentation.notices.map(\.text)
                + configuration.presentation.disclosures.flatMap(\.paragraphs)
        ).joined(separator: " ")
        for phrase in ["small input-token charge", "at the time of validation", "not a hard budget boundary", "best effort", "supported decisions when selected"] {
            XCTAssertTrue(text.contains(phrase), phrase)
        }
        let registry = try DecisionServiceRegistry(registrations: [registration])
        let decisions = await registry.registration(for: .openAIDecisions)
        XCTAssertNotNil(decisions)
        let jev = await registry.registration(for: .jev)
        XCTAssertNil(jev)
    }

    private func readyAdapter(_ recorder: DecisionsTestRecorder) async -> (OpenAIDecisionsDecisionService, OpenAIDecisionsRouterCredentialService) {
        let credentials = OpenAIDecisionsRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()),
            decide: { request, key in try await recorder.decide(request, key: key) }
        )
        _ = await credentials.validateAndSave("synthetic", operationID: UUID())
        return (OpenAIDecisionsDecisionService(credentialService: credentials), credentials)
    }

    private func choice(_ key: String) -> DecisionChoice {
        .init(opaqueKey: key, description: "Capable candidate")
    }

    private func request(
        name: String = "model_route", context: String = "TASK:\nInvestigate a regression",
        instructions: String = "Choose one for delegated subagent session.",
        contract: String = FiniteChoiceDecisionRequest.currentContractVersion,
        choices: [DecisionChoice]? = nil
    ) -> FiniteChoiceDecisionRequest {
        .init(
            requestID: UUID(), consumerID: .modelRouter, contractVersion: contract,
            policy: ModelRouterDecisionPolicy.identity, textContext: context,
            question: .init(name: name, instructions: instructions, choices: choices ?? [choice("opaque-a"), choice("opaque-b")])
        )
    }
}

final class OpenAIDecisionsRoutingClientTests: XCTestCase {
    func testBuildsExactRequestAndDecodesValidResponseOnce() async throws {
        let transport = CapturingDecisionsTransport(status: 200, body: validResponse)
        let client = OpenAIDecisionsRoutingClient(transport: transport)
        let response = try await client.decide(wireRequest, apiKey: "synthetic-test-key")
        XCTAssertEqual(response.model, "gpt-6-luna")
        let request = await transport.capturedRequest
        XCTAssertEqual(request?.url?.absoluteString, "https://api.openai.com/v1/decisions")
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-test-key")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request?.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(object["input"] as? String, "synthetic task text")
        let questions = try XCTUnwrap(object["questions"] as? [[String: Any]])
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions[0]["type"] as? String, "choice")
        let choices = try XCTUnwrap(questions[0]["choices"] as? [[String: Any]])
        XCTAssertEqual(choices.compactMap { $0["value"] as? String }, ["opaque-a", "opaque-b"])
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testMapsDocumentedErrorCodesWithoutLeakingProviderText() async {
        await assertClientError(.policyUnavailable, status: 401, code: nil)
        await assertClientError(.policyUnavailable, status: 403, code: nil)
        await assertClientError(.rateLimited, status: 429, code: "slow_down", type: "rate_limit_error")
        await assertClientError(.transport, status: 429, code: "slow_down", type: "unknown_error")
        await assertClientError(.policyUnavailable, status: 429, code: "organization_usage_limit_exceeded")
        await assertClientError(.transport, status: 429, code: "unknown_code")
        await assertClientError(.overloaded, status: 503, code: "server_is_overloaded", type: "service_unavailable_error")
        await assertClientError(.transport, status: 503, code: "unknown_code")
    }

    func testUndecodableSuccessAndOversizedInjectedBodyFailClosed() async {
        let invalidJSON = CapturingDecisionsTransport(status: 200, body: Data("not json".utf8))
        do {
            _ = try await OpenAIDecisionsRoutingClient(transport: invalidJSON).decide(wireRequest, apiKey: "key")
            XCTFail("Expected invalid response")
        } catch { XCTAssertEqual(error as? OpenAIDecisionsRoutingClientError, .invalidResponse) }

        let oversized = CapturingDecisionsTransport(status: 200, body: Data(repeating: 0x20, count: 64 * 1024 + 1))
        do {
            _ = try await OpenAIDecisionsRoutingClient(transport: oversized).decide(wireRequest, apiKey: "key")
            XCTFail("Expected oversized response rejection")
        } catch { XCTAssertEqual(error as? OpenAIDecisionsRoutingClientError, .responseTooLarge) }
    }

    func testDeadlineWinsAndCancelsInjectedTransportWithoutRetry() async {
        let transport = NeverDecisionsTransport()
        let client = OpenAIDecisionsRoutingClient(transport: transport, sleep: { _ in
            throw OpenAIDecisionsRoutingClientError.timeout
        })
        do {
            _ = try await client.decide(wireRequest, apiKey: "key")
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? OpenAIDecisionsRoutingClientError, .timeout) }
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testURLSessionTransportBoundsChunkedBodyAndRejectsRedirects() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DecisionsStubURLProtocol.self]
        let transport = OpenAIDecisionsURLSessionTransport(configuration: configuration)
        var request = URLRequest(url: OpenAIDecisionsRoutingClient.endpoint)
        request.httpMethod = "POST"
        request.setValue("oversized", forHTTPHeaderField: "X-Test-Mode")
        do {
            _ = try await transport.send(request, maximumBodyBytes: 64 * 1024)
            XCTFail("Expected bounded reader to stop oversized response")
        } catch { XCTAssertEqual(error as? OpenAIDecisionsRoutingClientError, .responseTooLarge) }

        request.setValue("redirect", forHTTPHeaderField: "X-Test-Mode")
        do {
            _ = try await transport.send(request, maximumBodyBytes: 64 * 1024)
            XCTFail("Expected redirect rejection")
        } catch { XCTAssertEqual(error as? OpenAIDecisionsRoutingClientError, .invalidResponse) }

        request.setValue("chunked", forHTTPHeaderField: "X-Test-Mode")
        let (data, response) = try await transport.send(request, maximumBodyBytes: 64 * 1024)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, validResponse)
    }

    func testURLSessionTransportAlreadyCancelledCallerSettlesBeforeStartingRequest() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DecisionsStubURLProtocol.self]
        let transport = OpenAIDecisionsURLSessionTransport(configuration: configuration)
        let operation = Task {
            // Deterministically invoke the cancellation handler before continuation installation.
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await transport.send(URLRequest(url: OpenAIDecisionsRoutingClient.endpoint), maximumBodyBytes: 64 * 1024)
                return false
            } catch {
                return error is CancellationError
            }
        }
        let cancelled = await operation.value
        XCTAssertTrue(cancelled)
    }

    private var wireRequest: OpenAIDecisionsWireRequest {
        .init(model: "gpt-6-luna", input: "synthetic task text", questions: [
            .init(name: "model", instructions: "Choose exactly one candidate.", choices: [
                .init(value: "opaque-a", description: "First"),
                .init(value: "opaque-b", description: "Second")
            ])
        ])
    }

    private var validResponse: Data {
        Data(#"{"model":"gpt-6-luna","answers":[{"type":"choice","name":"model","choice":"opaque-a","probabilities":[{"value":"opaque-a","probability":0.7},{"value":"opaque-b","probability":0.3}],"confidence":0.8}],"usage":{"input_tokens":10,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":0,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":10}}"#.utf8)
    }

    private func assertClientError(
        _ expected: OpenAIDecisionsRoutingClientError,
        status: Int,
        code: String?,
        type: String? = nil
    ) async {
        var body = "{\"error\":{"
        if let code { body += "\"code\":\"\(code)\"," }
        if let type { body += "\"type\":\"\(type)\"," }
        if body.hasSuffix(",") { body.removeLast() }
        body += "}}"
        let transport = CapturingDecisionsTransport(status: status, body: Data(body.utf8))
        do {
            _ = try await OpenAIDecisionsRoutingClient(transport: transport).decide(wireRequest, apiKey: "key")
            XCTFail("Expected error \(expected)")
        } catch { XCTAssertEqual(error as? OpenAIDecisionsRoutingClientError, expected) }
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }
}

private final class DecisionsStubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let mode = request.value(forHTTPHeaderField: "X-Test-Mode")
        if mode == "redirect" {
            let redirect = URLRequest(url: URL(string: "https://example.org/elsewhere")!)
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://example.org/elsewhere"])!
            client?.urlProtocol(self, wasRedirectedTo: redirect, redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let payload = mode == "oversized" ? Data(repeating: 0x20, count: 64 * 1024 + 1) : Self.validResponse
        for start in stride(from: 0, to: payload.count, by: 13) {
            let end = min(start + 13, payload.count)
            client?.urlProtocol(self, didLoad: payload.subdata(in: start ..< end))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static let validResponse = Data(#"{"model":"gpt-6-luna","answers":[{"type":"choice","name":"model","choice":"opaque-a","probabilities":[{"value":"opaque-a","probability":0.7},{"value":"opaque-b","probability":0.3}],"confidence":0.8}],"usage":{"input_tokens":10,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":0,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":10}}"#.utf8)
}

private actor CapturingDecisionsTransport: OpenAIDecisionsHTTPTransport {
    private let status: Int
    private let body: Data
    private(set) var capturedRequest: URLRequest?
    private(set) var requestCount = 0

    init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    func send(_ request: URLRequest, maximumBodyBytes: Int) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        capturedRequest = request
        guard body.count <= maximumBodyBytes else { throw OpenAIDecisionsRoutingClientError.responseTooLarge }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (body, response)
    }
}

private actor NeverDecisionsTransport: OpenAIDecisionsHTTPTransport {
    private(set) var requestCount = 0

    func send(_ request: URLRequest, maximumBodyBytes: Int) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}
