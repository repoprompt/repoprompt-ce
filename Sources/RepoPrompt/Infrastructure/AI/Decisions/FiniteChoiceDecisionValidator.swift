import Foundation

/// Structural validation only. Adapters retain their stricter wire-specific acceptance rules.
struct FiniteChoiceDecisionValidator {
    enum RequestError: Error, Equatable {
        case unsupportedContract
        case invalidConsumerOrPolicy
        case invalidQuestion
        case invalidChoiceCount
        case invalidOpaqueKey
        case duplicateOpaqueKey
        case invalidDescription
        case sizeLimitExceeded
        case unsupportedCapability
    }

    static let maximumChoices = 12
    /// RPCE acceptance policy for rounded probability distributions, aligned with Jev.
    static let probabilitySumTolerance = 0.000_1
    static let maximumQuestionNameBytes = 64
    static let maximumOpaqueKeyBytes = 128
    static let maximumContextBytes = 24 * 1024
    static let maximumInstructionsBytes = 16 * 1024
    static let maximumChoiceDescriptionBytes = 8 * 1024
    static let maximumAggregateBytes = 128 * 1024

    func validateRequest(
        _ request: FiniteChoiceDecisionRequest,
        capabilities: DecisionServiceCapabilities,
        requirement: DecisionCapabilityRequirement = .textFiniteChoice
    ) throws {
        guard request.contractVersion == FiniteChoiceDecisionRequest.currentContractVersion else {
            throw RequestError.unsupportedContract
        }
        guard !request.consumerID.rawValue.isBlank,
              !request.policy.id.isBlank,
              !request.policy.version.isBlank
        else { throw RequestError.invalidConsumerOrPolicy }
        let question = request.question
        guard !question.name.isEmpty,
              question.name.utf8.count <= Self.maximumQuestionNameBytes,
              question.name.utf8.allSatisfy({ (33 ... 126).contains($0) })
        else { throw RequestError.invalidQuestion }
        guard (2 ... Self.maximumChoices).contains(question.choices.count) else {
            throw RequestError.invalidChoiceCount
        }
        var seenKeys: Set<String> = []
        for choice in question.choices {
            guard !choice.opaqueKey.isBlank,
                  choice.opaqueKey.utf8.count <= Self.maximumOpaqueKeyBytes
            else { throw RequestError.invalidOpaqueKey }
            guard seenKeys.insert(choice.opaqueKey).inserted else { throw RequestError.duplicateOpaqueKey }
            guard !choice.description.isBlank else { throw RequestError.invalidDescription }
            guard choice.description.utf8.count <= Self.maximumChoiceDescriptionBytes else {
                throw RequestError.sizeLimitExceeded
            }
        }
        guard request.textContext.utf8.count <= Self.maximumContextBytes,
              question.instructions.utf8.count <= Self.maximumInstructionsBytes,
              request.aggregateUTF8Bytes <= Self.maximumAggregateBytes
        else { throw RequestError.sizeLimitExceeded }
        guard capabilities.supports(requirement, request: request) else {
            throw RequestError.unsupportedCapability
        }
    }

    func validateOutcome(
        _ outcome: DecisionOutcome,
        request: FiniteChoiceDecisionRequest,
        acceptancePolicyVersion: String
    ) -> DecisionOutcome {
        let evidence: DecisionEvidence?
        switch outcome {
        case let .selected(key, selectedEvidence):
            guard request.question.choices.count(where: { $0.opaqueKey == key }) == 1 else {
                return .invalidResponse
            }
            evidence = selectedEvidence
        case let .abstained(reasonCode, abstainedEvidence):
            guard !reasonCode.isBlank else { return .invalidResponse }
            evidence = abstainedEvidence
        case let .failed(_, _, failedEvidence):
            evidence = failedEvidence
        case .cancelled:
            return .cancelled
        }
        guard validateEvidence(evidence, request: request, acceptancePolicyVersion: acceptancePolicyVersion) else {
            return .invalidResponse
        }
        return outcome
    }

    private func validateEvidence(
        _ evidence: DecisionEvidence?,
        request: FiniteChoiceDecisionRequest,
        acceptancePolicyVersion: String
    ) -> Bool {
        guard let evidence else { return true }
        guard evidence.acceptancePolicyVersion == acceptancePolicyVersion,
              evidence.confidence.map({ $0.isFinite && (0 ... 1).contains($0) }) ?? true,
              evidence.usage?.inputTokens.map({ $0 >= 0 }) ?? true,
              evidence.usage?.outputTokens.map({ $0 >= 0 }) ?? true
        else { return false }
        let keys = Set(request.question.choices.map(\.opaqueKey))
        return validCoverage(evidence.scores, semantics: evidence.scoreSemantics, expected: .independentScore, keys: keys)
            && validCoverage(evidence.probabilities, semantics: evidence.probabilitySemantics, expected: .probability, keys: keys)
    }

    static func isNormalizedProbabilityDistribution(_ values: some Sequence<Double>) -> Bool {
        let sum = values.reduce(0, +)
        return sum.isFinite && abs(sum - 1) <= probabilitySumTolerance
    }

    private func validCoverage(
        _ values: [DecisionChoiceValue]?,
        semantics: DecisionValueSemantics?,
        expected: DecisionValueSemantics,
        keys: Set<String>
    ) -> Bool {
        guard let values else { return semantics == nil }
        guard semantics == expected, values.count == keys.count else { return false }
        var seen: Set<String> = []
        for value in values {
            guard keys.contains(value.opaqueKey),
                  seen.insert(value.opaqueKey).inserted,
                  value.value.isFinite,
                  (0 ... 1).contains(value.value)
            else { return false }
        }
        return seen == keys
            && (expected != .probability || Self.isNormalizedProbabilityDistribution(values.map(\.value)))
    }
}

private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
