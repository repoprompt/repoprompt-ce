import Foundation
@testable import RepoPromptApp
import RepoPromptSecureStorage
import XCTest

final class JevRouterCredentialServiceTests: XCTestCase {
    func testLateValidationCannotOverwriteNewerCandidate() async {
        let storage = TestSecureStorageBackend()
        let client = ControlledJevClient()
        let service = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: storage),
            client: client
        )
        let firstID = UUID()
        let secondID = UUID()
        let first = Task { await service.validateAndSave("candidate-a", operationID: firstID) }
        await client.waitUntilStarted("candidate-a")
        let second = Task { await service.validateAndSave("candidate-b", operationID: secondID) }
        await client.waitUntilStarted("candidate-b")

        await client.complete("candidate-b")
        guard case .saved = await second.value else { return XCTFail("Newer candidate did not save") }
        await client.complete("candidate-a")
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .superseded)
        XCTAssertEqual(storage.value(for: .jevRouterAPIKey), "candidate-b")
    }

    func testStoredKeyUsesExplicitNoninteractiveAccessMode() async {
        let storage = TestSecureStorageBackend(values: [.jevRouterAPIKey: "stored"])
        let client = ImmediateJevClient()
        let service = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: storage),
            client: client
        )
        _ = await service.validateStoredKey(
            operationID: UUID(),
            accessMode: .nonInteractive(reason: .backgroundAvailabilityCheck)
        )
        XCTAssertTrue(storage.calls.contains(.init(
            operation: .get,
            account: .jevRouterAPIKey,
            accessMode: .nonInteractive(reason: .backgroundAvailabilityCheck)
        )))
        guard case let .ready(_, policyVersion) = await service.readinessSnapshot() else {
            return XCTFail("A valid key must make Jev ready")
        }
        XCTAssertEqual(policyVersion, JevRouterCredentialService.routingPolicyVersion)
    }

    func testSavedKeyBootstrapsAReplacementServiceInstance() async {
        let storage = TestSecureStorageBackend()
        let first = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: storage),
            client: ImmediateJevClient()
        )
        guard case .saved = await first.validateAndSave("persistent", operationID: UUID()) else {
            return XCTFail("Expected the first service to save the key")
        }

        let replacement = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: storage),
            client: ImmediateJevClient()
        )
        await replacement.bootstrapStoredConfigurationIfNeeded()

        guard case .ready = await replacement.readinessSnapshot() else {
            return XCTFail("A replacement service must restore readiness from persisted storage")
        }
    }

    func testMissingStoredKeyInvalidatesPreviouslyValidatedReadiness() async throws {
        let storage = TestSecureStorageBackend(values: [.jevRouterAPIKey: "stored"])
        let service = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: storage),
            client: ImmediateJevClient()
        )
        guard case .saved = await service.validateStoredKey(operationID: UUID()) else {
            return XCTFail("Expected initial stored-key validation")
        }
        try storage.delete(for: SecureStorageAccount.jevRouterAPIKey.identifier, accessMode: .interactive)

        let result = await service.validateStoredKey(operationID: UUID())
        XCTAssertEqual(result, .missingKey)
        guard case .needsConfiguration = await service.readinessSnapshot() else {
            return XCTFail("Missing stored credential must fail closed")
        }
    }

    func testReadinessGenerationPublishesToTwoWindowObservers() async {
        let service = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend(values: [.jevRouterAPIKey: "stored"])),
            client: ImmediateJevClient()
        )
        let firstStream = await service.readinessUpdates()
        let secondStream = await service.readinessUpdates()
        let first = Task { await firstStream.firstReadyGeneration() }
        let second = Task { await secondStream.firstReadyGeneration() }
        await service.bootstrapStoredConfigurationIfNeeded()
        let firstGeneration = await first.value
        let secondGeneration = await second.value
        XCTAssertNotNil(firstGeneration)
        XCTAssertEqual(firstGeneration, secondGeneration)
    }

    func testCancelValidationCancelsExactTransportTask() async {
        let client = CancellationObservingJevClient()
        let service = JevRouterCredentialService(client: client)
        let validation = Task { await service.validateAndSave("candidate", operationID: UUID()) }
        await client.waitUntilStarted()
        await service.cancelAndAdvanceGeneration()
        let validationResult = await validation.value
        XCTAssertEqual(validationResult, .superseded)
        await client.waitUntilCancelled()
        guard case let .needsConfiguration(generation, _) = await service.readinessSnapshot() else {
            return XCTFail("Cancellation must advance generation and fail closed")
        }
        XCTAssertGreaterThan(generation, 0)
    }

    func testCancelValidationSettlesWhenClientIgnoresCancellationAndFiltersLateSuccess() async {
        let storage = TestSecureStorageBackend()
        let client = ControlledJevClient()
        let service = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: storage),
            client: client
        )
        let validation = Task { await service.validateAndSave("candidate", operationID: UUID()) }
        await client.waitUntilStarted("candidate")

        await service.cancelAndAdvanceGeneration()
        let result = await validation.value
        XCTAssertEqual(result, .superseded)
        await client.complete("candidate")
        await Task.yield()

        XCTAssertNil(storage.value(for: .jevRouterAPIKey))
        guard case .needsConfiguration = await service.readinessSnapshot() else {
            return XCTFail("Late success must not republish validated readiness")
        }
    }
}

