import Foundation

struct CodexHookTrustService {
    typealias RequestExecutor = @Sendable (
        _ method: String,
        _ params: [String: Any]?,
        _ timeout: TimeInterval?
    ) async throws -> [String: Any]

    let requestExecutor: RequestExecutor
    let executionCWD: String?
    let timeout: TimeInterval?

    func listHooks() async throws -> CodexHookInventory {
        try Task.checkCancellation()
        return try await loadHookInventory()
    }

    func trustHooks(
        expectedCandidates: [CodexHookTrustCandidate],
        expectedInventoryFingerprint: String
    ) async throws -> CodexHookInventory {
        try Task.checkCancellation()
        let preflightInventory = try await loadHookInventory()
        guard preflightInventory.fingerprint == expectedInventoryFingerprint else {
            throw CodexHookTrustError.inventoryChanged(replacement: preflightInventory)
        }
        let trustValues = try validatedTrustValues(
            for: expectedCandidates,
            in: preflightInventory
        )

        try Task.checkCancellation()
        let writeOutcome = await performCancellationShieldedRequest(
            method: "config/batchWrite",
            params: [
                "edits": [[
                    "keyPath": "hooks.state",
                    "value": trustValues,
                    "mergeStrategy": "upsert"
                ]],
                "reloadUserConfig": true
            ]
        )
        guard !Task.isCancelled else {
            throw CodexHookTrustError.cancelled
        }

        let writeResult: [String: Any]
        switch writeOutcome {
        case let .success(result):
            writeResult = result
        case let .failure(error):
            if error is CancellationError {
                throw CodexHookTrustError.cancelled
            }
            if Self.isUnsupportedMethodError(error) {
                throw CodexHookTrustError.unsupportedMethod(method: "config/batchWrite")
            }
            throw CodexHookTrustError.batchWriteFailed
        }
        guard writeResult["status"] as? String == "ok" else {
            throw CodexHookTrustError.batchWriteFailed
        }

        return try await verifyCandidates(expectedCandidates)
    }

    private func validatedTrustValues(
        for candidates: [CodexHookTrustCandidate],
        in inventory: CodexHookInventory
    ) throws -> [String: Any] {
        guard inventory.validatedUnresolvedProjectHooks(for: candidates) != nil else {
            throw CodexHookTrustError.inventoryChanged(replacement: inventory)
        }

        var trustValues: [String: Any] = [:]
        for candidate in candidates {
            trustValues[candidate.key] = ["trusted_hash": candidate.currentHash]
        }
        return trustValues
    }

    private func verifyCandidates(
        _ candidates: [CodexHookTrustCandidate]
    ) async throws -> CodexHookInventory {
        try Task.checkCancellation()
        let verifiedInventory: CodexHookInventory
        do {
            verifiedInventory = try await loadHookInventory()
        } catch is CancellationError {
            throw CodexHookTrustError.cancelled
        } catch let error as CodexHookTrustError {
            switch error {
            case .unsupportedMethod, .cancelled:
                throw error
            default:
                throw CodexHookTrustError.postWriteVerificationFailed(latest: nil)
            }
        } catch {
            throw CodexHookTrustError.postWriteVerificationFailed(latest: nil)
        }

        guard verifiedInventory.verifies(candidates) else {
            throw CodexHookTrustError.postWriteVerificationFailed(latest: verifiedInventory)
        }
        try Task.checkCancellation()
        return verifiedInventory
    }

    private func loadHookInventory() async throws -> CodexHookInventory {
        guard let executionCWD,
              !executionCWD.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CodexHookTrustError.malformedListResponse
        }

        let result: [String: Any]
        do {
            result = try await requestExecutor(
                "hooks/list",
                ["cwds": [executionCWD]],
                timeout
            )
        } catch is CancellationError {
            throw CodexHookTrustError.cancelled
        } catch {
            if Self.isUnsupportedMethodError(error) {
                throw CodexHookTrustError.unsupportedMethod(method: "hooks/list")
            }
            throw CodexHookTrustError.malformedListResponse
        }
        return try CodexHookInventory.decode(result: result, executionCWD: executionCWD)
    }

    private func performCancellationShieldedRequest(
        method: String,
        params: [String: Any]?
    ) async -> Result<[String: Any], Error> {
        let requestTask = Task {
            try await requestExecutor(method, params, nil)
        }
        do {
            return try await .success(requestTask.value)
        } catch {
            return .failure(error)
        }
    }

    private static func isUnsupportedMethodError(_ error: Error) -> Bool {
        guard case let CodexAppServerClient.ClientError.requestFailed(failure) = error else {
            return false
        }
        return failure.code == -32601
    }
}
