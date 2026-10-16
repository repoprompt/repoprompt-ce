import Foundation

enum CodexHookTrustMutationSettlement {
    case response([String: Any])
    case unsettled
}

typealias CodexHookTrustMutationExecutor = @Sendable (
    _ method: String,
    _ params: [String: Any]?,
    _ deadline: TimeInterval
) async throws -> CodexHookTrustMutationSettlement

struct CodexHookTrustService {
    typealias RequestExecutor = @Sendable (
        _ method: String,
        _ params: [String: Any]?,
        _ timeout: TimeInterval?
    ) async throws -> [String: Any]
    enum RequestError: Error {
        case unsupportedMethod
    }

    private enum ShieldedWriteOutcome {
        case response([String: Any])
        case recovered(CodexHookInventory)
        case failure(Error)
        case recoveryFailed
    }

    let requestExecutor: RequestExecutor
    let mutationExecutor: CodexHookTrustMutationExecutor
    let executionCWD: String?
    let timeout: TimeInterval?
    let writeSettlementDeadline: TimeInterval

    func listHooks() async throws -> CodexHookInventory {
        try Task.checkCancellation()
        return try await loadHookInventory(timeout: timeout)
    }

    func trustHooks(
        expectedCandidates: [CodexHookTrustCandidate],
        expectedInventoryFingerprint: String
    ) async throws -> CodexHookInventory {
        try Task.checkCancellation()
        let preflightInventory = try await loadHookInventory(timeout: writeSettlementDeadline)
        guard preflightInventory.fingerprint == expectedInventoryFingerprint else {
            throw CodexHookTrustError.inventoryChanged(replacement: preflightInventory)
        }
        let trustValues = try validatedTrustValues(
            for: expectedCandidates,
            in: preflightInventory
        )

        try Task.checkCancellation()
        let writeOutcome = await performCancellationShieldedWrite(
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

        switch writeOutcome {
        case let .response(writeResult):
            guard writeResult["status"] as? String == "ok" else {
                throw CodexHookTrustError.batchWriteFailed
            }
            return try await verifyCandidates(expectedCandidates)
        case let .recovered(recoveredInventory):
            guard recoveredInventory.verifies(expectedCandidates) else {
                throw CodexHookTrustError.postWriteVerificationFailed(latest: recoveredInventory)
            }
            return recoveredInventory
        case let .failure(error):
            if error is CancellationError {
                throw CodexHookTrustError.cancelled
            }
            if Self.isUnsupportedMethodError(error) {
                throw CodexHookTrustError.unsupportedMethod(method: "config/batchWrite")
            }
            throw CodexHookTrustError.batchWriteFailed
        case .recoveryFailed:
            throw CodexHookTrustError.postWriteVerificationFailed(latest: nil)
        }
    }

    private func validatedTrustValues(
        for candidates: [CodexHookTrustCandidate],
        in inventory: CodexHookInventory
    ) throws -> [String: Any] {
        guard inventory.validatesUnresolvedProjectHooks(for: candidates) else {
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
            verifiedInventory = try await loadHookInventory(timeout: writeSettlementDeadline)
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

    private func loadHookInventory(timeout: TimeInterval?) async throws -> CodexHookInventory {
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

    private func performCancellationShieldedWrite(
        method: String,
        params: [String: Any]?
    ) async -> ShieldedWriteOutcome {
        let requestTask = Task<ShieldedWriteOutcome, Never> {
            do {
                switch try await mutationExecutor(method, params, writeSettlementDeadline) {
                case let .response(response):
                    return ShieldedWriteOutcome.response(response)
                case .unsettled:
                    do {
                        return try await ShieldedWriteOutcome.recovered(
                            loadHookInventory(timeout: writeSettlementDeadline)
                        )
                    } catch {
                        return ShieldedWriteOutcome.recoveryFailed
                    }
                }
            } catch {
                return ShieldedWriteOutcome.failure(error)
            }
        }
        return await requestTask.value
    }

    private static func isUnsupportedMethodError(_ error: Error) -> Bool {
        guard let requestError = error as? RequestError else { return false }
        guard case .unsupportedMethod = requestError else { return false }
        return true
    }
}