private extension AsyncStream where Element == DecisionReadiness {
    func firstReadyGeneration() async -> UInt64? {
        for await readiness in self {
            if case let .ready(generation, _) = readiness { return generation }
        }
        return nil
    }
}

private actor ControlledJevClient: JevRoutingClientProtocol {
    private var started: Set<String> = []
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var completions: [String: CheckedContinuation<JevModelList, Error>] = [:]

    func listModels(apiKey: String, timeout: Duration) async throws -> JevModelList {
        started.insert(apiKey)
        startWaiters.removeValue(forKey: apiKey)?.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { completions[apiKey] = $0 }
    }

    func judge(
        request: JevRoutingWireRequest,
        apiKey: String,
        timeout: Duration
    ) async throws -> JevRoutingWireResponse {
        throw JevRoutingClientError.invalidRequest
    }

    func waitUntilStarted(_ key: String) async {
        if started.contains(key) { return }
        await withCheckedContinuation { startWaiters[key, default: []].append($0) }
    }

    func complete(_ key: String) {
        completions.removeValue(forKey: key)?.resume(returning: .init(models: [.init(name: "jev")]))
    }
}

private struct ImmediateJevClient: JevRoutingClientProtocol {
    func listModels(apiKey: String, timeout: Duration) async throws -> JevModelList {
        .init(models: [.init(name: "jev-latest")])
    }

    func judge(
        request: JevRoutingWireRequest,
        apiKey: String,
        timeout: Duration
    ) async throws -> JevRoutingWireResponse {
        throw JevRoutingClientError.invalidRequest
    }
}

