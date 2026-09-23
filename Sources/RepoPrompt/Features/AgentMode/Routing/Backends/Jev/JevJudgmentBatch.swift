import Foundation

/// One opaque choice option offered inside a single judgment question.
///
/// Criteria are ordered rather than mapped so that a duplicate opaque key is a build error instead
/// of a silently collapsed dictionary entry.
struct JevJudgmentCriterion: Equatable {
    let opaqueKey: String
    let description: String
}

/// A single constrained-choice question submitted to the Jev evaluator.
struct JevJudgmentQuestion: Equatable {
    /// The only answer type this adapter submits or accepts.
    static let choiceType = "choice"

    let id: String
    let instructions: String
    let criteria: [JevJudgmentCriterion]

    /// The opaque keys this question offers. Validation is always scoped to a single question, so a
    /// sibling question's key is never in scope here.
    var submittedOpaqueKeys: Set<String> {
        Set(criteria.map(\.opaqueKey))
    }
}

/// An ordered set of independent choice questions evaluated in one Jev request.
///
/// The documented Jev wire surface has always accepted a question map, and the shipped routing
/// policy submits exactly one `route` question per decision. This type owns the structural contract
/// shared by both shapes so that adding a question can never weaken the per-question guarantees:
/// opaque keys are scoped to their own question, and every submitted question must be answered
/// exactly once.
struct JevJudgmentBatch: Equatable {
    enum BuildError: Error, Equatable {
        case noQuestions
        case emptyQuestionID
        case duplicateQuestionID(String)
        case invalidCriteriaCount(questionID: String)
        case emptyCriterionKey(questionID: String)
        case duplicateCriterionKey(questionID: String)
    }

    static let minimumCriteria = 2
    static let maximumCriteria = AgentTaskRoutingEnvelopeBuilder.maximumCandidates

    let questions: [JevJudgmentQuestion]

    init(questions: [JevJudgmentQuestion]) throws {
        guard !questions.isEmpty else { throw BuildError.noQuestions }
        var seenQuestionIDs: Set<String> = []
        for question in questions {
            guard !question.id.isEmpty else { throw BuildError.emptyQuestionID }
            guard seenQuestionIDs.insert(question.id).inserted else {
                throw BuildError.duplicateQuestionID(question.id)
            }
            guard (Self.minimumCriteria ... Self.maximumCriteria).contains(question.criteria.count) else {
                throw BuildError.invalidCriteriaCount(questionID: question.id)
            }
            var seenOpaqueKeys: Set<String> = []
            for criterion in question.criteria {
                guard !criterion.opaqueKey.isEmpty else {
                    throw BuildError.emptyCriterionKey(questionID: question.id)
                }
                guard seenOpaqueKeys.insert(criterion.opaqueKey).inserted else {
                    throw BuildError.duplicateCriterionKey(questionID: question.id)
                }
            }
        }
        self.questions = questions
    }

    var questionIDs: Set<String> {
        Set(questions.map(\.id))
    }

    /// Submitted opaque keys per question. Keys may legitimately repeat across questions, so
    /// response validation is always scoped to one question and never to the batch as a whole.
    var submittedOpaqueKeysByQuestionID: [String: Set<String>] {
        questions.reduce(into: [:]) { result, question in
            result[question.id] = question.submittedOpaqueKeys
        }
    }

    /// Encodes the batch into the documented `questions` map. A one-question batch produces exactly
    /// the payload the shipped routing policy has always sent.
    func wireQuestions() -> [String: JevRoutingWireRequest.Question] {
        questions.reduce(into: [:]) { result, question in
            result[question.id] = JevRoutingWireRequest.Question(
                type: JevJudgmentQuestion.choiceType,
                instructions: question.instructions,
                criteria: question.criteria.reduce(into: [:]) { criteria, criterion in
                    criteria[criterion.opaqueKey] = criterion.description
                }
            )
        }
    }
}
