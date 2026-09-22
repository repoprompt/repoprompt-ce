import Foundation

struct JevRoutingResponseInterpreter {
    struct ValidatedResponse: Equatable {
        let selectedOpaqueKey: String
        let probabilities: [String: Double]
        let confidence: Double
        let inputTokens: Int
        let outputTokens: Int
    }

    enum ValidationError: Error, Equatable {
        case wrongEvaluator
        case wrongAnswerShape
        case unknownOrMissingCandidates
        case invalidProbability
        case nonUniqueWinningChoice
        case invalidConfidence
        case invalidUsage
    }

    /// Validates the documented Jev response shape without making an acceptance decision.
    /// Confidence and winning probability remain separate evidence; neither is a threshold here.
    func validate(
        _ response: JevRoutingWireResponse,
        submittedOpaqueKeys: Set<String>,
        pinnedModel: String = JevRouterCredentialService.pinnedModel
    ) throws -> ValidatedResponse {
        guard response.model == pinnedModel else { throw ValidationError.wrongEvaluator }
        guard response.answers.count == 1,
              let answer = response.answers["route"],
              answer.type == "choice",
              submittedOpaqueKeys.contains(answer.choice)
        else { throw ValidationError.wrongAnswerShape }
        guard Set(answer.probabilities.keys) == submittedOpaqueKeys else {
            throw ValidationError.unknownOrMissingCandidates
        }
        guard answer.probabilities.values.allSatisfy({ $0.isFinite && (0 ... 1).contains($0) }) else {
            throw ValidationError.invalidProbability
        }
        let sum = answer.probabilities.values.reduce(0, +)
        guard abs(sum - 1) <= 0.000_1 else { throw ValidationError.invalidProbability }
        guard let maximum = answer.probabilities.values.max() else {
            throw ValidationError.invalidProbability
        }
        let winners = answer.probabilities.filter { $0.value == maximum }.map(\.key)
        guard winners == [answer.choice] else { throw ValidationError.nonUniqueWinningChoice }
        guard answer.confidence.isFinite, (0 ... 1).contains(answer.confidence) else {
            throw ValidationError.invalidConfidence
        }
        guard response.usage.inputTokens >= 0, response.usage.outputTokens >= 0 else {
            throw ValidationError.invalidUsage
        }
        return ValidatedResponse(
            selectedOpaqueKey: answer.choice,
            probabilities: answer.probabilities,
            confidence: answer.confidence,
            inputTokens: response.usage.inputTokens,
            outputTokens: response.usage.outputTokens
        )
    }
}