private actor CancellationObservingJevClient: JevRoutingClientProtocol {
    private var started = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func listModels(apiKey: String, timeout: Duration) async throws -> JevModelList {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        do {
            try await Task.sleep(for: .seconds(60))
            throw JevRoutingClientError.timeout
        } catch is CancellationError {
            cancelled = true
            cancellationWaiters.forEach { $0.resume() }
            cancellationWaiters.removeAll()
            throw CancellationError()
        }
    }

    func judge(request: JevRoutingWireRequest, apiKey: String, timeout: Duration) async throws -> JevRoutingWireResponse {
        throw JevRoutingClientError.invalidRequest
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilCancelled() async {
        if cancelled { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }
}

final class OpenAIDecisionsRouterCredentialServiceTests: XCTestCase {
    func testSyntheticValidationSavesOnlyDedicatedAccountInteractively() async {
        let storage = TestSecureStorageBackend(values: [.openAIAPI: "provider", .codexCLIAPI: "cli", .jevRouterAPIKey: "jev"])
        let recorder = DecisionsTestRecorder()
        let service = makeService(storage, recorder)
        let result = await service.validateAndSave(" candidate ", operationID: UUID())
        XCTAssertEqual(result, .saved(generation: 1))
        XCTAssertEqual(storage.value(for: .openAIDecisionsRouterAPIKey), "candidate")
        XCTAssertEqual(storage.value(for: .openAIAPI), "provider")
        let requests = await recorder.requests
        XCTAssertEqual(requests, [OpenAIDecisionsRouterCredentialService.validationRequest])
        XCTAssertEqual(storage.calls, [.init(operation: .save, account: .openAIDecisionsRouterAPIKey, accessMode: .interactive)])
    }

    func testMissingKeyAndKeychainDenialAreDistinct() async {
        let storage = TestSecureStorageBackend()
        let service = makeService(storage)
        let missing = await service.validateStoredKey(operationID: UUID())
        XCTAssertEqual(missing, .missingKey)
        storage.getErrors[.openAIDecisionsRouterAPIKey] = .interactionNotAllowed
        let denied = await service.validateStoredKey(operationID: UUID())
        guard case .failed = denied else { return XCTFail("Expected redacted storage failure") }
        let state = await service.readinessSnapshot()
        guard case .temporarilyUnavailable = state else { return XCTFail("Denial is not a missing key") }
    }

    func testBootstrapAndRoutingUseNoninteractiveAccessRevalidationUsesInteractive() async throws {
        let storage = TestSecureStorageBackend(values: [.openAIDecisionsRouterAPIKey: "stored"])
        let service = makeService(storage)
        await service.bootstrapStoredConfigurationIfNeeded()
        _ = try await service.judgeForRouting(OpenAIDecisionsRouterCredentialService.validationRequest)
        _ = await service.perform(.revalidateStoredSecret)
        XCTAssertEqual(storage.calls.map(\.accessMode), [.nonInteractive(reason: .backgroundAvailabilityCheck), .nonInteractive(reason: .backgroundAvailabilityCheck), .interactive])
    }

    func testFailedBootstrapDoesNotRebillSameGeneration() async {
        let recorder = DecisionsTestRecorder(error: .timeout)
        let service = makeService(TestSecureStorageBackend(values: [.openAIDecisionsRouterAPIKey: "stored"]), recorder)
        await service.bootstrapStoredConfigurationIfNeeded()
        await service.bootstrapStoredConfigurationIfNeeded()
        let count = await recorder.requests.count
        XCTAssertEqual(count, 1)
        _ = await service.validateStoredKey(operationID: UUID())
        let explicitCount = await recorder.requests.count
        XCTAssertEqual(explicitCount, 2)
    }

    func testBootstrapSkipsExplicitValidationAtomically() async {
        let gate = DecisionsTestGate()
        let service = OpenAIDecisionsRouterCredentialService(secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()), decide: { request, key in try await gate.decide(request, key: key) })
        let operation = Task { await service.validateAndSave("candidate", operationID: UUID()) }
        await gate.waitFor("candidate")
        await service.bootstrapStoredConfigurationIfNeeded()
        let count = await gate.count
        XCTAssertEqual(count, 1)
        await gate.complete("candidate")
        _ = await operation.value
    }

    func testFailedReplacementRestoresStableReadyNotValidating() async {
        let recorder = DecisionsTestRecorder()
        let service = makeService(TestSecureStorageBackend(), recorder)
        _ = await service.validateAndSave("old", operationID: UUID())
        let before = await service.readinessSnapshot()
        await recorder.setError(.policyUnavailable)
        _ = await service.validateAndSave("bad", operationID: UUID())
        let after = await service.readinessSnapshot()
        XCTAssertEqual(after, before)
    }

    func testOverlappingReplacementsCancelPromptlyAndLateResultCannotSave() async {
        let storage = TestSecureStorageBackend()
        let gate = DecisionsTestGate()
        let service = OpenAIDecisionsRouterCredentialService(secureKeys: SecureKeysService(secureStorage: storage), decide: { request, key in try await gate.decide(request, key: key) })
        let first = Task { await service.validateAndSave("first", operationID: UUID()) }
        await gate.waitFor("first")
        let second = Task { await service.validateAndSave("second", operationID: UUID()) }
        await gate.waitFor("second")
        // Fake deliberately ignores cancellation; logical caller must settle before fake completes.
        let result = await first.value
        XCTAssertEqual(result, .superseded)
        await gate.complete("second")
        _ = await second.value
        await gate.complete("first")
        XCTAssertEqual(storage.value(for: .openAIDecisionsRouterAPIKey), "second")
        let state = await service.readinessSnapshot()
        XCTAssertEqual(state.generation, 1)
        XCTAssertTrue(state.isReady)
    }

    func testRemovalWinsOverValidationAndLateFailureCannotRestoreReadiness() async throws {
        let storage = TestSecureStorageBackend(values: [.openAIDecisionsRouterAPIKey: "old"])
        let gate = DecisionsTestGate()
        let service = OpenAIDecisionsRouterCredentialService(secureKeys: SecureKeysService(secureStorage: storage), decide: { request, key in try await gate.decide(request, key: key) })
        let operation = Task { await service.validateAndSave("candidate", operationID: UUID()) }
        await gate.waitFor("candidate")
        try await service.delete(operationID: UUID())
        let result = await operation.value
        XCTAssertEqual(result, .superseded)
        await gate.complete("candidate", error: .policyUnavailable)
        XCTAssertNil(storage.value(for: .openAIDecisionsRouterAPIKey))
        let state = await service.readinessSnapshot()
        XCTAssertFalse(state.isReady)
        XCTAssertEqual(state.generation, 1)
    }

    func testParentCancellationSettlesIgnoringFakeAndRestoresStableState() async {
        let gate = DecisionsTestGate()
        let service = OpenAIDecisionsRouterCredentialService(secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()), decide: { request, key in try await gate.decide(request, key: key) })
        let before = await service.readinessSnapshot()
        let operation = Task { await service.validateAndSave("candidate", operationID: UUID()) }
        await gate.waitFor("candidate")
        operation.cancel()
        let result = await operation.value
        XCTAssertEqual(result, .superseded)
        let after = await service.readinessSnapshot()
        XCTAssertEqual(after, before)
        await gate.complete("candidate")
    }

    func testCancellationDuringConfirmedSaveStillCommits() async {
        let storage = DecisionsMutationStorage()
        let gate = DecisionsTestGate()
        let service = OpenAIDecisionsRouterCredentialService(secureKeys: SecureKeysService(secureStorage: storage), decide: { request, key in try await gate.decide(request, key: key) })
        let operation = Task { await service.validateAndSave("new", operationID: UUID()) }
        await gate.waitFor("new")
        storage.onSave = { operation.cancel() }
        await gate.complete("new")
        let result = await operation.value
        XCTAssertEqual(result, .saved(generation: 1))
        let state = await service.readinessSnapshot()
        XCTAssertTrue(state.isReady)
        XCTAssertEqual(storage.value, "new")
    }

    func testWriteThenThrowFencesPriorGenerationAndRequiresRevalidation() async {
        let storage = DecisionsMutationStorage()
        let recorder = DecisionsTestRecorder()
        let service = OpenAIDecisionsRouterCredentialService(secureKeys: SecureKeysService(secureStorage: storage), decide: { request, key in try await recorder.decide(request, key: key) })
        _ = await service.validateAndSave("old", operationID: UUID())
        storage.throwAfterSave = true
        let result = await service.validateAndSave("new", operationID: UUID())
        guard case .failed = result else { return XCTFail("Expected ambiguous write failure") }
        XCTAssertEqual(storage.value, "new")
        let state = await service.readinessSnapshot()
        XCTAssertFalse(state.isReady)
        XCTAssertEqual(state.generation, 2)
        await service.bootstrapStoredConfigurationIfNeeded()
        let count = await recorder.requests.count
        XCTAssertEqual(count, 2, "Ambiguous writes require explicit revalidation, not an automatic billable probe")
        let revalidated = await service.validateStoredKey(operationID: UUID())
        XCTAssertEqual(revalidated, .saved(generation: 3))
    }

    func testDefiniteRemovalDenialPreservesReadinessUnknownRemovalFencesIt() async {
        let storage = TestSecureStorageBackend()
        let service = makeService(storage)
        _ = await service.validateAndSave("old", operationID: UUID())
        let before = await service.readinessSnapshot()
        storage.deleteErrors[.openAIDecisionsRouterAPIKey] = .userInteractionCancelled
        _ = await service.perform(.removeStoredSecret)
        let preserved = await service.readinessSnapshot()
        XCTAssertEqual(preserved, before)
        storage.deleteErrors[.openAIDecisionsRouterAPIKey] = .unexpectedStatus(-1)
        _ = await service.perform(.removeStoredSecret)
        let fenced = await service.readinessSnapshot()
        XCTAssertFalse(fenced.isReady)
        XCTAssertEqual(fenced.generation, before.generation + 1)
        await service.bootstrapStoredConfigurationIfNeeded()
        let stillFenced = await service.readinessSnapshot()
        XCTAssertEqual(stillFenced, fenced, "Ambiguous removal must not silently regain readiness")
    }

    func testRemote401PolicyFailurePreservesStoredKeyAndReadinessGeneration() async {
        let recorder = DecisionsTestRecorder()
        let storage = TestSecureStorageBackend()
        let service = makeService(storage, recorder)
        _ = await service.validateAndSave("old", operationID: UUID())
        let before = await service.readinessSnapshot()
        await recorder.setError(.policyUnavailable)
        do { _ = try await service.judgeForRouting(OpenAIDecisionsRouterCredentialService.validationRequest)
            XCTFail("Expected denial")
        } catch {}
        let after = await service.readinessSnapshot()
        XCTAssertEqual(after, before)
        XCTAssertEqual(storage.value(for: .openAIDecisionsRouterAPIKey), "old")
    }

    func testReplacementFencesLateRoutingResult() async throws {
        let gate = DecisionsTestGate()
        let service = OpenAIDecisionsRouterCredentialService(secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()), decide: { request, key in try await gate.decide(request, key: key) })
        let initial = Task { await service.validateAndSave("old", operationID: UUID()) }
        await gate.waitFor("old")
        await gate.complete("old")
        _ = await initial.value
        let route = Task { try await service.judgeForRouting(OpenAIDecisionsRouterCredentialService.validationRequest) }
        await gate.waitFor("old")
        let replacement = Task { await service.validateAndSave("new", operationID: UUID()) }
        await gate.waitFor("new")
        await gate.complete("new")
        _ = await replacement.value
        await gate.complete("old")
        do { _ = try await route.value
            XCTFail("Old-generation response must be rejected")
        } catch { XCTAssertEqual(error as? OpenAIDecisionsRoutingClientError, .policyUnavailable) }
    }

    func testRefusalCannotEstablishReadinessOrSave() async {
        let storage = TestSecureStorageBackend()
        let service = OpenAIDecisionsRouterCredentialService(secureKeys: SecureKeysService(secureStorage: storage), decide: { request, _ in decisionsTestResponse(request, refusal: true) })
        _ = await service.validateAndSave("candidate", operationID: UUID())
        XCTAssertNil(storage.value(for: .openAIDecisionsRouterAPIKey))
        let state = await service.readinessSnapshot()
        XCTAssertFalse(state.isReady)
    }

    func testStreamStartsWithSnapshotThenOrderedOverlayAndCommittedState() async {
        let service = makeService(TestSecureStorageBackend())
        let stream = await service.readinessUpdates()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.generation, 0)
        _ = await service.validateAndSave("candidate", operationID: UUID())
        let overlay = await iterator.next()
        XCTAssertEqual(overlay, .validating(generation: 0))
        let commitOverlay = await iterator.next()
        XCTAssertEqual(commitOverlay, .validating(generation: 1))
        let committed = await iterator.next()
        XCTAssertEqual(committed, .ready(generation: 1, policyVersion: OpenAIDecisionsRouterCredentialService.routingPolicyVersion))
    }

    private func makeService(_ storage: TestSecureStorageBackend, _ recorder: DecisionsTestRecorder = DecisionsTestRecorder()) -> OpenAIDecisionsRouterCredentialService {
        OpenAIDecisionsRouterCredentialService(secureKeys: SecureKeysService(secureStorage: storage), decide: { request, key in try await recorder.decide(request, key: key) })
    }
}

