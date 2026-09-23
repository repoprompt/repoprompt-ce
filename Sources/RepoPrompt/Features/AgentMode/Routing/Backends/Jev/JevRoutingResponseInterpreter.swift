import Foundation

struct JevRoutingResponseInterpreter {
    struct ValidatedAnswer: Equatable {
        let selectedOpaqueKey: String
        let probabilities: [String: Double]
        let confidence: Double
    }

    struct ValidatedResponse: Equatable {
        let answersByQuestionID: [String: ValidatedAnswer]
        let inputTokens: Int
        let outputTokens: Int

        func answer(forQuestionID questionID: String) -> ValidatedAnswer? {
            answersByQuestionID[questionID]
        }
    }

    enum ValidationError: Error, Equatable {
        case wrongEvaluator
        case wrongAnswerShape
        case missingAnswer(questionID: String)
        case unexpectedAnswer(questionID: String)
        case unknownOrMissingCandidates
        case invalidProbability
        case nonUniqueWinningChoice
        case invalidConfidence
        case invalidUsage
    }

    /// Validates the documented Jev response shape without making an acceptance decision.
    ///
    /// Every submitted question is validated independently and must be answered exactly once, and
    /// an answer may reference only the opaque keys of its own question. Batching therefore never
    /// weakens the single-question guarantees: a key that belongs to a sibling question is rejected
    /// exactly like an unknown key. Confidence and winning probability remain separate evidence;
    /// neither is a threshold here.
    func validate(
        _ response: JevRoutingWireResponse,
        batch: JevJudgmentBatch,
        pinnedModel: String = JevRouterCredentialService.pinnedModel
    ) throws -> ValidatedResponse {
        guard response.model == pinnedModel else { throw ValidationError.wrongEvaluator }
        if let unexpected = Set(response.answers.keys).subtracting(batch.questionIDs).sorted().first {
            throw ValidationError.unexpectedAnswer(questionID: unexpected)
        }
        var validatedAnswers: [String: ValidatedAnswer] = [:]
        for question in batch.questions {
            guard let answer = response.answers[question.id] else {
                throw ValidationError.missingAnswer(questionID: question.id)
            }
            validatedAnswers[question.id] = try validate(
                answer,
                submittedOpaqueKeys: question.submittedOpaqueKeys
            )
        }
        guard response.usage.inputTokens >= 0, response.usage.outputTokens >= 0 else {
            throw ValidationError.invalidUsage
        }
        return ValidatedResponse(
            answersByQuestionID: validatedAnswers,
            inputTokens: response.usage.inputTokens,
            outputTokens: response.usage.outputTokens
        )
    }

    private func validate(
        _ answer: JevRoutingWireResponse.Answer,
        submittedOpaqueKeys: Set<String>
    ) throws -> ValidatedAnswer {
        guard answer.type == JevJudgmentQuestion.choiceType,
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
        return ValidatedAnswer(
            selectedOpaqueKey: answer.choice,
            probabilities: answer.probabilities,
            confidence: answer.confidence
        )
    }
}
