#if DEBUG
    import CoreFoundation
    import Foundation

    enum PromptExperimentGradingState: String, Codable {
        case pending
        case invalidResponse = "invalid_response"
        case providerFailed = "provider_failed"
        case cancelled
        case completed
    }

    struct PromptExperimentGradingCheckpoint: Equatable {
        let id: UUID
        let exampleID: String
        let split: PromptExperimentDatasetSplit
        let candidate: String
        let output: String
        let ordinal: Int
        let state: PromptExperimentGradingState
        let response: String?
    }

    struct PromptExperimentGradingEvidence: Codable, Equatable, Identifiable {
        struct History: Codable, Equatable {
            let ordinal: Int
            let state: PromptExperimentGradingState
            let responseEvidence: PromptExperimentArtifactReference?
        }

        let id: UUID
        let exampleID: String
        let split: PromptExperimentDatasetSplit
        let candidateEvidence: PromptExperimentArtifactReference
        let outputEvidence: PromptExperimentArtifactReference
        let ordinal: Int
        let state: PromptExperimentGradingState
        let history: [History]

        func settlingCancellation() -> Self {
            guard state == .pending else { return self }
            return Self(
                id: id,
                exampleID: exampleID,
                split: split,
                candidateEvidence: candidateEvidence,
                outputEvidence: outputEvidence,
                ordinal: ordinal,
                state: .cancelled,
                history: history + [.init(ordinal: ordinal, state: .cancelled, responseEvidence: nil)]
            )
        }
    }

    /// No catch-all retries. Only a completed judge response with invalid score JSON is
    /// eligible for one format repair, and only within the sealed run-wide allowance.
    /// Checkpoint failures and cancellation escape immediately, before further spending.
    @MainActor
    enum PromptExperimentGrading {
        enum Failure: String, LocalizedError {
            case invalidResponse = "judge_invalid_response"
            case providerFailed = "judge_provider_failed"

            var errorDescription: String? {
                rawValue
            }
        }

        static func decode(_ raw: String, minimum: Double, maximum: Double) -> (score: Double, feedback: String)? {
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("```"), text.hasSuffix("```"), let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...].dropLast(3))
            }
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let number = object["score"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite,
                  number.doubleValue >= minimum, number.doubleValue <= maximum,
                  let feedback = object["feedback"] as? String
            else { return nil }
            return (number.doubleValue, feedback)
        }

        static func run(
            minimum: Double, maximum: Double, canRepair: Bool,
            checkpoint: (Int, PromptExperimentGradingState, String?) async throws -> Void,
            invoke: (Bool) async throws -> String
        ) async throws -> (score: Double, feedback: String) {
            for ordinal in 1 ... (canRepair ? 2 : 1) {
                try Task.checkCancellation()
                try await checkpoint(ordinal, .pending, nil)
                do {
                    try Task.checkCancellation()
                    let response: String
                    do {
                        response = try await invoke(ordinal == 2)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        try await checkpoint(ordinal, .providerFailed, nil)
                        throw Failure.providerFailed
                    }
                    try Task.checkCancellation()
                    if let value = decode(response, minimum: minimum, maximum: maximum) {
                        try await checkpoint(ordinal, .completed, response)
                        return value
                    }
                    try await checkpoint(ordinal, .invalidResponse, response)
                } catch is CancellationError {
                    // The canonical store intentionally accepts settlement writes after
                    // cancellation; it never checks Task cancellation during persistence.
                    try await checkpoint(ordinal, .cancelled, nil)
                    throw CancellationError()
                }
            }
            throw Failure.invalidResponse
        }
    }
#endif
