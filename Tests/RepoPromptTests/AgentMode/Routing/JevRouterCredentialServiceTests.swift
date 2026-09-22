import Foundation
@testable import RepoPromptApp
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

private extension AsyncStream where Element == AgentTaskRouterBackendReadiness {
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
