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
        var awaitingRetry: Bool?
    }

    struct PromptExperimentGradingEvidence: Codable, Equatable, Identifiable {
        struct History: Codable, Equatable {
            let ordinal: Int
            let state: PromptExperimentGradingState
            let responseEvidence: PromptExperimentArtifactReference?
            var awaitingRetry: Bool? = nil
        }

        let id: UUID
        let exampleID: String
        let split: PromptExperimentDatasetSplit
        let candidateEvidence: PromptExperimentArtifactReference
        let outputEvidence: PromptExperimentArtifactReference
        let ordinal: Int
        let state: PromptExperimentGradingState
        let history: [History]
        /// Additive metadata; older builds still decode the original failure state.
        var awaitingRetry: Bool? = nil

        func settlingInterruption() -> Self {
            guard awaitingRetry == true else { return self }
            var copy = self
            copy.awaitingRetry = false
            return copy
        }

        func settlingCancellation() -> Self {
            guard state == .pending || awaitingRetry == true else { return self }
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

    struct PromptExperimentCallbackClock {
        let startedAt: TimeInterval
        private var pausedAt: TimeInterval?
        private var pausedSeconds: TimeInterval = 0

        init(startedAt: TimeInterval) {
            self.startedAt = startedAt
        }

        mutating func setPaused(_ paused: Bool, now: TimeInterval) {
            if paused, pausedAt == nil { pausedAt = now }
            else if !paused, let start = pausedAt {
                pausedSeconds += max(0, now - start)
                pausedAt = nil
            }
        }

        func activeSeconds(at now: TimeInterval) -> TimeInterval {
            max(0, now - startedAt - pausedSeconds - (pausedAt.map { max(0, now - $0) } ?? 0))
        }
    }

    @MainActor
    final class PromptExperimentGradingRetryGate {
        private struct Pending {
            let attemptID: UUID
            var accepted = false
            var continuation: CheckedContinuation<Void, Error>?
        }

        private var pending: [UUID: Pending] = [:]

        func wait(attemptID: UUID, gradingID: UUID, publish: () async throws -> Void) async throws {
            guard pending[gradingID] == nil else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("This grading retry is already pending.")
            }
            pending[gradingID] = Pending(attemptID: attemptID)
            defer { pending.removeValue(forKey: gradingID) }
            try await publish()
            guard pending[gradingID] != nil else { throw CancellationError() }
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    if pending[gradingID]?.accepted == true { continuation.resume() }
                    else { pending[gradingID]?.continuation = continuation }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancel(gradingID: gradingID)
                }
            }
            try Task.checkCancellation()
        }

        func cancel(gradingID: UUID) {
            // Removal and continuation extraction are one MainActor transaction:
            // a late decision cannot be reported accepted after cancellation.
            let entry = pending.removeValue(forKey: gradingID)
            entry?.continuation?.resume(throwing: CancellationError())
        }

        func retry(attemptID: UUID, gradingID: UUID) throws {
            guard var entry = pending[gradingID], entry.attemptID == attemptID, !entry.accepted else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("No matching live grading retry is awaiting a decision. This cannot resume an exited worker.")
            }
            entry.accepted = true
            let continuation = entry.continuation
            entry.continuation = nil
            pending[gradingID] = entry
            continuation?.resume()
        }
    }

    /// No catch-all automatic retries. Without a decision callback only invalid JSON
    /// is repairable. Opt-in explicit decisions can retry a provider failure too.
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
            requestRetry: ((Failure) async throws -> Void)? = nil,
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
                        if ordinal == 1, canRepair, let requestRetry {
                            try await requestRetry(.providerFailed)
                            continue
                        }
                        throw Failure.providerFailed
                    }
                    try Task.checkCancellation()
                    if let value = decode(response, minimum: minimum, maximum: maximum) {
                        try await checkpoint(ordinal, .completed, response)
                        return value
                    }
                    try await checkpoint(ordinal, .invalidResponse, response)
                    if ordinal == 1, canRepair, let requestRetry {
                        try await requestRetry(.invalidResponse)
                    }
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
