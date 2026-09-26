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

    /// No catch-all automatic retries: only an invalid judge response is repairable, once per
    /// evaluation. Checkpoint failures and cancellation escape immediately,
    /// before further spending.
    @MainActor
    enum PromptExperimentGrading {
        enum Failure: String, LocalizedError {
            case invalidResponse = "judge_invalid_response"
            case providerFailed = "judge_provider_failed"

            var errorDescription: String? {
                rawValue
            }
        }

        /// Extracts one evaluator object from a judge reply: the bare reply, else the last fenced
        /// `json`/untagged block, else the first balanced top-level `{…}` that parses as a JSON object.
        /// Surrounding prose is tolerated; the contract (finite in-range numeric score, string
        /// feedback) is still validated strictly.
        static func decode(_ raw: String, minimum: Double, maximum: Double) -> (score: Double, feedback: String)? {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let object = jsonObject(text)
                ?? lastFencedJSONBlock(in: text).flatMap(jsonObject)
                ?? firstBalancedJSONObject(in: text)
            guard let object else { return nil }
            return validate(object, minimum: minimum, maximum: maximum)
        }

        private static func jsonObject(_ text: String) -> [String: Any]? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") else { return nil }
            let repaired = escapingControlCharactersInStrings(trimmed)
            return (try? JSONSerialization.jsonObject(with: Data(repaired.utf8))) as? [String: Any]
        }

        /// Judges sometimes emit raw newlines/tabs inside string literals (e.g. multi-paragraph
        /// `feedback`), which strict JSON rejects. Escapes U+0000–U+001F only while inside a string
        /// literal (tracking backslash escapes); structural whitespace outside strings is untouched.
        static func escapingControlCharactersInStrings(_ text: String) -> String {
            var result = String.UnicodeScalarView()
            var inString = false
            var escaped = false
            for scalar in text.unicodeScalars {
                guard inString else {
                    if scalar == "\"" { inString = true }
                    result.append(scalar)
                    continue
                }
                if escaped {
                    escaped = false
                    result.append(scalar)
                } else if scalar == "\\" {
                    escaped = true
                    result.append(scalar)
                } else if scalar == "\"" {
                    inString = false
                    result.append(scalar)
                } else if scalar.value < 0x20 {
                    let replacement = switch scalar {
                    case "\n": "\\n"
                    case "\r": "\\r"
                    case "\t": "\\t"
                    default: String(format: "\\u%04x", scalar.value)
                    }
                    result.append(contentsOf: replacement.unicodeScalars)
                } else {
                    result.append(scalar)
                }
            }
            return String(result)
        }

        /// The content of the last closed ``` fence whose info string is empty or `json`.
        static func lastFencedJSONBlock(in text: String) -> String? {
            let lines = text.components(separatedBy: "\n")
            var found: String?
            var openTag: String?
            var body: [String] = []
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let tag = openTag {
                    if trimmed == "```" {
                        if tag.isEmpty || tag == "json" { found = body.joined(separator: "\n") }
                        openTag = nil
                        body = []
                    } else {
                        body.append(line)
                    }
                } else if trimmed.hasPrefix("```") {
                    openTag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                }
            }
            return found
        }

        /// Scans top-level `{…}` spans (string- and escape-aware inside a span) and returns the
        /// first one that parses as a JSON object.
        static func firstBalancedJSONObject(in text: String) -> [String: Any]? {
            let scalars = Array(text.unicodeScalars)
            var depth = 0
            var start = 0
            var inString = false
            var escaped = false
            for index in scalars.indices {
                let scalar = scalars[index]
                if depth > 0, inString {
                    if escaped {
                        escaped = false
                    } else if scalar == "\\" {
                        escaped = true
                    } else if scalar == "\"" {
                        inString = false
                    }
                    continue
                }
                switch scalar {
                case "{":
                    if depth == 0 { start = index }
                    depth += 1
                case "}" where depth > 0:
                    depth -= 1
                    if depth == 0 {
                        var span = String.UnicodeScalarView()
                        span.append(contentsOf: scalars[start ... index])
                        if let object = jsonObject(String(span)) { return object }
                    }
                case "\"" where depth > 0:
                    inString = true
                default:
                    break
                }
            }
            return nil
        }

        private static func validate(
            _ object: [String: Any], minimum: Double, maximum: Double
        ) -> (score: Double, feedback: String)? {
            guard let number = object["score"] as? NSNumber,
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
                    // The canonical store accepts settlement writes after cancellation.
                    try await checkpoint(ordinal, .cancelled, nil)
                    throw CancellationError()
                }
            }
            throw Failure.invalidResponse
        }
    }
#endif