/// Synthetic fixtures use exactly the fields frozen in contract record Response mapping.
func decisionsTestResponse(_ request: OpenAIDecisionsWireRequest, refusal: Bool = false) -> OpenAIDecisionsWireResponse {
    let question = request.questions[0]
    return .init(model: request.model, answers: [refusal ? .refusal(name: question.name) : .choice(name: question.name, choice: question.choices[0].value, probabilities: question.choices.map { .init(value: $0.value, probability: 0.5) }, confidence: 0.8)], usage: .init(inputTokens: 10, inputTokensDetails: .init(cachedTokens: 0, cacheWriteTokens: 0), outputTokens: 0, outputTokensDetails: .init(reasoningTokens: 0), totalTokens: 10))
}

actor DecisionsTestRecorder {
    var requests: [OpenAIDecisionsWireRequest] = []
    var keys: [String] = []
    var error: OpenAIDecisionsRoutingClientError?
    init(error: OpenAIDecisionsRoutingClientError? = nil) {
        self.error = error
    }

    func setError(_ error: OpenAIDecisionsRoutingClientError?) {
        self.error = error
    }

    func decide(_ request: OpenAIDecisionsWireRequest, key: String) throws -> OpenAIDecisionsWireResponse {
        requests.append(request)
        keys.append(key)
        if let error { throw error }
        return decisionsTestResponse(request)
    }
}

