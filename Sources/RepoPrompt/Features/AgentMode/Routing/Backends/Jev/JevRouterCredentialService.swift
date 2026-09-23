import Foundation

actor JevRouterCredentialService: AgentTaskRouterBackendSettingsController {
    enum ValidationResult: Equatable {
        case saved(generation: UInt64, supportedModel: String)
        case missingKey
        case superseded
        case failed(String)
    }

    static let pinnedModel = "jev-1.13.0"
    static let routingPolicyVersion = "jev-1.13.0-rpce-session-routing-v5-model-then-effort"

    private let secureKeys: SecureKeysService
    private let client: any JevRoutingClientProtocol
    private var generation: UInt64 = 0
    private var activeValidationID: UUID?
    private var activeValidationTask: Task<JevModelList, Error>?
    private var hasValidatedKey = false
    private var isValidating = false
    private var startupValidatedGeneration: UInt64?
    private var readinessContinuations: [UUID: AsyncStream<AgentTaskRouterBackendReadiness>.Continuation] = [:]

    init(
        secureKeys: SecureKeysService = SecureKeysService(),
        client: any JevRoutingClientProtocol = JevRoutingClient()
    ) {
        self.secureKeys = secureKeys
        self.client = client
    }

    func readinessSnapshot() -> AgentTaskRouterBackendReadiness {
        if isValidating { return .validating(generation: generation) }
        guard hasValidatedKey else {
            return .needsConfiguration(generation: generation, reason: "Validate a TypeSafe API key.")
        }
        return .ready(generation: generation, policyVersion: Self.routingPolicyVersion)
    }

    func readinessUpdates() -> AsyncStream<AgentTaskRouterBackendReadiness> {
        let observationID = UUID()
        return AsyncStream { continuation in
            readinessContinuations[observationID] = continuation
            continuation.yield(readinessSnapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeReadinessContinuation(observationID) }
            }
        }
    }

    func validateAndSave(_ candidate: String, operationID: UUID) async -> ValidationResult {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .missingKey }
        beginValidation(operationID: operationID)
        defer { finishValidationIfOwned(operationID: operationID) }
        do {
            let models = try await validateModels(apiKey: trimmed, operationID: operationID)
            guard owns(operationID), !Task.isCancelled else { return .superseded }
            guard let supportedModel = models.models.map(\.name).first(where: Self.isSupportedModelName) else {
                return .failed("The account does not expose a supported Jev evaluator.")
            }
            try secureKeys.saveAPIKey(trimmed, for: .jevRouterAPIKey, accessMode: .interactive)
            guard owns(operationID), !Task.isCancelled else { return .superseded }
            advanceGeneration(validated: true)
            startupValidatedGeneration = generation
            return .saved(generation: generation, supportedModel: supportedModel)
        } catch is CancellationError {
            return .superseded
        } catch {
            guard owns(operationID), !Task.isCancelled else { return .superseded }
            if error as? JevRoutingClientError == .authentication {
                advanceGeneration(validated: false)
            }
            return .failed(Self.redactedMessage(for: error))
        }
    }

    func validateStoredKey(
        operationID: UUID,
        accessMode: KeychainAccessMode = .nonInteractive(reason: .backgroundAvailabilityCheck)
    ) async -> ValidationResult {
        beginValidation(operationID: operationID)
        defer { finishValidationIfOwned(operationID: operationID) }
        do {
            let storedKey = try await secureKeys.getAPIKey(for: .jevRouterAPIKey, accessMode: accessMode)
            guard owns(operationID), !Task.isCancelled else { return .superseded }
            guard let key = storedKey, !key.isEmpty else {
                advanceGeneration(validated: false)
                return .missingKey
            }
            let models = try await validateModels(apiKey: key, operationID: operationID)
            guard owns(operationID), !Task.isCancelled else { return .superseded }
            guard let supportedModel = models.models.map(\.name).first(where: Self.isSupportedModelName) else {
                advanceGeneration(validated: false)
                return .failed("The account does not expose a supported Jev evaluator.")
            }
            advanceGeneration(validated: true)
            startupValidatedGeneration = generation
            return .saved(generation: generation, supportedModel: supportedModel)
        } catch is CancellationError {
            return .superseded
        } catch {
            guard owns(operationID), !Task.isCancelled else { return .superseded }
            if error as? JevRoutingClientError == .authentication {
                advanceGeneration(validated: false)
            }
            return .failed(Self.redactedMessage(for: error))
        }
    }

    func delete(operationID: UUID) throws {
        beginValidation(operationID: operationID)
        defer { finishValidationIfOwned(operationID: operationID) }
        try secureKeys.deleteAPIKey(for: .jevRouterAPIKey, accessMode: .interactive)
        advanceGeneration(validated: false)
        startupValidatedGeneration = nil
    }

    func loadForRouting() async throws -> (key: String, generation: UInt64) {
        guard hasValidatedKey else { throw JevRoutingClientError.authentication }
        let capturedGeneration = generation
        guard let key = try await secureKeys.getAPIKey(
            for: .jevRouterAPIKey,
            accessMode: .nonInteractive(reason: .backgroundAvailabilityCheck)
        ), !key.isEmpty, hasValidatedKey, generation == capturedGeneration else {
            advanceGeneration(validated: false)
            throw JevRoutingClientError.authentication
        }
        return (key, capturedGeneration)
    }

    func judgeForRouting(_ request: JevRoutingWireRequest) async throws -> JevRoutingWireResponse {
        let credential = try await loadForRouting()
        do {
            return try await client.judge(
                request: request,
                apiKey: credential.key,
                timeout: JevRoutingClient.outerDeadline
            )
        } catch {
            if error as? JevRoutingClientError == .authentication,
               generation == credential.generation
            {
                advanceGeneration(validated: false)
            }
            throw error
        }
    }

    func cancelValidation() {
        activeValidationTask?.cancel()
        activeValidationTask = nil
        activeValidationID = nil
        isValidating = false
        publishReadiness()
    }

    func bootstrapStoredConfigurationIfNeeded() async {
        guard startupValidatedGeneration != generation else { return }
        let attemptedGeneration = generation
        _ = await validateStoredKey(
            operationID: UUID(),
            accessMode: .nonInteractive(reason: .backgroundAvailabilityCheck)
        )
        if startupValidatedGeneration == nil, generation == attemptedGeneration {
            startupValidatedGeneration = generation
        }
    }

    func cancelAndAdvanceGeneration() {
        activeValidationTask?.cancel()
        activeValidationTask = nil
        activeValidationID = nil
        isValidating = false
        generation &+= 1
        hasValidatedKey = false
        startupValidatedGeneration = nil
        publishReadiness()
    }

    func perform(
        _ action: AgentTaskRouterBackendSettingsAction
    ) async -> AgentTaskRouterBackendSettingsActionResult {
        switch action {
        case let .validateAndSaveSecret(secret):
            return await Self.actionResult(from: validateAndSave(secret, operationID: UUID()))
        case .revalidateStoredSecret:
            return await Self.actionResult(from: validateStoredKey(operationID: UUID(), accessMode: .interactive))
        case .removeStoredSecret:
            do {
                try delete(operationID: UUID())
                return .succeeded("Stored Jev key removed.")
            } catch {
                return .failed("The stored Jev key could not be removed.")
            }
        }
    }

    static func isSupportedModelName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "jev" || normalized == "jev-latest" || normalized.hasPrefix("jev-")
    }

    private func validateModels(apiKey: String, operationID: UUID) async throws -> JevModelList {
        let task = Task {
            try await JevOwnedFirstResult<JevModelList>().run([
                { try await self.client.listModels(apiKey: apiKey, timeout: JevRoutingClient.outerDeadline) }
            ])
        }
        activeValidationTask = task
        defer {
            if owns(operationID) { activeValidationTask = nil }
        }
        return try await task.value
    }

    private func beginValidation(operationID: UUID) {
        activeValidationTask?.cancel()
        activeValidationTask = nil
        activeValidationID = operationID
        isValidating = true
        publishReadiness()
    }

    private func finishValidationIfOwned(operationID: UUID) {
        guard owns(operationID) else { return }
        activeValidationTask = nil
        activeValidationID = nil
        isValidating = false
        publishReadiness()
    }

    private func owns(_ operationID: UUID) -> Bool {
        activeValidationID == operationID
    }

    private func advanceGeneration(validated: Bool) {
        generation &+= 1
        hasValidatedKey = validated
        publishReadiness()
    }

    private func publishReadiness() {
        let snapshot = readinessSnapshot()
        for continuation in readinessContinuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeReadinessContinuation(_ id: UUID) {
        readinessContinuations.removeValue(forKey: id)
    }

    private static func actionResult(from result: ValidationResult) -> AgentTaskRouterBackendSettingsActionResult {
        switch result {
        case let .saved(_, supportedModel):
            .succeeded("Key verified. \(supportedModel) is available and routing is ready.")
        case .missingKey:
            .missingSecret("Enter a TypeSafe API key.")
        case .superseded:
            .superseded("Validation was cancelled or superseded.")
        case let .failed(message):
            .failed(message)
        }
    }

    private static func redactedMessage(for error: Error) -> String {
        switch error as? JevRoutingClientError {
        case .authentication: "Authentication failed."
        case .rateLimited: "TypeSafe rate limited validation."
        case .overloaded: "TypeSafe is temporarily overloaded."
        case .timeout: "TypeSafe validation timed out."
        case .invalidRequest, .invalidResponse, .decoding: "TypeSafe returned an unexpected response."
        case .service: "TypeSafe validation failed."
        case nil: "Validation failed."
        }
    }
}
