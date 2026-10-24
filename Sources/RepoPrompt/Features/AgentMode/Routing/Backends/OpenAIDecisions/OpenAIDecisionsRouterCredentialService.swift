import Foundation
import RepoPromptSecureStorage

/// Owns only the dedicated Decisions credential. Selection and durable feature intent live elsewhere.
actor OpenAIDecisionsRouterCredentialService: DecisionServiceConfigurationController {
    typealias Decide = @Sendable (OpenAIDecisionsWireRequest, String) async throws -> OpenAIDecisionsWireResponse
    enum ValidationResult: Equatable {
        case saved(generation: UInt64)
        case missingKey
        case superseded
        case failed(String)
    }

    static let pinnedModel = OpenAIDecisionsRoutingResponseInterpreter.pinnedModel
    static let routingPolicyVersion = "openai-decisions-gpt-6-luna-rpce-v2"
    /// Fixed benign billable access probe; never populated from a user task.
    static let validationRequest = OpenAIDecisionsWireRequest(
        model: pinnedModel, input: "Choose the label for the word apple.",
        questions: [.init(name: "credential_access", instructions: "Choose the matching category.", choices: [
            .init(value: "fruit", description: "An edible fruit."),
            .init(value: "vehicle", description: "A means of transportation.")
        ])]
    )

    private let secureKeys: SecureKeysService
    private let decide: Decide
    private var generation: UInt64 = 0
    private var stable: DecisionReadiness = .needsConfiguration(generation: 0, reason: "Validate a Decisions OpenAI API key first.")
    private var activeID: UUID?
    private var activeTask: Task<OpenAIDecisionsWireResponse, Error>?
    private var startupAttemptedGeneration: UInt64?
    private var observers: [UUID: AsyncStream<DecisionReadiness>.Continuation] = [:]

    init(secureKeys: SecureKeysService = SecureKeysService(), decide: @escaping Decide = { request, key in
        try await OpenAIDecisionsRoutingClient().decide(request, apiKey: key)
    }) {
        self.secureKeys = secureKeys
        self.decide = decide
    }

    func readinessSnapshot() -> DecisionReadiness {
        activeID == nil ? stable : .validating(generation: generation)
    }

    func readinessUpdates() -> AsyncStream<DecisionReadiness> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.yield(readinessSnapshot())
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }

    func validateAndSave(_ candidate: String, operationID: UUID) async -> ValidationResult {
        let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .missingKey }
        begin(operationID)
        defer { finish(operationID) }
        do {
            try await probe(key, operationID: operationID)
            guard activeID == operationID, !Task.isCancelled else { return .superseded }
            do {
                // Synchronous durable commit: no cancellation check after a confirmed save.
                try secureKeys.saveAPIKey(key, for: .openAIDecisionsRouterAPIKey, accessMode: .interactive)
            } catch {
                advanceReady(false)
                startupAttemptedGeneration = generation // Explicit revalidation owns recovery after an ambiguous mutation.
                return .failed("Secure storage may have changed. Revalidate the stored Decisions key.")
            }
            advanceReady(true)
            startupAttemptedGeneration = generation
            return .saved(generation: generation)
        } catch {
            guard activeID == operationID, !Task.isCancelled else { return .superseded }
            if Self.isCancellation(error) { return .superseded }
            // Candidate failures leave the stable credential untouched, never restore an overlay.
            return .failed(Self.message(error))
        }
    }

    func validateStoredKey(operationID: UUID, accessMode: KeychainAccessMode = .interactive) async -> ValidationResult {
        begin(operationID)
        defer { finish(operationID) }
        do {
            let key = try await secureKeys.getAPIKey(for: .openAIDecisionsRouterAPIKey, accessMode: accessMode)
            guard activeID == operationID, !Task.isCancelled else { return .superseded }
            guard let key, !key.isEmpty else {
                advanceReady(false)
                return .missingKey
            }
            try await probe(key, operationID: operationID)
            guard activeID == operationID, !Task.isCancelled else { return .superseded }
            advanceReady(true)
            startupAttemptedGeneration = generation
            return .saved(generation: generation)
        } catch {
            guard activeID == operationID, !Task.isCancelled else { return .superseded }
            if Self.isCancellation(error) { return .superseded }
            if error as? OpenAIDecisionsRoutingClientError == .policyUnavailable {
                stable = .policyUnavailable(generation: generation, reason: Self.message(error))
            } else {
                stable = .temporarilyUnavailable(generation: generation, reason: Self.message(error))
            }
            return .failed(Self.message(error))
        }
    }

    func delete(operationID: UUID) throws {
        begin(operationID)
        defer { finish(operationID) }
        do {
            try secureKeys.deleteAPIKey(for: .openAIDecisionsRouterAPIKey, accessMode: .interactive)
            advanceReady(false)
            startupAttemptedGeneration = nil
        } catch {
            // These concrete Keychain delete errors occur before mutation. Unknown backends/errors
            // provide no such guarantee and must fence readiness rather than claim the old key survived.
            switch error as? KeychainService.KeychainError {
            case .interactionNotAllowed, .userInteractionCancelled, .authenticationFailed: break
            default:
                advanceReady(false)
                startupAttemptedGeneration = generation
            }
            throw error
        }
    }

    func judgeForRouting(_ request: OpenAIDecisionsWireRequest) async throws -> OpenAIDecisionsWireResponse {
        guard activeID == nil, stable.isReady else { throw OpenAIDecisionsRoutingClientError.policyUnavailable }
        let captured = generation
        let key: String?
        do {
            key = try await secureKeys.getAPIKey(for: .openAIDecisionsRouterAPIKey, accessMode: .nonInteractive(reason: .backgroundAvailabilityCheck))
        } catch {
            if generation == captured, activeID == nil {
                stable = .temporarilyUnavailable(generation: generation, reason: "Secure storage access is unavailable.")
                publish()
            }
            throw OpenAIDecisionsRoutingClientError.policyUnavailable
        }
        guard generation == captured, activeID == nil, stable.isReady else { throw OpenAIDecisionsRoutingClientError.policyUnavailable }
        guard let key, !key.isEmpty else {
            advanceReady(false)
            throw OpenAIDecisionsRoutingClientError.policyUnavailable
        }
        // Remote errors, including ambiguous 401, cannot invalidate or delete a credential.
        let response = try await decide(request, key)
        guard generation == captured, activeID == nil, stable.isReady else { throw OpenAIDecisionsRoutingClientError.policyUnavailable }
        return response
    }

    func bootstrapStoredConfigurationIfNeeded() async {
        guard activeID == nil, startupAttemptedGeneration != generation else { return }
        startupAttemptedGeneration = generation
        let result = await validateStoredKey(operationID: UUID(), accessMode: .nonInteractive(reason: .backgroundAvailabilityCheck))
        guard result != .superseded else { return }
        // Missing-key validation can fence the generation too; do not rebill at that new state.
        startupAttemptedGeneration = generation
    }

    func cancelValidation() {
        activeTask?.cancel()
        activeTask = nil
        activeID = nil
        publish()
    }

    func cancelAndAdvanceGeneration() {
        cancelValidation()
        advanceReady(false)
        startupAttemptedGeneration = nil
    }

    func perform(_ action: DecisionServiceSettingsAction) async -> DecisionServiceSettingsActionResult {
        let result: ValidationResult
        switch action {
        case let .validateAndSaveSecret(secret): result = await validateAndSave(secret, operationID: UUID())
        case .revalidateStoredSecret: result = await validateStoredKey(operationID: UUID())
        case .removeStoredSecret:
            do { try delete(operationID: UUID())
                return .succeeded("Stored Decisions key removed.")
            } catch { return .failed("The stored Decisions key could not be removed.") }
        }
        switch result {
        case .saved: return .succeeded("Decisions access verified at this moment. Routing is ready.")
        case .missingKey: return .missingSecret("Enter an API key for Decisions by OpenAI.")
        case .superseded: return .superseded("Validation was cancelled or superseded.")
        case let .failed(message): return .failed(message)
        }
    }

    private func probe(_ key: String, operationID: UUID) async throws {
        let decide = decide
        let task = Task {
            try await OpenAIDecisionsCredentialFirstResult().run { try await decide(Self.validationRequest, key) }
        }
        activeTask = task
        let response = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard activeID == operationID, !Task.isCancelled else { throw CancellationError() }
        let interpreted = try OpenAIDecisionsRoutingResponseInterpreter().interpret(response, expectedQuestionName: "credential_access", submittedChoices: ["fruit", "vehicle"])
        guard case .choice = interpreted else { throw OpenAIDecisionsRoutingClientError.invalidResponse }
    }

    private func begin(_ id: UUID) {
        activeTask?.cancel()
        activeTask = nil
        activeID = id
        publish()
    }

    private func finish(_ id: UUID) {
        guard activeID == id else { return }
        activeTask = nil
        activeID = nil
        publish()
    }

    private func advanceReady(_ ready: Bool) {
        generation &+= 1
        stable = ready ? .ready(generation: generation, policyVersion: Self.routingPolicyVersion) : .needsConfiguration(generation: generation, reason: "Validate a Decisions OpenAI API key first.")
        publish()
    }

    private func publish() {
        for observer in observers.values {
            observer.yield(readinessSnapshot())
        }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || error as? OpenAIDecisionsRoutingClientError == .cancelled
    }

    private static func message(_ error: Error) -> String {
        if error as? OpenAIDecisionsRoutingClientError == .policyUnavailable { return "Decisions access is unavailable for this project or account." }
        if error is KeychainService.KeychainError { return "Secure storage access is unavailable." }
        return "Decisions validation is temporarily unavailable or returned an invalid response."
    }
}

/// Settles validation promptly even if an injected operation ignores cancellation. Only the actor
/// can commit storage; this detached response owner can never save or publish readiness.
private final class OpenAIDecisionsCredentialFirstResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OpenAIDecisionsWireResponse, Error>?
    private var result: Result<OpenAIDecisionsWireResponse, Error>?
    private var task: Task<Void, Never>?
    func run(_ operation: @escaping @Sendable () async throws -> OpenAIDecisionsWireResponse) async throws -> OpenAIDecisionsWireResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result { lock.unlock()
                    continuation.resume(with: result)
                    return
                }
                self.continuation = continuation
                lock.unlock()
                let task = Task { do { try await self.settle(.success(operation())) } catch { self.settle(.failure(error)) } }
                lock.lock()
                if result != nil { lock.unlock()
                    task.cancel()
                } else { self.task = task
                    lock.unlock()
                }
            }
        } onCancel: { self.settle(.failure(CancellationError())) }
    }

    private func settle(_ result: Result<OpenAIDecisionsWireResponse, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        let task = task
        self.task = nil
        lock.unlock()
        task?.cancel()
        continuation?.resume(with: result)
    }
}