actor DecisionsTestGate {
    private var pending: [String: (OpenAIDecisionsWireRequest, CheckedContinuation<OpenAIDecisionsWireResponse, Error>)] = [:]
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var count = 0
    func decide(_ request: OpenAIDecisionsWireRequest, key: String) async throws -> OpenAIDecisionsWireResponse {
        count += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[key] = (request, continuation)
            waiters.removeValue(forKey: key)?.resume()
        }
    }

    func waitFor(_ key: String) async {
        if pending[key] != nil { return }
        await withCheckedContinuation { waiters[key] = $0 }
    }

    func complete(_ key: String, error: OpenAIDecisionsRoutingClientError? = nil) {
        guard let (request, continuation) = pending.removeValue(forKey: key) else { return }
        if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: decisionsTestResponse(request)) }
    }
}

private final class DecisionsMutationStorage: SecureKeyValueStorageBackend, @unchecked Sendable {
    var value: String?
    var throwAfterSave = false
    var onSave: (() -> Void)?
    let persistsValuesAcrossLaunches = true
    func get(for key: String, accessMode: KeychainAccessMode) throws -> String {
        guard let value else { throw KeychainService.KeychainError.itemNotFound }
        return value
    }

    func save(_ value: String, for key: String, accessMode: KeychainAccessMode) throws {
        self.value = value
        onSave?()
        if throwAfterSave { throw KeychainService.KeychainError.unexpectedStatus(-1) }
    }

    func create(_ value: String, for key: String, accessMode: KeychainAccessMode) throws {
        guard self.value == nil else { throw KeychainService.KeychainError.duplicateItem }
        try save(value, for: key, accessMode: accessMode)
    }

    func delete(for key: String, accessMode: KeychainAccessMode) throws {
        value = nil
    }
}
