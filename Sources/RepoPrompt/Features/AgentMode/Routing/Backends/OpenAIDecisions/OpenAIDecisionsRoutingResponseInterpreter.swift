import Foundation

struct OpenAIDecisionsRoutingResponseInterpreter {
    static let pinnedModel = "gpt-6-luna"

    enum Interpretation: Equatable {
        case choice(key: String, scores: [String: Double], confidence: Double)
        case refusal
    }

    enum ValidationError: Error, Equatable {
        case wrongModel
        case wrongAnswerCount
        case wrongQuestion
        case wrongAnswerType
        case unknownChoice
        case invalidProbabilities
        case invalidConfidence
        case invalidUsage
    }

    func interpret(
        _ response: OpenAIDecisionsWireResponse,
        expectedQuestionName: String,
        submittedChoices: [String]
    ) throws -> Interpretation {
        guard response.model == Self.pinnedModel else { throw ValidationError.wrongModel }
        guard response.answers.count == 1 else { throw ValidationError.wrongAnswerCount }
        guard response.usage.inputTokens >= 0,
              response.usage.inputTokensDetails.cachedTokens >= 0,
              response.usage.inputTokensDetails.cacheWriteTokens >= 0,
              response.usage.outputTokens >= 0,
              response.usage.outputTokensDetails.reasoningTokens >= 0,
              response.usage.totalTokens >= 0 else { throw ValidationError.invalidUsage }

        switch response.answers[0] {
        case let .refusal(name):
            guard name == expectedQuestionName else { throw ValidationError.wrongQuestion }
            return .refusal
        case let .choice(name, choice, probabilities, confidence):
            guard name == expectedQuestionName else { throw ValidationError.wrongQuestion }
            guard submittedChoices.count == Set(submittedChoices).count,
                  submittedChoices.contains(choice) else { throw ValidationError.unknownChoice }
            guard confidence.isFinite, (0 ... 1).contains(confidence) else { throw ValidationError.invalidConfidence }
            guard probabilities.count == submittedChoices.count else { throw ValidationError.invalidProbabilities }
            var scores: [String: Double] = [:]
            for entry in probabilities {
                guard submittedChoices.contains(entry.value), scores[entry.value] == nil,
                      entry.probability.isFinite, (0 ... 1).contains(entry.probability)
                else {
                    throw ValidationError.invalidProbabilities
                }
                scores[entry.value] = entry.probability
            }
            guard Set(scores.keys) == Set(submittedChoices),
                  FiniteChoiceDecisionValidator.isNormalizedProbabilityDistribution(scores.values)
            else { throw ValidationError.invalidProbabilities }
            return .choice(key: choice, scores: scores, confidence: confidence)
        }
    }
}
